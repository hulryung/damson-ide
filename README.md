# Orchard

**A native macOS cockpit for running CLI coding agents side by side — each in its own git worktree.**

Orchard drives multiple agents (Claude Code today; more engines planned) in
parallel, each isolated in its own `git worktree`, and tracks them in one place:
a sidebar of projects and worktrees, a per-worktree Agent / Diff / Terminal pane,
a native diff reviewer, a task queue, and turn-completion detection so you can
see at a glance which agent is working, waiting on you, or done.

It's the orchestration counterpart to [Damson](https://github.com/hulryung/damson),
the GPU terminal it reuses — Orchard renders each agent's PTY with Damson's own
Metal terminal engine (`DamsonTerminal`) rather than reimplementing one.

> Same product space as [Orca](https://github.com/stablyai/orca), but native
> Swift/AppKit, macOS-only, and built on Damson's terminal engine.

## The model: worktrees outlive agents

The durable noun is the **worktree**, not the agent process. An agent starts,
finishes, and can be dismissed or replaced; the worktree and its branch stay
until you delete them deliberately. That's what makes a finished agent's output
reviewable instead of evaporating the moment it stops — and why quitting Orchard
changes nothing on disk.

```
~/Orchard/worktrees/<repo>/<name>          # outside your checkout
                           └── branch: <git-username>/<name>
```

* **Outside the repo** — file watchers, language servers, test globs, and `rg` in
  your primary checkout never see N copies of the project.
* **Readable names** — `dkkang/fix-parser`, then `-2`, `-3` on collision. Never a
  UUID: the branch is how you find this work in `git branch` or a PR.
* **Pinned base** — each worktree forks from a resolved commit (probing
  `origin/main` → `origin/master` → `main` → `master`), not from whatever happens
  to be checked out, so an agent never inherits half-finished local work.
* **Recorded in git itself** — `orchard.worktree.<uuid>.*` plus
  `branch.<branch>.base` in the repo's config. Restart rebuilds the sidebar from
  git, so no app-side store can drift out of sync with the disk.
* **Safe deletion** — a preflight names exactly what would be lost (uncommitted
  files, unpushed commits) before you confirm, protected paths are refused
  outright, and branch removal uses `git branch -d` so unmerged commits survive.

### Per-project setup

Commit an `orchard.yaml` and every fresh worktree is usable before the agent's
first turn:

```yaml
scripts:
  setup: |
    npm install
    cp .env.example .env
sharedPaths:      # linked in from the primary checkout
  - node_modules
  - .env
```

The setup script runs in the new worktree with `ORCHARD_ROOT_PATH`,
`ORCHARD_WORKTREE_PATH`, `ORCHARD_WORKSPACE_NAME`, and `ORCHARD_BRANCH` set;
failures are surfaced inline with their output rather than logged and forgotten.

## Status

Early. The core loop works: spawn an agent in a fresh worktree, drive its PTY,
detect when its turn completes, queue and schedule tasks across a concurrency
limit, and steer it from the UI or the `orchard-cli` control socket.

### Turn-completion detection (3 tiers)

Knowing whether an agent is **working**, **waiting on you**, or **done** is the
hard part. Orchard layers three signals, most-reliable first:

1. **Lifecycle hooks (primary).** On spawn, Orchard writes a scoped
   `.claude/settings.local.json` into the agent's worktree that POSTs Claude
   Code's own lifecycle events (`UserPromptSubmit`, `PreToolUse`/`PostToolUse`,
   `Notification`, `Stop`) to a loopback hook server, tagged with a per-agent
   token. Structured and race-free — the agent tells us its state directly.
2. **OSC 9999 (fallback).** For engines without hooks, an `\e]9999;{status}\e\\`
   escape in the PTY output is parsed straight from Damson's VT event stream.
