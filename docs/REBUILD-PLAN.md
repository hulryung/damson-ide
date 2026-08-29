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

### Wave 12 (T47–T50, parallel; T50 report-only) — MERGED 2026-08-25, 906 tests

All four landed: T50 dogfood-3 report (socket load 20/20, cycle green, branch cleanup
verified), T47 orchestration view controls, T48 Automations window (enabled flag with
default-true decode; due/fireDue skip disabled), T49 Vault (archive browser/reader,
live-run-protected prune that re-plans and deletes only the preview intersection).
Merge order became arrival order T50 → T47 → T48 → T49; the only conflicts were
additive Go-menu/AppStore unions between T48 and T49. Visual pass of the three new
windows still pending (display was locked at wave end — AX reads and screenshots
blocked; not a permission problem).

**T47 — Orchestration view controls.** Add guarded mutations to the T44 view:
worker-release (enabled only for settled dispatches, confirm sheet naming exactly
what closes), worker-retain/stop (stop confirms with the task title and warns the
dispatch fails), gate-resolve (option picker), all through the same store/verb paths
and refusal semantics as the CLI — a refusal renders the typed reason inline, never a
silent no-op. Every mutation appends a local audit line in the view.

**T48 — Automations UI.** App surface for T16: an Automations window (menu + sidebar
entry) listing automations with enable state and next-fire time, a create/edit sheet
with a trigger builder (hourly/daily/weekdays/weekly/cron field with validation
preview), target picker (repo → fresh worktree, or existing workspace), provider and
prompt fields, precheck command with its skip semantics explained, and a run-history
pane per automation (fired/skipped/failed with timestamps and result links). Drives
the existing runtime service only.

**T49 — Vault: archive & transcript browser.** A cross-run browser for what workers
left behind: every dispatch's archives (cleaned/raw terminal tails, transcript pins)
listed by run/task/agent with a text filter, a reader pane reusing worker-read paths,
and a retention policy (size/age caps configurable in Settings; prune runs whose
archives exceed them, never the active run) with a dry-run preview before deletion.

**T50 — Dogfood cycle 3 (report-only).** On the current build: hammer the socket with
parallel CLI load (e.g. 20 concurrent status/list calls — the O_NONBLOCK regression
class must stay dead), run the full live cycle again, verify the Orchestration window
reflects the run live (screenshot evidence), confirm remote_unsupported guards, and
write docs/reports/dogfood-3.md with comparisons to cycle 2 and any new findings.

### Wave 13 (T51–T53, parallel) — MERGED 2026-08-25, 932 tests

Status: T53 merged (delete-branch surfaced in the app sheet, human remote
worktree-list with staleness warning, send quiet unless --verbose). T51 merged and
VERIFIED LIVE: close main window → process alive, runtime socket answers, 0 windows;
activate → workbench restored with state; app menu truthfully shows
"Runtime alive · rt_…" matching the live runtimeId. T52's first dispatch (codex)
failed at startup — "Agent startup blocked: codex-update-prompt" (the codex CLI's
update prompt blocks supervised launch; consider updating codex before next use) —
re-dispatched on claude in the same worktree; the retry landed. T52's
load-bearing finding: most archive mangling blamed on the cleaner is upstream in the
raw capture (wide pastes reach the stream buffer pre-collapsed, torn repaints drop
letters); the cleaner's own damage was invented word boundaries, now gone — every
emitted line is a captured line minus chrome, respacing only with provenance.
Follow-ups promoted to the backlog below.

**T51 — Runtime survives window close.** Closing the main window today terminates the
app (applicationShouldTerminateAfterLastWindowClosed), killing the runtime and every
supervised worker with it — diagnosed live in dogfood-3. Change the lifecycle: closing
the main window keeps the app and runtime alive; clicking the Dock icon or activating
Orchard reopens (or re-fronts) the main window with its workbench state; auxiliary
windows (Automations, Vault, Orchestration, Dashboard, Settings) keep their existing
close behavior; Cmd-Q / Orchard ▸ Quit still performs the full termination path
(keeper handoff, runtime stop, metadata removal — do not break T23). Add a small,
truthful "runtime alive" indication reachable without the main window (the Dock menu
and/or app menu). Unit-test the lifecycle decision logic where it is extractable;
document what needs a human visual pass. Owns: Sources/OrchardApp/main.swift,
Sources/OrchardApp/AppStore.swift (minor wiring only), docs. Does not touch
OrchardTerminals, OrchardRuntime, or the CLI.

