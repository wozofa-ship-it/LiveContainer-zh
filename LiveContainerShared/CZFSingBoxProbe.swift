import Foundation
import Network

/// sing-box 临时实例的纯 SOCKS5 测速探针（B 项目 S3）。
///
/// 职责只有一件事：对“已经在本地端口上监听的 SOCKS 服务”做一次
/// 真实往返探测（TCP → SOCKS5 握手 → CONNECT → HTTP 状态行），
/// 返回通/不通/被拒与实测毫秒数。调用方（S2 集成层）负责在探针
/// 前后起停临时 sing-box 实例，本文件不调用核心库、不读写偏好设置、
/// 不碰主核心、不写任何日志文件。
///
/// 调用约束（必须遵守，否则会卡界面）：
/// - 只能在后台队列调用，禁止主线程调用。本函数是阻塞式实现
///   （DispatchSemaphore，与 TUIC Demo 的 probeBlocking 一致），
///   在主线程调用会把界面卡到 deadline 为止。
/// - 整个 probe 共用一个绝对 deadline（timeout 参数，调用方传 5 秒）：
///   TCP、握手、CONNECT、HTTP 任一步超时都返回失败，不抛错到调用方；
///   每一步的等待都以同一个 deadline 为上限，deadline 一过后续步骤
///   立刻返回，不会把调用线程挂起超过 timeout + 1 秒（多出的 1 秒
///   只留给系统调度余量，不是额外等待）。
/// - 不记录目标之外的信息：错误字符串只含阶段名与 rep/HTTP 码，
///   不含链接、密码、密钥、token；探针返回值里也不带任何此类信息。
/// - 目标固定为 host:80 的 HTTP（不是 TLS）：问题只是“隧道通不通”，
///   拿到 HTTP 状态码即算通，与 Demo 的做法一致。
public enum CZFSingBoxProbeError: Error {
    case tcpFailed(String)
    case socksFailed(String)
    case connectRejected(Int)
    case httpFailed(String)
    case timeout
}

public struct CZFSingBoxProbeResult {
    public let success: Bool
    public let delayMs: Int
    public let rejected: Bool
}

public enum CZFSingBoxProbe {
    /// 对本地 SOCKS 服务做一次阻塞式探测。
    ///
    /// - 参数 port：本地 SOCKS 监听端口（S2 集成传 10927）。
    ///   非法（<1 或 >65535）直接返回失败，不建连接。
    /// - 参数 host：探测目标主机名或 IPv4 字面量。空串直接返回失败；
    ///   域名按 SOCKS5 03 型地址发，IPv4 字面量按 01 型发 4 字节；
    ///   IPv6 字面量不在本探针的编码范围内，直接返回失败。
    /// - 参数 timeout：整次探测的绝对超时（秒，调用方传 5）。
    ///   任一步超时都返回 success=false、delayMs=0，不抛错。
    /// - 返回：rep != 0（真收到 SOCKS 拒绝回复）时 success=false、
    ///   rejected=true；其余失败一律 success=false、rejected=false；
    ///   拿到 HTTP 状态码时 success=true、delayMs=实测毫秒。
    ///   注意：只有“真收到 rep != 0”才算被拒，CONNECT 阶段超时
    ///   不算被拒（Demo v07 教训：超时误记为被拒会误导诊断）。
    /// - 只能在后台队列调用，禁止主线程调用。
    public static func probe(port: Int, host: String, timeout: TimeInterval) -> CZFSingBoxProbeResult {
        let start = Date()
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // 入参非法直接返回失败，不 throw 穿透、不建连接。
        guard port >= 1, port <= 65535, !target.isEmpty, timeout > 0 else {
            return CZFSingBoxProbeResult(success: false, delayMs: 0, rejected: false)
        }
        // 组装 CONNECT 报文：域名 03 型、IPv4 01 型；IPv6 与超长
        // 域名（>255 字节，SOCKS5 长度字段放不下）直接返回失败。
        guard let connectBytes = connectBytes(for: target) else {
            return CZFSingBoxProbeResult(success: false, delayMs: 0, rejected: false)
        }
        let deadline = DispatchTime.now() + .milliseconds(max(1, Int(timeout * 1000)))
        do {
            let conn = try openConnection(port: port, deadline: deadline)
            defer { conn.cancel() }
            try socksGreeting(conn: conn, deadline: deadline)
            let rep = try socksConnect(conn: conn, bytes: connectBytes, deadline: deadline)
            guard rep == 0 else {
                // 真被拒：只有收到 rep != 0 的回复才走这条路。
                return CZFSingBoxProbeResult(success: false, delayMs: 0, rejected: true)
            }
            _ = try httpGet(conn: conn, host: target, deadline: deadline)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return CZFSingBoxProbeResult(success: true, delayMs: ms, rejected: false)
        } catch let error as CZFSingBoxProbeError {
            // 防御性分支：connectRejected 在本实现里是直接返回、
            // 不经 throw，但万一将来改动让它被 throw，也要正确
            // 映射为 rejected=true，而不是淹没成普通失败。
            if case .connectRejected = error {
                return CZFSingBoxProbeResult(success: false, delayMs: 0, rejected: true)
            }
            // 超时与其它失败统一映射：success=false、delayMs=0、
            // rejected=false，绝不把错误抛给调用方。
            return CZFSingBoxProbeResult(success: false, delayMs: 0, rejected: false)
        } catch {
            return CZFSingBoxProbeResult(success: false, delayMs: 0, rejected: false)
        }
    }

