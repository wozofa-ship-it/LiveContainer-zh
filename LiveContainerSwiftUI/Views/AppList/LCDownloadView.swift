//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import CryptoKit
import SwiftUI
import UserNotifications

// 3.8.666（B-1）：后台下载断点记录——进程被杀时内存里的
// savedResumeData 一起死，续传数据只活在后台会话守护进程里；
// 把（会话 identifier、下载地址、落盘目标、是否可自动续）记到
// Caches/CZFDownloadResume/<sha256(identifier)>.json，续传数据
// 另存同名 .resume；重开后按地址找回记录、按 identifier 重建
// 会话接管在途任务，或拿续传数据重下。记录在下载开始时建、
// 成功时清；用户主动取消的记 autoResume=false（只手动重下时用，
// 启动不自动续）；失败/被杀的记 autoResume=true（启动自动续）。
// 注意：代理开着时 hostDownloadConfiguration 返回 .default
// 前台配置（identifier 不生效），那路不受后台会话保护——记录
// 照记（续传数据仍可用），接管时找不到在途任务就走续传重下。
private struct CZFDownloadResumeRecord: Codable {
    var identifier: String
    var urlString: String
    var destPath: String
    var autoResume: Bool
    // 3.8.670（B-3）：连续最终失败计数——死链每次冷启动都重试 3 次
    // 并弹下载弹窗；带默认值，老记录（无此键）解码不受影响。
    var failCount: Int = 0
}

private enum CZFDownloadResumeStore {
    private static let directoryName = "CZFDownloadResume"

    static func directory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func key(for identifier: String) -> String {
        let digest = SHA256.hash(data: Data(identifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonURL(for identifier: String) -> URL? {
        directory()?.appendingPathComponent(key(for: identifier) + ".json")
    }

    private static func resumeURL(for identifier: String) -> URL? {
        directory()?.appendingPathComponent(key(for: identifier) + ".resume")
    }

    private static func allRecords() -> [(identifier: String, record: CZFDownloadResumeRecord)] {
        guard let dir = directory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [(identifier: String, record: CZFDownloadResumeRecord)] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(CZFDownloadResumeRecord.self, from: data) else { continue }
            out.append((identifier: record.identifier, record: record))
        }
        return out
    }

    static func saveRecord(identifier: String, url: URL, dest: URL, autoResume: Bool) {
        guard let dir = directory(), let jsonURL = jsonURL(for: identifier) else { return }
        // 同一地址只留一份记录：新一轮下载（重试换 identifier）先清
        // 旧轮的，不然启动自动续会找回已失效的旧 identifier。
        // 3.8.670（B-3）：换 identifier 不清失败计数——同一地址的旧
        // 记录带过来的 failCount 要留着，不然每轮重试/每次冷启动
        // 都从 0 开始，死链永远到不了 3 次阈值。
        var czfOldFailCount = 0
        for old in allRecords() where old.record.urlString == url.absoluteString && old.identifier != identifier {
            czfOldFailCount = max(czfOldFailCount, old.record.failCount)
            clearRecord(identifier: old.identifier)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var record = CZFDownloadResumeRecord(identifier: identifier, urlString: url.absoluteString, destPath: dest.path, autoResume: autoResume)
        record.failCount = czfOldFailCount
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: jsonURL, options: [.atomic])
        }
    }

    static func updateAutoResume(identifier: String, autoResume: Bool) {
        guard let jsonURL = jsonURL(for: identifier),
              var record = loadRecord(identifier: identifier) else { return }
        record.autoResume = autoResume
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: jsonURL, options: [.atomic])
        }
    }

    // 3.8.670（B-3）：只改失败计数，不动 autoResume 与其他字段。
    static func updateFailCount(identifier: String, failCount: Int) {
        guard let jsonURL = jsonURL(for: identifier),
              var record = loadRecord(identifier: identifier) else { return }
        record.failCount = failCount
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: jsonURL, options: [.atomic])
        }
    }

    static func loadRecord(identifier: String) -> CZFDownloadResumeRecord? {
        guard let jsonURL = jsonURL(for: identifier),
              let data = try? Data(contentsOf: jsonURL),
              let record = try? JSONDecoder().decode(CZFDownloadResumeRecord.self, from: data) else { return nil }
        return record
    }

    static func loadRecord(forURL url: URL) -> CZFDownloadResumeRecord? {
        allRecords().first { $0.record.urlString == url.absoluteString }?.record
    }

    static func pendingAutoResumeRecords() -> [CZFDownloadResumeRecord] {
        allRecords().map { $0.record }.filter { $0.autoResume }
    }

    static func saveResumeData(identifier: String, data: Data) {
        guard let dir = directory(), let resumeURL = resumeURL(for: identifier) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: resumeURL, options: [.atomic])
    }

    static func loadResumeData(identifier: String) -> Data? {
        guard let resumeURL = resumeURL(for: identifier) else { return nil }
        return try? Data(contentsOf: resumeURL)
    }

    static func clearRecord(identifier: String) {
        if let jsonURL = jsonURL(for: identifier) {
            try? FileManager.default.removeItem(at: jsonURL)
        }
        if let resumeURL = resumeURL(for: identifier) {
            try? FileManager.default.removeItem(at: resumeURL)
        }
    }
}

