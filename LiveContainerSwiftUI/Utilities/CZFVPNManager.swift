//
//  CZFVPNManager.swift
//  单 App VPN（验证版，2026-10-21）
//
//  思路：Xray 核心（libXray 官方封装）跑在宿主进程里，开一个
//  本地 SOCKS5 入口（127.0.0.1:10827）；被标记的 App 单独部署
//  CZFProxy.dylib，把它的 TCP 流量拐进这个入口经节点出网。
//  没标记的 App 完全不碰（不启核心、不装插件）。
//
//  节点链接由 libXray 自带的 convertShareLinksToXrayJson 转成
//  出站配置，本类只负责拼装完整配置（SOCKS 入站 + 全部流量走
//  节点）与启停。域名经 SOCKS 以域名形式交给节点远端解析，
//  本地不落 DNS。
//

import Foundation
import LibXray

public final class CZFVPNManager {
    public static let shared = CZFVPNManager()

    public static let socksPort = 10827
    private static let nodeLinkKey = "CZFVPNNodeLink"
    private static let enabledKeyPrefix = "CZFVPNEnabled-"

    public private(set) var isRunning = false
    private var runningLink: String?
    public private(set) var lastError: String?

    private init() {}

    // MARK: - 节点与标记（UserDefaults 存储）

    public var nodeLink: String {
        UserDefaults.standard.string(forKey: Self.nodeLinkKey) ?? ""
    }

    public static func isEnabled(for appInfo: LCAppInfo) -> Bool {
        guard let bundleId = appInfo.bundleIdentifier() else { return false }
        return UserDefaults.standard.bool(forKey: enabledKeyPrefix + bundleId)
    }

    public static func setEnabled(_ enabled: Bool, for appInfo: LCAppInfo) {
        guard let bundleId = appInfo.bundleIdentifier() else { return }
        UserDefaults.standard.set(enabled, forKey: enabledKeyPrefix + bundleId)
    }

    // MARK: - 插件部署（signApp 签名前调用）

