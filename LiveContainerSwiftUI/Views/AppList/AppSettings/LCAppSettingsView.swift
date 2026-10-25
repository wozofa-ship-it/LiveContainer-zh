//
//  LCAppSettingsView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/9/16.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LCAppSettingsView: View {
    @State private var documentPickerCoordinator = DocumentPickerCoordinator()

    private class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
        var onDocumentPicked: ((URL) -> Void)?

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onDocumentPicked?(url)
        }
    }
    
    private var appInfo : LCAppInfo
    
    @ObservedObject private var model : LCAppModel
    

    @StateObject private var renameFolderInput = InputHelper()
    @StateObject private var moveToAppGroupAlert = YesNoHelper()
    @StateObject private var moveToPrivateDocAlert = YesNoHelper()
    @StateObject private var signUnsignedAlert = YesNoHelper()
    @StateObject private var addExternalNonLocalContainerWarningAlert = YesNoHelper()
    @State var choosingStorage = false
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    // 修复区默认折叠（平时不常用，页面先短一截）
    @State private var fixesExpanded = false
    @State private var selectUnusedContainerSheetShow = false
    @State private var schedMinEnabled = false
    @State private var schedMinTime = Date()
    /// 单 App VPN 指定节点改动后自增，逼设置页重读一遍节点行。
    @State private var vpnNodeTick = 0

    /// 每 App 保活开关：白名单文件不存在 = 全保，开关显示开；
    /// 文件存在 = 只有名单里的 App 保活。改完需重开该 App 生效
    /// （白名单在游客启动时构造器里读一次）。
    @State private var keepAliveOn = true
    
    @EnvironmentObject private var sharedModel : SharedModel
    
    init(model: LCAppModel) {
        self.appInfo = model.appInfo
        self._model = ObservedObject(wrappedValue: model)
    }

    // 定时最小化打开：开关与时间按 bundleIdentifier 存 UserDefaults，
    // 由 MultitaskDockManager 的轮询到点执行（键名前缀 CZFSchedMin）。
    private var schedMinBundleId: String {
        appInfo.bundleIdentifier() ?? ""
    }

    private func loadSchedMinSettings() {
        let defaults = UserDefaults.standard
        let bid = schedMinBundleId
        schedMinEnabled = defaults.bool(forKey: "CZFSchedMinEnabled-\(bid)")
        let minutes: Int
        if defaults.object(forKey: "CZFSchedMinMinutes-\(bid)") == nil {
            minutes = 8 * 60
        } else {
            minutes = defaults.integer(forKey: "CZFSchedMinMinutes-\(bid)")
        }
        var comps = DateComponents()
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        schedMinTime = Calendar.current.date(from: comps) ?? Date()
    }

    /// 保活总开关（没存过 = 默认开，跟启动同步同一读法）
    private var globalKeepAliveOn: Bool {
        UserDefaults.standard.object(forKey: "LCKeepAliveEnabled") as? Bool ?? true
    }

    // 每 App 保活：白名单文件 CZFKeepAliveApps.txt 跟 dylib 同目录，
    // dylib 拷在两个全局夹，写两份保持一致（构造器用 dladdr 读自己那份）。
    private func keepAliveListURLs() -> [URL] {
        [LCPath.tweakPath, LCPath.lcGroupTweakPath].map { $0.appendingPathComponent("CZFKeepAliveApps.txt") }
    }

    /// 白名单：nil = 两夹文件都不存在（全保）；否则为名单内容
    private func readKeepAliveList() -> [String]? {
        for url in keepAliveListURLs() {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        return nil
    }

    private func writeKeepAliveList(_ list: [String]) throws {
        let content = list.isEmpty ? "" : list.joined(separator: "\n") + "\n"
        let fm = FileManager()
        for url in keepAliveListURLs() {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func loadKeepAliveSetting() {
        let bid = appInfo.bundleIdentifier() ?? ""
        if let list = readKeepAliveList() {
            keepAliveOn = list.contains(bid)
        } else {
            keepAliveOn = true
        }
    }

    private func setKeepAlive(_ on: Bool) {
        let bid = appInfo.bundleIdentifier() ?? ""
        guard !bid.isEmpty else { return }
        do {
            if on {
                if var list = readKeepAliveList() {
                    if !list.contains(bid) {
                        list.append(bid)
                        try writeKeepAliveList(list)
                    }
                }
                // 文件不存在 = 本来就全保，不用写
            } else {
                if var list = readKeepAliveList() {
                    list.removeAll { $0 == bid }
                    try writeKeepAliveList(list)
                } else {
                    // 首次关：用全部 App 名单种子，只去掉这个 App
                    let all = (sharedModel.apps + sharedModel.hiddenApps).compactMap { $0.appInfo.bundleIdentifier() }.filter { !$0.isEmpty && $0 != bid }
                    guard !all.isEmpty else {
                        errorShow = true
                        errorInfo = "应用列表为空，无法建立保活名单"
                        return
                    }
                    try writeKeepAliveList(all)
                }
            }
            keepAliveOn = on
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
        }
    }

    /// 单 App VPN 的节点行：跟随全局或给这个 App 单独指定一个
    /// 节点（延迟敏感的 App 指到最快的那个）。核心只有一个，
    /// 打开这个 App 时若核心正跑在别的节点上会按它的节点重启。
    private var vpnNodeRow: some View {
        let links = CZFVPNManager.shared.nodeLinks
        let current = CZFVPNManager.nodeOverride(for: model.appInfo)
        let _ = vpnNodeTick
        return Menu {
            Button {
                CZFVPNManager.setNodeOverride(nil, for: model.appInfo)
                vpnNodeTick += 1
            } label: {
                if current == nil {
                    Label("跟随全局", systemImage: "checkmark")
                } else {
                    Text("跟随全局")
                }
            }
            ForEach(links, id: \.self) { link in
                Button {
                    CZFVPNManager.setNodeOverride(link, for: model.appInfo)
                    vpnNodeTick += 1
                } label: {
                    let d = CZFVPNManager.nodeDisplay(for: link)
                    if current == link {
                        Label(d.detail.isEmpty ? d.name : "\(d.name)（\(d.detail)）", systemImage: "checkmark")
                    } else {
                        Text(d.detail.isEmpty ? d.name : "\(d.name)（\(d.detail)）")
                    }
                }
            }
        } label: {
            HStack {
                LCSettingsIcon(systemName: "server.rack", color: .blue)
                Text("使用节点")
                Spacer()
                Text(current.map { CZFVPNManager.nodeDisplay(for: $0).name } ?? "跟随全局")
                    .foregroundStyle(.gray)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
    }

    private func saveSchedMinSettings() {
        let bid = schedMinBundleId
        guard !bid.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(schedMinEnabled, forKey: "CZFSchedMinEnabled-\(bid)")
        let cal = Calendar.current
        let minutes = cal.component(.hour, from: schedMinTime) * 60 + cal.component(.minute, from: schedMinTime)
        defaults.set(minutes, forKey: "CZFSchedMinMinutes-\(bid)")
        // 改设置后清掉今日已开标记，让新时间今天就能生效
        defaults.removeObject(forKey: "CZFSchedMinLastDate-\(bid)")
    }
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("lc.appSettings.bundleId".loc)
                    Spacer()
                    Text(appInfo.relativeBundlePath)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("lc.appSettings.remark".loc)
                    Spacer()
                    TextField("lc.appSettings.remarkPlaceholder".loc, text: $model.uiRemark)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.trailing)
                }
                if !model.uiIsShared {
                    Menu {
                        Button {
                            model.uiTweakFolder = nil
                        } label: {
                            Text(model.uiTweakFolders.isEmpty ? "✓ \("lc.common.none".loc)" : "lc.common.none".loc)
                        }
                        ForEach(sharedModel.tweakFolderNames, id:\.self) { folderName in
                            Button {
                                model.toggleTweakFolder(folderName)
                            } label: {
                                Text(model.uiTweakFolders.contains(folderName) ? "✓ \(folderName)" : folderName)
                            }
                        }
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "folder.fill", color: .blue)
                            Text("lc.appSettings.tweakFolder".loc)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(model.uiTweakFolders.isEmpty ? "None" : (model.uiTweakFolders.count == 1 ? model.uiTweakFolders[0] : "\(model.uiTweakFolders.count) 个"))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    
                    
                } else {
                    HStack {
                        Text("lc.appSettings.tweakFolder".loc)
                            .foregroundColor(.primary)
                        Spacer()
                        Text(model.uiTweakFolders.isEmpty ? "lc.common.none".loc : model.uiTweakFolders.joined(separator: "、"))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                if !model.uiIsShared {
                    if LCUtils.isAppGroupAltStoreLike() || LCUtils.store() == .ADP {
                        Button {
                            Task { await moveToAppGroup()}
                        } label: {
                            HStack {
                                LCSettingsIcon(systemName: "person.2.fill", color: .blue)
                                Text("lc.appSettings.toSharedApp".loc)
                            }
                        }
                    }
                } else if sharedModel.multiLCStatus != 2 {
                    Button {
                        Task { await movePrivateDoc() }
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "person.fill", color: .gray)
                            Text("lc.appSettings.toPrivateApp".loc)
                        }
                    }
                }
            } header: {
                Text("lc.common.data".loc)
            }
            
            Section {
                List{
                    ForEach(model.uiContainers.indices, id:\.self) { i in
                        NavigationLink {
                            LCContainerView(container: model.uiContainers[i], uiDefaultDataFolder: $model.uiDefaultDataFolder, delegate: self)
                        } label: {
                            Text(model.uiContainers[i].name)
                        }
                    }
                }
                if(model.uiContainers.count < SharedModel.keychainAccessGroupCount) {
                    Button {
                        Task{ await createFolder() }
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "folder.badge.plus", color: .blue)
                            Text("lc.appSettings.newDataFolder".loc)
                        }
                    }
                    Button {
                        choosingStorage = true
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "externaldrive.fill", color: .gray)
                            Text("lc.appSettings.selectExternalStorage".loc)
                        }
                    }
                    if(!model.uiIsShared) {
                        Button {
                            selectUnusedContainerSheetShow = true
                        } label: {
                            HStack {
                                LCSettingsIcon(systemName: "archivebox.fill", color: .gray)
                                Text("lc.container.selectUnused".loc)
                            }
                        }
                    }
                }
                
            } header: {
                Text("lc.common.container".loc)
            }
            
            
            Section {
                Toggle(isOn: $model.uiIsJITNeeded) {
                    HStack {
                        LCSettingsIcon(systemName: "bolt.fill", color: .orange)
                        Text("lc.appSettings.launchWithJit".loc)
                    }
                }
                .disabled(model.uiIs32bit)
                if #available(iOS 26.0, *), model.uiIsJITNeeded, !model.uiIs32bit {
                    HStack {
                        Text("lc.appSettings.jit26.script".loc)
                        Spacer()
                        if let base64String = model.jitLaunchScriptJs, !base64String.isEmpty {
                            // Show a generic name since we're not storing the filename
                            Text("lc.appSettings.jit26.scriptLoaded".loc)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.primary)

                            Button(action: {
                                model.jitLaunchScriptJs = nil
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        } else {
                            Text("No file selected")
                                .foregroundColor(.gray)
                        }
                        Button(action: {
                            // This will trigger the file picker
                            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.javaScript], asCopy: true)
                            picker.allowsMultipleSelection = false
                            documentPickerCoordinator.onDocumentPicked = { url in
                                do {
                                    let data = try Data(contentsOf: url)
                                    // Store the Base64-encoded string of the file content
                                    model.jitLaunchScriptJs = data.base64EncodedString()
                                } catch {
                                    errorInfo = "Failed to read file: \(error.localizedDescription)"
                                    errorShow = true
                                }
                            }
                            picker.delegate = documentPickerCoordinator

                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let rootViewController = windowScene.windows.first?.rootViewController {
                                rootViewController.present(picker, animated: true)
                            }
                        }) {
                            Text("lc.common.select".loc)
                        }
                    }
                }
                if model.uiIs32bit {
                    Picker(selection: $model.uiSelected32BitEmulator) {
                        ForEach(sharedModel.arm32EmuApps, id: \.self) { app in
                            Text("lc.common.default".loc).tag("")
                            Text(app.appInfo.displayName()).tag(app.appInfo.relativeBundlePath!)
                        }
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "cpu.fill", color: .gray)
                            Text("lc.appSettings.selected32BitEmulator".loc)
                        }
                    }
                }
            } footer: {

                    if #available(iOS 26.0, *), model.uiIsJITNeeded {
                        Text("lc.appSettings.launchWithJitDesc".loc + "\n" + "lc.appSettings.jit26.scriptDesc".loc)

                    } else {
                        Text("lc.appSettings.launchWithJitDesc".loc)
                    }
                
            }

            Section {
                Toggle(isOn: $model.uiIsLocked) {
                    HStack {
                        LCSettingsIcon(systemName: "lock.fill", color: .red)
                        Text("lc.appSettings.lockApp".loc)
                    }
                }
                .onChange(of: model.uiIsLocked, perform: { newValue in
                    Task { await model.setLocked(newLockState: newValue) }
                })

                if model.uiIsLocked {
                    Toggle(isOn: $model.uiIsHidden) {
                        HStack {
                            LCSettingsIcon(systemName: "eye.slash.fill", color: .gray)
                            Text("lc.appSettings.hideApp".loc)
                        }
                    }
                    .onChange(of: model.uiIsHidden, perform: { _ in
                        Task { await toggleHidden() }
                    })
                    .transition(.opacity.combined(with: .slide)) 
                }
            } footer: {
                if model.uiIsLocked {
                    Text("lc.appSettings.hideAppDesc".loc)
                        .transition(.opacity.combined(with: .slide))
                }
            }
            
            if #available(iOS 16.0, *) {
                Section {
                    Picker(selection: $model.uiIsMultitaskModeSpecificed) {
                        Text("lc.common.default".loc).tag(MultitaskSpecified.default)
                        Text("lc.common.no".loc).tag(MultitaskSpecified.no)
                        Text("lc.common.yes".loc).tag(MultitaskSpecified.yes)
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "rectangle.stack", color: .purple)
                            Text("lc.appBanner.multitask".loc)
                        }
                    }
                }
            }
            
            Section {
                NavigationLink {
                    if let supportedLanguage = model.supportedLanguages {
                        Form {
                            Picker(selection: $model.uiSelectedLanguage) {
                                Text("lc.common.auto".loc).tag("")
                                
                                ForEach(supportedLanguage, id:\.self) { language in
                                    if language != "Base" {
                                        VStack(alignment: .leading) {
                                            Text(Locale(identifier: language).localizedString(forIdentifier: language) ?? language)
                                            Text("\(Locale.current.localizedString(forIdentifier: language) ?? "") - \(language)")
                                                .font(.footnote)
                                                .foregroundStyle(.gray)
                                        }
                                        .tag(language)
                                    }

                                }
                            } label: {
                                Text("lc.common.language".loc)
                            }
                            .pickerStyle(.inline)
                        }

                    } else {
                        Text("lc.common.loading".loc)
                            .onAppear() {
                                Task{ loadSupportedLanguages() }
                            }
                    }
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "globe", color: .blue)
                        Text("lc.common.language".loc)
                        Spacer()
                        if model.uiSelectedLanguage == "" {
                            Text("lc.common.auto".loc)
                                .foregroundStyle(.gray)
                        } else {
                            Text(Locale.current.localizedString(forIdentifier: model.uiSelectedLanguage) ?? model.uiSelectedLanguage)
                                .foregroundStyle(.gray)
                        }
                    }
                    
                }
            }
            
            Section {
                Toggle(isOn: Binding(
                    get: { CZFVPNManager.isEnabled(for: model.appInfo) },
                    set: { CZFVPNManager.setEnabled($0, for: model.appInfo) }
                )) {
                    HStack {
                        LCSettingsIcon(systemName: "shield.fill", color: .green)
                        Text("VPN 打开（内置节点）")
                    }
                }
                if CZFVPNManager.isEnabled(for: model.appInfo) {
                    vpnNodeRow
                }
                if let stats = CZFVPNManager.proxyStatsText(for: model.appInfo) {
                    Text(stats)
                        .font(.caption)
                        .foregroundStyle(.gray)
                    if CZFVPNManager.proxySelfTestFailed(for: model.appInfo) {
                        Text("自检 0：代理钩子没装上，流量没走节点，重开 App 再看。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("单App VPN（验证版）")
            } footer: {
                Text("开启后这个 App 的流量走内置节点出网（节点链接在「设置 → 单App VPN」里填）。没有专属插件目录时会自动建一个名为 CZFVPN 的目录。改完需重开该 App 生效。")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { keepAliveOn },
                    set: { setKeepAlive($0) }
                )) {
                    HStack {
                        LCSettingsIcon(systemName: "heart.fill", color: .red)
                        Text("保活（仅这个 App）")
                    }
                }
                .disabled(!globalKeepAliveOn)
            } header: {
                Text("后台保活")
            } footer: {
                Text("需先在设置里打开保活总开关，否则这里不可选。开着时这个 App 切后台进音频保活档位；关掉后它不再保活，且名单一旦建立、没勾的 App 也不保活。改完需重开该 App 生效。")
            }

            Section {
                Toggle(isOn: $schedMinEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "clock.fill", color: .orange)
                        Text("定时最小化打开")
                    }
                }
                .onChange(of: schedMinEnabled) { _ in
                    saveSchedMinSettings()
                }
                if schedMinEnabled {
                    DatePicker(selection: $schedMinTime, displayedComponents: .hourAndMinute) {
                        HStack {
                            LCSettingsIcon(systemName: "alarm.fill", color: .orange)
                            Text("打开时间")
                        }
                    }
                        .onChange(of: schedMinTime) { _ in
                            saveSchedMinSettings()
                        }
                }
            } header: {
                Text("定时打开")
            } footer: {
                Text("每天到设定时间，自动把这个 App 以最小化方式打开。需要 LiveContainer 保持运行（在前台，或开着保活挂在后台）；如果到点时 LiveContainer 被彻底关掉了，下次打开它时会补开。这个 App 需要先手动打开过一次。")
            }

            Section {
                DisclosureGroup(isExpanded: $fixesExpanded) {
                    Toggle(isOn: $model.uiFixFilePickerNew) {
                        HStack {
                            LCSettingsIcon(systemName: "folder.fill", color: .blue)
                            Text("lc.appSettings.fixFilePickerNew".loc)
                        }
                    }
                    Toggle(isOn: $model.uiFixLocalNotification) {
                        HStack {
                            LCSettingsIcon(systemName: "bell.fill", color: .orange)
                            Text("lc.appSettings.fixLocalNotification".loc)
                        }
                    }
                    Toggle(isOn: $model.uiUseLCBundleId) {
                        HStack {
                            LCSettingsIcon(systemName: "app.badge", color: .blue)
                            Text("lc.appSettings.useLCBundleId".loc)
                        }
                    }
                    Text("lc.appSettings.useLCBundleIdDesc".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "wrench.and.screwdriver.fill", color: .gray)
                        Text("lc.appSettings.fixes".loc)
                    }
                }
            }
            
            if SharedModel.isPhone {
                Section {
                    Picker(selection: $model.uiOrientationLock) {
                        Text("lc.common.disabled".loc).tag(LCOrientationLock.Disabled)
                        Text("lc.apppSettings.orientationLock.landscape".loc).tag(LCOrientationLock.Landscape)
                        Text("lc.apppSettings.orientationLock.portrait".loc).tag(LCOrientationLock.Portrait)
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "iphone", color: .gray)
                            Text("lc.apppSettings.orientationLock".loc)
                        }
                    }
                }
            }
            
            Section {
                Toggle(isOn: $model.uiHideLiveContainer) {
                    HStack {
                        LCSettingsIcon(systemName: "eye.slash", color: .gray)
                        Text("lc.appSettings.hideLiveContainer".loc)
                    }
                }

                Toggle(isOn: $model.uiDontInjectTweakLoader) {
                    HStack {
                        LCSettingsIcon(systemName: "nosign", color: .red)
                        Text("lc.appSettings.dontInjectTweakLoader".loc)
                    }
                }.disabled(model.uiTweakLoaderInjectFailed)
                
                if model.uiDontInjectTweakLoader {
                    Toggle(isOn: $model.uiDontLoadTweakLoader) {
                        HStack {
                            LCSettingsIcon(systemName: "square.slash.fill", color: .gray)
                            Text("lc.appSettings.dontLoadTweakLoader".loc)
                        }
                    }
                }
                
            } footer: {
                Text("lc.appSettings.hideLiveContainerDesc".loc)
            }
            
            if #available(iOS 16.0, *) {
                Section {
                    Toggle(isOn: $model.uiClassicMode) {
                        HStack {
                            LCSettingsIcon(systemName: "rectangle.on.rectangle", color: .gray)
                            Text("lc.appSettings.classicMode".loc)
                        }
                    }
                } footer: {
                    Text("lc.appSettings.classicModeDesc".loc)
                }
            }
            
            Section {
                Toggle(isOn: $model.uiSpoofSDKVersion) {
                    HStack {
                        LCSettingsIcon(systemName: "hammer.fill", color: .gray)
                        Text("lc.appSettings.spoofSDKVersion".loc)
                    }
                }
            } footer: {
                Text("lc.appSettings.fspoofSDKVersionDesc".loc)
            }

            
            Section {
                Toggle(isOn: $model.uiDoSymlinkInbox) {
                    HStack {
                        LCSettingsIcon(systemName: "link", color: .blue)
                        Text("lc.appSettings.fixFilePicker".loc)
                    }
                }
            } footer: {
                Text("lc.appSettings.fixFilePickerDesc".loc)
            }
            
            Section {
                Button {
                    Task { await forceResign() }
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "signature", color: .blue)
                        Text("lc.appSettings.forceSign".loc)
                    }
                }
                .disabled(model.isAppRunning)
            } footer: {
                Text("lc.appSettings.forceSignDesc".loc)
            }
            
            Section {
                HStack {
                    Text("lc.appList.sort.lastLaunched".loc)
                    Spacer()
                    Text(formatDate(date: appInfo.lastLaunched))
                        .foregroundStyle(.gray)
                }
                HStack {
                    Text("lc.appList.sort.installationDate".loc)
                    Spacer()
                    Text(formatDate(date: appInfo.installationDate))
                        .foregroundStyle(.gray)
                }
            } header: {
                Text("lc.common.statistics")
            }

        }
        .navigationTitle(appInfo.displayName())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSchedMinSettings(); loadKeepAliveSetting() }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {
            })
        } message: {
            Text(errorInfo)
        }
        
        .textFieldAlert(
            isPresented: $renameFolderInput.show,
            title: "lc.common.enterNewFolderName".loc,
            text: $renameFolderInput.initVal,
            placeholder: "",
            action: { newText in
                renameFolderInput.close(result: newText!)
            },
            actionCancel: {_ in
                renameFolderInput.close(result: "")
            }
        )
        .alert("lc.appSettings.toSharedApp".loc, isPresented: $moveToAppGroupAlert.show) {
            Button {
                self.moveToAppGroupAlert.close(result: true)
            } label: {
                Text("lc.common.move".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                self.moveToAppGroupAlert.close(result: false)
            }
        } message: {
            Text("lc.appSettings.toSharedAppDesc".loc)
        }
        .alert("lc.appSettings.toPrivateApp".loc, isPresented: $moveToPrivateDocAlert.show) {
            Button {
                self.moveToPrivateDocAlert.close(result: true)
            } label: {
                Text("lc.common.move".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                self.moveToPrivateDocAlert.close(result: false)
            }
        } message: {
            Text("lc.appSettings.toPrivateAppDesc".loc)
        }
        .alert("lc.appSettings.forceSign".loc, isPresented: $signUnsignedAlert.show) {
            Button {
                self.signUnsignedAlert.close(result: true)
            } label: {
                Text("lc.common.ok".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                self.signUnsignedAlert.close(result: false)
            }
        } message: {
            Text("lc.appSettings.signUnsignedDesc".loc)
        }
        .alert("lc.appSettings.addExternalNonLocalContainer".loc, isPresented: $addExternalNonLocalContainerWarningAlert.show) {
            Button {
                self.addExternalNonLocalContainerWarningAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                self.addExternalNonLocalContainerWarningAlert.close(result: false)
            }
        } message: {
            Text("lc.appSettings.addExternalNonLocalContainerWarningAlert".loc)
        }
        .sheet(isPresented: $selectUnusedContainerSheetShow) {
            LCSelectContainerView(isPresent: $selectUnusedContainerSheetShow, delegate: self)
        }
        .fileImporter(isPresented: $choosingStorage, allowedContentTypes: [.folder]) { result in
            Task { await importDataStorage(result: result) }
        }
    }

    func createFolder() async {
        let newName = NSUUID().uuidString
        guard let displayName = await renameFolderInput.open(initVal: newName), displayName != "" else {
            return
        }
        let fm = FileManager()
        let dest : URL
        if model.uiIsShared {
            dest = LCPath.lcGroupDataPath.appendingPathComponent(newName)
        } else {
            dest = LCPath.dataPath.appendingPathComponent(newName)
        }
        
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        
        sharedModel.appDataFolderNames.append(newName)
        let newContainer = LCContainer(folderName: newName, name: displayName, isShared: model.uiIsShared)
        // assign keychain group
        var keychainGroupSet : Set<Int> = Set(minimumCapacity: 3)
        for i in 0..<SharedModel.keychainAccessGroupCount {
            keychainGroupSet.insert(i)
        }
        for container in model.uiContainers {
            keychainGroupSet.remove(container.keychainGroupId)
        }
        guard let freeKeyChainGroup = keychainGroupSet.randomElement() else {
            errorInfo = "lc.container.notEnoughKeychainGroup".loc
            errorShow = true
            return
        }
        
        model.uiContainers.append(newContainer)
        if model.uiSelectedContainer == nil {
            model.uiSelectedContainer = newContainer;
        }
        if model.uiDefaultDataFolder == nil {
            model.uiDefaultDataFolder = newName
            appInfo.dataUUID = newName
        }
        appInfo.containers = model.uiContainers;
        newContainer.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: freeKeyChainGroup)
    }
    
    func importDataStorage(result: Result<URL, any Error>) async {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                errorInfo = "unable to access directory, startAccessingSecurityScopedResource returns false"
                errorShow = true
                return
            }
            let path = url.path
            let fm = FileManager.default
            let _ = try fm.contentsOfDirectory(atPath: path)

            let v = try url.resourceValues(forKeys: [
                .volumeIsLocalKey,
                .volumeIsInternalKey,
            ])
            if !(v.volumeIsLocal == true && v.volumeIsInternal == true) {
                guard let doAdd = await addExternalNonLocalContainerWarningAlert.open(), doAdd else {
                    return
                }
            }
            
            guard let bookmark = LCUtils.bookmark(for: url) else {
                errorInfo = "Unable to generate a bookmark for the selected URL!"
                errorShow = true
                return
            }
            
            var container: LCContainer? = nil
            if fm.fileExists(atPath: url.appendingPathComponent("LCContainerInfo.plist").path) {
                let plistInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("LCContainerInfo.plist")), format: nil)
                if let plistInfo = plistInfo as? [String : Any] {
                    let name = plistInfo["folderName"] as? String ?? url.lastPathComponent
                    container = LCContainer(infoDict: ["folderName": url.lastPathComponent, "name": name, "bookmarkData":bookmark], isShared: false)
                }
            }
            if container == nil {
                // it's an empty folder, we assign a new keychain group to it.
                container = LCContainer(infoDict: ["folderName": url.lastPathComponent, "name": url.lastPathComponent, "bookmarkData": bookmark], isShared: false)
                // assign keychain group
                var keychainGroupSet : Set<Int> = Set(minimumCapacity: 3)
                for i in 0..<SharedModel.keychainAccessGroupCount {
                    keychainGroupSet.insert(i)
                }
                for container in model.uiContainers {
                    keychainGroupSet.remove(container.keychainGroupId)
                }
                guard let freeKeyChainGroup = keychainGroupSet.randomElement() else {
                    errorInfo = "lc.container.notEnoughKeychainGroup".loc
                    errorShow = true
                    return
                }
                
//                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if container!.bookmarkResolved {
                        container!.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: freeKeyChainGroup)
                    }
