import Foundation

/// 3.8.637（B1）：个人 ID 签名改写后的 Bundle ID 归一。
///
/// 个人 ID 签名把 `CFBundleIdentifier` 改写成 `原ID.团队ID`（双图标根因已证实；
/// `LCAppInfo.m` 的 `setDoUseLCBundleId` 存 `LCOrignalBundleIdentifier` 就是为
/// 这改写准备的），而 `bundleIdentifier()` 默认返回改写后的 ID（`doUseLCBundleId`
/// 默认 `NO`）。源页/文件夹/坞面板的“已装”判定只按精确相等建键，个人 ID 签名的
/// App 永远认不出已装，企业证书签名的 App（不改写 ID）不受影响。
///
/// 归一规则：末段恰为 10 位、且字母数字混杂（至少一个字母 + 至少一个数字）
/// 时去掉该段——团队 ID（如 `9C27AADJ2K`、`KMRGJZFUYQ`）正是这个形状。
/// 不能只用 `hasPrefix(bid + ".")`：`com.x.y` 与 `com.x.y.helper` 是两个
/// App；也不能只验“10 位字母数字”：纯字母或纯数字的 10 位末段更可能是
/// 真实包名段，不是团队 ID。
func czfNormalizedBundleID(_ bundleID: String) -> String {
    guard let dot = bundleID.lastIndex(of: ".") else { return bundleID }
    let suffix = bundleID[bundleID.index(after: dot)...]
    guard suffix.count == 10,
          suffix.contains(where: { $0.isLetter }),
          suffix.contains(where: { $0.isNumber }),
          suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return bundleID }
    return String(bundleID[..<dot])
}

/// 两个 Bundle ID 在归一后是否同一 App（个人 ID 改写前/后视为同一 App）。
func czfSameBundleID(_ lhs: String, _ rhs: String) -> Bool {
    lhs == rhs || czfNormalizedBundleID(lhs) == czfNormalizedBundleID(rhs)
}

/// 3.8.639（B2）：单 App 设置的实例稳定键——安装文件夹名
/// （`relativeBundlePath`，如 `Xianyu.app`），换队重签不改、
/// 同名多开路径不撞；取不到时回落 `bundleIdentifier()`。
/// 注意不要用归一 Bundle ID（`czfNormalizedBundleID`）：那会把同一
/// App 不同团队签的两个分身绑到同一份设置上。`relativeBundlePath`
/// 是扫描时写死的存储属性（`LiveContainerSwiftUIApp`），不读
/// `_info`，任意线程读都安全；回落的 `bundleIdentifier()` 才读
/// `_info`，调用方在后台线程时须自己走主线程取（`CZFVPNManager`
/// 的 `czfBundleId` 同款），本函数不包 `main.sync`。
func czfStableSettingsKey(for appInfo: LCAppInfo) -> String {
    if let path = appInfo.relativeBundlePath, !path.isEmpty { return path }
    return appInfo.bundleIdentifier() ?? ""
}

/// 3.8.639（B2）：定时三枚键（Enabled/Minutes/LastDate）的稳定键 +
/// 首次读迁移——轮询（`MultitaskDockManager`）、菜单（`SourcesPanelView`）、
/// 设置页（`LCAppSettingsView`）三路共用同一份；重签后旧 bid 已不可知，
/// 丢了的追不回来。
func czfSchedMinKey(for appInfo: LCAppInfo) -> String {
    let stable = czfStableSettingsKey(for: appInfo)
    if let oldBid = appInfo.bundleIdentifier(), oldBid != stable {
        czfMigrateDefaultsKey(prefix: "CZFSchedMinEnabled-", stableKey: stable, oldBid: oldBid)
        czfMigrateDefaultsKey(prefix: "CZFSchedMinMinutes-", stableKey: stable, oldBid: oldBid)
        czfMigrateDefaultsKey(prefix: "CZFSchedMinLastDate-", stableKey: stable, oldBid: oldBid)
    }
    return stable
}

/// 3.8.639（B2）：把旧 bid 键的值搬到新稳定键——只在新键无值、
/// 旧键有值时搬一次，搬完删旧键。重签后旧 bid 已不可知、
/// 丢了的设置追不回来；没重签前读到就先搬走，以后重签不丢。
/// `Bool` 键用 `object(forKey:)` 判有无：显式存过 `false` 也
/// 是有值（`NSNumber`），不会误判成“没存过”。
func czfMigrateDefaultsKey(prefix: String, stableKey: String, oldBid: String, defaults: UserDefaults = .standard) {
    guard !stableKey.isEmpty, !oldBid.isEmpty, stableKey != oldBid else { return }
    let newKey = prefix + stableKey
    let oldKey = prefix + oldBid
    guard defaults.object(forKey: newKey) == nil, let value = defaults.object(forKey: oldKey) else { return }
    defaults.set(value, forKey: newKey)
    defaults.removeObject(forKey: oldKey)
}
