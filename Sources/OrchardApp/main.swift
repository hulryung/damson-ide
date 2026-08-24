import AppKit
import SwiftUI
import DamsonTerminal
import OrchardCore
import OrchardRuntime
import OrchardTerminals

// Orchard v2 app shell (T5). The target/product is `OrchardApp` because a bare
// `Orchard` product collides with the `orchard` CLI on a case-insensitive
// filesystem; OrchardTrampoline still materializes the user-visible Orchard.app.

// T23: when this binary was exec'd as a per-generation keeper copy
// (`__orchard-keeper <generation>`), it becomes the PTY-holding daemon and never
// reaches any AppKit/trampoline setup. Must run before everything else.
KeeperDaemon.runIfInvoked()

OrchardTrampoline.relaunchInAppBundleIfNeeded()

let app = NSApplication.shared
let appDelegate = OrchardAppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()

final class OrchardAppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore!
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var orchestrationWindow: NSWindow?
    private var automationsWindow: NSWindow?
    private var vaultWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.appearance = NSAppearance(named: .darkAqua)

            let store = AppStore(settings: OrchardSettings())
            self.store = store
            // T23: consume any keeper restoration state before projects open (hook
            // ports rebind at supervisor start), then adopt the surviving PTYs once
            // the projects and the terminal registry are up.
            KeeperRestart.prepareBoot(store: store)
            store.restore()
            KeeperRestart.completeBoot(store: store)
            store.focusMainWindow = { [weak self] in
                self?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            store.showDashboard = { [weak self] in
                MainActor.assumeIsolated { self?.showDashboard(nil) }
            }
            store.showOrchestration = { [weak self] in
                MainActor.assumeIsolated { self?.showOrchestration(nil) }
            }
            store.showAutomations = { [weak self] in
                MainActor.assumeIsolated { self?.showAutomations(nil) }
            }
            store.showVault = { [weak self] in
                MainActor.assumeIsolated { self?.showVault(nil) }
            }
            store.showSettings = { [weak self] in
                MainActor.assumeIsolated { self?.showSettings(nil) }
            }
            buildMenu()

            let hosting = NSHostingController(
                rootView: RootView()
                    .environmentObject(store)
                    .preferredColorScheme(.dark))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Orchard"
            win.setContentSize(NSSize(width: 1180, height: 760))
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // No window tabs: macOS otherwise adds its own "+" (new window tab)
            // beside the toolbar's New Worktree "+", reading as a duplicate.
            win.tabbingMode = .disallowed
            win.appearance = NSAppearance(named: .darkAqua)
            win.titlebarAppearsTransparent = false
            win.center()
            win.makeKeyAndOrderFront(nil)
            self.window = win
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // T23: hand live PTYs to the keeper BEFORE shutdown terminates anything.
            // Released sessions' terminate() no-ops, so shutdownAll stays unchanged.
            if let store { KeeperRestart.handOffAtQuit(store: store) }
            store?.shutdownAll()
        }
    }

    @MainActor @objc func newWorkspace(_ sender: Any?) { store.addProjectViaPanel() }
    @MainActor @objc func openRemote(_ sender: Any?) { store.presentOpenRemote() }
    @MainActor @objc func newWorktree(_ sender: Any?) { store.requestNewWorktree() }
    @MainActor @objc func openJumpPalette(_ sender: Any?) { store.isJumpPaletteOpen = true }
    @MainActor @objc func showTerminalTab(_ sender: Any?) { store.selectKind(.terminal) }
    @MainActor @objc func showDiffTab(_ sender: Any?) { store.selectKind(.diff) }
    @MainActor @objc func showEditorTab(_ sender: Any?) { store.selectKind(.editor) }
    @MainActor @objc func showBrowserTab(_ sender: Any?) { store.selectKind(.browser) }
    @MainActor @objc func splitRight(_ sender: Any?) { store.splitFocused(axis: .horizontal) }
    @MainActor @objc func splitDown(_ sender: Any?) { store.splitFocused(axis: .vertical) }
    @MainActor @objc func toggleChatView(_ sender: Any?) { store.toggleFocusedViewMode() }
    @MainActor @objc func refreshDiff(_ sender: Any?) {
        if let record = store.selectedRecord { Task { await record.refresh() } }
    }
    @MainActor @objc func saveFocusedEditor(_ sender: Any?) { store.saveFocusedEditor() }

    @MainActor @objc func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: SettingsView(settings: store.settings)
                .environmentObject(store)
                .preferredColorScheme(.dark))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Settings"
        win.styleMask = [.titled, .closable]
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func showDashboard(_ sender: Any?) {
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: AgentDashboardView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Agent Dashboard"
        win.setContentSize(NSSize(width: 960, height: 520))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        dashboardWindow = win
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func showOrchestration(_ sender: Any?) {
        if let orchestrationWindow {
            orchestrationWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: OrchestrationView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Orchestration"
        win.setContentSize(NSSize(width: 1040, height: 620))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        orchestrationWindow = win
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func showAutomations(_ sender: Any?) {
        if let automationsWindow {
            automationsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: AutomationsView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Automations"
        win.setContentSize(NSSize(width: 1040, height: 620))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        automationsWindow = win
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func showVault(_ sender: Any?) {
        if let vaultWindow {
            vaultWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: VaultView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Vault"
        win.setContentSize(NSSize(width: 1080, height: 640))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        vaultWindow = win
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func zoomAllIn(_ sender: Any?) { surfaces().forEach { $0.zoomIn(nil) } }
    @MainActor @objc func zoomAllOut(_ sender: Any?) { surfaces().forEach { $0.zoomOut(nil) } }
    @MainActor @objc func resetAllZoom(_ sender: Any?) { surfaces().forEach { $0.resetZoom(nil) } }

    private func surfaces() -> [DamsonSurfaceView] {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        guard let root = window?.contentView else { return [] }
        var found: [DamsonSurfaceView] = []
        func walk(_ v: NSView) {
            if let s = v as? DamsonSurfaceView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Orchard", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Orchard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let nwt = NSMenuItem(title: "New Worktree…", action: #selector(newWorktree(_:)), keyEquivalent: "n")
        nwt.target = self
        fileMenu.addItem(nwt)
        let nw = NSMenuItem(title: "Open Project…", action: #selector(newWorkspace(_:)), keyEquivalent: "o")
        nw.keyEquivalentModifierMask = [.command, .shift]
        nw.target = self
        fileMenu.addItem(nw)
        let remote = NSMenuItem(title: "Open Remote…", action: #selector(openRemote(_:)), keyEquivalent: "")
        remote.target = self
        fileMenu.addItem(remote)
        fileMenu.addItem(.separator())
        let save = NSMenuItem(title: "Save", action: #selector(saveFocusedEditor(_:)), keyEquivalent: "s")
        save.target = self
        fileMenu.addItem(save)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goItem.submenu = goMenu
        let jump = NSMenuItem(title: "Jump…", action: #selector(openJumpPalette(_:)), keyEquivalent: "j")
        jump.target = self
        goMenu.addItem(jump)
        let dash = NSMenuItem(title: "Agent Dashboard", action: #selector(showDashboard(_:)), keyEquivalent: "d")
        dash.keyEquivalentModifierMask = [.command, .shift]
        dash.target = self
        goMenu.addItem(dash)
        let orch = NSMenuItem(title: "Orchestration", action: #selector(showOrchestration(_:)), keyEquivalent: "")
        orch.target = self
        goMenu.addItem(orch)
        let autos = NSMenuItem(title: "Automations", action: #selector(showAutomations(_:)), keyEquivalent: "")
        autos.target = self
        goMenu.addItem(autos)
        let vault = NSMenuItem(title: "Vault", action: #selector(showVault(_:)), keyEquivalent: "")
        vault.target = self
        goMenu.addItem(vault)
        goMenu.addItem(.separator())
        for (index, item) in [
            ("Terminal", #selector(showTerminalTab(_:))),
            ("Diff", #selector(showDiffTab(_:))),
            ("Editor", #selector(showEditorTab(_:))),
            ("Browser", #selector(showBrowserTab(_:))),
        ].enumerated() {
            let menuItem = NSMenuItem(title: item.0, action: item.1, keyEquivalent: "\(index + 1)")
            menuItem.target = self
            goMenu.addItem(menuItem)
        }
        goMenu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Diff", action: #selector(refreshDiff(_:)), keyEquivalent: "r")
        refresh.target = self
        goMenu.addItem(refresh)

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(DamsonSurfaceView.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(DamsonSurfaceView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(DamsonSurfaceView.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let splitR = NSMenuItem(title: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "\\")
        splitR.target = self
        viewMenu.addItem(splitR)
        let splitD = NSMenuItem(title: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "\\")
        splitD.keyEquivalentModifierMask = [.command, .shift]
        splitD.target = self
        viewMenu.addItem(splitD)
        viewMenu.addItem(.separator())
        let toggleChat = NSMenuItem(title: "Toggle Chat View", action: #selector(toggleChatView(_:)),
                                    keyEquivalent: "j")
        toggleChat.keyEquivalentModifierMask = [.command, .shift]
        toggleChat.target = self
        viewMenu.addItem(toggleChat)
        viewMenu.addItem(.separator())
        let zai = NSMenuItem(title: "Zoom All In", action: #selector(zoomAllIn(_:)), keyEquivalent: "=")
        zai.keyEquivalentModifierMask = [.command, .option]
        zai.target = self
        viewMenu.addItem(zai)
        let zao = NSMenuItem(title: "Zoom All Out", action: #selector(zoomAllOut(_:)), keyEquivalent: "-")
        zao.keyEquivalentModifierMask = [.command, .option]
        zao.target = self
        viewMenu.addItem(zao)
        let zar = NSMenuItem(title: "Reset All Zoom", action: #selector(resetAllZoom(_:)), keyEquivalent: "0")
        zar.keyEquivalentModifierMask = [.command, .option]
        zar.target = self
        viewMenu.addItem(zar)

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
