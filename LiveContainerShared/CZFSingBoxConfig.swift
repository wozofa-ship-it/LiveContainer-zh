import Foundation

// CZFSingBoxConfig.swift
//
// 职责：sing-box 分流判定 + TUIC / Hysteria2 配置 JSON 生成
// （TUIC 245 起，Hysteria2 3.8.434 起；sing-box 只跑这两
// 种出站，其余协议一律走 245 原有的 Xray 路径）。
// 只含纯函数与静态方法：不调用任何 Libbox/CGo 函数，不碰 UserDefaults，
// 不读写文件、不联网。配置一律用 JSONSerialization 拼（不许字符串插值），
// 密码/密钥里含引号、反斜杠也不会打断 JSON。
//
// 与 CZFVPNManager 的衔接：
// CZFVPNManager.nodeScheme / isSupportedNodeScheme 是协议清单
// （Xray 转换器清单 + TUIC + Hysteria2）。
// 本文件的 coreKind 是在其之上的第二层分流：tuic / hysteria2 /
// hy2 走 sing-box，其余一律走 Xray（245 原有路径）。调用顺序：
// 先查 coreKind，sing-box 时生成 sing-box 配置并起 sing-box
// 核心；非 sing-box 时走 245 的 Xray 转换与启动，原样不动。
// 本地无 Swift 工具链：括号平衡 ≠ 编译通过，需 CI 验证。

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

    /// 节点出站的统一 tag。
    static let nodeTag = "node-out"

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

    // MARK: 对外接口

    /// 分流主入口：tuic / hysteria2 / hy2 走 sing-box，其余一律
    /// 走 Xray。hysteria2 本来也在 Xray 转换器清单里，但实测
    /// 转换器转不动（用户 2026-11-12 报全部 hysteria2 节点
    /// “不支持”）；sing-box v1.14.4 内置 hysteria2 出站，改走
    /// sing-box 才能连上。Xray 转换器认不认由转换器自己决定，
    /// 这里不替它背书，也不替它拒收。
    public static func coreKind(for link: String) -> CZFCoreKind {
        switch scheme(of: link) {
        case "tuic", "hysteria2", "hy2": return .singBox
        default: return .xray
        }
    }

    /// 行内“不验证书”标记判定：tuic / hysteria2 且跳过证书验证
    /// 时标。hysteria2 带 pinSHA256 时也标（sing-box 无法钉扎，
    /// 见 hysteria2Outbound，只能跳过验证，同样是不验证书）。
    /// 调用方是 CZFVPNManager.nodeDisplay（行内 scheme 显示处）。
    public static func showsInsecureMark(for link: String) -> Bool {
        let s = scheme(of: link)
        guard s == "tuic" || s == "hysteria2" || s == "hy2" else { return false }
        if isInsecureNode(link) { return true }
        if s != "tuic" {
            let map = queryMap(of: link)
            if firstQuery(map, "pinSHA256", "pinsha256") != nil { return true }
        }
        return false
    }
}

// MARK: - 配置生成

public enum CZFSingBoxConfig {

    // MARK: 通用解析工具（全部只抛“缺什么/哪项不合法”，绝不带凭证值）

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

    // MARK: TUIC 出站（字段名后都注了文档依据）

