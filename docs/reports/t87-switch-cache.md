# T87 — a workspace switch costs no git

The user, after T86: "still a bit slow — cc-rate-widget to CAN-debugger-hw". T86 had taken
the *resolution* of a workspace off the critical path and got the pane drawing in 0.0 ms.
What was left was everything the workbench asks git once the pane exists, and one thing
nobody had measured at all.

Two rules, from the plan. **Nothing on the critical path**: the pane, the tree and the card
appear immediately and the facts arrive after. **Do not recompute what has not changed**:
cache per-worktree facts, with honest invalidation only.

## What a switch cost, and what it costs now

Wave 24's live-app table found `refreshConflicts` at 445 ms and `refreshCheckout` at 209 ms,
against ~103 ms for the same commands run raw from a shell. Three things were happening at
once, and only the first was the one being looked for.

| | Before | After |
|---|---|---|
| `git` processes per workspace, first visit | **5** | **3** |
| `git` processes per workspace, revisit | **5** | **0** |
| the explorer's watcher, per switch, on the main actor | **229 ms** (3754-entry walk) | **0.45 ms** |
| `git` processes in a view body, per sidebar re-render | **1 per project** | **0** |

### The reading itself

Measured through `GitFactsCacheTests.GitFactsBenchTests` against the user's own two
checkouts — read-only, three runs each, all on this machine:

| Repo | The 5 processes a switch used to run | One reading (3 processes) | Revisit |
|---|---|---|---|
| cc-rate-widget (94 entries) | 30.3 / 30.3 / 30.7 ms | **19.5–20.2 ms** | **0.004 ms, 0 git** |
| CAN-debugger-hw (3754 entries, 498 MB) | 36.9 / 40.6 / 42.5 ms | **30.5–35.9 ms** | **0.004 ms, 0 git** |

Reproduce:

```
ORCHARD_BENCH_REPO=~/dev/CAN-debugger-hw swift test --filter GitFactsBenchTests
ORCHARD_BENCH_REPO=~/dev/CAN-debugger-hw swift test --filter FileWatcherBaselineBenchTests
```

### Against the live app

**Pending.** These rows need a human to click six workspace selections in the running app
with `ORCHARD_TRACE_SWITCH=1`; accessibility is refused machine-wide on this box, so neither
the coordinator nor I can drive the UI, and synthetic clicks do not reach SwiftUI's gesture
handlers in any case. The coordinator has the build and the ask is out. They are left blank
rather than guessed.

| Phase (live app, cc-rate-widget → CAN-debugger-hw) | Before T87 | First visit | Revisit |
|---|---|---|---|
| `select(sync)` | — | | |
| `materializeDamsonSession` | 0.0 ms | | |
| `explorer.reload` | 0.3 ms | | |
| `explorer.watch` | *never measured* | | |
| `refreshCheckout` | 209 ms | | |
| `refreshConflicts` | 445 ms | | |
| readings caused by the switch | 2 (5 processes) | | |

One trace line, one env var:

```
ORCHARD_TRACE_SWITCH=1 ~/Library/Caches/orchard/Orchard.app/Contents/MacOS/Orchard 2>trace.log
…
ORCHARD_TRACE refreshConflicts 0.1 ms, reads=0, git=0 (process-wide)
```

`reads=` is the number the acceptance turns on and the only one that is *attributable*: it
counts fresh readings **this phase caused**, from the cache that owns them, and one reading
is exactly three git processes. `git=` is process-wide and therefore noisy — the first live
trace showed a launch-path `refreshConflicts` at 33 spawns while running none of its own,
because the startup fan-out over every worktree in every repo landed inside its window.
That reading was the counter, not the phase.

## What changed

### 1. The conflict summary stopped being a second reading

`refreshConflicts` ran `git rev-parse --absolute-git-dir` and a second `git status
--porcelain -z` — two processes asking questions the status reading had already answered,
started in parallel with it at the exact moment the user was waiting. Both are gone:

- **The unmerged list comes from porcelain v2.** `git status --porcelain=v2 --branch -uall
  -z` prints a `u` record per unmerged path with git's two-letter conflict code, in the same
  reading that answers "is this tree dirty". The path is *everything after the tenth
  column*, not the last token — taking the last token truncates a path with a space in it,
  which is pinned by `testUnmergedRecordsCarryTheirPathAndConflictCode`.
