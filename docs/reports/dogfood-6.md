# Orchard dogfood cycle 6 (T69)

Date: 2026-08-25 (Asia/Seoul), 20:44–20:58 KST (11:44–11:58 UTC)
CLI: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` (SHA-256 `000ddaec30651ebd3b08abd297d5f917c38d11319be3cb4eaa8aa4c4d3c22fc2`, 9,660,760 bytes, mtime 2026-08-25 20:32 +0900 — byte-identical to `/Users/dkkang/dev/damson-ide/.build/release/orchard`; `automations --help` lists `automation_not_found / automation_invalid_input / automation_disabled / automation_fire_in_flight`, so it carries `97a5495`, the T66 wave-18 commit)
Runtime: live Orchard app, `rt_5867877d-1c9d-4e1e-a3fc-7696b098ae33`, PID 4491, started 2026-08-25 20:33:26 KST — the same runtime id and PID answered every call in this cycle; the app was never launched, driven, or quit
App binary: `Orchard.app/Contents/MacOS/Orchard`, mtime 2026-08-25 20:32 — carries the T68 strings (`still contains conflict markers`, `Theirs (replayed commit)`, `Run \`git rebase --continue\` in a terminal to finish.`, `all conflicts resolved`), so the running app holds the same conflict code this report exercises
Source at HEAD of this worktree: `9043b77` (wave 19 plan); last source commit `c68ceff` (T68 merge)

Result: the supervised Claude cycle settled in 16 s and archived with `respacedLines: 0`. Every wave-16/17/18 fix in scope held (once + auto-disable, `automation_fire_in_flight`, the new `automation_disabled` guard on a consumed `once`, `repo_in_use` refusal, typed exits 1 / usage 64, typed automation codes) and the T66 empty-container `rmdir` fired on both removals — it also swept up the `damson-ide/` container that had been sitting empty since cycle 4. **One new real defect:** `GitConflictService` round-trips file content through a lossy UTF-8 `String`, so resolving a conflict in a binary or non-UTF-8 file silently rewrites bytes it never touched and stages the corrupted result (finding 1).

Everything went through the CLI. The only terminals and worktrees Orchard created for me are gone; the one foreign terminal (`term_aa262cf3-…`, shell on cc-rate-widget) was never touched. Final state matches baseline exactly: 3 repos, 3 primary worktrees, 1 foreign terminal, 0 automations, `~/Orchard/worktrees/` holding only the pre-existing `repo/`.

## Cycle 6 vs cycle 5

| Area | Cycle 5 (T63) | Cycle 6 (T69) |
|---|---|---|
| Full `--agent claude` cycle | ready 6 s, settled 17 s, `respacedLines: 0` | **Holds**: ready 5 s, settled 16 s, 250 raw / 163 readable, `respacedLines: 0`, 0 damage shapes |
| Conflict review (T68) | did not exist | **Logic verified live** against 6 real conflicts in linked worktrees (merge + rebase, UU/AA/UD/binary, default + diff3 style). GUI shell unverified — see Part 2 |
| `once` + fire-in-flight | fired once, 2× `automation_fire_in_flight` | **Holds**: 8.0 s fire window, 2× `automation_fire_in_flight`, `due` empty during the window, `enabled:false` after |
| `run --id` on a consumed `once` | not tested (T66 added the guard) | **New guard works**: `automation_disabled`, exit 1, in json and human mode |
| Typed automation codes | all `automation_error` (cycle-5 finding 10) | **Fixed**: `automation_not_found` / `automation_invalid_input` / `automation_disabled`, and `internal_error` for the unexpected path |
| Empty per-repo container | survived `worktree rm` + `repo remove` (cycle-5 finding 9) | **Fixed**: `rmdir`'d on the last `worktree rm`, twice; the stale `damson-ide/` container went with it |
| `worker-read` older lines | undiscoverable (cycle-5 finding 11) | **Documented**: `--limit <n> (default 200)` in help plus two notes; still no `hasOlder` field |
| `repo remove` refusal | typed `repo_in_use`, no `--force` | **Holds**: names worktree, then worktree + automation, then automation alone; clean removal after |
| Typed-error exit status | 1 (usage 64) | **Holds** across 14 probes on 9 verbs, json and human |

## Part 1 — full supervised Claude cycle

Receipt ids are the `id` field of each `--json` envelope; all carried `_meta.runtimeId = rt_5867877d…`. Times UTC (KST = UTC+9).

