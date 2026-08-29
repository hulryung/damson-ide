# T92 — Opening a pull request: the first thing Orchard writes to GitHub

Date: 2026-08-29 (Asia/Seoul)
Branch: `hulryung/t92-pr-create`, on `6e3ea1f` (the pull-request spine)
Forge tooling: `gh` 2.98.0 (2026-08-20), authenticated as `hulryung`
Verification runtime: headless `orchard serve --data-dir <scratch>` — its own data
dir, never the app's. The Orchard app was not launched, quit, or relaunched.

**GitHub writes: none.** Every `gh` invocation in the code, the tests, the live
verification below, and this report is `repo view`, `pr view`, `pr list`, or
`api …/branches/<ref>`. No pull request was opened. Nothing was pushed. The task
was to build pull-request creation, not to perform one, and the abstention was
easy to hold because the code makes it structural (§5).

**New:** `PullRequestCreationService.swift`, `PullRequestTemplate.swift`,
`PullRequestGateway+Creation.swift`, `PullRequestCommandHandler.swift`,
`CreatePullRequestSheet.swift`, `PullRequestCreationTests.swift`.
**Edited, additively, 143 lines across five shared files:** the `pr` command spec,
its two human formatters, the CLI's subcommand dispatch, one handler registration,
and **12 lines in `SourceControlView.swift`** — one `@State`, one button, one
`.sheet`. Nothing under `Checks/`, `Conflicts/`, `SourceControl/`'s logic,
`Hosts/`, or `Automations/` was touched, and the three spine files are byte-identical
to what landed on `main`.

`swift build` clean; `swift test` **1532 tests, 4 skipped (the four pre-existing
skips), 0 failures**.

---

## A note on the ground this was built on

The spine described in the task — `PullRequestModels`, `PullRequestRefusal`,
`GitHubPRGateway`, `PullRequestGatewayTests` — was not on `main` when this task
started; it was uncommitted in the primary checkout and landed as `6e3ea1f`
partway through the reading pass. It is now the base of this branch, unmodified.
The one thing the spine did not offer is in a separate file, exactly as the task
directed (§6), so the two workers building on it concurrently see no edits from
here.

---

## 1. Eligibility is evidence, and the order of the ladder is the design

The interesting part of `eligibility(worktree:base:)` is not that it returns
reasons. It is the **order**, and two properties of that order are load-bearing.

**Cheap and fundamental first, so the common refusals cost no network.** A folder
that is not a worktree, a machine with no `gh`, and a detached HEAD are all
answered before a single process is launched. `gh_not_installed` in particular is
resolved by `probe.resolvedExecutable()` — a filesystem check — because the one
machine where that answer matters is the machine that cannot run `gh` to find out.
`testGhNotInstalledIsLearnedWithoutLaunchingGh` asserts `probe.invocations` is
empty, not merely that the reason is right.

**A refusal carries what was learned before it.** `.branch_not_pushed` still
carries `head`, `needsPush`, and the repository's template, so the sheet can
prefill a body and offer a Push button while the Create button is disabled. A
refusal that discards its context forces the UI to re-derive it, and re-derivation
is where the two copies drift apart.

The ladder, in the order it runs:

| rung | reason | how it is learned |
|---|---|---|
| remote workspace | `remote_unsupported` | the workspace's stamped host id — **before git runs** |
| not a worktree | `not_a_worktree` | `rev-parse --is-inside-work-tree` |
| no `gh` | `gh_not_installed` | a filesystem check; nothing launched |
| detached HEAD | `detached_head` | `symbolic-ref` returns nothing |
| no remote / not GitHub / not authed | `no_git_remote`, `unsupported_forge`, `gh_not_authenticated` | `gh repo view`, classified by the spine |
| never pushed | `branch_not_pushed` + `needsPush` | no `@{u}` |
| ahead of upstream | `unpushed_commits` + `needsPush` | `rev-list --count @{u}..HEAD` |
| base == head | `base_equals_head` | string comparison — **before any base lookup** |
| named base absent | `base_ref_missing` | `gh api repos/…/branches/<ref>` → 404 |
| no base resolvable | `no_base_ref` | `defaultBranchRef` was null |
| zero commits | `nothing_to_propose` | `rev-list --count <remote>/<base>..HEAD` |
| a PR already open | `pull_request_exists` + `existing` | `gh pr view <head>` |

