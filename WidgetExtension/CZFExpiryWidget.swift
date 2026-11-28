//  CZFExpiryWidget.swift
//  WidgetExtension
//
//  3.8.732（F-3）：桌面小组件第二种——签名快到期：显示最快到期
//  的 4 个签名（名字 + 到期日 + 剩余天数）。
//  数据源：主 App 写的 App Group 快照（CZFWidgetSnapshot.syncExpiry：
//  CZFWidgetExpiry.json）；小组件不读主 App 沙盒、不调主 App 的类、
//  不扫 mobileprovision。快照 Entry 与主 App 侧
//  CZFWidgetSnapshot.ExpiryEntry 同款 Codable（两边各一份，
//  小组件 target 不依赖主 App target）。
//  label 分支是 CZFSignatureExpiry.label(forDaysLeft:) 的复制
//  （主 App target 内，扩展读不到；置顶 widget :17-19 同款模式）。

import SwiftUI
import WidgetKit

/// 快照里的一个快到期签名（字段与主 App 侧 CZFWidgetSnapshot.ExpiryEntry 一一对应）。
struct CZFWidgetExpiryEntry: Codable {
    var name: String
    var daysLeft: Int
    var dateText: String
}

struct CZFExpiryWidgetTimelineEntry: TimelineEntry {
    var date: Date
    var items: [CZFWidgetExpiryEntry]
}

struct CZFExpiryWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CZFExpiryWidgetTimelineEntry {
        CZFExpiryWidgetTimelineEntry(date: Date(), items: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (CZFExpiryWidgetTimelineEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CZFExpiryWidgetTimelineEntry>) -> Void) {
        let entry = loadEntry()
        // 快照由主 App 刷新签名天数时写盘并调 WidgetCenter 刷新；
        // 这里再给 30 分钟兜底轮询，兜住主 App 侧刷新没触发的情况
        //（置顶 widget :62-66 同款）。
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> CZFExpiryWidgetTimelineEntry {
        guard let groupURL = LCSharedUtils.appGroupPath() else {
            return CZFExpiryWidgetTimelineEntry(date: Date(), items: [])
        }
        let file = groupURL.appendingPathComponent("CZFWidgetExpiry.json")
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([CZFWidgetExpiryEntry].self, from: data) else {
            return CZFExpiryWidgetTimelineEntry(date: Date(), items: [])
        }
        return CZFExpiryWidgetTimelineEntry(date: Date(), items: decoded)
    }
}

struct CZFExpiryWidgetView: View {
    var entry: CZFExpiryWidgetTimelineEntry

    /// 剩余天数文案——CZFSignatureExpiry.label(forDaysLeft:) 的
    /// 复制（主 App target 内，扩展读不到；两边各一份同款）。
    private static func label(forDaysLeft daysLeft: Int) -> String {
        if daysLeft < 0 { return "已过期 \(-daysLeft) 天" }
        if daysLeft == 0 { return "今天到期" }
        return "剩 \(daysLeft) 天"
    }

    /// 剩余天数颜色：已过期红、当天到期橙、其余次要色。
    private static func color(forDaysLeft daysLeft: Int) -> Color {
        if daysLeft < 0 { return .red }
        if daysLeft == 0 { return .orange }
        return .secondary
    }

    var body: some View {
        if entry.items.isEmpty {
            // 无到期信息时显示空态文案，不 crash（置顶 widget :156-161 同款）。
            Text("暂无快到期签名")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("签名快到期")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 同名分身会重名（同一 App 两队各签一份），不用 name
                // 当 id，用下标当 id。
                ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.dateText) · \(Self.label(forDaysLeft: item.daysLeft))")
                            .font(.caption)
                            .foregroundStyle(Self.color(forDaysLeft: item.daysLeft))
                    }
                }
            }
            .padding()
        }
    }
}

struct CZFExpiryWidget: Widget {
    let kind: String = "CZFExpiryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CZFExpiryWidgetProvider()) { entry in
            CZFExpiryWidgetView(entry: entry)
        }
        .configurationDisplayName("签名快到期")
        .description("最快到期的 4 个签名，一眼看到剩余天数")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
