import Foundation

/// Why a pull-request operation could not be carried out.
///
/// Same discipline as `ChecksUnavailableReason` (T88) and deliberately *not* the
/// same type. The shared facts — no `gh`, not authenticated, no remote, detached
/// HEAD — carry the same `rawValue` in both vocabularies, because they are the
/// same fact and should log and grep as one. What differs is the remedy: "then
/// refresh" is the right next step for a reading and the wrong one for a write.
/// Do not unify these two enums into one; unify the *probe* instead.
///
/// Every case here is a dead end a person can act on. A write that fails without
/// landing in this enum is a bug, not a surprise: `apiError` is the honest catch
/// -all and it carries `gh`'s own stderr in `detail`.
public enum PullRequestRefusalReason: String, Codable, Equatable, Sendable, CaseIterable {

    // MARK: Shared preconditions — raw values match ChecksUnavailableReason

    /// No `gh` on this machine, or not where a GUI-launched app can see it.
    case ghNotInstalled = "gh_not_installed"
    /// `gh` is present but has no usable credentials.
    case ghNotAuthenticated = "gh_not_authenticated"
    /// The worktree has no remote to open a pull request against.
    case noGitRemote = "no_git_remote"
    /// The remote is not GitHub. Nothing is inferred for other forges.
    case unsupportedForge = "unsupported_forge"
    /// HEAD is detached, so there is no branch to propose.
    case detachedHead = "detached_head"
    /// `gh` was launched and did not answer inside the timeout.
    case ghTimedOut = "gh_timed_out"
    /// The workspace lives on another host; Orchard will not answer for it here.
    case remoteWorkspace = "remote_unsupported"
    /// The path is not inside a git work tree.
    case notAWorktree = "not_a_worktree"
    /// `gh` failed for a reason we did not recognise. `detail` carries its stderr.
    case apiError = "api_error"

    // MARK: Creation

    /// The branch has no commits the base does not already have.
    case nothingToPropose = "nothing_to_propose"
    /// The branch exists locally but has never been pushed, so GitHub cannot see it.
    case branchNotPushed = "branch_not_pushed"
    /// The local branch is ahead of its upstream: GitHub would review stale code.
    case unpushedCommits = "unpushed_commits"
    /// A pull request for this branch already exists.
    case pullRequestExists = "pull_request_exists"
    /// No base ref could be resolved — the repo default branch is unknown and the
    /// caller named none.
    case noBaseRef = "no_base_ref"
    /// The named base does not exist on the remote.
    case baseRefMissing = "base_ref_missing"
    /// Head and base are the same ref.
    case baseEqualsHead = "base_equals_head"
    /// The title was empty. GitHub will not take an untitled pull request and we
    /// will not invent one.
    case emptyTitle = "empty_title"

    // MARK: Acting on an existing pull request

    /// The operation needs a pull request and this branch has none.
    case noPullRequest = "no_pull_request"
    /// GitHub refuses a self-review.
    case cannotReviewOwnPullRequest = "cannot_review_own_pull_request"
    /// The review body was empty where GitHub requires one (request-changes and
    /// a bare comment both do).
    case emptyReviewBody = "empty_review_body"
    /// The pull request is closed or already merged.
    case pullRequestNotOpen = "pull_request_not_open"
    /// The pull request cannot merge: conflicts, or a required gate is unmet.
    case notMergeable = "not_mergeable"
    /// The merge method is disabled for this repository.
    case mergeMethodUnavailable = "merge_method_unavailable"
    /// The token lacks the permission this operation needs.
    case insufficientPermission = "insufficient_permission"
    /// The review thread named does not exist, or is not on this pull request.
    case threadNotFound = "thread_not_found"
    /// The comment anchor does not fall on a line the diff touches.
    case lineNotInDiff = "line_not_in_diff"

