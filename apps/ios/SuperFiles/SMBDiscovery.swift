import Foundation
import Combine
import Darwin

/// 发现局域网内的 SMB 服务器：
/// 1. Bonjour（`_smb._tcp`）——NAS / macOS 通常会广播；
/// 2. 当前 /24 网段的 445 端口探测——Linux Samba 默认不广播，只能主动扫。
final class SMBDiscovery: NSObject, ObservableObject {
    struct Server: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: Int
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var isScanning = false

    private let browser = NetServiceBrowser()
    /// 注入的 NetBIOS 主机名查询（走 Rust core 的 NBNS 查询）；nil 时跳过。
    private let netbiosName: ((String) -> String?)?
    private var resolving: Set<String> = []
    private var seen: Set<String> = []
    private var timeoutWork: DispatchWorkItem?
    private var bonjourActive = false
    private var scanActive = false
    private var scanToken = UUID()
    private var scanQueue = OperationQueue()

    init(netbiosName: ((String) -> String?)? = nil) {
        self.netbiosName = netbiosName
        super.init()
        browser.delegate = self
    }

    func start() {
        stop(reset: true)
        let token = UUID()
        scanToken = token

        bonjourActive = true
        updateScanning()
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")

        let work = DispatchWorkItem { [weak self] in
            self?.bonjourActive = false
            self?.updateScanning()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)

        startSubnetScan(token: token)
    }

    func stop(reset: Bool = false) {
        scanToken = UUID()
        scanQueue.cancelAllOperations()
        browser.stop()
        timeoutWork?.cancel()
        timeoutWork = nil
        bonjourActive = false
        scanActive = false
        isScanning = false
        resolving.removeAll()
        if reset {
            servers.removeAll()
            seen.removeAll()
        }
    }

    private func updateScanning() {
        isScanning = bonjourActive || scanActive
    }

    private func add(name: String, host: String, port: Int) {
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !trimmed.isEmpty, port > 0 else { return }
        let key = "\(trimmed):\(port)"
        guard !seen.contains(key) else { return }
        // 去重只按 host:port。不能按 name 判重：多台 Samba 主机名常常相同，
        // 或反解都失败而落到同一默认名，按 name 判重会把后面的全部误杀。
        seen.insert(key)
        servers.append(Server(id: key, name: name, host: trimmed, port: port))
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - 网段扫描

    private func startSubnetScan(token: UUID) {
        guard let subnet = Self.localSubnet24() else { return }
        scanActive = true
        updateScanning()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 32
        queue.qualityOfService = .utility
        scanQueue = queue

        for last in 1...254 {
            let ip = "\(subnet).\(last)"
            queue.addOperation { [weak self] in
                guard let self, self.scanToken == token else { return }
                guard Self.probeSMB(host: ip) else { return }
                // 主机名：NBNS 查询 > 反向 DNS > 兜底（IP 已在行下方单独展示）
                let name = self.netbiosName?(ip) ?? Self.reverseName(ip) ?? "SMB 服务器"
                DispatchQueue.main.async {
                    guard self.scanToken == token else { return }
                    self.add(name: name, host: ip, port: 445)
                }
            }
        }

        queue.addOperation { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.scanToken == token else { return }
                self.scanActive = false
                self.updateScanning()
            }
        }
    }

    /// 取 Wi-Fi（en0）IPv4 的 /24 前缀。
    private static func localSubnet24() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let list = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = list
        while let ifa = pointer {
            defer { pointer = ifa.pointee.ifa_next }
            guard
                let sa = ifa.pointee.ifa_addr,
                sa.pointee.sa_family == UInt8(AF_INET),
                let name = String(cString: ifa.pointee.ifa_name, encoding: .utf8),
                name == "en0"
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0, let ip = String(validatingUTF8: host) else { continue }
            let parts = ip.split(separator: ".")
            if parts.count == 4, !ip.hasPrefix("127.") {
                return parts.prefix(3).joined(separator: ".")
            }
        }
        return nil
    }

    /// 非阻塞 TCP 连接 445；350ms 内没连上就算不存在。
    private static func probeSMB(host: String) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(445).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, 350)
        guard ready > 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    private static func reverseName(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NAMEREQD
                )
            }
        }
        guard result == 0, let name = String(validatingUTF8: host) else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension SMBDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let key = "\(service.name)|\(service.type)|\(service.domain)"
        guard !resolving.contains(key) else { return }
        resolving.insert(key)
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 4)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        guard let host = service.hostName else { return }
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        let key = "\(trimmed):\(service.port)"
        servers.removeAll { $0.id == key }
        seen.remove(key)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        bonjourActive = false
        updateScanning()
    }
}

extension SMBDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
        add(name: sender.name, host: host, port: sender.port)
        resolving.remove("\(sender.name)|\(sender.type)|\(sender.domain)")
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        resolving.remove("\(sender.name)|\(sender.type)|\(sender.domain)")
    }
}
