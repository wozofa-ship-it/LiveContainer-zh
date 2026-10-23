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
    
    func download(url: URL, to: URL) async throws {
        var ansError: Error? = nil

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
                }
                if let tempFileURL {
                    do {
                        let fm = FileManager.default
                        print(to)
                        try fm.moveItem(at: tempFileURL, to: to)
                    } catch {
                        ansError = error
                    }
                }
                if self.continuation != nil {
                    c.resume()
                }

            }), delegateQueue: .main)

            downloadTask = session.downloadTask(with: url)
            downloadTask?.resume()
        }
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
        downloadTask?.cancel()
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

            HStack(spacing: 48) {
                Button(action: { helper.minimized = true }) {
                    Text("隐藏")
                        .foregroundColor(.accentColor)
                }
                Button(action: cancelDownload) {
                    Text("lc.common.cancel".loc)
                        .foregroundColor(.red)
                }
            }
            .padding(.bottom)
        }
        .frame(width: 300)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .shadow(radius: 10)
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
                completeCallback(location, NSError(domain: "", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error: \(statusCode)"]))
            }
        } else {
            completeCallback(location, NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
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