**One deviation from the task's stated order, deliberate.** The task lists
`not_a_worktree` before `remote_unsupported`; this checks the host first. A remote
workspace's *local* path is either absent or some unrelated directory on this
machine, so running git on it produces a confident answer about the wrong
checkout — and `not_a_worktree`'s remedy ("open a workspace backed by a git
worktree") is actively misleading for a workspace that is one, on another host.
The two rungs are only distinguishable when both apply, and in that case the host
is the truer fact. `testRemoteWorkspaceIsRefusedBeforeGitIsEvenRead` asserts the
git seam was read zero times.

### What the ladder costs

Three `gh` round trips on the fully-eligible path (`repo view`, one
`api …/branches` only when the caller named a base, `pr view`), and four cheap
read-only git verbs. Every git verb used here — `rev-parse`, `symbolic-ref`,
`rev-list`, `for-each-ref` — is in `GitRunner.readOnlyVerbs`, so an eligibility
read invalidates nobody's `GitFactsCache` entry and adds no git cost to a workspace
switch. That constraint is why remotes are enumerated from `refs/remotes` rather
than by `git remote`, which is not a read-only verb and would drop the worktree's
cached facts every time the banner refreshed.

---

## 2. The three-state lookup, and the bug it exists to prevent

> `existingLookup` must distinguish `found`, `notFound` and `unavailable`. A lookup
> that FAILED is `unavailable` and must never be reported as `notFound`.

This is one `switch` and it is the most important nine lines in the feature:

```swift
case .failure(let refusal):
    return refusal.reason == .noPullRequest
        ? (.notFound, nil, .unknown)     // gh answered: there is none
        : (.unavailable, nil, .unknown)  // gh did not answer
case .success(let json):
    guard let detail = PullRequestDecoder.detail(from: json, repository: repository) else {
        return (.unavailable, nil, .unknown)   // we asked and cannot read the reply
    }
    return (.found, detail.ref, detail.state)
```

Exactly one failure — gh's own "no pull requests found" — is an answer. A 401, a
403, a 502, a DNS failure, a timeout, and a zero-exit body we cannot parse are all
`unavailable`. `testAFailedExistingLookupIsUnavailableAndNeverNotFound` runs all
seven shapes through the whole service and asserts the third state every time.

Both directions are tested, because a UI that can *never* say "no pull request" is
as useless as one that says it wrongly:
`testGhSayingThereIsNoPullRequestIsNotFound` pins the other half.

**The distinction survives the whole way out.** The wire publishes
`existingLookup` verbatim; the CLI prints *"existing pull request: could not ask —
this is not the same as none"*; the sheet draws that sentence in orange. A
consumer that collapses the third state into the second has to do it on purpose.

**And it does not block.** The spine's own test asserts that an `unavailable`
lookup leaves `canCreate` true — which is right, because refusing to let anyone
open a pull request whenever GitHub is flaky would be a worse failure than the one
being prevented. The real guard is the second line of defence: GitHub refuses a
duplicate in its own words and `classify` names it `pull_request_exists`.
`testAnUnavailableLookupDoesNotBlockButGitHubStillRefusesADuplicate` runs both
halves end to end.

---

## 3. Base resolution: two refusals to guess

**`main` is never guessed.** The base is the caller's when they named one, the
repository's `defaultBranchRef` when they did not, and `no_base_ref` when GitHub
named neither. The live check below is the proof this matters: `cli/cli`'s default
branch is **`trunk`**, and every hard-coded `"main"` in this space is a pull request
opened against a branch that does not exist.

