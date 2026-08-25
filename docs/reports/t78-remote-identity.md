# T78 — remote panes carry Orchard identity

Wave 21. Owns `Sources/OrchardTerminals/DamsonTerminalFactory.swift`,
`Sources/OrchardTerminals/OrchardIdentity.swift`, the factory's respawn/reconnect
wrap (same spawn path), matching tests, and this report. Does not touch Files,
`WorktreeManager`, Conflicts, the CLI surface, or Automations.

Closes the finding in `docs/reports/remote-verification.md`: a remote pane's PTY
child is `ssh`, so the five `ORCHARD_*` variables injected into the local process
environment never reached the far-side shell.

## What was wrong

`DamsonTerminalFactory` stamped `ORCHARD_TERMINAL_HANDLE`, `ORCHARD_PANE_KEY`,
`ORCHARD_WORKTREE_ID`, `ORCHARD_CLI_COMMAND`, and `ORCHARD_DATA_PATH` on the
spawned process. For a remote pane that process is the local `ssh` client.
OpenSSH does not forward arbitrary environment (`SendEnv`/`AcceptEnv` is opt-in
and not ours to require), so `env | grep ORCHARD` inside the remote pane printed
nothing.

An agent there could not identify itself, find the CLI, or call the runtime
back. Supervised dispatch stays `remote_unsupported` for that reason, not
because the reverse tunnel itself was missing.

## The fix

Identity is still written into the local env (local panes, and it is harmless
on `ssh`). For `spec.isRemote`, the factory also carries it through the remote
command line:

```
export ORCHARD_TERMINAL_HANDLE=…; export ORCHARD_PANE_KEY=…; …; <far-side command>
```

A dest-only `ssh` (bare login) gets an exporting login shell appended:
`export …; exec "${SHELL:-/bin/sh}" -l` — the same `${SHELL:-/bin/sh}` fallback
`SSHCommand.cdAndLoginShellCommand` already uses.

Two argv shapes the factory actually produces are rewritten:

- remote **agent**: `[/usr/bin/ssh, -tt, (-R …), dest, <remote command>]` — last
  element wrapped; `-R` untouched
- remote **shell**: `[<login-shell>, -l, -c, "/usr/bin/ssh -tt dest '…'"]` — the
  quoted remote command is tokenized, wrapped, and re-quoted with
  `EngineLaunch.shellQuote`

The recorded spec stays the **unwrapped** invocation. Keeper restoration and
`KeeperRemoteRestoration.reconnectPlan` keep seeing the far-side command they
persisted (`exec claude`, the `-R` they retarget). The factory reapplies the
current handle/pane key on every spawn, including respawn and reconnect. Wrap
is idempotent: a leading `export ORCHARD_*=` run is stripped and rewritten so a
previously wrapped argv cannot accumulate prefixes.

`AgentSupervisor.spawnEnvironment` now applies the same `OrchardIdentity.bindings`
so the two local-env paths cannot drift.

## Tests

`Tests/OrchardTerminalsTests/RemoteIdentityTests.swift` — 15 cases:

- wrap prefixes, bare-login fallback, quoting (spaces and embedded `'`)
- idempotent rewrite (new handle wins)
- agent argv / dest-only ssh / combined flags (`-tt`, `-p2200`, `-oBatchMode=yes`)
- login-shell `-c` ssh command-line wrap
- reconnect retarget then wrap (local `-R` port moves; far side unchanged)
- factory `launchConfig` for agent, remote shell prompt, bare ssh, local no-op,
  and a reconnect spec

## Live harness (orchard-loopback, 127.0.0.1:2222)

`orchard host check --name orchard-loopback`: reachable, authenticated, 104 ms.

**Quoting + CLI callback, proven over the real sshd** (same export string the
factory emits). All five variables appear, and `$ORCHARD_CLI_COMMAND status`
reaches the running runtime (`rt_9749b202-…`, pid 29881). Bare `orchard` is
**not** on the remote login PATH — the injected `ORCHARD_CLI_COMMAND` is what
makes the callback work.

**Reverse-forward hook grant is now reachable.** A remote Claude pane on
`damson-ide-remote` opened with `statusDetection.mode: hooks` and
`tunnelPort: 47110` (the first fixed-range candidate). The grant does not
depend on identity; identity is what lets an agent *use* the CLI on top of
that channel. Reconnect grant / rebind were not exercised (would need an app
restart, which this task must not perform).

**Pane-level `env | grep ORCHARD` against the running app still prints nothing.**
The live factory is the trampoline binary at
`~/Library/Caches/orchard/Orchard.app` (started 22:55, binary dated 22:43).
This task must not launch or quit Orchard, so the new factory is not yet the
process that `terminal create` hits. A pane created on
`2fae36b9-…::/Users/dkkang/dev/damson-ide` confirmed the pre-T78 behaviour
(`T78-NO-ORCHARD`). After the running runtime loads this commit, the same
create + `env | grep ORCHARD` is the remaining acceptance check.

## What is left

- `swift build && swift test`: **1158 tests, 2 skipped, 0 failures** (retry;
  a first run hit two unrelated load flakes — FileWatcher budget and
  ServerRuntime FD-bound — that passed on the second full suite).
- Reload the running Orchard app (coordinator-owned) and re-verify a remote
  pane lists the five variables, then `$ORCHARD_CLI_COMMAND status` inside it.
- Supervised remote dispatch is still refused typed; identity is necessary but
  not sufficient for that (the far side still has no lifecycle worker contract).
