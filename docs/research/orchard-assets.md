# Orchard v1 asset inventory — keep/discard map

Repo: `/Users/dkkang/dev/damson-ide`, 8,697 lines of Swift at commit `872e2bc`.
Targets: `DamsonOrchestrator` (engine, 3,120), `Orchard` (SwiftUI app, 3,888),
`OrchardControl` (350) + `orchard-cli` (157), tests (1,182).

**Headline: only 2 of 19 engine files import anything from damson** (`AgentSession.swift`,
`OrchestratorController.swift`). The consumed `DamsonSession` surface is ~11 members
(`write, grid, config, updateConfig, terminate, processExited, bracketedPasteEnabled,
hasRunningForegroundJob, gridChanged, outputEvents, onExit`) — one small `TerminalSession`
protocol decouples the whole engine.

## KEEP — clean engine assets (~2,600 lines + ~1,040 test lines)

| Path | Lines | Why |
|---|---|---|
| `DamsonOrchestrator/WorktreeManager.swift` | 487 | git-config-as-database persistence (`orchard.worktree.<uuid>.*` + `branch.<b>.base`), restore-from-git on relaunch (no app-side store to drift), `-2/-3` collision suffixes, base resolution `origin/main→origin/master→main→master`, fork pinned to a concrete SHA with `--no-track`, deletion preflight naming exactly what would be lost (`unpushedCommits == nil` means *no upstream*), `assertRemovable` path guards, `git branch -d` never `-D`, sharedPaths symlinking with escape guards, all `.git/worktrees` mutations serialized on one queue. Note: git lowercases trailing config keys — `baseRef` reads back as `baseref` (handled). |
| `DamsonOrchestrator/GitRunner.swift` | 133 | Hardened subprocess runner: absolute git path (GUI PATH), `GIT_TERMINAL_PROMPT=0` + `GIT_OPTIONAL_LOCKS=0`, concurrent stdout/stderr drain (sequential deadlocks on big diffs), 180s reader-based timeout, SIGTERM→SIGKILL. |
| `DamsonOrchestrator/GitService.swift` | 280 | All diffs vs the fork-point SHA (committed+uncommitted read as one change set), `-z` framing throughout, untracked-as-added with binary heuristic + 2MB cap, `commitsAhead`, `unpushedCommits: Int?` (nil = no upstream). Sendable value types. |
| `DamsonOrchestrator/HookServer.swift` | 133 | Loopback NWListener HTTP server, kernel-assigned port, per-agent unguessable token routing. Round-trip tested. |
| `DamsonOrchestrator/HookInstaller.swift` | 57 | Writes `<worktree>/.claude/settings.local.json` **merging** (owns only `hooks`); hook = `curl -sS -m 2 … \|\| true` (can never stall/fail the agent). Pair with `ensureExcluded(".claude/settings.local.json")` so it never appears in the agent's git status. Events: UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, SessionEnd. |
| `DamsonOrchestrator/ReadinessDetector.swift` + `ReadinessSnapshot.swift` | 224 | 3-tier fusion: externalSignal (hooks/OSC) > engine fingerprints > generic process signal; process-exit authoritative above all. Idle debounce ×2, 1.5s spawn floor, post-delivery race guard, approval-beats-idle, 30s external-signal freshness. Pure function over a Sendable snapshot — fully testable. |
| `DamsonOrchestrator/AgentEngine.swift` + `ClaudeCodeEngine.swift` + `GenericShellEngine.swift` | 356 | Plug-in protocol (launchArgv/env/promptDelivery/classify/hookEvents/hookSignal). `ClaudeCodeEngine.inheritedSessionMarkers` strips `CLAUDECODE, CLAUDE_CODE_CHILD_SESSION, CLAUDE_CODE_ENTRYPOINT, CLAUDE_CODE_SSE_PORT, CLAUDE_CODE_SESSION_ID` (hard-won). `ClaudeFingerprints` = maintained matcher set incl. DECSET-2026 sync-frame cadence; OSC 9999 tier; Ctrl-C idle inference (Claude emits no Stop on interrupt). |
| `DamsonOrchestrator/OrchardProjectConfig.swift` + `SetupRunner.swift` | 265 | Dependency-free YAML subset parser (block scalars, flow sequences, comments, quoting; `symlinkPaths` alias for orca compat) + hardened setup runner (`set -eo pipefail`, login shell, /dev/null stdin, 600s timeout, TERM→KILL, pipe drain). |
| `DamsonOrchestrator/WorktreeNaming.swift` | 70 | git-ref-safe sanitization, 60-char cap, name suggestions. |
| `OrchardControl/Wire.swift` + `ControlServer.swift`, `orchard-cli/main.swift` | 507 | Unix-socket discovery (`orchard-<uid>/<pid>.sock`, 0700/0600, ESRCH sweep), NDJSON envelope. Wire format evolves for v2 but the plumbing is sound. |
| `Orchard/JumpPalette.swift:157-204` (`PaletteRanking`) | ~45 | Pure subsequence fuzzy matcher (contiguity + word-boundary bonuses). |
| `Orchard/OrchardTrampoline.swift` | 89 | Self-materializes `~/Library/Caches/orchard/Orchard.app` for Dock identity + UNUserNotificationCenter without a packaging pipeline; `ORCHARD_NO_TRAMPOLINE=1` bypass. |
| Tests (5 of 6 files) | ~1,040 | Real-git fixture harnesses (WorktreeManager, GitService, ProjectConfig/Naming/Safety/Env), synthetic-snapshot detector tests, live HookServer round-trip. `TerminalConfigTests` case is damson-specific and dies. |

