import AppKit
import SwiftUI
import Combine
import FortiVPNCore

@main
@MainActor
struct FortiVPNTrayApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let smokeTest = CommandLine.arguments.contains("--smoke-test")
    private lazy var model = AppModel(smokeTest: smokeTest)
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var subscription: AnyCancellable?
    private var quitting = false
    private let popover = NSPopover()
    private var trayController: NSHostingController<TrayView>!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !smokeTest, let existing = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }), let url = existing.bundleURL {
            // Both native and legacy variants use the same data/helper. Only one may run.
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        configureApplicationMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "FortiVPNTray"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hostingView = NSHostingView(rootView: MainView(model: model))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // fullSizeContentView includes the title bar; set the outer frame explicitly
        // so AppKit does not add title-bar height to the 400 x 560 design.
        window.setFrame(NSRect(x: 0, y: 0, width: 400, height: 560), display: false)
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "FortiVPNTray"
        trayController = NSHostingController(rootView: TrayView(model: model,
            openWindow: { [weak self] in self?.showWindow() },
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApp.terminate(nil) }))
        popover.contentViewController = trayController
        popover.behavior = .transient
        // Immediate transitions keep rapid status-button/window actions deterministic.
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        refreshStatusIcon()
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatusIcon()
                self?.resizePopover()
            }
        }
        showWindow()
        if smokeTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Task { await self.runSmokeTest() } }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
    @objc func showWindow() {
        guard let window else { return }
        popover.close()
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openSettings() { showWindow(); model.settingsVisible = true }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        resizePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Accessory apps can interact with the popover without acquiring a Dock tile.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func resizePopover() {
        guard let trayController else { return }
        trayController.view.layoutSubtreeIfNeeded()
        popover.contentSize = trayController.view.fittingSize
    }
    @objc private func showAbout() {
        showWindow()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "FortiVPNTray", .applicationVersion: "0.2.0 · Native Swift", .credits: NSAttributedString(string: "Native SwiftUI + AppKit client. Based on OpenFortiVpn Connect by Wallacy Santos Ferreira. VPN engine: openfortivpn.")])
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.helperBusy {
            model.error = "Wait for the helper installation or removal to finish before quitting."
            showWindow()
            return .terminateCancel
        }
        guard model.hasSession else { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        quitting = true
        Task {
            do { try await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                quitting = false
                model.error = "Could not disconnect: \(error.localizedDescription)"
                showWindow()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    private func refreshStatusIcon() {
        let symbol: String
        let color: NSColor?
        switch model.phase {
        case .connected: symbol = "checkmark.shield.fill"; color = .systemGreen
        case .connecting, .waiting, .disconnecting: symbol = "arrow.triangle.2.circlepath"; color = .systemOrange
        case .failed: symbol = "exclamationmark.shield.fill"; color = .systemRed
        case .disconnected: symbol = "shield"; color = nil
        }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FortiVPNTray · \(model.phase.rawValue)")
        if let color { image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) }
        image?.isTemplate = color == nil
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "FortiVPNTray · \(model.phase.rawValue)"
    }
    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    private func configureApplicationMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("About FortiVPNTray", action: #selector(showAbout)))
        appMenu.addItem(menuItem("Settings…", action: #selector(openSettings)))
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FortiVPNTray", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = edit
        bar.addItem(editItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windows = NSMenu(title: "Window")
        windows.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windows.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windows
        bar.addItem(windowItem)
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windows
    }
    private func snapshot(_ view: NSView, name: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("FortiVPNTray-smoke-\(name).png"))
            return true
        } catch { return false }
    }
    private func runSmokeTest() async {
        // In-process integration check: uses real NSWindow / NSApplication objects,
        // but never starts VPNs, contacts the helper or reads user configuration.
        var checks: [String: Bool] = [:]
        checks["nativeHostingView"] = window.contentView is NSHostingView<MainView>
        checks["startupVisible"] = window.isVisible && NSApp.activationPolicy() == .regular
        window.performClose(nil)
        checks["closeHidesWindowAndDock"] = !window.isVisible && NSApp.activationPolicy() == .accessory
        checks["statusItemRetained"] = statusItem.button != nil
        showWindow()
        checks["reopenRestoresWindowAndDock"] = window.isVisible && NSApp.activationPolicy() == .regular
        checks["noSessionCreated"] = !model.hasSession && model.profiles.isEmpty
        checks["compactWindowSize"] = window.contentView?.bounds.size == NSSize(width: 400, height: 560)
        window.performClose(nil)
        togglePopover()
        checks["trayOpensWithoutDock"] = popover.isShown && NSApp.activationPolicy() == .accessory && !window.isVisible
        checks["trayUsesSharedModel"] = trayController.rootView.model === model
        checks["trayHasUsableSize"] = popover.contentSize.width == 400 && popover.contentSize.height > 100
        try? await Task.sleep(nanoseconds: 250_000_000)
        let disconnectedIcon = statusItem.button?.image?.tiffRepresentation
        var fixture = VPNProfile()
        fixture.name = "Example VPN"
        model.profiles = [fixture]; model.selectedID = fixture.id; model.activeID = fixture.id
        model.phase = .connected
        model.ip = "10.2.3.4"
        model.since = Date().addingTimeInterval(-65)
        model.downloadRate = 2048
        model.uploadRate = 1024
        model.received = 1_048_576
        model.sent = 524_288
        model.trafficHistory = (0..<60).map { index in
            .init(download: index % 7 == 0 ? Double(index * 180) : 0, upload: index % 9 == 0 ? Double(index * 70) : 0)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        refreshStatusIcon()
        resizePopover()
        checks["connectedIconDiffers"] = statusItem.button?.image?.tiffRepresentation != disconnectedIcon && statusItem.button?.image?.isTemplate == false
        checks["traySharesLiveTelemetry"] = trayController.rootView.model.ip == "10.2.3.4" && trayController.rootView.model.trafficHistory.count == 60
        model.downloadRate = 4096
        checks["traySeesUpdatedTelemetry"] = trayController.rootView.model.downloadRate == 4096
        checks["connectedCardFitsPopover"] = popover.contentSize.height > 300 && popover.contentSize.height < 560
        checks["traySnapshot"] = snapshot(trayController.view, name: "tray")
        // A transient popover may already have dismissed on an external focus
        // change during rendering. Do not accidentally reopen it in a close check.
        if popover.isShown { togglePopover() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        checks["trayClosesWithoutDock"] = !popover.isShown && NSApp.activationPolicy() == .accessory
        togglePopover()
        try? await Task.sleep(nanoseconds: 300_000_000)
        showWindow()
        try? await Task.sleep(nanoseconds: 300_000_000)
        checks["openingWindowDismissesTray"] = !popover.isShown
        checks["openingFromTrayShowsWindow"] = window.isVisible
        checks["openingFromTrayRestoresDock"] = NSApp.activationPolicy() == .regular
        model.settingsVisible = true
        model.helperStatus = HelperInstallationStatus(executablePresent: true, launchDaemonPresent: true, version: AppIdentity.helperVersion)
        try? await Task.sleep(nanoseconds: 250_000_000)
        checks["settingsSnapshot"] = snapshot(window.contentView!, name: "settings")
        let data = try! JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
        Darwin.exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}