- **The git dir is resolved without git.** `<worktree>/.git` is either the directory itself
  (a primary checkout) or a one-line file holding `gitdir: <path>` (a linked worktree), and
  a linked worktree's git dir holds a `commondir` file naming the repo-wide one. That is
  how git resolves it, and it is a `stat` and a file read.
  `rev-parse --absolute-git-dir` survives as the fallback for a layout this reader does not
  understand, so an unfamiliar repo degrades to the old cost rather than to a wrong answer.
  `testALinkedWorktreesGitDirIsResolvedWithoutSpawningGit` checks the answer against git's
  own for both the git dir and the common dir.

Which operation is mid-flight still has to be asked even when there are no conflicted
files: a merge whose conflicts are all staged is unfinished, and that is exactly the state
where the user needs to be told what to do next. It is now `stat` calls on control files
rather than a process.

### 2. `GitFactsCache` — and the rule that makes it honest

One reading per worktree, keyed by real path and base ref, holding the status *and* the
conflict summary because they come from the same three processes.

The rule the plan set was "a cache that can serve a stale branch or a resolved conflict must
be invalidated by whatever changed it, or not exist". That is implemented as an invariant,
not a habit: **nothing is cached that is not watched.** `store` starts the watcher before it
publishes the entry, and if a watcher cannot be started the reading is returned to its
caller and never cached. A value nobody is watching is a value that can quietly become a
lie, so it does not get to exist.

What the watcher covers, per worktree:

- the working tree,
- the worktree's own git dir (`HEAD`, `index`, `MERGE_HEAD`, `rebase-merge/`),
- the repo-wide git dir (`refs/`, `packed-refs`) — because a commit in a *linked* worktree
  touches nothing in the working tree at all. It moves a ref that lives in the base repo.

`objects/` is excluded. A commit writes hundreds of files there and none of them change any
fact reported here — they are content-addressed blobs, and it is `refs/` moving that makes a
commit visible. Without the filter one commit would invalidate the cache dozens of times.

This is deliberately **not** the existing `FileWatcher`. That one exists to say *which* files
changed and walks the tree to find out, which on a 498 MB checkout is more work than the
reading it would be protecting. `GitTreeWatcher` only ever answers "something did", which is
all an invalidation needs, so it does no walking at all.

Three tests are the honesty of the whole design, and each one drives git as a **plain
subprocess** rather than through `GitRunner` — standing in for the user's terminal, an agent,
or anything else on the machine, none of which tell Orchard what they did:

- `testACommitMadeOutsideOrchardIsNoticed` — commit in a linked worktree, working tree
  untouched; `commitsAhead` goes 0 → 1 and the subject appears.
- `testABranchSwitchMadeOutsideOrchardIsNoticed` — `git checkout -b` rewrites one file in
  the worktree's git dir; the branch stops being served.
- `testAResolvedConflictIsNoticed` — a real merge conflict, then resolved; the summary that
  opened the conflict tab does not survive the commit that closed it.

Two smaller rules:

- **An invalidated reading is dropped, never served.** The cache never answers with
  something it knows is out of date. The view keeps showing the last fact it was given until
  a fresh one lands — visibly late, which is the honest way to be behind, and exactly what
  the published `@Published` status already did between refreshes.
- **A reading overtaken mid-flight is returned but not stored.** It is the newest thing
  anyone has, so its caller gets it; the next caller reads again rather than inheriting a
  value that was already wrong when it landed. `testAReadingInvalidatedWhileItRanIsNotStored`
  pins it against a deliberately slow stand-in for git, so it is the case under test rather
  than a race the test happened to win.

`GitRunner.onMutation` retires a reading the instant Orchard itself runs a mutating verb, so
a commit from the source-control panel does not wait out a file-system notification. That is
a latency shortcut and is documented as one: the watcher is the correctness guarantee, so a
verb wrongly counted read-only costs a few milliseconds of lateness, not a wrong answer.
(`worktree list` is the one verb the subcommand alone gets wrong, and it runs on the listing
path often enough that treating it as a mutation would defeat the cache.)

### 3. Coalescing, and getting off the cooperative pool

The sidebar row, the workbench's conflict check and the source-control panel all ask about
the same worktree in the same turn of the run loop. They now share one reading
(`testConcurrentReadersOfOneWorktreeShareOneReading`: four concurrent callers, three spawns,
one compute).

The readings themselves moved off the Swift cooperative thread pool. Every one blocks its
thread inside `poll` while git runs, and `Task.detached(priority: .utility)` doing that is
how a two-spawn conflict check took 445 ms while a sidebar refresh was in flight: the pool is
as wide as the machine has cores, and a fan-out over every worktree in every repo fills it
with blocked threads. `ReadScheduler` runs at most four at a time on a queue of its own. It
also fixes `refreshAllStatuses`, which T86 left recorded as "still unbounded".

### 4. The selection reads first