    // 按标记把 CZFProxy.dylib 同步进该 App 的专属插件目录：
    // 开着 → 内容不一致就拷入（随后 signTweaks 会签它）；
    // 关着 → 残留删掉。
    public static func syncProxyTweak(for appInfo: LCAppInfo, tweakFolderUrl: URL) {
        let dest = tweakFolderUrl.appendingPathComponent("CZFProxy.dylib")
        let fm = FileManager.default
        // 目录可能还不存在（自动建的 CZFVPN 目录名只有名字、没落盘），
        // 先建出来——不建的话随后 signTweaks 枚举目录会直接报错，
        // 整个 App 都打不开（真机实测）
        try? fm.createDirectory(at: tweakFolderUrl, withIntermediateDirectories: true)
        if isEnabled(for: appInfo) {
            guard let src = Bundle.main.url(forResource: "CZFProxy", withExtension: "dylib") else { return }
            let srcData = try? Data(contentsOf: src)
            let destData = try? Data(contentsOf: dest)
            if destData != srcData {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: src, to: dest)
            }
        } else {
            try? fm.removeItem(at: dest)
        }
    }

    // MARK: - 核心启停

    // 被标记 App 启动前调用：核心已在跑且节点没换就直接返回；
    // 失败只记 lastError 不抛——游客侧插件有 fail-open，核心不
    // 在时 App 直连不断网。
    public func ensureRunning() {
        let link = nodeLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        if isRunning && runningLink == link { return }
        _ = start()
    }

    @discardableResult
    public func start() -> Bool {
        let link = nodeLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            lastError = "还没填节点链接"
            return false
        }
        if isRunning && runningLink == link { return true }
        if isRunning { stop() }

        let conv = invoke(method: "convertShareLinksToXrayJson", payload: ["text": Self.normalizedShareLink(link)])
        guard let conv,
              conv["success"] as? Bool == true,
              let data = conv["data"] as? [String: Any],
              var outbounds = data["outbounds"] as? [[String: Any]],
              !outbounds.isEmpty else {
            lastError = "节点链接解析失败：\(invokeError(from: conv) ?? "核心无应答")"
            return false
        }
        var node = outbounds[0]
        node["tag"] = "node"

        let config: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": Self.socksPort,
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": false],
                "sniffing": ["enabled": true, "destOverride": ["http", "tls"]],
            ]],
            "outbounds": [
                node,
                ["tag": "direct", "protocol": "freedom"] as [String: Any],
                ["tag": "block", "protocol": "blackhole"] as [String: Any],
            ],
            "routing": [
                "domainStrategy": "IPIfNonMatch",
                "rules": [["type": "field", "inboundTag": ["socks-in"], "outboundTag": "node"]],
            ],
        ]
        guard let cfgData = try? JSONSerialization.data(withJSONObject: config),
              let cfgStr = String(data: cfgData, encoding: .utf8) else {
            lastError = "核心配置生成失败"
            return false
        }
        let resp = invoke(method: "runXray", payload: ["xrayJson": cfgStr])
        guard let resp, resp["success"] as? Bool == true else {
            lastError = "核心启动失败：\(invokeError(from: resp) ?? "未知错误")"
            return false
        }
        isRunning = true
        runningLink = link
        lastError = nil
        return true
    }

    public func stop() {
        _ = invoke(method: "stopXray", payload: [:])
        isRunning = false
        runningLink = nil
    }

    // MARK: - 老格式链接翻译

    // 有些面板发的 vless 链接是老格式：vless://<base64>?参数，
    // base64 解开是「加密:uuid@地址:端口」。官方解析器只认标准
    // 格式（uuid@地址:端口 写在明处），先把老格式翻译成标准
    // 格式再交给它；认不出的一律原样返回。
    private static func normalizedShareLink(_ link: String) -> String {
        guard link.hasPrefix("vless://") else { return link }
        let rest = String(link.dropFirst("vless://".count))
        let authEnd = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = String(rest[..<authEnd])
        if authority.contains("@") { return link } // 已是标准格式

        var b64 = authority
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let decodedData = Data(base64Encoded: b64),
              let decoded = String(data: decodedData, encoding: .utf8) else { return link }

        let pattern = #"^([^:]+):([^@]+)@([^:]+):([0-9]+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
              m.numberOfRanges == 5 else { return link }
        func group(_ i: Int) -> String {
            let r = Range(m.range(at: i), in: decoded)!
            return String(decoded[r])
        }
        let encryption = group(1), uuid = group(2), host = group(3), port = group(4)

        // 查询参数手动切分（不走 URLComponents：它对这种 base64
        // 当主机名的怪链接有整串拒绝的先例，参数会丢）
        var query: [String: String] = [:]
        if let qStart = link.firstIndex(of: "?") {
            var qStr = link[link.index(after: qStart)...]
            if let hashIdx = qStr.firstIndex(of: "#") {
                qStr = qStr[..<hashIdx]
            }
            for pair in qStr.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    query[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                }
            }
        }

        var out: [(String, String)] = [("encryption", encryption)]
        if let pbk = query["pbk"], !pbk.isEmpty {
            out.append(("security", "reality"))
            out.append(("pbk", pbk))
            if let sid = query["sid"], !sid.isEmpty { out.append(("sid", sid)) }
        } else if query["tls"] == "1" {
            out.append(("security", "tls"))
        } else {
            out.append(("security", "none"))
        }
        if let sni = query["peer"] ?? query["sni"], !sni.isEmpty {
            out.append(("sni", sni))
        }
        if let flow = query["flow"], !flow.isEmpty {
            out.append(("flow", flow))
        } else if query["xtls"] == "2" {
            out.append(("flow", "xtls-rprx-vision"))
        } else if query["xtls"] == "1" {
            out.append(("flow", "xtls-rprx-origin"))
        }
        if let fp = query["fingerprint"] ?? query["fp"], !fp.isEmpty {
            out.append(("fp", fp))
        }
        let type = query["type"] ?? query["net"] ?? "tcp"
        out.append(("type", type))
        if type == "ws" {
            if let h = query["host"], !h.isEmpty { out.append(("host", h)) }
            if let p = query["path"], !p.isEmpty { out.append(("path", p)) }
        }

        var result = "vless://\(uuid)@\(host):\(port)?"
        result += out.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&")
        if let name = query["remarks"], !name.isEmpty {
            result += "#" + (name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name)
        }
        return result
    }

    // MARK: - libXray 调用

    private func invokeError(from resp: [String: Any]?) -> String? {
        guard let resp else { return nil }
        let err = resp["error"] as? String
        return (err?.isEmpty == false) ? err : nil
    }

    private func invoke(method: String, payload: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = ["apiVersion": 3, "method": method, "payload": payload]
        guard let reqData = try? JSONSerialization.data(withJSONObject: request),
              let reqStr = String(data: reqData, encoding: .utf8),
              let cReq = strdup(reqStr) else {
            return nil
        }
        defer { free(cReq) }
        guard let cResp = CGoInvoke(cReq) else { return nil }
        defer { CGoFree(cResp) }
        let respStr = String(cString: cResp)
        guard let respData = respStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: respData),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }
}
