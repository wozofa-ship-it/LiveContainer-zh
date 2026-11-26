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

    // L175：版本行身份——同 B-9/czfStableID：id 是每次解码都换的
    // UUID，详情页 ForEach(app.versions) 用它时，源刷新一到就
    // 重建全部版本行，已点进的旧版详情页被顶回详情根（L174-1
    // 同款）。身份只用版本号 + build，不进下载地址——地址改了
    // 也不换身份；同一版本 + build 列两次时由解码处去重。
    var czfStableID: String {
        version + "|" + (buildVersion ?? "")
    }

    // 3.8.649（F2）：版本 + build 拼法——只升 build 的更新
    //（2.0/build 50 → 2.0/build 100）在详情页是两个看不出区别的
    //“2.0”；详情页版本行与旧版页两处行文案都走这里。
    var czfVersionWithBuild: String {
        buildVersion.map { "\(version) (\($0))" } ?? version
    }
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
    // 3.8.658（F2）：停用源集合——暂停检查更新的源 URL（absoluteString）。
    // 留着源、留着缓存内容，只是不再自动联网刷它、也不再算进可更新
    // 名单；单源手动刷新不拦（显式点的那次仍可刷）。与源列表同库
    // 同款（UserDefaults.standard，[String]），删源时顺带清记录，
    // 免得同 URL 重加回来还停着。@Published：组头 Menu 文案与
    // “已暂停”小字跟它走；视图另有 onChange 重算可更新缓存。
    @Published private(set) var disabledSourceURLs: Set<String> = []
    private let disabledKey = "CZFDisabledSourceURLs"

    // 3.8.660（F2）：各源上次成功检查时间——[源 URL: Double 秒数]，
    // 一个字典键，不按源建多个 key；Double 秒数（@AppStorage 的
    // Date 值类型只在 iOS 18+ 可用，见 :980 同款教训）。@Published：
    // 组头文案跟它走；删源时顺带清记录（同 disabledSourceURLs）。
    @Published private(set) var czfLastCheckDates: [String: Double] = [:]
    private let lastCheckDatesKey = "CZFSourceLastCheckDates"

    func isSourcePaused(_ url: URL) -> Bool {
        disabledSourceURLs.contains(url.absoluteString)
    }

    func togglePauseSource(_ url: URL) {
        let key = url.absoluteString
        if disabledSourceURLs.contains(key) {
            disabledSourceURLs.remove(key)
        } else {
            disabledSourceURLs.insert(key)
        }
        persistDisabledSources()
    }

    private func persistDisabledSources() {
        UserDefaults.standard.set(Array(disabledSourceURLs), forKey: disabledKey)
    }

    private func loadDisabledSources() {
        let stored = UserDefaults.standard.array(forKey: disabledKey) as? [String] ?? []
        disabledSourceURLs = Set(stored)
    }

    private func persistLastCheckDates() {
        UserDefaults.standard.set(czfLastCheckDates, forKey: lastCheckDatesKey)
    }

    private func loadLastCheckDates() {
        let stored = UserDefaults.standard.dictionary(forKey: lastCheckDatesKey) ?? [:]
        czfLastCheckDates = stored.compactMapValues { $0 as? Double }
    }

    /// 某源一次检查成功后记戳（与全局 CZFSourceLastCheckDate 同处写，
    /// 同口径：数据未变也算查过一次，失败不写）。
    private func czfMarkSourceChecked(_ url: URL) {
        czfLastCheckDates[url.absoluteString] = Date().timeIntervalSince1970
        persistLastCheckDates()
    }

    /// 某源上次成功检查文案——复用全局脚注的 lc.sources.lastChecked
    /// 格式串；从未成功过返回“尚未检查”（全局脚注同款硬编码文案）。
    func czfLastCheckedText(for url: URL) -> String {
        guard let timestamp = czfLastCheckDates[url.absoluteString], timestamp > 0 else { return "尚未检查" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "lc.sources.lastChecked".localizeWithFormat(formatter.string(from: Date(timeIntervalSince1970: timestamp)))
    }

    private let cacheDirectoryName = "AltStoreSourceCache"
    private var hasLoadedSources = false
    
    func loadSourcesIfNeeded() {
        guard !hasLoadedSources else { return }
        hasLoadedSources = true
        loadStoredSources()
        Task {
            // O-28：缓存解码先于刷新（顺序与原来同步版一致：
            // 缓存先显示，刷新再盖新版），都放后台，解完回主线程填。
            await loadStoredCaches()
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
        // 3.8.658（F2）：删源顺带清停用记录，同 URL 重加回来不还停着。
        disabledSourceURLs.remove(item.url.absoluteString)
        persistDisabledSources()
        // 3.8.660（F2）：删源顺带清该源的上次检查戳，同款。
        czfLastCheckDates.removeValue(forKey: item.url.absoluteString)
        persistLastCheckDates()
        persistSources()
        removeCache(for: item.url)
    }
    
    func refreshSource(_ item: SourceItem) async {
        await refreshSource(url: item.url)
    }
    
    /// 3.8.660（B2）：返回是否至少一源成功——自动刷新节流戳失败也
    /// 消耗，断网打开后 5 分钟内不重试；成功才写戳（见
    /// autoRefreshSourcesIfNeeded）。成功判据复用下面全局戳同款。
    /// @discardableResult：其余 3 处调用点（:229、:1276、坞 :5330）
    /// 不关心返回值，不改行为。
    @discardableResult
    func refreshAllSources() async -> Bool {
        guard !sources.isEmpty else {
            return false
        }
        // O-10：重入守卫——顶栏刷新、组头刷新、管理源添加后
        // 刷新都能调这里，慢源拖住整组时再点会并行跑两组，
        // 两组 defer 各置一次 false，状态提前归零、刷新
        // 指示器提前灭。已在刷直接返回，不改刷新逻辑本身。
        guard !isRefreshingAll else {
            return false
        }
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        // 原来 for 循环一个个 await：源多时等待时间累加。
        // 改成每 4 个一组并行刷：组内网络请求并行，组间顺序。
        // refreshSource 是 MainActor 隔离的，sources 的读写
        // 都在主 actor 上串行，网络 await 会挂起让出，不会
        // 出现多任务同时改数组的竞态；缓存已在 loadStoredSources
        // 里先显示，刷新期间旧内容不清空，失败只记 error。
        // 3.8.658（F2）：停用源不进自动刷新——只刷未停用的源；
        // 单源手动刷新 refreshSource(url:) 不拦。
        let urls = sources.map({ $0.url }).filter { !disabledSourceURLs.contains($0.absoluteString) }
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
        // 3.8.653（F2）：上次检查更新时间——至少一个源本次成功才写；
        // 单源成功已在 refreshSource 成功处写过，这里是整组刷新的
        // 收口；全失败（断网）不写，时间戳才诚实。
        // 3.8.658（F2）：停用源不算——全停用时一个都没查，时间戳不写。
        let czfRefreshSucceeded = sources.contains(where: { $0.error == nil && !disabledSourceURLs.contains($0.url.absoluteString) })
        if czfRefreshSucceeded {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "CZFSourceLastCheckDate")
        }
        return czfRefreshSucceeded
    }
    
    private func refreshSource(url: URL) async {
        guard let index = sources.firstIndex(where: { $0.url == url }) else {
            return
        }
        sources[index].isLoading = true
        sources[index].error = nil
        // O-28：缓存读盘放 detached——原来同步 Data(contentsOf:)
        // 在主线程上。cachedData 是 nonisolated 纯读盘，无状态。
        let previousData = await Task.detached { self.cachedData(for: url) }.value
        do {
            let (source, data) = try await AltStoreSourceLoader.load(from: url)
            guard let sourceIndex = sources.firstIndex(where: { $0.url == url }) else {
                return
            }
            // L147-1：数据没变就跳过重写缓存——但只在内存里
            // 已有解出的 source 时才跳。缓存解不出（缓存损坏、
            // 或更新后解码变严）时 source 是 nil，旧写法照样跳过、
            // source 永远是 nil：行只剩名字 + host，无 App、无错、
            // 不转圈，刷新多少次都一样，只能删源重加才好。
            // 新数据反正已在 load 里解过，直接用它填上；解不出
            // 就走下面的 catch 报错，不再静默空白。
            if let previousData, previousData == data, sources[sourceIndex].source != nil {
                sources[sourceIndex].isLoading = false
                // 3.8.653（F2）：数据未变也是查过一次（联网拉到了新数据）。
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "CZFSourceLastCheckDate")
                // 3.8.660（F2）：该源本次成功也记戳。
                czfMarkSourceChecked(url)
                return
            }
            sources[sourceIndex].source = source
            sources[sourceIndex].isLoading = false
            storeCache(data, for: url)
            // 3.8.653（F2）：单源刷新成功也算一次检查（组头单刷同款）。
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "CZFSourceLastCheckDate")
            // 3.8.660（F2）：该源本次成功也记戳。
            czfMarkSourceChecked(url)
        } catch {
            if let sourceIndex = sources.firstIndex(where: { $0.url == url }) {
                sources[sourceIndex].error = error.localizedDescription
                sources[sourceIndex].isLoading = false
            }
        }
    }
    
    // L113-1：坞源面板与源页各持一个 ViewModel 实例，面板覆盖层常驻、
    // @StateObject 只在首次创建时建一次；旧版这里只在 init 跑一次，
    // 之后源页增删源只写 UserDefaults，面板的 sources 永远是旧名单——
    // 新源进不了面板、删掉的源还留在面板里继续刷。改成按 URL 合并：
    // 已有的条目（含已解出的 source）原样保留，新 URL 以 isLoading
    // 追加（面板显示转圈，等下一次刷新填数），已删的 URL 摘掉。
    // init 时 sources 为空，与旧行为完全一致。面板每次调出前调一次
    // reloadStoredSources() 再刷新。
    private func loadStoredSources() {
        // 3.8.658（F2）：停用集合随源列表一起读回。
        loadDisabledSources()
        // 3.8.660（F2）：各源上次检查戳随源列表一起读回。
        loadLastCheckDates()
        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: defaultsKey) as? [String] ?? []
        // 3.8.553（L83）：已存的重复源（归一前加进来的两种写法）
        // 读时先归一再去重，留第一条——只按原字符串去重拦不住
        // …/repo.json 与 …/repo.json/ 这种旧重复；下次增删源时
        // persistSources 会把归一去重后的写回。
        var seen = Set<String>()
        let urls = stored.compactMap { URL(string: $0) }
            .map { stripTrailingSlash(from: $0) }
            .filter { seen.insert($0.absoluteString).inserted }
        self.sources = urls.map { url in
            if let existing = sources.first(where: { $0.url == url }) {
                return existing
            }
            return SourceItem(url: url, isLoading: true)
        }
    }

    /// L113-1：面板调出前重读已存源名单（见 loadStoredSources）。
    func reloadStoredSources() {
        loadStoredSources()
    }

    /// O-28：已存源缓存读盘 + 解码放后台——原来 init 里同步全在主
    /// 线程。解完回主线程逐条填 source，只填仍为空的：刷新可能
    /// 已写入新版，不拿旧缓存盖掉。decode 是静态纯函数、每轮
    /// 自带格式器，线程安全。
    private func loadStoredCaches() async {
        let urls = sources.map { $0.url }
        let decoded = await Task.detached {
            urls.compactMap { url -> (URL, AltStoreSource)? in
                guard let data = self.cachedData(for: url),
                      let cachedSource = try? AltStoreSourceLoader.decode(from: data, baseURL: url) else { return nil }
                return (url, cachedSource)
            }
        }.value
        for (url, cachedSource) in decoded {
            guard let index = sources.firstIndex(where: { $0.url == url }),
                  sources[index].source == nil else { continue }
            sources[index].source = cachedSource
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
            return stripTrailingSlash(from: URL(fileURLWithPath: trimmed))
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return stripTrailingSlash(from: url)
        }
        if let httpsURL = URL(string: "https://\(trimmed)") {
            return stripTrailingSlash(from: httpsURL)
        }
        return nil
    }

    /// 3.8.553（L83）：末尾斜杠归一——同一源写成两种样子
    /// （…/repo.json 与 …/repo.json/）会被当成两个源：addSource
    /// 的去重是精确 URL 相等，拦不住，源列表出现两行、刷新拉
    /// 两遍、源页 App 也出现两份（跨源去重只在单源解码内做，
    /// B-10）。根路径 "/" 本身保留；query/fragment 不动。
    private func stripTrailingSlash(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        return components.url ?? url
    }
}

