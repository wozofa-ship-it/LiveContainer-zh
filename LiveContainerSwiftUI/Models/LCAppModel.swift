import Foundation

protocol LCAppModelDelegate {
    func closeNavigationView()
    func changeAppVisibility(app : LCAppModel)
    func jitLaunch(appName: String, classicMode: UInt, selectedBundlePath: String?, selectedContainerFolder: String?, launchURL: String?) async -> Bool
    func jitLaunch(withScript script: String, appName: String, classicMode: UInt, selectedBundlePath: String?, selectedContainerFolder: String?, launchURL: String?) async -> Bool
    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async
    func showRunWhenMultitaskAlert() async -> Bool?
}

class LCAppModel: ObservableObject, Hashable {
    
    @Published var appInfo : LCAppInfo
    
    @Published var isAppRunning = false
    // 同步启动互斥（3.8.459 审计）：isAppRunning 的置位在
    // runApp 内多个 await 之后，连点两次会双双越过首行守卫、
    // 双签双起（同容器还会在启动门里挂两个同 uuid 等待者）。
    // 这把锁在首行同步抢占、中间无 await 间隙；全程持有，
    // 退出即放。isAppRunning 仍是 UI 侧的运行指示，不动它。
    private let czfLaunchLock = NSLock()
    private var czfLaunchInFlight = false
    private func czfClaimLaunch() -> Bool {
        czfLaunchLock.lock()
        defer { czfLaunchLock.unlock() }
        guard !czfLaunchInFlight else { return false }
        czfLaunchInFlight = true
        return true
    }
    private func czfReleaseLaunch() {
        czfLaunchLock.lock()
        czfLaunchInFlight = false
        czfLaunchLock.unlock()
    }

    // S-1/F-1/F-2：共享锁守卫（全仓唯一一份新入口共用；banner、
    // 列表、launchAppWithBundleId 的现有守卫不动，不改它们的认证
    // 流程与报错出口）。锁了且没解锁过就先弹人脸，通过返回 true；
    // 取消或抛错返回 false，调用方直接 return。
    // LCUtils.authenticateUser 成功后置 isHiddenAppUnlocked，后面
    // 同款检查直接短路，不弹第二次人脸。静态版供只有 LCAppInfo
    // 的入口（坞图标/运行条/右缘轮切）用；实例版供有 LCAppModel
    // 的入口用，谓词只写在静态版这一处。
    static func czfAuthenticateIfLocked(appInfo: LCAppInfo) async -> Bool {
        guard appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked else { return true }
        do {
            return try await LCUtils.authenticateUser()
        } catch {
            return false
        }
    }

    func czfAuthenticateIfLocked() async -> Bool {
        await Self.czfAuthenticateIfLocked(appInfo: appInfo)
    }

    // MARK: - F-4/F-10：带回 / 拉满 / 最小化 / 小窗口共用助手
    // banner / 网格 / 面板三处原来各写一遍“dock 里找条目 → 带回并
    // 拉满/还原小窗/最小化”与“起完等窗进 dock 再拉满”，行为已分叉
    // （面板只用 dataUUID 查 dock、拉满重试只等 2 秒；banner/网格
    // 用选中容器优先、等 6 秒）。抽到这里，三处共用同一份。
    // 调用约定：主线程调（调用方原来就是按钮动作 / MainActor.run，
    // 与被替换的代码一致）；认证不在这里做，调用方带回/启动前
    // 先过守卫（面板 F-1、banner O-3）。
    // runApp 内的 bringExistingMultitaskWindowIfNeeded 不走这里：
    // 它只带回不改尺寸、还管 launchAppUrlScheme，语义不同。

    /// 实例 UUID：选中容器的 folderName 优先，dataUUID 回落。
    /// banner 的 bannerInstanceUUID 与面板的 dataUUID 原来各取各的，
    /// 选中容器与 dataUUID 不一致时行为分叉；统一到这一处。
    var czfInstanceUUID: String? {
        uiSelectedContainer?.folderName ?? appInfo.dataUUID
    }

    /// dock 里找归属对得上的条目：没有条目、条目归属对不上、
    /// 或归属验不出（appInfo 缺失/路径为空）都返回 nil，调用方
    /// 走新起；宁可多起一个窗口，不顶错别人的。
    @available(iOS 16.0, *)
    private static func czfOwnedDockEntry(app: LCAppModel, uuid: String) -> DockAppModel? {
        guard let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let runningPath = entry.appInfo?.relativeBundlePath, !runningPath.isEmpty,
              runningPath == app.appInfo.relativeBundlePath else { return nil }
        return entry
    }

