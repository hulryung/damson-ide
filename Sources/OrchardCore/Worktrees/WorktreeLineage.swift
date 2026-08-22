import Foundation

/// How a parent relationship was captured. `explicit` is a caller-supplied
/// `--parent-worktree`; `inferred` is cwd / calling-terminal context.
public enum LineageCaptureConfidence: String, Codable, Equatable, Sendable {
    case explicit
    case inferred
}

public enum LineageCaptureSource: String, Codable, Equatable, Sendable {
    case explicitCLIFlag = "explicit-cli-flag"
    case envWorkspace = "env-workspace"
    case cwdContext = "cwd-context"
    case terminalContext = "terminal-context"
    case orchestrationContext = "orchestration-context"
    case activeWorkspace = "active-workspace"
    case manualAction = "manual-action"
}

/// Why the worktree exists. Sidebar lineage is **not** orchestration lifecycle —
/// a CLI-created child of a worker worktree is still `cli`.
public enum LineageOrigin: String, Codable, Equatable, Sendable {
    case orchestration
    case cli
    case manual
}

public struct LineageCapture: Codable, Equatable, Sendable {
    public var source: LineageCaptureSource
    public var confidence: LineageCaptureConfidence

    public init(source: LineageCaptureSource, confidence: LineageCaptureConfidence) {
        self.source = source
        self.confidence = confidence
    }
}

/// Parent/child record for a worktree. `--no-parent` is orthogonal to
/// `--base-branch`: the former controls this record, the latter chooses the git
/// fork point. A missing parent (nil) is a first-class state, not "use the
/// default base branch as parent".
public struct WorktreeLineage: Codable, Equatable, Sendable {
    public var worktreeId: String
    public var worktreeInstanceId: String
    /// Nil when created with `--no-parent` or when no parent could be captured.
    public var parentWorktreeId: String?
    public var parentWorktreeInstanceId: String?
    public var origin: LineageOrigin
    public var capture: LineageCapture
    public var orchestrationRunId: String?
    public var taskId: String?
    public var createdAt: Date

    public init(worktreeId: String,
                worktreeInstanceId: String,
                parentWorktreeId: String?,
                parentWorktreeInstanceId: String?,
                origin: LineageOrigin,
                capture: LineageCapture,
                orchestrationRunId: String? = nil,
                taskId: String? = nil,
                createdAt: Date = Date()) {
        self.worktreeId = worktreeId
        self.worktreeInstanceId = worktreeInstanceId
        self.parentWorktreeId = parentWorktreeId
        self.parentWorktreeInstanceId = parentWorktreeInstanceId
        self.origin = origin
        self.capture = capture
        self.orchestrationRunId = orchestrationRunId
        self.taskId = taskId
        self.createdAt = createdAt
    }

    /// True when this record should be dropped because the child's instance id
    /// no longer matches — the path was reused by a later worktree.
    public func isStale(currentInstanceId: String) -> Bool {
        worktreeInstanceId.caseInsensitiveCompare(currentInstanceId) != .orderedSame
    }
}
