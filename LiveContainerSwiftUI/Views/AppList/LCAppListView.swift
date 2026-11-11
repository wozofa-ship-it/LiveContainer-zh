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
}

// 待安装队列项：url 安装与 plist 安装共用一个队（cases 与
// urlStr 原样保留，供 pendingInstalls 去重用）。
// 3.8.428 设置#25：跨页待装队列不在这里——原来挂的 static
// urls: [URL] 只存地址，三处来源的 autoReplace / preview /
// forceAsNew 全丢了（批量丢 autoReplace、单装丢 preview、
// 新建丢 preview + forceAsNew），已移到下面的
// CZFSourcePendingInstall（四字段齐全），urls 已删。
private enum CZFPendingInstall {
    case url(String, Bool, Bool, Bool)
    case plist(String)
    var urlStr: String {
        switch self {
        case .url(let s, _, _, _): return s
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
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    // 本地 IPA 文件夹（3.8.423）：+ 号旁的文件夹按钮，选一个
    // 文件夹，列里面的 IPA 点一下安装；文件夹用 bookmark 记住。
    @State var czfIpaFolderPickerShow = false
    @State var czfIpaFolderURL: URL? = nil
    @State var czfIpaFolderSheetShow = false
    // 3.8.428 安装#4：换文件夹标记——点“换文件夹”时只关 sheet
    // 并置这个标记，等 sheet 的 onDismiss 回调里再弹选择器；
    // 同一代码块里 sheet=false + picker=true 时选择器可能弹不出。
    @State private var czfIpaFolderChangeRequested = false
    // 3.8.429 文件夹选完没反应标记：选完文件夹后等 picker 关完
    // 再弹 IPA 网格 sheet（见下面 betterFolderImporter 的
    // onDismiss）；回调里直接 sheet=true 时 picker 还在上面，
    // sheet 会被 UIKit 静默吞掉、选完什么都不出。
    @State private var czfIpaFolderPicked = false
    // 长按标记（3.8.426）：文件夹按钮长按=选文件夹、点按=
    // 显示 IPA 网格。长按松手时 Button 的 action 也会触发，
    // 用这个标记拦住，不让长按后又弹一次网格。
    @State var czfIpaFolderLongPressed = false
    @State var errorShow = false
    @State var errorInfo = ""
    // 新装 App 后自动恢复备份的结果提示
    @State var installInfoShow = false
    @State var installInfo = ""
    // 安装请求队列（源页批量安装用）：串行下+装，已装的直接覆盖
    @State var installQueue: [(url: URL, autoReplace: Bool, preview: Bool, forceAsNew: Bool)] = []
    // 安装前预览（源里单个安装时，下完先弹信息卡确认再装）
    @State var installPreviewShow = false
    @State var installPreviewText = ""
    @State var installPreviewContinuation: CheckedContinuation<Bool, Never>? = nil
    @State var installQueueRunning = false
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
    // 索时只含搜到的）；全选只动这些，不动列表外的。
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
            for app in batchCurrentList {
                batchSelectedIDs.remove(czfBatchKey(for: app))
            }
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
            if let folders = try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) {
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
            _ = CZFVPNManager.shared.start()
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

    // 3.8.282：长按菜单的测延迟——直接调 manager 的只读测速
    //（不像设置页那样先停核心）：核心在跑时可能整批被拒，
    // completion 的 rejected 为真时如实提示，不谎报延迟
    private func toolbarPingNodes(afterPing: (([CZFVPNManager.CZFNodePingResult]) -> Void)? = nil) {
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
            if let best = bestIndex, best != CZFVPNManager.shared.activeNodeIndex, best < CZFVPNManager.shared.nodeLinks.count {
                CZFVPNManager.shared.setActiveNode(at: best)
                let name = CZFVPNManager.nodeDisplay(for: CZFVPNManager.shared.nodeLinks[best]).name
                self.vpnPingMessage = "已切到最快节点：\(name)（\(results[best].delay)ms）"
            }
            afterPing?(results)
        }
    }

    // 3.8.282：切到最快——有本轮测速结果直接切，没有就先测
    // 再切；测速被拒或全失败时不乱切（提示已在测速里给了）。
    // 索引先判界：测完后去设置页删过节点的话，旧下标可能
    // 越界（setActiveNode 自带守卫，但下标取名字会崩）
    private func switchToFastestNode() {
        let links = CZFVPNManager.shared.nodeLinks
        if let best = vpnPingResults.filter({ $0.value.success && $0.key < links.count }).min(by: { $0.value.delay < $1.value.delay }) {
            CZFVPNManager.shared.setActiveNode(at: best.key)
            let name = CZFVPNManager.nodeDisplay(for: links[best.key]).name
            vpnPingMessage = "已切到最快节点：\(name)（\(best.value.delay)ms）"
            return
        }
        toolbarPingNodes { results in
            guard let best = results.enumerated().filter({ $0.element.success }).min(by: { $0.element.delay < $1.element.delay }),
                  best.offset < CZFVPNManager.shared.nodeLinks.count else { return }
            CZFVPNManager.shared.setActiveNode(at: best.offset)
            let name = CZFVPNManager.nodeDisplay(for: CZFVPNManager.shared.nodeLinks[best.offset]).name
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
                sharedModel.selectedTab = .settings
            }
        } label: {
            Label("VPN", systemImage: vpnCoreRunning ? "shield.fill" : "shield")
        } primaryAction: {
            toggleVPNCore()
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
                        Label("add", systemImage: "plus")
                    }

                    if installprogressVisible {
                        ProgressView().progressViewStyle(.circular).padding(.horizontal, 8)
                    }
                }
                // 本地 IPA 文件夹（3.8.423，用户 21:49 令；3.8.426
                // 改成长按选文件夹、点按显示 IPA 网格，用户 23:00
                // 令）：点按=记过的文件夹直接打开 IPA 网格，没记
                // 过弹选择器；长按=重新选文件夹（换文件夹）。长
                // 按松手时 Button 的 action 也会触发，靠
                // czfIpaFolderLongPressed 拦住，不弹两次。
                Button {
                    if czfIpaFolderLongPressed {
                        czfIpaFolderLongPressed = false
                        return
                    }
                    if let saved = czfRestoreIpaFolder() {
                        czfIpaFolderURL = saved
                        czfIpaFolderSheetShow = true
                    } else {
                        czfIpaFolderPickerShow = true
                    }
                } label: {
                    Label("本地 IPA 文件夹", systemImage: "folder")
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    czfIpaFolderLongPressed = true
                    czfIpaFolderPickerShow = true
                }
                if(UserDefaults.sideStoreExist()) {
                    Button {
                        LCUtils.openSideStore(delegate: self)
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
                Label("更多工具", systemImage: topToolsExpanded ? "chevron.left" : "chevron.right")
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
                Button("Help", systemImage: "questionmark") {
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
    // 列数默认 4，图标大小默认 0=大（1=中，2=小）。
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
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
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
        let apps = selectedBatchApps
        guard !apps.isEmpty else { return }
        batchBusy = true
        defer { batchBusy = false }
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            errorInfo = "lc.settings.backupFail".loc
            errorShow = true
            return
        }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        let (okNames, failedNames, skippedNames, overwrittenCount): ([String], [String], [String], Int) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                var ok: [String] = []
                var failed: [String] = []
                // 3.8.281：锁了的跳过、覆盖计数
                var skipped: [String] = []
                var overwritten = 0
                for app in apps {
                    let name = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
                    // 3.8.281：锁了的跳过（报已锁定）；备之前先记有无
                    // 旧备份，成功了才算一次覆盖（跑完报“覆盖了 N 个”）。
                    let fname = LCDataManagementView.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
                    if LCDataManagementView.isBackupLocked(fname) {
                        skipped.append("\(name)（已锁定）")
                        continue
                    }
                    let hadBackup = fm.fileExists(atPath: backupRoot.appendingPathComponent(fname).path)
                    do {
                        let one = try LCDataManagementView.backupOneAppSync(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly)
                        ok.append(one.folderName)
                        if hadBackup { overwritten += 1 }
                    } catch {
                        failed.append("\(name)：\(LCUtils.czfFriendlyError(error))")
                    }
                }
                if !ok.isEmpty {
                    LCDataManagementView.syncBackupsToExternalFolder(appNames: ok, backupRoot: backupRoot)
                    LCDataManagementView.writeCZFSettingsBackupDebounced()
                }
                continuation.resume(returning: (ok, failed, skipped, overwritten))
            }
        }
        if okNames.isEmpty && failedNames.isEmpty && !skippedNames.isEmpty {
            // 3.8.281：全被跳过（都锁了）不是失败，如实报跳过。
            installInfo = "已跳过 \(skippedNames.count) 个（已锁定）：\n" + skippedNames.joined(separator: "\n")
            installInfoShow = true
        } else if okNames.isEmpty {
            errorInfo = "备份失败，一个都没备份上：\n" + failedNames.joined(separator: "\n")
            errorShow = true
        } else {
            installInfo = "批量备份完成：成功 \(okNames.count) 个" + (loginOnly ? "（只备份登录态）" : "（完整备份）") + (overwrittenCount > 0 ? "（其中 \(overwrittenCount) 个覆盖了旧备份）" : "") + (failedNames.isEmpty ? "" : "，失败 \(failedNames.count) 个：\n" + failedNames.joined(separator: "\n")) + (skippedNames.isEmpty ? "" : "，跳过 \(skippedNames.count) 个（已锁定）：\n" + skippedNames.joined(separator: "\n"))
            installInfoShow = true
        }
        batchMode = false
        batchSelectedIDs.removeAll()
        refreshBackupStatus()
    }

    // 批量恢复：多选的 App 各找自己的备份文件夹，有备份的
    // 调 restoreOneApp（静态，数据管理页同款），没备份的
    // 记“无备份”跳过；单个失败不 abort 整批，跑完汇总报数；
    // 跑完刷新每行备份状态。
    private func batchRestore(loginOnly: Bool) async {
        let apps = selectedBatchApps
        guard !apps.isEmpty else { return }
        batchBusy = true
        defer { batchBusy = false }
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            errorInfo = "lc.settings.backupFail".loc
            errorShow = true
            return
        }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        var ok: [String] = []
        var failed: [String] = []
        var noBackup: [String] = []
        for app in apps {
            let name = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
            let folderName = LCDataManagementView.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
            let folderURL = backupRoot.appendingPathComponent(folderName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
                noBackup.append(name)
                continue
            }
            do {
                let outcome = try await LCDataManagementView.restoreOneApp(appFolder: folderURL, app: app, loginOnly: loginOnly)
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
            installInfo = "所选 App 都没有备份：\n" + noBackup.joined(separator: "\n")
            installInfoShow = true
        } else if ok.isEmpty {
            errorInfo = "恢复失败，一个都没恢复上：\n" + failed.joined(separator: "\n")
            errorShow = true
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
            installInfo = summary
            installInfoShow = true
        }
        batchMode = false
        batchSelectedIDs.removeAll()
        refreshBackupStatus()
    }

    // 新4（3.8.277）：批量隐藏——复用单个隐藏函数
    // LCAppModel.toggleHidden（delegate 已指回本页，
    // changeAppVisibility 会把 App 搬进隐藏区）。只对当前
    // 可见的勾选 App 调（toggle 是开关，filter 拦住已隐藏
    // 的，防误触反向取消隐藏；想取消隐藏走下面的 batchUnhide，
    // 底栏按钮在全选隐藏时自动变“恢复显示”）。
    private func batchHide() async {
        let apps = selectedBatchApps.filter { !$0.appInfo.isHidden }
        guard !apps.isEmpty else { return }
        batchBusy = true
        defer { batchBusy = false }
        for app in apps {
            await app.toggleHidden()
        }
        installInfo = "已隐藏 \(apps.count) 个 App（在下方隐藏 App 分段里查看）"
        installInfoShow = true
        batchMode = false
        batchSelectedIDs.removeAll()
    }

    // 3.8.281：批量恢复显示——把勾中的隐藏 App 搬回可见区。
    // toggleHidden 是开关，已隐藏的调它就是取消隐藏；只对已
    // 隐藏的调，可见的勾中了也不动（底栏按钮只在全选隐藏时
    // 才变“恢复显示”，混选时仍是“隐藏”，防一键两边乱动）。
    private func batchUnhide() async {
        let apps = selectedBatchApps.filter { $0.appInfo.isHidden }
        guard !apps.isEmpty else { return }
        batchBusy = true
        defer { batchBusy = false }
        for app in apps {
            await app.toggleHidden()
        }
        installInfo = "已恢复显示 \(apps.count) 个 App"
        installInfoShow = true
        batchMode = false
        batchSelectedIDs.removeAll()
    }

    // 新4（3.8.277）：批量删除——复用删 App 的文件部分
    // LCAppBannerViewController.deleteAppFiles（单个 uninstall()
    // 同款实现，删 .app 包 + 从列表移除 + 可选删数据容器与
    // 钥匙串），逐个调，单个失败不 abort 整批。确认在调用前
    // 由 confirmationDialog 一次问清（删 App / 删 App 及其数据）。
    private func batchDelete(removeDataFolders: Bool) async {
        let apps = selectedBatchApps
        guard !apps.isEmpty else { return }
        batchBusy = true
        defer { batchBusy = false }
        var deleted: [String] = []
        var failed: [String] = []
        var failedContainers: [String] = []
        for app in apps {
            let name = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
            do {
                // removeFromList 是非逃逸闭包（deleteAppFiles 内同步调完），
                // 抓 struct 的 self 合法、不产生循环引用；[weak self]
                // 只能用于 class，LCAppListView 是 struct，编不过。
                let failedC = try LCAppBannerViewController.deleteAppFiles(app, removeDataFolders: removeDataFolders) { model in
                    self.removeApp(app: model)
                }
                deleted.append(name)
                failedContainers.append(contentsOf: failedC)
            } catch {
                failed.append("\(name)：\(LCUtils.czfFriendlyError(error))")
            }
        }
        if deleted.isEmpty {
            errorInfo = "删除失败，一个都没删除：\n" + failed.joined(separator: "\n")
            errorShow = true
        } else {
            installInfo = "已删除 \(deleted.count) 个 App" + (failed.isEmpty ? "" : "，失败 \(failed.count) 个：\n" + failed.joined(separator: "\n")) + (failedContainers.isEmpty ? "" : "\n以下容器删除失败，已保留：\(failedContainers.joined(separator: "、"))")
            installInfoShow = true
        }
        batchMode = false
        batchSelectedIDs.removeAll()
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
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
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
                    onOpenSettings: { app in self.openNavigationView(view: AnyView(LCAppSettingsView(model: app))) }
                ),
                onRemoveApp: { app in self.removeApp(app: app) },
                onAuthenticateHidden: { Task { await self.authenticateUser() } },
                promptForGeneratedIconStyle: { await self.promptForGeneratedIconStyle() },
                installMdm: { data in self.installMdm(data: data) }
            )
            // 计数行已删（3.8.419，建议第 6 条）：“共 n 个 App”没信息量。
            if sharedModel.multiLCStatus == 2 {
                Text("lc.appList.manageInPrimaryTip".loc)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding()
    }

    // 网格长按菜单里的多任务启动（banner runApp(multitask:) 同款，
    // 锁屏认证走列表的 launchAppWithBundleId 同款逻辑）：
    // 锁了先人脸，过了再按反向偏好起（多任务↔直接）。
    private func czfGridLaunchMultitask(app: LCAppModel) {
        Task {
            if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    guard try await LCUtils.authenticateUser() else { return }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            do {
                try await app.runApp(multitask: !app.shouldLaunchInMultitaskMode)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
        }
    }

    // 网格点图标启动（banner runButtonTapped 同款语义，3.8.406）：
    // 点已在运行的 App 不能走 runApp 空转（LCAppModel.runApp 开头
    // 就是 isAppRunning 就 return）——先按实例 UUID 在 dock 里找
    // 条目、验相对路径归属，带回并拉满；没带回才是新起：记启动偏好
    // .large、走 launchAppWithBundleId（锁屏认证路径不变）、起完
    // 轮询拉满。长按守卫是 banner 按钮独有的，网格不要。
    private func czfGridLaunch(app: LCAppModel) {
        if #available(iOS 16.0, *),
           let uuid = app.uiSelectedContainer?.folderName ?? app.appInfo.dataUUID {
            let dockManager = MultitaskDockManager.shared
            if let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }) {
                let belongsToOther: Bool
                if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                    belongsToOther = runningPath != app.appInfo.relativeBundlePath
                } else {
                    belongsToOther = true
                }
                if !belongsToOther {
                    var brought = false
                    if #available(iOS 16.1, *) {
                        brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
                    }
                    if !brought {
                        brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
                    }
                    // 带回成功拉满；带回失败但条目还在且不是本次
                    // C4 清掉的死窗（窗已在前台、只是 bring 没抬动）
                    // 同样拉满，别再静默空转回小窗。
                    let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == uuid
                    let entryGone = !dockManager.apps.contains(where: { $0.appUUID == uuid })
                    if brought || (!cleanedByC4 && !entryGone) {
                        // maximizeWindow 是切换式，先判 !isMaximized，
                        // 否则已是最大窗会被反切回小窗。
                        if let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
                           !vc.isMaximized {
                            vc.maximizeWindow()
                        }
                        return
                    }
                }
            } else {
                // 没有 dock 条目（原生窗口模式等）：保留旧行为，
                // 只带回不拉满（没 decorated VC 可拉），带回失败
                // 再落到新起。
                var brought = false
                if #available(iOS 16.1, *) {
                    brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
                }
                if !brought {
                    brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
                }
                if brought {
                    return
                }
            }
        }

        Task {
            Self.czfSetLastLaunchMode(.large, for: app)
            await self.launchAppWithBundleId(bundleId: app.appInfo.relativeBundlePath ?? "", container: nil)
            // 新开路拉满（banner pollAndMaximizeFreshWindow 同款）：
            // uuid 在起完再取——无容器的 App 首启时 runApp 会新建
            // 容器并改 dataUUID（LCAppModel.runApp:402–436），起前取的
            // 是旧值，轮询永远找不到新窗；banner 的轮询是每 tick
            // 重取，这里起完取一次等价（轮询 6 秒内选中不再变）。
            await MainActor.run {
                if #available(iOS 16.0, *),
                   let uuid = app.uiSelectedContainer?.folderName ?? app.appInfo.dataUUID {
                    Self.czfPollAndMaximizeFreshWindow(uuid: uuid, expectedPath: app.appInfo.relativeBundlePath)
                }
            }
        }
    }

    // 启动偏好记忆（banner setLastLaunchMode 同款 5 行）：键
    // LCAppLastLaunchMode：[唯一 ID: "large"/"small"/"minimized"]，
    // 存 App Group。启动一律记 .large（用户亲定：启动=大窗）。
    private static let czfGridLastLaunchModeKey = "LCAppLastLaunchMode"

    private enum CZFGridLaunchMode: String {
        case large, small, minimized
    }

    private static func czfSetLastLaunchMode(_ mode: CZFGridLaunchMode, for model: LCAppModel) {
        guard let id = LCAppSortManager.shared.getUniqueIdentifier(for: model) else { return }
        var dict = LCUtils.appGroupUserDefault.dictionary(forKey: czfGridLastLaunchModeKey) as? [String: String] ?? [:]
        dict[id] = mode.rawValue
        LCUtils.appGroupUserDefault.set(dict, forKey: czfGridLastLaunchModeKey)
        LCDataManagementView.writeCZFSettingsBackupDebounced()
    }

    // 启动新开路拉满（banner pollAndMaximizeFreshWindow 同款）：
    // runApp 起完新窗可能还没进 dock（签名耗时），0.1 秒×60 次
    // 轮询等它出现；归属按路径验，别人的窗口占着 uuid 就停表
    // 不碰；vc 没就绪继续等；拉满或 60 次后停表。
    // 静态方法：不捕获 struct 的 self——Timer 闭包是逃逸闭包，
    // 但 LCAppListView 是 struct，[weak self] 编不过（weak 只
    // 能用于 class，见 3.8.277 构建 #42013239934）；静态方法只
    // 捕获 uuid/expectedPath/attempts 三个值，无循环引用。
    @available(iOS 16.0, *)
    private static func czfPollAndMaximizeFreshWindow(uuid: String, expectedPath: String?) {
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            attempts += 1
            guard let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }) else {
                if attempts >= 60 {
                    timer.invalidate()
                }
                return
            }
            let owned: Bool
            if let runningPath = entry.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                owned = runningPath == expectedPath
            } else {
                owned = false
            }
            if !owned {
                timer.invalidate()
                return
            }
            guard let vc = entry.view?._viewDelegate() as? DecoratedAppSceneViewController else {
                if attempts >= 60 {
                    timer.invalidate()
                }
                return
            }
            if !vc.isMaximized {
                vc.maximizeWindow()
            }
            if vc.isMaximized || attempts >= 60 {
                timer.invalidate()
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
        // 原样排布，图只从透明处透出来。
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
            if !didAppear {
                onAppear()
            }
            // 3.8.404：每次回到本页都扫分享收件箱（切回 App
            // 页时 onAppear 也触发，didAppear 守卫只拦 onAppear()）。
            czfClaimShareInbox()
        }
        .onChange(of: czfBackgroundVersion) { _ in
            czfBackgroundImage = CZFAppBackground.loadImage()
        }
        .onChange(of: scenePhase) { newPhase in
            // 3.8.404：从后台切回前台时扫分享收件箱（本页已在
            // 前台时分享的场景，onAppear 不触发）。
            if newPhase == .active {
                czfClaimShareInbox()
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
            // 顶栏实底走 czfSolidToolbarBackground（3.8.424：
            // .toolbarBackground 是 iOS 16+ API，部署目标 15.0
            // 下直接调编不过，包 #available）。
            .czfSolidToolbarBackground()
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
                            if batchSelectionAllHidden {
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
        .confirmationDialog("删除 \(batchSelectedIDs.count) 个 App", isPresented: $batchDeleteConfirm, titleVisibility: .visible) {
            Button("删除 App（保留数据）", role: .destructive) {
                Task { await batchDelete(removeDataFolders: false) }
            }
            Button("删除 App 及其数据", role: .destructive) {
                Task { await batchDelete(removeDataFolders: true) }
            }
            Button("取消", role: .cancel) { }
        }
        // 3.8.302：批量备份范围单（与数据管理页“备份范围”单同款
        // 两选项 + 同款说明）；选了范围才跑 batchBackup，取消不跑。
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
        // 批量恢复范围单（与批量备份同款两选项）；选了范围
        // 才跑 batchRestore，取消不跑。
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
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .alert("提示", isPresented: $installInfoShow){
            Button("lc.common.ok".loc, action: {
            })
        } message: {
            Text(installInfo)
        }
        // 3.8.282：顶部盾牌长按菜单的测速 / 切节点结果提示
        .alert("测延迟", isPresented: Binding(get: { vpnPingMessage != nil }, set: { if !$0 { vpnPingMessage = nil } })) {
            Button("lc.common.ok".loc, action: {
            })
        } message: {
            Text(vpnPingMessage ?? "")
        }
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
                        ForEach(Array(installQueue.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item.url.lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    if let idx = installQueue.firstIndex(where: { $0.url == item.url && $0.autoReplace == item.autoReplace }) {
                                        installQueue.remove(at: idx)
                                    }
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
        // 本地 IPA 文件夹（3.8.423）：选文件夹（asCopy false，
        // 原位读），存 bookmark、打开 IPA 列表；列表里点一个
        // 就进安装队列（enqueueInstall，不删用户文件夹里的原文件）。
        .betterFolderImporter(isPresented: $czfIpaFolderPickerShow, callback: { folderURL in
            czfSaveIpaFolder(folderURL)
            czfIpaFolderURL = folderURL
            // 3.8.429 选完没反应：回调里直接 czfIpaFolderSheetShow
            // = true 时 picker 还没关，sheet 会被 UIKit 静默吞掉
            //（present 时已有控制器在上面）。只记 URL + 置标记，
            // 等下面的 onDismiss（picker 关完）再弹 sheet。
            czfIpaFolderPicked = true
        }, onDismiss: {
            czfIpaFolderPickerShow = false
            // 3.8.429：picker 关完再弹 sheet；再往下一帧推，
            // 等 picker 的 dismiss 走完，sheet 才不会被吞。
            if czfIpaFolderPicked {
                czfIpaFolderPicked = false
                DispatchQueue.main.async {
                    czfIpaFolderSheetShow = true
                }
            }
        })
        .sheet(isPresented: $czfIpaFolderSheetShow, onDismiss: {
            // 3.8.428 安装#4：换文件夹——等 sheet 关完再弹选择器；
            // 同一代码块里 sheet=false + picker=true 时选择器可能
            // 弹不出（ViewExtensions 的修饰符不改，另一位同事在改它）。
            if czfIpaFolderChangeRequested {
                czfIpaFolderChangeRequested = false
                czfIpaFolderPickerShow = true
            }
        }) {
            if let folderURL = czfIpaFolderURL {
                CZFLocalIpaFolderView(
                    folderURL: folderURL,
                    onInstall: { ipaURL in
                        czfIpaFolderSheetShow = false
                        enqueueInstall(url: ipaURL, autoReplace: false)
                    },
                    onChangeFolder: {
                        czfIpaFolderChangeRequested = true
                        czfIpaFolderSheetShow = false
                    },
                    onClose: {
                        czfIpaFolderSheetShow = false
                    }
                )
            }
        }
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
        // 3.8.428 安装#9：覆盖运行中 App 前的确认——不静默强杀，
        // 请用户先退出该 App；“继续覆盖”才装，取消=放弃这次安装。
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
            title: "给新 App 起个名字",
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
            })
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
            // 消费完清空，避免重复装。下面的安装通知 onReceive
            // 原样保留，不动。
            if !CZFSourcePendingInstall.items.isEmpty {
                let czfQueued = CZFSourcePendingInstall.items
                CZFSourcePendingInstall.items.removeAll()
                for item in czfQueued {
                    enqueueInstall(url: item.url, autoReplace: item.autoReplace, preview: item.preview, forceAsNew: item.forceAsNew)
                }
            }
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
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
                enqueueInstall(url: installUrl, autoReplace: (obj2["autoReplace"] as? Bool) ?? false, preview: (obj2["preview"] as? Bool) ?? false, forceAsNew: (obj2["forceAsNew"] as? Bool) ?? false)
            }
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
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
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
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
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


    
    // 本地 IPA 文件夹（3.8.423）：文件夹 bookmark 存取。
    // bookmark 存进 UserDefaults，下次点文件夹按钮直接恢复，
    // 不用重新选；失效了返回 nil、重选。注意：.withSecurityScope
    // 是 macOS 才有的选项，iOS 上编不过（3.8.429 实证：
    // 用了它构建报 'withSecurityScope' is unavailable in iOS，
    // 已撤回）——iOS 里文档选择器给的 URL 本身就是
    // security-scoped，普通 bookmark 就够，解析出来再
    // startAccessingSecurityScopedResource。
    private func czfSaveIpaFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "CZFLocalIpaFolderBookmark")
        }
    }

    private func czfRestoreIpaFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "CZFLocalIpaFolderBookmark") else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        // 书签旧了也别直接丢（3.8.426，用户 23:00 报“选了
        // 文件夹、再点没有 IPA”）：isStale 只说明书签数据
        // 过期，解析出的 URL 多半还能用。先把 URL 返回、
        // 再重存一份新书签，下次就不走这条。直接返回 nil
        // 的话，点按钮又弹选择器，看着像“没记住文件夹”。
        if isStale {
            czfSaveIpaFolder(url)
        }
        return url
    }

    func startInstallApp(_ fileUrl:URL) async {
        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
            // installIpaFile 成功路不一定清 flag，这里先清再出队，
            // 否则队里那个撞上正忙会重新排队、一直等不到
            self.installprogressVisible = false
            drainPendingInstalls()
        } catch is CZFInstallCancelled {
            // 3.8.428 安装#2：用户取消安装，不弹错误提示。
            self.installprogressVisible = false
            drainPendingInstalls()
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
            drainPendingInstalls()
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL, autoReplace: Bool = false, forceAsNew: Bool = false) async throws {
        let fm = FileManager()

        // 装之前先看空间：解包 + 落盘 + 签名大约要 IPA 体积
        // 的 3 倍，空间不够时原来是装到一半才失败、报错还看
        // 不懂；现在提前明确告诉差多少。小包不查（误差大）
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let ipaSize = (attrs[.size] as? NSNumber)?.int64Value, ipaSize > 50 * 1024 * 1024,
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
        self.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.installProgressPercentage = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }
        
        // decompress
        // 3.8.428 安装#8：解包失败单独报“已损坏或下载不完整”，
        // 不再复用 urlFileIsNotIpaError（那是“不是 IPA”的判断，
        // 扩展名那路还用它，别动）。
        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
            throw "这个 IPA 已损坏或下载不完整，请重新下载"
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
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier() == newBundleId
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier() == newBundleId
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
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
                if !czfAuthOK {
                    self.installprogressVisible = false
                    try? fm.removeItem(at: payloadPath)
                    throw CZFInstallCancelled()
                }
            }
            
        }
        
        // 多开自定义名必须在 if 块外声明：签名之前那处在块外用它，
        // 块内 var 会出不了作用域（构建 #209 唯一红字就是这个）。
        var czfCustomDisplayName: String? = nil
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newBundleId)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            
            self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            
            for app in sameBundleIdApp {
                self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
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
                self.installprogressVisible = false
                try? fm.removeItem(at: payloadPath)
                throw CZFInstallCancelled()
            }

            // 多开（安装为新 App）：先让用户输个新名字，再往下装。
            // 空着或跟原名一样 = 不自定义；取消 = 放弃这次安装。
            // 批量自动覆盖不走这里，不弹框挡队列。
            if !installOptionChosen.isReplace && !sameBundleIdApp.isEmpty {
                let originalName = newAppInfo.displayName() ?? ""
                let inputName = await installAsNewNameInput.open(initVal: originalName)
                guard let inputName else {
                    // 3.8.428 安装#2：输新名字点取消=取消安装，抛
                    // 专用取消信号（原来直接 return，会被批量计为成功）。
                    self.installprogressVisible = false
                    try? fm.removeItem(at: payloadPath)
                    throw CZFInstallCancelled()
                }
                let trimmed = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != originalName {
                    czfCustomDisplayName = trimmed
                }
            }
            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
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
        if let appToReplace, appToReplace.isAppRunning {
            czfRunningAppName = appToReplace.appInfo.displayName() ?? appToReplace.appInfo.bundleIdentifier() ?? ""
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
            // ③ 新包落盘了，删旧包备份。
            try? fm.removeItem(at: czfOldBackup)
        } catch {
            try? fm.removeItem(at: czfOldBackup)
            throw error
        }
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
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
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if czfSignResumeOnce.claimTimeout() {
                    c.resume()
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
        if czfSignResumeOnce.timedOut {
            signError = "签名超时（已等待 5 分钟），请重试"
            signSuccess = false
        }
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            LCAppModel.copy(fromApp: appToReplace, toAppInfo: finalNewApp)
            // 覆盖更新保留被替换那个实例的自定义名（多开改名后更新
            // 不丢名）；本分支只在覆盖时走，多开新实例不走这里。
            // 上游 9d6ea09 把逐项拷贝抽成 LCAppModel.copy，但它不拷
            // customDisplayName，这里补上，fork 定制不丢（setter
            // 自带 save，无需另调 save）。
            finalNewApp.customDisplayName = appToReplace.appInfo.customDisplayName
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
                // 覆盖安装（旧模型换新模型）后同款清掉，否则旧
                // 包路径的缓存/dock 条目会指到已替换的 App。
                if #available(iOS 16.0, *) {
                    MultitaskDockManager.refreshAfterAppChanged()
                }

            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)

                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }

                // 全新安装（非覆盖更新）：自动查这个 App 的备份
                // 记录，有就直接恢复并弹窗，没有就不弹窗
                Task { await self.autoRestoreBackupAfterInstall(app: newAppModel) }
            }

            self.installprogressVisible = false
        }
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
        let bundleID = app.appInfo.bundleIdentifier() ?? ""
        let name = app.appInfo.displayName() ?? bundleID
        let appUUID = app.appInfo.dataUUID ?? ""
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let root = docs.appendingPathComponent("Backups")
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
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
            // 候选去重（同一文件夹可能同时满足二、三档）
            let unique = Array(Set(candidates))
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
        let outcome = try? await LCDataManagementView.restoreOneApp(appFolder: found, app: app)
        await MainActor.run {
            if outcome?.ok == true {
                installInfo = "「\(name)」已恢复备份记录"
            } else if let outcome, outcome.keychainFound > 0 {
                // 备份里明明有钥匙串却恢复失败：把条数和错误码
                // 亮出来，卡在哪一环一眼可辨，不再误报"没数据"
                installInfo = "「\(name)」找到备份记录，钥匙串有 \(outcome.keychainFound) 条但写回失败（错误码 \(outcome.keychainStatus)）"
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
        if self.installprogressVisible {
            if !pendingInstalls.contains(where: { $0.urlStr == urlStr }) {
                pendingInstalls.append(.plist(urlStr))
            }
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await CZFVPNManager.hostSession().data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
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
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    /// 安装请求队列：下载器全局只有一个、安装器同时只能装
    /// 一个，源页的批量安装必须一个一个排队来，不然忙着装
    /// 别的时新请求会被直接丢掉、批量只装得上第一个。单个
    /// 安装请求也走这里（队列空闲时立即执行，和以前一样）；
    /// autoReplace 的请求遇到已装同款直接覆盖、不弹选择框
    func enqueueInstall(url: URL, autoReplace: Bool, preview: Bool = false, forceAsNew: Bool = false) {
        installQueue.append((url: url, autoReplace: autoReplace, preview: preview, forceAsNew: forceAsNew))
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
            while !installQueue.isEmpty {
                let item = installQueue.removeFirst()
                if processed > 0 || !installQueue.isEmpty {
                    batch = true
                }
                installQueueTotal = processed + 1 + installQueue.count
                installQueueDone = processed
                installQueueCurrent = item.url.lastPathComponent
                // 等手动触发的安装先装完，别互相抢
                // 3.8.428 安装#6：等的时候每秒查一次取消标志——
                // 用户点了进度条旁的取消，就跳过当前项、继续下一项。
                var czfWaitCancelled = false
                while installprogressVisible {
                    if czfInstallCancelRequested {
                        czfWaitCancelled = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if czfWaitCancelled {
                    czfInstallCancelRequested = false
                    czfLastInstallWasCancelled = true
                    cancelledNames.append(item.url.lastPathComponent)
                    // 上一轮可能已预下载了这一项的包，跳过就清掉，
                    // 别把临时 IPA 漏在 tmp 里。
                    if let pf = prefetched, pf.url == item.url {
                        try? FileManager.default.removeItem(at: pf.file)
                        prefetched = nil
                    }
                    processed += 1
                    installQueueDone = processed
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
                // 不占界面上那个；下失败了轮到时走正常下载）
                var prefetchTask: Task<(URL, URL)?, Never>? = nil
                if let next = installQueue.first, !next.url.isFileURL {
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
                czfLastInstallWasCancelled = false
                let installOK = await installFromUrl(urlStr: installStr, autoReplace: item.autoReplace, preview: item.preview, forceAsNew: item.forceAsNew)
                if czfLastInstallWasCancelled {
                    cancelledNames.append(item.url.lastPathComponent)
                    czfLastInstallWasCancelled = false
                } else if installOK {
                    succeeded += 1
                } else {
                    failedNames.append(item.url.lastPathComponent)
                }
                if let prefetchFile {
                    try? FileManager.default.removeItem(at: prefetchFile)
                }
                processed += 1
                installQueueDone = processed
                prefetched = await prefetchTask?.value ?? nil
            }
            downloadHelper.batchMode = false
            installQueueRunning = false
            if processed > 1 {
                // 汇总分开报成功/失败并点名失败的：原来只报总数，
                // 装 10 个挂 3 个也显示"完成"，得逐个去核对
                // 3.8.428 安装#2：取消单独列出来，不混进成功/失败。
                if failedNames.isEmpty && cancelledNames.isEmpty {
                    installInfo = "批量安装完成：共 \(processed) 个，全部成功"
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
                    installInfo = czfSummary
                }
                installInfoShow = true
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

    /// 安装前预览文案：把刚下载的 IPA 解开读 Info.plist，
    /// 拼出名称/版本/Bundle ID/大小/声明的权限。解不开或
    /// 读不到就返回 nil（不拦，照常安装）
    func makeInstallPreviewText(forIpa url: URL) async -> String? {
        let fm = FileManager.default
        let previewDir = fm.temporaryDirectory.appendingPathComponent("CZFInstallPreview")
        try? fm.removeItem(at: previewDir)
        try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: previewDir) }
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        guard await decompress(url.path, previewDir.path, progress) == 0 else { return nil }
        let payloadPath = previewDir.appendingPathComponent("Payload")
        guard let contents = try? fm.contentsOfDirectory(atPath: payloadPath.path),
              let appName = contents.first(where: { $0.hasSuffix(".app") }) else { return nil }
        let infoURL = payloadPath.appendingPathComponent(appName).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? appName
        let version = (plist["CFBundleShortVersionString"] as? String) ?? "?"
        let bundleId = (plist["CFBundleIdentifier"] as? String) ?? "?"
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
        guard !pendingInstalls.isEmpty else { return }
        let next = pendingInstalls.removeFirst()
        Task {
            switch next {
            case .url(let s, let r, let p, let f):
                await installFromUrl(urlStr: s, autoReplace: r, preview: p, forceAsNew: f)
            case .plist(let s):
                await installFromPlist(urlStr: s)
            }
        }
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
                if let b64 = entry.bookmarkBase64,
                   let bookmarkData = Data(base64Encoded: b64) {
                    LCUtils.appGroupUserDefault.set(bookmarkData, forKey: "LCLaunchExtensionFileBookmark")
                }
                Self.czfClaimedInboxFiles.insert(fileKey)
                Task {
                    let ok = await self.installFromUrl(urlStr: fileURLString)
                    if ok { try? fm.removeItem(at: url) }
                    Self.czfClaimedInboxFiles.remove(fileKey)
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
                    await self.launchAppWithBundleId(bundleId: bundleName, container: entry.containerFolderName, urlStr: entry.launchURL)
                    try? fm.removeItem(at: url)
                    Self.czfClaimedInboxFiles.remove(fileKey)
                }
            case .sidestore:
                Self.czfClaimedInboxFiles.insert(fileKey)
                Task {
                    await self.launchAppWithBundleId(bundleId: "builtinSideStore", container: nil, urlStr: entry.launchURL)
                    try? fm.removeItem(at: url)
                    Self.czfClaimedInboxFiles.remove(fileKey)
                }
            }
        }
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

    func installFromUrl(urlStr: String, autoReplace: Bool = false, preview: Bool = false, forceAsNew: Bool = false) async -> Bool {
        // 3.8.428 App#4：粘贴的安装链接带首尾空格/换行就报“链接
        // 无效”，先 trim（与 installFromPlist 同款处理）。
        let urlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        // 3.8.428 安装#2：取消标记不在这里清——defer 里
        // drainPendingInstalls 可能并发起下一次安装，入口清会把
        // 上一次的取消标记冲掉；由 enqueueInstall 在每次调用前
        // 清、调用后读（见 enqueueInstall），这里只在取消路径置 true。
        // 进行中再点安装：排进队、当前装完接着装，不再静默丢掉
        if self.installprogressVisible {
            let item = CZFPendingInstall.url(urlStr, autoReplace, preview, forceAsNew)
            if !pendingInstalls.contains(where: { $0.urlStr == urlStr }) {
                pendingInstalls.append(item)
            }
            return false
        }
        // 3.8.428 安装#6：进度条旁点了取消——还没开始装就直接
        // 按取消返回，不进下载/解包。
        if czfTakeInstallCancel() {
            return false
        }

        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return false
        }

        guard var installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return false
        }
        
        self.installprogressVisible = true
        defer {
            self.installprogressVisible = false
            drainPendingInstalls()
        }

        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return false
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "读取共享的 IPA 文件失败：\(LCUtils.czfFriendlyError(error))"
                    errorShow = true
                    return false
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return false
            }
            
            // 3.8.428 安装#3：文件夹弹窗点安装就关 sheet，模型
            // deinit 会 stopAccessing，大包解包中途可能丢访问权；
            // 文件若在 CZFLocalIpaFolderBookmark 记住的文件夹里，
            // 这里用文件夹书签重新取权再解包（与 426 的
            // czfRestoreIpaFolder 同款取法），用完释放；文件夹
            // 模型本身的 deinit 不动。
            var czfFolderURL: URL? = nil
            var czfFolderAccessHeld = false
            if let folderURL = czfRestoreIpaFolder(),
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
            if czfTakeInstallCancel() {
                return false
            }

            var installOK = true
            do {
                try await installIpaFile(installUrl, autoReplace: autoReplace, forceAsNew: forceAsNew)
            } catch is CZFInstallCancelled {
                // 3.8.428 安装#2：取消不弹错、不计失败，记取消。
                czfLastInstallWasCancelled = true
                installOK = false
            } catch {
                installOK = false
                errorInfo = LCUtils.czfFriendlyError(error)
                errorShow = true
            }

            // I2：只有安装成功才删 Inbox 源 IPA；安装失败时
            // 留着源文件，方便用户重试 / 排查。
            if installOK {
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
                } catch {
                    // 清理本身失败只记日志，不重写 errorInfo
                    print("delete inbox ipa failed: \(error)")
                }
            }
            return installOK
        }
        
        // 3.8.428 安装#2：fileManager/destinationURL 提到 do 外面，
        // 下面那个 catch is CZFInstallCancelled 里要清临时包，
        // do 里声明的变量 catch 里够不到。
        let fileManager = FileManager.default
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try await downloadHelper.download(url: installUrl, to: destinationURL)
            if downloadHelper.cancelled {
                // 3.8.428 安装#2：用户取消下载=取消，不计失败。
                czfLastInstallWasCancelled = true
                return false
            }
            // 3.8.428 安装#6：下载完、解包前再查一次取消。
            if czfTakeInstallCancel() {
                try? fileManager.removeItem(at: destinationURL)
                return false
            }
            if preview, let text = await makeInstallPreviewText(forIpa: destinationURL) {
                // 下完了先弹信息卡：用户点「安装」才继续，
                // 点「取消」删掉临时包、什么都不装
                let proceed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    installPreviewContinuation = cont
                    installPreviewText = text
                    installPreviewShow = true
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
                    czfLastInstallWasCancelled = true
                    try? fileManager.removeItem(at: destinationURL)
                    return false
                }
            }
            try await installIpaFile(destinationURL, autoReplace: autoReplace, forceAsNew: forceAsNew)
            try fileManager.removeItem(at: destinationURL)
        } catch is CZFInstallCancelled {
            // 3.8.428 安装#2：安装中途取消（替换选择/输名/运行中
            // 确认），清掉临时包、不弹错，记取消。
            czfLastInstallWasCancelled = true
            try? fileManager.removeItem(at: destinationURL)
            return false
        } catch {
            errorInfo = LCUtils.czfFriendlyError(error)
            errorShow = true
            return false
        }
        return true
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
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
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt, selectedBundlePath: String?, selectedContainerFolder: String?, launchURL: String?) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode, selectedBundlePath: selectedBundlePath, selectedContainerFolder: selectedContainerFolder, launchURL: launchURL)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt, selectedBundlePath: String?, selectedContainerFolder: String?, launchURL: String?) async {
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
            return
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
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    // App 名含空格时 URL(string:) 直接返回 nil，旧代码静默失败；
                    // 先 percent-encoding 再拼，拼不出给提示而不是无反应。
                    let encodedAppName = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appName
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
                            UIApplication.shared.open(url)
                        } else {
                            errorInfo = "Failed to build JIT URL."
                            errorShow = true
                        }
                    }
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
                        UIApplication.shared.open(url)
                    }
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
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
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
private struct LCAppReorderDropDelegate: DropDelegate {
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
