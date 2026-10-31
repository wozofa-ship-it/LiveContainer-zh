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

struct LCDataManagementView : View {
    @State var folderPaths : [LCFolderPath]
    @State var filzaInstalled = false
    @State var appeared = false
    
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
    @State private var showBackupSelect = false
    @State private var backupSelectedIDs = Set<String>()
    @State private var showBackupScopeDialog = false
    @State private var showRestoreScopeDialog = false
    @State private var pendingRestoreURL: URL? = nil
    @State private var pendingRestoreAll = false
    // 选择性多选恢复：多选 sheet 里勾中的文件夹 URL 原值
    // （与 mergedBackupFolders() 返回的同一批 URL 比对；
    // @State 不落盘，不新开 UserDefaults 键；勾选态跨次
    // 打开保留，与备份侧 backupSelectedIDs 同款）
    @State private var showRestoreMultiSelect = false
    @State private var restoreSelectedFolderURLs = Set<URL>()
    @State private var restoreMultiSelectFolders: [URL] = []
    @State private var pendingRestoreFolders: [URL] = []
    @State private var pendingBackupApps: [LCAppModel] = []
    @State private var scheduleKeychainOnly = false
    @State private var showRestoreSelect = false
    // 恢复选择 sheet 内的操作反馈（删备份等）：必须挂在 sheet
    // 自己身上——v143 试过先关 sheet 再弹外层提示，还是有盖住/
    // 卡住的可能；sheet 内的事就在 sheet 内交代，不跨层弹提示
    @State private var restoreSheetNotice: String? = nil
    @State private var backupFolderList: [URL] = []
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
    @State private var exportBackupURL: URL? = nil
    @State private var showScheduleCache = false
    @State private var cacheScheduleEnabled = false
    @State private var cacheScheduleHour = 3
    @State private var cacheScheduleMinute = 0
    @State private var showFolderPicker = false
    @State private var externalFolderName: String? = nil
    // 注：恢复合一后不再有“选哪个文件夹”dialog，restoreFromExternal
    // 与 backupFolders() 无参版随之退役（sheet 直接调 fromExternal 版）
    @State private var showDeleteAllBackupsConfirm = false
    @State private var showDeleteBackupConfirm = false
    @State private var pendingDeleteBackupURL: URL? = nil
    
    @EnvironmentObject private var sharedModel : SharedModel
    
    init() {
        _folderPaths = State(initialValue: [
            LCFolderPath(path: LCPath.docPath, desc: "Private Container"),
            LCFolderPath(path: LCPath.lcGroupDocPath, desc: "App Group Container"),
            LCFolderPath(path: Bundle.main.bundleURL, desc: "LiveContainer Bundle"),
        ])
    }
    
