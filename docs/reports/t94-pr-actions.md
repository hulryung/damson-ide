# T94 — acting on a pull request: review, threads, merge, state

**Built on:** the pull-request spine landed as `6e3ea1f` — `PullRequestModels.swift`,
`PullRequestRefusal.swift`, `GitHubPRGateway.swift`. None of those three files was
edited; everything T94 needed from the gateway went into a new
`PullRequestGateway+Actions.swift`, as instructed, because T92 and T93 are in the
same wave.

**Added:**
`Sources/OrchardRuntime/PullRequests/ReviewSubmission.swift`,
`PullRequestActionService.swift`, `PullRequestGateway+Actions.swift`,
`PullRequestActionCommandHandler.swift`;
`Sources/OrchardApp/PullRequests/ReviewComposer.swift`, `MergeSheet.swift`;
`Tests/OrchardRuntimeTests/PullRequestActionTests.swift`.

**Touched, minimally, because a CLI verb has nowhere else to live:**
`RuntimeAssembly.swift` (six lines: one `registry.register`),
`CommandSpec.swift` (one `CommandSpec` for `pr`),
`orchard/main.swift` (verb routing + one formatter case),
`CLIFormatting.swift` (one function, appended).

**Not touched:** `Checks/`, `Conflicts/`, `SourceControl/`, `Hosts/`,
`Automations/`, `PullRequestPane` (T93), and the three spine files.

`swift build` clean. `swift test` green across the whole suite; the 55 tests this
task adds are in `PullRequestActionTests.swift`.

---

## The argument this task is really about

Every verb here writes to a server somebody else owns. The failure mode is not a
crash, it is a *quiet success*: a merge that happened because a key was pressed
while the wrong window had focus, or because a `Bool` defaulted to `true`
somewhere three call sites away. An accidental commit is a `git reset`. An
accidental merge is a notification in a dozen inboxes, a branch that may no
longer exist, and a base branch that now contains code nobody agreed to.

Orchard is driven by agents, which makes this worse in a specific way: an agent
does not hesitate. Whatever the API makes easy, it will do at machine speed. So
the defence cannot be a warning label. It has to be the shape of the API.

### Confirmation is a token, not a boolean

The obvious design is `merge(method:deleteBranch:confirmed: Bool)`. It is wrong
for three reasons, and the third is the one that decided it:

1. **A `Bool` has a default.** The moment a default exists, `confirmed` is one
   careless `= true` away from a hover that merges. There is no default that is
   safe here, and Swift will happily let a caller supply one.
2. **A `Bool` carries no content.** It says somebody agreed; it cannot say what
   they agreed *to*. A user who ticked "delete the branch", changed their mind,
   and pressed a button rendered before the change has still passed
   `confirmed: true`.
3. **A `Bool` cannot go stale.** Between reading a pull request and merging it,
   somebody can push, somebody else can merge, the method picker can move. A
   boolean agreed to none of that.

So a destructive verb takes an `ActionConfirmation` token, and the token is a
readable digest of the operative facts:

```
action=merge;repo=hulryung/damson-ide;number=42;method=squash;
deleteBranch=no;head=abc1234;state=OPEN;worktree=/path/to/checkout
```

The only way to obtain one is `mergePlan(...)`, which reads the pull request.
That is what makes "read before you merge" structural rather than a convention
somebody can forget — there is no argument you can synthesise for `merge` without
having done the read, because the head commit and the state are in it.

`MergePlan.sentence` and `MergePlan.confirmation.token` are computed from the
same stored properties, so the sentence on screen and the token the button spends
cannot describe different merges. Flip the method and both change together;
`testATokenIsSpecificToTheMergeItNames` pins method, delete-branch, head commit
and worktree as four independent invalidators.

**What this is not.** It is not a security boundary. Anything inside the process
can spell a token out by hand. It defends against staleness and accident, which
are the two ways an IDE actually merges the wrong thing, and I would rather say
that plainly than let the word "token" imply more than it does.

### The sentence names three facts

> Merge hulryung/damson-ide#42 "Act on a pull request" into main by squashing
> every commit into one. The branch topic will be kept.

Which pull request — by number *and* title, because a number alone is not
something anyone recognises under time pressure. Which method, as a verb phrase
rather than a button label, because "Squash and merge" is a control and
"squashing every commit into one" is a consequence. And the branch's fate,
stated in both directions — "will be kept" is written out rather than left as the
absence of "will be deleted", so silence never has to be interpreted.

