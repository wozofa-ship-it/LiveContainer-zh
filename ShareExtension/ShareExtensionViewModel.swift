import Combine
import Foundation
import LocalAuthentication
import UIKit
// 3.8.370：367 的 launchResponder 用了 UIResponder/
// UIApplication，但这文件没 import UIKit，编译器三处不认，
// 367/368 的 Archive 全挂。369 只加了注释、漏了真正的
// import 语句——这次是实打实的 import UIKit 行。

@MainActor
final class ShareExtensionViewModel: ObservableObject {
    @Published var payload = SharePayload()
    @Published var visibleApps: [ShareApp] = []
    @Published var hiddenApps: [ShareApp] = []
    @Published var recommendedBundleIDs: [String] = []
    @Published var hiddenUnlocked = false
    @Published var isLaunching = false
    @Published var errorMessage: String?

    var allApps: [ShareApp] = []
    var sharedDefaults: UserDefaults?
    var privateDocURL: URL?
    var privateDocAccessing = false
    var appGroupRootURL: URL?
    weak var currentContext: NSExtensionContext?
    // 3.8.367：响应链打开的起点，由 ShareExtensionHandler 设为
    // 它自己（UIViewController）。链往上走 view → window →
    // UIApplication，拿到真 UIApplication 才能调 open。
    weak var launchResponder: UIResponder?

    init() {
        sharedDefaults = UserDefaults(suiteName: LCSharedUtils.appGroupID())
        appGroupRootURL = LCSharedUtils.appGroupPath()?.appendingPathComponent("LiveContainer")
        privateDocURL = Self.resolvePrivateDocURL(sharedDefaults: sharedDefaults)
        privateDocAccessing = privateDocURL != nil
        reloadApps()
    }

    deinit {
        if privateDocAccessing {
            privateDocURL?.stopAccessingSecurityScopedResource()
        }
    }