    /// F-4：带回共用——banner / 网格 / 面板三处原来各写一遍。
    /// dock 里归属对得上的条目 → 带回；maximize=true 时顺手拉满，
    /// false 时顺手还原成小窗（maximizeWindow 是切换式）。
    /// 返回 true = 已处理（调用方直接 return，不再新起）；
    /// false = 没带回（调用方走新起）。
    /// 死窗兜底：bring 没抬动、条目还在、不是本次 C4 清掉的死窗时，
    /// 窗已在前台——拉满路按旧行为返回 brought（拿不到 VC 时走新起），
    /// 小窗路返回 true（旧行为：只还原不重起）。
    /// 没有 dock 条目时：拉满路保留旧行为，只带回不拉满（没 decorated
    /// VC 可拉）；小窗路不试带回（旧行为：直接走未运行分支起新窗）。
    static func czfBringRunningAppToFront(_ app: LCAppModel, maximize: Bool) -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        guard let uuid = app.czfInstanceUUID else { return false }
        let dockManager = MultitaskDockManager.shared
        if let runningApp = czfOwnedDockEntry(app: app, uuid: uuid) {
            var brought = false
            if #available(iOS 16.1, *) {
                brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
            }
            if !brought {
                brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
            }
            // 带回成功拉满；带回失败但条目还在且不是本次 C4 清掉的
            // 死窗（窗已在前台、只是 bring 没抬动）同样拉满，别再
            // 静默空转回小窗。
            let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == uuid
            let entryGone = !dockManager.apps.contains(where: { $0.appUUID == uuid })
            if brought || (!cleanedByC4 && !entryGone) {
                // maximizeWindow 是切换式：拉满先判 !isMaximized，
                // 否则已是最大窗会被反切回小窗；还原先判 isMaximized。
                // 死窗兜底：bring 没抬动、条目还在、但拿不到 VC 时
                // 不是“窗已在前台”，是死窗——拉满路返回 brought
                // （false 即走新起），小窗路返回 true（只还原不重起）。
                if let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController {
                    if maximize {
                        if !vc.isMaximized {
                            vc.maximizeWindow()
                        }
                    } else if vc.isMaximized {
                        vc.maximizeWindow()
                    }
                    return true
                }
                return maximize ? brought : true
            }
        } else if dockManager.apps.contains(where: { $0.appUUID == uuid }) {
            // 条目在但归属对不上，不碰，返回 false 走新起。
            return false
        } else {
            // 没有 dock 条目（原生窗口模式等）：拉满路保留旧行为，
            // 只带回不拉满，带回失败再落到新起；小窗路不试带回。
            guard maximize else { return false }
            var brought = false
            if #available(iOS 16.1, *) {
                brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
            }
            if !brought {
                brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
            }
            if brought {
                return true
            }
        }
        return false
    }

    /// F-10：还原小窗共用——banner 静态版与面板实例版原来各写一遍，
    /// 一字相同。窗口已最大化时点一下（maximizeWindow 是切换式）
    /// 还原成小窗。
    @available(iOS 16.0, *)
    static func czfUnmaximizeWindow(uuid: String) {
        guard let runningApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
              vc.isMaximized else { return }
        vc.maximizeWindow()
    }

    /// 小窗口回落路专用（3.8.239）：czfOnWindowAppeared 是“同 uuid
    /// 条目已存在就立即回调”、不验归属——同容器被别的条目占着时，
    /// 回调会把别人的窗口还原成小窗。动作前再按路径复验一次，
    /// 对不上/验不出就什么都不做，别动别人的窗口。
    @available(iOS 16.0, *)
    static func czfUnmaximizeWindowIfOwned(uuid: String, expectedPath: String?) {
        guard let expectedPath,
              let runningApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty,
              runningPath == expectedPath else { return }
        czfUnmaximizeWindow(uuid: uuid)
    }

    /// F-10：最小化已在运行分支共用——banner 与面板原来各写一遍：
    /// dock 里归属对得上的条目 → 直接最小化。返回 true = 已处理。
    /// 最小化不露内容，不要认证；未运行分支的启动才要认证（调用方做）。
    static func czfMinimizeRunningWindow(_ app: LCAppModel) -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        guard let uuid = app.czfInstanceUUID,
              czfOwnedDockEntry(app: app, uuid: uuid) != nil else { return false }
        MultitaskDockManager.shared.minimizeWindow(uuid: uuid)
        return true
    }

    /// F-4：起完拉满共用——banner / 网格 / 面板三处原来各写一遍
    /// “等窗进 dock → 按路径验归属 → 拉满”，重试上限统一 6 秒
    /// （面板原来 2 秒，签名慢的包拉不满）。uuid 每轮重取：容器
    /// 中途换了就跟新值（面板同款语义，F-3 同款保护）。
    @available(iOS 16.0, *)
    static func czfPollAndMaximizeFreshWindow(app: LCAppModel) {
        let expectedPath = app.appInfo.relativeBundlePath
        let deadline = Date().addingTimeInterval(6)
        czfWaitUUIDThenMaximizeFreshWindow(app: app, expectedPath: expectedPath, deadline: deadline)
    }

    /// 容器还没建出来（uuid 为空）时等容器出现再注册窗口回调，
    /// 上限 6 秒（原轮询同款预算）；等不到就停，不报错。
    @available(iOS 16.0, *)
    private static func czfWaitUUIDThenMaximizeFreshWindow(app: LCAppModel, expectedPath: String?, deadline: Date) {
        if let uuid = app.czfInstanceUUID {
            MultitaskDockManager.shared.czfOnWindowAppeared(uuid: uuid, timeout: max(0, deadline.timeIntervalSinceNow)) {
                czfRetryMaximizeFreshWindow(app: app, deadline: deadline)
            }
            return
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            czfWaitUUIDThenMaximizeFreshWindow(app: app, expectedPath: expectedPath, deadline: deadline)
        }
    }

    /// 返回 true = 已处理完（已拉满，或归属不对停表不再碰）。
    /// uuid 每轮重取：容器中途换了就跟新值。
    @available(iOS 16.0, *)
    private static func czfTryMaximizeFreshWindow(app: LCAppModel) -> Bool {
        let expectedPath = app.appInfo.relativeBundlePath
        guard let uuid = app.czfInstanceUUID,
              let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }) else { return false }
        let owned: Bool
        if let runningPath = entry.appInfo?.relativeBundlePath, !runningPath.isEmpty {
            owned = runningPath == expectedPath
        } else {
            owned = false
        }
        if !owned { return true }
        guard let vc = entry.view?._viewDelegate() as? DecoratedAppSceneViewController else { return false }
        if !vc.isMaximized {
            vc.maximizeWindow()
        }
        return vc.isMaximized
    }

    @available(iOS 16.0, *)
    private static func czfRetryMaximizeFreshWindow(app: LCAppModel, deadline: Date) {
        guard !czfTryMaximizeFreshWindow(app: app) else { return }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            czfRetryMaximizeFreshWindow(app: app, deadline: deadline)
        }
    }

    /// F-10：最小化共用助手——banner 与面板共用（带回 + 归属校验 +
    /// 未运行启动 + 超时反馈四段里的后三段由骨架做，运行中分支
    /// 在这里）。调用方负责认证（banner 在按钮里先过守卫，面板
    /// 在外层先认证）与关面板/记偏好。onError 是失败反馈出口
    /// （banner 传 showError，面板传 reportLaunchError）；
    /// onProceed 在 uuid 验过后立刻调一次（面板用它关面板，
    /// banner 不用，默认空）——运行中分支与未运行分支都只关这一次，
    /// 助手返回后调用方不用再关。
    static func czfMinimizeApp(
        _ app: LCAppModel,
        onError: @escaping (String) -> Void,
        onProceed: @escaping () -> Void = {}
    ) async {
        guard #available(iOS 16.0, *) else { return }
        guard app.czfInstanceUUID != nil else { return }
        onProceed()
        if czfMinimizeRunningWindow(app) { return }
        let expectedPath = app.appInfo.relativeBundlePath
        let dockManager = MultitaskDockManager.shared
        await czfLaunchThenActOnWindow(
            app: app,
            multitask: nil,
            timeout: 6,
            timeoutMessage: "最小化超时：6 秒内没等到「\(app.appInfo.displayName() ?? "App")」的窗口，请确认 App 已打开后重试",
            action: { waitUUID in
                if let entry = dockManager.apps.first(where: { $0.appUUID == waitUUID }) {
                    let owned = entry.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 == expectedPath } ?? false
                    if owned {
                        dockManager.minimizeWindow(uuid: waitUUID)
                    }
                }
            },
            onError: onError
        )
    }

    /// F-10：小窗口共用助手——banner 与面板共用。未运行分支：
    /// 窗出来 0.35 秒后还原为小窗；30 秒未出现放弃等，到期报一次
    /// 超时（F-3：原来静默放弃）。其余约定与 czfMinimizeApp 同款。
    static func czfSmallWindowApp(
        _ app: LCAppModel,
        onError: @escaping (String) -> Void,
        onProceed: @escaping () -> Void = {}
    ) async {
        guard #available(iOS 16.0, *) else { return }
        guard app.czfInstanceUUID != nil else { return }
        onProceed()
        if czfBringRunningAppToFront(app, maximize: false) { return }
        let expectedPath = app.appInfo.relativeBundlePath
        await czfLaunchThenActOnWindow(
            app: app,
            multitask: true,
            timeout: 30,
            timeoutMessage: "小窗口超时：30 秒内没等到「\(app.appInfo.displayName() ?? "App")」的窗口，请确认 App 已打开后重试",
            action: { waitUUID in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    czfUnmaximizeWindowIfOwned(uuid: waitUUID, expectedPath: expectedPath)
                }
            },
            onError: onError
        )
    }

    /// F-10：未运行分支的共用骨架——最小化/小窗口共用：
    /// ① 在旧 uuid 上注册“窗出现即动作”回调；② 调 launch 启动；
    /// ③ 启动完重读 uuid，换了就在新 uuid 上再注册一次（F-3：
    /// 拆容器换号后旧 uuid 等不来新窗）；④ 到期动作没跑就经
    /// onError 报一次超时。action 在窗口出现时调；timeout 是
    /// 等窗预算（秒）；launch 抛错时经 onError 报启动错、不再报超时。
    @available(iOS 16.0, *)
    private static func czfLaunchThenActOnWindow(
        app: LCAppModel,
        multitask: Bool?,
        timeout: TimeInterval,
        timeoutMessage: String,
        action: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async {
        guard let uuid = app.czfInstanceUUID else { return }
        let deadline = Date().addingTimeInterval(timeout)
        var done = false
        let act: (String) -> Void = { waitUUID in
            action(waitUUID)
            done = true
        }
        MultitaskDockManager.shared.czfOnWindowAppeared(uuid: uuid, timeout: timeout) {
            act(uuid)
        }
        do {
            try await app.runApp(multitask: multitask, containerFolderName: uuid)
        } catch {
            onError(error.localizedDescription)
            return
        }
        if let freshUUID = app.czfInstanceUUID, freshUUID != uuid, Date() < deadline {
            MultitaskDockManager.shared.czfOnWindowAppeared(uuid: freshUUID, timeout: max(0, deadline.timeIntervalSinceNow)) {
                act(freshUUID)
            }
        }
        Task { @MainActor in
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            if !done {
                onError(timeoutMessage)
            }
        }
    }

    @Published var isSigningInProgress = false
    @Published var signProgress = 0.0
    private var observer : NSKeyValueObservation?
    
    @Published var uiIsJITNeeded : Bool {
        didSet {
            appInfo.isJITNeeded = uiIsJITNeeded
        }
    }
    @Published var uiHelperProcessesSupport: Bool {
        didSet {
            appInfo.helperProcessesSupport = uiHelperProcessesSupport
        }
    }
    @Published var uiClassicMode : Bool {
        didSet {
            appInfo.classicMode = uiClassicMode
        }
    }
    @Published var uiIsHidden : Bool
    @Published var uiIsLocked : Bool
    @Published var uiIsShared : Bool
    @Published var uiDefaultDataFolder : String?
    @Published var uiContainers : [LCContainer]
    @Published var uiSelectedContainer : LCContainer?
    @Published var uiIs32bit : Bool
    @Published var uiIs32bitEmulator : Bool
    @Published var uiTweakFolder : String? {
        didSet {
            appInfo.tweakFolder = uiTweakFolder
        }
    }
    /// 模块文件夹多选：存储仍是一个字符串（LCTweakFolder），
    /// 多个文件夹名用 | 拼接——旧的单值天然就是单元素，向后
    /// 兼容不用迁移。TweakLoader 侧按同一规则拆开逐个加载
    static func czfSplitTweakFolders(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: "|").map { String($0) }.filter { !$0.isEmpty }
    }
    static func czfJoinTweakFolders(_ folders: [String]) -> String? {
        folders.isEmpty ? nil : folders.joined(separator: "|")
    }
    var uiTweakFolders: [String] {
        Self.czfSplitTweakFolders(uiTweakFolder)
    }
    func toggleTweakFolder(_ name: String) {
        var folders = uiTweakFolders
        if let idx = folders.firstIndex(of: name) {
            folders.remove(at: idx)
        } else {
            folders.append(name)
        }
        uiTweakFolder = Self.czfJoinTweakFolders(folders)
    }
    @Published var uiDoSymlinkInbox : Bool {
        didSet {
            appInfo.doSymlinkInbox = uiDoSymlinkInbox
        }
    }
    @Published var uiUseLCBundleId : Bool {
        didSet {
            appInfo.doUseLCBundleId = uiUseLCBundleId
        }
    }
    
    @Published var uiFixFilePickerNew : Bool {
        didSet {
            appInfo.fixFilePickerNew = uiFixFilePickerNew
        }
    }
    @Published var uiFixLocalNotification : Bool {
        didSet {
            appInfo.fixLocalNotification = uiFixLocalNotification
        }
    }
    @Published var uiFixBackgroundTaskIdentifiers : Bool {
        didSet {
            appInfo.fixBackgroundTaskIdentifiers = uiFixBackgroundTaskIdentifiers
        }
    }
    
    @Published var uiHideLiveContainer : Bool {
        didSet {
            appInfo.hideLiveContainer = uiHideLiveContainer
        }
    }
    @Published var uiTweakLoaderInjectFailed : Bool
    @Published var uiDontInjectTweakLoader : Bool {
        didSet {
            appInfo.dontInjectTweakLoader = uiDontInjectTweakLoader
        }
    }
    @Published var uiDontLoadTweakLoader : Bool {
        didSet {
            appInfo.dontLoadTweakLoader = uiDontLoadTweakLoader
        }
    }
    @Published var uiOrientationLock : LCOrientationLock {
        didSet {
            appInfo.orientationLock = uiOrientationLock
        }
    }
    @Published var uiSelectedLanguage : String {
        didSet {
            appInfo.selectedLanguage = uiSelectedLanguage
        }
    }
    
    @Published var uiDontSign : Bool {
        didSet {
            appInfo.dontSign = uiDontSign
        }
    }
    
    @Published var jitLaunchScriptJs: String? {
        didSet {
            appInfo.jitLaunchScriptJs = jitLaunchScriptJs
        }
    }
    
    @Published var uiSelected32BitEmulator : String {
        didSet {
            appInfo.selected32BitEmulator = uiSelected32BitEmulator
        }
    }
    
    @Published var uiSpoofSDKVersion : Bool {
        didSet {
            appInfo.spoofSDKVersion = uiSpoofSDKVersion
        }
    }
    
    @Published var uiRemark : String {
        didSet {
            appInfo.remark = uiRemark
        }
    }

    // 多开自定义名：改这里就改列表名和之后备份的文件夹名，
    // 清空 = 回到包内原名。
    @Published var uiCustomDisplayName : String {
        didSet {
            appInfo.customDisplayName = uiCustomDisplayName
        }
    }
    
    @Published var uiIsMultitaskModeSpecificed : MultitaskSpecified {
        didSet {
            appInfo.multitaskSpecified = uiIsMultitaskModeSpecificed;
        }
    }
    
    public var bundleIdentifier: String {
        get {
            return appInfo.bundleIdentifier() ?? "?"
        }
    }
    
    public var version: String {
        get {
            return appInfo.version() ?? "?"
        }
    }
    
    public var displayName: String {
        get {
            return appInfo.displayName() ?? "?"
        }
    }
    
    public var shouldLaunchInMultitaskMode : Bool {
        get {
            if #available(iOS 16.0, *) {
                return uiIsMultitaskModeSpecificed == .yes ||
                (uiIsMultitaskModeSpecificed == .default && UserDefaults.standard.bool(forKey: "LCLaunchInMultitaskMode"))
            } else {
                return false
            }
        }
    }
    
    @Published var supportedLanguages : [String]?
    
    var delegate : LCAppModelDelegate?
    
    init(appInfo : LCAppInfo, delegate: LCAppModelDelegate? = nil) {
        self.appInfo = appInfo
        self.delegate = delegate

        if !appInfo.isLocked && appInfo.isHidden {
            appInfo.isLocked = true
        }
        
        self.uiIsJITNeeded = appInfo.isJITNeeded
        self.uiHelperProcessesSupport = appInfo.helperProcessesSupport
        self.uiClassicMode = appInfo.classicMode
        self.uiIsHidden = appInfo.isHidden
        self.uiIsLocked = appInfo.isLocked
        self.uiIsShared = appInfo.isShared
        self.uiSelectedLanguage = appInfo.selectedLanguage ?? ""
        self.uiDefaultDataFolder = appInfo.dataUUID
        self.uiContainers = appInfo.containers
        self.uiTweakFolder = appInfo.tweakFolder
        self.uiDoSymlinkInbox = appInfo.doSymlinkInbox
        self.uiOrientationLock = appInfo.orientationLock
        self.uiIsMultitaskModeSpecificed = appInfo.multitaskSpecified
        self.uiUseLCBundleId = appInfo.doUseLCBundleId
        self.uiFixFilePickerNew = appInfo.fixFilePickerNew
        self.uiFixLocalNotification = appInfo.fixLocalNotification
        self.uiFixBackgroundTaskIdentifiers = appInfo.fixBackgroundTaskIdentifiers
        self.uiHideLiveContainer = appInfo.hideLiveContainer
        self.uiDontInjectTweakLoader = appInfo.dontInjectTweakLoader
        self.uiTweakLoaderInjectFailed = appInfo.info()["LCTweakLoaderCantInject"] as? Bool ?? false
        self.uiDontLoadTweakLoader = appInfo.dontLoadTweakLoader
        self.uiDontSign = appInfo.dontSign
        self.jitLaunchScriptJs = appInfo.jitLaunchScriptJs
        self.uiSelected32BitEmulator = appInfo.selected32BitEmulator ?? ""
        self.uiSpoofSDKVersion = appInfo.spoofSDKVersion
        self.uiRemark = appInfo.remark ?? ""
        self.uiCustomDisplayName = appInfo.customDisplayName ?? ""
        self.uiIs32bit = appInfo.is32bit
        self.uiIs32bitEmulator = appInfo.is32bitEmulator
        for container in uiContainers {
            if container.folderName == uiDefaultDataFolder {
                self.uiSelectedContainer = container;
                break
            }
        }
    }
    
    static func == (lhs: LCAppModel, rhs: LCAppModel) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    
    // 多开数据隔离：同包名有多个 App 条目（不同名字、不同包
    // 文件夹）时，各实例必须各用各的数据。LiveContainer 默认
    // 有两条共享通道：App Group 默认不隔离（所有容器走同一
    // 个 AppGroup 文件夹）、钥匙串组是 0..<128 随机（多实例
    // 时会撞组，撞上就共用登录态）。新容器、已有容器都在启
    // 动时一次性隔离：App Group 隔离 + 厂商标识伪装 + 钥匙串
    // 组改成同包名下没人用的组。隔离只做一次（打标记），之
    // 后用户在容器设置里亲手改的开关不再被自动翻回去。
    private func czfOtherSameBundleApps() -> [LCAppModel] {
        let myPath = appInfo.relativeBundlePath
        return (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps).filter {
            $0 !== self && $0.bundleIdentifier == bundleIdentifier && $0.appInfo.relativeBundlePath != myPath
        }
    }
    private func czfFreeKeychainGroup(excluding container: LCContainer) -> Int {
        var used = Set<Int>()
        for app in DataManager.shared.model.apps + DataManager.shared.model.hiddenApps {
            for c in app.uiContainers where c !== container {
                let g = c.keychainGroupId
                if g >= 0 { used.insert(g) }
            }
        }
        for c in uiContainers where c !== container {
            let g = c.keychainGroupId
            if g >= 0 { used.insert(g) }
        }
        let free = (0..<SharedModel.keychainAccessGroupCount).filter { !used.contains($0) }
        return free.randomElement() ?? Int.random(in: 0..<SharedModel.keychainAccessGroupCount)
    }
    // 多开容器拆分（视频实证）：同包名两个 App 条目若指到
    // 同一个容器文件夹，启动时按容器找窗口、按容器查占用都会
    // 把第一个的窗口顶回来，第二个永远起不来，数据、登录态
    // 也天然同一份。v189 只改了钥匙串组/App Group/厂商标识，
    // 没动这条按容器找窗口的路由，盖不住它。启动前若选中
    // 的容器被同包名别的条目也在用，就给本条目新建一个空
    // 容器并切过去：旧容器留在列表里不删，旧数据归原来那
    // 个条目，新条目从空数据起，之后各用各的。只拆选中
    // 的那一个，不动别的容器。
    private func czfSplitSharedContainerIfNeeded() {
        guard !czfOtherSameBundleApps().isEmpty else { return }
        guard let selected = uiSelectedContainer else { return }
        let sharedFolder = selected.folderName
        let isSharedWithOther = czfOtherSameBundleApps().contains { other in
            other.uiContainers.contains { $0.folderName == sharedFolder }
        }
        guard isSharedWithOther else { return }
        // 拆分换容器时把待恢复的钥匙串排队文件一起带过去：
        // 恢复只把 CZFKeychainImport.plist 写进恢复时已有的容器，
        // 启动若切到别的容器（复用旧的或新建的），文件留在旧容器
        // 里、桥在新容器里看不到，imported=0/0、登录回不来——
        // 多开 App 时好时坏的根因之一。文件跟启动走；目标已有
        // 文件时不动（恢复时已写过一份），只补缺的。
        let carryPendingKeychainImport: (LCContainer) -> Void = { newContainer in
            let fm = FileManager.default
            let src = selected.containerURL.appendingPathComponent("CZFKeychainImport.plist")
            let dst = newContainer.containerURL.appendingPathComponent("CZFKeychainImport.plist")
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        // 旧数据归先装的那一个：先装的条目不拆、继续用旧容器，
        // 后装的条目才拆到新容器，不然先启动的那个反而丢了
        // 旧数据、后启动的那个却捡了旧数据，完全反了。先按
        // installationDate 判，缺失时按包文件夹名判：克隆的
        // 文件夹是 包名_时间戳.app，原装的是 包名.app。
        for other in czfOtherSameBundleApps() where other.uiContainers.contains(where: { $0.folderName == sharedFolder }) {
            if let myDate = appInfo.installationDate, let otherDate = other.appInfo.installationDate {
                if myDate < otherDate { return }
            } else {
                let myPath = appInfo.relativeBundlePath ?? ""
                let otherPath = other.appInfo.relativeBundlePath ?? ""
                let myStamped = myPath.range(of: "_\\d+\\.app$", options: .regularExpression) != nil
                let otherStamped = otherPath.range(of: "_\\d+\\.app$", options: .regularExpression) != nil
                if !myStamped && otherStamped { return }
            }
        }
        // 已有不共享的容器时直接切过去，不再新建（容器越生越多根因之二）：
        // 共享容器被重选（旧备份恢复把 dataUUID 指回旧容器、菜单点回旧容器）
        // 时，原来每次都要造一个新 UUID，列表只增不减；本条目自己的容器
        // （上次拆出来的、最新那个）数据就是本条目的，复用它隔离性不变，
        // 还保住了数据。取最后一个：多次拆分留下的孤儿在前面，最新在最后。
        // 本条目一个不共享的容器都没有时，才走下面新建。
        let others = czfOtherSameBundleApps()
        if let own = uiContainers.filter({ folder in
            !others.contains { other in
                other.uiContainers.contains { $0.folderName == folder.folderName }
            }
        }).last {
            uiSelectedContainer = own
            uiDefaultDataFolder = own.folderName
            appInfo.dataUUID = own.folderName
            carryPendingKeychainImport(own)
            return
        }
        let newName = NSUUID().uuidString
        let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
        newContainer.enableMultiOpenIsolation()
        let group = czfFreeKeychainGroup(excluding: newContainer)
        uiContainers.append(newContainer)
        uiSelectedContainer = newContainer
        appInfo.containers = uiContainers
        newContainer.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier, keychainGroupId: group)
        appInfo.dataUUID = newName
        uiDefaultDataFolder = newName
        carryPendingKeychainImport(newContainer)
    }
    private func czfIsolateMultiOpenContainersIfNeeded() {
        guard !czfOtherSameBundleApps().isEmpty else { return }
        // V2：老标记只含 App Group / IDFV / 钥匙串组，换新标记让
        // 已隔离过的分身也跑一遍，把设备指纹补上（重跑是幂等的，
        // 已分好的组不换，只补没开的那几项）。
        let markerKey = "CZFMultiOpenIsolatedV2-\(bundleIdentifier)-\(appInfo.relativeBundlePath ?? "")"
        if UserDefaults.standard.bool(forKey: markerKey) { return }
        var otherGroups = Set<Int>()
        var otherFolders = Set<String>()
        for app in czfOtherSameBundleApps() {
            for c in app.uiContainers {
                otherFolders.insert(c.folderName)
                let g = c.keychainGroupId
                if g >= 0 { otherGroups.insert(g) }
            }
        }
        for container in uiContainers {
            // 共享容器不碰：它的 plist 是两个条目共用的文件，改它
            // 会把另一个条目的组也翻掉，来回 ping-pong；拆分后
            // 选中的已是新容器，旧共享容器只留给原来那个条目。
            if otherFolders.contains(container.folderName) { continue }
            var newGroup = container.keychainGroupId
            if newGroup < 0 || otherGroups.contains(newGroup) {
                newGroup = czfFreeKeychainGroup(excluding: container)
            }
            if !container.isolateAppGroup || !container.spoofIdentifierForVendor || !container.spoofDeviceFingerprint || container.keychainGroupId != newGroup {
                container.enableMultiOpenIsolation()
                container.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier, keychainGroupId: newGroup)
            }
            if newGroup >= 0 { otherGroups.insert(newGroup) }
        }
        if !uiContainers.isEmpty {
            UserDefaults.standard.set(true, forKey: markerKey)
        }
    }

    // You should let LCAppModel.runApp to decide whether to run in multitask mode, but you may override the multitask parameter if necessary
    func runApp(multitask: Bool? = nil, containerFolderName : String? = nil, bundleIdOverride : String? = nil, urlStr : String? = nil, forceJIT: Bool? = nil) async throws{
        // 先抢同步锁再读 isAppRunning：forceResign 也置
        // isAppRunning（不走这把锁），两重守卫各拦一侧。
        guard czfClaimLaunch() else {
            return
        }
        defer { czfReleaseLaunch() }
        if isAppRunning {
            return
        }

        if uiContainers.isEmpty {
            let newName = NSUUID().uuidString
            let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
            let isMultiOpen = !czfOtherSameBundleApps().isEmpty
            let group: Int
            if isMultiOpen {
                newContainer.enableMultiOpenIsolation()
                group = czfFreeKeychainGroup(excluding: newContainer)
            } else {
                group = Int.random(in: 0..<SharedModel.keychainAccessGroupCount)
            }
            uiContainers.append(newContainer)
            if uiSelectedContainer == nil {
                uiSelectedContainer = newContainer;
            }
            appInfo.containers = uiContainers;
            newContainer.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: group)
            // 3.8.377：卸载重装后首次启动新建容器时，把磁盘上已有容器里的
            // CZFKeychainImport.plist 带过来——恢复时排队文件只写进了旧容器
            // 37EDAD10（375 的恢复时循环是空操作：恢复时根本不存在第二个
            // 容器），新容器里没有，桥就读不到令牌。只补缺的，不覆盖已有的。
            do {
                let containerDir = newContainer.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath
                let dst = newContainer.containerURL.appendingPathComponent("CZFKeychainImport.plist")
                if !FileManager.default.fileExists(atPath: dst.path),
                   let entries = try? FileManager.default.contentsOfDirectory(at: containerDir, includingPropertiesForKeys: nil) {
                    for entry in entries where entry.lastPathComponent != newName {
                        let src = entry.appendingPathComponent("CZFKeychainImport.plist")
                        if FileManager.default.fileExists(atPath: src.path) {
                            try? FileManager.default.copyItem(at: src, to: dst)
                            break
                        }
                    }
                }
            }
            appInfo.dataUUID = newName
            uiDefaultDataFolder = newName
            if isMultiOpen {
                UserDefaults.standard.set(true, forKey: "CZFMultiOpenIsolatedV2-\(bundleIdentifier)-\(appInfo.relativeBundlePath ?? "")")
            }
        }
        czfIsolateMultiOpenContainersIfNeeded()
        if let containerFolderName {
            uiSelectedContainer = uiContainers.first { $0.folderName == containerFolderName } ?? uiSelectedContainer
        }
        // 拆分只做一次、且只在最终选中定下来后做（容器越生越多根因之一）：
        // 原来选前先拆一次、选后再拆一次，面板传 dataUUID 时若选前已是
        // 共享容器，第一次拆出的新容器会被随后的指定选中覆盖、直接成
        // 孤儿留在列表里，第二次又拆一个——一次启动多两个容器。
        // 只留这一次：containerFolderName 为空时选中没变，等同于原来
        // 的第一次；指定了容器时拆的就是最终那个，不造孤儿。
        // 拆完选中已是新容器，当前文件夹就以选中为准，不再
        // 用旧的 containerFolderName，否则拆了也白拆。
        czfSplitSharedContainerIfNeeded()
        let currentDataFolder = uiSelectedContainer?.folderName
        
        let classicMode = appInfo.defaultClassicMode
        let multitask = classicMode == 0 ? (multitask ?? shouldLaunchInMultitaskMode) : false
        
        if MultitaskManager.isMultitasking() || multitask,
           let currentDataFolder {
            if await bringExistingMultitaskWindowIfNeeded(dataUUID: currentDataFolder, urlScheme: urlStr) {
                return
            }
            
        }
        
        // this is rerouted to bringing app to front, so not needed here?
