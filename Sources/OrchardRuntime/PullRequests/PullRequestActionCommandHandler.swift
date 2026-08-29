import Foundation
import OrchardCore
import OrchardProtocol

/// RPC surface for `orchard pr review|comment|reply|resolve|unresolve|merge|ready|close|reopen`.
///
/// Thin over `PullRequestActionService` — the same UI-free type the composer and
/// the merge sheet call — plus workspace selection, exactly the shape
/// `ChecksCommandHandler` established for T88.
///
/// Where it deliberately differs from that handler: **checks never fail because
/// GitHub said no, and these verbs do.** A checks reading that cannot be taken is
/// an answer in an `ok: true` envelope. A merge that did not happen is not an
/// answer, it is a merge that did not happen, so every path where nothing landed
/// comes back `ok: false` and the CLI exits non-zero. A script that runs
/// `orchard pr merge` and gets exit 0 is entitled to believe the branch is in.
///
/// ## The destructive gate
///
/// `merge` and `close` require `--yes`. Without it the handler still does the
/// read, still builds the plan, and returns the sentence that names what would
/// happen — as an error, so the exit status says nothing was done. That is the
/// dry run the task asks for, and it is also the only way a person or an agent
/// gets to read the sentence before deciding.
public final class PullRequestActionCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = [
        "pr-review", "pr-comment", "pr-reply", "pr-resolve", "pr-unresolve",
        "pr-merge", "pr-ready", "pr-close", "pr-reopen",
    ]

    private let workspaces: WorkspaceService
    private let probe: any GitHubCLIProbe
    private let timeout: TimeInterval

    public init(workspaces: WorkspaceService,
                probe: any GitHubCLIProbe = SystemGitHubCLI(),
                timeout: TimeInterval = 20) {
        self.workspaces = workspaces
        self.probe = probe
        self.timeout = timeout
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let err as PullRequestCommandError {
            return .failure(id: request.id,
                            error: RPCError(code: err.code, message: err.message,
                                            data: err.data))
        } catch let err as WorkspaceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch {
            return .failure(id: request.id, error: RPCError(
                code: "internal_error", message: String(describing: error)))
        }
    }

    private func dispatch(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params ?? .object([:])
        let service = try await service(for: params)
        switch request.method {
        case "pr-review":     return try await review(service, params)
        case "pr-comment":    return try await comment(service, params)
        case "pr-reply":      return try await reply(service, params)
        case "pr-resolve":    return try await thread(service, params, resolve: true)
        case "pr-unresolve":  return try await thread(service, params, resolve: false)
        case "pr-merge":      return try await merge(service, params)
        case "pr-close":      return try await close(service, params)
        case "pr-reopen":     return try settle(await service.reopen())
        case "pr-ready":      return try settle(await service.setDraft(params.bool("draft") ?? false))
        default:
            throw PullRequestCommandError.invalidArgument("unrouted verb '\(request.method)'")
        }
    }

    // MARK: - Verbs

    private func review(_ service: PullRequestActionService,
                        _ params: JSONValue) async throws -> JSONValue {
        let raw = params.string("verdict", "review") ?? ""
        guard let verdict = Self.verdict(raw) else {
            throw PullRequestCommandError.invalidArgument(
                "pr review requires --verdict approve|request-changes|comment"
                    + (raw.isEmpty ? "" : " (got '\(raw)')"))
        }
        let body = params.string("body") ?? ""
        // The empty-body rule is *not* re-implemented here. The service refuses
        // before it launches anything, and this handler reports that refusal like
        // any other — one rule, one place.
        return try settle(await service.submitReview(verdict: verdict, body: body))
    }

    private func comment(_ service: PullRequestActionService,
                         _ params: JSONValue) async throws -> JSONValue {
        guard let path = params.string("path", "file"), !path.isEmpty else {
            throw PullRequestCommandError.invalidArgument("pr comment requires --path <file>")
        }
        guard let line = params.field("line")?.intValue else {
            throw PullRequestCommandError.invalidArgument("pr comment requires --line <n>")
        }
        guard let body = params.string("body"), !body.isEmpty else {
            throw PullRequestCommandError.invalidArgument("pr comment requires --body <text>")
        }
        let startLine = params.field("start-line", "startLine")?.intValue
        let side = DiffSide(gh: params.string("side"))
        return try settle(await service.comment(on: path, line: line, startLine: startLine,
                                                side: side, body: body))
    }

    private func reply(_ service: PullRequestActionService,
                       _ params: JSONValue) async throws -> JSONValue {
        let threadId = try Self.threadId(params)
        guard let body = params.string("body"), !body.isEmpty else {
            throw PullRequestCommandError.invalidArgument("pr reply requires --body <text>")
        }
        return try settle(await service.reply(toThread: threadId, body: body))
    }

    private func thread(_ service: PullRequestActionService, _ params: JSONValue,
                        resolve: Bool) async throws -> JSONValue {
        let threadId = try Self.threadId(params)
        return try settle(resolve ? await service.resolve(thread: threadId)
                                  : await service.unresolve(thread: threadId))
    }

    private func merge(_ service: PullRequestActionService,
                       _ params: JSONValue) async throws -> JSONValue {
        let raw = params.string("method") ?? "merge"
        guard let method = MergeMethod(rawValue: raw.lowercased()) else {
            throw PullRequestCommandError.invalidArgument(
                "pr merge --method must be merge|squash|rebase (got '\(raw)')")
        }
        // Absent means false. There is no other reading of a missing flag, and a
        // branch is not deleted because somebody forgot to say not to.
        let deleteBranch = params.bool("delete-branch", "deleteBranch") ?? false

        let plan: MergePlan
        switch await service.mergePlan(method: method, deleteBranch: deleteBranch) {
        case .failure(let refusal): throw PullRequestCommandError(refusal)
        case .success(let value): plan = value
        }

        guard params.bool("yes") == true else {
            // The dry run reports the readiness it just read, so a merge that
            // would be refused says so before anyone types --yes rather than
            // after.
            var warnings = plan.warnings
            if case .refused(let refusal) = plan.readiness {
                warnings.insert("\(refusal.headline). \(refusal.detail)"
                    .trimmingCharacters(in: .whitespaces), at: 0)
            } else if plan.readiness == .stillComputing {
                warnings.insert("GitHub has not finished computing whether this merges. "
                    + "Re-running with --yes now would send nothing.", at: 0)
            }
            throw PullRequestCommandError.wouldDo(plan.confirmation,
                                                  plan: Self.planPayload(plan),
                                                  warnings: warnings)
        }
        return try settle(await service.merge(plan: plan,
                                              confirmation: plan.confirmation.token),
                          plan: Self.planPayload(plan))
    }

    private func close(_ service: PullRequestActionService,
                       _ params: JSONValue) async throws -> JSONValue {
        let plan: ClosePlan
        switch await service.closePlan() {
        case .failure(let refusal): throw PullRequestCommandError(refusal)
        case .success(let value): plan = value
        }
        guard params.bool("yes") == true else {
            throw PullRequestCommandError.wouldDo(plan.confirmation, plan: .object([
                "action": .string("close"),
                "repository": .string(plan.ref.repository),
                "number": .number(Double(plan.ref.number)),
                "title": .string(plan.title),
                "headRefName": .string(plan.headRefName),
            ]))
        }
        return try settle(await service.close(plan: plan,
                                              confirmation: plan.confirmation.token))
    }

    // MARK: - Settling an outcome

    /// Turn a `PullRequestActionResult` into a wire answer.
    ///
    /// Only `.succeeded` is `ok: true`. The other three all mean nothing landed,
    /// and each keeps its own code so a caller can tell "GitHub said no" from
    /// "GitHub has not decided" from "you never confirmed".
    private func settle(_ result: PullRequestActionResult,
                        plan: JSONValue? = nil) throws -> JSONValue {
        switch result {
        case .succeeded(let receipt):
            var object: [String: JSONValue] = [
                "status": .string("done"),
                "action": .string(receipt.action.rawValue),
                "summary": .string(receipt.summary),
                "detail": .string(receipt.detail),
                "repository": .string(receipt.ref.repository),
                "number": .number(Double(receipt.ref.number)),
                "url": .string(receipt.ref.url),
            ]
            if let plan { object["plan"] = plan }
            return .object(object)
        case .refused(let refusal):
            throw PullRequestCommandError(refusal)
        case .mergeabilityUnknown(let pending):
            throw PullRequestCommandError(
                "mergeability_unknown",
                "\(pending.headline). \(pending.detail) \(pending.remedy)"
                    .trimmingCharacters(in: .whitespaces),
                data: .object([
                    "status": .string("mergeability_unknown"),
                    "headline": .string(pending.headline),
                    "detail": .string(pending.detail),
                    "remedy": .string(pending.remedy),
                    "repository": .string(pending.ref.repository),
                    "number": .number(Double(pending.ref.number)),
                ]))
        case .needsConfirmation(let confirmation):
            throw PullRequestCommandError.wouldDo(confirmation, plan: plan)
        }
    }

    // MARK: - Plumbing

    private func service(for params: JSONValue) async throws -> PullRequestActionService {
        let workspace = try await resolve(params)
        // A remote workspace is refused typed rather than acted on from here: this
        // machine's `gh` and this machine's checkout describe a different tree.
        // Merging the wrong repository is exactly the accident T94 exists to stop.
        guard workspace.hostId == "local" else {
            throw PullRequestCommandError(PullRequestRefusal(.remoteWorkspace,
                detail: "This workspace's files live on \(workspace.hostId)."))
        }
        guard workspace.kind != .folder else {
            throw PullRequestCommandError(PullRequestRefusal(.notAWorktree,
                detail: "\(workspace.path) is a folder workspace, not a git worktree."))
        }
        let root = URL(fileURLWithPath: workspace.path)
        let branch = GitRunner.shared.line(in: root, ["symbolic-ref", "--short", "-q", "HEAD"])
        return PullRequestActionService(worktree: root, branch: branch,
                                        probe: probe, timeout: timeout)
    }

    private func resolve(_ params: JSONValue) async throws -> Workspace {
        if let selector = params.string("worktree", "selector", "id"), !selector.isEmpty {
            return try await workspaces.show(selector: selector, cwd: params.string("cwd"))
        }
        if let cwd = params.string("cwd"), !cwd.isEmpty {
            return try await workspaces.current(cwd: cwd)
        }
        throw PullRequestCommandError.invalidArgument("missing worktree selector")
    }

    private static func threadId(_ params: JSONValue) throws -> String {
        guard let id = params.string("thread", "thread-id", "threadId"), !id.isEmpty else {
            throw PullRequestCommandError.invalidArgument(
                "this verb requires --thread <review thread id>")
        }
        return id
    }

    static func verdict(_ raw: String) -> ReviewVerdict? {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "approve", "approved": return .approve
        case "request-changes", "requestchanges", "changes", "reject": return .requestChanges
        case "comment": return .comment
        default: return nil
        }
    }

    static func planPayload(_ plan: MergePlan) -> JSONValue {
        .object([
            "action": .string("merge"),
            "repository": .string(plan.ref.repository),
            "number": .number(Double(plan.ref.number)),
            "title": .string(plan.title),
            "method": .string(plan.method.rawValue),
            "deleteBranch": .bool(plan.deleteBranch),
            "headRefName": .string(plan.headRefName),
            "baseRefName": .string(plan.baseRefName),
            "state": .string(plan.state.rawValue),
            "mergeable": .string(plan.mergeable.rawValue),
            "readiness": .string(Self.readinessCode(plan.readiness)),
            "availableMethods": .array(plan.policy.methods.map { .string($0.rawValue) }),
            "methodsAreAuthoritative": .bool(plan.policy.isAuthoritative),
            "warnings": .array(plan.warnings.map { .string($0) }),
        ])
    }

    static func readinessCode(_ readiness: MergeReadiness) -> String {
        switch readiness {
        case .ready: return "ready"
        case .stillComputing: return "still_computing"
        case .refused(let refusal): return refusal.code
        }
    }
}

