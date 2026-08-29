import Foundation

/// What a pull-request *write* looks like before, during and after it happens.
///
/// The spine (`PullRequestModels`, `PullRequestRefusal`) describes a pull request
/// as it is. This file describes the things we do to one, and it exists mostly to
/// hold one idea: **a mutation on someone else's server is a two-step act.** Step
/// one produces a plan that names what will happen; step two carries the token
/// that plan minted. There is no one-step door, and there is no default that
/// walks through it.
///
/// Read `ActionConfirmation` first — the rest of the file is in service of it.

// MARK: - Confirmation

/// A sentence naming exactly what is about to happen, and the token that proves
/// somebody was shown it.
///
/// Why a token rather than a `Bool`:
///
/// * A `Bool` parameter has a default, and a default is precisely the thing that
///   must not be able to merge a pull request. `confirmed: Bool = false` is one
///   careless `= true` away from a hover that merges.
/// * A token is *minted from live state*. It digests the pull request's number,
///   its state, its head commit, the merge method, whether the branch dies, and
///   the worktree the plan was built in. If any of those moved between the plan
///   and the press — somebody pushed, somebody else merged, the user flipped the
///   method behind the sheet — the token no longer matches and the action stops.
/// * It is human-readable on purpose. It rides the CLI and appears in test
///   failures, and a digest you can read tells you *which* fact changed.
///
/// What it is not: a security boundary. Anything in this process can spell a
/// token out by hand. It defends against staleness and against accident, which
/// are the two ways an agent-driven IDE actually merges the wrong thing.
public struct ActionConfirmation: Codable, Equatable, Sendable {
    /// One sentence, plain language, naming the pull request by number and title
    /// and every consequence that outlives the click.
    public var sentence: String
    /// Deterministic digest of the operative facts. Compared verbatim.
    public var token: String

    public init(sentence: String, token: String) {
        self.sentence = sentence
        self.token = token
    }

    /// Build a token from ordered `key=value` facts. Sorted by the caller, not
    /// here: the order is part of the contract and a silent re-sort would make
    /// two different plans mint the same token.
    static func token(_ facts: [(String, String)]) -> String {
        facts.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
    }
}

// MARK: - What an action is

public enum PullRequestActionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case review
    case lineComment = "line_comment"
    case threadReply = "thread_reply"
    case threadResolve = "thread_resolve"
    case threadUnresolve = "thread_unresolve"
    case merge
    case close
    case reopen
    case markDraft = "mark_draft"
    case markReady = "mark_ready"

    /// Whether the act cannot be undone by pressing the opposite button.
    ///
    /// Merge is the only truly irreversible one, and close is here with it
    /// because closing discards an in-flight conversation's momentum even though
    /// `reopen` exists. These two — and only these two — are gated behind a
    /// minted confirmation in the service and behind `--yes` in the CLI.
    public var isDestructive: Bool {
        switch self {
        case .merge, .close: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .review: return "Submit review"
        case .lineComment: return "Comment on a line"
        case .threadReply: return "Reply to a thread"
        case .threadResolve: return "Resolve a thread"
        case .threadUnresolve: return "Unresolve a thread"
        case .merge: return "Merge"
        case .close: return "Close"
        case .reopen: return "Reopen"
        case .markDraft: return "Convert to draft"
        case .markReady: return "Mark ready for review"
        }
    }
}

/// What happened, in words, after a write landed.
public struct PullRequestActionReceipt: Codable, Equatable, Sendable {
    public var action: PullRequestActionKind
    public var ref: PullRequestRef
    /// Past tense, naming the pull request. This is what the UI and the CLI print.
    public var summary: String
    /// `gh`'s own first line of output, when it said anything worth keeping.
    public var detail: String

    public init(action: PullRequestActionKind, ref: PullRequestRef,
                summary: String, detail: String = "") {
        self.action = action
        self.ref = ref
        self.summary = summary
        self.detail = detail
    }
}

