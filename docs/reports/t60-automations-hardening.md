# T60 — Automations hardening (dogfood-4 findings 1–4)

Wave 16, worktree `hulryung/v16-automations-hardening`. Source findings:
`docs/reports/dogfood-4.md` findings 2, 3, 4, 5 (the plan's "findings 1–4").

Ownership kept to `Sources/OrchardRuntime/Automations/**` (one new file), a
minimal Once option in `AutomationEditorSheet.swift`, two touchpoints that were
strictly needed (`WorkerVerbs+Start.swift` dispatch-input stage,
`RuntimeAssembly.swift` fire closure), the matching tests, and the e2e stage.
No `Sources/orchard` CLI file and no `OrchardApp/main.swift` was touched. The
Orchard app was never launched or quit; nothing was pushed.

## 1. Single fire per minute slot (finding 2)

`AutomationService` now claims a slot **in-actor, synchronously, before the
fire callback is awaited** (`inFlight: [automationId: scheduledAt]`) and
releases the claim only after the run row is persisted — both without a
suspension point, so no caller can observe "row not yet written, claim already
gone". Every path that can start a worker goes through the claim:

- `fireDue` claims all of its due slots before the first `await`, so the
  scheduler tick and CLI `automations fire-due` racing on the same minute
  produce one run and one worker (`testConcurrentFireDueFiresOneSlotExactlyOnce`
  runs two `fireDue`s against a 300 ms fire callback: one callback call, one row).
- `due` (observation, and the CLI `automations due`) hides claimed slots.
- `run(id:)` / `automations run --id` during a fire is refused typed:
  `automation_fire_in_flight`.

## 2. Shell-provider fires execute (finding 3)

Root cause, confirmed from the injection path: `worker-start` types the agent
preamble into the pane. For an agent TUI that is a prompt; for interactive zsh
it is a paste whose first apostrophe (`coordinator's`) opens a quote, so the
shell sits at its `>` continuation prompt holding the whole paste — capability
included — and nothing runs.

Fix: an automation whose provider is `shell` calls `worker-start` with the new
runtime-internal param `dispatch-input: shell-command`. The `dispatch_input`
stage then injects **one executable command line** built by
`AutomationShellDispatch.commandLine` instead of the preamble:

```
orchard_automation_command() { eval '<prompt>'; }; orchard_automation_command;
orchard_automation_status=$?; …; '<cli>' send --from '<handle>'
  --dispatch-capability '<cap>' --type worker_done --subject "automation command exited $status"
  --body "…" --task-id '<task>' --dispatch-id '<dispatch>' --outcome succeeded|failed;
exit "$orchard_automation_status"
```

- The prompt runs inside `eval` of a single-quoted argument (`'` → `'\''`), so
  the line is quote-balanced for any prompt; a prompt with its own syntax error
  fails with a status instead of stranding the shell at `quote>`.
  `testQuotingKeepsAnyPromptInsideOneQuotedArgument` proves it with `zsh -n`;
  `testCommandLineExecutesUnderZshWithAStubCLI` runs the line under real zsh
  with a stub CLI and checks argv, outcome, and exit status for exit 0 / a
  parse error / `exit 7`.
- The capability only ever appears inside a submitted line (the same exposure
  as inside a submitted agent preamble); no fire path leaves it in pending pane
  input. The receipt's `dispatch_input` effect carries `mode: shell-command`.
- `dispatch-input shell-command` with any engine other than `shell` is refused
  `invalid_argument` before a worktree or terminal exists. The default
  (`preamble`) is unchanged, so the coordinator's documented scripted-shell path
  (`worker-start --agent shell`, harness reads the capability and answers) still
  behaves exactly as the first half of the e2e expects.
- Workspace-target shell automations are unchanged (they still require an agent
  terminal of the same provider; a bare shell has none).

## 3. `once` schedule (finding 4)

`AutomationTrigger.once`. `time` is an ISO-8601 instant (`2026-08-26T07:05:00Z`,
`2026-08-26T07:05Z`, offsets honoured), `HH:mm` (the first such UTC minute at or
after the creation minute), or `now` (the creation minute). Resolution is
`AutomationSchedule.onceFireDate`; all schedule math (`validate`, `matches`,
`nextFire`, `due`) understands it.

- Due semantics: a once slot is due from the moment it has passed until a run
  is recorded for it, **regardless of the scheduler's `since` checkpoint** — a
  runtime that was down at the slot fires it on its first pass back; after that,
  never. Re-arming (edit `time`, re-enable) makes the new slot due once more.
- After its single attempt — fired, failed, or precheck-skipped — the service
  flips `enabled` off in the same store write that records the run
  (`AutomationService.onceConsumedMessage` on the fired row).
- CLI: `orchard automations create --trigger once --time now|HH:mm|<iso> …`
  works today with no CLI source change (the CLI passes `--trigger` through).
  `automations --help` still lists `hourly|daily|weekdays|weekly|five-field-cron`
  for `--trigger`; that string lives in `OrchardProtocol/CommandSpec.swift`
  (T61's file) — a one-word follow-up for T61.
- Editor: a "Once" segment with a "Fire at (ISO-8601 UTC, HH:mm, or now)" field,
  defaulting to five minutes out; list rows label a passed once slot
  `due now` / `fired · once` / `paused · once` instead of "invalid schedule".

## 4. Settlement of automation-fired workers (finding 5)

Decided semantics (also in the `AutomationShellDispatch` doc comment):

| Provider | How the dispatch settles | Then |
|---|---|---|
| `shell` | The submitted line's own `worker_done` (identity-proven, `--outcome` from the exit status), **before** the PTY ends. The T11 exit reconciler then sees a settled dispatch and does nothing — no escalation. | `worker-release --dispatch` archives the pane tail and closes the exited pane (`closed_exited_terminal`); `worktree rm` removes the worktree. |
| `shell`, but the line never reaches the runtime (CLI missing, socket gone, the prompt itself `exit`s) | The PTY end alone settles it: the T11 reconciler fails the dispatch (`worker_process_exited`, exit code in `last_error`) and escalates into the Run's mailbox as for any worker. | `worker-release` still releases (`closed_exited_terminal`). |
| agent (`claude-code`, `codex`, …) | Unchanged: the agent sends `worker_done`; the pane idles at its prompt. | Operator releases when done. |

Invariant: **an automation-fired shell worker settles on process exit**, one way
or the other; it can no longer stay `dispatched` forever, and release never
lands `retained/identity_unproven` for it. Nothing is auto-released — the exited
pane keeps the command's output for inspection, and the automation history row
now carries `dispatchId` and `orchestrationRunId` so `worker-show`,
`worker-read`, and `worker-release` are one command away. The "Automation: …"
Run, its Task, and the settled Dispatch remain as the record (dogfood-4
observation 11 applies to them too).

Not done, deliberately: auto-disable after N failures (finding 4's "and/or") —
`once` covers the dogfood use case; a failure budget is a separate policy
decision.

## Verification

- `swift build` — ok
- `swift test` — 1006 tests, 2 skipped, 0 failures (116.4 s); 986 before T60
- `swift build -c release` then `ORCHARD_CI_E2E=1 scripts/e2e-headless.sh` —
  `PASS (repo → run/task → shell worker_done → archive/release → worktree rm → automations once due/fireDue → shell worker settled on exit → release/archive → auto-disabled → clean SIGINT)`

The e2e automation stage now creates `--trigger once --time now --provider shell
--prompt "printf 'orchard-e2e-%s\n' \"$((6*7))\""`, drives `due`/`fire-due`,
requires the fired row's `dispatchId`/`orchestrationRunId`, polls `worker-show`
until the worker is `succeeded` (settled by the shell itself), checks the
`worker_done` delivery (`outcome: succeeded`) in the automation's Run, waits for
the pane's `exit`, releases (`released`, `closed_exited_terminal`), asserts the
archive contains `orchard-e2e-42` (output only execution can produce), asserts
the automation is now `enabled: false` with `fire-due` and `due` both empty,
and checks a `--disabled` cron automation is never due before removing it. The
readiness poke tolerates a pane that already ran its line and exited.

New/extended tests: `AutomationServiceTests` (+5), `AutomationScheduleTests`
(+3), `AutomationCommandHandlerTests` (+2), `AutomationViewProjectionTests`
(+1), `AutomationShellDispatchTests` (new, 5), `WorkerVerbTests` (+4:
shell-command line not preamble; worker_done-then-exit settles and releases
`closed_exited_terminal`; exit-without-worker_done settles via the reconciler
and releases; engine guard).