public final class DownloadHelper : ObservableObject {
    @Published var downloadProgress : Float = 0.0
    @Published var downloadedSize : Int64 = 0
    @Published var totalSize : Int64 = 0
    @Published var isDownloading = false
    @Published var cancelled = false
    // 下载弹窗是否被用户收起（收起后留一个小悬浮钮，下载继续、
    // 界面可以正常操作别的功能，点悬浮钮把弹窗调回来）
    @Published var minimized = false
    // 批量安装期间为 true：新下载不把弹窗重新弹出来，
    // 保持用户上次的收起/展开状态
    var batchMode = false
    // 3.8.664（F2）：实时速度 + 剩余时间 + 暂停/继续——速度用
    // 滑动窗口：每次进度回调记 (Date, totalBytesWritten)，取近
    // 2 秒增量；总长度未知（totalSize <= 0）时只显速度、不显 ETA。
    @Published var downloadSpeed: Int64 = 0
    @Published var downloadETA: TimeInterval?
    @Published var paused = false
    // 3.8.672（F-1）：下载排队——在途锁（czfDownloadInFlight）被占
    // 时后到的下载不再被调用方顶回去，改在这里排队等锁：等锁的
    // 请求按到达顺序记名（czfQueuedDownloads），拿到锁即摘掉；
    // czfCurrentDownloadName 是当前在下那路的显示名（弹窗/胶囊
    // 的排队行用）。只记内存，杀进程后排队项丢失可接受（续传
    // 记录只保在途那路）。
    @Published var czfQueuedDownloads: [String] = []
    @Published var czfCurrentDownloadName: String?
    private var czfSpeedSamples: [(date: Date, bytes: Int64)] = []
    // 3.8.670（B-2）：失速心跳任务——download() 内创建、返回/抛错时停。
    private var czfStallHeartbeat: Task<Void, Never>?
    // 进度发布节流用：上次发布进度的时间
    private var lastProgressPublish = Date.distantPast
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: UnsafeContinuation<(), Never>?
    // 断点续传：中断（取消/失败）时留下的续传数据和它对应的
    // 地址，下次下同一个地址时接着下，不用从 0 开始
    private var savedResumeData: Data?
    private var savedResumeURL: URL?
    private var currentURL: URL?
    // L50-1：同一 helper 同时只能下一个——源页下载
    // （czfDownloadVersionTo）与安装下载（installFromUrl）
    // 共用 LCTabView 注入的这一个实例，而 downloadOnce 的
    // continuation / downloadTask / savedResumeData 都是单
    // 槽；两路重叠会把槽盖掉，后完成的那路 completeCallback
    // 见 continuation 已空、永远不恢复，await 永久挂起
    // （安装卡死、队列停摆，只能杀 App）。download() 全程
    // 占住本标志（含 2 秒重试间隙——isDownloading 在间隙里
    // 是 false，不能拿它当判据），后到的等在途的走完再下
    // 自己的。
    private var czfDownloadInFlight = false
    // 3.8.666（B-1）：本次下载的后台会话 identifier（落盘记录用，
    // cancel() 写续传数据时也要它）与启动自动续找回的旧 identifier
    //（只给 download() 第 0 轮用，重试换新 identifier）；启动自动续
    // 每冷启动只试一次（LCTabView .task 调，见 czfAutoResumeInterruptedIfNeeded）。
    private var czfCurrentSessionIdentifier: String?
    private var czfResumeSessionIdentifier: String?
    private static var czfAutoResumeAttempted = false

