import Foundation
import OrchardCore
import OrchardProtocol

/// RPC surface for `orchard checks list|show`.
///
/// Thin over `ChecksService` — the same UI-free actor the checks sidebar calls —
/// plus workspace selection. Every unavailable path arrives here already typed;
/// this handler's only job is to not lose that typing on the way to the wire.
///
/// Note what is *not* an RPC error: "no PR for this branch", "gh not installed",
/// "not authenticated". Those are answers, and they come back in an `ok: true`
/// envelope with `status: "unavailable"` and a reason. An `ok: false` here means
/// the request itself was malformed or the workspace could not be resolved.
public final class ChecksCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = ["checks-list", "checks-show"]

    private let checks: ChecksService
    private let workspaces: WorkspaceService

    public init(checks: ChecksService, workspaces: WorkspaceService) {
        self.checks = checks
        self.workspaces = workspaces
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let err as ChecksCommandError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as WorkspaceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch {
            return .failure(id: request.id, error: RPCError(
                code: "internal_error", message: String(describing: error)))
        }
    }

    private func dispatch(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params ?? .object([:])
        switch request.method {
        case "checks-list":
            return try await list(params)
        case "checks-show":
            return try await show(params)
        default:
            throw ChecksCommandError.invalidArgument("unrouted verb '\(request.method)'")
        }
    }

    private func list(_ params: JSONValue) async throws -> JSONValue {
        let workspace = try await resolve(params)
        let snapshot = await checks.snapshot(
            worktreeId: workspace.id, path: workspace.path, hostId: workspace.hostId,
            kind: workspace.kind, refresh: params.bool("refresh") ?? false)
        return try JSONBridge.value(ChecksListResult(snapshot: snapshot,
                                                     links: workspace.links))
    }

    private func show(_ params: JSONValue) async throws -> JSONValue {
        let workspace = try await resolve(params)
        guard let selector = params.string("check", "name", "id"), !selector.isEmpty else {
            throw ChecksCommandError.invalidArgument(
                "checks show requires --check <name|details-url|job-id>")
        }
        let snapshot = await checks.snapshot(
            worktreeId: workspace.id, path: workspace.path, hostId: workspace.hostId,
            kind: workspace.kind, refresh: params.bool("refresh") ?? false)
        // A check cannot be shown from a snapshot that has none. The refusal names
        // the snapshot's own reason rather than inventing "check not found".
        guard snapshot.isAvailable else {
            let reason = snapshot.unavailable ?? ChecksUnavailability(.apiError)
            throw ChecksCommandError(reason.code,
                                     "\(reason.headline). \(reason.detail) \(reason.remedy)"
                                        .trimmingCharacters(in: .whitespaces))
        }
        guard let check = ChecksSelection.match(selector, in: snapshot.checks) else {
            throw ChecksCommandError(
                "check_not_found",
                "no check matching '\(selector)' on PR #\(snapshot.pullRequest?.number ?? 0). "
                    + "Known: \(snapshot.checks.map(\.name).joined(separator: ", "))")
        }
        let limit = params.field("limit")?.intValue ?? ChecksService.defaultLogLines
        let result = await checks.log(worktreeId: workspace.id, path: workspace.path,
                                      check: check, limit: max(0, limit))
        return try JSONBridge.value(ChecksShowResult(result: result,
                                                     pullRequest: snapshot.pullRequest))
    }

    private func resolve(_ params: JSONValue) async throws -> Workspace {
        if let selector = params.string("worktree", "selector", "id"), !selector.isEmpty {
            return try await workspaces.show(selector: selector, cwd: params.string("cwd"))
        }
        if let cwd = params.string("cwd"), !cwd.isEmpty {
            return try await workspaces.current(cwd: cwd)
        }
        throw ChecksCommandError.invalidArgument("missing worktree selector")
    }
}

/// Name/URL/job-id matching for `checks show`, split out so it is testable without
/// a runtime and shared with the app's details tab.
public enum ChecksSelection {
    /// Exact id, exact name, exact job id, then a unique case-insensitive prefix or
    /// substring. Ambiguity is not resolved by picking the first — it returns nil so
    /// the caller can list the candidates.
    public static func match(_ selector: String,
                             in checks: [CheckRunSummary]) -> CheckRunSummary? {
        let needle = selector.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        if let hit = checks.first(where: { $0.id == needle }) { return hit }
        if let hit = checks.first(where: { $0.name == needle }) { return hit }
        if let hit = checks.first(where: { $0.jobId == needle }) { return hit }
        let lowered = needle.lowercased()
        let prefixed = checks.filter { $0.name.lowercased().hasPrefix(lowered) }
        if prefixed.count == 1 { return prefixed[0] }
        let contained = checks.filter { $0.name.lowercased().contains(lowered) }
        if contained.count == 1 { return contained[0] }
        return nil
    }
}

private struct ChecksListResult: Encodable {
    var worktree: String
    var path: String
    var branch: String?
    var headSha: String?
    var observedAt: Double
    var ageSeconds: Double
    var status: String
    var unavailable: ChecksUnavailability?
    var pullRequest: PullRequestSummary?
    var rollup: String
    var rollupLabel: String
    var checkCount: Int
    var checks: [CheckRunSummary]
    /// The worktree's typed links, so one call answers both halves of the card.
    var links: [WorktreeLink]

    init(snapshot: ChecksSnapshot, links: [WorktreeLink]) {
        worktree = snapshot.worktreeId
        path = snapshot.worktreePath
        branch = snapshot.branch
        headSha = snapshot.headSha
        observedAt = snapshot.observedAt
        // Stated on the wire so no consumer has to compute it — and so no consumer
        // can present a cached reading as current without noticing.
        ageSeconds = max(0, Date().timeIntervalSince(snapshot.observedDate))
        status = snapshot.status
        unavailable = snapshot.unavailable
        pullRequest = snapshot.pullRequest
        rollup = snapshot.rollup
        rollupLabel = snapshot.rollupLabel
        checkCount = snapshot.checks.count
        checks = snapshot.checks
        self.links = links
    }
}

private struct ChecksShowResult: Encodable {
    var worktree: String
    var check: CheckRunSummary
    var pullRequest: PullRequestSummary?
    var observedAt: Double
    var status: String
    var reason: String?
    var headline: String?
    var detail: String?
    var remedy: String?
    var log: String?
    var truncated: Bool
    var totalLines: Int
    var returnedLines: Int

    init(result: CheckLogResult, pullRequest: PullRequestSummary?) {
        worktree = result.worktreeId
        check = result.check
        self.pullRequest = pullRequest
        observedAt = result.observedAt
        status = result.status
        reason = result.reason
        headline = result.headline
        detail = result.detail
        remedy = result.remedy
        log = result.log
        truncated = result.truncated
        totalLines = result.totalLines
        returnedLines = result.returnedLines
    }
}
