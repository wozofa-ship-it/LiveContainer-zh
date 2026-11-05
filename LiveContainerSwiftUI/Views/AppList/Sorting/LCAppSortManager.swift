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
        }
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
            // 排序方式变了就刷新设置备份：导出文件里的
            // LCAppSortType 别滞后，恢复直接拿最新值。
            LCDataManagementView.writeCZFSettingsBackup()
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
            LCDataManagementView.writeCZFSettingsBackup()
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
            LCDataManagementView.writeCZFSettingsBackup()
        }
    }

    @Published var currentSchemeName: String {
        didSet {
            LCUtils.appGroupUserDefault.set(currentSchemeName, forKey: Self.currentSchemeKey)
            LCDataManagementView.writeCZFSettingsBackup()
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

    // 新2（3.8.277）：App 分组。groups 是分组名（有序，分组顺序），
    // 存 App Group 键 LCAppGroups；groupMembers 是 [唯一 ID: 分组名]，
    // 存 LCAppGroupMembers。没进 groupMembers 的 App 属“未分组”
    //（不存；占位名 "未分组" 是保留名，不可作分组名）。
    static let groupsKey = "LCAppGroups"
    static let groupMembersKey = "LCAppGroupMembers"
    static let ungroupedName = "未分组"

    @Published var groups: [String] {
        didSet {
            LCUtils.appGroupUserDefault.set(groups, forKey: Self.groupsKey)
            LCDataManagementView.writeCZFSettingsBackup()
        }
    }

    @Published var groupMembers: [String: String] {
        didSet {
            LCUtils.appGroupUserDefault.set(groupMembers, forKey: Self.groupMembersKey)
            LCDataManagementView.writeCZFSettingsBackup()
        }
    }

    /// 该 App 的分组名，没进组返回 nil。
    func groupName(for app: LCAppModel) -> String? {
        guard let id = getUniqueIdentifier(for: app) else { return nil }
        return groupMembers[id]
    }

    /// 把 App 移进分组；group 为 nil 表示移回“未分组”。
    /// 不存在的分组名直接忽略。
    func moveApp(_ app: LCAppModel, to group: String?) {
        guard let id = getUniqueIdentifier(for: app) else { return }
        if let group {
            guard groups.contains(group) else { return }
            groupMembers[id] = group
        } else {
            groupMembers.removeValue(forKey: id)
        }
    }

    /// 新增分组（空白、保留名、已存在返回 false）。新分组排最后。
    @discardableResult
    func addGroup(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != Self.ungroupedName, !groups.contains(trimmed) else { return false }
        groups.append(trimmed)
        return true
    }

    /// 分组改名（空白、保留名、旧名不存在、新名已存在返回 false）。
    /// 组内成员的归属跟着新名走。
    @discardableResult
    func renameGroup(from oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != Self.ungroupedName, trimmed != oldName, groups.contains(oldName), !groups.contains(trimmed) else { return false }
        groups = groups.map { $0 == oldName ? trimmed : $0 }
        // 先收 ID 再改值：字典迭代中直接改值不安全。
        let memberIDs = groupMembers.filter { $0.value == oldName }.map { $0.key }
        for id in memberIDs {
            groupMembers[id] = trimmed
        }
        return true
    }

    /// 删分组（不存在返回 false）。组内成员移回“未分组”。
    @discardableResult
    func deleteGroup(named name: String) -> Bool {
        guard groups.contains(name) else { return false }
        groups.removeAll { $0 == name }
        // 先收 ID 再删：字典迭代中直接删键不安全。
        let memberIDs = groupMembers.filter { $0.value == name }.map { $0.key }
        for id in memberIDs {
            groupMembers.removeValue(forKey: id)
        }
        return true
    }

    /// 分组重排：把分组从 from 移到 to（管理页 onMove 用）。
    func moveGroup(fromOffsets source: IndexSet, toOffset destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
    }
    
    @Published var sortedApps : [LCAppModel] = []
    @Published var sortedHiddenApps : [LCAppModel] = []
    
    private var cancellables = Set<AnyCancellable>()
    // MARK: - Initialization
    
    init() {
        self.customSortOrder = LCUtils.appGroupUserDefault.array(forKey: "LCCustomSortOrder") as? [String] ?? []
        // 新1：方案首次用时从现有自定义顺序迁移出一套“常用”，
        // 再补空的“游戏”“工作”两套示例方案；已有方案直接读。
        // init 里 didSet 不触发，迁移完直接写回 defaults 落盘。
        if let saved = LCUtils.appGroupUserDefault.dictionary(forKey: Self.schemesKey) as? [String: [String]], !saved.isEmpty {
            self.schemes = saved
        } else {
            self.schemes = [Self.defaultSchemeName: self.customSortOrder, "游戏": [], "工作": []]
            LCUtils.appGroupUserDefault.set(self.schemes, forKey: Self.schemesKey)
        }
        self.currentSchemeName = LCUtils.appGroupUserDefault.string(forKey: Self.currentSchemeKey) ?? Self.defaultSchemeName
        if schemes[currentSchemeName] == nil {
            currentSchemeName = schemes.keys.sorted().first ?? Self.defaultSchemeName
            LCUtils.appGroupUserDefault.set(currentSchemeName, forKey: Self.currentSchemeKey)
        }
        // 新2：分组。归属里写着不存在的分组名（删分组后残留的
        // 旧数据）直接丢掉，App 回“未分组”。
        let savedGroups = LCUtils.appGroupUserDefault.array(forKey: Self.groupsKey) as? [String] ?? []
        self.groups = savedGroups
        self.groupMembers = (LCUtils.appGroupUserDefault.dictionary(forKey: Self.groupMembersKey) as? [String: String] ?? [:]).filter { savedGroups.contains($0.value) }
        
        DataManager.shared.model.$apps
            .sink { newValue in
                self.sortedApps = self.getSortedApps(newValue, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
            .store(in: &cancellables)
        
        DataManager.shared.model.$hiddenApps
            .sink { newValue in
                self.sortedHiddenApps = self.getSortedApps(newValue, sortType: self.appSortType, customSortOrder: self.customSortOrder)
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
        // 新2：分组也重读（恢复写回后当场生效，不用等重启）。
        self.groups = LCUtils.appGroupUserDefault.array(forKey: Self.groupsKey) as? [String] ?? []
        if let members = LCUtils.appGroupUserDefault.dictionary(forKey: Self.groupMembersKey) as? [String: String] {
            self.groupMembers = members.filter { groups.contains($0.value) }
        }
        self.customSortOrder = LCUtils.appGroupUserDefault.array(forKey: "LCCustomSortOrder") as? [String] ?? []
        self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
        if DataManager.shared.model.isHiddenAppUnlocked {
            self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
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
    
    func getSortedApps(_ appList: [LCAppModel], sortType: AppSortType, customSortOrder: [String]) -> [LCAppModel] {
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
