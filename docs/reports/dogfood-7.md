# Orchard dogfood cycle 7 (T81)

Date: 2026-08-26 (Asia/Seoul), 20:43–20:54 KST (11:43–11:54 UTC)
CLI: `/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard` (`orchard 2.0.0-dev`, SHA-256 `61ddf7272a5cecb38f15f8d9d0db142baf0e1fa38075fbf8e897dd54ef651002`, 10,215,480 bytes, mtime 2026-08-26 20:32 +0900 — byte-identical to `/Users/dkkang/dev/damson-ide/.build/release/orchard`). `repo --help` documents `repo remove --forget` / `forget_local_refused`; `worker-read --help` names `hasOlder`; `conflicts` lists `list|show|take|resolve|stage`; `project` and `worktree` subverbs are first-class. The binary therefore carries T72–T80.
Runtime: live Orchard app, `rt_fb3c96e6-0c3a-4653-a204-5dfc1992ddb2`, PID 10847, started 2026-08-26 20:32:49 KST — the same runtime id and PID answered every call in this cycle; the app was never launched, driven, or quit.
SSH harness: host `orchard-loopback` (`127.0.0.1:2222`) — `host check --name orchard-loopback` → `reachable` (113 ms at the start of the cycle, 45 ms at the end).
Source at HEAD of this worktree: `1600b53` (T80 live verification + T82 filed). Last source commits: `98cd21a` (T80 merge), `ac9a646` (T79 merge).

Result: the local Claude cycle settled in 18 s and archived with `respacedLines: 0`. A remote supervised cycle against a repo registered on `orchard-loopback` probed **ready** (far-side `orchard status --json` reached *this* runtime), created a pane on `ssh:orchard-loopback`, and settled `worker_done` over the tunnel. `repo remove --forget` unregistered that view; over ssh the far side's three git worktrees, directory inodes, and the scratch file were untouched. Every wave-19–21 item in scope held (byte-exact `conflicts take` on a 768-byte binary, non-UTF-8 `file preview` with typed save refusal, `once` fires once and auto-disables, typed exits 1 / usage 64, `hasOlder`, `project` / `worktree` subverbs). **T82 still holds live:** `worker-start --agent shell` pastes the dispatch preamble as shell input, so the remote pane opened a quote and sat in continuation until `--interrupt`.

Everything went through the CLI. The only terminals and worktrees Orchard created for me are gone; the three foreign terminals (`term_af906bb9-…` local on cc-rate-widget, `term_287d3904-…` / `term_13377d46-…` leftover remote panes) were never touched. Final state matches baseline: 3 repos, 3 primary worktrees, 3 foreign terminals, 0 automations, `~/Orchard/worktrees/` holding only the pre-existing `repo/` container.

## Cycle 7 vs cycle 6

| Area | Cycle 6 (T69) | Cycle 7 (T81) |
|---|---|---|
| Full `--agent claude` cycle | ready 5 s, settled 16 s, `respacedLines: 0` | **Holds**: ready 6 s, settled 18 s, 250 raw / 166 readable, `respacedLines: 0`, 0 damage shapes |
| Remote supervised cycle | out of scope (`remote_unsupported`) | **New**: probe **ready**; dispatch `ctx_0a86244b0c01` on `ssh:orchard-loopback`; `worker_done` from the far-side CLI settled this runtime; release `closed_remote_connection` |
| `repo remove --forget` | no verb; remote rows had to be pruned by hand | **Works**: ordinary remove `repo_in_use` naming the three projected remote worktrees; `--forget` drops them with `forgotten: true`, `hostUntouched: true`; ssh inodes unchanged. Local `--forget` → `forget_local_refused` |
| Byte-exact conflict take | **defect** (768-byte binary → 1792 bytes of `EF BF BD`, staged) | **Fixed live via CLI**: `conflicts take --side theirs` on the same 768-byte fixture; working file, `:0`, and `feature:blob.bin` are byte-identical (`b967589ade21`), still 768 bytes, no `EF BF BD` |
| Editor file fidelity | not in scope (decode-then-write still live in Files) | **Holds**: Latin-1 `file preview` returns `content: ""`, `notTextReason: not_utf8`, `byteLength: 42`. `EditorDocument.saveRefusal` for that surface is typed `not_utf8`. Binary with NULs is `nul_bytes` / save `not_text`. UTF-8 notes remain saveable |
| `once` + auto-disable | 8.0 s window, 2× `automation_fire_in_flight`, `enabled: false` | **Holds**: 8.8 s window, 2× `automation_fire_in_flight`, `enabled: false`, `run --id` → `automation_disabled`, second `fire-due` empty |
| Typed-error exit status | 1 (usage 64) | **Holds** across 17 typed probes + 3 usage probes |
| `worker-read hasOlder` | documented, not fielded | **Fielded**: live `--limit 10` → `hasOlder: true`; `--cursor 0` → `false`; default 200 of 250 → `true`. Help names the field |
| `project` / `worktree` subverbs | missing / not first-class | **Present**: `project list\|show\|current`; `worktree show\|current\|create\|set\|rm\|ps` |