1. Baseline 11:44: 3 repos (`damson-ide` `db25c3b8-…`, `CAN-debugger-hw`, `cc-rate-widget`), 3 primary worktrees, 1 terminal (`term_aa262cf3-…`, foreign), 0 automations, `~/Orchard/worktrees/` = `damson-ide/` (empty since cycle 4) + `repo/`.
2. `run-create` 11:45:42: receipt `B3DA1AB8-10CF-4656-9A3D-E4A4C1A11828`, run `run_e7ced127d2d7`, coordinator handle `cli`.
3. `task-create`: receipt `DB943CF6-C716-4649-85DE-B7E26F1F5B14`, task `task_65cf4ac9a28f` — write one exact 79-byte line, run `cat` / `wc -c` / `git status --porcelain` / `git rev-parse --abbrev-ref HEAD`, do not commit or stage, report the byte count.
4. `worker-start --agent claude --repo damson-ide --name dogfood-t69-20260825 --setup skip --timeout-ms 240000`: 11:45:59 → 11:46:04 (**5 s**), receipt `F240FD68-F21E-4F9A-AFAA-388258EB6BA9`, dispatch `ctx_a556320c32b9`, terminal `term_389f6645-7dc3-4ca4-96b9-3feb3ff08029`, worktree `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t69-20260825` on `daekeun-kang/dogfood-t69-20260825` at `77be5cf`, effects `worktree created / setup skipped / terminal created (agent) / dispatch_input preamble accepted`, `state: ready`, `stage: input_accepted`.
5. Settlement: `check --run … --wait --types worker_done` receipt `4B2D2DC1-C569-4374-80E5-5DB171E26382`, `count: 1`, delivery `delivery_35100bd9129d`, one `worker_done` (`msg_256daa1cc51a`, created 11:46:15 — **16 s after `worker-start`**, subject "T69 scratch file created (79 bytes)", payload `outcome: succeeded`, `filesModified: [orchard-dogfood-t69.txt]`). `worker-show` receipt `F7C8C163-1232-4716-BC2F-0CBCA3E33AC2`: dispatch `completed` 11:46:15, `failure_count: 0`, `termination_reason: null`, engine `claude-code`, `agentState: idle`, resource `wtr_1ffbb71288ae` owned, `observation.exactWorker: true`.
6. Independent check of the worker's claim: the file is 79 bytes, ends in exactly one `\n` (xxd tail `… 7377 6565 700a`), content is the exact requested line, `git status --porcelain` shows only `?? orchard-dogfood-t69.txt`, branch and HEAD as reported. Nothing staged, nothing committed.
7. Live reads: auto receipt `04A6B774-93DF-497C-9EAA-F6F771E719F7` served the live stream (`fallbackReason: provider_transcript_not_pinned`, `source: terminal`, 200 of 250 lines, `oldestCursor 0`, `latestCursor 250`).
8. Ack: receipt `D5BA3A96-B450-40C7-8ED0-8B396C1C4B9B`, `duplicate: false`.
9. Release 11:47:03: receipt `DC51A954-AF35-4C52-8EE7-0F8CA38D48D3`, `state: released`, `processAction: closed_agent_terminal`, archive `captured` 250 raw / 163 readable, source `terminal`. `terminal list` afterwards shows only the foreign `term_aa262cf3-…`.
10. Archived reads: cleaned receipt `6EEDC2F6-11F2-4123-B69B-02883B0ABEAA` — 163 lines, `chromeStripped` = 30 spinner, 20 separator, 30 duplicate, 7 blank, 0 escape-remnant, **0 respaced** (`capturedLineCount: 250`), warning "87 of 250 captured lines were chrome"; raw receipt `443E1BEF-F98D-4364-9D62-35927F58C88F` — 250 untouched lines.
11. Cleanup: `worktree rm --force --delete-branch` receipt `536E0F2B-F914-403C-AB64-510D639B4AA7` → `removed`, `branchDeleted`, `branchMerged` all true. `~/Orchard/worktrees/damson-ide/` is **gone** (Part 3, finding 6). Re-show receipt `F860DA93-DF49-49F8-9754-9B5E4435232B` → `unknown_worktree`, exit 1; archive receipt `B6578C80-E332-4109-B429-DA5C1754565B` still serves 163 lines after deletion; post-release `worker-show` receipt `90D0E8B1-72DE-487D-8F52-683A1178348B` → resource `released/released`, `retainedReason: null`, terminal `null`, observation `missing`, archive `captured`. `git worktree list` and `show-ref` in the main checkout have zero `dogfood-t69` entries.

