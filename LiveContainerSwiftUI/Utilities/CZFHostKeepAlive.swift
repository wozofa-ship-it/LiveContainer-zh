// CZFHostKeepAlive.swift
// 宿主侧无声音频保活：宿主切后台时若有游客在跑，让宿主自己播一段静音，
// 宿主进程保持运行，游客所在的 LiveProcess Extension 才不被系统回收。
// 与游客侧 CZFKeepAlive.dylib 同一套配方（8kHz 单声道静音循环 + 30 秒看门狗），
// 但跑在宿主进程里：覆盖所有游客（含 dontInject、没挂保活夹的），不依赖游客侧插件。
// 开关与游客侧保活共用 LCKeepAliveEnabled（设置页“保活（无声音频）”，默认开）。
// 只在“开关开 + 有游客在跑 + 宿主已切后台”三者同时满足时播放；
// 宿主回前台、最后一个游客退出、开关关闭时立即停，不额外耗电。
// 宿主保活按白名单（CZF）：与游客侧共用 CZFKeepAliveApps.txt，文件不存在
// = 全保，文件存在 = 只有名单里的游客才触发宿主保活。宿主音频是整进程
// 一份、没法按 App 切分，所以只要有一个在跑游客在名单里，宿主照常保；
// 只有在跑游客全都不在名单里时，宿主才停。原生模式下 dock 无记录、
// 场景无法对应 bid，维持旧行为全保，避免误停。
// v1.1 优化（防 1 分钟内被掐）：①提前启动 —— WillResignActive 就先播，
// 切后台时音频会话已经是激活态，不留“先被掐、后才开始播”的空档；
// ②游客计数补原生模式 —— 虚拟模式数 dock，原生模式数系统已连接的场景
// （主场景 + 游客场景 > 1 即有游客），原来只数 dock 时原生模式下计数恒为 0、
// 宿主保活从不启动；③后台任务第二通道 —— 音频被打断时，后台任务先顶住，
// 过期时重开音频并续一个新任务，音频单通道断了不再直接等于被掐。

import AVFoundation
import UIKit

final class CZFHostKeepAlive {
    static let shared = CZFHostKeepAlive()

    private var player: AVAudioPlayer?
    private var watchdog: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isBackgrounded = false
    private var installed = false

    private init() {}

    /// App 启动时调一次：装后台/前台/音频中断观察者（主队列）。
    func install() {
        guard !installed else { return }
        installed = true
        isBackgrounded = UIApplication.shared.applicationState == .background
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isBackgrounded = true
            self?.refresh()
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isBackgrounded = false
            self?.refresh()
        }
        // 提前启动：上滑切 App 时 WillResignActive 先于 DidEnterBackground，
        // 这里就先播，切后台时音频会话已经是激活态。
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isBackgrounded = true
            self?.refresh()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isBackgrounded = false
            self?.refresh()
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            self.refresh()
        }
    }

    /// 白名单读法与 LCAppSettingsView.readKeepAliveList 同款：先读
    /// tweakPath，读到即算；两夹文件都不存在 = 全保。空文件读出空名单，
    /// 不是“不存在”，这时名单外的游客一律不保。
    private static func keepAliveNeeded(for bid: String) -> Bool {
        for url in [LCPath.tweakPath, LCPath.lcGroupTweakPath].map({ $0.appendingPathComponent("CZFKeepAliveApps.txt") }) {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let list = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return list.contains(bid)
            }
        }
        return true
    }

    /// 开关/游客数/前后台/白名单任一变化时调：重算该不该播（主队列）。
    func refresh() {
        let enabled = UserDefaults.standard.object(forKey: "LCKeepAliveEnabled") as? Bool ?? true
        var guestsNeedKeepAlive = false
        if #available(iOS 16.0, *) {
            let dockApps = MultitaskDockManager.shared.apps
            if !dockApps.isEmpty {
                // 虚拟模式：按 dock 记录逐个对白名单，bid 未知时保守全保，
                // 避免把拿不到 bid 的游客误停。注意不能在这里再 fallback
                // 到 scenes：dock 有记录却全被排除时，scenes 仍可能 > 1，
                // fallback 会把白名单排除又拉回全保。
                guestsNeedKeepAlive = dockApps.contains { app in
                    guard let bid = app.appInfo?.bundleIdentifier(), !bid.isEmpty else { return true }
                    return Self.keepAliveNeeded(for: bid)
                }
            } else {
                // 原生模式下 dock 不启用：游客是系统场景，主场景之外多一个
                // 即有游客。connectedScenes 由系统维护、场景断开即掉，
                // 比只加不删的窗口字典可靠；但场景无法对应 bid，只能全保。
                guestsNeedKeepAlive = UIApplication.shared.connectedScenes.count > 1
            }
        } else {
            guestsNeedKeepAlive = UIApplication.shared.connectedScenes.count > 1
        }
        if enabled && guestsNeedKeepAlive && isBackgrounded {
            start()
        } else {
            stop()
        }
    }

    /// 后台任务第二通道：音频被打断时先顶住，过期时重开音频并续一个新任务。
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
            if self.isBackgrounded { self.start() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func start() {
        beginBackgroundTask()
        if let player = player, player.isPlaying { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(data: CZFHostKeepAlive.silentWAVData())
                player?.numberOfLoops = -1
                player?.volume = 0.0
                player?.prepareToPlay()
            }
            player?.play()
        } catch {
            // 宿主保活绝不能拖垮宿主：起不来就安静失败，游客侧保活仍在。
            return
        }
        if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.isBackgrounded && !(self.player?.isPlaying ?? false) {
                    self.start()
                }
            }
            watchdog?.tolerance = 10.0
        }
    }

    private func stop() {
        watchdog?.invalidate()
        watchdog = nil
        player?.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBackgroundTask()
    }

    /// 1 秒静音 WAV（8000Hz 单声道 16bit PCM），与游客侧 CZFKeepAlive.m 同配方。
    private static func silentWAVData() -> Data {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let chunkSize = 36 + dataSize
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        var data = Data()
        func append<T>(_ value: T) {
            var v = value
            data.append(Data(bytes: &v, count: MemoryLayout<T>.size))
        }
        data.append("RIFF".data(using: .ascii)!)
        append(chunkSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        data.append("data".data(using: .ascii)!)
        append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