## Part 1 — local supervised Claude cycle

Receipt ids are the `id` field of each `--json` envelope; all carried `_meta.runtimeId = rt_fb3c96e6…`. Times UTC (KST = UTC+9).

1. Baseline 11:43: 3 repos (`damson-ide` `db25c3b8-…`, `CAN-debugger-hw`, `cc-rate-widget`), 3 primary worktrees, 3 foreign terminals, 0 automations, `~/Orchard/worktrees/` = pre-existing `repo/`.
2. `run-create` 11:43:12: receipt `2E4CE447-672E-4354-ACDB-56E8D22A0F65`, run `run_fcfbbe900168`, coordinator handle `cli`.
3. `task-create`: receipt `039882B9-1B13-466C-816C-6205689A821C`, task `task_7662c45ed1a6` — write one exact 38-byte line (`T81 dogfood-7 scratch line 2026-08-26\n`), run `cat` / `wc -c` / `git status --porcelain` / `git rev-parse --abbrev-ref HEAD`, do not commit or stage, report the byte count.
4. `worker-start --agent claude --repo damson-ide --name dogfood-t81-20260826 --setup skip --timeout-ms 240000`: 11:43:23 → 11:43:29 (**6 s**), receipt `5E55FF53-4E23-4297-B7D7-B6071146E4A8`, dispatch `ctx_bb5436fa2604`, terminal `term_5c5087b7-e777-4ae1-9357-e363ddebe23d`, worktree `/Users/dkkang/Orchard/worktrees/damson-ide/dogfood-t81-20260826` on `daekeun-kang/dogfood-t81-20260826` at `77be5cf`, effects `worktree created / setup skipped / terminal created (agent) / dispatch_input preamble accepted`, `state: ready`, `stage: input_accepted`.
5. Settlement: `check --run … --wait --types worker_done` receipt `64A2783A-E11F-4BC9-BD97-22E008CA613D`, `count: 1`, delivery `delivery_d778ea9c26af`, one `worker_done` (`msg_88a38f183e8d`, created 11:43:41 — **18 s after `worker-start`**, subject "T81 dogfood-7 scratch file written (38 bytes)", payload `outcome: succeeded`, `filesModified: [orchard-dogfood-t81.txt]`). `worker-show` receipt `8E863B76-216A-42C4-9E2F-730EED030DC8`: dispatch `completed` 11:43:41, `failure_count: 0`, `termination_reason: null`, engine `claude-code`, resource `wtr_2900dd0c06fe` owned, `observation.exactWorker: true`.
6. Independent check of the worker's claim: the file is 38 bytes, ends in exactly one `\n` (xxd tail `…3038 2d32 360a`), content is the exact requested line, `git status --porcelain` shows only `?? orchard-dogfood-t81.txt`, branch `daekeun-kang/dogfood-t81-20260826`. Nothing staged, nothing committed.
7. Live reads (hasOlder — see Part 4): auto `--limit 10` → `hasOlder: true`, `startCursor: 240`, `latestCursor: 250`; default → `hasOlder: true`, 200 of 250, `startCursor: 50`; `--cursor 0 --limit 10` → `hasOlder: false`. `fallbackReason: provider_transcript_not_pinned`, `source: terminal`.
8. Ack: receipt `B2EAF3E0-E11C-44ED-935F-69848E379818`, `duplicate: false`.
9. Release 11:44: receipt `F7B6DAB0-22C5-4680-A88E-47E8058ADB32`, `state: released`, `processAction: closed_agent_terminal`, archive `captured` 250 raw / 166 readable, source `terminal`. `terminal list` afterwards shows only the three foreign handles.
10. Archived reads: cleaned — 166 lines, `chromeStripped` = 32 spinner, 23 separator, 21 duplicate, 8 blank, 0 escape-remnant, **0 respaced** (`capturedLineCount: 250`). Raw default 200 of 250, `hasOlder: true`. Post-release `worker-show`: resource `released/released`, `retainedReason: null`, terminal `null`, observation `missing`, archive `captured`.
11. Cleanup: `worktree rm --force --delete-branch` receipt `0C77F947-9034-4AD5-A378-F7E1D3DCA90F` → `removed`, `branchDeleted`, `branchMerged` all true. `~/Orchard/worktrees/damson-ide/` is **gone**. Re-show → `unknown_worktree`, exit 1; archive still serves 166 lines after deletion. `git worktree list` and `show-ref` in the main checkout have zero `dogfood-t81` entries.

