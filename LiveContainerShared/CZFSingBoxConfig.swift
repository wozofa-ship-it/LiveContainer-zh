import Foundation

// CZFSingBoxConfig.swift
//
// 职责：sing-box 分流判定 + TUIC 配置 JSON 生成（TUIC-only：
// 245 + 仅 TUIC，sing-box 只跑 TUIC 出站，其余协议一律走
// 245 原有的 Xray 路径）。
// 只含纯函数与静态方法：不调用任何 Libbox/CGo 函数，不碰 UserDefaults，
// 不读写文件、不联网。配置一律用 JSONSerialization 拼（不许字符串插值），
// 密码/密钥里含引号、反斜杠也不会打断 JSON。
//
// 与 CZFVPNManager 的衔接：
// CZFVPNManager.nodeScheme / isSupportedNodeScheme 是协议清单
// （Xray 转换器清单 + TUIC）。
// 本文件的 coreKind 是在其之上的第二层分流：tuic 走 sing-box，
// 其余一律走 Xray（245 原有路径）。调用顺序：先查 coreKind，
// tuic 时生成 sing-box 配置并起 sing-box 核心；非 tuic 时走
// 245 的 Xray 转换与启动，原样不动。
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

    /// 分流主入口（TUIC-only）：tuic 走 sing-box，其余一律
    /// 走 Xray（245 原有路径；Xray 转换器认不认由转换器
    /// 自己决定，这里不替它背书，也不替它拒收）。
    public static func coreKind(for link: String) -> CZFCoreKind {
        if scheme(of: link) == "tuic" { return .singBox }
        return .xray
    }

    /// 行内“不验证书”标记判定：tuic 且含 allowInsecure 时标
    /// （tuic 出站一定写 tls 块，insecure 参数真实生效）。
    /// 调用方是 CZFVPNManager.nodeDisplay（行内 scheme 显示处）。
    public static func showsInsecureMark(for link: String) -> Bool {
        guard scheme(of: link) == "tuic" else { return false }
        return isInsecureNode(link)
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
        guard let password = comps.password else {
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

    // MARK: 对外接口

    /// 生成完整 sing-box 配置 JSON（JSONSerialization，sortedKeys）。
    /// 固定骨架：log.level=warning（不写 log.output 文件）；
    /// dns.servers=[{tag:local,type:local}] + final=local；
    /// inbounds：mixed（listen 127.0.0.1，listen_port=socksPort），
    /// httpPort 非 nil 时再加一个 http 入站（listen_port=httpPort）；
    /// route.final=node-out；outbounds=[tuic 出站]。
    /// 非 tuic 节点一律 throw notSingBoxNode（调用方先按
    /// coreKind 分流，只在 tuic 时调用）。
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
        guard scheme == "tuic" else {
            throw CZFSingBoxConfigError.notSingBoxNode
        }
        let outbound = try tuicOutbound(link: link)

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
        root["outbounds"] = [outbound]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CZFSingBoxConfigError.encodingFailed
        }
        return json
    }

    /// 生成多 TUIC 出站的 sing-box 配置 JSON（测速用，3.8.306）：
    /// 一个临时实例带 N 个 TUIC 出站（tag node-out-<i>）+ N 个
    /// mixed 入站（端口 basePort...basePort+N-1），路由规则把每个
    /// 入站钉到对应的出站，N 个探针并行跑，总耗时 ≈ 最慢的一个
    /// （原来是每节点起一个实例串行测，N 个节点要 N 倍时间）。
    /// 与单节点版同款骨架（log/dns），只是出站/入站/路由按节点数
    /// 展开。links 为空或 basePort + 数量越界时 throw。
    /// 非 tuic 链接一律 throw notSingBoxNode（调用方先按 coreKind
    /// 分流，只把 tuic 链接传进来）。
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
            guard CZFSingBoxRouting.scheme(of: link) == "tuic" else {
                throw CZFSingBoxConfigError.notSingBoxNode
            }
            let tag = "node-out-\(i)"
            let inboundTag = "mixed-in-\(i)"
            outbounds.append(try tuicOutbound(link: link, tag: tag))
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
            "log": ["level": "warning"],
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