/// GitHub has not finished deciding whether the branches can merge.
///
/// Deliberately **not** a `PullRequestRefusal`. A refusal says "this cannot
/// happen"; this says "nobody knows yet, ask again". Collapsing it into a
/// refusal teaches users to force past it, and collapsing it into `mergeable`
/// merges on a guess. It is its own case in `PullRequestActionResult` for that
/// reason, and the UI shows it as a wait, not as a wall.
public struct MergeabilityPending: Codable, Equatable, Sendable {
    public var ref: PullRequestRef
    public var headline: String
    public var detail: String
    public var remedy: String

    public init(ref: PullRequestRef,
                headline: String = "GitHub is still working out whether this can merge",
                detail: String = "",
                remedy: String = "Ask again in a moment. Nothing was sent.") {
        self.ref = ref
        self.headline = headline
        self.detail = detail
        self.remedy = remedy
    }
}

/// The four things a write can come back as.
///
/// There is no `Bool`, and there is no "sort of". Every caller must name what it
/// does about a pending mergeability and about a missing confirmation, because
/// both of those are moments where the wrong default merges something.
public enum PullRequestActionResult: Equatable, Sendable {
    case succeeded(PullRequestActionReceipt)
    case refused(PullRequestRefusal)
    /// Mergeability is still being computed. Nothing was launched.
    case mergeabilityUnknown(MergeabilityPending)
    /// The caller did not carry the token this plan minted. Nothing was launched.
    /// The confirmation attached is the one that would have to be shown.
    case needsConfirmation(ActionConfirmation)

    public var receipt: PullRequestActionReceipt? {
        if case .succeeded(let receipt) = self { return receipt }
        return nil
    }

    public var refusal: PullRequestRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }

    public var didSucceed: Bool { receipt != nil }

    /// The headline a surface shows, whatever the outcome. Never empty.
    public var headline: String {
        switch self {
        case .succeeded(let receipt): return receipt.summary
        case .refused(let refusal): return refusal.headline
        case .mergeabilityUnknown(let pending): return pending.headline
        case .needsConfirmation: return "Confirmation required"
        }
    }
}

// MARK: - Review submission

/// A review the user has typed but not yet sent.
///
/// The empty-body rule lives here rather than in the service so the composer can
/// ask the same question the service will ask, get the same answer, and disable
/// its own button with the real reason on it. One rule, one place, two callers.
public struct ReviewSubmission: Equatable, Sendable {
    public var verdict: ReviewVerdict
    public var body: String

    public init(verdict: ReviewVerdict, body: String = "") {
        self.verdict = verdict
        self.body = body
    }

    /// Body with surrounding whitespace gone. Whitespace is not a review.
    public var trimmedBody: String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why this cannot be sent, or nil. Checked before `gh` is launched — a
    /// round trip to be told the body is empty is a round trip we already knew
    /// the answer to.
    public var refusal: PullRequestRefusal? {
        guard verdict.requiresBody, trimmedBody.isEmpty else { return nil }
        return PullRequestRefusal(.emptyReviewBody,
            detail: "\(verdict.submitLabel) needs a body; GitHub rejects an empty one.")
    }

    public var canSubmit: Bool { refusal == nil }
}

extension ReviewVerdict {
    /// Button and sentence wording. `label` is deliberately not on the spine's
    /// enum — T94 owns the verbs, T93 owns the nouns.
    public var submitLabel: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        case .comment: return "Comment"
        }
    }

    /// What the reviewer is doing, in a sentence naming the consequence.
    public var submitDescription: String {
        switch self {
        case .approve:
            return "Records your approval. On a protected branch this may be what unblocks a merge."
        case .requestChanges:
            return "Blocks the pull request until you or another reviewer clears it."
        case .comment:
            return "Leaves remarks without approving or blocking."
        }
    }
}

/// Where a line comment is going to land.
///
/// `line` is the anchor on `side`; `startLine` turns it into a range. GitHub
/// rejects an anchor that is not on a line the diff touches, and that rejection
/// arrives as a 422 with a message about the diff — `PullRequestActionClassifier`
/// turns it into `.lineNotInDiff` so the user is told which fact is wrong rather
/// than shown a status code.
public struct ReviewCommentAnchor: Equatable, Sendable {
    public var path: String
    public var line: Int
    public var startLine: Int?
    public var side: DiffSide
    public var body: String