    // 3.8.900（L564-3）czfCancelRequested：调用方传的取消检查闭包——下载在途期间
    // 每 0.5 秒读一次，读到真就停掉本次下载；不传（nil）时不轮询，原样。
    func download(url: URL, to: URL, czfCancelRequested: (() async -> Bool)? = nil) async throws {
        // 3.8.572（L339-1）：L50-1 的查与置是两次 MainActor.run、中间隔一次 await——都在主线程跑不等于原子：两路同时等时都能读到空闲、都置真并行下，单槽 continuation/downloadTask 被盖掉，后完成那路见 continuation 已空、永远不恢复（L50-1 原文说的挂起，安装队停摆、只能杀 App）。
        // 触发口子是现成的：重试 2 秒间隙里 isDownloading 已是 false（completeCallback 清的）、标志仍占着，源页守门 S:1834 只认 isDownloading、覆盖确认 S:1262 根本没门，两路都能进轮询等；安装队尾那路同款。查与置必须同一次 MainActor.run 内原子完成；defer 里不能 await，清标志仍放主线程 Task。
        // 3.8.672（F-1）：拿不到锁的请求记进排队名册再等，不再
        // 被调用方顶回去；拿到锁即摘掉（只摘首个同名项，同名
        // 两路排队时另一路还在册上）。等锁循环里不抛错，摘名
        // 一定发生在拿到锁之后，不漏记。
        var czfQueuedName: String? = nil
        while true {
            let acquired = await MainActor.run {
                if czfDownloadInFlight { return false }
                czfDownloadInFlight = true
                return true
            }
            if acquired { break }
            if czfQueuedName == nil {
                let name = czfDisplayDownloadName(url)
                czfQueuedName = name
                await MainActor.run { czfQueuedDownloads.append(name) }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let name = czfQueuedName {
            await MainActor.run {
                if let idx = czfQueuedDownloads.firstIndex(of: name) {
                    czfQueuedDownloads.remove(at: idx)
                }
            }
        }
        defer {
            Task { @MainActor in
                czfDownloadInFlight = false
                czfCurrentDownloadName = nil
            }
        }
        await MainActor.run { czfCurrentDownloadName = czfDisplayDownloadName(url) }
        currentURL = url
        // 3.8.666（B-1）：内存里没有同一地址的续传数据时，去盘上找——
        // 上次下载被杀/失败后留下的记录（Caches/CZFDownloadResume），
        // 续传数据与旧会话 identifier 一起捡起来；第 0 轮 downloadOnce
        // 用旧 identifier 重建会话，先看在途任务还在不在（系统回收
        // 时任务常在守护进程里继续跑），在就接管、不新建任务。
        if savedResumeData == nil || savedResumeURL != url {
            if let record = CZFDownloadResumeStore.loadRecord(forURL: url),
               let data = CZFDownloadResumeStore.loadResumeData(identifier: record.identifier) {
                savedResumeData = data
                savedResumeURL = url
                czfResumeSessionIdentifier = record.identifier
            } else if let record = CZFDownloadResumeStore.loadRecord(forURL: url) {
                // 只有记录、没有续传数据文件（任务可能还在守护进程里
                // 跑）：identifier 照样带上，第 0 轮先试接管。
                czfResumeSessionIdentifier = record.identifier
            }
        }
        // 3.8.603（O-15）：cancelled 只在用户主动发起新下载时复位——
        // 原来 downloadOnce 入口无条件清掉，重试间隙点的取消在
        // 下一轮开始时被擦除（重试循环的查取消跑在它前面，窗口虽小
        // 仍是真口子）；移到 download() 入口、拿了在途锁之后清，
        // 重试不再碰它。
        await MainActor.run {
            cancelled = false
            // 3.8.664（F2）：新下载从未暂停态开始——paused 只在这里复位，
            // 不在 downloadOnce 里（重试建新任务时不擦掉用户已按的暂停，
            // 见 downloadOnce 末尾按标志立即挂起）。
            paused = false
        }
        // 3.8.900（L564-3）：下载阶段的取消检查点——进度条旁 ✕ 只置
        // czfInstallCancelRequested（LCAppListView），原来 download() 全程
        // 不读它，✕ 要等整个下载跑完才在下载后检查点生效，大包/慢网下
        // 几分钟毫无反应。调用方传了检查闭包时，在途期间每 0.5 秒读一
        // 次（与签名取消轮询同款），读到就调 cancel() 停掉本次下载；
        // 闭包只读不取标志，标志由调用方下载后检查点/失败 catch 取走，
        // 不抢不漏；轮询只在拿到在途锁、复位 cancelled 之后才起跑，停
        // 的一定是本次下载，不会误停别的路正在下的包；没传闭包的调用
        // 方（预取、源页）原样。下载返回/抛错时 defer 停掉轮询。
        var czfDownloadCancelTask: Task<Void, Never>? = nil
        if let czfIsCancelRequested = czfCancelRequested {
            czfDownloadCancelTask = Task {
                while !Task.isCancelled {
                    if await czfIsCancelRequested() {
                        await MainActor.run { self.cancel() }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        defer { czfDownloadCancelTask?.cancel() }
        // 3.8.670（B-2）：失速心跳——每 1 秒看一次最后样本时间，超 2 秒
        // 无新样本就把速度清 0、ETA 清空（界面走 czfDownloadSpeedText
        // 现成的 "0 KB/s" 分支，无新文案）；只在下载中且未暂停时跑，
        // 暂停态不抢（暂停本就显示“已暂停”）。样本读写都在主线程
        //（进度回调在 MainActor.run 里记），心跳也在主线程读。
        // download() 返回/抛错时 defer 停掉。
        czfStallHeartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    guard isDownloading, !paused else { return }
                    guard let last = czfSpeedSamples.last?.date else { return }
                    guard Date().timeIntervalSince(last) > 2 else { return }
                    downloadSpeed = 0
                    downloadETA = nil
                }
            }
        }
        defer { czfStallHeartbeat?.cancel() }
        // 失败自动重试：最多 3 次（首次 + 2 次重试），网络抖
        // 一下不用用户再点一次。每次优先用上次留下的续传数
        // 据接着下（completeCallback 失败时已存好），不从 0
        // 开始；用户主动取消立即停、不重试
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                // O-15：重试前查取消——上轮失败后用户点了取消，
                // 不再白等 2 秒、也不再重试；睡完再查一次，睡着
                // 时取消也不再下。抛上轮的错（与下面 catch 里
                // cancelled 就 throw error 同款）。
                if cancelled { throw lastError ?? CancellationError() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if cancelled { throw lastError ?? CancellationError() }
            }
            do {
                // 3.8.666（B-1）：第 0 轮带上启动/重下找回的旧 identifier
                //（接管在途任务用），用完即清，重试换新 identifier；
                // czfIsFirstAttempt 供 downloadOnce 决定清不清理进度
                //（见 B-2：重试不归零）。
                let czfSessionID = attempt == 0 ? czfResumeSessionIdentifier : nil
                if attempt == 0 { czfResumeSessionIdentifier = nil }
                if let data = savedResumeData, savedResumeURL == url {
                    savedResumeData = nil
                    savedResumeURL = nil
                    try await downloadOnce(url: url, to: to, resumeData: data, czfSessionIdentifier: czfSessionID, czfIsFirstAttempt: attempt == 0)
                } else {
                    try await downloadOnce(url: url, to: to, resumeData: nil, czfSessionIdentifier: czfSessionID, czfIsFirstAttempt: attempt == 0)
                }
                // 3.8.570（L327-1）：取消后 download() 不能正常返回——cancel() 只 resume 了 continuation、不置错，downloadOnce 的 ansError 仍是 nil，直接 return 会让调用方当成下载成功；installFromUrl 有 cancelled 兜底、installTweak/预取走独立实例无取消路，唯独源页 czfDownloadVersionTo 覆盖确认路：旧文件仍在 destURL，魔数校验放过旧包，取消后仍弹分享表（分享的是旧版）。下完先查取消（读走 MainActor.run，L50-1 同款），取消就抛 CancellationError——四处调用方已按 cancelled 分流，不弹错。
                if await MainActor.run(body: { cancelled }) { throw CancellationError() }
                return
            } catch {
                lastError = error
                if cancelled {
                    throw error
                }
            }
        }
        // 3.8.670（B-3）：最终失败出口记一次失败——3 次重试耗尽才到
        // 这里（取消路在上面已直接抛，不计）；累计满 3 次最终失败
        // 后把 autoResume 改 false，冷启动不再自动续、也不再弹下载
        // 弹窗。阈值 3 次、处理 updateAutoResume(false) 而非
        // clearRecord：记录与续传数据保留，手动重下同一地址仍从
        // 断点续。成功时 downloadOnce 已清记录（含 failCount），
        // 无需另清。
        if let record = CZFDownloadResumeStore.loadRecord(forURL: url) {
            let newCount = record.failCount + 1
            CZFDownloadResumeStore.updateFailCount(identifier: record.identifier, failCount: newCount)
            if newCount >= 3 {
                CZFDownloadResumeStore.updateAutoResume(identifier: record.identifier, autoResume: false)
            }
        }
        throw lastError ?? NSError(domain: "DownloadHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败"])
    }

    // 3.8.666（B-1）：取后台会话里全部在途下载任务——接管时用；
    // getTasksWithCompletionHandler 包一层 checked continuation。
    private func czfDownloadTasks(of session: URLSession) async -> [URLSessionDownloadTask] {
        await withCheckedContinuation { (cont: CheckedContinuation<[URLSessionDownloadTask], Never>) in
            session.getTasksWithCompletionHandler { _, _, downloadTasks in
                cont.resume(returning: downloadTasks)
            }
        }
    }

    // 3.8.666（B-1）：后台会话里指定地址的在途下载任务——有就接管，
    // 没有就新建；按 originalRequest.url 认（重定向后仍是原地址）。
    private func czfExistingDownloadTask(for url: URL, in session: URLSession) async -> URLSessionDownloadTask? {
        let tasks = await czfDownloadTasks(of: session)
        return tasks.first { $0.originalRequest?.url == url }
    }

    private func downloadOnce(url: URL, to: URL, resumeData: Data?, czfSessionIdentifier: String? = nil, czfIsFirstAttempt: Bool = true) async throws {
        var ansError: Error? = nil
        // 3.8.666（B-1）：旧会话的完成事件落地后可能刷新续传数据
        //（见下面半秒等待），入参 resumeData 不能直接改，另存一份可变的。
        var czfResumeData = resumeData
        // 本次下载建的会话，结束时要释放（见方法末尾）
        var createdSession: URLSession? = nil
        // 3.8.666（B-1）：会话 identifier 不再每 call 一新 UUID——
        // 旧 identifier（启动/重下找回的记录）复用以便接管在途任务；
        // 全新下载才生成新的，并连同地址/落盘目标记盘（进程被杀后
        // 重开靠它找回）。不敢用全 helper 共用的固定单 identifier：
        // 主 helper 与源页/预取两个一次性 helper 可能同时下载，同
        // identifier 的多会话对象会抢事件（L50-1 同类挂起），每下载
        // 一个 identifier 才隔离；AppDelegate 接管时系统直接给
        // identifier，不用猜。代理开着时 hostDownloadConfiguration
        // 返回 .default 前台配置（identifier 不生效），那路不受后台
        // 会话保护，记录照记、接管时找不到在途任务就走续传重下。
        let czfIdentifier = czfSessionIdentifier ?? "com.livecontainer.download.\(UUID().uuidString)"
        czfCurrentSessionIdentifier = czfIdentifier
        // 3.8.668（B-1）：重试间隙里用户按了暂停——pause() 只改内存，
        // saveRecord(autoResume: true) 会先清掉旧记录（同一地址只留
        // 一份）、暂停意图跟着丢，冷启动又自动续上；建记录前先在主
        // 线程读 paused，暂停中就记 false，堵住重试间隙那路。
        let czfPausedBeforeStart = await MainActor.run { paused }
        CZFDownloadResumeStore.saveRecord(identifier: czfIdentifier, url: url, dest: to, autoResume: !czfPausedBeforeStart)

        await MainActor.run {
            // 3.8.603（O-15）：复位移到 download() 入口，这里不再清——
            // 重试调 downloadOnce 时清掉会把重试间隙点的取消擦除。
            if !batchMode {
                minimized = false
            }

            // 3.8.666（B-2）：清零只在首轮全新下载做——resumeData 或
            // 旧 identifier 任一在就是续传，重试（attempt>0）也不清；
            // 新任务首个进度回调到达前保留上轮 downloadedSize/totalSize。
            // 速度窗口首轮照样重开（续传也重开，只是不动进度/已下量）。
            if czfIsFirstAttempt && resumeData == nil && czfSessionIdentifier == nil {
                downloadProgress = 0.0
                downloadedSize = 0
                totalSize = 0
            }
            // 3.8.664（F2）：新一轮尝试重开速度窗口——样本/速度/ETA
            // 都清掉；paused 不在这里复位（见 download() 入口）。
            downloadSpeed = 0
            downloadETA = nil
            czfSpeedSamples.removeAll()

            isDownloading = true
        }
        
        // 3.8.666（B-1）：会话与 delegate 先建好（delegate 的完成回调
        // 只认 self.continuation，不再捕获 withUnsafeContinuation 的 c，
        // 见下面 completeCallback），再看有没有在途任务要接管。
        let bgConfig = CZFVPNManager.hostDownloadConfiguration(identifier: czfIdentifier)
        let session = URLSession(configuration: bgConfig, delegate: DownloadDelegate(progressCallback: { progress, downloaded, total in
                // 2026-11-24（发热 H-2 宿主代理闲置上限）：下载还在走字节
                // 就是宿主在用核心，刷新闲置计时——长下载超过自动停档位
                // 也不被到点停核打断。回调代理关时也会来，直连下载由
                // noteHostActivity 内部验开关拦下，不记；只是一次 Date 写，
                // 不发 UI 更新。
                CZFVPNManager.shared.noteHostActivity()
                Task{ await MainActor.run {
                    // 3.8.664（F2）：滑动窗口样本——每次回调都记（不过
                    // 节流门，保证窗口准），只留近 2 秒内的；速度与
                    // ETA 的发布仍走下面的节流门（与进度同一节流）。
                    let czfSampleNow = Date()
                    self.czfSpeedSamples.append((date: czfSampleNow, bytes: downloaded))
                    self.czfSpeedSamples.removeAll { czfSampleNow.timeIntervalSince($0.date) > 2 }
                    // 节流：进度回调一秒能来几十次，每次都发布
                    // 会让监听这个对象的整个 App 列表跟着重绘，
                    // 下载中滑动就一卡一卡。进度变化不到 1% 且
                    // 离上次发布不到 0.25 秒的直接跳过，最后一
                    // 下（100%）照常发布
                    let now = Date()
                    if progress < 1,
                       abs(progress - self.downloadProgress) < 0.01,
                       now.timeIntervalSince(self.lastProgressPublish) < 0.25 {
                        return
                    }
                    self.lastProgressPublish = now
                    self.downloadProgress = progress
                    self.downloadedSize = downloaded
                    self.totalSize = total
                    self.downloadSpeed = self.czfCurrentSpeed()
                    self.downloadETA = self.czfCurrentETA()
                }}
            }, completeCallback: {tempFileURL, error in
                Task{ await MainActor.run {
                    self.isDownloading = false
                }}
                if let error {
                    print(error)
                    ansError = error
                    // 失败时系统给了续传数据就留着，下次接着下
                    if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        self.savedResumeData = data
                        self.savedResumeURL = url
                        // 3.8.666（B-1）：续传数据落盘——只靠内存的话
                        // 进程一死即失；重开后 download() 入口按地址捡。
                        CZFDownloadResumeStore.saveResumeData(identifier: czfIdentifier, data: data)
                    }
                    // 3.8.603（O-15）：有错不搬文件——404/403 时 tempFileURL 是
                    // 服务器错误页，搬过去就是错误页冒充的 .ipa；直接删掉临时文件。
                    if let tempFileURL, tempFileURL.standardizedFileURL != to.standardizedFileURL {
                        try? FileManager.default.removeItem(at: tempFileURL)
                    }
                } else {
                    self.savedResumeData = nil
                    self.savedResumeURL = nil
                    // 3.8.666（B-1）：下完了，落盘记录清掉——启动自动续
                    // 不再找回它；接管路的验收也靠记录在不在（见下）。
                    CZFDownloadResumeStore.clearRecord(identifier: czfIdentifier)
                }
                // 3.8.603（O-15）：只有没错时才搬临时文件到目标——
                // 有错时上面已删临时文件，这里不再搬错误页冒充 .ipa。
                if error == nil, let tempFileURL {
                    do {
                        let fm = FileManager.default
                        print(to)
                        // 3.8.601（L135）：落盘先删后挪的换位口子（L132/L133/
                        // L134-3 同款，第六处）——原来目标已存在时先
                        // removeItem 再 moveItem，两步之间被杀/闪退，
                        // 旧文件已删、新文件还留在 URLSession 临时目录
                        // （系统会清掉）。L133 只看了安装路的 tmp
                        // 新名、判“丢的只是刚下的文件”没修；这助手
                        // 是四路共用的，源页下 IPA 到 Documents 时目标
                        // 可能已存在（downloadVersion 先问过覆盖确认），
                        // 丢的是用户已下好的旧包、得重下。旧在就
                        // replaceItemAt 原子换上、不在就 moveItem；
                        // move 路仍留 NSFileWriteFileExistsError 重试
                        // （并发另一路刚搬到位），重试也走 replaceItemAt。
                        // 目标是同名目录（.ipa 名的文件夹）时 replaceItemAt
                        // 直接抛错、旧目录原样不动，比原来先删整目录安全。
                        if tempFileURL.standardizedFileURL != to.standardizedFileURL {
                            if fm.fileExists(atPath: to.path) {
                                _ = try fm.replaceItemAt(to, withItemAt: tempFileURL)
                            } else {
                                do {
                                    try fm.moveItem(at: tempFileURL, to: to)
                                } catch let moveError as NSError where moveError.domain == NSCocoaErrorDomain && moveError.code == NSFileWriteFileExistsError {
                                    // 仍撞上“已存在”：并发另一路刚搬到位。
                                    // 原子换上，不再先删后挪；还不行才把错往上抛。
                                    _ = try fm.replaceItemAt(to, withItemAt: tempFileURL)
                                }
                            }
                        }
                    } catch {
                        ansError = error
                    }
                }
                // 先置 nil 再 resume：cancel() 也会 resume 同一个
                // continuation，下载完成到 isDownloading=false 传播
                // 前取消按钮仍可点，两路各 resume 一次会双 resume 崩溃。
                // 先置 nil，cancel() 看到 nil 就跳过；反过来 cancel()
                // 先跑时这里看到 nil 同样跳过。
                // 3.8.666（B-1）：不捕获 withUnsafeContinuation 的 c——
                // 会话在 withUnsafeContinuation 之前就建好了（接管路要
                // 先拿会话查在途任务），完成时直接认 self.continuation；
                // 接管路里 continuation 是 nil，这里只搬文件、不 resume。
                if let cont = self.continuation {
                    self.continuation = nil
                    cont.resume()
                }

            }), delegateQueue: .main)
            createdSession = session

            // 3.8.666（B-1）：旧会话重建时，守护进程里已跑完的任务的
            // 完成事件会异步吐给新 delegate（搬文件、清记录）；等半秒
            // 让它落地——落地了（记录已清 + 目标已出现）就不用再建任务。
            // 失败事件也可能刚落了新的续传数据，重读盘上的替掉入参，
            // 别拿旧的（或空的）续传数据重下。全新下载（identifier 为
            // nil）不走这段，不加半秒延迟。
            if czfSessionIdentifier != nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if CZFDownloadResumeStore.loadRecord(identifier: czfIdentifier) == nil,
                   FileManager.default.fileExists(atPath: to.path) {
                    await MainActor.run { isDownloading = false }
                    createdSession?.finishTasksAndInvalidate()
                    savedResumeData = nil
                    savedResumeURL = nil
                    return
                }
                if let fresh = CZFDownloadResumeStore.loadResumeData(identifier: czfIdentifier) {
                    czfResumeData = fresh
                }
            }

