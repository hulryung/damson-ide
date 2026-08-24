import AppKit
import DamsonTerminal
import Foundation
import OrchardRuntime
import OrchardTerminals

/// T23 restart survival — the app-side quit/boot wiring around the keeper.
///
/// Clean quit: every live registered PTY is released from its session
/// (`releaseForKeeperHandoff`), handed to a freshly spawned per-generation keeper
/// (a copy of this very binary running `KeeperDaemon`), and a per-pane restoration
/// record is persisted. Next boot: the record is consumed (one-shot), the keeper's
/// inventory is claimed back, and each surviving PTY is adopted into the terminal
/// registry under the SAME paneKey with a bumped incarnation — agent panes rejoin
/// their project's supervisor so status detection re-attaches.
///
/// Deliberate limits (mirroring damson's docs/CLAUDE-ORCHESTRATION.md §3):
/// a LOCAL child that exited while held closes its pane (no respawn) — a remote pane
/// instead comes back disconnected and reconnectable (T43); Claude panes do NOT
/// auto-resume conversations (`/resume` stays human); a crash-quit writes nothing and
/// the next boot is exactly today's fresh boot. App-owned plain shell tabs
/// (`AppStore.shells`) have no registry identity and are not handed off.
@MainActor
enum KeeperRestart {
    /// Feature gate; default on. `defaults write app.damson.orchard
    /// orchard.keepSessionsOnRestart -bool NO` opts out.
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "orchard.keepSessionsOnRestart") as? Bool) != false
    }

    private static var pending: KeeperRestorationState?

    // MARK: - Quit side

    /// Hand every live registered PTY to a fresh keeper and persist the restoration
    /// state. Runs synchronously in `applicationWillTerminate`, BEFORE the store
    /// shutdown that would otherwise terminate the children (a released session's
    /// terminate() no-ops, so the existing shutdown path stays untouched).
    static func handOffAtQuit(store: AppStore) {
        guard enabled, let runtime = store.runtime else { return }
        var released = runtime.terminalService.releaseForKeeperHandoff()
        guard !released.isEmpty else { return }

        // Record each agent pane's hook-server port so the next boot can rebind it
        // (the port lives in the worktree's installed hook config, which the
        // surviving CLI keeps using).
        for i in released.indices {
            guard let repoPath = released[i].paneRecord.repoPath,
                  let project = project(in: store, repoPath: repoPath) else { continue }
            let port = project.agents.hookPort
            released[i].paneRecord.hookPort = port == 0 ? nil : port
        }

        let generation = KeeperPaths.mintGeneration()
        guard let executable = Bundle.main.executablePath,
              let sock = KeeperClient.spawnKeeper(generation: generation,
                                                  executablePath: executable) else {
            // Keeper unavailable: close the released masters. Last-close delivers
            // SIGHUP, so this degrades to exactly what a normal quit would have done.
            for pane in released { close(pane.handoff.fd) }
            return
        }
        let held = KeeperClient.sendHolds(
            socket: sock,
            holds: released.map { ($0.paneRecord.keeperUUID, $0.handoff) })
        close(sock)

        let panes = released.map(\.paneRecord).filter { held.contains($0.keeperUUID) }
        guard !panes.isEmpty else { return }
        let state = KeeperRestorationState(generation: generation, panes: panes)
        do {
            try KeeperRestorationStore.save(
                state, to: KeeperRestorationStore.defaultURL(dataDirectory: runtime.dataDirectory))
            NSLog("orchard: handed off %d pane(s), generation %@", panes.count, generation)
        } catch {
            NSLog("orchard: keeper restoration state save failed: %@", String(describing: error))
        }
    }

    // MARK: - Boot side

    /// Before `store.restore()`: consume the restoration file (one-shot — a crash
    /// mid-restore must not re-adopt) and hand the hook-port hints to the store so
    /// each project's supervisor can rebind its previous port when it starts.
    static func prepareBoot(store: AppStore) {
        guard let runtime = store.runtime else { return }
        let url = KeeperRestorationStore.defaultURL(dataDirectory: runtime.dataDirectory)
        guard let state = KeeperRestorationStore.loadAndDelete(at: url), enabled else { return }
        pending = state
        for pane in state.panes {
            guard let repoPath = pane.repoPath, let port = pane.hookPort else { continue }
            store.keeperHookPortHints[standardized(repoPath)] = port
        }
        // T43: the surviving `ssh` of a remote agent pane is still forwarding
        // `-R <remote>:127.0.0.1:<local>` to the port the PREVIOUS app instance's hook
        // server held. Nothing can re-point that forward — the child is not ours to
        // reconfigure — so the runtime's channel asks for that exact port back before
        // it binds. Losing the race is survivable and typed (the pane degrades to
        // fingerprint-only and says so); not asking would lose it every time.
        runtime.hookChannel.preferredPort = state.panes
            .compactMap { $0.remote?.tunnel?.localPort }
            .first { $0 != 0 }
    }

    /// After `store.restore()` (projects exist, supervisors are up): claim the
    /// keeper's inventory and adopt each surviving pane. A pane whose child exited
    /// while held is absent from the claim: a local one simply closes (no respawn),
    /// a remote one comes back as an ended connection that can be reopened.
    static func completeBoot(store: AppStore) {
        guard let state = pending else { return }
        pending = nil
        guard let runtime = store.runtime else { return }
        let claimed = KeeperClient.claim(generation: state.generation,
                                         wanted: state.panes.map(\.keeperUUID))

        for pane in state.panes {
            guard let adopted = claimed[pane.keeperUUID] else {
                adoptEndedRemotePane(pane, runtime: runtime, store: store,
                                     endingObserved: claimed.endingObserved(pane.keeperUUID))
                continue
            }
            var config = store.settings.terminalConfig()
            config.cwd = pane.cwd
            config.argv = pane.argv
            let terminal = DamsonTerminalSession(
                adopted: adopted, replayPreamble: pane.preamble, config: config,
                initialCols: pane.cols, initialRows: pane.rows)

            // Agent panes rejoin their project's supervisor, so tabs bind and the
            // hook/fingerprint status stack re-attaches (same token as before).
            var agent: AgentSession?
            if let repoPath = pane.repoPath,
               let project = project(in: store, repoPath: repoPath) {
                let worktree = pane.worktreePath.flatMap { path in
                    project.records.first { $0.worktree.path.path == path }?.worktree
                }
                agent = try? project.agents.adoptRestoredAgent(
                    engineID: pane.engineID, terminal: terminal,
                    worktree: worktree, title: pane.title, hookToken: pane.hookToken)
            }
            do {
                _ = try runtime.terminalService.adoptKeeperRestored(
                    pane: pane, session: terminal, agentSession: agent)
            } catch {
                // Dropping the session closes the adopted master — that child's pane
                // closes, everything else restores.
                NSLog("orchard: keeper adoption failed for pane %@: %@",
                      pane.paneKey, String(describing: error))
            }
        }
    }

    /// A pane the keeper could not hand back: its child ended while we were gone.
    ///
    /// For a local pane this is T23's documented limit and the pane simply closes.
    /// A remote pane is different in kind, not degree: what ended is a *connection*,
    /// and the design's rule 2 says loss of contact is never evidence that anything on
    /// the far side stopped. Closing it would erase the only local record that an
    /// agent was started in a named directory on a named machine — and erase it
    /// silently, as if nothing had been running. So it comes back inspectable,
    /// disconnected, and reconnectable.
    private static func adoptEndedRemotePane(_ pane: KeeperPaneRecord,
                                             runtime: OrchardRuntimeHost,
                                             store: AppStore,
                                             endingObserved: Bool) {
        guard pane.isRemote,
              let host = ExecutionHostId(rawValue: pane.executionHostId) else { return }
        var config = store.settings.terminalConfig()
        config.cwd = pane.cwd
        do {
            _ = try runtime.terminalService.adoptEndedRemote(pane: pane, config: config)
            // Which sentence the pane gets is decided here, because this is the only
            // place that knows whether the keeper ANSWERED. A keeper that reported this
            // child gone observed the ending; a keeper that never answered observed
            // nothing, and claiming an ending we did not see would invent exactly the
            // evidence rule 2 requires.
            store.noteEndedRemotePane(
                paneKey: pane.paneKey,
                note: endingObserved
                    ? RemotePaneRestoration.describeEndedWhileHeld(host: host)
                    : RemotePaneRestoration.describeHoldUnverifiable(host: host))
            NSLog("orchard: remote pane %@ restored without a connection (ending %@)",
                  pane.paneKey, endingObserved ? "observed" : "unverifiable")
        } catch {
            NSLog("orchard: could not restore ended remote pane %@: %@",
                  pane.paneKey, String(describing: error))
        }
    }

    // MARK: - Helpers

    private static func project(in store: AppStore, repoPath: String) -> ProjectSession? {
        let path = standardized(repoPath)
        return store.projects.first { $0.repo.standardizedFileURL.path == path }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
