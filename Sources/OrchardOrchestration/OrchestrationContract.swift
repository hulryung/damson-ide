import Foundation

/// Version-matched orchestration prose shared by the binary guide and every
/// injected Dispatch preamble. Behavioral rules belong here so the two surfaces
/// cannot silently teach different lifecycle contracts.
public enum OrchestrationContract {
    public static let topics = ["orchestration"]

    public static let workerDuties = """
    ## Worker duties

    A worker must send `worker_done` exactly once with its Task ID, Dispatch ID,
    dispatch capability, explicit `succeeded|failed` outcome, and a three-sentence
    executive summary. It sends a heartbeat every five minutes while actively
    working, uses `ask` (then `ask --resume`) for blocking human decisions, and uses
    `escalation` only when coordinator action is required before completion.

    The injected dispatch capability is secret, attempt-scoped authority: never
    omit it, reuse it for another Dispatch, or expose it outside lifecycle calls.
    After `worker_done`, stop work and return to the idle agent prompt; a fresh Task
    arrives only in a fresh Dispatch preamble.
    """

    public static let coordinatorGuide = """
    # Orchard orchestration

    Create or bind one Run, create the full ready Task wave (including dependency
    edges), then start every independent worker before waiting. Treat the Run as the
    coordinator inbox, each Task as the durable work item, and each Dispatch as one
    attempt with its own capability and terminal ownership.

    ## Coordinator loop

    Read every `worker-start` receipt before continuing. `ready` with setup still
    running is valid for start-immediately repositories; failures report their stage,
    effects, and residual resources and must not be blindly retried. Required remote
    or launch-preference capabilities must be advertised before using those options.

    Wait with `check --wait --types worker_done,escalation,question`. A Delivery is a
    bounded FIFO batch and replays unchanged until acknowledged. Process every message,
    answer questions, and make the release/retain decision for each accepted completion
    before `check --ack <delivery-id> --wait`; never acknowledge first.

    On accepted `worker_done`, immediately reuse the exact terminal with a fresh
    `worker-start --terminal` when the same agent owns follow-up work. Otherwise run
    `worker-release` after succeeded and failed outcomes; release archives inspectable
    output before closing only a proven owned terminal. Use `worker-retain` solely for
    an explicit debugging hold, and never replace uncertain release with terminal close.

    ## Capabilities

    Lifecycle mutations require the Dispatch's attempt-scoped capability plus matching
    Task and Dispatch IDs. Connected-server placement, lifecycle settlement, transcript
    reads, and launch preferences must degrade to typed unsupported/fallback receipts
    when the runtime does not advertise their capabilities.

    ## Terminals

    The CLI exposes the runtime terminal lifecycle directly: `terminal list`,
    `create`, `read`, `send`, `wait`, `close`, and `rename`. Address an existing
    terminal with `--terminal <handle>`; use cursor reads for incremental output and
    `--screen` for its rendered grid. A complete smoke path is scriptable without the
    app: create a terminal, send text with `--enter`, read or wait for it, then verify
    it still appears in `terminal list`. `terminal split` is reserved but currently
    returns the typed `not_implemented` error.

    \(workerDuties)
    """
}
