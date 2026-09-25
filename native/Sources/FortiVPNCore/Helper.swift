import Foundation
import Darwin

public struct HelperResponse: Decodable {
    public let ok: Bool
    public let error: String?
    public let pid: Int32?
    public let version: String?
}

public struct HelperClient {
    public let socketPath: String
    private let timeoutSeconds: Int
    public init(socketPath: String = AppIdentity.socketPath, timeoutSeconds: Int = 30) {
        self.socketPath = socketPath; self.timeoutSeconds = max(1, timeoutSeconds)
    }

    public func request(_ fields: [String: Any]) throws -> HelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPNError("Could not create helper connection.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw VPNError("Helper socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyBytes(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw VPNError("Helper unavailable. Install or repair it in Settings before connecting.") }
        var payload = try JSONSerialization.data(withJSONObject: fields)
        payload.append(10)
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw VPNError("Could not send the helper request.") }
                offset += n
            }
        }
        shutdown(fd, SHUT_WR)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(10) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw VPNError("Helper response was interrupted or timed out. Check the VPN process before retrying.")
            }
            reply.append(contentsOf: buffer.prefix(count))
            guard reply.count <= 65536 else { throw VPNError("Helper response exceeds the allowed size.") }
        }
        let response = try JSONDecoder().decode(HelperResponse.self, from: reply)
        guard response.ok else { throw VPNError(response.error ?? "Helper request failed.") }
        return response
    }
    public func version() throws -> String { try request(["cmd": "ping"]).version ?? "unknown" }
}

public enum Commands {
    public struct Output {
        public let status: Int32
        public let text: String
    }
    public static func run(_ executable: String, _ args: [String], input: Data? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            try pipe.fileHandleForWriting.write(contentsOf: input)
            try pipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func administrator(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = try run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        guard result.status == 0 else { throw VPNError(result.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

public enum HelperInstaller {
    public static func install(resourceDirectory: URL) throws {
        let source = resourceDirectory.appendingPathComponent("openvpngui-helper")
        guard FileManager.default.isExecutableFile(atPath: source.path) else { throw VPNError("The bundled helper is missing. Rebuild the .app using native/scripts/build.sh.") }
        let destination = "/Library/PrivilegedHelperTools/\(AppIdentity.helperLabel)"
        let plistPath = "/Library/LaunchDaemons/\(AppIdentity.helperLabel).plist"
        let plist: [String: Any] = ["Label": AppIdentity.helperLabel, "ProgramArguments": [destination],
            "RunAtLoad": true, "KeepAlive": true, "EnvironmentVariables": ["RUST_LOG": "info"],
            "StandardOutPath": "/var/log/fortivpntray-helper.log", "StandardErrorPath": "/var/log/fortivpntray-helper.log"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let xml = String(decoding: data, as: UTF8.self)
        try Commands.administrator("set -e; /bin/launchctl bootout system/\(AppIdentity.helperLabel) 2>/dev/null || true; /bin/mkdir -p /Library/PrivilegedHelperTools; /usr/bin/install -o root -g wheel -m 755 \(Commands.shellQuote(source.path)) \(Commands.shellQuote(destination)); /usr/bin/printf '%s' \(Commands.shellQuote(xml)) > \(Commands.shellQuote(plistPath)); /usr/sbin/chown root:wheel \(Commands.shellQuote(plistPath)); /bin/chmod 644 \(Commands.shellQuote(plistPath)); /bin/launchctl bootstrap system \(Commands.shellQuote(plistPath))")
    }
    public static func uninstall() throws {
        try Commands.administrator("set -e; /bin/launchctl bootout system/\(AppIdentity.helperLabel) 2>/dev/null || true; /bin/rm -f /Library/PrivilegedHelperTools/\(AppIdentity.helperLabel) /Library/LaunchDaemons/\(AppIdentity.helperLabel).plist \(AppIdentity.socketPath)")
    }
}

/// A failed ping alone does not mean the helper is not installed.
public struct HelperInstallationStatus: Equatable {
    public enum State { case missing, incomplete, unavailable, ready, versionMismatch }
    public let executablePresent: Bool
    public let launchDaemonPresent: Bool
    public let version: String?
    public init(executablePresent: Bool, launchDaemonPresent: Bool, version: String?) {
        self.executablePresent = executablePresent
        self.launchDaemonPresent = launchDaemonPresent
        self.version = version
    }
    public var state: State {
        if let version {
            guard executablePresent && launchDaemonPresent else { return .incomplete }
            return version == AppIdentity.helperVersion ? .ready : .versionMismatch
        }
        if executablePresent && launchDaemonPresent { return .unavailable }
        return executablePresent || launchDaemonPresent ? .incomplete : .missing
    }
    public var title: String {
        switch state {
        case .missing: return "Not installed"
        case .incomplete: return "Installation needs repair"
        case .unavailable: return "Installed · not responding"
        case .ready: return "Installed and running"
        case .versionMismatch: return "Installed · update required"
        }
    }
    public var detail: String {
        switch state {
        case .missing: return "Install the helper to connect to a VPN."
        case .incomplete: return "Helper files are incomplete. Repair the installation."
        case .unavailable: return "The helper is installed, but could not be reached. Try Refresh or Repair."
        case .ready: return "Version \(version ?? "") · Ready to connect."
        case .versionMismatch: return "Running v\(version ?? "unknown"); this app requires v\(AppIdentity.helperVersion)."
        }
    }
    public static func inspect() -> Self {
        let files = FileManager.default
        return Self(executablePresent: files.fileExists(atPath: "/Library/PrivilegedHelperTools/\(AppIdentity.helperLabel)"),
                    launchDaemonPresent: files.fileExists(atPath: "/Library/LaunchDaemons/\(AppIdentity.helperLabel).plist"),
                    version: try? HelperClient(timeoutSeconds: 2).version())
    }
}