The first live trace showed `refreshCheckout` at 172 ms three times over at launch. The
reading measures 30 ms. The other 140 ms was queueing: at launch every worktree in every repo
asks at once, and the queue is bounded, so the workspace the user just picked waited behind
the whole fan-out.

`ReadScheduler` is two queues rather than a priority number, because the ordering has to be
exact — a selection arriving behind twenty background readings has to be *next*, not
twenty-first. Work already in flight is never preempted (a git process is not interruptible),
so the wait is bounded by one reading rather than by the backlog. Measured with a synthetic
24-deep backlog and a fixed-cost stand-in for git: a selection costing 420 ms alone costs
533 ms behind the backlog instead of scaling with it
(`testAForegroundReadingOvertakesABacklogOfBackgroundOnes`).

### 5. The explorer's watcher was walking the whole workspace on the main actor

Not in anyone's trace, and the largest single number in this task.

`FileWatcher.start(root:)` took its baseline snapshot — a recursive walk calling
`attributesOfItem` on every entry — **synchronously**, and `FileExplorerModel.configure` calls
it from `onChange(of: identity)`, which fires on every workspace selection. On
CAN-debugger-hw that is **229 ms of main-thread work per switch**, on top of every phase the
trace did cover. `explorer.reload` at 0.3 ms was measured; the `startWatching()` line right
after it was not.

The walk now runs on the watcher's own serial queue, enqueued *before* the FSEvents stream is
created, so any event the stream delivers queues behind it and reconciles against a real
baseline rather than an empty one. `start` went from 229 ms to 0.45 ms. Both halves are
pinned: `testStartDoesNotWalkTheTreeOnTheCallersThread` (against the measured cost of the
walk itself, so it cannot pass by the machine being fast) and
`testTheFirstReconcileDoesNotReportPreexistingFilesAsCreated` — because diffing against an
empty baseline would announce the entire workspace as newly created.

The trace now carries an `explorer.watch` phase so this can never go unmeasured again.

### 6. Synchronous git inside view bodies

Raised by the coordinator mid-task, from the user's own question — why is slow work not
simply on another thread. Four instances, all of them *getters read during rendering*, which
is the opposite shape from the phases above: small per call, but on the main thread inside
`body`, which is the thing that actually stutters.

- **`ProjectSession.rootSubtitle`** ran `git rev-parse --abbrev-ref HEAD`. Read by the
  sidebar's project row, the workbench header and the status-bar chip — so a three-project
  sidebar ran three main-thread git processes on every re-render, and selecting a workspace
  re-renders the sidebar because the highlight moves. The branch was already in the status
  reading; there was never anything to ask for. It shows `…` until the first reading lands,
  rather than naming a branch nobody looked up.
- **`ProjectCheckoutDiffPane`** read the branch the same way, once per render of the pane.
- **`ComposerView.branches`** ran `git for-each-ref` from `body` — once per keystroke while
  the composer is open. Loaded once now, off the main actor, via
  `ProjectSession.baseRefChoices()`.
- **`DeleteWorktreeSheet.preflight`** was a computed property running a *whole status
  reading* — three processes — evaluated inside `body`, re-run on every render of the sheet
  while the user reads the warnings it produced. Loaded once now, and the sheet says
  "Checking what this would discard…" rather than showing delete controls whose `force` flag
  it would have to guess.

One more found by the same audit, outside the switch path but the same class:
**`FileExplorerModel.applyFilter`** ran `FileService.search` — a tree walk — on the main
actor from `onChange(of: filter)`, so one walk per keystroke. Now detached with a token that
drops answers to queries the user has already typed past.

#### The audit, including what came back clean

| Site | Reaches git / the filesystem from a view body? |
|---|---|
| `ProjectSession.rootSubtitle` (sidebar row, workbench header, status bar) | **was: `git rev-parse`** — fixed |
| `ProjectCheckoutDiffPane.body` | **was: `git rev-parse`** — fixed |
| `ComposerView.branches` | **was: `git for-each-ref`** — fixed |
| `DeleteWorktreeSheet.preflight` | **was: a full status reading** — fixed |
| `FileExplorerModel.applyFilter` | **was: a tree walk** — fixed (not the switch path) |
| `JumpPalette.catalog` | clean — carries a comment from an earlier instance of exactly this bug |
| `JumpPalette.loadQuickOpen` | clean — `Task.detached` |
| `SourceControlPanel.refresh` / `.mutate` | clean — `Task.detached` |
| `DiffPaneView.loadDiff` / `.commit` / `.push` | clean — `Task.detached` |
| `ConflictReviewPane.refresh` / `.select` / resolutions | clean — `Task.detached` |
| `WorktreeRecord.refresh`, `ProjectSession.refreshCheckout` | clean — through the cache, off the main actor |
| `FileExplorerModel.reload` → `load(parent:)` | clean — reads one directory (0.3 ms measured), not from `body` |
| `SidebarView` `worktrees.isGitRepository`, `SettingsView` `branchPrefix`, `ComposerView` `branchPrefix` / `takenNames` / `suggestedName` | clean — stored values and pure functions |
| `EditorDocumentController`, `EditorSessionStore` | clean — controller methods, not getters |