/// A typed CLI-facing failure. Same shape as `ChecksCommandError`, plus the
/// structured payload that lets `--json` callers read the plan they were shown
/// in prose.
public struct PullRequestCommandError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public let data: JSONValue?

    public init(_ code: String, _ message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// A refusal, flattened the way T88 flattens one: headline, gh's own words,
    /// and the one thing to do about it.
    public init(_ refusal: PullRequestRefusal) {
        self.code = refusal.code
        self.message = "\(refusal.headline). \(refusal.detail) \(refusal.remedy)"
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        self.data = .object([
            "status": .string("refused"),
            "code": .string(refusal.code),
            "headline": .string(refusal.headline),
            "detail": .string(refusal.detail),
            "remedy": .string(refusal.remedy),
        ])
    }

    public var description: String { message }

    public static func invalidArgument(_ message: String) -> PullRequestCommandError {
        PullRequestCommandError("invalid_argument", message)
    }

    /// The dry run. It reads as an error on purpose: the exit status has to say
    /// that nothing was done, and a zero exit on a merge that did not merge is
    /// the single worst thing this CLI could do.
    public static func wouldDo(_ confirmation: ActionConfirmation,
                               plan: JSONValue? = nil,
                               warnings: [String] = []) -> PullRequestCommandError {
        var payload: [String: JSONValue] = [
            "status": .string("confirmation_required"),
            "sentence": .string(confirmation.sentence),
            "token": .string(confirmation.token),
        ]
        if let plan, case .object(let fields) = plan {
            for (key, value) in fields where payload[key] == nil { payload[key] = value }
        }
        // Warnings ride in the message, not only in `data`. Human mode prints the
        // message and nothing else, and "this repository deletes branches on
        // merge" is exactly the sentence somebody needs before they type --yes.
        var message = confirmation.sentence
        for warning in warnings { message += "\n  ! \(warning)" }
        message += "\n  Nothing was sent. Re-run with --yes to do it."
        return PullRequestCommandError("confirmation_required", message,
                                       data: .object(payload))
    }
}