//        if(MultitaskManager.isUsing(container: uiSelectedContainer!.folderName)) {
//            throw "lc.container.inUse".loc + "\n MultiTask"
//        }
        
        // if the selected container is in use (either other lc or multitask), open the host lc associated with it
        if
            let fn = uiSelectedContainer?.folderName,
            var runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: fn)
        {
            runningLC = (runningLC as NSString).deletingPathExtension
            
            var openURLComp = URLComponents()
            openURLComp.scheme = runningLC
            if let urlStr {
                openURLComp.host = "open-url"
                openURLComp.queryItems = [
                    URLQueryItem(name: "url", value: Data(urlStr.utf8).base64EncodedString())
                ]
            }
            if await UIApplication.shared.canOpenURL(openURLComp.url!) {
                await UIApplication.shared.open(openURLComp.url!)
                return
            }
        }
        
        // find a free lc to run non-multitasking shared app. If none, ask user if they want to terminate all multitasking apps
        if MultitaskManager.isMultitasking() && !multitask {
            if self.uiIsShared {
                var freeScheme: String? = nil
                LCUtils.forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                    freeScheme = scheme
                    shouldBreak = true
                }
                if let freeScheme {
                    LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                    LCUtils.appGroupUserDefault.set(self.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                    LCUtils.appGroupUserDefault.set(uiSelectedContainer?.folderName, forKey: "LCLaunchExtensionContainerName")
                    if let urlStr {
                        LCUtils.appGroupUserDefault.set(urlStr, forKey: "LCLaunchExtensionLaunchURL")
                    }
                    LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                    var launchURLComp = URLComponents()
                    launchURLComp.scheme = freeScheme
                    launchURLComp.host = "livecontainer-launch"
                    var queryItems: [URLQueryItem] = []
                    if let bundlePath = self.appInfo.relativeBundlePath {
                        queryItems.append(URLQueryItem(name: "bundle-name", value: bundlePath))
                    }
                    if let folderName = uiSelectedContainer?.folderName {
                        queryItems.append(URLQueryItem(name: "container-folder-name", value: folderName))
                    }
                    
                    launchURLComp.queryItems = queryItems
                    
                    if let url = launchURLComp.url {
                        await UIApplication.shared.open(url)
                    } else {
                        throw "Unable to build URL from launchURLComp???"
                    }
                    return
                }
            }
            
            guard let ans = await delegate?.showRunWhenMultitaskAlert(), ans else {
                return
            }
        }
        
        await MainActor.run {
            isAppRunning = true
        }
        defer {
            Task { await MainActor.run {
                isAppRunning = false
            }}
        }
        // 单 App VPN 快开（小火箭式）：核心启动与签名并行——
        // 两者无依赖（签名动插件文件、核心只碰 libXray），串
        // 行等是白白加起来的秒数。核心启动是同步阻塞的
        // CGoInvoke，放 detached 后台线程跑，不冻主线程；
        // 游客仍等核心就绪才起（免得头几秒走直连），只是
        // 不再串行等签名。签名失败时核心照常起着（等同预
        // 热），闲置后自动停；核心起失败也不拦启动（游客侧
        // fail-open 兜底，直连）。appInfo 先提成本地常量：
        // detached 闭包是 escaping，不能隐式抓 self 的属性。
        let vpnAppInfo = appInfo
        let vpnCoreTask: Task<Void, Never>? = CZFVPNManager.isEnabled(for: vpnAppInfo)
            ? Task.detached(priority: .userInitiated) { CZFVPNManager.shared.ensureRunning(for: vpnAppInfo) }
            : nil
        try await signApp(force: false)
        await vpnCoreTask?.value
        // P1（3.8.279）：探节点与开窗并行——277 是“探通再放行”，
        // 探的 0.2–0.5 秒（坏节点数秒）全堵在开窗前。改核心起来
        // 立刻开窗，探节点放后台并行跑；探通什么都不做，探不通
        // 后台切节点（切节点逻辑现成）。代价：坏节点时头 1 秒左
        // 右可能走 fail-open 直连（用户 2026-11-05 点头）。
        // 没标 VPN 的 App（vpnCoreTask 为 nil）不探。
        if vpnCoreTask != nil {
            Task.detached(priority: .userInitiated) {
                _ = await CZFVPNManager.shared.waitUntilNodeReady(for: vpnAppInfo, timeout: 5)
            }
        }

        var jitNeeded = appInfo.isJITNeeded || appInfo.is32bit
        if let forceJIT {
            jitNeeded = forceJIT
        }
