// 本地 IPA 文件夹（3.8.423，用户 21:49 令）：+ 号旁边加一个
// 文件夹按钮，选一个本地文件夹，读出里面的 IPA，显示名字
// 和图标，点一下就安装。文件夹用 security-scoped bookmark
// 记住，下次点按钮直接打开，不用重新选。
import SwiftUI

struct CZFLocalIpaItem: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    var displayName: String
    var version: String?
    var sizeText: String
    var icon: UIImage?
    var detailLoaded = false
}

@MainActor
final class CZFLocalIpaFolderModel: ObservableObject {
    @Published var items: [CZFLocalIpaItem] = []
    @Published var scanning = true
    @Published var errorText: String?

    let folderURL: URL
    private var didStartAccessing = false
    // 详情解包任务（安装审计 #5 / App #15）：分块任务组限流
    // 3 个并发；弹窗关闭时 cancelDetailTasks() 取消它。
    private var detailTask: Task<Void, Never>?
    // 弹窗已关/已取消刷新时为真：在后台解包跑完回主线程前
    // 再拦一道，拦住已失效的旧解包刷进新列表。
    private var detailsCancelled = false

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
    // detailsCancelled 拦住，不再刷进列表。
    func cancelDetailTasks() {
        detailsCancelled = true
        detailTask?.cancel()
        detailTask = nil
    }

    func scan() {
        cancelDetailTasks()
        detailsCancelled = false
        scanning = true
        errorText = nil
        items = []
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
            // 名字和图标逐个在后台解包读，读好一行刷一行；
            // 文件名先顶着，不用等全部解完才显示列表。
            detailTask = Task { await loadAllDetails() }
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

    // 详情解包限流 3 个并发（安装审计 #5 / App #15）：
    // 抄 LCAltStoreSourcesView.refreshAllSources 的分块任务组
    // 写法，每 3 个一组并行解包，组间顺序等；100 个 IPA
    // 不再是 100 个并发解压。取消时组内未开始的解包不再
    // 启动（Task.isCancelled 守卫），在途的解包由
    // loadDetails 里的 detailsCancelled 拦住不刷表。
    // 全部读完后按显示名重排一次（App #28）。
    private func loadAllDetails() async {
        var start = 0
        while start < items.count {
            if Task.isCancelled { return }
            let chunk = Array(items[start..<min(start + 3, items.count)])
            await withTaskGroup(of: Void.self) { group in
                for item in chunk {
                    group.addTask {
                        await Task.detached { await self.loadDetails(for: item) }.value
                    }
                }
            }
            start += 3
        }
        if Task.isCancelled { return }
        sortItemsByDisplayName()
    }

    // 详情读完后按显示名重排一次（App #28）：格子里显示的
    // 是 Info.plist 真名，按文件名排看着乱。显示名缺失时
    // 回落文件名（建 items 时 displayName 已预填文件名）。
    // 本函数跑在主线程（detailTask 继承 MainActor），直接
    // 改 items，不在解包任务里改数组。
    private func sortItemsByDisplayName() {
        items.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // 解包是同步重活，不许占主线程：nonisolated，在后台
    // 跑完再回主线程刷那一行。直接在 @MainActor 里调 extract
    // 会卡住列表滚动。
    nonisolated private func loadDetails(for item: CZFLocalIpaItem) async {
        let info = Self.extractIpaInfo(url: item.url)
        await MainActor.run {
            guard !self.detailsCancelled else { return }
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                if let name = info.name { self.items[idx].displayName = name }
                if let version = info.version { self.items[idx].version = version }
                if let icon = info.icon { self.items[idx].icon = icon }
                self.items[idx].detailLoaded = true
            }
        }
    }

    nonisolated private static func extractIpaInfo(url: URL) -> (name: String?, version: String?, icon: UIImage?) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("CZFIpaFolder-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        guard extract(url.path, tmp.path, progress) == 0 else { return (nil, nil, nil) }
        let payload = tmp.appendingPathComponent("Payload")
        guard let contents = try? fm.contentsOfDirectory(atPath: payload.path),
              let appName = contents.first(where: { $0.hasSuffix(".app") }) else { return (nil, nil, nil) }
        let appDir = payload.appendingPathComponent(appName)
        guard let data = try? Data(contentsOf: appDir.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return (nil, nil, nil) }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        let version = plist["CFBundleShortVersionString"] as? String
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
            for suffix in ["@3x.png", "@2x.png", ".png"] {
                let path = appDir.appendingPathComponent(base + suffix).path
                if let img = UIImage(contentsOfFile: path) {
                    icon = img
                    break outer
                }
            }
        }
        return (name, version, icon)
    }
}

struct CZFLocalIpaFolderView: View {
    @StateObject private var model: CZFLocalIpaFolderModel
    var onInstall: (URL) -> Void
    var onChangeFolder: () -> Void
    var onClose: () -> Void

    init(folderURL: URL, onInstall: @escaping (URL) -> Void, onChangeFolder: @escaping () -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CZFLocalIpaFolderModel(folderURL: folderURL))
        self.onInstall = onInstall
        self.onChangeFolder = onChangeFolder
        self.onClose = onClose
    }

    // 4 列网格（3.8.426）：弹窗比整页窄，4 列比源页默认 5 列
    // 松一点，图标大、名字看得清。
    private var czfGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
    }

    var body: some View {
        NavigationView {
            Group {
                if model.scanning {
                    ProgressView("正在读取文件夹…")
                } else if let errorText = model.errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(errorText)
                            .foregroundStyle(.secondary)
                    }
                } else if model.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("这个文件夹里没有 IPA（已扫过子文件夹）")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // 网格（3.8.426，用户 23:00 令“弹出页面跟源
                    // 一样”）：列表改成源页同款网格——大图标 +
                    // 名字 + 版本，4 列，点格子直接安装。不再
                    // 用 List 行（行里名字版本号挤、图标小，
                    // 看着不像源页）。
                    ScrollView {
                        LazyVGrid(columns: czfGridColumns, spacing: 16) {
                            ForEach(model.items) { item in
                                CZFLocalIpaGridCell(item: item) {
                                    onInstall(item.url)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle(model.folderURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    // 安装审计 #18 / App #18：刷新按钮，与
                    // “换文件夹”并排；扫描中置灰防重复点。
                    Button(action: { model.scan() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")
                    .disabled(model.scanning)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("换文件夹", action: onChangeFolder)
                }
            }
            .onAppear { model.scan() }
            .onDisappear { model.cancelDetailTasks() }
        }
    }
}

// 一个 IPA 的格子（3.8.426）：源页同款——大图标 + 下方名字
// （两行）+ 版本/大小，点格子直接安装。图标没解出来之前
// 先显示占位，解出来那一行自己刷出来。
struct CZFLocalIpaGridCell: View {
    let item: CZFLocalIpaItem
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let side = max(geo.size.width, 44)
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
            Text(item.displayName)
                .font(.footnote)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                .shadow(color: .white.opacity(0.95), radius: 4, x: 0, y: 0)
            Text([item.version.map { "版本 \($0)" }, item.sizeText.isEmpty ? nil : item.sizeText].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
