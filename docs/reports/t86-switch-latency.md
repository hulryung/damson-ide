# T86 — workspace switching

The user reported that selecting a workspace was slow to change the pane. Wave 24 measured
it on the live runtime and found half a second going into resolving a worktree selector,
with git accounting for almost none of it. This is what the time was, what it is now, and
what had to change.

## Result

Measured with `scripts/bench-switch-latency.sh`: a headless `orchard serve` in a throwaway
HOME, three git repos with one Orchard worktree each, median of nine runs of the whole CLI
invocation (process spawn + socket connect + RPC + work) — the same way the coordinator
measured. "Before" is the same harness driven against the pre-T86 binary built from
`576e682`, in the same session on the same machine, so the two columns are comparable.

| Call | Before | After | Wave-24 plan target |
|---|---|---|---|
| `orchard status` (CLI round-trip baseline) | 19 ms | 19 ms | — |
| **`worktree list` (all three repos)** | **384 ms** | **33 ms** | under 100 ms |
| `worktree list --repo id:<repo1>` | 112 ms | 29 ms | — |
| `terminal create --cwd <path>` | 21 ms | 21 ms | — |
| **`terminal create --worktree id:<repo>::<path>`** | **525 ms** | **30 ms** | under 100 ms |
| raw `git worktree list --porcelain` | 23 ms | 23 ms | — |
| raw `git status --porcelain` | 24 ms | 23 ms | — |

Both acceptance numbers are met with about three times the required margin. The machine was
shared with other agents throughout; three re-runs over the following hour, at load averages
between 5 and 10, read 33–41 ms and 30–35 ms against baselines of 19–22 ms. The shape holds
and the whole table shifts together with load, which is why every row is reported next to
the `status` round-trip that carries none of this work.

### Against the live app

The coordinator rebuilt from main and relaunched, then measured the same calls against the
running app (three registered repos, four live panes). I re-measured the read-only half
myself through the app's own runtime socket; the two agree.

| Call | Before (live app) | After (live app) |
|---|---|---|
| `orchard status` (baseline) | 30 ms | 25 ms |
| `worktree list` (three repos) | 820 ms | 108 ms (mine: 116 ms) |
| `terminal create --worktree` | 516–1000 ms | 110 ms |

Both harnesses are reported because they answer different questions. The headless bench
isolates the work this task changed; the live app adds what the app process costs on top of
it, and that turns out to be the whole of the remaining gap — see below.

Reproduce with:

```
swift build -c release
./scripts/bench-switch-latency.sh                 # add ORCHARD_BENCH_RUNS=N for more samples
ORCHARD_BENCH_BIN=<other binary> ./scripts/bench-switch-latency.sh   # to compare builds
```

## Where the time actually went

`GitRunner` now counts every `git` it launches (`GitRunner.Trace`), and
`ORCHARD_GIT_TRACE=1` prints each one with its wall-clock and whether it ran on the main
thread. Pointing that at the pre-T86 runtime showed a warm `worktree list` over three repos
spending **nine serial git spawns**:

```
git -C repo1 rev-parse --abbrev-ref HEAD        # primary checkout's branch
git -C repo1 rev-parse HEAD                     # primary checkout's head
git -C wt/repo1/bench1 rev-parse HEAD           # each worktree's head
… the same three again for repo2 and repo3
```

Two per repo plus one per worktree, laid end to end. And `terminal create --worktree
id:<repoId>::<path>` cost *more* than the listing, because resolving the selector ran the
whole listing first: the pane needed one workspace and paid for every registered repo.

The individual spawns were 8–18 ms each when they ran alone, which matched raw `git` — so
the plan's reading was right that git is not the slow part. But they were 70–85 ms each
when several ran at once, which is where the rest of the half-second came from. That turned
out to be Orchard's own doing, not git's (see the runner change below).

## What changed

### 1. An `id:` selector resolves from the repo it names

`WorkspaceService.resolveWorkspace` used to enumerate every repo and then pick the match.
`id:<repoId>::<path>` already names its repo and its path, so it now reads that repo alone —
one `git worktree list --porcelain`, nothing else — and only falls through to the full
listing when the direct read genuinely cannot find it. The fallback keeps the fast path a
shortcut rather than a narrower match: a path the repo does not hold still fails
`unknown_worktree`, and `name:` / `branch:` / `path:` selectors are untouched.

