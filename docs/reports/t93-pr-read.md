# T93 — Reading a pull request: conversation, reviews, line-anchored threads

**Built on:** the spine landed at `6e3ea1f` — `PullRequestModels.swift`,
`PullRequestRefusal.swift`, `GitHubPRGateway.swift` and the contract in
`PullRequestGatewayTests.swift`. None of those four files is touched.

**Added:**
`Sources/OrchardRuntime/PullRequests/PullRequestReadService.swift`,
`Sources/OrchardRuntime/PullRequests/ReviewThreadQuery.swift`,
`Sources/OrchardApp/PullRequests/PullRequestModel.swift`,
`Sources/OrchardApp/PullRequests/PullRequestPane.swift`,
`Tests/OrchardRuntimeTests/PullRequestReadTests.swift`.

**Edited, minimally:** `WorkspaceModels.swift` (+7), `WorkbenchView.swift` (+2),
`AppStore.swift` (+4), `RootView.swift` (+1). Nothing under `Checks/`,
`Conflicts/`, `SourceControl/`, `Hosts/` or `Automations/`.

`swift build` clean; `swift test` 1529 tests, 4 skipped, 0 failures — 41 of them
new here.

**Live reference:** `gh` 2.98.0 against `cli/cli`, read-only, 2026-08-29. Three
of this task's decisions come from what that data actually looked like rather
than from what the API documentation implies, and they are the three sections
below marked **found live**.

---

## The shape of a read

Two round trips, and the split is forced rather than chosen.

```
gh pr view --json <22 fields>     → header + conversation + files   (1 process)
gh api graphql  reviewThreads     → line-anchored threads          (1+ processes)
```

`gh pr view --json` genuinely cannot answer the second half. Verified, not
assumed: `--json comments` returns issue comments (`IC_…` ids, no `path`, no
`line`), and `--json reviews` returns review *bodies* with a state. Neither
carries a single line anchor. The threads only exist behind GraphQL's
`reviewThreads` connection.

What is a choice is that the first trip is *one* trip. `detail(worktree:)` asks
for `PullRequestDecoder.viewFields`; `read(worktree:)` asks for that same list
plus `comments,reviews,latestReviews,files` and decodes all four sections out of
the one payload. The decoder ignores keys it was not built for, so the superset
costs nothing and saves three subprocesses.

The repository (`owner/name`, needed for the GraphQL variables) is read off the
`url` field `gh` already returned, rather than spent as a second `gh repo view`.
That is the whole reason the common path stays at one process. A pull request
that comes back with no usable URL is refused as `api_error` with an explicit
message, because the alternative — synthesising `https://github.com//pull/42` —
is a URL that is wrong rather than absent.

---

## Staleness: there is no cache, and nowhere to put one

T87's rule is that a value nobody is watching can quietly become a lie. Nothing
watches GitHub. A review lands, a thread resolves, someone force-pushes, and no
local event fires — there is no watcher to be had, so by T87's own rule there is
no cache.

This is enforced structurally, not by discipline: `PullRequestReadService` is a
`struct` with no `var` state. A cache is not merely absent from it, it is
unrepresentable. `PullRequestModel` holds the last reading it was handed, which
is a different thing and is labelled as one — every reading carries `observedAt`,
the pane's footer renders `read 12s ago` against a once-a-second tick, and it
says in as many words that *nothing here is cached*.

T88 could afford a 45-second TTL because CI state is cheap to be slightly wrong
about. A review verdict is not. The asymmetry is the argument.

"Do not cache across a head SHA change" is therefore satisfied vacuously, and the
head the reading describes is on screen (`head abc1234 · branch`) so a reader can
see for themselves which commit was being talked about.

---

## Pagination, and never being short in silence

`reviewThreads(first: 100)` is one page. The task's rule — 101 threads must not
show as 100 — is met by asking GitHub for `totalCount` alongside the nodes, so a
shortfall is arithmetic rather than a guess:

```swift
missingThreads = max(0, totalCount - threads.count)
```

