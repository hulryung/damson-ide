# Orchard visual pass — wave 19/20 (T74)

Date: 2026-08-25 (Asia/Seoul), 21:28–21:36 KST
CLI: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` (SHA-256 `000ddaec30651ebd3b08abd297d5f917c38d11319be3cb4eaa8aa4c4d3c22fc2`, 9,660,760 bytes, mtime 2026-08-25 20:32 +0900 — byte-identical to the dogfood-6 CLI)
Runtime: live Orchard app, `rt_5867877d-1c9d-4e1e-a3fc-7696b098ae33`, PID 4491, started 2026-08-25 20:33:26 KST — the same runtime id and PID as dogfood-6; the app was never launched, quit, or relaunched
App binary: `Orchard.app/Contents/MacOS/Orchard`, mtime 2026-08-25 20:32 — carries the T68 strings (`still contains conflict markers`, `Theirs (replayed commit)`, `all conflicts resolved`, `Runtime alive`) and does **not** carry T70/T71 strings (`Source Control`, `Float Terminal`, `No staged changes`, `No unstaged changes`, `empty_staged_set`, `empty_commit_message`, `Reveal Floating Window`, `Live agents by dashboard`, `Unstage All`)
Source at HEAD of this worktree: `9f0932d` (wave 19 close + wave 20 plan). T70 (`48bb018` / merge `9b40cec`) and T71 (`0062a31` / merge `2e19c58`) are in this checkout. They are **not** in the running binary.
Computer-use: `orca computer` provider `orca-computer-use-macos` 1.0.0. Observation: screenshot + element frames. Actions advertised: click/type/press-key/hotkey/set-value. Surfaces: `menus: false`, `menubar: false`, `dialogs: false`, `dock: false`. One Orchard window: id `17697`, 1048×812 at (872, 30), title "Orchard". No second (floating) window.

Result: the running app is still the T68-era build from 20:32. A read-only AX tree + screenshot of window `17697` therefore cannot confirm the three wave-19 GUI surfaces T74 asked about — they are not in the process that is on screen. `orchard agent-context --json` (59,654 bytes, 40 verbs) matches this worktree's `CommandSpec` table: no summary drift, no `allowedValues` drift. `worker-read` still has no `hasOlder` field. There is still no `conflicts` verb (T73 has not landed here).

Computer-use was screenshots + AX trees only. No clicks, no keys, no workspace-selection change, no file mutation, no input into any terminal.

## What the running window actually shows

AX snapshot `4C1AB3DF-E09A-4C4E-BE77-BDF2E3A7AEAD` (92 elements, untruncated) plus the matching screenshot:

- **Left sidebar.** "Workspaces". Three cards: `damson-ide` / `main`, `CAN-debugger-hw` / `main`, `cc-rate-widget` / `main` (selected). Each repo header shows a trailing `0`. That digit is `RepoHeader`'s `project.records.count` (SidebarView.swift:273) — worktree cardinality, **not** T71 agent-bucket counts.
- **Center workbench.** Header `cc-rate-widget` + `main`. Tabs: Terminal (selected), Diff. Prompt visible: `cc-rate-widget on  main`. Add-tab control is a `menu button Add`. No Conflicts tab.
- **Right sidebar.** T9 Files explorer only: header text "Files", two icon buttons (eye / reload), Filter field, then the `cc-rate-widget` tree (`Assets.xcassets` … `vercel.json`). No Files / Source Control picker. No "Source Control", "Staged", "Changes", "Commit", "Stage", or "Unstage" nodes.
- **Status bar.** Screenshot shows a thin bottom strip with **only** `0 ports` on the right. The AX tree does not expose the status-bar chips at all (it ends at the toolbar / traffic-light buttons). Pre-T71 `StatusBarView` is a `Spacer` plus `PortsStatusChip` — that is what is on screen. No `name · branch` chip, no `⚠/⟳/✓/●` bucket summary, no `Runtime alive · rt_…` chip.
- **Windows.** `list-windows` returned exactly one window. No always-on-top floating terminal.

`orchard worktree list` agrees: 3 primary worktrees, all on `main`. None of `/Users/dkkang/dev/{damson-ide,CAN-debugger-hw,cc-rate-widget}` has `MERGE_HEAD` or `rebase-merge`. `syncConflictTab` only inserts a Conflicts tab when `summary.isActive`; with no in-progress merge/rebase the tab is correctly absent. Inducing one would mean writing a conflict into a user checkout — out of scope.

## T70 — source-control section

**Not present in the running app.** The binary has no T70 strings. The AX tree and screenshot show the T9 Files header, not `RightSidebar`'s Files / Source Control picker.

This worktree's source *would* render, once rebuilt:

- Picker: Files | Source Control (`RightSidebar.swift`).
- Header "Source Control", branch menu, Staged / Changes sections (`"No staged changes"` / `"No unstaged changes"`), Commit field, Push/Pull only when `hasRemote`.
- Typed refusals as an orange `errorText` line: `empty_commit_message — Commit message is empty.`, `empty_staged_set — Nothing is staged to commit.`, plus `no_remote`, `not_a_repository`, `invalid_branch_name`, `branch_exists`, `branch_not_found`, `git_failed`.

**Unverified on screen:** staged vs unstaged lists, the empty-state copy, the orange error bar, stage/unstage, commit refusals, branch switch/create, push/pull visibility. Those need a binary that contains T70. Even then, the error surfaces only appear after a Commit / stage / branch action — a click that this pass was not allowed to send, and that would have been a mutation if it had succeeded.

## T71 — status bar + floating terminal

**Not present in the running app.**

T71 `StatusBarView` (this checkout) is workspace chip + agent-bucket chip + spacer + runtime chip + ports chip. `StatusBarProjection` copy that should appear after a rebuild:

| Chip | Projection |
|---|---|
| Workspace / branch | `cc-rate-widget · main` (selected worktree) |
| Agent buckets | `⚠0  ⟳0  ✓0  ●0` when the four dashboard buckets are empty (glyphs stay; zeros stay) |
| Runtime | `Runtime alive · rt_5867877d-1c9d-4e1e-a3fc-7696b098ae33` (T51 `menuTitle`; the string **is** in the running binary for the app menu, but the status-bar chip is T71 and is not drawn) |
| Ports | `0 ports` — this chip **is** on screen (T20) |

What *is* visible today and must not be mistaken for T71: workbench header `cc-rate-widget` / `main`; sidebar card `main` labels; sidebar `0` = worktree count, not agent buckets.

**Floating-terminal menu affordance.** In this checkout it is a tab-chip `contextMenu` item `"Float Terminal"` (`WorkbenchView.swift:223`), disabled when `existingDamsonSession` is nil. There is no always-visible button. The running binary has no `"Float Terminal"` / `"Reveal Floating Window"` / `"No live session"` string. `orca computer` reports `surfaces.menus: false`, so a context menu cannot be opened through the AX provider even if the item existed. Reading-only, so the Terminal tab was not right-clicked. One window only — the floating window is not open.

The T71 workbench placeholder (`"Floating"` / `"Reveal Floating Window"`) was not on screen; the Terminal pane still holds the PTY.

## T68 — conflict-review pane (still GUI-unverified)

The running binary **does** contain T68. The Conflicts tab is not on screen because no registered worktree is mid-merge. T74 forbade creating one. The GUI shell dogfood-6 listed as unverified is still unverified: auto-open / retract / badge, Hunks vs Whole-files picker, three-column stages, per-hunk pickers, orange error bar, busy/stale guards, Take ours/theirs. T73's CLI verbs are not in this worktree or in the running CLI (`orchard conflicts` → unknown command).

## What synthetic input cannot verify

Recorded without sending any of it. These are provider / AppKit facts, not guesses from this session's clicks.

1. **`orca computer press-key` does not reach `KeyCaptureView`.** `JumpPalette.KeyCaptureView` installs `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` and handles key codes 126 / 125 / 53 (up / down / escape). Computer-use `press-key` / `hotkey` inject CGEvents that this local monitor does not see. Wave-17 already hit this: `press-key Escape` left the palette up and a later Cmd-Q returned `-128`. **System Events key codes do** (`osascript` `key code 53` for Escape). This pass did not open the palette and did not send either kind of key.
2. **Menus, menubar, and dialogs are not a computer-use surface** (`capabilities.supports.surfaces.menus/menubar/dialogs` are all false). The Float Terminal item lives on a SwiftUI `contextMenu`. It cannot be listed or invoked through the AX tree this provider exposes.
3. **Status-bar chips are not in the AX tree.** The ports chip is visible in pixels and absent from `treeText`. A T71 rebuild would likely have the same hole: screenshot can confirm the chips; AX cannot.
4. **Source-control error surfaces need a click** (Commit with an empty message or empty index, bad branch name, …). Computer-use could click those buttons; this pass was read-only, and the T70 UI is not in the running process anyway. A successful click would also be a git mutation.
5. **`type-text` / `press-key` into a Damson pane is not a UI read** — it is input into the user's terminal, which this task forbade. Key routing into `TerminalFitHost` was not probed.
6. **Conflict-review chrome needs an active merge** in a worktree the app already has selected. Creating one is a file/history mutation.

## Agent-context vs CommandSpec

Compared three faces of the same table:

- Running `orchard agent-context --json`: `schemaVersion` 1, **40** commands, 59,654 bytes (same size dogfood-6 reported).
- This worktree's `Sources/OrchardProtocol/CommandSpec.swift` (`OrchardCommands.all`). `git diff c68ceff HEAD -- Sources/OrchardProtocol/CommandSpec.swift` is empty — wave 19 did not touch the table. Last edit: `97a5495` (T66), which the running CLI already carries.
- Running `orchard <verb> --help` for every verb (rendered by `CommandHelpRenderer` from that same `CommandSpec`).

### Verb list

Identical, in the same order: `status`, `serve`, `agent-context`, `guide`, `version`, `run-create`, `run-use`, `run-current`, `run-list`, `run-show`, `send`, `check`, `reply`, `ask`, `inbox`, `task-create`, `task-list`, `task-update`, `dispatch`, `dispatch-show`, `gate-create`, `gate-resolve`, `gate-list`, `worker-start`, `worker-show`, `worker-read`, `worker-stop`, `worker-abandon`, `worker-release`, `worker-retain`, `worker-list`, `repo`, `worktree`, `workspace-ports`, `file`, `terminal`, `browser`, `automations`, `host`, `reset`.

No `conflicts` verb. `orchard conflicts --help` → `unknown or missing command`. T73 owns that addition and has not merged here.

Every `command("name", "summary")` / `CommandSpec(name: "guide", …)` summary matches the JSON `summary` and the first line of `--help`. No help-text drift.

### `allowedValues` — no table drift

The only closed flags in the table, and the JSON values:

| Verb | Flag | `allowedValues` in JSON = `CommandSpec` |
|---|---|---|
| `worker-start` | `--agent` | `claude-code`, `codex`, `cursor-agent`, `grok`, `shell`, `claude`, `cursor` (`OrchardAgentEngines.acceptedIdentifiers`) |
| `worker-read` | `--source` | `auto`, `transcript`, `terminal` |
| `terminal` | `--engine` | same engine list as `--agent` |

`--help` does **not** print those lists. `CommandHelpRenderer.flagLabel` emits `--name <valueHint>` only; `allowedValues` is ignored. So `worker-start --help` says `--agent <agent>` and `terminal --help` says `--engine <engine>` (plus "(default shell)" in the summary). That is a renderer gap, not a mismatch between `agent-context` and `CommandSpec`. An agent that reads `--help` instead of `--json` still cannot see the accepted engine spellings — the same class of miss dogfood-1 spent a failed `worker-start` on.

Aliases are declared and rendered, not drifted: `dispatch-show --id` help says `alias: --dispatch`; `worktree --status` help says `alias: --workspace-status`. `repo --help` notes "There is no `--force`" (the word `force` appears in the note, not as a flag).

### `worker-read` / `hasOlder` (dogfood-6 finding 12)

Unchanged. JSON + `--help`:

- `--limit` summary: `Maximum lines to return (default 200)`
- Notes: "Without `--limit`, worker-read returns the newest 200 lines." / "Use `--limit` and `--cursor` to page older output. `truncated` describes the requested window, not whether older lines exist."
- No `hasOlder` key in `agent-context`, in `CommandSpec`, or in the `worker-read` result object (`WorkerVerbs.swift` still emits `truncated`, `oldestCursor`, `latestCursor`, `returnedLineCount`, `nextCursor`). Older lines are still discoverable only by comparing `oldestCursor` with `latestCursor − returnedLineCount`.

## Findings

| # | Finding | Evidence | Status |
|---|---|---|---|
| 1 | **The running Orchard.app is the 20:32 T68 build.** T70/T71 source is in this worktree (`9f0932d`) but not in PID 4491. A visual pass of the live window cannot confirm source-control, T71 status-bar chips, or the Float Terminal menu. Confirming those needs a rebuild/relaunch the task forbade. | Binary strings; AX + screenshot of window 17697; git log | Blocker for the GUI half of T74 — honest, not a product defect |
| 2 | **Right sidebar is still T9 Files.** No Source Control picker, no Staged/Changes, no orange `errorText`. | AX nodes 49–85; screenshot | T70 unverified on the running app |
| 3 | **Status bar is still T20 ports-only.** Screenshot: `0 ports` on the right. No `cc-rate-widget · main`, no bucket glyphs, no runtime chip. Sidebar `0` is worktree count (`RepoHeader`), not agent buckets. Workspace/branch *do* appear on the workbench header and sidebar cards — those are not the T71 chips. | Screenshot; pre-T71 `StatusBarView`; SidebarView.swift:273 | T71 status bar unverified on the running app |
| 4 | **No floating-terminal affordance in the running process.** One window. `"Float Terminal"` absent from the binary. The T71 item is a tab `contextMenu`; computer-use cannot open menus. | `list-windows`; strings; `capabilities.surfaces.menus=false` | T71 menu unverified on the running app |
| 5 | **T68 conflict-review GUI is still unverified.** Binary has the code; no registered worktree is mid-merge, so no Conflicts tab. Creating a conflict was out of scope. | `worktree list`; MERGE_HEAD absent on all three checkouts; dogfood-6 finding 3 | Same gap as dogfood-6; T73 would make it CLI-reachable |
| 6 | **`agent-context --json` matches `CommandSpec`.** 40 verbs, identical summaries, identical `allowedValues`. Wave 19 did not edit the table. | `git diff c68ceff HEAD -- CommandSpec.swift` empty; per-verb `--help` first lines | No drift |
| 7 | **`--help` still hides `allowedValues`.** `CommandHelpRenderer` never prints the closed lists. `worker-start --agent` / `terminal --engine` JSON has the seven engine ids; human help does not. | `CLIFormatting.swift:47-49`; `worker-start --help`; `terminal --help` | Presentation gap, not table drift |
| 8 | **No `conflicts` verb** in the running CLI or in this worktree's `CommandSpec`. | `orchard conflicts` → unknown command; JSON has zero "conflict" | Expected until T73 merges |
| 9 | **`worker-read` still has no `hasOlder`.** Help and notes document the 200-line window; the receipt still uses `truncated` / cursors. | `worker-read --help`; `WorkerVerbs.swift` live + archive objects | dogfood-6 finding 12, still open |
| 10 | **`orca computer press-key` does not reach `KeyCaptureView`; System Events key codes do.** Menus/menubar/dialogs are not computer-use surfaces. Status-bar chips are pixels-only. | `JumpPalette.swift:300-337`; REBUILD-PLAN T65 note; capabilities JSON | Tooling limit — do not treat a failed `press-key` as an app bug |

## Cleanliness

Same runtime id and PID (`rt_5867877d-…`, 4491) before and after. Computer-use: one `list-windows` and one `get-app-state` (screenshot + AX). No clicks, no keys, no `terminal send`, no workspace-selection change, no file writes except this report. `orchard` calls were `status`, `agent-context --json`, `--help` / `<verb> --help`, `worktree list --json`, and a `conflicts` probe that the CLI rejected. Registered repos, worktrees, and the foreign terminal were not touched.