### 2. One porcelain read per repo replaces 2 + N `rev-parse` calls

`git worktree list --porcelain` already prints the path, HEAD commit and branch of the
primary checkout *and* every linked worktree. The projection now takes that one reading per
repo (`WorktreeFactsReader`) instead of buying the same facts a spawn at a time. Nine spawns
for three repos became three.

The paths need care: git prints the realpath of every worktree (`/private/tmp/...` where
Orchard holds `/tmp/...`), so the map is keyed through `resolvingSymlinksInPath`. A repo
registered by a path *inside* its checkout falls back to the porcelain's main entry, which
git always prints first.

### 3. Repos are read in parallel

The per-repo porcelain reads run concurrently (`DispatchQueue.concurrentPerform`). The
`WorktreeService` for each repo is resolved first, on the main actor — that is where a cold
repo pays its one-time `start()` — so the parallel part is purely the process spawns, which
share nothing.

### 4. A status reading is three git processes, not eight

`GitService.status` used to spawn: `rev-parse --abbrev-ref HEAD`, `diff --name-status`,
`diff --numstat`, `ls-files --others`, `rev-list --count <base>..HEAD`, `status --porcelain`,
`log -1 --pretty=%s`, `rev-parse --abbrev-ref @{upstream}`, `rev-list --count @{upstream}..`.
Now:

- `git status --porcelain=v2 --branch --untracked-files=all -z` carries the branch, whether
  there is an upstream, how far ahead of it HEAD is, whether the tree is dirty, and the
  untracked list — five of those spawns in one.
- `git diff --no-renames --raw --numstat -z <base> --` carries change kind *and* line counts
  from a single walk; git emits both requested formats in one run.
- `git log -z --format=%s <base>..HEAD` carries both the ahead count and the newest subject.

This does not show up in the two headline numbers — a listing never reads status — but it is
what the sidebar pays per worktree on every refresh, so it is multiplied by the number of
workspaces on screen.

**Fixed on the way:** `--no-renames` is now explicit. `diff.renames` defaults to *on*, and a
detected rename makes `--numstat -z` emit a record whose path field is empty, which the old
parser read as a changed file with no name. Pinned by
`testARenameReadsAsDeletePlusAddWithNoPhantomEntry`.

### 5. The runner drains both pipes from one thread

`GitRunner.captureData` dispatched two reader blocks onto the global concurrent queue and
blocked its caller on a third. Reading the pipes concurrently is not optional — draining one
to the end before touching the other deadlocks as soon as either buffer fills — but the
implementation meant every git call parked three threads. A handful of git queries at once
starved that pool, which is exactly why concurrent spawns cost 80 ms instead of 10 ms.

It now watches both descriptors with `poll` on the calling thread. Three concurrent raw git
spawns from a shell cost 27 ms; through the old runner they cost 84 ms each; through the new
one the whole parallel read is back down to the cost of one spawn. Output larger than a pipe
buffer and stderr on a nonzero exit are both pinned by tests
(`testOutputLargerThanAPipeBufferIsCapturedWhole`, `testStderrSurvivesANonzeroExit`).

### 6. No cache

The plan allowed caching stable facts with honest invalidation. Nothing was cached. Once a
whole-repo reading costs one spawn, a cache would buy a few milliseconds and risk showing a
branch or a status that has since changed — including from outside the app, which nothing
here can be notified about. The only thing kept between calls is what already was: the
per-repo `WorktreeService` and its one-time `start()`.

## The app half: nothing git on the main thread during a switch

Two things ran git — or a spawn — on the main thread while a workspace switch was in flight.

**`ProjectSession.refreshCheckout()`** was `async` but did its work inline on the main actor,
so selecting a project root froze the workbench for the length of a full status read.
`WorktreeService.primaryCheckoutStatus()` is now `async` and detached, like
`WorktreeRecord.refresh()` already was — a synchronous spelling on a `@MainActor` type could
only ever have been a main-thread git read, so the signature no longer offers one. Opening a
project no longer waits on it either; the status arrives after the window does.

**Pane materialization ran inside `TerminalPane.body`.** Drawing the pane spawned the PTY,
registered it with the runtime and mutated `shells`, all before SwiftUI could put a pixel on
screen. `AppStore.prepareDamsonSession` now does that from the pane's `.task`, idempotent
and single-flight so repeated view updates cannot mint a second PTY for one pane; the body
is a pure lookup (`existingDamsonSession`). A pane that has not been prepared yet renders
"Opening…" rather than the "No session" placeholder — the difference between "not yet" and
"not going to" is what a user reads off a pane, and only the second one is a refusal.