### Archive fidelity spot-check

Over the cleaned (166) and raw (200-of-250 window) faces:

- 0 raw lines in the sampled window were inspected for control bytes beyond the usual TUI chrome; `escapeRemnantLines: 0`, `respacedLines: 0`.
- 0 damage shapes (`Tipsforgettingstarted`, `coorinator`, `Taskcompleteanddispatchsettled`, `terminalhandleis`) in raw or cleaned.
- 0 runs of 16+ letters in the cleaned face (no `subagentPromptCacheTtl` this cycle).
- Ground-truth phrases present in the cleaned face: `Your coordinator's terminal handle is: cli`, `=== TASK ===`, `orchard-dogfood-t81.txt`, `38`, `wc -c`, `worker_done`, `task_7662c45ed1a6`, `ctx_bb5436fa2604`, `term_5c5087b7`.

Not pinned as a fixture (T81 is report-only).

## Part 2 — remote supervised cycle against orchard-loopback

T80 made `worker-start` ask the far side *before* it creates anything:

```
ssh <dest> 'export ORCHARD_CLI_COMMAND=…; export ORCHARD_DATA_PATH=…; <cli> status --json'
```

The two exports are byte-identical to what the pane will carry (T78). The answer must name *this* runtime. The three verdicts are `ready` / `refused` / `unverifiable`.

### 2.1 Independent probe — **ready**

Same command line the start path runs, against `orchard-loopback`:

```
ssh -p 2222 dkkang@127.0.0.1 \
  'export ORCHARD_CLI_COMMAND=/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard;
   export ORCHARD_DATA_PATH=/Users/dkkang/Library/Application Support/Orchard;
   "$ORCHARD_CLI_COMMAND" status --json'
```

Returned `ok: true`, `runtimeId: rt_fb3c96e6-0c3a-4653-a204-5dfc1992ddb2`, `pid: 10847` — **this** runtime. Verdict: **ready**. (`which orchard` on the far side is empty; PATH is irrelevant because the probe uses the absolute CLI path.)

The `worker-start` success envelope does not echo the probe verdict as a field. The evidence it ran and got `ready` is that the call succeeded and created a remote pane rather than returning `remote_unsupported` / `host_unverifiable` *before anything was created*.

### 2.2 Repo registered on the host

Scratch git repo created **over ssh** (so the far side owns it): `/private/tmp/orchard-t81-remote/repo` at `bea277e`, plus two extra git worktrees `wt-a` / `wt-b`.

`repo add --path /private/tmp/orchard-t81-remote/repo --host ssh:orchard-loopback --display-name t81-remote --base-ref main` receipt `82FDFBDE-5A65-4E2A-B38A-F00E561F4536`, repo `acbd2d86-5fcc-465a-91db-5872732aebb0`, `hostId: ssh:orchard-loopback`. `worktree list` then projected all three: `repo` / `wt-a` / `wt-b`.

