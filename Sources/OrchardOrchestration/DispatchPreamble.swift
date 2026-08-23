import Foundation

/// Builds the injected worker contract (docs/research/orca-inventory.md §1.6), ported
/// from ~/dev/orca/src/main/runtime/orchestration/preamble.ts with `orchard` CLI verbs
/// (§1.4 exact names: `send`, `check`, `ask`).
///
/// Behavioral rules (body summary, heartbeat cadence, no local prompts) live as inline
/// comments above the relevant CLI example, not as a separate prose block — LLM readers
/// anchor on examples and skim trailing prose, so rules must land at the point of use.
public enum DispatchPreamble {
    /// Heartbeat cadence. 5 minutes is frequent enough that the coordinator's
    /// stale-heartbeat check (threshold 10 min = 2×) catches a hung worker within one
    /// tick, and infrequent enough to avoid inbox spam on long tasks.
    public static let heartbeatIntervalMinutes = 5

    public enum WorkerKind: Sendable {
        /// An agent TUI that returns to its prompt — idles after worker_done so the
        /// coordinator can re-engage the terminal with a fresh preamble.
        case promptReturningAgent
        /// A bare shell — has no idle agent prompt to reuse; exits after worker_done.
        case bareShell
    }

    /// Populated only when the target worktree is behind its base. Callers must NOT
    /// pre-populate this with empty data; the drift section is a loud-but-rare signal
    /// tied to the `allow-stale-base: true` override path, and polluting it for fresh
    /// worktrees would train workers to ignore it.
    public struct BaseDrift: Sendable {
        public let base: String
        public let behind: Int
        public let recentSubjects: [String]

        public init(base: String, behind: Int, recentSubjects: [String]) {
            self.base = base
            self.behind = behind
            self.recentSubjects = recentSubjects
        }
    }

    public struct Params: Sendable {
        public var taskID: String
        /// worker_done/heartbeat are keyed on (taskId, dispatchId): a retried task has
        /// multiple dispatch rows, and keying on both prevents stale messages from a
        /// previously-failed dispatch from completing or refreshing the retry.
        public var dispatchID: String
        public var dispatchCapability: String?
        public var taskSpec: String
        public var coordinatorHandle: String
        public var workerHandle: String
        public var cliCommand: String
        public var baseDrift: BaseDrift?
        public var workerKind: WorkerKind
        /// Resolved decision-gate Q&A for this task, appended so the retry attempt
        /// starts from the human's answers instead of re-asking
        /// (docs/research/orca-inventory.md §1.8).
        public var resolvedGates: [(question: String, resolution: String)]

        public init(
            taskID: String,
            dispatchID: String,
            dispatchCapability: String? = nil,
            taskSpec: String,
            coordinatorHandle: String,
            workerHandle: String,
            cliCommand: String = "orchard",
            baseDrift: BaseDrift? = nil,
            workerKind: WorkerKind = .promptReturningAgent,
            resolvedGates: [(question: String, resolution: String)] = []
        ) {
            self.taskID = taskID
            self.dispatchID = dispatchID
            self.dispatchCapability = dispatchCapability
            self.taskSpec = taskSpec
            self.coordinatorHandle = coordinatorHandle
            self.workerHandle = workerHandle
            self.cliCommand = cliCommand
            self.baseDrift = baseDrift
            self.workerKind = workerKind
            self.resolvedGates = resolvedGates
        }
    }

