//
//  LCAltStoreSourcesView.swift
//  LiveContainerSwiftUI
//
//  Created by Stephen B on 2025/2/15.
//

import Foundation
import ImageIO
import SwiftUI
import UIKit
import CryptoKit

struct AltStoreSourceAppVersion: Identifiable, Hashable {
    let id = UUID()
    let version: String
    let buildVersion: String?
    let releaseDate: Date?
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int64?
}

struct AltStoreSourceApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let tintColor: Color?
    let screenshots: [URL]
    let versions: [AltStoreSourceAppVersion]
    let latestVersion: AltStoreSourceAppVersion?
    let isBeta: Bool

    // B-9：身份只用包名，不再带版本号——源刷新时版本号一变
    // （1.0 → 1.1），行身份变、cell 重建、详情 sheet 被关掉。
    // 同包名在两个源里是两条记录也不怕：身份按 ForEach 作用
    // 域算，两个源是两个 ForEach；同源内同包名重复条目由
    // B-10 渲染前显式去重（只留一条），不再靠版本号区分。
    // 3.8.450：身份改成包名 + 名字——同源内同包名有汉化版/
    // 原版两个变体时，只按包名会把第二个当重复杀掉（Erosion
    // 中文版 0.3.1 被 Erosion 0.3.1 盖掉，用户 23:19 报）；
    // 名字区分变体，版本号仍不进身份，刷新升版不重建 cell。
    var czfStableID: String {
        bundleIdentifier + "|" + name
    }
}

struct AltStoreSource: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let headerURL: URL?
    let tintColor: Color?
    let website: URL?
    let apps: [AltStoreSourceApp]
}

private struct AltStoreSourceResponse: Decodable {
    let name: String?
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let headerURL: String?
    let tintColor: String?
    let website: String?
    let apps: [AltStoreSourceAppResponse]?
}

private struct AltStoreSourceAppResponse: Decodable {
    let beta: Bool?
    let name: String?
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let version: String?
    let versionDate: String?
    let versionDescription: String?
    let downloadURL: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let screenshotURLs: [String]?
    let versions: [AltStoreSourceAppVersionResponse]?
    
    enum CodingKeys: String, CodingKey {
        case beta
        case name
        case bundleIdentifier
        case developerName
        case subtitle
        case version
        case versionDate
        case versionDescription
        case downloadURL
        case localizedDescription
        case iconURL
        case tintColor
        case screenshotURLs
        case versions
    }
}

private struct AltStoreSourceAppVersionResponse: Decodable {
    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    
    enum CodingKeys: String, CodingKey {
        case version
        case buildVersion = "buildNumber"
        case date
        case localizedDescription
        case downloadURL
        case size
    }
}

@MainActor
final class AltStoreSourcesViewModel: ObservableObject {
    struct SourceItem: Identifiable, Hashable {
        let id: URL
        let url: URL
        var source: AltStoreSource?
        var isLoading: Bool
        var error: String?
        
        init(url: URL, isLoading: Bool = false, source: AltStoreSource? = nil, error: String? = nil) {
            self.url = url
            self.id = url
            self.isLoading = isLoading
            self.source = source
            self.error = error
        }
        
        var displayName: String {
            if let source {
                return source.name
            }
            if let host = url.host, !host.isEmpty {
                return host
            }
            return url.absoluteString
        }
        
        var primaryIconURL: URL? {
            if let icon = source?.iconURL {
                return icon
            }
            if let appIcon = source?.apps.first(where: { $0.iconURL != nil })?.iconURL {
                return appIcon
            }
            return nil
        }
    }
    
    @Published private(set) var sources: [SourceItem] = []
    @Published var isRefreshingAll = false
    private let defaultsKey = "LCAltStoreSourceURLs"

    private let cacheDirectoryName = "AltStoreSourceCache"
    
    init() {
        loadStoredSources()
        Task {
            await refreshAllSources()
        }
    }
    
    func addSource(from rawValue: String) async -> String? {
        guard let normalizedURL = normalizeSourceURL(from: rawValue) else {
            return "lc.sources.error.invalidUrl".loc
        }
        
        if sources.contains(where: { $0.url == normalizedURL }) {
            return "lc.sources.error.duplicate".loc
        }
        
        sources.append(SourceItem(url: normalizedURL, isLoading: true))
        persistSources()
        await refreshSource(url: normalizedURL)
        return nil
    }
    
    func removeSource(_ item: SourceItem) {
        sources.removeAll { $0.id == item.id }
        persistSources()
        removeCache(for: item.url)
    }
    
    func refreshSource(_ item: SourceItem) async {
        await refreshSource(url: item.url)
    }
    
    func refreshAllSources() async {
        guard !sources.isEmpty else {
            return
        }
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        // 原来 for 循环一个个 await：源多时等待时间累加。
        // 改成每 4 个一组并行刷：组内网络请求并行，组间顺序。
        // refreshSource 是 MainActor 隔离的，sources 的读写
        // 都在主 actor 上串行，网络 await 会挂起让出，不会
        // 出现多任务同时改数组的竞态；缓存已在 loadStoredSources
        // 里先显示，刷新期间旧内容不清空，失败只记 error。
        let urls = sources.map({ $0.url })
        var start = 0
        while start < urls.count {
            let chunk = Array(urls[start..<min(start + 4, urls.count)])
            await withTaskGroup(of: Void.self) { group in
                for url in chunk {
                    group.addTask { await self.refreshSource(url: url) }
                }
            }
            start += 4
        }
    }
    
    private func refreshSource(url: URL) async {
        guard let index = sources.firstIndex(where: { $0.url == url }) else {
            return
        }
        sources[index].isLoading = true
        sources[index].error = nil
        let previousData = cachedData(for: url)
        do {
            let (source, data) = try await AltStoreSourceLoader.load(from: url)
            guard let sourceIndex = sources.firstIndex(where: { $0.url == url }) else {
                return
            }
            if let previousData, previousData == data {
                sources[sourceIndex].isLoading = false
                return
            }
            sources[sourceIndex].source = source
            sources[sourceIndex].isLoading = false
            storeCache(data, for: url)
        } catch {
            if let sourceIndex = sources.firstIndex(where: { $0.url == url }) {
                sources[sourceIndex].error = error.localizedDescription
                sources[sourceIndex].isLoading = false
            }
        }
    }
    
    private func loadStoredSources() {
        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: defaultsKey) as? [String] ?? []
        let urls = stored.compactMap { URL(string: $0) }
        self.sources = urls.map { SourceItem(url: $0, isLoading: false) }
        for index in sources.indices {
            let url = sources[index].url
            if let data = cachedData(for: url),
               let cachedSource = try? AltStoreSourceLoader.decode(from: data, baseURL: url) {
                sources[index].source = cachedSource
            }
        }
    }
    
    private func persistSources() {
        let urls = sources.map { $0.url.absoluteString }
        UserDefaults.standard.set(urls, forKey: defaultsKey)
    }
    
    private func normalizeSourceURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        if let httpsURL = URL(string: "https://\(trimmed)") {
            return httpsURL
        }
        return nil
    }
}

private extension AltStoreSourcesViewModel {
    func cachedData(for url: URL) -> Data? {
        guard let fileURL = cacheFileURL(for: url) else { return nil }
        return try? Data(contentsOf: fileURL)
    }
    
    func storeCache(_ data: Data, for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignore cache write errors
        }
    }
    
    func cacheFileURL(for url: URL) -> URL? {
        guard let directory = ensureCacheDirectory() else { return nil }
        let fileName = cacheFileName(for: url)
        return directory.appendingPathComponent(fileName)
    }
    
    func ensureCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }
    
    func cacheFileName(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }
    
    func removeCache(for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            // Ignore cache removal errors
        }
    }
}