    var body: some View {

        Form {
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
                Text("把节点列表、每个 App 的 VPN 标记、窗口位置、手势灵敏度等 CZF 设置，连同 App 排序、定时备份/定时清理设置、已添加源，一起打包成一个 JSON 文件（CZFSettingsBackup.json）。点「导出设置」直接存：本地文稿根目录一份，你在下面选的备份文件夹里自动也一份；每次备份 App 时那份也会自动刷新。换机或重装后导入即可恢复；导入后重启 LiveContainer 全部生效。")
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
                Button {
                    pendingBackupApps = sharedModel.apps + sharedModel.hiddenApps
                    showBackupScopeDialog = true
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "doc.on.doc", color: .blue)
                        Text("lc.settings.backupAll".loc)
                    }
                }
                Button {
                    showBackupSelect = true
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "checkmark.circle.fill", color: .green)
                        Text("lc.settings.backupSelected".loc)
                    }
                }
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
                Button {
                    showFolderPicker = true
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "icloud.fill", color: .blue)
                        Text("iCloud 备份文件夹")
                        Spacer()
                        Text(externalFolderName ?? "未选择")
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
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
        .navigationTitle("lc.settings.dataManagement".loc)
        .navigationBarTitleDisplayMode(.inline)
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
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView { url in
                saveExternalBackupFolder(url)
            }
        }
        .confirmationDialog("备份范围", isPresented: $showBackupScopeDialog, titleVisibility: .visible) {
            Button("只备份登录态") {
                let apps = pendingBackupApps
                Task { await backupApps(apps, loginOnly: true) }
            }
            Button("完整备份（数据 + 登录态）") {
                let apps = pendingBackupApps
                Task { await backupApps(apps, loginOnly: false) }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("只备份登录态：体积小、备得快，重装后恢复即可免登录，大多数 App 选这个就够。")
        }
        // 恢复范围弹窗优化：说明不再把两个选项的解释挤成一整段
        // （扫一眼分不清）；安全的选项只留一句说明，危险的选项
        // 标红、后果直接写进按钮上，点之前就看得见
        .confirmationDialog("恢复范围", isPresented: $showRestoreScopeDialog, titleVisibility: .visible) {
            Button("只恢复登录态") {
                startPendingRestore(loginOnly: true)
            }
            Button("恢复全部数据（会覆盖当前数据）", role: .destructive) {
                startPendingRestore(loginOnly: false)
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("只恢复登录态：只写回登录，现有数据不动。")
        }
        .sheet(isPresented: $showBackupSelect) {
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
                .navigationTitle("lc.settings.backupSelected".loc)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("lc.settings.backup".loc) {
                            pendingBackupApps = (sharedModel.apps + sharedModel.hiddenApps).filter {
                                backupSelectedIDs.contains(Self.instanceKey(for: $0))
                            }
                            showBackupSelect = false
                            showBackupScopeDialog = true
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showRestoreSelect) {
            NavigationView {
                // 恢复合一：本地 + iCloud 同屏两个区，不再先弹
                // “选哪个文件夹”再进单源列表；iCloud 未设时
                // 区里直接给选文件夹入口
                List {
                    Section("本地备份") {
                        if backupFolderList.isEmpty {
                            Text("暂无备份")
                                .foregroundColor(.secondary)
                        }
                        ForEach(backupFolderList, id: \.self) { folderURL in
                            restoreRow(for: folderURL)
                        }
                    }
                    Section("iCloud 备份") {
                        if Self.externalBackupFolderURL() != nil {
                            if externalBackupFolderList.isEmpty {
                                Text("暂无备份")
                                    .foregroundColor(.secondary)
                            }
                            ForEach(externalBackupFolderList, id: \.self) { folderURL in
                                restoreRow(for: folderURL)
                            }
                        } else {
                            Button("选择 iCloud 备份文件夹") {
                                showRestoreSheetFolderPicker = true
                            }
                        }
                    }
                }
                .navigationTitle("lc.settings.restoreBackup".loc)
                .onAppear {
                    backupFolderList = backupFolders(fromExternal: false)
                    externalBackupFolderList = Self.externalBackupFolderURL() != nil ? backupFolders(fromExternal: true) : []
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
                            showRestoreSelect = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Menu {
                            Button {
                                showRestoreSelect = false
                                pendingRestoreURL = nil
                                pendingRestoreAll = true
                                showRestoreScopeDialog = true
                            } label: {
                                Label("一键恢复全部", systemImage: "arrow.clockwise.circle")
                            }
                            Button {
                                showRestoreMultiSelect = true
                            } label: {
                                Label("恢复已选…", systemImage: "checkmark.circle")
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
                        if let url = pendingDeleteBackupURL {
                            deleteBackup(at: url)
                        }
                        pendingDeleteBackupURL = nil
                    }
                    Button("lc.common.cancel".loc, role: .cancel) {
                        pendingDeleteBackupURL = nil
                    }
                } message: {
                    Text("将删除备份「\(pendingDeleteBackupURL?.lastPathComponent ?? "")」，此操作不可恢复")
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
                .sheet(isPresented: $showBackupPreview) {
                    NavigationView {
                        List {
                            ForEach(previewItems, id: \.folderName) { item in
                                previewRow(for: item)
                            }
                        }
                        .navigationTitle("备份清单预览")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("取消") { showBackupPreview = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("恢复") {
                                    showBackupPreview = false
                                    if let url = previewFolderURL {
                                        pendingRestoreURL = url
                                        pendingRestoreAll = false
                                        showRestoreScopeDialog = true
                                        showRestoreSelect = false
                                    }
                                }
                                .disabled(previewFolderURL == nil)
                            }
                        }
                    }
                }
                // 选择性多选恢复：恢复 sheet 内再叠一层 sheet
                // （与文件夹 picker、清单预览同款嵌套，不关恢复
                // sheet；“恢复”走 pendingRestoreFolders + scope
                // 弹窗路：关多选、关恢复 sheet、弹 scope 弹窗，
                // 与清单预览的“恢复”同款；确认步骤就是 scope
                // 弹窗本身（一键恢复全部同样只走 scope 弹窗，
                // 不另做多文件夹预览，不静默覆盖）
                .sheet(isPresented: $showRestoreMultiSelect) {
                    NavigationView {
                        List {
                            if restoreMultiSelectFolders.isEmpty {
                                Text("暂无备份")
                                    .foregroundColor(.secondary)
                            }
                            ForEach(restoreMultiSelectFolders, id: \.self) { folderURL in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(folderURL.lastPathComponent)
                                            .font(.headline)
                                        Text("\(backupDateText(for: folderURL)) · \(backupSizeLabel(for: folderURL))\(Self.backupScopeBadge(folderURL))")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: restoreSelectedFolderURLs.contains(folderURL) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(.blue)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if restoreSelectedFolderURLs.contains(folderURL) {
                                        restoreSelectedFolderURLs.remove(folderURL)
                                    } else {
                                        restoreSelectedFolderURLs.insert(folderURL)
                                    }
                                }
                            }
                        }
                        .navigationTitle("恢复已选备份")
                        .navigationBarTitleDisplayMode(.inline)
                        .onAppear {
                            restoreMultiSelectFolders = mergedBackupFolders()
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("lc.common.cancel".loc) { showRestoreMultiSelect = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("恢复") {
                                    pendingRestoreFolders = restoreMultiSelectFolders.filter { restoreSelectedFolderURLs.contains($0) }
                                    pendingRestoreAll = false
                                    pendingRestoreURL = nil
                                    showRestoreMultiSelect = false
                                    showRestoreSelect = false
                                    showRestoreScopeDialog = true
                                }
                                .disabled(restoreMultiSelectFolders.filter { restoreSelectedFolderURLs.contains($0) }.isEmpty)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showScheduleBackup) {
            NavigationView {
                Form {
                    Section {
                        Toggle("启用定时备份", isOn: $scheduleEnabled)
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
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "LCExternalBackupFolderBookmark")
            Self.cachedExternalFolderURL = nil
            externalFolderName = url.lastPathComponent
            // 立即把已有本地备份同步过去（后台线程）
            Task.detached {
                Self.syncAllLocalBackupsToExternalFolder()
            }
            successInfo = "备份文件夹已设置：\(url.lastPathComponent)\n之后的备份会同步到该文件夹，恢复时也会从该文件夹读取"
            successShow = true
        } else {
            errorInfo = "保存文件夹授权失败，请重新选择"
            errorShow = true
        }
    }

    static func externalBackupFolderURL() -> URL? {
        if let cached = Self.cachedExternalFolderURL {
            return cached
        }
        guard let data = UserDefaults.standard.data(forKey: "LCExternalBackupFolderBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        // 本次运行内保持访问权限，供列表/恢复/删除直接使用
        _ = url.startAccessingSecurityScopedResource()
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
    ]

    // 注意：@discardableResult 必须紧贴 func 写，中间不能插
    // static let，否则编译报 attribute 不能用在这条声明上，
    // 269b523 那次构建 #233 就是这么挂的。
    @discardableResult
    static func writeCZFSettingsBackup() -> (local: URL?, externalFolderName: String?) {
        let skip: Set<String> = ["CZFUpdatableAppCount", "CZFLastSourceAutoRefresh"]
        var payload: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("CZF") && !skip.contains(key) {
            payload[key] = value
        }
        // App Group 里的 CZF 键也要：最小化省电三个开关存在
        // App Group 里，只扫标准库会漏掉它们；已在 payload
        // 里的（标准库同名）不动，标准库优先。
        for (key, value) in LCUtils.appGroupUserDefault.dictionaryRepresentation() where key.hasPrefix("CZF") && !skip.contains(key) && payload[key] == nil {
            payload[key] = value
        }
        // 排序在 App Group 里、定时备份/清理在标准库里但前缀是 LC，
        // 原来只拷 CZF 的逻辑会漏掉这两类，这里显式补上。
        let standard = UserDefaults.standard
        for key in settingsBackupExtraStandardKeys {
            if let value = standard.object(forKey: key) {
                payload[key] = value
            }
        }
        let appGroup = LCUtils.appGroupUserDefault
        for key in settingsBackupAppGroupKeys {
            if let value = appGroup.object(forKey: key) {
                payload[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return (nil, nil)
        }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return (nil, nil) }
        let localURL = docs.appendingPathComponent("CZFSettingsBackup.json")
        var writtenLocal: URL? = nil
        do {
            try data.write(to: localURL, options: .atomic)
            writtenLocal = localURL
        } catch { }
        var extName: String? = nil
        if let extURL = Self.externalBackupFolderURL() {
            let dest = extURL.appendingPathComponent("CZFSettingsBackup.json")
            do {
                try data.write(to: dest, options: .atomic)
                extName = extURL.lastPathComponent
            } catch { }
        }
        return (writtenLocal, extName)
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
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
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
        let (local, extName) = Self.writeCZFSettingsBackup()
        if local != nil {
            if let extName {
                settingsTransferMessage = "设置备份已存好（CZFSettingsBackup.json）：本地文稿根目录一份，你选的备份文件夹「\(extName)」里也一份"
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
    /// 设备键就算进了文件也不会被导入）。返回写回项数。
    @discardableResult
    static func applySettingsDictionary(_ dict: [String: Any]) -> Int {
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
        return count
    }

    /// 恢复时找设置备份并写回（只给完整恢复用，登录态恢复不
    /// 碰全局设置）：跟恢复源同侧优先（iCloud 恢复用外部根
    /// 的那份，本地恢复用文稿根的那份），首选没有再试另一侧；
    /// 两边都没有返回 found=false。返回（写回项数，找到没有）。
    static func restoreCZFSettings(for backupURL: URL) async -> (imported: Int, found: Bool) {
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
            return (Self.applySettingsDictionary(dict), true)
        }
        return (0, false)
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
        let count = Self.applySettingsDictionary(dict)
        settingsTransferMessage = "已导入 \(count) 项设置，重启 LiveContainer 后全部生效"
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
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        for case let fileURL as URL in enumerator {
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

    @ViewBuilder
    func restoreRow(for folderURL: URL) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(folderURL.lastPathComponent)
                    .font(.headline)
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
                // 预览计算放 Task：原来点行同步算清单，登录档整树
                // 枚举在主线程堵几秒到几十秒、看门狗杀进程；
                // Task 挂起不堵主线程，算完再弹 sheet（终态与
                // 原来一致）。连点两行时只认最后一次（先算完的
                // 旧结果不覆盖新行），防异步时序错位。
                Task {
                    let items = await Self.previewItems(for: folderURL)
                    if previewFolderURL == folderURL {
                        previewItems = items
                        showBackupPreview = true
                    }
                }
            }
            Spacer()
            Button {
                showRestoreSelect = false
                pendingRestoreURL = folderURL
                pendingRestoreAll = false
                showRestoreScopeDialog = true
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                    Text("恢复")
                }
                .foregroundColor(.blue)
            }
            .buttonStyle(.bordered)
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
        }
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
        }
    }

    func deleteBackup(at backupURL: URL) {
        do {
            try FileManager.default.removeItem(at: backupURL)
            backupFolderList.removeAll { $0 == backupURL }
            externalBackupFolderList.removeAll { $0 == backupURL }
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
        for url in backupFolderList + externalBackupFolderList {
            if (try? fm.removeItem(at: url)) != nil {
                deleted += 1
            }
        }
        backupFolderList = backupFolders(fromExternal: false)
        externalBackupFolderList = Self.externalBackupFolderURL() != nil ? backupFolders(fromExternal: true) : []
        restoreSheetNotice = "已删除 \(deleted) 个备份"
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

    func backupAllApps() async {
        let allApps = sharedModel.apps + sharedModel.hiddenApps
        await backupApps(allApps)
    }

    /// 把一个 App 的整套数据备份到 Backups/<显示名>（先写
    /// 临时目录、写完换名覆盖，防丢）：manifest + .app + 各
    /// 数据容器 + 组容器 + 钥匙串快照。backupApps 的批量循环
    /// 和覆盖安装前的自动备份都走这里。同步执行，调用方自己
    /// 挪到后台队列
    @discardableResult
    static func backupOneAppSync(_ app: LCAppModel, backupRoot: URL, fm: FileManager, loginOnly: Bool = false) throws -> (keychainCount: Int, keychainHasSnapshot: Bool, bridgeStatus: String?, loginFileCount: Int, loginBreakdown: [String: Int], loginSkipped: Int, keychainSnapshotDate: Date?, loginSkippedPaths: [String], folderName: String, containerCount: Int) {
        let appName = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
        // v216：同款多开各写各的文件夹（见 backupFolderName：
        // 同实例沿用旧名、新实例加实例后缀；老文件夹不改名）。
        // appName 仍是显示名（报告文案用），落盘用 folderName。
        let folderName = Self.backupFolderName(for: app, backupRoot: backupRoot, fm: fm)
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
        if !loginOnly {
        // 保存 .app bundle 供恢复时参考（iOS 沙盒不允许调用 zip，暂不打包 IPA）
        if let bundlePath = app.appInfo.bundlePath() {
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let destAppURL = appBackupURL.appendingPathComponent(bundleURL.lastPathComponent)
            try? fm.copyItem(at: bundleURL, to: destAppURL)
        }
        for container in app.uiContainers {
            let srcURL = container.containerURL
            let destURL = appBackupURL.appendingPathComponent(srcURL.lastPathComponent)
            // v216：成功拷回的数据容器数（健康分与预览共用；
            // AppGroup 组容器不计在内）
            if fm.fileExists(atPath: srcURL.path), (try? fm.copyItem(at: srcURL, to: destURL)) != nil {
                containerCount += 1
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
                    try? fm.copyItem(at: src, to: groupRoot.appendingPathComponent(groupID))
                }
            }
        }
        } else {
            // 登录态档：容器整棵树里 ≤5MB 的小文件（Library、
            // Documents、LCAppGroup 等全扫；单容器封顶 300MB），
            // 组容器同规则；钥匙串快照在下面照旧备
            for container in app.uiContainers {
                let srcURL = container.containerURL
                if fm.fileExists(atPath: srcURL.path) {
                    let destURL = appBackupURL.appendingPathComponent(srcURL.lastPathComponent)
                    let r = Self.copyLoginStateFiles(from: srcURL, to: destURL, fm: fm)
                    loginFileCount += r.count
                    loginSkipped += r.skipped
                    if loginSkippedPaths.count < 50 { loginSkippedPaths.append(contentsOf: r.skippedPaths.prefix(50 - loginSkippedPaths.count)) }
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
                try? data.write(to: keychainRoot.appendingPathComponent(container.folderName + ".plist"))
                keychainCount += items.count
            }
        }
        // 全部写完才换上：删掉旧备份、临时文件夹改名到位。
        // 中途任何一步抛错都走不到这里，旧备份原样保留
        if fm.fileExists(atPath: finalURL.path) {
            try fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: appBackupURL, to: finalURL)
        return (keychainCount, keychainHasSnapshot, bridgeStatus, loginFileCount, loginBreakdown, loginSkipped, newestDumpDate, loginSkippedPaths, folderName, containerCount)
    }

    /// 覆盖安装前的自动备份入口：把被覆盖 App 的整套数据备
    /// 一份到 Backups/<文件夹名>（与手动备份同一位置、同实
    /// 例新的盖旧的；多开时文件夹名带实例后缀，见
    /// backupFolderName），新版装上有问题时能在数据管理里
    /// 恢复回滚。备份失败不挡安装，静默跳过
    static func autoBackupBeforeOverwrite(_ app: LCAppModel) async {
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
    static func backupHealthLine(name: String, loginOnly: Bool, containerCount: Int, keychainCount: Int, keychainHasSnapshot: Bool, loginFileCount: Int) -> String {
        var parts: [String] = []
        if loginOnly {
            parts.append(loginFileCount > 0 ? "会话文件 ✅ \(loginFileCount) 个" : "会话文件 ❌ 0 个")
        } else {
            parts.append(containerCount > 0 ? "容器 ✅ \(containerCount) 个" : "容器 ❌ 缺数据容器")
        }
        if keychainCount > 0 {
            parts.append("钥匙串 ✅ \(keychainCount) 条")
        } else if keychainHasSnapshot {
            parts.append("钥匙串 ⚠️ 快照为空")
        } else {
            parts.append("钥匙串 ❌ 无快照")
        }
        return "\(name)：\(parts.joined(separator: " · "))"
    }

    func backupApps(_ apps: [LCAppModel], loginOnly: Bool = false) async {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            errorInfo = "lc.settings.backupFail".loc
            errorShow = true
            return
        }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        backupRestoreProgress = "正在备份（0/\(apps.count)）…"
        // 拷贝重活整体挪到后台队列：原来这段在打开页面触发定时备份时
        // 能把主线程堵死几分钟（整 App 容器逐个 copyItem，都是 GB 级），
        // 界面点不动也划不动。挪后台后备份照跑，界面不卡；结果回主线程
        // 再更新成功/失败提示。用 GCD+continuation 桥接，不挑并发模式。
        let (count, failure, keychainTotal, snapshotMissing, bridgeStatuses, loginFileTotal, loginBreakdownTotal, loginSkippedTotal, snapshotDates, failedNames, loginSkippedPathsTotal, healthLines): (Int, Error?, Int, Bool, [String], Int, [String: Int], Int, [String], [String], [String], [String]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                do {
                    try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    var count = 0
                    var backedUpFolderNames: [String] = []
                    var failedNames: [String] = []
                    // v216：每 App 健康行（成功才记，失败的走失败清单）
                    var healthLines: [String] = []
                    var keychainTotal = 0
                    var loginFileTotal = 0
                    var loginBreakdownTotal: [String: Int] = [:]
                    var loginSkippedTotal = 0
                    var loginSkippedPathsTotal: [String] = []
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
                        do {
                            let one = try Self.backupOneAppSync(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly)
                            keychainTotal += one.keychainCount
                            loginFileTotal += one.loginFileCount
                            for (k, v) in one.loginBreakdown { loginBreakdownTotal[k, default: 0] += v }
                            loginSkippedTotal += one.loginSkipped
                            if loginSkippedPathsTotal.count < 10 { loginSkippedPathsTotal.append(contentsOf: one.loginSkippedPaths.prefix(10 - loginSkippedPathsTotal.count)) }
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
                            healthLines.append(Self.backupHealthLine(name: name, loginOnly: loginOnly, containerCount: one.containerCount, keychainCount: one.keychainCount, keychainHasSnapshot: one.keychainHasSnapshot, loginFileCount: one.loginFileCount))
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
                    Self.writeCZFSettingsBackup()
                    continuation.resume(returning: (count, nil, keychainTotal, snapshotMissing, bridgeStatuses, loginFileTotal, loginBreakdownTotal, loginSkippedTotal, snapshotDates, failedNames, loginSkippedPathsTotal, healthLines))
                } catch {
                    continuation.resume(returning: (0, error, 0, false, [], 0, [:], 0, [], [], [], []))
                }
            }
        }
        backupRestoreProgress = nil
        if let failure {
            errorInfo = LCUtils.czfFriendlyError(failure)
            errorShow = true
        } else if count == 0, !failedNames.isEmpty {
            // 一个都没成：别报“成功 0 个”，直接报失败清单
            errorInfo = "备份失败，一个都没备份上：\n" + failedNames.joined(separator: "\n")
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
            // v216：备份健康分——每个成功 App 一行，缺哪项标 ❌
            //（弹窗是纯文本，不能着色；红字版在恢复前清单预览里）。
            // 失败的 App 已在上面失败清单里，这里只列成功的。
            if !healthLines.isEmpty {
                successInfo += "\n—— 备份健康（缺项标 ❌）——\n" + healthLines.joined(separator: "\n")
            }
            successInfo += "\n" + backupRoot.path
            successShow = true
        }
    }


    /// 恢复范围弹窗选完后分发：单个恢复走 pendingRestoreURL，
    /// 一键恢复全部走 pendingRestoreAll（同一个范围套全部），
    /// 多选恢复走 pendingRestoreFolders（只恢复勾中的文件夹）
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
                lines.append("设置：已恢复 \(s.imported) 项，重启 LiveContainer 后全部生效")
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
                lines.append("设置：已恢复 \(s.imported) 项，重启 LiveContainer 后全部生效")
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
                if app == nil {
                    app = allApps.first(where: {
                        ($0.appInfo.displayName() ?? "") == folderName ||
                        ($0.appInfo.bundleIdentifier() ?? "") == folderName
                    })
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
                        app = matches[0]
                        fallbackNote = "按 Bundle ID 兜底"
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
                            noDataApps.append("\(displayName)（备份里容器 \(outcome.containerFolderCount) 个，会话文件合并 \(outcome.mergedLoginFiles) 个，钥匙串快照 \(outcome.keychainFound) 条）")
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
            for item in missing {
                if presentResult {
                    backupRestoreProgress = "正在安装并恢复 \(item.name)（等安装完成）…"
                }
                guard let downloadURL = downloadURLForApp(bundleID: item.bundleID, name: item.name, in: sourceApps) else {
                    installNotFound.append(item.name)
                    continue
                }
                // 等安装前先快照已装集合：原来按 Bundle ID 或显示名
                // 首匹配，装 Muse5 时列表里已有的 Muse（同款同
                // Bundle ID）会先被认成“装好了”，Muse5 的数据就
                // 盖进 Muse。只等新出现（快照里没有）且显示名对
                // 上的那一个；显示名对不上宁可超时报安装失败，也
                // 不错位恢复。
                let beforeApps = Set((sharedModel.apps + sharedModel.hiddenApps).map { ObjectIdentifier($0) })
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": downloadURL])
                }
                // 装好后 App 会进 sharedModel 的列表；2 秒一查，最多等 10 分钟
                var installedApp: LCAppModel?
                for _ in 0..<300 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let currentApps = sharedModel.apps + sharedModel.hiddenApps
                    installedApp = currentApps.first(where: {
                        !beforeApps.contains(ObjectIdentifier($0)) &&
                        ($0.appInfo.displayName() ?? "") == item.name
                    })
                    if installedApp != nil { break }
                }
                guard let installedApp else {
                    installFailed.append(item.name)
                    continue
                }
                // 再缓 2 秒等安装收尾落稳，然后恢复这个 App 的数据
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    // v216：同主循环（iCloud 进度 + 排队提醒 + 无数据定位）
                    let outcome2 = try await Self.restoreOneApp(appFolder: item.folder, app: installedApp, loginOnly: loginOnly, downloadProgress: { downloaded, total in
                        DispatchQueue.main.async {
                            self.backupRestoreProgress = "正在从 iCloud 下载：已下 \(downloaded) / 共 \(total) 个…"
                        }
                    })
                    keychainFoundTotal += outcome2.keychainFound
                    keychainQueuedTotal += outcome2.keychainQueued
                    keychainImportedTotal += outcome2.keychainImported
                    keychainUnwritableTotal += outcome2.keychainUnwritable
                    if keychainStatusFirst == nil && outcome2.keychainStatus != errSecSuccess {
                        keychainStatusFirst = (item.name, outcome2.keychainStatus)
                    }
                    if outcome2.keychainQueued > 0 {
                        keychainQueuedApps.append(item.name)
                    }
                    if outcome2.ok {
                        installRestoredCount += 1
                        if await Self.backupVersionDiffers(appFolder: item.folder, app: installedApp) {
                            versionMismatchApps.append(item.name)
                        }
                    } else {
                        if loginOnly {
                            noDataApps.append(item.name)
                        } else {
                            noDataApps.append("\(item.name)（备份里容器 \(outcome2.containerFolderCount) 个）")
                        }
                        noDataFolders.append(NoDataFolderEntry(name: item.name, folder: item.folder))
                    }
                } catch {
                    restoreFailedApps.append("\(item.name)：\(LCUtils.czfFriendlyError(error))")
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
                    msg += "\n\n设置：已恢复 \(s.imported) 项，重启 LiveContainer 后全部生效"
                } else {
                    msg += "\n\n设置：未找到设置备份（CZFSettingsBackup.json），开关需手动重设或用设置页导入"
                }
            }
            if installRestoredCount > 0 {
                msg += "\n\n其中 \(installRestoredCount) 个是先安装再恢复的"
            }
            if !installNotFound.isEmpty {
                msg += "\n\n未在源中找到（请手动到 App 页导入 IPA）：\n" + installNotFound.joined(separator: "\n")
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
            if !versionMismatchApps.isEmpty {
                msg += "\n\n备份版本与当前 App 版本不同的（数据已整套按备份时刻恢复；打开后若仍有个别信息异常，是新版读旧数据的兼容问题）：\n" + versionMismatchApps.joined(separator: "\n")
            }
            // 一个都没恢复成时别再弹“成功”：v214 真机上“成功 /
            // 恢复完成：0 个 App”就是这么误导人的（照抄 v213
            // 备份侧“一个都没成直接报失败清单”的规矩）。正文
            // 里各类失败清单照旧列出，只是换成错误弹窗。
            if presentResult {
                let totalRestored = restoredCount + installRestoredCount
                if totalRestored == 0 && (!restoreFailedApps.isEmpty || !noDataApps.isEmpty || !ambiguousApps.isEmpty || !installFailed.isEmpty || !installNotFound.isEmpty) {
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
    static func waitForUbiquitousDownload(_ url: URL, fm: FileManager, maxSeconds: Int = 120, onProgress: ((Int, Int) -> Void)? = nil) async {
        guard let extURL = Self.externalBackupFolderURL(),
              url.path.hasPrefix(extURL.path + "/") else { return }
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
        if files.isEmpty { return }
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
        await Task.detached {
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
                if remaining.isEmpty { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
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
        try await Task.detached {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
        }.value
    }

    static func copyGroupOffMain(from src: URL, to dest: URL) async -> Bool {
        await Task.detached {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            return (try? fm.copyItem(at: src, to: dest)) != nil
        }.value
    }

    static func mergeLoginStateOffMain(from src: URL, to dest: URL, mirrorGroupToHost: URL? = nil) async -> Int {
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
        // 登录态合并计数（三种合并之和，见各合并点）与完整
        // 备份登录态恢复的顶层文件夹数（容器数修正用，见
        // outcome 赋值处）：只记数，不改合并语义。
        var mergedLoginFiles = 0
        var loginMergeFolderCount = 0
        var newDefaultContainer: LCContainer?
        for containerFolder in containerFolders {
            let folderName = containerFolder.lastPathComponent
            // iCloud 源先等数据下完再拷/合并，否则拷到占位空壳
            await Self.waitForUbiquitousDownload(containerFolder, fm: fm, onProgress: downloadProgress)
            if let live = app.uiContainers.first(where: { $0.containerURL.lastPathComponent == folderName }) {
                if isLoginBackup {
                    // 登录态备份只有半套会话文件：合并进现有
                    // 容器（同名文件覆盖、其他数据不动），整
                    // 容器替换会把没备的那半套数据删掉。
                    // 合并拷盘挪后台（见三件套注释）：逐文件
                    // copyItem 累计也是主线程长堵。
                    let mergeDest = live.containerURL
                    let mergeMirror: URL? = live.isolateAppGroup ? nil : LCPath.lcGroupAppGroupPath
                    let merged = await Self.mergeLoginStateOffMain(from: containerFolder, to: mergeDest, mirrorGroupToHost: mergeMirror)
                    mergedLoginFiles += merged
                    if merged > 0 {
                        restoredContainers += 1
                    }
                    continue
                }
                // 同名容器还在（没删过 App）：原地覆盖。
                // 拷盘挪后台（见三件套注释），语义与原来
                // 完全一致（存在先删再拷，失败照常 throw）。
                try await Self.replaceContainerOffMain(from: containerFolder, to: live.containerURL)
                restoredContainers += 1
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
            // 拷盘挪后台（见三件套注释），语义与原来一致。
            try await Self.replaceContainerOffMain(from: containerFolder, to: destURL)
            let restoredName = (NSDictionary(contentsOf: destURL.appendingPathComponent("LCContainerInfo.plist")) as? [String: Any])?["name"] as? String ?? folderName
            let restored = LCContainer(infoDict: ["folderName": folderName, "name": restoredName], isShared: app.appInfo.isShared)
            var containers = app.uiContainers
            containers.append(restored)
            app.uiContainers = containers
            app.appInfo.containers = containers
            restoredContainers += 1
            if newDefaultContainer == nil || folderName == manifestDataUUID {
                newDefaultContainer = restored
            }
        }
        if let newDefaultContainer {
            // 恢复出来的容器设为默认选中，App 下次打开就用它
            app.uiSelectedContainer = newDefaultContainer
            app.uiDefaultDataFolder = newDefaultContainer.folderName
            app.appInfo.dataUUID = newDefaultContainer.folderName
        }
        // 恢复模块选择：manifest 记着备份时的模块夹，写回；
        // 老备份没有这字段就不动（保持新装默认）
        if !manifestTweakFolder.isEmpty {
            app.appInfo.tweakFolder = manifestTweakFolder
        }
        var restoredExtras = false
        // 组容器数据写回：和容器、钥匙串是同一时刻的快照，
        // 三处一起回滚，App 读到的才是一套对齐的数据
        let appGroupBackup = appFolder.appendingPathComponent("AppGroup")
        if !loginOnly || isLoginBackup, let groupFolders = try? fm.contentsOfDirectory(at: appGroupBackup, includingPropertiesForKeys: nil) {
            for groupFolder in groupFolders {
                let dest = LCPath.lcGroupAppGroupPath.appendingPathComponent(groupFolder.lastPathComponent)
                // iCloud 源先等数据下完再拷/合并，否则拷到占位空壳
                await Self.waitForUbiquitousDownload(groupFolder, fm: fm, onProgress: downloadProgress)
                if isLoginBackup && fm.fileExists(atPath: dest.path) {
                    // 登录态档的组容器同样是半套：合并，不整替。
                    // 合并拷盘挪后台（见三件套注释）。
                    let merged = await Self.mergeLoginStateOffMain(from: groupFolder, to: dest)
                    mergedLoginFiles += merged
                    if merged > 0 {
                        restoredExtras = true
                    }
                    continue
                }
                // 组容器整替拷盘挪后台（见三件套注释），语义
                // 与原来一致（存在先删、失败静默不记）。
                if await Self.copyGroupOffMain(from: groupFolder, to: dest) {
                    restoredExtras = true
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
                await Self.waitForUbiquitousDownload(folder, fm: fm, onProgress: downloadProgress)
                guard let target = app.uiContainers.first(where: { $0.containerURL.lastPathComponent == n })
                        ?? app.uiSelectedContainer ?? app.uiContainers.first else { continue }
                // 合并拷盘挪后台（见三件套注释）：目标值先在
                // 调用方线程取出，只把纯 URL 传进 detached。
                let mergeDest = target.containerURL
                let mergeMirror: URL? = target.isolateAppGroup ? nil : LCPath.lcGroupAppGroupPath
                let merged = await Self.mergeLoginStateOffMain(from: folder, to: mergeDest, mirrorGroupToHost: mergeMirror)
                mergedLoginFiles += merged
                if merged > 0 {
                    restoredExtras = true
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
                guard let plist else { continue }
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
            MultitaskDockManager.shared.closeAppWindow(uuid: app.appInfo.dataUUID)
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
    static func copyLoginStateFiles(from src: URL, to dst: URL, fm: FileManager) -> (count: Int, breakdown: [String: Int], skipped: Int, skippedPaths: [String]) {
        var count = 0
        var bytes = 0
        var skipped = 0
        // 跳过路径清单：以前只报“跳过 N 个文件”，从报告证不了
        // 也证伪不了会话文件在不在跳过里；现在把相对路径也带
        // 出来（只收前 50 条防 2985 个全列出把报告撑爆，数照全计）。
        var skippedPaths: [String] = []
        var copied: [String] = []
        let entries = loginStateEntries(in: src, fm: fm).sorted { $0.size < $1.size }
        for e in entries {
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
            }
        }
        return (count, loginStateDirBreakdown(for: copied), skipped, skippedPaths)
    }

    /// 把登录态文件合并进现有容器（恢复用：同名文件逐个覆盖，
    /// 容器里其他文件不动；LCContainerInfo.plist 是活容器自己
    /// 的身份文件，永不覆盖）。返回合并了几个文件。
    /// mirrorGroupToHost：目标容器没开隔离组时，备份里的
    /// LCAppGroup/<组ID>/ 同步镜像一份到宿主组容器目录——
    /// 游客读组数据走哪边取决于容器当时的隔离开关，两边都
    /// 落一份才不会因开关状态错位而读空（不计入合并数）
    @discardableResult
    static func mergeLoginStateFiles(from src: URL, to dst: URL, fm: FileManager, mirrorGroupToHost: URL? = nil) -> Int {
        var count = 0
        for e in loginStateEntries(in: src, fm: fm) {
            let rel = e.rel
            if rel == "LCContainerInfo.plist" { continue }
            let s = e.src
            let d = dst.appendingPathComponent(rel)
            try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: d.path) {
                try? fm.removeItem(at: d)
            }
            if (try? fm.copyItem(at: s, to: d)) != nil {
                count += 1
            }
            if let host = mirrorGroupToHost {
                let parts = rel.split(separator: "/")
                if parts.count >= 3 && parts[0] == "LCAppGroup" {
                    let rest = parts.dropFirst(2).joined(separator: "/")
                    let hd = host.appendingPathComponent(String(parts[1])).appendingPathComponent(rest)
                    try? fm.createDirectory(at: hd.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: hd.path) {
                        try? fm.removeItem(at: hd)
                    }
                    try? fm.copyItem(at: s, to: hd)
                }
            }
        }
        return count
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
                let (data, _) = try await CZFVPNManager.hostSession().data(from: sourceURL)
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
                try await sharedModel.apps.first(where: { app in
                    return app.appInfo.bundleIdentifier() == "com.tigisoftware.Filza"
                })?.runApp(urlStr: launchURLStr)
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
        let hour = defaults.integer(forKey: "LCScheduleCacheHour")
        let minute = defaults.integer(forKey: "LCScheduleCacheMinute")
        let now = Date()
        let cal = Calendar.current
        if cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now) < hour * 60 + minute { return }
        for app in DataManager.shared.model.apps {
            app.appInfo.clearIconCache()
        }
        defaults.set(today, forKey: "LCScheduleCacheLastDate")
    }

    func checkAndRunScheduledBackup() async {
        await Self.runScheduledBackupIfDue()
    }

    /// 定时备份的静默核心（静态：同上，主界面打开即查）。判断
    /// 口径：启用 + 选了 App + 今天没备过 + 已到设定时间 →
    /// 按设定范围（完整/登录态）在后台静默备完才记日期，全
    /// 失败不记、等下次打开重试。原来走 backupApps 会弹"备
    /// 份完成"窗，定时触发不弹窗更合适
    static func runScheduledBackupIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "LCScheduleBackupEnabled") else { return }
        guard let ids = defaults.stringArray(forKey: "LCScheduleBackupAppIDs"), !ids.isEmpty else { return }
        let hour = defaults.integer(forKey: "LCScheduleBackupHour")
        let minute = defaults.integer(forKey: "LCScheduleBackupMinute")
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
        let didBackup: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var backedUpFolderNames: [String] = []
                if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let backupRoot = docs.appendingPathComponent("Backups")
                    try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    for app in selected {
                        // v216：同步按返回的实际文件夹名（多开后缀名
                        // ≠ 显示名），不按显示名猜
                        if let one = try? Self.backupOneAppSync(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly) {
                            backedUpFolderNames.append(one.folderName)
                        }
                    }
                    if !backedUpFolderNames.isEmpty {
                        Self.syncBackupsToExternalFolder(appNames: backedUpFolderNames, backupRoot: backupRoot)
                        Self.writeCZFSettingsBackup()
                    }
                }
                continuation.resume(returning: !backedUpFolderNames.isEmpty)
            }
        }
        if didBackup {
            defaults.set(today, forKey: "LCScheduleBackupLastDate")
            defaults.synchronize()
        }
    }
    
    func clearIconCache() async {
        for app in sharedModel.apps {
            app.appInfo.clearIconCache()
        }
    }
    
    // 直接用 rootViewController 弹出文件选择器（避免 SwiftUI 套娃 sheet 冲突）
    func presentExportPicker(for url: URL) {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        // 找到最顶层的 VC
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              var topVC = window.rootViewController else { return }
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        topVC.present(picker, animated: true)
        successInfo = "请选择导出位置（可存到 iCloud 云盘）"
        successShow = true
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
        topVC.present(picker, animated: true)
        successInfo = "请选择导出位置（可存到 iCloud 云盘）"
        successShow = true
    }

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
