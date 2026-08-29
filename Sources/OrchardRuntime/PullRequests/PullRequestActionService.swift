import Foundation

/// Everything Orchard does *to* a pull request.
///
/// One service, one worktree. The worktree is constructor state rather than a
/// parameter on every verb for a reason that is not tidiness: it is a fact in the
/// confirmation token, so a plan built in one checkout cannot be spent in
/// another. A stateless service would have to take the worktree twice — once to
/// build the plan and once to act — and the two could disagree.
///
/// ## The shape of a write
///
/// Reads are one step. Writes are one step *unless the write cannot be undone*,
/// and then they are two:
///
/// 1. Ask for a plan. That costs a `gh pr view` and launches nothing that writes.
///    The plan carries a sentence naming the pull request, the method, and the
///    branch's fate, plus a token minted from the state it just read.
/// 2. Act, carrying the token. A token that does not match — because the plan is
///    stale, because the method changed behind the sheet, because somebody
///    handed a plan to a different worktree — stops the write before `gh` runs.
///
/// Merge and close take that road. Everything else is a single call, because a
/// review can be superseded, a thread can be unresolved, and a draft can be
/// marked ready — none of them is a door that locks behind you.
///
/// ## What never happens here
///
/// No verb retries itself. No verb infers a default. `deleteBranch` is `false` in
/// every signature and every initialiser in this file, and the only thing that
/// makes it true is a caller passing `true` because a person ticked a box.
public struct PullRequestActionService: Sendable {

    /// The checkout every verb acts in. `gh` resolves the repository, the host and
    /// the credentials from here.
    public let worktree: URL
    /// The branch to look a pull request up by. `nil` lets `gh` resolve from the
    /// worktree, which is what a detached or unusual checkout needs.
    public let branch: String?
    public let gateway: GitHubPRGateway

    public init(worktree: URL, branch: String? = nil,
                gateway: GitHubPRGateway = GitHubPRGateway()) {
        self.worktree = worktree
        self.branch = branch
        self.gateway = gateway
    }

    public init(worktree: URL, branch: String? = nil,
                probe: any GitHubCLIProbe, timeout: TimeInterval = 20) {
        self.init(worktree: worktree, branch: branch,
                  gateway: GitHubPRGateway(probe: probe, timeout: timeout))
    }

    private var worktreePath: String { worktree.standardizedFileURL.path }

    // MARK: - Reads the writes depend on

