import Foundation
import OrchardCore

/// Why a checks reading could not be taken.
///
/// The whole point of T88: every path that cannot answer is *named*. A blank
/// panel, a spinner that never resolves, or a green tick standing in for "we
/// don't know" are all failures of this enum, not of the UI.
public enum ChecksUnavailableReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// No `gh` on this machine (or not where a GUI-launched app can see it).
    case ghNotInstalled = "gh_not_installed"
    /// `gh` is there but nobody is logged in, or the token it has is rejected.
    case ghNotAuthenticated = "gh_not_authenticated"
    /// The worktree's repo has no git remote at all.
    case noGitRemote = "no_git_remote"
    /// It has a remote, and that remote is not GitHub.
    case unsupportedForge = "unsupported_forge"
    /// HEAD is detached, so there is no branch a PR could be found for.
    case detachedHead = "detached_head"
    /// GitHub answered, and there is no pull request for this branch.
    case noPullRequest = "no_pull_request"
    /// GitHub answered with an error (rate limit, 404, 5xx, network).
    case apiError = "api_error"
    /// `gh` was still running when the deadline passed and was killed.
    case ghTimedOut = "gh_timed_out"
    /// The workspace lives on another machine; reading it locally would answer
    /// for the wrong checkout.
    case remoteWorkspace = "remote_unsupported"
    /// The path is not (or no longer) a git worktree.
    case notAWorktree = "not_a_worktree"
    /// A folder workspace: no branch, so nothing to look a PR up by.
    case notAGitWorkspace = "not_a_git_workspace"

    public var headline: String {
        switch self {
        case .ghNotInstalled: return "GitHub CLI not found"
        case .ghNotAuthenticated: return "GitHub CLI not authenticated"
        case .noGitRemote: return "No git remote"
        case .unsupportedForge: return "Remote is not GitHub"
        case .detachedHead: return "Detached HEAD"
        case .noPullRequest: return "No pull request"
        case .apiError: return "GitHub API error"
        case .ghTimedOut: return "GitHub CLI timed out"
        case .remoteWorkspace: return "Remote workspace"
        case .notAWorktree: return "Not a git worktree"
        case .notAGitWorkspace: return "Folder workspace"
        }
    }

    /// The one thing a user can do about it. Never empty — a named dead end with
    /// no next step is only half an answer.
    public var remedy: String {
        switch self {
        case .ghNotInstalled:
            return "Install it (brew install gh), then refresh."
        case .ghNotAuthenticated:
            return "Run gh auth login in a terminal, then refresh."
        case .noGitRemote:
            return "Add a remote (git remote add origin …) and push the branch."
        case .unsupportedForge:
            return "Checks read GitHub only. Nothing is inferred for other forges."
        case .detachedHead:
            return "Check out a branch, then refresh."
        case .noPullRequest:
            return "Open a pull request for this branch, then refresh."
        case .apiError:
            return "Retry; if it persists check gh auth status and network access."
        case .ghTimedOut:
            return "Retry. A slow or blocked network is the usual cause."
        case .remoteWorkspace:
            return "Read checks from a shell on that host; Orchard will not answer for it from here."
        case .notAWorktree:
            return "Open a workspace backed by a git worktree."
        case .notAGitWorkspace:
            return "Folder workspaces have no branch, so no pull request can be found."
        }
    }
}

/// A named dead end plus whatever detail the tool actually said. `detail` carries
/// `gh`'s own stderr where there is one, so the user is never left guessing what
/// went wrong behind a friendly headline.
public struct ChecksUnavailability: Codable, Equatable, Sendable, Error {
    public var reason: ChecksUnavailableReason
    public var code: String
    public var headline: String
    public var detail: String
    public var remedy: String

    public init(_ reason: ChecksUnavailableReason, detail: String = "") {
        self.reason = reason
        self.code = reason.rawValue
        self.headline = reason.headline
        self.detail = detail
        self.remedy = reason.remedy
    }
}

/// Where one check sits, collapsed from GitHub's `status` × `conclusion` grid to
/// the buckets a person reads at a glance. `unknown` is real and stays visible:
/// a conclusion string we have never seen is shown as unknown, not as a pass.
public enum CheckBucket: String, Codable, Equatable, Sendable, CaseIterable {
    case pass, fail, pending, skipped, cancelled, neutral, unknown

    public var label: String {
        switch self {
        case .pass: return "Passed"
        case .fail: return "Failed"
        case .pending: return "Running"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        case .neutral: return "Neutral"
        case .unknown: return "Unknown"
        }
    }

    public var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        case .skipped: return "minus.circle"
        case .cancelled: return "slash.circle"
        case .neutral: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Rollup precedence: one failure beats any number of passes, and anything
    /// still running beats a pass because the answer is not in yet.
    var severity: Int {
        switch self {
        case .fail: return 5
        case .pending: return 4
        case .cancelled: return 3
        case .unknown: return 2
        case .neutral: return 1
        case .skipped: return 0
        case .pass: return 0
        }
    }