### `unknown` mergeability is a third thing

GitHub computes mergeability asynchronously. Ask too soon and it says `UNKNOWN`.
There were two tempting readings and both are wrong:

* **Treat it as mergeable** — merges on a guess.
* **Treat it as a refusal** — teaches users that the refusal is noise, and the
  next thing they learn is how to get past it.

So it is neither. `PullRequestActionResult` has four cases, and
`.mergeabilityUnknown` is its own: nothing was launched, the sheet's merge button
is off, the CLI exits non-zero with code `mergeability_unknown`, and the remedy
is "ask again in a moment". `testUnknownMergeabilityIsNeitherMergeableNorARefusal`
asserts all three halves — plan readiness, result case, and an empty
`probe.invocations` for `pr merge`.

One ordering decision falls out of this: in `MergePlan.make`, certain refusals
are decided **before** the pending state. A merged pull request whose mergeability
is still `UNKNOWN` refuses with `pull_request_not_open`, not "still computing".
A spinner in front of a locked door is worse than the locked door.

### `deleteBranch` defaults to false in four places

The service signature, `MergePlan.init`, the CLI flag, and the sheet's `@State`.
All four default off, and `testDeleteBranchIsOffUnlessAskedForAndOnlyThenReachesGh`
asserts the only one that matters — the argv. `--delete-branch` is absent unless
somebody ticked a box.

One honest complication: a repository can be configured to delete head branches
on merge regardless of what we send. We read that setting and *warn* — "this
repository deletes head branches on merge, so `topic` may be deleted even though
the box is unticked" — because the alternative is a sheet that promises to keep a
branch GitHub is about to delete. We never flip our own tick because of their
setting.

---

## What I deliberately did not automate

**Self-review is not pre-empted.** GitHub refuses to let you approve your own
pull request. We could check the viewer's login first and grey the button out.
I didn't: it costs another round trip, it is wrong for the machine-account cases,
and a wrong guess blocks a legitimate review with no way past. The gateway's
`classify` already maps GitHub's own wording to `.cannotReviewOwnPullRequest`, so
the refusal arrives with a headline and a remedy.
`testSelfReviewRefusalReachesTheUserIntact` also asserts gh's own sentence
survives in `detail` — the friendly headline must not cost the real message.

**Nothing retries itself.** `PullRequestRefusalReason.isTransient` exists and is
never consulted by this code. A retry affordance is the user's; a write that
retries itself is a write that can happen twice.

**A timed-out write is not reported as "nothing happened".** It is the one
outcome we genuinely cannot report on — `gh` may have posted before the deadline.
The refusal says so: *"It may or may not have gone through — reload before
retrying."* Pinned by `testATimedOutWriteSaysItMayHaveLanded`.

**`close` does not offer to delete the branch**, though `gh pr close` supports it.
Closing is already the destructive half; deleting the branch too is a second
decision, and bundling two irreversible acts behind one button is how the second
one gets made by accident.

**`merge` does not re-read before it fires.** The plan already pins state and head
commit in the token, and GitHub is the final authority anyway — it refuses a
stale merge itself, and that refusal is classified. A second read would narrow
the window without closing it, at the cost of a round trip between the click and
the act.

**A GraphQL 200 with an `errors` array is a failure.** `gh api graphql` exits 0
when a mutation fails. Trusting the exit code is how a resolve that silently did
nothing gets reported as done, so `runWrite` parses the body.
`testAGraphQLErrorInsideATwoHundredIsStillAFailure` pins it.

---

## Refusals: one vocabulary, refined not replaced

The spine's `GitHubPRGateway.classify` handles the wording that reads and writes
share. Three refusals only a write can provoke — `lineNotInDiff`,
`threadNotFound`, and the merge-time flavours of `mergeMethodUnavailable` /
`pullRequestNotOpen` — needed more.

The rule I held to: `PullRequestActionClassifier` runs **after** the spine's
classifier and only ever refines `.apiError`, which is the spine's honest "I have
not seen this wording". It can never overwrite a reason the spine already named.
If it could, there would be two vocabularies for one fact, and the whole point of
`PullRequestRefusalReason` is that there is one.
`testTheRefinementPassOnlyEverRefinesApiError` asserts this across every action
context.

The refinement also takes the verb as context, because GitHub reuses sentences:
`HTTP 404` from a thread mutation means `thread_not_found`; the same 404 from
`gh pr merge` means `insufficient_permission`, since GitHub hides what you may
not touch rather than admitting it exists.

