# T89 — finishing the remote transport (2026-08-27)

Wave 26. Four leftovers, all named in `docs/design/remote-hosts.md`'s own "still open
for a later stage" list: a durable connection with a **generation counter**, connection
multiplexing, a producer for `HostLiveness.live`, and remote provider transcripts.

Owns `OrchardRuntime/Hosts/**`, the OrchardTerminals remote paths,
`docs/design/remote-hosts.md`, tests, and this report. Did not touch `Checks/**`,
`Files/**`, or `OrchardApp`. The Orchard app was never launched or quit; every live
check ran against a headless `orchard serve` with its own data directory.

## The four, in one line each

| Leftover | Now | Where |
|---|---|---|
| Durable connection, generation counter | `RemoteConnection` — one `ControlMaster` per host, a generation minted on every open, a fence that refuses to answer for an ended one | `Hosts/RemoteConnection.swift`, design §3.1 |
| Connection multiplexing | remote git reads, pane liveness and transcripts share one transport; probes, tunnel walks and pane `ssh` deliberately do not | same |
| A producer for `live` | the pane records its far-side pid *and start time* at launch; asking the host about that record is the first thing entitled to say `live` | `Hosts/RemoteProcessLiveness.swift`, design §3.2 |
| Remote provider transcripts | resolved on the far side, bytes base64, typed refusals kept | `Hosts/RemoteProviderTranscript.swift`, design §6 stage 5 |

New CLI: `orchard host connect|disconnect|connection [<name>]`, and
`orchard terminal liveness --pane <k> | --terminal <h> [--generation <label>]`.

## Verdict discipline, held

The charter's two rules were the design constraints, not a checklist at the end.

- **Loss of contact is `unverifiable`, never `exited`.** A master that dies, a socket
  that vanishes, a command that hits its deadline — all `unverifiable`, all carrying
  `Loss of contact is not evidence that anything on <host> stopped.` verbatim. The only
  new `exited` is one the owning host issued: it looked for the pid and there is none,
  or the pid now belongs to a different process.
- **A generation-fenced reconnect refuses rather than guesses.** `acquire(fencedTo:)`
  returns `connection_generation_ended` naming both generations; a pane liveness question
  about an ended generation returns `superseded` — reported as `unverifiable`, **with the
  pid withheld**, because that pid belongs to a process the asker has never seen.

One decision worth stating plainly, because it cuts the other way: **failing to
multiplex is never a verdict.** If the master cannot be established, the command runs on
its own `ssh` — the pre-T89 behaviour — and whatever *it* answers is the honest answer. A
genuinely unreachable host still says so through the command itself. Turning a local
inconvenience (a control path that will not fit in a `sockaddr_un`) into `unverifiable`
would manufacture a verdict about another machine out of a fact about this one. The
explicit `host connect` verb still reports the failure typed, because there the user
asked for the connection itself.

## The subtle part: what "the same connection" is worth

A shared transport is the first thing Orchard has ever had that could be the same
connection twice, and that is what makes the counter necessary rather than decorative.
Three things had to hold, and two of them only showed up against a real `sshd`.

1. **The sequence is in the control socket path** (`<run>/mux/<hash>-<sequence>`), so a
   master left from generation 3 listens on a socket generation 4 never names.
2. **A stale socket is confessed; a missing one is not.** Verified live: with the socket
   file absent, OpenSSH prints *nothing* and connects directly with exit 0. Detecting
   loss from stderr alone would have left the state reading `open` while every command
   quietly opened its own connection — and a fenced caller would have been served from a
   span of contact that no longer existed. The connection is now checked with a `stat`
   in front of every acquisition. This was found by running it, not by reading it.
3. **An answer that bypassed the master is treated differently depending on the
   question.** A fenced call's answer is discarded even at exit 0 — it is not a smaller
   answer, it is an answer to a different question. An unfenced call keeps it (a direct
   connection answers a question about the *machine* perfectly well) but the attribution
   is dropped, so nothing records it as coming from a span it did not.

## Live verification — `orchard-loopback` (127.0.0.1:2222)

`orchard host check orchard-loopback` → `reachable`, 122 ms, "authenticated and ran the
probe command". A headless `orchard serve --data-dir <scratch>` from this branch;
scratch repo registered as `t89-remote` on `ssh:orchard-loopback`, dropped with
`repo remove --forget` at the end. The user's live runtime and its (empty) host registry
were never written to.

### Multiplexing

Counted from the harness `sshd`'s own log (`Accepted publickey` lines):

| | new SSH connections |
|---|---|
| `host connect` | 1 (the master) |
| 3 × `worktree list` with the master up | **0** |
| 3 × `worktree list` with the master killed | **3** — one per call, the pre-T89 shape |
| `host check` | 1 — a probe *is* the connect, so it is never multiplexed |

Per-command latency on loopback, where a handshake is as cheap as it will ever get:
**11 ms multiplexed vs 46 ms direct.**

### The generation counter

```
$ orchard host connect orchard-loopback
orchard-loopback: open · orchard-loopback#1.2ceb5b85

$ pkill -f 'ControlMaster=yes'          # the master dies under the runtime
$ orchard host connection orchard-loopback
orchard-loopback: lost · orchard-loopback#1.2ceb5b85
  reason: its control socket is gone, so the connection it named has ended
  Connection orchard-loopback#1.2ceb5b85 ended — … Loss of contact is not evidence that
  anything on orchard-loopback stopped. Reopening makes a new generation; it does not
  continue this one.

$ orchard worktree list --repo <id>     # work continues, on a new generation
$ orchard host connection orchard-loopback
orchard-loopback: open · orchard-loopback#2.2ceb5b85
```

### `live`, for the first time

