import Foundation
import OrchardCore
import OrchardProtocol

/// RPC surface for `orchard conflicts list|show|take|resolve|stage`.
///
/// Thin over `GitConflictService` — the same UI-free type the conflict-review
/// pane calls — plus worktree selection and the typed refusals the CLI prints.
public final class ConflictsCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = [
        "conflicts-list", "conflicts-show", "conflicts-take",
        "conflicts-resolve", "conflicts-stage",
    ]

    private let workspaces: WorkspaceService
    private let files: FileService
    private let conflicts: GitConflictService

    public init(workspaces: WorkspaceService,
                files: FileService = FileService(),
                conflicts: GitConflictService = GitConflictService()) {
        self.workspaces = workspaces
        self.files = files
        self.conflicts = conflicts
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let err as ConflictCommandError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as FileServiceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as WorkspaceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as GitError {
            return .failure(id: request.id,
                            error: RPCError(code: Self.code(for: err), message: err.message))
        } catch {
            return .failure(id: request.id, error: RPCError(code: "internal_error",
                                                           message: String(describing: error)))
        }
    }

    @MainActor
    private func dispatch(_ request: RPCRequest) throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]
        switch request.method {
        case "conflicts-list":
            return try list(params)
        case "conflicts-show":
            return try show(params)
        case "conflicts-take":
            return try take(params)
        case "conflicts-resolve":
            return try resolve(params)
        case "conflicts-stage":
            return try stage(params)
        default:
            throw ConflictCommandError.invalidArgument("unrouted verb '\(request.method)'")
        }
    }

    @MainActor
    private func list(_ params: [String: JSONValue]) throws -> JSONValue {
        let target = try resolveTarget(params)
        let summary = conflicts.summary(worktree: target.root)
        return try JSONBridge.value(ConflictListResult(
            worktree: target.id,
            operation: summary.operation.rawValue,
            operationLabel: summary.operation.label,
            oursLabel: summary.operation.oursLabel,
            theirsLabel: summary.operation.theirsLabel,
            headline: summary.headline,
            nextStepHint: summary.nextStepHint,
            isActive: summary.isActive,
            fileCount: summary.fileCount,
            files: summary.files.map(ConflictFileDTO.init)))
    }

    @MainActor
    private func show(_ params: [String: JSONValue]) throws -> JSONValue {
        let target = try resolveTarget(params)
        let file = try requireConflicted(params, worktree: target.root)
        let document = conflicts.document(worktree: target.root, path: file.path)
        var stages: [String: String] = [:]
        for stage in GitConflictStage.allCases where file.kind.has(stage) {
            if let text = conflicts.stageContents(worktree: target.root, path: file.path, stage: stage) {
                stages[stage.label.lowercased()] = text
            }
        }
        return try JSONBridge.value(ConflictShowResult(
            worktree: target.id,
            file: ConflictFileDTO(file),
            readable: document != nil,
            hasConflictMarkers: document?.hasConflictMarkers ?? false,
            hunkCount: document?.hunkCount ?? 0,
            hunks: (document?.hunks ?? []).map(ConflictHunkDTO.init),
            stages: stages))
    }

    @MainActor
    private func take(_ params: [String: JSONValue]) throws -> JSONValue {
        let target = try resolveTarget(params)
        let file = try requireConflicted(params, worktree: target.root)
        guard let raw = params.str("side"), let side = GitConflictSide(rawValue: raw) else {
            throw ConflictCommandError.invalidArgument("invalid --side. Use ours or theirs.")
        }
        try conflicts.take(side, worktree: target.root, path: file.path)
        let url = target.root.appendingPathComponent(file.path)
        let deleted = !FileManager.default.fileExists(atPath: url.path)
        return try JSONBridge.value(ConflictTakeResult(
            worktree: target.id, path: file.path, side: side.rawValue,
            staged: true, deleted: deleted))
    }

    @MainActor
    private func resolve(_ params: [String: JSONValue]) throws -> JSONValue {
        let target = try resolveTarget(params)
        let file = try requireConflicted(params, worktree: target.root)
        guard let hunk = params.int("hunk") else {
            throw ConflictCommandError.invalidArgument("conflicts resolve requires --hunk <n>")
        }
        guard let raw = params.str("choice"),
              let choice = GitConflictChoice(rawValue: raw),
              choice != .unresolved else {
            throw ConflictCommandError.invalidArgument(
                "invalid --choice. Use ours, theirs, or both.")
        }
        guard let document = conflicts.document(worktree: target.root, path: file.path) else {
            throw ConflictCommandError(
                "cannot_read",
                "\(file.path) is not readable as text; use conflicts take --side ours|theirs")
        }
        if document.hunkCount == 0 {
            throw ConflictCommandError.invalidArgument(
                "\(file.path) has no conflict hunks; use conflicts take or conflicts stage")
        }
        guard document.hunks.contains(where: { $0.index == hunk }) else {
            throw ConflictCommandError(
                "hunk_not_found",
                "hunk \(hunk) is out of range (file has \(document.hunkCount) hunks)")
        }
        let result = try conflicts.resolve(worktree: target.root, path: file.path,
                                           choices: [hunk: choice])
        return try JSONBridge.value(ConflictResolveResult(
            worktree: target.id, path: file.path, hunk: hunk, choice: choice.rawValue,
            remainingHunks: result.remainingHunks, staged: result.staged))
    }

    @MainActor
    private func stage(_ params: [String: JSONValue]) throws -> JSONValue {
        let target = try resolveTarget(params)
        let file = try requireConflicted(params, worktree: target.root)
        try conflicts.stage(worktree: target.root, path: file.path)
        return try JSONBridge.value(ConflictStageResult(
            worktree: target.id, path: file.path, staged: true))
    }

    private struct Target {
        var workspace: Workspace
        var id: String { workspace.id }
        var root: URL { URL(fileURLWithPath: workspace.path) }
    }

    @MainActor
    private func resolveTarget(_ params: [String: JSONValue]) throws -> Target {
        if let selector = params.str("worktree") ?? params.str("selector") ?? params.str("id"),
           !selector.isEmpty {
            return try local(Target(
                workspace: try workspaces.show(selector: selector, cwd: params.str("cwd"))))
        }
        if let cwd = params.str("cwd"), !cwd.isEmpty {
            return try local(Target(workspace: try workspaces.current(cwd: cwd)))
        }
        throw ConflictCommandError.invalidArgument("missing worktree selector")
    }

    private func local(_ target: Target) throws -> Target {
        guard WorkspaceService.isRemote(target.workspace) == false else {
            throw ConflictCommandError(
                "remote_unsupported",
                "\(target.id) lives on \(target.workspace.hostId); "
                    + "conflicts cannot read remote workspaces yet")
        }
        return target
    }

    private func requireConflicted(_ params: [String: JSONValue],
                                   worktree: URL) throws -> GitConflictedFile {
        let path = try requiredPath(params, root: worktree)
        let listed = conflicts.conflictedFiles(worktree: worktree)
        guard let file = listed.first(where: { $0.path == path }) else {
            throw ConflictCommandError(
                "not_conflicted",
                "\(path) is not a conflicted path")
        }
        return file
    }

    private func requiredPath(_ params: [String: JSONValue], root: URL) throws -> String {
        let raw = params.str("path") ?? params.str("relativePath") ?? params.str("relative-path") ?? ""
        var rel = try files.relativePath(from: raw, root: root)
        while rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
        if rel.isEmpty {
            throw ConflictCommandError.invalidArgument("missing --path")
        }
        _ = try files.resolve(root: root, relativePath: rel)
        return rel
    }

    static func code(for error: GitError) -> String {
        if error.message.contains("conflict markers") { return "conflict_markers_remain" }
        if error.message.contains("cannot read conflicted file") { return "cannot_read" }
        return "git_error"
    }
}

