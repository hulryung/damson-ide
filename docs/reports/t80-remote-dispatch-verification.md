# T80 live verification — supervised dispatch across a host boundary (2026-08-26)

Run by the coordinator: the T80 worker died mid-review (10 hours of silence) with its
work uncommitted; the code was found building clean with the full suite green (1225
tests), committed on its branch, merged, and then verified live against the
`orchard-loopback` harness (docs/reports/remote-verification.md).

## What crossed the boundary

| Step | Evidence |
|---|---|
| Probe before creating anything | `worker-start` ran the CLI over ssh with the identity the pane would carry; the far side answered with **this** runtime |
| Dispatch created on a remote worktree | `dispatchId ctx_b7e58459c0f6`, terminal created on `ssh:orchard-loopback` — the placement that answered `remote_unsupported` for eleven waves |
| Preamble delivered | the remote pane holds the full contract: capability `dcap_odSPxmTaVpD152…`, task/dispatch ids, and the CLI's absolute path |
| Far side reached the runtime | the remote CLI answered from `rt_fb3c96e6-…`, the app's live runtime — and a first attempt was refused typed (`invalid_argument`, missing `--outcome`) rather than silently accepted |
| `worker_done` over the tunnel | dispatch went to **completed** at 11:37:16 |
| Release + archive | `released`, 76 raw / 53 readable lines captured from the remote pane |

## Defect found while verifying: a shell worker cannot run its task

`worker-start --agent shell` injects the dispatch preamble into the pane **as shell
input**. The preamble contains quotes, so the shell opens a quote and sits in
continuation: every later line is echoed and nothing executes. Reproduced identically
on a **local** worker (`ctx_eb6d9a19b29f`) and the remote one, so it is not
remote-specific. A single `terminal send --interrupt` restores the shell and commands
run normally — which is how this verification finished.

This is the supervised-dispatch sibling of dogfood-4's finding 2: T60 fixed exactly
this for automation fires by routing them through a `dispatch-input shell-command`
stage, and `worker-start` never adopted it. An agent-TUI worker is unaffected (the
preamble is a prompt there, not shell input).

Filed as T82.