The loop follows `pageInfo.endCursor` until `hasNextPage` is false or a budget of
20 pages (2 000 threads) runs out. Hitting the budget bounds the *cost*, never the
honesty: the pane then renders "100 of 101 review threads are not shown" with a
remedy pointing at GitHub. `shortfallSummary` returns `nil` when nothing is
missing, so the incomplete case can never be communicated by an absence.

The same discipline one level down: `comments(first: 50)` inside each thread also
returns `totalCount`, and a thread with more replies than that records the
remainder per thread rather than ending on a reply that looks like the last word.

Two failure modes get deliberate, asymmetric treatment:

- **Page one fails** → the whole thread read fails, and the pane shows the named
  refusal beside a header and file list that are still real.
- **Page five fails** → the four pages already in hand are kept, and the
  difference from `totalCount` is reported as a shortfall. Throwing away real
  threads to report a clean error would lose more than it explains.

And a GraphQL `errors` array is a refusal even when data arrives beside it. `gh`
exits non-zero there (checked: exit 1, body on stdout, message on stderr) so the
gateway already classifies it — the explicit check in `decodePage` is belt and
braces against the failure that would hurt most, an error decoding to zero
threads and rendering as "no review threads on this pull request".

---

## Found live #1: an outdated thread has no line

The task's specified query asks for `line` and `startLine`. Against real data,
every outdated thread comes back like this:

```json
{"isOutdated": true, "isResolved": true, "path": ".github/workflows/lint.yml",
 "line": null, "startLine": null, "originalLine": 47, "diffSide": "RIGHT"}
```

`line` is null precisely *because* the thread is outdated — the line it pointed
at is not in the head any more. The anchor it was written against survives only
in `originalLine`, which the specified query does not request.

So the query asks for `originalLine` and `originalStartLine` too, and the decoder
falls back to them. Without that, an outdated thread renders with no line number
at all: shown, but not really — which fails the rule it was meant to satisfy.

The number is then phrased in the past tense. `ReviewThread.anchorDescription`
returns `"was line 47"` for an outdated thread and `"line 12"` for a current one.
Rendering "line 47" for a line that no longer exists is the quiet kind of lie
this codebase keeps refusing to tell; the same number told truthfully costs one
word.

The wording lives in the runtime rather than in the view for one reason: there is
no `OrchardApp` test target, and this is the sort of sentence that must not
regress unnoticed. It is tested.

Outdated threads are grouped, sorted and drawn exactly like current ones and
carry an `Outdated` badge. There is no parameter anywhere in this feature that
would let a caller filter them out.

---

## Found live #2: `latestReviews` has no ids

`gh pr view --json reviews,latestReviews` returns both lists — and every
`latestReviews` entry comes back with `"id": ""` and `"commit": {"oid": ""}`.
Deduplicating the two lists by identity is therefore impossible.

So they are not deduplicated. `reviews` is the complete history and the only
source of conversation entries. `latestReviews` is used *only* to mark which of
those entries still stands, matched on `(login, submittedAt)` — the pair GitHub
does send, and which is unique per reviewer.

That distinction earns its keep. On the live pull request read for this task:

```
babakks  CHANGES_REQUESTED  21:16  → superseded
babakks  APPROVED           22:11  → current   (empty body)
```

Without the mark, a resolved objection sits in the timeline looking exactly like
an open one.

## Found live #3: `--json files` truncates at 100

The same live pull request reported `changedFiles: 252` and returned exactly 100
entries in `files`. `gh` asks for one page and says nothing about the rest.

`PullRequestReading.missingFiles` is `changedFiles - files.count`, and the pane
renders "152 more files are changed but were not listed by gh." Paginating the
file list would be a third API and a much longer read for a list nobody scrolls
to the end of; stating the shortfall costs one line and is honest. That is the
trade, made deliberately.

---

## The conversation

Timeline comments and submitted review bodies merge into one chronological list.
A review's body and its verdict travel together on the same
`PullRequestComment.reviewVerdict`, as specified.

Three rules about not reporting things that were not said:

**`PENDING` reviews are excluded.** A pending review is a draft only its author
can see. It has not been submitted, so it is not part of the conversation.

**Empty-bodied `COMMENTED` reviews are excluded.** That is the wrapper GitHub
creates when somebody leaves only line comments; its content *is* the review
threads, which have their own section. Rendering the wrapper too would put an
empty bubble in the timeline.

