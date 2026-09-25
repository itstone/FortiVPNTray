import SwiftUI
import AppKit
import FortiVPNCore

private enum Appearance {
    static let secondary = Color.white.opacity(0.48)
    static let border = Color.white.opacity(0.10)
    static let blue = Color(red: 0.23, green: 0.51, blue: 0.96)
}

private struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct FilledButton: ButtonStyle {
    var color = Appearance.blue
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .foregroundStyle(Color.white.opacity(enabled ? 1 : 0.5))
            .background(color.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct InputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Appearance.border))
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var editing: VPNProfile?
    @State private var aboutVisible = false
    var body: some View {
        ZStack {
            Backdrop()
            Color.black.opacity(0.48)
            VStack(spacing: 0) {
                Text("FortiVPNTray").font(.system(size: 11, weight: .semibold))
                    .tracking(0.8).foregroundStyle(Color.white.opacity(0.6))
                    .frame(maxWidth: .infinity).frame(height: 28)
                if model.settingsVisible {
                    SettingsView(model: model)
                } else if aboutVisible {
                    about
                } else {
                    ConnectionCard(model: model).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
                    if let profile = editing {
                        ProfileEditor(model: model, profile: profile) { editing = nil }
                            .id(profile.id).padding(.horizontal, 16).padding(.bottom, 12)
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        profileList.padding(.horizontal, 16)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    footer
                }
            }
            if model.tab == "logs" { logOverlay }
        }
        .frame(width: 400, height: 560)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .foregroundStyle(Color.white.opacity(0.88))
        .sheet(item: $model.certificate) { prompt in
            VStack(alignment: .leading, spacing: 16) {
                Label("Verify gateway certificate", systemImage: "exclamationmark.shield").font(.headline)
                Text("Compare this SHA256 fingerprint with your administrator before trusting the gateway.").font(.callout)
                Text(prompt.digest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Cancel") { model.certificate = nil; model.disconnect() }
                    Spacer()
                    Button("Trust and Reconnect") { model.trustCertificate(prompt) }
                }
            }.padding(20).frame(width: 340).preferredColorScheme(.dark)
        }
        .alert("FortiVPNTray", isPresented: Binding(get: { model.error != nil && model.certificate == nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var profileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VPN PROFILES").font(.system(size: 11, weight: .medium)).tracking(1.5)
                .foregroundStyle(Appearance.secondary).padding(.bottom, 2)
            if model.profiles.isEmpty {
                Text("No profiles yet. Create one to get started.")
                    .font(.system(size: 13)).foregroundStyle(Appearance.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.profiles) { profile in
                            HStack(spacing: 10) {
                                Button {
                                    model.selectedID = profile.id
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "server.rack").font(.system(size: 18))
                                            .foregroundStyle(Appearance.secondary).frame(width: 40, height: 40)
                                            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(profile.host).font(.system(size: 11)).foregroundStyle(Appearance.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.hasSession)
                                Button { editing = profile } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                                    .buttonStyle(.plain).foregroundStyle(Appearance.secondary).help("Edit profile")
                                    .disabled(!model.mayEdit).accessibilityLabel("Edit \(profile.name)")
                                Image(systemName: model.selectedID == profile.id ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 19)).foregroundStyle(model.selectedID == profile.id ? Appearance.blue : Color.white.opacity(0.2))
                                    .accessibilityLabel(model.selectedID == profile.id ? "Selected" : "Not selected")
                            }.padding(12)
                                .background(Color.black.opacity(model.selectedID == profile.id ? 0.5 : 0.3), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selectedID == profile.id ? Appearance.blue.opacity(0.3) : Appearance.border))
                        }
                    }
                }.frame(maxHeight: 224)
            }
            Button { editing = VPNProfile() } label: {
                Text("+ New Profile").font(.system(size: 13)).foregroundStyle(Appearance.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }.buttonStyle(.plain).disabled(!model.mayEdit)
            Spacer(minLength: 0)
        }
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Button { model.tab = "logs" } label: {
                Label("Logs", systemImage: "doc.text")
                if !model.logs.isEmpty { Text("\(model.logs.count)").font(.system(size: 10)) }
            }.accessibilityLabel("Logs")
            Spacer()
            Button { model.settingsVisible = true } label: { Image(systemName: "gearshape") }
                .help("Settings").accessibilityLabel("Settings")
            Button { aboutVisible = true } label: { Image(systemName: "info.circle") }
                .help("About").accessibilityLabel("About")
            Text("v0.2.0").font(.system(size: 11))
        }
        .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.4))
        .padding(.horizontal, 16).frame(height: 34)
        .background(Color.black.opacity(0.2)).overlay(alignment: .top) { Rectangle().fill(Appearance.border).frame(height: 1) }
    }
    private var logOverlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection Logs").font(.headline)
                Spacer()
                Button("Clear") { model.logs = [] }.buttonStyle(.plain).foregroundStyle(Appearance.secondary)
                Button { model.tab = "connection" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close logs")
            }
            ScrollView {
                Text(model.logs.isEmpty ? "No logs yet." : model.logs.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).padding(.top, 28).background(Color(white: 0.09).opacity(0.98))
    }
    private var about: some View {
        VStack(spacing: 20) {
            panelHeader("About") { aboutVisible = false }
            Spacer()
            Image(systemName: "lock.shield.fill").font(.system(size: 48)).foregroundStyle(Appearance.blue)
            Text("FortiVPNTray").font(.title3.bold())
            Text("Version 0.2.0 · Native Swift").foregroundStyle(Appearance.secondary)
            Text("Based on OpenFortiVpn Connect by Wallacy Santos Ferreira. VPN engine: openfortivpn.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(Appearance.secondary)
            Link("View source on GitHub", destination: URL(string: "https://github.com/itstone/FortiVPNTray")!)
            Spacer()
        }.padding(16)
    }
}

