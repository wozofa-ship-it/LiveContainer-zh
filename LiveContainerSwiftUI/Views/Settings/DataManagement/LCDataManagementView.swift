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
    @State private var showBackupSelect = false
    @State private var backupSelectedIDs = Set<String>()
    @State private var showRestoreSelect = false
    @State private var backupFolderList: [URL] = []
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
            Section {
                if sharedModel.multiLCStatus != 2 {
                    Button {
                        moveAppGroupFolderFromPrivateToAppGroup()
                    } label: {
                        Text("lc.settings.appGroupPrivateToShare".loc)
                    }
                    Button {
                        moveAppGroupFolderFromAppGroupToPrivate()
                    } label: {
                        Text("lc.settings.appGroupShareToPrivate".loc)
                    }

                    Button {
                        Task { await moveDanglingFolders() }
                    } label: {
                        Text("lc.settings.moveDanglingFolderOut".loc)
                    }
                    Button(role:.destructive) {
                        Task { await cleanUpUnusedFolders() }
                    } label: {
                        Text("lc.settings.cleanDataFolder".loc)
                    }
                }

                Button(role:.destructive) {
                    Task { await removeKeyChain() }
                } label: {
                    Text("lc.settings.cleanKeychain".loc)
                }

                Button(role:.destructive) {
                    Task { await clearTemporaryFiles() }
                } label: {
                    Text("lc.settings.cleanTmp".loc)
                }
                
                Button(role:.destructive) {
                    Task { await clearCacheFiles() }
                } label: {
                    Text("lc.settings.cleanCaches".loc) 
                }

            }
            
            Section(header: Text("lc.settings.backupRestore".loc)) {
                Button {
                    Task { await backupAllApps() }
                } label: {
                    Text("lc.settings.backupAll".loc)
                }
                Button {
                    showBackupSelect = true
                } label: {
                    Text("lc.settings.backupSelected".loc)
                }
                Button {
                    loadScheduleSettings()
                    showScheduleBackup = true
                } label: {
                    HStack {
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
                    showRestoreSelect = true
                } label: {
                    Text("lc.settings.restoreBackup".loc)
                }
            }
            
            Section {
                Button {
                    Task { await clearIconCache() }
                } label: {
                    Text("lc.settings.clearIconCache".loc)
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
                            let selected = (sharedModel.apps + sharedModel.hiddenApps).filter {
                                backupSelectedIDs.contains($0.appInfo.bundleIdentifier() ?? "")
                            }
                            showBackupSelect = false
                            Task { await backupApps(selected) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showRestoreSelect) {
            NavigationView {
                List(backupFolderList, id: \.self) { folderURL in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(folderURL.lastPathComponent)
                                .font(.headline)
                            Text(folderURL.path)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            showRestoreSelect = false
                            Task { await restoreFromBackup(at: folderURL) }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise.circle")
                                Text("恢复")
                            }
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            showRestoreSelect = false
                            Task { await installMissingApps(from: folderURL) }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                Text("安装")
                            }
                            .foregroundColor(.green)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            presentExportPicker(for: folderURL)
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("导出")
                            }
                            .foregroundColor(.orange)
                        }
                        .buttonStyle(.bordered)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteBackup(at: folderURL)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .navigationTitle("lc.settings.restoreBackup".loc)
                .onAppear {
                    backupFolderList = backupFolders()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("lc.common.cancel".loc) {
                            showRestoreSelect = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Menu {
                            Button {
                                showRestoreSelect = false
                                Task {
                                    for folderURL in backupFolderList {
                                        await restoreFromBackup(at: folderURL)
                                    }
                                }
                            } label: {
                                Label("一键恢复全部", systemImage: "arrow.clockwise.circle")
                            }
                            Button {
                                presentExportPickerForAll()
                            } label: {
                                Label("一键导出全部", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Text("全部")
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
                    Section(footer: Text("每天到点自动清理图标缓存。打开数据管理页时补执行。")) {
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
        // 检查定时备份
        Task { await checkAndRunScheduledBackup() }
        // 检查定时清理缓存
        Task { await checkAndRunScheduledCache() }
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

    func backupFolders() -> [URL] {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let backupsURL = docsURL.appendingPathComponent("Backups")
        guard let folders = try? fm.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else { return [] }
        return folders.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast) ?? Date.distantPast > (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast) ?? Date.distantPast }
    }

    func deleteBackup(at backupURL: URL) {
        do {
            try FileManager.default.removeItem(at: backupURL)
            // 直接从列表移除，不开关 sheet
            backupFolderList.removeAll { $0 == backupURL }
            successInfo = "已删除备份：\(backupURL.lastPathComponent)"
            successShow = true
        } catch {
            errorInfo = "删除失败：\(error.localizedDescription)"
            errorShow = true
        }
    }

    func backupAllApps() async {
        let allApps = sharedModel.apps + sharedModel.hiddenApps
        await backupApps(allApps)
    }

    func backupApps(_ apps: [LCAppModel]) async {
        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            errorInfo = "lc.settings.backupFail".loc
            errorShow = true
            return
        }
        let backupRoot = docsURL.appendingPathComponent("Backups")
        do {
            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            var count = 0
            for app in apps {
                let appName = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "Unknown"
                // 按 App 名建文件夹，存在则先删除再重建（直接覆盖）
                let appBackupURL = backupRoot.appendingPathComponent(appName)
                if fm.fileExists(atPath: appBackupURL.path) {
                    try fm.removeItem(at: appBackupURL)
                }
                try fm.createDirectory(at: appBackupURL, withIntermediateDirectories: true)
                // 保存 manifest.json（含 bundleID、版本，用于恢复时自动安装）
                let manifest: [String: String] = [
                    "bundleIdentifier": app.appInfo.bundleIdentifier() ?? "",
                    "displayName": app.appInfo.displayName() ?? "",
                    "version": app.appInfo.version() ?? ""
                ]
                if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
                    try? manifestData.write(to: appBackupURL.appendingPathComponent("manifest.json"))
                }
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
                count += 1
            }
            successInfo = String(format: "lc.settings.backupComplete".loc, count) + "\n" + backupRoot.path
            successShow = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }


    func restoreFromBackup(at backupURL: URL) async {
        let fm = FileManager.default
        do {
            // 新结构：backupURL 直接是单个 App 的备份文件夹（如 Backups/GitHub/）
            // 兼容旧结构：如果是时间戳文件夹，里面是多个 App 文件夹
            let folderName = backupURL.lastPathComponent
            let manifestURL = backupURL.appendingPathComponent("manifest.json")
            let isSingleAppFolder = fm.fileExists(atPath: manifestURL.path)
            
            let appFolders: [URL]
            if isSingleAppFolder {
                appFolders = [backupURL]
            } else {
                appFolders = try fm.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil)
            }
            var restoredCount = 0
            var missingApps: [String] = []
            var missingFolders: [URL] = []
            let allApps = sharedModel.apps + sharedModel.hiddenApps
            for appFolder in appFolders {
                let folderName = appFolder.lastPathComponent
                // 先按显示名匹配，再按 Bundle ID 匹配
                guard let app = allApps.first(where: {
                    ($0.appInfo.displayName() ?? "") == folderName ||
                    ($0.appInfo.bundleIdentifier() ?? "") == folderName
                }) else {
                    // App 未安装：读 manifest.json 获取应用名，提示用户先安装
                    let manifestURL = appFolder.appendingPathComponent("manifest.json")
                    var appName = folderName
                    if let data = try? Data(contentsOf: manifestURL),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let displayName = json["displayName"], !displayName.isEmpty {
                        appName = displayName
                    }
                    missingApps.append(appName)
                    continue
                }
                let containerFolders = try fm.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil)
                for containerFolder in containerFolders {
                    for container in app.uiContainers {
                        if container.containerURL.lastPathComponent == containerFolder.lastPathComponent {
                            let destURL = container.containerURL
                            if fm.fileExists(atPath: destURL.path) {
                                try fm.removeItem(at: destURL)
                            }
                            try fm.copyItem(at: containerFolder, to: destURL)
                            break
                        }
                    }
                }
                restoredCount += 1
            }
            var msg = String(format: "lc.settings.restoreComplete".loc, restoredCount)
            if !missingApps.isEmpty {
                msg += "\n\n未安装的 App（请先安装 IPA）：\n" + missingApps.joined(separator: "\n")
            }
            successInfo = msg
            successShow = true
            // 恢复为0时自动触发安装流程
            if restoredCount == 0 && !missingApps.isEmpty {
                await installMissingApps(from: backupURL)
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func installMissingApps(from backupURL: URL) async {
        let fm = FileManager.default
        do {
            // 新结构：backupURL 直接是单个 App 的备份文件夹；兼容旧时间戳结构
            let manifestURL = backupURL.appendingPathComponent("manifest.json")
            let isSingleAppFolder = fm.fileExists(atPath: manifestURL.path)
            let appFolders: [URL]
            if isSingleAppFolder {
                appFolders = [backupURL]
            } else {
                appFolders = try fm.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil)
            }
            let allApps = sharedModel.apps + sharedModel.hiddenApps
            var toInstall: [(name: String, bundleID: String)] = []
            for appFolder in appFolders {
                let folderName = appFolder.lastPathComponent
                // 跳过 manifest.json 和 .app bundle，只处理数据文件夹
                if folderName == "manifest.json" || folderName.hasSuffix(".app") { continue }
                let manifestURL = appFolder.appendingPathComponent("manifest.json")
                var bundleID = ""
                var displayName = folderName
                // 尝试从 manifest 读取
                if let data = try? Data(contentsOf: manifestURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    bundleID = json["bundleIdentifier"] ?? ""
                    if let dn = json["displayName"], !dn.isEmpty { displayName = dn }
                }
                // 检查是否已安装
                let installed = allApps.contains {
                    ($0.appInfo.displayName() ?? "") == folderName ||
                    ($0.appInfo.bundleIdentifier() ?? "") == folderName ||
                    (!(bundleID.isEmpty) && ($0.appInfo.bundleIdentifier() ?? "") == bundleID)
                }
                if !installed {
                    toInstall.append((name: displayName, bundleID: bundleID))
                }
            }
            if toInstall.isEmpty {
                await MainActor.run {
                    successInfo = "所有 App 均已安装，无需安装"
                    successShow = true
                }
            } else {
                // 优先从已添加的源查找 IPA
                var installedCount = 0
                var notFound: [String] = []
                for item in toInstall {
                    if let downloadURL = await searchSourceForApp(bundleID: item.bundleID, name: item.name) {
                        // 找到源，通过通知触发安装
                        await MainActor.run {
                            NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": downloadURL])
                        }
                        installedCount += 1
                    } else {
                        notFound.append(item.name)
                    }
                }
                var msg = ""
                if installedCount > 0 {
                    msg += "已从源找到 \(installedCount) 个 App 并开始安装\n"
                }
                if !notFound.isEmpty {
                    msg += "\n未在源中找到（请手动到 App 页导入 IPA）：\n" + notFound.joined(separator: "\n")
                }
                await MainActor.run {
                    successInfo = msg.isEmpty ? "未找到可安装的 App" : msg
                    successShow = true
                }
            }
        } catch {
            await MainActor.run {
                errorInfo = "扫描备份失败：\(error.localizedDescription)"
                errorShow = true
            }
        }
    }

    /// 从已添加的源中按 bundleID 或名字查找 App 的下载链接
    func searchSourceForApp(bundleID: String, name: String) async -> URL? {
        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: "LCAltStoreSourceURLs") as? [String] ?? []
        for urlString in stored {
            guard let sourceURL = URL(string: urlString) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: sourceURL)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let apps = json["apps"] as? [[String: Any]] else { continue }
                for app in apps {
                    let appBundleID = app["bundleIdentifier"] as? String ?? ""
                    let appName = app["name"] as? String ?? ""
                    let match = (!bundleID.isEmpty && appBundleID == bundleID) || (!name.isEmpty && appName == name)
                    if match {
                        // 优先取 versions[0].downloadURL，兼容顶层 downloadURL
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
            } catch {
                continue
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
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "LCScheduleCacheEnabled") else { return }
        // 今天已清理过就跳过
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let today = formatter.string(from: Date())
        if defaults.string(forKey: "LCScheduleCacheLastDate") == today { return }
        // 还没到设定时间就跳过
        let hour = defaults.integer(forKey: "LCScheduleCacheHour")
        let minute = defaults.integer(forKey: "LCScheduleCacheMinute")
        let now = Date()
        let cal = Calendar.current
        let nowHour = cal.component(.hour, from: now)
        let nowMinute = cal.component(.minute, from: now)
        if nowHour * 60 + nowMinute < hour * 60 + minute { return }
        // 执行清理
        await clearIconCache()
        defaults.set(today, forKey: "LCScheduleCacheLastDate")
    }
    
    func checkAndRunScheduledBackup() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "LCScheduleBackupEnabled") else { return }
        guard let ids = defaults.stringArray(forKey: "LCScheduleBackupAppIDs"), !ids.isEmpty else { return }
        
        let hour = defaults.integer(forKey: "LCScheduleBackupHour")
        let minute = defaults.integer(forKey: "LCScheduleBackupMinute")
        
        // 检查今天是否已备份
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let today = dateFormatter.string(from: Date())
        let lastBackup = defaults.string(forKey: "LCScheduleBackupLastDate") ?? ""
        if lastBackup == today { return }
        
        // 检查是否已到设定时间
        let calendar = Calendar.current
        let now = Date()
        let nowHour = calendar.component(.hour, from: now)
        let nowMinute = calendar.component(.minute, from: now)
        let nowTotal = nowHour * 60 + nowMinute
        let scheduleTotal = hour * 60 + minute
        if nowTotal < scheduleTotal { return }
        
        // 执行备份
        let selected = (sharedModel.apps + sharedModel.hiddenApps).filter {
            ids.contains($0.appInfo.bundleIdentifier() ?? "")
        }
        if !selected.isEmpty {
            await backupApps(selected)
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
        let urls = backupFolderList
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
