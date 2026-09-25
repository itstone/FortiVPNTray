# FortiVPNTray — Build and development

A macOS 13+ Apple Silicon application using SwiftUI and AppKit. The desktop executable is Swift. The standalone Rust `helper/` crate supplies the privileged connection service, and the external openfortivpn executable supplies the VPN engine.

## Build and run

Requirements: Apple Command Line Tools (Swift 6+), Rust, and `brew install openfortivpn`.

```bash
native/scripts/test.sh
native/scripts/build.sh
open native/dist/FortiVPNTray.app
```

If needed, prefix the build commands with `DEVELOPER_DIR=/Library/Developer/CommandLineTools` to select that installed toolchain for this command only. You can also open `native/Package.swift` in Xcode for editing and debugging. Use the build script for a complete app bundle containing the helper and icon.

Set `FORTIVPNTRAY_OUTPUT_DIR="$PWD/native/dist/development"` when building to a separate bundle without replacing a running app. Quit the existing app before launching the new bundle.

The build produces an ad-hoc signed `.app` and `native/dist/FortiVPNTray-native-arm64.zip`; it is not a notarized distribution. Node/npm are not required. The Rust build compiles only the standalone helper package.

## Application behavior

- Closing the main window switches the app to Accessory mode: no running Dock icon, but the status item and VPN remain. Open it from the menu bar to restore the window and Dock icon. Minimize retains normal macOS behavior.
- Quit disconnects the current session before exiting. A failed disconnect keeps the application open with an actionable error.
- Profiles, settings and Keychain passwords use `com.itstone.fortivpntray`.
- Run one FortiVPNTray instance at a time. Do not connect multiple VPN clients concurrently: the helper manages system PPP interfaces, DNS and routes.
- Settings distinguishes missing, incomplete, unresponsive, ready and incompatible helper states. Install/removal shows progress and verifies the result. During a VPN session, changing the helper is disabled with an explicit explanation; Refresh remains available. Uninstall asks for confirmation and keeps profiles/passwords.
- The Helper is required for connections. Install/Repair in Settings uses `com.itstone.fortivpntray.helper` label and socket.
- Password and SAML profiles, realms, certificate pinning, explicit automatic certificate trust, debug logs, DNS fallback, current traffic rates and totals are supported. Extra arguments use one argument per line; credential/configuration/DNS overrides are rejected to retain application control.
- DNS supplied by the VPN takes precedence. If fallback is enabled and the VPN supplies no DNS servers, the captured system DNS servers are used.
- Logs in the UI are bounded and redact credentials and URLs. The private temporary log is removed on successful disconnect or detected process exit. No raw log export is provided.
- Configuration editing is disabled during a session; malformed configuration is preserved and reported rather than silently replaced.
- The 400×560 dark single-column window contains a connection card, profile list / inline editor, and Logs / Settings / About footer. Password and SAML are side-by-side radio buttons. The connection card includes a 60-sample download/upload chart.
- The tray opens a graphical popover sharing the main connection card: profile, VPN IP, live duration, green/orange traffic history, rates and totals. Connected uses a green filled checkmark shield; disconnected uses an outline shield. Opening the tray preserves Accessory mode. Counters and charts observe the same model as the main window.

## Verification

Core tests cover profile/settings JSON, atomic persistence/error behavior, credential arguments, certificate validation, split DNS, fragmented log reads, log redaction, SAML detection and the real Unix-socket protocol against a local mock helper. They also create, update and delete a randomly named test Keychain item. They do not read existing user passwords, start a VPN or install privileged software.

Run an in-process AppKit integration check in a logged-in graphical session:

```bash
native/dist/FortiVPNTray.app/Contents/MacOS/FortiVPNTray --smoke-test
```

This uses a temporary empty configuration, does not contact the helper, and checks actual window visibility, activation policy, shared tray telemetry, icon changes, popover sizing and close/reopen behavior. It also renders synthetic tray/settings screenshots to the temporary directory. It exits automatically. It does not substitute for visual QA or a real password/SAML gateway test.

Manual acceptance: add/edit/delete a test profile; verify a Keychain prompt if accessing credentials from the previously signed app; verify helper installation; connect with password and SAML; confirm corporate DNS resolution; close and reopen while connected; disconnect and quit; confirm network recovery after gateway loss and sleep/wake.

Architecture follows Apple's [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview) and [NSApplication activation policy](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory) APIs.