### Archive fidelity spot-check

Over receipts `6EEDC2F6…` (cleaned) and `443E1BEF…` (raw):

- 250 raw lines, 163 cleaned. 0 raw lines carry a control or escape byte; the widest raw line is exactly the 120-column pane.
- 0 damage shapes (`Tipsforgettingstarted`, `coorinator`, `Taskcompleteanddispatchsettled`, `terminalhandleis`) in raw or cleaned.
- The only run of 16+ letters in the cleaned text is `subagentPromptCacheTtl` — same single benign identifier as cycle 5. Nothing else is joined.
- 14 of 15 ground-truth phrases are present verbatim in the cleaned face. The 15th (`git rev-parse --abbrev-ref HEAD`) is absent only because the pane wrapped it at column 120 — **the raw capture carries the identical wrap** (`… ; git rev-parse` / `--abbrev-ref HEAD`), so this is the pane's line wrap, not a cleaner defect. Every substring probe (`rev-parse`, `abbrev-ref`, `--abbrev`) is present in both faces.

Not pinned as a fixture (T69 is report-only); cycle 4's fixture and `PostT54CaptureFixtureTests` hold the contract.

## Part 2 — conflict review (T68), live

### 2.0 What is reachable, honestly

**Nothing in the T68 surface is exposed over CLI or RPC.** `orchard agent-context --json` (59,654 bytes, the complete command table) contains zero occurrences of "conflict"; `grep -rni conflict Sources/OrchardRuntime Sources/OrchardProtocol Sources/orchard` returns nothing. `GitConflictService`, `GitConflictDocument`, `GitConflictSummary` and `GitConflictChoice` are referenced only from `Sources/OrchardApp/AppStore.swift` and `Sources/OrchardApp/Conflicts/ConflictReviewPane.swift`. There is no conflict verb, no conflict field on `worktree show` or `file diff`, and no RPC handler.

So "verify through the CLI/RPC" has an empty answer, and saying otherwise would be a lie. What I did instead: compiled the **OrchardCore sources at this worktree's HEAD** (`swiftc -O` over all 24 `Sources/OrchardCore/**/*.swift`, no SwiftPM, no damson, no SwiftUI) into throwaway probe binaries in the session scratchpad, and drove `GitConflictService` directly against real conflicted git worktrees. That exercises the exact code the pane calls — the running app binary carries the same symbols (header above) — but it does **not** exercise the app.

**Verified (UI-free, live git):** operation detection incl. the linked-worktree control-file path, porcelain `-z` decoding, per-stage index reads, hunk parsing (default and diff3 style), per-hunk resolution, the partial-write / no-stage rule, the staging refusal, whole-side `take` incl. the delete case, and the summary/headline/next-step transitions.

**Not verified — GUI-only, and therefore untested this cycle:**
- the conflict tab auto-opening on a mid-merge worktree and retracting when clean without stealing focus (`AppStore.syncConflictTab`), and the tab-strip badge (`WorkbenchView.swift:287`);
- the refresh cadence — `refreshConflicts` fires only from `.task(id: key)` on the workbench and from the pane's own reload, so a conflict created while the pane is already open shows up only on the manual refresh button (this is a design observation from reading, not a defect I reproduced);
- the Hunks / Whole-files segmented picker and the base/ours/theirs three-column stage panes;
- the per-hunk pickers, "All ours" / "All theirs", "Stage Resolution" vs "Save Progress" labelling, "Open in Editor";
- the orange error bar that surfaces the refusal text, the `isBusy` re-entrancy guard, and the `loadToken` stale-load guard.

A human visual pass is still owed on all of the above.

### 2.1 Scratch repos and conflicts created

All under the session scratchpad (`…/scratchpad/conflict/t69-conflict`), **outside** every registered repo and outside `~/Orchard`. Never registered with Orchard. Base commit plus two diverging branches; five **linked worktrees I created** (`wt-merge`, `wt-rebase`, `wt-space`, `wt-bin`, `wt-latin`), all removed at the end.

### 2.2 Linked-worktree control-file path — verified