enum AltStoreSourceLoader {
    static func load(from url: URL) async throws -> (AltStoreSource, Data) {
        let (data, response) = try await CZFVPNManager.hostSession().data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "AltStoreSource", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
        }
        let source = try decode(from: data, baseURL: url)
        return (source, data)
    }
    
    static func decode(from data: Data, baseURL: URL) throws -> AltStoreSource {
        try decodeSource(from: data, baseURL: baseURL)
    }
    
    private static func decodeSource(from data: Data, baseURL: URL) throws -> AltStoreSource {
        // 日期格式器每轮解码只建一次：原来每个日期字段、
        // 每个版本日期都新建 ISO8601 + DateFormatter，源里
        // App 多就建一堆。不改成静态共享——DateFormatter
        // 不是线程安全的，解码可能不在主线程跑；每轮自带
        // 一份、同一轮内复用，JSON 解码本身是顺序的，
        // 同一轮内不存在并发改格式器的情况。
        let isoFormatter = ISO8601DateFormatter()
        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "yyyy-MM-dd"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let isoDate = isoFormatter.date(from: rawValue) {
                return isoDate
            }
            if let shortDate = shortFormatter.date(from: rawValue) {
                return shortDate
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(rawValue)")
        })

        let response = try decoder.decode(AltStoreSourceResponse.self, from: data)
        guard let name = response.name else {
            throw NSError(domain: "AltStoreSource", code: 0, userInfo: [NSLocalizedDescriptionKey: "lc.sources.error.malformed".loc])
        }
        let apps = (response.apps ?? []).compactMap { appResponse in
            buildApp(from: appResponse, baseURL: baseURL, fallbackTint: response.tintColor, isoFormatter: isoFormatter, shortFormatter: shortFormatter)
        }
        // B-10：解码处按 czfStableID 显式去重（留第一条）——
        // 源 JSON 里同包名出现两次时，ForEach 撞 id 的行为是
        // 未定义的，不能把去重寄托在 SwiftUI 上。这里一次去
        // 重，网格/列表/批量三路都干净。
        return AltStoreSource(
            name: name,
            identifier: response.identifier,
            subtitle: response.subtitle,
            description: response.description,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            headerURL: url(for: response.headerURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor),
            website: url(for: response.website, baseURL: baseURL),
            apps: czfDedupSourceApps(apps)
        )
    }
    
    private static func buildApp(from response: AltStoreSourceAppResponse, baseURL: URL, fallbackTint: String?, isoFormatter: ISO8601DateFormatter, shortFormatter: DateFormatter) -> AltStoreSourceApp? {
        guard let bundleIdentifier = response.bundleIdentifier else {
            return nil
        }
        // 3.8.412：名字为空的源条目不能直接留着——Text("") 不渲染，
        // 图标再加载失败就剩一个全空白格（用户 11-11 截图 3 处）。
        // 空名字用 bundleIdentifier 兜底，格子总有字可认。
        let trimmedName = (response.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? bundleIdentifier : trimmedName

        let versions = buildVersions(from: response, baseURL: baseURL, isoFormatter: isoFormatter, shortFormatter: shortFormatter)
        let latest = versions.first ?? buildLegacyVersion(from: response, baseURL: baseURL, isoFormatter: isoFormatter, shortFormatter: shortFormatter)
        
        return AltStoreSourceApp(
            name: name,
            bundleIdentifier: bundleIdentifier,
            developerName: response.developerName,
            subtitle: response.subtitle,
            description: response.localizedDescription ?? response.versionDescription,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor ?? fallbackTint),
            screenshots: (response.screenshotURLs ?? []).compactMap { url(for: $0, baseURL: baseURL) },
            versions: versions,
            latestVersion: latest,
            isBeta: response.beta ?? false
        )
    }
    
    private static func buildVersions(from response: AltStoreSourceAppResponse, baseURL: URL, isoFormatter: ISO8601DateFormatter, shortFormatter: DateFormatter) -> [AltStoreSourceAppVersion] {
        guard let versions = response.versions else { return [] }
        return versions.compactMap { version in
            guard let versionString = version.version,
                  let downloadURLString = version.downloadURL,
                  let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
                return nil
            }
            return AltStoreSourceAppVersion(
                version: versionString,
                buildVersion: version.buildVersion,
                releaseDate: parseDate(version.date, isoFormatter: isoFormatter, shortFormatter: shortFormatter),
                localizedDescription: version.localizedDescription,
                downloadURL: downloadURL,
                size: version.size
            )
        }
    }
    
    private static func buildLegacyVersion(from response: AltStoreSourceAppResponse, baseURL: URL, isoFormatter: ISO8601DateFormatter, shortFormatter: DateFormatter) -> AltStoreSourceAppVersion? {
        guard let versionString = response.version,
              let downloadURLString = response.downloadURL,
              let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
            return nil
        }
        return AltStoreSourceAppVersion(
            version: versionString,
            buildVersion: nil,
            releaseDate: parseDate(response.versionDate, isoFormatter: isoFormatter, shortFormatter: shortFormatter),
            localizedDescription: response.versionDescription ?? response.localizedDescription,
            downloadURL: downloadURL,
            size: nil
        )
    }
    
    private static func parseDate(_ value: String?, isoFormatter: ISO8601DateFormatter, shortFormatter: DateFormatter) -> Date? {
        guard let value else { return nil }
        if let isoDate = isoFormatter.date(from: value) {
            return isoDate
        }
        return shortFormatter.date(from: value)
    }
    
    private static func url(for string: String?, baseURL: URL) -> URL? {
        guard let string = string, !string.isEmpty else { return nil }
        if let absoluteURL = URL(string: string), absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: string, relativeTo: baseURL)?.absoluteURL
    }
    
    private static func color(from hex: String?) -> Color? {
        guard let hex = hex else { return nil }
        return Color(hexString: hex)
    }
}

private extension Color {
    init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")
        
        if cleaned.count == 3 {
            var expanded = ""
            for character in cleaned {
                expanded.append(character)
                expanded.append(character)
            }
            cleaned = expanded
        }
        
        if cleaned.count == 6 {
            cleaned.append("FF")
        }
        
        guard cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            return nil
        }
        
        let red = Double((value & 0xFF00_0000) >> 24) / 255.0
        let green = Double((value & 0x00FF_0000) >> 16) / 255.0
        let blue = Double((value & 0x0000_FF00) >> 8) / 255.0
        let alpha = Double(value & 0x0000_00FF) / 255.0
        
        self = Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// 「忽略此版本」的存储：键 CZFIgnoredUpdate-<bundleId> 存被
/// 忽略的版本号。忽略后这个版本不再算有更新（行状态、源标签
/// 红点、全部更新都跳过）；源里出了更新的版本会重新提醒
enum CZFUpdateIgnore {
    static func ignoredVersion(for bundleId: String) -> String? {
        UserDefaults.standard.string(forKey: "CZFIgnoredUpdate-\(bundleId)")
    }
    static func setIgnored(_ version: String?, for bundleId: String) {
        if let version {
            UserDefaults.standard.set(version, forKey: "CZFIgnoredUpdate-\(bundleId)")
        } else {
            UserDefaults.standard.removeObject(forKey: "CZFIgnoredUpdate-\(bundleId)")
        }
    }
    static func isIgnored(_ app: AltStoreSourceApp) -> Bool {
        guard let latest = app.latestVersion?.version else { return false }
        return ignoredVersion(for: app.bundleIdentifier) == latest
    }
}

// U10 批量勾选键：源 feed URL + bundleIdentifier。同一 App 在
// 两个源里是两条记录，只用 bundleIdentifier 会两边同打勾；
// 源标识用 SourceItem 的 feed URL（item.url / item.id，
// 稳定唯一），不用 AltStoreSource.identifier（可选、
// 可能为空/重复）也不用 AltStoreSource.id（每次解码
// 新 UUID，不稳定）。
func czfSourceSelectionKey(sourceURL: URL, bundleIdentifier: String) -> String {
    "\(sourceURL.absoluteString):\(bundleIdentifier)"
}

// B-10：按 czfStableID 显式去重（留第一条）。
func czfDedupSourceApps(_ apps: [AltStoreSourceApp]) -> [AltStoreSourceApp] {
    var seen = Set<String>()
    return apps.filter { seen.insert($0.czfStableID).inserted }
}

// 全部更新清单 sheet（用户 18:46 令）：列出全部可更新 App，
// 每行图标 + 名字 + 已装版本 → 新版本 + 单独“更新”按钮；
// 底部“全部更新”走批量队列。O-4：单行更新不关整单——点过
// 的行标“已入队”并从名单剔除，可连续点下一行；onUpdateOne
// 返回是否已接单（无下载链接返回 false，行保留）。
struct CZFUpdatableAppsSheet: View {
    let apps: [AltStoreSourceApp]
    let onUpdateOne: (AltStoreSourceApp) -> Bool
    let onUpdateAll: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel: SharedModel
    // O-4：行内“已入队”状态——点过“更新”的行先标已入队，
    // 父级同时把它从 cachedUpdatableApps 剔除，行随后消失；
    // 父级名单没刷新时，已入队的行至少显示状态、不让重
    // 复点。
    @State private var updatingIDs: Set<String> = []

    private func installedVersion(for app: AltStoreSourceApp) -> String {
        (sharedModel.apps + sharedModel.hiddenApps)
            .first(where: { $0.appInfo.bundleIdentifier() == app.bundleIdentifier })?
            .appInfo.version() ?? ""
    }

