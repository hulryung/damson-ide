# T56 — Automations fire end-to-end, headless

No automation had ever fired live. The service, scheduler, and Automations
window existed; `due` / `fireDue` were in-process only, and a just-created
automation was never due until the *next* matching slot after `createdAt`.

This worktree keeps fixes inside `Sources/OrchardRuntime/Automations/**` plus
the headless harness, automations tests, and this note. It does not touch
`WorkerVerbs.swift`, OrchardTerminals, or OrchardApp. The Orchard app was
not launched or quit.

## What changed

- `AutomationSchedule.due` treats the current UTC minute as a candidate when
  the trigger matches and that minute is not already in `lastRuns`. Creating
  `* * * * *` (or hourly at this minute) is therefore due immediately, so the
  harness can drive `due` / `fireDue` without waiting for the next hour.
- `AutomationService.due` is the observation API; `fireDue` now returns the
  persisted `AutomationRun` rows (worktree / terminal come from the existing
  host fire callback).
- RPC: `automations-due`, `automations-fire-due` (alias `automations-fireDue`).
  Optional `since` / `through` are unix seconds or ISO-8601; defaults match
  the scheduler's first pass (`distantPast` … now). The `orchard` CLI already
  routes `automations <subcommand>` onto those verbs — no CLI source edits.
- `scripts/e2e-headless.sh` creates that automation against the temp repo,
  asserts `automations due` lists it (unless the in-process scheduler already
  won the race), backgrounds `automations fire-due`, pokes the new headless
  shell so `worker-start` can reach tui-idle, then requires a fired history
  row with `worktreeId` and `terminalId`.

## Verification (this worktree, 2026-08-25)

- `swift build` — ok
- `swift test` — 938 tests, 2 skipped, 0 failures (117.95s)
- `swift build -c release` then `ORCHARD_CI_E2E=1 scripts/e2e-headless.sh` —
  `e2e-headless: PASS (repo → run/task → shell worker_done → archive/release → worktree rm → automations due/fireDue → clean SIGINT)`
