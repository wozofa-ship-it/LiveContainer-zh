// 本地 IPA 文件夹（3.8.423，用户 21:49 令）：+ 号旁边加一个
// 文件夹按钮，选一个本地文件夹，读出里面的 IPA，显示名字
// 和图标，点一下就安装。文件夹用 security-scoped bookmark
// 记住，下次点按钮直接打开，不用重新选。
import SwiftUI
import UIKit
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
    // 3.8.666（B-alt）：id 改相对路径派生稳定键——原来 `let id = UUID()`
    // 每次重建随机，scan() 全量重建后批量选中集按 id 匹配全丢
    // （长按单删触发重扫即丢选；同名替换触发全扫也丢选）；
    // 现在同一文件（相对路径不变）重建出同一 id，勾选跨重扫
    // 与同名替换都保留。派生用相对路径 SHA256 前 16 字节
    // （O-16 czfCacheKey 同款思路，相对路径 + 哈希，不含 mtime/
    // size——文件被替换后 id 不变、勾选才留得住）；文件夹根外
    // 回落绝对路径。id 仍是 UUID 类型，itemsByID / wantedDetailIDs
    // 全是 id 键，不用改类型、不动选中集结构。
    let id: UUID
    let url: URL
    let fileName: String
    var displayName: String
    var version: String?
    // 3.8.668（B-2）：build 号（CFBundleVersion）——同版不同 build
    // 的包要按 build 比新旧；读不到为 nil，按 0 比。
    var build: String?
    var sizeText: String
    var icon: UIImage?
    var detailLoaded = false
    // 3.8.649（F3）：按大小/最新排序要数字大小与修改时间——
    // sizeText 是格式化字符串，比不了大小。
    var fileSize: Int64 = 0
    var modificationDate: Date?
    // 3.8.444：包名（CFBundleIdentifier），供格子打“已安装”
    // 绿勾——读 Info.plist 得来，读不到时不打勾。
    var bundleIdentifier: String?

    init(url: URL, fileName: String, displayName: String, version: String? = nil, build: String? = nil, sizeText: String, icon: UIImage? = nil, detailLoaded: Bool = false, fileSize: Int64 = 0, modificationDate: Date? = nil, bundleIdentifier: String? = nil, folderRoot: URL? = nil) {
        self.id = Self.czfStableID(for: url, relativeTo: folderRoot)
        self.url = url
        self.fileName = fileName
        self.displayName = displayName
        self.version = version
        self.build = build
        self.sizeText = sizeText
        self.icon = icon
        self.detailLoaded = detailLoaded
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.bundleIdentifier = bundleIdentifier
    }

    static func czfStableID(for url: URL, relativeTo folderRoot: URL?) -> UUID {
        let rel: String
        if let root = folderRoot, url.path.hasPrefix(root.path) {
            var r = String(url.path.dropFirst(root.path.count))
            if r.hasPrefix("/") { r.removeFirst() }
            rel = r
        } else {
            rel = url.path
        }
        let digest = SHA256.hash(data: Data(rel.utf8))
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

@MainActor
final class CZFLocalIpaFolderModel: ObservableObject {
    @Published var items: [CZFLocalIpaItem] = [] {
        didSet {
            // D11：id→item 查表与 items 同步——didSet 覆盖全量
            // 替换（scan）与单行字段改写（loadDetails）两路，
            // loadDetailIfNeeded 与 processWantedDetails 的 id
            // 查找走它，不再线性扫 items。
            itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        }
    }
    // D11：id→item 查表（与 items 同步，见 items 的 didSet）。
    private var itemsByID: [UUID: CZFLocalIpaItem] = [:]
    @Published var scanning = true
    @Published var errorText: String?

    let folderURL: URL
    private var didStartAccessing = false
    // O-30 文件夹懒加载：详情解包任务——单任务按想要详情的
    // 项 3 个一组并行解包；弹窗关闭时 cancelDetailTasks() 取消它。
    private var detailTask: Task<Void, Never>?
    // 3.8.900（L585-C1）：扫文件夹的代次——onAppear 重进时旧 Task 还在跑，新 Task 不取消它（Task 体里无挂起点、取消也停不住），只凭代次拦旧写回；存 Task 会与 self 成环，不存。
    private var czfScanEpoch = 0
    // O-30：想要详情的项 id 集合（格子滚到眼前时 onAppear
    // 推进来），不在队里的不解，不浪费 CPU。
    // D11：由 [UUID] 改 Set，contains/insert/remove 全是
    // O(1)；取 chunk 时顺序不再是推进顺序（Set 无序），但
    // 只影响先解哪 3 个，列表仍按文件名序、读回不重排，
    // 显示不受影响。
    private var wantedDetailIDs: Set<UUID> = []
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
            // 3.8.900（L565-2）：O-5 短路只认文件夹 URL，不认内容——外面
            // 增删 IPA 后切回来，onAppear 调 scan() 直接短路返回，列表陈旧：
            // 新 IPA 不出现、已删的还留着，点它安装失败。短路前先比一次
            // 递归枚举出的 IPA 地址集（collectIpaURLs 本来就是扫的第一步，
            // 枚举本身便宜；贵的是逐文件 stat 与详情解包，短路照样省掉）：
            // 地址集与当前列表一致才短路，不一致就走全扫；枚举失败时
            // 也走全扫（全扫的 do/catch 会报真错）。
            var found: [URL] = []
            if (try? collectIpaURLs(in: folderURL, into: &found)) != nil {
                let sortedFound = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                // 3.8.664（B1）：短路比对改指纹（URL + 修改时间 + 大小）——
                // 同名 IPA 被新文件替换时地址集不变，只比 URL 会短路返回、
                // 列表仍显旧版本/大小/“有更新”徽标；任一文件指纹不同即走
                // 全扫。全扫重建全部行（detailLoaded 回 false，变化的行
                // 重新读详情），详情缓存键同样含修改时间 + 大小，旧缓存
                // 不再命中——两道门都动，只动一道仍 stale。
                let czfFoundPrints: [(URL, Int64, Double)] = sortedFound.map { url in
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    return (url, size, mtime)
                }
                let czfCurrentPrints: [(URL, Int64, Double)] = items.map { ($0.url, $0.fileSize, $0.modificationDate?.timeIntervalSince1970 ?? 0) }
                // 3.8.665 修法：元组数组没有 ==（元组不遵 Equatable，
                // 构建 45776004621 唯一红字）——改逐项比对，顺序敏感
                // 语义与原 == 一致（两边同按文件名排序）。
                if czfFoundPrints.elementsEqual(czfCurrentPrints, by: { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }) {
                    return
                }
            }
        }
        lastScannedFolderURL = folderURL
        cancelDetailTasks()
        detailsCancelled = false
        scanning = true
        errorText = nil
        // 3.8.900（L585-C1）：代次 +1、取本次代次；didStartAccessing 快照进本地量——Task 是裸 Task，里面直读这个 @MainActor 旗是跨线程读。
        czfScanEpoch += 1
        let czfEpoch = czfScanEpoch
        let czfNeedsAccess = !didStartAccessing
        // O-5：不清 items，旧列表一直可见到新列表就绪（枚举
        // 完再整体替换）；初次扫 items 为空，照常显示
        // ProgressView（见 Grid 的 scanning && items.isEmpty）。
        // 首次扫顺手做一次磁盘缓存 LRU 清理（O-16）。
        _ = Self.czfCachePruneOnce
        Task {
            // 3.8.492（L10）：startAccessing 只起一次——scan() 在
            // 列表为空时可重跑（onAppear 再进），原来每次 Task 都
            // 起一次，deinit 只停一次，多起的访问权一直挂着。
            // 首次起过（didStartAccessing 已真）就不再起；首次
            // 起失败（沙盒内目录返 false）时仍为 false，下次重扫
            // 会重试，行为不变。
            // 3.8.900（L585-C1）：取权仍在这里做（文件 I/O 不上主线程），旗只回主线程置；czfStarted 供下面报错分支用，不用再读 didStartAccessing。
            let czfStarted: Bool
            if czfNeedsAccess {
                czfStarted = folderURL.startAccessingSecurityScopedResource()
                await MainActor.run { self.didStartAccessing = czfStarted }
            } else {
                czfStarted = true
            }
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
                let czfErrorText: String
                if !czfStarted {
                    czfErrorText = "没有权限访问这个文件夹，请重新选择文件夹"
                } else if error.domain == NSCocoaErrorDomain && error.code == 260 {
                    // Cocoa 260 = NSFileReadNoSuchFileError（LCUtilsExtensions 同款判法）
                    czfErrorText = "这个文件夹已被移动或删除，请重新选择文件夹"
                } else if error.domain == NSCocoaErrorDomain && error.code == 257 {
                    // Cocoa 257 = NSFileReadNoPermissionError
                    czfErrorText = "没有权限访问这个文件夹：\(error.localizedDescription)"
                } else {
                    czfErrorText = "读取文件夹失败：\(error.localizedDescription)"
                }
                // 3.8.900（L585-C1）：写回全回主线程、代次不对就一行不写——旧 Task 的失败不盖新 Task 的列表。
                await MainActor.run {
                    guard czfEpoch == self.czfScanEpoch else { return }
                    lastScannedFolderURL = nil
                    errorText = czfErrorText
                    scanning = false
                }
                return
            }
            let sortedURLs = ipaURLs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            // 3.8.900（L585-C1）：条目先在后台拼好，赋值回主线程；代次不对（已有新一轮在扫）就不写，旧列表不盖新列表。
            let czfNewItems = sortedURLs.map { url in
                // 3.8.649（F3）：attributesOfItem 只调一次，顺手取
                // 大小（数字）与修改时间——不新增磁盘 I/O。
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return CZFLocalIpaItem(
                    url: url,
                    fileName: url.lastPathComponent,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    version: nil,
                    sizeText: size > 0 ? fmt.string(fromByteCount: size) : "",
                    icon: nil,
                    fileSize: size,
                    modificationDate: attrs?[.modificationDate] as? Date,
                    // 3.8.666（B-alt）：id 按相对路径派生，根传进来——
                    // 不传就回落绝对路径，文件夹改名/移动会换 id。
                    folderRoot: folderURL
                )
            }
            await MainActor.run {
                guard czfEpoch == self.czfScanEpoch else { return }
                items = czfNewItems
                scanning = false
            }
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
                // 3.8.492（L10）：子文件夹读失败只跳过它——原来
                // try 会把错误一路抛回 scan() 的 do/catch，整个
                // 文件夹直接报“读取文件夹失败”，顶层已扫到的 IPA
                // 也全丢；一个无权限的子文件夹不该毁掉整份列表。
                try? collectIpaURLs(in: url, into: &out)
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
              let current = itemsByID[item.id], !current.detailLoaded,
              !wantedDetailIDs.contains(item.id) else { return }
        wantedDetailIDs.insert(item.id)
        if detailTask == nil {
            detailTask = Task { await processWantedDetails() }
        }
    }

    // 3.8.662（B3）：搜索时补推全部未读详情——搜索只比已解出的
    // version，没滚到的行 version 恒为 nil、搜版本号搜不到；
    // 把全部未读详情的 id 一次推进 wantedDetailIDs，复用现有
    // 3 个一组后台管道 + 磁盘缓存（多数是缓存命中，不全量解包）。
    // 搜索框 onChange 节流后调；detailsCancelled 守卫与
    // loadDetailIfNeeded 同款。
    func czfRequestAllDetails() {
        guard !detailsCancelled else { return }
        for item in items where !item.detailLoaded {
            guard !wantedDetailIDs.contains(item.id) else { continue }
            wantedDetailIDs.insert(item.id)
        }
        if detailTask == nil, !wantedDetailIDs.isEmpty {
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
            for id in chunk { wantedDetailIDs.remove(id) }
            // 只处理还在列表里、还没读过详情的项（重扫重建后
            // 旧 id 可能已不在列表里）。
            let targets = chunk.compactMap { id -> CZFLocalIpaItem? in
                guard let item = itemsByID[id], !item.detailLoaded else { return nil }
                return item
            }
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
    // 3.8.668（B-2）：build 进缓存——旧缓存没有 "build" 键时按
    // 未命中处理、走一次解包重存（新缓存总写该键，无 build 的包
    // 写 ""，不再反复解包）；元组顺序与 extractIpaInfo 一致。
    nonisolated private static func czfLoadCachedDetail(for url: URL, relativeTo folderRoot: URL?) -> (name: String?, version: String?, build: String?, icon: UIImage?, bundleIdentifier: String?)? {
        guard let dir = czfCacheDir,
              let key = czfCacheKey(for: url, relativeTo: folderRoot),
              let metaData = try? Data(contentsOf: dir.appendingPathComponent(key + ".json")),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let build = meta["build"] as? String else { return nil }
        let icon = (try? Data(contentsOf: dir.appendingPathComponent(key + ".png"))).flatMap { UIImage(data: $0) }
        return (meta["name"] as? String, meta["version"] as? String, build, icon, meta["bundleIdentifier"] as? String)
    }

    // 存缓存：.json 总是存（无图标也存名字/版本/包名；解包
    // 完全失败时存空 {}，下次不再重复解这个坏包——键含修改
    // 时间 + 大小，文件一换键就变、自动失效）；.png 只有有
    // 图标时才存。
    // 3.8.668（B-2）：build 总写键（无 build 写 ""），与上面读缓存
    // 的“无键即旧缓存”口径配对；解包完全失败时 build 也写 ""。
    nonisolated private static func czfSaveCachedDetail(for url: URL, relativeTo folderRoot: URL?, name: String?, version: String?, build: String?, icon: UIImage?, bundleIdentifier: String?) {
        guard let dir = czfCacheDir,
              let key = czfCacheKey(for: url, relativeTo: folderRoot) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta: [String: Any] = [:]
        if let name { meta["name"] = name }
        if let version { meta["version"] = version }
        meta["build"] = build ?? ""
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
                    if let build = cached.build, !build.isEmpty { self.items[idx].build = build }
                    if let icon = cached.icon { self.items[idx].icon = icon }
                    if let bundleIdentifier = cached.bundleIdentifier { self.items[idx].bundleIdentifier = bundleIdentifier }
                    self.items[idx].detailLoaded = true
                }
            }
            return
        }
        let info = Self.extractIpaInfo(url: item.url)
        // 解出来了就存缓存，下次切回来直接读（无图标也存 .json）。
        Self.czfSaveCachedDetail(for: item.url, relativeTo: folderRoot, name: info.name, version: info.version, build: info.build, icon: info.icon, bundleIdentifier: info.bundleIdentifier)
        await MainActor.run {
            guard !self.detailsCancelled else { return }
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                if let name = info.name { self.items[idx].displayName = name }
                if let version = info.version { self.items[idx].version = version }
                if let build = info.build { self.items[idx].build = build }
                if let icon = info.icon { self.items[idx].icon = icon }
                if let bundleIdentifier = info.bundleIdentifier { self.items[idx].bundleIdentifier = bundleIdentifier }
                self.items[idx].detailLoaded = true
            }
        }
    }

    nonisolated private static func extractIpaInfo(url: URL) -> (name: String?, version: String?, build: String?, icon: UIImage?, bundleIdentifier: String?) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("CZFIpaFolder-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        guard extract(url.path, tmp.path, progress) == 0 else { return (nil, nil, nil, nil, nil) }
        let payload = tmp.appendingPathComponent("Payload")
        guard let contents = try? fm.contentsOfDirectory(atPath: payload.path),
              let appName = contents.first(where: { $0.hasSuffix(".app") }) else { return (nil, nil, nil, nil, nil) }
        let appDir = payload.appendingPathComponent(appName)
        guard let data = try? Data(contentsOf: appDir.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return (nil, nil, nil, nil, nil) }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        let version = plist["CFBundleShortVersionString"] as? String
        // 3.8.668（B-2）：build 号（CFBundleVersion）——同版不同 build
        // 的包要按 build 比新旧；读不到为 nil，按 0 比。
        let build = plist["CFBundleVersion"] as? String
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
        return (name, version, build, icon, bundleIdentifier)
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

// 3.8.649（F3）：本地 IPA 文件夹排序——名字（现状）/ 大小
// （大→小）/ 最新（修改时间新→旧）。键 `CZFLocalIpaFolderSort`
// 是新 @AppStorage 键，默认名字序；菜单标题硬编码中文，沿用
// “复制 Bundle ID”同款先例。0 新 L() key。iOS 15 无新 API。
enum CZFLocalIpaFolderSort: String, CaseIterable {
    case name
    case size
    case recent

    var czfDisplayName: String {
        switch self {
        case .name: return "按名字"
        case .size: return "按大小"
        case .recent: return "按最新"
        }
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

    // 3.8.649（F3）：文件夹排序开关——与下面格子读同一把
    // @AppStorage 键（UserDefaults 共享，两处都跟随）。
    @AppStorage("CZFLocalIpaFolderSort") private var czfSort = CZFLocalIpaFolderSort.name
    // 3.8.672（F-3）：只看有新版——3.8.682（B3）上移到源页持有
    // （见 LCAltStoreSourcesView czfFolderOnlyUpdatable），本节只读/
    // 改；切分段不再丢。过滤在下面格子里。
    @Binding var czfOnlyUpdatable: Bool
    // 3.8.682（B3）：文件夹搜索字——3.8.653（F1）原是本节下格子的
    // @State，分段切换即丢；上移到源页持有（见 LCAltStoreSourcesView
    // czfFolderSearchText），本节只透传给格子。不持久化。
    @Binding var czfSearchText: String
    // 3.8.658（B2）：“清除文件夹”确认框开关——此前一点即清，
    // 与“换文件夹”并排、误触即丢绑定（重选可恢复，不是丢文件）。
    @State private var czfShowClearFolderConfirm = false
    // 3.8.662（F2）：文件夹多选批量——选中集存 CZFLocalIpaItem.id（UUID），与 App 页
    // batchSelectedIDs 同款不持久化；id 已改相对路径派生稳定键
    // （3.8.666 B-alt），文件夹重扫不再重建 id，旧选中不再自然失效，
    // 格子按实际匹配到的项计数、不认 stale id（只剩已删文件的旧 id 不匹配）。
    // 3.8.666（B-alt）：批量态与选中集由源页持有（见 LCAltStoreSourcesView
    // czfFolderBatchMode / czfFolderSelectedIDs），本节只读/改、不再自己
    // @State——源/文件夹分段一切换，if 分支销毁重建，本节的 @State 全丢；
    // 上移后分段切换不丢勾选。
    @Binding var czfBatchMode: Bool
    @Binding var czfSelectedIDs: Set<UUID>
    // 3.8.718（F-3）：重复包清理——格子上报的每组待删旧包
    //（标题行按钮计数/确认框组数用）；清理请求序号（确认后
    // +1，格子 onChange 收到后删文件重扫）；确认框开关。模型
    // 在格子里，标题行不直接碰模型（文件夹切换时格子
    // .id(url) 重建，模型跟着换）。
    @State private var czfDupExtraGroups: [[CZFLocalIpaItem]] = []
    @State private var czfDupCleanupRequest = 0
    @State private var czfShowDupCleanupConfirm = false
    private var czfDupExtraCount: Int { czfDupExtraGroups.flatMap { $0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 3.8.712：表头分两行——单行 7 项理想宽约 540pt > 440pt
            // 屏宽，SwiftUI 压最低优先级的可换行 Text，Toggle label
            // “只看有新版”被压成一字宽竖条、排序 Menu 也折两行。
            // 两行各加 fixedSize + lineLimit(1)，再宽也不竖排。
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text("本地 IPA 文件夹")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    if folderURL != nil {
                        // 3.8.649（F3）：排序切换——Picker 放 Menu 里
                        //（App 页排序菜单 LCAppListView:904 同款写法）。
                        Menu {
                            Picker("排序", selection: $czfSort) {
                                ForEach(CZFLocalIpaFolderSort.allCases, id: \.self) { sort in
                                    Text(sort.czfDisplayName).tag(sort)
                                }
                            }
                        } label: {
                            // UI 打磨（3.8.649）：按钮直接显示当前排序，
                            // 不用点开菜单才知道现在按什么排。
                            Label(czfSort.czfDisplayName, systemImage: "arrow.up.arrow.down")
                                .font(.footnote)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        // 3.8.662（F2）：多选开关——点开后格子点按改为
                        // 勾选（App 页菜单“多选”同款语义）；关掉即清选中。
                        Button(czfBatchMode ? "完成" : "多选") {
                            czfBatchMode.toggle()
                            if !czfBatchMode { czfSelectedIDs.removeAll() }
                        }
                        .font(.footnote)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if folderURL != nil {
                    HStack {
                        // 3.8.672（F-3）：只看有新版——排序 Menu 旁的
                        // Toggle，与 App 页“仅可更新”同款语义（只留带
                        // 红箭头的行）；文案进表（lc.folder.onlyUpdatable）。
                        Toggle("lc.folder.onlyUpdatable".loc, isOn: $czfOnlyUpdatable)
                            .font(.footnote)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        // 3.8.718（F-3）：清理重复——有已知重复组时
                        // 才出现；删前弹确认框报组数/份数。详情是懒
                        // 加载的，没滚到的行还没解出包名/版本、进不
                        // 了分组，按钮只按当前已知重复显示（确认后
                        // 删时格子再按当时列表重算）。
                        if !czfDupExtraGroups.isEmpty {
                            Button("清理重复（\(czfDupExtraCount)）") {
                                czfShowDupCleanupConfirm = true
                            }
                            .font(.footnote)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .confirmationDialog("清理重复包", isPresented: $czfShowDupCleanupConfirm, titleVisibility: .visible) {
                                Button("删除", role: .destructive) {
                                    czfDupCleanupRequest += 1
                                }
                                Button("取消", role: .cancel) { }
                            } message: {
                                Text("发现 \(czfDupExtraGroups.count) 组重复包，共 \(czfDupExtraCount) 个旧包将被删除，每组保留修改时间最新的一份，此操作无法撤销。")
                            }
                        }
                        Button("清除文件夹", role: .destructive) {
                            // 3.8.658（B2）：先弹确认再清——与“换文件夹”
                            // 并排，误触即丢绑定；文案不写“无法撤销”
                            //（重选即可恢复），只说要重新选择。
                            czfShowClearFolderConfirm = true
                        }
                        .font(.footnote)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .confirmationDialog("清除文件夹", isPresented: $czfShowClearFolderConfirm, titleVisibility: .visible) {
                            Button("清除", role: .destructive, action: onClearFolder)
                            Button("取消", role: .cancel) { }
                        } message: {
                            Text("将取消已选文件夹，需重新选择文件夹。文件夹里的 IPA 文件不会被删除。")
                        }
                        Button("换文件夹", action: onPickFolder)
                            .font(.footnote)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            if let url = folderURL {
                // 文件夹换了就重建模型重扫（StateObject 的
                // folderURL 是 let，不重建就还是旧文件夹）。
                CZFInlineIpaFolderGrid(folderURL: url, onPickFolder: onPickFolder, onInstall: onInstall, batchMode: $czfBatchMode, selectedIDs: $czfSelectedIDs, onlyUpdatable: $czfOnlyUpdatable, searchText: $czfSearchText, dupExtraGroups: $czfDupExtraGroups, dupCleanupRequest: $czfDupCleanupRequest)
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
    // 3.8.662（F2）：批量态与选中集由标题行持有（开关在标题行），
    // 本格子只读/改；选中集是 Set<UUID>（CZFLocalIpaItem.id）。
    @Binding var czfBatchMode: Bool
    @Binding var czfSelectedIDs: Set<UUID>
    // 3.8.672（F-3）：只看有新版——标题行持有，格子只读；
    // 过滤见下面 czfDisplayedItems。
    @Binding var czfOnlyUpdatable: Bool
    // 3.8.682（B3）：文件夹搜索字——3.8.653（F1）原是本格子的 @State，
    // 分段切换即丢；上移到源页持有（见 LCAltStoreSourcesView
    // czfFolderSearchText），经 Section 以 Binding 传下来。不持久化。
    @Binding var czfSearchText: String
    // 3.8.718（F-3）：重复包清理——模型在格子里，标题行不直接碰
    // 模型：格子把每组待删的旧包上报给标题行（按钮计数/确认框
    // 组数用），标题行确认后把清理请求序号 +1，格子收到后删
    // 文件并重扫。请求序号只增不减，onChange 只认变化。
    @Binding var czfDupExtraGroups: [[CZFLocalIpaItem]]
    @Binding var czfDupCleanupRequest: Int

    @StateObject private var model: CZFLocalIpaFolderModel

    init(folderURL: URL, onPickFolder: @escaping () -> Void, onInstall: @escaping (URL) -> Void, batchMode: Binding<Bool>, selectedIDs: Binding<Set<UUID>>, onlyUpdatable: Binding<Bool>, searchText: Binding<String>, dupExtraGroups: Binding<[[CZFLocalIpaItem]]>, dupCleanupRequest: Binding<Int>) {
        self.folderURL = folderURL
        self.onPickFolder = onPickFolder
        self.onInstall = onInstall
        _model = StateObject(wrappedValue: CZFLocalIpaFolderModel(folderURL: folderURL))
        _czfBatchMode = batchMode
        _czfSelectedIDs = selectedIDs
        _czfOnlyUpdatable = onlyUpdatable
        _czfSearchText = searchText
        _czfDupExtraGroups = dupExtraGroups
        _czfDupCleanupRequest = dupCleanupRequest
    }

    // 3.8.442：列数跟上面已装 App 网格一致——原来写死 4 列，
    // 图标比上面 5 列的大、不对称。读同一份网格设置
    //（CZFAppGridColumns，默认 5），用户改上面列数时下面
    // 跟着变，永远对齐。
    @AppStorage("CZFAppGridColumns") private var czfAppGridColumns = 5
    private var czfColCount: Int { max(3, min(6, czfAppGridColumns)) }

    // 3.8.604（O-18）：已装查找表在父级一次算好，传给格子
    // （见 CZFInstalledLookup）。sharedModel 来自 App 页同层
    // 环境（格子原来自己读它）。文件夹格子只有已装标记要
    // 查表，没有插件判据，pluginPaths 为空。
    @EnvironmentObject private var sharedModel: SharedModel

    // 3.8.649（F3）：与上面标题行读同一把排序键。
    @AppStorage("CZFLocalIpaFolderSort") private var czfSort = CZFLocalIpaFolderSort.name

    // 3.8.649（F1）：长按菜单的分享目标与待删项——分享走系统
    // 分享表（ActivityViewController），删除先弹确认框。
    @State private var czfShareURL: URL?
    @State private var czfDeleteItem: CZFLocalIpaItem?
    // 3.8.662（F2）：批量分享的 URL 组（空 = 未分享）与批量删除
    // 确认框开关——与单项 czfShareURL / czfDeleteItem 分开记，
    // sheet 与 alert 各自只用一套绑定（同一视图挂两个 .sheet /
    // .alert 时只有一个会弹，见下面合并后的绑定）。
    @State private var czfBatchShareURLs: [URL] = []
    @State private var czfShowBatchDeleteConfirm = false
    // 3.8.662（B3）：搜索节流任务——输入停 0.3 秒后才补推全部
    // 未读详情；每敲一字取消上一个，不给每个前缀都全量推队。
    @State private var czfSearchDetailTask: Task<Void, Never>?

    // 3.8.653（F1）：文件夹搜索字现由源页持有（见上面 @Binding
    // czfSearchText，3.8.682 B3），此处不再自己 @State；搜索只滤
    // 本格子，不挂 .searchable（源页 body 已有一个绑源 App 搜索的，
    // 同一 NavigationView 双 .searchable 会抢同一个搜索栏）。

    // 3.8.649（F3）：display 排序只能是渲染层派生数组——items
    // 本身必须保持文件名序，O-5 短路（:180–183）拿
    // sortedFound == items.map(\.url) 比地址集，改 items 顺序
    // 会让短路恒失效、每次切回都全扫重解。
    private var czfSortedItems: [CZFLocalIpaItem] {
        switch czfSort {
        case .name:
            return model.items
        case .size:
            return model.items.sorted { $0.fileSize > $1.fileSize }
        case .recent:
            return model.items.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        }
    }

    // 3.8.653（F1）：搜索过滤派生——在排序派生之后再滤一层，不动
    // czfSortedItems（O-5 短路与排序都不受影响）；四路匹配与 App 页
    // :1112-1122 同款（大小写不敏感），字段都在 CZFLocalIpaItem：
    // fileName / displayName / version / bundleIdentifier（详情解出后才有）。
    private var czfFilteredItems: [CZFLocalIpaItem] {
        let q = czfSearchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return czfSortedItems }
        return czfSortedItems.filter { item in
            item.fileName.localizedCaseInsensitiveContains(q) ||
            item.displayName.localizedCaseInsensitiveContains(q) ||
            (item.version?.localizedCaseInsensitiveContains(q) ?? false) ||
            // 3.8.704（B-2）：搜 build 号也命中——副标题明明显示
            // “版本 v (b)”，搜 build 号却搜不到（App 页 3.8.658 F3
            // 同款；build 缺省 "0" 不参与匹配）。
            ((item.build ?? "") != "0" && (item.build?.localizedCaseInsensitiveContains(q) ?? false)) ||
            (item.bundleIdentifier?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    // 3.8.672（F-3）：只看有新版——在搜索过滤之后再滤一层；
    // 判定口径与行级角标同一份（czfFolderItemHasUpdate），
    // 不动 czfFilteredItems（O-5 短路与搜索都不受影响）。
    private var czfDisplayedItems: [CZFLocalIpaItem] {
        guard czfOnlyUpdatable else { return czfFilteredItems }
        return czfFilteredItems.filter { czfFolderItemHasUpdate(item: $0, installedLookup: czfInstalledLookup) }
    }

    private var czfInstalledLookup: CZFInstalledLookup {
        CZFInstalledLookup(apps: sharedModel.apps, hiddenApps: sharedModel.hiddenApps, pluginPaths: [])
    }

    // 3.8.662（F2）：实际选中的项——按 id 在当前列表里匹配；
    // id 是相对路径派生的稳定键（3.8.666 B-alt），重扫不再换 id，
    // stale id 只剩已删文件那部分，不进这里；底栏计数/禁用/分享/
    // 删除/安装都认它，不认原始 Set 的 count。
    private var czfSelectedItems: [CZFLocalIpaItem] {
        let ids = czfSelectedIDs
        return model.items.filter { ids.contains($0.id) }
    }

    private func czfToggleSelection(_ item: CZFLocalIpaItem) {
        if czfSelectedIDs.contains(item.id) {
            czfSelectedIDs.remove(item.id)
        } else {
            czfSelectedIDs.insert(item.id)
        }
    }

    // 3.8.664（F3）：批量全选——全选范围取当前 czfDisplayedItems
    //（搜索/只看有新版筛后剩下的，与 App 页“搜索时只勾搜到的”同口径）；
    // “取消全选”清掉全部已选项（含筛掉的那部分，App #12 先例）。
    private var czfBatchAllSelected: Bool {
        !czfDisplayedItems.isEmpty && czfDisplayedItems.allSatisfy { czfSelectedIDs.contains($0.id) }
    }
    private func czfToggleBatchSelectAll() {
        if czfBatchAllSelected {
            czfSelectedIDs.removeAll()
        } else {
            for item in czfDisplayedItems {
                czfSelectedIDs.insert(item.id)
            }
        }
    }

    // 3.8.662（F2）：批量删除——循环删文件后一次 model.scan()；
    // URL 集变了，O-5 短路不命中，走全扫（单项删除同款）。
    // 删完清选中、退出批量态。
    private func czfDeleteBatchSelected() {
        for url in czfSelectedItems.map(\.url) {
            try? FileManager.default.removeItem(at: url)
        }
        czfShowBatchDeleteConfirm = false
        czfSelectedIDs.removeAll()
        czfBatchMode = false
        model.scan()
    }

    // 3.8.718（F-3）：删重复包——删前一刻再按当前 model.items
    // 重算（确认框弹着时详情可能还在加载、新重复可能刚被认出，
    // 以删时为准）；删完清掉已删项的批量选中、一次重扫。
    private func czfDeleteDuplicates() {
        let extras = czfDuplicateExtraGroups(items: model.items).flatMap { $0 }
        guard !extras.isEmpty else { return }
        for item in extras {
            try? FileManager.default.removeItem(at: item.url)
        }
        czfSelectedIDs.subtract(extras.map(\.id))
        model.scan()
    }

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
                VStack(alignment: .leading, spacing: 8) {
                    // 3.8.653（F1）：本地搜索框——放大镜 + 清除按钮（本批 UI 打磨）；
                    // 搜索只滤本格子，不动源列表（源搜索仍走顶栏 .searchable）。
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索文件名、显示名、版本号、Bundle ID", text: $czfSearchText)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            // 3.8.682（B1）：iOS 15 兜底收键盘——键盘工具条
                            // Done 按钮（MultitaskDockView 同款 resign
                            // 写法）；16+ 另有外层 ScrollView 的
                            // scrollDismissesKeyboard，两路都不吞格子点按。
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("完成") {
                                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    }
                                }
                            }
                        if !czfSearchText.isEmpty {
                            Button { czfSearchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    if czfDisplayedItems.isEmpty {
                        // 3.8.672（F-3）：筛空文案——筛选开着且搜索本身
                        // 有结果时，是“只看有新版”筛掉的，用 App 页
                        // 3.8.651 同款文案（0 新 key）；搜索本身没结果
                        // 时仍是“没有匹配的 IPA”。
                        Text(czfOnlyUpdatable && !czfFilteredItems.isEmpty ? "筛选条件下没有 App" : "没有匹配的 IPA")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: czfColCount), spacing: 12) {
                            ForEach(czfDisplayedItems) { item in
                                CZFLocalIpaGridCell(
                                    item: item,
                                    installedLookup: czfInstalledLookup,
                                    onShare: { czfShareURL = item.url },
                                    onDelete: { czfDeleteItem = item },
                                    onCopyFileName: { UIPasteboard.general.string = item.fileName },
                                    // 3.8.662（F2）：批量态——点格子改为勾选
                                    //（App 页 batchMode 行首勾选圈同款语义），
                                    // 平时点格子仍是安装；参数顺序与 cell 声明
                                    // 一致（onTap 必须留在最后）。
                                    czfBatchMode: czfBatchMode,
                                    czfIsSelected: czfSelectedIDs.contains(item.id),
                                    onTap: {
                                        if czfBatchMode {
                                            czfToggleSelection(item)
                                        } else {
                                            onInstall(item.url)
                                        }
                                    }
                                )
                                .onAppear { model.loadDetailIfNeeded(for: item) }
                            }
                        }
                    }
                    // 3.8.662（F2）：批量底栏——分享 / 安装 / 删除（计数是
                    // 实际匹配到的选中项，未选时禁用）+ 取消（退出
                    // 批量态并清选中）；只在批量态显示，搜索筛空时
                    // 也在（选中项可能在筛掉的那部分里）。
                    // 3.8.666（UI 打磨）：底栏按钮统一样式——bordered +
                    // small，纯样式，不动布局与逻辑。
                    if czfBatchMode {
                        HStack(spacing: 12) {
                            Button("分享 (\(czfSelectedItems.count))") {
                                czfBatchShareURLs = czfSelectedItems.map(\.url)
                            }
                            .disabled(czfSelectedItems.isEmpty)
                            Button("删除 (\(czfSelectedItems.count))", role: .destructive) {
                                czfShowBatchDeleteConfirm = true
                            }
                            .disabled(czfSelectedItems.isEmpty)
                            // 3.8.666（F-1）：批量安装——当场快照 URL 组再逐个
                            // 调 onInstall（单点格子同款：切 App 页 + 写共享
                            // 待装队列），排空、串行安装、失败汇总、完成通知
                            // 全复用现有安装队列，不新造队列；装完退出批量态
                            // 并清选中。快照当场取，别事后按 id 回查——安装
                            // 前一次 scan() 就能丢项。
                            Button("安装 (\(czfSelectedItems.count))") {
                                let urls = czfSelectedItems.map(\.url)
                                czfBatchMode = false
                                czfSelectedIDs.removeAll()
                                for url in urls {
                                    onInstall(url)
                                }
                            }
                            .disabled(czfSelectedItems.isEmpty)
                            // 3.8.664（F3）：全选/取消全选——文案沿用 App 页
                            // 硬编码中文（LCAppListView:2755 同款）。
                            Button(czfBatchAllSelected ? "取消全选" : "全选") {
                                czfToggleBatchSelectAll()
                            }
                            Spacer()
                            Button("取消") {
                                czfBatchMode = false
                                czfSelectedIDs.removeAll()
                            }
                        }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .onAppear { model.scan() }
        // 3.8.718（F-3）：详情每读回一批就重算重复组上报标题行
        //（变了才写绑定，不反复推同一份）；标题行确认清理后
        // 序号 +1，这里删文件并重扫。
        .onReceive(model.$items) { _ in
            let groups = czfDuplicateExtraGroups(items: model.items)
            if czfDupGroupIDs(groups) != czfDupGroupIDs(czfDupExtraGroups) {
                czfDupExtraGroups = groups
            }
        }
        .onChange(of: czfDupCleanupRequest) { _ in
            guard czfDupCleanupRequest > 0 else { return }
            czfDeleteDuplicates()
        }
        // 3.8.696（B3）：文件夹分段下拉刷新——源分段同款入口（源页
        // :1487 的 .refreshable）；model.scan() 是同步 void、后台开
        // Task 跑，指示器在闭包返回时即消失，不等到扫完（与源页
        // await refreshAllSources() 的指示器行为不同）；旧列表在扫
        // 期间仍可见（O-5 注释 :969 起），扫完整体替换。模型是
        // @MainActor，await 进去。
        .refreshable { await model.scan() }
        .onDisappear {
            model.cancelDetailTasks()
            // 3.8.662（B3）：节流任务也取消——睡醒后调
            // czfRequestAllDetails 时 detailsCancelled 已是真、
            // 方法内守卫会拦，但不留无用任务。
            czfSearchDetailTask?.cancel()
        }
        // 3.8.662（B3）：搜版本号时补推全部未读详情——搜索只比
        // 已解出的 version，没滚到的行 version 恒为 nil；输入停
        // 0.3 秒后调模型新方法，把全部未读详情一次推进队里
        //（复用 3 个一组后台管道 + 磁盘缓存，多数是缓存命中）。
        // 搜索框清空时不推（无查询不必解详情）。
        .onChange(of: czfSearchText) { _ in
            czfSearchDetailTask?.cancel()
            guard !czfSearchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            czfSearchDetailTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                model.czfRequestAllDetails()
            }
        }
        // 3.8.649（F1）：分享走系统分享表——分享的 URL 在内容闭包
        // 里当场抓住（CZFAppGridView:745 同款），不走 onDismiss 删文件。
        // 3.8.662（F2）：批量分享共用这一个 sheet——同一视图挂两个
        // .sheet 时只有一个会弹；批量优先（单项分享时批量组是空的）。
        .sheet(isPresented: Binding(get: { czfShareURL != nil || !czfBatchShareURLs.isEmpty }, set: { if !$0 { czfShareURL = nil; czfBatchShareURLs.removeAll() } })) {
            if !czfBatchShareURLs.isEmpty {
                ActivityViewController(activityItems: czfBatchShareURLs as [Any]) { _, _, _, _ in
                    czfBatchShareURLs.removeAll()
                }
            } else if let url = czfShareURL {
                ActivityViewController(activityItems: [url]) { _, _, _, _ in
                    czfShareURL = nil
                }
            }
        }
        // 3.8.649（F1）：删除是用户自选文件夹里的真实文件，必须带
        // 确认框；确认后删文件再重扫——删完地址集变了，O-5 短路
        // 不命中，走全扫，列表即时去掉已删的行。
        // 3.8.662（F2）：批量删除共用这一个 alert——同一视图挂两个
        // .alert 时只有一个会弹；标题保持“删除 IPA”，批量时 message
        // 里写个数（标题用插值要 LocalizedStringKey 拼串，免生事）。
        .alert("删除 IPA", isPresented: Binding(get: { czfDeleteItem != nil || czfShowBatchDeleteConfirm }, set: { if !$0 { czfDeleteItem = nil; czfShowBatchDeleteConfirm = false } })) {
            if czfShowBatchDeleteConfirm {
                Button("删除", role: .destructive) {
                    czfDeleteBatchSelected()
                }
                Button("取消", role: .cancel) { czfShowBatchDeleteConfirm = false }
            } else {
                Button("删除", role: .destructive) {
                    if let item = czfDeleteItem {
                        try? FileManager.default.removeItem(at: item.url)
                        czfDeleteItem = nil
                        model.scan()
                    }
                }
                Button("取消", role: .cancel) { czfDeleteItem = nil }
            }
        } message: {
            if czfShowBatchDeleteConfirm {
                Text("将删除选中的 \(czfSelectedItems.count) 个 IPA，文件会从文件夹中移除，此操作无法撤销。")
            } else {
                Text("将删除“\(czfDeleteItem?.fileName ?? "")”，文件会从文件夹中移除，此操作无法撤销。")
            }
        }
    }
}

// 一个 IPA 的格子（3.8.426）：源页同款——大图标 + 下方名字
// （两行）+ 版本/大小，点格子直接安装。图标没解出来之前
// 先显示占位，解出来那一行自己刷出来。
// 3.8.672（F-3）：文件夹 IPA 有新版判定——行级角标与列表
// 筛选共用这一份（口径与原来 cell 内 czfHasUpdate 一字相同，
// 只是从 cell 里抽出来）：短版本号比已装最旧实例新就标；源页
// 网格同款角标（CZFSourceGridView.hasUpdate）。已装实例取最旧
// 的（installedModel，3.8.649 B2），比版本走全局
// czfIsNewerVersion。3.8.668（B-2）：build 级比较——文件夹 IPA
// 的 build 从 extractIpaInfo 读 CFBundleVersion 进 item.build，
// 短版本号相等时按 build 比（同版高 build 也标）；build 读不到
// 按 0 比，与源页网格同口径。
// 3.8.718（F-3）：重复包分组——同 bundleIdentifier + version +
// build 一组，每组只留 modificationDate 最新的一份，其余是待删
// 的旧包；bundleIdentifier 为 nil/空的不参与分组（身份不明不删）；
// 只留一份的组不进结果，每组绝不删光。返回每组待删的旧包。
func czfDuplicateExtraGroups(items: [CZFLocalIpaItem]) -> [[CZFLocalIpaItem]] {
    var grouped: [String: [CZFLocalIpaItem]] = [:]
    for item in items {
        guard let bid = item.bundleIdentifier, !bid.isEmpty else { continue }
        let key = "\(bid)\n\(item.version ?? "")\n\(item.build ?? "")"
        grouped[key, default: []].append(item)
    }
    return grouped.values.compactMap { group in
        guard group.count > 1 else { return nil }
        let sorted = group.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        return Array(sorted.dropFirst())
    }
}

// 3.8.718（F-3）：重复组比对键——组内 id 排好序、组间按首 id
// 排好序，Dictionary 分组顺序不定也不误判“变了”。
private func czfDupGroupIDs(_ groups: [[CZFLocalIpaItem]]) -> [[UUID]] {
    groups.map { $0.map(\.id).sorted { $0.uuidString < $1.uuidString } }
        .sorted { ($0.first?.uuidString ?? "") < ($1.first?.uuidString ?? "") }
}

func czfFolderItemHasUpdate(item: CZFLocalIpaItem, installedLookup: CZFInstalledLookup) -> Bool {
    guard let version = item.version,
          let bid = item.bundleIdentifier, !bid.isEmpty,
          let installed = installedLookup.installedModel(bundleIdentifier: bid) else { return false }
    return czfIsNewerVersion(version, build: item.build, newerThan: installed.appInfo.version() ?? "", installedBuild: installed.appInfo.buildVersion())
}

struct CZFLocalIpaGridCell: View {
    let item: CZFLocalIpaItem
    // 3.8.604（O-18）：父级一次算好的已装查找表，格子只查表。
    let installedLookup: CZFInstalledLookup
    // 3.8.649（F1）：长按菜单回调——分享 / 删除 / 复制文件名，
    // 动作由父级格子持有（分享表与确认框的 state 在父级）。
    // 声明顺序注意：onTap 必须留在最后，调用点用 trailing
    // closure 传它（新闭包放它前面，否则 trailing closure
    // 会绑到最后一个新闭包上、编不过）。
    var onShare: () -> Void = {}
    var onDelete: () -> Void = {}
    var onCopyFileName: () -> Void = {}
    // 3.8.662（F2）：批量态——点格子改为勾选（父级 onTap 分支），
    // 格子左上角挂勾选圈（App 页 batchMode 行首勾选圈同款写法，
    // LCAppListView.swift:1560 起）；声明顺序注意：新项放
    // onTap 前面，onTap 必须留在最后（trailing closure 绑定）。
    var czfBatchMode = false
    var czfIsSelected = false
    var onTap: () -> Void

    // 3.8.444：已安装标记（用户 13:51 令“不知道哪个安装了
    // 哪个没安装”）——按包名比对已装 App（含隐藏 App），与源
    // 页绿勾（CZFSourceGridView）同款判据、同款绿勾位置。
    // 3.8.459 兼容审计：名字晕影按 colorScheme 换色（与 App 网格
    // CZFAppGridView:463、源格子 CZFSourceGridView:427 同款）——
    // 原来写死白晕影，深色模式下白字压在亮壁纸上没对比、读不清。
    @Environment(\.colorScheme) private var colorScheme
    private var czfIsInstalled: Bool {
        guard let bid = item.bundleIdentifier, !bid.isEmpty else { return false }
        return installedLookup.isInstalled(bundleIdentifier: bid)
    }

    // 3.8.660（F1）：文件夹 IPA 有新版——判定走文件级共用
    // czfFolderItemHasUpdate（列表筛选同一口径）。
    private var czfHasUpdate: Bool {
        czfFolderItemHasUpdate(item: item, installedLookup: installedLookup)
    }

    // 3.8.668（B-2/UI 打磨）：副标题版本行——有 build 时“版本 1.2 (123)”；
    // 无 build 时只显短版本号，样式不变。
    private var czfVersionText: String? {
        guard let v = item.version else { return nil }
        if let b = item.build, !b.isEmpty { return "版本 \(v) (\(b))" }
        return "版本 \(v)"
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
                if czfHasUpdate {
                    // 有新版角标（3.8.660 F1）——与源页网格同口径：
                    // 有更新就说明已装，红色下箭头代替绿勾（不叠两层）。
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundColor(.red)
                        .background(Color(.systemBackground).opacity(0.85), in: Circle())
                        .offset(x: 6, y: -6)
                } else if czfIsInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                        .background(Color(.systemBackground).opacity(0.85), in: Circle())
                        .offset(x: 6, y: -6)
                }
            }
            .overlay(alignment: .topLeading) {
                // 3.8.662（F2）：批量态勾选圈——左上角，与右上角
                // 的有新版/已装角标不叠；未选中是空圈、选中是实心。
                if czfBatchMode {
                    Image(systemName: czfIsSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(czfIsSelected ? .accentColor : .secondary)
                        .background(Color(.systemBackground).opacity(0.85), in: Circle())
                        .offset(x: -6, y: -6)
                }
            }
            Text(item.displayName)
                .font(.footnote)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.95) : .white.opacity(0.95), radius: 4, x: 0, y: 0)
            Text(czfDetailFailed ? "无法读取".loc : [czfVersionText, item.sizeText.isEmpty ? nil : item.sizeText].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // 3.8.649（F1）：长按菜单——分享 IPA / 复制文件名 / 删除。
        // 标题硬编码中文，沿用“复制 Bundle ID”同款先例；删除是
        // 真实文件，确认框在父级格子弹，这里只回调。
        // 3.8.666（B-alt 补门）：批量态下不给「删除」——批量勾选
        // 中长按删一个会触发 scan() 全量重建；id 已改稳定键
        // （主修法），这里再加一道门，批量态下的删除走底栏
        // 「删除 (n)」，不从单项菜单进。
        .contextMenu {
            Button("分享 IPA", systemImage: "square.and.arrow.up", action: onShare)
            Button("复制文件名", systemImage: "doc.on.doc", action: onCopyFileName)
            // 3.8.688（F3）：复制版本号 / 复制 Bundle ID——与 App 页
            // 长按菜单同款（3.8.639/647）与源页行同款（3.8.682 F2）；
            // 版本号读不到或为 "?" 时不显示，Bundle ID 为空时不显示；
            // 数据现成（item.version / item.bundleIdentifier，
            // extractIpaInfo 从 Info.plist 读），零新解析、零新 key。
            // 标题硬编码中文，沿用本菜单“复制文件名”先例。
            if let version = item.version, version != "?" {
                Button("复制版本号", systemImage: "doc.on.doc") {
                    // 3.8.704（B-1）：带 build，与副标题 czfVersionText
                    // 同款“版本 (build)”拼法；无 build 时保持原样。
                    if let czfBuild = item.build, !czfBuild.isEmpty {
                        UIPasteboard.general.string = "\(version) (\(czfBuild))"
                    } else {
                        UIPasteboard.general.string = version
                    }
                }
            }
            if let bundleID = item.bundleIdentifier, !bundleID.isEmpty {
                Button("复制 Bundle ID", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = bundleID
                }
            }
            if !czfBatchMode {
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
    }
}

// 3.8.682（B1）：iOS 16+ 滚即收键盘——scrollDismissesKeyboard 是
// 16+ API，extension 内用 #available 分支，调用方不用写两遍
// ScrollView；iOS 15 走搜索框键盘工具条 Done 按钮（见格子内
// TextField 的 .toolbar），两路都不吞格子点按。
extension View {
    @ViewBuilder
    func czfScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
    }
}