    /// tuic：照抄 TUICLink 语义（官方 outbound/tuic：server /
    /// server_port 必填，uuid 必填，password，congestion_control
    /// ∈ cubic/new_reno/bbr，udp_relay_mode ∈ native/quic，tls 必填）。
    /// tag 默认 node-out；多出站测速时调用方传 node-out-<i>。
    static func tuicOutbound(link: String, tag: String = CZFSingBoxRouting.nodeTag) throws -> [String: Any] {
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
        // L14-5：原来只判 password 为 nil 不判空串，tuic://uuid:@host:port
        // 会生成带空密码的配置，核心起不来才报错；与同文件 hysteria2Outbound
        //（空密码抛 missingField）不一致，TUIC 协议要求密码，空密码恒非法。
        // 3.8.495（L14）
        guard let password = comps.password, !password.isEmpty else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        var out: [String: Any] = [
            "type": "tuic",
            "tag": tag,
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

    // MARK: Hysteria2 出站（字段名后都注了文档依据）

    /// hysteria2：sing-box outbound/hysteria2（v1.14.4 内置）：
    /// server / server_port / password 必填，tls 必填（Hysteria2
    /// 强制 TLS，enabled 恒 true）；server_ports 端口跳跃（1.11+
    /// 才认，本工程 1.14.4）；obfs 只认 salamander / gecko
    /// （sing-box 1.14 起 gecko 同款 type+password；其它值直接
    /// 抛 invalidValue("obfs")，不静默丢弃——O-6：以前非
    /// salamander 的值既不进配置也不报错，节点假装能连）。
    /// 链接格式 hysteria2://PASSWORD@host:port?sni=&insecure=&
    /// pinSHA256=&mport=61000-62000#名，hy2 是同协议别名。
    /// password 在 userinfo：user 即密码，含冒号时整串
    /// user:password 都是密码（照抄 tuic 的“不二次解码”）。
    /// pinSHA256：sing-box 出站 TLS 没有证书钉扎字段（转换器
    /// 圈子公认：钉扎无等价字段，丢了等于降级）；链接带钉扎说
    /// 明服务端证书不是公开可验的，留 insecure=false 会握手
    /// 失败，只能跳过验证才能连上——宁可连上也不让节点继续
    /// 显示“不支持”。mport=61000-62000 → server_ports=
    /// ["61000:62000"]（分隔符 hyphen 变 colon）；格式不对就
    /// 跳过，只用主端口。
    /// tag 默认 node-out；多出站测速时调用方传 node-out-<i>。
    static func hysteria2Outbound(link: String, tag: String = CZFSingBoxRouting.nodeTag) throws -> [String: Any] {
        guard let comps = components(of: link), ["hysteria2", "hy2"].contains(comps.scheme?.lowercased() ?? "") else {
            throw CZFSingBoxConfigError.unsupportedScheme("hysteria2")
        }
        var passwordParts: [String] = []
        if let user = comps.user, !user.isEmpty { passwordParts.append(user) }
        if let pwd = comps.password, !pwd.isEmpty { passwordParts.append(pwd) }
        let password = passwordParts.joined(separator: ":")
        guard !password.isEmpty else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        let hasPin = CZFSingBoxRouting.firstQuery(map, "pinSHA256", "pinsha256") != nil
        let insecure = tlsP.insecure || hasPin
        var out: [String: Any] = [
            "type": "hysteria2",
            "tag": tag,
            "server": server,
            "server_port": port,
            "password": password,
        ]
        if let mport = CZFSingBoxRouting.firstQuery(map, "mport"), !mport.isEmpty {
            let parts = mport.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]),
               (1...65535).contains(lo), (1...65535).contains(hi), lo <= hi {
                out["server_ports"] = ["\(lo):\(hi)"]
            }
        }
        if let obfs = CZFSingBoxRouting.firstQuery(map, "obfs") {
            // O-6：obfs 只认 salamander / gecko（gecko 与
            // salamander 同款 type+password）；其它值直接抛错，
            // 让节点在测速/启动前就显示“不支持”，而不是生成
            // 一个没 obfs 块的配置假装能连。salamander / gecko
            // 没给密码时沿用老行为：不写 obfs 块、不抛错。
            let kind = obfs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard kind == "salamander" || kind == "gecko" else {
                throw CZFSingBoxConfigError.invalidValue("obfs")
            }
            if let obfsPwd = CZFSingBoxRouting.firstQuery(map, "obfs-password", "obfs_password"), !obfsPwd.isEmpty {
                out["obfs"] = ["type": kind, "password": obfsPwd] as [String: Any]
            }
        }
        if let up = CZFSingBoxRouting.firstQuery(map, "up_mbps", "up"), let upInt = Int(up) {
            out["up_mbps"] = upInt
        }
        if let down = CZFSingBoxRouting.firstQuery(map, "down_mbps", "down"), let downInt = Int(down) {
            out["down_mbps"] = downInt
        }
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: insecure)
        return out
    }

    /// 按 scheme 分发到对应的出站生成器（tuic / hysteria2 / hy2）。
    /// 其余 scheme 一律 throw notSingBoxNode（调用方先按 coreKind
    /// 分流，只把 sing-box 链接传进来）。
    static func outbound(for link: String, tag: String = CZFSingBoxRouting.nodeTag) throws -> [String: Any] {
        switch CZFSingBoxRouting.scheme(of: link) {
        case "tuic": return try tuicOutbound(link: link, tag: tag)
        case "hysteria2", "hy2": return try hysteria2Outbound(link: link, tag: tag)
        default: throw CZFSingBoxConfigError.notSingBoxNode
        }
    }

    // MARK: 对外接口

    /// sing-box 日志落盘路径（O-7）：Documents/singbox/sing-box.log
    /// 的绝对路径。只算路径字符串，不读写文件。必须用绝对路径：
    /// 相对路径由进程 cwd 解析，iOS 上 cwd 不保证是沙盒根，
    /// 写 "Documents/..." 相对路径可能落到 /Documents 去、甚至
    /// 让核心启动失败；绝对路径一定落在 Documents/singbox 下。
    /// 目录由 CZFSingBoxCore.setupIfNeeded 在 start 前建好。
    public static var singBoxLogPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("singbox/sing-box.log").path
    }

    /// 生成完整 sing-box 配置 JSON（JSONSerialization，sortedKeys）。
    /// 固定骨架：log.level=info + log.output 落盘到
    /// Documents/singbox/sing-box.log（O-7；原来是 warning 且
    /// 不写文件，节点断流时无据可查）；
    /// dns.servers=[{tag:local,type:local}] + final=local；
    /// inbounds：mixed（listen 127.0.0.1，listen_port=socksPort），
    /// httpPort 非 nil 时再加一个 http 入站（listen_port=httpPort）；
    /// route.final=node-out；outbounds=[tuic / hysteria2 出站]。
    /// 非 sing-box 节点一律 throw notSingBoxNode（调用方先按
    /// coreKind 分流，只在 sing-box 时调用）。
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
        let outbound = try outbound(for: link)

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
            "log": ["level": "info", "output": singBoxLogPath],
            "dns": [
                "servers": [["tag": "local", "type": "local"]],
                "final": "local",
            ],
            "inbounds": inbounds,
            "route": ["final": CZFSingBoxRouting.nodeTag],
        ]
        // 注意：不能把 Optional 直接塞进 JSON（JSONSerialization
        // 不认 Optional，必抛错），这里先解包再放进数组。
        root["outbounds"] = [outbound]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CZFSingBoxConfigError.encodingFailed
        }
        return json
    }

    /// 生成多 sing-box 出站的 sing-box 配置 JSON（测速用，3.8.306）：
    /// 一个临时实例带 N 个出站（tag node-out-<i>）+ N 个
    /// mixed 入站（端口 basePort...basePort+N-1），路由规则把每个
    /// 入站钉到对应的出站，N 个探针并行跑，总耗时 ≈ 最慢的一个
    /// （原来是每节点起一个实例串行测，N 个节点要 N 倍时间）。
    /// 与单节点版同款骨架（log/dns），只是出站/入站/路由按节点数
    /// 展开。links 为空或 basePort + 数量越界时 throw。
    /// 非 sing-box 链接一律 throw notSingBoxNode（调用方先按 coreKind
    /// 分流，只把 sing-box 链接传进来）。
    public static func configJSON(for links: [String], basePort: Int) throws -> String {
        guard !links.isEmpty else {
            throw CZFSingBoxConfigError.missingField("links")
        }
        guard (1...65535).contains(basePort), basePort + links.count - 1 <= 65535 else {
            throw CZFSingBoxConfigError.invalidValue("basePort")
        }
        var outbounds: [[String: Any]] = []
        var inbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        for (i, link) in links.enumerated() {
            let tag = "node-out-\(i)"
            let inboundTag = "mixed-in-\(i)"
            outbounds.append(try outbound(for: link, tag: tag))
            inbounds.append([
                "type": "mixed",
                "tag": inboundTag,
                "listen": "127.0.0.1",
                "listen_port": basePort + i,
            ])
            rules.append([
                "inbound": [inboundTag],
                "outbound": tag,
            ])
        }
        var root: [String: Any] = [
            "log": ["level": "info", "output": singBoxLogPath],
            "dns": [
                "servers": [["tag": "local", "type": "local"]],
                "final": "local",
            ],
            "inbounds": inbounds,
            "route": [
                "rules": rules,
                "final": "node-out-0",
            ],
        ]
        root["outbounds"] = outbounds
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CZFSingBoxConfigError.encodingFailed
        }
        return json
    }
}