            // 3.8.666（B-1）：接管路——进程被杀/被系统回收后，后台任务
            // 常在守护进程里继续跑；用旧 identifier 重建会话就能在
            // getTasks 里看见它，直接等它跑完，不新建任务、不从 0 重下。
            // 进度从任务计数里刷（也靠上面 delegate 的进度回调），不依赖
            // delegate 回调落到哪个会话对象上（接管会话与本会话同
            // identifier 时事件只给其中一个对象，轮询不怕抢）。
            // 验收：任务走后等一拍（让 delegate 的搬文件/清记录跑完），
            // 落盘目标出现且 mtime/size 变了（或事先不存在）才算成功——
            // 目标事先已存在时只看“存在”会拿旧文件冒充本次成功；
            // 没落盘就抛错，download() 重试走续传数据。
            if let existing = await czfExistingDownloadTask(for: url, in: session) {
                downloadTask = existing
                // 落盘目标的事先快照——先取再 resume：任务跑得快时
                // delegate 可能在快照前就搬完文件，快照会把新文件
                // 当成“事先已存在”，验收认不出成功、白白重下一遍。
                let czfDestAttrsBefore = try? FileManager.default.attributesOfItem(atPath: to.path)
                let czfDestExistedBefore = czfDestAttrsBefore != nil
                let czfDestMtimeBefore = (czfDestAttrsBefore?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let czfDestSizeBefore = (czfDestAttrsBefore?[.size] as? NSNumber)?.int64Value ?? 0
                existing.resume()
                while true {
                    if await MainActor.run(body: { cancelled }) { break }
                    // 3.8.670（B-1）：暂停中跳过 getTasks 与进度发布、只睡
                    // 5 秒再查——挂起的任务仍留在 getTasks 列表里，旧循环
                    // 每 0.5 秒空转耗电；resume() 已会 downloadTask?.resume()，
                    // 恢复后轮询自动回 0.5 秒节奏。不要改成暂停即 break
                    // 走重试：那会丢掉被接管任务已下的字节（无 resumeData，
                    // 重试从 0 下），比空转更差。
                    if await MainActor.run(body: { paused }) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                    let tasks = await czfDownloadTasks(of: session)
                    guard let task = tasks.first(where: { $0.originalRequest?.url == url }) else { break }
                    await MainActor.run {
                        downloadedSize = task.countOfBytesReceived
                        if task.countOfBytesExpectedToReceive > 0 {
                            totalSize = task.countOfBytesExpectedToReceive
                            downloadProgress = Float(task.countOfBytesReceived) / Float(task.countOfBytesExpectedToReceive)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let czfDestAttrsAfter = try? FileManager.default.attributesOfItem(atPath: to.path)
                var czfAdoptSucceeded = false
                if let after = czfDestAttrsAfter {
                    let mtime = (after[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let size = (after[.size] as? NSNumber)?.int64Value ?? 0
                    czfAdoptSucceeded = !czfDestExistedBefore || mtime != czfDestMtimeBefore || size != czfDestSizeBefore
                }
                await MainActor.run { isDownloading = false }
                createdSession?.finishTasksAndInvalidate()
                if czfAdoptSucceeded {
                    savedResumeData = nil
                    savedResumeURL = nil
                    CZFDownloadResumeStore.clearRecord(identifier: czfIdentifier)
                    return
                }
                throw ansError ?? NSError(domain: "DownloadHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载中断，正在断点续传"])
            }

            await withUnsafeContinuation { c in
                continuation = c
                if let czfData = czfResumeData {
                    downloadTask = session.downloadTask(withResumeData: czfData)
                } else {
                    downloadTask = session.downloadTask(with: url)
                }
                downloadTask?.resume()
                // 3.8.664（F2）：重试间隙里用户按了暂停时没有在途任务、
                // pause() 只置了标志；新任务建好按标志立即挂起，不让
                // 重试悄悄跑起来（paused 在 download() 入口才复位）。
                if paused { downloadTask?.suspend() }
                // 2026-11-24（发热 H-2 宿主代理闲置上限）：下载会话建好、
                // 任务开始跑就是一次宿主活动（首字节未到也算一次）；
                // 进行中由上面进度回调续记，停在 0 字节的下载也至少
                // 得一个档位的宽限，不会被待停在起步一分钟内打断。
                CZFVPNManager.shared.noteHostActivity()
            }
        // 会话用完释放：以前每次下载（重试、预取都会叠加）都新
        // 建一个后台会话且从不 invalidate，只增不减地挂在系统
        // 里。任务已结束/失败/取消走到这里，收尾释放正合适
        createdSession?.finishTasksAndInvalidate()
        if let ansError {
            throw ansError
        }
    }
    
    // 3.8.664（F2）：滑动窗口速度——近 2 秒样本首尾增量 ÷ 时间跨度；
    // 样本不足 2 个或跨度过小时返回 0，不拿上次速度冒充。
    private func czfCurrentSpeed() -> Int64 {
        guard czfSpeedSamples.count >= 2,
              let first = czfSpeedSamples.first,
              let last = czfSpeedSamples.last else { return 0 }
        let span = last.date.timeIntervalSince(first.date)
        guard span > 0.05 else { return 0 }
        return Int64(Double(last.bytes - first.bytes) / span)
    }

    // 3.8.664（F2）：剩余时间——剩余字节 ÷ 速度；总长度未知或速度
    // 为 0 时返回 nil（界面只显速度、不显 ETA）。
    private func czfCurrentETA() -> TimeInterval? {
        guard totalSize > 0, downloadSpeed > 0 else { return nil }
        let remaining = totalSize - downloadedSize
        guard remaining > 0 else { return nil }
        return TimeInterval(remaining) / TimeInterval(downloadSpeed)
    }

    // 3.8.664（F2）：暂停/继续——suspend/resume，不走 cancel 路，
    // 不断开、不丢 resumeData；暂停不改 minimized，batchMode 下
    // 暂停不重弹弹窗。重试间隙里没有在途任务时只置标志，新任务
    // 建好后按标志立即挂起（见 downloadOnce 末尾）。
    // 3.8.668（B-1）：暂停意图要落盘——paused 只在内存里，杀掉重开
    // 后冷启动自动续只认记录（autoResume=true）；pause() 在此把
    // 当前会话记录改成 false（cancel() 同款写法），resume() 改回
    // true；记录不在时 updateAutoResume 直接返回，不报错。
    func pause() {
        paused = true
        downloadTask?.suspend()
        if let id = czfCurrentSessionIdentifier {
            CZFDownloadResumeStore.updateAutoResume(identifier: id, autoResume: false)
        }
    }

    func resume() {
        paused = false
        downloadTask?.resume()
        if let id = czfCurrentSessionIdentifier {
            CZFDownloadResumeStore.updateAutoResume(identifier: id, autoResume: true)
        }
    }

    func cancel() {
        if let continuation {
            continuation.resume()
        }
        cancelled = true
        continuation = nil
        // 带续传数据的取消：系统把下好的部分留成续传数据，
        // 下次下同一个地址接着下，不用从 0 开始
        // 3.8.666（B-1）：续传数据也落盘（只靠内存的话进程一死
        // 即失）；取消的记 autoResume=false——启动不自动续，
        // 只在用户手动重下同一地址时由 download() 捡起来。
        let czfCancelIdentifier = czfCurrentSessionIdentifier
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data else {
                return
            }
            self.savedResumeData = data
            self.savedResumeURL = self.currentURL
            if let id = czfCancelIdentifier {
                CZFDownloadResumeStore.saveResumeData(identifier: id, data: data)
                CZFDownloadResumeStore.updateAutoResume(identifier: id, autoResume: false)
            }
        })
        isDownloading = false
    }

    // 3.8.666（B-1）：启动自动续——冷启动时 LCTabView .task 调一次，
    // 把上次被杀/失败后留下的可自动续记录（autoResume=true，用户
    // 主动取消的不在内）逐个续上下去；记录里的落盘目标父目录
    // 可能已被系统清掉（tmp），先建出来；正在下载时不插队。
    // 每冷启动只试一次（静态旗），失败/抛错就跳过本条、续下一条，
    // 不拦启动。
    func czfAutoResumeInterruptedIfNeeded() async {
        guard !Self.czfAutoResumeAttempted else { return }
        Self.czfAutoResumeAttempted = true
        // 后台唤起接管中的记录不碰——接管会话正跑着它，跑完由
        // 接管 delegate 搬文件；这里再建同 identifier 会话会
        // 抢事件（见 AppDelegate czfBackgroundTakeoverIdentifiers）。
        let czfTakeoverIDs = AppDelegate.czfBackgroundTakeoverIdentifiers
        for record in CZFDownloadResumeStore.pendingAutoResumeRecords() {
            guard !czfTakeoverIDs.contains(record.identifier) else { continue }
            guard let url = URL(string: record.urlString) else { continue }
            let dest = URL(fileURLWithPath: record.destPath)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if await MainActor.run(body: { isDownloading }) { return }
            // 3.8.670（F-1）：自动续传完成也推一条通知——冷启动续完
            // 文件静默落盘，用户无从得知；失败/取消不推（只成功推）。
            do {
                try await download(url: url, to: dest)
                czfNotifyDownloadDone(fileName: dest.lastPathComponent)
            } catch {
                // 失败就跳过本条、续下一条（原 try? 行为），不推通知。
            }
        }
    }
}

// 3.8.666（B-1）：后台唤起时的会话接管 delegate——进程被杀后
// 系统以后台事件唤起 App，AppDelegate 用事件给的 identifier
// 重建会话；本 delegate 只做收尾：下完把临时文件搬到记录里的
// 落盘目标、失败留续传数据、事件交完调 completionHandler。
// 与 DownloadDelegate 分开：接管时没有在途的 download() 调用
// 可回调，收尾只走磁盘记录。session 与本对象由 AppDelegate
// 强持有，事件交完（urlSessionDidFinishEvents）后由
// czfOnFinished 回调释放。
final class CZFBackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let identifier: String
    private let completionHandler: () -> Void
    var czfOnFinished: ((String) -> Void)?

    init(identifier: String, completionHandler: @escaping () -> Void) {
        self.identifier = identifier
        self.completionHandler = completionHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let record = CZFDownloadResumeStore.loadRecord(identifier: identifier) else { return }
        let dest = URL(fileURLWithPath: record.destPath)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: location)
            } else {
                try fm.moveItem(at: location, to: dest)
            }
            CZFDownloadResumeStore.clearRecord(identifier: identifier)
            // 3.8.670（F-1）：后台接管完成也推一条通知——进程被杀后
            // 系统唤起 App 搬完文件即止，用户无从得知。
            czfNotifyDownloadDone(fileName: dest.lastPathComponent)
        } catch {
            print("CZFBackgroundDownloadDelegate move failed: \(error)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error,
           let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            CZFDownloadResumeStore.saveResumeData(identifier: identifier, data: data)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionHandler()
        czfOnFinished?(identifier)
    }
}