**The gate that fires before anything launches.** `ReviewSubmission.refusal` and
`ReviewCommentAnchor.refusal` are pure computed properties. The service consults
them before it so much as resolves the `gh` binary, and `ReviewComposer` consults
*the same properties* to decide whether its button is enabled and what the
disabled reason says. One rule, one place, two callers — what the button says and
what the runtime would do cannot drift. Every test in this group asserts
`probe.invocations.isEmpty`, not merely that a refusal came back.

---

## UI

### `ReviewComposer`

Radio rows rather than a segmented control, because each verdict carries a
consequence and "Blocks the pull request until you or another reviewer clears it"
does not fit in a segment. The `body required` pill sits on the two verdicts that
need one, so the constraint is visible before it bites.

The disabled Submit says why, under the button, in the refusal's own words. A
grey button that is silent is exactly the dead-end-without-a-remedy that
`PullRequestRefusalReason` was written to prevent.

**Keyboard:** ⌘Return submits. Plain Return does not — it belongs to the body
field, because a review body is prose and prose has paragraphs. There is no
`.defaultAction` button in the sheet.

### `MergeSheet`

The sheet *is* the second step. Opening it takes one reading (`mergeContext()` —
`gh pr view` plus `gh repo view`); every subsequent radio button and tick derives
a new plan from that reading with **no network at all**, via the pure
`MergePlan.make`. That is not an optimisation — it is what lets the sentence stay
true as the user tries methods. A sheet that spent two round trips per radio
button would end up either caching a stale readiness or showing a spinner on a
toggle, and both of those are how a merge button ends up enabled against a state
nobody re-read.

The method picker offers only what the repository allows. When the settings read
does not land, `RepositoryMergePolicy.isAuthoritative` is false, all three methods
are offered, and a warning says we could not tell. Hiding a button that works and
offering one that does not are the same bug; the only honest third option is to
say so.

**Keyboard: the Merge button has no shortcut at all.** Not `.defaultAction`, not
⌘Return. Escape cancels. The single gesture that merges is a click on a button
sitting directly under a sentence naming what it will do.

### How I expect these to be wired into `PullRequestPane` (T93)

I did not touch that file. Both views are plain `struct`s with no environment
dependencies beyond `@Environment(\.dismiss)`, so they present from anywhere:

```swift
// In PullRequestPane, alongside its existing state:
@State private var showingReview = false
@State private var showingMerge = false

private var actions: PullRequestActionService {
    PullRequestActionService(worktree: URL(fileURLWithPath: workspace.path),
                             branch: branch)
}

.sheet(isPresented: $showingReview) {
    ReviewComposer(service: actions, ref: detail.ref, title: detail.title) { _ in
        Task { await reload() }          // the receipt is handed back; reload the pane
    }
}
.sheet(isPresented: $showingMerge) {
    MergeSheet(service: actions) { _ in
        Task { await reload() }
    }
}
```

Three things to know when wiring it:

* `PullRequestActionService` is a `Sendable` struct — construct it per worktree,
  hold it in a view, or build it on demand. It caches nothing.
* `ReviewComposer` needs `ref` and `title` passed in. The pane already has both;
  a second `gh pr view` to draw a header is a round trip for decoration.
* Both call `onCompleted` with a `PullRequestActionReceipt` and then dismiss
  themselves. The pane's job is to reload — the receipt names what changed.
* Both use `ChecksNotice` from `Checks/ChecksSidebar.swift` for refusals, so a
  refusal here looks exactly like a refusal in the checks sidebar. Reused, not
  copied, and that file was not edited.

---

## CLI

```
orchard pr review|comment|reply|resolve|unresolve|merge|ready|close|reopen
```

The task named seven verbs; `reply` and `unresolve` are here too, because the
service has them and the CLI is the only headless surface — a thread you can
resolve but not reopen is a one-way door for an agent.

**The envelope convention is the opposite of `checks`, deliberately.** A checks
reading that could not be taken is an *answer*: `ok: true`, `status:
"unavailable"`, a typed reason. A merge that did not happen is not an answer, it
is a merge that did not happen. So **only a verb that landed exits 0.** A script
that runs `orchard pr merge` and reads exit 0 is entitled to believe the branch
is in.

**`--yes` for merge and close.** Without it, the pull request is still read, the
plan is still built, and the sentence is printed — then exit 1 with code
`confirmation_required`. The dry run is not a preview mode bolted on; it is the
same plan the `--yes` path spends, so what it prints is exactly what would
happen. `--json` callers get the whole plan in `error.data`, including
`readiness`, `availableMethods` and the warnings.

