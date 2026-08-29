import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// T94 — acting on a pull request.
///
/// Every test runs against `FixtureGitHubCLI`. Nothing here launches `gh`, and
/// nothing here can reach GitHub: the probe is a dictionary with an invocation
/// log. That log is the point of most of these assertions — the interesting
/// claim is usually not "it refused" but **"it refused without launching
/// anything"**, and only `probe.invocations` can settle that.
final class PullRequestActionTests: XCTestCase {

    private var probe: FixtureGitHubCLI!
    private let worktree = URL(fileURLWithPath: "/tmp/orchard-t94")

    override func setUp() {
        super.setUp()
        probe = FixtureGitHubCLI()
        probe.setExecutable("/fixture/gh")
    }

    private func service(branch: String? = "topic") -> PullRequestActionService {
        PullRequestActionService(worktree: worktree, branch: branch, probe: probe, timeout: 5)
    }

    // MARK: - Fixtures

    /// A pull request as `gh pr view --json` reports one. Every state the merge
    /// path branches on is a parameter, because every one of them changes what
    /// may happen.
    private func prJSON(number: Int = 42, state: String = "OPEN",
                        mergeable: String = "MERGEABLE", isDraft: Bool = false,
                        mergeStateStatus: String = "CLEAN",
                        headOid: String = "abc1234") -> String {
        """
        {"number":\(number),"title":"Act on a pull request",
         "body":"","url":"https://github.com/hulryung/damson-ide/pull/\(number)",
         "state":"\(state)","isDraft":\(isDraft),
         "author":{"login":"hulryung"},
         "baseRefName":"main","headRefName":"topic","headRefOid":"\(headOid)",
         "reviewDecision":"REVIEW_REQUIRED","mergeable":"\(mergeable)",
         "mergeStateStatus":"\(mergeStateStatus)",
         "additions":10,"deletions":2,"changedFiles":3,
         "createdAt":"2026-08-29T04:00:00Z","updatedAt":"2026-08-29T04:30:00Z"}
        """
    }

    private func policyJSON(merge: Bool = true, squash: Bool = true, rebase: Bool = true,
                            deleteOnMerge: Bool = false) -> String {
        """
        {"nameWithOwner":"hulryung/damson-ide","mergeCommitAllowed":\(merge),
         "squashMergeAllowed":\(squash),"rebaseMergeAllowed":\(rebase),
         "deleteBranchOnMerge":\(deleteOnMerge)}
        """
    }

