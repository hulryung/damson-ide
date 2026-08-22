# Orca feature & architecture inventory (rebuild source spec)

Surveyed from `/Users/dkkang/dev/orca` (Electron + React + TS). This is the source spec for
rebuilding Orca's core functionality natively in Orchard. File paths below refer to the orca
repo and are for reference reading only.

**The single most important architectural fact: Orca's product is a runtime daemon with an
agent-facing RPC/CLI surface, and a UI that is a client of it.** The rebuild must build the
runtime first (worktree registry + PTY host + orchestration DB + local socket RPC), then the
AppKit/SwiftUI shell on top.

## 0. Control plane

- Runtime metadata `{runtimeId, pid, transports[], authToken, startedAt}` written to
  `<userData>/orca-runtime.json` (`src/shared/runtime-bootstrap.ts`).
- Transports: unix socket (CLI path), plus websocket for remote/headless.
- Wire: newline-delimited JSON frames, one connection per request. Server may interleave
  `{"_keepalive":true}` frames during long-polls; each keepalive resets the client timeout
  (this is how `check --wait --timeout-ms 900000` survives a 60s default ceiling). Clean FIN
  before a terminal frame = `runtime_unavailable`. (`src/cli/runtime/transport.ts`)
- Response envelope: `{ id, ok, result | error:{code,message,data}, _meta:{runtimeId} }`.
- Modes: app mode (runtime inside the GUI app), headless `orca serve`, paired remote
  environments (`--environment X` routes over WebSocket).

### Agent-context discovery (how an agent inside a worktree finds the runtime)

Env vars injected into every managed PTY:
- `ORCA_TERMINAL_HANDLE` — this pane's terminal handle (`term_<uuid>`); implicit `--from`.
- `ORCA_PANE_KEY` — durable pane identity `"<tabId>:<leafUUID>"`; survives handle reminting;
  orchestration authority is keyed on it, not the handle.
- `ORCA_WORKTREE_ID` (`<repoId>::<path>`), `ORCA_WORKSPACE_ID`, `ORCA_CLI_COMMAND`,
  `ORCA_USER_DATA_PATH`, `ORCA_AGENT_LAUNCH_TOKEN` (launch-token proof), `ORCA_CLI_CWD`.
- `orca agent-context --json` serializes the entire command spec table (pure local read,
  no runtime needed): `{schemaVersion, commands:[{command, aliases, summary, usage, flags[],
  positionalArgs[], examples[], notes[]}]}`.
- `orca skills list` / `orca skills get <topic>` serve **version-matched guides from the
  binary itself**; installed skill files on disk are content-free stubs. Keep this pattern —
  it is the reason agents don't hallucinate flags.

## 1. Orchestration

### 1.1 The four nouns

| Noun | What it is |
|---|---|
| **Run** | Durable namespace + coordinator inbox. Never schedules or places workers. |
| **Task** | Work item with a spec and DAG deps. |
| **Dispatch** | One *attempt* assigning one Task to one terminal. **Lifecycle authority lives here.** |
| **WorkerDispatch** | Supervised-worker resource accounting for a Dispatch (state machine + owned terminal). |

A retried Task has multiple dispatch rows. `worker_done`/`heartbeat` are keyed on
`(taskId, dispatchId)` so a late message from a dead attempt cannot settle the live retry.

### 1.2 Persistence — SQLite at `<userData>/orchestration.db`

```
runs(id, objective, coordinator_handle, coordinator_pane_key, consumer_generation, …)
messages(id, run_id, from_handle, to_handle, subject, body, type, priority, thread_id,
         payload, read, sequence AUTOINCREMENT PK, created_at, sender_pane_key)
deliveries(id, run_id, consumer_generation, message_ids JSON, status, acknowledged_at)
  -- UNIQUE partial index: only ONE 'outstanding' delivery per run
tasks(id, run_id, parent_id, created_by_*, task_title, display_name, spec, status,
      deps JSON, result, created_at, completed_at)
dispatch_contexts(id, run_id, task_id, launch_token_hash, assignee_handle, assignee_pane_key,
      capability_hash, process_incarnation, status, failure_count, termination_reason, …)
decision_gates(id, run_id, task_id, question, options JSON, status, resolution, …)
worker_dispatches(dispatch_id, state, stage, worktree_id, agent_terminal_handle,
      setup_state, effects JSON, residual_resources JSON, …)
worker_terminal_resources(id, origin/owner_dispatch_id, terminal_handle, pane_key,
      ownership_state, release_state, retained_reason, …)
worker_terminal_archives(dispatch_id, kind:'transcript_pin'|'terminal_tail', content, …)
mutation_receipts(caller_fingerprint, request_id, method, payload_hash, state, receipt)
questions(message_id, run_id, dispatch_id, asker_handle, status, answer_*, …)
```

