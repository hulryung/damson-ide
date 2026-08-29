import XCTest
@testable import OrchardRuntime

/// The spine three pull-request features sit on. What is asserted here is the
/// contract they inherit: a failure always lands on a named reason, and a decoder
/// never invents a reassuring state out of a missing field.
final class PullRequestGatewayTests: XCTestCase {

    private func failure(_ stderr: String, status: Int32 = 1) -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: status, stdout: "", stderr: stderr)
    }

    // MARK: - Classification

    func testClassifiesGhsOwnWording() {
        let cases: [(String, PullRequestRefusalReason)] = [
            ("no git remotes found", .noGitRemote),
            ("none of the git remotes point to a known GitHub host", .unsupportedForge),
            ("To get started with GitHub CLI, please run: gh auth login", .ghNotAuthenticated),
            ("HTTP 401: Bad credentials", .ghNotAuthenticated),
            ("fatal: not a git repository", .notAWorktree),
            ("no pull requests found for branch \"topic\"", .noPullRequest),
            ("a pull request for branch \"topic\" into branch \"main\" already exists", .pullRequestExists),
            ("No commits between main and topic", .nothingToPropose),
            ("must first push the branch to a remote", .branchNotPushed),
            ("GraphQL: Can not approve your own pull request", .cannotReviewOwnPullRequest),
            ("Pull request is not mergeable", .notMergeable),
            ("HTTP 403: Resource not accessible by integration", .insufficientPermission),
        ]
        for (stderr, expected) in cases {
            let refusal = GitHubPRGateway.classify(failure(stderr))
            XCTAssertEqual(refusal.reason, expected, "stderr: \(stderr)")
            XCTAssertEqual(refusal.code, expected.rawValue)
            XCTAssertFalse(refusal.headline.isEmpty)
            XCTAssertFalse(refusal.remedy.isEmpty, "every dead end needs a next step")
        }
    }

    /// Wording we have never seen must not vanish into a friendly headline: it
    /// becomes `api_error` and keeps gh's own sentence.
    func testUnrecognisedStderrBecomesApiErrorAndKeepsTheMessage() {
        let refusal = GitHubPRGateway.classify(failure("something nobody has seen before"))
        XCTAssertEqual(refusal.reason, .apiError)
        XCTAssertEqual(refusal.detail, "something nobody has seen before")
    }

    func testDetailTakesTheFirstMeaningfulLineNotTheUsageBlob() {
        let refusal = GitHubPRGateway.classify(
            failure("\n\n  no pull requests found for branch \"x\"\n\nUsage: gh pr view\n"))
        XCTAssertEqual(refusal.reason, .noPullRequest)
        XCTAssertEqual(refusal.detail, "no pull requests found for branch \"x\"")
    }

    func testEveryReasonHasAHeadlineAndARemedy() {
        for reason in PullRequestRefusalReason.allCases {
            XCTAssertFalse(reason.headline.isEmpty, "\(reason) headline")
            XCTAssertFalse(reason.remedy.isEmpty, "\(reason) remedy")
            XCTAssertFalse(reason.rawValue.contains(" "), "\(reason) code must be a slug")
        }
    }

    /// The shared preconditions must keep the same codes T88 already emits, so the
    /// two vocabularies name the same fact the same way.
    func testSharedPreconditionCodesMatchChecks() {
        let pairs: [(PullRequestRefusalReason, ChecksUnavailableReason)] = [
            (.ghNotInstalled, .ghNotInstalled),
            (.ghNotAuthenticated, .ghNotAuthenticated),
            (.noGitRemote, .noGitRemote),
            (.unsupportedForge, .unsupportedForge),
            (.detachedHead, .detachedHead),
            (.ghTimedOut, .ghTimedOut),
            (.remoteWorkspace, .remoteWorkspace),
            (.notAWorktree, .notAWorktree),
            (.apiError, .apiError),
            (.noPullRequest, .noPullRequest),
        ]
        for (pr, checks) in pairs {
            XCTAssertEqual(pr.rawValue, checks.rawValue)
        }
    }

    func testOnlyNetworkShapedReasonsAreTransient() {
        XCTAssertTrue(PullRequestRefusalReason.ghTimedOut.isTransient)
        XCTAssertTrue(PullRequestRefusalReason.apiError.isTransient)
        XCTAssertFalse(PullRequestRefusalReason.pullRequestExists.isTransient)
        XCTAssertFalse(PullRequestRefusalReason.cannotReviewOwnPullRequest.isTransient)
    }

    // MARK: - Running

    func testMissingGhIsNamedBeforeAnythingIsLaunched() async {
        let probe = FixtureGitHubCLI()
        probe.setExecutable(nil)
        let gateway = GitHubPRGateway(probe: probe)
        let result = await gateway.run(["pr", "view"], cwd: URL(fileURLWithPath: "/tmp"))
        guard case .failure(let refusal) = result else { return XCTFail("expected refusal") }
        XCTAssertEqual(refusal.reason, .ghNotInstalled)
        XCTAssertTrue(probe.invocations.isEmpty, "gh must not be launched to learn it is absent")
    }

    func testTimeoutIsItsOwnReasonNotAnApiError() async {
        let probe = FixtureGitHubCLI()
        probe.setExecutable("/usr/bin/gh")
        probe.scriptFallback(GitHubCLIOutcome(status: nil, timedOut: true))
        let gateway = GitHubPRGateway(probe: probe, timeout: 3)
        let result = await gateway.run(["pr", "view"], cwd: URL(fileURLWithPath: "/tmp"))
        guard case .failure(let refusal) = result else { return XCTFail("expected refusal") }
        XCTAssertEqual(refusal.reason, .ghTimedOut)
    }

    func testNonJsonStdoutIsARefusalNotACrash() async {
        let probe = FixtureGitHubCLI()
        probe.setExecutable("/usr/bin/gh")
        probe.scriptFallback(GitHubCLIOutcome(status: 0, stdout: "not json at all"))
        let gateway = GitHubPRGateway(probe: probe)
        let result = await gateway.json(["pr", "view"], cwd: URL(fileURLWithPath: "/tmp"))
        guard case .failure(let refusal) = result else { return XCTFail("expected refusal") }
        XCTAssertEqual(refusal.reason, .apiError)
    }

    // MARK: - Decoding

    private var fullJSON: [String: Any] {
        [
            "number": 42,
            "title": "Open pull requests from Orchard",
            "body": "Body text",
            "url": "https://github.com/hulryung/damson-ide/pull/42",
            "state": "OPEN",
            "isDraft": true,
            "author": ["login": "hulryung", "avatarUrl": "https://example/a.png"],
            "baseRefName": "main",
            "headRefName": "orchard/pr-create",
            "headRefOid": "abc1234",
            "reviewDecision": "CHANGES_REQUESTED",
            "mergeable": "CONFLICTING",
            "mergeStateStatus": "DIRTY",
            "additions": 120,
            "deletions": 8,
            "changedFiles": 5,
            "createdAt": "2026-08-29T04:00:00Z",
            "updatedAt": "2026-08-29T04:30:00.123Z",
        ]
    }

    func testDecodesEveryFieldItAsksFor() {
        let pr = PullRequestDecoder.detail(from: fullJSON, repository: "hulryung/damson-ide")
        XCTAssertEqual(pr?.ref.number, 42)
        XCTAssertEqual(pr?.ref.repository, "hulryung/damson-ide")
        XCTAssertEqual(pr?.state, .open)
        XCTAssertEqual(pr?.isDraft, true)
        XCTAssertEqual(pr?.author?.login, "hulryung")
        XCTAssertEqual(pr?.baseRefName, "main")
        XCTAssertEqual(pr?.reviewDecision, .changesRequested)
        XCTAssertEqual(pr?.mergeable, .conflicting)
        XCTAssertEqual(pr?.mergeStateStatus, "DIRTY")
        XCTAssertEqual(pr?.changedFiles, 5)
        XCTAssertNotNil(pr?.createdAt)
        XCTAssertNotNil(pr?.updatedAt, "fractional seconds must parse too")
    }

    func testNoNumberMeansNoPullRequest() {
        XCTAssertNil(PullRequestDecoder.detail(from: ["title": "x"], repository: "o/r"))
    }

    /// The load-bearing assertion of the whole file: absent state is `unknown`,
    /// never `open`, and an unseen vocabulary word is `unknown`, never the
    /// nearest good value.
    func testMissingOrUnseenStatesDecodeToUnknownNotToSomethingReassuring() {
        let sparse = PullRequestDecoder.detail(from: ["number": 1], repository: "o/r")
        XCTAssertEqual(sparse?.state, .unknown)
        XCTAssertEqual(sparse?.mergeable, .unknown)
        XCTAssertEqual(sparse?.reviewDecision, .undecided, "absent means nobody decided yet")

        let alien = PullRequestDecoder.detail(
            from: ["number": 1, "state": "TRANSMOGRIFIED", "mergeable": "PROBABLY",
                   "reviewDecision": "VIBES"],
            repository: "o/r")
        XCTAssertEqual(alien?.state, .unknown)
        XCTAssertEqual(alien?.mergeable, .unknown)
        XCTAssertEqual(alien?.reviewDecision, .unknown)
    }

    func testUrlIsSynthesisedWhenGhDidNotSendOne() {
        let pr = PullRequestDecoder.detail(from: ["number": 9], repository: "o/r")
        XCTAssertEqual(pr?.ref.url, "https://github.com/o/r/pull/9")
    }

    func testUnparseableTimestampIsNilNotNow() {
        let pr = PullRequestDecoder.detail(
            from: ["number": 1, "createdAt": "yesterday-ish"], repository: "o/r")
        XCTAssertNil(pr?.createdAt)
    }

    func testAnonymousAuthorDecodesToNilRatherThanAnEmptyLogin() {
        XCTAssertNil(PullRequestDecoder.actor(["login": ""]))
        XCTAssertNil(PullRequestDecoder.actor(nil))
        XCTAssertEqual(PullRequestDecoder.actor(["login": "octocat"])?.login, "octocat")
    }

    // MARK: - Vocabularies

    func testVerdictFlagsAndBodyRequirement() {
        XCTAssertEqual(ReviewVerdict.approve.ghFlag, "--approve")
        XCTAssertEqual(ReviewVerdict.requestChanges.ghFlag, "--request-changes")
        XCTAssertEqual(ReviewVerdict.comment.ghFlag, "--comment")
        XCTAssertFalse(ReviewVerdict.approve.requiresBody)
        XCTAssertTrue(ReviewVerdict.requestChanges.requiresBody)
        XCTAssertTrue(ReviewVerdict.comment.requiresBody)
    }

    func testEligibilityKeepsUnavailableApartFromNotFound() {
        let couldNotAsk = PullRequestCreationEligibility(existingLookup: .unavailable)
        let noneExists = PullRequestCreationEligibility(existingLookup: .notFound)
        XCTAssertNotEqual(couldNotAsk.existingLookup, noneExists.existingLookup)
        XCTAssertTrue(couldNotAsk.canCreate, "no refusal recorded means creation is not blocked")

        let blocked = PullRequestCreationEligibility(
            refusal: PullRequestRefusal(.pullRequestExists),
            existingLookup: .found,
            existing: PullRequestRef(repository: "o/r", number: 3,
                                     url: "https://github.com/o/r/pull/3"))
        XCTAssertFalse(blocked.canCreate)
        XCTAssertEqual(blocked.existing?.number, 3)
    }
}
