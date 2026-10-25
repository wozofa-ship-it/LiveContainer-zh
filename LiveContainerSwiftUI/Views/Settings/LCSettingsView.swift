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

    // 签名剩余时间：续签区里只列各 App 到期日（只读展示）。
    // 自动续签已去掉（2026-10-25）：回到前台拉起 Side 重签
    // 全部会动各 App 的签名，Side 用的证书和 LC 存的不一致
    // 时团队对不上、游客弹签名无效——用户亲指就是加了续签
    // 之后开始报错，自动续签这部分不要了，显示保留。
    @State private var signatureExpiries: [CZFSignatureExpiry] = []
    private func refreshSignatureExpiries() {
        let entries = CZFSignatureExpiryReader.snapshotEntries(apps: sharedModel.apps, hiddenApps: sharedModel.hiddenApps)
        DispatchQueue.global(qos: .userInitiated).async {
            let list = CZFSignatureExpiryReader.loadAll(entries: entries)
            DispatchQueue.main.async { signatureExpiries = list }
        }
    }

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
    @State var vpnActiveIndex = 0
    @State var vpnPingResults: [Int: CZFVPNManager.CZFNodePingResult] = [:]
    @State var vpnPinging = false
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
                Section {
                    Button {
                        // 一键调用 SideInstaller 🅥 续签全部：跳它的
                        // refresh-all 入口，它自己拉隧道续签
                        if let url = URL(string: "sideinstaller://refresh-all") {
                            UIApplication.shared.open(url, options: [:]) { success in
                                if !success {
                                    errorInfo = "没能打开 SideInstaller 🅥，请确认它已安装"
                                    errorShow = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("一键续签（调用 SideInstaller 🅥）")
                            Spacer()
                            Image(systemName: "arrow.clockwise.circle")
                                .foregroundStyle(.blue)
                        }
                    }
                    // 各 App 签名剩余时间（按到期日从近到远排，
                    // 快到期的标红；读不到描述文件的 App 不列）
                    if signatureExpiries.isEmpty {
                        Text("未读到签名到期时间")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(signatureExpiries) { e in
                            HStack {
                                Text(e.name)
                                Spacer()
                                Text("\(e.label) · \(e.dateText)到期")
                                    .font(.caption)
                                    .foregroundColor(e.daysLeft <= 2 ? .red : .secondary)
                            }
                        }
                    }
                } header: {
                    Text("续签")
                } footer: {
                    Text("点一下跳到 SideInstaller 🅥，自动续签全部个人 ID 签名的 App（包括 LiveContainer 自己，赶在签名到期前续上）。前提：LiveContainer 的安装包已放进 SideInstaller 🅥 的文件里、签名团队一致；若 SideInstaller 🅥 里没有它的安装包，会被跳过续不到。")
                }
                .onAppear { refreshSignatureExpiries() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    refreshSignatureExpiries()
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
                
                Section{
                    Toggle(isOn: $dynamicColors) {
                        HStack {
                            LCSettingsIcon(systemName: "paintpalette.fill", color: .purple)
                            Text("lc.settings.dynamicColors".loc)
                        }
                    }
                    if #available(iOS 18.0, *) {
                        Toggle(isOn: $darkModeIcon) {
                            HStack {
                                LCSettingsIcon(systemName: "moon.fill", color: .indigo)
                                Text("lc.settings.darkModeIcon".loc)
                            }
                        }
                    }
                    
                } header: {
                    Text("lc.settings.interface".loc)
                } footer: {
                    Text("lc.settings.dynamicColors.desc".loc)
                }
                Section{
                    Toggle(isOn: $frameShortIcon) {
                        HStack {
                            LCSettingsIcon(systemName: "plus.app", color: .green)
                            Text("lc.settings.FrameIcon".loc)
                        }
                    }
                } header: {
                    Text("lc.common.miscellaneous".loc)
                } footer: {
                    Text("lc.settings.FrameIconDesc".loc)
                }
                
                Section {
                    Toggle(isOn: $silentSwitchApp) {
                        HStack {
                            LCSettingsIcon(systemName: "eye.slash", color: .gray)
                            Text("lc.settings.silentSwitchApp".loc)
                        }
                    }
                } footer: {
                    Text("lc.settings.silentSwitchAppDesc".loc)
                }
                
                Section {
                    Toggle(isOn: $silentOpenWebPage) {
                        HStack {
                            LCSettingsIcon(systemName: "globe", color: .teal)
                            Text("lc.settings.silentOpenWebPage".loc)
                        }
                    }
                } footer: {
                    Text("lc.settings.silentOpenWebPageDesc".loc)
                }
                
                if sharedModel.isHiddenAppUnlocked {
                    Section {
                        Toggle(isOn: $strictHiding) {
                            HStack {
                                LCSettingsIcon(systemName: "hand.raised.fill", color: .red)
                                Text("lc.settings.strictHiding".loc)
                            }
                        }
                    } footer: {
                        Text("lc.settings.strictHidingDesc".loc)
                    }
                }
                
                Section {
                    Toggle(isOn: $dontSignApp) {
                        HStack {
                            LCSettingsIcon(systemName: "signature", color: .orange)
                            Text("lc.settings.dontSign".loc)
                        }
                    }
                } footer: {
                    Text("lc.settings.dontSignDesc".loc)
                }

                Section {
                    Button {
                        clearNotifications()
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "bell.slash.fill", color: .red)
                            Text("lc.settings.clearNotifications".loc)
                        }
                    }
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
                            CZFVPNManager.shared.addNode(vpnNewNodeText)
                            vpnNewNodeText = ""
                            vpnPingResults = [:]
                            refreshVPNState()
                        }
                        .disabled(vpnNewNodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                        .disabled(vpnSubBusy || vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                                // 红 ≥800ms；失败显示 超时/不通
                                if vpnPinging && vpnPingResults[index] == nil {
                                    Text("测速中")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                } else if let ping = vpnPingResults[index] {
                                    if ping.success {
                                        Text("\(ping.delay)ms")
                                            .font(.caption)
                                            .foregroundStyle(ping.delay < 300 ? .green : (ping.delay < 800 ? .orange : .red))
                                    } else {
                                        Text(ping.delay == 11000 ? "超时" : "不通")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                                if index == vpnActiveIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets.sorted(by: >) {
                            CZFVPNManager.shared.removeNode(at: i)
                        }
                        vpnPingResults = [:]
                        refreshVPNState()
                    }
                    HStack {
                        Button(vpnCoreRunning ? "停止核心" : "启动核心") {
                            if vpnCoreRunning {
                                CZFVPNManager.shared.stop()
                            } else {
                                _ = CZFVPNManager.shared.start()
                            }
                            refreshVPNState()
                        }
                        Button(vpnPinging ? "测速中…" : "测延迟") {
                            vpnPingResults = [:]
                            vpnPinging = true
                            CZFVPNManager.shared.pingAllNodes { results in
                                var map: [Int: CZFVPNManager.CZFNodePingResult] = [:]
                                for (i, r) in results.enumerated() { map[i] = r }
                                vpnPingResults = map
                                savePingResults()
                                vpnPinging = false
                                refreshVPNState()
                            }
                        }
                        .disabled(vpnPinging || vpnNodes.isEmpty)
                        // 测完后一键切到最快的（只认测通的节点；
                        // 已经是最快时不显示，省得误会）
                        if let fastest = vpnPingResults.filter({ $0.value.success }).min(by: { $0.value.delay < $1.value.delay }), fastest.key != vpnActiveIndex {
                            Button("切到最快") {
                                CZFVPNManager.shared.setActiveNode(at: fastest.key)
                                refreshVPNState()
                            }
                        }
                        // 测完后按延迟从低到高重排节点列表（不通
                        // 的沉底、没测到的最后），活动节点按内容
                        // 跟随、不重启核心
                        if vpnPingResults.count > 1 {
                            Button("按延迟排序") {
                                let links = CZFVPNManager.shared.nodeLinks
                                let sorted = links.enumerated().sorted { a, b in
                                    let ka = vpnPingResults[a.offset].map { $0.success ? $0.delay : Int.max - 1 } ?? Int.max
                                    let kb = vpnPingResults[b.offset].map { $0.success ? $0.delay : Int.max - 1 } ?? Int.max
                                    return ka < kb
                                }.map { $0.element }
                                CZFVPNManager.shared.replaceNodeOrder(sorted)
                                vpnPingResults = [:]
                                refreshVPNState()
                            }
                        }
                        Spacer()
                        Text(vpnCoreRunning ? "核心运行中" : (vpnStatusMessage ?? "核心未启动"))
                            .font(.footnote)
                            .foregroundStyle(.gray)
                    }
                    .onAppear {
                        refreshVPNState()
                    }
                    Toggle(isOn: $vpnPrewarm) {
                        HStack {
                            LCSettingsIcon(systemName: "flame.fill", color: .orange)
                            Text("打开时预热节点核心")
                        }
                    }
                    Toggle(isOn: $vpnHostProxy) {
                        HStack {
                            LCSettingsIcon(systemName: "arrow.down.circle", color: .green)
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
                } header: {
                    Text("单App VPN")
                } footer: {
                    Text("点节点行切换（核心在跑时立即生效），左滑可删。订阅导入会用订阅内容整体替换节点列表（当前选中的节点还在订阅里就继续用它），节点更新了再点一次「导入订阅」即可。点「测延迟」经每个节点真实发一次请求量往返毫秒数（核心在跑时测速会短暂停核心、测完自动起回来，几秒的事）。给某个 App 开 VPN：去该 App 的设置页打开「VPN 打开（内置节点）」；被标记的 App 打开时核心自动启动、全部关掉后自动停。「打开时预热节点核心」开着时，进 LiveContainer 就先把核心热好，第一个 VPN App 点开不用等冷启动（不用的话核心随宿主挂起，不额外耗电）。打开「源和下载也走内置节点」后，LiveContainer 刷源、从源下载 IPA 也经当前节点出网（境外源才需要开）。")
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
                        Button {
                            presentFLEXOverlay()
                        } label: {
                            HStack {
                                LCSettingsIcon(systemName: "magnifyingglass", color: .purple)
                                Text("lc.settings.showFlexOverlay".loc)
                            }
                        }
                        .disabled(NSClassFromString("FLEXManager") == nil)
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
                Button("lc.common.cancel".loc, role: .cancel) {
                    pendingSubLinks = []
                }
            } message: {
                Text("当前 \(vpnNodes.count) 个节点（包括手动添加的）会被订阅内容整体替换，此操作不可恢复")
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
        vpnPingResults = [:]
        refreshVPNState()
        successInfo = "订阅导入完成：共 \(links.count) 个节点（节点列表已替换为订阅内容）"
        successShow = true
    }

    func refreshVPNState() {
        vpnNodes = CZFVPNManager.shared.nodeLinks
        vpnActiveIndex = CZFVPNManager.shared.activeNodeIndex
        vpnCoreRunning = CZFVPNManager.shared.isRunning
        vpnStatusMessage = CZFVPNManager.shared.lastError
        vpnHostProxy = CZFVPNManager.isHostProxyEnabled
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
    private static let pingCacheKey = "CZFVPNPingCache"

    private func savePingResults() {
        // 先剪掉已不在列表里的节点，缓存不无限长
        var merged = (UserDefaults.standard.dictionary(forKey: Self.pingCacheKey) as? [String: Int] ?? [:])
            .filter { vpnNodes.contains($0.key) }
        for (index, result) in vpnPingResults {
            guard vpnNodes.indices.contains(index) else { continue }
            merged[vpnNodes[index]] = result.success ? result.delay : (result.delay == 11000 ? -2 : -1)
        }
        UserDefaults.standard.set(merged, forKey: Self.pingCacheKey)
    }

    private func restorePingResults() {
        let cache = UserDefaults.standard.dictionary(forKey: Self.pingCacheKey) as? [String: Int] ?? [:]
        guard !cache.isEmpty else { return }
        var map: [Int: CZFVPNManager.CZFNodePingResult] = [:]
        for (index, link) in vpnNodes.enumerated() {
            guard let v = cache[link] else { continue }
            if v >= 0 {
                map[index] = CZFVPNManager.CZFNodePingResult(success: true, delay: v)
            } else if v == -2 {
                map[index] = CZFVPNManager.CZFNodePingResult(success: false, delay: 11000)
            } else {
                map[index] = CZFVPNManager.CZFNodePingResult(success: false, delay: 10000)
            }
        }
        if !map.isEmpty {
            vpnPingResults = map
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
