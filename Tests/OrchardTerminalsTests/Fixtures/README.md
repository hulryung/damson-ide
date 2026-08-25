# Terminal capture fixtures

Three verbatim `terminal_tail` archives Orchard pinned at `worker-release` during
live dogfood cycles. `TerminalCaptureCleanerTests` and
`TerminalCaptureFidelityTests` read them directly, so the chrome stripper is
measured against real noise rather than a synthetic imitation of it. Do not
regenerate or tidy the files: their value is that they are untouched.

| File | Cycle | Dispatch | Lines |
|---|---|---|---|
| `claude-code-tui-capture.txt` | 1 (T34 retry, docs/reports/dogfood-1.md) | `ctx_0931b123463e` | 1,594 |
| `claude-code-tui-capture-dogfood-2.txt` | 2 (T38, docs/reports/dogfood-2.md) | `ctx_c6ed09a10232` | 630 |
| `claude-code-tui-capture-t50.txt` | 3 (T50, docs/reports/dogfood-3.md) | `ctx_49651f2f3c3f` | 430 |

One captured line per file line. Nothing was reformatted — the collapsed words,
half-painted spinner frames, dropped letters, and repeated footer blocks are exactly
what a caller got back from `worker-read`. The only edit is the dispatch capability
secret, replaced in place with `dcap_REDACTED…` padded to the original length so no
line's width changes.

Cycle 1 is the archive T35 was built against. Cycle 2 adds the remainder of finding 4
(collapsed words such as `orchardsend` / `OrcharddogfoodT38completed$`) plus the
Swift-debug `orchard send` dump. Cycle 3 is the T52 evidence: a session in a wide
terminal whose paste never emitted its empty cells, so most of the capture arrives
already collapsed (`Tipsforgettingstarted`) and some of it arrives with letters
missing (`paste gain to expad` for "paste again to expand", `coorinator` for
"coordinator"). That damage is upstream of the cleaner — see
`docs/design/terminal-capture-fidelity.md` — and T54 root-caused and fixed it
(`docs/design/capture-fidelity-upstream.md`; `UpstreamCaptureFidelityTests` reproduces
the same shapes from a scripted cell-diff paint through the real engine). Captures
pinned after T54 will read as whole rows; these three are kept verbatim as the record
of what the cleaner was built against.

## How these were extracted

The archives live in the running app's store. Copy it, never open it in place:

```sh
cp ~/Library/Application\ Support/Orchard/orchestration.db{,-wal,-shm} /tmp/dbcopy/
sqlite3 'file:/tmp/dbcopy/orchestration.db?mode=ro'  # read-only URI, WAL replayed
```

`worker_terminal_archives.content` is a JSON object; the untouched capture is its
`rawLines` array (`lines` is the cleaned face, and the cycle-1 row predates
`rawLines`, so for that one `lines` *is* the raw capture). Write one array element
per file line, then redact the capability secrets.
