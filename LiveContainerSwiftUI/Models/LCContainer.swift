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

    // 3.8.718（B-2）：容器 plist 读/写失败标记——读失败时开关全
    // 按默认显示、写失败时开关看着改了、重进变回去；空 catch
    // 原来把两路都吞了。容器页凭这两旗提示，调用方凭写旗报错。
    @Published var czfPlistReadFailed = false
    @Published var czfPlistWriteFailed = false

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
                // 3.8.900（L574-3）：外置容器懒读也要先拿 scope——与
                // L573-4 同根（convenience init 读 plist 那处）：
                // init 从不填 infoDict（只 applyPlistInfo 到各
                // 属性），loadName/reloadInfoPlist 只在容器设置
                // 页走；启动时 czfFreeKeychainGroup（M:734）与
                // czfIsolateMultiOpenContainersIfNeeded（M:881）
                // 直接读这里，裸读读不到外置 plist 就回 -1：
                // 已占的组号被当成空闲，新容器撞组、两分身共用
                // 一组钥匙串（L438-1/G5 同款伤害）；未隔离过
                // 的外置容器还会因 -1 被重分新组，旧组令牌留
                // 在旧组里、新组是空的，下次启动登录态就没了。
                // 本地容器（无书签）与死书签不动。
                let czfDidAccess = storageBookMark != nil && bookmarkResolved && containerURL.startAccessingSecurityScopedResource()
                defer { if czfDidAccess { containerURL.stopAccessingSecurityScopedResource() } }
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
                // 3.8.900（L574-3）：与 keychainGroupId 同根——外置
                // 容器裸读读不到 plist，LCSelectContainerView
                // 里一直显示 unknown；同款先拿 scope 再读。
                let czfDidAccess = storageBookMark != nil && bookmarkResolved && containerURL.startAccessingSecurityScopedResource()
                defer { if czfDidAccess { containerURL.stopAccessingSecurityScopedResource() } }
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
                    // 3.8.900（L568-12）：书签是创建侧带 scope 建的
                    // （LCUtils.bookmark(for:)，1<<11），这里解析
                    // 原来用默认选项 []——解析侧 scope 是 1<<10，
                    // 不带它解出的 URL 没有安全域，startAccessing
                    // 恒 false（L566-8 分享扩展/快捷指令同款）。
                    // 全仓其余解析点都带 1<<10，只剩这一处漏网。
                    // 后果：外置容器在存储页恒显示 0 字节、缓存
                    // 清理静默跳过（那两路已按 L39 包了
                    // startAccessing，只等这里解出带 scope 的 URL）。
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: URL.BookmarkResolutionOptions(rawValue: 1 << 10), bookmarkDataIsStale: &isStale)

                    self.resolvedContainerURL = url
                    // 3.8.900（L570-4）：只在解析成功时置真——原来这行
                    // 写在 do/catch 外面，书签已死（外置夹被移动/删掉）
                    // 抛错也照置真，resolvedContainerURL 仍是 nil、
                    // 标志却说已解析。调用方全凭它认“外置可用”：
                    // 备份那路（D:3232）拿 containerURL（已回落到
                    // 本地 dataPath/<夹名>、init 还顺手建了个空壳目录
                    // （M:280）当真夹拷、计成功，备份报成功、真数据根本没进去。
                    self.bookmarkResolved = true

                } catch {
                    print(error.localizedDescription)
                }
        }
        
        do {
            // 3.8.900（L573-4）：外置容器读 plist 也要先
            // startAccessing——书签解出带 scope 的 URL 只是“能
            // 访问”，不 start 就读不到（deleteData 的 L568-16
            // 同款：同一 containerURL 列目录直接抛错）。原来
            // 这里裸读，外置容器的隔离/IDFV/指纹开关每次进设置
            // 页都显示关、伪装值全空，用户以为没开隔离、其实
            // plist 里开着；书签已死时 bookmarkResolved 为
            // false，不碰，行为与原来一致（本地回落路照旧）。
            let czfDidAccess = bookmarkResolved && containerURL.startAccessingSecurityScopedResource()
            defer { if czfDidAccess { containerURL.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            if(!fm.fileExists(atPath: infoDictUrl.deletingLastPathComponent().path)) {
                try fm.createDirectory(at: infoDictUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            let plistInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoDictUrl), format: nil)
            if let plistInfo = plistInfo as? [String : Any] {
                applyPlistInfo(plistInfo)
            }
        } catch {
            // 3.8.718（B-2）：文件不存在 = 全新容器正常路径，一字
            // 不动（静默）；文件存在但读/解析失败 = 记日志 + 置失
            // 败标记（容器页可读、挂提示行），隔离/IDFV/指纹开关
            // 不再全按默认关静默显示。
            if FileManager.default.fileExists(atPath: infoDictUrl.path) {
                print("[CZF] 容器 plist 读取失败：\(infoDictUrl.path)，原因：\(error.localizedDescription)")
                czfPlistReadFailed = true
            }
        }
    }

    // plist 读共用（D3）：convenience init 与 loadName 两处
    // 原来各写一份（14 个键 +“先读值再开开关”顺序注释），
    // 新键只改这里一处。先读值再开开关：didSet 在开时会补
    // 没生成的值（D1 派生值也在 didSet 里补），顺序反了会
    // 把刚生成的值又用 nil 盖掉。
    private func applyPlistInfo(_ plistInfo: [String: Any]) {
        isolateAppGroup = plistInfo["isolateAppGroup"] as? Bool ?? false
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
        // 3.8.572（L103）：开旗必须在读值之后——原来上面先开
        // spoofIdentifierForVendor 再读 spoofedIdentifier，didSet
        // 开旗时刚生成的 UUID 会被下一行 nil（plist 里没这个键
        // 时）盖掉，旗开着、值没了，客端静默不 hook、IDFV 用回
        // 真的，L89 的种子判据还认旗开着是“已隔离”不再修；
        // spoofDeviceFingerprint 本来就在最后，没动。
        spoofIdentifierForVendor = plistInfo["spoofIdentifierForVendor"] as? Bool ?? false
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
        // 3.8.720（B-1）：-1 是“读不到”的哨兵值，不是合法组号——
        // 磁盘已有文件时绝不把 -1 写进去（会永久丢组号与登录态，
        // 原 plist 还被内存默认值覆盖）；拦下并置写失败标记，
        // 调用方按写失败报错。
        // 3.8.722（B-2）：拦截改无条件——原来只拦“文件已存在”时，
        // 文件不存在（容器 plist 缺失、infoDict 读不到回 -1）时
        // 直接放行，把 -1 写进新建的 plist；写死后文件已存在且含
        // -1，下次保存反被守卫拒写，配置锁死；-1 组也不在授权表内，
        // SecItemAdd 报 -34018。文件不存在也不写 -1，直接置写失败
        // 标记返回，调用方（容器页 saveContainer 路）凭标记报错并
        // 把开关拨回旧值。合法调用方传的都是已分配的组号
        //（czfFreeKeychainGroup / czfRestoreKeychainGroup 永不回
        // -1，升级路写 0），不受影响。
        if keychainGroupId == -1 {
            print("[CZF] 容器 plist 拒绝写入 keychainGroupId=-1：\(infoDictUrl.path)")
            czfPlistWriteFailed = true
            return
        }
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
        
        // 3.8.900（L573-5）：与 L573-4 同根的写侧——外置容器写
        // plist 也要先 startAccessing，否则写盘静默失败
        // （catch 空着）：容器页开关看着改了、退出重进又变
        // 回去，隔离/指纹/代理全都存不住。只包写盘这段，
        // 本地容器（storageBookMark 为 nil）与死书签不动。
        let czfDidAccess = storageBookMark != nil && bookmarkResolved && containerURL.startAccessingSecurityScopedResource()
        defer { if czfDidAccess { containerURL.stopAccessingSecurityScopedResource() } }
        do {
            let fm = FileManager.default
            if(!fm.fileExists(atPath: infoDictUrl.deletingLastPathComponent().path)) {
                try fm.createDirectory(at: infoDictUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            let plistData = try PropertyListSerialization.data(fromPropertyList: infoDict as Any, format: .binary, options: 0)
            // 3.8.552（L215）：容器 plist 必须原子写——原来直接写，进程
            // 恰在写盘那一刻被杀就留半截文件，NSDictionary(contentsOf:)
            // 读回 nil、keychainGroupId 回落 -1（客端 SecItem.m 读到
            // 0 走 legacy 共享组），钥匙串静默落回跨 App 共用、且
            // 启动时没有任何一路会重分（只剩设置页旧容器迁移那处认 -1）。
            // 组 A 其余有内容的写盘点（M:1237、S:388、S:3092）早已是 .atomic，
            // 只剩这一处漏网（V:852 是 0 字节标记文件，无内容可撕，不算）；成功路径一字未变。
            try plistData.write(to: infoDictUrl, options: .atomic)
            // 3.8.718（B-2）：写成了就清失败标记（上次失败的旧旗
            // 不留到下次保存误报）。
            czfPlistWriteFailed = false
        } catch {
            // 3.8.718（B-2）：.atomic 写失败不再无声——记日志 +
            // 置标记，调用方（容器页 saveContainer 路）凭标记报
            // 错并把开关拨回旧值；签名不动（13 处调用点不用改）。
            print("[CZF] 容器 plist 写入失败：\(infoDictUrl.path)，原因：\(error.localizedDescription)")
            czfPlistWriteFailed = true
        }
    }
    
    func reloadInfoPlist() {
        // 3.8.900（L573-6）：与 L573-4 同根——容器页 onAppear 每次
        // 都调这里，外置容器裸读读不到就把 infoDict 置 nil，
        // keychainGroupId 立刻变 -1：之后点“清理钥匙串”会按
        // -1 归一到 0 组清理（LCUtilsExtensions:525），真组
        // （如 5 组）的令牌全残留；再存一次还会把 -1 写进
        // plist（L573-5 修好写盘后）。读之前先拿 scope，死书签
        // 时不碰，行为与原来一致。
        let czfDidAccess = storageBookMark != nil && bookmarkResolved && containerURL.startAccessingSecurityScopedResource()
        defer { if czfDidAccess { containerURL.stopAccessingSecurityScopedResource() } }
        infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
        // 3.8.720（B-1）：读失败置标记——文件在但读不出时，
        // 之后任何保存都会把 keychainGroupId = -1 写进盘
        //（头上的注释 L573-6 已写明后果）；读成功清标记；
        // 文件不存在是全新容器，不置标记。
        if infoDict == nil && FileManager.default.fileExists(atPath: infoDictUrl.path) {
            print("[CZF] 容器 plist 读取失败：\(infoDictUrl.path)")
            czfPlistReadFailed = true
        } else if infoDict != nil {
            czfPlistReadFailed = false
        }
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
