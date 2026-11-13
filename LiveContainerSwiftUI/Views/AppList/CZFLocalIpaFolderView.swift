// 本地 IPA 文件夹（3.8.423，用户 21:49 令）：+ 号旁边加一个
// 文件夹按钮，选一个本地文件夹，读出里面的 IPA，显示名字
// 和图标，点一下就安装。文件夹用 security-scoped bookmark
// 记住，下次点按钮直接打开，不用重新选。
import SwiftUI
import CryptoKit

// 本地 IPA 文件夹的持久化（3.8.454）：App 页与源页共用——
// 文件夹从 App 页移到源页（用户 20:34 令“把文件夹移到源
// 这里”+“一边源一边文件夹可以选择显示”），保存/恢复逻辑
// 只写一份，两处都调它。书签创建值（1<<11）、解析值
// （1<<10）、建前先 startAccessing、建完当场解验才存，与
// 443/447 的教训一致，别改。
enum CZFLocalIpaFolderStore {
    static let pathKey = "CZFLocalIpaFolderPath"
    static let bookmarkKey = "CZFLocalIpaFolderBookmark"

    @discardableResult
    static func save(_ url: URL) -> Bool {
        // 创建侧 withSecurityScope = 1 << 11（不是 1 << 10，
        // 那是 suitableForBookmarkFile）。
        let czfWithSecurityScope: UInt = 1 << 11
        // 路径每次都存一份（书签丢了/解不出来时按路径回落）。
        UserDefaults.standard.set(url.path, forKey: pathKey)
        // 3.8.447 文件夹真因（440 用户实测“还是一样”）：
        // 建 security-scoped 书签前必须先 startAccessing，
        // 否则 bookmarkData(withSecurityScope:) 校验不到访问
        // 权限、静默失败，代码回落到无 scope 书签——存下来
        // 也打不开（439 的 1<<10 错值 + 440 的缺 startAccessing
        // 都是同一结果：重开要重选）。先 startAccessing 再建，
        // 建完当场解出来验 startAccessing 能过，才算真有 scope、
        // 才存；验不过就不存，别拿无 scope 书签冒充。
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: URL.BookmarkCreationOptions(rawValue: czfWithSecurityScope), includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: URL.BookmarkResolutionOptions(rawValue: 1 << 10), relativeTo: nil, bookmarkDataIsStale: &isStale),
              resolved.startAccessingSecurityScopedResource() else {
            return false
        }
        resolved.stopAccessingSecurityScopedResource()
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return true
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            // 没书签时试路径回落（保存时两种书签都失败才走这里）。
            if let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return nil
        }
        var isStale = false
        let czfWithSecurityScope: UInt = 1 << 10
        // 先按 security scope 解析，不行再按普通方式解析（与
        // 保存的回落对应：存的是哪种，这里就按哪种解）。
        if let url = try? URL(resolvingBookmarkData: data, options: URL.BookmarkResolutionOptions(rawValue: czfWithSecurityScope), relativeTo: nil, bookmarkDataIsStale: &isStale) {
            if isStale {
                save(url)
            }
            return url
        }
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            if isStale {
                save(url)
            }
            return url
        }
        // 书签彻底解不出来，试路径回落。
        if let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // S-11：清除已选文件夹——书签与路径两个键都删掉，
    // 下次出现时 restore() 返回 nil，内嵌区回到“选择文件夹”。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
    }
}

struct CZFLocalIpaItem: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    var displayName: String
    var version: String?
    var sizeText: String
    var icon: UIImage?
    var detailLoaded = false
    // 3.8.444：包名（CFBundleIdentifier），供格子打“已安装”
    // 绿勾——读 Info.plist 得来，读不到时不打勾。
    var bundleIdentifier: String?
}

@MainActor
final class CZFLocalIpaFolderModel: ObservableObject {
    @Published var items: [CZFLocalIpaItem] = []
    @Published var scanning = true
    @Published var errorText: String?

