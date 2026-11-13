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
import LiveContainerShared

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
    // B-3 sing-box 配置缓存：上次成功启动的（链接，配置 JSON）。
    // configJSON 只由链接 + 固定端口（10827/10828）+ 固定日志
    // 路径（singBoxLogPath，进程内不变）决定，同一链接生成的
    // JSON 字节相同；只存内存不落盘（进程重启即丢，容器路径
    // 变了旧 JSON 里的日志路径也会过期）。只在 vpnCoreLock 下
    // 读写：startSingBox 的调用方 start(withLink:) 已持锁，
    // 不另加锁。stop() 不清它——测速停/启、自动停、手动开关
    // 的停→启正是要复用的场景；链接变了 key 对不上自然重建。
    private var cachedSingBoxLink: String?
    private var cachedSingBoxConfig: String?
    // 当前在跑的是哪个核心（nil = 没在跑）：TUIC-only 单活切换
    // 的唯一事实来源——start 成功时记、stop 时清；测速分流
    // 与停核心都读它，绝不凭 isRunning 猜核心种类。
    private var runningCore: CZFCoreKind?
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
    // O-29：每链接上次探通时间——连开几个 VPN App 时每个都实网探
    // 一次，白白建会话、打 generate_204。60 秒内同一链接直接放行，
    // 省重复探针、省电；坏节点轮换仍靠 scheduleRotateCheck 兜底，
    // TTL 只省“刚验过”的重复验证，不影响首次探与失败重试。
    // 读写都在 vpnCoreLock 下（waitUntilNodeReady 各路并发调）。
    // 键是链接字面量，节点列表就那么多张，不会无限涨。
    private var czfLastProbeOK: [String: Date] = [:]
    private let czfProbeTTL: TimeInterval = 60
    // 节点自动轮换：核心在跑时每 30 秒读归属 App 的插件统计，
    // 窗口内失败一直涨、成功代理一条不涨，就判定当前节点对该
    // App 已死，按列表顺序切下一个支持协议的节点并重启核心。
    // 归属 App 与 coreOwnerBundleId 同步记、同步清。
    private var coreOwnerAppInfo: LCAppInfo?
    private var pendingRotateWork: DispatchWorkItem?
    private var rotateLastFailed: Int64?
    private var rotateLastProxied: Int64?
    private var rotateBaselineLink: String?
    private var rotateCooldownUntil = Date.distantPast
    private var rotateTriedLinks = Set<String>()
    private static let autoRotateKey = "CZFVPNAutoRotate"
    // 轮换开关：键不存在 = 开（用户亲令要轮换，默认开着，随时可关）
    public static var isAutoRotateEnabled: Bool {
        guard let v = UserDefaults.standard.object(forKey: autoRotateKey) as? Bool else { return true }
        return v
    }
    public static func setAutoRotate(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoRotateKey)
        if enabled {
            shared.scheduleRotateCheck()
        } else {
            shared.cancelRotateCheck()
        }
    }
    // 核心状态串行化：start/stop/开 App 预热原来在
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
    // 的 deferredEnsure / 切节点跟随），否则测速结果会被
    // 插队的核心启停打乱（pingBatch 被拒）。
    private var isPinging = false
    // 测延迟自动停核心的恢复快照：startVPNPing 在核心在跑
    // 时先停、测完凭它重启原来那条（归属原样）；核心没在
    // 跑时不写，测完不启动。一次性的，restart 读完即清。
    private var pingStoppedLink: String?
    private var pingStoppedOwner: LCAppInfo?
    // 测速窗口内被挡下的开 App 请求：只记最后一个，测速完
    // 再给它 ensureRunning（游客启动时等核心，见 LCAppModel
    // 的 vpnCoreTask；挡下不等于丢掉）。
    private var deferredEnsureApp: LCAppInfo?
    // 旧测速收尾写过的延迟重试链接：只读版测速不再写它，
    // 仅 stop() 在非测速窗口内清掉它作兼容；用户亲手停核
    // 心时同样清掉，不留事后起回来的尾巴。
    private var pingRetryLink: String?
    // 用户/ App 动作计数：测速收尾要不要碰预热抑制，
    // 就看测速窗口内有没有这类动作。开 App（ensureRunning，
    // 含测速收尾补跑）、源下载开关（ensureRunningForHost）、
    // 设置页亲手起停核心（noteManualCoreToggle）都会 +1；
    // 预热、测速自身不 +1——它们是自动触发，不能反过来
    // 推翻用户/ App 在测速窗口内做的决定。
    private var coreActionEpoch = 0
    // 测速代次：每轮 pingAllNodes 开始时 +1，保留作代次
    // 区分；只读版已删收尾后校验，不再用它去翻状态。
    private var pingGeneration = 0
    // 测速结束时核心没在跑时对预热的持久抑制：v186 只压
    // 10 秒，超过窗口、切走再进 App，预热又把核心起回来，
    // 用户认定的就是“测速改了核心”。本标志只在测速收尾
    // 看到核心没在跑时置真，且落盘（UserDefaults），宿
    // 主进程重启也不丢；只由三类手动动作清掉：亲手起核心、
    // 打开标了 VPN 的 App、亲手拨一次预热开关。预热开关值
    // 本身不动，开关关着时 prewarmIfNeeded 本来就返回，
    // 本标志不影响它。测速结束时核心在跑就清掉，不留旧抑制。
    private var prewarmSuppressedAfterPing: Bool {
        get { UserDefaults.standard.bool(forKey: "CZFVPNPrewarmSuppressedAfterPing") }
        set { UserDefaults.standard.set(newValue, forKey: "CZFVPNPrewarmSuppressedAfterPing") }
    }
    // 设置页显示用：测速后预热是否被压着（开关开着也不预热时，
    // 界面要把这个状态说出来，不能让用户以为预热坏了）。
    public var isPrewarmSuppressedAfterPing: Bool {
        UserDefaults.standard.bool(forKey: "CZFVPNPrewarmSuppressedAfterPing")
    }
    // 3.8.282：核心上次开/关（重启恢复用）：start() 成功写
    // true，stop() 写 false；没写过（nil，从没动过开关）
    // 时按老行为（只预热，不强制恢复）。测速的停→启走同
    // 一对函数，净结果就是测速前后的真实状态，不会写错。
    private var coreWasRunning: Bool? {
        get { UserDefaults.standard.object(forKey: "CZFVPNCoreWasRunning") as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: "CZFVPNCoreWasRunning") }
    }
    // 测速窗口内被挡下的源下载开关起核心请求：与
    // deferredEnsureApp 同理，测速收尾再补跑一次。
    private var deferredHostEnsure = false
    // 核心关闭后自动停时长（CZF，可调）：设置页“单App VPN”里
    // 选 5 / 10 / 30 分钟，默认 10 分钟（以前写死 30 分钟）。
    // 注意定义：只在最后一个标 VPN 的 App 关窗后计时，
    // 最小化不算关、不计时——以前叫“闲置自动停”容易误读。
    // 已排队的停核心任务仍按排队时的时长触发，但触发时按
    // 当前档位重算闲置时长：档位改短不会提前停、改长不会
    // 误停，下次 App 变化重排时按新档位来，行为安全。
    private static let autoStopMinutesKey = "CZFVPNAutoStopMinutes"
    private static var autoStopDelay: TimeInterval {
        // integer(forKey:) 在键不存在时返回 0，正好落到默认 10，
        // 不用 object(as? Int) 的桥接不确定性（仓内 activeNodeIndex 同款读法）。
        // -1 = 永不：返 .infinity，调用方（noteRunningAppsChanged）
        // 见到无限直接不排停核心，绝不拿它去排 asyncAfter。
        let minutes = UserDefaults.standard.integer(forKey: autoStopMinutesKey)
        if minutes == -1 { return .infinity }
        return TimeInterval([5, 10, 30].contains(minutes) ? minutes : 10) * 60
    }

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

    // 节点变了就刷新设置备份：导入导出配置（CZFSettingsBackup.json）
    // 本来只在手动导出 / 备份 App 时写，节点增删改后不刷就过期，
    // 换机重装导入的还是旧节点；这里顺手刷一份，配置永远是最新节点。
    // 只调 DataManagement 现成的静态写函数，不改那份文件。
    private func refreshSettingsBackup() {
        LCDataManagementView.writeCZFSettingsBackupDebounced()
    }

    // 返回 true 表示真的加进去了；空链接或已存在返回 false，
    // 界面据此提示“已存在”，不再静默失败（以前直接 return，
    // 界面还把输入框清空，看起来像加上了）。
    @discardableResult
    public func addNode(_ link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var links = nodeLinks
        if links.contains(trimmed) { return false }
        links.append(trimmed)
        UserDefaults.standard.set(links, forKey: Self.nodeListKey)
        refreshSettingsBackup()
        return true
    }

    // 清理专用：只换节点列表、不碰核心。清理只是删节点，
    // 核心在跑就继续用在用节点，停着就继续停着，绝不因清理
    // 启停核心；replaceAllNodes 会调 applyActiveNodeChange，
    // 清理不能走它。
    public func replaceNodesWithoutCoreChange(_ newLinks: [String]) {
        // 保序去重：订阅自带重复链接时不进两行（单测按 firstIndex
        // 写回会永远只写第一行），调用方（合并导入）已去重也无妨。
        var seen = Set<String>()
        let cleaned = newLinks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !cleaned.isEmpty else { return }
        let previousActive = nodeLink
        UserDefaults.standard.set(cleaned, forKey: Self.nodeListKey)
        if let idx = cleaned.firstIndex(of: previousActive) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        } else {
            UserDefaults.standard.set(0, forKey: Self.activeNodeKey)
        }
        refreshSettingsBackup()
    }

    // 用一批新链接整体替换节点列表（订阅刷新用）：尽量保留
    // 当前活动节点（按内容找回），找不到就落到第一个
    public func replaceAllNodes(_ newLinks: [String]) {
        var seen = Set<String>()
        let cleaned = newLinks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !cleaned.isEmpty else { return }
        let previousActive = nodeLink
        UserDefaults.standard.set(cleaned, forKey: Self.nodeListKey)
        if let idx = cleaned.firstIndex(of: previousActive) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        } else {
            UserDefaults.standard.set(0, forKey: Self.activeNodeKey)
        }
        applyActiveNodeChange()
        refreshSettingsBackup()
    }

    /// 拉订阅内容并解析出节点链接：机场订阅通常是整段 base64
    /// （解开后一行一条链接），也有直接一行一条的明文格式，
    /// 两种都认；只保留带 :// 的行（vless/vmess/trojan/ss 等）
    public static func fetchSubscriptionLinks(urlString: String, completion: @escaping (Result<[String], Error>) -> Void) {
        var trimmedInput = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // sub:// 订阅链接：机场/客户端常发的格式，冒号后是真实订
        // 阅地址的 base64（URL 安全变体、可能缺 padding）。旧代码
        // 直接拿 sub:// 去拉，URLSession 不认这个 scheme，当场
        // 报「不支持的 URL」——正是用户 2026-10-26 截图里那条错。
        // 先解开：解出来是单条 http(s) 地址就按它拉；解出来已
        // 经是一批节点链接就直接返回，不用再发请求。
        if trimmedInput.lowercased().hasPrefix("sub://") {
            let payload = String(trimmedInput.dropFirst("sub://".count))
                .components(separatedBy: .whitespacesAndNewlines).joined()
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let decoded = Data(base64Encoded: padded),
               let decodedText = String(data: decoded, encoding: .utf8),
               !decodedText.isEmpty {
                let decodedTrimmed = decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
                let nodeLines = decodedTrimmed.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.contains("://") && !$0.lowercased().hasPrefix("http") }
                if !nodeLines.isEmpty {
                    completion(.success(nodeLines))
                    return
                }
                trimmedInput = decodedTrimmed
            } else {
                completion(.failure(NSError(domain: "CZFVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "sub:// 订阅链接解不出来"])))
                return
            }
        }
        guard let url = URL(string: trimmedInput) else {
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
        refreshSettingsBackup()
    }

    /// 重启恢复（耗电修法，用户令“启动需要 VPN 的 App 时
    /// 再开启”，eager 预热已删）：只做一件事——上次亲手
    /// 开着核心，宿主重启后起回来。从不因“有 App 标了
    /// VPN”就提前起核心；要 VPN 的 App 启动时由 runApp
    /// 的 ensureRunning 按需起（见 LCAppModel.runApp），
    /// 全部关掉后自动停照常。预热开关（CZFVPNPrewarm）
    /// 不再触发启动，设置页那行先不动。
    /// ignoringSuppression：前台进 App 页时传 true——恢复
    /// 本就是用户亲手开过的意图，不被测速后抑制拦住。
    public func prewarmIfNeeded(ignoringSuppression: Bool = false) {
        // 测速窗口内不恢复：起核心会让 pingBatch 被拒、
        // 测速结果不准；恢复本就是 opportunistic，下次进前台还会再跑
        vpnCoreLock.lock()
        let pinging = isPinging
        // 测速结束时核心没在跑就一直不恢复：见字段注释，
        // 与时间无关、切走再进、进程重启都不放行，直到
        // 亲手起核心、打开标了 VPN 的 App、亲手拨一次
        // 预热开关三者之一出现；前台进 App 页也放行
        //（ignoringSuppression，见参数注释）。恢复成“在跑”
        // 时下面 guard !isRunning 本来就返回，不需要这层。
        let suppressed = prewarmSuppressedAfterPing
        vpnCoreLock.unlock()
        if pinging { return }
        if suppressed && !ignoringSuppression { return }
        // 3.8.282：重启恢复——上次亲手开着，宿主重启后起
        // 回来（不要求有 App 标 VPN，核心开关本身就是全局
        // 的；起成功后 start() 已把标志写回 true，起失败
        // 下次进前台再试）；上次是关的就不恢复，免得把
        // 手动关的又起回来；没记过（nil，从没动过开关）
        // 也不起——只开 LiveContainer 看一眼不该起核心。
        if let wasRunning = coreWasRunning {
            if wasRunning, !isRunning, !nodeLinks.isEmpty {
                _ = start()
            }
        }
    }

    public func removeNode(at index: Int) {
        var links = nodeLinks
        guard links.indices.contains(index) else { return }
        // 删在用节点：以前 previousActive 找不回来就落到最后
        // 一个，applyActiveNodeChange 还会在核心在跑时直接按
        // 新节点重启——用户删在用节点本意是停掉，结果被静默
        // 切到别的节点继续跑。现在删在用节点就停核心，不自
        // 动切；选中项落到第一个（核心停着，不会立刻生效）。
        // 删非在用节点仍按内容找回，不动核心归属。
        let wasActive = index == activeNodeIndex
        let previousActive = nodeLink
        links.remove(at: index)
        UserDefaults.standard.set(links, forKey: Self.nodeListKey)
        if let newIdx = links.firstIndex(of: previousActive) {
            UserDefaults.standard.set(newIdx, forKey: Self.activeNodeKey)
        } else if wasActive {
            UserDefaults.standard.set(0, forKey: Self.activeNodeKey)
        } else {
            UserDefaults.standard.set(max(links.count - 1, 0), forKey: Self.activeNodeKey)
        }
        if wasActive {
            stop()
        } else {
            applyActiveNodeChange()
        }
        refreshSettingsBackup()
    }

    public func setActiveNode(at index: Int) {
        guard nodeLinks.indices.contains(index) else { return }
        UserDefaults.standard.set(index, forKey: Self.activeNodeKey)
        applyActiveNodeChange()
        refreshSettingsBackup()
    }

    // 活动节点变了而核心在跑：立刻按新节点重启（改完即生效）；
    // 没有可用节点了就停掉
    private func applyActiveNodeChange() {
        // 测速窗口内不切：切节点会重启核心、打断测速；
        // 节点选择已写进 UserDefaults，测速收尾
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

    // 优5（3.8.277）：恢复/导入已把节点列表与活动下标写回
    // defaults 后调——核心在跑且活动节点变了就重启切过去，
    // 不需重启 App；核心停着时下次启动现读新节点。测速窗口
    // 内推迟到测速收尾跟随（applyActiveNodeChange 同款守卫）。
    // 起核心是同步阻塞的 CGoInvoke，调用方放 detached 跑。
    public func applyRestoredNodeSettings() {
        applyActiveNodeChange()
    }

    // 节点自定义别名：按链接原文存字典（UserDefaults），
    // 删节点/改链接时旧别名自然失效（键对不上就不用），
    // 不另做清理——字典里多一条死记录无害。
    private static let nodeAliasKey = "CZFVPNNodeAliases"
    public static func nodeAlias(for link: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: nodeAliasKey) as? [String: String])?[link]
    }
    public static func setNodeAlias(_ alias: String?, for link: String) {
        var dict = UserDefaults.standard.dictionary(forKey: nodeAliasKey) as? [String: String] ?? [:]
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            dict[link] = alias
        } else {
            dict.removeValue(forKey: link)
        }
        UserDefaults.standard.set(dict, forKey: nodeAliasKey)
    }

    // 改一条节点的链接（长按菜单“编辑链接”用）：只换列表
    // 不碰核心；改的正是在用节点时活动下标跟到新链接，
    // 不落到第一个；改的不是在用节点时按内容找回不动。
    // 已有相同链接时返回 false（不造重复行），调用方据此提示。
    @discardableResult
    public func updateNode(at index: Int, with newLink: String) -> Bool {
        let trimmed = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var links = nodeLinks
        guard links.indices.contains(index) else { return false }
        if links[index] != trimmed && links.contains(trimmed) { return false }
        let wasActive = index == activeNodeIndex
        links[index] = trimmed
        UserDefaults.standard.set(links, forKey: Self.nodeListKey)
        if wasActive {
            UserDefaults.standard.set(index, forKey: Self.activeNodeKey)
        } else if let idx = links.firstIndex(of: nodeLink) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        }
        refreshSettingsBackup()
        // 改的正是在用节点：核心还在跑旧链接，界面却已把新链接标成
        // 在用——与 setActiveNode（改完即重启生效）/ replaceAllNodes
        // 同款，立刻跟过去；测速窗口内 applyActiveNodeChange 会推
        // 迟到测速收尾跟随，核心停着时是空操作。
        if wasActive {
            applyActiveNodeChange()
        }
        return true
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
        // 行内显示 scheme：节点行一眼看出协议；支不支持由
        // isSupportedNodeScheme 按转换器清单再分级（未测到的
        // 不支持节点行内直接标“不支持”，不等人测完才知道）。
        let scheme = nodeScheme(for: link)
        if !scheme.isEmpty {
            detail = detail.isEmpty ? scheme : "\(scheme) · \(detail)"
        }
        // 不验证书标记：tuic 且含 allowInsecure 时标（判定在
        // CZFSingBoxRouting.showsInsecureMark：tuic 出站一定
        // 写 tls 块，insecure 参数真实生效才标）。
        if CZFSingBoxRouting.showsInsecureMark(for: link) {
            detail = detail.isEmpty ? "不验证书" : "\(detail) · 不验证书"
        }
        // 自定义别名优先：用户亲手起的名字盖过链接备注/地址，
        // 详情行（协议·地址）不动，行上仍能认出是哪个节点。
        if let alias = nodeAlias(for: link), !alias.isEmpty {
            name = alias
        }
        return (name, detail)
    }

    /// 节点链接的协议 scheme（小写；原始 Xray JSON 出站记
    /// 为 json；无 :// 的纯文本行记为空串）。取原文链接，
    /// 不取归一化后的（老格式 vless 归一化后 scheme 不变，
    /// 但原文才是用户贴进来的协议）。
    public static func nodeScheme(for link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return "json"
        }
        guard let range = trimmed.range(of: "://") else {
            return ""
        }
        return String(trimmed[..<range.lowerBound]).lowercased()
    }

    /// 转换器清单分级：libXray convertShareLinksToXrayJson 只
    /// 认这些协议族（VMessAEAD/VLESS/Hysteria2/SS/SOCKS/
    /// Trojan）+ 原始 JSON 出站绕法 + sing-box 的 TUIC；
    /// 其余未列出的 scheme、无 scheme 的纯文本一律不支持。
    /// 注意这是静态分级：
    /// 清单内的节点仍可能因老格式、allowInsecure 等参数被
    /// 转换器拒收，那种以实测的 conversionFailed 为准。
    public static func isSupportedNodeScheme(_ scheme: String) -> Bool {
        // hy2 = Hysteria2 的标准别名，socks5 = SOCKS 的标准链接
        // scheme；静态分级宁可多认别名——真不认的节点实测时
        // conversionFailed 会纠回“不支持”，反过来漏标却要等
        // 实测才知道它是好的。
        ["vmess", "vless", "hysteria2", "hy2", "ss", "socks", "socks5", "trojan", "json", "tuic"].contains(scheme)
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
            // H-9 快筛：先比文件大小+修改时间，都一样就不读文件
            // 直接判相同；不一样（或取不到属性）再整份比字节，
            // 结论不变，只省一次全量读。
            let czfSameByAttrs: Bool = {
                guard let sAttrs = try? fm.attributesOfItem(atPath: src.path),
                      let dAttrs = try? fm.attributesOfItem(atPath: dest.path),
                      let sSize = sAttrs[.size] as? NSNumber,
                      let dSize = dAttrs[.size] as? NSNumber,
                      let sDate = sAttrs[.modificationDate] as? Date,
                      let dDate = dAttrs[.modificationDate] as? Date else { return false }
                return sSize == dSize && sDate == dDate
            }()
            if !czfSameByAttrs {
                let srcData = try? Data(contentsOf: src)
                let destData = try? Data(contentsOf: dest)
                if destData != srcData {
                    try? fm.removeItem(at: dest)
                    try? fm.copyItem(at: src, to: dest)
                    return true
                }
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
    public func noteManualCoreToggle(started: Bool) {
        vpnCoreLock.lock()
        coreActionEpoch += 1
        // 亲手起核心才清掉测速后的预热抑制：亲手停核心不
        // 清——停完切回前台又被预热起回来，和测速后翻盘是
        // 同一类毛病；想恢复预热，拨一次预热开关即可。
        if started { prewarmSuppressedAfterPing = false }
        vpnCoreLock.unlock()
    }

    // 设置页亲手拨预热开关时调：只清掉测速后的预热抑制，
    // 不记进 coreActionEpoch——拨开关本身不动核心状态，
    // 不应让测速收尾因此跳过恢复。
    public func notePrewarmSwitchToggled() {
        vpnCoreLock.lock()
        prewarmSuppressedAfterPing = false
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
        // 测速窗口内不开核心：这时起核心会让 pingBatch 被拒、
        // 测速结果不准。只记下这次请求，测速收尾会补跑它；取消自动
        // 停、记启动时间、补钉节点这三件上面已经做了，不受
        // 挡下影响。
        vpnCoreLock.lock()
        let pinging = isPinging
        if pinging, let appInfo {
            deferredEnsureApp = appInfo
        }
        vpnCoreLock.unlock()
        if pinging { return }
        // 打开标了 VPN 的 App 是手动动作：清掉测速后的预热
        // 抑制，之后预热/自动启动照常工作。测速窗口内被挡
        // 下的请求走收尾补跑，补跑时 pinging 已是 false，
        // 同样在这里清掉；测速窗口内只记不启动，抑制不动。
        if appInfo != nil {
            vpnCoreLock.lock()
            prewarmSuppressedAfterPing = false
            vpnCoreLock.unlock()
        }
        // 用这个 App 自己的节点（钉死过就用钉死的，没钉死跟随
        // 全局）
        let link = effectiveLink(for: appInfo).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        if isRunning && runningLink == link {
            claimCoreOwnershipIfRunning(link: link, for: appInfo)
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
            claimCoreOwnershipIfRunning(link: link, for: appInfo)
        } else {
            // 启动时节点起不来就地往下一个切：之前是起不来
            // 就停在死节点上，App 一直不通；轮换要等 3 次
            // 失败才触发，根本等不到。排序与轮换同款（新鲜
            // 测速从快到慢，没测速排最后），钉死的改 override，
            // 跟随全局的改全局活动节点；一圈都不通就停。
            startFallback(from: link, for: appInfo)
        }
    }

    /// 起核心后认领归属（ensureRunning / startFallback /
    /// waitUntilNodeReady 三路共用）：只有在同一把锁下看到
    /// runningLink 仍是刚起的那条才认领。两个 VPN App 同时启动
    /// 时，后起的会把核心换成自己的节点；先起的不能在事后把
    /// 归属写成自己——归属与在跑链接对不上，轮换巡检会按错
    /// App 读统计。没认领时不排轮换，归属方自己的那路会排。
    private func claimCoreOwnershipIfRunning(link: String, for appInfo: LCAppInfo?) {
        vpnCoreLock.lock()
        let claimed = isRunning && runningLink == link
        if claimed {
            if let bid = appInfo?.bundleIdentifier() {
                coreOwnerBundleId = bid
            }
            coreOwnerAppInfo = appInfo
        }
        vpnCoreLock.unlock()
        if claimed {
            scheduleRotateCheck()
        }
    }

    // 11（3.8.277）：等节点真正就绪再放行 App 启动（runApp 在
    // 核心任务 await 后调）。start() 只等核心开始监听（SOCKS
    // 口起来），节点首次握手是懒触发的——光等 ensureRunning，
    // App 起来时节点还没通，头几秒请求全失败。经核心发一次
    // 真实请求验节点：通了立刻返回 true；不通按测速顺序切
    // 下一个再探（最多 3 个节点）；超时/都探不通返回 false，
    // 调用方按现有 fail-open 放行，绝不无限等。只在核心正跑
    // 着该 App 的节点时才探；核心被别的 App 占着、或根本没
    // 起来时直接返回 false，不动别人的节点。严格模式语义不
    // 动：探不通也不改标记、不改直连与否。
    // timeout 是单次探测超时（秒）：核心自己的握手超时是 4 秒
    //（Xray policy handshake），5 秒是它加 1 秒余量。
    public func waitUntilNodeReady(for appInfo: LCAppInfo?, timeout: TimeInterval = 5) async -> Bool {
        guard let appInfo else { return false }
        let link = effectiveLink(for: appInfo).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return false }
        vpnCoreLock.lock()
        let running = isRunning
        let currentLink = runningLink
        vpnCoreLock.unlock()
        guard running, currentLink == link else { return false }
        // O-29：60 秒内同一链接刚探通过，直接放行，不再实网探。
        // 只在核心正跑着该 App 的节点时短路；核心没起来/换了
        // 链接时上面 guard 已返回 false，不走这里。
        vpnCoreLock.lock()
        let lastOK = czfLastProbeOK[link]
        vpnCoreLock.unlock()
        if let lastOK, Date().timeIntervalSince(lastOK) < czfProbeTTL {
            return true
        }
        if await probeNodeThroughCore(timeout: timeout) {
            noteProbeOK(link: link)
            return true
        }
        // 不通立刻切下一个（不等攒够 3 次失败才轮换）：
        // 候选按新鲜测速从快到慢（startFallback 同款排序），
        // 最多再试 2 个；都探不通就 fail-open，调用方照常启动。
        let links = nodeLinks
        guard links.count >= 2 else { return false }
        let cands = Self.sortedSupportedCandidates(links: links, excluding: [link])
        for cand in cands.prefix(2) {
            // 测速窗口内不切节点起核心：这轮探针是 runApp 派的，
            // 用户此时点“测延迟”会先停核心再测；这里中途起核心
            // 会让 pingBatch 被拒、整轮测速作废。直接返回 false，
            // 调用方按 fail-open 放行，绝不无限等。
            vpnCoreLock.lock()
            let pinging = isPinging
            vpnCoreLock.unlock()
            guard !pinging else { return false }
            // 起核心是同步阻塞的 CGoInvoke，放 detached 跑，
            // 不冻调用方的协作线程（runApp 侧同款做法）。
            let started = await Task.detached(priority: .userInitiated) { CZFVPNManager.shared.start(withLink: cand.link) }.value
            guard started else { continue }
            if Self.nodeOverride(for: appInfo) != nil {
                Self.setNodeOverride(cand.link, for: appInfo)
            } else {
                UserDefaults.standard.set(cand.idx, forKey: Self.activeNodeKey)
            }
            claimCoreOwnershipIfRunning(link: cand.link, for: appInfo)
            if await probeNodeThroughCore(timeout: timeout) {
                noteProbeOK(link: cand.link)
                return true
            }
        }
        return false
    }

    /// O-29：记一笔探通时间（vpnCoreLock 下写，与读同一把锁）。
    private func noteProbeOK(link: String) {
        vpnCoreLock.lock()
        czfLastProbeOK[link] = Date()
        vpnCoreLock.unlock()
    }

    // 经核心发一次真实请求验节点：走 HTTP 10828 代理访
    // generate_204（空回应、最轻），拿到任何 HTTP 回应即算
    // 通（出站失败时核心直接断连接、不回 HTTP）。不用
    // cp.cloudflare.com 作探针——有些节点单拦 Cloudflare
    // 那一路、实际经节点上网是通的（测速里的假不通同款教训）。
    // 超时/抛错即不通。只读，不改核心与节点状态。
    private func probeNodeThroughCore(timeout: TimeInterval) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = Self.proxyDictionary()
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let url = URL(string: "https://www.gstatic.com/generate_204") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    // 多任务列表变化后由 MultitaskDockManager 调用：还在跑的
    // App 里已经没有被标记的了，就按自动停档位排一个停核心；
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
        // 永不档：前面已取消待停任务，这里不再排新的——
        // asyncAfter 拿 .infinity 排期行为未定义，绝不能排。
        guard !Self.autoStopDelay.isInfinite else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.checkPendingStop()
        }
        pendingStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoStopDelay, execute: work)
    }

    /// 到点的自动停检查（noteRunningAppsChanged 排的任务与测速中
    /// 的重试共用）：逐项重查——核心还在跑、宿主开关关着、闲置
    /// 够分钟数、测速窗口外，四项全过才停。测速窗口内不算数：
    /// 30 秒后重查一次（测速有界、一定会结束），而不是丢掉这次
    /// 自动停、等下一次 App 变化（可能永远不来，核心就一直跑）。
    /// 重试同样逐项重查：期间有 App 启动/宿主开关打开，重查会
    /// 拦下，不会误停。
    private func checkPendingStop() {
        guard isRunning else { return }
        if Self.isHostProxyEnabled { return }
        if Date().timeIntervalSince(lastFlaggedLaunchAt) < Self.autoStopDelay { return }
        vpnCoreLock.lock()
        let pinging = isPinging
        vpnCoreLock.unlock()
        if pinging {
            let retry = DispatchWorkItem { [weak self] in
                self?.checkPendingStop()
            }
            pendingStopWork = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: retry)
            return
        }
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        // 手动 / 宿主 / 预热起核心：不归某个 App 所有，清掉
        // 养号归属，之后 App 自动启动才可以重新抢核心
        coreOwnerBundleId = nil
        coreOwnerAppInfo = nil
        let ok = start(withLink: nodeLink)
        // 3.8.282：起成功了就记下“开着”，宿主重启后恢复
        // 成开着；起失败不写（状态没变）。stop() 里对称写“关着”。
        if ok { coreWasRunning = true }
        return ok
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
        // B1（重启不丢恢复意图）：下面的 stop() 会把 coreWasRunning
        // 写成 false，但这只是换节点的中间态，不是用户关核心——
        // 成功后按停之前的原值恢复；失败则保持 false（核心确实停了）。
        let wasRunningFlag = coreWasRunning
        if isRunning { stop() }

        // 临时探针在跑时拒绝起主核心（Xray 与 sing-box 两路都挡）：
        // 探针与主核心同进程只能活一个，探针起在前、主核心后起
        // 就是双运行时；探针几秒就完，拒绝后重试即可。stop()
        // 后 flag 仍为真只可能是探针（stop 成败都清 flag），
        // 所以这句报错只会在测速进行中出现。
        if CZFSingBoxCore.isServiceRunning {
            lastError = "测速进行中，稍后再试"
            return false
        }

        // TUIC-only 分流：tuic 走 sing-box，其余走 245 原有
        // Xray 转换与启动（原样不动）。分流前已停掉旧核心
        // （先停后起，同一时刻只活一个核心，端口复用）。
        if CZFSingBoxRouting.coreKind(for: link) == .singBox {
            let ok = startSingBox(withLink: link)
            if ok { coreWasRunning = wasRunningFlag }
            return ok
        }

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
        // 多路复用：vmess/vless/trojan/shadowsocks 出站开 mux，并发 8，
        // 多请求共用一条连接、省反复握手；direct/block、socks 及
        // 用户自带 json 不动；转换结果自带 mux 时不覆盖。
        if let proto = node["protocol"] as? String,
           ["vmess", "vless", "trojan", "shadowsocks"].contains(proto),
           node["mux"] == nil {
            node["mux"] = ["enabled": true, "concurrency": 8] as [String: Any]
        }

        // O-7：Xray 日志目录先建出来——Xray 自己不建目录，
        // 目录不存在时 access/error 文件打不开。建失败也不拦
        // 启动（try?，失败时 Xray 侧写日志失败而已）。
        try? FileManager.default.createDirectory(at: Self.xrayLogDirectory, withIntermediateDirectories: true)

        let config: [String: Any] = [
            // O-7：loglevel warning → info，并落盘 access/error
            // 到 Documents/xray/（原来只 warning 且不写文件，
            // 节点断流时无据可查）。sing-box 侧同款在
            // CZFSingBoxConfig.configJSON 里（level info +
            // output → Documents/singbox/sing-box.log）。
            "log": ["loglevel": "info", "access": Self.xrayAccessLogURL.path, "error": Self.xrayErrorLogURL.path],
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
        runningCore = .xray
        lastError = nil
        coreWasRunning = wasRunningFlag
        return true
    }

    // sing-box 核心启动（调用方 start(withLink:) 已持锁且已
    // 停掉旧核心，这里不再重复加锁）。配置端口与 Xray 侧复用
    // 同一对回环端口（SOCKS 10827 / HTTP 10828），插件侧的
    // 代理指向不用改。启动失败时 isRunning 保持 false、
    // runningCore 保持 nil，不碰严格标记：钉死节点的 App
    // 插件读到 CZFProxyStrict 标记仍断网不直连（fail-closed），
    // 跟随全局的 App 维持既有 fail-open——失败本身绝不
    // 偷偷改成直连或改标记。
    private func startSingBox(withLink link: String) -> Bool {
        // B-3：链接与上次成功启动的相同，直接复用已校验过的
        // 配置 JSON 并跳过 CheckConfig（同一份 JSON 校验结果
        // 确定，重复生成 + 全量校验是纯浪费）；链接变了或无
        // 缓存才重新生成并全量校验。失败不写缓存。
        let config: String
        let skipCheck: Bool
        if link == cachedSingBoxLink, let cached = cachedSingBoxConfig {
            config = cached
            skipCheck = true
        } else {
            do {
                config = try CZFSingBoxConfig.configJSON(for: link, socksPort: Self.socksPort, httpPort: 10828)
            } catch {
                lastError = "节点配置生成失败：\(error.localizedDescription)"
                return false
            }
            skipCheck = false
        }
        do {
            try CZFSingBoxCore.start(configJSON: config, skipCheck: skipCheck)
        } catch {
            lastError = "sing-box 启动失败：\(error.localizedDescription)"
            return false
        }
        cachedSingBoxLink = link
        cachedSingBoxConfig = config
        isRunning = true
        runningLink = link
        runningCore = .singBox
        lastError = nil
        return true
    }

    public func stop() {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        // 旧测速延迟重试链接的清理：只读版测速不再写它，
        // 这里只在非测速窗口内清掉残留，免得事后起回来。
        if !isPinging { pingRetryLink = nil }
        // 按在跑的核心种类停对应核心（runningCore 是唯一事实
        // 来源；nil 时走老 stopXray 路，与旧行为一致）。
        // sing-box 的 stop 失败也吞掉（S1 语义：失败也置 false），
        // 状态照常清干净，不留半吊子在跑态。
        if runningCore == .singBox {
            try? CZFSingBoxCore.stop()
        } else {
            _ = invoke(method: "stopXray", payload: [:])
        }
        isRunning = false
        // 3.8.282：记下“关着”，宿主重启后保持关着（预热
        // 也不再把它起回来，见 prewarmIfNeeded 的闸门）。
        coreWasRunning = false
        runningLink = nil
        runningCore = nil
        coreOwnerBundleId = nil
        coreOwnerAppInfo = nil
        cancelRotateCheck()
        // 停核心后状态行不再显示上次启动失败的旧报错，
        // 改回“核心未启动”；启动失败时 start() 会重写它。
        lastError = nil
    }

    // MARK: - 节点自动轮换

    // 排一次 30 秒后的轮换检查：已排的先取消再重排，保证
    // 同一时刻只有一个巡检在跑；核心没在跑、开关关着、
    // 没有归属 App 时不排（下次起核心 / 开开关时再排）。
    private func scheduleRotateCheck() {
        pendingRotateWork?.cancel()
        pendingRotateWork = nil
        vpnCoreLock.lock()
        let running = isRunning
        let owner = coreOwnerAppInfo
        vpnCoreLock.unlock()
        guard running, Self.isAutoRotateEnabled, owner != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.rotateCheck()
        }
        pendingRotateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func cancelRotateCheck() {
        pendingRotateWork?.cancel()
        pendingRotateWork = nil
    }

    // 一轮检查：读归属 App 的插件统计，窗口内失败增量 ≥ 3
    // 且成功代理增量为 0，说明这 30 秒里被拦的连接全失败、
    // App 一条数据没拿到，当前节点对它已死 → 轮换。
    // 成功代理只要涨了，就说明节点通路还活着（个别域名失败
    // 是常态），不轮换，免得正常 App 被来回换 IP 折腾。
    private func rotateCheck() {
        pendingRotateWork = nil
        vpnCoreLock.lock()
        let running = isRunning
        let pinging = isPinging
        let link = runningLink
        let owner = coreOwnerAppInfo
        vpnCoreLock.unlock()
        guard running, Self.isAutoRotateEnabled, !pinging,
              let appInfo = owner,
              let dict = Self.proxyStatsDict(for: appInfo),
              let failed = Int64(dict["failed"] ?? ""),
              let proxied = Int64(dict["proxied"] ?? "") else {
            // 读不到统计（插件还没写文件等）：基线不动，下轮再看
            scheduleRotateCheck()
            return
        }
        // 核心换节点了（手动切或上次轮换）：基线重置，不拿旧数比
        if rotateBaselineLink != link {
            rotateBaselineLink = link
            rotateLastFailed = failed
            rotateLastProxied = proxied
            rotateTriedLinks = []
            scheduleRotateCheck()
            return
        }
        let failedDelta = failed - (rotateLastFailed ?? failed)
        let proxiedDelta = proxied - (rotateLastProxied ?? proxied)
        rotateLastFailed = failed
        rotateLastProxied = proxied
        if Date() < rotateCooldownUntil {
            scheduleRotateCheck()
            return
        }
        if failedDelta >= 3 && proxiedDelta == 0 {
            rotateToNextNode()
        }
        scheduleRotateCheck()
    }

    // 按列表顺序切下一个支持协议的节点并重启核心：归属 App
    // 钉死过就改它的 override（轮换后仍钉死在新节点，不回落
    // 全局），跟随全局就改全局活动节点。起不来的节点继续往
    // 下一个切，一圈都起不来就停轮换、写原因，不再无限重启。
    // 启动失败时的就地切节点（ensureRunning 专用）：候选按
    // 新鲜测速从快到慢（与轮换同款排序），跳过刚失败的那条；
    // 成功后按轮换同款改钉死/全局，并接管归属、排轮换检查；
    // 一圈都不通就停，lastError 留最后一次失败原因。
    private func startFallback(from failedLink: String, for appInfo: LCAppInfo?) {
        let links = nodeLinks
        guard links.count >= 2 else { return }
        let cands = Self.sortedSupportedCandidates(links: links, excluding: [failedLink])
        for cand in cands {
            if start(withLink: cand.link) {
                if let appInfo = appInfo, Self.nodeOverride(for: appInfo) != nil {
                    Self.setNodeOverride(cand.link, for: appInfo)
                } else {
                    UserDefaults.standard.set(cand.idx, forKey: Self.activeNodeKey)
                }
                claimCoreOwnershipIfRunning(link: cand.link, for: appInfo)
                return
            }
        }
    }

    private func rotateToNextNode() {
        guard let appInfo = coreOwnerAppInfo else { return }
        let links = nodeLinks
        guard links.count >= 2 else { return }
        var current = effectiveLink(for: appInfo)
        for _ in 0..<links.count {
            guard let target = nextSupportedNode(after: current, links: links) else {
                cancelRotateCheck()
                lastError = "节点自动轮换一圈都不通，已停止轮换，手动换节点或检查订阅"
                return
            }
            rotateTriedLinks.insert(current)
            rotateTriedLinks.insert(target)
            if Self.nodeOverride(for: appInfo) != nil {
                Self.setNodeOverride(target, for: appInfo)
            } else if let idx = links.firstIndex(of: target) {
                UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
            }
            vpnCoreLock.lock()
            coreOwnerBundleId = nil
            vpnCoreLock.unlock()
            if start(withLink: target) {
                vpnCoreLock.lock()
                if let bid = appInfo.bundleIdentifier() {
                    coreOwnerBundleId = bid
                }
                coreOwnerAppInfo = appInfo
                vpnCoreLock.unlock()
                rotateCooldownUntil = Date().addingTimeInterval(60)
                rotateBaselineLink = target
                rotateLastFailed = nil
                rotateLastProxied = nil
                return
            }
            current = target
        }
        cancelRotateCheck()
        lastError = "节点自动轮换一圈都不通，已停止轮换，手动换节点或检查订阅"
    }

    // 测速缓存（与设置页同一份 UserDefaults，格式 link -> {v: code, t: time}；
    // code >= 0 为通的延迟 ms，-1/-2/-3 为不通/超时/不支持；24h 后算旧数不用）。
    private static let pingCacheKey = "CZFVPNPingCache"
    private static let pingCacheStaleAfter: TimeInterval = 86400

    private static func freshPingDelay(for link: String) -> Int? {
        guard let raw = UserDefaults.standard.dictionary(forKey: pingCacheKey),
              let value = raw[link] else { return nil }
        let code: Int
        let time: TimeInterval
        if let dict = value as? [String: Any] {
            code = (dict["v"] as? NSNumber)?.intValue ?? -1
            time = (dict["t"] as? NSNumber)?.doubleValue ?? 0
        } else if let num = value as? NSNumber {
            code = num.intValue
            time = 0
        } else {
            return nil
        }
        guard code >= 0, time != 0,
              Date().timeIntervalSince1970 - time <= pingCacheStaleAfter else { return nil }
        return code
    }

    // 轮换候选：按新鲜测速延迟从快到慢（没测过/旧数排最后，
    // 仍按列表顺序），而不是按列表顺序——轮换后落在最快的
    // 可用节点上，不会从 465ms 的 TUIC 切到 1791ms 的 VLESS。
    // 没测速数据时退化为原来的列表顺序，行为与之前一致。
    // 候选节点排序（轮换与启动 fallback 共用）：按新鲜测速从快
    // 到慢（没测速排最后，仍按列表顺序）；exclude 之外的才进
    // 候选。抽出来是去重——两边之前各写了一份同样的循环。
    private static func sortedSupportedCandidates(links: [String], excluding: Set<String>) -> [(link: String, idx: Int, delay: Int)] {
        var cands: [(link: String, idx: Int, delay: Int)] = []
        for (idx, cand) in links.enumerated() {
            if excluding.contains(cand) { continue }
            if !Self.isSupportedNodeScheme(Self.nodeScheme(for: cand)) { continue }
            cands.append((cand, idx, Self.freshPingDelay(for: cand) ?? Int.max))
        }
        cands.sort { ($0.delay, $0.idx) < ($1.delay, $1.idx) }
        return cands
    }

    private func nextSupportedNode(after current: String, links: [String]) -> String? {
        var excluding = rotateTriedLinks
        excluding.insert(current)
        return Self.sortedSupportedCandidates(links: links, excluding: excluding).first?.link
    }

    // MARK: - 节点延迟测试

    /// 一个节点的延迟测试结果：success 时 delay 是真实毫秒；
    /// 失败时 delay 是核心给的码（10000 出错 / 11000 超时），
    /// 界面别当毫秒显示。conversionFailed 区分两种失败：转换
    /// 器拒收（协议不在清单里）与网络不通——前者界面显示
    /// “不支持”而非“不通”，“清理不通”也不会误删它。
    public struct CZFNodePingResult {
        public let success: Bool
        public let delay: Int
        public let conversionFailed: Bool
        public init(success: Bool, delay: Int, conversionFailed: Bool = false) {
            self.success = success
            self.delay = delay
            self.conversionFailed = conversionFailed
        }
    }

    /// 测延迟前停核心（用户 2026-11-03 定的“停止测速启动”）：
    /// 核心在跑就先记下在跑的链接与归属 App 再停，返回 true；
    /// 核心没在跑就不动，返回 false（测完也不启动）。
    /// 快照与停核心同一把递归锁下做，免得抓到的在跑态
    /// 是另一路 stop/start 做到一半的中间态。stop() 会清
    /// 掉归属，所以快照必须在 stop() 之前抓。
    @discardableResult
    public func stopCoreForPing() -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        guard isRunning, let link = runningLink else {
            pingStoppedLink = nil
            pingStoppedOwner = nil
            return false
        }
        pingStoppedLink = link
        pingStoppedOwner = coreOwnerAppInfo
        // B1（测速暂停不是关核心）：stop() 会把 coreWasRunning 写成
        // false；测速只是暂停，恢复意图按停之前原样保留，否则一次
        // 测速就把 3.8.457 的重启恢复悄悄丢了（重启后核心不再回来）。
        let wasRunningFlag = coreWasRunning
        stop()
        coreWasRunning = wasRunningFlag
        return true
    }

    /// 测延迟完重启原来那条（只在 stopCoreForPing 停过时
    /// 起作用）：归属 App 的有效链接没变才重启（测速中途
    /// 用户亲手换了节点就不抢，免得盖掉用户的新选择）；
    /// 重启走 ensureRunning，归属与轮换巡检原样恢复，起
    /// 不来走 250 的就地切下一个，不停在死节点上。快照
    /// 读完即清，重复调用不会二次启动。养号另有 ensureRunning
    /// 自己的占用守卫兜底（中途别的 App 起了核心就拒绝）。
    public func restartCoreAfterPing() {
        vpnCoreLock.lock()
        let link = pingStoppedLink
        let owner = pingStoppedOwner
        pingStoppedLink = nil
        pingStoppedOwner = nil
        vpnCoreLock.unlock()
        guard let link = link else { return }
        // 测速中途换了目标就不重启旧的：收尾已按用户的新
        // 选择处理过，旧快照作废。
        guard effectiveLink(for: owner).trimmingCharacters(in: .whitespacesAndNewlines) == link.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        ensureRunning(for: owner)
        // 重启成功后清掉测速收尾置的预热抑制：收尾时核心
        // 是停的（抑制置真），现在核心又在跑了，抑制前提
        // 已不存在；重启失败则留着，不让预热去起刚起不来
        // 的核心。归属 App 的重启已由 ensureRunning 清过，
        // 这里只补全局（owner 为 nil）那一路。isRunning 与
        // 清抑制同一把锁下读改，与测速收尾的读法一致。
        vpnCoreLock.lock()
        if isRunning {
            prewarmSuppressedAfterPing = false
        }
        vpnCoreLock.unlock()
    }

    /// 测全部节点的延迟（libXray 的 pingBatch：临时实例并发
    /// 测、每批最多 5 个，经节点真实发一次 HEAD 量往返）。
    /// 测速只读：绝不 stop/start 核心、不改核心启停状态，
    /// 也不在测完事后起回或校验翻盘——测速前核心在跑就
    /// 保持在跑、没在跑就保持没在跑。代价要明说：核心
    /// 在跑时 pingBatch 可能因生命周期锁被拒，整批结果
    /// 会是失败，此时 completion 的 rejected 为真，界面
    /// 要提示“核心在跑、测速被占用”而不是把节点标不通、
    /// 更不能用这批结果去清理节点。onPartial 在第一轮
    /// 测完就回主线程，只含当轮结果，界面只合并其中通
    /// 的节点先显示，不通的继续重试、等最终 completion。
    /// completion 回主线程，结果与 nodeLinks 同序。
    public func pingAllNodes(onPartial: (([CZFNodePingResult]) -> Void)? = nil, onProgress: ((Int, Int, String) -> Void)? = nil, completion: @escaping ([CZFNodePingResult], Bool) -> Void) {
        let links = nodeLinks
        guard !links.isEmpty else { completion([], false); return }
        // 先在调用线程把测速标志立起来再派后台队列：原来标
        // 志只在后台块里立，调用与后台执行之间的窗口里预
        // 热可能抢跑起核心，测速中就先变在跑；立标志本身
        // 不抓状态，状态快照仍在后台块里同一把锁下抓。
        vpnCoreLock.lock()
        isPinging = true
        vpnCoreLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            // 抓状态必须和 start/stop 同一把锁：否则抓到的
            // 核心在跑/活动链接可能是另一路 stop/start
            // 做到一半的中间态，收尾判断就按错状态走。
            // 抓完立刻放锁——锁不包整段测速（见字段注释）。
            self.vpnCoreLock.lock()
            self.isPinging = true
            self.pingRetryLink = nil
            self.pingGeneration += 1
            let epochAtPingStart = self.coreActionEpoch
            let coreRunningAtStart = self.isRunning
            let prePingActiveLink = self.nodeLink
            self.vpnCoreLock.unlock()
            var conversionCache: [String: String] = [:]
            var outcome = self.runPingBatches(links: links, url: "https://cp.cloudflare.com/", phase: "测速", onProgress: onProgress, conversionCache: &conversionCache)
            // 核心在跑且整批被拒 = 核心占用测速，不是节点不通：
            // 测速只读，不停车重测、不重试（重试同样会被拒，
            // 只会白白拖时间），直接把被拒结果交给界面提示。
            let pingRejected = coreRunningAtStart && outcome.batchRejected
            // 轮末复核（TUIC 探针竞态）：测速中途刚起的核心
            // 也会让探针记被拒，completion 用起止任一时刻在跑
            // 且被拒才算占用，见末尾 finalRejected；重试门只
            // 看起时状态（重试失败不覆写成功项，无害）。
            if let onPartial {
                let firstItems = outcome.items
                DispatchQueue.main.async { onPartial(firstItems) }
            }
            if !pingRejected {
                // 假不通修法：第一地址（Cloudflare）个别失败时，
                // 按顺序用另外两个地址单独重测，只认重测通的——
                // 有些 REALITY 节点对 Cloudflare 那一路不通，但
                // 实际经节点上网是通的（小火箭同节点 183ms），
                // 一次失败就永久标不通、逼用户换 IP 是错的。
                // 只用一个重试地址还不够：测速库对 204 空回应
                // 的判定未必算成功，所以第二重试用返回 200 的
                // 苹果连通性检测页兜底；三个地址都失败才标不通。
                var failedIndices = outcome.items.enumerated().filter { !$0.element.success }.map { $0.offset }
                for retryURL in ["https://www.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"] {
                    if failedIndices.isEmpty { break }
                    let failedLinks = failedIndices.map { links[$0] }
                    let retry = self.runPingBatches(links: failedLinks, url: retryURL, phase: "重试", onProgress: onProgress, conversionCache: &conversionCache)
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
            // 测速收尾（只读版）：测速本身绝不动核心启停，
            // 没有恢复、没有事后重试、没有校验翻盘。收尾只做
            // 三件与核心启停无关的事：
            // 1) 没用户动作时，把测速结束时的核心状态记成
            //    预热抑制（在跑就清、没在跑就置），这样测速
            //    后切回前台，预热不会把停着的核心悄悄起回来；
            //    有用户动作时不碰抑制，亲手起停/开 App 的路
            //    径自己会清或保留；
            // 2) 测速窗口内被挡下的开 App / 源下载请求、以及
            //    用户换过的活动节点，在测速结束后补跑一次——
            //    这些是用户/App 自己的动作，不是测速在动核心；
            // 3) 把结果和被拒标志交给 completion，界面据此
            //    决定要不要提示“核心占用”以及要不要禁清理。
            var deferredApp: LCAppInfo?
            var deferredHost = false
            var postPingActiveLink = prePingActiveLink
            self.vpnCoreLock.lock()
            let epochChanged = self.coreActionEpoch != epochAtPingStart
            if !epochChanged {
                self.prewarmSuppressedAfterPing = !self.isRunning
            } else {
                self.pingRetryLink = nil
            }
            postPingActiveLink = self.nodeLink
            deferredApp = self.deferredEnsureApp
            self.deferredEnsureApp = nil
            deferredHost = self.deferredHostEnsure
            self.deferredHostEnsure = false
            self.isPinging = false
            self.vpnCoreLock.unlock()
            if let deferredApp {
                self.ensureRunning(for: deferredApp)
            } else if postPingActiveLink != prePingActiveLink {
                self.applyActiveNodeChange()
            }
            if deferredHost {
                self.ensureRunningForHost()
            }
            self.vpnCoreLock.lock()
            let coreRunningAtEnd = self.isRunning
            self.vpnCoreLock.unlock()
            let finalRejected = (coreRunningAtStart || coreRunningAtEnd) && outcome.batchRejected
            let items = outcome.items
            DispatchQueue.main.async { completion(items, finalRejected) }
        }
    }

    /// 只测一个节点：复用 runPingBatches 的单链接子集与三地址
    /// 重试（Cloudflare → gstatic → Apple），不测整表。测速只读
    /// 规则与全量测速一致：立 isPinging 挡预热/切节点/开 App，
    /// 收尾只做预热抑制与被挡请求的补跑，绝不动核心启停；
    /// 核心在跑且整批被拒时 rejected 为真，界面不覆写旧结果。
    /// completion 回主线程，result 为 nil 表示下标已失效。
    public func pingSingleNode(at index: Int, completion: @escaping (CZFNodePingResult?, Bool) -> Void) {
        let links = nodeLinks
        guard links.indices.contains(index) else { completion(nil, false); return }
        let link = links[index]
        vpnCoreLock.lock()
        isPinging = true
        vpnCoreLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.vpnCoreLock.lock()
            self.isPinging = true
            self.pingRetryLink = nil
            self.pingGeneration += 1
            let epochAtPingStart = self.coreActionEpoch
            let coreRunningAtStart = self.isRunning
            let prePingActiveLink = self.nodeLink
            self.vpnCoreLock.unlock()
            var conversionCache: [String: String] = [:]
            var outcome = self.runPingBatches(links: [link], url: "https://cp.cloudflare.com/", phase: "测速", onProgress: nil, conversionCache: &conversionCache)
            let pingRejected = coreRunningAtStart && outcome.batchRejected
            if !pingRejected {
                var failed = outcome.items.first?.success == true ? [] : [0]
                for retryURL in ["https://www.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"] {
                    if failed.isEmpty { break }
                    let retry = self.runPingBatches(links: [link], url: retryURL, phase: "重试", onProgress: nil, conversionCache: &conversionCache)
                    if retry.items.first?.success == true {
                        outcome.items[0] = retry.items[0]
                        failed = []
                    }
                }
            }
            var deferredApp: LCAppInfo?
            var deferredHost = false
            var postPingActiveLink = prePingActiveLink
            self.vpnCoreLock.lock()
            let epochChanged = self.coreActionEpoch != epochAtPingStart
            if !epochChanged {
                self.prewarmSuppressedAfterPing = !self.isRunning
            } else {
                self.pingRetryLink = nil
            }
            postPingActiveLink = self.nodeLink
            deferredApp = self.deferredEnsureApp
            self.deferredEnsureApp = nil
            deferredHost = self.deferredHostEnsure
            self.deferredHostEnsure = false
            self.isPinging = false
            self.vpnCoreLock.unlock()
            if let deferredApp {
                self.ensureRunning(for: deferredApp)
            } else if postPingActiveLink != prePingActiveLink {
                self.applyActiveNodeChange()
            }
            if deferredHost {
                self.ensureRunningForHost()
            }
            self.vpnCoreLock.lock()
            let coreRunningAtEnd = self.isRunning
            self.vpnCoreLock.unlock()
            // 轮末复核：与 pingAllNodes 同理，中途起的核心也算占用。
            let finalRejected = (coreRunningAtStart || coreRunningAtEnd) && outcome.batchRejected
            let item = outcome.items.first
            DispatchQueue.main.async { completion(item, finalRejected) }
        }
    }

    /// 逐批调 pingBatch（同步阻塞，必须在后台线程调）
    /// conversionCache：同一轮测速内复用链接转换结果。
    /// pingAllNodes/pingSingleNode 要对不通节点走三轮地址
    /// （Cloudflare → gstatic → Apple），原来每轮都对每个
    /// 链接重新调一次 convertShareLinksToXrayJson；转换结果
    /// 只取决于链接本身，与测速地址无关，所以一轮内缓存
    /// 一次即可，缓存只活在当次测速调用内，不跨轮复用。
    private func runPingBatches(links: [String], url: String, phase: String = "", onProgress: ((Int, Int, String) -> Void)? = nil, conversionCache: inout [String: String]) -> (items: [CZFNodePingResult], batchRejected: Bool) {
        var items = [CZFNodePingResult?](repeating: nil, count: links.count)
        var batchRejected = false
        // TUIC-only 测速分流（测速只读，不动主核心）：
        // - tuic 节点：先只做配置解析校验（不启动服务），
        //   解析失败记 conversionFailed（界面“不支持”，清理
        //   不删）；解析成功走单实例多出站并行探针（端口
        //   10927 起，一个实例带全部 TUIC 出站，探针并行）。
        // - 双运行时硬规则：主核心在跑（任何一种）时，临时实
        //   例不起；主核心是 sing-box 时，连 Xray pingBatch
        //   也不调（整轮 rejected，复用“核心占用保留旧结果”
        //   语义）。主核心是 Xray 时 pingBatch 照常（现有行
        //   为：被生命周期锁拒则 batchRejected）。
        // - 探针目标 host 取本轮测速 URL 的 host（Cloudflare /
        //   gstatic / Apple 三轮各不相同），端口 80 明文 HTTP；
        //   成功节点只探一次（重试只传失败下标），失败节点随
        //   重试轮次重探（最坏 3×5 秒，文档化代价）。
        // 占用判定在函数入口抓一次（不包整段测速，见字段注释）。
        vpnCoreLock.lock()
        let mainRunning = isRunning
        let mainCore = runningCore
        vpnCoreLock.unlock()
        let singBoxMainRunning = mainRunning && mainCore == .singBox
        // 先把每个链接转成出站 JSON，转不动的直接记失败
        var pending: [(index: Int, xrayJson: String)] = []
        var singBoxPending: [(index: Int, link: String)] = []
        for (i, link) in links.enumerated() {
            // sing-box 节点（tuic / hysteria2）：只做配置解析校验，不启动服务。
            if CZFSingBoxRouting.coreKind(for: link) == .singBox {
                if (try? CZFSingBoxConfig.configJSON(for: link, socksPort: 10927, httpPort: nil)) != nil {
                    singBoxPending.append((i, link))
                } else {
                    items[i] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
                }
                continue
            }
            let normalized = Self.normalizedShareLink(link)
            if let cached = conversionCache[normalized] {
                pending.append((i, cached))
                continue
            }
            let conv = invoke(method: "convertShareLinksToXrayJson", payload: ["text": normalized])
            if let conv, conv["success"] as? Bool == true,
               let data = conv["data"] as? [String: Any],
               let outbounds = data["outbounds"] as? [[String: Any]], !outbounds.isEmpty,
               let jsonData = try? JSONSerialization.data(withJSONObject: ["outbounds": outbounds]),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                conversionCache[normalized] = jsonStr
                pending.append((i, jsonStr))
            } else {
                // 转换失败单记：不是网络不通，是协议不在转换器
                // 清单里——界面据此显示“不支持”，清理不删。
                items[i] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
            }
        }
        if singBoxMainRunning {
            // sing-box 主核心在跑：Xray pingBatch 不与它同进程
            // 跑，整批记被拒（调用方按“核心占用”保留旧结果）。
            if !pending.isEmpty { batchRejected = true }
            for entry in pending {
                items[entry.index] = CZFNodePingResult(success: false, delay: 10000)
            }
        } else {
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
                if let onProgress {
                    let done = items.compactMap { $0 }.count
                    let total = links.count
                    DispatchQueue.main.async { onProgress(done, total, phase) }
                }
                start += 5
            }
        }
        // sing-box 临时探针（单实例多出站并行；主核心在跑时跳过，记被拒）。
        if !singBoxPending.isEmpty {
            if mainRunning {
                batchRejected = true
                for entry in singBoxPending {
                    items[entry.index] = CZFNodePingResult(success: false, delay: 10000)
                }
            } else {
                let probeHost = URLComponents(string: url)?.host ?? ""
                if let results = probeSingBoxNodes(links: singBoxPending.map { $0.link }, host: probeHost) {
                    for (j, entry) in singBoxPending.enumerated() {
                        items[entry.index] = results[j]
                    }
                } else {
                    // 起探针时主核心刚跑起来：记被拒，调用方
                    // 按“核心占用”保留旧结果（pingAllNodes /
                    // pingSingleNode 的 pingRejected 含轮末复核）。
                    batchRejected = true
                    for entry in singBoxPending {
                        items[entry.index] = CZFNodePingResult(success: false, delay: 10000)
                    }
                }
                if let onProgress {
                    let done = items.compactMap { $0 }.count
                    let total = links.count
                    DispatchQueue.main.async { onProgress(done, total, phase) }
                }
            }
        }
        return (items.map { $0 ?? CZFNodePingResult(success: false, delay: 10000) }, batchRejected)
    }

    /// sing-box 多节点临时探针（单实例多出站并行，3.8.306）：
    /// 一个临时实例带 N 个 TUIC 出站 + N 个 mixed 入站（端口
    /// 10927 起），N 个探针并行跑，总耗时 ≈ 最慢的一个（原来
    /// 每节点起一个实例串行测，N 个节点要 N 倍时间）。
    /// 只在无主核心时调用；起实例前再复核一次占用，占用竞态
    /// 时返回 nil，由调用方记被拒。延迟码与单节点版同款：
    /// 被拒记 10000（界面“不通”，清理可删），超时或失败记
    /// 11000（界面“超时”，实际含义是超时或失败，不是已证实
    /// 的超时——v1 已知局限，见汇报）。
    private func probeSingBoxNodes(links: [String], host: String) -> [CZFNodePingResult]? {
        vpnCoreLock.lock()
        // 主核心在跑，或上个临时实例泄漏未停（崩溃才可能），
        // 都算占用：不与任何已跑实例同进程起第二个。
        let occupied = isRunning || CZFSingBoxCore.isServiceRunning
        vpnCoreLock.unlock()
        if occupied { return nil }
        let config: String
        do {
            config = try CZFSingBoxConfig.configJSON(for: links, basePort: 10927)
        } catch {
            return links.map { _ in CZFNodePingResult(success: false, delay: 10000, conversionFailed: true) }
        }
        // 拿着锁起临时实例：起完（flag 已置 true）再放锁，
        // 主核心的 start 拿不到锁就进不来，不可能插进
        // “检查完还没起”的窗口。只锁起实例这一下，不锁
        // 整个探针（探针要几秒，锁全程会冻住起核心）。
        vpnCoreLock.lock()
        if isRunning || CZFSingBoxCore.isServiceRunning {
            vpnCoreLock.unlock()
            return nil
        }
        do {
            try CZFSingBoxCore.start(configJSON: config)
        } catch {
            vpnCoreLock.unlock()
            return links.map { _ in CZFNodePingResult(success: false, delay: 11000) }
        }
        vpnCoreLock.unlock()
        defer { try? CZFSingBoxCore.stop() }
        // 并行探针：每个端口一个后台任务，DispatchGroup 等全部
        // 完成。probe 是阻塞式（内部信号量），各任务跑在自己的
        // 全局队列线程上，互不干扰；结果按下标写回（各下标只写
        // 一次，NSLock 护写回，group.wait 后再读）。
        var results = [CZFNodePingResult?](repeating: nil, count: links.count)
        let writeLock = NSLock()
        let group = DispatchGroup()
        for i in links.indices {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let probe = CZFSingBoxProbe.probe(port: 10927 + i, host: host, timeout: 5)
                let result: CZFNodePingResult
                if probe.success {
                    result = CZFNodePingResult(success: true, delay: probe.delayMs)
                } else if probe.rejected {
                    result = CZFNodePingResult(success: false, delay: 10000)
                } else {
                    result = CZFNodePingResult(success: false, delay: 11000)
                }
                writeLock.lock()
                results[i] = result
                writeLock.unlock()
                group.leave()
            }
        }
        group.wait()
        return results.map { $0 ?? CZFNodePingResult(success: false, delay: 11000) }
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
        // 速窗口内起核心让 pingBatch 被拒、测速结果不准。
        vpnCoreLock.lock()
        let pinging = isPinging
        if pinging {
            deferredHostEnsure = true
            coreActionEpoch += 1
        }
        vpnCoreLock.unlock()
        if pinging { return }
        // 源下载开关是手动动作：和开 App 一样清掉测速后的
        // 预热抑制；测速窗口内被挡下的请求走收尾补跑，补
        // 跑时 pinging 已是 false，同样在这里清掉。
        vpnCoreLock.lock()
        prewarmSuppressedAfterPing = false
        vpnCoreLock.unlock()
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
        return "插件统计（加载 \(load) · 自检 \(dict["selftest"] ?? "?")）：解析共 \(dict["gaiPass"] ?? "0") 次（假IP \(dict["gaiFake"] ?? "0")）· 代理连接 \(dict["proxied"] ?? "0") · 失败 \(dict["failed"] ?? "0") · 直连 \(dict["direct"] ?? "0") · 放行 \(dict["pass"] ?? "0") · connectx \(dict["connectx"] ?? "0")（代理 \(dict["connectxProxied"] ?? "0")）· 会话改写 \(dict["swizzled"] ?? "0") · 配置改写 \(dict["cfg"] ?? "0") · 拦QUIC \(dict["quic"] ?? "0") · QUIC代理 \(dict["quicProxied"] ?? "0")"
    }

    // MARK: - 核心日志（O-7：日志落盘 + VPN 页查看）

    /// sing-box 日志文件（configJSON 里 log.output 的同一路径，
    /// 定义在 CZFSingBoxConfig.singBoxLogPath，这里只转 URL）。
    public static var singBoxLogURL: URL {
        URL(fileURLWithPath: CZFSingBoxConfig.singBoxLogPath)
    }

    /// Xray 日志目录（Documents/xray；start 前建出来，见
    /// start(withLink:) 里的 createDirectory）。
    public static var xrayLogDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xray", isDirectory: true)
    }
    public static var xrayAccessLogURL: URL { xrayLogDirectory.appendingPathComponent("access.log") }
    public static var xrayErrorLogURL: URL { xrayLogDirectory.appendingPathComponent("error.log") }

    /// 读核心日志尾部（VPN 页“查看核心日志”只读展示用）：
    /// sing-box 日志 + Xray error 日志各取尾部 maxLinesPerFile
    /// 行（默认 60 行/文件），逐行按探针同款规则脱敏（见
    /// sanitizeCoreLogLine）。Xray access 日志不展示——每行
    /// 都是连接记录、几乎全是目标地址，脱敏后剩不下可读内容，
    /// 文件仍落盘，供 Files 里查。文件不存在（核心还没跑过）
    /// 时该段写“（无日志文件）”。只读文件尾部 64KB，不整
    /// 文件读进内存；日志文件无轮转/上限（O-7 不做，见汇报）。
    public static func coreLogTail(maxLinesPerFile: Int = 60) -> String {
        let sections: [(title: String, url: URL)] = [
            ("sing-box", singBoxLogURL),
            ("Xray error", xrayErrorLogURL),
        ]
        var out: [String] = []
        for (title, url) in sections {
            out.append("—— \(title) ——")
            guard let text = tailOfFile(url, maxBytes: 64 * 1024) else {
                out.append("（无日志文件）")
                continue
            }
            let tail = Array(text.components(separatedBy: .newlines).suffix(maxLinesPerFile))
            if tail.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                out.append("（日志为空）")
            } else {
                out.append(contentsOf: tail.map { sanitizeCoreLogLine($0) })
            }
        }
        return out.joined(separator: "\n")
    }

    /// 只读文件尾部 maxBytes 字节并解成字符串；文件不存在/
    /// 为空/读不出返回 nil。截断点若切在行中间，丢掉首个
    /// 不完整行。UTF-8 用 lossy 解码，截断处的半个字符不报错。
    private static func tailOfFile(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let firstNL = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNL)...])
        }
        return text
    }

    /// 核心日志单行脱敏（探针同款规则：错误字符串只含阶段名，
    /// 不含链接、密码、密钥、token——见 CZFSingBoxProbe 头注释）：
    /// - URL 里的 userinfo（密码）整段抹掉：`://xxx@` → `://***@`
    /// - URL query 串整段抹掉（obfs-password 常在 query 里）
    /// - 凭证类 key=value 的值抹掉（password / obfs-password /
    ///   token / secret / uuid / key 等）
    /// - Authorization 头的值抹掉
    /// - IPv4 地址（含端口）抹掉
    /// 局限：域名形式的目标地址（如 dial 报错里的 example.com:443）
    /// 没抹——正则分不清节点域名与普通域名/版本号，全抹会把日志
    /// 砍得没法读；日志只在本机查看、不上传、不进错误上报。
    public static func sanitizeCoreLogLine(_ line: String) -> String {
        var s = line
        s = s.replacingOccurrences(of: "://[^/\\s@]+@", with: "://***@", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\?[^\\s]*", with: "?***", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\b(password|passwd|pwd|obfs[-_]?password|secret|token|api[-_]?key|private[-_]?key|uuid|key)\\s*[:=]\\s*[^\\s,;\"']+", with: "$1=***", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)(authorization:\\s*)\\S+", with: "$1***", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}(?::\\d+)?\\b", with: "***", options: .regularExpression)
        return s
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
