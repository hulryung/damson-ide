import XCTest
@testable import OrchardRuntime

/// T88 core: every unavailable path is typed, no status is guessed, and the cache
/// cannot hand back a reading that no longer describes the workspace.
final class ChecksServiceTests: XCTestCase {

    // MARK: - Fixtures

    /// The exact wording gh 2.98.0 prints for each dead end. Captured live (see
    /// docs/reports/t88-checks.md); pinning them here means a gh wording change
    /// fails a test instead of quietly collapsing into `api_error`.
    private enum GHSays {
        static let noRemote = "no git remotes found"
        static let notGitHub = "none of the git remotes configured for this repository "
            + "point to a known GitHub host. To tell gh about a new GitHub host, "
            + "please use `gh auth login`"
        static let notAuthenticated = "To get started with GitHub CLI, please run:  gh auth login\n"
            + "Alternatively, populate the GH_TOKEN environment variable with a "
            + "GitHub API authentication token."
        static let noPR = "no pull requests found for branch \"feature/x\""
        static let badCredentials = "HTTP 401: Bad credentials (https://api.github.com/graphql)\n"
            + "Try authenticating with:  gh auth login -h github.com"
        static let rateLimited = "HTTP 403: API rate limit exceeded (https://api.github.com/graphql)"
    }

