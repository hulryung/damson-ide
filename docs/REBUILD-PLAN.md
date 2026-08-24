# Orchard v2 — rebuild plan

Orchard (this repo) is being rebuilt into a native-macOS equivalent of
[Orca](https://github.com/stablyai/orca): a multi-agent orchestrator IDE — orchestration
(runs/tasks/dispatch/messaging), workspace & worktree management, terminals, a file
manager, and embedded-browser integration — implemented in Swift on top of damson's
terminal engine.

Read before writing any code:

- `docs/research/orca-inventory.md` — the feature/semantics spec being replicated.
- `docs/research/damson-surface.md` — what the damson libraries provide; known gaps.
- `docs/research/orchard-assets.md` — which v1 code is kept vs rewritten.

Reference source on this machine (read-only): `~/dev/orca` (the product being matched),
`~/dev/damson` (the terminal engine).

## Product decisions

- **Native Swift/AppKit+SwiftUI, macOS 13+, Swift 5.9.** Terminal rendering stays on
  `DamsonTerminal` (bump pin to `from: "0.4.1"`).
- **Runtime-first architecture** (the key Orca lesson): a UI-free runtime owns worktrees,
  terminals, orchestration state, and an agent-facing control plane; the app is a client.
  v2 runs the runtime in-process inside the app; a headless `orchard serve` can come later
  because the boundary exists from day one.
- **App name stays `Orchard`; the agent-facing CLI becomes `orchard`** (replaces v1
  `orchard-cli`). Per-repo config stays `orchard.yaml` (keeps `symlinkPaths`/orca aliases).
- **No scheduler.** v1's FIFO queue is deleted. Coordinators are LLM agents driving the
  loop through the CLI (run/task/dispatch/check), exactly like Orca. This also follows
  damson's documented "do not build" list.
- **Local host only for now.** `ExecutionHostId` appears in the data model as `local`
  from day one, but SSH/remote hosts, federation, mobile, artifact/skill sharing,
  automations, and legacy-contract migration are explicitly out of scope for v2
  foundation.
- Storage (macOS): `~/Library/Application Support/Orchard/` →
  `orchard-data.json` (durable state), `orchestration.db` (SQLite via system `SQLite3`),
  `orchard-runtime.json` (runtime metadata; socket path, pid, authToken). Worktree *facts*
  keep v1's git-config persistence (better than a store that can drift); user-authored
  worktree meta (displayName, status, comment, links) lives in `orchard-data.json`.
- Wire: NDJSON frames over a unix socket, envelope
  `{id, ok, result | error:{code,message,data}, _meta:{runtimeId}}`, `{"_keepalive":true}`
  frames during long-polls. Env injected into every managed PTY:
  `ORCHARD_TERMINAL_HANDLE, ORCHARD_PANE_KEY, ORCHARD_WORKTREE_ID, ORCHARD_CLI_COMMAND,
  ORCHARD_DATA_PATH` (plus the existing setup-script vars).
- Agent self-documentation ships in the binary: `orchard agent-context --json` (full
  command table) and `orchard guide get <topic>` (version-matched usage guides).

## Module layout (targets in Package.swift)

```
Sources/
  OrchardCore/            # UI-free foundation (no damson import)
    Git/                  #   GitRunner, GitService                          [lifted]
    Worktrees/            #   WorktreeManager, WorktreeNaming, records/meta  [lifted+extended]
    Config/               #   OrchardProjectConfig, SetupRunner              [lifted]
    Support/              #   PaletteRanking, small shared utilities        [lifted]
  OrchardTerminals/       # terminal + agent layer (sole damson-importing library)
                          #   TerminalSession protocol + DamsonTerminalSession adapter,
                          #   AgentEngine/ClaudeCodeEngine/GenericShellEngine,
                          #   HookServer/HookInstaller, ReadinessDetector/Snapshot,
                          #   AgentSession (rewritten on the protocol), prompt injection
  OrchardOrchestration/   # SQLite store + orchestration semantics + dispatch preamble
  OrchardProtocol/        # Codable wire types + RPC envelope + command specs
                          #   (shared by runtime server and CLI; no other deps)
  OrchardRuntime/         # runtime assembly (imports all of the above)
    Server/               #   unix-socket NDJSON server, runtime metadata, handler registry
    Terminals/            #   terminal service + RPC handlers
    Workspaces/           #   workspace service (worktrees + folder workspaces) + handlers
    Orchestration/        #   orchestration RPC handlers (thin over OrchardOrchestration)
    Files/                #   file service + handlers (wave 2 fills this out)
  orchard/                # executable: the agent-facing CLI (client of the socket;
                          #   agent-context and guides work with no runtime)
  OrchardApp/             # executable: the app (SwiftUI shell; hosts OrchardRuntime
                          #   in-process; OrchardTrampoline retained). Named OrchardApp,
                          #   not Orchard: on a case-insensitive filesystem `Orchard` and
                          #   `orchard` are the same Sources/ path and the same .build
                          #   output binary (the link steps clobber each other), so the
                          #   app target/product is OrchardApp while OrchardTrampoline
                          #   keeps the user-visible bundle identity "Orchard.app".
                          #   T5's ownership is Sources/OrchardApp/**.
Tests/
  OrchardCoreTests/  OrchardTerminalsTests/  OrchardOrchestrationTests/  OrchardRuntimeTests/
```

Dependency rule: `OrchardCore ← {OrchardTerminals, OrchardOrchestration(?)} ←
OrchardRuntime ← {orchard, OrchardApp}`. (T12 revised the original thin-client rule: the
`orchard` executable links OrchardRuntime + OrchardTerminals so `orchard serve` can host
the runtime headless; the light paths — status, agent-context, guide — never construct it.)
Only `OrchardTerminals` and the `OrchardApp` app may import damson products.

## Work breakdown

Execution model: Orca orchestration Run; each task is one worker agent in its own git
worktree forked from `main`; the coordinator reviews and merges locally in order.
Tasks T1–T5 depend on T0. Merge order after review: T1 → T2 → T3 → T4 → T5.

### T0 — Skeleton & asset migration (exclusive; nothing else runs until merged)

Restructure the repo to the module layout above:

1. New `Package.swift`: all targets/products declared (even where directories start
   nearly empty); damson pinned `from: "0.4.1"`; executables `Orchard` and `orchard`.
2. Move the KEEP assets from `docs/research/orchard-assets.md` into their new targets
   (plain `git mv` + import fixes; no behavior changes).
3. Extract `TerminalSession` protocol (~11 members: write, grid access, config get/update,
   terminate, processExited/exitCode, bracketedPasteEnabled, hasRunningForegroundJob,
   gridChanged, outputEvents, onExit) in `OrchardTerminals`; implement
   `DamsonTerminalSession` adapter; rewrite `AgentSession` against the protocol.
   `OrchardCore` must compile with zero damson imports.
4. Split `OrchestratorController`: keep a headless `WorktreeService` (create/restore/
   delete/setup) and `AgentSupervisor` (spawn agent session in a worktree, hook install,
   readiness stream) in the appropriate targets; delete theme/UI-callback glue; expose an
   `AsyncStream<OrchardEvent>` of domain events instead of closures.
5. Delete: v1 `Sources/Orchard` app (all 17 files — salvage `PaletteRanking` →
   `OrchardCore/Support`, `OrchardTrampoline` → new app target), `OrchardControl`,
   `orchard-cli` (v1), `TaskQueue`, dead code listed in the assets doc.
6. Define the thin seams wave-1 tasks implement behind:
   - `OrchardProtocol`: `RPCRequest`/`RPCResponse` envelope Codables + a `CommandSpec`
     type (name, flags, summary) + placeholder command enums.
   - `OrchardRuntime/Server`: `CommandHandler` protocol
     (`verbs: [String]`, `handle(_ request:) async -> RPCResponse`) + a registry that the
     server routes through; a stub in-memory server so tests can exercise handlers without
     a socket.
7. New minimal `Orchard` app entry: single window, placeholder sidebar/detail, proving
   the app target links DamsonTerminal and boots.
8. Port the 5 surviving test files to the new module names; delete the damson-specific
   `TerminalConfigTests` case. `swift build` and `swift test` green.
9. Update `README.md` top section to describe v2 direction (link this plan); add
   `docs/MIGRATION-V2.md` recording every move/delete.

### T1 — Orchestration store & semantics (`OrchardOrchestration` + its tests)

Implement the Orca orchestration model per `docs/research/orca-inventory.md` §1 and §8:

- SQLite schema (system `SQLite3`, thin typed wrapper, WAL, all writes in transactions):
  runs, messages (monotonic `sequence`), deliveries (unique partial index: one
  `outstanding` per run), tasks (DAG `deps` JSON), dispatch_contexts, decision_gates,
  worker_dispatches, worker_terminal_resources, worker_terminal_archives,
  mutation_receipts, questions. Copy the enums verbatim.
- Semantics: FIFO delivery batching (cap 50) with verbatim replay until ack;
  consumer-generation fencing; `(taskId, dispatchId)`-keyed settlement with typed
  rejections (`unknown_task | unknown_dispatch | task_dispatch_mismatch |
  inactive_dispatch | stale_dispatch`); 3-failure circuit breaker; gates never
  auto-resolve + pending gate force-re-blocks its task; DAG readiness
  (`task-list --ready`); worker_done auto-completes task+dispatch; heartbeat staleness
  (10 min) computes a warning flag only; retry-request idempotency via mutation_receipts;
  group-address expansion at send time (one row per recipient, shared thread_id;
  forbidden for worker_done/heartbeat).
- Dispatch preamble builder (worker contract text with real IDs inlined, per §1.6,
  including the after-worker_done behavior split and the never-local-prompts rule).
- Long-poll support: an async wait primitive (`waitForMessage(types:timeout:)`) the RPC
  layer can call, resolved by message arrival.
- No damson import, no UI. Exhaustive unit tests (this is the correctness-critical
  module: batching/replay/fencing/settlement/circuit-breaker/gate-reblock at minimum).

Owns: `Sources/OrchardOrchestration/**`, `Tests/OrchardOrchestrationTests/**`.

### T2 — Control plane: runtime server + `orchard` CLI (`OrchardProtocol`, `OrchardRuntime/Server`, `Sources/orchard`)

- NDJSON unix-socket server: socket at `~/Library/Application Support/Orchard/run/` (or
  `$TMPDIR` fallback), 0700/0600 perms, runtime metadata file
  (`orchard-runtime.json` with runtimeId/pid/socket/authToken), auth-token check,
  one-connection-per-request, `{"_keepalive":true}` frames every 15s during long-polls,
  clean error envelope. Stale-socket sweep from v1's discovery code.
- Handler registry wiring (`CommandHandler` seam from T0); `status` command.
- The `orchard` CLI executable: arg parsing from declarative `CommandSpec`s (usable for
  `agent-context`), `--json` everywhere, human formatting otherwise; `agent-context`
  (serialize the full spec table, no runtime needed); `guide get <topic>` with an
  embedded orchestration guide (adapted from orca's, using `orchard` verbs);
  client transport with keepalive-aware timeouts.
- Orchestration RPC handlers (`OrchardRuntime/Orchestration/`): thin mapping of the §1.4
  verb set onto the T1 store API (agree the API surface with T1 through the seam types in
  the skeleton; coordinate via `ask` if a signature must change).
- Repo verbs backed by a simple repo registry in `orchard-data.json`:
  `repo list|add|show`.

Owns: `Sources/OrchardProtocol/**`, `Sources/OrchardRuntime/Server/**`,
`Sources/OrchardRuntime/Orchestration/**`, `Sources/orchard/**`,
`Tests/OrchardRuntimeTests/Server*`, `Tests/OrchardRuntimeTests/Orchestration*`.

### T3 — Terminal service (`OrchardTerminals` completion + `OrchardRuntime/Terminals`)

Per `docs/research/orca-inventory.md` §3:

- Terminal registry with the two-identity model: remintable `handle`
  (`term_<uuid>`) + durable `paneKey`; incarnation counters; per-worktree terminal lists;
  `RuntimeTerminalSummary`-shaped listing (handle, worktreeId, title, connected,
  lastOutputAt, preview tail).
- `read` with both sources: accumulated stream (ring buffer of parsed text with cursor
  paging) and `--screen` (rendered grid snapshot); result carries
  `source: stream|screen`.
- `send` via the full injection pipeline lifted to v2: ESC-sanitize → bracketed paste →
  chunked writes → submit `\r` after 500 ms → verify the agent left idle within 5 s
  (reuse ReadinessDetector state as the working-sequence); typed refusals
  (`no-agent | permission`), per-PTY serialization.
- `wait --for tui-idle|exit`: only `idle` satisfies tui-idle (`permission` does not);
  fast-path already-idle; resolve on any transition to idle; never clear the last-status
  record; reject immediately on PTY exit; default timeout.
- Agent status stream per terminal fusing the existing 3-tier detection; expose
  `AgentStatusEntry`-shaped snapshots (state, stateStartedAt, agentType, paneKey, …).
- Engines: extend the registry beyond Claude — `codex`, `grok`, `cursor-agent`, generic
  shell — launch argv + env + (where known) hook installation; keep Claude's
  env-marker stripping.
- RPC handlers for `terminal list|create|read|send|wait|split(stub ok)|close|rename`.

Owns: `Sources/OrchardTerminals/**` (post-T0 contents), `Sources/OrchardRuntime/Terminals/**`,
`Tests/OrchardTerminalsTests/**`, `Tests/OrchardRuntimeTests/Terminal*`.

### T4 — Workspace service (`OrchardCore/Worktrees` extension + `OrchardRuntime/Workspaces`)

Per `docs/research/orca-inventory.md` §2:

- Worktree identity `"<repoId>::<path>"`; repo registry (id, path, displayName, baseRef)
  persisted in `orchard-data.json`; keep git-config worktree facts from v1.
- `WorktreeMeta` (displayName, comment, workspaceStatus, isPinned/isUnread/isArchived,
  sortOrder, lastActivityAt, linkedIssue/PR as plain strings for now) in
  `orchard-data.json`; workspace-status vocabulary with the four defaults + custom.
- Folder workspaces as first-class peers projected into the same workspace shape
  (empty branch/head).
- Lineage records `{child, parent, origin: orchestration|cli|manual, capture
  confidence}`; `--no-parent` ⊥ base-branch, per the checklist.
- Name generation: keep v1 sanitization + collision suffixes; add a generated-name pool
  with **permanent retirement** persisted per repo.
- Deletion: keep v1 preflight; wire the `archive` script (v1 half-finish) with
  `--run-hooks` semantics.
- `worker-start`-shaped composition helper: create worktree (optionally agent-first) →
  wait agent readiness → return `{worktreeId, agentTerminalHandle}` — built on T0's
  `WorktreeService`/`AgentSupervisor` seams and the terminal service API (coordinate
  signatures via `ask` if needed; the RPC-level `worker-start` verb itself is wired in a
  short follow-up once T1–T4 merge).
- RPC handlers for `worktree list|show|current|create|set|rm` and JSON store
  load/save with atomic writes.

Owns: `Sources/OrchardCore/Worktrees/**` (post-T0), `Sources/OrchardRuntime/Workspaces/**`,
`Tests/OrchardCoreTests/**` (worktree parts), `Tests/OrchardRuntimeTests/Workspace*`.

### T5 — App shell v1 (`Sources/OrchardApp`)

Per `docs/research/orca-inventory.md` §6, dark-native like v1 but the new information
architecture:

- Left sidebar: repo/project groups → **workspace cards** (status slot from
  workspaceStatus, unread dot, branch, +N/−M, inline live-agent rows with state glyphs).
  Filters: repo, status; ordering manual|recent.
- Center workbench: per-workspace **tab groups with splits**; tab kinds `terminal` (hosts
  `DamsonTerminalView`), `diff` (port v1 DiffPaneView against OrchardCore GitService),
  placeholder kinds for `editor`/`browser` (wave 2).
- Agent dashboard window (kanban: attention | working | done | idle; click-to-focus).
- Jump palette (⌘J) over workspaces/agents using `PaletteRanking`.
- Composer (⌘N): name, prompt, engine (claude|codex|grok|cursor|shell), base branch,
  fan-out count.
- Settings (port v1's three groups; per-repo concurrency remains a display concern only —
  no scheduler).
- Drive everything through the runtime services (in-process), not private state; the app
  observes the domain-event AsyncStream.

Owns: `Sources/OrchardApp/**`.

### Wave 2 (T7–T10, parallel; merge order T7 → T8 → T9 → T10)

**T7 — Worker lifecycle verbs (runtime).** Implement the supervised-worker RPC surface
end to end: `worker-start` (compose T4's WorkerStart helper + T3 terminal readiness +
preamble injection, staged receipt with effects/failedStage), `worker-show`,
`worker-read` (archive or bounded live terminal output), `worker-stop`, `worker-abandon`,
`worker-release` (archive to worker_terminal_archives BEFORE closing; refuse unproven/
reused/user terminals), `worker-retain`, `worker-list`. Owns
`Sources/OrchardRuntime/Orchestration/Worker*` (new), `Sources/OrchardRuntime/Workspaces/
WorkerStart.swift`, additive public API on OrchardOrchestration worker tables, additive
OrchardTerminals reads, CLI worker-verb wiring, `Tests/OrchardRuntimeTests/Worker*`.

**T8 — Repo/project unification (app).** Make the runtime repo registry
(orchard-data.json) the single source of truth for the sidebar: Open Project… and
`orchard repo add` both land there and surface as sidebar projects live; one-time
migration of the UserDefaults `orchard.workspaces` list; project remove updates the
registry. Owns `Sources/OrchardApp/**` (core files) plus additive read/observe API on
`Sources/OrchardRuntime/Workspaces`.

**T9 — File manager.** Runtime file service (`readDir`, `preview` with byte budget +
binary/image detection, `stat`, `search`, name-filtered listing) under
`Sources/OrchardRuntime/Files/**`, CLI `file open|diff|open-changed` verbs, and a
right-sidebar explorer in the app under `Sources/OrchardApp/FileExplorer/**` (lazy tree
rooted at the selected worktree, dotfile toggle, name filter, reveal, open → diff tab
for changed files) with a minimal hook into the workbench chrome.

**T10 — Browser pane.** Per-workspace embedded browser: `BrowserWorkspace`/`BrowserPage`
model, WKWebView pane as a new workbench tab kind under `Sources/OrchardApp/Browser/**`,
runtime browser service under `Sources/OrchardRuntime/Browser/**`, and automation verbs
`browser goto|back|forward|reload|snapshot|click|fill|type|screenshot|eval|console|tab`
— snapshot walks the DOM via injected JS into a text outline with `@e1…` refs
(re-snapshot after navigation; stale refs are errors, not guesses). Page content is
untrusted data. CLI verbs additive.

Shared-territory rule for the wave: the `orchard` CLI spec table and OrchardApp chrome
accept additive edits from several tasks; keep them in per-feature files where possible
and expect the coordinator to resolve small merge conflicts.

### Wave 3 (T11–T14, parallel; merge order T11 → T12 → T13 → T14)

**T11 — Orchestration hardening (runtime).** Make v2's supervision trustworthy:
capability-hash enforcement on lifecycle `send` (a `worker_done`/`heartbeat`/`ask`
without the dispatch capability whose SHA-256 matches the stored hash — or from a
pane other than the assignee — is rejected with a typed settlement code);
worker-process-exit auto-escalation (terminal exit of a live supervised dispatch fails
it and posts a priority-high `escalation` to the Run, waking `check --wait`; deliberate
closes do not escalate); a real dogfood e2e test driving `worker-start --agent shell`
through the live runtime to settlement. Owns Sources/OrchardRuntime/Orchestration/**,
additive OrchardOrchestration/OrchardTerminals API, Tests/OrchardRuntimeTests/Worker*.

**T12 — `orchard serve` headless (control plane).** Boot OrchardRuntimeHost without
the GUI: `orchard serve [--data-dir <path>]` runs the socket server + services in the
foreground until SIGINT/SIGTERM (clean shutdown removes the socket + metadata);
headless terminal factory (DamsonSession renders nothing — sessions stay headless);
`status` reports mode app|headless; refuse to start when a live runtime already owns
the metadata file (stale metadata from a dead pid is reclaimed). Owns
Sources/orchard/** (serve entry), Sources/OrchardRuntime/Server/**, tests.

**T13 — Chat view-mode (app).** Per-tab `viewMode: terminal | chat` on agent tabs: a
native chat rendering of the agent conversation built from the terminal service's
AgentStatusEntry stream (prompts, last assistant message, state transitions), with an
input box that submits through the verified injection pipeline and falls back to the
raw terminal on demand; toggle in the tab chrome, state per tab. Owns
Sources/OrchardApp/** chat files + additive OrchardTerminals status-stream API.

**T14 — Search & watch (files).** Extend the file service: full-text content search
(bounded, include patterns, per-file match excerpts, binary skip), directory watching
with reconciliation events the explorer consumes (create/delete/rename reflected
without manual refresh), and auto-reveal of the active file. Owns
Sources/OrchardRuntime/Files/**, Sources/OrchardApp/FileExplorer/**, file CLI
additions, Tests/OrchardRuntimeTests/File*.

### Wave 4 (T15–T18, parallel; merge order T15 → T16 → T18; T17 lands in ~/dev/damson)

**T15 — Workspace projection & serve socket default (runtime).** Project every
registered repo's primary checkout (and folder workspaces) into the runtime workspace
registry as first-class workspaces keyed `repoId::path` (empty branch/head for folder
roots), so worktree selectors (`path:`, `name:`, `active`) resolve them everywhere —
`file search`, browser resolver, terminal create. Second fix: when the serve
`--data-dir` would push the socket path past the 104-byte sun_path limit, default the
socket into `$TMPDIR/orchard-<uid>/` while keeping data in the requested directory
(metadata records the real socket path). Owns Sources/OrchardRuntime/Workspaces/**,
Server/RuntimePaths*, tests.

**T16 — Automations (runtime + CLI).** Scheduled prompts per orca-inventory §7: an
automations store in orchard-data.json ({id, name, trigger hourly|daily|weekdays|weekly|
5-field-cron, time, day, provider agent, prompt, target repo (fresh worktree per run) or
workspace (reuse), bounded precheck command — exit 0 continues else records skipped},
a scheduler in the runtime host that fires due automations while it runs (app or serve),
run history with outcomes, and CLI `automations list|show|create|edit|remove|run|runs`.
Firing a repo-target automation composes the existing worker-start path with the
configured agent + prompt. Owns Sources/OrchardRuntime/Automations/** (new), CLI spec
additions, tests (trigger math incl. cron parse, due-run selection, precheck skip).

**T17 — damson-side fixes (in ~/dev/damson).** The authorized damson track, per
docs/research/damson-surface.md gaps: (1) honor `--pane <id>` for every pane-addressed
control command (send-text, send-keys, dump-grid, zoom, resize-pane, focus-pane,
close-pane), not just pane-info — the wire plumbing exists, only dispatch ignores it;
(2) add a multi-subscriber raw-output stream (`outputBytes` PassthroughSubject
alongside the clobberable `onOutput`), non-breaking; (3) optional deferred/initial-size
spawn for DamsonSession (init that takes cols/rows, or a lazy-spawn variant) without
changing existing call sites. Update docs/CLAUDE-ORCHESTRATION.md §2 accordingly.
Verification: damson's own `swift test` suite; all changes additive to the library
contracts. Lands on a branch in ~/dev/damson; the damson-ide pin bump waits for a
tagged damson release (user decision — tagging triggers the notarized release CI).

**T18 — Live dashboard & status polish (app).** Wire the T5 dashboard skeleton to the
real status stream: buckets attention|working|done|idle fed by AgentStatusEntry
transitions (permission ⇒ attention), click-to-focus routes to the owning workspace
tab, done cards stay highlighted until focused (existing unacked set), inline agent
rows on workspace cards get the same live states, and the workspace-status slot
supports the custom vocabulary from settings. Owns Sources/OrchardApp/** dashboard/
sidebar files; additive status-stream reads only.

### Wave 5 (T19–T22, parallel; merge order T19 → T20 → T21 → T22)

**T19 — Adopt damson @ 0483173 (terminals).** Pin damson by revision 0483173 (T17
merge: pane-addressed control, `outputBytes` multi-subscriber stream, sized spawn) and
adopt it: `DamsonTerminalSession`/factory spawn at the real initial pane size instead
of eating the 80×24 reflow (thread cols/rows through the terminal service and app
panes; default sensibly when unknown), and switch any raw-output consumers to the
multi-subscriber `outputBytes` where it removes single-closure contention. No behavior
change beyond spawn size; all tests stay green.

**T20 — Ports & status surface (runtime + app).** Detect listening TCP ports per
workspace (poll `lsof`-derived data for processes whose cwd/tree is inside the
worktree; debounced), expose `workspace ports` over RPC + `orchard worktree ps`-style
CLI listing, render a ports chip on workspace cards and a status-bar summary in the
app. Detection must be best-effort and cheap (no per-output-event hooks; timer sweep).

**T21 — Browser profiles & iframes (browser).** Session profiles: one profile ⇒ one
`WKWebsiteDataStore` partition (default shared + named isolated profiles; per
browser-workspace binding persisted in orchard-data.json; CLI `browser tab profile
list|create|set|show`). Snapshot iframes: walk same-origin child frames inline into
the outline (frame-scoped refs), mark cross-origin frames as opaque nodes. Refs still
invalidate on navigation.

**T22 — Review flow (app diff pane).** Grow the diff pane into the review flow v1
anticipated: grouped changed-file list (staged-ness irrelevant — fork-point diff),
hunk navigation (n/p), a commit box driving `GitService.commitAll` (finally used) with
the diff refreshing after, and a push action using `GitService.push` with upstream
state surfaced (ahead/no-upstream states from `unpushedCommits`). Keep it
worktree-scoped and observation-honest: failures surface inline with git's own stderr.

### Wave 6 (T23–T26, parallel; merge order T23 → T24 → T25 → T26)

**T23 — PTY restart survival (keeper adoption).** Adopt damson's keeper stack (public
since the 0483173 pin: `releasePTYForHandoff`, `PTYHost.adopt`,
`stateRestorationPreamble`, `KeeperProtocol`, the `damson-keeper` binary) so live agent
and shell PTYs survive an Orchard app restart: manage a per-generation keeper process,
hand off PTY masters on clean quit, persist per-pane restoration records (paneKey,
argv, cwd, scrollback preamble) in the session state, adopt on next boot back into the
terminal registry under the same paneKey with a bumped incarnation, and re-establish
agent status detection. Deliberate scope limits from damson's own docs: a dead child
closes its pane rather than respawning, and Claude panes do not auto-resume
conversations (`/resume` stays human). Crash-quit (no handoff) degrades to today's
behavior.

**T24 — Transcript pins & real guide (control plane).** worker-release archives are
terminal-tail-only; add provider transcript pinning: the hook payload's provider
session id (Claude) resolves to the transcript file, and release pins its content (or
bounded tail) into worker_terminal_archives as kind transcript_pin, with worker-read
preferring it. Second: replace the 6-line embedded `orchard guide get orchestration`
stub with the real version-matched contract (coordinator loop, worker duties,
delivery/ack semantics, worker-start receipts, capability rules) generated from one
source shared with the dispatch preamble so they cannot drift.

**T25 — Test stabilization & CI script.** Fix the FileWatcher flake (event
debounce/race under full-suite load), audit other timing-sensitive tests (scripted
waits, status-stream tests) for real synchronization instead of sleeps, and add
`scripts/ci.sh` = clean build + full test + release build, the exact merge-gate this
project uses.

**T26 — App polish pass.** Jump palette covers files (quickOpen paths) and commands;
unread markers propagate from agent activity to cards and dashboard consistently;
workspace card context menu (set status, archive/unarchive, reveal in Finder, delete
with the preflight sheet); settings panes for the new subsystems (ports sweep interval,
default browser profile, automations enable/disable). No new services — UI over
existing APIs.

### Wave 7 (T27–T30, parallel; merge order T27 → T30 → T28 → T29)

**T27 — `orchard terminal` CLI group.** Expose the existing terminal RPC verbs
(list/create/read/send/wait/close/rename; split stays not_implemented) as a top-level
`terminal` command with subcommand routing like repo/browser/file, full CommandSpec
flags (worktree selector, --screen/--cursor/--limit, --enter/--interrupt, --for
tui-idle|exit, --timeout-ms), human formatting for list/read, agent-context and the
embedded guide updated. Found missing during the T23 smoke (RPC works; CLI absent).

**T28 — Editor pane.** Make the workbench `editor` tab kind real: open a file in an
editable monospaced NSTextView wrapper (line/column in a thin footer, dirty dot in the
tab label, ⌘S saves via the file service's write path with git-status refresh, revert
on external change prompt), reachable from the explorer double-click, the jump
palette, and `file open-changed --mode edit`. Plain text first (no highlighting);
binary/oversized files fall back to the preview notice.

**T29 — SSH slice: design + host registry + remote terminal PoC.** Write
docs/design/remote-hosts.md following orca's ssh-execution-boundary rules (verdicts
live|unverifiable|exited; loss of contact is never death; ExecutionHostId on
everything). Implement the foundation: `orchard host list|add|check` backed by a host
registry in orchard-data.json (+~/.ssh/config name import), a BatchMode connectivity
probe, and a proof-of-concept remote terminal: terminal create --host ssh:<name>
spawns `ssh -tt <host>` in a local PTY with executionHostId stamped on the summary.
Remote worktrees/agents stay out of scope this wave.

**T30 — Terminal pane fit & feel.** Fix the half-clipped first row (grid is
bottom-anchored; top-align when content is shorter than the viewport), snap pane
content height to cell multiples where feasible so no partial rows render, and keep
scroll position stable across pane resizes. Work through DamsonSurfaceView/Grid
public API from the app container; damson-side changes only if additive and necessary
(ask first).

### Wave 8 (T31–T34, parallel; merge order T31 → T33 → T32; T34 is report-only)

**T31 — Adoption fit & restore polish.** Keeper-adopted panes bypass T30's
cell-snap/top-align fit (half-clipped first row after relaunch): route adopted panes
through the same TerminalPaneHost fit path on attach, re-apply on the first
grid-change after adoption, and audit the adoption path for other skipped setup
(status seeding, sized respawn geometry). Verify with a real quit/relaunch cycle and
screenshot; describe the visual result honestly.

**T32 — SSH stage 2: remote worktrees.** Per docs/design/remote-hosts.md: repos can
register with `--host ssh:<name>` (remote path probed over ssh), worktree
list/create/rm run their git operations through a bounded ssh runner (BatchMode,
timeouts, stderr surfaced; reuse GitRunner's hardening shape), remote worktrees
project into the workspace registry with executionHostId stamped, and creating a
terminal in a remote worktree opens `ssh -tt <host> cd <path> && exec $SHELL -l`.
Remote agents/keeper stay out of scope; file service returns typed
remote_unsupported for remote paths this wave.

**T33 — Editor syntax highlighting.** Lightweight regex/state-machine highlighter
(no external deps): Swift, JSON, YAML, Markdown, and shell first; token classes
(keyword/string/comment/number/type) mapped to theme colors; incremental
re-highlight of the edited line's neighborhood so typing stays smooth; large files
degrade to plain text past a budget. Language picked by extension; unit-test the
tokenizers.

**T34 — Dogfood cycle (report-only).** Using ONLY the `orchard` CLI against the live
app runtime: register this repo, run-create, task-create a trivial real task, start a
claude agent in a fresh Orchard-managed worktree, supervise via `orchard check
--wait` to a settled `worker_done`, verify the transcript/archive paths, then clean
up (release, delete the worktree). Deliverable: docs/reports/dogfood-1.md recording
every command, receipt, quirk, and bug found (bugs go to the backlog; do not fix
code). No damson-ide source changes.

### Wave 9 (T35–T38; T35/T36/T37 parallel, T38 depends on T35+T36)

**T35 — Dispatch ergonomics (dogfood fixes, runtime).** From dogfood-1: accept
`claude` as an alias for the `claude-code` engine and enumerate engine ids in
agent-context; a failed worker-start cleans up its partial worktree/dispatch (or
returns exact residuals with working cleanup commands); the injected preamble and
worker env carry an absolute ORCHARD_CLI_COMMAND (never bare `orchard`); worker-read
`--source transcript` is honored or fails typed (no silent terminal fallback); the
terminal-tail archive strips TUI chrome (spinner frames, repeated separators) with
raw bytes still recoverable.

**T36 — CLI ergonomics.** `orchard <command> --help` prints that command's spec
(flags, positionals, examples) instead of unknown-flag; bare `orchard guide` lists
topics; human formatter for worktree list covering remote entries with the staleness
warning; usage strings audited against dogfood-1's friction notes.

**T37 — Remote workspace UI.** App flow for remote repos: an Open Remote… entry
(host picker from the registry + remote path field with probe feedback), remote
repos/worktrees render in the sidebar with the host chip, opening a remote worktree
opens its ssh pane, and file/agent affordances show disabled states with the typed
remote_unsupported explanation rather than failing silently.

**T38 — Dogfood cycle 2 (report-only; after T35+T36 merge).** Re-run the full live
cycle from docs/reports/dogfood-1.md with the fixes in place: `--agent claude` must
work, the preamble must be executable verbatim by the worker, transcript reads must
be honest, archives readable. Record docs/reports/dogfood-2.md with a
finding-by-finding comparison table against cycle 1, plus any new findings. Same
safety rules: never touch resources you did not create; report bugs, do not fix.

### Wave 10 (T39–T42, parallel; merge order T40 → T42 → T41 → T39)

**T39 — SSH stage 3: remote agent panes.** Per docs/design/remote-hosts.md: launch an
agent CLI in a remote worktree (`ssh -tt <host> cd <wt> && exec <agent>`), with agent
status detection carried over an SSH reverse tunnel (`-R 0:127.0.0.1:<hook-port>`)
that lets the remote agent's hooks POST back to the local HookServer; fingerprints
remain the fallback when the tunnel cannot bind. Supervised orchestration dispatch to
remote agents stays a typed remote_unsupported (the remote host has no orchard CLI —
lifecycle duties are impossible); these are handoff-style panes with live status only.
Honest scope notes required in worker_done.

**T40 — Worktree lifecycle polish.** `worktree rm` gains --delete-branch (safe `git
branch -d` after removal, refusing unmerged unless --force-branch; preflight names the
branch and its merged/unmerged state); the app delete sheet's branch checkbox drives
the same path; finish archive readability (finding 4: the cleaner still collapses
words — fix segmentation so words keep their spaces); investigate and fix the
Swift-debug noisy send output from dogfood-2.

**T41 — Composer & agent-flow polish.** The ⌘N composer gets the v1-spec surface on
v2: engine picker from the live registry (aliases shown once), base-branch picker
seeded with the repo default, fan-out count (N independent worktrees, same prompt),
initial workspace status; workspace cards get a start/restart-agent affordance when no
agent is live (spawn into the existing worktree, agent-first). No scheduler — fan-out
just creates N workers now.

**T42 — Headless E2E CI harness.** Extend scripts/ci.sh with a headless orchestration
smoke: boot `orchard serve` against a temp data dir, drive the full cycle via the CLI
(repo add → run/task → worker-start with the shell engine → check --wait to settled
worker_done → worker-read → release → worktree rm), assert receipts at each step, and
tear down cleanly. Must run without the GUI and leave nothing behind; wire it as an
opt-in ci.sh stage (ORCHARD_CI_E2E=1) so plain unit runs stay fast.

### Wave 11 (T43–T46, parallel; merge order T45 → T46 → T43 → T44)

**T43 — SSH stage 4: remote pane restoration.** The keeper already keeps the local
`ssh` child alive across an app restart; make adoption restore the REST of a remote
pane's identity: persist per-pane host/remote-cwd/agent-argv/tunnel state in the
restoration record, re-attach engine identity and statusDetection (tunnel if its
local listener can rebind, else typed fingerprint degradation) on adopt, and when the
ssh child died while held, surface a reconnect affordance (fresh ssh from the same
spec, new incarnation) worded in verdicts — the pane says the connection ended, never
that remote work died.

**T44 — In-app orchestration view.** A window/section (menu + sidebar entry) showing
the runtime's own orchestration state read-only: runs → tasks (status, deps,
titles) → dispatches/workers (dispatch status, worker state, terminal state), with a
worker archive viewer (cleaned lines with a raw toggle) and jump-to-terminal for live
workers. All reads through the in-process store/services; no mutations from this
surface (release/stop stay CLI-only this wave).

**T45 — Host liveness producer.** A periodic bounded prober (reuse HostProbe;
configurable interval; runs only while remote repos/panes exist) that publishes
per-host reachable|auth-required|unreachable + last-checked, feeding the sidebar host
chips and Open Remote sheet live. Loss of reachability updates the chip only — never
any workspace or worker state.

**T46 — Runtime performance & robustness pass.** Measure, then fix: SQLite pragmas
and index audit for the orchestration store (journal/synchronous, hot-query EXPLAIN),
socket-server connection handling audit (thread growth under concurrent CLI load,
cap/reuse), file-watcher and port-sweep budgets under many workspaces, and a
before/after measurement table in the worker_done for every change made.

### Wave 12+ backlog

Intermittent single-test failure in full-suite runs: likely root-caused by the
accepted-socket O_NONBLOCK inheritance regression (fixed post-wave-11 — accepted
connections now clear the flag); if a 1-failure run recurs, capture the test name.

T39/T43 leftovers (need a real remote host to verify): sshd reverse-forward grant, real
remote Claude POSTing through the tunnel, fixed-range port claim surviving to the
pane's ssh, the same forward being granted again on a reconnect, and a remote agent
still POSTing through a forward whose local end a new app instance rebound. Open by
design: remote provider transcripts unresolvable, a restored ended pane has no
scrollback (the keeper cannot hand back a dead pane's buffer), app-side remote *agent*
opening (CLI/RPC only today; the app's reconnect button reaches remote shell panes).

From dogfood cycle 2 (docs/reports/dogfood-2.md): archive chrome-stripping still
collapses words (finding 4 partially fixed); worker send in a Swift-debug context
prints noisy output; `worktree rm` leaves the branch behind (offer branch deletion in
the preflight like v1 did).

T32 leftovers: human-readable remote worktree-list formatter (staleness warning is
JSON-only), remote file backend + remote agents (SSH stage 3), app-side UI to open a
remote workspace (the host chip renders; opening flow does not exist).

From the first dogfood cycle (docs/reports/dogfood-1.md, all verified live):
worker-start `--agent claude` fails with unknown engine (accepted id is
`claude-code`; alias it and enumerate engines in agent-context, and make the
failed launch clean up its partial worktree/dispatch), the injected preamble
references bare `orchard` that is not on the worker's PATH (inject
ORCHARD_CLI_COMMAND as an absolute path and use it in the preamble), worker-read
`--source transcript` silently falls back to terminal (honor the request or fail
typed), TUI terminal archives are noisy (strip spinner/chrome on capture),
subcommand `--help` is rejected, and bare `orchard guide` should list topics.
Also:

Project the repo primary checkout (and folder workspaces) into the runtime workspace
registry as `repoId::path` the way Orca does — today `orchard file search --worktree
path:<repo>` fails with unknown_worktree until a worktree is created through the
runtime (verified live 2026-08-23). Also: headless serve refuses socket paths over the
104-byte sun_path limit with a typed error — consider defaulting the socket into
$TMPDIR when --data-dir is deep.

App sidebar duality was resolved by T8 (was: `orchard repo add` never surfaced in the
UI, verified live 2026-08-23). Remaining: chat view-mode overlay on agent PTYs,
`orchard serve` headless mode, capability-hash enforcement on `send`, full-text file
search, browser session profiles/cookie import, automations (scheduled prompts),
status-bar/ports, damson-side fixes (pane targeting, multi-subscriber raw output,
deferred spawn), SSH/remote hosts.


File-manager service + right-sidebar explorer UI; WKWebView browser pane + automation
verbs (snapshot with @e refs via injected JS, click/fill/screenshot/eval, per-workspace
tabs); `worker-start` RPC verb end-to-end + worker archives; chat view-mode overlay;
`orchard serve` headless; damson-side fixes (pane targeting for all commands,
multi-subscriber raw-output stream, richer dump-grid); status-bar/ports; automations.

## Worker ground rules

1. Fork point is `main` of this repo; work only in your assigned worktree; commit
   locally with clear messages; **do not push, do not merge, do not touch other tasks'
   paths** (ownership lists above). Package.swift is owned by T0; later tasks may not
   edit it except to add files (SPM auto-globs — so normally no edit at all).
2. `swift build` and `swift test` must pass before you report done.
3. No new external dependencies. SQLite = `import SQLite3` (system). damson imports only
   in `OrchardTerminals` and the `Orchard` app.
4. Match existing code style: doc comments explain *why*; concise; value types +
   `Sendable` where practical; no force-unwraps in engine code.
5. You are a supervised orchestration worker: follow your injected preamble —
   `worker_done` exactly once with outcome, heartbeats while working, blocking questions
   via `orca orchestration ask` (NEVER a local interactive prompt).
6. Read the three research docs before coding. When this plan and a research doc
   conflict, this plan wins; when both are silent, match Orca's behavior
   (`~/dev/orca` is on disk — cite the file you followed in your commit message).
