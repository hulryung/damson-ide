# T85 — a real remote file backend (2026-08-26)

Wave 23. `file` verbs answered `remote_unsupported` for a remote workspace on
purpose: resolving a remote path with `FileManager` would either fail confusingly
or — the real hazard — find a same-named directory on this machine and quietly
answer with the wrong repo's files. That refusal is replaced for the operations
that can be faithful over ssh.

Owns `OrchardRuntime/Files/**`, the remote file transport, matching tests, and
this report. Does not touch `OrchardApp/**`, `WorkerVerbs`, or `OrchardTerminals`.
The Orchard app was never launched or quit.

## What is faithful over ssh

| Verb | Remote | Why |
|---|---|---|
| `file-read-dir` | **yes** | directory listing, no symlink follow |
| `file-list` | **yes** | bounded name listing |
| `file-stat` | **yes** | size / dir / symlink / mtime from the far side |
| `file-preview` | **yes** | bytes come back base64; T75 classify happens *here* |
| `file-search` | **yes** | far-side walk + match; excerpts are display-only |
| `file-open` | **refused** `remote_unsupported` | local GUI action (`FileOpenCenter` posts to the app) |
| `file-open-changed` | **refused** `remote_unsupported` | same: posts local open requests |
| `file-diff` | **refused** `remote_unsupported` | `GitService.diff` runs local git, including untracked `--no-index`; a partial remote git-diff that hid new files would be a lie |
| reveal | **no verb** | CommandSpec copy; there is no `file-reveal` RPC. Open is the GUI action. |
| write / save | **no verb** | editor save is in-process `FileService.write` (T75); not an RPC, not this slice |
| watch | **not a verb** | `FileWatcher` is local FSEvents; the app explorer stays gated by `RemoteWorkspacePolicy` |

A dropped connection is `host_unverifiable` (rule 2), never `not_found`. `../`
is `path_escape` in Swift *before* ssh, so a confined relative path is the only
thing that becomes a remote argument.

## Byte fidelity (T75, over ssh)

The expensive mistake is the same one T75 closed locally: decode stdout as UTF-8,
hand the String to the editor, write it back. `String(decoding:as: UTF8.self)`
turns every illegal byte into U+FFFD and calls it success; a save then rewrites
the file.

The transport never does that with file bytes:

1. Path confinement is string-only (`RemoteFilePath`). No `URL(fileURLWithPath:)`
   of a remote root, so a coincidentally-named local directory cannot answer.
2. The far-side helper (`perl -e`, ASCII protocol `ORCHARD-FILE/1`) base64-encodes
   names and bodies. OpenSSH's stdout can be parsed as UTF-8 without touching a
   single file byte.
3. `FileService.preview(data:relativePath:)` is the one classifier. A Latin-1
   file comes back as `content: ""`, `notTextReason: not_utf8`, `byteLength` of
   the original; a NUL in the head is `nul_bytes`. U+FFFD cannot reach a caller
   as `content`.
4. Content search is display-only, same as local T75: ASCII inside Latin-1 is a
   real match; the excerpt may contain U+FFFD because search never writes.