## REWRITE — entangled or wrong-shaped

| Path | Lines | Why |
|---|---|---|
| `Sources/Orchard/*` (17 files) | 3,888 | The v1 SwiftUI app. Single-selection over a flat worktree list; no cards/board, no dashboard, no file manager, no browser, no orchestration UI. Discard; salvage `DiffPaneView` ideas (selection pinned across refreshes, loadToken staleness guard), `PaletteRanking`, trampoline. |
| `DamsonOrchestrator/OrchestratorController.swift` | 510 | Half engine half app glue: schedule/spawn/setup/retire/delete/restore logic next to theme application + 4 UI callbacks + both damson imports. Split into headless services; replace callbacks with an AsyncStream of domain events. |
| `DamsonOrchestrator/AgentSession.swift` | 280 | The damson chokepoint (4Hz snapshot timer, grid scraping, prompt delivery, sendKey/interrupt). Extract `TerminalSession` protocol (~11 members) and rewrite against it. |
| `DamsonOrchestrator/WorktreeRecord.swift` | 141 | `@MainActor ObservableObject` view-model living in the engine (presentation vocabulary `WorktreeDisplayState`). Keep the shape, rewrite. |
| `DamsonOrchestrator/TaskQueue.swift` + scheduler block | ~85 | FIFO only; `while pending && active < maxConcurrency` — deliberately NOT the v2 model (see damson docs "do not build"). v2 has no scheduler: the coordinator agent drives, tasks form a DAG with deps. Keep `AgentTask` as a starting shape only. |
| `Orchard/OrchardControlDispatch.swift` | 246 | UI remote-control command dispatch. Replaced by the v2 runtime RPC. |

## Half-finished leftovers (do not carry forward silently)

- `orchard.yaml` `archive:` parsed + tested, never executed (delete flow never runs it).
- OSC 133 prompt-mark path designed but `newPromptMarkSinceTaskStart` hardcoded `false`.
- `AgentRuntimeState.awaitingInput` fully styled, produced by no classifier.
- `GitService.commitAll`/`push` documented "for the review flow"; no review flow calls them.
- `forceDeleteBranch` exists engine-side; the delete sheet never offers it.
- `AgentTask` doc-comment references a nonexistent `OrchestratorRun`; queue state lost on quit.
- Dead: `NoWorktreesView`, `StateSummary`, `requestAddTaskForSelected`, `focusedAgentID`,
  `TaskQueue.removePending/reorderPending/allTasks`.
- CLI↔server timeout mismatch: server 8s semaphore vs client 5s receive — slow commands
  surface as "server closed without response".

## Dependency note

`Package.swift` pins damson at revision `e4d14f9` — 63 commits stale (see
`docs/research/damson-surface.md`). Bump to `from: "0.4.1"`. `Package.resolved` also drags
Sparkle transitively; nothing here uses it.