Ordinary `repo remove` (no `--forget`) receipt `C4DE980E-…` → **`repo_in_use`**, exit 1, naming all three projected worktrees including the primary (`'repo', 'wt-b', 'wt-a'`). That is the wave-21 teardown gap T79 closed.

### 2.3 `worker-start` on an existing remote worktree

`run-create` receipt `EE1283C5-CFCD-450E-90AF-267C58C2809F`, run `run_8ea703b8a554`. `task-create` receipt `6DB16F1A-…`, task `task_cddd6bfd79da`.

`worker-start --agent shell --worktree acbd2d86-…::/private/tmp/orchard-t81-remote/wt-a --setup skip --timeout-ms 120000`: 11:45:48 → 11:45:51 (**3 s**), receipt `3D7F4524-17D0-47BF-A5EB-258A39D85AC2`, dispatch `ctx_0a86244b0c01`, terminal `term_1a06658d-13a4-4b6d-994b-89fc840a5abd`, effects `worktree reused / terminal created (agent) / dispatch_input preamble accepted`, `state: ready`. `worker-show`: `executionHostId: ssh:orchard-loopback`, engine `shell`, title `wt-a`.

Because the placement was an *existing* remote worktree, the probe ran in preflight **before** a dispatch row existed (T80). It was `ready`; the door opened.

### 2.4 T82 still holds — the shell cannot run its task

The remote pane's first screen after injection:

```
❯ >....
```

zsh continuation. The dispatch preamble contains quotes, so it was pasted as shell input and opened a quote. Every later preamble line was echoed, nothing executed. Identical to T80's local reproduction; this is not remote-specific. Filed as T82, still open.

`terminal send --interrupt` (receipt `6BFED67E-2154-41C8-8614-31B6841912AA`, `accepted: true`, 1 byte) restored the prompt. That is how the rest of this cycle finished — the same workaround T80 used.

### 2.5 What crossed the tunnel

| Step | Evidence |
|---|---|
| Probe before creating anything | Independent identical ssh command, and the succeeding `worker-start`, both **ready**. Far side answered `rt_fb3c96e6-…` / PID 10847 |
| Dispatch on a remote worktree | `ctx_0a86244b0c01`, terminal created on `ssh:orchard-loopback` — the placement that answered `remote_unsupported` for eleven waves |
| Preamble delivered | pane holds the full contract: capability `dcap_R8P5_9Ae31V5eGgIhnowJBwJkOpo4uth`, task/dispatch ids, CLI absolute path |
| Five `ORCHARD_*` variables on the far side | `ORCHARD_CLI_COMMAND`, `ORCHARD_DATA_PATH`, `ORCHARD_PANE_KEY`, `ORCHARD_TERMINAL_HANDLE=term_1a06658d-…`, `ORCHARD_WORKTREE_ID=acbd2d86-…::/private/tmp/orchard-t81-remote/wt-a`. Prompt renders `🌐` |
| Far side reached **this** runtime | `orchard status --json` *inside the remote pane* → `rt_fb3c96e6-…`, pid 10847 |
| Typed refusal over the tunnel | far-side `send --type worker_done` without `--outcome` → `invalid_argument`: "worker_done requires outcome=succeeded\|failed for a current Dispatch.", envelope id `7DDC0EC9-4F71-4412-8304-16BC5D6D1497`, `_meta.runtimeId` this runtime — not silently accepted |
| `worker_done` over the tunnel | far-side CLI with `--outcome succeeded` returned `lifecycle.status: settled`. Coordinator `check --wait` receipt `56439131-86E2-42BD-AC70-369DD31E4BCD`, delivery `delivery_2857bf0d4266`, `msg_c3658cb0431e` from `term_1a06658d-…`, payload `outcome: succeeded`. Dispatch `completed` 11:46:54, `failure_count: 0` |
| Independent check of the file | `/private/tmp/orchard-t81-remote/wt-a/orchard-dogfood-t81-remote.txt` is 11 bytes (`T81 remote\n`), `??` in porcelain |
| Release + archive | receipt `CFC2CB63-4B65-498D-9E91-F3BBD4F04B9B`, `released`, `processAction: closed_remote_connection`, 127 raw / 88 readable, `respacedLines: 0`. Warning: "Whether the remote process stopped is unverifiable; loss of contact is not evidence that anything on orchard-loopback stopped." (Rule 2). Terminal list back to the three foreign handles |

