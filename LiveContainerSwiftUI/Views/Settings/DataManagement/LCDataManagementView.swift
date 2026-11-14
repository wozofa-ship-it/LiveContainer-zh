//
//  LCDataManagementView.swift
//  LiveContainer
//
//  Created by s s on 2025/4/18.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LCFolderPath {
    var path : URL
    var desc : String
}

/// 恢复后“无可恢复数据”的备份文件夹（v216）：恢复报告里只
/// 有名字不够，用户要能点一下就在文件 App 里打开核对。
/// Identifiable 用 UUID（同名多开的文件夹名可能重复，名
/// 字不能当 id）。
struct NoDataFolderEntry: Identifiable {
    let id = UUID()
    let name: String
    let folder: URL
}

/// 3.8.299：恢复用 IPA 选择器的 delegate。恢复 Task 里用
/// withCheckedContinuation 等用户选文件，delegate 回调就是
/// resume 的时机。UIDocumentPickerViewController 的 delegate
/// 是弱引用，coordinator 靠 selfRetain 活到回调（选到或取
/// 消都只 resume 一次，回调完立刻释放）。
private final class RestoreIPAPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    private let onDone: (URL?) -> Void
    private var done = false
    private var selfRetain: RestoreIPAPickerCoordinator?
    init(onDone: @escaping (URL?) -> Void) {
        self.onDone = onDone
        super.init()
        selfRetain = self
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !done else { return }
        done = true
        let url = urls.first
        selfRetain = nil
        onDone(url)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !done else { return }
        done = true
        selfRetain = nil
        onDone(nil)
    }
}

/// 恢复前备份清单预览的一行（v216）：只读元数据和已下载
/// 到本机的文件，绝不触发 iCloud 下载（未同步的部分标
/// “未同步”，不给假数字）。
struct BackupPreviewItem {
    /// 文件夹名（新命名带实例后缀时原样显示，用来区分多开）
    var folderName: String
    /// manifest 里的显示名，没有 manifest 时等于文件夹名
    var displayName: String
    /// manifest scope：full / login / keychain / ""（无 manifest）
    var scope: String
    /// manifest backupDate，没有时为空
    var backupDate: String
    /// 数据容器数（与 restoreOneApp 的 containerFolders 同口径：
    /// manifest/.app/AppGroup/Keychain 之外的顶层条目）
    var containerCount: Int
    /// 钥匙串条数合计；nil = 没有 Keychain 目录（无快照）
    var keychainCount: Int?
    /// Keychain 里的 plist 是否都已下载到本机（iCloud 源才有意义）
    var keychainSynced: Bool
    /// 登录态档的会话文件数（只对 login 范围计数，完整档为 nil，
    /// 表示“含在整容器里”）；超过 100000 时记 100001，显示 100000+
    var sessionFileCount: Int?
    /// 有没有 .app 本体
    var hasAppBundle: Bool
    /// 空备份判定：完整档看容器+钥匙串，登录态档看会话文件+钥匙串
    var isEmptyBackup: Bool {
        if scope == "login" {
            return (sessionFileCount ?? 0) == 0 && (keychainCount ?? 0) == 0
        }
        return containerCount == 0 && (keychainCount ?? 0) == 0
    }
}

/// 3.8.313：源面板快捷方式直开数据管理里的某个动作——
/// 快捷方式存的设置页（CZFSettingsPage）里，恢复/备份类
/// 不是新页，都是 LCDataManagementView 里的 sheet/弹窗；
/// 用 initialSheet 告诉本页一出现就自动弹出哪一个，免得
/// 用户先进数据管理再点一次。
enum LCDataManagementInitialSheet {
    case restore
    case backupSelect
    case backupAll
    case scheduleBackup
    // 3.8.349：只备某一个 App，直出范围选页——复用 .backupAll
    // 的 onAppearFunc 路（pendingBackupApps + body 直返
    // CZFScopeChoiceView），不经过选页。目标 App 不放在
    // enum 里（要带 LCAppModel 就丢了 CaseIterable/raw
    // String），走 init 的 directBackupApps 参数；面板的
    // 备份快捷方式（appbackup: 条目）点按时把 App 传进来。
    // directBackupApps 为空时 onAppearFunc 不弹框（绝不
    // 退回“全部 App”，用户只要那一个）。
    case backupScope
}

struct LCDataManagementView : View {
    @State var folderPaths : [LCFolderPath]
    @State var filzaInstalled = false
    @State var appeared = false
    // 3.8.313：直开某动作（见 LCDataManagementInitialSheet）。
    let initialSheet: LCDataManagementInitialSheet?
    // 3.8.349：.backupScope 直出范围框要备的 App（只含目标
    // 一个，不含全部；init 参数传进来，plain let，init 里
    // 直接赋值，不读 sharedModel）。不走 .backupScope 时为空。
    let directBackupApps: [LCAppModel]
    // 3.8.359：面板单独弹窗预选的范围（nil = 没预选，走范围
    // 选页 CZFScopeChoiceView；非 nil = 面板已让用户选过，
    // 直接按它备份，不再出选页）。
    let preselectedLoginOnly: Bool?
    @State private var didApplyInitialSheet = false
    
    @StateObject private var appFolderRemovalAlert = YesNoHelper()
    @State private var folderRemoveCount = 0
    
    @StateObject private var keyChainRemovalAlert = YesNoHelper()
    @StateObject private var tmpRemovalAlert = YesNoHelper()
    @StateObject private var cacheRemovalAlert = YesNoHelper() 

    
    @State var errorShow = false
    @State var errorInfo = ""
    @State var successShow = false
    @State var successInfo = ""
    // 备份/恢复进行中的进度文案（第几个、当前哪个 App）：
    // 以前全程黑盒，GB 级备份只能干等、卡没卡都不知道
    @State private var backupRestoreProgress: String? = nil
    // 3.8.307：恢复列表排序/筛选——0=时间（新→旧）、1=名字
    // （A→Z）；只看登录态是筛选（manifest scope == "login"）。
    // @State 不落盘，每次打开恢复 sheet 都是默认态。
    // 3.8.337：直进（initialSheet）时本页只是个空壳，内层页关
    // 掉后本页也跟着关——用户点快捷方式/文件夹只想看内层那一页，
    // 不想关掉内层后还剩一个数据管理页（“别弹窗俩个出来”）。
    @Environment(\.dismiss) private var dismiss
    @State private var backupSortMode: Int = 0
    @State private var backupLoginOnlyFilter: Bool = false
    @State private var showBackupSelect = false
    @State private var backupSelectedIDs = Set<String>()
    // 3.8.404：范围选择独立成页（CZFScopeChoiceView）——旧 dialog
    // 跟踪位随已死的 presentScopeAlert 一并删除；收尾改看“已选
    // 范围”位 czfScopeChosen（见 czfDismissIfDirectEntryDone）。
    // 3.8.404：范围选择独立成页（CZFScopeChoiceView）——398 的
    // 面板页内选框与 401 的设置页内选框一并删除，全线收口到
    // 这一页；直进 .backupScope/.backupAll 由 body 直接返回
    // 该页（见 czfDirectScopeOpen）。
    @State private var czfScopeChosen = false
    // 3.8.404：行“恢复”推范围选页的驱动位（隐藏 NavigationLink
    // 的 isActive 绑定，见 restoreRow）；nil = 未推。
    @State private var czfRowRestoreScopeURL: URL? = nil
    // 3.8.344 根因 2：直进内层页是否真弹出来的确认位。init 置
    // true 的盖子可能在外层 sheet 动画中被丢弃且无回调；盖子
    // 内容 onAppear 时置 true，onAppearFunc 0.6 秒后检查它——
    // 仍 false 说明盖子丢了，才做 false→true 重 present。
    @State private var czfDirectCoverAppeared = false
    @State private var pendingRestoreURL: URL? = nil
    @State private var pendingRestoreAll = false
    // 选择性多选（3.8.283：选择备份双动作——勾中了能删能恢复）：
    // 多选 sheet 里勾中的文件夹 URL 原值（与
    // mergedBackupFolders() 返回的同一批 URL 比对；
    // @State 不落盘，不新开 UserDefaults 键；勾选态跨次
    // 打开保留，与备份侧 backupSelectedIDs 同款）
    @State private var showSelectBackups = false
    @State private var selectedBackupFolderURLs = Set<URL>()
    @State private var selectBackupFolders: [URL] = []
    // 3.8.283：选择备份 sheet 的恢复路（多选恢复走它进范围弹窗；
    // 282 删过，283 恢复双动作时加回来）
    @State private var pendingRestoreFolders: [URL] = []
    @State private var pendingBackupApps: [LCAppModel] = []
    @State private var scheduleKeychainOnly = false
    @State private var showRestoreSelect = false
    // 新5（3.8.277）：换机迁移向导状态。step：0 选来源、1 看内容、
    // 2 一键恢复中（进度走 backupRestoreProgress 同款）、3 汇总报告。
    @State private var showMigrationWizard = false
    @State private var migrationStep = 0
    @State private var migrationSourceExternal = false
    @State private var migrationLocalCount = 0
    @State private var migrationExternalCount = 0
    @State private var migrationFolders: [URL] = []
    @State private var migrationPreviews: [BackupPreviewItem] = []
    @State private var migrationHasSettings = false
    @State private var migrationHasSort = false
    @State private var migrationHasSchemes = false
    @State private var migrationRunning = false
    @State private var migrationReport: String? = nil
    // 恢复选择 sheet 内的操作反馈（删备份等）：必须挂在 sheet
    // 自己身上——v143 试过先关 sheet 再弹外层提示，还是有盖住/
    // 卡住的可能；sheet 内的事就在 sheet 内交代，不跨层弹提示
    @State private var restoreSheetNotice: String? = nil
    @State private var backupFolderList: [URL] = []
    // 3.8.335：删备份闪退第三修（325 数据层 + 326 时机层都没盖住，
    // 334 又崩 Invalid update section 3，iCloud 区 7→7 却删了 1 个）：
    // List 的版本号，删备份时 +1 强制 List 整体重建、不走 diff——
    // SwiftUI 的 UICollectionView diff 在备份列表上三番五次算错
    // （iCloud 删完重载仍见文件、URL 写法差异、排序抖动都可能
    // 让 diff 与数据源对不上），重建直接绕过整类问题。代价是
    // 删完列表滚回顶部，删备份时可接受。
    @State private var backupListVersion = 0
    // 3.8.281：锁了的备份文件夹名（界面用；UserDefaults 是真源，
    // 恢复 sheet 打开时同步一次，锁/解锁时两边一起写）。
    @State private var lockedBackupNames: Set<String> = []
    // 3.8.281：“清理”组默认收起，展开状态记住。
    @AppStorage("CZFCleanupSectionExpanded") private var cleanupSectionExpanded = false
    // 3.8.281：“存储位置”组默认收起，展开状态记住。
    @AppStorage("CZFStorageLocationExpanded") private var storageLocationExpanded = false
    // iCloud 备份列表（恢复 sheet 里与本地同屏显示，不再先弹
    // “选哪个文件夹”再进单源列表；未设 iCloud 文件夹时为空）
    @State private var externalBackupFolderList: [URL] = []
    // 恢复 sheet 内选 iCloud 文件夹用的 picker（挂在 sheet 内，
    // 不跟父页的 picker 抢同一个 sheet 位）
    @State private var showRestoreSheetFolderPicker = false
    // 每个备份的体积（打开恢复列表时后台算，行里显示 + 底部总占用）
    @State private var backupSizes: [URL: Int64] = [:]
    // v216：恢复前清单预览（点行出 sheet，不动恢复按钮）
    @State private var previewFolderURL: URL? = nil
    @State private var previewItems: [BackupPreviewItem] = []
    @State private var showBackupPreview = false
    // 清单预览加载中：点行先弹 sheet 给转圈（清单枚举在后台
    // 算，登录档大时要点几秒；以前算完才弹 sheet，点后半天
    // 没反应、用户以为没点上）。
    @State private var previewLoading = false
    // v216：恢复后“无可恢复数据”的文件夹（结果弹窗里的
    // “在文件 App 里打开”按钮用它；按钮点过就清空，不漏到
    // 下一次无关弹窗里）
    @State private var pendingNoDataFolders: [NoDataFolderEntry] = []
    // 设置导出/导入
    @State private var showSettingsImporter = false
    @State private var settingsTransferMessage: String?
    @State private var showSettingsTransferAlert = false
    @State private var showScheduleBackup = false
    @State private var scheduleEnabled = false
    @State private var scheduleHour = 3
    @State private var scheduleMinute = 0
    @State private var scheduleSelectedIDs = Set<String>()
    // 导出 picker 的 delegate 强持有：UIDocumentPickerViewController
    // 的 delegate 是 weak，内联创建会被当场释放、回调永不触发
    // （441 教训）；用 @State 持有到 picker 关掉。
    @State private var exportPickerCoordinator: CZFExportPickerCoordinator?
    @State private var showScheduleCache = false
    @State private var cacheScheduleEnabled = false
    @State private var cacheScheduleHour = 3
    @State private var cacheScheduleMinute = 0
    @State private var externalFolderName: String? = nil
    // 注：恢复合一后不再有“选哪个文件夹”dialog，restoreFromExternal
    // 与 backupFolders() 无参版随之退役（sheet 直接调 fromExternal 版）
    @State private var showDeleteAllBackupsConfirm = false
    @State private var showDeleteBackupConfirm = false
    // 3.8.282：多选删备份的确认框
    @State private var showDeleteMultiSelectConfirm = false
    @State private var pendingDeleteBackupURL: URL? = nil
    
    @EnvironmentObject private var sharedModel : SharedModel
    // 3.8.348：删 @EnvironmentObject sceneDelegate——独立 hosting
    // + fullScreenCover 下环境注入不可靠，347 在 ensureSourcesOverlay
    // 里手动注仍闪退（访问缺失的 @EnvironmentObject 直接 fatal
    // error）。已删的 presentScopeAlert 当时改函数内现取前台场景
    // 的 delegate，不再依赖环境。347 的注入留着：源面板 .sheet 弹的
    // LCAppSettingsView 的 textFieldAlert 还要它。

    // 备份选 App 的全选状态：列表里 App 全勾上了才算全选。
    private var allBackupSelected: Bool {
        let apps = sharedModel.apps + sharedModel.hiddenApps
        return !apps.isEmpty && apps.allSatisfy { backupSelectedIDs.contains(Self.instanceKey(for: $0)) }
    }
    // 选择备份的全选状态：当前备份列表全勾上了才算全选。
    private var allSelectBackupsSelected: Bool {
        !selectBackupFolders.isEmpty && selectBackupFolders.allSatisfy { selectedBackupFolderURLs.contains($0) }
    }

    init(initialSheet: LCDataManagementInitialSheet? = nil, directBackupApps: [LCAppModel] = [], preselectedLoginOnly: Bool? = nil) {
        self.initialSheet = initialSheet
        self.directBackupApps = directBackupApps
        self.preselectedLoginOnly = preselectedLoginOnly
        _folderPaths = State(initialValue: [
            LCFolderPath(path: LCPath.docPath, desc: "Private Container"),
            LCFolderPath(path: LCPath.lcGroupDocPath, desc: "App Group Container"),
            LCFolderPath(path: Bundle.main.bundleURL, desc: "LiveContainer Bundle"),
        ])
        // 3.8.342：直进白页闪根因——内层页在 onAppear 里
        // asyncAfter(0.0) 才开，外层 sheet 滑入动画 + 内层
        // cover 滑入动画两段加起来，白壳暴露约 1 秒（用户
        // 17:02 视频第 5→7 帧实证；338 注释“白页只剩一帧”
        // 只算了 runloop，没算两段动画）。改在 init 里就把
        // 内层页开关置 true，内层页随外层页一起呈现，不再
        // 经过白壳；didApplyInitialSheet 一并置 true，
        // onAppearFunc 不再重复开。.backupAll 是范围选页
        // （要 sharedModel 填 pendingBackupApps，init 里拿
        // 不到），仍走 onAppearFunc；.backupScope 同款（范围
        // 选页 + directBackupApps 已在 init 里拿到，但选页
        // 要等外层 cover 落定才出，也走 onAppearFunc）。
        switch initialSheet {
        case .restore:
            _showRestoreSelect = State(initialValue: true)
            _didApplyInitialSheet = State(initialValue: true)
        case .backupSelect:
            _showBackupSelect = State(initialValue: true)
            _didApplyInitialSheet = State(initialValue: true)
        case .scheduleBackup:
            _showScheduleBackup = State(initialValue: true)
            _didApplyInitialSheet = State(initialValue: true)
        case .backupAll, .backupScope, .none:
            break
        }
    }
    
    // 3.8.366：恢复页直进只弹一次——恢复内容抽成 restoreBackupContent，
    // 直进（initialSheet == .restore）时 body 直接返回它，不再经
    // 数据管理壳 + fullScreenCover 两层；正常进页时仍走下面的
    // fullScreenCover，内容同一份，两路行为一致。
    @ViewBuilder private var restoreBackupContent: some View {
        NavigationView {
            // 恢复合一：本地 + iCloud 同屏两个区，不再先弹
            // “选哪个文件夹”再进单源列表；文件夹选择与
            // 换机迁移放最顶上（3.8.282）
            List {
                // 3.8.404：恢复范围选择独立成页 CZFScopeChoiceView
                //（各入口 NavigationLink 推入），此页内选框删除。
                // 3.8.307：一键恢复全部挪到列表顶部单独一行
                //（原来藏在工具栏“全部”菜单里，翻半天才找
                // 到）；副标题写清恢复的是全部本地备份。
                Section {
                    // 3.8.404：范围选择独立成页——NavigationLink 推入
                    // CZFScopeChoiceView，选完 pop 回来。
                    NavigationLink {
                        CZFScopeChoiceView(
                            isBackup: false,
                            apps: [],
                            restoreAll: true,
                            restoreURL: nil,
                            restoreFolders: [],
                            isDirectEntry: false,
                            onChoose: { loginOnly in
                                self.pendingRestoreURL = nil
                                self.pendingRestoreAll = true
                                self.doRestoreScope(loginOnly: loginOnly)
                            }
                        )
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "arrow.clockwise.circle", color: .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("一键恢复全部")
                                Text("恢复全部本地备份（本地 + iCloud）")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                // 3.8.282：选文件夹与换机迁移都放最顶上
                //（用户 2026-11-06 亲令：文件夹选择原来在
                // iCloud 区最底下、迁移向导在 sheet 最底下，
                // 两个都挪到最前面）
                Section {
                    if Self.externalBackupFolderURL() != nil {
                        Button {
                            showRestoreSheetFolderPicker = true
                        } label: {
                            HStack {
                                Label("重新选择 iCloud 备份文件夹", systemImage: "folder")
                                Spacer()
                                Text(Self.externalBackupFolderURL()?.lastPathComponent ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Button("选择 iCloud 备份文件夹") {
                            showRestoreSheetFolderPicker = true
                        }
                    }
                    Button {
                        // 3.8.339：向导页盖在恢复页上面，先不关
                        // 恢复页（同款转场冲突，向导会被吞掉）。
                        beginMigrationWizard()
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "arrow.triangle.2.circlepath", color: .purple)
                            Text("换机迁移向导")
                        }
                    }
                }
                // 3.8.307：恢复列表排序/筛选——时间（新→旧）
                // / 名字（A→Z）二选一 + 只看登录态开关。
                Section {
                    Picker("排序", selection: $backupSortMode) {
                        Text("时间").tag(0)
                        Text("名字").tag(1)
                    }
                    .pickerStyle(.segmented)
                    Toggle("只看登录态", isOn: $backupLoginOnlyFilter)
                }
                // 3.8.307：两边都空时给空状态 + 去备份按钮
                //（原来每区各一句“暂无备份”，没处可点）。
                if backupFolderList.isEmpty && externalBackupFolderList.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有备份")
                                .font(.headline)
                            Text("先备份一次，恢复时才能在这里选")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            // 3.8.404：范围选择独立成页——NavigationLink
                            // 推入 CZFScopeChoiceView，选完 pop 回来。
                            NavigationLink {
                                CZFScopeChoiceView(
                                    isBackup: true,
                                    apps: sharedModel.apps + sharedModel.hiddenApps,
                                    restoreAll: false,
                                    restoreURL: nil,
                                    restoreFolders: [],
                                    isDirectEntry: false,
                                    onChoose: { loginOnly in
                                        self.pendingBackupApps = sharedModel.apps + sharedModel.hiddenApps
                                        self.doBackupScope(loginOnly: loginOnly)
                                    }
                                )
                            } label: {
                                Text("去备份")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("本地备份") {
                    if sortedLocalBackups.isEmpty {
                        Text(backupFolderList.isEmpty ? "暂无备份" : "没有符合筛选的备份")
                            .foregroundColor(.secondary)
                    }
                    ForEach(sortedLocalBackups, id: \.self) { folderURL in
                        restoreRow(for: folderURL)
                    }
                }
                Section("iCloud 备份") {
                    if sortedExternalBackups.isEmpty {
                        Text(externalBackupFolderList.isEmpty ? "暂无备份" : "没有符合筛选的备份")
                            .foregroundColor(.secondary)
                    }
                    ForEach(sortedExternalBackups, id: \.self) { folderURL in
                        restoreRow(for: folderURL)
                    }
                }
            }
            // 3.8.335：删备份闪退第三修——List 身份绑版本号，
            // 删备份时 +1 强制整体重建、不走 diff，绕过
            // Invalid update 整类问题（见 backupListVersion）。
            .id(backupListVersion)
            .navigationTitle("lc.settings.restoreBackup".loc)
            .onAppear {
                czfDirectCoverAppeared = true
                backupFolderList = backupFolders(fromExternal: false)
                externalBackupFolderList = Self.externalBackupFolderURL() != nil ? backupFolders(fromExternal: true) : []
                lockedBackupNames = Self.lockedBackupNameSet()
                restoreSheetNotice = nil
                refreshBackupSizes()
            }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    // sheet 内操作反馈优先显示（删备份的结果
                    // 在这里交代，不跨层弹外层提示）；无反馈
                    // 时显示备份总占用
                    if let notice = restoreSheetNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if backupSizes.count == backupFolderList.count + externalBackupFolderList.count && !(backupFolderList.isEmpty && externalBackupFolderList.isEmpty) {
                        Text("本地 \(backupFolderList.count) 个 · iCloud \(externalBackupFolderList.count) 个，共占用 \(backupSizeText(backupSizes.values.reduce(0, +)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        // 3.8.366：直进时 body 本身就是恢复页（无盖子），
                        // 取消直接 dismiss 整页回 App 页；正常进页时
                        // 恢复页是盖子，关盖子回数据管理页。
                        if initialSheet == .restore {
                            dismiss()
                        } else {
                            showRestoreSelect = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button {
                            showSelectBackups = true
                        } label: {
                            Label("选择备份…", systemImage: "checkmark.circle")
                        }
                        Button {
                            presentExportPickerForAll()
                        } label: {
                            Label("一键导出全部", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            showDeleteAllBackupsConfirm = true
                        } label: {
                            Label("一键删除全部", systemImage: "trash")
                        }
                    } label: {
                        Text("全部")
                    }
                }
            }
            .confirmationDialog("确定删除全部备份？", isPresented: $showDeleteAllBackupsConfirm, titleVisibility: .visible) {
                Button("删除全部", role: .destructive) {
                    deleteAllBackups()
                }
                Button("lc.common.cancel".loc, role: .cancel) {}
            } message: {
                Text("将删除本地 \(backupFolderList.count) 个 + iCloud \(externalBackupFolderList.count) 个备份，此操作不可恢复")
            }
            // 单个删除改用 alert：同页已有两个 confirmationDialog
            // 时确认框会一闪而过（多 dialog 同层抢占）；alert
            // 在 sheet 内是唯一弹窗，不抢占
            .alert("确定删除这个备份？", isPresented: $showDeleteBackupConfirm) {
                Button("删除", role: .destructive) {
                    let url = pendingDeleteBackupURL
                    pendingDeleteBackupURL = nil
                    // 闪退修（325 没盖住这条：单删仍崩 Invalid update
                    // section 3，7→7、删 1 个）：325 只修了
                    // deleteBackup 里的数据源（从磁盘重载），但
                    // 没修执行时机——alert 确认按钮里同步改
                    // backupFolderList，List 的 diff 与 alert
                    // 消失合并成一次更新，UICollectionView 拿
                    // 到“删了 1 个”却看到数据源还是 7 条，直接
                    // 崩。挪到下一轮 runloop：alert 先消失，
                    // 列表再单独更新 7→6，两次干净更新，不再合并。
                    if let url {
                        DispatchQueue.main.async {
                            deleteBackup(at: url)
                        }
                    }
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    pendingDeleteBackupURL = nil
                }
            } message: {
                // 3.8.307：写清本地 + iCloud 份一起删（306
                // 起单删就两边都清，文案不写用户以为只删一边）
                Text("将删除备份「\(pendingDeleteBackupURL?.lastPathComponent ?? "")」（本地 + iCloud 份一起删），此操作不可恢复")
            }
            // iCloud 未设时在 sheet 内直接选文件夹：选完
            // 刷新 iCloud 列表 + 体积，不用关 sheet 重进
            .sheet(isPresented: $showRestoreSheetFolderPicker) {
                FolderPickerView { url in
                    saveExternalBackupFolder(url)
                    externalBackupFolderList = backupFolders(fromExternal: true)
                    refreshBackupSizes()
                }
            }
            // v216：恢复前备份清单预览（恢复 sheet 内再叠一层
            // sheet；“恢复”走恢复行同一条路：关预览、关恢复
            // sheet、设 pendingRestoreURL、弹 scope 弹窗）
            // 3.8.340：预览也改真全屏——339 只改了恢复选页，
            // 预览还是半屏 sheet，用户 16:38 截图实证：预览
            // 顶上露一截、底下恢复页从缝里透出来，看着还是
            // “俩个页面”。预览左上角已有“取消”按钮。
            .fullScreenCover(isPresented: $showBackupPreview) {
                NavigationView {
                    Group {
                        if previewLoading && previewItems.isEmpty {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("正在加载清单…")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List {
                                ForEach(previewItems, id: \.folderName) { item in
                                    previewRow(for: item)
                                }
                            }
                        }
                    }
                    .navigationTitle("备份清单预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showBackupPreview = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            // 3.8.404：范围选择独立成页——NavigationLink
                            // 推入 CZFScopeChoiceView，选完 pop 回来。
                            NavigationLink {
                                CZFScopeChoiceView(
                                    isBackup: false,
                                    apps: [],
                                    restoreAll: false,
                                    restoreURL: previewFolderURL,
                                    restoreFolders: [],
                                    isDirectEntry: false,
                                    onChoose: { loginOnly in
                                        if let url = self.previewFolderURL {
                                            self.pendingRestoreURL = url
                                            self.pendingRestoreAll = false
                                            self.doRestoreScope(loginOnly: loginOnly)
                                        }
                                    }
                                )
                            } label: {
                                Text("恢复")
                            }
                            .disabled(previewFolderURL == nil)
                        }
                    }
                }
            }
            // 选择性多选（3.8.283：选择备份双动作）：恢复
            // sheet 内再叠一层 sheet（与文件夹 picker、清
            // 单预览同款嵌套，不关恢复 sheet；“删除”先弹
            // 自己的确认框再删，锁了的跳过并报数；“恢复”
            // 走范围弹窗，一键恢复全部已挪到列表顶部单独一行）
            // 3.8.340：多选页也改真全屏（同预览的修法，半屏
            // sheet 顶上露缝、底下恢复页透出来就是“俩个页面”）。
            .fullScreenCover(isPresented: $showSelectBackups) {
                NavigationView {
                    List {
                        if selectBackupFolders.isEmpty {
                            Text("暂无备份")
                                .foregroundColor(.secondary)
                        }
                        ForEach(selectBackupFolders, id: \.self) { folderURL in
                            HStack {
                                VStack(alignment: .leading) {
                                    HStack(spacing: 4) {
                                        Text(folderURL.lastPathComponent)
                                            .font(.headline)
                                        // 3.8.281：锁了的备份挂 🔒
                                        if lockedBackupNames.contains(folderURL.lastPathComponent) {
                                            Image(systemName: "lock.fill")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                    Text("\(backupDateText(for: folderURL)) · \(backupSizeLabel(for: folderURL))\(Self.backupScopeBadge(folderURL))")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: selectedBackupFolderURLs.contains(folderURL) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(.blue)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedBackupFolderURLs.contains(folderURL) {
                                    selectedBackupFolderURLs.remove(folderURL)
                                } else {
                                    selectedBackupFolderURLs.insert(folderURL)
                                }
                            }
                        }
                    }
                    .navigationTitle("选择备份")
                    .navigationBarTitleDisplayMode(.inline)
                    .onAppear {
                        selectBackupFolders = mergedBackupFolders()
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("lc.common.cancel".loc) { showSelectBackups = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            // 3.8.283：选择备份双动作（用户纠正 282 的
                            // 单删）：勾中了既能删也能恢复——删除先确认
                            // 再删（锁了的跳过并报数），恢复走范围弹窗
                            HStack {
                                Button(allSelectBackupsSelected ? "取消全选" : "全选") {
                                    if allSelectBackupsSelected {
                                        selectedBackupFolderURLs.removeAll()
                                    } else {
                                        selectedBackupFolderURLs = Set(selectBackupFolders)
                                    }
                                }
                                HStack {
                                    Button("删除", role: .destructive) {
                                        showDeleteMultiSelectConfirm = true
                                    }
                                    // 3.8.404：范围选择独立成页——
                                    // NavigationLink 推入 CZFScopeChoiceView。
                                    NavigationLink {
                                        CZFScopeChoiceView(
                                            isBackup: false,
                                            apps: [],
                                            restoreAll: false,
                                            restoreURL: nil,
                                            restoreFolders: selectBackupFolders.filter { selectedBackupFolderURLs.contains($0) },
                                            isDirectEntry: false,
                                            onChoose: { loginOnly in
                                                self.pendingRestoreFolders = selectBackupFolders.filter { selectedBackupFolderURLs.contains($0) }
                                                self.pendingRestoreAll = false
                                                self.pendingRestoreURL = nil
                                                self.doRestoreScope(loginOnly: loginOnly)
                                            }
                                        )
                                    } label: {
                                        Text("恢复")
                                    }
                                }
                                .disabled(selectBackupFolders.filter { selectedBackupFolderURLs.contains($0) }.isEmpty)
                            }
                        }
                    }
                    // 3.8.282：多选删备份的确认框（挂在选择备份 sheet 里，
                    // 才能盖在它上面弹；已锁定的不会删，文案里先说清）
                    .alert("确定删除所选备份？", isPresented: $showDeleteMultiSelectConfirm) {
                        Button("删除", role: .destructive) {
                            deleteSelectedBackups()
                        }
                        Button("lc.common.cancel".loc, role: .cancel) {}
                    } message: {
                        // 3.8.307：写清本地 + iCloud 份一起删
                        //（306 起多选删就两边都清，文案不写
                        // 用户以为只删一边）
                        Text("将删除所选的 \(selectBackupFolders.filter { selectedBackupFolderURLs.contains($0) }.count) 个备份（本地 + iCloud 份一起删），已锁定的不会删，此操作不可恢复")
                    }
                }
            }
        }
        // 3.8.317：用户 21:54 截图——从面板图标打开恢复时，内层
        // 恢复 sheet 顶部短一截（外层 sheet 还在呈现动画里就
        // 弹了内层，按未落定的容器布局）。改大号定额，强制满高。
        // 3.8.317 修复：直接调 .presentationDetents 编不过
        //（构建 #364 唯一红字，部署目标 15.0），走包了
        // #available 的 czfPresentationDetentsLarge。
        .czfPresentationDetentsLarge()
    }

    var body: some View {
        // 3.8.366：恢复页直进只弹一次——initialSheet == .restore 时
        // body 直接就是恢复页（restoreBackupContent），不再先 present
        // 数据管理壳、再盖 fullScreenCover；点一次只弹一页，
        // 点取消直接 dismiss 回 App 页。正常进页仍走下面的 Form。
        if initialSheet == .restore {
            restoreBackupContent
                .onAppear { onAppearFunc() }
                .alert("lc.common.error".loc, isPresented: $errorShow){
                    // v216：恢复后“无可恢复数据”的文件夹，在结果弹窗里
                    // 直接给打开按钮（点过就清空，不漏到下一次无关弹窗）。
                    // 为空时 builder 仍为空，走默认“好”按钮，行为不变。
                    if !pendingNoDataFolders.isEmpty {
                        ForEach(pendingNoDataFolders) { entry in
                            Button("在文件 App 里打开「\(entry.name)」") {
                                openFolderInFiles(entry.folder)
                                pendingNoDataFolders = []
                            }
                        }
                        Button("好", role: .cancel) {
                            pendingNoDataFolders = []
                        }
                    }
                } message: {
                    Text(errorInfo)
                }
                .alert("lc.common.success".loc, isPresented: $successShow){
                    if !pendingNoDataFolders.isEmpty {
                        ForEach(pendingNoDataFolders) { entry in
                            Button("在文件 App 里打开「\(entry.name)」") {
                                openFolderInFiles(entry.folder)
                                pendingNoDataFolders = []
                            }
                        }
                        Button("好", role: .cancel) {
                            pendingNoDataFolders = []
                        }
                    }
                } message: {
                    Text(successInfo)
                }
        } else if czfDirectScopeOpen {
            // 3.8.404：直进备份直接返回范围选页（与 366 的 .restore
            // 直返 restoreBackupContent 同款）——不再先 present
            // 数据管理壳、再等 UIKit 弹窗；选页本身就是内容，选完
            // 置 czfScopeChosen，由直进收尾机制 0.3 秒后关页。
            CZFScopeChoiceView(
                isBackup: true,
                apps: czfDirectScopeApps,
                restoreAll: false,
                restoreURL: nil,
                restoreFolders: [],
                isDirectEntry: true,
                onChoose: { loginOnly in
                    self.pendingBackupApps = self.czfDirectScopeApps
                    self.czfScopeChosen = true
                    self.doBackupScope(loginOnly: loginOnly)
                    // 3.8.408：选完直接调收尾——Form 分支上的
                    // .onChange(of: czfScopeChosen) 在直进时还不存在
                    // （body 直返选页、Form 根本没渲染），选完翻回
                    // Form 时值已是 true、不会再触发；不调这一句，
                    // didApplyInitialSheet 即便为 true 也没人关 sheet。
                    self.czfDismissIfDirectEntryDone()
                }
            )
            // 3.8.408：直进选页出现即置 didApplyInitialSheet——
            // onAppearFunc 只挂在 .restore 分支与 Form 分支，直进
            // 时根本不跑；不置这一位，收尾函数的 guard 永远提前返回。
            .onAppear { self.didApplyInitialSheet = true }
        } else {
        // 3.8.408：删 CZFNavWrap——NavigationStack 嵌在 NavigationView
        // 里是未定义行为，设置页“备份全部”的 NavigationLink 被它吞了
        // （点一下什么都不出，用户 404/406 真机报）。三路入口（设置页
        // NavigationLink、坞 sheet、App 列表 NavigationLink）与各 sheet
        // 内页（预览/多选/备份选页/恢复页）都已有 NavigationView 祖先，
        // Form 直接放，不再包导航容器。
        Form {
            // 3.8.404：面板直进范围框已独立成页 CZFScopeChoiceView
            //（body 直返，见 czfDirectScopeOpen），此页内选框删除。
            // #20：储存总览已拆成独立文件 LCStorageOverviewSection
            LCStorageOverviewSection()

            Section {
                Button {
                    exportCZFSettings()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "square.and.arrow.up", color: .blue)
                        Text("导出设置")
                    }
                }
                Button {
                    showSettingsImporter = true
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "square.and.arrow.down", color: .green)
                        Text("导入设置")
                    }
                }
            } header: {
                Text("设置备份")
            } footer: {
                Text("把节点列表、每个 App 的 VPN 标记、窗口位置、手势灵敏度等 CZF 设置，连同 App 排序、固定区图标顺序与快捷行图标顺序、定时备份/定时清理设置、已添加源，一起打包成一个 JSON 文件（CZFSettingsBackup.json）。点「导出设置」直接存：本地文稿根目录一份，你在下面选的备份文件夹里自动也一份；改了 App 排序、每次备份 App 时那份都会自动刷新。换机或重装后导入即可恢复；App 排序与固定区顺序导入后直接生效，其余设置重启 LiveContainer 后生效。")
            }
            .fileImporter(isPresented: $showSettingsImporter, allowedContentTypes: [UTType.json]) { result in
                switch result {
                case .success(let url):
                    importCZFSettings(from: url)
                case .failure(let error):
                    settingsTransferMessage = "导入失败：\(error.localizedDescription)"
                    showSettingsTransferAlert = true
                }
            }
            .alert("设置备份", isPresented: $showSettingsTransferAlert) {
                Button("lc.common.ok".loc) {}
            } message: {
                Text(settingsTransferMessage ?? "")
            }

            Section {
                if sharedModel.multiLCStatus != 2 {
                    Button {
                        moveAppGroupFolderFromPrivateToAppGroup()
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "tray.and.arrow.up.fill", color: .blue)
                            Text("lc.settings.appGroupPrivateToShare".loc)
                        }
                    }
                    Button {
                        moveAppGroupFolderFromAppGroupToPrivate()
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "tray.and.arrow.down.fill", color: .green)
                            Text("lc.settings.appGroupShareToPrivate".loc)
                        }
                    }

                    Button {
                        Task { await moveDanglingFolders() }
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "folder.fill", color: .orange)
                            Text("lc.settings.moveDanglingFolderOut".loc)
                        }
                    }
                }
                // 3.8.281：清理按钮收进可收起的“清理”组（平时只占一行）。
                DisclosureGroup("清理", isExpanded: $cleanupSectionExpanded) {
                    if sharedModel.multiLCStatus != 2 {
                        Button(role:.destructive) {
                            Task { await cleanUpUnusedFolders() }
                        } label: {
                            HStack {
                                LCSettingsIcon(systemName: "trash", color: .red)
                                Text("lc.settings.cleanDataFolder".loc)
                            }
                        }
                    }

                Button(role:.destructive) {
                    Task { await removeKeyChain() }
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "key.fill", color: .orange)
                        Text("lc.settings.cleanKeychain".loc)
                    }
                }

