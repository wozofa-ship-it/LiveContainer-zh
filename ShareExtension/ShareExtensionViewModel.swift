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
    // 3.8.404：Share 不再打开主 App（响应链 / context.open /
    // LSApplicationWorkspace 三路全灭），改走 App Group 收件箱。
    // launchResponder / responderChainOnly 只留给 ActionExtensionHandler
    // 设——Action 与 Share 共用本文件（Action 的 Sources 显式编了
    // 本文件），删了属性会断 Action 编译；Share 侧不再使用。
    weak var launchResponder: UIResponder?
    var responderChainOnly = false
    // 3.8.404：收件箱提示。写进收件箱成功后置文案，面板顶部横幅显示，
    // 2 秒后自动 completeRequest 关面板。
    @Published var inboxNotice: String?
    private var inboxCompletionSent = false
    // 3.8.376 分路日志：本次打开尝试的诊断行（每路一到两行）。
    // 失败时拼进 errorMessage 让用户截图；同时写 NSLog 和
    // App Group 里的 CZFShareExtensionLog.txt（带时间戳）。
    private var shareDiagLines: [String] = []

    private func czfShareLog(_ line: String) {
        shareDiagLines.append(line)
        NSLog("[CZFShare] %@", line)
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LCSharedUtils.appGroupID()) {
            let url = dir.appendingPathComponent("CZFShareExtensionLog.txt")
            let prev = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let stamped = "\(Date()): \(line)\n"
            try? (prev + stamped).write(to: url, atomically: true, encoding: .utf8)
        }
    }

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
        if isLaunching || inboxNotice != nil {
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
                try enqueueBuiltInSideStore(context: context)
                return
            }

            // 3.8.404：不再尝试打开主 App，只把启动请求写进 App Group
            // 收件箱，面板提示后关面板；主 App 前台认领后启动客 App。
            let entry = try inboxEntryForLaunch(app: app, container: container)
            try writeInboxEntry(entry)
            finishWithInboxNotice("已收进 LiveContainer，打开 App 启动", context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shouldShowInstallAction() -> Bool {
        guard case .file(let fileURL) = payload.kind else {
            return false
        }
        let ext = fileURL.pathExtension.lowercased()
        return ext == "ipa" || ext == "tipa"
    }

    func installSharedFileInLiveContainer(context: NSExtensionContext?) async {
        if isLaunching || inboxNotice != nil {
            return
        }
        guard case .file(let fileURL) = payload.kind else {
            return
        }
        isLaunching = true
        defer { isLaunching = false }

        do {
            // 3.8.404：只把文件 bookmark 写进 App Group 收件箱，
            // 不再拼 livecontainer://install 链接、不再尝试打开主 App。
            let bookmark = try storeBookmark(for: fileURL)
            let entry = CZFShareInboxEntry(
                kind: .file,
                date: Self.czfInboxDateString(),
                fileName: fileURL.lastPathComponent,
                fileExtension: fileURL.pathExtension.lowercased(),
                fileURLString: fileURL.absoluteString,
                bookmarkBase64: bookmark.base64EncodedString()
            )
            try writeInboxEntry(entry)
            finishWithInboxNotice("已收进 LiveContainer，打开 App 安装", context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 收件箱载荷（3.8.404）：URL 分享只取链接字符串写进收件箱；
    /// 文件分享沿用 storeBookmark 取 security-scoped bookmark。
    private func payloadPartsForInbox() throws -> (launchURLString: String?, bookmark: Data?, fileURL: URL?) {
        switch payload.kind {
        case .url(let url):
            return (url.absoluteString, nil, nil)
        case .file(let fileURL):
            return (fileURL.absoluteString, try storeBookmark(for: fileURL), fileURL)
        case .empty:
            return (nil, nil, nil)
        case .loading:
            throw ShareExtensionError("The shared item is still loading.")
        case .failed(let message):
            throw ShareExtensionError(message)
        }
    }

    private func inboxEntryForLaunch(app: ShareApp, container: ShareContainer) throws -> CZFShareInboxEntry {
        let parts = try payloadPartsForInbox()
        return CZFShareInboxEntry(
            kind: .launch,
            date: Self.czfInboxDateString(),
            fileName: parts.fileURL?.lastPathComponent,
            fileExtension: parts.fileURL?.pathExtension.lowercased(),
            fileURLString: parts.fileURL?.absoluteString,
            bookmarkBase64: parts.bookmark?.base64EncodedString(),
            bundleName: app.relativeBundlePath,
            containerFolderName: container.folderName,
            launchURL: parts.launchURLString
        )
    }

    /// 内置 SideStore 收件箱（3.8.404）：只写收件箱，不再写
    /// LCLaunchExtension* 键、不再拼 livecontainer://livecontainer-launch
    /// 链接、不再尝试打开主 App。
    private func enqueueBuiltInSideStore(context: NSExtensionContext?) throws {
        let parts = try payloadPartsForInbox()
        let entry = CZFShareInboxEntry(
            kind: .sidestore,
            date: Self.czfInboxDateString(),
            fileName: parts.fileURL?.lastPathComponent,
            fileExtension: parts.fileURL?.pathExtension.lowercased(),
            fileURLString: parts.fileURL?.absoluteString,
            bookmarkBase64: parts.bookmark?.base64EncodedString(),
            launchURL: parts.launchURLString
        )
        try writeInboxEntry(entry)
        finishWithInboxNotice("已收进 LiveContainer，打开 App 安装", context: context)
    }

    /// 写收件箱（3.8.404）：一文件一条，`<AppGroup>/LiveContainer/ShareInbox/<UUID>.json`，
    /// 主 App 前台认领后删除。沿用 LCSharedUtils.appGroupPath()，
    /// 与 czfShareLog 的 CZFShareExtensionLog.txt 同一个 group。
    private func writeInboxEntry(_ entry: CZFShareInboxEntry) throws {
        guard let inboxURL = inboxDirectoryURL else {
            throw ShareExtensionError("Unable to locate App Group.")
        }
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        let fileURL = inboxURL.appendingPathComponent(UUID().uuidString + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entry)
        try data.write(to: fileURL, options: .atomic)
        czfShareLog("inbox: wrote \(entry.kind.rawValue) -> \(fileURL.lastPathComponent)")
    }

    private var inboxDirectoryURL: URL? {
        appGroupRootURL?.appendingPathComponent("ShareInbox", isDirectory: true)
    }

    private static func czfInboxDateString() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// 面板提示后关面板（3.8.404）：先置 inboxNotice 让面板顶部横幅
    /// 显示文案，2 秒后 completeRequest。inboxCompletionSent 防重复关。
    private func finishWithInboxNotice(_ notice: String, context: NSExtensionContext?) {
        inboxNotice = notice
        czfShareLog("inbox notice: \(notice)")
        let ctx = context ?? currentContext
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.completeInboxRequest(context: ctx)
        }
    }

    private func completeInboxRequest(context: NSExtensionContext?) {
        guard !inboxCompletionSent else { return }
        inboxCompletionSent = true
        (context ?? currentContext)?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// 沿用旧 storeBookmark：取 security-scoped bookmark（1 << 11，
    /// SecurityScopeAllowOnlyReadAccess）。3.8.404 起不再写
    /// LCLaunchExtensionFileBookmark 键，bookmark 只进收件箱文件；
    /// 主 App 用旧解析法（1 << 10，见 LCAppListView installFromUrl）认领。
    private func storeBookmark(for fileURL: URL) throws -> Data {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        return try fileURL.bookmarkData(
            options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
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
