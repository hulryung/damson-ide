# Orchard dogfood cycle 4 (T57)

Date: 2026-08-25 (Asia/Seoul)  
CLI: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` (`orchard 2.0.0-dev`, SHA-256 `422d6456a66ff968a433ceb9f0cf523502c454f06e4c01412b40e5564e71bbfd`, 9,298,488 bytes, mtime 2026-08-25 13:39:15 +0900 — byte-identical to `/Users/dkkang/dev/damson-ide/.build/release/orchard`; built after the T54 merge at 13:36 and the wave-14 close at 13:40)  
Runtime: live Orchard app, `rt_91e74d07-9bf7-4d6a-b41c-b5fb6d227821`, PID 2859, started 2026-08-25 13:40:09 KST — the same runtime answered every call in this cycle; no app exit  
Source at HEAD of this worktree: `6e1cba6`  
Result: the full supervised Claude cycle ran and cleaned up in 2m40s wall clock (worker ready in 7 s, settled 17 s after start); the T54 capture fix is verified on this cycle's own archive and pinned as the fourth fixture; automations fired live from the CLI and produced run-history rows — and surfaced a double fire, an un-executed shell prompt, and a scheduler that kept firing every minute until the automation was deleted.

Everything went through the CLI. The app was never launched, quit, or driven; the only terminal and worktrees touched were the ones this cycle created, and every one of them is gone.

## Cycle 4 vs cycle 3

| Area | Cycle 3 (T50) | Cycle 4 (T57) |
|---|---|---|
| Full `--agent claude` cycle | Succeeded; settled in 26 s | **Succeeded**: `ready` at `input_accepted` in 7 s, engine `claude-code`, one `worker_done` 17 s after start, exactly one delivery, ack `duplicate: false`. |
| Archive readability | 430 raw / 151 readable; `Tipsforgettingstarted`, `coorinator`, `Taskcompleteanddispatchsettled` in the cleaned face | **Closed on evidence**: 380 raw / 166 readable; every cleaned line is a raw line minus chrome (0 unsourced, 0 re-spaced, 0 substantive lines vanished), `respacedLines: 0`, no pre-T54 damage shape in raw or cleaned. Pinned as `Fixtures/claude-code-tui-capture-t57.txt`. |
| Transcript source contract | Typed `transcript_unavailable`; `auto` fell back to terminal | **Unchanged/honest** live and archived (`provider_session_unavailable`); `auto` states its fallback. Exit status still 0 on the typed error (cycle-3 finding 4 stands). |
| Worktree cleanup | `--force --delete-branch` verified | **Verified again** on five worktrees (one worker, four automation): `removed`, `branchDeleted`, `branchMerged` all true; paths and refs gone; `unknown_worktree` on re-show. |
| Automations | Not exercised live (T56 headless only) | **Fired live**: due-now `* * * * *` on the damson-ide repo, `automations due` listed it, `fire-due` returned a `fired` run row with `worktreeId`/`terminalId`, `automations remove` deleted it. Three new findings below. |
| App stability | One transient app exit between load test and `run-create` | **None**: same runtime id and PID before, during, and after. No concurrent-load phase this cycle. |
| Remote guard | Not testable (no hosts) | Not re-tested; `repo list` still shows three local repos only. |

## Full live-cycle receipts

Receipt ids are the `id` field of each `--json` envelope; all carried `_meta.runtimeId = rt_91e74d07…`.

1. Repo: `repo show` receipt `2771582F-315B-4454-8F48-F4922509B637`, repo `db25c3b8-4da6-45f3-b59d-cf47f2cbff87` (`damson-ide`, base `origin/main`). No `repo add` needed.
2. `run-create`: receipt `10243113-336D-4323-BFC3-58FDEC3CD69B`, run `run_2a5180f1f824`, coordinator handle `cli`.
3. `task-create`: receipt `DBD1B85E-9792-483D-8A7A-B35217E1A560`, task `task_2599cf32e704` ("Create one T57 scratch line": write one exact 69-byte line, `cat`/`wc -c`/`git status --porcelain`, do not commit).
4. `worker-start --agent claude --setup skip --timeout-ms 240000`: 13:49:01 → 13:49:08 KST, receipt `F7238736-C24B-43F1-B35E-50FE86B0D6D8`, dispatch `ctx_cc1a74b0234a`, terminal `term_737b2b84-4d9d-486a-ad11-df5c7bad4a85`, worktree `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t57-20260825` on branch `daekeun-kang/dogfood-t57-20260825` at `872e2bc`, `state: ready`, `stage: input_accepted`, `residualResources: []`, launch agent `claude`.
5. Settlement: `check --wait` receipt `74EE4885-8ABE-41D2-B524-6952E867956A` returned at 13:49:28 with `count: 1`, delivery `delivery_fa1fd35b63a3`, one `worker_done` (`msg_267b3d5c3109`, created 04:49:18Z, payload `outcome: succeeded`, `filesModified: [orchard-dogfood-t57.txt]`, body naming 69 bytes). `worker-show` receipt `CA0971DA-518B-48EB-A4DC-F694E34B9642`: dispatch `completed` at 04:49:18Z, engine `claude-code`, `agentState: idle`, resource `wtr_d65bbebf3298` owned.
6. Independent check of the worker's claim: the file is 69 bytes, ends in a single `\n`, `git status --porcelain` shows only `?? orchard-dogfood-t57.txt`.
7. Live reads: transcript receipt `3943C8BD-A73B-4807-811B-62C020CDD24A` typed `transcript_unavailable` / `provider_session_unavailable` with `nextCommands`; auto receipt `E567D538-75F3-479B-A19D-CD702194C542` served 380 live stream lines (`fallbackReason: provider_transcript_not_pinned`); `--raw` receipt `9BB13C4E-8E44-41FF-A16D-BE7B46D8015F`, also 380.
8. Release: receipt `282B2160-854F-4CF1-9E78-F38759AB5C01`, `state: released`, `processAction: closed_agent_terminal`, archive `captured` 380 raw / 166 readable.
9. Archived reads: transcript receipt `0FD32C1D-A919-45FF-B7FD-503A28A399D4` still typed unavailable (`archived: true`); auto receipt `4C086E9D-4748-4EE3-82A3-DE4602AACCC1` served the cleaned archive with `chromeStripped` = 152 spinner, 17 separator, 39 duplicate, 6 blank, 0 escape-remnant, 0 respaced; `--raw` receipt `39951AEC-FE39-4688-ABD7-CA57571BEF05` served 380 untouched lines.
10. Delivery ack: receipt `358A9372-4D50-42BB-875A-46AC3FBAF858`, `duplicate: false`. Post-release `worker-show` receipt `4DCCD941-AC6F-41E0-ADBA-49B4285D2AC8`: resource `released`, terminal `missing`, archive `captured`.
11. Cleanup: `worktree rm --force --delete-branch` receipt `AF8FBF2C-1496-4614-BF6F-E0818656B9A0` → `removed`, `branchDeleted`, `branchMerged` all true; path gone; `git show-ref` finds no branch; `git worktree list` in the main checkout has no entry; re-show receipt `82132143-1DE4-45B5-803F-FB44D4F7683D` typed `unknown_worktree`; archive receipt `DF47F3B9-6FA7-4639-8999-2F77F7653D4A` still served 166 lines after deletion.

## T54 verification on this cycle's archive

The archive was read three ways and they agree: `worker-read --raw` (380 lines), the `rawLines` array in `worker_terminal_archives.content` for `ctx_cc1a74b0234a` in a copy of `orchestration.db` (opened read-only; the WAL replays the row), and the cleaned `lines` array against `worker-read --source auto` — `rawLines == --raw` and `lines == auto` element for element.

What the capture looks like now, at the exact sites the T50 fixture collapsed or tore:

| Cycle 3 raw (pre-T54) | Cycle 4 raw (post-T54) |
|---|---|
| `Tipsforgettingstarted` | `│ Tips for getting started │` |
| `paste gain to expad` | `paste again to expand` |
| `Your coordinator's terminalhandleis:cli` | `Your coordinator's terminal handle is: cli` |
| `You talk tohe coorinatoronlythroughtheCLIcommandsbelow.Donotuse` | `You talk to the coordinator only through the CLI commands below. Do not use` |
| `Taskcompleteanddispatchsettled.` | (no such collapse anywhere; the worker's closing lines read whole) |

Checks run over the cleaned archive, independently of the cleaner (token logic restated in the test, chrome as a cell boundary):

- Every one of the 166 cleaned lines has the characters and word boundaries of some raw line: 0 unsourced, 0 re-spaced.
- 0 substantive raw lines (≥ 3 words, ≥ 24 letters, not a repaint frame) vanished.
- No raw line is wider than the 120-column pane; no raw line carries an escape or control byte.
- The only run of 16+ letters in the cleaned text is `subagentPromptCacheTtl`, an identifier Claude Code's release notes print as one word. Nothing else is joined.
- 15 ground-truth phrases (the runtime's own preamble sentences, the task's exact line, the worker's `wc -c` verification, `sent worker_done`) all present verbatim.
- Chrome off: 0 rule lines, 0 spinner frames in the cleaned face; the two-column welcome box is emitted as text.

Residual observations, not damage: the cleaner still keeps some repainted status-bar rows (4 of 14 `⎇` rows, with different `$` and token counters) and the `Update available!` / usage-limit banner; those are honest repeats of real rows, which is the T54 §5 position.

### The fourth fixture

`Tests/OrchardTerminalsTests/Fixtures/claude-code-tui-capture-t57.txt`: 380 lines, 25,729 bytes, SHA-256 `21747ccee63878931134b806b33256e4cb74190c54e32ae34ece81dbbc276ee7`. Extracted per the README recipe from a copy of `orchestration.db{,-wal,-shm}` taken after release; the only edit is the dispatch capability, replaced in place by `dcap_` + `REDACTED`×4 at the same width on four preamble lines and by `dcap_REDAC` where the TUI had already truncated it to `dcap_YxoG0…`. `PostT54CaptureFixtureTests` (new file) pins: 380 raw / whole rows / no control bytes; the cleaned shape exactly as the live receipts reported it (166 readable, 152/17/39/6/0/0/0); chrome off with the preamble, the task line, the worker's verification and its `worker_done` all readable; no joined words; and the same every-cleaned-line-is-a-raw-line-minus-chrome contract `TerminalCaptureFidelityTests` holds the three pre-T54 fixtures to.

## Automations, live

The coordinator chose to point the automation at the already-registered `damson-ide` repo rather than a temp repo, because the runtime has no `repo-remove` verb (finding 6). The prompt was a trivial shell echo that must not edit the repo.

| Time (UTC) | Call | Receipt | Result |
|---|---|---|---|
| 04:52:58 | `automations create --name dogfood-t57-fire-now --trigger five-field-cron --time '* * * * *' --provider shell --prompt "echo orchard-dogfood-t57-automation" --repo db25c3b8…` | `C832C836-E8F3-4C9D-B438-65C16CC43C64` | `auto_3587551f-69f7-41c4-beb4-4f6b8cd4ff68`, enabled |
| 04:52:59 | `automations due` | `4B4A96EF-0BC2-4132-AE75-1722998AC3A8` | listed once, `scheduledAt` 04:52:00 (the current minute — T56's rule works) |
| 04:53:10 | `automations runs --id` (before) | `30776116-E8CF-4725-8981-1303F880F7A3` | `runs: []` |
| 04:53:10–14 | `automations fire-due` | `66731D1E-5CA3-4973-A0BB-6CA50579743D` | one run `arun_99b7f35a…`, `outcome: fired`, `scheduledAt` 04:53:00, started 04:53:10.570, finished 04:53:14.217, worktree `automation-8cd4ff68-1787633590`, terminal `term_42b5cedb…` |
| 04:53:16 | `automations runs --id` (after) | `D69DDF2E-7F41-4BA1-BFCF-E29B6AE71C03` | **two** rows for `scheduledAt` 04:53:00: the one above and `arun_0e76ae27…` started 04:53:13.160 (worktree `…1787633593`, terminal `term_eeb08d97…`) |
| 04:54:16, 04:55:19 | (in-process scheduler, no CLI call) | — | two more fires for 04:54:00 and 04:55:00 (`arun_0a7d0849…`, `arun_e3c481d4…`) while the first two were being cleaned up |
| 04:55:37 | `automations remove --id` | `315FCCF9-7B8D-43D9-94A1-D833098EB6D2` | `removed: true`; `list` empty; `due` empty; no further fires |
| after | `automations runs --id` | `35E01947-2615-48F0-B200-76E1CF3C19B3` | all four run rows still readable after the automation was removed |

Each fire created a full orchestration run ("Automation: dogfood-t57-fire-now": `run_521fd04135ed`, `run_d15608174ff9`, `run_dccb6c2e0000`, `run_179968e22450`), a task, a dispatch (`ctx_a2f4094bcde0`, `ctx_63cd0c0d3fac`, `ctx_2634aea7f050`, `ctx_45540f556972`), a fresh top-level worktree on its own branch at `872e2bc`, and a shell terminal. All four worktrees were clean (`git status --porcelain` empty) — the echo never ran.

What the shell terminal held (`terminal read`, receipt `0EDE5B0E-F54E-4F1D-92D8-53FADB3AE443`; `--screen` receipt `7233EAD2-0AAA-4C12-88F4-7B1716C2BC44`; stream receipt `0E0A341B-80AA-46C1-B418-08CDF8D6C503`, 39 lines): the zsh prompt, then `❯ >....` — zsh's multi-line paste display — followed by the entire dispatch preamble (CLI commands with the live `dcap_…` capability, `=== AFTER YOU SEND worker_done ===`, `=== TASK ===`) and finally `echo orchard-dogfood-t57-automation`. No line of output `orchard-dogfood-t57-automation` exists anywhere in the stream: the paste was delivered as agent input and left sitting in the line editor, unexecuted.

Cleanup path for an automation dispatch (it never settles): `worker-release` refused with typed `dispatch_inactive` ("only a settled worker can release. Use worker-stop"); `worker-stop` returned `stopped` / `closed_agent_terminal` (receipts `8C28B5AF…`, `0CA7C536…`, `83769594…`, `77B61119…`); `worker-release` afterwards returned `state: retained`, `reason: identity_unproven`, `archive: null` (receipts `30E1F041…`, `522260A7…`); `worktree rm --force --delete-branch` then removed each worktree and branch (receipts `42B779CB…`, `256B6883…`, `6153EECB…`, `8464252A…`, all `branchDeleted`/`branchMerged` true).

## Findings

| # | Finding | Evidence | Status |
|---|---|---|---|
| 1 | **T54 holds on a live archive.** A post-T54 Claude Code session archives as whole rows; the cleaner had nothing to re-space and rewrote nothing. The archive-readability row can be closed. | Table above; 0 unsourced / 0 re-spaced / 0 vanished; `respacedLines: 0`; fixture + `PostT54CaptureFixtureTests` | Verified, pinned |
| 2 | **A due automation fires twice for the same minute when `fire-due` races the scheduler.** The explicit `fire-due` run started 04:53:10.570; the in-process scheduler's run for the same `scheduledAt` 04:53:00 started 04:53:13.160, before the first finished at 04:53:14.217. `lastRuns` de-duplication only sees a fire once it is recorded, so an in-flight fire is not a guard. Two worktrees, two terminals, two runs for one slot. | `D69DDF2E…` two rows, same `scheduledAt` | New — needs an in-flight guard (per-automation fire lock or record `scheduledAt` before the fire callback runs) |
| 3 | **A shell-provider automation does not execute its prompt.** The fire delivers the whole dispatch preamble + `=== TASK === <prompt>` into a zsh PTY as one paste; the shell shows `>....` and waits. The `echo` never ran, yet the run row says `fired`. The pane is left with a pending multi-line paste that contains lifecycle `send` commands carrying a live capability token — an Enter in that pane would run them. | Terminal reads `0EDE5B0E…`, `7233EAD2…`, `0E0A341B…`; four clean worktrees | New — either run shell prompts as commands (and record the exit status as the outcome) or refuse `--provider shell` for prompt automations |
| 4 | **`* * * * *` keeps firing every minute until removed.** Correct for the trigger, but the CLI-driven "create → fire-due → observe → remove" window cost one worktree + terminal + run per minute: four fires in 2m10s. The e2e harness never sees this because it shuts the runtime down. | Runs at 04:53:10, 04:53:13, 04:54:16, 04:55:19 | New — document `--disabled` + explicit fire (if `fire-due` gains `--id`) for one-shot exercise, or `automations run --id` |
| 5 | **Automation dispatches have no clean release.** They stay `dispatched` forever (a shell never sends `worker_done`), `worker-release` refuses (`dispatch_inactive`), and after `worker-stop` the release lands `retained`/`identity_unproven` with `archive: null`. Their runs, tasks, and dispatches remain in `run-list` / `worker-list` after the worktree is gone. | `A5532108…`, `30E1F041…`, `522260A7…`; `run-list` still shows four "Automation:" runs | New — settle an automation dispatch when its pane exits or when the automation is removed |
| 6 | **No `repo-remove` verb.** `RepoRegistryHandler` exposes `repo-list`/`repo-add`/`repo-show` only, so any registration made from the CLI (including a temp repo for a test) is permanent from the CLI. This is why the automation ran on `damson-ide`. | `Sources/OrchardRuntime/Server/RepoRegistryHandler.swift:10`; `repo --help` | Confirmed (coordinator decision B) |
| 7 | `automations --help` lists `list|show|create|edit|remove|run|runs` but not `due` / `fire-due`, which route and work (T56). | `automations --help` vs receipts `4B4A96EF…`, `66731D1E…` | Minor — help text |
| 8 | `dispatch-show` takes `--id` while `worker-show`/`worker-read`/`worker-stop`/`worker-release` take `--dispatch`; the wrong flag prints usage with exit 0. | `dispatch-show --dispatch …` → "unknown flag" | Minor — accept `--dispatch` as an alias |
| 9 | Typed errors still exit 0 (cycle-3 finding 4): `transcript_unavailable`, `dispatch_inactive`, `unknown_worktree` all returned `ok: false` with process status 0. | Checked after the cycle | Unchanged |
| 10 | Live `worker-read --source auto` before release serves the raw stream (380 lines, identical to `--raw`) with no `chromeStripped` receipt; only the archive is cleaned. Readers that want cleaned text from a live worker have to wait for release. | `E567D538…` vs `9BB13C4E…` | Observation |
| 11 | Automation run history survives `automations remove` (four rows readable by id after deletion). Useful for audit; nothing purges it. | `35E01947…` | Observation |
| 12 | No transient app exit this cycle; the cycle-3 exit is not reproduced by a plain supervised cycle. | Same `rt_91e74d07…` / PID 2859 throughout | Observation |

## Verification of this worktree

- `swift build` — ok
- `swift test` — 970 tests, 2 skipped, 0 failures (115.7 s); the 5 new `PostT54CaptureFixtureTests` cases are included
- Files: `docs/reports/dogfood-4.md` (this report), `Tests/OrchardTerminalsTests/Fixtures/claude-code-tui-capture-t57.txt` (new), `Tests/OrchardTerminalsTests/Fixtures/README.md` (fourth row), `Tests/OrchardTerminalsTests/PostT54CaptureFixtureTests.swift` (new). No production source touched.

## Safety and cleanup

Baseline before: 3 repos (`damson-ide`, `CAN-debugger-hw`, `cc-rate-widget`), 3 primary worktrees, 1 terminal (`term_b0e49933-91e5-42a7-9bfa-f7f12ed5589a`, not mine), 0 automations. Baseline after: identical — 3 repos, 3 worktrees, the same single terminal, 0 automations, `git worktree list` and `git branch --list` in the main checkout show no `dogfood-t57*` or `automation-8cd4ff68*` entries, `/Users/dkkang/Orchard/worktrees/damson-ide/` is empty, runtime `rt_91e74d07…` still `ready`. The only resources created were the T57 dispatch (terminal, worktree, branch) and the four automation fires (terminals, worktrees, branches, one automation), all removed through `worker-release` / `worker-stop`, `worktree rm --force --delete-branch`, and `automations remove`. The orchestration store was only ever copied (`cp` of `orchestration.db{,-wal,-shm}` into the session scratchpad, opened with `?mode=ro`); nothing was written to the live database directly. No production source was modified; this worktree adds the fixture, its test, the README row, and this report.
