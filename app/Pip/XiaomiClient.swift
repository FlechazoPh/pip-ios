// 小米驱动 — 对照 REVERSE.md §3（ke2.java，mg1 实现）。
// 纯明文 HTTP GET，无鉴权、无自定义头、无持久连接、无心跳。
import Foundation

enum PipError: LocalizedError {
    /// 电视未响应（isalive 失败 / 网络错误后仍失败）
    case notResponding
    /// 不支持的操作（l72）：只弹 Toast，不重试
    case unsupported(String)
    /// 静音失败：音量没有调到 0 / <值>
    case volumeTarget(String)

    var errorDescription: String? {
        switch self {
        case .notResponding: return "电视未响应"
        case .unsupported(let msg): return msg
        case .volumeTarget(let msg): return msg
        }
    }
}

/// RemoteKey 枚举 ng1 到 keycode 的映射（REVERSE.md §3.2）。
/// 注意：PLAY_PAUSE 与 OK 相同，都是 `enter` —— 照搬，不要“修正”。
enum RemoteKey: String {
    case up = "up"
    case down = "down"
    case left = "left"
    case right = "right"
    case ok = "enter"
    case playPause = "enter"
    case back = "back"
    case home = "home"
    case menu = "menu"
    case volumeUp = "volumeup"
    case volumeDown = "volumedown"
    case power = "power"
}

actor XiaomiClient {
    let device: PipDevice
    /// 静音缓存：上次静音前的音量（ke2 内部字段 c，REVERSE.md §3.4）。
    /// 非 nil = 当前静音态；再次点按 = 恢复到该音量。
    private var mutedFromVolume: Int?
    private var connected = false

    init(device: PipDevice) {
        self.device = device
    }

    private var baseURL: String { "http://\(device.host):\(device.port)" }

    /// 一次独立的 HTTP GET。原版 ke2.e() 超时：connect 2500ms / read 3000ms。
    private func get(_ path: String, timeout: TimeInterval) async throws -> String {
        guard let url = URL(string: baseURL + path) else { throw PipError.notResponding }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // 无鉴权、无自定义头（原版 HttpURLConnection 手写 GET，无自定义头）。
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PipError.notResponding
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch let e as PipError {
            throw e
        } catch {
            throw PipError.notResponding
        }
    }

    /// 连接检查 ke2.c()：GET /request?action=isalive，响应体含 "status":0 才算成功。
    func isAlive(timeout: TimeInterval = 3.0) async -> Bool {
        do {
            let body = try await get("/request?action=isalive", timeout: timeout)
            return body.contains("\"status\":0") || body.range(
                of: "\"status\"\\s*:\\s*0", options: .regularExpression) != nil
        } catch {
            return false
        }
    }

    /// 读音量 ke2.d()：GET /controller?action=getvolume，正则 "volume"\s*:\s*(\d+)。
    /// 匹配不到抛“这台电视不支持静音”。
    func getVolume() async throws -> Int {
        let body = try await get("/controller?action=getvolume", timeout: 3.0)
        guard let text = RegexHelper.firstGroup(pattern: "\"volume\"\\s*:\\s*(\\d+)", in: body),
              let value = Int(text) else {
            throw PipError.unsupported("这台电视不支持静音")
        }
        return value
    }

    /// 按键 ke2.b(RemoteKey)：GET /controller?action=keyevent&keycode=<name>。
    /// 会话层 u00：每次按键前若未连接先调 isalive；IOException -> 关闭后自动重连重试一次，
    /// 仍失败进入错误态；l72（不支持）只弹 Toast，不重试。
    func sendKey(_ key: RemoteKey) async throws {
        try await withRetry {
            if !self.connected {
                guard await self.isAlive() else { throw PipError.notResponding }
                self.connected = true
            }
            _ = try await self.get("/controller?action=keyevent&keycode=\(key.rawValue)", timeout: 3.0)
        }
    }

    /// 不支持的操作：直接抛 l72，不发请求、不重试（REVERSE.md §3.2）。
    /// nonisolated：不碰 actor 状态，供 UI 层直接调用。
    nonisolated func unsupportedControlCenter() throws -> Never {
        throw PipError.unsupported("这台设备没有控制中心")
    }

    nonisolated func unsupportedSkip() throws -> Never {
        throw PipError.unsupported("这台设备不支持这个操作")
    }

    /// 静音 ke2.b case 11：无专用接口，靠循环调音量模拟（REVERSE.md §3.4）。
    /// 静音态（缓存非 nil）：循环 volumeup + getvolume 核对，直到 >= 缓存值后清空缓存；
    /// 非静音：先 getvolume，<=0 直接返回；否则循环 volumedown + 核对直到 <=0，并缓存原音量。
    /// 上限 101 次，调不到抛“音量没有调到 0”/“音量没有调到 <值>”。
    func toggleMute() async throws {
        if let target = mutedFromVolume {
            // 恢复音量
            for _ in 0..<101 {
                let current = try await stepVolumeUpAndRead()
                if current >= target {
                    mutedFromVolume = nil
                    return
                }
            }
            throw PipError.volumeTarget("音量没有调到 \(target)")
        } else {
            let current = try await getVolume()
            guard current > 0 else { return }
            mutedFromVolume = current
            for _ in 0..<101 {
                let now = try await stepVolumeDownAndRead()
                if now <= 0 { return }
            }
            // 恢复失败：保留缓存（仍是静音进行态），与原版一致：下次点按继续尝试恢复。
            throw PipError.volumeTarget("音量没有调到 0")
        }
    }

    private func stepVolumeUpAndRead() async throws -> Int {
        try await sendKey(.volumeUp)
        return try await getVolume()
    }

    private func stepVolumeDownAndRead() async throws -> Int {
        try await sendKey(.volumeDown)
        return try await getVolume()
    }

    /// u00.a() 包装：IOException -> 关闭驱动后自动重连重试一次。
    /// 注意：unsupported / volumeTarget 不重试（原版只对 IOException 重试）。
    private func withRetry(_ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch PipError.notResponding {
            connected = false
            // 重连重试一次
            do {
                try await work()
            } catch PipError.notResponding {
                connected = false
                throw PipError.notResponding
            }
        }
    }

    func disconnect() {
        // ke2.close() 为默认空实现：无长连接可关。
        connected = false
    }
}
