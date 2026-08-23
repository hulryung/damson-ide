# Orchard dogfood cycle 1 (T34)

Date: 2026-08-23 (Asia/Seoul)  
Runtime: live Orchard app, runtime `rt_b6f2f28e-d025-46d9-ab25-3726eda940d3`  
CLI: `/Users/dkkang/dev/damson-ide/.build/release/orchard`  
Result: completed. A Claude worker performed the real scratch-file task, sent `worker_done`, its terminal was archived/released, and both Orchard-created worktrees were removed.

## Command log and receipts

All commands below used only the specified release `orchard` CLI against the app runtime. Receipt IDs are included where the CLI returned them.

1. `/Users/dkkang/dev/damson-ide/.build/release/orchard --help`
   - Printed the top-level command list. `worker-start`, `worker-read`, `worker-release`, `worktree`, and the orchestration verbs were present.

2. `/Users/dkkang/dev/damson-ide/.build/release/orchard guide`
   - Failed with usage: `orchard guide list | orchard guide get orchestration [--json]`.
   - Quirk: the top-level help says only “Read an embedded version-matched guide”; invoking the verb without arguments is an error rather than listing topics.

3. `/Users/dkkang/dev/damson-ide/.build/release/orchard guide get orchestration`
   - Returned the embedded orchestration guide, including the required `check --wait --types worker_done,escalation,question` loop, acknowledge-after-processing rule, and release/archive guidance.

4. `/Users/dkkang/dev/damson-ide/.build/release/orchard status --help`
   - Failed with `orchard: unknown flag --help for status`.
   - Quirk: subcommands do not accept the conventional `--help`; the remaining commands in that shell chain were therefore not run.

5. `/Users/dkkang/dev/damson-ide/.build/release/orchard agent-context`
   - Returned the complete JSON command schema (2,086 lines in this build). This was used to discover exact flag names. The shell display truncated it, but the command completed successfully.

6. `/Users/dkkang/dev/damson-ide/.build/release/orchard agent-context --json | jq '.commands[] | select(.name=="worker-start" or .name=="worker-read" or .name=="worker-release" or .name=="worktree")'`
   - Confirmed `worker-start --task --repo --name --agent --base-branch --setup --timeout-ms`, `worker-read --dispatch --source`, `worker-release --dispatch`, and `worktree ... rm --worktree [--force]`.
   - Quirk: the schema describes `--agent` only as “Agent type” and does not enumerate accepted values.

7. `/Users/dkkang/dev/damson-ide/.build/release/orchard status --json`
   - Receipt `9889A2D5-330B-4DDE-8646-A40048E102A4`: `ok: true`, `status: ready`, `mode: app`, PID 4851.

8. `/Users/dkkang/dev/damson-ide/.build/release/orchard repo list --json`
   - Receipt `3C74C1FB-C37A-4548-B2C8-49E87B3B7F93`: three repos; `/Users/dkkang/dev/damson-ide` was already registered as `db25c3b8-4da6-45f3-b59d-cf47f2cbff87` with base `origin/main`.

9. `/Users/dkkang/dev/damson-ide/.build/release/orchard repo add --path /Users/dkkang/dev/damson-ide --json`
   - Receipt `D9065633-033B-450D-B76A-7CFD7C98AA64`: idempotently returned the existing repo record; count did not increase.

10. `/Users/dkkang/dev/damson-ide/.build/release/orchard repo list --json`
    - Receipt `E92D3234-433D-4289-BD31-D3B2A4165211`: still three repos and the same damson-ide ID.

11. `/Users/dkkang/dev/damson-ide/.build/release/orchard run-create --objective 'Dogfood T34: have a Claude worker append one line to a scratch file and report completion' --json`
    - Receipt `47FF37CD-0C59-4881-BAF1-38F4FA158D6F`: created `run_b072e7fb2258`; coordinator handle and pane key were both the synthetic value `cli`.

12. `/Users/dkkang/dev/damson-ide/.build/release/orchard task-create --run run_b072e7fb2258 --task-title 'Append one scratch line' --spec 'In your Orchard-managed worktree, append exactly one line containing "Orchard dogfood T34 completed" to orchard-dogfood-scratch.txt, then verify the file and report succeeded. Do not edit any existing project source, do not commit, and follow the injected lifecycle instructions exactly.' --json`
    - Receipt `FB73CD62-1532-4507-B761-A135EB1F5D6E`: created ready task `task_7e931a8b2419`.

13. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-start --task task_7e931a8b2419 --repo db25c3b8-4da6-45f3-b59d-cf47f2cbff87 --name dogfood-t34-20260823 --agent claude --base-branch origin/main --setup skip --timeout-ms 120000 --json`
    - Receipt `425950FC-70CF-41CD-8838-50AE2B466E65`: failed with typed `worker_start_failed` at `terminal_create`, `unknown engine: claude`.
    - It had already created worktree `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t34-20260823`, and returned dispatch `ctx_8e498b20be34` plus that residual resource.

14. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-show --dispatch ctx_8e498b20be34 --json`
    - Receipt `B7A2C865-FA62-4FA1-99A4-3F564EB30604`: confirmed failed/unattached state, no terminal, and the single residual worktree.

15. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-abandon --dispatch ctx_8e498b20be34 --json`
    - Receipt `0639B0D5-7E91-4021-8CDB-C937AAEEFC76`: marked the failed worker abandoned and correctly retained the possibly-live residual worktree rather than deleting it automatically.

16. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree show --worktree dogfood-t34-20260823 --json`
    - Receipt `D112B1CA-F153-43D4-8C86-EF5192C80859`: resolved the exact Orchard-owned worktree and instance `B34AC6C4-F152-4B07-B8D0-F2C1487BD2A2`.

17. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree rm --worktree 'db25c3b8-4da6-45f3-b59d-cf47f2cbff87::/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t34-20260823' --json`
    - Receipt `798FAD92-4AC0-4BBF-B59B-7810601F8A1C`: `removed: true`.

18. `/Users/dkkang/dev/damson-ide/.build/release/orchard task-list --run run_b072e7fb2258 --json`
    - Receipt `D4A32D3A-BCBD-44F8-B018-EE830764713C`: first task was durably `failed` after the launch failure.

19. `/Users/dkkang/dev/damson-ide/.build/release/orchard task-create --run run_b072e7fb2258 --task-title 'Append one scratch line (retry)' --spec '<same trivial spec>' --json`
    - Receipt `1C538199-E068-4D70-B6CF-03835DC2D52F`: created ready task `task_f08c3313953e`.

20. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-start --task task_f08c3313953e --repo db25c3b8-4da6-45f3-b59d-cf47f2cbff87 --name dogfood-t34-retry-20260823 --agent claude-code --base-branch origin/main --setup skip --timeout-ms 120000 --json`
    - Receipt `B2CB2830-3071-49F2-981B-30E0C64BA8AE`: ready at `input_accepted`; created dispatch `ctx_0931b123463e`, worktree `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t34-retry-20260823`, and owned terminal `term_0cc6eaa9-c85a-4d6c-9d49-ed4d5528bbe2` with engine `claude-code`.

21. `/Users/dkkang/dev/damson-ide/.build/release/orchard check --run run_b072e7fb2258 --wait --types worker_done,escalation,question --timeout-ms 60000 --json`
    - Receipt `08F59639-920E-44A0-AE2F-410145651C78`: timed out normally with zero messages after 60 seconds. No hang; the long poll returned a typed `timedOut: true` result.

22. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-show --dispatch ctx_0931b123463e --json`
    - Receipt `FE887C05-EBDE-4785-9E8C-019CB00D2B5B`: exact worker live, terminal connected and idle, dispatch still `dispatched`.

23. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_0931b123463e --source terminal --limit 100 --json`
    - Receipt `D6DABC06-FD71-4AC6-BA3C-88CD3EA1911E`: returned 100 live terminal lines with cursor 1102. Output was readable enough for diagnosis but contained heavily fragmented TUI spinner/status text.

24. `/Users/dkkang/dev/damson-ide/.build/release/orchard check --run run_b072e7fb2258 --wait --types worker_done,escalation,question --timeout-ms 60000 --json`
    - Receipt `9A678269-7161-44CA-8916-F06615A6B936`: returned delivery `delivery_3300be4a2f10` with one `worker_done` (`msg_27e9386a94ec`), outcome `succeeded` for `task_f08c3313953e` / `ctx_0931b123463e`.
    - Worker reported exactly one scratch line, `wc -l = 1`, one grep match, trailing newline present, only the untracked scratch file in git status, no source edits, and no commit.

25. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_0931b123463e --source transcript --limit 40 --json`
    - Receipt `2A66ABA6-2B69-469D-B7C1-F5AE3598A326`: succeeded before release, but returned `source: terminal`, `archived: false`, and `fallbackReason: provider_transcript_not_pinned` rather than a provider transcript.

26. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-release --dispatch ctx_0931b123463e --json`
    - Receipt `605CA56B-7CD1-477C-ABFF-850EC34C1128`: state `released`, process action `closed_agent_terminal`, archive `captured` from terminal.

27. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_0931b123463e --source transcript --limit 40 --json`
    - Receipt `5C7DCF31-9D47-4D17-88C7-D7B8599473F9`: archive remained readable after terminal close (`archived: true`, 1,594 total lines), with `fallbackReason: provider_session_unavailable` and `source: terminal`.

28. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-show --dispatch ctx_0931b123463e --json`
    - Receipt `D47C11CF-FB28-4B57-9C97-B020D7ED9939`: dispatch completed, worker succeeded/settled, terminal missing as expected, terminal resource released with captured archive.

29. `/Users/dkkang/dev/damson-ide/.build/release/orchard check --run run_b072e7fb2258 --ack delivery_3300be4a2f10 --json`
    - Receipt `B7B5F3A9-EC7E-404E-B00A-F6E40585C867`: acknowledged once, `duplicate: false`, no additional messages.

30. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree rm --worktree 'db25c3b8-4da6-45f3-b59d-cf47f2cbff87::/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t34-retry-20260823' --json`
    - Receipt `B7CCA90B-91FB-45B8-92FB-D891E8C53C06`: safely refused with typed `worktree_dirty`, `1 uncommitted file will be discarded`. This was the intended deletion preflight for the real scratch artifact.

31. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree rm --worktree 'db25c3b8-4da6-45f3-b59d-cf47f2cbff87::/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t34-retry-20260823' --force --json`
    - Receipt `7CA8AEB5-2C94-48D1-88E4-110452EFCB7A`: `removed: true`.

32. `/Users/dkkang/dev/damson-ide/.build/release/orchard worktree show --worktree dogfood-t34-retry-20260823 --json`
    - Receipt `C0C3F491-71B3-4E70-B15C-E95CAF377668`: typed `unknown_worktree`, confirming deletion.

33. `/Users/dkkang/dev/damson-ide/.build/release/orchard worker-read --dispatch ctx_0931b123463e --source transcript --limit 5 --json`
    - Receipt `01905864-2ECF-4191-BCB5-160F4B42198C`: archive still served after worktree deletion (`archived: true`, worker `succeeded`, five lines returned from 1,594).

## Bugs and product findings

1. **Advertised Claude spelling fails.** `worker-start --agent claude` created a worktree and dispatch, then failed at terminal creation with `unknown engine: claude`. The accepted spelling is `claude-code`, but `agent-context` does not enumerate allowed values. This is both a discoverability problem and a partial-effects path that every caller must clean up.

2. **Injected lifecycle commands can be unavailable to the worker.** The Claude worker reported that the injected preamble used bare `orchard`, but `orchard` was not on its PATH. Its first literal attempt failed with `command not found`; a fallback through `orca orchestration send` was rejected with `run_required`; it finally succeeded only by discovering and using `/Users/dkkang/dev/damson-ide/.build/release/orchard`. A worker following the preamble literally can stall before settlement.

3. **Requested transcript silently falls back to terminal capture.** `worker-read --source transcript` succeeded but returned `source: terminal`; before release the reason was `provider_transcript_not_pinned`, and after release it was `provider_session_unavailable`. The archive works, but callers asking specifically for a transcript do not receive one.

4. **Terminal archive text is noisy/corrupted for a TUI agent.** The returned archive contains spinner frames, separators, prompt chrome, and collapsed words (for example `Sentworker_donewith--outcome succeeded`). It is useful as raw evidence but poor as a readable transcript.

5. **No conventional subcommand help.** `orchard status --help` is rejected as an unknown flag. Exact usage is discoverable through `agent-context`, but this is surprising and makes interactive recovery harder.

6. **Guide discovery is terse.** Bare `orchard guide` errors with a usage line instead of listing available guide topics. `orchard guide get orchestration` itself worked.

## Safety and cleanup verification

- No pre-existing terminal or worktree was addressed or modified.
- The only terminals/worktrees touched were those created by dispatches `ctx_8e498b20be34` and `ctx_0931b123463e`.
- The first failed launch's residual worktree was resolved by its exact Orchard ID before deletion.
- The successful worker terminal was released through `worker-release`, not closed ad hoc.
- Dirty-worktree deletion was attempted without `--force` first; Orchard refused and reported the one scratch file. Only then was the exact owned worktree removed with `--force`.
- Archive reads continued to work after both release and worktree deletion.
- No damson-ide source file was modified during the cycle.