struct ConnectionCard: View {
    @ObservedObject var model: AppModel
    private var statusColor: Color {
        switch model.phase {
        case .connected: return .green
        case .connecting, .waiting: return .yellow
        case .disconnecting: return .orange
        case .failed: return .red
        case .disconnected: return Color(red: 0.61, green: 0.64, blue: 0.69)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 12, height: 12)
                Text(model.phase == .waiting ? "Waiting for SAML login…" : model.phase.rawValue)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            if model.phase == .connected {
                VStack(alignment: .leading, spacing: 4) {
                    Text((model.profiles.first { $0.id == model.activeID } ?? model.selected)?.name ?? "")
                    Text("IP: \(model.ip)")
                    if let since = model.since { Text(since, style: .timer).monospacedDigit() }
                    TrafficChart(samples: model.trafficHistory).padding(.top, 5)
                    HStack {
                        Text("● \(StatisticsFormatter.speed(model.downloadRate)) down").foregroundStyle(.green.opacity(0.8))
                        Spacer()
                        Text("● \(StatisticsFormatter.speed(model.uploadRate)) up").foregroundStyle(.orange.opacity(0.8))
                    }.font(.system(size: 11))
                    HStack {
                        Text("\(StatisticsFormatter.bytes(model.received)) received")
                        Spacer()
                        Text("\(StatisticsFormatter.bytes(model.sent)) sent")
                    }.font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.3))
                }.font(.system(size: 12)).foregroundStyle(Appearance.secondary).padding(.leading, 20)
            }
            if let url = model.samlURL {
                Button("Open SAML sign-in in browser") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Appearance.blue)
            }
            Button(model.phase == .disconnecting ? "Disconnecting…" : (model.hasSession ? "Disconnect" : "Connect")) {
                model.hasSession ? model.disconnect() : model.connect()
            }
            .buttonStyle(FilledButton(color: model.hasSession ? .red.opacity(0.8) : Appearance.blue))
            .disabled(model.phase == .disconnecting || model.helperBusy || (!model.hasSession && (model.selected == nil || !model.storageAvailable)))
        }
        .padding(16)
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.hasSession ? statusColor.opacity(0.2) : Appearance.border))
    }
}

struct TrayView: View {
    @ObservedObject var model: AppModel
    let openWindow: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            ConnectionCard(model: model)
            if !model.hasSession && !model.profiles.isEmpty {
                Picker("Profile", selection: $model.selectedID) {
                    ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }.disabled(model.helperBusy)
            }
            if model.error != nil || model.certificate != nil {
                Button("Open window to review connection message…", action: openWindow)
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Open Window", action: openWindow)
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
                Button("Quit", action: quit)
            }.buttonStyle(.borderless).font(.system(size: 12))
        }.padding(16).frame(width: 400)
            .background(Color(red: 0.035, green: 0.075, blue: 0.085))
            .foregroundStyle(Color.white.opacity(0.88)).preferredColorScheme(.dark)
    }
}

private func panelHeader(_ title: String, back: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
        Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Appearance.secondary).accessibilityLabel("Back")
        Text(title).font(.system(size: 14, weight: .semibold))
        Spacer()
    }
}