    private func ok(_ stdout: String = "") -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: 0, stdout: stdout, executablePath: "/fixture/gh")
    }

    private func failed(_ stderr: String, status: Int32 = 1) -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: status, stderr: stderr, executablePath: "/fixture/gh")
    }

    private func scriptRead(_ pr: String? = nil, policy: String? = nil) {
        probe.script(["pr", "view"], ok(pr ?? prJSON()))
        probe.script(["repo", "view"], ok(policy ?? policyJSON()))
    }

    /// Every `gh` argument list the probe was asked to run, flattened, so a test
    /// can ask "was a merge ever launched" without caring about argument order.
    private func launched(_ verb: String...) -> Bool {
        probe.invocations.contains { $0.starts(with: verb) }
    }

    // MARK: - 1. Submitting a review

    /// The load-bearing assertion for the empty-body rule: not merely that it
    /// refuses, but that it refuses having launched **nothing**. A round trip to
    /// be told something we already knew is a round trip that can also fail for
    /// an unrelated reason and confuse the message.
    func testEmptyBodyIsRefusedBeforeGhIsLaunched() async {
        for verdict in [ReviewVerdict.requestChanges, .comment] {
            probe = FixtureGitHubCLI()
            probe.setExecutable("/fixture/gh")
            let result = await service().submitReview(verdict: verdict, body: "   \n  ")
            XCTAssertEqual(result.refusal?.reason, .emptyReviewBody, "\(verdict)")
            XCTAssertTrue(probe.invocations.isEmpty,
                          "\(verdict): gh must not run to learn the body is blank")
        }
    }

    /// Approve is the one verdict GitHub takes bare, so an empty body is not a
    /// refusal there — and the read still has to happen to learn the number.
    func testApproveMayGoInWithoutABody() async {
        scriptRead()
        probe.script(["pr", "review"], ok("Approved pull request #42"))
        let result = await service().submitReview(verdict: .approve, body: "")
        XCTAssertTrue(result.didSucceed, result.headline)
        XCTAssertTrue(launched("pr", "review"))
    }

    func testReviewArgvCarriesTheFlagAndTheTrimmedBody() async {
        scriptRead()
        probe.script(["pr", "review"], ok(""))
        _ = await service().submitReview(verdict: .requestChanges, body: "  needs a test\n")
        let call = probe.invocations.first { $0.starts(with: ["pr", "review"]) }
        XCTAssertEqual(call, ["pr", "review", "42", "--request-changes",
                              "--body", "needs a test"])
    }

    /// GitHub refuses a self-review and we do not pre-empt that guess. What we
    /// must do is let its own wording arrive with a headline and a remedy on it
    /// rather than as a stderr dump.
    func testSelfReviewRefusalReachesTheUserIntact() async {
        scriptRead()
        probe.script(["pr", "review"],
                     failed("GraphQL: Can not approve your own pull request (addPullRequestReview)"))
        let result = await service().submitReview(verdict: .approve, body: "")
        let refusal = try? XCTUnwrap(result.refusal)
        XCTAssertEqual(refusal?.reason, .cannotReviewOwnPullRequest)
        XCTAssertEqual(refusal?.code, "cannot_review_own_pull_request")
        XCTAssertFalse(refusal?.headline.isEmpty ?? true)
        XCTAssertFalse(refusal?.remedy.isEmpty ?? true)
        XCTAssertTrue(refusal?.detail.contains("Can not approve your own") ?? false,
                      "gh's own sentence must survive the friendly headline")
    }

    func testAReviewOnAWorktreeWithNoPullRequestIsNamed() async {
        probe.script(["pr", "view"], failed("no pull requests found for branch \"topic\""))
        let result = await service().submitReview(verdict: .comment, body: "hi")
        XCTAssertEqual(result.refusal?.reason, .noPullRequest)
        XCTAssertFalse(launched("pr", "review"), "a review needs a pull request to review")
    }

    func testMissingGhIsNamedWithoutLaunchingAnything() async {
        probe.setExecutable(nil)
        let result = await service().submitReview(verdict: .comment, body: "hi")
        XCTAssertEqual(result.refusal?.reason, .ghNotInstalled)
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    // MARK: - 2. Line-anchored comments

    func testLineCommentPostsToTheCommentsEndpointAnchoredToTheHeadCommit() async {
        scriptRead()
        probe.script(["api", "--method"], ok("{\"id\":1}"))
        let result = await service().comment(on: "Sources/A.swift", line: 12,
                                             body: "why this cast?")
        XCTAssertTrue(result.didSucceed, result.headline)
        let call = probe.invocations.first { $0.first == "api" }
        XCTAssertEqual(call, [
            "api", "--method", "POST",
            "/repos/hulryung/damson-ide/pulls/42/comments",
            "-f", "commit_id=abc1234",
            "-f", "path=Sources/A.swift",
            "-F", "line=12",
            "-f", "side=RIGHT",
            "-f", "body=why this cast?",
        ])
    }

    func testAMultiLineAnchorCarriesStartLineAndStartSide() async {
        scriptRead()
        probe.script(["api", "--method"], ok("{\"id\":1}"))
        _ = await service().comment(on: "Sources/A.swift", line: 20, startLine: 16,
                                    side: .left, body: "this whole block")
        let call = probe.invocations.first { $0.first == "api" } ?? []
        XCTAssertTrue(call.contains("start_line=16"))
        XCTAssertTrue(call.contains("start_side=LEFT"))
        XCTAssertTrue(call.contains("side=LEFT"))
    }

    /// The 422 GitHub sends for an anchor off the diff must arrive as a named
    /// dead end with a remedy, not as a status code.
    func testAnAnchorOffTheDiffBecomesLineNotInDiff() async {
        scriptRead()
        probe.script(["api", "--method"],
                     failed("gh: Validation Failed (HTTP 422)\n"
                        + "pull_request_review_thread.line must be part of the diff"))
        let result = await service().comment(on: "Sources/A.swift", line: 9999,
                                             body: "here")
        let refusal = try? XCTUnwrap(result.refusal)
        XCTAssertEqual(refusal?.reason, .lineNotInDiff)
        XCTAssertNotEqual(refusal?.reason, .apiError, "a raw 422 has no remedy")
        XCTAssertFalse(refusal?.remedy.isEmpty ?? true)
    }

    func testLocalAnchorMistakesAreRefusedBeforeGhIsLaunched() async {
        let cases: [(String, Int, Int?, String, PullRequestRefusalReason)] = [
            ("Sources/A.swift", 12, nil, "   ", .emptyReviewBody),
            ("", 12, nil, "text", .lineNotInDiff),
            ("Sources/A.swift", 0, nil, "text", .lineNotInDiff),
            ("Sources/A.swift", 4, 9, "text", .lineNotInDiff),
        ]
        for (path, line, start, body, expected) in cases {
            probe = FixtureGitHubCLI()
            probe.setExecutable("/fixture/gh")
            let result = await service().comment(on: path, line: line, startLine: start,
                                                 body: body)
            XCTAssertEqual(result.refusal?.reason, expected, "\(path):\(line)")
            XCTAssertTrue(probe.invocations.isEmpty,
                          "\(path):\(line) — nothing should have been launched")
        }
    }

    // MARK: - 3. Threads

    func testThreadVerbsUseTheRightGraphQLMutation() async {
        let expectations: [(String, String)] = [
            ("resolve", "resolveReviewThread"),
            ("unresolve", "unresolveReviewThread"),
            ("reply", "addPullRequestReviewThreadReply"),
        ]
        for (verb, mutation) in expectations {
            probe = FixtureGitHubCLI()
            probe.setExecutable("/fixture/gh")
            probe.script(["api", "graphql"], ok("{\"data\":{}}"))
            let subject = service()
            let result: PullRequestActionResult
            switch verb {
            case "resolve": result = await subject.resolve(thread: "PRRT_abc")
            case "unresolve": result = await subject.unresolve(thread: "PRRT_abc")
            default: result = await subject.reply(toThread: "PRRT_abc", body: "ack")
            }
            XCTAssertTrue(result.didSucceed, "\(verb): \(result.headline)")
            let call = probe.invocations.first { $0.starts(with: ["api", "graphql"]) } ?? []
            XCTAssertTrue(call.joined(separator: " ").contains(mutation), verb)
            XCTAssertTrue(call.contains("threadId=PRRT_abc"), verb)
        }
    }

    func testAThreadGitHubDoesNotKnowIsNamedNotGuessed() async {
        probe.script(["api", "graphql"],
                     failed("GraphQL: Could not resolve to a node with the global id of 'PRRT_x'"))
        let result = await service().resolve(thread: "PRRT_x")
        XCTAssertEqual(result.refusal?.reason, .threadNotFound)
    }

    /// GraphQL puts mutation failures in a 200 body. Exit code 0 is not evidence
    /// that anything happened, and reporting one as done is how a resolve that
    /// silently did nothing gets reported as a resolve.
    func testAGraphQLErrorInsideATwoHundredIsStillAFailure() async {
        probe.script(["api", "graphql"], ok("""
        {"data":{"resolveReviewThread":null},
         "errors":[{"message":"Could not resolve to a node with the global id of 'x'"}]}
        """))
        let result = await service().resolve(thread: "PRRT_x")
        XCTAssertFalse(result.didSucceed, "a 200 with errors is not a success")
        XCTAssertEqual(result.refusal?.reason, .threadNotFound)
    }

    func testAnEmptyThreadIdIsRefusedBeforeGhIsLaunched() async {
        for result in [await service().resolve(thread: "  "),
                       await service().unresolve(thread: ""),
                       await service().reply(toThread: "", body: "hi")] {
            XCTAssertEqual(result.refusal?.reason, .threadNotFound)
        }
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    func testAnEmptyReplyIsRefusedBeforeGhIsLaunched() async {
        let result = await service().reply(toThread: "PRRT_abc", body: "\n  \t")
        XCTAssertEqual(result.refusal?.reason, .emptyReviewBody)
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    // MARK: - 4. Merging

    func testMergePlanReadsBeforeItDecidesAndLaunchesNoWrite() async {
        scriptRead()
        guard case .success(let plan) = await service().mergePlan(method: .squash) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.readiness, .ready)
        XCTAssertEqual(plan.ref.number, 42)
        XCTAssertEqual(plan.ref.repository, "hulryung/damson-ide")
        XCTAssertTrue(launched("pr", "view"))
        XCTAssertFalse(launched("pr", "merge"), "building a plan must never merge")
    }

    /// The rule the whole task hangs on. `unknown` is GitHub still computing. It
    /// is not permission, and the outcome it produces is its own case — not a
    /// refusal, which would teach people to force past it.
    func testUnknownMergeabilityIsNeitherMergeableNorARefusal() async {
        scriptRead(prJSON(mergeable: "UNKNOWN"))
        guard case .success(let plan) = await service().mergePlan(method: .merge) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.readiness, .stillComputing)
        XCTAssertFalse(plan.readiness.isReady)

        let result = await service().merge(plan: plan, confirmation: plan.confirmation.token)
        guard case .mergeabilityUnknown(let pending) = result else {
            return XCTFail("expected the pending case, got \(result)")
        }
        XCTAssertNil(result.refusal, "still computing is not a refusal")
        XCTAssertFalse(pending.remedy.isEmpty)
        XCTAssertFalse(launched("pr", "merge"), "nothing may be sent while GitHub decides")
    }

    func testConflictsAndClosedAndDisabledMethodsAreEachNamed() async {
        let cases: [(String, String, String, PullRequestRefusalReason)] = [
            (prJSON(mergeable: "CONFLICTING"), policyJSON(), "merge", .notMergeable),
            (prJSON(state: "CLOSED"), policyJSON(), "merge", .pullRequestNotOpen),
            (prJSON(state: "MERGED"), policyJSON(), "merge", .pullRequestNotOpen),
            (prJSON(), policyJSON(squash: false), "squash", .mergeMethodUnavailable),
        ]
        for (pr, policy, rawMethod, expected) in cases {
            probe = FixtureGitHubCLI()
            probe.setExecutable("/fixture/gh")
            scriptRead(pr, policy: policy)
            let method = MergeMethod(rawValue: rawMethod)!
            guard case .success(let plan) = await service().mergePlan(method: method) else {
                return XCTFail("expected a plan for \(expected)")
            }
            guard case .refused(let refusal) = plan.readiness else {
                return XCTFail("expected \(expected), got \(plan.readiness)")
            }
            XCTAssertEqual(refusal.reason, expected)

            let result = await service().merge(plan: plan,
                                               confirmation: plan.confirmation.token)
            XCTAssertEqual(result.refusal?.reason, expected)
            XCTAssertFalse(launched("pr", "merge"), "\(expected) must not reach gh pr merge")
        }
    }

    /// A closed pull request outranks a mergeability GitHub has not computed:
    /// "we don't know yet" must never sit in front of "this is already over".
    func testACertainRefusalOutranksAPendingMergeability() async {
        scriptRead(prJSON(state: "MERGED", mergeable: "UNKNOWN"))
        guard case .success(let plan) = await service().mergePlan(method: .merge) else {
            return XCTFail("expected a plan")
        }
        guard case .refused(let refusal) = plan.readiness else {
            return XCTFail("expected a refusal, got \(plan.readiness)")
        }
        XCTAssertEqual(refusal.reason, .pullRequestNotOpen)
    }

    // MARK: - Merge: the confirmation

    func testMergeWithoutTheTokenLaunchesNothingAndHandsBackTheSentence() async {
        scriptRead()
        guard case .success(let plan) = await service().mergePlan(method: .squash) else {
            return XCTFail("expected a plan")
        }
        for wrong in ["", "yes", "true", plan.confirmation.token + "x"] {
            let result = await service().merge(plan: plan, confirmation: wrong)
            guard case .needsConfirmation(let confirmation) = result else {
                return XCTFail("expected needsConfirmation for '\(wrong)', got \(result)")
            }
            XCTAssertEqual(confirmation.token, plan.confirmation.token)
            XCTAssertFalse(confirmation.sentence.isEmpty)
        }
        XCTAssertFalse(launched("pr", "merge"), "an unconfirmed merge must launch nothing")
    }

    /// The token is minted from live state, so a plan that no longer describes
    /// reality cannot be spent. Flipping the method behind the sheet is the
    /// cheapest way to prove it.
    func testATokenIsSpecificToTheMergeItNames() async {
        scriptRead()
        let subject = service()
        guard case .success(let squash) = await subject.mergePlan(method: .squash),
              case .success(let rebase) = await subject.mergePlan(method: .rebase),
              case .success(let deleting) = await subject.mergePlan(method: .squash,
                                                                    deleteBranch: true) else {
            return XCTFail("expected three plans")
        }
        XCTAssertNotEqual(squash.confirmation.token, rebase.confirmation.token,
                          "the method is part of what was agreed to")
        XCTAssertNotEqual(squash.confirmation.token, deleting.confirmation.token,
                          "the branch's fate is part of what was agreed to")

        // The head commit is in the token too, so a push under the sheet
        // invalidates what was agreed to.
        probe.script(["pr", "view"], ok(prJSON(headOid: "def5678")))
        guard case .success(let moved) = await subject.mergePlan(method: .squash) else {
            return XCTFail("expected a plan")
        }
        XCTAssertNotEqual(squash.confirmation.token, moved.confirmation.token,
                          "the commit being merged is part of what was agreed to")

        // And so is the checkout: a plan minted elsewhere cannot be spent here.
        let elsewhere = PullRequestActionService(
            worktree: URL(fileURLWithPath: "/tmp/some-other-worktree"),
            branch: "topic", probe: probe, timeout: 5)
        guard case .success(let foreign) = await elsewhere.mergePlan(method: .squash) else {
            return XCTFail("expected a plan")
        }
        XCTAssertNotEqual(moved.confirmation.token, foreign.confirmation.token)
        let result = await subject.merge(plan: moved,
                                         confirmation: foreign.confirmation.token)
        guard case .needsConfirmation = result else {
            return XCTFail("a foreign token must not spend this plan, got \(result)")
        }
        XCTAssertFalse(launched("pr", "merge"))
    }

    /// The sentence has to name the three facts somebody who merged the wrong
    /// thing wishes they had read: which pull request, which method, and whether
    /// the branch survives.
    func testTheConfirmationSentenceNamesThePullRequestMethodAndBranch() async {
        scriptRead()
        guard case .success(let kept) = await service().mergePlan(method: .squash),
              case .success(let deleted) = await service().mergePlan(method: .squash,
                                                                     deleteBranch: true) else {
            return XCTFail("expected plans")
        }
        for sentence in [kept.sentence, deleted.sentence] {
            XCTAssertTrue(sentence.contains("hulryung/damson-ide#42"), sentence)
            XCTAssertTrue(sentence.contains("Act on a pull request"), sentence)
            XCTAssertTrue(sentence.contains("squashing"), sentence)
            XCTAssertTrue(sentence.contains("topic"), sentence)
        }
        XCTAssertTrue(kept.sentence.contains("will be kept"), kept.sentence)
        XCTAssertTrue(deleted.sentence.contains("will be deleted"), deleted.sentence)
    }

    // MARK: - Merge: delete-branch

    /// Four places default this, and all four default it off. This asserts the
    /// one that reaches GitHub: the argv.
    func testDeleteBranchIsOffUnlessAskedForAndOnlyThenReachesGh() async {
        scriptRead()
        probe.script(["pr", "merge"], ok("Merged pull request #42"))
        guard case .success(let plan) = await service().mergePlan(method: .squash) else {
            return XCTFail("expected a plan")
        }
        XCTAssertFalse(plan.deleteBranch, "the default is off")
        _ = await service().merge(plan: plan, confirmation: plan.confirmation.token)
        let call = probe.invocations.first { $0.starts(with: ["pr", "merge"]) }
        XCTAssertEqual(call, ["pr", "merge", "42", "--squash"])
        XCTAssertFalse(call?.contains("--delete-branch") ?? true)

        probe = FixtureGitHubCLI()
        probe.setExecutable("/fixture/gh")
        scriptRead()
        probe.script(["pr", "merge"], ok("Merged pull request #42"))
        guard case .success(let ticked) = await service().mergePlan(method: .squash,
                                                                    deleteBranch: true) else {
            return XCTFail("expected a plan")
        }
        _ = await service().merge(plan: ticked, confirmation: ticked.confirmation.token)
        let tickedCall = probe.invocations.first { $0.starts(with: ["pr", "merge"]) }
        XCTAssertEqual(tickedCall, ["pr", "merge", "42", "--squash", "--delete-branch"])
    }

    func testASuccessfulMergeReportsWhatItDid() async {
        scriptRead()
        probe.script(["pr", "merge"], ok("Merged pull request #42 (Act on a pull request)"))
        guard case .success(let plan) = await service().mergePlan(method: .squash) else {
            return XCTFail("expected a plan")
        }
        let result = await service().merge(plan: plan, confirmation: plan.confirmation.token)
        let receipt = try? XCTUnwrap(result.receipt)
        XCTAssertEqual(receipt?.action, .merge)
        XCTAssertTrue(receipt?.summary.contains("hulryung/damson-ide#42") ?? false)
        XCTAssertTrue(receipt?.summary.contains("main") ?? false)
    }

    // MARK: - Merge: repository policy

    func testThePickerOffersOnlyWhatTheRepositoryAllows() async {
        scriptRead(policy: policyJSON(merge: false, squash: true, rebase: false))
        guard case .success(let plan) = await service().mergePlan(method: .squash) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.policy.methods, [.squash])
        XCTAssertTrue(plan.policy.isAuthoritative)
    }

    /// An unreadable settings read is not a guess in either direction: every
    /// method is offered and the plan says out loud that we could not tell.
    func testUnreadableSettingsOfferEverythingAndSaySo() async {
        probe.script(["pr", "view"], ok(prJSON()))
        probe.script(["repo", "view"], failed("HTTP 403: Resource not accessible"))
        guard case .success(let plan) = await service().mergePlan(method: .rebase) else {
            return XCTFail("expected a plan")
        }
        XCTAssertFalse(plan.policy.isAuthoritative)
        XCTAssertEqual(plan.policy.methods, MergeMethod.allCases)
        XCTAssertEqual(plan.readiness, .ready, "we could not tell, so we do not block")
        XCTAssertTrue(plan.warnings.contains { $0.contains("could not be read") },
                      "warnings: \(plan.warnings)")
    }

    func testARepositoryThatDeletesBranchesOnMergeIsCalledOut() async {
        scriptRead(policy: policyJSON(deleteOnMerge: true))
        guard case .success(let plan) = await service().mergePlan(method: .merge) else {
            return XCTFail("expected a plan")
        }
        XCTAssertFalse(plan.deleteBranch, "their setting never turns our tick on")
        XCTAssertTrue(plan.warnings.contains { $0.contains("deletes head branches") },
                      "warnings: \(plan.warnings)")
    }

    func testABlockedOrDraftMergeIsWarnedAboutRatherThanInvented() async {
        scriptRead(prJSON(isDraft: true, mergeStateStatus: "BLOCKED"))
        guard case .success(let plan) = await service().mergePlan(method: .merge) else {
            return XCTFail("expected a plan")
        }
        // We do not invent a refusal GitHub might not make; we say what it said.
        XCTAssertEqual(plan.readiness, .ready)
        XCTAssertTrue(plan.warnings.contains { $0.contains("draft") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("blocked") })
    }

    func testGitHubsOwnMergeRefusalsAreNamed() async {
        let cases: [(String, PullRequestRefusalReason)] = [
            ("Pull request is not mergeable: the base branch was modified", .notMergeable),
            ("GraphQL: Squash merges are not allowed on this repository", .mergeMethodUnavailable),
            ("HTTP 403: Resource not accessible by integration", .insufficientPermission),
            ("gh: Not Found (HTTP 404)", .insufficientPermission),
            ("GraphQL: Pull request is already merged", .pullRequestNotOpen),
        ]
        for (stderr, expected) in cases {
            probe = FixtureGitHubCLI()
            probe.setExecutable("/fixture/gh")
            scriptRead()
            probe.script(["pr", "merge"], failed(stderr))
            guard case .success(let plan) = await service().mergePlan(method: .merge) else {
                return XCTFail("expected a plan")
            }
            let result = await service().merge(plan: plan,
                                               confirmation: plan.confirmation.token)
            XCTAssertEqual(result.refusal?.reason, expected, stderr)
        }
    }

    /// A write that timed out may have landed. The refusal has to say so rather
    /// than imply nothing happened.
    func testATimedOutWriteSaysItMayHaveLanded() async {
        scriptRead()
        probe.script(["pr", "merge"], GitHubCLIOutcome(status: nil, timedOut: true))
        guard case .success(let plan) = await service().mergePlan(method: .merge) else {
            return XCTFail("expected a plan")
        }
        let result = await service().merge(plan: plan, confirmation: plan.confirmation.token)
        XCTAssertEqual(result.refusal?.reason, .ghTimedOut)
        XCTAssertTrue(result.refusal?.detail.contains("may or may not") ?? false,
                      "detail: \(result.refusal?.detail ?? "")")
    }

    // MARK: - 5. State

    func testCloseTakesTheSameTwoStepRoadAsMerge() async {
        scriptRead()
        probe.script(["pr", "close"], ok("Closed pull request #42"))
        guard case .success(let plan) = await service().closePlan() else {
            return XCTFail("expected a plan")
        }
        XCTAssertTrue(plan.sentence.contains("hulryung/damson-ide#42"))
        XCTAssertTrue(plan.sentence.contains("without merging"))
        XCTAssertTrue(plan.sentence.contains("topic"), "the branch's fate is named")

        let unconfirmed = await service().close(plan: plan, confirmation: "yes")
        guard case .needsConfirmation = unconfirmed else {
            return XCTFail("expected needsConfirmation, got \(unconfirmed)")
        }
        XCTAssertFalse(launched("pr", "close"))

        let confirmed = await service().close(plan: plan, confirmation: plan.confirmation.token)
        XCTAssertTrue(confirmed.didSucceed, confirmed.headline)
        XCTAssertEqual(probe.invocations.first { $0.starts(with: ["pr", "close"]) },
                       ["pr", "close", "42"])
    }

    /// Closing does not offer to delete the branch. Closing is already the
    /// destructive half; deleting the branch as well is a second decision, and it
    /// is not one this verb makes.
    func testCloseNeverDeletesTheBranch() async {
        scriptRead()
        probe.script(["pr", "close"], ok(""))
        guard case .success(let plan) = await service().closePlan() else {
            return XCTFail("expected a plan")
        }
        _ = await service().close(plan: plan, confirmation: plan.confirmation.token)
        let call = probe.invocations.first { $0.starts(with: ["pr", "close"]) } ?? []
        XCTAssertFalse(call.contains("--delete-branch"))
        XCTAssertTrue(plan.sentence.contains("will be kept"))
    }

    func testClosingSomethingAlreadyClosedIsRefusedBeforeTheWrite() async {
        scriptRead(prJSON(state: "CLOSED"))
        guard case .failure(let refusal) = await service().closePlan() else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(refusal.reason, .pullRequestNotOpen)
        XCTAssertFalse(launched("pr", "close"))
    }

    func testReopenOnlyAppliesToAClosedPullRequest() async {
        scriptRead(prJSON(state: "CLOSED"))
        probe.script(["pr", "reopen"], ok("Reopened pull request #42"))
        let reopened = await service().reopen()
        XCTAssertTrue(reopened.didSucceed, reopened.headline)
        XCTAssertEqual(probe.invocations.first { $0.starts(with: ["pr", "reopen"]) },
                       ["pr", "reopen", "42"])

        for state in ["OPEN", "MERGED"] {
            probe = FixtureGitHubCLI()
            probe.setExecutable("/fixture/gh")
            scriptRead(prJSON(state: state))
            let result = await service().reopen()
            XCTAssertEqual(result.refusal?.reason, .pullRequestNotOpen, state)
            XCTAssertFalse(launched("pr", "reopen"), state)
        }
    }

    func testSetDraftUsesReadyAndUndoAndSaysNothingWhenNothingChanges() async {
        scriptRead(prJSON(isDraft: false))
        probe.script(["pr", "ready"], ok(""))
        let toDraft = await service().setDraft(true)
        XCTAssertTrue(toDraft.didSucceed, toDraft.headline)
        XCTAssertEqual(probe.invocations.first { $0.starts(with: ["pr", "ready"]) },
                       ["pr", "ready", "42", "--undo"])

        probe = FixtureGitHubCLI()
        probe.setExecutable("/fixture/gh")
        scriptRead(prJSON(isDraft: true))
        probe.script(["pr", "ready"], ok(""))
        let toReady = await service().setDraft(false)
        XCTAssertTrue(toReady.didSucceed, toReady.headline)
        XCTAssertEqual(probe.invocations.first { $0.starts(with: ["pr", "ready"]) },
                       ["pr", "ready", "42"])

        // Already in the asked-for state: gh exits zero and does nothing, which
        // would have us report a change that did not happen.
        probe = FixtureGitHubCLI()
        probe.setExecutable("/fixture/gh")
        scriptRead(prJSON(isDraft: true))
        let noop = await service().setDraft(true)
        XCTAssertTrue(noop.didSucceed)
        XCTAssertTrue(noop.receipt?.summary.contains("already") ?? false,
                      noop.receipt?.summary ?? "")
        XCTAssertFalse(launched("pr", "ready"))
    }

    // MARK: - Vocabulary

    func testOnlyMergeAndCloseAreTreatedAsDestructive() {
        XCTAssertTrue(PullRequestActionKind.merge.isDestructive)
        XCTAssertTrue(PullRequestActionKind.close.isDestructive)
        for kind in PullRequestActionKind.allCases
        where kind != .merge && kind != .close {
            XCTAssertFalse(kind.isDestructive, "\(kind)")
        }
    }

    func testEveryActionResultHasAHeadline() {
        let ref = PullRequestRef(repository: "o/r", number: 1, url: "")
        let results: [PullRequestActionResult] = [
            .succeeded(PullRequestActionReceipt(action: .merge, ref: ref, summary: "Merged.")),
            .refused(PullRequestRefusal(.notMergeable)),
            .mergeabilityUnknown(MergeabilityPending(ref: ref)),
            .needsConfirmation(ActionConfirmation(sentence: "Merge o/r#1.", token: "t")),
        ]
        for result in results {
            XCTAssertFalse(result.headline.isEmpty, "\(result)")
        }
    }

    func testRepositoryIsDerivedFromThePullRequestURL() {
        XCTAssertEqual(
            PullRequestActionDecoder.repository(
                fromPullRequestURL: "https://github.com/hulryung/damson-ide/pull/42"),
            "hulryung/damson-ide")
        XCTAssertNil(PullRequestActionDecoder.repository(fromPullRequestURL: ""))
    }

    /// The refinement pass must never overwrite something the spine already
    /// named. If it could, there would be two vocabularies.
    func testTheRefinementPassOnlyEverRefinesApiError() {
        let named = GitHubCLIOutcome(status: 1, stderr: "no git remotes found")
        for context in PullRequestActionKind.allCases {
            XCTAssertEqual(
                PullRequestActionClassifier.classify(named, context: context).reason,
                .noGitRemote, "\(context)")
        }
    }

    func testUnrecognisedWordingStaysApiErrorAndKeepsItsMessage() {
        let outcome = GitHubCLIOutcome(status: 1, stderr: "the moon is in the wrong house")
        let refusal = PullRequestActionClassifier.classify(outcome, context: .merge)
        XCTAssertEqual(refusal.reason, .apiError)
        XCTAssertEqual(refusal.detail, "the moon is in the wrong house")
    }
}

