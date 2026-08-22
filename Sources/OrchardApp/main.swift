import AppKit
import SwiftUI
import DamsonTerminal
import OrchardCore
import OrchardRuntime

// Orchard v2 — minimal booting shell. Proves the app target links DamsonTerminal and
// hosts the (in-process) runtime modules; T5 replaces the placeholder content with the
// real workspace-card sidebar and tab-group workbench.
//
// The binary/target is `OrchardApp` (a bare `Orchard` product collides with the
// `orchard` CLI on case-insensitive filesystems); the user-visible identity is still
// "Orchard.app" — the trampoline below materializes the bundle under that name.

// Relaunch inside Orchard.app (own icon/dock identity) before any GUI work.
OrchardTrampoline.relaunchInAppBundleIfNeeded()

let app = NSApplication.shared
let appDelegate = OrchardAppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()

final class OrchardAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Orchard is a dark-only app: every built-in agent theme is dark, and a light
            // sidebar wrapped around a dark terminal reads as a rendering bug.
            NSApp.appearance = NSAppearance(named: .darkAqua)

            let hosting = NSHostingController(
                rootView: PlaceholderRootView().preferredColorScheme(.dark))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Orchard"
            win.setContentSize(NSSize(width: 1180, height: 760))
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.appearance = NSAppearance(named: .darkAqua)
            win.center()
            win.makeKeyAndOrderFront(nil)
            self.window = win
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Sidebar/detail placeholder for the T5 shell. The detail pane hosts a live
/// `DamsonTerminalView` running a login shell — a boot-time proof that the app target
/// links and drives the damson engine, not just imports it.
struct PlaceholderRootView: View {
    @State private var session: DamsonSession = {
        var config = DamsonConfig()
        config.argv = DamsonConfig.defaultArgv()
        config.env = DamsonConfig.defaultEnv()
        return DamsonSession(config: config)
    }()

    var body: some View {
        NavigationSplitView {
            List {
                Section("Workspaces") {
                    Label("Orchard v2 skeleton", systemImage: "leaf")
                    Text("Workspace cards land in T5")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            DamsonTerminalView(session: session)
                .padding(4)
        }
    }
}
