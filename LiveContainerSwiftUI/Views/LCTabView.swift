//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI

struct LCTabView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject var downloadHelper = DownloadHelper()
    // 「源」标签的更新红点数字（源页算好写进来的）
    @AppStorage("CZFUpdatableAppCount") var updatableAppCount = 0

    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    
    var body: some View {
        TabView(selection: $sharedModel.selectedTab) {
            if DataManager.shared.model.multiLCStatus != 2 {
                LCSourcesView()
                    .tabItem {
                        Label("lc.tabView.sources".loc, systemImage: "books.vertical")
                    }
                    .badge(updatableAppCount > 0 ? updatableAppCount : 0)
                    .tag(LCTabIdentifier.sources)
            }
            LCAppListView()
                .tabItem {
                    Label("lc.tabView.apps".loc, systemImage: "square.stack.3d.up.fill")
                }
                .tag(LCTabIdentifier.apps)
            if DataManager.shared.model.multiLCStatus != 2 {
                LCTweaksView()
                    .tabItem{
                        Label("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver")
                    }
                    .tag(LCTabIdentifier.tweaks)
            }
            
            LCSettingsView()
                .tabItem {
                    Label("lc.tabView.settings".loc, systemImage: "gearshape.fill")
                }
                .tag(LCTabIdentifier.settings)
        }
        .overlay(
            VStack {
                Spacer()
            }
        )
        .onAppear {
            // 提前把多任务管理器建起来：全局手势识别器和 Darwin
            // 监听都在它的 init 里装配，懒到第一个 App 打开才建，
            // 刚进 LiveContainer 在主界面就滑不出面板（用户实测）。
            // 管理器是 iOS 16+ 类型，与 AppDelegate 部署插件同款守卫
            if #available(iOS 16.0, *) {
                _ = MultitaskDockManager.shared
            }
            // 每次打开 App 通知源页自动刷新一次（节流在源页那边）
            NotificationCenter.default.post(name: Notification.Name("CZFRefreshSourcesRequest"), object: nil)
            // 预热节点核心：有标了 VPN 的 App 时提前起核心，
            // 第一个 VPN App 点开不用等冷启动。11（3.8.277）：
            // 前台进 App 页就预热，不过测速后的抑制——测速后
            // 抑制一直拦着预热，下一个 VPN App 每次都吃满冷启动。
            // 起核心是同步阻塞的 CGoInvoke，放 detached 跑，别卡主线程
            //（代码自注 :455；applyRestoredNodeSettings 同款）。
            Task.detached {
                CZFVPNManager.shared.prewarmIfNeeded(ignoringSuppression: true)
            }
            // 定时备份/定时清理的到点检查：原来只挂在数据管理页
            // 的 onAppear 上，不去那页就永远不触发（审计发现）。
            // 改成打开 LiveContainer 就查，到没到点由各自的
            // 日期+时间守卫决定，静默执行不弹窗
            Task {
                await LCDataManagementView.runScheduledBackupIfDue()
                await LCDataManagementView.runScheduledCacheIfDue()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            // 从后台切回前台时也预热一次（核心可能已被自动停）；
            // 同上，不过测速后的抑制。
            if newPhase == .active {
                // 起核心是同步阻塞的 CGoInvoke，放 detached 跑，别卡主线程。
                Task.detached {
                    CZFVPNManager.shared.prewarmIfNeeded(ignoringSuppression: true)
                }
                // 优5（3.8.277）：定时备份/清理的到点检查原来只在
                // 冷打开时跑（onAppear）；从后台切回也查一次，
                // 恢复/导入改了定时后不用等下次冷打开。开关与
                // 时间都是现读，到没到点由各自的日期去重守卫决定，
                // 冷打开时 onAppear 与这路各跑一次不会重复执行。
                Task {
                    await LCDataManagementView.runScheduledBackupIfDue()
                    await LCDataManagementView.runScheduledCacheIfDue()
                }
            }
        }
        .downloadAlert(helper: downloadHelper)
        .environmentObject(downloadHelper)
        // #27：错误 alert 只在崩溃 sheet 没显示时弹——冷启动
        // crashReportShow 与 errorShow 可同时为真，alert 会被
        // sheet 盖住。派生 Binding：crash sheet 关掉后若
        // errorShow 仍为真，alert 再出现；用户关掉 alert 才清 errorShow。
        .alert("lc.common.error".loc, isPresented: Binding(
            get: { errorShow && !crashReportShow },
            set: { newValue in if !newValue { errorShow = false } }
        )){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.footnote.monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if #available(iOS 16.0, *) {
                            if let log = UserDefaults.lcShared().url(forKey: "LC32BitTranslationLayerLogFile") {
                                ShareLink(item: log)
                            } else {
                                ShareLink(item: errorInfo)
                            }
                        } else {
                            Button("lc.common.copy".loc) {
                                copyError()
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        // 3.8.416：坞面板直出设置页（主 App 代弹）——面板宿主是
        // 孤儿控制器，挂它身上的 .sheet 弹不出来（411/412/414
        // 三版全灭），addChild 还会崩；改走 SharedModel 触发器：
        // 面板只写 sharedModel.czfDirectPage/App/LoginOnly，
        // 根 TabView 在这里弹 sheet（根控制器是正经
        // rootViewController，能弹）。内容与面板旧 sheet 同款
        // （NavigationView 包 destinationView，左上“关闭”）。
        // 关 sheet 清触发器（关闭按钮与下滑关行为一致），下次
        // 点按才能再触发（值不变 SwiftUI 不重弹）。
        .sheet(item: $sharedModel.czfDirectPage, onDismiss: {
            sharedModel.czfDirectApp = nil
            sharedModel.czfDirectLoginOnly = nil
        }) { page in
            NavigationView {
                page.destinationView(forDirectBackupApp: sharedModel.czfDirectApp, preselectedLoginOnly: sharedModel.czfDirectLoginOnly)
                    .navigationTitle(page.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") {
                                sharedModel.czfDirectPage = nil
                                sharedModel.czfDirectApp = nil
                                sharedModel.czfDirectLoginOnly = nil
                            }
                        }
                    }
            }
        }
        .task {
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkAndSaveBundleId()
            checkGetTaskAllow()
            checkPrivateContainerBookmark()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
    }
    
    func dispatchURL(url: URL) {
        repeat {
            if url.isFileURL {
                sharedModel.selectedTab = .apps
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.selectedTab = .apps
                break
            }
            
            guard let host = url.host?.lowercased() else {
                // 第三批低 #47：无 host 的链接原来静默丢弃，弹一次提示。
                errorInfo = "无法识别的链接"
                errorShow = true
                return
            }

            // R-5：host 是设置页标识（backupall 等）时直接走
            // czfDirectPage 直出 sheet（与面板 openSettingsPage
            // 同款出口，LCTabView 监听弹 sheet），不写 deepLink；
            // 原先落 default 弹“无法识别的链接”，设置页的
            // deepLinkSettingsPage 分支已死、一并删掉。
            if let page = CZFSettingsPage(rawValue: host) {
                sharedModel.czfDirectPage = page
                return
            }

            switch host {
            case "livecontainer-launch", "install", "open-web-page", "open-url":
                sharedModel.selectedTab = .apps
            case "certificate":
                sharedModel.selectedTab = .settings
            case "source":
                // S-2/R-7：副 LC（multiLCStatus == 2）没有源 Tab，
                // App 页 handleURL 也没有 source 分支，写进 deepLink
                // 只会被静默丢掉；直接弹错，不写 deepLink。
                if DataManager.shared.model.multiLCStatus == 2 {
                    errorInfo = "副 LC 不支持添加源，请在主 LC 里打开"
                    errorShow = true
                    return
                }
                sharedModel.selectedTab = .sources
            default:
                // 第三批低 #47：未知 host 原来静默丢弃，弹一次提示。
                errorInfo = "无法识别的链接：\(url.absoluteString)"
                errorShow = true
                return
            }
            
        } while(false)

        // 第三批低 #53：deepLink 原是单值槽，第二条链接会覆盖
        // 第一条。槽空着直接写，有链接在等就排队；消费方置 nil
        // 时 SharedModel.didSet 递补下一条。
        if sharedModel.deepLink == nil {
            sharedModel.deepLink = url
        } else {
            sharedModel.deepLinkQueue.append(url)
        }
    }
    
    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }
    
    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")
        
        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
        
        guard let errorStr else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }
            
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }
        
        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }
        
        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }
    
    func checkAndSaveBundleId() {
        if DataManager.shared.model.multiLCStatus == 2 {
            let scheme = UserDefaults.lcAppUrlScheme() ?? ""
            LCUtils.appGroupUserDefault.set(Bundle.main.bundleIdentifier, forKey: "LCBundleID.\(scheme)")
        }
        
        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }
        
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        
        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }
        
        if(bundleId != correctBundleId) {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }
    
    func checkGetTaskAllow() {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
    
    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }
        
        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}