    var body: some View {
        // 部署目标 iOS 15：NavigationStack 是 iOS 16+，用
        // NavigationView + Stack 样式（与本文件其余 sheet 同款）。
        NavigationView {
            List {
                ForEach(apps, id: \.czfStableID) { app in
                    HStack(spacing: 12) {
                        SourceIconView(url: app.iconURL)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .lineLimit(1)
                            Text("\(installedVersion(for: app)) → \(app.latestVersion?.version ?? "")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if updatingIDs.contains(app.czfStableID) {
                            Text("已入队")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else {
                            Button("更新") {
                                if onUpdateOne(app) {
                                    updatingIDs.insert(app.czfStableID)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .navigationTitle("全部更新(\(apps.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onUpdateAll()
                } label: {
                    Text("全部更新(\(apps.count))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(Color(.systemBackground))
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct LCSourcesView: View {
    @StateObject private var viewModel = AltStoreSourcesViewModel()
    @State private var errorMessage: String?
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @ObservedObject public var searchContext: SearchContext = SearchContext()
    @State private var expandedSources: Set<URL> = []
    // 源中 #3：上次见过的源 id 集合——onChange 里用它判断哪个
    // 源是真正新加入的（只用 expandedSources 作基准不行：
    // 被用户收起的旧源也不在展开集里，会被误判为新源）。
    @State private var czfKnownSourceIDs: Set<URL> = []
    @State private var isManagingSources = false
    @State private var isBatchMode = false
    @State private var selectedIDs = Set<String>()
    // 源页网格模式（3.8.407）：默认 false=原来列表；列数/图标
    // 大小复用 App 页同一套 @AppStorage 键，两处同改同生效。
    @AppStorage("CZFSourceListGridMode") private var czfSourceGridMode = false
    @AppStorage("CZFAppGridColumns") private var czfSourceGridColumns = 5
    @AppStorage("CZFAppGridIconSize") private var czfSourceGridIconSize = 0
    @State private var czfSourceGridSettingsShow = false
    // 可更新数量写到这里，底部「源」标签上显示红点数字
    @AppStorage("CZFUpdatableAppCount") private var updatableCountBadge = 0
    // 可更新名单缓存：原来 updatableApps 是计算属性，body 每次
    // 渲染（搜字、展开、加载状态变）都把全部源 × 全部 App 比一
    // 遍版本、还逐个读忽略记录；改成算一次存起来，只在源/已装/
    // 忽略变时重算（见 refreshUpdatableCache 调用点）
    @State private var cachedUpdatableApps: [AltStoreSourceApp] = []
    // 全部更新点开先列清单（用户 18:46 令）：原来点“全部更新”
    // 直接全装，用户看不到是哪几个要更新。改成先弹 sheet 列出
    // 全部可更新 App（图标 + 名字 + 已装版本 → 新版本），每行
    // 可单独更新，底部再放“全部更新”。
    @State private var showUpdatableList = false
    // 本地 IPA 文件夹（3.8.454，用户 20:34 令“把文件夹移到源
    // 这里”+“一边源一边文件夹可以选择显示”）：源页顶部加
    // “源 / 文件夹”分段切换，文件夹区从 App 页移到这里；
    // 保存/恢复走共用 CZFLocalIpaFolderStore。
    @State private var czfSourcesTab = 0
    @State private var czfIpaFolderPickerShow = false
    @State private var czfIpaFolderURL: URL? = nil
    // 上次自动刷新源的时间（自动刷新节流：5 分钟内不重复刷）
    @AppStorage("CZFLastSourceAutoRefresh") private var lastSourceAutoRefresh: Double = 0

    /// 自动刷新源：打开 App / 切到源页时后台刷一次，更新红点
    /// 才是准的；5 分钟内重复触发直接跳过，不浪费流量
    private func autoRefreshSourcesIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard now - lastSourceAutoRefresh > 300, !viewModel.sources.isEmpty else {
            return
        }
        lastSourceAutoRefresh = now
        Task { await viewModel.refreshAllSources() }
    }
    
    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var isViewAppeared = false

    // 自定义背景（3.8.416）：与 App 页同一张图、同一把键
    // （CZFAppBackground.versionKey）——App 页网格设置里选
    // 的图，这里跟着显示；源页之前根本没接背景（17:44 用户
    // 报“源背景图不生效”）。读法与 App 页同款（.background
    // 挂 ScrollView，不包 ZStack，不动 NavigationView 排布）。
    @AppStorage(CZFAppBackground.versionKey) private var czfBackgroundVersion = 0
    @State private var czfBackgroundImage: UIImage? = nil
    
    // body 拆分（3.8.423，422 构建红字）：body 太大编译器
    // 算不过来（unable to type-check in reasonable time）。
    // 把最大的块——整个 Group（空态 + 列表）抽出来，body
    // 只剩 NavigationView + 修饰符。只拆不改逻辑。
    // 3.8.454：源/文件夹分段切换——czfSourcesContent 只放
    // Picker + 分支，源列表本身再抽一层 czfSourcesListContent。
    @ViewBuilder
    private var czfSourcesContent: some View {
        VStack(spacing: 0) {
            Picker("显示", selection: $czfSourcesTab) {
                Text("源").tag(0)
                Text("文件夹").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            if czfSourcesTab == 1 {
                ScrollView {
                    CZFInlineIpaFolderSection(
                        folderURL: czfIpaFolderURL,
                        onPickFolder: { czfIpaFolderPickerShow = true },
                        onInstall: { url in czfInstallFolderIpa(url) }
                    )
                    .padding()
                }
            } else {
                czfSourcesListContent
            }
        }
    }

    @ViewBuilder
    private var czfSourcesListContent: some View {
        Group {
            if viewModel.sources.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("lc.sources.empty".loc)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    // 3.8.431 源分组仍没好（用户 01:58 报 429“原来
                    // 一模一样”：整页只有一个“解剖自我”组头）：
                    // 429 只把 CZFSourceGridView 里层改成 VStack，
                    // 外层父级这里仍是 LazyVStack——ScrollView >
                    // LazyVStack（父）> CZFSourceGridView（VStack）
                    // > 每源 VStack > 组头 + LazyVGrid。父级懒栈
                    // 给里层算高度算不准，只露出第一组、其余组
                    // 被裁掉，看着像所有 App 混在一个组里。426
                    // 的 Section 版组头横排一行、428 的组头沉底，
                    // 都是同一处父级懒栈算高度的毛病。修法：父级
                    // 也改普通 VStack（非懒），整页确定性布局；
                    // 列表路（AltStoreSourceSectionView）同样走
                    // VStack，不受影响。
                    VStack(spacing: 16) {
                        if czfSourceGridMode {
                            CZFSourceGridView(
                                items: viewModel.sources,
                                columns: czfSourceGridColumns,
                                iconSize: czfSourceGridIconSize,
                                filteredApps: { item in filteredApps(for: item) },
                                isFiltering: isFiltering,
                                onRefresh: { item in Task { await viewModel.refreshSource(item) } },
                                onInstall: install(app:),
                                onInstallAsNew: installAsNew(app:),
                                onDownload: download(app:),
                                onDownloadVersion: downloadVersion(url:),
                                onRemove: { item in sourcePendingRemoval = item },
                                isBatchMode: isBatchMode,
                                selectedIDs: selectedIDs,
                                onToggleSelect: { sourceURL, app in
                                    let key = czfSourceSelectionKey(sourceURL: sourceURL, bundleIdentifier: app.bundleIdentifier)
                                    if selectedIDs.contains(key) {
                                        selectedIDs.remove(key)
                                    } else {
                                        selectedIDs.insert(key)
                                    }
                                }
                            )
                            .padding(.horizontal)
                        } else {
                            ForEach(czfVisibleListSources, id: \.id) { item in
                                let apps = filteredApps(for: item)
                                AltStoreSourceSectionView(
                                    item: item,
                                    filteredApps: apps,
                                    isFiltering: isFiltering,
                                    isExpanded: expandedSources.contains(item.id),
                                    onRefresh: { Task { await viewModel.refreshSource(item) } },
                                    onInstall: install(app:),
                                    onInstallAsNew: installAsNew(app:),
                                    onDownload: download(app:),
                                    onDownloadVersion: downloadVersion(url:),
                                    onRemove: { sourcePendingRemoval = item },
                                    toggleExpanded: { toggleExpansion(for: item.id) },
                                    isBatchMode: isBatchMode,
                                    selectedIDs: selectedIDs,
                                    onToggleSelect: { sourceURL, app in
                                        let key = czfSourceSelectionKey(sourceURL: sourceURL, bundleIdentifier: app.bundleIdentifier)
                                        if selectedIDs.contains(key) {
                                            selectedIDs.remove(key)
                                        } else {
                                            selectedIDs.insert(key)
                                        }
                                    }
                                )
                                .padding(.horizontal)
                                .animation(.easeInOut, value: apps.count)
                            }
                        }
                        
                        // S2：加载中不闪空态——还有源在加载时不显示
                        // “没有 App”，等加载完、计数仍为 0 时再显示。
                        if totalFilteredAppCount == 0 && !viewModel.sources.contains(where: { $0.isLoading }) {
                            VStack(spacing: 8) {
                                Text("lc.sources.section.noApps".loc)
                                    .foregroundStyle(.gray)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 160, alignment: .center)
                            .padding(.horizontal)
                        }
                    }
                    // 顶部留白 + 底部留白（3.8.421，建议第 1、6 条）：
                    // 顶部 8pt，第一组完整露出来，不顶到搜索栏下；
                    // 底部 100pt，滑到底最后一行名字完整露出来，
                    // 不被底部 tab 栏盖住一半。
                    // 源页顶部留白（3.8.426，8→12）：第一组图标
                    // 顶着导航栏/搜索栏，8 不够，第一行图标还
                    // 是露不全。加到 12，第一组离顶栏远一点。
                    .padding(.top, 12)
                    .padding(.bottom, 100)
                }
                // 自定义背景（3.8.416）：与 App 页同款——图挂
                // ScrollView 的 .background，不包 ZStack，
                // 不动 NavigationView 排布（415 血泪：ZStack
                // 会把大标题/搜索栏/切换行叠到一块）。
                .background {
                    if let bg = czfBackgroundImage {
                        Image(uiImage: bg)
                            .resizable()
                            .scaledToFill()
                            .ignoresSafeArea()
                            .overlay(Color.black.opacity(0.12))
                    }
                }
                .onAppear {
                    czfBackgroundImage = CZFAppBackground.loadImage()
                }
                .onChange(of: czfBackgroundVersion) { _ in
                    czfBackgroundImage = CZFAppBackground.loadImage()
                }
                // 切换行已收进设置（3.8.419，建议第 3 条）：原来钉在
                // 顶部的“恢复原生 / 网格设置”行删掉，模式开关收到
                // 网格设置 sheet 里（CZFAppGridSettingsView 的显示
                // 模式，两页共用），网格设置入口收到顶栏 leading；
                // 页面多出一行 App。
            }
        }
    }

    // body 再拆分（3.8.424，423 构建仍红字）：与 App 页同款，
    // body 还是算不过来。抽 Group 不够，改两段拆：A=导航栏+
    // 弹层，body=A+搜索+事件回调。只拆不改逻辑。
    @ViewBuilder
    private var czfSourcesBodyA: some View {
        NavigationView {
            czfSourcesContent
            // 大标题改内联（3.8.420）：与 App 页同款，标题收进顶栏
            // 一行，页面更紧凑，顶栏不留大片空白。
            // 顶栏改实底（3.8.422，建议第 1 条）：与 App 页同款，
            // 导航栏背景改不透明，内容往上滑不从玻璃顶栏/搜索栏
            // 下面透出来，顶部干净。
            .navigationTitle("lc.tabView.sources".loc)
            .navigationBarTitleDisplayMode(.inline)
            // 顶栏实底走 czfSolidToolbarBackground（3.8.424：
            // .toolbarBackground 是 iOS 16+ API，部署目标 15.0
            // 下直接调编不过，包 #available）。
            .czfSolidToolbarBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.isRefreshingAll {
                        ProgressView()
                    } else {
                        Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                            Task { await viewModel.refreshAllSources() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    // 有已装 App 能更新时才出现：点开先列清单
                    // （见 showUpdatableList 注释），不在这直接装
                    if !cachedUpdatableApps.isEmpty {
                        Button("全部更新(\(cachedUpdatableApps.count))") {
                            showUpdatableList = true
                        }
                    }
                }
                // 顶栏统一（3.8.419，建议第 2 条）：批量按钮从 trailing
                // 收到 leading，跟刷新并排——两页都变成 leading  pill
                //（两个图标）+ trailing 圆圈（一个图标），跟 App 页
                // “+ ?” / “>” 同款式。网格设置入口也放 leading。
                ToolbarItem(placement: .topBarLeading) {
                    Button(isBatchMode ? "lc.common.cancel".loc : "lc.sources.batchSelect".loc, systemImage: isBatchMode ? "xmark" : "checkmark.circle") {
                        isBatchMode.toggle()
                        if !isBatchMode {
                            selectedIDs.removeAll()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if isBatchMode {
                            Button("lc.common.install".loc) {
                                batchInstallSelected()
                            }
                            .disabled(selectedIDs.isEmpty)
                        }
                        // 网格设置挪到 trailing（3.8.421，建议第 2 条）：
                        // leading 原来三个图标（刷新/批量/网格设置）挤一个
                        // 宽 pill，太宽、中间“源”字没地方；网格设置挪到
                        // 右边“+”旁边，leading 只留刷新+批量，pill 变窄。
                        // U12：只打开设置 sheet，不强制切网格——模式由
                        // sheet 里的显示模式 Picker 决定。
                        Button {
                            czfSourceGridSettingsShow = true
                        } label: {
                            Label("网格设置", systemImage: "slider.horizontal.3")
                        }
                        Button("lc.sources.addSource".loc, systemImage: "plus") {
                            isManagingSources = true
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: Binding<Bool>(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("lc.sources.removeConfirmation.title".loc, isPresented: Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } })
        ) {
            Button("lc.common.remove".loc, role: .destructive) {
                if let sourcePendingRemoval {
                    viewModel.removeSource(sourcePendingRemoval)
                }
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: {
            if let name = sourcePendingRemoval?.displayName {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(name))
            } else {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(""))
            }
        }
        .sheet(isPresented: $czfSourceGridSettingsShow) {
            CZFAppGridSettingsView(columns: $czfSourceGridColumns, iconSize: $czfSourceGridIconSize, gridMode: $czfSourceGridMode, showSort: false)
        }
        .sheet(isPresented: $showUpdatableList) {
            CZFUpdatableAppsSheet(
                apps: cachedUpdatableApps,
                onUpdateOne: { app in
                    // O-4：单行更新不关整单。无下载链接不接单，
                    // 行保留（install 里的 errorMessage 在 sheet
                    // 盖着时弹不出来，见 B-11；至少行还在、用户
                    // 看得到它没入队）。
                    guard app.latestVersion?.downloadURL != nil else {
                        errorMessage = "lc.sources.error.missingDownload".loc
                        return false
                    }
                    install(app: app)
                    cachedUpdatableApps.removeAll { $0.czfStableID == app.czfStableID }
                    return true
                },
                onUpdateAll: {
                    showUpdatableList = false
                    Task { @MainActor in
                        let result = await installBatch(cachedUpdatableApps)
                        czfShowBatchResult(result)
                    }
                }
            )
        }
        .sheet(isPresented: $isManagingSources) {
            if #available(iOS 16.0, *) {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
                .presentationDetents([.large])
            } else {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
            }
        }
        // 本地 IPA 文件夹选择器（3.8.454）：文件夹区移到源页，
        // 选文件夹存在共用 CZFLocalIpaFolderStore；内嵌区直接
        // 显示，不弹 sheet，不用 429 那套 onDismiss 绕法。
        .betterFolderImporter(isPresented: $czfIpaFolderPickerShow, callback: { folderURL in
            CZFLocalIpaFolderStore.save(folderURL)
            czfIpaFolderURL = folderURL
        }, onDismiss: {
            czfIpaFolderPickerShow = false
        })
    }

    var body: some View {
        czfSourcesBodyA
        .searchable(text: $searchContext.query)

        .onAppear {
            refreshUpdatableCache()
            autoRefreshSourcesIfNeeded()
            // 3.8.454：文件夹区移到源页，出现时把记过的文件夹
            // URL 恢复出来（没记过保持 nil，内嵌区显示“选择文件夹”按钮）。
            if czfIpaFolderURL == nil {
                czfIpaFolderURL = CZFLocalIpaFolderStore.restore()
            }
            // 设置 #22：只在首次出现时全展开，之后切 Tab 回源页
            // 保留 expandedSources，不再无条件全展开。原来这行
            // 写在 isViewAppeared 守卫之外，每次出现都全展开；
            // 且 isViewAppeared 原来只在有 deepLink 时才置真，
            // 无深链时永远 false、首次判断也失效——这里首次出
            // 现时先置真，deepLink 只在首次出现时处理一次。
            if !isViewAppeared {
                expandedSources = Set(viewModel.sources.map { $0.id })
                czfKnownSourceIDs = Set(viewModel.sources.map { $0.id })
                isViewAppeared = true
                guard sharedModel.selectedTab == .sources, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
            }
        }
        .onChange(of: viewModel.sources) { newSources in
            refreshUpdatableCache()
            let newSet = Set(newSources.map { $0.id })
            // 源中 #3：只把真正新加入的源加进展开集——新加入 =
            // 在新列表里、不在上次见过的源 id 里。原来
            // intersection(newSet).union(newSet) 恒等于全部源，
            // 收起的源一刷新就又展开。
            let newlyAdded = newSet.subtracting(czfKnownSourceIDs)
            expandedSources = expandedSources.intersection(newSet).union(newlyAdded)
            czfKnownSourceIDs = newSet
        }
        .onChange(of: sharedModel.apps) { _ in
            refreshUpdatableCache()
        }
        .onChange(of: sharedModel.hiddenApps) { _ in
            refreshUpdatableCache()
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .sources, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CZFRefreshSourcesRequest"))) { _ in
            // App 每次打开时主框架发一次：源页在的话顺手刷新，
            // 红点不用等用户点进源页才准；忽略/取消忽略也走这个
            // 通知，顺带重算可更新名单
            autoRefreshSourcesIfNeeded()
            refreshUpdatableCache()
        }
    }
    
    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 源中 #6（列表路）：搜索中过滤掉 filteredApps 为空的源组，
    // 不渲染空组头；非搜索时不过滤。
    private var czfVisibleListSources: [AltStoreSourcesViewModel.SourceItem] {
        guard isFiltering else { return viewModel.sources }
        return viewModel.sources.filter { !filteredApps(for: $0).isEmpty }
    }
    
    private var totalFilteredAppCount: Int {
        viewModel.sources.reduce(0) { partialResult, item in
            partialResult + filteredApps(for: item).count
        }
    }
    
    private func filteredApps(for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        guard let source = item.source else { return [] }
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return source.apps
        }
        return source.apps.filter { app in
            let lower = query.lowercased()
            if app.name.lowercased().contains(lower) {
                return true
            }
            if app.bundleIdentifier.lowercased().contains(lower) {
                return true
            }
            if let developer = app.developerName?.lowercased(), developer.contains(lower) {
                return true
            }
            if let subtitle = app.subtitle?.lowercased(), subtitle.contains(lower) {
                return true
            }
            return false
        }
    }
    
    @MainActor
    private func handleAddSource(_ rawValue: String) async -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 1 添加源失败无反馈：原来返回 Bool、错误写父级
        // errorMessage，sheet 盖在上面时父级 alert 被 UIKit
        // 静默丢弃，输错地址毫无反应。改成返回错误文本，
        // 调用方自己决定在哪显示：sheet 内本地弹、深链走父级。
        return await viewModel.addSource(from: trimmed)
    }
    
    @MainActor
    private func batchInstallSelected() {
        let appsToInstall = viewModel.sources.flatMap { item -> [AltStoreSourceApp] in
            guard let source = item.source else { return [] }
            return source.apps.filter { selectedIDs.contains(czfSourceSelectionKey(sourceURL: item.url, bundleIdentifier: $0.bundleIdentifier)) }
        }
        // 源中 #5：按 bundleIdentifier 去重，同一 App 在两个源
        // 里只装一次（保留第一次出现的记录）。
        var seenBundleIDs = Set<String>()
        let dedupedApps = appsToInstall.filter { seenBundleIDs.insert($0.bundleIdentifier).inserted }
        isBatchMode = false
        selectedIDs.removeAll()
        Task { @MainActor in
            let result = await installBatch(dedupedApps)
            czfShowBatchResult(result)
        }
    }

    // O-4：installBatch 的汇总——queued 是已交给 App 页安装
    // 队列的 IPA（还没装完，成败由 App 页队列的汇总报）；
    // succeeded 是同步装完的 dylib；skipped 是无下载链接、
    // 直接跳过的；failed 是 dylib 下载/签名失败的（名 + 原因）。
    struct CZFInstallBatchResult {
        var queued: [String] = []
        var succeeded: [String] = []
        var skipped: [String] = []
        var failed: [(name: String, reason: String)] = []
    }

    // O-4：批量汇总的就地反馈——installBatch 只负责数数，显示
    // 在这里。errorMessage 的 alert 挂在源页上：只有没切走
    // （一个都没入队）时用户才看得见；一旦有 IPA 入队就切到
    // App 页，跳过/失败的汇总目前没有可见通道（见 installBatch
    // 注释里 dylib 那一段），只能等 App 页接线。
    @MainActor
    private func czfShowBatchResult(_ result: CZFInstallBatchResult) {
        guard !result.skipped.isEmpty || !result.failed.isEmpty else { return }
        guard result.queued.isEmpty else { return }
        var lines: [String] = []
        if !result.skipped.isEmpty {
            lines.append("跳过 \(result.skipped.count) 个（无下载链接）：\(result.skipped.joined(separator: "、"))")
        }
        if !result.failed.isEmpty {
            lines.append("失败 \(result.failed.count) 个：\(result.failed.map { "\($0.name)：\($0.reason)" }.joined(separator: "、"))")
        }
        errorMessage = lines.joined(separator: "\n")
    }

    /// 批量安装一组 App（勾选批量装、「全部更新」共用）：
    /// 全部发给 App 页的安装队列串行执行，autoReplace =
    /// 已装同款直接覆盖、不逐个弹框确认
    /// O-4：返回（入队/跳过/失败）汇总，不再静默跳过。入队
    /// 只是“已交给 App 页队列”，真正的成功/失败由 App 页安
    /// 装队列的汇总报（LCAppListView 的批量收尾）；这里的
    /// failed 只是批量前置失败（无下载链接、dylib 下载/签
    /// 名失败）。
    /// dylib 失败的可见反馈目前接不上：失败写源页
    /// errorMessage 时用户已被切到 App 页、源页 alert 看不
    /// 见。要让 App 页在安装队列收尾处报这笔失败，得改
    /// LCAppListView.swift——在 drainPendingInstalls /
    /// notifyBatchDone 处接一份“源页批量前置失败”名单（例
    /// 如 CZFSourcePendingInstall 同款共享数组，App 页排空
    /// 时读出来拼进批量汇总/通知）。本次只把汇总返回出来，
    /// 调用方在没切走时就地提示（见 czfShowBatchResult）。
    @MainActor
    private func installBatch(_ apps: [AltStoreSourceApp]) async -> CZFInstallBatchResult {
        var result = CZFInstallBatchResult()
        var switchedTab = false
        for app in apps {
            guard let downloadURL = app.latestVersion?.downloadURL else {
                result.skipped.append(app.name)
                continue
            }
            if downloadURL.pathExtension.lowercased() == "dylib" {
                // 插件（dylib）走插件安装通道：等它装完再数，
                // 失败进汇总，不再后台 Task 静默丢掉。
                if let error = await installTweak(from: downloadURL, name: app.name, bundleIdentifier: app.bundleIdentifier) {
                    result.failed.append((name: app.name, reason: error.localizedDescription))
                } else {
                    result.succeeded.append(app.name)
                }
                continue
            }
            if !switchedTab {
                withAnimation {
                    DataManager.shared.model.selectedTab = .apps
                }
                switchedTab = true
            }
            // 3.8.428 设置#25：不再发 0.5 秒延迟通知（App 页若未出现会丢），
            // 改写入共享待装队列，App 页 onAppear 时排空进安装队列。
            CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: downloadURL, autoReplace: true, preview: false, forceAsNew: false))
            result.queued.append(app.name)
        }
        return result
    }

    /// 已装且源里有更高版本的 App（「全部更新」的名单）：
    /// 版本号按数字段比较（1.10 > 1.9），同名只算一次
    private func computeUpdatableApps() -> [AltStoreSourceApp] {
        let installed = Dictionary((sharedModel.apps + sharedModel.hiddenApps).map {
            ($0.appInfo.bundleIdentifier() ?? "", $0.appInfo.version() ?? "")
        }, uniquingKeysWith: { first, _ in first })
        var result: [AltStoreSourceApp] = []
        var seen = Set<String>()
        for item in viewModel.sources {
            guard let source = item.source else { continue }
            for app in source.apps {
                guard let latest = app.latestVersion,
                      let installedVersion = installed[app.bundleIdentifier],
                      czfIsVersion(latest.version, newerThan: installedVersion),
                      CZFUpdateIgnore.ignoredVersion(for: app.bundleIdentifier) != latest.version,
                      seen.insert(app.bundleIdentifier).inserted else {
                    continue
                }
                result.append(app)
            }
        }
        return result
    }

    // 可更新名单缓存刷新：算一次、同时写红点。调用点=全部输入
    // 变化处：进页、源变、已装/隐藏变、忽略与 App 打开刷新请求
    private func refreshUpdatableCache() {
        let list = computeUpdatableApps()
        cachedUpdatableApps = list
        updatableCountBadge = list.count
    }

    @MainActor
    private func install(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        if downloadURL.pathExtension.lowercased() == "dylib" {
            // O-4：单装 dylib 不切 Tab，用户还留在源页，失败走
            // 源页 errorMessage 能看见；等 Task 跑完再写。
            Task {
                if let error = await installTweak(from: downloadURL, name: app.name, bundleIdentifier: app.bundleIdentifier) {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        // 3.8.428 设置#25：改写入共享待装队列（见批量处注释），App 页 onAppear 时排空。
        CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: downloadURL, autoReplace: false, preview: true, forceAsNew: false))


    }

    // 文件夹 IPA 安装（3.8.454）：文件夹区移到源页后，点格子
    // 切回 App 页装——与源里 install(app:) 同款：先切 Tab，
    // 再写共享待装队列，App 页 onAppear 时排空进安装队列。
    // autoReplace=false、preview=false，与原来 App 页文件夹
    // 点格子直接 enqueueInstall 同款（不弹预览、不删原文件）。
    @MainActor
    private func czfInstallFolderIpa(_ url: URL) {
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: url, autoReplace: false, preview: false, forceAsNew: false))
    }

    // 源页已装 App 的「新建」：不弹替换/新建选择框，直接按
    // 多开走，App 页照常弹新名字输入框；插件 dylib 没有多开
    // 一说，照旧走插件安装。
    @MainActor
    private func installAsNew(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        if downloadURL.pathExtension.lowercased() == "dylib" {
            Task {
                if let error = await installTweak(from: downloadURL, name: app.name, bundleIdentifier: app.bundleIdentifier) {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        // 3.8.428 设置#25：改写入共享待装队列（见批量处注释），App 页 onAppear 时排空。
        CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: downloadURL, autoReplace: false, preview: true, forceAsNew: true))
    }

    // 低 #10：插件安装文件夹名加上 bundleIdentifier，防同名
    // 插件互相覆盖——原来只用 app.name，两个源里同名不同款的
    // 插件会写进同一个文件夹、互相覆盖。
    // O-4：返回失败的 Error（nil = 成功），不再自己写源页
    // errorMessage——批量时用户已被切到 App 页，源页的
    // errorMessage 写了也看不见；由调用方决定在哪提示。
    @MainActor
    private func installTweak(from url: URL, name: String, bundleIdentifier: String) async -> Error? {
        do {
            let (tempURL, _) = try await CZFVPNManager.hostSession().download(from: url)
            let fm = FileManager.default
            // 按“插件名-包名”建文件夹，不全塞一个。
            let folderURL = LCPath.tweakPath.appendingPathComponent("\(name)-\(bundleIdentifier)")
            if !fm.fileExists(atPath: folderURL.path) {
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
            let destURL = folderURL.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tempURL, to: destURL)
            try await LCUtils.signTweaks(tweakFolderUrl: folderURL, force: true)
            return nil
        } catch {
            return error
        }
    }

    @MainActor
    private func download(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        downloadVersion(url: downloadURL)
    }

    // 3.8.307：源详情页历史版本下载——指定任意版本 URL
    // 下载（不只 latest）。与 download(app:) 同款流程：
    // hostSession 下到文稿目录，再弹分享框；失败走 errorMessage。
    // download(app:) 已改走它，行为不变。
    @MainActor
    private func downloadVersion(url downloadURL: URL) {
        Task {
            do {
                let (tempURL, _) = try await CZFVPNManager.hostSession().download(from: downloadURL)
                let fileName = downloadURL.lastPathComponent
                let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destURL = docsURL.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
                await MainActor.run {
                    shareFile(at: destURL)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func shareFile(at url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        rootVC.present(activityVC, animated: true)
    }
    
    private func toggleExpansion(for id: URL) {
        withAnimation(.easeInOut) {
            if expandedSources.contains(id) {
                expandedSources.remove(id)
            } else {
                expandedSources.insert(id)
            }
        }
    }
    
    func handleURL(url : URL) {
        if url.host == "source" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var sourceUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        sourceUrl = installUrl1
                    }
                }
                if let sourceUrl {
                    // 低 #52：切 Tab 由 dispatchURL 做（LCTabView:220，
                    // host == "source" 时已写 selectedTab = .sources），
                    // 这里重复写已删。
                    // 1：深链添加失败走父级 errorMessage（此时没
                    // sheet 盖着，父级 alert 能正常弹）。
                    // B-11：管理源 sheet 正开着时，父级 alert 盖
                    // 在 sheet 下面会被 UIKit 静默丢弃（#1 在
                    // sheet 内修掉的那类问题，换了个入口又出现）。
                    // 先关 sheet，等它关完再弹错误。
                    Task {
                        if let error = await handleAddSource(sourceUrl) {
                            if isManagingSources {
                                isManagingSources = false
                                try? await Task.sleep(nanoseconds: 400_000_000)
                            }
                            errorMessage = error
                        }
                    }
                } else {
                    // 低 #52：无 url 参数时弹提示，别静默无事。
                    // B-11 同款：sheet 开着时先关再弹。
                    if isManagingSources {
                        isManagingSources = false
                        let msg = "lc.sources.error.invalidUrl".loc
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            errorMessage = msg
                        }
                    } else {
                        errorMessage = "lc.sources.error.invalidUrl".loc
                    }
                }
            }
        }
    }
}

private struct ManageSourcesSheet: View {
    @ObservedObject var viewModel: AltStoreSourcesViewModel
    @Binding var isPresented: Bool
    let onAdd: (String) async -> String?

    @State private var manualSourceValue = ""
    @State private var isAddingManual = false
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    // 1 添加源失败无反馈：sheet 内本地错误，父级 alert 盖在
    // sheet 上会被 UIKit 静默丢弃，这里自己弹。
    @State private var addError: String?
    @FocusState private var isManualFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    if viewModel.sources.isEmpty {
                        Text("lc.sources.empty".loc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { item in
                            HStack(alignment: .top, spacing: 12) {
                                SourceIconView(url: resolvedIconURL(for: item))
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .bold()
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sourcePendingRemoval = item
                                } label: {
                                    Label("lc.sources.removeSource".loc, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("lc.sources.manage.current".loc)
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://example.com/source.json", text: $manualSourceValue)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($isManualFieldFocused)
                        
                        Button {
                            attemptManualAdd()
                        } label: {
                            if isAddingManual {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("lc.sources.addSource".loc)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingManual)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("lc.sources.manage.manual".loc)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("lc.sources.addSource".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) {
                        isPresented = false
                    }
                }
            }
        }
        .confirmationDialog(
            "lc.sources.removeConfirmation.title".loc,
            isPresented: Binding<Bool>(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            presenting: sourcePendingRemoval
        ) { item in
            Button("lc.common.remove".loc, role: .destructive) {
                viewModel.removeSource(item)
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { item in
            Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(item.displayName))
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // 1 添加源失败无反馈：sheet 内本地弹错误，挂在 sheet
        // 自己的层级上，不会被 sheet 盖住吞掉。
        .alert("lc.common.error".loc, isPresented: Binding<Bool>(
            get: { addError != nil },
            set: { if !$0 { addError = nil } })
        ) {
            Button("lc.common.ok".loc, role: .cancel) { addError = nil }
        } message: {
            Text(addError ?? "")
        }
    }
    
    // 低 #7：删第二段冗余查找——ManageSourcesSheet 的 ForEach
    // 本来就是 over viewModel.sources，item 就是列表里的那一项，
    // 再 first(where:) 找回来的是同一个 item，primaryIconURL
    // 与上面那行完全相同（上面已是 nil 才走到这里）；直接返回。
    private func resolvedIconURL(for item: AltStoreSourcesViewModel.SourceItem) -> URL? {
        item.primaryIconURL
    }
    
    private func attemptManualAdd() {
        let trimmed = manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAddingManual else { return }
        isAddingManual = true
        Task {
            // 1：onAdd 返回错误文本（nil = 成功），失败时 sheet
            // 内本地弹，不再指望父级 alert（会被 sheet 盖住吞掉）。
            if let error = await onAdd(trimmed) {
                addError = error
            } else {
                manualSourceValue = ""
                isManualFieldFocused = false
            }
            isAddingManual = false
        }
    }
}

// 源里 App 列表的共享子视图（3.8.407）：列表 section 展开后
// 与网格详情页共用——同一份 50 条上限 +“展开全部”、同一份
// LCSourceAppBanner 行（安装/下载/批量勾选原样）。
struct CZFSourceAppListView: View {
    let source: AltStoreSource
    // U10：勾选键要用的源 feed URL（AltStoreSource 本身没有
    // URL 字段，从调用方 item.url 传进来）。
    let sourceURL: URL
    let filteredApps: [AltStoreSourceApp]
    let isFiltering: Bool
    let onInstall: (AltStoreSourceApp) -> Void
    let onInstallAsNew: (AltStoreSourceApp) -> Void
    let onDownload: (AltStoreSourceApp) -> Void
    let onDownloadVersion: (URL) -> Void
    let isBatchMode: Bool
    let selectedIDs: Set<String>
    let onToggleSelect: (URL, AltStoreSourceApp) -> Void
    @State private var showAllApps = false

    var body: some View {
        VStack(spacing: 12) {
            // 2 列表行身份稳定：ForEach 不用默认 UUID id（每次
            // 解码重新生成，刷新一次全部行换身份、详情 sheet
            // 被关掉），改用包名+版本号的稳定身份。
            ForEach(filteredApps[0..<(showAllApps ? filteredApps.count : min(50, filteredApps.count))], id: \.czfStableID) { app in
                LCSourceAppBanner(app: app, source: source, installAction: onInstall, installAsNewAction: onInstallAsNew, downloadAction: onDownload, downloadVersionAction: onDownloadVersion, isBatchMode: isBatchMode, isSelected: selectedIDs.contains(czfSourceSelectionKey(sourceURL: sourceURL, bundleIdentifier: app.bundleIdentifier)), onToggleSelect: { onToggleSelect(sourceURL, app) })
            }
            if filteredApps.isEmpty {
                if source.apps.isEmpty || isFiltering {
                    Text("lc.sources.section.noApps".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if filteredApps.count > 50 && !showAllApps {
                Text("lc.sources.section.tooManyApps".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("展开全部（共 \(filteredApps.count) 个）") {
                    showAllApps = true
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AltStoreSourceSectionView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let filteredApps: [AltStoreSourceApp]
    let isFiltering: Bool
    let isExpanded: Bool
    let onRefresh: () -> Void
    let onInstall: (AltStoreSourceApp) -> Void
    let onInstallAsNew: (AltStoreSourceApp) -> Void
    let onDownload: (AltStoreSourceApp) -> Void
    // 3.8.307：详情页历史版本下载——指定版本 URL 下
    //（onDownload 只下最新版，历史版本走这条）。
    let onDownloadVersion: (URL) -> Void
    let onRemove: () -> Void
    let toggleExpanded: () -> Void
    let isBatchMode: Bool
    let selectedIDs: Set<String>
    let onToggleSelect: (URL, AltStoreSourceApp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
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
            
            if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if item.source == nil, let host = item.url.host {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            // S1：有缓存 source 且展开/过滤中时先显示 App 列表，
            // 刷新失败只在列表上方贴一行小提示；无缓存或未展开
            // 时仍走下面的大错误块（与旧行为一致）。
            if let source = item.source, isExpanded || isFiltering {
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
            }
        }
    }
}

// 低 #8：两处版本比较统一为这一个——原来 computeUpdatableApps
//（红点名单）用 .numeric compare，LCSourceAppBanner.hasUpdate
// 用手动分段比（isVersion），两处可能打架；抽共用函数，
// 手动分段比（1.10 > 1.9，非数字段按 0 算），两处都调它。
// 版本数字段比较（1.10 > 1.9）。不 private：网格格子
// CZFSourceAppGridCell.hasUpdate 与 LCSourceAppBanner.hasUpdate
// 共用同一份比较（见 CZFSourceGridView.swift）。
func czfIsVersion(_ a: String, newerThan b: String) -> Bool {
    let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
    let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(aParts.count, bParts.count)
    for i in 0..<count {
        let av = i < aParts.count ? aParts[i] : 0
        let bv = i < bParts.count ? bParts[i] : 0
        if av != bv { return av > bv }
    }
    return false
}

// LCSourceAppBanner 不再 private：网格详情页（CZFSourceGridView.swift）
// 复用同一份行（见 CZFSourceAppListView）。
struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let installAction: (AltStoreSourceApp) -> Void
    let installAsNewAction: (AltStoreSourceApp) -> Void
    let downloadAction: (AltStoreSourceApp) -> Void
    // 3.8.307：详情页历史版本下载（指定版本 URL）。
    let downloadVersionAction: (URL) -> Void
    let isBatchMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var sharedModel: SharedModel
    @State private var showDetail = false
    @State private var copiedCardURL = false
    // 忽略/取消忽略后翻一下，强制本行按新状态重画
    @State private var ignoreRefresh = false
    // 机制 2：多开时“打开”绝不静默取首个，多个实例弹实例选择
    @State private var showInstancePicker = false
    
    private var isInstalled: Bool {
        (sharedModel.apps + sharedModel.hiddenApps).contains { $0.appInfo.bundleIdentifier() == app.bundleIdentifier }
    }
    
    // 注意：installedAppModel 只供 hasUpdate 版本比较；启动绝不走它
    //（多开时“打开”按下面 installedAppModels 走单开直启/多开选实例）。
    private var installedAppModel: LCAppModel? {
        (sharedModel.apps + sharedModel.hiddenApps).first(where: { $0.appInfo.bundleIdentifier() == app.bundleIdentifier })
    }

    private var installedAppModels: [LCAppModel] {
        (sharedModel.apps + sharedModel.hiddenApps).filter { $0.appInfo.bundleIdentifier() == app.bundleIdentifier }
    }
    
    // 源里版本比已装版本新 → 有更新（被用户忽略的这个版本不算）
    private var hasUpdate: Bool {
        _ = ignoreRefresh
        guard let sourceVersion = app.latestVersion?.version,
              let installed = installedAppModel else { return false }
        if CZFUpdateIgnore.ignoredVersion(for: app.bundleIdentifier) == sourceVersion { return false }
        return czfIsVersion(sourceVersion, newerThan: installed.appInfo.version())
    }
    
    private var isPluginInstalled: Bool {
        guard let downloadURL = app.latestVersion?.downloadURL,
              downloadURL.pathExtension.lowercased() == "dylib" else { return false }
        // 低 #10：文件夹名与 installTweak 同款“名-包名”；老版只
        // 有 app.name 的文件夹也认（已装的插件不用重装）。
        let newURL = LCPath.tweakPath.appendingPathComponent("\(app.name)-\(app.bundleIdentifier)").appendingPathComponent(downloadURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: newURL.path) { return true }
        let oldURL = LCPath.tweakPath.appendingPathComponent(app.name).appendingPathComponent(downloadURL.lastPathComponent)
        return FileManager.default.fileExists(atPath: oldURL.path)
    }
    
    private var primaryColor: Color {
        guard dynamicColors else { return Color("FontColor") }
        return app.tintColor ?? source.tintColor ?? Color("FontColor")
    }
    
    private var textColor: Color {
        _ = colorScheme == .dark // trigger refresh
        let color = dynamicColors ? primaryColor : Color("FontColor")
        return color.readableTextColor()
    }
    
    private var backgroundColor: Color {
        dynamicColors ? primaryColor.opacity(0.5) : Color("AppBannerBG")
    }
    
    private var metadataText: String {
        guard let latest = app.latestVersion else {
            return app.bundleIdentifier
        }
        if let build = latest.buildVersion, !build.isEmpty {
            return "\(latest.version) (\(build)) • \(app.bundleIdentifier)"
        }
        return "\(latest.version) • \(app.bundleIdentifier)"
    }
    
    private var subtitleText: String {
        if let subtitle = app.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if let developer = app.developerName, !developer.isEmpty {
            return developer
        }
        return ""
    }
    
    var body: some View {
        HStack {
            HStack(alignment: .center, spacing: 12) {
                SourceIconView(url: app.iconURL)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.headline)
                        if app.isBeta {
                            Text("lc.sources.badge.beta".loc.uppercased())
                                .font(.caption2.weight(.heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                    Text(metadataText)
                        .font(.caption)
                        .foregroundColor(textColor)
                        .lineLimit(2)
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.caption2)
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                }
            }
            .allowsHitTesting(false)
            Spacer()
            // 卡片上可见的复制按钮：点一下复制该 App 的下载地址
            if let downloadURL = app.latestVersion?.downloadURL {
                Button {
                    UIPasteboard.general.string = downloadURL.absoluteString
                    copiedCardURL = true
                } label: {
                    Image(systemName: copiedCardURL ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(textColor)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(BasicButtonStyle())
            }
            if isBatchMode {
                Button {
                    onToggleSelect()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title)
                        .foregroundColor(isSelected ? .blue : .gray)
                }
                .buttonStyle(BasicButtonStyle())
                .padding(.trailing, 8)
            } else {
                Button {
                    downloadAction(app)
                } label: {
                    Text("lc.common.download".loc)
                        .bold()
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(height: 32)
                        .minimumScaleFactor(0.1)
                }
                .buttonStyle(BasicButtonStyle())
                .padding(.trailing, 8)
                .frame(idealWidth: 70)
                .frame(height: 32)
                .fixedSize()
                .background(
                    // 下载是可点的主操作：以前平灰和旁边绿/橙
                    // 状态钮同排，看着像被禁用了，改蓝色
                    Capsule().fill(Color.blue)
                )
                .clipShape(Capsule())
                let isDylib = (app.latestVersion?.downloadURL.pathExtension.lowercased() == "dylib")
                if isDylib && isPluginInstalled {
                    Text("lc.common.installed".loc)
                        .bold()
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(height: 32)
                        .minimumScaleFactor(0.1)
                        .padding()
                        .frame(idealWidth: 70)
                        .frame(height: 32)
                        .fixedSize()
                        .background(Capsule().fill(Color.green))
                        .clipShape(Capsule())
                } else if !isDylib && isInstalled && hasUpdate {
                    HStack(spacing: 6) {
                        Button {
                            installAction(app)
                        } label: {
                            Text("更新")
                                .bold()
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .frame(height: 32)
                                .minimumScaleFactor(0.1)
                        }
                        .buttonStyle(BasicButtonStyle())
                        .padding()
                        .frame(idealWidth: 70)
                        .frame(height: 32)
                        .fixedSize()
                        .background(
                            Capsule().fill(Color.orange)
                        )
                        .clipShape(Capsule())
                        Button {
                            installAsNewAction(app)
                        } label: {
                            Text("新建")
                                .bold()
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .frame(height: 32)
                                .minimumScaleFactor(0.1)
                        }
                        .buttonStyle(BasicButtonStyle())
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.purple))
                        .clipShape(Capsule())
                    }
                } else if !isDylib && isInstalled {
                    HStack(spacing: 6) {
                        Button {
                            let matches = installedAppModels
                            if matches.count == 1, let only = matches.first {
                                Task { try? await only.runApp() }
                            } else if matches.count > 1 {
                                showInstancePicker = true
                            }
                        } label: {
                            Text("lc.common.open".loc)
                                .bold()
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .frame(height: 32)
                                .minimumScaleFactor(0.1)
                        }
                        .buttonStyle(BasicButtonStyle())
                        .padding()
                        .frame(idealWidth: 70)
                        .frame(height: 32)
                        .fixedSize()
                        .background(
                            Capsule().fill(Color.green)
                        )
                        .clipShape(Capsule())
                        Button {
                            installAsNewAction(app)
                        } label: {
                            Text("新建")
                                .bold()
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .frame(height: 32)
                                .minimumScaleFactor(0.1)
                        }
                        .buttonStyle(BasicButtonStyle())
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.purple))
                        .clipShape(Capsule())
                    }
                } else {
                    Button {
                        installAction(app)
                    } label: {
                        Text("lc.common.install".loc)
                            .bold()
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .frame(height: 32)
                            .minimumScaleFactor(0.1)
                    }
                    .buttonStyle(BasicButtonStyle())
                    .padding()
                    .frame(idealWidth: 70)
                    .frame(height: 32)
                    .fixedSize()
                    .background(
                        Capsule().fill(dynamicColors ? primaryColor : Color("FontColor"))
                    )
                    .clipShape(Capsule())
                }
            }
        }
        .padding()
        // 低 #9：固定 88pt 改 minHeight——长版本加副标题满载约
        // 107pt，固定高会压内容；内容少时仍是 88，不变矮。
        .frame(minHeight: 88)
        .background {
            RoundedRectangle(cornerSize: CGSize(width: 22, height: 22))
                .fill(backgroundColor)
        }
        .onTapGesture {
            if !isBatchMode {
                showDetail = true
            }
        }
        .contextMenu {
            if hasUpdate, let version = app.latestVersion?.version {
                Button {
                    CZFUpdateIgnore.setIgnored(version, for: app.bundleIdentifier)
                    ignoreRefresh.toggle()
                    // 让源页顺带重算红点和「全部更新」名单（带
                    // 5 分钟节流，不会频繁打网络）
                    NotificationCenter.default.post(name: Notification.Name("CZFRefreshSourcesRequest"), object: nil)
                } label: {
                    Label("忽略此版本", systemImage: "bell.slash")
                }
            }
            if CZFUpdateIgnore.isIgnored(app) {
                Button {
                    CZFUpdateIgnore.setIgnored(nil, for: app.bundleIdentifier)
                    ignoreRefresh.toggle()
                    NotificationCenter.default.post(name: Notification.Name("CZFRefreshSourcesRequest"), object: nil)
                } label: {
                    Label("取消忽略更新", systemImage: "bell")
                }
            }
        }
        .sheet(isPresented: $showDetail) {
            LCSourceAppDetailView(app: app, source: source, onDownloadVersion: downloadVersionAction, onInstall: installAction, onInstallAsNew: installAsNewAction)
        }
        .sheet(isPresented: $showInstancePicker) {
            NavigationView {
                List(installedAppModels, id: \.self) { model in
                    Button {
                        showInstancePicker = false
                        Task { try? await model.runApp() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.appInfo.displayName())
                                .font(.system(size: 15)).bold()
                            Text("容器 \(model.uiSelectedContainer?.name ?? model.uiSelectedContainer?.folderName ?? "") • 版本 \(model.appInfo.version())")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("选择要打开的实例")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showInstancePicker = false }
                    }
                }
            }
        }
    }
}

// LCSourceAppDetailView 不再 private：源页 App 网格格子
//（CZFSourceGridView.swift）点格子/长按菜单也要弹同一份详情 sheet。
struct LCSourceAppDetailView: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    // 3.8.307：历史版本下载——点版本行下载该版本的 URL。
    let onDownloadVersion: (URL) -> Void
    // 3.8.448（用户 16:11 令“点开源应用详情有安装新建
    // 复制”）：详情页顶部加安装/新建/复制三个按钮。
    let onInstall: (AltStoreSourceApp) -> Void
    let onInstallAsNew: (AltStoreSourceApp) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copiedDownloadURL = false

    // 从描述或下载链接里找 GitHub 地址
    private var githubURL: URL? {
        if let downloadURL = app.latestVersion?.downloadURL,
           downloadURL.host?.contains("github") == true {
            return downloadURL
        }
        if let desc = app.description,
           let range = desc.range(of: "https://github.com/[^\\s)\"']+", options: .regularExpression) {
            return URL(string: String(desc[range]))
        }
        return nil
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        SourceIconView(url: app.iconURL)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.headline)
                            if let latest = app.latestVersion {
                                Text("版本 \(latest.version)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Text(app.bundleIdentifier)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // 3.8.448：安装/新建/复制三个按钮（用户 16:11 令）。
                // 安装/新建先关详情单再进队列（与下载按钮同款，
                // 不然切到 App 页时详情单还盖在上面）；复制只写
                // 剪贴板、不关单，按钮变“已复制”给反馈。
                Section {
                    HStack(spacing: 12) {
                        Button {
                            dismiss()
                            onInstall(app)
                        } label: {
                            // 3.8.450（用户 17:47 报“安装按钮不整齐”，
                            // 放大截图实证）：安装用 Label 时图标根本没
                            // 画出来——.borderedProminent 下 Label 的
                            // 图标被吞了，只剩“安装”俩字居中，新建/
                            // 复制是图标+字，三处对不上。改显式 HStack
                            // （Image + Text），图标是独立视图，不走
                            // Label，三处结构完全一致才对齐。
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.down")
                                Text("安装")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            dismiss()
                            onInstallAsNew(app)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.square.on.square")
                                Text("新建")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        if let downloadURL = app.latestVersion?.downloadURL {
                            Button {
                                UIPasteboard.general.string = downloadURL.absoluteString
                                copiedDownloadURL = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: copiedDownloadURL ? "checkmark" : "doc.on.doc")
                                    Text(copiedDownloadURL ? "已复制" : "复制")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                if let developer = app.developerName, !developer.isEmpty {
                    Section(header: Text("开发者")) {
                        Text(developer)
                    }
                }
                if let subtitle = app.subtitle, !subtitle.isEmpty {
                    Section(header: Text("简介")) {
                        Text(subtitle)
                    }
                }
                if let desc = app.description, !desc.isEmpty {
                    Section(header: Text("描述")) {
                        Text(desc)
                            .font(.callout)
                    }
                }
                // 旧版点按跳到该旧版的下载页：原来是 Button 关单
                // 后台静默下载，140MB 下完前全程没反馈，用户
                // 看着就是“点了没反应”。改 NavigationLink 推一
                // 个旧版页（版本号/日期/大小/描述 + 该版下载
                // 地址 + 下载按钮），点下载走“下载地址”栏同款
                // （先关详情单再下该版的包）。
                Section(header: Text("版本信息")) {
                    ForEach(app.versions) { version in
                        NavigationLink {
                            LCSourceAppVersionDetailView(app: app, version: version, onDownloadVersion: onDownloadVersion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.version)
                                    .font(.subheadline).bold()
                                if let date = version.releaseDate {
                                    Text(date, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let size = version.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let vdesc = version.localizedDescription, !vdesc.isEmpty {
                                    Text(vdesc)
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if let downloadURL = app.latestVersion?.downloadURL {
                    Section(header: Text("下载地址")) {
                        // 3.8.307：下载地址改走应用内下载——原来
                        // 是 Link，点开 Safari 下不了 IPA；现在
                        // 点一下直接下最新版（与行上下载同款）。
                        Button {
                            dismiss()
                            onDownloadVersion(downloadURL)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                Text(downloadURL.absoluteString)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                    }
                }
                if let githubURL {
                    Section {
                        Link(destination: githubURL) {
                            HStack {
                                Image(systemName: "link")
                                Text("在 GitHub 查看")
                            }
                        }
                    }
                }
                Section(header: Text("来源")) {
                    Text(source.name)
                }
            }
            .navigationTitle("应用详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// 旧版下载页：版本行 NavigationLink 推进来，只看这一个旧版、
// 只下这一个旧版的包（downloadURL 是该版自己的，不是最新版）。
// 下载按钮走“下载地址”栏同款：先关详情单再下载，分享框从
// rootVC 弹出，不与详情单叠在一起。
private struct LCSourceAppVersionDetailView: View {
    let app: AltStoreSourceApp
    let version: AltStoreSourceAppVersion
    let onDownloadVersion: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.headline)
                    Text("版本 \(version.version)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let date = version.releaseDate {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let size = version.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let vdesc = version.localizedDescription, !vdesc.isEmpty {
                        Text(vdesc)
                            .font(.callout)
                    }
                }
                .padding(.vertical, 2)
            }
            Section(header: Text("下载地址")) {
                Button {
                    dismiss()
                    onDownloadVersion(version.downloadURL)
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text(version.downloadURL.absoluteString)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
        }
        .navigationTitle(version.version)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// 源图标磁盘缓存：裸 AsyncImage 没有落盘，源页每次
// 重建、每行图标都重新联网下载。内存（NSCache，
// 200 个上限）+ Caches/CZFSourceIcons 落盘，文件名
// 是链接的 base64url（跨启动稳定，不用 hashValue），
// 失败仍回占位图，行为与原来一致。
// O-16：磁盘只加 TTL 与数量上限——30 天过期重下（同 URL
// 换图不再永显示旧图），写完顺手剪掉最旧的、文件数不超
// 200 个；内存缓存不动，不大改。
private final class CZFSourceIconCache {
    static let shared = CZFSourceIconCache()
    private static let diskTTL: TimeInterval = 30 * 24 * 3600
    private static let diskMaxCount = 200
    // C-5：源图标来自任意 URL、尺寸不可控，全分辨率解码进内存
    // 会爆内存。降采样目标：最大显示 64pt（详情页）/网格格子
    // 约 110pt，@3x ≈ 330px，384 留余量；内存上限 50MB。
    private static let thumbnailMaxPixelSize = 384
    private static let memoryTotalCostLimit = 50 * 1024 * 1024
    private let memory = NSCache<NSString, UIImage>()
    private let ioQueue = DispatchQueue(label: "czf.sourceicon.cache", qos: .utility)
    private init() {
        memory.countLimit = 200
        memory.totalCostLimit = Self.memoryTotalCostLimit
    }
    private func diskURL(for url: URL) -> URL? {
        let name = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CZFSourceIcons", isDirectory: true)
            .appendingPathComponent(name)
    }
    private func diskData(for url: URL) async -> Data? {
        guard let dest = diskURL(for: url) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            ioQueue.async { cont.resume(returning: try? Data(contentsOf: dest)) }
        }
    }
    // C-5：按显示尺寸降采样后再缓存，不把原图全分辨率解进内存。
    // 降采样失败（非图片数据/缩略图建不出）时回落到原 UIImage(data:)，
    // 图标不直接消失。cost 按像素数计（RGBA 每像素 4 字节）。
    private static func decodedImage(from data: Data) -> UIImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: thumb, scale: UIScreen.main.scale, orientation: .up)
            }
        }
        return UIImage(data: data)
    }
    private static func pixelCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.width * cg.height * 4
    }
    private func store(_ image: UIImage, forKey key: NSString) {
        memory.setObject(image, forKey: key, cost: Self.pixelCost(of: image))
    }
    func load(url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let hit = memory.object(forKey: key) { return hit }
        // 磁盘命中先验 TTL：过期当未命中，重新下载覆盖旧文件；
        // 文件不存在也算过期（直接走下载）。
        if !(await diskIsExpired(for: url)),
           let data = await diskData(for: url), let img = Self.decodedImage(from: data) {
            store(img, forKey: key)
            return img
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = Self.decodedImage(from: data) else { return nil }
        store(img, forKey: key)
        if let dest = diskURL(for: url) {
            ioQueue.async {
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: dest, options: .atomic)
                // 写完顺手剪掉最旧的，磁盘文件数不超过上限。
                Self.pruneDisk(base: dest.deletingLastPathComponent(), maxCount: Self.diskMaxCount)
            }
        }
        return img
    }

    // 磁盘文件按修改时间验 30 天 TTL（见 load）。
    private func diskIsExpired(for url: URL) async -> Bool {
        guard let dest = diskURL(for: url) else { return true }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            ioQueue.async {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
                      let mtime = attrs[.modificationDate] as? Date else {
                    cont.resume(returning: true)
                    return
                }
                cont.resume(returning: Date().timeIntervalSince(mtime) > Self.diskTTL)
            }
        }
    }

    // 磁盘文件数超上限时删最旧的（按修改时间），只在写缓存
    // 后顺手跑一次，不另起定时任务；刚写的文件最新，不会
    // 被自己删掉。
    private static func pruneDisk(base: URL, maxCount: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]),
              files.count > maxCount else { return }
        let sorted = files.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return d0 < d1
        }
        for old in sorted.prefix(files.count - maxCount) {
            try? fm.removeItem(at: old)
        }
    }
}

// SourceIconView 不再 private：网格单元/详情页（CZFSourceGridView.swift）
// 与管理源 sheet 共用同一份图标加载。
struct SourceIconView: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await CZFSourceIconCache.shared.load(url: url)
        }
    }

    private var placeholder: some View {
        // 3.8.412：DefaultIcon 是白底细线框，白底上几乎看不见，
        // 图标加载失败的格子就剩一片白（用户 11-11 截图）。
        // 改灰底 + 系统 App glyph，加载失败也有个可见的灰格子。
        ZStack {
            Color(uiColor: .systemGray5)
            GeometryReader { geo in
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    // 低 #12：留白按图标尺寸比例算——原来固定
                    // .padding(12)，28pt 组头里 glyph 只剩约 4pt，
                    // 几乎看不见；按边长 30% 留白（28pt → 垫约
                    // 8pt、glyph 约 12pt；60pt → glyph 约 24pt）。
                    .padding(max(geo.size.width * 0.3, 2))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