A remote shell pane in a remote worktree:

```
$ orchard terminal liveness --pane <k>
<k>: live · pid 63009
  generation: orchard-loopback#1.00aaba83
  orchard-loopback confirms process 63009 is running.

$ ssh -p 2222 … 'ps -o pid,ppid,lstart,command -p 63009'
63009 63008 Thu Aug 27 15:48:05 2026     /bin/zsh -l
```

The pid is genuinely the far side's login shell, and its start time matches the one
recorded at launch to the second. Then, with that process killed on the host and the
pane already **disconnected** on this side:

```
$ orchard terminal liveness --pane <k>
<k>: exited · pid 63009
  orchard-loopback reports process 63009 is gone.
```

That is the case stage 4 could not answer at all: before this, a pane whose connection
ended was permanently `unverifiable`, because everything that could be observed was on
the wrong side of the connection.

### The fence, live

```
$ orchard terminal reconnect --pane <k> --json
  previousGeneration : orchard-loopback#1.00aaba83
  generation         : orchard-loopback#2.55e0bac4
  note: Opened a new connection … as generation orchard-loopback#2.55e0bac4;
        orchard-loopback#1.00aaba83 has ended and is no longer answerable. …

$ cat ~/.orchard/panes/*.pane          # the far side moved with it
65087	Thu Aug 27 15:48:44 2026 	orchard-loopback#2.55e0bac4

$ orchard terminal liveness --pane <k>
<k>: live · pid 65087

$ orchard terminal liveness --pane <k> --generation orchard-loopback#1.00aaba83
<k>: unverifiable (superseded)
  Refused: orchard-loopback holds this pane under generation orchard-loopback#2.55e0bac4,
  not orchard-loopback#1.00aaba83. The process it would report belongs to a later
  connection, so it is not an answer about orchard-loopback#1.00aaba83. A later
  connection cannot answer for an earlier one; reopening is a new generation, not a
  continuation.
```

A new pid was available and correct, and it was withheld. That is the whole point.

### Remote transcripts

The far-side half, run over the real connection with the script the reader generates:

| Case | Result |
|---|---|
| no transcript for that session | `ORCHARD-TX/1 not-found` → `provider_transcript_not_found` |
| a UTF-8 transcript | `ok 64 /Users/…/-Users-dkkang-Orchard-worktrees-repo-t89live/t89-live-session.jsonl`; 64 bytes decoded byte-for-byte |
| a Latin-1 byte in the file | bytes on the wire `7b2261223a22636166e9227d0a` — `0xe9` intact, typed `provider_transcript_invalid_utf8`, never U+FFFD |
| a directory that does not exist there | `ORCHARD-TX/1 no-cwd` → `remote_working_directory_unavailable` |
| `cd /tmp && pwd -P` on the host | `/private/tmp` — which is why the script resolves the directory there instead of encoding the path we recorded |

The synthetic project directory under `~/.claude/projects/` was created for this check
and removed afterwards.

## Honest scope — what was NOT proven

- **A real remote Claude session's transcript, end to end.** The far-side transport is
  verified live (above) and the runtime wiring is unit-tested
  (`WorkerRuntimeContext.transcriptPlacement` → `RemoteProviderTranscript`), but the two
  were not driven together by a real remote agent. The missing link is a hook-attested
  `providerSessionID`, which T83 already proved crosses the tunnel; nothing in this wave
  produced one. `worker-read --source transcript` on a remote pane no longer answers
  `remote_provider_transcript_unsupported` — it answers with the pane's real typed
  reason, which for a shell pane is `provider_session_unavailable`.
- **Multiplexing on three paths outside this task's ownership.** The file service
  (`Files/**`, T85's), `WorkerVerbs+Remote`'s readiness probe, and repo registration each
  build their own `SSHRunner` and still pay one `ssh` per call. The seam is one optional
  argument wide (`SSHRunner(… connection:)`), so wiring them is a line each — it was left
  to the owners of those files rather than reached into.
- **A `.live` verdict for a remote *agent* pane specifically.** The mechanism is
  engine-independent and the agent launch carries the same prelude (pinned by
  `RemoteAgentTests`), but the live run used a shell pane.
- **A host without `ps` or `base64`.** Both degrade typed by construction
  (`no-record` / `no-encoder`), and both are unit-tested, but no such host was available.

## Tests

`swift build` clean; `swift test` **1386 tests, 0 failures** (4 skipped, as before);
`scripts/e2e-headless.sh` green.

New: `RemoteDurabilityTests` (20 connection/fence/multiplex cases + 8 over the RPC seam),
`RemoteLivenessTests` (13 liveness + 6 generation-label cases), `RemoteTranscriptTests`
(11). Extended: `RemoteAgentTests` (+5 — the launch records an identity, `live` over the
RPC seam, a stale generation refused, a respawn moving the host's record, and a remote
transcript no longer refused for being remote),
`RemotePaneReconnectTests` (the reconnect names both generations and re-stamps the far
side), `TerminalHandlerTests` (the CLI surface).

Two existing assertions were **deliberately changed**, and both changes are the feature:
`RemoteAgentTests.testARespawnKeepsTheRemoteInvocation…` and
`RemotePaneReconnectTests.testReconnectReopensTheRecordedInvocation…` asserted the
recorded launch came back byte-identical. It now differs in exactly one place — the
generation stamp — and both tests assert that, plus that everything else (host, path,
argv, hook token, identity token) is unchanged. A relaunch that kept its old generation
would be the precise confusion this task exists to prevent.

## Residue

`~/.orchard/panes/<token>.pane`, one 60-byte line per remote pane, on each host. Pruned
by a later launch after 7 days. The live run's record was removed by hand.