**T52 — Terminal capture cleaner: stop mangling text.** The Vault reader shows cleaned
captures losing whitespace AND characters: real samples from the live store include
"Tipsforgettingstarted", "WelcomebackDaekeun!", "Bugfixesandreliabilityimprovements",
"coorinatoronlythroughtheCLIcommandsbelow.Donotuse", and "paste gain to expad" (note
dropped letters: should read "paste again to expand"), "coorinator" (dropped d-i),
"handleis" ("handle is"). The cleaner (Sources/OrchardTerminals/
TerminalCaptureCleaner.swift) must never emit a line it cannot clean faithfully —
prefer passing the raw line through over collapsing or dropping characters. Extract
real fixtures by COPYING ~/Library/Application Support/Orchard/orchestration.db into
your worktree's test resources (worker_terminal_archives.raw_lines) — never open the
live DB read-write and never point tests at the live path. Acceptance: fixture-driven
tests over the real T50/T38/T34 captures assert no word-joins and no character loss
versus raw; existing cleaner tests stay green or are corrected with justification.
Owns: Sources/OrchardTerminals/TerminalCaptureCleaner.swift, Tests/** for it, test
fixtures, docs. Does not touch OrchardApp or OrchardRuntime.

**T53 — Small-finding sweep (dogfood-2/T32 leftovers).** Three small fixes, one
branch: (1) the app-side worktree remove flow offers branch deletion in its preflight
(v1 behavior; CLI `worktree rm --delete-branch` from T40 is the model — surface the
same choice and result in the sheet); (2) `orchard host worktree-list` (or the actual
remote worktree-list verb) gets a human-readable formatter including the staleness
warning that today is JSON-only; (3) worker send in a Swift-debug context prints noisy
output — find the debug-print leak and silence it behind a verbosity flag. Each fix
gets a test where testable. Owns: Sources/orchard/**, Sources/OrchardApp worktree
sheet/flow files, Sources/OrchardCore where the formatter lives, matching Tests/**.
Does not touch Sources/OrchardApp/main.swift, TerminalCaptureCleaner.swift, or
OrchardRuntime/Orchestration verb logic.

### Wave 14 (T54–T56, parallel) — MERGED 2026-08-25, 965 tests, e2e PASS

All three landed. T54's root cause: the damage was ORCHARD-side, not damson's — the
read stream was assembled from parsed text events with CSIs dropped at the seam, and
a cell-diffing TUI sends cell writes (cursor motion over blanks, unchanged cells
unsent), not lines. Fixed in OrchardTerminals: CSI-aware seam, TerminalCaptureCollector
classifies bursts print vs paint and captures paints from the grid (row diff,
scrollback, DECSET-2026 frames), wide-glyph phantom space fixed. damson unchanged, no
pin change. T55: respacedLines serialized. T56: automations fire end-to-end headless
(current-minute due + due/fire-due RPC). T54 follow-ups (design doc §6): stream ring
capacity under a 10fps spinner, pin a post-T54 live capture as a fourth fixture on the
next dogfood cycle.

**T54 — Upstream capture fidelity (investigation + fix).** T52 proved the cleaner
faithful and localized the real damage upstream: wide pastes reach the captured
stream already collapsed ("Tipsforgettingstarted") and torn repaints drop characters
("paste gain to expad", "coorinator"). Reproduce and root-cause where fidelity is
lost between the damson terminal grid and WorkerVerbs' page read (grid row→string
conversion trimming/joining? snapshot racing a repaint? outputBytes vs grid source?).
The T52 fixture (Tests/OrchardTerminalsTests/Fixtures/claude-code-tui-capture-t50.txt)
holds the evidence. Deliver docs/design/capture-fidelity-upstream.md (root cause +
repro), a scripted-paint repro test, and the fix. Fix Orchard-side if possible. If
the fix is genuinely damson-side: create a branch in a NEW worktree of ~/dev/damson
(`git -C ~/dev/damson worktree add …`) — NEVER touch the ~/dev/damson primary
checkout, its uncommitted WIP, or its main; report the damson diff for coordinator
review instead of merging or pinning anything yourself. Owns:
Sources/OrchardTerminals/**, Tests/OrchardTerminalsTests/**, docs/design/**; damson
changes only on a new branch in a new damson worktree. Does not touch
OrchardRuntime, OrchardApp, or Package.swift pins.

**T55 — respacedLines on the wire.** TerminalCaptureCleaner.Report now counts
respacedLines but the runtime's chromeStripped receipt does not serialize it. Add it
to the receipt payload (WorkerVerbs) and any CLI rendering that shows chromeStripped,
with a test. Owns: Sources/OrchardRuntime/Orchestration/WorkerVerbs.swift (receipt
region only), Sources/orchard/** if the receipt renders there, matching Tests/**.
Does not touch TerminalCaptureCleaner.swift or OrchardApp.

**T56 — Automations fire end-to-end, headless.** The Automations window and service
exist but no automation has ever fired live. Extend the headless E2E harness
(scripts/e2e-headless.sh + its serve fixture) to: create an automation due
immediately against a temp repo, drive the scheduler (due/fireDue), and assert a run
record lands in run history with its worktree/terminal outcome; fix what breaks in
OrchardRuntime/Automations to make the path real. Keep fixes inside Automations/*
and the harness. Owns: scripts/e2e-headless.sh, Sources/OrchardRuntime/Automations/**,
Tests/** for automations, docs. Does not touch WorkerVerbs.swift,
OrchardTerminals, or OrchardApp.

### Wave 15 (T57–T59, parallel) — MERGED 2026-08-25, 986 tests

T57 dogfood-4: cycle clean (ready 7s, settled 17s, no app exit — T51 holding), T54
VERIFIED LIVE on a fresh archive (cleaned = raw minus chrome, respacedLines 0, no
T50 shapes) and pinned as the 4th fixture; automations fired live (decision B).
T58: spinner ticks coalesce in place in the stream ring (uncoalesced, 10fps filled
the 10k ring in ~16.7min). T59: adopted panes re-fit on first framed paint (root
cause was ORDER — replay landed before the surface had a frame); coordinator
verified the primary case live post-relaunch: first row renders unclipped.
Engine notes: cursor stalls on plan-approval prompts for design-y tasks
(agent_prompt_stalled; the orphan keeps running fenced — stop the terminal before
re-dispatch); codex still blocked on its update prompt.

**T57 — Dogfood cycle 4 (report + fixture pin).** On the current build, via the CLI
only (the app is the user's; never launch/quit it, never touch terminals/worktrees you
did not create): run a full supervised cycle (repo → run/task → claude worker →
settlement → archive → release → worktree rm --delete-branch), then verify the T54
capture fix on YOUR OWN worker's archive — worker-read cleaned output must show no
joined words, no dropped characters, chrome off; extract that archive from a COPY of
orchestration.db (redact capability tokens) and pin it as the fourth fixture with a
test case asserting its cleaned shape (T54 follow-up §6). Also exercise automations
live: create a due-now automation on a temp repo via the CLI, watch fireDue produce a
run-history row, then delete it. Report docs/reports/dogfood-4.md with a findings
table. Owns: docs/reports/dogfood-4.md, Tests/OrchardTerminalsTests/Fixtures/**, ONE
new test file for the fixture. Does not modify production sources.

**T58 — Stream ring capacity vs paint-heavy TUIs.** T54 §6 flags the stream ring
under a 10fps spinner row: measure how long a paint-heavy session stays within the
ring before terminal_tail loses early output, decide and implement the right bound
(size, byte budget, or collector-aware retention), with a test that a sustained
spinner does not evict recent real output. Owns:
Sources/OrchardTerminals/TerminalStreamBuffer.swift (+ collector touchpoints if
strictly needed), its tests, docs note. Does not touch fixtures, WorkerVerbs, or
OrchardApp.

**T59 — Keeper-adopted pane fit.** Since wave 7: keeper-ADOPTED panes bypass the T30
cell-snap/top-align fit — the first row renders half-clipped after app relaunch until
a manual resize. Route adopted panes through the same fit path as fresh spawns (T30's
fix in Sources/OrchardApp/TerminalPaneHost.swift is the model; adoption happens via
KeeperRestart/TerminalRegistry). Add a regression test where the fit decision is
extractable; document what needs a human visual pass after relaunch. Owns:
Sources/OrchardApp/TerminalPaneHost.swift, Sources/OrchardApp/KeeperRestart.swift,
minimal OrchardTerminals adoption touchpoints if strictly needed, matching tests.
Does not touch TerminalStreamBuffer.swift, fixtures, or main.swift.

### Wave 16 (T60–T62, parallel) — MERGED 2026-08-25, 1022 tests, e2e PASS

All three landed. T60: atomic minute-slot claim (concurrent due→fire proves one run;
in-flight fires refuse as automation_fire_in_flight), shell fires now EXECUTE via a
dispatch-input stage (one quote-balanced line; no capability left in pane input),
`once` trigger (ISO|HH:mm|now, auto-disables after firing; e2e exercises it),
settlement: shell workers settle via worker_done or the T11 exit reconciler and
release closes the exited pane. T61: repo remove (repo_in_use typed refusal),
ok:false envelopes exit 1 centrally, help nits. T62: frame autosave on all windows
(center only without a saved frame; T51 reopen keeps the retained window).
Coordinator added `once` to the automations help (T60 leftover, T61's file).
Not done (deliberate): auto-disable-after-N-failures — `once` covers the dogfood
case; revisit only if recurring automations misbehave in practice.

**T60 — Automations hardening (dogfood-4 findings 1–4).** (1) Single-fire guarantee:
fire-due and the in-process scheduler must not both fire one minute slot — claim the
slot atomically in the store (or equivalent) with a test that concurrent due→fire
paths produce exactly one run. (2) Shell-provider fires must EXECUTE: the injected
preamble+prompt currently lands as an unsubmitted paste in zsh; submit it, and
guarantee no fire path ever leaves a capability sitting in a pane's pending input.
(3) Add a `once` schedule: fires a single time then auto-disables (runtime + CLI;
a minimal "Once" option in AutomationEditorSheet.swift is allowed). (4) Settlement
story for automation-fired workers: a fired shell worker settles on process exit,
worker-release must not strand them; document the decided semantics. Owns:
Sources/OrchardRuntime/Automations/**, minimal AutomationEditorSheet.swift addition,
settlement touchpoints in LiveOrchestrationStore+*/WorkerVerbs only if strictly
needed, matching Tests, e2e stage update. Does not touch Sources/orchard CLI files
or OrchardApp/main.swift.