**Empty-bodied approvals are kept.** There the verdict is the whole message —
which is exactly the `babakks APPROVED` entry above.

`DISMISSED` is the interesting one. `ReviewVerdict` is a closed three-case
vocabulary because it is the *write* vocabulary — it maps to `gh pr review`'s
flags — and there is no flag for dismissal. Mapping a dismissed review onto
`.comment` would report a withdrawn approval as an ordinary remark. So
`ConversationEntry.origin` carries GitHub's own word verbatim
(`.review(state: "DISMISSED")`), `reviewVerdict` stays nil, and the pane says
"review dismissed". The closed vocabulary keeps its meaning and the wider one
survives beside it.

Reviews are visually distinct from plain comments by three signals at once: a
verdict glyph, a tinted 2pt leading edge in the verdict's colour, and the verdict
in words. A plain comment gets none of them.

---

## Markdown: what is rendered, and what is not

**The choice: a block splitter in the runtime, Foundation's parser for inline
spans.** No dependency, and neither half reimplements the other.

Foundation already ships `AttributedString(markdown:)`, which does bold, italic,
links and inline code correctly. What it will not do is block structure — it
flattens a fenced code block into a paragraph. For a code review that is the one
thing that must not happen. So `PullRequestMarkdown.blocks` decides block
structure (headings, fences, lists, quotes, tables, rules) and
`.inlineOnlyPreservingWhitespace` handles the spans inside each block.

"Monospace plain text throughout" was the honest fallback on offer and it is
worse than this. A PR description is mostly prose with code *in* it; setting the
prose in a monospaced font to protect the code punishes the common case to
rescue the rare one, when splitting the two costs about 120 lines of pure,
tested function.

Deliberate choices inside the splitter:

- **Newlines inside a paragraph are preserved.** GitHub renders a single newline
  in a comment as a line break. Re-wrapping would mangle every pasted stack trace
  and diff, which is most of what people paste into review comments.
- **An unterminated fence still closes at end of input.** Dropping the rest of a
  comment because somebody forgot three backticks loses more than it protects.
- **Ordered lists keep the author's own numbering** rather than being renumbered.
- **Task lists become `☐`/`☑`.** A PR description's checklist is usually the
  point of it.
- **HTML comments are stripped** — see below. **All other HTML is left
  verbatim.**

### What is deliberately NOT rendered

**Images.** `![alt](url)` renders as its link, not as a picture. Fetching remote
images would mean unbounded network requests issued from a view body, for
arbitrary URLs, per comment — three things this codebase forbids separately. The
alt text and the link are the honest subset.

**Tables as tables.** A GFM table is detected as a run (header, delimiter row,
body) and rendered *monospaced and horizontally scrollable*, so the author's own
pipe alignment lines the columns up. It is not laid out as a real grid. This is
the one place I chose a deliberate half-measure, and the reason is that the
alternative half-measure is much worse: a table left as prose in a proportional
font with newlines preserved is visibly broken, which is precisely the outcome
the brief said to avoid. Monospaced-verbatim is a legible answer that does not
pretend to be a grid. A real grid needs column-width measurement and is a task,
not a detail.

**HTML.** `<details>`, `<img>`, `<sub>` and friends are shown as literal text.
Rendering them needs an HTML parser; *stripping* the tags would silently delete
whatever they wrap. Showing the markup is ugly and honest, and it is visibly
ugly, which is the kind of wrong that gets fixed.

**The one exception, found live: HTML comments are hidden.** GitHub's own pull
request template is mostly `<!-- … -->`, and every markdown renderer — GitHub's
included — hides them. Rendering them put three paragraphs of template
instructions ("Thank you for contributing to GitHub CLI!") into a body the author
never wrote and nobody can see on GitHub. Stripping them took the live body from
43 blocks to 23, and the 23 are what GitHub shows. A comment is unambiguously not
content, which is why it gets treated differently from a `<details>` block that
is. Comments inside fenced code survive, because there they are an example.

