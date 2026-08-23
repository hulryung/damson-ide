# Terminal capture fixtures

`claude-code-tui-capture.txt` is the verbatim `terminal_tail` archive Orchard pinned
at `worker-release` during dogfood cycle 1 (docs/reports/dogfood-1.md, dispatch
`ctx_0931b123463e`): 1,594 stream lines from a live Claude Code TUI, one captured
line per file line. Nothing was reformatted — the collapsed words, half-painted
spinner frames, and repeated footer blocks are exactly what a caller got back from
`worker-read`. The only edit is the dispatch capability secret, replaced with
`dcap_REDACTED…`.

`claude-code-tui-capture-dogfood-2.txt` is the same kind of archive from cycle 2
(docs/reports/dogfood-2.md, dispatch `ctx_c6ed09a10232`): 630 stream lines. Cycle 2
is the remainder of finding 4 (collapsed words such as `orchardsend` /
`OrcharddogfoodT38completed$`) plus the Swift-debug `orchard send` dump. Capability
secrets are replaced with `dcap_REDACTED`.

`TerminalCaptureCleanerTests` reads both files directly, so the chrome stripper is
measured against real noise rather than a synthetic imitation of it. Do not
regenerate or tidy the files: their value is that they are untouched.
