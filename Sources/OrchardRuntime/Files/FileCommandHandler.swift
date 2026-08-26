import Foundation
import OrchardCore
import OrchardProtocol

/// RPC surface for the file service: `file-read-dir|preview|stat|list|search`
/// plus the agent-facing `file-open|diff|open-changed` verbs.
///
/// `file-diff` returns the fork-point unified diff from `GitService` (printed by
/// the CLI). `file-open` / `file-open-changed` post an in-process notification so
/// the app can focus itself — they do not wait on a UI.
///
/// Remote workspaces (T85) are served by `RemoteFileService` for listing, search,
/// and preview/read. Open/reveal-style verbs stay `remote_unsupported` because
/// they mean a local GUI action; `file-diff` stays refused because matching
/// `GitService.diff`'s untracked `--no-index` contract over ssh is not this slice
/// and a partial diff that hides new files would be a lie.
public final class FileCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = [
        "file-read-dir", "file-preview", "file-stat", "file-list", "file-search",
        "file-open", "file-diff", "file-open-changed",
    ]

    private let files: FileService
    private let workspaces: WorkspaceService
    private let opens: FileOpenCenter
    private let git: GitService
    private let hostRunner: HostCommandRunner
    private let remoteTimeout: TimeInterval

    public init(files: FileService = FileService(),
                workspaces: WorkspaceService,
                opens: FileOpenCenter = FileOpenCenter(),
                git: GitService = GitService(),
                hostRunner: HostCommandRunner = ProcessHostCommandRunner(),
                remoteTimeout: TimeInterval = SSHRunner.defaultTimeout) {
        self.files = files
        self.workspaces = workspaces
        self.opens = opens
        self.git = git
        self.hostRunner = hostRunner
        self.remoteTimeout = remoteTimeout
    }

    public var openCenter: FileOpenCenter { opens }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let err as FileServiceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as RemoteHostError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as HostRegistryError {
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
    private func dispatch(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]
        let target = try resolveTarget(params)
        if WorkspaceService.isRemote(target.workspace) {
            return try await dispatchRemote(request.method, params: params, target: target)
        }
        return try dispatchLocal(request.method, params: params, target: target)
    }

    @MainActor
    private func dispatchLocal(_ method: String, params: [String: JSONValue],
                               target: Target) throws -> JSONValue {
        switch method {
        case "file-read-dir":
            let rel = try relativePath(params, root: target.root)
            let entries = try files.readDir(
                root: target.root, relativePath: rel,
                showDotfiles: params.flag("showDotfiles") || params.flag("show-dotfiles"))
            return try JSONBridge.value(DirResult(entries: entries, path: rel, worktree: target.id))

        case "file-preview":
            let rel = try requiredRelativePath(params, root: target.root)
            let preview = try files.preview(root: target.root, relativePath: rel,
                                            maxBytes: params.int("maxBytes") ?? params.int("max-bytes"))
            return try JSONBridge.value(preview)

        case "file-stat":
            let rel = try relativePath(params, root: target.root)
            return try JSONBridge.value(files.stat(root: target.root, relativePath: rel))

        case "file-list":
            let result = try files.list(
                root: target.root,
                query: params.str("query") ?? params.str("filter"),
                showDotfiles: params.flag("showDotfiles") || params.flag("show-dotfiles"),
                limit: params.int("limit") ?? FileService.defaultListLimit)
            return try JSONBridge.value(result)

        case "file-search":
            guard let query = params.str("query"), !query.isEmpty else {
                throw FileServiceError.invalidArgument("file-search requires query")
            }
            let result = try files.contentSearch(root: target.root, query: query,
                                                 options: searchOptions(params))
            return try JSONBridge.value(result)

        case "file-open":
            return try JSONBridge.value(openFile(params, target: target, mode: .edit))

        case "file-diff":
            let rel = try requiredRelativePath(params, root: target.root)
            _ = try files.resolve(root: target.root, relativePath: rel)
            let baseRef = target.workspace.baseRef.isEmpty ? "HEAD" : target.workspace.baseRef
            let diff = git.diff(worktree: target.root, baseRef: baseRef, path: rel)
            return try JSONBridge.value(FileDiffResult(
                worktree: target.id, path: rel, diff: diff, baseRef: baseRef))

        case "file-open-changed":
            return try JSONBridge.value(openChanged(params, target: target))

        default:
            throw FileServiceError.invalidArgument("unrouted verb '\(method)'")
        }
    }

    @MainActor
    private func dispatchRemote(_ method: String, params: [String: JSONValue],
                                target: Target) async throws -> JSONValue {
        switch method {
        case "file-open":
            throw Self.remoteGUIRefusal(target, action: "file open")
        case "file-open-changed":
            throw Self.remoteGUIRefusal(target, action: "file open-changed")
        case "file-diff":
            throw FileServiceError(
                "remote_unsupported",
                "\(target.id) lives on \(target.workspace.hostId); file diff still runs a "
                    + "local git against the path, which would read the wrong machine. A "
                    + "remote git-diff that matched GitService.diff (including untracked "
                    + "--no-index) is not this slice — refusing beats a partial diff that "
                    + "hides new files.")
        default:
            break
        }

        let remote = try remoteService(target)
        let rel = try remoteRelativePath(params, root: target.workspace.path)
        switch method {
        case "file-read-dir":
            let entries = try await remote.readDir(
                relativePath: rel,
                showDotfiles: params.flag("showDotfiles") || params.flag("show-dotfiles"))
            return try JSONBridge.value(DirResult(entries: entries, path: rel, worktree: target.id))

        case "file-preview":
            if rel.isEmpty { throw FileServiceError.invalidArgument("missing file path") }
            let preview = try await remote.preview(
                relativePath: rel,
                maxBytes: params.int("maxBytes") ?? params.int("max-bytes"))
            return try JSONBridge.value(preview)

        case "file-stat":
            return try JSONBridge.value(try await remote.stat(relativePath: rel))

        case "file-list":
            let result = try await remote.list(
                query: params.str("query") ?? params.str("filter"),
                showDotfiles: params.flag("showDotfiles") || params.flag("show-dotfiles"),
                limit: params.int("limit") ?? FileService.defaultListLimit)
            return try JSONBridge.value(result)

        case "file-search":
            guard let query = params.str("query"), !query.isEmpty else {
                throw FileServiceError.invalidArgument("file-search requires query")
            }
            let result = try await remote.contentSearch(query: query, options: searchOptions(params))
            return try JSONBridge.value(result)

        default:
            throw FileServiceError.invalidArgument("unrouted verb '\(method)'")
        }
    }

    @MainActor
    private func remoteService(_ target: Target) throws -> RemoteFileService {
        guard let hostId = ExecutionHostId(rawValue: target.workspace.hostId), !hostId.isLocal else {
            throw FileServiceError(
                "remote_unsupported",
                "\(target.id) has an unusable execution host '\(target.workspace.hostId)'")
        }
        let host = try workspaces.hosts.require(host: hostId)
        let runner = SSHRunner(host: host, runner: hostRunner, timeout: remoteTimeout)
        return try RemoteFileService(runner: runner, root: target.workspace.path, files: files)
    }

    static func remoteGUIRefusal(_ target: Target, action: String) -> FileServiceError {
        FileServiceError(
            "remote_unsupported",
            "\(target.id) lives on \(target.workspace.hostId); \(action) is a local GUI "
                + "action and cannot target a remote workspace")
    }

    private func searchOptions(_ params: [String: JSONValue]) -> FileContentSearchOptions {
        FileContentSearchOptions(
            include: globs(params, "include"),
            exclude: globs(params, "exclude"),
            caseSensitive: params.flag("caseSensitive") || params.flag("case-sensitive"),
            showDotfiles: params.flag("showDotfiles") || params.flag("show-dotfiles"),
            limit: params.int("limit") ?? FileService.defaultContentSearchLimit,
            perFileLimit: params.int("perFileLimit") ?? params.int("per-file-limit")
                ?? FileService.defaultPerFileMatchLimit)
    }

    @MainActor
    private func openFile(_ params: [String: JSONValue], target: Target,
                          mode: FileOpenRequest.Mode) throws -> FileOpenResult {
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
    private func openChanged(_ params: [String: JSONValue],
                             target: Target) throws -> FileOpenChangedResult {
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

    struct Target {
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

    private func remoteRelativePath(_ params: [String: JSONValue], root: String) throws -> String {
        let raw = params.str("path") ?? params.str("relativePath") ?? params.str("relative-path") ?? ""
        return try RemoteFilePath.relativePath(from: raw, root: root)
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