### 1.3 Enumerations (copy verbatim)

```
MessageType     = status | dispatch | worker_done | merge_ready | escalation
                | handoff | decision_gate | question | heartbeat
MessagePriority = normal | high | urgent
TaskStatus      = pending | ready | dispatched | completed | failed | blocked
DispatchStatus  = pending | dispatched | completed | failed | circuit_broken
GateStatus      = pending | resolved | timeout
QuestionStatus  = pending | answered | closed
DeliveryStatus  = outstanding | acknowledged | fenced
WorkerDispatchState = starting | ready | start_unknown | failed | succeeded
                    | stopping | stop_unknown | stopped | abandoned
WorkerTerminal ownership_state = owned | transferred | user_owned | external | released
WorkerTerminal release_state   = not_requested | retained | requested | releasing | released | unknown
WorkerReportOutcome = succeeded | failed
```

### 1.4 Agent-facing command surface (exact names)

Run: `run-create --objective`, `run-use --id [--takeover-legacy]`, `run-current`,
`run-list`, `run-show`.

Messaging:
```
send   --subject [--to run:id|dispatch:id|handle|@group] [--body] [--type] [--priority]
       [--thread-id] [--payload json] [--task-id] [--dispatch-id] [--outcome succeeded|failed]
       [--files-modified csv] [--report-path] [--phase] [--retry-request id]
check  [--terminal h] [--run id] [--ack delivery_id] [--unread|--peek|--all] [--types csv]
       [--format] [--wait] [--timeout-ms n] [--retry-request id]
reply  --id msg_id --body text
ask    (--question t | --resume message_id) [--options csv] [--timeout-ms n]
inbox  [--limit n] [--full]
```

Tasks/dispatch: `task-create --spec [--task-title] [--display-name] [--deps json] [--parent]`,
`task-list [--status] [--ready] [--brief]`, `task-update --id --status [--result json]`,
`dispatch --task --to handle [--inject] [--dry-run] [--return-preamble]`, `dispatch-show`.

Supervised worker lifecycle:
```
worker-start   --task id [--on env] [--worktree current|<sel>|new-child|new-top-level]
               (--agent a | --terminal h) [--model id] [--effort lvl] [--name n] [--repo sel]
               [--base-branch ref] [--setup run|skip|inherit] [--retry-of dispatch_id]
worker-show    --dispatch id
worker-read    --dispatch id [--source auto|transcript|terminal] [--cursor] [--limit]
worker-stop | worker-abandon | worker-release | worker-retain   --dispatch id
worker-list    [--terminal-state …]
```

Gates: `gate-create --task --question [--options json]`, `gate-resolve --id --resolution`,
`gate-list`. Recovery: `reset (--all|--tasks|--messages)`.

Group addresses: `@all`, `@idle`, `@worktree:<id>`, agent groups `@claude @codex @grok
@cursor …`. Resolved **at send time — one message row per recipient sharing a thread_id**.
Group send forbidden for `worker_done`/`heartbeat`.

### 1.5 Coordinator model

There is **no scheduler**. The coordinator is an LLM agent running the loop by hand:
run-create → task-create ×N → worker-start ×N → `check --wait --types
worker_done,escalation,question` → reply to questions, release/reuse workers, ack, repeat.

Delivery semantics (critical):
- A coordinator `check` returns the Run's **oldest unacknowledged FIFO batch, max 50
  messages**. That exact batch **replays verbatim until `--ack <delivery_id>`**. Only one
  `outstanding` delivery per Run (unique partial index).
- `--types` filters only what *wakes a waiter*; the returned batch is still the full oldest batch.
- `consumer_generation` on the Run is a fence: rebinding bumps it; stale consumers get
  `consumer_fenced`.
- `check --wait` is a real long-poll (message-arrival notifications resolve waiters; socket
  keepalives every 15s).
