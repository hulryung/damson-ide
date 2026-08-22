# Damson library surface & gaps (for Orchard v2)

Surveyed from `/Users/dkkang/dev/damson` (Swift, macOS 13+, ~24.8k lines). Damson is the
GPU terminal app; Orchard consumes its library products.

## Products

| Product | Kind | Role |
|---|---|---|
| `DamsonTerminal` | library | VT parser + Grid + Metal renderer + PTY. A versioned contract for damson-ide. |
| `DamsonControl` | library | damson ↔ damson-cli IPC (NDJSON over unix socket). Reused by Orchard's control layer. |
| `damson` | executable | The terminal app (windows/tabs/splits, Sparkle, control-socket server). |
| `damson-cli` | executable | Control client only — sends one JSON command to a running app. |
| `damson-keeper` | executable | Daemon holding PTY master fds across app restarts (no SIGHUP). |

Non-product targets: `DamsonAgents` (Claude session badges, pane registry — deliberately
not exported), `DamsonKeeperCore`, `CFDPass` (SCM_RIGHTS fd passing).

## DamsonTerminal API Orchard uses / can use

**Session** — `DamsonSession` (`Sources/DamsonTerminal/DamsonSession.swift`, 720 lines):
- `init(config:restoredScrollback:[backend:])` — spawns the PTY **eagerly in init at 80×24**.
- `write(Data)` (programmatic input, queued, never dropped), `resize`, `updateConfig`,
  `terminate`, `foregroundProcessID` (tcgetpgrp), `currentWorkingDirectory`,
  `currentDirectory` (OSC 7), `hasRunningForegroundJob`, `promptMarks: [UInt64]` (OSC 133;A),
  `title`, `processExited`/`exitCode`.
- Keeper handoff: `releasePTYForHandoff() -> PTYHost.PTYHandoff?`, `stateRestorationPreamble()`.
- `SessionIOBackend` protocol — the injection seam (spawn/write/resize/terminate/
  childWorkingDirectory/isRunningForegroundJob/foregroundPID). `PTYHost` (forkpty backend)
  is public: `spawn`, `adopt(fd:pid:…)`, `releaseOwnership()`.

**Observation**:
- `outputEvents: PassthroughSubject<DamsonOutputEvent, Never>` — multi-subscriber, every
  parsed token: `.text`, `.execute`, `.csi(…)`, `.osc([String])`. **Every unhandled OSC still
  reaches subscribers** → private OSC protocols work with zero damson changes.
