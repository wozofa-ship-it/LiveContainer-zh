// CZFClashYAML.swift
// Clash / mihomo YAML 订阅里的 proxies 段转标准 share-link。
// 纯函数：不碰 UserDefaults、不碰网络、不调用 Libbox、不抛异常。
// 输出直接是标准 share-link 字符串，调用方走现有 addNode / 去重，
// 不依赖 CZFVPNManager.normalizedShareLink 再加工（它只处理
// vless / trojan 老格式）。
// 注意：iOS SDK 没有 YAML 库，这里是手写最小子集解析器，只认
// 顶层 proxies: 数组；其余段（proxy-groups、rules、port 等）
// 一律忽略。格式错的项计入 skipped，不 throw、不 crash。

import Foundation

enum CZFClashYAML {

    /// 解析 Clash YAML 文本。
    /// - 返回：links 为转换出的标准 share-link；skipped 为丢弃的
    ///   proxy 项数（格式错、无 type、无 server、port 非法、
    ///   不支持的 type、必填字段缺失都按 1 项计）。
    static func parse(_ text: String) -> (links: [String], skipped: Int) {
        var links: [String] = []
        var skipped = 0
        let items = parseProxyItems(text)
        for item in items {
            if let link = link(from: item) {
                links.append(link)
            } else {
                skipped += 1
            }
        }
        return (links, skipped)
    }

    // MARK: - 最小 YAML 子集解析

    /// 一项 proxy 的平铺键值表。嵌套 map 用点号拼键：
    /// ws-opts.path、ws-opts.headers.Host、grpc-opts.grpc-service-name、
    /// reality-opts.public-key 等；alpn 这类行内 / 块列表拼成逗号串。
    private typealias ProxyDict = [String: String]

