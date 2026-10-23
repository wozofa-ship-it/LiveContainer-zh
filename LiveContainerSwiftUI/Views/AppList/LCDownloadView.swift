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

    func download(url: URL, to: URL) async throws {
        currentURL = url
        // 失败自动重试：最多 3 次（首次 + 2 次重试），网络抖
        // 一下不用用户再点一次。每次优先用上次留下的续传数
        // 据接着下（completeCallback 失败时已存好），不从 0
        // 开始；用户主动取消立即停、不重试
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            do {
                if let data = savedResumeData, savedResumeURL == url {
                    savedResumeData = nil
                    savedResumeURL = nil
                    try await downloadOnce(url: url, to: to, resumeData: data)
                } else {
                    try await downloadOnce(url: url, to: to, resumeData: nil)
                }
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
            cancelled = false
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
                } else {
                    self.savedResumeData = nil
                    self.savedResumeURL = nil
                }
                if let tempFileURL {
                    do {
                        let fm = FileManager.default
                        print(to)
                        // 目标有同名残留时 moveItem 直接报"已存在
                        // 同名项目"、下载白下完（真机实测：上次
                        // 安装没清干净的 tmp 文件、或重试时上一
                        // 轮已搬到位的文件都会撞上）：搬之前先清
                        if tempFileURL.standardizedFileURL != to.standardizedFileURL,
                           fm.fileExists(atPath: to.path) {
                            try? fm.removeItem(at: to)
                        }
                        try fm.moveItem(at: tempFileURL, to: to)
                    } catch {
                        ansError = error
                    }
                }
                if self.continuation != nil {
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

struct DownloadAlert : View {
    @StateObject var helper : DownloadHelper
    var body: some View {
        
        Color.black.opacity(0.2) // Semi-transparent grey background
            .edgesIgnoringSafeArea(.all) // Covers entire screen
        
        VStack {
            Text("lc.download.downloading".loc)
                .font(.headline)
                .padding(.top)
            
            ProgressView(value: helper.downloadProgress, total: 1)
                .padding()
            
            Text("\(formatBytes(helper.downloadedSize)) / \(formatBytes(helper.totalSize))")
                .font(.subheadline)
                .padding(.bottom)

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
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB] // Allow KB, MB, and GB
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
                                ProgressView(value: helper.downloadProgress, total: 1)
                                    .progressViewStyle(.circular)
                                Text("下载中 \(Int(helper.downloadProgress * 100))%")
                                    .font(.caption.bold())
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
        let progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
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