//                }
            }
            model.uiContainers.append(container!)
            appInfo.containers = model.uiContainers;
            if model.uiSelectedContainer == nil {
                model.uiSelectedContainer = container;
            }
            if model.uiDefaultDataFolder == nil {
                model.uiDefaultDataFolder = url.lastPathComponent
                appInfo.dataUUID = url.lastPathComponent
            }

        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func moveToAppGroup() async {
        for container in appInfo.containers {
            if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
                errorInfo = "lc.appSettings.appOpenInOtherLc %@ %@".localizeWithFormat(runningLC, runningLC)
                errorShow = true
                return
            }
        }
        
        guard let result = await moveToAppGroupAlert.open(), result else {
            return
        }
        
        do {
            try LCPath.ensureAppGroupPaths()

            var moves: [(URL, URL)] = [];
            moves.append((
                URL(fileURLWithPath: appInfo.bundlePath()),
                LCPath.lcGroupBundlePath.appendingPathComponent(appInfo.relativeBundlePath)
            ))
            for container in model.uiContainers {
                if container.storageBookMark != nil {
                    continue
                }
                
                moves.append((
                    LCPath.dataPath.appendingPathComponent(container.folderName),
                    LCPath.lcGroupDataPath.appendingPathComponent(container.folderName)
                ))
            }
            // 模块文件夹是 | 拼的多选：必须逐个搬，整串当一个路径搬
            // 必然撞上 sourceDoesNotExist，整个转换直接失败。
            // 磁盘上没有的目录（比如还没落盘的 CZFVPN）直接跳过，
            // 有东西的才搬，不丢、不报错；.disabled 的停用态也一起搬。
            if let tweakFolder = appInfo.tweakFolder, tweakFolder.count > 0 {
                for name in LCAppModel.czfSplitTweakFolders(tweakFolder) {
                    for candidate in [name, name + ".disabled"] {
                        let src = LCPath.tweakPath.appendingPathComponent(candidate)
                        if FileManager.default.fileExists(atPath: src.path) {
                            moves.append((src, LCPath.lcGroupTweakPath.appendingPathComponent(candidate)))
                        }
                    }
                }
            }
            
            try LCUtils.moveFilesAtomicallyAfterPreflight(moves)
            
            for container in model.uiContainers {
                if container.storageBookMark != nil {
                    continue
                }
                sharedModel.appDataFolderNames.removeAll(where: { s in
                    return s == container.folderName
                })
                container.isShared = true
            }
            
            if let tweakFolder = appInfo.tweakFolder, tweakFolder.count > 0 {
                // 注册表里存的是拆分后的单名，拿整串比永远删不掉。
                for name in LCAppModel.czfSplitTweakFolders(tweakFolder) {
                    sharedModel.tweakFolderNames.removeAll(where: { $0 == name })
                }
            }
            
            appInfo.setBundlePath(LCPath.lcGroupBundlePath.appendingPathComponent(appInfo.relativeBundlePath).path)
            appInfo.isShared = true
            model.uiIsShared = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func movePrivateDoc() async {
        for container in appInfo.containers {
            if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {                
                errorInfo = "lc.appSettings.appOpenInOtherLc %@ %@".localizeWithFormat(runningLC, runningLC)
                errorShow = true
                return
            }
        }

        guard let result = await moveToPrivateDocAlert.open(), result else {
            return
        }
        
        do {
            var moves: [(URL, URL)] = [];
            moves.append((
                URL(fileURLWithPath: appInfo.bundlePath()),
                LCPath.bundlePath.appendingPathComponent(appInfo.relativeBundlePath)
            ))
            for container in model.uiContainers {
                if container.storageBookMark != nil {
                    continue
                }
                moves.append((
                    LCPath.lcGroupDataPath.appendingPathComponent(container.folderName),
                    LCPath.dataPath.appendingPathComponent(container.folderName)
                ))
            }
            // 回搬同样逐个搬，磁盘上没有的目录跳过，.disabled 停用态一起搬。
            if let tweakFolder = appInfo.tweakFolder, tweakFolder.count > 0 {
                for name in LCAppModel.czfSplitTweakFolders(tweakFolder) {
                    for candidate in [name, name + ".disabled"] {
                        let src = LCPath.lcGroupTweakPath.appendingPathComponent(candidate)
                        if FileManager.default.fileExists(atPath: src.path) {
                            moves.append((src, LCPath.tweakPath.appendingPathComponent(candidate)))
                        }
                    }
                }
            }
            
            try LCUtils.moveFilesAtomicallyAfterPreflight(moves)
            
            for container in model.uiContainers {
                if container.storageBookMark != nil {
                    continue
                }
                sharedModel.appDataFolderNames.append(container.folderName)
            }
            if let tweakFolder = appInfo.tweakFolder, tweakFolder.count > 0 {
                for name in LCAppModel.czfSplitTweakFolders(tweakFolder) where !sharedModel.tweakFolderNames.contains(name) {
                    sharedModel.tweakFolderNames.append(name)
                }
                model.uiTweakFolder = tweakFolder
            }
            
            appInfo.setBundlePath(LCPath.bundlePath.appendingPathComponent(appInfo.relativeBundlePath).path)
            appInfo.isShared = false
            model.uiIsShared = false
            for container in model.uiContainers {
                container.isShared = false
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func loadSupportedLanguages() {
        do {
            try model.loadSupportedLanguages()
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
    }
    
    func toggleHidden() async {
        await model.toggleHidden()
    }
    
    func forceResign() async {
        if model.uiDontSign {
            guard let result = await signUnsignedAlert.open(), result else {
                return
            }
            model.uiDontSign = false
        }
        
        do {
            try await model.forceResign()
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func formatDate(date: Date?) -> String {
        guard let date else {
            return "lc.common.unknown".loc
        }
        
        let formatter1 = DateFormatter()
        formatter1.dateStyle = .short
        formatter1.timeStyle = .medium
        return formatter1.string(from: date)
    
    }
}



extension LCAppSettingsView : LCContainerViewDelegate {
    func getBundleId() -> String {
        return model.appInfo.bundleIdentifier()!
    }
    
    func unbindContainer(container: LCContainer) {
        model.uiContainers.removeAll { c in
            c === container
        }
        
        // if the deleted container is the default one, we change to another one
        if container.folderName == model.uiDefaultDataFolder && !model.uiContainers.isEmpty{
            setDefaultContainer(container: model.uiContainers[0])
        }
        // if the deleted container is the selected one, we change to the default one
        if model.uiSelectedContainer === container && !model.uiContainers.isEmpty {
            for container in model.uiContainers {
                if container.folderName == model.uiDefaultDataFolder {
                    model.uiSelectedContainer = container
                    break
                }
            }
        }
        
        if model.uiContainers.isEmpty {
            model.uiSelectedContainer = nil
            model.uiDefaultDataFolder = nil
            appInfo.dataUUID = nil
        }
        appInfo.containers = model.uiContainers
    }
    
    func setDefaultContainer(container newDefaultContainer: LCContainer ) {
        if model.uiSelectedContainer?.folderName == model.uiDefaultDataFolder {
            model.uiSelectedContainer = newDefaultContainer
        }
        
        appInfo.dataUUID = newDefaultContainer.folderName
        model.uiDefaultDataFolder = newDefaultContainer.folderName
    }
    
    func saveContainer(container: LCContainer) {
        container.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: container.keychainGroupId)
        appInfo.containers = model.uiContainers
        model.objectWillChange.send()
    }
    
    func getSettingsBundle() -> Bundle? {
        return Bundle(url: URL(fileURLWithPath: appInfo.bundlePath()).appendingPathComponent("Settings.bundle"))
    }
    
    func getContainerURL(container: LCContainer) -> URL {
        let preferencesFolderUrl = container.containerURL.appendingPathComponent("Library/Preferences")
        let fm = FileManager.default
        do {
            let doExist = fm.fileExists(atPath: preferencesFolderUrl.path)
            if !doExist {
                try fm.createDirectory(at: preferencesFolderUrl, withIntermediateDirectories: true)
            }

        } catch {
            errorInfo = "Cannot create Library/Preferences folder!".loc
            errorShow = true
        }
        return container.containerURL
    }
    
}

extension LCAppSettingsView : LCSelectContainerViewDelegate {
    func addContainers(containers: Set<String>) {
        if containers.count + model.uiContainers.count > SharedModel.keychainAccessGroupCount {
            errorInfo = "lc.container.tooMuchContainers".loc
            errorShow = true
            return
        }
        
        for folderName in containers {
            let newContainer = LCContainer(folderName: folderName, name: folderName, isShared: false)
            newContainer.loadName()
            if newContainer.keychainGroupId == -1 {
                // assign keychain group for old containers
                var keychainGroupSet : Set<Int> = Set(minimumCapacity: SharedModel.keychainAccessGroupCount)
                for i in 0..<SharedModel.keychainAccessGroupCount {
                    keychainGroupSet.insert(i)
                }
                for container in model.uiContainers {
                    keychainGroupSet.remove(container.keychainGroupId)
                }
                guard let freeKeyChainGroup = keychainGroupSet.randomElement() else {
                    errorInfo = "lc.container.notEnoughKeychainGroup".loc
                    errorShow = true
                    return
                }
                newContainer.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: freeKeyChainGroup)
            }

            
            model.uiContainers.append(newContainer)
            if model.uiSelectedContainer == nil {
                model.uiSelectedContainer = newContainer;
            }
            if model.uiDefaultDataFolder == nil {
                model.uiDefaultDataFolder = folderName
                appInfo.dataUUID = folderName
            }


        }
        appInfo.containers = model.uiContainers;

    }
}
