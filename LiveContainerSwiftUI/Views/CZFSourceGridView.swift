//  CZFSourceGridView.swift
//  LiveContainerSwiftUI
//
//  源页网格模式（3.8.409）：按源分组直接显示 App——每个源一个组，
//  组头照抄列表 section 头部样式（图标 36 + 源名 + 刷新/复制/
//  删除 Menu），标题点进源详情页；组头下面是该源 App 的 LazyVGrid。
//  点 App 格子打开应用详情 sheet（与列表点行一致），安装/下载
//  走长按菜单和详情页里的按钮。列数/图标大小复用 App 页同一套
//  @AppStorage 键。

import SwiftUI
import UIKit

struct CZFSourceGridView: View {
    var items: [AltStoreSourcesViewModel.SourceItem]
    var columns: Int
    var iconSize: Int
    var filteredApps: (AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp]
    var isFiltering: Bool
    var onRefresh: (AltStoreSourcesViewModel.SourceItem) -> Void
    var onInstall: (AltStoreSourceApp) -> Void
    var onInstallAsNew: (AltStoreSourceApp) -> Void
    var onDownload: (AltStoreSourceApp) -> Void
    var onDownloadVersion: (URL) -> Void
    var onRemove: (AltStoreSourcesViewModel.SourceItem) -> Void
    var isBatchMode: Bool
    var selectedIDs: Set<String>
    // U10：勾选回调带源 feed URL——同一 App 在两个源里是两条
    // 记录，回调只给 app 时父视图分不清勾的是哪一个源的。
    var onToggleSelect: (URL, AltStoreSourceApp) -> Void

