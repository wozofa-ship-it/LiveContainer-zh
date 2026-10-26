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
    private static let nodeOverrideKeyPrefix = "CZFVPNNodeOverride-"
    // 用户在 App 设置里亲手选过"跟随全局"时才为 true；缺省为 false，
    // 表示这个 App 还没选过，养号锁定逻辑可以替它钉死当前节点
    private static let followGlobalKeyPrefix = "CZFVPNFollowGlobal-"

    public private(set) var isRunning = false
    private var runningLink: String?
    // 核心当前归哪个 App 所有（ensureRunning 起核心时记下）：
    // 养号 App 在跑时，别的 App 自动启动不准抢核心换节点，
    // 手动在设置里切节点、停核心时会清掉这个归属
    private var coreOwnerBundleId: String?
    public private(set) var lastError: String?
    // 核心自动停：被标记 App 全部关掉后延迟停核心（见
    // noteRunningAppsChanged）；防抖靠"最近一次被标记 App
    // 启动时间"+ 30 分钟延迟双保险，避免 App 重启时反复启停
    private var pendingStopWork: DispatchWorkItem?
    private var lastFlaggedLaunchAt = Date.distantPast
    // 核心状态串行化：start/stop/测速恢复/开 App 预热原来在
    // 主线程、detached Task、测速后台队列三处同时改
    // isRunning/runningLink/coreOwnerBundleId，测速中途开 App
    // 时 stop/start 互相插队，恢复完又被改回去。NSLock 在
    // start(withLink:) 内部调 stop() 时会同线程二次加锁死锁，
    // 故用 NSRecursiveLock（同仓 LCUtilsExtensions 的 lock/defer
    // 写法，见该文件 verifiedTweakFoldersLock 处）。
    // 锁只包状态切换（stop/start/抓状态/恢复），不包整段测速
    // （pingBatch 有 5 秒超时、重试可达十几秒，包住会冻住主
    // 线程的预热）；测速窗口内别的触发靠下面的 isPinging 挡。
    private let vpnCoreLock = NSRecursiveLock()
    // 测速进行中标志：测速窗口内开 App、预热、切节点一律不
    // 直接动核心，改由测速收尾统一处理（见 pingAllNodes 末尾
    // 的 deferredEnsure / 切节点跟随 / 延迟重试），否则测速
    // 的停核心-重测-起回序列会被插队打乱。
    private var isPinging = false
    // 测速窗口内被挡下的开 App 请求：只记最后一个，测速完
    // 再给它 ensureRunning（游客启动时等核心，见 LCAppModel
    // 的 vpnCoreTask；挡下不等于丢掉）。
    private var deferredEnsureApp: LCAppInfo?
    // 测速恢复起核心失败时留下的延迟重试链接：只由测速收尾
    // 写、stop() 清、延迟重试闭包一次性消费；用户测速后亲
    // 手停核心时 stop() 会清掉它，延迟重试不再把核心起回来。
    private var pingRetryLink: String?
    // 用户/ App 动作计数：测速收尾要不要按测速前状态恢复，
    // 就看测速窗口内有没有这类动作。开 App（ensureRunning，
    // 含测速收尾补跑）、源下载开关（ensureRunningForHost）、
    // 设置页亲手起停核心（noteManualCoreToggle）都会 +1；
    // 预热、延迟重试、测速自身不 +1——它们是自动触发，
    // 不能反过来推翻用户/ App 在测速窗口内做的决定，也
    // 不能让收尾后的校验把它们当成用户动作放过。
    private var coreActionEpoch = 0
    // 测速代次：每轮 pingAllNodes 开始时 +1。收尾后 3 秒的
    // 校验只认同一代次，新一轮测速开始就作废旧校验，免得
    // 旧校验去 undo 新一轮测速的收尾。
    private var pingGeneration = 0
    // 测速收尾刚恢复成的状态与时间：只在收尾真正按测速前
    // 状态恢复时写（测速窗口内有用户动作、收尾跳过恢复时
    // 不写）。预热用它判断：刚被测速恢复成“没在跑”的几
    // 秒内，切回前台也不预热起核心——否则用户点完测速、
    // 切走切回，预热立刻又把核心起回来，看起来就是“测
    // 速把核心启动了”。新进程里这两个值是初始值，预热
    // 不受影响。
    private var lastPingRestoredRunning: Bool?
    private var lastPingRestoreAt = Date.distantPast
    // 测速窗口内被挡下的源下载开关起核心请求：与
    // deferredEnsureApp 同理，测速收尾再补跑一次。
    private var deferredHostEnsure = false
    // 核心闲置自动停时长：小火箭式常驻取舍——30 分钟内重开
    // 免冷启动；真闲置才停（宿主被系统挂起时本就不耗电）
    private static let autoStopDelay: TimeInterval = 1800

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

    // 用一批新链接整体替换节点列表（订阅刷新用）：尽量保留
    // 当前活动节点（按内容找回），找不到就落到第一个
    public func replaceAllNodes(_ newLinks: [String]) {
        let cleaned = newLinks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let previousActive = nodeLink
        UserDefaults.standard.set(cleaned, forKey: Self.nodeListKey)
        if let idx = cleaned.firstIndex(of: previousActive) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        } else {
            UserDefaults.standard.set(0, forKey: Self.activeNodeKey)
        }
        applyActiveNodeChange()
    }

    /// 拉订阅内容并解析出节点链接：机场订阅通常是整段 base64
    /// （解开后一行一条链接），也有直接一行一条的明文格式，
    /// 两种都认；只保留带 :// 的行（vless/vmess/trojan/ss 等）
    public static func fetchSubscriptionLinks(urlString: String, completion: @escaping (Result<[String], Error>) -> Void) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            completion(.failure(NSError(domain: "CZFVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "订阅地址不对"])))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // 不少机场按客户端 UA 返回不同格式，给个常见客户端的
        // UA 拿到原始分享链接列表
        request.setValue("Shadowrocket/2.2.50", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data, let raw = String(data: data, encoding: .utf8) else {
                completion(.failure(NSError(domain: "CZFVPN", code: -2, userInfo: [NSLocalizedDescriptionKey: "订阅内容读不出来"])))
                return
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = trimmed
            // 整体 base64 就先解开（去掉空白后能整段解码、且
            // 解出来含 :// 才算数，明文格式不会误伤）；有的
            // 机场用 URL 安全变体（- 和 _），一并兼容
            let compact = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            if !compact.isEmpty, compact.count % 4 == 0,
               let decoded = Data(base64Encoded: compact),
               let decodedText = String(data: decoded, encoding: .utf8),
               decodedText.contains("://") {
                text = decodedText
            }
            let links = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.contains("://") }
            if links.isEmpty {
                completion(.failure(NSError(domain: "CZFVPN", code: -3, userInfo: [NSLocalizedDescriptionKey: "订阅里没找到节点链接"])))
            } else {
                completion(.success(links))
            }
        }.resume()
    }

    // 只换节点顺序（测速排序用）：活动节点按内容找回，不
    // 重启核心（顺序不影响在跑的核心用哪条节点）
    public func replaceNodeOrder(_ newLinks: [String]) {
        guard !newLinks.isEmpty else { return }
        let previousActive = nodeLink
        UserDefaults.standard.set(newLinks, forKey: Self.nodeListKey)
        if let idx = newLinks.firstIndex(of: previousActive) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        }
    }

    /// 预热：有 App 标了 VPN 且预热开关没关时，提前把核心
    /// 拉起来（用全局当前节点），第一个 VPN App 点开就不
    /// 用等冷启动。核心已经在跑就直接返回，不打扰正在用
    /// 的连接；起了没人用时原有的 30 分钟自动停不覆盖这种
    /// 情况（没 App 启动过），核心随宿主进程被系统挂起，
    /// 不额外耗电
    public func prewarmIfNeeded() {
        // 测速窗口内不预热：此时核心正被测速停掉重测，预热
        // 起核心会让 pingBatch 再被拒、还打乱测速收尾的恢复
        // 判断；预热本就是 opportunistic，下次进前台还会再跑
        vpnCoreLock.lock()
        let pinging = isPinging
        // 刚被测速恢复成“没在跑”时不预热：见字段注释。
        // 恢复成“在跑”时下面 guard !isRunning 本来就返回，
        // 这里只挡恢复成没在跑的那 10 秒窗口。
        let restoredOff = lastPingRestoredRunning == false
        let restoredAt = lastPingRestoreAt
        vpnCoreLock.unlock()
        if pinging { return }
        if restoredOff, Date().timeIntervalSince(restoredAt) < 10 { return }
        if UserDefaults.standard.object(forKey: "CZFVPNPrewarm") != nil, !UserDefaults.standard.bool(forKey: "CZFVPNPrewarm") {
            return
        }
        guard !isRunning, !nodeLinks.isEmpty else { return }
        let defaults = UserDefaults.standard
        let hasMarked = defaults.dictionaryRepresentation().keys.contains { key in
            key.hasPrefix("CZFVPNEnabled-") && defaults.bool(forKey: key)
        }
        guard hasMarked else { return }
        _ = start()
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
        // 测速窗口内不切：切节点会重启核心，打断测速的停-
        // 重测-起回；节点选择已写进 UserDefaults，测速收尾
        // 会比对测速前后的活动链接、再跟随这次切换（见
        // pingAllNodes 末尾），用户的切换不会丢。
        vpnCoreLock.lock()
        let pinging = isPinging
        vpnCoreLock.unlock()
        if pinging { return }
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
        // 养号锁定（1）：刚打开 VPN 且还没钉过节点、也没亲手选
        // 过跟随全局时，立刻把当前全局节点钉成这个 App 的专属
        // 节点；以后全局怎么换都不动它。已经钉过的、亲手选过
        // 跟随全局的，都不动
        if enabled,
           nodeOverride(for: appInfo) == nil,
           !isFollowGlobalExplicit(for: appInfo) {
            let current = shared.nodeLink
            if !current.isEmpty {
                setNodeOverride(current, for: appInfo)
            }
        }
    }

    // 用户是否在 App 设置里亲手选过"跟随全局"（缺省 false）
    public static func isFollowGlobalExplicit(for appInfo: LCAppInfo) -> Bool {
        guard let bundleId = appInfo.bundleIdentifier() else { return false }
        return UserDefaults.standard.bool(forKey: followGlobalKeyPrefix + bundleId)
    }

    // 按 App 指定节点：存链接本身而不是下标，节点列表增删、
    // 排序、订阅替换都不会让指定关系错位。钉死后即使这条链
    // 接不在列表里了也照用——列表只是选节点的菜单，不是
    // App 的 IP 归属；删了菜单项就悄悄换 IP，正是养号最忌
    // 讳的。亲手选跟随全局时才回落全局
    public static func nodeOverride(for appInfo: LCAppInfo) -> String? {
        guard let bundleId = appInfo.bundleIdentifier() else { return nil }
        let saved = UserDefaults.standard.string(forKey: nodeOverrideKeyPrefix + bundleId)
        return (saved?.isEmpty == false) ? saved : nil
    }

    public static func setNodeOverride(_ link: String?, for appInfo: LCAppInfo) {
        guard let bundleId = appInfo.bundleIdentifier() else { return }
        if let link, !link.isEmpty {
            UserDefaults.standard.set(link, forKey: nodeOverrideKeyPrefix + bundleId)
            UserDefaults.standard.removeObject(forKey: followGlobalKeyPrefix + bundleId)
        } else {
            UserDefaults.standard.removeObject(forKey: nodeOverrideKeyPrefix + bundleId)
            UserDefaults.standard.set(true, forKey: followGlobalKeyPrefix + bundleId)
        }
    }

    // 这个 App 实际用的节点链接：钉死过就用钉死的，不管它还
    // 在不在列表里；没钉死才用全局活动节点
    public func effectiveLink(for appInfo: LCAppInfo?) -> String {
        if let appInfo,
           let override = Self.nodeOverride(for: appInfo) {
            return override
        }
        return nodeLink
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
        // 养号严格模式标记（3）：钉死节点的 App 在插件目录里留
        // 一个 CZFProxyStrict 空文件，插件启动时读到它就改成
        // fail-closed（核心不在时断网不直连）；跟随全局的 App
        // 不留标记，维持原来的 fail-open。标记不是 dylib，
        // 不影响返回值（返回值只表示 dylib 有没有换上）
        let strictMarker = tweakFolderUrl.appendingPathComponent("CZFProxyStrict")
        if isEnabled(for: appInfo) {
            if nodeOverride(for: appInfo) != nil {
                if !fm.fileExists(atPath: strictMarker.path) {
                    try? Data().write(to: strictMarker)
                }
            } else {
                try? fm.removeItem(at: strictMarker)
            }
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
            try? fm.removeItem(at: strictMarker)
        }
        return false
    }

    // MARK: - 核心启停

    // 被标记 App 启动前调用：核心已在跑且节点没换就直接返回；
    // 失败只记 lastError 不抛——游客侧插件有 fail-open，核心不
    // 在时 App 直连不断网（钉死节点 App 的插件读到严格标记
    // 后改成断网不直连，见 syncProxyTweak）。
    // 设置页亲手起停核心时调：把这次手动动作记进
    // coreActionEpoch，让测速收尾知道测速窗口内用户亲手
    // 动过核心——收尾就不再按测速前状态把用户的决定 undo
    // 回去（测速中亲手停核心，测完又被收尾起回来，正是
    // “测速把核心启动了”的一种真实路径）。
    public func noteManualCoreToggle() {
        vpnCoreLock.lock()
        coreActionEpoch += 1
        vpnCoreLock.unlock()
    }

    public func ensureRunning(for appInfo: LCAppInfo? = nil) {
        // 开 App 是用户/ App 动作：记进 epoch，测速收尾的
        // 校验不会把它当成自动触发 undo 掉。
        if appInfo != nil {
            vpnCoreLock.lock()
            coreActionEpoch += 1
            vpnCoreLock.unlock()
        }
        // 有被标记 App 在启动：取消待执行的自动停，并记下时间
        pendingStopWork?.cancel()
        pendingStopWork = nil
        lastFlaggedLaunchAt = Date()
        // 养号锁定（1）补钉：已经开了 VPN、还没钉过节点、也没
        // 亲手选过跟随全局的旧 App，第一次启动时就把当前全局
        // 节点钉死，之后不再跟全局走
        if let appInfo,
           Self.isEnabled(for: appInfo),
           Self.nodeOverride(for: appInfo) == nil,
           !Self.isFollowGlobalExplicit(for: appInfo) {
            let current = nodeLink
            if !current.isEmpty {
                Self.setNodeOverride(current, for: appInfo)
            }
        }
        // 测速窗口内不开核心：测速正在停核心重测，这时起核
        // 心会跟测速的 stop/start 插队（两路并发调 libXray 的
        // 生命周期，起可能失败、还可能把测速刚起回的核心换
        // 链）。只记下这次请求，测速收尾会补跑它；取消自动
        // 停、记启动时间、补钉节点这三件上面已经做了，不受
        // 挡下影响。
        vpnCoreLock.lock()
        let pinging = isPinging
        if pinging, let appInfo {
            deferredEnsureApp = appInfo
        }
        vpnCoreLock.unlock()
        if pinging { return }
        // 用这个 App 自己的节点（钉死过就用钉死的，没钉死跟随
        // 全局）
        let link = effectiveLink(for: appInfo).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        if isRunning && runningLink == link {
            if let bid = appInfo?.bundleIdentifier() {
                coreOwnerBundleId = bid
            }
            return
        }
        // 养号保护（2）：核心已经归另一个 App 所有（那个 App
        // 钉死了节点、核心正跑在它的节点上），这个 App 自动
        // 启动不准抢核心换节点——换 IP 正是养号最忌讳的。
        // 手动在设置里切节点（applyActiveNodeChange / start()）
        // 会清掉归属，那时才换；自动启动只保证核心在跑
        if isRunning,
           let owner = coreOwnerBundleId,
           let bid = appInfo?.bundleIdentifier(),
           owner != bid {
            lastError = "核心正被另一个已钉死节点的 App 占用，暂不切换（手动在设置里切节点可强制切换）"
            return
        }
        if start(withLink: link) {
            if let bid = appInfo?.bundleIdentifier() {
                coreOwnerBundleId = bid
            }
        }
    }

    // 多任务列表变化后由 MultitaskDockManager 调用：还在跑的
    // App 里已经没有被标记的了，就排一个 30 分钟后的停核心；
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
            if Date().timeIntervalSince(self.lastFlaggedLaunchAt) < Self.autoStopDelay { return }
            self.stop()
        }
        pendingStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoStopDelay, execute: work)
    }

    @discardableResult
    public func start() -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        // 手动 / 宿主 / 预热起核心：不归某个 App 所有，清掉
        // 养号归属，之后 App 自动启动才可以重新抢核心
        coreOwnerBundleId = nil
        return start(withLink: nodeLink)
    }

    // 用指定链接起核心：已在跑且正是这条链接就直接成功；
    // 在跑的是别的节点先停再按这条起
    private func start(withLink rawLink: String) -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
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
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        // 测速后的延迟重试只认这一个链接：用户亲手停核心
        // 时清掉，延迟重试不再违背用户的意思把它起回来；
        // 测速窗口内调 stop()（测速自己的停核心分支）不走
        // 这一支——那时重试链接还没写，写它的收尾在后头。
        if !isPinging { pingRetryLink = nil }
        _ = invoke(method: "stopXray", payload: [:])
        isRunning = false
        runningLink = nil
        coreOwnerBundleId = nil
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
            // 抓状态必须和 start/stop 同一把锁：否则抓到的
            // wasRunning/runningLink 可能是另一路 stop/start
            // 做到一半的中间态，恢复就按错状态起/停。
            // 抓完立刻放锁——锁不包整段测速（见字段注释）。
            self.vpnCoreLock.lock()
            self.isPinging = true
            self.pingRetryLink = nil
            self.pingGeneration += 1
            let pingGen = self.pingGeneration
            let epochAtPingStart = self.coreActionEpoch
            let wasRunning = self.isRunning
            let originalRunningLink = self.runningLink
            let originalOwner = self.coreOwnerBundleId
            let prePingActiveLink = self.nodeLink
            self.vpnCoreLock.unlock()
            var outcome = self.runPingBatches(links: links, url: "https://cp.cloudflare.com/")
            // 测速窗口内已有用户/ App 动作时，停核心重测分支
            // 也不立即起回：亲手停核心后这一步起回来，等于
            // 在收尾之前就把用户的决定 undo 了；收尾同样会
            // 因 epoch 变化跳过恢复，补跑的开 App 请求会按
            // 自己的节点把核心起回来（那是 App 的动作）。
            self.vpnCoreLock.lock()
            let epochChangedMidPing = self.coreActionEpoch != epochAtPingStart
            self.vpnCoreLock.unlock()
            if wasRunning && outcome.batchRejected && !epochChangedMidPing {
                self.stop()
                outcome = self.runPingBatches(links: links, url: "https://cp.cloudflare.com/")
                // 测速停核心再起回来，必须按原来在跑的那条链接起，
                // 不能按全局活动节点起——否则钉死 App 的 IP 会被
                // 一次测速悄悄换掉；原来没在跑就按全局起
                if let orig = originalRunningLink, !orig.isEmpty {
                    _ = self.start(withLink: orig)
                    self.coreOwnerBundleId = originalOwner
                } else {
                    _ = self.start()
                }
            } else {
                // 假不通修法：第一地址（Cloudflare）个别失败时，
                // 按顺序用另外两个地址单独重测，只认重测通的——
                // 有些 REALITY 节点对 Cloudflare 那一路不通，但
                // 实际经节点上网是通的（小火箭同节点 183ms），
                // 一次失败就永久标不通、逼用户换 IP 是错的。
                // 只用一个重试地址还不够：测速库对 204 空回应
                // 的判定未必算成功，所以第二重试用返回 200 的
                // 苹果连通性检测页兜底；三个地址都失败才标不通。
                // 整批被拒时不走这一步（那是核心占用问题，
                // 上面停核心重测的分支已经处理）
                var failedIndices = outcome.items.enumerated().filter { !$0.element.success }.map { $0.offset }
                for retryURL in ["https://www.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"] {
                    if failedIndices.isEmpty { break }
                    let failedLinks = failedIndices.map { links[$0] }
                    let retry = self.runPingBatches(links: failedLinks, url: retryURL)
                    var stillFailed: [Int] = []
                    for (j, idx) in failedIndices.enumerated() {
                        if retry.items[j].success {
                            outcome.items[idx] = retry.items[j]
                        } else {
                            stillFailed.append(idx)
                        }
                    }
                    failedIndices = stillFailed
                }
            }
            // 测速收尾：无条件按测速前状态恢复——测速本身绝不改
            // 核心启用状态。上一轮只在收尾做一次立即起回：
            // stopXray 的关停若是异步的，紧接着的 runXray 会
            // 因生命周期锁未释放而失败，两次立即重试都撞在
            // 同一个窗口上，之后再没人补救，核心就永久停在
            // “未启动”，设置页刷新出来就是上一轮视频里那样。
            // 本轮收尾分四步，全在同一把锁里判状态、做起停，
            // 锁外再补跑被挡的请求：
            // 1) 按测速前状态恢复（测速前在跑：没在跑才按原链
            //    接起回、归属还原；测速前没在跑：测速窗口里
            //    被别的触发拉起来的也停掉——但测速窗口内开
            //    App/预热/切节点本轮已被 isPinging 挡下，这
            //    里只处理测速自己的停核心分支残留）；
            // 2) 恢复后仍没在跑、且测速前是在跑的，留一个延
            //    迟重试链接，2 秒后（关停应已落定）再起一次，
            //    仍失败就认栽、不再循环；
            // 3) 测速窗口内用户换过活动节点：恢复完再跟随这
            //    次切换（applyActiveNodeChange 在测速窗口内
            //    被挡下时节点选择已写进 UserDefaults）；
            // 4) 测速窗口内被挡下的开 App 请求：恢复完补跑
            //    一次 ensureRunning（若它带钉死节点，优先于
            //    第 3 步的全局切换，故有补跑时跳过第 3 步）。
            var deferredApp: LCAppInfo?
            var deferredHost = false
            var postPingActiveLink = prePingActiveLink
            var retryLink: String?
            // 测速窗口内有没有用户/ App 动作（亲手起停、开 App、
            // 源下载开关）：有，收尾就不再按测速前状态恢复，
            // 否则会把用户在测速窗口内亲手做的决定 undo 回去
            // （测速中亲手停核心，测完又被起回来；或反过来）。
            // 没动作时才按测速前状态恢复，并把恢复结果记下来
            // 供预热抑制和收尾后校验用；有动作时清掉旧的恢复
            // 记录，免得上一轮的恢复状态继续抑制预热。
            self.vpnCoreLock.lock()
            let epochChanged = self.coreActionEpoch != epochAtPingStart
            if !epochChanged {
                if wasRunning {
                    if !self.isRunning {
                        if let orig = originalRunningLink, !orig.isEmpty {
                            let ok = self.start(withLink: orig)
                            if ok {
                                self.coreOwnerBundleId = originalOwner
                            } else {
                                retryLink = orig
                                self.pingRetryLink = orig
                            }
                        } else {
                            let ok = self.start()
                            if !ok, !self.nodeLink.isEmpty {
                                retryLink = self.nodeLink
                                self.pingRetryLink = self.nodeLink
                            }
                        }
                    }
                } else if self.isRunning {
                    self.stop()
                }
                self.lastPingRestoredRunning = self.isRunning
                self.lastPingRestoreAt = Date()
            } else {
                // 用户动作优先：延迟重试也不再跑，免得它在用
                // 户亲手停核心后又把核心起回来。
                self.pingRetryLink = nil
                self.lastPingRestoredRunning = nil
            }
            postPingActiveLink = self.nodeLink
            deferredApp = self.deferredEnsureApp
            self.deferredEnsureApp = nil
            deferredHost = self.deferredHostEnsure
            self.deferredHostEnsure = false
            self.isPinging = false
            self.vpnCoreLock.unlock()
            if let retryLink {
                // 延迟重试一次性消费：用户此后亲手停核心会
                // 经 stop() 清掉 pingRetryLink，闭包里再判一
                // 次，绝不在用户停核心后又把它起回来；新一
                // 轮测速开始时 isPinging 为真，旧重试直接作废。
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    self.vpnCoreLock.lock()
                    let stillPending = self.pingRetryLink == retryLink && !self.isPinging
                    self.pingRetryLink = nil
                    let needRetry = stillPending && !self.isRunning
                    self.vpnCoreLock.unlock()
                    if needRetry {
                        _ = self.start(withLink: retryLink)
                    }
                }
            }
            if let deferredApp {
                self.ensureRunning(for: deferredApp)
            } else if postPingActiveLink != prePingActiveLink {
                self.applyActiveNodeChange()
            }
            if deferredHost {
                self.ensureRunningForHost()
            }
            // 收尾后校验（只认同一代次、且收尾后没有新的用户/
            // App 动作）：收尾把状态恢复对了，之后几秒内若被
            // 自动触发（切回前台的预热等）悄悄翻回去，这里一
            // 次性把它按回恢复成的状态。用户亲手起停、开 App、
            // 源下载开关都会让 epoch 变化，校验直接作废，不会
            // undo 用户的决定；新一轮测速开始也会让代次变化，
            // 旧校验同样作废。只校验一次，不循环。
            self.vpnCoreLock.lock()
            let verifiedRunning = self.isRunning
            let verifiedLink = self.runningLink
            let verifiedOwner = self.coreOwnerBundleId
            let verifiedEpoch = self.coreActionEpoch
            self.vpnCoreLock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.vpnCoreLock.lock()
                let stillSamePing = self.pingGeneration == pingGen && !self.isPinging
                let noNewAction = self.coreActionEpoch == verifiedEpoch
                let flipped = self.isRunning != verifiedRunning
                self.vpnCoreLock.unlock()
                guard stillSamePing, noNewAction, flipped else { return }
                if verifiedRunning {
                    // 起回后把归属也还原：start(withLink:) 不写
                    // 归属，stop() 又把它清掉了，不还原的话下
                    // 一个 App 启动就能抢走这条钉死节点的核心。
                    let ok: Bool
                    if let link = verifiedLink, !link.isEmpty {
                        ok = self.start(withLink: link)
                    } else {
                        ok = self.start()
                    }
                    if ok {
                        self.vpnCoreLock.lock()
                        self.coreOwnerBundleId = verifiedOwner
                        self.vpnCoreLock.unlock()
                    }
                } else {
                    self.stop()
                }
            }
            let items = outcome.items
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// 逐批调 pingBatch（同步阻塞，必须在后台线程调）
    private func runPingBatches(links: [String], url: String) -> (items: [CZFNodePingResult], batchRejected: Bool) {
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
                "url": url,
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
        let scheme: String
        if link.hasPrefix("vless://") {
            scheme = "vless://"
        } else if link.hasPrefix("trojan://") {
            scheme = "trojan://"
        } else {
            return link
        }
        let rest = String(link.dropFirst(scheme.count))
        let authEnd = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = String(rest[..<authEnd])
        if authority.contains("@") {
            // 标准格式：只翻译小火箭参数，其余原样。
            return rewriteShadowrocketParams(link)
        }
        guard scheme == "vless://" else { return link } // trojan 老格式不动

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
        // 小火箭写法：obfs=websocket 即 ws，obfsParam 即 WS host；标准参数优先。
        let type = query["type"] ?? query["net"] ?? (query["obfs"] == "websocket" ? "ws" : nil) ?? "tcp"
        out.append(("type", type))
        if type == "ws" {
            if let h = query["host"] ?? query["obfsParam"], !h.isEmpty { out.append(("host", h)) }
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

    // 标准格式链接里的小火箭参数翻译：只在查询串后追加标准参数，
    // authority 与片段、原有参数串一律原样不动。
    // obfs=websocket → type=ws（仅当没写 type/net 时）；
    // obfsParam → host（仅当没写 host 且最终是 ws 时）；
    // peer → sni（仅当没写 sni 时）。三个参数一个都没有时原样返回。
    private static func rewriteShadowrocketParams(_ link: String) -> String {
        guard let qStart = link.firstIndex(of: "?") else { return link }
        let afterQ = link[link.index(after: qStart)...]
        let hashIdx = afterQ.firstIndex(of: "#")
        let qStr = hashIdx.map { String(afterQ[..<$0]) } ?? String(afterQ)
        let fragment = hashIdx.map { String(afterQ[$0...]) } ?? ""
        // 只读键与解码后的值做判断，原有参数串不重编码。
        var keys = Set<String>()
        var values: [String: String] = [:]
        for pair in qStr.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                keys.insert(String(parts[0]))
                values[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        var add: [String] = []
        if !keys.contains("type"), !keys.contains("net"), values["obfs"] == "websocket" {
            add.append("type=ws")
        }
        let finalIsWS = values["type"] == "ws" || values["net"] == "ws" || add.contains("type=ws")
        if finalIsWS, !keys.contains("host"), let h = values["obfsParam"], !h.isEmpty {
            add.append("host=" + (h.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? h))
        }
        if !keys.contains("sni"), let s = values["peer"], !s.isEmpty {
            add.append("sni=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s))
        }
        guard !add.isEmpty else { return link }
        let base = String(link[..<qStart])
        let sep = qStr.isEmpty ? "" : "&"
        return base + "?" + qStr + sep + add.joined(separator: "&") + fragment
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
        // 源下载开关在测速窗口内打开时也不直接起核心：它
        // 和开 App 一样是用户动作，测速收尾再补跑，免得测
        // 速窗口内起核心跟测速的停/起插队、测完状态翻掉。
        vpnCoreLock.lock()
        let pinging = isPinging
        if pinging {
            deferredHostEnsure = true
            coreActionEpoch += 1
        }
        vpnCoreLock.unlock()
        if pinging { return }
        pendingStopWork?.cancel()
        pendingStopWork = nil
        if !isRunning {
            vpnCoreLock.lock()
            coreActionEpoch += 1
            vpnCoreLock.unlock()
            _ = start()
        }
    }

    /// 读按包名统计文件并解析成 k=v 表；文件没有/读不出返回 nil。
    /// 统计文件在插件自己的目录（CZFVPN）里：多选时先找它，
    /// 没有再退第一个文件夹（旧单选行为），都没有才看开关默认
    private static func proxyStatsDict(for appInfo: LCAppInfo) -> [String: String]? {
        let czfFolders = LCAppModel.czfSplitTweakFolders(appInfo.tweakFolder)
        guard let folderName = czfFolders.first(where: { $0 == "CZFVPN" }) ?? czfFolders.first ?? (isEnabled(for: appInfo) ? "CZFVPN" : nil) else { return nil }
        let base = appInfo.isShared ? LCPath.lcGroupTweakPath : LCPath.tweakPath
        let folder = base.appendingPathComponent(folderName)
        // 统计按 App 分文件（插件按包名命名）；按包名文件没有就不显示，
        // 不再退读老版共用文件——那是各 App 混在一起的老数，显示成当前
        // App 的就是错数
        let bid = appInfo.bundleIdentifier() ?? ""
        let url = folder.appendingPathComponent("CZFProxyStats-\(bid).txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var dict: [String: String] = [:]
        for part in raw.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        return dict
    }

    /// 自检 0 = 钩子没装上、代理没生效；只有统计文件里明确写 0 才报，
    /// 没文件时不报（那时统计行本身也不显示）
    public static func proxySelfTestFailed(for appInfo: LCAppInfo) -> Bool {
        proxyStatsDict(for: appInfo)?["selftest"] == "0"
    }

    public static func proxyStatsText(for appInfo: LCAppInfo) -> String? {
        guard let dict = proxyStatsDict(for: appInfo) else { return nil }
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
