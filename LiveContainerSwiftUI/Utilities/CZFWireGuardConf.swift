// CZFWireGuardConf.swift
// WireGuard .conf（INI）转 wireguard:// share-link。
// 纯函数：不碰 UserDefaults、不碰网络、不调用 Libbox。
// 测试一律用占位值，绝不写真实密钥。
// 约定（单节点模型，本期边界）：
// - [Interface] 的 Address 进链接的 address 参数：
//   sing-box 的 WireGuard endpoint 本地地址字段就是 address，
//   缺失仍 throw（见 link 的 Address guard）。
// - [Interface] 的 DNS 丢弃：本期不拼 DNS，注释写明。
// - [Peer] 的 AllowedIPs 丢弃：单节点模型不做分流，
//   全部流量走该 Peer，不按 AllowedIPs 拆分。
// - 多 [Peer] 只取第一个，其余忽略（单节点模型只有一个对端）。

import Foundation

enum CZFWireGuardConfError: Error {
    /// 缺失字段：只写字段名，不含任何密钥值。
    case missingField(String)
}

extension CZFWireGuardConfError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingField(let field): return "缺少 \(field)"
        }
    }
}

enum CZFWireGuardConf {

    /// 从 WireGuard .conf 文本生成 wireguard:// 链接。
    /// - 参数 ini: .conf 全文；name: 节点备注（进 # 片段）。
    /// - 缺 PrivateKey / PublicKey / Endpoint / Address 任一，
    ///   或空文件 / 无 [Interface] 段，throw missingField(字段名)。
    static func link(from ini: String, name: String) throws -> String {
        let (interface, peer) = parse(ini)
        guard !interface.isEmpty || !peer.isEmpty else {
            throw CZFWireGuardConfError.missingField("Interface")
        }
        guard !interface.isEmpty else {
            throw CZFWireGuardConfError.missingField("Interface")
        }
        guard let privateKey = interface["privatekey"], !privateKey.isEmpty else {
            throw CZFWireGuardConfError.missingField("PrivateKey")
        }
        // Address 进链接的 address 参数（endpoint 本地地址）。
        guard let address = interface["address"], !address.isEmpty else {
            throw CZFWireGuardConfError.missingField("Address")
        }
        guard let publicKey = peer["publickey"], !publicKey.isEmpty else {
            throw CZFWireGuardConfError.missingField("PublicKey")
        }
        guard let endpointRaw = peer["endpoint"], !endpointRaw.isEmpty,
              let endpoint = validEndpoint(endpointRaw) else {
            throw CZFWireGuardConfError.missingField("Endpoint")
        }
        var pairs: [(String, String)] = []
        pairs.append(("private-key", privateKey))
        pairs.append(("public-key", publicKey))
        if let psk = peer["presharedkey"], !psk.isEmpty {
            pairs.append(("preshared-key", psk))
        }
        pairs.append(("endpoint", endpoint))
        pairs.append(("address", address))
        let query = "?" + pairs.map {
            "\($0.0)=\(encodeQuery($0.1))"
        }.joined(separator: "&")
        let authority = authorityString(for: endpoint)
        let fragment: String
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            fragment = ""
        } else {
            fragment = "#" + encodeFragment(trimmedName)
        }
        return "wireguard://\(authority)\(query)\(fragment)"
    }

    // MARK: - INI 解析

    private enum Section {
        case none, interface, peer, other
    }

    /// 返回 ([Interface] 键值, 第一个 [Peer] 键值)，键已小写化。
    /// 段头大小写不敏感；重复键以后者为准；其它段忽略。
    private static func parse(_ ini: String) -> ([String: String], [String: String]) {
        var interface: [String: String] = [:]
        var peer: [String: String] = [:]
        var section: Section = .none
        var peerDone = false // 第二个起的 [Peer] 段一律忽略

        for rawLine in ini.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // 整行注释（# 或 ; 开头）跳过。
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }
            // 段头：[Interface] / [Peer]，大小写不敏感。
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces).lowercased()
                switch header {
                case "interface":
                    section = .interface
                case "peer":
                    if peerDone {
                        section = .other
                    } else {
                        section = .peer
                        peerDone = true
                    }
                default:
                    section = .other
                }
                continue
            }
            guard section == .interface || section == .peer else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            // 行内注释：值后跟空白 + # 或 ; 时截断（密钥本身
            // 的 Base64 字母表不含 # / ;，不会误截）。
            if let commentIndex = value.firstIndex(where: { ch in
                ch == "#" || ch == ";"
            }) {
                let before = value[..<commentIndex]
                if before.hasSuffix(" ") || before.hasSuffix("\t") {
                    value = String(before).trimmingCharacters(in: .whitespaces)
                }
            }
            if value.isEmpty { continue }
            switch section {
            case .interface: interface[key] = value // 重复键以后者为准
            case .peer: peer[key] = value
            default: break
            }
        }
        return (interface, peer)
    }

    /// Endpoint 校验：host:port，port 须为 1...65535；
    /// host 为空或 port 非法时返回 nil（调用方按缺失处理，
    /// 错误信息只写字段名，不含原始值）。
    private static func validEndpoint(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // IPv6：[::1]:51820 形态，或裸 ::1:51820（取最后一段当端口）。
        let host: String
        let portText: String
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]"),
                  text.index(after: close) < text.endIndex,
                  text[text.index(after: close)] == ":"
            else { return nil }
            host = String(text[...close])
            portText = String(text[text.index(after: close)...].dropFirst())
        } else if let colon = text.lastIndex(of: ":") {
            host = String(text[..<colon])
            portText = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        guard !host.isEmpty,
              let port = Int(portText), (1...65535).contains(port) else { return nil }
        return "\(host):\(port)"
    }

    /// authority：IPv6 裸地址补方括号，已带括号的原样保留。
    private static func authorityString(for endpoint: String) -> String {
        if endpoint.hasPrefix("[") { return endpoint }
        let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 2 {
            // 裸 IPv6：host 部分含冒号，补括号。
            let host = parts.dropLast().joined(separator: ":")
            return "[\(host)]:\(parts.last ?? "")"
        }
        return endpoint
    }

    /// query 值：Base64 密钥里的 + / = 必须百分号编码，
    /// 只保留字母数字与 -._~ 及 endpoint 里的 : 。
    private static func encodeQuery(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~:"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// fragment（# 备注）：只保留字母数字与 -._~，其余编码。
    private static func encodeFragment(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
