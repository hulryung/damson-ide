import Foundation

/// The domain types every pull-request feature shares.
///
/// Field names follow `gh`'s own JSON where there is one, so a reader can put
/// this file next to `gh pr view --json` output and see the mapping without a
/// translation table. Where GitHub has a closed vocabulary we model it as an
/// enum with an explicit `unknown` case: a value we have never seen is shown as
/// unknown, never collapsed into the nearest good state.

// MARK: - Identity

/// Which pull request, on which repository, for which worktree.
///
/// Carried whole rather than as a bare number: a number alone is ambiguous the
/// moment a fork is involved, and every refusal wants to name the repository it
/// was talking to.
public struct PullRequestRef: Codable, Equatable, Sendable {
    /// `owner/name` of the repository the pull request lives on.
    public var repository: String
    public var number: Int
    /// `https://github.com/owner/name/pull/N`.
    public var url: String

    public init(repository: String, number: Int, url: String) {
        self.repository = repository
        self.number = number
        self.url = url
    }
}

// MARK: - Closed vocabularies

public enum PullRequestState: String, Codable, Equatable, Sendable, CaseIterable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
    case unknown = "UNKNOWN"

    public init(gh raw: String?) {
        self = PullRequestState(rawValue: (raw ?? "").uppercased()) ?? .unknown
    }

    public var label: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .merged: return "Merged"
        case .unknown: return "Unknown"
        }
    }
}

/// GitHub's aggregate review verdict for the pull request.
///
/// `undecided` and `unknown` are different facts and stay different: `undecided`
/// means GitHub told us nobody has decided yet; `unknown` means we could not
/// tell. The case is not called `none` on purpose — on an `Optional<ReviewDecision>`
/// that spelling silently resolves to `Optional.none`, and the compiler will not
/// warn you.
public enum ReviewDecision: String, Codable, Equatable, Sendable, CaseIterable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
    case undecided = "NONE"
    case unknown = "UNKNOWN"

    public init(gh raw: String?) {
        guard let raw, !raw.isEmpty else { self = .undecided; return }
        self = ReviewDecision(rawValue: raw.uppercased()) ?? .unknown
    }

    public var label: String {
        switch self {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .reviewRequired: return "Review required"
        case .undecided: return "No review yet"
        case .unknown: return "Unknown"
        }
    }
}

/// Whether GitHub thinks the branches can merge. `unknown` is GitHub's own
/// answer while it computes the merge commit — it is a real state, not a gap in
/// our reading, and the UI must show it as "checking", never as mergeable.
public enum MergeabilityState: String, Codable, Equatable, Sendable, CaseIterable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"

    public init(gh raw: String?) {
        self = MergeabilityState(rawValue: (raw ?? "").uppercased()) ?? .unknown
    }
}

/// What a reviewer is submitting.
public enum ReviewVerdict: String, Codable, Equatable, Sendable, CaseIterable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"

    /// The `gh pr review` flag that carries this verdict.
    public var ghFlag: String {
        switch self {
        case .approve: return "--approve"
        case .requestChanges: return "--request-changes"
        case .comment: return "--comment"
        }
    }

    /// GitHub rejects an empty body for these; `approve` may go in bare.
    public var requiresBody: Bool { self != .approve }
}

public enum MergeMethod: String, Codable, Equatable, Sendable, CaseIterable {
    case merge, squash, rebase

    public var ghFlag: String {
        switch self {
        case .merge: return "--merge"
        case .squash: return "--squash"
        case .rebase: return "--rebase"
        }
    }

    public var label: String {
        switch self {
        case .merge: return "Create a merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }
}

/// Which side of the diff a comment is anchored to.
public enum DiffSide: String, Codable, Equatable, Sendable {
    case left = "LEFT"
    case right = "RIGHT"

    public init(gh raw: String?) {
        self = DiffSide(rawValue: (raw ?? "").uppercased()) ?? .right
    }
}

// MARK: - People and prose

public struct GitHubActor: Codable, Equatable, Sendable {
    public var login: String
    /// Absent for a deleted account, and for some bot actors.
    public var avatarURL: String?

    public init(login: String, avatarURL: String? = nil) {
        self.login = login
        self.avatarURL = avatarURL
    }
}

/// One comment, wherever it sits — the conversation timeline or a review thread.
public struct PullRequestComment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var author: GitHubActor?
    public var body: String
    public var createdAt: Date
    /// True when GitHub reports the comment was edited after posting.
    public var isEdited: Bool
    /// Present only for a comment that came in as part of a submitted review.
    public var reviewVerdict: ReviewVerdict?

    public init(id: String, author: GitHubActor?, body: String, createdAt: Date,
                isEdited: Bool = false, reviewVerdict: ReviewVerdict? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.isEdited = isEdited
        self.reviewVerdict = reviewVerdict
    }
}

/// A line-anchored review conversation.
///
/// `line` is the anchor on `diffSide`; `startLine` is set only for a multi-line
/// anchor. `isOutdated` means the thread's lines no longer exist in the head —
/// it is kept and marked, never dropped, because a stale objection is still an
/// objection somebody has to answer.
public struct ReviewThread: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var line: Int?
    public var startLine: Int?
    public var diffSide: DiffSide
    public var isResolved: Bool
    public var isOutdated: Bool
    public var comments: [PullRequestComment]