// 3.8.670（F-1）：下载完成本地通知——源页下载 / 自动续传 / 后台
// 接管三路共用；照抄 LCAppListView.notifyBatchDone 的按需申请
// 写法（未授权时静默跳过、不重复弹授权框）；identifier 用
// CZFDownloadDone- 前缀，不走 CZFBatchInstall 静默分支，前台
// 也弹横幅 + 响铃（见 AppDelegate CZFNotificationDelegate）。
// 安装路不调：装完紧接着就是安装 UI + 批量通知，加了是噪音。
// 标题/正文复用源页三选框现成文案，0 新 key。
func czfNotifyDownloadDone(fileName: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "下载完成"
        content.body = "\(fileName) 已下载完成"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "CZFDownloadDone-\(UUID().uuidString)", content: content, trigger: nil))
    }
}

// 3.8.664（F2）：速度 + 剩余时间文案——弹窗与收起胶囊共用；
// 总长度未知（eta 为 nil）时只显速度、不显 ETA；速度为 0 时
// 显 "0 KB/s"（ByteCountFormatter 的 0 是 "Zero KB"，别直接用它）。
// 文案硬编码中文（本文件“已下载 …”同款先例），不新增 L() key。
fileprivate func czfDownloadSpeedText(speed: Int64, eta: TimeInterval?) -> String {
    let speedText = speed > 0 ? "\(formatBytes(speed))/s" : "0 KB/s"
    guard let eta, eta > 0 else { return speedText }
    if eta < 60 {
        return "\(speedText) · 还剩约 \(Int(eta)) 秒"
    }
    if eta < 3600 {
        return "\(speedText) · 还剩约 \(Int(eta / 60)) 分钟"
    }
    return "\(speedText) · 还剩约 \(Int(eta / 3600)) 小时 \(Int(eta.truncatingRemainder(dividingBy: 3600) / 60)) 分钟"
}

