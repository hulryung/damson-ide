import Foundation
import DamsonTerminal
import OrchardCore

/// Builds an engine's final launch shape: argv wrapped in a login shell (so brew/PATH
/// resolve under a GUI launch) unless the engine already launches its own shell.
/// Shared by `AgentSupervisor` and the terminal-service factory so the two spawn
/// paths cannot drift.
public enum EngineLaunch {
    public static func argv(engine: AgentEngine, task: AgentTask, worktree: URL) -> [String] {
        let inner = engine.launchArgv(task: task, worktree: worktree)
        if engine.launchesOwnShell { return inner }
        let shell = DamsonConfig.loginShellPath()
        let cmd = "exec " + inner.map(shellQuote).joined(separator: " ")
        return [shell, "-l", "-c", cmd]
    }

    public static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Host facts injected into every managed PTY's environment, so an agent running
/// inside it can find the runtime (`ORCHARD_*` vars per docs/REBUILD-PLAN.md).
public struct TerminalHostContext: Sendable {
    /// How to invoke the agent-facing CLI from inside the PTY (e.g. "orchard").
    public var cliCommand: String?
    /// The runtime's data directory (`~/Library/Application Support/Orchard`).
    public var dataPath: String?

    public init(cliCommand: String? = nil, dataPath: String? = nil) {
        self.cliCommand = cliCommand
        self.dataPath = dataPath
    }
}

/// The production `TerminalSessionFactory`: spawns a `DamsonSession` for a create
/// spec, with the engine's argv/env shaping plus the `ORCHARD_*` identity injection.
public enum DamsonTerminalFactory {
    /// `template` carries presentation defaults (font/theme/scrollback); each spawn
    /// overlays argv/cwd/env on a copy.
    @MainActor
    public static func make(template: DamsonConfig = DamsonConfig(),
                            context: TerminalHostContext = TerminalHostContext()) -> TerminalSessionFactory {
        { spec, engine in
            let config = launchConfig(spec: spec, engine: engine,
                                      template: template, context: context)
            return DamsonTerminalSession(
                config: config,
                initialCols: spec.initialCols ?? TerminalSpawnDefaults.cols,
                initialRows: spec.initialRows ?? TerminalSpawnDefaults.rows)
        }
    }

    /// The argv/cwd/env the factory would spawn — extracted so tests can pin the
    /// remote-identity wrap without forking a real `ssh`.
    ///
    /// Called on every spawn, including respawn and `reconnectRemote`: the recorded
    /// spec keeps the unwrapped invocation (so keeper restoration and reconnect
    /// surgery still see the far-side command they persisted), and this reapplies
    /// the current handle/pane key at fork time.
    public static func launchConfig(spec: TerminalCreateSpec, engine: AgentEngine,
                                    template: DamsonConfig = DamsonConfig(),
                                    context: TerminalHostContext = TerminalHostContext()) -> DamsonConfig {
        var config = template
        let cwd = spec.cwd ?? config.cwd
        config.cwd = cwd
        let task = AgentTask(title: spec.title ?? engine.displayName,
                             prompt: spec.prompt,
                             engineID: engine.id,
                             baseRepoPath: "")
        // A spec-supplied argv wins: a remote agent pane is a Claude Code pane for
        // readiness and sends, but its PTY child is `ssh`, and the engine cannot
        // describe that launch (T39).
        var argv = spec.launchArgv ?? EngineLaunch.argv(
            engine: engine, task: task,
            worktree: URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath))
        let bindings = OrchardIdentity.bindings(spec: spec, context: context)
        // Local env is still set — a local pane reads it, and it is harmless on the
        // `ssh` client itself. For a remote pane it is not enough: ssh does not
        // forward these, so the far-side command line has to carry them (T78).
        if spec.isRemote {
            argv = OrchardIdentity.carryThroughSSH(argv: argv, bindings: bindings)
        }
        config.argv = argv
        // Engine env shaping first (e.g. Claude's inherited-session-marker
        // stripping), then the Orchard identity the agent uses to find us. The
        // handle is the value at spawn; after a remint the pane key remains the
        // durable identity — which is exactly why both are injected.
        var env = engine.env(base: config.env)
        OrchardIdentity.apply(bindings, to: &env)
        config.env = env
        return config
    }
}
