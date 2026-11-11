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

    init(folderURL: URL) {
        self.folderURL = folderURL
    }

    deinit {
        if didStartAccessing {
            folderURL.stopAccessingSecurityScopedResource()
        }
    }

    func scan() {
        scanning = true
        errorText = nil
        items = []
        Task {
            didStartAccessing = folderURL.startAccessingSecurityScopedResource()
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                errorText = "打不开这个文件夹"
                scanning = false
                return
            }
            let ipaURLs = urls.filter {
                $0.pathExtension.lowercased() == "ipa"
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            items = ipaURLs.map { url in
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
            for item in items {
                Task.detached { await self.loadDetails(for: item) }
            }
        }
    }

    // 解包是同步重活，不许占主线程：nonisolated，在后台
    // 跑完再回主线程刷那一行。直接在 @MainActor 里调 extract
    // 会卡住列表滚动。
    nonisolated private func loadDetails(for item: CZFLocalIpaItem) async {
        let info = Self.extractIpaInfo(url: item.url)
        await MainActor.run {
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
                        Text("这个文件夹里没有 IPA")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List(model.items) { item in
                        Button {
                            onInstall(item.url)
                        } label: {
                            HStack(spacing: 12) {
                                if let icon = item.icon {
                                    IconImageView(icon: icon)
                                        .frame(width: 48, height: 48)
                                } else {
                                    Image(systemName: "app.badge")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, height: 48)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                        .lineLimit(1)
                                    Text([item.version.map { "版本 \($0)" }, item.sizeText.isEmpty ? nil : item.sizeText].compactMap { $0 }.joined(separator: " · "))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
                    Button("换文件夹", action: onChangeFolder)
                }
            }
            .onAppear { model.scan() }
        }
    }
}
