# Orchard dogfood cycle 3 (T50)

Date: 2026-08-25 (Asia/Seoul)  
CLI: `/Users/dkkang/dev/damson-ide/.build/release/orchard` (`orchard 2.0.0-dev`, SHA-256 `0576e27ce7ac74636ec3bbe448d007181e619960bb7549b428d5e07e3d9f0e6c`, 8,867,320 bytes, mtime 2026-08-24 10:33:56 +0900)  
Runtime: live Orchard app; successful cycle used runtime `rt_e77cb3f3-9c64-48d0-9da8-e4b5bd295603`, PID 1318, started 2026-08-25 00:13:12 KST  
App helper CLI: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` — byte-identical to the requested release CLI  
Source at HEAD of this worktree: `d135b2a`  
Result: completed after one live-app relaunch. All 20 concurrent probes returned valid success JSON; the full Claude cycle settled and cleaned up; the Orchestration window reflected it; `--delete-branch` removed the created branch. A transient app exit between the load test and the first `run-create` is the principal new finding.

## Cycle 3 vs cycle 2

| Area | Cycle 2 | Cycle 3 |
|---|---|---|
| Concurrent socket load | Not exercised | **20/20 succeeded**: 10 `status --json` plus 10 `worktree list --json`, launched as 20 shell background jobs. Every file parsed with `jq`, had `ok: true`, a receipt id, and runtime metadata; all stderr files were empty. No O_NONBLOCK truncation or malformed JSON occurred. |
| Full `--agent claude` cycle | Succeeded | **Succeeded again**: `ready` at `input_accepted`, engine resolved to `claude-code`, worker settled `succeeded` in 26 seconds, and the coordinator received exactly one `worker_done`. |
| Transcript source contract | Typed `transcript_unavailable`; `auto` used terminal | **Unchanged/honest** live and archived: explicit transcript returned `ok: false`, code `transcript_unavailable`, reason `provider_session_unavailable`; `auto` returned terminal with the stated fallback. |
| Archive readability | 630 raw / 206 readable; collapsed words remained | 430 raw / 151 readable; 279 chrome lines stripped. Collapsed/corrupted spacing remains (`Taskcompleteanddispatchsettled`, malformed command text), so the partial-fix assessment is unchanged. |
| Worktree cleanup | Worktree removed but branch remained because no delete flag was used | **Fixed path verified**: `worktree rm --force --delete-branch` returned `branchDeleted: true`, `branchMerged: true`; the checkout path and `refs/heads/daekeun-kang/dogfood-t50-20260825` are both gone. |
| Orchestration app view | Not part of cycle 2 | **Verified live** via computer-use: the T50 run appeared with one completed task and a completed/succeeded/reclaimable dispatch before release, then changed to released after `worker-release`. |
| Remote guard | Not reported as exercised | **Not testable in this runtime**: `repo list` showed three local repos/workspaces only, and `host list` returned zero hosts. No user-owned remote was created merely to test the refusal. |

## Socket-load test

The load command launched 20 clients concurrently against runtime `rt_607cbb31-294f-438b-982f-039a034a3eca`: ten release-CLI `status --json` calls and ten `worktree list --json` calls. Results were stored under `/tmp/orchard-t50-load.L1iN6d`; the validator found `JSON_COUNT=20`, `FAIL=0`, and no stderr. Thus the O_NONBLOCK truncation class stayed dead under the requested load: there were no short reads, decoding errors, missing receipt envelopes, or nonzero client exits.

There was, however, a temporally adjacent stability event. After all 20 calls and subsequent successful repo/worktree/terminal snapshot calls, the Orchard process disappeared and removed `orchard-runtime.json`. The first `run-create` and its dependent `task-create` failed verbatim:

```text
orchard: Error Domain=NSCocoaErrorDomain Code=260 "The file “orchard-runtime.json” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/Users/dkkang/Library/Application Support/Orchard/orchard-runtime.json, NSURL=file:///Users/dkkang/Library/Application%20Support/Orchard/orchard-runtime.json, NSUnderlyingError=0x10605e620 {Error Domain=NSPOSIXErrorDomain Code=2 "No such file or directory"}}
```

The second failure was identical except for the final underlying object address (`0x1020567c0`). No `Orchard` diagnostic report existed under `~/Library/Logs/DiagnosticReports`, so this report does not claim the concurrent load caused the exit. Relaunching the same cached app produced runtime `rt_e77cb3f3-9c64-48d0-9da8-e4b5bd295603`, which stayed ready through the entire cycle and final status check.

## Full live-cycle receipts

1. Repo ensure: `repo list` receipt `3E49D44B-A0B0-4A20-8011-444F7AFFAAA6`; idempotent `repo add` receipt `4521C314-2E19-4F23-ACF4-9D24358605B3`; repo `db25c3b8-4da6-45f3-b59d-cf47f2cbff87`, base `origin/main`.
2. `run-create`: receipt `21F6D013-08C0-4764-99D7-552E632B3797`, run `run_889656e306a9`.
3. `task-create`: receipt `A4A78302-5278-4CFC-8FA3-0EE5942AB33E`, task `task_f38a88e92dd1` (“Create one T50 scratch line”).
4. `worker-start --agent claude`: receipt `0745510E-89ED-4071-BC7A-6FE5EB485C96`, dispatch `ctx_49651f2f3c3f`, terminal `term_e04b55a3-92d3-41a9-bd75-6698431c66e2`, worktree `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t50-20260825`, `state: ready`, `stage: input_accepted`, `residualResources: []`.
5. Settlement: worker-show receipt `D06F9DEF-DEA9-4CC4-A1C5-EB78877100BB` reported dispatch completed, worker succeeded, engine `claude-code`. Delivery receipt `811D91D5-2485-4BD9-B839-3E0E8F2CEA58`, delivery `delivery_80ac85cb2b0b`, contained exactly one `worker_done` (`msg_1ff19beefa62`). The worker verified a 30-byte scratch file, exact trailing LF, and only that untracked file in git status.
6. Live reads: transcript receipt `89A68621-26CA-4314-A30C-D1673DF0E819` was typed unavailable; auto receipt `DC705715-364E-42F7-A739-89C57BAE5697` returned live terminal output with `fallbackReason: provider_transcript_not_pinned`.
7. Release: receipt `7DCF1CE4-D5AB-46D4-BC32-847D5C498414`, `state: released`, `processAction: closed_agent_terminal`, archive captured with 430 raw / 151 readable lines.
8. Archived reads: transcript receipt `0312C5ED-C0E9-4469-B750-15B9FB664CFC` remained typed unavailable; auto receipt `C38F7FAF-048B-4DD7-887C-C49333D0E454` served the terminal archive with 222 spinner, 22 separator, 35 duplicate, 0 blank, and 0 escape-remnant lines removed.
9. Delivery ack: receipt `AA56FEF4-DDD4-46F0-BDA4-261CBED109E5`, `duplicate: false`.
10. Cleanup: `worktree rm --force --delete-branch` receipt `086C928A-E45F-49E4-A2E8-8E39A64152BC` returned `removed: true`, `branchDeleted: true`, `branchMerged: true`. A subsequent show returned typed `unknown_worktree` (receipt `CAF39C33-1A06-4EF9-B644-E2028AD59569`), filesystem testing found the path gone, and `git show-ref --verify refs/heads/daekeun-kang/dogfood-t50-20260825` found no branch. Archive receipt `7F24F9FD-A80F-42C3-881A-06A09337F9FF` still served output after deletion.

## In-app Orchestration evidence

Only the Orchard app was targeted with computer-use. The Orchestration window was opened through its sidebar Orchestration control; no other window or terminal was touched.

- Live/settled screenshot: `/tmp/t50-orchestration-live.png`. It visibly shows the objective “Dogfood T50: verify live orchestration…”, task “Create one T50 scratch line”, task status `completed`, dispatch statuses `completed`, `succeeded`, and `reclaimable`, plus terminal handle `term_e04b55a3-92d3-41a9-bd75-6698431c66e2`.
- Post-release screenshot: `/tmp/t50-orchestration-released.png`. The same row changed from `reclaimable` to `released`, matching the CLI receipt. The window's refresh indicator read `0s`.
- Accessibility snapshots are `/tmp/t50-ui-live.json` and `/tmp/t50-ui-final.json`; both identify window title `Orchestration` in app bundle `app.damson.orchard`.

## Remote guard spot-check

`repo list` reported exactly three registered repos (`damson-ide`, `CAN-debugger-hw`, `cc-rate-widget`), each with `hostId: local`; `worktree list` likewise showed only three local primary workspaces. `host list` receipt `1792C710-81C6-426E-8ABF-94366EB6` returned `hosts: []`, `totalCount: 0`. Therefore there was no registered remote workspace on which to issue `worker-start --worktree`; the `remote_unsupported` refusal was not testable without creating or touching extra resources, which the safety constraint forbids.

## New findings

1. **Transient live-app exit after a successful concurrent-load phase.** Every load response was valid, and several subsequent snapshot calls also succeeded, but the app then exited before `run-create`, removing its runtime descriptor. There was no macOS diagnostic report. This is direct evidence of one exit, but not enough evidence to attribute causality to O_NONBLOCK or to the load itself.
2. **`--delete-branch` closes cycle 2's cleanup gap.** The new cleanup response explicitly reports branch deletion and merge safety, and independent git verification confirmed the ref is absent.
3. **Observation-only Orchestration state tracks release promptly.** The view showed the settled worker as reclaimable, then as released after the CLI mutation, with its refresh age returning to zero.
4. **Explicit transcript errors still use a successful process exit status.** `worker-read --source transcript` emitted an `ok: false`, typed `transcript_unavailable` envelope but the CLI process returned exit status 0. The error contract is machine-readable, but shell scripts cannot detect it from exit status alone.

## Safety and cleanup

Before and after the successful cycle, Orchard listed the same three worktrees and five terminals. The only created checkout/terminal were the T50 dispatch resources; the terminal was released through `worker-release`, and the exact owned dirty checkout was removed with `--force --delete-branch`. The archive remains readable, no remote resources were created, no source files were changed, and no pre-existing app window or terminal was operated.