`git merge feature` in the linked worktree `wt-merge` left `MERGE_HEAD` at
`…/t69-conflict/.git/worktrees/wt-merge/MERGE_HEAD` and **not** at `…/t69-conflict/.git/MERGE_HEAD` (checked both: absent at the top level, present in the linked git dir). `GitConflictService.operation(worktree:)` resolves through `git rev-parse --absolute-git-dir` and returned `merge` correctly. A naive `<path>/.git/MERGE_HEAD` check would have returned `none` here. The rebase case landed `rebase-merge/` (plus `REBASE_HEAD`) in the same linked git dir with no `MERGE_HEAD` alongside; `operation` returned `rebase`, and the rebase-first ordering in the source is what makes the labels come out as "Ours (upstream)" / "Theirs (replayed commit)" instead of merge wording.

### 2.3 Conflict listing — verified

`git merge feature` produced three kinds at once: `AA added.txt`, `UD deleted-by-them.txt`, `UU wide.txt`.

```
headline     = Merge in progress — 3 conflicted files
nextStepHint = nil                      (gated on files.isEmpty — correct)
  AA  added.txt            bothAdded    "Both added"      stages=[2,3]   inlineMarkers=true
  UD  deleted-by-them.txt  deletedByThem "Deleted by them" stages=[1,2]  inlineMarkers=false
  UU  wide.txt             bothModified "Both modified"   stages=[1,2,3] inlineMarkers=true
```

Index stages for the UU file read back 240 / 250 / 254 bytes with line 3 = `line 03` / `line 03 OURS` / `line 03 THEIRS`. `stageContents(.theirs)` on the UD file returned `nil` — the side that deleted it holds no stage, which is what makes the pane omit a "Theirs" column instead of showing an empty one.

The `-z` framing claims were tested against the exact hazard the source comments name. In `wt-space` I staged a rename (`git mv aaa-original.txt aaa-renamed.txt`) *while* two conflicts were outstanding, so porcelain led with a two-field record:

```
R  aaa-renamed.txt\0aaa-original.txt\0UU dir with space/nested file.txt\0UU has space.txt\0
```

`parsePorcelain` consumed the origin field and reported exactly **2** conflicted files with both paths intact, including the directory-with-a-space split (`dir=dir with space`, `name=nested file.txt`). No phantom paths, no off-by-one.

### 2.4 Per-hunk resolution and the staging refusal — verified

`wide.txt` parsed to 2 hunks (`startLine 3` range `2..<7`, `startLine 31` range `30..<35`, labels `HEAD` / `feature`).

- **Partial pass:** `resolve(choices: [0: .ours])` → `remainingHunks: 1`, **`staged: false`**. Hunk 0 collapsed to `line 03 OURS`; hunk 1 kept `<<<<<<< / ======= / >>>>>>>` verbatim; `git status` stayed `UU wide.txt`. The undecided part of a big file survives a partial pass exactly as documented.
- **Staging refusal:** `stage(worktree:path:)` on that half-resolved file threw `wide.txt still contains conflict markers` and `git status` was still `UU wide.txt` afterwards — the markers cannot reach a commit through this route.
- **Completion:** deciding the remaining hunk `.theirs` → `remainingHunks: 0`, `staged: true`, no markers left, `git status` `M  wide.txt`. Line 3 = `line 03 OURS`, line 27 = `line 27 THEIRS` — the two sides really were taken independently.
- **Whole-side take:** `take(.theirs)` on the AA file wrote `added on feature` and staged it; `take(.theirs)` on the UD file **removed the file and staged the removal** (`D  deleted-by-them.txt`) rather than leaving our content sitting there.
- **After all three:** `operation=merge, fileCount=0, isActive=true`, headline "Merge in progress — all conflicts resolved", and `nextStepHint` now returns "Run `git commit` in a terminal to finish the merge." `git commit --no-edit` then succeeded and `operation` dropped to `none`, `isActive=false`.
- **Rebase round-trip:** in `wt-rebase`, `resolve(.both)` → `staged: true`, hint "Run `git rebase --continue` in a terminal to finish."; `git rebase --continue` succeeded, the replayed commit carries both lines, `operation` returned to `none`.
- **diff3:** with `merge.conflictStyle=diff3` the same rebase conflict parsed with `base=["line 03"]` and `baseLabel="parent of a1400a4 (topic changes line 03)"`; the `.both` resolution dropped the base section and kept ours+theirs only.
- **Pure-text rules:** `.both` on `a/<<<X/===/Y>>>/b` yields `"a\nX\nY\nb\n"`; an unterminated region parses to **0 hunks** (the file is left alone) while `containsMarkers` still returns `true`, so it is still refused for staging.

