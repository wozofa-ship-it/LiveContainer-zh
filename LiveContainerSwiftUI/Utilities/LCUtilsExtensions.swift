//
//  LCUtilsExtensions.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import LocalAuthentication

extension LCUtils {
    public static let appGroupUserDefault = UserDefaults.init(suiteName: LCSharedUtils.appGroupID()) ?? UserDefaults.standard
    
    // 本次运行内已验签通过的插件文件夹，避免每次打开 App 重复扫描全局插件（force=true 的安装/管理流程不受影响）
    private static var verifiedTweakFolders: Set<String> = []
    private static let verifiedTweakFoldersLock = NSLock()

    // 串行化所有 tweak 签名：宿主启动部署桥（后台 Task 单签）
    // 与游客启动整夹签名曾同时改写同一文件，签名写坏/指纹
    // 错乱；所有签名入口都走这里排队，一次只跑一个任务。
    // 已在串行队列上时直接跑（防嵌套调用死锁）。
    private static let tweakSignQueueKey = DispatchSpecificKey<Void>()
    private static let tweakSignQueue: DispatchQueue = {
        let q = DispatchQueue(label: "czf.tweak.sign.serial")
        q.setSpecific(key: tweakSignQueueKey, value: ())
        return q
    }()
    private static func withSerializedTweakSign<T>(_ work: @escaping () async throws -> T) async throws -> T {
        if DispatchQueue.getSpecific(key: tweakSignQueueKey) != nil {
            return try await work()
        }
        return try await withCheckedThrowingContinuation { cont in
            tweakSignQueue.async {
                let sema = DispatchSemaphore(value: 0)
                Task {
                    do {
                        let result = try await work()
                        cont.resume(returning: result)
                    } catch {
                        cont.resume(throwing: error)
                    }
                    sema.signal()
                }
                sema.wait()
            }
        }
    }
    
    private static func isTweakFolderVerified(_ url: URL) -> Bool {
        verifiedTweakFoldersLock.lock()
        defer { verifiedTweakFoldersLock.unlock() }
        return verifiedTweakFolders.contains(url.path)
    }
    
    private static func markTweakFolderVerified(_ url: URL) {
        verifiedTweakFoldersLock.lock()
        verifiedTweakFolders.insert(url.path)
        verifiedTweakFoldersLock.unlock()
    }

    // 证书换了（不同团队）后内存里的“已验过”要作废：指纹表是按
    // 团队分键的，下次冷启动会重签；但同进程内 isTweakFolderVerified
    // 会直接短路跳过，插件还留着旧团队的签名、游客里 dlopen 报
    // 签名无效，直到重启 App 才自愈。导入证书成功后调这里清掉。
    // 同团队重导也清，无非多签一轮，不亏。
    static func czfInvalidateVerifiedTweakFolders() {
        verifiedTweakFoldersLock.lock()
        verifiedTweakFolders.removeAll()
        verifiedTweakFoldersLock.unlock()
    }

    // 验签指纹：文件大小+修改时间。文件被换掉/重签都会变，变了就重验。
    private static func tweakFingerprint(of attributes: [FileAttributeKey: Any]) -> String {
        let size = attributes[.size] as? NSNumber ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(mtime)"
    }
    
    // 签名唯一入口（串行）：部署 Task 与启动签名曾同时改写
    // 同一文件；包一层串行锁再跑实现，一次只签一批
    public static func signTweaks(tweakFolderUrl: URL, force : Bool = false, progressHandler : ((Progress) -> Void)? = nil) async throws {
        try await withSerializedTweakSign {
            try await signTweaksImpl(tweakFolderUrl: tweakFolderUrl, force: force, progressHandler: progressHandler)
        }
    }