private extension AltStoreSourcesViewModel {
    // O-28：读盘四件套标 nonisolated——只用 FileManager + SHA256 +
    // Data 读写，无共享可变状态，可在 detached 任务里跑；
    // ensureCacheDirectory 并发建目录安全（已存在不报错）。
    // storeCache/removeCache 仍在 MainActor 上调，不动。
    nonisolated func cachedData(for url: URL) -> Data? {
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
    
    nonisolated func cacheFileURL(for url: URL) -> URL? {
        guard let directory = ensureCacheDirectory() else { return nil }
        let fileName = cacheFileName(for: url)
        return directory.appendingPathComponent(fileName)
    }
    
    nonisolated func ensureCacheDirectory() -> URL? {
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
    
    nonisolated func cacheFileName(for url: URL) -> String {
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
        // 3.8.547（L181）：源 JSON 会变，走 freshData 绕开 URLCache 取新鲜数据。
        let (data, response) = try await CZFVPNManager.freshData(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "AltStoreSource", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
        }
        // O-28：解码放 detached——原来网络 await 回来后 continuation
        // 回到调用方 MainActor，JSON 解码 + 逐 App buildApp + 去重
        // 全在主线程。decode 是静态纯函数、每轮自带格式器，线程安全；
        // 解完回主线程写 sources，调用方语义不变。
        let source = try await Task.detached { try decode(from: data, baseURL: url) }.value
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
        // 3.8.549（L79）：versions 不按 JSON 顺序信——源格式约定是
        // 新版在前，但手写源常把新版追加在末尾（用户中文源 83 个
        // App 里 2 个升序、6 个乱序，实证）；latest = versions.first
        // 会取到旧版，安装、下更新检测、历史列表全错。解码时按
        // （版本，build）降序排好——合规源本来就是降序、排序是空
        // 操作；历史列表也跟着新版在前。比较器就是 hasUpdate 同款
        // czfIsNewerVersion（版本不等比版本、相等比 build），无新语义。
        let sorted: [AltStoreSourceAppVersion] = versions.compactMap { version in
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
        }.sorted { a, b in
            czfIsNewerVersion(a.version, build: a.buildVersion, newerThan: b.version, installedBuild: b.buildVersion)
        }
        // L175：按版本身份去重（留第一条）——ForEach(app.versions)
        // 的身份走 czfStableID（版本号 + build），源里同一版本 +
        // build 列两次时 ForEach 撞 id 的行为未定义（B-10 同款），
        // 解码处一次去重；latest = versions.first 不受影响。
        var seenVersionIDs = Set<String>()
        return sorted.filter { seenVersionIDs.insert($0.czfStableID).inserted }
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
    // 3.8.692（B3）：忽略键改为“版本|build”——只升 build 的更新
    // （2.0/b50 → 2.0/b100）原来只记短版本号，忽略后新 build
    // 永不再提醒。build 为空时只记短版本；分隔符 `|` 不会出
    // 现在版本号/build 里。
    static func ignoredKey(version: String, build: String?) -> String {
        if let build, !build.isEmpty {
            return "\(version)|\(build)"
        }
        return version
    }
    // 3.8.692（B3）：存的值与当前最新版比对——新条目（带 `|`）
    // 版本与 build 都对上才算忽略；老条目（只有短版本号）按
    // “忽略该短版本全部 build”通配保留，不打扰已忽略的用户。
    static func isIgnoredStored(_ stored: String?, version: String, build: String?) -> Bool {
        guard let stored else { return false }
        if stored.contains("|") {
            return stored == ignoredKey(version: version, build: build)
        }
        return stored == version
    }
    static func isIgnored(_ app: AltStoreSourceApp) -> Bool {
        guard let latest = app.latestVersion else { return false }
        return isIgnoredStored(ignoredVersion(for: app.bundleIdentifier), version: latest.version, build: latest.buildVersion)
    }

    // 3.8.702（F2）：“归一 Bundle ID → 最新版本|build”字典——源页
    // refreshUpdatableCache 顺带写、App 页长按菜单读（0 新 key 之外
    // 只加 CZFUpdatableLatestVersions 这一个）。
    // 形态照抄 CZFUpdatableBundleIDs 的逗号串：`归一ID=版本|build`
    // 逗号拼；`=` 与 `,` 不会出现在包名/版本号/build 里。
    // 字典覆盖可更新 + 已忽略但有新版的 App：忽略的 App 不在可更新
    // 名单里，只从名单取就永远取不到已忽略那份的最新版，App 页
    // “取消忽略更新”也就无从判定。
    static func latestVersionDict(from string: String) -> [String: String] {
        var dict: [String: String] = [:]
        for entry in string.split(separator: ",") {
            let kv = entry.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            dict[String(kv[0])] = String(kv[1])
        }
        return dict
    }
    static func latestVersionsString(from dict: [String: String]) -> String {
        dict.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
    // 字典值（即 ignoredKey 的产物）拆回版本/build，供
    // isIgnoredStored 比对；无 `|` 时只有短版本、build 为 nil。
    static func splitIgnoredKey(_ key: String) -> (version: String, build: String?) {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return (key, nil) }
        return (String(parts[0]), String(parts[1]))
    }
}

/// 「跳过更新」的持久存储：键 CZFSkippedUpdates 存 [stableID: 版本号]。
/// 跳过只藏更新清单与红点，图标更新角标（hasUpdate）不受影响——
/// 与 CZFUpdateIgnore（忽略此版本，连角标一起藏）不同，别混用。
/// 跳过当且仅当源里最新版本与 build 都等于记的（3.8.698 B1：
/// 只升 build 也是新版本，跳过后新 build 要重新提醒）；源出了
/// 新版本就重新提醒。
enum CZFSkippedUpdate {
    private static let key = "CZFSkippedUpdates"

    static func skippedVersions() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    static func skippedVersion(for stableID: String) -> String? {
        skippedVersions()[stableID]
    }

    static func setSkipped(_ version: String?, for stableID: String) {
        var dict = skippedVersions()
        if let version {
            dict[stableID] = version
        } else {
            dict.removeValue(forKey: stableID)
        }
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func isSkipped(_ app: AltStoreSourceApp) -> Bool {
        guard let latest = app.latestVersion else { return false }
        // 3.8.698（B1）：照抄 25 轮 B3（CZFUpdateIgnore）——跳过
        // 键改记“版本|build”，只升 build 的更新跳过后新 build
        // 重新提醒；老条目（无 `|`）按短版本通配保留，与 B3 同款。
        return CZFUpdateIgnore.isIgnoredStored(skippedVersion(for: app.czfStableID), version: latest.version, build: latest.buildVersion)
    }

    /// 清过期条目：已装版本已 ≥ 跳过记的版本（已更新过了），
    /// 该条目永不再命中，读时顺手删掉，别让 UserDefaults 无限长。
    /// 未装的 App 保守保留（重装旧版回来时跳过仍有效）。
    /// 3.8.698（B1）：跳过值现为“版本|build”——pruneStale 只比
    /// 版本段（czfIsVersion 按 `.` 切，Int("0|100") ?? 0 得 0），
    /// 比较结果不变；只升 build 后条目多留一阵，直到版本号越过
    /// 才清，属无害残留（与 B3 老条目同款），不用改。
    static func pruneStale(installed apps: [LCAppModel]) {
        // L149-1：按包名收全部已装分身的版本，不只取首个——
        // 只按首个分身判会误删：新分身排在前时条目被删，之后
        // 删掉新分身、旧分身顶上来，更新行重现、跳过却丢了。
        var installedVersions: [String: [String]] = [:]
        for app in apps {
            // 3.8.637（B1）：已装键是个人 ID 改写后的 ID（`原ID.团队ID`）、
            // 跳过表键是源里的原始 ID，精确比对永不命中、过期条目永不清。
            // 两边都归一到去队尾段的 ID 再比对。
            installedVersions[czfNormalizedBundleID(app.appInfo.bundleIdentifier() ?? ""), default: []]
                .append(app.appInfo.version() ?? "")
        }
        var dict = skippedVersions()
        let before = dict.count
        dict = dict.filter { stableID, skippedVersion in
            let bundleId = String(stableID.split(separator: "|", maxSplits: 1).first ?? Substring(stableID))
            guard let versions = installedVersions[czfNormalizedBundleID(bundleId)], !versions.isEmpty else { return true }
            // 3.8.562（L93）：原来只留“跳过版本比已装新”的条目——
            // 已装与跳过版本号相等时（只升 build 的更新：已装
            // 2.0/build 50、源最新 2.0/build 100，用户跳过 2.0）
            // 也删条目，下次刷新更新又冒出来，跳过等于没点。
            // 跳过是按版本号记的，与 CZFUpdateIgnore 同款语义：
            // 只有已装版本号严格新于跳过版本（已更新过去了）
            // 才删；相等留着，源出了更新的版本号再提醒。
            // L149-1：全部已装分身都严格新于跳过版本才删；单分身时与原来一字相同。
            return !versions.allSatisfy { czfIsVersion($0, newerThan: skippedVersion) }
        }
        if dict.count != before {
            UserDefaults.standard.set(dict, forKey: key)
        }
    }
}

// U10 批量勾选键：源 feed URL + czfStableID（包名 + 名字）。
// 同一 App 在两个源里是两条记录，只用包名会两边同打勾；
// 同源同包名双变体（汉化版/原版）名字不同，键也不同，不再
// 共用一个键（3.8.664 B3：原来只拼 bundleIdentifier，双变体
// 勾一个等于勾两个、批量安装去重又静默丢一个）。
// 源标识用 SourceItem 的 feed URL（item.url / item.id，
// 稳定唯一），不用 AltStoreSource.identifier（可选、
// 可能为空/重复）也不用 AltStoreSource.id（每次解码
// 新 UUID，不稳定）。
func czfSourceSelectionKey(sourceURL: URL, app: AltStoreSourceApp) -> String {
    "\(sourceURL.absoluteString):\(app.czfStableID)"
}

// 3.8.664（B3/F1）：已勾去重计数——按 czfStableID（包名 + 名字）
// 去重后的条数，与 batchInstallSelected 实际装的数一致
//（S-13 同款口径：同一 App 在两个源里各勾一次只装一次，
// 只数 selectedIDs 会多算；同源双变体名字不同、各算一个）。
func czfDedupedSelectedCount(sources: [AltStoreSourcesViewModel.SourceItem], selectedIDs: Set<String>) -> Int {
    var seen = Set<String>()
    var count = 0
    for item in sources {
        guard let source = item.source else { continue }
        for app in source.apps where selectedIDs.contains(czfSourceSelectionKey(sourceURL: item.url, app: app)) {
            if seen.insert(app.czfStableID).inserted { count += 1 }
        }
    }
    return count
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
// 返回错误文本（nil = 已接单）。S-3：失败反馈进 sheet 内显示——
// onUpdateOne 的错误（无下载链接、dylib 安装失败）由 sheet
// 自己的 sheetError alert 弹，不再写父级 errorMessage（sheet
// 盖着时父级 alert 会被 UIKit 静默丢弃，见 ManageSourcesSheet
// 的 addError 同款做法）。
// 跳过（3.8.454，用户 03:16 令“更新这里也可以选择不更新”）：
// 每行左滑出“跳过”，点了把该 App 从本次更新名单剔除（不装、
// 不进批量队列）；跳过记版本持久化，源出新版本才重新出现，
// 不是永久不更新。onSkip 只删名单，不动已装 App。
struct CZFUpdatableAppsSheet: View {
    let apps: [AltStoreSourceApp]
    let onUpdateOne: (AltStoreSourceApp) async -> String?
    let onUpdateAll: () -> Void
    let onSkip: (AltStoreSourceApp) -> Void
    // 3.8.702（B1）：手动刷新——走父级已有的 viewModel.refreshAllSources
    //（@MainActor、带 O-10 重入守卫，手动刷新不受 300 秒节流，顶栏刷新
    // 同款调用），不要新造刷新路。调用点只有一处（czfUpdatableAppsSheet）。
    let onRefresh: () async -> Void
    // 3.8.702（B1）：名单新鲜度——读与 App 页同一把 key
    // CZFLastSourceAutoRefresh（0 新 key），300 秒阈值与文案照抄
    // LCAppListView 的 czfUpdatableListStale/czfUpdatableStaleText。
    @AppStorage("CZFLastSourceAutoRefresh") private var czfLastSourceAutoRefresh: Double = 0
    private static let czfRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    private var czfUpdatableListStale: Bool {
        guard czfLastSourceAutoRefresh > 0 else { return true }
        return Date().timeIntervalSince1970 - czfLastSourceAutoRefresh > 300
    }
    private var czfUpdatableStaleText: String {
        guard czfLastSourceAutoRefresh > 0 else { return "可更新名单尚未检查过" }
        let checkedDate = Date(timeIntervalSince1970: czfLastSourceAutoRefresh)
        return "可更新名单是\(Self.czfRelativeFormatter.localizedString(for: checkedDate, relativeTo: Date()))检查的"
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel: SharedModel
    // O-4：行内“已入队”状态——点过“更新”的行先标已入队，
    // 父级同时把它从 cachedUpdatableApps 剔除，行随后消失；
    // 父级名单没刷新时，已入队的行至少显示状态、不让重
    // 复点。
    @State private var updatingIDs: Set<String> = []
    // S-3：sheet 内本地错误——onUpdateOne 返回的错误文本
    // 在这里弹（挂在 sheet 自己的层级上，不会被 sheet 盖
    // 住吞掉；与 ManageSourcesSheet.addError 同款）。
    @State private var sheetError: String?

    private func installedVersion(for app: AltStoreSourceApp) -> String {
        // 3.8.637（B1）：同款归一——个人 ID 改写后的已装 ID 与源里的
        // 原始 ID 精确比对查不到，更新单里的“已装版本”恒为空。
        // 3.8.649（B2）：多分身取最旧实例的版本——首个实例由扫描
        // 顺序定，显示较新的分身会把旧分身的更新藏起来。
        let matches = (sharedModel.apps + sharedModel.hiddenApps)
            .filter { czfSameBundleID($0.appInfo.bundleIdentifier() ?? "", app.bundleIdentifier) }
        // 3.8.690（B1）：只升 build 的更新在清单里显示成“2.0 → 2.0”——
        // 已装一侧原来只取 version()，build 丢了；与新版一侧同款拼
        // “版本 (build)”（无 build 时回落纯版本号，与原来一字相同）。
        guard let oldest = matches.min(by: { a, b in
            czfIsNewerVersion(b.appInfo.version() ?? "", build: b.appInfo.buildVersion(), newerThan: a.appInfo.version() ?? "", installedBuild: a.appInfo.buildVersion())
        }) else { return "" }
        let version = oldest.appInfo.version() ?? ""
        if let build = oldest.appInfo.buildVersion(), !build.isEmpty {
            return "\(version) (\(build))"
        }
        return version
    }

    var body: some View {
        // 部署目标 iOS 15：NavigationStack 是 iOS 16+，用
        // NavigationView + Stack 样式（与本文件其余 sheet 同款）。
        NavigationView {
            List {
                // 3.8.702（B1）：过期提示条——App 页有提示、这里没有，
                // 同一份过期缓存；只在过期时显示，样式照抄 App 页
                // czfUpdatableStaleHint（三角 + 文案 + 刷新按钮）。
                if czfUpdatableListStale {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(czfUpdatableStaleText)
                                .font(.footnote)
                            Spacer()
                            Button("刷新") {
                                Task { @MainActor in await onRefresh() }
                            }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                ForEach(apps, id: \.czfStableID) { app in
                    HStack(spacing: 12) {
                        SourceIconView(url: app.iconURL)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .lineLimit(1)
                            Text("\(installedVersion(for: app)) → \(app.latestVersion?.czfVersionWithBuild ?? "")")
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
                                // S-3：先标已入队防重复点（dylib 要等装完
                                // 才知道成败，按钮不能一直敞着）；失败时
                                // 恢复行、错误进 sheet 内 alert。
                                updatingIDs.insert(app.czfStableID)
                                Task {
                                    let error = await onUpdateOne(app)
                                    // 3.8.544（L161）：成功时也要摘 ID——原来只在失败时摘，
                                    // 成功那路行已从名单剔除、ID 却留在集合里；源再刷新、
                                    // 同一 App 出新版本重进名单时，行一直显示“已入队”、
                                    // 更新按钮与左滑跳过都没了，只能关了重开 sheet。
                                    // 本 Task 是裸 Task、不在主 actor 上（L40/L44 同款），
                                    // updatingIDs/sheetError 是 @State，回主线程再写。
                                    await MainActor.run {
                                        updatingIDs.remove(app.czfStableID)
                                        if let error {
                                            sheetError = error
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    // 跳过（3.8.454）：左滑出“跳过”，从本次更新名单
                    // 剔除该 App（不装、不进批量队列），记版本持久化、
                    // 源出新版本才重新出现。已入队的行不挂跳过（已在装了）。
                    .swipeActions(edge: .trailing) {
                        if !updatingIDs.contains(app.czfStableID) {
                            Button("跳过", role: .destructive) {
                                onSkip(app)
                            }
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
        // S-3：sheet 内本地弹错误，挂在 sheet 自己的层级上，
        // 不会被 sheet 盖住吞掉（与 ManageSourcesSheet.addError 同款）。
        .alert("lc.common.error".loc, isPresented: Binding<Bool>(
            get: { sheetError != nil },
            set: { if !$0 { sheetError = nil } })
        ) {
            Button("lc.common.ok".loc, role: .cancel) { sheetError = nil }
        } message: {
            Text(sheetError ?? "")
        }
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
    // 大小源页自己一套键（3.8.461 分键：CZFSourceGridColumns/
    // CZFSourceGridIconSize），与 App 页互不影响；老用户首次
    // 进源页从旧键拷一份过来（见 czfMigrateSourceGridKeys）。
    @AppStorage("CZFSourceListGridMode") private var czfSourceGridMode = false
    @AppStorage("CZFSourceGridColumns") private var czfSourceGridColumns = 5
    @AppStorage("CZFSourceGridIconSize") private var czfSourceGridIconSize = 0
    @State private var czfSourceGridSettingsShow = false
    // 可更新数量写到这里，底部「源」标签上显示红点数字
    @AppStorage("CZFUpdatableAppCount") private var updatableCountBadge = 0
    // 3.8.643（F3）：可更新名单的归一 Bundle ID 集合（逗号串）——
    // App 页“仅可更新”开关按它过滤；与红点数同一处写、新鲜度同款
    // （只在源页刷新缓存时更新，长期不进源页会旧）。
    @AppStorage("CZFUpdatableBundleIDs") private var updatableBundleIDs = ""
    // 3.8.702（F2）：可更新 + 已忽略但有新版的 App 的最新“版本|build”
    // 字典（`归一ID=版本|build` 逗号串，见 CZFUpdateIgnore）——供
    // App 页长按菜单“忽略此版本/取消忽略更新”取最新版；与
    // updatableBundleIDs 同一处写、同一处删键。键口径与读键一致：
    // 写键是归一 Bundle ID，App 页忽略写键也用归一 ID（源原始包名
    // 本来就没有队尾段，归一后与读键相同）。
    @AppStorage("CZFUpdatableLatestVersions") private var updatableLatestVersions = ""
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
    // 3.8.666（B-alt）：文件夹批量态与选中集上移到源页持有——
    // 原来是 CZFInlineIpaFolderSection 的 @State，源/文件夹分段
    // 一切换，`if czfSourcesTab == 1` 分支销毁重建，批量态与勾选
    // 全丢；放源页后分段切换不丢（选中集存稳定 id，见
    // CZFLocalIpaItem）。文件夹换了（.id(url) 重建）时选中集
    // 仍按 id 匹配，旧文件夹的 id 在新列表里对不上，自然不显示。
    @State private var czfFolderBatchMode = false
    @State private var czfFolderSelectedIDs: Set<UUID> = []
    // 3.8.682（B3）：文件夹搜索字与“只看有新版”上移到源页持有——
    // 原来是 Section/Grid 的 @State，源/文件夹分段一切换，`if
    // czfSourcesTab == 1` 分支销毁重建，全丢；3.8.666 B-alt 同款
    // （只上移了批量态/选中集，这两处漏了）。不持久化，只保本次
    // 会话内分段切换；过滤逻辑与搜索节流任务不动。
    @State private var czfFolderSearchText = ""
    @State private var czfFolderOnlyUpdatable = false
    // 上次自动刷新源的时间（自动刷新节流：5 分钟内不重复刷）
    @AppStorage("CZFLastSourceAutoRefresh") private var lastSourceAutoRefresh: Double = 0
    // 3.8.653（F2）：上次检查更新时间——ViewModel 在刷新成功处写
    // CZFSourceLastCheckDate（存秒数 Double，0 = 尚未检查）。只读，
    // 不写；失败不写（见 refreshAllSources / refreshSource 注释）。
    // 修法注：@AppStorage 的 Date 值类型无论带不带默认值都只在
    // iOS 18+ 可用（两轮红字：init(_:store:) 与
    // init(wrappedValue:_:store:) 各一处）；改存 Double 秒数，
    // 同文件 CZFLastSourceAutoRefresh 同款，显示时再拼回 Date。
    @AppStorage("CZFSourceLastCheckDate") private var czfLastCheckDate: Double = 0

    // 3.8.653（F2）：上次检查文案——有值拼日期（dateStyle .short /
    // timeStyle .medium，LCAppSettingsView.formatDate 同款），
    // 无值显示“尚未检查”。
    private var czfLastCheckText: String {
        guard czfLastCheckDate > 0 else { return "尚未检查" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return "lc.sources.lastChecked".localizeWithFormat(formatter.string(from: Date(timeIntervalSince1970: czfLastCheckDate)))
    }

    /// 源页网格列数/图标大小分键迁移（3.8.461）：旧版与 App 页
    /// 共用 CZFAppGridColumns/CZFAppGridIconSize，首次进源页把
    /// 旧键值拷到新键 CZFSourceGridColumns/CZFSourceGridIconSize，
    /// 只拷一次（CZFSourceGridKeysMigratedV1 标记，照抄
    /// CZFPinnedPanelAppsMigratedV2 同款做法）；新键已有值时不
    /// 覆盖（用户已在新键上改过）。旧键无值时不写，新键走默认。
    private func czfMigrateSourceGridKeys() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "CZFSourceGridKeysMigratedV1") else { return }
        if defaults.object(forKey: "CZFSourceGridColumns") == nil,
           let old = defaults.object(forKey: "CZFAppGridColumns") {
            defaults.set(old, forKey: "CZFSourceGridColumns")
        }
        if defaults.object(forKey: "CZFSourceGridIconSize") == nil,
           let old = defaults.object(forKey: "CZFAppGridIconSize") {
            defaults.set(old, forKey: "CZFSourceGridIconSize")
        }
        defaults.set(true, forKey: "CZFSourceGridKeysMigratedV1")
    }

    /// 自动刷新源：打开 App / 切到源页时后台刷一次，更新红点
    /// 才是准的；5 分钟内重复触发直接跳过，不浪费流量
    /// 3.8.660（B2）：节流戳只在刷成功后写——原来先写戳再刷，
    /// 断网失败也消耗掉 5 分钟窗口，网恢复后反复进出源页都不
    /// 重刷；手动刷新在途时自动刷新的 Task 直接 no-op，戳也被
    /// 白白消耗（同一根因第二条路）。Task 回主线程写戳（@AppStorage
    /// 写与 refreshAllSources 的 MainActor 调用同款，见 L40）。
    private func autoRefreshSourcesIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard now - lastSourceAutoRefresh > 300, !viewModel.sources.isEmpty else {
            return
        }
        Task { @MainActor in
            if await viewModel.refreshAllSources() {
                lastSourceAutoRefresh = Date().timeIntervalSince1970
            }
        }
    }
    
    @EnvironmentObject private var sharedModel : SharedModel
    // S-7：存文件下载走共享 DownloadHelper（Tab 级注入，与安装
    // 下载同一套，进度弹窗/取消/续传全复用；LCSourcesView 只在
    // LCTabView:29 实例化，Tab 级 environmentObject 一定在）。
    @EnvironmentObject private var downloadHelper: DownloadHelper
    // S-7：存文件下载同名覆盖确认——目标已存在时先问用户，
    // 确认才下载覆盖；取消则不下载。
    @State private var czfDownloadOverwritePending: (url: URL, destURL: URL)?
    // 3.8.668（F-3）：源页下载完成三选框——下载成功 + 魔数校验通过后
    // 不再直弹分享表，改弹 confirmationDialog（安装 / 分享 / 取消）；
    // dylib 不给“安装”按钮（非 IPA，无安装路）。
    @State private var czfDownloadedFilePending: URL?
    // 3.8.672（F-2）：下载完成后自动安装开关——读设置页同键
    //（CZFDownloadAutoInstall，默认关），见 czfDownloadVersionTo。
    @AppStorage("CZFDownloadAutoInstall") private var czfDownloadAutoInstall = false
    // 3.8.672（B-1）：插件在途安装键集——行安装按钮在途时变
    // 转圈 + 禁用；键与 installTweakIfDylib 的去重键同一口径
    //（见 czfDylibInstallKey），成功/失败都清掉。
    @State private var czfDylibInstallingIDs: Set<String> = []
    // 3.8.672（B-1）：刚装完的插件名——成功提示 alert 用，
    // 弹完清掉；失败仍走 errorMessage。
    @State private var czfDylibInstallSuccessName: String?
    // 3.8.688（F2）：搜索行“添加为源”失败的本地错误——sheet 内
    // addError 同款：父级 errorMessage 的 alert 在 sheet 盖着时
    // 会被 UIKit 静默丢弃（S-9/S-3），这里是列表行直加、sheet
    // 没开，但失败反馈仍走自己独立的 alert 叶子，不与批量汇总
    // 的 errorMessage 共用槽位；成功不留文本。
    @State private var czfAddSourceError: String?
    // TwoYi 安卓系统（3.8.628，按需下载，不编进包）：
    // 安装状态派生（见 Shared.swift 的 CZFTwoYi），不另存 key。
    @State private var czfTwoYiDownloading = false
    @State private var czfTwoYiDeleteConfirm = false
    private var czfTwoYiApp: LCAppModel? { CZFTwoYi.installedApp(in: sharedModel) }
    
    @State private var isViewAppeared = false

    // 自定义背景（3.8.416，3.8.453 分家）：源页用自己的图与键
    // （CZFSourceBackground.versionKey / CZFSourceBackground.jpg）
    // ——之前与 App 页共用同一张 CZFAppBackground.jpg，源页设的
    // 图会盖掉 App 页的、反之亦然，用户报“源是源壁纸、App 是
    // App 壁纸也没生效”。读法与 App 页同款（图铺 ScrollView
    // 背后，不包 ZStack，不动 NavigationView 排布）。
    @AppStorage(CZFSourceBackground.versionKey) private var czfBackgroundVersion = 0
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
            // 3.8.501（L22）：分段下方补 8pt 白，与上方搜索框到分段
            // 的 8pt（同款 .padding(.top, 8)）一样大；白在 Picker
            // 外（页面底色），不在壁纸 ScrollView 里——放 ScrollView
            // 顶 padding 的话是壁纸不是白。文件夹分支同款受益。
            .padding(.bottom, 8)
            if czfSourcesTab == 1 {
                ScrollView {
                    CZFInlineIpaFolderSection(
                        folderURL: czfIpaFolderURL,
                        onPickFolder: { czfIpaFolderPickerShow = true },
                        onInstall: { url in czfInstallFolderIpa(url) },
                        onClearFolder: {
                            CZFLocalIpaFolderStore.clear()
                            czfIpaFolderURL = nil
                        },
                        // 3.8.682（B3）：搜索字与“只看有新版”由源页持有
                        // （见上），分段切换不丢。实参须按 Section 声明顺序：
                        // czfOnlyUpdatable / czfSearchText 在前，批量态与
                        // 选中集在后（逐成员 init 按声明顺序）。
                        czfOnlyUpdatable: $czfFolderOnlyUpdatable,
                        czfSearchText: $czfFolderSearchText,
                        // 3.8.666（B-alt）：批量态与选中集由源页持有
                        // （见上），分段切换不丢勾选。
                        czfBatchMode: $czfFolderBatchMode,
                        czfSelectedIDs: $czfFolderSelectedIDs
                    )
                    .padding()
                }
                // 3.8.682（B1）：iOS 16+ 滚即收键盘——键盘盖着下半屏
                // 时，滚一下即可收起再点格子安装；不吞格子点按。
                .czfScrollDismissesKeyboard()
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
                // 3.8.684（F3）：点当前 Tab 回到顶部——ScrollViewReader
                // 的 proxy 只在闭包内，锚点与 onReceive 都落在这里。
                ScrollViewReader { czfSourcesProxy in
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
                        // 3.8.684（F3）：回到顶部锚点——点当前“源” Tab 即滚到这里。
                        Color.clear.frame(height: 0).id("czfSourcesListTop")
                        // 3.8.696（F2）：.ipa/.tipa 直链先给“安装这个 IPA”行
                        //（见 czfSearchIpaRow，列表/网格两路共用本 VStack，
                        // 一处加两路受益）；再往下才是“添加为源”行。
                        czfSearchIpaRow
                        // 3.8.688（F2）：搜不到时输入像 URL 就给一行“添加为源”——
                        // 原来搜索无匹配时列表只剩 TwoYi 区、无任何空态文案与下一步
                        // 入口，要加这个源必须点 + → 管理源 sheet → 再粘贴一次。
                        // App 页搜索快捷行（“打开网址 / 在网上搜索”）同一模式的
                        // 先例；点一下走现成 handleAddSource，成功清掉搜索词、
                        // 新源组直接现身，失败进本页独立的 czfAddSourceError
                        // alert（不走父级 errorMessage，见该 @State 注释）。
                        // 列表/网格两路共用本 VStack，一处加两路受益。
                        // 3.8.696（F2）：.ipa/.tipa 链接不再出“添加为源”行——
                        // 它不是源 JSON，点下去 addSource 必失败弹错。
                        // 3.8.700（B3）：已加的源不再出“添加为源”行——原来
                        // 只看搜索无匹配、不查该源是否已加，搜已加源的完整
                        // URL 时行照常出现、点后才报 duplicate。viewModel
                        // 的 normalizeSourceURL 是 private，视图侧只能做
                        // 原样 URL 比对，覆盖粘贴原链接的主路；带尾斜杠等
                        // 变体仍走现有 duplicate 友好报错兜底。
                        if isFiltering, totalFilteredAppCount == 0, let czfAddURL = czfSearchSourceURL, !["ipa", "tipa"].contains(czfAddURL.pathExtension.lowercased()), !viewModel.sources.contains(where: { $0.url == czfAddURL }) {
                            Button {
                                Task {
                                    if let error = await handleAddSource(czfAddURL.absoluteString) {
                                        await MainActor.run { czfAddSourceError = error }
                                    } else {
                                        await MainActor.run { searchContext.query = "" }
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "link.badge.plus")
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("添加为源")
                                            .font(.headline)
                                        Text(czfAddURL.absoluteString)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                        // TwoYi 安卓系统（3.8.628）：只在“源”分段出现
                        // （不在“文件夹”分段）、网格与列表两模式都可见、
                        // 与每源一组平级；源为空的空态分支里不出现。
                        CZFTwoYiSection(
                            installed: czfTwoYiApp != nil,
                            isDownloading: czfTwoYiDownloading,
                            // 3.8.690（B2）：还在不在队里直接认共享排队名册
                            // czfQueuedDownloads——排队名是 czfDisplayDownloadName
                            // （LCDownloadView.swift:851），TwoYi 文件名 27 字
                            // 节、无 UUID 前缀，显示名就是 lastPathComponent 原样。
                            isQueued: downloadHelper.czfQueuedDownloads.contains(CZFTwoYi.downloadURL.lastPathComponent),
                            downloadProgress: downloadHelper.downloadProgress,
                            // 3.8.672（F-1）：下载排队——TwoYi 按钮只在
                            // 自己下载时禁用，别路下载中也能点、点下去
                            // 进排队（:2144 守门已删，按钮再拦就白改了）；
                            // 重复点按仍由 czfTwoYiDownloading 拦。
                            installDisabled: czfTwoYiDownloading,
                            onInstall: { czfInstallTwoYi() },
                            onRemove: { czfTwoYiDeleteConfirm = true },
                            // 3.8.692（F3）：打开 TwoYi——照抄行上打开块的
                            // 骨架（锁守卫 + runApp + 失败写父级
                            // errorMessage，裸 Task、回主线程写）；
                            // 只有一个 guest 实例，无多实例选择器。
                            onOpen: {
                                guard let app = czfTwoYiApp else { return }
                                Task {
                                    guard await app.czfAuthenticateIfLocked() else { return }
                                    do {
                                        try await app.runApp()
                                    } catch {
                                        await MainActor.run { errorMessage = error.localizedDescription }
                                    }
                                }
                            }
                        )
                        .padding(.horizontal)
                        if czfSourceGridMode {
                            CZFSourceGridView(
                                items: viewModel.sources,
                                viewModel: viewModel,
                                columns: czfSourceGridColumns,
                                iconSize: czfSourceGridIconSize,
                                filteredApps: { item in filteredApps(for: item) },
                                isFiltering: isFiltering,
                                searchQuery: searchContext.debouncedQuery,
                                onRefresh: { item in Task { await viewModel.refreshSource(item) } },
                                onInstall: install(app:),
                                onInstallAsNew: installAsNew(app:),
                                onDownload: download(app:),
                                onDownloadVersion: downloadVersion(url:),
                                onRemove: { item in sourcePendingRemoval = item },
                                isBatchMode: isBatchMode,
                                selectedIDs: selectedIDs,
                                onBatchInstall: { batchInstallSelected() },
                                onToggleSelect: { sourceURL, app in
                                    let key = czfSourceSelectionKey(sourceURL: sourceURL, app: app)
                                    if selectedIDs.contains(key) {
                                        selectedIDs.remove(key)
                                    } else {
                                        selectedIDs.insert(key)
                                    }
                                },
                                // 3.8.672（B-1）：插件在途键集——网格详情页
                                // 复用的列表行也要变转圈，往下传。
                                // 3.8.673 修法（红字 6）：实参须按声明顺序，
                                // onToggleSelect 在 dylibInstallingIDs 之前。
                                dylibInstallingIDs: czfDylibInstallingIDs,
                                // 3.8.696（F1）：组头“更新本源全部 App”——
                                // 子集算子 + 批量安装回调往网格里传，组头
                                // 再按本源 apps 取子集；实参按声明顺序，
                                // 在 dylibInstallingIDs 之后。
                                updatableAppsForSource: czfUpdatableApps(for:),
                                onUpdateSourceApps: czfUpdateSourceApps(apps:)
                            )
                            .padding(.horizontal)
                        } else {
                            // 3.8.673 修法（第二轮红字 2-4）：元组 keypath
                            // \.item.id 推不出根类型（报成 Binding<C>），
                            // 与网格 ForEach 同款改按下标迭代；不用
                            // .indices（会被解析成 indices(where:) 方法）。
                            ForEach(0..<czfVisibleListEntries.count, id: \.self) { (index: Int) in
                                let entry = czfVisibleListEntries[index]
                                let apps = entry.apps
                                AltStoreSourceSectionView(
                                    item: entry.item,
                                    filteredApps: apps,
                                    isFiltering: isFiltering,
                                    isExpanded: expandedSources.contains(entry.item.id),
                                    onRefresh: { Task { await viewModel.refreshSource(entry.item) } },
                                    onInstall: install(app:),
                                    onInstallAsNew: installAsNew(app:),
                                    onDownload: download(app:),
                                    onDownloadVersion: downloadVersion(url:),
                                    onRemove: { sourcePendingRemoval = entry.item },
                                    // 3.8.658（F2）：停用开关接 ViewModel。
                                    isPaused: viewModel.isSourcePaused(entry.item.url),
                                    onTogglePause: { viewModel.togglePauseSource(entry.item.url) },
                                    // 3.8.660（F2）：各源上次成功检查时间接 ViewModel。
                                    lastCheckedText: viewModel.czfLastCheckedText(for: entry.item.url),
                                    toggleExpanded: { toggleExpansion(for: entry.item.id) },
                                    isBatchMode: isBatchMode,
                                    selectedIDs: selectedIDs,
                                    onToggleSelect: { sourceURL, app in
                                        let key = czfSourceSelectionKey(sourceURL: sourceURL, app: app)
                                        if selectedIDs.contains(key) {
                                            selectedIDs.remove(key)
                                        } else {
                                            selectedIDs.insert(key)
                                        }
                                    },
                                    // 3.8.672（B-1）：插件在途键集——行安装
                                    // 按钮在途时变转圈，往下传。
                                    // 3.8.673 修法（红字 6 同款）：实参须按声明
                                    // 顺序，onToggleSelect 在 dylibInstallingIDs 之前。
                                    dylibInstallingIDs: czfDylibInstallingIDs,
                                    // 3.8.696（F1）：组头“更新本源全部 App”——
                                    // 本源可更新子集（按 czfStableID 与该源
                                    // filteredApps 取交集）+ 批量安装回调；
                                    // 实参按声明顺序，在 dylibInstallingIDs 之后。
                                    updateSourceApps: czfUpdatableApps(for: apps),
                                    onUpdateSourceApps: czfUpdateSourceApps(apps:)
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
                        // 3.8.653（F2）：上次检查更新时间 footnote——列表底部一行；
                        // 源为空的空态分支里不出现（无源可查，时间戳无意义）。
                        Text(czfLastCheckText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal)
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
                // 3.8.686（F3）：下拉刷新全部源——与 App 页同款
                // （LCAppListView :2705-2708）；复用已有的
                // refreshAllSources（自带节流、重入守卫与成功判据，
                // 3.8.660 B2）。iOS 15+ API，无新 key、无新助手。
                .refreshable {
                    await viewModel.refreshAllSources()
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
                    czfBackgroundImage = CZFSourceBackground.loadImage()
                }
                .onChange(of: czfBackgroundVersion) { _ in
                    czfBackgroundImage = CZFSourceBackground.loadImage()
                }
                // 3.8.684（F3）：点当前 Tab 回到顶部——与 App 页同款，
                // 只在当前就是源页时滚。
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CZFScrollCurrentTabToTop"))) { output in
                    guard (output.object as? LCTabIdentifier) == .sources else { return }
                    guard sharedModel.selectedTab == .sources else { return }
                    withAnimation { czfSourcesProxy.scrollTo("czfSourcesListTop", anchor: .top) }
                }
                // 3.8.688（B2）：搜索后滚列表收键盘——与文件夹分支
                // （:1201，20 轮）同款一行现成助手；主列表此前漏了。
                // 回顶锚点（21/22 轮）不动。
                .czfScrollDismissesKeyboard()
                // 切换行已收进设置（3.8.419，建议第 3 条）：原来钉在
                // 顶部的“恢复原生 / 网格设置”行删掉，模式开关收到
                // 网格设置 sheet 里（CZFAppGridSettingsView 的显示
                // 模式，两页共用），网格设置入口收到顶栏 leading；
                // 页面多出一行 App。
                }
            }
        }
    }

    // 3.8.688 修法（构建 run 45874596602 唯一红字原文：
    // LCAltStoreSourcesView.swift:1465:44: error: the compiler is
    // unable to type-check this expression in reasonable time; try
    // breaking up the expression into distinct sub-expressions）——
    // czfSourcesBodyA 一串修饰符里又添了 F2 的 alert 叶子与 B1/B3
    // 的闭包，整串表达式算不过来。按本文件 3.8.423/424 同款拆法：
    // 把最大的两块（全部更新清单 sheet、管理源 sheet）各抽成独立
    // @ViewBuilder，BodyA 只留一行调用；内容一字不动，只换缩进。
    @ViewBuilder
    private var czfUpdatableAppsSheet: some View {
        CZFUpdatableAppsSheet(
            apps: cachedUpdatableApps,
            onUpdateOne: { app in
                // O-4：单行更新不关整单。S-3：失败返回错误文本，
                // 由 sheet 内 alert 显示，不再写父级 errorMessage
                // （sheet 盖着时父级 alert 弹不出来，见 B-11）。
                guard app.latestVersion?.downloadURL != nil else {
                    return "lc.sources.error.missingDownload".loc
                }
                // S-3/S-8：dylib 等装完再决定——成功才从名单
                // 剔除，失败行保留、错误文本进 sheet 内显示。
                switch await installTweakIfDylib(app: app) {
                case .notDylib:
                    break
                case .succeeded:
                    // 3.8.581（L411-1）：本闭包唯一调用方是 sheet 行按钮的裸 Task（:794，Swift 5.0 靶下 Button 闭包的 Task 不继承 MainActor），await 之后在全局执行器上跑；cachedUpdatableApps 是 @State（:886）、updatableCountBadge 是 @AppStorage（:881），离主线程写报 Publishing changes、更新完的行可能不消失、红标可能不刷新（L40/L44/L395-1 同款——L161 只包了调用方 Task 自己的 updatingIDs/sheetError 写，闭包内部这两处漏了）。回主线程再写。
                    await MainActor.run {
                        cachedUpdatableApps.removeAll { $0.czfStableID == app.czfStableID }
                        updatableCountBadge = cachedUpdatableApps.count
                        // 3.8.653（B2）：ID 集与名单同一处写——只改名单+红点，
                        // App 页“仅可更新”仍按旧 ID 集列出刚更新的行；
                        // 按新名单顺手重算（refreshUpdatableCache :1780 同款拼接）。
                        updatableBundleIDs = cachedUpdatableApps.map { czfNormalizedBundleID($0.bundleIdentifier) }.joined(separator: ",")
                        // 3.8.702（F2）：字典同步删键——只删这一项，不从名单
                        // 重算（已忽略的 App 不在 cachedUpdatableApps 里，
                        // 重算会丢它们的最新版）。
                        var czfLatestDict = CZFUpdateIgnore.latestVersionDict(from: updatableLatestVersions)
                        czfLatestDict.removeValue(forKey: czfNormalizedBundleID(app.bundleIdentifier))
                        updatableLatestVersions = CZFUpdateIgnore.latestVersionsString(from: czfLatestDict)
                        // 3.8.704（F-3）：URL 字典同步删键（与版本字典同款，
                        // 只删这一项；App 页“更新这个 App”不再为它出现）。
                        var czfDownloadURLs = (UserDefaults.standard.dictionary(forKey: "CZFUpdatableDownloadURLs") as? [String: String]) ?? [:]
                        czfDownloadURLs.removeValue(forKey: czfNormalizedBundleID(app.bundleIdentifier))
                        UserDefaults.standard.set(czfDownloadURLs, forKey: "CZFUpdatableDownloadURLs")
                        // 3.8.702（B3）：dylib 单行成功、名单变空即关 sheet——
                        // onUpdateAll 与 onSkip 名单为空时都关了，唯独这条漏了；
                        // 非 dylib 路走 install 切 App 页、不留空 sheet，这里不切
                        // 页，sheet 会赖在空名单上。照抄 onSkip 的写法。
                        if cachedUpdatableApps.isEmpty {
                            showUpdatableList = false
                        }
                    }
                    return nil
                case .failed(let error):
                    return error.localizedDescription
                }
                // 3.8.581（L411-1）：同上，install(app:) 在这里直接调；它里面写 @Published selectedTab（切 App 页）+ 无锁静态数组 CZFSourcePendingInstall.append（与 App 页 onAppear/onReceive 的主线程排空竞态），必须回主线程再调。
                // 3.8.649（B3）：这里不乐观剔除——install(app:) 只切
                // Tab + 写待装队列，成败未定；先剔除再装、装失败
                // 时 apps 不变、onChange 不重算，行与红点就此消失、
                // 直到下次进源页才回来。改等 apps 变化后由 onChange
                // 重算自然消失（成功装完行即走，失败行与红点保留）。
                await MainActor.run {
                    install(app: app)
                }
                return nil
            },
            onUpdateAll: {
                showUpdatableList = false
                Task { @MainActor in
                    let result = await installBatch(cachedUpdatableApps)
                    czfShowBatchResult(result)
                }
            },
            // 跳过（持久 + 带版本）：记进 CZFSkippedUpdate（源出
            // 新版本才重新出现），再从名单剔除并同步红点；图标
            // 上的更新角标（hasUpdate）不受影响。
            onSkip: { app in
                // 3.8.698（B1）：跳过表改记“版本|build”（照抄 25 轮
                // B3 的 CZFUpdateIgnore.ignoredKey）——只升 build 的
                // 更新原来只记短版本，跳过后新 build 永不再提醒。
                // build 为空时只记短版本，与 B3 同款。
                CZFSkippedUpdate.setSkipped(app.latestVersion.map { CZFUpdateIgnore.ignoredKey(version: $0.version, build: $0.buildVersion) }, for: app.czfStableID)
                cachedUpdatableApps.removeAll { $0.czfStableID == app.czfStableID }
                updatableCountBadge = cachedUpdatableApps.count
                // 3.8.653（B2）：同上，ID 集与名单同一处写（:1780 同款拼接）。
                updatableBundleIDs = cachedUpdatableApps.map { czfNormalizedBundleID($0.bundleIdentifier) }.joined(separator: ",")
                // 3.8.702（F2）：字典同步删键（同上，只删这一项）。
                var czfLatestDict = CZFUpdateIgnore.latestVersionDict(from: updatableLatestVersions)
                czfLatestDict.removeValue(forKey: czfNormalizedBundleID(app.bundleIdentifier))
                updatableLatestVersions = CZFUpdateIgnore.latestVersionsString(from: czfLatestDict)
                // 3.8.704（F-3）：URL 字典同步删键（与版本字典同款，
                // 只删这一项；跳过的 App 不再出现“更新这个 App”）。
                var czfDownloadURLs = (UserDefaults.standard.dictionary(forKey: "CZFUpdatableDownloadURLs") as? [String: String]) ?? [:]
                czfDownloadURLs.removeValue(forKey: czfNormalizedBundleID(app.bundleIdentifier))
                UserDefaults.standard.set(czfDownloadURLs, forKey: "CZFUpdatableDownloadURLs")
                // 3.8.688（B3）：跳光即关 sheet——onSkip 只剔名单、不碰
                // showUpdatableList，名单跳空后 List 为空、标题与底部
                // 按钮都变“全部更新(0)”、sheet 赖在屏幕上；点下去
                // onUpdateAll 走空 installBatch、czfShowBatchResult
                // 直接 return，零反馈。名单变空即事毕，直接关回源页。
                // 只动现成 @State，不碰跳过持久化、不碰红点重算。
                if cachedUpdatableApps.isEmpty {
                    showUpdatableList = false
                }
            },
            // 3.8.702（B1）：sheet 内手动刷新——走 viewModel.refreshAllSources
            //（顶栏刷新同款）；成功后补写 CZFLastSourceAutoRefresh 戳
            //（手动刷新今天不写戳，只 autoRefresh 写，不补写则刷新完提示
            // 条仍显示过期；与 autoRefreshSourcesIfNeeded 成功写戳同款）。
            // Task { @MainActor in } 调用（sheet 内按钮同款），戳写在主线程。
            onRefresh: {
                if await viewModel.refreshAllSources() {
                    lastSourceAutoRefresh = Date().timeIntervalSince1970
                }
            }
        )
    }

    @ViewBuilder
    private var czfManageSourcesSheet: some View {
        if #available(iOS 16.0, *) {
            ManageSourcesSheet(
                viewModel: viewModel,
                isPresented: $isManagingSources,
                onAdd: { rawValue in
                    await handleAddSource(rawValue)
                },
                // 3.8.688（B1）：删源清选中集——22 轮 B1 同款 hazard：
                // 删源只清 ViewModel 侧，不碰视图层 selectedIDs；
                // 删完选中集变幽灵、顶栏“安装”仍亮、点下去静默空跑。
                // 选中键是 czfSourceSelectionKey（源 feed URL + ":" +
                // czfStableID），按该源 URL 前缀整批清掉；不碰续签过滤。
                // 3.8.688 修法3：不用 removeAll(where:)——Set 没有它
                //（那是 RangeReplaceableCollection 的方法，全仓 removeAll
                // 闭包全在 Array 上），写了编译器把 removeAll 认成无参
                // 版、尾随闭包报 extra trailing closure；改 filter 重赋。
                onRemove: { item in
                    let prefix = item.url.absoluteString + ":"
                    selectedIDs = selectedIDs.filter { !$0.hasPrefix(prefix) }
                }
            )
            .presentationDetents([.large])
        } else {
            ManageSourcesSheet(
                viewModel: viewModel,
                isPresented: $isManagingSources,
                onAdd: { rawValue in
                    await handleAddSource(rawValue)
                },
                // 3.8.688（B1）：删源清选中集——与上面 iOS 16+ 分支同款（见该处注释）。
                onRemove: { item in
                    let prefix = item.url.absoluteString + ":"
                    selectedIDs = selectedIDs.filter { !$0.hasPrefix(prefix) }
                }
            )
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
            // 顶栏走超薄材质透壁纸（3.8.453）：之前实底
            // czfSolidToolbarBackground，App 页 .toolbarBackground
            // 没生效透出深色壁纸变黑、源页实底白，两页顶黑白不一。
            // 改走 czfWallpaperToolbarBackground，壁纸模糊透出、
            // 两页一致；iOS 15 走默认半透明。
            .czfWallpaperToolbarBackground()
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
        // 3.8.664（F1）：批量底栏——批量模式 + “源”分段时才出现
        //（App 页批量底栏同款挂法与样式：直接挂 NavigationView 上、
        // 浅灰实底）；只放已选数 + 全选/取消全选 + 取消，安装仍在
        // 顶栏，不重复造第二个安装钮。
        .safeAreaInset(edge: .bottom) {
            if isBatchMode && czfSourcesTab == 0 {
                HStack {
                    Text("已选 \(czfBatchSelectedCount) 个")
                        .font(.subheadline)
                    Button(czfBatchAllSelected ? "取消全选" : "全选") {
                        czfToggleBatchSelectAll()
                    }
                    Spacer()
                    Button("取消") {
                        isBatchMode = false
                        selectedIDs.removeAll()
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // 3.8.589（L121）：同一视图挂多个 .alert/.confirmationDialog 只有最后一个生效——
        // SwiftUI 同一分支只认最外层一个弹窗（sarunw 实证，L120 同款）。
        // 各挪一个 background 叶子、各占一条分支，宿主链上不再留弹窗类修饰符；触发点与按钮一字不动。
        .background(
            EmptyView()
                .alert("lc.common.error".loc, isPresented: Binding<Bool>(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } })
                ) {
                    Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
        )
        // 3.8.688（F2）：搜索行“添加为源”失败的本地 alert——
        // 3.8.589（L121）同款：各挪一个 background 叶子、各占一条
        // 分支，不与 errorMessage 共用槽位。
        .background(
            EmptyView()
                .alert("lc.common.error".loc, isPresented: Binding<Bool>(
                    get: { czfAddSourceError != nil },
                    set: { if !$0 { czfAddSourceError = nil } })
                ) {
                    Button("lc.common.ok".loc, role: .cancel) { czfAddSourceError = nil }
                } message: {
                    Text(czfAddSourceError ?? "")
                }
        )
        // 3.8.672（B-1）：插件安装成功提示——复用 errorMessage
        // 同款 alert 槽位（background 叶子，各占一条分支），另起
        // 标题/状态位；标题复用 lc.common.installed，0 新 key。
        // 源页此前无 toast 槽，不新造 toast 体系。
        .background(
            EmptyView()
                .alert("lc.common.installed".loc, isPresented: Binding<Bool>(
                    get: { czfDylibInstallSuccessName != nil },
                    set: { if !$0 { czfDylibInstallSuccessName = nil } })
                ) {
                    Button("lc.common.ok".loc, role: .cancel) { czfDylibInstallSuccessName = nil }
                } message: {
                    Text("\(czfDylibInstallSuccessName ?? "") 已安装")
                }
        )
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
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
        )
        // S-7：存文件下载同名覆盖前问一次——目标已存在时先弹确认，
        // 用户点“覆盖”才下载，点取消不下载、不覆盖。
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .confirmationDialog(
                    "文件已存在",
                    isPresented: Binding<Bool>(
                        get: { czfDownloadOverwritePending != nil },
                        set: { if !$0 { czfDownloadOverwritePending = nil } }
                    ),
                    presenting: czfDownloadOverwritePending
                ) { pending in
                    Button("覆盖", role: .destructive) {
                        czfDownloadVersionTo(url: pending.url, destURL: pending.destURL)
                        czfDownloadOverwritePending = nil
                    }
                    Button("取消", role: .cancel) {
                        czfDownloadOverwritePending = nil
                    }
                } message: { pending in
                    Text("\(pending.destURL.lastPathComponent) 已存在，是否覆盖？")
                }
        )
        // 3.8.668（F-3）：下载完成三选框——3.8.589（L121）同款：挪
        // background 叶子，宿主链上不再留弹窗类修饰符。安装走源页
        // 待装队列（切 App 页 + CZFSourcePendingInstall，App 页排空
        // 进 installFromUrl 的 file:// 本地路、不重新下载，
        // czfProgressBase 默认 0）；分享走现有 shareFile(at:)；
        // 取消只留文件。dylib 不给安装按钮。
        .background(
            EmptyView()
                .confirmationDialog(
                    "下载完成",
                    isPresented: Binding<Bool>(
                        get: { czfDownloadedFilePending != nil },
                        set: { if !$0 { czfDownloadedFilePending = nil } }
                    ),
                    presenting: czfDownloadedFilePending
                ) { destURL in
                    if destURL.pathExtension.lowercased() != "dylib" {
                        Button("lc.common.install".loc) {
                            czfInstallDownloadedFile(destURL)
                        }
                    }
                    Button("分享") {
                        shareFile(at: destURL)
                        czfDownloadedFilePending = nil
                    }
                    Button("lc.common.cancel".loc, role: .cancel) {
                        czfDownloadedFilePending = nil
                    }
                } message: { destURL in
                    Text("\(destURL.lastPathComponent) 已下载完成")
                }
        )
        // TwoYi 安卓系统（3.8.628）：删 guest 前问一次——
        // 3.8.589（L121）：同款——也挪 background 叶子。
        // 单个确认框、两 destructive 按钮（CZFAppGridView 同款），
        // 不做两步链式弹窗（第二步可能被第一步的收起静默顶掉）。
        // 标题/正文复用 lc.appBanner.*；“保留数据重装会恢复旧
        // 安卓数据”写进正文第二行（lc.twoyi.deleteKeepDataNote）。
        .background(
            EmptyView()
                .confirmationDialog("lc.appBanner.confirmUninstallTitle".loc, isPresented: $czfTwoYiDeleteConfirm, titleVisibility: .visible) {
                    Button("lc.twoyi.deleteKeepData".loc, role: .destructive) {
                        Task { await czfDeleteTwoYi(removeDataFolders: false) }
                    }
                    Button("lc.twoyi.deleteAllData".loc, role: .destructive) {
                        Task { await czfDeleteTwoYi(removeDataFolders: true) }
                    }
                    Button("lc.common.cancel".loc, role: .cancel) {}
                } message: {
                    Text("lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(czfTwoYiApp?.displayName ?? CZFTwoYi.displayName) + "\n" + "lc.twoyi.deleteKeepDataNote".loc)
                }
        )
        .sheet(isPresented: $czfSourceGridSettingsShow) {
            CZFAppGridSettingsView(columns: $czfSourceGridColumns, iconSize: $czfSourceGridIconSize, gridMode: $czfSourceGridMode, showSort: false, isSource: true)
        }
        .sheet(isPresented: $showUpdatableList) {
            czfUpdatableAppsSheet
        }
        .sheet(isPresented: $isManagingSources) {
            czfManageSourcesSheet
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
            viewModel.loadSourcesIfNeeded()
            czfMigrateSourceGridKeys()
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
        .onChange(of: sharedModel.selectedTab) { tab in
            if tab == .sources {
                viewModel.loadSourcesIfNeeded()
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
        // 3.8.658（F2）：停用/恢复源即重算可更新名单与红点——
        // togglePauseSource 不改 sources，上面那路 onChange 不触发。
        .onChange(of: viewModel.disabledSourceURLs) { _ in
            refreshUpdatableCache()
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
            // 红点不用等用户点进源页才准。
            autoRefreshSourcesIfNeeded()
            refreshUpdatableCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CZFRecomputeUpdatableCache"))) { _ in
            // S-12：忽略/取消忽略版本只用重算红点与可更新名单，
            // 不用联网刷新源——以前也发 CZFRefreshSourcesRequest，
            // 名字说"刷新源"实际生效的只是重算，名不副实。
            refreshUpdatableCache()
        }
    }
    
    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 源中 #6（列表路）：搜索中过滤掉 filteredApps 为空的源组，
    // 不渲染空组头；非搜索时不过滤。
    // 3.8.603（O-18）：列表路一次 map——原来 czfVisibleListSources 与
    // 行内 filteredApps(for:) 各调一遍过滤，一次 body 求值过滤两遍
    // （再加 totalFilteredAppCount 是三遍）；现在一次算出 [(item, apps)]，
    // 可见组与行共用，少一遍全量过滤。非搜索时不过滤（同款语义）。
    private var czfVisibleListEntries: [(item: AltStoreSourcesViewModel.SourceItem, apps: [AltStoreSourceApp])] {
        guard isFiltering else {
            return viewModel.sources.map { ($0, $0.source?.apps ?? []) }
        }
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.sources.compactMap { item in
            let apps = filteredApps(for: item)
            if !apps.isEmpty { return (item, apps) }
            // 3.8.664（B2）：source == nil（仍在加载/加载失败）的组，
            // 源名命中搜索词时也保留——组头 + 加载中/错误块照常显示，
            // 不再搜源名时整组消失；名字不命中仍丢掉（无 App 可列）。
            if item.source == nil, !query.isEmpty, item.displayName.localizedCaseInsensitiveContains(query) {
                return (item, apps)
            }
            return nil
        }
    }
    
    private var totalFilteredAppCount: Int {
        viewModel.sources.reduce(0) { partialResult, item in
            partialResult + filteredApps(for: item).count
        }
    }
    
    private func filteredApps(for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return item.source?.apps ?? []
        }
        // 3.8.664（B2）：源名匹配移到 guard 之前——source == nil
        //（仍在加载/加载失败）的源原来在 guard 处直接 return []，
        // 搜源名时整组消失；先比源名，名字命中即返回该源全部 App
        //（source 为 nil 时无 App、返回 []，组是否保留由可见条目
        // 按源名匹配判断，见 czfVisibleListEntries / czfVisibleItems）。
        // 3.8.662（F3）：搜源名即列出该源全部 App——displayName
        // 含源名（未加载时回落 URL host）；此前只比 App 的六路
        // 字段，搜源名时所有组都被 czfVisibleListEntries 丢掉、
        // 结果是空页。网格路共用同一函数，一处改两路受益。
        if item.displayName.localizedCaseInsensitiveContains(query) {
            return item.source?.apps ?? []
        }
        guard let source = item.source else { return [] }
        // 3.8.603（O-18）：query.lowercased() 提到 filter 外——
        // 原来每 App 算一次，搜索时每遍过滤都重复算。
        let lower = query.lowercased()
        return source.apps.filter { app in
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
            // 3.8.658（F3）：源页搜索顺带支持版本号 + build 号——
            // 原来只比名字/Bundle ID/开发者/副标题，版本号都不比；
            // 与 App 页同款，build 缺省 "0" 不参与匹配。
            if let latest = app.latestVersion, latest.version.lowercased().contains(lower) {
                return true
            }
            if let build = app.latestVersion?.buildVersion?.lowercased(), build != "0", build.contains(lower) {
                return true
            }
            return false
        }
    }
    
    // 3.8.688（F2）：搜索输入像 http(s) URL 才返回它——App 页
    // czfSearchURL 同款判法（URLComponents + http/https + host），
    // 但只认带协议的完整 URL：裸域名不补协议（源地址必须是完整
    // 链接，补出来的多半不是源）；带空格/其他协议头的不算。
    private var czfSearchSourceURL: URL? {
        let q = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !q.contains(" ") else { return nil }
        guard let comps = URLComponents(string: q), let scheme = comps.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"), comps.host != nil else { return nil }
        return comps.url
    }

    // 3.8.696（F2）：搜索输入像 .ipa/.tipa 直链才返回它——App 页
    // czfSearchURL 同款判法（LCAppListView:2351-2370：带协议直接用、
    // 裸域名补 https、带空格/其他协议头/无点的不算），再按后缀
    // 认 ipa/tipa。App 页的 czfSearchURL 是 private 计算属性，
    // 跨文件不可见，这里内联同款判法；源页 czfSearchSourceURL
    // 只认带协议完整 URL，口径比 App 页窄，不可直接套用，否则
    // 裸域名 .ipa 链接仍无行。
    private var czfSearchIpaURL: URL? {
        let q = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !q.contains(" ") else { return nil }
        let url: URL?
        if let comps = URLComponents(string: q), let scheme = comps.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"), comps.host != nil {
            url = comps.url
        } else {
            if q.contains("://") { return nil }
            guard q.contains(".") else { return nil }
            let parts = q.split(separator: ".")
            let isIPv4 = parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy({ $0.isNumber }) }
            guard parts.count >= 2,
                  (isIPv4 || (q == q.lowercased() && parts.last!.count >= 2 && parts.last!.allSatisfy({ $0.isLetter }))) else { return nil }
            url = URL(string: "https://" + q)
        }
        guard let ipaURL = url, ["ipa", "tipa"].contains(ipaURL.pathExtension.lowercased()) else { return nil }
        return ipaURL
    }

    // 3.8.696（F2）：搜到 .ipa/.tipa 直链给一行“安装这个 IPA”——
    // App 页 26 轮 F2（LCAppListView:2427-2450）同款，点按直接
    // 写待装队列并切 App 页（install(app:) 的收尾两行同款），
    // 不用进 + 菜单“从链接安装”重粘一遍；样式照抄下面“添加为源”
    // 行（圆角 22 同款）。出现条件与 App 页同款：输入是 .ipa
    // 直链即出现，不要求零结果。抽成独立 builder 再挂进搜索
    // VStack（3.8.688 体检查超时教训，大 VStack 不再直接加表达式）。
    @ViewBuilder
    private var czfSearchIpaRow: some View {
        if isFiltering, let czfIpaURL = czfSearchIpaURL {
            Button {
                // 3.8.702（B2）：点按即清搜索——入队本身不失败，与切
                // Tab 同步；同页“添加为源”行成功即清同款。
                searchContext.query = ""
                withAnimation {
                    DataManager.shared.model.selectedTab = .apps
                }
                CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: czfIpaURL, autoReplace: false, preview: true, forceAsNew: false))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安装这个 IPA")
                            .font(.headline)
                        Text(czfIpaURL.absoluteString)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
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
    
    // 3.8.664（F1）：批量全选用的当前列表——全部可见源组过滤后
    // 的 App（搜索时只含搜到的，未搜索时是全部）；“全选”只勾
    // 这些。“取消全选”清掉全部已选项（App #12 同款：原来只清
    // 当前列表的，搜索时看不见的已选项还留在批量里）。
    private var czfBatchCurrentList: [(sourceURL: URL, app: AltStoreSourceApp)] {
        viewModel.sources.flatMap { item in
            filteredApps(for: item).map { (sourceURL: item.url, app: $0) }
        }
    }
    private var czfBatchAllSelected: Bool {
        !czfBatchCurrentList.isEmpty && czfBatchCurrentList.allSatisfy { entry in
            selectedIDs.contains(czfSourceSelectionKey(sourceURL: entry.sourceURL, app: entry.app))
        }
    }
    private func czfToggleBatchSelectAll() {
        if czfBatchAllSelected {
            selectedIDs.removeAll()
        } else {
            for entry in czfBatchCurrentList {
                selectedIDs.insert(czfSourceSelectionKey(sourceURL: entry.sourceURL, app: entry.app))
            }
        }
    }
    // 3.8.664（F1）：底栏已选数——按 czfStableID 去重后的条数，
    // 与 batchInstallSelected 实际装的数一致（S-13 同款口径）。
    private var czfBatchSelectedCount: Int {
        czfDedupedSelectedCount(sources: viewModel.sources, selectedIDs: selectedIDs)
    }

    @MainActor
    private func batchInstallSelected() {
        let appsToInstall = viewModel.sources.flatMap { item -> [AltStoreSourceApp] in
            guard let source = item.source else { return [] }
            return source.apps.filter { selectedIDs.contains(czfSourceSelectionKey(sourceURL: item.url, app: $0)) }
        }
        // 源中 #5：按 czfStableID（包名 + 名字）去重，同一 App 在
        // 两个源里只装一次（保留第一次出现的记录）；同源同包名
        // 双变体（汉化版/原版）名字不同、键不同，各装一个
        // （3.8.664 B3：原来按 bundleIdentifier 去重，双变体
        // 批量安装时静默丢一个）。
        var seenStableIDs = Set<String>()
        let dedupedApps = appsToInstall.filter { seenStableIDs.insert($0.czfStableID).inserted }
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

    // O-4：批量汇总的反馈——installBatch 只负责数数，显示
    // 在这里。errorMessage 的 alert 挂在源页上：没切走时当场
    // 弹；有 IPA 入队已切到 App 页时，errorMessage 照样写
    // （alert 的 isPresented 直接绑 errorMessage != nil），
    // 用户切回源页时再弹出来——原来这里 guard queued 为空
    // 才写，混装一批里 dylib 失败/无链接的跳过全被静默丢掉。
    // 仍不如 App 页批量收尾的汇总及时，但不再丢。
    @MainActor
    private func czfShowBatchResult(_ result: CZFInstallBatchResult) {
        guard !result.skipped.isEmpty || !result.failed.isEmpty else { return }
        var lines: [String] = []
        if !result.skipped.isEmpty {
            lines.append("跳过 \(result.skipped.count) 个（无下载链接）：\(result.skipped.joined(separator: "、"))")
        }
        if !result.failed.isEmpty {
            lines.append("失败 \(result.failed.count) 个：\(result.failed.map { "\($0.name)：\($0.reason)" }.joined(separator: "、"))")
        }
        errorMessage = lines.joined(separator: "\n")
    }

    // S-8：dylib 安装分支抽共用——install / installAsNew /
    // installBatch 三处共用同一份判断与提交，不再各写一遍
    // pathExtension == "dylib"。非 dylib 返回 .notDylib，调用
    // 方继续走 IPA 路；dylib 等装完再报结果，调用方直接 return。
    private enum CZFDylibInstallOutcome {
        case notDylib
        case succeeded
        case failed(Error)
    }

    private final class CZFDylibInstallInFlightBox {
        let task: Task<CZFDylibInstallOutcome, Never>
        init(_ task: Task<CZFDylibInstallOutcome, Never>) { self.task = task }
    }
    @State private var czfDylibInstallInFlight: [String: CZFDylibInstallInFlightBox] = [:]

    @MainActor
    // L157-1：在途合并——同一 dylib 双击/重入时只装一份：行里
    // “安装”/“更新”按钮（banner :2483/:2575、详情页 :2765、
    // 格子 :1040）点下去不禁用，dylib 分支是裸 Task（install
    // :1669、installAsNew :1711），双击就并行跑两份 installTweak，下载各走
    // 各的临时文件，最后都进 czfReplaceTweakFile 换同一个
    // destURL：常见一路是两份都验到旧文件在、第二份挪 .bak
    // 时撞空抛错，装其实成了、用户却看到一条系统原样报错；
    // 极窄一路（第二份的存在检查正好落在第一份挪走旧文件、
    // 还没挪进新文件的微秒缝里）是第二份挪新文件时撞已存在
    // 而抛错，catch 里删 dest、旧文件也没了——插件整个被删
    // 掉（跳过清单 55 是源页与面板同时装同款的同根竞态，
    // 本修只拦源页内这一路，55 仍在）。修法照图标缓存
    // CZFSourceIconCache 的在途合并同款（:3038 InFlightBox +
    // 身份比对再清）：按目标文件全路径（文件夹“名-包名”+
    // 文件名，与 installTweak 的 destURL 同款拼法）记在途
    // Task，第二路直接等同一个任务的结果；单装一路行为不变。
    // 在途表放 @State——本方法是 View 结构体的非 mutating
    // 方法，普通存储属性写不进去；@State 的 setter 是
    // nonmutating，同一视图身份下各次调用共用同一份表。
    // 3.8.542（L157）
    private func installTweakIfDylib(app: AltStoreSourceApp) async -> CZFDylibInstallOutcome {
        // 3.8.672（B-1）：去重键走共用 czfDylibInstallKey（行在途态
        // 同一口径）；helper 已验 dylib + 链接存在，downloadURL
        // 再解一次只是取值。
        guard let key = czfDylibInstallKey(for: app),
              let downloadURL = app.latestVersion?.downloadURL else {
            return .notDylib
        }
        if let existing = czfDylibInstallInFlight[key] {
            return await existing.task.value
        }
        let box = CZFDylibInstallInFlightBox(Task<CZFDylibInstallOutcome, Never> {
            if let error = await self.installTweak(from: downloadURL, name: app.name, bundleIdentifier: app.bundleIdentifier) {
                return .failed(error)
            }
            return .succeeded
        })
        czfDylibInstallInFlight[key] = box
        let result = await box.task.value
        if czfDylibInstallInFlight[key] === box { czfDylibInstallInFlight.removeValue(forKey: key) }
        return result
    }

    /// 批量安装一组 App（勾选批量装、「全部更新」共用）：
    /// 全部发给 App 页的安装队列串行执行，autoReplace =
    /// 已装同款直接覆盖、不逐个弹框确认
    /// O-4：返回（入队/跳过/失败）汇总，不再静默跳过。入队
    /// 只是“已交给 App 页队列”，真正的成功/失败由 App 页安
    /// 装队列的汇总报（LCAppListView 的批量收尾）；这里的
    /// failed 只是批量前置失败（无下载链接、dylib 下载/签
    /// 名失败）。
    /// dylib 失败的可见反馈：czfShowBatchResult 现在无论是
    /// 否切走都写 errorMessage，没切走当场弹、切走了切回源
    /// 页时再弹，不再静默丢掉。要让它进 App 页安装队列收尾
    /// 的汇总里，得改 LCAppListView.swift——在
    /// drainPendingInstalls / notifyBatchDone 处接一份“源页
    /// 批量前置失败”名单（例如 CZFSourcePendingInstall 同款
    /// 共享数组，App 页排空时读出来拼进批量汇总/通知）。那
    /// 是更及时的通道，本次不动（在我的文件之外）。
    @MainActor
    private func installBatch(_ apps: [AltStoreSourceApp]) async -> CZFInstallBatchResult {
        var result = CZFInstallBatchResult()
        var switchedTab = false
        // 3.8.672（B-2）：改两遍——第一遍只把全部非 dylib 的 IPA
        // 入队（并照常切 App 页，让安装队列立即开工）；第二遍再
        // 串行处理 dylib（仍 await installTweakIfDylib、仍进同一份
        // result 计数，汇总文案与 czfShowBatchResult 调用点不动）。
        // 原来一遍循环里 dylib 走 await 全程等完才计数，名单以
        // dylib 开头时切页与入队全被拖后；S-8 的本意只是“等装完
        // 再数，失败进汇总”，并未要求“先装插件再排 IPA”。
        var dylibApps: [AltStoreSourceApp] = []
        for app in apps {
            guard let downloadURL = app.latestVersion?.downloadURL else {
                result.skipped.append(app.name)
                continue
            }
            if downloadURL.pathExtension.lowercased() == "dylib" {
                dylibApps.append(app)
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
        for app in dylibApps {
            // S-8：dylib 走共用分支（installTweakIfDylib），等装完
            // 再数，失败进汇总，不再后台 Task 静默丢掉。
            switch await installTweakIfDylib(app: app) {
            case .notDylib:
                break
            case .succeeded:
                result.succeeded.append(app.name)
                continue
            case .failed(let error):
                result.failed.append((name: app.name, reason: error.localizedDescription))
                continue
            }
        }
        return result
    }

    /// 已装且源里有更高版本的 App（「全部更新」的名单）：
    /// 版本号按数字段比较（1.10 > 1.9），同包名只算一次。
    /// 同包名多个变体（汉化版/原版，czfStableID 不同）时留
    /// 版本号最新的那一个，不留先遇到的那一个——原来 seen
    /// 按包名先到先得，源里原版 1.0 排在汉化版 1.2 前面时，
    /// 名单里就是 1.0，点更新装完 1.0、1.2 又冒出来，得更新
    /// 两次。顺序仍按首次出现的包名排，不改名单顺序。
    // 3.8.702（F2）：includeIgnored=true 时不过滤已忽略的 App——
    // refreshUpdatableCache 用它给字典补“已忽略但有新版”的最新版
    //（App 页“取消忽略更新”要这个值判定）；可更新名单与红点仍走
    // 默认 false，不进忽略的 App。
    private func computeUpdatableApps(includeIgnored: Bool = false) -> [AltStoreSourceApp] {
        // 3.8.637（B1）：已装键是个人 ID 改写后的 ID、源里的键是原始 ID，
        // 精确比对查不到、Tab 红点不到它。两边都归一到去队尾段的 ID。
        // 3.8.649（B2）：同包名多分身时取最旧实例的版本 / build——
        // 只留首个实例（uniquingKeysWith: { first, _ in first }）时，
        // 首个新、旧分身仍低于源最新版，更新永不检出；哪边排前面
        // 由扫描顺序定，行为还不稳定。取最旧 = 任一实例低于源
        // 最新版即算有更新。
        var czfOldestByID: [String: (version: String, build: String)] = [:]
        for app in sharedModel.apps + sharedModel.hiddenApps {
            let key = czfNormalizedBundleID(app.appInfo.bundleIdentifier() ?? "")
            let version = app.appInfo.version() ?? ""
            let build = app.appInfo.buildVersion() ?? "0"
            if let existing = czfOldestByID[key] {
                if czfIsNewerVersion(existing.version, build: existing.build, newerThan: version, installedBuild: build) {
                    czfOldestByID[key] = (version, build)
                }
            } else {
                czfOldestByID[key] = (version, build)
            }
        }
        let installed = Dictionary(uniqueKeysWithValues: czfOldestByID.map { ($0.key, $0.value.version) })
        let installedBuilds = Dictionary(uniqueKeysWithValues: czfOldestByID.map { ($0.key, $0.value.build) })
        var bestByBundle: [String: AltStoreSourceApp] = [:]
        var order: [String] = []
        for item in viewModel.sources {
            // 3.8.658（F2）：停用源不参与可更新计算——缓存内容照常
            // 显示、可安装，只是不再把它算进可更新名单与红点。
            guard !viewModel.isSourcePaused(item.url) else { continue }
            guard let source = item.source else { continue }
            for app in source.apps {
                guard let latest = app.latestVersion,
                      let installedVersion = installed[czfNormalizedBundleID(app.bundleIdentifier)],
                      czfIsNewerVersion(latest.version, build: latest.buildVersion, newerThan: installedVersion, installedBuild: installedBuilds[czfNormalizedBundleID(app.bundleIdentifier)]),
                      includeIgnored || !CZFUpdateIgnore.isIgnoredStored(CZFUpdateIgnore.ignoredVersion(for: app.bundleIdentifier), version: latest.version, build: latest.buildVersion) else {
                    continue
                }
                if let existing = bestByBundle[app.bundleIdentifier] {
                    // existing.latestVersion?.buildVersion 是 String??，
                    // 直接传给 String? 参数编不过；先解包再比。
                    if let existingLatest = existing.latestVersion,
                       czfIsNewerVersion(latest.version, build: latest.buildVersion, newerThan: existingLatest.version, installedBuild: existingLatest.buildVersion) {
                        bestByBundle[app.bundleIdentifier] = app
                    }
                } else {
                    bestByBundle[app.bundleIdentifier] = app
                    order.append(app.bundleIdentifier)
                }
            }
        }
        return order.compactMap { bestByBundle[$0] }
    }

    // 可更新名单缓存刷新：算一次、同时写红点。调用点=全部输入
    // 变化处：进页、源变、已装/隐藏变、忽略与 App 打开刷新请求
    private func refreshUpdatableCache() {
        // 跳过滤掉：跳过的版本不回名单、不计红点；源出了新版本
        // （版本号对不上记的）就重新出现。先清过期条目。
        CZFSkippedUpdate.pruneStale(installed: sharedModel.apps + sharedModel.hiddenApps)
        let list = computeUpdatableApps().filter { !CZFSkippedUpdate.isSkipped($0) }
        cachedUpdatableApps = list
        updatableCountBadge = list.count
        // 3.8.643（F3）：顺带把名单的归一 Bundle ID 集合写进 AppStorage，
        // 供 App 页“仅可更新”开关过滤；归一口径与 computeUpdatableApps
        // 同款 czfNormalizedBundleID（去队尾段），不归一就比对不上
        // 个人 ID 改写后的 ID（3.8.637 B1 同款教训）。
        updatableBundleIDs = list.map { czfNormalizedBundleID($0.bundleIdentifier) }.joined(separator: ",")
        // 3.8.702（F2）：顺带写最新版本字典——名单里的可更新 App +
        // 已忽略但有新版的 App（computeUpdatableApps(includeIgnored:)
        // 再算一份、只留 isIgnored 的；跳过的 App 不在名单里、也不进
        // 字典，App 页 hasUpdate 口径与“仅可更新”一致）。
        // latestVersion 在 computeUpdatableApps 里已守卫非空。
        var czfLatestDict: [String: String] = [:]
        for app in list {
            if let latest = app.latestVersion {
                czfLatestDict[czfNormalizedBundleID(app.bundleIdentifier)] = CZFUpdateIgnore.ignoredKey(version: latest.version, build: latest.buildVersion)
            }
        }
        for app in computeUpdatableApps(includeIgnored: true) where CZFUpdateIgnore.isIgnored(app) {
            if let latest = app.latestVersion {
                czfLatestDict[czfNormalizedBundleID(app.bundleIdentifier)] = CZFUpdateIgnore.ignoredKey(version: latest.version, build: latest.buildVersion)
            }
        }
        updatableLatestVersions = CZFUpdateIgnore.latestVersionsString(from: czfLatestDict)
        // 3.8.704（F-3）：顺带写最新版下载 URL 字典——App 页“更新这个
        // App”读它；只含可更新名单里的 App（已忽略/已跳过/暂停源天然
        // 不在名单里，与“仅可更新”口径一致）。逗号串存不下 URL（查询
        // 串含 `=`/`,`，会切坏格式），走 CZFSkippedUpdate 同款
        // [String: String] 整存整取、每次全量重写，过期键随重算自动
        // 消失（已装/已忽略/已跳过时不再写入）。
        var czfDownloadURLDict: [String: String] = [:]
        for app in list {
            if let latest = app.latestVersion {
                czfDownloadURLDict[czfNormalizedBundleID(app.bundleIdentifier)] = latest.downloadURL.absoluteString
            }
        }
        UserDefaults.standard.set(czfDownloadURLDict, forKey: "CZFUpdatableDownloadURLs")
    }

    // 3.8.696（F1）：本源可更新子集——cachedUpdatableApps 按
    // czfStableID（包名 + 名字，跨源同键）与该源 filteredApps
    // 取交集；暂停源 computeUpdatableApps 已跳过，子集天然为 0。
    // 同一 App 跨两源时两边按钮都会带它，装的是名单里那一份
    // 最新版，不会多装，不另做归属逻辑。
    private func czfUpdatableApps(for sourceApps: [AltStoreSourceApp]) -> [AltStoreSourceApp] {
        let ids = Set(sourceApps.map { $0.czfStableID })
        return cachedUpdatableApps.filter { ids.contains($0.czfStableID) }
    }

    // 3.8.696（F1）：组头“更新本源全部 App”的执行——与“全部更新”
    // onUpdateAll（:1559-1564）同一形态：Task { @MainActor in
    // installBatch + czfShowBatchResult }；installBatch 与
    // czfShowBatchResult 都是 @MainActor。
    private func czfUpdateSourceApps(apps: [AltStoreSourceApp]) {
        Task { @MainActor in
            let result = await installBatch(apps)
            czfShowBatchResult(result)
        }
    }

    @MainActor
    private func install(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        if downloadURL.pathExtension.lowercased() == "dylib" {
            // O-4：单装 dylib 不切 Tab，用户还留在源页，失败走
            // 源页 errorMessage 能看见；S-8：走共用分支，等结果
            // 再决定反馈（失败才写 errorMessage）。
            // 3.8.672（B-1）：在途态——点下去先挂键（行按钮变转圈
            // + 禁用，去重逻辑不动，重复点按仍由
            // czfDylibInstallInFlight 拦）；成功/失败都清键，
            // 成功再挂成功提示（失败仍走 errorMessage）。
            if let key = czfDylibInstallKey(for: app) {
                czfDylibInstallingIDs.insert(key)
            }
            Task {
                let outcome = await installTweakIfDylib(app: app)
                // 3.8.519（L44）：本 Task 是裸 Task、不在主 actor
                // 上（L40 同款），errorMessage 是 @State，回主线程再写。
                await MainActor.run {
                    if let key = czfDylibInstallKey(for: app) {
                        czfDylibInstallingIDs.remove(key)
                    }
                    switch outcome {
                    case .failed(let error):
                        errorMessage = error.localizedDescription
                    case .succeeded:
                        czfDylibInstallSuccessName = app.name
                    case .notDylib:
                        break
                    }
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

    // TwoYi 安卓系统（3.8.628）：开 = 下载 IPA 装成 guest。
    // 走共享 DownloadHelper（全局弹窗、单飞锁；下载中文案明示、
    // 按钮禁用防重复点按）。下载前先做 installIpaFile 同款
    // 3 倍空间预检（609MB×3），别让用户下完才知空间不够。
    // 落盘 tmp/LCWebDownload-<UUID>/TwoYi.ipa：installFromUrl
    // 本地分支成功后整目录删（只认父目录名前缀 LCWebDownload-
    // 且父目录是 tmp 的直接子目录，见 LCAppListView 本地分支；
    // 直接放 tmp/LCWebDownload-<UUID>.ipa 不行——父目录是 tmp，
    // 前缀对不上，不会被清）。装完走源页待装队列 + preview，
    // 与源页单装同款（App 页排空进安装队列）。
    @MainActor
    private func czfInstallTwoYi() {
        // 3.8.672（F-1）：下载排队——TwoYi 同款守门改入队：正在
        // 下载时不再顶回去（删掉上面的 isDownloading 守门），
        // 共享 DownloadHelper 的排队名册里等锁，拿到锁自动开始。
        let need = CZFTwoYi.downloadSize * 3
        if let fsAttrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSize = (fsAttrs[.systemFreeSize] as? NSNumber)?.int64Value,
           freeSize < need {
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            errorMessage = "存储空间不足：安装这个应用约需 \(fmt.string(fromByteCount: need)) 空闲空间，当前只剩 \(fmt.string(fromByteCount: freeSize))"
            return
        }
        czfTwoYiDownloading = true
        Task {
            let fm = FileManager.default
            let dirURL = fm.temporaryDirectory.appendingPathComponent("LCWebDownload-\(UUID().uuidString)")
            let tmpURL = dirURL.appendingPathComponent("TwoYi.ipa")
            do {
                try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try await downloadHelper.download(url: CZFTwoYi.downloadURL, to: tmpURL)
                guard LCUtils.czfFileHasPrefix(tmpURL, prefixes: LCUtils.czfExpectedPrefixes(for: tmpURL)) else {
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败，服务器返回了无效文件"])
                }
                await MainActor.run {
                    czfTwoYiDownloading = false
                    withAnimation {
                        DataManager.shared.model.selectedTab = .apps
                    }
                    CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: tmpURL, autoReplace: false, preview: true, forceAsNew: false))
                }
            } catch {
                // 下载失败/取消/魔数不对：本次落盘的临时目录没用了
                // （重试会换新 UUID 目录），删掉，别留 609MB 残包；
                // 取消不弹错（与 czfDownloadVersionTo 同款）。
                try? fm.removeItem(at: dirURL)
                await MainActor.run {
                    czfTwoYiDownloading = false
                    if !downloadHelper.cancelled {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    // TwoYi 安卓系统（3.8.628）：关 = 删掉 TwoYi guest。
    // 文件删除走横幅卡共用 deleteAppFiles（删包、删容器、
    // 钥匙串、未锁定备份；正在运行先拦）；列表摘除内联抄
    // LCAppListView.removeApp（摘三表 + VPN 取消/清键 +
    // dock 刷新，源页没有 LCAppListView 实例）。
    // 删前先清待装队列里躺着的 TwoYi 项（下载完已入队、还没
    // 排空的），不然删完它又自己装回来；同 URL 的临时目录
    // 一并删（只认 LCWebDownload- 前缀的父目录，与
    // installFromUrl 的清理同款口径）。
    private func czfDeleteTwoYi(removeDataFolders: Bool) async {
        // 3.8.900（L566-5）同款：本函数从确认框按钮的 Task 调来、
        // 不在主线程；取目标与清待装队列回主线程做。
        let app: LCAppModel? = await MainActor.run {
            let target = czfTwoYiApp
            CZFSourcePendingInstall.items.removeAll { item in
                guard item.url.lastPathComponent == "TwoYi.ipa",
                      item.url.deletingLastPathComponent().lastPathComponent.hasPrefix("LCWebDownload-") else { return false }
                try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
                return true
            }
            return target
        }
        guard let app else { return }
        do {
            let (failedContainers, keptBackupName) = try await LCAppBannerViewController.deleteAppFiles(
                app,
                removeDataFolders: removeDataFolders,
                removeFromList: { model in
                    sharedModel.apps.removeAll { $0 == model }
                    sharedModel.hiddenApps.removeAll { $0 == model }
                    sharedModel.arm32EmuApps.removeAll { $0 == model }
                    CZFVPNManager.shared.cancelDeferredEnsure(for: model.appInfo)
                    CZFVPNManager.clearVPNSettings(for: model.appInfo)
                    if #available(iOS 16.0, *) {
                        MultitaskDockManager.refreshAfterAppChanged()
                    }
                }
            )
            var messages: [String] = []
            if !failedContainers.isEmpty {
                messages.append("以下容器删除失败，已保留：\(failedContainers.joined(separator: "、"))")
            }
            if let kept = keptBackupName {
                messages.append("备份「\(kept)」已锁定，已保留")
            }
            if !messages.isEmpty {
                await MainActor.run { errorMessage = messages.joined(separator: "\n") }
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
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
            // S-8：走共用分支，等结果再决定反馈（失败才写 errorMessage）。
            Task {
                if case .failed(let error) = await installTweakIfDylib(app: app) {
                    // 3.8.519（L44）：本 Task 是裸 Task、不在主 actor
                    // 上（L40 同款），errorMessage 是 @State，回主线程再写。
                    await MainActor.run { errorMessage = error.localizedDescription }
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
            // S-7：插件下载同款走 DownloadHelper（失败重试 3 次/
            // 断点续传），用独立实例——不占 App 页安装队列的共享
            // 实例，不抢进度弹窗（与 LCAppListView 预取同款做法）。
            let helper = DownloadHelper()
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("CZFTweak-\(UUID().uuidString).dylib")
            try await helper.download(url: url, to: tempURL)
            // DownloadHelper 不验 HTTP 状态：404 错误页也会落盘成
            // “插件文件”再签名；验 Mach-O 魔数，错了按下载失败报
            // （替掉原来的 2xx 状态校验，作用一样）。
            guard LCUtils.czfFileHasPrefix(tempURL, prefixes: LCUtils.czfExpectedPrefixes(for: url)) else {
                try? FileManager.default.removeItem(at: tempURL)
                throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败，服务器返回了无效文件"])
            }
            let fm = FileManager.default
            // 按“插件名-包名”建文件夹，不全塞一个。
            let folderURL = LCPath.tweakPath.appendingPathComponent("\(name)-\(bundleIdentifier)")
            if !fm.fileExists(atPath: folderURL.path) {
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
            // 换文件并签名走共用（带回滚）：旧文件先挪 .bak，签失败
            // 恢复旧的，不丢能用的插件。
            let destURL = folderURL.appendingPathComponent(LCUtils.czfTweakFileName(for: url))
            try await LCUtils.czfReplaceTweakFile(tempURL: tempURL, destURL: destURL, folderURL: folderURL)
            // 3.8.557（L303-1）：源页装插件建了文件夹却没进 tweakFolderNames 注册表——
            // 注册表只在冷启动扫描（LiveContainerSwiftUIApp.swift:142）与模块页新建/改名
            // （LCTweaksView.swift:814）时维护；面板 installTweakFromPanel 同款漏了，
            // L302-1 已修（K:4970），源页这里也漏了。后果：本次启动内 App 设置
            // （LCAppSettingsView.swift:399）/网格（CZFAppGridView.swift:717）/
            // 横幅菜单（LCAppBannerViewController.swift:477）里看不到刚装的文件夹、
            // 挂不上去，重启才出现。修法：装成功后按 L96 同口径（去 .disabled 后缀、
            // 表里没有才加）登记；失败走 catch，不登记。installTweak 本身非
            // @MainActor、await 之后执行器不保证主线程，注册走 MainActor.run
            // （L299-4 同款）；S 与 T 同 target，直接用 LCTweakItem.disabledSuffix。
            let folderName = "\(name)-\(bundleIdentifier)"
            let registryName = folderName.hasSuffix(LCTweakItem.disabledSuffix) ? String(folderName.dropLast(LCTweakItem.disabledSuffix.count)) : folderName
            await MainActor.run {
                if !sharedModel.tweakFolderNames.contains(registryName) {
                    sharedModel.tweakFolderNames.append(registryName)
                }
            }
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
    // 下到文稿目录，再弹分享框；失败走 errorMessage。
    // download(app:) 已改走它，行为不变。
    // S-7：先算目标路径——同名文件已存在时先弹覆盖确认
    // （不先下、不静默覆盖），确认后才调 czfDownloadVersionTo；
    // 共享下载器一次只能下一路，App 页安装正在下载时先提示、不抢。
    @MainActor
    private func downloadVersion(url downloadURL: URL) {
        // 裸域名/无路径链接 lastPathComponent 为空，destURL 会是
        // Documents 目录本身；裸 UUID 无 .ipa 后缀落盘成无扩展名
        // 文件，Files 不认 IPA。照抄 installFromUrl 的兜底（空名
        // 用 app.ipa），缺后缀补 .ipa。dylib 例外：空名用
        // tweak.dylib、缺后缀不补 .ipa——以前 foo.dylib 会被改
        // 成 foo.dylib.ipa，分享出去是错名。
        let isDylib = downloadURL.pathExtension.lowercased() == "dylib"
        var fileName = downloadURL.lastPathComponent
        if fileName.isEmpty {
            fileName = isDylib ? "tweak.dylib" : "app.ipa"
        } else if !isDylib && !fileName.lowercased().hasSuffix(".ipa") {
            fileName += ".ipa"
        }
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destURL = docsURL.appendingPathComponent(fileName)
        // 3.8.672（F-1）：下载排队——正在下载时不再顶回去（删掉
        // 上面的 isDownloading 守门），直接进 czfDownloadVersionTo，
        // 共享 DownloadHelper 的排队名册里等锁，拿到锁自动开始。
        if FileManager.default.fileExists(atPath: destURL.path) {
            czfDownloadOverwritePending = (url: downloadURL, destURL: destURL)
            return
        }
        czfDownloadVersionTo(url: downloadURL, destURL: destURL)
    }

    // 3.8.672（F-2）：三选框“安装”按钮与自动安装共用的入队一步——
    // 切 App 页 + 写共享待装队列（preview: true，不重新下载）；
    // 顺手清掉三选框待装位（自动安装路本来就没有它，置 nil 无害）。
    @MainActor
    private func czfInstallDownloadedFile(_ destURL: URL) {
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: destURL, autoReplace: false, preview: true, forceAsNew: false))
        czfDownloadedFilePending = nil
    }

    // S-7：存文件下载真正下的一步——走共享 DownloadHelper
    // （与安装下载同一套：Tab 级进度弹窗/取消/断点续传/失败
    // 重试 3 次），不再用 hostSession().download 静默下载。
    // DownloadHelper 不验 HTTP 状态：404 错误页也会落盘成
    // “IPA”，按文件类型验魔数（dylib 是 Mach-O，IPA 是 ZIP），
    // 错了删文件、按下载失败报。以前只验 ZIP，插件点“下载”
    // 永远报“无效文件”。
    // 用户主动取消不弹错（与安装下载同款：cancelled 单独处理）。
    @MainActor
    private func czfDownloadVersionTo(url downloadURL: URL, destURL: URL) {
        Task {
            do {
                try await downloadHelper.download(url: downloadURL, to: destURL)
                guard LCUtils.czfFileHasPrefix(destURL, prefixes: LCUtils.czfExpectedPrefixes(for: downloadURL)) else {
                    try? FileManager.default.removeItem(at: destURL)
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败，服务器返回了无效文件"])
                }
                await MainActor.run {
                    // 3.8.672（F-2）：下载完成后自动安装——开关开且非
                    // dylib 时不置三选框待装位，直接走三选框“安装”同一
                    // 段代码（czfInstallDownloadedFile）；dylib 永远不
                    // 自动安装（无安装入口，16 轮 F-3 同款口径）；
                    // 开关关时现状不变。
                    if czfDownloadAutoInstall, destURL.pathExtension.lowercased() != "dylib" {
                        czfInstallDownloadedFile(destURL)
                    } else {
                        // 3.8.668（F-3）：下完不再直弹分享表——改弹三选框
                        // （安装 / 分享 / 取消），SwiftUI dialog 挂源页
                        // 视图上，异步完成时不怕已有 sheet 顶掉（L85 同款）。
                        czfDownloadedFilePending = destURL
                    }
                    // 3.8.670（F-1）：源页下载完成推一条通知——App 不在
                    // 前台时三选框用户看不到；与三选框并存，不替掉它。
                    czfNotifyDownloadDone(fileName: destURL.lastPathComponent)
                }
            } catch {
                await MainActor.run {
                    if !downloadHelper.cancelled {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    @MainActor
    private func shareFile(at url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        // 3.8.555（L85）：从 rootVC 直弹会被已有弹窗静默顶掉——下载是异步的，
        // 完成时用户可能正开着管理源/全部更新/网格设置 sheet（rootVC 上已有
        // presentedVC），UIKit 直接丢掉这次 present，分享表不出、也不报错，
        // 文件已落盘在 Documents、用户无从得知（L82-1 面板下载同款，修法同款：
        // present 前先走到最顶层）。正常路 rootVC 上没弹窗，走到顶就是它自己，行为不变。
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
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
                            // 3.8.555（L85）：本 Task 是裸 Task，isManagingSources 是
                            // @State——上面注释只把“写”包进 MainActor.run，读还留在
                            // 裸执行器上；读到过期值时 sheet 开着也被判成没开，错误
                            // 直接写父级 errorMessage、被 sheet 盖住静默丢掉，正是
                            // B-11 要防的那一下。读也回主线程（先取再判的两行写法；
                            // if await MainActor.run { ... } { 的双大括号是没编过的新
                            // 形状，不用；MainActor.run({ ... }) 带括号会把闭包当成
                            // resultType，457 红字教训）。
                            let czfManagingSources = await MainActor.run { isManagingSources }
                            if czfManagingSources {
                                // 3.8.519（L44）：本 Task 是裸 Task、不在主
                                // actor 上（L40 同款），isManagingSources/
                                // errorMessage 是 @State，回主线程再写；
                                // 关 sheet 后等 400ms 再弹错的顺序不变。
                                await MainActor.run { isManagingSources = false }
                                try? await Task.sleep(nanoseconds: 400_000_000)
                            }
                            await MainActor.run { errorMessage = error }
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
        } else if url.host == "update-list" {
            // 3.8.698（F1）：App 页“全部更新(n)”的跨页触发——
            // App 页先切源页 Tab 再写 deepLink，源页 onChange/
            // onAppear 守卫（selectedTab == .sources）放行后到
            // 这里；名单非空才弹 sheet（空时不弹，按钮本身只在
            // czfUpdatableCount > 0 时出现，双保险）。
            if !cachedUpdatableApps.isEmpty {
                showUpdatableList = true
            }
        }
    }
}

private struct ManageSourcesSheet: View {
    @ObservedObject var viewModel: AltStoreSourcesViewModel
    @Binding var isPresented: Bool
    let onAdd: (String) async -> String?
    // 3.8.688（B1）：删源后的父级回调——sheet 自己不知道父级
    // LCSourcesView 的 selectedIDs（22 轮 B1 遗留入口：sheet 左滑
    // 删除只清 ViewModel 侧，选中集变幽灵、顶栏“安装”仍亮、点下去
    // 静默空跑）。父级在回调里按 czfSourceSelectionKey 前缀清掉
    // 该源的选中键；不传时按无回调处理，旧调用点不用改。
    // 3.8.688 修法4：默认值放 init 参数上、属性本身不带默认值——
    // let 属性带了 = nil 就是已初始化，init 里再赋一次报
    // immutable value may only be initialized once（3.8.673
    // dylibInstallingIDs 同款写法：属性无默认值，init 参数带 = []）。
    let onRemove: ((AltStoreSourcesViewModel.SourceItem) -> Void)?

    // 3.8.688 修法（构建 run 45876896062 唯一红字原文：
    // LCAltStoreSourcesView.swift:1553:27: error: extra argument
    // 'onRemove' in call）——带默认值的 onRemove 在 memberwise init
    // 下调用点报 extra argument（CZFSourceAppListView :2935、
    // AltStoreSourceSectionView :3092，3.8.673 同款）；显式声明兜底，
    // 参数顺序与声明一致，onRemove 仍带默认值，旧调用点可省。
    // @ObservedObject/@Binding 的写法照仓内现成 init 抄：
    // ObservedObject(wrappedValue:)（LCAppSettingsView :131）、
    // self._isPresented = isPresented（ViewExtensions :167）。
    init(viewModel: AltStoreSourcesViewModel, isPresented: Binding<Bool>, onAdd: @escaping (String) async -> String?, onRemove: ((AltStoreSourcesViewModel.SourceItem) -> Void)? = nil) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._isPresented = isPresented
        self.onAdd = onAdd
        self.onRemove = onRemove
    }

    @State private var manualSourceValue = ""
    @State private var isAddingManual = false
    // S-9 回退（3.8.453 核查）：sheet 内删源不能走父级的 .alert——
    // 父级 alert 被 sheet 盖住会被 UIKit 静默丢弃（S-3 同款），
    // 删了没反应。sheet 内必须自己留 confirmationDialog。
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
                            // 3.8.702（F3）：行长按“复制源链接”——原来只能精确
                            // 长按小字号 URL 再选区复制；文案与写法照抄组头菜单
                            // 同款一行（AltStoreSourceSectionView）。
                            .contextMenu {
                                Button("复制源链接", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = item.url.absoluteString
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
                        // 3.8.690（F1）：从剪贴板粘贴——手动添加框原来
                        // 只有输入框 +“添加源”按钮，链接在别处复制好
                        // 还得手打；读剪贴板填入，焦点跟进输入框，再
                        // 点“添加源”走现成 attemptManualAdd（非 URL
                        // 照旧走 onAdd 的错误文案，不新增错误通道）。
                        HStack(spacing: 8) {
                            TextField("https://example.com/source.json", text: $manualSourceValue)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .focused($isManualFieldFocused)
                            Button {
                                if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                                    manualSourceValue = pasted
                                    isManualFieldFocused = true
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isAddingManual)
                            // 3.8.694（F3）：长按“粘贴并添加”——读剪贴板
                            // 填入后直接调同一 struct 内的 attemptManualAdd()，
                            // 校验与错误通道与点“添加源”一字相同，0 新错误
                            // 通道；点按行为保持 24 轮原样（填入 + 聚焦，
                            // 可再改链接）。不新增按钮、不改布局，不碰删源
                            // 逻辑与父级选中集。
                            .contextMenu {
                                Button {
                                    if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                                        manualSourceValue = pasted
                                        attemptManualAdd()
                                    }
                                } label: {
                                    Label("粘贴并添加", systemImage: "doc.on.clipboard.fill")
                                }
                            }
                        }
                        
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
        .navigationViewStyle(StackNavigationViewStyle())
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
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
                        // 3.8.688（B1）：删源顺带清父级选中集——见上面
                        // onRemove 注释；只改删除后的清理，不碰本
                        // confirmationDialog 宿主（S9 回退禁区）。
                        onRemove?(item)
                        sourcePendingRemoval = nil
                    }
                    Button("lc.common.cancel".loc, role: .cancel) {
                        sourcePendingRemoval = nil
                    }
                } message: { item in
                    Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(item.displayName))
                }
        )
        // 1 添加源失败无反馈：sheet 内本地弹错误，挂在 sheet
        // 自己的层级上，不会被 sheet 盖住吞掉。
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("lc.common.error".loc, isPresented: Binding<Bool>(
                    get: { addError != nil },
                    set: { if !$0 { addError = nil } })
                ) {
                    Button("lc.common.ok".loc, role: .cancel) { addError = nil }
                } message: {
                    Text(addError ?? "")
                }
        )
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
            // 3.8.519（L44）：本 Task 是裸 Task、不在主 actor 上
            //（L40 同款），addError/manualSourceValue/
            // isManualFieldFocused（@FocusState）/isAddingManual
            // 是 @State，回主线程再写。
            if let error = await onAdd(trimmed) {
                await MainActor.run { addError = error }
            } else {
                await MainActor.run {
                    manualSourceValue = ""
                    isManualFieldFocused = false
                }
            }
            await MainActor.run { isAddingManual = false }
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
    // 3.8.672（B-1）：插件在途安装键集——行安装按钮在途时变转圈；
    // 带默认值，网格详情页等复用方不传时按无在途处理。
    let dylibInstallingIDs: Set<String>

    // 3.8.673 修法（红字 8）：显式 init——带默认值的
    // dylibInstallingIDs 在 memberwise init 下调用点报
    // extra argument，显式声明兜底；参数顺序与声明一致，
    // dylibInstallingIDs 仍带默认值，旧调用点可省。
    init(source: AltStoreSource, sourceURL: URL, filteredApps: [AltStoreSourceApp], isFiltering: Bool, onInstall: @escaping (AltStoreSourceApp) -> Void, onInstallAsNew: @escaping (AltStoreSourceApp) -> Void, onDownload: @escaping (AltStoreSourceApp) -> Void, onDownloadVersion: @escaping (URL) -> Void, isBatchMode: Bool, selectedIDs: Set<String>, onToggleSelect: @escaping (URL, AltStoreSourceApp) -> Void, dylibInstallingIDs: Set<String> = []) {
        self.source = source
        self.sourceURL = sourceURL
        self.filteredApps = filteredApps
        self.isFiltering = isFiltering
        self.onInstall = onInstall
        self.onInstallAsNew = onInstallAsNew
        self.onDownload = onDownload
        self.onDownloadVersion = onDownloadVersion
        self.isBatchMode = isBatchMode
        self.selectedIDs = selectedIDs
        self.onToggleSelect = onToggleSelect
        self.dylibInstallingIDs = dylibInstallingIDs
    }

    @State private var showAllApps = false

    // 3.8.604（O-18）：已装查找表在父级一次算好，传给行
    // （见 CZFInstalledLookup）。sharedModel 来自源页同层
    // 环境（行原来自己读它）。插件候选路径只对列表里带
    // dylib 最新版的 App 算；filteredApps 已是父级算好的
    // 列表，这里直接用，不重算。
    @EnvironmentObject private var sharedModel: SharedModel

    private var czfInstalledLookup: CZFInstalledLookup {
        let pluginPaths: [String] = filteredApps.flatMap { app -> [String] in
            guard let downloadURL = app.latestVersion?.downloadURL,
                  downloadURL.pathExtension.lowercased() == "dylib",
                  !downloadURL.lastPathComponent.isEmpty else { return [] }
            let file = downloadURL.lastPathComponent
            return [
                LCPath.tweakPath.appendingPathComponent("\(app.name)-\(app.bundleIdentifier)").appendingPathComponent(file).path,
                LCPath.tweakPath.appendingPathComponent(app.name).appendingPathComponent(file).path
            ]
        }
        return CZFInstalledLookup(apps: sharedModel.apps, hiddenApps: sharedModel.hiddenApps, pluginPaths: pluginPaths)
    }

    var body: some View {
        VStack(spacing: 12) {
            // 2 列表行身份稳定：ForEach 不用默认 UUID id（每次
            // 解码重新生成，刷新一次全部行换身份、详情 sheet
            // 被关掉），改用包名+版本号的稳定身份。
            ForEach(filteredApps[0..<(showAllApps ? filteredApps.count : min(50, filteredApps.count))], id: \.czfStableID) { app in
                LCSourceAppBanner(app: app, source: source, installAction: onInstall, installAsNewAction: onInstallAsNew, downloadAction: onDownload, downloadVersionAction: onDownloadVersion, isBatchMode: isBatchMode, isSelected: selectedIDs.contains(czfSourceSelectionKey(sourceURL: sourceURL, app: app)), onToggleSelect: { onToggleSelect(sourceURL, app) }, installedLookup: czfInstalledLookup, dylibInstallingIDs: dylibInstallingIDs)
            }
            if filteredApps.isEmpty {
                if source.apps.isEmpty || isFiltering {
                    Text("lc.sources.section.noApps".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if filteredApps.count > 50 {
                Text("lc.sources.section.tooManyApps".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 3.8.696（B2）：展开后要能收回去——原来按钮只在
                // !showAllApps 分支里、点按只写 true，全仓无一处
                // 写回 false；改 toggle，文案按态翻。
                Button(showAllApps ? "收起" : "展开全部（共 \(filteredApps.count) 个）") {
                    showAllApps.toggle()
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// TwoYi 安卓系统（3.8.628，按需下载，不编进包）：
// 组头行 + 说明卡 + 安装/删除按钮；安装状态派生自已装
// guest 列表，不另存开关 key（删 guest 的路有三条，
// Bool 会漂移）。照 CZFInlineIpaFolderSection 的骨架，
// 不用 Toggle——开是 609MB 下载 + 安装的长异步过程，
// Toggle 瞬间翻转、失败要再翻回来，状态机比按钮复杂。
private struct CZFTwoYiSection: View {
    var installed: Bool
    var isDownloading: Bool
    var isQueued: Bool
    var downloadProgress: Float
    var installDisabled: Bool
    var onInstall: () -> Void
    var onRemove: () -> Void
    // 3.8.692（F3）：已装时“打开”——源页列表行对已装 App 都有绿色
    // “打开”钮，TwoYi 是唯一的例外；打开逻辑由父级传入（行上
    // 打开块的骨架，见调用点），TwoYi 只有一个 guest 实例，无
    // 多实例选择器问题。
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "apps.iphone")
                    .foregroundStyle(.secondary)
                Text("lc.twoyi.title".loc)
                    .font(.headline)
                Spacer()
                if isDownloading {
                    // 3.8.690（B2）：排队等待时进度串位——downloadProgress
                    // 是共享 @Published，拿到锁后才重置为 0；正下着别路
                    // IPA 时点 TwoYi，行上立刻显示别路的百分比。还在队
                    // 里时只显“排队中”（现成 lc.download.queued，0 新
                    // key），拿到锁后再显百分比；不新造状态。
                    if isQueued {
                        Text("lc.download.queued".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\("lc.download.downloading".loc) \(Int(downloadProgress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if installed {
                    Text("lc.common.installed".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("lc.twoyi.notInstalled".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("lc.twoyi.desc".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    if installed {
                        // 3.8.692（F3）：已装时并排“打开 + 删除”。
                        Button("lc.common.open".loc, action: onOpen)
                        Button("lc.common.remove".loc, role: .destructive, action: onRemove)
                    } else {
                        Button("lc.common.install".loc, action: onInstall)
                            .disabled(installDisabled)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    // 3.8.658（F2）：停用开关——组头 Menu 里“暂停检查更新 /
    // 恢复检查”，停用后组头补“已暂停”小字。
    let isPaused: Bool
    let onTogglePause: () -> Void
    // 3.8.660（F2）：各源上次成功检查文案（ViewModel 已拼好，
    // 从未成功过为“尚未检查”），组头副标题下单独成行。
    let lastCheckedText: String
    let toggleExpanded: () -> Void
    let isBatchMode: Bool
    let selectedIDs: Set<String>
    let onToggleSelect: (URL, AltStoreSourceApp) -> Void
    // 3.8.672（B-1）：插件在途安装键集——往下传给列表行；
    // 带默认值，旧调用点不传时按无在途处理。
    let dylibInstallingIDs: Set<String>
    // 3.8.696（F1）：本源可更新子集 + 批量安装回调——父级按
    // czfStableID 与该源 filteredApps 取交集算好；空即无菜单项。
    let updateSourceApps: [AltStoreSourceApp]
    let onUpdateSourceApps: ([AltStoreSourceApp]) -> Void

    // 3.8.673 修法（第四轮红字 2）：显式 init——带默认值的
    // dylibInstallingIDs 在 memberwise init 下调用点报
    // extra argument，显式声明兜底；参数顺序与声明一致，
    // dylibInstallingIDs 仍带默认值，旧调用点可省。
    init(item: AltStoreSourcesViewModel.SourceItem, filteredApps: [AltStoreSourceApp], isFiltering: Bool, isExpanded: Bool, onRefresh: @escaping () -> Void, onInstall: @escaping (AltStoreSourceApp) -> Void, onInstallAsNew: @escaping (AltStoreSourceApp) -> Void, onDownload: @escaping (AltStoreSourceApp) -> Void, onDownloadVersion: @escaping (URL) -> Void, onRemove: @escaping () -> Void, isPaused: Bool, onTogglePause: @escaping () -> Void, lastCheckedText: String, toggleExpanded: @escaping () -> Void, isBatchMode: Bool, selectedIDs: Set<String>, onToggleSelect: @escaping (URL, AltStoreSourceApp) -> Void, dylibInstallingIDs: Set<String> = [], updateSourceApps: [AltStoreSourceApp] = [], onUpdateSourceApps: @escaping ([AltStoreSourceApp]) -> Void = { _ in }) {
        self.item = item
        self.filteredApps = filteredApps
        self.isFiltering = isFiltering
        self.isExpanded = isExpanded
        self.onRefresh = onRefresh
        self.onInstall = onInstall
        self.onInstallAsNew = onInstallAsNew
        self.onDownload = onDownload
        self.onDownloadVersion = onDownloadVersion
        self.onRemove = onRemove
        self.isPaused = isPaused
        self.onTogglePause = onTogglePause
        self.lastCheckedText = lastCheckedText
        self.toggleExpanded = toggleExpanded
        self.isBatchMode = isBatchMode
        self.selectedIDs = selectedIDs
        self.onToggleSelect = onToggleSelect
        self.dylibInstallingIDs = dylibInstallingIDs
        self.updateSourceApps = updateSourceApps
        self.onUpdateSourceApps = onUpdateSourceApps
    }

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
                // 3.8.658（F2）：停用后组头补“已暂停”小字——缓存内容
                // 照常显示、可安装，不藏 App。
                if isPaused {
                    Text("已暂停")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // 收起时刷新失败无处显示：有缓存 + 收起时，错误行
                // 藏在未展开的内容里（S1 只在展开/过滤时渲染），
                // 无缓存时大错误块本来就一直显示。组头补一个小黄
                // 三角，点开组看原因；展开/过滤/加载中不重复显示。
                if item.error != nil && !isExpanded && !isFiltering && !item.isLoading {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
                if item.isLoading {
                    ProgressView()
                } else {
                    Menu {
                        Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                        // 3.8.658（F2）：暂停检查更新——留着源、留着缓存，
                        // 只跳过自动刷新与可更新计算；单源手动刷新不拦。
                        Button(isPaused ? "lc.sources.resumeUpdates".loc : "lc.sources.pauseUpdates".loc, systemImage: isPaused ? "play.fill" : "pause.fill", action: onTogglePause)
                        Button("复制源链接", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = item.url.absoluteString
                        }
                        // 3.8.696（F1）：更新本源全部 App——本源可更新子集
                        //（无子集不出现，暂停源子集天然为 0）；批量态下
                        // 不给（删源同款口径）。同一 App 跨两源时两边
                        // 按钮都会带它，装的是名单里那一份最新版，不多装。
                        if !isBatchMode, !updateSourceApps.isEmpty {
                            Button("更新本源全部 App（\(updateSourceApps.count)）", systemImage: "arrow.down.circle") {
                                onUpdateSourceApps(updateSourceApps)
                            }
                        }
                        // 3.8.686（B1）：批量态下不给“删除源”——删源只清
                        // ViewModel 侧，不碰视图层 selectedIDs；删完选中集
                        // 变幽灵、顶栏“安装”仍亮、点下去静默空跑。单项菜单
                        // 21 轮 B2/B3 同款设防；刷新/暂停/复制照常留（只读）。
                        if !isBatchMode {
                            Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // 3.8.660（F2）：副标题与上次检查时间两行 footnote 收到
            // 一个 VStack 里，行距 2pt（UI 打磨：原来两行之间是父级
            // 12pt，太散）；检查时间单独成行，从未成功过显示“尚未检查”。
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if item.source == nil, let host = item.url.host {
                    Text(host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(lastCheckedText)
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
                        onToggleSelect: onToggleSelect,
                        dylibInstallingIDs: dylibInstallingIDs
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

// 版本 + build 二元组比较（只升 build 号的更新也能检出）：
// 版本不等时只比版本；版本相等时比 build（数字比，缺 build 按 0）。
// 三处消费者（computeUpdatableApps、LCSourceAppBanner.hasUpdate、
// CZFSourceGridView 格子）共用这一份。
func czfIsNewerVersion(_ version: String, build: String?, newerThan installedVersion: String, installedBuild: String?) -> Bool {
    if czfIsVersion(version, newerThan: installedVersion) { return true }
    if czfIsVersion(installedVersion, newerThan: version) { return false }
    let aBuild = Int(build ?? "") ?? 0
    let bBuild = Int(installedBuild ?? "") ?? 0
    return aBuild > bBuild
}

// 3.8.672（B-1）：插件安装在途键——与 installTweakIfDylib
// 的去重键同一口径（"\(name)-\(bundleIdentifier)/\(文件名)"），
// 行安装按钮的在途态（LCSourceAppBanner）与去重字典共用这一份；
// 非 dylib 返回 nil。不 private：行与源页共用。
func czfDylibInstallKey(for app: AltStoreSourceApp) -> String? {
    guard let downloadURL = app.latestVersion?.downloadURL,
          downloadURL.pathExtension.lowercased() == "dylib" else {
        return nil
    }
    return "\(app.name)-\(app.bundleIdentifier)/\(LCUtils.czfTweakFileName(for: downloadURL))"
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
    // 3.8.604（O-18）：父级一次算好的已装查找表，行只查表。
    let installedLookup: CZFInstalledLookup
    // 3.8.672（B-1）：插件在途安装键集——在途的插件行安装按钮
    // 变转圈；带默认值，旧调用点不传时按无在途处理。
    let dylibInstallingIDs: Set<String>

    // 3.8.673 修法（红字 7）：显式 init——带默认值的
    // dylibInstallingIDs 在 memberwise init 下调用点报
    // extra argument，显式声明兜底；参数顺序与声明一致，
    // dylibInstallingIDs 仍带默认值，旧调用点可省。
    init(app: AltStoreSourceApp, source: AltStoreSource, installAction: @escaping (AltStoreSourceApp) -> Void, installAsNewAction: @escaping (AltStoreSourceApp) -> Void, downloadAction: @escaping (AltStoreSourceApp) -> Void, downloadVersionAction: @escaping (URL) -> Void, isBatchMode: Bool, isSelected: Bool, onToggleSelect: @escaping () -> Void, installedLookup: CZFInstalledLookup, dylibInstallingIDs: Set<String> = []) {
        self.app = app
        self.source = source
        self.installAction = installAction
        self.installAsNewAction = installAsNewAction
        self.downloadAction = downloadAction
        self.downloadVersionAction = downloadVersionAction
        self.isBatchMode = isBatchMode
        self.isSelected = isSelected
        self.onToggleSelect = onToggleSelect
        self.installedLookup = installedLookup
        self.dylibInstallingIDs = dylibInstallingIDs
    }
    
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @Environment(\.colorScheme) var colorScheme
    @State private var showDetail = false
    @State private var copiedCardURL = false
    // 忽略/取消忽略后翻一下，强制本行按新状态重画
    @State private var ignoreRefresh = false
    // 机制 2：多开时“打开”绝不静默取首个，多个实例弹实例选择
    @State private var showInstancePicker = false
    // 3.8.535（L62-3）：启动失败本地报错——见下面「打开」两处注释。
    @State private var launchError: String?
    
    // 3.8.604（O-18）：以下三处改查表——原来每行各扫一遍
    // 已装列表（isInstalled、installedAppModel、installedAppModels
    // 三遍），每遍调一次 ObjC bundleIdentifier()。
    private var isInstalled: Bool {
        installedLookup.isInstalled(bundleIdentifier: app.bundleIdentifier)
    }
    
    // 注意：installedAppModel 只供 hasUpdate 版本比较；启动绝不走它
    //（多开时“打开”按下面 installedAppModels 走单开直启/多开选实例）。
    private var installedAppModel: LCAppModel? {
        installedLookup.installedModel(bundleIdentifier: app.bundleIdentifier)
    }

    private var installedAppModels: [LCAppModel] {
        installedLookup.installedModels(bundleIdentifier: app.bundleIdentifier)
    }
    
    // 源里版本比已装版本新 → 有更新（被用户忽略的这个版本不算）
    private var hasUpdate: Bool {
        _ = ignoreRefresh
        // latest 先解包：latestVersion?.buildVersion 是 String??（双层
        // 可选），直接传给 String? 参数编不过；解包后 buildVersion
        // 是 String?，单层。
        guard let latest = app.latestVersion,
              let installed = installedAppModel else { return false }
        let sourceVersion = latest.version
        if CZFUpdateIgnore.isIgnoredStored(CZFUpdateIgnore.ignoredVersion(for: app.bundleIdentifier), version: sourceVersion, build: latest.buildVersion) { return false }
        return czfIsNewerVersion(sourceVersion, build: latest.buildVersion, newerThan: installed.appInfo.version(), installedBuild: installed.appInfo.buildVersion())
    }
    
    private var isPluginInstalled: Bool {
        guard let downloadURL = app.latestVersion?.downloadURL,
              downloadURL.pathExtension.lowercased() == "dylib",
              // 空文件名时拼接出的就是文件夹本身，文件夹在就误报“已装”。
              !downloadURL.lastPathComponent.isEmpty else { return false }
        // 低 #10：文件夹名与 installTweak 同款“名-包名”；老版只
        // 有 app.name 的文件夹也认（已装的插件不用重装）。
        // 3.8.604（O-18）：fileExists 只在父级算一次、结果放
        // 表里（见 CZFInstalledLookup），这里只查表，不再每
        // 渲染调两次磁盘 stat。
        let file = downloadURL.lastPathComponent
        let newPath = LCPath.tweakPath.appendingPathComponent("\(app.name)-\(app.bundleIdentifier)").appendingPathComponent(file).path
        if installedLookup.isPluginInstalled(path: newPath) { return true }
        let oldPath = LCPath.tweakPath.appendingPathComponent(app.name).appendingPathComponent(file).path
        return installedLookup.isPluginInstalled(path: oldPath)
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
    
    // 3.8.692 修法 1（构建 run 45890414484 红字原文修）：长按菜单
    // 单抽一个 builder——body 在 :3518 报 `the compiler is unable
    // to type-check this expression in reasonable time`，本批给
    // sheet 调用点加了一个实参、菜单里改了一处绑定，体检查超时；
    // 菜单内容一字不动，只换宿主（3.8.688 同款拆法）。
    @ViewBuilder
    private var czfBannerContextMenu: some View {
        // 3.8.684（F2）：固定到面板——坞源面板行菜单同款入口
        // （MultitaskDockView rowContextMenu），源页不用再绕
        // 进坞找它；文案按固定态翻，0 新 key。
        Button {
            CZFPinnedAppsStore.shared.toggleSourcePin(app)
        } label: {
            Label(CZFPinnedAppsStore.shared.isSourcePinned(app) ? "取消固定" : "固定到面板", systemImage: CZFPinnedAppsStore.shared.isSourcePinned(app) ? "pin.slash" : "pin")
        }
        // 3.8.684（B2）：批量态下不提供忽略/取消忽略——点按已
        // 设防，长按再改忽略名单会绕过批量流程、重算红点；
        // 复制两项与固定项照常留（只读，不碰批量队列）。
        if !isBatchMode {
        if hasUpdate, let latest = app.latestVersion {
            Button {
                // 3.8.692（B3）：忽略记“版本|build”，不是只记短版本。
                CZFUpdateIgnore.setIgnored(CZFUpdateIgnore.ignoredKey(version: latest.version, build: latest.buildVersion), for: app.bundleIdentifier)
                ignoreRefresh.toggle()
                // S-12：只重算红点和「全部更新」名单，不用
                // 联网刷新源——发 CZFRecomputeUpdatableCache，
                // 不再挂"刷新源"的通知。
                NotificationCenter.default.post(name: Notification.Name("CZFRecomputeUpdatableCache"), object: nil)
            } label: {
                Label("忽略此版本", systemImage: "bell.slash")
            }
        }
        if CZFUpdateIgnore.isIgnored(app) {
            Button {
                CZFUpdateIgnore.setIgnored(nil, for: app.bundleIdentifier)
                ignoreRefresh.toggle()
                // S-12：同上，只重算，不刷新源。
                NotificationCenter.default.post(name: Notification.Name("CZFRecomputeUpdatableCache"), object: nil)
            } label: {
                Label("取消忽略更新", systemImage: "bell")
            }
        }
        }
        // 3.8.682（F2）：复制版本号 / 复制 Bundle ID——与 App 页
        // 长按菜单同款（3.8.639/647），源页原来只有“忽略此版本”；
        // 版本号取源最新版，读不到或为 "?" 时不显示（网格 :834
        // 同款判法）；标题硬编码中文。0 新 key。
        if let version = app.latestVersion?.version, version != "?" {
            Button {
                // 3.8.704（B-1）：复制带 build 的版本号，与详情页
                // 版本行文案（czfVersionWithBuild）同一值。
                UIPasteboard.general.string = app.latestVersion?.czfVersionWithBuild
            } label: {
                Label("复制版本号", systemImage: "doc.on.doc")
            }
        }
        Button {
            UIPasteboard.general.string = app.bundleIdentifier
        } label: {
            Label("复制 Bundle ID", systemImage: "doc.on.doc")
        }
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
                    // 3.8.698（B3）：2 秒后复位反馈态——原来只置 true
                    // 永不复位，图标永久变勾、再点也没有新反馈。
                    // binding 先取成局部量再进闭包，不在闭包里碰
                    // self（LCAppListView :886-895 同款 idiom）。
                    let copiedFlag = $copiedCardURL
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedFlag.wrappedValue = false }
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
                                Task {
                                    // S-1：源页「打开」先过锁守卫，认证未通过直接 return。
                                    guard await only.czfAuthenticateIfLocked() else { return }
                                    // 3.8.535（L62-3）：原来 try? 把启动失败整个吞掉——
                                    // 签名失败/证书缺失/签名超时时点了毫无反应，用户只能
                                    // 当“没点上”再点一次。App 页三路（网格 launchAppWithBundleId、
                                    // 多任务 czfGridLaunchMultitask、横幅 runApp）全是
                                    // do/catch + 弹错，源页这里是唯一吞掉的口子；do/catch
                                    // 后写本行本地 launchError 弹（裸 Task，回主线程再写）。
                                    do {
                                        try await only.runApp()
                                    } catch {
                                        await MainActor.run { launchError = error.localizedDescription }
                                    }
                                }
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
                } else if isDylib, let czfInstallingKey = czfDylibInstallKey(for: app), dylibInstallingIDs.contains(czfInstallingKey) {
                    // 3.8.672（B-1）：插件在途——按钮变转圈 + 不可再点
                    //（ProgressView 本身无动作，去重逻辑不动）；
                    // 样式与“安装”钮同一颗胶囊，行高不跳。
                    ProgressView()
                        .tint(.white)
                        .frame(idealWidth: 70)
                        .frame(height: 32)
                        .background(
                            Capsule().fill(dynamicColors ? primaryColor : Color("FontColor"))
                        )
                        .clipShape(Capsule())
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
        // 3.8.686（B3）：批量态下点行身即勾选——与格子同款
        // （CZFSourceGridView :614-620）与 App 页批量行同款
        // （LCAppListView :1758-1764）；原来批量态是空操作，
        // 只能精确点右上角小圆圈。
        .onTapGesture {
            if isBatchMode {
                onToggleSelect()
            } else {
                showDetail = true
            }
        }
        .contextMenu {
            czfBannerContextMenu
        }
        .sheet(isPresented: $showDetail) {
            LCSourceAppDetailView(app: app, source: source, onDownloadVersion: downloadVersionAction, onInstall: installAction, onInstallAsNew: installAsNewAction, installedLookup: installedLookup)
        }
        .sheet(isPresented: $showInstancePicker) {
            NavigationView {
                List(installedAppModels, id: \.self) { model in
                    Button {
                        showInstancePicker = false
                        Task {
                            // S-1：实例选择器「打开」先过锁守卫，认证未通过直接 return。
                            guard await model.czfAuthenticateIfLocked() else { return }
                            // 3.8.535（L62-3）：同款——try? 吞启动失败，do/catch 后
                            // 写本行本地 launchError 弹（裸 Task，回主线程再写）。
                            do {
                                try await model.runApp()
                            } catch {
                                await MainActor.run { launchError = error.localizedDescription }
                            }
                        }
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
        // 3.8.535（L62-3）：启动失败本地弹——挂在本行上，列表/网格两
        // 个宿主都能弹（父级 LCSourcesView 的 errorMessage 在行里够不着，
        // 也不经过它）；实例选择器那路先关单再启动，出错时单已关完。
        .alert("lc.common.error".loc, isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("lc.common.ok".loc, role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? "")
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
    // 3.8.692（F2）：已装查找表——两个调用点（列表行、网格格子）
    // 各自手里都有，详情页拿它算“已装最新版”判据 + 取实例列表；
    // 不传（nil）时一律显示“安装”，老行为。行上的打开逻辑不直
    // 接复用：打开块里 showInstancePicker/launchError 是行私有
    // 的 state，详情页是另一个 struct，根本够不着；实例选择器
    // 与启动失败弹都挂在详情页自己身上（行上的那份在详情 sheet
    // 盖着时弹不出来，也不走父级 errorMessage），打开逻辑照抄
    // 行上骨架放详情页内（见 czfOpenInstalled）。
    // 3.8.692 修法 3（构建 run 45892761379 红字原文修）：`let` 属性
    // 带默认值即已初始化，显式 init 里再赋报 `may only be
    // initialized once`（3.8.688 修法 4 同款）——默认值只放 init
    // 参数上，属性本身不带默认值；两调用点都显式传参，不影响。
    let installedLookup: CZFInstalledLookup?
    // 3.8.692 修法 2（构建 run 45890414484 红字原文修）：显式 init——
    // 网格调用点报 `extra argument 'installedLookup' in call`，行调
    // 用点同款传参却没报；memberwise 合成在 :3518 体检查超时级联
    // 下不可靠，显式声明兜底，与 LCSourceAppBanner 的 3.8.673
    // 显式 init 同款；参数顺序与声明一致，installedLookup 带默认
    // 值，旧调用点可省。
    init(app: AltStoreSourceApp, source: AltStoreSource, onDownloadVersion: @escaping (URL) -> Void, onInstall: @escaping (AltStoreSourceApp) -> Void, onInstallAsNew: @escaping (AltStoreSourceApp) -> Void, installedLookup: CZFInstalledLookup? = nil) {
        self.app = app
        self.source = source
        self.onDownloadVersion = onDownloadVersion
        self.onInstall = onInstall
        self.onInstallAsNew = onInstallAsNew
        self.installedLookup = installedLookup
    }
    @Environment(\.dismiss) private var dismiss
    @State private var copiedDownloadURL = false
    // S-10②：无下载链接时安装/新建不在父级写错（详情单还在
    // dismiss 动画里，父级 alert 会被吞）；在详情页内就地弹。
    @State private var detailError: String?
    // 3.8.692（F2）：详情页内“打开”的实例选择器与启动失败弹——
    // 行上的那份挂在行上，详情 sheet 盖着时弹不出来，故详情页
    // 自己挂一份；与 detailError 的 alert 不在同一条链上
    // （L121 同款：同一视图多个 alert 只认最后一个）。
    @State private var czfShowInstancePicker = false
    @State private var czfLaunchError: String?

    // 从描述或下载链接里找 GitHub 地址
    private var githubURL: URL? {
        if let downloadURL = app.latestVersion?.downloadURL,
           downloadURL.host?.contains("github") == true {
            return downloadURL
        }
        if let desc = app.description,
           let range = desc.range(of: "https://github.com/[^\\s)\"']+", options: .regularExpression) {
            // L141-2：正则是贪心的，描述里链接后跟的句末标点（中文句号
            // “。”最常见，英文句号/逗号/顿号同款）会被吞进 URL，
            // 点“在 GitHub 查看”就 404。去尾部句末标点再建 URL；
            // 无标点时与原来一字相同。
            // 3.8.566（L299-1）：L141-2 的集里只有中文标点 + 英文句号，
            // 英文逗号/冒号/分号/感叹号/问号还在集外——注释自称
            // “英文逗号同款”并不成立（实测集内无 ASCII , : ; ! ?）。
            // 描述里 "…https://github.com/foo/bar, it's great" 这种
            // 英文句式，正则（只挡空白/)/"/'）会把逗号吞进 URL、点
            // 开 404；冒号/分号/感叹号同款。去尾只动末尾字符，带查
            // 询串的链接（末尾不是标点）一字不动。
            let raw = String(desc[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。.，、；：！？.,:;!?"))
            return URL(string: raw)
        }
        return nil
    }

    // 3.8.692（F2）：详情页“打开”判据——与行上同款（非 dylib、
    // 已装、无更新）；hasUpdate 的忽略比对走 B3 的“版本|build”
    // 口径（isIgnoredStored），行/格子/坞同款。
    private var czfDetailIsDylib: Bool {
        app.latestVersion?.downloadURL.pathExtension.lowercased() == "dylib"
    }
    private var czfDetailIsInstalled: Bool {
        guard let lookup = installedLookup else { return false }
        return lookup.isInstalled(bundleIdentifier: app.bundleIdentifier)
    }
    private var czfDetailHasUpdate: Bool {
        guard let lookup = installedLookup,
              let latest = app.latestVersion,
              let installed = lookup.installedModel(bundleIdentifier: app.bundleIdentifier) else { return false }
        let sourceVersion = latest.version
        if CZFUpdateIgnore.isIgnoredStored(CZFUpdateIgnore.ignoredVersion(for: app.bundleIdentifier), version: sourceVersion, build: latest.buildVersion) { return false }
        return czfIsNewerVersion(sourceVersion, build: latest.buildVersion, newerThan: installed.appInfo.version(), installedBuild: installed.appInfo.buildVersion())
    }
    private var czfDetailShowOpen: Bool {
        !czfDetailIsDylib && czfDetailIsInstalled && !czfDetailHasUpdate
    }

    // 3.8.692（F2）：详情页内“打开”——照抄行上打开块的骨架
    // （:3609–3660）：单实例先过锁守卫再 runApp，失败写本页
    // czfLaunchError 弹；多实例弹本页实例选择器（挂在详情页
    // 自己身上，见 body 末尾）。
    private func czfOpenInstalled() {
        guard let lookup = installedLookup else { return }
        let matches = lookup.installedModels(bundleIdentifier: app.bundleIdentifier)
        if matches.count == 1, let only = matches.first {
            Task {
                guard await only.czfAuthenticateIfLocked() else { return }
                do {
                    try await only.runApp()
                } catch {
                    await MainActor.run { czfLaunchError = error.localizedDescription }
                }
            }
        } else if matches.count > 1 {
            czfShowInstancePicker = true
        }
    }

    // 3.8.692（F2）：实例选择器单抽一个 builder——body 已大，
    // sheet 内容不直接塞进 body 表达式（3.8.688 体检查超时
    // 教训）。内容照抄行上那份（:3776–3806）：实例行先关单
    // 再启动，失败写本页 czfLaunchError。
    @ViewBuilder
    private var czfInstancePickerSheet: some View {
        NavigationView {
            List(installedLookup?.installedModels(bundleIdentifier: app.bundleIdentifier) ?? [], id: \.self) { model in
                Button {
                    czfShowInstancePicker = false
                    Task {
                        guard await model.czfAuthenticateIfLocked() else { return }
                        do {
                            try await model.runApp()
                        } catch {
                            await MainActor.run { czfLaunchError = error.localizedDescription }
                        }
                    }
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
                    Button("取消") { czfShowInstancePicker = false }
                }
            }
        }
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
                                // 3.8.704（B-3）：顶部与版本行口径一致，显
                                // “版本 (build)”——只升 build 的更新在顶部
                                // 原来与已装版看起来完全相同。
                                Text("版本 \(latest.czfVersionWithBuild)")
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
                // S-10：顶部补「下载」按钮，与行/格子对齐（只在
                // 有下载链接时出现）；安装/新建无链接时不关单，
                // 在详情页内就地提示，不写父级 errorMessage。
                Section {
                    HStack(spacing: 12) {
                        Button {
                            // 3.8.692（F2）：已装最新版时顶部“安装”变“打开”——
                            // 与列表行绿色“打开”同义；打开不关详情单（行上
                            // 打开也不切页），不验下载链接。有更新/未装/
                            // dylib 时仍是“安装”，老行为。
                            if czfDetailShowOpen {
                                czfOpenInstalled()
                            } else {
                                guard app.latestVersion?.downloadURL != nil else {
                                    detailError = "lc.sources.error.missingDownload".loc
                                    return
                                }
                                dismiss()
                                onInstall(app)
                            }
                        } label: {
                            // 3.8.450（用户 17:47 报“安装按钮不整齐”，
                            // 放大截图实证）：安装用 Label 时图标根本没
                            // 画出来——.borderedProminent 下 Label 的
                            // 图标被吞了，只剩“安装”俩字居中，新建/
                            // 复制是图标+字，三处对不上。改显式 HStack
                            // （Image + Text），图标是独立视图，不走
                            // Label，三处结构完全一致才对齐。
                            HStack(spacing: 6) {
                                Image(systemName: czfDetailShowOpen ? "play.fill" : "square.and.arrow.down")
                                Text(czfDetailShowOpen ? "lc.common.open".loc : "安装")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            guard app.latestVersion?.downloadURL != nil else {
                                detailError = "lc.sources.error.missingDownload".loc
                                return
                            }
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
                                dismiss()
                                onDownloadVersion(downloadURL)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.circle")
                                    Text("下载")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        if let downloadURL = app.latestVersion?.downloadURL {
                            Button {
                                UIPasteboard.general.string = downloadURL.absoluteString
                                copiedDownloadURL = true
                                // 3.8.698（B3）：2 秒后复位反馈态——原来只置
                                // true 永不复位，“复制”钮永久显示“已复制”。
                                // binding 先取成局部量再进闭包，不在闭包里
                                // 碰 self（LCAppListView :886-895 同款 idiom）。
                                let copiedFlag = $copiedDownloadURL
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedFlag.wrappedValue = false }
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
                    // 3.8.546（L175）：版本行身份走 czfStableID——AltStoreSourceAppVersion.id 是每次解码都换的 UUID，源刷新落地换掉整组 App 对象时全部版本行重建，已点进的旧版详情页被顶回详情根（L174-1 同款，面板行是 B-9 修过的 czfStableID）。版本身份只用版本号 + build，不进下载地址。
                    ForEach(app.versions, id: \.czfStableID) { version in
                        NavigationLink {
                            // 3.8.666（F-2）：安装此版本——与最新版横幅的
                            // onInstall（:2061）同款：切 App 页 + 写共享待装
                            // 队列，autoReplace:false（已装同款时走安装队列
                            // 的覆盖确认，不静默覆盖），preview:true（安装前
                            // 预览卡上确认版本号）。
                            LCSourceAppVersionDetailView(app: app, version: version, onDownloadVersion: onDownloadVersion, onInstallVersion: { url in
                                withAnimation {
                                    DataManager.shared.model.selectedTab = .apps
                                }
                                CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: url, autoReplace: false, preview: true, forceAsNew: false))
                            })
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.czfVersionWithBuild)
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
                            // 3.8.690（F2）：版本行长按“安装此版本”——想装
                            // 旧版原来要点行进旧版页再点安装；这里直接装，
                            // 少进一页。行一级没有 onInstallVersion 那个闭包
                            // （它只活在下面旧版页的 destination 里），故把
                            // 3.8.666 F-2 的闭包体原样内联（切 App 页 + 写
                            // 待装队列，autoReplace:false、preview:true）；
                            // “下载”仍保留在旧版页内，不动。
                            // 3.8.698（F2/B2）：版本行长按菜单补“复制下载
                            // 链接”（与“安装此版本”并列，无反馈态，与
                            // 同文件菜单里的复制项同款）；B2：先 dismiss()
                            // 再切 Tab、再写待装队列——与旧版页 :4483 顺序
                            // 一字相同，否则详情单盖住安装预览、点了像
                            // 没反应（3.8.690 F2 内联时把 dismiss() 丢了）。
                            .contextMenu {
                                Button("安装此版本") {
                                    dismiss()
                                    withAnimation {
                                        DataManager.shared.model.selectedTab = .apps
                                    }
                                    CZFSourcePendingInstall.append(CZFSourcePendingInstallItem(url: version.downloadURL, autoReplace: false, preview: true, forceAsNew: false))
                                }
                                Button {
                                    UIPasteboard.general.string = version.downloadURL.absoluteString
                                } label: {
                                    Label("复制下载链接", systemImage: "doc.on.doc")
                                }
                                // 3.8.704（F-1）：复制版本号——与同行显示文案
                                // （version.czfVersionWithBuild）同一值；必须
                                // 用 czfVersionWithBuild 而不是 version.version，
                                // 否则丢 build（B-1 同根）。
                                Button {
                                    UIPasteboard.general.string = version.czfVersionWithBuild
                                } label: {
                                    Label("复制版本号", systemImage: "doc.on.doc")
                                }
                            }
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
            // S-10②：无下载链接的错误在详情页内弹，不写父级。
            .alert("lc.common.error".loc, isPresented: Binding(get: { detailError != nil }, set: { if !$0 { detailError = nil } })) {
                Button("lc.common.ok".loc, role: .cancel) { detailError = nil }
            } message: {
                Text(detailError ?? "")
            }
        }
        // 3.8.692（F2）：实例选择器 + 启动失败弹挂在详情页自己身上——
        // 行上的那份在详情 sheet 盖着时弹不出来；与上面 detailError
        // 的 alert 不在同一条链上（L121 同款：同一视图多个 alert
        // 只认最后一个），各占一条分支。
        .sheet(isPresented: $czfShowInstancePicker) {
            czfInstancePickerSheet
        }
        .alert("lc.common.error".loc, isPresented: Binding(get: { czfLaunchError != nil }, set: { if !$0 { czfLaunchError = nil } })) {
            Button("lc.common.ok".loc, role: .cancel) { czfLaunchError = nil }
        } message: {
            Text(czfLaunchError ?? "")
        }
    }
}

// 旧版下载页：版本行 NavigationLink 推进来，只看这一个旧版、
// 只下这一个旧版的包（downloadURL 是该版自己的，不是最新版）。
// 下载按钮走“下载地址”栏同款：先关详情单再下载，分享框从
// rootVC 弹出，不与详情单叠在一起。
// 3.8.666（F-2）：加「安装此版本」——指定旧版直接装，不只下载文件。
private struct LCSourceAppVersionDetailView: View {
    let app: AltStoreSourceApp
    let version: AltStoreSourceAppVersion
    let onDownloadVersion: (URL) -> Void
    let onInstallVersion: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    // 3.8.696（F3）：复制下载链接的反馈态——主详情页同款（写剪贴板 +
    // 本地 Bool 翻“已复制”，不关单）；带默认值，调用点不动。
    @State private var czfCopiedDownloadURL = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.headline)
                    Text("版本 \(version.czfVersionWithBuild)")
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
                // 3.8.696（F3）：复制下载链接——主详情页同款（写剪贴板 +
                // 本地 Bool 翻“已复制”），复制的是本版链接；旧版页
                // 原来只有下载行 +“安装此版本”，无复制。
                Button {
                    UIPasteboard.general.string = version.downloadURL.absoluteString
                    czfCopiedDownloadURL = true
                    // 3.8.698（B3）：2 秒后复位反馈态——原来只置 true
                    // 永不复位，旧版页“复制下载链接”永久显示“已复制”。
                    // binding 先取成局部量再进闭包，不在闭包里碰
                    // self（LCAppListView :886-895 同款 idiom）。
                    let copiedFlag = $czfCopiedDownloadURL
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedFlag.wrappedValue = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: czfCopiedDownloadURL ? "checkmark" : "doc.on.doc")
                        Text(czfCopiedDownloadURL ? "已复制" : "复制下载链接")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                // 3.8.666（F-2）：安装此版本——先关详情单再写待装队列，
                // 与下载按钮同款顺序；下载按钮保留不动（仍有人只要文件）。
                // UI 打磨：borderedProminent，与详情页「安装」主按钮同款。
                Button {
                    dismiss()
                    onInstallVersion(version.downloadURL)
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("安装此版本")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
    // O-32：在途合并——同一 URL 已在下载时不再另起一个下载，
    // 等同一个任务的结果回来。ioQueue（串行）顺带 guard 这张表，
    // 与磁盘读写共用一把锁；下载任务里只调 ioQueue.async 写盘，
    // 不嵌套 sync，不会死锁。
    // 3.8.534 修法：Task 是 struct，没有身份，=== 编不过；盒子是类，
    // 按盒身份比对再清，只清自己那一项（L85 原意不变）。
    private final class InFlightBox {
        let task: Task<UIImage?, Never>
        init(_ task: Task<UIImage?, Never>) { self.task = task }
    }
    private var inFlight: [String: InFlightBox] = [:]
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
        // 图标走 hostSession：代理开时经节点取（URLSession.shared
        // 绕开代理、图标一直灰占位）；代理关时 hostSession() 回落
        // .shared，行为不变。
        let box: InFlightBox = ioQueue.sync {
            if let existing = inFlight[url.absoluteString] {
                return existing
            }
            let newTask = Task<UIImage?, Never> {
                // D4：先验 HTTP 状态，非 2xx（404 错误页等）直接返 nil，
                // 不缓存坏数据（N2/N3 同款）。失败不缓存，成功才缓存。
                // 3.8.547（L181）：图标会变（同地址换图），绕开 URLCache；磁盘 30 天 TTL 照旧先验。
                guard let (data, response) = try? await CZFVPNManager.freshData(from: url),
                      let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let img = Self.decodedImage(from: data) else { return nil }
                self.store(img, forKey: key)
                if let dest = self.diskURL(for: url) {
                    self.ioQueue.async {
                        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? data.write(to: dest, options: .atomic)
                        // 写完顺手剪掉最旧的，磁盘文件数不超过上限。
                        Self.pruneDisk(base: dest.deletingLastPathComponent(), maxCount: Self.diskMaxCount)
                    }
                }
                return img
            }
            let newBox = InFlightBox(newTask)
            inFlight[url.absoluteString] = newBox
            return newBox
        }
        let result = await box.task.value
        // 3.8.555（L85）：只清自己那一项——原来无条件 removeValue：A、B 两路
        // 等同一个在途任务时，A 先跑完就把表项清掉，C 随后新建任务 T2 登记，
        // B 跑完又清一次、把 T2 也清掉，D 再来就认不出 T2 在途、又另起一次
        // 下载。只多下一次图标，不坏数据；按身份比对再清，零行为变化。
        ioQueue.sync { if inFlight[url.absoluteString] === box { inFlight.removeValue(forKey: url.absoluteString) } }
        return result
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
            let loaded = await CZFSourceIconCache.shared.load(url: url)
            // 3.8.566（L97）：url 换了会取消旧任务，但 load 里等在途
            // 下载的 await 不因调用方取消而提前返回——旧任务跑完仍会
            // 把旧图标写进 image，格子就顶着别人的图标（快滑未缓存
            // 图标的网格时能撞上）；取消了就别写，让新任务的图留着。
            guard !Task.isCancelled else { return }
            image = loaded
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
