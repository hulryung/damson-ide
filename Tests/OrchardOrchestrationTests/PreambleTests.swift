import XCTest
@testable import OrchardOrchestration

/// The injected worker contract (§1.6): real IDs inlined, the required behavioral rules
/// present, the after-worker_done split by worker kind, drift section gated on real drift.
final class PreambleTests: XCTestCase {
    private func params(
        capability: String? = "dcap_secret123",
        drift: DispatchPreamble.BaseDrift? = nil,
        kind: DispatchPreamble.WorkerKind = .promptReturningAgent
    ) -> DispatchPreamble.Params {
        DispatchPreamble.Params(
            taskID: "task_1234",
            dispatchID: "ctx_5678",
            dispatchCapability: capability,
            taskSpec: "Implement the flux capacitor.",
            coordinatorHandle: "term_coord",
            workerHandle: "term_worker",
            baseDrift: drift,
            workerKind: kind)
    }

    func testInlinesRealIDsAndCapability() {
        let text = DispatchPreamble.build(params())
        XCTAssertTrue(text.contains("Your task ID is: task_1234"))
        XCTAssertTrue(text.contains("Your coordinator's terminal handle is: term_coord"))
        XCTAssertTrue(text.contains("--task-id task_1234 --dispatch-id ctx_5678 --outcome succeeded"))
        XCTAssertTrue(text.contains("--dispatch-capability dcap_secret123"))
        XCTAssertTrue(text.contains("orchard send --from term_worker"))
        XCTAssertTrue(text.hasSuffix("=== TASK ===\nImplement the flux capacitor."))
    }

    func testOmittedCapabilityOmitsFlag() {
        let text = DispatchPreamble.build(params(capability: nil))
        XCTAssertFalse(text.contains("--dispatch-capability"))
    }

    func testRequiredBehavioralRulesArePresent() {
        let text = DispatchPreamble.build(params())
        // worker_done exactly once, with the 3-sentence body rule.
        XCTAssertTrue(text.contains("REQUIRED exactly once"))
        XCTAssertTrue(text.contains("3-sentence executive summary"))
        // Heartbeat cadence and its dispatch-keying rationale.
        XCTAssertTrue(text.contains("send a heartbeat every 5 minutes"))
        XCTAssertTrue(text.contains("cannot mask a hung retry"))
        // The never-local-prompts rule.
        XCTAssertTrue(text.contains("BEHAVIOR RULE #1"))
        XCTAssertTrue(text.contains("NEVER use a local interactive prompt"))
        XCTAssertTrue(text.contains("orchard ask"))
        // Escalation path.
        XCTAssertTrue(text.contains("--type escalation"))
    }

    func testPromptReturningAgentIdlesAfterWorkerDone() {
        let text = DispatchPreamble.build(params(kind: .promptReturningAgent))
        XCTAssertTrue(text.contains("=== AFTER YOU SEND worker_done ==="))
        XCTAssertTrue(text.contains("return to an idle prompt"))
        XCTAssertTrue(text.contains("Do not exit the shell."))
        // The direct-user-instruction carve-out.
        XCTAssertTrue(text.contains("Never refuse a direct user request because you were a worker."))
    }

    func testBareShellExitsAfterWorkerDone() {
        let text = DispatchPreamble.build(params(kind: .bareShell))
        XCTAssertTrue(text.contains("Exit the shell after completion."))
        XCTAssertFalse(text.contains("Do not exit the shell."))
    }

    func testDriftSectionOnlyForRealDrift() {
        let noDrift = DispatchPreamble.build(params(drift: nil))
        XCTAssertFalse(noDrift.contains("BASE DRIFT"))

        // behind == 0 emits nothing — polluting the section for fresh worktrees would
        // train workers to ignore it.
        let zeroDrift = DispatchPreamble.build(
            params(drift: .init(base: "origin/main", behind: 0, recentSubjects: [])))
        XCTAssertFalse(zeroDrift.contains("BASE DRIFT"))

        let realDrift = DispatchPreamble.build(
            params(drift: .init(
                base: "origin/main", behind: 4,
                recentSubjects: ["Fix crash on boot", "Add settings pane"])))
        XCTAssertTrue(realDrift.contains("--- BASE DRIFT ---"))
        XCTAssertTrue(realDrift.contains("4 commits behind origin/main"))
        XCTAssertTrue(realDrift.contains("  - Fix crash on boot"))
        // Drift lands before the task spec so the worker reads it from line 1.
        let driftRange = try? XCTUnwrap(realDrift.range(of: "BASE DRIFT"))
        let taskRange = try? XCTUnwrap(realDrift.range(of: "=== TASK ==="))
        if let driftRange, let taskRange {
            XCTAssertLessThan(driftRange.lowerBound, taskRange.lowerBound)
        }
    }

    func testCustomCLICommandReplacesVerbPrefix() {
        var custom = params()
        custom.cliCommand = "orchard-dev"
        let text = DispatchPreamble.build(custom)
        XCTAssertTrue(text.contains("orchard-dev send --from term_worker"))
        XCTAssertTrue(text.contains("orchard-dev check --terminal term_worker"))
        XCTAssertFalse(text.contains("orchard send "))
    }

    /// T35 (dogfood-1 finding 2): the worker ran the preamble's commands literally,
    /// got `command not found: orchard`, and stalled short of settlement. Every
    /// lifecycle example must carry the runtime's absolute command, and the preamble
    /// must say so rather than leaving the worker to notice.
    func testAbsoluteCLICommandIsUsedEverywhereAndCalledOut() {
        let absolute = "/Users/dkkang/dev/damson-ide/.build/release/orchard"
        var custom = params()
        custom.cliCommand = absolute
        let text = DispatchPreamble.build(custom)

        for verb in ["send", "check", "ask"] {
            XCTAssertTrue(text.contains("\(absolute) \(verb) "),
                          "\(verb) is not shown with the absolute command")
        }
        XCTAssertTrue(text.contains("Your Orchard CLI is exactly this command"))
        XCTAssertTrue(text.contains("$ORCHARD_CLI_COMMAND"),
                      "the preamble must name the env var carrying the same path")
        XCTAssertTrue(text.contains("`command not found`"),
                      "the preamble must say why a bare `orchard` fails")

        // No runnable line may start with a bare `orchard` — that is the exact string
        // the dogfood worker copied.
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(trimmed.hasPrefix("orchard "),
                           "a bare orchard invocation survived: \(trimmed)")
        }
    }

    /// The command string is inlined verbatim, spaces and all, so a path inside a
    /// directory with a space still reads as one command to copy.
    func testCLICommandIsInlinedVerbatim() {
        var custom = params()
        custom.cliCommand = "/Applications/My Tools/orchard"
        let text = DispatchPreamble.build(custom)
        XCTAssertTrue(text.contains("/Applications/My Tools/orchard send --from term_worker"))
    }

    func testGuideAndPreambleShareWorkerDutiesSource() {
        let preamble = DispatchPreamble.build(params())
        XCTAssertTrue(preamble.contains(OrchestrationContract.workerDuties))
        XCTAssertTrue(OrchestrationContract.coordinatorGuide.contains(
            OrchestrationContract.workerDuties))
        XCTAssertTrue(OrchestrationContract.coordinatorGuide.contains("worker-start` receipt"))
        XCTAssertTrue(OrchestrationContract.coordinatorGuide.contains("check --ack"))
        XCTAssertEqual(OrchestrationContract.topics, ["orchestration"])
    }
}
