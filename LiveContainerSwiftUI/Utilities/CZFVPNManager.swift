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
    private static let nodeListKey = "CZFVPNNodeLinks"
    private static let activeNodeKey = "CZFVPNActiveNodeIndex"
    private static let enabledKeyPrefix = "CZFVPNEnabled-"

    public private(set) var isRunning = false
    private var runningLink: String?
    public private(set) var lastError: String?
    // 核心自动停：被标记 App 全部关掉后延迟停核心（见
    // noteRunningAppsChanged）；防抖靠"最近一次被标记 App
    // 启动时间"+ 60 秒延迟双保险，避免 App 重启时反复启停
    private var pendingStopWork: DispatchWorkItem?
    private var lastFlaggedLaunchAt = Date.distantPast

    private init() {}

    // MARK: - 节点与标记（UserDefaults 存储）

    // 节点列表：老版本只存过单个链接，首次读时自动迁移成列表，
    // 用户原来填的节点不丢
    public var nodeLinks: [String] {
        if let saved = UserDefaults.standard.array(forKey: Self.nodeListKey) as? [String] {
            return saved
        }
        let legacy = UserDefaults.standard.string(forKey: Self.nodeLinkKey) ?? ""
        let migrated = legacy.isEmpty ? [] : [legacy]
        UserDefaults.standard.set(migrated, forKey: Self.nodeListKey)
        return migrated
    }

    public var activeNodeIndex: Int {
        let links = nodeLinks
        guard !links.isEmpty else { return 0 }
        let idx = UserDefaults.standard.integer(forKey: Self.activeNodeKey)
        return min(max(idx, 0), links.count - 1)
    }

    // 当前生效的节点链接（start/ensureRunning 都读它）
    public var nodeLink: String {
        let links = nodeLinks
        guard !links.isEmpty else { return "" }
        return links[activeNodeIndex]
    }

    public func addNode(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var links = nodeLinks
        if links.contains(trimmed) { return }
        links.append(trimmed)
        UserDefaults.standard.set(links, forKey: Self.nodeListKey)
    }

    public func removeNode(at index: Int) {
        var links = nodeLinks
        guard links.indices.contains(index) else { return }
        // 先记住当前活动节点是哪条：删掉它前面的节点会让后面的
        // 往前挪，按下标存的选中项会悄悄换人，删完要按内容找回
        let previousActive = nodeLink
        links.remove(at: index)
        UserDefaults.standard.set(links, forKey: Self.nodeListKey)
        if let newIdx = links.firstIndex(of: previousActive) {
            UserDefaults.standard.set(newIdx, forKey: Self.activeNodeKey)
        } else {
            UserDefaults.standard.set(max(links.count - 1, 0), forKey: Self.activeNodeKey)
        }
        applyActiveNodeChange()
    }

    public func setActiveNode(at index: Int) {
        guard nodeLinks.indices.contains(index) else { return }
        UserDefaults.standard.set(index, forKey: Self.activeNodeKey)
        applyActiveNodeChange()
    }

    // 活动节点变了而核心在跑：立刻按新节点重启（改完即生效）；
    // 没有可用节点了就停掉
    private func applyActiveNodeChange() {
        guard isRunning else { return }
        if nodeLink.isEmpty {
            stop()
        } else if runningLink != nodeLink {
            _ = start()
        }
    }

    // 节点显示名：优先链接里的备注（标准格式的 # 片段；老格式
    // 经 normalizedShareLink 后 remarks 也会落到片段里），其次
    // 是 地址:端口——列表里一眼能认出是哪个节点
    public static func nodeDisplay(for link: String) -> (name: String, detail: String) {
        let std = normalizedShareLink(link)
        var name = ""
        var detail = ""
        if let comps = URLComponents(string: std) {
            if let frag = comps.fragment, !frag.isEmpty {
                name = frag
            }
            if let host = comps.host, !host.isEmpty {
                detail = comps.port.map { "\(host):\($0)" } ?? host
            }
        }
        if name.isEmpty {
            name = detail.isEmpty ? "节点" : detail
        }
        return (name, detail)
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
    // 返回 true 表示这次换上了新插件文件——调用方要立刻给它
    // 单独补一签（见 signApp 里的说明）
    @discardableResult
    public static func syncProxyTweak(for appInfo: LCAppInfo, tweakFolderUrl: URL) -> Bool {
        let dest = tweakFolderUrl.appendingPathComponent("CZFProxy.dylib")
        let fm = FileManager.default
        // 目录可能还不存在（自动建的 CZFVPN 目录名只有名字、没落盘），
        // 先建出来——不建的话随后 signTweaks 枚举目录会直接报错，
        // 整个 App 都打不开（真机实测）
        try? fm.createDirectory(at: tweakFolderUrl, withIntermediateDirectories: true)
        if isEnabled(for: appInfo) {
            guard let src = Bundle.main.url(forResource: "CZFProxy", withExtension: "dylib") else { return false }
            let srcData = try? Data(contentsOf: src)
            let destData = try? Data(contentsOf: dest)
            if destData != srcData {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: src, to: dest)
                return true
            }
        } else {
            try? fm.removeItem(at: dest)
        }
        return false
    }

    // MARK: - 核心启停

    // 被标记 App 启动前调用：核心已在跑且节点没换就直接返回；
    // 失败只记 lastError 不抛——游客侧插件有 fail-open，核心不
    // 在时 App 直连不断网。
    public func ensureRunning() {
        // 有被标记 App 在启动：取消待执行的自动停，并记下时间
        pendingStopWork?.cancel()
        pendingStopWork = nil
        lastFlaggedLaunchAt = Date()
        let link = nodeLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        if isRunning && runningLink == link { return }
        _ = start()
    }

    // 多任务列表变化后由 MultitaskDockManager 调用：还在跑的
    // App 里已经没有被标记的了，就排一个 60 秒后的停核心；
    // 期间有被标记 App 起来（ensureRunning 会取消）就不停
    public func noteRunningAppsChanged(stillHasFlagged: Bool) {
        // 宿主自身走节点的开关开着时，核心同样算"还在被用"
        if stillHasFlagged || Self.isHostProxyEnabled {
            pendingStopWork?.cancel()
            pendingStopWork = nil
            return
        }
        guard isRunning else { return }
        pendingStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            if Self.isHostProxyEnabled { return }
            if Date().timeIntervalSince(self.lastFlaggedLaunchAt) < 60 { return }
            self.stop()
        }
        pendingStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
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
            "inbounds": [
                [
                    "tag": "socks-in",
                    "listen": "127.0.0.1",
                    "port": Self.socksPort,
                    "protocol": "socks",
                    "settings": ["auth": "noauth", "udp": false],
                    "sniffing": ["enabled": true, "destOverride": ["http", "tls"]],
                ] as [String: Any],
                // HTTP 入口给 NSURLSession 配置改写用（插件把会话
                // 的代理字典指向这里，框架自己把请求送进来）
                [
                    "tag": "http-in",
                    "listen": "127.0.0.1",
                    "port": 10828,
                    "protocol": "http",
                    "settings": [String: Any](),
                ] as [String: Any],
            ],
            "outbounds": [
                node,
                ["tag": "direct", "protocol": "freedom"] as [String: Any],
                ["tag": "block", "protocol": "blackhole"] as [String: Any],
            ],
            "routing": [
                "domainStrategy": "IPIfNonMatch",
                "rules": [["type": "field", "inboundTag": ["socks-in", "http-in"], "outboundTag": "node"]],
            ],
            // 隧道闲置保活拉长到 600 秒（默认 300）：X 这类间歇
            // 小请求的 App 隔几分钟用一次，隧道被回收就要重付
            // 一次跨欧握手，表现为时快时慢
            "policy": [
                "levels": ["0": ["connIdle": 600, "handshake": 4] as [String: Any]],
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

    // MARK: - 节点延迟测试

    /// 一个节点的延迟测试结果：success 时 delay 是真实毫秒；
    /// 失败时 delay 是核心给的码（10000 出错 / 11000 超时），
    /// 界面别当毫秒显示
    public struct CZFNodePingResult {
        public let success: Bool
        public let delay: Int
    }

    /// 测全部节点的延迟（libXray 的 pingBatch：临时实例并发
    /// 测、每批最多 5 个，经节点真实发一次 HEAD 量往返）。
    /// 注意 pingBatch 与在跑的核心抢同一把生命周期锁、核心
    /// 在跑时整批会被拒——所以核心在跑时先停、测完按原样起
    /// 回来（用户点测速触发，几秒的事）。completion 回主
    /// 线程，结果与 nodeLinks 同序
    public func pingAllNodes(completion: @escaping ([CZFNodePingResult]) -> Void) {
        let links = nodeLinks
        guard !links.isEmpty else { completion([]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let wasRunning = self.isRunning
            var outcome = self.runPingBatches(links: links)
            if wasRunning && outcome.batchRejected {
                self.stop()
                outcome = self.runPingBatches(links: links)
                _ = self.start()
            }
            let items = outcome.items
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// 逐批调 pingBatch（同步阻塞，必须在后台线程调）
    private func runPingBatches(links: [String]) -> (items: [CZFNodePingResult], batchRejected: Bool) {
        var items = [CZFNodePingResult?](repeating: nil, count: links.count)
        var batchRejected = false
        // 先把每个链接转成出站 JSON，转不动的直接记失败
        var pending: [(index: Int, xrayJson: String)] = []
        for (i, link) in links.enumerated() {
            let conv = invoke(method: "convertShareLinksToXrayJson", payload: ["text": Self.normalizedShareLink(link)])
            if let conv, conv["success"] as? Bool == true,
               let data = conv["data"] as? [String: Any],
               let outbounds = data["outbounds"] as? [[String: Any]], !outbounds.isEmpty,
               let jsonData = try? JSONSerialization.data(withJSONObject: ["outbounds": outbounds]),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                pending.append((i, jsonStr))
            } else {
                items[i] = CZFNodePingResult(success: false, delay: 10000)
            }
        }
        var start = 0
        while start < pending.count {
            let batch = Array(pending[start..<min(start + 5, pending.count)])
            let resp = invoke(method: "pingBatch", payload: [
                "configs": batch.map { ["xrayJson": $0.xrayJson] },
                "timeout": 5,
                "url": "https://cp.cloudflare.com/",
            ])
            if let resp, resp["success"] as? Bool == true,
               let data = resp["data"] as? [String: Any],
               let results = data["results"] as? [[String: Any]] {
                for (j, item) in results.enumerated() where j < batch.count {
                    let ok = item["success"] as? Bool ?? false
                    let delay = (item["delay"] as? NSNumber)?.intValue ?? 10000
                    items[batch[j].index] = CZFNodePingResult(success: ok, delay: delay)
                }
            } else {
                batchRejected = true
            }
            for entry in batch where items[entry.index] == nil {
                items[entry.index] = CZFNodePingResult(success: false, delay: 10000)
            }
            start += 5
        }
        return (items.map { $0 ?? CZFNodePingResult(success: false, delay: 10000) }, batchRejected)
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

    // 读游客插件写的运行统计（插件同目录的 CZFProxyStats.txt），
    // 供 App 设置页显示：插件到底干了多少活、哪类连接没被拦到
    // MARK: 宿主自身走节点（源刷新 / 从源下载 IPA）

    /// 开关：LiveContainer 自己的源请求与下载也经内置节点出网
    /// （境外源才需要；JIT 的局域网服务器调用不走这里、不受影响）
    public static var isHostProxyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "CZFVPNHostProxyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "CZFVPNHostProxyEnabled") }
    }

    public static func proxyDictionary() -> [String: Any] {
        [
            "HTTPEnable": true, "HTTPProxy": "127.0.0.1", "HTTPPort": 10828,
            "HTTPSEnable": true, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 10828,
            "SOCKSEnable": true, "SOCKSProxy": "127.0.0.1", "SOCKSPort": socksPort,
        ]
    }

    private static let proxiedHostSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = proxyDictionary()
        return URLSession(configuration: config)
    }()

    /// 宿主自己的网络会话：开关开且核心在跑时经核心出网，
    /// 否则系统共享会话（fail-open，不断网）
    public static func hostSession() -> URLSession {
        guard isHostProxyEnabled, shared.isRunning else { return .shared }
        return proxiedHostSession
    }

    /// 下载用配置：走节点时改用前台配置——后台配置的下载任务由
    /// 系统进程执行、代理字典不生效；不开节点时维持后台配置原样
    public static func hostDownloadConfiguration(identifier: String) -> URLSessionConfiguration {
        if isHostProxyEnabled && shared.isRunning {
            let config = URLSessionConfiguration.default
            config.connectionProxyDictionary = proxyDictionary()
            return config
        }
        return URLSessionConfiguration.background(withIdentifier: identifier)
    }

    /// 宿主开关打开时把核心拉起来（源/下载要用），顺带取消待执行的自动停
    public func ensureRunningForHost() {
        guard Self.isHostProxyEnabled else { return }
        pendingStopWork?.cancel()
        pendingStopWork = nil
        if !isRunning {
            _ = start()
        }
    }

    public static func proxyStatsText(for appInfo: LCAppInfo) -> String? {
        guard let folderName = appInfo.tweakFolder ?? (isEnabled(for: appInfo) ? "CZFVPN" : nil) else { return nil }
        let base = appInfo.isShared ? LCPath.lcGroupTweakPath : LCPath.tweakPath
        let folder = base.appendingPathComponent(folderName)
        // 统计按 App 分文件（插件按包名命名）；老版的共用文件兜底
        let bid = appInfo.bundleIdentifier() ?? ""
        var url = folder.appendingPathComponent("CZFProxyStats-\(bid).txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("CZFProxyStats.txt")
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var dict: [String: String] = [:]
        for part in raw.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        guard let load = dict["load"] else { return nil }
        return "插件统计（加载 \(load) · 自检 \(dict["selftest"] ?? "?")）：解析共 \(dict["gaiPass"] ?? "0") 次（假IP \(dict["gaiFake"] ?? "0")）· 代理连接 \(dict["proxied"] ?? "0") · 失败 \(dict["failed"] ?? "0") · 直连 \(dict["direct"] ?? "0") · 放行 \(dict["pass"] ?? "0") · connectx \(dict["connectx"] ?? "0") · 会话改写 \(dict["swizzled"] ?? "0") · 配置改写 \(dict["cfg"] ?? "0") · 拦QUIC \(dict["quic"] ?? "0")"
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