**T61 — CLI polish (dogfood-4 leftovers).** (1) `repo remove` verb: refuse while
worktrees/automations reference the repo (typed error naming them), no --force in
v1 of the verb; registry row + orchard-data cleanup; human + JSON faces. (2) Typed
errors must exit non-zero from the CLI (today exit 0) — audit the error path once,
centrally. (3) The help/flag nits listed in docs/reports/dogfood-4.md. Owns:
Sources/orchard/**, the repo-registry handler file, OrchardProtocol/CommandSpec.swift
+ CLIFormatting.swift, matching Tests. Does not touch Automations/** or OrchardApp.

**T62 — Window frame persistence.** main.swift windows remember nothing across
relaunch (why keeper-adopted panes commonly come back into a smaller window). Give
the main window and the auxiliary windows (Settings, Dashboard, Orchestration,
Automations, Vault) frame autosave (setFrameAutosaveName or equivalent restoration),
verify the T51 close→reopen path restores the frame too, and unit-test whatever is
extractable. Owns: Sources/OrchardApp/main.swift (window creation sites), a small
test where extractable, docs note. Does not touch AutomationEditorSheet.swift,
OrchardRuntime, or OrchardTerminals.

### Wave 17 (T63–T65, parallel) — MERGED 2026-08-25, 1031 tests, e2e PASS

T63 dogfood-5 verified wave 16 LIVE: once fired exactly one run across a minute
boundary and two scheduler ticks then auto-disabled; concurrent run --id refused
automation_fire_in_flight; repo remove refused repo_in_use (naming worktree, then
worktree+automation, then automation) and removed cleanly after; 13 typed errors
across 10 verbs exit 1, usage errors exit 64; archive fidelity clean (0 re-spaced,
0 unsourced). All dogfood-4 findings closed. T64: cardStatus board columns
(worktree set --status, sidebar chips + context menu + group-by-status). T65: jump
palette four-kind routing incl. Go-menu commands. New minor findings → backlog:
empty ~/Orchard/worktrees/<repo>/ container dir left after worktree rm + repo
remove; automations verbs use generic automation_error where siblings use typed
codes; manual run --id does not check enabled on a consumed once; worker-read
200-line default window worth a look.

**T63 — Dogfood cycle 5 (wave-16 verification, report-only).** On the current build via
the CLI only (never launch/quit the app; never touch terminals/worktrees you did not
create): (1) full supervised claude cycle to settlement with archive fidelity spot-check;
(2) hardened automations live: a `once` automation on damson-ide fires exactly once,
settles on exit, auto-disables; verify a concurrent manual `run --id` during the fire
window is refused as automation_fire_in_flight; (3) `repo remove`: add a temp repo, verify
in-use refusal while its worktree exists, then clean removal after; (4) typed errors exit
non-zero (spot-check 3 verbs). Report docs/reports/dogfood-5.md with a findings table.
Owns only the report. Does not modify sources or tests.

**T64 — workspaceStatus board columns (cardStatus).** Orca parity (inventory §2): user-set
board columns on worktree cards — defaults todo/in-progress/in-review/completed plus
user-defined {id,label,color} — DISTINCT from the derived live status. Runtime: status
field in user-authored worktree meta (orchard-data.json) + `worktree set --status` CLI +
spec; App: sidebar card shows the column (color chip), context menu to change it, a
group-by-status toggle in the sidebar. Owns: OrchardCore worktree meta files,
Sources/orchard worktree set verb + CommandSpec entry, SidebarView.swift + AppStore
wiring, matching tests. Does not touch PaletteSources.swift, Automations, or
OrchardTerminals.

**T65 — Jump palette parity (cmd-j).** Orca parity (inventory §6): the palette must cover
worktrees, files, agents, and commands with correct routing — worktree → select workspace,
file → open in editor, agent → focus its pane, command → execute (the Go-menu surface at
minimum). Ranking via existing PaletteRanking; sources in PaletteSources. Owns:
OrchardCore/Support/PaletteSources.swift + PaletteRanking if needed, the palette view
files in OrchardApp, matching tests. Does not touch SidebarView.swift, worktree meta, or
CommandSpec.

### Wave 18 (T66–T68, parallel) — MERGED 2026-08-25, 1077 tests, e2e PASS

T66: empty `~/Orchard/worktrees/<repo>/` container removed after the last worktree
goes (never recursive), typed automation errors (automation_not_found /
_invalid_input / _disabled) incl. a disabled-once `run --id` guard, worker-read's
200-line default documented. T67: UI-free DashboardCard/DashboardBoard projection
with all inventory §6 card fields, done-until-acknowledged highlight, 40-card
per-bucket cap (parentPaneKey has no live stamp yet — nil until orchestration
stamps it). T68: conflict-review tab — UI-free GitConflicts (operation detection
via --absolute-git-dir since a linked worktree's MERGE_HEAD lives in
.git/worktrees/<name>, porcelain -z with the rename second-field trap, marker
parsing, per-hunk ours/theirs/both, staging refused while markers remain,
delete/modify resolves via git rm) + ConflictReviewPane auto-opening for a
conflicted worktree without stealing the pane. Finishing/aborting an operation
stays in the terminal by design; the pane itself is unit-verified only.

**Coordinator-found palette defects (fixed on main, not worker work).** Live ⌘J
verification of wave 17 found two: rows kept stale content when the query
refiltered (`.id(index)` fought the ForEach's data identity — now keyed by
candidate), and a repo with no secondary worktrees was unreachable because the
catalog seeded only from `records` while the primary checkout is its own sidebar
row (new PaletteProjectSeed / `root:` candidates / `.selectProjectRoot`). A first
attempt at the latter read `project.rootSubtitle` inside the catalog and crashed
the app (SwiftUI AttributeGraph precondition, SIGABRT) — that property shells out
to git and the catalog rebuilds on every keystroke; the render path now stays
git-free. Tooling note: `orca computer press-key Escape` does not reach the
palette's KeyCaptureView (a stuck sheet then blocks Cmd-Q with -128);
`osascript 'key code 53'` does.

**T66 — Dogfood-5 minor findings sweep.** (1) `worktree rm` and `repo remove` must
remove the now-empty `~/Orchard/worktrees/<repo>/` container directory (only when
empty; never recursively). (2) Automations verbs get typed error codes
(automation_not_found, automation_invalid_input, …) where they answer generic
automation_error today — match sibling verbs' vocabulary; update CommandSpec notes if
they enumerate codes. (3) Manual `run --id` on a consumed `once` automation must
refuse (automation_disabled or equivalent typed code) instead of firing a disabled
automation. (4) Look at worker-read's 200-line default window: make the default and
the flag documented and consistent (no behavior redesign). Owns:
OrchardCore/Worktrees removal path, OrchardRuntime/Automations error surface +
run-path guard, Sources/orchard + CommandSpec touch-ups, matching tests. Does not
touch OrchardApp or OrchardTerminals.

**T67 — Agent Dashboard kanban parity.** Inventory §6: buckets
attention|working|done|idle; card carries paneKey, agentType, dotState, task, last
user/agent message, click-to-focus routing, parentPaneKey, workspaceStatus,
startedAt/finishedAt, unseen, askSummary; a done card stays highlighted until
acknowledged; fleet sizes bounded so a huge fleet cannot blank the view. Audit the
T19 dashboard against that list, implement what is missing, and unit-test the
UI-free projection. Owns: Sources/OrchardApp/AgentDashboardView.swift + its
projection files (extract to OrchardCore/OrchardRuntime if UI-free), minimal
AppStore wiring, matching tests. Does not touch WorkbenchView.swift, worktree
meta/removal, or Automations.

**T68 — Conflict-review tab.** Inventory §6 center tabs include conflict-review: when
a workspace's worktree has merge conflicts (merge/rebase in progress), a tab that
lists conflicted files, shows ours/theirs/base per file with the conflicted hunks,
and lets the user choose ours/theirs per hunk or open the file in the editor; writing
a resolution stages the file. Detection via git status porcelain (unmerged entries).
Keep the git logic UI-free in OrchardCore/Git with tests over a fixture repo the
tests create; the tab renders it. Owns: OrchardCore/Git conflict files,
Sources/OrchardApp conflict-review view files + WorkbenchView tab-kind wiring +
minimal AppStore additions, matching tests. Does not touch
AgentDashboardView.swift, Automations, or worktree removal paths.

### Wave 19 (T69–T71, parallel) — MERGED 2026-08-25, 1106 tests

T69 dogfood-6: cycle holds (ready 5s, settled 16s, respacedLines 0); T68's conflict
LOGIC verified live against six real merge/rebase conflicts in linked worktrees;
waves 16–18 fixes all held. One real defect found → T72. T70: source-control panel
(staged/unstaged, stage/unstage, typed commit refusals, branch switch/create,
push/pull only with a remote) over a new UI-free GitSourceControl. T71: floating
terminal bound to an existing pane's session (close unbinds, never kills the PTY)
plus status-bar workspace/branch, dashboard bucket counts, runtime item. Three GUI
surfaces landed without a visual pass → T74.

**T69 — Dogfood cycle 6 (report-only).** CLI only; never launch/quit the app; never
touch terminals/worktrees you did not create. (1) Full supervised cycle to
settlement. (2) **Conflict-review live**: create a scratch repo OUTSIDE the user's
registered repos (e.g. under your worktree's tmp), produce a real merge conflict in
a worktree you create, and verify the T68 surface through what is reachable from the
CLI/RPC (conflict listing, per-hunk resolution, the staging refusal while markers
remain, the linked-worktree MERGE_HEAD path); report honestly which parts are only
reachable in the GUI and therefore unverified. (3) Regression-sweep the fixes from
waves 16–18: once/fire-in-flight, repo remove refusal, typed exits, empty container
cleanup, typed automation errors. Report docs/reports/dogfood-6.md with a findings
table. Owns only the report; no source or test changes.

**T70 — Source-control panel (right sidebar).** Inventory §6 lists source-control
among the right-sidebar sections; today we have explorer/search/vault/workspaces/
ports. Add a source-control section for the selected workspace: changed-file list
(staged vs unstaged, with the same status vocabulary the diff pane uses), stage /
unstage per file and all, commit with a message (refuse empty message and empty
staged set with typed errors), branch name display + switch/create, and
push/pull surfaced only when a remote exists — every failure path typed and shown
inline, never silent. Keep the git logic UI-free in OrchardCore/Git (new file, do
not edit GitConflicts.swift) with tests over fixture repos the tests create; the
panel renders it. Owns: a new OrchardCore/Git source-control file + its tests, a new
Sources/OrchardApp/SourceControl/ directory, minimal RootView/AppStore wiring for
the section. Does not touch GitConflicts.swift, Conflicts/**, JumpPalette.swift,
AgentDashboardView.swift, or Automations.

**T71 — Floating terminal + status-bar items.** Inventory §6 "Other": (1) a floating
terminal — a small always-on-top window bound to an existing pane's live session
(never a second PTY for the same pane), openable from the pane's menu, closable
without killing the session, remembering its frame like T62's windows; (2)
status-bar items beyond the current ports chip: current workspace + branch, live
agent count by bucket (reuse T67's projection, do not edit it), and the runtime
indicator (reuse T51's runtimePresence). Owns: Sources/OrchardApp/StatusBarView.swift,
a new floating-terminal view file + its window creation in main.swift, minimal
AppStore wiring, matching tests where extractable. Does not touch
AgentDashboardView.swift, DashboardProjection.swift, SourceControl/**, or
OrchardTerminals internals.

### Wave 20 (T72–T74, parallel) — MERGED 2026-08-25, 1143 tests, e2e PASS

T72 fixed the data loss against real git: GitRunner gained a raw-Data path
(capture() is now a thin decode over it, so existing callers are untouched),
whole-file take copies the chosen index stage byte for byte INCLUDING its mode
(exec bit, 120000 symlink), and per-hunk resolve refuses non-UTF-8 with a typed
error surfaced in the pane. The 768-byte binary now stays 768 bytes with a staged
blob id equal to git's own. T73 added `orchard conflicts list|show|take|resolve|
stage` over the same service, so the surface is no longer GUI-only. T74's visual
pass could not confirm T70/T71 on screen — the running app predated them (workers
may not relaunch it); the coordinator has since relaunched, and CommandSpec vs
agent-context showed no drift.

Coordinator integration fix: T73's handler matched GitError message strings for
the staging refusal, which T72 turned into typed GitConflictError values — the
verb answered internal_error until the two vocabularies were mapped.

Known: one full-suite run reported a single failure that did not reproduce in the
next two clean runs (1143/1143) and printed no assertion line — same intermittent
flake noted in wave 11 and by T72. Capture the name when it recurs.

Still owed from T72's audit (outside its ownership): the same decode-then-write
defect exists in the editor path (FileService.preview → FileService.write), and
WorktreeManager.ensureExcluded has a truncation risk.

**T72 — Conflict resolution must be byte-exact (data-loss fix).** dogfood-6 found
`GitRunner.Output.stdout` decodes with `String(decoding:as: UTF8.self)`, so
GitConflictService round-trips file content lossily: `take()` on a binary conflict
rewrote a 768-byte blob as 1792 bytes of U+FFFD **and staged it**, and `resolve()`
corrupted an untouched Latin-1 header line. For binaries the Take buttons are the
pane's only route, so the broken path is the only path. Fix: give GitRunner a raw
`Data` stdout variant (do not change the existing String API's callers) and make
whole-file take a byte-exact copy of the chosen index stage; per-hunk resolution
needs text, so refuse it with a typed error when the file is not valid UTF-8, and
say so in the pane. Audit every other place that writes file content read through
the String path. Tests must include binary and Latin-1 fixtures — T68's 25 tests
were all `.utf8`, which is why this shipped. Owns: OrchardCore/Git/GitRunner.swift,
GitConflicts.swift, Conflicts/ConflictReviewPane.swift, their tests. Does not touch
GitSourceControl.swift, SourceControl/**, or Automations.

**T73 — Conflict verbs on the CLI/RPC surface.** dogfood-6: the entire T68 surface
is GUI-only (zero conflict verbs in agent-context), so no agent can see or resolve
a conflict and the tab could not be dogfooded. Add `orchard conflicts
list|show|take|resolve|stage` over the same UI-free service the pane uses (list
conflicted files for a worktree; show hunks; take ours/theirs whole-file; resolve a
hunk; stage a fully-decided file — with the same refusals: never stage while markers
remain, typed errors throughout), CommandSpec entries, and guide coverage. Owns:
Sources/orchard/**, OrchardProtocol/CommandSpec.swift, a new conflict command
handler in OrchardRuntime, guide text, matching tests. Does not edit
GitConflicts.swift or GitRunner.swift (T72 owns those) — call them as they are.

**T74 — Wave 19/20 visual pass + agent-context freshness (report-only).** Three
GUI surfaces landed unverified (source-control panel, floating terminal +
status-bar items, conflict-review pane) and dogfood-6 noted `worker-read` still has
no `hasOlder` field. Drive the RUNNING app through computer-use ONLY for reading
(screenshots + AX trees; never quit or relaunch it, never send input into the user's
terminals): confirm the source-control section renders staged/unstaged and its
error surfaces, the status bar shows workspace/branch, agent buckets and the runtime
item, and the floating terminal's menu affordance exists. Note honestly what
synthetic input cannot verify (SwiftUI key handling — `orca computer press-key`
does not reach KeyCaptureView; use System Events key codes). Also diff
`agent-context --json` against the CommandSpec table and report any verb whose help
or allowedValues drifted. Report docs/reports/visual-pass-w19.md. Owns only that
report.

### Wave 21 (T75–T78) — MERGED 2026-08-26, 1199 tests, e2e + ci.sh PASS

The backlog is closed. T75: byte-exact file round-trips outside the conflict path
(preview decodes only when the bytes round-trip, non-UTF-8 opens read-only, save
refusals are typed and shown, dirty tracking is byte-level) and ensureExcluded now
works in bytes AND writes to `--git-path info/exclude` — in a linked worktree the
old `--git-dir` path was one git never reads, so AgentSupervisor's
`.claude/settings.local.json` rule had never taken effect. T76: named and fixed the
socket load test's backlog/FD-sampling race. T77: worktree subverbs, a `project`
group, and `worker-read --limit`'s honest `hasOlder`; skills/artifacts/computer
declared out of scope. T78: remote panes now carry the five ORCHARD_* variables
through the ssh command line — verified live (see below), which also unblocked the
reverse-forward hook grant (`statusDetection=hooks`, tunnelPort 47110).

Coordinator work in this wave: verified the whole remote stack over a REAL SSH
transport without a second machine (user-space sshd on 127.0.0.1:2222 — see
docs/reports/remote-verification.md), which is what exposed T78's defect; ran T78's
live acceptance after merging (a worker may not relaunch the app); closed T75's two
handoffs (the FileWatcher microbenchmark now counts path materializations instead of
racing the wall clock — it was the second flake, 3 failures in 40 isolated runs; and
GitConflicts' decode refuses anything that does not re-encode byte-for-byte, so a
UTF-8 BOM is no longer silently stripped on resolve).

**New gap found during teardown:** a remote repo cannot be unregistered once its
worktrees have been enumerated — `repo remove` refuses with `repo_in_use` naming
worktrees that live on the far side, and there is no registry-only forget. Removing
them with `worktree rm` would delete the remote's real worktrees, which is not what
un-registering a remote view should mean. The row had to be pruned from
orchard-data.json by hand (app stopped, file backed up). Needs a `repo remove
--forget` (registry-only, remote repos) or an automatic drop of remote worktree rows.

**T75 — File-content fidelity outside the conflict path.** T72's audit found the same
decode-then-write defect it fixed for conflicts still living in the editor path:
`FileService.preview` decodes with a lossy UTF-8 String and `FileService.write` writes
that String back, so opening and saving a Latin-1 or binary file rewrites it as
U+FFFD. Also flagged: `WorktreeManager.ensureExcluded` has a truncation risk. Fix
both: reads/writes that round-trip content must be byte-exact, an editor must refuse
to save what it could not represent (typed error, surfaced in the pane rather than
silently corrupting), and ensureExcluded must never truncate a file it only meant to
append to. Tests must include binary, Latin-1, CRLF, and empty-file fixtures — the
lesson from T72 is that an all-`.utf8` fixture set proves nothing about fidelity.
Owns: OrchardRuntime/Files/** (or wherever FileService lives),
OrchardCore/Worktrees/WorktreeManager.swift, the editor pane's save path in
Sources/OrchardApp/Editor/**, matching tests. Does not touch GitConflicts.swift,
GitRunner.swift, GitSourceControl.swift, or Automations.

**T76 — Hunt the intermittent full-suite failure.** Since wave 11 a single test has
occasionally failed in full-suite runs and passed on re-run; T72 hit it too and could
not capture the name, and one wave-20 run failed while printing no assertion line.
Reproduce it: run the suite repeatedly (e.g. 10+ runs) capturing per-test output to
files, and when it fires, identify the test and the mechanism (shared temp dirs,
port/socket reuse, timing, global state between suites, parallel execution). Fix the
root cause if it is a test-isolation bug; if it is a product race, say so plainly and
write the smallest failing reproduction. Deliver docs/reports/flaky-hunt.md with what
ran, what fired, and the fix. Owns: whatever test files the fix requires plus that
report; production changes only if the root cause is genuinely in product code, and
name them explicitly in the report. Does not touch Files/**, WorktreeManager.swift,
or the CLI surface.

**T77 — CLI surface audit against inventory §7.** Audit `orchard`'s command groups
against docs/research/orca-inventory.md §7 and close the real gaps. Known: `worktree`
lacks `show|current|create|set|rm|ps` as documented subverbs (some exist elsewhere),
there is no `project` group, and `worker-read` still has no `hasOlder` field
(dogfood-5/6 finding) so an agent cannot tell whether older output exists. Skills,
artifacts, and computer groups are OUT of scope — say so in the report rather than
inventing them. For every gap you close: CommandSpec entry, handler, guide text,
tests. For every gap you deliberately leave: one line in the report saying why.
Deliver docs/reports/cli-surface-audit.md. Owns: Sources/orchard/**,
OrchardProtocol/CommandSpec.swift + guides, the worktree/project handlers in
OrchardRuntime/Workspaces/**, WorkerVerbs' read path for `hasOlder`, matching tests.
Does not touch Files/**, WorktreeManager.swift, Conflicts/**, or Automations.

### Wave 22 (T79–T82) — MERGED 2026-08-26, 1243 tests, e2e PASS

Both open items closed, and the verification found a third thing worth fixing.

- **T79** `repo remove --forget`: unregisters a remote repo view — the row and the
  local rows projecting its remote worktrees — touching nothing on the host. A local
  repo still refuses (`forget_local_refused`). Verified live, and dogfood-7 confirmed
  the far side's worktrees survive byte-for-byte.
- **T80** supervised dispatch across a host boundary: `worker-start` no longer
  *assumes* a remote host cannot carry a dispatch, it *asks* — running the CLI over
  ssh with the identity the pane will carry and opening the door only when the far
  side reaches THIS runtime, keeping ready / refused / unverifiable distinct.
  Verified live end to end (docs/reports/t80-remote-dispatch-verification.md) and
  again by dogfood-7. The T80 worker died mid-review after ten hours of silence with
  its work uncommitted; the coordinator verified, committed and merged it.
- **T81** dogfood cycle 7: waves 19–21 all hold, plus the remote cycle and `--forget`.
- **T82** the defect that verification exposed: `worker-start` typed the agent preamble
  into a *shell* pane, whose first apostrophe left zsh in quote continuation with the
  live capability stranded in pending input — so a shell worker could never run its
  task. Dispatch input is now shaped by the engine (TUI keeps the prompt; a shell gets
  one executable line that writes the contract to a mode-600 file). Fixing it surfaced
  the deeper cause: input typed before the shell takes the tty is read in canonical
  mode and cut at MAX_CANON (1024 bytes), losing the tail whatever the quoting, so a
  bare shell's readiness is now a nonce handshake the shell must actually run.

A real SSH transport is available for this wave: host `orchard-loopback`
(127.0.0.1:2222, user-space sshd started by the coordinator, `orchard host check
--name orchard-loopback` → reachable). The coordinator tears it down at the end.

**T79 — Unregister a remote repo without touching the far side.** Wave-21 teardown
found that once a remote repo's worktrees are enumerated, `repo remove` refuses
(`repo_in_use`) naming worktrees that live on the remote — and `worktree rm` would
delete the far side's real worktrees, which is not what un-registering a view means.
The registry row had to be pruned from orchard-data.json by hand. Add a registry-only
unregister: drop the repo row and the *local rows projecting* its remote worktrees,
touching nothing on the host. Decide and document the spelling (`repo remove --forget`
or a `repo forget` subverb); a LOCAL repo must still refuse rather than silently
forgetting worktrees that exist on this machine. Typed errors, human + JSON faces,
CommandSpec + guide. Verify live against `orchard-loopback`: register the remote repo,
list its worktrees, unregister, confirm `repo list` is clean, `worktree list` no longer
projects them, and the remote's worktrees are all still there over ssh. Owns
Sources/orchard/**, the repo-registry handler, CommandSpec/guides, matching tests.
Does not touch WorkerVerbs, Automations, Conflicts/**, or OrchardTerminals.

**T80 — Supervised dispatch to a remote host.** `worker-start` against a remote
worktree still answers `remote_unsupported`. T78 delivered the missing precondition
(the pane carries the five ORCHARD_* variables and the reverse-forward hook grant
completes), so the lifecycle contract can now reach the far side. Make a supervised
worker run on a remote host end to end: dispatch preamble injected into the remote
agent, capability minted and usable from over there, `send`/`check`/`worker_done`
crossing the tunnel, exit reconciliation and `worker-release` archiving the remote
pane's output. Where a piece genuinely cannot work remotely, refuse it typed and
say so in the report instead of pretending. Verify live against `orchard-loopback`
with a real supervised worker (a shell worker is enough — do not spend an agent
seat), and report exactly what crossed the tunnel. Owns
OrchardRuntime/Orchestration/WorkerVerbs*.swift and the remote paths it needs in
OrchardTerminals, matching tests, docs/reports/t80-remote-dispatch.md. Does not
touch the repo registry (T79), Files/**, or Conflicts/**.

**T81 — Dogfood cycle 7 (report-only).** Once T79 and T80 are merged the coordinator
will say so. Then, CLI only (never launch/quit the app; never touch terminals or
worktrees you did not create): run a local supervised cycle, a REMOTE supervised
cycle against `orchard-loopback`, exercise `repo` unregister on a remote repo, and
regression-sweep waves 19–21 (byte-exact conflicts, file fidelity, once automations,
typed exits, `hasOlder`, `project`/`worktree` subverbs). Report
docs/reports/dogfood-7.md with a findings table. Owns only that report.

### Backlog status (2026-08-26) — closed

Every item the earlier waves deferred is now resolved:

- **damson push / pin** — no longer a blocker: `0483173` is on `origin/main`, and
  damson has since released **v0.5.0**, which contains it. The exact-revision pin was
  retired for `.package(url: …, exact: "0.5.0")`; the full suite (1199), release build
  and headless e2e all pass against it. The "tag v0.4.2" item is obsolete — damson's
  release pipeline already shipped 0.5.0 (its CI committed the appcast), and cutting a
  damson release remains the owner's call, not something this repo needs.
- **Real-remote SSH verification** — done without a second machine
  (docs/reports/remote-verification.md, docs/reports/t78-remote-identity.md).
- **Editor decode-then-write, ensureExcluded truncation** — T75.
- **Intermittent full-suite failures** — two distinct flakes, both fixed (T76's socket
  load test; the FileWatcher microbenchmark, by the coordinator).
- **CLI surface gaps** — T77 (worktree subverbs, `project`, `hasOlder`).

Open by design / newly filed: `repo remove --forget` for remote repos (see wave 21),
supervised dispatch to remote stays typed-refused (identity is necessary but not
sufficient), and skills/artifacts/computer groups remain out of scope.

### Wave 16 source findings (from dogfood-4, docs/reports/dogfood-4.md)

Automations hardening: (1) fire-due races the in-process scheduler → double fire in
one minute slot; (2) shell-provider fires PASTE the preamble+prompt into zsh but
never execute it — the pane is left holding an unsubmitted paste carrying a live
capability (also a hygiene issue: don't leave capabilities sitting in pane input);
(3) '* * * * *' refires every minute until removed — consider a one-shot/`once`
schedule and/or auto-disable after N failures; (4) automation dispatches never
settle (worker-release lands retained/identity_unproven after worker-stop) — decide
the settlement story for automation-fired workers. Plus: repo-remove verb (registry
is permanent from the CLI today), typed errors still exit 0, help/flag nits,
main.swift window-frame autosave (why the smaller-window adopted-fit case is the
common one), and — only if clipping recurs — damson exposing an unconditional
follow re-pin.

### Wave 23 (T83–T85) — MERGED 2026-08-26, 1269+ tests

The remote story is closed. **T83** drove a real `claude-code` worker to settlement over
ssh (dispatch created 12:55:00, completed 12:55:18): the reverse tunnel bound on the far
side, hook config was written before launch, Claude ran Orchard's own Stop hook — so
remote readiness is hook-attested, not inferred. The run paid for itself three times
over: a remote agent could never have started on ANY real host because `ssh host '<cmd>'`
is not a login shell and PATH lacked `claude`; that failure reached the coordinator as a
bare "process has exited" with the pane's one-line explanation stranded (readiness
failures now carry the pane's last words); and `RemoteHookConfig`'s `mkdir -p` was
conjuring a missing remote worktree, so an agent came up in an empty directory wearing
the workspace's name (now `remote_worktree_missing`, typed). **T84** lets the app start
an agent on a remote workspace through the same runtime verbs the CLI uses, with host
chips and typed inline failures; the composer sheet and GUI clicks remain unverifiable by
synthetic input, and `worktree create --agent` is still `remote_unsupported`. **T85**
replaced the file service's blanket refusal with a real ssh backend for
read-dir/list/stat/preview/search under T75's byte rules (a far-side Latin-1 file comes
back typed `not_utf8`, never U+FFFD), keeping `open`/`open-changed`/`diff` refused with
stated reasons — a remote git-diff that hid untracked files would be a lie.

Still open after this wave: remote provider transcripts (refused typed; T85's transport
is the path to closing it), a durable connection with a generation counter, connection
multiplexing, and `HostLiveness.live` having no producer.

The SSH harness is live for this wave: host `orchard-loopback` (127.0.0.1:2222,
user-space sshd started by the coordinator; `orchard host check --name
orchard-loopback` → reachable). The coordinator tears it down at the end. Register
your own remote repo with `--host ssh:orchard-loopback` and drop it with
`repo remove --forget` when you are done.

**T83 — A real agent worker, supervised, on a remote host.** T80 and T82 proved the
lifecycle with *shell* workers; a `claude-code` worker has never been driven to
settlement over ssh, so the last unproven span of remote orchestration is the one that
matters most in practice: an agent TUI on the far side receiving the preamble as a
prompt, minting nothing locally, and sending `worker_done` back through the tunnel.
Drive exactly one such worker with a trivial task (create one scratch file and report),
release it promptly, and report what crossed — readiness detection (hooks vs
fingerprints), transcript availability, archive contents, and anything that behaved
differently from a local agent worker. Where a piece cannot work remotely, refuse it
typed and say so rather than papering over it. Fix what the run exposes, inside your
ownership. Owns: OrchardTerminals remote agent paths, OrchardRuntime/Orchestration
worker verbs where the run demands it, matching tests,
docs/reports/t83-remote-agent-worker.md. Does not touch Files/**, OrchardApp/**, or
the repo registry.

**T84 — Open a remote agent pane from the app.** `terminal create --worktree <remote>
--engine <agent>` has worked since T39, but the GUI only reaches remote *shell* panes:
the composer's engine picker and the workspace card's start/restart affordances stop at
the host boundary. Make the app able to start an agent on a remote workspace through
the same runtime verbs the CLI uses, with the host chip visible on the pane, failures
surfaced typed inline (never silent), and affordances that cannot work remotely
disabled with a reason rather than hidden. Verify live against `orchard-loopback` by
driving the running app through computer-use for *reading* (screenshots + AX) — the
coordinator will rebuild and relaunch for you on request; never launch or quit it
yourself. Owns: Sources/OrchardApp/ComposerView.swift, SidebarView.swift card
affordances, AppStore wiring, matching tests, docs/reports/t84-remote-agent-ui.md.
Does not touch OrchardTerminals, Files/**, or WorkerVerbs.

**T85 — A real remote file backend.** `file` verbs answer `remote_unsupported` for a
remote workspace, deliberately: resolving a remote path locally would be worse than an
error. Replace the refusal with a real backend for the operations that can be faithful
over ssh — listing, search, preview/read with the same byte-fidelity rules T75
established (never decode what will not round-trip), and open/reveal refused typed
where they mean a local GUI action. Keep the honest refusal wherever fidelity or
semantics cannot be preserved, and say which in the report. Verify live against
`orchard-loopback`, including a non-UTF-8 file. Owns:
OrchardRuntime/Files/**, a remote file transport where it belongs, matching tests,
docs/reports/t85-remote-files.md. Does not touch OrchardApp/**, WorkerVerbs, or
OrchardTerminals.

### Wave 24 (T86) — MERGED 2026-08-27: switching is ~30x faster

Two causes, and only the live app could show the second.

1. **Enumeration.** An `id:<repoId>::<path>` selector was resolved by enumerating every
   repo; per repo, `2+N` rev-parse calls where one `git worktree list --porcelain`
   suffices, and `GitService.status` spent 8 spawns where 3 do. Selectors now resolve
   from the repo they name, repos are read in parallel, and the app's
   `primaryCheckoutStatus` is async+detached with pane materialization moved out of
   `TerminalPane.body` into the pane's `.task` behind an "Opening…" placeholder.
2. **`Process.waitUntilExit()` polls the current run loop** — on the app's main thread
   that is AppKit's. Every git-touching RPC paid ~85 ms *per call, regardless of spawn
   count* (worktree show with one spawn cost the same as a three-repo list). GitRunner
   now reaps through the termination handler. Same cause as the older "live PTYs
   inflate every RPC" finding, which is gone with it, and `swift test` fell from ~229 s
   to ~113 s on the same machine with no other change.

Measured on the live app (coordinator's harness, baseline 24–26 ms):

| Call | before | after enumeration fix | after reaping fix |
|---|---|---|---|
| `worktree list` (3 repos) | 820 ms | 108 ms | **50 ms** |
| `terminal create --worktree` | 516–1000 ms | ~110 ms | **49 ms** |
| `worktree show` | — | 111 ms | **48 ms** |

Left open: the "Opening…" placeholder has never been *seen* — the computer-use
accessibility grant is refused machine-wide right now (Orchard and Finder alike), so
the visual pass is blocked on a human toggling that permission; and
`refreshAllStatuses` still fans out unbounded (3 spawns per worktree, N at once).

The user reports that selecting a workspace takes noticeably long to change the pane.
Measured on the live runtime (2026-08-27, three repos with one worktree each):

| Call | Cost |
|---|---|
| `orchard status` (CLI round-trip baseline) | **30 ms** |
| `terminal create --cwd <path>` (no worktree selector) | **~40 ms** |
| `terminal create --worktree id:<repo>::<path>` | **~530 ms** |
| `worktree list` (all three repos) | **~520 ms** |
| `worktree list --repo name:<one>` | **~210 ms each** |
| raw `git worktree list --porcelain` / `git status --porcelain` | **~29 ms each** |

So resolving a worktree selector costs half a second, and it is not git being slow:
one repo with ONE worktree spends ~210 ms, which is roughly six or seven `git`
spawns. The app pays this on the main thread — `AppStore.session(for:)` calls
`runtime.terminalService.create(worktreeId:…)` inline while the pane materializes —
so the first switch to a workspace stalls the UI for as long as the enumeration takes.

**T86 — Make workspace switching immediate.** Two halves, both required.
(1) *Make resolution cheap.* An `id:<repoId>::<path>` selector already names its repo
and path: resolving it must not enumerate anything. Where enumeration is genuinely
needed, collapse the per-worktree git calls (a single `git status --porcelain=v2
--branch` carries branch, ahead/behind and changes that separate spawns fetch today),
cache what is stable with honest invalidation, and parallelize across repos. Do not
trade correctness for speed: a cache that can serve a stale branch or status must
either be invalidated on the operations that change it or not exist.
(2) *Never block the main thread.* Pane materialization must not run a git enumeration
inline during view rendering; the pane should appear at once and fill in as the
session arrives, or the session should be prepared off the critical path.
Acceptance, measured the same way and reported in a table next to the numbers above:
`worktree list` for three repos and `terminal create --worktree` each **under 100 ms**,
and the app's workspace switch showing no synchronous git work on the main thread.
Owns: OrchardCore/Git + OrchardCore/Worktrees, OrchardRuntime/Workspaces,
Sources/OrchardApp/AppStore.swift pane materialization, matching tests,
docs/reports/t86-switch-latency.md. Does not touch Files/**, Conflicts/**,
Automations/**, or the remote transports.

### Wave 25 (T87) — MERGED 2026-08-27: a revisit costs no git at all

| | before | after |
|---|---|---|
| `git` processes per workspace, first visit | 5 | **3** |
| `git` processes per workspace, **revisit** | 5 | **0** (0.004 ms) |
| explorer watcher, per switch, on the main actor | **229 ms** (3754-entry walk) | **0.45 ms** |
| `git` in a view body, per sidebar re-render | 1 per project | **0** |

Status and conflicts are one reading now (they were five processes across two callers
that did not know about each other), cached per worktree and served only while a
watcher is alive over everything that could make the reading untrue — no watcher, no
cache, because a value nobody is watching can quietly become a lie.

Two findings came out of refusing a number rather than accepting it. The `reads=4` the
worker first reported as attributable was still process-wide sampling; it is a task
local bound *around* the phase now, which is also why the trace helpers became closures
— a value has to be bound around the work, not sampled either side of it. Chasing that
exposed the real one: the workspace the user just picked joined the launch fan-out's
*queue position* along with its reading, so being coalesced made it wait. A foreground
request now promotes the queued ticket out of the background queue (a no-op once the
git process has started, since that is not interruptible).

Five synchronous-git-in-a-view-body sites are gone: `rootSubtitle` (the branch was
already in the status reading — there was never anything to ask git for),
ProjectCheckoutDiffPane, ComposerView.branches (`git for-each-ref` per keystroke),
DeleteWorktreeSheet.preflight (a whole 3-process reading per render of the sheet), and
FileExplorerModel.applyFilter (a tree walk per keystroke). The biggest single number was
in nobody's trace at all: `FileWatcher.start` took its baseline snapshot synchronously.

Still PENDING: the switch-path rows measured through the GUI. The report names the exact
invocation and the six clicks; the instrumentation ships behind `ORCHARD_TRACE_SWITCH=1`.

The user, after T86: "still a bit slow — cc-rate-widget to CAN-debugger-hw". The
coordinator instrumented the live app (`ORCHARD_TRACE_SWITCH=1`, committed) and
measured. What T86 fixed stayed fixed — pane materialization 0.0 ms, explorer reload
0.3 ms — and what is left is git work per switch:

| Phase (live app, CAN-debugger-hw = 3353 files / 498 MB) | Cost |
|---|---|
| `refreshConflicts` (runs on every workspace key change) | **445 ms** |
| `refreshCheckout` → `GitService.status` (3 spawns) | **209 ms** |
| the same three git commands run raw from a shell | 39 + 36 + 28 = ~103 ms |
| one `git` spawn, any command, this machine | **~30 ms** |

So the floor is the spawn: a switch runs several git commands and each costs ~30 ms
before git does any work, and the app pays roughly double what the raw commands cost.
CAN-debugger-hw has **zero** untracked files, so `untrackedChanges` (which reads every
untracked file) is not the cause here — but it would be on a repo that has them.

**T87 — Make a switch cost no git at all.** Two rules. (1) *Nothing on the critical
path.* Rendering a workspace must not wait on git: the pane, the tree and the card
appear immediately, and status/conflict facts arrive after, visibly late rather than
blocking. (2) *Do not recompute what has not changed.* Cache per-worktree git facts
(status, conflict summary, branch) keyed by worktree, invalidated by the FS watcher
already running and by the operations that mutate the tree — so switching back to a
workspace visited a moment ago spends nothing. Honest invalidation only: a cache that
can serve a stale branch or a resolved conflict must be invalidated by whatever
changed it, or not exist. Also collapse `refreshConflicts` (measure its spawns first —
it costs twice `status`) and coalesce concurrent refreshes of the same worktree into
one in-flight request. ACCEPTANCE, measured with `ORCHARD_TRACE_SWITCH=1` on the live
app and reported as a table: switching between two already-visited workspaces triggers
**zero** git spawns on the critical path, a first visit's git work is off it, and the
trace shows no phase over 50 ms in the switch itself. Owns: OrchardCore/Git,
OrchardCore/Worktrees, Sources/OrchardApp (AppStore, ProjectSession, FileExplorer),
matching tests, docs/reports/t87-switch-cache.md. Does not touch remote transports,
Automations, or Conflicts/** beyond what the summary path needs.

### Wave 26 (T88–T91) — MERGED 2026-08-27, 1471 tests

The last three dispatchable Orca gaps, plus a chrome pass the user asked for.

- **T88 checks.** Typed issue/PR links on worktree meta, a checks sidebar section
  and a check-details tab, over `gh` when it is present and authenticated. Every
  unavailable path is typed and visible (no gh, not authenticated, no remote, no PR
  for this branch, API error) — never a blank panel, never a guessed status. Reads
  only: every `gh` call in the code, tests and report is `pr view` / `pr list` /
  `auth status` / `run view --log`.
- **T89 remote durability.** Durable connection with a generation counter (a
  reconnect can no longer be mistaken for continuity), multiplexing, the first
  producer for `HostLiveness.live`, and remote provider transcripts on T85's
  transport.
- **T90 the three named views.** Read Orca, wrote `docs/research/orca-views.md`, and
  built **one**: Space (workspace disk usage and reclaimable storage — nothing else
  in Orchard shows bytes). `activity` is redundant with the Agent Dashboard and is a
  default-off prototype in Orca itself; `tasks` is a hosted issue board, a different
  noun from an orchestration Task. Both left unbuilt, with reasons.
- **T91 chrome.** Orca's rules, found by reading it: selection is neutral (a wash of
  the foreground plus a bright edge, never the accent), hover changes fill only, the
  list has no dividers, and group headers are the same size as card titles with
  weight doing the hierarchy. Adopted. **Refused**: the inset rounded card tile —
  the single most recognisable "looks like Orca" move, and the one thing the user
  had already complained about — plus fixed-width tabs, which need a scrolling strip
  first.

Coordinator, same day, from the user's own use: ⌘T / ⌘D / ⇧⌘D / ⌘W / ⇧⌘W bound the
way a terminal app binds them (⌘W closing the window is what read as "the app jumped
to another screen"), a split that would leave an unusable sliver now refuses with the
reason in the status bar, the workbench no longer draws under the status bar, the
workspace column is an opaque square-edged pane, and a new workspace opens with a
terminal instead of a terminal plus a Diff tab nobody asked for.

GUI verification, 2026-08-29 — the five surfaces that only a click could reach are
checked off in [`docs/reports/wave26-gui-verification.md`](reports/wave26-gui-verification.md):
the Checks sidebar renders the CLI's typed refusal with its provenance line, Source
Control stages/refuses/commits end to end, the floating terminal round-trips with the
session intact, the automation sheet's "Next 3 fires" is a real cron evaluation (it skips
the weekend, and shows nothing rather than a guess for an unparseable field), and the
conflict pane's per-hunk `Undecided | Ours | Theirs | Both` writes and stages the
resolution. Two findings: the Source Control panel does not poll, so an external change to
the worktree needs its ↻; and the auto-added Conflicts tab lingers after the merge ends
until an unrelated `refreshGit` retracts it. Every state was built in an Orchard-made
worktree on a local-only branch and restored byte for byte.

### Wave 27 (T92–T94) — GitHub pull requests: open, read, act

Chosen over adding more agent engines. Measured against Orca on 2026-08-29, the
honest gap is breadth, not spine: 5 engines against ~20, and **1 forge against
7**. Of the two, the forge is the one that changes a working day. Orca's PR
surface splits into create / fetch / list / update / merge / lookup / check —
and `check` plus `lookup` are already ours from T88, so this wave is the other
four.

**The spine landed first (`6e3ea1f`), not as a task.** Three workers needed the
same foundation and inventing it three times would have produced three stderr
vocabularies. `GitHubPRGateway` is the only place pull-request code runs `gh`;
`PullRequestRefusalReason` names twenty-six dead ends, sharing raw values with
T88's `ChecksUnavailableReason` for the facts that are genuinely the same while
keeping remedies apart ("then refresh" is right for a reading, wrong for a
write). Verified against the real gh 2.98.0 field list and a live GraphQL
`reviewThreads` shape rather than from memory — which is how we learned that
line-anchored threads are simply absent from `gh pr view --json`.

- **T92 create.** Eligibility as evidence, not a boolean: a ladder where every
  rung is a named refusal, base resolved from the repo default rather than
  guessed at `main`, template discovery, and — the rule Orca learned the hard
  way — `existingLookup` keeping `.unavailable` apart from `.notFound`, because
  conflating them is how a second pull request gets opened. Pushing is never
  silent.
- **T93 read.** One `gh pr view --json` for the detail; a paginated GraphQL
  query for review threads, because a PR with 101 threads must not quietly show
  100. Outdated threads are shown and marked, never hidden — a stale objection
  is still an objection.
- **T94 act.** Review verdicts, line-anchored comments, thread resolve/reply,
  merge, draft/close/reopen. Mergeability `.unknown` is GitHub still computing:
  not permission to merge, and not a refusal either. Nothing destructive fires
  from a hover or a bare shortcut, and `--yes` is required at the CLI —
  Orchard is driven by agents, and an accidental merge is unrecoverable in a
  way an accidental commit is not.

Deferred to a later wave, deliberately: diff-anchored comment rendering inside
the diff pane (it needs T93's threads and T94's mutations to both exist first).

### Wave 26 source (T88–T90) — close the Orca gap

After wave 25 the switch is fast and the parity checklist (inventory §8) is done. What
Orca still has that Orchard does not falls into three dispatchable pieces. The fourth —
a human driving four GUI surfaces — cannot be dispatched and stays with the user.

**T88 — Checks: CI and pull-request state on the card and in the sidebar.** Inventory §6
lists `pr-checks` and `checks` as right-sidebar sections and check-details as a center
tab; §2 gives cards typed `issue`, `linear-issue`, `jira-issue`, `pr` and `ci` properties.
Orchard stores `linkedIssue`/`linkedPR` as bare strings and shows no CI state at all.
Build it against GitHub first (the forge this repo uses), via the `gh` CLI when it is
present and authenticated: typed link fields on worktree meta, a checks section listing
the PR's checks with their conclusions, and a check-details tab for one run's output.
Every unavailable path must be typed and visible — no `gh`, not authenticated, no
remote, no PR for this branch, API error — never a blank panel and never a guessed
status. Nothing may block the main thread or a workspace switch (wave 25's rules hold:
no network or subprocess in a view body, results cached with honest invalidation).
Owns: OrchardCore/Worktrees meta link fields, a new OrchardRuntime/Checks service +
verbs, Sources/OrchardApp/Checks/**, sidebar section wiring, tests,
docs/reports/t88-checks.md. Does not touch Git*/GitFactsCache internals, Automations,
Conflicts/**, or remote transports.

**T89 — Finish the remote transport.** Four leftovers, all named in
docs/design/remote-hosts.md: a durable connection with a **generation counter** so a
reconnect can never be mistaken for continuity; connection multiplexing (today every
command is its own `ssh`); a producer for `HostLiveness.live` (presentation-only today,
with no path that ever sets it); and remote provider transcripts, which stay refused
typed even where the file is local — T85's transport is the way to close that. Keep the
verdict discipline: loss of contact is `unverifiable`, never `exited`, and a
generation-fenced reconnect must refuse to answer for the old generation rather than
guess. Verify live against the coordinator's loopback host. Owns:
OrchardRuntime/Hosts/**, OrchardTerminals remote paths, docs/design/remote-hosts.md,
tests, docs/reports/t89-remote-durability.md. Does not touch Checks/**, Files/**, or
OrchardApp.

**T90 — What `activity`, `tasks` and `space` actually are.** Inventory §6 names three
Orca top-level views we never specified and never built. `~/dev/orca` is on this machine,
read-only. Read it, write what each view *is* — its data, its actions, what it is for
that the workbench and the orchestration view do not already cover — into
docs/research/orca-views.md, then implement the one with the highest value for this app
and say plainly why the other two were left (including "this is redundant with what we
have", if that is the honest answer). Do not build all three on speculation. Owns:
docs/research/orca-views.md, whichever view you build under Sources/OrchardApp/**, its
runtime projection if it needs one, tests, docs/reports/t90-views.md. Does not touch
Checks/**, Hosts/**, Git*, or Automations.

### Standing backlog (reconciled 2026-08-26)

Everything the old wave-13+ list carried has since been closed and is recorded in its
wave section: respacedLines on the wire (T55), capture fidelity — root-caused
Orchard-side, damson untouched (T54) with `respacedLines: 0` in every dogfood since,
both intermittent test failures (T76 + coordinator), branch deletion and the
human-readable remote worktree-list (T53), window lifecycle (T51), the reverse-forward
hook grant and remote identity (T78), supervised remote dispatch (T80), and the
shell-worker contract (T82). What genuinely remains:

**Remote, still real work**
- A supervised worker running a real *agent* engine on a remote host. T80/T82 proved
  the lifecycle with shell workers; a remote `claude-code` worker has never been driven
  to settlement.
- App-side opening of a remote *agent* pane. `terminal create --engine <agent>` against
  a remote worktree works since T39, but the GUI reaches remote shell panes only.
- A real remote file backend: `file` verbs answer `remote_unsupported` for a remote
  workspace by design (resolving remote paths locally would be worse than an error).
- Durable connection with a generation counter, and connection multiplexing — today
  each command is its own `ssh`.
- `HostLiveness.live` has no producer (deliberate: presentation-only).

**Open by design (revisit only if a use case appears)**
- Remote provider transcripts are unresolvable; a restored ended pane has no scrollback
  (the keeper cannot hand back a dead pane's buffer).
- `skills`, `artifacts`, and `computer` command groups are out of scope (T77).

**Owed to a human**
- GUI surfaces that shipped unit- and CLI-verified but never driven by a person:
  the conflict-review pane's per-hunk controls, the source-control panel's staging and
  commit flow, the floating terminal, and the Automations editor sheet. Synthetic input
  cannot stand in — `orca computer press-key` does not reach SwiftUI's key handling
  (System Events key codes do), and taps on SwiftUI gesture handlers do not fire.

### Wave 16 source findings (from dogfood-4, docs/reports/dogfood-4.md)

Automations hardening: (1) fire-due races the in-process scheduler → double fire in
one minute slot; (2) shell-provider fires PASTE the preamble+prompt into zsh but
never execute it — the pane is left holding an unsubmitted paste carrying a live
capability (also a hygiene issue: don't leave capabilities sitting in pane input);
(3) '* * * * *' refires every minute until removed — consider a one-shot/`once`
schedule and/or auto-disable after N failures; (4) automation dispatches never
settle (worker-release lands retained/identity_unproven after worker-stop) — decide
the settlement story for automation-fired workers. Plus: repo-remove verb (registry
is permanent from the CLI today), typed errors still exit 0, help/flag nits,
main.swift window-frame autosave (why the smaller-window adopted-fit case is the
common one), and — only if clipping recurs — damson exposing an unconditional
follow re-pin.

### Wave 13+ backlog

T52 follow-ups: (a) Report.respacedLines exists but the runtime's chromeStripped
receipt does not serialize it (WorkerVerbs was outside T52 ownership) — small wire
addition; (b) the real capture-fidelity fix is upstream: wide pastes arrive in the
output stream already collapsed and torn repaints drop characters before the cleaner
ever runs — needs investigation in the damson outputBytes/stream-buffer path (damson
change; coordinate with the pin).

From dogfood cycle 3: the "transient app exit" during the cycle matches a clean
window-close (no crash log, metadata removed cleanly). T51 changes that
lifecycle — closing the workbench keeps the in-process runtime alive; Dock /
windowless activation restore it; Cmd-Q still takes the T23 termination path;
the Dock and Orchard menus show a truthful "Runtime alive · rt_…" while the
socket is listening. Human visual pass: `docs/reports/t51-window-lifecycle.md`.
Archive word-collapse persists in TUI frames (Taskcompleteanddispatchsettled)
— a third cleaner pass or accepting raw-only for TUI frames.

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
