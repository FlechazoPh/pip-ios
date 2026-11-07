// 局域网发现 — 对照 REVERSE.md §4.1（r01 + yt.Q）。
// 小米发现 = 纯 TCP 端口扫描，没有 mDNS/NSD、没有 SSDP、没有 UDP 广播。
// 因此不走 Bonjour，不声明 NSBonjourServices；首次访问局域网会弹系统权限框，
// 需 Info.plist 的 NSLocalNetworkUsageDescription。
import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum Discovery {
    /// 本机 Wi-Fi IPv4（getifaddrs，en0；REVERSE.md §7）。
    static func localWiFiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var en0: String?
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & Int32(IFF_UP)) != 0, (flags & Int32(IFF_LOOPBACK)) == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" { en0 = ip }
            if fallback == nil { fallback = ip }
        }
        return en0 ?? fallback
    }

    /// TCP 连通性探测 yt.E(port, ip)：connect <ip>:6095，超时 350ms。
    /// 用非阻塞 connect + poll(POLLOUT) 实现毫秒级超时（select 的 fd_set 在 Swift 里没有宏绑定）。
    static func tcpConnectable(host: String, port: Int, timeoutMs: Int = 350) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let ret = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ret == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeoutMs)) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return false }
        return true
    }

    /// 单 IP 探测 yt.Q(ip) 的小米分支：
    /// 1. TCP connect <ip>:6095（350ms）；2. GET isalive（800ms）；
    /// 3. 正则 "devicename"\s*:\s*"([^"]+)" 取名；命中则返回设备。
    static func probe(ip: String) async -> PipDevice? {
        guard tcpConnectable(host: ip, port: 6095) else { return nil }
        // isalive 需要在 800ms 内完成：用短超时直调 HTTP。
        guard let url = URL(string: "http://\(ip):6095/request?action=isalive") else { return nil }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0.8
        config.timeoutIntervalForResource = 0.8
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, _) = try await session.data(from: url)
            let body = String(data: data, encoding: .utf8) ?? ""
            guard body.contains("\"status\":0") else { return nil }
            guard let name = RegexHelper.firstGroup(
                pattern: "\"devicename\"\\s*:\\s*\"([^\"]+)\"", in: body),
                !name.isEmpty else { return nil }
            return PipDevice.xiaomi(host: ip, name: name)
        } catch {
            return nil
        }
    }

    /// /24 扫描：前缀.1 ~ 前缀.254，跳过本机 IP，并发上限 48（Semaphore，REVERSE.md §4.1）。
    static func scan() async -> [PipDevice] {
        guard let local = localWiFiIPv4(),
              let dot = local.lastIndex(of: ".") else { return [] }
        let prefix = String(local[..<dot])
        var found: [PipDevice] = []
        // 按 48 一批做任务组，等价于原版 Semaphore(48)。
        var batch: [String] = []
        func flush(_ ips: [String]) async -> [PipDevice] {
            await withTaskGroup(of: PipDevice?.self) { group in
                for ip in ips { group.addTask { await probe(ip: ip) } }
                var out: [PipDevice] = []
                for await d in group { if let d { out.append(d) } }
                return out
            }
        }
        for i in 1...254 {
            let ip = "\(prefix).\(i)"
            guard ip != local else { continue }
            batch.append(ip)
            if batch.count >= 48 {
                found.append(contentsOf: await flush(batch))
                batch.removeAll()
            }
        }
        if !batch.isEmpty { found.append(contentsOf: await flush(batch)) }
        return found.sorted { $0.host < $1.host }
    }
}

// MARK: - 正则取第一捕获组（ke2.e 的 devicename 正则 / getvolume 的 volume 正则都用它）

enum RegexHelper {
    static func firstGroup(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
