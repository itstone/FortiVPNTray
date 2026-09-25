import Testing
import Foundation
import Darwin
@testable import FortiVPNCore

struct CoreTests {
    private func profile() -> VPNProfile {
        var p = VPNProfile(); p.name = "Office"; p.host = "vpn.example.com"; p.username = "alice"
        return p
    }
    @Test func testHelperInstallationClassifiesFilesAndServiceIndependently() {
        typealias Status = HelperInstallationStatus
        expectEqual(Status(executablePresent: false, launchDaemonPresent: false, version: nil).state, .missing)
        expectEqual(Status(executablePresent: true, launchDaemonPresent: false, version: nil).state, .incomplete)
        expectEqual(Status(executablePresent: false, launchDaemonPresent: true, version: nil).state, .incomplete)
        expectEqual(Status(executablePresent: true, launchDaemonPresent: true, version: nil).state, .unavailable)
        expectEqual(Status(executablePresent: true, launchDaemonPresent: true, version: AppIdentity.helperVersion).state, .ready)
        expectEqual(Status(executablePresent: true, launchDaemonPresent: true, version: "old").state, .versionMismatch)
        // A still-running process with removed files is not a verified installation/removal.
        expectEqual(Status(executablePresent: false, launchDaemonPresent: false, version: AppIdentity.helperVersion).state, .incomplete)
    }
    @Test func testStatisticsByteBoundaries() {
        expectEqual(StatisticsFormatter.bytes(0), "0 B")
        expectEqual(StatisticsFormatter.bytes(1023), "1023 B")
        expectEqual(StatisticsFormatter.bytes(1024), "1.0 KB")
        expectEqual(StatisticsFormatter.bytes(1_048_576), "1.0 MB")
        expectEqual(StatisticsFormatter.bytes(1_073_741_824), "1.0 GB")
    }
    @Test func testStatisticsRatesRejectInvalidSamples() {
        expectEqual(StatisticsFormatter.speed(-1), "0 B/s")
        expectEqual(StatisticsFormatter.speed(.nan), "0 B/s")
        expectEqual(StatisticsFormatter.speed(.infinity), "0 B/s")
        expectEqual(StatisticsFormatter.speed(2048), "2.0 KB/s")
    }
    @Test func testStatisticsDurationHandlesMissingAndFutureStart() {
        let now = Date(timeIntervalSince1970: 100000)
        expectEqual(StatisticsFormatter.duration(since: nil, now: now), "—")
        expectEqual(StatisticsFormatter.duration(since: now.addingTimeInterval(60), now: now), "00:00:00")
        expectEqual(StatisticsFormatter.duration(since: now.addingTimeInterval(-3661), now: now), "01:01:01")
        expectEqual(StatisticsFormatter.duration(since: now.addingTimeInterval(-90000), now: now), "25:00:00")
    }
    @Test func testKeychainRoundTripAndUpdate() throws {
        let id = "native-test-" + UUID().uuidString
        defer { try? Keychain.delete(id) }
        expectNil(try Keychain.password(for: id))
        try Keychain.save("temporary-native-test", for: id)
        expectEqual(try Keychain.password(for: id), "temporary-native-test")
        try Keychain.save("updated-native-test", for: id)
        expectEqual(try Keychain.password(for: id), "updated-native-test")
        try Keychain.delete(id)
        expectNil(try Keychain.password(for: id))
        expectNoThrow(try Keychain.delete(id))
    }
    @Test func testLegacyProfileDecodesAndRoundTrips() throws {
        let json = #"[{"id":"old-id","name":"Office","host":"vpn.example.com","port":8443,"auth_type":"Saml","username":null,"realm":"staff","trusted_certs":[],"extra_args":[]}]"#
        let values = try JSONDecoder().decode([VPNProfile].self, from: Data(json.utf8))
        expectEqual(values[0].id, "old-id")
        expectEqual(values[0].authType, .saml)
        expectFalse(values[0].ignoreCertErrors)
        expectEqual(try JSONDecoder().decode([VPNProfile].self, from: JSONEncoder().encode(values)), values)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values[0])) as! [String: Any]
        expectEqual(encoded["auth_type"] as? String, "Saml")
        expectNil(encoded["password"])
    }
    @Test func testSettingsDefaultsMatchLegacy() throws {
        let value = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"debug_mode":true}"#.utf8))
        expectTrue(value.debugMode); expectTrue(value.dnsFallback); expectFalse(value.helperDeclined)
    }
    @Test func testStorageRoundTripAndMalformedDataPreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(directory: folder)
        expectEqual(try store.profiles(), [])
        let p = profile()
        try store.save(profiles: [p])
        expectEqual(try store.profiles(), [p])
        var settings = AppSettings(); settings.dnsFallback = false
        try store.save(settings: settings)
        expectEqual(try store.settings(), settings)
        let path = folder.appendingPathComponent("profiles.json")
        let damaged = Data("bad json".utf8)
        try damaged.write(to: path)
        expectThrows(try store.profiles())
        expectEqual(try Data(contentsOf: path), damaged)
    }
    @Test func testProfileValidationRejectsUnsafeHostAndPort() {
        for host in ["", "host;touch", "https://vpn.example.com", "../host"] {
            var p = profile(); p.host = host; expectThrows(try p.validated())
        }
        var p = profile(); p.port = 65536; expectThrows(try p.validated())
        p.port = 0; expectThrows(try p.validated())
    }
    @Test func testPasswordArgumentsRequireCredentials() throws {
        var p = profile()
        expectThrows(try p.arguments(password: nil))
        p.username = " "; expectThrows(try p.arguments(password: "secret"))
        p.username = "alice"
        let args = try p.arguments(password: "x ' $ \\ y")
        expectEqual(Array(args.prefix(5)), ["vpn.example.com:8443", "-u", "alice", "-p", "x ' $ \\ y"])
        expectTrue(args.contains("--set-dns=0"))
    }
    @Test func testSAMLArgumentsDoNotIncludePassword() throws {
        var p = profile(); p.authType = .saml; p.realm = "staff"
        let args = try p.arguments(password: "unused")
        expectTrue(args.contains("--saml-login")); expectTrue(args.contains("--realm=staff"))
        expectFalse(args.contains("-p")); expectFalse(args.contains("unused"))
    }
    @Test func testExtraArgumentsCannotOverrideCredentialsOrDNS() {
        for arg in ["--pppd-plugin=/tmp/x", "--config=/tmp/x", "-c/tmp/x", "-psecret", "--set-dns=1", "--cookie=secret", "--saml-login=9999", "--realm=other"] {
            expectThrows(try Validation.extraArguments([arg]))
        }
        expectNoThrow(try Validation.extraArguments(["--persistent=5", "--pppd-use-syslog=1"]))
    }
    @Test func testCertificateFingerprintsValidated() throws {
        var p = profile(); p.trustedCerts = [String(repeating: "a", count: 64)]
        expectTrue(try p.arguments(password: "secret").contains("--trusted-cert=" + p.trustedCerts[0]))
        p.trustedCerts = ["abc"]; expectThrows(try p.validated())
    }
    @Test func testShellQuotingPreservesLiteralMetacharacters() throws {
        let value = "a'b $HOME `ignored` \"hello\""
        let result = try Commands.run("/bin/sh", ["-c", "printf '%s' " + Commands.shellQuote(value)])
        expectEqual(result.status, 0); expectEqual(result.text, value)
    }
    @Test func testParserFindsIPAfterTimestamp() {
        var parser = LogParser()
        _ = parser.consume("[2026-09-25T09:00:00Z] DEBUG: Got addresses: [10.2.3.4], peer [10.0.0.1]")
        expectEqual(parser.consume("INFO: Tunnel is up and running."), [.connected("10.2.3.4")])
    }
    @Test func testParserSupportsPPPLocalIP() {
        var parser = LogParser()
        _ = parser.consume("local  IP address 10.4.5.6")
        expectEqual(parser.localIP, "10.4.5.6")
    }
    @Test func testVPNDNSExcludesFallback() {
        var parser = LogParser()
        _ = parser.consume("DEBUG: Found dns server 10.0.0.53 in xml config")
        _ = parser.consume("DEBUG: Found dns suffix a.example.com;b.example.com,a.example.com in xml config")
        expectEqual(parser.effectiveDNS(fallback: ["8.8.8.8"]), ["10.0.0.53"])
        expectEqual(parser.dnsSuffixes, ["a.example.com", "b.example.com"])
    }
    @Test func testDNSFallbackUsedOnlyWhenVPNProvidesNone() {
        var parser = LogParser()
        expectEqual(parser.effectiveDNS(fallback: ["192.168.1.1"]), ["192.168.1.1"])
        _ = parser.consume("Found dns server 999.1.1.1")
        expectEqual(parser.dnsServers, [])
    }
    @Test func testCertificateReportedOnceAfterFailure() {
        var parser = LogParser()
        let digest = String(repeating: "ab", count: 32)
        expectEqual(parser.consume("--trusted-cert=" + digest), [])
        _ = parser.consume("ERROR: Gateway certificate validation failed.")
        expectEqual(parser.consume(" --trusted-cert=" + digest), [.certificate(digest)])
        expectEqual(parser.consume(" --trusted-cert=" + digest), [])
    }
    @Test func testSAMLURLDetectedOnceAndRejectsNonLocalHTTP() {
        var parser = LogParser()
        let url = URL(string: "https://vpn.example.com/remote/saml/start?x=1")!
        expectEqual(parser.consume("SAML login: \(url)"), [.saml(url)])
        expectEqual(parser.consume("SAML login: \(url)"), [])
        expectEqual(parser.consume("saml http://insecure.example.com/"), [])
    }
    @Test func testLogsRedactSecretsAndURLs() {
        let safe = LogParser.redacted("password=secret cookie: token123 https://vpn.example.com/?token=123")
        expectFalse(safe.contains("secret")); expectFalse(safe.contains("token123")); expectFalse(safe.contains("token=123"))
    }
    @Test func testLogBufferHandlesPartialUTF8() {
        var buffer = LogBuffer()
        let bytes = Data("连接中\nnext\n".utf8)
        expectEqual(buffer.append(bytes.prefix(2)), [])
        expectEqual(buffer.append(bytes.dropFirst(2)), ["连接中", "next"])
    }
    @Test func testTunnelDownAndLastError() {
        var parser = LogParser()
        _ = parser.consume("ERROR: Authentication failed")
        expectEqual(parser.lastError, "ERROR: Authentication failed")
        expectEqual(parser.consume("INFO: Tunnel is down"), [.disconnected])
    }
    @Test func testHelperUnavailableIsActionable() {
        expectThrows(try HelperClient(socketPath: "/tmp/missing-\(UUID().uuidString)").version()) {
            expectTrue($0.localizedDescription.contains("Helper unavailable"))
        }
    }
    @Test func testHelperProtocolAndFragmentedResponse() throws {
        try withServer(reply: #"{"ok":true,"pid":1234,"version":"0.1.9"}"#) { client, request in
            let response = try client.request(["cmd": "spawn-vpn", "args": ["vpn.example.com:8443", "-p", "quoted ' password"]])
            expectEqual(response.pid, 1234)
            let fields = try request()
            expectEqual(fields["cmd"] as? String, "spawn-vpn")
            expectEqual((fields["args"] as? [String])?.last, "quoted ' password")
        }
    }
    @Test func testHelperRejectionPropagates() throws {
        try withServer(reply: #"{"ok":false,"error":"Blocked argument"}"#) { client, _ in
            expectThrows(try client.version()) { expectEqual($0.localizedDescription, "Blocked argument") }
        }
    }
    @Test func testHelperMalformedResponseFails() throws {
        try withServer(reply: "not-json") { client, _ in expectThrows(try client.version()) }
    }
    private func withServer(reply: String, body: (HelperClient, () throws -> [String: Any]) throws -> Void) throws {
        let path = "/tmp/native-vpn-test-\(UUID().uuidString).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        expectAtLeast(fd, 0)
        defer { close(fd); unlink(path) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in Array(path.utf8CString).withUnsafeBytes { buffer.copyBytes(from: $0) } }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { throw VPNError("Could not bind test socket: \(errno)") }
        final class RequestBox: @unchecked Sendable { var data = Data() }
        let box = RequestBox()
        let done = DispatchSemaphore(value: 0)
        // The client uses blocking socket I/O. A dispatch global queue can share
        // the constrained Swift Testing executor and starve on small CI runners.
        // A dedicated OS thread keeps the mock server independent of test tasks.
        Thread.detachNewThread {
            defer { done.signal() }
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            defer { close(peer) }
            var noSignal: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !box.data.contains(10) {
                let n = read(peer, &buffer, buffer.count)
                if n <= 0 { break }
                box.data.append(contentsOf: buffer.prefix(n))
            }
            for byte in Array((reply + "\n").utf8) {
                var value = byte
                // If a timed-out client has closed, let its assertion report the
                // failure instead of killing every test with SIGPIPE.
                guard write(peer, &value, 1) == 1 else { return }
            }
        }
        var waited = false
        defer { if !waited { _ = done.wait(timeout: .now() + 3) } }
        try body(HelperClient(socketPath: path)) {
            guard done.wait(timeout: .now() + 3) == .success else { throw VPNError("Mock helper did not finish.") }
            waited = true
            return try JSONSerialization.jsonObject(with: box.data) as! [String: Any]
        }
    }
}

private func expectEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T) {
    do { #expect(try lhs() == rhs()) } catch { Issue.record(error) }
}
private func expectTrue(_ value: @autoclosure () throws -> Bool) {
    do { #expect(try value()) } catch { Issue.record(error) }
}
private func expectFalse(_ value: @autoclosure () throws -> Bool) {
    do { #expect(try !value()) } catch { Issue.record(error) }
}
private func expectNil<T>(_ value: @autoclosure () throws -> T?) {
    do { #expect(try value() == nil) } catch { Issue.record(error) }
}
private func expectAtLeast<T: Comparable>(_ lhs: T, _ rhs: T) { #expect(lhs >= rhs) }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); Issue.record("Expected an error") } catch { handler(error) }
}
private func expectNoThrow<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression() } catch { Issue.record(error) }
}