    let folderURL: URL
    private var didStartAccessing = false
    // O-30 文件夹懒加载：详情解包任务——单任务按想要详情的
    // 项 3 个一组并行解包；弹窗关闭时 cancelDetailTasks() 取消它。
    private var detailTask: Task<Void, Never>?
    // O-30：想要详情的项 id 队列（格子滚到眼前时 onAppear
    // 推进来），按推进顺序解包；不在队里的不解，不浪费 CPU。
    private var wantedDetailIDs: [UUID] = []
    // 弹窗已关/已取消刷新时为真：在后台解包跑完回主线程前
    // 再拦一道，拦住已失效的旧解包刷进新列表。
    private var detailsCancelled = false

    // 上次扫过的文件夹（O-5 扫前短路用）：切 Tab 重建视图时
    // onAppear 又调 scan()，文件夹没变且已有列表就直接返回，
    // 不重扫；文件夹换了（模型随 .id(url) 重建）或上次扫失败
    // 时这里是 nil，照常扫。
    private var lastScannedFolderURL: URL?

    init(folderURL: URL) {
        self.folderURL = folderURL
    }

    deinit {
        if didStartAccessing {
            folderURL.stopAccessingSecurityScopedResource()
        }
    }

    // 弹窗关闭时取消未完成的解包（安装审计 #5 / App #15）：
    // 组内未开始的解包不再启动；在途的解包跑完后被
    // detailsCancelled 拦住，不再刷进列表。O-30：想要详情的
    // 队列也清掉，下次出现格子 onAppear 重新推进。
    func cancelDetailTasks() {
        detailsCancelled = true
        wantedDetailIDs.removeAll()
        detailTask?.cancel()
        detailTask = nil
    }

    func scan() {
        // O-5 扫前短路（模型上移与扫前短路二选一，选这个）：
        // 文件夹未变且已有列表，直接返回，不重扫。O-30：切走
        // 时 onDisappear 取消过详情任务，没读完的详情不用续上
        // 全量解包——格子再出现时 onAppear 按需推进，没读完
        // 的行自己会补上。这里必须把 detailsCancelled 清掉，
        // 不然 onAppear 推进来的详情全被 guard 拦住、永远不读。
        if folderURL == lastScannedFolderURL, !items.isEmpty {
            detailsCancelled = false
            return
        }
        lastScannedFolderURL = folderURL
        cancelDetailTasks()
        detailsCancelled = false
        scanning = true
        errorText = nil
        // O-5：不清 items，旧列表一直可见到新列表就绪（枚举
        // 完再整体替换）；初次扫 items 为空，照常显示
        // ProgressView（见 Grid 的 scanning && items.isEmpty）。
        // 首次扫顺手做一次磁盘缓存 LRU 清理（O-16）。
        _ = Self.czfCachePruneOnce
        Task {
            didStartAccessing = folderURL.startAccessingSecurityScopedResource()
            let fm = FileManager.default
            // 安装审计 #17：打不开要分原因，不许再用一句笼统的
            // “打不开这个文件夹”盖住所有情况。startAccessing
            // 返回 false 本身不直接报错（沙盒内目录也会返回
            // false 但照常能读），读失败时再结合它定文案。
            let ipaURLs: [URL]
            do {
                var found: [URL] = []
                try collectIpaURLs(in: folderURL, into: &found)
                ipaURLs = found
            } catch let error as NSError {
                // O-5：扫失败时把短路标记清掉，下次出现重扫；
                // 否则旧列表非空会直接短路返回，错误一直挂着。
                lastScannedFolderURL = nil
                if !didStartAccessing {
                    errorText = "没有权限访问这个文件夹，请重新选择文件夹"
                } else if error.domain == NSCocoaErrorDomain && error.code == 260 {
                    // Cocoa 260 = NSFileReadNoSuchFileError（LCUtilsExtensions 同款判法）
                    errorText = "这个文件夹已被移动或删除，请重新选择文件夹"
                } else if error.domain == NSCocoaErrorDomain && error.code == 257 {
                    // Cocoa 257 = NSFileReadNoPermissionError
                    errorText = "没有权限访问这个文件夹：\(error.localizedDescription)"
                } else {
                    errorText = "读取文件夹失败：\(error.localizedDescription)"
                }
                scanning = false
                return
            }
            let sortedURLs = ipaURLs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            items = sortedURLs.map { url in
                let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                return CZFLocalIpaItem(
                    url: url,
                    fileName: url.lastPathComponent,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    version: nil,
                    sizeText: size > 0 ? fmt.string(fromByteCount: size) : "",
                    icon: nil
                )
            }
            scanning = false
            // O-30：扫完不再全量解包所有 IPA（100 个包就要解
            // 100 次，打开文件夹卡半天）。文件名先顶着，详情
            // 由格子滚到眼前时 onAppear 按需推进。
        }
    }