    /// One short sentence, sentence case, no trailing period — the headline a
    /// person reads first.
    public var headline: String {
        switch self {
        case .ghNotInstalled: return "GitHub CLI not found"
        case .ghNotAuthenticated: return "GitHub CLI not authenticated"
        case .noGitRemote: return "No git remote"
        case .unsupportedForge: return "Remote is not GitHub"
        case .detachedHead: return "Detached HEAD"
        case .ghTimedOut: return "GitHub CLI timed out"
        case .remoteWorkspace: return "Remote workspace"
        case .notAWorktree: return "Not a git worktree"
        case .apiError: return "GitHub API error"
        case .nothingToPropose: return "Nothing to propose"
        case .branchNotPushed: return "Branch not pushed"
        case .unpushedCommits: return "Unpushed commits"
        case .pullRequestExists: return "Pull request already open"
        case .noBaseRef: return "No base branch"
        case .baseRefMissing: return "Base branch not on the remote"
        case .baseEqualsHead: return "Base and head are the same branch"
        case .emptyTitle: return "Title is empty"
        case .noPullRequest: return "No pull request"
        case .cannotReviewOwnPullRequest: return "Cannot review your own pull request"
        case .emptyReviewBody: return "Review body is empty"
        case .pullRequestNotOpen: return "Pull request is not open"
        case .notMergeable: return "Not mergeable"
        case .mergeMethodUnavailable: return "Merge method unavailable"
        case .insufficientPermission: return "Insufficient permission"
        case .threadNotFound: return "Review thread not found"
        case .lineNotInDiff: return "Line is not in the diff"
        }
    }

    /// The one thing a person can do about it. Never empty — a named dead end
    /// with no next step is only half an answer.
    public var remedy: String {
        switch self {
        case .ghNotInstalled:
            return "Install it (brew install gh), then try again."
        case .ghNotAuthenticated:
            return "Run gh auth login in a terminal, then try again."
        case .noGitRemote:
            return "Add a remote (git remote add origin …), then push the branch."
        case .unsupportedForge:
            return "Pull requests are opened on GitHub only. Nothing is attempted elsewhere."
        case .detachedHead:
            return "Check out a branch, then try again."
        case .ghTimedOut:
            return "Retry. A slow or blocked network is the usual cause."
        case .remoteWorkspace:
            return "Act on the pull request from a shell on that host."
        case .notAWorktree:
            return "Open a workspace backed by a git worktree."
        case .apiError:
            return "Retry; if it persists check gh auth status and network access."
        case .nothingToPropose:
            return "Commit something the base does not already have."
        case .branchNotPushed:
            return "Push the branch first — Orchard will offer to."
        case .unpushedCommits:
            return "Push, so the pull request reviews what you actually wrote."
        case .pullRequestExists:
            return "Open the existing pull request instead."
        case .noBaseRef:
            return "Name a base branch — the repository default could not be resolved."
        case .baseRefMissing:
            return "Push the base branch, or pick one that exists on the remote."
        case .baseEqualsHead:
            return "Pick a different base."
        case .emptyTitle:
            return "Give the pull request a title."
        case .noPullRequest:
            return "Open a pull request for this branch first."
        case .cannotReviewOwnPullRequest:
            return "Leave a comment instead, or have someone else review it."
        case .emptyReviewBody:
            return "Write what you want changed."
        case .pullRequestNotOpen:
            return "Reopen it, or act on a different pull request."
        case .notMergeable:
            return "Resolve the conflicts or satisfy the required checks, then retry."
        case .mergeMethodUnavailable:
            return "Pick a method the repository allows."
        case .insufficientPermission:
            return "Ask for write access, or act as a user who has it."
        case .threadNotFound:
            return "Reload the pull request — the thread may have been deleted."
        case .lineNotInDiff:
            return "Anchor the comment on a line the diff actually changes."
        }
    }

    /// Whether retrying the identical call could plausibly succeed without anything
    /// else changing. Callers use it to decide between a retry affordance and a
    /// dead stop; it is never used to retry automatically behind the user's back.
    public var isTransient: Bool {
        switch self {
        case .ghTimedOut, .apiError: return true
        default: return false
        }
    }
}

/// A named dead end plus whatever `gh` actually said.
///
/// `detail` carries the tool's own stderr where there is one, so a friendly
/// headline never costs the user the real message.
public struct PullRequestRefusal: Codable, Equatable, Sendable, Error {
    public var reason: PullRequestRefusalReason
    public var code: String
    public var headline: String
    public var detail: String
    public var remedy: String

    public init(_ reason: PullRequestRefusalReason, detail: String = "") {
        self.reason = reason
        self.code = reason.rawValue
        self.headline = reason.headline
        self.detail = detail
        self.remedy = reason.remedy
    }
}
