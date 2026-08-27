# T88 — Checks: CI and pull-request state on the card and in the sidebar

Date: 2026-08-27 (Asia/Seoul)
Branch: `hulryung/v26-checks`, on top of `2476fa4` (wave 26 plan)
Forge tooling: `gh` 2.98.0 (2026-08-20), authenticated as `hulryung`
Verification runtime: headless `orchard serve --data-dir <scratch>` — its own data dir,
never the app's. The Orchard app was not launched, quit, or relaunched.
GitHub writes: **none.** Every `gh` invocation in the code, the tests, and this
report is `pr view`, `pr list`, `auth status`, or `run view --log`. No PR was
opened, no comment posted, nothing pushed.

## What shipped

Three things the inventory asked for and Orchard did not have:

1. **Typed links on worktree meta** (inventory §2's `issue` / `linear-issue` /
   `jira-issue` / `pr` card properties). `linkedIssue`/`linkedPR` were bare
   strings; they are now views onto a typed `links: [WorktreeLink]` array.
2. **A checks section in the right sidebar** (inventory §6's `pr-checks` /
   `checks`): the workspace's pull request, every check on it, and its conclusion.
3. **A `check-details` centre tab** (inventory §6): one check run's GitHub state
   and its Actions job log.

Plus the agent-facing half: an `OrchardRuntime/Checks` service and the
`checks list|show` verbs, so the CLI and the GUI read the same thing the same way.

## The rule this task is actually about

> Every unavailable path must be typed and visible — no `gh`, not authenticated,
> no remote, no PR for this branch, API error — never a blank panel, never a
> guessed status, never a cached status presented as current.

That is enforced by making the alternative unrepresentable, not by remembering to
handle it:

- `ChecksSnapshot` has exactly two shapes. `available` carries a PR and its
  checks; `unavailable` carries a `ChecksUnavailability`, which is a
  `ChecksUnavailableReason` plus a **headline**, `gh`'s **own words** as detail,
  and a **remedy**. There is no third shape, so "blank panel" has nothing to
  render from.
- `CheckBucket.from(status:conclusion:)` maps a conclusion string it has never
  seen to `.unknown`, never to `.pass`. `ChecksRollup` keeps `none` (a PR with no
  CI — a real answer) distinct from `unknown` (a state we do not recognise).
- Every snapshot carries `observedAt`; the wire adds `ageSeconds`; the CLI prints
  `checked 12s ago`; the sidebar footer prints the same, re-rendered once a second
  while a panel is on screen. A cached reading cannot be shown without its age.
- `WorktreeLinkInference` types `#412`, `123`, `GH-7`, and github.com / linear.app
  / *.atlassian.net URLs. `ENG-412` is a Linear key *and* a Jira key, so it stays
  `untyped` — shown as untyped, with the command that would type it — rather than
  being guessed into one.

### Typed reasons

| code | when | remedy shown |
|---|---|---|
| `gh_not_installed` | no `gh` on PATH or in the usual install dirs | install it |
| `gh_not_authenticated` | `gh` exits 4, prints its login hint, or GitHub answers 401 | `gh auth login` |
| `no_git_remote` | the repo has no remote at all | add one and push |
| `unsupported_forge` | it has a remote and it is not GitHub | GitHub only; nothing inferred |
| `detached_head` | HEAD is detached, so no branch to look a PR up by | check out a branch |
| `no_pull_request` | GitHub answered; the branch has no PR | open one |
| `api_error` | rate limit, 4xx/5xx, unreadable payload | retry; check auth/network |
| `gh_timed_out` | `gh` outlived the deadline and was killed | retry |
| `remote_unsupported` | the workspace lives on another host | read it from a shell there |
| `not_a_worktree` | the path is not inside a git work tree | open a git workspace |
| `not_a_git_workspace` | a folder workspace: no branch | folder workspaces have no PR |

And for one check's log: `not_an_actions_job` (a StatusContext or a check with no
Actions job URL — it names the details URL instead of pretending it can fetch),
`log_pending`, `log_expired`, `api_error`, `gh_timed_out`.

## Cache: what makes it honest

`ChecksService` caches per workspace path. A reading is **current** only when both
hold:

1. **Same commit.** Keyed on the worktree's HEAD sha.
2. **Same branch.** Added after live verification caught it (below).
3. **Inside the TTL** (45s, `ORCHARD_CHECKS_TTL_SECONDS` overrides). Checks change
   while the commit does not — that is what CI *is*.

Past either, `cached()` returns nil and the caller re-reads. A stale entry is
reachable only through `lastKnown(path:)`, which is named for what it is and
carries `observedAt`. Concurrent readers of the same workspace share one in-flight
`gh` (`testConcurrentReadsCollapseToOneSpawn`).

