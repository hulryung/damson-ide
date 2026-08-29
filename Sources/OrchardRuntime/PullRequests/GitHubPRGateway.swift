import Foundation
import OrchardCore

/// The one place pull-request features talk to `gh`.
///
/// Everything above this line works in domain types and typed refusals;
/// everything below is argv, stdout and stderr. Features must not shell out on
/// their own — a second call site is a second stderr vocabulary, and the point
/// of `PullRequestRefusalReason` is that there is exactly one.
///
/// The probe is injected, so every path here is testable against
/// `FixtureGitHubCLI` without a network or a `gh` binary. T88 established that
/// contract; this reuses it rather than inventing a parallel one.
public struct GitHubPRGateway: Sendable {
    public let probe: any GitHubCLIProbe
    public let timeout: TimeInterval

    public init(probe: any GitHubCLIProbe = SystemGitHubCLI(), timeout: TimeInterval = 20) {
        self.probe = probe
        self.timeout = timeout
    }

    // MARK: - Running gh

    /// Run `gh` and return stdout, or the refusal the failure maps to.
    ///
    /// A non-zero exit is always classified — never surfaced as a bare string —
    /// so a caller cannot accidentally show a raw stderr dump where a headline
    /// and a remedy belong.
    public func run(_ arguments: [String], cwd: URL,
                    timeout override: TimeInterval? = nil) async
        -> Result<String, PullRequestRefusal> {
        guard probe.resolvedExecutable() != nil else {
            return .failure(PullRequestRefusal(.ghNotInstalled,
                detail: "No gh binary on this machine's PATH or in the usual install locations."))
        }
        let outcome = await probe.run(arguments, cwd: cwd, timeout: override ?? timeout)
        if outcome.timedOut {
            return .failure(PullRequestRefusal(.ghTimedOut,
                detail: "gh \(arguments.joined(separator: " ")) did not answer in \(Int(override ?? timeout))s."))
        }
        guard outcome.status == 0 else {
            return .failure(Self.classify(outcome))
        }
        return .success(outcome.stdout)
    }

    /// Run `gh` and decode its stdout as a JSON object.
    public func json(_ arguments: [String], cwd: URL,
                     timeout override: TimeInterval? = nil) async
        -> Result<[String: Any], PullRequestRefusal> {
        switch await run(arguments, cwd: cwd, timeout: override) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let stdout):
            guard let data = stdout.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                return .failure(PullRequestRefusal(.apiError,
                    detail: "gh returned output that is not a JSON object: \(Self.firstLine(stdout))"))
            }
            return .success(dictionary)
        }
    }

    // MARK: - Classifying what gh said

    /// Map a failed `gh` invocation onto a named dead end.
    ///
    /// The substrings are `gh`'s own wording, matched case-insensitively. Anything
    /// unrecognised becomes `apiError` carrying the real stderr — the honest
    /// answer, and the one that tells us which substring to add next.
    public static func classify(_ outcome: GitHubCLIOutcome) -> PullRequestRefusal {
        let text = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
        let lowered = text.lowercased()
        let detail = firstLine(text)

        func refusal(_ reason: PullRequestRefusalReason) -> PullRequestRefusal {
            PullRequestRefusal(reason, detail: detail)
        }

        if lowered.contains("no git remotes found") || lowered.contains("no git remote") {
            return refusal(.noGitRemote)
        }
        if lowered.contains("point to a known github host")
            || lowered.contains("not a github repository") {
            return refusal(.unsupportedForge)
        }
        if lowered.contains("gh auth login")
            || lowered.contains("to get started with github cli")
            || lowered.contains("authentication required")
            || lowered.contains("bad credentials")
            || lowered.contains("http 401") {
            return refusal(.ghNotAuthenticated)
        }
        if lowered.contains("not a git repository") {
            return refusal(.notAWorktree)
        }
        if lowered.contains("no pull requests found")
            || lowered.contains("no open pull requests found")
            || lowered.contains("no pull request found") {
            return refusal(.noPullRequest)
        }
        if lowered.contains("a pull request for branch")
            && lowered.contains("already exists") {
            return refusal(.pullRequestExists)
        }
        if lowered.contains("no commits between") {
            return refusal(.nothingToPropose)
        }
        if lowered.contains("must first push")
            || lowered.contains("has no upstream")
            || lowered.contains("does not exist on the remote") {
            return refusal(.branchNotPushed)
        }
        if lowered.contains("can not request changes on your own pull request")
            || lowered.contains("cannot request changes on your own")
            || lowered.contains("can not approve your own pull request")
            || lowered.contains("cannot approve your own") {
            return refusal(.cannotReviewOwnPullRequest)
        }
        if lowered.contains("not mergeable") || lowered.contains("merge conflict")
            || lowered.contains("pull request is not mergeable") {
            return refusal(.notMergeable)
        }
        if lowered.contains("merge method") && lowered.contains("not allowed") {
            return refusal(.mergeMethodUnavailable)
        }
        if lowered.contains("http 403") || lowered.contains("must have admin rights")
            || lowered.contains("resource not accessible") {
            return refusal(.insufficientPermission)
        }
        if lowered.contains("closed") && lowered.contains("cannot be reopened") {
            return refusal(.pullRequestNotOpen)
        }
        return refusal(.apiError)
    }

    /// The first line with anything on it. `gh` puts its real message first and
    /// usage text after; showing the whole blob buries the sentence that matters.
    static func firstLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Decoding gh's JSON