// MARK: - RPC surface

/// `orchard pr …` through the in-memory server seam.
///
/// The contract pinned here is the one that separates these verbs from `checks`:
/// **only a verb that landed is `ok: true`.** A refusal, a pending mergeability
/// and an unconfirmed destructive verb are all `ok: false`, so the CLI exits
/// non-zero and a script cannot read "exit 0" as "the branch is in".
@MainActor
final class PullRequestActionHandlerTests: XCTestCase {
    private var tmp: URL!
    private var probe: FixtureGitHubCLI!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                      "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-pr-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        probe = FixtureGitHubCLI()
        probe.setExecutable("/fixture/gh")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeServer() throws -> (InMemoryRuntimeServer, Workspace) {
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try ChecksHandlerTests.git(["init", "-q", "-b", "topic"], cwd: repo)
        try ChecksHandlerTests.git(["config", "user.email", "t@o.app"], cwd: repo)
        try ChecksHandlerTests.git(["config", "user.name", "T"], cwd: repo)
        try ChecksHandlerTests.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        let service = WorkspaceService(dataURL: tmp.appendingPathComponent("orchard-data.json"))
        let record = try service.addRepo(path: repo, kind: .git)
        let workspace = try XCTUnwrap(try service.listWorkspaces(repo: record.id).first)
        var registry = CommandRegistry()
        registry.register(PullRequestActionCommandHandler(workspaces: service, probe: probe,
                                                          timeout: 2))
        registry.register(WorkspaceCommandHandler(service: service))
        return (InMemoryRuntimeServer(registry: registry, runtimeId: "rt_pr"), workspace)
    }

