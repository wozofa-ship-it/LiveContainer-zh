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
    @State var vpnStatusMessage: String?
    @State var vpnNewNodeText = ""
    @State var vpnSubURL: String = UserDefaults.standard.string(forKey: "CZFVPNSubscriptionURL") ?? ""
    @State var vpnSubBusy = false
    @State var showSubReplaceConfirm = false
    @State var pendingSubLinks: [String] = []
    @State var vpnNodes: [String] = []
    @State var vpnHostProxy = false
    @AppStorage("CZFVPNPrewarm") var vpnPrewarm = true
    @AppStorage("CZFVPNAutoStopMinutes") var vpnAutoStopMinutes = 10
    @State var vpnActiveIndex = 0
    @State var vpnPingResults: [Int: CZFVPNManager.CZFNodePingResult] = [:]
    @State var vpnPingStaleIndices: Set<Int> = []
    @State var vpnSinglePinging = false
    @State var vpnSinglePingIndex: Int?
    @State var showDeleteActiveConfirm = false
    @State var pendingDeleteIndices: [Int] = []
    @State var vpnPinging = false
    @State var vpnPingRejected = false
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
    
    /// 测完后有没有批量操作可做（切到最快/清理不通/按延迟排序
    /// 任一出现）：批量操作行只在此时才出现，平时不占一行。
    private var hasVPNBatchActions: Bool {
        vpnPingResults.contains(where: { $0.value.success && $0.key != vpnActiveIndex })
            || vpnPingResults.contains(where: { !$0.value.success && $0.key != vpnActiveIndex })
            || vpnPingResults.count > 1
    }

    var body: some View {
        NavigationView {
            Form {
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

                Section {
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
                    ForEach(Array(vpnNodes.enumerated()), id: \.offset) { index, link in
                        Button {
                            CZFVPNManager.shared.setActiveNode(at: index)
                            refreshVPNState()
                        } label: {
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
                                if let ping = vpnPingResults[index], !ping.success, index == vpnActiveIndex, vpnCoreRunning {
                                    Text("在用")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else if (vpnPinging || vpnSinglePingIndex == index) && vpnPingResults[index] == nil {
                                    Text("测速中")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                } else if vpnSinglePingIndex == index {
                                    Text("测速中")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                } else if let ping = vpnPingResults[index] {
                                    // 超 24 小时的缓存结果：灰色加“·旧”，
                                    // 别按新鲜延迟的颜色误导切节点。
                                    let isStale = vpnPingStaleIndices.contains(index)
                                    if ping.success {
                                        Text(isStale ? "\(ping.delay)ms·旧" : "\(ping.delay)ms")
                                            .font(.caption)
                                            .foregroundStyle(isStale ? .gray : (ping.delay < 300 ? .green : (ping.delay < 800 ? .orange : .red)))
                                    } else {
                                        Text((ping.delay == 11000 ? "超时" : "不通") + (isStale ? "·旧" : ""))
                                            .font(.caption)
                                            .foregroundStyle(isStale ? .gray : .red)
                                    }
                                }
                                if index == vpnActiveIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        // 单节点复测：长按行出菜单，只测这一条，
                        // 不清整表、不测全部。行内再嵌 Button 会
                        // 和整行切换按钮抢点击，用菜单最稳。
                        .contextMenu {
                            Button("复测这个节点") {
                                startSinglePing(index)
                            }
                            .disabled(vpnPinging || vpnSinglePinging)
                        }
                    }
                    .onDelete { offsets in
                        // 测速中左滑也禁删：.disabled 不一定挡得住
                        // List 的左滑删除，动作里再守一次，免得
                        // 测速中列表变了、结果下标错位。
                        guard !vpnPinging && !vpnSinglePinging else { return }
                        // 删在用节点先弹确认：manager 侧删在用
                        // 节点已改成停核心不自动切，界面再确认
                        // 一次，免得左滑手误把在用节点删了。
                        if offsets.contains(vpnActiveIndex) {
                            pendingDeleteIndices = offsets.sorted()
                            showDeleteActiveConfirm = true
                        } else {
                            for i in offsets.sorted(by: >) {
                                CZFVPNManager.shared.removeNode(at: i)
                            }
                            vpnPingResults = [:]
                            refreshVPNState()
                        }
                    }
                    // 测速中节点行置灰：测速中点节点行只会把勾
                    // 先动、核心切换被挡下测完才补跑，看起来
                    // 像切了其实还没切；置灰后测速中点不动，
                    // 测完再点才是真切。单节点复测同理。
                    .disabled(vpnPinging || vpnSinglePinging)
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
                        // 出不通的、且不是当前在用节点的——在用
                        // 节点即使某次测速失败也不删（核心在跑且
                        // 实际能上网是更强的证据，见上面「在用」
                        // 的例外）。用 replaceAllNodes 一次替换，
                        // 活动节点按内容跟随、不重启核心。
                        if vpnPingResults.contains(where: { !$0.value.success && $0.key != vpnActiveIndex }) {
                            Button("清理不通") {
                                let failed = Set(vpnPingResults.filter { !$0.value.success && $0.key != vpnActiveIndex }.map { $0.key })
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
                    }
                    // 被拒提示独立一行：原来它和一串按钮挤在同一行，
                    // 长文字把按钮全挤没了；单独一行文字自然换行，
                    // 按钮放下面一行，不再抢宽度。
                    if vpnPingRejected && !vpnPinging {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上次测速被在跑的核心占用，结果没更新：先停核心再测更准，清理/排序按上次真测结果")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            Button("停核心重测") {
                                CZFVPNManager.shared.stop()
                                refreshVPNState()
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
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "timer", color: .red.opacity(0.85))
                            Text("核心关闭后自动停")
                        }
                    }
                } header: {
                    Text("单App VPN")
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
                            Text("点节点行切换（核心在跑时立即生效），左滑删除；订阅导入会整体替换节点列表，更新后重导一次。\n测延迟是真实请求往返毫秒数，不切换核心，通的节点先显示；核心在跑时测可能不准，先停再测。\n给 App 开 VPN：去该 App 设置页打开「VPN 打开（内置节点）」；标记的 App 打开时核心自启，全部关掉后按上面分钟数自停，期间重开会取消这次自停。\n预热开着进 App 就先热好核心；源和下载走节点只对境外源有用。\n最小化不算关，核心继续跑。")
                        }
                    }
                }
                
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
        // 切回前台刷新核心状态：核心在后台被自动停、被别的
        // App 起停后，设置页按钮还是旧状态，下一按钮一刷新
        // 才翻出来、看起来像那个按钮切的；切回前台就刷新，
        // 按钮先对上真实状态。测速中刷新不翻核心按钮（见
        // refreshVPNState 里的测速中守卫），不会打断测速。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshVPNState()
        }
    }
    
    // 保活开关同步：开 → 把内置保活 dylib 放入全局 Tweaks 根目录并立即签名（没签名游客进程加载不了）；
    // 关 → 移出。onAppear 时也会调用一次，补齐/更新文件。
    // 静态版供 App 启动时同步：只靠设置页 onAppear 的话，
    // 重装后用户不打开设置页、保活就一直没部署。
    func syncKeepAliveTweak(enabled: Bool) {
        Self.syncKeepAliveTweak(enabled: enabled, forceSign: true)
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
        if enabled && (forceSign || copied) {
            // 设置页来时强制签一遍（文件已在但可能没签过）；
            // 启动同步只在新拷时签，不拖启动
            Task {
                try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: true)
                try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.lcGroupTweakPath, force: true)
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
        CZFVPNManager.shared.replaceAllNodes(links)
        UserDefaults.standard.set(vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "CZFVPNSubscriptionURL")
        // 订阅导入时直接剪落盘缓存：以前只清内存结果，
        // 被替换掉的节点还留在缓存里，下次存结果时才剪；
        // 先按新列表剪掉，再刷新、再从缓存恢复，恢复的
        // 只会是新列表里还留着的节点。
        writePingCache(readPingCache().filter { links.contains($0.key) })
        vpnPingResults = [:]
        refreshVPNState()
        successInfo = "订阅导入完成：共 \(links.count) 个节点（节点列表已替换为订阅内容）"
        successShow = true
    }

    /// 订阅合并导入：只追加订阅里没有的节点，保留手填
    /// 节点和活动节点（追加在末尾不移位，活动节点不变，
    /// 核心在跑也不重启）。没有新节点时列表不动。
    func mergeSubscriptionLinks(_ links: [String]) {
        let cleaned = links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
        vpnPinging = true
        vpnPingRejected = false
        vpnPingDone = 0
        vpnPingTotal = vpnNodes.count
        vpnPingPhase = "测速"
        CZFVPNManager.shared.pingAllNodes(onPartial: { partial in
            // 通的先显示：只合并通的节点，不通的
            // 留空继续显示“测速中”，等最终结果；
            // 不在这里 save，最终结果才落盘。
            for (i, r) in partial.enumerated() where r.success {
                vpnPingResults[i] = r
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
                vpnPingRejected = false
                savePingResults()
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
        let link = vpnNodes[index]
        vpnSinglePingIndex = index
        vpnSinglePinging = true
        CZFVPNManager.shared.pingSingleNode(at: index) { result, rejected in
            vpnSinglePinging = false
            vpnSinglePingIndex = nil
            if rejected {
                vpnPingRejected = true
            } else if let result, let currentIndex = vpnNodes.firstIndex(of: link) {
                vpnPingResults[currentIndex] = result
                vpnPingStaleIndices.remove(currentIndex)
                savePingResults()
            }
            refreshVPNState()
        }
    }

    func refreshVPNState() {
        vpnNodes = CZFVPNManager.shared.nodeLinks
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
    // 内容对回新下标。编码：≥0 = 通的延迟 ms；-1 = 不通；-2 = 超时）
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
            merged[vpnNodes[index]] = (code: result.success ? result.delay : (result.delay == 11000 ? -2 : -1), time: now)
        }
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
        }
    }
}