    // MARK: - CONNECT 报文组装

    /// 域名 → 05 01 00 03 <len> <域名> 00 50；IPv4 → 05 01 00 01
    /// <4 字节> 00 50。端口固定 80（00 50，大端序）。组装不出
    /// （IPv6、超长域名）返回 nil，调用方直接记失败。
    private static func connectBytes(for host: String) -> [UInt8]? {
        if let octets = ipv4Octets(host) {
            return [0x05, 0x01, 0x00, 0x01] + octets + [0x00, 0x50]
        }
        // 含冒号的是 IPv6 字面量或带端口的写法，本探针不编码：
        // 按域名发会错，按 01 型也发不下，宁可直接失败。
        guard !host.contains(":") else { return nil }
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty, bytes.count <= 255 else { return nil }
        return [0x05, 0x01, 0x00, 0x03, UInt8(bytes.count)] + bytes + [0x00, 0x50]
    }

    /// 严格 IPv4 字面量：4 段、全数字、每段 0...255。不是则返回 nil，
    /// 调用方按域名处理（域名里含点是常态，不能只看有没有点）。
    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }),
                  let value = Int(part), value >= 0, value <= 255 else {
                return nil
            }
            octets.append(UInt8(value))
        }
        return octets
    }

    // MARK: - TCP 连接（照抄 Demo openConnection）

    private static func openConnection(port: Int, deadline: DispatchTime) throws -> NWConnection {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw CZFSingBoxProbeError.tcpFailed("tcp")
        }
        let conn = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var readyError: Error?
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let error):
                readyError = error
                sem.signal()
            case .cancelled:
                readyError = CZFSingBoxProbeError.tcpFailed("tcp")
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: .global())
        guard sem.wait(timeout: deadline) == .success else {
            conn.cancel()
            throw CZFSingBoxProbeError.timeout
        }
        conn.stateUpdateHandler = nil
        if readyError != nil {
            // 错误原因只记阶段名，不把底层错误的描述串进结果，
            // 避免描述里夹带地址以外的信息。
            throw CZFSingBoxProbeError.tcpFailed("tcp")
        }
        return conn
    }

    // MARK: - 收发原语（照抄 Demo send/recv）

    /// 发送：超时 throw .timeout；其它发送失败 throw .tcpFailed，
    /// 调用方各阶段再按阶段名重映射（见 socksGreeting 等）。
    private static func send(conn: NWConnection, bytes: [UInt8], deadline: DispatchTime) throws {
        let sem = DispatchSemaphore(value: 0)
        var sendError: Error?
        conn.send(content: Data(bytes), completion: .contentProcessed { error in
            sendError = error
            sem.signal()
        })
        guard sem.wait(timeout: deadline) == .success else {
            throw CZFSingBoxProbeError.timeout
        }
        if sendError != nil {
            throw CZFSingBoxProbeError.tcpFailed("send")
        }
    }

    /// 接收：超时 throw .timeout；接收失败/对端关闭 throw .tcpFailed。
    /// 标签必须是 minimumIncompleteLength（Demo 与 v05 构建血泪：
    /// 写成 minimumLength 编译不过，Network 框架没有这个标签）。
    private static func recv(conn: NWConnection, minimum: Int, maximum: Int, deadline: DispatchTime) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        var recvError: Error?
        conn.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, _, error in
            out = data
            recvError = error
            sem.signal()
        }
        guard sem.wait(timeout: deadline) == .success else {
            throw CZFSingBoxProbeError.timeout
        }
        if recvError != nil {
            throw CZFSingBoxProbeError.tcpFailed("receive")
        }
        guard let data = out, !data.isEmpty else {
            throw CZFSingBoxProbeError.tcpFailed("receive")
        }
        return data
    }

    // MARK: - SOCKS5 与 HTTP（照抄 Demo 阶段划分）

    /// 握手：发 05 01 00（一个无认证方法），必须回 05 00。
    /// 超时原样透传 .timeout；其它失败重映射为 socksFailed。
    private static func socksGreeting(conn: NWConnection, deadline: DispatchTime) throws {
        do {
            try send(conn: conn, bytes: [0x05, 0x01, 0x00], deadline: deadline)
            let greeting = try recv(conn: conn, minimum: 2, maximum: 2, deadline: deadline)
            guard greeting.count >= 2, greeting[0] == 0x05, greeting[1] == 0x00 else {
                throw CZFSingBoxProbeError.socksFailed("greeting")
            }
        } catch let error as CZFSingBoxProbeError {
            if case .timeout = error { throw error }
            throw CZFSingBoxProbeError.socksFailed("greeting")
        }
    }

    /// CONNECT：发报文、读回复，返回 REP 字节。回复不是 05 开头
    /// 或不足 2 字节算 socksFailed；超时原样透传 .timeout。
    /// 注意：这里只返回 rep，不在这里判定拒不拒绝——rep != 0
    /// 的判定在 probe() 里做，超时路径绝不走到那条分支。
    private static func socksConnect(conn: NWConnection, bytes: [UInt8], deadline: DispatchTime) throws -> UInt8 {
        do {
            try send(conn: conn, bytes: bytes, deadline: deadline)
            let reply = try recv(conn: conn, minimum: 4, maximum: 64, deadline: deadline)
            guard reply.count >= 2, reply[0] == 0x05 else {
                throw CZFSingBoxProbeError.socksFailed("connect")
            }
            return reply[1]
        } catch let error as CZFSingBoxProbeError {
            if case .timeout = error { throw error }
            throw CZFSingBoxProbeError.socksFailed("connect")
        }
    }

    /// HTTP：发 GET（Host: host，Connection: close），读状态行、
    /// 取第二段的整数码。任何一步失败（含无状态行、非文本）
    /// 都记 httpFailed；超时原样透传 .timeout。拿到码即算通，
    /// 不校验码的范围（301/404 同样证明隧道通，与 Demo 一致）。
    private static func httpGet(conn: NWConnection, host: String, deadline: DispatchTime) throws -> Int {
        do {
            let request = "GET / HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
            try send(conn: conn, bytes: Array(request.utf8), deadline: deadline)
            let response = try recv(conn: conn, minimum: 1, maximum: 4096, deadline: deadline)
            guard let text = String(data: response, encoding: .utf8) else {
                throw CZFSingBoxProbeError.httpFailed("http")
            }
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, let code = Int(parts[1]) else {
                throw CZFSingBoxProbeError.httpFailed("http")
            }
            return code
        } catch let error as CZFSingBoxProbeError {
            if case .timeout = error { throw error }
            throw CZFSingBoxProbeError.httpFailed("http")
        }
    }
}