### 2.5 New defect — lossy UTF-8 round-trip corrupts and stages non-UTF-8 files

`GitRunner.capture` decodes git's stdout with `String(decoding: outData, as: UTF8.self)` (`GitRunner.swift:130`), which is *lossy*: any byte sequence that is not valid UTF-8 becomes U+FFFD. `GitConflictService.stageContents` returns that `String`, `document()` decodes the working file the same way, and `write(_:worktree:path:)` re-encodes with `.utf8`. Nothing in the path is byte-preserving, and both write paths stage the result.

**Binary conflict** (`wt-bin`, `blob.bin` = 768 bytes containing `00 FF FE 80 C3 28` repeated, a UU conflict):

```
document                     : nil  (binary — no hunks to pick)
take(.theirs)                : wrote 1792 bytes, head = [0, 239, 191, 189]
git index truth (:3:blob.bin): 768 bytes,  sha aeb931ca…, head = 00 ff fe 80
resulting working file       : 1792 bytes, sha 630d14a9…, head = 00 ef bf bd
cmp                          : *** differ at byte 2 ***
porcelain after              : M  blob.bin      <-- corrupted content is STAGED
summary after                : files=0, "Run `git commit` in a terminal to finish the merge."
```

Every non-UTF-8 byte became `EF BF BD`; the file more than doubled in size and the pane reports the conflict resolved. This is not an exotic path: for a binary UU file `document()` returns `nil`, so the pane shows no hunks and the footer's **"Take ours" / "Take theirs" buttons are the only resolution route offered** (`ConflictReviewPane.swift:415-424` renders them unconditionally). Binary conflicts are precisely the case that goes through the broken code.

**It is not limited to binaries.** In `wt-latin`, `latin1.txt` is ordinary text whose *header line* holds one Latin-1 byte `0xE9` (`caf\xe9`), with the conflict several lines below it:

```
before resolve: 68 65 61 64 65 72 20 63 61 66 e9 20 6c 61 74 69 6e 31   "header caf<E9> latin1"
resolve(hunk 0 = .ours) -> remaining=0, staged=true
after  resolve: 68 65 61 64 65 72 20 63 61 66 ef bf bd 20 6c 61 74 69   "header caf<EF BF BD> latin1"
porcelain     : M  latin1.txt
```

A line the user never looked at, outside every conflict region, was silently rewritten and staged. `document()`'s binary guard (`GitConflicts.swift:512`, `data.prefix(8000).contains(0)`) does not help — a Latin-1 text file has no NUL byte.

T68's own tests are thorough (25 cases, including a linked-worktree case and a paths-with-spaces case) but every fixture is written and read with `encoding: .utf8` (`GitConflictTests.swift:230,234`) and there is no binary or non-UTF-8 fixture, which is exactly why this was not caught.

Not fixed here: T69 owns only this report. Suggested shape for whoever picks it up — give `GitRunner` a `Data`-returning capture, have `stageContents`/`take` move bytes rather than `String`, keep `document()`/`resolve()` on `String` but refuse (typed) instead of writing when the read was lossy, and add a binary and a Latin-1 fixture.

### 2.6 Two smaller observations from the same area

- For a binary UU file the footer falls through to the **"Stage File"** button (because `model.hunks` is empty), which calls `stage()`. There are no markers in a binary, so the refusal never fires and the button stages git's *ours* copy — silently resolving the conflict to ours with no indication that a choice was made. The button's help text ("Refused while conflict markers remain") describes a protection that cannot apply to this file.
- A binary whose first 8000 bytes contain **no** NUL (my 1024 × `0x07` fixture) slips past the `document()` binary guard and parses as "1 line, 0 hunks". The user-visible outcome is the same as the nil case because git itself refuses to write markers into a binary, so nothing breaks — but the NUL heuristic is not what is protecting anyone here, and it is worth not relying on it.

## Part 3 — regression sweep, waves 16–18

Temp repo: `git init -b main` + one empty commit (`4230b1e`) in the session scratchpad, registered at 11:52:28 (receipt `5452DD5A-FB8E-4FEF-A6FA-73CD0DF2D195`, repo `91ed54f3-4c0b-4cb5-9da6-f24aadc9b0ad`), removed at the end.