Ack receipt `23BF885C-C4EF-4A22-B96B-BAEBAF70169D`, `duplicate: false`.

The remote pane's `worker_done` was authored in that pane after the interrupt. An agent-TUI worker would not have needed the workaround (the preamble is a prompt there, not shell input).

## Part 3 — `repo remove --forget`

After the remote cycle the three git worktrees still existed on the host (release closed the *connection*, not the checkouts). Snapshot over ssh, directory inodes `12436094` (repo) / `12436095` (wt-a) / `12436096` (wt-b), scratch file inode `12453830` still 11 bytes.

`repo remove --repo acbd2d86-… --forget` receipt `BA71F578-977E-4539-9DB6-20D8E4A3B1BF`:

```
forgotten: true
hostUntouched: true
removed: true
droppedWorktrees: [repo, wt-b, wt-a]   # the local projections
```

After:

- `repo list` count 3 (baseline). `repo show acbd2d86-…` → `unknown_repo`, exit 1.
- `worktree list` total 3, all `hostId: local`. `worktree show` of the forgotten `wt-a` id → `unknown_worktree`, exit 1.
- `orchard-data.json` `remoteWorktrees: []`; the `acbd2d86-…` repo row is gone.

Over ssh, **byte-for-byte the same worktree list**, the same three directory inodes, the same scratch file (11 bytes, inode `12453830`). `--forget` dropped Orchard's view and touched nothing on the host.

`--forget` on a **local** repo (`damson-ide`) receipt `FEDB1125-6C8D-4E43-B196-3B08ED0C4D24` → **`forget_local_refused`**, exit 1 in JSON and human:

> cannot forget local repo 'damson-ide': --forget drops the registry view of a remote checkout without touching the host. A local repo's worktrees live on this machine; remove extra worktrees first, then repo remove.

Spelling is `repo remove --forget`, not a `repo forget` subverb — matches the CommandSpec / guide.

The far-side scratch repo was then removed over ssh (`git worktree remove --force` of the two extras, then `rm -rf /private/tmp/orchard-t81-remote`) so this cycle leaves nothing behind. That cleanup is *this worker's*, not `--forget`.

## Part 4 — regression sweep, waves 19–21

Temp local repo `/tmp/orchard-t81-local/repo` (seed `4397b01`), registered receipt `13A4FDDD-C8F4-48FE-A03A-667FC67CD229`, repo `cc44e334-7899-49b8-9f9b-da7e401401c7`. `worktree create --name t81-bin-conflict` receipt `9A8F1926-410F-4E84-89F7-D583FC0687FA` at `/Users/dkkang/Orchard/worktrees/repo/t81-bin-conflict`. Removed at the end.

### 4.1 Byte-exact `conflicts take` on a binary file (T72 / T73)

The dogfood-6 fixture: `blob.bin` = 768 bytes of `00 FF FE 80 C3 28` repeated (seed sha `aeb931caa183`). `main` and `feature` each flipped the last repeating byte (`0x27` / `0x29`). `git merge feature` in the linked worktree:

```
warning: Cannot merge binary files: blob.bin
UU blob.bin
UU latin1.txt
```

`conflicts list` receipt `1BF01A1C-…`: `Merge in progress — 2 conflicted files`, operation `merge`. `conflicts show --path blob.bin` receipt `7C07799B-…`: `readable: false`, `hunkCount: 0`, `hasConflictMarkers: false`, `stages: {}` — no hunks, so take is the only route.

`conflicts take --path blob.bin --side theirs` receipt `79B94B35-09E8-4125-A785-CDCCEAD4A23F`, `staged: true`.

| | bytes | sha256 (12) | head |
|---|---|---|---|
| working file after take | 768 | `b967589ade21` | `00fffe80c329` |
| git `:0:blob.bin` (staged) | 768 | `b967589ade21` | |
| `feature:blob.bin` (theirs) | 768 | `b967589ade21` | |
| `main:blob.bin` (ours, not taken) | 768 | `cddbb06e2a68` | `00fffe80c327` |