#if targetEnvironment(simulator)
        jitNeeded = false
#endif
        // 跳错修复：非多任务 JIT 的启动键不在这里写，改由
        // delegate 在 JIT 确认后写（见 jitLaunch(withScript:)）；
        // 多任务 JIT 与非 JIT 路仍在这里写（客启动在即，
        // 无 pending 窗口；多任务 JIT 键时序一字不动）。
        // delegate 路 = jitNeeded 且不走多任务 JIT 分支。
        let jitDefersKeyWrite: Bool
        if #available(iOS 17.4, *) {
            jitDefersKeyWrite = jitNeeded && !multitask
        } else {
            jitDefersKeyWrite = jitNeeded
        }
        // 串行门（多任务路）：启动键是全局单键（selected/
        // selectedContainer），亚秒级连点两次多任务启动会把第
        // 一次的键顶掉、客读到第二次的键而起错 App。写键前先
        // 持门，客窗口出现（dockManager.apps 含本容器，与
        // smallWindowOpenApp 认同一信号）或启动失败/15 秒超时
        // 才释放；第二次启动绝不挂到超时（拿门最多等 60 秒，
        // 仍拿不到就无门放行、不抛错）。经典路不动——宿主启动
        // 调用后即 SIGKILL，无门可持；delegate 写键路（非多任
        // 务 JIT）也不持门，键时序一字不动。
        // 本次是否走这里写键并起多任务窗的两条路（与下面
        // launch 分支一一对应）：17.4+ 时 multitask 即是；
        // 17.4 以下时 multitask 且非 JIT 才是（multitask+JIT
        // 走 delegate 路，键不在这里写，不持门）。
        let czfMultitaskLaunchHere: Bool
        if #available(iOS 17.4, *) {
            czfMultitaskLaunchHere = multitask
        } else if #available(iOS 16.0, *) {
            czfMultitaskLaunchHere = multitask && !jitNeeded
        } else {
            czfMultitaskLaunchHere = false
        }
        var czfGateHeld = false
        var czfGateUUID: String?
        if czfMultitaskLaunchHere, let folderName = uiSelectedContainer?.folderName {
            czfGateHeld = try await CZFMultitaskLaunchGate.shared.acquire(for: folderName)
            if czfGateHeld {
                czfGateUUID = folderName
            }
        }
        // 失败释放：链路抛错会跳过下面的交接，门还在手里时由
        // 这个 defer 放掉；成功交接后 czfGateUUID 已置空，
        // defer 不再动手。defer 里不能 await，用 Task 送释放。
        defer {
            if let uuid = czfGateUUID {
                Task {
                    await CZFMultitaskLaunchGate.shared.release(for: uuid)
                }
            }
        }
        if !jitDefersKeyWrite {
            if let bundleIdOverride {
                UserDefaults.standard.set(bundleIdOverride, forKey: "selected")
            } else {
                UserDefaults.standard.set(self.appInfo.relativeBundlePath, forKey: "selected")
            }
            if let urlStr {
                UserDefaults.standard.setValue(urlStr, forKey: "launchAppUrlScheme")
            }
            UserDefaults.standard.set(uiSelectedContainer?.folderName, forKey: "selectedContainer")
        }

        // JIT 确认取消时不盖“最近启动”：delegate 的 jitLaunch 返 Bool，
        // 取消返 false；其它路（多任务/直接启动）照常盖戳。
        var czfDidLaunch = true
        if jitNeeded {
            if multitask, #available(iOS 17.4, *) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // 3.8.496（L12）：启动窗在客端初始化完成前被关掉时 pid
                    // 回调永不触发——terminate 在未运行时是空操作，不走
                    // delegate；pidCallbacks 只在 onAppInitialize 里取走
                    // 调一次，无超时、无清理。continuation 永远挂起、
                    // isAppRunning 一直 true、App 再也点不开，只能重启
                    // LiveContainer。30 秒超时兜底，只恢复一次
                    //（CZFOnceBox，czfWaitForWindowAndRelease 同款；
                    // 回调两路都在主线程、超时任务也跑主线程，take
                    // 全在 MainActor 上串行，不会双恢复）。
                    let czfPidBox = CZFOnceBox()
                    let czfPidTimeout = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        if czfPidBox.take() {
                            continuation.resume(throwing: "Guest app did not initialize in 30 seconds")
                        }
                    }
                    LCUtils.launchMultitaskGuestApp(appInfo.displayName()) { pidNumber, error in
                        if let error {
                            czfPidTimeout.cancel()
                            if czfPidBox.take() {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                        guard let pidNumber = pidNumber else {
                            czfPidTimeout.cancel()
                            if czfPidBox.take() {
                                continuation.resume(throwing: "Failed to obtain PID from LiveProcess")
                            }
                            return
                        }
                        Task {
                            if let scriptData = self.jitLaunchScriptJs, !scriptData.isEmpty {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: scriptData, appName: self.appInfo.displayName())
                            } else {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: nil, appName: self.appInfo.displayName())
                            }
                            czfPidTimeout.cancel()
                            await MainActor.run {
                                if czfPidBox.take() {
                                    continuation.resume()
                                }
                            }
                        }
                    }
                }
            } else {
                // Non-multitask JIT：启动键由 delegate 在 JIT 确认后写
                // （见 jitLaunch(withScript:)），这里只传值不写键；
                // bundleIdOverride 为空时退回自身包路径，与旧写键一致。
                if let scriptData = jitLaunchScriptJs, !scriptData.isEmpty {
                    czfDidLaunch = await delegate?.jitLaunch(withScript: scriptData, appName: self.appInfo.displayName(), classicMode: classicMode, selectedBundlePath: bundleIdOverride ?? self.appInfo.relativeBundlePath, selectedContainerFolder: uiSelectedContainer?.folderName, launchURL: urlStr) ?? false
                } else {
                    czfDidLaunch = await delegate?.jitLaunch(appName: self.appInfo.displayName(), classicMode: classicMode, selectedBundlePath: bundleIdOverride ?? self.appInfo.relativeBundlePath, selectedContainerFolder: uiSelectedContainer?.folderName, launchURL: urlStr) ?? false
                }
            }
        } else if multitask, #available(iOS 16.0, *) {
            try await LCUtils.launchMultitaskGuestApp(appInfo.displayName())
        } else {
            if #available(iOS 26.0, *), FileManager.default.fileExists(atPath: "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE") {
                let fileContents = "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE".data(using: .utf8)
                let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("preloadLibraries.txt")
                try fileContents?.write(to: fileURL)
            }
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
        }

        // 启动成功：门交接给等窗任务——客窗口出现或 15 秒超时
        // 才释放；runApp 本身不等窗返回，isAppRunning 周期不变。
        if czfGateHeld, let uuid = czfGateUUID {
            czfGateUUID = nil
            Task.detached {
                await CZFMultitaskLaunchGate.shared.czfWaitForWindowAndRelease(uuid: uuid)
            }
        }

        // Record the launch time
        // JIT 确认取消时不盖（czfDidLaunch 为 false），免得“最近启动”
        // 排一个根本没启动的 App；其它路照常盖。
        if czfDidLaunch {
            appInfo.lastLaunched = Date()
        }

        await MainActor.run {
            isAppRunning = false
        }
    }
    
    func forceResign() async throws {
        if isAppRunning {
            return
        }
        isAppRunning = true
        defer {
            Task{ await MainActor.run {
                self.isAppRunning = false
            }}

        }
        try await signApp(force: true)
    }
    
    func signApp(force: Bool = false) async throws {
        var signError : String? = nil
        var signSuccess = false
        defer {
            Task{ await MainActor.run {
                self.isSigningInProgress = false
            }}
        }
        
        await withUnsafeContinuation({ c in
            appInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error;
                signSuccess = success;
                c.resume()
            }, progressHandler: { signProgress in
                guard let signProgress else {
                    return
                }
                self.isSigningInProgress = true
                self.observer = signProgress.observe(\.fractionCompleted) { p, v in
                    DispatchQueue.main.async {
                        self.signProgress = signProgress.fractionCompleted
                    }
                }
            }, forceSign: force)
        })
        if let signError {
            if !signSuccess {
                throw signError.loc
            }
        }
        
        // 先签全局插件（原顺序在 guard 之后，没选模块文件夹的 App 会提前返回、全局插件签不上）
        try await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: force) { p in
            Task{ await MainActor.run {
                self.isSigningInProgress = true
            }}
        }

        // 单 App VPN（验证版）：开着 VPN 又没选 CZFVPN 目录的，
        // 把它加进模块文件夹列表，重定向插件才有地方部署
        if CZFVPNManager.isEnabled(for: appInfo) {
            var folders = Self.czfSplitTweakFolders(appInfo.tweakFolder)
            if !folders.contains("CZFVPN") {
                folders.append("CZFVPN")
                appInfo.tweakFolder = Self.czfJoinTweakFolders(folders)
            }
        }

        // 证书缺失时不再静默放行：没证书就签不了任何插件，
        // signTweaks 顶层 guard 会直接 return，游客照常启动、
        // 插件用旧签名加载必弹 Failed to load tweaks——
        // 2026-10-24 全量弹窗的根因就是证书丢了之后这里一直
        // 静默放行（钥匙串桥签名三版一模一样，证明机上签名
        // 根本没跑过）。有插件要签却没证书时直接报错，让用户
        // 去设置里重导证书，而不是放进游客弹看不懂的错。
        // 没插件的游客、禁注入的游客不受影响，照常启动。
        if !appInfo.dontInjectTweakLoader,
           LCSharedUtils.certificatePassword() == nil || LCUtils.certificateData() == nil {
            let fm = FileManager.default
            func folderHasTweak(_ url: URL) -> Bool {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
                for case let u as URL in e {
                    if u.pathExtension == "dylib" || u.pathExtension == "framework" { return true }
                }
                return false
            }
            var hasTweaks = folderHasTweak(LCPath.tweakPath)
            if !hasTweaks {
                for f in Self.czfSplitTweakFolders(appInfo.tweakFolder) {
                    let u = appInfo.isShared ? LCPath.lcGroupTweakPath.appendingPathComponent(f) : LCPath.tweakPath.appendingPathComponent(f)
                    if folderHasTweak(u) { hasTweaks = true; break }
                }
            }
            if hasTweaks {
                throw "证书缺失，插件无法签名：请到设置 → 证书里重新导入证书，再打开 App"
            }
        }

        // 逐个签所选的模块文件夹（多选；一个没选就直接收尾，
        // 和旧版 guard 返回等价）
        for tweakFolder in Self.czfSplitTweakFolders(appInfo.tweakFolder) {
            let tweakFolderUrl: URL
            if appInfo.isShared {
                tweakFolderUrl = LCPath.lcGroupTweakPath.appendingPathComponent(tweakFolder)
            } else {
                tweakFolderUrl = LCPath.tweakPath.appendingPathComponent(tweakFolder)
            }
            // 自愈：转共享时没搬过来的旧文件夹（以前整串当一个路径搬，
            // 多选时直接失败），重开 App 时顺手搬过去，不然共享 App
            // 永远读不到它，重新开也没用。目标已存在时不动，不覆盖。
            if appInfo.isShared {
                let privateUrl = LCPath.tweakPath.appendingPathComponent(tweakFolder)
                let fm = FileManager.default
                if !fm.fileExists(atPath: tweakFolderUrl.path),
                   fm.fileExists(atPath: privateUrl.path) {
                    try? fm.moveItem(at: privateUrl, to: tweakFolderUrl)
                }
            }
            // 单 App VPN（验证版）：签名之前按标记同步重定向插件。
            // 刚换上的新插件单独补一签（照手势插件的部署法）：批量
            // 签名带指纹缓存，新文件有被误判"已验过"跳过的先例
            // （真机出过签名无效被拒载），单独签没有缓存判断、必签。
            if tweakFolder == "CZFVPN", CZFVPNManager.syncProxyTweak(for: appInfo, tweakFolderUrl: tweakFolderUrl) {
                let proxyUrl = tweakFolderUrl.appendingPathComponent("CZFProxy.dylib")
                try? await LCUtils.signSingleTweakFile(proxyUrl)
                if !checkCodeSignature((proxyUrl.path as NSString).utf8String) {
                    // 第一签验不过就再签一次（下面的批量签名还会再兜底）
                    try? await LCUtils.signSingleTweakFile(proxyUrl)
                }
            }
            try await LCUtils.signTweaks(tweakFolderUrl: tweakFolderUrl, force: force) { p in
                Task{ await MainActor.run {
                    self.isSigningInProgress = true
                }}
            }
        }
    }

    func setLocked(newLockState: Bool) async {
        // if locked state in appinfo already match with the new state, we just the change
        if appInfo.isLocked == newLockState {
            return
        }
        
        if newLockState {
            appInfo.isLocked = true
        } else {
            // authenticate before cancelling locked state
            // 3.8.441：解锁必须每次都弹人脸识别——原来调
            // LCUtils.authenticateUser()，隐藏 App 解锁过一次后
            // 它直接短路放行，锁定的 App 点“解锁”就不弹人脸了。
            // 改走强制认证（不短路、不碰隐藏解锁态）。
            do {
                let result = try await LCUtils.authenticateUserForced()
                if !result {
                    uiIsLocked = true
                    return
                }
            } catch {
                uiIsLocked = true
                return
            }
            
            // auth pass, we need to cancel app's lock and hidden state
            appInfo.isLocked = false
            if appInfo.isHidden {
                await toggleHidden()
            }
        }
    }
    
    func toggleHidden() async {
        delegate?.closeNavigationView()
        if appInfo.isHidden {
            appInfo.isHidden = false
            uiIsHidden = false
        } else {
            appInfo.isHidden = true
            uiIsHidden = true
        }
        delegate?.changeAppVisibility(app: self)
    }
    
    func loadSupportedLanguages() throws {
        let fm = FileManager.default
        if supportedLanguages != nil {
            return
        }
        supportedLanguages = []
        let fileURLs = try fm.contentsOfDirectory(at: URL(fileURLWithPath: appInfo.bundlePath()!) , includingPropertiesForKeys: nil)
        for fileURL in fileURLs {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            if(fileType == .typeDirectory && fileURL.lastPathComponent.hasSuffix(".lproj")) {
                supportedLanguages?.append(fileURL.deletingPathExtension().lastPathComponent)
            }
        }
        
    }
    
    private func bringExistingMultitaskWindowIfNeeded(dataUUID: String, urlScheme: String?) async -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return await MainActor.run {
            // 已有窗口必须属于本条目：同包名别的条目若共用容器，
            // 按 dataUUID 找会把别人的窗口顶回来；归属对不上
            // 就不顶，交给 runApp 去拆容器、起新窗口。
            if let dockApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == dataUUID }) {
                // dock 条目存在却无法证明归属（appInfo 缺失或路径
                // 为空）时视为未知，一律不顶窗口，交给 runApp；
                // 宁可多起一个窗口，不顶错别人的。
                guard let dockPath = dockApp.appInfo?.relativeBundlePath, !dockPath.isEmpty else {
                    return false
                }
                if dockPath != appInfo.relativeBundlePath {
                    return false
                }
            }
            if let urlScheme {
                UserDefaults.standard.setValue(urlScheme, forKey: "launchAppUrlScheme")
            }
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: dataUUID)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: dataUUID)
            }
            if let urlScheme, !found  {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            }
            return found
        }
    }
    
    static func copy(fromApp: LCAppModel, toAppInfo: LCAppInfo) {
        // copy previous configration to new app
        toAppInfo.autoSaveDisabled = true
        toAppInfo.isLocked = fromApp.appInfo.isLocked
        toAppInfo.isHidden = fromApp.appInfo.isHidden
        toAppInfo.isShared = fromApp.appInfo.isShared
        
        toAppInfo.containerInfo = fromApp.appInfo.containerInfo
        toAppInfo.tweakFolder = fromApp.appInfo.tweakFolder
        toAppInfo.dataUUID = fromApp.appInfo.dataUUID
        
        toAppInfo.spoofSDKVersion = fromApp.appInfo.spoofSDKVersion
        toAppInfo.doSymlinkInbox = fromApp.appInfo.doSymlinkInbox

        toAppInfo.selectedLanguage = fromApp.appInfo.selectedLanguage

        toAppInfo.orientationLock = fromApp.appInfo.orientationLock
        toAppInfo.dontInjectTweakLoader = fromApp.appInfo.dontInjectTweakLoader
        toAppInfo.hideLiveContainer = fromApp.appInfo.hideLiveContainer
        toAppInfo.dontLoadTweakLoader = fromApp.appInfo.dontLoadTweakLoader
        toAppInfo.doUseLCBundleId = fromApp.appInfo.doUseLCBundleId
        toAppInfo.fixFilePickerNew = fromApp.appInfo.fixFilePickerNew
        toAppInfo.fixLocalNotification = fromApp.appInfo.fixLocalNotification
        toAppInfo.fixBackgroundTaskIdentifiers = fromApp.appInfo.fixBackgroundTaskIdentifiers
        
        toAppInfo.isJITNeeded = fromApp.appInfo.isJITNeeded
        toAppInfo.jitLaunchScriptJs = fromApp.appInfo.jitLaunchScriptJs
        toAppInfo.helperProcessesSupport = fromApp.appInfo.helperProcessesSupport
        
        toAppInfo.multitaskSpecified = fromApp.appInfo.multitaskSpecified
        toAppInfo.classicMode = fromApp.appInfo.classicMode
        
        toAppInfo.lastLaunched = fromApp.appInfo.lastLaunched
        
        toAppInfo.autoSaveDisabled = false
        toAppInfo.save()
    }
}

