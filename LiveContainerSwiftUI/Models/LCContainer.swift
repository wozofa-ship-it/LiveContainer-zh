//
//  LCAppInfo.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/5.
//

import Foundation

class LCContainer : ObservableObject, Hashable {
    @Published var folderName : String
    @Published var name : String
    @Published var isShared : Bool
    
    @Published var storageBookMark: Data?
    @Published var resolvedContainerURL: URL?
    @Published var bookmarkResolved = false
    var bookmarkResolveContinuation: UnsafeContinuation<(), Never>? = nil
    
    @Published var isolateAppGroup : Bool

    @Published var spoofIdentifierForVendor : Bool {
        didSet {
            if spoofIdentifierForVendor && spoofedIdentifier == nil {
                spoofedIdentifier = UUID().uuidString
            }
        }
    }
    public var spoofedIdentifier: String?

    // 设备指纹伪装（多开分身各有一套环境用）：打开时一次性生成
    // 一套伪装值并持久化，之后固定不变（换值会让平台认出是同一
    // 台设备换了马甲，反而更可疑）。IDFA、设备名、系统版本、
    // 机型（hw.machine）四项，客端 hook 在启动时注入。
    // 机型只从近几代 Pro 机型里挑（不含本机 iPhone17,2），
    // 系统版本只在当前大版本内浮动（不往低了编，免得 App
    // 判系统太旧关功能）。
    @Published var spoofDeviceFingerprint : Bool {
        didSet {
            if spoofDeviceFingerprint {
                if spoofedAdvertisingIdentifier == nil {
                    spoofedAdvertisingIdentifier = UUID().uuidString
                }
                if spoofedDeviceName == nil {
                    spoofedDeviceName = LCContainer.czfRandomDeviceName()
                }
                if spoofedSystemVersion == nil {
                    spoofedSystemVersion = LCContainer.czfRandomSystemVersion()
                }
                if spoofedMachine == nil {
                    spoofedMachine = LCContainer.czfRandomMachine()
                }
                if spoofedRegion == nil {
                    spoofedRegion = LCContainer.czfRandomRegion()
                }
                // 派生值与机型/地区同源（D1 单一事实源）：屏幕尺寸与
                // locale/语言/时区由机型/地区码推导，随 plist 传给客端，
                // 客端不再另维护对照表。老容器缺这几键时就地补齐，
                // 下次保存时写入 plist；客端读不到时回落到内置表。
                if spoofedScreenWidth == nil, let m = spoofedMachine, let s = LCContainer.czfScreenForMachine(m) {
                    spoofedScreenWidth = s.width
                    spoofedScreenHeight = s.height
                    spoofedScreenScale = s.scale
                }
                if spoofedLocaleIdentifier == nil, let r = spoofedRegion, let info = LCContainer.czfRegionInfo(r) {
                    spoofedLocaleIdentifier = info.localeID
                    spoofedLanguage = info.language
                    spoofedTimeZoneName = info.timeZoneName
                }
            }
        }
    }
    public var spoofedAdvertisingIdentifier: String?
    public var spoofedDeviceName: String?
    public var spoofedSystemVersion: String?
    public var spoofedMachine: String?
    // 地区（国家/地区码）：语言 + 时区 + 地区三件套由此推导，
    // 客端 hook NSLocale/NSTimeZone 注入。每个分身随机一个，
    // 固定不变。
    public var spoofedRegion: String?
    // 屏幕与地区派生值（D1 单一事实源）：由机型/地区码推导，
    // 随 plist 传给客端，客端不再另维护对照表。老容器没有
    // 这几键，读时由 didSet 就地补齐，下次保存时写入 plist。
    public var spoofedScreenWidth: Double?
    public var spoofedScreenHeight: Double?
    public var spoofedScreenScale: Double?
    public var spoofedLocaleIdentifier: String?
    public var spoofedLanguage: String?
    public var spoofedTimeZoneName: String?

    // D5：多开隔离开关三元组（App Group 隔离 + IDFV 伪装 + 设备指纹），
    // 三处自动开隔离共用。三个 didSet 都是 nil 守卫（已有值不重生成），
    // 逐个赋 true 与原来逐行写语义相同。
    func enableMultiOpenIsolation() {
        isolateAppGroup = true
        spoofIdentifierForVendor = true
        spoofDeviceFingerprint = true
    }

