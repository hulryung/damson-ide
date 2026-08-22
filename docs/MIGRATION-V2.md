# v1 → v2 migration record (T0)

Executed per `docs/REBUILD-PLAN.md` §T0 and `docs/research/orchard-assets.md`. Every
move is a `git mv` (history preserved); "no behavior change" below means the only edits
were module imports. `swift build` and `swift test` are green at the end of this series.

## Naming deviation (approved by the coordinator)

The plan called for executable products `Orchard` (app) and `orchard` (CLI). On a
case-insensitive filesystem (macOS default) those are the **same path** — both as
`Sources/Orchard` vs `Sources/orchard` and as the `.build/<config>/` output binary —
and the two link steps clobber each other (verified: `ld: symbol(s) not found` from the
interleaved links). Resolution:

- The agent-facing CLI keeps the contract name exactly: product/target **`orchard`**
  at `Sources/orchard/` (preambles and guides embed this name).
- The app target/product is **`OrchardApp`** at `Sources/OrchardApp/`.
  `OrchardTrampoline` still materializes the bundle as **Orchard.app** with display
  name "Orchard", so the user-visible identity is unchanged.
- `docs/REBUILD-PLAN.md`'s module-layout section was updated accordingly
  (T5's ownership is `Sources/OrchardApp/**`).

## Dependency change

- damson pin: revision `e4d14f9` → **`from: "0.4.1"`** (63 commits ahead; everything v2
  needs — spawnPane/listAgents/paneInfo, SessionIOBackend.foregroundPID, keeper stack —
  landed after the old pin; v0.4.1 no longer declares colliding Orchard targets).
  `DamsonSession(config:)` still exists as a convenience init at 0.4.1.
- No new external dependencies. The transitive Sparkle drag remains (damson declares
  it); nothing here uses it.

## Moved — no behavior change (KEEP assets)

| v1 (`Sources/DamsonOrchestrator/`) | v2 | Edits |
|---|---|---|
| `GitRunner.swift` | `Sources/OrchardCore/Git/` | none |
| `GitService.swift` | `Sources/OrchardCore/Git/` | none |
| `WorktreeManager.swift` | `Sources/OrchardCore/Worktrees/` | none |
| `WorktreeNaming.swift` | `Sources/OrchardCore/Worktrees/` | none |
| `OrchardProjectConfig.swift` | `Sources/OrchardCore/Config/` | none |
| `SetupRunner.swift` | `Sources/OrchardCore/Config/` | none |
| `AgentRuntimeState.swift` | `Sources/OrchardCore/Support/` | none (moved to Core so `OrchardEvent` can carry agent states without a damson-adjacent import) |
| `AgentEngine.swift` | `Sources/OrchardTerminals/` | `import OrchardCore` |
| `ClaudeCodeEngine.swift` | `Sources/OrchardTerminals/` | `import OrchardCore` |
| `GenericShellEngine.swift` | `Sources/OrchardTerminals/` | none |
| `AgentTask.swift` | `Sources/OrchardTerminals/` | none (kept as the engine-facing work shape only; the real v2 Task noun is T1's SQLite row) |
| `HookServer.swift` | `Sources/OrchardTerminals/` | none |
| `HookInstaller.swift` | `Sources/OrchardTerminals/` | none |
| `ReadinessDetector.swift` | `Sources/OrchardTerminals/` | `import OrchardCore` |
| `ReadinessSnapshot.swift` | `Sources/OrchardTerminals/` | `import OrchardCore` |

## Rewritten (moved + reshaped)

- **`AgentSession.swift`** → `Sources/OrchardTerminals/AgentSession.swift`. Rewritten
  against the new **`TerminalSession` protocol** (12 members: write, gridSnapshot,
  config get/update, terminate, processExited, exitCode, bracketedPasteEnabled,
  hasRunningForegroundJob, gridChanged, outputEvents, onExit) instead of a concrete
  `DamsonSession`. Detection logic (tiers, interrupt inference, freshness, auto-response
  gating, prompt delivery framing) is unchanged; grid scraping goes through
  `TerminalGridSnapshot`. `DamsonTerminalSession` (new) is the one production adapter.
- **`OrchestratorController.swift`** (510 lines) → **deleted**, split into:
  - `Sources/OrchardCore/Worktrees/WorktreeService.swift` — headless
    create/restore/delete/setup, naming defaults + overrides, deletion preflight,
    primary-checkout status. Zero damson imports.
  - `Sources/OrchardTerminals/AgentSupervisor.swift` — spawn engine in a worktree,
    login-shell argv wrapping, env scrubbing, hook install + hook-event routing,
    prompt-once-on-first-idle, retire/shutdown.
  - The 4 UI callbacks (`onAgentSpawned/onAgentRetired/onError/onAgentNeedsAttention`)
    and theme glue (`applyTheme`, `applyTerminalConfig`, `configTemplate` presentation
    copying) are **deleted**; both services expose an `AsyncStream<OrchardEvent>`
    (`Sources/OrchardCore/Support/OrchardEvent.swift`, new) instead.
  - The scheduler block (`schedule()`, `maxConcurrency`, `activeAgentCount`,
    `newInteractiveAgent`, `enqueue`) is **deleted with no replacement** — v2 has no
    scheduler by design (damson's "do not build" list; coordinators drive the loop).
- **`WorktreeRecord.swift`** → `Sources/OrchardCore/Worktrees/WorktreeRecord.swift`.
  Same shape/vocabulary (`SetupState`, `WorktreeDisplayState`, cached status,
  refresh-off-main), but no longer holds a live `AgentSession` (that coupled core to the
  terminal layer). The agent layer mirrors state into `agentState:
  AgentRuntimeState?`; T4 extends the record with persisted `WorktreeMeta`.

## Salvaged from the deleted v1 app

- `Orchard/JumpPalette.swift:155–204` (`PaletteRanking`) →
  `Sources/OrchardCore/Support/PaletteRanking.swift`, generalized: caller supplies
  `(text, weight)` fields per item instead of hardcoding `PaletteItem`'s
  title/branch/repo. Algorithm (subsequence + contiguity/word-boundary bonuses +
  early-match bias) unchanged.
- `Orchard/OrchardTrampoline.swift` → `Sources/OrchardApp/OrchardTrampoline.swift`
  (unchanged; still materializes `~/Library/Caches/orchard/Orchard.app`).
- `Orchard/Resources/Orchard.icns` → `Sources/OrchardApp/Resources/Orchard.icns`.

## Deleted

- **v1 SwiftUI app** — the other 16 of `Sources/Orchard/*` (AgentGridView,
  AgentMetaViews, AgentStatusStyle, AgentTerminalView, DesignTokens, DiffPaneView,
  JumpPalette*, NewWorktreeComposer, OrchardControlDispatch, OrchardSettings,
  ProjectRootView, RootView, SettingsView, SidebarView, WorkspaceStore,
  WorktreeDetailView, WorktreeStatusStyle, main.swift). T5 rebuilds the shell on the
  new information architecture; `DiffPaneView`'s ideas (selection pinned across
  refreshes, loadToken staleness guard) are noted in the assets doc for that rebuild.
  This also removes the dead code named in the assets doc (`NoWorktreesView`,
  `StateSummary`, `requestAddTaskForSelected`, `focusedAgentID`).
- **`Sources/OrchardControl/`** (Wire.swift, ControlServer.swift) and
  **`Sources/orchard-cli/`** (v1 CLI). Replaced by the v2 control plane: T2 rebuilds
  the socket server on `OrchardProtocol`'s envelope; the socket-discovery/perms
  patterns worth lifting stay reachable in git history (also fixes the v1
  server-8s/client-5s timeout mismatch by construction).
- **`TaskQueue.swift`** and the scheduler block (see above), including its dead
  `removePending/reorderPending/allTasks`. `AgentTask` survives as a shape only.

## New seams (skeleton for wave 1)

- `Sources/OrchardProtocol/RPCEnvelope.swift` — `RPCRequest`/`RPCResponse`/`RPCError`/
  `RPCMeta` (wire key `_meta`) + dependency-free `JSONValue`.
- `Sources/OrchardProtocol/CommandSpec.swift` — `CommandSpec`/`FlagSpec`/
  `AgentContextDocument` + placeholder `CommandGroup` enum.
- `Sources/OrchardRuntime/Server/CommandHandler.swift` — `CommandHandler` protocol
  (`verbs`, `handle`) + `CommandRegistry` (build-once routing, `unknown_command`
  envelope for unclaimed verbs).
- `Sources/OrchardRuntime/Server/InMemoryRuntimeServer.swift` — socketless server stub
  stamping `_meta.runtimeId`, so wave-1 handlers are testable without a socket.
- `Sources/OrchardOrchestration/OrchardOrchestration.swift` — placeholder reserving the
  module for T1.
- `Sources/orchard/main.swift` — minimal CLI: `agent-context --json` (offline, from the
  spec table) and `version`; T2 adds the spec-driven parser + socket client.
- `Sources/OrchardApp/main.swift` — minimal booting shell (dark single window,
  placeholder sidebar, live `DamsonTerminalView` in the detail pane proving the damson
  link), trampoline retained.

## Tests

| v1 (`Tests/DamsonOrchestratorTests/`) | v2 | Notes |
|---|---|---|
| `WorktreeManagerTests.swift` | `Tests/OrchardCoreTests/` | import rename only |
| `GitServiceTests.swift` | `Tests/OrchardCoreTests/` | import rename only |
| `ProjectConfigAndNamingTests.swift` | `Tests/OrchardCoreTests/` | import rename; its `AgentEnvironmentTests` class moved to `Tests/OrchardTerminalsTests/AgentEnvironmentTests.swift` (the engines live there now) |
| `ReadinessDetectorTests.swift` | `Tests/OrchardTerminalsTests/` | import rename only |
| `TurnDetectionTests.swift` | `Tests/OrchardTerminalsTests/` | import rename only |
| `FingerprintAndModelTests.swift` | `Tests/OrchardTerminalsTests/` | import rename only |
| `ControllerOverrideTests.swift` | `Tests/OrchardCoreTests/WorktreeServiceTests.swift` | `ControllerOverrideTests` class re-targeted at `WorktreeService` (same assertions; the setup-gating test now exercises `runSetupScriptIfEnabled`). The damson-specific **`TerminalConfigTests` case is deleted** — it tested `applyTerminalConfig`, which died with the controller's theme glue. |

New: `Tests/OrchardRuntimeTests/ServerSeamTests.swift` (envelope `_meta` wire shape,
Codable round-trip, registry routing, unknown-verb envelope),
`Tests/OrchardOrchestrationTests/OrchardOrchestrationTests.swift` (placeholder).

Result: 74 tests, 0 failures.

## Half-finished v1 leftovers — carried forward *explicitly* (not silently)

Per the assets doc these must not slip through unnoticed; status after T0:

- `orchard.yaml` `archive:` — still parsed + tested, still never executed. **T4** wires
  it into deletion with `--run-hooks` semantics.
- OSC 133 prompt-mark path — `newPromptMarkSinceTaskStart` still hardcoded `false` in
  `AgentSession.makeSnapshot`. **T3** owns the real working-sequence plumbing.
- `AgentRuntimeState.awaitingInput` — still produced by no classifier (kept because the
  enum is Tier-1 hook vocabulary; **T3**'s richer status stream decides its fate).
- `GitService.commitAll`/`push` — still uncalled; kept for the T4/T5 review flow.
- `forceDeleteBranch` — now exposed on `WorktreeService`; **T5** decides whether the
  delete sheet offers it.
- v1 CLI↔server timeout mismatch — moot (that stack is deleted; T2 rebuilds with
  keepalive-aware timeouts).
