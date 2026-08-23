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
            var config = template
            let cwd = spec.cwd ?? config.cwd
            config.cwd = cwd
            let task = AgentTask(title: spec.title ?? engine.displayName,
                                 prompt: spec.prompt,
                                 engineID: engine.id,
                                 baseRepoPath: "")
            config.argv = EngineLaunch.argv(
                engine: engine, task: task,
                worktree: URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath))
            // Engine env shaping first (e.g. Claude's inherited-session-marker
            // stripping), then the Orchard identity the agent uses to find us. The
            // handle is the value at spawn; after a remint the pane key remains the
            // durable identity — which is exactly why both are injected.
            var env = engine.env(base: config.env)
            env["ORCHARD_TERMINAL_HANDLE"] = spec.handle
            env["ORCHARD_PANE_KEY"] = spec.paneKey
            if let worktreeId = spec.worktreeId {
                env["ORCHARD_WORKTREE_ID"] = worktreeId
            }
            if let cli = context.cliCommand {
                env["ORCHARD_CLI_COMMAND"] = cli
            }
            if let dataPath = context.dataPath {
                env["ORCHARD_DATA_PATH"] = dataPath
            }
            config.env = env
            return DamsonTerminalSession(
                config: config,
                initialCols: spec.initialCols ?? TerminalSpawnDefaults.cols,
                initialRows: spec.initialRows ?? TerminalSpawnDefaults.rows)
        }
    }
}