**`repo remove` refusal** — `worktree create` receipt `2E06DF95-C4A8-4F79-85F3-2BE9AD0159BC` (`t69-tmp-wt`). Then:

| Step | Receipt | Result |
|---|---|---|
| `repo remove` with a worktree | `7FE764A7-4701-475C-B8B5-FCD937862943` | `repo_in_use`, "still referenced by worktrees: 't69-tmp-wt'. Remove those first; --force is not accepted.", `data.worktrees` = 1, `data.automations` = `[]`, exit 1 (json **and** human) |
| + a disabled daily automation (`EA8415BF-…`, `auto_581d2bee-…`) | `B7FAA2E4-0540-4EE0-A244-563356F25A24` | `repo_in_use` naming **both**: "worktrees: 't69-tmp-wt'; automations: 't69-tmp-auto'" |
| after `worktree rm` (`288E540E-…`) | `013159AB-1EC3-4D09-B1C9-DFB33ED63FAD` | `repo_in_use` naming the automation alone, `data.worktrees: []` |
| after both automations removed | `84554A8F-EF16-453D-85AD-51BEB3A33F83` | the repo record, `ok: true`, exit 0 |
| `repo show` afterwards | — | `unknown_repo`, exit 1; `repo list` back to 3, `worktree list` back to 3 |

**Empty container `rmdir` (T66)** — verified **twice**, on the last `worktree rm` in each container, never recursively:

- `~/Orchard/worktrees/damson-ide/` had been sitting empty since cycle 4 (cycle-5 finding 9). Part 1's worker put `dogfood-t69-20260825` in it; after `worktree rm` receipt `536E0F2B-…` the whole `damson-ide/` container was gone.
- `~/Orchard/worktrees/t69-temp/` appeared on `worktree create` and was gone after `worktree rm` receipt `288E540E-…`; it reappeared for the automation's worktree and was gone again after receipt `E7E258F1-CB92-42AB-9474-C20F8E58616D`.
- `~/Orchard/worktrees/` ends the cycle holding only the pre-existing, non-empty `repo/` — untouched.

**`once` + fire-in-flight + the new disabled guard** — automation `t69-once` (`auto_494134a9-ce8c-4502-baaa-edb5043a30d3`) created 11:53:12 (receipt `B299AC22-1A40-4595-B7C6-AA82F69C3FBA`), `trigger once`, `time now`, `provider shell`, `--precheck "sleep 5" --timeout 10` to widen the window.

1. `due` receipt `46A41A0A-6BEB-4F25-BADA-26AE80C6A984`: the one slot, `scheduledAt` 11:53:00.
2. `fire-due` (background) held the claim **11:53:19.3 → 11:53:27.3 (8.0 s)**. Inside it: `run --id` receipt `4763227C-FBA4-4472-BA26-A1A970FFAC7C` → `automation_fire_in_flight`, exit 1; `due` → `[]` (the claimed slot is hidden); a second `run --id` receipt `B7BDA834-653A-4187-8B2B-C248AEB49501` → `automation_fire_in_flight` again.
3. `fire-due` receipt `41EE5C8B-32FA-40F2-AECB-C814DCF94938`: one run row `arun_a85bd17f-…`, `outcome: fired`, `message: "once schedule consumed; automation disabled"`, dispatch `ctx_8b4ab7219095`, run `run_a0ee6094b871`, terminal `term_df2725bd-…`, worktree `…/t69-temp/automation-043a30d3-1787658804`.
4. `show` receipt `63A137A0-97E4-4BA4-85CF-37D8A9D7B54E` → **`enabled: false`**. `due` → `[]`; an explicit second `fire-due` → `runs: []`; `runs --id` → still 1 row.
5. **New in T66:** `automations run --id` on the now-disabled (consumed) automation, receipt `FB5A9975-D47A-4DE6-8B70-936B1A5A64A5` → **`automation_disabled`**, "automation … is disabled", exit 1 in json **and** human mode. Before this guard, a manual `run --id` was the way to re-fire a spent `once`.
6. Settlement of the shell fire: `worker-show` receipt `2A51FE55-9F70-4C8C-BD38-A4BD90FA7F2D` — dispatch created 11:53:24, **`completed` 11:53:30**, `termination_reason: null`, `last_failure: null`, `failure_count: 0`, worker `succeeded / settled`, terminal engine `shell`, observation `exited`. One `worker_done` ("automation command exited 0", `outcome: succeeded`). Pane read receipt `741297CD-4B52-4CB1-9723-826AF50CD98C`: the single submitted `orchard_automation_command() { eval '…'; }; …; exit "$orchard_automation_status"` line, then `T69 once fire`, `T69 done`, then `sent worker_done  run:run_a0ee6094b871  settled  succeeded …` — executed, not left pasted, with the capability only ever inside a submitted line. `worker-release` receipt `FCFCE263-97D5-47FF-970D-6BAA3782D6DB` → `closed_exited_terminal`, archive 15 raw / 12 readable, never `retained/identity_unproven`.