- A `check --wait` timeout or `{count:0}` is a checkpoint, not a failure.
- Every mutating command takes `--retry-request <id>`; `mutation_receipts` keyed on
  `(caller_fingerprint, request_id)` + payload hash makes exact-retry safe.

### 1.6 Dispatch preamble (the injected worker contract)

Built per dispatch with real IDs inlined:
1. `send --type worker_done … --task-id … --dispatch-id … --outcome succeeded|failed
   --files-modified … --report-path …` — REQUIRED exactly once; body = 3-sentence summary.
2. `send --type heartbeat --phase <investigating|implementing|reviewing|waiting>` every 5 min.
3. `ask --question … --options … --timeout-ms 600000` with BEHAVIOR RULE #1: NEVER use a
   local interactive prompt (AskUserQuestion) — the coordinator cannot see it and the session
   hangs forever.
4. `send --type escalation` for pre-completion blockers.
5. After `worker_done`: a prompt-returning agent idles at its prompt (does not exit, does not
   poll); a bare shell exits. A direct user instruction is new user-owned work — never refuse
   it citing worker role.
6. Optional BASE DRIFT section when the worktree base is behind.
7. `=== TASK ===` + the spec.

`dispatchCapability` is a secret passed on dispatch; only its SHA-256 is stored. Combined
with `assignee_pane_key`, `launch_token_hash`, `process_incarnation`, this proves a
`worker_done` came from the actual dispatched pane.

### 1.7 worker-start pipeline stages

`worktree_create → terminal_create → setup_start → agent_readiness (wait tui-idle, default
60s) → capability minting → dispatch_input (inject preamble) → ready`. Receipt reports
`{state, stage, failedStage?, setup:{requested,effective,…}, launch:{requested,effective},
effects[] {kind, action:created|reused, id}, residualResources[], nextCommands?}`.
Exit 0 only for `ready`; `start_unknown` surfaces as outcome_unknown with recovery commands.

### 1.8 Failure/escalation/cleanup semantics (the surprising parts)

- **Circuit breaker: 3 consecutive dispatch failures ⇒ circuit_broken, task failed.**
- **Worker process exit auto-escalates** (priority-high escalation message to the Run,
  wakes `check --wait`) — but only for non-deliberate exits. Lookup is by handle OR pane key
  (reminted handles no longer match; the pane outlives them).
- Escalation triage rejects: no exact `{taskId,dispatchId}`, dispatch↛task mismatch,
  unproven sender, or a task whose supervised worker is still live.
- **Stale heartbeat (10 min = 2× cadence) warns only, never auto-fails.**
- **Decision gates are never auto-resolved**; tasks with pending gates are force-re-blocked
  every tick. A resolved gate's Q&A is appended to the next dispatch preamble.
- **worker-release archives output first** (transcript pin / terminal tail) so worker-read
  still works after the terminal closes; refuses to close setup terminals, default tabs,
  reused/pre-existing terminals, user-taken-over terminals, unproven identities. Idempotent.
- `dispatch --inject` (low-level) creates NO worker_dispatches row → `unsupervised`;
  worker-stop/abandon never touch its process.
- `worker-read --source auto` returns the hook-reported provider transcript when the session
  can be proven, else bounded terminal output with typed `fallbackReason`. Cursors pin to a
  source; `source_changed` invalidates.
- `worker-show.observation.agentWait`: object = proven human-only wait (evidence `hook |
  prompt-text | title`); `null` = looked, found nothing; **absent = never looked** (must not
  read as "not waiting"). Three-state optional, not a Bool.
- Handoff vs orchestration is a hard product boundary: full handoff = create worktree with
  agent+prompt, then stop monitoring. No task rows, no preamble, no check --wait.
- When liveness/authority can't be proven: **degrade to read-only inspection, never fall
  back to local execution.**

## 2. Workspace / worktree model

### Identity
- Worktree id = `` `${repoId}::${path}` ``. A bare repo id is NOT a worktree id.
- Folder workspaces reuse the id space: `` `${repo.id}::${repo.path}` `` and
  `…::workspace:<uuid>` for multiple sessions on one folder; they project into the same
  `Worktree` shape (empty head/branch) so all UI/RPC treat both uniformly.
- `instanceId` (UUID) = immutable per-workspace-instance identity; rejects stale lineage
  after path reuse.
- `ExecutionHostId = 'local' | 'ssh:<id>' | 'runtime:<id>'` stamped on everything.