```
$ orchard pr merge --method squash
orchard: confirmation_required: Merge hulryung/damson-ide#42 "Act on a pull
request" into main by squashing every commit into one. The branch topic will be kept.
  ! This repository deletes head branches on merge, so topic may be deleted even
    though the box is unticked.
  Nothing was sent. Re-run with --yes to do it.
$ echo $?
1
```

The dry run also reports the readiness it just read, so a merge that *would* be
refused says so before anyone types `--yes` rather than after.

**Why review submission is not `--yes`-gated.** It is a mutation, and it is not
destructive: a review can be superseded by another review, a resolved thread can
be unresolved, a draft can be marked ready. `PullRequestActionKind.isDestructive`
is true for exactly `merge` and `close`, and
`testOnlyMergeAndCloseAreTreatedAsDestructive` pins the list so widening it is a
deliberate edit rather than a drift. Gating everything behind `--yes` would make
the flag mean "I typed a verb" instead of "I accept something irreversible", and
a confirmation that fires on everything is a confirmation nobody reads.

---

## Testing

55 tests, all through `FixtureGitHubCLI`. No live `gh` mutation was run at any
point, in tests or by hand — the probe is a dictionary with an invocation log,
and it cannot reach a network.

That log carries most of the weight. For a precondition the interesting claim is
never "it refused" but **"it refused having launched nothing"**, and only
`probe.invocations` can settle that:

| Claim | Test |
| --- | --- |
| Empty body refuses before `gh` is resolved | `testEmptyBodyIsRefusedBeforeGhIsLaunched` |
| Local anchor mistakes refuse before launch | `testLocalAnchorMistakesAreRefusedBeforeGhIsLaunched` |
| `unknown` is not mergeable and not a refusal | `testUnknownMergeabilityIsNeitherMergeableNorARefusal` |
| A certain refusal outranks a pending one | `testACertainRefusalOutranksAPendingMergeability` |
| `--delete-branch` reaches gh only when ticked | `testDeleteBranchIsOffUnlessAskedForAndOnlyThenReachesGh` |
| An unconfirmed merge launches nothing | `testMergeWithoutTheTokenLaunchesNothingAndHandsBackTheSentence` |
| The token invalidates on method, branch, commit, worktree | `testATokenIsSpecificToTheMergeItNames` |
| `--yes` is required, and the dry run exits non-zero | `testMergeWithoutYesPrintsWhatItWouldDoAndFails` |
| A 422 off the diff becomes `line_not_in_diff` | `testAnAnchorOffTheDiffBecomesLineNotInDiff` |
| A GraphQL 200 with errors is a failure | `testAGraphQLErrorInsideATwoHundredIsStillAFailure` |
| The refinement pass never overwrites a named reason | `testTheRefinementPassOnlyEverRefinesApiError` |

Every refusal reason this task can produce is covered:
`empty_review_body`, `cannot_review_own_pull_request`, `pull_request_not_open`,
`not_mergeable`, `merge_method_unavailable`, `insufficient_permission`,
`thread_not_found`, `line_not_in_diff`, `no_pull_request`, `gh_not_installed`,
`gh_timed_out`, `api_error`.

---

## Two deviations worth flagging at merge

**1. `PullRequestActionService` holds its worktree.** The task sketched
`submitReview(worktree:verdict:body:)` and `merge(worktree:method:deleteBranch:)`
with a worktree, and `reply(toThread:body:)`, `resolve(thread:)`, `close()`,
`reopen()`, `setDraft(_:)` without one. Three of eight named it; five did not.
I made it constructor state so all eight agree — and there turned out to be a
real reason beyond consistency: the worktree is a fact in the confirmation token,
so a plan built in one checkout cannot be spent in another. A stateless service
would take the worktree twice, once to build the plan and once to act, and the
two could disagree. The verb spellings are otherwise exactly as specified.

**2. Four shared files have small additive edits.** Registering a handler and
adding a CLI verb have nowhere else to live. Each edit is one contiguous block
placed next to the `checks` equivalent, so if T92 and T93 append theirs in the
same places the conflicts are adjacent-line and mechanical:
`RuntimeAssembly.swift` (one `register` call), `CommandSpec.swift` (one
`CommandSpec`), `orchard/main.swift` (one routing block, one formatter case),
`CLIFormatting.swift` (one function at the end of `OrchardHumanFormatter`).
