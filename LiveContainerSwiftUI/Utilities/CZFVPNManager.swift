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
    /// 用户亲手停核心的代次（3.8.900（L569-1））：只有“停核心”这个
    /// 决定才 +1——三处核心开关的 noteManualCoreToggle(started: false)、
    /// 删在用节点（removeNode 的 wasActive 支）、到点自动停
    /// （checkPendingStop）。轮换/就地切的重试循环在每次重试前比对它，
    /// 中途有人亲手停了核心就收手，不把刚停的核心又起回来。轮换自己
    /// 的起核中间态 stop()（start(withLink:) 里先停后起）与测速的
    /// stopCoreForPing 不碰它（那两路不是“停核心”的决定；轮换本来
    /// 也不在测速窗口内跑）。只在 vpnCoreLock 下读写。
    private var czfManualCoreStopEpoch = 0
    /// 轮换进行中（3.8.900（L567-1））：轮换改异步后，一轮（尤其
    /// 节点多、全圈试下来）可能超过 30 秒巡检间隔，定时器到点会
    /// 再起一轮——原来主线程同步跑不可能重叠。只在主线程上读写
    /// （与 rotateTriedLinks 同款约束），轮换 Task 起时置真、
    /// 跑完置假；在途时新一轮不叠加，只重排下一轮检查。
    private var czfRotateRunning = false
    /// 无归属/无统计时探针连续失败次数（3.8.582（VPN-5））：只在主队
    /// 列上读写——handleRotateProbeResult 跑在 MainActor.run 里，
    /// rotateCheck 的 work item 也在主队列，与 rotateTriedLinks
    /// 同款约束。探通清零；连续两次失败才轮换。
    private var rotateProbeFailures = 0
    /// 探针连续失败所属的节点链接（3.8.900（L563-1））：计数是“同一节点连续
    /// 失败”的次数，节点一切换就重开一轮——原来只记次数不记归属，旧节点攒了
    /// 1 次失败后手动切节点/统计路轮换，新节点再抖一次就满两次被轮换。
    private var rotateProbeLink: String?
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
        // L143-1：配置变了就刷设置备份（见 refreshSettingsBackup）。
        shared.refreshSettingsBackup()
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
    /// UI 发起的起/停核心串行队列（3.8.900（L577-1））：点节点行/核心开关/宿主代理开关都在主线程，起核心是同步阻塞的 CGoInvoke（转换 + 起核，几秒，见 L567-1），主线程直调会把界面冻住；放这条串行队列跑，点按顺序不变（先点的先起停），做完由调用方回主线程刷新。只接 UI 发起的起停：轮换/就地切/预热/恢复早已在 detached/后台跑，不动它们。
    static let czfCoreStartQueue = DispatchQueue(label: "CZFVPNManager.coreStart", qos: .userInitiated)
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
    // 测速窗口内被挡下的开 App 请求：全记下来，测速完按启
    // 动顺序挨个补跑 ensureRunning。只记最后一个会丢掉先启
    // 动的那个——它 fail-open 起了、之后一直跑在后启动那个
    // App 的节点上，钉死节点的养号 App 会悄悄换 IP（游客启
    // 动时等核心，见 LCAppModel 的 vpnCoreTask；挡下不等于丢掉）。
    private var deferredEnsureApps: [LCAppInfo] = []
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
    // 测速代次：每轮 ping 开始时 +1；收尾只认最新一轮——
    // App 页与 VPN 页各有自己的测速标志，manager 的
    // isPinging 不拦第二轮，先完的那轮不能清标志、不能
    // 补跑被挡请求（见 pingAllNodes/pingSingleNode 尾部）。
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
    // 与 deferredEnsureApps 同理，测速收尾再补跑一次。
    private var deferredHostEnsure = false
    // 测速窗口内亲手换了节点：setActiveNode 在 isPinging 时、或
    // 快照还在等 restart 时（收尾已把 isPinging 置 false、restart
    // 还没跑，中间还隔着补跑的阻塞式起核心）记一笔，测速收尾/
    // restart 取走再跟随——applyActiveNodeChange 只在核心在跑时
    // 才切，测速开始时核心通常已被 stopCoreForPing 停掉，直接调
    // 它跟随就落空。只认显式切换（且有效节点真变了）：删节点/
    // 导入恢复改了链接时不记，removeNode“删在用节点就停核心”
    // 的原语义不动。收尾链接没变时不清除，留给 restart 消费。
    private var czfNodeSwitchDuringPing = false
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
        // 3.8.565（L293-1）：原来 return links[activeNodeIndex]——
        // activeNodeIndex 内部又读一次 nodeLinks 再夹下标；列表在
        // 两次读之间变长（加节点/订阅刷新整体替换写 UserDefaults）
        // 时，夹好的下标可能越过第一次快照的尾，下标越界直接崩。
        // 读一次快照、同快照内夹下标；列表稳定时结果与原来一字
        // 不差。后台读点：测速块（:2011/:2082/:2162/:2193）与
        // Task.detached 调来的 ensureRunning（M:1148）都会读它，
        // 写点全在主线程，两读之间没有锁。
        let idx = UserDefaults.standard.integer(forKey: Self.activeNodeKey)
        return links[min(max(idx, 0), links.count - 1)]
    }

    // 节点变了就刷新设置备份：导入导出配置（CZFSettingsBackup.json）
    // 本来只在手动导出 / 备份 App 时写，节点增删改后不刷就过期，
    // 换机重装导入的还是旧节点；这里顺手刷一份，配置永远是最新节点。
    // 只调 DataManagement 现成的静态写函数，不改那份文件。
    // 3.8.537（L143-1）：只接节点列表变更不够——别名/开关/钉死/
    // 跟随/自动轮换/宿主代理五处调用点、六个键也是 CZF 键、也在备份 payload 里，
    // 改完不刷，恢复用的备份里还是旧值（钉死节点丢了=悄悄换 IP，
    // L91 同款伤害）；运行时状态（预热抑制/核心在跑/故障转移改
    // 活动下标/测速缓存）不接。写盘本身已防抖（0.5 秒后才写），
    // 故障转移连调几次也只落一笔，不阻塞调用方。
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
        // 3.8.582（VPN-1）：清理换表，旧链接不在新表里的 override
        // 一并清掉（见下面 helpers 注释）。
        Self.clearStaleNodeOverrides(keeping: cleaned)
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
        // 3.8.582（VPN-1）：订阅刷新整体换表，旧链接不在新表里
        // 的 override 一并清掉（见下面 helpers 注释）。
        Self.clearStaleNodeOverrides(keeping: cleaned)
        // 3.8.900（L572-2）：被动换表不抢钉死核心（见 czfFollowListChange）。
        czfFollowListChange()
        refreshSettingsBackup()
    }

    /// 订阅返回的一行是不是节点链接（3.8.900（L573-1））：行首到 "://" 之前
    /// 必须是纯 scheme token（字母开头，只含字母/数字/+/-/.），且不是 http/https；
    /// 以 "{" 开头的原始 JSON 出站原样保留（订阅本来就按含 :// 的行收）。
    /// 过期订阅回 200 + HTML 错误页时，页里的 <script src="https://…">、
    /// <a href="https://…">、<link href="https://…"> 行都含 ://，旧过滤
    /// （只判含 ://）直接当节点返回、整体替换会把好节点全换成垃圾行、行行
    /// “不支持”；sub:// 分支早已拦 http 行，主路漏了同款（下面注释自认
    /// HTML 错误页能过三关、只验了状态码）。
    private static func czfIsNodeLinkLine(_ line: String) -> Bool {
        guard line.contains("://") else { return false }
        if line.hasPrefix("{") { return true }
        guard let range = line.range(of: "://") else { return false }
        let scheme = String(line[..<range.lowerBound]).lowercased()
        guard scheme != "http", scheme != "https",
              let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
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
                    .filter { Self.czfIsNodeLinkLine($0) }
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
        // 3.8.547（L181）：订阅会变，绕开 URLCache（同 freshData 的理
        // 由；这里本来就是 URLRequest，直接置 cachePolicy）。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        // 不少机场按客户端 UA 返回不同格式，给个常见客户端的
        // UA 拿到原始分享链接列表
        request.setValue("Shadowrocket/2.2.50", forHTTPHeaderField: "User-Agent")
        // 3.8.547（L183）：订阅走 hostSession——代理开且核心在跑时经节点
        // 取（URLSession.shared 绕开代理；机场订阅域名在直连下常被墙，
        // 核心明明在跑、订阅却拉不下来，图标同款已在 load 里修过）；
        // 代理关时 hostSession() 本来就回 .shared，行为不变。
        Self.hostSession().dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            // 过期订阅返回的 HTML 错误页也能过下面三关（无传输错、
            // 是 UTF-8、含 "://"），先验 HTTP 状态，非 200 直接失败。
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(NSError(domain: "CZFVPN", code: -4, userInfo: [NSLocalizedDescriptionKey: "订阅拉取失败，服务器返回 \(code)"])))
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
            // 3.8.576（L107）：整段 base64 常常不带尾部 `=`（URL 安全变体
            // 尤其如此，上面刚换过 `-`/`_`）；`Data(base64Encoded:)` 要
            // 求长度是 4 的倍数，没补 `=` 就解不出来、订阅报“里没找到
            // 节点链接”。与 sub:// 分支（:291）与 vmessDisplay 同款，
            // 先补齐再解；`count % 4 == 1` 的串补了也解不出，自然落
            // 到下面的明文行过滤，不误伤。
            let padded = compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
            if !compact.isEmpty,
               let decoded = Data(base64Encoded: padded),
               let decodedText = String(data: decoded, encoding: .utf8),
               decodedText.contains("://") {
                text = decodedText
            }
            let links = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { Self.czfIsNodeLinkLine($0) }
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
        // 3.8.582（VPN-1）：只换顺序、链接一个不少，扫一遍正常是
        // 空操作；但之前版本删节点留下的过期 override 在这里一并
        // 清掉（见下面 helpers 注释）。
        Self.clearStaleNodeOverrides(keeping: newLinks)
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
        // 3.8.582（VPN-1）：删掉的节点若还有 App 钉死在上面，清掉
        // override 回落全局——不然钉死的 App 永远拿已删的死链接连，
        // 菜单里还看不见它（链接因重复行仍在列表里时 helper 不动）。
        // 3.8.900（L572-2）：清掉必须在跟随之前——跟随的放行条件是
        // “核心跑的链接还钉不钉死”，刚删的钉死链接要先清掉才读到不
        // 钉死、照常跟回全局；不清就误判还在钉死、核心一直跑死链接。
        Self.clearStaleNodeOverrides(keeping: links)
        if wasActive {
            // 3.8.594（L127）：删在用节点就是亲手停核心——
            // stop() 只停核心，不清测速的待重启快照；测速窗口
            // 内删在用节点时，收尾跟随会把快照改写成新活动链
            // 接、restart 又把核心起回来，“删在用节点就停核心”
            // 就落空了。快照一并清掉，restart 不再起；非测速
            // 窗口内快照本来就是 nil，清掉是空操作。
            vpnCoreLock.lock()
            pingStoppedLink = nil
            pingStoppedOwner = nil
            // 3.8.900（L569-1）：删在用节点也是亲手停核心，记一代次——
            // 轮换/就地切正在重试时见代次变了就收手（同 noteManualCoreToggle）。
            czfManualCoreStopEpoch += 1
            vpnCoreLock.unlock()
            stop()
        } else {
            // 3.8.900（L572-2）：被动删节点不抢钉死核心（见 czfFollowListChange）。
            czfFollowListChange()
        }
        refreshSettingsBackup()
    }

    public func setActiveNode(at index: Int) {
        guard nodeLinks.indices.contains(index) else { return }
        let oldIndex = activeNodeIndex
        // 3.8.900（L572-1）：点已在用的节点行不是切换——原来不判就直
        // 接 applyActiveNodeChange，核心正跑在钉死节点的 App 的节点
        // 上时 runningLink（钉死）!= nodeLink（全局在用），start() 会
        // 把核心重启到全局节点、清掉归属，养号 App 当场悄悄换 IP；
        // 点一下已在用的行本该什么都不做。其它调用方（切最快/测速收
        // 尾）本来就先判 != 才调，这里一次拦住行点/菜单点/盾牌切最快
        // 三路；下标没变时下面那笔 ping 窗口标志本来也不记、备份也
        // 不用刷，提前返回行为一字不动。
        guard index != oldIndex else { return }
        UserDefaults.standard.set(index, forKey: Self.activeNodeKey)
        // 3.8.592（L125）：测速窗口内点的切换记一笔，收尾跟随用
        //（见 czfFollowPostPingNodeSwitch / restartCoreAfterPing）；
        // 窗外切换走下面 applyActiveNodeChange 立刻切，标志不记。
        // 只在有效节点真变了时记（点已在用的节点不记）；快照还在
        // 等 restart 时也记——收尾已把 isPinging 置 false、restart
        // 还没跑，中间还隔着补跑的阻塞式起核心。
        vpnCoreLock.lock()
        if index != oldIndex && (isPinging || pingStoppedLink != nil) { czfNodeSwitchDuringPing = true }
        vpnCoreLock.unlock()
        applyActiveNodeChange()
        refreshSettingsBackup()
    }

    // 3.8.900（L572-2）：某条链接是否仍被任一 App 钉死（override 值
    // 等于它）——列表被动变动后跟随全局的放行条件（见 czfFollowListChange）。
    // 直接扫 UserDefaults 的 override 键，与 nodeOverride(for:) 读同一
    // 份值；只在订阅刷新/删节点/测速收尾这类用户动作里调，不在热路上。
    private static func czfIsPinnedLiveLink(_ link: String?) -> Bool {
        guard let link, !link.isEmpty else { return false }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(nodeOverrideKeyPrefix) {
            if defaults.string(forKey: key) == link { return true }
        }
        return false
    }

    /// 列表被动变动后的跟随（订阅刷新 / 删节点 / 测速收尾的列表变动路，
    /// 3.8.900（L572-2）：核心正跑在仍被任一 App 钉死的节点上时别跟
    /// 全局走——订阅刷新/删不相干节点只动了列表，全局在用节点根本没变，
    /// 原来无条件 applyActiveNodeChange，runningLink（钉死）!= nodeLink
    /// （全局）就把核心重启到全局节点、清掉归属，养号 App 当场悄悄换
    /// IP；钉死链接已不在列表里时 override 已被清掉（VPN-1），这里读
    /// 到不钉死、照常跟全局，不留死节点。核心跑在全局节点上时
    /// applyActiveNodeChange 本来就是空操作，行为一字不动。显式切换
    /// （setActiveNode 点了别的节点、测速收尾的显式切换分支）不走这里，
    // 手动切节点强制切换的原语义不动。
    private func czfFollowListChange() {
        // 判定与跟随在同一把锁下（L567-2 同款纪律）：锁外判、锁内
        // 动之间核心可能刚被别的 App 抢走，判完就错了。
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        if Self.czfIsPinnedLiveLink(runningLink) { return }
        applyActiveNodeChange()
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
        // 3.8.900（L577-1）：主线程调进来时（点节点行/切最快/订阅导入跟随/删节点跟随），起/停核心是同步阻塞的 CGoInvoke（转换 + 起核，几秒，见 L567-1），主线程直调会把界面冻住；放串行队列跑（点按顺序不变），执行时再现读状态（见下）。后台调进来时（测速收尾跟随/恢复）同步跑，一字不动。
        if Thread.isMainThread {
            Self.czfCoreStartQueue.async { self.czfApplyActiveNodeChangeNow() }
            return
        }
        czfApplyActiveNodeChangeNow()
    }

    /// applyActiveNodeChange 的真正起停步（见上）：执行时现读在跑态与活动链接——排队这会儿核心可能已被停（验不过就不起，不把刚停的核心又起回来）、活动链接可能已被改（按最新链接起，不起旧选择）。
    private func czfApplyActiveNodeChangeNow() {
        guard isRunning else { return }
        if nodeLink.isEmpty {
            stop()
        } else if runningLink != nodeLink {
            _ = start()
        }
    }

    // 测速收尾跟随用户在窗口内亲手换的节点（两条测速收尾调）：
    // 原来只调 applyActiveNodeChange，它只在核心在跑时才切；
    // 测速开始时核心通常已被 stopCoreForPing 停掉，跟随落空，
    // 之后 completion 里的 restartCoreAfterPing 又会把核心起回
    // 旧节点（钉死归属时）或干脆不起（跟随全局时守卫拦掉），
    // 用户的切换被悄悄丢掉：界面显示新节点，核心却跑旧节点
    // 或停着。核心停着且有待重启快照时，把快照改写成新链接、
    // 无归属，让 restart 按新链接起（与窗外亲手切节点 start()
    // 清归属同款语义）；核心在跑时 applyActiveNodeChange 已切
    // 过去，同样把快照清掉，免得 restart 又起回旧节点。显式
    // 切换（nodeSwitched）与列表变动（订阅刷新/改在用节点链
    // 接/清理不通节点）两路都跟随：没显式切换时，核心在跑仍
    // 走 applyActiveNodeChange，核心停着且有快照时同样改写快
    // 照（与显式切换同款）；removeNode 删在用节点时直接清快
    // 照（见 removeNode），“删在用节点就停核心”原语义不动。
    private func czfFollowPostPingNodeSwitch(postPingActiveLink: String, nodeSwitched: Bool) {
        guard nodeSwitched else {
            // 3.8.594（L127）：列表变动改了活动链接（订阅刷新/
            // 改在用节点链接/清理不通节点）时也得跟随——原来这路
            // 只调 applyActiveNodeChange，它只在核心在跑时才切；
            // 测速开始时核心通常已被 stopCoreForPing 停掉，跟随
            // 就是空操作，旧快照还指着旧链接，restartCoreAfterPing
            // 的守卫（有效链接 == 快照链接）直接拦掉：测速前还在
            // 跑的核心测完一直停着，且收尾在没用户动作时已把预热
            // 抑制置真（!epochChanged 时），预热也不会把它带回
            // 来，只能亲手再起。L125 只盖了亲手点节点那路
            // （nodeSwitched），列表变动这路一直漏着。
            // 核心在跑时照旧 applyActiveNodeChange（原来这路）；
            // 核心停着且有待重启快照时，把快照改写成当前活动链
            // 接、无归属，让 restart 按新链接起（与显式切换
            // 同款：改写后归属为 nil，restart 守卫按当前活动
            // 链接比对、照常通过）。
            vpnCoreLock.lock()
            let czfCoreRunningNow = isRunning
            let czfHadSnapshot = pingStoppedLink != nil
            let czfSnapshotLink = pingStoppedLink
            vpnCoreLock.unlock()
            if czfCoreRunningNow {
                // 3.8.900（L572-2）：列表变动路不抢钉死核心（见 czfFollowListChange）。
                self.czfFollowListChange()
            } else if czfHadSnapshot {
                // 3.8.900（L572-2）：快照链着仍钉死的节点时不动——测速前
                // 核心跑的是钉死 App 的节点，全局换了与它无关，改写快照
                // 会让 restart 按全局节点起、钉死 App 悄悄换 IP；快照链
                // 已不在列表（override 已清）或本来就是全局核心时照旧改写。
                guard !Self.czfIsPinnedLiveLink(czfSnapshotLink) else { return }
                vpnCoreLock.lock()
                self.pingStoppedLink = postPingActiveLink
                self.pingStoppedOwner = nil
                vpnCoreLock.unlock()
            }
            return
        }
        vpnCoreLock.lock()
        let czfCoreRunningNow = isRunning
        let czfHadSnapshot = pingStoppedLink != nil
        vpnCoreLock.unlock()
        if czfCoreRunningNow {
            self.applyActiveNodeChange()
            vpnCoreLock.lock()
            self.pingStoppedLink = nil
            self.pingStoppedOwner = nil
            vpnCoreLock.unlock()
        } else if czfHadSnapshot {
            vpnCoreLock.lock()
            self.pingStoppedLink = postPingActiveLink
            self.pingStoppedOwner = nil
            vpnCoreLock.unlock()
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
        // L143-1：配置变了就刷设置备份（见 refreshSettingsBackup）。
        shared.refreshSettingsBackup()
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
        // 3.8.564（L95）：改链接别把自定义别名弄丢——别名按链接原文存
        // 字典，链接一换键就对不上，亲手起的名字当场掉回地址显示，
        // 旧键还留一条死记录；先记下旧链接的别名，写完列表挪到新
        // 链接上（同文重存是空操作；新链接已有同名死记录时以这次
        // 改动的为准）。删节点那路死记录无害，照旧不清理。
        let oldLink = links[index]
        let oldAlias = Self.nodeAlias(for: oldLink)
        links[index] = trimmed
        UserDefaults.standard.set(links, forKey: Self.nodeListKey)
        if let oldAlias {
            Self.setNodeAlias(oldAlias, for: trimmed)
            if trimmed != oldLink {
                Self.setNodeAlias(nil, for: oldLink)
            }
        }
        // 3.8.582（VPN-1）：钉死同款跟过去——别名挪了，override 不挪
        // 的话钉死的 App 仍拿旧链接连（见上面 helpers 注释）。
        if trimmed != oldLink {
            Self.remapNodeOverride(from: oldLink, to: trimmed)
        }
        if wasActive {
            UserDefaults.standard.set(index, forKey: Self.activeNodeKey)
        } else if let idx = links.firstIndex(of: nodeLink) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        }
        refreshSettingsBackup()
        // 改的正是在用节点：核心还在跑旧链接，界面却已把新链接标成
        // 在用——与 replaceAllNodes 同款，立刻跟过去；测速窗口内
        // 跟随会推迟到测速收尾，核心停着时是空操作。
        // 3.8.900（L572-3）：原样保存不算改——链接一个字没变时跟过
        // 去等于无故重启核心，核心正跑在钉死节点的 App 的节点上时
        // 还会把它抢回全局节点、悄悄换 IP；真改了才跟。
        // 3.8.900（L574-1）：改链接是列表变动、不是显式切节点——上面
        // remap 已把旧链接的钉死挪到新链接上：核心正跑在别的钉
        // 死节点上时跟过去等于抢走养号 App 的核心、悄悄换 IP
        // （L572-2 同款，replaceAllNodes/删节点已修，这里漏了）；
        // 核心跑的正是被改这条时，旧链接已被 remap 挪走、不再被
        // 钉死，跟随照常重启到新链接。显式切节点（setActiveNode）
        // 不走这里，手动强制切换的原语义不动。
        if wasActive && trimmed != oldLink {
            czfFollowListChange()
        } else if trimmed != oldLink {
            // 3.8.900（L576-1）：改的不是全局在用节点、但核心正跑
            // 在这条旧链接上（钉死它的 App 的节点）时也要跟过去——
            // 上面 remap 只把钉死挪到新链接上，核心却还跑着旧链接：
            // 用户改链接多半是旧服务器/密码已死，改完 App 还走旧
            // 链接继续失败、界面却显示新链接，等于改了个寂寞；
            // 下次开 App 时才按新钉死起，之前一直跑旧的。
            // 只认“核心正跑的正是被改这条”：跑在别的钉死节点上
            // 时不动（L574-1 同款，绝不抢走养号 App 的核心）；
            // 跟随目标是改后的新链接，不是全局节点（czfFollowListChange
            // 只会跟全局，钉死 App 跟过去就悄悄换了 IP）。
            // 归属原样带进 start（锁下读到的现任归属），起成功后
            // 归属不变；测速窗口内核心已停（runningLink 为 nil），
            // 不触发，收尾 restart 按已 remap 的新钉死起（见
            // restartCoreAfterPing 的 effectiveLink）。
            vpnCoreLock.lock()
            let czfRunningOldLink = isRunning && runningLink == oldLink
            let czfOwnerBid = coreOwnerBundleId
            let czfOwnerAppInfo = coreOwnerAppInfo
            vpnCoreLock.unlock()
            if czfRunningOldLink {
                // 3.8.900（L577-1）：同款——起核心是同步阻塞的 CGoInvoke，编辑链接在主线程调这里，直调冻界面；放串行队列跑。执行时再验一次核心仍跑在旧链接上（排队这会儿用户可能已亲手停了核心、或测速已停核心，验不过就不起；测速停核心那路收尾 restart 按已 remap 的新钉死起，同款覆盖）。
                Self.czfCoreStartQueue.async {
                    self.vpnCoreLock.lock()
                    let czfStillOnOldLink = self.isRunning && self.runningLink == oldLink
                    self.vpnCoreLock.unlock()
                    if czfStillOnOldLink {
                        _ = self.start(withLink: trimmed, ownerBid: czfOwnerBid, ownerAppInfo: czfOwnerAppInfo)
                    }
                }
            }
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
        // 3.8.523（L51）：vmess 链接整段 authority 是 base64 的
        // JSON（备注在 ps、地址在 add、端口在 port），URLComponents
        // 会把 base64 当主机名——要么整串乱码当名字、要么含 =
        // / 解析失败、所有 vmess 节点都显示成一样的“节点 · vmess”，
        // 列表里认不出是哪个节点（本函数注释的“列表里一眼能认出
        // 是哪个节点”就 broken 在这里；仓内无任何地方解过 vmess
        // 的 ps）。先解 base64 JSON，解不出再走通用路（JSON 节点
        // 显示成“节点”是设置页帮助里写明的既有行为，不动它）。
        if nodeScheme(for: link) == "vmess", let vmess = vmessDisplay(for: std) {
            name = vmess.name
            detail = vmess.detail
        } else if nodeScheme(for: link) == "ss", let ss = ssDisplay(for: std) {
            name = ss.name
            detail = ss.detail
        } else if let comps = URLComponents(string: std) {
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

    /// vmess 链接解备注/地址：`vmess://<base64-JSON>`，JSON 里
    /// ps 是备注、add 是地址、port 是端口（字符串或数字）。
    /// 解不出（非标准 base64/不是 JSON/既无 ps 又无 add）返回
    /// nil，调用方走通用路。base64 可能是 URL 安全变体（- _）
    /// 且缺 padding，与订阅解码同款处理。
    private static func vmessDisplay(for link: String) -> (name: String, detail: String)? {
        guard link.hasPrefix("vmess://") else { return nil }
        var rest = String(link.dropFirst("vmess://".count))
        if let hashIdx = rest.firstIndex(of: "#") { rest = String(rest[..<hashIdx]) }
        if let qIdx = rest.firstIndex(of: "?") { rest = String(rest[..<qIdx]) }
        let b64 = rest
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any] else { return nil }
        let address = (dict["add"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var port = ""
        if let p = dict["port"] as? String {
            port = p
        } else if let p = dict["port"] as? NSNumber {
            port = p.stringValue
        }
        let hostPort = address.isEmpty ? "" : (port.isEmpty ? address : "\(address):\(port)")
        let remark = (dict["ps"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remark.isEmpty || !hostPort.isEmpty else { return nil }
        return (name: remark.isEmpty ? hostPort : remark, detail: hostPort)
    }

    /// ss 链接解地址：`ss://<base64(method:password@host:port)>#名`
    /// （整段 authority 是 base64 的老格式）。通用路拿 base64 当
    /// 主机名——有 #备注时详情行显示一整串 base64 而不是地址:端口，
    /// 没备注时名字本身就是那串 base64，列表里认不出是哪个节点
    /// （vmessDisplay 的 L51 同款）。只有 authority 里没有 "@"
    /// 时才试解（`ss://base64@host:port` 那种只编了 userinfo 的，
    /// 通用路本来就能读出 host:port，不动它）；解不出/格式不对
    /// 返回 nil，调用方走通用路。base64 可能是 URL 安全变体
    /// （- _）且缺 padding，与 vmessDisplay 同款处理。
    /// 3.8.900（L575-2）
    private static func ssDisplay(for link: String) -> (name: String, detail: String)? {
        guard link.hasPrefix("ss://") else { return nil }
        var rest = String(link.dropFirst("ss://".count))
        // 外面的 #备注先取出来（名字优先用它）；authority 是 # 之前那段。
        var remark = ""
        if let hashIdx = rest.firstIndex(of: "#") {
            let rawRemark = String(rest[rest.index(after: hashIdx)...])
            remark = rawRemark.removingPercentEncoding ?? rawRemark
            rest = String(rest[..<hashIdx])
        }
        // authority 里有 @ 就是标准/半 base64 格式，通用路能读，不动。
        guard !rest.contains("@") else { return nil }
        // base64 本身可能含 "/"，整段先试；外面带 "/?plugin=…" 时
        // 再试 "/" / "?" 之前的前缀。两次都按下面的严格形状验，
        // 解出来不是 method:password@host:port 就返回 nil，不误伤。
        var candidates: [String] = [rest]
        if let slashIdx = rest.firstIndex(of: "/") { candidates.append(String(rest[..<slashIdx])) }
        if let qIdx = rest.firstIndex(of: "?") { candidates.append(String(rest[..<qIdx])) }
        for candidate in candidates {
            let b64 = candidate
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4)
            guard let data = Data(base64Encoded: padded),
                  var decoded = String(data: data, encoding: .utf8) else { continue }
            decoded = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            // 解开后可能带 "/?plugin=…" 或 "#名"，先切掉。
            if let cutIdx = decoded.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                decoded = String(decoded[..<cutIdx])
            }
            // method:password@host:port——密码里可能含 ":"，按第一个
            // ":" 分 method；host:port 按最后一个 "@" 与最后一个
            // ":" 分（IPv6 主机带方括号）。
            guard let atIdx = decoded.lastIndex(of: "@") else { continue }
            let hostPort = String(decoded[decoded.index(after: atIdx)...])
            let methodAndPassword = String(decoded[..<atIdx])
            guard methodAndPassword.contains(":") else { continue }
            let host: String
            let port: String
            if hostPort.hasPrefix("[") {
                guard let closeIdx = hostPort.firstIndex(of: "]") else { continue }
                let afterBracket = hostPort.index(after: closeIdx)
                guard afterBracket < hostPort.endIndex, hostPort[afterBracket] == ":" else { continue }
                host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closeIdx])
                port = String(hostPort[hostPort.index(after: afterBracket)...])
            } else {
                guard let colonIdx = hostPort.lastIndex(of: ":") else { continue }
                host = String(hostPort[..<colonIdx])
                port = String(hostPort[hostPort.index(after: colonIdx)...])
            }
            guard !host.isEmpty, let portInt = Int(port), (1...65535).contains(portInt) else { continue }
            let hostPortText = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            let cleanRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name: cleanRemark.isEmpty ? hostPortText : cleanRemark, detail: hostPortText)
        }
        return nil
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

    /// 3.8.545（L75）：bundleIdentifier() 读 _info（doUseLCBundleId 时读 LCOrignalBundleIdentifier，见 LCAppInfo.m:188）；下面五处 helper 被 signApp/runApp/ensureRunning/waitUntilNodeReady/startFallback 的后台任务调，离主线程读与主线程写竞态（L70/L72-2 同款）。主线程直读、后台经 main.sync 取（L70/L73 同款，isMainThread 防自死锁；只拷一个字符串，极快，不把文件 I/O 搬回主线程）。注意：绝不在持 vpnCoreLock 时调它——主线程可能正等这把锁，会死锁；claim 那处先在锁外取（见该函数注释）。
    private static func czfBundleId(for appInfo: LCAppInfo) -> String? {
        if Thread.isMainThread { return appInfo.bundleIdentifier() }
        return DispatchQueue.main.sync { appInfo.bundleIdentifier() }
    }

    public static func isEnabled(for appInfo: LCAppInfo) -> Bool {
        guard let bundleId = czfBundleId(for: appInfo) else { return false }
        return UserDefaults.standard.bool(forKey: enabledKeyPrefix + bundleId)
    }

    public static func setEnabled(_ enabled: Bool, for appInfo: LCAppInfo) {
        guard let bundleId = czfBundleId(for: appInfo) else { return }
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
        // L143-1：配置变了就刷设置备份（见 refreshSettingsBackup）。
        shared.refreshSettingsBackup()
    }

    // 用户是否在 App 设置里亲手选过"跟随全局"（缺省 false）
    public static func isFollowGlobalExplicit(for appInfo: LCAppInfo) -> Bool {
        guard let bundleId = czfBundleId(for: appInfo) else { return false }
        return UserDefaults.standard.bool(forKey: followGlobalKeyPrefix + bundleId)
    }

    // 按 App 指定节点：存链接本身而不是下标，节点列表增删、
    // 排序、订阅替换都不会让指定关系错位。钉死后即使这条链
    // 接不在列表里了也照用——列表只是选节点的菜单，不是
    // App 的 IP 归属；删了菜单项就悄悄换 IP，正是养号最忌
    // 讳的。亲手选跟随全局时才回落全局
    public static func nodeOverride(for appInfo: LCAppInfo) -> String? {
        guard let bundleId = czfBundleId(for: appInfo) else { return nil }
        let saved = UserDefaults.standard.string(forKey: nodeOverrideKeyPrefix + bundleId)
        return (saved?.isEmpty == false) ? saved : nil
    }

    public static func setNodeOverride(_ link: String?, for appInfo: LCAppInfo) {
        guard let bundleId = czfBundleId(for: appInfo) else { return }
        if let link, !link.isEmpty {
            UserDefaults.standard.set(link, forKey: nodeOverrideKeyPrefix + bundleId)
            UserDefaults.standard.removeObject(forKey: followGlobalKeyPrefix + bundleId)
        } else {
            UserDefaults.standard.removeObject(forKey: nodeOverrideKeyPrefix + bundleId)
            UserDefaults.standard.set(true, forKey: followGlobalKeyPrefix + bundleId)
        }
        // L143-1：配置变了就刷设置备份（见 refreshSettingsBackup）。
        shared.refreshSettingsBackup()
    }

    // 3.8.582（VPN-1）：钉死链接维护——override 存的是整条链接串，
    // 节点列表变了它不会自己跟过去：改链接时钉死的 App 仍拿旧链
    // 接连（旧密码/旧服务器已死），删节点/订阅替换后钉死的链接
    // 也不在列表里了，设置页菜单只列当前节点，过期 override 本
    // 身不显示，用户无从发现、无从改。改链接跟到新链接；旧链接
    // 不在新列表里了就清掉（回落跟随全局），不让钉死的 App 永远
    // 拿死链接连。调用方在 refreshSettingsBackup() 之前调这里，
    // 备份里记的才是迁移后的钉死关系。
    /// 把指着 oldLink 的 override 改指 newLink（改链接用）。
    private static func remapNodeOverride(from oldLink: String, to newLink: String) {
        let defaults = UserDefaults.standard
        // dictionaryRepresentation() 是快照，边遍历边写是安全的。
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(nodeOverrideKeyPrefix) {
            guard defaults.string(forKey: key) == oldLink else { continue }
            defaults.set(newLink, forKey: key)
        }
    }

    /// 清掉所有指着已不在 links 里的链接的 override（删节点/
    /// 订阅替换/清理/重排用），回落跟随全局（setNodeOverride(nil)
    /// 同款：删键 + 置 followGlobal）。还在列表里的不动。
    private static func clearStaleNodeOverrides(keeping links: [String]) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(nodeOverrideKeyPrefix) {
            guard let saved = defaults.string(forKey: key), !saved.isEmpty, !links.contains(saved) else { continue }
            defaults.removeObject(forKey: key)
            defaults.set(true, forKey: followGlobalKeyPrefix + String(key.dropFirst(nodeOverrideKeyPrefix.count)))
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
                    // 3.8.523（L51）：先拷到临时文件、再换位——原来
                    // 先删旧插件再拷新，拷失败（磁盘满）时旧插件已
                    // 没了、还返回 true（调用方以为换上了新插件就
                    // 去单签，实际签的是不存在的文件）；钉死节点的
                    // App 没了插件就断网。临时文件拷失败时旧插件
                    // 原样保留、返回 false。
                    // 3.8.599（L133-1）：换位也走 replaceItemAt——原来
                    // 先删旧插件再 move，删与挪之间被杀/闪退就是
                    // 插件没了（备份最后一步与钥匙串桥同款口子，
                    // L132-1 已修那两处，这里是第三处）；同目录
                    // replaceItemAt（无旧插件时 move），失败时旧
                    // 插件原样保留、清临时文件、返 false。
                    let tmpDest = dest.appendingPathExtension("czf-tmp")
                    try? fm.removeItem(at: tmpDest)
                    guard (try? fm.copyItem(at: src, to: tmpDest)) != nil else { return false }
                    if fm.fileExists(atPath: dest.path) {
                        do {
                            _ = try fm.replaceItemAt(dest, withItemAt: tmpDest)
                        } catch {
                            try? fm.removeItem(at: tmpDest)
                            return false
                        }
                    } else if (try? fm.moveItem(at: tmpDest, to: dest)) == nil {
                        try? fm.removeItem(at: tmpDest)
                        return false
                    }
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
        // 3.8.554（L221）：亲手停核心时一并清掉测速的待重启快照——
        // stop() 只停核心，不清快照（L127 删在用节点同款已修过一次，
        // removeNode :467 在位）；三处开关只认本页 vpnPinging，跨页
        // 不互斥：面板打开后设置页/App 页才开始测速，面板开关还是
        // 打开前刷的那个 true、照常能点，点“停止核心”只是空操作
        // （核心已被 stopCoreForPing 停下），测完 completion 还会
        // restartCoreAfterPing 把核心起回来，亲手停核心的意图被
        // undo（L193-1 只拦了面板自己测速那一窗；L222 的调出刷新
        // 只在打开时刷，面板已打开时不补刷）。快照只由
        // restartCoreAfterPing 消费，清掉后 restart 读到 nil 不再起；
        // 非测速窗口内快照本来就是 nil，清掉是空操作。三处开关都
        // 先调这里再起/停，放这里一次盖住三路。
        if !started {
            pingStoppedLink = nil
            pingStoppedOwner = nil
            // 3.8.900（L569-1）：亲手停核心记一代次——轮换/就地切正在
            // 重试时见代次变了就收手，不把刚停的核心又起回来（见
            // czfManualCoreStopEpoch 注释）；亲手起核心不记（起核后
            // 核心在跑且无归属，重试前的归属复验自会让路）。
            czfManualCoreStopEpoch += 1
        }
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

    // 3.8.900（L570-1）：czfKeepAutoStop 只给测速后重启（restartCoreAfterPing）
    // 传 true——那不是一次 App 启动，只是把测速前在跑的核心起回来：
    // 下面两步（取消待执行的自动停、把闲置计时起点刷成现在）是“有 App
    // 刚启动”的语义，重启路走它等于把已排好的自动停取消、闲置时钟
    // 重置，之后再没人重排，核心一直跑到下次 App 开关才停（耗电）。
    // 其余调用方（runApp、测速收尾补跑）都是真启动，一字不动。
    public func ensureRunning(for appInfo: LCAppInfo? = nil, czfKeepAutoStop: Bool = false) {
        // 开 App 是用户/ App 动作：记进 epoch，测速收尾的
        // 校验不会把它当成自动触发 undo 掉。
        if appInfo != nil {
            vpnCoreLock.lock()
            coreActionEpoch += 1
            vpnCoreLock.unlock()
        }
        // 有被标记 App 在启动：取消待执行的自动停，并记下时间
        // 3.8.900（L567-2）：cancel 与置 nil 必须在同一把锁下——
        // 本函数跑在 detached 后台任务里，noteRunningAppsChanged
        // 在主线程排新任务；两条语句之间被插队会把新排任务的引
        // 用抹掉，cancel 丢了、任务到点仍触发（下面 checkPendingStop
        // 的停前复核是第二道防线）。
        if !czfKeepAutoStop {
            vpnCoreLock.lock()
            pendingStopWork?.cancel()
            pendingStopWork = nil
            vpnCoreLock.unlock()
            lastFlaggedLaunchAt = Date()
        }
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
        if pinging, let appInfo, !deferredEnsureApps.contains(where: { $0 === appInfo }) {
            deferredEnsureApps.append(appInfo)
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
        // 会清掉归属，那时才换；自动启动只保证核心在跑。
        // appInfo 为 nil 的调用方（测速完 restartCoreAfterPing
        // 的无归属快照）也不能抢：原来 `let bid` 要求调用方
        // 必须有 bundleId，nil 调用方直接跳过守卫——测速中途
        // 别的 App 刚起了核心，收尾会把它抢回旧节点、还把归属
        // 写成 bundleId/空 appInfo 不同步的一对。
        // 3.8.545（L75）：bundleIdentifier() 读 _info，离主线程读竞态；经 helper 取（此处未持锁，main.sync 安全）。
        // 3.8.562（L93）：bid 在锁外取好（L75，绝不在持锁时调
        // czfBundleId），传进 start(withLink:)——锁下再认归属
        // 才是终审（见该函数注释）；这里的无锁守卫只作快拒。
        let czfBid = appInfo.flatMap { Self.czfBundleId(for: $0) }
        if isRunning,
           let owner = coreOwnerBundleId,
           czfBid != owner {
            lastError = "核心正被另一个已钉死节点的 App 占用，暂不切换（手动在设置里切节点可强制切换）"
            return
        }
        // 3.8.900（L569-2）：记下起核前的代次，传给 startFallback——
        // 代次快照必须在起核前取：用户可能正在起核这几秒里亲手停
        // 核心（停核心那下先卡在锁上、等起核失败才跑），起核失败后
        // 再取就已是停过之后的代次，重试复验恒过、等于没验。
        vpnCoreLock.lock()
        let czfStopEpochBeforeStart = czfManualCoreStopEpoch
        vpnCoreLock.unlock()
        if start(withLink: link, ownerBid: czfBid, ownerAppInfo: appInfo) {
            claimCoreOwnershipIfRunning(link: link, for: appInfo)
        } else {
            // 启动时节点起不来就地往下一个切：之前是起不来
            // 就停在死节点上，App 一直不通；轮换要等 3 次
            // 失败才触发，根本等不到。排序与轮换同款（新鲜
            // 测速从快到慢，没测速排最后），钉死的改 override，
            // 跟随全局的改全局活动节点；一圈都不通就停。
            startFallback(from: link, for: appInfo, stopEpochAtEntry: czfStopEpochBeforeStart)
        }
    }

    /// 测速窗口内关掉的 App：它排进 deferredEnsureApps 的那次
    /// 启动请求作废——收尾补跑会把核心起在已关 App 的节点上，
    /// 而关窗那刻核心还没跑、noteRunningAppsChanged 的
    /// `guard isRunning else { return }` 直接 return、没排待停，
    /// 核心起起来后就一直跑到下一次 App 开关才停（没有别的
    /// 周期巡检会停它）。宿主侧不用同款：ensureRunningForHost
    /// 的补跑入口先查 isHostProxyEnabled，关了就直接 return。
    /// 调用方在主线程（removeRunningApp 的 main.async 块），
    /// bundleIdentifier() 的 _info 读安全；同数组的追加与两
    /// 路收尾取走都在这把锁下。按身份比对，AppInfoProvider
    /// 兜底重建的另一份实例按（包名，容器）认——同一容器就
    /// 是同一份启动请求，不会误取消别的分身。
    public func cancelDeferredEnsure(for appInfo: LCAppInfo) {
        vpnCoreLock.lock()
        deferredEnsureApps.removeAll(where: {
            $0 === appInfo
                || ($0.dataUUID != nil && $0.dataUUID == appInfo.dataUUID
                    && $0.bundleIdentifier() == appInfo.bundleIdentifier())
        })
        vpnCoreLock.unlock()
    }

    /// 起核心后认领归属（ensureRunning / startFallback /
    /// waitUntilNodeReady 三路共用）：只有在同一把锁下看到
    /// runningLink 仍是刚起的那条才认领。两个 VPN App 同时启动
    /// 时，后起的会把核心换成自己的节点；先起的不能在事后把
    /// 归属写成自己——归属与在跑链接对不上，轮换巡检会按错
    /// App 读统计。没认领时不排轮换，归属方自己的那路会排。
    private func claimCoreOwnershipIfRunning(link: String, for appInfo: LCAppInfo?) {
        // 3.8.545（L75）：bundleIdentifier() 读 _info，离主线程读竞态；先在锁外取——main.sync 绝不能在持锁时调（主线程可能正等这把锁，会死锁），bundleId 不会变，锁外取与锁内取同一值。
        let claimBid = appInfo.flatMap { Self.czfBundleId(for: $0) }
        vpnCoreLock.lock()
        let claimed = isRunning && runningLink == link
        if claimed {
            // 3.8.900（L577-2）：只在无归属或同一 App 时认领——原来不管现任归属是谁都直接改写：A 钉死节点 X、核心归属 A 时，B（跟随全局，全局正好也是 X）一打开就把归属偷成 B；X 死后轮换按 B 走，新节点只写全局下标、A 的钉死仍指着已死的 X，之后每次开 A 都先试死节点再就地切。现任归属是别的 App 时不动（B 的启动照常放行，核心本来就在 B 要的节点上）；无归属（手动起核心）或同一 App（分身共用 bundleId 也算同一）时照旧认领。只比 bundleId：coreOwnerBundleId 与 coreOwnerAppInfo 同步记、同步清，拿它当唯一身份，不在锁下调 bundleIdentifier()（L75 死锁禁令）。
            if coreOwnerBundleId == nil || (claimBid != nil && coreOwnerBundleId == claimBid) {
                if let bid = claimBid {
                    coreOwnerBundleId = bid
                }
                // appInfo 为 nil 时不动归属：上面只在有值时改
                // bundleId，这里却把 appInfo 置 nil，会让两字段
                // 不同步（bundleId 指着旧 App、appInfo 是空），
                // 轮换巡检读到空归属就停摆。nil 调用方只认领
                // “在跑”的事实，不改归属。
                if let appInfo = appInfo {
                    coreOwnerAppInfo = appInfo
                }
            }
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
        // 3.8.900（L569-2）：记下进来的代次——候选重试前复验用（见循环内）。
        vpnCoreLock.lock()
        let czfStopEpochAtEntry = czfManualCoreStopEpoch
        vpnCoreLock.unlock()
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
        // 3.8.562（L93）：bid 锁外取好传进 start（同 ensureRunning）。
        let czfBid = Self.czfBundleId(for: appInfo)
        for cand in cands.prefix(2) {
            // 测速窗口内不切节点起核心：这轮探针是 runApp 派的，
            // 用户此时点“测延迟”会先停核心再测；这里中途起核心
            // 会让 pingBatch 被拒、整轮测速作废。直接返回 false，
            // 调用方按 fail-open 放行，绝不无限等。
            vpnCoreLock.lock()
            let pinging = isPinging
            vpnCoreLock.unlock()
            guard !pinging else { return false }
            // 3.8.900（L569-2）：重试前复验（同 L569-1：探针几秒里用户
            // 可能已亲手停了核心、或别的 App 刚起核心；不复验就起候选
            // 节点，等于把刚停的核心又起回来、或停掉别人刚起的核心。
            // 收手：返回 false，调用方按既有 fail-open 放行）。
            if czfRetryYielded(stopEpochAtEntry: czfStopEpochAtEntry, for: appInfo) { return false }
            // 起核心是同步阻塞的 CGoInvoke，放 detached 跑，
            // 不冻调用方的协作线程（runApp 侧同款做法）。
            let started = await Task.detached(priority: .userInitiated) { CZFVPNManager.shared.start(withLink: cand.link, ownerBid: czfBid, ownerAppInfo: appInfo) }.value
            guard started else { continue }
            claimCoreOwnershipIfRunning(link: cand.link, for: appInfo)
            if await probeNodeThroughCore(timeout: timeout) {
                // 3.8.523（L51）：探通了才把候选节点写进钉死/
                // 全局——原来先写再探，探不通继续试下一个，最
                // 后全试完都失败时钉死/全局已指着最后一个探
                // 证已死的节点，用户的原节点选择被悄悄换掉，
                // 下次启动还先上这个死节点。全局下标按当前列
                // 表现查（探针几秒里用户可能增删过节点，旧快
                // 照的 idx 会指错行；钉死那路本来就是按内容写）。
                if Self.nodeOverride(for: appInfo) != nil {
                    Self.setNodeOverride(cand.link, for: appInfo)
                } else if let idx = nodeLinks.firstIndex(of: cand.link) {
                    UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
                }
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

    // 经核心发一次真实请求验节点：走 HTTP 10828 代理发真实请求，
    // 拿到任何 HTTP 回应即算通（出站失败时核心直接断连接、不回
    // HTTP）。不只访一个站——有些节点单拦一路、实际经节点上网
    // 是通的（测速里的假不通同款教训），按测速顺序三目标重试
    //（Cloudflare → gstatic → Apple）。超时/抛错即换下一个站。
    // 只读，不改核心与节点状态。
    private func probeNodeThroughCore(timeout: TimeInterval) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = Self.proxyDictionary()
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        // 3.8.582（VPN-4）：单访 gstatic 会假死——有些节点单拦一路、
        // 实际经节点上网是通的。按测速的顺序三目标重试，任一回
        // HTTP 即算通；三个都失败才算不通。每个目标各给足 timeout
        //（握手本身要 4 秒，拆小了会把慢节点误判死；全死时最坏
        // 3 倍超时，只在死节点上多等，调用方照常 fail-open）。
        for urlString in ["https://cp.cloudflare.com/", "https://www.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"] {
            guard let url = URL(string: urlString) else { continue }
            do {
                let (_, response) = try await session.data(from: url)
                if response is HTTPURLResponse { return true }
            } catch {
                continue
            }
        }
        return false
    }

    // 多任务列表变化后由 MultitaskDockManager 调用：还在跑的
    // App 里已经没有被标记的了，就按自动停档位排一个停核心；
    // 期间有被标记 App 起来（ensureRunning 会取消）就不停
    public func noteRunningAppsChanged(stillHasFlagged: Bool) {
        // 宿主自身走节点的开关开着时，核心同样算"还在被用"
        if stillHasFlagged || Self.isHostProxyEnabled {
            // 3.8.900（L567-2）：cancel 与置 nil 在同一把锁下——
            // ensureRunning 在 detached 任务里同时碰它（见该函数
            // 注释），两条语句之间插队会抹掉对方刚排的任务。
            vpnCoreLock.lock()
            pendingStopWork?.cancel()
            pendingStopWork = nil
            vpnCoreLock.unlock()
            return
        }
        guard isRunning else { return }
        // 3.8.900（L567-2）：取消旧任务、建新任务、赋值三步在
        // 同一把锁下——建任务不碰共享状态，锁里建无妨；分开写
        // 会在取消与赋值之间留窗口，ensureRunning 的 cancel+nil
        // 落进来会把新任务引用抹掉（到点仍触发，靠下面的停前
        // 复核兜底）。
        vpnCoreLock.lock()
        pendingStopWork?.cancel()
        // 永不档：前面已取消待停任务，这里不再排新的——
        // asyncAfter 拿 .infinity 排期行为未定义，绝不能排。
        guard !Self.autoStopDelay.isInfinite else {
            vpnCoreLock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.checkPendingStop()
        }
        pendingStopWork = work
        vpnCoreLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoStopDelay, execute: work)
    }

    /// 到点的自动停检查（noteRunningAppsChanged 排的任务与测速中
    /// 的重试共用）：逐项重查——核心还在跑、宿主开关关着、闲置
    /// 够分钟数、测速窗口外、停前复核无标 VPN 的 App 在跑，五项
    /// 全过才停（3.8.900（L567-2）：最后一项是漏网待停任务的兜底）。测速窗口内不算数：
    /// 30 秒后重查一次（测速有界、一定会结束），而不是丢掉这次
    /// 自动停、等下一次 App 变化（可能永远不来，核心就一直跑）。
    /// 重试同样逐项重查：期间有 App 启动/宿主开关打开，重查会
    /// 拦下，不会误停。
    private func checkPendingStop() {
        guard isRunning else { return }
        if Self.isHostProxyEnabled { return }
        // 档位改长了：到点时闲置还不够新档位，别直接丢掉这次
        // 自动停——否则核心一直跑到下次 App 变化才停。按剩余
        // 时间重排（改短不影响：到点时闲置已够，直接往下走）。
        // 改成“永不”时这次自动停作废（asyncAfter 拿 .infinity
        // 排期行为未定义，绝不能排）。
        let delay = Self.autoStopDelay
        let idle = Date().timeIntervalSince(lastFlaggedLaunchAt)
        if idle < delay {
            guard !delay.isInfinite else { return }
            let retry = DispatchWorkItem { [weak self] in
                self?.checkPendingStop()
            }
            // 3.8.900（L567-2）：赋值进锁（ensureRunning 在 detached
            // 里同时碰它；只锁赋值，建任务与排期不碰共享状态）。
            vpnCoreLock.lock()
            pendingStopWork = retry
            vpnCoreLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay - idle), execute: retry)
            return
        }
        vpnCoreLock.lock()
        let pinging = isPinging
        vpnCoreLock.unlock()
        if pinging {
            let retry = DispatchWorkItem { [weak self] in
                self?.checkPendingStop()
            }
            // 3.8.900（L567-2）：同上，赋值进锁。
            vpnCoreLock.lock()
            pendingStopWork = retry
            vpnCoreLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: retry)
            return
        }
        // 3.8.900（L567-2）：停之前再复核一次还有没有标 VPN 的
        // App 在跑（与 noteRunningAppsChanged 同口径：坞里的在跑
        // 列表）——待停任务可能因跨线程竞态成了漏网之鱼（cancel
        // 丢了），只按闲置时间判会把正开着的 App 断网（钉死节点
        // 的直接断网，跟随全局的悄悄直连），且没有任何提示；只
        // 在虚拟窗模式下复核（原生窗 App 不进坞表，列表空不代表
        // 没人在跑，那路保持现状）。在跑就不停、清掉本任务，
        // 下次关 App 时 noteRunningAppsChanged 会重排。
        if #available(iOS 16.0, *),
           (MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow) == .virtualWindow,
           MultitaskDockManager.shared.apps.contains(where: { app in
               guard let info = app.appInfo else { return false }
               return Self.isEnabled(for: info)
           }) {
            vpnCoreLock.lock()
            pendingStopWork = nil
            vpnCoreLock.unlock()
            return
        }
        // 3.8.900（L569-1）：到点停核心也是“停核心”的决定，记一代次——
        // 轮换/就地切正在重试时见代次变了就收手，不把刚停的核心又起回来。
        vpnCoreLock.lock()
        czfManualCoreStopEpoch += 1
        vpnCoreLock.unlock()
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        // 3.8.554（L221）：测速窗口内亲手起核心直接拒——三处开关只认
        // 本页 vpnPinging，跨页不互斥：别处测速时本页开关还能点“启动
        // 核心”（核心已被 stopCoreForPing 停下，开关显示未启动）；Xray
        // 节点测速不走 sing-box 临时实例，start(withLink:) 里的探针守卫
        // （CZFSingBoxCore.isServiceRunning）拦不住，start() 会把主核心
        // 起起来、测速的 pingBatch 被生命周期锁拒、整批结果记“核心占用”
        // （TUIC 测速有临时实例占着才拦得住）。内部三路 start() 调用方
        // 进门前都已判 isPinging（prewarmIfNeeded、applyActiveNodeChange、
        // ensureRunningForHost），不受影响；restartCoreAfterPing 走
        // ensureRunning → start(withLink:)，不走这里。
        guard !isPinging else {
            lastError = "测速进行中，稍后再试"
            return false
        }
        // 3.8.523（L51）：手动起核心是新的明确意图，之前排好的
        // 自动停不能再按旧截止时间把它停掉——ensureRunning（开
        // App）与 ensureRunningForHost 起核心时都会取消待停，
        // 唯独设置页手动起核心与切节点走的 start() 漏了：标 VPN
        // 的 App 关窗排好 10 分钟待停后，用户在设置页亲手起核
        // 心，待停到点时 idle（自上次启动算起）已够档位，check-
        // PendingStop 直接 stop()，刚亲手起的核心可能 1 分钟
        // 后就被停掉。取消后下次关 App 时 noteRunningAppsChanged
        // 再排新的；起失败时核心本就停着，待停到点也是空操作。
        pendingStopWork?.cancel()
        pendingStopWork = nil
        // 手动 / 宿主 / 预热起核心：不归某个 App 所有，清掉
        // 养号归属，之后 App 自动启动才可以重新抢核心
        coreOwnerBundleId = nil
        coreOwnerAppInfo = nil
        let ok = start(withLink: nodeLink)
        // 3.8.282：起成功了就记下“开着”，宿主重启后恢复
        // 成开着；起失败不写（状态没变）。stop() 里对称写“关着”。
        if ok { coreWasRunning = true }
        // 3.8.582（VPN-5）：手动起成功后也排一次轮换巡检——以前
        // 只清归属、不排巡检，死节点占着核心、之后又没开过标 VPN
        // 的 App 时，30 秒巡检永远不排。锁是 NSRecursiveLock，
        // 这里调 scheduleRotateCheck 不死锁；归属为 nil 时下面
        // rotateCheck 走探针兜底。
        if ok { scheduleRotateCheck() }
        return ok
    }

    // 用指定链接起核心：已在跑且正是这条链接就直接成功；
    // 在跑的是别的节点先停再按这条起
    // 3.8.562（L93）：ownerBid/ownerAppInfo 是调用方的归属（锁外
    // 取好传进来，绝不在持锁时调 czfBundleId，L75）——归属守卫
    // 必须在同一把锁下与停旧核心原子完成：原来守卫只在
    // ensureRunning 里无锁读，两个 App 在同一轮阻塞式 start
    //（CGo invoke 几百毫秒到数秒，期间 isRunning 仍是 false）
    // 里先后越过守卫，后起的 start 会停掉先起的核心、换成自己
    // 的节点，先起的 App fail-open 跑在别人的节点上（钉死节点
    // 的养号 App 悄悄换 IP，与 L91 同款症状、另一条路）。这里
    // 在锁下再认一次归属：核心正跑在别人的节点上就拒绝起，
    // 不动别人的核心；起成功后也在同一把锁下认领归属（只写
    // 字段，不排轮换——轮换仍由调用方事后的认领排），起完与
    // 认领之间不再有窗口。nil = 手动/无归属起核心（start()、
    // ensureRunningForHost），不拒绝、不认领，原语义不动。
    private func start(withLink rawLink: String, ownerBid: String? = nil, ownerAppInfo: LCAppInfo? = nil) -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            lastError = "还没填节点链接"
            return false
        }
        if isRunning && runningLink == link { return true }
        // 3.8.900（L575-1）：测速窗口内不起主核心——六路调用方
        // （ensureRunning / start() / waitUntilNodeReady / 轮换两路 /
        // startFallback）起核前都查过 isPinging，但查与起之间隔着
        // effectiveLink/nodeOverride 的 main.sync 与归属守卫：查完
        // 到起核之间用户在另一页点下“测延迟”，窗口已立、起核照常
        // 跑，pingBatch/探针撞上在跑的核心、整批记“核心占用”，
        // 测速白跑一轮、还弹“核心在跑”。这里已持 vpnCoreLock
        // （pingAllNodes/pingSingleNode 立标志走同一把锁），锁下
        // 再验一次才是终审；已在跑同一条时上面已直接返回 true，
        // 不扰测速。测速收尾的 restartCoreAfterPing 在 isPinging
        // 已清后才跑，不受影响；轮换/就地切的每轮重查（L571-1）
        // 仍在，起核被拒后各自收手，不死循环。
        guard !isPinging else {
            lastError = "测速进行中，稍后再试"
            return false
        }
        // 锁下再认归属：已被别的 App 钉死占住时拒绝，不停它的核心。
        if isRunning, let owner = coreOwnerBundleId, let bid = ownerBid, bid != owner {
            lastError = "核心正被另一个已钉死节点的 App 占用，暂不切换（手动在设置里切节点可强制切换）"
            return false
        }
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
            if ok {
                coreWasRunning = wasRunningFlag
                // 3.8.562（L93）：起成功当场认领（同锁下，后面
                // 再无窗口可抢；轮换仍由调用方事后认领排）。
                if let ownerBid { coreOwnerBundleId = ownerBid }
                if let ownerAppInfo { coreOwnerAppInfo = ownerAppInfo }
            }
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
        // 3.8.562（L93）：起成功当场认领（同上）。
        if let ownerBid { coreOwnerBundleId = ownerBid }
        if let ownerAppInfo { coreOwnerAppInfo = ownerAppInfo }
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
    // 同一时刻只有一个巡检在跑；核心没在跑、开关关着时不排
    //（下次起核心 / 开开关时再排）。3.8.582（VPN-5）：不要求
    // 归属 App——手动起核心没有归属，归属守卫会让巡检永远排
    // 不上；无归属时 rotateCheck 走探针兜底（见下面）。
    private func scheduleRotateCheck() {
        pendingRotateWork?.cancel()
        pendingRotateWork = nil
        vpnCoreLock.lock()
        let running = isRunning
        vpnCoreLock.unlock()
        guard running, Self.isAutoRotateEnabled else { return }
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
        guard running, Self.isAutoRotateEnabled, !pinging else {
            scheduleRotateCheck()
            return
        }
        // 有归属且统计可读 → 原来的增量统计路（下面 if 内，一字不动）
        // 3.8.900（L568-1）：统计还得是新鲜的——归属 App 关掉/挂起后
        // 文件冻结，增量恒为 0、轮换条件永不成立，探针兜底又只在
        // “无归属或统计读不到”时才走，冻结但能读到的文件把它也堵
        // 住了（宿主代理开着时核心留下来给源/下载用，节点死后宿主
        // 流量一直走死节点，直到下次开标 VPN 的 App 或亲手切节点）。
        // 文件不新鲜就走下面的探针兜底（实测，不认冻结的数）。
        if let appInfo = owner,
           Self.czfProxyStatsFresh(for: appInfo),
           let dict = Self.proxyStatsDict(for: appInfo),
           let failed = Int64(dict["failed"] ?? ""),
           let proxied = Int64(dict["proxied"] ?? "") {
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
            if failedDelta >= 3 && proxiedDelta == 0, !czfRotateRunning {
                // 3.8.900（L567-1）：轮换在后台起核心——rotateToNextNode
                // 里的 start(withLink:) 是同步阻塞的 CGoInvoke（转换 +
                // 起核，几秒），原来整段跑在主队列上，节点一死界面就
                // 冻住几秒、候选多时冻更久；改 Task 里跑，跑完再排
                // 下一轮检查（不先排：下一轮 30 秒从轮换结束起算，
                // 与原来一致）；在途旗子防重叠（节点多、一轮超过
                // 30 秒时定时器不再叠加第二轮）。
                czfRotateRunning = true
                Task { @MainActor in
                    await self.rotateToNextNode(for: appInfo)
                    self.czfRotateRunning = false
                    self.scheduleRotateCheck()
                }
                return
            }
            scheduleRotateCheck()
            return
        }
        // 3.8.582（VPN-5）：无归属（手动起核心），或归属 App 的统计
        // 文件读不到（插件还没落盘 / App 一直连不上）时，统计路永
        // 远走不到轮换、死节点一直占着。改走直接探核心：连续两次
        // 探不通才轮换（一次失败可能是瞬时抖动）；探通了计数清零。
        // 探针是 async，这里起 Task 跑；下一轮先照常排（Task 里轮
        // 换后还会重排，不冲突）；结果处理跳回主队列跑（与
        // rotateCheck/rotateToNextNode 同在主队列，rotateTriedLinks
        // 等状态仍只在主队列上碰）。
        scheduleRotateCheck()
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.probeNodeThroughCore(timeout: 5)
            // 3.8.900（L563-1）：把探针发起时的链接带给结果处理——探针跑完
            // 时节点可能已换，旧节点的结果不能记到新节点头上。
            await MainActor.run { self.handleRotateProbeResult(ok: ok, link: link) }
        }
    }

    /// 探针兜底的结果处理（3.8.582（VPN-5），跑在 MainActor.run 里，
    /// 与 rotateCheck/rotateToNextNode 同在主队列）：探通清零；
    /// 连续两次探不通才轮换——有归属走 rotateToNextNode（它自带
    /// 归属复验），无归属走下面的全局轮换。处理完重排下一轮。
    /// 3.8.900（L563-1）：计数按链接分账——探针跑完时节点已换（手动切/
    /// 统计路轮换/启停）就丢弃这份旧结果；链接变了就重开一轮计数，
    /// 旧节点的 1 次失败不算到新节点头上。
    private func handleRotateProbeResult(ok: Bool, link probeLink: String?) {
        vpnCoreLock.lock()
        let currentLink = runningLink
        let coreRunning = isRunning
        vpnCoreLock.unlock()
        guard coreRunning, let probeLink, currentLink == probeLink else {
            scheduleRotateCheck()
            return
        }
        if rotateProbeLink != probeLink {
            rotateProbeLink = probeLink
            rotateProbeFailures = 0
        }
        if ok {
            rotateProbeFailures = 0
            scheduleRotateCheck()
            return
        }
        rotateProbeFailures += 1
        guard rotateProbeFailures >= 2 else {
            scheduleRotateCheck()
            return
        }
        rotateProbeFailures = 0
        vpnCoreLock.lock()
        let owner = coreOwnerAppInfo
        let link = runningLink
        let running = isRunning
        vpnCoreLock.unlock()
        guard running else {
            scheduleRotateCheck()
            return
        }
        // 3.8.900（L567-1）：同统计路，轮换在后台起核心，跑完再排下一轮；
        // 在途旗子防重叠（见 czfRotateRunning 声明注释）。
        if !czfRotateRunning {
            czfRotateRunning = true
            if let appInfo = owner {
                Task { @MainActor in
                    await self.rotateToNextNode(for: appInfo)
                    self.czfRotateRunning = false
                    self.scheduleRotateCheck()
                }
            } else {
                Task { @MainActor in
                    await self.rotateGlobalNode(from: link)
                    self.czfRotateRunning = false
                    self.scheduleRotateCheck()
                }
            }
        } else {
            scheduleRotateCheck()
        }
    }

    /// 无归属时的全局轮换（3.8.582（VPN-5））：手动起核心没有归属
    /// App，统计路读不到任何 App 的插件统计；探针连续失败时按
    /// 列表顺序切下一个支持协议的节点并重启核心，只改全局活动
    /// 节点，不碰任何钉死。起不来的继续往下一个切，一圈都不通
    /// 就停轮换、写原因（rotateToNextNode 同款）。
    /// 3.8.900（L567-1）：@MainActor async——起核心是同步阻塞的
    /// CGoInvoke，放 detached 跑，不冻主线程；主队列独占的状态
    /// （rotateTriedLinks 等）仍在主 actor 上碰。
    @MainActor
    private func rotateGlobalNode(from currentLink: String?) async {
        vpnCoreLock.lock()
        let stillRunning = isRunning
        let current = runningLink
        // 3.8.900（L569-1）：记下进来的代次——重试前复验用（见循环顶）。
        let czfStopEpochAtEntry = czfManualCoreStopEpoch
        vpnCoreLock.unlock()
        guard stillRunning, current == currentLink, let current else { return }
        let links = nodeLinks
        guard links.count >= 2 else { return }
        rotateTriedLinks = []
        var cursor = current
        var czfFirstAttempt = true
        for _ in 0..<links.count {
            // 3.8.900（L569-1）：重试前复验（同 rotateToNextNode；无归属，
            // 第一轮不验——入口刚验过在跑且是当前链接；之后每轮先验：
            // 上一轮起核失败后核心若还在跑，一定是别人刚起的，收手）。
            if !czfFirstAttempt, czfRetryYielded(stopEpochAtEntry: czfStopEpochAtEntry, for: nil) { return }
            czfFirstAttempt = false
            // 3.8.900（L571-1）：每轮起核前重查测速窗口——轮换是多候选、
            // 每候选一次阻塞式起核的长 Task，上一候选起失败后核心已停，
            // 用户此时点“测延迟”（先停核心再测）会与本轮下一候选起核
            // 撞上：起核成功会让整轮 pingBatch/探针记“核心占用”，
            // 结果全作废。收手：巡检由调用方的 Task 续延重排，不取消、
            // 不写“一圈都不通”（L570-2 同款收手语义）。
            vpnCoreLock.lock()
            let czfPingingNow = isPinging
            vpnCoreLock.unlock()
            if czfPingingNow { return }
            // 3.8.900（L570-2）：每轮起核前重查轮换开关——开关只在排巡检
            // （scheduleRotateCheck）与巡检入口（rotateCheck）查过一次，
            // 一轮轮换要起好几个候选、每候选一次阻塞式起核就是几秒，
            // 探针兜底那路还要先探 5 秒：这几秒到十几秒里用户关掉开关，
            // 轮换照常把节点换掉（关开关只取消已排的 work item，在途的
            // Task 不停）。收手：巡检由调用方的 Task 续延重排，开关关着
            // 时 scheduleRotateCheck 直接不排，不取消、不写“一圈都不通”。
            guard Self.isAutoRotateEnabled else { return }
            guard let target = nextSupportedNode(after: cursor, links: links) else {
                cancelRotateCheck()
                lastError = "节点自动轮换一圈都不通，已停止轮换，手动换节点或检查订阅"
                return
            }
            rotateTriedLinks.insert(cursor)
            rotateTriedLinks.insert(target)
            // 3.8.900（L567-1）：起核心放 detached 跑（:613 注释与
            // runApp 的 vpnCoreTask 同款）；await 不放条件里（607
            // 修法同款），先取结果再判；落笔前复验核心仍跑在刚起
            // 的节点上——await 回来这段时间里别的 App 可能已抢走
            // 核心，这时再写活动下标就是错数。
            let czfStarted = await Task.detached { [weak self] in self?.start(withLink: target) ?? false }.value
            guard czfStarted else {
                cursor = target
                continue
            }
            vpnCoreLock.lock()
            let czfStillOurs = isRunning && runningLink == target
            vpnCoreLock.unlock()
            guard czfStillOurs else { return }
            if let idx = nodeLinks.firstIndex(of: target) {
                UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
            }
            return
        }
        cancelRotateCheck()
        lastError = "节点自动轮换一圈都不通，已停止轮换，手动换节点或检查订阅"
    }

    /// 3.8.900（L569-1）：重试前复验——轮换/就地切/探通后切的重试循环
    /// 在每次重试前调：中途有人亲手停了核心（代次变了）、核心被别的
    /// App 抢走（归属变了）、或核心正跑在无归属的手动核心上时收手，
    /// 不把刚停的核心又起回来、不抢别人刚起的核心。返回 true = 收手。
    /// 只读状态、不改状态；锁只跨三次读，不包起核、不调 main.sync。
    private func czfRetryYielded(stopEpochAtEntry: Int, for appInfo: LCAppInfo?) -> Bool {
        vpnCoreLock.lock()
        let czfEpochNow = czfManualCoreStopEpoch
        let czfOwnerNow = coreOwnerAppInfo
        let czfRunningNow = isRunning
        vpnCoreLock.unlock()
        if czfEpochNow != stopEpochAtEntry { return true }
        if let czfOwnerNow, czfOwnerNow !== appInfo { return true }
        if czfRunningNow && czfOwnerNow == nil { return true }
        return false
    }

    // 按列表顺序切下一个支持协议的节点并重启核心：归属 App
    // 钉死过就改它的 override（轮换后仍钉死在新节点，不回落
    // 全局），跟随全局就改全局活动节点。起不来的节点继续往
    // 下一个切，一圈都起不来就停轮换、写原因，不再无限重启。
    // 启动失败时的就地切节点（ensureRunning 专用）：候选按
    // 新鲜测速从快到慢（与轮换同款排序），跳过刚失败的那条；
    // 成功后按轮换同款改钉死/全局，并接管归属、排轮换检查；
    // 一圈都不通就停，lastError 留最后一次失败原因。
    private func startFallback(from failedLink: String, for appInfo: LCAppInfo?, stopEpochAtEntry: Int) {
        let links = nodeLinks
        guard links.count >= 2 else { return }
        // 3.8.562（L93）：bid 锁外取好传进 start（同 ensureRunning）。
        let czfBid = appInfo.flatMap { Self.czfBundleId(for: $0) }
        let cands = Self.sortedSupportedCandidates(links: links, excluding: [failedLink])
        for cand in cands {
            // 3.8.900（L569-2）：重试前复验（同 L569-1 轮换：上一候选起核
            // 失败后，用户可能已亲手停了核心、或别的 App 刚起核心占住；
            // 不复验就接着起下一个，等于把刚停的核心又起回来、或停掉
            // 别人刚起的核心。收手：App 按既有 fail-open 放行，不写错；
            // 第一轮也验——ensureRunning 那次起核若是被归属守卫拒的
            // （核心正被别的 App 占着），一个候选都不该试）。
            if czfRetryYielded(stopEpochAtEntry: stopEpochAtEntry, for: appInfo) { return }
            // 3.8.900（L571-1）：每轮起核前重查测速窗口（同轮换两路：
            // 上一候选起失败后核心已停，用户此时点“测延迟”会与本轮
            // 下一候选起核撞上，整轮 pingBatch/探针记“核心占用”、
            // 结果全作废；收手：App 按既有 fail-open 放行）。
            vpnCoreLock.lock()
            let czfPingingNow = isPinging
            vpnCoreLock.unlock()
            if czfPingingNow { return }
            if start(withLink: cand.link, ownerBid: czfBid, ownerAppInfo: appInfo) {
                if let appInfo = appInfo, Self.nodeOverride(for: appInfo) != nil {
                    Self.setNodeOverride(cand.link, for: appInfo)
                } else {
                    // 3.8.529（L56）：下标按当前列表现查——cand.idx
                    // 是函数入口快照里的下标，start(withLink:) 同步
                    // 阻塞几秒里用户可能在设置页增删/重排节点（测速
                    // 后补跑的 deferred ensure 那路用户正坐在 VPN
                    // 设置页里），旧下标会指错行、核心跑的节点与界
                    // 面“在用”行对不上（L51-12 在 waitUntilNodeReady
                    // 里修过同款，这里漏了）；链接已不在列表里时不
                    // 写下标，核心照常跑这条链接。
                    if let idx = nodeLinks.firstIndex(of: cand.link) {
                        UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
                    }
                }
                claimCoreOwnershipIfRunning(link: cand.link, for: appInfo)
                return
            }
        }
    }

    // L141-1：轮换目标必须用 rotateCheck 锁下验过的归属 App，
    // 不能在这里无锁重读 coreOwnerAppInfo——两步之间别的 App
    // 可能刚起核心换了归属，重读会拿着旧 App 的死节点统计、
    // 去轮换新 App 的节点（无辜换 IP，养号最忌）；核心停了
    // 也一样会为已关 App 把核心重起起来。入口锁下复验归属
    // 仍是该 App 且核心在跑，否则直接返回（调用方的 Task 续延
    // 照常重排下一轮检查）。两个调用方（rotateCheck 与
    // handleRotateProbeResult）都经 Task { @MainActor in } 调来，
    // 下面 bundleIdentifier() 直读安全。
    // 3.8.900（L567-1）：@MainActor async——起核心是同步阻塞的
    // CGoInvoke，放 detached 跑，不冻主线程；主队列独占的状态
    // 仍在主 actor 上碰；入口复验仍在函数开头做（函数跑在主
    // actor 上，读到的是最新归属）。
    @MainActor
    private func rotateToNextNode(for appInfo: LCAppInfo) async {
        vpnCoreLock.lock()
        let stillOwner = isRunning && coreOwnerAppInfo === appInfo
        // 3.8.900（L569-1）：记下进来的代次——重试前复验用（见循环顶）。
        let czfStopEpochAtEntry = czfManualCoreStopEpoch
        vpnCoreLock.unlock()
        guard stillOwner else { return }
        let links = nodeLinks
        guard links.count >= 2 else { return }
        // 3.8.520（L46）：每轮轮换从空 tried 集开始——上一轮
        // 试过的节点只对上一轮有意义，留到下一轮会把还能用的
        // 节点也排除掉。两节点时必中：上一轮 A→B 成功后
        // tried={A,B}，下一轮再要轮换时 nextSupportedNode 把
        // A、B 全排除、直接判“一圈都不通”并停掉整个轮换巡检
        // （cancelRotateCheck），明明一个节点都没试过；三节点
        // 以上同样会跳过上一轮试过、60 秒冷却后可能已恢复的
        // 节点。循环内照常 insert，本轮内不重复试；成功路的
        // baseline 重置（rotateCheck 里 link 变了即清）仍在，
        // 不动它。
        rotateTriedLinks = []
        var current = effectiveLink(for: appInfo)
        // 3.8.562（L93）：bid 传进 start（主队列上，bundleIdentifier()
        // 直读安全；start 里锁下认领，轮换起完不再留窗口）。
        let czfBid = appInfo.bundleIdentifier()
        for _ in 0..<links.count {
            // 3.8.900（L569-1）：重试前复验——上一轮起核失败后、这一轮
            // 再起之前，用户可能已亲手停了核心（轮换进行中点的“停止
            // 核心”：起核同步阻塞持锁，停核心那下先卡住、等起核失败
            // 才跑，跑完核心已停；不复验就接着起下一个，等于把刚停的
            // 核心又起回来），或别的 App 刚起核心占住了它（本函数每轮
            // 起核前先把归属清 nil，下一轮起核守卫直接放行、会停掉别人
            // 刚起的核心）。收手：巡检由调用方的 Task 续延重排，不取消、
            // 不写“一圈都不通”（节点没死，是让路）；第一轮入口刚验过，
            // 代次与归属都是现取的，复验恒过。
            if czfRetryYielded(stopEpochAtEntry: czfStopEpochAtEntry, for: appInfo) { return }
            // 3.8.900（L571-1）：每轮起核前重查测速窗口（同 rotateGlobalNode：
            // 轮换是多候选、每候选一次阻塞式起核的长 Task，上一候选起失败
            // 后核心已停，用户此时点“测延迟”会与本轮下一候选起核撞上，
            // 整轮 pingBatch/探针记“核心占用”、结果全作废；收手时不取消
            // 巡检、不写“一圈都不通”，调用方的 Task 续延重排）。
            vpnCoreLock.lock()
            let czfPingingNow = isPinging
            vpnCoreLock.unlock()
            if czfPingingNow { return }
            // 3.8.900（L570-2）：每轮起核前重查轮换开关（同 rotateGlobalNode：
            // 开关只在排巡检与巡检入口查过，轮换本身是多候选、每候选一次
            // 阻塞式起核的长 Task，中途关开关不复验就照常换节点；收手时
            // 不取消巡检、不写“一圈都不通”，调用方的 Task 续延重排，
            // 开关关着时 scheduleRotateCheck 直接不排）。
            guard Self.isAutoRotateEnabled else { return }
            guard let target = nextSupportedNode(after: current, links: links) else {
                cancelRotateCheck()
                lastError = "节点自动轮换一圈都不通，已停止轮换，手动换节点或检查订阅"
                return
            }
            rotateTriedLinks.insert(current)
            rotateTriedLinks.insert(target)
            vpnCoreLock.lock()
            coreOwnerBundleId = nil
            vpnCoreLock.unlock()
            // 3.8.900（L567-1）：起核心放 detached 跑（:613 注释与
            // runApp 的 vpnCoreTask 同款）；await 不放条件里（607
            // 修法同款），先取结果再判；落笔前复验核心仍跑在刚起
            // 的节点上——await 回来这段时间里别的 App 可能已抢走
            // 核心，这时再写钉死/活动下标/冷却基线就是错数。
            let czfStarted = await Task.detached { [weak self] in self?.start(withLink: target, ownerBid: czfBid, ownerAppInfo: appInfo) ?? false }.value
            if czfStarted {
                vpnCoreLock.lock()
                let czfStillOurs = isRunning && runningLink == target
                vpnCoreLock.unlock()
                guard czfStillOurs else { return }
                // 3.8.523（L51）：起成功了才把目标节点写进钉死/
                // 全局——原来先写再起，起失败继续试下一个，一圈
                // 都起不来时钉死/全局已指着最后一个起失败的节
                // 点（与 waitUntilNodeReady 探不通还写同款）；
                // 下次启动先上这个死节点，养号钉死也被悄悄换
                // 掉。全失败时钉死仍指着原来那个死节点，与报错
                // 文案“手动换节点”一致。startFallback 本来就是
                // 起成功才写的形状，这里照它。
                if Self.nodeOverride(for: appInfo) != nil {
                    Self.setNodeOverride(target, for: appInfo)
                } else if let idx = nodeLinks.firstIndex(of: target) {
                    // 3.8.535（L62-2）：下标按当前列表现查——上面
                    // links 是函数入口快照，start(withLink:) 同步
                    // 阻塞几秒里列表可能已变：L56 注“整函数在主队
                    // 列 work item 里同步跑完、设置页改不了表”
                    // 只对了设置页那半——设置备份恢复在后台任务
                    // 里直接写 CZFVPNNodeLinks（LCDataManagementView
                    // applySettingsDictionary，注释自认“恢复在后
                    // 台任务里”），旧下标会指错行、还把恢复写回
                    // 的活动下标又盖掉（L56 startFallback 同款，
                    // L51-12 waitUntilNodeReady 同款）；链接已不
                    // 在列表里时不写下标，核心照常跑这条链接。
                    UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
                }
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
    // R-3：键与过期时间只此一份（两页的读写/恢复方法也在本文件
    // 下面，与轮换的 freshPingDelay 共用同一份缓存）。
    static let pingCacheKey = "CZFVPNPingCache"
    static let pingCacheStaleAfter: TimeInterval = 86400

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

    // MARK: - 测速结果持久化（R-3：两页共用同一份 CZFVPNPingCache）
    // 以前这套读写只在 VPN 页（CZFVPNSettingsView 私有方法），
    // App 页测速结果只存内存：VPN 页刚测完的毫秒数，切到 App 页
    // 盾牌菜单里仍显示"未测速"。现在抽到 manager 当静态方法，
    // 两页共用同一缓存、同一编解码；按节点链接内容存，增删别的
    // 节点不影响已有结果，重排后按内容对回新下标。
    // 编码：≥0 = 通的延迟 ms；-1 = 不通；-2 = 超时；-3 = 不支持
    // （转换失败）。新格式每条带时间戳（v = 延迟码，t = 测于何时
    // 的秒时间戳）：超 24 小时的结果算旧。旧格式（直接存 Int）
    // 兼容读，时间戳按 0 计、即直接算旧。键与过期时间见上面
    // freshPingDelay 旁的同一份声明（R-3 合并，不重复声明）。
    static func readPingCache() -> [String: (code: Int, time: TimeInterval)] {
        guard let raw = UserDefaults.standard.dictionary(forKey: pingCacheKey) else { return [:] }
        var out: [String: (code: Int, time: TimeInterval)] = [:]
        for (link, value) in raw {
            if let dict = value as? [String: Any] {
                let code = (dict["v"] as? NSNumber)?.intValue ?? 0
                let time = (dict["t"] as? NSNumber)?.doubleValue ?? 0
                out[link] = (code: code, time: time)
            } else if let num = value as? NSNumber {
                out[link] = (code: num.intValue, time: 0)
            }
        }
        return out
    }

    static func writePingCache(_ cache: [String: (code: Int, time: TimeInterval)]) {
        var out: [String: [String: Any]] = [:]
        for (link, entry) in cache {
            out[link] = ["v": entry.code, "t": entry.time]
        }
        UserDefaults.standard.set(out, forKey: pingCacheKey)
    }

    /// 测速结果落盘编码（与 restorePingResults 的解码对应）：
    /// ≥0 = 通的延迟 ms；-1 = 不通；-2 = 超时；-3 = 不支持。
    static func pingCacheCode(for result: CZFNodePingResult) -> Int {
        result.success ? result.delay : (result.conversionFailed ? -3 : (result.delay == 11000 ? -2 : -1))
    }

    /// 整表落盘：先剪掉已不在列表里的节点，缓存不无限长。
    static func savePingResults(_ results: [Int: CZFNodePingResult], nodes: [String]) {
        var merged = readPingCache().filter { nodes.contains($0.key) }
        let now = Date().timeIntervalSince1970
        for (index, result) in results {
            guard nodes.indices.contains(index) else { continue }
            merged[nodes[index]] = (code: pingCacheCode(for: result), time: now)
        }
        writePingCache(merged)
    }

    /// 单测只写该条缓存：以前单测调全量 savePingResults，
    /// 全表时间戳都被刷成"刚才"，几天前的旧结果杀掉重进后
    /// "·旧"消失、冒充新鲜。整表测速仍走全量（确实全测了）。
    static func savePingResult(link: String, result: CZFNodePingResult, nodes: [String]) {
        var merged = readPingCache().filter { nodes.contains($0.key) }
        merged[link] = (code: pingCacheCode(for: result), time: Date().timeIntervalSince1970)
        writePingCache(merged)
    }

    /// 按节点内容从落盘缓存重建下标结果 + 旧结果下标集。
    static func restorePingResults(nodes: [String]) -> (results: [Int: CZFNodePingResult], stale: Set<Int>, oldestTime: TimeInterval?) {
        let cache = readPingCache()
        var map: [Int: CZFNodePingResult] = [:]
        var stale: Set<Int> = []
        // 新鲜条目里最旧的测量时间（供 App 页“切最快”判断内存数
        // 有没有超 24h；旧条目不计入，免得把新鲜数也算老）。
        var oldestTime: TimeInterval? = nil
        let now = Date().timeIntervalSince1970
        for (index, link) in nodes.enumerated() {
            guard let entry = cache[link] else { continue }
            let v = entry.code
            if v >= 0 {
                map[index] = CZFNodePingResult(success: true, delay: v)
            } else if v == -2 {
                map[index] = CZFNodePingResult(success: false, delay: 11000)
            } else if v == -3 {
                map[index] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
            } else {
                map[index] = CZFNodePingResult(success: false, delay: 10000)
            }
            if entry.time == 0 || now - entry.time > pingCacheStaleAfter {
                stale.insert(index)
            } else if let t = oldestTime {
                oldestTime = min(t, entry.time)
            } else {
                oldestTime = entry.time
            }
        }
        return (map, stale, oldestTime)
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
            // 3.8.587（L119）：核心没在跑就什么都不做、不清快照——
            // 快照是谁停核心谁的：另一轮测速的 stopCoreForPing 没
            // 停过核心，却把上一轮停核心那轮的快照清掉，上一轮
            // 测完 restartCoreAfterPing 读到 nil 就不重启，核心
            // 悄悄一直停着（两轮重叠：App 页与设置页各有自己的
            // 测速标志，pingGeneration 注释已认两轮可并发；本页
            // 与设置页的 guard 只拦各自页内重入，拦不住跨页）。
            // 快照由 restartCoreAfterPing 读完即清；亲手停核心
            // （noteManualCoreToggle，L221）与删在用节点（removeNode，
            // L127）也会清——那两路本意就是停核心，restart 不再起；
            // 收尾跟随在核心已在跑时也会清（restart 没必要）。
            // 四处调用方都在 completion 里按 pingStoppedCore 配对调它，
            // pingAllNodes/pingSingleNode 一定调 completion，
            // 不留陈旧快照。
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
        // 3.8.554（L227）：另一轮测速还在跑时别消费快照——快照
        // 读完即清，但 ensureRunning 会因 isPinging 拒绝起核心，
        // 快照丢了就没人再起，核心悄悄一直停着（跨页两轮重叠：
        // 停核心那轮先完、另一轮还在探；后完那轮的 pingStoppedCore
        // 是 false，不会再调这里）。留给最新一轮收尾消费（ping
        // 尾 isLatestPing 分支里调这里补起）。
        guard !isPinging else {
            vpnCoreLock.unlock()
            return
        }
        let hadSnapshot = pingStoppedLink != nil
        let czfSnapshotLink = pingStoppedLink
        var owner = pingStoppedOwner
        pingStoppedLink = nil
        pingStoppedOwner = nil
        // 3.8.592（L125）：收尾把 isPinging 置 false 后、这里跑
        // 起来之前点的切换——setActiveNode 在快照还在时也记了
        // 标志（见 setActiveNode），归属清掉、按当前 effectiveLink
        // 起在新节点上；没换过节点时一字不动。目标永远是用户最
        // 新选择，即使标志是旧轮残留的也不会起错节点。
        if czfNodeSwitchDuringPing {
            czfNodeSwitchDuringPing = false
            owner = nil
        }
        vpnCoreLock.unlock()
        guard hadSnapshot else { return }
        // 3.8.558（L241）：快照只用来判断“测速停过核心”，不再
        // 比对目标链接——收尾跟随（czfFollowPostPingNodeSwitch）
        // 只处理全局活动链接的变化；归属 App 的专属节点在测速
        // 窗口内被改了（App 设置页 pin 节点，setNodeOverride 只
        // 写 UserDefaults、不动核心、无跟随），旧守卫拿新目标比
        // 旧快照、直接拦掉重启，测速前还在跑的核心测完一直停着，
        // 预热抑制也已置真，只能亲手再起（L127 同款）。ensureRunning
        // 自己按当前 effectiveLink 取，旧链接本来就起不回来；
        // 亲手停核心（noteManualCoreToggle）与删在用节点（removeNode）
        // 已在快照为 nil 时早退，拦重启的口子不在这里。
        // 3.8.900（L570-1）：重启不是 App 启动，不取消待执行的自动停、
        // 不重置闲置计时（见 ensureRunning 的 czfKeepAutoStop 注释）。
        ensureRunning(for: owner, czfKeepAutoStop: true)
        // 重启成功后清掉测速收尾置的预热抑制：收尾时核心
        // 是停的（抑制置真），现在核心又在跑了，抑制前提
        // 已不存在；重启失败则留着，不让预热去起刚起不来
        // 的核心。归属 App 的重启已由 ensureRunning 清过，
        // 这里只补全局（owner 为 nil）那一路。isRunning 与
        // 清抑制同一把锁下读改，与测速收尾的读法一致。
        vpnCoreLock.lock()
        // 3.8.900（L575-1）：重启撞上新一轮测速时别丢快照——上面守卫
        // 通过后、ensureRunning 起核前，另一页点了“测延迟”，新窗口
        // 已立、start(withLink:) 里的测速守卫会拒掉这次起核；快照已
        // 被上面清掉的话，新一轮收尾的 restart 读不到快照、测速前在
        // 跑的核心一直停着。起核被测速挡下时把快照还回去，留给新一
        // 轮收尾重试（L227 同款“留给最新一轮”）；起核是别的原因失败
        // （节点本身起不来）时不还，快照已消费、行为与原来一致。
        if !isRunning && isPinging {
            pingStoppedLink = czfSnapshotLink
            pingStoppedOwner = owner
        }
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
        // 代次在调用线程同步取：后台块里再 +1 的话，两轮
        // 几乎同时进时先后不定，先完的轮次可能误认最新。
        vpnCoreLock.lock()
        isPinging = true
        pingGeneration += 1
        let generation = pingGeneration
        vpnCoreLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            // 抓状态必须和 start/stop 同一把锁：否则抓到的
            // 核心在跑/活动链接可能是另一路 stop/start
            // 做到一半的中间态，收尾判断就按错状态走。
            // 抓完立刻放锁——锁不包整段测速（见字段注释）。
            self.vpnCoreLock.lock()
            self.isPinging = true
            self.pingRetryLink = nil
            let epochAtPingStart = self.coreActionEpoch
            let coreRunningAtStart = self.isRunning
            let prePingActiveLink = self.nodeLink
            self.vpnCoreLock.unlock()
            var conversionCache: [String: String] = [:]
            var singBoxOutboundCache: [String: [String: Any]] = [:]  // 3.8.603（O-11）：sing-box 出站解析缓存，与 conversionCache 同款轮内复用
            var outcome = self.runPingBatches(links: links, url: "https://cp.cloudflare.com/", phase: "测速", onProgress: onProgress, conversionCache: &conversionCache, singBoxOutboundCache: &singBoxOutboundCache)
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
                    let retry = self.runPingBatches(links: failedLinks, url: retryURL, phase: "重试", onProgress: onProgress, conversionCache: &conversionCache, singBoxOutboundCache: &singBoxOutboundCache)
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
            var deferredApps: [LCAppInfo] = []
            var deferredHost = false
            var postPingActiveLink = prePingActiveLink
            var nodeSwitched = false
            self.vpnCoreLock.lock()
            // 并发测速收尾：只有最新一轮才清标志、记预热抑制、
            // 取走被挡请求；先完的旧轮只回自己的 completion，
            // 不碰共享收尾状态——否则它会把核心起回来，让还在
            // 跑的新轮探针撞上“核心占用”，还会提前放开 isPinging。
            let isLatestPing = (generation == self.pingGeneration)
            let epochChanged = self.coreActionEpoch != epochAtPingStart
            if isLatestPing {
                if !epochChanged {
                    self.prewarmSuppressedAfterPing = !self.isRunning
                } else {
                    self.pingRetryLink = nil
                }
                postPingActiveLink = self.nodeLink
                deferredApps = self.deferredEnsureApps
                self.deferredEnsureApps = []
                deferredHost = self.deferredHostEnsure
                self.deferredHostEnsure = false
                nodeSwitched = self.czfNodeSwitchDuringPing
                // 链接没变时不清除：窗口内点的切换可能在收尾与
                // restart 之间才发生，留给 restartCoreAfterPing
                // 消费；变了就由跟随分支消费。
                if postPingActiveLink != prePingActiveLink {
                    self.czfNodeSwitchDuringPing = false
                }
                self.isPinging = false
            }
            self.vpnCoreLock.unlock()
            if !deferredApps.isEmpty {
                for app in deferredApps {
                    self.ensureRunning(for: app)
                }
                // 显式切换在补跑后再切一次（窗外亲手切节点同款：
                // start() 清归属）；列表变动（订阅刷新/改链接/
                // 清理）只在补跑没把核心跑起来时跟随——改写快照
                // 让 restart 按新活动链接起，跑起来了就不动补跑
                // 刚起的核心。
                if postPingActiveLink != prePingActiveLink {
                    self.vpnCoreLock.lock()
                    let czfReplayStartedCore = self.isRunning
                    self.vpnCoreLock.unlock()
                    if nodeSwitched || !czfReplayStartedCore {
                        self.czfFollowPostPingNodeSwitch(postPingActiveLink: postPingActiveLink, nodeSwitched: nodeSwitched)
                    }
                }
            } else if postPingActiveLink != prePingActiveLink {
                self.czfFollowPostPingNodeSwitch(postPingActiveLink: postPingActiveLink, nodeSwitched: nodeSwitched)
            }
            if deferredHost {
                self.ensureRunningForHost()
            }
            self.vpnCoreLock.lock()
            let coreRunningAtEnd = self.isRunning
            self.vpnCoreLock.unlock()
            let finalRejected = (coreRunningAtStart || coreRunningAtEnd) && outcome.batchRejected
            let items = outcome.items
            // 3.8.554（L227）：最新一轮收尾时把遗留快照消费掉——
            // 停核心那轮先完时它的 completion 调 restartCoreAfterPing
            // 被上面守卫拦下（快照没动）；本轮是最后一轮，isPinging
            // 已清，在这里补起原来那条。放 completion 之前、deferred
            // 补跑之后（补跑的 App 先占核心，restart 再按快照守卫
            // 退让，与 completion 里调的顺序一致）；finalRejected
            // 已按探针时状态算好，不受这次重启影响。
            if isLatestPing {
                self.restartCoreAfterPing()
            }
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
        // 代次在调用线程同步取（同 pingAllNodes，防两轮并发时
        // 先完的轮次误认最新）。
        vpnCoreLock.lock()
        isPinging = true
        pingGeneration += 1
        let generation = pingGeneration
        vpnCoreLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.vpnCoreLock.lock()
            self.isPinging = true
            self.pingRetryLink = nil
            let epochAtPingStart = self.coreActionEpoch
            let coreRunningAtStart = self.isRunning
            let prePingActiveLink = self.nodeLink
            self.vpnCoreLock.unlock()
            var conversionCache: [String: String] = [:]
            var singBoxOutboundCache: [String: [String: Any]] = [:]  // 3.8.603（O-11）：sing-box 出站解析缓存，与 conversionCache 同款轮内复用
            var outcome = self.runPingBatches(links: [link], url: "https://cp.cloudflare.com/", phase: "测速", onProgress: nil, conversionCache: &conversionCache, singBoxOutboundCache: &singBoxOutboundCache)
            let pingRejected = coreRunningAtStart && outcome.batchRejected
            if !pingRejected {
                var failed = outcome.items.first?.success == true ? [] : [0]
                for retryURL in ["https://www.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"] {
                    if failed.isEmpty { break }
                    let retry = self.runPingBatches(links: [link], url: retryURL, phase: "重试", onProgress: nil, conversionCache: &conversionCache, singBoxOutboundCache: &singBoxOutboundCache)
                    if retry.items.first?.success == true {
                        outcome.items[0] = retry.items[0]
                        failed = []
                    }
                }
            }
            var deferredApps: [LCAppInfo] = []
            var deferredHost = false
            var postPingActiveLink = prePingActiveLink
            var nodeSwitched = false
            self.vpnCoreLock.lock()
            // 并发测速收尾（同 pingAllNodes）：只有最新一轮才
            // 清标志、记预热抑制、取走被挡请求。
            let isLatestPing = (generation == self.pingGeneration)
            let epochChanged = self.coreActionEpoch != epochAtPingStart
            if isLatestPing {
                if !epochChanged {
                    self.prewarmSuppressedAfterPing = !self.isRunning
                } else {
                    self.pingRetryLink = nil
                }
                postPingActiveLink = self.nodeLink
                deferredApps = self.deferredEnsureApps
                self.deferredEnsureApps = []
                deferredHost = self.deferredHostEnsure
                self.deferredHostEnsure = false
                nodeSwitched = self.czfNodeSwitchDuringPing
                // 链接没变时不清除：窗口内点的切换可能在收尾与
                // restart 之间才发生，留给 restartCoreAfterPing
                // 消费；变了就由跟随分支消费。
                if postPingActiveLink != prePingActiveLink {
                    self.czfNodeSwitchDuringPing = false
                }
                self.isPinging = false
            }
            self.vpnCoreLock.unlock()
            if !deferredApps.isEmpty {
                for app in deferredApps {
                    self.ensureRunning(for: app)
                }
                // 显式切换在补跑后再切一次（窗外亲手切节点同款：
                // start() 清归属）；列表变动（订阅刷新/改链接/
                // 清理）只在补跑没把核心跑起来时跟随——改写快照
                // 让 restart 按新活动链接起，跑起来了就不动补跑
                // 刚起的核心。
                if postPingActiveLink != prePingActiveLink {
                    self.vpnCoreLock.lock()
                    let czfReplayStartedCore = self.isRunning
                    self.vpnCoreLock.unlock()
                    if nodeSwitched || !czfReplayStartedCore {
                        self.czfFollowPostPingNodeSwitch(postPingActiveLink: postPingActiveLink, nodeSwitched: nodeSwitched)
                    }
                }
            } else if postPingActiveLink != prePingActiveLink {
                self.czfFollowPostPingNodeSwitch(postPingActiveLink: postPingActiveLink, nodeSwitched: nodeSwitched)
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
            // 3.8.554（L227）：最新一轮收尾时把遗留快照消费掉（同
            // pingAllNodes 尾部：停核心那轮先完时 restart 被守卫拦
            // 下，快照留给本轮补起）。
            if isLatestPing {
                self.restartCoreAfterPing()
            }
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
    /// singBoxOutboundCache 同款（3.8.603（O-11））：sing-box
    /// 出站解析结果，key 为归一化链接，value 为出站字典——
    /// 校验步解析一次，探针拼配置时复用，不再每轮重解析
    /// （原来校验调 configJSON 生成整份配置再丢掉，探针又
    /// 对同一批链接生成第二份，失败节点一轮内解析两次、
    /// 三轮六次）。
    private func runPingBatches(links: [String], url: String, phase: String = "", onProgress: ((Int, Int, String) -> Void)? = nil, conversionCache: inout [String: String], singBoxOutboundCache: inout [String: [String: Any]]) -> (items: [CZFNodePingResult], batchRejected: Bool) {
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
                // 3.8.603（O-11）：校验即解析——原来调 configJSON(for: link) 生成整份
                // 配置再丢掉（每轮每节点一次）；现在只解析出站字典进轮内缓存，校验与
                // 探针共用一份，不再二次解析。校验结果与原来相同（configJSON 里唯一
                // 可能抛错的步骤就是 outbound(for:)）。
                let normalized = Self.normalizedShareLink(link)
                if singBoxOutboundCache[normalized] == nil {
                    guard let outbound = try? CZFSingBoxConfig.outbound(for: link) else {
                        items[i] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
                        continue
                    }
                    singBoxOutboundCache[normalized] = outbound
                }
                singBoxPending.append((i, link))
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
                if let results = probeSingBoxNodes(links: singBoxPending.map { $0.link }, host: probeHost, singBoxOutboundCache: singBoxOutboundCache) {
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
    private func probeSingBoxNodes(links: [String], host: String, singBoxOutboundCache: [String: [String: Any]]) -> [CZFNodePingResult]? {
        vpnCoreLock.lock()
        // 主核心在跑，或上个临时实例泄漏未停（崩溃才可能），
        // 都算占用：不与任何已跑实例同进程起第二个。
        let occupied = isRunning || CZFSingBoxCore.isServiceRunning
        vpnCoreLock.unlock()
        if occupied { return nil }
        let config: String
        do {
            // 3.8.603（O-11）：出站已在校验步解析进缓存，这里只换 tag
            // （tag 只在出站字典顶层，见 tuicOutbound/hysteria2Outbound）
            // 再拼配置，不再每轮重解析；缓存未命中时（不应发生）退回
            // 直接解析，行为与原来相同。
            var outbounds: [[String: Any]] = []
            for (i, link) in links.enumerated() {
                let normalized = Self.normalizedShareLink(link)
                if var cached = singBoxOutboundCache[normalized] {
                    cached["tag"] = "node-out-\(i)"
                    outbounds.append(cached)
                } else {
                    outbounds.append(try CZFSingBoxConfig.outbound(for: link, tag: "node-out-\(i)"))
                }
            }
            config = try CZFSingBoxConfig.configJSON(forOutbounds: outbounds, basePort: 10927)
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
            // 3.8.582（VPN-3）：批量 CheckConfig 失败不能整批记 11000——
            // 一个坏出站会让全部好节点也被“清理不通”删掉（清理删
            // !success && !conversionFailed 的节点）。逐个起临时实例
            // 校验：起得来的当场单测出真实延迟，起不来的标
            // conversionFailed（“不支持”，清理不删）。
            return validateSingBoxLinksIndividually(links: links, host: host)
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

    /// 批量 CheckConfig 失败后的逐个校验（3.8.582（VPN-3），见上面
    /// probeSingBoxNodes 的 catch）：每个链接单独建配置、单独起
    /// 临时实例、单独探一次。起不来的（转换失败或 CheckConfig/
    /// 启动失败）标 conversionFailed（“不支持”，清理不删）；起
    /// 得来的给真实单测结果。校验中途主核心抢占时立刻停手、余下
    /// 未验的按 conversionFailed 保底——宁可不删，不可误删。
    /// 只在批量起失败的罕见路跑；逐个起实例比批量慢，测速本身
    /// 在后台队列，不冻界面。锁纪律与批量路同款：只锁“检查+起
    /// 实例”这一下，探针本身不持锁；起着时主核心的 start(withLink:)
    /// 读到 isServiceRunning 为真会拒绝，不会抢走实例。
    private func validateSingBoxLinksIndividually(links: [String], host: String) -> [CZFNodePingResult] {
        var results = [CZFNodePingResult?](repeating: nil, count: links.count)
        for i in links.indices {
            // 主核心抢占检查：锁下看占用，被占就停手
            vpnCoreLock.lock()
            let occupied = isRunning || CZFSingBoxCore.isServiceRunning
            vpnCoreLock.unlock()
            guard !occupied else {
                for j in links.indices where results[j] == nil {
                    results[j] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
                }
                break
            }
            let link = links[i]
            let singleConfig: String
            do {
                singleConfig = try CZFSingBoxConfig.configJSON(for: link, socksPort: 10927, httpPort: nil)
            } catch {
                results[i] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
                continue
            }
            // 锁下起实例，起完再放锁
            vpnCoreLock.lock()
            if isRunning || CZFSingBoxCore.isServiceRunning {
                vpnCoreLock.unlock()
                for j in links.indices where results[j] == nil {
                    results[j] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
                }
                break
            }
            do {
                try CZFSingBoxCore.start(configJSON: singleConfig)
            } catch {
                vpnCoreLock.unlock()
                results[i] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
                continue
            }
            vpnCoreLock.unlock()
            // defer 在循环体内：每次迭代结束即停掉本次实例，
            // 不留到下个链接（下个链接起实例前必须停干净）。
            defer { try? CZFSingBoxCore.stop() }
            let probe = CZFSingBoxProbe.probe(port: 10927, host: host, timeout: 5)
            if probe.success {
                results[i] = CZFNodePingResult(success: true, delay: probe.delayMs)
            } else if probe.rejected {
                results[i] = CZFNodePingResult(success: false, delay: 10000)
            } else {
                results[i] = CZFNodePingResult(success: false, delay: 11000)
            }
        }
        return results.map { $0 ?? CZFNodePingResult(success: false, delay: 10000, conversionFailed: true) }
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
        // L137-1：值不能走 .urlQueryAllowed——它不编 &，WS 路径里
        // 的 &（如 /x?a=1&b=2）会把重建后的链接从 & 处切断，转换
        // 器读到的 path 被截断、后面多出幻影参数，节点连不上或
        // 走错路；L60 同款，改走 czfQueryValueAllowed（排除 &）。
        result += out.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .czfQueryValueAllowed) ?? $0.1)" }
            .joined(separator: "&")
        if let name = query["remarks"], !name.isEmpty {
            result += "#" + (name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name)
        } else if let hashIdx = link.firstIndex(of: "#") {
            // 老格式链接的名字一般在 # 片段里（remarks 参数反而少见）：
            // 原来这里直接丢了，节点名退化成 地址:端口。原样保留。
            result += String(link[hashIdx...])
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
        set {
            UserDefaults.standard.set(newValue, forKey: "CZFVPNHostProxyEnabled")
            // L143-1：配置变了就刷设置备份（见 refreshSettingsBackup）。
            shared.refreshSettingsBackup()
        }
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

    // 3.8.547（L181）：取会变的内容必须绕开 URLCache——hostSession()
    // 的两路会话（.shared 与 proxiedHostSession）都是
    // URLSessionConfiguration.default，requestCachePolicy 默认
    // .useProtocolCachePolicy、urlCache 默认共享缓存；源站
    // （GitHub Pages / raw 常见 max-age 300–600 秒）回了
    // Cache-Control 后，max-age 内刷新直接拿缓存字节、不走网，
    // 用户明明点了刷新、新版也上架了，源页还是旧数据，直到
    // max-age 过期才出现；L147-1 的短路还把这份缓存字节当成
    // “数据没变”直接跳过。离线时照旧走 catch（旧内容保留 +
    // 报错），不改离线行为；代理行为走 hostSession() 原样。
    public static func freshData(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await hostSession().data(for: request)
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
        // 3.8.900（L567-2）：同 ensureRunning，cancel 与置 nil
        // 在同一把锁下（本函数也可能被后台任务调）。
        vpnCoreLock.lock()
        pendingStopWork?.cancel()
        pendingStopWork = nil
        vpnCoreLock.unlock()
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
    /// 3.8.900（L568-1）：统计文件地址——proxyStatsDict 与新鲜度检查
    /// 共用同一算法（文件夹取法/包名分文件一字不动，只是抽出来）。
    private static func czfProxyStatsURL(for appInfo: LCAppInfo) -> URL? {
        let czfFolders = LCAppModel.czfSplitTweakFolders(appInfo.tweakFolder)
        guard let folderName = czfFolders.first(where: { $0 == "CZFVPN" }) ?? czfFolders.first ?? (isEnabled(for: appInfo) ? "CZFVPN" : nil) else { return nil }
        let base = appInfo.isShared ? LCPath.lcGroupTweakPath : LCPath.tweakPath
        let folder = base.appendingPathComponent(folderName)
        // 统计按 App 分文件（插件按包名命名）；按包名文件没有就不显示，
        // 不再退读老版共用文件——那是各 App 混在一起的老数，显示成当前
        // App 的就是错数
        let bid = appInfo.bundleIdentifier() ?? ""
        return folder.appendingPathComponent("CZFProxyStats-\(bid).txt")
    }

    /// 3.8.900（L568-1）：统计文件 90 秒内写过才算新鲜——插件只在
    /// 有网络动作时写统计（节流 1.5 秒，见 CZFProxy.m 的
    /// CZFWriteStats 调用点）；90 秒（三个巡检周期）一个字节没写，
    /// 客进程要么已死、要么已挂起、要么一直没流量，文件里的数不
    /// 是活证据，不能拿它拦轮换。只给 rotateCheck 用，设置页的
    /// 统计显示一字不动（陈旧数照常显示，只是不再当轮换判据）。
    private static func czfProxyStatsFresh(for appInfo: LCAppInfo) -> Bool {
        guard let url = czfProxyStatsURL(for: appInfo),
              let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(mtime) < 90
    }

    private static func proxyStatsDict(for appInfo: LCAppInfo) -> [String: String]? {
        guard let url = czfProxyStatsURL(for: appInfo) else { return nil }
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
