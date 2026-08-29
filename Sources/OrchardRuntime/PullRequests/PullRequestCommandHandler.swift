import Foundation
import OrchardCore
import OrchardProtocol

/// RPC surface for `orchard pr eligibility|create`.
///
/// Thin over `PullRequestCreationService` — the same UI-free type the sheet calls —
/// plus workspace selection, so an agent and a person reach GitHub through exactly
/// one implementation.
///
/// The two verbs answer differently on purpose, and the difference is not an
/// oversight:
///
/// * **`pr eligibility` is a reading.** "You cannot open one, because the branch is
///   not pushed" is the answer to the question, not a failure to answer it, so it
///   comes back `ok: true` with a typed refusal — the same shape `orchard checks`
///   uses, for the same reason.
/// * **`pr create` is a write.** A refusal means no pull request exists, and a
///   script must see that in the exit status. It comes back `ok: false` with the
///   refusal's own code, and its message carries the headline, gh's detail and the
///   remedy — the shape `checks show` already uses when it is asked for something
///   that is not there.
public final class PullRequestCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = ["pr-eligibility", "pr-create"]

    private let creation: PullRequestCreationService
    private let workspaces: WorkspaceService

    public init(creation: PullRequestCreationService, workspaces: WorkspaceService) {
        self.creation = creation
        self.workspaces = workspaces
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            return .success(id: request.id, result: try await dispatch(request))
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
        case "pr-eligibility": return try await eligibility(params)
        case "pr-create": return try await create(params)
        default:
            throw ChecksCommandError.invalidArgument("unrouted verb '\(request.method)'")
        }
    }

    // MARK: - eligibility

    private func eligibility(_ params: JSONValue) async throws -> JSONValue {
        let workspace = try await resolve(params)
        let result = await read(workspace, base: params.string("base"))
        return try JSONBridge.value(PullRequestEligibilityResult(workspace: workspace,
                                                                 eligibility: result))
    }

    // MARK: - create

    private func create(_ params: JSONValue) async throws -> JSONValue {
        let workspace = try await resolve(params)
        guard let title = params.string("title")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            // Checked here as well as in the service so the CLI's own missing-flag
            // case reads as a usage error rather than as GitHub refusing something.
            throw ChecksCommandError(PullRequestRefusalReason.emptyTitle.rawValue,
                                     "pr create requires --title. "
                                        + PullRequestRefusalReason.emptyTitle.remedy)
        }

        // Eligibility runs first and its refusal is the answer. Creating past a known
        // dead end would spend a round trip to be told the same thing in worse words —
        // and on the `branch_not_pushed` path it is the difference between a named
        // refusal and a pull request proposing commits GitHub cannot see.
        let eligibility = await read(workspace, base: params.string("base"))
        if let refusal = eligibility.refusal { throw Self.error(refusal) }
        guard let head = eligibility.head, let base = eligibility.resolvedBase else {
            throw ChecksCommandError(PullRequestRefusalReason.noBaseRef.rawValue,
                                     "no head or base could be resolved for this worktree")
        }

        // No body means an empty body. The repository's template is reported by
        // `pr eligibility` and never spliced in here: filling a pull request with
        // prose the caller has not seen publishes text under their name that they
        // never read. The sheet prefills because a human is looking at it.
        let draft = PullRequestDraft(title: title, body: params.string("body") ?? "",
                                     base: base, head: head,
                                     isDraft: params.bool("draft") ?? false)
        switch await creation.create(worktree: URL(fileURLWithPath: workspace.path),
                                     draft: draft) {
        case .failure(let refusal):
            throw Self.error(refusal)
        case .success(let ref):
            return try JSONBridge.value(PullRequestCreateResult(workspace: workspace,
                                                                ref: ref, draft: draft))
        }
    }

    // MARK: - Shared

    private func read(_ workspace: Workspace,
                      base: String?) async -> PullRequestCreationEligibility {
        // A folder workspace has no branch, so it has nothing to propose. Named here
        // rather than left to git, which would answer `not_a_worktree` about a
        // directory that is a perfectly good workspace.
        if workspace.kind == .folder {
            return PullRequestCreationEligibility(
                refusal: PullRequestRefusal(.notAWorktree,
                    detail: "\(workspace.path) is a folder workspace, not a git worktree."))
        }
        return await creation.eligibility(worktree: URL(fileURLWithPath: workspace.path),
                                          base: base, hostId: workspace.hostId)
    }

    /// The refusal, whole, on the wire: code as the error code, and headline plus
    /// gh's own detail plus the remedy as the message — so a person reading stderr
    /// gets all four parts and a script gets a stable code to branch on.
    private static func error(_ refusal: PullRequestRefusal) -> ChecksCommandError {
        ChecksCommandError(refusal.code,
                           "\(refusal.headline). \(refusal.detail) \(refusal.remedy)"
                            .replacingOccurrences(of: "  ", with: " ")
                            .trimmingCharacters(in: .whitespaces))
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

// MARK: - Wire shapes

/// One refusal, flattened for the wire. Same four parts the sidebar shows and the
/// CLI prints: nothing is dropped on the way out of the runtime.
struct PullRequestRefusalPayload: Encodable {
    var code: String
    var headline: String
    var detail: String
    var remedy: String
    /// Whether retrying the identical call could plausibly work. Published so a
    /// caller can offer a retry without hard-coding which codes are network-shaped.
    var transient: Bool

    init(_ refusal: PullRequestRefusal) {
        code = refusal.code
        headline = refusal.headline
        detail = refusal.detail
        remedy = refusal.remedy
        transient = refusal.reason.isTransient
    }
}

struct PullRequestRefPayload: Encodable {
    var repository: String
    var number: Int
    var url: String

    init(_ ref: PullRequestRef) {
        repository = ref.repository
        number = ref.number
        url = ref.url
    }
}

private struct PullRequestEligibilityResult: Encodable {
    var worktree: String
    var path: String
    var hostId: String
    /// `ready` or `refused`. Both are `ok: true` answers.
    var status: String
    var canCreate: Bool
    var refusal: PullRequestRefusalPayload?
    var head: String?
    var base: String?
    var commitsAhead: Int?
    var needsPush: Bool
    /// `found` | `notFound` | `unavailable`. Published verbatim, because a consumer
    /// that collapses the third into the second reintroduces the bug this feature
    /// was built to close.
    var existingLookup: String
    var existing: PullRequestRefPayload?
    var hasTemplate: Bool
    var template: String?

    init(workspace: Workspace, eligibility: PullRequestCreationEligibility) {
        worktree = workspace.id
        path = workspace.path
        hostId = workspace.hostId
        status = eligibility.canCreate ? "ready" : "refused"
        canCreate = eligibility.canCreate
        refusal = eligibility.refusal.map(PullRequestRefusalPayload.init)
        head = eligibility.head
        base = eligibility.resolvedBase
        commitsAhead = eligibility.commitsAhead
        needsPush = eligibility.needsPush
        existingLookup = eligibility.existingLookup.rawValue
        existing = eligibility.existing.map(PullRequestRefPayload.init)
        hasTemplate = eligibility.template != nil
        template = eligibility.template
    }
}

private struct PullRequestCreateResult: Encodable {
    var worktree: String
    var path: String
    var repository: String
    var number: Int
    var url: String
    var title: String
    var base: String
    var head: String
    var isDraft: Bool

    init(workspace: Workspace, ref: PullRequestRef, draft: PullRequestDraft) {
        worktree = workspace.id
        path = workspace.path
        repository = ref.repository
        number = ref.number
        url = ref.url
        title = draft.title
        base = draft.base
        head = draft.head
        isDraft = draft.isDraft
    }
}