    // 递归扫子文件夹（App #14）：contentsOfDirectory 不递归，
    // 子文件夹里的 IPA 原来静默忽略。跳过隐藏文件
    // （.skipsHiddenFiles）、不跟进软链目录（LCDataManagementView
    // .folderSize 同款防死循环）、不钻进 .app/.ipa 包内部。
    private func collectIpaURLs(in folder: URL, into out: inout [URL]) throws {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                let ext = url.pathExtension.lowercased()
                if ext == "app" || ext == "ipa" { continue }
                try collectIpaURLs(in: url, into: &out)
            } else if url.pathExtension.lowercased() == "ipa"
                        || url.pathExtension.lowercased() == "tipa" {
                // 安装审计 #10 / App #13：扫描加上 .tipa，
                // 与 + 号导入接受 [.ipa, .tipa] 保持一致。
                out.append(url)
            }
        }
    }

    // O-30 文件夹懒加载：格子滚到眼前时 onAppear 调这里，
    // 把想要详情的项推进队里；已读过、已在队里、已取消的
    // 不再推进。单任务按 3 个一组并行解包（安装审计 #5 /
    // App #15 同款限流），不在队里的不解。
    // 顺序按文件名定（扫完已按文件名排好），详情读回来只
    // 改显示名/版本/图标，不重排——滚动中重排会跳格；
    // App #28 的“读完按显示名重排”随全量解包一起去掉。
    func loadDetailIfNeeded(for item: CZFLocalIpaItem) {
        guard !detailsCancelled,
              items.contains(where: { $0.id == item.id && !$0.detailLoaded }),
              !wantedDetailIDs.contains(item.id) else { return }
        wantedDetailIDs.append(item.id)
        if detailTask == nil {
            detailTask = Task { await processWantedDetails() }
        }
    }

    // 详情解包限流 3 个并发（安装审计 #5 / App #15）：
    // 抄 LCAltStoreSourcesView.refreshAllSources 的分块任务组
    // 写法，每 3 个一组并行解包，组间顺序等；100 个 IPA
    // 不再是 100 个并发解压。取消时组内未开始的解包不再
    // 启动（Task.isCancelled 守卫），在途的解包由
    // loadDetails 里的 detailsCancelled 拦住不刷表。
    // 队空了就停，下次格子出现再推进。
    private func processWantedDetails() async {
        // O-16：缓存键用相对文件夹根的相对路径，根传给
        // loadDetails（后台解包任务里直接用，不回主线程取）。
        let root = folderURL
        while !wantedDetailIDs.isEmpty {
            if Task.isCancelled { return }
            let chunk = Array(wantedDetailIDs.prefix(3))
            wantedDetailIDs.removeFirst(min(3, wantedDetailIDs.count))
            // 只处理还在列表里、还没读过详情的项（重扫重建后
            // 旧 id 可能已不在列表里）。
            let targets = chunk.compactMap { id in items.first(where: { $0.id == id && !$0.detailLoaded }) }
            if targets.isEmpty { continue }
            await withTaskGroup(of: Void.self) { group in
                for item in targets {
                    group.addTask {
                        await Task.detached { await self.loadDetails(for: item, folderRoot: root) }.value
                    }
                }
            }
        }
        detailTask = nil
    }

    // 解包是同步重活，不许占主线程：nonisolated，在后台
    // 跑完再回主线程刷那一行。直接在 @MainActor 里调 extract
    // 会卡住列表滚动。
    // 详情磁盘缓存（3.8.446，用户 14:53 令“切换过来每次，
    // 加载图标”）：切到 App 页 onAppear 就重扫重解包，图标
    // 每次现解。把解出的名字/版本/包名/图标缩略图存到
    // Caches/CZFIpaFolderCache，每个 IPA 各存一份
    // <key>.json + <key>.png，并发写不撞同一个文件。
    // O-16：键改用相对文件夹根的相对路径 + 修改时间 + 大小
    // 的 SHA256（原来是绝对路径：文件夹重选/改名/移动就全
    // 部失效）；两级缓存——无图标时也存 .json（名字/版本/
    // 包名），读缓存时图标缺失不判整条未命中（原来缺 png
    // 即未命中，无图标的包每次切 Tab 都全量解包重读）。
    nonisolated private static var czfCacheDir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CZFIpaFolderCache", isDirectory: true)
    }

    nonisolated private static func czfCacheKey(for url: URL, relativeTo folderRoot: URL?) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        // 相对路径：文件在文件夹根下时用根下相对路径（子文件
        // 夹也一样，如 sub/xxx.ipa）；不在根下时回落绝对路径
        //（旧行为，至少还能命中）。
        let rel: String
        if let root = folderRoot, url.path.hasPrefix(root.path) {
            var r = String(url.path.dropFirst(root.path.count))
            if r.hasPrefix("/") { r.removeFirst() }
            rel = r
        } else {
            rel = url.path
        }
        let raw = "\(rel)|\(mtime)|\(size)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // 读缓存：.json 在即命中，图标缺失不判整条未命中（无图
    // 标的包照常用名字/版本/包名，icon 为 nil）；只有 .json
    // 没有（或解析失败）才算未命中、走解包。
    nonisolated private static func czfLoadCachedDetail(for url: URL, relativeTo folderRoot: URL?) -> (name: String?, version: String?, icon: UIImage?, bundleIdentifier: String?)? {
        guard let dir = czfCacheDir,
              let key = czfCacheKey(for: url, relativeTo: folderRoot),
              let metaData = try? Data(contentsOf: dir.appendingPathComponent(key + ".json")),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else { return nil }
        let icon = (try? Data(contentsOf: dir.appendingPathComponent(key + ".png"))).flatMap { UIImage(data: $0) }
        return (meta["name"] as? String, meta["version"] as? String, icon, meta["bundleIdentifier"] as? String)
    }

    // 存缓存：.json 总是存（无图标也存名字/版本/包名；解包
    // 完全失败时存空 {}，下次不再重复解这个坏包——键含修改
    // 时间 + 大小，文件一换键就变、自动失效）；.png 只有有
    // 图标时才存。
    nonisolated private static func czfSaveCachedDetail(for url: URL, relativeTo folderRoot: URL?, name: String?, version: String?, icon: UIImage?, bundleIdentifier: String?) {
        guard let dir = czfCacheDir,
              let key = czfCacheKey(for: url, relativeTo: folderRoot) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta: [String: Any] = [:]
        if let name { meta["name"] = name }
        if let version { meta["version"] = version }
        if let bundleIdentifier { meta["bundleIdentifier"] = bundleIdentifier }
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: dir.appendingPathComponent(key + ".json"))
        }
        if let icon, let png = icon.pngData() {
            try? png.write(to: dir.appendingPathComponent(key + ".png"))
        }
    }

    // O-16：磁盘缓存 LRU 清理——启动后第一次扫文件夹时跑一
    // 次（static let 只初始化一次，线程安全）：条目超 200
    // 个或总大小超 100MB 时删最旧的（按修改时间），直到两
    // 项都回到上限内；无 .json 的孤儿 .png 一并清掉（读缓
    // 存时永远用不上）。
    nonisolated private static let czfCachePruneOnce: Bool = {
        czfPruneCache()
        return true
    }()

    nonisolated private static func czfPruneCache() {
        guard let dir = czfCacheDir else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let maxEntries = 200
        let maxTotalBytes: Int64 = 100 * 1024 * 1024
        var totalSize: Int64 = 0
        var entries: [(key: String, mtime: Date, size: Int64)] = []
        var orphanPNGs: [(url: URL, size: Int64)] = []
        for file in files {
            let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
            totalSize += size
            if file.pathExtension == "json" {
                let key = file.deletingPathExtension().lastPathComponent
                let pngSize = ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(key + ".png").path))?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                entries.append((key: key, mtime: mtime, size: size + pngSize))
            } else if file.pathExtension == "png" {
                let key = file.deletingPathExtension().lastPathComponent
                if !fm.fileExists(atPath: dir.appendingPathComponent(key + ".json").path) {
                    orphanPNGs.append((url: file, size: size))
                }
            }
        }
        for orphan in orphanPNGs {
            try? fm.removeItem(at: orphan.url)
            totalSize -= orphan.size
        }
        var remaining = entries.count
        guard remaining > maxEntries || totalSize > maxTotalBytes else { return }
        for entry in entries.sorted(by: { $0.mtime < $1.mtime }) {
            if remaining <= maxEntries && totalSize <= maxTotalBytes { break }
            try? fm.removeItem(at: dir.appendingPathComponent(entry.key + ".json"))
            try? fm.removeItem(at: dir.appendingPathComponent(entry.key + ".png"))
            totalSize -= entry.size
            remaining -= 1
        }
    }

    nonisolated private func loadDetails(for item: CZFLocalIpaItem, folderRoot: URL) async {
        // 先读磁盘缓存：命中直接用，不解包。
        if let cached = Self.czfLoadCachedDetail(for: item.url, relativeTo: folderRoot) {
            await MainActor.run {
                guard !self.detailsCancelled else { return }
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    if let name = cached.name { self.items[idx].displayName = name }
                    if let version = cached.version { self.items[idx].version = version }
                    if let icon = cached.icon { self.items[idx].icon = icon }
                    if let bundleIdentifier = cached.bundleIdentifier { self.items[idx].bundleIdentifier = bundleIdentifier }
                    self.items[idx].detailLoaded = true
                }
            }
            return
        }
        let info = Self.extractIpaInfo(url: item.url)
        // 解出来了就存缓存，下次切回来直接读（无图标也存 .json）。
        Self.czfSaveCachedDetail(for: item.url, relativeTo: folderRoot, name: info.name, version: info.version, icon: info.icon, bundleIdentifier: info.bundleIdentifier)
        await MainActor.run {
            guard !self.detailsCancelled else { return }
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                if let name = info.name { self.items[idx].displayName = name }
                if let version = info.version { self.items[idx].version = version }
                if let icon = info.icon { self.items[idx].icon = icon }
                if let bundleIdentifier = info.bundleIdentifier { self.items[idx].bundleIdentifier = bundleIdentifier }
                self.items[idx].detailLoaded = true
            }
        }
    }

    nonisolated private static func extractIpaInfo(url: URL) -> (name: String?, version: String?, icon: UIImage?, bundleIdentifier: String?) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("CZFIpaFolder-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        guard extract(url.path, tmp.path, progress) == 0 else { return (nil, nil, nil, nil) }
        let payload = tmp.appendingPathComponent("Payload")
        guard let contents = try? fm.contentsOfDirectory(atPath: payload.path),
              let appName = contents.first(where: { $0.hasSuffix(".app") }) else { return (nil, nil, nil, nil) }
        let appDir = payload.appendingPathComponent(appName)
        guard let data = try? Data(contentsOf: appDir.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return (nil, nil, nil, nil) }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        let version = plist["CFBundleShortVersionString"] as? String
        // 3.8.444：包名供格子打“已安装”绿勾。
        let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        var icon: UIImage?
        // 图标名先看 CFBundleIconFiles，没有就试常见名。
        var candidates: [String] = []
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            candidates.append(contentsOf: files)
        }
        candidates.append(contentsOf: ["AppIcon60x60", "AppIcon76x76", "AppIcon40x40"])
        outer: for base in candidates {
            // 安装低 #19：先直接试 base 本身（CFBundleIconFiles
            // 里的名字有的自带后缀），再试拼接后缀。
            for suffix in ["", "@3x.png", "@2x.png", ".png"] {
                let path = appDir.appendingPathComponent(base + suffix).path
                if let img = UIImage(contentsOfFile: path) {
                    icon = img
                    break outer
                }
            }
        }
        // 安装中 #7：现代 App 图标都在 Assets.car 里，散装 PNG
        // 找不到时用公开 API 读：UIImage(named:in:) 会查该
        // Bundle 的 Assets.car，不用自己解析 car 格式；名字取
        // CFBundleIconName，没有就试 "AppIcon"，取不到再回落占位。
        if icon == nil, let bundle = Bundle(url: appDir) {
            var iconSetName = "AppIcon"
            if let icons = plist["CFBundleIcons"] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let name = primary["CFBundleIconName"] as? String {
                iconSetName = name
            }
            icon = UIImage(named: iconSetName, in: bundle, compatibleWith: nil)
        }
        // 安装低 #19：存入前按显示尺寸缩成缩略图，原图全尺寸
        // 常驻内存（格子只显示约 85pt）。
        if let img = icon {
            icon = Self.czfMakeThumbnail(img)
        }
        return (name, version, icon, bundleIdentifier)
    }

    // 安装低 #19：按显示尺寸缩成缩略图——格子只显示约 85pt，
    // 原图（常上千 px）全尺寸常驻内存。最长边 ≤256px 就够
    // @3x 的 85pt 格子；已经够小的原样返回。
    nonisolated private static func czfMakeThumbnail(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 256
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }
        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// App 页下方内嵌文件夹 IPA 区（3.8.436，用户 11:15 令，红框处）：
