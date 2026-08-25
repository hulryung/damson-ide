# Orchard dogfood cycle 5 (T63)

Date: 2026-08-25 (Asia/Seoul), 17:45–17:55 KST  
CLI: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` (`orchard 2.0.0-dev`, SHA-256 `70dc27dd658580212d345ee4cc4f661929a2b24d10468118c0e70ff9a8db08e5`, 9,394,408 bytes, mtime 2026-08-25 17:35 +0900 — byte-identical to `/Users/dkkang/dev/damson-ide/.build/release/orchard`; its `automations --help` lists `once` and `due|fire-due`, so it carries `e08e9f1`, the last wave-16 source commit)  
Runtime: live Orchard app, `rt_22052a2a-9d00-40d0-98ee-aed0fedc42cb`, PID 6839, started 2026-08-25 17:35:46 KST — the same runtime answered every call in this cycle; no app exit  
Source at HEAD of this worktree: `cd4ec1f` (wave 17 plan)  
Result: every wave-16 item verified live. The supervised Claude cycle settled in 17 s and archived with zero re-spacing; a `once` automation on damson-ide fired exactly once, its shell worker settled on exit, the automation auto-disabled, and two concurrent `run --id` calls inside the fire window were refused `automation_fire_in_flight`; `repo remove` refused while a worktree and then an automation referenced the temp repo and removed cleanly after; typed errors exit 1 (usage 64) on every verb checked. Two new minor findings (an empty per-repo container directory survives `worktree rm` + `repo remove`; automations verbs report `automation_error` where sibling verbs use typed not-found codes).

Everything went through the CLI. The app was never launched, quit, or driven; the only terminals and worktrees touched were the ones this cycle created, and every one of them is gone.

## Cycle 5 vs cycle 4

| Area | Cycle 4 (T57) | Cycle 5 (T63) |
|---|---|---|
| Full `--agent claude` cycle | Succeeded; ready 7 s, settled 17 s | **Succeeded**: `ready` at `input_accepted` in 6 s, engine `claude-code`, one `worker_done` 17 s after start, one delivery, ack `duplicate: false`, release `closed_agent_terminal`. |
| Archive readability | 380 raw / 166 readable, 0 unsourced / 0 re-spaced | **Holds on a second live archive**: 231 raw / 159 readable, `respacedLines: 0`, 0 unsourced, 0 re-spaced, 0 substantive lines lost, all 15 ground-truth phrases verbatim, no pre-T54 damage shape in raw or cleaned. |
| Automations | `* * * * *` fired 4× in 2m10s; double-fire race; shell prompt pasted, never run; dispatches never settled | **Hardened**: `once --time now` fired once across a minute boundary and ≥2 scheduler ticks; concurrent `run --id` ×2 → `automation_fire_in_flight`; shell prompt executed and settled the dispatch by its own `worker_done` 6 s after dispatch; `enabled: false` in the first `show` after the fire. |
| `repo remove` | No verb | **Works**: typed `repo_in_use` naming the worktree, then worktree + automation, then automation alone; clean removal; `unknown_repo` on re-show; registry back to 3. |
| Typed-error exit status | 0 (cycle-3 finding 4, cycle-4 finding 9) | **1** in `--json` and human mode across 13 typed errors on 10 verbs; usage errors **64**. |
| Help/flag nits | `automations --help` missing `due`/`fire-due`; `dispatch-show` rejects `--dispatch` | Both fixed: help lists `due|fire-due` and `once`; `dispatch-show --dispatch` and `--id` both answer. |
| App stability | Same runtime throughout | Same runtime id and PID before, during, and after. |

## Part 1 — full supervised Claude cycle

Receipt ids are the `id` field of each `--json` envelope; all carried `_meta.runtimeId = rt_22052a2a…`. Times are UTC (KST = UTC+9).

1. Baseline: 3 repos (`damson-ide` `db25c3b8-…`, `CAN-debugger-hw`, `cc-rate-widget`), 3 primary worktrees, 1 terminal (`term_b0507402-…`, shell on cc-rate-widget, not mine), 0 automations. No `repo add` needed.
2. `run-create` 08:45:53: receipt `063B587C-2D05-47B8-BE5E-DC1E7AD26E49`, run `run_489847561bf0`, coordinator handle `cli`.
3. `task-create`: receipt `96581CBE-7B26-42BA-8953-67A9227C4EE3`, task `task_5d6d22877994` ("Create one T63 scratch line": write one exact 73-byte line, `cat`/`wc -c`/`git status --porcelain`, do not commit, report the byte count).
4. `worker-start --agent claude --repo damson-ide --name dogfood-t63-20260825 --setup skip --timeout-ms 240000`: 08:46:05 → 08:46:11, receipt `93807741-58A1-426F-88B9-E27D3B1D71CF`, dispatch `ctx_7cab5b06d0f5`, terminal `term_0fb91f6a-54da-4a2f-a474-ba445c969bfa`, worktree `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t63-20260825` on `daekeun-kang/dogfood-t63-20260825` at `77be5cf`, effects `worktree created / setup skipped / terminal created (agent) / dispatch_input preamble accepted`, `state: ready`, `stage: input_accepted`.
5. Settlement: `check --run … --wait --types worker_done` receipt `3C705863-F11F-4379-8855-0478C1A9B9A9` returned at 08:46:22 with `count: 1`, delivery `delivery_3bc93a924e37`, one `worker_done` (`msg_7b0f05f70b68`, subject "T63 scratch file written (73 bytes)", payload `outcome: succeeded`, `filesModified: [orchard-dogfood-t63.txt]`). `worker-show` receipt `A0CC155A-F493-48B6-95A6-8D369C276F14`: dispatch `completed` at 08:46:22, `worker.state: succeeded`, `stage: settled`, engine `claude-code`, `agentState: idle`, resource `wtr_696a21e3fc52` owned, `observation.exactWorker: true`.
6. Independent check of the worker's claim: the file is 73 bytes, ends in a single `\n` (xxd tail `2d32 350a`), content is the exact line, `git status --porcelain` shows only `?? orchard-dogfood-t63.txt`, branch and HEAD as reported.
7. Live reads: transcript receipt `97A51198-FAC6-40F8-B26C-DDFF9C327D5E` typed `transcript_unavailable` / `provider_session_unavailable` with two `nextCommands` — **process exit status 1**; auto receipt `1854E2DC-6EF5-413C-9785-292C92F85F52` served the live stream (`fallbackReason: provider_transcript_not_pinned`, 200 of 231 lines, no `chromeStripped` receipt); raw receipt `243397A4-1C7C-4903-A45C-E92CC6A1E29A` identical window.
8. Ack: receipt `9EB66C13-8FA1-4AE7-BCCF-641560021DD6`, `duplicate: false`.
9. Release 08:46:49: receipt `10BB98BC-E0B3-41E4-9E09-692B2EA92DBD`, `state: released`, `processAction: closed_agent_terminal`, archive `captured` 231 raw / 159 readable, source `terminal`. `terminal list` afterwards shows only the foreign `term_b0507402-…`.
10. Archived reads: transcript receipt `BCEB250F-AE95-4FEE-9B79-1BF089123CC9` still typed unavailable (`archived: true`, exit 1); auto receipt `341DA7ED-3086-4157-96BB-CDB8C866CD9F` served 159 cleaned lines with `chromeStripped` = 27 spinner, 17 separator, 22 duplicate, 6 blank, 0 escape-remnant, **0 respaced** (`capturedLineCount: 231`) and the warning "72 of 231 captured lines were chrome"; `--raw` receipt `87B39D96-BFB7-47A6-9B68-11B06BA8D16E` served 231 untouched lines. Post-release `worker-show` receipt `3E817FB2-1C0A-42BA-AB36-4C11B424CF8C`: resource `released`, terminal `null`, observation `missing`, archive `captured`.
11. Cleanup: `worktree rm --force --delete-branch` receipt `A4A7EB53-F89D-4D57-8514-8F9433069DFD` → `removed`, `branchDeleted`, `branchMerged` all true; path gone; `git worktree list` / `show-ref` in the main checkout have no `dogfood-t63` entry; re-show receipt `DAE146C1-0B9B-4E7F-9E4F-51A7F92CA82B` typed `unknown_worktree` (exit 1); archive receipt `BB0D0CA6-48A0-45F4-AD7F-9030E5894F84` still served 159 lines after deletion.

### Archive fidelity spot-check

Same method as cycle 4, restated independently of the cleaner over receipts `341DA7ED…` (cleaned) and `87B39D96…` (raw): box-drawing, bullets, spinner glyphs and `⎿`/`❯` are cell boundaries; a cleaned line is "sourced" if its token sequence is a contiguous run of some raw line's tokens, "re-spaced" if only its joined characters match.

- 231 raw lines, 159 cleaned. 0 raw lines carry a control or escape byte; the widest raw line is exactly the 120-column pane.
- **0 unsourced, 0 re-spaced** cleaned lines.
- 6 substantive raw lines are absent from the cleaned face and all six are repaint frames: 4× the `⏵⏵ bypass permissions on …` status row (one copy is kept), 1× a `✶ Accomplishing… (running stop hook · 17s …)` spinner frame (10 raw spinner frames of that row, all chrome), 1× a `$0.43` status-bar repaint (the `$0.30` and the final truncated status rows are kept). 4 of 7 raw `⎇` rows survive — honest repeats, the T54 §5 position.
- The only run of 16+ letters in the cleaned text is `subagentPromptCacheTtl` (a Claude Code release-note identifier). Nothing else is joined.
- 15 ground-truth phrases present verbatim: the preamble's `Your coordinator's terminal handle is: cli` and `You talk to the coordinator only through the CLI commands below`, `=== TASK ===`, `BEHAVIOR RULE`, the task's exact 73-byte line, `Do NOT commit`, `orchard-dogfood-t63.txt`, `wc -c`, `73`, `git status --porcelain`, `task_5d6d22877994`, `ctx_7cab5b06d0f5`, `--outcome succeeded`, `worker_done`, `Tips for getting started`.
- Chrome off: 0 rule lines, 0 spinner frames in the cleaned face; the welcome box is emitted as text; the worker's closing recap and `sent worker_done run:run_489847561bf0 settled succeeded …` read whole.
- No pre-T54 damage shape (`Tipsforgettingstarted`, `coorinator`, `Taskcompleteanddispatchsettled`, `terminalhandleis`) in raw or cleaned.

