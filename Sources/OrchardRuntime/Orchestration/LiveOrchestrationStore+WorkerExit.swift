import Foundation
import OrchardOrchestration
import OrchardProtocol
import OrchardTerminals

// T11: worker-process-exit auto-escalation (docs/research/orca-inventory.md §1.8).
// The terminal service reports every PTY end; when the pane carries a LIVE supervised
// dispatch, the dispatch fails (workerProcessExited) — and unless the exit was
// deliberate (coordinator worker-stop/release, user close), a priority-high
// `escalation` lands in the Run's mailbox and wakes `check --wait`.
extension LiveOrchestrationStore {
    /// Entry point for `TerminalService.onTerminalExit`. Fire-and-forget from the
    /// terminal layer's perspective: failures are logged, never thrown back into the
    /// PTY teardown path.
    public func handleWorkerTerminalExit(_ event: TerminalExitEvent) async {
        do {
            try reconcileWorkerTerminalExit(event)
        } catch {
            NSLog("orchard: worker terminal exit reconciliation failed for %@: %@",
                  event.handle, String(describing: error))
        }
    }

    private func reconcileWorkerTerminalExit(_ event: TerminalExitEvent) throws {
        // Lookup by handle OR pane key: a reminted handle no longer matches, but the
        // pane outlives it (§1.8). Only live (pending/dispatched) dispatches resolve.
        guard let dispatch = try store.activeDispatchForAssignee(
            handle: event.handle, paneKey: event.paneKey) else {
            return
        }
        // Only supervised dispatches: `dispatch --inject` assignments have no worker
        // row and their processes are never lifecycle-managed here.
        guard let worker = try store.workerDispatch(dispatch.id) else { return }
        if worker.state.isSettled { return }
        if worker.state == .stopping {
            // A coordinator worker-stop is mid-flight and owns the settlement
            // (`settleWorkerStop` runs right after its closeTerminal returns).
            return
        }

        let exitCode = event.exitCode.map(String.init) ?? "unknown"
        let reason = event.deliberate ? "deliberate_close" : "worker_process_exited"
        let error = event.deliberate
            ? "The worker terminal was closed while Dispatch \(dispatch.id) was live."
            : "The worker terminal process exited (code \(exitCode)) while Dispatch \(dispatch.id) was live."
        _ = try store.failDispatch(dispatch.id, error: error,
                                   workerProcessExited: true, terminationReason: reason)

        if !event.deliberate {
            // `sendMessage` notifies the Run's waiters after commit, so a parked
            // `check --wait` wakes on the escalation itself.
            _ = try store.sendMessage(OutboundMessage(
                from: event.handle,
                senderPaneKey: event.paneKey,
                to: "run:\(dispatch.runID)",
                runID: dispatch.runID,
                subject: "Worker process exited (task \(dispatch.taskID))",
                body: error + " The dispatch was failed automatically; inspect with "
                    + "worker-show --dispatch \(dispatch.id), then retry via "
                    + "worker-start --retry-of \(dispatch.id) or fail the task.",
                type: .escalation,
                priority: .high,
                payload: Self.encodeReceipt(.object([
                    "taskId": .string(dispatch.taskID),
                    "dispatchId": .string(dispatch.id),
                    "exitCode": event.exitCode.map { .number(Double($0)) } ?? .null,
                    "terminationReason": .string(reason),
                ]))))
        }
        // Wake anything blocked on the dispatch itself (a parked `ask`, worker-mode
        // `check --wait`) so it re-reads the now-settled state.
        waitCenter.notifyMessageArrived(recipient: "dispatch:\(dispatch.id)", type: .status)
    }
}