    // S-7 魔数校验抽共用（原在 LCAltStoreSourcesView 私有，坞源
    // 面板 installTweakFromPanel / downloadFromPanel 也要验）：
    // DownloadHelper / URLSession 都不验 HTTP 状态，404 错误页
    // 也会落盘；读前 4 字节比对。
    static func czfFileHasPrefix(_ url: URL, prefixes: [[UInt8]]) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return prefixes.contains([UInt8](data))
    }

    // 按文件类型取期望前缀：dylib 是 Mach-O（32/64 位、大小端、
    // fat 通吃），其余（IPA）是 ZIP（PK\x03\x04）。
    static func czfExpectedPrefixes(for url: URL) -> [[UInt8]] {
        if url.pathExtension.lowercased() == "dylib" {
            return [
                [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],
                [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],
                [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF],
            ]
        }
        return [[0x50, 0x4B, 0x03, 0x04]]
    }

    // 插件文件名：裸域名链接 lastPathComponent 为空时兜底
    // tweak.dylib（源页 installTweak 与坞面板
    // installTweakFromPanel 共用）。
    static func czfTweakFileName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? "tweak.dylib" : name
    }

    // 换插件文件并签名（带回滚）：旧文件先挪到 .bak，签失败时
    // 删新文件、把旧的挪回来；签成功再删备份。原来先删旧文件
    // 再签，签失败旧的也没了，用户丢掉能用的插件。暂存名
    // foo.dylib.bak 不以 .dylib 结尾，signTweaks 枚举不会把它也签了。
    static func czfReplaceTweakFile(tempURL: URL, destURL: URL, folderURL: URL) async throws {
        let fm = FileManager.default
        let backupURL = destURL.appendingPathExtension("bak")
        var oldBackedUp = false
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: backupURL)
            try fm.moveItem(at: destURL, to: backupURL)
            oldBackedUp = true
        }
        do {
            try fm.moveItem(at: tempURL, to: destURL)
            try await LCUtils.signTweaks(tweakFolderUrl: folderURL, force: true)
        } catch {
            try? fm.removeItem(at: destURL)
            if oldBackedUp {
                try? fm.moveItem(at: backupURL, to: destURL)
            }
            throw error
        }
        try? fm.removeItem(at: backupURL)
    }

    private static func signTweaksImpl(tweakFolderUrl: URL, force : Bool = false, progressHandler : ((Progress) -> Void)? = nil) async throws {
        guard LCSharedUtils.certificatePassword() != nil else {
            return
        }
        if !force, isTweakFolderVerified(tweakFolderUrl) {
            return
        }
        // 落盘验签指纹（按证书 Team 分键）：指纹对得上的文件
        // 就是本 Team 签过的，直接跳过——插件文件夹文件一多，
        // 这是冷启后第一次打开 App 的主要耗时之一。注意：绝不
        // 能把“通用验签通过”当成“本 Team 签过”——通用验签
        // 只认签名本身有效，不认团队，旧团队签的文件也能通过，
        // 跳过就再也不会重签，游客里 dlopen 照样报签名无效
        // （2026-10-24 全量弹窗就是这么来的）。所以没指纹的
        // 文件必须实签一次，签完再记；Team 取不到、根本没表
        // 可查时，也一律实签，不许再用通用验签兜底跳过——
        // 2026-10-24 22:41 真机证实：v153 的通用验签兜底让旧
        // 团队签的 CZFProxy 原样跳过，签名和 20:54 一模一样，
        // 自愈根本没生效。宁可每次启动多签一轮，不许再跳过。
        // v2：v1 表里已混进只验过没签过的文件，换键后下一版
        // 启动时全部重签一次自愈。
        var fingerprintKey: String? = nil
        var fingerprints: [String: String] = [:]
        var fingerprintsChanged = false
        if let certData = certificateData(),
           let certPassword = LCSharedUtils.certificatePassword(),
           let teamId = getCertTeamId(withKeyData: certData, password: certPassword) {
            let key = "LCVerifiedTweakFingerprints_\(teamId)_v2"
            fingerprintKey = key
            fingerprints = appGroupUserDefault.dictionary(forKey: key) as? [String: String] ?? [:]
        }
        let fm = FileManager.default
        // a disabled folder is renamed to .disabled; skip it, it gets signed again once re-enabled
        if !fm.fileExists(atPath: tweakFolderUrl.path) {
            let disabledUrl = tweakFolderUrl.deletingLastPathComponent().appendingPathComponent(tweakFolderUrl.lastPathComponent + ".disabled")
            if fm.fileExists(atPath: disabledUrl.path) {
                return
            }
        }
        var isFolder :ObjCBool = false
        if(fm.fileExists(atPath: tweakFolderUrl.path, isDirectory: &isFolder) && !isFolder.boolValue) {
            return
        }
        
        // check if re-sign is needed
        // if signature is invalid, we need to re-sign. dylib and framework's main binary are supported
        // 递归枚举：加载侧（TweakLoader）会递归进模块夹，签名侧以前只扫顶层，
        // 嵌套 .dylib 从没签过、加载必弹 Failed to load tweaks。顶层保持原语义
        // （签失败即 throw）；嵌套尽力签（失败也不拦启动，顶多还是以前的弹窗，
        // 不比现在差）。框架包只签主可执行文件、不往里钻；已停用的子夹不进。
        let baseDepth = tweakFolderUrl.pathComponents.count
        guard let enumerator = fm.enumerator(at: tweakFolderUrl, includingPropertiesForKeys: nil) else {
            return
        }
        var topFiles: [URL] = []
        var nestedFiles: [URL] = []

        for case let entryURL as URL in enumerator {
            let isTopLevel = entryURL.pathComponents.count - baseDepth == 1
            let attributes: [FileAttributeKey: Any]
            if isTopLevel {
                attributes = try fm.attributesOfItem(atPath: entryURL.path)
            } else {
                // 嵌套项读不到属性就跳过，不拦启动
                guard let a = try? fm.attributesOfItem(atPath: entryURL.path) else { continue }
                attributes = a
            }
            let fileType = attributes[.type] as? FileAttributeType
            if(fileType != FileAttributeType.typeDirectory && fileType != FileAttributeType.typeRegular) {
                continue
            }
            let name = entryURL.lastPathComponent
            let baseName = name.hasSuffix(".disabled") ? String(name.dropLast(".disabled".count)) : name
            var candidate: URL? = nil
            if(fileType == FileAttributeType.typeDirectory) {
                if(baseName.hasSuffix(".framework")) {
                    guard let frameworkBundle = Bundle(url: entryURL), let executableURL = frameworkBundle.executableURL else {
                        enumerator.skipDescendants()
                        continue
                    }
                    candidate = executableURL
                    enumerator.skipDescendants()
                } else if(name.hasSuffix(".disabled")) {
                    enumerator.skipDescendants()
                    continue
                } else {
                    // 普通子夹：往里走，不签夹子本身
                    continue
                }
            } else if (fileType == FileAttributeType.typeRegular && baseName.hasSuffix(".dylib")) {
                candidate = entryURL
            } else {
                continue
            }
            guard let fileURL = candidate else { continue }

            if !force {
                // 指纹按最终要验的文件现取属性：框架类插件上文把
                // fileURL 换成了包内的可执行文件，不能用文件夹的属性
                let fpAttributes = (try? fm.attributesOfItem(atPath: fileURL.path)) ?? attributes
                let fingerprint = tweakFingerprint(of: fpAttributes)
                if fingerprints[fileURL.path] == fingerprint {
                    continue;
                }
                // 没指纹的一律实签（见上文注释）。Team 取不到时
                // fingerprintKey 为 nil、没有任何指纹可比对，同样
                // 落到待签实签——绝不许再用通用验签兜底
                // 跳过（通用验签不认团队，旧团队签的文件也能通过）。
            }

            if isTopLevel {
                topFiles.append(fileURL)
            } else {
                nestedFiles.append(fileURL)
            }
        }

        if !topFiles.isEmpty {
            for fileURL in topFiles {
                LCPatchAppBundleFixupARM64eSlice(fileURL)
            }

            // 3.8.500（L19）：顶层插件签名 continuation 加 5 分钟超时兜底——
            // 与启动路签名（LCAppModel signApp，L18）同款：ZSigner 回调
            // 一直不来时原来永远挂起（zsign.mm 的 dispatch_group_wait
            // 是 DISPATCH_TIME_FOREVER，单个文件签名卡住就永远等不到
            // 回调），runApp 永不返、isAppRunning 一直 true、App 再也
            // 点不开。超时与正常完成用 CZFOnceFlag 互斥，resume 只调
            // 一次；超时后抛错走原有失败路径（文件夹不记已验，下次
            // 启动重试）。
            let czfTopResumeOnce = CZFOnceFlag()
            var czfTopTimeoutTask: Task<Void, Never>?
            try await withUnsafeThrowingContinuation({ (c: UnsafeThrowingContinuation<Void>) in
                czfTopTimeoutTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                    if czfTopResumeOnce.claimTimeout() {
                        c.resume(throwing: "插件签名超时（已等待 5 分钟），请重试")
                    }
                }
                let progress = signFilesWithZSign(with: topFiles) { success, error in
                    if czfTopResumeOnce.claim() {
                        if(success) {
                            c.resume()
                            return
                        }

                        guard let error else {
                            c.resume()
                            return
                        }
                        c.resume(throwing: error)
                    }
                }
                if let progress {
                    progressHandler?(progress)
                }
            })
            czfTopTimeoutTask?.cancel()
            // 刚签完的文件把指纹刷新成签后状态，下次冷启动直接跳过校验
            if let fingerprintKey {
                for fileURL in topFiles {
                    if let attributes = try? fm.attributesOfItem(atPath: fileURL.path) {
                        fingerprints[fileURL.path] = tweakFingerprint(of: attributes)
                        fingerprintsChanged = true
                    }
                }
            }
        }

        if !nestedFiles.isEmpty {
            for fileURL in nestedFiles {
                LCPatchAppBundleFixupARM64eSlice(fileURL)
            }

            // 3.8.500（L19）：嵌套插件签名同款 5 分钟超时兜底（与上面
            // 顶层同根因）；超时按失败返回 false，启动继续走（与嵌套
            // 签失败同款：不记指纹、不拦启动）。
            let czfNestedResumeOnce = CZFOnceFlag()
            var czfNestedTimeoutTask: Task<Void, Never>?
            let nestedOK = await withUnsafeContinuation({ c in
                czfNestedTimeoutTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                    if czfNestedResumeOnce.claimTimeout() {
                        c.resume(returning: false)
                    }
                }
                let progress = signFilesWithZSign(with: nestedFiles) { success, _ in
                    if czfNestedResumeOnce.claim() {
                        c.resume(returning: success)
                    }
                }
                if let progress {
                    progressHandler?(progress)
                }
            })
            czfNestedTimeoutTask?.cancel()
            if nestedOK, let fingerprintKey {
                for fileURL in nestedFiles {
                    if let attributes = try? fm.attributesOfItem(atPath: fileURL.path) {
                        fingerprints[fileURL.path] = tweakFingerprint(of: attributes)
                        fingerprintsChanged = true
                    }
                }
            }
        }

        if fingerprintsChanged, let fingerprintKey {
            appGroupUserDefault.set(fingerprints, forKey: fingerprintKey)
        }
        markTweakFolderVerified(tweakFolderUrl)
    }

    // 只签单个插件文件（部署手势插件时用）：原来部署替换一个文件要把
    // 两个全局插件目录整夹 force 重签，插件越多越慢；其余文件签名没动
    // 过，没必要陪着重签。处理与 signTweaks 对单文件一致（先做 arm64e
    // 切片修补再签）。
    public static func signSingleTweakFile(_ fileURL: URL) async throws {
        try await withSerializedTweakSign {
            try await signSingleTweakFileImpl(fileURL)
        }
    }

    private static func signSingleTweakFileImpl(_ fileURL: URL) async throws {
        guard LCSharedUtils.certificatePassword() != nil else {
            return
        }
        LCPatchAppBundleFixupARM64eSlice(fileURL)
        // 3.8.500（L19）：单文件签名同款 5 分钟超时兜底（与上面顶层
        // 同根因）；超时后抛错走调用方原有失败路径。
        let czfSingleResumeOnce = CZFOnceFlag()
        var czfSingleTimeoutTask: Task<Void, Never>?
        try await withUnsafeThrowingContinuation { (c: UnsafeThrowingContinuation<Void>) in
            czfSingleTimeoutTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if czfSingleResumeOnce.claimTimeout() {
                    c.resume(throwing: "插件签名超时（已等待 5 分钟），请重试")
                }
            }
            let _ = signFilesWithZSign(with: [fileURL]) { success, error in
                if czfSingleResumeOnce.claim() {
                    if success {
                        c.resume()
                        return
                    }
                    guard let error else {
                        c.resume()
                        return
                    }
                    c.resume(throwing: error)
                }
            }
        }
        czfSingleTimeoutTask?.cancel()
    }

    private static func authenticateUser(completion: @escaping (Bool, Error?) -> Void) {
        // Create a context for authentication
        let context = LAContext()
        var error: NSError?

        // Check if the device supports biometric authentication
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            // Determine the reason for the authentication request
            let reason = "lc.utils.requireAuthentication".loc

            // Evaluate the authentication policy
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evaluationError in
                DispatchQueue.main.async {
                    if success {
                        // Authentication successful
                        completion(true, nil)
                    } else {
                        if let evaluationError = evaluationError as? LAError, evaluationError.code == LAError.userCancel || evaluationError.code == LAError.appCancel {
                            completion(false, nil)
                        } else {
                            // Authentication failed
                            completion(false, evaluationError)
                        }

                    }
                }
            }
        } else {
            // Biometric authentication is not available
            DispatchQueue.main.async {
                if let evaluationError = error as? LAError, evaluationError.code == LAError.passcodeNotSet {
                    // No passcode set, we also define this as successful Authentication
                    completion(true, nil)
                } else {
                    completion(false, error)
                }

            }
        }
    }
    
    public static func authenticateUser() async throws -> Bool {
        if DataManager.shared.model.isHiddenAppUnlocked {
            return true
        }
        
        var success = false
        var error : Error? = nil
        await withUnsafeContinuation { c in
            LCUtils.authenticateUser { success1, error1 in
                success = success1
                error = error1
                c.resume()
            }
        }
        if let error = error {
            throw error
        }
        if !success {
            return false
        }
        DispatchQueue.main.async {
            DataManager.shared.model.isHiddenAppUnlocked = true
        }
        return true
    }

    // 解锁已锁定 App 用（3.8.441，用户 13:07 令“锁定 App
    // 想解锁必须人脸识别”）：每次都弹人脸识别，不走上面
    // isHiddenAppUnlocked 的短路——隐藏 App 解锁过一次后
    // 上面那个直接放行，锁定的 App 点“解锁”就不弹人脸了。
    // 这里不碰 isHiddenAppUnlocked（只管 App 锁，不管隐藏）。
    public static func authenticateUserForced() async throws -> Bool {
        var success = false
        var error: Error? = nil
        await withUnsafeContinuation { c in
            LCUtils.authenticateUser { success1, error1 in
                success = success1
                error = error1
                c.resume()
            }
        }
        if let error = error {
            throw error
        }
        return success
    }
    
    public static func getStoreName() -> String {
        switch LCUtils.store() {
        case .AltStore:
            return "AltStore"
        case .SideStore:
            return "SideStore"
        case .ADP:
            return "ADP"
        default:
            return "Unknown Store"
        }
    }
    
    public static func removeAppKeychain(dataUUID label: String) {
        [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassCertificate, kSecClassKey, kSecClassIdentity].forEach {
          let status = SecItemDelete([
            kSecClass as String: $0,
            "alis": label,
          ] as CFDictionary)
          if status != errSecSuccess && status != errSecItemNotFound {
              //Error while removing class $0
              NSLog("[LC] Failed to find keychain items: \(status)")
          }
        }
    }
    
    public static func forEachInstalledLC(isFree: Bool, block: (String, inout Bool) -> Void) {
        for scheme in LCSharedUtils.lcUrlSchemes() {
            if scheme == UserDefaults.lcAppUrlScheme() {
                continue
            }
            
            // Check if the app is installed
            guard let url = URL(string: "\(scheme)://"),
                  UIApplication.shared.canOpenURL(url) else {
                continue
            }
            
            // Check shared utility logic
            if isFree && LCSharedUtils.isLCScheme(inUse: scheme) {
                continue
            }
            
            var shouldBreak = false
            block(scheme, &shouldBreak)
            
            if shouldBreak {
                break
            }
        }
    }
    
    public static func askForJIT(withScript script: String? = nil, appName: String? = nil, classicMode: UInt = 0, onServerMessage: ((String) -> Void)? = nil) async -> Bool {
        // if LiveContainer is installed by TrollStore
        let tsPath = "\(Bundle.main.bundlePath)/../_TrollStore"
        if (access((tsPath as NSString).utf8String, 0) == 0) {
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
            return true
        }
        
        guard let groupUserDefaults = UserDefaults(suiteName: LCSharedUtils.appGroupID()),
              let jitEnabler = JITEnablerType(rawValue: groupUserDefaults.integer(forKey: "LCJITEnablerType")) else {
            return false
        }
        
        if(jitEnabler == .SideJITServer){
            guard
                  let sideJITServerAddress = groupUserDefaults.string(forKey: "LCSideJITServerAddress"),
                  let deviceUDID = groupUserDefaults.string(forKey: "LCDeviceUDID"),
                  !sideJITServerAddress.isEmpty && !deviceUDID.isEmpty else {
                return false
            }
            
            onServerMessage?("Please make sure the VPN is connected if the server is not in your local network.")
            
            do {
                let launchJITUrlStr = "\(sideJITServerAddress)/\(deviceUDID)/\(Bundle.main.bundleIdentifier ?? "")"
                guard let launchJITUrl = URL(string: launchJITUrlStr) else { return false }
                let session = URLSession.shared
                
                onServerMessage?("Contacting SideJITServer at \(sideJITServerAddress)...")
                let request = URLRequest(url: launchJITUrl)
                let (data, _) = try await session.data(for: request)
                onServerMessage?(String(decoding: data, as: UTF8.self))
                
            } catch {
                onServerMessage?("Failed to contact SideJITServer: \(error)")
            }
            
            return false
        } else if (jitEnabler == .JITStreamerEBLegacy) {
            var JITStresmerEBAddress = groupUserDefaults.string(forKey: "LCSideJITServerAddress") ?? ""
            if JITStresmerEBAddress.isEmpty {
                JITStresmerEBAddress = "http://[fd00::]:9172"
            }
            
            onServerMessage?("Please make sure the VPN is connected if the server is not in your local network.")
            
            do {
                
                onServerMessage?("Contacting JitStreamer-EB server at \(JITStresmerEBAddress)...")
                
                let session = URLSession.shared
                let decoder = JSONDecoder()
                
                let mountStatusUrlStr = "\(JITStresmerEBAddress)/mount"
                guard let mountStatusUrl = URL(string: mountStatusUrlStr) else { return false }
                let mountRequest = URLRequest(url: mountStatusUrl)
                
                // check mount status
                onServerMessage?("Checking mount status...")
                let (mountData, _) = try await session.data(for: mountRequest)
                let mountResponseObj = try decoder.decode(JITStreamerEBMountResponse.self, from: mountData)
                guard mountResponseObj.ok else {
                    onServerMessage?(mountResponseObj.error ?? "Mounting failed with unknown error.")
                    return false
                }
                if mountResponseObj.mounting {
                    onServerMessage?("Your device is currently mounting the developer disk image. Leave your device on and connected. Once this finishes, you can run JitStreamer again.")
                    onServerMessage?("Check \(JITStresmerEBAddress)/mount_status for mounting status.")
                    if let mountStatusUrl = URL(string: "\(JITStresmerEBAddress)/mount_status") {
                        await UIApplication.shared.open(mountStatusUrl)
                    }
                    return false
                }
                
                // open safari to use /launch_app api
                if let mountStatusUrl = URL(string: "\(JITStresmerEBAddress)/launch_app/\(Bundle.main.bundleIdentifier!)") {
                    onServerMessage?("JIT acquisition will continue in the default browser.")
                    await UIApplication.shared.open(mountStatusUrl)
                }
                return false
                
                
            } catch {
                onServerMessage?("Failed to contact JitStreamer-EB server: \(error)")
            }
        } else if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
            guard let appName else { onServerMessage?("Unable to get App Name, Please try again."); return false }
            // App 名/脚本含空格或特殊字符时直接拼出的 URL 为 nil，旧代码强解包即闪退；
            // 先 percent-encoding 再拼，LC 中转分支（走 base64）不受影响。
            let encodedAppName = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appName
            var launchURLStr = "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(encodedAppName)"
            
            if let script = script, !script.isEmpty {
                launchURLStr += "&script=\(script.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? script)"
            }
            
            if jitEnabler == .StosDebugLC {
                let encodedStr = Data(launchURLStr.utf8).base64EncodedString()


                var appToLaunch: LCAppModel? = nil
                // find an app that can respond to stikjit://
                appLoop:
                for app in DataManager.shared.model.apps {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == "stosdebug" {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
                guard let appToLaunch else {
                    onServerMessage?("StosDebug is not installed in LiveContainer.")
                    return false
                }
                
                if !appToLaunch.uiIsShared {
                    onServerMessage?("StosDebug is installed in LiveContainer, but is not a shared app. Convert it to a shared app to continue.")
                    return false
                }
                // check if stosdebug is already running
                var freeScheme = LCSharedUtils.getContainerUsingLCScheme(withFolderName: appToLaunch.uiDefaultDataFolder)
                
                if(freeScheme == nil) {
                    // if not, try to find a free lc
                    forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                        freeScheme = scheme
                        shouldBreak = true
                    }
                }
                guard let freeScheme else {
                    onServerMessage?("No free LiveContainer is available. Please either: \n(1)close one, \n(2)install a new one, \n(3)choose another method to enable JIT.")
                    return false
                }
                
                let launchURL = URL(string: "\(freeScheme)://open-url?url=\(encodedStr)")!
                LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                LCUtils.appGroupUserDefault.set(appToLaunch.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                onServerMessage?("JIT acquisition will continue in another LiveContainer.")
                
                await UIApplication.shared.open(launchURL)
            } else {
                guard let directURL = URL(string: launchURLStr) else {
                    onServerMessage?("Failed to build JIT URL, please try again.")
                    return false
                }
                onServerMessage?("JIT acquisition will continue in StosDebug.")
                // open 返回 false = StosDebug 没装/打不开：旧代码直接丢掉，
                // 静默无事。发一句人话并返回 false，上层弹提示。
                // 注：不用 canOpenURL——stosdebug 不在 Info.plist 的
                // LSApplicationQueriesSchemes 里，canOpenURL 永远 false，
                // 会把成功路也判成失败；open 的返回值直接说明开没开成。
                let opened = await UIApplication.shared.open(directURL)
                if !opened {
                    onServerMessage?("StosDebug 未安装/打不开，请先安装 StosDebug")
                }
                return opened
            }
            
        } else if jitEnabler == .StikJIT || jitEnabler == .StikJITLC {
            var launchURLStr = "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)"

            if let script = script, !script.isEmpty {
                launchURLStr += "&script-data=\(script.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? script)"
            }
            let launchURL : URL
            if jitEnabler == .StikJITLC {
                let encodedStr = Data(launchURLStr.utf8).base64EncodedString()


                var appToLaunch: LCAppModel? = nil
                // find an app that can respond to stikjit://
                appLoop:
                for app in DataManager.shared.model.apps {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == "stikjit" {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
                guard let appToLaunch else {
                    onServerMessage?("StikDebug is not installed in LiveContainer.")
                    return false
                }
                
                if !appToLaunch.uiIsShared {
                    onServerMessage?("StikDebug is installed in LiveContainer, but is not a shared app. Convert it to a shared app to continue.")
                    return false
                }
                // check if stikdebug is already running
                var freeScheme = LCSharedUtils.getContainerUsingLCScheme(withFolderName: appToLaunch.uiDefaultDataFolder)
                
                if(freeScheme == nil) {
                    // if not, try to find a free lc
                    forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                        freeScheme = scheme
                        shouldBreak = true
                    }
                }
                guard let freeScheme else {
                    onServerMessage?("No free LiveContainer is available. Please either: \n(1)close one, \n(2)install a new one, \n(3)choose another method to enable JIT.")
                    return false
                }
                
                launchURL = URL(string: "\(freeScheme)://open-url?url=\(encodedStr)")!
                LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                LCUtils.appGroupUserDefault.set(appToLaunch.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                onServerMessage?("JIT acquisition will continue in another LiveContainer.")
                
            } else {
                guard let directURL = URL(string: launchURLStr) else {
                    onServerMessage?("Failed to build JIT URL, please try again.")
                    return false
                }
                launchURL = directURL
                onServerMessage?("JIT acquisition will continue in StikDebug.")
            }
            // open 返回 false = StikDebug 没装/打不开：旧代码直接丢掉，
            // 静默无事。发一句人话并返回 false，上层弹提示（只给非 LC
            // 分支发，LC 分支走另一个容器、失败原因不一样）。
            // 注：不用 canOpenURL——stikjit 不在 Info.plist 的
            // LSApplicationQueriesSchemes 里，canOpenURL 永远 false，
            // 会把成功路也判成失败；open 的返回值直接说明开没开成。
            let opened = await UIApplication.shared.open(launchURL)
            if !opened, jitEnabler == .StikJIT {
                onServerMessage?("StikDebug 未安装/打不开，请先安装 StikDebug 2.3.0+")
            }
            return opened
        } else if jitEnabler == .SideStore {
            onServerMessage?("JIT acquisition will continue in SideStore.")
            let launchURL = URL(string: "sidestore://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)")!
            await UIApplication.shared.open(launchURL)
        }
        return false
    }

    static func moveFilesAtomicallyAfterPreflight(_ moves: [(URL, URL)]) throws {
        let fileManager = FileManager.default

        var seenSources = Set<URL>()
        var seenDestinations = Set<URL>()

        let normalizedMoves = moves.map { source, destination in
            (
                source.standardizedFileURL,
                destination.standardizedFileURL
            )
        }

        // MARK: - Preflight

        for (source, destination) in normalizedMoves {
            guard !source.path.isEmpty else {
                throw BatchMoveError.emptySource(source)
            }

            guard source != destination else {
                throw BatchMoveError.sourceEqualsDestination(source)
            }

            guard seenSources.insert(source).inserted else {
                throw BatchMoveError.duplicateSource(source)
            }
            
            guard fileManager.isWritableFile(atPath: source.deletingLastPathComponent().path) else {
                throw BatchMoveError.sourceParentIsNotWritable(source.deletingLastPathComponent())
            }

            guard seenDestinations.insert(destination).inserted else {
                throw BatchMoveError.duplicateDestination(destination)
            }

            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw BatchMoveError.sourceDoesNotExist(source)
            }

            do {
                _ = try source.checkResourceIsReachable()
            } catch {
                throw BatchMoveError.sourceIsNotReachable(source, underlying: error)
            }

            guard !fileManager.fileExists(atPath: destination.path) else {
                throw BatchMoveError.destinationAlreadyExists(destination)
            }

            let parent = destination.deletingLastPathComponent()

            var parentIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) else {
                throw BatchMoveError.destinationParentDoesNotExist(parent)
            }

            guard parentIsDirectory.boolValue else {
                throw BatchMoveError.destinationParentIsNotDirectory(parent)
            }

            guard fileManager.isWritableFile(atPath: parent.path) else {
                throw BatchMoveError.destinationParentIsNotWritable(parent)
            }

            if isDirectory.boolValue {
                let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
                let destinationPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"

                if destinationPath.hasPrefix(sourcePath) {
                    throw BatchMoveError.moveWouldPlaceDirectoryInsideItself(
                        source: source,
                        destination: destination
                    )
                }
            }
        }

        // MARK: - Execute only after all preflight checks pass

        // 真原子：执行中途失败时把已搬完的按相反顺序搬回去，
        // 否则 App 会卡在“本体已搬、数据还在原处”的半截状态——
        // 模型还指着旧路径（打不开），重试又撞 destinationAlreadyExists，
        // 只能手动去 Filza 挪回来。回滚本身尽力而为；回滚也失败
        // 时把两份错误都写进 underlying，用户看到的是实情。
        var completed: [(URL, URL)] = []
        for (source, destination) in normalizedMoves {
            do {
                try fileManager.moveItem(at: source, to: destination)
                completed.append((source, destination))
            } catch {
                var rollbackError: Error?
                for (doneSource, doneDestination) in completed.reversed() {
                    do {
                        try fileManager.moveItem(at: doneDestination, to: doneSource)
                    } catch {
                        if rollbackError == nil { rollbackError = error }
                    }
                }
                if let rollbackError {
                    let combined = NSError(domain: "LiveContainerBatchMove", code: 1, userInfo: [NSLocalizedDescriptionKey: "Move failed (\(error.localizedDescription)); rolling back completed moves also failed (\(rollbackError.localizedDescription)). Files may be left in a partial state — please check their locations."])
                    throw BatchMoveError.moveFailed(
                        source: source,
                        destination: destination,
                        underlying: combined
                    )
                }
                throw BatchMoveError.moveFailed(
                    source: source,
                    destination: destination,
                    underlying: error
                )
            }
        }
    }
    
    // 把系统/网络的英文报错翻成能看懂的中文并分清原因：安装、
    // 下载、备份、恢复失败时原来直接弹英文原文（"The Internet
    // connection appears to be offline." 这类），链接死了、断网了、
    // 空间满了根本分不清。认不出的仍回落系统描述（系统语言为
    // 中文时它本身就是中文，不会更差）
    public static func czfFriendlyError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return "网络不可用，请检查网络连接后重试"
            case NSURLErrorTimedOut:
                return "连接超时，网络太慢或服务器没响应，可以稍后重试"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "找不到服务器，链接可能已失效"
            case NSURLErrorCannotConnectToHost:
                return "连不上服务器，链接可能已失效或服务器已关闭"
            case NSURLErrorCancelled:
                return "操作已取消"
            default:
                return "网络错误（代码 \(ns.code)），请检查网络后重试"
            }
        }
        // Cocoa 640 = NSFileWriteOutOfSpaceError（写文件空间满）
        if ns.domain == NSCocoaErrorDomain && ns.code == 640 {
            return "手机存储空间不足，请先清理空间再重试"
        }
        // POSIX ENOSPC(28)：底层写文件时空间满
        if ns.domain == NSPOSIXErrorDomain && ns.code == 28 {
            return "手机存储空间不足，请先清理空间再重试"
        }
        // Cocoa 260 = NSFileReadNoSuchFileError
        if ns.domain == NSCocoaErrorDomain && ns.code == 260 {
            return "文件不存在或已被删除"
        }
        return error.localizedDescription
    }

    static func openSideStore(delegate: LCAppModelDelegate? = nil, urlStr: String? = nil) {
        let sideStoreApp = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared, delegate: delegate)
        
        Task {
            try await sideStoreApp.runApp(bundleIdOverride: "builtinSideStore", urlStr: urlStr)
        }
    }
}
