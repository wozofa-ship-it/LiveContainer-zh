//
//  MultitaskAppWindow.swift
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
import SwiftUI

@available(iOS 16.1, *)
struct MultitaskAppInfo {
    var displayName: String
    var dataUUID: String
    var bundleId: String
    
    init(displayName: String, dataUUID: String, bundleId: String) {
        self.displayName = displayName
        self.dataUUID = dataUUID
        self.bundleId = bundleId
    }
}

@available(iOS 16.1, *)
@objc class MultitaskWindowManager: NSObject {
    @Environment(\.openWindow) static var openWindow
    static var appDict: [String: MultitaskAppInfo] = [:]
    
    @objc class func openAppWindow(displayName: String, dataUUID: String, bundleId: String, pidCallback: ((NSNumber, Error?) -> Void)?) {
        DataManager.shared.model.enableMultipleWindow = true
        if let pidCallback {
            DataManager.shared.model.pidCallbacks[dataUUID] = pidCallback
        }
        appDict[dataUUID] = MultitaskAppInfo(displayName: displayName, dataUUID: dataUUID, bundleId: bundleId)
        openWindow(id: "appView", value: dataUUID)
    }
    
    @objc class func openExistingAppWindow(dataUUID: String) -> Bool {
        for a in appDict {
            if a.value.dataUUID == dataUUID {
                openWindow(id: "appView", value: a.key)
                return true
            }
        }
        return false
    }
}

@available(iOS 16.1, *)
struct AppSceneViewSwiftUI: UIViewControllerRepresentable {
    @Binding var show: Bool
    let bundleId: String
    let dataUUID: String
    let initSize: CGSize
    let onAppInitialize: (Int32, Error?) -> Void
    
    class Coordinator: NSObject, AppSceneViewControllerDelegate {
        let onExit: () -> Void
        let onAppInitialize: (Int32, Error?) -> Void
        init(onAppInitialize: @escaping (Int32, Error?) -> Void, onExit: @escaping () -> Void) {
            self.onAppInitialize = onAppInitialize
            self.onExit = onExit
        }
        
        func appSceneVCAppDidExit(_: AppSceneViewController!) {
            onExit()
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
            DispatchQueue.main.async {
                (vc.view.window?.windowScene?.statusBarManager as? LCStatusBarManager)?.nativeWindowViewController = vc
            }
            onAppInitialize(vc.pid, error)
        }
        
        func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
            vc.updateSettings { settings in
                guard let settings else { return }
                let defaultInsets = vc.view.window?.safeAreaInsets ?? .zero
                settings.peripheryInsets = defaultInsets
                settings.safeAreaInsetsPortrait = defaultInsets
                settings.deviceOrientation = UIDevice.current.orientation
                settings.setInterfaceOrientation(UIApplication.shared.statusBarOrientation)
                if(settings.interfaceOrientation().isLandscape) {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.height, height: vc.view.frame.size.width))
                } else {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.width, height: vc.view.frame.size.height))
                }
            }
            // fix live resize
            vc.contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!, transitionContext context: Any!, lifecycleActionType actionType: UInt32) {
            settings.interruptionPolicy = 0
            //settings.peripheryInsets = vc.view.window?.safeAreaInsets ?? .zero
            vc.presenter.scene.updateSettings(settings, withTransitionContext: context, completion: nil)
            // Not sure what actionType 2 is, but it's only set when this scene enters foreground, so we can pass URL scheme here
            if actionType == 2, let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
                vc.openURLScheme(launchUrl)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onAppInitialize: onAppInitialize, onExit: {
            show = false
            // 3.8.555（L228）：客进程退出时也摘条目——场景还活着
            // （终止屏），但 App 已经不在跑；只靠 disconnect 钩子，
            // 条目要残留到用户关场景。removeRunningApp 幂等，两处
            // 各调一次无害。本结构体没有 appInfo，只有 dataUUID。
            MultitaskDockManager.shared.removeRunningApp(dataUUID)
        })
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        return AppSceneViewController(bundleId: bundleId, dataUUID: dataUUID, delegate: context.coordinator)
    }
    
    func updateUIViewController(_ vc: UIViewController, context _: Context) {
        if let vc = vc as? AppSceneViewController {
            if !show {
                vc.terminate()
            }
        }
    }
}

