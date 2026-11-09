// CZFActionShims.swift — ActionExtension 专用的 Swift 替身
// 背景：ActionExtension 的 SWIFT_OBJC_BRIDGING_HEADER 在 385–388 四版里
// 始终不生效（ShareExtension 同款设置却能编），桥接头导入的三个 ObjC 符号
// （LCSharedUtils / LCShareExtensionLauncher / String.loc）在 ActionExtension
// 编译 ShareExtensionViewModel/Views 时全部报 cannot find in scope。
// 本文件用纯 Swift 提供这三个符号，行为逐项对齐 ObjC 原实现，
// 只编进 ActionExtension（本文件在 ActionExtension/ 目录下，走该 target 的
// 同步组自动包含；ShareExtension 不含本文件，走桥接头原路，不受影响）。
// @objc(...) 用不同名，避免与 LiveContainerShared.framework 里的 ObjC 同名类
// 以及 main.m 里的 ObjC LCShareExtensionLauncher 在运行时重名。

import Foundation
import Security
import Darwin

// MARK: - String.loc

extension String {
    /// 对齐 LiveContainer/Localization.m 的 -[NSString(Localization) localized]：
    /// 先查主 App bundle（扩展 bundle 上两级），再查 en.lproj，都没有返回原文。
    var loc: String {
        let mainBundle = CZFActionShims.mainBundle
        let message = mainBundle.localizedString(forKey: self, value: "", table: nil)
        if message != self {
            return message
        }
        if let enPath = mainBundle.path(forResource: "en", ofType: "lproj"),
           let enBundle = Bundle(path: enPath) {
            return enBundle.localizedString(forKey: self, value: nil, table: nil)
        }
        return self
    }
}

// MARK: - LCSharedUtils 替身

/// Swift 替身：Swift 侧类型名 LCSharedUtils（供 ViewModel 调用），
/// ObjC 运行时名 CZFActionLCSharedUtils，避免与框架里的 ObjC LCSharedUtils 重名。
@objc(CZFActionLCSharedUtils)
final class LCSharedUtils: NSObject {

    /// 对齐 LiveContainer/LCSharedUtils.m +teamIdentifier。
    /// 注意：SecTaskCreateFromSelf / SecTaskCopyValueForEntitlement 不进 Swift
    ///（389 红字证实），不用 SecTask。先读主 App 的 embedded.mobileprovision，
    /// 再走钥匙串回退（与 ObjC 的 Palera1n 回退同法）。
    static func teamIdentifier() -> String? {
        if let team = CZFActionShims.teamIdentifierFromProvision() {
            return team
        }
        // 钥匙串回退：查 bundleSeedID 的 accessGroup，取 "." 前一段
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bundleSeedID",
            kSecAttrService as String: "",
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(query as CFDictionary, &result)
        }
        if status == errSecSuccess, let dict = result as? [String: Any] {
            _ = SecItemDelete(query as CFDictionary)
            if let accessGroup = dict[kSecAttrAccessGroup as String] as? String {
                return accessGroup.components(separatedBy: ".").first
            }
        }
        return nil
    }

    /// 对齐 +appGroupID：先读 mobileprovision 里的 application-groups，
    /// 优先含 Apps 子目录的组；再按 teamID 拼两个候选组；再读缓存；都没有返回 Unknown。
    /// 注意：SecTask 读 entitlement 不进 Swift，不用。
    static func appGroupID() -> String {
        if let groups = CZFActionShims.applicationGroupsFromProvision() {
            for group in groups {
                guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { continue }
                let appsURL = url.appendingPathComponent("Apps")
                if FileManager.default.fileExists(atPath: appsURL.path) {
                    return group
                }
            }
            for group in groups {
                if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
                    return group
                }
            }
        }
        let team = teamIdentifier() ?? ""
        let candidates = [
            "group.com.SideStore.SideStore.\(team)",
            "group.com.rileytestut.AltStore.\(team)",
        ]
        for group in candidates {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { continue }
            let appsURL = url.appendingPathComponent("Apps")
            if FileManager.default.fileExists(atPath: appsURL.path) {
                return group
            }
        }
        for group in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
                return group
            }
        }
        if let cached = UserDefaults.standard.string(forKey: "LCAppGroupID"),
           FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: cached) != nil {
            return cached
        }
        return "Unknown"
    }

    /// 对齐 +appGroupPath。
    static func appGroupPath() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID())
    }

    private static var containerLockURL: URL? {
        return appGroupPath()?
            .appendingPathComponent("LiveContainer")
            .appendingPathComponent("containerLock.plist")
    }

    /// 进程是否存活：pid = val57 >> 32；用 kill(pid, 0) 替代 csops_audittoken 的 ESRCH 判定。
    /// kill 返回 0 表示存在；返回 -1 且 errno == EPERM 表示存在但无权发信号；ESRCH 表示不存在。
    private static func isPidAlive(_ pid: pid_t) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// 对齐 +isLCSchemeInUse:。
    static func isLCScheme(inUse lc: String) -> Bool {
        guard let path = containerLockURL?.path,
              let info = NSDictionary(contentsOfFile: path) as? [String: Any],
              let num = info[lc] as? NSNumber else {
            return false
        }
        let val57 = num.uint64Value
        let pid = pid_t(val57 >> 32)
        return isPidAlive(pid)
    }

    /// 对齐 +getContainerUsingLCSchemeWithFolderName:。
    static func getContainerUsingLCScheme(withFolderName folderName: String) -> String? {
        guard let path = containerLockURL?.path,
              let info = NSDictionary(contentsOfFile: path) as? [String: Any],
              let appUsage = info[folderName] as? [String: Any] else {
            return nil
        }
        let val57 = (appUsage["auditToken57"] as? NSNumber)?.uint64Value ?? 0
        let pid = pid_t(val57 >> 32)
        if !isPidAlive(pid) {
            return nil
        }
        return appUsage["runningLC"] as? String
    }

    /// 对齐 +lcUrlSchemes（经 +lcUnorderedUrlSchemes）。
    static func lcUrlSchemes() -> [String] {
        let defaultSchemes = ["livecontainer", "livecontainer2", "livecontainer3"]
        let allowed = Set(defaultSchemes)
        var result: [String] = []
        let sharedDefaults = UserDefaults(suiteName: appGroupID())
        if let saved = sharedDefaults?.object(forKey: "LCMultiLaunchPriority") as? [Any] {
            for value in saved {
                guard let scheme = (value as? String)?.lowercased() else { continue }
                if !allowed.contains(scheme) || result.contains(scheme) { continue }
                result.append(scheme)
            }
        }
        for scheme in defaultSchemes where !result.contains(scheme) {
            result.append(scheme)
        }
        return result
    }
}

