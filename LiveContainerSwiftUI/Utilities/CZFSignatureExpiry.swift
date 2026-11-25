import Foundation
import UIKit
import UserNotifications

// 签名剩余时间：读各 App 包里 embedded.mobileprovision 的
// ExpirationDate（Side 同款字节扫描法：CMS 包里找 plist，
// 不走私有 API；读不到的 App 不列入，不影响别的 App）
struct CZFSignatureExpiry: Identifiable {
    // id 用包路径：同名 App 装两个时名字会撞，路径不会
    var id: String { bundlePath }
    let name: String
    let bundlePath: String
    let expiryDate: Date

    var daysLeft: Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: expiryDate)).day ?? 0
    }

    var label: String {
        Self.label(forDaysLeft: daysLeft)
    }

    /// label 的纯函数版（3.8.635 F1）：列表/网格只拿到 daysLeft
    /// 时共用同一份文案，不各写一份分支（分支一改三处全改）。
    static func label(forDaysLeft daysLeft: Int) -> String {
        if daysLeft < 0 { return "已过期 \(-daysLeft) 天" }
        if daysLeft == 0 { return "今天到期" }
        return "剩 \(daysLeft) 天"
    }

    // 只在主线程渲染时调（续签区行视图），静态格式器不再
    // 每次渲染新建；DateFormatter 本身不是线程安全的，别
    // 在后台线程调 dateText。
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()

    var dateText: String {
        Self.dateFormatter.string(from: expiryDate)
    }
}

enum CZFSignatureExpiryReader {
    // 只剩只读展示：自动续签已去掉（2026-10-25，见设置页注释），
    // 下面不再有任何拉起 Side 重签的代码。

    // 抓快照（主线程调）：宿主自己 + 全部游客 App（含隐藏的，
    // 续签不分显隐）；真正读文件放后台做，不堵 UI
    static func snapshotEntries(apps: [LCAppModel], hiddenApps: [LCAppModel]) -> [(name: String, bundlePath: String)] {
        var entries: [(name: String, bundlePath: String)] = []
        if let hostPath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
           let hostDir = (hostPath as NSString).deletingLastPathComponent as String? {
            entries.append((name: "LiveContainer", bundlePath: hostDir))
        }
        for m in apps + hiddenApps {
            guard let bundlePath = m.appInfo.bundlePath() else { continue }
            let name = m.appInfo.displayName() ?? m.appInfo.bundleIdentifier() ?? ""
            entries.append((name: name, bundlePath: bundlePath))
        }
        return entries
    }

    // 到期日缓存：续签区每次回前台都全量重读各 App 的
    // mobileprovision、CMS 里扫 plist，到期日只有重签才
    // 会变。按（文件路径 + 修改时间 + 大小）缓存，重签
    // 必然改大小或修改时间，下一轮一定重读，不会读旧；
    // 文件不存在时不缓存，每次仍会试读一次。loadAll 在
    // 后台线程调，缓存读写加锁（DateFormatter 那边是主
    // 线程渲染，不走这把锁）。
    private static let expiryCacheLock = NSLock()
    private static var expiryCache: [String: (mtime: Date, size: Int, date: Date?)] = [:]

    private static func cachedExpiryDate(inFile path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else {
            return expiryDate(inFile: path)
        }
        expiryCacheLock.lock()
        let cached = expiryCache[path]
        expiryCacheLock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size {
            return cached.date
        }
        let date = expiryDate(inFile: path)
        expiryCacheLock.lock()
        expiryCache[path] = (mtime, size, date)
        expiryCacheLock.unlock()
        return date
    }

    static func loadAll(entries: [(name: String, bundlePath: String)]) -> [CZFSignatureExpiry] {
        var out: [CZFSignatureExpiry] = []
        for e in entries {
            guard let date = cachedExpiryDate(inFile: "\(e.bundlePath)/embedded.mobileprovision") else { continue }
            out.append(CZFSignatureExpiry(name: e.name, bundlePath: e.bundlePath, expiryDate: date))
        }
        return out.sorted { $0.expiryDate < $1.expiryDate }
    }

