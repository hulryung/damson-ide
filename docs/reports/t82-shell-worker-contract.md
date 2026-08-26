# T82 — a shell worker can act on its contract (2026-08-26)

Filed by T80's live verification: `worker-start --agent shell` typed the agent preamble
into the pane **as shell input**. The preamble's first apostrophe opened a quote, zsh
dropped to its `quote>` continuation prompt, and the whole paste — the live dispatch
capability with it — sat in pending input. The worker could never run its task, never
send `worker_done`, and only a manual `terminal send --interrupt` got the shell back.
Reproduced on a local pane (`ctx_eb6d9a19b29f`) and a remote one (`ctx_b7e58459c0f6`).

## The fix

`worker-start` now chooses the *shape* of the dispatch input from the engine, not from
the caller. `AgentEngineRegistry` already knows which engines run a long-running TUI;
everything else has a shell prompt behind it, and prose cannot be typed into a shell
prompt.

| Engine | `dispatch_input` mode | What lands in the pane |
|---|---|---|
| claude-code, codex, grok, cursor-agent | `preamble` (unchanged) | the contract as a prompt |
| shell, supervised | **`shell-contract`** (new) | one executable line that saves + prints the contract |
| shell, automation fire | `shell-command` (T60) | one executable line that runs the spec and reports its exit status |

`Sources/OrchardRuntime/Orchestration/ShellWorkerContract.swift` builds the new line. It
exports the dispatch identity (`ORCHARD_CLI_COMMAND`, `ORCHARD_WORKER_HANDLE`,
`ORCHARD_TASK_ID`, `ORCHARD_DISPATCH_ID`, `ORCHARD_DISPATCH_CAPABILITY`), writes the
contract to `$ORCHARD_DISPATCH_CONTRACT` with mode 600, prints it, and returns the
prompt. The contract itself is the ordinary worker preamble with
`DispatchPreamble.WorkerKind.bareShell` — a kind that existed and had never been wired —
under a short header saying how it arrived and what is already exported, so
`worker_done` is a one-liner that needs nothing retyped out of the scrollback.

Two properties are structural rather than hoped for:

- **Quote-balanced for any contract text.** The document rides inside one single-quoted
  assignment, every apostrophe rewritten to the `'\''` idiom (T60's `singleQuoted`).
- **Newline-free.** Real newlines are encoded for `printf '%b'` (backslashes escaped
  first, so no `\c` or `\0` can survive from the text itself). A document embedded with
  its real newlines would still be balanced, but a pane without bracketed paste would
  submit it line by line and sit at `quote>` until the closing quote arrived — the exact
  state this task exists to make impossible, even transiently.

## What live verification then found: a second, older defect

The first live run stranded the pane anyway — at the same `quote>` prompt, with the
contract cut off mid-word. The cut is at **1024 bytes**: `MAX_CANON`. A pane's shell only
puts the tty in raw mode while its line editor is reading; during startup files (and
between commands) the tty is in **canonical mode**, where anything past `MAX_CANON` is
silently dropped. So a multi-kilobyte injection into a shell that has not taken the tty
back loses its tail — its closing quote with it — whatever the payload says.

This is not new to T82: the old preamble, and any long T60 automation line, had the same
exposure. What made it invisible is that `agent_readiness` asked the wrong question. The
generic detector answers "has this pane stopped painting", and a shell running its
startup files is exactly as quiet as one waiting at a prompt.

So the shell-engine launch path now asks the shell to *answer*:

1. **`agent_readiness`** — for a bare shell, `tui-idle` is replaced by a handshake:
   `printf 'orchard-shell-ready %s\n' '<nonce>'`. The `%s` is in the format and the nonce
   is in the argument, so the command's **output** is a string its echo cannot produce —
   seeing it is proof the shell *ran* the line. Probes repeat until the deadline, because
   the interesting failure is a probe that was never read.
2. **`dispatch_input`** — the contract line ends with the same marker printf, so it only
   prints if the shell reached the end of the line. Each offer is verified; a failed one
   is cleared with an interrupt (the manual recovery T80 performed by hand) before the
   next, which finds a settled shell. The interrupt runs on the last attempt too: if the
   stage fails, it fails with an empty prompt behind it.

A `ready` receipt for a shell worker now means the pane ran the contract to its end.
A pane that swallowed it fails the stage with a typed reason and a full residual receipt
instead of being handed to a coordinator whose worker can never answer.

## Live verification

Against a headless runtime built from this branch (`orchard serve`, its own data dir; the
Orchard app was never launched or quit). No interrupt was sent by hand at any point — the
only inputs were `worker-start`'s own probes, the task, and the report.

| Step | Local | Remote (`ssh:orchard-loopback`) |
|---|---|---|
| `worker-start --agent shell` | ok, **2.1 s**, `state: ready`, `stage: input_accepted` | ok, **2.2 s**, same |
| `dispatch_input` mode | `shell-contract` | `shell-contract` |
| pane after delivery | full contract printed, back at `❯` | full contract printed, back at `❯` with the 🌐 host indicator |
| contract saved | `$ORCHARD_DISPATCH_CONTRACT`, 128 lines, mode 600 | same, on the far side |
| task run in the pane | `TASK-DONE 0d22c72 initial` | `FAR-SIDE Daekeuns-MacBook-Pro.local pid=99833 pwd=/Users/dkkang/Orchard/worktrees/remote/t82-remote` |
| `worker_done` **from inside the pane**, using only the exported variables | `status: settled`, `outcome: succeeded` | same, over the tunnel |
| dispatch after settlement | `worker.state succeeded`, `dispatch.status completed` | same |
| `worker-release` | `released` / `closed_agent_terminal` / archive `captured` | `released` / `closed_remote_connection` / archive `captured` |

Dispatches: local `ctx_f0f356d9c76d`, remote `ctx_bce44f8742dd`.

Gates: `swift build`, `swift test` (**1243 tests, 0 failures**, 2 skipped),
`swift build -c release`, and `scripts/e2e-headless.sh` — **PASS**, including the
automation-fired shell stage, which now goes through the same readiness handshake.

Teardown: the remote worktree this run created was removed on the host
(`worktree rm --force` → `removed: true`), the remote repo view was unregistered with
`repo remove --forget` (T79) — the far side's repo is still there, `ed1b6e1 initial` — the
local worktree and repo rows were removed, and the harness runtime was stopped. The app's
own data directory was never written to; everything ran under `ORCHARD_DATA_PATH`.

## Notes for whoever reads this next

- `scripts/e2e-headless.sh` still pokes shell panes to force readiness. That hack is now
  redundant for `worker-start --agent shell` — the verb supplies its own readiness
  evidence — but the script also pokes automation-fired panes, so it was left alone.
- A shell worker is told to **exit** after `worker_done`, not to idle: `worker-start
  --terminal` refuses a pane with no agent, so a shell pane genuinely cannot be re-adopted
  for a fresh dispatch, and telling it to wait would leave it waiting for input that can
  never arrive.
- The capability now reaches the pane in three places, all of them post-submission: the
  executed line, the mode-600 file, and `$ORCHARD_DISPATCH_CAPABILITY`. It is never in
  un-submitted input in any interleaving, which is the invariant T60 established for
  automation fires and this extends to supervised ones.