    /// GitHub's `status` + `conclusion` pair, collapsed. Nothing is invented:
    /// an unrecognised conclusion lands in `.unknown`.
    public static func from(status: String?, conclusion: String?) -> CheckBucket {
        let state = (conclusion?.isEmpty == false ? conclusion : status)?.uppercased() ?? ""
        switch state {
        case "SUCCESS", "COMPLETED_SUCCESS": return .pass
        case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR": return .fail
        case "CANCELLED": return .cancelled
        case "SKIPPED": return .skipped
        case "NEUTRAL", "STALE": return .neutral
        case "QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED", "EXPECTED":
            return .pending
        case "": return .unknown
        default: return .unknown
        }
    }
}

/// The overall verdict for a PR's checks. `none` is a genuine answer — a PR with
/// no CI configured — and is spelled differently from "we could not look".
public enum ChecksRollup: String, Codable, Equatable, Sendable {
    case pass, fail, pending, neutral, none, unknown

    public var label: String {
        switch self {
        case .pass: return "All checks passed"
        case .fail: return "Checks failed"
        case .pending: return "Checks running"
        case .neutral: return "Checks neutral"
        case .none: return "No checks reported"
        case .unknown: return "Check state unknown"
        }
    }

    public static func from(_ checks: [CheckRunSummary]) -> ChecksRollup {
        guard !checks.isEmpty else { return .none }
        let worst = checks.map(\.bucketValue).max(by: { $0.severity < $1.severity }) ?? .unknown
        switch worst {
        case .fail: return .fail
        case .pending: return .pending
        case .cancelled: return .fail
        case .unknown: return .unknown
        case .neutral: return .neutral
        case .skipped, .pass: return .pass
        }
    }
}

/// One check, as the sidebar lists it.
public struct CheckRunSummary: Codable, Equatable, Sendable, Identifiable {
    /// Stable within a snapshot: the details URL when there is one, else the name.
    public var id: String
    public var name: String
    public var workflow: String?
    /// `CheckRun` or `StatusContext` — the two things GitHub's rollup contains.
    public var kind: String
    /// Raw GitHub `status` (CheckRun only) and `conclusion`/`state`, kept verbatim
    /// so the UI can show what GitHub actually said next to our bucket.
    public var status: String?
    public var conclusion: String?
    public var bucket: String
    public var bucketLabel: String
    public var detailsUrl: String?
    public var startedAt: String?
    public var completedAt: String?
    public var summary: String?
    /// Actions run id and job id parsed out of `detailsUrl`. Both nil is exactly
    /// the case where `checks show` has no log to fetch, and says so.
    public var runId: String?
    public var jobId: String?

    public var bucketValue: CheckBucket { CheckBucket(rawValue: bucket) ?? .unknown }

    public init(id: String, name: String, workflow: String? = nil, kind: String,
                status: String? = nil, conclusion: String? = nil,
                bucket: CheckBucket, detailsUrl: String? = nil,
                startedAt: String? = nil, completedAt: String? = nil,
                summary: String? = nil, runId: String? = nil, jobId: String? = nil) {
        self.id = id
        self.name = name
        self.workflow = workflow
        self.kind = kind
        self.status = status
        self.conclusion = conclusion
        self.bucket = bucket.rawValue
        self.bucketLabel = bucket.label
        self.detailsUrl = detailsUrl
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.summary = summary
        self.runId = runId
        self.jobId = jobId
    }
}

/// The pull request the checks belong to.
public struct PullRequestSummary: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: String
    /// `OPEN` / `CLOSED` / `MERGED`, verbatim from GitHub.
    public var state: String
    public var isDraft: Bool
    public var headRefName: String
    public var headRefOid: String
    public var repository: String?

    public init(number: Int, title: String, url: String, state: String, isDraft: Bool,
                headRefName: String, headRefOid: String, repository: String? = nil) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.repository = repository
    }
}

/// One reading of a workspace's checks. Either it is `available` and carries a PR
/// plus its checks, or it is `unavailable` and carries a named reason — there is
/// no third shape, which is what makes a blank panel unrepresentable.
public struct ChecksSnapshot: Codable, Equatable, Sendable {
    public var worktreeId: String
    public var worktreePath: String
    public var branch: String?
    /// The commit this reading was taken against. The cache key: when HEAD moves,
    /// the reading is dropped rather than shown against the new commit.
    public var headSha: String?
    /// Epoch milliseconds. Always present, and every surface renders its age —
    /// a cached reading is labelled with when it was taken, never as "now".
    public var observedAt: Double
    /// `available` | `unavailable`.
    public var status: String
    public var unavailable: ChecksUnavailability?
    public var pullRequest: PullRequestSummary?
    public var checks: [CheckRunSummary]
    public var rollup: String
    public var rollupLabel: String

    public var isAvailable: Bool { status == "available" }
    public var rollupValue: ChecksRollup { ChecksRollup(rawValue: rollup) ?? .unknown }
    public var observedDate: Date { Date(timeIntervalSince1970: observedAt / 1000) }

