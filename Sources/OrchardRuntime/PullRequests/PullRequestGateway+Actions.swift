import Foundation

/// What T94 needs from the spine that the spine does not have: the argv for every
/// write verb, and the handful of `gh` sentences that only a write can provoke.
///
/// It lives beside `GitHubPRGateway` rather than inside it because three workers
/// are extending that file at once. Nothing here launches anything — building an
/// argument list is a pure function, which is what lets the tests assert on the
/// exact command a merge *would* run without running one.

// MARK: - Classification

/// The failures only a write produces.
///
/// This never re-decides anything the spine already named. It runs *after*
/// `GitHubPRGateway.classify` and only ever refines `.apiError`, which is the
/// spine's honest "I have not seen this wording". A refinement that could
/// overwrite a named reason would be a second vocabulary, and the whole point of
/// `PullRequestRefusalReason` is that there is one.
public enum PullRequestActionClassifier {

    /// Classify a failed write. `context` narrows the reading where two verbs
    /// share a sentence — GitHub's "Could not resolve to a node" means a missing
    /// thread when we were resolving a thread and means nothing in particular
    /// when we were not.
    public static func classify(_ outcome: GitHubCLIOutcome,
                                context: PullRequestActionKind) -> PullRequestRefusal {
        let base = GitHubPRGateway.classify(outcome)
        guard base.reason == .apiError else { return base }

        let text = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
        let lowered = text.lowercased()
        let detail = base.detail

        func refine(_ reason: PullRequestRefusalReason) -> PullRequestRefusal {
            PullRequestRefusal(reason, detail: detail)
        }

        // A line anchor GitHub will not accept. The 422 body says it in several
        // wordings depending on whether the file, the line or the range is the
        // problem; all three mean the same thing to a person: the anchor is not
        // on a line this diff touches.
        if lowered.contains("must be part of the diff")
            || lowered.contains("not part of the diff")
            || lowered.contains("line must be part of")
            || lowered.contains("pull_request_review_thread.line")
            || lowered.contains("pull_request_review_thread.path")
            || lowered.contains("start_line must precede")
            || (lowered.contains("422") && lowered.contains("diff")) {
            return refine(.lineNotInDiff)
        }

        // A node id GitHub does not know, or knows as something else. GraphQL says
        // "Could not resolve to a node with the global id of …"; REST says 404.
        if lowered.contains("could not resolve to a node")
            || lowered.contains("could not resolve to a pullrequestreviewthread")
            || lowered.contains("does not exist on pullrequestreviewthread")
            || (isThreadVerb(context)
                && (lowered.contains("not found") || lowered.contains("http 404"))) {
            return refine(.threadNotFound)
        }

        // Branch protection and the settings picker. `gh` and the API disagree on
        // wording; both are here.
        if lowered.contains("merge commits are not allowed")
            || lowered.contains("squash merges are not allowed")
            || lowered.contains("rebase merges are not allowed")
            || lowered.contains("merge_method")
            || (lowered.contains("method") && lowered.contains("not allowed")) {
            return refine(.mergeMethodUnavailable)
        }

        // Acting on a pull request that has stopped being open. GitHub reports
        // this several ways, none of which contain the word "mergeable".
        if lowered.contains("pull request is closed")
            || lowered.contains("pull request is already merged")
            || lowered.contains("already merged")
            || lowered.contains("cannot be reopened")
            || lowered.contains("state cannot be changed")
            || lowered.contains("not open") {
            return refine(.pullRequestNotOpen)
        }

        // Everything a protected branch refuses at merge time.
        if lowered.contains("base branch was modified")
            || lowered.contains("required status check")
            || lowered.contains("at least 1 approving review")
            || lowered.contains("changes requested")
            || lowered.contains("review is required")
            || lowered.contains("is not mergeable") {
            return refine(.notMergeable)
        }

        if lowered.contains("http 404") && context == .merge {
            // A merge that 404s is nearly always a token without write access:
            // GitHub hides what you may not touch rather than admitting it exists.
            return refine(.insufficientPermission)
        }

        return base
    }

    private static func isThreadVerb(_ kind: PullRequestActionKind) -> Bool {
        switch kind {
        case .threadReply, .threadResolve, .threadUnresolve: return true
        default: return false
        }
    }
}