Not pinned as a fixture this cycle (T63 is report-only); the cycle-4 fixture and `PostT54CaptureFixtureTests` already hold the contract.

## Part 2 — hardened automations, live on damson-ide

The scheduler ticks every 30 s (`AutomationService.swift:244`), so a `once --time now` slot is claimed by whichever of the in-process tick and a CLI `fire-due` gets there first. To make the fire window wide enough to race deterministically, the automation carried `--precheck "sleep 5"` (the precheck runs inside the claimed window).

1. `automations create --name t63-once --trigger once --time now --provider shell --repo damson-ide --prompt "echo T63 once fire; sleep 3; echo T63 done" --precheck "sleep 5" --timeout 10` at 08:49:03.950: receipt `56C8B13A-C27F-4FEF-9041-E0A75B9E5A80`, `auto_084870ed-1af2-4f44-bbaf-9fc221be0d35`, `enabled: true`, `time: now`.
2. `automations due` receipt `F3A35563-F321-4A42-8AA5-A19E3C78EB01`: the one slot, `scheduledAt` 08:49:00.
3. `fire-due` (background) claimed the slot at 08:49:03.994; 0.6 s later, inside the window: `run --id auto_084870ed…` receipt `DD381E1E-BB49-4C8A-BCC2-C645611A9A6F` → **`automation_fire_in_flight`** ("a fire for automation … is already in flight"), exit 1; `due` receipt `9499F6CC-78BF-4340-BA4B-3DD255381D32` → `[]` (the claimed slot is hidden); a second `run --id` receipt `6C10AC09-AA96-4337-A561-358E01513121` → `automation_fire_in_flight` again, exit 1.
4. `fire-due` returned at 08:49:12.051 (window 8.06 s = 5 s precheck + ~3 s shell worker-start), receipt `17AD9FC2-72A0-483C-A3FD-E775D82EDD94`: one run row `arun_f1208b74-79de-418d-96dc-f3e618ccf048`, `outcome: fired`, `message: "once schedule consumed; automation disabled"`, `dispatchId ctx_557bd4b20d20`, `orchestrationRunId run_e5dec1c6f76b`, `terminalId term_a1956df3-c2cf-4875-9794-91a77ac5613f`, worktree `…/damson-ide/automation-21be0d35-1787647749`.
5. Immediately after: `show` receipt `44D7601E-B115-4933-8319-86BA6862E945` → **`enabled: false`**; `runs --id` receipt `55B1D635-5C0C-47A4-8BCD-2A0F96E9C7B2` → 1 row; `due` receipt `61F8BC90-026B-4BC4-961A-756A508C7250` → `[]`.
6. Settlement: `check --run run_e5dec1c6f76b --wait --types worker_done` receipt `4DE8994B-F808-4706-9417-3E40733EC14C` → one `worker_done` `msg_8f3a590904f0` created 08:49:15, subject "automation command exited 0", payload `outcome: succeeded`, `taskId task_5bc79e8a8763`, `dispatchId ctx_557bd4b20d20`. `worker-show` receipt `BFF12F77-11B5-4702-8C57-E955650D05DA`: dispatch created 08:49:09, **`completed` 08:49:15**, `termination_reason: null`, `last_failure: null`, `worker.state succeeded / stage settled`, effects `… / dispatch_input mode shell-command accepted`, terminal engine `shell`, `connected: false`, observation `exited`, resource `owned / not_requested`. No escalation landed in the run's mailbox. `run-show --id` receipt `31BC63C8-1C89-4C6D-AB62-2A43932E9299`: run "Automation: t63-once", its task completed 08:49:15 with the `worker_done` body as `result`.
7. The pane really ran the prompt: live read receipt `A339E267-679D-4213-A04D-B8589F800D3A` (16 lines, `status.terminal: exited`) shows the single submitted `orchard_automation_command() { eval '…'; }; …; exit "$orchard_automation_status"` line, then `T63 once fire`, `T63 done`, and `sent worker_done run:run_e5dec1c6f76b settled succeeded …`. Nothing is left pending in pane input.
8. Ack receipt `7C55EDA5-7E06-432D-BEE9-C8099505BED1` (`duplicate: false`). Release 08:50:15 receipt `FE376E7E-7B75-40B1-B20D-FB00D8B4EA56`: `state: released`, **`processAction: closed_exited_terminal`**, archive `captured` 16 raw / 13 readable. Post-release `worker-show` receipt `EE06662C-4D0D-4C32-A732-887CA524A905`: `released / released`, `retainedReason: null`, terminal `null`. Archived read receipt `88F16E41-38A9-479A-90DC-D40552494F21`: 13 lines, `respacedLines: 0`. `worktree rm --force --delete-branch` receipt `0612A199-1006-4A78-8CD9-A24B31CCACC7`: `removed`, `branchDeleted`, `branchMerged` all true.
9. Exactly once, across time: after the 08:50 minute boundary and at least two 30 s scheduler ticks (08:50:40), `runs --id` receipt `E5221160-C7A3-4095-A5B8-AB9F04FAC97E` → still 1 row (`scheduledAt` 08:49:00); `due` receipt `4965DEC6-E94E-439A-AC77-F6559550DC2B` → `[]`; an explicit `fire-due` receipt `34EC2220-6E52-481B-9854-807C950E951D` → `runs: []`; `runs` still 1; `show` still `enabled: false`; `list` shows `t63-once` disabled.
10. `automations remove` receipt `15627BC8-6009-476A-BA3F-C5713336183C` → `removed: true`; `list` → `[]`; `runs --id` receipt `95F77A7A-D9F5-4D9D-8852-DCB7B9D99317` still returns the 1 row (cycle-4 observation 11 stands); `show` receipt `9EB80090-D08A-4FBF-A40D-683E517ECB8E` → `automation_error: automation not found`, exit 1.

