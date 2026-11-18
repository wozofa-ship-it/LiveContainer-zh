//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

// 3.8.428 安装#2：安装取消专用信号——取消（替换选择框点取消、
// 多开输名点取消、隐藏认证被拒、覆盖运行中 App 时用户点取消、
// 预览点取消、下载被取消、进度条旁点取消）不再走 return/返回
// false 被批量计为成功；取消路径一律抛它，installFromUrl 侧
// 单独 catch 记“已取消”，不计成功也不计失败。
struct CZFInstallCancelled: Error {}

// 3.8.428 安装#6：一次性标志（线程安全）——continuation 只能
// resume 一次，正常完成与超时互斥用；timedOut 标明是哪边赢了。
final class CZFOnceFlag: @unchecked Sendable {
    private var done = false
    private(set) var timedOut = false
    // O-9：签名等待取消分支——取消轮询抢到 resume 时置 true（与 timedOut
    // 互斥），调用方据此抛 CZFInstallCancelled，而不是走签名失败路径。
    private(set) var cancelled = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
    func claimTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        timedOut = true
        return true
    }
    func claimCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        cancelled = true
        return true
    }
}

// 待安装队列项：url 安装与 plist 安装共用一个队（cases 与
// urlStr 原样保留，供 pendingInstalls 去重用）。
// 3.8.428 设置#25：跨页待装队列不在这里——原来挂的 static
// urls: [URL] 只存地址，三处来源的 autoReplace / preview /
// forceAsNew 全丢了（批量丢 autoReplace、单装丢 preview、
// 新建丢 preview + forceAsNew），已移到下面的
// CZFSourcePendingInstall（四字段齐全），urls 已删。
private enum CZFPendingInstall {
    // url：地址、autoReplace、preview、forceAsNew、预设自定义名
    //（恢复缺失的多开实例时带，nil = 不预设）。
    case url(String, Bool, Bool, Bool, String?)
    case plist(String)
    var urlStr: String {
        switch self {
        case .url(let s, _, _, _, _): return s
        case .plist(let s): return s
        }
    }
}

// 源页待装队列（3.8.428，设置审计 #25）：源页安装请求先写这里、
// App 页出现时排空进安装队列，不再只靠 0.5 秒延迟通知（App 页
// 没出现时通知静默丢失）。名字与上面的 CZFPendingInstall
// 区分开，不重名、不复用；类型与静态数组都是模块可见
//（不加 private），源页文件直接写。字段与安装队列元组同款：
// (url, autoReplace, preview, forceAsNew)，三处来源各取所需——
// 批量 autoReplace:true、单装 preview:true、新建 preview +
// forceAsNew:true。
struct CZFSourcePendingInstallItem {
    let url: URL
    let autoReplace: Bool
    let preview: Bool
    let forceAsNew: Bool
}

enum CZFSourcePendingInstall {
    static var items: [CZFSourcePendingInstallItem] = []
    // 同一请求重复点/批量与单点重叠时只留一份：四字段全同才
    // 算重复；排空后列表清空，后续再点可重新进队，不影响多开。
    static func append(_ item: CZFSourcePendingInstallItem) {
        guard !items.contains(where: { $0.url == item.url && $0.autoReplace == item.autoReplace && $0.preview == item.preview && $0.forceAsNew == item.forceAsNew }) else { return }
        items.append(item)
        // 3.8.508（L30）：App 页已在前台时只靠 onAppear 排空会
        // 漏——批量更新循环里 dylib 的 await 让出主线程后 App 页
        // 已出现并排空过一次，之后再入队的就一直躺在这里（无报
        // 错、无进度，直到下次进 App 页）。入队即发通知，在前
        // 台的 App 页当场排空；不在前台时没人收，等 onAppear 排空。
        NotificationCenter.default.post(name: NSNotification.CZFSourcePendingInstallAppended, object: nil)
    }
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    // 本地 IPA 文件夹已移到源页（3.8.454）：保存/恢复见
    // CZFLocalIpaFolderStore；安装时取权（3.8.428 安装#3）
    // 仍调它。App 页不再有文件夹按钮/内嵌区/sheet。
    @State var errorShow = false
    @State var errorInfo = ""
    // 新装 App 后自动恢复备份的结果提示
    @State var installInfoShow = false
    @State var installInfo = ""
    // 安装请求队列（源页批量安装用）：串行下+装，已装的直接覆盖
    // App #8：队列项带稳定 id——原来是无 id 元组，删行按
    // url + autoReplace 找第一个匹配，有重复项时删的是另一行。
    @State var installQueue: [(id: UUID, url: URL, autoReplace: Bool, preview: Bool, forceAsNew: Bool, customDisplayName: String?)] = []
    // 安装前预览（源里单个安装时，下完先弹信息卡确认再装）
    @State var installPreviewShow = false
    @State var installPreviewText = ""
    @State var installPreviewContinuation: CheckedContinuation<Bool, Never>? = nil
    @State var installQueueRunning = false
    // O-9：正在装的那一项（已出队、不在 installQueue 里）：去重键与
    // installQueue / pendingInstalls 共用 (url, autoReplace, preview,
    // forceAsNew, customDisplayName)，enqueueInstall 入队时三处一起查——只查队里会漏掉
    // 已出队正在装的项，同一请求正在装时再点会重复进队。
    @State private var czfInFlightInstall: (url: URL, autoReplace: Bool, preview: Bool, forceAsNew: Bool, customDisplayName: String?)?
    // 3.8.428 安装#6：进度条旁取消按钮置的取消标志——队列轮询
    // 到它时跳过当前项、继续下一项；installFromUrl 入口与解包
    // 前检查点也会取走它（见 czfTakeInstallCancel）。
    @State private var czfInstallCancelRequested = false
    // 3.8.428 安装#2：最近一次 installFromUrl 是否以“取消”结束
    //（抛 CZFInstallCancelled / 下载被取消 / 预览点取消或超时），
    // 供 enqueueInstall 单独计取消数；由 enqueueInstall 在每次
    // 调用前清 false、调用后读，取消路径才置 true。
    @State private var czfLastInstallWasCancelled = false
    // 队列进度（App 页顶部小条显示用）
    @State var installQueueTotal = 0
    @State var installQueueDone = 0
    @State var installQueueCurrent = ""
    // 点顶部小条打开的队列名单（可删单个、可取消剩余）
    @State var queueSheetShow = false
    
    // ipa installing stuff
    @State var installprogressVisible = false
    // 安装排队：进行中再点安装不再静默丢掉，排进队、当前装完
    // 接着装（defer 里出队一个）；同地址重复点只排一次
    @State private var pendingInstalls: [CZFPendingInstall] = []
    // 3.8.527（L54）：startInstallApp 忙时排队进来的 asCopy
    // 临时副本地址（absoluteString）。排空走 installFromUrl
    // 的 file 分支不删它（只删 Inbox / LCWebDownload-），drain
    // 里装完（或起跑即取消）后按这张表删，免得 tmp 漏一个 IPA。
    // static：排队与排空之间视图可能重建，实例 @State 靠不住。
    private static var czfFileImporterTmpToDelete: Set<String> = []
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    // 多开安装时输新名字（分清两个同款 App 用）
    @StateObject private var installAsNewNameInput = InputHelper()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()

    // 3.8.428 安装#9：覆盖运行中 App 前的确认框——被替换的 App
    // 在运行时先请用户退出，确认继续才装；取消=放弃这次安装。
    @StateObject private var czfRunningAppConfirm = YesNoHelper()
    @State private var czfRunningAppName = ""
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false

    // 新1（3.8.277）：排序方案管理页。
    @State private var sortSchemesViewPresent = false

    // 新4（3.8.277）：批量操作。多选只针对主列表（可见 App），
    // 隐藏区 App 不参与（已隐藏的再“隐藏”无意义，备份/删除
    // 走数据管理页）。选中集存唯一 ID，不存下标——搜索过滤
    // 与排序变化都不会串选。
    @State private var batchMode = false
    // 顶栏三个工具（数据管理/VPN/多选）收起/展开：默认收起，点
    // 箭头展开、再点收起；只管显隐，三个功能本身不动。
    @State private var topToolsExpanded = false
    // 3.8.281：顶部 VPN 开关用的核心运行状态（CZFVPNManager 不是
    // ObservableObject，本地 @State 存一份，进页/点按后从
    // shared.isRunning 刷新，与设置页同款读法）。
    @State private var vpnCoreRunning = false
    // 3.8.282：顶部盾牌长按菜单用的测速状态（只读测速，
    // 核心在跑时可能被拒，见 toolbarPingNodes 的 rejected 处理）
    @State private var vpnPinging = false
    @State private var vpnPingResults: [Int: CZFVPNManager.CZFNodePingResult] = [:]
    // L58-2：内存测速结果属于哪个节点列表的快照（VPN 页 L43-2
    // 同款）——结果按下标记存，设置页增删/重排节点后下标就过期；
    // 下面 czfRestorePingResultsFromCache / switchToFastestNode
    // 按快照校验，toolbarPingNodes 按内容换算下标。
    @State private var vpnPingResultNodes: [String] = []
    // 内存测速结果的测量时间（恢复时取缓存里新鲜条目最旧的时间，
    // 现测时取当时）：切最快只认 24h 内的内存数，超了现场重测。
    @State private var vpnPingResultsFetchedAt: Date?
    @State private var vpnPingMessage: String?
    @State private var batchSelectedIDs: Set<String> = []
    @State private var batchDeleteConfirm = false
    // 3.8.302：批量备份范围单开关——App 页多选备份原来点“备份”
    // 就直接跑完整备份、从不问范围（用户 300 真机报“只显示备份
    // 成功，没显示登录态还是完整备份”）；点备份先弹范围单，
    // 选了范围再跑，结果里也写明范围。
    @State private var batchBackupScopeConfirm = false
    // 批量恢复范围单开关（同款：先弹范围单再跑）。
    @State private var batchRestoreScopeConfirm = false
    @State private var batchBusy = false
    // 每行备份状态：实例唯一 ID → “已备份 · 日期”/“无备份”，
    // 进页时一次扫完 Backups 目录算好，行上只查表不扫盘；
    // 批量备份/恢复跑完后刷新。
    @State private var backupStatusByID: [String: String] = [:]

    private var selectedBatchApps: [LCAppModel] {
        // 3.8.281：隐藏 App 也进批量勾选范围（原来只看可见 App，
        // 隐藏区行就算有了勾选圈、勾了也没用——批量备份/删除都
        // 拿不到它们；恢复备份本身不拦隐藏 App，拦的是这里）。
        (sharedModel.apps + sharedModel.hiddenApps).filter { app in
            batchSelectedIDs.contains(czfBatchKey(for: app))
        }
    }

    // 3.8.281：勾中的 App 是不是全是隐藏的（底栏“隐藏/恢复显示”
    // 按钮换 label 用；空选时 false，按钮反正禁用）。
    private var batchSelectionAllHidden: Bool {
        !selectedBatchApps.isEmpty && selectedBatchApps.allSatisfy { $0.appInfo.isHidden }
    }

    // 3.8.428 设置#31：批量勾选键——getUniqueIdentifier 在
    // bundleIdentifier 或 relativeBundlePath 为 nil 时返回 nil，
    // 原来 isBatchSelected/toggle 直接 guard-return，格子仍显示
    // 空心勾选圈、点它静默无反应；取不到唯一 ID 时用对象身份
    // 兜底，保证每个格子都有可用的勾选键（同一实例在会话内稳定；
    // 批量相关的五处读写全走这个键，别处（备份表/拖拽/启动偏好）
    // 的键不动，各用各的）。
    private func czfBatchKey(for app: LCAppModel) -> String {
        if let id = sharedAppSortManager.getUniqueIdentifier(for: app) {
            return id
        }
        return "czf-obj-\(ObjectIdentifier(app))"
    }

    private func isBatchSelected(_ app: LCAppModel) -> Bool {
        batchSelectedIDs.contains(czfBatchKey(for: app))
    }

    private func toggleBatchSelection(_ app: LCAppModel) {
        let id = czfBatchKey(for: app)
        if batchSelectedIDs.contains(id) {
            batchSelectedIDs.remove(id)
        } else {
            batchSelectedIDs.insert(id)
        }
    }

    // 全选用的当前列表：可见 App + 已解锁的隐藏 App（搜
    // 索时只含搜到的）；“全选”只勾这些。“取消全选”清掉
    // 全部已选项（App #12：原来只清当前列表的，搜索时
    // 看不见的已选项还留在批量里，接着点删除会删掉屏幕
    // 上看不见的 App）。
    private var batchCurrentList: [LCAppModel] {
        filteredApps + (sharedModel.isHiddenAppUnlocked ? filteredHiddenApps : [])
    }
    private var batchAllSelected: Bool {
        !batchCurrentList.isEmpty && batchCurrentList.allSatisfy { app in
            batchSelectedIDs.contains(czfBatchKey(for: app))
        }
    }
    private func toggleBatchSelectAll() {
        if batchAllSelected {
            batchSelectedIDs.removeAll()
        } else {
            for app in batchCurrentList {
                batchSelectedIDs.insert(czfBatchKey(for: app))
            }
        }
    }

    // 每行备份状态：一次扫完 Backups 目录（每文件夹只读一次
    // manifest），按 dataUUID 建表；没对上的按显示名+包名
    // 兜底（与 backupFolderName 的认领同款优先级，显示用）；
    // 扫盘放后台，查表写表回主线程，行上只查表。
    private func refreshBackupStatus() {
        Task.detached {
            let fm = FileManager.default
            guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let backupRoot = docsURL.appendingPathComponent("Backups")
            var byUUID: [String: String] = [:]
            var byNameBid: [String: String] = [:]
            // iCloud 外部夹也扫：换机/重装后本地是空的，备份全在
            // iCloud 里，原来只扫本地，每行都显示“无备份”。外部先
            // 扫、本地后扫（同键冲突时本地覆盖；同步拷过去的同名
            // 备份日期本来就一样）。manifest 直读（detached 后台，
            // 不堵界面；数据管理页列外部备份同款读法，占位会触发
            // 下载、读到真日期）。
            var czfScanRoots: [URL] = []
            if let czfExtRoot = LCDataManagementView.externalBackupFolderURL() { czfScanRoots.append(czfExtRoot) }
            czfScanRoots.append(backupRoot)
            for czfRoot in czfScanRoots {
                if let folders = try? fm.contentsOfDirectory(at: czfRoot, includingPropertiesForKeys: nil) {
                    for folder in folders {
                        guard let info = LCDataManagementView.manifestInfo(of: folder), !info.backupDate.isEmpty else { continue }
                        if !info.dataUUID.isEmpty {
                            byUUID[info.dataUUID] = info.backupDate
                        }
                        if !info.displayName.isEmpty && !info.bundleID.isEmpty {
                            byNameBid["\(info.displayName)|\(info.bundleID)"] = info.backupDate
                        }
                    }
                }
            }
            let byUUIDCopy = byUUID
            let byNameBidCopy = byNameBid
            await MainActor.run {
                var table: [String: String] = [:]
                for app in sharedModel.apps + sharedModel.hiddenApps {
                    guard let id = sharedAppSortManager.getUniqueIdentifier(for: app) else { continue }
                    let uuid = app.appInfo.dataUUID ?? ""
                    let name = app.appInfo.displayName() ?? ""
                    let bid = app.appInfo.bundleIdentifier() ?? ""
                    if !uuid.isEmpty, let date = byUUIDCopy[uuid] {
                        table[id] = "已备份 · \(date)"
                    } else if let date = byNameBidCopy["\(name)|\(bid)"] {
                        table[id] = "已备份 · \(date)"
                    } else {
                        table[id] = "无备份"
                    }
                }
                backupStatusByID = table
            }
        }
    }

    // 3.8.282：顶部盾牌的开关（点按与长按菜单共用同一套调用；
    // 状态从 shared.isRunning 读，点按后刷新，不靠猜）
    private func toggleVPNCore() {
        CZFVPNManager.shared.noteManualCoreToggle(started: !vpnCoreRunning)
        if vpnCoreRunning {
            CZFVPNManager.shared.stop()
        } else {
            // 3.8.582（VPN-6）：起失败以前只把开关留在关态、不显示
            // 原因，用户无从查（lastError 只有 VPN 设置页读）。失败
            // 时把原因弹出来，走已有的 errorShow/errorInfo 通用报错
            // 框（L121 移到 background 叶子，sheet 盖不住）。
            let ok = CZFVPNManager.shared.start()
            if !ok {
                errorInfo = CZFVPNManager.shared.lastError ?? "核心启动失败"
                errorShow = true
            }
        }
        vpnCoreRunning = CZFVPNManager.shared.isRunning
    }

    // 3.8.282：长按菜单里节点行的字：当前节点打 ✓，测过延迟的
    // 挂毫秒数（失败挂“失败”），一眼看出哪个在用、哪个最快
    private func vpnNodeMenuLabel(idx: Int, link: String) -> String {
        let name = CZFVPNManager.nodeDisplay(for: link).name
        var suffix = ""
        if let r = vpnPingResults[idx] {
            suffix = r.success ? " · \(r.delay)ms" : " · 失败"
        }
        let mark = idx == CZFVPNManager.shared.activeNodeIndex ? "✓ " : ""
        return mark + name + suffix
    }

    // R-3：盾牌菜单的毫秒数从共用缓存恢复（VPN 页测完的
    // 结果也能显示）；只在内存表空着且没在测时恢复，不覆写
    // 刚测的。下标按节点链接内容对回，重排/增删不错位。
    // 只恢复新鲜的（<24h）：>24h 的旧数在 VPN 页显示“·旧”，
    // App 页没有旧标记——照单全收会把几天前的延迟当新鲜显示，
    // “切到最快”也会按旧数切节点。旧数不恢复，显示“未测速”，
    // 切最快时走现场重测（与 R-3 之前一致）。
    private func czfRestorePingResultsFromCache() {
        // L58-2：内存结果的下标属于旧列表时（设置页增删/重排后
        // 回到本页），先清掉——下面 restore 按内容从缓存重建，
        // 行上不再显示错行的延迟，“切到最快”也不按错下标走
        // （VPN 页 L43-2 同款）。
        if !vpnPingResults.isEmpty, vpnPingResultNodes != CZFVPNManager.shared.nodeLinks {
            vpnPingResults = [:]
            vpnPingResultNodes = []
            vpnPingResultsFetchedAt = nil
        }
        guard vpnPingResults.isEmpty, !vpnPinging else { return }
        let restored = CZFVPNManager.restorePingResults(nodes: CZFVPNManager.shared.nodeLinks)
        let fresh = restored.results.filter { !restored.stale.contains($0.key) }
        guard !fresh.isEmpty else { return }
        vpnPingResults = fresh
        vpnPingResultNodes = CZFVPNManager.shared.nodeLinks
        vpnPingResultsFetchedAt = restored.oldestTime.map { Date(timeIntervalSince1970: $0) }
    }

    // 3.8.282：长按菜单的测延迟——直接调 manager 的只读测速
    //（不像设置页那样先停核心）：核心在跑时可能整批被拒，
    // completion 的 rejected 为真时如实提示，不谎报延迟
    private func toolbarPingNodes(afterPing: (([CZFVPNManager.CZFNodePingResult], [String]) -> Void)? = nil) {
        guard !vpnPinging else { return }
        let links = CZFVPNManager.shared.nodeLinks
        guard !links.isEmpty else {
            vpnPingMessage = "还没加节点"
            return
        }
        // 3.8.305：跟设置页 startVPNPing 同规则——核心在跑先停、
        // 测完重启原来那条；没在跑直接测、测完不启动。停核心在
        // 测速标志立起来之前做，免得测速窗口内起停被 deferred
        // 逻辑插队。原来不先停核心，核心在跑时整批被生命周期锁
        // 拒、只能弹“先停核心再测”让用户手动停；现在自动走完。
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnPinging = true
        CZFVPNManager.shared.pingAllNodes { results, rejected in
            self.vpnPinging = false
            var bestIndex: Int? = nil
            if rejected {
                // 3.8.303：被拒那批全是失败，不是节点真不通——不覆写
                // 旧结果（manager 的规矩：pingAllNodes/pingSingleNode
                // 注释“界面不覆写旧结果”；设置页 startVPNPing
                // 被拒时也是不覆写、不落盘）。原来无条件先存结果，
                // 核心在跑时一测就把整表写成失败，菜单全挂“失败”，
                // 跟设置页的毫秒数对不上。旧结果留着，菜单继续显示
                // 上次真测的毫秒数；没测过就不挂后缀。先停核心后
                // 正常不应再被拒，这支留作兜底。
                self.vpnPingMessage = "核心在跑，测速被占用——先停核心再测"
            } else {
                var stored: [Int: CZFVPNManager.CZFNodePingResult] = [:]
                for (idx, r) in results.enumerated() { stored[idx] = r }
                self.vpnPingResults = stored
                // L58-2：结果按下标记存，快照记下它属于哪个列表，
                // 下面自愈/切最快按快照校验（VPN 页 L43-2 同款）。
                self.vpnPingResultNodes = links
                self.vpnPingResultsFetchedAt = Date()
                // R-3：结果写共用缓存（与 VPN 页同一份
                // CZFVPNPingCache），VPN 页测完切到 App 页，
                // 盾牌菜单不再显示"未测速"。
                CZFVPNManager.savePingResults(stored, nodes: links)
                if let best = results.enumerated().filter({ $0.element.success }).min(by: { $0.element.delay < $1.element.delay }) {
                    bestIndex = best.offset
                    let name = CZFVPNManager.nodeDisplay(for: links[best.offset]).name
                    self.vpnPingMessage = "最快：\(name)（\(best.element.delay)ms），共测了 \(results.count) 个节点"
                } else {
                    self.vpnPingMessage = "全部节点测速失败"
                }
            }
            // 停过的核心测完重启原来那条（没停过就不启动）；
            // 放 afterPing 之前，回调里切节点时核心已在跑。
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            // 3.8.306：测完自动切到最快节点——核心已重启（在跑），
            // 再切节点时 applyActiveNodeChange 会重启新节点。
            // 已是最快就不切（省一次重启）。switchToFastestNode
            // 调这里时回调还会再切一次同节点，是空操作。
            // L58-2：best 是测速起跑时快照 links 里的下标——测速
            // 期间去设置页增删/重排节点后，照旧下标切会切到错的
            // 节点；按链接内容换算成当前列表下标，找不到了
            // （已删）就不切，只报最快那条。
            if let best = bestIndex, best < links.count,
               let liveIdx = CZFVPNManager.shared.nodeLinks.firstIndex(of: links[best]),
               liveIdx != CZFVPNManager.shared.activeNodeIndex {
                CZFVPNManager.shared.setActiveNode(at: liveIdx)
                let name = CZFVPNManager.nodeDisplay(for: CZFVPNManager.shared.nodeLinks[liveIdx]).name
                self.vpnPingMessage = "已切到最快节点：\(name)（\(results[best].delay)ms）"
            }
            afterPing?(results, links)
        }
    }

    // 3.8.282：切到最快——有本轮测速结果直接切，没有就先测
    // 再切；测速被拒或全失败时不乱切（提示已在测速里给了）。
    // 索引先判界：测完后去设置页删过节点的话，旧下标可能
    // 越界（setActiveNode 自带守卫，但下标取名字会崩）
    private func switchToFastestNode() {
        let links = CZFVPNManager.shared.nodeLinks
        // L58-2：内存结果的下标属于旧列表时（设置页增删/重排后
        // 没回过本页、自愈没跑到），先清掉再现场重测——只判
        // best.key < links.count 不够，列表变了下标仍在界内、
        // 指的却是另一个节点。
        if !vpnPingResults.isEmpty, vpnPingResultNodes != links {
            vpnPingResults = [:]
            vpnPingResultNodes = []
            vpnPingResultsFetchedAt = nil
        }
        // 内存结果也会过期：LiveContainer 连续活过 24h 不重启时，
        // 恢复/测得的旧数仍在内存里，按旧数切会切到次优节点。
        // 有测量时间且在 24h 内才走内存快路，否则现场重测。
        let memoryFresh = vpnPingResultsFetchedAt.map { Date().timeIntervalSince($0) <= CZFVPNManager.pingCacheStaleAfter } ?? false
        if memoryFresh, let best = vpnPingResults.filter({ $0.value.success && $0.key < links.count }).min(by: { $0.value.delay < $1.value.delay }) {
            CZFVPNManager.shared.setActiveNode(at: best.key)
            let name = CZFVPNManager.nodeDisplay(for: links[best.key]).name
            vpnPingMessage = "已切到最快节点：\(name)（\(best.value.delay)ms）"
            return
        }
        // L58-2：回调的下标属于本次测速的快照 pingLinks，照旧
        // 下标切会切错节点（toolbarPingNodes 里同款）；按链接
        // 内容换算，找不到了就不切。
        toolbarPingNodes { results, pingLinks in
            guard let best = results.enumerated().filter({ $0.element.success }).min(by: { $0.element.delay < $1.element.delay }),
                  best.offset < pingLinks.count,
                  let liveIdx = CZFVPNManager.shared.nodeLinks.firstIndex(of: pingLinks[best.offset]) else { return }
            CZFVPNManager.shared.setActiveNode(at: liveIdx)
            let name = CZFVPNManager.nodeDisplay(for: CZFVPNManager.shared.nodeLinks[liveIdx]).name
            self.vpnPingMessage = "已切到最快节点：\(name)（\(best.element.delay)ms）"
        }
    }

    // 3.8.285：283 构建 331 红字——LCAppListView.swift:540:25
    // "the compiler is unable to type-check this expression in
    // reasonable time"。body 本来就巨大，283 把盾牌的 Button +
    // contextMenu 换成嵌套 Menu（里面还有子菜单 + ForEach），
    // 整个 body 一个表达式 type-check 超时。修法照编译器说的
    // 拆开：盾牌菜单与节点子菜单各抽成独立子表达式，body 的
    // ToolbarItem 里只留一行调用；菜单内容、点按长按语义一字不动。
    @ViewBuilder
    private var vpnNodeSubmenu: some View {
        Menu("选择节点") {
            if CZFVPNManager.shared.nodeLinks.isEmpty {
                Button("暂无节点") {}
                    .disabled(true)
            } else {
                ForEach(Array(CZFVPNManager.shared.nodeLinks.enumerated()), id: \.offset) { idx, link in
                    Button {
                        CZFVPNManager.shared.setActiveNode(at: idx)
                    } label: {
                        Text(vpnNodeMenuLabel(idx: idx, link: link))
                    }
                }
            }
        }
    }

    // 3.8.306：盾牌菜单顶上直接显示当前节点名和延迟——原来要
    // 点进“选择节点”子菜单、再看每行的毫秒数才知道在用哪个。
    // 没测过显示“未测速”，没节点显示“暂无节点”。
    private var vpnCurrentNodeLabel: String {
        let links = CZFVPNManager.shared.nodeLinks
        guard !links.isEmpty else { return "暂无节点" }
        let idx = CZFVPNManager.shared.activeNodeIndex
        guard idx < links.count else { return "暂无节点" }
        let name = CZFVPNManager.nodeDisplay(for: links[idx]).name
        if let r = vpnPingResults[idx] {
            return r.success ? "当前节点：\(name) · \(r.delay)ms" : "当前节点：\(name) · 失败"
        }
        return "当前节点：\(name) · 未测速"
    }

