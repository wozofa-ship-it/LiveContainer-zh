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
    var onToggleSelect: (AltStoreSourceApp) -> Void

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

    var body: some View {
        // 3.8.416：连续网格已撤回——.gridCellColumns 通栏组头
        // 仍会在组尾留空位（组头占 5 列、塞不进上一组剩的 1 格，
        // 只能换行，空位还在），消不掉组尾空位，反而多一路
        // iOS 16+ 分支、徒增风险。组尾空位是分组网格的固有
        // 形态（每组单独 LazyVGrid），与 App 资源库同款，不再
        // 强行连续化。组头已抽成 CZFSourceGridGroupHeaderView
        // 独立结构（两路共用，无行为变化），留着。
        //
        // 组头钉住已撤回（3.8.424，用户 22:19 视频报“源网格
        // 还是有 bug，好多图标显示不全”）：421 把组头钉住置顶
        // （pinnedViews），组头钉在顶上不动，格子往上滑就从
        // 组头下面过、图标被组头盖住一半（视频里第一行图标
        // 全程只露一半/全被盖掉）。钉住和图标露全不可兼得，
        // 图标露全优先，组头改回跟着内容一起滑走，不再钉住。
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(items, id: \.id) { item in
                Section {
                    CZFSourceGridGroupContentView(
                        item: item,
                        apps: filteredApps(item),
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
                } header: {
                    CZFSourceGridGroupHeaderView(
                        item: item,
                        apps: filteredApps(item),
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
                    .background(.ultraThinMaterial)
                }
            }
        }
    }
}

// 一个源的组头（标题推入源详情页）：独立出来，供连续网格
// （iOS 16+ 单 LazyVGrid，组头通栏）与分组网格（iOS 15
// 回落）两路共用。样式照抄 AltStoreSourceSectionView。
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
    let onToggleSelect: (AltStoreSourceApp) -> Void

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
                }
            }
        }
    }
}

// 一个源的组：组头（标题推入源详情页）+ 该源 App 的网格 / 空态 /
// 错误块 / 加载态。组头样式照抄 AltStoreSourceSectionView。
// 一组的内容（错误/空提示/App 网格/加载中）：从
// CZFSourceGridGroupView 里抽出来，供 Section 的 content 用；
// 组头另走 CZFSourceGridGroupHeaderView（Section header，钉住置顶）。
// 3.8.421 前的 CZFSourceGridGroupView（组头+内容合一个 VStack）
// 已随 Section 化删掉，只剩这一处用。
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
    let onToggleSelect: (AltStoreSourceApp) -> Void

    var body: some View {
        // 组头瘦身（3.8.419，建议第 4 条）：副标题/host 行删掉，
        // 收到详情页里（CZFSourceDetailView 本来就显示 subtitle），
        // 组头只剩标题一行，少占地方。
        Group {
            if let error = item.error {
                CZFSourceGridErrorView(error: error, onRefresh: onRefresh)
            } else if let source = item.source {
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
                                isSelected: selectedIDs.contains(app.bundleIdentifier),
                                onToggleSelect: { onToggleSelect(app) },
                                onInstall: onInstall,
                                onInstallAsNew: onInstallAsNew,
                                onDownload: onDownload,
                                onDownloadVersion: onDownloadVersion
                            )
                        }
                    }
                }
            } else if item.isLoading {
                ProgressView("lc.sources.loading".loc)
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

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let side = max(geo.size.width * iconFactor, 44)
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
                // （minimumScaleFactor 0.7），“闲鱼_7.28.50_...”
                // 这类超长名缩到两行内显示全，不再截断成“去...”；
                // 白晕影加粗（opacity 0.85→0.95、radius 3→4），
                // 黑字压在黑佛像上也能读。与 App 格子同款。
                .font(.footnote)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                .shadow(color: .white.opacity(0.95), radius: 4, x: 0, y: 0)
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
        .overlay(alignment: .topTrailing) {
            if isBatchMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .background(Color(.systemBackground).opacity(0.85), in: Circle())
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
    let onToggleSelect: (AltStoreSourceApp) -> Void

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

                if let error = item.error {
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
                } else if let source = item.source {
                    CZFSourceAppListView(
                        source: source,
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
                } else if item.isLoading {
                    ProgressView("lc.sources.loading".loc)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(item.source?.name ?? item.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
