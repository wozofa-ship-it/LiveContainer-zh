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
