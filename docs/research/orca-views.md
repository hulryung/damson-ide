# Orca top-level views: `activity`, `tasks`, `space`

Inventory §6 (`docs/research/orca-inventory.md`) names three top-level views
Orchard never specified and never built: `tasks`, `activity`, `space`. This
note is what those views actually *are* in `~/dev/orca` (read-only), what they
are for that Orchard's workbench, orchestration view, and agent dashboard do
not already cover, and which one this task implements.

Orca mounts them as mutually exclusive pages in
`src/renderer/src/app-shell/AppWorkspaceShell.tsx`:

```
activeView === 'tasks'      → TaskPage
activeView === 'activity'   → ActivityPrototypePage
activeView === 'space'      → WorkspaceSpacePage
```

alongside `terminal` (the workbench), `settings`, `automations`, `skills`,
`artifacts`, and `mobile`. They are not workbench tabs and not right-sidebar
sections. Switching to one replaces the center column.

## 1. `activity` — cross-workspace agent inbox

**Source.** `src/renderer/src/components/activity/ActivityPrototypePage.tsx`
and its siblings under `components/activity/`. The file name is not a leftover:
the surface is still a prototype, gated by `settings.experimentalActivity`,
which Orca **defaults off for every user**
(`src/main/persistence-settings-ui-defaults.test.ts`). A persisted
`activeView: 'activity'` is dropped on hydrate unless the flag is on
(`src/renderer/src/store/slices/ui-hydration-view-layout.test.ts`).

**What it is.** A two-pane inbox of *agent panes*, not workspaces. One row per
`paneKey` (`<tabId>:<leafId>`). Each thread is the live agent snapshot (if
any) plus a history of `done | blocked | waiting` events drawn from
`agentStatusByPaneKey`, retained agents, and migration-unsupported PTYs.

**Data.**

| Field | Meaning |
|---|---|
| `paneKey`, `paneTitle`, `agentType` | Durable pane identity and generated title |
| `currentAgentState` | Live `working \| blocked \| waiting`, else nil |
| `events[]` | Historical `done/blocked/waiting` with timestamp, unread, last assistant / prompt |
| `responsePreview` | Bounded (320 chars) status text for the list |
| `worktree`, `repo`, `tab` | Click-to-focus routing |
| `unread` | Derived from acknowledgement, not a second unread store |

**Actions.** Search; filter All / Unread; group by status / project / worktree /
agent; compact mode; mark all read; select a thread. Selecting a thread
**portals the live xterm** from the workbench into the activity detail pane
(`activity-terminal-portal.ts`) so the user can watch or type without leaving
the inbox. Click-through also activates the worktree and focuses the pane.

**What it is for.** After you walk away from a fleet: “what happened, what is
unread, show me that PTY.” The dashboard is a *current-state kanban*
(`attention \| working \| done \| idle`). Activity is a *chronological inbox
with history and a live terminal portal*.

**Overlap with Orchard.** Orchard already has:

- Agent Dashboard (`AgentDashboardView` + `DashboardProjection`) with the same
  live states, unseen highlighting, last user/agent lines, and click-to-focus.
- Sidebar cards with inline live-agent rows and the same unread reducer.
- Vault for *ended* dispatch leftovers (transcripts / tails), which is a
  different noun (archives, not live panes).

What activity uniquely adds is (1) per-pane event history and (2) the xterm
DOM portal. (1) is a list-shaped restatement of the dashboard. (2) is an
Electron trick: the activity page does not own a PTY; it reparents the
workbench's xterm node. There is no honest AppKit equivalent without moving
Damson surfaces between windows, which would fight the workbench's ownership
of sessions.

**Left unbuilt.** Redundant with the agent dashboard for current state and
unread; the distinctive piece is an Electron portal we should not clone; Orca
itself still ships it behind an experimental flag defaulted off.

## 2. `tasks` — hosted issue tracker, not orchestration tasks

**Source.** `src/renderer/src/components/TaskPage.tsx` (~4k lines) plus
`task-page-*.ts(x)` helpers for GitHub, GitLab, Linear, and Jira.

**What it is.** A project-management page over *external* work items. The
noun “task” here is a GitHub issue/PR, a GitLab issue/MR, a Linear issue, or
a Jira issue. It is not an Orchard/Orca orchestration `Task` (the DAG item
under a Run). The empty-state copy is explicit: “Select at least one project
source so Orca knows which host/account to fetch tasks from.”

**Data.** Provider connection status (Linear workspace, Jira site, `gh` /
`glab` preflight); a multi-repo picker; cached work-item lists (title, state,
assignees, labels, checks pill, URL); Linear custom views / projects / teams;
Jira presets and sort; GitHub issue vs PR mode.

**Actions.** Switch provider and mode; search; open an item in a drawer /
hosted page; create GitHub/Linear/Jira drafts; patch Linear fields; jump to
the linked worktree. None of this writes the orchestration store.

**What it is for.** “What is on the team's GitHub/Linear/Jira board, and which
repo should I open a worktree for?” A human intake surface for *tickets*,
sitting above worktree creation.

