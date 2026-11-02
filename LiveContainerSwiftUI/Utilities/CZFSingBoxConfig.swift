import Foundation

// CZFSingBoxConfig.swift
//
// 职责：sing-box 分流判定 + sing-box 配置 JSON 生成（B 项目 S2）。
// 只含纯函数与静态方法：不调用任何 Libbox/CGo 函数，不碰 UserDefaults，
// 不读写文件、不联网。配置一律用 JSONSerialization 拼（不许字符串插值），
// 密码/密钥里含引号、反斜杠也不会打断 JSON。
//
// 字段依据：sing-box 官方文档（2026-11-02 核对，见各协议注释）。
// 凡文档查不到、或文档与任务描述不一致的字段，本文件一律不写，
// 并在注释与交付汇报里明说“未验证，CI/真机前需再核”。
// 本地无 Swift 工具链：括号平衡 ≠ 编译通过，需 CI 验证。
//
// 与 CZFVPNManager 的衔接：
// CZFVPNManager.nodeScheme / isSupportedNodeScheme 是 Xray 转换器清单
// （vmess/vless/hysteria2/hy2/ss/socks/socks5/trojan/json）。
// 本文件的 coreKind 是在其之上的第二层分流：先按 scheme 定大方向，
// 再按参数把“Xray 拒收的那部分 vmess/ss + 全部 sing-box 系协议”
// 拨给 sing-box。调用顺序：先查 unsupportedReason（非 nil 就别路由），
// 再查 coreKind（xray / singBox），最后按 coreKind 选核心生成配置。
// 注意：coreKind 的 .xray 只表示“不走 sing-box”，纯文本、未知协议
// 也会落到 .xray，调用方必须先看 unsupportedReason。

/// 核心分流结果。xray = 走 Xray（含“不走 sing-box”的一切情况）。
public enum CZFCoreKind {
    case xray
    case singBox
}

/// 配置生成错误。所有 case 只带字段名或 scheme 名，绝不带密码、
// 密钥、uuid、私钥等任何凭证值（调用方打印错误也不会泄漏）。
public enum CZFSingBoxConfigError: Error {
    case missingField(String)
    case invalidValue(String)
    case unsupportedScheme(String)
    case notSingBoxNode
    case encodingFailed
}

extension CZFSingBoxConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingField(let field): return "缺少 \(field)"
        case .invalidValue(let field): return "\(field) 不合法"
        case .unsupportedScheme(let scheme): return "不支持的协议：\(scheme)"
        case .notSingBoxNode: return "该节点不走 sing-box，不由本文件生成配置"
        case .encodingFailed: return "配置 JSON 编码失败"
        }
    }
}

// MARK: - 分流判定

public enum CZFSingBoxRouting {

    /// 节点出站的统一 tag。sing-box 的 outbounds 与 endpoints 共用
    /// tag 命名空间，所以 WireGuard endpoint 也用这个 tag，不另起。
    static let nodeTag = "node-out"

    /// 只看 scheme 字面就走 sing-box 的 9 个协议。
    /// 注意：vmess/ss 不在这里——它们按参数分流，见 coreKind。
    /// hysteria2/hy2 也不在这里——Hysteria2 走 Xray（已有验证）。
    private static let singBoxSchemes: Set<String> = [
        "tuic", "hysteria", "wireguard", "naive", "ssh",
        "http", "anytls", "shadowtls", "snell",
    ]

    /// Xray 侧已知的 scheme（抄 CZFVPNManager.isSupportedNodeScheme
    /// 的清单；本文件不调用它，保持自包含，清单变了要同步改）。
    private static let xraySchemes: Set<String> = [
        "vmess", "vless", "hysteria2", "hy2", "ss",
        "socks", "socks5", "trojan", "json",
    ]

    /// 明确不支持的 scheme（sing-box 也没有这个协议）。
    private static let unsupportedSchemes: Set<String> = ["ssr", "mieru", "juicity"]

    /// AEAD / 现代 SS 加密方法（小写）。不在此集合里的 SS 方法
    /// （aes-*-cfb/ctr、rc4-md5、chacha20-ietf、xchacha20、none 等）
    /// 一律按“老 SS”走 sing-box；方法名原样透传，不校验白名单。
    private static let aeadMethods: Set<String> = [
        "aes-128-gcm", "aes-256-gcm",
        "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305",
    ]

    // MARK: scheme 与 query 解析（与 CZFVPNManager.nodeScheme 同语义）