Net for the dogfood-4 findings: 2 (double fire) closed by the claim; 3 (pasted, never executed) closed — the prompt ran and the capability only ever appeared inside a submitted line; 4 (`* * * * *` refires) closed for the dogfood use case by `once` + auto-disable; 5 (never settles) closed — the dispatch completed on the line's own `worker_done` before the PTY ended and released `closed_exited_terminal`, not `retained/identity_unproven`.

## Part 3 — `repo remove`

Temp repo: `git init -b main` + one empty commit (`c126ae5`) inside the session scratchpad.

1. `repo add --path … --display-name t63-temp --base-ref main` 08:51:31: receipt `77C2BB04-D328-4493-BC20-971C3B710D97`, repo `b9cae268-34a4-4be6-ad38-1a9525499a26`; `repo list` count 4.
2. `worktree create --repo b9cae268… --name t63-tmp-wt` 08:51:35: receipt `C6FA6114-93B9-4021-AA26-E93408F864DC`, worktree `b9cae268…::/Users/dkkang/Orchard/worktrees/tmp-repo-t63/t63-tmp-wt` on `daekeun-kang/t63-tmp-wt`, lineage `origin: cli`.
3. `repo remove --repo b9cae268…` receipt `0606C7F2-1FD9-4D18-A332-69B737814C47` → **`repo_in_use`**, exit 1, message "cannot remove repo 't63-temp': still referenced by worktrees: 't63-tmp-wt'. Remove those first; --force is not accepted.", `data.worktrees` = the one id/displayName, `data.automations: []`. Human mode: `orchard: repo_in_use: cannot remove repo …`, exit 1.
4. Added a disabled daily automation on the temp repo (receipt `A36AAC6D-094E-4D87-A957-1551673B3240`, `auto_464044c7-…`, `enabled: false`). `repo remove` receipt `A24DE051-40F9-48D3-84C4-31D6C4B27C78` → `repo_in_use` naming **both** ("worktrees: 't63-tmp-wt'; automations: 't63-tmp-auto'"), exit 1.
5. `worktree rm --force --delete-branch` receipt `21D444FB-C310-4177-9130-400E9DCB78C8` → removed, branch deleted. `repo remove` receipt `A9A41F40-A2EC-44A0-BFFA-B8298F4BEDA4` → `repo_in_use` naming the automation alone, `data.worktrees: []`, exit 1.
6. `automations remove` receipt `BF6F8EF9-96F0-43FD-9781-D224682FF7ED` → removed. `repo remove` receipt `C4DA7B60-FBEA-4197-ADF7-7EF8F35FF6F3` → **the repo record with `removed: true`**, exit 0.
7. After: `repo show` receipt `CAF3A7FB-0E4A-4DED-96F3-E49EE9E5C9D7` → `unknown_repo` ("no repo matching 'b9cae268…'"), exit 1; `repo list` back to the 3 baseline repos; `worktree list` back to 3; the temp repo's own `git worktree list` has only its primary checkout and `git branch` only `main`. `WorkspaceService.removeRepo` also drops the repo's folder workspaces, retired-name set, worktree meta and lineage from `orchard-data.json` — nothing was left for `worktree list` to show.
8. Left behind: the empty container directory `/Users/dkkang/Orchard/worktrees/tmp-repo-t63/` (created 17:51:35 by `worktree create`, still present after `worktree rm` and `repo remove`). Removed by hand with `rmdir`; the temp repo directory in the scratchpad was deleted. Finding 9 below.