### 7. Untracked files, which would have been the cause on a different repo

CAN-debugger-hw has zero untracked files, so this was not what the user hit. It would have
been on a repo that has them: `GitService` read **every untracked file whole, on every
refresh**, with `attributesOfItem` for the size and a per-byte `Data.reduce` for the count.

There is no `git` command that counts the lines in a file git is not tracking, so the only
way to put a `+N` on a brand-new file is to read it. The fix is a cheaper read and a bound:

| | Before | After |
|---|---|---|
| 300 files / 9.5 MB | 46.5 ms | **4.9 ms** |
| 3000 tiny files | 186.0 ms | **38.0 ms** |

`stat` and a plain `read` instead of `attributesOfItem` and `Data(contentsOf:)` — the old
pair spent most of its time building an `NSDictionary` of every attribute of a file to read
one field off it, which is why thousands of *small* untracked files were expensive
regardless of size — and `memchr` for the newline scan. Both counters are asserted to
produce the identical number.

The budget is what removes the unbounded case: 16 MB and 2000 files per refresh, in both
halves because either can be the whole cost. That caps this at roughly 30 ms.

What is past the budget is reported as **a change of unknown size**, which is a different
claim from "a change of zero lines" and from "binary". `GitFileChange.linesCounted` and
`GitDiffStat.countsComplete` carry it; the diff pane's file row shows `—` and the stat badge
shows `+N…` with a tooltip. This also retires an existing lie: a text file over the per-file
ceiling used to be reported as binary.

## What is pinned by tests

`GitFactsCacheTests` (17) — warm reading spawns nothing; four concurrent readers share one
reading; a working-tree edit, an outside commit, an outside branch switch and a resolved
conflict each retire the reading; an overtaken reading is not stored; status + conflicts cost
three spawns; the git dir and common dir resolve without git and agree with git; mutating
verbs are told apart from read-only ones and a read-only query retires nothing; untracked
line counts are exact including a missing final newline, agree between counters, and a file
past the budget is flagged rather than called empty.

`WorkspaceSwitchSpawnBudgetTests` (2) — alternating between two visited workspaces spawns no
git at all while still reporting both branches and the conflict summary; a first visit has
nothing cached to serve.

`GitFactsUrgencyTests` (1) — a selection does not wait behind a 24-deep background backlog.

`GitStatusPorcelainParseTests` (+2) — unmerged records carry path (spaces included) and code;
a malformed one is skipped rather than turned into a conflict on a path nobody named.

`FileWatcherTests` (+2) — `start` does not walk on the caller's thread; the first reconcile
does not report the existing workspace as freshly created.

`swift build && swift test` (1323 tests, 4 skipped, 0 failures) and `scripts/e2e-headless.sh`
both pass. The three skips are the env-gated benches.

## Known limits, stated rather than hidden

- **A busy workspace re-reads.** An agent writing to the workspace on screen invalidates
  continuously. The cache does not serve stale values, so the card is re-read — debounced to
  once per 750 ms, on the trailing edge so the last write is the one the reading sees. A
  switch back to a workspace an agent is actively working in therefore *does* run git; the
  acceptance case, and the user's complaint, is two quiet workspaces.
- **Anything under the repo-wide git dir invalidates every worktree of that repo.** A commit
  in worktree B retires worktree A's reading. It has to: A's `unpushedCommits` is read
  against refs that live there, and a `pack-refs` rewrites the file all of them share. The
  cost is one background re-read, and `objects/` — the loud part — is already excluded.
- **A build writing into an ignored directory invalidates.** Telling "a new untracked file"
  from "a file `.gitignore` covers" cannot be done without asking git, which is the thing
  being avoided. Over-invalidation costs a re-read; under-invalidation would cost the truth.
- **The visual pass still has not happened.** Same as T86: accessibility is refused
  machine-wide on this box, so no screenshot and no synthetic input. That the switch *feels*
  immediate, that `…` in a project row is a beat rather than a flicker, and that the delete
  sheet's "Checking…" is not annoying, are all unwitnessed and want a person's eyes.