    public init(id: String, path: String, line: Int?, startLine: Int? = nil,
                diffSide: DiffSide = .right, isResolved: Bool, isOutdated: Bool,
                comments: [PullRequestComment]) {
        self.id = id
        self.path = path
        self.line = line
        self.startLine = startLine
        self.diffSide = diffSide
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.comments = comments
    }
}

/// One file in the pull request's diff.
public struct PullRequestFile: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var additions: Int
    public var deletions: Int

    public var id: String { path }

    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }
}

// MARK: - The pull request

/// Everything one `gh pr view --json` can tell us, decoded. The fuller sibling of
/// T88's `PullRequestSummary`, which carries only what a checks badge needs.
///
/// Review threads are deliberately *not* here: `gh pr view` does not carry them
/// and a GraphQL round trip is a separate cost. A caller that needs them asks
/// for them, so nobody pays for line-level threads while rendering a badge.
public struct PullRequestDetail: Codable, Equatable, Sendable {
    public var ref: PullRequestRef
    public var title: String
    public var body: String
    public var author: GitHubActor?
    public var state: PullRequestState
    public var isDraft: Bool
    public var baseRefName: String
    public var headRefName: String
    public var headRefOid: String?
    public var reviewDecision: ReviewDecision
    public var mergeable: MergeabilityState
    /// GitHub's `mergeStateStatus` verbatim (BLOCKED, CLEAN, DIRTY, …). Kept as a
    /// string because the vocabulary is undocumented and grows; never branched on
    /// without a default.
    public var mergeStateStatus: String?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(ref: PullRequestRef, title: String, body: String = "",
                author: GitHubActor? = nil, state: PullRequestState,
                isDraft: Bool = false, baseRefName: String, headRefName: String,
                headRefOid: String? = nil, reviewDecision: ReviewDecision = .undecided,
                mergeable: MergeabilityState = .unknown, mergeStateStatus: String? = nil,
                additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0,
                createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.ref = ref
        self.title = title
        self.body = body
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.baseRefName = baseRefName
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Creation

/// What the user is proposing, before it exists.
public struct PullRequestDraft: Equatable, Sendable {
    public var title: String
    public var body: String
    public var base: String
    public var head: String
    public var isDraft: Bool

    public init(title: String, body: String = "", base: String, head: String,
                isDraft: Bool = false) {
        self.title = title
        self.body = body
        self.base = base
        self.head = head
        self.isDraft = isDraft
    }
}

/// Whether a pull request can be opened from this worktree right now, and if not,
/// exactly why.
///
/// Modelled as evidence rather than a boolean so the UI can explain itself: a
/// disabled "Create" button that cannot say why is the failure this type exists
/// to prevent. `existingLookup` distinguishes "GitHub says there is no pull
/// request" from "we could not ask" — conflating those is how a second pull
/// request gets opened by accident.
public struct PullRequestCreationEligibility: Equatable, Sendable {
    public enum ExistingLookup: String, Codable, Equatable, Sendable {
        /// GitHub answered, and there is a pull request for this branch.
        case found
        /// GitHub answered, and there is none.
        case notFound
        /// We could not ask. Never treated as `notFound`.
        case unavailable
    }

    public var refusal: PullRequestRefusal?
    public var existingLookup: ExistingLookup
    public var existing: PullRequestRef?
    /// The base we resolved, when we could resolve one.
    public var resolvedBase: String?
    public var head: String?
    /// Commits on head that base does not have, when countable.
    public var commitsAhead: Int?
    /// True when the branch has commits its upstream does not, so a create would
    /// propose code GitHub cannot see yet.
    public var needsPush: Bool
    /// The repository's pull-request template, when one was found.
    public var template: String?

    public var canCreate: Bool { refusal == nil }

    public init(refusal: PullRequestRefusal? = nil,
                existingLookup: ExistingLookup = .unavailable,
                existing: PullRequestRef? = nil, resolvedBase: String? = nil,
                head: String? = nil, commitsAhead: Int? = nil,
                needsPush: Bool = false, template: String? = nil) {
        self.refusal = refusal
        self.existingLookup = existingLookup
        self.existing = existing
        self.resolvedBase = resolvedBase
        self.head = head
        self.commitsAhead = commitsAhead
        self.needsPush = needsPush
        self.template = template
    }
}