                Button(role:.destructive) {
                    Task { await clearTemporaryFiles() }
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "doc.fill", color: .gray)
                        Text("lc.settings.cleanTmp".loc)
                    }
                }
                
                Button(role:.destructive) {
                    Task { await clearCacheFiles() }
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "externaldrive.fill", color: .blue)
                        Text("lc.settings.cleanCaches".loc) 
                    }
                }
                }

            }

            Section(header: Text("lc.settings.backupRestore".loc)) {
                if let progress = backupRestoreProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(progress)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                // 备份/恢复进行中禁用入口：跑一半再点一个会并发
                // 跑两份，备份互相覆盖、恢复互相抢容器；进度条
                // 在上面走着时入口全灰，跑完自动恢复。
                // 3.8.404：范围选择独立成页——NavigationLink 推入
                // CZFScopeChoiceView（选完 pop 回来，不再在按钮
                // 下面长内联选框）。
                NavigationLink {
                    CZFScopeChoiceView(
                        isBackup: true,
                        apps: sharedModel.apps + sharedModel.hiddenApps,
                        restoreAll: false,
                        restoreURL: nil,
                        restoreFolders: [],
                        isDirectEntry: false,
                        onChoose: { loginOnly in
                            self.pendingBackupApps = sharedModel.apps + sharedModel.hiddenApps
                            self.doBackupScope(loginOnly: loginOnly)
                        }
                    )
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "doc.on.doc", color: .blue)
                        Text("lc.settings.backupAll".loc)
                    }
                }
                .disabled(backupRestoreProgress != nil)
                Button {
                    showBackupSelect = true
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "checkmark.circle.fill", color: .green)
                        Text("lc.settings.backupSelected".loc)
                    }
                }
                .disabled(backupRestoreProgress != nil)
                Button {
                    loadScheduleSettings()
                    showScheduleBackup = true
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "clock.fill", color: .orange)
                        Text("定时备份")
                        Spacer()
                        if scheduleEnabled {
                            Text(String(format: "%02d:%02d", scheduleHour, scheduleMinute))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }
                Button {
                    // 恢复合一：直接开 sheet，本地 + iCloud 同屏，
                    // 不再先弹“选哪个文件夹”
                    showRestoreSelect = true
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "arrow.clockwise", color: .green)
                        Text("lc.settings.restoreBackup".loc)
                    }
                }
                .disabled(backupRestoreProgress != nil)
            }
            // 3.8.281：换机迁移向导搬进恢复 sheet 里（备份组只留 4 行）；
            // 向导 sheet 挂在组上，入口在恢复 sheet 内。
            .sheet(isPresented: $showMigrationWizard) {
                migrationWizardView
                    .interactiveDismissDisabled(migrationRunning)
            }
            
            Section {
                Button {
                    Task { await clearIconCache() }
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "photo.fill", color: .purple)
                        Text("lc.settings.clearIconCache".loc)
                    }
                }
                Button {
                    cacheScheduleEnabled = UserDefaults.standard.bool(forKey: "LCScheduleCacheEnabled")
                    cacheScheduleHour = UserDefaults.standard.integer(forKey: "LCScheduleCacheHour")
                    cacheScheduleMinute = UserDefaults.standard.integer(forKey: "LCScheduleCacheMinute")
                    if UserDefaults.standard.object(forKey: "LCScheduleCacheHour") == nil {
                        cacheScheduleHour = 3
                        cacheScheduleMinute = 0
                        // 3.8.355：与定时备份同款——默认时间写回，
                        // 免得静默判断读到缺键的 0:00 当天立刻清一次。
                        UserDefaults.standard.set(cacheScheduleHour, forKey: "LCScheduleCacheHour")
                        UserDefaults.standard.set(cacheScheduleMinute, forKey: "LCScheduleCacheMinute")
                    }
                    showScheduleCache = true
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "clock.fill", color: .orange)
                        Text("定时清理缓存")
                        Spacer()
                        if cacheScheduleEnabled {
                            Text(String(format: "%02d:%02d", cacheScheduleHour, cacheScheduleMinute))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Section {
                // 3.8.281：路径行收进可收起的“存储位置”组（平时只占一行）。
                DisclosureGroup("存储位置", isExpanded: $storageLocationExpanded) {
                    ForEach(folderPaths, id:\.desc) { path in
                    HStack(spacing: 10) {
                        Text(path.desc)
                        Spacer()
                        if filzaInstalled {
                            Button {
                                openInFilza(path: path.path)
                            } label: {
                                Text("Filza")
                            }
                            .buttonStyle(.bordered)
                        }
                        Button {
                            copy(text: path.path.path)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                }
            }
        }
        // 3.8.337：直进时本页只是空壳——标题留空、导航栏藏掉、
        // 内容透明，内层页没弹出来之前用户只看到一张白纸，不
        // 会看到数据管理列表（“别弹窗俩个出来”）。正常进页时
        // initialSheet 为 nil，三行全按原样。
        // 3.8.343：opacity 不能写死 initialSheet != nil 就 0——
        // 内层页/范围选页万一没出来（342 实证：.backupAll
        // 只走范围选页，init 不开页），用户就永远卡在一张白纸上。改成只在
        // 内层页或范围框真的开着时才藏本页；都没开时显示本
        // 页内容（再由 czfDismissIfDirectEntryDone 关页回
        // App 页），永不白纸。
        // 3.8.345：上面这套 opacity 是白顶的根因——视频实证
        // （2026-11-07 19:12）：恢复页/备份选页打开时顶部
        // 先白一大块、约 1 秒后才正常。盖子是 fullScreenCover
        // 本来就不透明，盖上后本页自然被遮住，根本不需要
        // opacity 藏；opacity 一置 0，盖子上滑动画还没盖到
        // 顶部时，顶部露出的就是透明本页后面的白底。删掉
        // opacity，动画过程里用户看到的是本页内容（正常），
        // 盖子盖满后本页自然被遮；盖子关掉后本页恢复可见，
        // 再由 czfDismissIfDirectEntryDone 关页回 App 页。
        .navigationTitle(initialSheet == nil ? "lc.settings.dataManagement".loc : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(initialSheet != nil)
        .alert("lc.common.error".loc, isPresented: $errorShow){
            // v216：恢复后“无可恢复数据”的文件夹，在结果弹窗里
            // 直接给打开按钮（点过就清空，不漏到下一次无关弹窗）。
            // 为空时 builder 仍为空，走默认“好”按钮，行为不变。
            if !pendingNoDataFolders.isEmpty {
                ForEach(pendingNoDataFolders) { entry in
                    Button("在文件 App 里打开「\(entry.name)」") {
                        openFolderInFiles(entry.folder)
                        pendingNoDataFolders = []
                    }
                }
                Button("好", role: .cancel) {
                    pendingNoDataFolders = []
                }
            }
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow){
            if !pendingNoDataFolders.isEmpty {
                ForEach(pendingNoDataFolders) { entry in
                    Button("在文件 App 里打开「\(entry.name)」") {
                        openFolderInFiles(entry.folder)
                        pendingNoDataFolders = []
                    }
                }
                Button("好", role: .cancel) {
                    pendingNoDataFolders = []
                }
            }
        } message: {
            Text(successInfo)
        }
        .alert("lc.settings.cleanDataFolder".loc, isPresented: $appFolderRemovalAlert.show) {
            if folderRemoveCount > 0 {
                Button(role: .destructive) {
                    appFolderRemovalAlert.close(result: true)
                } label: {
                    Text("lc.common.delete".loc)
                }
            }

            Button("lc.common.cancel".loc, role: .cancel) {
                appFolderRemovalAlert.close(result: false)
            }
        } message: {
            if folderRemoveCount > 0 {
                Text("lc.settings.cleanDataFolderConfirm %lld".localizeWithFormat(folderRemoveCount))
            } else {
                Text("lc.settings.noDataFolderToClean".loc)
            }

        }
        .alert("lc.settings.cleanKeychain".loc, isPresented: $keyChainRemovalAlert.show) {
            Button(role: .destructive) {
                keyChainRemovalAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }

            Button("lc.common.cancel".loc, role: .cancel) {
                keyChainRemovalAlert.close(result: false)
            }
        } message: {
            Text("lc.settings.cleanKeychainDesc".loc)
        }
        .alert("lc.settings.cleanTmp".loc, isPresented: $tmpRemovalAlert.show) {
            Button(role: .destructive) {
                tmpRemovalAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }

            Button("lc.common.cancel".loc, role: .cancel) {
                tmpRemovalAlert.close(result: false)
            }
        } message: {
            Text("lc.settings.cleanTmpConfirm".loc)
        }
        .alert("lc.settings.cleanCaches".loc, isPresented: $cacheRemovalAlert.show) {
    Button(role: .destructive) {
        cacheRemovalAlert.close(result: true)
    } label: {
        Text("lc.common.delete".loc)
    }

    Button("lc.common.cancel".loc, role: .cancel) {
        cacheRemovalAlert.close(result: false)
    }
} message: {
    Text("lc.settings.cleanCacheConfirm".loc) 
}

        .onAppear {
            onAppearFunc()
        }
        // 3.8.337：直进收尾——五路内层页/弹窗任一关上时都查一遍
        // 是不是全关了，全关了本页也关（见 czfDismissIfDirectEntryDone）。
        .onChange(of: showRestoreSelect) { _ in czfDismissIfDirectEntryDone() }
        .onChange(of: showBackupSelect) { _ in czfDismissIfDirectEntryDone() }
        .onChange(of: showScheduleBackup) { _ in czfDismissIfDirectEntryDone() }
        // 3.8.404：范围选择独立成页——直进范围选完置
        // czfScopeChosen，收尾靠它触发（旧 dialog 位已删）。
        .onChange(of: czfScopeChosen) { _ in czfDismissIfDirectEntryDone() }
        // 12：备份结果弹窗点掉（successShow/errorShow 由
        // true 变 false）时也查一遍——直进备份跑完后结果弹着，
        // 收尾被 guard 拦住，用户点掉弹窗后才轮到关页。
        .onChange(of: successShow) { _ in czfDismissIfDirectEntryDone() }
        .onChange(of: errorShow) { _ in czfDismissIfDirectEntryDone() }
        // 真全屏：325 的 sheet + large detent 顶上仍留一条缝——
        // sheet 的 large 本来就不是全屏，顶边留边距+圆角，底下
        // 的设置页总从缝里露出来，detent 再调也盖不住（系统
        // sheet 帧自带顶边距，公开 API 去不掉）。改 fullScreenCover
        // 顶满整屏；代价是没了下滑关闭手势，所以左上角补一个
        // “取消”按钮（没它用户改主意就关不掉面板了）。内容、
        // 备份按钮流程一字不动。范围框 3.8.340 起改 .alert
        // （见上面），不再是挂父视图的 confirmationDialog。
        .fullScreenCover(isPresented: $showBackupSelect) {
            NavigationView {
                List(sharedModel.apps + sharedModel.hiddenApps, id: \.self) { app in
                    HStack {
                        Text(app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown")
                        Spacer()
                        Image(systemName: backupSelectedIDs.contains(Self.instanceKey(for: app)) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(.blue)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let key = Self.instanceKey(for: app)
                        if backupSelectedIDs.contains(key) {
                            backupSelectedIDs.remove(key)
                        } else {
                            backupSelectedIDs.insert(key)
                        }
                    }
                }
                .onAppear { czfDirectCoverAppeared = true }
                .navigationTitle("lc.settings.backupSelected".loc)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("lc.common.cancel".loc) {
                            showBackupSelect = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        HStack {
                            Button(allBackupSelected ? "取消全选" : "全选") {
                                if allBackupSelected {
                                    backupSelectedIDs.removeAll()
                                } else {
                                    backupSelectedIDs = Set((sharedModel.apps + sharedModel.hiddenApps).map { Self.instanceKey(for: $0) })
                                }
                            }
                            // 3.8.404：范围选择独立成页——NavigationLink
                            // 推入 CZFScopeChoiceView，选完 pop 回来；
                            // doBackupScope 仍关选页（见其本体）。
                            NavigationLink {
                                CZFScopeChoiceView(
                                    isBackup: true,
                                    apps: (sharedModel.apps + sharedModel.hiddenApps).filter {
                                        backupSelectedIDs.contains(Self.instanceKey(for: $0))
                                    },
                                    restoreAll: false,
                                    restoreURL: nil,
                                    restoreFolders: [],
                                    isDirectEntry: false,
                                    onChoose: { loginOnly in
                                        self.pendingBackupApps = (sharedModel.apps + sharedModel.hiddenApps).filter {
                                            backupSelectedIDs.contains(Self.instanceKey(for: $0))
                                        }
                                        self.doBackupScope(loginOnly: loginOnly)
                                    }
                                )
                            } label: {
                                Text("lc.settings.backup".loc)
                            }
                            // 零勾选禁用确认：以前零勾选也能走完还报
                            // 成功（空跑一趟）；现在没勾就不让点。
                            .disabled(backupSelectedIDs.isEmpty)
                        }
                    }
                }
            }
        }
        // 3.8.339：恢复页改真全屏——原来是半屏 sheet，直进时
        // 顶上露一截空白壳（数据管理页 opacity 0），用户看
        // 着就是“俩个页面”（用户 16:07 报）。备份选页 329
        // 起就是全屏，恢复页跟它一致；左上角已有“取消”按钮。
        .fullScreenCover(isPresented: $showRestoreSelect) {
            restoreBackupContent
        }
        .sheet(isPresented: $showScheduleBackup) {
            NavigationView {
                Form {
                    Section {
                        Toggle("启用定时备份", isOn: $scheduleEnabled)
                    }
                    // 3.8.306：定时备份失败别静默——上次失败记在
                    // LCScheduleBackupLastFailure，打开这页就看得见。
                    if let lastFailure = UserDefaults.standard.string(forKey: "LCScheduleBackupLastFailure") {
                        Section {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("上次定时备份失败：\(lastFailure)")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    Section(header: Text("备份范围")) {
                        Picker("范围", selection: $scheduleKeychainOnly) {
                            Text("完整（数据+登录态）").tag(false)
                            Text("只备份登录态").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    Section(header: Text("备份时间（每天）")) {
                        HStack {
                            Picker("时", selection: $scheduleHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                            Text(":")
                            Picker("分", selection: $scheduleMinute) {
                                ForEach(0..<60, id: \.self) { m in
                                    Text(String(format: "%02d", m)).tag(m)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                        }
                        .frame(height: 120)
                    }
                    Section(header: Text("选择要备份的 App")) {
                        ForEach(sharedModel.apps + sharedModel.hiddenApps, id: \.self) { app in
                            HStack {
                                Text(app.appInfo.displayName() ?? "")
                                Spacer()
                                let key = Self.instanceKey(for: app)
                                Image(systemName: scheduleSelectedIDs.contains(key) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(.blue)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let key = Self.instanceKey(for: app)
                                if scheduleSelectedIDs.contains(key) {
                                    scheduleSelectedIDs.remove(key)
                                } else {
                                    scheduleSelectedIDs.insert(key)
                                }
                            }
                        }
                    }
                }
                .onAppear { czfDirectCoverAppeared = true }
                .navigationTitle("定时备份")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showScheduleBackup = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saveScheduleSettings()
                            showScheduleBackup = false
                            successInfo = scheduleEnabled ? "定时备份已启用，每天 \(String(format: "%02d:%02d", scheduleHour, scheduleMinute)) 执行" : "定时备份已关闭"
                            successShow = true
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showScheduleCache) {
            NavigationView {
                Form {
                    Section {
                        Toggle("启用定时清理缓存", isOn: $cacheScheduleEnabled)
                    }
                    Section(header: Text("执行时间")) {
                        HStack {
                            Picker("时", selection: $cacheScheduleHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                            Picker("分", selection: $cacheScheduleMinute) {
                                ForEach(0..<60, id: \.self) { m in
                                    Text(String(format: "%02d", m)).tag(m)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Section(footer: Text("每天到点自动清理图标缓存。当天没赶上时，下次打开 LiveContainer 补执行。")) {
                        EmptyView()
                    }
                }
                .navigationTitle("定时清理缓存")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showScheduleCache = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saveCacheScheduleSettings()
                            showScheduleCache = false
                            successInfo = cacheScheduleEnabled ? "定时清理已启用，每天 \(String(format: "%02d:%02d", cacheScheduleHour, cacheScheduleMinute)) 执行" : "定时清理已关闭"
                            successShow = true
                        }
                    }
                }
            }
        }
        }
    }
    
    // 3.8.337：直进收尾——initialSheet 触发的内层页/弹窗全关了，
    // 本页也关掉（回 App 页）。只在直进时跑；正常进数据管理页
    // 时 initialSheet 为 nil，一律不关。判“全关”不是判某一个，
    // 是五路全 false——备份选页点“备份”会先关选页再弹范围框，
    // 只看选页会误关，范围选页开着时不关。
    // 3.8.338 修：立刻判会误关——点“备份”那一下，选页关和范围
    // 选页出现是两次状态变化，onChange 先看到选页关了、范围选页
    // 还没出来，当场判全关就把本页关了，范围选页挂在本页身上、
    // 跟着一起没了，用户就看不到选页（用户 15:16 报）。改延迟
    // 0.3 秒再判，等范围选页出来再看，就不会误关；用户点取消
    // 关页时多等 0.3 秒才回 App 页，几乎感觉不到。
    // 3.8.404：范围框改独立选页后，收尾改看 czfDirectScopeOpen
    //（选页开着 = 直进范围未选）；选完置 czfScopeChosen，选页
    // 收起，0.3 秒后关页。
    // 3.8.404：直进备份是否直接返回范围选页（body 分支条件）。
    // 直进 .backupAll/.backupScope 且未预选时为真；有预选时
    // onAppearFunc 直接 doBackupScope，不经选页；选完置
    // czfScopeChosen 后为假，body 回到 Form，收尾机制关页。
    // .backupScope 且 directBackupApps 为空时不直返（落回 Form，
    // 不退回全部 App）。
    private var czfDirectScopeOpen: Bool {
        (initialSheet == .backupAll || initialSheet == .backupScope)
            && preselectedLoginOnly == nil
            && !czfScopeChosen
            && (initialSheet != .backupScope || !directBackupApps.isEmpty)
    }
    // 3.8.404：直进范围选页要备的 App——.backupScope 只备
    // directBackupApps 那一个（或几个），.backupAll 备全部。
    private var czfDirectScopeApps: [LCAppModel] {
        initialSheet == .backupScope ? directBackupApps : (sharedModel.apps + sharedModel.hiddenApps)
    }
    private func czfDismissIfDirectEntryDone() {
        guard initialSheet != nil else { return }
        guard didApplyInitialSheet else { return }
        // 12：备份进行中（backupRestoreProgress 非空）或结果
        // 弹窗正弹着（successShow/errorShow）时不关页——原来
        // 选完范围 0.3 秒就关，备份后台跑几分钟，结果 alert
        // 挂在已关的页上弹不出（用户报“备份弹窗从来没弹过”）。
        // 关页等备份跑完、用户点掉结果弹窗后再由 onChange 触发。
        guard backupRestoreProgress == nil else { return }
        guard !successShow, !errorShow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.initialSheet != nil else { return }
            guard !self.showRestoreSelect, !self.showBackupSelect, !self.showScheduleBackup,
                  !self.czfDirectScopeOpen else { return }
            // 12：0.3 秒里备份可能刚启动、结果弹窗可能刚弹，
            // 关前再拦一道，别把进行中的备份/正弹的结果关掉。
            guard self.backupRestoreProgress == nil else { return }
            guard !self.successShow, !self.errorShow else { return }
            self.dismiss()
        }
    }

    func onAppearFunc() {
        if !appeared {
            for app in sharedModel.apps {
                if app.appInfo.bundleIdentifier() == "com.tigisoftware.Filza" {
                    filzaInstalled = true
                    break
                }
            }
            appeared = true
        }
        // 3.8.313：直开某动作——只跑一次（关掉内层 sheet 后
        // 本页重现时不再重复弹）。包一层 async，让外层 sheet
        // 先落定再弹内层，避免两层 sheet 同帧抢呈现。
        // 3.8.317：一个 runloop 不够——外层 sheet 呈现动画约
        // 0.35 秒，内层在动画中途弹会按未落定的容器布局，
        // 顶部短一截（用户 21:54 截图）。改 0.5 秒，等落定。
        // 3.8.337：直进时本页是空壳（opacity 0），0.5 秒白屏
        // 太久；NavigationLink 推入没有外层 sheet 动画要等，
        // 改 0.1 秒，内层页几乎立刻出来。
        // 3.8.338：0.1 秒还是闪白页——推入动画 0.35 秒里空壳
        // 先滑进来，内层页 0.1 秒后才弹，用户就看到一张白页
        // 3.8.342：直进内层页改在 init 里开（见 init 注释），
        // 这里只剩 .backupAll/.backupScope 兜底——范围选页是
        // body 内容，不等 sheet 落定，备好待备份 App 即可。
        // 其余三路（.restore/.backupSelect/.scheduleBackup）
        // 已在 init 里开好、didApplyInitialSheet 为 true，
        // 这里的 switch 是兜底（init 万一没开上时再开一次）。
        if !didApplyInitialSheet, let sheet = initialSheet {
            didApplyInitialSheet = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.0) {
                switch sheet {
                case .restore:
                    self.showRestoreSelect = true
                case .backupSelect:
                    self.showBackupSelect = true
                case .backupAll:
                    // 3.8.404：范围选择独立成页——body 已直返
                    // CZFScopeChoiceView（见 czfDirectScopeOpen），
                    // 这里只备好待备份 App，不再弹任何框。
                    self.pendingBackupApps = sharedModel.apps + sharedModel.hiddenApps
                case .backupScope:
                    // 3.8.349：只备 directBackupApps 里那一个
                    // App，直出范围框。空数组绝不弹（也不退回
                    // 全部 App）；空时本页是空壳，收尾五路全
                    // false 会由 czfDismissIfDirectEntryDone
                    // 关掉，不留白页。
                    // 3.8.359：面板单独弹窗已预选范围时不
                    // 再弹框，直接按预选备份。
                    guard !self.directBackupApps.isEmpty else { return }
                    self.pendingBackupApps = self.directBackupApps
                    if let loginOnly = self.preselectedLoginOnly {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.doBackupScope(loginOnly: loginOnly)
                        }
                    } else {
                        // 3.8.404：范围选择独立成页——body 已直返
                        // CZFScopeChoiceView（见 czfDirectScopeOpen），
                        // 这里只备好待备份 App，不再置任何位。
                    }
                case .scheduleBackup:
                    self.loadScheduleSettings()
                    self.showScheduleBackup = true
                }
            }
        }
        // 3.8.344 根因 2：init 置 true 的盖子可能在外层 sheet
        // 动画（约 0.35 秒）中被 SwiftUI 丢弃，且 didApplyInitialSheet
        // 已为 true 堵死上面兜底，无任何重试，白页永久化。0.6 秒
        // 后检查确认位：盖子内容 onAppear 置过 true 说明已出来，
        // 不动；仍 false 说明丢了，做 false→true 跳变（分两个
        // runloop，先 false 再 async true）强制重 present；再
        // 0.6 秒后仍没出来就把开关清回 false，让 opacity 公式放
        // 本页恢复可见（用户可手动点），永不永久白纸。
        if didApplyInitialSheet, let sheet = initialSheet {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard !self.czfDirectCoverAppeared else { return }
                switch sheet {
                case .restore:
                    // 3.8.366：直进时 body 本身就是恢复页，没有盖子
                    // 可恢复，不翻开关（翻了也无盖子可弹，还可能
                    // 误触 onChange 收尾）。
                    break
                case .backupSelect:
                    self.showBackupSelect = false
                    DispatchQueue.main.async { self.showBackupSelect = true }
                case .scheduleBackup:
                    self.showScheduleBackup = false
                    DispatchQueue.main.async { self.showScheduleBackup = true }
                case .backupAll:
                    return
                case .backupScope:
                    // 3.8.404：范围选页是 body 内容、不占盖子，没有
                    // 重 present 一说，同 .backupAll 直接返回。
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard !self.czfDirectCoverAppeared else { return }
                    switch sheet {
                    case .restore: break
                    case .backupSelect: self.showBackupSelect = false
                    case .scheduleBackup: self.showScheduleBackup = false
                    case .backupAll: break
                    case .backupScope: break
                    }
                }
            }
        }
        externalFolderName = Self.externalBackupFolderURL()?.lastPathComponent
        // 兜底：把本地备份补齐同步到外部文件夹（后台线程，避免大备份拷贝卡界面）
        // 节流：6 小时内已同步过就跳过。原来每次打开本页都全量比对+补拷，
        // 和到期的定时备份叠在一起抢 I/O；备份动作本身已即时同步到外部
        // 文件夹，这里只兜底捡漏，不需要每次打开都跑一遍。
        let lastSync = UserDefaults.standard.double(forKey: "LCExternalSyncLastRun")
        if Date().timeIntervalSince1970 - lastSync > 6 * 3600 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "LCExternalSyncLastRun")
            Task.detached {
                Self.syncAllLocalBackupsToExternalFolder()
            }
        }
        // 检查定时备份
        Task { await checkAndRunScheduledBackup() }
        // 检查定时清理缓存
        Task { await checkAndRunScheduledCache() }
    }

    // MARK: - 外部备份文件夹（iCloud Drive 等，经文件选择器授权 + bookmark 持久化）

    private static var cachedExternalFolderURL: URL? = nil

    func saveExternalBackupFolder(_ url: URL) {
        // 创建侧 withSecurityScope = 1 << 11（不是 1 << 10，
        // 那是 suitableForBookmarkFile；CZFLocalIpaFolderView 同款）。
        let czfWithSecurityScope: UInt = 1 << 11
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: URL.BookmarkCreationOptions(rawValue: czfWithSecurityScope), includingResourceValuesForKeys: nil, relativeTo: nil) else {
            errorInfo = "保存文件夹授权失败，请重新选择"
            errorShow = true
            return
        }
        // 建完当场解出来验 startAccessing 能过，才算真有 scope、
        // 才存；验不过就不存，别拿无 scope 书签冒充。
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: URL.BookmarkResolutionOptions(rawValue: 1 << 10), relativeTo: nil, bookmarkDataIsStale: &isStale),
              resolved.startAccessingSecurityScopedResource() else {
            errorInfo = "保存文件夹授权失败，请重新选择"
            errorShow = true
            return
        }
        resolved.stopAccessingSecurityScopedResource()
        UserDefaults.standard.set(data, forKey: "LCExternalBackupFolderBookmark")
        Self.cachedExternalFolderURL = nil
        externalFolderName = url.lastPathComponent
        // 立即把已有本地备份同步过去（后台线程）
        Task.detached {
            Self.syncAllLocalBackupsToExternalFolder()
        }
        successInfo = "备份文件夹已设置：\(url.lastPathComponent)\n之后的备份会同步到该文件夹，恢复时也会从该文件夹读取"
        successShow = true
    }

    static func externalBackupFolderURL() -> URL? {
        if let cached = Self.cachedExternalFolderURL {
            return cached
        }
        guard let data = UserDefaults.standard.data(forKey: "LCExternalBackupFolderBookmark") else { return nil }
        var stale = false
        // 先按 security scope 解析（1 << 10），不行再按普通方式解析
        // （老书签是无 scope 的；CZFLocalIpaFolderView.restore 同款回落）。
        let url: URL
        if let scoped = try? URL(resolvingBookmarkData: data, options: URL.BookmarkResolutionOptions(rawValue: 1 << 10), relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = scoped
        } else if let plain = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = plain
        } else {
            return nil
        }
        // 本次运行内保持访问权限，供列表/恢复/删除直接使用；
        // 拿不到访问权限就当没配过，别把打不开的 URL 缓存下来。
        guard url.startAccessingSecurityScopedResource() else { return nil }
        Self.cachedExternalFolderURL = url
        return url
    }

    // 把刚备份好的 App 文件夹同步到外部文件夹（同名覆盖）
    // 静态化：函数体只用 externalBackupFolderURL 和 FileManager，不碰
    // 视图状态，静态后可从后台线程直接调（备份重活整体挪后台用）。
    static func syncBackupsToExternalFolder(appNames: [String], backupRoot: URL) {
        guard let extURL = Self.externalBackupFolderURL() else { return }
        let fm = FileManager.default
        for name in appNames {
            let src = backupRoot.appendingPathComponent(name)
            let dest = extURL.appendingPathComponent(name)
            // 防丢：先拷到临时名、拷完再换上；原来是先删外部
            // 那份再拷，拷到一半断网/被杀就是外部新旧两空。
            // 临时名带点前缀，恢复列表（skipsHiddenFiles）不显示
            let tmp = extURL.appendingPathComponent(".czf-sync-tmp-\(name)")
            if fm.fileExists(atPath: tmp.path) {
                try? fm.removeItem(at: tmp)
            }
            guard (try? fm.copyItem(at: src, to: tmp)) != nil else { continue }
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            try? fm.moveItem(at: tmp, to: dest)
        }
    }

    // 生成设置备份 JSON 并落盘：本地文稿根目录一份；已设置外部
    // 备份文件夹（「iCloud 备份文件夹」选的那个）时，同一份直接
    // 写进那个文件夹根目录，与 App 备份放一起，不用再手动选位置。
    // 静态：备份 App 的后台流程结束时也顺手刷新一份（自动备份）。
    /// 导出时除 CZF 键外，另带上的 LC 设置键：排序和定时。
    /// 只列设置本身，不带执行记录（LCSchedule*LastDate）和敏感/
    /// 设备相关键（证书数据/密码、外部文件夹书签等），那些不进备份。
    static let settingsBackupExtraStandardKeys: Set<String> = [
        "LCScheduleBackupEnabled", "LCScheduleBackupHour", "LCScheduleBackupMinute",
        "LCScheduleBackupAppIDs", "LCScheduleBackupKeychainOnly",
        "LCScheduleCacheEnabled", "LCScheduleCacheHour", "LCScheduleCacheMinute",
        // 标准库里的 LC 开关：原来只拷 CZF 前缀 + 定时这两类，
        // 设置页里这些 LC 开关一个都没进备份，恢复后全丢。
        // 证书/密码/书签/设备号（LCCertificate*、LCDeviceUDID、
        // 外部文件夹书签）一律不进，见下表外的排除原则。
        "LCSwitchAppWithoutAsking", "LCOpenWebPageWithoutAsking",
        "LCMultiAllowGameMode", "LCMultiAllowGameCategory",
        "LCLaunchMultitaskMaximized", "LCLaunchInMultitaskMode",
        "LCFrameShortcutIcons", "LCLoadTweaksToSelf",
        "LCKeepSelectedWhenQuit", "LCKeepAliveEnabled",
        "LCIgnoreJITOnLaunch", "LCWaitForDebugger",
        "LCSharePrivateDataWithLiveProcess",
        // 已添加源：2026-10-31 10:59 用户改口，设置备份导出
        // 也要包括已添加源（推翻 04:18 不进备份的决定）。源地址
        // 存在标准库（LCAltStoreSourcesView 读写标准库），进这
        // 张标准表后导出、恢复、手动导入三路都走同一分支：
        // 导出时 writeCZFSettingsBackup 读标准库带上它，恢复/
        // 导入时 applySettingsDictionary 按本表写回标准库。
        // 证书/密码/书签/设备号仍不进（见上排除原则）。
        "LCAltStoreSourceURLs",
    ]
    static let settingsBackupAppGroupKeys: Set<String> = [
        "LCAppSortType", "LCCustomSortOrder",
        // 新1（3.8.277）：多套排序方案与正在用的方案名也进备份。
        "LCCustomSortSchemes", "LCCustomSortSchemeCurrent",
        // App Group 里的开关：排序之外这些原来也没进备份。
        // CZFMin* 三个也在 App Group 里（设置页 @AppStorage
        // 指明了 store），必须进这张表——导入先判这张表，
        // 否则按 CZF 前缀误写标准库，界面读 App Group 等于没恢复。
        // LCDeviceUDID 是设备号，不进（换机恢复会写错设备）。
        "darkModeIcon", "dynamicColors",
        "LCMultitaskMode", "LCMultitaskBottomWindowBar",
        "LCAutoEndPiP", "LCSkipTerminatedScreen",
        "LCRestartTerminatedApp", "LCMaxOneAppOnStage",
        "LCDockWidth", "LCHideCollapsedDock", "LCHideDock",
        "LCRedirectURLToHost", "LCDontSignApp", "LCStrictHiding",
        "LCSideJITServerAddress", "LCSelected32BitEmulator", "LCJITEnablerType",
        "CZFMinPowerSavingEnabled", "CZFMinAutoCloseEnabled", "CZFMinAutoCloseMinutes",
        // 新4（3.8.288）：固定区列表 CZFPinnedPanelApps 也在 App Group
        // 里（CZFPinnedAppsStore 读 App Group），不进这张表导入时
        // 按 CZF 前缀误写标准库，固定区读不到等于没恢复（同上）。
        "CZFPinnedPanelApps",
        // 新5（3.8.379）：面板快捷行 CZFPanelCustomShortcuts 也改存
        // App Group（同上），不进这张表导入时按 CZF 前缀误写标准库，
        // 面板读不到等于没恢复。
        "CZFPanelCustomShortcuts",
        // 新6（3.8.459 审计）：固定区旧键迁移完成标记
        // CZFPinnedPanelAppsMigratedV2 也在 App Group 里
        //（CZFPinnedAppsStore.migrateLegacyPins 读 App Group）。
        // 它带 CZF 前缀，导出时 App Group 全量扫会带上它，
        // 不进这张表导入时按 CZF 前缀误写标准库，读它的地方
        // 永远读不到，恢复/导入后迁移每回重跑一次（现迁移
        // 只转换不删，重跑无害，但往返本就该对得上）。
        "CZFPinnedPanelAppsMigratedV2",
        // 新7（3.8.459 审计）：多开启动优先级 LCMultiLaunchPriority
        // 也在 App Group 里（LCMultiLCManagementView 读写 App
        // Group），是用户排过的设置；LC 前缀既不进 CZF 全量扫、
        // 也不在这张表里，恢复后启动顺序全丢。补进来。
        "LCMultiLaunchPriority",
    ]

    // 注意：@discardableResult 必须紧贴 func 写，中间不能插
    // static let，否则编译报 attribute 不能用在这条声明上，
    // 269b523 那次构建 #233 就是这么挂的。
    // 3.8.448 闪退真因（用户 16:10 报“打开APP都闪退”，
    // Invalid type in JSON write (__NSCFData)）：payload 是
    // 全量扫 CZF 前缀的 UserDefaults，书签
    // CZFLocalIpaFolderBookmark（Data）也被扫进来，
    // JSONSerialization 遇到 Data 抛 NSException——try? 拦
    // 不住 NSException，直接闪退。修法：进 payload 前先验
    // 是不是合法 JSON 值（String/数字/布尔/数组/字典/null），
    // Data/Date 等一律跳过；书签本来就不该进设置备份。
    private static func czfIsJSONValue(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber, is NSNull:
            return true
        case let array as [Any]:
            return array.allSatisfy { czfIsJSONValue($0) }
        case let dict as [String: Any]:
            return dict.values.allSatisfy { czfIsJSONValue($0) }
        default:
            return false
        }
    }

    @discardableResult
    static func writeCZFSettingsBackup() -> (local: URL?, externalFolderName: String?, externalWriteFailed: Bool) {
        let skip: Set<String> = ["CZFUpdatableAppCount", "CZFLastSourceAutoRefresh"]
        // 定时打开的按日标记（CZFSchedMinLastDate-<bid>）不进备份：
        // 带进备份、恢复后当天定时打开被跳过一次。按前缀跳过，
        // 不是精确集合（bid 各不相同）。
        var payload: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("CZF") && !skip.contains(key) && !key.hasPrefix("CZFSchedMinLastDate-") && czfIsJSONValue(value) {
            payload[key] = value
        }
        // App Group 里的 CZF 键也要：最小化省电三个开关存在
        // App Group 里，只扫标准库会漏掉它们；已在 payload
        // 里的（标准库同名）不动，标准库优先。
        for (key, value) in LCUtils.appGroupUserDefault.dictionaryRepresentation() where key.hasPrefix("CZF") && !skip.contains(key) && !key.hasPrefix("CZFSchedMinLastDate-") && payload[key] == nil && czfIsJSONValue(value) {
            payload[key] = value
        }
        // 排序在 App Group 里、定时备份/清理在标准库里但前缀是 LC，
        // 原来只拷 CZF 的逻辑会漏掉这两类，这里显式补上。
        let standard = UserDefaults.standard
        for key in settingsBackupExtraStandardKeys {
            if let value = standard.object(forKey: key), czfIsJSONValue(value) {
                payload[key] = value
            }
        }
        let appGroup = LCUtils.appGroupUserDefault
        for key in settingsBackupAppGroupKeys {
            if let value = appGroup.object(forKey: key), czfIsJSONValue(value) {
                payload[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return (nil, nil, false)
        }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return (nil, nil, false) }
        let localURL = docs.appendingPathComponent("CZFSettingsBackup.json")
        var writtenLocal: URL? = nil
        do {
            try data.write(to: localURL, options: .atomic)
            writtenLocal = localURL
        } catch { }
        var extName: String? = nil
        var extFailed = false
        if let extURL = Self.externalBackupFolderURL() {
            let dest = extURL.appendingPathComponent("CZFSettingsBackup.json")
            do {
                try data.write(to: dest, options: .atomic)
                extName = extURL.lastPathComponent
            } catch {
                // 3.8.487：外部写失败要分得清——原来只返 extName，
                // 导出处分不清“没配文件夹”和“配了但写失败”，后者
                // 也报“选好文件夹后自动存一份”，用户以为已备到
                // iCloud、实际只有本地有。失败要单独报出来。
                extFailed = true
            }
        }
        return (writtenLocal, extName, extFailed)
    }

    // P7（3.8.280）：设置备份写盘防抖 + 后台写——原来每次启动/
    // 切节点/改排序都在主线程同步做两次全量 dictionaryRepresentation
    // + JSON + 两次原子写盘。备份只是尽力快照，不必每次同步落盘：
    // 0.5 秒内多次调用只留最后一次，实际写放后台串行队列。调度
    // 永远走主队列（调用方可能在备份任务的后台队列里），静态
    // workItem 只在主线程碰，不加锁。需要立即拿到文件的导出流程
    //（exportCZFSettings）继续走上面那个同步原函数，不走这里。
    // 极端情况（改完设置 0.5 秒内杀进程）最多丢最后一次快照，
    // 磁盘上仍是上一次的完整备份，设置本身在 UserDefaults 里不受影响。
    private static var settingsBackupWorkItem: DispatchWorkItem?
    private static let settingsBackupQueue = DispatchQueue(label: "com.livecontainer.settingsBackup", qos: .utility)

    // B-5：备份串行队列——backupOneAppSync 的临时目录名只由
    // folderName 定（.czf-backup-tmp-<名>），四路备份（手动/
    // 批量/定时/覆盖前自动）并发会撞同一个临时目录、互相删/
    // 覆盖。backupOneAppSync 的入口只过这个队列，保证同一时
    // 刻只有一个备份在写临时目录。四路都在后台队列调它，串行
    // 队列只排队、不堵主线程。
    private static let czfBackupSerialQueue = DispatchQueue(label: "com.livecontainer.backup.serial", qos: .userInitiated)

    static func writeCZFSettingsBackupDebounced() {
        DispatchQueue.main.async {
            LCDataManagementView.settingsBackupWorkItem?.cancel()
            let item = DispatchWorkItem {
                LCDataManagementView.settingsBackupQueue.async {
                    _ = LCDataManagementView.writeCZFSettingsBackup()
                }
            }
            LCDataManagementView.settingsBackupWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
    }

    /// 备份文件夹是否有效：单 App 备份含 manifest.json，
    /// 旧时间戳结构含子文件夹。空目录不算备份：同步时不把它
    /// 扩散到 iCloud，免得那边也多个点进去恢复 0 个的空壳。
    /// 注意恢复列表不拿它过滤——iCloud 文件夹可能只是元数据
    /// 还没同步到，恢复时先触发下载等一等（见 restoreFromBackup），
    /// 直接过滤会把还没同步好的真备份也藏起来。
    static func isValidBackupFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
            return true
        }
        if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            return children.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return false
    }

    // 兜底同步：把本地备份里外部文件夹还缺的/过期的补过去（选文件夹后、打开数据管理页时调用）
    static func syncAllLocalBackupsToExternalFolder() {
        guard let extURL = Self.externalBackupFolderURL() else { return }
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        guard let localFolders = try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return }
        for src in localFolders {
            guard (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            // 本地空壳不同步到 iCloud，免得那边也多个空备份。
            guard Self.isValidBackupFolder(src) else { continue }
            let dest = extURL.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                // 两边都有：比较 manifest 修改时间，本地更新才覆盖
                let srcManifest = src.appendingPathComponent("manifest.json")
                let destManifest = dest.appendingPathComponent("manifest.json")
                // 没 manifest 的旧结构文件夹：两边都是 distantPast 会永远跳过、
                // 永远同步不到 iCloud；没 manifest 时退到文件夹本身的修改时间比
                let srcDate = (try? fm.attributesOfItem(atPath: srcManifest.path))?[.modificationDate] as? Date
                    ?? (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date ?? Date.distantPast
                let destDate = (try? fm.attributesOfItem(atPath: destManifest.path))?[.modificationDate] as? Date
                    ?? (try? fm.attributesOfItem(atPath: dest.path))?[.modificationDate] as? Date ?? Date.distantPast
                if destDate >= srcDate { continue }
                try? fm.removeItem(at: dest)
            }
            // 拷失败不留空壳：删掉拷一半的 dest，下次同步重拷；
            // 否则空目录会进恢复列表，点进去就是“成功 0 个”。
            if (try? fm.copyItem(at: src, to: dest)) == nil {
                try? fm.removeItem(at: dest)
            }
        }
    }
        func cleanUpUnusedFolders() async {
        
        var folderNameToAppDict : [String:LCAppModel] = [:]
        for app in sharedModel.apps {
            for container in app.appInfo.containers {
                folderNameToAppDict[container.folderName] = app;
            }
        }
        for app in sharedModel.hiddenApps {
            for container in app.appInfo.containers {
                folderNameToAppDict[container.folderName] = app;
            }
        }
        
        var foldersToDelete : [String]  = []
        for appDataFolderName in sharedModel.appDataFolderNames {
            if folderNameToAppDict[appDataFolderName] == nil {
                foldersToDelete.append(appDataFolderName)
            }
        }
        folderRemoveCount = foldersToDelete.count
        
        guard let result = await appFolderRemovalAlert.open(), result else {
            return
        }
        do {
            let fm = FileManager()
            for folder in foldersToDelete {
                try fm.removeItem(at: LCPath.dataPath.appendingPathComponent(folder))
                LCUtils.removeAppKeychain(dataUUID: folder)
                sharedModel.appDataFolderNames.removeAll(where: { s in
                    return s == folder
                })
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func removeKeyChain() async {
        guard let result = await keyChainRemovalAlert.open(), result else {
            return
        }
        
        [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassCertificate, kSecClassKey, kSecClassIdentity].forEach {
          let status = SecItemDelete([
            kSecClass: $0,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
          ] as CFDictionary)
          if status != errSecSuccess && status != errSecItemNotFound {
              //Error while removing class $0
              errorInfo = status.description
              errorShow = true
          }
        }
    }

    func clearTemporaryFiles() async {
        guard let result = await tmpRemovalAlert.open(), result else {
            return
        }

        let fm = FileManager.default
        let tmpDirectory = fm.temporaryDirectory

        do {
            let tmpItems = try fm.contentsOfDirectory(at: tmpDirectory, includingPropertiesForKeys: nil)

            if tmpItems.isEmpty {
                successInfo = "lc.settings.noTmpToClean".loc
                successShow = true
                return
            }

            for item in tmpItems {
                try fm.removeItem(at: item)
            }

            successInfo = "lc.settings.cleanTmpComplete".loc
            successShow = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func clearCacheFiles() async {
        guard let result = await cacheRemovalAlert.open(), result else {
            return
        }

        let fm = FileManager.default

        var allApps = sharedModel.apps + sharedModel.hiddenApps
        if UserDefaults.sideStoreExist() {
            allApps.append(LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared))
        }
        
        var cleanedCount = 0

        do {
            for app in allApps {
                for container in app.uiContainers {
                    let containerPath = container.containerURL
                    let guestCachePath = containerPath.appendingPathComponent("Library/Caches")
                    
                    if fm.fileExists(atPath: guestCachePath.path) {
                        let cacheItems = try fm.contentsOfDirectory(at: guestCachePath, includingPropertiesForKeys: nil)
                        for item in cacheItems {
                            try fm.removeItem(at: item)
                        }
                        cleanedCount += 1
                    }
                }
            }
            if let lcCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                fm.fileExists(atPath: lcCaches.path) {
                let cacheItems = try fm.contentsOfDirectory(at: lcCaches, includingPropertiesForKeys: nil)
                for item in cacheItems {
                    try fm.removeItem(at: item)
                }
                cleanedCount += 1
            }

            if cleanedCount == 0 {
                successInfo = "lc.settings.noCacheToClean".loc
            } else {
                successInfo = "lc.settings.cleanCacheComplete".loc
            }
            successShow = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    // 备份时间显示：优先 manifest 里记录的，旧备份没有就用 manifest 文件修改时间
    /// 文件夹递归总大小（备份体积显示用，后台线程算）
    static func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            // 3.8.317：软链目录不跟进——枚举器默认会钻进软链指
            // 向的目录，链回祖先就是死循环，统计永远算不完
            // （用户 2026-11-06 21:46 真机实证：数据管理
            // “正在统计…”一直卡住）。软链本身不计大小（目标
            // 在树内由实路径计一次，树外本就不该计）。
            if let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
               values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func backupSizeText(_ size: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: size)
    }

    func backupSizeLabel(for folderURL: URL) -> String {
        guard let size = backupSizes[folderURL] else {
            return "计算中…"
        }
        return backupSizeText(size)
    }

    /// 导出全部 CZF 设置：直接落盘，不再弹保存位置选择——
    /// 本地文稿根目录一份；选了「iCloud 备份文件夹」的话，
    /// 那个文件夹里自动也存一份（与 App 备份同处）
    func exportCZFSettings() {
        let (local, extName, extFailed) = Self.writeCZFSettingsBackup()
        if local != nil {
            if let extName {
                settingsTransferMessage = "设置备份已存好（CZFSettingsBackup.json）：本地文稿根目录一份，你选的备份文件夹「\(extName)」里也一份"
            } else if extFailed {
                settingsTransferMessage = "设置备份已存到本地文稿根目录（CZFSettingsBackup.json），但写进你选的备份文件夹失败了（iCloud 未同步或文件夹不可用），仅本地有这份"
            } else {
                settingsTransferMessage = "设置备份已存到本地文稿根目录（CZFSettingsBackup.json）。在下面选好「iCloud 备份文件夹」后，导出会自动也存一份到那个文件夹"
            }
        } else {
            settingsTransferMessage = "导出失败：设置备份写不进去"
        }
        showSettingsTransferAlert = true
    }

    /// 设置字典写回（不弹提示，供手动导入和恢复共用）：
    /// App Group 表先判——App Group 里的 CZF 键若按 CZF 前缀
    /// 走会误写标准库，界面读 App Group 就等于没恢复；再判
    /// CZF 前缀/标准扩展表 → 标准库；其余未知键一律不写
    /// （旧备份只有 CZF 键时行为不变，证书、书签这类敏感/
    /// 设备键就算进了文件也不会被导入）。返回（写回项数，
    /// 本次是否含排序键）。
    @discardableResult
    static func applySettingsDictionary(_ dict: [String: Any]) -> (count: Int, sortRestored: Bool) {
        var count = 0
        for (key, value) in dict {
            if Self.settingsBackupAppGroupKeys.contains(key) {
                LCUtils.appGroupUserDefault.set(value, forKey: key)
                count += 1
            } else if key.hasPrefix("CZF") || Self.settingsBackupExtraStandardKeys.contains(key) {
                UserDefaults.standard.set(value, forKey: key)
                count += 1
            }
        }
        // 排序键写回来了：当场让排序管理器重读重排，列表立即
        // 按恢复的顺序走，不用等重启（以前只改了 defaults，
        // 内存里的 customSortOrder 还是旧的，看着像没恢复）。
        // 新1：方案键也算排序键，reloadSortSettings 会一并重读方案。
        let sortRestored = dict["LCCustomSortOrder"] != nil || dict["LCAppSortType"] != nil || dict["LCCustomSortSchemes"] != nil || dict["LCCustomSortSchemeCurrent"] != nil
        if sortRestored {
            DispatchQueue.main.async { LCAppSortManager.shared.reloadSortSettings() }
        }
        // 3.8.316：固定区顺序也当场重读——CZFPinnedPanelApps
        // 与快捷行 CZFPanelCustomShortcuts 都已在导出里（前者
        // 在 AppGroup 白名单，后者走 CZF 前缀扫描），导入写回
        // 后固定区 store 内存还是旧的，不重读看着像没恢复；
        // 快捷行是面板 onAppear 时现读 customShortcuts，下次
        // 打开即按新顺序走，无需另调。
        if dict["CZFPinnedPanelApps"] != nil {
            DispatchQueue.main.async { CZFPinnedAppsStore.shared.reload() }
        }
        // 优5（3.8.277）：节点列表/活动下标写回来了：核心在跑
        // 时经现成入口重启切过去（applyActiveNodeChange 只在
        // 活动链接真变了时重启；测速窗口内推迟到收尾跟随），
        // 不需重启 App；核心停着下次启动现读。起核心是同步
        // 阻塞的 CGoInvoke，放 detached 跑，不冻调用线程
        //（导入在主线程、恢复在后台任务里都一样）。
        if dict["CZFVPNNodeLinks"] != nil || dict["CZFVPNNodeLink"] != nil || dict["CZFVPNActiveNodeIndex"] != nil {
            Task.detached(priority: .userInitiated) { CZFVPNManager.shared.applyRestoredNodeSettings() }
        }
        return (count, sortRestored)
    }

    /// 恢复时找设置备份并写回（只给完整恢复用，登录态恢复不
    /// 碰全局设置）：跟恢复源同侧优先（iCloud 恢复用外部根
    /// 的那份，本地恢复用文稿根的那份），首选没有再试另一侧；
    /// 两边都没有返回 found=false。返回（写回项数，找到没有，
    /// 本次是否含排序键）。
    static func restoreCZFSettings(for backupURL: URL) async -> (imported: Int, found: Bool, sortRestored: Bool) {
        let fm = FileManager.default
        let localJSON = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("CZFSettingsBackup.json")
        var candidates: [URL] = []
        if let extURL = Self.externalBackupFolderURL() {
            let extJSON = extURL.appendingPathComponent("CZFSettingsBackup.json")
            if backupURL.path.hasPrefix(extURL.path + "/") {
                candidates.append(extJSON)
                if let l = localJSON { candidates.append(l) }
            } else {
                if let l = localJSON { candidates.append(l) }
                candidates.append(extJSON)
            }
        } else if let l = localJSON {
            candidates.append(l)
        }
        for url in candidates {
            // 设置 JSON 在外部 iCloud 根，不在门/wait 覆盖内：
            // 占位时主线程现读会堵下载；只把 Data 放 detached，
            // 解析 + 写回仍在调用方线程（与钥匙串导入同款分工）。
            guard let data = await Task.detached { try? Data(contentsOf: url) }.value,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let applied = Self.applySettingsDictionary(dict)
            return (applied.count, true, applied.sortRestored)
        }
        return (0, false, false)
    }

    /// 导入设置备份：只认 CZF 开头的键和两张扩展表，逐个写回
    /// 对应 UserDefaults（标准库/App Group 分流见
    /// applySettingsDictionary）。JSON 数字回来是 NSNumber，
    /// UserDefaults 读写都认，不用特殊处理
    func importCZFSettings(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            settingsTransferMessage = "导入失败：这个文件不是有效的设置备份"
            showSettingsTransferAlert = true
            return
        }
        let (count, sortRestored) = Self.applySettingsDictionary(dict)
        // 优5（3.8.277）：恢复/导入后热生效的范围变了——手势、
        // 多任务栏、节点无需重启即生效（节点在核心运行时自动
        // 重连），定时、窗口模式与窗口位置下次打开 App 时生效。
        // 旧文案“重启后全部生效”已不准确，改掉。
        let hotNote = "手势、多任务栏、节点、分组已直接生效（核心在跑时节点自动重连），定时、窗口模式与窗口位置下次打开 App 时生效"
        settingsTransferMessage = sortRestored
            ? "已导入 \(count) 项设置，App 排序已直接恢复；\(hotNote)"
            : "已导入 \(count) 项设置；\(hotNote)"
        showSettingsTransferAlert = true
    }

    // #23：Backups 树单次遍历——原来恢复 sheet 里每个备份各
    // 递归扫一遍（N 个备份 = N 遍整树），现在每个根目录只扫
    // 一遍、按顶级文件夹归集大小；本地 + iCloud 两个根各一遍
    func refreshBackupSizes() {
        let localFolders = backupFolderList
        let externalFolders = externalBackupFolderList
        let extRoot = Self.externalBackupFolderURL()
        DispatchQueue.global(qos: .utility).async {
            var map: [URL: Int64] = [:]
            let fm = FileManager.default
            if let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                Self.accumulateSizes(into: &map, folders: localFolders, root: docsURL.appendingPathComponent("Backups"), fm: fm)
            }
            if let extURL = extRoot {
                Self.accumulateSizes(into: &map, folders: externalFolders, root: extURL, fm: fm)
            }
            DispatchQueue.main.async {
                backupSizes = map
            }
        }
    }

    // 单次枚举一棵树、按顶级文件夹归集文件大小。相对路径必须
    // 先解符号链接再剥前缀：枚举器给 /private/var，容器路径
    // 是 /var，直接拼会脏（v146 修过的同款坑）
    static func accumulateSizes(into map: inout [URL: Int64], folders: [URL], root: URL, fm: FileManager) {
        for folder in folders { map[folder] = 0 }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for case let fileURL as URL in enumerator {
            // 3.8.317：同 folderSize——软链目录不跟进，防链回
            // 祖先的死循环把恢复 sheet 的按备份大小也卡死。
            if let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
               values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let rel = Self.relativePath(of: fileURL, under: root),
                  let top = rel.split(separator: "/").first.map(String.init),
                  let folder = folders.first(where: { $0.lastPathComponent == top }) else { continue }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                map[folder, default: 0] += Int64(size)
            }
        }
    }

    func backupDateText(for folderURL: URL) -> String {
        let manifestURL = folderURL.appendingPathComponent("manifest.json")
        // 行日期跑在 body 主线程：iCloud 源 manifest 未下载时
        // Data(contentsOf:) 会触发隐式下载、慢网卡住界面；
        // 未同步跳过 Data 读、直接走下面 mtime 兜底（纯元数据，
        // 与读失败同款路径），绝不为了一行日期去拉下载。
        let manifestDownloaded: Bool = {
            guard let extURL = Self.externalBackupFolderURL(),
                  folderURL.path.hasPrefix(extURL.path + "/") else { return true }
            return Self.isFileDownloaded(manifestURL, underExternal: true)
        }()
        if manifestDownloaded,
           let data = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let dateStr = json["backupDate"], !dateStr.isEmpty {
            return "备份时间：\(dateStr)"
        }
        let fm = FileManager.default
        let date = (try? fm.attributesOfItem(atPath: manifestURL.path))?[.modificationDate] as? Date
            ?? (try? fm.attributesOfItem(atPath: folderURL.path))?[.modificationDate] as? Date
        if let date {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            return "备份时间：\(fmt.string(from: date))"
        }
        return ""
    }

    func backupFolders(fromExternal: Bool) -> [URL] {
        let fm = FileManager.default
        var allFolders: [URL] = []
        if fromExternal {
            if let extURL = Self.externalBackupFolderURL(),
               let folders = try? fm.contentsOfDirectory(at: extURL, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) {
                allFolders += folders
            }
        } else if let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let backupsURL = docsURL.appendingPathComponent("Backups")
            if let folders = try? fm.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) {
                allFolders += folders
            }
        }
        return allFolders.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast) ?? Date.distantPast > (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast) ?? Date.distantPast }
    }

    // 恢复 sheet 的一行：本地/iCloud 两个区共用同一行式样
    /// v216：清单预览的一行。空备份用红字直标（纯文本弹窗
    /// 做不到着色，预览 sheet 里可以——这是预览存在的意义之一）。
    @ViewBuilder
    func previewRow(for item: BackupPreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.displayName)
                    .font(.headline)
                if item.isEmptyBackup {
                    Text("空备份：恢复会是 0 个")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            Text(previewDetailLine(for: item))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    func previewDetailLine(for item: BackupPreviewItem) -> String {
        var parts: [String] = [item.folderName]
        switch item.scope {
        case "full": parts.append("完整")
        case "login": parts.append("登录态")
        case "keychain": parts.append("仅钥匙串")
        default: parts.append("未知范围")
        }
        if !item.backupDate.isEmpty { parts.append(item.backupDate) }
        parts.append("容器 \(item.containerCount) 个")
        if let kc = item.keychainCount {
            parts.append(item.keychainSynced ? "钥匙串 \(kc) 条" : "钥匙串 \(kc) 条（部分未同步）")
        } else {
            parts.append("钥匙串：无快照")
        }
        if let sf = item.sessionFileCount {
            parts.append(sf > 100000 ? "会话文件 100000+ 个" : "会话文件 \(sf) 个")
        } else if item.scope == "full" || item.scope.isEmpty {
            parts.append("会话文件含在整容器里")
        }
        if item.hasAppBundle { parts.append("含安装包") }
        return parts.joined(separator: " · ")
    }

    // 3.8.307：恢复列表排序/筛选——时间按 manifest backupDate
    // 倒序（新→旧，字符串本身是 yyyy-MM-dd HH:mm，字典序即
    // 时间序）；名字按文件夹名不区分大小写；只看登录态按
    // manifest scope == "login"。每行 manifest 只读一次，
    // 列表几十个以内，现场读够用。
    private func applyBackupSortFilter(to folders: [URL]) -> [URL] {
        var list = folders
        if backupLoginOnlyFilter {
            list = list.filter { Self.manifestInfo(of: $0)?.scope == "login" }
        }
        if backupSortMode == 1 {
            list.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            list.sort { (Self.manifestInfo(of: $0)?.backupDate ?? "") > (Self.manifestInfo(of: $1)?.backupDate ?? "") }
        }
        return list
    }
    private var sortedLocalBackups: [URL] { applyBackupSortFilter(to: backupFolderList) }
    private var sortedExternalBackups: [URL] { applyBackupSortFilter(to: externalBackupFolderList) }

    @ViewBuilder
    func restoreRow(for folderURL: URL) -> some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(folderURL.lastPathComponent)
                        .font(.headline)
                        // 3.8.310：名字只显示一行（用户斥“app 名字
                        // 都挡住了”——大按钮把名字栏挤窄，名字折
                        // 成两三行；按钮改小后名字有地方了，一行
                        // 放不下就截断，不再折行）。
                        .lineLimit(1)
                    // 3.8.281：锁了的备份行首挂 🔒
                    if lockedBackupNames.contains(folderURL.lastPathComponent) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    // 3.8.306：钥匙串健康色——绿=有令牌、橙=快照为空、
                    // 红=无快照；iCloud 未下载时不显示
                    if let health = Self.backupKeychainHealth(folderURL) {
                        HStack(spacing: 2) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundColor(health == "ok" ? .green : health == "empty" ? .orange : .red)
                            Text(health == "ok" ? "钥匙串" : health == "empty" ? "快照空" : "无快照")
                                .font(.caption2)
                                .foregroundColor(health == "ok" ? .green : health == "empty" ? .orange : .red)
                        }
                    }
                }
                Text("\(backupDateText(for: folderURL)) · \(backupSizeLabel(for: folderURL))\(Self.backupScopeBadge(folderURL))")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            // v216：点行文本区先看清单预览（恢复/导出按钮仍是
            // 自己的动作，不被手势抢；预览里的“恢复”走同一条
            // pendingRestoreURL + scope 弹窗路）
            .contentShape(Rectangle())
            .onTapGesture {
                previewFolderURL = folderURL
                // 先弹 sheet 给加载反馈：清单枚举在后台算，
                // 算完再填表；连点两行时只认最后一次（先算完的
                // 旧结果不覆盖新行），防异步时序错位。
                previewItems = []
                previewLoading = true
                showBackupPreview = true
                Task {
                    let items = await Self.previewItems(for: folderURL)
                    if previewFolderURL == folderURL {
                        previewItems = items
                        previewLoading = false
                    }
                }
            }
            Spacer()
            // 3.8.282：锁开关放行上（不只左滑）：用户说“锁定备份
            // 开关没看到”——左滑才有的入口太藏，行内直接给一个
            // 锁钮（橙=已锁，灰=未锁），点一下即锁/解锁
            // 3.8.307：三个按钮都加大触摸区——锁钮给 44pt
            // 最小边（图标小但手能点中），恢复/导出用大号
            // 控件，行内按钮不再挤在一起误点
            // 3.8.310：用户斥恢复行按钮太大太丑、App 名字都
            // 被挡住了——恢复/导出改回常规尺寸，名字栏有地方
            // 了（名字另加 lineLimit(1) 不再折行）。
            Button {
                toggleBackupLock(folderName: folderURL.lastPathComponent)
            } label: {
                Image(systemName: lockedBackupNames.contains(folderURL.lastPathComponent) ? "lock.fill" : "lock.open")
                    .foregroundColor(lockedBackupNames.contains(folderURL.lastPathComponent) ? .orange : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                // 3.8.404：范围选择独立成页——置位后由行尾隐藏
                // NavigationLink 程序化推入 CZFScopeChoiceView。
                czfRowRestoreScopeURL = folderURL
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                    Text("恢复")
                }
                .foregroundColor(.blue)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            Button {
                presentExportPicker(for: folderURL)
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("导出")
                }
                .foregroundColor(.blue)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        // 3.8.404：行“恢复”的范围选页——List 行里直接放
        // NavigationLink 会在行尾多一个 chevron，改用隐藏链接 +
        // isActive 程序化推入（NavigationView 语境、iOS 15 可用；
        // isActive 在 iOS 16+ 已弃用但仍可编译运行）。
        .background(
            NavigationLink(
                destination: CZFScopeChoiceView(
                    isBackup: false,
                    apps: [],
                    restoreAll: false,
                    restoreURL: folderURL,
                    restoreFolders: [],
                    isDirectEntry: false,
                    onChoose: { loginOnly in
                        self.pendingRestoreURL = folderURL
                        self.pendingRestoreAll = false
                        self.doRestoreScope(loginOnly: loginOnly)
                    }
                ),
                isActive: Binding(
                    get: { czfRowRestoreScopeURL == folderURL },
                    set: { active in if !active { czfRowRestoreScopeURL = nil } }
                ),
                label: { EmptyView() }
            )
            .hidden()
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                // 删单个备份原来左滑直接删（删全部反而有
                // 确认框）：备份含整套数据/登录态，误滑
                // 不可恢复，先确认再删
                pendingDeleteBackupURL = folderURL
                showDeleteBackupConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            // 3.8.281：锁/解锁（删锁定的要先解锁，见 deleteBackup）
            Button {
                toggleBackupLock(folderName: folderURL.lastPathComponent)
            } label: {
                Label(lockedBackupNames.contains(folderURL.lastPathComponent) ? "解锁" : "锁定", systemImage: lockedBackupNames.contains(folderURL.lastPathComponent) ? "lock.open" : "lock")
            }
            .tint(.orange)
        }
    }

    // 3.8.281：恢复列表里锁/解锁一个备份（写 UserDefaults + 同步
    // 界面用的 @State 集合；锁本身按文件夹名记）。
    func toggleBackupLock(folderName: String) {
        let locked = !lockedBackupNames.contains(folderName)
        Self.setBackupLocked(folderName, locked: locked)
        if locked {
            lockedBackupNames.insert(folderName)
        } else {
            lockedBackupNames.remove(folderName)
        }
    }

    func deleteBackup(at backupURL: URL) {
        // 3.8.281：锁了的备份不删，先解锁（恢复列表左滑锁/解锁）。
        if lockedBackupNames.contains(backupURL.lastPathComponent) {
            restoreSheetNotice = "已锁定，先解锁才能删除：\(backupURL.lastPathComponent)"
            return
        }
        do {
            try FileManager.default.removeItem(at: backupURL)
            // 3.8.306：单删也清 iCloud 份——合并列表本地优先，
            // 同名备份只留本地那条 URL，删本地不删 iCloud 的话
            // 外部那份下次刷新又冒出来。deleteAllBackups 早就
            // 两边都删，单删/多选删照抄它。
            if let externalRoot = Self.externalBackupFolderURL() {
                try? FileManager.default.removeItem(at: externalRoot.appendingPathComponent(backupURL.lastPathComponent))
            }
            // 闪退修（删文件 Invalid update，section 3 本地备份
            // 7→7 但删了 1 个）：原来用 removeAll { $0 == url }
            // 逐条删，URL 写法稍有出入（iCloud 书签解析的
            // /private 前缀、编码差异）就会漏删，数据源还剩
            // 7 条、List 却已按删了 1 条算，直接崩。改成删完
            // 从磁盘重载两张列表（与 deleteAllBackups /
            // deleteSelectedBackups 同款），以磁盘为准，数一定
            // 对得上；锁了/删失败时不走这里，数组不动。
            backupFolderList = backupFolders(fromExternal: false)
            externalBackupFolderList = Self.externalBackupFolderURL() != nil ? backupFolders(fromExternal: true) : []
            // 3.8.335 第三修：334 又崩在 iCloud 区——删完重载
            // 仍见文件（iCloud 同步滞后、目录枚举残留），数据源
            // 7→7、List 却按删了 1 个算。重载后再按名字硬性
            // 剔掉已删那条（按 lastPathComponent，不靠 URL 相等），
            // 数一定对得上；再 +1 逼 List 整体重建、不走 diff，
            // 两道保险，整类 Invalid update 绕过去。
            let deletedName = backupURL.lastPathComponent
            backupFolderList.removeAll { $0.lastPathComponent == deletedName }
            externalBackupFolderList.removeAll { $0.lastPathComponent == deletedName }
            backupListVersion += 1
            // 反馈只写 sheet 底部的提示行：不关 sheet、不弹外
            // 层提示——删完留在列表里继续操作，跨层弹提示是
            // 前两版按钮点不动的根源
            restoreSheetNotice = "已删除备份：\(backupURL.lastPathComponent)"
        } catch {
            restoreSheetNotice = "删除失败：\(LCUtils.czfFriendlyError(error))"
        }
    }

    func deleteAllBackups() {
        let fm = FileManager.default
        var deleted = 0
        // 3.8.281：锁了的不删
        var lockedSkipped = 0
        // 本地+iCloud 同一份备份（同名）只算一次：两边各删一份
        // 是对的，但计数按 URL 涨两次，用户看到的“已删除 N 个”虚高。
        var countedNames: Set<String> = []
        for url in backupFolderList + externalBackupFolderList {
            let name = url.lastPathComponent
            if lockedBackupNames.contains(name) {
                if countedNames.insert(name).inserted {
                    lockedSkipped += 1
                }
                continue
            }
            if (try? fm.removeItem(at: url)) != nil {
                if countedNames.insert(name).inserted {
                    deleted += 1
                }
            }
        }
        backupFolderList = backupFolders(fromExternal: false)
        externalBackupFolderList = Self.externalBackupFolderURL() != nil ? backupFolders(fromExternal: true) : []
        // 3.8.335：同 deleteBackup，List 重建、不走 diff。
        backupListVersion += 1
        restoreSheetNotice = "已删除 \(deleted) 个备份" + (lockedSkipped > 0 ? "，\(lockedSkipped) 个已锁定未删" : "")
    }

    // 3.8.283：多选删备份（选择备份 sheet 的删除路）：锁了的
    // 不删，报数；删完刷新两张列表、清勾选、关 sheet，
    // 结果写恢复 sheet 底部的提示行。换机向导的一键恢复不受影响，
    // 它直接调 restoreSelectedBackups，不走这条。
    func deleteSelectedBackups() {
        let selected = selectBackupFolders.filter { selectedBackupFolderURLs.contains($0) }
        let fm = FileManager.default
        var deleted = 0
        var lockedSkipped = 0
        for url in selected {
            if lockedBackupNames.contains(url.lastPathComponent) {
                lockedSkipped += 1
                continue
            }
            if (try? fm.removeItem(at: url)) != nil {
                deleted += 1
                // 3.8.306：多选删也清 iCloud 份——合并列表本地优先，
                // 同名备份只留本地那条 URL，删本地不删 iCloud 的话
                // 外部那份下次刷新又冒出来。deleteAllBackups 早就
                // 两边都删，照抄它。
                if let externalRoot = Self.externalBackupFolderURL() {
                    try? fm.removeItem(at: externalRoot.appendingPathComponent(url.lastPathComponent))
                }
            }
        }
        backupFolderList = backupFolders(fromExternal: false)
        externalBackupFolderList = Self.externalBackupFolderURL() != nil ? backupFolders(fromExternal: true) : []
        // 3.8.335：同 deleteBackup，List 重建、不走 diff。
        backupListVersion += 1
        selectedBackupFolderURLs.removeAll()
        showSelectBackups = false
        restoreSheetNotice = "已删除 \(deleted) 个备份" + (lockedSkipped > 0 ? "，\(lockedSkipped) 个已锁定未删" : "")
    }

    /// 恢复/导出“全部”用的合并列表：本地在前，iCloud 只补
    /// 本地没有的同名备份（同名以本地为准，本地通常更新；
    /// 避免同一 App 被旧 iCloud 备份二次覆盖）
    func mergedBackupFolders() -> [URL] {
        var seen = Set<String>()
        var merged: [URL] = []
        for folder in backupFolderList + externalBackupFolderList {
            if seen.insert(folder.lastPathComponent).inserted {
                merged.append(folder)
            }
        }
        return merged
    }

    /// 把一个 App 的整套数据备份到 Backups/<显示名>（先写
    /// 临时目录、写完换名覆盖，防丢）：manifest + .app + 各
    /// 数据容器 + 组容器 + 钥匙串快照。backupApps 的批量循环
    /// 和覆盖安装前的自动备份都走这里。同步执行，调用方自己
    /// 挪到后台队列
    @discardableResult
    // B-5：四路备份互斥入口（手动/批量/定时/覆盖前自动都走这里）：
    // 真身在 backupOneAppSyncLocked，这里只过串行队列，保证同一
    // 时刻只有一个备份在写临时目录。队列只在本函数里用，不存在
    // 重入（backupOneAppSyncLocked 不调自己、不回头调本函数）。
    static func backupOneAppSync(_ app: LCAppModel, backupRoot: URL, fm: FileManager, loginOnly: Bool = false) throws -> (keychainCount: Int, keychainHasSnapshot: Bool, bridgeStatus: String?, loginFileCount: Int, loginBreakdown: [String: Int], loginSkipped: Int, keychainSnapshotDate: Date?, loginSkippedPaths: [String], folderName: String, containerCount: Int, containerNames: [String], loginFailed: Int, loginFailedPaths: [String]) {
        try czfBackupSerialQueue.sync {
            try Self.backupOneAppSyncLocked(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly)
        }
    }

    private static func backupOneAppSyncLocked(_ app: LCAppModel, backupRoot: URL, fm: FileManager, loginOnly: Bool = false) throws -> (keychainCount: Int, keychainHasSnapshot: Bool, bridgeStatus: String?, loginFileCount: Int, loginBreakdown: [String: Int], loginSkipped: Int, keychainSnapshotDate: Date?, loginSkippedPaths: [String], folderName: String, containerCount: Int, containerNames: [String], loginFailed: Int, loginFailedPaths: [String]) {
        let appName = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
        // v216：同款多开各写各的文件夹（见 backupFolderName：
        // 同实例沿用旧名、新实例加实例后缀；老文件夹不改名）。
        // appName 仍是显示名（报告文案用），落盘用 folderName。
        let folderName = Self.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
        // 3.8.281：锁了的备份不覆盖（批量/定时/自动备份三处调用前
        // 已跳过，这里是兜底：直接调本函数也盖不掉锁定的备份）。
        if Self.isBackupLocked(folderName) {
            throw NSError(domain: "LiveContainerBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "备份已锁定"])
        }
        // 防丢：先写到文稿根目录下的临时文件夹（带点前缀，
        // 备份列表扫不到），全部写完最后一步才换名上位。原来是
        // 先删旧备份再重建，写到一半失败/空间满/被系统杀掉，
        // 就是新旧两空——仅密匙备份以后是登录命根子，不能赌。
        // 临时目录与 Backups 同卷，换名是瞬间完成的改名操作
        let finalURL = backupRoot.appendingPathComponent(folderName)
        let appBackupURL = backupRoot.deletingLastPathComponent()
            .appendingPathComponent(".czf-backup-tmp-\(folderName)")
        if fm.fileExists(atPath: appBackupURL.path) {
            try? fm.removeItem(at: appBackupURL)
        }
        try fm.createDirectory(at: appBackupURL, withIntermediateDirectories: true)
        var loginFileCount = 0
        var loginBreakdown: [String: Int] = [:]
        var loginSkipped = 0
        var loginSkippedPaths: [String] = []
        // 13：拷失败清单（完整备份的容器/.app 拷失败 + 登录态
        // 档的 copyLoginStateFiles 失败都记这里，进回执）。
        var loginFailed = 0
        var loginFailedPaths: [String] = []
        // 保存 manifest.json（含 bundleID、版本，用于恢复时自动安装）
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
        // 默认容器的钥匙串组号也记下：删后重装恢复时新建的
        // 兜底容器照这个组号建，写回的条目 agrp 和快照里
        // 原样对齐，不用等桥二次改写
        let defaultContainer = app.uiContainers.first(where: { $0.folderName == (app.appInfo.dataUUID ?? "") }) ?? app.uiContainers.first
        let manifest: [String: String] = [
            "bundleIdentifier": app.appInfo.bundleIdentifier() ?? "",
            "displayName": app.appInfo.displayName() ?? "",
            "version": app.appInfo.version() ?? "",
            "backupDate": dateFmt.string(from: Date()),
            // 恢复时靠它认出哪个是默认容器：容器文件夹名
            // 是随机 UUID，删后重装会换号，不能靠名字猜
            "dataUUID": app.appInfo.dataUUID ?? "",
            "keychainGroupId": defaultContainer.map { String($0.keychainGroupId) } ?? "",
            // 备份范围：login = 登录态档（钥匙串快照 + 会话文件，
            // 没有 .app 本体和整套数据）；full = 整套都备。恢复
            // 列表据此打标；旧备份的 keychain（纯钥匙串）照旧认
            "scope": loginOnly ? "login" : "full",
            // 模块选择：删后恢复时写回，免得手动选的模块夹丢了重选
            "tweakFolder": app.appInfo.tweakFolder ?? ""
        ]
        if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
            try? manifestData.write(to: appBackupURL.appendingPathComponent("manifest.json"))
        }
        // 完整档才整拷 .app 本体、数据容器和组容器（体积大头
        // 全在这里）；登录态档只挑会话文件，见 else 分支
        // v216：成功拷回的数据容器数（登录态档不走完整分支，
        // 保持 0，属设计内不含整容器），声明放分支外，返回时两边都可见
        var containerCount = 0
        // 3.8.281：成功拷回的容器文件夹名（健康行显名用；登录态档
        // 不走完整分支，保持空）。
        var containerNames: [String] = []
        if !loginOnly {
        // 保存 .app bundle 供恢复时参考（iOS 沙盒不允许调用 zip，暂不打包 IPA）
        if let bundlePath = app.appInfo.bundlePath() {
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let destAppURL = appBackupURL.appendingPathComponent(bundleURL.lastPathComponent)
            // 13：.app 拷失败也记失败清单，别静默丢。
            if (try? fm.copyItem(at: bundleURL, to: destAppURL)) == nil {
                loginFailed += 1
                if loginFailedPaths.count < 50 { loginFailedPaths.append(bundleURL.lastPathComponent) }
                // B-4：拷失败的残留 `.app` 删掉，否则下面校验的
                // fileExists 会把半截 `.app` 当成已拷上。
                try? fm.removeItem(at: destAppURL)
            }
        }
        for container in app.uiContainers {
            let srcURL = container.containerURL
            let destURL = appBackupURL.appendingPathComponent(srcURL.lastPathComponent)
            // v216：成功拷回的数据容器数（健康分与预览共用；
            // AppGroup 组容器不计在内）
            if fm.fileExists(atPath: srcURL.path), (try? fm.copyItem(at: srcURL, to: destURL)) != nil {
                containerCount += 1
                containerNames.append(srcURL.lastPathComponent)
            } else if fm.fileExists(atPath: srcURL.path) {
                // 13：容器拷失败记失败清单，别静默丢。
                loginFailed += 1
                if loginFailedPaths.count < 50 { loginFailedPaths.append(srcURL.lastPathComponent) }
                // B-3：copyItem 不是原子的，中途失败（磁盘满/
                // I/O 错）可能在目标留下一个不完整目录；不清掉
                // 的话，下面的容器数校验会数到这个残留目录、误报
                // “容器数对不上”、整个备份被删，而 #13 记下的
                // 具体失败文件随抛错一起丢了。拷失败就把目标目录
                // 删掉，校验只数成功拷完的容器，失败走失败清单
                // （部分成功）。（前提：copyItem 中途失败留残留
                // 目录是 Foundation 已知非原子行为，本机未实测。）
                try? fm.removeItem(at: destURL)
            }
        }
        // 组容器数据（App 与它的扩展/小组件共用的那份）：不在
        // 数据容器里，单独存在宿主 Data/AppGroup/<组ID> 下，
        // 以前从没备份过——恢复后容器回到备份时刻、组数据却
        // 停在当前，两边对不上，App 里信息就错乱（版本更新
        // 后恢复最常见）。隔离组容器的 App 数据在容器内已备，
        // 不重复
        if app.uiContainers.contains(where: { !$0.isolateAppGroup }) {
            let groupRoot = appBackupURL.appendingPathComponent("AppGroup")
            for groupID in Self.appGroupIDs(for: app) {
                let src = LCPath.lcGroupAppGroupPath.appendingPathComponent(groupID)
                if fm.fileExists(atPath: src.path) {
                    try? fm.createDirectory(at: groupRoot, withIntermediateDirectories: true)
                    // 13：组容器拷失败记失败清单，别静默丢。
                    if (try? fm.copyItem(at: src, to: groupRoot.appendingPathComponent(groupID))) == nil {
                        loginFailed += 1
                        if loginFailedPaths.count < 50 { loginFailedPaths.append("AppGroup/\(groupID)") }
                        // B-3/B-4 同款：copyItem 不是原子的，拷失败可能在目标留下一个不完整目录；.app 和数据容器都清残留，这里原来没清，半截组数据会进备份、恢复时再拷回去。
                        try? fm.removeItem(at: groupRoot.appendingPathComponent(groupID))
                    }
                }
            }
        }
        } else {
            // 登录态档：登录关键文件（偏好设置、Documents、
            // SQLite 库、plist、Cookie/WebKit/会话相关）先全拷、
            // 不计预算，其余文件按大小升序、单容器封顶 300MB
            // （见 copyLoginStateFiles）；组容器同规则；钥匙串
            // 快照在下面照旧备
            for container in app.uiContainers {
                let srcURL = container.containerURL
                if fm.fileExists(atPath: srcURL.path) {
                    let destURL = appBackupURL.appendingPathComponent(srcURL.lastPathComponent)
                    let r = Self.copyLoginStateFiles(from: srcURL, to: destURL, fm: fm)
                    loginFileCount += r.count
                    loginSkipped += r.skipped
                    if loginSkippedPaths.count < 50 { loginSkippedPaths.append(contentsOf: r.skippedPaths.prefix(50 - loginSkippedPaths.count)) }
                    // 13：拷失败数与路径也累上来，进回执。
                    loginFailed += r.failed
                    if loginFailedPaths.count < 50 { loginFailedPaths.append(contentsOf: r.failedPaths.prefix(50 - loginFailedPaths.count)) }
                    for (k, v) in r.breakdown { loginBreakdown[k, default: 0] += v }
                }
            }
            if app.uiContainers.contains(where: { !$0.isolateAppGroup }) {
                let groupRoot = appBackupURL.appendingPathComponent("AppGroup")
                for groupID in Self.appGroupIDs(for: app) {
                    let src = LCPath.lcGroupAppGroupPath.appendingPathComponent(groupID)
                    if fm.fileExists(atPath: src.path) {
                        try? fm.createDirectory(at: groupRoot, withIntermediateDirectories: true)
                        let r = Self.copyLoginStateFiles(from: src, to: groupRoot.appendingPathComponent(groupID), fm: fm)
                        loginFileCount += r.count
                        loginSkipped += r.skipped
                        if loginSkippedPaths.count < 50 { loginSkippedPaths.append(contentsOf: r.skippedPaths.prefix(50 - loginSkippedPaths.count)) }
                        // 13：拷失败数与路径也累上来，进回执。
                        loginFailed += r.failed
                        if loginFailedPaths.count < 50 { loginFailedPaths.append(contentsOf: r.failedPaths.prefix(50 - loginFailedPaths.count)) }
                        for (k, v) in r.breakdown { loginBreakdown[k, default: 0] += v }
                    }
                }
            }
        }
        // 钥匙串快照（登录令牌本体）：按容器逐个导出。以前令
        // 牌只活在系统钥匙串里、不进备份——同机删重装能靠残
        // 留找回，换机/重装 LiveContainer 就全丢；且恢复时
        // 三处数据不在同一时刻也是信息错乱的来源之一，备齐
        // 了一起回滚才对齐
        let keychainRoot = appBackupURL.appendingPathComponent("Keychain")
        var keychainCount = 0
        var keychainHasSnapshot = false
        var newestDumpDate: Date? = nil
        // 钥匙串快照改读游客进程内钥匙串桥（CZFKeychainBridge）
        // 写在容器根目录的文件：宿主侧 SecItem 查询在这台机上
        // 恒为空（按组/按别名/整表捞五版实测全是 0 条且无错误
        // 码），游客自己导的才作数。快照文件不存在 = 这个 App
        // 装上钥匙串桥之后还没被打开过
        var bridgeStatus: String? = nil
        for container in app.uiContainers {
            // 桥的状态回执：备份弹窗要带出来定案（桥跑没跑、
            // 组对不对、条目在不在），取第一个有的容器那份
            if bridgeStatus == nil,
               let s = try? String(contentsOf: container.containerURL.appendingPathComponent("CZFKeychainBridgeStatus.txt"), encoding: .utf8) {
                bridgeStatus = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let dumpURL = container.containerURL.appendingPathComponent("CZFKeychainDump.plist")
            guard let data = try? Data(contentsOf: dumpURL),
                  let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { continue }
            // 快照新鲜度：桥每次在游客启动/切后台时重写这
            // 个文件，mtime 就是快照时间；备份弹窗报出来，
            // 登录后没切后台就备份、dump 还是旧值时用户
            // 能一眼看出来（取各容器里最新的）
            if let attrs = try? fm.attributesOfItem(atPath: dumpURL.path),
               let mdate = attrs[.modificationDate] as? Date,
               (newestDumpDate == nil || mdate > newestDumpDate!) {
                newestDumpDate = mdate
            }
            keychainHasSnapshot = true
            if !items.isEmpty {
                try? fm.createDirectory(at: keychainRoot, withIntermediateDirectories: true)
                // 写盘失败也别算成功：原来 try? 吞掉写失败、keychainCount 照加，校验又只核 Keychain 目录在不在（目录刚建好），备份会报“钥匙串 ✅ N 条”但里面根本没有快照文件，恢复时登录令牌悄悄丢了。写失败记失败清单、清掉半截文件。
                let keychainDest = keychainRoot.appendingPathComponent(container.folderName + ".plist")
                if (try? data.write(to: keychainDest)) != nil {
                    keychainCount += items.count
                } else {
                    loginFailed += 1
                    if loginFailedPaths.count < 50 { loginFailedPaths.append("Keychain/\(container.folderName).plist") }
                    try? fm.removeItem(at: keychainDest)
                }
            }
        }
        // 3.8.281：备完校验——换上之前先核临时文件夹，通不过就
        // 删临时文件夹、抛错，旧备份原样保留（不换上、不丢数据）。
        // 只核便宜项，不枚举整棵树（会话文件几万个，枚举会堵死）：
        // manifest 能读 + 范围对得上；完整档核容器数；有钥匙串快照
        // 核 Keychain 目录在。登录态档不核容器数（登录分支也建容器
        // 目录、但 containerCount 保持 0，对不上是设计内的）。
        var verifyFailure: String?
        if let info = Self.manifestInfo(of: appBackupURL) {
            if info.scope != (loginOnly ? "login" : "full") { verifyFailure = "manifest 范围不对" }
        } else {
            verifyFailure = "manifest 读不到"
        }
        if verifyFailure == nil && !loginOnly {
            let diskContainers = (try? fm.contentsOfDirectory(at: appBackupURL, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
                let n = $0.lastPathComponent
                return n != "manifest.json" && !n.hasSuffix(".app") && n != "AppGroup" && n != "Keychain" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.count ?? -1
            if diskContainers != containerCount {
                // B-3：数对不上、且前面有容器拷失败时，点名拷失败
                // 的容器（残留目录清不掉也会落到这里），别只报
                // “数对不上”——用户从报错看不出真正原因。
                if loginFailed > 0 {
                    verifyFailure = "容器拷贝失败 \(loginFailed) 个（\(loginFailedPaths.prefix(3).joined(separator: "、"))）"
                } else {
                    verifyFailure = "容器数对不上（备了 \(containerCount) 个、盘上有 \(diskContainers) 个）"
                }
            }
        }
        if verifyFailure == nil && !loginOnly, let bundlePath = app.appInfo.bundlePath() {
            // B-4：完整档核 `.app` 在不在——`.app` 只是供恢复时
            // 参考（恢复安装走源下载链接/用户自选 IPA，不靠它），
            // 缺了不直接导致恢复失败；但“完整”备份缺 `.app`
            // 名不副实，校验加这一项。文案只陈述事实。
            let appName = URL(fileURLWithPath: bundlePath).lastPathComponent
            if !fm.fileExists(atPath: appBackupURL.appendingPathComponent(appName).path) {
                verifyFailure = ".app 未拷上"
            }
        }
        if verifyFailure == nil && keychainHasSnapshot && !fm.fileExists(atPath: appBackupURL.appendingPathComponent("Keychain").path) {
            verifyFailure = "钥匙串快照缺失"
        }
        if let reason = verifyFailure {
            try? fm.removeItem(at: appBackupURL)
            throw NSError(domain: "LiveContainerBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "备份校验未通过（\(reason)），已保留上次备份"])
        }
        // 全部写完才换上：删掉旧备份、临时文件夹改名到位。
        // 中途任何一步抛错都走不到这里，旧备份原样保留
        if fm.fileExists(atPath: finalURL.path) {
            try fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: appBackupURL, to: finalURL)
        return (keychainCount, keychainHasSnapshot, bridgeStatus, loginFileCount, loginBreakdown, loginSkipped, newestDumpDate, loginSkippedPaths, folderName, containerCount, containerNames, loginFailed, loginFailedPaths)
    }

    /// 覆盖安装前的自动备份入口：把被覆盖 App 的整套数据备
    /// 一份到 Backups/<文件夹名>（与手动备份同一位置、同实
    /// 例新的盖旧的；多开时文件夹名带实例后缀，见
    /// backupFolderName），新版装上有问题时能在数据管理里
    /// 恢复回滚。备份失败不挡安装，静默跳过
    static func autoBackupBeforeOverwrite(_ app: LCAppModel) async {
        // 3.8.374：备份前先刷快照，别读旧 dump（batchBackup 同款缺口）。
        await Self.refreshKeychainSnapshot(for: app)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let root = docs.appendingPathComponent("Backups")
                    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
                    // v216：只在备份成功时同步，且按返回的实际文件
                    // 夹名同步（多开后缀名 ≠ 显示名；原来丢弃结果
                    // 后按显示名同步，同款多开会同步错文件夹）。
                    // 备份失败时不触发同步，外部文件夹里不留半成品。
                    if let one = try? Self.backupOneAppSync(app, backupRoot: root, fm: fm) {
                        Self.syncBackupsToExternalFolder(appNames: [one.folderName], backupRoot: root)
                        // B-2：单 App 里个别文件拷失败不抛错、也算
                        // “成功”，原来只取 folderName、失败数直接
                        // 丢了；自动备份静默跳过不挡安装，记一条
                        // 日志留痕（App 名 + 失败数 + 前 3 条路径）。
                        if one.loginFailed > 0 {
                            let name = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
                            print("[AutoBackup] \(name) 覆盖安装前自动备份有 \(one.loginFailed) 个文件拷贝失败：\(one.loginFailedPaths.prefix(3).joined(separator: "、"))")
                        }
                    }
                }
                continuation.resume()
            }
        }
    }

    /// v216：备份健康分的一行（纯文本报告里“标红”只能用 ❌
    /// 字样——弹窗是 Text，不能着色；红字版在恢复前清单预览
    /// 里看）。完整档看容器 + 钥匙串，登录态档看会话文件 +
    /// 钥匙串（登录态档不含整容器，不列容器项）；失败的 App
    /// 已在失败清单里，不重复进健康节。
    // B-16：健康行加拷贝失败数——原来只认容器数/钥匙串，
    // 完整备份丢一个容器，健康行只显示“容器 ✅ 2 个”
    // （而不是 3 个），没有 ❌ 标记，不数数就发现不了。
    static func backupHealthLine(name: String, loginOnly: Bool, containerCount: Int, keychainCount: Int, keychainHasSnapshot: Bool, loginFileCount: Int, containerNames: [String] = [], loginFailed: Int = 0) -> String {
        var parts: [String] = []
        if loginOnly {
            parts.append(loginFileCount > 0 ? "会话文件 ✅ \(loginFileCount) 个" : "会话文件 ❌ 0 个")
        } else {
            if containerCount > 0 {
                // 3.8.281：容器只报个数看不出这次拷了哪几个（1 个还
                // 是 2 个飘就是因为这个）；名字截前 8 位列出来。
                let names = containerNames.map { String($0.prefix(8)) }.joined(separator: "、")
                parts.append("容器 ✅ \(containerCount) 个（\(names)）")
            } else {
                parts.append("容器 ❌ 缺数据容器")
            }
        }
        if keychainCount > 0 {
            parts.append("钥匙串 ✅ \(keychainCount) 条")
        } else if keychainHasSnapshot {
            parts.append("钥匙串 ⚠️ 快照为空")
        } else {
            parts.append("钥匙串 ❌ 无快照")
        }
        if loginFailed > 0 {
            parts.append("拷贝失败 ❌ \(loginFailed) 个")
        }
        return "\(name)：\(parts.joined(separator: " · "))"
    }

    /// 3.8.374：备份前强制刷新钥匙串快照。快照只在客 App 启动/切后台时由桥重写，
    /// 登录后没切后台就备份、读到的还是启动时的旧 dump，恢复时先删再加把活令牌
    /// 换成旧值，直接掉线（373 实测：21:08 快照是重登前拍的，18 条全是旧令牌）。
    /// 照抄恢复的关窗模式：关掉本次要备的各容器窗口，客 App 切后台触发 CZFKBRun
    /// 重写 dump，轮询 mtime 至多等 5 秒，前进即新鲜，超时按旧值继续（回执已报
    /// 快照时间，用户看得见）。同时解决文件侧滞后（关窗时 App 落盘再拷）。
    static func refreshKeychainSnapshot(for app: LCAppModel) async {
        let fm = FileManager.default
        var before: [URL: Date] = [:]
        for container in app.uiContainers {
            let dumpURL = container.containerURL.appendingPathComponent("CZFKeychainDump.plist")
            if let attrs = try? fm.attributesOfItem(atPath: dumpURL.path),
               let mdate = attrs[.modificationDate] as? Date {
                before[dumpURL] = mdate
            }
        }
        if #available(iOS 16.0, *) {
            for container in app.uiContainers {
                MultitaskDockManager.shared.closeAppWindow(uuid: container.folderName)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var refreshed = false
            for container in app.uiContainers {
                let dumpURL = container.containerURL.appendingPathComponent("CZFKeychainDump.plist")
                if let attrs = try? fm.attributesOfItem(atPath: dumpURL.path),
                   let mdate = attrs[.modificationDate] as? Date {
                    if let old = before[dumpURL] {
                        if mdate > old { refreshed = true }
                    } else {
                        refreshed = true
                    }
                }
            }
            if refreshed { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func backupApps(_ apps: [LCAppModel], loginOnly: Bool = false) async {
        // 6 计时（备份只加计时，不改并行）：串行队列是正确性
        // 要求（3.8.318 注释写死，钥匙串两遍全量并发会把
        // dump 和回执写岔、令牌丢了），提速动不了，只量耗时。
        // 从本函数开始计时，到回执为止，整批总耗时。
        let czfBackupStart = Date()
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // B-15：早退前清备份进度——不然进度文案卡在“正在
            // 备份…”，且 czfDismissIfDirectEntryDone 的 guard
            // 永远拦住、直进页关不掉。几乎不可达（iOS 文稿目录
            // 恒在），记为防御性缺口。
            backupRestoreProgress = nil
            errorInfo = "lc.settings.backupFail".loc
            errorShow = true
            return
        }
        // 3.8.374：备份前先刷快照（见 refreshKeychainSnapshot），别读旧 dump
        for app in apps {
            await Self.refreshKeychainSnapshot(for: app)
        }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        // 初始进度也写清第一个 App 的名字（循环里每 App 都会
        // 刷新，0/N 那个空名只闪一下也别留）
        if let first = apps.first {
            let firstName = first.appInfo.displayName() ?? first.appInfo.bundleIdentifier() ?? "Unknown"
            backupRestoreProgress = "正在备份 \(firstName)（1/\(apps.count)）"
        } else {
            backupRestoreProgress = "正在备份（0/\(apps.count)）…"
        }
        // 拷贝重活整体挪到后台队列：原来这段在打开页面触发定时备份时
        // 能把主线程堵死几分钟（整 App 容器逐个 copyItem，都是 GB 级），
        // 界面点不动也划不动。挪后台后备份照跑，界面不卡；结果回主线程
        // 再更新成功/失败提示。用 GCD+continuation 桥接，不挑并发模式。
        let (count, failure, keychainTotal, snapshotMissing, bridgeStatuses, loginFileTotal, loginBreakdownTotal, loginSkippedTotal, snapshotDates, failedNames, loginSkippedPathsTotal, healthLines, skippedNames, loginFailedTotal, loginFailedPathsTotal): (Int, Error?, Int, Bool, [String], Int, [String: Int], Int, [String], [String], [String], [String], [String], Int, [String]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                do {
                    try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    var count = 0
                    var backedUpFolderNames: [String] = []
                    var failedNames: [String] = []
                    // 3.8.281：跳过未重复备的（锁了的 / 今天已备过登录态的）
                    var skippedNames: [String] = []
                    // v216：每 App 健康行（成功才记，失败的走失败清单）
                    var healthLines: [String] = []
                    var keychainTotal = 0
                    var loginFileTotal = 0
                    var loginBreakdownTotal: [String: Int] = [:]
                    var loginSkippedTotal = 0
                    var loginSkippedPathsTotal: [String] = []
                    // 13：拷失败总数与路径（进回执）。
                    var loginFailedTotal = 0
                    var loginFailedPathsTotal: [String] = []
                    var snapshotMissing = false
                    var bridgeStatuses: [String] = []
                    var snapshotDates: [String] = []
                    let dateFmt = DateFormatter()
                    dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
                    for (index, app) in apps.enumerated() {
                        let name = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
                        // 进度回主线程刷新：备到第几个、当前哪个
                        DispatchQueue.main.async {
                            self.backupRestoreProgress = "正在备份 \(name)（\(index + 1)/\(apps.count)）"
                        }
                        // 单个失败不 abort 整批：原来一个 throw 就停掉后面
                        // 所有 App，还把已备好的 count 清零报 0——“好多都没
                        // 备份上”就是这么来的。单个失败记下来继续备后面的，
                        // 最后在报告里列出失败的。
                        // 3.8.281：跳过不重复备——锁了的（报已锁定）和
                        // 批量登录态今天已备过的（报今日已备过）都不
                        // 重跑；单个明确备份（只选 1 个）不跳过，点了
                        // 就是要重备。跳过的记 skippedNames，报告里单列。
                        let fname = Self.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
                        if Self.isBackupLocked(fname) {
                            skippedNames.append("\(name)（已锁定）")
                            continue
                        }
                        if loginOnly && apps.count > 1 && Self.isLoginBackupCurrentToday(app: app, backupRoot: backupRoot, fm: fm) {
                            skippedNames.append("\(name)（今日已备过）")
                            continue
                        }
                        do {
                            let one = try Self.backupOneAppSync(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly)
                            keychainTotal += one.keychainCount
                            loginFileTotal += one.loginFileCount
                            for (k, v) in one.loginBreakdown { loginBreakdownTotal[k, default: 0] += v }
                            loginSkippedTotal += one.loginSkipped
                            if loginSkippedPathsTotal.count < 10 { loginSkippedPathsTotal.append(contentsOf: one.loginSkippedPaths.prefix(10 - loginSkippedPathsTotal.count)) }
                            // 13：拷失败数与路径累上来，进回执。
                            loginFailedTotal += one.loginFailed
                            if loginFailedPathsTotal.count < 10 { loginFailedPathsTotal.append(contentsOf: one.loginFailedPaths.prefix(10 - loginFailedPathsTotal.count)) }
                            if !one.keychainHasSnapshot {
                                snapshotMissing = true
                            }
                            if let s = one.bridgeStatus {
                                bridgeStatuses.append("\(name)：\(s)")
                            }
                            if one.keychainCount > 0, let d = one.keychainSnapshotDate {
                                snapshotDates.append("\(name)：\(dateFmt.string(from: d))")
                            }
                            count += 1
                            // v216：同步按实际文件夹名（多开后缀名 ≠
                            // 显示名），健康行跟成功数一起回主线程
                            backedUpFolderNames.append(one.folderName)
                            healthLines.append(Self.backupHealthLine(name: name, loginOnly: loginOnly, containerCount: one.containerCount, keychainCount: one.keychainCount, keychainHasSnapshot: one.keychainHasSnapshot, loginFileCount: one.loginFileCount, containerNames: one.containerNames, loginFailed: one.loginFailed))
                        } catch {
                            failedNames.append("\(name)：\(LCUtils.czfFriendlyError(error))")
                        }
                    }
                    DispatchQueue.main.async {
                        self.backupRestoreProgress = "正在同步到备份文件夹…"
                    }
                    // 同步到外部备份文件夹（如已设置 iCloud 文件夹）
                    Self.syncBackupsToExternalFolder(appNames: backedUpFolderNames, backupRoot: backupRoot)
                    // 设置备份跟着一起自动刷新（本地 + 所选备份文件夹）
                    Self.writeCZFSettingsBackupDebounced()
                    continuation.resume(returning: (count, nil, keychainTotal, snapshotMissing, bridgeStatuses, loginFileTotal, loginBreakdownTotal, loginSkippedTotal, snapshotDates, failedNames, loginSkippedPathsTotal, healthLines, skippedNames, loginFailedTotal, loginFailedPathsTotal))
                } catch {
                    continuation.resume(returning: (0, error, 0, false, [], 0, [:], 0, [], [], [], [], [], 0, []))
                }
            }
        }
        backupRestoreProgress = nil
        if let failure {
            // B-7：失败路径也拼用时（原来只有成功回执里有），
            // 定位“备份跑了多久才失败”才有数据。
            errorInfo = LCUtils.czfFriendlyError(failure) + "\n" + Self.czfFormatElapsed(Date().timeIntervalSince(czfBackupStart))
            errorShow = true
        } else if count == 0, !failedNames.isEmpty {
            // 一个都没成：别报“成功 0 个”，直接报失败清单
            errorInfo = "备份失败，一个都没备份上：\n" + failedNames.joined(separator: "\n") + "\n" + Self.czfFormatElapsed(Date().timeIntervalSince(czfBackupStart))
            errorShow = true
        } else {
            // 钥匙串导了几条必须报出来：以前恒为 0 也照报"备份
            // 完成"，用户拿着空备份去恢复才发现没数据。快照是
            // 游客进程内的钥匙串桥在 App 打开时写的；0 条时按
            // 有没有快照分两种说法：没快照 = 装上这版后还没打
            // 开过那个 App；有快照还空 = 桥确认它没存令牌
            successInfo = String(format: "lc.settings.backupComplete".loc, count) + "\n钥匙串令牌共导出 \(keychainTotal) 条"
            if keychainTotal == 0 {
                successInfo += snapshotMissing ? "（还没有密匙快照：先打开一次要备份的 App，再回来备份）" : "（密匙快照是空的）"
            }
            if loginOnly {
                if loginFileTotal > 0 {
                    let dist = loginBreakdownTotal.keys.sorted().map { "\($0) \(loginBreakdownTotal[$0] ?? 0)" }.joined(separator: " · ")
                    successInfo += "\n会话文件共 \(loginFileTotal) 个（\(dist)）"
                } else {
                    // 0 也要明说：以前 0 时整行消失，空备份和
                    // 完整备份在弹窗里长得一样，误导人去恢复
                    successInfo += "\n会话文件共 0 个"
                }
                if loginSkippedTotal > 0 {
                    successInfo += "\n超 300MB 预算跳过 \(loginSkippedTotal) 个文件"
                    // 只列前 10 条相对路径（弹窗塞不下 2985 条）：
                    // 下次看到“登录态没回来”时，先对一下会话文件
                    // 在不在这张跳过清单里，再定是预算问题还是
                    // 钥匙串问题。
                    if !loginSkippedPathsTotal.isEmpty {
                        successInfo += "（前 \(loginSkippedPathsTotal.count) 条：\n" + loginSkippedPathsTotal.joined(separator: "\n") + "）"
                        if loginSkippedTotal > loginSkippedPathsTotal.count {
                            successInfo += "\n另有 \(loginSkippedTotal - loginSkippedPathsTotal.count) 个未列出"
                        }
                    }
                }
            }
            // 13：拷失败清单——以前拷失败直接丢、回执里一个
            // 字没有；现在失败也报数+列路径（前 10 条），
            // 让用户知道这次备份里哪些文件没拷上。
            // B-1：原来这块在 if loginOnly 里面，完整备份的
            // .app/容器/组容器拷失败从来不显示；移出来两边
            // 都报——完整备份列容器/组容器名，登录态档列会
            // 话文件相对路径。
            if loginFailedTotal > 0 {
                successInfo += "\n⚠️ 拷贝失败 \(loginFailedTotal) 个文件"
                if !loginFailedPathsTotal.isEmpty {
                    successInfo += "（前 \(loginFailedPathsTotal.count) 条：\n" + loginFailedPathsTotal.joined(separator: "\n") + "）"
                    if loginFailedTotal > loginFailedPathsTotal.count {
                        successInfo += "\n另有 \(loginFailedTotal - loginFailedPathsTotal.count) 个未列出"
                    }
                }
            }
            if !bridgeStatuses.isEmpty {
                successInfo += "\n—— 桥回执 ——\n" + bridgeStatuses.joined(separator: "\n")
            }
            if !snapshotDates.isEmpty {
                successInfo += "\n—— 钥匙串快照时间 ——\n" + snapshotDates.joined(separator: "\n")
                successInfo += "\n（快照是 App 打开/切后台时由桥写的；若之后登录过，先打开 App 切一次后台再备份）"
            }
            if !failedNames.isEmpty {
                successInfo += "\n—— 以下 App 备份失败（已跳过，继续备了后面的）——\n" + failedNames.joined(separator: "\n")
            }
            if !skippedNames.isEmpty {
                successInfo += "\n—— 以下跳过（未重复备份）——\n" + skippedNames.joined(separator: "\n")
            }
            // v216：备份健康分——每个成功 App 一行，缺哪项标 ❌
            //（弹窗是纯文本，不能着色；红字版在恢复前清单预览里）。
            // 失败的 App 已在上面失败清单里，这里只列成功的。
            if !healthLines.isEmpty {
                successInfo += "\n—— 备份健康（缺项标 ❌）——\n" + healthLines.joined(separator: "\n")
            }
            // 6 计时：整批总耗时（从 backupApps 开始到回执）。
            // B-8：秒数用 Int 截断（59.9 秒显示“59 秒”，不再
            // 四舍五入成“60 秒”）；≥ 60 分钟加小时段（“2 小时
            // 0 分”而不是“120 分 0 秒”）。三处回执共用同一
            // 个格式化函数（见 czfFormatElapsed）。
            successInfo += "\n" + Self.czfFormatElapsed(Date().timeIntervalSince(czfBackupStart))
            successInfo += "\n" + backupRoot.path
            successShow = true
        }
    }

    // B-7/B-8：用时格式化（成功/失败三处回执共用）。
    // 秒数 Int 截断，与分钟分支一致；≥ 60 分钟加小时段。
    private static func czfFormatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 {
            return "用时 \(total) 秒"
        }
        let minutes = total / 60
        let secs = total % 60
        if minutes < 60 {
            return "用时 \(minutes) 分 \(secs) 秒"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "用时 \(hours) 小时 \(mins) 分"
    }


    // 3.8.281：开换机迁移向导（重置状态 + 弹 sheet；主入口在
    // 恢复 sheet 里，备份组那行已撤）。
    func beginMigrationWizard() {
        migrationStep = 0
        migrationSourceExternal = false
        migrationFolders = []
        migrationPreviews = []
        migrationHasSettings = false
        migrationHasSort = false
        migrationHasSchemes = false
        migrationRunning = false
        migrationReport = nil
        showMigrationWizard = true
    }

    // 3.8.283：这个 App 是否已有完整备份（本地或 iCloud 任一是
    // full 就算；登录态备份盖上去会把整套数据弄没，备份弹窗
    // 警告与定时跳过都用它）。iCloud 的 manifest 没下载完时
    // 读不到，不算（下次下完了再认）。
    static func hasExistingFullBackup(for app: LCAppModel, backupRoot: URL, fm: FileManager) -> Bool {
        let folderName = Self.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
        if Self.manifestInfo(of: backupRoot.appendingPathComponent(folderName))?.scope == "full" {
            return true
        }
        if let extRoot = Self.externalBackupFolderURL() {
            let folderURL = extRoot.appendingPathComponent(folderName)
            if Self.isFileDownloaded(folderURL.appendingPathComponent("manifest.json"), underExternal: true),
               Self.manifestInfo(of: folderURL)?.scope == "full" {
                return true
            }
        }
        return false
    }

    // 3.8.283：备份范围弹窗的警告——待备份的 App 里有完整备份
    // 时明说“选登录态会把它替换掉”，免得一点就把整套数据备没了
    // 3.8.404：改 static + 显式传 apps，供独立选页
    // CZFScopeChoiceView 直接读（不再经 pendingBackupApps）。
    static func existingFullBackupWarningText(for apps: [LCAppModel]) -> String {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return "" }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        var names: [String] = []
        for app in apps {
            if Self.hasExistingFullBackup(for: app, backupRoot: backupRoot, fm: fm) {
                names.append(app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown")
            }
        }
        guard !names.isEmpty else { return "" }
        if names.count > 3 {
            return "⚠️ 注意：其中 \(names.count) 个 App 已有完整备份，选“只备份登录态”会把它替换掉，整套数据将被覆盖，只留登录态。\n"
        }
        return "⚠️ 注意：\(names.joined(separator: "、"))已有完整备份，选“只备份登录态”会把它替换掉，整套数据将被覆盖，只留登录态。\n"
    }

    // 3.8.306：备份前先报钥匙串快照状态——快照空/缺/旧时备份
    // 里就没有最新令牌，恢复后登录回不来（红果短剧就是这个坑）。
    // 只读各容器的 CZFKeychainDump.plist（与 backupOneAppSync
    // 同一路），不触发 iCloud 下载、不写任何东西。
    // 3.8.341：范围记忆——用户选了范围就记下来（UserDefaults），
    // 下次弹框把上次那个选项排第一、文案里写清“上次选的是”，
    // 点第一个就是上次的选择；没选过时保持原顺序（登录态在前）。
    // 只记选择、不跳过弹框：恢复“全部数据”是覆盖操作，弹框
    // 是最后一道确认，不能省。
    // 3.8.404：改 static，供独立选页 CZFScopeChoiceView 直接读。
    static var lastBackupLoginOnly: Bool? {
        UserDefaults.standard.object(forKey: "LCBackupLastLoginOnly") as? Bool
    }
    static var lastRestoreLoginOnly: Bool? {
        UserDefaults.standard.object(forKey: "LCRestoreLastLoginOnly") as? Bool
    }
    static func lastBackupScopeHint() -> String {
        guard let last = lastBackupLoginOnly else { return "" }
        return "上次选的是：" + (last ? "只备份登录态" : "完整备份") + "。\n"
    }
    static func lastRestoreScopeHint() -> String {
        guard let last = lastRestoreLoginOnly else { return "" }
        return "上次选的是：" + (last ? "只恢复登录态" : "恢复全部数据") + "。\n"
    }
    private func doBackupScope(loginOnly: Bool) {
        UserDefaults.standard.set(loginOnly, forKey: "LCBackupLastLoginOnly")
        let apps = pendingBackupApps
        // 用户选了范围才关选页（选页一直盖在下面等着，
        // 点取消就回到选页接着挑，不丢已勾的 App）。
        showBackupSelect = false
        showRestoreSelect = false
        // 12：同步置备份进行中（backupApps 里也会置，但 Task 是
        // 异步的；直进收尾的 0.3 秒关页可能抢在 Task 启动前，
        // 误把进行中的备份关掉）。
        if let first = apps.first {
            let firstName = first.appInfo.displayName() ?? first.appInfo.bundleIdentifier() ?? "Unknown"
            backupRestoreProgress = "正在备份 \(firstName)（1/\(apps.count)）"
        } else {
            backupRestoreProgress = "正在备份（0/\(apps.count)）…"
        }
        Task {
            await backupApps(apps, loginOnly: loginOnly)
            // 12：跑完后调收尾——此时结果弹窗正弹着，收尾里
            // 的 guard 会拦住；等用户点掉弹窗，onChange 再调
            // 收尾，关页（见 1193 附近 successShow/errorShow
            // 的 onChange）。
            czfDismissIfDirectEntryDone()
        }
    }
    private func doRestoreScope(loginOnly: Bool) {
        UserDefaults.standard.set(loginOnly, forKey: "LCRestoreLastLoginOnly")
        // 用户选了范围才把上面盖着的几层页一起关掉
        // （恢复页/预览页/多选页，没开的关了也没事），再开始恢复。
        showRestoreSelect = false
        showBackupPreview = false
        showSelectBackups = false
        startPendingRestore(loginOnly: loginOnly)
    }
    // 3.8.404：改 static + 显式传 apps，供独立选页直接读。
    static func keychainSnapshotWarningText(for apps: [LCAppModel]) -> String {
        let fm = FileManager.default
        var lines: [String] = []
        for app in apps {
            let name = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
            var hasDump = false
            var hasItems = false
            var newestDate: Date? = nil
            for container in app.uiContainers {
                let dumpURL = container.containerURL.appendingPathComponent("CZFKeychainDump.plist")
                guard let data = try? Data(contentsOf: dumpURL),
                      let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { continue }
                hasDump = true
                if !items.isEmpty { hasItems = true }
                if let attrs = try? fm.attributesOfItem(atPath: dumpURL.path),
                   let mdate = attrs[.modificationDate] as? Date,
                   (newestDate == nil || mdate > newestDate!) {
                    newestDate = mdate
                }
            }
            if !hasDump {
                lines.append("• \(name)：钥匙串 ❌ 无快照（装桥后没打开过 App，备份里没有令牌）")
            } else if !hasItems {
                lines.append("• \(name)：钥匙串 ⚠️ 快照为空")
            } else if let d = newestDate, Date().timeIntervalSince(d) > 24 * 3600 {
                let fmt = DateFormatter()
                fmt.dateFormat = "MM月d日 HH:mm"
                lines.append("• \(name)：钥匙串 ⚠️ 快照是 \(fmt.string(from: d)) 的（超过 1 天没刷新，登录后先打开 App 切一次后台再备份）")
            }
        }
        guard !lines.isEmpty else { return "" }
        return "⚠️ 钥匙串快照提醒：\n\(lines.joined(separator: "\n"))\n"
    }

    // 3.8.281：备份范围弹窗先报已有备份（日期 + 范围 + 锁定），再选
    // 范围；没旧备份时只显示原来的范围说明。只读本地 manifest，
    // 不触发 iCloud 下载（覆盖写的是本地那份）。
    // 3.8.404：改 static + 显式传 apps，供独立选页直接读。
    static func existingBackupSummaryText(for apps: [LCAppModel]) -> String {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return "" }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        var lines: [String] = []
        for app in apps {
            let folderName = Self.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
            guard let info = Self.manifestInfo(of: backupRoot.appendingPathComponent(folderName)) else { continue }
            let name = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
            let scopeText: String
            switch info.scope {
            case "full": scopeText = "完整备份"
            case "login": scopeText = "登录态"
            case "keychain": scopeText = "仅钥匙串"
            default: scopeText = "未知范围"
            }
            let lockText = Self.isBackupLocked(folderName) ? " · 🔒已锁定（备份时会跳过）" : ""
            lines.append("• \(name)：已有备份 \(info.backupDate) · \(scopeText)\(lockText)")
        }
        if lines.isEmpty { return "" }
        let shown = lines.prefix(3).joined(separator: "\n")
        let more = lines.count > 3 ? "\n等 \(lines.count) 个已有备份" : ""
        return "已有备份：\n\(shown)\(more)\n"
    }

    // 3.8.306：恢复范围弹窗先写清恢复的是谁——原来只问“恢复吗”，
    // 恢复错 App 才发现。只读本地 manifest，不触发 iCloud 下载。
    // 3.8.404：改 static + 显式传参，供独立选页直接读。
    static func restoreTargetText(all: Bool, url: URL?, folders: [URL]) -> String {
        if all {
            return "恢复全部备份。\n"
        }
        if let url = url {
            if let info = Self.manifestInfo(of: url) {
                let name = info.displayName.isEmpty ? url.lastPathComponent : info.displayName
                let scopeText: String
                switch info.scope {
                case "full": scopeText = "完整备份"
                case "login": scopeText = "登录态"
                case "keychain": scopeText = "仅钥匙串"
                default: scopeText = "未知范围"
                }
                return "恢复「\(name)」的备份（\(info.backupDate) · \(scopeText)）。\n"
            }
            return "恢复「\(url.lastPathComponent)」的备份。\n"
        }
        if !folders.isEmpty {
            let names = folders.map { url in
                Self.manifestInfo(of: url)?.displayName ?? url.lastPathComponent
            }.filter { !$0.isEmpty }
            if names.count > 3 {
                return "恢复 \(names.count) 个备份：\(names.prefix(3).joined(separator: "、"))等。\n"
            }
            return "恢复 \(names.count) 个备份：\(names.joined(separator: "、"))。\n"
        }
        return ""
    }

    /// 恢复范围弹窗选完后分发：单个恢复走 pendingRestoreURL，
    /// 一键恢复全部走 pendingRestoreAll（同一个范围套全部），
    /// 多选恢复走 pendingRestoreFolders（只恢复勾中的文件夹，
    /// 选择备份 sheet 的“恢复”按钮喂它）。
    /// 多选恢复（换机向导）直接调 restoreSelectedBackups，
    /// 不走这个分发。
    func startPendingRestore(loginOnly: Bool) {
        // 后台持有：大文件恢复拷盘时切后台/锁屏，系统不会
        // 中途挂起；没它时主线程又被拷盘堵住，挂起不及时
        // 就看门狗杀进程（闪退）。过期回调留空是故意的：
        // 拷盘已挪后台（见三件套），主线程始终响应，过期
        // 只是干净挂起、回前台继续，不杀进程；恢复结束必
        // 调 endBackgroundTask。bgID 是 let，Task 捕获无
        // Sendable 问题。UIApplication 本文件已 import，
        // CZFHostKeepAlive 同款用法。
        let bgID = UIApplication.shared.beginBackgroundTask { }
        if pendingRestoreAll {
            pendingRestoreAll = false
            Task { await restoreAllBackups(loginOnly: loginOnly); UIApplication.shared.endBackgroundTask(bgID) }
        } else if let url = pendingRestoreURL {
            pendingRestoreURL = nil
            Task { await restoreFromBackup(at: url, loginOnly: loginOnly); UIApplication.shared.endBackgroundTask(bgID) }
        } else if !pendingRestoreFolders.isEmpty {
            let folders = pendingRestoreFolders
            pendingRestoreFolders = []
            Task { await restoreSelectedBackups(folders: folders, loginOnly: loginOnly); UIApplication.shared.endBackgroundTask(bgID) }
        } else {
            UIApplication.shared.endBackgroundTask(bgID)
        }
    }

    /// 一键恢复全部：逐个静默恢复、只在最后弹一个总报告（原
    /// 来每个备份弹一次自己的结果窗，十几个备份要点掉十几层）
    func restoreAllBackups(loginOnly: Bool) async {
        let merged = mergedBackupFolders()
        // v216：一键恢复前清空无数据文件夹（逐个恢复时追加，
        // 汇总弹窗里一次全给出来；不清空会把上次残留带进来）
        pendingNoDataFolders = []
        var lines: [String] = []
        for (index, folderURL) in merged.enumerated() {
            backupRestoreProgress = "正在恢复全部备份：\(folderURL.lastPathComponent)（\(index + 1)/\(merged.count)）"
            lines.append(await restoreFromBackup(at: folderURL, presentResult: false, loginOnly: loginOnly))
        }
        // 一键恢复全部：设置只做一次（单个恢复在各自报告里做，
        // 这里逐个调时 presentResult=false 不做，免得重复写）。
        if !loginOnly, let first = merged.first {
            let s = await Self.restoreCZFSettings(for: first)
            if s.found {
                if s.sortRestored {
                    lines.append("设置：已恢复 \(s.imported) 项，App 排序已直接恢复；手势、多任务栏、节点、分组已直接生效（核心在跑时节点自动重连），定时、窗口模式与窗口位置下次打开 App 时生效")
                } else {
                    lines.append("设置：已恢复 \(s.imported) 项；手势、多任务栏、节点、分组已直接生效（核心在跑时节点自动重连），定时、窗口模式与窗口位置下次打开 App 时生效")
                }
            } else {
                lines.append("设置：未找到设置备份（CZFSettingsBackup.json），开关需手动重设或用设置页导入")
            }
        }
        backupRestoreProgress = nil
        // 恢复完成：清 AppInfo 缓存与 dock 残留条目（恢复会改
        // 模型容器/换实例，旧缓存与旧条目会指错 App）。
        if #available(iOS 16.0, *) {
            MultitaskDockManager.refreshAfterAppChanged()
        }
        successInfo = "一键恢复全部完成（共 \(lines.count) 个备份）：\n\n" + lines.joined(separator: "\n")
        successShow = true
    }

    /// 恢复已选：与一键恢复全部同一套聚合（逐个静默恢复、
    /// 最后只弹一个总报告），只是集合是用户勾中的文件夹，
    /// 不是全部；单个文件夹失败不 abort 整批
    /// （restoreFromBackup(presentResult:false) 内已把失败
    // 消化成行摘要，见 v213/v219 容错）
    func restoreSelectedBackups(folders: [URL], loginOnly: Bool) async {
        // v216 同款：一键恢复前清空无数据文件夹（逐个恢复时
        // 追加，汇总弹窗里一次全给出来；不清空会把上次残留
        // 带进来）
        pendingNoDataFolders = []
        var lines: [String] = []
        for (index, folderURL) in folders.enumerated() {
            backupRestoreProgress = "正在恢复已选备份：\(folderURL.lastPathComponent)（\(index + 1)/\(folders.count)）"
            lines.append(await restoreFromBackup(at: folderURL, presentResult: false, loginOnly: loginOnly))
        }
        // 设置只做一次（与一键恢复全部同款：单个恢复在各自
        // 报告里做，这里逐个调时 presentResult=false 不做，
        // 免得重复写；只对第一个已选文件夹做）
        if !loginOnly, let first = folders.first {
            let s = await Self.restoreCZFSettings(for: first)
            if s.found {
                if s.sortRestored {
                    lines.append("设置：已恢复 \(s.imported) 项，App 排序已直接恢复；手势、多任务栏、节点、分组已直接生效（核心在跑时节点自动重连），定时、窗口模式与窗口位置下次打开 App 时生效")
                } else {
                    lines.append("设置：已恢复 \(s.imported) 项；手势、多任务栏、节点、分组已直接生效（核心在跑时节点自动重连），定时、窗口模式与窗口位置下次打开 App 时生效")
                }
            } else {
                lines.append("设置：未找到设置备份（CZFSettingsBackup.json），开关需手动重设或用设置页导入")
            }
        }
        backupRestoreProgress = nil
        // 恢复完成：同款清缓存与 dock 残留（见一键恢复全部）。
        if #available(iOS 16.0, *) {
            MultitaskDockManager.refreshAfterAppChanged()
        }
        // 注意：这里用 folders.count，不照抄一键恢复全部的
        // lines.count——后者把 settings 行也算进去了，设置
        // 恢复成功时会把头数多算 1 个；已选报头只认勾中数
        successInfo = "恢复已选完成（共 \(folders.count) 个备份）：\n\n" + lines.joined(separator: "\n")
        successShow = true
    }

    // 新5（3.8.277）：换机迁移向导——读所选来源里有什么。
    // 文件夹清单走现成的 backupFolders；App 数走现成的
    // previewItems；设置备份读源根目录的 CZFSettingsBackup.json
    //（与 restoreCZFSettings 同款文件；iCloud 占位文件现读会堵
    // 下载，放 detached 读，解析 + 判断仍在这里）。
    private func loadMigrationContents() async {
        let folders = backupFolders(fromExternal: migrationSourceExternal)
        migrationFolders = folders
        var items: [BackupPreviewItem] = []
        for folder in folders {
            items.append(contentsOf: await Self.previewItems(for: folder))
        }
        migrationPreviews = items
        let settingsURL: URL?
        if migrationSourceExternal {
            settingsURL = Self.externalBackupFolderURL()?.appendingPathComponent("CZFSettingsBackup.json")
        } else {
            settingsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("CZFSettingsBackup.json")
        }
        migrationHasSettings = false
        migrationHasSort = false
        migrationHasSchemes = false
        if let url = settingsURL {
            let dict: [String: Any]? = await Task.detached {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }.value
            if let dict {
                migrationHasSettings = true
                migrationHasSort = dict["LCCustomSortOrder"] != nil || dict["LCAppSortType"] != nil
                migrationHasSchemes = dict["LCCustomSortSchemes"] != nil
            }
        }
    }

    // 新5（3.8.277）：向导的一键恢复——复用现成的恢复已选：
    // 逐个静默恢复 App + 设置只做一次 + 进度一条线
    //（backupRestoreProgress）+ 最后汇总报告。报告在本向导
    // 第 4 步显示，父页的 success 弹窗压住（同一次 Task 内
    // 同步关掉，不会闪出来）。
    private func startMigrationRestore() {
        migrationStep = 2
        migrationRunning = true
        let folders = migrationFolders
        Task {
            await restoreSelectedBackups(folders: folders, loginOnly: false)
            successShow = false
            migrationReport = successInfo.isEmpty ? "恢复完成，未返回报告。" : successInfo
            migrationRunning = false
            migrationStep = 3
        }
    }

    // 新5（3.8.277）：换机迁移向导界面。4 步：① 选备份来源
    //（本地/iCloud 文件夹）② 列出里面有什么（App 数量、有没有
    // 设置备份、有没有排序）③ 一键恢复 App + 设置 + 排序，进度
    // 一条线 ④ 最后给汇总报告。恢复逻辑不另写，全走现成的
    // restoreSelectedBackups / restoreCZFSettings / 进度报告。
    @ViewBuilder
    private var migrationWizardView: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("第 \(migrationStep + 1) 步，共 4 步")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if migrationStep == 0 {
                    // 3.8.322 液体化繁为简：选项卡圆角 12→20，
                    // 与面板卡片行统一。
                    Text("选备份来源")
                        .font(.title2).bold()
                    Text("从哪份备份恢复？本地是本机文稿里的 Backups，iCloud 是你选的 iCloud 备份文件夹。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button {
                        migrationSourceExternal = false
                        migrationStep = 1
                        Task { await loadMigrationContents() }
                    } label: {
                        HStack {
                            Text("本地备份")
                            Spacer()
                            Text("\(migrationLocalCount) 个文件夹")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                    Button {
                        migrationSourceExternal = true
                        migrationStep = 1
                        Task { await loadMigrationContents() }
                    } label: {
                        HStack {
                            Text("iCloud 备份文件夹")
                            Spacer()
                            Text(Self.externalBackupFolderURL() == nil ? "未选择" : "\(migrationExternalCount) 个文件夹")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                    .disabled(Self.externalBackupFolderURL() == nil)
                    Spacer()
                } else if migrationStep == 1 {
                    Text("里面有什么")
                        .font(.title2).bold()
                    if migrationFolders.isEmpty {
                        Text("这个来源下没有备份文件夹。")
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("App 备份：\(migrationFolders.count) 个文件夹，共 \(migrationPreviews.count) 个 App")
                            Text(migrationHasSettings ? "设置备份：有" : "设置备份：没有")
                            if migrationHasSettings {
                                Text(migrationHasSort ? "App 排序：有，会一起恢复" : "App 排序：没有")
                                if migrationHasSchemes {
                                    Text("排序方案：有，会一起恢复")
                                }
                            }
                        }
                        .font(.subheadline)
                        List {
                            ForEach(migrationFolders, id: \.self) { folder in
                                Text(folder.lastPathComponent)
                                    .lineLimit(1)
                            }
                        }
                        .listStyle(.plain)
                    }
                    Spacer()
                    HStack {
                        Button("上一步") { migrationStep = 0 }
                        Spacer()
                        Button("一键恢复") { startMigrationRestore() }
                            .disabled(migrationFolders.isEmpty || migrationRunning)
                            .buttonStyle(.borderedProminent)
                    }
                } else if migrationStep == 2 {
                    Text("正在恢复")
                        .font(.title2).bold()
                    if let progress = backupRestoreProgress {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(progress)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        Text("准备恢复…")
                            .foregroundColor(.secondary)
                    }
                    Text("恢复期间请不要关闭 LiveContainer，App 与设置按顺序恢复。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    Text("恢复完成")
                        .font(.title2).bold()
                    ScrollView {
                        Text(migrationReport ?? "恢复完成，未返回报告。")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Button("完成") { showMigrationWizard = false }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .navigationTitle("换机迁移向导")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showMigrationWizard = false }
                        .disabled(migrationRunning)
                }
            }
            .onAppear {
                migrationLocalCount = backupFolders(fromExternal: false).count
                migrationExternalCount = Self.externalBackupFolderURL() != nil ? backupFolders(fromExternal: true).count : 0
            }
        }
    }

    /// 恢复一个备份文件夹。presentResult=true（恢复单个时）照旧
    /// 弹完整报告；false（一键恢复全部逐个调）时不弹窗，返回一行
    /// 摘要给调用方汇总成一个总报告。返回值单个恢复时不用
    @discardableResult
    func restoreFromBackup(at backupURL: URL, presentResult: Bool = true, loginOnly: Bool = false) async -> String {
        let fm = FileManager.default
        if presentResult {
            backupRestoreProgress = "正在恢复 \(backupURL.lastPathComponent)…"
            // v216：单个恢复先清无数据文件夹（结果弹窗按钮点过
            // 也清，双保险，不漏到下一次无关弹窗里）
            pendingNoDataFolders = []
        }
        do {
            // 新结构：backupURL 直接是单个 App 的备份文件夹（如 Backups/GitHub/）
            // 兼容旧结构：如果是时间戳文件夹，里面是多个 App 文件夹
            let folderName = backupURL.lastPathComponent
            let manifestURL = backupURL.appendingPathComponent("manifest.json")
            // iCloud 备份可能只同步了文件夹壳、内容元数据还没到本机：
            // 直接读会读到空文件夹，误报“成功 0 个”。先触发下载，
            // 等 manifest 出现且有非 manifest 子项再读（manifest 是
            // 小 JSON、先到，单凭它跳出会撞上容器还没到的假 0）；
            // 等不到才按空处理。已同步好的文件夹第一次检查就通过，
            // 不多等。注意：无 manifest 的旧结构文件夹等不满这个
            // 条件（15 秒走满才按原流程走，只是多等一次，不影响
            // 结果——现备份必写 manifest，旧结构已是少数）。
            if let extURL = Self.externalBackupFolderURL(),
               backupURL.path.hasPrefix(extURL.path + "/") {
                try? fm.startDownloadingUbiquitousItem(at: backupURL)
                for _ in 0..<15 {
                    if fm.fileExists(atPath: manifestURL.path),
                       let children = try? fm.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil),
                       children.contains(where: { $0.lastPathComponent != "manifest.json" }) { break }
                    backupRestoreProgress = "正在从 iCloud 下载 \(folderName)…"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            let isSingleAppFolder = fm.fileExists(atPath: manifestURL.path)

            let appFolders: [URL]
            if isSingleAppFolder {
                appFolders = [backupURL]
            } else {
                appFolders = try fm.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil)
            }
            // 空文件夹：直接报失败，不再走“成功 / 恢复完成：0 个 App”误导人。
            // iCloud 内容没同步到时上面已等过 15 秒，还空就是真空。
            if appFolders.isEmpty {
                let msg = "这个备份文件夹是空的，没有可恢复的数据（iCloud 内容可能还没同步到本机，稍后再试；或文件夹里确实没有备份）"
                if presentResult {
                    backupRestoreProgress = nil
                    errorInfo = msg
                    errorShow = true
                }
                return "\(folderName)：\(msg)"
            }
            var restoredCount = 0
            var keychainFoundTotal = 0
            var keychainPlistTotal = 0
            var keychainQueuedTotal = 0
            var keychainImportedTotal = 0
            var keychainUnwritableTotal = 0
            // 宿主直写第一个非成功错误码（连同 App 名）：直写
            // 失败码以前算了没展示，下次测试看到“钥匙串没回来”
            // 时能直接点名卡在哪一环（-34018 多为无权访问组）。
            var keychainStatusFirst: (name: String, status: OSStatus)?
            var missing: [(folder: URL, name: String, bundleID: String)] = []
            var noDataApps: [String] = []
            // 兜底配对 / 多候选对不上的 App（见配对兜底注释）：
            // 只记名，不新开 UserDefaults 键
            var ambiguousApps: [String] = []
            var fallbackPairedApps: [String] = []
            // 单个恢复失败不 abort 整批（照抄 v213 备份侧模式）：
            // 原来 restoreOneApp 一 throw，整个 restoreFromBackup
            // 跳到外层 catch，后面所有 App 都没恢复、报告也丢了。
            // 单个失败记下来继续恢复后面的，最后在报告里列出。
            var restoreFailedApps: [String] = []
            // 3.8.286：组容器恢复失败的 App（旧数据已保留，只
            // 是该组没恢复回来；与整 App 失败分开列）
            var groupFailedApps: [String] = []
            // B-6：会话文件合并失败总数与路径（前 10 条，带 App
            // 名前缀；与备份侧 #13 的回执同款写法）。
            var mergeFailedTotal = 0
            var mergeFailedPathsTotal: [String] = []
            // 3.8.294（P0-4）：iCloud 未下完、恢复可能不完整的
            // App（仍算恢复成功计入 restoredCount，单列提示，
            // 不进 noDataApps——数据确实部分恢复了）
            var downloadIncompleteApps: [String] = []
            var versionMismatchApps: [String] = []
            var missingFolders: [URL] = []
            // v216：无数据文件夹（与 noDataApps 文本并行）：结果
            // 弹窗里“在文件 App 里打开”按钮用它定位核对。
            var noDataFolders: [NoDataFolderEntry] = []
            // v216：钥匙串已排队的 App（恢复完逐个提示打开一次，
            // 排队快照在 App 下次全新启动时才由桥写回）。
            var keychainQueuedApps: [String] = []
            let allApps = sharedModel.apps + sharedModel.hiddenApps
            for (index, appFolder) in appFolders.enumerated() {
                let folderName = appFolder.lastPathComponent
                if presentResult {
                    backupRestoreProgress = "正在恢复 \(folderName)（\(index + 1)/\(appFolders.count)）"
                }
                // v216：先按 manifest dataUUID 精确匹配实例——
                // 同款多开的新备份文件夹名带实例后缀（Muse /
                // Muse（xxxxxxxx）），靠文件夹名猜会错位；dataUUID
                // 对上就是同一个实例。对不上时走下面旧逻辑（老备
                // 份不动，显示名/Bundle ID/改名兜底照旧）。
                var app: LCAppModel? = nil
                if let json = await Self.manifestDict(appFolder: appFolder),
                   let du = json["dataUUID"], !du.isEmpty {
                    app = allApps.first(where: { ($0.appInfo.dataUUID ?? "") == du })
                }
                // 再按显示名匹配，再按 Bundle ID 匹配
                // 多开同名不猜首个：同款多开未改名时两个实例显示名
                // 相同，first(where:) 按数组顺序取，顺序一变就串
                // 到另一个实例（间歇串号）。多候选时先按文件夹名
                // 里的实例后缀“（xxxxxxxx）”（dataUUID 前 8 位）
                // 精确认，认不出就不猜、留给后面阶段处理。
                if app == nil {
                    let nameCandidates = allApps.filter {
                        ($0.appInfo.displayName() ?? "") == folderName ||
                        ($0.appInfo.bundleIdentifier() ?? "") == folderName
                    }
                    if nameCandidates.count == 1 {
                        app = nameCandidates[0]
                    } else if nameCandidates.count > 1,
                              let suffix = Self.czfInstanceSuffix(fromFolderName: folderName) {
                        app = nameCandidates.first(where: { ($0.appInfo.dataUUID ?? "").hasPrefix(suffix) })
                            ?? nameCandidates.first(where: { ($0.uiContainers.first?.folderName ?? "").hasPrefix(suffix) })
                    }
                }
                // 改名后旧备份兜底：显示名对不上了，看 manifest 的
                // Bundle ID；同款只装了一个时才能唯一认出，多开装
                // 了两个时不猜（猜错会把数据还给错的那个）。
                if app == nil,
                   let json = await Self.manifestDict(appFolder: appFolder),
                   let bid = json["bundleIdentifier"], !bid.isEmpty {
                    let matches = allApps.filter { ($0.appInfo.bundleIdentifier() ?? "") == bid }
                    if matches.count == 1 {
                        // 显示名一致校验：manifest 记的显示名必须和
                        // 唯一候选的显示名对上，否则可能是同款多开
                        // 的另一个实例（只装 Muse、恢复 Muse5 备份
                        // 时就会误认成 Muse，Muse5 数据盖进 Muse）。
                        // 对不上不猜，走未安装流程（装/手动导入），
                        // 宁可恢复失败也不错位。manifest 没写显示名
                        // 的老备份沿用旧行为（count==1 即认）。
                        let manifestName = json["displayName"] ?? ""
                        let candidateName = matches[0].appInfo.displayName() ?? ""
                        if manifestName.isEmpty || manifestName == candidateName {
                            app = matches[0]
                        }
                    }
                }
                // 兜底配对（严格三段全 miss 时才进，不换严格规则）：
                // 删 Live 重装后全部 manifest dataUUID 都过期，严格
                // 第一段全灭；文件夹名是多开后缀名、显示名改过时
                // 第二段也灭；第三段又被显示名一致校验拦住时，
                // 整个备份就掉进“未安装”流程——App 明明装着，却
                // 要去源里重装，源里没有就报 0。这两段只在唯一
                // 候选时才认，多候选一律不猜（见 ambiguousApps）。
                // 兜底配对成功后走下面同一套 restoreOneApp 全流程
                //（数据 + 钥匙串排队），不只报个数。
                // 4a：按 manifest Bundle ID 兜底（唯一候选才认；
                // 显示名不要求一致——改名/删剩单实例时显示名
                // 对不上是常态；Bundle ID 是 App 身份，不同
                // Bundle ID 的绝不配。已知取舍：同款多开删剩
                // 一个时，这段会把已删实例的备份配给现存同款
                // 实例——要避开就保留两个实例再恢复）。
                var fallbackNote: String? = nil
                var ambiguousNote: String? = nil
                if app == nil,
                   let json = await Self.manifestDict(appFolder: appFolder),
                   let bid = json["bundleIdentifier"], !bid.isEmpty {
                    let matches = allApps.filter { ($0.appInfo.bundleIdentifier() ?? "") == bid }
                    if matches.count == 1 {
                        // 名字对不上不配：多开兄弟的备份不能盖进现存
                        // 实例（间歇串号的主路——只剩 muse 时恢复
                        // muse8 的备份，4a 按 Bundle ID 单候选就配
                        // 给 muse）。与第 3 段同款要求：manifest 有
                        // 显示名时必须与候选一致，否则走下面“未安
                        // 装”流程自动新建该名字的实例再恢复。
                        let manifestName = json["displayName"] ?? ""
                        let candidateName = matches[0].appInfo.displayName() ?? ""
                        if manifestName.isEmpty || manifestName == candidateName {
                            app = matches[0]
                            fallbackNote = "按 Bundle ID 兜底"
                        }
                    } else if matches.count > 1 {
                        ambiguousNote = "同款多开 \(matches.count) 个，无法唯一确定"
                    }
                }
                // 4b：按 manifest 显示名兜底（唯一候选才认；若
                // manifest 有 Bundle ID，候选的 Bundle ID 必须
                // 一致——同名不同 App 绝不配。4a 已判多候选时
                // 跳过本段：同款实例显示名相同，显示名无法
                // 再区分它们，猜了也是错）。
                if app == nil, ambiguousNote == nil,
                   let json = await Self.manifestDict(appFolder: appFolder),
                   let manifestName = json["displayName"], !manifestName.isEmpty {
                    let manifestBid = json["bundleIdentifier"] ?? ""
                    let matches = allApps.filter {
                        ($0.appInfo.displayName() ?? "") == manifestName &&
                        (manifestBid.isEmpty || ($0.appInfo.bundleIdentifier() ?? "") == manifestBid)
                    }
                    if matches.count == 1 {
                        app = matches[0]
                        fallbackNote = "按显示名兜底"
                    } else if matches.count > 1 {
                        ambiguousNote = "同名 \(matches.count) 个，无法唯一确定"
                    }
                }
                // 兜底多候选：App 装着但无法唯一确定，不进
                // “未安装”流程（否则会去源里重装一个重复实例），
                // 也不猜——报告里明说对不上。
                if app == nil, let note = ambiguousNote {
                    ambiguousApps.append("\(folderName)（\(note)）")
                    continue
                }
                guard let app else {
                    // App 未安装：记下它的备份文件夹和身份，后面先装再恢复
                    var appName = folderName
                    var appBundleID = ""
                    if let json = await Self.manifestDict(appFolder: appFolder) {
                        if let displayName = json["displayName"], !displayName.isEmpty {
                            appName = displayName
                        }
                        appBundleID = json["bundleIdentifier"] ?? ""
                    }
                    missing.append((folder: appFolder, name: appName, bundleID: appBundleID))
                    continue
                }
                do {
                    // v216：iCloud 下载进度经闭包回主线程写文案
                    //（只在外部源等待时触发；本地恢复不报进度）。
                    let outcome = try await Self.restoreOneApp(appFolder: appFolder, app: app, loginOnly: loginOnly, downloadProgress: { downloaded, total in
                        DispatchQueue.main.async {
                            self.backupRestoreProgress = "正在从 iCloud 下载：已下 \(downloaded) / 共 \(total) 个…"
                        }
                    })
                    keychainFoundTotal += outcome.keychainFound
                    keychainPlistTotal += outcome.keychainPlistFiles
                    keychainQueuedTotal += outcome.keychainQueued
                    keychainImportedTotal += outcome.keychainImported
                    keychainUnwritableTotal += outcome.keychainUnwritable
                    if keychainStatusFirst == nil && outcome.keychainStatus != errSecSuccess {
                        keychainStatusFirst = (app.appInfo.displayName() ?? folderName, outcome.keychainStatus)
                    }
                    // v216：钥匙串已排队的 App 记下来，报告末尾
                    // 逐个提醒打开一次（排队快照下次全新启动才写回）
                    if outcome.keychainQueued > 0 {
                        keychainQueuedApps.append(app.appInfo.displayName() ?? folderName)
                    }
                    // 3.8.286：组容器失败进报告（旧数据已保留）
                    if !outcome.groupRestoreFailed.isEmpty {
                        groupFailedApps.append("\(app.appInfo.displayName() ?? folderName)（组容器 \(outcome.groupRestoreFailed.joined(separator: "、")) 未恢复，旧数据已保留）")
                    }
                    // B-6：会话文件合并失败进报告（原文件未动，
                    // 可再恢复一次；路径带 App 名前缀，跨 App
                    // 同名路径不混淆）。
                    if outcome.mergedLoginFailed > 0 {
                        mergeFailedTotal += outcome.mergedLoginFailed
                        let mergeDisplayName = app.appInfo.displayName() ?? folderName
                        if mergeFailedPathsTotal.count < 10 {
                            mergeFailedPathsTotal.append(contentsOf: outcome.mergedLoginFailedPaths.prefix(10 - mergeFailedPathsTotal.count).map { "\(mergeDisplayName)/\($0)" })
                        }
                    }
                    // 3.8.294（P0-4）：下载未完成仍算恢复成功（部分
                    // 数据已拷回），单列进报告，不进 noDataApps。
                    if outcome.downloadIncomplete {
                        downloadIncompleteApps.append(app.appInfo.displayName() ?? folderName)
                    }
                    if outcome.ok {
                        restoredCount += 1
                        if await Self.backupVersionDiffers(appFolder: appFolder, app: app) {
                            versionMismatchApps.append(app.appInfo.displayName() ?? folderName)
                        }
                        if let note = fallbackNote {
                            fallbackPairedApps.append("\(app.appInfo.displayName() ?? folderName)（\(note)）")
                        }
                    } else {
                        // 完整恢复时带上备份里容器数：0 个 = 备份里真
                        // 没数据容器（备份侧缺东西）；>0 个 = 有容器
                        // 但都没恢复出数据（空壳/合并 0 个，恢复侧问题）。
                        // 登录态恢复也带数：容器数现已是实数（完整
                        // 备份登录态恢复取合并循环的顶层文件夹数，
                        // 不再是结构 0），会话合并数与钥匙串条数一
                        // 起，0 报告时能直接定位是文件夹空、合并 0
                        // 还是快照空——14:45 弹窗只写裸名，定不了。
                        let displayName = app.appInfo.displayName() ?? folderName
                        if loginOnly {
                            noDataApps.append("\(displayName)（备份里容器 \(outcome.containerFolderCount) 个，会话文件合并 \(outcome.mergedLoginFiles) 个，合并失败 \(outcome.mergedLoginFailed) 个，钥匙串快照 \(outcome.keychainFound) 条）")
                        } else {
                            noDataApps.append("\(displayName)（备份里容器 \(outcome.containerFolderCount) 个）")
                        }
                        // v216：无数据文件夹也记一份，结果弹窗里
                        // “在文件 App 里打开”按钮用它定位核对
                        noDataFolders.append(NoDataFolderEntry(name: displayName, folder: appFolder))
                    }
                } catch {
                    restoreFailedApps.append("\(app.appInfo.displayName() ?? folderName)：\(LCUtils.czfFriendlyError(error))")
                }
            }
            // 未安装的 App：先从源里下载安装，等装好再恢复它的数据。
            // 老逻辑是恢复和安装同时发：恢复当场报 0，安装请求又因为
            // 安装通道同时只接一个、其余被静默丢弃，最后谁也没成。
            // 现在一个个串行：装一个 → 等它出现在列表里 → 恢复 → 下一个
            var installRestoredCount = 0
            var installNotFound: [String] = []
            var installFailed: [String] = []
            // #5：源只拉一次——原来每缺一个 App 就把全部源 JSON
            // 重新拉一遍（N 个缺 App = N × 全源请求），现在先
            // 一次拉全表、后面只查表；没缺 App 时不拉
            let sourceApps = missing.isEmpty ? [] : await fetchAllSourceApps()
            // B-14：缺 App 的安装+等待并行化——原来串行：装一个
            // → 等 5 分钟 → 恢复 → 下一个；3 个都装失败要空等
            // 15 分钟。现在分三步：① 串行把每个缺 App 的下载
            // 地址定下来（源里找或请用户选 IPA，文件选择器不
            // 能并发）；② 把安装请求全发进队列（enqueueInstall
            // 本身串行排队，不会冲掉），各路并行等自己的 App
            // 出现，总等待取最长 5 分钟而不是叠加；③ 装好的
            // 逐个串行恢复（restoreOneApp 涉钥匙串/容器，不并
            // 行）。每路结果先收数组，合并时再碰共享计数。
            var missingPlan: [(folder: URL, name: String, bundleID: String, url: URL)] = []
            for item in missing {
                if presentResult {
                    backupRestoreProgress = "正在安装并恢复 \(item.name)（等安装完成）…"
                }
                // 3.8.299：源里没有待恢复的 App 时，别直接报“未在源中
                // 找到”了事（用户得自己退出恢复、去 App 页导 IPA、装
                // 好再回来恢复——这条路当初就没想通）。当场请用户选它
                // 的 IPA 文件，选好就走下面同一条安装通道、装好就恢复，
                // 整条链不出恢复流程；取消才记未找到。
                if let fromSource = downloadURLForApp(bundleID: item.bundleID, name: item.name, in: sourceApps) {
                    missingPlan.append((item.folder, item.name, item.bundleID, fromSource))
                } else if let picked = await pickIPAForRestore(appName: item.name) {
                    missingPlan.append((item.folder, item.name, item.bundleID, picked))
                } else {
                    installNotFound.append(item.name)
                }
            }
            // 等安装前先快照已装集合（所有路共用同一份快照）：
            // 原来按 Bundle ID 或显示名首匹配，装 Muse5 时列表
            // 里已有的 Muse（同款同 Bundle ID）会先被认成“装好
            // 了”，Muse5 的数据就盖进 Muse。只等新出现（快照里
            // 没有）且显示名对上的那一个；显示名对不上宁可超时
            // 报安装失败，也不错位恢复。
            let czfMissingBeforeApps = Set((sharedModel.apps + sharedModel.hiddenApps).map { ObjectIdentifier($0) })
            struct CZFMissingWaitResult {
                let name: String
                let folder: URL
                let installedApp: LCAppModel?
                let cancelled: Bool
            }
            let czfMissingWaits = await withTaskGroup(of: CZFMissingWaitResult.self) { group in
                for plan in missingPlan {
                    group.addTask {
                        // 还原分身数据自带分身名（3.8.453）：预设名从备份
                        // 文件夹名（分身数据的名字）取，剥掉实例后缀
                        // “（xxxxxxxx）”。文件夹名是每实例的稳定标识，
                        // 用户在备份列表里看到的就是它；之前只用
                        // plan.name（manifest displayName），旧备份的
                        // manifest 还是原名时，预设名等于包内原名、
                        // 输名框照弹，用户还得手输分身名。文件夹名
                        // 为空才回落 plan.name。
                        let czfFolderPreset = Self.czfStripInstanceSuffix(from: plan.folder.lastPathComponent)
                        let czfPresetName = czfFolderPreset.isEmpty ? Self.czfStripInstanceSuffix(from: plan.name) : czfFolderPreset
                        await MainActor.run {
                            NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": plan.url, "forceAsNew": true, "customDisplayName": czfPresetName])
                        }
                        // 装好后 App 会进 sharedModel 的列表；2 秒一查，
                        // 最多等 5 分钟。B-13：循环里判 Task.isCancelled，
                        // 取消就立即退出，不再空转 150 次。
                        var installedApp: LCAppModel?
                        var waitCancelled = false
                        for _ in 0..<150 {
                            if Task.isCancelled { waitCancelled = true; break }
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if Task.isCancelled { waitCancelled = true; break }
                            let currentApps = sharedModel.apps + sharedModel.hiddenApps
                            installedApp = currentApps.first(where: {
                                !czfMissingBeforeApps.contains(ObjectIdentifier($0)) &&
                                ($0.appInfo.displayName() ?? "") == plan.name &&
                                (plan.bundleID.isEmpty || ($0.appInfo.bundleIdentifier() ?? "") == plan.bundleID)
                            })
                            if installedApp != nil { break }
                        }
                        return CZFMissingWaitResult(name: plan.name, folder: plan.folder, installedApp: installedApp, cancelled: waitCancelled)
                    }
                }
                var collected: [CZFMissingWaitResult] = []
                for await r in group { collected.append(r) }
                return collected
            }
            for wait in czfMissingWaits {
                if wait.cancelled {
                    installFailed.append("\(wait.name)（已取消）")
                    continue
                }
                guard let installedApp = wait.installedApp else {
                    installFailed.append(wait.name)
                    continue
                }
                // 再缓 2 秒等安装收尾落稳，然后恢复这个 App 的数据
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    // v216：同主循环（iCloud 进度 + 排队提醒 + 无数据定位）
                    let outcome2 = try await Self.restoreOneApp(appFolder: wait.folder, app: installedApp, loginOnly: loginOnly, downloadProgress: { downloaded, total in
                        DispatchQueue.main.async {
                            self.backupRestoreProgress = "正在从 iCloud 下载：已下 \(downloaded) / 共 \(total) 个…"
                        }
                    })
                    keychainFoundTotal += outcome2.keychainFound
                    keychainQueuedTotal += outcome2.keychainQueued
                    keychainImportedTotal += outcome2.keychainImported
                    keychainUnwritableTotal += outcome2.keychainUnwritable
                    if keychainStatusFirst == nil && outcome2.keychainStatus != errSecSuccess {
                        keychainStatusFirst = (wait.name, outcome2.keychainStatus)
                    }
                    if outcome2.keychainQueued > 0 {
                        keychainQueuedApps.append(wait.name)
                    }
                    // 3.8.286：组容器失败进报告（旧数据已保留）
                    if !outcome2.groupRestoreFailed.isEmpty {
                        groupFailedApps.append("\(wait.name)（组容器 \(outcome2.groupRestoreFailed.joined(separator: "、")) 未恢复，旧数据已保留）")
                    }
                    // B-6：会话文件合并失败进报告（同主循环）。
                    if outcome2.mergedLoginFailed > 0 {
                        mergeFailedTotal += outcome2.mergedLoginFailed
                        if mergeFailedPathsTotal.count < 10 {
                            mergeFailedPathsTotal.append(contentsOf: outcome2.mergedLoginFailedPaths.prefix(10 - mergeFailedPathsTotal.count).map { "\(wait.name)/\($0)" })
                        }
                    }
                    // 3.8.294（P0-4）：下载未完成仍算恢复成功，单列进报告。
                    if outcome2.downloadIncomplete {
                        downloadIncompleteApps.append(wait.name)
                    }
                    if outcome2.ok {
                        installRestoredCount += 1
                        if await Self.backupVersionDiffers(appFolder: wait.folder, app: installedApp) {
                            versionMismatchApps.append(wait.name)
                        }
                    } else {
                        if loginOnly {
                            noDataApps.append(wait.name)
                        } else {
                            noDataApps.append("\(wait.name)（备份里容器 \(outcome2.containerFolderCount) 个）")
                        }
                        noDataFolders.append(NoDataFolderEntry(name: wait.name, folder: wait.folder))
                    }
                } catch {
                    restoreFailedApps.append("\(wait.name)：\(LCUtils.czfFriendlyError(error))")
                }
            }
            var msg = String(format: "lc.settings.restoreComplete".loc, restoredCount + installRestoredCount)
            if keychainFoundTotal > 0 {
                msg += "\n\n钥匙串：备份含 \(keychainFoundTotal) 条，已排队 \(keychainQueuedTotal) 条（打开 App 时由桥写回），宿主直写 \(keychainImportedTotal) 条"
                if keychainUnwritableTotal > 0 {
                    msg += "\n其中 \(keychainUnwritableTotal) 条所属 App 不注入插件（桥不加载），排队文件不会被写回"
                }
                // 直写失败码：以前算了没展示，“钥匙串没回来”时
                // 只能猜卡在哪一环；现在把第一个非成功码连 App
                // 名一起报出来。-34018 多为新签名描述文件没带
                // 共享钥匙串组（签名/描述文件问题，App 代码修不了，
                // 需重签带共享组的描述文件，或走文件会话恢复）。
                if let first = keychainStatusFirst {
                    msg += "\n宿主直写失败码：\(first.status)（\(first.name)，OSStatus）"
                    if first.status == -34018 {
                        msg += "——多为新签名描述文件没带共享钥匙串组，需重签带共享组的描述文件"
                    }
                }
            } else if loginOnly {
                // 登录态恢复却一条钥匙串都没找到：登录态无从
                // 恢复，直接点名（以前这行直接消失，用户只能看
                // 到“恢复完成 0 个”干瞪眼）。常见原因：备份时
                // App 还没打开过、快照根本没生成。再分一层：
                // 快照文件在但读出 0 条 = 快照本身为空（桥跑过，
                // 没收到令牌），或文件还没同步完/已损坏——恢复
                // 侧读不到条目，分不出来；两路做法一样（确认
                // 文件夹已同步 + 打开 App 切后台重备），写在一起。
                if keychainPlistTotal > 0 {
                    msg += "\n\n钥匙串：备份里有快照文件但读出 0 条（快照本身为空，或文件还没同步完；先在文件 App 里确认文件夹已下载，再打开 App 切一次后台重新备份）"
                } else {
                    msg += "\n\n钥匙串：备份里没有钥匙串快照，登录态无从恢复（备份前先打开一次要备份的 App，让桥生成快照）"
                }
            }
            // v216：登录态提醒链——排队快照在 App 下次全新启动
            // 时才由桥写回，不打开就还没恢复登录态；恢复完逐个
            // 点名提醒（纯文本报告，不另开弹窗叠加）。
            if !keychainQueuedApps.isEmpty {
                msg += "\n\n—— 登录态提醒 ——\n以下 App 的钥匙串已排队，请逐个打开一次（排队快照在 App 下次全新启动时才由桥写回，不打开就还没恢复登录态）：\n" + keychainQueuedApps.joined(separator: "\n")
            }
            // 完整恢复才带回全局设置：设置 JSON 跟备份一起刷新
            // （本地文稿根 + 外部备份根），但恢复流程从没读过它，
            // 删后重装开关一个都没回来就是这个缺口。只在单个恢复
            // 时做（一键恢复全部在汇总处做一次，免得每文件夹
            // 重复写）；登录态恢复不碰全局设置（范围弹窗承诺
            // “只写回登录”）。
            if !loginOnly && presentResult {
                let s = await Self.restoreCZFSettings(for: backupURL)
                if s.found {
                    if s.sortRestored {
                        msg += "\n\n设置：已恢复 \(s.imported) 项，App 排序已直接恢复；手势、多任务栏、节点、分组已直接生效（核心在跑时节点自动重连），定时、窗口模式与窗口位置下次打开 App 时生效"
                    } else {
                        msg += "\n\n设置：已恢复 \(s.imported) 项；手势、多任务栏、节点、分组已直接生效（核心在跑时节点自动重连），定时、窗口模式与窗口位置下次打开 App 时生效"
                    }
                } else {
                    msg += "\n\n设置：未找到设置备份（CZFSettingsBackup.json），开关需手动重设或用设置页导入"
                }
            }
            if installRestoredCount > 0 {
                msg += "\n\n其中 \(installRestoredCount) 个是先安装再恢复的"
            }
            if !installNotFound.isEmpty {
                // 3.8.299：源里没有时恢复流程已当场请用户选 IPA，
                // 走到这里是用户取消了选择（不是没提示就跳过）。
                msg += "\n\n未恢复（源里没有，也没选 IPA 文件；再恢复一次、选 IPA 即可装好恢复）：\n" + installNotFound.joined(separator: "\n")
            }
            if !installFailed.isEmpty {
                msg += "\n\n安装失败或超时（可到 App 页看报错后重试）：\n" + installFailed.joined(separator: "\n")
            }
            if !noDataApps.isEmpty {
                msg += "\n\n未能恢复数据的 App（备份里没有可对应的数据容器）：\n" + noDataApps.joined(separator: "\n")
            }
            if !fallbackPairedApps.isEmpty {
                msg += "\n\n兜底配对恢复的 App（严格匹配未命中，按唯一候选配对，走正常恢复全流程）：\n" + fallbackPairedApps.joined(separator: "\n")
            }
            if !ambiguousApps.isEmpty {
                msg += "\n\n无法唯一确定恢复目标的 App（未恢复，也未去重装；请保留对应实例后手动单文件夹恢复）：\n" + ambiguousApps.joined(separator: "\n")
            }
            if !restoreFailedApps.isEmpty {
                msg += "\n\n恢复失败的 App（已跳过，继续恢复了后面的）：\n" + restoreFailedApps.joined(separator: "\n")
            }
            if !groupFailedApps.isEmpty {
                msg += "\n\n组容器恢复失败的 App（旧数据已保留，未丢失）：\n" + groupFailedApps.joined(separator: "\n")
            }
            // B-6：会话文件合并失败单列（与备份侧 #13 的“⚠️ 拷贝
            // 失败”回执同款写法：总数 + 前 10 条路径 + 另有 N 个）。
            // 合并失败不抛错、原文件未动，可再恢复一次。
            if mergeFailedTotal > 0 {
                msg += "\n\n⚠️ 会话文件合并失败 \(mergeFailedTotal) 个（原文件未动，可再恢复一次）"
                if !mergeFailedPathsTotal.isEmpty {
                    msg += "（前 \(mergeFailedPathsTotal.count) 条：\n" + mergeFailedPathsTotal.joined(separator: "\n") + "）"
                    if mergeFailedTotal > mergeFailedPathsTotal.count {
                        msg += "\n另有 \(mergeFailedTotal - mergeFailedPathsTotal.count) 个未列出"
                    }
                }
            }
            if !downloadIncompleteApps.isEmpty {
                msg += "\n\niCloud 未下完，恢复可能不完整的 App（已恢复的部分数据可用；等 iCloud 同步完再恢复一次可补全）：\n" + downloadIncompleteApps.joined(separator: "\n")
            }
            if !versionMismatchApps.isEmpty {
                msg += "\n\n备份版本与当前 App 版本不同的（数据已整套按备份时刻恢复；打开后若仍有个别信息异常，是新版读旧数据的兼容问题）：\n" + versionMismatchApps.joined(separator: "\n")
            }
            // 一个都没恢复成时别再弹“成功”：v214 真机上“成功 /
            // 恢复完成：0 个 App”就是这么误导人的（照抄 v213
            // 备份侧“一个都没成直接报失败清单”的规矩）。正文
            // 里各类失败清单照旧列出，只是换成错误弹窗。
            if presentResult {
                let totalRestored = restoredCount + installRestoredCount
                if totalRestored == 0 && (!restoreFailedApps.isEmpty || !noDataApps.isEmpty || !ambiguousApps.isEmpty || !installFailed.isEmpty || !installNotFound.isEmpty || !groupFailedApps.isEmpty) {
                    errorInfo = msg
                    errorShow = true
                } else {
                    successInfo = msg
                    successShow = true
                }
                // 单个恢复完成：同款清缓存与 dock 残留。只在
                // presentResult 时跑一次；一键/已选逐个调时
                // presentResult=false，不重复跑（批完成时跑）。
                if #available(iOS 16.0, *) {
                    MultitaskDockManager.refreshAfterAppChanged()
                }
            }
            // 汇总用的一行摘要：恢复数 + 各类问题计数
            var line = "\(folderName)：已恢复 \(restoredCount + installRestoredCount) 个"
            var issues: [String] = []
            if !installNotFound.isEmpty { issues.append("未在源中找到 \(installNotFound.count) 个") }
            if !installFailed.isEmpty { issues.append("安装失败 \(installFailed.count) 个") }
            if !noDataApps.isEmpty { issues.append("无可恢复数据 \(noDataApps.count) 个") }
            if !ambiguousApps.isEmpty { issues.append("多候选对不上 \(ambiguousApps.count) 个") }
            if !restoreFailedApps.isEmpty { issues.append("恢复失败 \(restoreFailedApps.count) 个") }
            if !groupFailedApps.isEmpty { issues.append("组容器失败 \(groupFailedApps.count) 个") }
            if mergeFailedTotal > 0 { issues.append("会话合并失败 \(mergeFailedTotal) 个") }
            if !downloadIncompleteApps.isEmpty { issues.append("iCloud 未下完 \(downloadIncompleteApps.count) 个") }
            if !versionMismatchApps.isEmpty { issues.append("版本不同 \(versionMismatchApps.count) 个") }
            if !issues.isEmpty {
                line += "（" + issues.joined(separator: "、") + "）"
            }
            if !fallbackPairedApps.isEmpty {
                line += "（含兜底配对 \(fallbackPairedApps.count) 个）"
            }
            // 一键汇总以前丢钥匙串明细：单文件夹报告里有的数，
            // 汇总行里也要有，否则一键恢复后看不出登录态那路
            // 到底排队了几条、直写了几条。
            if keychainFoundTotal > 0 {
                line += "；钥匙串备份含 \(keychainFoundTotal) 条，已排队 \(keychainQueuedTotal) 条，宿主直写 \(keychainImportedTotal) 条"
                if keychainUnwritableTotal > 0 {
                    line += "，\(keychainUnwritableTotal) 条不注入无法写回"
                }
            }
            // v216：一键汇总也带登录态提醒（逐个打开一次才算写回）
            if !keychainQueuedApps.isEmpty {
                line += "；请逐个打开一次以下 App 完成登录态写回：" + keychainQueuedApps.joined(separator: "、")
            }
            // v216：无数据文件夹交给结果弹窗的“在文件 App 里
            // 打开”按钮（单个恢复先清后记；一键恢复逐个追加，
            // 汇总弹窗里一次全给出来）。
            if presentResult {
                pendingNoDataFolders = noDataFolders
            } else {
                pendingNoDataFolders += noDataFolders
            }
            if presentResult {
                backupRestoreProgress = nil
            }
            return line
        } catch {
            if presentResult {
                backupRestoreProgress = nil
                errorInfo = LCUtils.czfFriendlyError(error)
                errorShow = true
            }
            return "\(backupURL.lastPathComponent)：恢复失败（\(LCUtils.czfFriendlyError(error))）"
        }
    }

    /// 一次单 App 恢复的结果：ok 之外带上钥匙串的实况（备份
    /// 里有几条、写回几条、失败时系统给的错误码），失败提示
    /// 能直接点名卡在哪一环，不再只有一句"没有可恢复的数据"
    struct RestoreOutcome {
        var ok = false
        var keychainFound = 0
        var keychainImported = 0
        var keychainQueued = 0
        var keychainUnwritable = 0
        var keychainStatus: OSStatus = errSecSuccess
        // 备份文件夹里的数据容器文件夹数（manifest/.app/AppGroup/
        // Keychain 之外）：ok=false 时区分“备份里真没容器”和
        // “有容器但都没恢复出数据”（空壳/合并 0 个），下次测试
        // 看到“备份里没有可对应的数据容器”时能直接定位是哪种。
        // 登录态恢复时也是实数：完整备份登录态恢复的容器数取
        // 合并循环的顶层文件夹数（见 loginMergeFolderCount），
        // 不再是结构 0。
        var containerFolderCount = 0
        // 登录态合并进来的会话文件数（容器合并 + 组容器登录
        // 合并 + 完整备份会话合并之和）：登录态恢复报 0 时，
        // 凭它区分“备份里没东西”与“东西在但没合进来”。
        var mergedLoginFiles = 0
        // B-6：登录态合并失败数与路径（与备份侧 #13 对称）：
        // 合并失败不抛错、容器照常记恢复，但失败要进报告，
        // 否则“合并 0 个”分不出是备份里没东西还是东西在但
        // 没合进来；镜像份失败也记在这里。
        var mergedLoginFailed = 0
        var mergedLoginFailedPaths: [String] = []
        // 3.8.286：组容器整替失败的组名（原子替换后旧数据
        // 保留，失败要进报告，不能静默丢掉）。
        var groupRestoreFailed: [String] = []
        // 3.8.294（P0-4）：iCloud 下载未完成——任一段
        // waitForUbiquitousDownload 超时仍有文件未下完时为
        // true；本地文件夹、无文件、全部已下完时为 false。
        // 恢复可能只拷了一部分，报告里单列提示，不静默报成功。
        var downloadIncomplete = false
        // 备份 Keychain 目录里的 plist 文件数（不管条目数）：
        // 0 = 目录缺/空；>0 但 keychainFound=0 = 快照文件在
        // 但读出 0 条（空快照，或文件未同步完/已损坏）。
        var keychainPlistFiles = 0
    }

    /// 把一个 App 备份文件夹里的数据容器恢复到这个 App 名下。
    /// ok = 至少拷回一个容器或写回一条钥匙串。删后重装时容
    /// 器名对不上号，按原文件夹名放回原位并登记，登录态才能
    /// 跟着回来（见内注）。做成静态：安装流程装完新 App 后
    /// 也要调它自动恢复备份。
    /// iCloud 恢复前把数据下到本地：只对外部（iCloud）文件夹下的源生效，
    /// 本地备份直接返回（本地恢复行为不动）。文件夹壳先到、大文件后到时，
    /// 直接拷会拷到占位空壳——钥匙串那处已因此加过单文件等待，
    /// 数据容器和组容器之前没等，是同一类缺口。做法：对文件夹内
    /// 所有文件逐个触发下载，轮询到全部 .current 或超时（默认 120 秒）；
    /// 超时不报错，照常拷（拷到多少算多少，不比现在更差）。
    /// v216：onProgress 已下数/总数回调（非逃逸闭包，调用方
    /// 在主线程写进度文案）。本地文件夹直接返回、不报进度；
    /// 总数为 0 时不报（没东西可等）；提前下完时报 (total, total)。
    /// 3.8.294（P0-4）：返回全部文件是否真正下完——本地文件
    /// 夹、无文件、轮询到全部 .current 为 true，超时仍有未下
    /// 完为 false；调用方记进 outcome，报告里单列提示。
    static func waitForUbiquitousDownload(_ url: URL, fm: FileManager, maxSeconds: Int = 120, onProgress: ((Int, Int) -> Void)? = nil) async -> Bool {
        guard let extURL = Self.externalBackupFolderURL(),
              url.path.hasPrefix(extURL.path + "/") else { return true }
        try? fm.startDownloadingUbiquitousItem(at: url)
        // 整树枚举挪后台：大容器几万文件时逐个 resourceValues
        // 在主线程同样是秒级长堵；逻辑与原来一字不差（上限、
        // 逐个触发下载），只换执行线程。轮询段 v222 起也挪
        // 后台（见下面轮询段注释）——filter 的逐文件
        // resourceValues 在大容器上同样是秒级长堵。
        let files: [URL] = await Task.detached {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .ubiquitousItemDownloadingStatusKey], options: [.skipsHiddenFiles]) else { return [URL]() }
            var out: [URL] = []
            for case let file as URL in enumerator {
                // 上限 20000 → 100000：用户实测一个备份 22832 个文件，
                // 旧上限会漏掉 20000 之后的全部文件（既不触发下载、又
                // 不等它们），恢复直接拷到占位空壳。100000 以上仍截断
                // （极端大备份的残留上限，超时照常拷，不比现在更差）。
                if out.count > 100000 { break }
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                out.append(file)
                try? fm.startDownloadingUbiquitousItem(at: file)
            }
            return out
        }.value
        if files.isEmpty { return true }
        // 只轮询还没下完的：原来每秒全量扫一遍（N 个文件 × 120 秒），
        // 文件一多就是几百万次 resourceValues；下完的移出本轮，越轮越少。
        // 语义跟原来一致：读不到状态按已下完处理（不卡住），状态
        // 为空或未下完继续等，超时照常拷。
        // 轮询段也挪后台（v222）：filter 的逐文件 resourceValues
        // 在主线程是秒级长堵（大容器 × 120 秒）；sleep 本身不占
        // 线程，但跟 filter 同段、一起挪，调用方线程只剩一次
        // detached 跳转。filter 用 URL.resourceValues，不碰
        // FileManager，故 detached 只捕获 files（纯 URL）与进度
        // 值；onProgress 必须回主线程发——调用方在主线程写文案
        // （见 v216 注释），detached 内直接调会跑到后台线程。
        // 本 target 是 Swift 5 mode（project.pbxproj，app target
        // LiveContainerSwiftUI 的 SWIFT_VERSION = 5.0），捕获
        // onProgress 闭包可编译；CI 为最终 verdict。
        return await Task.detached {
            var remaining = files
            if !files.isEmpty { await MainActor.run { onProgress?(0, files.count) } }
            for _ in 0..<maxSeconds {
                remaining = remaining.filter { file in
                    guard let status = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus else { return false }
                    return status != .current
                }
                if !files.isEmpty {
                    let done = files.count - remaining.count
                    await MainActor.run { onProgress?(done, files.count) }
                }
                if remaining.isEmpty { return true }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return false
        }.value
    }

    /// 恢复拷盘三件套（只挪纯 FileManager 活，不动模型/@State）：
    /// 整容器 copyItem（GB 级）在调用方线程同步跑是恢复闪退
    /// 的根因——恢复经 Task{} 从 UI 发起、继承 MainActor，
    /// 主线程被堵几分钟，切后台/锁屏时挂起不及时就看门狗
    /// 杀进程（看着就是闪退，不是卡住）。备份侧 v216 已把
    /// 同样问题挪到后台队列（见 backupApps 注释），恢复侧
    /// 从没挪过。copyItem 本身是内核拷，不整文件进内存，
    /// 所以不用改流式；要改的是线程 + 后台持有（见
    /// startPendingRestore）。FileManager.default 在 detached
    /// 内取，不从外层捕获，避免 Sendable 问题。
    static func replaceContainerOffMain(from src: URL, to dest: URL) async throws {
        // 先拷到临时目录再原子替换：原来先删 dest 再拷，拷失败
        // （磁盘满、iCloud 占位未下完）直接 throw，原数据已丢；
        // restoreOneApp 是 throws，抛错后整个函数提前退出，已
        // 替换的前几个回不去、后几个没恢复、结尾清理和关窗口
        // 都没跑。现：拷失败时 dest 原样不动；替换用
        // replaceItemAt（失败时原位文件保留），成功后清 tmp。
        // tmp 与 dest 同目录（同卷，rename 才成立）。
        try await Task.detached {
            let fm = FileManager.default
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(".restore-tmp-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: src, to: tmp)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
            do {
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: dest)
                }
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
        }.value
    }

    static func copyGroupOffMain(from src: URL, to dest: URL) async -> Bool {
        // 3.8.286（P0-3）：组容器恢复改原子替换——原来先删 dest
        // 再拷，拷失败（磁盘满、iCloud 占位未下完）旧数据已丢，
        // 且失败静默不记。照上面 replaceContainerOffMain 同款：
        // 先拷临时目录（与 dest 同目录、同卷），再 replaceItemAt
        // 换上；哪步失败都清 tmp、dest 原样不动，返回 false 记
        // 进报告。dest 不存在时直接 moveItem。
        await Task.detached {
            let fm = FileManager.default
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(".restore-tmp-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: src, to: tmp)
            } catch {
                try? fm.removeItem(at: tmp)
                return false
            }
            do {
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: dest)
                }
            } catch {
                try? fm.removeItem(at: tmp)
                return false
            }
            return true
        }.value
    }

    static func mergeLoginStateOffMain(from src: URL, to dest: URL, mirrorGroupToHost: URL? = nil) async -> (merged: Int, failed: Int, failedPaths: [String]) {
        await Task.detached {
            Self.mergeLoginStateFiles(from: src, to: dest, fm: FileManager.default, mirrorGroupToHost: mirrorGroupToHost)
        }.value
    }

    /// 恢复路径上的 iCloud 源字节读（v223，慢网看门狗口子）：
    /// 恢复链跑在主线程（Task{} 从 UI 发起继承 MainActor，见
    /// 三件套注释），而 Data(contentsOf:) 在占位文件上会触发
    /// 下载并同步堵到下完为止——慢网下主线程被堵久了，系统
    /// 看门狗杀进程，看着就是卡住然后闪退。门只验元数据
    /// （fileExists + 列目录，不读字节），wait 只覆盖容器/
    /// 组文件夹，不覆盖 manifest、Keychain、设置 JSON；这三
    /// 处原来全在主线程现读。修法沿三件套/钥匙串导入同款：
    /// 纯 Data + 解析放 Task.detached（只传 URL、只回纯值，
    /// 不碰模型/@State），调用方线程只用结果。Swift 5 mode，
    /// [[String: Any]] 捕获可编译（importKeychainItems 同款
    /// 前例）；CI 为最终 verdict。
    static func manifestDict(appFolder: URL) async -> [String: String]? {
        await Task.detached {
            guard let data = try? Data(contentsOf: appFolder.appendingPathComponent("manifest.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
            return json
        }.value
    }

    static func readKeychainPlist(file: URL) async -> (data: Data, items: [[String: Any]])? {
        await Task.detached {
            guard let data = try? Data(contentsOf: file),
                  let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return nil }
            return (data, items)
        }.value
    }

    /// v216：downloadProgress 原样透传给三处 iCloud 等待
    /// （容器、组容器、登录态合并），调用方在主线程写文案。
    static func restoreOneApp(appFolder: URL, app: LCAppModel, loginOnly: Bool = false, downloadProgress: ((Int, Int) -> Void)? = nil) async throws -> RestoreOutcome {
        let fm = FileManager.default
        // 登录态备份的容器里只有半套会话文件，恢复走合并（见
        // 循环内分支）；完整备份整套替换；只恢复登录态时完整
        // 备份的容器不进循环，会话文件在下面单独合并
        // manifest 只读一次（detached，见 helpers 注释）：
        // 原来 backupScope 与下面各读一次，全在主线程；
        // scope/默认容器/组号/模块夹全从这次结果取。
        let manifestJSON = await Self.manifestDict(appFolder: appFolder)
        let isLoginBackup = manifestJSON?["scope"] == "login"
        // 备份里的容器文件夹（跳过 manifest、.app 本体，
        // 以及组容器和钥匙串两个附属目录——它们在下面单独恢复）
        var containerFolders: [URL] = []
        if !loginOnly || isLoginBackup {
            containerFolders = try fm.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != "manifest.json" && !$0.lastPathComponent.hasSuffix(".app") && $0.lastPathComponent != "AppGroup" && $0.lastPathComponent != "Keychain" }
        }
        // manifest 记着备份时的默认容器名，多个容器时靠它定默认；
        // 组号记着备份时的钥匙串组，恢复补容器时照它建
        var manifestDataUUID = ""
        var manifestKeychainGroupId: Int? = nil
        var manifestTweakFolder = ""
        if let json = manifestJSON {
            manifestDataUUID = json["dataUUID"] ?? ""
            if let g = json["keychainGroupId"], let gv = Int(g) {
                manifestKeychainGroupId = gv
            }
            manifestTweakFolder = json["tweakFolder"] ?? ""
        }
        var restoredContainers = 0
        // 3.8.294（P0-4）：本次恢复里任一段 iCloud 下载超时
        // 未下完即 true，结尾写进 outcome.downloadIncomplete。
        var downloadIncomplete = false
        // 登录态合并计数（三种合并之和，见各合并点）与完整
        // 备份登录态恢复的顶层文件夹数（容器数修正用，见
        // outcome 赋值处）：只记数，不改合并语义。
        var mergedLoginFiles = 0
        // B-6：登录态合并失败数与路径（三种合并之和，与
        // mergedLoginFiles 同款累计；路径前 50 条）。
        var mergedLoginFailed = 0
        var mergedLoginFailedPaths: [String] = []
        var loginMergeFolderCount = 0
        var newDefaultContainer: LCContainer?
        // 本次恢复动过的容器文件夹名（原地覆盖/登录合并/新恢复
        // 全算）：结尾关窗口用，不只关 dataUUID——非默认容器
        // 的窗口若在跑，恢复后它继续用内存旧数据跑。
        var restoredFolderNames = Set<String>()
        // 3.8.294（P0-5）：恢复前先关窗——恢复进行中 App 还在
        // 跑时，它会继续写数据容器，写完就被本函数的覆盖/合并
        // 盖掉（或关窗时丢掉）。结尾已有恢复后关窗，但那是事后
        // 补救，恢复进行中的几分钟写入已丢。开始拷数据前就把本
        // 次要恢复的容器对应的窗口关掉。文件夹名就是窗口 uuid
        // （结尾关窗直接拿 restoredFolderNames 当 uuid 关）；
        // AppGroup/钥匙串没有窗口 uuid（组容器是共享的，钥匙串
        // 排队进全部容器），但它们随容器恢复一起写回，关容器窗
        // 口即关掉会写它们的进程。只关本次备份里的容器，不动别
        // 的 App、也不动本 App 不在备份里的容器；没在跑就是空操
        // 作（closeAppWindow 内部按 uuid 查不到即返回）。候选集
        // 是备份里的文件夹名（不是结尾的 restoredFolderNames）：
        // 精确动过的集合要等各循环跑完才知道，开始前只能按候选
        // 集关，个别被跳过（登录空壳）的窗口多关一次无害、重开
        // 即可。过滤条件与下面 containerFolders 同款；loginOnly
        // 全量合并时 containerFolders 为空，这里仍按备份文件夹名
        // 关，覆盖合并路径。MultitaskDockManager 是 iOS 16+ 类，
        // 必须用 #available 包住（2026-10-25 构建 #186 红字教训）。
        if #available(iOS 16.0, *) {
            let backupContainerNames: [String] = ((try? fm.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil)) ?? []).map { $0.lastPathComponent }.filter { $0 != "manifest.json" && !$0.hasSuffix(".app") && $0 != "AppGroup" && $0 != "Keychain" }
            for name in backupContainerNames {
                MultitaskDockManager.shared.closeAppWindow(uuid: name)
            }
        }
        for containerFolder in containerFolders {
            let folderName = containerFolder.lastPathComponent
            // iCloud 源先等数据下完再拷/合并，否则拷到占位空壳
            let containerDownloaded = await Self.waitForUbiquitousDownload(containerFolder, fm: fm, onProgress: downloadProgress)
            if !containerDownloaded { downloadIncomplete = true }
            if let live = app.uiContainers.first(where: { $0.containerURL.lastPathComponent == folderName }) {
                if isLoginBackup {
                    // 登录态备份只有半套会话文件：合并进现有
                    // 容器（同名文件覆盖、其他数据不动），整
                    // 容器替换会把没备的那半套数据删掉。
                    // 合并拷盘挪后台（见三件套注释）：逐文件
                    // copyItem 累计也是主线程长堵。
                    let mergeDest = live.containerURL
                    let mergeMirror: URL? = live.isolateAppGroup ? nil : LCPath.lcGroupAppGroupPath
                    let mergeResult = await Self.mergeLoginStateOffMain(from: containerFolder, to: mergeDest, mirrorGroupToHost: mergeMirror)
                    mergedLoginFiles += mergeResult.merged
                    // B-6：合并失败累上来，进 outcome 与报告。
                    mergedLoginFailed += mergeResult.failed
                    if mergedLoginFailedPaths.count < 50 { mergedLoginFailedPaths.append(contentsOf: mergeResult.failedPaths.prefix(50 - mergedLoginFailedPaths.count)) }
                    if mergeResult.merged > 0 {
                        restoredContainers += 1
                        restoredFolderNames.insert(folderName)
                    }
                    continue
                }
                // 同名容器还在（没删过 App）：原地覆盖。
                // 拷盘挪后台（见三件套注释）；替换是原子的
                // （见 replaceContainerOffMain），失败原数据保留、
                // 照常 throw。
                try await Self.replaceContainerOffMain(from: containerFolder, to: live.containerURL)
                restoredContainers += 1
                restoredFolderNames.insert(folderName)
                continue
            }
            // 删后重装：新容器的文件夹名是新随机 UUID，和备份里的
            // 旧名对不上——按原文件夹名把整个容器放回原位并登记：
            // 容器里的 LCContainerInfo.plist 记着钥匙串组号，文件
            // 和钥匙串指向一起回来，登录态才能跟着恢复
            if isLoginBackup {
                // 登录态备份的空壳（只剩身份文件、没有会话文件）
                // 不登记成容器：否则安装后误报「已恢复备份记录」，
                // 登录其实没回来；钥匙串部分走下面兜底建容器那套。
                // 整树枚举也挪后台：大容器几万文件时 resourceValues
                // 逐个取在主线程同样是秒级长堵。
                let realFiles = await Task.detached { Self.loginStateEntries(in: containerFolder, fm: FileManager.default) }.value.map { $0.rel }.filter { $0 != "LCContainerInfo.plist" }
                if realFiles.isEmpty {
                    continue
                }
            }
            let root = app.appInfo.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath
            let destURL = root.appendingPathComponent(folderName)
            // 拷盘挪后台（见三件套注释）；替换是原子的，失败原
            // 数据保留（见 replaceContainerOffMain）。
            try await Self.replaceContainerOffMain(from: containerFolder, to: destURL)
            let restoredName = (NSDictionary(contentsOf: destURL.appendingPathComponent("LCContainerInfo.plist")) as? [String: Any])?["name"] as? String ?? folderName
            let restored = LCContainer(infoDict: ["folderName": folderName, "name": restoredName], isShared: app.appInfo.isShared)
            var containers = app.uiContainers
            containers.append(restored)
            app.uiContainers = containers
            app.appInfo.containers = containers
            restoredContainers += 1
            restoredFolderNames.insert(folderName)
            if newDefaultContainer == nil || folderName == manifestDataUUID {
                newDefaultContainer = restored
            }
        }
        if let newDefaultContainer {
            // 恢复出来的容器设为默认选中，App 下次打开就用它。
            // 但必须以 manifest 默认容器为准：manifest 默认容器
            // 若已在机上（走原地覆盖分支、没进 newDefaultContainer），
            // 首个新容器不得占位，否则下次打开进的是备份里的非
            // 默认容器、毫无提示；只有 manifest 默认容器不在机上
            // 时，才用首个新容器作默认（原有回落）。
            let finalDefault = app.uiContainers.first { $0.folderName == manifestDataUUID } ?? newDefaultContainer
            app.uiSelectedContainer = finalDefault
            app.uiDefaultDataFolder = finalDefault.folderName
            app.appInfo.dataUUID = finalDefault.folderName
        }
        // 恢复模块选择：manifest 记着备份时的模块夹，写回；
        // 老备份没有这字段就不动（保持新装默认）
        if !manifestTweakFolder.isEmpty {
            app.appInfo.tweakFolder = manifestTweakFolder
        }
        var restoredExtras = false
        // 3.8.286：组容器恢复失败的组名（P0-3 原子替换后失败
        // 仍要进报告；outcome 在下面才建，先记局部变量）
        var failedGroupNames: [String] = []
        // 组容器数据写回：和容器、钥匙串是同一时刻的快照，
        // 三处一起回滚，App 读到的才是一套对齐的数据
        let appGroupBackup = appFolder.appendingPathComponent("AppGroup")
        if !loginOnly || isLoginBackup, let groupFolders = try? fm.contentsOfDirectory(at: appGroupBackup, includingPropertiesForKeys: nil) {
            for groupFolder in groupFolders {
                let dest = LCPath.lcGroupAppGroupPath.appendingPathComponent(groupFolder.lastPathComponent)
                // iCloud 源先等数据下完再拷/合并，否则拷到占位空壳
                let groupDownloaded = await Self.waitForUbiquitousDownload(groupFolder, fm: fm, onProgress: downloadProgress)
                if !groupDownloaded { downloadIncomplete = true }
                if isLoginBackup && fm.fileExists(atPath: dest.path) {
                    // 登录态档的组容器同样是半套：合并，不整替。
                    // 合并拷盘挪后台（见三件套注释）。
                    let mergeResult = await Self.mergeLoginStateOffMain(from: groupFolder, to: dest)
                    mergedLoginFiles += mergeResult.merged
                    // B-6：合并失败累上来，进 outcome 与报告。
                    mergedLoginFailed += mergeResult.failed
                    if mergedLoginFailedPaths.count < 50 { mergedLoginFailedPaths.append(contentsOf: mergeResult.failedPaths.prefix(50 - mergedLoginFailedPaths.count)) }
                    if mergeResult.merged > 0 {
                        restoredExtras = true
                    }
                    continue
                }
                // 组容器整替拷盘挪后台（见三件套注释）：原子替换
                // （先拷临时目录再 replaceItemAt，失败旧数据不动），
                // 失败的组名进报告（不再静默丢掉）。
                if await Self.copyGroupOffMain(from: groupFolder, to: dest) {
                    restoredExtras = true
                } else {
                    failedGroupNames.append(groupFolder.lastPathComponent)
                }
            }
        }
        // 完整备份 + 只恢复登录态：整套容器不动，只把备份容器
        // 里的会话文件合并进现有容器（钥匙串在下面照常写回）。
        // 刚装完没打开过的 App 一个容器都没有：原来合并循环
        // 的 target 守卫会全部跳过，会话文件明明在备份里却
        // 一个都合并不进来，直接报 0（原来指望钥匙串段“补一
        // 个默认容器”，但快照 absent 时那段根本不建——
        // 14:45 Mithka 登录态恢复 0 个就是这条路）。照钥匙
        // 串段同款先补一个默认容器，合并才有落点；文件夹一
        // 个都没有时不补。补的容器就是 App 的合法默认容器
        // （首启也会建一个），钥匙串段随后复用它，不重复建。
        if loginOnly && !isLoginBackup {
            let topFolders = (try? fm.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil)) ?? []
            loginMergeFolderCount = topFolders.filter { let n = $0.lastPathComponent; return n != "manifest.json" && !n.hasSuffix(".app") && n != "AppGroup" && n != "Keychain" }.count
            if app.uiContainers.isEmpty, loginMergeFolderCount > 0 {
                let newName = manifestDataUUID.isEmpty ? NSUUID().uuidString : manifestDataUUID
                let newContainer = LCContainer(folderName: newName, name: newName, isShared: app.appInfo.isShared)
                var containers = app.uiContainers
                containers.append(newContainer)
                app.uiContainers = containers
                app.appInfo.containers = containers
                app.uiSelectedContainer = newContainer
                app.uiDefaultDataFolder = newName
                app.appInfo.dataUUID = newName
                if let bundleID = app.appInfo.bundleIdentifier() {
                    newContainer.makeLCContainerInfoPlist(appIdentifier: bundleID, keychainGroupId: manifestKeychainGroupId ?? Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
                }
            }
            for folder in topFolders {
                let n = folder.lastPathComponent
                if n == "manifest.json" || n.hasSuffix(".app") || n == "AppGroup" || n == "Keychain" { continue }
                // iCloud 源先等数据下完再合并，否则拷到占位空壳
                let mergeDownloaded = await Self.waitForUbiquitousDownload(folder, fm: fm, onProgress: downloadProgress)
                if !mergeDownloaded { downloadIncomplete = true }
                // 找目标容器：按名对上的才合并；对不上的按备份文件夹新建
                // 一个容器（完整恢复分支同款注册），再把会话文件合进它。
                // 原来回落到选中容器/首个容器，多容器重装后各容器会话全
                // 并进同一个容器，跨容器数据混杂。是 manifest 默认容器时
                // 同时设为选中（完整恢复同款），否则只是多一个可切换容器。
                let target: LCContainer
                if let matched = app.uiContainers.first(where: { $0.containerURL.lastPathComponent == n }) {
                    target = matched
                } else {
                    let newContainer = LCContainer(folderName: n, name: n, isShared: app.appInfo.isShared)
                    var containers = app.uiContainers
                    containers.append(newContainer)
                    app.uiContainers = containers
                    app.appInfo.containers = containers
                    if n == manifestDataUUID {
                        app.uiSelectedContainer = newContainer
                        app.uiDefaultDataFolder = n
                        app.appInfo.dataUUID = n
                    }
                    target = newContainer
                }
                // 合并拷盘挪后台（见三件套注释）：目标值先在
                // 调用方线程取出，只把纯 URL 传进 detached。
                let mergeDest = target.containerURL
                let mergeMirror: URL? = target.isolateAppGroup ? nil : LCPath.lcGroupAppGroupPath
                let mergeResult = await Self.mergeLoginStateOffMain(from: folder, to: mergeDest, mirrorGroupToHost: mergeMirror)
                mergedLoginFiles += mergeResult.merged
                // B-6：合并失败累上来，进 outcome 与报告。
                mergedLoginFailed += mergeResult.failed
                if mergedLoginFailedPaths.count < 50 { mergedLoginFailedPaths.append(contentsOf: mergeResult.failedPaths.prefix(50 - mergedLoginFailedPaths.count)) }
                if mergeResult.merged > 0 {
                    restoredExtras = true
                    restoredFolderNames.insert(target.containerURL.lastPathComponent)
                }
            }
        }
        // 钥匙串写回：备份里哪个容器的快照，就写进这次恢复后
        // 同名容器的组里（组号取目标容器自己的，删后重装时
        // 与备份一致；同名覆盖时按现有容器走，不串号）
        var outcome = RestoreOutcome()
        // 完整备份登录态恢复时 containerFolders 本来就是空
        // （结构 0），容器数取合并循环的顶层文件夹数才是实数；
        // 其余两路 loginMergeFolderCount=0，结果不变。
        outcome.containerFolderCount = containerFolders.count + loginMergeFolderCount
        outcome.mergedLoginFiles = mergedLoginFiles
        // B-6：合并失败数与路径进 outcome，供报告单列。
        outcome.mergedLoginFailed = mergedLoginFailed
        outcome.mergedLoginFailedPaths = mergedLoginFailedPaths
        outcome.groupRestoreFailed = failedGroupNames
        outcome.downloadIncomplete = downloadIncomplete
        let keychainBackup = appFolder.appendingPathComponent("Keychain")
        if let files = try? fm.contentsOfDirectory(at: keychainBackup, includingPropertiesForKeys: nil) {
            let plistFiles = files.filter { $0.pathExtension == "plist" }
            outcome.keychainPlistFiles = plistFiles.count
            for file in plistFiles {
                if let plist = await Self.readKeychainPlist(file: file) {
                    outcome.keychainFound += plist.items.count
                }
            }
            // 没容器可落先补一个：刚装完还没打开过的 App 一个
            // 容器都没有（列表里标"数据文件夹未创建"），仅密匙
            // 备份又没有容器文件夹可借道恢复，钥匙串整份落空
            // （真机实测：装完自动恢复报"没有可恢复的数据"、
            // 手动恢复报 0 个）。照 runApp 首启的建法补一个默认
            // 容器，登录态才有着落
            if app.uiContainers.isEmpty && !plistFiles.isEmpty {
                // 容器名直接用备份时的原名（manifest 的
                // dataUUID）：快照文件名、别名都按原名记账，
                // 同名对上目标容器是第一优先落点，不用再靠
                // 默认容器兜底猜；组号同样照备份时的建
                let newName = manifestDataUUID.isEmpty ? NSUUID().uuidString : manifestDataUUID
                let newContainer = LCContainer(folderName: newName, name: newName, isShared: app.appInfo.isShared)
                var containers = app.uiContainers
                containers.append(newContainer)
                app.uiContainers = containers
                app.appInfo.containers = containers
                app.uiSelectedContainer = newContainer
                app.uiDefaultDataFolder = newName
                app.appInfo.dataUUID = newName
                if let bundleID = app.appInfo.bundleIdentifier() {
                    newContainer.makeLCContainerInfoPlist(appIdentifier: bundleID, keychainGroupId: manifestKeychainGroupId ?? Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
                }
            }
            for file in plistFiles {
                let folderName = file.deletingPathExtension().lastPathComponent
                // 落点：同名容器优先；对不上号的落当前默认容器
                // ——仅密匙备份的全部身家就是这几份快照，原逻
                // 辑只认同名/备份时默认/仅一份三种情况，容器
                // 名字一换（删后重装、多容器）就整份丢弃，登录
                // 态永远回不来；并入默认容器同键覆盖以备份为准
                let target = app.uiContainers.first(where: { $0.folderName == folderName })
                    ?? app.uiSelectedContainer
                    ?? app.uiContainers.first
                guard let target else { continue }
                // 从 iCloud 文件夹恢复时文件可能还是占位没下到
                // 本地：先触发下载、短等重试；读放 detached（见
                // helpers 注释），主线程不堵下载。注意 Data 读
                // 占位是同步堵、不是快速失败，所以重试前的第
                // 一读也必须 detached（原注释“读出来直接失败”
                // 只对真缺失/损坏成立，对占位不成立）。
                var plist = await Self.readKeychainPlist(file: file)
                if plist == nil {
                    try? fm.startDownloadingUbiquitousItem(at: file)
                    for _ in 0..<5 where plist == nil {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        plist = await Self.readKeychainPlist(file: file)
                    }
                }
                guard let plist else {
                    // 3.8.294（P0-4）：重试 5 秒仍读不出——若文件还没
                    // 下完（占位），不是快照损坏：记进下载未完成，报
                    // 告里提示，不要静默跳过。已下完仍读不出是损坏
                    // 或缺失，不归下载未完成。本地文件无 iCloud 状态，
                    // isFileDownloaded 按已下载处理（返回 true）。
                    if !Self.isFileDownloaded(file, underExternal: true) { outcome.downloadIncomplete = true }
                    continue
                }
                let data = plist.data
                let items = plist.items
                let writeResult = await Self.importKeychainItems(items, container: target)
                outcome.keychainImported += writeResult.imported
                if writeResult.imported == 0 && writeResult.lastStatus != errSecSuccess {
                    outcome.keychainStatus = writeResult.lastStatus
                }
                if writeResult.imported > 0 {
                    restoredExtras = true
                }
                // 3.8.375：删后重装时 App 会先装出一个新容器（随机组），恢复再把旧容器
                // 补回来；宿主直写只写目标容器，若启动进了新容器，令牌就 orphan。
                // 照排队文件同款，写进 App 全部容器各自的组（只写、不计入回执数）。
                for container in app.uiContainers where container.folderName != target.folderName {
                    _ = await Self.importKeychainItems(items, container: container)
                }
                // 宿主写回在这台机上同样靠不住（同一套 SecItem，
                // 读恒空的前车之鉴）：快照同时放进容器，游客
                // 下次打开时由进程内的钥匙串桥在 App 读令牌之前
                // 写回——这一份落了地，恢复就算数。写进这个
                // App 的每一个容器（不只目标容器）：启动时实际
                // 用哪个容器由 App 状态决定，只写一个出现过文
                // 件在 A、启动进 B、桥扑空的错位，全写堵死
                var queuedAny = false
                for container in app.uiContainers {
                    if (try? data.write(to: container.containerURL.appendingPathComponent("CZFKeychainImport.plist"))) != nil {
                        queuedAny = true
                    }
                }
                if queuedAny {
                    // 不注入插件的 App 桥不加载，排队文件永远没
                    // 人消费：别混进"已排队"骗人，单列无法写回
                    if app.appInfo.dontInjectTweakLoader {
                        outcome.keychainUnwritable += items.count
                    } else {
                        outcome.keychainQueued += items.count
                    }
                    restoredExtras = true
                    // 3.8.305：钥匙串已排队也关窗——排队文件要下次
                    // 全新启动才由桥抢导，只合了文件没动容器名时
                    // 关窗集里没它，正在跑的 App 继续用内存旧状态、
                    // 看着像没恢复。把全部容器名补进关窗集，恢复后
                    // 统一关窗重开；没在跑就是空操作。
                    for container in app.uiContainers {
                        restoredFolderNames.insert(container.folderName)
                    }
                }
            }
        }
        outcome.ok = restoredContainers > 0 || restoredExtras
        // 恢复后清掉文件夹已不存在的容器条目：删 App 时文件夹被抹掉，
        // 条目还留在列表里，容器菜单里就一堆 UUID 幽灵，选了也打不开、
        // 登录也对不上，看着就是信息错乱。只删文件夹确实不存在的；
        // 刚恢复出来的文件夹都在磁盘上，不动。若当前选中正好被清掉，
        // 改选恢复出来的默认容器（或第一个还在的），免得下次打开仍
        // 进空容器。放关窗口之前，让关窗口也按纠正后的 dataUUID 走。
        let existingContainers = app.uiContainers.filter { fm.fileExists(atPath: $0.containerURL.path) }
        if existingContainers.count != app.uiContainers.count {
            app.uiContainers = existingContainers
            app.appInfo.containers = existingContainers
            if let selected = app.uiSelectedContainer, !existingContainers.contains(selected) {
                let fallback = newDefaultContainer ?? existingContainers.first
                app.uiSelectedContainer = fallback
                if let fallback {
                    app.uiDefaultDataFolder = fallback.folderName
                    app.appInfo.dataUUID = fallback.folderName
                }
            }
        }
        // 恢复免登录修正（2026-10-25）：钥匙串恢复只是把快照排队成
        // CZFKeychainImport.plist，真正写回在游客下次全新启动时由桥
        // 完成；恢复本身不杀已运行的游客，用户直接切回看到的还是未
        // 登录。恢复成功后若该 App 正在运行就关掉它（真终止进程，
        // 下次打开即全新启动、桥构造器抢导排队文件）；没在运行就是
        // 空操作。安装后自动恢复也走这里，刚装的 App 没在运行，
        // 同样是空操作。MultitaskDockManager 是 iOS 16+ 才有的类，
        // 必须用 #available 包住（2026-10-25 构建 #186 红字教训：
        // 不包就报 'only available in iOS 16.0 or newer'）。
        if #available(iOS 16.0, *) {
            // 关掉全部被恢复容器的在跑窗口，不只关 dataUUID：
            // 非默认容器 B 的窗口若在跑，恢复后它继续用内存旧
            // 数据跑，要手动关窗重开才生效；没在跑就是空操作。
            // 只关本次动过的容器，没动过的不打扰。
            for uuid in restoredFolderNames {
                MultitaskDockManager.shared.closeAppWindow(uuid: uuid)
            }
        }
        return outcome
    }

    /// 这份备份的范围（manifest 里的 scope 标记；旧备份没有
    /// 这个字段，一律按完整备份对待，返回空串）
    static func backupScope(of folderURL: URL) -> String {
        // 行角标跑在 body 主线程：iCloud 源 manifest 未下载时
        // Data(contentsOf:) 会触发隐式下载、慢网卡住界面；
        // 未同步按“无 manifest”处理（返回空串，与读失败同款），
        // 绝不为了一行角标去拉下载（previewItem 同款守卫）。
        let manifestURL = folderURL.appendingPathComponent("manifest.json")
        if let extURL = externalBackupFolderURL(),
           folderURL.path.hasPrefix(extURL.path + "/"),
           !isFileDownloaded(manifestURL, underExternal: true) {
            return ""
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return ""
        }
        return json["scope"] ?? ""
    }

    /// 备份列表上的范围角标：登录态档和旧的纯钥匙串档分开标，
    /// 完整备份不标
    static func backupScopeBadge(_ folderURL: URL) -> String {
        switch backupScope(of: folderURL) {
        case "keychain": return " · 仅密匙"
        case "login": return " · 登录态"
        default: return ""
        }
    }

    // 3.8.306：备份列表行上的钥匙串健康色——行里扫一眼就知道
    // 这个备份的登录令牌在不在。只看 Keychain 目录里有没有
    // .plist（备份只在有条目时才写 .plist，见 backupOneAppSync），
    // 不解析文件内容； iCloud 源未下载时不判断、不触发下载。
    // 返回 nil = 未知（不显示）；"ok" / "empty" / "missing"。
    static func backupKeychainHealth(_ folderURL: URL) -> String? {
        let keychainURL = folderURL.appendingPathComponent("Keychain")
        if let extURL = externalBackupFolderURL(),
           folderURL.path.hasPrefix(extURL.path + "/"),
           !isFileDownloaded(keychainURL, underExternal: true) {
            return nil
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: keychainURL.path, isDirectory: &isDir), isDir.boolValue else {
            return "missing"
        }
        let files = (try? fm.contentsOfDirectory(at: keychainURL, includingPropertiesForKeys: nil)) ?? []
        if files.contains(where: { $0.pathExtension == "plist" }) {
            return "ok"
        }
        return "empty"
    }

    /// 登录文件定位：整棵容器树的文件清单（相对路径→大小-
    /// 修改时间），不设 5MB 门槛——多大都记，只排除 tmp、
    /// 桥文件、符号链接。容器内直接用相对路径，宿主组容器
    /// 记 AppGroup/<组ID>/相对路径，多容器时再加容器文件夹
    /// 名前缀区分
    /// 容器内相对路径：两边都先解析符号链接再剥前缀。直接字
    /// 符串剥前缀会撞 /var → /private/var 解析不一致：枚举器
    /// 回的是 /private/var/...，容器路径是 /var/...，剥完剩
    /// “/privateLibrary/…”这种脏路径——备份拷到错目录、恢复
    /// 合并到错目录、tmp/桥文件排除失效、空壳判定失效，登录
    /// 态全程丢包。这就是 v141–v145 登录态死活回不来的根因
    static func relativePath(of file: URL, under container: URL) -> String? {
        let base = container.resolvingSymlinksInPath().path
        let full = file.resolvingSymlinksInPath().path
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

    /// 登录态文件清单（递归）：整棵容器树全收——含 tmp、
    /// Caches、符号链接（解析后按真实文件收录，祖先链防
    /// 循环）。完整备份能恢复而登录备份不能，差集只剩这
    /// 三类（tmp/链接/缓存大文件），索性全收，不再逐项猜；
    /// 唯一排除是钥匙串桥自己的 3 个根文件。LCContainerInfo
    /// .plist 照收（恢复补容器时靠它认组号）。返回（相对
    /// 路径，真实源文件，大小）——链接的源是解析后的目标
    static func loginStateEntries(in container: URL, fm: FileManager) -> [(rel: String, src: URL, size: Int)] {
        var out: [(rel: String, src: URL, size: Int)] = []
        let bridgeFiles: Set<String> = ["CZFKeychainDump.plist", "CZFKeychainImport.plist", "CZFKeychainBridgeStatus.txt"]
        func walk(_ dir: URL, prefix: String, depth: Int, ancestors: [String]) {
            guard depth <= 16 else { return }
            let resolvedDir = dir.resolvingSymlinksInPath().path
            guard !ancestors.contains(resolvedDir) else { return }
            let next = ancestors + [resolvedDir]
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey], options: []) else { return }
            for item in items {
                let name = item.lastPathComponent
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                guard let v = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { continue }
                if v.isSymbolicLink == true {
                    guard let dest = try? fm.destinationOfSymbolicLink(atPath: item.path) else { continue }
                    let target = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : dir.appendingPathComponent(dest)
                    let t = target.resolvingSymlinksInPath()
                    guard let tv = try? t.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { continue }
                    if tv.isDirectory == true {
                        walk(t, prefix: rel, depth: depth + 1, ancestors: next)
                    } else if tv.isRegularFile == true {
                        out.append((rel, t, tv.fileSize ?? 0))
                    }
                    continue
                }
                if v.isDirectory == true {
                    walk(item, prefix: rel, depth: depth + 1, ancestors: next)
                    continue
                }
                guard v.isRegularFile == true else { continue }
                if !rel.contains("/") && bridgeFiles.contains(rel) { continue }
                out.append((rel, item, v.fileSize ?? 0))
            }
        }
        walk(container, prefix: "", depth: 0, ancestors: [])
        return out
    }

    /// 路径清单按顶级目录分组计数（备份弹窗报分布用；身份
    /// 文件不算会话文件，不进分布；LCAppGroup 按组 ID 单列，
    /// 一眼看出会话是不是在组容器里）
    static func loginStateDirBreakdown(for paths: [String]) -> [String: Int] {
        var d: [String: Int] = [:]
        for rel in paths where rel != "LCContainerInfo.plist" {
            let parts = rel.split(separator: "/")
            let key: String
            if parts.count <= 1 {
                key = "(根目录)"
            } else if parts[0] == "LCAppGroup", parts.count >= 2 {
                key = "LCAppGroup/" + parts[1]
            } else {
                key = String(parts[0])
            }
            d[key, default: 0] += 1
        }
        return d
    }

    /// 把登录态文件从 src 拷到 dst（备份用：dst 是新建的空
    /// 目录，逐个建中间目录直拷）。按大小升序拷、单容器封
    /// 顶 300MB——会话文件普遍小，先保住，超预算的缓存大
    /// 文件排后面被截断。返回（实拷的会话文件数，目录分
    /// 布，超预算跳过数）——身份文件照拷但不计入文件数
    @discardableResult
    static func copyLoginStateFiles(from src: URL, to dst: URL, fm: FileManager) -> (count: Int, breakdown: [String: Int], skipped: Int, skippedPaths: [String], failed: Int, failedPaths: [String]) {
        var count = 0
        var bytes = 0
        var skipped = 0
        // 跳过路径清单：以前只报“跳过 N 个文件”，从报告证不了
        // 也证伪不了会话文件在不在跳过里；现在把相对路径也带
        // 出来（只收前 50 条防 2985 个全列出把报告撑爆，数照全计）。
        var skippedPaths: [String] = []
        // 13：拷失败清单——以前 try? 拷失败直接丢、回执里一个
        // 字没有，会话文件拷丢了用户只看到“备份成功”。现在
        // 失败也计数+列路径（前 50 条），进回执。
        var failed = 0
        var failedPaths: [String] = []
        var copied: [String] = []
        // 3.8.312：登录关键文件优先——以前按大小升序拷、300MB
        // 封顶，假设“会话文件普遍小”。但红果这类 App 的登录态
        // 落在单个大文件里（大 SQLite 库 / WebView 存储），按大
        // 小排后面被截断：登录态备份恢复后登录过期，完整备份
        // （整容器全拷）却能直接登录。登录关键文件先全拷、不
        // 计入 300MB 预算；其余文件仍按大小升序、300MB 封顶。
        func isLoginCritical(_ rel: String) -> Bool {
            let lower = rel.lowercased()
            if lower.hasPrefix("library/preferences/") || lower.hasPrefix("documents/") { return true }
            if lower.hasSuffix(".db") || lower.hasSuffix(".sqlite") || lower.hasSuffix(".sqlite3")
                || lower.hasSuffix(".sqlite-wal") || lower.hasSuffix(".sqlite-shm") || lower.hasSuffix(".plist") { return true }
            if lower.contains("cookie") || lower.contains("webkit") || lower.contains("session")
                || lower.contains("token") || lower.contains("account") || lower.contains("login")
                || lower.contains("auth") { return true }
            return false
        }
        let entries = loginStateEntries(in: src, fm: fm)
        let priority = entries.filter { isLoginCritical($0.rel) }
        let regular = entries.filter { !isLoginCritical($0.rel) }.sorted { $0.size < $1.size }
        // 先拷登录关键文件（不计预算，必拷）
        for e in priority {
            let d = dst.appendingPathComponent(e.rel)
            try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: e.src, to: d)) != nil {
                copied.append(e.rel)
                if e.rel != "LCContainerInfo.plist" {
                    count += 1
                }
            } else {
                // 13：拷失败记入失败清单（不静默丢弃）。
                failed += 1
                if failedPaths.count < 50 { failedPaths.append(e.rel) }
                // B-3/B-4 同款：单文件拷失败也可能留半截文件（磁盘满时最常见），不清掉的话截断的 .db/.plist 会进备份、恢复时盖掉 live 的好文件。
                try? fm.removeItem(at: d)
            }
        }
        // 再拷其余文件，按大小升序、300MB 封顶
        for e in regular {
            if bytes + e.size > 300 * 1024 * 1024 {
                skipped += 1
                if skippedPaths.count < 50 { skippedPaths.append(e.rel) }
                continue
            }
            let d = dst.appendingPathComponent(e.rel)
            try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: e.src, to: d)) != nil {
                bytes += e.size
                copied.append(e.rel)
                if e.rel != "LCContainerInfo.plist" {
                    count += 1
                }
            } else {
                // 13：拷失败记入失败清单（不静默丢弃）。
                failed += 1
                if failedPaths.count < 50 { failedPaths.append(e.rel) }
                // B-3/B-4 同款：拷失败的半截文件清掉，别让它进备份（同上，恢复时会盖掉 live 的好文件）。
                try? fm.removeItem(at: d)
            }
        }
        return (count, loginStateDirBreakdown(for: copied), skipped, skippedPaths, failed, failedPaths)
    }

    /// 把登录态文件合并进现有容器（恢复用：同名文件逐个覆盖，
    /// 容器里其他文件不动；LCContainerInfo.plist 是活容器自己
    /// 的身份文件，永不覆盖）。返回（合并成功数，合并失败数，
    /// 失败路径前 50 条）——与备份侧 #13 的 failed/failedPaths
    /// 对称：合并失败不抛错，但失败要进报告，否则“合并 0 个”
    /// 分不出“备份里没东西”还是“东西在但没合进来”。
    /// mirrorGroupToHost：目标容器没开隔离组时，备份里的
    /// LCAppGroup/<组ID>/ 同步镜像一份到宿主组容器目录——
    /// 游客读组数据走哪边取决于容器当时的隔离开关，两边都
    /// 落一份才不会因开关状态错位而读空（不计入合并数）
    @discardableResult
    // 11 登录态恢复先删后拷：照 replaceContainerOffMain 同款，
    // 单文件先拷临时文件再原子替换。原来先删目标再拷，拷失败
    // （iCloud 占位未下完、磁盘满）时 live 登录文件已删、没回来。
    // tmp 与目标同目录（同卷，replaceItemAt 才成立）；哪步失败
    // 都清 tmp、目标原样不动，返回 false。
    static func czfReplaceFileAtomic(from src: URL, to dest: URL, fm: FileManager) -> Bool {
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".restore-tmp-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: src, to: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
        return true
    }

    static func mergeLoginStateFiles(from src: URL, to dst: URL, fm: FileManager, mirrorGroupToHost: URL? = nil) -> (merged: Int, failed: Int, failedPaths: [String]) {
        var count = 0
        // B-6：合并失败数与路径（与备份侧 #13 对称）。
        var failed = 0
        var failedPaths: [String] = []
        for e in loginStateEntries(in: src, fm: fm) {
            let rel = e.rel
            if rel == "LCContainerInfo.plist" { continue }
            let s = e.src
            let d = dst.appendingPathComponent(rel)
            try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 11：先拷临时文件再原子替换，拷失败时 live 文件不动。
            if czfReplaceFileAtomic(from: s, to: d, fm: fm) {
                count += 1
            } else {
                // B-6：主份合并失败记数+列路径，别静默丢。
                failed += 1
                if failedPaths.count < 50 { failedPaths.append(rel) }
            }
            if let host = mirrorGroupToHost {
                let parts = rel.split(separator: "/")
                if parts.count >= 3 && parts[0] == "LCAppGroup" {
                    let rest = parts.dropFirst(2).joined(separator: "/")
                    let hd = host.appendingPathComponent(String(parts[1])).appendingPathComponent(rest)
                    try? fm.createDirectory(at: hd.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // 11：镜像份同款原子替换。
                    // B-6：镜像份失败也记一份（路径前挂“镜像：”，
                    // 与主份区分开——主份成功、镜像失败时报告照写
                    // “已恢复”，但隔离组开关切到另一边时 App 可能读空。
                    if !czfReplaceFileAtomic(from: s, to: hd, fm: fm) {
                        failed += 1
                        if failedPaths.count < 50 { failedPaths.append("镜像：" + rel) }
                    }
                }
            }
        }
        return (count, failed, failedPaths)
    }

    /// 备份的版本号与当前已装版本是否不同（版本更新后恢复
    /// 旧备份时提示用，让用户知道数据是旧版时刻的整套快照）
    static func backupVersionDiffers(appFolder: URL, app: LCAppModel) async -> Bool {
        guard let json = await Self.manifestDict(appFolder: appFolder),
              let backupVersion = json["version"], !backupVersion.isEmpty,
              let currentVersion = app.appInfo.version(), !currentVersion.isEmpty else {
            return false
        }
        return backupVersion != currentVersion
    }

    /// 钥匙串组名：与游客侧 SecItem.m 的拼法一致（组号 0 无后缀）
    static func keychainGroupString(groupId: Int) -> String {
        let team = LCSharedUtils.teamIdentifier() ?? ""
        if groupId == 0 {
            return "\(team).com.kdt.livecontainer.shared"
        }
        return "\(team).com.kdt.livecontainer.shared.\(groupId)"
    }

    /// 读一个 App 的组容器 ID 列表：从它的可执行文件签名权限里取。
    /// 排除 LiveContainer 自己的组——那个在游客侧映射到宿主根
    /// 目录本身，绝不能当数据拷进拷出
    static func appGroupIDs(for app: LCAppModel) -> [String] {
        guard let bundlePath = app.appInfo.bundlePath(),
              let info = NSDictionary(contentsOfFile: bundlePath + "/Info.plist") as? [String: Any],
              let execName = info["CFBundleExecutable"] as? String,
              let xml = getExecutableEntitlementXML(bundlePath + "/" + execName),
              let data = xml.data(using: .utf8) else {
            return []
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any],
              let groups = dict["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        let own = LCSharedUtils.appGroupID()
        return groups.filter { $0 != own }
    }

    /// 把钥匙串桥插件部署到两个全局 Tweaks 文件夹（与手势
    /// 插件同一套路：比内容、只签换掉的文件）。游客启动时由
    /// TweakLoader 加载它，在游客进程内导出/写回钥匙串——
    /// 宿主侧 SecItem 读游客钥匙串在这台机上恒为空，只能
    /// 借游客自己的进程
    static func deployKeychainBridgeTweak() {
        let fm = FileManager.default
        guard let src = Bundle.main.url(forResource: "CZFKeychainBridge", withExtension: "dylib") else { return }
        let srcData = try? Data(contentsOf: src)
        var copiedDests: [URL] = []
        for folder in [LCPath.tweakPath, LCPath.lcGroupTweakPath] {
            let dest = folder.appendingPathComponent("CZFKeychainBridge.dylib")
            let destData = try? Data(contentsOf: dest)
            if destData != srcData {
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: src, to: dest)) != nil {
                    copiedDests.append(dest)
                }
            }
        }
        if !copiedDests.isEmpty {
            Task(priority: .userInitiated) {
                for dest in copiedDests {
                    try? await LCUtils.signSingleTweakFile(dest)
                }
            }
        }
    }

    /// 把钥匙串快照写回目标容器：组号改成目标容器自己的
    /// （同名覆盖恢复时容器组号可能与备份时不同，按现有的
    /// 写，App 才找得到）；别名盖成目标容器的文件夹名——与
    /// 游客存入时 SecItem.m 盖的 alis 一致，LCUI 按别名清理、
    /// 导出按别名兜底查都认得出这批条目。同步标记要摘掉：
    /// 宿主没有 iCloud 钥匙串权限，带着 sync 写回会被系统
    /// 以缺权限拒绝。同键已存在时先删再加，保证值以备份为
    /// 准。全量属性写不进时退到最小属性集再试一次：快照里
    /// 可能带着原进程上下文的键，换个进程写会被系统以参数
    /// 错误整条拒绝。返回写进条数 + 最后一次失败的错误码，
    /// 失败不再静默
    @discardableResult
    // v222 起 async：SecItemAdd/Delete 是同步跨进程 IPC，逐条
    // 循环在主线程是长堵（快照条数多时）；整段放 Task.detached，
    // 调用方只收结果、在调用方线程写回（调用点写的是
    // outcome/restoredExtras 局部量，无 @State/模型写回）。
    // 验查：本函数只读 container.keychainGroupId（Int）与
    // container.folderName（String），不写模型；group 与
    // folderName 先在调用方线程取成值再进 detached，不捕获
    // container 对象（LCContainer 是 class、非 Sendable）。
    // 本 target 是 Swift 5 mode，捕获 items（[[String: Any]]）
    // 可编译；CI 为最终 verdict。
    static func importKeychainItems(_ items: [[String: Any]], container: LCContainer) async -> (imported: Int, lastStatus: OSStatus) {
        let group = keychainGroupString(groupId: container.keychainGroupId)
        let folderName = container.folderName
        return await Task.detached {
            var imported = 0
            var lastStatus: OSStatus = errSecSuccess
            for item in items {
                var attrs = item
                attrs.removeValue(forKey: "cdat")
                attrs.removeValue(forKey: "mdat")
                attrs.removeValue(forKey: kSecAttrSynchronizable as String)
                attrs[kSecAttrAccessGroup as String] = group
                attrs["alis"] = folderName
                var status = SecItemAdd(attrs as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    var query = attrs
                    query.removeValue(forKey: kSecValueData as String)
                    SecItemDelete(query as CFDictionary)
                    status = SecItemAdd(attrs as CFDictionary, nil)
                }
                if status != errSecSuccess {
                    let minimalKeys: [String] = [
                        kSecClass as String, kSecAttrAccount as String,
                        kSecAttrService as String, kSecAttrGeneric as String,
                        // 3.8.346：恢复侧补 kSecAttrServer（与 345
                        // 导出侧对称：InternetPassword 的标识常在
                        // server 上，service 常为空；最小集丢了
                        // server，App 按 server 查就找不到，静默
                        // “恢复了但没登录”）。
                        kSecAttrServer as String,
                        kSecAttrLabel as String, kSecAttrAccessible as String,
                        kSecValueData as String
                    ]
                    var minimal: [String: Any] = [
                        kSecAttrAccessGroup as String: group,
                        "alis": folderName
                    ]
                    for key in minimalKeys {
                        if let value = attrs[key] {
                            minimal[key] = value
                        }
                    }
                    if minimal[kSecValueData as String] != nil {
                        var deleteQuery = minimal
                        deleteQuery.removeValue(forKey: kSecValueData as String)
                        SecItemDelete(deleteQuery as CFDictionary)
                        status = SecItemAdd(minimal as CFDictionary, nil)
                    }
                }
                if status == errSecSuccess {
                    imported += 1
                } else {
                    lastStatus = status
                }
            }
            return (imported, lastStatus)
        }.value
    }

    /// #5 配套：已添加的源表一次拉全（恢复未装 App 时调用方
    /// 先拉一次，后面每个缺 App 只查这张表，不再每 App 重拉全源）
    func fetchAllSourceApps() async -> [[String: Any]] {
        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: "LCAltStoreSourceURLs") as? [String] ?? []
        var all: [[String: Any]] = []
        for urlString in stored {
            guard let sourceURL = URL(string: urlString) else { continue }
            do {
                let (data, response) = try await CZFVPNManager.hostSession().data(from: sourceURL)
                // 404 等错误页也可能落盘成“源表”再解析；先验状态，
                // 非 2xx 直接跳过这个源，别把错误页当源表解析。
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let apps = json["apps"] as? [[String: Any]] else { continue }
                all += apps
            } catch {
                continue
            }
        }
        return all
    }

    // 纯查表：不碰网络。优先取 versions[0].downloadURL，兼容顶层 downloadURL
    func downloadURLForApp(bundleID: String, name: String, in sourceApps: [[String: Any]]) -> URL? {
        for app in sourceApps {
            let appBundleID = app["bundleIdentifier"] as? String ?? ""
            let appName = app["name"] as? String ?? ""
            let match = (!bundleID.isEmpty && appBundleID == bundleID) || (!name.isEmpty && appName == name)
            if match {
                var downloadString: String? = app["downloadURL"] as? String
                if downloadString == nil,
                   let versions = app["versions"] as? [[String: Any]],
                   let first = versions.first {
                    downloadString = first["downloadURL"] as? String
                }
                if let ds = downloadString, let url = URL(string: ds) {
                    return url
                }
            }
        }
        return nil
    }

    /// 3.8.299：源里没有待恢复 App 的下载地址时，当场请用户选它的
    /// IPA 文件（asCopy，选中的文件会拷一份，装完再恢复）。取消
    /// 返回 nil（调用方按原有“未在源中找到”记）。恢复 Task 不一
    /// 定在主线程，弹 picker 必须切到主线程；用 continuation 把
    /// delegate 回调桥回 async，选到或取消都只 resume 一次。
    private func pickIPAForRestore(appName: String) async -> URL? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                // 先确认能弹 picker 再建 coordinator：没窗口时直接
                // resume nil，不建 coordinator（建了又没回调，selfRetain
                // 会一直挂着不释放）。
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootViewController = windowScene.windows.first?.rootViewController else {
                    continuation.resume(returning: nil)
                    return
                }
                let coordinator = RestoreIPAPickerCoordinator { url in
                    continuation.resume(returning: url)
                }
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.ipa, UTType.tipa], asCopy: true)
                picker.allowsMultipleSelection = false
                picker.delegate = coordinator
                // picker 标题写清是给哪个 App 选安装包，免得用户
                // 对着文件列表不知道在选谁的 IPA
                picker.title = "为「\(appName)」选择 IPA"
                rootViewController.present(picker, animated: true)
            }
        }
    }

    func moveDanglingFolders() async {
        let fm = FileManager()
        do {
            var appDataFoldersInUse : Set<String> = Set();
            var tweakFoldersInUse : Set<String> = Set();
            for app in sharedModel.apps {
                if !app.appInfo.isShared {
                    continue
                }
                for container in app.appInfo.containers {
                    appDataFoldersInUse.update(with: container.folderName);
                }

                
                if let folder = app.appInfo.tweakFolder {
                    tweakFoldersInUse.update(with: folder);
                }

            }
            
            for app in sharedModel.hiddenApps {
                if !app.appInfo.isShared {
                    continue
                }
                for container in app.appInfo.containers {
                    appDataFoldersInUse.update(with: container.folderName);
                }
                if let folder = app.appInfo.tweakFolder {
                    tweakFoldersInUse.update(with: folder);
                }

            }
            
            var movedDataFolderCount = 0
            let sharedDataFolders = try fm.contentsOfDirectory(atPath: LCPath.lcGroupDataPath.path)
            for sharedDataFolder in sharedDataFolders {
                if appDataFoldersInUse.contains(sharedDataFolder) {
                    continue
                }
                try fm.moveItem(at: LCPath.lcGroupDataPath.appendingPathComponent(sharedDataFolder), to: LCPath.dataPath.appendingPathComponent(sharedDataFolder))
                movedDataFolderCount += 1
            }
            
            var movedTweakFolderCount = 0
            let sharedTweakFolders = try fm.contentsOfDirectory(atPath: LCPath.lcGroupTweakPath.path)
            for tweakFolderInUse in sharedTweakFolders {
                if tweakFoldersInUse.contains(tweakFolderInUse) || tweakFolderInUse == "TweakLoader.dylib" {
                    continue
                }
                try fm.moveItem(at: LCPath.lcGroupTweakPath.appendingPathComponent(tweakFolderInUse), to: LCPath.tweakPath.appendingPathComponent(tweakFolderInUse))
                movedTweakFolderCount += 1
            }
            successInfo = "lc.settings.moveDanglingFolderComplete %lld %lld".localizeWithFormat(movedDataFolderCount,movedTweakFolderCount)
            successShow = true
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func moveAppGroupFolderFromAppGroupToPrivate() {
        let fm = FileManager()
        do {
            if !fm.fileExists(atPath: LCPath.appGroupPath.path) {
                try fm.createDirectory(atPath: LCPath.appGroupPath.path, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: LCPath.lcGroupAppGroupPath.path) {
                try fm.createDirectory(atPath: LCPath.lcGroupAppGroupPath.path, withIntermediateDirectories: true)
            }
            
            let privateFolderContents = try fm.contentsOfDirectory(at: LCPath.appGroupPath, includingPropertiesForKeys: nil)
            let sharedFolderContents = try fm.contentsOfDirectory(at: LCPath.lcGroupAppGroupPath, includingPropertiesForKeys: nil)
            if privateFolderContents.count > 0 {
                errorInfo = "lc.settings.appGroupExistPrivate".loc
                errorShow = true
                return
            }
            for file in sharedFolderContents {
                try fm.moveItem(at: file, to: LCPath.appGroupPath.appendingPathComponent(file.lastPathComponent))
            }
            successInfo = "lc.settings.appGroup.moveSuccess".loc
            successShow = true
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func moveAppGroupFolderFromPrivateToAppGroup() {
        let fm = FileManager()
        do {
            if !fm.fileExists(atPath: LCPath.appGroupPath.path) {
                try fm.createDirectory(atPath: LCPath.appGroupPath.path, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: LCPath.lcGroupAppGroupPath.path) {
                try fm.createDirectory(atPath: LCPath.lcGroupAppGroupPath.path, withIntermediateDirectories: true)
            }
            
            let privateFolderContents = try fm.contentsOfDirectory(at: LCPath.appGroupPath, includingPropertiesForKeys: nil)
            let sharedFolderContents = try fm.contentsOfDirectory(at: LCPath.lcGroupAppGroupPath, includingPropertiesForKeys: nil)
            if sharedFolderContents.count > 0 {
                errorInfo = "lc.settings.appGroupExist Shared".loc
                errorShow = true
                return
            }
            for file in privateFolderContents {
                try fm.moveItem(at: file, to: LCPath.lcGroupAppGroupPath.appendingPathComponent(file.lastPathComponent))
            }
            successInfo = "lc.settings.appGroup.moveSuccess".loc
            successShow = true
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func copy(text: String) {
        UIPasteboard.general.string = text
    }
    
    func openInFilza(path: URL) {
        let launchURLStr = "filza://view\(path.path)/."
        Task {
            do {
                // 锁旁路：Filza 也能被锁定，直启前先过共享守卫；
                // 未装 Filza 时与原来一样静默无事，未锁时不弹人脸。
                guard let filza = sharedModel.apps.first(where: { $0.appInfo.bundleIdentifier() == "com.tigisoftware.Filza" }) else { return }
                guard await filza.czfAuthenticateIfLocked() else { return }
                try await filza.runApp(urlStr: launchURLStr)
            } catch {
                successInfo = error.localizedDescription
                successShow = true
            }
        }
    }

    /// v216：在文件 App 里打开一个备份文件夹（恢复后“无可恢复
    /// 数据”时核对用）。本 App 文稿内的备份走 shareddocuments://
    /// 深链（能定位到 Backups/<名>）；外部文件夹（iCloud 等）
    /// 不在文稿内、shareddocuments 到不了，改直接开 file://
    ///（文件 App 对 File Provider 位置一般能接住）；接不住时
    /// 不报错——报告里已有文件夹名，用户可在文件 App 里手动找。
    /// 注意：本函数不读文件夹内容，只拼 URL，不触发 iCloud 下载。
    func openFolderInFiles(_ folder: URL) {
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           folder.path.hasPrefix(docs.path + "/") {
            let rel = String(folder.path.dropFirst(docs.path.count + 1))
            if let encoded = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "shareddocuments://" + encoded) {
                UIApplication.shared.open(url)
                return
            }
        }
        UIApplication.shared.open(folder)
    }
    
    /// 读一个备份文件夹的 manifest（读不到/格式不对返回 nil；
    /// 调用方一律按“无 manifest”处理，不抛错）。
    static func manifestInfo(of folderURL: URL) -> (displayName: String, bundleID: String, dataUUID: String, scope: String, backupDate: String)? {
        guard let data = try? Data(contentsOf: folderURL.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return (json["displayName"] ?? "", json["bundleIdentifier"] ?? "", json["dataUUID"] ?? "", json["scope"] ?? "", json["backupDate"] ?? "")
    }

    // 3.8.281：锁定备份——锁了的备份文件夹不参与覆盖（备份时跳过，
    // 删除要先解锁）。锁存在 UserDefaults 里、按文件夹名记（本地
    // 与 iCloud 同名文件夹共用一把锁；备份文件夹本身不改格式，
    // 恢复流程不受影响）。
    static let lockedBackupsKey = "CZFLockedBackups"
    static func isBackupLocked(_ folderName: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: lockedBackupsKey) ?? []).contains(folderName)
    }
    static func setBackupLocked(_ folderName: String, locked: Bool) {
        var names = UserDefaults.standard.stringArray(forKey: lockedBackupsKey) ?? []
        if locked {
            if !names.contains(folderName) { names.append(folderName) }
        } else {
            names.removeAll { $0 == folderName }
        }
        UserDefaults.standard.set(names, forKey: lockedBackupsKey)
    }
    static func lockedBackupNameSet() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: lockedBackupsKey) ?? [])
    }
    // 3.8.281：今天已备过登录态没（批量备份跳过重复用）：本地
    // 备份 manifest 的 scope 是 login 且 backupDate 是今天。
    static func isLoginBackupCurrentToday(app: LCAppModel, backupRoot: URL, fm: FileManager) -> Bool {
        let folderName = Self.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
        guard let info = Self.manifestInfo(of: backupRoot.appendingPathComponent(folderName)) else { return false }
        guard info.scope == "login" else { return false }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return info.backupDate.hasPrefix(fmt.string(from: Date()))
    }

    /// v216：多开实例的备份文件夹名。同款多开（同显示名、不同
    /// dataUUID）以前都写 Backups/<显示名>，后备的把先备的整
    /// 文件夹删掉重写——同款两个实例只能留一个备份。规则：
    /// 1. 备份根里已有文件夹的 manifest dataUUID 对上本实例
    ///    → 沿用那个名（新旧命名都认，不改名、不另起）；
    /// 2. 老备份没有 dataUUID 时：同名 + 同 bid + 同显示名
    ///    → 沿用旧名（区分不出来，宁可沿用不另起）；
    /// 3. 平名已被别的实例占 → 新备份用“显示名（dataUUID 前 8 位）”
    ///    后缀（dataUUID 为空时退第一容器文件夹名前 8 位，
    ///    再没有退“2”——已装 App 一定有容器，基本走不到）；
    /// 4. 否则用平名。老备份文件夹本身永远不改名（只对新备份
    ///    生效），恢复时新旧两种命名都要认（见恢复匹配的
    ///    dataUUID 优先分支）。
    static func backupFolderName(for app: LCAppModel, backupRoot: URL, fm: FileManager) -> String {
        let base = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
        let myUUID = app.appInfo.dataUUID ?? ""
        let myBid = app.appInfo.bundleIdentifier() ?? ""
        guard let folders = try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) else { return base }
        let dirs = folders.filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        // 1. 同实例已有文件夹：dataUUID 对上就沿用
        if !myUUID.isEmpty {
            for folder in dirs where manifestInfo(of: folder)?.dataUUID == myUUID {
                return folder.lastPathComponent
            }
        }
        // 1b. 孤儿文件夹认领（3.8.281）：重装会换 dataUUID，规则 1
        // 认不出旧文件夹、规则 3 就会另起带后缀的新文件夹，越备
        // 越多。旧文件夹同名 + 同 bundleID、且它的 dataUUID 已
        // 不属于任何在装 App（多开兄弟的 dataUUID 还在装，绝不
        // 动，各备各的）→ 沿用旧文件夹名，下次备份写新 manifest
        // 时 dataUUID 自然更新成新的。已锁定的不认领；孤儿有
        // 多个时认备份日期最新的那个。
        do {
            let installedUUIDs = Set((DataManager.shared.model.apps + DataManager.shared.model.hiddenApps).compactMap { $0.appInfo.dataUUID })
            var orphanCandidates: [(name: String, date: String)] = []
            for folder in dirs {
                let name = folder.lastPathComponent
                guard let info = manifestInfo(of: folder),
                      info.bundleID == myBid, info.displayName == base,
                      !info.dataUUID.isEmpty, info.dataUUID != myUUID,
                      !installedUUIDs.contains(info.dataUUID),
                      !Self.isBackupLocked(name) else { continue }
                orphanCandidates.append((name, info.backupDate))
            }
            if let best = orphanCandidates.sorted(by: { $0.date > $1.date }).first {
                return best.name
            }
        }
        // 2. 老备份无 dataUUID 时的同实例认法
        for folder in dirs where folder.lastPathComponent == base {
            if let info = manifestInfo(of: folder), info.bundleID == myBid && info.displayName == base && (info.dataUUID.isEmpty || myUUID.isEmpty) {
                return base
            }
        }
        // 3. 平名已被占 → 实例后缀
        if dirs.contains(where: { $0.lastPathComponent == base }) {
            let short: String
            if !myUUID.isEmpty {
                short = String(myUUID.prefix(8))
            } else if let firstFolder = app.uiContainers.first?.folderName, !firstFolder.isEmpty {
                short = String(firstFolder.prefix(8))
            } else {
                short = "2"
            }
            return "\(base)（\(short)）"
        }
        return base
    }

    /// 一个文件是否已下载到本机（v216 预览用）：本地备份恒为
    /// 已下载；iCloud 源按 ubiquitousItemDownloadingStatus 判，
    /// 读不到状态按已下载处理（与 waitForUbiquitousDownload 语义一致，
    /// 不卡住）。本函数只读元数据，不触发下载。
    static func isFileDownloaded(_ url: URL, underExternal: Bool) -> Bool {
        guard underExternal else { return true }
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus else { return true }
        return status == .current
    }

    /// v216：恢复前备份清单预览。单个 App 文件夹（有 manifest）
    /// 返回 1 项；时间戳文件夹（无 manifest）返回其下每个子文件
    /// 夹各 1 项（无 manifest 的子夹也列，范围标“未知”，与恢复
    /// 时把它当 App 文件夹处理的行为一致）。只读元数据 + 已下载
    /// 文件内容，绝不触发 iCloud 下载；未同步的钥匙串只标
    /// “未同步”，不给假数字。
    /// 登录态预览会话文件数：整树枚举放 detached（只传目录值、
    /// 只回计数值，不碰模型/@State）。原来在点行主线程同步跑，
    /// 大容器几万文件时 resourceValues 逐个取是秒级长堵；v223
    /// 没动预览，登录恢复点行先卡在这里、再看门狗杀进程
    /// （卡 + 闪退）。逻辑与原来一字不差：跳过目录、100000
    /// 封顶、skipsHiddenFiles。
    static func sessionFileCount(dirs: [URL]) async -> Int {
        await Task.detached {
            let fm = FileManager.default
            var count = 0
            for dir in dirs {
                if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for case let file as URL in enumerator {
                        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                        count += 1
                        if count > 100000 { break }
                    }
                }
                if count > 100000 { break }
            }
            return count
        }.value
    }

    static func previewItems(for folderURL: URL) async -> [BackupPreviewItem] {
        let fm = FileManager.default
        let underExternal: Bool = {
            guard let extURL = externalBackupFolderURL() else { return false }
            return folderURL.path.hasPrefix(extURL.path + "/")
        }()
        if fm.fileExists(atPath: folderURL.appendingPathComponent("manifest.json").path) {
            return [await previewItem(for: folderURL, fm: fm, underExternal: underExternal)]
        }
        guard let children = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return [] }
        // 顺序 await 保序：原来 map 顺序即展示顺序，并行会乱序。
        var out: [BackupPreviewItem] = []
        for child in children.filter({ !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            out.append(await previewItem(for: child, fm: fm, underExternal: underExternal))
        }
        return out
    }

    static func previewItem(for folderURL: URL, fm: FileManager, underExternal: Bool) async -> BackupPreviewItem {
        // 预览跑在点按的主线程：iCloud 源的 manifest 没下载到
        // 本机时直接 Data(contentsOf:) 会触发隐式下载、卡住
        // 界面——先看下载状态，未同步时按“无 manifest”处理
        // （范围标未知、日期空），绝不为了一次预览去拉下载。
        let manifestURL = folderURL.appendingPathComponent("manifest.json")
        let info = isFileDownloaded(manifestURL, underExternal: underExternal) ? manifestInfo(of: folderURL) : nil
        let children = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        // 与 restoreOneApp 的 containerFolders 同口径
        let containerCount = children.filter { $0.lastPathComponent != "manifest.json" && !$0.lastPathComponent.hasSuffix(".app") && $0.lastPathComponent != "AppGroup" && $0.lastPathComponent != "Keychain" }.count
        let hasAppBundle = children.contains { $0.lastPathComponent.hasSuffix(".app") }
        // 钥匙串：目录不存在 = 无快照；存在则只数已下载的 plist，
        // 有任何一个未下载就标未同步（数是已下载部分的合计，
        // 展示时带“部分未同步”，不冒充总数）。
        var keychainCount: Int? = nil
        var keychainSynced = true
        let keychainDir = folderURL.appendingPathComponent("Keychain")
        if (try? keychainDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           let plists = try? fm.contentsOfDirectory(at: keychainDir, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "plist" }) {
            var sum = 0
            for plist in plists {
                if isFileDownloaded(plist, underExternal: underExternal) {
                    if let data = try? Data(contentsOf: plist),
                       let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
                        sum += items.count
                    }
                } else {
                    keychainSynced = false
                }
            }
            keychainCount = sum
        }
        // 会话文件只对登录态档计数（完整档的会话文件在整容器里，
        // 不单数）：递归数容器顶层条目下的文件，100001 封顶。
        // 整树枚举放 detached（见 sessionFileCount 注释）：原来
        // 在点行主线程同步跑，大容器几万文件时是秒级长堵。
        var sessionFileCount: Int? = nil
        if info?.scope == "login" {
            let containerDirs = children.filter { $0.lastPathComponent != "manifest.json" && !$0.lastPathComponent.hasSuffix(".app") && $0.lastPathComponent != "AppGroup" && $0.lastPathComponent != "Keychain" }
            sessionFileCount = await Self.sessionFileCount(dirs: containerDirs)
        }
        return BackupPreviewItem(
            folderName: folderURL.lastPathComponent,
            displayName: (info?.displayName.isEmpty == false ? info!.displayName : folderURL.lastPathComponent),
            scope: info?.scope ?? "",
            backupDate: info?.backupDate ?? "",
            containerCount: containerCount,
            keychainCount: keychainCount,
            keychainSynced: keychainSynced,
            sessionFileCount: sessionFileCount,
            hasAppBundle: hasAppBundle
        )
    }

    /// 多开实例键：多开同款共用 Bundle ID，拿 bid 当选择键会
    /// 选一个带另一个（Muse/Muse5 实证）。实例身份 = 数据
    /// 文件夹名 dataUUID（每实例各一个，改名不动它）；没
    /// dataUUID 的（默认容器）退到 bid + 显示名（多开建时强制
    /// 不同名，撞不上）。键带 uuid:/bid: 前缀，两类永不串。
    static func instanceKey(for app: LCAppModel) -> String {
        if let uuid = app.appInfo.dataUUID, !uuid.isEmpty {
            return "uuid:" + uuid
        }
        return "bid:" + (app.appInfo.bundleIdentifier() ?? "") + "#" + (app.appInfo.displayName() ?? "")
    }

    /// 备份文件夹名里的实例后缀“（xxxxxxxx）”：backupFolderName 规则 3
    /// 拼的是 dataUUID 前 8 位（无 dataUUID 时退到容器文件夹名前 8 位）。
    /// 文件夹名形如“muse（a1b2c3d4）”时返回 a1b2c3d4，没有后缀返回 nil。
    static func czfInstanceSuffix(fromFolderName name: String) -> String? {
        guard name.hasSuffix("）"),
              let openRange = name.range(of: "（", options: .backwards) else { return nil }
        let suffix = String(name[openRange.upperBound..<name.index(before: name.endIndex)])
        return suffix.isEmpty ? nil : suffix
    }

    /// 去掉文件夹名尾巴的实例后缀“（xxxxxxxx）”，剩显示名本身。
    /// 恢复缺失实例时预设自定义名用：传“muse8（a1b2c3d4）”会把
    /// 实例建歪成带后缀的名字，须先剥掉。
    static func czfStripInstanceSuffix(from name: String) -> String {
        guard name.hasSuffix("）"),
              let openRange = name.range(of: "（", options: .backwards) else { return name }
        return String(name[..<openRange.lowerBound])
    }

    /// 定时备份旧存 bid 升实例键：老版本存的是 bid，新键是
    /// 实例键；直接比对会全丢（定时备份悄悄备 0 个）。已是
    /// 实例键的原样留；是 bid 的展开成该 bid 全部现实例
    /// （老语义就是“这个 App 全选”，展开后行为不变）；
    /// 两头都对不上的（已删 App）丢掉。只做内存换算，不写
    /// 回（下次用户保存定时设置时自然落成新格式）。
    static func migratedScheduleIDs(from stored: [String], apps: [LCAppModel]) -> Set<String> {
        var out = Set<String>()
        let keys = apps.map { Self.instanceKey(for: $0) }
        for id in stored {
            if keys.contains(id) {
                out.insert(id)
            } else {
                for app in apps where (app.appInfo.bundleIdentifier() ?? "") == id {
                    out.insert(Self.instanceKey(for: app))
                }
            }
        }
        return out
    }

    func loadScheduleSettings() {
        let defaults = UserDefaults.standard
        scheduleEnabled = defaults.bool(forKey: "LCScheduleBackupEnabled")
        scheduleHour = defaults.integer(forKey: "LCScheduleBackupHour")
        scheduleMinute = defaults.integer(forKey: "LCScheduleBackupMinute")
        if let ids = defaults.stringArray(forKey: "LCScheduleBackupAppIDs") {
            scheduleSelectedIDs = Self.migratedScheduleIDs(from: ids, apps: sharedModel.apps + sharedModel.hiddenApps)
        }
        scheduleKeychainOnly = defaults.bool(forKey: "LCScheduleBackupKeychainOnly")
        // 默认 3:00
        if defaults.object(forKey: "LCScheduleBackupHour") == nil {
            scheduleHour = 3
            scheduleMinute = 0
            // 3.8.355：默认时间写回 UserDefaults——之前只改内存
            // 不落盘；用户开页点“保存”前若已开着定时备份，
            // runScheduledBackupIfDue 读到的是缺键的 0:00，
            // 当天任何时间都算“已到设定时间”，一开主界面就
            // 立刻静默备一次（用户原话“没设时间会立刻跑”）。
            // 现在缺键就地写回 3:00，静默判断与界面显示一致。
            defaults.set(scheduleHour, forKey: "LCScheduleBackupHour")
            defaults.set(scheduleMinute, forKey: "LCScheduleBackupMinute")
        }
    }
    
    func saveScheduleSettings() {
        let defaults = UserDefaults.standard
        defaults.set(scheduleEnabled, forKey: "LCScheduleBackupEnabled")
        defaults.set(scheduleHour, forKey: "LCScheduleBackupHour")
        defaults.set(scheduleMinute, forKey: "LCScheduleBackupMinute")
        defaults.set(Array(scheduleSelectedIDs), forKey: "LCScheduleBackupAppIDs")
        defaults.set(scheduleKeychainOnly, forKey: "LCScheduleBackupKeychainOnly")
        defaults.synchronize()
    }
    
    func saveCacheScheduleSettings() {
        let defaults = UserDefaults.standard
        defaults.set(cacheScheduleEnabled, forKey: "LCScheduleCacheEnabled")
        defaults.set(cacheScheduleHour, forKey: "LCScheduleCacheHour")
        defaults.set(cacheScheduleMinute, forKey: "LCScheduleCacheMinute")
        defaults.synchronize()
    }
    
    func checkAndRunScheduledCache() async {
        await Self.runScheduledCacheIfDue()
    }

    /// 定时清理缓存的静默核心（静态：打开 LiveContainer 主界面
    /// 时也要能触发，不再只等数据管理页打开——原触发点是审计
    /// 查出的缺陷）。判断口径与原实例版一致：启用 + 今天没清
    /// 过 + 已到设定时间 → 清一遍图标缓存并记日期
    static func runScheduledCacheIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "LCScheduleCacheEnabled") else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let today = formatter.string(from: Date())
        if defaults.string(forKey: "LCScheduleCacheLastDate") == today { return }
        // 3.8.355：与定时备份同款缺键兜底——没设过时间按默认
        // 3:00 算，不按 0:00，否则开主界面当天立刻清一次。
        let hour = defaults.object(forKey: "LCScheduleCacheHour") == nil ? 3 : defaults.integer(forKey: "LCScheduleCacheHour")
        let minute = defaults.object(forKey: "LCScheduleCacheMinute") == nil ? 0 : defaults.integer(forKey: "LCScheduleCacheMinute")
        let now = Date()
        let cal = Calendar.current
        if cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now) < hour * 60 + minute { return }
        // 隐藏 App 也清：原来只扫 apps，隐藏 App 的图标缓存
        // 永远不清，手动清理与定时清理都漏。
        // 冷启动空跑不记日期：冷启动扫描还没完成时 model.apps
        // 是空的，循环一次没清也照常记了今天，当天就再也不会
        // 清（定时备份同款是选空直接 return 不记日期；这里原来
        // 无条件记）。零 App 的用户每次打开都重查一次，无害。
        let appsToClear = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        guard !appsToClear.isEmpty else { return }
        for app in appsToClear {
            app.appInfo.clearIconCache()
        }
        defaults.set(today, forKey: "LCScheduleCacheLastDate")
    }

    func checkAndRunScheduledBackup() async {
        await Self.runScheduledBackupIfDue()
    }

    /// 定时备份在途守卫：LCTabView 冷启动时 onAppear 与 scenePhase
    /// .active 各触发一次、数据管理页 onAppear 是第三路；三路几乎
    /// 同时进时日期只在备完后才记，三路都会通过日期检查、同时备
    /// 同一批 App 写同一个备份文件夹（两份备份互相覆盖、文件写一半
    /// 被另一份顶掉）。先到的跑，后到的直接返回。
    private static let scheduledBackupLock = NSLock()
    private static var scheduledBackupRunning = false

    /// 定时备份的静默核心（静态：同上，主界面打开即查）。判断
    /// 口径：启用 + 选了 App + 今天没备过 + 已到设定时间 →
    /// 按设定范围（完整/登录态）在后台静默备完才记日期，全
    /// 失败不记、等下次打开重试。原来走 backupApps 会弹"备
    /// 份完成"窗，定时触发不弹窗更合适
    static func runScheduledBackupIfDue() async {
        scheduledBackupLock.lock()
        guard !scheduledBackupRunning else { scheduledBackupLock.unlock(); return }
        scheduledBackupRunning = true
        scheduledBackupLock.unlock()
        defer {
            scheduledBackupLock.lock()
            scheduledBackupRunning = false
            scheduledBackupLock.unlock()
        }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "LCScheduleBackupEnabled") else { return }
        guard let ids = defaults.stringArray(forKey: "LCScheduleBackupAppIDs"), !ids.isEmpty else { return }
        // 3.8.355：没设过时间时按默认 3:00 算，不按 0:00——
        // integer 缺键回 0，0:00 意味着“任何时间都已到”，
        // 定时备份会在开主界面当天立刻跑一次。loadScheduleSettings
        // 已补写回，但旧机/旧档可能仍缺键，这里再兜一道。
        let hour = defaults.object(forKey: "LCScheduleBackupHour") == nil ? 3 : defaults.integer(forKey: "LCScheduleBackupHour")
        let minute = defaults.object(forKey: "LCScheduleBackupMinute") == nil ? 0 : defaults.integer(forKey: "LCScheduleBackupMinute")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let today = dateFormatter.string(from: Date())
        if defaults.string(forKey: "LCScheduleBackupLastDate") == today { return }
        let calendar = Calendar.current
        let now = Date()
        if calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now) < hour * 60 + minute { return }
        let loginOnly = defaults.bool(forKey: "LCScheduleBackupKeychainOnly")
        let model = DataManager.shared.model
        let migrated = Self.migratedScheduleIDs(from: ids, apps: model.apps + model.hiddenApps)
        let selected = (model.apps + model.hiddenApps).filter {
            migrated.contains(Self.instanceKey(for: $0))
        }
        guard !selected.isEmpty else { return }
        // 3.8.374：定时备份同样先刷快照，别读旧 dump
        for app in selected {
            await Self.refreshKeychainSnapshot(for: app)
        }
        let (didBackup, hadFailure): (Bool, Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var backedUpFolderNames: [String] = []
                // 3.8.283 跳过已有完整备份的登录态档：跳过也要记数，
                // 全跳过且无失败时当天同样算结算（原来只看有没有备
                // 上，永不结算，每次进页都重跑、还关客 App 窗口）。
                var skippedFullCount = 0
                // 3.8.306：定时备份失败别静默——原来失败用 try?
                // 吞掉，整批全失败也不留痕、第二天照常重试，
                // 用户根本不知道没备上。失败的 App 记下来，
                // 写进 LCScheduleBackupLastFailure，设置页定时
                // 备份区直接显示出来。
                var failedNames: [String] = []
                // B-2：单 App 里个别文件拷失败不抛错、也算“成功”，
                // 原来只取 folderName、失败数直接丢了；按 App 记
                // 下来，和整 App 失败一起写进上次失败记录。
                var copyFailedNames: [String] = []
                if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let backupRoot = docs.appendingPathComponent("Backups")
                    try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    for app in selected {
                        // 3.8.283：定时登录态不覆盖完整备份——完整备份里
                        // 已有登录态，登录态档盖上去只丢数据不赚东西；
                        // 跳过（不记成功），想更新它就手动备一次
                        //（弹窗会警告）。只查已有完整备份的 App，
                        // 没备份的照常备。
                        if loginOnly && Self.hasExistingFullBackup(for: app, backupRoot: backupRoot, fm: fm) {
                            skippedFullCount += 1
                            continue
                        }
                        // v216：同步按返回的实际文件夹名（多开后缀名
                        // ≠ 显示名），不按显示名猜
                        do {
                            let one = try Self.backupOneAppSync(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly)
                            backedUpFolderNames.append(one.folderName)
                            if one.loginFailed > 0 {
                                copyFailedNames.append("\(app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown")（\(one.loginFailed) 个文件拷贝失败）")
                            }
                        } catch {
                            failedNames.append(app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown")
                        }
                    }
                    if !backedUpFolderNames.isEmpty {
                        Self.syncBackupsToExternalFolder(appNames: backedUpFolderNames, backupRoot: backupRoot)
                        Self.writeCZFSettingsBackupDebounced()
                    }
                    if !failedNames.isEmpty || !copyFailedNames.isEmpty {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "MM月d日 HH:mm"
                        let when = fmt.string(from: Date())
                        var failureParts: [String] = []
                        if !failedNames.isEmpty {
                            let names = failedNames.prefix(3).joined(separator: "、") + (failedNames.count > 3 ? "等 \(failedNames.count) 个" : "")
                            failureParts.append("\(names)备份失败")
                        }
                        if !copyFailedNames.isEmpty {
                            let names = copyFailedNames.prefix(3).joined(separator: "、") + (copyFailedNames.count > 3 ? "等 \(copyFailedNames.count) 个" : "")
                            failureParts.append("\(names)有文件拷贝失败")
                        }
                        UserDefaults.standard.set("\(when)：\(failureParts.joined(separator: "；"))", forKey: "LCScheduleBackupLastFailure")
                        UserDefaults.standard.synchronize()
                    }
                }
                // 全跳过且无失败时当天同样算结算（见上面 skippedFullCount），
                // 真失败时不结算，第二天照常重试。
                continuation.resume(returning: (!backedUpFolderNames.isEmpty || (failedNames.isEmpty && skippedFullCount == selected.count), !failedNames.isEmpty || !copyFailedNames.isEmpty))
            }
        }
        if didBackup {
            defaults.set(today, forKey: "LCScheduleBackupLastDate")
            // 3.8.487：上次失败记录要清——原来只写不删，一次失败后
            // 设置页的红字警告永远挂着，哪怕之后天天备成功。零失败
            // 才清；本轮有失败时上面刚写了新记录，别动它。
            if !hadFailure {
                defaults.removeObject(forKey: "LCScheduleBackupLastFailure")
            }
            defaults.synchronize()
        }
    }
    
    func clearIconCache() async {
        // 隐藏 App 也清（同 runScheduledCacheIfDue 的漏项）。
        for app in sharedModel.apps + sharedModel.hiddenApps {
            app.appInfo.clearIconCache()
        }
    }
    
    // 直接用 rootViewController 弹出文件选择器（避免 SwiftUI 套娃 sheet 冲突）。
    // 不在这里弹“成功”：文件还没拷、用户还没选位置就报成功是假成功，
    // 且弹窗与 picker 同一个 runloop 抢呈现位、弹窗会把 picker 静默吞掉
    // （用户点“好”后根本没出现选位置的界面，什么都没导出）；成功只在
    // delegate 的 didPickDocumentsAt 里报（那时系统已把文件拷到用户选的位置）。
    func presentExportPicker(for url: URL) {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        // 找到最顶层的 VC
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              var topVC = window.rootViewController else { return }
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        let coordinator = CZFExportPickerCoordinator()
        coordinator.onPick = { dest in
            let destName = dest.deletingLastPathComponent().lastPathComponent
            self.successInfo = "已导出到「\(destName.isEmpty ? dest.lastPathComponent : destName)」"
            self.successShow = true
        }
        picker.delegate = coordinator
        exportPickerCoordinator = coordinator
        topVC.present(picker, animated: true)
    }

    func presentExportPickerForAll() {
        let urls = mergedBackupFolders()
        guard !urls.isEmpty else { return }
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              var topVC = window.rootViewController else { return }
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        // 同 presentExportPicker：成功只在 delegate 回调里报，不提前弹。
        let coordinator = CZFExportPickerCoordinator()
        coordinator.onPick = { dest in
            let destName = dest.deletingLastPathComponent().lastPathComponent
            self.successInfo = "已导出到「\(destName.isEmpty ? dest.lastPathComponent : destName)」"
            self.successShow = true
        }
        picker.delegate = coordinator
        exportPickerCoordinator = coordinator
        topVC.present(picker, animated: true)
    }

}