    private static func parseProxyItems(_ text: String) -> [ProxyDict] {
        var items: [ProxyDict] = []
        var current: ProxyDict = [:]
        var hasCurrent = false
        // 嵌套栈：(缩进, 完整键路径)，只支持一层以上的嵌套归属。
        var stack: [(indent: Int, key: String)] = []
        var itemIndent = 0
        var inProxies = false

        func flush() {
            if hasCurrent { items.append(current) }
            current = [:]
            hasCurrent = false
            stack = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let indent = leadingIndent(rawLine)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // 整行注释跳过。
            if trimmed.hasPrefix("#") { continue }

            // 顶层键（缩进 0）：只有 proxies: 进入解析，其余段结束解析。
            if indent == 0, !trimmed.hasPrefix("-") {
                if trimmed == "proxies:" || trimmed.hasPrefix("proxies: ") {
                    flush()
                    inProxies = true
                    continue
                }
                if inProxies {
                    // proxies 段结束（下一顶层段开始）。
                    flush()
                    inProxies = false
                }
                continue
            }
            guard inProxies else { continue }

            // 新 proxy 项：dash 行，且缩进与首项一致（或首项未定）。
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                let isNewItem = !hasCurrent || indent <= itemIndent
                if isNewItem {
                    flush()
                    hasCurrent = true
                    itemIndent = indent
                    stack = []
                    let content = trimmed == "-" ? "" : String(trimmed.dropFirst(2))
                    if !content.isEmpty {
                        parseKeyValueLine(content, effectiveIndent: indent + 2, into: &current, stack: &stack)
                    }
                    continue
                }
                // 缩进更深的 dash 行：块列表元素（如 alpn: 下的 - h2），
                // 追加到栈顶键（逗号拼接）。
                if let key = stack.last?.key {
                    let value = scalarValue(stripInlineComment(String(trimmed.dropFirst(2))))
                    if !value.isEmpty {
                        if let old = current[key], !old.isEmpty {
                            current[key] = old + "," + value
                        } else {
                            current[key] = value
                        }
                    }
                }
                continue
            }

            guard hasCurrent else { continue }
            parseKeyValueLine(trimmed, effectiveIndent: indent, into: &current, stack: &stack)
        }
        flush()
        return items
    }

    /// 解析一行 `key: value`（已去掉行首 dash 与缩进）。
    /// 无冒号的行是格式错行：不进表；该项最终若缺必填字段，
    /// 会在转换时按 skipped 计 1 项（不单独计行数，避免重复计）。
    private static func parseKeyValueLine(
        _ line: String,
        effectiveIndent: Int,
        into dict: inout ProxyDict,
        stack: inout [(indent: Int, key: String)]
    ) {
        guard let colon = line.firstIndex(of: ":") else { return }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        let rawValue = String(line[line.index(after: colon)...])
        let value = scalarValue(stripInlineComment(rawValue))
        // 弹出缩进不小于本行的栈帧（同级或回退到父级）。
        while let last = stack.last, last.indent >= effectiveIndent {
            stack.removeLast()
        }
        let fullKey = stack.last.map { $0.key + "." + key } ?? key
        if value.isEmpty {
            // 空值：可能是嵌套 map 的父键（如 ws-opts:），也可能是
            // 真空值。先当父键入栈；若其后无子行，该键无值，
            // 转换时按缺失处理，不影响其它字段。
            stack.append((indent: effectiveIndent, key: fullKey))
        } else {
            dict[fullKey] = value
        }
    }

    private static func leadingIndent(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 2 }
            else { break }
        }
        return count
    }

    /// 行内注释：# 之前截断，但引号内的 # 不截断；# 前须为空格
    /// 或行首（密码里紧贴的 # 不当注释，避免误截）。
    private static func stripInlineComment(_ s: String) -> String {
        var inSingle = false
        var inDouble = false
        var previous: Character = " "
        var out = ""
        for ch in s {
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            if ch == "#" && !inSingle && !inDouble
                && (previous == " " || previous == "\t") {
                break
            }
            out.append(ch)
            previous = ch
        }
        return out
    }

    /// 标量：双引号 / 单引号 / 无引号；行内列表 [a, b] 拼成逗号串。
    private static func scalarValue(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            let inner = String(t.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 2 {
            return String(t.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        if t.hasPrefix("[") && t.hasSuffix("]") {
            let inner = String(t.dropFirst().dropLast())
            return inner.split(separator: ",")
                .map { scalarValue(String($0)) }
                .filter { !$0.isEmpty }
                .joined(separator: ",")
        }
        return t
    }

    // MARK: - 编码

    /// userinfo（密码 / uuid 前的字段）：只保留字母数字与 -._~
    /// 其余一律百分号编码，: @ / ? # 在密码里出现时必须编码。
    private static func encodeUserinfo(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// query 值：保留路径等可读字符，& = ? # 一律编码，避免切断参数。
    private static func encodeQuery(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~!$'()*+,;:@/"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// fragment（# 备注）：只保留字母数字与 -._~，其余编码。
    private static func encodeFragment(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func fragmentSuffix(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return "#" + encodeFragment(t)
    }

    private static func queryString(_ pairs: [(String, String)]) -> String {
        let kept = pairs.filter { !$0.1.isEmpty }
        guard !kept.isEmpty else { return "" }
        return "?" + kept.map { "\($0.0)=\(encodeQuery($0.1))" }.joined(separator: "&")
    }

    private static func boolValue(_ s: String?) -> Bool {
        guard let v = s?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return v == "true" || v == "1" || v == "yes"
    }

    private static func boolString(_ s: String?) -> String {
        guard let v = s, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return boolValue(v) ? "true" : "false"
    }

    // MARK: - 转换

    private static func validHostPort(_ dict: ProxyDict) -> (host: String, port: Int)? {
        guard let host = dict["server"]?.trimmingCharacters(in: .whitespaces),
              !host.isEmpty else { return nil }
        guard let portText = dict["port"]?.trimmingCharacters(in: .whitespaces),
              let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private static func sniValue(_ dict: ProxyDict) -> String {
        // Clash 惯用 servername，mihomo 也接受 sni；前者优先。
        dict["servername"] ?? dict["sni"] ?? ""
    }

    private static func wsHost(_ dict: ProxyDict) -> String {
        dict["ws-opts.headers.Host"] ?? dict["ws-opts.headers.host"] ?? ""
    }

    private static func link(from dict: ProxyDict) -> String? {
        guard let type = dict["type"]?.trimmingCharacters(in: .whitespaces).lowercased(),
              !type.isEmpty else { return nil }
        guard let hp = validHostPort(dict) else { return nil }
        let name = dict["name"] ?? ""
        let frag = fragmentSuffix(name)
        let tls = boolValue(dict["tls"])
        let reality = boolValue(dict["reality"])
        let sni = sniValue(dict)
        let alpn = dict["alpn"] ?? ""
        let network = dict["network"] ?? ""

        switch type {
        case "ss":
            guard let method = dict["cipher"], !method.isEmpty,
                  let password = dict["password"], !password.isEmpty else { return nil }
            // 明文 userinfo 形态：Base64 与否由调用方现有逻辑处理。
            return "ss://\(encodeUserinfo(method)):\(encodeUserinfo(password))@\(hp.host):\(hp.port)\(frag)"
        case "vmess":
            guard let uuid = dict["uuid"], !uuid.isEmpty else { return nil }
            var json: [String: String] = [:]
            json["v"] = "2"
            json["ps"] = name
            json["add"] = hp.host
            json["port"] = String(hp.port)
            json["id"] = uuid
            json["aid"] = dict["alterId"] ?? "0"
            json["scy"] = dict["cipher"] ?? "auto"
            json["net"] = network
            json["type"] = "" // Clash vmess 无独立 header-type 字段，留空不编造
            json["host"] = wsHost(dict)
            json["path"] = dict["ws-opts.path"] ?? ""
            json["tls"] = tls ? "tls" : ""
            json["sni"] = tls ? sni : ""
            guard let data = try? JSONSerialization.data(
                withJSONObject: json, options: [.sortedKeys]),
                  !data.isEmpty else { return nil }
            return "vmess://" + data.base64EncodedString() + frag
        case "vless":
            guard let uuid = dict["uuid"], !uuid.isEmpty else { return nil }
            var pairs: [(String, String)] = [("encryption", "none")]
            if let flow = dict["flow"], !flow.isEmpty { pairs.append(("flow", flow)) }
            if reality { pairs.append(("security", "reality")) }
            else if tls { pairs.append(("security", "tls")) }
            if !network.isEmpty { pairs.append(("type", network)) }
            if network == "ws" {
                let h = wsHost(dict)
                if !h.isEmpty { pairs.append(("host", h)) }
                if let p = dict["ws-opts.path"], !p.isEmpty { pairs.append(("path", p)) }
            }
            if network == "grpc" {
                if let s = dict["grpc-opts.grpc-service-name"], !s.isEmpty {
                    pairs.append(("serviceName", s))
                }
            }
            if !sni.isEmpty { pairs.append(("sni", sni)) }
            if !alpn.isEmpty { pairs.append(("alpn", alpn)) }
            if let fp = dict["client-fingerprint"], !fp.isEmpty { pairs.append(("fp", fp)) }
            if reality {
                if let pbk = dict["reality-opts.public-key"], !pbk.isEmpty { pairs.append(("pbk", pbk)) }
                if let sid = dict["reality-opts.short-id"], !sid.isEmpty { pairs.append(("sid", sid)) }
            }
            return "vless://\(encodeUserinfo(uuid))@\(hp.host):\(hp.port)\(queryString(pairs))\(frag)"
        case "trojan":
            guard let password = dict["password"], !password.isEmpty else { return nil }
            var pairs: [(String, String)] = []
            if !sni.isEmpty { pairs.append(("sni", sni)) }
            if !alpn.isEmpty { pairs.append(("alpn", alpn)) }
            pairs.append(("security", "tls"))
            return "trojan://\(encodeUserinfo(password))@\(hp.host):\(hp.port)\(queryString(pairs))\(frag)"
        case "http":
            let auth: String
            if let user = dict["username"], !user.isEmpty {
                let pass = dict["password"] ?? ""
                auth = pass.isEmpty ? "\(encodeUserinfo(user))@" : "\(encodeUserinfo(user)):\(encodeUserinfo(pass))@"
            } else { auth = "" }
            var pairs: [(String, String)] = []
            if tls {
                pairs.append(("tls", "true"))
                if !sni.isEmpty { pairs.append(("sni", sni)) }
            }
            return "http://\(auth)\(hp.host):\(hp.port)\(queryString(pairs))\(frag)"
        case "socks5":
            let auth: String
            if let user = dict["username"], !user.isEmpty {
                let pass = dict["password"] ?? ""
                auth = pass.isEmpty ? "\(encodeUserinfo(user))@" : "\(encodeUserinfo(user)):\(encodeUserinfo(pass))@"
            } else { auth = "" }
            return "socks://\(auth)\(hp.host):\(hp.port)\(frag)"
        case "hysteria2", "hy2":
            guard let password = dict["password"], !password.isEmpty else { return nil }
            var pairs: [(String, String)] = []
            if !sni.isEmpty { pairs.append(("sni", sni)) }
            if !alpn.isEmpty { pairs.append(("alpn", alpn)) }
            let insecure = boolString(dict["skip-cert-verify"])
            if !insecure.isEmpty { pairs.append(("insecure", insecure)) }
            if let obfs = dict["obfs"], !obfs.isEmpty { pairs.append(("obfs", obfs)) }
            if let obfsPass = dict["obfs-password"], !obfsPass.isEmpty {
                pairs.append(("obfs-password", obfsPass))
            }
            return "hysteria2://\(encodeUserinfo(password))@\(hp.host):\(hp.port)\(queryString(pairs))\(frag)"
        case "tuic":
            guard let uuid = dict["uuid"], !uuid.isEmpty,
                  let password = dict["password"], !password.isEmpty else { return nil }
            var pairs: [(String, String)] = []
            if !sni.isEmpty { pairs.append(("sni", sni)) }
            if !alpn.isEmpty { pairs.append(("alpn", alpn)) }
            if let cc = dict["congestion-controller"], !cc.isEmpty {
                pairs.append(("congestion_control", cc))
            }
            if let urm = dict["udp-relay-mode"], !urm.isEmpty {
                pairs.append(("udp_relay_mode", urm))
            }
            let insecure = boolString(dict["skip-cert-verify"])
            if !insecure.isEmpty { pairs.append(("allow_insecure", insecure)) }
            return "tuic://\(encodeUserinfo(uuid)):\(encodeUserinfo(password))@\(hp.host):\(hp.port)\(queryString(pairs))\(frag)"
        case "anytls":
            guard let password = dict["password"], !password.isEmpty else { return nil }
            var pairs: [(String, String)] = []
            if !sni.isEmpty { pairs.append(("sni", sni)) }
            if !alpn.isEmpty { pairs.append(("alpn", alpn)) }
            let insecure = boolString(dict["skip-cert-verify"])
            if !insecure.isEmpty { pairs.append(("insecure", insecure)) }
            return "anytls://\(encodeUserinfo(password))@\(hp.host):\(hp.port)\(queryString(pairs))\(frag)"
        case "wireguard":
            guard let privateKey = dict["private-key"], !privateKey.isEmpty,
                  let publicKey = dict["public-key"], !publicKey.isEmpty else { return nil }
            var pairs: [(String, String)] = []
            pairs.append(("private-key", privateKey))
            pairs.append(("public-key", publicKey))
            if let psk = dict["preshared-key"], !psk.isEmpty {
                pairs.append(("preshared-key", psk))
            }
            pairs.append(("endpoint", "\(hp.host):\(hp.port)"))
            // 本地地址：Clash Meta wireguard 的 ip / ipv6 有就带上，
            // 没有就省略（S2 的 endpoint 解析里 address 已是可选）。
            let localAddrs = [dict["ip"], dict["ipv6"]].compactMap { $0 }.filter { !$0.isEmpty }
            if !localAddrs.isEmpty {
                pairs.append(("address", localAddrs.joined(separator: ",")))
            }
            // authority 用 host:port 占位（wireguard:// 后不能空），
            // 真实端点以 endpoint 参数为准，与 .conf 导入的输出一致。
            return "wireguard://\(hp.host):\(hp.port)\(queryString(pairs))\(frag)"
        case "ssh":
            guard let user = dict["username"], !user.isEmpty else { return nil }
            let auth: String
            if let pass = dict["password"], !pass.isEmpty {
                auth = "\(encodeUserinfo(user)):\(encodeUserinfo(pass))@"
            } else {
                auth = "\(encodeUserinfo(user))@"
            }
            return "ssh://\(auth)\(hp.host):\(hp.port)\(frag)"
        case "snell":
            guard let psk = dict["psk"], !psk.isEmpty else { return nil }
            var pairs: [(String, String)] = []
            if let v = dict["version"], !v.isEmpty { pairs.append(("version", v)) }
            if let obfs = dict["obfs"], !obfs.isEmpty { pairs.append(("obfs", obfs)) }
            if let obfsHost = dict["obfs-host"], !obfsHost.isEmpty {
                pairs.append(("obfs-host", obfsHost))
            }
            return "snell://\(encodeUserinfo(psk))@\(hp.host):\(hp.port)\(queryString(pairs))\(frag)"
        default:
            // ssr、mieru、juicity、未知 type 一律跳过，不输出链接。
            return nil
        }
    }
}
