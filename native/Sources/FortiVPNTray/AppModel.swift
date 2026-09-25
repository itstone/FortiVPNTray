import AppKit
import SwiftUI
import FortiVPNCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: String { case disconnected = "Disconnected", connecting = "Connecting…", waiting = "Waiting for SSO…", connected = "Connected", disconnecting = "Disconnecting…", failed = "Connection error" }
    struct CertificatePrompt: Identifiable { let id = UUID(); let profileID: String; let digest: String }
    @Published var profiles: [VPNProfile] = []
    @Published var selectedID: String?
    @Published var phase: Phase = .disconnected
    @Published var activeID: String?
    @Published var ip = ""
    @Published var since: Date?
    @Published var logs: [String] = []
    @Published var error: String?
    @Published var settings = AppSettings()
    @Published var helperStatus: HelperInstallationStatus?
    @Published var helperRefreshing = false
    @Published var helperOperation = ""
    @Published var helperFeedback: String?
    @Published var helperFeedbackIsError = false
    @Published var helperBusy = false
    @Published var settingsVisible = false
    @Published var tab = "connection"
    @Published var certificate: CertificatePrompt?
    @Published var samlURL: URL?
    @Published var received: UInt64 = 0
    @Published var sent: UInt64 = 0
    @Published var downloadRate: Double = 0
    @Published var uploadRate: Double = 0
    struct TrafficSample { let download: Double; let upload: Double }
    @Published var trafficHistory: [TrafficSample] = []
    private var lastHistorySample = Date.distantPast
    @Published var storageAvailable = true
    private let store: ConfigurationStore
    private let engine = VPNEngine()
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var previousSample: (Date, UInt64, UInt64)?
    let smokeTest: Bool
    var selected: VPNProfile? { profiles.first { $0.id == selectedID } }
    var hasSession: Bool { activeID != nil }
    var mayEdit: Bool { !hasSession && storageAvailable }

    init(smokeTest: Bool = false) {
        self.smokeTest = smokeTest
        store = ConfigurationStore(directory: smokeTest ? FileManager.default.temporaryDirectory.appendingPathComponent("fortivpntray-smoke-\(UUID().uuidString)") : nil)
        do {
            profiles = try store.profiles()
            settings = try store.settings()
            selectedID = profiles.first?.id
        } catch {
            storageAvailable = false
            self.error = "Cannot read existing configuration. The files have been preserved. \(error.localizedDescription)"
        }
        if !smokeTest { refreshHelper() }
    }
    func save(_ profile: VPNProfile, password: String) throws {
        guard mayEdit else { throw VPNError("Disconnect before editing profiles.") }
        let profile = try profile.validated()
        let previous = profiles
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        try store.save(profiles: updated)
        do {
            if !password.isEmpty { try Keychain.save(password, for: profile.id) }
        } catch {
            try store.save(profiles: previous)
            throw error
        }
        profiles = updated
        selectedID = profile.id
    }
    func delete(_ profile: VPNProfile) {
        guard mayEdit else { return }
        do {
            let updated = profiles.filter { $0.id != profile.id }
            try store.save(profiles: updated)
            profiles = updated
            selectedID = profiles.first?.id
            try Keychain.delete(profile.id)
        } catch { self.error = error.localizedDescription }
    }
    func saveSettings() {
        guard storageAvailable else { return }
        do { try store.save(settings: settings) }
        catch { self.error = error.localizedDescription }
    }
    func connect() {
        guard !hasSession, !helperBusy, storageAvailable, let profile = selected else { return }
        let token = UUID()
        generation = token
        activeID = profile.id
        phase = .connecting
        logs = []; ip = ""; since = nil; error = nil; samlURL = nil
        received = 0; sent = 0; downloadRate = 0; uploadRate = 0; previousSample = nil
        trafficHistory = []; lastHistorySample = .distantPast
        let settings = self.settings
        operation = Task {
            do {
                let password = profile.authType == .password ? try Keychain.password(for: profile.id) : nil
                try await engine.start(profile: profile, password: password, settings: settings)
                guard generation == token else { return }
                while !Task.isCancelled && generation == token {
                    let result = try await engine.poll()
                    guard generation == token else { return }
                    for line in result.lines where settings.debugMode || !line.contains("DEBUG:") { appendLog(line) }
                    for event in result.events {
                        switch event {
                        case .connected(let address): phase = .connected; ip = address; since = since ?? Date(); samlURL = nil
                        case .disconnected: appendLog("The tunnel is down; waiting for process cleanup.")
                        case .saml(let url):
                            phase = .waiting; samlURL = url
                            NSWorkspace.shared.open(url)
                        case .certificate(let digest): certificate = CertificatePrompt(profileID: profile.id, digest: digest)
                        }
                    }
                    updateBandwidth(result)
                    if let message = result.exitMessage {
                        phase = .failed; activeID = nil; self.error = message
                        downloadRate = 0; uploadRate = 0; since = nil; ip = ""
                        appendLog(message)
                        return
                    }
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                // A monitor failure may leave a VPN running. Keep Disconnect available.
                let running = await engine.hasSession
                activeID = running ? profile.id : nil
                phase = .failed
                downloadRate = 0; uploadRate = 0
                self.error = error.localizedDescription
                appendLog(error.localizedDescription)
            }
        }
    }
    func disconnect() {
        guard hasSession, phase != .disconnecting else { return }
        Task {
            do { try await shutdown() }
            catch { self.error = error.localizedDescription; phase = .failed }
        }
    }
    func shutdown() async throws {
        generation = UUID()
        let starting = operation
        starting?.cancel()
        // Wait for an in-flight spawn to finish before asking the helper to stop it.
        // This prevents a late spawn from surviving a close/quit request.
        phase = .disconnecting
        await starting?.value
        try await engine.stop()
        activeID = nil; phase = .disconnected; since = nil; samlURL = nil
        ip = ""; downloadRate = 0; uploadRate = 0
        operation = nil
    }
    func trustCertificate(_ prompt: CertificatePrompt) {
        certificate = nil
        Task {
            do {
                try await shutdown()
                guard var profile = profiles.first(where: { $0.id == prompt.profileID }) else { return }
                if !profile.trustedCerts.contains(prompt.digest) { profile.trustedCerts.append(prompt.digest) }
                try save(profile, password: "")
                connect()
            } catch { self.error = error.localizedDescription }
        }
    }
    func refreshHelper() {
        guard !helperBusy, !helperRefreshing else { return }
        helperRefreshing = true
        Task {
            helperStatus = await Task.detached { HelperInstallationStatus.inspect() }.value
            helperRefreshing = false
        }
    }
    func manageHelper(install: Bool) {
        guard !hasSession, !helperBusy, !helperRefreshing else { return }
        helperBusy = true
        helperOperation = install ? "Installing helper…" : "Uninstalling helper…"
        helperFeedback = nil
        helperFeedbackIsError = false
        let resources = Bundle.main.resourceURL
        Task {
            do {
                try await Task.detached {
                    if install {
                        guard let resources else { throw VPNError("App bundle resources were not found.") }
                        try HelperInstaller.install(resourceDirectory: resources)
                    } else { try HelperInstaller.uninstall() }
                }.value
                helperOperation = "Verifying helper…"
                var status = await Task.detached { HelperInstallationStatus.inspect() }.value
                // launchd can take a moment to start the newly installed service.
                for _ in 0..<4 where install && status.state != .ready {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    status = await Task.detached { HelperInstallationStatus.inspect() }.value
                }
                helperStatus = status
                guard install ? status.state == .ready : status.state == .missing else {
                    throw VPNError(install ? "Installation finished, but the helper is not ready. \(status.detail)" : "Removal could not be verified. \(status.detail)")
                }
                helperFeedback = install ? "Helper installed successfully and ready to use." : "Helper uninstalled. Your profiles and saved passwords are preserved."
            } catch {
                helperFeedbackIsError = true
                helperFeedback = error.localizedDescription
                helperStatus = await Task.detached { HelperInstallationStatus.inspect() }.value
            }
            helperBusy = false
            helperOperation = ""
        }
    }
    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 1500 { logs.removeFirst(logs.count - 1500) }
    }
    private func updateBandwidth(_ result: PollResult) {
        guard phase == .connected else { return }
        let now = Date()
        if let (last, rx, tx) = previousSample {
            let elapsed = max(now.timeIntervalSince(last), 0.001)
            downloadRate = Double(result.received >= rx ? result.received - rx : 0) / elapsed
            uploadRate = Double(result.sent >= tx ? result.sent - tx : 0) / elapsed
        }
        previousSample = (now, result.received, result.sent)
        received = result.received; sent = result.sent
        if now.timeIntervalSince(lastHistorySample) >= 2 {
            trafficHistory.append(TrafficSample(download: downloadRate, upload: uploadRate))
            if trafficHistory.count > 60 { trafficHistory.removeFirst(trafficHistory.count - 60) }
            lastHistorySample = now
        }
    }
}