A host without `perl` fails typed (`remote_unsupported`, "file transport on
\<host\> failed") rather than approximating. orchard-loopback is Darwin and has
`/usr/bin/perl`.

Each call is still its own `ssh` (design §7). `BatchMode=yes` and `ConnectTimeout`
are the existing runner's.

## Layout

- `RemoteFilePath.swift` — string confinement (`..`, NUL, absolute, symlink
  escape after `realpath` on the far side)
- `RemoteFileTransport.swift` — ssh command + `ORCHARD-FILE/1` parse + far-side
  perl helper
- `RemoteFileService.swift` — FileService-shaped reads against a remote root
- `FileCommandHandler` — local vs remote split; GUI/diff refusals named
- `FileService.preview(data:)` — T75 classify extracted so both backends share it

## Tests

`swift build` clean. `swift test` **1261 tests, 0 failures** (2 skipped,
pre-existing). 19 new:

- `RemoteFileTransportTests` (11) — runs the perl helper locally against a temp
  tree (no ssh). Latin-1 bytes in, `not_utf8` out, no U+FFFD in content; UTF-8
  with BOM round-trips; NUL head is `nul_bytes`; `../` is `path_escape`; a
  symlink whose target sits outside the root is `path_escape` and carries no
  body; listing omits dotfiles; search finds `hello` under `*.swift` and ASCII
  `caf` inside Latin-1.
- `RemoteFileHandlerTests` (6) — RPC through a scripted ssh runner. Preview of
  Latin-1 is typed `not_utf8`; UTF-8 is content; search/list go over ssh;
  `../` does not ssh; open / open-changed / diff stay `remote_unsupported`;
  ssh 255 is `host_unverifiable` with the rule-2 reminder, not `not_found`.
- `RemoteWorktreeTests` — the old blanket `file-read-dir` → `remote_unsupported`
  is now a transport round-trip; open and diff still refuse.

## Live verification (orchard-loopback, 127.0.0.1:2222)

The running Orchard app was not used (its runtime does not have this code, and
this task must not launch or quit it). A headless `orchard serve --data-dir
/tmp/orchard-t85-remote/data` from this branch talked to the same user-space
sshd. `host check --name orchard-loopback` → `reachable`, 115 ms, "authenticated
and ran the probe command".

Scratch git repo `/tmp/orchard-t85-remote/repo` registered as
`t85-remote` / `c3fdbf62-c5a9-4d29-bf81-c5e05557c6ad` /
`hostId: ssh:orchard-loopback`. Worktree id
`c3fdbf62-…::/private/tmp/orchard-t85-remote/repo`.

A Latin-1 file was created on the far side *after* registration:

```
ssh -p 2222 dkkang@127.0.0.1 python3 -c 'open("…/far-latin1.txt","wb").write(b"caf\xe9 deja\xe0\n")'
```

| Call | Result |
|---|---|
| `file preview latin1.txt` | `content: ""`, `isBinary: true`, `notTextReason: not_utf8`, `byteLength: 5`. Hex on disk still `636166e90a`. No U+FFFD as content. Receipt `C8140DC9-…` |
| `file preview far-latin1.txt` | same shape, `byteLength: 11`. Far-side hex `636166e92064656a61e00a`. Receipt `3267A646-…` |
| `file preview notes.txt` | `content: "hello from utf8\n"`, `isBinary: false`. Receipt `298B46B9-…` |
| `file preview blob.bin` | `notTextReason: nul_bytes`, `byteLength: 9`. Receipt `7077C1C8-…` |
| `file search hello` | `notes.txt:1` and `src/app.swift:1`. Receipt `E5DABBD1-…` |
| `file search caf` | hits `latin1.txt` and `far-latin1.txt` (ASCII inside Latin-1; excerpts display-only). Receipt `B3DD4CDF-…` |
| `file list` | `blob.bin`, `far-latin1.txt`, `latin1.txt`, `notes.txt`, `src/app.swift` |
| `file read-dir` | `src/` first, then the files; `.git` not listed |
| `file stat notes.txt` | size 16, not a directory |
| `file open notes.txt` | `remote_unsupported` — "file open is a local GUI action" |
| `file open-changed` | `remote_unsupported` — same |
| `file diff notes.txt` | `remote_unsupported` — "file diff still runs a local git against the path" |
| `file preview ../secret` | `path_escape`, no ssh walk |

`repo remove --forget` (receipt `848154FE-…`): `forgotten: true`,
`hostUntouched: true`. Far-side `latin1.txt` still `636166e90a`. Headless
runtime torn down; the Orchard app was not touched.

## Honest refusals, named

- **`file-open` / `file-open-changed`:** they post `FileOpenRequest` for the
  in-process app explorer. A remote workspace has no local pane to focus, and
  inventing one would open a local path that is not the file. Typed
  `remote_unsupported`.
- **`file-diff`:** `GitService.diff` is local git plus untracked `--no-index`.
  Running it against the workspace `URL` is the original wrong-machine hazard.
  Shipping a remote `git diff` that omitted untracked files would hide new work.
  Refusing beats that approximation; a faithful remote diff is later work.
- **write / save:** not an RPC. T75's byte-exact write stays on `FileService`
  and the editor. A remote write that decoded, or a String write over Latin-1,
  is exactly the defect this slice exists to not reintroduce. Out of scope.
- **watch:** `FileWatcher` is FSEvents on this machine. The app file explorer
  remains `RemoteWorkspacePolicy`-gated; T85 does not pretend the explorer can
  subscribe to a remote tree.
- **conflicts:** still `remote_unsupported` (T32). Out of ownership.
- **no `perl` on the host:** typed `remote_unsupported` from the transport,
  not a local fallback.

## Not done here

Durable ssh with a generation counter, connection multiplexing, remote write,
remote watch, remote git-diff matching `GitService.diff`, and flipping
`RemoteWorkspacePolicy.fileExplorer` so the app explorer lights up — that last
one is app-side (T84's lane / a later Files consumer). The RPC is the door.
