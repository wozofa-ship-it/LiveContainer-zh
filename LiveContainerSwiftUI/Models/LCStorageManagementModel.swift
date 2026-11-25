import Foundation
import Combine

struct LCAppStorageItem: Identifiable {
    let id: UUID

    let appModel: LCAppModel
    /// 3.8.557（L87）：显示名快照——排序在后台任务组里跑，原来
    /// 直接读 appModel.displayName（_info），离主线程读是 L70
    /// 同款；快照在主线程上取，见下面的 CZFStorageAppSnapshot。
    let displayName: String
    let bundleSize: Int64?
    let containersSize: Int64

    let totalSize: Int64

    let containerDetails: [LCAppStorageContainerItem]
}

struct LCAppStorageContainerItem: Identifiable {
    let id: UUID
    let name: String
    let size: Int64
    let isExternalContainer: Bool
    // 3.8.645（B3）：去重键——标准化后的容器 URL 路径。按 URL
    // 去重、不是按 folderName：私人树与共享树同名夹是两个容器
    //（LCAppSettingsView:1633 同款教训），只比 folderName 会把
    // 共享夹当成已有的私人夹。明细行不带它去重（每 App 各自仍
    // 显示自己用的容器大小），只在“容器”分类累加时用。
    let containerURL: URL
}

struct LCStorageBreakdown {
    let totalSize: Int64
    let appBundleSize: Int64
    let containersSize: Int64
    let temporaryFilesSize: Int64
    let appGroupSize: Int64
    let tweaksSize: Int64
    let otherSize: Int64

    let appItems: [LCAppStorageItem]
}

@MainActor
final class LCStorageManagementModel: ObservableObject {
    @Published var breakdown: LCStorageBreakdown?
    @Published var isCalculating = false
    @Published var errorInfo: String?
    // 3.8.643（B2）：本次快照是否把隐藏 App 的占用算进了“其他”——
    // 锁定时隐藏 App 不进快照、明细里没有它们，但包 + 容器仍在残差
    // 里（otherSize）；与快照同一时刻取值，免得解锁后数字与说明对不上。
    @Published var czfHiddenAppsInOther = false

    func refresh(apps: [LCAppModel], hiddenApps: [LCAppModel]) async {
        guard !isCalculating else {
            return
        }

        isCalculating = true
        defer { isCalculating = false }
        errorInfo = nil
        breakdown = nil
        // 3.8.643（B2）：与下面快照同一时刻取值（见 czfHiddenAppsInOther 注释）。
        czfHiddenAppsInOther = !DataManager.shared.model.isHiddenAppUnlocked && !hiddenApps.isEmpty

        // 3.8.557（L87）：快照在主线程上取——calculateBreakdown 是
        // nonisolated，后台任务组并发跑；直接读 isHiddenAppUnlocked /
        // uiContainers / 容器 @Published / displayName（_info）是 L70
        // 同款离主线程读，读-写并发可能崩；SideStore 那个现建模型
        // 的 init 也读二十多项 _info，不能在后台建（早先一轮只验
        // 了“calculateBreakdown 是 nonisolated 纯算数、不碰
        // @Published”，漏了这三处）。快照只含纯数据，model 仅供
        // UI 持有显示，计算不读它。
        let snapshots = Self.czfSnapshots(apps: apps, hiddenApps: hiddenApps)
        do {
            breakdown = try await Self.calculateBreakdown(snapshots: snapshots)
            // 3.8.645（F2）：存储页刷新时顺带填大小缓存（同一套快照
            // + 算法，不另算一遍）：下次选“按占用大小”直接按这次
            // 的数排，不用再后台逐个算。批量一次写，只触发一次重排。
            if let breakdown {
                var czfSizes: [String: Int64] = [:]
                for item in breakdown.appItems {
                    if let path = item.appModel.appInfo.bundlePath() {
                        czfSizes[path] = item.totalSize
                    }
                }
                CZFAppSizeCache.shared.setSizes(czfSizes)
            }
        } catch {
            errorInfo = error.localizedDescription
        }
    }

    // 3.8.557（L87）：存储统计快照（L73 CZFBackupAppSnapshot
    // 同款）——后台任务组只读这份纯数据，不碰 LCAppModel /
    // LCContainer 的 @Published 与 LCAppInfo 的 _info。
    private struct CZFStorageContainerSnapshot {
        let name: String
        let containerURL: URL
        let storageBookMark: Data?
        let bookmarkResolved: Bool
    }
    private struct CZFStorageAppSnapshot {
        let model: LCAppModel
        let containers: [CZFStorageContainerSnapshot]
        let bundlePath: String?
        let displayName: String
        let isSideStore: Bool
    }

