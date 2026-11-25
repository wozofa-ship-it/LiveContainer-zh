//
//  LCAppSortManager.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/22.
//

import Foundation
import SwiftUI
import Combine

enum AppSortType: String, CaseIterable {
    case defaultOrder = "default"
    case alphabetical = "alphabetical"
    case reverseAlphabetical = "reverse_alphabetical"
    case lastLaunched = "last_launched"
    case installationDate = "installationDate"
    case custom = "custom"
    // 3.8.645（F2）：按占用大小（从大到小）。
    case bySize = "by_size"
    // 3.8.651（F1）：按签名到期日（最早到期在前）。
    case byExpiry = "by_expiry"
    
    var displayName: String {
        switch self {
        case .defaultOrder:
            return "lc.common.default".loc
        case .alphabetical:
            return "lc.appList.sort.alphabetical".loc
        case .reverseAlphabetical:
            return "lc.appList.sort.reverseAlphabetical".loc
        case .lastLaunched:
            return "lc.appList.sort.lastLaunched".loc
        case .installationDate:
            return "lc.appList.sort.installationDate".loc
        case .custom:
            return "lc.appList.sort.custom".loc
        case .bySize:
            return "lc.appList.sort.bySize".loc
        case .byExpiry:
            return "lc.appList.sort.byExpiry".loc
        }
    }
    
    var systemImage: String {
        switch self {
        case .defaultOrder:
            return "ellipsis"
        case .alphabetical:
            return "chevron.down"
        case .reverseAlphabetical:
            return "chevron.up"
        case .lastLaunched:
            return "clock"
        case .installationDate:
            if #available(iOS 18.0, *) {
                return "square.and.arrow.down.badge.clock"
            } else {
                return "square.and.arrow.down"
            }
        case .custom:
            return "list.bullet"
        case .bySize:
            // iOS 15 已有（SF Symbols 1 时代的符号），无门控问题。
            return "arrow.up.arrow.down"
        case .byExpiry:
            // iOS 15 已有（SF Symbols 1 时代的符号），无门控问题。
            return "hourglass"
        }
    }
}

/// 3.8.645（F2）：App 总占用缓存（包 + 容器），键是 bundlePath。
/// 排序是同步的、大小是全目录遍历——不能现算现排：缓存由存储
/// 管理页刷新时顺带填（同一套快照 + 算法），选“按占用大小”时
/// 缺失的后台逐个补；大小就绪就调 onChange（主线程），排序
/// 管理器订阅它、bySize 下重排。plain 类 + NSLock，不碰
/// @MainActor：排序与存储统计都不在主 actor 上。
final class CZFAppSizeCache {
    static let shared = CZFAppSizeCache()
    private let lock = NSLock()
    private var sizes: [String: Int64] = [:]
    private var inFlight: Set<String> = []
    /// 大小就绪时调（主线程）。
    var onChange: (() -> Void)?

    func size(for app: LCAppModel) -> Int64? {
        guard let path = app.appInfo.bundlePath() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return sizes[path]
    }