    private func call(_ server: InMemoryRuntimeServer, _ method: String,
                      _ params: [String: JSONValue]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    private func scriptRead(mergeable: String = "MERGEABLE", state: String = "OPEN") {
        probe.script(["pr", "view"], GitHubCLIOutcome(status: 0, stdout: """
        {"number":42,"title":"Act on a pull request",
         "url":"https://github.com/hulryung/damson-ide/pull/42","state":"\(state)",
         "isDraft":false,"baseRefName":"main","headRefName":"topic",
         "headRefOid":"abc1234","mergeable":"\(mergeable)","mergeStateStatus":"CLEAN"}
        """, executablePath: "/fixture/gh"))
        probe.script(["repo", "view"], GitHubCLIOutcome(status: 0, stdout: """
        {"nameWithOwner":"hulryung/damson-ide","mergeCommitAllowed":true,
         "squashMergeAllowed":true,"rebaseMergeAllowed":true,"deleteBranchOnMerge":false}
        """, executablePath: "/fixture/gh"))
    }

    private func launchedMerge() -> Bool {
        probe.invocations.contains { $0.starts(with: ["pr", "merge"]) }
    }

    // MARK: - The destructive gate

    /// Without `--yes`: the plan is read and the sentence is printed, the exit is
    /// non-zero, and nothing was sent. That is the whole dry run.
    func testMergeWithoutYesPrintsWhatItWouldDoAndFails() async throws {
        let (server, workspace) = try makeServer()
        scriptRead()
        let response = await call(server, "pr-merge", [
            "worktree": .string(workspace.id), "method": .string("squash"),
        ])
        XCTAssertFalse(response.ok, "a dry run must not exit 0")
        XCTAssertEqual(response.error?.code, "confirmation_required")
        let message = try XCTUnwrap(response.error?.message)
        XCTAssertTrue(message.contains("hulryung/damson-ide#42"), message)
        XCTAssertTrue(message.contains("squashing"), message)
        XCTAssertTrue(message.contains("will be kept"), message)
        XCTAssertTrue(message.contains("--yes"), message)
        XCTAssertFalse(launchedMerge(), "nothing may be sent without --yes")
        XCTAssertEqual(CLIEnvelopeExit.status(for: response), CLIEnvelopeExit.typedError)

        let data = try XCTUnwrap(response.error?.data?.objectValue)
        XCTAssertEqual(data["status"]?.stringValue, "confirmation_required")
        XCTAssertEqual(data["method"]?.stringValue, "squash")
        XCTAssertEqual(data["deleteBranch"]?.boolValue, false)
        XCTAssertEqual(data["readiness"]?.stringValue, "ready")
    }

    func testCloseWithoutYesPrintsWhatItWouldDoAndFails() async throws {
        let (server, workspace) = try makeServer()
        scriptRead()
        let response = await call(server, "pr-close", ["worktree": .string(workspace.id)])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "confirmation_required")
        XCTAssertTrue(response.error?.message.contains("without merging") ?? false)
        XCTAssertFalse(probe.invocations.contains { $0.starts(with: ["pr", "close"]) })
    }

