import AppKit
import SwiftUI
import DamsonTerminal
import OrchardControl

// Relaunch inside Orchard.app (own icon/dock identity) before any GUI work.
OrchardTrampoline.relaunchInAppBundleIfNeeded()

let app = NSApplication.shared
let appDelegate = OrchardAppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()

final class OrchardAppDelegate: NSObject, NSApplicationDelegate {
    private var store: WorkspaceStore!
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var controlServer: OrchardControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Orchard is a dark-only app. Pinning the appearance (rather than following the
            // system) keeps the chrome consistent with the terminal surfaces it frames —
            // every built-in agent theme is dark, and a light sidebar wrapped around a dark
            // terminal reads as a rendering bug. Every semantic color in `Tokens` resolves
            // through this, so nothing else has to know.
            NSApp.appearance = NSAppearance(named: .darkAqua)

            let store = WorkspaceStore(settings: OrchardSettings())
            self.store = store
            store.restore()
            startControlServer(store: store)
            buildMenu()

            NotificationCenter.default.addObserver(
                forName: .orchardShowSettings, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.showSettings(nil) }
                }

            let hosting = NSHostingController(
                rootView: RootView()
                    .environmentObject(store)
                    .preferredColorScheme(.dark))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Orchard"
            win.setContentSize(NSSize(width: 1180, height: 760))
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.appearance = NSAppearance(named: .darkAqua)
            // A unified dark titlebar rather than a light strip above a dark sidebar.
            win.titlebarAppearsTransparent = false
            win.center()
            win.makeKeyAndOrderFront(nil)
            self.window = win
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        MainActor.assumeIsolated { store?.shutdownAll() }
    }

    /// Start the orchard-cli control socket. The handler runs on a worker thread, so it hops
    /// to the main actor (where `store` lives) and waits briefly for the result.
    private func startControlServer(store: WorkspaceStore) {
        let server = OrchardControlServer()
        do {
            try server.start { command in
                var response = OrchardResponse.error("timed out")
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    response = MainActor.assumeIsolated { store.handle(command) }
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 8)
                return response
            }
            controlServer = server
        } catch {
            NSLog("orchard: control server failed to start: %@", String(describing: error))
        }
    }

    // MARK: - Menu actions

    /// Cmd-Shift-O — open another git repo as a project.
    @MainActor @objc func newWorkspace(_ sender: Any?) { store.addWorkspaceViaPanel() }
    /// Cmd-N — the primary action: create a worktree and start an agent in it.
    @MainActor @objc func newWorktree(_ sender: Any?) { store.requestNewWorktree() }
    /// Cmd-J — jump to any worktree across every open project.
    @MainActor @objc func openJumpPalette(_ sender: Any?) { store.isJumpPaletteOpen = true }
    /// Cmd-1/2/3 — switch the main pane between Agent, Diff, and Terminal.
    @MainActor @objc func showAgentTab(_ sender: Any?) { store.mainTab = .agent }
    @MainActor @objc func showDiffTab(_ sender: Any?) { store.mainTab = .diff }
    @MainActor @objc func showTerminalTab(_ sender: Any?) { store.mainTab = .terminal }
    /// Cmd-G — every agent terminal at once.
    @MainActor @objc func toggleGridOverview(_ sender: Any?) {
        store.showsGridOverview.toggle()
    }
    /// Cmd-R — re-read the selected worktree's diff.
    @MainActor @objc func refreshDiff(_ sender: Any?) {
        if let record = store.selectedWorktree { Task { await record.refresh() } }
    }

    /// Cmd-, — preferences. A single reused window: reopening Settings should return you to
    /// the tab you were on, not stack another copy.
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

    // Global zoom — apply to every agent terminal in the front window. (Per-terminal zoom
    // is handled by the plain Zoom In/Out items, which target the focused surface via the
    // responder chain.)
    @MainActor @objc func zoomAllIn(_ sender: Any?) { surfaces().forEach { $0.zoomIn(nil) } }
    @MainActor @objc func zoomAllOut(_ sender: Any?) { surfaces().forEach { $0.zoomOut(nil) } }
    @MainActor @objc func resetAllZoom(_ sender: Any?) { surfaces().forEach { $0.resetZoom(nil) } }

    /// Every terminal surface in the key/main window's view hierarchy.
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
        nw.keyEquivalentModifierMask = [.command, .shift]; nw.target = self
        fileMenu.addItem(nw)
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
        let jump = NSMenuItem(title: "Jump to Worktree…", action: #selector(openJumpPalette(_:)), keyEquivalent: "j")
        jump.target = self
        goMenu.addItem(jump)
        goMenu.addItem(.separator())
        for (index, item) in [("Agent", #selector(showAgentTab(_:))),
                              ("Diff", #selector(showDiffTab(_:))),
                              ("Terminal", #selector(showTerminalTab(_:)))].enumerated() {
            let menuItem = NSMenuItem(title: item.0, action: item.1, keyEquivalent: "\(index + 1)")
            menuItem.target = self
            goMenu.addItem(menuItem)
        }
        goMenu.addItem(.separator())
        let grid = NSMenuItem(title: "All Agents", action: #selector(toggleGridOverview(_:)), keyEquivalent: "g")
        grid.target = self
        goMenu.addItem(grid)
        let refresh = NSMenuItem(title: "Refresh Diff", action: #selector(refreshDiff(_:)), keyEquivalent: "r")
        refresh.target = self
        goMenu.addItem(refresh)

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        // Per-terminal: target the focused surface via the responder chain (nil target).
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(DamsonSurfaceView.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(DamsonSurfaceView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(DamsonSurfaceView.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        // Global: every terminal in the front window.
        let zai = NSMenuItem(title: "Zoom All In", action: #selector(zoomAllIn(_:)), keyEquivalent: "=")
        zai.keyEquivalentModifierMask = [.command, .option]; zai.target = self
        viewMenu.addItem(zai)
        let zao = NSMenuItem(title: "Zoom All Out", action: #selector(zoomAllOut(_:)), keyEquivalent: "-")
        zao.keyEquivalentModifierMask = [.command, .option]; zao.target = self
        viewMenu.addItem(zao)
        let zar = NSMenuItem(title: "Reset All Zoom", action: #selector(resetAllZoom(_:)), keyEquivalent: "0")
        zar.keyEquivalentModifierMask = [.command, .option]; zar.target = self
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
