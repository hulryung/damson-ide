# T84 — Open a remote agent pane from the app (2026-08-26)

Wave 23. Owns `Sources/OrchardApp/ComposerView.swift`, `SidebarView.swift`
card affordances, AppStore wiring, matching tests, and this report. Does
not touch OrchardTerminals, Files/**, or WorkerVerbs.

`terminal create --worktree <remote> --engine <agent>` has worked since
T39. The GUI still stopped at the host boundary: the composer threw
`remote_unsupported`, the card start/restart row was **hidden** on a
remote project, and the context-menu start used `try?` so a failure
vanished. Those doors now use the same runtime verb the CLI uses.

## What changed

**Start / restart on an existing remote worktree.** `AppStore.startAgent`
calls `RemoteAgentStart.createPane` → in-process `terminal-create` with
`--worktree` + `--engine` (no second `--host`; the worktree stamp chooses
the machine). The returned PTY is bound to a terminal tab whose
`executionHostId` is the summary's, so the host chip is a stamp, not a
guess. The card lists the pane from `TerminalService.list` rather than
adopting it into the local `AgentSupervisor` — that path would write
hook config into a local directory that happens to share the remote
path (the T32 hazard, and on `orchard-loopback` the path *is* local).

**Composer on a remote repo.** ⌘N / New is enabled when the remote repo
is in the registry. Create runs `WorkspaceService.create` (`worktree-create`,
`agent` unset — that spawn still refuses remote) then the same
`terminal-create` verb for each planned name. The engine picker stays
the live registry. Base-ref seeding uses the registry default / `HEAD`
because a remote project has no local `for-each-ref`.

**Failures stay typed and inline.** `RemoteAgentStart.describe` renders
`code: message` (`unknown_engine`, `host_unverifiable`, …). The composer
sheet and the card row both show it. The context menu no longer uses
`try?`.

**Affordances that still cannot work remotely stay visible and disabled
with a reason:** Reveal in Finder, Show Diff, Delete Worktree, the
file/editor/browser tabs. They are not hidden.

## Ownership note (OrchardRuntime/Hosts)

The spec named ComposerView, SidebarView, AppStore, tests, and this
report. Two UI-free types had to move with that wiring or the app would
have invented a second policy:

- `Sources/OrchardRuntime/Hosts/RemoteWorkspacePolicy.swift` — `.agents`
  and `.composer` are available on a remote host (they were the gate that
  hid the controls). File/diff/editor/browser stay refused.
- `Sources/OrchardRuntime/Hosts/RemoteAgentStart.swift` — the
  `terminal-create` param shape and `code: message` renderer, so tests
  can pin the verb without importing OrchardApp.

Neither file is WorkerVerbs, Files, or OrchardTerminals.

## Tests

`Tests/OrchardRuntimeTests/RemoteWorkspacePolicyTests.swift` — agents and
composer are available on `ssh:*`; file/diff/editor/browser stay
`remote_unsupported` / local-only.

`Tests/OrchardRuntimeTests/RemoteAgentStartTests.swift` — the
`terminal-create` param shape (`worktree` + `engine`, no extra `host`),
success/failure envelope decoding, and `code: message` wording that
never says "deleted".

`swift build && swift test`: **1251 tests, 2 skipped, 0 failures**.

## Live verification (read-only computer-use)

Coordinator rebuilt **this branch** (`v23-remote-agent-ui`) and
relaunched. Runtime in the window chrome:
`rt_aadd4b08-38f8-4df4-824b-bed8f17cad0a`. Host check:
`orchard-loopback` reachable (127.0.0.1:2222).

Registered a throwaway remote repo
`/tmp/t84-remote-scratch` as `t84-remote` (`--host ssh:orchard-loopback`),
created worktree `t84-agent-ui`, then `repo remove --forget` and removed
the leftover host directory. Nothing else in the registry was touched.

Computer-use captures (read-only, `--restore-window` once to front the
window; no clicks, no keys):

| Capture | Build | What it showed |
|---|---|---|
| `3b67ca61-7239-4ee3-86dc-353d9e6395bd` | branch relaunch `rt_aadd4b08-…` | Sidebar lists `t84-remote` with **orchard-loopback** host chips (AX: three `orchard-loopback` texts on the repo, two on the card). Card shows **Start agent** (play glyph + chevron). AX: unlabeled button + `Go Down` menu next to `main`. |
| `c7419fa2-cc31-4c36-b54b-ccfcd33345e6` | same process | Same card still showing Start agent after a CLI `terminal create --engine claude` (the sidebar does not subscribe to an external create; a GUI start calls `objectWillChange`). |

CLI `terminal create --worktree <t84-agent-ui> --engine claude` against
that same runtime returned `ok`, `engine: claude-code`,
`executionHostId: ssh:orchard-loopback`, `statusDetection.mode: hooks`,
`tunnelPort: 47111`. The pane was closed before forget.

Host-chip crowding: on the repo header, `orchard-loopback` and the
liveness line (`reachable - Ns ago`) overlap in the narrow sidebar.
That is the existing compact `HostChip` + liveness pair, not a new
control. The card row itself is readable: chip then `reachable`.

| Check | Result |
|---|---|
| Host chip on sidebar card / repo | **Yes** — `orchard-loopback` in AX and pixels |
| Start agent visible on a remote card (not hidden) | **Yes** |
| Composer engine picker reachable for a remote repo | Enabled in code (`canCreateWorktree`); sheet not opened (see below) |
| Disabled Finder / Diff / Delete still show a reason | Code: `.disabled` + `.help` reason; context menu not opened |
| Typed inline failure (`code: message`) | Unit-tested; live click not driven |
| Same verb as CLI | Live `terminal-create --engine claude` on the scratch worktree succeeded |

## What synthetic input cannot verify

- `orca computer press-key` does not reach SwiftUI key handling (⌘N,
  composer Return). System Events key codes do; this pass did not send
  them. The composer sheet was therefore **not** opened.
- Taps on SwiftUI gesture handlers (card `onTapGesture`, some menu
  rows) do not fire. The remote card was **not** selected, so the
  workbench stayed on `cc-rate-widget` and the agent pane's tab chip
  was not photographed. Start/Restart was **not** clicked.
- A prompt typed into the composer is saved as `lastPrompt` but is
  **not** injected into a remote agent TUI — `RemotePaneLauncher`
  keeps that prompt empty so an `ssh` command line is not typed into
  Claude. Same as the CLI verb.

## What is left

- `worktree-create --agent` (WorkspaceService.spawnAgent) still answers
  `remote_unsupported`. The app does not use that door; it creates the
  worktree, then `terminal-create --engine`.
- Supervised `worker-start` on a remote host is T83, not this task.
- File / diff / editor / browser remain local-only (T85 owns files).
- Host-chip + liveness overlap on a narrow repo header is pre-existing
  crowding; not fixed here.