// 备份导出 picker 的 delegate：UIDocumentPickerViewController 的
// delegate 是 weak，内联创建会被当场释放、回调永不触发（441 教训）；
// 由 LCDataManagementView 用 @State 强持有。成功只在
// documentPicker(_:didPickDocumentsAt:) 里报——forExporting(asCopy:)
// 的回调在系统把文件拷到用户选的位置之后才触发；取消静默，不报成功。
final class CZFExportPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    var onPick: ((URL) -> Void)?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            onPick?(url)
        }
    }

    // 用户取消导出：不报成功，静默。
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
}

// 文件夹选择器（选 iCloud Drive 里的文件夹，授权后用 bookmark 长期访问）
struct FolderPickerView: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
    }
}

// MARK: - 备份/恢复范围选择独立页（3.8.404）

/// 备份/恢复范围选择独立成页。替代 342–403 的六版弹窗与
/// 398/401/402 的页内选框：选页本身就是普通内容，不走
/// present、不占呈现位，设置页、恢复页、选页、多选页、预览页、
/// 坞直进七路入口全推入这一页。
/// - 直进（isDirectEntry = true）：选完不自己 dismiss，靠
///   czfScopeChosen → 直进收尾机制 0.3 秒后关壳。
/// - 推入（isDirectEntry = false）：选完 dismiss() pop 回去；
///   取消恒 dismiss()。
struct CZFScopeChoiceView: View {
    let isBackup: Bool
    let apps: [LCAppModel]
    let restoreAll: Bool
    let restoreURL: URL?
    let restoreFolders: [URL]
    let isDirectEntry: Bool
    let onChoose: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    private var scopeHint: String {
        if isBackup {
            return LCDataManagementView.lastBackupScopeHint()
                + LCDataManagementView.existingBackupSummaryText(for: apps)
                + LCDataManagementView.existingFullBackupWarningText(for: apps)
                + LCDataManagementView.keychainSnapshotWarningText(for: apps)
                + "只备份登录态：体积小、备得快，重装后恢复即可免登录，大多数 App 选这个就够。"
        } else {
            return LCDataManagementView.lastRestoreScopeHint()
                + LCDataManagementView.restoreTargetText(all: restoreAll, url: restoreURL, folders: restoreFolders)
                + "恢复会用备份里的登录态覆盖当前登录态。\n"
                + "只恢复登录态：只写回登录，现有数据不动。"
        }
    }

