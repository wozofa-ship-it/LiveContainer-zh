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
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(items, id: \.id) { item in
                CZFSourceGridGroupView(
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
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(item.source?.name ?? item.displayName)
                        .font(.system(.title2).bold())
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
struct CZFSourceGridGroupView: View {
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
        VStack(alignment: .leading, spacing: 12) {
            czfGroupHeader

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
                CZFSourceGridErrorView(error: error, onRefresh: onRefresh)
            } else if let source = item.source {
                if apps.isEmpty {
                    Text("lc.sources.section.noApps".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
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

    private var czfGroupHeader: some View {
        CZFSourceGridGroupHeaderView(
            item: item,
            apps: apps,
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
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(app.name)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        // 板色（3.8.416）：格子加 AppBannerBG 浅蓝卡片底，与 App
        // 列表行（LCAppBannerView）同款色——之前格子是白底无卡片，
        // 跟 App 页颜色对不上（用户 17:16 报）。圆角 16（图标
        // 圆角 14，卡片稍大一圈）。
        .background(Color("AppBannerBG"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
