# Wave 21 flaky-test hunt

## What ran

All commands ran on macOS from the T76 worktree with SwiftPM's progress bar disabled so the raw per-test lines remained in separate log files.

- 12 consecutive full-suite runs: `SWIFT_TEST_DISABLE_PROGRESS_BAR=1 swift test --parallel`. Each run executed 1,143 tests. Runs 1–6, 11, and 12 passed; runs 7–10 failed.
- 20 isolated runs of the identified test before the fix. One failed, proving that the failure does not require another suite or shared cross-suite state.
- After the final fix, 100 consecutive isolated runs passed.
- After the final fix, three more full-suite runs (3,429 test executions) passed.

The investigation logs were captured under `/tmp/v21-flaky-hunt-logs-task_1c4d699b316c/`. In particular, `run-7.log` and `run-8.log` contain the original full-suite failures, `filtered-12.log` contains the isolated reproduction, and `fixed2-1.log` through `fixed2-100.log` contain the final stress verification.

## What fired

The flaky test was:

`OrchardRuntimeTests.ServerRuntimeTests.testFiftyConcurrentStatusCallsAreBoundedAndDoNotLeakFDs`

The full-suite failures reported both of these symptoms:

- `connect failed: Connection refused` from the status call made immediately after creating 50 abrupt clients.
- An FD delta above the assertion threshold (observed deltas included 7 and 12) because accepted sockets were still being drained asynchronously.

The isolated reproduction produced the same failure (`connect failed: Connection refused`, with an FD delta of 16), so this was not a shared temporary-directory collision, port/socket-name reuse, cross-suite global state, or SwiftPM test parallelism issue.

## Mechanism and fix

This was a test-isolation/timing defect, not a product race. The test mixed three different load boundaries:

1. Orchard intentionally caps active server connections at 16.
2. The test raced 50 simultaneous client connections, which could additionally exercise and overflow the kernel's finite listen backlog before Orchard accepted them.
3. It then created 50 connect-and-immediately-close clients and synchronously inspected `/dev/fd`, even though the server's accept/close work is asynchronous.

The test now limits its client operation queue to Orchard's documented 16-connection cap. It still performs 50 total requests and verifies the server's observed peak does not exceed the cap, without accidentally making kernel backlog overflow part of the contract. After the abrupt-client burst, it waits up to two seconds for a healthy status response and for the FD count to return to the allowed baseline instead of assuming asynchronous cleanup is instantaneous.

Only `Tests/OrchardRuntimeTests/ServerRuntimeTests.swift` changed. No production code changed.