// 3.8.672（F-1）：排队显示名——安装路落盘名带 "<UUID>-" 前缀
//（LCAppListView 每次安装一段 UUID），显示时去掉，只留原文件名；
// 源页下载本来就没有前缀，原样显示。
fileprivate func czfDisplayDownloadName(_ url: URL) -> String {
    let name = url.lastPathComponent
    guard name.count > 37 else { return name }
    let prefix = String(name.prefix(36))
    guard name[name.index(name.startIndex, offsetBy: 36)] == "-",
          UUID(uuidString: prefix) != nil else { return name }
    return String(name.dropFirst(37))
}

// 3.8.672（F-1）：排队行文案——弹窗与收起胶囊共用；在途那路
// 的文件名 + 首个排队项的位置（第 1 位）+ 还有几路在排；
// 只有一路在排时不写“共 N 个”。
fileprivate func czfDownloadQueueText(currentName: String?, queued: [String]) -> String {
    guard let first = queued.first else { return "" }
    let head = currentName.map { "\($0) · " } ?? ""
    let tail = queued.count > 1 ? "（+\(queued.count - 1)）" : ""
    return "\(head)\("lc.download.queued".loc)：\("lc.download.queuePosition".localizeWithFormat(1)) \(first)\(tail)"
}

// 下载量格式化：弹窗与收起胶囊共用（原来是 DownloadAlert 的
// 私有方法，胶囊在另一个 View 里用不上，提到文件级）。
fileprivate func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB] // Allow KB, MB, and GB
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

