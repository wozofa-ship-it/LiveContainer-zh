import Foundation
import UIKit

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
        if daysLeft < 0 { return "已过期 \(-daysLeft) 天" }
        if daysLeft == 0 { return "今天到期" }
        return "剩 \(daysLeft) 天"
    }

    var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: expiryDate)
    }
}

enum CZFSignatureExpiryReader {
    static let autoRenewEnabledKey = "CZFAutoRenewEnabled"
    static let aheadDaysKey = "CZFRenewAheadDays"
    static let lastAutoRenewKey = "CZFLastAutoRenewDate"
    static let aheadOptions = [1, 2, 3, 5, 7]

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

    static func loadAll(entries: [(name: String, bundlePath: String)]) -> [CZFSignatureExpiry] {
        var out: [CZFSignatureExpiry] = []
        for e in entries {
            guard let date = expiryDate(inFile: "\(e.bundlePath)/embedded.mobileprovision") else { continue }
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

    static var triggeredToday: Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return UserDefaults.standard.string(forKey: lastAutoRenewKey) == f.string(from: Date())
    }

    // 自动续签（App 前台时调）：最近到期 ≤ 提前天数、且今天
    // 还没触发过，就拉起 Side 的 refresh-all 续全部；一天最
    // 多一次，续上后到期日往后推、条件自然解除，续失败也
    // 不会每次前台都弹
    static func maybeAutoRenew() {
        guard UserDefaults.standard.object(forKey: autoRenewEnabledKey) as? Bool ?? true else { return }
        guard !triggeredToday else { return }
        let ahead = UserDefaults.standard.object(forKey: aheadDaysKey) as? Int ?? 2
        let entries = snapshotEntries(apps: DataManager.shared.model.apps, hiddenApps: DataManager.shared.model.hiddenApps)
        DispatchQueue.global(qos: .utility).async {
            let nearest = loadAll(entries: entries).map(\.daysLeft).min()
            guard let nearest = nearest, nearest <= ahead else { return }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            UserDefaults.standard.set(f.string(from: Date()), forKey: lastAutoRenewKey)
            DispatchQueue.main.async {
                if let url = URL(string: "sideinstaller://refresh-all") {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}