    private var czfGridColumns: [GridItem] {
        let count = max(3, min(6, columns))
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    // 图标尺寸：大/中/小 = 单元宽度的 1.0 / 0.85 / 0.7（App 页同款）。
    private var czfIconFactor: CGFloat {
        switch iconSize {
        case 1: return 0.85
        case 2: return 0.7
        default: return 1.0
        }
    }

    // 低 #11：filteredApps 每源每轮算一次存起来——原来组头调一次、
    // 组内容调一次，搜索时 czfVisibleItems 的过滤又调一次（每源
    // 3 遍）；改成一次 map 出 (item, apps)，三处共用。
    private var czfVisibleItems: [(item: AltStoreSourcesViewModel.SourceItem, apps: [AltStoreSourceApp])] {
        let computed = items.map { (item: $0, apps: filteredApps($0)) }
        guard isFiltering else { return computed }
        return computed.filter { !$0.apps.isEmpty }
    }

    var body: some View {
        // 3.8.429 组头丢了（用户 00:51 截图实证：428 整页只有
        // 底部一个“解剖自我”组头，其余组头全没了、App 混成
        // 一大片连续网格）：428 把 Section 换成每源 VStack，
        // 但外层仍是 LazyVStack——ScrollView > LazyVStack
        // （父）> CZFSourceGridView > LazyVStack（本层）> 每源
        // VStack > 组头 + LazyVGrid，嵌套懒栈。懒栈只按需
        // 布子视图，组头这种小视图在嵌套里高度算不准/丢了，
        // 只剩网格露出来；426 的 Section 版是组头横排一行的
        // 同款毛病。修法：外层改普通 VStack（非懒），全部
        // 组头立即定高排布，确定性布局；每组内容仍是 LazyVGrid
        // （格子懒加载还在，性能不丢）。组头跟着内容一起滑走，
        // 不钉住。
        VStack(alignment: .leading, spacing: 16) {
            ForEach(czfVisibleItems, id: \.item.id) { entry in
                let item = entry.item
                let apps = entry.apps
                VStack(alignment: .leading, spacing: 8) {
                    CZFSourceGridGroupHeaderView(
                        item: item,
                        apps: apps,
                        isFiltering: isFiltering,
                        onRefresh: { onRefresh(item) },
                        onInstall: onInstall,
                        onInstallAsNew: onInstallAsNew,
                        onDownload: onDownload,
                        onDownloadVersion: onDownloadVersion,
                        onRemove: { onRemove(item) },
                        isBatchMode: isBatchMode,
                        selectedIDs: selectedIDs,
                        onToggleSelect: onToggleSelect
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    CZFSourceGridGroupContentView(
                        item: item,
                        apps: apps,
                        isFiltering: isFiltering,
                        columns: czfGridColumns,
                        iconFactor: czfIconFactor,
                        onRefresh: { onRefresh(item) },
                        onInstall: onInstall,
                        onInstallAsNew: onInstallAsNew,
                        onDownload: onDownload,
                        onDownloadVersion: onDownloadVersion,
                        onRemove: { onRemove(item) },
                        isBatchMode: isBatchMode,
                        selectedIDs: selectedIDs,
                        onToggleSelect: onToggleSelect
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// 一个源的组头（标题推入源详情页）：独立出来，供每源 VStack
// （组头 + 内容）用。样式照抄 AltStoreSourceSectionView。
struct CZFSourceGridGroupHeaderView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let apps: [AltStoreSourceApp]
    let isFiltering: Bool
    let onRefresh: () -> Void
    let onInstall: (AltStoreSourceApp) -> Void
    let onInstallAsNew: (AltStoreSourceApp) -> Void
    let onDownload: (AltStoreSourceApp) -> Void
    let onDownloadVersion: (URL) -> Void
    let onRemove: () -> Void
    let isBatchMode: Bool
    let selectedIDs: Set<String>
    let onToggleSelect: (URL, AltStoreSourceApp) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink {
                CZFSourceDetailView(
                    item: item,
                    filteredApps: apps,
                    isFiltering: isFiltering,
                    onRefresh: onRefresh,
                    onInstall: onInstall,
                    onInstallAsNew: onInstallAsNew,
                    onDownload: onDownload,
                    onDownloadVersion: onDownloadVersion,
                    onRemove: onRemove,
                    isBatchMode: isBatchMode,
                    selectedIDs: selectedIDs,
                    onToggleSelect: onToggleSelect
                )
            } label: {
                HStack(spacing: 10) {
                    SourceIconView(url: item.primaryIconURL)
                        // 组头瘦身（3.8.419，建议第 4 条）：图标 36→28、
                        // 标题 title2→title3（小一号），组头少占地方。
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(item.source?.name ?? item.displayName)
                        .font(.system(.title3).bold())
                        // 低 #64：源名加 lineLimit(1)，超长源名截断、
                        // 不挤占右侧 Menu（超大字体下也不挤）。
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if item.isLoading {
                ProgressView()
            } else {
                Menu {
                    Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                    Button("复制源链接", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = item.url.absoluteString
                    }
                    Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                        .foregroundColor(.secondary)
                        // 低 #63：Menu label 补无障碍标签，VoiceOver
                        // 能读出“更多操作”。
                        .accessibilityLabel("更多操作")
                }
            }
        }
    }
}

// 一个源的组：组头（标题推入源详情页）+ 该源 App 的网格 / 空态 /
// 错误块 / 加载态。组头样式照抄 AltStoreSourceSectionView。
// 一组的内容（错误/空提示/App 网格/加载中）：3.8.428 起由
// CZFSourceGridView 的每源 VStack 直接拼组头 + 本视图，
// 不再走 Section（组头横排 bug，见 body 注释）。
struct CZFSourceGridGroupContentView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let apps: [AltStoreSourceApp]
    let isFiltering: Bool
    let columns: [GridItem]
    let iconFactor: CGFloat
    let onRefresh: () -> Void
    let onInstall: (AltStoreSourceApp) -> Void
    let onInstallAsNew: (AltStoreSourceApp) -> Void
    let onDownload: (AltStoreSourceApp) -> Void
    let onDownloadVersion: (URL) -> Void
    let onRemove: () -> Void
    let isBatchMode: Bool
    let selectedIDs: Set<String>
    let onToggleSelect: (URL, AltStoreSourceApp) -> Void

    var body: some View {
        // 组头瘦身（3.8.419，建议第 4 条）：副标题/host 行删掉，
        // 收到详情页里（CZFSourceDetailView 本来就显示 subtitle），
        // 组头只剩标题一行，少占地方。
        Group {
            // S1：有缓存 source 时先显示 App 网格，刷新失败只在
            // 网格上方贴一行小提示；无缓存时仍走下面的大错误块。
            if let source = item.source {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = item.error {
                        CZFSourceRefreshErrorRow(error: error, onRefresh: onRefresh)
                    }
                    if apps.isEmpty {
                        Text("lc.sources.section.noApps".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(apps, id: \.bundleIdentifier) { app in
                                CZFSourceAppGridCell(
                                    app: app,
                                    source: source,
                                    iconFactor: iconFactor,
                                    isBatchMode: isBatchMode,
                                    // U10：勾选键 = 源 feed URL + bundleIdentifier，
                                    // 同一 App 在两个源里不再两边同打勾。
                                    isSelected: selectedIDs.contains(czfSourceSelectionKey(sourceURL: item.url, bundleIdentifier: app.bundleIdentifier)),
                                    onToggleSelect: { onToggleSelect(item.url, app) },
                                    onInstall: onInstall,
                                    onInstallAsNew: onInstallAsNew,
                                    onDownload: onDownload,
                                    onDownloadVersion: onDownloadVersion
                                )
                            }
                        }
                    }
                }
            } else if let error = item.error {
                CZFSourceGridErrorView(error: error, onRefresh: onRefresh)
            } else if item.isLoading {
                ProgressView("lc.sources.loading".loc)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // 设置 #33：error 与 source 同时为 nil 且不在加载
                // 时（如加载结束无源无错），之前整个 Group 渲染
                // 为空、只剩组头；补空态文案。
                Text("lc.sources.section.noApps".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// 错误块：照抄列表 section 的错误块样式。
struct CZFSourceGridErrorView: View {
    let error: String
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("lc.sources.section.error".loc)
                .font(.subheadline)
                .bold()
            Text(error)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("lc.sources.refresh".loc, action: onRefresh)
                .font(.footnote)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(uiColor: UIColor.secondarySystemBackground))
        )
    }
}

// S1 刷新失败一行小提示（有缓存时用）：只占一行，不盖住已缓存
// 的 App 网格/列表；无缓存时仍走上面的 CZFSourceGridErrorView
// 大块。文案走现成 .loc key（lc.sources.section.error /
// lc.sources.refresh），无中文写死。
struct CZFSourceRefreshErrorRow: View {
    let error: String
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text("lc.sources.section.error".loc)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("lc.sources.refresh".loc, action: onRefresh)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// App 格子：大图标 + 下方单行 App 名，图标取法与 CZFAppGridCell
// 同款（GeometryReader + aspectRatio(1)，图标宽 = 单元宽 × 系数，
// 最小 44，圆角 14）。点格子：批量模式切勾选，非批量打开应用
// 详情 sheet（与列表点行一致）；长按菜单：安装 / 多开安装 /
// 下载 / 应用详情，历史版本下载在详情 sheet 的“版本信息”里。
struct CZFSourceAppGridCell: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    var iconFactor: CGFloat
    var isBatchMode: Bool
    var isSelected: Bool
    var onToggleSelect: () -> Void
    var onInstall: (AltStoreSourceApp) -> Void
    var onInstallAsNew: (AltStoreSourceApp) -> Void
    var onDownload: (AltStoreSourceApp) -> Void
    var onDownloadVersion: (URL) -> Void

    @State private var showDetail = false

    // 设置 #37：App 名晕影按 colorScheme 换色——浅色白晕影、
    // 深色黑晕影；原来写死白晕影，深色模式下白字 + 白晕影
    // 配浅色背景看不清。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                // U11：边长不小于 44，但不许超出单元格宽——屏宽
                // ≤375pt 时单元格不足 44pt，旧写法图标比格子宽、
                // 盖住相邻格子。iconFactor 逻辑不动。
                let side = min(max(geo.size.width * iconFactor, 44), geo.size.width)
                SourceIconView(url: app.iconURL)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // 图标淡底影（3.8.422，建议第 2 条）：很淡的一层黑影
                    // （opacity 0.15），只把图标从亮背景（天空/云）上托
                    // 出来一点；不是 418 撤掉的那种卡片底，别回去了。
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(app.name)
                // 名字（3.8.421，建议第 3、4 条）：长名字自动缩小
                // （minimumScaleFactor 0.7），最多显示两行，超长
                // 仍截断加省略号（.lineLimit(2)）；白晕影加粗
                // （opacity 0.85→0.95、radius 3→4），黑字压在
                // 黑佛像上也能读；深色模式用黑晕影（设置 #37）。
                // 与 App 格子同款。
                .font(.footnote)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.95) : .white.opacity(0.95), radius: 4, x: 0, y: 0)
        }
        // 去阴影（3.8.418）：格子上的 AppBannerBG 卡片底撤掉——
        // 416 加的卡片在白底上看着像一层阴影，用户 19:09 报
        // “源有阴影”。源页格子回扁平（裸图标 + 名字），与 App
        // 页格子一样，两页都无阴影。
        .contentShape(Rectangle())
        .onTapGesture {
            if isBatchMode {
                onToggleSelect()
            } else {
                showDetail = true
            }
        }
        // 低 #54：补双击进详情，与 App 格子“单击启动、双击进设置”
        // 的手势结构一致。双击与单击同动作（都开详情），不用
        // exclusively——单点不用等双击超时、立即开详情；双击时
        // 单点先触发一次、再触发双击，showDetail 置 true 幂等，
        // sheet 只开一次。批量模式下双击不做事（单点已勾选）。
        .onTapGesture(count: 2) {
            if !isBatchMode {
                showDetail = true
            }
        }
        // 低 #63：格子是 onTapGesture 触发，VoiceOver 能触发但无
        // 按钮 traits；补 .isButton（名字 Text 由 VoiceOver 读出）。
        .accessibilityAddTraits(.isButton)
        .overlay(alignment: .topTrailing) {
            if isBatchMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .background(Color(.systemBackground).opacity(0.85), in: Circle())
                    // 低 #55：勾选圈向外偏移，别压在图标一角。
                    .offset(x: 6, y: -6)
            }
        }
        .contextMenu {
            Button("lc.common.install".loc, systemImage: "square.and.arrow.down") {
                onInstall(app)
            }
            Button("新建", systemImage: "plus.square.on.square") {
                onInstallAsNew(app)
            }
            Button("lc.common.download".loc, systemImage: "arrow.down.circle") {
                onDownload(app)
            }
            Button("应用详情", systemImage: "info.circle") {
                showDetail = true
            }
        }
        .sheet(isPresented: $showDetail) {
            LCSourceAppDetailView(app: app, source: source, onDownloadVersion: onDownloadVersion)
        }
    }
}

// 源详情页（组头标题推入）：头部（图标 + 源名 + 刷新/复制/
// 删除 Menu）+ subtitle/host + 错误块 + App 列表，App 列表
// 复用 CZFSourceAppListView，与列表 section 展开后同一份。
struct CZFSourceDetailView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let filteredApps: [AltStoreSourceApp]
    let isFiltering: Bool
    let onRefresh: () -> Void
    let onInstall: (AltStoreSourceApp) -> Void
    let onInstallAsNew: (AltStoreSourceApp) -> Void
    let onDownload: (AltStoreSourceApp) -> Void
    let onDownloadVersion: (URL) -> Void
    let onRemove: () -> Void
    let isBatchMode: Bool
    let selectedIDs: Set<String>
    let onToggleSelect: (URL, AltStoreSourceApp) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    SourceIconView(url: item.primaryIconURL)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(item.source?.name ?? item.displayName)
                        .font(.system(.title2).bold())
                    Spacer()
                    if item.isLoading {
                        ProgressView()
                    } else {
                        Menu {
                            Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                            Button("复制源链接", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = item.url.absoluteString
                            }
                            Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .imageScale(.large)
                                .foregroundColor(.secondary)
                                // 低 #63：同组头，Menu label 补无障碍标签。
                                .accessibilityLabel("更多操作")
                        }
                    }
                }