### Worktree fields (beyond git facts)
`displayName, comment, linkedIssue/PR/LinearIssue/…, isArchived, isUnread, isPinned,
sortOrder, manualOrder, lastActivityAt, createdWithAgent, baseRef, pushTarget,
priorWorktreeIds, workspaceStatus, diffComments`. Persisted user-authored subset =
`WorktreeMeta` keyed by worktree id in the JSON store.

### workspaceStatus ("cardStatus") — user-set board columns
Defaults: `todo("Todo"), in-progress("In progress"), in-review("In review"),
completed("Done")` + user-defined `{id,label,color?,icon?}`. **Distinct from** the derived
live status `RuntimeWorktreeStatus = active|working|permission|done|inactive`.

### Card properties
`status, unread, ci, branch, issue, linear-issue, jira-issue, pr, automation, cli, comment,
ports, inline-agents`; `status`+`unread` fixed; Default vs Compact modes.

### Lineage
`WorktreeLineage {worktreeId, parentWorktreeId, origin: orchestration|cli|manual,
capture:{source, confidence: explicit|inferred}, orchestrationRunId?, taskId?, …}`.
Parent inferred from calling terminal/cwd when possible. **`--no-parent` controls lineage
only; `--base-branch` chooses the git base. Orthogonal.** Sidebar lineage ≠ orchestration
lifecycle.

### Creation / naming / retirement
- Agent-first creation is the required pattern: `worktree create --agent <a> [--prompt]`
  launches the agent in the first terminal, returns `agentTerminalHandle`. Bare create +
  later terminal-create leaves an orphan fallback shell (anti-pattern).
- Created in background by default; `--activate` reveals.
- Auto-naming from a marine-creature pool (~552) with **permanent name retirement** — a
  spent name is never reissued because the old directory may still hold agent conversation
  state keyed to that path. Compact registry `{exhaustedTiers, names[]}` per repo and per
  remote namespace.
- Selectors: `id:<repoId>::<path>` · `name:` · `path:` · `branch:` · `issue:` ·
  `active`/`current` (longest enclosing managed worktree from cwd).
- Removal with safety/fencing/trash; archive hooks only with `--run-hooks`.

### Per-worktree session state (persisted)
Tabs by worktree, tab-group layouts, pane layouts, open files, browser tabs/pages by
workspace, active ids, last-visited, sleeping agent sessions by paneKey, PTY incarnations
by paneKey, topology revision by repo. Per-host partitioning (`local` + by ExecutionHostId).

### Per-repo config: `orca.yaml`
```yaml
scripts: { setup: <sh>, archive: <sh> }
issueCommand: <sh>
defaultTabs: [{title, color, command}]
environmentRecipes: [...]
worktree: { sharedDirectories: [...] }
```
Policies: `SetupRunPolicy = ask|run-by-default|skip-by-default`,
`SetupAgentStartupPolicy = start-immediately|wait-for-setup`,
hook scripts are content-hash trusted.

### Persistence locations (macOS, `~/Library/Application Support/<app>/`)
`orca-data.json` (all durable state), `orca-github-cache.json` (droppable sidecar),
`orchestration.db` (SQLite), `orca-runtime.json`, terminal history/scrollback snapshots.
Capture the userData path once at boot.

## 3. Terminals & agent sessions

### Identity layers (all four matter)
- `handle` = `term_<uuid>`, runtime-scoped, **remintable** (stale → `terminal_handle_stale`;
  re-list and use the replacement only, never dual-send).
- `paneKey` = `"<tabId>:<leafUUID>"` — durable; orchestration authority keys on it.
- `ptyId` + `incarnationId` — the live process channel and respawn counter.
- `process_incarnation` — host-issued proof in dispatch authority.

Layout: worktree → tab groups (split tree) → tabs (`contentType = terminal|editor|diff|
conflict-review|check-details|browser|simulator`; per-tab viewMode `terminal|chat`) →
panes (split tree of leaves).

### Command surface
```
terminal list [--worktree] [--include-visual-layouts]     # layouts omitted by default
terminal show|read|send|wait|create|split|switch|close|rename|stop
terminal read [--cursor n] [--limit n] [--screen]
  # default = accumulated stream, escapes stripped → repainted lines come back as stacked
  # fragments; --screen = rendered frame. Result reports source: stream|screen|screen-unavailable.
terminal send [--text t] [--enter] [--interrupt]  → {accepted, refusedReason?: no-agent|permission}
terminal wait --for exit|tui-idle [--timeout-ms n]
```

