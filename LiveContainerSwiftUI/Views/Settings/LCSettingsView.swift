//
//  LCSettingsView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UserNotifications

enum JITEnablerType : Int, CaseIterable, Identifiable {
    var id: Int { rawValue }
    case SideJITServer = 0
    case StikJIT = 1
    case JITStreamerEBLegacy = 2
    case StikJITLC = 3
    case SideStore = 4
    case StosDebug = 5
    case StosDebugLC = 6
    
    var displayName: String {
        switch self {
        case .StikJIT: "StikDebug"
        case .StikJITLC: "StikDebug (Another LiveContainer/Multitask)"
        case .StosDebug: "StosDebug"
        case .StosDebugLC: "StosDebug (Another LiveContainer/Multitask)"
        case .SideStore: "SideStore"
        case .JITStreamerEBLegacy: "JitStreamer-EB (Relaunch)"
        case .SideJITServer: "SideJITServer/JITStreamer 2.0"
        }
    }
}

/// 设置行图标（参考 Minis 设置页语言）：白 glyph + 彩色圆底 30pt，
/// 跟行高走，Form 里图标列自然对齐。只加在单行简单行上
/// （按钮/链接/开关/选择器），多行自定义布局（节点列表、签名
/// 到期行、订阅行）不动，免得挤坏原有排版。二级页面共用此组件。
struct LCSettingsIcon: View {
    let systemName: String
    let color: Color
    var body: some View {
        Image(systemName: systemName)
            // 第三批低 #62：字号改相对字号（subheadline 约 15pt，
            // 与原来一致），跟随动态类型；框仍 30×30。
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
            .background(color)
            .clipShape(Circle())
    }
}

struct LCSettingsView: View {
    @State var errorShow = false
    @State var errorInfo = ""
    @State var successShow = false
    @State var successInfo = ""

    @State private var certificateDataFound = false

    // 续签区已整段删掉（2026-10-29 用户亲定“没什么用”）：
    // 一键续签只是跳 SideInstaller 🅥 走 refresh-all，企业证书
    // 的 App 本来就会被跳过续不到，到期日列表也只是只读展示。
    // CZFSignatureExpiry 工具文件还在仓里、未被引用，之后要
    // 恢复续签区时可直接复用，不用重写读取逻辑。

    @StateObject private var certificateImportAlert = YesNoHelper()
    @StateObject private var certificateImportFromBuiltInSideStoreAlert = YesNoHelper()
    @StateObject private var certificateRemoveAlert = YesNoHelper()
    @StateObject private var nukeSideStoreAlert = YesNoHelper()
    @StateObject private var certificateImportFileAlert = AlertHelper<URL>()
    @StateObject private var certificateImportPasswordAlert = InputHelper()
    
    @AppStorage("LCFrameShortcutIcons") var frameShortIcon = false
    @AppStorage("LCSwitchAppWithoutAsking") var silentSwitchApp = false
    @AppStorage("LCOpenWebPageWithoutAsking") var silentOpenWebPage = false
    @AppStorage("LCDontSignApp", store: LCUtils.appGroupUserDefault) var dontSignApp = false
    @AppStorage("LCStrictHiding", store: LCUtils.appGroupUserDefault) var strictHiding = false
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    @AppStorage("LCSideJITServerAddress", store: LCUtils.appGroupUserDefault) var sideJITServerAddress : String = ""
    @AppStorage("LCDeviceUDID", store: LCUtils.appGroupUserDefault) var deviceUDID: String = ""
    @AppStorage("LCJITEnablerType", store: LCUtils.appGroupUserDefault) var JITEnabler: JITEnablerType = .SideJITServer
    
    @State var store : Store = .Unknown
    
