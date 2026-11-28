//  CZFPinnedAppsWidget.swift
//  WidgetExtension
//
//  3.8.722（F-3）：桌面小组件——显示用户置顶的 App（图标+名字），
//  点图标即在 Live 内启动对应客 App。
//  数据源：主 App 写的 App Group 快照（CZFWidgetSnapshot：
//  CZFWidgetPinnedApps.json + CZFWidgetIcons/*.png）；小组件
//  不读主 App 沙盒、不调主 App 的类、不扫客 App 包。启动深链
//  复用现成 livecontainer://livecontainer-launch?bundle-name=…
//  &container-folder-name=…（接收处理在 LCAppListView:6532）。
//  App Group 发现复用 LCSharedUtils.appGroupPath（ShareExtension
//  同款桥接，扩展进程里 team 拿不到的兜底都在里面）。
//  快照 Entry 与 CZFWidgetSnapshot.Entry 同款 Codable（两边各一份，
//  小组件 target 不依赖主 App target）。

import SwiftUI
import WidgetKit

/// 快照里的一个置顶 App（字段与主 App 侧 CZFWidgetSnapshot.Entry 一一对应）。
struct CZFWidgetPinnedEntry: Codable {
    var key: String
    var displayName: String
    var relativeBundlePath: String
    var folderName: String
    var iconFileName: String
}

/// 小组件内一个 App 的渲染模型（快照项 + 读到的图标 + 拼好的深链）。
struct CZFWidgetApp: Identifiable {
    var id: String { entry.key }
    var entry: CZFWidgetPinnedEntry
    var icon: UIImage?
    var launchURL: URL?
}

struct CZFWidgetTimelineEntry: TimelineEntry {
    var date: Date
    var apps: [CZFWidgetApp]
}

struct CZFWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CZFWidgetTimelineEntry {
        CZFWidgetTimelineEntry(date: Date(), apps: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (CZFWidgetTimelineEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CZFWidgetTimelineEntry>) -> Void) {
        let entry = loadEntry()
        // 快照由主 App 固定/进 App 页时写盘并调 WidgetCenter 刷新；
        // 这里再给 30 分钟兜底轮询，兜住主 App 侧刷新没触发的情况。
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> CZFWidgetTimelineEntry {
        guard let groupURL = LCSharedUtils.appGroupPath() else {
            return CZFWidgetTimelineEntry(date: Date(), apps: [])
        }
        let file = groupURL.appendingPathComponent("CZFWidgetPinnedApps.json")
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([CZFWidgetPinnedEntry].self, from: data) else {
            return CZFWidgetTimelineEntry(date: Date(), apps: [])
        }
        let iconsDir = groupURL.appendingPathComponent("CZFWidgetIcons", isDirectory: true)
        let apps = decoded.map { item -> CZFWidgetApp in
            var image: UIImage?
            if !item.iconFileName.isEmpty {
                image = UIImage(contentsOfFile: iconsDir.appendingPathComponent(item.iconFileName).path)
            }
            return CZFWidgetApp(entry: item, icon: image, launchURL: Self.launchURL(for: item))
        }
        return CZFWidgetTimelineEntry(date: Date(), apps: apps)
    }

    /// 深链拼法与 CZFAppGridView.czfCopyLaunchURL 同款：bundle-name
    /// 是相对包路径，container-folder-name 是容器文件夹名；值里
    /// 带 &（如 H&M.app）时接收侧会从 & 处切断，用
    /// czfQueryValueAllowed（排除 &，见 Shared.swift L60-1）编码。
    private static func launchURL(for item: CZFWidgetPinnedEntry) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&")
        guard let bundle = item.relativeBundlePath.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var str = "livecontainer://livecontainer-launch?bundle-name=\(bundle)"
        if !item.folderName.isEmpty,
           let folder = item.folderName.addingPercentEncoding(withAllowedCharacters: allowed) {
            str += "&container-folder-name=\(folder)"
        }
        return URL(string: str)
    }
}

struct CZFPinnedAppsWidgetView: View {
    var entry: CZFWidgetTimelineEntry
    @Environment(\.widgetFamily) var family

