import Foundation
import OrchardOrchestration

/// UI-free row models for the in-app orchestration view (docs/REBUILD-PLAN.md T44).
/// Built from store rows only — no SwiftUI, no mutation, no terminal I/O.

public struct OrchestrationTaskCounts: Equatable, Sendable {
    public let total: Int
    public let pending: Int
    public let ready: Int
    public let dispatched: Int
    public let completed: Int
    public let failed: Int
    public let blocked: Int

    public init(total: Int, pending: Int, ready: Int, dispatched: Int,
                completed: Int, failed: Int, blocked: Int) {
        self.total = total
        self.pending = pending
        self.ready = ready
        self.dispatched = dispatched
        self.completed = completed
        self.failed = failed
        self.blocked = blocked
    }

    public var summary: String {
        if total == 0 { return "0 tasks" }
        var parts: [String] = ["\(total) task\(total == 1 ? "" : "s")"]
        if dispatched > 0 { parts.append("\(dispatched) dispatched") }
        if ready > 0 { parts.append("\(ready) ready") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if failed > 0 { parts.append("\(failed) failed") }
        if completed > 0 { parts.append("\(completed) completed") }
        return parts.joined(separator: " · ")
    }
}

public struct OrchestrationDispatchRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let dispatchStatus: String
    public let workerState: String
    public let terminalState: String?
    public let agentHandle: String?
    public let hasArchive: Bool

    public init(id: String, dispatchStatus: String, workerState: String,
                terminalState: String?, agentHandle: String?, hasArchive: Bool) {
        self.id = id
        self.dispatchStatus = dispatchStatus
        self.workerState = workerState
        self.terminalState = terminalState
        self.agentHandle = agentHandle
        self.hasArchive = hasArchive
    }
}

public struct OrchestrationTaskRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let deps: [String]
    public let displayName: String
    public let title: String
    public let spec: String
    public let dispatches: [OrchestrationDispatchRow]

    public init(id: String, status: String, deps: [String], displayName: String,
                title: String, spec: String, dispatches: [OrchestrationDispatchRow]) {
        self.id = id
        self.status = status
        self.deps = deps
        self.displayName = displayName
        self.title = title
        self.spec = spec
        self.dispatches = dispatches
    }

    /// Prefer display name, then title, then a short spec — the outline label.
    public var label: String {
        if !displayName.isEmpty { return displayName }
        if !title.isEmpty { return title }
        return spec
    }
}

public struct OrchestrationRunRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let objective: String
    public let createdAt: String
    public let counts: OrchestrationTaskCounts
    public let tasks: [OrchestrationTaskRow]

    public init(id: String, objective: String, createdAt: String,
                counts: OrchestrationTaskCounts, tasks: [OrchestrationTaskRow]) {
        self.id = id
        self.objective = objective
        self.createdAt = createdAt
        self.counts = counts
        self.tasks = tasks
    }
}

public struct OrchestrationViewSnapshot: Equatable, Sendable {
    public let runs: [OrchestrationRunRow]
    public static let empty = OrchestrationViewSnapshot(runs: [])

    public init(runs: [OrchestrationRunRow]) {
        self.runs = runs
    }
}

/// Archive text as `worker-read` serves it: cleaned `lines` by default, `rawLines`
/// when the caller asks for the untouched capture. Transcript pins expose the
/// pinned document rather than a TUI tail.
public struct OrchestrationArchiveView: Equatable, Sendable {
    public let dispatchID: String
    public let kind: String
    public let cleanedLines: [String]
    public let rawLines: [String]
    public let transcript: String?

    public init(dispatchID: String, kind: String, cleanedLines: [String],
                rawLines: [String], transcript: String?) {
        self.dispatchID = dispatchID
        self.kind = kind
        self.cleanedLines = cleanedLines
        self.rawLines = rawLines
        self.transcript = transcript
    }

    public var isTranscript: Bool { kind == WorkerTerminalArchiveKind.transcriptPin.rawValue }

    /// Same choice `worker-read --raw` makes for a terminal-tail archive.
    public func lines(showRaw: Bool) -> [String] {
        if isTranscript {
            guard let transcript else { return [] }
            return transcript.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map(String.init)
        }
        return showRaw ? rawLines : cleanedLines
    }
}

/// Projection from store rows / archive JSON onto the view models. Observation
/// only — never writes the store.
public enum OrchestrationProjection {
    public static let specLimit = 80

    public static func abbreviateSpec(_ spec: String, limit: Int = specLimit) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// `display_name` wins, then `task_title`, then a short spec — matches
    /// `task-list --brief` title fallback.
    public static func displayName(displayName: String?, taskTitle: String?, spec: String) -> String {
        if let name = nonempty(displayName) { return name }
        if let title = nonempty(taskTitle) { return title }
        return abbreviateSpec(spec)
    }