    public static func build(_ params: Params) -> String {
        let cli = params.cliCommand
        let capabilityFlag = params.dispatchCapability.map { " --dispatch-capability \($0)" } ?? ""

        let header = """
        You are working inside Orchard, a multi-agent IDE. You are a dispatched worker.
        Your coordinator's terminal handle is: \(params.coordinatorHandle)
        Your task ID is: \(params.taskID)

        You talk to the coordinator only through the CLI commands below. Do not use
        Slack, GitHub comments, or any other channel to reach a human during the run.

        \(OrchestrationContract.workerDuties)

        === CLI COMMANDS ===

          # Your Orchard CLI is exactly this command, and it is also exported into
          # this terminal as $ORCHARD_CLI_COMMAND:
          #
          #   \(cli)
          #
          # Run it verbatim, path and all. Do NOT shorten it to a bare `orchard`
          # (your login shell has no PATH entry for it and the call dies with
          # `command not found`), and do NOT substitute another orchestrator's CLI —
          # a lifecycle call sent through anything else is rejected and your Dispatch
          # never settles.

          # Report the terminal task outcome (REQUIRED exactly once).
          #
          # RULE: --body must be a 3-sentence executive summary (what you did,
          # what you found, what's left). Never send an empty body; the coordinator
          # reads the body first and only opens artifacts if it needs more detail.
          # If you produced a long-form artifact, include its path as
          # payload.reportPath so the coordinator can find it without a file search.
          #
          # RULE: send worker_done exactly once. Use --outcome succeeded when the
          # requested work is done, or replace it with --outcome failed when it is not.
          # Never encode failure only in prose and never silently exit.
          # Include BOTH taskId and dispatchId in the payload so a late completion
          # from a failed retry cannot complete the current dispatch.
          \(cli) send --from \(params.workerHandle)\(capabilityFlag) \\
            --type worker_done --subject "<short status>" \\
            --body "<3-sentence summary: what you did, what you found, what's left>" \\
            --task-id \(params.taskID) --dispatch-id \(params.dispatchID) --outcome succeeded \\
            --files-modified "path/a,path/b" \\
            --report-path "<optional: path to the full artifact>"

          # BEHAVIOR RULE: send a heartbeat every \(heartbeatIntervalMinutes) minutes
          # while actively working on the task. The coordinator uses this to
          # distinguish "still thinking" from "hung / crashed." Skip heartbeats only
          # while blocked inside `check --wait` or `ask` — those calls are
          # themselves liveness signals.
          #
          # Include BOTH taskId and dispatchId in the payload: the coordinator
          # attributes the heartbeat to the specific dispatch context, not just
          # the task, so a straggler heartbeat from a previously-failed dispatch
          # cannot mask a hung retry.
          \(cli) send --from \(params.workerHandle)\(capabilityFlag) \\
            --type heartbeat --subject "alive" \\
            --task-id \(params.taskID) --dispatch-id \(params.dispatchID) \\
            --phase "<short: investigating|implementing|reviewing|waiting>"

          # Ask the coordinator a question and block until it answers.
          #
          # BEHAVIOR RULE #1 (MUST NOT VIOLATE):
          # NEVER use a local interactive prompt (AskUserQuestion or similar);
          # use `\(cli) ask`. A local TUI prompt is invisible to the coordinator —
          # it cannot see it and cannot answer — so your session will hang forever
          # waiting on a human. Every interactive question goes through `ask` below.
          #
          # The `ask` verb durably records a question in this Dispatch's Run and
          # blocks until the coordinator replies, then prints the reply body. If the
          # call times out or disconnects, resume with the returned message ID instead
          # of creating a duplicate question.
          \(cli) ask --from \(params.workerHandle)\(capabilityFlag) \\
            --question "<your question>" \\
            --options "<optional,comma,separated>" \\
            --timeout-ms 600000

          # Escalate a blocker or failure (pre-completion, when you need the
          # coordinator to do something before you can continue):
          \(cli) send --from \(params.workerHandle)\(capabilityFlag) \\
            --type escalation --subject "Blocked: <reason>" \\
            --body "<details>" \\
            --task-id \(params.taskID) --dispatch-id \(params.dispatchID)

          # Check for messages from the coordinator:
          \(cli) check --terminal \(params.workerHandle)

        \(postWorkerDoneInstructions(cli: cli, workerKind: params.workerKind))
        """

        let drift = params.baseDrift.flatMap { $0.behind > 0 ? driftSection($0) : nil } ?? ""
        let gates = params.resolvedGates.isEmpty ? "" : resolvedGatesSection(params.resolvedGates)

        return """
        \(header)\(drift)\(gates)

        === TASK ===
        \(params.taskSpec)
        """
    }

    /// The after-worker_done behavior split: re-dispatch reaches idle agents as terminal
    /// input, so a prompt-returning agent idles at its prompt (polling after completion
    /// cannot receive a new TASK block and looks hung), while a bare shell exits.
    private static func postWorkerDoneInstructions(cli: String, workerKind: WorkerKind) -> String {
        switch workerKind {
        case .bareShell:
            return """
            === AFTER YOU SEND worker_done ===

            worker_done ends your turn for this task. Your dispatched work is complete:
            stop and take no further actions — do NOT start new or unrelated work,
            do NOT run a sleep/poll loop, and do NOT keep calling
            `\(cli) check`. The coordinator has already recorded your
            completion and expects no further output.

            Exit the shell after completion. Bare-shell workers have no idle agent
            prompt for Orchard to reuse; if the coordinator has more for you it will
            dispatch or prompt another worker with a fresh TASK block.
            """
        case .promptReturningAgent:
            return """
            === AFTER YOU SEND worker_done ===

            worker_done ends your turn for this task. Your dispatched work is complete:
            stop, return to an idle prompt, and take no further actions — do NOT start
            new or unrelated work, do NOT run a sleep/poll loop, and do NOT keep calling
            `\(cli) check`. The coordinator has already recorded your
            completion and expects no further output.

            A direct instruction from the user takes precedence over this idle rule.
            Treat it as new user-owned work: follow it without coordinator approval or a
            fresh Dispatch, and do not send lifecycle messages using the settled task or
            Dispatch IDs. Never refuse a direct user request because you were a worker.

            Do not exit the shell. Your terminal stays available, and if the
            coordinator has more for you it will re-engage this terminal with a fresh
            preamble + TASK block, which arrives as new input. Treat that as supervised
            work under the new Dispatch; ignore stale follow-ups from the settled task.
            """
        }
    }

    private static func driftSection(_ drift: BaseDrift) -> String {
        let subjects = drift.recentSubjects.map { "  - \($0)" }.joined(separator: "\n")
        return """


        --- BASE DRIFT ---
        Your worktree HEAD is \(drift.behind) commits behind \(drift.base). The most recent
        subjects on \(drift.base) NOT in your worktree:
        \(subjects)

        If any look relevant to your task, either pull them in (`git pull --rebase
        \(drift.base)` or equivalent) or escalate to the coordinator before starting.
        ---
        """
    }

    private static func resolvedGatesSection(_ gates: [(question: String, resolution: String)]) -> String {
        let entries = gates
            .map { "  Q: \($0.question)\n  A: \($0.resolution)" }
            .joined(separator: "\n\n")
        return """


        === RESOLVED DECISION GATES ===
        Earlier attempts at this task were blocked on questions a human has since
        answered. Work from these answers; do not re-ask them:

        \(entries)
        """
    }
}