`working == theirs == staged`. No `EF BF BD` anywhere. The old code wrote 1792 bytes here. Porcelain `M  blob.bin`; list dropped to 1 file (`latin1.txt`).

**Latin-1 text, same worktree.** Working file still had `caf<E9>` in an untouched header and conflict markers below. `conflicts show` → `readable: false`, `hunkCount: 0`. `conflicts resolve --hunk 0 --choice ours` receipt `7754ED36-…` → **`cannot_read`**: "latin1.txt is not readable as text; use conflicts take --side ours|theirs", exit 1. File **unchanged** (`0xE9` still there, markers still there, no `EF BF BD`). `conflicts take --side theirs` receipt `0A5750C0-…` wrote `header caf<E9> latin1\nline 02\nline 03 THEIRS\n`, byte-identical to `feature:latin1.txt`. List: `fileCount: 0`, headline "all conflicts resolved", next-step "Run `git commit` in a terminal to finish the merge."

(The CLI maps the internal `GitConflictError.not_utf8` onto `cannot_read` for `resolve` when `document()` is nil. The refusal is typed; the file is not rewritten.)

Cosmetic: `conflicts list` reported `hasInlineMarkers: true` for `blob.bin` even though git wrote no markers and `show` said `hasConflictMarkers: false`. Harmless — take still worked.

### 4.2 Editor file fidelity (T75)

`file preview` is accepted by the CLI (it routes to RPC `file-preview`) even though `file --help` only lists `open|diff|open-changed|search`. Live against the conflict worktree after take:

| path | content | isBinary | notTextReason | byteLength |
|---|---|---|---|---|
| `latin1.txt` | `""` | true | `not_utf8` | 42 |
| `blob.bin` | `""` | true | `nul_bytes` | 768 |
| `notes.txt` | `"utf8 notes\n"` | false | null | 11 |

No U+FFFD is handed out as content. A non-UTF-8 open is therefore not an editable buffer — it is a description (`notTextReason` + empty content). `file open` posts a GUI notification and was not used (would have switched the running workbench).

There is no `file save` / `file write` verb. Save refusal lives in `EditorDocument.saveRefusal` (UI-free; the pane calls it on ⌘S). A throwaway `swiftc` of this worktree's `EditorDocument.swift` against `FilePreview` values matching the live receipts:

```
latin1 refusalCode=not_utf8 display=not_utf8 — This file's 42 bytes are not UTF-8 text. Saving would rewrite every byte the editor could not decode, so it was not saved.
blob   refusalCode=not_text display=not_text — This binary file is 768 bytes of content the editor cannot represent as text, so it was not saved.
notes  refusalCode=nil
```

The probe binary was deleted. The GUI pane itself was not driven.

### 4.3 `once` automation fires exactly once and auto-disables

Automation `t81-once` (`auto_6b24ed61-0bac-4ff8-b567-8e68feadf323`) created 11:50:32 (receipt `4984F89A-…`), `trigger once`, `time now`, `provider shell`, `--precheck "sleep 5" --timeout 10`.

1. `due` receipt `BD1E56B7-…`: the one slot, `scheduledAt` 11:50:00.
2. `fire-due` (background) held the claim **11:50:32.1 → 11:50:40.9 (8.8 s)**. Inside it: `run --id` → `automation_fire_in_flight`, exit 1; `due` → `[]`; a second `run --id` → `automation_fire_in_flight` again.
3. `fire-due` receipt `D213C116-…`: one run row `arun_af0b92b7-…`, `outcome: fired`, `message: "once schedule consumed; automation disabled"`, dispatch `ctx_3377ecd02f19`, run `run_f576bcef4cb9`, terminal `term_76c7e260-…`, worktree `…/repo/automation-feadf323-1787745037`.
4. `show` → **`enabled: false`**. `due` → `[]`; a second `fire-due` → `runs: []`; `runs --id` → still 1 row.
5. `automations run --id` on the consumed `once` → **`automation_disabled`**, exit 1 in JSON and human.
6. Settlement: `check --wait --types worker_done` → one `worker_done` "automation command exited 0", `outcome: succeeded`. `worker-show`: dispatch `completed` 11:50:43, worker `succeeded / settled`, engine `shell`, observation `exited`. Release receipt `5003B3B7-…` → `closed_exited_terminal`, 16 raw / 13 readable. `worktree rm --force --delete-branch` → removed, branch deleted.