    public init(path: String, line: Int, startLine: Int? = nil,
                side: DiffSide = .right, body: String) {
        self.path = path
        self.line = line
        self.startLine = startLine
        self.side = side
        self.body = body
    }

    public var trimmedBody: String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local objections, before any network. An empty comment is not a comment,
    /// and a range that ends before it starts is a typo we can name ourselves
    /// rather than let GitHub name for us.
    public var refusal: PullRequestRefusal? {
        if trimmedBody.isEmpty {
            return PullRequestRefusal(.emptyReviewBody,
                detail: "A line comment with no text says nothing.")
        }
        if path.trimmingCharacters(in: .whitespaces).isEmpty {
            return PullRequestRefusal(.lineNotInDiff, detail: "No file path was given.")
        }
        if line <= 0 {
            return PullRequestRefusal(.lineNotInDiff,
                detail: "Line \(line) is not a line number.")
        }
        if let startLine, startLine > line {
            return PullRequestRefusal(.lineNotInDiff,
                detail: "The range starts at \(startLine) and ends at \(line).")
        }
        return nil
    }
}

// MARK: - Repository merge policy

/// What the repository actually allows, as GitHub reports it.
///
/// `isAuthoritative` is the load-bearing field. When the repository read fails —
/// no permission to read settings, a timeout, an old `gh` — we do **not** guess
/// that all three methods work and we do not guess that none does. We show all
/// three and say we could not tell, which is the only honest option and keeps a
/// user from staring at a picker missing the button they wanted.
public struct RepositoryMergePolicy: Codable, Equatable, Sendable {
    public var nameWithOwner: String?
    public var allowsMergeCommit: Bool
    public var allowsSquash: Bool
    public var allowsRebase: Bool
    /// The repository's own "delete branch on merge" setting. Reported so the
    /// sheet can say the branch may go regardless of our tick — it never turns
    /// our tick on.
    public var deletesBranchOnMerge: Bool
    /// False when the settings read did not land. Then `methods` is all three.
    public var isAuthoritative: Bool

    public init(nameWithOwner: String? = nil, allowsMergeCommit: Bool = true,
                allowsSquash: Bool = true, allowsRebase: Bool = true,
                deletesBranchOnMerge: Bool = false, isAuthoritative: Bool = false) {
        self.nameWithOwner = nameWithOwner
        self.allowsMergeCommit = allowsMergeCommit
        self.allowsSquash = allowsSquash
        self.allowsRebase = allowsRebase
        self.deletesBranchOnMerge = deletesBranchOnMerge
        self.isAuthoritative = isAuthoritative
    }

    /// What the picker may offer. Never empty: a repository that reports every
    /// method disabled is a reading we do not believe, and an empty picker is a
    /// dead end with no remedy.
    public var methods: [MergeMethod] {
        guard isAuthoritative else { return MergeMethod.allCases }
        var allowed: [MergeMethod] = []
        if allowsMergeCommit { allowed.append(.merge) }
        if allowsSquash { allowed.append(.squash) }
        if allowsRebase { allowed.append(.rebase) }
        return allowed.isEmpty ? MergeMethod.allCases : allowed
    }

    public func allows(_ method: MergeMethod) -> Bool {
        methods.contains(method)
    }
}

// MARK: - Plans

/// Whether a merge may be attempted at all.
public enum MergeReadiness: Equatable, Sendable {
    /// GitHub says the branches merge, or says nothing that contradicts it.
    case ready
    /// GitHub is computing. Not permission, not refusal.
    case stillComputing
    /// A named dead end: closed, conflicting, method disabled.
    case refused(PullRequestRefusal)

    public var isReady: Bool { self == .ready }
}