    func testMergeWithYesActuallyMerges() async throws {
        let (server, workspace) = try makeServer()
        scriptRead()
        probe.script(["pr", "merge"], GitHubCLIOutcome(status: 0, stdout: "Merged #42",
                                                        executablePath: "/fixture/gh"))
        let response = await call(server, "pr-merge", [
            "worktree": .string(workspace.id), "method": .string("squash"),
            "yes": .bool(true),
        ])
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        let object = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "done")
        XCTAssertEqual(object["action"]?.stringValue, "merge")
        XCTAssertEqual(probe.invocations.first { $0.starts(with: ["pr", "merge"]) },
                       ["pr", "merge", "42", "--squash"])
    }

    func testDeleteBranchReachesGhOnlyWhenTheFlagIsGiven() async throws {
        let (server, workspace) = try makeServer()
        scriptRead()
        probe.script(["pr", "merge"], GitHubCLIOutcome(status: 0, stdout: "",
                                                        executablePath: "/fixture/gh"))
        _ = await call(server, "pr-merge", [
            "worktree": .string(workspace.id), "yes": .bool(true),
            "delete-branch": .bool(true),
        ])
        XCTAssertEqual(probe.invocations.first { $0.starts(with: ["pr", "merge"]) },
                       ["pr", "merge", "42", "--merge", "--delete-branch"])
    }

    /// A pending mergeability is its own code, and it still exits non-zero:
    /// nothing was merged.
    func testPendingMergeabilityIsItsOwnCodeAndStillFails() async throws {
        let (server, workspace) = try makeServer()
        scriptRead(mergeable: "UNKNOWN")
        let response = await call(server, "pr-merge", [
            "worktree": .string(workspace.id), "yes": .bool(true),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "mergeability_unknown")
        XCTAssertFalse(launchedMerge())
        let data = try XCTUnwrap(response.error?.data?.objectValue)
        XCTAssertFalse(data["remedy"]?.stringValue?.isEmpty ?? true)
    }

    /// And the dry run for the same state warns rather than promising.
    func testTheDryRunSaysWhenAMergeWouldNotGoThroughAnyway() async throws {
        let (server, workspace) = try makeServer()
        scriptRead(mergeable: "UNKNOWN")
        let response = await call(server, "pr-merge", ["worktree": .string(workspace.id)])
        XCTAssertEqual(response.error?.code, "confirmation_required")
        XCTAssertTrue(response.error?.message.contains("not finished computing") ?? false,
                      response.error?.message ?? "")
    }

    // MARK: - Refusals on the wire

    func testEmptyReviewBodyIsATypedErrorAndLaunchesNothing() async throws {
        let (server, workspace) = try makeServer()
        let response = await call(server, "pr-review", [
            "worktree": .string(workspace.id), "verdict": .string("request-changes"),
            "body": .string("  "),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "empty_review_body")
        XCTAssertTrue(probe.invocations.isEmpty, "not even the read should have happened")
        let data = try XCTUnwrap(response.error?.data?.objectValue)
        XCTAssertFalse(data["headline"]?.stringValue?.isEmpty ?? true)
        XCTAssertFalse(data["remedy"]?.stringValue?.isEmpty ?? true)
    }

    func testAnUnknownVerdictIsAUsageErrorNotAGuess() async throws {
        let (server, workspace) = try makeServer()
        let response = await call(server, "pr-review", [
            "worktree": .string(workspace.id), "verdict": .string("lgtm"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    func testVerdictSpellingsThatShouldWork() {
        XCTAssertEqual(PullRequestActionCommandHandler.verdict("approve"), .approve)
        XCTAssertEqual(PullRequestActionCommandHandler.verdict("request-changes"),
                       .requestChanges)
        XCTAssertEqual(PullRequestActionCommandHandler.verdict("REQUEST_CHANGES"),
                       .requestChanges)
        XCTAssertEqual(PullRequestActionCommandHandler.verdict("comment"), .comment)
        XCTAssertNil(PullRequestActionCommandHandler.verdict("ship-it"))
    }

    func testASuccessfulReviewIsOkAndSaysWhatHappened() async throws {
        let (server, workspace) = try makeServer()
        scriptRead()
        probe.script(["pr", "review"], GitHubCLIOutcome(status: 0, stdout: "",
                                                         executablePath: "/fixture/gh"))
        let response = await call(server, "pr-review", [
            "worktree": .string(workspace.id), "verdict": .string("comment"),
            "body": .string("looks fine"),
        ])
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        let object = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(object["action"]?.stringValue, "review")
        XCTAssertEqual(object["number"]?.intValue, 42)
        XCTAssertFalse(OrchardHumanFormatter.pullRequestAction(response.result).isEmpty)
    }

    func testThreadVerbsNeedAThreadId() async throws {
        let (server, workspace) = try makeServer()
        for verb in ["pr-resolve", "pr-unresolve", "pr-reply"] {
            let response = await call(server, verb, ["worktree": .string(workspace.id)])
            XCTAssertFalse(response.ok, verb)
            XCTAssertEqual(response.error?.code, "invalid_argument", verb)
        }
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    func testACommentNeedsAPathALineAndABody() async throws {
        let (server, workspace) = try makeServer()
        let base: [String: JSONValue] = ["worktree": .string(workspace.id)]
        let partials: [[String: JSONValue]] = [
            base,
            base.merging(["path": .string("A.swift")]) { _, new in new },
            base.merging(["path": .string("A.swift"), "line": .number(3)]) { _, new in new },
        ]
        for params in partials {
            let response = await call(server, "pr-comment", params)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, "invalid_argument")
        }
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    func testGitHubsRefusalKeepsItsCodeHeadlineDetailAndRemedyOnTheWire() async throws {
        let (server, workspace) = try makeServer()
        scriptRead()
        probe.script(["pr", "review"], GitHubCLIOutcome(
            status: 1, stderr: "GraphQL: Can not approve your own pull request",
            executablePath: "/fixture/gh"))
        let response = await call(server, "pr-review", [
            "worktree": .string(workspace.id), "verdict": .string("approve"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "cannot_review_own_pull_request")
        let data = try XCTUnwrap(response.error?.data?.objectValue)
        XCTAssertEqual(data["headline"]?.stringValue, "Cannot review your own pull request")
        XCTAssertTrue(data["detail"]?.stringValue?.contains("Can not approve") ?? false)
        XCTAssertFalse(data["remedy"]?.stringValue?.isEmpty ?? true)
    }

    func testAMissingWorktreeSelectorIsARequestError() async throws {
        let (server, _) = try makeServer()
        let response = await call(server, "pr-merge", [:])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    /// Every verb the spec advertises must be routable, or the CLI offers a verb
    /// the runtime does not answer.
    func testEveryAdvertisedVerbIsRegistered() {
        let handler = PullRequestActionCommandHandler(
            workspaces: WorkspaceService(dataURL: tmp.appendingPathComponent("w.json")))
        for verb in ["review", "comment", "reply", "resolve", "unresolve",
                     "merge", "ready", "close", "reopen"] {
            XCTAssertTrue(handler.verbs.contains("pr-\(verb)"), verb)
        }
    }
}
