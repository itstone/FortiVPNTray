import Foundation

public enum LogEvent: Equatable {
    case connected(String), disconnected, saml(URL), certificate(String)
}

public struct LogParser {
    public private(set) var dnsServers: [String] = []
    public private(set) var dnsSuffixes: [String] = []
    public private(set) var localIP: String?
    public private(set) var lastError: String?
    private var certificateFailed = false
    private var reportedCertificates: Set<String> = []
    private var reportedURLs: Set<URL> = []
    public init() {}
    public mutating func consume(_ line: String) -> [LogEvent] {
        var events: [LogEvent] = []
        if line.contains("ERROR:") { lastError = Self.redacted(line) }
        if let ip = Self.capture(#"Found dns server ([0-9.]+)"#, line), Validation.ipv4(ip), !dnsServers.contains(ip) { dnsServers.append(ip) }
        if let suffixes = Self.capture(#"Found dns suffix ([^\s]+)"#, line) {
            for suffix in suffixes.split(whereSeparator: { $0 == ";" || $0 == "," }).map(String.init) where Validation.hostname(suffix) && !dnsSuffixes.contains(suffix) {
                dnsSuffixes.append(suffix)
            }
        }
        for pattern in [#"Got addresses: \[([0-9.]+)\]"#, #"local\s+IP address\s+([0-9.]+)"#, #"local IP is\s+([0-9.]+)"#] {
            if let ip = Self.capture(pattern, line), Validation.ipv4(ip) { localIP = ip }
        }
        if line.contains("Gateway certificate validation failed") { certificateFailed = true }
        if certificateFailed, let digest = Self.capture(#"(?i)(?:--trusted-cert[=\s]+|sha256:\s*)([0-9a-f:]{64,95})"#, line)?.replacingOccurrences(of: ":", with: "").lowercased(), Validation.digest(digest), reportedCertificates.insert(digest).inserted {
            events.append(.certificate(digest))
        }
        if line.lowercased().contains("saml"), let raw = Self.capture(#"(https?://[^\s\"'<>]+)"#, line), let url = URL(string: raw), let host = url.host,
           (url.scheme == "https" || host == "127.0.0.1" || host == "localhost"), reportedURLs.insert(url).inserted {
            events.append(.saml(url))
        }
        if line.contains("Tunnel is up and running") { events.append(.connected(localIP ?? "unknown")) }
        if line.contains("Tunnel is down") { events.append(.disconnected) }
        return events
    }
    public func effectiveDNS(fallback: [String]) -> [String] {
        // Never mix public resolvers into a VPN-provided split-DNS configuration.
        dnsServers.isEmpty ? fallback : dnsServers
    }
    public static func redacted(_ line: String) -> String {
        var text = line
        for pattern in [#"(?i)(password|passwd|cookie|authorization|token|SAMLResponse)\s*[:=]\s*\S+"#, #"https?://[^\s]+"#] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return text
    }
    public static func capture(_ pattern: String, _ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}

/// Accumulates incomplete UTF-8 lines between polling reads without corrupting characters.
public struct LogBuffer {
    private var bytes = Data()
    public init() {}
    public mutating func append(_ data: Data) -> [String] {
        bytes.append(data)
        var lines: [String] = []
        while let end = bytes.firstIndex(of: 10) {
            lines.append(String(decoding: bytes[..<end], as: UTF8.self))
            bytes.removeSubrange(...end)
        }
        // Bound memory even if the child produces an unterminated malformed line.
        if bytes.count > 1_048_576 { bytes.removeAll() }
        return lines
    }
}
