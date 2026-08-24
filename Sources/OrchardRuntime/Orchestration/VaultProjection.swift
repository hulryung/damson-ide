import Foundation
import OrchardOrchestration

/// UI-free row models for the Vault — the cross-run browser over what workers left
/// behind (docs/REBUILD-PLAN.md T49). Built from store records only: no SwiftUI, no
/// mutation, no terminal I/O. The app renders these; the tests exercise them directly.

public struct VaultArchiveRow: Equatable, Sendable, Identifiable {
    public var id: String { dispatchID }
    public let dispatchID: String
    /// `terminal_tail` or `transcript_pin`.
    public let kind: String
    public let createdAt: String
    public let byteSize: Int
    public let agentHandle: String?
    public let engineID: String?
    public let workerState: String
    public let dispatchStatus: String
    /// Lowercased haystack the filter matches against: ids, labels, handles, engine,
    /// kind, and the bounded content prefix the store scanned.
    public let searchText: String
    /// The stored archive is longer than what the filter scanned.
    public let contentScanTruncated: Bool

    public init(dispatchID: String, kind: String, createdAt: String, byteSize: Int,
                agentHandle: String?, engineID: String?, workerState: String,
                dispatchStatus: String, searchText: String, contentScanTruncated: Bool) {
        self.dispatchID = dispatchID
        self.kind = kind
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.agentHandle = agentHandle
        self.engineID = engineID
        self.workerState = workerState
        self.dispatchStatus = dispatchStatus
        self.searchText = searchText
        self.contentScanTruncated = contentScanTruncated
    }

    public var isTranscript: Bool { kind == WorkerTerminalArchiveKind.transcriptPin.rawValue }
    public var kindLabel: String { VaultProjection.kindLabel(kind) }
    public var sizeLabel: String { VaultProjection.byteLabel(byteSize) }
    /// Engine, else the handle, else the worker state — the "who produced this" chip.
    public var producerLabel: String {
        engineID ?? agentHandle ?? workerState
    }
}

public struct VaultTaskGroup: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let title: String
    public let archives: [VaultArchiveRow]

    public init(id: String, label: String, title: String, archives: [VaultArchiveRow]) {
        self.id = id
        self.label = label
        self.title = title
        self.archives = archives
    }

    public var byteSize: Int { archives.reduce(0) { $0 + $1.byteSize } }
    public var sizeLabel: String { VaultProjection.byteLabel(byteSize) }
}

public struct VaultRunGroup: Equatable, Sendable, Identifiable {
    public let id: String
    public let objective: String
    public let createdAt: String
    /// The run still holds live coordination, so retention will never prune it.
    public let isLive: Bool
    public let tasks: [VaultTaskGroup]

    public init(id: String, objective: String, createdAt: String, isLive: Bool,
                tasks: [VaultTaskGroup]) {
        self.id = id
        self.objective = objective
        self.createdAt = createdAt
        self.isLive = isLive
        self.tasks = tasks
    }

    public var archiveCount: Int { tasks.reduce(0) { $0 + $1.archives.count } }
    public var byteSize: Int { tasks.reduce(0) { $0 + $1.byteSize } }
    public var sizeLabel: String { VaultProjection.byteLabel(byteSize) }
}

public struct VaultSnapshot: Equatable, Sendable {
    public let runs: [VaultRunGroup]
    /// Characters of each archive the store scanned for the content filter.
    public let scanLimit: Int
    /// True when at least one listed archive is longer than the scan limit.
    public let scanTruncated: Bool

    public static let empty = VaultSnapshot(runs: [], scanLimit: 0, scanTruncated: false)

    public init(runs: [VaultRunGroup], scanLimit: Int, scanTruncated: Bool) {
        self.runs = runs
        self.scanLimit = scanLimit
        self.scanTruncated = scanTruncated
    }

    public var archiveCount: Int { runs.reduce(0) { $0 + $1.archiveCount } }
    public var byteSize: Int { runs.reduce(0) { $0 + $1.byteSize } }
    public var sizeLabel: String { VaultProjection.byteLabel(byteSize) }
    public var isEmpty: Bool { runs.isEmpty }

    public func archive(dispatchID: String) -> VaultArchiveRow? {
        location(dispatchID: dispatchID)?.archive
    }

    /// Where a dispatch's archive sits in the tree — the reader pane's header needs
    /// the run and task, not just the row.
    public func location(dispatchID: String)
        -> (run: VaultRunGroup, task: VaultTaskGroup, archive: VaultArchiveRow)? {
        for run in runs {
            for task in run.tasks {
                if let archive = task.archives.first(where: { $0.dispatchID == dispatchID }) {
                    return (run, task, archive)
                }
            }
        }
        return nil
    }
}

