//  CZFWidgetSnapshot.swift
//  LiveContainerSwiftUI
//
//  3.8.722（F-3）：桌面小组件的数据源——主 App 侧把置顶 App 的
//  快照写进 App Group 共享容器，小组件只读快照渲染。
//  为什么不能小组件自己扫盘：客 App 的包在主 App 沙盒
//  Documents/Applications（或共享区 LiveContainer/Applications），
//  小组件进程读不到主 App 沙盒；只有 App Group 共享容器两边都
//  可读。快照里只放小组件点启动要用的字段 + 图标小图文件名。
//  图标取法复用 CZFAppIconLoader 的缓存逻辑：客包内本来就有
//  LCAppIconLight.png 磁盘缓存（LCAppInfo.m:185-222），这里只
//  读缓存、不生成——没缓存的项小组件显示首字母占位，等用户逛
//  一次 App 页（网格/列表会后台生成图标写盘）下次同步即有图。

import UIKit
import WidgetKit

/// 小组件快照：置顶 App 列表 + 图标小图，写在 App Group 共享容器里。
enum CZFWidgetSnapshot {
    /// 快照文件名（App Group 根目录下）。
    static let fileName = "CZFWidgetPinnedApps.json"
    /// 图标小图目录名（App Group 根目录下），文件名为“固定键.png”。
    static let iconsDirName = "CZFWidgetIcons"

    struct Entry: Codable {
        /// 固定键（“包名_dataUUID”，与 CZFPinnedAppsStore 同款）。
        var key: String
        /// 显示名。
        var displayName: String
        /// 相对包路径（深链 bundle-name 参数原值）。
        var relativeBundlePath: String
        /// 容器文件夹名（深链 container-folder-name 参数原值）。
        var folderName: String
        /// 图标小图文件名（iconsDirName 下），无缓存图标时为空串。
        var iconFileName: String
    }

    private static func appGroupURL() -> URL? {
        LCSharedUtils.appGroupPath()
    }

    /// 全量同步：按当前置顶键 + 传入的模型表重建快照与图标。
    /// 固定键里 "src:" 开头的是源固定项（无已装实例、无法启动），
    /// 小组件只显示已装 App，跳过。模型表里查不到的残留键跳过，
    /// 不删固定数据（CZFPinnedAppsStore 同款：残留键留着无害）。
    /// 无置顶项时写空数组（小组件显示空态），旧图标一并清掉。
    /// 写完调 WidgetCenter 刷新时间线，小组件当场更新，不用等
    /// 下次系统轮询。
    static func sync(apps: [LCAppModel]) {
        guard let groupURL = appGroupURL() else { return }
        let pinnedKeys = LCUtils.appGroupUserDefault.stringArray(forKey: "CZFPinnedPanelApps") ?? []
        var entries: [Entry] = []
        var liveIconNames = Set<String>()
        for key in pinnedKeys {
            // 源固定项（"src:包名"）没有已装实例，跳过。
            guard !key.hasPrefix("src:") else { continue }
            guard let app = apps.first(where: { CZFPinnedAppsStore.pinKey(for: $0) == key }),
                  let relativeBundlePath = app.appInfo.relativeBundlePath else { continue }
            let displayName = app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? key
            // 深链的容器参数：当前选中容器优先，取不到退到 dataUUID
            //（容器文件夹名就是 dataUUID，见 CZFAppGridView 复制深链）。
            let folderName = app.uiSelectedContainer?.folderName ?? app.appInfo.dataUUID ?? ""
            var iconFileName = ""
            // 只读磁盘缓存（快路径），不生成图标：生成是后台活，
            // 同步调用方（onAppear/固定切换）在主线程，不堵界面。
            if let icon = CZFAppIconLoader.cachedIconOnly(for: app.appInfo, darkModeIcon: false),
               let png = icon.pngData() {
                iconFileName = "\(key).png"
                liveIconNames.insert(iconFileName)
                let iconsDir = groupURL.appendingPathComponent(iconsDirName, isDirectory: true)
                try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
                try? png.write(to: iconsDir.appendingPathComponent(iconFileName), options: .atomic)
            }
            entries.append(Entry(key: key, displayName: displayName, relativeBundlePath: relativeBundlePath, folderName: folderName, iconFileName: iconFileName))
        }
        let url = groupURL.appendingPathComponent(fileName)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
        // 清掉不再置顶的残留图标（只删本目录下 .png，且不在本轮 live 集里）。
        let iconsDir = groupURL.appendingPathComponent(iconsDirName, isDirectory: true)
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: iconsDir, includingPropertiesForKeys: nil) {
            for file in leftovers where file.pathExtension.lowercased() == "png" && !liveIconNames.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        // 部署目标 iOS 15，WidgetCenter（iOS 14+）恒可用，无需 #available。
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 3.8.732（F-3）：签名快到期快照文件名（App Group 根目录下）。
    static let expiryFileName = "CZFWidgetExpiry.json"

    /// 快照里的一个快到期签名（字段与扩展侧 CZFWidgetExpiryEntry 一一对应）。
    struct ExpiryEntry: Codable {
        /// 显示名。
        var name: String
        /// 剩余天数（负数=已过期）。
        var daysLeft: Int
        /// 到期日短串（如“12月2日”，CZFSignatureExpiry.dateText 同款）。
        var dateText: String
    }

    /// 签名快到期同步：取已按到期日排好序的 loaded 前 4 项写盘，
    /// 写完调 WidgetCenter 刷新时间线。只做 JSON 编码 + 原子写盘，
    /// 不读盘、不自己扫 mobileprovision（loadAll 是后台读盘活，
    /// 调用方 czfRefreshSignatureExpiry 已算好 loaded 数组传进来；
    /// sync() 是主线程调的，里面调 loadAll 会堵界面）。
    /// loaded 为空时写空数组（小组件显示空态，旧快照不残留）。
    /// dateText 读主线程专用的静态格式器——调用方在 MainActor.run
    /// 写回块里调（主线程），安全。
    static func syncExpiry(items: [CZFSignatureExpiry]) {
        guard let groupURL = appGroupURL() else { return }
        let entries = items.prefix(4).map { ExpiryEntry(name: $0.name, daysLeft: $0.daysLeft, dateText: $0.dateText) }
        let url = groupURL.appendingPathComponent(expiryFileName)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
