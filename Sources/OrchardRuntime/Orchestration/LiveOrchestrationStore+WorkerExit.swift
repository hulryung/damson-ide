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
        if worker.state == .stopUnknown, event.deliberate {
            // The stop already ran, closed this very pane, and recorded its own verdict
            // — for a remote worker, "the connection was closed and nothing confirmed
            // the process stopped" (T80). The PTY end that follows *is* that close, so
            // reconciling it again would overwrite the stop's answer with a second,
            // weaker telling of the same event. A non-deliberate exit after a failed
            // stop is different — that is news, and it still lands below.
            return
        }

        // What the PTY's end actually proves. For a local pane the PTY *is* the worker,
        // so an exit status is proof of exit. For an `ssh:` pane the PTY holds the ssh
        // client: status 255 is OpenSSH reporting its own transport failure, which says
        // nothing about the far side (docs/design/remote-hosts.md §1, rule 2). Reading
        // that as "the worker died" is how a coordinator respawns a task onto a worktree
        // a still-live agent is editing from the other machine.
        let host = ExecutionHostId(rawValue: event.executionHostId) ?? .local
        let verdict = HostLiveness.verdictForPTYEnd(host: host, exitCode: event.exitCode)
        let unverifiable = verdict.status == "unverifiable" && !host.isLocal
        let exitCode = event.exitCode.map(String.init) ?? "unknown"
        let reason: String
        let error: String
        if event.deliberate {
            reason = "deliberate_close"
            error = unverifiable
                ? "The worker's connection to \(host.name) was closed while Dispatch "
                    + "\(dispatch.id) was live. Whether anything is still running there "
                    + "is unverifiable — \(verdict.reason ?? HostLiveness.connectionLostReason)."
                : "The worker terminal was closed while Dispatch \(dispatch.id) was live."
        } else if unverifiable {
            // The supervision is over either way — this runtime can no longer reach the
            // worker, so the dispatch cannot stay open — but the sentence that settles it
            // must not issue a death certificate nobody signed.
            reason = "connection_lost_unverifiable"
            error = "The connection to \(host.name) ended while Dispatch \(dispatch.id) "
                + "was live. Whether the worker is still running there is unverifiable — "
                + "\(verdict.reason ?? HostLiveness.connectionLostReason). Nothing on "
                + "\(host.name) was stopped; do not respawn this task onto the same "
                + "worktree until the host has been checked."
        } else {
            reason = "worker_process_exited"
            error = host.isLocal
                ? "The worker terminal process exited (code \(exitCode)) while Dispatch \(dispatch.id) was live."
                : "The connection to \(host.name) closed and the remote worker exited "
                    + "(status \(exitCode)) while Dispatch \(dispatch.id) was live."
        }
        _ = try store.failDispatch(
            dispatch.id, error: error, workerProcessExited: true,
            terminationReason: reason,
            // The stage is the claim the worker row makes about the process. Only an
            // exit that was actually reported gets to say `process_exited`.
            workerStage: unverifiable ? "connection_lost" : "process_exited")

        if !event.deliberate {
            // `sendMessage` notifies the Run's waiters after commit, so a parked
            // `check --wait` wakes on the escalation itself.
            _ = try store.sendMessage(OutboundMessage(
                from: event.handle,
                senderPaneKey: event.paneKey,
                to: "run:\(dispatch.runID)",
                runID: dispatch.runID,
                subject: unverifiable
                    ? "Worker connection to \(host.name) lost (task \(dispatch.taskID))"
                    : "Worker process exited (task \(dispatch.taskID))",
                body: error + " The dispatch was failed automatically; inspect with "
                    + "worker-show --dispatch \(dispatch.id), then "
                    + (unverifiable
                        ? "check the host (`host check --name \(host.name)`) before "
                            + "retrying — a retry into the same worktree while a live "
                            + "agent may still hold it is the failure rule 2 exists to "
                            + "prevent."
                        : "retry via worker-start --retry-of \(dispatch.id) or fail the task."),
                type: .escalation,
                priority: .high,
                payload: Self.encodeReceipt(.object([
                    "taskId": .string(dispatch.taskID),
                    "dispatchId": .string(dispatch.id),
                    "exitCode": event.exitCode.map { .number(Double($0)) } ?? .null,
                    "terminationReason": .string(reason),
                    "executionHostId": .string(event.executionHostId),
                    // The verdict vocabulary, on the wire, so a coordinator does not
                    // have to re-derive it from an exit code and a host id.
                    "livenessVerdict": .string(verdict.status),
                ]))))
        }
        // Wake anything blocked on the dispatch itself (a parked `ask`, worker-mode
        // `check --wait`) so it re-reads the now-settled state.
        waitCenter.notifyMessageArrived(recipient: "dispatch:\(dispatch.id)", type: .status)
    }
}