**A bug this caught.** The first implementation keyed only on the HEAD sha. Live
verification ran `git checkout --detach HEAD` in a scratch repo — same commit, no
branch — and the panel confidently redrew the *previous branch's* answer. Two
branches sitting on one commit have the same hole. The branch is now part of the
key, and `testSwitchingBranchAtTheSameCommitDropsTheReading` pins it.

## Wave 25's rules

- **No network or subprocess in a view body.** Views read `checks.snapshot(for:)`,
  a dictionary lookup. The read happens in `ChecksSidebar`'s `.task(id:)` and in
  the refresh button. `store.checksTarget()` is pure lookups.
- **Nothing on the main thread.** `SystemGitHubCLI.run` is a detached utility task;
  `ChecksService` is an actor; even the two git reads (`rev-parse`,
  `symbolic-ref`) run in a detached task so the actor is never held across them.
- **No git cost added to a workspace switch.** There is no background sweep — a
  checks read happens only while the Checks section is mounted, or when the CLI
  asks. The two git reads use verbs that are in `GitRunner.readOnlyVerbs`, so they
  invalidate nobody's `GitFactsCache` entry. `GitFactsCache` and the `Git*` types
  were not touched.
- **One subprocess for the common path.** `gh pr view <branch> --json
  number,title,url,state,isDraft,headRefName,headRefOid,statusCheckRollup` answers
  the PR *and* the whole rollup in one call. `gh` is resolved to an absolute path
  (`/opt/homebrew/bin/gh`, …) for the reason `GitRunner` resolves `git`: a
  Dock-launched app has no `/opt/homebrew/bin`, and "gh not installed" must be
  true when it is shown.

## Live verification

All of the following ran against the real `gh` 2.98.0, against a headless runtime
with its own data dir.

**Unavailable paths** — each produced its own reason, carrying gh's own words:

```
$ orchard checks list                       # this worktree, branch with no PR
No pull request [no_pull_request]  hulryung/v26-checks · checked just now
  no pull requests found for branch "hulryung/v26-checks"
  Open a pull request for this branch, then refresh.

$ orchard checks list --worktree path:<scratch/noremote>
No git remote [no_git_remote]  main · checked just now
  no git remotes found
  Add a remote (git remote add origin …) and push the branch.

$ orchard checks list --worktree path:<scratch/gitlab-remote>
Remote is not GitHub [unsupported_forge]  main · checked just now
  none of the git remotes configured for this repository point to a known GitHub
  host. To tell gh about a new GitHub host, please use `gh auth login`
  Checks read GitHub only. Nothing is inferred for other forges.

$ orchard checks list --worktree path:<scratch/detached>
Detached HEAD [detached_head]  (no branch) · checked just now
  HEAD is detached at 5e442e12.
  Check out a branch, then refresh.
```

`gh_not_authenticated` (empty `GH_CONFIG_DIR`, cleared `GH_TOKEN`), the HTTP-401
rejected-credential case, `gh_not_installed`, and `not_a_worktree` are verified in
`ChecksLiveGitHubCLITests` against the same real binary — the user's own
credentials are never touched, only a scratch config dir.

**The available path** — a scratch repo whose `origin` is `cli/cli` and whose
branch name matches a real open PR's head ref (no clone, no checkout, no write):

```
$ orchard checks list --worktree path:<scratch/livepr>
#14267 chore(deps): bump github.com/google/go-containerregistry from 0.21.9 to 0.22.0
  OPEN · dependabot/…-0.22.0 · All checks passed · checked just now
  https://github.com/cli/cli/pull/14267
  skipped   label-external  (PR Triaging)
  pass      lint  (Lint)
  pass      build (ubuntu-latest)  (Unit and Integration Tests)
  … 42 checks total, every one in a named bucket

$ orchard checks show --check govulncheck --limit 8
govulncheck — Passed
  github: COMPLETED/SUCCESS
  https://github.com/cli/cli/actions/runs/32977930148/job/98207132573
  log: last 8 of 266 lines
  <8 real log lines>
```

Truncation is stated, never silent — the tail is kept because for a failing job
the end is the part that says why.

**Typed links**, through `worktree set`:

```
--issue "#412"                              → issue        412
--pr "https://github.com/o/r/pull/9"        → pr           9    (url kept)
--issue "https://acme.atlassian.net/browse/ENG-99" → jira-issue ENG-99
--issue "ENG-412"                           → untyped      ENG-412
--issue "ENG-412" --link-kind linear-issue  → linear-issue ENG-412
--issue "ENG-412" --link-kind bogus         → invalid_argument: unknown --link-kind
                                              'bogus'. Use issue, linear-issue,
                                              jira-issue, pr
```

An unknown `--link-kind` is refused rather than ignored: dropping it silently
would store an untyped link while the caller believed it had typed one.