    /// The pull request for this worktree's branch.
    ///
    /// Every write that needs a number, a head commit or a state comes through
    /// here, so "read before you act" is not a convention anybody can skip.
    public func detail() async -> Result<PullRequestDetail, PullRequestRefusal> {
        switch await gateway.json(PullRequestActionCommand.view(branch: branch),
                                  cwd: worktree) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let json):
            let repository = (json["url"] as? String)
                .flatMap(PullRequestActionDecoder.repository(fromPullRequestURL:))
                ?? "unknown/unknown"
            guard let detail = PullRequestDecoder.detail(from: json,
                                                         repository: repository) else {
                return .failure(PullRequestRefusal(.noPullRequest,
                    detail: "gh answered without a pull request number for this branch."))
            }
            return .success(detail)
        }
    }

    /// The repository's merge settings.
    ///
    /// Never fails: a read that does not land comes back non-authoritative, which
    /// makes the picker offer all three methods and say it could not tell. The
    /// alternative — assuming the defaults are true — hides a button that works
    /// or offers one that does not.
    public func repositoryPolicy() async -> RepositoryMergePolicy {
        switch await gateway.json(PullRequestActionCommand.repositoryPolicy, cwd: worktree) {
        case .failure:
            return RepositoryMergePolicy(isAuthoritative: false)
        case .success(let json):
            return PullRequestActionDecoder.policy(from: json)
        }
    }

    // MARK: - 1. Submitting a review

    /// Submit a review.
    ///
    /// The empty-body gate fires first, before `gh` is resolved let alone
    /// launched: we already know the answer, and a network round trip to be told
    /// something we could have said ourselves is a round trip that can also fail
    /// for an unrelated reason and confuse the message.
    ///
    /// GitHub's refusal of a self-review is *not* pre-empted here. We do not know
    /// who the viewer is without another call, and guessing wrong would block a
    /// legitimate review. `GitHubPRGateway.classify` already maps GitHub's own
    /// wording to `.cannotReviewOwnPullRequest`, and this verb's job is to let
    /// that reach the user with its headline and remedy intact.
    public func submitReview(verdict: ReviewVerdict, body: String)
        async -> PullRequestActionResult {
        let submission = ReviewSubmission(verdict: verdict, body: body)
        if let refusal = submission.refusal { return .refused(refusal) }

        switch await detail() {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let pr):
            let arguments = PullRequestActionCommand.review(submission, number: pr.ref.number)
            switch await gateway.runWrite(arguments, cwd: worktree, context: .review) {
            case .failure(let refusal):
                return .refused(refusal)
            case .success(let stdout):
                return .succeeded(PullRequestActionReceipt(
                    action: .review, ref: pr.ref,
                    summary: "\(verdict.submitLabel) submitted on "
                        + "\(pr.ref.repository)#\(pr.ref.number).",
                    detail: GitHubPRGateway.firstLine(stdout)))
            }
        }
    }

    // MARK: - 2. Line-anchored review comments

    /// Comment on one line, or one range of lines, of the diff.
    ///
    /// Needs the head commit, so it reads the pull request first — the anchor is
    /// meaningless without the commit it is anchored in, and pinning it to the
    /// head we just read is what stops a comment landing on a line that moved.
    ///
    /// An anchor GitHub rejects because the line is not in the diff arrives as a
    /// 422; `PullRequestActionClassifier` turns it into `.lineNotInDiff`, which
    /// has a headline and a remedy. A raw 422 has neither.
    public func comment(on path: String, line: Int, startLine: Int? = nil,
                        side: DiffSide = .right, body: String)
        async -> PullRequestActionResult {
        let anchor = ReviewCommentAnchor(path: path, line: line, startLine: startLine,
                                         side: side, body: body)
        if let refusal = anchor.refusal { return .refused(refusal) }

        switch await detail() {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let pr):
            guard let commitId = pr.headRefOid, !commitId.isEmpty else {
                return .refused(PullRequestRefusal(.apiError,
                    detail: "gh did not report a head commit, and a line comment must "
                        + "be anchored to one."))
            }
            let arguments = PullRequestActionCommand.lineComment(
                anchor, repository: pr.ref.repository, number: pr.ref.number,
                commitId: commitId)
            switch await gateway.runWrite(arguments, cwd: worktree, context: .lineComment) {
            case .failure(let refusal):
                return .refused(refusal)
            case .success(let stdout):
                let where_ = anchor.startLine.map { "\(path):\($0)-\(line)" } ?? "\(path):\(line)"
                return .succeeded(PullRequestActionReceipt(
                    action: .lineComment, ref: pr.ref,
                    summary: "Commented on \(where_) in "
                        + "\(pr.ref.repository)#\(pr.ref.number).",
                    detail: GitHubPRGateway.firstLine(stdout)))
            }
        }
    }

    // MARK: - 3. Threads

    /// Reply into an existing review thread.
    ///
    /// Addressed by GraphQL node id, which is global — but the call still runs in
    /// the worktree so `gh` picks the right host and credentials.
    public func reply(toThread threadId: String, body: String)
        async -> PullRequestActionResult {
        if let refusal = Self.threadPrecondition(threadId) { return .refused(refusal) }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .refused(PullRequestRefusal(.emptyReviewBody,
                detail: "A reply with no text says nothing."))
        }
        return await threadAction(.threadReply, threadId: threadId,
                                  arguments: PullRequestActionCommand.replyToThread(
                                      threadId, body: text),
                                  summary: "Replied to review thread \(threadId).")
    }

    public func resolve(thread threadId: String) async -> PullRequestActionResult {
        if let refusal = Self.threadPrecondition(threadId) { return .refused(refusal) }
        return await threadAction(.threadResolve, threadId: threadId,
                                  arguments: PullRequestActionCommand.resolveThread(threadId),
                                  summary: "Resolved review thread \(threadId).")
    }

    public func unresolve(thread threadId: String) async -> PullRequestActionResult {
        if let refusal = Self.threadPrecondition(threadId) { return .refused(refusal) }
        return await threadAction(.threadUnresolve, threadId: threadId,
                                  arguments: PullRequestActionCommand.unresolveThread(threadId),
                                  summary: "Reopened review thread \(threadId).")
    }

    /// An id we can see is not an id is refused here, not by GitHub. Sending an
    /// empty string and reading back a GraphQL parse error is a worse message
    /// than the one we can write ourselves.
    private static func threadPrecondition(_ threadId: String) -> PullRequestRefusal? {
        guard threadId.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return PullRequestRefusal(.threadNotFound, detail: "No thread id was given.")
    }

    /// Thread verbs share everything but their mutation, and they deliberately do
    /// **not** read the pull request first: a thread id is global, the mutation
    /// fails cleanly on an id GitHub does not know, and a read would cost a round
    /// trip to learn something the mutation already tells us.
    private func threadAction(_ kind: PullRequestActionKind, threadId: String,
                              arguments: [String], summary: String)
        async -> PullRequestActionResult {
        switch await gateway.runWrite(arguments, cwd: worktree, context: kind) {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let stdout):
            // No pull request was read, so the ref names the thread's repository
            // only as far as we know it. Honest beats decorative.
            let ref = PullRequestRef(repository: "", number: 0, url: "")
            return .succeeded(PullRequestActionReceipt(
                action: kind, ref: ref, summary: summary,
                detail: GitHubPRGateway.firstLine(stdout)))
        }
    }

    // MARK: - 4. Merging

    /// Read the pull request and work out whether, and how, it could be merged.
    ///
    /// This is the only way to get a token `merge` will accept, which is how the
    /// read stops being optional. It launches `gh pr view` and `gh repo view` and
    /// nothing else — no write verb runs while a plan is being built.
    ///
    /// `deleteBranch` defaults to `false` here, in `MergePlan.init`, in the CLI
    /// and in the sheet. Four places, one default, and it is the safe one.
    public func mergePlan(method: MergeMethod,
                          deleteBranch: Bool = false) async -> Result<MergePlan, PullRequestRefusal> {
        switch await mergeContext() {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let context):
            return .success(MergePlan.make(context: context, method: method,
                                           deleteBranch: deleteBranch,
                                           worktreePath: worktreePath))
        }
    }

    /// The two readings a plan is derived from, taken once.
    ///
    /// The merge sheet takes this on open and then derives a plan locally for
    /// every method and every tick of the delete-branch box. Nothing about that
    /// is a cache with a lifetime: it is one reading, and the sheet's own
    /// confirmation sentence says which pull request state it was taken against.
    public func mergeContext() async -> Result<MergeContext, PullRequestRefusal> {
        switch await detail() {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let pr):
            return .success(MergeContext(detail: pr, policy: await repositoryPolicy()))
        }
    }

    /// Derive a plan from a reading this caller already has, without touching the
    /// network. The worktree comes from the service, so a plan still cannot be
    /// built for one checkout and spent in another.
    public func plan(from context: MergeContext, method: MergeMethod,
                     deleteBranch: Bool = false) -> MergePlan {
        MergePlan.make(context: context, method: method, deleteBranch: deleteBranch,
                       worktreePath: worktreePath)
    }

    /// Merge, having been shown the sentence.
    ///
    /// Three gates, in this order, and `gh pr merge` runs only past all three:
    ///
    /// 1. **The token.** Missing or stale, and nothing is launched. The result
    ///    carries the confirmation that would have to be shown, so a caller that
    ///    forgot gets the sentence rather than an error code.
    /// 2. **Mergeability still computing.** Its own result case. Not a refusal —
    ///    a refusal invites forcing — and emphatically not permission.
    /// 3. **A named refusal from the plan.** Closed, conflicting, method disabled.
    public func merge(plan: MergePlan, confirmation: String) async -> PullRequestActionResult {
        guard confirmation == plan.confirmation.token else {
            return .needsConfirmation(plan.confirmation)
        }
        switch plan.readiness {
        case .refused(let refusal):
            return .refused(refusal)
        case .stillComputing:
            return .mergeabilityUnknown(MergeabilityPending(
                ref: plan.ref,
                detail: "GitHub has not finished computing whether "
                    + "\(plan.headRefName) merges into \(plan.baseRefName). "
                    + "Nothing was sent.",
                remedy: "Ask again in a moment — the answer usually arrives in seconds."))
        case .ready:
            break
        }

        switch await gateway.runWrite(PullRequestActionCommand.merge(plan),
                                      cwd: worktree, context: .merge) {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let stdout):
            var summary = "Merged \(plan.ref.repository)#\(plan.ref.number) into "
            summary += "\(plan.baseRefName) by \(plan.method.sentenceFragment)."
            if plan.deleteBranch { summary += " Branch \(plan.headRefName) deleted." }
            return .succeeded(PullRequestActionReceipt(
                action: .merge, ref: plan.ref, summary: summary,
                detail: GitHubPRGateway.firstLine(stdout)))
        }
    }

    // MARK: - 5. State

    /// Read the pull request and work out what closing it would mean.
    ///
    /// The same two-step road as merge. Closing is reversible in the sense that
    /// `reopen` exists, and irreversible in the sense that everybody watching the
    /// pull request is told it is over.
    public func closePlan(openThreadCount: Int? = nil)
        async -> Result<ClosePlan, PullRequestRefusal> {
        switch await detail() {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let pr):
            guard pr.state == .open else {
                return .failure(PullRequestRefusal(.pullRequestNotOpen,
                    detail: "\(pr.ref.repository)#\(pr.ref.number) is already "
                        + "\(pr.state.label.lowercased())."))
            }
            return .success(ClosePlan(ref: pr.ref, title: pr.title, state: pr.state,
                                      headRefName: pr.headRefName,
                                      openThreadCount: openThreadCount,
                                      worktreePath: worktreePath))
        }
    }

    public func close(plan: ClosePlan, confirmation: String) async -> PullRequestActionResult {
        guard confirmation == plan.confirmation.token else {
            return .needsConfirmation(plan.confirmation)
        }
        switch await gateway.runWrite(PullRequestActionCommand.close(plan),
                                      cwd: worktree, context: .close) {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let stdout):
            return .succeeded(PullRequestActionReceipt(
                action: .close, ref: plan.ref,
                summary: "Closed \(plan.ref.repository)#\(plan.ref.number) without merging. "
                    + "Branch \(plan.headRefName) kept.",
                detail: GitHubPRGateway.firstLine(stdout)))
        }
    }

    /// Reopen. One step: it un-does a close, and nothing is lost by doing it.
    public func reopen() async -> PullRequestActionResult {
        switch await detail() {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let pr):
            guard pr.state == .closed else {
                return .refused(PullRequestRefusal(.pullRequestNotOpen,
                    detail: pr.state == .merged
                        ? "\(pr.ref.repository)#\(pr.ref.number) was merged. A merged pull "
                            + "request cannot be reopened."
                        : "\(pr.ref.repository)#\(pr.ref.number) is already open."))
            }
            switch await gateway.runWrite(
                PullRequestActionCommand.reopen(number: pr.ref.number),
                cwd: worktree, context: .reopen) {
            case .failure(let refusal):
                return .refused(refusal)
            case .success(let stdout):
                return .succeeded(PullRequestActionReceipt(
                    action: .reopen, ref: pr.ref,
                    summary: "Reopened \(pr.ref.repository)#\(pr.ref.number).",
                    detail: GitHubPRGateway.firstLine(stdout)))
            }
        }
    }

    /// Convert to a draft, or mark ready for review.
    ///
    /// One step, and the read in front of it is not ceremony: `gh pr ready` on a
    /// pull request that is already in the state asked for exits zero and does
    /// nothing, which would have us report a change that did not happen.
    public func setDraft(_ isDraft: Bool) async -> PullRequestActionResult {
        let kind: PullRequestActionKind = isDraft ? .markDraft : .markReady
        switch await detail() {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let pr):
            guard pr.state == .open else {
                return .refused(PullRequestRefusal(.pullRequestNotOpen,
                    detail: "\(pr.ref.repository)#\(pr.ref.number) is "
                        + "\(pr.state.label.lowercased())."))
            }
            guard pr.isDraft != isDraft else {
                return .succeeded(PullRequestActionReceipt(
                    action: kind, ref: pr.ref,
                    summary: isDraft
                        ? "\(pr.ref.repository)#\(pr.ref.number) is already a draft."
                        : "\(pr.ref.repository)#\(pr.ref.number) is already ready for review.",
                    detail: "Nothing was sent."))
            }
            switch await gateway.runWrite(
                PullRequestActionCommand.setDraft(isDraft, number: pr.ref.number),
                cwd: worktree, context: kind) {
            case .failure(let refusal):
                return .refused(refusal)
            case .success(let stdout):
                return .succeeded(PullRequestActionReceipt(
                    action: kind, ref: pr.ref,
                    summary: isDraft
                        ? "Converted \(pr.ref.repository)#\(pr.ref.number) to a draft."
                        : "Marked \(pr.ref.repository)#\(pr.ref.number) ready for review.",
                    detail: GitHubPRGateway.firstLine(stdout)))
            }
        }
    }
}
