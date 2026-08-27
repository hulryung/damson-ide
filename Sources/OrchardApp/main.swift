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

final class OrchardAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: AppStore!
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var orchestrationWindow: NSWindow?
    private var automationsWindow: NSWindow?
    private var vaultWindow: NSWindow?
    private var spaceWindow: NSWindow?
    private var floatingWindow: NSWindow?
    /// T51: disabled app-menu row; title is refreshed from `runtimePresence`.
    private var appRuntimeMenuItem: NSMenuItem?

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
                MainActor.assumeIsolated { self?.orderFrontMainWindow() }
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
            store.showSpace = { [weak self] in
                MainActor.assumeIsolated { self?.showSpace(nil) }
            }
            store.showSettings = { [weak self] in
                MainActor.assumeIsolated { self?.showSettings(nil) }
            }
            store.showFloatingTerminal = { [weak self] in
                MainActor.assumeIsolated { self?.showFloatingTerminal(nil) }
            }
            store.hideFloatingTerminal = { [weak self] in
                MainActor.assumeIsolated { self?.floatingWindow?.orderOut(nil) }
            }
            buildMenu()

            createMainWindow()
            orderFrontMainWindow()
            refreshRuntimeIndication()
        }
    }

    /// T51: closing the workbench (or any auxiliary window) must not quit the
    /// process. The in-process runtime and its supervised workers stay up; Dock
    /// reopen / activation restore the workbench. Cmd-Q still terminates.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        WindowLifecycle.shouldTerminateAfterLastWindowClosed(hostsInProcessRuntime: true)
    }

    /// Dock icon / Finder reopen: always re-front the workbench, even when an
    /// auxiliary window is already visible. Workbench state lives on AppStore,
    /// so the same layouts/selection come back with the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard store != nil else { return }
            if WindowLifecycle.shouldOrderFrontMainWindow(
                mainWindowOnScreen: isMainWindowOnScreen(), trigger: .dockOrFinder) {
                orderFrontMainWindow()
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            // `activate` runs before `applicationDidFinishLaunching`; skip until
            // the store exists so we don't recreate a workbench with no runtime.
            guard store != nil else { return }
            if WindowLifecycle.shouldOrderFrontMainWindow(
                mainWindowOnScreen: isMainWindowOnScreen(),
                hasAnyVisibleWindow: hasAnyVisibleWindow(),
                trigger: .activation) {
                orderFrontMainWindow()
            }
            refreshRuntimeIndication()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        var title: String?
        MainActor.assumeIsolated {
            guard store != nil else { return }
            title = store.runtimePresence.menuTitle
        }
        guard let title else { return nil }
        let menu = NSMenu()
        let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show Orchard", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        return menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // T23: hand live PTYs to the keeper BEFORE shutdown terminates anything.
            // Released sessions' terminate() no-ops, so shutdownAll stays unchanged.
            // T51 must not run this path on window close — only Cmd-Q / Quit.
            if let store { KeeperRestart.handOffAtQuit(store: store) }
            store?.shutdownAll()
        }
    }

    @MainActor @objc func newWorkspace(_ sender: Any?) { store.addProjectViaPanel() }
    @MainActor @objc func openRemote(_ sender: Any?) { store.presentOpenRemote() }
    @MainActor @objc func newWorkbenchTab(_ sender: Any?) { store.addTabToFocusedGroup() }
    @MainActor @objc func closeFocusedTab(_ sender: Any?) { store.closeFocusedTab() }
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
    @MainActor @objc func showMainWindow(_ sender: Any?) { orderFrontMainWindow() }

    @MainActor @objc func showSettings(_ sender: Any?) {
        presentAuxiliaryWindow(
            existing: &settingsWindow,
            title: "Settings",
            styleMask: [.titled, .closable],
            role: .settings,
            rootView: SettingsView(settings: store.settings)
                .environmentObject(store)
                .preferredColorScheme(.dark))
    }

    @MainActor @objc func showDashboard(_ sender: Any?) {
        presentAuxiliaryWindow(
            existing: &dashboardWindow,
            title: "Agent Dashboard",
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            role: .dashboard,
            rootView: AgentDashboardView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
    }

    @MainActor @objc func showOrchestration(_ sender: Any?) {
        presentAuxiliaryWindow(
            existing: &orchestrationWindow,
            title: "Orchestration",
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            role: .orchestration,
            rootView: OrchestrationView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
    }

    @MainActor @objc func showAutomations(_ sender: Any?) {
        presentAuxiliaryWindow(
            existing: &automationsWindow,
            title: "Automations",
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            role: .automations,
            rootView: AutomationsView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
    }

    @MainActor @objc func showVault(_ sender: Any?) {
        presentAuxiliaryWindow(
            existing: &vaultWindow,
            title: "Vault",
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            role: .vault,
            rootView: VaultView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
    }

    @MainActor @objc func showSpace(_ sender: Any?) {
        presentAuxiliaryWindow(
            existing: &spaceWindow,
            title: "Space",
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            role: .space,
            rootView: SpaceView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
    }

    /// Always-on-top window bound to an existing pane. Close unbinds; the
    /// session stays with the pane (T71).
    @MainActor @objc func showFloatingTerminal(_ sender: Any?) {
        guard store.floatingTerminal != nil else { return }
        presentFloatingWindow()
    }

    /// T71: closing the floating window must not terminate the pane's session.
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard (notification.object as? NSWindow) === floatingWindow else { return }
            store.closeFloatingTerminal(orderOut: false)
        }
    }

    @MainActor @objc func zoomAllIn(_ sender: Any?) { surfaces().forEach { $0.zoomIn(nil) } }
    @MainActor @objc func zoomAllOut(_ sender: Any?) { surfaces().forEach { $0.zoomOut(nil) } }
    @MainActor @objc func resetAllZoom(_ sender: Any?) { surfaces().forEach { $0.resetZoom(nil) } }

    @MainActor
    private func createMainWindow() {
        guard window == nil else { return }
        let hosting = NSHostingController(
            rootView: RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Orchard"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // No window tabs: macOS otherwise adds its own "+" (new window tab)
        // beside the toolbar's New Worktree "+", reading as a duplicate.
        win.tabbingMode = .disallowed
        win.appearance = NSAppearance(named: .darkAqua)
        win.titlebarAppearsTransparent = false
        // The toolbar's New Worktree "+" was forcing the full-height unified titlebar.
        // Compact keeps the control and gives back the vertical space it was taking.
        win.toolbarStyle = .unifiedCompact
        win.isReleasedWhenClosed = false
        persistFrame(win, role: .main)
        self.window = win
    }

    /// T62: default size, then restore-or-center, then enable autosave.
    /// Must not run on the T51 reopen path — that reuses the same NSWindow.
    @MainActor
    private func persistFrame(_ window: NSWindow, role: WindowFrameAutosave.Role) {
        if let size = WindowFrameAutosave.defaultContentSize(for: role) {
            window.setContentSize(NSSize(width: size.width, height: size.height))
        }
        let name = WindowFrameAutosave.name(for: role)
        let restored = window.setFrameUsingName(name)
        if WindowFrameAutosave.shouldCenter(didRestoreSavedFrame: restored) {
            window.center()
        }
        window.setFrameAutosaveName(name)
    }

    /// T51 reuse: order-front the retained window. First creation this process
    /// applies T62 restore-or-center + autosave.
    @MainActor
    private func presentAuxiliaryWindow<Content: View>(
        existing: inout NSWindow?,
        title: String,
        styleMask: NSWindow.StyleMask,
        role: WindowFrameAutosave.Role,
        rootView: Content
    ) {
        switch WindowFrameAutosave.reopenStrategy(windowAlreadyCreated: existing != nil) {
        case .orderFrontExisting:
            existing?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        case .createAndRestore:
            break
        }
        let hosting = NSHostingController(rootView: rootView)
        let win = NSWindow(contentViewController: hosting)
        win.title = title
        win.styleMask = styleMask
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        persistFrame(win, role: role)
        win.makeKeyAndOrderFront(nil)
        existing = win
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func presentFloatingWindow() {
        let title = Self.floatingWindowTitle(store.floatingTerminal?.title ?? "Terminal")
        switch WindowFrameAutosave.reopenStrategy(windowAlreadyCreated: floatingWindow != nil) {
        case .orderFrontExisting:
            floatingWindow?.title = title
            applyFloatingLevel(floatingWindow)
            floatingWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        case .createAndRestore:
            break
        }
        let hosting = NSHostingController(
            rootView: FloatingTerminalView()
                .environmentObject(store)
                .preferredColorScheme(.dark))
        let win = NSWindow(contentViewController: hosting)
        win.title = title
        win.styleMask = [.titled, .closable, .resizable]
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.delegate = self
        persistFrame(win, role: .floatingTerminal)
        applyFloatingLevel(win)
        win.makeKeyAndOrderFront(nil)
        floatingWindow = win
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func applyFloatingLevel(_ window: NSWindow?) {
        guard FloatingTerminalPolicy.staysOnTop, let window else { return }
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = window.collectionBehavior.union(.canJoinAllSpaces)
    }

    private static func floatingWindowTitle(_ paneTitle: String) -> String {
        "\(paneTitle) — Floating"
    }

    @MainActor
    private func orderFrontMainWindow() {
        switch WindowFrameAutosave.reopenStrategy(windowAlreadyCreated: window != nil) {
        case .createAndRestore:
            createMainWindow()
        case .orderFrontExisting:
            break
        }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func isMainWindowOnScreen() -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    @MainActor
    private func hasAnyVisibleWindow() -> Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    @MainActor
    private func refreshRuntimeIndication() {
        appRuntimeMenuItem?.title = store.runtimePresence.menuTitle
    }

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

    @MainActor
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
        let runtimeItem = NSMenuItem(title: store.runtimePresence.menuTitle, action: nil, keyEquivalent: "")
        runtimeItem.isEnabled = false
        appMenu.addItem(runtimeItem)
        appRuntimeMenuItem = runtimeItem
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Orchard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let newTab = NSMenuItem(title: "New Tab", action: #selector(newWorkbenchTab(_:)), keyEquivalent: "t")
        newTab.target = self
        fileMenu.addItem(newTab)
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
        // ⌘W closes the tab, ⇧⌘W the window — the terminal-app pairing. Closing the
        // window on ⌘W read as "the app jumped somewhere else": since T51 the process
        // survives a closed window, so the workbench just disappeared.
        let closeTab = NSMenuItem(title: "Close Tab", action: #selector(closeFocusedTab(_:)), keyEquivalent: "w")
        closeTab.target = self
        fileMenu.addItem(closeTab)
        let closeWindow = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindow)

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
        let space = NSMenuItem(title: "Space", action: #selector(showSpace(_:)), keyEquivalent: "")
        space.target = self
        goMenu.addItem(space)
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
        // ⌘D splits side by side and ⇧⌘D splits below — the pairing iTerm2 and Warp
        // use, so the shortcut a terminal user already has in their fingers works here.
        let splitR = NSMenuItem(title: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "d")
        splitR.target = self
        viewMenu.addItem(splitR)
        let splitD = NSMenuItem(title: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "d")
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
        let showMain = NSMenuItem(title: "Show Orchard", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        showMain.target = self
        windowMenu.addItem(showMain)
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