### 4.4 Typed errors exit 1

Every typed error (`ok: false`) exits **1** in `--json` and human mode; usage errors exit **64**:

| Command | Code | Exit |
|---|---|---|
| `worktree show/rm --worktree nope` | `unknown_worktree` | 1 |
| `worker-show/worker-read/dispatch-show --dispatch ctx_nope` | `dispatch_not_found` | 1 |
| `repo show --repo nope` | `unknown_repo` | 1 |
| `repo remove` without `--repo` | `invalid_argument` | 1 |
| `run-show --id run_nope` / `task-create --spec x` (no run) | `run_not_found` | 1 |
| `automations show/run/edit --id auto_nope` | `automation_not_found` | 1 |
| `automations create --trigger fortnightly` / `--time not-a-time` | `automation_invalid_input` | 1 |
| `automations run --id` ×2 during a fire | `automation_fire_in_flight` | 1 |
| `automations run --id` on a consumed `once` | `automation_disabled` | 1 |
| `repo remove` while remote worktrees projected | `repo_in_use` | 1 |
| `repo remove --forget` on a local repo | `forget_local_refused` | 1 |
| `conflicts resolve` on Latin-1 | `cannot_read` | 1 |
| `conflicts show` without `--path` | `invalid_argument` | 1 |
| `file open` with no path | `not_in_worktree` | 1 |
| `orchard frobnicate`, `worktree list --bogus`, `repo --nope` | usage | 64 |
| `status`, `automations list` | ok | 0 |

### 4.5 `worker-read hasOlder` (T77)

Live stream of the Claude cycle (250 lines in the ring):

| Invocation | `hasOlder` | `startCursor` | `oldestCursor` | `latestCursor` | returned |
|---|---|---|---|---|---|
| `--limit 10` | **true** | 240 | 0 | 250 | 10 |
| default (`--limit` 200) | **true** | 50 | 0 | 250 | 200 |
| `--cursor 0 --limit 10` | **false** | 0 | 0 | 250 | 10 |

`truncated` stayed false in all three (the ring still holds the older lines). Help: "hasOlder is true when lines exist before this window"; "truncated means the requested cursor was below the retained ring … not that hasOlder is true." Cycle-5 finding 11 / cycle-6 finding 12 is closed.

Archived cleaned face of the same dispatch is the whole 166-line document (`hasOlder: false`); archived raw default 200 of 250 still reports `hasOlder: true`.

### 4.6 `project` / `worktree` subverbs (T77)

- `worktree --help` usage is `list|show|current|create|set|rm|ps`. `worktree show` of the conflict worktree returned the record. `worktree set --status in-review` receipt `4C4D593F-…` wrote `workspaceStatus: in-review`. `worktree current --cwd <that path>` resolved `t81-bin-conflict`. `worktree ps --json` → `totalCount: 5` (the three primaries plus the two t81-local worktrees then live). `worktree rm` as above.
- `project --help` usage is `list|show|current`. `project list` count 4 while t81-local was registered (`t81-local` `worktreeCount: 2`). `project show --project t81-local` returned the repo record plus its two worktrees. `project current --cwd <conflict wt>` resolved the same project.

## Findings