struct ProfileEditor: View {
    @ObservedObject var model: AppModel
    @State var profile: VPNProfile
    var onDone: () -> Void
    @State private var password = ""
    @State private var portText = ""
    @State private var certificates = ""
    @State private var extraArguments = ""
    @State private var error: String?
    @State private var confirmDelete = false
    private var isNew: Bool { !model.profiles.contains { $0.id == profile.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelHeader(isNew ? "New Profile" : "Edit Profile", back: onDone)
                if !isNew {
                    Button("Delete") { confirmDelete = true }.buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12)).disabled(!model.mayEdit)
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    field("Name") { TextField("My VPN", text: $profile.name).modifier(InputStyle()).accessibilityLabel("Name") }
                    HStack(alignment: .top, spacing: 10) {
                        field("Host") { TextField("vpn.example.com", text: $profile.host).modifier(InputStyle()).accessibilityLabel("Host") }
                        field("Port") { TextField("8443", text: $portText).modifier(InputStyle()).accessibilityLabel("Port") }.frame(width: 88)
                    }
                    field("Authentication") {
                        Picker("Authentication", selection: $profile.authType) {
                            Text("Password").tag(AuthType.password)
                            Text("SAML").tag(AuthType.saml)
                        }
                        .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                        .accessibilityIdentifier("profile-authentication")
                    }
                    if profile.authType == .password {
                        field("Username") { TextField("john.doe", text: Binding(get: { profile.username ?? "" }, set: { profile.username = $0 })).modifier(InputStyle()).accessibilityLabel("Username") }
                        field("Password") { SecureField(isNew ? "Enter password" : "Leave empty to keep current", text: $password).modifier(InputStyle()).accessibilityLabel("Password") }
                    } else {
                        Text("Sign in through your browser when you connect.").font(.system(size: 11)).foregroundStyle(Appearance.secondary)
                    }
                    field("Realm (optional)") { TextField("optional", text: Binding(get: { profile.realm ?? "" }, set: { profile.realm = $0 })).modifier(InputStyle()).accessibilityLabel("Realm") }
                    Toggle("Ignore certificate errors", isOn: $profile.ignoreCertErrors).font(.system(size: 12)).toggleStyle(.checkbox)
                    Text("Trusts whatever certificate the gateway presents. Only use on gateways you control.").font(.system(size: 11)).foregroundStyle(Appearance.secondary)
                    DisclosureGroup("Trusted Certificates") {
                        Text("SHA256 fingerprints · one per line").font(.system(size: 11)).foregroundStyle(Appearance.secondary)
                        TextEditor(text: $certificates).font(.system(size: 11, design: .monospaced)).frame(height: 65)
                            .scrollContentBackground(.hidden).modifier(InputStyle()).accessibilityLabel("Trusted certificates")
                    }.font(.system(size: 12))
                    DisclosureGroup("Advanced arguments") {
                        Text("One argument per line").font(.system(size: 11)).foregroundStyle(Appearance.secondary)
                        TextEditor(text: $extraArguments).font(.system(size: 11, design: .monospaced)).frame(height: 55)
                            .scrollContentBackground(.hidden).modifier(InputStyle()).accessibilityLabel("Extra arguments")
                    }.font(.system(size: 12))
                }.padding(.trailing, 2)
            }
            HStack(spacing: 8) {
                Button("Save") {
                    do {
                        guard let port = Int(portText), (1...65535).contains(port) else { throw VPNError("Enter a port between 1 and 65535.") }
                        profile.port = port
                        profile.trustedCerts = lines(certificates)
                        profile.extraArgs = lines(extraArguments)
                        try model.save(profile, password: password)
                        onDone()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(FilledButton()).keyboardShortcut(.defaultAction).disabled(!model.mayEdit)
                Button("Cancel", action: onDone).buttonStyle(FilledButton(color: Color.white.opacity(0.1))).keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { portText = String(profile.port); certificates = profile.trustedCerts.joined(separator: "\n"); extraArguments = profile.extraArgs.joined(separator: "\n") }
        .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmDelete) {
            Button("Delete Profile", role: .destructive) { model.delete(profile); onDone() }
        } message: { Text("The saved password will also be removed from Keychain.") }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(Appearance.secondary)
            content()
        }
    }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmUninstall = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            panelHeader("Settings") { model.saveSettings(); model.settingsVisible = false }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Debug mode", isOn: $model.settings.debugMode).toggleStyle(.switch).disabled(!model.storageAvailable)
                    Text("Show detailed connection logs.").font(.system(size: 11)).foregroundStyle(Appearance.secondary)
                    Toggle("DNS fallback", isOn: $model.settings.dnsFallback).toggleStyle(.switch).disabled(!model.storageAvailable)
                    Text("Use system DNS only when the VPN supplies none. Changes apply to the next connection.").font(.system(size: 11)).foregroundStyle(Appearance.secondary)
                    Divider().padding(.vertical, 4)
                    Text("CONNECTION HELPER").font(.system(size: 11, weight: .medium)).tracking(1).foregroundStyle(Appearance.secondary)
                    VStack(alignment: .leading, spacing: 7) {
                        Label(model.helperStatus?.title ?? "Checking helper…",
                              systemImage: model.helperStatus?.state == .ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(model.helperStatus?.state == .ready ? Color.green : Color.orange)
                        Text(model.helperStatus?.detail ?? "Reading installation and service status.")
                            .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.7))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    if model.hasSession {
                        Label("VPN is active. Disconnect first to repair or uninstall the helper.", systemImage: "lock.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    if model.helperBusy {
                        HStack { ProgressView().controlSize(.small); Text(model.helperOperation) }.font(.system(size: 12))
                    }
                    if let feedback = model.helperFeedback {
                        Label(feedback, systemImage: model.helperFeedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(model.helperFeedbackIsError ? Color.orange : Color.green)
                            .textSelection(.enabled)
                    }
                    Button(model.helperStatus?.state == .missing ? "Install Helper…" : "Repair / Reinstall Helper…") { model.manageHelper(install: true) }
                        .buttonStyle(FilledButton()).disabled(model.hasSession || model.helperBusy || model.helperRefreshing)
                    HStack {
                        Button("Uninstall Helper…", role: .destructive) { confirmUninstall = true }
                            .buttonStyle(.bordered).tint(.red)
                            .disabled(model.hasSession || model.helperBusy || model.helperRefreshing || model.helperStatus == nil || model.helperStatus?.state == .missing)
                        Spacer()
                        Button(model.helperRefreshing ? "Checking…" : "Refresh") { model.refreshHelper() }
                            .buttonStyle(.bordered).disabled(model.helperBusy || model.helperRefreshing)
                    }.font(.system(size: 12))
                    Text("Install and uninstall require macOS administrator permission. Uninstalling preserves your VPN profiles and passwords.")
                        .font(.system(size: 11)).foregroundStyle(Appearance.secondary)
                }.font(.system(size: 13)).padding(.trailing, 2)
            }
            Button("Done") { model.saveSettings(); model.settingsVisible = false }.buttonStyle(FilledButton()).keyboardShortcut(.defaultAction)
        }.padding(16)
        .confirmationDialog("Uninstall the connection helper?", isPresented: $confirmUninstall) {
            Button("Uninstall Helper", role: .destructive) { model.manageHelper(install: false) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the background connection helper. VPN connections will be unavailable until you reinstall it. Your profiles and saved passwords will be kept. macOS will request administrator permission.")
        }
        .onAppear { if !model.smokeTest { model.refreshHelper() } }
    }
}

private struct TrafficChart: View {
    let samples: [AppModel.TrafficSample]
    private var maximum: Double { max(1024, samples.map { max($0.download, $0.upload) }.max() ?? 0) }
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(StatisticsFormatter.speed(maximum)).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.3))
            Canvas { context, size in
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: size.height / 2))
                grid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(grid, with: .color(.white.opacity(0.05)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                for upload in [false, true] {
                    let points = samples.enumerated().map { index, sample in
                        CGPoint(x: Double(60 - samples.count + index) / 59 * size.width,
                                y: size.height * (1 - (upload ? sample.upload : sample.download) / maximum))
                    }
                    guard let first = points.first, let last = points.last else { continue }
                    var line = Path()
                    line.move(to: first)
                    for point in points.dropFirst() { line.addLine(to: point) }
                    var area = line
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.addLine(to: CGPoint(x: first.x, y: size.height))
                    area.closeSubpath()
                    let color: Color = upload ? .orange : .green
                    context.fill(area, with: .color(color.opacity(0.18)))
                    context.stroke(line, with: .color(color.opacity(0.7)), lineWidth: 1)
                }
            }.frame(height: 80).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.05)))
        }.accessibilityLabel("Download and upload history, last two minutes")
    }
}
