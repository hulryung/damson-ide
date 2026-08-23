import Foundation
import OrchardCore
import OrchardProtocol

/// RPC surface for the file service: `file-read-dir|preview|stat|list|search`
/// plus the agent-facing `file-open|diff|open-changed` verbs.
///
/// `file-diff` returns the fork-point unified diff from `GitService` (printed by
/// the CLI). `file-open` / `file-open-changed` post an in-process notification so
/// the app can focus itself — they do not wait on a UI.
public final class FileCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = [
        "file-read-dir", "file-preview", "file-stat", "file-list", "file-search",
        "file-open", "file-diff", "file-open-changed",
    ]

    private let files: FileService
    private let workspaces: WorkspaceService
    private let opens: FileOpenCenter
    private let git: GitService

    public init(files: FileService = FileService(),
                workspaces: WorkspaceService,
                opens: FileOpenCenter = FileOpenCenter(),
                git: GitService = GitService()) {
        self.files = files
        self.workspaces = workspaces
        self.opens = opens
        self.git = git
    }

    public var openCenter: FileOpenCenter { opens }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let err as FileServiceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as WorkspaceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as GitError {
            return .failure(id: request.id, error: RPCError(code: "git_error", message: err.message))
        } catch {
            return .failure(id: request.id, error: RPCError(code: "internal_error",
                                                           message: String(describing: error)))
        }
    }

    @MainActor
    private func dispatch(_ request: RPCRequest) throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]
        switch request.method {
        case "file-read-dir":
            let target = try resolveTarget(params)
            let rel = try relativePath(params, root: target.root)
            let entries = try files.readDir(
                root: target.root, relativePath: rel,
                showDotfiles: params.flag("showDotfiles") || params.flag("show-dotfiles"))
            return try JSONBridge.value(DirResult(entries: entries, path: rel, worktree: target.id))

        case "file-preview":
            let target = try resolveTarget(params)
            let rel = try requiredRelativePath(params, root: target.root)
            let preview = try files.preview(root: target.root, relativePath: rel,
                                            maxBytes: params.int("maxBytes") ?? params.int("max-bytes"))
            return try JSONBridge.value(preview)

        case "file-stat":
            let target = try resolveTarget(params)
            let rel = try relativePath(params, root: target.root)
            return try JSONBridge.value(files.stat(root: target.root, relativePath: rel))

        case "file-list":
            let target = try resolveTarget(params)
            let result = try files.list(
                root: target.root,
                query: params.str("query") ?? params.str("filter"),
                showDotfiles: params.flag("showDotfiles") || params.flag("show-dotfiles"),
                limit: params.int("limit") ?? FileService.defaultListLimit)
            return try JSONBridge.value(result)

        case "file-search":
            let target = try resolveTarget(params)
            guard let query = params.str("query"), !query.isEmpty else {
                throw FileServiceError.invalidArgument("file-search requires query")
            }
            let options = FileContentSearchOptions(
                include: globs(params, "include"),
                exclude: globs(params, "exclude"),
                caseSensitive: params.flag("caseSensitive") || params.flag("case-sensitive"),
                showDotfiles: params.flag("showDotfiles") || params.flag("show-dotfiles"),
                limit: params.int("limit") ?? FileService.defaultContentSearchLimit,
                perFileLimit: params.int("perFileLimit") ?? params.int("per-file-limit")
                    ?? FileService.defaultPerFileMatchLimit)
            let result = try files.contentSearch(root: target.root, query: query, options: options)
            return try JSONBridge.value(result)

        case "file-open":
            return try JSONBridge.value(openFile(params, mode: .edit))

        case "file-diff":
            let target = try resolveTarget(params)
            let rel = try requiredRelativePath(params, root: target.root)
            _ = try files.resolve(root: target.root, relativePath: rel)
            let baseRef = target.workspace.baseRef.isEmpty ? "HEAD" : target.workspace.baseRef
            let diff = git.diff(worktree: target.root, baseRef: baseRef, path: rel)
            return try JSONBridge.value(FileDiffResult(
                worktree: target.id, path: rel, diff: diff, baseRef: baseRef))

        case "file-open-changed":
            return try JSONBridge.value(openChanged(params))

        default:
            throw FileServiceError.invalidArgument("unrouted verb '\(request.method)'")
        }
    }

    @MainActor
    private func openFile(_ params: [String: JSONValue], mode: FileOpenRequest.Mode) throws -> FileOpenResult {
        let target = try resolveTarget(params)
        let rel = try requiredRelativePath(params, root: target.root)
        let url = try files.resolve(root: target.root, relativePath: rel)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            return FileOpenResult(worktree: target.id, relativePath: rel, kind: "directory",
                                  opened: false, reason: "path is a directory")
        }
        let kind = files.kind(of: rel)
        opens.post(FileOpenRequest(worktreeId: target.id, worktreePath: target.root.path,
                                   relativePath: rel, mode: mode))
        return FileOpenResult(worktree: target.id, relativePath: rel, kind: kind, opened: true)
    }

    @MainActor
    private func openChanged(_ params: [String: JSONValue]) throws -> FileOpenChangedResult {
        let target = try resolveTarget(params)
        let modeRaw = (params.str("mode") ?? "diff").lowercased()
        guard modeRaw == "edit" || modeRaw == "diff" || modeRaw == "both" else {
            throw FileServiceError.invalidArgument("invalid --mode. Use edit, diff, or both.")
        }
        let baseRef = target.workspace.baseRef.isEmpty ? "HEAD" : target.workspace.baseRef
        let status = git.status(worktree: target.root, baseRef: baseRef)
        var opened: [FileOpenChangedRecord] = []
        var skipped: [FileOpenChangedRecord] = []

        for change in status.stat.files {
            if modeRaw == "edit" || modeRaw == "both" {
                if change.kind == .deleted {
                    skipped.append(FileOpenChangedRecord(
                        path: change.path, mode: "edit", opened: false, skipped: true,
                        reason: "deleted file has no edit target"))
                } else {
                    opens.post(FileOpenRequest(worktreeId: target.id, worktreePath: target.root.path,
                                               relativePath: change.path, mode: .edit))
                    opened.append(FileOpenChangedRecord(
                        path: change.path, mode: "edit", opened: true, skipped: false))
                }
            }
            if modeRaw == "diff" || modeRaw == "both" {
                opens.post(FileOpenRequest(worktreeId: target.id, worktreePath: target.root.path,
                                           relativePath: change.path, mode: .diff))
                opened.append(FileOpenChangedRecord(
                    path: change.path, mode: "diff", opened: true, skipped: false))
            }
        }
        return FileOpenChangedResult(worktree: target.id, mode: modeRaw,
                                     opened: opened, skipped: skipped,
                                     totalChanged: status.stat.fileCount)
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
            return Target(workspace: try workspaces.show(selector: selector, cwd: params.str("cwd")))
        }
        if let cwd = params.str("cwd"), !cwd.isEmpty {
            return Target(workspace: try workspaces.current(cwd: cwd))
        }
        throw FileServiceError.invalidArgument("missing worktree selector")
    }

    private func relativePath(_ params: [String: JSONValue], root: URL) throws -> String {
        let raw = params.str("path") ?? params.str("relativePath") ?? params.str("relative-path") ?? ""
        return try files.relativePath(from: raw, root: root)
    }

    private func requiredRelativePath(_ params: [String: JSONValue], root: URL) throws -> String {
        let rel = try relativePath(params, root: root)
        if rel.isEmpty {
            throw FileServiceError.invalidArgument("missing file path")
        }
        return rel
    }

    /// Include/exclude globs. A JSON array is accepted as-is; a string is one glob
    /// (not CSV — `*.{swift,md}` must not split on the comma).
    private func globs(_ params: [String: JSONValue], _ key: String) -> [String] {
        switch params[key] {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case .array(let values):
            return values.compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }
}

private struct DirResult: Encodable {
    var entries: [FileDirEntry]
    var path: String
    var worktree: String
}