    public static func title(displayName: String?, taskTitle: String?, spec: String) -> String {
        if let title = nonempty(taskTitle) { return title }
        if let name = nonempty(displayName) { return name }
        return abbreviateSpec(spec)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func counts(statuses: [String]) -> OrchestrationTaskCounts {
        var pending = 0, ready = 0, dispatched = 0, completed = 0, failed = 0, blocked = 0
        for status in statuses {
            switch status {
            case TaskStatus.pending.rawValue: pending += 1
            case TaskStatus.ready.rawValue: ready += 1
            case TaskStatus.dispatched.rawValue: dispatched += 1
            case TaskStatus.completed.rawValue: completed += 1
            case TaskStatus.failed.rawValue: failed += 1
            case TaskStatus.blocked.rawValue: blocked += 1
            default: break
            }
        }
        return OrchestrationTaskCounts(
            total: statuses.count, pending: pending, ready: ready,
            dispatched: dispatched, completed: completed, failed: failed, blocked: blocked)
    }

    /// Mirrors `WorkerTerminalListState.derive` with primitives so the view (and
    /// its tests) never construct store row objects.
    public static func terminalState(
        workerState: String,
        agentHandle: String?,
        releaseState: String?,
        ownershipState: String?
    ) -> String? {
        WorkerTerminalListState.derive(
            workerState: workerState,
            agentTerminalHandle: agentHandle,
            releaseState: releaseState,
            ownershipState: ownershipState
        )?.rawValue
    }

    public static func dispatchRow(
        id: String,
        dispatchStatus: String,
        workerState: String,
        agentHandle: String?,
        releaseState: String?,
        ownershipState: String?,
        hasArchive: Bool
    ) -> OrchestrationDispatchRow {
        OrchestrationDispatchRow(
            id: id,
            dispatchStatus: dispatchStatus,
            workerState: workerState,
            terminalState: terminalState(
                workerState: workerState,
                agentHandle: agentHandle,
                releaseState: releaseState,
                ownershipState: ownershipState),
            agentHandle: agentHandle,
            hasArchive: hasArchive)
    }

    public static func taskRow(
        id: String,
        status: String,
        deps: [String],
        displayName: String?,
        taskTitle: String?,
        spec: String,
        dispatches: [OrchestrationDispatchRow]
    ) -> OrchestrationTaskRow {
        OrchestrationTaskRow(
            id: id,
            status: status,
            deps: deps,
            displayName: self.displayName(displayName: displayName, taskTitle: taskTitle, spec: spec),
            title: title(displayName: displayName, taskTitle: taskTitle, spec: spec),
            spec: spec,
            dispatches: dispatches)
    }

    public static func runRow(
        id: String,
        objective: String,
        createdAt: String,
        tasks: [OrchestrationTaskRow]
    ) -> OrchestrationRunRow {
        OrchestrationRunRow(
            id: id,
            objective: objective,
            createdAt: createdAt,
            counts: counts(statuses: tasks.map(\.status)),
            tasks: tasks)
    }

    /// Decode a `worker_terminal_archives.content` blob the same way `worker-read`
    /// does: `lines` / `rawLines` for a terminal tail, `content` for a transcript pin.
    public static func archiveView(dispatchID: String, kind: String, contentJSON: String)
        -> OrchestrationArchiveView {
        let parsed = parseJSON(contentJSON)
        if kind == WorkerTerminalArchiveKind.transcriptPin.rawValue {
            let transcript: String?
            if let object = parsed as? [String: Any] {
                transcript = object["content"] as? String ?? stringify(parsed)
            } else if let text = parsed as? String {
                transcript = text
            } else {
                transcript = contentJSON.isEmpty ? nil : contentJSON
            }
            return OrchestrationArchiveView(
                dispatchID: dispatchID, kind: kind,
                cleanedLines: [], rawLines: [], transcript: transcript)
        }
        let object = parsed as? [String: Any]
        let cleaned = stringArray(object?["lines"])
        let raw = stringArray(object?["rawLines"])
        return OrchestrationArchiveView(
            dispatchID: dispatchID, kind: kind,
            cleanedLines: cleaned,
            rawLines: raw.isEmpty ? cleaned : raw,
            transcript: nil)
    }

    public static func snapshot(
        runs: [OrchestrationRun],
        tasks: [OrchestrationTask],
        workers: [WorkerListRow],
        archivedDispatchIDs: Set<String>
    ) -> OrchestrationViewSnapshot {
        let tasksByRun = Dictionary(grouping: tasks, by: \.runID)
        let workersByTask = Dictionary(grouping: workers, by: \.taskID)
        let rows = runs.map { run in
            let runTasks = (tasksByRun[run.id] ?? []).map { task in
                let dispatches = (workersByTask[task.id] ?? []).map { worker in
                    dispatchRow(
                        id: worker.dispatchID,
                        dispatchStatus: worker.dispatchStatus.rawValue,
                        workerState: worker.workerState,
                        agentHandle: worker.agentTerminalHandle,
                        releaseState: worker.resource?.releaseState.rawValue,
                        ownershipState: worker.resource?.ownershipState.rawValue,
                        hasArchive: archivedDispatchIDs.contains(worker.dispatchID))
                }
                return taskRow(
                    id: task.id,
                    status: task.status.rawValue,
                    deps: task.deps,
                    displayName: task.displayName,
                    taskTitle: task.taskTitle,
                    spec: task.spec,
                    dispatches: dispatches)
            }
            return runRow(
                id: run.id,
                objective: run.objective,
                createdAt: run.createdAt,
                tasks: runTasks)
        }
        return OrchestrationViewSnapshot(runs: rows)
    }

    // MARK: - JSON

    private static func parseJSON(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return parsed
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func stringify(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
