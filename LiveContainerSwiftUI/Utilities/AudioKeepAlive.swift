import AVFoundation
import UIKit

// 音频保活：后台播放无声音频，防止 iOS 杀进程
// 用户手动开关，默认关闭
class AudioKeepAlive {
    static let shared = AudioKeepAlive()
    
    private var audioPlayer: AVAudioPlayer?
    private var isRunning = false
    
    private init() {}
    
    func start() {
        guard !isRunning else { return }
        
        do {
            // 设置音频会话为后台播放
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            
            // 生成 1 秒的静音
            let silence = generateSilence(duration: 1.0)
            audioPlayer = try AVAudioPlayer(data: silence)
            audioPlayer?.numberOfLoops = -1 // 无限循环
            audioPlayer?.volume = 0.0 // 静音
            audioPlayer?.play()
            
            isRunning = true
        } catch {
            print("[AudioKeepAlive] 启动失败: \(error)")
        }
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isRunning = false
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("[AudioKeepAlive] 停止失败: \(error)")
        }
    }
    
    // 生成静音 WAV 数据
    private func generateSilence(duration: Double) -> Data {
        let sampleRate = 44100.0
        let samples = Int(sampleRate * duration)
        
        var data = Data()
        // WAV header (44 bytes)
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + samples * 2).littleEndian) { Data($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Data($0) }) // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) }) // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }) // bits per sample
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(samples * 2).littleEndian) { Data($0) })
        // 静音数据 (全0)
        data.append(Data(count: samples * 2))
        
        return data
    }
}
