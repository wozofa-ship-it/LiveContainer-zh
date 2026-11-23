//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import SwiftUI

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

    // 3.8.900（L564-3）czfCancelRequested：调用方传的取消检查闭包——下载在途期间
    // 每 0.5 秒读一次，读到真就停掉本次下载；不传（nil）时不轮询，原样。
    func download(url: URL, to: URL, czfCancelRequested: (() async -> Bool)? = nil) async throws {
        // 3.8.572（L339-1）：L50-1 的查与置是两次 MainActor.run、中间隔一次 await——都在主线程跑不等于原子：两路同时等时都能读到空闲、都置真并行下，单槽 continuation/downloadTask 被盖掉，后完成那路见 continuation 已空、永远不恢复（L50-1 原文说的挂起，安装队停摆、只能杀 App）。
        // 触发口子是现成的：重试 2 秒间隙里 isDownloading 已是 false（completeCallback 清的）、标志仍占着，源页守门 S:1834 只认 isDownloading、覆盖确认 S:1262 根本没门，两路都能进轮询等；安装队尾那路同款。查与置必须同一次 MainActor.run 内原子完成；defer 里不能 await，清标志仍放主线程 Task。
        while true {
            let acquired = await MainActor.run {
                if czfDownloadInFlight { return false }
                czfDownloadInFlight = true
                return true
            }
            if acquired { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        defer {
            Task { @MainActor in czfDownloadInFlight = false }
        }
        currentURL = url
        // 3.8.603（O-15）：cancelled 只在用户主动发起新下载时复位——
        // 原来 downloadOnce 入口无条件清掉，重试间隙点的取消在
        // 下一轮开始时被擦除（重试循环的查取消跑在它前面，窗口虽小
        // 仍是真口子）；移到 download() 入口、拿了在途锁之后清，
        // 重试不再碰它。
        await MainActor.run { cancelled = false }
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
                if let data = savedResumeData, savedResumeURL == url {
                    savedResumeData = nil
                    savedResumeURL = nil
                    try await downloadOnce(url: url, to: to, resumeData: data)
                } else {
                    try await downloadOnce(url: url, to: to, resumeData: nil)
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
        throw lastError ?? NSError(domain: "DownloadHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败"])
    }

    private func downloadOnce(url: URL, to: URL, resumeData: Data?) async throws {
        var ansError: Error? = nil
        // 本次下载建的会话，结束时要释放（见方法末尾）
        var createdSession: URLSession? = nil

        await MainActor.run {
            // 3.8.603（O-15）：复位移到 download() 入口，这里不再清——
            // 重试调 downloadOnce 时清掉会把重试间隙点的取消擦除。
            if !batchMode {
                minimized = false
            }

            downloadProgress = 0.0
            downloadedSize = 0
            totalSize = 0

            isDownloading = true
        }
        
        await withUnsafeContinuation { c in
            continuation = c
            
            let bgConfig = CZFVPNManager.hostDownloadConfiguration(identifier: "com.livecontainer.download.\(UUID().uuidString)")
            let session = URLSession(configuration: bgConfig, delegate: DownloadDelegate(progressCallback: { progress, downloaded, total in
                // 2026-11-24（发热 H-2 宿主代理闲置上限）：下载还在走字节
                // 就是宿主在用核心，刷新闲置计时——长下载超过自动停档位
                // 也不被到点停核打断。回调代理关时也会来，直连下载由
                // noteHostActivity 内部验开关拦下，不记；只是一次 Date 写，
                // 不发 UI 更新。
                CZFVPNManager.shared.noteHostActivity()
                Task{ await MainActor.run {
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
                    }
                    // 3.8.603（O-15）：有错不搬文件——404/403 时 tempFileURL 是
                    // 服务器错误页，搬过去就是错误页冒充的 .ipa；直接删掉临时文件。
                    if let tempFileURL, tempFileURL.standardizedFileURL != to.standardizedFileURL {
                        try? FileManager.default.removeItem(at: tempFileURL)
                    }
                } else {
                    self.savedResumeData = nil
                    self.savedResumeURL = nil
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
                if self.continuation != nil {
                    self.continuation = nil
                    c.resume()
                }

            }), delegateQueue: .main)
            createdSession = session

            if let resumeData {
                downloadTask = session.downloadTask(withResumeData: resumeData)
            } else {
                downloadTask = session.downloadTask(with: url)
            }
            downloadTask?.resume()
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
    
    func cancel() {
        if let continuation {
            continuation.resume()
        }
        cancelled = true
        continuation = nil
        // 带续传数据的取消：系统把下好的部分留成续传数据，
        // 下次下同一个地址接着下，不用从 0 开始
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data else {
                return
            }
            self.savedResumeData = data
            self.savedResumeURL = self.currentURL
        })
        isDownloading = false
    }
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
            Text("lc.download.downloading".loc)
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
                        Button {
                            helper.minimized = false
                        } label: {
                            HStack(spacing: 6) {
                                // 总长度未知时不显示百分比，只显已下载量。
                                if helper.totalSize > 0 {
                                    ProgressView(value: helper.downloadProgress, total: 1)
                                        .progressViewStyle(.circular)
                                    Text("下载中 \(Int(helper.downloadProgress * 100))%")
                                        .font(.caption.bold())
                                } else {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                    Text("下载中 \(formatBytes(helper.downloadedSize))")
                                        .font(.caption.bold())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(radius: 4)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 100)
                    }
                }
            }

        }
        .onChange(of: helper.isDownloading) { newVal in
            withAnimation(.easeInOut(duration: 0.1)) {
                show = newVal
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