    func loadPayload(from context: NSExtensionContext?) {
        if let context {
            currentContext = context
        }
        Task {
            do {
                let loaded = try await SharePayload.load(from: context)
                await MainActor.run {
                    self.payload.kind = loaded
                }
                if let url = await MainActor.run(body: { self.payload.sharedURL }) {
                    await refreshRecommendation(for: url)
                } else {
                    await MainActor.run {
                        self.recommendedBundleIDs = []
                    }
                }
            } catch {
                await MainActor.run {
                    self.payload.kind = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelRequest() {
        currentContext?.cancelRequest(withError: ShareExtensionError("Cancelled"))
    }

    func unlockHiddenApps() async {
        do {
            guard try await Self.authenticateUser() else {
                return
            }
            hiddenUnlocked = true
            rebuildVisibleApps()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recommendedApps() -> [ShareApp] {
        let candidates = hiddenUnlocked ? visibleApps + hiddenApps : visibleApps
        guard !recommendedBundleIDs.isEmpty else {
            return []
        }

        var rank: [String: Int] = [:]
        for bundleID in recommendedBundleIDs {
            let normalizedID = bundleID.lowercased()
            if rank[normalizedID] == nil {
                rank[normalizedID] = rank.count
            }
        }
        return candidates
            .filter { rank[$0.bundleIdentifier.lowercased()] != nil }
            .sorted { (rank[$0.bundleIdentifier.lowercased()] ?? Int.max) < (rank[$1.bundleIdentifier.lowercased()] ?? Int.max) }
    }

    func suggestedApps() -> [ShareApp] {
        var apps = recommendedApps()
        if shouldShowInstallAction(),
           let sideStoreApp = visibleApps.first(where: { $0.isBuiltInSideStore }),
           !apps.contains(where: { $0.id == sideStoreApp.id }) {
            apps.append(sideStoreApp)
        }
        return apps
    }

    func regularApps() -> [ShareApp] {
        visibleApps
    }

    func hiddenRegularApps() -> [ShareApp] {
        hiddenApps
    }

    func shouldShowHiddenUnlockButton() -> Bool {
        !hiddenUnlocked && !hiddenApps.isEmpty && !(sharedDefaults?.bool(forKey: "LCStrictHiding") ?? false)
    }

    private func refreshRecommendation(for url: URL) async {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            recommendedBundleIDs = []
            return
        }
        let bundleIDs = await AssociatedDomainResolver.bundleIDs(for: host)
        await MainActor.run {
            self.recommendedBundleIDs = bundleIDs
        }
    }

    static func authenticateUser() async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error = error as? LAError, error.code == .passcodeNotSet {
                return true
            }
            if let error {
                throw error
            }
            return false
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "lc.utils.requireAuthentication".loc) { success, evaluationError in
                if let evaluationError = evaluationError as? LAError, evaluationError.code == .userCancel || evaluationError.code == .appCancel {
                    continuation.resume(returning: false)
                } else if let evaluationError {
                    continuation.resume(throwing: evaluationError)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }
    
    func reloadApps() {
        var apps: [ShareApp] = []
        if let privateDocURL {
            apps.append(contentsOf: loadApps(root: privateDocURL, isShared: false))
        }
        if let appGroupRootURL {
            apps.append(contentsOf: loadApps(root: appGroupRootURL, isShared: true))
        }
        if let builtInSideStore = loadBuiltInSideStoreApp() {
            apps.append(builtInSideStore)
        }

        allApps = apps
        rebuildVisibleApps()
    }

    func rebuildVisibleApps() {
        let sorted = sortApps(allApps)
        visibleApps = sorted.filter { !$0.isHidden }
        hiddenApps = sorted.filter { $0.isHidden }
    }

    private func sortApps(_ apps: [ShareApp]) -> [ShareApp] {
        let regularApps = apps.filter { !$0.isBuiltInSideStore }
        let sideStoreApps = apps.filter { $0.isBuiltInSideStore }
        let sortType = sharedDefaults?.string(forKey: "LCAppSortType") ?? "default"
        let sorted: [ShareApp]

        switch sortType {
        case "alphabetical":
            sorted = regularApps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case "reverse_alphabetical":
            sorted = regularApps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending }
        case "last_launched":
            let dated = regularApps.compactMap { app -> (ShareApp, Date)? in
                guard let lastLaunched = app.lastLaunched else {
                    return nil
                }
                return (app, lastLaunched)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
            let undated = regularApps.filter { $0.lastLaunched == nil }
            sorted = dated + undated
        case "installationDate":
            let dated = regularApps.compactMap { app -> (ShareApp, Date)? in
                guard let installationDate = app.installationDate else {
                    return nil
                }
                return (app, installationDate)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
            let undated = regularApps.filter { $0.installationDate == nil }
            sorted = dated + undated
        case "custom":
            sorted = sortByCustomOrder(regularApps)
        default:
            sorted = regularApps
        }

        return sorted + sideStoreApps
    }

    private func sortByCustomOrder(_ apps: [ShareApp]) -> [ShareApp] {
        guard let customSortOrder = sharedDefaults?.array(forKey: "LCCustomSortOrder") as? [String],
              !customSortOrder.isEmpty else {
            return apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }

        var sortedApps: [ShareApp] = []
        var remainingApps = apps
        for uniqueID in customSortOrder {
            if let index = remainingApps.firstIndex(where: { uniqueID == uniqueIdentifier(for: $0) }) {
                sortedApps.append(remainingApps.remove(at: index))
            }
        }

        remainingApps.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        sortedApps.append(contentsOf: remainingApps)
        return sortedApps
    }

    private func uniqueIdentifier(for app: ShareApp) -> String {
        "\(app.bundleIdentifier):\(app.relativeBundlePath)"
    }

    private func loadApps(root: URL, isShared: Bool) -> [ShareApp] {
        let applicationsURL = root.appendingPathComponent("Applications")
        guard let appDirs = try? FileManager.default.contentsOfDirectory(at: applicationsURL, includingPropertiesForKeys: nil) else {
            return []
        }

        return appDirs.compactMap { appURL in
            guard appURL.pathExtension == "app" else {
                return nil
            }
            return loadApp(appURL: appURL, root: root, isShared: isShared)
        }
    }

    private func loadApp(appURL: URL, root: URL, isShared: Bool) -> ShareApp? {
        guard
            let infoPlist = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any]
        else {
            return nil
        }
        let appInfo = (NSDictionary(contentsOf: appURL.appendingPathComponent("LCAppInfo.plist")) as? [String: Any]) ?? [:]
        let relativeBundlePath = appURL.lastPathComponent
        let displayName = (infoPlist["CFBundleDisplayName"] as? String)
            ?? (infoPlist["CFBundleName"] as? String)
            ?? (infoPlist["CFBundleExecutable"] as? String)
            ?? relativeBundlePath
        let bundleIdentifier: String
        if appInfo["doUseLCBundleId"] as? Bool == true, let original = appInfo["LCOrignalBundleIdentifier"] as? String {
            bundleIdentifier = original
        } else {
            bundleIdentifier = (infoPlist["CFBundleIdentifier"] as? String) ?? "Unknown"
        }

        let containers = loadContainers(appInfo: appInfo, root: root, isShared: isShared)
        let usableContainers = containers.isEmpty ? fallbackContainers(appInfo: appInfo, root: root, isShared: isShared) : containers
        guard !usableContainers.isEmpty else {
            return nil
        }

        return ShareApp(
            id: "\(isShared ? "shared" : "private")|\(relativeBundlePath)",
            relativeBundlePath: relativeBundlePath,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            isShared: isShared,
            isHidden: appInfo["isHidden"] as? Bool ?? false,
            isLocked: appInfo["isLocked"] as? Bool ?? false,
            isJITNeeded: appInfo["isJITNeeded"] as? Bool ?? false,
            containers: usableContainers,
            iconURL: iconURL(for: appURL),
            lastLaunched: appInfo["lastLaunched"] as? Date,
            installationDate: appInfo["installationDate"] as? Date,
            isBuiltInSideStore: false
        )
    }

    private func loadBuiltInSideStoreApp() -> ShareApp? {
        let sideStoreFrameworkURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks/SideStoreApp.framework")
        guard FileManager.default.fileExists(atPath: sideStoreFrameworkURL.path) else {
            return nil
        }

        let container = ShareContainer(
            id: "builtinSideStore",
            folderName: "builtinSideStore",
            name: "SideStore",
            isShared: false,
        )

        return ShareApp(
            id: "builtinSideStore",
            relativeBundlePath: "builtinSideStore",
            displayName: "SideStore",
            bundleIdentifier: "builtinSideStore",
            isShared: false,
            isHidden: false,
            isLocked: false,
            isJITNeeded: false,
            containers: [container],
            iconURL: builtInSideStoreIconURL(),
            lastLaunched: nil,
            installationDate: nil,
            isBuiltInSideStore: true
        )
    }

    private func builtInSideStoreIconURL() -> URL? {
        guard let privateDocURL else {
            return nil
        }
        let iconCacheURL = privateDocURL
            .appendingPathComponent("SideStore/Library/Caches", isDirectory: true)
            .appendingPathComponent("BuiltInSideStoreIconCache", isDirectory: true)
        return preferredIconURL(in: iconCacheURL)
    }

    private func iconURL(for appURL: URL) -> URL? {
        preferredIconURL(in: appURL)
    }

    private func preferredIconURL(in directory: URL) -> URL? {
        let lightIconURL = directory.appendingPathComponent("LCAppIconLight.png")
        let darkIconURL = directory.appendingPathComponent("LCAppIconDark.png")

        let preferredIconURL: URL
        let fallbackIconURL: URL
        if #available(iOS 18.0, *), sharedDefaults?.bool(forKey: "darkModeIcon") == true {
            preferredIconURL = darkIconURL
            fallbackIconURL = lightIconURL
        } else {
            preferredIconURL = lightIconURL
            fallbackIconURL = darkIconURL
        }

        if FileManager.default.fileExists(atPath: preferredIconURL.path) {
            return preferredIconURL
        }
        if FileManager.default.fileExists(atPath: fallbackIconURL.path) {
            return fallbackIconURL
        }
        return nil
    }

    private func loadContainers(appInfo: [String: Any], root: URL, isShared: Bool) -> [ShareContainer] {
        guard let containerInfo = appInfo["LCContainers"] as? [[String: Any]] else {
            return []
        }
        return containerInfo.compactMap { dict in
            guard let folderName = dict["folderName"] as? String else {
                return nil
            }
            let name = (dict["name"] as? String) ?? folderName
            return ShareContainer(
                id: "\(isShared ? "shared" : "private")|\(folderName)",
                folderName: folderName,
                name: name,
                isShared: isShared,
            )
        }
    }

    private func fallbackContainers(appInfo: [String: Any], root: URL, isShared: Bool) -> [ShareContainer] {
        guard let folderName = appInfo["LCDataUUID"] as? String else {
            return []
        }
        return [
            ShareContainer(
                id: "\(isShared ? "shared" : "private")|\(folderName)",
                folderName: folderName,
                name: folderName,
                isShared: isShared,
            )
        ]
    }
    
    func launch(app: ShareApp, context: NSExtensionContext?) async {
        guard let container = app.primaryContainer else {
            errorMessage = "lc.shareExtension.error.noContainer".loc
            return
        }
        await launch(app: app, container: container, context: context)
    }

    func launch(app: ShareApp, container: ShareContainer, context: NSExtensionContext?) async {
        if isLaunching {
            return
        }
        isLaunching = true
        defer { isLaunching = false }

        do {
            if (app.isLocked || app.isHidden) && !hiddenUnlocked {
                guard try await Self.authenticateUser() else {
                    return
                }
            }

            if app.isBuiltInSideStore {
                try await launchBuiltInSideStore(context: context)
                return
            }

            let item = ShareLaunchItem(app: app, container: container)
            let launchURLString = try preparePayloadForLaunch()
            guard let launchURL = buildLaunchURL(for: item, launchURLString: launchURLString) else {
                throw ShareExtensionError("Unable to build launch URL.")
            }

            // 3.8.363：iOS 26 下 LSApplicationWorkspace 从扩展里调
            // 会被拦，旧代码还永远返回 true、失败也静默关面板。
            // 先走系统 sanctioned 的 NSExtensionContext.openURL，
            // 失败再回落旧 Launcher；两路都失败就留面板报错。
            let ctx = context ?? currentContext
            if await openLaunchURL(launchURL, context: ctx) {
                ctx?.completeRequest(returningItems: nil, completionHandler: nil)
            } else {
                errorMessage = "lc.shareExtension.error.openFailed".loc
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 打开 LiveContainer（3.8.367）：三路按序试，返回是否真正打开。
    /// 第一路响应链：iOS 26 下 LSApplicationWorkspace 从扩展调被拦、
    /// NSExtensionContext.open 又不在 Share 扩展的支持列表里，两路
    /// 都打不开。Apollo-Reborn PR #307 实证：走响应链拿到的
    /// UIApplication.openURL:options:completionHandler: 在 iOS 26.5
    /// 真机上能打开。链从 launchResponder（宿主视图控制器）往上走
    /// view → window → UIApplication，5 秒超时。
    /// 第二路 context.open，第三路旧 Launcher（LSApplicationWorkspace）。
    /// 三路都失败返回 false，调用方留面板报错。
    private func openLaunchURL(_ url: URL, context: NSExtensionContext?) async -> Bool {
        if await openViaResponderChain(url) { return true }
        if let context {
            // 3.8.366：第二路加 3 秒超时竞速。context.open 的回调
            // 在 Share 扩展上可能永远不回（系统不支持的扩展点），
            // 原先 withCheckedContinuation 会无限挂起、面板卡死；
            // 3 秒未回调按 false 走回落（第三路已有 5 秒信号量超时）。
            // 回调与超时谁先到谁 resume，锁保证只 resume 一次
            //（重复 resume 会 trap）。
            let opened: Bool = await withCheckedContinuation { cont in
                // 3.8.363 修正：Swift 里叫 open，不是 openURL
                //（openURL 是 ObjC 名，Swift 下没这个成员，363
                // 构建就是挂在这里）。Share 扩展不在 Apple 的
                // open 支持列表里（只列 Today/iMessage），可能
                // 直接返回 false，失败就走下面的回落。
                let lock = NSLock()
                var done = false
                func resumeOnce(_ value: Bool) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return }
                    done = true
                    cont.resume(returning: value)
                }
                context.open(url) { success in resumeOnce(success) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { resumeOnce(false) }
            }
            if opened { return true }
        }
        return await Task.detached {
            LCShareExtensionLauncher.openURL(fromShareExtension: url)
        }.value
    }

    /// 响应链打开：从 launchResponder 往上走 nextResponder，碰到
    /// UIApplication 就调它的 open（带 5 秒超时竞速）。链断了或
    /// open 回 false 就返回 false，让调用方走下一路。
    private func openViaResponderChain(_ url: URL) async -> Bool {
        var current: UIResponder? = launchResponder
        while let responder = current {
            if let app = responder as? UIApplication {
                let opened: Bool = await withCheckedContinuation { cont in
                    let lock = NSLock()
                    var done = false
                    func resumeOnce(_ value: Bool) {
                        lock.lock()
                        defer { lock.unlock() }
                        guard !done else { return }
                        done = true
                        cont.resume(returning: value)
                    }
                    app.open(url, options: [:]) { success in resumeOnce(success) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { resumeOnce(false) }
                }
                return opened
            }
            current = responder.next
        }
        return false
    }

    func shouldShowInstallAction() -> Bool {
        guard case .file(let fileURL) = payload.kind else {
            return false
        }
        let ext = fileURL.pathExtension.lowercased()
        return ext == "ipa" || ext == "tipa"
    }

    func installSharedFileInLiveContainer(context: NSExtensionContext?) async {
        if isLaunching {
            return
        }
        guard case .file(let fileURL) = payload.kind else {
            return
        }
        isLaunching = true
        defer { isLaunching = false }

        do {
            try storeBookmark(for: fileURL)
            guard var components = URLComponents(string: "livecontainer://install") else {
                throw ShareExtensionError("Unable to build install URL.")
            }
            components.queryItems = [
                URLQueryItem(name: "url", value: fileURL.absoluteString)
            ]
            guard let installURL = components.url else {
                throw ShareExtensionError("Unable to build install URL.")
            }

            let ctx = context ?? currentContext
            if await openLaunchURL(installURL, context: ctx) {
                ctx?.completeRequest(returningItems: nil, completionHandler: nil)
            } else {
                errorMessage = "lc.shareExtension.error.openFailed".loc
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preparePayloadForLaunch() throws -> String? {
        switch payload.kind {
        case .url(let url):
            return url.absoluteString
        case .file(let fileURL):
            try storeBookmark(for: fileURL)
            return fileURL.absoluteString
        case .empty:
            return nil
        case .loading:
            throw ShareExtensionError("The shared item is still loading.")
        case .failed(let message):
            throw ShareExtensionError(message)
        }
    }

    private func launchBuiltInSideStore(context: NSExtensionContext?) async throws {
        let launchURLString = try preparePayloadForLaunch()

        sharedDefaults?.set("livecontainer", forKey: "LCLaunchExtensionScheme")
        sharedDefaults?.set("builtinSideStore", forKey: "LCLaunchExtensionBundleID")
        if let launchURLString {
            sharedDefaults?.set(launchURLString, forKey: "LCLaunchExtensionLaunchURL")
        }
        sharedDefaults?.set(Date(), forKey: "LCLaunchExtensionLaunchDate")

        guard var components = URLComponents(string: "livecontainer://livecontainer-launch") else {
            throw ShareExtensionError("Unable to build SideStore launch URL.")
        }
        var queryItems = [
            URLQueryItem(name: "bundle-name", value: "builtinSideStore")
        ]
        if let launchURLString {
            queryItems.append(URLQueryItem(name: "open-url", value: Data(launchURLString.utf8).base64EncodedString()))
        }
        components.queryItems = queryItems
        guard let launchURL = components.url else {
            throw ShareExtensionError("Unable to build SideStore launch URL.")
        }

        let ctx = context ?? currentContext
        if await openLaunchURL(launchURL, context: ctx) {
            ctx?.completeRequest(returningItems: nil, completionHandler: nil)
        } else {
            errorMessage = "lc.shareExtension.error.openFailed".loc
        }
    }

    private func storeBookmark(for fileURL: URL) throws {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let bookmark = try fileURL.bookmarkData(
            options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        sharedDefaults?.set(bookmark, forKey: "LCLaunchExtensionFileBookmark")
    }

    private func buildLaunchURL(for item: ShareLaunchItem, launchURLString: String?) -> URL? {
        var schemeToLaunch = "livecontainer"
        var newLaunch = false

        if var runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: item.container.folderName) {
            if runningLC.hasSuffix("liveprocess") {
                runningLC = (runningLC as NSString).deletingPathExtension
            }
            schemeToLaunch = runningLC
        } else {
            newLaunch = true
            schemeToLaunch = item.app.isShared ? (firstFreeInstalledLC() ?? "livecontainer") : "livecontainer"
        }

        if newLaunch && !item.app.isHidden && !item.app.isLocked && !item.app.isJITNeeded {
            sharedDefaults?.set(schemeToLaunch, forKey: "LCLaunchExtensionScheme")
            sharedDefaults?.set(item.app.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
            sharedDefaults?.set(item.container.folderName, forKey: "LCLaunchExtensionContainerName")
            if let launchURLString {
                sharedDefaults?.set(launchURLString, forKey: "LCLaunchExtensionLaunchURL")
            }
            sharedDefaults?.set(Date(), forKey: "LCLaunchExtensionLaunchDate")
        }

        var components = URLComponents()
        components.scheme = schemeToLaunch
        components.host = "livecontainer-launch"
        var queryItems = [
            URLQueryItem(name: "bundle-name", value: item.app.relativeBundlePath),
            URLQueryItem(name: "container-folder-name", value: item.container.folderName)
        ]
        if let launchURLString {
            queryItems.append(URLQueryItem(name: "open-url", value: Data(launchURLString.utf8).base64EncodedString()))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func firstFreeInstalledLC() -> String? {
        for scheme in LCSharedUtils.lcUrlSchemes() {
            guard
                let url = URL(string: "\(scheme)://"),
                LCShareExtensionLauncher.canOpenURL(fromShareExtension: url)
            else {
                continue
            }
            if LCSharedUtils.isLCScheme(inUse: scheme) {
                continue
            }
            return scheme
        }
        return nil
    }
    
    static func resolvePrivateDocURL(sharedDefaults: UserDefaults?) -> URL? {
        guard let bookmarkData = sharedDefaults?.data(forKey: "LCLaunchExtensionPrivateDocBookmark") else {
            return nil
        }
        guard let url = resolveBookmarkURL(bookmarkData) else {
            sharedDefaults?.set(nil, forKey: "LCLaunchExtensionPrivateDocBookmark")
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private static func resolveBookmarkURL(_ bookmarkData: Data) -> URL? {
        do {
            var isStale = false
            return try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        } catch {
            return nil
        }
    }
}
