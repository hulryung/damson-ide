# T83 — a real agent worker, supervised, on a remote host (2026-08-26)

T80 and T82 drove *shell* workers to settlement across the host boundary. This task
drove a `claude-code` worker: an agent TUI on the far side that received the preamble as
a prompt, minted nothing locally, did the work there, and sent `worker_done` back through
the tunnel. It worked — after the launch path was fixed, because the very first attempt
died at spawn with `zsh:1: command not found: claude`.

Everything below ran against a headless runtime built from this branch (`orchard serve`,
its own data dir under the session scratchpad) and the `orchard-loopback` harness
(127.0.0.1:2222). The Orchard app was never launched, quit, or written to.

## The run that settled

| Step | Evidence |
|---|---|
| Remote repo registered | `t83-remote-agent` → `/Users/dkkang/dev/damson-ide` on `ssh:orchard-loopback` |
| Precondition (T80) | the far side ran the CLI with the pane's own identity and answered with **this** runtime |
| Remote worktree created | `…/Orchard/worktrees/damson-ide/t83-remote-agent-2`, on the far side |
| Tunnel claimed | `-R 47110:127.0.0.1:<hook port>`; `sshd-sess` bound `127.0.0.1:47110` **on the far side** |
| Hook config written **before** launch | `<worktree>/.claude/settings.local.json`, six events, each `curl … 127.0.0.1:47110/hook?agent=<token>` |
| Agent launched | `claude` resolved and started; trust prompt auto-cleared by `ClaudeCodeEngine.autoResponseKeys` |
| `worker-start` receipt | `state: ready`, `stage: input_accepted`, `dispatch_input mode: preamble` |
| Agent's own work | one shell command on the far side wrote `/tmp/t83-remote-agent-proof.txt` |
| `worker_done` over the tunnel | `msg_e12e9d5faba6`, `outcome: succeeded`, `filesModified: [/tmp/t83-remote-agent-proof.txt]` |
| Dispatch | `ctx_ea4558a26983` — created 12:55:00, **completed 12:55:18** |
| Release | `released` / `closed_remote_connection` / archive `captured`, 235 raw → 162 readable |

Eighteen seconds covered all of it: remote worktree creation, ssh connect, the port claim,
the config write, Claude Code's startup and trust gate, the preamble injection, the agent's
turn, and its CLI call home.

The proof file, read back over ssh:

```
hostname=Daekeuns-MacBook-Pro.local
pid=26606
cwd=/Users/dkkang/Orchard/worktrees/damson-ide/t83-remote-agent-2
```

The pane shows the worker running the CLI **verbatim at the absolute path the preamble
gave it** — the dogfood-1 fix earning its keep on the far side — and getting a settled
receipt back:

```
⏺ Bash(/Users/…/.build/arm64-apple-macosx/debug/orchard send --from term_62a7faf5-… -…)
  ⎿ sent worker_done  run:run_c741a59c217f  settled  succeeded
     task:task_2e7113f157b1  dispatch:ctx_ea4558a26983  id:msg_e12e9d5faba6
```

## Defect 1 — a remote agent had no PATH to be found on

The first attempt (`ctx_64c46e385b41`) failed at `agent_readiness`. The pane held two
lines:

```
zsh:1: command not found: claude
Connection to 127.0.0.1 closed.
```

`RemoteEngineLaunch` sends the agent's **command**, not a path, and its doc comment says
why: a local absolute path is meaningless on the far side, so "a remote launch names the
command and lets the remote login shell resolve it, exactly as the user would if they
typed it there themselves." The premise was right and the last clause was false —
`ssh host '<command>'` is **not a login**. sshd runs the command through `$SHELL -c`,
which reads no `.zprofile`, `.zshrc` or `.bash_profile`. Measured on the harness:

```
$ ssh … 'echo $PATH; command -v claude'   → /usr/bin:/bin:/usr/sbin:/sbin ; (nothing)
$ ssh … 'exec "${SHELL:-/bin/sh}" -lc "command -v claude"'   → /opt/homebrew/bin/claude
```

Every agent CLI anyone actually installs — homebrew, `~/.claude/local`, a version
manager — is invisible in that PATH. So a remote *agent* pane could never have started on
any real host; the eleven waves of remote work in front of it were never able to find
out, because until T78/T80 nothing got this far.

The local spawn has always solved exactly this: `EngineLaunch.argv` wraps an engine's argv
in `[shell, -l, -c, …]` "so brew/PATH resolve under a GUI launch". The remote command now
does the same:

```
cd '<dir>' && exec "${SHELL:-/bin/sh}" -lc 'unset <markers…>; exec <command> <args…>'
```

Three properties kept: the `cd` happens on the far side; the marker `unset` now runs
*inside* the login shell, after the rc files, so an rc that exports one cannot win; and
`exec` twice means the PTY's remote child is still the agent itself, so
`HostLiveness.verdictForPTYEnd` reads the agent's exit status and not a wrapper's. The
whole inner command travels as one single-quoted argument.

`Sources/OrchardRuntime/Hosts/RemoteAgentLaunch.swift`, with
`SSHCommand.loginShell` extracted so the shell pane path (`cdAndLoginShellCommand`, which
had it right all along) and the agent path spell it identically.

## Defect 2 — the failure that explained itself, silently

That first receipt said only:

```
lastError: terminal 'term_0a487319-…' process has exited
failedStage: agent_readiness
```

A sentence about Orchard's own state. The far side's explanation was one line away, in a
pane the failure was about to close — and a coordinator that cleaned up its residuals
would have lost it entirely. On a remote host this is the *common* failure: a PATH that
does not resolve, an ssh auth refusal, a config the agent rejects at startup.

`agent_readiness` now fails with what the pane last said, both ways the wait can fail
(unsatisfied, or thrown). Verified live by removing the remote worktree out from under a
registry row:

```
lastError: terminal 'term_12cb3cd5-…' process has exited. The pane's last output was:
  zsh:cd:1: no such file or directory: /Users/dkkang/Orchard/worktrees/damson-ide/t83-remote-agent-2
  / Connection to 127.0.0.1 closed.
paneOutput: ["zsh:cd:1: no such file or directory: …", "Connection to 127.0.0.1 closed."]
```

Prose for a human, and a field for a coordinator that parses receipts. The quote is
evidence when there is some, never a precondition — a silent pane still gets the same
typed refusal without it.

## Defect 3 — the hook installer conjured the worktree it was writing into

Found while building the repro for defect 2. `RemoteHookConfig.install` ran
`mkdir -p <worktree>/.claude`, and it is the **first** thing that touches the far side. So
on a host where the worktree was gone — removed underneath the registry, a stale row, a
path that never existed — this step created the whole chain, the pane's `cd` then
*succeeded* into an empty directory, and Claude Code came up in a directory wearing the
workspace's name with none of its files in it. That is the same class of mistake as a
local PTY sitting in a remote path (docs/design/remote-hosts.md §1, rule 1): the work
happens somewhere that is not the workspace.

The install now refuses a missing worktree typed (`remote_worktree_missing`) and creates
nothing. Hook-install failure is deliberately non-fatal, so the pane still opens — as
`fingerprint-only`, saying which directory was missing — and the launch that follows fails
honestly with the far side's own `cd: no such file or directory`, which is defect 2's fix
carrying it. Verified live: after the fix, the directory was **not** recreated.

## What crossed the tunnel

### Readiness — hook-attested, not fingerprint-guessed

The pane reported `statusDetection: {mode: hooks, tunnelPort: 47110}`, but that is what
was *planned*. Three pieces of evidence say the channel was really carrying:

1. **The far side bound the port.** `sshd-sess` held `127.0.0.1:47110 (LISTEN)`; nothing
   listens there without the reverse forward.
2. **A POST from the far side reached this runtime and routed to this pane.** Running the
   pane's own hook command shape over ssh answered `http=200`, and the pane's `agentState`
   flipped `idle → working` **with a completely static screen** — impossible for a
   fingerprint, and proof of the whole chain: forward, server, token → `AgentSession`,
   external signal beating `classify`. It decayed back to `idle` when the external signal
   went stale, so the fingerprint fallback is intact underneath.
3. **Claude Code ran the hooks itself during the real run.** The archive contains
   `Beboppin'… (running stop hooks… 0/3 …)` — three `Stop` hooks, one of them the config
   Orchard wrote into that worktree minutes earlier.

So a remote agent worker's `ready` receipt means the same thing a local one's does. This
is also the first time T39's reverse-forward grant, the fixed-range port claim, and "a real
remote agent POSTing through the tunnel" have been exercised against a real sshd — they
were listed as unverified in `docs/reports/remote-verification.md` because they all
presupposed the identity T78 later delivered.

### Transcript — refused typed, and the refusal is right