## Part 4 — typed errors exit non-zero

Spot-checked well past the three the plan asked for; every typed error (`ok: false`) exits **1** in both `--json` and human mode, and every usage error exits **64**:

| Command | Error code | Exit |
|---|---|---|
| `worker-read --source transcript` (live and archived) | `transcript_unavailable` | 1 |
| `worktree show --worktree no-such-worktree` (json and human) | `unknown_worktree` | 1 |
| `worktree rm --worktree no-such-worktree` | `unknown_worktree` | 1 |
| `worker-read --dispatch ctx_nope` / `worker-show --dispatch ctx_nope` | `dispatch_not_found` | 1 |
| `automations run --id` during a fire (×2) | `automation_fire_in_flight` | 1 |
| `automations run --id auto_nope` / `show --id auto_nope` (human) | `automation_error` | 1 |
| `automations create --trigger fortnightly` / `--trigger once --time not-a-time` | `automation_error` | 1 |
| `repo remove` while referenced (×3, json and human) | `repo_in_use` | 1 |
| `repo show --repo nope` | `unknown_repo` | 1 |
| `repo show` / `repo remove` without `--repo` | `invalid_argument` | 1 |
| `task-create --spec x` with no run in scope | `run_not_found` | 1 |
| `orchard frobnicate` | usage: unknown command | 64 |
| `worktree list --bogus` / `run-show --run …` | usage: unknown flag | 64 |
| `status`, `dispatch-show --dispatch …`, `dispatch-show --id …`, idempotent `worker-release` replay | ok | 0 |