// 选过的文件夹的 IPA 直接显示在已装 App 下方，不用再点
// 文件夹按钮弹 sheet（sheet 426/429/430/435 四版都没稳住）。
// 复用 CZFLocalIpaFolderModel 扫描 + CZFLocalIpaGridCell 格子，
// 点格子直接安装。没选过文件夹时只显示一个“选择文件夹”按钮。
struct CZFInlineIpaFolderSection: View {
    var folderURL: URL?
    var onPickFolder: () -> Void
    var onInstall: (URL) -> Void
    // S-11：清除文件夹回调——源页传进来，调 store.clear() 并置
    // czfIpaFolderURL = nil（本节不直接碰那把 @State）。
    var onClearFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("本地 IPA 文件夹")
                    .font(.headline)
                Spacer()
                if folderURL != nil {
                    Button("清除文件夹", role: .destructive, action: onClearFolder)
                        .font(.footnote)
                    Button("换文件夹", action: onPickFolder)
                        .font(.footnote)
                }
            }
            if let url = folderURL {
                // 文件夹换了就重建模型重扫（StateObject 的
                // folderURL 是 let，不重建就还是旧文件夹）。
                CZFInlineIpaFolderGrid(folderURL: url, onPickFolder: onPickFolder, onInstall: onInstall)
                    .id(url)
            } else {
                Button(action: onPickFolder) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("选择 IPA 文件夹")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// 内嵌区格子：自带 CZFLocalIpaFolderModel，出现即扫。
// 用实格子（VStack + HStack 按 4 列切行，全量渲染），不用
// LazyVGrid——嵌在 App 页 ScrollView 的 VStack 里，懒格子
// 高度按可见行算、滑动会跳（源页 433 同款毛病）。
struct CZFInlineIpaFolderGrid: View {
    let folderURL: URL
    var onPickFolder: () -> Void
    var onInstall: (URL) -> Void

    @StateObject private var model: CZFLocalIpaFolderModel

    init(folderURL: URL, onPickFolder: @escaping () -> Void, onInstall: @escaping (URL) -> Void) {
        self.folderURL = folderURL
        self.onPickFolder = onPickFolder
        self.onInstall = onInstall
        _model = StateObject(wrappedValue: CZFLocalIpaFolderModel(folderURL: folderURL))
    }

    // 3.8.442：列数跟上面已装 App 网格一致——原来写死 4 列，
    // 图标比上面 5 列的大、不对称。读同一份网格设置
    //（CZFAppGridColumns，默认 5），用户改上面列数时下面
    // 跟着变，永远对齐。
    @AppStorage("CZFAppGridColumns") private var czfAppGridColumns = 5
    private var czfColCount: Int { max(3, min(6, czfAppGridColumns)) }

    var body: some View {
        Group {
            // O-5：重扫时旧列表非空就不盖 ProgressView，列表一
            // 直可见到新列表就绪；只有初次扫（列表为空）才转圈。
            if model.scanning && model.items.isEmpty {
                ProgressView("正在读取文件夹…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let errorText = model.errorText {
                VStack(spacing: 8) {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重新选择文件夹", action: onPickFolder)
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if model.items.isEmpty {
                Text("这个文件夹里没有 IPA")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // O-30：行式 VStack 改 LazyVGrid——格子只在滚到
                // 眼前时才创建，onAppear 按需推进详情解包；没滚
                // 到的 IPA 不解包。列数/间距与原来一致（列数读
                // 同一份网格设置，横向间距 16、纵向 12），末行
                // 不用再手填 Color.clear 占位。
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: czfColCount), spacing: 12) {
                    ForEach(model.items) { item in
                        CZFLocalIpaGridCell(item: item) {
                            onInstall(item.url)
                        }
                        .onAppear { model.loadDetailIfNeeded(for: item) }
                    }
                }
            }
        }
        .onAppear { model.scan() }
        .onDisappear { model.cancelDetailTasks() }
    }
}

// 一个 IPA 的格子（3.8.426）：源页同款——大图标 + 下方名字
// （两行）+ 版本/大小，点格子直接安装。图标没解出来之前
// 先显示占位，解出来那一行自己刷出来。
struct CZFLocalIpaGridCell: View {
    let item: CZFLocalIpaItem
    var onTap: () -> Void

    // 3.8.444：已安装标记（用户 13:51 令“不知道哪个安装了
    // 哪个没安装”）——按包名比对已装 App（含隐藏 App），与源
    // 页绿勾（CZFSourceGridView）同款判据、同款绿勾位置。
    @EnvironmentObject private var sharedModel: SharedModel
    // 3.8.459 兼容审计：名字晕影按 colorScheme 换色（与 App 网格
    // CZFAppGridView:463、源格子 CZFSourceGridView:427 同款）——
    // 原来写死白晕影，深色模式下白字压在亮壁纸上没对比、读不清。
    @Environment(\.colorScheme) private var colorScheme
    private var czfIsInstalled: Bool {
        guard let bid = item.bundleIdentifier, !bid.isEmpty else { return false }
        return (sharedModel.apps + sharedModel.hiddenApps).contains { $0.appInfo.bundleIdentifier() == bid }
    }

    // App #16：detailLoaded 是“已尝试读详情”标记——读完
    // 仍没图标也没版本号 = 解包失败，挂一句“无法读取”，
    // 和“还在读”（占位图标）区分开。
    private var czfDetailFailed: Bool {
        item.detailLoaded && item.icon == nil && item.version == nil
    }

    // 3.8.454：图标跟已装 App 网格同一套大小设置（大/中/小 =
    // 单元宽度的 1.0 / 0.85 / 0.7）——原来写死满宽 1.0，不读
    // 设置，用户在网格设置里选“小”时上面变小、下面还是满宽，
    // 看着文件夹图标比上面大一圈（用户 20:32 报）。
    @AppStorage("CZFAppGridIconSize") private var czfGridIconSize = 0
    private var czfIconFactor: CGFloat {
        switch czfGridIconSize {
        case 1: return 0.85
        case 2: return 0.7
        default: return 1.0
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { geo in
                    let side = min(max(geo.size.width * czfIconFactor, 44), geo.size.width)
                    Group {
                        if let icon = item.icon {
                            IconImageView(icon: icon)
                        } else {
                            Image(systemName: "app.badge")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: side, height: side)
                    // App #17：灰底挂到定好宽高的外层 frame 上，
                    // 整格灰色占位，不再只贴在 glyph 大小的 Image 上。
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .aspectRatio(1, contentMode: .fit)
                if czfIsInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                        .background(Color(.systemBackground).opacity(0.85), in: Circle())
                        .offset(x: 6, y: -6)
                }
            }
            Text(item.displayName)
                .font(.footnote)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.95) : .white.opacity(0.95), radius: 4, x: 0, y: 0)
            Text(czfDetailFailed ? "无法读取".loc : [item.version.map { "版本 \($0)" }, item.sizeText.isEmpty ? nil : item.sizeText].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