`worker-read --source transcript` answers, exit 1:

```
transcript_unavailable / reason: remote_provider_transcript_unsupported
availableSource: terminal   nextCommands: [--source terminal, --source auto]
```

This harness is the exact coincidence that would make a wrong implementation look
correct: the far side *is* this machine, so the session's JSONL really is on this disk
(`~/.claude/projects/-Users-dkkang-Orchard-worktrees-damson-ide-t83-remote-agent-2/…jsonl`,
60 KB). Orchard still refuses, and should: on a genuinely different host that path is
either empty or holds an unrelated local session, and pinning *that* as this worker's
evidence is worse than having none.

What the run does change is the *reason*. The refusal was written when neither half was
knowable; now both are. The hook channel reports `providerSessionID` (that is what pins a
local transcript), and the pane records `remoteCwd`, so the file's identity on the far
side is fully determined. The only missing piece is a way to read a file over there —
which is precisely T85's remote file backend. This stays refused here rather than growing
a second, private ssh file transport in the worker verbs; when T85 lands, this is a small
follow-up and not a design question.

### Archive — a terminal tail, and a good one

`worker-release` captured 235 raw / 162 readable lines with
`fallbackReason: remote_provider_transcript_unsupported`. The chrome strip reported
`spinnerLines 18, separatorLines 21, duplicateLines 29, blankLines 5, escapeRemnantLines 0,
respacedLines 0`. The readable text carries the whole run end to end — banner, TASK block,
the tool call, the settlement receipt, the agent's closing summary — and shows **no**
word-collapse (the `Taskcompleteanddispatchsettled` failure mode from earlier dogfoods did
not recur).

## Differences from a local agent worker

| | Local | Remote |
|---|---|---|
| `dispatch_input` mode | `preamble` | `preamble` — identical; the contract is engine-shaped, never host-shaped |
| Identity | PTY process environment | `export ORCHARD_*=…` in the ssh remote command (T78) |
| Agent resolution | login-shell wrap (`EngineLaunch.argv`) | login-shell wrap — **this task**; it was missing |
| Readiness | hook POST to loopback | hook POST to the far side's loopback, through `-R`; config written over ssh first |
| Trust prompt | auto-cleared | auto-cleared, identically |
| Release archive | provider **transcript pin** | terminal tail + `fallbackReason` |
| Release action | `closed_agent_terminal` | `closed_remote_connection`, with the rule-2 warning that the far-side process's fate is unverifiable |

On that last row: the warning is right to hedge, and on this host the process did in fact
die — no `claude` with a cwd in the worktree survived the release (checked across all 37
`claude` processes then running).

## One thing observed and not explained

The sabotaged run — the pane that Claude Code opened in the bare directory defect 3 had
conjured — reached `dispatch_input` and failed there with *"agent in 'term_b392d8de-…'
never left idle after prompt submission"*: the preamble was typed, the input box came back
empty, and the agent never started a turn. It did not recur in the clean run (same engine,
same host, same injection path), and the only difference was a worktree that was an empty
directory. Recorded rather than diagnosed; if a remote agent worker ever fails at
`dispatch_input` again, this is the second sighting and worth chasing then.

## Not fixed here, deliberately

- **Remote provider transcripts** — refused typed, as above. Closable on top of T85.
- **A restored ended pane has no scrollback** — unchanged, and unrelated to the agent path.
- **One `ssh` per command** — the durable connection with a generation counter and
  connection multiplexing is still open backlog. The agent pane holds one long-lived `ssh`
  (with the forward); every *control* round trip — probe, worktree create, hook write — is
  still its own connection. Nothing in this run was slow enough to force the issue.

## Gates

`swift build`, `swift test` (**1248 tests, 0 failures**, 2 skipped),
`swift build -c release`, and `scripts/e2e-headless.sh` — all PASS.

New tests: the login-shell wrap and its quoting (`RemoteAgentTests`, ×2 plus three
existing assertions retargeted), the missing-worktree refusal and its ordering
(`RemoteAgentTests`), and the readiness residual with and without a talking pane
(`WorkerVerbTests`, ×2).

## Teardown

The remote worktree was removed on the far side (`removed: true`) and both leftover
branches deleted there; the remote repo view was unregistered with `repo remove --forget`
(`hostUntouched: true` — the far side's repo is untouched); the headless runtime and its
data directory were destroyed; the scratch file the worker created was removed. The
`orchard-loopback` host row and the app's own data directory were never written to.
