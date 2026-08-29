# Wave 26 — GUI verification of the five surfaces that need a click

Everything in wave 26 was verified at the CLI/test level at merge time. Five
surfaces could only be verified by driving the running app: they are checked off
here, against the build the user has open, on 2026-08-29.

Method: `screencapture` plus synthetic input against the frontmost Orchard
window. Every state that needed data was created in
`~/Orchard/worktrees/ccse/apricot` — an Orchard-made worktree on the local-only
branch `daekeun-kang/apricot` with no upstream — and restored byte for byte
afterwards (`HEAD 3e6de5e`, empty `git status`, no leftover branches). No
automation was persisted; the window's frame was put back.

---

## 1. Checks sidebar (T88) — a typed refusal, on screen

The shield tab renders the same refusal the CLI returns, not an empty panel:

> ⚠ **No pull request** `no_pull_re…`
> no pull requests found for branch "…"
> Open a pull request for this branch
> checked just now
> at 3e6de5e · daekeun-kang/apricot

Headline, machine code, detail, remedy — and the provenance line saying *when* it
looked and *what* it looked at. That last line is the part that makes the empty
state trustworthy rather than ambiguous.

## 2. Source Control (T88 scope) — staging, refusal, commit

Full path driven from the panel:

| step | on screen | on disk |
|---|---|---|
| scratch file created externally | *panel unchanged* | `?? ORCHARD-SCM-CHECK.txt` |
| header ↻ | `Changes 1` · `U ORCHARD-SCM-CHECK.txt` | — |
| **Stage All** | `Staged 1` · `A …`, `Changes 0`, `Unstage All` appears | `A  ORCHARD-SCM-CHECK.txt` |
| **Commit**, message empty | `empty_commit_message — Commit message is empty.` inline, orange mono | HEAD unmoved |
| message + **Commit** | banner clears, `Staged 0` / `Changes 0` | HEAD `b71e7b5 chore: orchard scm verification` |

The refusal is the service's own code and sentence, rendered where the action
was taken. The commit was then reverted (`reset --hard 3e6de5e`).

**Finding — the panel does not poll.** It re-reads on `.task(id: root.path)`
(workspace change) and on its own mutations. An *external* change to the worktree
leaves it stale until the user presses ↻. That is consistent with
`GitSourceControl`'s "nothing is cached; the caller owns refresh cadence", and it
is honest — it never shows a wrong count — but a file changed by an agent in that
worktree will not appear on its own. Worth wiring to the same watcher that feeds
`refreshGit`.

## 3. Floating terminal — round trip, session intact

`Float Terminal` from the tab's context menu (enabled only with a live session):

- an always-on-top **Terminal — Floating** window opens showing *the same*
  session, scrollback and prompt intact;
- the pane it left shows the placeholder — "This pane's session is in the
  always-on-top window. Close that window to bring it back — the session stays
  alive." — plus **Reveal Floating Window**;
- closing the floating window returns the session to the pane, scrollback intact.

The claim on the placeholder is the behaviour, verified in both directions.

## 4. Automations editor sheet — the preview is a real evaluation

`Go ▸ Automations` → **New Automation**. Trigger `Hourly | Daily | Weekdays |
Weekly | Once | Cron`, target `Repo (fresh worktree) | Workspace (reuse
session)`, repository and provider pickers, prompt.

The "Next 3 fires" block is the thing worth verifying, and it holds up:

| cron | next 3 fires | check |
|---|---|---|
| `0 9 * * 1-5` | 2026-08-31, 09-01, 09-02 @ 09:00 UTC | today is **Sat** 08-29 — it skips the weekend |
| `99 * * * *` | *block disappears* | no fabricated schedule for an unparseable field |
| `30 2 * * 0` | 2026-08-30, 09-06, 09-13 @ 02:30 UTC | three consecutive Sundays |

`Create` is `.disabled(!validation.isValid)`; clicking it with the invalid cron
did nothing. Cancelled — `automations: 0` in the store afterwards.

## 5. Conflict review — per-hunk decisions

A reversible `add/add` conflict was created in the apricot worktree.

- The **Conflicts 1** tab appeared on its own, *unselected* — the pane is not
  stolen from whoever is typing, exactly as `syncConflictTab` documents.
- Header `Merge in progress — 1 conflicted file`; list `AA CONFLICT-CHECK.txt`;
  file badge `Both added`; scope `Hunks | Whole files`; `Open in Editor`.
- Hunk 1 · line 1 · `Undecided | Ours | Theirs | Both`, with
  `Ours (current) · HEAD` and `Theirs (incoming) · orchard-tmp-side` side by
  side — the incoming side is named, not just labelled "theirs".
- Choosing **Theirs**: the hunk grows a `Theirs` badge, the chosen side tints,
  the counter moves `0 of 1` → **`1 of 1 hunks decided`**, and the primary button
  relabels `Save Progress` → **`Stage Resolution`**.
- **Stage Resolution** wrote `side branch line` and staged it — `AA` → `M `.
- The pane then reads `Merge in progress — all conflicts resolved / Run
  \`git commit\` in a terminal to finish the merge.` It resolves; it does not
  commit the merge for you.

**Finding — the auto-tab lingers after the merge ends.** Retraction lives in
`syncConflictTab`, which only runs from `refreshGit`, and only when the tab is
not selected. After `git merge --abort` the pane needed its own ↻ to say
"No conflicts", and merely switching to another tab did not retract it; it took a
workspace switch. Both are the documented rule working as written, but the
sequence leaves a stale tab on screen with no way to dismiss it except waiting
for an unrelated refresh.

---

## Tooling note

`System Events`' `click at` reaches AppKit/SwiftUI controls but **not** the
damson terminal surface — clicks there never made it first responder, so
keystrokes went to the window and were dropped. A `CGEvent` mouseDown/Up pair
posted to `.cghidEventTap` works, because `DamsonSurfaceView.mouseDown` calls
`window?.makeFirstResponder(self)` on a real event. Not an app defect; a
constraint on how these surfaces can be driven from a script. Same for SwiftUI
`TextField` focus — the AX `AXValue` setter is the reliable way in.

## Still pending

T87's `ORCHARD_TRACE_SWITCH=1` switch-path rows. Collecting them means running
the bundle binary directly with that variable set, which means quitting and
relaunching the user's app — not something a coordinator does to a running
session. It waits for a launch the user makes themselves.