/// Everything a merge confirmation needs to say, computed from a live read.
///
/// A plan is not a merge. Building one costs a `gh pr view` and launches nothing
/// that writes. It is the only way to obtain the token `merge` demands, which
/// is how "read the pull request before merging it" stops being a convention
/// somebody can forget and becomes the shape of the API.
public struct MergePlan: Equatable, Sendable {
    public var ref: PullRequestRef
    public var title: String
    public var method: MergeMethod
    /// Defaults to false everywhere it is constructed. The only thing that makes
    /// it true is a user ticking a box.
    public var deleteBranch: Bool
    public var headRefName: String
    public var baseRefName: String
    public var headRefOid: String?
    public var state: PullRequestState
    public var mergeable: MergeabilityState
    public var mergeStateStatus: String?
    public var isDraft: Bool
    public var readiness: MergeReadiness
    public var policy: RepositoryMergePolicy
    /// Things true of this merge that are not refusals but that a person would
    /// want to have read first — a blocked branch protection, a draft, a
    /// repository that deletes branches on its own.
    public var warnings: [String]
    /// The worktree the plan was built in. Part of the token, so a plan cannot
    /// be carried to another checkout.
    public var worktreePath: String

    public var confirmation: ActionConfirmation {
        ActionConfirmation(sentence: sentence, token: ActionConfirmation.token([
            ("action", "merge"),
            ("repo", ref.repository),
            ("number", String(ref.number)),
            ("method", method.rawValue),
            ("deleteBranch", deleteBranch ? "yes" : "no"),
            ("head", headRefOid ?? "unknown"),
            ("state", state.rawValue),
            ("worktree", worktreePath),
        ]))
    }

    /// The sentence. It names the pull request by number *and* title, the method
    /// in words, and the branch's fate — the three facts somebody who merged the
    /// wrong thing wishes they had been shown.
    public var sentence: String {
        var text = "Merge \(ref.repository)#\(ref.number) “\(title)” into "
        text += "\(baseRefName) by \(method.sentenceFragment)."
        text += deleteBranch
            ? " The branch \(headRefName) will be deleted."
            : " The branch \(headRefName) will be kept."
        return text
    }

    public init(ref: PullRequestRef, title: String, method: MergeMethod,
                deleteBranch: Bool = false, headRefName: String, baseRefName: String,
                headRefOid: String? = nil, state: PullRequestState,
                mergeable: MergeabilityState, mergeStateStatus: String? = nil,
                isDraft: Bool = false, readiness: MergeReadiness,
                policy: RepositoryMergePolicy = RepositoryMergePolicy(),
                warnings: [String] = [], worktreePath: String) {
        self.ref = ref
        self.title = title
        self.method = method
        self.deleteBranch = deleteBranch
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.headRefOid = headRefOid
        self.state = state
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.isDraft = isDraft
        self.readiness = readiness
        self.policy = policy
        self.warnings = warnings
        self.worktreePath = worktreePath
    }
}

/// The two live readings a merge plan is derived from, kept together so a UI can
/// take them once and then re-derive a plan for every method the user tries
/// without asking GitHub again.
///
/// That is not an optimisation, it is the reason the picker can be honest: a
/// sheet that had to spend two round trips per radio button would end up caching
/// a stale readiness or showing a spinner on a toggle, and both of those are how
/// a merge button ends up enabled against a state nobody re-read.
public struct MergeContext: Equatable, Sendable {
    public var detail: PullRequestDetail
    public var policy: RepositoryMergePolicy

    public init(detail: PullRequestDetail, policy: RepositoryMergePolicy) {
        self.detail = detail
        self.policy = policy
    }
}