**A named base that is missing is refused, not replaced.** The task's phrasing
("prefer the caller's base when it exists on the remote; otherwise the repository
default branch") admits a reading where a missing named base silently falls back to
the default. This does not do that. Silently retargeting a base somebody typed is
the same class of act as guessing `main` — it opens a pull request against a
different branch than the one they asked for, and reports success.
`base_ref_missing` exists precisely so that dead end has a name and a remedy;
`testMissingNamedBaseIsRefusedRatherThanReplacedByTheDefaultBranch` asserts
`resolvedBase` stays what they typed and never becomes `main`.

**Existence is asked of GitHub, not of `refs/remotes`.** A base that exists but was
never fetched reads as missing locally, and `refs/remotes/origin/main` can be
months stale. The base is where the pull request lands, so the forge is the only
authority worth asking. This is what needed the one gateway extension: `run()`
collapses every nonzero exit into a classified refusal, which is right everywhere
else and wrong here, because **HTTP 404 is an answer**. `RemoteBranchLookup` has
three cases for the same reason `existingLookup` does — a 401 during a base check
is not evidence that a branch is absent, and
`testUnreadableBaseLookupTakesTheCallerAtTheirWordRatherThanRefusing` pins that
a base whose existence could not be established is *used*, not refused. Not knowing
is not evidence of absence, in either direction.

**A counted zero and an uncountable base are different.** `nothing_to_propose`
fires only on a counted zero. A base that was never fetched leaves `commitsAhead`
nil, refuses nothing, and prints *"commits not counted"* rather than *"0 commits"* —
`testUncountableCommitsAreNotReportedAsNothingToPropose` and its CLI twin.
Telling a user with real work that they have nothing to propose is the worst
possible false negative here.

**Only an *open* pull request blocks.** GitHub itself allows a new pull request on
a branch whose last one was closed or merged; refusing there would leave the user
with no way forward from the UI and no way to know why. The closed one is still
reported — "there was one and it was merged" is worth reading before proposing the
same branch again — but it does not block.

---

## 4. The template is discovered, never invented

`PullRequestTemplate.find(in:)` walks GitHub's own list, in GitHub's own order, so
a repository that renders a template on github.com renders the same one here.
Absence returns nil and is never an error: most repositories have none, and a pull
request opened without one is completely ordinary.

Two details that only show up on somebody else's machine:

- **The reported path is the one on disk.** On a case-insensitive volume
  `.github/PULL_REQUEST_TEMPLATE.md` and `.github/pull_request_template.md` are the
  same file, and `FileManager.fileExists` cheerfully confirms a spelling that is
  not there. Each candidate is resolved against a real directory listing — exact
  case first, case-insensitive as fallback — so the label names a file `git` can
  find.
- **"First `*.md` in the directory" is a name sort.** `contentsOfDirectory` makes
  no ordering promise. A picker that shows a different template on a colleague's
  laptop is a bug that only reproduces on the colleague's laptop.

**What is not generated.** Nothing writes a body when there is no template. An
empty body is the honest prefill for a repository that never asked for one, and a
checklist Orchard invented is prose published under the user's name that nobody
agreed to.

**And the CLI does not splice the template in.** `orchard pr create` sends `--body`
exactly as given; absent means empty. `pr eligibility` *reports* the template so an
agent can read it and pass it deliberately. The sheet prefills because a human is
looking at the text and can edit it before pressing Create — the difference is not
convenience, it is whether anyone read what was published.

---

## 5. Nothing pushes itself

> A tool that pushes without being asked is the failure mode here.

Three structural facts, rather than a comment asking future edits to behave:

1. **`create` does not call the push closure.** It cannot: `PullRequestGitSeam.push`
   is the only writing verb in the seam, it is a separate field, and
   `testCreateNeverPushesEvenWhenEligibilitySaidAPushWasNeeded` builds the exact
   state where a push is obviously wanted (`needsPush == true`), calls `create`, and
   asserts the recorder saw zero pushes.
2. **Discovering that a push is owed performs no push.** Both push-shaped rungs set
   `needsPush` and assert an empty push log.
3. **The affordance is a button.** `pushHead` is its own entry point, its own
   published `isPushing`, and its help text says *"nothing is pushed until you press
   this."* Its refusals are pinned too: detached HEAD, no remote, not a worktree,
   remote workspace — `testPushHeadRefusesWhatItCannotPush` also asserts a refused
   push is not a push.

**No `orchard pr push` verb.** The task asked for two verbs and this adds exactly
two. A CLI push verb would also be the wrong shape: the entire point of the rule is
that a *person* asks, and a person at a terminal already has `git push -u`. What the
CLI owes them is the honest statement that a push is required, which it prints.

`create` also refuses an empty title **before anything is launched** — GitHub will
not take an untitled pull request, and Orchard will not compose one from the branch
name.  `testEmptyTitleIsRefusedBeforeGhIsLaunched` runs three whitespace-only
titles and asserts `probe.invocations` is empty for each. (The sheet *suggests* a
title from the branch name, in a visible field the user can overwrite; that is a
starting point on screen, not a value invented behind them, and the service still
refuses if they clear it.)

One more abstention worth naming: when `gh pr create` exits zero without printing
a pull-request URL, that is `api_error` carrying gh's real output — not a
synthesised ref. Returning a fabricated number would hand the caller a pull request
that may not exist. `testCreateWithoutAUrlIsAnApiErrorNotAFabricatedRef`.

---

## 6. Why the gateway needed one extension and nothing else

The task permits adding to the spine in `PullRequestGateway+Creation.swift` rather
than editing shared files. That file contains two functions and no more:
`outcome(_:cwd:)`, which is deliberately **not public** — exactly one caller is
entitled to see an exit status, and widening it would put a second stderr
vocabulary back in the codebase — and `remoteBranch(_:repository:cwd:)`, which is
the one place a nonzero exit is an answer.

Everything else the creation flow needs is composed from `run`, `json` and
`classify`, so `gh` is still launched from exactly one type. Repository identity
and the existing-PR lookup live in the *service*, because they are creation-flow
policy, not gateway plumbing, and putting them in the shared file is how two
concurrent workers get a merge conflict over code neither of them needs.

---

## 7. The verbs, and why they answer differently

```
orchard pr eligibility [--worktree <selector>] [--base <ref>] [--json]
orchard pr create --title <text> [--body <text>] [--base <ref>] [--draft]
```

`pr eligibility` is a **reading**: "you cannot open one, because the branch is not
pushed" is the answer to the question, not a failure to answer it. It returns
`ok: true` with a typed refusal — the shape `orchard checks` uses, for the same
reason — and the human formatter prints headline, code, gh's own detail and the
remedy in the checks block style.

`pr create` is a **write**: a refusal means no pull request exists, and a script
must see that in the exit status. It returns `ok: false` with the refusal's own
code, and the message carries headline + detail + remedy, so all four parts still
reach stderr. This is the split `checks list` and `checks show` already use; making
`create` an `ok: true` "answer" would make a failed create exit 0, which is the
kind of thing that gets discovered by a CI pipeline that did not notice.

`pr create` runs eligibility first and stops at its refusal. Spending a round trip
to be told the same thing in worse words is pointless — and on the
`branch_not_pushed` path it is the difference between a named refusal and a pull
request proposing commits GitHub cannot see.

---

## 8. The sheet

Source Control footer → **Pull Request…** (12 added lines in that file; everything
else lives in `CreatePullRequestSheet.swift`).

Title, a base picker, a draft toggle, a body prefilled from the template, and the
banner that is the actual point: every refusal drawn as headline + `gh`'s own words
+ remedy + the code chip, with Create disabled *because* of that reason. A disabled
button that cannot say why is the failure `PullRequestCreationEligibility` was
modelled as evidence to prevent, and the Create button's tooltip is the refusal's
headline and remedy for the same reason.

- **The base picker offers remote-tracking branches only**, because a base lives on
  the remote; offering a local-only branch offers one that cannot be selected.
  "Repository default" is a real entry rather than a pre-filled guess.
- **The template is an offer.** It fills an untouched body and never overwrites text
  the user has typed — the body is bound through a setter that records the first
  edit, so a re-check after a push cannot clobber their draft.
- **`unavailable` is drawn differently from `notFound`**, in orange, with the
  sentence spelled out.
- Wave 25's rules hold: no subprocess in a view body (every call is in `.task` or a
  button action), and nothing on the main thread (the service runs `gh` and `git` on
  detached utility tasks).