    func setSize(_ size: Int64, forBundlePath path: String) {
        lock.lock()
        sizes[path] = size
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// 存储页刷新时批量填（一次只触发一次重排）。
    func setSizes(_ newSizes: [String: Int64]) {
        guard !newSizes.isEmpty else { return }
        lock.lock()
        for (path, size) in newSizes { sizes[path] = size }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// 3.8.649（B1）：按 bundlePath 删旧条目——覆盖安装同文件夹名
    /// 原地替换，缓存 key 不变、旧大小永不重算；安装完成时先失效，
    /// 下次重排即重算。在途的也一并清掉（inFlight），否则
    /// czfEnsureSizes 会把它当“已在算”跳过、失效等于没失。
    /// 不发 onChange——失效后紧接着的 czfEnsureSizes 重算完会
    /// 经 setSize 发一次，够了。
    func removeSize(forBundlePath path: String) {
        lock.lock()
        sizes.removeValue(forKey: path)
        inFlight.remove(path)
        lock.unlock()
    }

    /// 缺失的后台逐个算（czfTotalSize：快照主线程取、算大小放
    /// 后台）；在途的只算一次，算完写缓存、触发重排。调用方在
    /// 主线程上调（appSortType 的 didSet / reloadSortSettings），
    /// Task 的执行器与被调函数本体见下面注释。
    func czfEnsureSizes(for apps: [LCAppModel]) {
        var todo: [(LCAppModel, String)] = []
        lock.lock()
        for app in apps {
            guard let path = app.appInfo.bundlePath(), sizes[path] == nil, !inFlight.contains(path) else { continue }
            inFlight.insert(path)
            todo.append((app, path))
        }
        lock.unlock()
        guard !todo.isEmpty else { return }
        // Task { @MainActor in }（CZFAppGridView 锁按钮同款）：
        // 循环体在主 actor 上跑、每次 await czfTotalSize（@MainActor
        // 类上的 static func，主线程取快照、算大小走 nonisolated
        // 的 calculateAppItem 放后台），不卡主线程；LCAppModel
        // 不是 Sendable，裸 Task 抓它会报 warning，@MainActor
        // 闭包不走那条路。
        Task { @MainActor in
            for (app, path) in todo {
                let size = await LCStorageManagementModel.czfTotalSize(for: app)
                self.lock.lock()
                self.inFlight.remove(path)
                self.lock.unlock()
                self.setSize(size, forBundlePath: path)
            }
        }
    }
}

/// 3.8.651（F1）：签名剩余天数缓存（bundlePath → daysLeft），照抄
/// CZFAppSizeCache 的形状：排序是同步的、天数是后台读盘——不能现算
/// 现排。由列表页 czfRefreshSignatureExpiry 喂数（后台读完一次性
/// 写进来），就绪调 onChange（主线程），排序管理器订阅它、byExpiry
/// 下重排。无到期日（读不到 mobileprovision）的不进表，排序时按
/// “未知”沉底。plain 类 + NSLock，不碰 @MainActor。
final class CZFAppExpiryCache {
    static let shared = CZFAppExpiryCache()
    private let lock = NSLock()
    private var days: [String: Int] = [:]
    /// 天数就绪时调（主线程）。
    var onChange: (() -> Void)?

    func daysLeft(for app: LCAppModel) -> Int? {
        guard let path = app.appInfo.bundlePath() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return days[path]
    }

    /// 列表页刷新后批量喂数（一次只触发一次重排；全量替换，
    /// 重签后续期、删掉的 App 掉出表）。
    func setDays(_ newDays: [String: Int]) {
        lock.lock()
        days = newDays
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}

/// 3.8.641（F1）：App 列表置顶的存储（与坞面板固定区无关）。
/// 键 `CZFListPinnedApps` 是新键，绝不复用坞的 `CZFPinnedPanelApps`
///（否则列表置顶会串进坞固定区）；键格式复用 `CZFPinnedAppsStore.pinKey`
///（`bundleID_dataUUID`，实例粒度，多开分身各置各的）；删 App 重装换
/// dataUUID 后置顶丢失，是与坞固定区同款的已知行为（MultitaskDockView
/// :3587-3590 注释）。0 新本地化 key（菜单标题硬编码中文）。
final class CZFListPinnedStore: ObservableObject {
    static let shared = CZFListPinnedStore()
    @Published private(set) var pinnedIds: [String] = []
    private let defaultsKey = "CZFListPinnedApps"
    init() {
        pinnedIds = LCUtils.appGroupUserDefault.stringArray(forKey: defaultsKey) ?? []
    }
    func isPinned(_ app: LCAppModel) -> Bool { pinnedIds.contains(Self.pinKey(for: app)) }
    /// 键格式唯一来源：坞的 `CZFPinnedAppsStore.pinKey`（实例粒度）。
    static func pinKey(for app: LCAppModel) -> String { CZFPinnedAppsStore.pinKey(for: app) }
    func toggle(_ app: LCAppModel) {
        let key = Self.pinKey(for: app)
        if let idx = pinnedIds.firstIndex(of: key) {
            pinnedIds.remove(at: idx)
        } else {
            pinnedIds.append(key)
        }
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
    }
}

/// Manages the state and logic for sorting the list of applications.
class LCAppSortManager: ObservableObject {
    
    static var shared: LCAppSortManager = LCAppSortManager()
    
    @AppStorage("LCAppSortType", store: LCUtils.appGroupUserDefault) var appSortType: AppSortType = .defaultOrder {
        didSet {
            self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            if DataManager.shared.model.isHiddenAppUnlocked {
                self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
            // 3.8.645（F2）：刚切到“按占用大小”时缓存里还没有的
            // 后台逐个算（算完 onChange 回来重排）；已有大小的
            // 直接按上面这次重排走，不用等。
            if self.appSortType == .bySize {
                CZFAppSizeCache.shared.czfEnsureSizes(for: DataManager.shared.model.apps + DataManager.shared.model.hiddenApps)
            }
            // 排序方式变了就刷新设置备份：导出文件里的
            // LCAppSortType 别滞后，恢复直接拿最新值。
            LCDataManagementView.writeCZFSettingsBackupDebounced()
        }
    }

    @Published var customSortOrder: [String] {
        didSet {
            LCUtils.appGroupUserDefault.set(customSortOrder, forKey: "LCCustomSortOrder")
            // 新1（3.8.277）：当前顺序始终是正在用的方案——顺序
            // 一变就写回该方案，切换方案回来时还是这次的顺序。
            // 值相同不重复写（切方案时写进来的就是该方案的顺序）。
            if schemes[currentSchemeName] != customSortOrder {
                schemes[currentSchemeName] = customSortOrder
            }
            // 自定义顺序变了就刷新设置备份：导出文件里的
            // LCCustomSortOrder 别滞后，恢复直接拿最新顺序。
            LCDataManagementView.writeCZFSettingsBackupDebounced()
        }
    }

    // 新1（3.8.277）：多套排序方案。[方案名: [唯一 ID]]，存
    // App Group 键 LCCustomSortSchemes；currentSchemeName 是
    // 正在用的方案名，存 LCCustomSortSchemeCurrent。方案名是
    // 用户起的任意字符串，不进本地化。
    static let schemesKey = "LCCustomSortSchemes"
    static let currentSchemeKey = "LCCustomSortSchemeCurrent"
    static let defaultSchemeName = "常用"

    @Published var schemes: [String: [String]] {
        didSet {
            LCUtils.appGroupUserDefault.set(schemes, forKey: Self.schemesKey)
            LCDataManagementView.writeCZFSettingsBackupDebounced()
        }
    }

    @Published var currentSchemeName: String {
        didSet {
            LCUtils.appGroupUserDefault.set(currentSchemeName, forKey: Self.currentSchemeKey)
            LCDataManagementView.writeCZFSettingsBackupDebounced()
        }
    }

    /// 切方案：把该方案的顺序写进 customSortOrder 并置 .custom
    ///（customSortOrder 的 didSet 会把它写回该方案——值相同，
    /// 不重复写）。不存在的名字直接忽略。切方案那一下关动画，
    /// 与排序切换同款（优3），免得整列重排闪动。
    func switchScheme(to name: String) {
        guard let order = schemes[name] else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentSchemeName = name
            customSortOrder = order
            appSortType = .custom
        }
    }

    /// 新增空方案（名已存在或空白返回 false）。新方案从空顺序
    /// 起，列表按字母序显示，拖动后即为该方案的顺序。
    @discardableResult
    func addScheme(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, schemes[trimmed] == nil else { return false }
        schemes[trimmed] = []
        return true
    }

    /// 方案改名（新名已存在、空白、或旧名不存在返回 false）。
    /// 正在用的方案改名后 currentSchemeName 跟着走。
    @discardableResult
    func renameScheme(from oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName, let order = schemes[oldName], schemes[trimmed] == nil else { return false }
        schemes.removeValue(forKey: oldName)
        schemes[trimmed] = order
        if currentSchemeName == oldName {
            currentSchemeName = trimmed
        }
        return true
    }

    /// 删方案（不存在或只剩最后一套返回 false）。删的是正在用
    /// 的就切到剩下的第一套（按名字排序），顺序跟着走。
    @discardableResult
    func deleteScheme(named name: String) -> Bool {
        guard schemes[name] != nil, schemes.count > 1 else { return false }
        schemes.removeValue(forKey: name)
        if currentSchemeName == name, let next = schemes.keys.sorted().first {
            switchScheme(to: next)
        }
        return true
    }

    @Published var sortedApps : [LCAppModel] = []
    @Published var sortedHiddenApps : [LCAppModel] = []
    
    private var cancellables = Set<AnyCancellable>()
    // MARK: - Initialization
    
    init() {
        // 新1（3.8.277）：init 里读 self 的属性前必须全部
        // 存储属性都已赋值，迁移/回落先用局部变量算完，再一次
        // 性赋值；didSet 在 init 里不触发，迁移结果直接写回
        // defaults 落盘（只在真正迁移/回落时写，原语义不变）。
        let savedOrder: [String] = LCUtils.appGroupUserDefault.array(forKey: "LCCustomSortOrder") as? [String] ?? []
        let savedSchemes = LCUtils.appGroupUserDefault.dictionary(forKey: Self.schemesKey) as? [String: [String]]
        let schemes: [String: [String]]
        var writeSchemesBack = false
        if let saved = savedSchemes, !saved.isEmpty {
            schemes = saved
        } else {
            // 方案首次用时从现有自定义顺序迁移出一套“常用”，
            // 再补空的“游戏”“工作”两套示例方案；已有方案直接读。
            schemes = [Self.defaultSchemeName: savedOrder, "游戏": [], "工作": []]
            writeSchemesBack = true
        }
        var currentScheme = LCUtils.appGroupUserDefault.string(forKey: Self.currentSchemeKey) ?? Self.defaultSchemeName
        var writeCurrentBack = false
        if schemes[currentScheme] == nil {
            currentScheme = schemes.keys.sorted().first ?? Self.defaultSchemeName
            writeCurrentBack = true
        }
        self.customSortOrder = savedOrder
        self.schemes = schemes
        self.currentSchemeName = currentScheme
        if writeSchemesBack {
            LCUtils.appGroupUserDefault.set(schemes, forKey: Self.schemesKey)
        }
        if writeCurrentBack {
            LCUtils.appGroupUserDefault.set(currentScheme, forKey: Self.currentSchemeKey)
        }
        
        DataManager.shared.model.$apps
            .sink { newValue in
                self.sortedApps = self.getSortedApps(newValue, sortType: self.appSortType, customSortOrder: self.customSortOrder)
                // 3.8.649（B1）：bySize 期间新增 App（安装 / 恢复 /
                // 下拉刷新后出现）没有缓存大小，size(for:) 为 nil
                // 就沉底；这里对缺失的当场补算，算完 onChange 回来
                // 重排、插到正确位置。czfEnsureSizes 自带在途去重，
                // 重复调无害；非 bySize 不调，不浪费 CPU。
                if self.appSortType == .bySize {
                    CZFAppSizeCache.shared.czfEnsureSizes(for: newValue)
                }
            }
            .store(in: &cancellables)
        
        DataManager.shared.model.$hiddenApps
            .sink { newValue in
                self.sortedHiddenApps = self.getSortedApps(newValue, sortType: self.appSortType, customSortOrder: self.customSortOrder)
                // 3.8.649（B1）：隐藏区同款补算。
                if self.appSortType == .bySize {
                    CZFAppSizeCache.shared.czfEnsureSizes(for: newValue)
                }
            }
            .store(in: &cancellables)
        
        $customSortOrder
            .sink { newValue in
                if self.appSortType == .custom {
                    self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: newValue)
                    if DataManager.shared.model.isHiddenAppUnlocked {
                        self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: newValue)
                    }
                }
            }
            .store(in: &cancellables)
        DataManager.shared.model.$isHiddenAppUnlocked
            .sink { newValue in
                if(!newValue) {
                    return
                }
                self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
            .store(in: &cancellables)
        // 3.8.645（F2）：大小缓存就绪（存储页刷新填上 / 后台逐个
        // 算完）时，正在用“按占用大小”就重排；别的排序不动。
        // onChange 在主线程上调（见 CZFAppSizeCache），这里读
        // @Published 数组与重排都在主线程上。
        CZFAppSizeCache.shared.onChange = { [weak self] in
            guard let self, self.appSortType == .bySize else { return }
            self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            if DataManager.shared.model.isHiddenAppUnlocked {
                self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
        }
        // 3.8.651（F1）：到期天数就绪（列表页刷新喂进来）时，
        // 正在用“按到期日”就重排；别的排序不动。
        // onChange 在主线程上调（见 CZFAppExpiryCache），这里读
        // @Published 数组与重排都在主线程上。
        CZFAppExpiryCache.shared.onChange = { [weak self] in
            guard let self, self.appSortType == .byExpiry else { return }
            self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            if DataManager.shared.model.isHiddenAppUnlocked {
                self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
        }
    }
    
    // MARK: - Internal Logic

    /// 导入/恢复后重读排序设置（主线程调）：
    /// customSortOrder 只在 init 读一次，恢复写回 defaults 后
    /// 内存还是旧顺序；这里当场重读重排，列表立即按恢复的
    /// 顺序走，不用等重启。applySettingsDictionary 在排序键
    /// 写回后调（DispatchQueue.main.async 过去）。
    func reloadSortSettings() {
        if let typeRaw = LCUtils.appGroupUserDefault.string(forKey: "LCAppSortType"),
           let type = AppSortType(rawValue: typeRaw) {
            self.appSortType = type
        }
        // 新1：方案也重读。恢复写回的方案与当前方案名都在
        // defaults 里；当前顺序仍以 LCCustomSortOrder 键为准
        //（与正在用的方案保持同步的同一份），customSortOrder
        // 的 didSet 会把它写回正在用的方案。旧备份没有方案键
        // 时不动现有方案，只把恢复的顺序写进正在用的方案。
        if let saved = LCUtils.appGroupUserDefault.dictionary(forKey: Self.schemesKey) as? [String: [String]], !saved.isEmpty {
            self.schemes = saved
        }
        if let current = LCUtils.appGroupUserDefault.string(forKey: Self.currentSchemeKey), schemes[current] != nil {
            self.currentSchemeName = current
        }
        self.customSortOrder = LCUtils.appGroupUserDefault.array(forKey: "LCCustomSortOrder") as? [String] ?? []
        self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
        if DataManager.shared.model.isHiddenAppUnlocked {
            self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
        }
        // 3.8.645（F2）：恢复回来就是 bySize 时也补算（didSet
        // 在这里不触发，上面直接赋值的重排只用了缓存里已有的）。
        if self.appSortType == .bySize {
            CZFAppSizeCache.shared.czfEnsureSizes(for: DataManager.shared.model.apps + DataManager.shared.model.hiddenApps)
        }
    }

    func getUniqueIdentifier(for app: LCAppModel) -> String? {
        guard let bundleId = app.appInfo.bundleIdentifier(),
              let relativePath = app.appInfo.relativeBundlePath else {
            return nil
        }
        return "\(bundleId):\(relativePath)"
    }
    
    func matches(uniqueId: String, app: LCAppModel) -> Bool {
        guard let appUniqueId = getUniqueIdentifier(for: app) else {
            return false
        }
        return uniqueId == appUniqueId
    }
    
    /// 3.8.641（F1）：置顶切换后重排——只重算排序后列表，不重读排序方式/
    /// 方案；sortedApps/sortedHiddenApps 是 @Published，列表页
    /// onChange(of: sortedApps) 随之刷过滤缓存。
    func czfResortAfterPinChange() {
        self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
        if DataManager.shared.model.isHiddenAppUnlocked {
            self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
        }
    }

    func getSortedApps(_ appList: [LCAppModel], sortType: AppSortType, customSortOrder: [String]) -> [LCAppModel] {
        // 3.8.641（F1）：置顶组固定在前——先按置顶键分区，两组各按当前
        // 排序排，再拼起来；八种排序（含默认顺序与自定义）全走同一条路，
        // 置顶组内仍按当前排序排。无置顶时一字不动（直接走老路）。
        let pinnedIds = Set(CZFListPinnedStore.shared.pinnedIds)
        guard appList.contains(where: { pinnedIds.contains(CZFListPinnedStore.pinKey(for: $0)) }) else {
            return czfSortSingleGroup(appList, sortType: sortType, customSortOrder: customSortOrder)
        }
        let pinned = appList.filter { pinnedIds.contains(CZFListPinnedStore.pinKey(for: $0)) }
        let unpinned = appList.filter { !pinnedIds.contains(CZFListPinnedStore.pinKey(for: $0)) }
        return czfSortSingleGroup(pinned, sortType: sortType, customSortOrder: customSortOrder)
            + czfSortSingleGroup(unpinned, sortType: sortType, customSortOrder: customSortOrder)
    }

    private func czfSortSingleGroup(_ appList: [LCAppModel], sortType: AppSortType, customSortOrder: [String]) -> [LCAppModel] {
        switch sortType {
        case .defaultOrder:
            return appList
        case .alphabetical:
            return appList.sorted { $0.appInfo.displayName().localizedStandardCompare($1.appInfo.displayName()) == .orderedAscending }
            
        case .reverseAlphabetical:
            return appList.sorted { $0.appInfo.displayName().localizedStandardCompare($1.appInfo.displayName()) == .orderedDescending }
            
        case .lastLaunched:
            let appsWithLaunchDate = appList.compactMap { app -> (LCAppModel, Date)? in
                guard let launchDate = app.appInfo.lastLaunched else { return nil }
                return (app, launchDate)
            }
            .sorted { $0.1 > $1.1 } // Sort by date, newest first
            .map { $0.0 } // Extract just the app models

            let appsWithoutLaunchDate = appList.filter { app in
                return app.appInfo.lastLaunched == nil
            }
            
            return appsWithLaunchDate + appsWithoutLaunchDate
            
        case .installationDate:
            let appsWithinstallationDate = appList.compactMap { app -> (LCAppModel, Date)? in
                guard let installationDate = app.appInfo.installationDate else { return nil }
                return (app, installationDate)
            }
            .sorted { $0.1 > $1.1 } // Sort by date, newest first
            .map { $0.0 } // Extract just the app models

            let appsWithoutInstallationDate = appList.filter { app in
                return app.appInfo.installationDate == nil
            }
            
            return appsWithinstallationDate + appsWithoutInstallationDate
        case .custom:
            return sortByCustomOrder(appList, customSortOrder: customSortOrder)
        case .bySize:
            // 3.8.645（F2）：按占用大小从大到小；大小未知（还没算
            // 出来）的排最后（lastLaunched 无日期放末尾同款）。
            let appsWithSize = appList.compactMap { app -> (LCAppModel, Int64)? in
                guard let size = CZFAppSizeCache.shared.size(for: app) else { return nil }
                return (app, size)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }

            let appsWithoutSize = appList.filter { app in
                return CZFAppSizeCache.shared.size(for: app) == nil
            }

            return appsWithSize + appsWithoutSize
        case .byExpiry:
            // 3.8.651（F1）：按签名到期日升序（最早到期在前）；
            // 天数未知（读不到 mobileprovision）的排最后（bySize
            // 无大小放末尾同款）。
            let appsWithExpiry = appList.compactMap { app -> (LCAppModel, Int)? in
                guard let d = CZFAppExpiryCache.shared.daysLeft(for: app) else { return nil }
                return (app, d)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }

            let appsWithoutExpiry = appList.filter { app in
                return CZFAppExpiryCache.shared.daysLeft(for: app) == nil
            }

            return appsWithExpiry + appsWithoutExpiry
        }
    }
    
    private func sortByCustomOrder(_ appList: [LCAppModel], customSortOrder: [String]) -> [LCAppModel] {
        if customSortOrder.isEmpty {
            return appList.sorted { $0.appInfo.displayName().localizedStandardCompare($1.appInfo.displayName()) == .orderedAscending }
        }
        
        var sortedApps: [LCAppModel] = []
        var remainingApps = appList
        
        for uniqueId in customSortOrder {
            if let index = remainingApps.firstIndex(where: { matches(uniqueId: uniqueId, app: $0) }) {
                sortedApps.append(remainingApps.remove(at: index))
            }
        }
        
        remainingApps.sort { $0.appInfo.displayName().localizedStandardCompare($1.appInfo.displayName()) == .orderedAscending }
        sortedApps.append(contentsOf: remainingApps)
        
        return sortedApps
    }
    
}