    private func failure(_ stderr: String, status: Int32 = 1) -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: status, stderr: stderr, executablePath: "/fixture/gh")
    }

    private func prJSON(number: Int = 7, checks: String = "[]",
                        state: String = "OPEN", head: String = "abc123") -> String {
        """
        {"number":\(number),"title":"Add checks","url":"https://github.com/o/r/pull/\(number)",
         "state":"\(state)","isDraft":false,"headRefName":"feature/x","headRefOid":"\(head)",
         "statusCheckRollup":\(checks)}
        """
    }

    private func success(_ json: String) -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: 0, stdout: json, executablePath: "/fixture/gh")
    }

    private let checkRollup = """
    [{"__typename":"CheckRun","name":"build","workflowName":"CI","status":"COMPLETED",
      "conclusion":"SUCCESS","startedAt":"2026-08-27T05:58:41Z",
      "completedAt":"2026-08-27T05:59:41Z",
      "detailsUrl":"https://github.com/o/r/actions/runs/33044232443/job/98424413029"},
     {"__typename":"CheckRun","name":"test","workflowName":"CI","status":"IN_PROGRESS",
      "conclusion":null,
      "detailsUrl":"https://github.com/o/r/actions/runs/33044232443/job/98424413030"},
     {"__typename":"StatusContext","context":"legacy/ci","state":"FAILURE",
      "description":"1 test failed","targetUrl":"https://ci.example.com/build/9",
      "createdAt":"2026-08-27T05:58:41Z"}]
    """

    private func makeService(_ probe: FixtureGitHubCLI,
                             facts: ChecksGitFacts = ChecksGitFacts(branch: "feature/x",
                                                                    headSha: "abc123",
                                                                    isRepository: true),
                             ttl: TimeInterval = 45,
                             now: @escaping @Sendable () -> Date = { Date() }) -> ChecksService {
        ChecksService(probe: probe, gitFacts: { _ in facts }, ttl: ttl, timeout: 1, now: now)
    }

    // MARK: - Typed unavailability

    func testEveryGhFailureShapeGetsItsOwnReason() {
        let cases: [(String, ChecksUnavailableReason)] = [
            (GHSays.noRemote, .noGitRemote),
            (GHSays.notGitHub, .unsupportedForge),
            (GHSays.notAuthenticated, .ghNotAuthenticated),
            (GHSays.noPR, .noPullRequest),
            (GHSays.badCredentials, .ghNotAuthenticated),
            (GHSays.rateLimited, .apiError),
            ("fatal: not a git repository (or any of the parent directories): .git",
             .notAWorktree),
        ]
        for (stderr, expected) in cases {
            let reason = GitHubChecksParser.unavailability(from: failure(stderr))
            XCTAssertEqual(reason.reason, expected, "for: \(stderr.prefix(40))")
            XCTAssertEqual(reason.code, expected.rawValue)
            // A named dead end always carries gh's own words and a next step.
            XCTAssertFalse(reason.headline.isEmpty)
            XCTAssertFalse(reason.remedy.isEmpty)
            XCTAssertFalse(reason.detail.isEmpty)
        }
    }

    func testNotAuthenticatedExitCodeAloneIsEnough() {
        let reason = GitHubChecksParser.unavailability(
            from: GitHubCLIOutcome(status: 4, stderr: "", executablePath: "/fixture/gh"))
        XCTAssertEqual(reason.reason, .ghNotAuthenticated)
    }

    func testMissingBinaryAndTimeoutAreDistinctFromApiError() {
        XCTAssertEqual(GitHubChecksParser.unavailability(from: .notInstalled()).reason,
                       .ghNotInstalled)
        let timedOut = GitHubCLIOutcome(status: nil, timedOut: true,
                                        executablePath: "/fixture/gh")
        XCTAssertEqual(GitHubChecksParser.unavailability(from: timedOut).reason, .ghTimedOut)
    }

    func testUnrecognisedFailureIsApiErrorCarryingWhatGhSaid() {
        let reason = GitHubChecksParser.unavailability(from: failure("something new happened"))
        XCTAssertEqual(reason.reason, .apiError)
        XCTAssertEqual(reason.detail, "something new happened")
    }

    /// gh answering with something we cannot read is not "no pull request" and not
    /// a success — it is an api error with the evidence attached.
    func testUnreadablePayloadIsApiErrorNotSuccess() {
        let outcome = success("<!DOCTYPE html><html>proxy login page</html>")
        switch GitHubChecksParser.parsePullRequest(outcome) {
        case .success: XCTFail("HTML must not parse as a pull request")
        case .failure(let reason):
            XCTAssertEqual(reason.reason, .apiError)
            XCTAssertTrue(reason.detail.contains("not JSON"))
        }
    }

    func testJSONWithoutANumberIsApiError() {
        switch GitHubChecksParser.parsePullRequest(success("{\"title\":\"x\"}")) {
        case .success: XCTFail("a PR with no number is not a PR")
        case .failure(let reason): XCTAssertEqual(reason.reason, .apiError)
        }
    }

    // MARK: - Buckets and rollup

    func testBucketsCollapseGitHubStatesAndKeepUnknownVisible() {
        XCTAssertEqual(CheckBucket.from(status: "COMPLETED", conclusion: "SUCCESS"), .pass)
        XCTAssertEqual(CheckBucket.from(status: "COMPLETED", conclusion: "FAILURE"), .fail)
        XCTAssertEqual(CheckBucket.from(status: "COMPLETED", conclusion: "TIMED_OUT"), .fail)
        XCTAssertEqual(CheckBucket.from(status: "COMPLETED", conclusion: "SKIPPED"), .skipped)
        XCTAssertEqual(CheckBucket.from(status: "COMPLETED", conclusion: "NEUTRAL"), .neutral)
        XCTAssertEqual(CheckBucket.from(status: "IN_PROGRESS", conclusion: nil), .pending)
        XCTAssertEqual(CheckBucket.from(status: nil, conclusion: "PENDING"), .pending)
        // The rule that matters: a state we have never seen is not a pass.
        XCTAssertEqual(CheckBucket.from(status: "COMPLETED", conclusion: "TELEPORTED"), .unknown)
        XCTAssertEqual(CheckBucket.from(status: nil, conclusion: nil), .unknown)
    }

    func testRollupTakesTheWorstAndDistinguishesNoneFromUnknown() {
        func check(_ bucket: CheckBucket) -> CheckRunSummary {
            CheckRunSummary(id: bucket.rawValue, name: bucket.rawValue, kind: "CheckRun",
                            bucket: bucket)
        }
        XCTAssertEqual(ChecksRollup.from([]), .none)
        XCTAssertEqual(ChecksRollup.from([check(.pass), check(.skipped)]), .pass)
        XCTAssertEqual(ChecksRollup.from([check(.pass), check(.pending)]), .pending)
        XCTAssertEqual(ChecksRollup.from([check(.pass), check(.pending), check(.fail)]), .fail)
        XCTAssertEqual(ChecksRollup.from([check(.pass), check(.unknown)]), .unknown)
        XCTAssertEqual(ChecksRollup.from([check(.cancelled)]), .fail)
    }

    func testRollupParsesBothCheckRunAndStatusContext() {
        switch GitHubChecksParser.parsePullRequest(success(prJSON(checks: checkRollup))) {
        case .failure(let reason): XCTFail("unexpected \(reason.code)")
        case .success(let (pr, checks)):
            XCTAssertEqual(pr.number, 7)
            XCTAssertEqual(pr.repository, "o/r")
            XCTAssertEqual(checks.count, 3)

            XCTAssertEqual(checks[0].bucket, CheckBucket.pass.rawValue)
            XCTAssertEqual(checks[0].workflow, "CI")
            XCTAssertEqual(checks[0].runId, "33044232443")
            XCTAssertEqual(checks[0].jobId, "98424413029")

            XCTAssertEqual(checks[1].bucket, CheckBucket.pending.rawValue)
            XCTAssertNil(checks[1].conclusion)

            // The old commit-status API spells everything differently.
            let legacy = checks[2]
            XCTAssertEqual(legacy.name, "legacy/ci")
            XCTAssertEqual(legacy.kind, "StatusContext")
            XCTAssertEqual(legacy.bucket, CheckBucket.fail.rawValue)
            XCTAssertEqual(legacy.detailsUrl, "https://ci.example.com/build/9")
            XCTAssertEqual(legacy.summary, "1 test failed")
            // Not an Actions job: no ids, which is what makes `checks show` refuse
            // typed instead of pretending it can fetch a log.
            XCTAssertNil(legacy.jobId)
        }
    }

    // MARK: - Cache honesty

    func testCurrentReadingIsReusedWithoutASecondSpawn() async {
        let probe = FixtureGitHubCLI()
        probe.script(["pr", "view"], success(prJSON()))
        let service = makeService(probe)

        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(probe.invocations.count, 1)
    }

    func testMovingHEADDropsTheReadingRatherThanRedrawingIt() async {
        let probe = FixtureGitHubCLI()
        probe.script(["pr", "view"], success(prJSON(number: 7)))
        var facts = ChecksGitFacts(branch: "feature/x", headSha: "abc123", isRepository: true)
        let service = ChecksService(probe: probe, gitFacts: { _ in facts }, ttl: 45,
                                    timeout: 1)

        let first = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(first.headSha, "abc123")

        facts.headSha = "def456"
        probe.script(["pr", "view"], success(prJSON(number: 8, head: "def456")))
        let second = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(probe.invocations.count, 2)
        XCTAssertEqual(second.pullRequest?.number, 8)
        XCTAssertEqual(second.headSha, "def456")
    }

    /// Two branches can point at the same commit, and detaching HEAD keeps the
    /// commit while removing the branch. The commit alone is not the key.
    func testSwitchingBranchAtTheSameCommitDropsTheReading() async {
        let probe = FixtureGitHubCLI()
        probe.script(["pr", "view"], success(prJSON()))
        var facts = ChecksGitFacts(branch: "feature/x", headSha: "abc123", isRepository: true)
        let service = ChecksService(probe: probe, gitFacts: { _ in facts }, ttl: 45,
                                    timeout: 1)

        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        facts.branch = "feature/y"
        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(probe.invocations.count, 2)

        // Detached: no branch at all, and the previous branch's PR must not stand in.
        facts.branch = nil
        let detached = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(detached.unavailable?.reason, .detachedHead)
    }

    func testAnExpiredReadingIsNotServedAsCurrent() async {
        let probe = FixtureGitHubCLI()
        probe.script(["pr", "view"], success(prJSON()))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let service = makeService(probe, ttl: 30, now: { clock.now })

        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        clock.advance(29)
        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(probe.invocations.count, 1, "still current inside the TTL")

        clock.advance(2)
        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(probe.invocations.count, 2, "past the TTL it must be re-read")

        // The expired entry is still recoverable, but only by a caller that asks
        // for it by its explicit name.
        let last = await service.lastKnown(path: "/tmp/w")
        XCTAssertNotNil(last)
        let current = await service.cached(path: "/tmp/w", headSha: "abc123",
                                           branch: "feature/x")
        XCTAssertNotNil(current, "the fresh re-read is current again")
    }

    func testRefreshBypassesTheCacheAndInvalidateEmptiesIt() async {
        let probe = FixtureGitHubCLI()
        probe.script(["pr", "view"], success(prJSON()))
        let service = makeService(probe)

        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        _ = await service.snapshot(worktreeId: "w", path: "/tmp/w", refresh: true)
        XCTAssertEqual(probe.invocations.count, 2)

        await service.invalidate(path: "/tmp/w")
        let last = await service.lastKnown(path: "/tmp/w")
        XCTAssertNil(last)
    }

    func testEverySnapshotCarriesWhenItWasTaken() async {
        let probe = FixtureGitHubCLI()
        probe.script(["pr", "view"], success(prJSON()))
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let service = makeService(probe, now: { taken })
        let snapshot = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(snapshot.observedDate.timeIntervalSince1970, taken.timeIntervalSince1970,
                       accuracy: 0.01)

        // An unavailable snapshot is stamped too — an unread panel and a panel that
        // read nothing five minutes ago are different things.
        let missing = ChecksService(probe: probe,
                                    gitFacts: { _ in ChecksGitFacts(branch: nil, headSha: nil,
                                                                    isRepository: false) },
                                    now: { taken })
        let unavailable = await missing.snapshot(worktreeId: "w", path: "/tmp/x")
        XCTAssertEqual(unavailable.unavailable?.reason, .notAWorktree)
        XCTAssertEqual(unavailable.observedDate.timeIntervalSince1970,
                       taken.timeIntervalSince1970, accuracy: 0.01)
    }

    func testConcurrentReadsCollapseToOneSpawn() async {
        let probe = FixtureGitHubCLI()
        probe.script(["pr", "view"], success(prJSON()))
        let service = makeService(probe)
        async let a = service.snapshot(worktreeId: "w", path: "/tmp/w")
        async let b = service.snapshot(worktreeId: "w", path: "/tmp/w")
        async let c = service.snapshot(worktreeId: "w", path: "/tmp/w")
        let all = await [a, b, c]
        XCTAssertEqual(Set(all.map(\.status)), ["available"])
        XCTAssertEqual(probe.invocations.count, 1)
    }

    // MARK: - Refusals before any network

    func testRemoteWorkspaceAndFolderWorkspaceRefuseWithoutSpawningGh() async {
        let probe = FixtureGitHubCLI()
        let service = makeService(probe)

        let remote = await service.snapshot(worktreeId: "w", path: "/tmp/w",
                                            hostId: "ssh:builder")
        XCTAssertEqual(remote.unavailable?.reason, .remoteWorkspace)
        XCTAssertTrue(remote.unavailable?.detail.contains("ssh:builder") ?? false)

        let folder = await service.snapshot(worktreeId: "w", path: "/tmp/w", kind: .folder)
        XCTAssertEqual(folder.unavailable?.reason, .notAGitWorkspace)
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    func testMissingGhIsAnsweredBeforeAnyNetworkCall() async {
        let probe = FixtureGitHubCLI()
        probe.setExecutable(nil)
        let service = makeService(probe)
        let snapshot = await service.snapshot(worktreeId: "w", path: "/tmp/w")
        XCTAssertEqual(snapshot.unavailable?.reason, .ghNotInstalled)
        XCTAssertTrue(probe.invocations.isEmpty, "no point running a binary that is not there")
    }

    // MARK: - Logs

    func testLogTailIsBoundedAndSaysSo() {
        let log = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let all = GitHubChecksParser.tail(log, limit: 0)
        XCTAssertFalse(all.truncated)
        XCTAssertEqual(all.total, 500)

        let tail = GitHubChecksParser.tail(log, limit: 10)
        XCTAssertTrue(tail.truncated)
        XCTAssertEqual(tail.total, 500)
        XCTAssertEqual(tail.returned, 10)
        XCTAssertTrue(tail.text.hasSuffix("line 500"))
        XCTAssertTrue(tail.text.hasPrefix("line 491"))
    }

    func testCheckWithoutAnActionsJobRefusesTypedInsteadOfGuessing() async {
        let probe = FixtureGitHubCLI()
        let service = makeService(probe)
        let check = CheckRunSummary(id: "legacy", name: "legacy/ci", kind: "StatusContext",
                                    bucket: .fail,
                                    detailsUrl: "https://ci.example.com/build/9")
        let result = await service.log(worktreeId: "w", path: "/tmp/w", check: check)
        XCTAssertFalse(result.isAvailable)
        XCTAssertEqual(result.reason, CheckLogUnavailableReason.notAnActionsJob.rawValue)
        XCTAssertTrue(result.detail?.contains("ci.example.com") ?? false)
        XCTAssertNotNil(result.remedy)
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    func testFetchedLogIsReturnedWithItsBounds() async {
        let probe = FixtureGitHubCLI()
        probe.script(["run", "view"],
                     GitHubCLIOutcome(status: 0, stdout: "a\nb\nc\n",
                                      executablePath: "/fixture/gh"))
        let service = makeService(probe)
        let check = CheckRunSummary(id: "build", name: "build", kind: "CheckRun",
                                    bucket: .fail, jobId: "98424413029")
        let result = await service.log(worktreeId: "w", path: "/tmp/w", check: check)
        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(result.log, "a\nb\nc")
        XCTAssertEqual(result.totalLines, 3)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(probe.invocations.first?.prefix(4).joined(separator: " "),
                       "run view --job 98424413029")
    }

    func testUnfinishedAndExpiredLogsAreDistinctReasons() {
        let pending = GitHubChecksParser.logUnavailability(
            from: failure("run 33044232443 is still in progress; logs will be available when it is complete"))
        XCTAssertEqual(pending.0, .logPending)

        let expired = GitHubChecksParser.logUnavailability(
            from: failure("HTTP 410: logs expired (https://api.github.com/…)"))
        XCTAssertEqual(expired.0, .expired)

        let other = GitHubChecksParser.logUnavailability(from: failure("HTTP 500"))
        XCTAssertEqual(other.0, .apiError)
    }

    func testActionsIdentifiersOnlyParseRealJobURLs() {
        let ids = GitHubChecksParser.actionsIdentifiers(
            "https://github.com/o/r/actions/runs/12/job/34")
        XCTAssertEqual(ids.runId, "12")
        XCTAssertEqual(ids.jobId, "34")

        let runOnly = GitHubChecksParser.actionsIdentifiers(
            "https://github.com/o/r/actions/runs/12")
        XCTAssertEqual(runOnly.runId, "12")
        XCTAssertNil(runOnly.jobId)

        XCTAssertNil(GitHubChecksParser.actionsIdentifiers("https://ci.example.com/b/9").jobId)
        XCTAssertNil(GitHubChecksParser.actionsIdentifiers(nil).runId)
    }
}

/// A clock the test moves by hand. Date.now would make TTL assertions timing-dependent.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }
}
