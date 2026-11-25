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
