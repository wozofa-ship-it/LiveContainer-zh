import Foundation
import Libbox

/// sing-box 核心的 Swift 薄封装（B 项目 S1，双核心里的 sing-box 一侧）。
///
/// 接口定死，供 S2/S3 与主 agent 按此集成，不许改名：
///   enum CZFSingBoxCore {
///     static var isServiceRunning: Bool
///     static func start(configJSON: String) throws
///     static func stop() throws
///     static func version() -> String
///   }
///
/// 形态说明：gomobile bind 生成的是 plain C 函数，不是 ObjC 方法，
/// 所以 Swift 侧不会把它们转成 throws。只返回 error 的 Go 函数对应
/// `BOOL LibboxXxx(..., NSError** error)`，调用点必须传 NSErrorPointer
/// （`&error`）并检查 BOOL；无 error 的 Version 直接返回 String。
/// 这一形态来自 TUIC Demo 里对 CI 生成的 Libbox.objc.h 的核实
/// （Demo 的 ios-app/SingBoxBridge.swift 头注释），本仓库里
/// 尚无 Libbox.xcframework，见汇报里的“未验证”项。
///
/// 安全红线：配置 JSON 只传给核心，绝不写盘、不写日志文件、
/// 不打印、不放进错误信息里。错误原样抛 NSError，不吞错、不改写。
/// 本文件不做任何网络请求、不碰 VPN 开关，起停只归这里管。
enum CZFSingBoxCore {
    /// 核心是否在跑。start 成功置 true；stop 成功置 false，
    /// stop 失败也置 false（核心已不可信，调用方按抛错处理）。
    static var isServiceRunning = false

    /// libbox 进程级初始化是否已做过。只做一次，stop 不重置：
    /// Setup 是进程级状态，重起服务不需要、也不应该重做 Setup。
    private static var setupDone = false

    /// 一次性初始化：basePath 必须是 Documents 根目录，
    /// 不是 Documents/singbox。libbox 把命令服务绑在
    /// basePath + "/command.sock"，Darwin AF_UNIX sun_path 上限
    /// 104 字节，App 容器前缀本身已占 76 字节，
    /// Documents/singbox 再加 "/command.sock" 会到 107 字节，
    /// 真机上 bind 报 EINVAL；Documents 根目录则为 99 字节。
    /// workingPath/tempPath 用 Documents/singbox，不存在则创建。
    private static func setupIfNeeded() throws {
        guard !setupDone else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("singbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var error: NSError?
        guard LibboxSetup(docs.path, dir.path, dir.path, &error) else {
            throw error ?? NSError(domain: "CZFSingBoxCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "libbox setup failed"])
        }
        setupDone = true
    }

    /// 先初始化，再校验配置，最后启动核心；三步全过才置
    /// isServiceRunning = true。任何一步失败都原样抛错，
    /// 不把配置内容写进错误信息。
    static func start(configJSON: String) throws {
        try setupIfNeeded()
        var error: NSError?
        guard LibboxCheckConfig(configJSON, &error) else {
            throw error ?? NSError(domain: "CZFSingBoxCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "config check failed"])
        }
        guard LibboxStartService(configJSON, &error) else {
            throw error ?? NSError(domain: "CZFSingBoxCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "service start failed"])
        }
        isServiceRunning = true
    }

    /// 停掉核心。成功置 false；失败也置 false 再抛错，
    /// 调用方不要拿 isServiceRunning 判断这次 stop 是否成功，
    /// 以是否抛错为准。
    static func stop() throws {
        var error: NSError?
        guard LibboxStopService(&error) else {
            isServiceRunning = false
            throw error ?? NSError(domain: "CZFSingBoxCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "service stop failed"])
        }
        isServiceRunning = false
    }

    /// sing-box 版本串（如 "1.14.4"），不启动核心也能调。
    static func version() -> String {
        LibboxVersion()
    }
}