    private var lastLoginOnly: Bool? {
        isBackup ? LCDataManagementView.lastBackupLoginOnly : LCDataManagementView.lastRestoreLoginOnly
    }

    private func choose(loginOnly: Bool) {
        onChoose(loginOnly)
        if !isDirectEntry {
            dismiss()
        }
    }

    var body: some View {
        List {
            Section {
                Text(scopeHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                if isBackup {
                    if lastLoginOnly == false {
                        Button("完整备份（数据 + 登录态）") { choose(loginOnly: false) }
                        Button("只备份登录态") { choose(loginOnly: true) }
                    } else {
                        Button("只备份登录态") { choose(loginOnly: true) }
                        Button("完整备份（数据 + 登录态）") { choose(loginOnly: false) }
                    }
                } else {
                    if lastLoginOnly == false {
                        Button("恢复全部数据（会覆盖当前数据）", role: .destructive) { choose(loginOnly: false) }
                        Button("只恢复登录态") { choose(loginOnly: true) }
                    } else {
                        Button("只恢复登录态") { choose(loginOnly: true) }
                        Button("恢复全部数据（会覆盖当前数据）", role: .destructive) { choose(loginOnly: false) }
                    }
                }
                Button("取消", role: .cancel) { dismiss() }
            } header: {
                Text(isBackup ? "备份范围" : "恢复范围")
            }
        }
        .navigationTitle(isBackup ? "备份范围" : "恢复范围")
        .navigationBarTitleDisplayMode(.inline)
    }
}