struct DownloadAlert : View {
    @StateObject var helper : DownloadHelper
    var body: some View {
        
        Color.black.opacity(0.2) // Semi-transparent grey background
            .edgesIgnoringSafeArea(.all) // Covers entire screen
        
        VStack {
            // 3.8.664（F2/UI 打磨）：暂停时标题改“已暂停”，不再顶着
            // “下载中”（进度条已冻住，标题还说在下是错文案）。
            Text(helper.paused ? "已暂停" : "lc.download.downloading".loc)
                .font(.headline)
                .padding(.top)
            
            // 总长度未知（服务器不发长度）时不用定值进度条，
            // 也不显示“-1”总大小：进度条改不确定样式，只显已下载量。
            if helper.totalSize > 0 {
                ProgressView(value: helper.downloadProgress, total: 1)
                    .padding()
            } else {
                ProgressView()
                    .padding()
            }
            
            if helper.totalSize > 0 {
                Text("\(formatBytes(helper.downloadedSize)) / \(formatBytes(helper.totalSize))")
                    .font(.subheadline)
                    .padding(.bottom)
            } else {
                Text("已下载 \(formatBytes(helper.downloadedSize))")
                    .font(.subheadline)
                    .padding(.bottom)
            }

            // 3.8.664（F2）：速度 + 剩余时间行——总长度未知时只显速度、
            // 不显 ETA（见 czfDownloadSpeedText）；与进度同一节流发布，
            // 不另起刷新。3.8.670（UI 打磨）：单行 + 缩放防截断，
            // 窄屏下“还剩约 X 小时 Y 分钟”不断尾，纯样式。
            Text(czfDownloadSpeedText(speed: helper.downloadSpeed, eta: helper.downloadETA))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            // 3.8.672（F-1）：排队行——有路在等锁时才出现；在途那路
            // 的文件名 + 首个排队项的位置；helper 是 @StateObject，
            // 排队名册一变这里就重画。
            if !helper.czfQueuedDownloads.isEmpty {
                Text(czfDownloadQueueText(currentName: helper.czfCurrentDownloadName, queued: helper.czfQueuedDownloads))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
            }

            // 按钮与收起态胶囊、全 App 的胶囊按钮同一套语言：
            // 以前是纯文字钮，混在材质卡上像没做完
            HStack(spacing: 12) {
                Button(action: { helper.minimized = true }) {
                    Text("隐藏")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundColor(.accentColor)
                }
                // 3.8.664（F2）：暂停/继续——suspend/resume，不走
                // cancel 路，不断开、不丢 resumeData。
                Button(action: { helper.paused ? helper.resume() : helper.pause() }) {
                    Text(helper.paused ? "lc.download.resume".loc : "lc.download.pause".loc)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundColor(.accentColor)
                }
                Button(action: cancelDownload) {
                    Text("lc.common.cancel".loc)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.12), in: Capsule())
                        .foregroundColor(.red)
                }
            }
            .padding(.bottom)
        }
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 8)
        .padding()
    }
    
    
    func cancelDownload() {
        helper.cancel()
    }
}

