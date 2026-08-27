# T90 — What `activity`, `tasks` and `space` actually are

Inventory §6 named three Orca top-level views Orchard had never specified.
`~/dev/orca` is on this machine (read-only). The research note is
`docs/research/orca-views.md`. This report is what shipped.

## What each view is

| View | In Orca | Unique vs workbench / orchestration / dashboard |
|---|---|---|
| **activity** | Cross-workspace agent inbox: one thread per pane, event history, unread, live xterm portal. Still a prototype (`ActivityPrototypePage`), gated by `experimentalActivity`, **defaulted off**. | Current state and unread already live on the Agent Dashboard. The portal is an Electron DOM reparent of the workbench xterm — not an AppKit thing we should clone. |
| **tasks** | GitHub / GitLab / Linear / Jira issue board (`TaskPage`). The noun is a hosted ticket, not an orchestration Task. | Orchestration view already lists Runs → Tasks → Dispatches. T88 owns GitHub checks. Building this is an issue-tracker product. |
| **space** | Workspace disk usage and reclaimable extra-worktree storage (`WorkspaceSpacePage` / `WorkspaceSpaceManagerPanel`). Typed scan statuses, primary checkout is never reclaimable, remote is `unavailable`. | Nothing else in Orchard shows bytes. Delete already exists, but you have to know which card and you never see size. |

## What we built

**Space.** Highest unique value that does not require speculation.

- `Sources/OrchardRuntime/Workspaces/WorkspaceSpaceProjection.swift` — UI-free
  rows, reclaimable math, sort/filter/group, byte labels, top-level compaction
  (48, rest folded into Other). No git, no host transport.
- `Sources/OrchardRuntime/Workspaces/WorkspaceSpaceScanner.swift` — local
  FileManager walk, off the main actor. Does not follow symlinks. Hidden
  entries (`.git`) count. Missing / no-access / error are typed, never a
  blank panel. Remote subjects are marked unavailable *before* any walk.
- `Sources/OrchardApp/Space/SpaceView.swift` + `SpaceBrowser.swift` —
  auxiliary window (Go → Space, sidebar disk icon, ⌘J “disk” / “reclaim”).
  Scan subjects come from the in-memory sidebar so a refresh cannot hitch a
  workspace switch. Delete reuses `DeleteWorktreeSheet`. Open focuses the
  workbench via `focusWorkspaceIdentity`.
- Window-frame role `space` (`OrchardSpaceWindow`, 1040×620). Palette Go-menu
  surface is now 10 commands.

Deliberate cuts versus Orca: no treemap (the table and size bars are the same
numbers), no git-status column (T90 must not touch `Git*`), no SSH walk (T89
owns Hosts; remote rows stay `unavailable`).

## Why the other two were left

- **activity** — redundant with the Agent Dashboard for live state, unseen, and
  click-to-focus. The distinctive piece is an xterm portal we cannot honestly
  port. Orca still hides the page behind an experimental flag defaulted off.
- **tasks** — a hosted issue tracker, not orchestration tasks. Orchestration
  view already covers the in-app noun. Do not stand up Linear/Jira/GitHub
  boards on speculation.

## Tests

`Tests/OrchardRuntimeTests/WorkspaceSpaceProjectionTests.swift` — reclaimable
vs main, remote unavailable without walking, typed unscanned/missing,
sort/filter/group, oversized query, byte labels, compaction, scanner: missing
path, `.git` counts, symlink not followed.

Palette and window-frame tables updated for the new Go item and autosave role.

`swift build` and `swift test` are green: 1344 tests, 4 skipped, 0 failures.
The Orchard app was not launched or quit from this task — coordinator should
rebuild+relaunch to pick up the Space window.