---

## 9. Live verification

Against real `gh` 2.98.0 and a headless runtime with its own data dir. Scratch
repositories, plus one whose `origin` is `cli/cli` (no clone — a remote added and
two shallow fetches).

```
$ orchard pr eligibility --worktree noremote
No git remote [no_git_remote]  main
  no git remotes found
  Add a remote (git remote add origin …), then push the branch.
  existing pull request: could not ask — this is not the same as none

$ orchard pr eligibility --worktree gitlab
Remote is not GitHub [unsupported_forge]  main
  none of the git remotes configured for this repository point to a known GitHub
  host. To tell gh about a new GitHub host, please use `gh auth login`
  Pull requests are opened on GitHub only. Nothing is attempted elsewhere.

$ orchard pr eligibility --worktree detached
Detached HEAD [detached_head]  (no branch)
  HEAD is detached at 4182145a.
  Check out a branch, then try again.

$ orchard pr eligibility --worktree livegh          # local branch, never pushed
Branch not pushed [branch_not_pushed]  topic
  topic has no upstream branch, so GitHub cannot see it yet.
  Push the branch first — Orchard will offer to.
  push required — nothing has been pushed for you
```

The base rungs, on a branch tracking `origin/trunk` — note that **no base was named
and the answer is `trunk`, not `main`**:

```
$ orchard pr eligibility --worktree livegh
Nothing to propose [nothing_to_propose]  synced → trunk
  synced has no commits that trunk does not already have.
  Commit something the base does not already have.
  a pull-request template was found and is offered as the body

$ orchard pr eligibility --worktree livegh --base no-such-branch-xyz
Base branch not on the remote [base_ref_missing]  synced → no-such-branch-xyz
  cli/cli has no branch named no-such-branch-xyz.
  Push the base branch, or pick one that exists on the remote.
```

That `base_ref_missing` is a real HTTP 404 from GitHub's API, and the base stayed
`no-such-branch-xyz` rather than being quietly retargeted to `trunk`.

The existing-PR path, on the head branch of a real open pull request:

```
$ orchard pr eligibility --worktree livegh --base trunk
Pull request already open [pull_request_exists]  williammartin-audit-spam-labeling → trunk
  #14285 is already open for williammartin-audit-spam-labeling: https://github.com/cli/cli/pull/14285
  Open the existing pull request instead.
  existing pull request #14285 https://github.com/cli/cli/pull/14285
  a pull-request template was found and is offered as the body
```

And the write verb refusing, with the exit status a script needs:

```
$ orchard pr create --worktree noremote --title "never happens" ; echo $?
orchard: no_git_remote: No git remote. no git remotes found Add a remote
  (git remote add origin …), then push the branch.
1

$ orchard pr create --worktree livegh ; echo $?
orchard: empty_title: pr create requires --title. Give the pull request a title.
1

$ orchard pr create --worktree livegh --base trunk --title "would be a duplicate"
orchard: pull_request_exists: Pull request already open. #14285 is already open
  for williammartin-audit-spam-labeling: … Open the existing pull request instead.
```

Every one of those `pr create` calls stopped at the eligibility gate. `gh pr create`
was never launched, in verification or anywhere else.

A live-`gh` verification of the *successful* create path is the one thing this
report cannot show, because showing it means opening a pull request, which the task
forbids. The path is covered by unit tests — argv construction with and without
`--draft`, URL parsing out of gh's real multi-line output, gh's refusals mapping to
their own names, and the missing-URL case — and the argv is a single `gh pr create`
whose flags are asserted.

---

## 10. Tests

| suite | n | what it holds |
|---|---|---|
| `PullRequestCreationTests` | 44 | every rung in order; what was *not* launched at each; found/notFound/unavailable across seven failure shapes; template order, case, sort determinism and absence; empty title before launch; the no-silent-push rule from three directions; URL parsing; the 404-vs-couldNotTell split; the published CLI surface and its two formatters |
| `PullRequestGatewayTests` | 17 | inherited from the spine, unmodified, still green |

Whole suite: **1532 tests, 4 skipped, 0 failures.** The four skips are the
pre-existing ones.

The tests lean on *abstention* assertions —
`XCTAssertTrue(probe.invocations.isEmpty)`, `XCTAssertTrue(git.pushes.isEmpty)`,
`XCTAssertEqual(git.factsReads, 0)` — because "it returned the right reason" stays
true through an edit that adds a network call or a push, and "it launched nothing"
does not.

---

## 11. Not done, and why

- **No forge but GitHub.** `unsupported_forge` is the honest answer, not a
  placeholder. Nothing about a GitLab remote is inferred.
- **No `orchard pr push`.** §5. The rule is that a person asks; a person at a
  terminal already has `git push -u`, and the CLI's job is to say plainly that a
  push is required.
- **No automatic template body from the CLI.** §4. A body the caller has not read
  is not published under their name.
- **No pull request opened from a remote workspace.** Typed `remote_unsupported`.
  Answering would use this machine's git and this machine's `gh` about a checkout on
  another host.
- **No eligibility cache.** Deliberate, and the opposite of T88's choice: a checks
  reading is polled by a panel that may sit open for an hour, whereas eligibility is
  read when a sheet opens and after a push. Caching it would mean a banner that says
  "branch not pushed" after the branch was pushed, which is exactly the class of lie
  T88's cache rules were written to prevent — and there is no polling loop here to
  make a cache worth the risk.
- **A human has not driven the sheet.** It is unit- and CLI-verified end to end, and
  the app was deliberately not launched (the task forbids it). `CreatePullRequestSheet`
  joins the standing "owed to a human" list in the plan. The one thing a human pass
  should look at first is the `needsPush` → Push → re-check loop, which is the only
  place in this feature where the UI's state advances because something was written.
- **A live successful `gh pr create`.** §9. Verifying it means doing it.