                if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if item.source == nil, let host = item.url.host {
                    Text(host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // S1：有缓存 source 时先显示 App 列表，刷新失败只在
                // 列表上方贴一行小提示；无缓存时仍走下面的大错误块。
                if let source = item.source {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = item.error {
                            CZFSourceRefreshErrorRow(error: error, onRefresh: onRefresh)
                        }
                        CZFSourceAppListView(
                            source: source,
                            sourceURL: item.url,
                            filteredApps: filteredApps,
                            isFiltering: isFiltering,
                            onInstall: onInstall,
                            onInstallAsNew: onInstallAsNew,
                            onDownload: onDownload,
                            onDownloadVersion: onDownloadVersion,
                            isBatchMode: isBatchMode,
                            selectedIDs: selectedIDs,
                            onToggleSelect: onToggleSelect
                        )
                    }
                } else if let error = item.error {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("lc.sources.section.error".loc)
                            .font(.subheadline)
                            .bold()
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("lc.sources.refresh".loc, action: onRefresh)
                            .font(.footnote)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(uiColor: UIColor.secondarySystemBackground))
                    )
                } else if item.isLoading {
                    ProgressView("lc.sources.loading".loc)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // 设置 #33：同款缺口——error 与 source 同时为
                    // nil 且不在加载时，之前这里渲染为空；补空态文案。
                    Text("lc.sources.section.noApps".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(item.source?.name ?? item.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
