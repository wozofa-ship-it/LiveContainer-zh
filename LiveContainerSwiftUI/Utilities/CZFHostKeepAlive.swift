// CZFHostKeepAlive.swift
// 宿主侧无声音频保活：宿主切后台时若有游客在跑，让宿主自己播一段静音，
// 宿主进程保持运行，游客所在的 LiveProcess Extension 才不被系统回收。
// 与游客侧 CZFKeepAlive.dylib 同一套配方（8kHz 单声道静音循环 + 30 秒看门狗），
// 但跑在宿主进程里：覆盖所有游客（含 dontInject、没挂保活夹的），不依赖游客侧插件。
// 开关与游客侧保活共用 LCKeepAliveEnabled（设置页“保活（无声音频）”，默认开）。
// 只在“开关开 + 有游客在跑 + 宿主已切后台”三者同时满足时播放；
// 宿主回前台、最后一个游客退出、开关关闭时立即停，不额外耗电。
// 注意：游客计数取 MultitaskDockManager.shared.apps（虚拟窗口模式，默认开）；
// 原生窗口模式下 dock 未启用、计数恒为 0，宿主保活不启动（与 dock 本身同限）。

import AVFoundation
import UIKit

final class CZFHostKeepAlive {
    static let shared = CZFHostKeepAlive()

    private var player: AVAudioPlayer?
    private var watchdog: Timer?
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
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            self.refresh()
        }
    }

    /// 开关/游客数/前后台任一变化时调：重算该不该播（主队列）。
    func refresh() {
        let enabled = UserDefaults.standard.object(forKey: "LCKeepAliveEnabled") as? Bool ?? true
        var guestsRunning = false
        if #available(iOS 16.0, *) {
            guestsRunning = !MultitaskDockManager.shared.apps.isEmpty
        }
        if enabled && guestsRunning && isBackgrounded {
            start()
        } else {
            stop()
        }
    }

    private func start() {
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