/// `gh pr view --json …` → domain types.
///
/// Every field is optional on the wire and defaulted here, because `--json` gives
/// exactly the fields asked for and a caller that asks for fewer must not crash a
/// decoder. What it must never do is default a *state* into something reassuring:
/// an absent `state` decodes to `.unknown`, not `.open`.
public enum PullRequestDecoder {

    /// The field list `summary(from:)` can fill. Callers pass this to `--json`.
    public static let viewFields = [
        "number", "title", "body", "url", "state", "isDraft", "author",
        "baseRefName", "headRefName", "headRefOid", "reviewDecision",
        "mergeable", "mergeStateStatus", "additions", "deletions",
        "changedFiles", "createdAt", "updatedAt",
    ].joined(separator: ",")

    /// Built field by field rather than as one literal: the whole-expression form
    /// pushed the type-checker past its budget, and the compiler said so.
    public static func detail(from json: [String: Any],
                              repository: String) -> PullRequestDetail? {
        guard let number = json["number"] as? Int else { return nil }
        let url: String = (json["url"] as? String)
            ?? "https://github.com/\(repository)/pull/\(number)"
        let ref = PullRequestRef(repository: repository, number: number, url: url)

        var detail = PullRequestDetail(
            ref: ref,
            title: json["title"] as? String ?? "",
            state: PullRequestState(gh: json["state"] as? String),
            baseRefName: json["baseRefName"] as? String ?? "",
            headRefName: json["headRefName"] as? String ?? "")

        detail.body = json["body"] as? String ?? ""
        detail.author = actor(json["author"])
        detail.isDraft = json["isDraft"] as? Bool ?? false
        detail.headRefOid = json["headRefOid"] as? String
        detail.reviewDecision = ReviewDecision(gh: json["reviewDecision"] as? String)
        detail.mergeable = MergeabilityState(gh: json["mergeable"] as? String)
        detail.mergeStateStatus = json["mergeStateStatus"] as? String
        detail.additions = json["additions"] as? Int ?? 0
        detail.deletions = json["deletions"] as? Int ?? 0
        detail.changedFiles = json["changedFiles"] as? Int ?? 0
        detail.createdAt = date(json["createdAt"])
        detail.updatedAt = date(json["updatedAt"])
        return detail
    }

    public static func actor(_ value: Any?) -> GitHubActor? {
        guard let node = value as? [String: Any],
              let login = node["login"] as? String, !login.isEmpty else { return nil }
        return GitHubActor(login: login, avatarURL: node["avatarUrl"] as? String)
    }

    /// GitHub sends RFC 3339, sometimes with fractional seconds. Both parse; an
    /// unparseable stamp becomes nil rather than `Date()`, so "we don't know when"
    /// never renders as "just now".
    public static func date(_ value: Any?) -> Date? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