### Turn-state detection stack (priority order)
1. **Agent hooks (authoritative).** Managed hook scripts installed into each agent's own
   config POST status to a local HTTP endpoint (claude, codex, gemini, cursor, grok, … 14
   targets). Payload: prompt, tool name/input, last assistant message, model, provider
   session id, subagent rosters, is_interrupt.
2. OSC title status.
3. Rendered-prompt heuristics (known ready-prompt previews; typed blocked reasons:
   update-prompt, trust-workspace, model-migration, approval-prompt, …).
4. Foreground-process check (agent idle vs shell prompt).

States: agent `working | blocked | waiting | done`; runtime projection `working | permission
| idle | null`.

**`terminal wait --for tui-idle` rules:**
- Only `idle` satisfies it — `permission` does NOT.
- Fast paths: already-idle lastAgentStatus, explicit idle OSC title, known ready-prompt.
- `lastAgentStatus` is a factual record — never cleared when a waiter consumes it (clearing
  made later waiters hang).
- Resolves on ANY transition to idle, not just working→idle.
- Pre-flight detection of typed blockers so a startup modal doesn't look like a hang.
- Default timeout enforced; PTY exit rejects the waiter immediately.

### Prompt delivery to an agent TUI (exact trick)
1. Replace every raw ESC in the prompt with literal `<ESC>`.
2. Wrap in bracketed paste `\x1b[200~ … \x1b[201~`.
3. Chunked writes, yielding between chunks; on mid-write failure still emit the closing
   `\x1b[201~`.
4. Arm a render gate before the last chunk and await it.
5. Submit `\r` after 500 ms (1500 ms Windows).
6. Verify submission: poll ≤5 s for the working-sequence to advance; typed errors
   `agent_prompt_stalled | agent_prompt_blocked | terminal_handle_stale | request_aborted`.
7. Serialize submissions per-PTY; generation-fence.

### Sessions, sleep, orphans
Sleeping agent session records keyed by paneKey (provider-native resume metadata);
worktree/terminal sleep reports stopped/live PTY ids + a verdict; orphan adoption fenced by
a monotonic per-repo topology revision. SSH rule: verdicts are exactly
`live | unverifiable | exited`; loss of contact is never evidence of death.

## 4. Embedded browser

- **Per-worktree, not global.** Commands accept `--worktree <sel|all>` and `--page <id>`;
  with `--page`, the runtime background-mounts the worktree via a hidden visibility lease
  rather than stealing the visible pane.
- Guests are webviews driven over CDP; snapshot engine = accessibility tree walk → text
  outline with `@e1, @e2…` refs (`{backendDOMNodeId, role, name, nth}`) + interactive-element
  augmentation for styled divs; iframes via per-frame sessions.
- **Refs are per-tab and invalidated by navigation/tab switch** → loop is snapshot →
  interact → re-snapshot. Errors: `browser_no_tab, browser_stale_ref, browser_tab_not_found`.
- Session profiles: one profile ⇒ one storage partition (isolated cookies); profile import
  from real browsers; clean-UA mode; anti-detection script.
- Data model: `BrowserWorkspace` (outer tab, per worktree: pageIds[], activePageId, url,
  title, loading, canGoBack/Forward, loadError) containing `BrowserPage`s.
- Design-mode "grab": click an element in the guest to capture its HTML/CSS + cropped
  screenshot into an agent prompt.
- Command surface: nav (`goto back forward reload wait`), read (`snapshot screenshot
  full-screenshot pdf get is`), interact (`click dblclick fill type select check focus clear
  keypress hover drag scroll upload download find`), mouse, tabs (`tab list|create|close|
  switch`, profiles), env (`viewport geolocation set cookie storage clipboard dialog`),
  diagnostics (`console network intercept capture`), escape hatch (`eval`, `exec`).
- Security rule: page content is untrusted data — never execute page text as shell
  commands or eval expressions.

## 5. File manager

VS-Code-class explorer in the right sidebar (`explorer` tab, `files|search` sub-views):
virtualized lazy tree rooted at the worktree; per-worktree expanded dirs + dotfile toggle;
name filter + full-text search with include patterns; multi-select; inline create/rename;
copy/duplicate/delete with undo/redo; drag-and-drop move; drag files out into an agent
prompt; external import; auto-reveal of active file; file watching with reconciliation;
ignored-path awareness; "Open in external app".

