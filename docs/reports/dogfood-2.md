# Orchard dogfood cycle 2 (T38)

Date: 2026-08-24 (Asia/Seoul)  
CLI: `/Users/dkkang/dev/damson-ide/.build/release/orchard` (`orchard 2.0.0-dev`, SHA-256 `298c0d339f7f5fc22268db65ae82dd212ce959cd99c01540d8d0b37344ca2ec3`, mtime 2026-08-24 00:17)  
Runtime: live Orchard app, runtime `rt_e8465133-8c53-41db-b7a2-919f3529043d`  
App: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/MacOS/Orchard` PID 48071, started 2026-08-23T15:17:47Z (Mon Aug 24 00:17:47 KST)  
App helper CLI: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` — **same SHA-256 as the release CLI**  
Source at HEAD of this worktree: `c878f41` Merge T35 (T36 already merged as `b6f93f6`)  
Result: completed. `--agent claude` launched, the worker ran the injected absolute CLI path verbatim, `worker_done` settled, transcript reads failed typed rather than lying, the archive was chrome-stripped and still readable after release and worktree deletion.

## Live-runtime vs T35/T36

This cycle used only the specified release `orchard` against the **live app runtime**. Before any mutating verbs, status/agent-context were used to check whether that runtime actually contained the Wave 9 fixes.

Evidence the running app **does** include T35 and T36 (not a stale pre-fix build):

- App binary and helper CLI timestamps are 2026-08-24 00:17, matching the process start and the release CLI mtime.
- Helper `orchard` byte-identical to `.build/release/orchard`.
- `status --json` reports `cliCommand` as the app helper path, `mode: app`, `status: ready`.
- `agent-context` enumerates `--agent` allowed values including the alias `claude`, and describes `--source transcript` as failing typed rather than falling back.
- Observed behavior matches those contracts (`--agent claude` ready at `input_accepted`; `worker-read --source transcript` returns typed `transcript_unavailable`).

T35 failed-start rollback was **not** re-exercised: the alias succeeded, so there was no partial worktree/dispatch to roll back.

## Command log and receipts

All commands below used only `/Users/dkkang/dev/damson-ide/.build/release/orchard` against the app runtime. Receipt IDs are included where the CLI returned them.

1. `/Users/dkkang/dev/damson-ide/.build/release/orchard --help`
   - Printed the top-level command list. `worker-start`, `worker-read`, `worker-release`, `worktree`, and the orchestration verbs were present.

2. `/Users/dkkang/dev/damson-ide/.build/release/orchard guide`
   - Printed a single topic: `orchestration`. No error. (Cycle 1 failed here with a usage line.)

3. `/Users/dkkang/dev/damson-ide/.build/release/orchard guide get orchestration`
   - Returned the embedded orchestration guide. It now documents `--agent` aliases (`claude` is `claude-code`), failed-start rollback + `residualResources`/`cleanupCommand`, `worker-read --source` as a contract (`transcript` fails typed; only `auto` may substitute), and the two-face archive (chrome-stripped default, `--raw` for the untouched capture).

4. `/Users/dkkang/dev/damson-ide/.build/release/orchard status --help`
   - Printed the command spec (`Usage: orchard status [options]`, `--json`, `-h, --help`). (Cycle 1: `unknown flag --help for status`.)

5. `/Users/dkkang/dev/damson-ide/.build/release/orchard agent-context --json`
   - Returned the complete command schema (`schemaVersion` + 40 commands). `worker-start --agent` `allowedValues`: `claude-code`, `codex`, `cursor-agent`, `grok`, `shell`, `claude`, `cursor`. `worker-read --source` `allowedValues`: `auto`, `transcript`, `terminal`, with summary “transcript fails typed rather than falling back”, plus `--raw`.

6. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-start --help` / `worker-read --help` / `worktree --help`
   - Each printed its spec. `--help` still does not list the engine ids (those live in `agent-context`).

7. `/Users/dkkang/dev/damson-ide/.build/release/orchard status --json`
   - Receipt `8D117BD3-E5EF-42EE-9A59-6A92472E82A9` (an earlier probe in the same session was `C30262C1-D354-4C6F-9E67-684A7974986E`): `ok: true`, `status: ready`, `mode: app`, PID 48071, runtime `rt_e8465133-8c53-41db-b7a2-919f3529043d`, `cliCommand` the app helper.

8. `/Users/dkkang/dev/damson-ide/.build/release/orchard repo list --json`
   - Receipt `E44C8772-9903-4C54-AA35-97FDF675CBB8`: three repos; `/Users/dkkang/dev/damson-ide` already registered as `db25c3b8-4da6-45f3-b59d-cf47f2cbff87` with base `origin/main`.

9. `/Users/dkkang/dev/damson-ide/.build/release/orchard repo add --path /Users/dkkang/dev/damson-ide --json`
   - Receipt `A3D7DDD9-C8A6-4D1F-8B93-6E91363EB36B`: idempotently returned the existing repo record. There is no `repo ensure` verb; this is the ensure path (list + add).

10. `/Users/dkkang/dev/damson-ide/.build/release/orchard repo list --json`
    - Receipt `0B42FA63-823A-4651-845A-FE4F1F7F82E0`: still three repos.

11. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree list`
    - Human table with `NAME / BRANCH / HOST / PATH` for the three primary checkouts (`local`). No staleness warning (none of these are remote). JSON list receipt from the pre-cycle snapshot: `28673AA6-A41B-40E6-8A6C-09DB16AA2612`.

12. `/Users/dkkang/dev/damson-ide/.build/release/orchard run-create --objective 'Dogfood T38: have a Claude worker append one line to a scratch file and report completion' --json`
    - Receipt `C0930078-55C0-409D-9F2E-0E5EC5E7E9CD`: created `run_f5d0ac1382b4`; coordinator handle and pane key were both the synthetic value `cli`.

13. `/Users/dkkang/dev/damson-ide/.build/release/orchard task-create --run run_f5d0ac1382b4 --task-title 'Append one scratch line' --spec '<trivial spec: append one line, verify, follow preamble CLI path verbatim>' --json`
    - Receipt `6522E7F5-A357-495F-8F9B-C32BDC15007E`: created ready task `task_a2cfa1d1dcd0`.

14. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-start --task task_a2cfa1d1dcd0 --repo db25c3b8-4da6-45f3-b59d-cf47f2cbff87 --name dogfood-t38-20260824 --agent claude --base-branch origin/main --setup skip --timeout-ms 120000 --json`
    - Receipt `00121624-1295-41F7-B0E5-200BA3D782EB`: **succeeded**. `state: ready`, `stage: input_accepted`, `launch.agent: claude`. Created dispatch `ctx_c6ed09a10232`, worktree `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t38-20260824`, owned terminal `term_f91112a8-b4ac-48a4-96a8-5bf6bee5ee77`. `residualResources: []`.
    - (Cycle 1: the same `--agent claude` failed at `terminal_create` with `unknown engine: claude` after already creating a worktree.)

15. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-show --dispatch ctx_c6ed09a10232 --json`
    - Receipt `7A4E9303-967B-4829-A550-12B1E3832DD1`: exact worker live, dispatch `dispatched`, terminal connected, **engine `claude-code`** (alias resolved), `startOptions.agent: claude`, agentState `working`.

16. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source transcript --limit 40 --json`
    - Receipt `EE5D8405-6AF2-4886-978A-F88E4BC56E35`: **typed failure** `transcript_unavailable`, `reason: provider_session_unavailable`, `availableSource: terminal`, `archived: false`, with `nextCommands` pointing at `--source terminal` and `--source auto` using the absolute helper path.
    - (Cycle 1: this call succeeded and silently returned `source: terminal`.)

17. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source auto --limit 40 --json`
    - Receipt `2994F389-EF26-4D7A-A3F9-BBB65F223DB6`: succeeded with `source: terminal`, `archived: false`, `fallbackReason: provider_transcript_not_pinned`. Live TUI text still noisy (spinners, separators, collapsed words). Chrome-stripping is archive-time, not live.

18. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source terminal --limit 80 --json` and `--cursor 0 --limit 80`
    - Receipts `C7D7ECC0-408C-4837-B082-7486CF535A30` (live tail) and `9D95847C-23D1-4C9A-8695-CF5E593B1AD1` (live `--cursor 0`). The cursor-0 page showed the injected preamble.
    - Preamble now inlines the absolute CLI and forbids a bare `orchard`:
      - “Your Orchard CLI is exactly this command, and it is also exported into this terminal as `$ORCHARD_CLI_COMMAND`: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard`”
      - “Run it verbatim, path and all. Do NOT shorten it to a bare `orchard` (your login shell has no PATH entry for it …)”
      - Example lifecycle lines all start with that absolute path (`send`, `ask`, `check`).
    - Worker PTY env (PID 56958, `/opt/homebrew/bin/claude`) confirmed `ORCHARD_CLI_COMMAND=/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` and `ORCHARD_TERMINAL_HANDLE=term_f91112a8-b4ac-48a4-96a8-5bf6bee5ee77`.

19. Scratch-file verification on the owned worktree (read-only; not an orchard mutation):
    - `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t38-20260824/orchard-dogfood-scratch.txt` existed, `wc -l = 1`, 30 bytes, content `Orchard dogfood T38 completed` plus a single LF (`cat -e` showed `$`). `git status --short` showed only `?? orchard-dogfood-scratch.txt`.

20. `/Users/dkkang/dev/damson-ide/.build/release/orchard check --run run_f5d0ac1382b4 --wait --types worker_done,escalation,question --timeout-ms 60000 --json`
    - Receipt `9CF2A925-63FE-406F-AD82-0F438968629A`: delivery `delivery_94fff84e75b4` with one `worker_done` (`msg_3d0f001d4799`), outcome `succeeded` for `task_a2cfa1d1dcd0` / `ctx_c6ed09a10232`.
    - Worker body: appended the expected line with `printf`, verified 1 line / 30 bytes / exact content / trailing `\n` / no CR, git status only the untracked scratch file, no source edits, no commit.
    - Terminal evidence that the preamble path was used, not a PATH lookup and not `orca`:
      `Bash(/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard send --from term_f91112a8-b4ac-48a4-96a8-5bf6bee5ee77 --dispatch-capability dcap_xSXDI…)`
      then a settled `worker_done` object. No `command not found`. Elapsed from dispatch 15:20:01 to `worker_done` 15:20:29.

21. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source transcript --limit 20 --json` (after `worker_done`, before release)
    - Receipt `3D586901-7BEA-4008-8F8A-933C5129945C`: again typed `transcript_unavailable` / `provider_session_unavailable`, `archived: false`.

22. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source auto --limit 5 --json`
    - Receipt `579FA4E6-2474-44D2-8C67-48972FEF54DB`: `source: terminal`, `archived: false`, `fallbackReason: provider_transcript_not_pinned`.

23. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-release --dispatch ctx_c6ed09a10232 --json`
    - Receipt `57315338-DC0E-4795-8F66-6978BC7F4056`: `state: released`, `processAction: closed_agent_terminal`, archive `captured` from terminal with **`rawLineCount: 630`, `readableLineCount: 206`**.

24. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source transcript --limit 20 --json` (after release)
    - Receipt `256539E2-2927-4A53-94FC-2FB0A1A0C745`: typed `transcript_unavailable`, now `archived: true`, same reason `provider_session_unavailable`. Still does not pretend the archive is a transcript.

25. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source auto --limit 40 --json`
    - Receipt `E7E94E79-1994-46F2-A55D-9D90117A2186`: `archived: true`, `source: terminal`, `fallbackReason: provider_session_unavailable`, `raw: false`, `totalLines: 206`.
    - `chromeStripped`: `{blankLines: 2, capturedLineCount: 630, duplicateLines: 87, escapeRemnantLines: 0, readableLineCount: 206, separatorLines: 59, spinnerLines: 276}` (2+87+206+59+276 = 630).
    - Warning: `Readable text was reconstructed from a TUI repaint stream; 424 of 630 captured lines were chrome. Use --raw for the untouched capture.`
    - Readable face still contains collapsed words and leftover banner/statusline fragments (see finding 4 remainder).

26. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source auto --raw --limit 20 --json`
    - Receipt `06212599-13A6-41D7-A4F9-0C750A9A16E7`: `raw: true`, separators and spinner frames present (`✢ Cascading…`, `───` rules). Untouched capture is recoverable.

27. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-show --dispatch ctx_c6ed09a10232 --json`
    - Receipt `CB6F8FEB-4331-4F66-82AF-70251AC25005`: dispatch `completed`, worker `succeeded`, terminal missing, resource `released` with captured archive (630/206).

28. `/Users/dkkang/dev/damson-ide/.build/release/orchard check --run run_f5d0ac1382b4 --ack delivery_94fff84e75b4 --json`
    - Receipt `74CEB1FC-DEE0-410C-82D9-C5A878BD581E`: acknowledged once, `duplicate: false`, no additional messages.

29. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree rm --worktree 'db25c3b8-4da6-45f3-b59d-cf47f2cbff87::/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t38-20260824' --json`
    - Receipt `C6EBC91A-E9E2-4A53-BF9B-5C2A19993554`: safely refused with typed `worktree_dirty`, `1 uncommitted file will be discarded`. Intended preflight for the scratch artifact.

30. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree rm --worktree 'db25c3b8-4da6-45f3-b59d-cf47f2cbff87::/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t38-20260824' --force --json`
    - Receipt `5D628C5C-851F-4E9A-A324-16103B338F83`: `removed: true`. Disk path gone.

31. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree show --worktree dogfood-t38-20260824 --json`
    - Receipt `C33A386E-B324-468C-84CB-4BE14E547C4A`: typed `unknown_worktree`.

32. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_c6ed09a10232 --source auto --limit 5 --json` and `--source terminal --limit 3 --json` after worktree deletion
    - Receipts `881B1634-5F9F-4664-A097-24C010C240E6` and `D36EEC43-84C2-4F49-9D67-2B065CEA1625`: archive still served (`archived: true`, worker `succeeded`, 206 readable / 630 raw). `--source terminal` on an archived worker also serves the chrome-stripped face unless `--raw`.

## Finding-by-finding comparison against cycle 1

| # | Cycle 1 finding | Cycle 2 status | Evidence |
|---|-----------------|----------------|----------|
| 1 | `worker-start --agent claude` failed with `unknown engine: claude` after creating a worktree/dispatch that the caller had to clean up. `agent-context` did not enumerate engines. | **Fixed** | `--agent claude` ready at `input_accepted` (receipt `00121624-1295-41F7-B0E5-200BA3D782EB`); terminal engine `claude-code`; `agent-context` lists `claude` as an allowed value. Failed-start rollback was not re-tested because the alias no longer fails. |
| 2 | Injected preamble used bare `orchard`; not on PATH; worker’s first literal attempt was `command not found`; fallback through `orca` was rejected; settlement required discovering the release binary. | **Fixed** | Preamble inlines `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` as `$ORCHARD_CLI_COMMAND` and tells the worker not to shorten it. Worker PTY env has that absolute path. Terminal shows `Bash(<absolute-helper>/orchard send …)` and `worker_done` settled in 28s with no `command not found`. |
| 3 | `worker-read --source transcript` succeeded but returned `source: terminal` (`provider_transcript_not_pinned` live, `provider_session_unavailable` after release). | **Fixed** (honest) | Live and post-release `--source transcript` fail typed `transcript_unavailable` with reason + `availableSource` + working `nextCommands`. `--source auto` still substitutes and names `source`/`fallbackReason`. There is still **no provider transcript** for Claude; the lie is gone, the transcript itself is not. |
| 4 | Terminal archive noisy/corrupted for a TUI agent (spinners, separators, collapsed words such as `Sentworker_donewith--outcome succeeded`). | **Partially fixed** | Archive now has two faces: chrome-stripped default (630→206; 276 spinner / 59 separator / 87 duplicate) and `--raw`. Warning discloses reconstruction. Readable text still collapses words (`orchardsend`, `OrcharddogfoodT38completed$`) and keeps banner/statusline fragments (`Updateavailable!Run:brewupgradeclaude-code@latest`, `Tipsforgettingstarted`). Live `--source auto` is still a raw TUI stream. |
| 5 | `orchard status --help` rejected as unknown flag. | **Fixed** | `status --help`, `worker-start --help`, `worker-read --help`, `worktree --help`, `send --help` all print the command spec. |
| 6 | Bare `orchard guide` errored with a usage line instead of listing topics. | **Fixed** | Bare `orchard guide` prints `orchestration`. |

## New findings

1. **`orchard send` human output is a Swift debug dump.** The worker invoked the preamble `send` without `--json`. The terminal captured `object(["type":OrchardProtocol.JSONValue.string("worker_done"),"count":OrchardProtocol.JSONValue.number(1.0), "lifecycle":OrchardProtocol.JSONValue.object([…])])` rather than JSON or a readable summary. The mutation itself succeeded (`status: settled`); this is formatter quality, not a settlement bug.

2. **`worktree rm` leaves the git branch.** After `--force` removed the Orchard worktree and disk path, local branch `daekeun-kang/dogfood-t38-20260824` remains in `/Users/dkkang/dev/damson-ide`. Cycle 1 left `daekeun-kang/dogfood-t34-20260823` and `daekeun-kang/dogfood-t34-retry-20260823` the same way; it was not recorded then. The checkout is gone; the branch is not.

3. **`--help` still does not enumerate engine ids.** Discoverability moved into `agent-context` `allowedValues` (fixed for agents). Interactive `--help` still says only `Agent engine id or alias`. Minor leftover of cycle-1 finding 1.

## Safety and cleanup verification

Pre-cycle snapshot (not touched):

- Worktrees: `cc-rate-widget`, `CAN-debugger-hw`, `damson-ide` primary checkouts only.
- Terminals: `term_baeb964d-…`, `term_a27e6af4-…`, `term_bc1aeed8-…`, `term_8cfa3ae4-…`.

Post-cycle snapshot (receipts `5E151631-2A5F-41EE-A99A-09C3057261F1` / `83F89348-086E-406A-80E2-BED0E4831B2D`): the same three worktrees and the same four terminals. The only resources addressed were those created by dispatch `ctx_c6ed09a10232` (`dogfood-t38-20260824` / `term_f91112a8-b4ac-48a4-96a8-5bf6bee5ee77`).

- Worker terminal released through `worker-release`, not closed ad hoc.
- Dirty-worktree deletion attempted without `--force` first; Orchard refused and reported the one scratch file. Only then was the exact owned worktree removed with `--force`.
- Archive reads continued to work after both release and worktree deletion.
- No damson-ide source file was modified during the cycle. The leftover git branch was recorded, not deleted.

## Cycle 1 items deliberately not re-run

- The failed `--agent claude` launch and its `worker-abandon` / residual-worktree cleanup path. T35 promised rollback or exact `cleanupCommand`s; that path is unproven in cycle 2 because the alias now works.
- Cycle 1’s 60s `check --wait` timeout (the worker finished in 28s; the first wait returned `worker_done` immediately).