**A second bug live verification caught.** `cli/cli`'s rollup returns 42 entries,
several sharing a name (retried jobs). Ids are `detailsUrl ?? name`; when even the
URL repeats, the id is now suffixed with its position so every check stays
individually addressable by the sidebar list and by `checks show --check`.

## Persistence and compatibility

`WorktreeMeta` gained a hand-written `Codable`. Decoding a file written before T88
(only `linkedIssue`/`linkedPR`) migrates the two strings into typed links; encoding
writes `links` **and** keeps both legacy strings, so an older build — or anything
reading `orchard-data.json` directly — still sees what it wrote. `worktree`
selectors (`issue:`), `Workspace.linkedIssue/linkedPR`, and every existing caller
keep working unchanged; `FolderWorkspaceRecord.links` is optional for the same
reason. Pinned by `WorktreeLinkTests`.

## Surfaces

- **Right sidebar → Checks.** PR title + state + rollup, a counts line, one row per
  check (bucket icon, name, workflow, duration; hover shows GitHub's raw
  `status/conclusion` and the details URL), a refresh button that says what it does
  ("ask GitHub again now, ignoring the cached reading"), and a footer with the age
  and the commit the reading was taken at. Unavailable renders the headline, gh's
  detail, the remedy, and the code chip. The section is mounted only while shown,
  so a hidden panel costs no network.
- **Centre → Check tab.** Opened by clicking a check, never on its own. Header
  carries the bucket, GitHub's raw state, the workflow and the duration; body is
  the job log with its bounds stated, or a typed reason with a remedy.
- **Card.** Typed link badges (tracker icon + `#412` / `ENG-412`; an untyped link
  says so on hover and names the command that types it), and a `ci` chip showing
  the rollup — drawn **only** from a reading Orchard actually took for that
  workspace. There is no background sweep, so a card never guesses a CI state; a
  workspace whose checks have never been read shows no chip at all.

## Verbs

```
orchard checks list [--worktree <selector>] [--refresh]
orchard checks show --check <name|details-url|job-id> [--refresh] [--limit <n>]
orchard worktree set --issue <text> [--link-kind issue|linear-issue|jira-issue|pr]
```

`checks list` returns `links` alongside the snapshot, so one call answers both
halves of the card. An unavailable path is an **answer**: `ok: true`,
`status: "unavailable"`, a typed reason. `ok: false` means the request was
malformed or the workspace could not be resolved — pinned by
`testUnavailableIsAnOkAnswerWithATypedReasonNotAnError`.

`checks show` on a snapshot that has no checks repeats the *snapshot's* reason
(`gh_not_authenticated`, …) rather than the misleading `check_not_found`. A
selector matching two checks returns nil rather than picking one, and the error
lists what is there.

## Tests

| suite | n | what it holds |
|---|---|---|
| `WorktreeLinkTests` | 12 | inference, ambiguity staying untyped, slot semantics, legacy-file migration, encode keeping both forms |
| `ChecksServiceTests` | 23 | every gh failure shape → its own reason, bucket/rollup collapsing, cache honesty (commit, branch, TTL, refresh, invalidate), in-flight collapse, log tail bounds |
| `ChecksHandlerTests` | 11 | the RPC contract, against a real git checkout and a scripted `gh` |
| `ChecksLiveGitHubCLITests` | 9 | the same paths against the **real** `gh` — the pin that a gh wording change fails loudly instead of quietly degrading to `api_error` |
| `CLIFormattingTests` (+9) | | the published help mentions every reason code; human output shows the age, the code, and truncation |

`swift build` clean, `swift test` 1378 tests / 0 failures / 4 skipped (the four
pre-existing skips). The live suite skips itself when `gh` is absent or logged
out, and honours `ORCHARD_SKIP_NETWORK_TESTS=1`.

## Not done, and why

- **Forges other than GitHub.** `unsupported_forge` is the honest answer, not a
  placeholder: nothing about a GitLab or Bitbucket remote is inferred.
- **Linear / Jira link *resolution*.** The kinds are stored and displayed; nothing
  fetches an issue title from those trackers. That needs credentials Orchard has
  no place to keep yet, and a guessed title would be exactly the failure mode this
  task is about.
- **A background checks sweep.** Deliberate. A periodic poll would spend a network
  round trip per workspace per tick for a panel nobody has open, and it is the
  fastest way to end up showing stale CI state as current.
- **A remote workspace's checks.** Typed `remote_unsupported`. Reading them here
  would answer with this machine's git and this machine's `gh` about a checkout on
  another host.
- **A human has not driven these two GUI surfaces.** They are unit- and
  CLI-verified end to end, and the app was deliberately not launched (the task
  forbids it). The sidebar section and the check-details tab join the standing
  "owed to a human" list in the plan.