    /// scheme（小写；原始 JSON 出站记为 json；无 :// 的纯文本记为空串）。
    static func scheme(of link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return "json" }
        guard let range = trimmed.range(of: "://") else { return "" }
        return String(trimmed[..<range.lowerBound]).lowercased()
    }

    /// query 参数表（同一参数多次出现时保留全部值）。
    /// URLComponents 已经做过一次 percent-decode，这里绝不再
    /// removingPercentEncoding：密码里若含 %XX 字样，二次解码会
    /// 把它改写成别的字符，等于改了密码（TUICLink 的教训，照抄）。
    static func queryMap(of link: String) -> [String: [String]] {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return [:]
        }
        var map: [String: [String]] = [:]
        for item in comps.queryItems ?? [] {
            guard let value = item.value else { continue }
            map[item.name, default: []].append(value)
        }
        return map
    }

    /// 按顺序取第一个非空 query 值。
    static func firstQuery(_ map: [String: [String]], _ names: String...) -> String? {
        for name in names {
            if let value = map[name]?.first, !value.isEmpty { return value }
        }
        return nil
    }

    /// 布尔型 query 参数：1 / true / yes（不区分大小写）即真。
    /// 同 splitList 的原因，不能把 [String] 转发给 variadic，
    /// 这里自己循环取首个非空值。
    static func boolQuery(_ map: [String: [String]], _ names: String...) -> Bool {
        var raw: String?
        for name in names {
            if let value = map[name]?.first, !value.isEmpty { raw = value; break }
        }
        guard let raw = raw else { return false }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "1" || v == "true" || v == "yes"
    }

    /// 是否含“跳过证书验证”参数（allow_insecure / insecure /
    /// skip-cert-verify 任一为 1/true/yes）。无 :// 的纯文本与
    /// JSON 出站返回 false。
    public static func isInsecureNode(_ link: String) -> Bool {
        let scheme = scheme(of: link)
        if scheme.isEmpty || scheme == "json" { return false }
        let map = queryMap(of: link)
        return boolQuery(map, "allow_insecure", "insecure", "skip-cert-verify")
    }

    /// 只看 scheme 字面是否属于 sing-box 系（9 个）。
    /// vmess/ss 永远返回 false——它们按参数分流，不按字面划。
    public static func isSingBoxScheme(_ scheme: String) -> Bool {
        return singBoxSchemes.contains(scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// 三撞判定：vless + 传输类型 xhttp + allowInsecure。
    /// 传输类型只认 query 的 type=xhttp（vless 链接的标准写法）。
    static func isTripleCollision(link: String, scheme: String) -> Bool {
        guard scheme == "vless" else { return false }
        let map = queryMap(of: link)
        let type = firstQuery(map, "type")?.lowercased() ?? ""
        return type == "xhttp" && isInsecureNode(link)
    }

    // MARK: vmess / ss 的参数探查（coreKind 用，不抛错，探查失败按 Xray 计）

    /// vmess 的 alterId（JSON 的 aid/alterId，或 URL 的 aid/alterId/
    /// alter_id；探查失败返回 0，即按 AEAD 计）。
    static func vmessAlterId(of link: String) -> Int {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "://") {
            let after = String(trimmed[range.upperBound...])
            let beforeQuery = after.split(separator: "?", maxSplits: 1).first.map(String.init) ?? after
            if !beforeQuery.contains("@") {
                // Base64(JSON) 形：解码后读 aid。
                if let dict = CZFSingBoxConfig.decodeBase64JSON(after) {
                    return CZFSingBoxConfig.intValue(dict["aid"] ?? dict["alterId"] ?? dict["alter_id"]) ?? 0
                }
                return 0
            }
        }
        let map = queryMap(of: link)
        if let raw = firstQuery(map, "aid", "alterId", "alter_id"), let v = Int(raw) { return v }
        return 0
    }

    /// ss 的加密方法（小写；探查失败返回 nil，即按 Xray 计）。
    /// 复用 CZFSingBoxConfig 的 ss 解析，但吞掉一切错误。
    static func ssMethod(of link: String) -> String? {
        guard let out = try? CZFSingBoxConfig.shadowsocksOutbound(link: link),
              let method = out["method"] as? String, !method.isEmpty else {
            return nil
        }
        return method.lowercased()
    }

    // MARK: 对外接口

    /// 分流主入口。顺序（一条都不能乱）：
    /// 1. vless：xhttp 一律 Xray（sing-box 没有 XHTTP 出站；
    ///    三撞时 unsupportedReason 会明说走不通）；xhttp 之外
    ///    含 allowInsecure 的走 sing-box（Xray 拒不验证书），
    ///    其余走 Xray（保 Vision/REALITY/原有行为）；
    /// 2. sing-box 系 9 个 scheme 一律 sing-box；
    /// 3. vmess：alterId > 0 的老 vmess 走 sing-box，否则看
    ///    allowInsecure（含 allowInsecure 一律 sing-box），其余 Xray；
    /// 4. ss：非 AEAD 老方法走 sing-box，否则看 allowInsecure，
    ///    其余走 Xray；
    /// 5. trojan / hysteria2 / hy2：含 allowInsecure 走 sing-box，
    ///    其余走 Xray（Hysteria2 非 insecure 仍走已验证的 Xray）；
    /// 6. 其余（socks/json/纯文本/未知）一律 Xray——调用方必须
    ///    先查 unsupportedReason，纯文本与未知协议落到这里
    ///    不代表“Xray 能跑”。
    public static func coreKind(for link: String) -> CZFCoreKind {
        let scheme = scheme(of: link)
        if scheme == "vless" {
            // xhttp 只能走 Xray；xhttp 之外含 allowInsecure 走 sing-box。
            if isTripleCollision(link: link, scheme: scheme) { return .xray }
            if isInsecureNode(link) { return .singBox }
            return .xray
        }
        if isSingBoxScheme(scheme) { return .singBox }
        switch scheme {
        case "vmess":
            if vmessAlterId(of: link) > 0 { return .singBox }
            if isInsecureNode(link) { return .singBox }
            return .xray
        case "ss":
            if let method = ssMethod(of: link), !aeadMethods.contains(method) { return .singBox }
            if isInsecureNode(link) { return .singBox }
            return .xray
        case "trojan", "hysteria2", "hy2":
            if isInsecureNode(link) { return .singBox }
            return .xray
        default:
            return .xray
        }
    }

    /// 不可路由的原因；可路由返回 nil。
    /// - ssr/mieru/juicity：明说 sing-box 也没有这个协议；
    /// - 三撞：明说两边都走不通；
    /// - 无 scheme 纯文本：明说不是节点链接；
    /// - 未知 scheme：只说暂不支持（不替 sing-box 背书有没有它）；
    /// - 其余（Xray 系、sing-box 系、json）一律 nil。
    public static func unsupportedReason(for link: String) -> String? {
        let scheme = scheme(of: link)
        if scheme.isEmpty { return "不是节点链接" }
        if unsupportedSchemes.contains(scheme) {
            return "\(scheme) 暂不支持（sing-box 也没有这个协议）"
        }
        if isTripleCollision(link: link, scheme: scheme) {
            return "VLESS+XHTTP 只能走 Xray，Xray 又拒不验证书，两边都走不通"
        }
        if singBoxSchemes.contains(scheme) || xraySchemes.contains(scheme) { return nil }
        return "\(scheme) 暂不支持"
    }

    /// 行内“不验证书”标记判定：含 allowInsecure 且实际会以
    /// tls.insecure=true 跑起来的节点。ss / snell / ssh /
    /// wireguard 没有 TLS 块（insecure 参数对它们无意义）；
    /// 三撞节点走不通；明文 vless（security=none）与没开
    /// tls 的 vmess 也不写 tls 块，同样不标。调用方是
    /// CZFVPNManager.nodeDisplay（行内 scheme 显示处）。
    public static func showsInsecureMark(for link: String) -> Bool {
        guard isInsecureNode(link), unsupportedReason(for: link) == nil else { return false }
        let scheme = scheme(of: link)
        if ["ss", "snell", "ssh", "wireguard"].contains(scheme) { return false }
        let map = queryMap(of: link)
        if scheme == "vless" {
            return firstQuery(map, "security")?.lowercased() != "none"
        }
        if scheme == "vmess" {
            let tlsRaw = firstQuery(map, "tls")?.lowercased() ?? ""
            return tlsRaw == "tls" || tlsRaw == "1" || tlsRaw == "true" || tlsRaw == "yes"
        }
        return true
    }
}

// MARK: - 配置生成

public enum CZFSingBoxConfig {

    // MARK: 通用解析工具（全部只抛“缺什么/哪项不合法”，绝不带凭证值）