**Typed exits and typed automation codes** — every typed error exits **1** in json and human mode; usage errors exit **64**:

| Command | Code | Exit |
|---|---|---|
| `automations show --id auto_nope` | `automation_not_found` | 1 |
| `automations run --id auto_nope` | `automation_not_found` | 1 |
| `automations edit --id auto_nope` | `automation_not_found` | 1 |
| `automations create --trigger fortnightly` | `automation_invalid_input` | 1 |
| `automations create --trigger once --time not-a-time` | `automation_invalid_input` | 1 |
| `automations run --id` ×2 during a fire | `automation_fire_in_flight` | 1 |
| `automations run --id` on a consumed `once` | `automation_disabled` | 1 |
| `repo show --repo nope` | `unknown_repo` | 1 |
| `repo remove` without `--repo` | `invalid_argument` | 1 |
| `repo remove` while referenced (×3) | `repo_in_use` | 1 |
| `worktree show/rm --worktree nope` | `unknown_worktree` | 1 |
| `worker-show/worker-read/dispatch-show --dispatch ctx_nope` | `dispatch_not_found` | 1 |
| `run-show --id run_nope` | `run_not_found` | 1 |
| `orchard frobnicate`, `worktree list --bogus`, `repo --nope` | usage | 64 |
| `status`, `automations list` | ok | 0 |

Cycle-5 finding 10 is closed: the generic `automation_error` is gone from every one of these paths, and `--help` now documents the four codes plus the disabled rule.

**`worker-read` paging (cycle-5 finding 11)** — documented rather than fielded: `--limit <n>  Maximum lines to return (default 200)` plus two notes ("Without --limit, worker-read returns the newest 200 lines." / "truncated describes the requested window, not whether older lines exist."). Still no `hasOlder` field; a caller must still compare `oldestCursor` against `latestCursor − returnedLineCount`.

## Findings

