# Terminal capture fixtures

`claude-code-tui-capture.txt` is the verbatim `terminal_tail` archive Orchard pinned
at `worker-release` during dogfood cycle 1 (docs/reports/dogfood-1.md, dispatch
`ctx_0931b123463e`): 1,594 stream lines from a live Claude Code TUI, one captured
line per file line. Nothing was reformatted — the collapsed words, half-painted
spinner frames, and repeated footer blocks are exactly what a caller got back from
`worker-read`. The only edit is the dispatch capability secret, replaced with
`dcap_REDACTED…`.

`TerminalCaptureCleanerTests` reads it directly, so the chrome stripper is measured
against real noise rather than a synthetic imitation of it. Do not regenerate or
tidy the file: its value is that it is untouched.
