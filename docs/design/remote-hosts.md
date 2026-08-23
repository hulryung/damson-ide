# Remote hosts (SSH execution boundary)

Status: **stage 1 shipped** (T29, wave 7) — host registry, bounded connectivity probe,
remote shell panes. Remote worktrees, remote agents, and keeper interplay are staged
below and deliberately out of scope for this wave.

This document is the contract for every later remote feature. It exists before the
features do because the expensive mistakes here are *semantic*, not mechanical: what a
dropped connection is allowed to mean, and which machine a piece of work is on.

Sources followed: `docs/research/orca-inventory.md` §2 (Identity, per-worktree session
state), §3 (Sessions, sleep, orphans), §1.8, rebuild checklist #14; orca
`src/shared/execution-host.ts`, `src/shared/pty-liveness-verdict.ts`,
`src/main/ssh/ssh-config-parser.ts`.

## 1. The two rules everything else follows

**Rule 1 — every workspace, terminal and PTY is stamped with an `ExecutionHostId`.**
Never inferred, never defaulted after the fact. A record that lost its host reads as
local, and local is the one answer that must never be guessed: guessing it runs work on
the wrong machine.

```
ExecutionHostId = "local" | "ssh:<name>"
```

Orca also has `runtime:<id>` for its ephemeral-VM environments. Orchard has no
equivalent, so that kind does not parse — an unknown kind is rejected rather than being
quietly downgraded to `local` (`ExecutionHostId(rawValue:)`; pinned by
`HostRegistryTests.testExecutionHostIdVocabulary`).

**Rule 2 — loss of contact is never evidence of death.** The verdict vocabulary is
exactly three words, and it is the same vocabulary on every surface:

| verdict | what it means | what it requires |
| --- | --- | --- |
| `live` | the owning host confirmed the process is running | a positive answer from the host |
| `unverifiable` | nobody who can answer for the host was reachable | nothing — this is the *default* when contact is lost |
| `exited` | the owning host confirmed the process is gone | positive evidence of absence |

`exited` requires proof. A dropped connection, an unreachable probe, or a host that is
no longer registered is `unverifiable` — never a death certificate, and never a
successful stop. The failure this prevents is concrete: a coordinator reading a dropped
SSH connection as "the worker died", respawning the task, and ending up with two agents
editing the same worktree from two machines.

Corollary (inventory §1.8): when liveness or authority cannot be proven, **degrade to
read-only inspection — never fall back to local execution.**

Implementation: `HostLivenessVerdict` / `HostLiveness` in
`Sources/OrchardRuntime/Hosts/HostLiveness.swift`. Stage 1 produces `unverifiable` and
`exited`; `live` gets its producer with stage 3's remote worker liveness, and is defined
now so no stage invents a fourth word.

### Applying rule 2 to a PTY that ends

A remote pane is a *local* PTY whose child is the `ssh` client. So a PTY exit is two
different facts depending on the host:

- **local host** — the PTY is the process. An exit status is proof of exit.
- **`ssh:<name>`** — status `255` is OpenSSH reporting *its own* transport failure. It
  says nothing about the far side, so the verdict is `unverifiable`. Any other status
  was propagated back through a working connection from the remote command, so it is
  real evidence: `exited`. A PTY that ends with no status at all is `unverifiable`.

`HostLiveness.verdictForPTYEnd(host:exitCode:)` is the single decision point;
`describeConnectionEnd(host:exitCode:)` is the one sentence user-facing copy uses, so
no surface can invent softer or harder wording than the verdict supports. The app
renders it in the pane when a remote PTY ends; `TerminalExitEvent` carries the pane's
`executionHostId` so consumers classify rather than assume.

## 2. Host registry

Registered hosts live in `orchard-data.json` under `hosts`:

```json
{ "name": "build", "hostname": "build.internal", "user": "ci", "port": 2222,
  "source": "ssh-config", "addedAt": 1755993600 }
```

`name` is the registry key and the `ssh:<name>` id suffix. It is restricted to letters,
digits, `.`, `_`, `-`, `@` so the raw id needs no escaping and stays greppable in JSON
and logs; anything else is rejected at registration.

A record is *a name for a connection target and nothing more*. It is never a claim that
the host is reachable, and a failed probe never removes it — registry and liveness are
separate questions on purpose.