| # | Finding | Evidence | Status |
|---|---|---|---|
| 1 | **`GitConflictService` corrupts non-UTF-8 files and stages the result.** Content round-trips through `String(decoding:as:UTF8.self)` (`GitRunner.capture`) and back out as `.utf8`. `take(.theirs)` on a 768-byte binary produced a 1792-byte file (`aeb931ca…` → `630d14a9…`, `cmp` differs at byte 2, every non-UTF-8 byte → `EF BF BD`) and staged it. `resolve()` on a Latin-1 *text* file rewrote a `0xE9` in an untouched header line and staged that too. For binaries `document()` is `nil`, so "Take ours/theirs" is the only route the pane offers — the broken path is the only path. | Part 2.5; `wt-bin`, `wt-latin` | **New — real defect.** Needs a `Data` path in `GitRunner`/`stageContents`/`take`, a typed refusal when a read was lossy, and binary + Latin-1 fixtures (T68's 25 tests are all `.utf8`) |
| 2 | **T68's conflict logic is correct on every path reachable without the GUI.** Linked-worktree `MERGE_HEAD` and `rebase-merge` detection, rebase-before-merge ordering and the swapped ours/theirs labels, porcelain `-z` with a leading rename record and spaced paths, per-stage index reads incl. `nil` for a deleting side, hunk parse (default + diff3), partial resolve without staging, full resolve with staging, `take` incl. the delete case, `.both`, unterminated-region safety, and the headline/next-step transitions through a real `git commit` and `git rebase --continue`. | Part 2.2–2.4 | Verified (UI-free, live git) |
| 3 | **The whole T68 surface is GUI-only.** Zero occurrences of "conflict" in the 59,654-byte `agent-context` command table and zero in `OrchardRuntime`/`OrchardProtocol`/`orchard`. The tab auto-open/retract, badge, stage panes, pickers, error bar, busy/stale guards, and the refresh cadence are therefore **unverified** this cycle and still owe a human visual pass. | Part 2.0 | Honest gap — consider an `orchard worktree conflicts` verb so this is dogfoodable |
| 4 | **Full supervised Claude cycle is healthy (4th consecutive cycle).** Ready 5 s, `worker_done` 16 s after start, one delivery, dispatch `completed`, release `closed_agent_terminal`, worktree + branch removed, `unknown_worktree` on re-show while the archive stays readable. | Part 1 receipts 2–11 | Verified |
| 5 | **T54 capture holds on a third live archive.** 250 raw / 163 readable, `respacedLines: 0`, 0 escape-remnant lines, 0 damage shapes, only `subagentPromptCacheTtl` runs 16+ letters, 14/15 ground-truth phrases verbatim and the 15th is the pane's own 120-column wrap, identical in raw. | Fidelity section | Verified, not re-pinned (report-only) |
| 6 | **Empty per-repo container cleanup works (cycle-5 finding 9 closed).** `rmdir` fired on the last `worktree rm` in three separate containers, including the stale `damson-ide/` that had been empty since cycle 4; never recursive; `~/Orchard/worktrees/` ends holding only the untouched `repo/`. | Part 3 | dogfood-5 finding 9 closed |
| 7 | **Typed automation codes (cycle-5 finding 10 closed).** `automation_not_found`, `automation_invalid_input`, `automation_disabled`, `automation_fire_in_flight` — all exit 1 in json and human mode, all four documented in `automations --help`. `automation_error` no longer appears. | Part 3 exit table | dogfood-5 finding 10 closed |
| 8 | **`run --id` on a consumed `once` is refused `automation_disabled`.** The T66 guard closes the last way to re-fire a spent one-shot. Also confirmed: fires exactly once, auto-disables, `due` and a second `fire-due` stay empty. | Part 3 steps 4–5 | New guard verified |
| 9 | **`automation_fire_in_flight`, `repo_in_use`, and typed exits all hold.** 8.0 s claimed window with two refused `run --id` calls and `due` hidden; `repo_in_use` naming worktree → both → automation with structured `data` and no `--force`; 14 typed probes on 9 verbs exit 1, usage exits 64. | Part 3 | No regression from wave 16 |
| 10 | **Shell-provider automation fires execute and settle.** One submitted command line, its output, its own `worker_done` 6 s after dispatch creation, `closed_exited_terminal` on release. | Part 3 step 6 | No regression from wave 16 |
| 11 | `automations remove --id <never-existed>` returns `ok: true` with `{"removed": false}` and exit 0, while `show` / `run` / `edit` on the same id return `automation_not_found` and exit 1. Defensible as an idempotent delete, and the payload is honest, but a scripted caller checking only the exit status cannot tell "deleted" from "was never there". | receipt `A96A977B-8FC2-404F-9746-75FD47C32970` | Observation — minor inconsistency |
| 12 | `worker-read`'s 200-line default is now named in `--limit`'s help and two notes (cycle-5 finding 11), but there is still no `hasOlder` field; older lines remain discoverable only by comparing `oldestCursor` with `latestCursor − returnedLineCount`. | Part 3, `worker-read --help` | Partially closed — documented, not fielded |
| 13 | For a binary UU file the pane's "Stage File" button stages git's *ours* copy with no marker to refuse on, silently resolving to ours; and a binary with no NUL in its first 8000 bytes slips past `document()`'s binary guard (harmless today only because git itself refuses to write markers into a binary). | Part 2.6 | Observation — tighten with finding 1 |

## Cleanliness

Same runtime id and PID (`rt_5867877d-…`, 4491) before, during, and after; the app was never launched, driven, or quit. Created and removed: 1 orchestration run, 1 task, 1 Claude worker + its worktree/branch, 1 temp repo + 1 worktree + 2 automations + 1 automation worktree/branch, 5 scratch git worktrees in a scratch repo outside every registered repo. Final state = baseline (3 repos, 3 primary worktrees, 1 foreign terminal, 0 automations, `~/Orchard/worktrees/` = `repo/` only). Probe binaries and the scratch conflict repo live in the session scratchpad and touch nothing in the user's tree.