**Overlap with Orchard.**

- Orchestration view already lists Runs → Tasks → Dispatches and offers the
  guarded mutations (`release` / `retain` / `stop` / `gate-resolve`). That is
  the in-app “tasks” noun.
- Worktree meta already stores `linkedIssue` / `linkedPR` as strings.
- T88 (not this task) owns GitHub Checks on the card and in the sidebar.

Building Orca's Task page would mean standing up GitHub/GitLab/Linear/Jira
clients, auth, caches, and mutation registries — a product of its own, and
one this app has no credentials or design for.

**Left unbuilt.** Not orchestration tasks (already covered). An external issue
tracker we do not have. Do not build it on speculation.

## 3. `space` — workspace disk usage and reclaim

**Source.** `src/renderer/src/components/workspace-space/WorkspaceSpacePage.tsx`
(a thin chrome page) hosting
`src/renderer/src/components/status-bar/WorkspaceSpaceManagerPanel.tsx`. Types
in `src/shared/workspace-space-types.ts`; scan in
`src/main/workspace-space-analysis.ts`. Marked **Beta** in the page header.
Copy: “Workspace disk usage and reclaimable worktree storage.”

**What it is.** A resource-manager over every known worktree: how much disk
each checkout occupies, how much of that is *reclaimable* (extra worktrees;
the primary checkout is never reclaimable), and a way to delete extras.

**Data** (per worktree row):

| Field | Meaning |
|---|---|
| `worktreeId`, `repoId`, `path`, `displayName`, `branch` | Identity |
| `isMainWorktree` | Primary checkout — size counts, reclaimable = 0, cannot delete |
| `isRemote` | Typed `unavailable`; not walked from this machine |
| `status` | `ok \| missing \| permission-denied \| unavailable \| error` |
| `sizeBytes`, `reclaimableBytes` | Reclaimable = size when not main and scan is ok |
| `topLevelItems[]` | Immediate children, compacted to 48 (rest folded into “Other”) |
| `skippedEntryCount` | Partial walk, not a blank panel |
| `lastActivityAt`, `scannedAt` | Sort / freshness |

Repo summaries roll those up. Progress is `scannedWorktreeCount / total`.

**Actions.** Refresh scan; search (capped); sort by size / name / repo /
activity; filter to deletable extras; inspect a row's top-level breakdown;
open the workspace; delete extra worktrees (Orca also batches, with a
readiness check for live agents / dirty editors / git changes). Escape closes
the page when no overlay is open.

**What it is for.** A multi-worktree orchestrator accumulates checkouts. The
workbench shows one workspace. The sidebar shows cards, not bytes. The
dashboard shows agents. Orchestration shows runs. Nothing else answers “what
is eating disk, and which extra worktree can I delete?” Dogfood already
records leftover worktrees after cycles; this is that surface.

**Overlap with Orchard.** Delete-worktree (sidebar + `DeleteWorktreeSheet`)
already exists, but you have to know which card to open and you never see
size. Vault prune is about *archives*, not checkouts. No current view
measures disk.

**Implemented (T90).** This is the one view with unique value that we can
build without cloning an Electron portal, without standing up issue-tracker
integrations, and without touching Checks / Hosts / Git* / Automations.

Deliberate cuts versus Orca's panel:

- No treemap. A table with size bars is the native equivalent; the treemap is
  decoration on the same numbers.
- No git-status column and no “changed file count” readiness. T90 must not
  touch `Git*`. Delete reuses the existing sheet, which already preflights.
- No SSH directory walk. Remote rows are typed `unavailable`. T89 owns Hosts.
- Scan the workspaces the app already has in memory (sidebar projects +
  extra worktrees). Do not call `listWorkspaces()` from this window: that
  path is a git porcelain read, and a Space refresh must not hitch a
  workspace switch.

## Decision

| View | Unique vs workbench / orchestration / dashboard | Build? |
|---|---|---|
| **Space** | Disk usage + reclaim of extra worktrees. Nothing else shows this. | **Yes** |
| Activity | Inbox + history + xterm portal. Current state and unread already live on the dashboard. Portal is Electron-specific. Still experimental-off upstream. | No — redundant with the dashboard; portal is not portable |
| Tasks | GitHub/Linear/Jira/GitLab issue board. Orchestration view already covers in-app tasks. | No — different noun; huge integration; T88 owns GitHub checks |

## Orchard mapping (what shipped)

- Research: this file.
- Runtime projection + scanner: `Sources/OrchardRuntime/Workspaces/WorkspaceSpaceProjection.swift`,
  `WorkspaceSpaceScanner.swift`. UI-free; no git; no host transport.
- App: `Sources/OrchardApp/Space/**`, Go menu, ⌘J, sidebar, window-frame
  autosave role `space`.
- Tests: `Tests/OrchardRuntimeTests/WorkspaceSpaceProjectionTests.swift`,
  plus the autosave / palette table updates.
- Report: `docs/reports/t90-views.md`.
