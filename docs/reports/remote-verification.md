# Remote verification over a real SSH transport (2026-08-25)

The backlog carried "real-remote SSH verification (needs a designated host)" from
wave 10 onward. No second machine was needed in the end: a **user-space sshd bound to
127.0.0.1:2222** provides a genuine SSH transport (real sshd, real key auth, real
remote process tree) without touching Remote Login or any system setting.

## Harness

```
/usr/sbin/sshd -f <scratch>/sshd_config -E <scratch>/sshd.log
#   ListenAddress 127.0.0.1 · Port 2222 · throwaway ed25519 host key
#   AuthorizedKeysFile <scratch>/authorized_keys (throwaway key + the user's own id_*.pub)
#   PasswordAuthentication no · UsePAM no · AllowTcpForwarding yes
```

Registered as `orchard host add --name orchard-loopback --hostname 127.0.0.1 --user
dkkang --port 2222`. Teardown is `kill $(cat <scratch>/sshd.pid)` plus removing the
`~/.ssh/config` block, the `[127.0.0.1]:2222` known_hosts line, and the host/repo rows
(backups of both ssh files are in the scratch dir).

## What passed

| Check | Result |
|---|---|
| `host check` | `reachable`, 51 ms, "authenticated and ran the probe command" |
| `repo add --host ssh:orchard-loopback` | registered with `hostId: ssh:orchard-loopback`, `baseRef: origin/main` |
| `worktree list` on the remote repo | **46 worktrees enumerated over real SSH** |
| `terminal create` on a remote worktree | `connected: true`, `executionHostId: ssh:orchard-loopback`, incarnation 1 |
| Command execution in the remote pane | `REMOTE-PROOF Daekeuns-MacBook-Pro Darwin 39429` — a real remote-side PID |
| Remote pane presentation | prompt renders the 🌐 host indicator |

## What failed — remote panes have no Orchard identity

`env | grep -i ORCHARD` inside the remote pane prints **nothing**. Locally every
managed PTY carries `ORCHARD_TERMINAL_HANDLE`, `ORCHARD_PANE_KEY`,
`ORCHARD_WORKTREE_ID`, `ORCHARD_CLI_COMMAND`, `ORCHARD_DATA_PATH`.

Cause: `DamsonTerminalFactory` sets those variables on the spawned process's
environment, but for a remote pane that process is **`ssh`** — and ssh does not
forward arbitrary environment to the remote shell (that needs `SendEnv` locally plus
`AcceptEnv` on the server, or the values passed in the remote command line). The code
comment right above the env block already notes "its PTY child is `ssh`" (T39), so
the seam was known; the consequence was not measured until now.

Consequences:

- An agent running in a remote pane cannot identify itself, cannot find the CLI, and
  cannot call the runtime back — the reverse-forward hook tunnel has nothing to
  address it with.
- This is why supervised dispatch to remote stays `remote_unsupported`: the identity
  contract simply does not reach the far side.

Fix direction (T78): pass the identity through the remote command line rather than the
local process environment — `ssh … <shell> -lc 'export ORCHARD_…=…; exec <shell> -l'`
or an equivalent that survives quoting, keeper restoration, and reconnect. Verify with
the same harness: `env | grep ORCHARD` in a remote pane must list the five variables,
and `orchard status` run *inside* the remote pane must reach the runtime.

## Not verified

The reverse-forward hook grant, fixed-range port claim, reconnect grant, and rebind
paths could not be exercised: they all presuppose the identity above, so they are
blocked behind T78 rather than independently failing.