    // 每分身单独代理：用户自己填（host + 端口），空 = 不走代理。
    // 不是自动生成的——代理服务器得用户自己有，填错/填了不可用
    // 的代理会让客端联网全断，只在填了且端口 > 0 时才 hook 生效。
    public var spoofedProxyHost: String?
    public var spoofedProxyPort: Int = 0

    static func czfRandomRegion() -> String {
        ["US", "JP", "GB", "DE", "FR", "KR", "AU", "CA"].randomElement() ?? "US"
    }

    static func czfRandomDeviceName() -> String {
        // 拟真设备名：真机名大多是“xxx 的 iPhone”或就叫“iPhone”，
        // “iPhone-XXXX”一眼机器生成。从一组通用名里随机挑一个，
        // 每个分身固定不变；IDFA/机型本来就区分各分身，名字撞了也无妨。
        // 注意：别用用户自己的名字（隐私），只用通用名。
        let names = [
            "iPhone",
            "我的 iPhone",
            "小明的 iPhone",
            "阿杰的 iPhone",
            "小红的 iPhone",
            "小李的 iPhone",
            "小王的 iPhone",
            "小张的 iPhone",
            "小刘的 iPhone",
            "小赵的 iPhone",
            "小周的 iPhone",
            "小吴的 iPhone",
            "小郑的 iPhone",
            "小林的 iPhone",
            "小何的 iPhone",
            "小郭的 iPhone",
            "小马的 iPhone",
            "小罗的 iPhone",
            "小梁的 iPhone",
            "小宋的 iPhone",
            "小唐的 iPhone",
            "小冯的 iPhone",
            "小于的 iPhone",
            "小董的 iPhone"
        ]
        return names.randomElement() ?? "iPhone"
    }

