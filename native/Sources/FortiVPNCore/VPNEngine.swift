import Foundation
import Darwin
import CryptoKit
import Security

public struct PollResult {
    public var lines: [String] = []
    public var events: [LogEvent] = []
    public var exitMessage: String?
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
}

public actor VPNEngine {
    private let helper: HelperClient
    private var pid: Int32?
    private var file: FileHandle?
    private var logURL: URL?
    private var parser = LogParser()
    private var buffer = LogBuffer()
    private var gateway: String?
    private var serverIP: String?
    private var fallbackDNS: [String] = []
    private var lastProcessCheck = Date.distantPast
    private var isConnected = false
    private var secret: String?

    public var hasSession: Bool { pid != nil }

    public init(helper: HelperClient = HelperClient()) { self.helper = helper }

    public func start(profile: VPNProfile, password: String?, settings: AppSettings) async throws {
        guard pid == nil else { throw VPNError("Disconnect the current session before reconnecting.") }
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/openfortivpn") else {
            throw VPNError("Install openfortivpn first: brew install openfortivpn. This build uses the Apple Silicon Homebrew path.")
        }
        let version = try helper.version()
        guard version == AppIdentity.helperVersion else { throw VPNError("The helper version is \(version). Install the bundled version in Settings.") }
        var profile = try profile.validated()
        if profile.ignoreCertErrors {
            let digest = try await GatewayCertificate.digest(host: profile.host, port: profile.port)
            if !profile.trustedCerts.contains(digest) { profile.trustedCerts.append(digest) }
        }
        try Task.checkCancellation()
        let args = try profile.arguments(password: password)
        secret = password
        parser = LogParser()
        buffer = LogBuffer()
        isConnected = false
        gateway = Self.defaultGateway()
        serverIP = Self.resolveIPv4(profile.host)
        fallbackDNS = settings.dnsFallback ? Self.currentDNS() : []
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fortivpntray-\(UUID().uuidString).log")
        // The legacy helper explicitly accepts only /tmp/fortivpntray-* paths.
        let helperURL = URL(fileURLWithPath: "/tmp/\(url.lastPathComponent)")
        let fd = open(helperURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw VPNError("Could not create the private VPN log.") }
        close(fd)
        logURL = helperURL
        do {
            file = try FileHandle(forReadingFrom: helperURL)
            var request: [String: Any] = ["cmd": "spawn-vpn", "args": args, "log_path": helperURL.path]
            if let serverIP { request["vpn_server"] = serverIP }
            let response = try helper.request(request)
            guard let newPID = response.pid, newPID > 1 else { throw VPNError("Helper did not return a valid VPN process ID.") }
            pid = newPID
            lastProcessCheck = Date()
        } catch {
            clearLog()
            throw error
        }
    }

    public func poll() throws -> PollResult {
        var result = PollResult()
        guard let pid, let file else { return result }
        let bytes = try file.read(upToCount: 131072) ?? Data()
        for raw in buffer.append(bytes) {
            let safe = secret.flatMap { $0.isEmpty ? nil : raw.replacingOccurrences(of: $0, with: "[redacted]") } ?? raw
            result.lines.append(LogParser.redacted(safe))
            for event in parser.consume(raw) {
                switch event {
                case .connected:
                    let servers = parser.effectiveDNS(fallback: fallbackDNS)
                    if !servers.isEmpty {
                        _ = try helper.request(["cmd": "setup-dns", "servers": servers, "suffixes": parser.dnsSuffixes])
                    }
                    isConnected = true
                default: break
                }
                result.events.append(event)
            }
        }
        if isConnected, let ip = parser.localIP {
            (result.received, result.sent) = Self.interfaceBytes(ip: ip)
        }
        if Date().timeIntervalSince(lastProcessCheck) >= 2 {
            lastProcessCheck = Date()
            if !Self.processAlive(pid) {
                // DNS cleanup also applies to unexpected exits, not only explicit disconnect.
                _ = try helper.request(["cmd": "teardown-dns"])
                result.exitMessage = parser.lastError ?? (isConnected ? "The VPN connection ended." : "openfortivpn exited before the tunnel was established.")
                self.pid = nil
                clearLog()
                isConnected = false
            }
        }
        return result
    }

    public func stop() throws {
        guard let pid else { return }
        if Self.processAlive(pid) {
            var request: [String: Any] = ["cmd": "kill-vpn", "pid": pid]
            if let gateway { request["gateway"] = gateway }
            if let serverIP { request["vpn_server"] = serverIP }
            _ = try helper.request(request)
        } else {
            _ = try helper.request(["cmd": "teardown-dns"])
        }
        self.pid = nil
        isConnected = false
        clearLog()
    }

    private func clearLog() {
        try? file?.close()
        file = nil
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        logURL = nil
        secret = nil
    }
    private static func processAlive(_ pid: Int32) -> Bool {
        guard let result = try? Commands.run("/bin/ps", ["-p", String(pid), "-o", "state="]) else { return true }
        let state = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !state.isEmpty && !state.hasPrefix("Z")
    }
    private static func defaultGateway() -> String? {
        guard let result = try? Commands.run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        let value = LogParser.capture(#"gateway:\s+([0-9.]+)"#, result.text)
        return value.flatMap { Validation.ipv4($0) ? $0 : nil }
    }
    private static func currentDNS() -> [String] {
        guard let result = try? Commands.run("/usr/sbin/scutil", ["--dns"]) else { return [] }
        var values: [String] = []
        for line in result.text.components(separatedBy: .newlines) {
            if line.hasPrefix("resolver #2") { break }
            if let ip = LogParser.capture(#"nameserver\[\d+\]\s*:\s*([0-9.]+)"#, line), Validation.ipv4(ip), !values.contains(ip) { values.append(ip) }
        }
        return values
    }
    private static func resolveIPv4(_ host: String) -> String? {
        if Validation.ipv4(host) { return host }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var address = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &output, socklen_t(output.count)) != nil else { return nil }
        return String(cString: output)
    }
    private static func interfaceBytes(ip: String) -> (UInt64, UInt64) {
        var start: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&start) == 0, let first = start else { return (0, 0) }
        defer { freeifaddrs(first) }
        var name: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let info = pointer.pointee
            if let address = info.ifa_addr, Int32(address.pointee.sa_family) == AF_INET {
                var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &value, &text, socklen_t(text.count)) != nil, String(cString: text) == ip,
                   String(cString: info.ifa_name).hasPrefix("ppp") { name = String(cString: info.ifa_name) }
            }
            cursor = info.ifa_next
        }
        cursor = first
        while let pointer = cursor {
            let info = pointer.pointee
            if let name, String(cString: info.ifa_name) == name, let address = info.ifa_addr,
               Int32(address.pointee.sa_family) == AF_LINK, let data = info.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                return (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
            }
            cursor = info.ifa_next
        }
        return (0, 0)
    }
}

private final class GatewayCertificate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: String?
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           let cert = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
            let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
            lock.lock(); fingerprint = digest; lock.unlock()
        }
        // Inspect only; never transmit credentials or accept a connection in this probe.
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    private func result() -> String? { lock.lock(); defer { lock.unlock() }; return fingerprint }
    static func digest(host: String, port: Int) async throws -> String {
        let delegate = GatewayCertificate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://\(host):\(port)/") else { throw VPNError("Invalid gateway URL.") }
        _ = try? await session.data(from: url)
        guard let result = delegate.result() else { throw VPNError("Could not obtain the gateway certificate. Check the host and network connection.") }
        return result
    }
}