    static func expiryDate(inFile path: String) -> Date? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = plistPayload(in: data),
              let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }

    // CMS 包里找 plist：XML 或 bplist00 开头那段（Side 同款）
    private static func plistPayload(in data: Data) -> Data? {
        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</plist>".utf8)
        if let start = data.range(of: xmlStart),
           let end = data.range(of: xmlEnd, options: [], in: start.lowerBound..<data.endIndex) {
            return data[start.lowerBound..<end.upperBound]
        }
        if let start = data.range(of: Data("bplist00".utf8)) {
            return data[start.lowerBound..<data.endIndex]
        }
        return nil
    }

}

// 3.8.639（F1）：证书到期前本地提醒——上一轮 F1 只在列表里
// 显示剩余天数，不打开 App 就看不到；用户证书到期是反复踩的
// 坑（解剖自我 2026-12-02 到期，全靠外部 cron 提醒），应用内
// 提醒覆盖全部 App。只提醒，不续签：不恢复设置页已删的续签区，
// 不加任何续签动作。
// 口径：到期前 3 天 / 1 天 / 当天 09:00 各推一条；已过的档位不补
// 推（当天 09:00 已过就不排当天的），已过期不排。identifier 用
// 确定性 `CZFExpiry-<bundlePath>-<3|1|0>`，每次刷新先按前缀清
// 掉该 App 的旧待发再重排（重签后续期、旧提醒自动作废）。
// 仅 `.authorized` 才排；`.notDetermined` 时调一次
// `requestAuthorization`（设置页已有申请入口，通知区权限行）。
// UserNotifications 全版本可用，部署目标 iOS 15 无需 #available。
// 文案沿用 `notifyBatchDone` 硬编码中文先例，0 新 key。
enum CZFExpiryReminder {
    private static let thresholds = [3, 1, 0]

    static func schedule(for items: [CZFSignatureExpiry]) {
        guard !items.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                scheduleAuthorized(items, center: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    scheduleAuthorized(items, center: center)
                }
            default:
                return
            }
        }
    }

    private static func scheduleAuthorized(_ items: [CZFSignatureExpiry], center: UNUserNotificationCenter) {
        let now = Date()
        let calendar = Calendar.current
        // 先清旧待发再重排：同一 App 的三档 identifier 前缀固定，
        // 清掉重排才不会让重签前的旧提醒留着误报。
        center.getPendingNotificationRequests { pending in
            var removeIDs: [String] = []
            var adds: [UNNotificationRequest] = []
            for item in items {
                let prefix = "CZFExpiry-\(item.bundlePath)-"
                removeIDs += pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
                for daysBefore in thresholds {
                    guard let fireDate = calendar.date(byAdding: .day, value: -daysBefore, to: calendar.startOfDay(for: item.expiryDate))?.addingTimeInterval(9 * 60 * 60),
                          fireDate > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "签名快到期"
                    content.body = daysBefore == 0 ? "\(item.name) 今天到期" : "\(item.name) 还有 \(daysBefore) 天到期"
                    content.sound = .default
                    let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    adds.append(UNNotificationRequest(identifier: "\(prefix)\(daysBefore)", content: content, trigger: trigger))
                }
            }
            if !removeIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: removeIDs)
            }
            for request in adds {
                center.add(request)
            }
        }
    }

    // 3.8.643（B1）：删 App 时清它的三档到期提醒——排期只按当前
    // 列表里的 items 清前缀（见 scheduleAuthorized），已删 App 的
    // bundlePath 不再出现在 items 里，提醒永远清不到、到期前仍会推。
    // 与 scheduleAuthorized 同款写法：先取待发、按前缀过滤再删。
    static func cancel(forBundlePath bundlePath: String) {
        let center = UNUserNotificationCenter.current()
        let prefix = "CZFExpiry-\(bundlePath)-"
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