### `source` decides how `ssh` is invoked

| source | destination argument | why |
| --- | --- | --- |
| `ssh-config` | the alias (`build`) | OpenSSH re-resolves the user's own `~/.ssh/config`: ProxyJump, IdentityFile, ControlMaster, everything Orchard deliberately does not model. Rewriting an alias into its hostname silently drops all of it. |
| `manual` | `[user@]hostname`, plus `-p <port>` | there is no config entry to resolve. |

Imported HostName/User/Port are stored for *display* only.

### CLI

```
orchard host list
orchard host add <name> --hostname <h> [--user <u>] [--port <n>]
orchard host add --import                 # list importable ~/.ssh/config names
orchard host add --import <name>          # register one of them
orchard host check <name>
```

`--import` with no name is a **listing, not a prompt**. A dispatched worker must never
be parked on an interactive picker (rebuild checklist #19), so the offer comes back as
data the caller re-invokes with.

`~/.ssh/config` parsing (`SSHConfigParser`) reads only what the picker shows — HostName,
User, Port. It is deliberately *not* a resolver. Wildcard and negated patterns (`Host *`,
`gpu-?`, `!excluded`) are skipped: they are patterns, not hosts, and `ssh <pattern>`
connects nowhere. `Match` blocks end the current block because their bodies are
conditional. A missing or unreadable config is "no hosts to offer", never an error.

## 3. Connectivity probe

```
ssh -o BatchMode=yes -o ConnectTimeout=5 <dest> true
```

`BatchMode=yes` is what makes this safe to run unattended: OpenSSH fails instead of
prompting for a password or passphrase, so the probe can never block on a human who is
not there.

**It is bounded twice**, because either bound alone can be defeated: `ConnectTimeout=5`
bounds the connect phase, and the runner's own deadline (12 s) bounds everything else —
a TCP connection that opens and then says nothing, a wedged `ProxyCommand`, a prompt
BatchMode somehow did not suppress. An agent-facing verb that can hang is worse than one
that answers `unreachable`: a coordinator blocked on a probe is indistinguishable from a
crashed one.

Classification (`HostProbe.classify`, pinned by fake-runner tests):

| result | verdict |
| --- | --- |
| exit 0 | `reachable` |
| exit ≠ 0 and ≠ 255 | `reachable` — the status came back *through* an authenticated connection, so the host answered (e.g. `true` missing on the far side) |
| 255 + permission denied / publickey / passphrase / changed host key | `auth-required` — the host answered; only a credential or a decision is missing |
| 255 + resolve/refused/timeout/reset/no-route | `unreachable` |
| our deadline fired | `unreachable`, `timedOut: true` |

`unreachable` results carry the rule-2 reminder verbatim: *"Unreachable is loss of
contact, not evidence that anything on `<name>` stopped."* `auth-required` is kept
distinct from `unreachable` because collapsing them sends a user to debug the network
when the real problem is their key.

## 4. Remote terminals (this wave's PoC)

```
terminal-create --host ssh:<name> [--prompt "<remote command>"]     # RPC verb
```

Reachable over the runtime socket today. The user-facing `orchard terminal create
--host ssh:<name>` spelling needs one `--host` flag added to the `terminal` command spec
that T27 introduces — the two tasks land in the same wave, and this slice deliberately
does not create a second `terminal` entry that would collide with it.

What happens: the runtime resolves `<name>` in the registry, then spawns **a local PTY
through the existing factory** whose child is `ssh -tt <dest> [command]`. `-tt` forces a
remote TTY (the local PTY is `ssh`'s stdin, not the remote shell's), so interactive
shells and full-screen TUIs draw correctly. With no command it is a remote login shell.

Because it is an ordinary local PTY:

- `terminal read | send | wait | close | rename` work unchanged, with the same stream and
  screen sources, the same handle/paneKey identities, and the same stale-handle rules;
- the summary carries `executionHostId: "ssh:<name>"`, stamped at create time;
- the app shows the host as a chip in the terminal tab label, and offers registered
  hosts under the tab bar's **Remote Shell** menu — only registered ones; Orchard never
  invents a connection target.

Refusals, all typed, all before anything spawns:

| case | error |
| --- | --- |
| `--host ssh:<name>` for an unregistered name | `unknown_host` |
| a host id that does not parse (`runtime:vm-1`, `ssh:`) | `invalid_argument` |
| `--host ssh:<name> --engine <agent>` | `not_implemented` (stage 3) |
| the app's remote tab whose host was unregistered since | opens nothing, says so |

None of these degrade to a local shell. That is rule 2's corollary in code.

Two carried facts worth knowing:

- **A respawn keeps its launch command for remote panes.** For an `ssh:` pane the shell
  engine's prompt *is* the `ssh` invocation; dropping it on respawn (which local panes
  do deliberately) would silently reopen the pane as a local shell.