// MARK: - LCShareExtensionLauncher 替身

/// Swift 替身：Swift 侧类型名 LCShareExtensionLauncher（供 ViewModel 调用），
/// ObjC 运行时名 CZFActionLCShareExtensionLauncher，避免与 main.m 里的 ObjC 同名类重名。
@objc(CZFActionLCShareExtensionLauncher)
final class LCShareExtensionLauncher: NSObject {

    /// 对齐 ShareExtension/main.m 的 +canOpenURLFromShareExtension:，
    /// 用 LSApplicationWorkspace 私有 API，不走桥接头。
    /// 取 workspace 走 LCSettingsView 里已证实的 NSClassFromString+perform 写法；
    /// 实例方法走最小 @objc 协议（只含实例方法，不含 static）。
    /// 取不到 workspace 时返回 false，调用方会回落到默认 livecontainer 方案。
    static func canOpenURL(fromShareExtension url: URL) -> Bool {
        guard let workspaceObj = (NSClassFromString("LSApplicationWorkspace") as? NSObject.Type)?
            .perform(NSSelectorFromString("defaultWorkspace"))?
            .takeUnretainedValue(),
              let workspace = workspaceObj as? CZFLSApplicationWorkspace else {
            return false
        }
        var error: NSError?
        return workspace.isApplicationAvailableToOpenURL(url, error: &error)
    }
}

/// LSApplicationWorkspace 的最小 @objc 协议（只声明要用的实例方法）。
@objc private protocol CZFLSApplicationWorkspace: NSObjectProtocol {
    func isApplicationAvailableToOpenURL(_ url: URL, error: NSErrorPointer) -> Bool
}

// MARK: - 内部 helper

private enum CZFActionShims {
    /// 对齐 ShareExtension/main.m 的 lcMainBundle：扩展 bundle 上两级 = 主 App bundle。
    static var mainBundle: Bundle {
        let url = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: url) ?? Bundle.main
    }

    /// 读主 App 的 embedded.mobileprovision（CMS 包裹的 plist），返回顶层字典。
    /// 找不到文件、找不到 plist 段或解析失败都返回 nil，调用方走别的回退。
    /// 写法照抄 LiveContainerSwiftUI/Utilities/CZFSignatureExpiry.swift 的 plistPayload。
    static func readMobileProvision() -> [String: Any]? {
        let url = mainBundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</plist>".utf8)
        guard let start = data.range(of: xmlStart),
              let end = data.range(of: xmlEnd, options: [], in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else { return nil }
        return plist
    }

    /// 从 mobileprovision 的 Entitlements 取 com.apple.developer.team-identifier。
    static func teamIdentifierFromProvision() -> String? {
        guard let plist = readMobileProvision(),
              let entitlements = plist["Entitlements"] as? [String: Any],
              let team = entitlements["com.apple.developer.team-identifier"] as? String else { return nil }
        return team
    }

    /// 从 mobileprovision 的 Entitlements 取 com.apple.security.application-groups。
    static func applicationGroupsFromProvision() -> [String]? {
        guard let plist = readMobileProvision(),
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return nil }
        return groups
    }
}