// MARK: - Argument lists

/// Every `gh` invocation a write makes, as data.
///
/// Pure functions so a test can assert the exact argv of a merge without a merge
/// happening — which is the only way to check "`--delete-branch` is absent unless
/// the user ticked it" without deleting a branch to find out.
public enum PullRequestActionCommand {

    /// `gh pr view --json …` for the fields a write needs to decide anything.
    public static func view(branch: String?) -> [String] {
        var arguments = ["pr", "view"]
        // Same rule as ChecksService: an all-digits branch name reads as a PR
        // number, so that one case falls back to gh's own resolution in `cwd`.
        if let branch, !branch.isEmpty, !branch.allSatisfy(\.isNumber) {
            arguments.append(branch)
        }
        arguments += ["--json", PullRequestDecoder.viewFields]
        return arguments
    }

    /// `gh repo view --json …` — the repository's merge settings, which is what
    /// lets the sheet offer only the methods that exist.
    public static let repositoryPolicy = [
        "repo", "view", "--json",
        "nameWithOwner,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,deleteBranchOnMerge",
    ]

    public static func review(_ submission: ReviewSubmission, number: Int) -> [String] {
        var arguments = ["pr", "review", String(number), submission.verdict.ghFlag]
        // `--body` is passed even when empty for approve, so the argv shape is
        // the same in both cases and gh never falls through to an editor.
        arguments += ["--body", submission.trimmedBody]
        return arguments
    }

    /// `gh api` POST to the review-comments endpoint.
    ///
    /// `-F` for the integers (gh sends them as JSON numbers) and `-f` for the
    /// strings. `line` without `start_line` is a single-line anchor; with it, a
    /// range, and GitHub then also wants `start_side`.
    public static func lineComment(_ anchor: ReviewCommentAnchor,
                                   repository: String, number: Int,
                                   commitId: String) -> [String] {
        var arguments = [
            "api", "--method", "POST",
            "/repos/\(repository)/pulls/\(number)/comments",
            "-f", "commit_id=\(commitId)",
            "-f", "path=\(anchor.path)",
            "-F", "line=\(anchor.line)",
            "-f", "side=\(anchor.side.rawValue)",
        ]
        if let startLine = anchor.startLine, startLine != anchor.line {
            arguments += ["-F", "start_line=\(startLine)",
                          "-f", "start_side=\(anchor.side.rawValue)"]
        }
        arguments += ["-f", "body=\(anchor.trimmedBody)"]
        return arguments
    }

    static let resolveMutation = """
    mutation($threadId: ID!) { \
    resolveReviewThread(input: {threadId: $threadId}) { \
    thread { id isResolved } } }
    """

    static let unresolveMutation = """
    mutation($threadId: ID!) { \
    unresolveReviewThread(input: {threadId: $threadId}) { \
    thread { id isResolved } } }
    """

    static let replyMutation = """
    mutation($threadId: ID!, $body: String!) { \
    addPullRequestReviewThreadReply(input: \
    {pullRequestReviewThreadId: $threadId, body: $body}) { \
    comment { id url } } }
    """

    public static func resolveThread(_ threadId: String) -> [String] {
        ["api", "graphql", "-f", "query=\(resolveMutation)", "-f", "threadId=\(threadId)"]
    }

    public static func unresolveThread(_ threadId: String) -> [String] {
        ["api", "graphql", "-f", "query=\(unresolveMutation)", "-f", "threadId=\(threadId)"]
    }

    public static func replyToThread(_ threadId: String, body: String) -> [String] {
        ["api", "graphql", "-f", "query=\(replyMutation)",
         "-f", "threadId=\(threadId)", "-f", "body=\(body)"]
    }

    /// `gh pr merge`. `--delete-branch` appears **only** when the plan says so,
    /// and the plan says so only because a user ticked a box that starts unticked.
    public static func merge(_ plan: MergePlan) -> [String] {
        var arguments = ["pr", "merge", String(plan.ref.number), plan.method.ghFlag]
        if plan.deleteBranch { arguments.append("--delete-branch") }
        return arguments
    }

    public static func close(_ plan: ClosePlan) -> [String] {
        // No `--delete-branch`: closing is already the destructive half. Deleting
        // the branch as well is a second decision and is not offered here.
        ["pr", "close", String(plan.ref.number)]
    }