**Syntax highlighting inside code fences.** The fence's language is shown as a
label; the code is not coloured. `IncrementalHighlighter` exists in this repo but
is wired to the editor's document model, and reaching into it from a comment
renderer is a bigger coupling than a review pane earns.

**Emoji shortcodes, `@mentions`, `#123` cross-references, footnotes, autolinked
issue references.** All shown as written. Each needs a GitHub-side lookup table
to do properly, and each is perfectly readable as its literal text.

---

## Surfaces

`PullRequestPane` is a workbench tab. `TabKind` gained a `.pullRequest` case in
seven lines, and because the `+` menu already iterates `TabKind.allCases`, the tab
became openable with no further wiring in `WorkbenchView` beyond the two-line
`tabBody` case.

The pane is four sections in the order a reviewer needs them:

1. **Header** — number, title, state badge, draft badge, `base ← head`, review
   decision, mergeability, `+120 −8`, file count. GitHub's raw `mergeStateStatus`
   is in the tooltip, beside our collapsed word, so the collapse is never the only
   record.
2. **Conversation** — the description as the opening post, then every comment and
   review body, oldest first.
3. **Review threads** — grouped by file, each with its anchor, a `Resolved` badge
   and an `Outdated` badge, and any per-thread reply shortfall.
4. **Files** — path and per-file diffstat, with the `missingFiles` line when `gh`
   came back short.

Every unavailable path renders the refusal's headline, `gh`'s own words, and a
remedy. That notice is literally T88's `ChecksNotice`, reused rather than
re-drawn, so the two features cannot drift into two dialects of the same apology.
There is no branch in the pane that produces a blank panel, and the only spinner
resolves on the same await that started it.

`mergeable: UNKNOWN` renders as "Mergeability unknown", never as mergeable — it
is GitHub still computing the merge commit, which is a real state and not a gap
in our reading.

The model owns no runtime service. `PullRequestReadService` is a stateless struct
over the `gh` probe, so it needs nothing from `RuntimeAssembly` — which also means
this feature added no line to a file T92 and T94 are both editing.

---

## Tests

41 new, all fixture-driven, no network and no `gh` binary. Covering, as required:
pagination across two pages; an outdated thread surviving into the model with its
`originalLine` anchor and past-tense wording; a review with a verdict landing in
the conversation with that verdict attached; absent optional fields decoding
without crashing or inventing; and every refusal path.

Plus the ones the live data argued for: the 101-thread shortfall, per-thread
reply truncation, a failing second page keeping its first, a GraphQL `errors`
array refusing rather than decoding to zero threads, superseded-verdict marking
against id-less `latestReviews`, `PENDING`/empty-`COMMENTED` exclusion with
empty-approval retention, short file lists, CRLF bodies, and HTML comments.

**One deviation from "everything through `FixtureGitHubCLI`.**
`FixtureGitHubCLI` keys responses on the first three argv words, so both pages of
a paginated GraphQL query collide on `api graphql` and it cannot express
pagination at all. Rather than edit `GitHubCLIProbe.swift` (owned by `Checks/`,
and out of bounds), the pagination tests use a 25-line `PagingGitHubCLI` in the
test file that keys on the cursor instead. It honours the actual contract — the
seam is `GitHubCLIProbe`, and nothing touches a network — and it makes a sharper
assertion than a response queue would: page two is served *only* if the code
really sent the cursor page one handed it.

---

## Not done, and why

- **No refresh on head movement.** The pane re-reads on demand and on first
  appearance, and otherwise shows its age. Polling GitHub on a timer is a rate
  limit waiting to happen, and there is no local event that means "a review
  landed".
- **Threads are not linked to the diff pane.** Clicking `a.swift:47` ought to open
  the editor there. That is a cross-feature wire into `Editor/` and `DiffPane`,
  both outside this task's files.
- **No avatars.** `GitHubActor.avatarURL` is decoded and carried; nothing fetches
  it, for the same reason images are not rendered.
- **The file list is not paginated** past `gh`'s 100. Stated above, and stated on
  screen.
- **Review threads are not collapsible.** A resolved thread is drawn in full with a
  neutral edge rather than folded away. Folding is the right default eventually;
  guessing at it before anyone has used the pane is not.