    @AppStorage("LCLoadTweaksToSelf") var injectToLCItelf = false
    @AppStorage("LCIgnoreJITOnLaunch") var ignoreJITOnLaunch = false
    @AppStorage("LCSelected32BitEmulator", store: LCUtils.appGroupUserDefault) var selected32BitEmulator : String = ""
    @AppStorage("LCKeepSelectedWhenQuit") var keepSelectedWhenQuit = false
    @AppStorage("LCWaitForDebugger") var waitForDebugger = false
    // 保活默认开：掉线根因——开关存在 UserDefaults 里，删了
    // 重装就归零；以前开着时全局注入、切后台不掉线，重装后
    // 开关回到关、打开设置页时 onAppear 还会把 dylib 删掉，
    // 之后一切换后台就被系统挂起断网。默认开 + 启动同步，
    // 重装后第一次启动即恢复保活；不想保活再手动关
    @AppStorage("LCKeepAliveEnabled") var keepAliveEnabled = true
    // 宿主通知授权状态（CZF，2026-10-29 通知恢复）：
    // 游客通知以宿主身份发出，系统里 LiveContainer 没授权，
    // 通知就会静默丢掉；这行就是让用户一眼看到授权状态、
    // 点一下补申请或跳系统设置。
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    // App 内更新检查（CZF，2026-10-29）：查 fork 自己的 update release
    // release，对比本机 LCVersionInfo 里的短提交号；有新版不
    // 自己下载安装（侧载 App 换不了自己的包），而是跳
    // sideinstaller://install?url=，由 SideInstaller 🅥 下载、
    // 签名、覆盖安装，SideInstaller 那边还会再弹一次确认。
    @State private var updateStatusText = "点一下检查"
    @State private var updateChecking = false
    @State private var updateInfo: CZFUpdateInfo?
    // 3.8.450：点版本页脚出作者信息——单击出作者 sheet，5 下进开发者模式；
    // 单击要等 0.35 秒确认不是连点，避免 sheet 弹出来挡住后 4 下。
    @State private var czfShowAuthorSheet = false
    @State private var czfVersionTapCount = 0
    @State private var czfVersionTapWorkItem: DispatchWorkItem?
    private func startUpdateCheck() {
        guard !updateChecking else { return }
        updateChecking = true
        updateStatusText = "检查中…"
        CZFUpdateCheck.check { result in
            DispatchQueue.main.async {
                updateChecking = false
                switch result {
                case .failure:
                    updateInfo = nil
                    updateStatusText = "检查失败，点一下重试"
                case .success(let info):
                    // #14：current 为 nil 时不要断言有新版
                    if let current = CZFUpdateCheck.currentCommit() {
                        if current == info.commit {
                            updateInfo = nil
                            updateStatusText = "已是最新（\(current)）"
                        } else {
                            updateInfo = info
                            var text = "有新版：\(info.commit)"
                            if let date = info.publishedAt {
                                let formatter = DateFormatter()
                                formatter.dateFormat = "yyyy-MM-dd"
                                text += " · \(formatter.string(from: date))"
                            }
                            updateStatusText = text
                            // 3.8.445（用户 13:53 令“点击检查更新
                            // 自动更新”）：查到新版直接跳 SideInstaller
                            // 安装，不用再点“去 SideInstaller 更新”。
                            // SideInstaller 没装时 open 回调报失败、
                            // 弹提示，下面两行跳转按钮还在，可手动点
                            // Seal。
                            openSideInstallerInstall()
                        }
                    } else {
                        updateInfo = nil
                        updateStatusText = "无法确认当前版本"
                    }
                }
            }
        }
    }
    private func openSideInstallerInstall() {
        guard let info = updateInfo else { return }
        var components = URLComponents()
        components.scheme = "sideinstaller"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: info.downloadURL.absoluteString)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                errorInfo = "没能打开 SideInstaller 🅥，请确认它已安装"
                errorShow = true
            }
        }
    }
    // 去 Seal 更新：照抄 openSideInstallerInstall，只换 scheme。
    // Seal 注册了 seal 和 sidestore 两个 scheme，用户定用
    // sidestore://install?url= 这个格式，不要自创 seal://。
    private func openSealInstall() {
        guard let info = updateInfo else { return }
        var components = URLComponents()
        components.scheme = "sidestore"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: info.downloadURL.absoluteString)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                errorInfo = "没能打开 Seal，请确认它已安装"
                errorShow = true
            }
        }
    }
    private var notificationAuthText: String {
        switch notificationAuthStatus {
        case .authorized: return "已开启"
        case .denied: return "已关闭"
        case .notDetermined: return "未申请"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时"
        @unknown default: return "未知"
        }
    }
    private func refreshNotificationAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { notificationAuthStatus = settings.authorizationStatus }
        }
    }
    @AppStorage("LCSharePrivateDataWithLiveProcess") var sharePrivateDataWithLiveProcess = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var isViewAppeared = false

    let storeName = LCUtils.getStoreName()
    
    init() {
        _certificateDataFound = State(initialValue: LCSharedUtils.certificatePassword() != nil)
        _store = State(initialValue: LCUtils.store())
    }
    

    var body: some View {
        NavigationView {
            Form {
                jitLessSection
                multiLCSection
                jitSection
                emulatorSection
                interfaceSection
                miscSection
                notificationSection
                storageSection
                keepAliveSection
                aboutSection
                versionFooter
                developerSection
            }
            .navigationBarTitle("lc.tabView.settings".loc)
            // B-12：32 位 App 全删光、段隐藏时，残留的
            // selected32BitEmulator 选值在 UI 上没处清。
            // arm32EmuApps 变空就清掉，日后装回 32 位 App
            // 时段重现、Picker 从“无”开始，不读旧值报错。
            .onChange(of: sharedModel.arm32EmuApps.isEmpty) { isEmpty in
                if isEmpty {
                    selected32BitEmulator = ""
                }
            }
            .alert("lc.common.error".loc, isPresented: $errorShow){
            } message: {
                Text(errorInfo)
            }
            .alert("lc.common.success".loc, isPresented: $successShow){
            } message: {
                Text(successInfo)
            }
            .alert("lc.settings.importCertificate".loc, isPresented: $certificateImportAlert.show) {
                Button {
                    certificateImportAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }

                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateImportAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.importCertificateDesc".loc)
            }
            .alert("lc.settings.removeCertificate".loc, isPresented: $certificateRemoveAlert.show) {
                Button(role: .destructive) {
                    certificateRemoveAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }

                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateRemoveAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.removeCertificateDesc".loc)
            }
            .alert("lc.settings.nukeSideStore".loc, isPresented: $nukeSideStoreAlert.show) {
                Button(role: .destructive) {
                    nukeSideStoreAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }

                Button("lc.common.cancel".loc, role: .cancel) {
                    nukeSideStoreAlert.close(result: false)
                }
            } message: {
                Text("将删除 SideStore 的 Database 与 Apps 目录，此操作不可撤销，要继续吗？")
            }
            .alert("lc.settings.importCertFromBuiltinSideStore".loc, isPresented: $certificateImportFromBuiltInSideStoreAlert.show) {
                Button {
                    certificateImportFromBuiltInSideStoreAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateImportFromBuiltInSideStoreAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.importCertFromBuiltinSideStoreDesc".loc)
            }
            .betterFileImporter(isPresented: $certificateImportFileAlert.show, types: [.p12], multiple: false, callback: { fileUrls in
                certificateImportFileAlert.close(result: fileUrls[0])
            }, onDismiss: {
                certificateImportFileAlert.close(result: nil)
            })
            .textFieldAlert(
                isPresented: $certificateImportPasswordAlert.show,
                title: "lc.settings.importCertificateInputPassword".loc,
                text: $certificateImportPasswordAlert.initVal,
                placeholder: "",
                action: { newText in
                    certificateImportPasswordAlert.close(result: newText)
                },
                actionCancel: {_ in
                    certificateImportPasswordAlert.close(result: nil)
                    certificateImportPasswordAlert.show = false
                }
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear() {
            if !isViewAppeared {
                guard sharedModel.selectedTab == .settings, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .settings, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }

    // MARK: - 设置页分段（纯拆分：各段原样出自 body，行为不动）
    @ViewBuilder private var jitLessSection: some View {
        if sharedModel.multiLCStatus != 2 {
            Section{
                if !certificateDataFound {
                    Button {
                        Task{ await importCertificate() }
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "square.and.arrow.down", color: .blue)
                            Text("lc.settings.importCertificate".loc)
                        }
                    }
                } else {
                    Button {
                        Task{ await removeCertificate() }
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "trash", color: .red)
                            Text("lc.settings.removeCertificate".loc)
                        }
                    }
                }
                if store == .AltStore || store == .SideStore {
                    Button {
                        Task{ await importCertificateFromSideStore() }
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "arrow.clockwise", color: .blue)
                            if certificateDataFound {
                                Text("lc.settings.refreshCertificateFromStore %@".localizeWithFormat(storeName))
                            } else {
                                Text("lc.settings.importCertificateFromStore %@".localizeWithFormat(storeName))
                            }
                        }
                    }
                }

                NavigationLink {
                    LCJITLessDiagnoseView()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "wrench.and.screwdriver", color: .gray)
                        Text("lc.settings.jitlessDiagnose".loc)
                    }
                }

            } header: {
                Text("lc.settings.jitLess".loc)
            } footer: {
                Text("lc.settings.jitLessDesc".loc)
            }
        }
    }

    @ViewBuilder private var multiLCSection: some View {
        if (store != .Unknown && store != .ADP) || LCUtils.isAppGroupAltStoreLike() {
            Section{
                NavigationLink {
                    LCMultiLCManagementView()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "apps.iphone", color: .blue)
                        if sharedModel.multiLCStatus == 0 {
                            Text("lc.settings.multiLC".loc)
                        } else if sharedModel.multiLCStatus == 2 {
                            Text("lc.settings.multiLCIsSecond".loc)
                        }
                    }
                }
                .disabled(sharedModel.multiLCStatus == 2)

                if(sharedModel.multiLCStatus == 2) {
                    NavigationLink {
                        LCJITLessDiagnoseView()
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "wrench.and.screwdriver", color: .gray)
                            Text("lc.settings.jitlessDiagnose".loc)
                        }
                    }
                }
            } footer: {
                Text("lc.settings.multiLCDesc".loc)
            }
        }
    }

    @ViewBuilder private var jitSection: some View {
        Section {
            if JITEnabler == .SideJITServer || JITEnabler == .JITStreamerEBLegacy {
                HStack {
                    LCSettingsIcon(systemName: "globe", color: .blue)
                    Text("lc.settings.JitAddress".loc)
                    Spacer()
                    TextField(JITEnabler == .SideJITServer ? "http://x.x.x.x:8080" : "http://[fd00::]:9172", text: $sideJITServerAddress)
                        .multilineTextAlignment(.trailing)
                }
            }
            if JITEnabler == .SideJITServer {
                HStack {
                    LCSettingsIcon(systemName: "iphone", color: .gray)
                    Text("lc.settings.JitUDID".loc)
                    Spacer()
                    TextField("lc.settings.JitUDID".loc, text: $deviceUDID)
                        .multilineTextAlignment(.trailing)
                }
            }
            Picker(selection: $JITEnabler) {
                ForEach(JITEnablerType.allCases) { enablerType in
                    Text(enablerType.displayName).tag(enablerType)
                }
            } label: {
                HStack {
                    LCSettingsIcon(systemName: "bolt.fill", color: .orange)
                    Text("lc.settings.jitEnabler".loc)
                }
            }

        } header: {
            Text("JIT")
        } footer: {
            Text("lc.settings.JitDesc".loc)
        }
    }

    @ViewBuilder private var emulatorSection: some View {
        // 精简（7）：没有 32 位 App 时不显示——选择器里只剩
        // “无”，占一整段没意义；有 32 位 App 时再出现。
        if !sharedModel.arm32EmuApps.isEmpty {
            Section {
                Picker(selection: $selected32BitEmulator) {
                    Text("lc.common.none".loc).tag("")
                    ForEach(sharedModel.arm32EmuApps, id: \.self) { app in
                        Text(app.appInfo.displayName()).tag(app.appInfo.relativeBundlePath ?? "")
                    }
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "cpu", color: .purple)
                        Text("lc.settings.selected32BitEmulator".loc)
                    }
                }
            } header: {
                Text("模拟器")
            } footer: {
                // #16：单 App 优先于全局（LCBootstrap.m:636 先读单 App 的值）
                Text("单 App 设置优先于全局设置")
            }
        }
    }

    @ViewBuilder private var interfaceSection: some View {
        // 界面区：说明从 footer 挪到各行下面的小字，
        // 深色图标那行原来没有说明（footer 只讲动态颜色），
        // 现在补上“横幅用 App 的深色图标”，两行说明各对各行。
        Section{
            Toggle(isOn: $dynamicColors) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        LCSettingsIcon(systemName: "paintpalette.fill", color: .purple)
                        Text("lc.settings.dynamicColors".loc)
                    }
                    Text("lc.settings.dynamicColors.desc".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if #available(iOS 18.0, *) {
                Toggle(isOn: $darkModeIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "moon.fill", color: .indigo)
                            Text("lc.settings.darkModeIcon".loc)
                        }
                        Text("App 横幅用 App 的深色图标")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("lc.settings.interface".loc)
        }
    }

    @ViewBuilder private var miscSection: some View {
        // 杂项区：原来 5 个开关各占一个 Section、每段带一段
        // footer 说明，竖着占 5 段；并成一段，说明挪到各行
        // 下面的小字，意思一句不少。“清除通知”原来也单独
        // 占一段，顺手并进这一段的末尾。#20：严格隐藏那行
        // 锁定状态下也显示（置灰并注明需先解锁），不再消失。
        // 3.8.450（用户 23:40 令“杂项改成杂项设置，折叠起来只
        // 显示多任务一个”）：段名改“杂项设置”，5 个开关收进
        // “更多设置”折叠组默认合上，只留多任务一行；多任务
        // 仍是直达链接，点进多任务设置页。
        Section{
            // 多任务：折叠后唯一可见的一行，直达多任务设置页。
            // 精简（7）：多任务设置原来单独占一段（一个链接 +
            // 一段 footer），并进杂项当一行，说明挪到行下小字。
            if #available(iOS 16.1, *) {
                NavigationLink {
                    LCMultitaskSettingView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "rectangle.stack", color: .purple)
                            Text("lc.appBanner.multitask".loc)
                        }
                        Text("lc.settings.multitaskDesc".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("更多设置") {
                Toggle(isOn: $frameShortIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "plus.app", color: .green)
                            Text("lc.settings.FrameIcon".loc)
                        }
                        Text("lc.settings.FrameIconDesc".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $silentSwitchApp) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "eye.slash", color: .gray)
                            Text("lc.settings.silentSwitchApp".loc)
                        }
                        Text("lc.settings.silentSwitchAppDesc".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $silentOpenWebPage) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "globe", color: .teal)
                            Text("lc.settings.silentOpenWebPage".loc)
                        }
                        Text("lc.settings.silentOpenWebPageDesc".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // #20：锁定状态下也显示该行（置灰并注明需先解锁），
                // 否则重新锁定后开关消失、无法关掉已开启的严格隐藏。
                Toggle(isOn: $strictHiding) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "hand.raised.fill", color: .red)
                            Text("lc.settings.strictHiding".loc)
                        }
                        Text("lc.settings.strictHidingDesc".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !sharedModel.isHiddenAppUnlocked {
                            Text("需先解锁隐藏 App 才能更改")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!sharedModel.isHiddenAppUnlocked)
                Toggle(isOn: $dontSignApp) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "signature", color: .orange)
                            Text("lc.settings.dontSign".loc)
                        }
                        Text("lc.settings.dontSignDesc".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("杂项设置")
        }
    }

    // 设置页整齐化（3.8.440，用户 12:49 令“太乱”）：杂项
    // 原来 8 行混在一起（5 个开关 + 清除通知 + 通知权限 +
    // 多任务），一屏装不下、看着像杂物堆。通知两行单拎
    // 出来成段，杂项只剩 App 行为开关 + 多任务。
    @ViewBuilder private var notificationSection: some View {
        Section {
            Button {
                clearNotifications()
            } label: {
                HStack {
                    LCSettingsIcon(systemName: "bell.slash.fill", color: .red)
                    Text("lc.settings.clearNotifications".loc)
                }
            }
            // 通知权限行：状态从系统实时读；未申请点一下
            // 直接申请，已拒绝点一下跳系统设置，已开启不
            // 显示按钮。从系统设置回来时刷新一次状态。
            HStack {
                LCSettingsIcon(systemName: "bell.fill", color: .orange)
                Text("通知权限")
                Spacer()
                Text(notificationAuthText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // 第三批低 #44：临时授权时再点“开启”无变化（已是
                // 临时授权，再申请也不会变），改成“去设置”，让
                // 用户去系统设置改；只有未申请时才显示“开启”。
                if notificationAuthStatus == .notDetermined {
                    Button("开启") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                            refreshNotificationAuth()
                        }
                    }
                    .buttonStyle(.borderless)
                } else if notificationAuthStatus == .denied || notificationAuthStatus == .provisional || notificationAuthStatus == .ephemeral {
                    Button("去设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onAppear { refreshNotificationAuth() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                refreshNotificationAuth()
            }
        } header: {
            Text("通知")
        }
    }

    @ViewBuilder private var storageSection: some View {
        Section {
            if sharedModel.multiLCStatus != 2 {
                NavigationLink {
                    LCStorageManagementView()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "externaldrive.fill", color: .blue)
                        Text("lc.settings.storageManagement".loc)
                    }
                }
            }
            NavigationLink {
                LCDataManagementView()
            } label: {
                HStack {
                    LCSettingsIcon(systemName: "folder.fill", color: .green)
                    Text("lc.settings.dataManagement".loc)
                }
            }
        }
    }

    @ViewBuilder private var keepAliveSection: some View {
        Section(header: Text("后台保活"), footer: Text("总开关：关掉后所有 App 都不保活。单 App 页可单独设置保活白名单（只有名单里的 App 保活）；改完需重开 App 生效。")) {
            Toggle(isOn: $keepAliveEnabled) {
                HStack {
                    LCSettingsIcon(systemName: "heart.fill", color: .red)
                    Text("保活（无声音频）")
                }
            }
            .onChange(of: keepAliveEnabled) { newValue in
                // R-10：写键 + 同步 + 刷新走共用 setKeepAlive。
                Self.setKeepAlive(newValue)
            }
            .onAppear {
                // R-10：同款（进页补齐/更新一次）。
                Self.setKeepAlive(keepAliveEnabled)
            }
        }
    }



    @ViewBuilder private var aboutSection: some View {
        Section {
            // 3.8.456（用户 21:34 令“关于作者隐藏到更新里面”）：
            // 关于段平时只显示“检查更新”一行；点检查更新后有新版
            // 时，下面两行跳转按钮一起出现，没新版时不显示。
            // 3.8.450：三条作者链接已搬到版本页脚（点版本号出 sheet）。
            Button {
                startUpdateCheck()
            } label: {
                HStack {
                    LCSettingsIcon(systemName: "arrow.down.circle", color: .blue)
                    Text("检查更新")
                    Spacer()
                    Text(updateStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(updateChecking)
            if updateInfo != nil {
                Button {
                    openSideInstallerInstall()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "arrow.clockwise.circle", color: .green)
                        Text("去 SideInstaller 更新")
                    }
                }
                Button {
                    openSealInstall()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "arrow.clockwise.circle", color: .green)
                        Text("去 Seal 更新")
                    }
                }
                Text("点更新会跳到 SideInstaller 🅥 下载安装，安装时会关闭 LiveContainer，装好后重新打开；更新前建议先在数据管理里备份一次。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // 3.8.450：三条作者链接搬到版本页脚——点“解剖自我 🅥
                // LiveContainer 版本号”弹出作者 sheet，不再藏在更新里。
            }
        } header: {
            Text("lc.settings.about".loc)
        } footer: {
            Text("lc.settings.warning".loc)
        }
    }

    @ViewBuilder private var versionFooter: some View {
        // 3.8.322 液体化繁为简：VStack + systemGroupedBackground
        // 是多余的——Form 本来就是分组底色，再套一层没意义；
        // 只留文字，居中、灰字、点 5 下进开发者模式，一字不动。
        // 3.8.450：单击出作者 sheet（三条作者链接搬到这里），5 下
        // 进开发者模式——单击等 0.35 秒确认不是连点，免得 sheet
        // 弹出来挡住后 4 下；5 下连点直接进开发者模式不出 sheet。
        Text(LCUtils.getVersionInfo())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .onTapGesture {
                czfVersionTapCount += 1
                czfVersionTapWorkItem?.cancel()
                if czfVersionTapCount >= 5 {
                    czfVersionTapCount = 0
                    czfVersionTapWorkItem = nil
                    sharedModel.developerMode = true
                } else {
                    let workItem = DispatchWorkItem {
                        czfVersionTapCount = 0
                        czfShowAuthorSheet = true
                    }
                    czfVersionTapWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
                }
            }
            // 第三批低 #57：点 5 下进开发者模式没有无障碍入口，
            // VoiceOver 用户无法触发，补一个 accessibilityAction。
            .accessibilityAction {
                sharedModel.developerMode = true
            }
            .listRowInsets(EdgeInsets())
            .sheet(isPresented: $czfShowAuthorSheet) {
                czfAuthorSheet
            }
    }

    @ViewBuilder private var czfAuthorSheet: some View {
        // 3.8.450：作者信息 sheet——点版本页脚弹出，三条链接
        // 原样从 aboutSection 的“关于作者”搬过来。
        NavigationView {
            List {
                Button {
                    openGitHub()
                } label: {
                    HStack {
                        Image("GitHub")
                            .resizable()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text("LiveContainer/LiveContainer")
                    }
                }
                Button {
                    openTwitter()
                } label: {
                    HStack {
                        Image("Twitter")
                            .resizable()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text("khanhduytran0")
                    }
                }
                Button {
                    openGitHub2()
                } label: {
                    HStack {
                        Image("GitHub")
                            .resizable()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text("Huge_Black")
                    }
                }
            }
            .navigationTitle("关于作者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        czfShowAuthorSheet = false
                    }
                }
            }
        }
    }

    @ViewBuilder private var developerSection: some View {
        if sharedModel.developerMode {
            Section {
                // 第三批低 #43：退出开发者模式的开关。开着表示
                // 正在开发者模式，关掉即退出（本区随之收起）。
                Toggle(isOn: $sharedModel.developerMode) {
                    HStack {
                        LCSettingsIcon(systemName: "wrench.fill", color: .gray)
                        Text("开发者模式")
                    }
                }
                Toggle(isOn: $injectToLCItelf) {
                    HStack {
                        LCSettingsIcon(systemName: "wrench.and.screwdriver", color: .gray)
                        Text("lc.settings.injectLCItself".loc)
                    }
                }
                Toggle(isOn: $ignoreJITOnLaunch) {
                    HStack {
                        LCSettingsIcon(systemName: "bolt.slash.fill", color: .orange)
                        Text("lc.settings.ignoreJITOnLaunch".loc)
                    }
                }
                Toggle(isOn: $keepSelectedWhenQuit) {
                    HStack {
                        LCSettingsIcon(systemName: "pin.fill", color: .blue)
                        Text("lc.settings.keepSelectedAppOnQuit".loc)
                    }
                }
                Toggle(isOn: $waitForDebugger) {
                    HStack {
                        LCSettingsIcon(systemName: "eye.fill", color: .gray)
                        Text("lc.settings.waitForDebugger".loc)
                    }
                }
                Toggle(isOn: $sharePrivateDataWithLiveProcess) {
                    HStack {
                        LCSettingsIcon(systemName: "lock.fill", color: .red)
                        Text("lc.settings.allowPrivateDataAccess".loc)
                    }
                }
                Button {
                    export()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "key.fill", color: .blue)
                        Text("lc.settings.exportCert".loc)
                    }
                }
                Button {
                    exportDyld()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "doc.fill", color: .gray)
                        Text("lc.settings.exportDyld".loc)
                    }
                }
                Button {
                    Task { await nukeSideStore() }
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "trash", color: .red)
                        Text("lc.settings.nukeSideStore".loc)
                    }
                }
                Button {
                    exportMainBundle()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "doc.on.doc", color: .blue)
                        Text("lc.settings.exportMainBundle".loc)
                    }
                }
                Button {
                    resetSymbolOffsets()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "arrow.clockwise", color: .orange)
                        Text("lc.settings.resetSymbolOffsets".loc)
                    }
                }
                // FLEX 行原来是没装也显示、只是置灰点不动；
                // 没装 FLEX 的机器上这行永远用不上，改成没装
                // 就不显示这行，有装才出现。注意：只是这一行
                // 隐藏，开发者区其他按钮不受影响。
                if NSClassFromString("FLEXManager") != nil {
                    Button {
                        presentFLEXOverlay()
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "magnifyingglass", color: .purple)
                            Text("lc.settings.showFlexOverlay".loc)
                        }
                    }
                }
            } header: {
                Text("lc.settings.developerSettings".loc)
            } footer: {
                Text("lc.settings.injectLCItselfDesc".loc)
            }
        }
    }
    
    // 保活开关同步：开 → 把内置保活 dylib 放入全局 Tweaks 根目录并签名（没签名游客进程加载不了）；
    // 关 → 移出。onAppear 时也会调用一次，补齐/更新文件。
    // 静态版供 App 启动时同步：只靠设置页 onAppear 的话，
    // 重装后用户不打开设置页、保活就一直没部署。
    // 设置页不再强制重签：走 forceSign: false + 按 Team 分键
    // 指纹表（见静态版注释），已验且队没换就跳过。
    func syncKeepAliveTweak(enabled: Bool) {
        Self.syncKeepAliveTweak(enabled: enabled, forceSign: false)
    }

    // R-10：保活总开关三处共用——写键 + 同步 dylib + 刷新保活。
    // 设置页 Toggle、Dock 快捷行按钮、保活快捷页 Toggle 三处只调
    // 它，不再各写一遍（开关本身仍是各处的 @AppStorage，同一把
    // 键，写 UserDefaults 即同步到三处）。
    static func setKeepAlive(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "LCKeepAliveEnabled")
        syncKeepAliveTweak(enabled: enabled, forceSign: false)
        CZFHostKeepAlive.shared.refresh()
    }

    static func syncKeepAliveTweak(enabled: Bool, forceSign: Bool) {
        let fm = FileManager.default
        guard let src = Bundle.main.url(forResource: "CZFKeepAlive", withExtension: "dylib") else { return }
        var copied = false
        for folder in [LCPath.tweakPath, LCPath.lcGroupTweakPath] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent("CZFKeepAlive.dylib")
            if enabled {
                // 同手势插件部署：比内容不比大小，防同体积新构建部署不出去
                let srcData = try? Data(contentsOf: src)
                let destData = try? Data(contentsOf: dest)
                if destData != srcData {
                    try? fm.removeItem(at: dest)
                    if (try? fm.copyItem(at: src, to: dest)) != nil {
                        copied = true
                    }
                }
            } else {
                try? fm.removeItem(at: dest)
            }
        }
        if enabled {
            // 签名决策（forceSign: false 时走指纹表，不再逢来必签）：
            // forceSign=true（旧强制路）或刚拷了新文件 → force:true
            // 实签（新文件必须签，in-run 已验集不能挡它）；
            // forceSign=false 且文件未变 → force:false，交给
            // signTweaksImpl 的按 Team 分键指纹表
            // （LCVerifiedTweakFingerprints_<teamId>_v2，文件
            // 大小+修改时间）：只有当前 Team 的指纹对上才跳过，
            // 队换/指纹缺失/Team 取不到一律实签并记到当前 Team
            // 的表里。绝不用通用验签当本 Team 签过（见
            // signTweaksImpl 注释）；启动同步同函数受益：队换后
            // 文件未变也会重签（旧队残留自愈），已验且未变时
            // 仍跳过，不拖启动。
            let force = forceSign || copied
            Task {
                try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: force)
                try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.lcGroupTweakPath, force: force)
            }
        }
    }

    /// 启动同步保活：读开关（没存过 = 默认开），部署/移除
    /// dylib。App 启动即做，不等用户打开设置页
    static func syncKeepAliveAtLaunch() {
        let enabled = UserDefaults.standard.object(forKey: "LCKeepAliveEnabled") as? Bool ?? true
        syncKeepAliveTweak(enabled: enabled, forceSign: false)
    }

    func openGitHub() {
        UIApplication.shared.open(URL(string: "https://github.com/LiveContainer/LiveContainer")!)
    }

    func openGitHub2() {
        UIApplication.shared.open(URL(string: "https://github.com/hugeBlack")!)
    }

    func openTwitter() {
        UIApplication.shared.open(URL(string: "https://twitter.com/khanhduytran0")!)
    }

    func clearNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
        if #available(iOS 16.0, *) {
            notificationCenter.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        successInfo = "通知已清除"
        successShow = true
    }

    func export() {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        var failures: [String] = []

        // 1. Copy embedded.mobileprovision from the main bundle to Documents
        if let embeddedURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
            let destinationURL = documentsURL.appendingPathComponent("embedded.mobileprovision")
            do {
                // #21：写前先删已存在的目标文件，否则第二次导出 copyItem 必抛错
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: embeddedURL, to: destinationURL)
                print("Successfully copied embedded.mobileprovision to Documents.")
            } catch {
                print("Error copying embedded.mobileprovision: \(error)")
                failures.append("embedded.mobileprovision 复制失败：\(error.localizedDescription)")
            }
        } else {
            print("embedded.mobileprovision not found in the main bundle.")
            failures.append("embedded.mobileprovision 未找到")
        }

        // 2. Read "certData" from UserDefaults and save to cert.p12 in Documents
        if let certData = LCUtils.certificateData() {
            let certFileURL = documentsURL.appendingPathComponent("cert.p12")
            do {
                try certData.write(to: certFileURL)
                print("Successfully wrote certData to cert.p12 in Documents.")
            } catch {
                print("Error writing certData to cert.p12: \(error)")
                failures.append("cert.p12 写入失败：\(error.localizedDescription)")
            }
        } else {
            print("certData not found in UserDefaults.")
            failures.append("证书数据未找到")
        }

        // 3. Read "certPassword" from UserDefaults and save to pass.txt in Documents
        if let certPassword = LCSharedUtils.certificatePassword() {
            let passwordFileURL = documentsURL.appendingPathComponent("pass.txt")
            do {
                try certPassword.write(to: passwordFileURL, atomically: true, encoding: .utf8)
                print("Successfully wrote certPassword to pass.txt in Documents.")
            } catch {
                print("Error writing certPassword to pass.txt: \(error)")
                failures.append("pass.txt 写入失败：\(error.localizedDescription)")
            }
        } else {
            print("certPassword not found in UserDefaults.")
            failures.append("证书密码未找到")
        }

        if failures.isEmpty {
            successInfo = "证书已导出到 Documents"
            successShow = true
        } else {
            errorInfo = failures.joined(separator: "\n")
            errorShow = true
        }
    }
    
    func exportMainBundle() {
        let url = Bundle.main.bundleURL
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            // #21：写前先删已存在的目标文件，否则第二次导出 copyItem 必抛错
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied main bundle to Documents.")
            successInfo = "主包已导出到 Documents"
            successShow = true
        } catch {
            print("Error copying main bundle \(error)")
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func resetSymbolOffsets() {
        LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
        successInfo = "符号偏移已重置"
        successShow = true
    }
    
    func presentFLEXOverlay() {
        let manager = (NSClassFromString("FLEXManager") as? NSObject.Type)?.perform(NSSelectorFromString("sharedManager"))
            .takeUnretainedValue() as? NSObject
        manager?.perform(NSSelectorFromString("showExplorer"))
    }
    
    func importCertificate() async {
        guard let doImport = await certificateImportAlert.open(), doImport else {
            return
        }
        guard let certificateURL = await certificateImportFileAlert.open() else {
            return
        }
        guard let certificatePassword = await certificateImportPasswordAlert.open() else {
            return
        }
        let certificateData : Data
        do {
            certificateData = try Data(contentsOf: certificateURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
        
        guard let _ = LCUtils.getCertTeamId(withKeyData: certificateData, password: certificatePassword) else {
            errorInfo = "lc.settings.invalidCertError".loc
            errorShow = true
            return
        }

        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(certificatePassword, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        certificateDataFound = true

        UserDefaults.standard.set(LCSharedUtils.appGroupID(), forKey: "LCAppGroupID")
    }
    
    func importCertificateFromSideStore() async {
        if UserDefaults.sideStoreExist() {
            if let ans = await certificateImportFromBuiltInSideStoreAlert.open(), ans {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificate",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.kdt.livecontainer",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]
                
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                
                guard status == errSecSuccess else {
                    if status == errSecItemNotFound {
                        errorInfo = "lc.settings.importCertFromBuiltinSideStore.certNotFounndErr".loc
                        errorShow = true
                    } else {
                        errorInfo = "Keychain read error: \(status)"
                        errorShow = true
                    }
                    return
                }
                
                guard let data = item as? Data else {
                    errorInfo = "Failed to decode certificate data"
                    errorShow = true
                    return
                }
                
                let passwordQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificatePassword",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.kdt.livecontainer",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]
                
                var passwordItem: CFTypeRef?
                let passwordStatus = SecItemCopyMatching(passwordQuery as CFDictionary, &passwordItem)
                var password = ""
                if passwordStatus == errSecSuccess,
                   let passwordData = passwordItem as? Data,
                   let pwd = String(data: passwordData, encoding: .utf8) {
                    password = pwd
                }
                
                onSideStoreCertificateCallback(certificateData: data, password: password)
                
                return
            }
        }
        
        let storeScheme : String
        if store == .AltStore {
            storeScheme = "altstore-classic"
        } else {
            storeScheme = "sidestore"
        }
        
        guard let url = URL(string: "\(storeScheme.lowercased())://certificate?callback_template=livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29") else {
            errorInfo = "Failed to initialize certificate import URL."
            errorShow = true
            return
        }
        // 商店 App 没装时 open 回 false，原来静默无事、用户以为点了没反应。
        let opened = await UIApplication.shared.open(url)
        if !opened {
            errorInfo = "没能打开 \(storeName)，请确认它已安装"
            errorShow = true
        }
    }
    func onSideStoreCertificateCallback(certificateData: Data, password: String) {
        // 与文件导入同款校验：证书坏了或密码不对就别存，否则静默存下、
        // 签名时才报错，用户根本不知道是导入这步坏的。钥匙串那路密
        // 码读不到时传的是 ""，错密码同样在这里拦住。
        guard LCUtils.getCertTeamId(withKeyData: certificateData, password: password) != nil else {
            errorInfo = "lc.settings.invalidCertError".loc
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        certificateDataFound = true
    }
    
    func removeCertificate() async {
        guard let doRemove = await certificateRemoveAlert.open(), doRemove else {
            return
        }

        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateUpdateDate")
        certificateDataFound = false

        UserDefaults.standard.set(nil, forKey: "LCAppGroupID")
    }
    
    func nukeSideStore() async {
        guard let doRemove = await nukeSideStoreAlert.open(), doRemove else {
            return
        }
        do {
            let fm = FileManager.default
            let sidestoreAppGroupURL = LCPath.lcGroupDocPath.deletingLastPathComponent()
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Database"))
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Apps"))
            successInfo = "SideStore 数据已清除"
            successShow = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func exportDyld() {
        let url = URL(fileURLWithPath: "/usr/lib/dyld")
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            // #21：写前先删已存在的目标文件，否则第二次导出 copyItem 必抛错
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied dyld to Documents.")
            successInfo = "dyld 已导出到 Documents"
            successShow = true
        } catch {
            print("Error copying dyld \(error)")
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func handleURL(url: URL) {
        if url.host == "certificate" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let encodedCert = queryItems["cert"]?.removingPercentEncoding,
                      let password = queryItems["password"],
                      let certData = Data(base64Encoded: encodedCert)
                else {
                    // #19：证书 deep link 参数缺失/非法时不再静默 return，弹错误提示
                    errorInfo = "证书链接无效，请检查链接参数后重试"
                    errorShow = true
                    return
                }
                
                onSideStoreCertificateCallback(certificateData: certData, password: password)
                
            } else {
                // #19：URLComponents 解析失败同样提示
                errorInfo = "证书链接无效，请检查链接参数后重试"
                errorShow = true
            }
        }
    }
}