    public static func reopen(number: Int) -> [String] {
        ["pr", "reopen", String(number)]
    }

    /// `gh pr ready` marks it ready; `--undo` converts it back to a draft.
    public static func setDraft(_ isDraft: Bool, number: Int) -> [String] {
        var arguments = ["pr", "ready", String(number)]
        if isDraft { arguments.append("--undo") }
        return arguments
    }
}

// MARK: - Decoding what a write answered

public enum PullRequestActionDecoder {

    /// `gh repo view --json` → the merge policy. A failed read is not a guess:
    /// it comes back with `isAuthoritative == false` and every method offered.
    public static func policy(from json: [String: Any]) -> RepositoryMergePolicy {
        RepositoryMergePolicy(
            nameWithOwner: json["nameWithOwner"] as? String,
            allowsMergeCommit: json["mergeCommitAllowed"] as? Bool ?? true,
            allowsSquash: json["squashMergeAllowed"] as? Bool ?? true,
            allowsRebase: json["rebaseMergeAllowed"] as? Bool ?? true,
            deletesBranchOnMerge: json["deleteBranchOnMerge"] as? Bool ?? false,
            isAuthoritative: true)
    }

    /// `owner/name` from a pull request URL, for the paths where we have a URL
    /// and no repository read. `https://github.com/o/r/pull/9` → `o/r`.
    public static func repository(fromPullRequestURL url: String) -> String? {
        guard let components = URL(string: url)?.pathComponents else { return nil }
        // ["/", owner, name, "pull", "9"]
        guard components.count >= 3 else { return nil }
        let owner = components[1], name = components[2]
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        return "\(owner)/\(name)"
    }

    /// GraphQL puts errors in a 200 body. A mutation that "succeeded" with an
    /// `errors` array did not succeed, and treating exit code 0 as the answer is
    /// how a resolve that silently did nothing gets reported as done.
    public static func graphQLError(in stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [[String: Any]], !errors.isEmpty else {
            return nil
        }
        let messages = errors.compactMap { $0["message"] as? String }
        return messages.isEmpty ? "GitHub returned an unspecified GraphQL error."
                                : messages.joined(separator: "; ")
    }
}

// MARK: - Running a write

extension GitHubPRGateway {
    /// Run a write verb and classify a failure with the context the spine's
    /// `classify` cannot have.
    ///
    /// The spine's `run` is right for reads and wrong here for one reason: it
    /// throws the `GitHubCLIOutcome` away, and "line is not in the diff" versus
    /// "thread not found" is a distinction that lives in wording only a write
    /// provokes. This keeps every launch inside the gateway — there is still
    /// exactly one place that runs `gh` — while letting the caller say which verb
    /// it was running.
    ///
    /// It also catches the GraphQL trap: a mutation that fails returns HTTP 200
    /// with an `errors` array, so exit code 0 is not evidence that anything
    /// happened.
    public func runWrite(_ arguments: [String], cwd: URL,
                         context: PullRequestActionKind,
                         timeout override: TimeInterval? = nil) async
        -> Result<String, PullRequestRefusal> {
        guard probe.resolvedExecutable() != nil else {
            return .failure(PullRequestRefusal(.ghNotInstalled,
                detail: "No gh binary on this machine's PATH or in the usual install locations."))
        }
        let outcome = await probe.run(arguments, cwd: cwd, timeout: override ?? timeout)
        if outcome.timedOut {
            // A timed-out write is the one outcome we genuinely cannot report on:
            // it may have landed. The detail says so rather than implying nothing
            // happened.
            return .failure(PullRequestRefusal(.ghTimedOut,
                detail: "gh \(arguments.prefix(2).joined(separator: " ")) did not answer in "
                    + "\(Int(override ?? timeout))s. It may or may not have gone through — "
                    + "reload before retrying."))
        }
        guard outcome.status == 0 else {
            return .failure(PullRequestActionClassifier.classify(outcome, context: context))
        }
        if let message = PullRequestActionDecoder.graphQLError(in: outcome.stdout) {
            let synthetic = GitHubCLIOutcome(status: 1, stdout: "", stderr: message)
            return .failure(PullRequestActionClassifier.classify(synthetic, context: context))
        }
        return .success(outcome.stdout)
    }
}