public struct DownloadAlertModifier: ViewModifier {
    @ObservedObject var helper : DownloadHelper
    @State var show = false
    
    public func body(content: Content) -> some View {

        ZStack {
            content
            if show && !helper.minimized {
                DownloadAlert(helper: helper)
            }
            if show && helper.minimized {
                // 收起后的小悬浮钮：只占右下角一小块，不挡界面
                // 操作；显示进度，点一下把下载弹窗调回来
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        // 3.8.664（F2）：收起胶囊下方补速度行 + 暂停/继续——
                        // 与弹窗内同一套文案/同一节流；暂停不改 minimized，
                        // batchMode 下暂停不重弹弹窗。
                        VStack(spacing: 6) {
                            Button {
                                helper.minimized = false
                            } label: {
                                HStack(spacing: 6) {
                                    // 总长度未知时不显示百分比，只显已下载量。
                                    if helper.totalSize > 0 {
                                        ProgressView(value: helper.downloadProgress, total: 1)
                                            .progressViewStyle(.circular)
                                        Text(helper.paused ? "已暂停 \(Int(helper.downloadProgress * 100))%" : "下载中 \(Int(helper.downloadProgress * 100))%")
                                            .font(.caption.bold())
                                    } else {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                        Text(helper.paused ? "已暂停 \(formatBytes(helper.downloadedSize))" : "下载中 \(formatBytes(helper.downloadedSize))")
                                            .font(.caption.bold())
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .shadow(radius: 4)
                            }
                            HStack(spacing: 8) {
                                Text(czfDownloadSpeedText(speed: helper.downloadSpeed, eta: helper.downloadETA))
                                    .font(.caption)
                                Button {
                                    helper.paused ? helper.resume() : helper.pause()
                                } label: {
                                    Text(helper.paused ? "lc.download.resume".loc : "lc.download.pause".loc)
                                        .font(.caption.bold())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(radius: 4)
                            // 3.8.672（F-1）：收起胶囊里的排队行——与弹窗内同一份文案；
                            // 只在有路排队时出现。
                            if !helper.czfQueuedDownloads.isEmpty {
                                Text(czfDownloadQueueText(currentName: helper.czfCurrentDownloadName, queued: helper.czfQueuedDownloads))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .shadow(radius: 4)
                            }
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 100)
                    }
                }
            }

        }
        .onChange(of: helper.isDownloading) { newVal in
            withAnimation(.easeInOut(duration: 0.1)) {
                // 3.8.672（F-1）：在途那路刚完、下一路还没拿到锁
                // 的瞬间 isDownloading 先翻 false（completeCallback
                // 清的），排队名册还非空——弹窗不闪断，等下一路
                // 拿到锁接上；名册空了才真正收起。
                show = newVal || !helper.czfQueuedDownloads.isEmpty
            }
        }
    }
}

class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressCallback: (Float, Int64, Int64) -> Void
    let completeCallback: (URL?, Error?) -> Void

    init(progressCallback: @escaping (Float, Int64, Int64) -> Void,
         completeCallback: @escaping (URL?, Error?) -> Void) {
        self.progressCallback = progressCallback
        self.completeCallback = completeCallback
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // 服务器不发长度时 totalBytesExpectedToWrite 是 -1
        // （NSURLSessionTransferSizeUnknown），直接除会得到负
        // 进度，界面就显示负百分比和“-1”总大小；未知长度传
        // -1 作标记，界面按 totalSize <= 0 走未知长度分支。
        let progress: Float
        if totalBytesExpectedToWrite > 0 {
            progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        } else {
            progress = -1
        }
        progressCallback(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode

            // Check if the status code is in the 2xx range
            if (200...299).contains(statusCode) {
                completeCallback(location, nil)
            } else {
                // 报错说人话并分清原因：以前一律英文 "HTTP Error:
                // 404"，链接死了都看不出来
                let message: String
                switch statusCode {
                case 404:
                    message = "下载链接已失效（服务器返回 404）"
                case 403:
                    message = "服务器拒绝下载（403），链接可能已过期或需要登录"
                default:
                    message = "下载失败，服务器返回 \(statusCode)"
                }
                completeCallback(location, NSError(domain: "", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        } else {
            completeCallback(location, NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败：服务器没有返回有效文件"]))
        }
        

    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completeCallback(nil, error)
        } else {

        }
    }
}

extension View {
    public func downloadAlert(helper: DownloadHelper) -> some View {
        self.modifier(DownloadAlertModifier(helper: helper))
    }
}