    /// 标准 + URL 安全 Base64 解码（自动补 = 填充）。
    /// 写法抄 CZFVPNManager 的 padding 惯例（仓库内已有 3 处同类用例）。
    static func decodeBase64(_ text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// Base64(JSON) → 字典；解失败返回 nil（调用方再按表单抛错）。
    /// 传入的是 :// 之后、?/# 之前的整段（不含 query/fragment）。
    static func decodeBase64JSON(_ afterScheme: String) -> [String: Any]? {
        let payload = afterScheme.split(separator: "?", maxSplits: 1).first
            .map(String.init) ?? afterScheme
        let clean = payload.split(separator: "#", maxSplits: 1).first.map(String.init) ?? payload
        guard let data = decodeBase64(clean),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// JSON 值 → Int（Int / NSNumber / 数字字符串都认）。
    static func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? NSNumber { return v.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// JSON 值 → String（String / NSNumber 都认）。
    static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let v = value as? NSNumber { return v.stringValue }
        return nil
    }

    /// URLComponents（trim 后解析；解析失败返回 nil，调用方按缺字段抛错）。
    static func components(of link: String) -> URLComponents? {
        return URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// host 非空校验（空 host 一律 throw，不区分协议）。
    static func requireHost(_ comps: URLComponents?) throws -> String {
        guard let host = comps?.host, !host.isEmpty else {
            throw CZFSingBoxConfigError.missingField("server")
        }
        return host
    }

    /// 端口校验：缺端口 throw，超出 1...65535 throw。
    static func requirePort(_ comps: URLComponents?) throws -> Int {
        guard let port = comps?.port else {
            throw CZFSingBoxConfigError.missingField("server_port")
        }
        guard (1...65535).contains(port) else {
            throw CZFSingBoxConfigError.invalidValue("server_port")
        }
        return port
    }

    /// “host:port”拆分（支持 [IPv6]:port；无端口返回 nil 端口）。
    static func splitHostPort(_ text: String) -> (host: String, port: Int?)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[") {
            guard let close = t.firstIndex(of: "]") else { return nil }
            let host = String(t[t.index(after: t.startIndex)..<close])
            let rest = String(t[t.index(after: close)...])
            if rest.hasPrefix(":") {
                guard let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
                return (host, port)
            }
            return (host, nil)
        }
        guard let colon = t.lastIndex(of: ":") else { return (t, nil) }
        let host = String(t[..<colon])
        let portText = String(t[t.index(after: colon)...])
        if portText.isEmpty { return (host, nil) }
        guard let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    /// 逗号分隔的 query 值 → 去空数组（alpn、allowed_ips 等用）。
    /// 注意：不能把 [String] 直接转发给 variadic 的 firstQuery
    /// （Swift 不支持数组 splat），这里自己循环取首个非空值。
    static func splitList(_ map: [String: [String]], _ names: String...) -> [String] {
        var raw: String?
        for name in names {
            if let value = map[name]?.first, !value.isEmpty { raw = value; break }
        }
        guard let raw = raw else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// alpn：逗号分隔或重复 query 项都认（照抄 TUICLink 的 alpn 处理）。
    static func alpnList(_ map: [String: [String]]) -> [String] {
        return (map["alpn"] ?? [])
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }

    /// 出站 tls 块（官方 shared/tls 出站字段：enabled / server_name /
    /// insecure / alpn）。server_name 与 alpn 为空时省略，不写空值。
    /// 注意：uTLS 指纹（fp / fingerprint 参数）本期一律丢弃不传——
    /// 因为不构建 with_utls 的 sing-box，传了 utls 块也跑不起来；
    /// 这是有意取舍，不是漏传（见交付汇报）。
    static func tlsBlock(serverName: String?, alpn: [String], insecure: Bool, enabled: Bool = true) -> [String: Any] {
        var tls: [String: Any] = ["enabled": enabled, "insecure": insecure]
        if let name = serverName, !name.isEmpty { tls["server_name"] = name }
        if !alpn.isEmpty { tls["alpn"] = alpn }
        return tls
    }

    /// sni/server_name + allowInsecure/insecure/skip-cert-verify 的统一取法。
    static func tlsParams(_ map: [String: [String]]) -> (serverName: String?, alpn: [String], insecure: Bool) {
        let serverName = CZFSingBoxRouting.firstQuery(map, "sni", "server_name")
        let insecure = CZFSingBoxRouting.boolQuery(map, "allow_insecure", "insecure", "skip-cert-verify")
        return (serverName, alpnList(map), insecure)
    }

    // MARK: 各协议出站（字段名后都注了文档依据）

    /// tuic：照抄 TUICLink 语义（官方 outbound/tuic：server /
    /// server_port 必填，uuid 必填，password，congestion_control
    /// ∈ cubic/new_reno/bbr，udp_relay_mode ∈ native/quic，tls 必填）。
    static func tuicOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "tuic" else {
            throw CZFSingBoxConfigError.unsupportedScheme("tuic")
        }
        // user/password 是 URLComponents 一次解码后的值，不二次解码。
        guard let uuid = comps.user, !uuid.isEmpty else {
            throw CZFSingBoxConfigError.missingField("uuid")
        }
        guard UUID(uuidString: uuid) != nil else {
            throw CZFSingBoxConfigError.invalidValue("uuid")
        }
        guard let password = comps.password else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        var out: [String: Any] = [
            "type": "tuic",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "password": password,
        ]
        if let cc = CZFSingBoxRouting.firstQuery(map, "congestion_control"), !cc.isEmpty {
            out["congestion_control"] = cc
        }
        if let mode = CZFSingBoxRouting.firstQuery(map, "udp_relay_mode"), !mode.isEmpty {
            out["udp_relay_mode"] = mode
        }
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    /// hysteria v1：官方 outbound/hysteria（无 version 字段——不要写；
    /// v1 的 obfs 是平铺字符串，不是 hysteria2 的 {type,password} 对象；
    /// auth 是 base64，auth_str 是明文——链接里的 auth 是明文，
    /// 所以写 auth_str；up/down 或 up_mbps/down_mbps 文档标必填，
    /// 链接里有 upmbps/downmbps 就映射，没有就不编造带宽值，
    /// 省略后能否过 CheckConfig 属未验证，见汇报）。
    static func hysteriaOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "hysteria" else {
            throw CZFSingBoxConfigError.unsupportedScheme("hysteria")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        var out: [String: Any] = [
            "type": "hysteria",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
        ]
        if let network = CZFSingBoxRouting.firstQuery(map, "protocol"), network == "tcp" || network == "udp" {
            out["network"] = network
        }
        if let auth = CZFSingBoxRouting.firstQuery(map, "auth") ?? comps.user, !auth.isEmpty {
            out["auth_str"] = auth
        }
        if let obfs = CZFSingBoxRouting.firstQuery(map, "obfs"), !obfs.isEmpty {
            out["obfs"] = obfs
        }
        if let up = CZFSingBoxRouting.firstQuery(map, "upmbps"), let v = Int(up) {
            out["up_mbps"] = v
        }
        if let down = CZFSingBoxRouting.firstQuery(map, "downmbps"), let v = Int(down) {
            out["down_mbps"] = v
        }
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    /// wireguard：官方 1.11+ 已废弃 wireguard 出站（1.13 起移除），
    /// 只能走顶层 endpoints（官方 endpoint/wireguard + migration 页）。
    /// 所以本函数返回的是 endpoint 对象，不是出站对象；configJSON
    /// 会把它放进顶层 "endpoints"，且不写 "outbounds"（两个区段
    /// 共用 tag 命名空间，重复写 node-out 会冲突）。
    /// endpoint 字段（官方 endpoint/wireguard）：address 必填、
    /// private_key 必填、peers 必填、peers.address / peers.port /
    /// peers.public_key（必填）/ peers.pre_shared_key /
    /// peers.allowed_ips（必填）。任务描述里的 server/server_port
    /// 是旧出站字段，1.14 上写了旧字段反而过不了 CheckConfig，
    /// 故此处按 endpoint 字段写，这是一处以文档为准的偏离，见汇报。
    /// endpoint 来源：优先 query 的 endpoint=host:port，否则用
    /// URL 的 host:port。address 缺了就 throw（官方标必填）。
    /// allowed_ips 缺省为全量（0.0.0.0/0 + ::/0）：代理用途就是
    /// 全流量走隧道，官方又标必填，不填默认值会直接 invalid。
    static func wireguardEndpoint(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "wireguard" else {
            throw CZFSingBoxConfigError.unsupportedScheme("wireguard")
        }
        let map = CZFSingBoxRouting.queryMap(of: link)
        let privateKey = CZFSingBoxRouting.firstQuery(map, "private-key", "private_key")
            ?? (comps.user?.isEmpty == false ? comps.user : nil)
        guard let privateKey = privateKey, !privateKey.isEmpty else {
            throw CZFSingBoxConfigError.missingField("private-key")
        }
        guard let publicKey = CZFSingBoxRouting.firstQuery(map, "public-key", "public_key"), !publicKey.isEmpty else {
            throw CZFSingBoxConfigError.missingField("public-key")
        }
        // 本地地址：.conf 导入与含 ip 的 Clash 条目会带 address；
        // 裸链接没有时省略（endpoint 的 address 不是必填字段，
        // 省略后仅作出口用能否通属未验证，见汇报）。
        let addresses = splitList(map, "address", "local-address", "local_address")
        let epHost: String
        let epPort: Int
        if let endpoint = CZFSingBoxRouting.firstQuery(map, "endpoint") {
            guard let parsed = splitHostPort(endpoint), !parsed.host.isEmpty, let p = parsed.port else {
                throw CZFSingBoxConfigError.invalidValue("endpoint")
            }
            epHost = parsed.host
            epPort = p
        } else {
            epHost = try requireHost(comps)
            epPort = try requirePort(comps)
        }
        var peer: [String: Any] = [
            "address": epHost,
            "port": epPort,
            "public_key": publicKey,
        ]
        if let psk = CZFSingBoxRouting.firstQuery(map, "preshared-key", "preshared_key"), !psk.isEmpty {
            peer["pre_shared_key"] = psk
        }
        let allowed = splitList(map, "allowed-ips", "allowed_ips")
        peer["allowed_ips"] = allowed.isEmpty ? ["0.0.0.0/0", "::/0"] : allowed
        var ep: [String: Any] = [
            "type": "wireguard",
            "tag": CZFSingBoxRouting.nodeTag,
            "private_key": privateKey,
            "peers": [peer],
        ]
        if !addresses.isEmpty {
            ep["address"] = addresses
        }
        if let mtuText = CZFSingBoxRouting.firstQuery(map, "mtu"), let mtu = Int(mtuText) {
            ep["mtu"] = mtu
        }
        return ep
    }

    /// naive：官方 outbound/naive（自 1.13.0；server / server_port /
    /// tls 必填；字段名是 username/password，不是 user/pass；
    /// tls 仅支持 server_name 等少数项——但任务要求 insecure 进
    /// tls.insecure，本文件照任务写，CheckConfig 能否接受属未验证）。
    static func naiveOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "naive" else {
            throw CZFSingBoxConfigError.unsupportedScheme("naive")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        var out: [String: Any] = [
            "type": "naive",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
        ]
        if let user = comps.user, !user.isEmpty { out["username"] = user }
        if let password = comps.password { out["password"] = password }
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    /// ssh：官方 outbound/ssh（server 必填，server_port 缺省 22，
    /// user 缺省 root，password / private_key / host_key；
    /// 注意：host_key 是字符串数组，不是单个字符串）。
    /// 任务要求缺 user 或 host 就 throw——官方虽有缺省值，但按
    /// 任务收紧：user 空着极可能是链接截断，宁可报错也不静默
    /// 用 root 去连。sni 参数无法映射：ssh 出站根本没有 tls
    /// 字段（官方页无此字段），sni 在此直接丢弃，见汇报。
    static func sshOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "ssh" else {
            throw CZFSingBoxConfigError.unsupportedScheme("ssh")
        }
        guard let user = comps.user, !user.isEmpty else {
            throw CZFSingBoxConfigError.missingField("user")
        }
        let server = try requireHost(comps)
        // 端口缺省 22（官方文档原话），不 throw。
        let port = comps.port ?? 22
        guard (1...65535).contains(port) else {
            throw CZFSingBoxConfigError.invalidValue("server_port")
        }
        let map = CZFSingBoxRouting.queryMap(of: link)
        var out: [String: Any] = [
            "type": "ssh",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "user": user,
        ]
        if let password = comps.password { out["password"] = password }
        if let key = CZFSingBoxRouting.firstQuery(map, "private-key", "private_key"), !key.isEmpty {
            out["private_key"] = key
        }
        let hostKeys = splitList(map, "host-key", "host_key")
        if !hostKeys.isEmpty { out["host_key"] = hostKeys }
        return out
    }

    /// http：官方 outbound/http（server / server_port 必填，
    /// username / password 为 Basic 认证，tls 可选）。
    /// tls.enabled 按 query 的 tls 参数（1/true/yes/tls 为真，
    /// 缺省 false）；insecure 进 tls.insecure。tls 块恒写，
    /// 即使 enabled=false 也写明，不让调用方猜默认值。
    static func httpOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "http" else {
            throw CZFSingBoxConfigError.unsupportedScheme("http")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        let tlsRaw = CZFSingBoxRouting.firstQuery(map, "tls")?.lowercased() ?? ""
        let tlsEnabled = tlsRaw == "1" || tlsRaw == "true" || tlsRaw == "yes" || tlsRaw == "tls"
        var out: [String: Any] = [
            "type": "http",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
        ]
        if let user = comps.user, !user.isEmpty { out["username"] = user }
        if let password = comps.password { out["password"] = password }
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure, enabled: tlsEnabled)
        return out
    }

    /// anytls：官方 outbound/anytls（自 1.12.0；server /
    /// server_port / password / tls 均必填；密码在 userinfo 的
    /// user 位，即 anytls://password@host:port）。
    static func anytlsOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "anytls" else {
            throw CZFSingBoxConfigError.unsupportedScheme("anytls")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        let password = (comps.user?.isEmpty == false ? comps.user : nil)
            ?? CZFSingBoxRouting.firstQuery(map, "password")
        guard let password = password, !password.isEmpty else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        var out: [String: Any] = [
            "type": "anytls",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "password": password,
        ]
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    /// shadowtls：官方 outbound/shadowtls（server / server_port /
    /// tls 必填；version ∈ 1/2/3，缺省 1；password 仅 v2/v3 有）。
    /// 注意：出站页根本没有 handshake 字段——handshake 是入站侧
    /// 的概念（tls 握手的目标就是 tls.server_name，即 sni），
    /// 出站写 handshake 反而会过不了 CheckConfig，所以不写。
    /// “缺一不可”的字段是 server / server_port / tls，以及
    /// v2/v3 的 password，缺了就 throw。
    static func shadowtlsOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "shadowtls" else {
            throw CZFSingBoxConfigError.unsupportedScheme("shadowtls")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        var version = 1
        if let raw = CZFSingBoxRouting.firstQuery(map, "version", "v"), let v = Int(raw) {
            version = v
        } else if CZFSingBoxRouting.firstQuery(map, "version", "v") != nil {
            throw CZFSingBoxConfigError.invalidValue("version")
        }
        guard version == 1 || version == 2 || version == 3 else {
            throw CZFSingBoxConfigError.invalidValue("version")
        }
        let password = comps.user ?? ""
        if version >= 2 && password.isEmpty {
            throw CZFSingBoxConfigError.missingField("password")
        }
        var out: [String: Any] = [
            "type": "shadowtls",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "version": version,
        ]
        if !password.isEmpty { out["password"] = password }
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    /// snell：官方 outbound/snell（自 1.14.0；server / server_port /
    /// version / psk 必填）。1.14 页只列 version 4 与 6（旧文档
    /// 的 1/2/3/5 已不在列；文档原话：v5 线路与 v4 相同，不再
    /// 单设 v5 客户端——所以链接 version=5 按 4 计，其余非法值
    /// throw）。缺省 version=4（1.14 页的结构示例即 4；文档虽
    /// 标必填，但链接常省略，写 4 是客户端通用缺省，见汇报）。
    /// v4 专属：obfs_mode（none/http）/ obfs_host；v6 专属：
    /// mode（default/unshaped/unsafe-raw）；跨版本的 obfs 参数
    /// 直接丢弃，不跨版本硬塞（塞错字段 CheckConfig 会报错）。
    static func snellOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "snell" else {
            throw CZFSingBoxConfigError.unsupportedScheme("snell")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let psk = (comps.user?.isEmpty == false ? comps.user : nil)
            ?? CZFSingBoxRouting.firstQuery(map, "psk")
        guard let psk = psk, !psk.isEmpty else {
            throw CZFSingBoxConfigError.missingField("psk")
        }
        var version = 4
        if let raw = CZFSingBoxRouting.firstQuery(map, "version"), let v = Int(raw) {
            if v == 5 {
                version = 4
            } else if v == 4 || v == 6 {
                version = v
            } else {
                throw CZFSingBoxConfigError.invalidValue("version")
            }
        } else if CZFSingBoxRouting.firstQuery(map, "version") != nil {
            throw CZFSingBoxConfigError.invalidValue("version")
        }
        var out: [String: Any] = [
            "type": "snell",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "version": version,
            "psk": psk,
        ]
        if let userkey = CZFSingBoxRouting.firstQuery(map, "userkey"), !userkey.isEmpty {
            out["userkey"] = userkey
        }
        if version == 4 {
            if let obfs = CZFSingBoxRouting.firstQuery(map, "obfs"), !obfs.isEmpty {
                guard obfs == "none" || obfs == "http" else {
                    throw CZFSingBoxConfigError.invalidValue("obfs")
                }
                out["obfs_mode"] = obfs
            }
            if let host = CZFSingBoxRouting.firstQuery(map, "obfs-host", "obfs_host"), !host.isEmpty {
                out["obfs_host"] = host
            }
        } else if version == 6 {
            if let mode = CZFSingBoxRouting.firstQuery(map, "mode"), !mode.isEmpty {
                guard mode == "default" || mode == "unshaped" || mode == "unsafe-raw" else {
                    throw CZFSingBoxConfigError.invalidValue("mode")
                }
                out["mode"] = mode
            }
        }
        return out
    }

    /// V2Ray 系传输块（vless / trojan 共用；vmess 仍用自己那份
    /// ws 代码，不动它）。只映射 tcp（不写块）/ ws / grpc /
    /// httpupgrade；xhttp 绝不能进 sing-box（到这里说明调用方
    /// 没先查 unsupportedReason），其它类型一律 throw——丢弃
    /// 未知传输会拼出一个 TCP 配置去连 WS 节点，静默错配
    /// 比明说“type 不合法”更坏。
    static func v2rayTransport(map: [String: [String]]) throws -> [String: Any]? {
        let type = CZFSingBoxRouting.firstQuery(map, "type")?.lowercased() ?? ""
        switch type {
        case "", "tcp", "none":
            return nil
        case "ws", "websocket":
            var t: [String: Any] = ["type": "ws"]
            if let path = CZFSingBoxRouting.firstQuery(map, "path"), !path.isEmpty {
                t["path"] = path
            }
            if let host = CZFSingBoxRouting.firstQuery(map, "host"), !host.isEmpty {
                t["headers"] = ["Host": host]
            }
            return t
        case "grpc":
            var t: [String: Any] = ["type": "grpc"]
            if let svc = CZFSingBoxRouting.firstQuery(map, "serviceName", "service_name"), !svc.isEmpty {
                t["service_name"] = svc
            }
            return t
        case "httpupgrade":
            var t: [String: Any] = ["type": "httpupgrade"]
            if let host = CZFSingBoxRouting.firstQuery(map, "host"), !host.isEmpty {
                t["host"] = host
            }
            if let path = CZFSingBoxRouting.firstQuery(map, "path"), !path.isEmpty {
                t["path"] = path
            }
            return t
        default:
            throw CZFSingBoxConfigError.invalidValue("type")
        }
    }

    /// vless（只给分流到 sing-box 的那部分用：xhttp 之外含
    /// allowInsecure 的；其余 vless 走 Xray，不进这里）。
    /// 官方 outbound/vless：server / server_port / uuid 必填，
    /// flow 只认 xtls-rprx-vision / xtls-rprx-vision-udp443，
    /// security=tls → tls 块，security=reality → tls.reality 块
    /// （pbk 必填、sni 必填、sid 可选），security=none → 明文，
    /// security 缺省时有 sni/alpn/insecure 任一按 tls 处理。
    /// fp/fingerprint 照例丢弃（不构建 with_utls）。
    static func vlessOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "vless" else {
            throw CZFSingBoxConfigError.unsupportedScheme("vless")
        }
        guard let uuid = comps.user, !uuid.isEmpty else {
            throw CZFSingBoxConfigError.missingField("uuid")
        }
        guard UUID(uuidString: uuid) != nil else {
            throw CZFSingBoxConfigError.invalidValue("uuid")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        var out: [String: Any] = [
            "type": "vless",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "uuid": uuid,
        ]
        if let flow = CZFSingBoxRouting.firstQuery(map, "flow"), !flow.isEmpty {
            guard flow == "xtls-rprx-vision" || flow == "xtls-rprx-vision-udp443" else {
                throw CZFSingBoxConfigError.invalidValue("flow")
            }
            out["flow"] = flow
        }
        let tlsP = tlsParams(map)
        switch CZFSingBoxRouting.firstQuery(map, "security")?.lowercased() {
        case "reality":
            guard let pbk = CZFSingBoxRouting.firstQuery(map, "pbk"), !pbk.isEmpty else {
                throw CZFSingBoxConfigError.missingField("pbk")
            }
            guard let sni = tlsP.serverName, !sni.isEmpty else {
                throw CZFSingBoxConfigError.missingField("sni")
            }
            var tls = tlsBlock(serverName: sni, alpn: tlsP.alpn, insecure: tlsP.insecure)
            var reality: [String: Any] = ["enabled": true, "public_key": pbk]
            if let sid = CZFSingBoxRouting.firstQuery(map, "sid"), !sid.isEmpty {
                reality["short_id"] = sid
            }
            tls["reality"] = reality
            out["tls"] = tls
        case "tls":
            out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        case "none":
            break
        case nil:
            if tlsP.serverName != nil || !tlsP.alpn.isEmpty || tlsP.insecure {
                out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
            }
        default:
            throw CZFSingBoxConfigError.invalidValue("security")
        }
        if let transport = try v2rayTransport(map: map) {
            out["transport"] = transport
        }
        return out
    }

    /// trojan（只给含 allowInsecure 的那部分用；其余 trojan 走
    /// Xray，不进这里）。官方 outbound/trojan：server /
    /// server_port / password 必填，tls 恒启用；security=reality
    /// 时加 tls.reality 块（pbk 必填、sni 必填，与 vless 同理）。
    /// 密码取 userinfo 的 password 位，没有则取 user 位
    /// （trojan://密码@host 形只有 user 位）。
    static func trojanOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "trojan" else {
            throw CZFSingBoxConfigError.unsupportedScheme("trojan")
        }
        guard let password = (comps.password?.isEmpty == false ? comps.password : comps.user),
              !password.isEmpty else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        var out: [String: Any] = [
            "type": "trojan",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "password": password,
        ]
        if CZFSingBoxRouting.firstQuery(map, "security")?.lowercased() == "reality" {
            guard let pbk = CZFSingBoxRouting.firstQuery(map, "pbk"), !pbk.isEmpty else {
                throw CZFSingBoxConfigError.missingField("pbk")
            }
            guard let sni = tlsP.serverName, !sni.isEmpty else {
                throw CZFSingBoxConfigError.missingField("sni")
            }
            var tls = tlsBlock(serverName: sni, alpn: tlsP.alpn, insecure: tlsP.insecure)
            var reality: [String: Any] = ["enabled": true, "public_key": pbk]
            if let sid = CZFSingBoxRouting.firstQuery(map, "sid"), !sid.isEmpty {
                reality["short_id"] = sid
            }
            tls["reality"] = reality
            out["tls"] = tls
        } else {
            out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        }
        if let transport = try v2rayTransport(map: map) {
            out["transport"] = transport
        }
        return out
    }

    /// hysteria2（只给含 allowInsecure 的那部分用；其余 hy2 走
    /// Xray，不进这里）。官方 outbound/hysteria2：server /
    /// server_port / password 必填，tls 恒启用（QUIC 必需）；
    /// obfs 只有 salamander 一种，写了 obfs 没写 obfs-password
    /// 按官方“构造失败”处理为 throw；up/down 只认纯整数
    /// （认不出就丢弃，不编造带宽值——brutal 与否属未验证）。
    /// 密码取法与 trojan 同理（password 位优先，没有取 user 位）。
    static func hysteria2Outbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link),
              comps.scheme?.lowercased() == "hysteria2" || comps.scheme?.lowercased() == "hy2" else {
            throw CZFSingBoxConfigError.unsupportedScheme("hysteria2")
        }
        guard let password = (comps.password?.isEmpty == false ? comps.password : comps.user),
              !password.isEmpty else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        var out: [String: Any] = [
            "type": "hysteria2",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "password": password,
        ]
        if let obfs = CZFSingBoxRouting.firstQuery(map, "obfs"), !obfs.isEmpty {
            guard obfs == "salamander" else {
                throw CZFSingBoxConfigError.invalidValue("obfs")
            }
            guard let obfsPassword = CZFSingBoxRouting.firstQuery(map, "obfs-password", "obfs_password"),
                  !obfsPassword.isEmpty else {
                throw CZFSingBoxConfigError.missingField("obfs-password")
            }
            out["obfs"] = ["type": "salamander", "password": obfsPassword]
        }
        if let up = CZFSingBoxRouting.firstQuery(map, "up"), let v = Int(up) {
            out["up_mbps"] = v
        }
        if let down = CZFSingBoxRouting.firstQuery(map, "down"), let v = Int(down) {
            out["down_mbps"] = v
        }
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    // MARK: 老 vmess / 老 SS（分流到 sing-box 的那部分）

    /// vmess 允许的 security（官方 outbound/vmess：auto / none /
    /// zero / aes-128-gcm / chacha20-poly1305，legacy 另有
    /// aes-128-ctr；任务清单与此一致，非法值 throw）。
    private static let vmessSecurities: Set<String> = [
        "auto", "none", "zero", "aes-128-gcm",
        "chacha20-poly1305", "aes-128-ctr",
    ]

    /// vmess URL 形出站。uuid 校验与 tuic 同理（UUID 格式非法就
    /// throw，不带值）。transport 目前只映射最常见的 ws（path +
    /// Host 头）；其它 net/type 直接丢弃，不猜 grpc/quic 字段。
    static func vmessURLOutbound(comps: URLComponents, map: [String: [String]]) throws -> [String: Any] {
        guard let uuid = comps.user, !uuid.isEmpty else {
            throw CZFSingBoxConfigError.missingField("uuid")
        }
        guard UUID(uuidString: uuid) != nil else {
            throw CZFSingBoxConfigError.invalidValue("uuid")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        var security = CZFSingBoxRouting.firstQuery(map, "encryption", "security")?.lowercased() ?? "auto"
        if security.isEmpty { security = "auto" }
        guard vmessSecurities.contains(security) else {
            throw CZFSingBoxConfigError.invalidValue("security")
        }
        var out: [String: Any] = [
            "type": "vmess",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "security": security,
        ]
        if let raw = CZFSingBoxRouting.firstQuery(map, "aid", "alterId", "alter_id"),
           let alter = Int(raw), alter > 0 {
            out["alter_id"] = alter
        }
        let type = CZFSingBoxRouting.firstQuery(map, "type")?.lowercased() ?? ""
        if type == "ws" {
            var transport: [String: Any] = ["type": "ws"]
            if let path = CZFSingBoxRouting.firstQuery(map, "path"), !path.isEmpty {
                transport["path"] = path
            }
            if let wsHost = CZFSingBoxRouting.firstQuery(map, "host"), !wsHost.isEmpty {
                transport["headers"] = ["Host": wsHost]
            }
            out["transport"] = transport
        }
        let tlsRaw = CZFSingBoxRouting.firstQuery(map, "tls")?.lowercased() ?? ""
        if tlsRaw == "tls" || tlsRaw == "1" || tlsRaw == "true" || tlsRaw == "yes" {
            let sni = CZFSingBoxRouting.firstQuery(map, "sni", "server_name")
                ?? CZFSingBoxRouting.firstQuery(map, "host")
            let insecure = CZFSingBoxRouting.boolQuery(map, "allow_insecure", "insecure", "skip-cert-verify")
            out["tls"] = tlsBlock(serverName: sni, alpn: alpnList(map), insecure: insecure)
        }
        return out
    }

    /// vmess Base64(JSON) 形出站。字段：add（或 address）/ port /
    /// id / aid（或 alterId；>0 才写 alter_id，=0 不写即 AEAD）/
    /// scy（或 security）/ net / type / host / path / tls / sni。
    /// v 字段只认“2 的标准 JSON”这一事实，不校验、不分支。
    static func vmessJSONOutbound(dict: [String: Any]) throws -> [String: Any] {
        guard let server = stringValue(dict["add"] ?? dict["address"]), !server.isEmpty else {
            throw CZFSingBoxConfigError.missingField("add")
        }
        guard let port = intValue(dict["port"]), (1...65535).contains(port) else {
            throw CZFSingBoxConfigError.invalidValue("port")
        }
        guard let uuid = stringValue(dict["id"]), !uuid.isEmpty else {
            throw CZFSingBoxConfigError.missingField("id")
        }
        guard UUID(uuidString: uuid) != nil else {
            throw CZFSingBoxConfigError.invalidValue("uuid")
        }
        var security = (stringValue(dict["scy"] ?? dict["security"])?.lowercased() ?? "auto")
        if security.isEmpty { security = "auto" }
        guard vmessSecurities.contains(security) else {
            throw CZFSingBoxConfigError.invalidValue("security")
        }
        var out: [String: Any] = [
            "type": "vmess",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "security": security,
        ]
        if let alter = intValue(dict["aid"] ?? dict["alterId"] ?? dict["alter_id"]), alter > 0 {
            out["alter_id"] = alter
        }
        let net = stringValue(dict["net"])?.lowercased() ?? ""
        if net == "ws" {
            var transport: [String: Any] = ["type": "ws"]
            if let path = stringValue(dict["path"]), !path.isEmpty { transport["path"] = path }
            if let wsHost = stringValue(dict["host"]), !wsHost.isEmpty {
                transport["headers"] = ["Host": wsHost]
            }
            out["transport"] = transport
        }
        let tlsRaw = stringValue(dict["tls"])?.lowercased() ?? ""
        if tlsRaw == "tls" {
            let sni = stringValue(dict["sni"]) ?? stringValue(dict["host"])
            // JSON 里的 insecure 可能是布尔 true，也可能是字符串 "1"。
            let insecure = (dict["allow_insecure"] as? Bool) == true
                || (dict["insecure"] as? Bool) == true
                || stringValue(dict["allow_insecure"])?.lowercased() == "1"
                || stringValue(dict["insecure"])?.lowercased() == "1"
            out["tls"] = tlsBlock(serverName: sni, alpn: [], insecure: insecure)
        }
        return out
    }

    /// vmess 总入口：:// 之后、? 之前含 @ → URL 形，否则 Base64(JSON) 形。
    /// Base64 字母表里没有 @，这个区分是安全的。
    static func vmessOutbound(link: String) throws -> [String: Any] {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://") else {
            throw CZFSingBoxConfigError.unsupportedScheme("vmess")
        }
        let after = String(trimmed[range.upperBound...])
        let beforeQuery = after.split(separator: "?", maxSplits: 1).first.map(String.init) ?? after
        if beforeQuery.contains("@") {
            guard let comps = components(of: link) else {
                throw CZFSingBoxConfigError.invalidValue("vmess 链接")
            }
            return try vmessURLOutbound(comps: comps, map: CZFSingBoxRouting.queryMap(of: link))
        }
        guard let dict = decodeBase64JSON(after) else {
            throw CZFSingBoxConfigError.invalidValue("vmess 链接")
        }
        return try vmessJSONOutbound(dict: dict)
    }

    /// ss 总入口，覆盖三种写法：
    /// (a) ss://method:password@host:port（明文 userinfo）；
    /// (b) ss://Base64(method:password)@host:port（Base64 userinfo）；
    /// (c) ss://Base64(method:password@host:port)（整段 Base64）。
    /// method 原样透传（AEAD 与旧加密方法都不校验白名单，错了
    /// 由 CheckConfig 报错）。plugin 按 SIP003 拆：plugin= 首次
    /// 分号前为 plugin，之后为 plugin_opts；没有就不写。
    /// 密码含 %XX 时不二次解码（URLComponents 已解一次）。
    static func shadowsocksOutbound(link: String) throws -> [String: Any] {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = components(of: link), comps.scheme?.lowercased() == "ss" else {
            throw CZFSingBoxConfigError.unsupportedScheme("ss")
        }
        let map = CZFSingBoxRouting.queryMap(of: link)
        var method: String?
        var password: String?
        var server: String?
        var port: Int?

        if let user = comps.user, !user.isEmpty {
            // (a) 明文或 (b) Base64 userinfo：先试 Base64 解码，
            // 解出含冒号的 method:password 才算 Base64 形，否则按明文。
            // 必须加可打印字符 + 方法名字符集双重校验：明文方法名
            // （如 aes-256-gcm）本身也能 Base64 解出乱码，乱码里
            // 偶然含冒号时会被误判成 Base64 形，方法名就错了。
            if let data = decodeBase64(user),
               let decoded = String(data: data, encoding: .utf8),
               decoded.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }),
               let colon = decoded.firstIndex(of: ":"),
               !String(decoded[..<colon]).isEmpty,
               String(decoded[..<colon]).unicodeScalars.allSatisfy({
                   $0.value >= 0x30 && $0.value <= 0x39
                       || $0.value >= 0x41 && $0.value <= 0x5A
                       || $0.value >= 0x61 && $0.value <= 0x7A
                       || $0.value == 0x2D || $0.value == 0x5F || $0.value == 0x2E
               }) {
                method = String(decoded[..<colon])
                password = String(decoded[decoded.index(after: colon)...])
            } else {
                method = user
                password = comps.password
            }
            server = comps.host
            port = comps.port
        } else if let hostBlob = comps.host, !hostBlob.isEmpty {
            // (c) 整段 Base64：解出 method:password@host:port，
            // 密码里可含 @，所以按最后一个 @ 拆 userinfo/地址。
            guard let data = decodeBase64(hostBlob),
                  let decoded = String(data: data, encoding: .utf8),
                  let at = decoded.lastIndex(of: "@") else {
                throw CZFSingBoxConfigError.invalidValue("ss 链接")
            }
            let userinfo = String(decoded[..<at])
            let addr = String(decoded[decoded.index(after: at)...])
            guard let colon = userinfo.firstIndex(of: ":") else {
                throw CZFSingBoxConfigError.invalidValue("ss 链接")
            }
            method = String(userinfo[..<colon])
            password = String(userinfo[userinfo.index(after: colon)...])
            guard let parsed = splitHostPort(addr), !parsed.host.isEmpty, let p = parsed.port else {
                throw CZFSingBoxConfigError.invalidValue("ss 链接")
            }
            server = parsed.host
            port = p
        }
        guard let finalMethod = method, !finalMethod.isEmpty else {
            throw CZFSingBoxConfigError.missingField("method")
        }
        guard let finalServer = server, !finalServer.isEmpty else {
            throw CZFSingBoxConfigError.missingField("server")
        }
        guard let finalPort = port, (1...65535).contains(finalPort) else {
            throw CZFSingBoxConfigError.invalidValue("server_port")
        }
        var out: [String: Any] = [
            "type": "shadowsocks",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": finalServer,
            "server_port": finalPort,
            "method": finalMethod,
            "password": password ?? "",
        ]
        if let plugin = CZFSingBoxRouting.firstQuery(map, "plugin"), !plugin.isEmpty {
            if let semi = plugin.firstIndex(of: ";") {
                out["plugin"] = String(plugin[..<semi])
                out["plugin_opts"] = String(plugin[plugin.index(after: semi)...])
            } else {
                out["plugin"] = plugin
            }
        }
        return out
    }

    // MARK: 对外接口

    /// 生成完整 sing-box 配置 JSON（JSONSerialization，sortedKeys）。
    /// 固定骨架：log.level=warning（不写 log.output 文件）；
    /// dns.servers=[{tag:local,type:local}] + final=local；
    /// inbounds：mixed（listen 127.0.0.1，listen_port=socksPort），
    /// httpPort 非 nil 时再加一个 http 入站（listen_port=httpPort）；
    /// route.final=node-out。
    /// WireGuard 例外：wireguard 出站已废弃，改走顶层 endpoints，
    /// 此时不写 outbounds 键（tag 命名空间共用，重复会冲突）。
    /// 本函数不复核 coreKind：vmess/ss 即使按分流走 Xray 也能
    /// 生成（sing-box 本身支持），调用方先按 coreKind 分流，
    /// 只在 sing-box 分流时调用；vless/trojan/hysteria2/socks/
    /// json/纯文本等非 sing-box 节点一律 throw notSingBoxNode。
    /// 主用例：socksPort=10827、httpPort=10828；测速临时实例：
    /// socksPort=10927、httpPort=nil（不建 http 入站）。
    public static func configJSON(for link: String, socksPort: Int, httpPort: Int?) throws -> String {
        guard (1...65535).contains(socksPort) else {
            throw CZFSingBoxConfigError.invalidValue("socksPort")
        }
        if let httpPort = httpPort {
            guard (1...65535).contains(httpPort) else {
                throw CZFSingBoxConfigError.invalidValue("httpPort")
            }
        }
        let scheme = CZFSingBoxRouting.scheme(of: link)
        let isWireGuard = scheme == "wireguard"
        let outbound: [String: Any]?
        let endpoint: [String: Any]?
        switch scheme {
        case "tuic":
            outbound = try tuicOutbound(link: link)
            endpoint = nil
        case "hysteria":
            outbound = try hysteriaOutbound(link: link)
            endpoint = nil
        case "wireguard":
            outbound = nil
            endpoint = try wireguardEndpoint(link: link)
        case "naive":
            outbound = try naiveOutbound(link: link)
            endpoint = nil
        case "ssh":
            outbound = try sshOutbound(link: link)
            endpoint = nil
        case "http":
            outbound = try httpOutbound(link: link)
            endpoint = nil
        case "anytls":
            outbound = try anytlsOutbound(link: link)
            endpoint = nil
        case "shadowtls":
            outbound = try shadowtlsOutbound(link: link)
            endpoint = nil
        case "snell":
            outbound = try snellOutbound(link: link)
            endpoint = nil
        case "vless":
            outbound = try vlessOutbound(link: link)
            endpoint = nil
        case "trojan":
            outbound = try trojanOutbound(link: link)
            endpoint = nil
        case "hysteria2", "hy2":
            outbound = try hysteria2Outbound(link: link)
            endpoint = nil
        case "vmess":
            outbound = try vmessOutbound(link: link)
            endpoint = nil
        case "ss":
            outbound = try shadowsocksOutbound(link: link)
            endpoint = nil
        default:
            throw CZFSingBoxConfigError.notSingBoxNode
        }

        var inbounds: [[String: Any]] = [[
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": socksPort,
        ]]
        if let httpPort = httpPort {
            inbounds.append([
                "type": "http",
                "tag": "http-in",
                "listen": "127.0.0.1",
                "listen_port": httpPort,
            ])
        }

        var root: [String: Any] = [
            "log": ["level": "warning"],
            "dns": [
                "servers": [["tag": "local", "type": "local"]],
                "final": "local",
            ],
            "inbounds": inbounds,
            "route": ["final": CZFSingBoxRouting.nodeTag],
        ]
        // 注意：不能把 Optional 直接塞进 JSON（JSONSerialization
        // 不认 Optional，必抛错），这里先解包再放进数组。
        if isWireGuard {
            guard let endpoint = endpoint else { throw CZFSingBoxConfigError.encodingFailed }
            root["endpoints"] = [endpoint]
        } else {
            guard let outbound = outbound else { throw CZFSingBoxConfigError.encodingFailed }
            root["outbounds"] = [outbound]
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CZFSingBoxConfigError.encodingFailed
        }
        return json
    }
}