    public init(worktreeId: String, worktreePath: String, branch: String?,
                headSha: String?, observedAt: Date = Date(),
                unavailable: ChecksUnavailability) {
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.branch = branch
        self.headSha = headSha
        self.observedAt = observedAt.timeIntervalSince1970 * 1000
        self.status = "unavailable"
        self.unavailable = unavailable
        self.pullRequest = nil
        self.checks = []
        self.rollup = ChecksRollup.unknown.rawValue
        self.rollupLabel = ChecksRollup.unknown.label
    }

    public init(worktreeId: String, worktreePath: String, branch: String?,
                headSha: String?, observedAt: Date = Date(),
                pullRequest: PullRequestSummary, checks: [CheckRunSummary]) {
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.branch = branch
        self.headSha = headSha
        self.observedAt = observedAt.timeIntervalSince1970 * 1000
        self.status = "available"
        self.unavailable = nil
        self.pullRequest = pullRequest
        self.checks = checks
        let rollup = ChecksRollup.from(checks)
        self.rollup = rollup.rawValue
        self.rollupLabel = rollup.label
    }

    /// Counts by bucket, in a fixed order, for the sidebar's summary line.
    public var counts: [(bucket: CheckBucket, count: Int)] {
        CheckBucket.allCases.compactMap { bucket in
            let n = checks.filter { $0.bucket == bucket.rawValue }.count
            return n > 0 ? (bucket, n) : nil
        }
    }
}

/// Why one check's log could not be fetched. Same discipline as the snapshot:
/// the details tab always says something specific.
public enum CheckLogUnavailableReason: String, Codable, Equatable, Sendable {
    /// The check is not a GitHub Actions job, so `gh` has no log for it.
    case notAnActionsJob = "not_an_actions_job"
    /// The job has not finished; GitHub serves logs only for completed jobs.
    case logPending = "log_pending"
    /// GitHub refused or errored on the log request.
    case apiError = "api_error"
    case ghTimedOut = "gh_timed_out"
    /// Logs are retained for a limited window and this one is past it.
    case expired = "log_expired"

    public var headline: String {
        switch self {
        case .notAnActionsJob: return "No fetchable log"
        case .logPending: return "Log not ready"
        case .apiError: return "GitHub API error"
        case .ghTimedOut: return "GitHub CLI timed out"
        case .expired: return "Log expired"
        }
    }

    public var remedy: String {
        switch self {
        case .notAnActionsJob:
            return "This check reports elsewhere. Open its details URL to read it."
        case .logPending:
            return "GitHub serves job logs once the job completes. Refresh when it finishes."
        case .apiError:
            return "Retry; if it persists check gh auth status and network access."
        case .ghTimedOut:
            return "Retry. A slow or blocked network is the usual cause."
        case .expired:
            return "GitHub no longer retains this run's logs. Re-run the workflow to get a fresh one."
        }
    }
}

/// One check's detail view: the check itself, and its log or a named reason there
/// is none.
public struct CheckLogResult: Codable, Equatable, Sendable {
    public var worktreeId: String
    public var check: CheckRunSummary
    public var observedAt: Double
    public var status: String            // `available` | `unavailable`
    public var reason: String?
    public var headline: String?
    public var detail: String?
    public var remedy: String?
    public var log: String?
    /// True when `log` is the tail of a longer log. Stated, never silent.
    public var truncated: Bool
    public var totalLines: Int
    public var returnedLines: Int

    public var isAvailable: Bool { status == "available" }
    public var observedDate: Date { Date(timeIntervalSince1970: observedAt / 1000) }

    public init(worktreeId: String, check: CheckRunSummary, log: String,
                truncated: Bool, totalLines: Int, returnedLines: Int,
                observedAt: Date = Date()) {
        self.worktreeId = worktreeId
        self.check = check
        self.observedAt = observedAt.timeIntervalSince1970 * 1000
        self.status = "available"
        self.reason = nil
        self.headline = nil
        self.detail = nil
        self.remedy = nil
        self.log = log
        self.truncated = truncated
        self.totalLines = totalLines
        self.returnedLines = returnedLines
    }

    public init(worktreeId: String, check: CheckRunSummary,
                reason: CheckLogUnavailableReason, detail: String = "",
                observedAt: Date = Date()) {
        self.worktreeId = worktreeId
        self.check = check
        self.observedAt = observedAt.timeIntervalSince1970 * 1000
        self.status = "unavailable"
        self.reason = reason.rawValue
        self.headline = reason.headline
        self.detail = detail
        self.remedy = reason.remedy
        self.log = nil
        self.truncated = false
        self.totalLines = 0
        self.returnedLines = 0
    }
}

/// Typed failure for the `checks` verbs. Codes are the CLI/RPC contract.
public struct ChecksCommandError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    public static func invalidArgument(_ message: String) -> ChecksCommandError {
        ChecksCommandError("invalid_argument", message)
    }
}