@available(iOS 16.1, *)
struct MultitaskAppWindow: View {
    @State var show = true
    @State var pid = 0
    @State var appInfo: MultitaskAppInfo? = nil
    @State var errorMessage: String? = nil
    @State private var hasScheduledAutoClose = false
    @State private var didRequestManualClose = false
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @Environment(\.openWindow) var openWindow
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    // 3.8.555（L228）：原生窗口关窗信号——管理器发、本场景收
    let closePub = NotificationCenter.default.publisher(for: .czfCloseNativeWindow)
    init(id: String) {
        guard let appInfo = MultitaskWindowManager.appDict[id] else {
            return
        }
        _appInfo = State(initialValue: appInfo)
    }
    
    var body: some View {
        let isVirtualWindowMode = multitaskMode == .virtualWindow
        if show, let appInfo {
            GeometryReader { geometry in
                AppSceneViewSwiftUI(show: $show, bundleId: appInfo.bundleId, dataUUID: appInfo.dataUUID, initSize: geometry.size,
                                    onAppInitialize: { pid, error in
                    DispatchQueue.main.async {
                        if error == nil {
                            self.pid = Int(pid)
                        } else {
                            self.errorMessage = error?.localizedDescription
                        }
                        // 按 dataUUID 取回自己的回调，各回各的 continuation；
                        // 取完即删，免得下次初始化又调到旧的。
                        if let cb = DataManager.shared.model.pidCallbacks.removeValue(forKey: appInfo.dataUUID) {
                            cb(NSNumber(value: pid), error)
                        }
                    }
                })
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.all, edges: .all)
            .navigationTitle(Text("\(appInfo.displayName) - \(String(pid))"))
            .onReceive(pub) { out in
                if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                    show = false
                    // 3.8.555（L228）：场景销毁时摘坞条目——原生条目没有
                    // view，removeRunningApp 仅有的两个调用点（Decorated
                    // 退出回调、C4 死窗清理）都够不到它，条目原来永久残留、
                    // 幽灵图标一直挂着，VPN 自动停也不触发。
                    MultitaskDockManager.shared.removeRunningApp(appInfo.dataUUID)
                }
            }
            .onReceive(closePub) { note in
                // 3.8.555（L228）：管理器关窗信号——原生场景只能自己
                // 销毁（requestSceneDestruction），管理器够不到场景；
                // uuid 对上才关，别家场景不动。关后 disconnect 钩子
                // 摘条目（同上）。语义与虚拟窗 closeWindow 一致。
                guard (note.userInfo?["appUUID"] as? String) == appInfo.dataUUID else { return }
                requestSceneDestruction(isManual: true)
            }
            
        } else if skipTerminatedScreen && isVirtualWindowMode, appInfo != nil {
            Color.clear
                .ignoresSafeArea(.all, edges: .all)
                .onAppear {
                    guard !didRequestManualClose else { return }
                    if let appInfo {
                        MultitaskRelaunchManager.scheduleRelaunchIfNeeded(bundleId: appInfo.bundleId, dataUUID: appInfo.dataUUID, isManualTermination: false)
                    }
                    if !hasScheduledAutoClose {
                        hasScheduledAutoClose = true
                        DispatchQueue.main.async {
                            requestSceneDestruction(isManual: false)
                        }
                    }
                }
        } else {
            VStack {
                Text("lc.multitaskAppWindow.appTerminated".loc)
                    .font(.largeTitle)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(.body, design: .monospaced))
                    Button("lc.common.copy".loc) {
                        UIPasteboard.general.string = errorMessage
                        requestSceneDestruction(isManual: true)
                    }
                    .buttonStyle(.bordered)
                }
                Button("lc.common.close".loc) {
                    requestSceneDestruction(isManual: true)
                }
                .buttonStyle(.bordered)
            }.onAppear {
                // appInfo == nil indicates this is the first scene opened in this launch. We don't want this so we open lc's main scene and close this view
                // however lc's main view may already be starting in another scene so we wait a bit before opening the main view
                // also we have to keep the view open for a little bit otherwise lc will be killed by iOS
                if appInfo == nil {
                    if DataManager.shared.model.mainWindowOpened {
                        requestSceneDestruction()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if !DataManager.shared.model.mainWindowOpened {
                                openWindow(id: "Main")
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                requestSceneDestruction()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func requestSceneDestruction(isManual: Bool = false) {
        if isManual {
            didRequestManualClose = true
        }
        guard let session = sceneDelegate.window?.windowScene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
            print(error)
        }
    }
}

@objcMembers
class MultitaskRelaunchManager: NSObject {
    private static var pendingKeys: Set<String> = []
    private static let pendingLock = NSLock()
    
    static func scheduleRelaunchIfNeeded(bundleId: String, dataUUID: String, isManualTermination: Bool) {
        let defaults = LCUtils.appGroupUserDefault
        let multitaskMode = MultitaskMode(rawValue: defaults.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        guard defaults.bool(forKey: "LCSkipTerminatedScreen"),
              defaults.bool(forKey: "LCRestartTerminatedApp"),
              multitaskMode == .virtualWindow,
              !isManualTermination else { return }
        
        let key = "\(bundleId)#\(dataUUID)"
        guard markPendingIfNeeded(key: key) else { return }
        
        Task {
            defer { clearPending(key: key) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await relaunchApp(bundleId: bundleId, dataUUID: dataUUID)
        }
    }
    
    private static func markPendingIfNeeded(key: String) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if pendingKeys.contains(key) {
            return false
        }
        pendingKeys.insert(key)
        return true
    }
    
    private static func clearPending(key: String) {
        pendingLock.lock()
        pendingKeys.remove(key)
        pendingLock.unlock()
    }
    
    private static func relaunchApp(bundleId: String, dataUUID: String) async {
        guard let appModel = await MainActor.run(body: { lookupAppModel(bundleId: bundleId) }),
              appModel.appInfo.lastLaunched.distance(to: .now) > 2
        else {
            return
        }
        
        do {
            // 3.8.558（L242-1）：内置 SideStore 走 openSideStore 同款
            // override 再起——见 lookupAppModel 注释；普通 App 不动。
            if appModel.appInfo is BuiltInSideStoreAppInfo {
                try await appModel.runApp(multitask: true, containerFolderName: dataUUID, bundleIdOverride: bundleId)
            } else {
                try await appModel.runApp(multitask: true, containerFolderName: dataUUID)
            }
        } catch {
            print("Failed to restart \(bundleId): \(error)")
        }
    }
    
    @MainActor private static func lookupAppModel(bundleId: String) -> LCAppModel? {
        let sharedModel = DataManager.shared.model
        if let app = sharedModel.apps.first(where: { $0.appInfo.relativeBundlePath == bundleId }) {
            return app
        }
        if let app = sharedModel.hiddenApps.first(where: { $0.appInfo.relativeBundlePath == bundleId }) {
            return app
        }
        // 3.8.558（L242-1）：内置 SideStore 的“重启已终止的 App”从没
        // 生效过——启动时 "selected" 写的是 bundleIdOverride 的
        // "builtinSideStore"（openSideStore，LCUtilsExtensions:967），
        // 这里只按 relativeBundlePath 在 apps/hiddenApps 两表里找；
        // SideStore 是合成模型（不在两表里）、relativeBundlePath
        // 又是 nil（BuiltInSideStoreAppInfo 从不设它），永远找不
        // 到、relaunchApp 在 guard 处静默 return。普通 App 不受
        // 影响（"selected" 就是 relativeBundlePath）。
        if bundleId == "builtinSideStore" {
            return LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        return nil
    }
}