extension MergePlan {
    /// Derive a plan from one reading. Pure — no network, no clock, no defaults
    /// beyond `deleteBranch: false`.
    ///
    /// The order of the checks is the argument this function exists to make.
    /// Certain refusals are decided first and the pending state last, because
    /// "GitHub has not worked it out yet" must never outrank "this is already
    /// merged" or "this repository does not allow squashing". A pending state
    /// that outranks a certain refusal is a spinner in front of a locked door.
    public static func make(context: MergeContext, method: MergeMethod,
                            deleteBranch: Bool = false,
                            worktreePath: String) -> MergePlan {
        let pr = context.detail
        let policy = context.policy

        var warnings: [String] = []
        if pr.isDraft {
            warnings.append("This pull request is a draft. GitHub will refuse to merge it "
                + "until it is marked ready.")
        }
        switch pr.mergeStateStatus?.uppercased() {
        case "BLOCKED":
            warnings.append("GitHub reports the merge as blocked — a required review or "
                + "check is not satisfied. The attempt may still be refused.")
        case "BEHIND":
            warnings.append("The branch is behind its base. GitHub may require an update "
                + "before merging.")
        case "UNSTABLE":
            warnings.append("Some checks are failing. GitHub will allow this merge, but the "
                + "failures are real.")
        default:
            break
        }
        if policy.deletesBranchOnMerge, !deleteBranch {
            warnings.append("This repository deletes head branches on merge, so "
                + "\(pr.headRefName) may be deleted even though the box is unticked.")
        }
        if !policy.isAuthoritative {
            warnings.append("The repository's merge settings could not be read, so every "
                + "method is offered. GitHub may still refuse one.")
        }

        let readiness: MergeReadiness
        if pr.state != .open {
            readiness = .refused(PullRequestRefusal(.pullRequestNotOpen,
                detail: "\(pr.ref.repository)#\(pr.ref.number) is "
                    + "\(pr.state.label.lowercased())."))
        } else if !policy.allows(method) {
            readiness = .refused(PullRequestRefusal(.mergeMethodUnavailable,
                detail: "\(pr.ref.repository) does not allow \(method.label.lowercased())."))
        } else if pr.mergeable == .conflicting {
            readiness = .refused(PullRequestRefusal(.notMergeable,
                detail: "GitHub reports conflicts between \(pr.headRefName) and "
                    + "\(pr.baseRefName)."))
        } else if pr.mergeable == .unknown {
            readiness = .stillComputing
        } else {
            readiness = .ready
        }

        return MergePlan(
            ref: pr.ref, title: pr.title, method: method, deleteBranch: deleteBranch,
            headRefName: pr.headRefName, baseRefName: pr.baseRefName,
            headRefOid: pr.headRefOid, state: pr.state, mergeable: pr.mergeable,
            mergeStateStatus: pr.mergeStateStatus, isDraft: pr.isDraft,
            readiness: readiness, policy: policy, warnings: warnings,
            worktreePath: worktreePath)
    }
}

extension MergeMethod {
    /// How the sentence says it: a verb phrase, not a button label.
    public var sentenceFragment: String {
        switch self {
        case .merge: return "creating a merge commit"
        case .squash: return "squashing every commit into one"
        case .rebase: return "rebasing its commits onto the base"
        }
    }
}

/// The same two-step shape for closing, because closing is the other act whose
/// cost lands on people who are not in the room.
public struct ClosePlan: Equatable, Sendable {
    public var ref: PullRequestRef
    public var title: String
    public var state: PullRequestState
    public var headRefName: String
    public var openThreadCount: Int?
    public var worktreePath: String

    public var confirmation: ActionConfirmation {
        ActionConfirmation(sentence: sentence, token: ActionConfirmation.token([
            ("action", "close"),
            ("repo", ref.repository),
            ("number", String(ref.number)),
            ("state", state.rawValue),
            ("worktree", worktreePath),
        ]))
    }

    public var sentence: String {
        var text = "Close \(ref.repository)#\(ref.number) “\(title)” without merging it."
        text += " The branch \(headRefName) will be kept."
        if let openThreadCount, openThreadCount > 0 {
            text += " \(openThreadCount) unresolved review "
            text += openThreadCount == 1 ? "thread stays open." : "threads stay open."
        }
        return text
    }

    public init(ref: PullRequestRef, title: String, state: PullRequestState,
                headRefName: String, openThreadCount: Int? = nil, worktreePath: String) {
        self.ref = ref
        self.title = title
        self.state = state
        self.headRefName = headRefName
        self.openThreadCount = openThreadCount
        self.worktreePath = worktreePath
    }
}