    static func czfRandomSystemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let real = "\(v.majorVersion).\(v.minorVersion)"
        let candidates = ["\(v.majorVersion).0", "\(v.majorVersion).1", "\(v.majorVersion).2", "\(v.majorVersion).3"].filter { $0 != real }
        return candidates.randomElement() ?? "\(v.majorVersion).1"
    }

    static func czfRandomMachine() -> String {
        ["iPhone17,1", "iPhone16,2", "iPhone16,1", "iPhone15,3", "iPhone15,2"].randomElement() ?? "iPhone17,1"
    }

    // 屏幕对照表（D1 单一事实源）：机型 -> 屏幕 native 像素 + scale，
    // 与 czfRandomMachine 的五款一致。客端（DeviceFingerprint.m）
    // 不再另维护一份，只读 plist 传过去的派生值；这里是唯一出处。
    static func czfScreenForMachine(_ machine: String) -> (width: Double, height: Double, scale: Double)? {
        switch machine {
        case "iPhone17,1": return (1206, 2622, 3) // iPhone 16 Pro
        case "iPhone16,2": return (1290, 2796, 3) // iPhone 15 Pro Max
        case "iPhone16,1": return (1179, 2556, 3) // iPhone 15 Pro
        case "iPhone15,3": return (1290, 2796, 3) // iPhone 14 Pro Max
        case "iPhone15,2": return (1179, 2556, 3) // iPhone 14 Pro
        default: return nil
        }
    }

    // 地区对照表（D1 单一事实源）：地区码 -> locale + 语言 + 时区，
    // 与 czfRandomRegion 的八个码一致。客端只读 plist 传过去的
    // 派生值；这里是唯一出处。
    static func czfRegionInfo(_ region: String) -> (localeID: String, language: String, timeZoneName: String)? {
        switch region {
        case "US": return ("en_US", "en", "America/New_York")
        case "JP": return ("ja_JP", "ja", "Asia/Tokyo")
        case "GB": return ("en_GB", "en", "Europe/London")
        case "DE": return ("de_DE", "de", "Europe/Berlin")
        case "FR": return ("fr_FR", "fr", "Europe/Paris")
        case "KR": return ("ko_KR", "ko", "Asia/Seoul")
        case "AU": return ("en_AU", "en", "Australia/Sydney")
        case "CA": return ("en_CA", "en", "America/Toronto")
        default: return nil
        }
    }
    private var infoDict : [String:Any]?
    public var containerURL : URL {
        if let resolvedContainerURL {
            return resolvedContainerURL
        }
        
        if isShared {
            return LCPath.lcGroupDataPath.appendingPathComponent("\(folderName)")
        } else {
            return LCPath.dataPath.appendingPathComponent("\(folderName)")
        }
    }
    private var infoDictUrl : URL {
        return containerURL.appendingPathComponent("LCContainerInfo.plist")
    }
    public var keychainGroupId : Int {
        get {
            if infoDict == nil {
                infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
            }
            guard let infoDict else {
                return -1
            }
            return infoDict["keychainGroupId"] as? Int ?? -1
        }
    }
    
    public var appIdentifier : String? {
        get {
            if infoDict == nil {
                infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
            }
            guard let infoDict else {
                return nil
            }
            return infoDict["appIdentifier"] as? String ?? nil
        }
    }
    
    init(folderName: String, name: String, isShared : Bool, isolateAppGroup: Bool = false, spoofIdentifierForVendor: Bool = false, spoofDeviceFingerprint: Bool = false, bookmarkData: Data? = nil, resolvedContainerURL: URL? = nil) {
        self.folderName = folderName
        self.name = name
        self.isShared = isShared
        self.isolateAppGroup = isolateAppGroup
        self.spoofIdentifierForVendor = spoofIdentifierForVendor
        self.spoofDeviceFingerprint = spoofDeviceFingerprint
        self.storageBookMark = bookmarkData
        self.resolvedContainerURL = resolvedContainerURL
    }
    
    convenience init(infoDict : [String : Any], isShared : Bool) {
        let bookmarkData : Data? = infoDict["bookmarkData"] as? Data
        
        self.init(folderName: infoDict["folderName"] as? String ?? "ERROR",
                  name: infoDict["name"] as? String ?? "ERROR",
                  isShared: isShared,
                  isolateAppGroup: false,
                  spoofIdentifierForVendor: false,
                  bookmarkData: bookmarkData,
                  resolvedContainerURL: nil
        )
        
        if let bookmarkData {

                do {
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)

                    self.resolvedContainerURL = url

                } catch {
                    print(error.localizedDescription)
                }

                self.bookmarkResolved = true
        }
        
        do {
            let fm = FileManager.default
            if(!fm.fileExists(atPath: infoDictUrl.deletingLastPathComponent().path)) {
                try fm.createDirectory(at: infoDictUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            let plistInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoDictUrl), format: nil)
            if let plistInfo = plistInfo as? [String : Any] {
                applyPlistInfo(plistInfo)
            }
        } catch {
            
        }
    }

    // plist 读共用（D3）：convenience init 与 loadName 两处
    // 原来各写一份（14 个键 +“先读值再开开关”顺序注释），
    // 新键只改这里一处。先读值再开开关：didSet 在开时会补
    // 没生成的值（D1 派生值也在 didSet 里补），顺序反了会
    // 把刚生成的值又用 nil 盖掉。
    private func applyPlistInfo(_ plistInfo: [String: Any]) {
        isolateAppGroup = plistInfo["isolateAppGroup"] as? Bool ?? false
        spoofIdentifierForVendor = plistInfo["spoofIdentifierForVendor"] as? Bool ?? false
        spoofedIdentifier = plistInfo["spoofedIdentifierForVendor"] as? String
        spoofedAdvertisingIdentifier = plistInfo["spoofedAdvertisingIdentifier"] as? String
        spoofedDeviceName = plistInfo["spoofedDeviceName"] as? String
        spoofedSystemVersion = plistInfo["spoofedSystemVersion"] as? String
        spoofedMachine = plistInfo["spoofedMachine"] as? String
        spoofedRegion = plistInfo["spoofedRegion"] as? String
        spoofedScreenWidth = plistInfo["spoofedScreenWidth"] as? Double
        spoofedScreenHeight = plistInfo["spoofedScreenHeight"] as? Double
        spoofedScreenScale = plistInfo["spoofedScreenScale"] as? Double
        spoofedLocaleIdentifier = plistInfo["spoofedLocaleIdentifier"] as? String
        spoofedLanguage = plistInfo["spoofedLanguage"] as? String
        spoofedTimeZoneName = plistInfo["spoofedTimeZoneName"] as? String
        spoofedProxyHost = plistInfo["spoofedProxyHost"] as? String
        spoofedProxyPort = plistInfo["spoofedProxyPort"] as? Int ?? 0
        spoofDeviceFingerprint = plistInfo["spoofDeviceFingerprint"] as? Bool ?? false
    }
    
    func toDict() -> [String : Any] {
        var ans : [String: Any] = [
            "folderName" : folderName,
            "name" : name
        ]
        if let storageBookMark {
            ans["bookmarkData"] = storageBookMark
        }
        return ans
    }
    
    func makeLCContainerInfoPlist(appIdentifier : String, keychainGroupId : Int) {
        infoDict = [
            "appIdentifier" : appIdentifier,
            "name" : name,
            "keychainGroupId" : keychainGroupId,
            "isolateAppGroup" : isolateAppGroup,
            "spoofIdentifierForVendor": spoofIdentifierForVendor,
            "spoofDeviceFingerprint": spoofDeviceFingerprint
        ]
        if let spoofedIdentifier {
            infoDict!["spoofedIdentifierForVendor"] = spoofedIdentifier
        }
        if let spoofedAdvertisingIdentifier {
            infoDict!["spoofedAdvertisingIdentifier"] = spoofedAdvertisingIdentifier
        }
        if let spoofedDeviceName {
            infoDict!["spoofedDeviceName"] = spoofedDeviceName
        }
        if let spoofedSystemVersion {
            infoDict!["spoofedSystemVersion"] = spoofedSystemVersion
        }
        if let spoofedMachine {
            infoDict!["spoofedMachine"] = spoofedMachine
        }
        if let spoofedRegion {
            infoDict!["spoofedRegion"] = spoofedRegion
        }
        if let spoofedScreenWidth {
            infoDict!["spoofedScreenWidth"] = spoofedScreenWidth
        }
        if let spoofedScreenHeight {
            infoDict!["spoofedScreenHeight"] = spoofedScreenHeight
        }
        if let spoofedScreenScale {
            infoDict!["spoofedScreenScale"] = spoofedScreenScale
        }
        if let spoofedLocaleIdentifier {
            infoDict!["spoofedLocaleIdentifier"] = spoofedLocaleIdentifier
        }
        if let spoofedLanguage {
            infoDict!["spoofedLanguage"] = spoofedLanguage
        }
        if let spoofedTimeZoneName {
            infoDict!["spoofedTimeZoneName"] = spoofedTimeZoneName
        }
        if let spoofedProxyHost, !spoofedProxyHost.isEmpty {
            infoDict!["spoofedProxyHost"] = spoofedProxyHost
        }
        if spoofedProxyPort > 0 {
            infoDict!["spoofedProxyPort"] = spoofedProxyPort
        }
        
        do {
            let fm = FileManager.default
            if(!fm.fileExists(atPath: infoDictUrl.deletingLastPathComponent().path)) {
                try fm.createDirectory(at: infoDictUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            let plistData = try PropertyListSerialization.data(fromPropertyList: infoDict as Any, format: .binary, options: 0)
            try plistData.write(to: infoDictUrl)
        } catch {
            
        }
    }
    
    func reloadInfoPlist() {
        infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
    }

    func loadName() {
        reloadInfoPlist()
        guard let infoDict else {
            return
        }
        name = infoDict["name"] as? String ?? "ERROR"
        applyPlistInfo(infoDict)
    }
    
    static func == (lhs: LCContainer, rhs: LCContainer) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

extension LCAppInfo {
    var containers : [LCContainer] {
        get {
            if self is BuiltInSideStoreAppInfo {
                let container = LCContainer(folderName: "", name: "SideStore", isShared: false)
                container.resolvedContainerURL = LCPath.docPath.appendingPathComponent("SideStore")
                return [container]
            }
            
            var upgrade = false
            // upgrade
            if let oldDataUUID = dataUUID, containerInfo == nil {
                containerInfo = [[
                    "folderName": oldDataUUID,
                    "name": oldDataUUID
                ]]
                upgrade = true
            }
            let dictArr = containerInfo as? [[String : Any]] ?? []
            return dictArr.map{ dict in
                let ans = LCContainer(infoDict: dict, isShared: isShared)
                if upgrade {
                    ans.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier()!, keychainGroupId: 0)
                }
                return ans
            }
        }
        set {
            containerInfo = newValue.map { container in
                return container.toDict()
            }
        }
    }

}