// MARK: - 多任务启动串行门（CZF，3.8.230）
// 启动键是全局单键，多任务路两次启动亚秒级连点会互相顶键、
// 客读错键起错 App。门是全局一把（不分容器——键本身就是
// 全局的）：写键前持门，客窗口出现或启动失败才放行。
// 取消：acquire 的检查与 sleep 在任务取消时抛错，门不落袋；
// 等待上限：持门等窗最多 15 秒、拿门最多 60 秒，超时即放
// 行/无门启动，第二次启动绝不无限挂起。
/// 只恢复一次的盒子（O-19）：窗口出现回调与 15 秒超时兜底
/// 都在主队列串行跑，谁先到谁拿，另一个空转；continuation
/// 只恢复一次，绝不 double-resume。
private final class CZFOnceBox {
    private var taken = false
    func take() -> Bool {
        guard !taken else { return false }
        taken = true
        return true
    }
}

actor CZFMultitaskLaunchGate {
    static let shared = CZFMultitaskLaunchGate()
    private var holder: String?
    private var waiters: [(uuid: String, continuation: CheckedContinuation<Bool, Error>)] = []
    // H-10 事件驱动等待队列：拿不到门时挂起等放门，不再 0.1 秒
    // 轮询。release/超时/取消三处都先把等待者移出队列再恢复，
    // 只恢复一次；release 时把门原子交给队首，醒来即持门。

    /// 拿门：无人持门直接拿；有人时挂起等放门或 60 秒超时；返回
    /// true = 已持门（调用方负责释放），false = 超时未拿到
    /// （无门放行，调用方不得释放）。任务取消时抛错。
    func acquire(for uuid: String) async throws -> Bool {
        try Task.checkCancellation()
        if holder == nil {
            holder = uuid
            return true
        }
        // 超时任务：60 秒后把本等待者移出队列并以 false 恢复；
        // 拿到门/取消时在 defer 里取消它。
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                await self.timeoutWaiter(uuid: uuid)
            } catch {
                // 取消/已拿到门：什么都不做
            }
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                // 闭包同步执行，还在 actor 隔离内，直接入队。
                waiters.append((uuid: uuid, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(uuid: uuid) }
        }
    }

    /// 放门：只有持有者能放，别人的释放一律忽略（超时无门
    /// 放行的调用方、已交接的等窗任务都不会误清别人的门）。
    /// 有排队的直接把门交给队首（actor 内原子交接）。
    func release(for uuid: String) {
        if holder == uuid {
            holder = nil
            if let next = waiters.first {
                waiters.removeFirst()
                holder = next.uuid
                next.continuation.resume(returning: true)
            }
        }
    }

    /// 超时：等待者还在队里就移出并以 false 恢复（已拿到门
    /// 的不在队里，什么都不做）。
    private func timeoutWaiter(uuid: String) {
        guard let index = waiters.firstIndex(where: { $0.uuid == uuid }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// 取消：等待者还在队里就移出并抛取消错（已恢复的不在
    /// 队里，什么都不做）。
    private func cancelWaiter(uuid: String) {
        guard let index = waiters.firstIndex(where: { $0.uuid == uuid }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// 等窗后放门：客窗口出现（dock 条目追加）即放；15 秒
    /// 未出现也放——门绝不为一次慢启动/失败启动一直占着。
    /// O-19：原来每 0.3 秒在主线程认一次 dockManager.apps，
    /// 最长 15 秒（50 次唤醒）。改走 czfOnWindowAppeared 回调
    /// （MultitaskDockView 已有，出现先于注册的竞态由它开头
    /// 的已存在检查兜底）；它超时不调 handler，所以另起一个
    /// 15 秒 asyncAfter 兜底，超时也放门。出现/超时谁先到谁
    /// 恢复，CZFOnceBox 保证只恢复一次。
    func czfWaitForWindowAndRelease(uuid: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = CZFOnceBox()
            // MultitaskDockManager 带 @available(iOS 16.0, *)，跨文件
            // 引用必须包 #available（v170 血泪：不包编不过）；16 以下
            // 多任务根本不存在，不注册回调，只走下面 15 秒超时放门。
            if #available(iOS 16.0, *) {
                MultitaskDockManager.shared.czfOnWindowAppeared(uuid: uuid, timeout: 15) {
                    guard box.take() else { return }
                    continuation.resume()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard box.take() else { return }
                continuation.resume()
            }
        }
        release(for: uuid)
    }
}