    /// 3.8.637（A2）：单 App 总占用（包 + 容器），供 App 设置页只读显示。
    /// 复用存储管理页同一套快照 + 算法：快照在主线程取（读 _info /
    /// @Published，见上面 refresh 的 L87 注释），算大小放后台；
    /// 外置容器不计入（与 calculateAppItem 同款）。读盘失败回 0，
    /// 设置页只显示、不报错。
    static func czfTotalSize(for model: LCAppModel) async -> Int64 {
        let snapshot = czfSnapshot(for: model)
        guard let item = try? await calculateAppItem(from: snapshot) else { return 0 }
        return item.totalSize
    }

    private static func czfSnapshot(for model: LCAppModel) -> CZFStorageAppSnapshot {
        CZFStorageAppSnapshot(
            model: model,
            containers: model.uiContainers.map {
                CZFStorageContainerSnapshot(name: $0.name, containerURL: $0.containerURL, storageBookMark: $0.storageBookMark, bookmarkResolved: $0.bookmarkResolved)
            },
            bundlePath: model.appInfo.bundlePath(),
            displayName: model.displayName,
            isSideStore: model.appInfo is BuiltInSideStoreAppInfo
        )
    }

    private static func czfSnapshots(apps: [LCAppModel], hiddenApps: [LCAppModel]) -> [CZFStorageAppSnapshot] {
        var allApps = DataManager.shared.model.isHiddenAppUnlocked ? apps + hiddenApps : apps
        if UserDefaults.sideStoreExist() {
            // 现建模型也在主线程上建：init 读二十多项 _info，
            // 单例的 _info 主线程正读着（设置页/锁守卫），后台
            // 建就是读-写并发。
            allApps.append(LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared))
        }
        return allApps.map { czfSnapshot(for: $0) }
    }

    private enum StorageCategory {
        case appBundle
        case containers
        case temporaryFiles
        case appGroup
        case tweaks
    }

    nonisolated private static func calculateBreakdown(snapshots: [CZFStorageAppSnapshot]) async throws -> LCStorageBreakdown {
        let appItems = try await calculateAppItems(
            from: snapshots
        )

        var sizesByCategory: [StorageCategory: Int64] = [:]
        
        let knownRoots = uniquePaths([LCPath.docPath, LCPath.lcGroupDocPath])
        let bundleRoots = uniquePaths([LCPath.bundlePath, LCPath.lcGroupBundlePath])
        let containerRoots = uniquePaths([LCPath.dataPath, LCPath.lcGroupDataPath])
        let appGroupRoots = uniquePaths([LCPath.appGroupPath, LCPath.lcGroupAppGroupPath])
        let tweakRoots = uniquePaths([LCPath.tweakPath, LCPath.lcGroupTweakPath])
        
        
        sizesByCategory[.appBundle] = 0
        sizesByCategory[.containers] = 0
        
        var sideStoreContainerSize: Int64 = 0
        // 3.8.645（B3）：共用容器在“容器”分类里只算一次——两个
        // App 条目共用同一数据文件夹时（克隆条目未启动拆分前、
        // “选择已有容器”跨 App 挂同一个夹），同一文件夹在两个
        // appItem 里各算一次，分类虚高一份、“其他”被同等压低、
        // 为负时整行直接消失。按标准化后的容器 URL 去重（本文件
        // uniquePaths 同款键）；逐 App 明细行不动。
        var czfSeenContainerURLs = Set<String>()
        for appItem in appItems {
            if !(appItem.appModel.appInfo is BuiltInSideStoreAppInfo) {
                sizesByCategory[.appBundle]! += appItem.bundleSize ?? 0
            } else {
                sideStoreContainerSize = appItem.containersSize
            }

            for containerDetail in appItem.containerDetails {
                if containerDetail.isExternalContainer {
                    continue
                }
                let czfContainerKey = containerDetail.containerURL.standardizedFileURL.path
                guard czfSeenContainerURLs.insert(czfContainerKey).inserted else { continue }
                sizesByCategory[.containers]! += containerDetail.size
            }
        }

        try await withThrowingTaskGroup(of: (StorageCategory, Int64).self) { group in

            group.addTask(priority: .utility) {
                (.temporaryFiles, try await calculateSize(at: FileManager.default.temporaryDirectory))
            }

            group.addTask(priority: .utility) {
                (.appGroup, try await calculateCombinedSize(of: appGroupRoots))
            }

            group.addTask(priority: .utility) {
                // Surface tweaks as a top-level bucket so managed tweak storage does not disappear into Other.
                (.tweaks, try await calculateCombinedSize(of: tweakRoots))
            }

            for try await (category, size) in group {
                sizesByCategory[category] = size
            }
        }

        let appBundleSize = sizesByCategory[.appBundle] ?? 0
        let containersSize = sizesByCategory[.containers] ?? 0
        let temporaryFilesSize = sizesByCategory[.temporaryFiles] ?? 0
        let appGroupSize = sizesByCategory[.appGroup] ?? 0
        let tweaksSize = sizesByCategory[.tweaks] ?? 0
        let knownRootsSize = try await calculateCombinedSize(of: knownRoots)
        var librarySize: Int64 = 0
        if let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            librarySize = try await calculateSize(at: libraryPath)
        }
        // Other is the residual after explicit categories are removed from the known storage roots, plus loose root-level files.
        let residualOtherSize = knownRootsSize - appBundleSize - containersSize - appGroupSize - tweaksSize
        let otherSize = residualOtherSize + librarySize

        return LCStorageBreakdown(
            totalSize: appBundleSize + containersSize + temporaryFilesSize + appGroupSize + tweaksSize + otherSize,
            appBundleSize: appBundleSize,
            containersSize: containersSize,
            temporaryFilesSize: temporaryFilesSize,
            appGroupSize: appGroupSize,
            tweaksSize: tweaksSize,
            otherSize: otherSize,
            appItems: appItems
        )
    }

    nonisolated private static func calculateAppItem(
        from input: CZFStorageAppSnapshot,
    ) async throws -> LCAppStorageItem {
        var containerDetails: [LCAppStorageContainerItem] = []
        containerDetails.reserveCapacity(input.containers.count)

        var containersSize: Int64 = 0
        for container in input.containers {
            // 扫一半取消/抛错时也要停访问，不然这次的安全域访问就漏了；
            // defer 在本轮循环结束时跑，抛错路径也一样停。
            let didAccess = container.bookmarkResolved && container.containerURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    container.containerURL.stopAccessingSecurityScopedResource()
                }
            }

            let size = try await calculateSize(at: container.containerURL)
            
            if container.storageBookMark == nil {
                containersSize += size
            }
            containerDetails.append(
                LCAppStorageContainerItem(
                    id: UUID(),
                    name: container.name,
                    size: size,
                    isExternalContainer: container.storageBookMark != nil,
                    containerURL: container.containerURL
                )
            )
        }


        let bundleSize: Int64?
        if let bundlePath = input.bundlePath {
            bundleSize = try await calculateSize(at: URL(fileURLWithPath: bundlePath))
        } else {
            bundleSize = nil
        }
        
        let totalSize: Int64
        if input.isSideStore {
            totalSize = containersSize
        } else {
            totalSize = (bundleSize ?? 0) + containersSize
        }

        return LCAppStorageItem(
            id: UUID(),
            appModel: input.model,
            displayName: input.displayName,
            bundleSize: bundleSize,
            containersSize: containersSize,
            totalSize: totalSize,
            containerDetails: containerDetails
        )
    }

    nonisolated private static func calculateAppItems(
        from inputs: [CZFStorageAppSnapshot]
    ) async throws -> [LCAppStorageItem] {
        var appItems: [LCAppStorageItem] = []
        appItems.reserveCapacity(inputs.count)

        try await withThrowingTaskGroup(of: LCAppStorageItem.self) { group in
            for input in inputs {
                group.addTask(priority: .utility) {
                    try await calculateAppItem(
                        from: input
                    )
                }
            }

            for try await item in group {
                appItems.append(item)
            }
        }

        return appItems.sorted {
            if $0.totalSize == $1.totalSize {
                return ($0.displayName).localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.totalSize > $1.totalSize
        }
    }

    nonisolated private static func calculateCombinedSize(of urls: [URL]) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Int64.self) { group in
            for url in uniquePaths(urls) {
                group.addTask(priority: .utility) {
                    try await calculateSize(at: url)
                }
            }

            var totalSize: Int64 = 0
            for try await size in group {
                totalSize += size
            }
            return totalSize
        }
    }

    nonisolated private static func uniquePaths(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []

        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else {
                continue
            }
            uniqueURLs.append(url)
        }

        return uniqueURLs
    }

    nonisolated private static func calculateSize(at url: URL) async throws -> Int64 {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
            .isDirectoryKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                continue
            }

            // 3.8.522（L49）：软链目录不跟进——枚举器默认会钻进软链指向
            // 的目录，同款已在 LCDataManagementView.folderSize 修过
            //（3.8.317，用户真机实证：统计永远算不完）。客端容器
            // 里的 tmp 是指到共享 TMPDIR 的软链（LCBootstrap.m:513），
            // 不拦会把整个共享 tmp 算进每个容器里：各容器大小虚高且
            // 彼此雷同，容器总和虚增 N 倍 tmp，Other 残差也被压低
            //（tmp 不在已知根里）；TMPDIR 里的 <bid>-Inbox 软链还
            // 会把各容器 Inbox 再算一遍。软链本身不计大小（目标在
            // 树内由实路径计一次，树外本就不该计）。
            if resourceValues.isSymbolicLink == true {
                if resourceValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            // 客端容器是活的：文件在扫描中途被客端删掉/改名时
            // resourceValues 会抛错——跳过这个文件即可，不能让
            // 一次瞬时错误把整轮存储统计都报成失败。
            guard resourceValues.isRegularFile == true else {
                continue
            }

            let fileSize = resourceValues.totalFileAllocatedSize
                ?? resourceValues.fileAllocatedSize
                ?? resourceValues.fileSize
                ?? 0
            totalSize += Int64(fileSize)
        }

        return totalSize
    }
}
