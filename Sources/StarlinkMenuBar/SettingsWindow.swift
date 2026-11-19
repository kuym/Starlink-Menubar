import AppKit
import ServiceManagement
import SwiftUI

/// The dish's own web UI.
let dishWebUI = URL(string: "http://192.168.100.1")!

/// The settings window, opened from the popup's gear button. An AppKit window rather than a SwiftUI `Window`
/// scene: on macOS 14 a scene can't be kept from opening at launch, and a menu-bar-only app has to bring
/// itself forward for the window to take focus.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        let w = window ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Starlink Menu Bar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var loginItem = LoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .toggleStyle(.checkbox)
                if let note = loginItem.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if loginItem.needsApproval {
                        Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Starlink Web UI") { NSWorkspace.shared.open(dishWebUI) }
                    .help("Open the dish's web UI (192.168.100.1)")
                Spacer()
                Button("Quit Starlink Menu Bar") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(20)
        .background {
            // A menu-bar-only app has no menu bar to provide ⌘W.
            Button("Close") { NSApp.keyWindow?.close() }
                .keyboardShortcut("w")
                .opacity(0)
                .allowsHitTesting(false)
        }
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()                  // it may have been changed in System Settings meanwhile
        }
    }
}

/// "Open at login" through `SMAppService.mainApp`, the standard mechanism since macOS 13: the app is listed
/// in System Settings › General › Login Items, where the user can also turn it off.
@MainActor @Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    var note: String? {
        if let error { return error }
        if needsApproval { return "macOS needs your approval: turn on Starlink Menu Bar in Login Items." }
        return nil
    }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = Bundle.main.bundleIdentifier == nil
                ? "Only available when run as the app bundle (build-app.sh), not from swift run."
                : "Couldn't \(on ? "add" : "remove") the login item: \(error.localizedDescription)"
        }
        refresh()
    }
}
