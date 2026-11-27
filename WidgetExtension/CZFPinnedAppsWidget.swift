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

    // 中号 8 个、大号 12 个：再多排不下，小组件只截不断行。
    private var visibleApps: [CZFWidgetApp] {
        Array(entry.apps.prefix(family == .systemLarge ? 12 : 8))
    }

    var body: some View {
        if entry.apps.isEmpty {
            Text("在 Live 内固定 App 后，这里显示一键启动")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 12)], spacing: 12) {
                ForEach(visibleApps) { app in
                    if let url = app.launchURL {
                        Link(destination: url) {
                            VStack(spacing: 4) {
                                czfIcon(for: app)
                                Text(app.entry.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        VStack(spacing: 4) {
                            czfIcon(for: app)
                            Text(app.entry.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func czfIcon(for app: CZFWidgetApp) -> some View {
        if let icon = app.icon {
            Image(uiImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
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
            .frame(width: 56, height: 56)
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
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct CZFPinnedAppsWidgetBundle: WidgetBundle {
    var body: some Widget {
        CZFPinnedAppsWidget()
    }
}