/// Typed failure for the conflicts verbs. Codes are the CLI/RPC contract.
public struct ConflictCommandError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    public static func invalidArgument(_ message: String) -> ConflictCommandError {
        ConflictCommandError("invalid_argument", message)
    }
}

private struct ConflictFileDTO: Encodable {
    var path: String
    var kind: String
    var kindCode: String
    var kindLabel: String
    var hasInlineMarkers: Bool
    var actionOurs: String
    var actionTheirs: String

    init(_ file: GitConflictedFile) {
        path = file.path
        kind = file.kind.rawValue
        kindCode = file.kind.code
        kindLabel = file.kind.label
        hasInlineMarkers = file.kind.hasInlineMarkers
        actionOurs = file.kind.actionLabel(for: .ours)
        actionTheirs = file.kind.actionLabel(for: .theirs)
    }
}

private struct ConflictHunkDTO: Encodable {
    var index: Int
    var startLine: Int
    var oursLabel: String
    var theirsLabel: String
    var baseLabel: String?
    var ours: [String]
    var theirs: [String]
    var base: [String]?

    init(_ hunk: GitConflictHunk) {
        index = hunk.index
        startLine = hunk.startLine
        oursLabel = hunk.oursLabel
        theirsLabel = hunk.theirsLabel
        baseLabel = hunk.baseLabel
        ours = hunk.ours
        theirs = hunk.theirs
        base = hunk.base
    }
}

private struct ConflictListResult: Encodable {
    var worktree: String
    var operation: String
    var operationLabel: String
    var oursLabel: String
    var theirsLabel: String
    var headline: String
    var nextStepHint: String?
    var isActive: Bool
    var fileCount: Int
    var files: [ConflictFileDTO]
}

private struct ConflictShowResult: Encodable {
    var worktree: String
    var path: String
    var kind: String
    var kindCode: String
    var kindLabel: String
    var hasInlineMarkers: Bool
    var actionOurs: String
    var actionTheirs: String
    var readable: Bool
    var hasConflictMarkers: Bool
    var hunkCount: Int
    var hunks: [ConflictHunkDTO]
    var stages: [String: String]

    init(worktree: String, file: ConflictFileDTO, readable: Bool,
         hasConflictMarkers: Bool, hunkCount: Int, hunks: [ConflictHunkDTO],
         stages: [String: String]) {
        self.worktree = worktree
        self.path = file.path
        self.kind = file.kind
        self.kindCode = file.kindCode
        self.kindLabel = file.kindLabel
        self.hasInlineMarkers = file.hasInlineMarkers
        self.actionOurs = file.actionOurs
        self.actionTheirs = file.actionTheirs
        self.readable = readable
        self.hasConflictMarkers = hasConflictMarkers
        self.hunkCount = hunkCount
        self.hunks = hunks
        self.stages = stages
    }
}

private struct ConflictTakeResult: Encodable {
    var worktree: String
    var path: String
    var side: String
    var staged: Bool
    var deleted: Bool
}

private struct ConflictResolveResult: Encodable {
    var worktree: String
    var path: String
    var hunk: Int
    var choice: String
    var remainingHunks: Int
    var staged: Bool
}

private struct ConflictStageResult: Encodable {
    var worktree: String
    var path: String
    var staged: Bool
}
