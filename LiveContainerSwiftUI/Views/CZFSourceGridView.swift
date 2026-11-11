//  CZFSourceGridView.swift
//  LiveContainerSwiftUI
//
//  源页网格模式（3.8.407）：LazyVGrid 大图标 + 源名，点格子
//  推入源详情页（复用 CZFSourceAppListView / LCSourceAppBanner）；
//  列数/图标大小复用 App 页同一套 @AppStorage 键。长按菜单与
//  section 头部 Menu 同款（刷新 / 复制源链接 / 删除源）。

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
        LazyVGrid(columns: czfGridColumns, spacing: 16) {
            ForEach(items, id: \.id) { item in
                NavigationLink {
                    CZFSourceDetailView(
                        item: item,
                        filteredApps: filteredApps(item),
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
                } label: {
                    CZFSourceGridCell(item: item, iconFactor: czfIconFactor)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise") {
                        onRefresh(item)
                    }
                    Button("复制源链接", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = item.url.absoluteString
                    }
                    Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive) {
                        onRemove(item)
                    }
                }
            }
        }
    }
}

// 网格单元：大图标 + 下方单行源名。图标取法照抄 section 头部
//（SourceIconView + primaryIconURL，没图时自带 DefaultIcon 占位）。
struct CZFSourceGridCell: View {
    let item: AltStoreSourcesViewModel.SourceItem
    var iconFactor: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let side = max(geo.size.width * iconFactor, 44)
                SourceIconView(url: item.primaryIconURL)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(item.source?.name ?? item.displayName)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }
}

// 源详情页（网格点格子推入）：头部（图标 + 源名 + 刷新/复制/
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