- `gridChanged: PassthroughSubject<Void, Never>` — multi-subscriber redraw signal.
- `onOutput: ((Data) -> Void)?` — raw pre-parse bytes, single clobberable closure (gap #2).
- Single-assignment callbacks: `onTitleChanged, onCwdChanged, onExit, onURLClick,
  onClipboardWrite, onBell (claimed by DamsonSurfaceView), onTmuxControlData`.

**Screen state** — `Grid` fully public: `cell(row:col:)`, `row(_:)`, `unifiedRow(_:)`,
`scrollback: [Line]` (Codable), `isAltScreenActive`, cursor pos/shape/visible,
`version: UInt64` (monotonic mutation counter), `debugDump()`. `SelectionLogic` incl.
**`lastCommandOutputRows`** (OSC 133-based last-command-output extraction).

**Views** — `DamsonTerminalView: NSViewRepresentable` (SwiftUI) wrapping
`DamsonSurfaceView: NSView` (`captureMetalImage() -> NSImage?`, find, zoom, copy/paste).
Headless use is supported: construct a `DamsonSession`, never attach a view, read `grid`.

**Config/theme**: `DamsonConfig` (font/theme/scrollback/argv/env/cwd; statics
`defaultEnv()`, `defaultArgv()`, `loginShellPath()`), `DamsonTheme` (built-in palettes),
`FontCascade`. `DamsonConfig.fromUserDefaults()` is app-side, not library-side.

**Renderer**: `TerminalRenderBackend` protocol is public but `MetalTerminalBackend` is
internal and constructed privately by `DamsonSurfaceView` — no offscreen/injectable
rendering (gap #5).

## DamsonControl (IPC)

Unix socket, one connection = one command = one NDJSON response, 5s timeouts, 16MB cap.
Discovery: `$XDG_RUNTIME_DIR/damson` → `$TMPDIR/damson-<uid>` → `/tmp/damson-<uid>`,
`<pid>.sock`, newest-mtime wins, `kill(pid,0)` liveness sweep.

`ControlCommandKind` (18): `newTab, split, switchTab, closeTab, listTabs, sendText,
sendKeys, resizeWindow, resizePane, focusPane, closePane, listPanes, dumpGrid, zoom,
applyLayout, spawnPane(SpawnSpec{split,cwd,argv,key}), listAgents, paneInfo`.
`PaneTarget {.active, .id(String)}` (wire key `"pane"`). `keyNameToBytes` (enter/tab/esc/
arrows/ctrl-a..z/f1..f12 → bytes) is useful standalone.

Server: `Damson.app` accept loop → main-actor dispatch with **2s semaphore timeout** (the
reason `SpawnSpec.key` idempotency exists — a timeout can report failure while the work
completes; retry without a key mints a second agent).

Separate `KeeperProtocol` (app ↔ keeper, fd passing via SCM_RIGHTS).

## docs/CLAUDE-ORCHESTRATION.md — the boundary and the traps

- **Scope**: "damson observes and addresses agents; it does not schedule them." Task
  boards/concurrency/worktrees belong to damson-ide.
- Agent status mechanism: pane → `tcgetpgrp` → pid → `~/.claude/sessions/<pid>.json` →
  status (`busy|shell|idle|waiting`+`waitingFor`), polled on a 3s timer (records are
  rewritten in place, so vnode watches freeze). Never wire the sweep to output/render
  callbacks.
- Splitting makes the NEW pane active → scripts must address panes by id, not focus.
- **"Do not build" list (respect in Orchard v2):**
  1. A scheduler that dequeues on `status: "idle"` — idle conflates finished / asked a
     clarifying question / never prompted. A real queue needs headless
     `-p --output-format stream-json` `result` messages.
  2. Screen-scraping the TUI as primary signal (fingerprints are a maintained set, not a
     protocol).
  3. Typing prompts into a live TUI expecting delivery acknowledgment — there is none;
     prompts go in argv (or use the full injection pipeline with verification, as Orca does).
  4. Impersonating iTerm2.
  5. Widening damson's PaneNode for non-terminal views.
- Launching a dev build from inside a Claude Code session inherits
  `CLAUDE_CODE_CHILD_SESSION` and silently suppresses badges — strip the env.

## Gaps (candidate damson-side fixes; user authorized damson changes)

1. **`--pane <id>` is honored for exactly one command** (`paneInfo`). `sendText, sendKeys,
   dumpGrid, zoom, resizePane, focusPane, closePane` all ignore the target and act on the
   active pane — the docs' own example silently misroutes. Plumbing exists on the wire;
   only dispatch needs it. **Highest-value damson fix.**
2. No multi-subscriber raw-bytes stream (`onOutput` is one clobberable closure). Add e.g.
   `outputBytes: PassthroughSubject<Data, Never>` — non-breaking.
3. No streaming/subscription channel over the control socket (strictly one-shot); no pane
   exit/title events outward. Out-of-process drivers must poll.
4. `dump-grid` returns only the visible viewport of the active pane, plain text (no
   scrollback/attributes/cursor). In-process consumers are fine (Grid is public).
5. Metal renderer not addressable offscreen (view-only).
6. Process-global `Cell.treatAmbiguousAsWide` set by every session init — last writer wins
   across the process. Hazard for per-worktree configs.
7. `DamsonSession.init` spawns eagerly at 80×24 — no lazy/deferred spawn or initial size.
8. `DamsonAgents` not exported (would have to reimplement the pid→session-json join, which
   is fine — Orchard has its own richer detection).
9. No pane-exit/alive field in `PaneInfo`.

## Versioning

Tags `v<semver>` (latest `v0.4.1`); pushing a tag runs the release workflow (sign,
notarize, dmg, appcast). **Orchard's pin `e4d14f9` is stale by 63 commits** — everything
Orchard v2 needs from damson (`spawnPane/listAgents/paneInfo`, `SessionIOBackend.
foregroundPID`, keeper stack, agent badges) landed after it. **Bump to `from: "0.4.1"`.**
(The pinned revision was chosen because earlier tags declared Orchard targets that collide
by module name; v0.4.1 no longer declares them.)