3. **Screen fingerprints + interrupt inference (last resort).** The original
   screen-scraper (spinner/input-box/approval matchers) still runs when no
   structured signal is present, plus a synthesized idle after a Ctrl-C (which
   Claude Code doesn't emit a `Stop` for).

A structured signal always overrides fingerprints; a permission prompt never
reads as idle.

## The window

Dark-only, native chrome, color reserved for state — the app spends its life
framing someone else's terminal, so its own surfaces recede.

```
┌── Projects ─────────┬──────────────────────────────────────────┐
│ ▾ damson-ide     3  │  ● fix-parser   dkkang/fix-parser · 2m14s │
│   ● fix-parser      │  ┌ Agent │ Diff 3 │ Terminal ┐            │
│     ⌥ dkkang/fix…   │  ├──────────────────────────────────────┤ │
│     +142 −31        │  │                                      │ │
│     ⟳ claude  2m14s │  │   (live agent PTY / diff / shell)    │ │
│   ● add-retry       │  │                                      │ │
│   ✓ refactor-cfg    │  │                                      │ │
├─────────────────────┤  └──────────────────────────────────────┘ │
│ + New Worktree   ⊞ 🎨│                                          │
└─────────────────────┴──────────────────────────────────────────┘
```

* **Sidebar** — projects → worktree cards → the agent running inside, if any.
  Each card carries a status glyph, its branch, `+N −M`, and an unread marker
  when an agent finished a turn while you were looking elsewhere.
* **Detail pane** — per-worktree **Agent** (the PTY), **Diff** (native reviewer:
  changed-file list plus colored unified diff, measured against the fork point so
  committed and uncommitted work read as one change set), and **Terminal** (a
  plain shell in the same worktree).
* **⌘J** jumps to any worktree across every project; **⌘N** opens the composer
  (name, prompt, engine, base branch, branch override, and a fan-out count that
  runs the same prompt in N independent worktrees).

The Agent tab always shows something live: when no agent is running (or one has
exited), it falls back to a shell in the worktree rather than a dead-end empty
state, with a bar offering to start or restart an agent.

Key bindings: `⌘N` new worktree · `⌘J` jump · `⌘1/2/3` Agent/Diff/Terminal ·
`⌘G` all-agents grid · `⌘R` refresh diff · `⌃⌘S` toggle sidebar · `⌘,` settings.

## Settings (⌘,)

Three groups, and every value actually drives behavior — a preference that only
applied on the next launch would be worse than none, so each either feeds new work
as it's created or pushes into live objects on change:

| | |
|---|---|
| **General** | Default agent, how many agents run at once (per project), notifications — all, or only when an agent is blocked on you. |
| **Worktrees** | Worktree root directory, branch prefix (with a live `dkkang/fix-parser` preview), default base branch, whether to run `orchard.yaml` setup, whether the delete sheet pre-checks "delete branch". |
| **Terminal** | Theme, monospaced font family and size, with a live preview. Applies to terminals already open. |

A base-branch override that doesn't resolve in a given repo is ignored rather than
adopted, so one global preference can't break a project that lacks that branch.

## Build & run

Requires macOS 13+ and a Swift 5.9+ toolchain.

```sh
swift build                 # resolves the Damson engine dependency + builds
./scripts/run-dev.sh        # build Orchard (release) and launch it
swift test                  # DamsonOrchestrator unit tests
```

Orchard self-bundles into `~/Library/Caches/orchard/Orchard.app` on first launch
(its own Dock identity, `app.damson.orchard`). `ORCHARD_NO_TRAMPOLINE=1` runs the
bare binary — handy for driving it headless via `orchard-cli`.

## Architecture

| Target | Role |
|---|---|
| `DamsonOrchestrator` | Engine library: agent sessions, persistent worktrees (`WorktreeManager`, `WorktreeRecord`), git queries (`GitRunner`, `GitService`), project config + setup runner, task queue, readiness/turn detection, engine adapters (Claude Code, generic shell). Depends on `DamsonTerminal` + `DamsonControl`. |
| `Orchard` | SwiftUI app: project/worktree sidebar, per-worktree detail tabs, diff pane, composer, jump palette, control-socket dispatch. |
| `OrchardControl` + `orchard-cli` | Unix-socket control plane so scripts (or an agent) can drive a running Orchard instance. |

### Driving it headlessly

```sh
orchard-cli add-workspace ~/dev/myrepo
orchard-cli add-task --workspace 0 --title "Fix parser" --prompt "…"
orchard-cli list-worktrees            # id, branch, state, +N −M, commits ahead
orchard-cli worktree-diff <id>        # unified diff vs the fork point
orchard-cli delete-worktree <id>      # refuses if it would lose work; --force to override
orchard-cli show-settings             # open the Settings window
```

The terminal engine (`DamsonTerminal`) and IPC wire format (`DamsonControl`) come
from the [damson](https://github.com/hulryung/damson) repo as versioned SwiftPM
library products — pinned in `Package.swift` so damson's daily development can't
break Orchard's build.

## License

MIT — see [LICENSE](LICENSE).
