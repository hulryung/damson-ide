import Foundation

/// Pure translation from what `gh` printed to what Orchard shows.
///
/// Everything here is a total function over `GitHubCLIOutcome`: there is no
/// "couldn't tell" branch that returns nil and leaves a caller to invent a state.
/// A shape we do not recognise becomes `apiError` carrying the raw stderr, which
/// is a named answer with the evidence attached.
public enum GitHubChecksParser {
    /// The exit code `gh` uses for "you are not authenticated".
    static let notAuthenticatedExit: Int32 = 4

    /// Classify a failed `gh pr view`. The message text is the contract `gh`
    /// actually offers; each of these was observed live against gh 2.98.0 and is
    /// covered by a fixture test so a wording change fails loudly rather than
    /// silently degrading to `api_error`.
    public static func unavailability(from outcome: GitHubCLIOutcome) -> ChecksUnavailability {
        if !outcome.launched {
            // Either there is no binary, or the one we found refused to launch.
            // Both are "gh cannot run here"; the second carries why.
            return ChecksUnavailability(.ghNotInstalled,
                                        detail: firstMeaningfulLine(outcome.stderr))
        }
        if outcome.timedOut {
            return ChecksUnavailability(.ghTimedOut,
                detail: "gh did not answer before the deadline.")
        }
        let text = (outcome.stderr + "\n" + outcome.stdout)
        let lowered = text.lowercased()
        let detail = firstMeaningfulLine(text)

        if lowered.contains("no git remotes found") {
            return ChecksUnavailability(.noGitRemote, detail: detail)
        }
        if lowered.contains("point to a known github host")
            || lowered.contains("not a github repository") {
            return ChecksUnavailability(.unsupportedForge, detail: detail)
        }
        if outcome.status == notAuthenticatedExit
            || lowered.contains("to get started with github cli")
            || lowered.contains("gh auth login")
            || lowered.contains("bad credentials")
            || lowered.contains("http 401") {
            return ChecksUnavailability(.ghNotAuthenticated, detail: detail)
        }
        if lowered.contains("no pull requests found")
            || lowered.contains("no open pull requests found") {
            return ChecksUnavailability(.noPullRequest, detail: detail)
        }
        if lowered.contains("not a git repository") {
            return ChecksUnavailability(.notAWorktree, detail: detail)
        }
        return ChecksUnavailability(.apiError, detail: detail.isEmpty
            ? "gh exited \(outcome.status.map(String.init) ?? "?") with no diagnostic."
            : detail)
    }

    /// Classify a failed `gh run view --log`.
    public static func logUnavailability(
        from outcome: GitHubCLIOutcome) -> (CheckLogUnavailableReason, String) {
        if !outcome.launched { return (.apiError, "gh is not available.") }
        if outcome.timedOut { return (.ghTimedOut, "gh did not answer before the deadline.") }
        let text = outcome.stderr + "\n" + outcome.stdout
        let lowered = text.lowercased()
        let detail = firstMeaningfulLine(text)
        if lowered.contains("still in progress") || lowered.contains("has not completed")
            || lowered.contains("run in progress") {
            return (.logPending, detail)
        }
        if lowered.contains("expired") || lowered.contains("no longer available")
            || lowered.contains("gone") {
            return (.expired, detail)
        }
        return (.apiError, detail.isEmpty ? "gh exited without a diagnostic." : detail)
    }