- **`--worktree` still resolves locally.** A remote pane has no local workspace, so
  `cwd` is only where `ssh` is launched from. Remote worktrees are stage 2.

## 5. Per-host partitioning

Orca partitions per-worktree session state by host: tabs, pane layouts, sleeping agent
sessions by paneKey, PTY incarnations by paneKey, and topology revisions are all scoped
`local` + by `ExecutionHostId` (inventory §2, "Per-worktree session state"). Two hosts
can hold panes with the same paneKey, and adopting one host's pane record into another
host's registry would attach a live handle to the wrong machine.

Today Orchard has one host's worth of that state, and the field that makes the
partitioning possible is already on every record (`RepoRecord.hostId`,
`Workspace.hostId`, `TerminalSummary.executionHostId`, `TerminalExitEvent.executionHostId`).
The rules the later stages must hold to:

1. Session state is keyed by `(executionHostId, paneKey)`, never by `paneKey` alone.
2. Orphan adoption is fenced per host: a topology revision from one host can never
   admit or retire another host's panes.
3. A host that disappears from the registry does not delete its state — its panes become
   `unverifiable`, and stay inspectable.
4. Listings must be host-aware. Today `terminal list` returns local and `ssh:` panes
   together and that is safe, because every handle it returns is a *local* PTY handle
   and each row is stamped. Once a stage-2/3 pane can live in a remote runtime, the
   listing needs the Orca shape — default to the caller's host, cross-host only as an
   explicit scope (`--host all`) — because a silently merged list is how a handle from
   the wrong machine gets used.

## 6. Staged roadmap

**Stage 1 — hosts + remote shell panes (this wave, done).** Registry, `~/.ssh/config`
import, bounded probe, `terminal create --host ssh:<name>`, execution-host stamping on
terminal summaries and tab labels, the verdict vocabulary and its user-facing copy.

**Stage 2 — remote worktrees.** Git facts read over the connection instead of the local
filesystem; `repoId::path` ids gain a host dimension; the file service learns a remote
backend; `worktree create` on a host. Prerequisite: a durable connection with a
generation counter, so a reconnect cannot be mistaken for continuity — every read must
be able to answer `unverifiable` rather than an empty listing. An empty result from an
unreachable host is the classic false `exited`.

**Stage 3 — remote agents.** Agent engines assume a local filesystem for argv, config,
hooks, and transcripts; a remote agent needs its hook endpoint reachable from the far
side and its provider transcript resolvable across the boundary (T24's pins). Until then
`--host ssh:<name> --engine <agent>` is refused rather than approximated — an
approximation would launch the agent on *this* machine under a remote host's name.
Dispatch authority must also carry the host: `process_incarnation` proves a pane on a
host, and a worker that cannot be proven live is `unverifiable`, which auto-escalates for
a human rather than being reaped.

**Stage 4 — keeper interplay.** T23's keeper hands local PTY masters across an app
restart. A remote pane's master is local too, so the mechanism transfers — but the
restoration record must carry `executionHostId`, adoption must be fenced per host (§5),
and a restored remote pane whose connection died during the restart is `unverifiable`:
it reopens as an inspectable dead pane, never as a silently reconnected live one, and
never as a local shell.

## 7. Non-goals

Orchard does not reimplement OpenSSH. No in-process SSH client, no key management, no
known-hosts UI, no relay/agent deployment onto the far side (Orca's `ssh-relay-*` stack).
Orchard shells out to the system `ssh` and lets the user's own `~/.ssh/config` be the
configuration surface. If a host works in a terminal, it works here — and if it does not,
the fix is in the user's SSH config, where they can already test it.