`CLIEnvelopeExit` (`CLIFormatting.swift:207`): `success 0`, `typedError 1`, `usage 64` — the live binary matches the source.

## Findings

| # | Finding | Evidence | Status |
|---|---|---|---|
| 1 | **Full supervised Claude cycle is healthy.** Ready in 6 s, `worker_done` 17 s after start, exactly one delivery, dispatch `completed`, release `closed_agent_terminal`, worktree and branch removed, `unknown_worktree` on re-show while the archive stays readable. | Part 1 receipts 1–11 | Verified (3rd consecutive cycle) |
| 2 | **T54 capture holds on a second live archive.** 231 raw / 159 readable, `respacedLines: 0`; 0 unsourced, 0 re-spaced, 0 substantive lines lost, 15/15 ground-truth phrases, no damage shapes; only `subagentPromptCacheTtl` runs 16+ letters. | Fidelity section; receipts `341DA7ED…`, `87B39D96…` | Verified, not re-pinned (report-only task) |
| 3 | **`once` fires exactly once and auto-disables.** One run row after the claimed fire, across a minute boundary, ≥2 scheduler ticks and an explicit `fire-due`; `enabled: false` in the first `show` after the fire; `due` empty thereafter; fired row stamped "once schedule consumed; automation disabled". | Part 2 steps 4, 5, 9 | dogfood-4 finding 4 closed |
| 4 | **Concurrent `run --id` inside the fire window is refused `automation_fire_in_flight`** (twice, exit 1) and `due` hides the claimed slot for the whole 8.06 s window. | Receipts `DD381E1E…`, `9499F6CC…`, `6C10AC09…` | dogfood-4 finding 2 closed |
| 5 | **Shell-provider fires execute and settle on exit.** The pane shows the one submitted command line, `T63 once fire` / `T63 done`, and the line's own `sent worker_done … settled succeeded`; dispatch `completed` 6 s after creation with no escalation; `worker-release` → `closed_exited_terminal` with a 16/13 archive, never `retained/identity_unproven`. | Receipts `4DE8994B…`, `BFF12F77…`, `A339E267…`, `FE376E7E…` | dogfood-4 findings 3 and 5 closed |
| 6 | **`repo remove` works and refuses honestly.** `repo_in_use` names the worktree, then worktree + automation, then the automation alone, with structured `data`; no `--force`; clean removal returns the record with `removed: true`; `unknown_repo` afterwards; registry, worktree list, and the temp repo's git state all back to baseline. | Part 3 receipts | dogfood-4 finding 6 closed |
| 7 | **Typed errors exit 1, usage errors exit 64,** in both `--json` and human mode, across 13 typed errors on 10 verbs. | Part 4 table | cycle-3 finding 4 / dogfood-4 finding 9 closed |
| 8 | Help/flag nits fixed: `automations --help` lists `due|fire-due` and `once`; `dispatch-show` accepts `--dispatch` and `--id`. | `automations --help`; receipts `68FA1447…`, `EF18CAF7…` | dogfood-4 findings 7 and 8 closed |
| 9 | **Empty per-repo container directory survives removal.** `worktree create` makes `/Users/dkkang/Orchard/worktrees/<repo>/`; `worktree rm` of its last worktree and then `repo remove` leave the empty directory behind (`tmp-repo-t63/`, and `damson-ide/` has been sitting empty since cycle 4). Cosmetic, but `repo remove` claims to drop what the repo owns. | `ls /Users/dkkang/Orchard/worktrees/` after Part 3; Part 1 and 2 cleanups | New — minor: `rmdir` the container when its last worktree goes, or on `repo remove` |
| 10 | **Automations use one generic error code.** Not-found (`show`/`run --id auto_nope`, and after `remove`) and invalid input (`--trigger fortnightly`, `once --time not-a-time`) all come back as `automation_error`, whereas the sibling verbs are typed (`unknown_repo`, `unknown_worktree`, `dispatch_not_found`, `invalid_argument`). A scripted caller has to string-match the message to tell "missing" from "invalid". | Receipts `C892D862…`, `9EB80090…`, `61587154…`, `3E5F7489…` | New — minor: `unknown_automation` + `invalid_argument` |
| 11 | Live `worker-read` without `--limit` returns the newest 200 of 231 lines with `truncated: false`; the 31 older lines are only discoverable by noticing `oldestCursor 0` vs `latestCursor − returnedLineCount`. | Receipts `1854E2DC…`, `243397A4…` vs `87B39D96…` | Observation — a `hasOlder`/`truncated` hint would help |
| 12 | Manual `run --id` on a consumed (disabled) `once` automation is not refused by the source — `AutomationService.run(id:)` never checks `enabled` — so an operator can fire a disabled one-shot again. Not exercised (it would create another worktree); a policy decision, not a defect. | `AutomationService.swift:124–127` | Observation for T60 follow-up |
| 13 | The 1 KB shell-command line is echoed by zsh's line editor with one torn partial repaint (a fragment beginning `chard/Orchard.app/…`) in both the live and archived pane text; the capability token is visible in the archive exactly as an agent preamble's is. Cosmetic; the T60 hygiene position (only ever inside a submitted line) holds. | Receipts `A339E267…`, `88F16E41…` | Observation |
| 14 | `worker-release` on an already-released dispatch replays `ok: true` with the same archive (idempotent, exit 0) rather than a typed refusal. Reasonable; noted because cycle 4 saw `dispatch_inactive` for automation dispatches, which the T60 settlement path no longer produces. | Receipt `2597D5E1…` | Observation |
| 15 | Cycle-4 observations 10 and 11 stand: live `--source auto` serves the raw stream with no `chromeStripped` receipt; automation run history survives `automations remove`; the automation's Run/Task/Dispatch remain in `run-list` / `worker-list` as the record. | Receipts `1854E2DC…`, `95F77A7A…`; `run-list` 10 rows | Unchanged, by design (T60 §4) |
| 16 | No app exit, no runtime restart: same `rt_22052a2a…` / PID 6839 throughout. | `status` before and after | Observation |