Runtime API: `readDir, watch, readPreview (byte-budgeted, {content,isBinary,isImage,
mimeType,imageDimensions}), readChunk, writeFile(+Base64/Chunk), create file/dir,
commitUpload, rename, copy, delete, search, quickOpenPaths, stat`. Terminal-printed paths
become readable only through explicit freshness-checked grants.

Agent-facing: `file open <path>`, `file diff <path> [--staged]`,
`file open-changed [--mode edit|diff|both]` (default diff).

## 6. UI shell (information architecture)

- Top-level views: `terminal | settings | tasks | activity | automations | space | skills |
  artifacts | mobile`.
- **Left sidebar**: header/toolbar, nav, filters (project/repo/workspace/host-scope),
  group-by toggle, then the **worktree card list**. Card = status slot + meta badges +
  inline live agent rows (with spawn lineage) + ports + detail sections (issue/review/
  automation/cli) + context menu. Grouping: project groups → repos → worktrees; ordering
  manual | recent.
- **Center**: workbench → tab groups with split layouts; tabs render terminal pane, editor,
  diff, conflict-review, check-details, browser pane. Per-tab `viewMode: terminal|chat`
  (native chat overlay on the live agent PTY).
- **Right sidebar**: `explorer (files|search) · search · vault (cross-session agent
  transcript browser) · workspaces · pr-checks · source-control · checks · ports`.
- **Agent Dashboard** (in-window | popout): kanban buckets `attention | working | done |
  idle`; card = `{paneKey, agentType, bucket, dotState, task, lastUserMessage,
  lastAgentMessage, click-to-focus routing ids, parentPaneKey, workspaceStatus, subagents[],
  startedAt/finishedAt, unseen, askSummary}`. A done card stays highlighted until
  acknowledged. Bounded fleet sizes so a huge fleet can't blank the popout.
- Other: jump palette (cmd-j: worktrees, files, agents, commands), task boards, floating
  terminal, status-bar items.

## 7. Other command groups (for completeness)

`open | serve | status`, `repo list|add|show|set-base-ref`, `project …`,
`worktree list|show|current|create|set|rm|ps`, `file …`, `automations …` (scheduled
prompts: cron/RRULE triggers, per-run new worktree or reused workspace, bounded
`--precheck`), `artifacts share|update|unshare|list|delete` (sharing gated by default-off
human-only capability, no CLI/RPC grant path), `skills …`, `computer …`, `agent-context`.

## 8. Rebuild checklist (must not miss)

1. Two identities per pane: remintable `handle`, durable `paneKey`. Authority keys on
   paneKey + process_incarnation.
2. Dispatch is the unit of lifecycle authority; `worker_done` carries `(taskId,dispatchId)`;
   settlement rejects `unknown_task | unknown_dispatch | task_dispatch_mismatch |
   inactive_dispatch | stale_dispatch`.
3. Exactly-one-outstanding FIFO delivery per Run, replayed verbatim until ack, cap 50,
   consumer-generation fence.
4. `--retry-request` idempotency on every mutation (receipts keyed on caller+request id).
5. Turn completion is hook-first, title-second, prompt-text-third, process-fourth — never
   inferred from silence. `permission` ≠ `idle`. Never clear lastAgentStatus on wait.
6. Prompt injection: ESC-sanitize → bracketed paste → chunk → render gate → delayed `\r` →
   verify working-sequence advanced.
7. Worker death auto-escalates; deliberate close does not.
8. 3 failures = circuit break. Stale heartbeat warns only.
9. Gates never auto-resolve; pending gate force-re-blocks its task.
10. worker-release archives before closing; refuses unproven/user-owned terminals.
11. Worktree name retirement is permanent (agent state keyed to old paths).
12. Folder workspaces are first-class; never assume git worktree.
13. `--no-parent` (lineage) ⊥ `--base-branch` (git base).
14. ExecutionHostId on everything; loss of contact = `unverifiable`, never `exited`.
15. Agent docs ship inside the binary (version-matched), stubs on disk.
16. `terminal read` stream vs screen must both exist with a `source` field.
17. Three-state optionals for observations (absent ≠ null).
18. Publishing capability gates are human-only.
19. Dispatched workers must never open local interactive prompts; blocking questions go
    through `ask`.
20. userData path captured once at boot; hot caches in droppable sidecars.
