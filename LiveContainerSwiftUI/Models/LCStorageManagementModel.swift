import Foundation
import Combine

struct LCAppStorageItem: Identifiable {
    let id: UUID

    let appModel: LCAppModel
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

    func refresh(apps: [LCAppModel], hiddenApps: [LCAppModel]) async {
        guard !isCalculating else {
            return
        }

        isCalculating = true
        defer { isCalculating = false }
        errorInfo = nil
        breakdown = nil

        do {
            breakdown = try await Self.calculateBreakdown(apps: apps, hiddenApps: hiddenApps)
        } catch {
            errorInfo = error.localizedDescription
        }
    }

    private enum StorageCategory {
        case appBundle
        case containers
        case temporaryFiles
        case appGroup
        case tweaks
    }

    nonisolated private static func calculateBreakdown(apps: [LCAppModel], hiddenApps: [LCAppModel]) async throws -> LCStorageBreakdown {
        var allApps: [LCAppModel]
        if DataManager.shared.model.isHiddenAppUnlocked {
            allApps = apps + hiddenApps
        } else {
            allApps = apps
        }
        
        if UserDefaults.sideStoreExist() {
            allApps.append(LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared))
        }

        // Show per-app bundle usage only when every installed app has a reliable bundle path.
        let appItems = try await calculateAppItems(
            from: allApps
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
        from input: LCAppModel,
    ) async throws -> LCAppStorageItem {
        var containerDetails: [LCAppStorageContainerItem] = []
        containerDetails.reserveCapacity(input.uiContainers.count)

        var containersSize: Int64 = 0
        for container in input.uiContainers {
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
                    isExternalContainer: container.storageBookMark != nil
                )
            )
        }


        let bundleSize: Int64?
        if let bundlePath = input.appInfo.bundlePath() {
            bundleSize = try await calculateSize(at: URL(fileURLWithPath: bundlePath))
        } else {
            bundleSize = nil
        }
        
        let totalSize: Int64
        if input.appInfo is BuiltInSideStoreAppInfo {
            totalSize = containersSize
        } else {
            totalSize = (bundleSize ?? 0) + containersSize
        }

        return LCAppStorageItem(
            id: UUID(),
            appModel: input,
            bundleSize: bundleSize,
            containersSize: containersSize,
            totalSize: totalSize,
            containerDetails: containerDetails
        )
    }

    nonisolated private static func calculateAppItems(
        from inputs: [LCAppModel]
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
                return ($0.appModel.displayName).localizedCaseInsensitiveCompare($1.appModel.displayName) == .orderedAscending
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