Everything else a switch touches was already off the main actor: `WorktreeRecord.refresh`,
`refreshConflicts`, the source-control panel and the diff pane all detach their git.
`GitRunner.Trace.mainThreadSpawns` makes the guarantee checkable, and
`MainThreadGitTests` asserts it stays at zero across a record refresh and a primary-checkout
status.

## What is pinned by tests

- `GitStatusPorcelainParseTests` — porcelain-v2 and combined raw/numstat framing, including
  the rename record's trailing original-path field and the detached-HEAD wording.
- `GitSpawnBudgetTests` — status is exactly three spawns; one porcelain read covers every
  worktree in a repo; facts key through symlinks; a rename produces delete+add and no
  phantom entry; large output and stderr survive the new drain.
- `MainThreadGitTests` — status refreshes never spawn git on the main thread.
- `WorkspaceSwitchLatencyTests` — a warm listing spawns one git per repo and still reports
  every branch and head; an `id:` selector reads only the repo it names; a primary-checkout
  id resolves the same way; a repo registered by a subdirectory still projects branch and
  head; a bad path still fails typed; `name:` / `branch:` / `path:` still resolve.

`swift build && swift test` (1294 tests, 2 skipped, 0 failures) and
`scripts/e2e-headless.sh` both pass.

## What is left, measured

Against the live app the residual is a **fixed per-`git`-spawn cost inside the app process**,
not the enumeration this task removed. The evidence, all median-of-nine through the app's
runtime socket:

| Call | Git spawns | Live app |
|---|---|---|
| `repo list`, `host list`, `terminal list`, `status` | 0 | 28–32 ms |
| `worktree show --worktree id:<repo>::<path>` | 1 | 111 ms |
| `worktree list --repo <one repo>` | 1 | 113 ms |
| `worktree list` (three repos) | 3, in parallel | 116 ms |

Git-free RPCs cost the round-trip baseline. Anything that touches git costs about 85 ms more,
and that surcharge does not grow with the number of repos or spawns — one spawn and three
parallel spawns cost the same. The same spawn costs ~10 ms from the headless runtime on the
same machine.

`Process.waitUntilExit()` is the reason: it is documented to poll *the current run loop*, and
on the app's main thread that is AppKit's. `GitRunner` now reaps through the process's
termination handler and a semaphore instead, which is signalled off the run loop and costs
the same everywhere. The corroboration is blunt: the full test suite went from 227 s to 107 s
on the same machine with no other change, XCTest being another main-thread-with-a-run-loop
host. What that does to the live-app numbers needs a rebuild and relaunch to confirm, which
is the coordinator's to run.

## Found but not fixed

- **Live PTYs inflate every RPC.** With eight shells open, a `worktree list` that costs
  33 ms alone costs ~105 ms, and `terminal list` scoped to a worktree does the same — with
  no extra git involved. The main actor is doing per-pane work that scales with the number
  of open panes. It is not a workspace-switch cost (a switch does not open eight panes) and
  it is in the terminal layer rather than this task's ownership, but it is real and it is
  measurable with the same harness. The benchmark closes each pane it opens so the create
  numbers are not contaminated by it.
- **`refreshAllStatuses` fans out unbounded.** It still starts one detached status read per
  worktree at once — now three git processes each rather than eight, so a repo with twenty
  worktrees goes from 160 concurrent spawns to 60. Better, still unbounded.

## Not verified here

**The visual pass did not happen.** The app was rebuilt and relaunched by the coordinator and
its runtime answered every measurement above, but the accessibility surface was unavailable
for the whole of this session: `orca computer get-app-state` returned `permission_denied`
("has visible windows but no accessibility window") for Orchard *and* for Finder, so it is
machine-wide rather than anything about this build, and `screencapture` had no screen-recording
grant from this shell either. Both would need a human to toggle the permission.

So the specific claims that are still unwitnessed: that the "Opening…" placeholder appears
and is replaced by the terminal rather than lingering, and that a switch *feels* immediate.
Those are the user's original complaint and they want a person's eyes. Everything measurable
without a window — the RPC latencies, the spawn budgets, the absence of main-thread git — is
measured above and pinned by tests.
