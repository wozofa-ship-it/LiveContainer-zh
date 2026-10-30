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
                Text("把节点列表、每个 App 的 VPN 标记、窗口位置、手势灵敏度等 CZF 设置，连同 App 排序、定时备份/定时清理设置，一起打包成一个 JSON 文件（CZFSettingsBackup.json）。点「导出设置」直接存：本地文稿根目录一份，你在下面选的备份文件夹里自动也一份；每次备份 App 时那份也会自动刷新。换机或重装后导入即可恢复；导入后重启 LiveContainer 全部生效。")
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
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow){
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
                        Image(systemName: backupSelectedIDs.contains(app.appInfo.bundleIdentifier() ?? "") ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(.blue)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let bid = app.appInfo.bundleIdentifier() ?? ""
                        if backupSelectedIDs.contains(bid) {
                            backupSelectedIDs.remove(bid)
                        } else {
                            backupSelectedIDs.insert(bid)
                        }
                    }
                }
                .navigationTitle("lc.settings.backupSelected".loc)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("lc.settings.backup".loc) {
                            pendingBackupApps = (sharedModel.apps + sharedModel.hiddenApps).filter {
                                backupSelectedIDs.contains($0.appInfo.bundleIdentifier() ?? "")
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
                                let bid = app.appInfo.bundleIdentifier() ?? ""
                                Image(systemName: scheduleSelectedIDs.contains(bid) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(.blue)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let bid = app.appInfo.bundleIdentifier() ?? ""
                                if scheduleSelectedIDs.contains(bid) {
                                    scheduleSelectedIDs.remove(bid)
                                } else {
                                    scheduleSelectedIDs.insert(bid)
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
    ]
    static let settingsBackupAppGroupKeys: Set<String> = [
        "LCAppSortType", "LCCustomSortOrder",
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
                let srcDate = (try? fm.attributesOfItem(atPath: srcManifest.path))?[.modificationDate] as? Date ?? Date.distantPast
                let destDate = (try? fm.attributesOfItem(atPath: destManifest.path))?[.modificationDate] as? Date ?? Date.distantPast
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

    /// 导入设置备份：只认 CZF 开头的键，逐个写回标准
    /// UserDefaults。JSON 数字回来是 NSNumber，UserDefaults
    /// 读写都认，不用特殊处理
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
        var count = 0
        for (key, value) in dict {
            if key.hasPrefix("CZF") || Self.settingsBackupExtraStandardKeys.contains(key) {
                UserDefaults.standard.set(value, forKey: key)
                count += 1
            } else if Self.settingsBackupAppGroupKeys.contains(key) {
                // 排序存在 App Group 里，导入必须写回 App Group，
                // 写标准库的话排序管理器读不到，等于没恢复。
                LCUtils.appGroupUserDefault.set(value, forKey: key)
                count += 1
            }
            // 其余未知键一律不写：旧备份只有 CZF 键时行为不变，
            // 证书、书签这类敏感/设备键就算进了文件也不会被导入。
        }
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
        if let data = try? Data(contentsOf: manifestURL),
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
    static func backupOneAppSync(_ app: LCAppModel, backupRoot: URL, fm: FileManager, loginOnly: Bool = false) throws -> (keychainCount: Int, keychainHasSnapshot: Bool, bridgeStatus: String?, loginFileCount: Int, loginBreakdown: [String: Int], loginSkipped: Int, keychainSnapshotDate: Date?) {
        let appName = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
        // 防丢：先写到文稿根目录下的临时文件夹（带点前缀，
        // 备份列表扫不到），全部写完最后一步才换名上位。原来是
        // 先删旧备份再重建，写到一半失败/空间满/被系统杀掉，
        // 就是新旧两空——仅密匙备份以后是登录命根子，不能赌。
        // 临时目录与 Backups 同卷，换名是瞬间完成的改名操作
        let finalURL = backupRoot.appendingPathComponent(appName)
        let appBackupURL = backupRoot.deletingLastPathComponent()
            .appendingPathComponent(".czf-backup-tmp-\(appName)")
        if fm.fileExists(atPath: appBackupURL.path) {
            try? fm.removeItem(at: appBackupURL)
        }
        try fm.createDirectory(at: appBackupURL, withIntermediateDirectories: true)
        var loginFileCount = 0
        var loginBreakdown: [String: Int] = [:]
        var loginSkipped = 0
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
            if fm.fileExists(atPath: srcURL.path) {
                try? fm.copyItem(at: srcURL, to: destURL)
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
        return (keychainCount, keychainHasSnapshot, bridgeStatus, loginFileCount, loginBreakdown, loginSkipped, newestDumpDate)
    }

    /// 覆盖安装前的自动备份入口：把被覆盖 App 的整套数据备
    /// 一份到 Backups/<显示名>（与手动备份同一位置、新的盖
    /// 旧的），新版装上有问题时能在数据管理里恢复回滚。
    /// 备份失败不挡安装，静默跳过
    static func autoBackupBeforeOverwrite(_ app: LCAppModel) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let root = docs.appendingPathComponent("Backups")
                    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
                    try? Self.backupOneAppSync(app, backupRoot: root, fm: fm)
                    if let name = app.appInfo.displayName() {
                        Self.syncBackupsToExternalFolder(appNames: [name], backupRoot: root)
                    }
                }
                continuation.resume()
            }
        }
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
        let (count, failure, keychainTotal, snapshotMissing, bridgeStatuses, loginFileTotal, loginBreakdownTotal, loginSkippedTotal, snapshotDates): (Int, Error?, Int, Bool, [String], Int, [String: Int], Int, [String]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                do {
                    try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    var count = 0
                    var backedUpNames: [String] = []
                    var keychainTotal = 0
                    var loginFileTotal = 0
                    var loginBreakdownTotal: [String: Int] = [:]
                    var loginSkippedTotal = 0
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
                        let one = try Self.backupOneAppSync(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly)
                        keychainTotal += one.keychainCount
                        loginFileTotal += one.loginFileCount
                        for (k, v) in one.loginBreakdown { loginBreakdownTotal[k, default: 0] += v }
                        loginSkippedTotal += one.loginSkipped
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
                        backedUpNames.append(name)
                    }
                    DispatchQueue.main.async {
                        self.backupRestoreProgress = "正在同步到备份文件夹…"
                    }
                    // 同步到外部备份文件夹（如已设置 iCloud 文件夹）
                    Self.syncBackupsToExternalFolder(appNames: backedUpNames, backupRoot: backupRoot)
                    // 设置备份跟着一起自动刷新（本地 + 所选备份文件夹）
                    Self.writeCZFSettingsBackup()
                    continuation.resume(returning: (count, nil, keychainTotal, snapshotMissing, bridgeStatuses, loginFileTotal, loginBreakdownTotal, loginSkippedTotal, snapshotDates))
                } catch {
                    continuation.resume(returning: (0, error, 0, false, [], 0, [:], 0, []))
                }
            }
        }
        backupRestoreProgress = nil
        if let failure {
            errorInfo = LCUtils.czfFriendlyError(failure)
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
                }
            }
            if !bridgeStatuses.isEmpty {
                successInfo += "\n—— 桥回执 ——\n" + bridgeStatuses.joined(separator: "\n")
            }
            if !snapshotDates.isEmpty {
                successInfo += "\n—— 钥匙串快照时间 ——\n" + snapshotDates.joined(separator: "\n")
                successInfo += "\n（快照是 App 打开/切后台时由桥写的；若之后登录过，先打开 App 切一次后台再备份）"
            }
            successInfo += "\n" + backupRoot.path
            successShow = true
        }
    }


    /// 恢复范围弹窗选完后分发：单个恢复走 pendingRestoreURL，
    /// 一键恢复全部走 pendingRestoreAll（同一个范围套全部）
    func startPendingRestore(loginOnly: Bool) {
        if pendingRestoreAll {
            pendingRestoreAll = false
            Task { await restoreAllBackups(loginOnly: loginOnly) }
        } else if let url = pendingRestoreURL {
            pendingRestoreURL = nil
            Task { await restoreFromBackup(at: url, loginOnly: loginOnly) }
        }
    }

    /// 一键恢复全部：逐个静默恢复、只在最后弹一个总报告（原
    /// 来每个备份弹一次自己的结果窗，十几个备份要点掉十几层）
    func restoreAllBackups(loginOnly: Bool) async {
        let merged = mergedBackupFolders()
        var lines: [String] = []
        for (index, folderURL) in merged.enumerated() {
            backupRestoreProgress = "正在恢复全部备份：\(folderURL.lastPathComponent)（\(index + 1)/\(merged.count)）"
            lines.append(await restoreFromBackup(at: folderURL, presentResult: false, loginOnly: loginOnly))
        }
        backupRestoreProgress = nil
        successInfo = "一键恢复全部完成（共 \(lines.count) 个备份）：\n\n" + lines.joined(separator: "\n")
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
        }
        do {
            // 新结构：backupURL 直接是单个 App 的备份文件夹（如 Backups/GitHub/）
            // 兼容旧结构：如果是时间戳文件夹，里面是多个 App 文件夹
            let folderName = backupURL.lastPathComponent
            let manifestURL = backupURL.appendingPathComponent("manifest.json")
            // iCloud 备份可能只同步了文件夹壳、内容元数据还没到本机：
            // 直接读会读到空文件夹，误报“成功 0 个”。先触发下载，
            // 等 manifest 出现或子项出现再读；等不到才按空处理。
            // 已同步好的文件夹第一次检查就通过，不多等。
            if let extURL = Self.externalBackupFolderURL(),
               backupURL.path.hasPrefix(extURL.path + "/") {
                try? fm.startDownloadingUbiquitousItem(at: backupURL)
                for _ in 0..<15 {
                    if fm.fileExists(atPath: manifestURL.path) { break }
                    if let children = try? fm.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil), !children.isEmpty { break }
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
            var keychainQueuedTotal = 0
            var keychainImportedTotal = 0
            var keychainUnwritableTotal = 0
            var missing: [(folder: URL, name: String, bundleID: String)] = []
            var noDataApps: [String] = []
            var versionMismatchApps: [String] = []
            var missingFolders: [URL] = []
            let allApps = sharedModel.apps + sharedModel.hiddenApps
            for (index, appFolder) in appFolders.enumerated() {
                let folderName = appFolder.lastPathComponent
                if presentResult {
                    backupRestoreProgress = "正在恢复 \(folderName)（\(index + 1)/\(appFolders.count)）"
                }
                // 先按显示名匹配，再按 Bundle ID 匹配
                var app = allApps.first(where: {
                    ($0.appInfo.displayName() ?? "") == folderName ||
                    ($0.appInfo.bundleIdentifier() ?? "") == folderName
                })
                // 改名后旧备份兜底：显示名对不上了，看 manifest 的
                // Bundle ID；同款只装了一个时才能唯一认出，多开装
                // 了两个时不猜（猜错会把数据还给错的那个）。
                if app == nil,
                   let data = try? Data(contentsOf: appFolder.appendingPathComponent("manifest.json")),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let bid = json["bundleIdentifier"], !bid.isEmpty {
                    let matches = allApps.filter { ($0.appInfo.bundleIdentifier() ?? "") == bid }
                    if matches.count == 1 {
                        app = matches[0]
                    }
                }
                guard let app else {
                    // App 未安装：记下它的备份文件夹和身份，后面先装再恢复
                    let manifestURL = appFolder.appendingPathComponent("manifest.json")
                    var appName = folderName
                    var appBundleID = ""
                    if let data = try? Data(contentsOf: manifestURL),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                        if let displayName = json["displayName"], !displayName.isEmpty {
                            appName = displayName
                        }
                        appBundleID = json["bundleIdentifier"] ?? ""
                    }
                    missing.append((folder: appFolder, name: appName, bundleID: appBundleID))
                    continue
                }
                let outcome = try await Self.restoreOneApp(appFolder: appFolder, app: app, loginOnly: loginOnly)
                keychainFoundTotal += outcome.keychainFound
                keychainQueuedTotal += outcome.keychainQueued
                keychainImportedTotal += outcome.keychainImported
                keychainUnwritableTotal += outcome.keychainUnwritable
                if outcome.ok {
                    restoredCount += 1
                    if Self.backupVersionDiffers(appFolder: appFolder, app: app) {
                        versionMismatchApps.append(app.appInfo.displayName() ?? folderName)
                    }
                } else {
                    noDataApps.append(app.appInfo.displayName() ?? folderName)
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
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": downloadURL])
                }
                // 装好后 App 会进 sharedModel 的列表；2 秒一查，最多等 10 分钟
                var installedApp: LCAppModel?
                for _ in 0..<300 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let currentApps = sharedModel.apps + sharedModel.hiddenApps
                    installedApp = currentApps.first(where: {
                        (!item.bundleID.isEmpty && ($0.appInfo.bundleIdentifier() ?? "") == item.bundleID) ||
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
                let outcome2 = try await Self.restoreOneApp(appFolder: item.folder, app: installedApp, loginOnly: loginOnly)
                keychainFoundTotal += outcome2.keychainFound
                keychainQueuedTotal += outcome2.keychainQueued
                keychainImportedTotal += outcome2.keychainImported
                keychainUnwritableTotal += outcome2.keychainUnwritable
                if outcome2.ok {
                    installRestoredCount += 1
                    if Self.backupVersionDiffers(appFolder: item.folder, app: installedApp) {
                        versionMismatchApps.append(item.name)
                    }
                } else {
                    noDataApps.append(item.name)
                }
            }
            var msg = String(format: "lc.settings.restoreComplete".loc, restoredCount + installRestoredCount)
            if keychainFoundTotal > 0 {
                msg += "\n\n钥匙串：备份含 \(keychainFoundTotal) 条，已排队 \(keychainQueuedTotal) 条（打开 App 时由桥写回），宿主直写 \(keychainImportedTotal) 条"
                if keychainUnwritableTotal > 0 {
                    msg += "\n其中 \(keychainUnwritableTotal) 条所属 App 不注入插件（桥不加载），排队文件不会被写回"
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
            if !versionMismatchApps.isEmpty {
                msg += "\n\n备份版本与当前 App 版本不同的（数据已整套按备份时刻恢复；打开后若仍有个别信息异常，是新版读旧数据的兼容问题）：\n" + versionMismatchApps.joined(separator: "\n")
            }
            if presentResult {
                successInfo = msg
                successShow = true
            }
            // 汇总用的一行摘要：恢复数 + 各类问题计数
            var line = "\(folderName)：已恢复 \(restoredCount + installRestoredCount) 个"
            var issues: [String] = []
            if !installNotFound.isEmpty { issues.append("未在源中找到 \(installNotFound.count) 个") }
            if !installFailed.isEmpty { issues.append("安装失败 \(installFailed.count) 个") }
            if !noDataApps.isEmpty { issues.append("无可恢复数据 \(noDataApps.count) 个") }
            if !versionMismatchApps.isEmpty { issues.append("版本不同 \(versionMismatchApps.count) 个") }
            if !issues.isEmpty {
                line += "（" + issues.joined(separator: "、") + "）"
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
    }

    /// 把一个 App 备份文件夹里的数据容器恢复到这个 App 名下。
    /// ok = 至少拷回一个容器或写回一条钥匙串。删后重装时容
    /// 器名对不上号，按原文件夹名放回原位并登记，登录态才能
    /// 跟着回来（见内注）。做成静态：安装流程装完新 App 后
    /// 也要调它自动恢复备份。
    static func restoreOneApp(appFolder: URL, app: LCAppModel, loginOnly: Bool = false) async throws -> RestoreOutcome {
        let fm = FileManager.default
        // 登录态备份的容器里只有半套会话文件，恢复走合并（见
        // 循环内分支）；完整备份整套替换；只恢复登录态时完整
        // 备份的容器不进循环，会话文件在下面单独合并
        let isLoginBackup = Self.backupScope(of: appFolder) == "login"
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
        if let data = try? Data(contentsOf: appFolder.appendingPathComponent("manifest.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            manifestDataUUID = json["dataUUID"] ?? ""
            if let g = json["keychainGroupId"], let gv = Int(g) {
                manifestKeychainGroupId = gv
            }
            manifestTweakFolder = json["tweakFolder"] ?? ""
        }
        var restoredContainers = 0
        var newDefaultContainer: LCContainer?
        for containerFolder in containerFolders {
            let folderName = containerFolder.lastPathComponent
            if let live = app.uiContainers.first(where: { $0.containerURL.lastPathComponent == folderName }) {
                if isLoginBackup {
                    // 登录态备份只有半套会话文件：合并进现有
                    // 容器（同名文件覆盖、其他数据不动），整
                    // 容器替换会把没备的那半套数据删掉
                    if Self.mergeLoginStateFiles(from: containerFolder, to: live.containerURL, fm: fm, mirrorGroupToHost: live.isolateAppGroup ? nil : LCPath.lcGroupAppGroupPath) > 0 {
                        restoredContainers += 1
                    }
                    continue
                }
                // 同名容器还在（没删过 App）：原地覆盖
                let destURL = live.containerURL
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: containerFolder, to: destURL)
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
                // 登录其实没回来；钥匙串部分走下面兜底建容器那套
                let realFiles = Self.loginStateEntries(in: containerFolder, fm: fm).map { $0.rel }.filter { $0 != "LCContainerInfo.plist" }
                if realFiles.isEmpty {
                    continue
                }
            }
            let root = app.appInfo.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath
            let destURL = root.appendingPathComponent(folderName)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: containerFolder, to: destURL)
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
                if isLoginBackup && fm.fileExists(atPath: dest.path) {
                    // 登录态档的组容器同样是半套：合并，不整替
                    if Self.mergeLoginStateFiles(from: groupFolder, to: dest, fm: fm) > 0 {
                        restoredExtras = true
                    }
                    continue
                }
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                if (try? fm.copyItem(at: groupFolder, to: dest)) != nil {
                    restoredExtras = true
                }
            }
        }
        // 完整备份 + 只恢复登录态：整套容器不动，只把备份容器
        // 里的会话文件合并进现有容器（钥匙串在下面照常写回）；
        // 容器一个都没有（刚装完）时跳过文件部分，钥匙串兜底
        // 建容器那套逻辑照旧
        if loginOnly && !isLoginBackup {
            let topFolders = (try? fm.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil)) ?? []
            for folder in topFolders {
                let n = folder.lastPathComponent
                if n == "manifest.json" || n.hasSuffix(".app") || n == "AppGroup" || n == "Keychain" { continue }
                guard let target = app.uiContainers.first(where: { $0.containerURL.lastPathComponent == n })
                        ?? app.uiSelectedContainer ?? app.uiContainers.first else { continue }
                if Self.mergeLoginStateFiles(from: folder, to: target.containerURL, fm: fm, mirrorGroupToHost: target.isolateAppGroup ? nil : LCPath.lcGroupAppGroupPath) > 0 {
                    restoredExtras = true
                }
            }
        }
        // 钥匙串写回：备份里哪个容器的快照，就写进这次恢复后
        // 同名容器的组里（组号取目标容器自己的，删后重装时
        // 与备份一致；同名覆盖时按现有容器走，不串号）
        var outcome = RestoreOutcome()
        let keychainBackup = appFolder.appendingPathComponent("Keychain")
        if let files = try? fm.contentsOfDirectory(at: keychainBackup, includingPropertiesForKeys: nil) {
            let plistFiles = files.filter { $0.pathExtension == "plist" }
            for file in plistFiles {
                if let data = try? Data(contentsOf: file),
                   let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
                    outcome.keychainFound += items.count
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
                // 本地（读出来直接失败）：先触发下载、短等重试
                var data = try? Data(contentsOf: file)
                if data == nil {
                    try? fm.startDownloadingUbiquitousItem(at: file)
                    for _ in 0..<5 where data == nil {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        data = try? Data(contentsOf: file)
                    }
                }
                guard let data,
                      let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { continue }
                let writeResult = Self.importKeychainItems(items, container: target)
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
        guard let data = try? Data(contentsOf: folderURL.appendingPathComponent("manifest.json")),
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
    static func copyLoginStateFiles(from src: URL, to dst: URL, fm: FileManager) -> (count: Int, breakdown: [String: Int], skipped: Int) {
        var count = 0
        var bytes = 0
        var skipped = 0
        var copied: [String] = []
        let entries = loginStateEntries(in: src, fm: fm).sorted { $0.size < $1.size }
        for e in entries {
            if bytes + e.size > 300 * 1024 * 1024 { skipped += 1; continue }
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
        return (count, loginStateDirBreakdown(for: copied), skipped)
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
    static func backupVersionDiffers(appFolder: URL, app: LCAppModel) -> Bool {
        guard let data = try? Data(contentsOf: appFolder.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
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
    static func importKeychainItems(_ items: [[String: Any]], container: LCContainer) -> (imported: Int, lastStatus: OSStatus) {
        let group = keychainGroupString(groupId: container.keychainGroupId)
        var imported = 0
        var lastStatus: OSStatus = errSecSuccess
        for item in items {
            var attrs = item
            attrs.removeValue(forKey: "cdat")
            attrs.removeValue(forKey: "mdat")
            attrs.removeValue(forKey: kSecAttrSynchronizable as String)
            attrs[kSecAttrAccessGroup as String] = group
            attrs["alis"] = container.folderName
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
                    "alis": container.folderName
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
    
    func loadScheduleSettings() {
        let defaults = UserDefaults.standard
        scheduleEnabled = defaults.bool(forKey: "LCScheduleBackupEnabled")
        scheduleHour = defaults.integer(forKey: "LCScheduleBackupHour")
        scheduleMinute = defaults.integer(forKey: "LCScheduleBackupMinute")
        if let ids = defaults.stringArray(forKey: "LCScheduleBackupAppIDs") {
            scheduleSelectedIDs = Set(ids)
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
        let selected = (model.apps + model.hiddenApps).filter {
            ids.contains($0.appInfo.bundleIdentifier() ?? "")
        }
        guard !selected.isEmpty else { return }
        let didBackup: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var backedUpNames: [String] = []
                if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let backupRoot = docs.appendingPathComponent("Backups")
                    try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    for app in selected {
                        if (try? Self.backupOneAppSync(app, backupRoot: backupRoot, fm: fm, loginOnly: loginOnly)) != nil {
                            backedUpNames.append(app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown")
                        }
                    }
                    if !backedUpNames.isEmpty {
                        Self.syncBackupsToExternalFolder(appNames: backedUpNames, backupRoot: backupRoot)
                        Self.writeCZFSettingsBackup()
                    }
                }
                continuation.resume(returning: !backedUpNames.isEmpty)
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