| # | Finding | Evidence | Status |
|---|---|---|---|
| 1 | **Local supervised Claude cycle is healthy (5th consecutive dogfood).** Ready 6 s, `worker_done` 18 s after start, one delivery, dispatch `completed`, release `closed_agent_terminal`, worktree + branch removed, `unknown_worktree` on re-show while the archive stays readable. | Part 1 | Verified |
| 2 | **T54 capture holds on a fourth live archive.** 250 raw / 166 readable, `respacedLines: 0`, 0 escape-remnant, 0 damage shapes, 0 16+ letter runs. | Part 1 fidelity | Verified, not re-pinned |
| 3 | **Remote `worker-start` probe is `ready`.** Far-side `status --json` with the pane's `ORCHARD_CLI_COMMAND` + `ORCHARD_DATA_PATH` reached `rt_fb3c96e6-…`. `worker-start` on an existing remote worktree succeeded in 3 s rather than `remote_unsupported`. | Part 2.1–2.3 | T80 holds live |
| 4 | **A supervised remote cycle can settle.** Preamble, capability, far-side CLI, typed `invalid_argument` (missing `--outcome`), then `worker_done` with `--outcome succeeded` all crossed the tunnel into *this* runtime. Release `closed_remote_connection` with Rule-2 unverifiable wording, archive 127/88. | Part 2.5 | Verified (shell worker needed `--interrupt`; see 5) |
| 5 | **T82 still holds: `worker-start --agent shell` pastes the preamble as shell input.** Remote pane sat in `❯ >....` until `--interrupt`. Identical to T80's local reproduction. Automation fires do *not* have this bug (T60 `dispatch-input shell-command`). | Part 2.4 | Open — T82 |
| 6 | **`repo remove --forget` unregisters a remote view without touching the host.** Ordinary remove `repo_in_use` naming the three projections; `--forget` returns `forgotten` / `hostUntouched` / `droppedWorktrees`; ssh worktree list and directory inodes unchanged; scratch file still 11 bytes. Local `--forget` is `forget_local_refused`. | Part 3 | T79 holds live |
| 7 | **Byte-exact `conflicts take` on a binary (dogfood-6 finding 1 closed).** 768-byte UU file: take theirs is byte-identical to `feature:blob.bin` and to staged `:0:`; still 768 bytes; no `EF BF BD`. Latin-1 `resolve` refuses and writes nothing; `take` keeps `0xE9`. | Part 4.1 | T72/T73 hold live |
| 8 | **Non-UTF-8 opens read-only; save refusal is typed (T75).** Live `file preview`: Latin-1 → `not_utf8` + empty content; binary → `nul_bytes`; UTF-8 notes still text. `EditorDocument.saveRefusal` for those surfaces is `not_utf8` / `not_text` / nil. No CLI save verb — the pane was not driven. | Part 4.2 | Verified on the preview/policy path; GUI ⌘S unverified |
| 9 | **`once` + fire-in-flight + `automation_disabled` hold.** 8.8 s claimed window, 2× `automation_fire_in_flight`, auto-disable, second `fire-due` empty, `run --id` refused `automation_disabled`. Shell fire executed and settled `closed_exited_terminal`. | Part 4.3 | No regression from wave 16 |
| 10 | **Typed exits hold.** 17 typed probes exit 1 (including the new `forget_local_refused` / `cannot_read`); usage exits 64. | Part 4.4 | No regression |
| 11 | **`worker-read.hasOlder` is live.** True when the window is not the start of the ring; false at `--cursor 0`; `truncated` stays the ring-eviction flag. Help names it. | Part 4.5 | Cycle-6 finding 12 closed |
| 12 | **`project` and `worktree` subverbs are live.** list/show/current, `worktree set --status in-review`, `worktree ps`, create/rm. | Part 4.6 | T77 holds live |
| 13 | `file --help` does not list `preview`, but `orchard file preview` is accepted and is the only CLI path that returns `notTextReason`. `main.swift` does not validate the file subcommand set the way `conflicts` does. | Part 4.2 | Observation — help drift, not a behavior bug |
| 14 | `conflicts list` reports `hasInlineMarkers: true` for a binary UU file that has no markers (`show` says `hasConflictMarkers: false`). Take still works. | Part 4.1 | Observation — cosmetic |

## Cleanliness

Same runtime id and PID (`rt_fb3c96e6-…`, 10847) before, during, and after; the app was never launched, driven, or quit. Created and removed: 2 orchestration runs (local Claude + remote shell) plus the automation's own run, 2 tasks, 1 Claude worker + its worktree/branch, 1 remote shell worker (worktree *reused*, then forgotten not deleted), 1 remote scratch repo registered then `--forget`'d then deleted over ssh, 1 local temp repo + conflict worktree + 1 `once` automation + its worktree/branch. Final state = baseline (3 repos, 3 primary worktrees, 3 foreign terminals, 0 automations, `~/Orchard/worktrees/` = pre-existing `repo/` only). Probe sources lived under `/tmp/orchard-t81-dogfood` and `/tmp/orchard-t81-{local,remote}` and were deleted.