    @ViewBuilder
    private var vpnShieldMenu: some View {
        Menu {
            Button(vpnCurrentNodeLabel) {}
                .disabled(true)
            Button(vpnCoreRunning ? "停止核心" : "启动核心") {
                toggleVPNCore()
            }
            .disabled(vpnPinging)
            Button(vpnPinging ? "测速中…" : "测延迟") {
                toolbarPingNodes()
            }
            .disabled(vpnPinging || CZFVPNManager.shared.nodeLinks.isEmpty)
            vpnNodeSubmenu
            Button("切到最快") {
                switchToFastestNode()
            }
            .disabled(CZFVPNManager.shared.nodeLinks.isEmpty)
            Button("前往 VPN 设置") {
                sharedModel.selectedTab = .tweaks
                sharedModel.czfTweakVPNRequest += 1
            }
        } label: {
            Label("VPN", systemImage: vpnCoreRunning ? "shield.fill" : "shield")
        }
        .foregroundStyle(vpnCoreRunning ? .green : .secondary)
    }
    // 3.8.330：顶栏抽出来——body 1911 行，328 的收起/展开
    // 让编译器 type-check 超时（构建 378 红字）。顶栏整段
    // 抽到 @ToolbarContentBuilder，body 里只留一行调用；
    // 图标、菜单、点按长按语义一字不动。
    @ToolbarContentBuilder
    private var appListToolbar: some ToolbarContent {
        // 顶栏 leading 收紧（3.8.420）：“+”和“?”原来是两个独立
        // ToolbarItem，iOS 把它们并进一个 pill、中间空一大截
        // （用户 20:11 截图：pill 又宽又空）。合成一个 ToolbarItem、
        // 里面 HStack 紧排，pill 变窄、看着利落。
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 16) {
                if sharedModel.multiLCStatus != 2 {
                    // 3.8.428 设置#26：进度圈与“+”菜单并存——原来安装
                    // 进行中整个“+”被换成进度圈，安装期间没法再从
                    // “+”选 IPA 排队；现在“+”常驻，进度圈只在进行
                    // 中时跟在它后面。
                    Menu {

                        Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus", action: {
                            choosingIPA = true
                        })
                        Button("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus", action: {
                            Task{ await startInstallFromUrl() }
                        })
                    } label: {
                        // App #21：文案走 .loc（没配翻译时回落原文）。
                        Label("add".loc, systemImage: "plus")
                    }

