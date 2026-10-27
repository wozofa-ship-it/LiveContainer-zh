import Foundation

protocol LCAppModelDelegate {
    func closeNavigationView()
    func changeAppVisibility(app : LCAppModel)
    func jitLaunch(appName: String, classicMode: UInt) async
    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async
    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async
    func showRunWhenMultitaskAlert() async -> Bool?
}

class LCAppModel: ObservableObject, Hashable {
    
    @Published var appInfo : LCAppInfo
    
    @Published var isAppRunning = false
    @Published var isSigningInProgress = false
    @Published var signProgress = 0.0
    private var observer : NSKeyValueObservation?
    
    @Published var uiIsJITNeeded : Bool {
        didSet {
            appInfo.isJITNeeded = uiIsJITNeeded
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
        let newName = NSUUID().uuidString
        let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
        newContainer.isolateAppGroup = true
        newContainer.spoofIdentifierForVendor = true
        let group = czfFreeKeychainGroup(excluding: newContainer)
        uiContainers.append(newContainer)
        uiSelectedContainer = newContainer
        appInfo.containers = uiContainers
        newContainer.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier, keychainGroupId: group)
        appInfo.dataUUID = newName
        uiDefaultDataFolder = newName
    }
    private func czfIsolateMultiOpenContainersIfNeeded() {
        guard !czfOtherSameBundleApps().isEmpty else { return }
        let markerKey = "CZFMultiOpenIsolated-\(bundleIdentifier)-\(appInfo.relativeBundlePath ?? "")"
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
            if !container.isolateAppGroup || !container.spoofIdentifierForVendor || container.keychainGroupId != newGroup {
                container.isolateAppGroup = true
                container.spoofIdentifierForVendor = true
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
        if isAppRunning {
            return
        }

        if uiContainers.isEmpty {
            let newName = NSUUID().uuidString
            let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
            let isMultiOpen = !czfOtherSameBundleApps().isEmpty
            let group: Int
            if isMultiOpen {
                newContainer.isolateAppGroup = true
                newContainer.spoofIdentifierForVendor = true
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
            appInfo.dataUUID = newName
            uiDefaultDataFolder = newName
            if isMultiOpen {
                UserDefaults.standard.set(true, forKey: "CZFMultiOpenIsolated-\(bundleIdentifier)-\(appInfo.relativeBundlePath ?? "")")
            }
        }
        czfSplitSharedContainerIfNeeded()
        czfIsolateMultiOpenContainersIfNeeded()
        if let containerFolderName {
            uiSelectedContainer = uiContainers.first { $0.folderName == containerFolderName } ?? uiSelectedContainer
        }
        // 显式指定容器后也要再拆一次：指定那个若是共享容器，
        // 不拆的话下面按容器找窗口仍会把别人的窗口顶回来。
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

        if let bundleIdOverride {
            UserDefaults.standard.set(bundleIdOverride, forKey: "selected")
        } else {
            UserDefaults.standard.set(self.appInfo.relativeBundlePath, forKey: "selected")
        }
        if let urlStr {
            UserDefaults.standard.setValue(urlStr, forKey: "launchAppUrlScheme")
        }
        UserDefaults.standard.set(uiSelectedContainer?.folderName, forKey: "selectedContainer")
        
        var jitNeeded = appInfo.isJITNeeded || appInfo.is32bit
        if let forceJIT {
            jitNeeded = forceJIT
        }
#if targetEnvironment(simulator)
        jitNeeded = false
#endif
        if jitNeeded {
            if multitask, #available(iOS 17.4, *) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    LCUtils.launchMultitaskGuestApp(appInfo.displayName()) { pidNumber, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let pidNumber = pidNumber else {
                            continuation.resume(throwing: "Failed to obtain PID from LiveProcess")
                            return
                        }
                        Task {
                            if let scriptData = self.jitLaunchScriptJs, !scriptData.isEmpty {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: scriptData, appName: self.appInfo.displayName())
                            } else {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: nil, appName: self.appInfo.displayName())
                            }
                            continuation.resume()
                        }
                    }
                }
            } else {
                // Non-multitask JIT flow remains unchanged
                if let scriptData = jitLaunchScriptJs, !scriptData.isEmpty {
                    await delegate?.jitLaunch(withScript: scriptData, appName: self.appInfo.displayName(), classicMode: classicMode)
                } else {
                    await delegate?.jitLaunch(appName: self.appInfo.displayName(), classicMode: classicMode)
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
        
        // Record the launch time
        appInfo.lastLaunched = Date()

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
            do {
                let result = try await LCUtils.authenticateUser()
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
            if let dockApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == dataUUID }),
               let dockPath = dockApp.appInfo?.relativeBundlePath,
               !dockPath.isEmpty,
               dockPath != appInfo.relativeBundlePath {
                return false
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
}