    // 小号 4 个、中号 8 个、大号 12 个：再多排不下；超量在网格
    // 末尾补一块“+N” tile（B-3），不再静默截掉。
    private var visibleApps: [CZFWidgetApp] {
        Array(entry.apps.prefix(family == .systemSmall ? 4 : family == .systemLarge ? 12 : 8))
    }

    /// 超出 visibleApps 的个数；>0 时网格末尾补“+N” tile。
    private var czfOverflowCount: Int {
        max(0, entry.apps.count - visibleApps.count)
    }

    /// 小尺寸放不下第 5 块 tile：有超量时只排 3 个 App，末尾
    /// 一块留给“+N”，仍是 2×2 不溢出；中/大号 tile 数不变。
    private var czfGridApps: [CZFWidgetApp] {
        if family == .systemSmall, czfOverflowCount > 0 {
            return Array(visibleApps.prefix(3))
        }
        return visibleApps
    }

    var body: some View {
        if entry.apps.isEmpty {
            Text("在 Live 内固定 App 后，这里显示一键启动")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else if family == .systemSmall {
            czfSmallGrid
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 12)], spacing: 12) {
                ForEach(czfGridApps) { app in
                    czfAppTile(app, iconSize: 56)
                }
                if czfOverflowCount > 0 {
                    czfOverflowTile(size: 56)
                }
            }
            .padding()
        }
    }

    /// 小尺寸 2×2 紧凑格（F-2）：图标 40 + 名字一行，padding 8、
    /// 间距 8——两行约 138pt，小组件 155pt 内不溢出。
    @ViewBuilder
    private var czfSmallGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(czfGridApps) { app in
                czfAppTile(app, iconSize: 40)
            }
            if czfOverflowCount > 0 {
                czfOverflowTile(size: 40)
            }
        }
        .padding(8)
    }

    /// 一个 App 的 tile（中/大/小号共用，只差图标尺寸）。
    @ViewBuilder
    private func czfAppTile(_ app: CZFWidgetApp, iconSize: CGFloat) -> some View {
        if let url = app.launchURL {
            Link(destination: url) {
                VStack(spacing: 4) {
                    czfIcon(for: app, size: iconSize)
                    Text(app.entry.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(spacing: 4) {
                czfIcon(for: app, size: iconSize)
                Text(app.entry.displayName)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }

    /// “+N” tile（B-3）：点开 Live App 页——走现成
    /// livecontainer-launch?bundle-name=ui（只打开界面、
    /// 不启动 App，App 页 handleURL 的约定），不新造深链；
    /// 路由：LCTabView.dispatchURL 切 .apps。
    @ViewBuilder
    private func czfOverflowTile(size: CGFloat) -> some View {
        if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=ui") {
            Link(destination: url) {
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13)
                            .fill(Color.secondary.opacity(0.25))
                        Text("+\(czfOverflowCount)")
                            .font(.title3.bold())
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: size, height: size)
                    Text("更多")
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func czfIcon(for app: CZFWidgetApp, size: CGFloat = 56) -> some View {
        if let icon = app.icon {
            Image(uiImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 13))
        } else {
            // 无缓存图标时首字母占位（主 App 侧只读缓存、不生成；
            // 用户逛一次 App 页生成图标写盘后，下次同步即有图）。
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.secondary.opacity(0.25))
                Text(String(app.entry.displayName.prefix(1)))
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        }
    }
}

struct CZFPinnedAppsWidget: Widget {
    let kind: String = "CZFPinnedAppsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CZFWidgetProvider()) { entry in
            CZFPinnedAppsWidgetView(entry: entry)
        }
        .configurationDisplayName("置顶 App")
        .description("一点即在 Live 内启动置顶的 App")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct CZFPinnedAppsWidgetBundle: WidgetBundle {
    var body: some Widget {
        CZFPinnedAppsWidget()
        // 3.8.732（F-3）：第二种小组件——签名快到期，kind 与置顶的不同。
        CZFExpiryWidget()
    }
}