                    if installprogressVisible {
                        ProgressView().progressViewStyle(.circular).padding(.horizontal, 8)
                    }
                }
                // 文件夹按钮已去掉（3.8.454）：文件夹移到源页，
                // App 页顶栏不再放文件夹入口。
                if(UserDefaults.sideStoreExist()) {
                    Button {
                        // 启动失败要报出来，别静默吞掉（见 openSideStore 的 onError）。
                        LCUtils.openSideStore(delegate: self) { error in
                            Task {
                                await MainActor.run {
                                    errorInfo = error.localizedDescription
                                    errorShow = true
                                }
                            }
                        }
                    } label: {
                        IconImageView(icon: BuiltInSideStoreAppInfo.shared.iconIsDarkIcon(darkModeIcon))
                            .frame(width: UIFont.preferredFont(forTextStyle: .body).lineHeight, height: UIFont.preferredFont(forTextStyle: .body).lineHeight)

                    }
                }
                // “?”已移进“>”展开的工具组（用户 21:48 令）：leading
                // 只留“+”（+ 有 SideStore 时还有它图标），不再常驻
                // 占地方；要帮助点“>”展开就能看到。
            }
        }
        
        // 顶栏三个工具收起/展开：默认只露一个箭头，点箭头
        // 展开显示数据管理/VPN/多选，再点收起；箭头在左，
        // 三个图标在它右边展开，其余图标（+、?、链接、排序）
        // 不动，三个功能本身也不动。
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation { topToolsExpanded.toggle() }
            } label: {
                Label("更多工具".loc, systemImage: topToolsExpanded ? "chevron.left" : "chevron.right")
            }
        }
        // 3.8.334：333 的 #available 修法是错的——ToolbarContentBuilder
        // 在 iOS 15 上只认 buildBlock，if / if-else / if #available
        // 全都要 iOS 16+（buildIf 与 buildLimitedAvailability 都是
        // 16+ 才有的），包 #available 也救不了，333 红字还是它。
        // 正确修法：ToolbarContentBuilder 这一层一个 if 都不留，
        // 三个工具照常摆在 builder 里，if 下沉到每个 ToolbarItem
        // 的内容里（那是 @ViewBuilder，buildIf 是 iOS 13+ 就有的）。
        // 收起时内容为空，ToolbarItem 不占位；展开时照常显示。
        // 3.8.337：文件夹图标直进恢复备份，不再停数据管理页——
        // 用户 14:11 视频：点文件夹先弹数据管理、再弹恢复备份，
        // 要直接弹恢复备份。用 initialSheet=.restore：数据管理
        // 页一出现就自动弹恢复备份（现成机制，0.5 秒后弹）。
        // 用户 14:17：顶栏全藏、只留展开箭头——文件夹也收进
        // 折叠里（点箭头才出来），默认只剩一个“>”。
        ToolbarItem(placement: .topBarTrailing) {
            if topToolsExpanded {
                NavigationLink {
                    LCDataManagementView(initialSheet: .restore)
                } label: {
                    Label("数据管理", systemImage: "folder")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // 3.8.283：长按菜单不显示（用户 282 真机报）：
            // ToolbarItem 里的 Button + contextMenu 长按不
            // 出菜单（工具栏手势抢占）。改 Menu + primaryAction：
            // 点按走 primaryAction 开关核心，长按出菜单——
            // 这才是工具栏上点按+长按的标准写法，菜单内容不变。
            // 3.8.285：嵌套 Menu 写在 body 里让编译器 type-check
            // 超时（构建 331 红字），菜单抽到上面 vpnShieldMenu，
            // 这里只留一行调用。
            if topToolsExpanded {
                vpnShieldMenu
            }
        }

        // 新4（3.8.277）：多选模式入口。开时行首挂勾选圈、
        // 整行点按即勾选；关时清空勾选。
        ToolbarItem(placement: .topBarTrailing) {
            if topToolsExpanded {
                Button {
                    batchMode.toggle()
                    if !batchMode { batchSelectedIDs.removeAll() }
                } label: {
                    Label("多选", systemImage: batchMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
            }
        }

        // 3.8.337：用户 14:17 顶栏全藏只留展开箭头——链接也收进
        // 折叠里，默认不显示，点箭头才出来。
        ToolbarItem(placement: .topBarTrailing) {
            if topToolsExpanded {
                Button("lc.appList.openLink".loc, systemImage: "link", action: {
                    Task { await onOpenWebViewTapped() }
                })
            }
        }

        // 3.8.337：同上，排序菜单也收进折叠里。
        ToolbarItem(placement: .topBarTrailing) {
            if topToolsExpanded {
            Menu {
                // 优3（3.8.277）：排序切换那一下不做全量动画——
                // 列表带 .animation(.easeInOut, value: filteredApps)，
                // 直接改 appSortType 会让整列重排闪动。自定义
                // Binding 在 setter 里用 disablesAnimations 的
                // transaction 包住写值，搜索输入的动画抑制
                //（searchContext.isTyping 那套）一行不动。
                Picker("Sort by", selection: Binding(
                    get: { sharedAppSortManager.appSortType },
                    set: { newValue in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            sharedAppSortManager.appSortType = newValue
                        }
                    }
                )) {
                    ForEach(AppSortType.allCases, id: \.self) { sortType in
                        Label(sortType.displayName, systemImage: sortType.systemImage)
                            .tag(sortType)
                    }
                }
                .onChange(of: sharedAppSortManager.appSortType) { newValue in
                    if sharedAppSortManager.appSortType == .custom {
                        // 自定义排序页是 sheet，用 withAnimation
                        // 单独给它动画——上面关动画的 transaction
                        // 别把它也压成无动画弹出。
                        withAnimation { customSortViewPresent = true }
                    }
                }
                if sharedAppSortManager.appSortType == .custom {
                    Divider()
                    
                    Button {
                        customSortViewPresent = true
                    } label: {
                        Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                    }
                }
                // 新1（3.8.277）：排序方案切换——选方案即把
                // 该方案的顺序写进 customSortOrder 并置
                // .custom（switchScheme 里做，带关动画）。
                Divider()
                Picker("排序方案", selection: Binding(
                    get: { sharedAppSortManager.currentSchemeName },
                    set: { sharedAppSortManager.switchScheme(to: $0) }
                )) {
                    ForEach(sharedAppSortManager.schemes.keys.sorted(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Button {
                    sortSchemesViewPresent = true
                } label: {
                    Label("管理排序方案…", systemImage: "folder.badge.gearshape")
                }
            } label: {
                Label("Sort by", systemImage: "line.3.horizontal.decrease.circle")
            }
            }
        }

        // 网格设置入口（3.8.419）：切换行收进设置后，网格设置
        // 从顶栏“>”展开的工具组里进——点“>”展开就能看到。
        // 点开只弹设置 sheet，不强制切模式；模式由 sheet 里
        // 的显示模式 Picker 决定。
        ToolbarItem(placement: .topBarTrailing) {
            if topToolsExpanded {
                Button {
                    czfGridSettingsShow = true
                } label: {
                    Label("网格设置", systemImage: "slider.horizontal.3")
                }
            }
        }

        // “?”帮助收到“>”展开的工具组（用户 21:48 令）：原来常驻
        // 在 leading pill 里占地方，挪到这里，点“>”展开才看到。
        ToolbarItem(placement: .topBarTrailing) {
            if topToolsExpanded {
                Button("Help".loc, systemImage: "questionmark") {
                    helpPresent = true
                }
            }
        }
    }


    // 优2（3.8.277）：列表内拖动重排——正在拖的 App 唯一 ID（松手提交用）。
    @State private var dragReorderID: String? = nil
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    // 3.8.404：分享收件箱认领——从后台切回前台时也要扫一遍
    //（App 已在前台时分享的场景，onAppear 不再触发）。
    @Environment(\.scenePhase) private var scenePhase
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    // 网格模式（3.8.406）：标准 UserDefaults。默认网格，
    // 列数默认 5，图标大小默认 0=大（1=中，2=小）。
    @AppStorage("CZFAppListGridMode") private var czfGridMode = true
    @AppStorage("CZFAppGridColumns") private var czfGridColumns = 5
    @AppStorage("CZFAppGridIconSize") private var czfGridIconSize = 0
    @State private var czfGridSettingsShow = false
    // 自定义背景（3.8.413）：版本号与网格设置页共用，选图/清除时 +1；
    // 图片存 Documents，onAppear/onChange 重读。
    @AppStorage(CZFAppBackground.versionKey) private var czfBackgroundVersion = 0
    @State private var czfBackgroundImage: UIImage?
    
    @State private var isViewAppeared = false
    
    @ObservedObject var searchContext: SearchContext = SearchContext()
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    // O-18 缓存：原来是计算属性，body 每次渲染都把全部 App
    // 过滤一遍（搜字/进度/状态一变就重算）。只在输入变时重算：
    // 输入 = 排序后列表 + 搜索词，onAppear 与下面两处 onChange
    // 里刷新缓存；body 各处读缓存，不再每渲染算一次。过滤
    // 逻辑本身不动（名字/Bundle ID/版本号三路匹配）。
    @State private var czfFilteredAppsCache: [LCAppModel] = []
    var filteredApps: [LCAppModel] { czfFilteredAppsCache }
    private func czfRefreshFilteredApps() {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            czfFilteredAppsCache = apps
        } else {
            czfFilteredAppsCache = apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                (app.appInfo.bundleIdentifier() ?? "").localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                // 优4（3.8.277）：搜版本号也命中。version 是
                // LCAppModel 的公开计算属性（取自
                // CFBundleShortVersionString，取不到是 "?"）；
                // "?" 不参与匹配，免得只输一个问号就列出全部。
                (app.version != "?" && app.version.localizedCaseInsensitiveContains(searchContext.debouncedQuery))
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                (app.appInfo.bundleIdentifier() ?? "").localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                (app.version != "?" && app.version.localizedCaseInsensitiveContains(searchContext.debouncedQuery))
            }
        }
    }

    // 新4（3.8.277）：一行 App 的显示。多选模式时行首挂勾选圈，
    // 整行点按即勾选（透明遮罩盖住横幅，免得点到启动按钮）；
    // 平时按优2挂拖拽（无搜索时），搜索时 plain 行。
    // 行下备份状态小字：查 refreshBackupStatus 建的表，
    // 表还没算好时不显示（不闪“无备份”）。
    @ViewBuilder
    private func backupStatusCaption(for app: LCAppModel) -> some View {
        if let id = sharedAppSortManager.getUniqueIdentifier(for: app),
           let status = backupStatusByID[id] {
            HStack(spacing: 4) {
                Image(systemName: status == "无备份" ? "externaldrive.badge.questionmark" : "externaldrive.fill")
                    .font(.caption2)
                Text(status)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func appRow(for app: LCAppModel) -> some View {
        if batchMode {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button { toggleBatchSelection(app) } label: {
                        Image(systemName: isBatchSelected(app) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundColor(isBatchSelected(app) ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    LCAppBanner(appModel: app, delegate: self)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { toggleBatchSelection(app) }
                        }
                }
                backupStatusCaption(for: app)
            }
        } else if searchContext.debouncedQuery.isEmpty {
            // 优2：无搜索时行可长按拖动重排（搜索时显示是
            // 子集，拖了会丢位置，所以不挂拖拽）。
            VStack(alignment: .leading, spacing: 2) {
                LCAppBanner(appModel: app, delegate: self)
                    .onDrag {
                        if let id = sharedAppSortManager.getUniqueIdentifier(for: app) {
                            dragReorderID = id
                            return NSItemProvider(object: id as NSString)
                        }
                        return NSItemProvider()
                    }
                    .onDrop(of: [.text], delegate: LCAppReorderDropDelegate(
                        targetApp: app,
                        draggedID: { dragReorderID },
                        commit: { dragged, target in commitDragReorder(draggedID: dragged, targetApp: target) }
                    ))
                backupStatusCaption(for: app)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                LCAppBanner(appModel: app, delegate: self)
                backupStatusCaption(for: app)
            }
        }
    }

    // 优2（3.8.277）：列表内长按拖动重排提交——松手时调。
    // 按当前显示顺序把拖的 App 移到目标位置，写 customSortOrder
    // 并置 .custom；没进自定义顺序的 App 按 sortByCustomOrder
    // 规则追加在后（字母序）；隐藏区 App 保持现有相对顺序
    // 跟在后面（与 LCCustomSortView.saveChanges 的拼接同款）。
    // 搜索时不启用（显示是子集，写全量顺序会丢位置）。
    private func commitDragReorder(draggedID: String, targetApp: LCAppModel) {
        defer { dragReorderID = nil }
        guard searchContext.debouncedQuery.isEmpty else { return }
        let manager = sharedAppSortManager
        guard filteredApps.contains(where: { manager.getUniqueIdentifier(for: $0) == draggedID }) else { return }
        var visibleIDs = filteredApps.compactMap { manager.getUniqueIdentifier(for: $0) }
        guard let from = visibleIDs.firstIndex(of: draggedID),
              let targetID = manager.getUniqueIdentifier(for: targetApp),
              let to = visibleIDs.firstIndex(of: targetID), from != to else { return }
        visibleIDs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        var newOrder = visibleIDs
        for hidden in sortedHiddenApps {
            guard let id = manager.getUniqueIdentifier(for: hidden), !newOrder.contains(id) else { continue }
            newOrder.append(id)
        }
        // 优3（3.8.277）：拖动松手写顺序也关动画——同款
        // disablesAnimations transaction，免得整列闪动。
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            manager.customSortOrder = newOrder
            manager.appSortType = .custom
        }
    }

    // 新4（3.8.277）：批量备份——复用单个备份函数
    // backupOneAppSync（LCDataManagementView 静态），逐个调，
    // 单个失败不 abort 整批（backupApps 同款）；拷贝重活放
    // 后台队列，主线程不卡。收尾同款：同步到外部备份文件夹 +
    // 刷新设置备份。跑完退出多选模式。
    // 3.8.302：范围由调用方从范围单里选了再传进来（原来无参、
    // 默认完整备份，从不问范围）。
    private func batchBackup(loginOnly: Bool) async {
        // 3.8.564（L289-1）：selectedBatchApps 离主线程读会撞 _info 与 @State——本函数从范围单按钮的裸 Task 调来（:1852/:1855），同步前缀跑在后台执行器上；selectedBatchApps 读 batchSelectedIDs（@State）+ sharedModel.apps/hiddenApps（@Published 数组）+ czfBatchKey → getUniqueIdentifier → bundleIdentifier()/relativeBundlePath 读 _info（NSMutableDictionary）；主线程 toggleHidden/toggleLocked 写 _info + save、列表刷新改数组时，并发读可能崩（L233-1 同款，只修了 batchHide/batchUnhide 的 filter，这三处与隐藏/恢复按钮的 Task 读点漏了；L44 注释也留了“本页这两处仍留着”）。快照回主线程取，数组是值类型、模型是 class，取完离线用无碍。
        let apps = await MainActor.run { selectedBatchApps }
        guard !apps.isEmpty else { return }
        // 3.8.534（L61-4）：本函数从批量备份范围单按钮的裸 Task 调来、
        // 不在主 actor 上（L40 同款）；batchBusy/installInfo/
        // installInfoShow/errorInfo/errorShow/batchMode/
        // batchSelectedIDs 是 @State，回主线程再写。L44 留作“可单独
        // 立批修”，L54 C2 只修了数据管理页那侧，本页这两处仍留着。
        // defer 里不能 await，改各 return 路同跳清（L44 batchHide
        // 同款；本函数设标志后有一条中途 return，尾部再清一次）。
        await MainActor.run { batchBusy = true }
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            await MainActor.run {
                errorInfo = "lc.settings.backupFail".loc
                errorShow = true
                batchBusy = false
            }
            return
        }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        // 3.8.567（L317-1）：App 页批量备份不走 doBackupScope——循环内自带
        // 锁跳过（isBackupLocked → skipped + continue），backupOneAppSync
        // 不传 allowLocked；L318-1（G1）的人脸 gate 覆盖不到这路，锁定的
        // 照样备不上。门在批量头：选中里含锁定备份（czfHasLockedBackup，
        // D 侧同款口径）→ 人脸一次；通过则该路跳过 continue 并透传
        // allowLocked: true；失败/取消清 batchBusy、不开始，已选状态不动。
        let czfAllowLocked: Bool
        if LCDataManagementView.czfHasLockedBackup(in: apps) {
            let czfAuthOK = (try? await LCUtils.authenticateUserForced()) ?? false
            guard czfAuthOK else {
                await MainActor.run { batchBusy = false }
                return
            }
            czfAllowLocked = true
        } else {
            czfAllowLocked = false
        }
        // 3.8.374：备份前先刷快照（见 refreshKeychainSnapshot），别读旧 dump
        // （backupApps 同款；批量备份原来直接调 backupOneAppSync）。
        for app in apps {
            await LCDataManagementView.refreshKeychainSnapshot(for: app)
        }
        let (okNames, failedNames, skippedNames, overwrittenCount, copyFailedCount): ([String], [String], [String], Int, Int) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                var ok: [String] = []
                var failed: [String] = []
                // 3.8.281：锁了的跳过、覆盖计数
                var skipped: [String] = []
                var overwritten = 0
                // B-2：单 App 里个别文件拷失败不抛错、也算“成功”，
                // 原来只取 folderName、失败数直接丢了；累上来进回执。
                var copyFailed = 0
                for app in apps {
                    // 3.8.544（L74）：GCD 块里离主线程读 _info（displayName/bundleIdentifier），L73 备好的 helper 同款 main.sync 取。
                    let name = LCDataManagementView.czfAppDisplayName(for: app)
                    // 3.8.281：锁了的跳过（报已锁定）；备之前先记有无
                    // 旧备份，成功了才算一次覆盖（跑完报“覆盖了 N 个”）。
                    let fname = LCDataManagementView.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
                    if LCDataManagementView.isBackupLocked(fname) && !czfAllowLocked {
                        skipped.append("\(name)（已锁定）")
                        continue
                    }
                    let hadBackup = fm.fileExists(atPath: backupRoot.appendingPathComponent(fname).path)
                    do {
                        let one = try LCDataManagementView.backupOneAppSync(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly, allowLocked: czfAllowLocked)
                        ok.append(one.folderName)
                        copyFailed += one.loginFailed
                        if hadBackup { overwritten += 1 }
                    } catch {
                        failed.append("\(name)：\(LCUtils.czfFriendlyError(error))")
                    }
                }
                if !ok.isEmpty {
                    LCDataManagementView.syncBackupsToExternalFolder(appNames: ok, backupRoot: backupRoot)
                    LCDataManagementView.writeCZFSettingsBackupDebounced()
                }
                continuation.resume(returning: (ok, failed, skipped, overwritten, copyFailed))
            }
        }
        if okNames.isEmpty && failedNames.isEmpty && !skippedNames.isEmpty {
            // 3.8.281：全被跳过（都锁了）不是失败，如实报跳过。
            await MainActor.run {
                installInfo = "已跳过 \(skippedNames.count) 个（已锁定）：\n" + skippedNames.joined(separator: "\n")
                installInfoShow = true
            }
        } else if okNames.isEmpty {
            await MainActor.run {
                errorInfo = "备份失败，一个都没备份上：\n" + failedNames.joined(separator: "\n")
                errorShow = true
            }
        } else {
            // 610 修法：540 唯一红字是这里类型检查超时（LCAppListView.swift:1080，
            // the compiler is unable to type-check this expression in reasonable time）。
            // 长串拼接（6 段 +、4 个三元、3 处插值、2 处 joined）原来是直接赋值、
            // 编得过；540（L61-4）把它包进 await MainActor.run 闭包后推过
            // 类型检查的时限。修法是拆表达式、不改逻辑：闭包外先把几段
            // 分别拼好，闭包里只做一次赋值。值全是本函数局部量（:1030
            // 的元组解包 + loginOnly 参数），与 @State 无关，先拼后赋
            // 语义一字不变。
            let backupSummaryBase = "批量备份完成：成功 \(okNames.count) 个" + (loginOnly ? "（只备份登录态）" : "（完整备份）")
            let backupSummaryOverwritten = overwrittenCount > 0 ? "（其中 \(overwrittenCount) 个覆盖了旧备份）" : ""
            let backupSummaryFailed = failedNames.isEmpty ? "" : "，失败 \(failedNames.count) 个：\n" + failedNames.joined(separator: "\n")
            let backupSummarySkipped = skippedNames.isEmpty ? "" : "，跳过 \(skippedNames.count) 个（已锁定）：\n" + skippedNames.joined(separator: "\n")
            let backupSummaryCopyFailed = copyFailedCount > 0 ? "\n其中 \(copyFailedCount) 个文件拷贝失败（备份可能不完整）" : ""
            let backupSummary = backupSummaryBase + backupSummaryOverwritten + backupSummaryFailed + backupSummarySkipped + backupSummaryCopyFailed
            await MainActor.run {
                installInfo = backupSummary
                installInfoShow = true
            }
        }
        await MainActor.run {
            batchMode = false
            batchSelectedIDs.removeAll()
            batchBusy = false
        }
        refreshBackupStatus()
    }

    // 批量恢复：多选的 App 各找自己的备份文件夹，有备份的
    // 调 restoreOneApp（静态，数据管理页同款），没备份的
    // 记“无备份”跳过；单个失败不 abort 整批，跑完汇总报数；
    // 跑完刷新每行备份状态。
    private func batchRestore(loginOnly: Bool) async {
        // 3.8.564（L289-1）：同 batchBackup——范围单按钮的裸 Task 调来（:1869/:1872），selectedBatchApps 快照回主线程取。
        let apps = await MainActor.run { selectedBatchApps }
        guard !apps.isEmpty else { return }
        // 3.8.534（L61-4）：同 batchBackup，范围单按钮的裸 Task 调来、
        // 不在主 actor 上；@State 写回主线程再写，defer 改各 return
        // 路同跳清（设标志后有一条中途 return）。
        await MainActor.run { batchBusy = true }
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            await MainActor.run {
                errorInfo = "lc.settings.backupFail".loc
                errorShow = true
                batchBusy = false
            }
            return
        }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        // 换机/重装后本地 Backups 是空的，备份全在 iCloud 外部夹里：
        // 原来只按本地算出的文件夹名找，外部有备份也报“没有备份”
        //（autoRestore 同款，批量恢复这路漏了）。本地找不到时再去
        // 外部索引里按 manifest 配对（同款严格三档）；外部索引只建
        // 一次，manifest 等下载共用 15 秒总预算（autoRestore 同款）。
        // 注意不用 backupFolderName 去外部夹算名：本地为空时它只会
        // 返回显示名，多开分身的“名（UUID8）”文件夹就对不上。
        var czfExtIndex: [(folder: URL, dataUUID: String, displayName: String, bundleID: String)] = []
        var czfExtWaitBudget = 15
        if let czfExtRoot = LCDataManagementView.externalBackupFolderURL(),
           let extFolders = try? fm.contentsOfDirectory(at: czfExtRoot, includingPropertiesForKeys: nil) {
            try? fm.startDownloadingUbiquitousItem(at: czfExtRoot)
            for folder in extFolders {
                var extIsDir: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &extIsDir), extIsDir.boolValue else { continue }
                let manifestURL = folder.appendingPathComponent("manifest.json")
                while czfExtWaitBudget > 0, !LCDataManagementView.isFileDownloaded(manifestURL, underExternal: true) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    czfExtWaitBudget -= 1
                }
                guard LCDataManagementView.isFileDownloaded(manifestURL, underExternal: true) else { continue }
                if let info = LCDataManagementView.manifestInfo(of: folder) {
                    czfExtIndex.append((folder, info.dataUUID, info.displayName, info.bundleID))
                } else {
                    czfExtIndex.append((folder, "", "", ""))
                }
            }
        }
        // 3.8.568（L317-2）：App 页批量恢复不走 doRestoreScope，restoreOneApp
        // 内 isBackupLocked/lockedBackupNames 出现 0 次——锁定备份恢复不弹
        // 人脸。门在批量头：本地算名（czfHasLockedBackup，D 侧同款）+ 外部
        // 索引里与选中 App 配对的文件夹名（本地为空时本地算名只剩显示名，
        // 多开分身的“名（UUID8）”对不上，见上面外部索引注释；只认与选中
        // App 配对的外部夹，不认整表，免得未选中 App 的锁定备份误 gate；
        // 多候选时循环记失败不恢复，gate 侧也放过，免得误弹）。
        // 失败/取消清 batchBusy、不开始，已选状态不动。
        var czfRestoreHasLocked = LCDataManagementView.czfHasLockedBackup(in: apps)
        if !czfRestoreHasLocked {
            let czfLockedNames = LCDataManagementView.lockedBackupNameSet()
            if !czfLockedNames.isEmpty {
                for app in apps {
                    let czfName = LCDataManagementView.czfAppDisplayName(for: app)
                    let (czfUUID, czfBid) = await MainActor.run { (app.appInfo.dataUUID ?? "", app.appInfo.bundleIdentifier() ?? "") }
                    if let czfExact = czfExtIndex.first(where: { !$0.dataUUID.isEmpty && !czfUUID.isEmpty && $0.dataUUID == czfUUID }) {
                        if czfLockedNames.contains(czfExact.folder.lastPathComponent) { czfRestoreHasLocked = true; break }
                    } else {
                        let czfCandidates = czfExtIndex.filter { entry in
                            if entry.displayName.isEmpty && entry.bundleID.isEmpty {
                                return entry.folder.lastPathComponent == czfName
                            }
                            return !entry.bundleID.isEmpty && entry.bundleID == czfBid && !entry.displayName.isEmpty && entry.displayName == czfName
                        }
                        if czfCandidates.count == 1 && czfLockedNames.contains(czfCandidates[0].folder.lastPathComponent) {
                            czfRestoreHasLocked = true; break
                        }
                    }
                }
            }
        }
        if czfRestoreHasLocked {
            let czfAuthOK = (try? await LCUtils.authenticateUserForced()) ?? false
            guard czfAuthOK else {
                await MainActor.run { batchBusy = false }
                return
            }
        }
        var ok: [String] = []
        var failed: [String] = []
        var noBackup: [String] = []
        // 3.8.574（L353-1）：批量恢复汇总只读 outcome.ok，钥匙串计数全丢弃——数据回来了、登录态 0 条时汇总照说“成功”，与 D 侧一键汇总同款毛病（L318-2 修过 D 侧，K2 这路漏了）。循环里仿 D:4755–4759 累加 5 个总量 + 排队 App 名，汇总处仿 D:5164–5180 追加说法；outcome.ok 语义（:6029，只看容器）不动。
        var czfKeychainFoundTotal = 0
        var czfKeychainPlistTotal = 0
        var czfKeychainQueuedTotal = 0
        var czfKeychainImportedTotal = 0
        var czfKeychainUnwritableTotal = 0
        var czfKeychainQueuedApps: [String] = []
        // 3.8.575（L360-1）：批量恢复汇总还丢 outcome.downloadIncomplete——iCloud 备份 120 秒没下完也算恢复成功（D:6029 只看容器，P0-4 在 D 侧已单列进报告），App 页汇总只说“成功 N 个”，用户以为全好了。循环里仿 D:4784–4785 无条件累加，汇总处仿 D:5110 追加说法；自动恢复成功分支同款漏（L356-1 刚补了钥匙串说法，下载未完仍没提）。
        var czfDownloadIncompleteApps: [String] = []
        // 3.8.581（L438-2）：恢复后保留的空容器（钥匙串组仍有登录态）——汇总单列。
        var czfKeptEmptyApps: [String] = []
        for app in apps {
            // 3.8.544（L74）：batchRestore 跑裸 Task（L61-4 注释），离主线程读 _info；L73 helper 同款 main.sync 取。
            let name = LCDataManagementView.czfAppDisplayName(for: app)
            let folderName = LCDataManagementView.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
            var folderURL = backupRoot.appendingPathComponent(folderName)
            var isDir: ObjCBool = false
            if !(fm.fileExists(atPath: folderURL.path, isDirectory: &isDir) && isDir.boolValue) {
                // 本地没有，去外部索引里配对：dataUUID 精确匹配直接认；
                // 否则显示名 + Bundle ID 都对上才算候选；多个候选不猜，
                // 记失败让用户去数据恢复里手动选。
                // 3.8.544（L74）：同上，dataUUID/bundleIdentifier 也是 _info 读；本函数是 async，逐点 MainActor.run 现取。
                let (appUUID, appBid) = await MainActor.run { (app.appInfo.dataUUID ?? "", app.appInfo.bundleIdentifier() ?? "") }
                if let exact = czfExtIndex.first(where: { !$0.dataUUID.isEmpty && !appUUID.isEmpty && $0.dataUUID == appUUID }) {
                    folderURL = exact.folder
                } else {
                    let candidates = czfExtIndex.filter { entry in
                        if entry.displayName.isEmpty && entry.bundleID.isEmpty {
                            // 无 manifest 的老备份只认文件夹名 == 显示名
                            return entry.folder.lastPathComponent == name
                        }
                        return !entry.bundleID.isEmpty && entry.bundleID == appBid && !entry.displayName.isEmpty && entry.displayName == name
                    }
                    if candidates.count == 1 {
                        folderURL = candidates[0].folder
                    } else if candidates.count > 1 {
                        failed.append("\(name)：找到多个备份，请在数据恢复里手动选择恢复")
                        continue
                    } else {
                        noBackup.append(name)
                        continue
                    }
                }
            }
            do {
                let outcome = try await LCDataManagementView.restoreOneApp(appFolder: folderURL, app: app, loginOnly: loginOnly)
                czfKeychainFoundTotal += outcome.keychainFound
                czfKeychainPlistTotal += outcome.keychainPlistFiles
                czfKeychainQueuedTotal += outcome.keychainQueued
                czfKeychainImportedTotal += outcome.keychainImported
                czfKeychainUnwritableTotal += outcome.keychainUnwritable
                if outcome.keychainQueued > 0 {
                    czfKeychainQueuedApps.append(name)
                }
                // L360-1：下载未完成仍算恢复成功（D:6029），单列进汇总，不进 failed（D:4784 同款，无条件记）。
                if outcome.downloadIncomplete {
                    czfDownloadIncompleteApps.append(name)
                }
                // 3.8.581（L438-2）：空容器已保留进汇总（D 侧同款）。
                if !outcome.keptEmptyContainers.isEmpty {
                    czfKeptEmptyApps.append("\(name)（\(outcome.keptEmptyContainers.count) 个空容器已保留，钥匙串组仍有登录态）")
                }
                if outcome.ok {
                    ok.append(name)
                } else {
                    failed.append("\(name)：恢复未完成")
                }
            } catch {
                failed.append("\(name)：\(LCUtils.czfFriendlyError(error))")
            }
        }
        if ok.isEmpty && failed.isEmpty && !noBackup.isEmpty {
            await MainActor.run {
                installInfo = "所选 App 都没有备份：\n" + noBackup.joined(separator: "\n")
                installInfoShow = true
            }
        } else if ok.isEmpty {
            await MainActor.run {
                errorInfo = "恢复失败，一个都没恢复上：\n" + failed.joined(separator: "\n")
                errorShow = true
            }
        } else {
            // 长串一次拼编译器算不动（3.8.320 构建 #370 红字），
            // 拆成几句一段一段拼。
            var summary = "批量恢复完成：成功 \(ok.count) 个"
            summary += loginOnly ? "（只恢复登录态）" : "（完整恢复）"
            if !failed.isEmpty {
                summary += "，失败 \(failed.count) 个：\n" + failed.joined(separator: "\n")
            }
            if !noBackup.isEmpty {
                summary += "，无备份 \(noBackup.count) 个：\n" + noBackup.joined(separator: "\n")
            }
            // L353-1：ok 非空才追加钥匙串说法——失败路已有各自说法；措辞仿 D 侧一键汇总（:5164–5180），0 条时也要写清登录态没回来。
            if czfKeychainFoundTotal > 0 {
                summary += "；钥匙串备份含 \(czfKeychainFoundTotal) 条，已排队 \(czfKeychainQueuedTotal) 条，宿主直写 \(czfKeychainImportedTotal) 条"
                if czfKeychainUnwritableTotal > 0 {
                    summary += "，\(czfKeychainUnwritableTotal) 条不注入无法写回"
                }
            } else {
                if czfKeychainPlistTotal > 0 {
                    summary += "；钥匙串快照在但读出 0 条，登录态未恢复"
                } else {
                    summary += "；钥匙串无快照，登录态未恢复"
                }
            }
            if !czfKeychainQueuedApps.isEmpty {
                summary += "；请逐个打开一次以下 App 完成登录态写回：" + czfKeychainQueuedApps.joined(separator: "、")
            }
            // L360-1：措辞仿 D:5110，ok 非空分支才追加。
            if !czfDownloadIncompleteApps.isEmpty {
                summary += "；iCloud 未下完，恢复可能不完整的 App（已恢复的部分数据可用；等 iCloud 同步完再恢复一次可补全）：\n" + czfDownloadIncompleteApps.joined(separator: "\n")
            }
            if !czfKeptEmptyApps.isEmpty {
                summary += "；空容器已保留（钥匙串组仍有登录态）：\n" + czfKeptEmptyApps.joined(separator: "\n")
            }
            await MainActor.run {
                installInfo = summary
                installInfoShow = true
            }
        }
        await MainActor.run {
            batchMode = false
            batchSelectedIDs.removeAll()
            batchBusy = false
        }
        refreshBackupStatus()
    }

    // 新4（3.8.277）：批量隐藏——复用单个隐藏函数
    // LCAppModel.toggleHidden（delegate 已指回本页，
    // changeAppVisibility 会把 App 搬进隐藏区）。只对当前
    // 可见的勾选 App 调（toggle 是开关，filter 拦住已隐藏
    // 的，防误触反向取消隐藏；想取消隐藏走下面的 batchUnhide，
    // 底栏按钮在全选隐藏时自动变“恢复显示”）。
    private func batchHide() async {
        // 3.8.556（L233）：isHidden 读 _info（LCAppInfo.m:727），本函数从按钮的裸 Task 调来、不在主 actor 上；主线程 toggleHidden 写 _info + save 时读-写并发可能崩（L70/L72/L74 同款）。整段 filter 回主线程取。
        let apps = await MainActor.run { selectedBatchApps.filter { !$0.appInfo.isHidden } }
        guard !apps.isEmpty else { return }
        // 3.8.519（L44）：本函数从按钮的裸 Task 调来、不在主 actor
        // 上（L40 同款），batchBusy/installInfo/batchMode/
        // batchSelectedIDs 是 @State，回主线程再写；toggleHidden
        // 本体已在 MainActor.run 里（L32），删文件/拷盘仍在外面。
        // 原 defer 清标志改尾部同跳清（本函数无中途 return）。
        await MainActor.run { batchBusy = true }
        for app in apps {
            await app.toggleHidden()
        }
        await MainActor.run {
            installInfo = "已隐藏 \(apps.count) 个 App（在下方隐藏 App 分段里查看）"
            installInfoShow = true
            batchMode = false
            batchSelectedIDs.removeAll()
            batchBusy = false
        }
    }

    // 3.8.281：批量恢复显示——把勾中的隐藏 App 搬回可见区。
    // toggleHidden 是开关，已隐藏的调它就是取消隐藏；只对已
    // 隐藏的调，可见的勾中了也不动（底栏按钮只在全选隐藏时
    // 才变“恢复显示”，混选时仍是“隐藏”，防一键两边乱动）。
    private func batchUnhide() async {
        // 3.8.556（L233）：isHidden 读 _info（LCAppInfo.m:727），同 batchHide，裸 Task 里离主线程读、主线程写 _info + save 时读-写并发可能崩。整段 filter 回主线程取。
        let apps = await MainActor.run { selectedBatchApps.filter { $0.appInfo.isHidden } }
        guard !apps.isEmpty else { return }
        // 3.8.519（L44）：同 batchHide，@State 写回主线程再写。
        await MainActor.run { batchBusy = true }
        for app in apps {
            await app.toggleHidden()
        }
        await MainActor.run {
            installInfo = "已恢复显示 \(apps.count) 个 App"
            installInfoShow = true
            batchMode = false
            batchSelectedIDs.removeAll()
            batchBusy = false
        }
    }

    // 新4（3.8.277）：批量删除——复用删 App 的文件部分
    // LCAppBannerViewController.deleteAppFiles（单个 uninstall()
    // 同款实现，删 .app 包 + 从列表移除 + 可选删数据容器与
    // 钥匙串），逐个调，单个失败不 abort 整批。确认在调用前
    // 由 confirmationDialog 一次问清（删 App / 删 App 及其数据）。
    private func batchDelete(removeDataFolders: Bool) async {
        // 3.8.564（L289-1）：同 batchBackup——确认框按钮的裸 Task 调来（:1837/:1840），selectedBatchApps 快照回主线程取。
        let apps = await MainActor.run { selectedBatchApps }
        guard !apps.isEmpty else { return }
        // 3.8.519（L44）：本函数从确认框按钮的裸 Task 调来、不在主
        // actor 上（L40 同款），batchBusy/errorInfo/installInfo/
        // batchMode/batchSelectedIDs 是 @State，回主线程再写；循环
        // 内 removeApp 本体已在 DispatchQueue.main.async 里（本文件
        // :3710），删文件仍在外面。原 defer 清标志改尾部同跳清。
        await MainActor.run { batchBusy = true }
        var deleted: [String] = []
        var failed: [String] = []
        var failedContainers: [String] = []
        var keptBackups: [String] = []
        for app in apps {
            // 3.8.544（L74）：batchDelete 跑确认框按钮的裸 Task（本函数注释），离主线程读 _info；L73 helper 同款 main.sync 取。
            let name = LCDataManagementView.czfAppDisplayName(for: app)
            do {
                // 3.8.557（L305-1）：deleteAppFiles 在批量删除里离主线程跑——
                // 本函数从确认框按钮的裸 Task 调来（:1837/:1840），同步前缀
                // 跑在后台执行器上；deleteAppFiles 内读 appInfo.containers
                // （_info[@"LCContainers"]，LCAppInfo.m:938，升级路还写 _info
                // + 落盘）与 appInfo.dataUUID（_info[@"LCDataUUID"]），
                // 成功删容器后还直接改 @Published appDataFolderNames
                // （SharedModel 非 @MainActor，编得过，但 SwiftUI 要求
                // 发布走主线程；单删两路都在主线程，批量这路漏了）。
                // 主线程 toggleHidden/toggleLocked 写同一份 _info，
                // 并发读可能崩（L233-1 同款）。整段调回主线程再删——
                // 单删本来就在主线程删文件，语义不变；每项各 await 一次，
                // 主线程在项与项之间能处理别的活，不会整批卡死界面。
                // removeFromList 仍是同步调完的非逃逸闭包，抓 struct
                // self 合法（原注释）。
                let (failedC, keptBackupName) = try await MainActor.run {
                    try LCAppBannerViewController.deleteAppFiles(app, removeDataFolders: removeDataFolders) { model in
                        self.removeApp(app: model)
                    }
                }
                deleted.append(name)
                failedContainers.append(contentsOf: failedC)
                if let kept = keptBackupName {
                    keptBackups.append(kept)
                }
            } catch {
                failed.append("\(name)：\(LCUtils.czfFriendlyError(error))")
            }
        }
        if deleted.isEmpty {
            await MainActor.run {
                errorInfo = "删除失败，一个都没删除：\n" + failed.joined(separator: "\n")
                errorShow = true
                batchMode = false
                batchSelectedIDs.removeAll()
                batchBusy = false
            }
        } else {
            await MainActor.run {
                installInfo = "已删除 \(deleted.count) 个 App" + (failed.isEmpty ? "" : "，失败 \(failed.count) 个：\n" + failed.joined(separator: "\n")) + (failedContainers.isEmpty ? "" : "\n以下容器删除失败，已保留：\(failedContainers.joined(separator: "、"))") + (keptBackups.isEmpty ? "" : "\n以下备份已锁定，已保留：\(keptBackups.joined(separator: "、"))")
                installInfoShow = true
                batchMode = false
                batchSelectedIDs.removeAll()
                batchBusy = false
            }
        }
    }

    // 浏览器式搜索（2026-10-24 用户定）：搜索框不再只滤已装 App，
    // 输入像网址就把网址放最上面点开直达，其他输入给一行网上搜索，
    // 点开走应用内浏览器（复用已有的 LCWebView 全屏页）。
    private var czfSearchText: String {
        searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 输入像网址才返回可直开的 URL：带 http(s):// 的直接用；不带
    // 协议的域名（如 example.com、www.example.com）补 https；带空
    // 格的短语、纯版本号、带大写的包名一律不算网址。
    private var czfSearchURL: URL? {
        let q = czfSearchText
        guard !q.isEmpty, !q.contains(" ") else { return nil }
        if let comps = URLComponents(string: q), let scheme = comps.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"), comps.host != nil {
            return comps.url
        }
        // 带其他协议头的（如 ftp://、xxx://）不是网址输入，不补协议
        if q.contains("://") { return nil }
        guard q.contains(".") else { return nil }
        let parts = q.split(separator: ".")
        let isIPv4 = parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy({ $0.isNumber }) }
        guard parts.count >= 2,
              (isIPv4 || (q == q.lowercased() && parts.last!.count >= 2 && parts.last!.allSatisfy({ $0.isLetter }))) else { return nil }
        return URL(string: "https://" + q)
    }

    private var czfSearchWebURL: URL? {
        let q = czfSearchText
        guard !q.isEmpty else { return nil }
        // L61-1：L60-1 同款——urlQueryAllowed 会放行 &（query 分隔符），
        // 搜 “H&M” 会拼成 wd=H&M、百度侧只认 wd=H；改走 czfQueryValueAllowed。
        // L63-1：czfQueryValueAllowed 只减了 &，+ 仍放行；百度按表单
        // 编码把 query 里的 + 解成空格，搜 “C++” 会变成搜 “C  ”。
        // 只在这一处再减 +（拼成 %2B），不动共用的 helper——交接路
        // 走 URLComponents，不把 + 当空格，8 处调用点无此问题。
        var allowed = CharacterSet.czfQueryValueAllowed
        allowed.remove(charactersIn: "+")
        let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
        return URL(string: "https://www.baidu.com/s?wd=" + encoded)
    }

    init() {
        _installOptions = State(initialValue: [])
    }
    
    // 浏览器式搜索快捷行（2026-10-24 用户定）：列表与网格共用——
    // 输入像网址就把网址放最上面点开直达，其他输入给一行网上搜索。
    @ViewBuilder
    private var czfSearchShortcutRows: some View {
        // 浏览器式搜索行：有输入时才出现，网址放最上面
        // 3.8.322 液体化繁为简：提示行圆角 16→22，与 App
        // 横幅行同圆角；计数行灰色走 .secondary，与行下
        // 备份状态小字同色。底栏固定铬走玻璃（见下）。
        if !czfSearchText.isEmpty {
            if let url = czfSearchURL {
                Button {
                    Task { await openWebView(urlString: url.absoluteString) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("打开网址")
                                .font(.headline)
                            Text(url.absoluteString)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(.plain)
            }
            Button {
                if let url = czfSearchWebURL {
                    Task { await openWebView(urlString: url.absoluteString) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                    Text("在网上搜索“\(czfSearchText)”")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
        }
    }

    // 原来的列表内容（body 里 ScrollView 的旧内容，原样抽出，
    // 一行未改，只换了缩进；搜索快捷行走上面共用的那份）。
    @ViewBuilder
    private var czfListContent: some View {
            NavigationLink(
                destination: navigateTo,
                isActive: $isNavigationActive,
                label: {
                    EmptyView()
            })
            .hidden()

            LazyVStack {
                // 切换行已固定在顶部（3.8.410，见 body 的 safeAreaInset），这里不再重复。
                czfSearchShortcutRows
                ForEach(filteredApps, id: \.self) { app in
                    appRow(for: app)
                }
                .transition(.scale)
            }
            .padding()
            .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredApps)

            VStack {
                // 隐藏区（3.8.280）：没人脸识别 = 只留一个 App 行高的
                // 空白，连“隐藏 App”几个字都不留，不留任何“这里藏了
                // 东西”的痕迹；长按空白处弹人脸识别，通过后 App 直接
                // 显示在列表里，不带标题。严格/非严格开关不再管列表
                // 显示（只剩 LCWebView 的链接跳转还在用它）。
                if sharedModel.hiddenApps.count > 0 {
                    if sharedModel.isHiddenAppUnlocked {
                        LazyVStack {
                            ForEach(filteredHiddenApps, id: \.self) { app in
                                // 3.8.281：隐藏行也走 appRow——多选模式时行首
                                // 挂勾选圈才能勾上；平时 appRow 的拖拽对隐藏
                                // 行是死的（commitDragReorder 只认可见 App，
                                // 拖隐藏行/往隐藏行上放都直接 no-op）。
                                appRow(for: app)
                            }
                            .transition(.scale)
                        }
                        .padding()
                        .transition(.opacity)
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                    } else {
                        Color.clear
                            .frame(height: LCAppBannerRootView.bannerHeight)
                            .contentShape(Rectangle())
                            .onLongPressGesture {
                                Task { await authenticateUser() }
                            }
                    }
                }

                let appCount = sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count
                Text(appCount > 0 || searchContext.debouncedQuery != "" ? "lc.appList.appCounter %lld".localizeWithFormat(appCount) : (sharedModel.multiLCStatus == 2 ? "lc.appList.convertToSharedToShowInLC2".loc : "lc.appList.installTip".loc))
                    .padding(.horizontal)
                    .foregroundStyle(.secondary)
                    .animation(searchContext.isTyping ? nil : .easeInOut, value: appCount)
                    .onTapGesture(count: 3) {
                        Task { await authenticateUser() }
                    }
            }.animation(searchContext.isTyping ? nil : .easeInOut, value: LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding"))

            if sharedModel.multiLCStatus == 2 {
                Text("lc.appList.manageInPrimaryTip".loc).foregroundStyle(.secondary).padding()
            }
            // 文件夹区已移到源页（3.8.454），列表底部不再接。
    }

    // 网格模式计数行文案已删（3.8.419，建议第 6 条）：“共 n 个 App”
    // 没信息量，计数行连同这条文案一起去掉。

    // 网格模式内容（自上而下）：搜索快捷行 / LazyVGrid（CZFAppGridView）。
    // 切换行已收进设置（3.8.419），不在这里。搜索栏沿用系统 .searchable，
    // 不另画才有意义；滚动位置与列表不共享。
    @ViewBuilder
    private var czfGridContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 编程式导航（3.8.419）：这条隐藏 NavigationLink 原来只在
            // 列表内容里，网格模式下不存在，点长按菜单/双击“设置”
            // 只改 isNavigationActive、没人响应，什么都不发生
            // （用户 20:11 报“网格点设置不管用”）。网格内容里也放
            // 一条，列表/网格都能进设置。
            NavigationLink(
                destination: navigateTo,
                isActive: $isNavigationActive,
                label: { EmptyView() })
            .hidden()

            czfSearchShortcutRows
            CZFAppGridView(
                apps: filteredApps,
                hiddenApps: filteredHiddenApps,
                hiddenUnlocked: sharedModel.isHiddenAppUnlocked,
                hiddenCount: sharedModel.hiddenApps.count,
                darkModeIcon: darkModeIcon,
                batchMode: batchMode,
                columns: czfGridColumns,
                iconSize: czfGridIconSize,
                isSearching: !searchContext.debouncedQuery.isEmpty,
                actions: CZFAppGridActions(
                    isBatchSelected: { app in self.isBatchSelected(app) },
                    onToggleBatchSelection: { app in self.toggleBatchSelection(app) },
                    onLaunch: { app in
                        self.czfGridLaunch(app: app)
                    },
                    onLaunchMultitask: { app in self.czfGridLaunchMultitask(app: app) },
                    onOpenSettings: { app in
                        // F-9：锁定 App 的设置页进前先认证（与启动同款守卫）；
                        // 网格双击与菜单设置按钮都走这里，一处守住两路。
                        Task {
                            guard await app.czfAuthenticateIfLocked() else { return }
                            // 3.8.519（L44）：本 Task 是裸 Task、不在主
                            // actor 上，openNavigationView 写 navigateTo/
                            // isNavigationActive（@State），回主线程再调。
                            await MainActor.run { self.openNavigationView(view: AnyView(LCAppSettingsView(model: app))) }
                        }
                    }
                ),
                onRemoveApp: { app in self.removeApp(app: app) },
                onAuthenticateHidden: { Task { await self.authenticateUser() } },
                promptForGeneratedIconStyle: { await self.promptForGeneratedIconStyle() },
                installMdm: { data in self.installMdm(data: data) }
            )
            // 计数行已删（3.8.419，建议第 6 条）：“共 n 个 App”没信息量。
            // 3.8.431 设置低 #19：网格模式看不到 App 总数；页面
            // 底部放一行小字总数（不占行、只作信息显示）。
            // O-12：页脚总数与列表 :1238 同口径——只计过滤后可见的，未解锁
            // 时不含隐藏 App；原来直接取模型全量，藏了 App 时总数比格子多、
            // 搜索时仍写全量总数，还把隐藏数量泄露出来。
            Text("共 \(sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count) 个 App")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            if sharedModel.multiLCStatus == 2 {
                Text("lc.appList.manageInPrimaryTip".loc)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // 文件夹区已移到源页（3.8.454），App 页不再内嵌。
        }
        .padding()
    }

    // 网格长按菜单里的多任务启动（banner runApp(multitask:) 同款，
    // 锁屏认证走列表的 launchAppWithBundleId 同款逻辑）：
    // 锁了先人脸，过了再按反向偏好起（多任务↔直接）。
    private func czfGridLaunchMultitask(app: LCAppModel) {
        Task {
            // O-3：与 czfGridLaunch / launchAppWithBundleId 共用守卫
            // czfAuthenticateLockedApp（锁了先人脸，过了再起）。
            guard await self.czfAuthenticateLockedApp(app) else { return }
            do {
                try await app.runApp(multitask: !app.shouldLaunchInMultitaskMode)
            } catch {
                // 3.8.519（L44）：本 Task 是裸 Task、不在主 actor 上
                //（L40 同款），errorInfo/errorShow 是 @State，回主线程再写。
                await MainActor.run {
                    errorInfo = error.localizedDescription
                    errorShow = true
                }
            }
        }
    }

    // O-3：锁屏守卫——列表/网格/多任务三路共用：锁了且没解锁过就先人脸，
    // 通过返回 true；取消返回 false、抛错弹错返回 false，调用方直接 return。
    // LCUtils.authenticateUser 成功后会置 isHiddenAppUnlocked，之后
    // launchAppWithBundleId 里的同款检查直接短路，不会弹第二次人脸。
    private func czfAuthenticateLockedApp(_ app: LCAppModel) async -> Bool {
        // 3.8.556（L233）：isLocked 读 _info（LCAppInfo.m:714），本函数从网格启动两路（czfGridLaunchMultitask/czfGridLaunch）的裸 Task 调来、不在主 actor 上；主线程 setLocked 写 _info + save 时读-写并发可能崩（L70/L72/L74 同款）。先回主线程取。
        let locked = await MainActor.run { app.appInfo.isLocked }
        guard locked && !sharedModel.isHiddenAppUnlocked else { return true }
        do {
            return try await LCUtils.authenticateUser()
        } catch {
            // 3.8.519（L44）：本函数从网格启动两路的裸 Task 调来、
            // 不在主 actor 上（L40 同款），errorInfo/errorShow 是
            // @State，回主线程再写。
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return false
        }
    }

    // 网格点图标启动（banner runButtonTapped 同款语义，3.8.406）：
    // 点已在运行的 App 不能走 runApp 空转（LCAppModel.runApp 开头
    // 就是 isAppRunning 就 return）——先按实例 UUID 在 dock 里找
    // 条目、验相对路径归属，带回并拉满；没带回才是新起：记启动偏好
    // .large、走 launchAppWithBundleId（锁屏认证路径不变）、起完
    // 轮询拉满。长按守卫是 banner 按钮独有的，网格不要。
    private func czfGridLaunch(app: LCAppModel) {
        Task {
            // O-3：带回前先认证（与 czfGridLaunchMultitask 共用守卫）：
            // 原来带回成功直接 return，锁了的 App 正在运行时点图标
            // 直接看到内容，人脸一次都不弹。
            guard await self.czfAuthenticateLockedApp(app) else { return }
            // 带回是 UIKit 活，主线程上做；带回成功直接 return，不再新起。
            // F-4：带回走共用助手（LCAppModel，banner/网格/面板三处共用）。
            if await MainActor.run(body: { LCAppModel.czfBringRunningAppToFront(app, maximize: true) }) { return }
            await self.launchAppWithBundleId(bundleId: app.appInfo.relativeBundlePath ?? "", container: nil)
            // 新开路拉满（F-4 共用助手，LCAppModel）：uuid 在助手内
            // 起完再取——无容器的 App 首启时 runApp 会新建容器并改
            // dataUUID（LCAppModel.runApp:402–436），起前取的是旧值，
            // 轮询永远找不到新窗；助手每轮重取，起完取一次等价
            // （轮询 6 秒内选中不再变），容器未建时先等容器出现。
            await MainActor.run {
                if #available(iOS 16.0, *) {
                    LCAppModel.czfPollAndMaximizeFreshWindow(app: app)
                }
            }
        }
    }

    // body 拆分（3.8.423，422 构建红字）：body 太大编译器
    // 算不过来（unable to type-check in reasonable time）。
    // 把最大的块——ScrollView（含背景/onAppear/onChange）
    // 抽出来，body 只剩 NavigationView + 修饰符。只拆不改逻辑。
    @ViewBuilder
    private var czfAppScrollContent: some View {
        ScrollView {
            if czfGridMode {
                czfGridContent
            } else {
                czfListContent
            }

        }
        // 自定义背景（3.8.415）：图挂在 ScrollView 的 .background
        // 里，不包 ZStack——413 把 ScrollView 包进 ZStack 后，
        // NavigationView 的大标题/搜索栏/切换行全叠到一块
        // （用户 414 截图：App 标题压住图标、搜索栏压住名字，
        // 太丑）。background 不动视图层级，标题/搜索/切换行
        // 原样排布，图只从透明处透出来。图带 .ignoresSafeArea()
        // 铺到顶栏区，顶栏走超薄材质（czfWallpaperToolbarBackground）
        // 透出壁纸、两页一致。
        .background {
            if let bg = czfBackgroundImage {
                Image(uiImage: bg)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.12))
            }
        }
        // 切换行已收进设置（3.8.419，建议第 3 条）：原来钉在顶部的
        // “恢复原生 / 网格设置”行删掉，模式开关收到网格设置
        // sheet 里（CZFAppGridSettingsView 的显示模式），网格设置
        // 入口收到顶栏“>”展开的工具组里；页面多出一行 App。
        .navigationBarProgressBar(show:$installprogressVisible, progress: $installProgressPercentage)
        .coordinateSpace(name: "scroll")
        .onAppear {
            czfBackgroundImage = CZFAppBackground.loadImage()
            // O-18：进页刷一次过滤缓存（输入=排序列表+搜索词）。
            czfRefreshFilteredApps()
            // 每次进页都重赋 delegate（见 czfAssignAppDelegates 注释）：
            // 冷启动扫描可能在 onAppear() 跑完后才换上新模型。
            czfAssignAppDelegates()
            if !didAppear {
                onAppear()
            }
            // 3.8.404：每次回到本页都扫分享收件箱（切回 App
            // 页时 onAppear 也触发，didAppear 守卫只拦 onAppear()）。
            czfClaimShareInbox()
            // R-3：进页时从共用缓存恢复测速结果（VPN 页测完的
            // 毫秒数也能在盾牌菜单里显示）；内存表空着才恢复。
            czfRestorePingResultsFromCache()
        }
        .onChange(of: czfBackgroundVersion) { _ in
            czfBackgroundImage = CZFAppBackground.loadImage()
        }
        // O-18：过滤缓存的两个输入变了才重算（搜字/排序列表），
        // 其余渲染（进度/状态）不再触发全量过滤。
        .onChange(of: searchContext.debouncedQuery) { _ in
            czfRefreshFilteredApps()
        }
        .onChange(of: sortedApps) { _ in
            czfRefreshFilteredApps()
            // 列表变了（冷启动扫描换模型/新装 App 追加），新模型补 delegate。
            czfAssignAppDelegates()
        }
        .onChange(of: scenePhase) { newPhase in
            // 3.8.404：从后台切回前台时扫分享收件箱（本页已在
            // 前台时分享的场景，onAppear 不触发）。
            if newPhase == .active {
                czfClaimShareInbox()
                // R-4：切回前台也刷新盾牌核心状态（核心可能在
                // VPN 页被起停或自动停，本地 @State 不自己猜；
                // 测速中不翻，与 VPN 页 refreshVPNState 同款守卫——
                // 测速期间核心是停着测的，翻了就错）。
                if !vpnPinging {
                    vpnCoreRunning = CZFVPNManager.shared.isRunning
                    // R-3：回前台也从共用缓存恢复测速结果
                    // （VPN 页测完切回来时盾牌菜单不再"未测速"）。
                    czfRestorePingResultsFromCache()
                }
            }
        }
    }

    // body 再拆分（3.8.424，423 构建仍红字）：body 420 行、35 个
    // 修饰符串在一个表达式里，编译器还是算不过来。抽 ScrollView
    // 不够，改三段拆：A=导航栏+批量底栏+前面几弹层，B=A+文件
    // 选择器+后面几弹层，body=B+事件回调。只拆不改逻辑。
    @ViewBuilder
    private var czfAppBodyA: some View {
        NavigationView {
            czfAppScrollContent
            
            // 大标题改内联（3.8.420）：大标题区在真机上是空的
            // （用户 20:11 截图：工具栏和搜索栏之间一大片空白，
            // 大标题“我的 App”没露出来，白占地方），改内联后标题
            // 收进顶栏一行，搜索栏上移，页面更紧凑。
            // 顶栏改实底（3.8.422，建议第 1 条）：导航栏背景改不透明，
            // 内容往上滑不从玻璃顶栏/搜索栏下面透出来（糊成一片、
            // 看着“显示不全”），顶部干净。
            .navigationTitle("lc.appList.myApps".loc)
            .navigationBarTitleDisplayMode(.inline)
            // 顶栏走超薄材质透壁纸（3.8.453）：之前实底
            // czfSolidToolbarBackground，App 页 .toolbarBackground
            // 没生效透出深色壁纸变黑、源页实底白，两页顶黑白不一。
            // 改走 czfWallpaperToolbarBackground，壁纸模糊透出、
            // 两页一致；iOS 15 走默认半透明。
            .czfWallpaperToolbarBackground()
            .toolbar { appListToolbar }
        }
        // 新4（3.8.277）：批量操作底栏——多选模式时才出现。备份/
        // 隐藏直接跑；删除先弹一次确认（删 App / 删 App 及其数据
        // 二选一，与单个卸载两次确认同款口径）。跑的时候按钮禁用。
        .safeAreaInset(edge: .bottom) {
            if batchMode {
                HStack {
                    Text("已选 \(batchSelectedIDs.count) 个")
                        .font(.subheadline)
                    Button(batchAllSelected ? "取消全选" : "全选") {
                        toggleBatchSelectAll()
                    }
                    .disabled(batchBusy)
                    Spacer()
                    Button("备份") {
                        // 3.8.302：先弹范围单再跑（原来直接跑完整备份）。
                        batchBackupScopeConfirm = true
                    }
                    .disabled(batchSelectedIDs.isEmpty || batchBusy)
                    Button("恢复") {
                        batchRestoreScopeConfirm = true
                    }
                    .disabled(batchSelectedIDs.isEmpty || batchBusy)
                    // 3.8.281：勾中的全是隐藏 App 时按钮变“恢复显示”
                    // （批量取消隐藏）；否则仍是“隐藏”（只藏可见的，
                    // 已隐藏的不动）。selectedBatchApps 已含隐藏 App，
                    // 全隐藏判断直接拿 batchSelectionAllHidden 算。
                    Button(batchSelectionAllHidden ? "恢复显示" : "隐藏") {
                        Task {
                            // 3.8.564（L289-1）：batchSelectionAllHidden 读 selectedBatchApps（见 batchBackup 注释），裸 Task 里直接读会离主线程撞 _info；先回主线程取快照再分支，batchHide/batchUnhide 自己还会再取一次，两次一致。
                            let allHidden = await MainActor.run { batchSelectionAllHidden }
                            if allHidden {
                                await batchUnhide()
                            } else {
                                await batchHide()
                            }
                        }
                    }
                    .disabled(batchSelectedIDs.isEmpty || batchBusy)
                    Button("删除") {
                        batchDeleteConfirm = true
                    }
                    .disabled(batchSelectedIDs.isEmpty || batchBusy)
                    .foregroundColor(.red)
                    Button("取消") {
                        batchMode = false
                        batchSelectedIDs.removeAll()
                    }
                    .disabled(batchBusy)
                }
                .padding()
                // 去液体（3.8.417）：批量底栏不再走玻璃——用户 19:06
                // “APP界面按钮别做成液体了”。改回原来浅灰实底
                // （Color(.secondarySystemBackground)），与源页同款
                // 实底做法统一。
                .background(Color(.secondarySystemBackground))
            }
        }
        // 3.8.589（L121）：同一视图挂多个 .alert/.confirmationDialog 只有最后一个生效——
        // SwiftUI 同一分支只认最外层一个弹窗（sarunw 实证，L120 同款）。
        // 各挪一个 background 叶子、各占一条分支，宿主链上不再留弹窗类修饰符；触发点与按钮一字不动。
        .background(
            EmptyView()
                .confirmationDialog("删除 \(batchSelectedIDs.count) 个 App", isPresented: $batchDeleteConfirm, titleVisibility: .visible) {
                    Button("删除 App（保留数据）", role: .destructive) {
                        Task { await batchDelete(removeDataFolders: false) }
                    }
                    Button("删除 App 及其数据", role: .destructive) {
                        Task { await batchDelete(removeDataFolders: true) }
                    }
                    Button("取消", role: .cancel) { }
                }
        )
        // 3.8.302：批量备份范围单（与数据管理页“备份范围”单同款
        // 两选项 + 同款说明）；选了范围才跑 batchBackup，取消不跑。
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .confirmationDialog("备份范围", isPresented: $batchBackupScopeConfirm, titleVisibility: .visible) {
                    Button("只备份登录态") {
                        Task { await batchBackup(loginOnly: true) }
                    }
                    Button("完整备份（数据 + 登录态）") {
                        Task { await batchBackup(loginOnly: false) }
                    }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("只备份登录态：体积小、备得快，重装后恢复即可免登录，大多数 App 选这个就够。")
                }
        )
        // 批量恢复范围单（与批量备份同款两选项）；选了范围
        // 才跑 batchRestore，取消不跑。
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .confirmationDialog("恢复范围", isPresented: $batchRestoreScopeConfirm, titleVisibility: .visible) {
                    Button("只恢复登录态") {
                        Task { await batchRestore(loginOnly: true) }
                    }
                    Button("完整恢复（数据 + 登录态）") {
                        Task { await batchRestore(loginOnly: false) }
                    }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("只恢复登录态：只恢复登录会话，不动 App 数据；完整恢复会把备份里的数据整个恢复回来。没有备份的 App 会跳过。")
                }
        )
        .navigationViewStyle(StackNavigationViewStyle())
        // 设置低 #49：系统返回只改 isNavigationActive、不清
        // navigateTo，旧 destination 常驻内存；返回后清掉。
        // closeNavigationView 经 LCAppModel delegate 还在调，不删；
        // 两条隐藏 NavigationLink 分属列表/网格各自层级，不合并。
        .onChange(of: isNavigationActive) { active in
            if !active { navigateTo = nil }
        }
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("lc.common.error".loc, isPresented: $errorShow){
                    Button("lc.common.ok".loc, action: {
                    })
                    Button("lc.common.copy".loc, action: {
                        copyError()
                    })
                } message: {
                    Text(errorInfo)
                }
        )
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("提示", isPresented: $installInfoShow){
                    Button("lc.common.ok".loc, action: {
                    })
                } message: {
                    Text(installInfo)
                }
        )
        // 3.8.282：顶部盾牌长按菜单的测速 / 切节点结果提示
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("测延迟", isPresented: Binding(get: { vpnPingMessage != nil }, set: { if !$0 { vpnPingMessage = nil } })) {
                    Button("lc.common.ok".loc, action: {
                    })
                } message: {
                    Text(vpnPingMessage ?? "")
                }
        )
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("安装前预览", isPresented: $installPreviewShow){
                    Button("安装", action: {
                        installPreviewContinuation?.resume(returning: true)
                        installPreviewContinuation = nil
                    })
                    Button("lc.common.cancel".loc, role: .cancel, action: {
                        installPreviewContinuation?.resume(returning: false)
                        installPreviewContinuation = nil
                    })
                } message: {
                    Text(installPreviewText)
                }
        )
        // 3.8.428 设置#23：批量安装进度 pill 从 .overlay(alignment:
        // .top) 移到 safeAreaInset(edge: .top)——原来贴在整个
        // NavigationView 顶部、只留 6pt，会盖住内联标题和顶栏按钮、
        // 拦截点按；现在 pill 排在导航栏下面、内容上面，不盖顶栏、
        // 不拦点按；两条 pill 都没显示时 VStack 高度为零，不占地方。
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                // 批量安装进行时，App 页顶部的小进度条：装到第几个、
                // 正在装哪个，一眼能看到（单个安装不显示）
                if installQueueRunning && installQueueTotal > 1 {
                    HStack(spacing: 8) {
                        // 点进度文字开队列名单；取消按钮在手势区域
                        // 外面，点它只取消、不弹队列 sheet。
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("队列安装中 \(installQueueDone + 1)/\(installQueueTotal)：\(installQueueCurrent)")
                                .font(.caption.bold())
                                .lineLimit(1)
                        }
                        .onTapGesture {
                            queueSheetShow = true
                        }
                        // 3.8.428 安装#6：进度条旁的取消按钮——点后
                        // 置取消标志，队列轮询到它时跳过当前项、继续
                        // 下一项（与安装#2 的取消信号打通）。
                        Button {
                            czfInstallCancelRequested = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .accessibilityLabel("取消安装")
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, 6)
                }
                // 单个安装进行中又点了安装：排进 pendingInstalls，之前是
                // 静默的，点完看不出排上了；给一条小提示，当前装完接着装
                if !pendingInstalls.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("排队中（\(pendingInstalls.count)）：当前装完接着装")
                            .font(.caption.bold())
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, 6)
                }
            }
        }
        .sheet(isPresented: $queueSheetShow) {
            // 队列名单：正在装的 + 还在排队的，排队的可以
            // 单个移除，也可以一键取消剩余全部（正在装的那个
            // 不受影响，会装完）
            NavigationView {
                List {
                    Section("正在安装") {
                        Text(installQueueCurrent.isEmpty ? "—" : installQueueCurrent)
                            .lineLimit(1)
                    }
                    Section("排队中（\(installQueue.count)）") {
                        ForEach(installQueue, id: \.id) { item in
                            HStack {
                                Text(item.url.lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    installQueue.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                            }
                        }
                    }
                }
                .navigationTitle("安装队列")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消剩余全部", role: .destructive) {
                            installQueue.removeAll()
                            queueSheetShow = false
                        }
                        .disabled(installQueue.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") {
                            queueSheetShow = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var czfAppBodyB: some View {
        czfAppBodyA
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        // 文件夹选择器与文件夹 sheet 已随文件夹移到源页
        // （3.8.454），App 页不再挂 betterFolderImporter。
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
                    ForEach(installOptions, id: \.self) { installOption in
                        Button(role: installOption.isReplace ? .destructive : nil, action: {
                            installReplaceAlert.close(result: installOption)
                        }, label: {
                            Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                        })
            
                    }
                    Button(role: .cancel, action: {
                        installReplaceAlert.close(result: nil)
                    }, label: {
                        Text("lc.appList.abortInstallation".loc)
                    })
                } message: {
                    Text("lc.appList.installReplaceTip".loc)
                }
        )
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
                    Button(role: .destructive) {
                        runWhenMultitaskAlert.close(result: true)
                    } label: {
                        Text("lc.common.continue".loc)
                    }
                    Button("lc.common.cancel".loc, role: .cancel) {
                        runWhenMultitaskAlert.close(result: false)
                    }
                } message: {
                    Text("lc.appBanner.confirmRunWhenMultitasking".loc)
                }
        )
        // 3.8.428 安装#9：覆盖运行中 App 前的确认——不静默强杀，
        // 请用户先退出该 App；“继续覆盖”才装，取消=放弃这次安装。
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("该 App 正在运行", isPresented: $czfRunningAppConfirm.show) {
                    Button("继续覆盖", role: .destructive) {
                        czfRunningAppConfirm.close(result: true)
                    }
                    Button("lc.common.cancel".loc, role: .cancel) {
                        czfRunningAppConfirm.close(result: false)
                    }
                } message: {
                    Text("「\(czfRunningAppName)」正在运行，覆盖安装前请先退出它，否则可能装坏或丢数据。确定要继续吗？")
                }
        )
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
                    Button {
                        generatedIconStyleSelector.close(result: .Light)
                    } label: {
                        Text("lc.appList.generatedIconStyleSelector.light".loc)
                    }
                    Button {
                        generatedIconStyleSelector.close(result: .Dark)
                    } label: {
                        Text("lc.appList.generatedIconStyleSelector.dark".loc)
                    }
                    Button {
                        generatedIconStyleSelector.close(result: .Original)
                    } label: {
                        Text("lc.appList.generatedIconStyleSelector.original".loc)
                    }
                    Button("lc.common.cancel".loc, role: .cancel) {
                        generatedIconStyleSelector.close(result: nil)
                    }
                }
        )
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installAsNewNameInput.show,
            title: "给新 App 起个名字".loc,
            text: $installAsNewNameInput.initVal,
            placeholder: "",
            action: { newText in
                installAsNewNameInput.close(result: newText)
            },
            actionCancel: {_ in
                installAsNewNameInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            }, downloadedIPAHandler: { fileURL in
                // 网页里下的 .ipa/.tipa 直链：downloadDidFinish 已
                // 落到 tmp，installFromUrl 接 file:// 走本地安装路。
                await installFromUrl(urlStr: fileURL.absoluteString)
            }, existingWebView: sharedModel.czfMinimizedWebView)
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .sheet(isPresented: $sortSchemesViewPresent) {
            LCAppSortSchemesView()
        }
        // 最小化的网页浮动按钮：点它即最大化（带着原页面回来）；
        // 小 X 直接丢弃最小化的页面，不打开。网页打开时不显示。
        .overlay(alignment: .bottomTrailing) {
            if let minimizedURL = sharedModel.czfMinimizedWebURL, sharedModel.czfMinimizedWebView != nil, !webViewOpened {
                HStack(spacing: 0) {
                    Button {
                        webViewURL = minimizedURL
                        webViewOpened = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                            Text(minimizedURL.host ?? minimizedURL.absoluteString)
                                .lineLimit(1)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    Button {
                        sharedModel.clearMinimizedWeb()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .padding(.trailing, 6)
                }
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
    }

    var body: some View {
        czfAppBodyB
        .onAppear() {
            // 3.8.281：每次进 App 页都刷新一次 VPN 开关状态（核心可能
            // 在别处被起停，本地 @State 不自己猜）。
            vpnCoreRunning = CZFVPNManager.shared.isRunning
            // 每行备份状态：每次进页都重算（备份可能在数据管理
            // 页刚做完，回来行上要对上）。
            refreshBackupStatus()
            // 3.8.428 设置#25：源页同事往 CZFSourcePendingInstall.items
            // 里写的待装队列，App 页出现时排空、逐个进安装队列；
            // 消费完清空，避免重复装。3.8.508（L30）：排空抽到
            // czfDrainSourcePendingInstalls，下面 onReceive 里
            // 入队通知来了也走同一份（App 页已在前台时后到的
            // 入队不能等下次出现）。下面的安装通知 onReceive
            // 原样保留，不动。
            czfDrainSourcePendingInstalls()
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                // App #25：标志位在 webPageToOpen 处理完就置真——
                // 原来只在深链分支走完后才置，没有深链时 guard
                // 提前 return，标志位永远是 false，首现逻辑
                // 每次进页都重跑一遍。
                isViewAppeared = true

                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                // 全部走队列串行执行：以前忙着装别的时新请求会被
                // 直接丢掉，批量安装实际只装得上第一个
                enqueueInstall(url: installUrl, autoReplace: (obj2["autoReplace"] as? Bool) ?? false, preview: (obj2["preview"] as? Bool) ?? false, forceAsNew: (obj2["forceAsNew"] as? Bool) ?? false, customDisplayName: obj2["customDisplayName"] as? String)
            }
        }
        // 3.8.508（L30）：源页待装队列新入队时当场排空——只靠
        // onAppear 排空时，批量更新里 dylib 后面的 App 会漏
        // （App 页已出现并排空过一次，后到的入队无人消费，
        // 无报错、无进度，直到下次进 App 页）。onReceive 只
        // 在视图在层级里时才触发，不在前台的入队等 onAppear
        // 排空；排空本身先取后清，通知重入也不会重复装。
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.CZFSourcePendingInstallAppended)) { _ in
            czfDrainSourcePendingInstalls()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.LaunchAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let bundleId = obj2["bundleId"] as? String {
                Task { await launchAppWithBundleId(bundleId: bundleId, container: nil) }
            }
        }
        .searchable(text: $searchContext.query)
        .sheet(isPresented: $czfGridSettingsShow) {
            CZFAppGridSettingsView(columns: $czfGridColumns, iconSize: $czfGridIconSize, gridMode: $czfGridMode)
        }
    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    // delegate 重赋（JIT 启动根因修法）：冷启动扫描是后台异步的
    // （LiveContainerSwiftUIApp:40，Task.detached 扫完整个替换
    // model.apps）；onAppear() 只跑一次（didAppear 守卫），扫完
    // 换上的新模型拿不到 delegate，JIT/多任务确认全走
    // delegate?. 链就静默空转——点启动没反应、没确认框、没报错。
    // 新装 App 追加进 apps 时同样没 delegate。重赋只是写引用，
    // 便宜；进页与列表变时都刷一次。
    private func czfAssignAppDelegates() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
    }

    func onAppear() {
        czfAssignAppDelegates()
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            // 3.8.519（L44）：本函数从多路按钮/深链的裸 Task 调来、
            // 不在主 actor 上（L40 同款），errorInfo/errorShow 是
            // @State，回主线程再写；下面三处同款。
            await MainActor.run {
                errorInfo = "lc.appList.urlInvalidError".loc
                errorShow = true
            }
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            // 3.8.578（L383-1）：本函数从多路按钮/深链的裸 Task 调来、不在主 actor 上（L44 同款）；这里读 sharedModel.apps/hiddenApps（@Published 数组）全表扫 urlSchemes，主线程安装完成/删除/显隐切换改同一份数组时与这里的读并发，Swift 数组非线程安全、可能崩（L309-1/L371-1 同款；urlSchemes() 本身读 _infoPlist、O-27 已证安全，危险的是数组本身）。一次回主线程取齐再分支，语义不动。
            let appToLaunch: LCAppModel? = await MainActor.run {
                var appListsToConsider = [sharedModel.apps]
                if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                    appListsToConsider.append(sharedModel.hiddenApps)
                }
                for appList in appListsToConsider {
                    for app in appList {
                        if let schemes = app.appInfo.urlSchemes() {
                            for scheme in schemes {
                                if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                    return app
                                }
                            }
                        }
                    }
                }
                return nil
            }


            guard let appToLaunch = appToLaunch else {
                await MainActor.run {
                    errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                    errorShow = true
                }
                return
            }
            
            // 3.8.556（L233）：isLocked 读 _info（LCAppInfo.m:714），本函数从多路按钮/深链的裸 Task 调来、不在主 actor 上；主线程 setLocked 写 _info + save 时读-写并发可能崩（L70/L72/L74 同款）。先回主线程取。
            let appLocked = await MainActor.run { appToLaunch.appInfo.isLocked }
            if appLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    // 3.8.534（L61-3）：L44 只包了本函数其余三处写点
                    // （guard 报错、scheme 找不到 App、runApp catch），
                    // 人脸认证这处 catch 漏了——锁 App 的外链打开时
                    // 人脸报错，弹窗不弹；同款包进 MainActor.run。
                    await MainActor.run {
                        errorInfo = error.localizedDescription
                        errorShow = true
                    }
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                await MainActor.run {
                    errorInfo = error.localizedDescription
                    errorShow = true
                }
            }
            
            return
        }
        // 新开网页时，之前最小化的网页被顶掉（只留一个最小化网页）。
        // 3.8.519（L44）：clearMinimizedWeb 写 SharedModel 的两个
        // @Published、webViewURL/webViewOpened 是 @State，回主线程
        // 再写；asyncAfter 本来就在主线程，语义不变。
        await MainActor.run {
            sharedModel.clearMinimizedWeb()
            webViewURL = urlToOpen.url!
            if webViewOpened {
                webViewOpened = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                    webViewOpened = true
                })
            } else {
                webViewOpened = true
            }
        }
    }


    
    // 本地 IPA 文件夹（3.8.423）：文件夹 bookmark 存取。
    // bookmark 存进 UserDefaults，下次点文件夹按钮直接恢复，
    // 不用重新选；失效了返回 nil、重选。
    // 3.8.435 根因（用户 11:04 报“文件夹没有显示 APP”，
    // 426/429/430 三版都没修住）：bookmark 必须带
    // .withSecurityScope，否则解析出的 URL 没有 security
    // scope，startAccessing 返回 false、读不到文件夹。
    // 之前注释里“普通 bookmark 就够”是错的——
    // 只有 picker 当场给的 URL 自带 scope，存进 UserDefaults
    // 再取出来就没了。iOS 上具名常量标了 unavailable（429
    // 实证编不过），只能用 rawValue。注意创建与解析的
    // 文件夹保存/恢复已移到 CZFLocalIpaFolderStore（3.8.454，
    // App 页与源页共用同一份；书签值与 startAccessing 顺序
    // 与 443/447 的教训一致，别改）。安装取权仍调它。

    func startInstallApp(_ fileUrl:URL) async {
        // 3.8.527（L54）：进行中再点“从 IPA 安装”要排队——原来
        // 直接调 installIpaFile，与在途安装并发跑：共用
        // installObserver/installProgressPercentage/
        // installReplaceAlert（单 continuation 会被第二路覆盖、
        // 第一路挂死），还可能算出同一 outputFolder 与同一
        // .czf-old 备份名、moveItem 互抢。照 installFromUrl
        // :3490 同款忙时进 pendingInstalls（五字段去重），轮
        // 到时 drainPendingInstalls 走 installFromUrl 的 file
        // 分支装；“+”常驻、进度圈只跟在后面（:591-600），用户
        // 随时能再点，排队提示在 :1843 一带已现成。
        // 3.8.560（L311-1）：忙时门四处 @State（installprogressVisible/installQueue/czfInFlightInstall/pendingInstalls）离主线程读 + append——与 installFromUrl 的门同款；读 + 判重 + 入队一次回主线程做。门与置 flag 合并在同一次跳里：分开跳会在门与置 flag 之间留窗口，第二路并发调用会也通过门、两路同时装（installFromUrl 入口单跳同款）。czfFileImporterTmpToDelete 是静态 Set，insert 随门一起回主线程（删方在 drain 里已回主线程，表只在主线程碰）。
        let czfBusyQueued = await MainActor.run { () -> Bool in
            guard installprogressVisible else {
                self.installprogressVisible = true
                return false
            }
            let urlStr = fileUrl.absoluteString
            let alreadyQueued = installQueue.contains(where: { $0.url == fileUrl && $0.autoReplace == false && $0.preview == false && $0.forceAsNew == false && $0.customDisplayName == nil })
            let alreadyInFlight = czfInFlightInstall.map { $0.url == fileUrl && $0.autoReplace == false && $0.preview == false && $0.forceAsNew == false && $0.customDisplayName == nil } ?? false
            let alreadyPending = pendingInstalls.contains(where: { czfIsSameInstallRequest(urlStr: urlStr, autoReplace: false, preview: false, forceAsNew: false, customDisplayName: nil, as: $0) })
            if !alreadyQueued && !alreadyInFlight && !alreadyPending {
                pendingInstalls.append(.url(urlStr, false, false, false, nil))
                // asCopy 临时副本：排空走 installFromUrl 不删它
                // （只删 Inbox / LCWebDownload-），记一笔，drain
                // 里装完（或起跑即取消）后删，免得 tmp 漏一个 IPA。
                Self.czfFileImporterTmpToDelete.insert(urlStr)
            }
            return true
        }
        if czfBusyQueued {
            return
        }
        do {
            try await installIpaFile(fileUrl)
            // L50-3：fileUrl 是文件选择器 asCopy: true 拷出来
            // 的临时副本，装完删它是清 tmp；删失败（极少）不该
            // 让已装好的这次报“安装失败”——改 try?，与
            // installFromUrl 远程段删临时包同款。
            try? FileManager.default.removeItem(at: fileUrl)
            // installIpaFile 成功路不一定清 flag，这里先清再出队，
            // 否则队里那个撞上正忙会重新排队、一直等不到
            // 3.8.560（L311-1）：收尾走 czfFinishInstall()（清 flag + 续排，顺序与原来一致）。
            await czfFinishInstall()
        } catch is CZFInstallCancelled {
            // 3.8.428 安装#2：用户取消安装，不弹错误提示。
            // 3.8.574（L351-1）：取消也清 asCopy 临时副本——忙时路 drain 里三 outcomes 都清表（L54/L341-1），非忙时路原来只成功才删。
            try? FileManager.default.removeItem(at: fileUrl)
            // 3.8.560（L311-1）：收尾走 czfFinishInstall()。
            await czfFinishInstall()
        } catch {
            // L351-1：失败同款清 tmp 副本（原件在“文件”里，重选即重试）。
            try? FileManager.default.removeItem(at: fileUrl)
            // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写；收尾走 czfFinishInstall()。
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            await czfFinishInstall()
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    // iCloud 占位文件（3.8.454，用户 20:38 报“好多 IPA 安装的
    // 损坏”“不完整”）：文件夹里的 IPA 若在 iCloud 云盘且还没
    // 下载到本机，读出来是不完整的，解包直接报“已损坏”。
    // 先触发下载并等它下完（最多 60 秒）；下不完就明确告诉
    // 用户去“文件”里点一下它、等下载完成再装。非 iCloud
    // 文件、或已下完的直接过。
    private func czfEnsureFileDownloaded(_ url: URL) async throws {
        // O-1 修法：只等“不再是 .notDownloaded”就返回是错的——下载中途
        // 状态就会变（本地已有部分副本），必须等到真正下完才返回。
        // 下完的判据：状态是 .current（最新版），或状态是 .downloaded
        // 且不在下载中（本地副本完整，只是不是最新云端版，装 IPA 够用）。
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
        func czfIsDownloaded(_ v: URLResourceValues) -> Bool {
            v.ubiquitousItemDownloadingStatus == .current ||
            (v.ubiquitousItemDownloadingStatus == .downloaded && v.ubiquitousItemIsDownloading != true)
        }
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else {
            return
        }
        if czfIsDownloaded(values) { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<120 {
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch is CancellationError {
                throw CZFInstallCancelled()
            }
            // 3.8.527（L54）：这 120×0.5 秒循环只认 Task 取消，
            // 不查 czfInstallCancelRequested——进度条旁点了取消，
            // 这里还要白等满 60 秒才走到后面的取消检查点。每次
            // sleep 后查一次，命中就按取消抛（与同款检查点一致）。
            // 3.8.560（L311-1）：czfTakeInstallCancel 读写 @State 标志，回主线程取（body: 标签，610 同款）。
            if await MainActor.run(body: { czfTakeInstallCancel() }) {
                throw CZFInstallCancelled()
            }
            if let v = try? url.resourceValues(forKeys: keys), czfIsDownloaded(v) {
                return
            }
        }
        throw "这个 IPA 还没下载完（iCloud 文件），请先在“文件”里点一下它、等下载完成再安装"
    }

    func installIpaFile(_ url:URL, autoReplace: Bool = false, forceAsNew: Bool = false, customDisplayName: String? = nil) async throws {
        let fm = FileManager()

        // iCloud 占位先确保下完（见 czfEnsureFileDownloaded），
        // 再算空间、再解包——占位文件的大小读出来不准。
        try await czfEnsureFileDownloaded(url)

        // 装之前先看空间：解包 + 落盘 + 签名大约要 IPA 体积
        // 的 3 倍，空间不够时原来是装到一半才失败、报错还看
        // 不懂；现在提前明确告诉差多少。安装低 #14：去掉
        // 50MB 门槛，小包也按 3 倍预检。
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let ipaSize = (attrs[.size] as? NSNumber)?.int64Value,
           let fsAttrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSize = (fsAttrs[.systemFreeSize] as? NSNumber)?.int64Value {
            let need = ipaSize * 3
            if freeSize < need {
                let fmt = ByteCountFormatter()
                fmt.countStyle = .file
                throw "存储空间不足：安装这个应用约需 \(fmt.string(fromByteCount: need)) 空闲空间，当前只剩 \(fmt.string(fromByteCount: freeSize))"
            }
        }

        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        // 3.8.560（L311-1）：installProgressPercentage 是 @State，回主线程置（KVO 回调里那处早已用 main.async 包过，只剩这里直写）。
        await MainActor.run { self.installProgressPercentage = 0.0 }
        // 第 2 条：解包每读一块就推一次 KVO，原来每次都 main.async 写
        // @State，全程无节流。只在变化 ≥0.5% 或距上次发布 ≥100ms
        // 时才发布；到 100% 时一定发布一次，不让进度条卡在 99.x%。
        var czfLastPublishedInstallFraction = 0.0
        var czfLastInstallPublishAt = Date.distantPast
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            let fraction = p.fractionCompleted
            let now = Date()
            if abs(fraction - czfLastPublishedInstallFraction) >= 0.005
                || now.timeIntervalSince(czfLastInstallPublishAt) >= 0.1
                || fraction >= 1.0 {
                czfLastPublishedInstallFraction = fraction
                czfLastInstallPublishAt = now
                DispatchQueue.main.async {
                    self.installProgressPercentage = Float(fraction)
                }
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        // 安装低 #23：每次安装用独立解包目录，不再共用固定
        // tmp/Payload——两个入口同时装会互相覆盖装坏。
        // 安装低 #12：defer 退出时一律清掉本次解包目录，
        // 抛错路径也不留残留（原来只在几个取消点手动删）。
        let czfExtractDir = fm.temporaryDirectory.appendingPathComponent("LCInstall-\(UUID().uuidString)")
        try? fm.createDirectory(at: czfExtractDir, withIntermediateDirectories: true)
        let payloadPath = czfExtractDir.appendingPathComponent("Payload")
        defer { try? fm.removeItem(at: czfExtractDir) }

        // decompress
        // 3.8.428 安装#8：解包失败单独报“已损坏或下载不完整”，
        // 不再复用 urlFileIsNotIpaError（那是“不是 IPA”的判断，
        // 扩展名那路还用它，别动）。
        guard await decompress(url.path, czfExtractDir.path, decompressProgress) == 0 else {
            throw "这个 IPA 已损坏或下载不完整，请重新下载"
        }

        // O-9：解包后取消检查点——原来解包、落盘、签名全程无检查点，
        // 大包签名时点取消毫无反应，只能等签完或 5 分钟超时。
        // 3.8.560（L311-1）：czfTakeInstallCancel 读写 @State 标志，回主线程取（body: 标签，610 同款）。
        if await MainActor.run(body: { czfTakeInstallCancel() }) {
            throw CZFInstallCancelled()
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        // 包名是安装流程的根基（落盘目录名、同款比对都靠它）：
        // Info.plist 里读不到包名（残留/损坏包）时走上面同款
        // “Info.plist 读不出来”的报错通道，不再往下用 ! 解包。
        // 正常包的包名一定非空，下面五处都复用这一个绑定值。
        guard let newBundleId = newAppInfo.bundleIdentifier(), !newBundleId.isEmpty else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        var appRelativePath = "\(newBundleId.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        // 3.8.577（L371-1）：installIpaFile 是非隔离 async，decompress 等 await 之后在裸 Task 执行器上跑；这里 filter 全表 App 的 bundleIdentifier() 读 _info（LCAppInfo.m:188），与主线程 toggleHidden/toggleLocked 写 _info + save、runApp 容器准备写 dataUUID（M:921-1018 主线程块）并发时读-写可能崩（L299-4/L325 同款；L81 只修了 :2957 那处，这里漏了）。两路 filter 各回主线程一次取，语义不动。
        var sameBundleIdApp = await MainActor.run {
            sharedModel.apps.filter { app in
                return app.appInfo.bundleIdentifier() == newBundleId
            }
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = await MainActor.run {
                sharedModel.hiddenApps.filter { app in
                    return app.appInfo.bundleIdentifier() == newBundleId
                }
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                // 3.8.428 安装#2：认证被拒/失败=取消安装，抛专用
                // 取消信号（原来直接 return，会被批量计为成功）；
                // 抛错不走下面那个 catch（它会把取消写进 errorInfo
                // 弹错），所以先在 do 外面算好再抛。
                var czfAuthOK = true
                do {
                    czfAuthOK = try await LCUtils.authenticateUser()
                } catch {
                    // O-8：认证抛错也 throw（原来弹错 + return，调用方以为
                    // 成功：批量计成功、远程下载的 IPA 还被删掉）。
                    // 调用方（installFromUrl / startInstallApp）的 catch
                    // 会按原有方式弹错；flag 由调用方清理，这里不碰。
                    throw error
                }
                if !czfAuthOK {
                    // 3.8.560（L311-1）：installprogressVisible 是 @State，回主线程清（清完再抛，调用方 catch 不重复清也无妨，重复清是幂等写）。
                    await MainActor.run { self.installprogressVisible = false }
                    try? fm.removeItem(at: payloadPath)
                    throw CZFInstallCancelled()
                }
            }
            
        }
        
        // 多开自定义名必须在 if 块外声明：签名之前那处在块外用它，
        // 块内 var 会出不了作用域（构建 #209 唯一红字就是这个）。
        var czfCustomDisplayName: String? = nil
        // 预设名（恢复缺失的多开实例时传）：有预设就直接用，不弹
        // 输入框；与包内原名相同 = 不自定义（与输入框同款规则）。
        // 放这里：有同款在装走下面输入框分支、无同款全新装也
        // 能把改过的名带回来，两路都覆盖。
        if let preset = customDisplayName {
            let trimmed = preset.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalName = newAppInfo.displayName() ?? ""
            if !trimmed.isEmpty && trimmed != originalName {
                czfCustomDisplayName = trimmed
            }
        }
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            // 安装低 #24：秒级时间戳同秒装两次会撞名，改毫秒。
            appRelativePath = "\(newBundleId)_\(Int(CFAbsoluteTimeGetCurrent() * 1000)).app"
            
            // 3.8.579（L395-1）：installOptions 是 @State（:188），替换选择框的 ForEach（:2174）读它；installIpaFile 是非隔离 async，decompress 等 await 之后在裸 Task 执行器上跑（L371-1 同款入口：文件选择器 :2164、分享收件箱 :3970、深链 :4769/:4854 全是裸 Task），这里直接写 @State 是离主线程发更新、与主线程渲染读同一份存储竞态，可能丢更新、框里选项出不来（L44/L81/L311-1 同款；本函数其余 @State 写点都已包过，只剩这两处）。赋值 + 追加一次回主线程做，relativeBundlePath 是 ivar 直读安全。
            await MainActor.run {
                self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
                for app in sameBundleIdApp {
                    self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
                }
            }

            let installOptionChosen: AppReplaceOption?
            if forceAsNew, !sameBundleIdApp.isEmpty {
                // 源页「新建」直达：不弹替换/新建选择框，直接按
                // 安装为新 App 走，后面照常弹新名字输入框。
                installOptionChosen = self.installOptions.first
            } else if autoReplace, let existing = sameBundleIdApp.first {
                // 批量安装指定：已装同款直接覆盖，不弹选择框
                installOptionChosen = self.installOptions.first { $0.appToReplace == existing }
            } else if autoReplace {
                // 只有残留文件夹、没有 App 记录：删掉残留，按
                // 默认文件夹名全新安装（效果等于覆盖）
                try? fm.removeItem(at: outputFolder)
                installOptionChosen = AppReplaceOption(isReplace: false, nameOfFolderToInstall: "\(newBundleId.sanitizeNonACSII()).app")
            } else {
                installOptionChosen = await installReplaceAlert.open()
            }

            guard let installOptionChosen else {
                // user cancelled
                // 3.8.428 安装#2：替换选择框点取消=取消安装，抛
                // 专用取消信号（原来直接 return，会被批量计为成功）。
                // 3.8.560（L311-1）：installprogressVisible 是 @State，回主线程清。
                await MainActor.run { self.installprogressVisible = false }
                try? fm.removeItem(at: payloadPath)
                throw CZFInstallCancelled()
            }

            // 多开（安装为新 App）：先让用户输个新名字，再往下装。
            // 空着或跟原名一样 = 不自定义；取消 = 放弃这次安装。
            // 批量自动覆盖不走这里，不弹框挡队列。
            // 预设名已落好时不弹框（恢复缺失实例自动新建用）。
            if !installOptionChosen.isReplace && !sameBundleIdApp.isEmpty && czfCustomDisplayName == nil {
                // 3.8.590（L122）：等替换选择框消失完再弹改名输入框——
                // 同款：上一个框消失动画没跑完时 root 仍忙，TextFieldAlertModifier
                // 以 root 正忙丢掉本次 present、isPresented 置回 false，
                // open() 的 continuation 永等不到 close()、安装悄悄卡死。
                // 500ms > 动画时长。取消时按安装#2 口径抛专用取消信号。
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch is CancellationError {
                    throw CZFInstallCancelled()
                }
                let originalName = newAppInfo.displayName() ?? ""
                let inputName = await installAsNewNameInput.open(initVal: originalName)
                guard let inputName else {
                    // 3.8.428 安装#2：输新名字点取消=取消安装，抛
                    // 专用取消信号（原来直接 return，会被批量计为成功）。
                    // 3.8.560（L311-1）：installprogressVisible 是 @State，回主线程清。
                    await MainActor.run { self.installprogressVisible = false }
                    try? fm.removeItem(at: payloadPath)
                    throw CZFInstallCancelled()
                }
                let trimmed = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != originalName {
                    czfCustomDisplayName = trimmed
                }
            }
            // 3.8.551（L81）：uiIsShared 是 @Published，安装路是裸 Task 执行器（LCAppListView 没标 @MainActor，L44 已证），离主线程读是 L70 同款；入口一次取齐。
            let replaceIsShared = await MainActor.run { installOptionChosen.appToReplace?.uiIsShared ?? false }
            if installOptionChosen.appToReplace != nil, replaceIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            // I1：覆盖时先不在这里删旧包——新包先搬到临时名，
            // 成功后再删旧包、把临时名改回正式名（下面 move
            // 处做），搬失败时旧包还在。
        }
        // 3.8.428 安装#9：覆盖已有 App 前，先查被替换的 App
        // 是否正在运行（LCAppModel.isAppRunning，runApp 起窗时
        // 置 true、退出时复位）——在运行就先请用户退出它，不静
        // 默强杀；确认继续才装，取消=放弃这次安装（抛专用取消
        // 信号，批量里单独计取消）。只在真有被替换对象时查，
        // 残留文件夹无 App 记录那路不查。
        // 3.8.551（L81）：isAppRunning 是 @Published、displayName()/bundleIdentifier() 读 _info、czfRunningAppName 是 @State——三者同跳取/写（L44-2 同款漏网：L44 只修了 9 处，这里不在其中；确认框 :2039 读 czfRunningAppName，离主线程写会丢更新、框里名字是旧的）。
        let replaceRunning = await MainActor.run {
            guard let appToReplace, appToReplace.isAppRunning else { return false }
            czfRunningAppName = appToReplace.appInfo.displayName() ?? appToReplace.appInfo.bundleIdentifier() ?? ""
            return true
        }
        if replaceRunning {
            guard let czfProceed = await czfRunningAppConfirm.open(), czfProceed else {
                try? fm.removeItem(at: payloadPath)
                throw CZFInstallCancelled()
            }
        }
        // 覆盖已有 App 前，先把它的整套数据自动备份一份
        //（容器+组数据+钥匙串，与手动备份同一位置、新的盖
        // 旧的）：新版装上有问题时，能从数据管理里恢复回滚
        if let appToReplace {
            await LCDataManagementView.autoBackupBeforeOverwrite(appToReplace)
        }
        // Move it!
        // I1：真回滚（先把旧包搬到备份名，再搬新包进来；任一
        // 步抛错都把旧包搬回来，旧 App 不丢）。旧包只在新包
        // 已落盘后才删备份；错误沿原路抛给调用方
        //（installFromUrl / startInstallApp 的 catch 里按
        // 原有方式报 errorInfo/errorShow）。
        let czfOldBackup = outputFolder.deletingLastPathComponent().appendingPathComponent(outputFolder.lastPathComponent + ".czf-old")
        if fm.fileExists(atPath: czfOldBackup.path) {
            try? fm.removeItem(at: czfOldBackup)
        }
        do {
            // ① 旧包先搬去备份名（不删）。
            if fm.fileExists(atPath: outputFolder.path) {
                try fm.moveItem(at: outputFolder, to: czfOldBackup)
            }
            do {
                // ② 新包搬进来。
                try fm.moveItem(at: appFolderPath, to: outputFolder)
            } catch {
                // 新包没进来：把旧包搬回来，再抛错。
                if fm.fileExists(atPath: czfOldBackup.path) {
                    try? fm.moveItem(at: czfOldBackup, to: outputFolder)
                }
                throw error
            }
            // ③ 旧包备份留到成功尾部再删（3.8.527 L54：删完
            // 仍有四处抛错点——落盘后取消、LCAppInfo 初始化
            // 失败、签名取消两处，旧包已无可回滚）。
        } catch {
            try? fm.removeItem(at: czfOldBackup)
            throw error
        }

        // 3.8.527（L54）：③ 之后四处抛错点的旧包回滚——新包
        // 已落盘在 outputFolder，不先挪走搬不回来；备份不
        // 在就什么都不做。成功尾部（函数末尾）再删备份。
        let czfRestoreOldBackup = {
            if fm.fileExists(atPath: czfOldBackup.path) {
                try? fm.removeItem(at: outputFolder)
                try? fm.moveItem(at: czfOldBackup, to: outputFolder)
            }
        }

        // O-9：落盘后取消检查点（与解包后、签名等待里同款）。
        // 3.8.560（L311-1）：czfTakeInstallCancel 读写 @State 标志，回主线程取（body: 标签，610 同款）。
        if await MainActor.run(body: { czfTakeInstallCancel() }) {
            czfRestoreOldBackup()
            throw CZFInstallCancelled()
        }

        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        // O-8：LCAppInfo 初始化失败也 throw（原来弹错 + return，调用方
        // 以为成功：批量计成功、远程下载的 IPA 还被删掉）。与函数内其
        // 他失败路径一致，调用方的 catch 按原有方式弹错。
        guard let finalNewApp else {
            // 3.8.527（L54）：新包 LCAppInfo 初始化失败，旧包搬回来再抛错。
            czfRestoreOldBackup()
            throw "lc.appList.appInfoInitError".loc
        }

        // 自定义名在签名之前落盘（LCAppInfo.plist），签名后不再动它。
        // 备份、列表、恢复全走 displayName，所以备份文件夹自动就叫
        // 这个新名字，两个同款 App 的备份不再同名互盖。
        if let czfCustomDisplayName {
            finalNewApp.customDisplayName = czfCustomDisplayName
        }
        
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        // 3.8.428 安装#6：签名 continuation 加 5 分钟超时兜底——
        // patchExecAndSignIfNeed 回调一直不来时原来永远挂起，整
        // 个安装队列僵死。超时与正常完成用 CZFOnceFlag 互斥，
        // resume 只调一次；超时后走下面原有的失败路径（signError
        // 非空、signSuccess 为 false），不在这里抛。
        let czfSignResumeOnce = CZFOnceFlag()
        // O-9：超时 Task 与取消轮询 Task 的句柄——正常完成时取消掉，
        // 不再空跑满 5 分钟；取消轮询 0.5 秒查一次取消标志，点了取消
        // 就抢 resume（与超时/正常完成共用 CZFOnceFlag 互斥，只 resume 一次）。
        var czfSignTimeoutTask: Task<Void, Never>?
        var czfSignCancelTask: Task<Void, Never>?
        // 3.8.551（L81）：uiDontSign 是 @Published，离主线程读是 L70 同款；下面 withUnsafeContinuation 的闭包是同步的、里面不能 await，先在外面取齐。
        let replaceDontSign = await MainActor.run { appToReplace?.uiDontSign ?? false }
        await withUnsafeContinuation({ c in
            if replaceDontSign || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            czfSignTimeoutTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if czfSignResumeOnce.claimTimeout() {
                    c.resume()
                }
            }
            czfSignCancelTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    // 3.8.560（L311-1）：czfInstallCancelRequested 是 @State，轮询 Task 跑全局执行器——回主线程读。
                    let czfSignCancelled = await MainActor.run { czfInstallCancelRequested }
                    if czfSignCancelled {
                        if czfSignResumeOnce.claimCancelled() {
                            c.resume()
                        }
                        return
                    }
                }
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                if czfSignResumeOnce.claim() {
                    signError = error
                    signSuccess = success
                    c.resume()
                }
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        czfSignTimeoutTask?.cancel()
        czfSignCancelTask?.cancel()
        if czfSignResumeOnce.cancelled {
            // O-9：签名等待被取消（取消轮询抢到了 resume）：抛取消，
            // 不走下面的签名失败路径；顺手取走取消标志，记取消数。
            // 3.8.560（L311-1）：czfTakeInstallCancel 读写 @State 标志，回主线程取。
            _ = await MainActor.run { czfTakeInstallCancel() }
            // 3.8.527（L54）：签名取消，旧包搬回来再抛错。
            czfRestoreOldBackup()
            throw CZFInstallCancelled()
        }
        // 3.8.499（L18）：签名轮询 0.5 秒一查，取消点在两次检查之间、
        // 签名又在下次检查前完成时，轮询被上面 cancel 掉、标志没人取——
        // 本次安装照常装完（点了取消还装上），标志还留给下一次安装、
        // 下次安装入口 :3409 直接取走当取消、白白记一次失败。签名刚完
        // 在这里再取一次，抢到就按取消抛（与上面 cancelled 分支同款）。
        // 3.8.560（L311-1）：czfTakeInstallCancel 读写 @State 标志，回主线程取（body: 标签，610 同款）。
        if await MainActor.run(body: { czfTakeInstallCancel() }) {
            // 3.8.527（L54）：签名刚完被取消，旧包搬回来再抛错。
            czfRestoreOldBackup()
            throw CZFInstallCancelled()
        }
        if czfSignResumeOnce.timedOut {
            signError = "签名超时（已等待 5 分钟），请重试"
            signSuccess = false
        }
        
        // we leave it unsigned even if signing failed
        if let signError {
            // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写。
            await MainActor.run {
                if signSuccess {
                    errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
                } else {
                    errorInfo = signError.loc
                }
                errorShow = true
            }
        }
        
        if let appToReplace {
            // 3.8.551（L81）：copy 读 fromApp.appInfo 二十多项 _info、customDisplayName 读 _info；安装路是裸 Task 执行器，整段回主线程做（L74 合进同一跳同款；toAppInfo 是本次新装的、还没进模型，写它本身不竞态，读侧才是问题）。
            await MainActor.run {
                LCAppModel.copy(fromApp: appToReplace, toAppInfo: finalNewApp)
                // 覆盖更新保留被替换那个实例的自定义名（多开改名后更新
                // 不丢名）；本分支只在覆盖时走，多开新实例不走这里。
                // 上游 9d6ea09 把逐项拷贝抽成 LCAppModel.copy，但它不拷
                // customDisplayName，这里补上，fork 定制不丢（setter
                // 自带 save，无需另调 save）。
                finalNewApp.customDisplayName = appToReplace.appInfo.customDisplayName
            }
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now
        
        DispatchQueue.main.async {
            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }
                // 3.8.561（L265-1）：32 位表同款维护——旧实例摘掉、新实例是 32 位就补进来，否则覆盖重装后表里留的是旧实例（路径 tag 相同、看着一样），新装 32 位 App 则要等下次冷启动才进模拟器选择器。
                sharedModel.arm32EmuApps.removeAll { $0 == appToReplace }
                if finalNewApp.is32bitEmulator {
                    sharedModel.arm32EmuApps.append(newAppModel)
                }
                // 覆盖安装（旧模型换新模型）后同款清掉，否则旧
                // 包路径的缓存/dock 条目会指到已替换的 App。
                if #available(iOS 16.0, *) {
                    MultitaskDockManager.refreshAfterAppChanged()
                }

            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                // 3.8.561（L265-1）：新装 32 位 App 同步进 32 位表，否则要等下次冷启动才进模拟器选择器。
                if finalNewApp.is32bitEmulator {
                    sharedModel.arm32EmuApps.append(newAppModel)
                }

                // 3.8.602（L136）：全新安装也要走同一失效——删后重
                // 装/恢复缺失 App 走的都是这条分支，包路径按包名
                // 生成、与旧包同一路径，共享图标缓存里旧图标还
                // 在，不清就一直显示旧图标。
                if #available(iOS 16.0, *) {
                    MultitaskDockManager.refreshAfterAppChanged()
                }

                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }

                // 全新安装（非覆盖更新）：自动查这个 App 的备份
                // 记录，有就直接恢复并弹窗，没有就不弹窗
                Task { await self.autoRestoreBackupAfterInstall(app: newAppModel) }
            }

            // O-9：这里只做模型追加，不清 installprogressVisible——flag
            // 只由 installFromUrl 的 defer 一处清理（startInstallApp 路
            // 由它自己清）；原来这里在 installIpaFile return 之后才跑，
            // defer 已清过一次并已 drain 下一项，延迟再清会放行并发。
        }
        // 3.8.527（L54）：成功尾部才删旧包备份（原在③处删，删完
        // 仍有四处抛错点、旧包已无可回滚）。走到这里安装已成，
        // 模型追加在上面已排队进主线程，旧备份可以清了；下次
        // 安装开头也会清残留 .czf-old，删失败（极少）不报错。
        try? fm.removeItem(at: czfOldBackup)
    }

    /// 全新安装完成后自动查备份记录（数据管理里备的）：
    /// 严格配对（照手动恢复的三档：dataUUID 精确匹配优先，
    /// 否则显示名 + Bundle ID 都对上才算，多个候选不猜），
    /// 有唯一备份就直接恢复（容器+组数据+钥匙串整套）并提示，
    /// 没有就不弹窗。只在全新安装时调——覆盖更新时
    /// 数据本来就在，拿旧备份回滚反而会把新数据冲掉
    func autoRestoreBackupAfterInstall(app: LCAppModel) async {
        // 后台持有（v222）：安装后自动恢复调 restoreOneApp，
        // 拷盘是 GB 级同步活（v220 已挪后台，但本入口此前无
        // 任何持有）；没它时切后台/锁屏会被挂起、看门狗杀进程
        // （v220 同款根因，只是另一个入口）。begin + defer
        // 必 end：函数内两处 guard early return 也走 defer，
        // 不会漏；过期回调留空是故意的：拷盘已挪后台、主线程
        // 响应，过期只干净挂起、回前台继续，不杀进程。
        // UIApplication 本文件已在用（open 链接两处），无需新 import。
        let bgID = UIApplication.shared.beginBackgroundTask { }
        defer { UIApplication.shared.endBackgroundTask(bgID) }
        let fm = FileManager.default
        // 3.8.566（L299-4）：bundleIdentifier()/displayName() 读 _info（LCAppInfo.m:188/:139），
        // 本函数在裸 Task 里跑（下面 L54 注释同款），主线程 toggleHidden/toggleLocked 写 _info +
        // save 时读-写并发可能崩（L289-1/L233-1 同款；L54 只把其他实例的 dataUUID 快照回了
        // 主线程取，本 App 这三行漏了）。入口一次取齐；dataUUID 是 ivar 属性、不读 _info，
        // 顺手同跳取，不另起一跳。回落语义一字不动（name 取不到时仍回落 bundleID）。
        let (bundleID, name, appUUID) = await MainActor.run {
            let bid = app.appInfo.bundleIdentifier() ?? ""
            let nm = app.appInfo.displayName() ?? bid
            return (bid, nm, app.appInfo.dataUUID ?? "")
        }
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let root = docs.appendingPathComponent("Backups")
        var folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        // 换机/重装后本地 Backups 是空的，备份全在 iCloud 外部夹里：
        // 原来只扫本地，自动恢复直接报“没有可恢复的数据”，等于没
        // 生效。本地优先（在列表前面，先配上、行为不变），后面再
        // 接外部文件夹一起配对。外部夹先触发整树下载；单个
        // manifest 等不到就不读（见循环内守卫），不比现在更差。
        let czfExtRoot = LCDataManagementView.externalBackupFolderURL()
        if let czfExtRoot {
            try? fm.startDownloadingUbiquitousItem(at: czfExtRoot)
            folders += (try? fm.contentsOfDirectory(at: czfExtRoot, includingPropertiesForKeys: nil)) ?? []
        }
        // 外部 manifest 下载等待总预算（restoreFromBackup 同款 15 秒）：
        // 逐个文件夹等会把总时间拉长，共用一个预算；用完后剩下的外
        // 部文件夹直接跳过（循环内守卫）。
        var czfExtWaitBudget = 15
        // 3.8.527（L54）：他实例备份排除——dataUUID 只在首次启动
        // 容器准备时才写（LCAppModel :716/:728/:824），安装刚完
        // 还没启动时 appUUID 恒空，第一档精确匹配永远走不到；
        // 不改名多开第二实例时，第二/三档（文件夹名 == 显示名 +
        // Bundle ID）会把原实例的备份当成自己的、自动恢复串实例。
        // 先快照列表里其他实例的 dataUUID（经主线程取，@Published
        // 数组；本函数在裸 Task 里跑，见 C3 同款），循环里 manifest
        // 的 dataUUID 若属于另一仍在列表里的实例，直接跳过该文件夹。
        // 删掉重装那路：原实例已不在列表，快照里没有它的 dataUUID，
        // 不排除、照旧恢复自己的数据。无 manifest 的老备份没有
        // dataUUID 可认，维持原行为。
        let czfOtherDataUUIDs: Set<String> = await MainActor.run {
            Set((sharedModel.apps + sharedModel.hiddenApps).filter { $0 !== app }.compactMap { $0.appInfo.dataUUID }.filter { !$0.isEmpty })
        }
        // 3.8.283：自动恢复改严格配对（照手动恢复 restoreFromBackup
        // 的三档）：dataUUID 精确匹配直接认；否则显示名 + Bundle ID
        // 都对上才算候选；多个候选不猜（多开分身同 bundleID，取第
        // 一个会串实例）。原来文件夹名一对上就认、bundleID 取第一
        // 个，删掉重装很容易恢复成另一个实例的数据。
        var found: URL?
        var candidates: [URL] = []
        for folder in folders {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            // 外部文件夹的 manifest 可能是 iCloud 占位：Data 读会触发隐式
            // 下载长堵（restoreFromBackup 同款注释），先等它下完再读；
            // 预算内等不到就跳过这个文件夹（不读占位、不误判）。
            // 无 manifest 的老备份 isFileDownloaded 恒真（无状态即已下载），
            // 直接过、不等。
            if let czfExtRoot, folder.path.hasPrefix(czfExtRoot.path + "/") {
                let manifestURL = folder.appendingPathComponent("manifest.json")
                while czfExtWaitBudget > 0, !LCDataManagementView.isFileDownloaded(manifestURL, underExternal: true) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    czfExtWaitBudget -= 1
                }
                guard LCDataManagementView.isFileDownloaded(manifestURL, underExternal: true) else { continue }
            }
            var json: [String: String]?
            if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                json = obj
            }
            // 第一档：manifest dataUUID 就是这个实例（同一次安装）
            if let du = json?["dataUUID"], !du.isEmpty, !appUUID.isEmpty, du == appUUID {
                found = folder
                break
            }
            // 3.8.527（L54）：这份备份的 dataUUID 属于列表里另一
            // 实例（仍在用），不是本 App 的——二/三档别认它。
            // 放在第一档之后：第一档是本实例精确匹配，优先认。
            if let du = json?["dataUUID"], !du.isEmpty, czfOtherDataUUIDs.contains(du) {
                continue
            }
            let mBid = json?["bundleIdentifier"] ?? ""
            let mName = json?["displayName"] ?? ""
            // 第二档：文件夹名 == 显示名且 manifest Bundle ID 对上
            // 第三档（改名兜底）：manifest Bundle ID + 显示名都对上
            // 无 manifest 的老备份只认文件夹名 == 显示名
            if json == nil {
                if folder.lastPathComponent == name { candidates.append(folder) }
            } else if folder.lastPathComponent == name, !mBid.isEmpty, mBid == bundleID {
                candidates.append(folder)
            } else if !mBid.isEmpty, mBid == bundleID, !mName.isEmpty, mName == name {
                candidates.append(folder)
            }
        }
        if found == nil {
            // 候选去重：同一文件夹只留一次；本地与外部同一份备份（同步拷
            // 过去的）文件夹同名，按名再去重，只留一份——candidates 按扫描
            // 顺序（本地在前），本地优先。不同名的才是真多开分身，照旧报
            // “多个备份”让用户手动选。
            var czfSeenNames = Set<String>()
            let unique = candidates.filter { czfSeenNames.insert($0.lastPathComponent).inserted }
            if unique.count == 1 {
                found = unique[0]
            } else if unique.count > 1 {
                // 多个候选不猜：报一声，让用户去恢复列表手动选
                await MainActor.run {
                    installInfo = "「\(name)」找到多个备份，请在数据恢复里手动选择恢复"
                    installInfoShow = true
                }
                return
            }
        }
        guard let found else {
            // 无备份就不弹窗：全新安装本来就没东西可恢复，
            // 弹一次纯属打扰；有备份才弹窗（恢复结果在下面）
            return
        }
        // 3.8.576（L366-1）：原来 try? 把 restoreOneApp 的抛错整个
        // 吞掉（D:5517 读备份目录、D:5606/:5668 拷容器失败都会抛，
        // 如磁盘满、iCloud 占位未下完），outcome 变 nil 后报告链
        // 一路掉到底，报“没有可恢复的数据”——备份明明有数据，
        // 只是恢复失败，用户可能就此删备份或放弃重试。D 侧单恢复
        // （:4747 do/catch）与本页批量恢复（:1268 + :1085
        // czfFriendlyError）都报真错，只有自动恢复这条路撒谎。
        // do/catch 接住真错，报告里单列一支；空备份仍报原话。
        let outcome: LCDataManagementView.RestoreOutcome?
        let restoreError: Error?
        do {
            outcome = try await LCDataManagementView.restoreOneApp(appFolder: found, app: app)
            restoreError = nil
        } catch {
            outcome = nil
            restoreError = error
        }
        await MainActor.run {
            if outcome?.ok == true {
                // 3.8.575（L356-1）：自动恢复的成功分支原来只说“已恢复备份记录”——outcome.ok 只看容器（D:6029），钥匙串与 ok 无关；备份里没钥匙串快照、或快照 0 条时登录态根本没回来，用户看一句“已恢复”以为全好了。D 侧单恢复（L318-2）与 App 页批量恢复（L353-1）都已补 0 条说法，自动恢复是最后一条漏的路。措辞仿 L353-1（:1305–1320）：found>0 拼正向行 + 不注入条数 + 排队提醒，0 条时写清登录态未恢复；失败分支已有各自说法，不动。
                var msg = "「\(name)」已恢复备份记录"
                if let outcome {
                    if outcome.keychainFound > 0 {
                        msg += "；钥匙串备份含 \(outcome.keychainFound) 条，已排队 \(outcome.keychainQueued) 条，宿主直写 \(outcome.keychainImported) 条"
                        if outcome.keychainUnwritable > 0 {
                            msg += "，\(outcome.keychainUnwritable) 条不注入无法写回"
                        }
                        if outcome.keychainQueued > 0 {
                            msg += "；请打开一次「\(name)」完成登录态写回"
                        }
                    } else if outcome.keychainPlistFiles > 0 {
                        msg += "；钥匙串快照在但读出 0 条，登录态未恢复"
                    } else {
                        msg += "；钥匙串无快照，登录态未恢复"
                    }
                    // L360-1：成功分支也可能下载未完——outcome.ok 只看容器（D:6029），iCloud 120 秒没下完也算成功；仿 D:5110 补一句，失败分支不动。
                    if outcome.downloadIncomplete {
                        msg += "；iCloud 未下完，恢复可能不完整，等 iCloud 同步完再恢复一次可补全"
                    }
                    // 3.8.581（L438-2）：空容器已保留进提示（D 侧同款）。
                    if !outcome.keptEmptyContainers.isEmpty {
                        msg += "；\(outcome.keptEmptyContainers.count) 个空容器已保留（钥匙串组仍有登录态）"
                    }
                }
                installInfo = msg
            } else if let outcome, outcome.keychainFound > 0 {
                // 备份里明明有钥匙串却恢复失败：把条数和错误码
                // 亮出来，卡在哪一环一眼可辨，不再误报"没数据"
                installInfo = "「\(name)」找到备份记录，钥匙串有 \(outcome.keychainFound) 条但写回失败（错误码 \(outcome.keychainStatus)）"
            } else if let restoreError {
                // L366-1：restoreOneApp 抛错（不是空备份）——报真错，
                // 不再谎报“没有可恢复的数据”；措辞仿 D 侧单恢复的
                // “恢复失败（czfFriendlyError）”同款。
                installInfo = "「\(name)」找到备份记录，恢复失败：\(LCUtils.czfFriendlyError(restoreError))"
            } else {
                installInfo = "「\(name)」找到备份记录，但没有可恢复的数据"
            }
            installInfoShow = true
        }
    }

    func startInstallFromUrl() async {
        guard var installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        // 3.8.428 App#4：输入的链接先去首尾空格/换行（从微信复制
        // 常带尾随换行），再走 itms-services 判断与 installFromUrl。
        installUrlStr = installUrlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !installUrlStr.isEmpty else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        // 进行中再点：同样排队（与 url 安装共用一个队）
        // .plist 项没有 autoReplace/preview/forceAsNew 三个字段，
        // 排队去重仍只比 urlStr（O-9 的四字段键只管 .url 项）。
        // 3.8.560（L311-1）：忙时门两处 @State（installprogressVisible/pendingInstalls）离主线程读 + append——与 installFromUrl 的门同款（L309-1/L311-1）；读 + 入队一次回主线程做。
        let czfBusyQueued = await MainActor.run { () -> Bool in
            guard installprogressVisible else { return false }
            if !pendingInstalls.contains(where: { $0.urlStr == urlStr }) {
                pendingInstalls.append(.plist(urlStr))
            }
            return true
        }
        if czfBusyQueued {
            return
        }

        // 3.8.566（L299-3）：.plist 项没走 installFromUrl 的 defer——下载/解析/取消
        // 任一处提前 return 都不续排，队里剩下的要等下一次安装才接着排（“排队中”
        // 一直挂着）。交接标志只在真正把活交给内层 installFromUrl（它的 defer 会
        // 续排）时才立；没交接的 return 路一律由本函数 defer 补排。忙时排队那
        // 条 return 在 defer 注册之前：它只是入队，正在装的那一项的 defer 会续排，
        // 这里不抢排。
        var czfHandedOff = false
        defer { if !czfHandedOff { drainPendingInstalls() } }

        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)

        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写。
                await MainActor.run {
                    errorInfo = "lc.appList.plistInvalidError".loc
                    errorShow = true
                }
                return
            }
        }

        // O-9：入口校验走共用函数（trim + multiLCStatus + URL 合法，
        // 与 installFromUrl 同款）；itms-services 解包在校验前做，解出
        // 的才是真 plist 地址。唯一顺序变化：原来 multiLCStatus 检查在
        // 解包前、现在在解包后——双重有错的输入（副 App + 坏 itms 链接）
        // 先报 plistInvalidError，不再先报副 App 提示。
        // 3.8.560（L311-1）：czfValidatedInstallURL 内写 errorInfo/errorShow（@State），回主线程验（body: 标签，610 同款）。
        guard let plistUrl = await MainActor.run(body: { czfValidatedInstallURL(plistUrlStr) }) else {
            return
        }
        
        do {
            // 3.8.548（L185）：plist 会变（新版上架），走 freshData 绕开 URLCache 取新鲜数据——
            // 同 L181-1（源页/图标/订阅）机理；同一 plist URL 二次安装时 max-age 内拿缓存字节，
            // plist 里还是旧版 IPA 地址，装上旧版（L79/L80 同款害处）。
            let (data, response) = try await CZFVPNManager.freshData(from: plistUrl)
            // URLSession.data 只在传输错误时抛，HTTP 4xx/5xx 也会落盘
            // 成“plist”再解析；先验状态，非 2xx 按 DownloadDelegate
            // 同款文案抛错，别把 404 错误页报成“plist 解析失败”误导排查。
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "下载失败，服务器返回 \(httpResponse.statusCode)"])
            }
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写。
                await MainActor.run {
                    errorInfo = "lc.appList.plistParseError".loc
                    errorShow = true
                }
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写。
                await MainActor.run {
                    errorInfo = "lc.appList.plistNoIpaError".loc
                    errorShow = true
                }
                return
            }
            
            // 3.8.566（L299-3）：下载窗口里点的取消——内层 installFromUrl 入口取走
            // 标志、defer 没跑，上面 drainPendingInstalls 的起跑预检（L42）只盖 .url
            // 项，不管这条；这里下载完先取一次，取到就当取消 return、defer 补排下
            // 一项。取不到再调内层，中间没有挂起点、标志变不了。
            // 3.8.560（L311-1）：czfTakeInstallCancel 读写 @State 标志，回主线程取（body: 标签，610 同款）。
            if await MainActor.run(body: { czfTakeInstallCancel() }) {
                return
            }
            czfHandedOff = true
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写。
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
            }
        }
    }
    
    /// 源页待装队列排空（3.8.428 设置#25 建、3.8.508 L30 抽共用）：
    /// 先取后清再逐个进安装队列——onAppear 与入队通知两路共用，
    /// 通知重入（排空里不再写共享数组，不会重入）与并发（主线程
    /// 两路串行）都不会重复装。
    func czfDrainSourcePendingInstalls() {
        guard !CZFSourcePendingInstall.items.isEmpty else { return }
        let czfQueued = CZFSourcePendingInstall.items
        CZFSourcePendingInstall.items.removeAll()
        for item in czfQueued {
            enqueueInstall(url: item.url, autoReplace: item.autoReplace, preview: item.preview, forceAsNew: item.forceAsNew)
        }
    }

    /// 安装请求队列：下载器全局只有一个、安装器同时只能装
    /// 一个，源页的批量安装必须一个一个排队来，不然忙着装
    /// 别的时新请求会被直接丢掉、批量只装得上第一个。单个
    /// 安装请求也走这里（队列空闲时立即执行，和以前一样）；
    /// autoReplace 的请求遇到已装同款直接覆盖、不弹选择框
    func enqueueInstall(url: URL, autoReplace: Bool, preview: Bool = false, forceAsNew: Bool = false, customDisplayName: String? = nil) {
        // App #8：同一 IPA 点两次会进队两次（文件夹网格双击 /
        // 源页批量重复勾选）；入队前判重，同一请求已在队里
        // 就不再加。
        guard !installQueue.contains(where: { $0.url == url && $0.autoReplace == autoReplace && $0.preview == preview && $0.forceAsNew == forceAsNew && $0.customDisplayName == customDisplayName }) else {
            return
        }
        // O-9：去重覆盖在途项（已出队正在装）与 pendingInstalls（忙时排队的），
        // 三处共用同一五字段键；只查队里会漏掉这两处，同一请求正在装时
        // 再点会重复进队、第二遍走替换选择框或 autoReplace 覆盖。
        if let inFlight = czfInFlightInstall,
           inFlight.url == url && inFlight.autoReplace == autoReplace && inFlight.preview == preview && inFlight.forceAsNew == forceAsNew && inFlight.customDisplayName == customDisplayName {
            return
        }
        if pendingInstalls.contains(where: { czfIsSameInstallRequest(urlStr: url.absoluteString, autoReplace: autoReplace, preview: preview, forceAsNew: forceAsNew, customDisplayName: customDisplayName, as: $0) }) {
            return
        }
        installQueue.append((id: UUID(), url: url, autoReplace: autoReplace, preview: preview, forceAsNew: forceAsNew, customDisplayName: customDisplayName))
        guard !installQueueRunning else {
            return
        }
        installQueueRunning = true
        Task {
            var processed = 0
            var succeeded = 0
            var failedNames: [String] = []
            // 3.8.428 安装#2：取消单独列——不计成功也不计失败。
            var cancelledNames: [String] = []
            var batch = false
            // 预下载好的下一个安装包：装当前这个的同时，后台
            // 先把下一个下好，轮到它时直接装，省一半等待
            var prefetched: (url: URL, file: URL)? = nil
            // 3.8.559（L309-1）：本 Task 是裸 Task（enqueueInstall 非 @MainActor，LCAppListView 没标 @MainActor，L44 已证），跑全局执行器；installQueue/installQueueTotal/installQueueDone/installQueueCurrent 全是 @State——主线程 enqueueInstall 在 append/判重（:3378），排队页按钮还能 removeAll（:2029/:2041），这里 removeFirst/读 count 与主线程并发改同一份 Array，Swift 数组非线程安全、可能崩（L69 同款读-写竞态）；进度 @State 离主线程写还会丢更新（L44/L32 同款）。查空与出队一次回主线程做（只有本 Task 出队，append 只增不减，不会取空），进度同一跳写。
            while await MainActor.run(body: { !installQueue.isEmpty }) {
                let (item, remaining) = await MainActor.run { (installQueue.removeFirst(), installQueue.count) }
                if processed > 0 || remaining > 0 {
                    batch = true
                }
                await MainActor.run {
                    installQueueTotal = processed + 1 + remaining
                    installQueueDone = processed
                    installQueueCurrent = item.url.lastPathComponent
                }
                // 等手动触发的安装先装完，别互相抢
                // 3.8.428 安装#6：等的时候每秒查一次取消标志——
                // 用户点了进度条旁的取消，就跳过当前项、继续下一项。
                var czfWaitCancelled = false
                // 3.8.559（L309-1）：installprogressVisible/czfInstallCancelRequested 是 @State，写方在 installFromUrl 与进度条按钮；离主线程读会撞写（L70 同款）。每秒轮询一次回主线程读齐。
                while true {
                    let (visible, cancelled) = await MainActor.run { (installprogressVisible, czfInstallCancelRequested) }
                    guard visible else { break }
                    if cancelled {
                        czfWaitCancelled = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if czfWaitCancelled {
                    // 3.8.559（L309-1）：取消标志是 @State，回主线程清/写（同上）。
                    await MainActor.run {
                        czfInstallCancelRequested = false
                        czfLastInstallWasCancelled = true
                    }
                    cancelledNames.append(item.url.lastPathComponent)
                    // 上一轮可能已预下载了这一项的包，跳过就清掉，
                    // 别把临时 IPA 漏在 tmp 里。
                    if let pf = prefetched, pf.url == item.url {
                        try? FileManager.default.removeItem(at: pf.file)
                        prefetched = nil
                    }
                    processed += 1
                    // L309-1：进度回主线程写。
                    await MainActor.run { installQueueDone = processed }
                    continue
                }
                if batch {
                    // 批量期间下载弹窗保持用户上次的收起状态，
                    // 不然每个 App 都弹一次出来
                    downloadHelper.batchMode = true
                }
                // 本轮装哪个地址：有预下载好的就用本地文件
                var installStr = item.url.absoluteString
                var prefetchFile: URL? = nil
                if let pf = prefetched, pf.url == item.url {
                    installStr = pf.file.absoluteString
                    prefetchFile = pf.file
                    prefetched = nil
                }
                // 后台预下载队列里的下一个（用独立的下载器，
                // 不占界面上那个；下失败了轮到时走正常下载）。
                // 要弹预览确认的不预取——预取会把远程 URL 换成本地
                // 文件，文件分支不跑预览，第 2 个起直接装、没确认。
                var prefetchTask: Task<(URL, URL)?, Never>? = nil
                // 3.8.559（L309-1）：installQueue.first 离主线程读，与主线程 append 撞同一份 Array；回主线程取。
                let next = await MainActor.run { installQueue.first }
                if let next, !next.url.isFileURL, !next.preview {
                    let nextURL = next.url
                    prefetchTask = Task {
                        let helper = DownloadHelper()
                        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("CZFPrefetch-\(UUID().uuidString).ipa")
                        do {
                            try await helper.download(url: nextURL, to: dest)
                            return (nextURL, dest)
                        } catch {
                            return nil
                        }
                    }
                }
                // 3.8.428 安装#2：调用前清取消标记、调用后读——
                // 取消（抛 CZFInstallCancelled / 下载被取消 / 预览
                // 取消或超时 / 进度条旁取消）单独计取消数，不计
                // 成功也不计失败。
                // 3.8.559（L309-1）：czfLastInstallWasCancelled/czfInFlightInstall 是 @State，主线程 enqueueInstall/installFromUrl 入口读在途项判重；离主线程写会撞读（L70 同款）。装前清标志 + 记在途、装完一次取齐，全回主线程做；标志在 installFromUrl 内也被写（见组外线索），本 Task 这侧先收敛。
                await MainActor.run {
                    czfLastInstallWasCancelled = false
                    // O-9：在途项记下来供入队去重查（已出队、不在 installQueue 里）；
                    // 键用原始 item.url，不用预下载改写后的本地文件地址。
                    czfInFlightInstall = (url: item.url, autoReplace: item.autoReplace, preview: item.preview, forceAsNew: item.forceAsNew, customDisplayName: item.customDisplayName)
                }
                let installOK = await installFromUrl(urlStr: installStr, autoReplace: item.autoReplace, preview: item.preview, forceAsNew: item.forceAsNew, customDisplayName: item.customDisplayName, czfFromQueue: true)
                let wasCancelled = await MainActor.run {
                    let v = czfLastInstallWasCancelled
                    czfLastInstallWasCancelled = false
                    czfInFlightInstall = nil
                    return v
                }
                // 3.8.900（L564-5）：忙时门抢输的本项已重排回 pendingInstalls——
                // 循环每项只在迭代开头等手动安装，等待轮询读到空闲与入口门之间
                // 隔着预取 await，drain 可在其间抢先把门置真；入口门见忙就把
                // 本项重排回队、返回 false，旧代码不分辨原因直接按失败计，
                // 汇总写“失败：X”，而 X 根本没装（无预取时门还豁免排队、直接
                // 丢掉；有预取时排的是预取临时文件地址、随后又被删）。把重排
                // 的那一份从 pendingInstalls 里取回、把本项放回队尾，稍后重装
                // 时再计——不计失败、不计取消、不推进 processed；下面预取清理
                // 照走。取回与放回在同一次主线程跳里做，drain 抢不到中间态。
                // 3.8.900（607 修）：await 不能放在 && 链右边——编译器报
                // 'await' cannot appear to the right of a non-assignment
                // operator。先判条件，再单独 await 取结果。
                var czfDeferred = false
                if !wasCancelled && !installOK {
                    czfDeferred = await MainActor.run { () -> Bool in
                    guard pendingInstalls.contains(where: { czfIsSameInstallRequest(urlStr: installStr, autoReplace: item.autoReplace, preview: item.preview, forceAsNew: item.forceAsNew, customDisplayName: item.customDisplayName, as: $0) }) else { return false }
                    pendingInstalls.removeAll(where: { czfIsSameInstallRequest(urlStr: installStr, autoReplace: item.autoReplace, preview: item.preview, forceAsNew: item.forceAsNew, customDisplayName: item.customDisplayName, as: $0) })
                    installQueue.append(item)
                    return true
                    }
                }
                if czfDeferred {
                    // 延期重装：本轮不计入任何一类、不推进 processed。
                } else if wasCancelled {
                    cancelledNames.append(item.url.lastPathComponent)
                } else if installOK {
                    succeeded += 1
                } else {
                    failedNames.append(item.url.lastPathComponent)
                }
                if let prefetchFile {
                    try? FileManager.default.removeItem(at: prefetchFile)
                }
                if !czfDeferred {
                    processed += 1
                    // L309-1：进度回主线程写。
                    await MainActor.run { installQueueDone = processed }
                }
                // 预下载文件别漏：队里那一项被用户删掉/队列被清空时，
                // 旧 prefetched 没人再消费，下一句直接覆盖/循环
                // 退出就丢了引用，整包 IPA 烂在 tmp 里（CZFPrefetch-*
                // 全仓只有这里产生、无启动清理）。覆盖前先删旧文件；
                // 同 URL 换新文件也照删——下一项认新文件，不认旧的。
                if let oldPrefetched = prefetched {
                    try? FileManager.default.removeItem(at: oldPrefetched.file)
                }
                prefetched = await prefetchTask?.value ?? nil
            }
            // 队列中途被清空：循环退出时 prefetched 还攥着刚下好的包，
            // 没人消费，顺手删掉，别留整包 IPA 在 tmp 里。
            if let leftoverPrefetched = prefetched {
                try? FileManager.default.removeItem(at: leftoverPrefetched.file)
            }
            downloadHelper.batchMode = false
            // 3.8.559（L309-1）：队尾 @State（installQueueRunning/czfInstallCancelRequested）离主线程写；回主线程清。
            await MainActor.run {
                installQueueRunning = false
                // 3.8.499（L18）：队排空时清掉残留的取消标志——取消点在
                // 签名完成后的收尾步骤里（最后一处检查点之后）时，标志没
                // 人取、队里也没下一项可消耗它；不清掉，下次安装入口
                // :3412 会取走这个过期标志、白白记一次失败。队已空、
                // 没有在装的项，剩下的标志只可能是过期的，放心清掉。
                czfInstallCancelRequested = false
            }
            if processed > 1 {
                // 汇总分开报成功/失败并点名失败的：原来只报总数，
                // 装 10 个挂 3 个也显示"完成"，得逐个去核对
                // 3.8.428 安装#2：取消单独列出来，不混进成功/失败。
                if failedNames.isEmpty && cancelledNames.isEmpty {
                    // 3.8.559（L309-1）：installInfo/installInfoShow 是 @State，汇总弹窗离主线程写会丢更新；回主线程写。
                    await MainActor.run { installInfo = "批量安装完成：共 \(processed) 个，全部成功" }
                } else {
                    var czfSummary = "批量安装完成：成功 \(succeeded) 个"
                    if !failedNames.isEmpty {
                        czfSummary += "，失败 \(failedNames.count) 个"
                    }
                    if !cancelledNames.isEmpty {
                        czfSummary += "，取消 \(cancelledNames.count) 个"
                    }
                    if !failedNames.isEmpty {
                        czfSummary += "\n\n失败的：\n" + failedNames.joined(separator: "\n")
                    }
                    if !cancelledNames.isEmpty {
                        czfSummary += "\n\n取消的：\n" + cancelledNames.joined(separator: "\n")
                    }
                    // L309-1：同上。
                    await MainActor.run { installInfo = czfSummary }
                }
                // L309-1：同上。
                await MainActor.run { installInfoShow = true }
                notifyBatchDone(processed, succeeded: succeeded, failedNames: failedNames, cancelledNames: cancelledNames)
            }
        }
    }

    /// 批量安装全部完成时发一条本地通知：批量装十几个要
    /// 很久，用户切去干别的也能知道装完了（在 App 里时只
    /// 进通知中心，不弹横幅，靠顶部小条和汇总弹窗就够了）
    func notifyBatchDone(_ count: Int, succeeded: Int, failedNames: [String], cancelledNames: [String] = []) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "批量安装完成"
            // 3.8.428 安装#2：通知里也单独报取消数。
            if failedNames.isEmpty && cancelledNames.isEmpty {
                content.body = "共 \(count) 个应用，全部成功"
            } else {
                content.body = "成功 \(succeeded) 个，失败 \(failedNames.count) 个，取消 \(cancelledNames.count) 个：\((failedNames + cancelledNames).joined(separator: "、"))"
            }
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "CZFBatchInstall-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    /// 安装前预览文案：第 1 条——单条目流式抽取
    /// Payload/*.app/Info.plist 直接解析，不全量解压、不建
    /// 临时目录。读不到就返回 nil（不拦，照常安装）
    func makeInstallPreviewText(forIpa url: URL) async -> String? {
        let fm = FileManager.default
        guard let data = czfExtractIpaInfoPlist(url.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let bundleId = (plist["CFBundleIdentifier"] as? String) ?? "?"
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? bundleId
        let version = (plist["CFBundleShortVersionString"] as? String) ?? "?"
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        let sizeText = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber).map { fmt.string(fromByteCount: $0.int64Value) } ?? "?"
        let permissionMap: [(String, String)] = [
            ("NSCameraUsageDescription", "相机"),
            ("NSMicrophoneUsageDescription", "麦克风"),
            ("NSPhotoLibraryUsageDescription", "相册"),
            ("NSLocationWhenInUseUsageDescription", "定位"),
            ("NSLocationAlwaysAndWhenInUseUsageDescription", "定位"),
            ("NSContactsUsageDescription", "通讯录"),
            ("NSFaceIDUsageDescription", "Face ID"),
            ("NSBluetoothAlwaysUsageDescription", "蓝牙"),
            ("NSLocalNetworkUsageDescription", "本地网络"),
            ("NSUserTrackingUsageDescription", "跨 App 跟踪"),
            ("NSHealthShareUsageDescription", "健康数据"),
        ]
        var perms: [String] = []
        for (key, label) in permissionMap where plist[key] != nil && !perms.contains(label) {
            perms.append(label)
        }
        var lines = ["\(name)（版本 \(version)）", "Bundle ID：\(bundleId)", "大小：\(sizeText)"]
        lines.append(perms.isEmpty ? "声明的权限：无特殊权限" : "声明的权限：\(perms.joined(separator: "、"))")
        return lines.joined(separator: "\n")
    }

    /// 返回是否装成功：批量队列靠它分开统计成功/失败（原来
    /// 无返回值，汇总只能报"共处理 N 个"，挂了几个看不出来）。
    /// 单个安装的调用方不关心返回值，照旧靠 errorShow 弹窗
    @discardableResult
    // 出队一个接着装：Task 里跑，撞上正忙会重新排队，不丢不死循环
    private func drainPendingInstalls() {
        // 3.8.560（L311-1）：pendingInstalls 是 @State；drain 从 installFromUrl/installFromPlist 的 defer 与 startInstallApp 调来，全是离主线程的执行器——pop 回主线程做（Task 本身仍是裸 Task、跑全局执行器，安装活离主线程；pop 与起跑取取消标志之间无其他挂起点，L42 口径不变）。
        Task {
            let next = await MainActor.run { () -> CZFPendingInstall? in
                guard !pendingInstalls.isEmpty else { return nil }
                return pendingInstalls.removeFirst()
            }
            guard let next else { return }
            // 3.8.517（L42）：取消点在排水 Task 起跑前——正在装的
            // 那一项刚结束、defer 已把这一项出队并起了 Task，用户
            // 此时点进度条旁的取消：标志立起来后，下面
            // installFromUrl 的入口检查取走它、直接 return false，
            // 此时 defer 还没注册、链就断了——这一项静默丢掉不说，
            // 剩下排队的要等下一次安装才接着排（“排队中”一直挂
            // 着）。起跑时先取一次：取到就把这一项当取消、继续排
            // 下一项；取不到再正常装。起跑到入口检查之间没有挂起
            // 点，残留窗口只剩主线程点按与本 Task 读标志之间的竞
            // 态，可忽略。注意：.plist 项下载 plist 的几秒窗口里
            // 点取消仍走老路（内层 installFromUrl 入口取走标志、
            // 该项按取消丢掉、其余排队等下一次安装才续上），不
            // 在此批动——那一项本就是要取消的，残留只是续排晚
            // 一步。
            if await MainActor.run(body: { czfTakeInstallCancel() }) {
                // 3.8.527（L54）：起跑即取消的这一项若是
                // startInstallApp 排进来的 asCopy 临时副本，
                // 也按表删掉——不装就不留 tmp。
                // 3.8.560（L311-1）：czfFileImporterTmpToDelete 是静态 Set，删表回主线程做（插表在忙时门里已回主线程，表只在主线程碰，不再竞态）。
                await MainActor.run { Self.czfDeleteFileImporterTmp(next.urlStr) }
                drainPendingInstalls()
                return
            }
            switch next {
            case .url(let s, let r, let p, let f, let n):
                await installFromUrl(urlStr: s, autoReplace: r, preview: p, forceAsNew: f, customDisplayName: n)
                // 3.8.527（L54）：排空装完，按表删 asCopy 临时
                // 副本（installFromUrl 的 file 分支不删它）；不
                // 在表里的地址（源页/收件箱/直链）原样不动。
                // 3.8.560（L311-1）：同上，删表回主线程。
                // 3.8.572（L341-1）：忙时 installFromUrl 会把这一项重新排回 pendingInstalls（根本没装）——这时不能删 asCopy 临时副本，删了轮到它时文件已不在、装失败还得重选。
                // 触发口子现成：installFromPlist 的 defer 也调 drain，plist 下载要几秒、期间别的安装能起（plist 门只读 flag、不置 flag），defer 的 drain 正撞上忙时门；czfFinishInstall 后的 drain 同款（竞争安装落在清 flag 与门之间）。
                // 只在这一项不在队里了（装完/取消/校验失败都已出队）才删；查队回主线程做（pendingInstalls 是 @State）。
                let czfStillPending = await MainActor.run { pendingInstalls.contains(where: { czfIsSameInstallRequest(urlStr: s, autoReplace: r, preview: p, forceAsNew: f, customDisplayName: n, as: $0) }) }
                if !czfStillPending {
                    await MainActor.run { Self.czfDeleteFileImporterTmp(s) }
                }
            case .plist(let s):
                await installFromPlist(urlStr: s)
            }
        }
    }

    // 3.8.527（L54）：czfFileImporterTmpToDelete 的取删合一——
    // 在表里才删，不在表里不动；删失败（极少）不报错，tmp 由
    // 系统清。URL(string:) 解不出时只把表项清掉、不删文件。
    private static func czfDeleteFileImporterTmp(_ urlStr: String) {
        guard czfFileImporterTmpToDelete.remove(urlStr) != nil,
              let tmpURL = URL(string: urlStr) else { return }
        try? FileManager.default.removeItem(at: tmpURL)
    }

    // MARK: - 分享收件箱认领（3.8.404）
    // 收件箱条目种类（与 ShareExtension 的 ShareModels.swift
    // 同款结构，字段名/类型必须一致，JSON 解码靠它；ShareModels
    // 只在扩展靶编译，主 App 侧需自带一份）。
    private enum CZFShareInboxKind: String, Codable {
        case file // 安装 IPA/tIPA：bookmarkBase64 + fileURLString
        case launch // 在客 App 里打开：bundleName + containerFolderName + launchURL
        case sidestore // 经内置 SideStore 打开：launchURL（文件时附 bookmarkBase64）
    }
    /// 收件箱条目。路径：`<AppGroup>/LiveContainer/ShareInbox/<UUID>.json`，
    /// 扩展只写、主 App 前台认领后删除。date 为 ISO8601 字符串。
    private struct CZFShareInboxEntry: Codable {
        var version: Int = 1
        var kind: CZFShareInboxKind
        var date: String
        var fileName: String?
        var fileExtension: String?
        var fileURLString: String?
        var bookmarkBase64: String?
        var bundleName: String?
        var containerFolderName: String?
        var launchURL: String?
    }
    // 3.8.404：正在认领的收件箱文件（JSON 文件名集合）——冷打开时
    // onAppear 与 scenePhase .active 会连着触发两次扫，同一文件
    // 不能起两个安装任务（第二个会排进 pendingInstalls、装完又
    // 重装一遍）。认领中的文件跳过，任务结束（无论成败）再清掉，
    // 失败的文件留在收件箱里、下次前台重试。
    private static var czfClaimedInboxFiles = Set<String>()

    // 3.8.404：分享收件箱认领（主 App 侧）。ShareExtension 只写
    // 收件箱、不再拉起主 App；主 App 每次进前台（onAppear +
    // scenePhase .active）扫一遍 ShareInbox/*.json，按 date 从早
    // 到晚逐条处理：file 走 installFromUrl（先把扩展写的 bookmark
    // 写回 LCLaunchExtensionFileBookmark 键，installFromUrl 认这
    // 个键解析安全域外文件）；launch 按 bundleName 找已装客 App
    // 走 launchAppWithBundleId；sidestore 走内置 SideStore。
    // 成功删 JSON，失败留着下次重试；解不出的坏文件直接删，防
    // 每次前台都卡在它上面。注意：冷启动 3 秒认领窗口
    // （LCBootstrap.m）只认 LCLaunchExtension* 键，收件箱是
    // deferred 打开，不走那个窗口。
    private func czfClaimShareInbox() {
        let inboxDir = LCPath.lcGroupDocPath.appendingPathComponent("ShareInbox")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, entry: CZFShareInboxEntry)] = []
        for url in files where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(CZFShareInboxEntry.self, from: data) else {
                try? fm.removeItem(at: url)
                continue
            }
            entries.append((url, entry))
        }
        entries.sort { $0.entry.date < $1.entry.date }
        for (url, entry) in entries {
            let fileKey = url.lastPathComponent
            guard !Self.czfClaimedInboxFiles.contains(fileKey) else { continue }
            switch entry.kind {
            case .file:
                guard let fileURLString = entry.fileURLString else {
                    try? fm.removeItem(at: url)
                    continue
                }
                // 有安装在跑时跳过本次认领（文件留着下次前台再认）——
                // 否则 installFromUrl 会把这次排进 pendingInstalls，
                // 队里的那份装完 JSON 还在，下次前台又装一遍。
                guard !self.installprogressVisible else { continue }
                // 3.8.450：死条目预检——分享的 IPA 文件已删/书签失效
                // 时，installFromUrl 的书签解析会抛“该文件不存在”
                // 并弹错，失败又留 JSON 下次重试，每次进 App 页
                // 都弹一次（用户 23:21 报“更新个 IPA 一直弹窗”）。
                // 先验书签：解析抛错即文件已死，静默删 JSON、不装、
                // 不弹；解析成功（含 stale，文件可能只是挪了位置）
                // 才继续走安装。只验书签，不动无书签条目。
                if let b64 = entry.bookmarkBase64,
                   let bookmarkData = Data(base64Encoded: b64) {
                    var czfPreflightStale = false
                    do {
                        _ = try URL(resolvingBookmarkData: bookmarkData,
                                    options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                                    relativeTo: nil, bookmarkDataIsStale: &czfPreflightStale)
                    } catch {
                        try? fm.removeItem(at: url)
                        continue
                    }
                }
                if let b64 = entry.bookmarkBase64,
                   let bookmarkData = Data(base64Encoded: b64) {
                    LCUtils.appGroupUserDefault.set(bookmarkData, forKey: "LCLaunchExtensionFileBookmark")
                }
                Self.czfClaimedInboxFiles.insert(fileKey)
                Task {
                    let ok = await self.installFromUrl(urlStr: fileURLString)
                    if ok { try? fm.removeItem(at: url) }
                    // L58-1：本 Task 是裸 Task、跑在全局执行器上，
                    // czfClaimedInboxFiles 是静态 Set、其余读写
                    // （contains/insert）都在主线程——离主线程删
                    // 会与进页/切回前台的认领扫描竞态写坏 Set，
                    // 回主线程再删。
                    await MainActor.run { Self.czfClaimedInboxFiles.remove(fileKey) }
                }
            case .launch:
                guard let bundleName = entry.bundleName else {
                    try? fm.removeItem(at: url)
                    continue
                }
                // 只认已装的 App；没装就留着（以后装了再认领），
                // 不弹“找不到 App”。
                let found = sharedModel.apps.contains { $0.appInfo.relativeBundlePath == bundleName }
                    || (!LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding")
                        && sharedModel.hiddenApps.contains { $0.appInfo.relativeBundlePath == bundleName })
                guard found else { continue }
                Self.czfClaimedInboxFiles.insert(fileKey)
                Task {
                    // 3.8.578（L109）：启动失败也留着下次前台重试——
                    // 原来无论成败都删 JSON，人脸点了拒绝/启动抛错时
                    // 这次分享就丢了，用户得回客 App 重新分享；与
                    // .file 分支“成功删 JSON，失败留着下次重试”同款。
                    let ok = await self.launchAppWithBundleId(bundleId: bundleName, container: entry.containerFolderName, urlStr: entry.launchURL)
                    if ok { try? fm.removeItem(at: url) }
                    // L58-1：同上，裸 Task 里删静态 Set 回主线程。
                    await MainActor.run { Self.czfClaimedInboxFiles.remove(fileKey) }
                }
            case .sidestore:
                Self.czfClaimedInboxFiles.insert(fileKey)
                Task {
                    // 3.8.578（L109）：.launch 同款，启动失败留着重试。
                    let ok = await self.launchAppWithBundleId(bundleId: "builtinSideStore", container: nil, urlStr: entry.launchURL)
                    if ok { try? fm.removeItem(at: url) }
                    // L58-1：同上，裸 Task 里删静态 Set 回主线程。
                    await MainActor.run { Self.czfClaimedInboxFiles.remove(fileKey) }
                }
            }
        }
    }

    // O-9：安装去重键——四字段全等才算同一请求（url, autoReplace,
    // preview, forceAsNew）：只比 urlStr 会把同地址不同 autoReplace /
    // forceAsNew 的请求误丢；.plist 项没有这三个字段，不参与本比对。
    private func czfIsSameInstallRequest(urlStr: String, autoReplace: Bool, preview: Bool, forceAsNew: Bool, customDisplayName: String?, as pending: CZFPendingInstall) -> Bool {
        guard case .url(let s, let r, let p, let f, let n) = pending else { return false }
        return s == urlStr && r == autoReplace && p == preview && f == forceAsNew && n == customDisplayName
    }

    // O-9：安装入口共用校验（installFromUrl 与 installFromPlist 共用）：
    // trim + multiLCStatus==2 拦截 + URL 合法校验。返回 nil 表示已弹错，
    // 调用方直接 return。注意：installFromPlist 的 itms-services 解包在
    // 调它之前做（解出的才是真 plist 地址）；installFromUrl 的忙时排队与
    // 取消检查在调它之前做，顺序与原来一致。
    private func czfValidatedInstallURL(_ urlStr: String) -> URL? {
        let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return nil
        }
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return nil
        }
        guard let url = URL(string: trimmed) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return nil
        }
        return url
    }

    // 3.8.428 安装#2/#6：取走一次取消请求——进度条旁取消按钮
    // 置 czfInstallCancelRequested，调用方在这里取走；取到返回
    // true 并把 czfLastInstallWasCancelled 置 true（供
    // enqueueInstall 单独计取消数），取不到返回 false。
    private func czfTakeInstallCancel() -> Bool {
        guard czfInstallCancelRequested else { return false }
        czfInstallCancelRequested = false
        czfLastInstallWasCancelled = true
        return true
    }

    // 3.8.560（L311-1）：安装收尾共用——清进度标志 + 续排。flag 必须在
    // drain 起跑的下一项读到之前清掉（否则下一项看 busy 又排回
    // pendingInstalls、还被队里记一次失败）；defer 里不能 await，
    // 置 flag 的函数各 return 点显式调这里，不再用 defer 清 flag。
    private func czfFinishInstall() async {
        await MainActor.run { installprogressVisible = false }
        drainPendingInstalls()
    }

    // 3.8.900（L564-5）czfFromQueue：调用方是批量循环时传 true——循环的本项在调
    // 用前已记为在途项，忙时门若按“已在途”豁免排队，本项会被静默丢掉
    // （见门里注释）；直达安装路（网页/粘贴/深链/文件选择器）不传，
    // 正在装的同一请求仍按原来豁免、不重复排队。
    func installFromUrl(urlStr: String, autoReplace: Bool = false, preview: Bool = false, forceAsNew: Bool = false, customDisplayName: String? = nil, czfFromQueue: Bool = false) async -> Bool {
        // 3.8.428 App#4：粘贴的安装链接带首尾空格/换行就报“链接
        // 无效”，先 trim（与 installFromPlist 同款处理）。
        let urlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        // 3.8.428 安装#2：取消标记不在这里清——defer 里
        // drainPendingInstalls 可能并发起下一次安装，入口清会把
        // 上一次的取消标记冲掉；由 enqueueInstall 在每次调用前
        // 清、调用后读（见 enqueueInstall），这里只在取消路径置 true。
        // 进行中再点安装：排进队、当前装完接着装，不再静默丢掉
        // O-9：排队去重与 enqueueInstall 同款五字段键，且已在安装队列
        // 里或正在装的同一请求不再往 pendingInstalls 里加（原来只比
        // urlStr，同地址不同 autoReplace/forceAsNew 的请求会被误丢、
        // 已在队里/在途的又会重复排一份）。
        // 3.8.428 安装#6：进度条旁点了取消——还没开始装就直接
        // 按取消返回，不进下载/解包。
        // 3.8.556（L301-1）：下面两条 return 都在 defer 注册之前——不续排，
        // 队里剩下的要等下一次安装才接着排（installFromPlist 同款，L299-3
        // 已修；忙时排队那条 return 不补排是对的，正在装的那一项会续排）。
        // 校验失败能进队：忙时路只比去重、不校验，粘贴的坏链接（如带空格）
        // 先排队、排水时才在 czfValidatedInstallURL 失败；multiLCStatus 是
        // 启动时定值（Shared.init），不会半路变 2。
        // 3.8.560（L311-1）：门 + 取取消 + 校验 + 置 flag 一次回主线程做——四步原子在主线程上，中间不挂起。分开跳会在门与置 flag 之间留窗口：第二个并发调用会在第一个还没置 flag 时也通过门、两路同时装（原写法门到置 flag 间无挂起点、窗口只有几条同步语句；拆成四跳会把窗口放大到两次主线程往返）。czfTakeInstallCancel/czfValidatedInstallURL 保持同步、只在调用点包（签名不动）；忙时返回 (nil, true) 入队、取消/校验失败返回 (nil, false) 续排、放行返回 (url, false) 且 flag 已置。
        let (czfEntryURL, czfBusyQueued): (URL?, Bool) = await MainActor.run {
            if installprogressVisible {
                let item = CZFPendingInstall.url(urlStr, autoReplace, preview, forceAsNew, customDisplayName)
                let alreadyQueued = URL(string: urlStr).map { queuedURL in
                    installQueue.contains(where: { $0.url == queuedURL && $0.autoReplace == autoReplace && $0.preview == preview && $0.forceAsNew == forceAsNew && $0.customDisplayName == customDisplayName })
                } ?? false
                let alreadyInFlight = czfInFlightInstall.map { $0.url.absoluteString == urlStr && $0.autoReplace == autoReplace && $0.preview == preview && $0.forceAsNew == forceAsNew && $0.customDisplayName == customDisplayName } ?? false
                let alreadyPending = pendingInstalls.contains(where: { czfIsSameInstallRequest(urlStr: urlStr, autoReplace: autoReplace, preview: preview, forceAsNew: forceAsNew, customDisplayName: customDisplayName, as: $0) })
                // 3.8.900（L564-5）：批量循环的本项在调用前已记为在途项
                // （czfInFlightInstall），忙时门若按“已在途”豁免排队，本项
                // 既不在队里、也没进 pendingInstalls——静默丢掉，循环还按
                // 失败计一次。循环的本项不是“别处正在装的重复请求”，它根本
                // 还没装，豁免对它不适用：循环调用时（czfFromQueue）照排；
                // 直达路仍按原来豁免，正在装的同一请求不重复排队。
                if !alreadyQueued && !alreadyPending && (!alreadyInFlight || czfFromQueue) {
                    pendingInstalls.append(item)
                }
                return (nil, true)
            }
            if czfTakeInstallCancel() {
                return (nil, false)
            }
            // O-9：入口校验走共用函数（trim + multiLCStatus + URL 合法，
            // 与 installFromPlist 同款）；忙时排队与取消检查已在前面做过，
            // 顺序与原来一致。
            guard let installUrl = czfValidatedInstallURL(urlStr) else {
                return (nil, false)
            }
            // defer 里不能 await，收尾改走 czfFinishInstall()（各 return 点显式调），这里不再挂 defer。
            self.installprogressVisible = true
            return (installUrl, false)
        }
        if czfBusyQueued {
            return false
        }
        guard var installUrl = czfEntryURL else {
            drainPendingInstalls()
            return false
        }

        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写；收尾走 czfFinishInstall()（清 flag + 续排）。
                await MainActor.run {
                    errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                    errorShow = true
                }
                await czfFinishInstall()
                return false
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    // 安装低 #20：解析侧 withSecurityScope = 1 << 10——
                    // iOS 上该具名常量标了 unavailable（429 实证
                    // 编不过），只能用 rawValue；抽成具名量，
                    // 不再裸写魔数。书签旧了也别直接丢：解析出的
                    // URL 多半还能用，先返回再重存一份新书签
                    // （与 CZFLocalIpaFolderStore.restore 同款处理）。注意
                    // 重存是创建侧，withSecurityScope = 1 << 11，
                    // 不是解析侧的 1 << 10（1 << 10 在创建侧是
                    // suitableForBookmarkFile，建出来不带 scope，
                    // 重启后又没权——文件夹 443 同款教训）。
                    let czfWithSecurityScope: UInt = 1 << 10
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: czfWithSecurityScope),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    if isStale {
                        // 3.8.447：重存书签前先 startAccessing 再建
                        //（文件夹同款真因：没 startAccessing 就建
                        // scope 书签会静默失败）。建完先停掉，
                        // 下面 didStartAccessing 再为本次安装起一次。
                        let started = resolvedURL.startAccessingSecurityScopedResource()
                        if let newData = try? resolvedURL.bookmarkData(
                            options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
                            includingResourceValuesForKeys: nil, relativeTo: nil) {
                            LCUtils.appGroupUserDefault.set(newData, forKey: "LCLaunchExtensionFileBookmark")
                        }
                        if started { resolvedURL.stopAccessingSecurityScopedResource() }
                    }
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写；收尾走 czfFinishInstall()。
                    await MainActor.run {
                        errorInfo =  "读取共享的 IPA 文件失败：\(LCUtils.czfFriendlyError(error))"
                        errorShow = true
                    }
                    await czfFinishInstall()
                    return false
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写；收尾走 czfFinishInstall()。
                await MainActor.run {
                    errorInfo = "lc.appList.ipaAccessError".loc
                    errorShow = true
                }
                await czfFinishInstall()
                return false
            }
            
            // 3.8.428 安装#3：文件夹弹窗点安装就关 sheet，模型
            // deinit 会 stopAccessing，大包解包中途可能丢访问权；
            // 文件若在 CZFLocalIpaFolderBookmark 记住的文件夹里，
            // 这里用文件夹书签重新取权再解包（与
            // CZFLocalIpaFolderStore.restore 同款取法），用完释放；
            // 文件夹模型本身的 deinit 不动。
            var czfFolderURL: URL? = nil
            var czfFolderAccessHeld = false
            if let folderURL = CZFLocalIpaFolderStore.restore(),
               installUrl.standardizedFileURL.path.hasPrefix(folderURL.standardizedFileURL.path + "/") {
                czfFolderURL = folderURL
                czfFolderAccessHeld = folderURL.startAccessingSecurityScopedResource()
            }
            defer {
                if czfFolderAccessHeld, let folderURL = czfFolderURL {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }

            // 3.8.428 安装#6：解包前再查一次取消——进度条旁点取消
            // 后，正在等前一个安装的这一项轮到时直接按取消返回。
            // 3.8.560（L311-1）：czfTakeInstallCancel 读写 @State 标志，回主线程取（body: 标签，610 同款）；收尾走 czfFinishInstall()。
            if await MainActor.run(body: { czfTakeInstallCancel() }) {
                await czfFinishInstall()
                return false
            }

            var installOK = true
            do {
                try await installIpaFile(installUrl, autoReplace: autoReplace, forceAsNew: forceAsNew, customDisplayName: customDisplayName)
            } catch is CZFInstallCancelled {
                // 3.8.428 安装#2：取消不弹错、不计失败，记取消。
                // 3.8.560（L311-1）：czfLastInstallWasCancelled 是 @State，回主线程写。
                await MainActor.run { czfLastInstallWasCancelled = true }
                installOK = false
            } catch {
                installOK = false
                // 3.8.900（L564-4）：本地分支失败也先取进度条旁 ✕ 的标志——
                // ✕ 点在解包/签名轮询间隙（或签名后检查点之后）又恰好抛错时，
                // 旧代码直接弹错、标志还残留到下一项（入口取走当取消、白白
                // 跳过一项）。取到就按取消计、不弹错（take 已置
                // czfLastInstallWasCancelled，循环记取消）；取不到再弹错。
                if await MainActor.run(body: { czfTakeInstallCancel() }) {
                    // 取消，不弹错。
                } else {
                    // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写。
                    await MainActor.run {
                        errorInfo = LCUtils.czfFriendlyError(error)
                        errorShow = true
                    }
                }
            }

            // I2：只有安装成功才删 Inbox 源 IPA；安装失败时
            // 留着源文件，方便用户重试 / 排查。
            if installOK {
                // 3.8.900（L564-4）：装成了才清残留的取消标志——✕ 点在
                // 签名后最后检查点（:3132）之后时，标志没人取；L18 只在队
                // 排空时清，队里还有下一项就会漏过去、下一项入口取走当
                // 取消、白白跳过一项。本项已装成，针对本项的取消已过期，
                // 在这里清掉；清与 ✕ 点按之间只隔一次主线程跳，窗口可忽略。
                await MainActor.run { czfInstallCancelRequested = false }
                do {
                    // delete ipa if it's in inbox
                    var shouldDelete = false
                    if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                        let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                        shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                    }
                    if shouldDelete {
                        try fm.removeItem(at: installUrl)
                    }
                    // 3.8.503（L25）：网页下载的 .ipa 落在本次下载独占的
                    // tmp 子目录 LCWebDownload-<UUID>/（L24），装完整个
                    // 子目录没人清——每个成功下载留一个目录 + 一个 IPA
                    // 在 tmp 里（失败的按 I2 同款留着）。只成功才删；
                    // 排队路径在 installIpaFile 之前就 return false，
                    // 走到这里的一定是本次真正执行完的安装，删了不
                    // 影响重试。
                    // 3.8.527（L54）：只认名字不够——用户在“文件”
                    // 里建个同名 LCWebDownload-xxx 文件夹、里面放
                    // IPA，装完也会被整目录删掉。再认位置：父目录
                    // 必须是 tmp 下的直接子目录（L24 的下载目的地
                    // 就是 tmp/LCWebDownload-<UUID>/）；标准化后比，
                    // /var 与 /private/var 两种写法都对得上。
                    var czfTmpPath = fm.temporaryDirectory.standardizedFileURL.path
                    if czfTmpPath.hasSuffix("/") { czfTmpPath.removeLast() }
                    let czfParentPath = installUrl.deletingLastPathComponent().standardizedFileURL.path
                    if installUrl.deletingLastPathComponent().lastPathComponent.hasPrefix("LCWebDownload-"),
                       czfParentPath.hasPrefix(czfTmpPath + "/") {
                        try fm.removeItem(at: installUrl.deletingLastPathComponent())
                    }
                } catch {
                    // 清理本身失败只记日志，不重写 errorInfo
                    print("delete inbox ipa failed: \(error)")
                }
            }
            // 3.8.560（L311-1）：收尾走 czfFinishInstall()（清 flag + 续排，原 defer 的活）。
            await czfFinishInstall()
            return installOK
        }
        
        // 3.8.428 安装#2：fileManager/destinationURL 提到 do 外面，
        // 下面那个 catch is CZFInstallCancelled 里要清临时包，
        // do 里声明的变量 catch 里够不到。
        let fileManager = FileManager.default
        // 朋友源下载链接最后一段常是裸 UUID（无 .ipa 后缀），多次
        // 装/重试/并发都撞同一个 tmp 路径——下载完 moveItem 报
        // “已存在同名项目”（真机两张截图同款）。每次安装前缀一
        // 段 UUID，落盘路径唯一，彻底避开残留与并发撞名；原文件
        // 名（含后缀）原样保留在后面。
        // 链接没有文件名时 lastPathComponent 为空，用默认名兜底，
        // 避免落盘文件名只剩 “<UUID>-” 这种怪名。
        let czfBaseName = installUrl.lastPathComponent.isEmpty ? "app.ipa" : installUrl.lastPathComponent
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(czfBaseName)")
        // O-8：远程下载的 IPA 只在安装成功时删（与本地 Inbox 路径“只成功
        // 才删”对齐）：installIpaFile 抛错/取消时不删，留着方便重试；
        // 删包失败本身不算安装失败（本地 Inbox 路同款 try?）。
        var czfRemoteInstallOK = false
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            // 安装低 #16：下载阶段导航栏进度条原来停在 0——
            // installProgressPercentage 只在 installIpaFile 内
            // 更新。下载时把下载进度同步过来（占前 20%，与
            // installIpaFile 里解包 80 + 签名 20 的配比一致）；
            // 下载完停掉，解包开始时 installIpaFile 从 0 重走。
            // H-7：原来 0.1 秒轮询读 downloadHelper.downloadProgress；
            // 进度本来就是 @Published（LCDownloadView 节流回调里发布，
            // 1%/0.25s 口径不动），直接订阅它，变化才写进度条，
            // 轮询 Task 删掉；函数返回时 defer 取消订阅。
            // czfLastShown 先取当前值，订阅瞬间那下不重复写。
            var czfLastShown: Float = self.downloadHelper.downloadProgress * 0.2
            let czfDownloadProgressCancellable = downloadHelper.$downloadProgress.sink { progress in
                let czfShown = progress * 0.2
                if czfShown != czfLastShown {
                    czfLastShown = czfShown
                    self.installProgressPercentage = czfShown
                }
            }
            defer { czfDownloadProgressCancellable.cancel() }

            // 3.8.900（L564-3）：下载时把进度条旁 ✕ 的标志以检查闭包传进
            // download()——下载器在途期间每 0.5 秒读一次、读到就停本次下载；
            // 闭包只读不取标志，标志由下面下载后检查点/失败 catch 取走。
            try await downloadHelper.download(url: installUrl, to: destinationURL, czfCancelRequested: { await MainActor.run { czfInstallCancelRequested } })
            if downloadHelper.cancelled {
                // 3.8.428 安装#2：用户取消下载=取消，不计失败。
                // 3.8.560（L311-1）：czfLastInstallWasCancelled 是 @State，回主线程写；收尾走 czfFinishInstall()。
                await MainActor.run { czfLastInstallWasCancelled = true }
                await czfFinishInstall()
                return false
            }
            // 3.8.428 安装#6：下载完、解包前再查一次取消。
            // 3.8.560（L311-1）：czfTakeInstallCancel 读写 @State 标志，回主线程取（body: 标签，610 同款）；收尾走 czfFinishInstall()。
            if await MainActor.run(body: { czfTakeInstallCancel() }) {
                try? fileManager.removeItem(at: destinationURL)
                await czfFinishInstall()
                return false
            }
            if preview, let text = await makeInstallPreviewText(forIpa: destinationURL) {
                // 下完了先弹信息卡：用户点「安装」才继续，
                // 点「取消」删掉临时包、什么都不装
                let proceed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    // 3.8.560（L311-1）：installPreviewContinuation/Text/Show 是 @State；本闭包跑在裸 Task 的执行器上，直接写离主线程。continuation 由 withCheckedContinuation 同步创建、alert 靠 Show 弹出——三处回主线程写（Task 跳，alert 晚一拍弹出，不影响按钮/超时取 continuation：按钮在主线程读，超时 Task 也回主线程取）。
                    Task { @MainActor in
                        installPreviewContinuation = cont
                        installPreviewText = text
                        installPreviewShow = true
                    }
                    // 3.8.428 设置#24：预览 alert 挂着 continuation，
                    // 若被别的 alert 顶掉就永远挂起；5 分钟超时自动
                    // 按取消 resume（与安装#2 的取消信号打通）。
                    // 按钮与超时都在主线程串行，先抢到 continuation
                    // 的那方 resume 并置 nil，另一方看到 nil 不动，
                    // resume 只调一次。
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000_000)
                        await MainActor.run {
                            if let cont = installPreviewContinuation {
                                installPreviewContinuation = nil
                                installPreviewShow = false
                                cont.resume(returning: false)
                            }
                        }
                    }
                }
                if !proceed {
                    // 3.8.428 安装#2：预览点取消或超时=取消，不计失败。
                    // 3.8.560（L311-1）：czfLastInstallWasCancelled 是 @State，回主线程写；收尾走 czfFinishInstall()。
                    await MainActor.run { czfLastInstallWasCancelled = true }
                    try? fileManager.removeItem(at: destinationURL)
                    await czfFinishInstall()
                    return false
                }
            }
            // 3.8.527（L54）：远程分支原来没传 customDisplayName，
            // 本地分支 :3665 完整传入——恢复缺失分身的远程路
            // （带 forceAsNew + 预设名）会走到这里弹输名框、
            // 等待循环等满 5 分钟报失败；补传，与本地同款。
            try await installIpaFile(destinationURL, autoReplace: autoReplace, forceAsNew: forceAsNew, customDisplayName: customDisplayName)
            czfRemoteInstallOK = true
        } catch is CZFInstallCancelled {
            // 3.8.428 安装#2：安装中途取消（替换选择/输名/运行中
            // 确认），清掉临时包、不弹错，记取消。
            // 3.8.560（L311-1）：czfLastInstallWasCancelled 是 @State，回主线程写。
            await MainActor.run { czfLastInstallWasCancelled = true }
            try? fileManager.removeItem(at: destinationURL)
        } catch {
            // 3.8.900（L564-4）：下载失败先取进度条旁 ✕ 的标志——✕ 点在
            // 下载中、下载又恰好失败时，旧代码只查 downloadHelper.cancelled
            // （✕ 不走下载弹窗、不置它），于是取消的安装先弹“下载失败”错、
            // 循环再按失败计，残留标志还漏到下一项（入口取走当取消、白白
            // 跳过一项）。取到就按取消计、不弹错（take 已置
            // czfLastInstallWasCancelled，循环记取消）；取不到再分
            // 下载弹窗取消/真失败。
            if await MainActor.run(body: { czfTakeInstallCancel() }) {
                try? fileManager.removeItem(at: destinationURL)
            } else if downloadHelper.cancelled {
                // L50-2：下载弹窗点了取消时 download() 是抛错出来
                // （URLErrorCancelled），不是正常返回——上面那个
                // `if downloadHelper.cancelled` 检查走不到。走到这
                // 里且 cancelled 为真就是取消，照 3.8.428 安装#2 的
                // 本意：不弹错、记取消（源页 czfDownloadVersionTo
                // 同款：cancelled 就不报 errorMessage）；只有真
                // 失败才弹错。
                // 3.8.560（L311-1）：czfLastInstallWasCancelled 是 @State，回主线程写。
                await MainActor.run { czfLastInstallWasCancelled = true }
                try? fileManager.removeItem(at: destinationURL)
            } else {
                // 3.8.603（O-15）：真失败也清临时包——与取消路对称，
                // 不留 tmp/<文件名>.ipa 残留；失败原因照常弹错。
                try? fileManager.removeItem(at: destinationURL)
                // 3.8.560（L311-1）：errorInfo/errorShow 是 @State，回主线程写。
                await MainActor.run {
                    errorInfo = LCUtils.czfFriendlyError(error)
                    errorShow = true
                }
            }
        }
        if czfRemoteInstallOK {
            // 3.8.900（L564-4）：远程分支装成也清残留取消标志——与本地分支
            // 同款：✕ 点在签名后最后检查点之后时标志没人取，L18 只在队排空
            // 时清，队里还有下一项就会漏过去、白白跳过一项。本项已装成，
            // 针对本项的取消已过期，在这里清掉。
            await MainActor.run { czfInstallCancelRequested = false }
            try? fileManager.removeItem(at: destinationURL)
        }
        // 3.8.560（L311-1）：收尾走 czfFinishInstall()（清 flag + 续排，原 defer 的活）。
        await czfFinishInstall()
        return czfRemoteInstallOK
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            // 3.8.561（L265-1）：32 位表也要一起摘——arm32EmuApps 只在冷启动扫描时重建（LiveContainerSwiftUIApp:44），删 App 只摘 apps/hiddenApps，删掉的 32 位 App 一直留在两个模拟器选择器里；被删的若是全局默认模拟器（LCSelected32BitEmulator），之后所有 32 位启动都在 LCBootstrap 报“The specified 32-bit emulator app is not found”起不来，只能亲手重选；B-12 的变空清理（LCSettingsView:257-259）也因表 mid-session 永不变空而永不触发。
            sharedModel.arm32EmuApps.removeAll { now in
                return app == now
            }
            // 3.8.568（L322-1）：删 App 也要取消它排进 deferredEnsureApps 的启动请求——L295-1 只修了关窗那路（K:591）；测速窗口内起 App 后删掉它，收尾补跑会把核心起在已删 App 的节点上，起后无人能停（V:1050-1061 注释自述）。删只走 removeApp 这一个漏斗（单删/批量/网格三路全经它），用传入 model 自身的 appInfo 取消，不查表；没排进的取消是空操作。
            CZFVPNManager.shared.cancelDeferredEnsure(for: app.appInfo)
            // 删 App 后 AppInfo 缓存与 dock 残留条目一起清，否
            // 则删掉的 App 还会按旧 LCAppInfo 被解析、旧 dock
            // 条目还会被顶回前台（MultitaskDockManager 是
            // iOS 16+ 类，必须用 #available 包住）。
            if #available(iOS 16.0, *) {
                MultitaskDockManager.refreshAfterAppChanged()
            }
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    // 3.8.578（L109）：返 Bool 供分享收件箱认领用——启动失败
    // 也要留着 JSON 下次前台重试（.file 分支同款口径）；其余
    // 三处调用点忽略返回值，@discardableResult 覆盖。
    @discardableResult
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async -> Bool {
        if bundleId == "" {
            return false
        }
        // 3.8.578（L391-1）：L233 只修了 isLocked 读、漏了这两段扫表本身——本函数从通知（:2416）/收件箱（:3996/:4005）/网格（:1769 经 czfGridLaunch 裸 Task）/深链（:4838）的裸 Task 调来，声明 :4478 头上无 @MainActor；这里 for 循环直接读 sharedModel.apps/hiddenApps（@Published 数组），主线程安装完成（:3154）/删除（:4425）/显隐切换（:4448）改同一份数组时与这里的读并发，Swift 数组非线程安全、可能崩（L383-1/L371-1 同款；relativeBundlePath 是 ivar、直读安全，危险的是数组本身）。两段扫表一次回主线程取齐再分支，顺序与匹配条件不动；命中那条的 isLocked 也在主线程上顺手取（L233 的内层 MainActor.run 不再需要），隐藏区命中仍按原义直接算锁住。
        let foundResult: (LCAppModel?, Bool) = await MainActor.run {
            for app in sharedModel.apps {
                if app.appInfo.relativeBundlePath == bundleId {
                    return (app, app.appInfo.isLocked)
                }
            }
            if !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                for app in sharedModel.hiddenApps {
                    if app.appInfo.relativeBundlePath == bundleId {
                        return (app, true)
                    }
                }
            }
            return (nil, false)
        }
        var appFound = foundResult.0
        var isFoundAppLocked = foundResult.1
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return false
                }
            } catch {
                // 3.8.519（L44）：本函数从通知/深链/网格启动的裸 Task
                // 调来、不在主 actor 上（L40 同款），errorInfo/errorShow
                // 是 @State，回主线程再写；下面两处同款。
                await MainActor.run {
                    errorInfo = error.localizedDescription
                    errorShow = true
                }
                return false
            }
        }
        
        guard let appFound else {
            await MainActor.run {
                errorInfo = "lc.appList.appNotFoundError".loc
                errorShow = true
            }
            return false
        }

        // 3.8.563（L287-1）：内置 SideStore 的 relativeBundlePath 是 nil
        // （LCAppInfo.h:24 只声明、从不赋值），runApp 没 bundleIdOverride
        // 时直接拿它写 "selected" 键——UserDefaults.set(nil) 等于删键；
        // 客端 LCBootstrap.m:961 的门（selectedApp || isSideStore）双空、
        // invokeAppMain 不跑，收件箱 .sidestore 这路就静默落回 LC 自身 UI、
        // 还把收件箱 JSON 当成功删了。openSideStore（LCUtilsExtensions:972）
        // 同款早已传 bundleIdOverride，这里补上才对齐；普通 App 的
        // bundleId 就是 relativeBundlePath，传 nil 走老路、不变。
        let bundleIdOverride = bundleId == "builtinSideStore" ? "builtinSideStore" : nil
        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, bundleIdOverride: bundleIdOverride, urlStr: urlStr, forceJIT: forceJIT)
            return true
        } catch {
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return false
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            // 3.8.519（L44）：本函数从隐藏 App 解锁三路的裸 Task 调来、
            // 不在主 actor 上（L40 同款），errorInfo/errorShow 是 @State，
            // 回主线程再写（人脸标志本身已由 L34 在 MainActor.run 里置）。
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt, selectedBundlePath: String?, selectedContainerFolder: String?, launchURL: String?) async -> Bool {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode, selectedBundlePath: selectedBundlePath, selectedContainerFolder: selectedContainerFolder, launchURL: launchURL)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt, selectedBundlePath: String?, selectedContainerFolder: String?, launchURL: String?) async -> Bool {
        await MainActor.run {
            jitLog = ""
        }
        // 跳错修复：确认前不写启动键、不启动 JIT 任务。旧代码
        // 两者都在确认前跑，弹框 pending 时面板窗点别的 App
        // 会覆盖三键；且 TrollStore 分支确认前就提前启动，
        // 所以写键与启动任务必须一起挪到确认后，缺一不可
        // （只挪键会修坏 TrollStore，只挪任务则竞态仍在）。
        guard let result = await jitAlert.open(), result else {
            // 取消（含滑掉 sheet）：只删自己这次的键——当前
            // selected/selectedContainer 仍等于本次启动值时
            // 才删，否则那是别的启动写的键，一律不动；删时
            // 成对删 selected 与 selectedContainer，不留一半。
            if UserDefaults.standard.string(forKey: "selected") == selectedBundlePath,
               UserDefaults.standard.string(forKey: "selectedContainer") == selectedContainerFolder {
                UserDefaults.standard.removeObject(forKey: "selected")
                UserDefaults.standard.removeObject(forKey: "selectedContainer")
            }
            // 取消返 false：调用方不盖“最近启动”。
            return false
        }
        // 确认后：先写键，再启动 JIT 任务（TrollStore 分支
        // 此时提前启动读到的是新鲜键），最后走原有 launch。
        // launchAppUrlScheme 只在有 url 时写，与旧写键一致。
        UserDefaults.standard.set(selectedBundlePath, forKey: "selected")
        if let launchURL {
            UserDefaults.standard.setValue(launchURL, forKey: "launchAppUrlScheme")
        }
        UserDefaults.standard.set(selectedContainerFolder, forKey: "selectedContainer")
        Task {
            // askForJIT 失败时只往 jitLog 写一句话，但 modal 已关、用户看不到；
            // 直接开 URL 的工具（StikJIT/StosDebug）返回 false 即没打开，
            // 在主列表弹一次错误提示。其它工具（经别的 App/服务器继续）
            // 本来就返回 false，不当失败处理。
            var lastMsg = ""
            let ok = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                lastMsg = newMsg
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            let enabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType"))
            if !ok, enabler == .StikJIT || enabler == .StosDebug {
                await MainActor.run {
                    if !lastMsg.isEmpty {
                        self.errorInfo = lastMsg
                        self.errorShow = true
                    }
                }
                return
            }
            guard let _ = enabler else {
                return
            }
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
        // 真启动才返 true，调用方盖“最近启动”。
        return true

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    // App 名含空格时 URL(string:) 直接返回 nil，旧代码静默失败；
                    // 先 percent-encoding 再拼，拼不出给提示而不是无反应。
                    // L60-1：名里带 & 时 urlQueryAllowed 会放行它、接收侧从
                    // & 处切断，改走 czfQueryValueAllowed（排除 &）。
                    let encodedAppName = appName.addingPercentEncoding(withAllowedCharacters: .czfQueryValueAllowed) ?? appName
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(encodedAppName)&pid=\(pid)&relaunchApp=false&forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            } else {
                                errorInfo = "Failed to build JIT URL."
                                errorShow = true
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(encodedAppName)&pid=\(pid)&forcePID=true\(encoded)") {
                            // StosDebug 没装时旧代码直接开、返回值丢掉，静默无事；
                            // open 返回 false 就弹提示。注：不用 canOpenURL，
                            // stosdebug 不在 LSApplicationQueriesSchemes 里。
                            // 注2：这里在 MainActor.run 同步闭包里，不能 await
                            //（await 会让闭包变 async，MainActor.run 不接受）；
                            // 用 completionHandler 版判失败，回调里回主线程写提示。
                            UIApplication.shared.open(url, options: [:]) { opened in
                                if !opened {
                                    Task { @MainActor in
                                        self.errorInfo = "StosDebug 未安装/打不开，请先安装 StosDebug"
                                        self.errorShow = true
                                    }
                                }
                            }
                        } else {
                            errorInfo = "Failed to build JIT URL."
                            errorShow = true
                        }
                    }
                    return
                }

                // 非 Stik 系 JIT 方式（SideJITServer/JITStreamer/SideStore）
                // 没有多任务 JIT 路：原来无条件拼 stikjit URL，报的却是
                // “StikDebug 未安装”假错、JIT 根本不尝试。先拦住，报实情。
                guard jitEnabler == .StikJIT || jitEnabler == .StikJITLC else {
                    errorInfo = "当前 JIT 方式不支持多任务 JIT，请改用 StikDebug/StosDebug"
                    errorShow = true
                    return
                }

                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        // StikDebug 没装时旧代码直接开、返回值丢掉，静默无事；
                        // open 返回 false 就弹提示。注：不用 canOpenURL，
                        // stikjit 不在 LSApplicationQueriesSchemes 里。
                        // 注2：这里在 MainActor.run 同步闭包里，不能 await
                        //（await 会让闭包变 async，MainActor.run 不接受）；
                        // 用 completionHandler 版判失败，回调里回主线程写提示。
                        UIApplication.shared.open(url, options: [:]) { opened in
                            if !opened {
                                Task { @MainActor in
                                    self.errorInfo = "StikDebug 未安装/打不开，请先安装 StikDebug 2.3.0+"
                                    self.errorShow = true
                                }
                            }
                        }
                    }
                } else {
                    errorInfo = "Failed to build JIT URL."
                    errorShow = true
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            // 启动失败要报出来，别静默吞掉（见 openSideStore 的 onError）。
            LCUtils.openSideStore(delegate: self) { error in
                Task {
                    await MainActor.run {
                        errorInfo = error.localizedDescription
                        errorShow = true
                    }
                }
            }
            return
        }
        // 设置低 #48：sidestore 链接但没装 SideStore，原来静默
        // return、deepLink 还被先清掉，链接丢了也没提示；弹一次错。
        if url.scheme == "sidestore" {
            errorInfo = "未安装 SideStore，无法打开此链接"
            errorShow = true
            return
        }

        if url.host == "open-web-page" || url.host == "open-url" {
            // App #26：解码失败原来静默 return，调方以为链接已
            // 打开；解不开就弹一次错误提示。
            // 设置低 #51：只取 queryItems?.first 会解错——链接带
            // 多余参数时 first 未必是 url；按名取 url/open-url。
            guard let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let queryItem = urlComponent.queryItems?.first(where: { $0.name == "url" || $0.name == "open-url" }),
                  !(queryItem.value?.isEmpty ?? true),
                  let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                  let decodedUrl = String(data: decodedData, encoding: .utf8) else {
                errorInfo = "打开网页链接失败：链接无效或已损坏"
                errorShow = true
                return
            }
            Task { await openWebView(urlString: decodedUrl) }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                } else if bundleId == nil {
                    // R-8：缺 bundle-name 参数原来静默无事，调方以为
                    // 已启动；补一次提示，与 open-web-page 分支同款
                    // errorInfo/errorShow。bundleId == "ui" 是“只打开
                    // LiveContainer 界面”的约定，本来就不启动 App，
                    // 保持静默。
                    errorInfo = "启动 App 失败：链接里没有 bundle-name 参数"
                    errorShow = true
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                } else {
                    // R-8：缺 url 参数原来静默无事，补一次提示。
                    errorInfo = "安装失败：链接里没有 url 参数"
                    errorShow = true
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}

// 优2（3.8.277）：行拖放代理——只在 performDrop 里提交（松手即写），
// 拖动过程中不改 customSortOrder（免得 didSet 每过一行就刷一次
// 设置备份文件）。搜索时不启用（见 ForEach 处）。
// 网格拖拽重排复用（3.8.453）：原来 private 只给列表模式用；
// 网格模式长按拖图标排序走同一份 DropDelegate，不再各写一套。
struct LCAppReorderDropDelegate: DropDelegate {
    let targetApp: LCAppModel
    let draggedID: () -> String?
    let commit: (String, LCAppModel) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = draggedID() else { return false }
        commit(dragged, targetApp)
        return true
    }
}