## Verification of this worktree

Report-only: no production source or test was touched, so no build or test run was needed for this change. The `once` behaviour was additionally cross-checked against `AutomationService.swift` (claim/`execute`/`persist`, 30 s scheduler loop) and `RepoRegistryHandler.swift` / `WorkspaceService.removeRepo` to describe what the live binary was doing.

## Safety and cleanup

Baseline before: 3 repos (`damson-ide`, `CAN-debugger-hw`, `cc-rate-widget`), 3 primary worktrees, 1 terminal (`term_b0507402-f1b2-4a9a-86a7-e711bbf3faf4`, not mine), 0 automations, runtime `rt_22052a2a…` PID 6839. Baseline after: identical — 3 repos, 3 worktrees, the same single terminal, 0 automations, same runtime and PID, `git worktree list` in `/Users/dkkang/dev/damson-ide` has no `Orchard/worktrees` entry and no `dogfood-t63*` / `automation-21be0d35*` branch, `/Users/dkkang/Orchard/worktrees/damson-ide/` is empty, and the `tmp-repo-t63/` container (finding 9) was `rmdir`ed. Resources created and removed by this cycle: one orchestration run + task + Claude dispatch (terminal, worktree, branch), one `once` automation and its fire (run, task, shell dispatch, terminal, worktree, branch), one temp repo registration with one worktree and one disabled automation, and the scratchpad temp repo. Everything was removed through `worker-release`, `worktree rm --force --delete-branch`, `automations remove`, and `repo remove`; nothing was written to the orchestration store or `orchard-data.json` directly. The app was never launched or quit; nothing was pushed.
