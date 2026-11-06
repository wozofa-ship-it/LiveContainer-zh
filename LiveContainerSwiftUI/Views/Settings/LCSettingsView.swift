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
            .font(.system(size: 15, weight: .semibold))
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
    @State var vpnCoreRunning = false
    // 3.8.281：VPN 栏展开/收起（默认收起），记住选择。
    @AppStorage("CZFVPNSectionExpanded") private var vpnSectionExpanded = false
    @State var vpnStatusMessage: String?
    @State var vpnNewNodeText = ""
    @State var vpnSubURL: String = UserDefaults.standard.string(forKey: "CZFVPNSubscriptionURL") ?? ""
    @State var vpnSubBusy = false
    @State var showSubReplaceConfirm = false
    @State var pendingSubLinks: [String] = []
    @State var vpnNodes: [String] = []
    @State var vpnHostProxy = false
    @AppStorage("CZFVPNPrewarm") var vpnPrewarm = true
    @AppStorage("CZFVPNAutoRotate") var vpnAutoRotate = true
    @AppStorage("CZFVPNAutoStopMinutes") var vpnAutoStopMinutes = 10
    @State var vpnActiveIndex = 0
    @State var vpnPingResults: [Int: CZFVPNManager.CZFNodePingResult] = [:]
    @State var vpnPingStaleIndices: Set<Int> = []
    @State var vpnSinglePinging = false
    @State var vpnSinglePingIndex: Int?
    @State var showDeleteActiveConfirm = false
    // 节点多选删除：长按行进多选（链接作键，导入换列表不错位），
    // 全选/删除选中/取消在这组状态上跑，删在用节点走已有确认框。
    @State var vpnNodeSelecting = false
    @State var vpnSelectedNodeLinks: Set<String> = []
    @State var pendingDeleteIndices: [Int] = []
    // 节点长按菜单（复制/编辑/别名/多选）+ 手动拖拽排序：
    // 编辑/别名走 textFieldAlert（iOS 15 可用；alert 内
    // TextField 需 iOS 16，部署目标 15.0 不可用）。
    @State var vpnEditNodeIndex: Int? = nil
    @State var vpnEditNodeText = ""
    @State var vpnEditNodeShow = false
    @State var vpnAliasNodeLink: String? = nil
    @State var vpnAliasText = ""
    @State var vpnAliasShow = false
    @State var vpnReordering = false
    // 订阅自动更新：开关 + 上次拉取时间（超 24 小时才拉，
    // 进设置页检查一次，不每次进都拉）。
    @AppStorage("CZFVPNSubAutoUpdate") var vpnSubAutoUpdate = false
    // 清理不通确认框
    @State var showClearFailedConfirm = false
    @State var pendingClearFailedCount = 0
    @State var vpnPinging = false
    @State var vpnPingRejected = false
    // 单测被核心占用拒写过的节点链接（CZF，3.8.237）：
    // 核心在跑时 pingBatch 被 libXray 生命周期锁拒掉，
    // 旧值与·旧都保留、用户在行上看不出任何变化；
    // 用链接集合标记（不用下标，删/排/导都不错位），
    // 行上直接显示“核心占用”，不再让用户猜。
    // 单测成功写回时清该条、整表成功时全清；只存会话，
    // 不落盘、不参与清理/排序判定（绝不冒充测速结果）。
    @State var vpnSingleRejectedLinks: Set<String> = []
    @State var vpnPingDone = 0
    @State var vpnPingTotal = 0
    @State var vpnPingPhase = "测速"
    @State var vpnPrewarmSuppressed = false
    @State private var showVPNHelp = false
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
                    if let current = CZFUpdateCheck.currentCommit(), current == info.commit {
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

    // 3.8.308：源面板直开某设置页——deepLink host 对上
    // CZFSettingsPage 就弹对应页（sheet，不动导航栈）。
    @State private var deepLinkSettingsPage: CZFSettingsPage? = nil

    let storeName = LCUtils.getStoreName()
    
    init() {
        _certificateDataFound = State(initialValue: LCSharedUtils.certificatePassword() != nil)
        _store = State(initialValue: LCUtils.store())
    }
    
    /// 测完后有没有批量操作可做（切到最快/清理不通/按延迟排序
    /// 任一出现）：批量操作行只在此时才出现，平时不占一行。
    /// 清理只认网络失败——转换失败（不支持）的不算，避免只剩
    /// 不支持节点时出现一行空按钮。
    private var hasVPNBatchActions: Bool {
        vpnPingResults.contains(where: { $0.value.success && $0.key != vpnActiveIndex })
            || vpnPingResults.contains(where: { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex })
            || vpnPingResults.count > 1
    }

    // 已开 VPN 的 App 汇总（可见 + 隐藏）：按 CZFVPNManager
    // 的 per-App 开关读，VPN 区里一行显示名字。
    private var vpnEnabledApps: [LCAppModel] {
        (sharedModel.apps + sharedModel.hiddenApps).filter { CZFVPNManager.isEnabled(for: $0.appInfo) }
    }

    // 订阅自动更新上次拉取时间的显示
    private var subAutoUpdateLastText: String {
        let last = UserDefaults.standard.double(forKey: "CZFVPNSubAutoUpdateLast")
        if last <= 0 { return "还没自动更新过，进设置页时检查" }
        return "上次更新：\(Date(timeIntervalSince1970: last).formatted(date: .numeric, time: .shortened))"
    }

    var body: some View {
        NavigationView {
            Form {
                vpnSection
                jitLessSection
                multiLCSection
                multitaskSection
                jitSection
                emulatorSection
                interfaceSection
                miscSection
                storageSection
                keepAliveSection
                aboutSection
                updateSection
                versionFooter
                developerSection
            }
            .navigationBarTitle("lc.tabView.settings".loc)
            .alert("lc.common.error".loc, isPresented: $errorShow){
            } message: {
                Text(errorInfo)
            }
            .alert("lc.common.success".loc, isPresented: $successShow){
            } message: {
                Text(successInfo)
            }
            .confirmationDialog("替换全部节点？", isPresented: $showSubReplaceConfirm, titleVisibility: .visible) {
                Button("替换为订阅的 \(pendingSubLinks.count) 个节点", role: .destructive) {
                    applySubscriptionLinks(pendingSubLinks)
                    pendingSubLinks = []
                }
                Button("合并导入（只加新的）") {
                    mergeSubscriptionLinks(pendingSubLinks)
                    pendingSubLinks = []
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    pendingSubLinks = []
                }
            } message: {
                Text("替换会把当前 \(vpnNodes.count) 个节点（包括手动添加的）整体换掉，此操作不可恢复；合并只追加订阅里没有的节点，保留手填节点")
            }
            .alert("删除在用节点？", isPresented: $showDeleteActiveConfirm) {
                Button("删除并停核心", role: .destructive) {
                    for i in pendingDeleteIndices.sorted(by: >) {
                        CZFVPNManager.shared.removeNode(at: i)
                    }
                    pendingDeleteIndices = []
                    vpnSelectedNodeLinks = []
                    vpnNodeSelecting = false
                    vpnPingResults = [:]
                    refreshVPNState()
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    pendingDeleteIndices = []
                }
            } message: {
                Text("删掉在用节点后核心会停掉，不会自动切到别的节点继续跑")
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
            // 节点长按菜单：编辑链接（改下标对应的链接，不碰
            // 核心；改的正是在用节点时活动下标跟到新链接）。
            .textFieldAlert(
                isPresented: $vpnEditNodeShow,
                title: "编辑节点链接",
                text: $vpnEditNodeText,
                placeholder: "vless://…",
                action: { newText in
                    if let idx = vpnEditNodeIndex, let text = newText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if CZFVPNManager.shared.updateNode(at: idx, with: text) {
                            vpnPingResults = [:]
                            refreshVPNState()
                        } else {
                            errorInfo = "节点已存在，未重复添加"
                            errorShow = true
                        }
                    }
                    vpnEditNodeIndex = nil
                },
                actionCancel: { _ in
                    vpnEditNodeIndex = nil
                }
            )
            // 节点长按菜单：自定义别名（空字符串=清除别名，
            // 恢复显示链接备注/地址）。
            .textFieldAlert(
                isPresented: $vpnAliasShow,
                title: "节点别名",
                text: $vpnAliasText,
                placeholder: "给节点起个名字",
                action: { newText in
                    if let link = vpnAliasNodeLink {
                        CZFVPNManager.setNodeAlias(newText, for: link)
                        refreshVPNState()
                    }
                    vpnAliasNodeLink = nil
                },
                actionCancel: { _ in
                    vpnAliasNodeLink = nil
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
        // 订阅自动更新：进设置页检查一次（超 24 小时才拉）；
        // 刚打开开关也检查一次，免得开了还要等下次进页。
        .onAppear {
            autoUpdateSubscriptionIfNeeded()
        }
        .onChange(of: vpnSubAutoUpdate) { newValue in
            if newValue {
                autoUpdateSubscriptionIfNeeded()
            }
        }
        // 3.8.308：源面板直开设置页（sheet，不动导航栈；
        // 关掉后 deepLinkSettingsPage 清掉，下次还能再开）。
        .sheet(item: $deepLinkSettingsPage) { page in
            NavigationView {
                page.destinationView
                    .navigationTitle(page.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { deepLinkSettingsPage = nil }
                        }
                    }
            }
        }
        // 切回前台刷新核心状态：核心在后台被自动停、被别的
        // App 起停后，设置页按钮还是旧状态，下一按钮一刷新
        // 才翻出来、看起来像那个按钮切的；切回前台就刷新，
        // 按钮先对上真实状态。测速中刷新不翻核心按钮（见
        // refreshVPNState 里的测速中守卫），不会打断测速。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshVPNState()
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

    @ViewBuilder private var multitaskSection: some View {
        if #available(iOS 16.1, *) {
            Section {
                NavigationLink {
                    LCMultitaskSettingView()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "rectangle.stack", color: .purple)
                        Text("lc.appBanner.multitask".loc)
                    }
                }
            } footer: {
                Text("lc.settings.multitaskDesc".loc)
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
                    TextField("", text: $deviceUDID)
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
        Section {
            Picker(selection: $selected32BitEmulator) {
                ForEach(sharedModel.arm32EmuApps, id: \.self) { app in
                    Text("lc.common.none".loc).tag("")
                    Text(app.appInfo.displayName()).tag(app.appInfo.relativeBundlePath!)
                }
            } label: {
                HStack {
                    LCSettingsIcon(systemName: "cpu", color: .purple)
                    Text("lc.settings.selected32BitEmulator".loc)
                }
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
        // 占一段，顺手并进这一段的末尾。严格隐藏那行只在
        // 隐藏 App 已解锁时出现，原条件不变。
        Section{
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
            if sharedModel.isHiddenAppUnlocked {
                Toggle(isOn: $strictHiding) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "hand.raised.fill", color: .red)
                            Text("lc.settings.strictHiding".loc)
                        }
                        Text("lc.settings.strictHidingDesc".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
                if notificationAuthStatus != .authorized {
                    Button(notificationAuthStatus == .denied ? "去设置" : "开启") {
                        if notificationAuthStatus == .denied {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } else {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                                refreshNotificationAuth()
                            }
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
            Text("lc.common.miscellaneous".loc)
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
        Section(header: Text("后台保活")) {
            Toggle(isOn: $keepAliveEnabled) {
                HStack {
                    LCSettingsIcon(systemName: "heart.fill", color: .red)
                    Text("保活（无声音频）")
                }
            }
            .onChange(of: keepAliveEnabled) { newValue in
                syncKeepAliveTweak(enabled: newValue)
                CZFHostKeepAlive.shared.refresh()
            }
            .onAppear {
                syncKeepAliveTweak(enabled: keepAliveEnabled)
                CZFHostKeepAlive.shared.refresh()
            }
        }
    }

// 节点行显示部分：只负责名字/详情/延迟状态/勾，
// 切换、复测、删除动作留在父视图。行显示与
// vpnSection 解耦后，无关设置项变化不再重建
// 整行显示树。
private struct CZFVPNNodeLabel: View {
    let link: String
    let ping: CZFVPNManager.CZFNodePingResult?
    let isActive: Bool
    let coreRunning: Bool
    let pinging: Bool
    let isSinglePingTarget: Bool
    let isRejected: Bool
    let isStale: Bool

    var body: some View {
        HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CZFVPNManager.nodeDisplay(for: link).name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(CZFVPNManager.nodeDisplay(for: link).detail)
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                Spacer()
                // 延迟测试结果（点下面的「测延迟」
                // 后显示）：绿 <300ms、橙 <800ms、
                // 红 ≥800ms；失败显示 超时/不通。
                // 例外：在用节点且核心在跑时，测速失败
                // 不显示不通——核心在跑且实际能上网
                // 是比一次测速样本更强的证据，显示
                // 不通只会逼用户误换 IP（养号大忌）
                if let ping, !ping.success, isActive, coreRunning {
                    Text("在用")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if (pinging || isSinglePingTarget) && ping == nil {
                    Text("测速中")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else if isSinglePingTarget {
                    Text("测速中")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else if isRejected {
                    // 单测被拒：只剩测速中途核心又被起起来的竞
                    // 态（单测与批量一样先停核心再测，见
                    // startSinglePing）；旧值原样保留，行上直接
                    // 写“核心占用”，别让用户对着不变的数字猜。
                    Text("核心占用")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if ping == nil, !CZFVPNManager.isSupportedNodeScheme(CZFVPNManager.nodeScheme(for: link)) {
                    // 未测到的不支持节点：按转换器清单静态分级，
                    // 直接标“不支持”（橙色，与实测失败的红色区分），
                    // 不等人测完才知道它跑不了。
                    Text("不支持")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let ping {
                    // 超 24 小时的缓存结果：灰色加“·旧”，
                    // 别按新鲜延迟的颜色误导切节点。
                    if ping.success {
                        Text(isStale ? "\(ping.delay)ms·旧" : "\(ping.delay)ms")
                            .font(.caption)
                            .foregroundStyle(isStale ? .gray : (ping.delay < 300 ? .green : (ping.delay < 800 ? .orange : .red)))
                    } else {
                        // 转换失败与网络失败分开显示：转换器拒收
                        // 是协议不支持，不是网络不通。
                        Text((ping.conversionFailed ? "不支持" : (ping.delay == 11000 ? "超时" : "不通")) + (isStale ? "·旧" : ""))
                            .font(.caption)
                            .foregroundStyle(isStale ? .gray : .red)
                    }
                }
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
        }
    }
}

    @ViewBuilder private var vpnSection: some View {
        Section {
            // 3.8.281：VPN 栏可收起（默认收起，只占一行；栏名旁直接
            // 显示核心状态，找 VPN 不用滑半天；展开状态用 AppStorage 记住）。
            DisclosureGroup(isExpanded: $vpnSectionExpanded) {
                HStack {
                    TextField("粘贴节点链接（vless://…）", text: $vpnNewNodeText)
                    .textInputAutocapitalization(.never)
                Button("添加") {
                    // 重复添加不再静默：addNode 返回 false
                    // 时提示已存在，输入框留着、不清结果。
                    if CZFVPNManager.shared.addNode(vpnNewNodeText) {
                        vpnNewNodeText = ""
                        vpnPingResults = [:]
                        refreshVPNState()
                    } else {
                        errorInfo = "节点已存在，未重复添加"
                        errorShow = true
                    }
                }
                .disabled(vpnNewNodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vpnPinging || vpnSinglePinging)
            }
            HStack {
                TextField("粘贴订阅地址（https://…）", text: $vpnSubURL)
                    .textInputAutocapitalization(.never)
                Button(vpnSubBusy ? "拉取中…" : "导入订阅") {
                    vpnSubBusy = true
                    CZFVPNManager.fetchSubscriptionLinks(urlString: vpnSubURL) { result in
                        DispatchQueue.main.async {
                            vpnSubBusy = false
                            switch result {
                            case .success(let links):
                                // 整体替换是破坏性操作：列表里有
                                // 手填节点时先确认再替换（原来点
                                // 一下直接全换，手填的瞬间没了）；
                                // 列表为空没东西可丢，直接导入
                                if vpnNodes.isEmpty {
                                    applySubscriptionLinks(links)
                                } else {
                                    pendingSubLinks = links
                                    showSubReplaceConfirm = true
                                }
                            case .failure(let error):
                                errorInfo = error.localizedDescription
                                errorShow = true
                            }
                        }
                    }
                }
                .disabled(vpnSubBusy || vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vpnPinging || vpnSinglePinging)
            }
            // 订阅自动更新：开着时进设置页检查，上次拉取超 24
            // 小时才重新拉（只追加新节点，保留手填节点）。
            Toggle(isOn: $vpnSubAutoUpdate) {
                Text("订阅自动更新")
            }
            if vpnSubAutoUpdate {
                Text(subAutoUpdateLastText)
                    .font(.footnote)
                    .foregroundStyle(.gray)
            }
            // 已开 VPN 的 App 汇总：按 per-App 开关读，只汇总、
            // 不改开关（改开关去各 App 设置页）。
            if vpnEnabledApps.isEmpty {
                Text("暂无 App 开启 VPN")
                    .font(.footnote)
                    .foregroundStyle(.gray)
            } else {
                Text("已开 VPN 的 App（\(vpnEnabledApps.count)）：\(vpnEnabledApps.map { $0.appInfo.displayName() ?? $0.appInfo.bundleIdentifier() ?? "?" }.joined(separator: "、"))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // 手动拖拽排序：点“排序”出现拖动柄，拖完点“完成”；
            // 活动节点按内容跟随，不重启核心。
            HStack {
                Text("节点")
                    .font(.headline)
                Spacer()
                Button(vpnReordering ? "完成" : "排序") {
                    vpnReordering.toggle()
                }
                .buttonStyle(.borderless)
            }
            ForEach(Array(vpnNodes.enumerated()), id: \.offset) { index, link in
                Button {
                    if vpnNodeSelecting {
                        if vpnSelectedNodeLinks.contains(link) {
                            vpnSelectedNodeLinks.remove(link)
                        } else {
                            vpnSelectedNodeLinks.insert(link)
                        }
                    } else {
                        CZFVPNManager.shared.setActiveNode(at: index)
                        refreshVPNState()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if vpnNodeSelecting {
                            Image(systemName: vpnSelectedNodeLinks.contains(link) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(vpnSelectedNodeLinks.contains(link) ? Color.blue : Color.secondary)
                        }
                        CZFVPNNodeLabel(
                            link: link,
                            ping: vpnPingResults[index],
                            isActive: index == vpnActiveIndex,
                            coreRunning: vpnCoreRunning,
                            pinging: vpnPinging,
                            isSinglePingTarget: vpnSinglePingIndex == index,
                            isRejected: vpnSingleRejectedLinks.contains(link),
                            isStale: vpnPingStaleIndices.contains(index)
                        )
                    }
                }
                // 长按菜单：复制链接/编辑链接/自定义别名/多选。
                // 原来长按直接进多选，菜单里留“多选”同款入口；
                // 复测仍走右滑，不动。
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = link
                        successInfo = "节点链接已复制"
                        successShow = true
                    } label: {
                        Label("复制链接", systemImage: "doc.on.doc")
                    }
                    Button {
                        vpnEditNodeIndex = index
                        vpnEditNodeText = link
                        vpnEditNodeShow = true
                    } label: {
                        Label("编辑链接", systemImage: "pencil")
                    }
                    Button {
                        vpnAliasNodeLink = link
                        vpnAliasText = CZFVPNManager.nodeAlias(for: link) ?? ""
                        vpnAliasShow = true
                    } label: {
                        Label("自定义别名", systemImage: "tag")
                    }
                    Button {
                        if !vpnNodeSelecting {
                            vpnNodeSelecting = true
                        }
                        vpnSelectedNodeLinks.insert(link)
                    } label: {
                        Label("多选", systemImage: "checkmark.circle")
                    }
                }
                // 右滑测速：整表测速太慢时只测这一条，
                // 与原长按复测同一入口；左滑删除不动。
                // allowsFullSwipe 关掉：测速要占 isPinging、
                // 挡核心切换，滑满就触发太容易误触。
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        startSinglePing(index)
                    } label: {
                        Label("测速", systemImage: "speedometer")
                    }
                    .tint(.blue)
                    .disabled(vpnPinging || vpnSinglePinging)
                }
                // 3.8.317：左滑删除改走 swipeActions 的删除钮——
                // 原来的 .onDelete 删在用节点时只弹确认框、不删
                // 数据，List 底层 UICollectionView 却已按“删了
                // 1 条”去算（7-1=6），数据源仍是 7 条，直接报
                // Invalid update（用户 2026-11-06 21:42 真机实
                // 证）。swipeActions 的按钮不触发 List 自动删，
                // 点了才由代码删数据，确认框再弹也安全。
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        guard !vpnPinging && !vpnSinglePinging else { return }
                        // 删在用节点先弹确认：manager 侧删在用
                        // 节点已改成停核心不自动切，界面再确认
                        // 一次，免得左滑手误把在用节点删了。
                        if index == vpnActiveIndex {
                            pendingDeleteIndices = [index]
                            showDeleteActiveConfirm = true
                        } else {
                            CZFVPNManager.shared.removeNode(at: index)
                            vpnPingResults = [:]
                            refreshVPNState()
                        }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(vpnPinging || vpnSinglePinging)
                }
            }
            // 测速中节点行置灰：测速中点节点行只会把勾
            // 先动、核心切换被挡下测完才补跑，看起来
            // 像切了其实还没切；置灰后测速中点不动，
            // 测完再点才是真切。单节点复测同理。
            .disabled(vpnPinging || vpnSinglePinging)
            // 手动拖拽排序：上面“排序”开着时出拖动柄，
            // 拖完 replaceNodeOrder 写回，活动节点按内容跟随。
            .environment(\.editMode, vpnReordering ? .constant(.active) : .constant(.inactive))
            .onMove { source, destination in
                var links = vpnNodes
                links.move(fromOffsets: source, toOffset: destination)
                CZFVPNManager.shared.replaceNodeOrder(links)
                refreshVPNState()
            }
            // 多选删除操作条：只在长按进多选后出现；全选按链接集合算，
            // 删选中走 deleteSelectedVPNNodeLinks（在用节点走确认框）。
            if vpnNodeSelecting {
                HStack {
                    Button(vpnSelectedNodeLinks == Set(vpnNodes) && !vpnNodes.isEmpty ? "取消全选" : "全选") {
                        if vpnSelectedNodeLinks == Set(vpnNodes) {
                            vpnSelectedNodeLinks = []
                        } else {
                            vpnSelectedNodeLinks = Set(vpnNodes)
                        }
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("删除选中 (\(vpnSelectedNodeLinks.count))") {
                        deleteSelectedVPNNodeLinks()
                    }
                    .disabled(vpnSelectedNodeLinks.isEmpty)
                    .foregroundStyle(Color.red)
                    .buttonStyle(.borderless)
                    Button("取消") {
                        vpnNodeSelecting = false
                        vpnSelectedNodeLinks = []
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button(vpnCoreRunning ? "停止核心" : "启动核心") {
                    CZFVPNManager.shared.noteManualCoreToggle(started: !vpnCoreRunning)
                    if vpnCoreRunning {
                        CZFVPNManager.shared.stop()
                    } else {
                        _ = CZFVPNManager.shared.start()
                    }
                    refreshVPNState()
                }
                // 测速中置灰：测速中亲手起停核心会和测速
                // 的 deferred 逻辑插队，状态容易翻；测速
                // 本身又不切核心，测速中起停没有意义，
                // 测完再点。
                .disabled(vpnPinging || vpnSinglePinging)
                .buttonStyle(.borderless)
                Button(vpnPinging ? (vpnPingTotal > 0 ? "\(vpnPingPhase) \(vpnPingDone)/\(vpnPingTotal)" : "测速中…") : "测延迟") {
                    startVPNPing()
                }
                .disabled(vpnPinging || vpnSinglePinging || vpnNodes.isEmpty)
                .buttonStyle(.borderless)
                Spacer()
                Text(vpnCoreRunning ? "核心运行中" : (vpnStatusMessage ?? "核心未启动"))
                    .font(.footnote)
                    .foregroundStyle(.gray)
            }
            .onAppear {
                refreshVPNState()
            }
            // 测完后的批量操作单独放一行：原来启动/测延迟/
            // 切最快/清理/排序/被拒提示/状态全挤在一行，
            // 按钮一多就互相挤压截断；拆开后主操作行永远
            // 只有两个按钮加状态，批量行只在有操作时出现。
            if hasVPNBatchActions {
            HStack {
                // 测完后一键切到最快的（只认测通的节点；
                // 已经是最快时不显示，省得误会）
                if let fastest = vpnPingResults.filter({ $0.value.success }).min(by: { $0.value.delay < $1.value.delay }), fastest.key != vpnActiveIndex {
                    Button("切到最快") {
                        CZFVPNManager.shared.setActiveNode(at: fastest.key)
                        refreshVPNState()
                    }
                    .disabled(vpnPinging || vpnSinglePinging)
                    .buttonStyle(.borderless)
                }
                // 测完后一键清理不通的节点：只删明确测
                // 出网络不通的、且不是当前在用节点的——在用
                // 节点即使某次测速失败也不删（核心在跑且
                // 实际上网是更强的证据，见上面「在用」
                // 的例外）；转换失败（不支持）的也不删——
                // 它们不是网络不通，删了等于删协议，留着等
                // 换协议或走原始 JSON 出站绕法。用
                // replaceAllNodes 一次替换，活动节点按内容
                // 跟随、不重启核心。
                if vpnPingResults.contains(where: { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex }) {
                    Button("清理不通") {
                        pendingClearFailedCount = vpnPingResults.filter { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex }.count
                        showClearFailedConfirm = true
                    }
                    // 被拒时不再禁清理：被拒结果已不再覆写
                    // 界面和缓存，清理按上次真测结果走；
                    // 测速中仍禁，免得按还没重试完的临时
                    // 失败删节点。
                    .disabled(vpnPinging || vpnSinglePinging)
                    .buttonStyle(.borderless)
                }
                // 测完后按延迟从低到高重排节点列表（不通
                // 的沉底、没测到的最后），在用节点固定
                // 在原位置不动、只排其余节点，活动节点
                // 按内容跟随、不重启核心。以前在用节点
                // 测速失败也会按不通沉底，列表顺序变了、
                // 容易误会成在用节点被换了。
                if vpnPingResults.count > 1 {
                    Button("按延迟排序") {
                        let links = CZFVPNManager.shared.nodeLinks
                        let activeIdx = vpnActiveIndex
                        let activeLink: String? = links.indices.contains(activeIdx) ? links[activeIdx] : nil
                        let rest = links.enumerated().filter { $0.offset != activeIdx }.sorted { a, b in
                            let ka = vpnPingResults[a.offset].map { $0.success ? $0.delay : Int.max - 1 } ?? Int.max
                            let kb = vpnPingResults[b.offset].map { $0.success ? $0.delay : Int.max - 1 } ?? Int.max
                            return ka < kb
                        }.map { $0.element }
                        var sorted = rest
                        if let activeLink {
                            sorted.insert(activeLink, at: min(activeIdx, sorted.count))
                        }
                        CZFVPNManager.shared.replaceNodeOrder(sorted)
                        vpnPingResults = [:]
                        refreshVPNState()
                    }
                    .disabled(vpnPinging || vpnSinglePinging)
                    .buttonStyle(.borderless)
                }
            }
            // 清理不通先确认：删节点不可恢复，点一下就删
            // 太容易手误；确认框里写清删几个、在用与不支持的不删。
            .alert("清理不通的节点？", isPresented: $showClearFailedConfirm) {
                Button("清理 \(pendingClearFailedCount) 个", role: .destructive) {
                    let failed = Set(vpnPingResults.filter { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex }.map { $0.key })
                    let kept = CZFVPNManager.shared.nodeLinks.enumerated().filter { !failed.contains($0.offset) }.map { $0.element }
                    // 清理不碰核心：只换列表，核心在跑继续用
                    // 在用节点、停着继续停着；再清掉内存结果、
                    // 按新列表剪掉已删节点的落盘缓存，最后刷新，
                    // 否则旧失败结果还在、清理按钮永远不消失，
                    // 看起来像没清理。
                    CZFVPNManager.shared.replaceNodesWithoutCoreChange(kept)
                    vpnNodes = CZFVPNManager.shared.nodeLinks
                    vpnPingResults = [:]
                    savePingResults()
                    refreshVPNState()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除 \(pendingClearFailedCount) 个测速不通的节点（在用节点与不支持的节点不会删），此操作不可恢复")
            }
            }
            // 被拒提示独立一行：原来它和一串按钮挤在同一行，
            // 长文字把按钮全挤没了；单独一行文字自然换行，
            // 按钮放下面一行，不再抢宽度。
            if vpnPingRejected && !vpnPinging {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上次测速被在跑的核心占用，结果没更新：先停核心再测更准，清理/排序按上次真测结果")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    // startVPNPing 已包办停核心→测速→重启，
                    // 这里不用再手动 stop（原来两处停逻辑漂移）。
                    Button("停核心重测") {
                        startVPNPing()
                    }
                    .buttonStyle(.borderless)
                }
            }
            Toggle(isOn: $vpnPrewarm) {
                HStack {
                    // 只动这两处图标观感：底色统一降到 0.85 不透明度，
                    // 橙/绿区分保留但不再刺眼；LCSettingsIcon 本体不动，
                    // 其他行的图标不受影响。尺寸 30pt、圆角、15pt
                    // semibold 白字仍走共用组件，不改布局。
                    LCSettingsIcon(systemName: "flame.fill", color: .orange.opacity(0.85))
                    Text("打开时预热节点核心")
                }
            }
            .onChange(of: vpnPrewarm) { _ in
                // 亲手拨一次预热开关：清掉测速后的预热抑制，
                // 之后预热照常工作；拨开关本身不动核心状态。
                CZFVPNManager.shared.notePrewarmSwitchToggled()
                refreshVPNState()
            }
            // 预热抑制可见：开关开着、测速后核心停着时，
            // 预热其实被压着不工作，以前界面上看不出，
            // 用户只会以为预热坏了；现在把状态说出来。
            if vpnPrewarmSuppressed && vpnPrewarm && !vpnCoreRunning {
                Text("测速后预热已暂停：拨一次预热开关可恢复")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Toggle(isOn: $vpnAutoRotate) {
                HStack {
                    LCSettingsIcon(systemName: "arrow.triangle.2.circlepath", color: .blue.opacity(0.85))
                    Text("节点自动轮换")
                }
            }
            .onChange(of: vpnAutoRotate) { newValue in
                CZFVPNManager.setAutoRotate(newValue)
                refreshVPNState()
            }
            Toggle(isOn: $vpnHostProxy) {
                HStack {
                    // 原来是 arrow.down.circle：带圈轮廓的符号在实心
                    // 圆底上显得又小又淡，跟 flame.fill 的实心符号
                    // 不是一套。换成无圈的 arrow.down，同样 15pt
                    // 白字实心圆底，两行符号粗细、视觉分量一致。
                    LCSettingsIcon(systemName: "arrow.down", color: .green.opacity(0.85))
                    Text("源和下载也走内置节点")
                }
            }
                .onChange(of: vpnHostProxy) { newValue in
                    CZFVPNManager.isHostProxyEnabled = newValue
                    if newValue {
                        CZFVPNManager.shared.ensureRunningForHost()
                    }
                    refreshVPNState()
                }
            Picker(selection: $vpnAutoStopMinutes) {
                Text("5 分钟").tag(5)
                Text("10 分钟").tag(10)
                Text("30 分钟").tag(30)
                Text("永不").tag(-1)
            } label: {
                HStack {
                    LCSettingsIcon(systemName: "timer", color: .red.opacity(0.85))
                    Text("核心关闭后自动停")
                }
            }
            } label: {
                HStack {
                    // 3.8.282：VPN 栏加美化图标（用户亲令）：跟数据管理、
                    // 保活等行一样挂彩色图标，不然整行只有字、太素
                    LCSettingsIcon(systemName: "shield.fill", color: .green)
                    Text("单App VPN")
                    Spacer()
                    Text(vpnCoreRunning ? "核心运行中" : "核心未启动")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                }
            }
        } footer: {
            // 原来这里是一整段 400 多字说明，常驻占十几行。
            // 改成默认只剩一行入口，点开才看精简版：关键意思
            // 都还在（切换/删除、订阅替换、测速、开 VPN、预热、
            // 源下载走节点、自动停、最小化不算关），但平时
            // 设置页不再被这段顶下去。
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    showVPNHelp.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("VPN 说明")
                        Image(systemName: showVPNHelp ? "chevron.up" : "chevron.down")
                    }
                }
                .font(.footnote)
                .buttonStyle(.plain)
                if showVPNHelp {
                    Text("点节点行切换（核心在跑时立即生效），左滑删除；订阅导入会整体替换节点列表，更新后重导一次。\n测延迟是真实请求往返毫秒数，不切换核心，通的节点先显示；测延迟会在核心在跑时先停核心、测完重启原来那条；核心没在跑时直接测、不启动。\n给 App 开 VPN：去该 App 设置页打开「VPN 打开（内置节点）」；标记的 App 打开时核心自启，全部关掉后按上面分钟数自停，期间重开会取消这次自停。\n预热开着进 App 就先热好核心；源和下载走节点只对境外源有用。\n最小化不算关，核心继续跑。\n节点行会显示协议（vless/vmess/trojan/ss/socks/hysteria2/tuic 等）；转换器只认这几类，未列出的链接会标“不支持”——不是网络不通，“清理不通”不会删它们。\n绕法：可以把出站写成原始 Xray JSON 当节点粘贴（转换器会保留其 outbounds），名字会显示成“节点”；测速与启动都走同一转换，JSON 节点同样能测。\n节点自动轮换开着时，核心在跑的 App 连续失败就自动按列表顺序换下一个支持的节点并重启核心，一圈都不通就停下来等手动处理。")
                }
            }
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            HStack {
                Image("GitHub")
                Button("LiveContainer/LiveContainer") {
                    openGitHub()
                }
            }
            HStack {
                Image("Twitter")
                Button("khanhduytran0") {
                    openTwitter()
                }
            }
            HStack {
                Image("GitHub")
                Button("Huge_Black") {
                    openGitHub2()
                }
            }
        } header: {
            Text("lc.settings.about".loc)
        } footer: {
            Text("lc.settings.warning".loc)
        }
    }

    @ViewBuilder private var updateSection: some View {
        // App 内更新检查：只查 fork 自己的 update release，不查
        // 上游源（会丢 fork 改动）。有新版时下面多两行
        // “去 SideInstaller 更新”和“去 Seal 更新”，点它直接跳
        // 对应 App 的 install 链接下载安装，不用再去聊天里拿直链。
        Section {
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
            }
        } header: {
            Text("更新")
        }
    }

    @ViewBuilder private var versionFooter: some View {
        VStack{
            Text(LCUtils.getVersionInfo())
                .foregroundStyle(.gray)
                .onTapGesture(count: 5) {
                    sharedModel.developerMode = true
                }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color(UIColor.systemGroupedBackground))
            .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var developerSection: some View {
        if sharedModel.developerMode {
            Section {
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

    /// 订阅导入的实际替换动作：导入按钮（列表为空时直达）和
    /// 替换确认框共用，避免两处逻辑漂移
    func applySubscriptionLinks(_ links: [String]) {
        // 订阅自身含重复链接时先去重（保序），否则替换后出两行
        // 相同节点、单测按 firstIndex 永远只写第一行。
        var seen = Set<String>()
        let deduped = links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        CZFVPNManager.shared.replaceAllNodes(deduped)
        UserDefaults.standard.set(vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "CZFVPNSubscriptionURL")
        // 订阅导入时直接剪落盘缓存：以前只清内存结果，
        // 被替换掉的节点还留在缓存里，下次存结果时才剪；
        // 先按新列表剪掉，再刷新、再从缓存恢复，恢复的
        // 只会是新列表里还留着的节点。
        writePingCache(readPingCache().filter { deduped.contains($0.key) })
        vpnPingResults = [:]
        refreshVPNState()
        successInfo = "订阅导入完成：共 \(deduped.count) 个节点（节点列表已替换为订阅内容）"
        successShow = true
    }

    /// 订阅合并导入：只追加订阅里没有的节点，保留手填
    /// 节点和活动节点（追加在末尾不移位，活动节点不变，
    /// 核心在跑也不重启）。没有新节点时列表不动。
    func mergeSubscriptionLinks(_ links: [String]) {
        // 先在订阅自身内去重（保序），再对原列表过滤：订阅自带
        // [A, A] 时只追加一个，否则两行相同节点、单测永远只写
        // 第一行，第二行永不更新。
        var seen = Set<String>()
        let cleaned = links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let existing = CZFVPNManager.shared.nodeLinks
        let fresh = cleaned.filter { !existing.contains($0) }
        UserDefaults.standard.set(vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "CZFVPNSubscriptionURL")
        if fresh.isEmpty {
            successInfo = "订阅里没有新节点，列表未变"
            successShow = true
            return
        }
        // 走清理同款只换列表不碰核心：活动节点按内容找回，
        // 追加在末尾不移位，核心在跑也不重启。
        CZFVPNManager.shared.replaceNodesWithoutCoreChange(existing + fresh)
        writePingCache(readPingCache().filter { (existing + fresh).contains($0.key) })
        vpnPingResults = [:]
        refreshVPNState()
        successInfo = "合并导入完成：新增 \(fresh.count) 个节点，共 \(existing.count + fresh.count) 个"
        successShow = true
    }

    // 测延迟的实际动作（测延迟按钮与被拒时的
    // “停核心重测”共用，免得两处逻辑漂移）：
    // 进度按批回主线程，按钮显示“测速 3/10”/
    // “重试 2/5”，不再只有一句测速中。
    func startVPNPing() {
        // 测速期间保留旧结果不清空：原来一开测就清表，
        // 测速中界面是空的、要等整轮测完才回来；现在旧
        // 结果先留着（按钮进度另行显示“测速 3/10”），
        // 测完由 completion 整表替换，被拒也不覆写。
        // 用户 2026-11-03 定的“停止测速启动”：核心在跑时
        // 先停、测完重启原来那条；核心没在跑时直接测、
        // 测完不启动。停核心在测速标志立起来之前做，免得
        // 测速窗口内起停被 deferred 逻辑插队。
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnPinging = true
        vpnPingRejected = false
        vpnPingDone = 0
        vpnPingTotal = vpnNodes.count
        vpnPingPhase = "测速"
        CZFVPNManager.shared.pingAllNodes(onPartial: { partial in
            // 通的先显示：只合并通的节点，不通的
            // 留空继续显示“测速中”，等最终结果；
            // 不在这里 save，最终结果才落盘。
            // 刚测通的节点同步清掉 stale 标记：别等整表
            // completion，测速中先显示的通节点一直灰色“·旧”
            // 是纯显示问题。
            for (i, r) in partial.enumerated() where r.success {
                vpnPingResults[i] = r
                vpnPingStaleIndices.remove(i)
            }
        }, onProgress: { done, total, phase in
            vpnPingDone = done
            vpnPingTotal = total
            vpnPingPhase = phase
        }) { results, rejected in
            if rejected {
                // 被拒那批全是失败，不是节点真不通：
                // 不覆写界面结果、不落盘，免得污染上次
                // 真测结果、清理/排序按假不通走；只出警告，
                // 清理/排序继续用上次真测结果。测速开始
                // 时已不再清空旧表，这里也不清空，直接
                // 保留旧结果即可，不用再靠缓存恢复。
                vpnPingRejected = true
            } else {
                var map: [Int: CZFVPNManager.CZFNodePingResult] = [:]
                for (i, r) in results.enumerated() { map[i] = r }
                vpnPingResults = map
                vpnPingStaleIndices = []
                vpnSingleRejectedLinks = []
                vpnPingRejected = false
                savePingResults()
            }
            // 停过的核心测完重启原来那条（没停过就不启动）；
            // 放 refresh 之前，状态行直接显示重启后的状态。
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            vpnPinging = false
            vpnPingDone = 0
            vpnPingTotal = 0
            refreshVPNState()
        }
    }

    // 单节点复测（长按行菜单）：只测这一条，不清整表。
    // 被拒时不覆写旧结果、只出警告；成功时只更新该节点
    // 的结果与缓存时间戳，其余节点结果不动。按链接内容
    // 对回下标，测速中列表变了也不错位。
    func startSinglePing(_ index: Int) {
        guard vpnNodes.indices.contains(index) else { return }
        // 滑动动作的 .disabled 不一定挡得住 List 行动作
        //（左滑删除已有同款教训、动作里另守一次），
        // 入口再守一次：测速中不叠加开第二轮单测。
        guard !vpnPinging && !vpnSinglePinging else { return }
        let link = vpnNodes[index]
        // 单测与批量同规则（251 只修了批量，行长按复测仍
        // 是老逻辑、核心在跑就拒，TUIC 行一直挂“核心占用”
        // 就是这么来的）：核心在跑先停、测完重启原来那条；
        // 没在跑直接测、测完不启动。停核心在测速标志立
        // 起来之前做，免得测速窗口内起停被 deferred 逻辑插队。
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnSinglePingIndex = index
        vpnSinglePinging = true
        CZFVPNManager.shared.pingSingleNode(at: index) { result, rejected in
            vpnSinglePinging = false
            vpnSinglePingIndex = nil
            if rejected {
                vpnPingRejected = true
                vpnSingleRejectedLinks.insert(link)
            } else if let result, let currentIndex = vpnNodes.firstIndex(of: link) {
                vpnPingResults[currentIndex] = result
                vpnPingStaleIndices.remove(currentIndex)
                vpnSingleRejectedLinks.remove(link)
                // 只写该条缓存，别刷全表时间戳（见 savePingResult）。
                savePingResult(link: link, result: result)
            }
            // 停过的核心测完重启原来那条（没停过就不启动）；
            // 放 refresh 之前，状态行直接显示重启后的状态。
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            refreshVPNState()
        }
    }

    // 多选删除：按链接换算下标（删时现算，导入换列表不错位）；
    // 含在用节点走已有确认框，确认后退出多选；不含直接删。
    func deleteSelectedVPNNodeLinks() {
        guard !vpnPinging && !vpnSinglePinging else { return }
        let indices = vpnNodes.enumerated().compactMap { vpnSelectedNodeLinks.contains($0.element) ? $0.offset : nil }
        guard !indices.isEmpty else { return }
        if indices.contains(vpnActiveIndex) {
            pendingDeleteIndices = indices.sorted()
            showDeleteActiveConfirm = true
        } else {
            for i in indices.sorted(by: >) {
                CZFVPNManager.shared.removeNode(at: i)
            }
            vpnSelectedNodeLinks = []
            vpnNodeSelecting = false
            vpnPingResults = [:]
            refreshVPNState()
        }
    }

    // 订阅自动更新：开关开着、填了订阅地址、上次拉取超 24
    // 小时（或从没拉过）时才拉；走 mergeSubscriptionLinks
    // （只追加新节点，保留手填节点），成功/失败都走现有
    // successInfo/errorInfo 弹窗反馈；进设置页检查一次。
    func autoUpdateSubscriptionIfNeeded() {
        guard vpnSubAutoUpdate else { return }
        let url = vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !vpnSubBusy else { return }
        let last = UserDefaults.standard.double(forKey: "CZFVPNSubAutoUpdateLast")
        if last > 0 && Date().timeIntervalSince1970 - last < 24 * 3600 { return }
        vpnSubBusy = true
        CZFVPNManager.fetchSubscriptionLinks(urlString: url) { result in
            DispatchQueue.main.async {
                vpnSubBusy = false
                switch result {
                case .success(let links):
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "CZFVPNSubAutoUpdateLast")
                    mergeSubscriptionLinks(links)
                case .failure(let error):
                    errorInfo = "订阅自动更新失败：\(error.localizedDescription)"
                    errorShow = true
                }
            }
        }
    }

    func refreshVPNState() {
        vpnNodes = CZFVPNManager.shared.nodeLinks
        // 核心占用标记按当前列表剪枝：删节点/订阅替换后孤儿标记
        // 自动掉，删掉重加同一条不会没测过就显示“核心占用”。
        // 链接集合标记，删/排/导都不错位，剪枝只删不在列表的。
        vpnSingleRejectedLinks = vpnSingleRejectedLinks.filter { vpnNodes.contains($0) }
        vpnActiveIndex = CZFVPNManager.shared.activeNodeIndex
        // 测速中不翻核心按钮：测速期间任何 onAppear/刷新
        // 都不该把按钮从停止翻成启动，核心状态以测速前为准，
        // 测完由 completion 一次性刷新。
        if !vpnPinging {
            vpnCoreRunning = CZFVPNManager.shared.isRunning
        }
        vpnStatusMessage = CZFVPNManager.shared.lastError
        vpnHostProxy = CZFVPNManager.isHostProxyEnabled
        vpnPrewarmSuppressed = CZFVPNManager.shared.isPrewarmSuppressedAfterPing
        // 内存里的测速结果被清空（增删/导入/排序都会清）时，
        // 从落盘缓存按节点内容重建，没测过的节点不显示
        if vpnPingResults.isEmpty && !vpnPinging {
            restorePingResults()
        }
    }

    // MARK: - 测速结果持久化（打磨：以前只存内存，增删/导入任一
    // 节点就整表清零、重启也没了，而测速要停一次核心，代价不小。
    // 按节点链接内容存：增删别的节点不影响已有结果，重排后按
    // 内容对回新下标。编码：≥0 = 通的延迟 ms；-1 = 不通；-2 = 超时；-3 = 不支持（转换失败）
    // 新格式每条带时间戳（v = 延迟码，t = 测于何时的秒时间戳）：
    // 超 24 小时的结果界面灰色显示“·旧”，别按旧延迟误切节点。
    // 旧格式（直接存 Int）兼容读，时间戳按 0 计、即直接算旧。
    private static let pingCacheKey = "CZFVPNPingCache"
    private static let pingCacheStaleAfter: TimeInterval = 86400

    private func readPingCache() -> [String: (code: Int, time: TimeInterval)] {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.pingCacheKey) else { return [:] }
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

    private func writePingCache(_ cache: [String: (code: Int, time: TimeInterval)]) {
        var out: [String: [String: Any]] = [:]
        for (link, entry) in cache {
            out[link] = ["v": entry.code, "t": entry.time]
        }
        UserDefaults.standard.set(out, forKey: Self.pingCacheKey)
    }

    private func savePingResults() {
        // 先剪掉已不在列表里的节点，缓存不无限长
        var merged = readPingCache().filter { vpnNodes.contains($0.key) }
        let now = Date().timeIntervalSince1970
        for (index, result) in vpnPingResults {
            guard vpnNodes.indices.contains(index) else { continue }
            merged[vpnNodes[index]] = (code: Self.pingCacheCode(for: result), time: now)
        }
        writePingCache(merged)
    }

    /// 测速结果落盘编码（与 restorePingResults 的解码对应）：
    /// ≥0 = 通的延迟 ms；-1 = 不通；-2 = 超时；-3 = 不支持。
    private static func pingCacheCode(for result: CZFVPNManager.CZFNodePingResult) -> Int {
        result.success ? result.delay : (result.conversionFailed ? -3 : (result.delay == 11000 ? -2 : -1))
    }

    /// 单测只写该条缓存：以前单测调全量 savePingResults，
    /// 全表时间戳都被刷成“刚才”，几天前的旧结果杀掉重进后
    /// “·旧”消失、冒充新鲜。整表测速仍走全量（确实全测了）。
    private func savePingResult(link: String, result: CZFVPNManager.CZFNodePingResult) {
        var merged = readPingCache().filter { vpnNodes.contains($0.key) }
        merged[link] = (code: Self.pingCacheCode(for: result), time: Date().timeIntervalSince1970)
        writePingCache(merged)
    }

    private func restorePingResults() {
        let cache = readPingCache()
        guard !cache.isEmpty else { return }
        var map: [Int: CZFVPNManager.CZFNodePingResult] = [:]
        var stale: Set<Int> = []
        let now = Date().timeIntervalSince1970
        for (index, link) in vpnNodes.enumerated() {
            guard let entry = cache[link] else { continue }
            let v = entry.code
            if v >= 0 {
                map[index] = CZFVPNManager.CZFNodePingResult(success: true, delay: v)
            } else if v == -2 {
                map[index] = CZFVPNManager.CZFNodePingResult(success: false, delay: 11000)
            } else if v == -3 {
                map[index] = CZFVPNManager.CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
            } else {
                map[index] = CZFVPNManager.CZFNodePingResult(success: false, delay: 10000)
            }
            if entry.time == 0 || now - entry.time > Self.pingCacheStaleAfter {
                stale.insert(index)
            }
        }
        if !map.isEmpty {
            vpnPingResults = map
            vpnPingStaleIndices = stale
        }
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
    }

    func export() {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // 1. Copy embedded.mobileprovision from the main bundle to Documents
        if let embeddedURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
            let destinationURL = documentsURL.appendingPathComponent("embedded.mobileprovision")
            do {
                try fileManager.copyItem(at: embeddedURL, to: destinationURL)
                print("Successfully copied embedded.mobileprovision to Documents.")
            } catch {
                print("Error copying embedded.mobileprovision: \(error)")
            }
        } else {
            print("embedded.mobileprovision not found in the main bundle.")
        }
        
        // 2. Read "certData" from UserDefaults and save to cert.p12 in Documents
        if let certData = LCUtils.certificateData() {
            let certFileURL = documentsURL.appendingPathComponent("cert.p12")
            do {
                try certData.write(to: certFileURL)
                print("Successfully wrote certData to cert.p12 in Documents.")
            } catch {
                print("Error writing certData to cert.p12: \(error)")
            }
        } else {
            print("certData not found in UserDefaults.")
        }
        
        // 3. Read "certPassword" from UserDefaults and save to pass.txt in Documents
        if let certPassword = LCSharedUtils.certificatePassword() {
            let passwordFileURL = documentsURL.appendingPathComponent("pass.txt")
            do {
                try certPassword.write(to: passwordFileURL, atomically: true, encoding: .utf8)
                print("Successfully wrote certPassword to pass.txt in Documents.")
            } catch {
                print("Error writing certPassword to pass.txt: \(error)")
            }
        } else {
            print("certPassword not found in UserDefaults.")
        }
    }
    
    func exportMainBundle() {
        let url = Bundle.main.bundleURL
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied main bundle to Documents.")
        } catch {
            print("Error copying main bundle \(error)")
        }
    }
    
    func resetSymbolOffsets() {
        LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
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
        await UIApplication.shared.open(url)
    }
    func onSideStoreCertificateCallback(certificateData: Data, password: String) {
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
        guard let doRemove = await certificateRemoveAlert.open(), doRemove else {
            return
        }
        do {
            let fm = FileManager.default
            let sidestoreAppGroupURL = LCPath.lcGroupDocPath.deletingLastPathComponent()
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Database"))
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Apps"))
        } catch {
            print("wtf \(error)")
        }
    }
    
    func exportDyld() {
        let url = URL(fileURLWithPath: "/usr/lib/dyld")
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied dyld to Documents.")
        } catch {
            print("Error copying dyld \(error)")
        }
    }
    
    func handleURL(url: URL) {
        if url.host == "certificate" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let encodedCert = queryItems["cert"]?.removingPercentEncoding,
                      let password = queryItems["password"],
                      let certData = Data(base64Encoded: encodedCert)
                else { return }
                
                onSideStoreCertificateCallback(certificateData: certData, password: password)
                
            }
        } else if let host = url.host, let page = CZFSettingsPage(rawValue: host) {
            // 3.8.308：源面板直开设置页——host 对上页标识就弹
            // 对应页（sheet）；host 不认就只停在设置页。
            deepLinkSettingsPage = page
        }
    }
}