/// One entry of a parsed transcript pin. Provider transcripts are JSONL; a pin that
/// parses renders as its message stream, anything else falls back to plain text.
public struct VaultTranscriptMessage: Equatable, Sendable, Identifiable {
    public let id: Int
    public let role: String
    public let timestamp: String?
    public let text: String

    public init(id: Int, role: String, timestamp: String?, text: String) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.text = text
    }
}

/// Projection from store records onto the Vault's row models, plus the pure filter
/// and transcript decode the reader uses. Observation only — never writes the store.
public enum VaultProjection {
    /// Archives whose dispatch no longer joins to a run are grouped here rather than
    /// dropped: the Vault's job is what is on disk, including the orphans.
    public static let orphanRunID = "__orphaned__"
    public static let orphanRunObjective = "Archives with no run"
    public static let orphanTaskID = "__orphaned_task__"

    // MARK: - Grouping

    /// Group records into run → task → dispatch, preserving the store's newest-first
    /// order at every level (a run's position is where its newest archive fell).
    public static func snapshot(
        records: [WorkerArchiveRecord],
        liveRunIDs: Set<String> = [],
        scanLimit: Int = 0
    ) -> VaultSnapshot {
        var runOrder: [String] = []
        var runsByID: [String: (objective: String, createdAt: String)] = [:]
        var taskOrder: [String: [String]] = [:]
        var taskInfo: [String: (label: String, title: String)] = [:]
        var rowsByTask: [String: [VaultArchiveRow]] = [:]

        for record in records {
            let runID = record.runID ?? orphanRunID
            if runsByID[runID] == nil {
                runOrder.append(runID)
                runsByID[runID] = (
                    objective: runID == orphanRunID
                        ? orphanRunObjective
                        : (nonempty(record.runObjective) ?? runID),
                    createdAt: record.runCreatedAt ?? record.createdAt)
            }
            let taskID = record.taskID ?? orphanTaskID
            let taskKey = runID + "/" + taskID
            if taskInfo[taskKey] == nil {
                taskOrder[runID, default: []].append(taskID)
                taskInfo[taskKey] = (
                    label: taskLabel(record),
                    title: taskTitle(record))
            }
            rowsByTask[taskKey, default: []].append(row(record))
        }

        let runs = runOrder.map { runID -> VaultRunGroup in
            let info = runsByID[runID] ?? (objective: runID, createdAt: "")
            let tasks = (taskOrder[runID] ?? []).map { taskID -> VaultTaskGroup in
                let key = runID + "/" + taskID
                let labels = taskInfo[key] ?? (label: taskID, title: taskID)
                return VaultTaskGroup(
                    id: taskID, label: labels.label, title: labels.title,
                    archives: rowsByTask[key] ?? [])
            }
            return VaultRunGroup(
                id: runID, objective: info.objective, createdAt: info.createdAt,
                isLive: liveRunIDs.contains(runID), tasks: tasks)
        }
        return VaultSnapshot(
            runs: runs,
            scanLimit: scanLimit,
            scanTruncated: records.contains(where: \.contentScanTruncated))
    }

    public static func row(_ record: WorkerArchiveRecord) -> VaultArchiveRow {
        VaultArchiveRow(
            dispatchID: record.dispatchID,
            kind: record.kind.rawValue,
            createdAt: record.createdAt,
            byteSize: record.byteSize,
            agentHandle: record.agentHandle,
            engineID: record.engineID,
            workerState: record.workerState,
            dispatchStatus: record.dispatchStatus?.rawValue ?? "unknown",
            searchText: searchText(record),
            contentScanTruncated: record.contentScanTruncated)
    }

    /// Everything a filter term may match, lowercased once at projection time.
    static func searchText(_ record: WorkerArchiveRecord) -> String {
        var parts: [String] = [
            record.dispatchID, record.kind.rawValue, record.workerState, record.createdAt,
        ]
        parts.append(contentsOf: [
            record.runID, record.runObjective, record.taskID, record.taskTitle,
            record.taskDisplayName, record.taskSpec, record.agentHandle, record.engineID,
            record.dispatchStatus?.rawValue,
        ].compactMap { $0 })
        parts.append(record.contentScan)
        return parts.joined(separator: "\n").lowercased()
    }