    /// `gh pr view --json …` output → a PR summary plus its checks.
    ///
    /// Throws nothing: an unreadable payload is an `apiError` unavailability with
    /// the raw text as detail, because "gh answered something we can't read" is a
    /// different fact from "there is no PR" and must not be shown as either
    /// success or "no pull request".
    public static func parsePullRequest(
        _ outcome: GitHubCLIOutcome
    ) -> Result<(PullRequestSummary, [CheckRunSummary]), ChecksUnavailability> {
        guard outcome.status == 0 else { return .failure(unavailability(from: outcome)) }
        guard let data = outcome.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(ChecksUnavailability(.apiError,
                detail: "gh printed output that is not JSON: "
                    + firstMeaningfulLine(outcome.stdout)))
        }
        guard let number = root["number"] as? Int else {
            return .failure(ChecksUnavailability(.apiError,
                detail: "gh returned JSON with no pull-request number."))
        }
        let pr = PullRequestSummary(
            number: number,
            title: root["title"] as? String ?? "",
            url: root["url"] as? String ?? "",
            state: (root["state"] as? String ?? "UNKNOWN").uppercased(),
            isDraft: root["isDraft"] as? Bool ?? false,
            headRefName: root["headRefName"] as? String ?? "",
            headRefOid: root["headRefOid"] as? String ?? "",
            repository: repositoryName(from: root["url"] as? String))
        let rollup = root["statusCheckRollup"] as? [[String: Any]] ?? []
        return .success((pr, uniquelyIdentified(rollup.compactMap(check(from:)))))
    }

    /// A rollup can legitimately carry several entries with the same name — a
    /// retried job, or two commit statuses from the same context — and most of the
    /// time their details URLs tell them apart. When even that repeats, the id is
    /// suffixed with its position so every check stays individually addressable
    /// (the sidebar list and `checks show --check` both key on it).
    static func uniquelyIdentified(_ checks: [CheckRunSummary]) -> [CheckRunSummary] {
        var seen: Set<String> = []
        return checks.enumerated().map { index, check in
            guard seen.contains(check.id) else {
                seen.insert(check.id)
                return check
            }
            var copy = check
            copy.id = "\(check.id)#\(index)"
            seen.insert(copy.id)
            return copy
        }
    }

    /// `https://github.com/<owner>/<repo>/pull/<n>` → `owner/repo`. Read off the
    /// URL gh already returned rather than spent as a second `gh repo view`.
    static func repositoryName(from url: String?) -> String? {
        guard let url, let parsed = URL(string: url) else { return nil }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// One rollup node. GitHub's rollup mixes `CheckRun` (Actions and friends) and
    /// `StatusContext` (the older commit-status API); the two spell every field
    /// differently, so both spellings are read and the origin is recorded.
    static func check(from node: [String: Any]) -> CheckRunSummary? {
        let typename = node["__typename"] as? String ?? "CheckRun"
        let name = (node["name"] as? String)
            ?? (node["context"] as? String)
            ?? ""
        guard !name.isEmpty else { return nil }
        let detailsUrl = (node["detailsUrl"] as? String) ?? (node["targetUrl"] as? String)
        let status = node["status"] as? String
        let conclusion = (node["conclusion"] as? String) ?? (node["state"] as? String)
        let bucket = CheckBucket.from(status: status, conclusion: conclusion)
        let ids = actionsIdentifiers(detailsUrl)
        return CheckRunSummary(
            id: detailsUrl ?? name,
            name: name,
            workflow: node["workflowName"] as? String,
            kind: typename,
            status: status,
            conclusion: conclusion,
            bucket: bucket,
            detailsUrl: detailsUrl,
            startedAt: (node["startedAt"] as? String) ?? (node["createdAt"] as? String),
            completedAt: node["completedAt"] as? String,
            summary: (node["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            runId: ids.runId,
            jobId: ids.jobId)
    }

    /// `https://github.com/o/r/actions/runs/<runId>/job/<jobId>` → the two ids.
    /// Anything else yields `(nil, nil)`, which is exactly the state `checks show`
    /// reports as `not_an_actions_job` instead of pretending it can fetch a log.
    public static func actionsIdentifiers(_ url: String?) -> (runId: String?, jobId: String?) {
        guard let url, let parsed = URL(string: url) else { return (nil, nil) }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        var runId: String?, jobId: String?
        if let index = parts.firstIndex(of: "runs"), parts.count > index + 1,
           parts[index + 1].allSatisfy(\.isNumber) {
            runId = parts[index + 1]
        }
        if let index = parts.firstIndex(of: "job"), parts.count > index + 1,
           parts[index + 1].allSatisfy(\.isNumber) {
            jobId = parts[index + 1]
        }
        return (runId, jobId)
    }

    /// The first line that carries content. `gh` puts the fact on line one and the
    /// suggestion on line two; showing only line two ("Try authenticating with…")
    /// would hide what actually happened.
    static func firstMeaningfulLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Keep the tail of a long log: for a failing job the end is the part that
    /// says why. Truncation is reported, never silent.
    public static func tail(_ log: String, limit: Int) -> (text: String, total: Int,
                                                           returned: Int, truncated: Bool) {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // A trailing newline yields one empty element that is not a line.
        var body = lines
        if body.last == "" { body.removeLast() }
        guard limit > 0, body.count > limit else {
            return (body.joined(separator: "\n"), body.count, body.count, false)
        }
        let kept = Array(body.suffix(limit))
        return (kept.joined(separator: "\n"), body.count, kept.count, true)
    }
}