    static func taskLabel(_ record: WorkerArchiveRecord) -> String {
        OrchestrationProjection.displayName(
            displayName: record.taskDisplayName,
            taskTitle: record.taskTitle,
            spec: record.taskSpec ?? record.taskID ?? "unknown task")
    }

    static func taskTitle(_ record: WorkerArchiveRecord) -> String {
        OrchestrationProjection.title(
            displayName: record.taskDisplayName,
            taskTitle: record.taskTitle,
            spec: record.taskSpec ?? record.taskID ?? "unknown task")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Filtering

    /// Whitespace-separated terms, all of which must appear (case-insensitive) in the
    /// row's haystack. An empty query matches everything.
    public static func matches(_ row: VaultArchiveRow, query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { row.searchText.contains($0) }
    }

    /// The snapshot narrowed to matching archives; runs and tasks with nothing left
    /// drop out entirely, so an empty result is visibly empty rather than a tree of
    /// empty headers.
    public static func filtered(_ snapshot: VaultSnapshot, query: String) -> VaultSnapshot {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snapshot }
        let runs = snapshot.runs.compactMap { run -> VaultRunGroup? in
            let tasks = run.tasks.compactMap { task -> VaultTaskGroup? in
                let archives = task.archives.filter { matches($0, query: trimmed) }
                guard !archives.isEmpty else { return nil }
                return VaultTaskGroup(
                    id: task.id, label: task.label, title: task.title, archives: archives)
            }
            guard !tasks.isEmpty else { return nil }
            return VaultRunGroup(
                id: run.id, objective: run.objective, createdAt: run.createdAt,
                isLive: run.isLive, tasks: tasks)
        }
        return VaultSnapshot(
            runs: runs, scanLimit: snapshot.scanLimit, scanTruncated: snapshot.scanTruncated)
    }

    // MARK: - Transcript pins

    /// Decode a pinned provider transcript (JSONL) into its message stream. Returns
    /// nil when the pin is not a message stream — the reader then shows it verbatim
    /// instead of inventing structure that is not there.
    public static func transcriptMessages(_ content: String) -> [VaultTranscriptMessage]? {
        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var messages: [VaultTranscriptMessage] = []
        var parsed = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            parsed += 1
            guard let message = transcriptMessage(object, id: messages.count) else { continue }
            messages.append(message)
        }
        // A JSONL pin whose lines mostly do not parse is not a message stream —
        // most likely plain terminal text that happened to start with a brace.
        guard !messages.isEmpty, parsed * 2 >= lines.count else { return nil }
        return messages
    }

    private static func transcriptMessage(_ entry: [String: Any], id: Int) -> VaultTranscriptMessage? {
        let message = entry["message"] as? [String: Any]
        let role = (message?["role"] as? String)
            ?? (entry["role"] as? String)
            ?? (entry["type"] as? String)
            ?? "entry"
        let timestamp = entry["timestamp"] as? String
        let text = transcriptText(message?["content"] ?? entry["content"] ?? entry["summary"])
        guard let text, !text.isEmpty else { return nil }
        return VaultTranscriptMessage(id: id, role: role, timestamp: timestamp, text: text)
    }

    /// Anthropic content is either a plain string or an array of typed blocks; render
    /// tool traffic as a labelled line rather than dropping it.
    private static func transcriptText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [Any] else { return nil }
        let rendered = blocks.compactMap { block -> String? in
            if let text = block as? String { return text }
            guard let object = block as? [String: Any] else { return nil }
            switch object["type"] as? String {
            case "text":
                return object["text"] as? String
            case "thinking":
                return (object["thinking"] as? String).map { "[thinking] \($0)" }
            case "tool_use":
                let name = object["name"] as? String ?? "tool"
                let input = compactJSON(object["input"])
                return input.isEmpty ? "[tool_use \(name)]" : "[tool_use \(name)] \(input)"
            case "tool_result":
                let body = transcriptText(object["content"]) ?? compactJSON(object["content"])
                return body.isEmpty ? "[tool_result]" : "[tool_result] \(body)"
            default:
                return (object["text"] as? String)
            }
        }
        let joined = rendered.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func compactJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    // MARK: - Labels

    public static func kindLabel(_ kind: String) -> String {
        switch kind {
        case WorkerTerminalArchiveKind.transcriptPin.rawValue: return "transcript pin"
        case WorkerTerminalArchiveKind.terminalTail.rawValue: return "terminal tail"
        default: return kind
        }
    }

    /// Binary-prefix sizes, one decimal above KB — the shape a retention preview needs
    /// ("frees 12.4 MB"), not a locale-formatted byte count.
    public static func byteLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}
