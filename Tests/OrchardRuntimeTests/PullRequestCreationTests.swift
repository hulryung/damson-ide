import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// T92 — opening a pull request.
///
/// Everything here runs against `FixtureGitHubCLI` and a recorded git seam: no
/// network, no `gh` binary, no repository on disk except the temp directories the
/// template tests build. What is asserted is mostly *ordering and abstention* —
/// which rung answers first, what was not launched, what was not pushed — because
/// those are the properties that a later edit silently breaks.
final class PullRequestCreationTests: XCTestCase {

    // MARK: - Doubles

    /// Records what the service asked git to do, so "the create path did not push"
    /// is a fact a test can read rather than a comment somebody has to keep true.
    private final class GitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _facts: PullRequestGitFacts
        private var _commitsAhead: Int?
        private var _pushResult: Result<String, GitPushFailure> = .success("")
        private var _factsReads = 0
        private var _pushes: [String] = []
        private var _aheadQueries: [String] = []

        init(facts: PullRequestGitFacts, commitsAhead: Int? = 3) {
            _facts = facts
            _commitsAhead = commitsAhead
        }

        var factsReads: Int { lock.withLock { _factsReads } }
        var pushes: [String] { lock.withLock { _pushes } }
        var aheadQueries: [String] { lock.withLock { _aheadQueries } }

        func failPush(_ message: String) {
            lock.withLock { _pushResult = .failure(GitPushFailure(message)) }
        }

        var seam: PullRequestGitSeam {
            PullRequestGitSeam(
                facts: { [self] _ in
                    lock.withLock { _factsReads += 1; return _facts }
                },
                commitsAhead: { [self] _, ref in
                    lock.withLock { _aheadQueries.append(ref); return _commitsAhead }
                },
                push: { [self] _, remote, branch in
                    lock.withLock { _pushes.append("\(remote) \(branch)"); return _pushResult }
                })
        }
    }

    private let worktree = URL(fileURLWithPath: "/tmp/orchard-t92")

    private func healthyFacts(branch: String = "topic",
                              upstream: String? = "origin/topic",
                              ahead: Int? = 0) -> PullRequestGitFacts {
        PullRequestGitFacts(isRepository: true, branch: branch, headSha: "abc1234def",
                            upstream: upstream, aheadOfUpstream: ahead, remotes: ["origin"])
    }

    private func ok(_ object: [String: Any]) -> GitHubCLIOutcome {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return GitHubCLIOutcome(status: 0, stdout: String(decoding: data, as: UTF8.self))
    }

    private func fails(_ stderr: String, status: Int32 = 1) -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: status, stderr: stderr)
    }

    /// A probe scripted for the happy path: a GitHub repo whose default branch is
    /// `main`, a base that exists, and no pull request for the branch yet.
    private func healthyProbe() -> FixtureGitHubCLI {
        let probe = FixtureGitHubCLI()
        probe.setExecutable("/usr/bin/gh")
        probe.script(["repo", "view"], ok(["nameWithOwner": "hulryung/damson-ide",
                                           "defaultBranchRef": ["name": "main"]]))
        probe.script(["api"], GitHubCLIOutcome(status: 0, stdout: "main\n"))
        probe.script(["pr", "view"], fails("no pull requests found for branch \"topic\""))
        return probe
    }

    private func service(_ probe: FixtureGitHubCLI,
                         _ git: GitRecorder) -> PullRequestCreationService {
        PullRequestCreationService(gateway: GitHubPRGateway(probe: probe), git: git.seam)
    }

    // MARK: - The ladder, rung by rung

    /// First rung, and it runs before git does. A remote workspace's local path is
    /// either absent or an unrelated directory on this machine; asking git about it
    /// would produce a confident answer about the wrong checkout.
    func testRemoteWorkspaceIsRefusedBeforeGitIsEvenRead() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree, hostId: "mac-mini")
        XCTAssertEqual(result.refusal?.reason, .remoteWorkspace)
        XCTAssertEqual(git.factsReads, 0, "git must not be asked about another host's checkout")
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    func testNotAWorktreeIsNamedBeforeGhIsConsulted() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: PullRequestGitFacts(isRepository: false))
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .notAWorktree)
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    /// "gh is not installed" must be answerable without a process — otherwise it is
    /// not answerable at all on the machine where it is true.
    func testGhNotInstalledIsLearnedWithoutLaunchingGh() async {
        let probe = healthyProbe()
        probe.setExecutable(nil)
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .ghNotInstalled)
        XCTAssertTrue(probe.invocations.isEmpty, "gh must not run to prove gh is absent")
    }

    func testDetachedHeadNamesTheCommitItIsDetachedAt() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: PullRequestGitFacts(
            isRepository: true, branch: nil, headSha: "deadbeefcafe"))
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .detachedHead)
        XCTAssertTrue(result.refusal!.detail.contains("deadbeef"))
        XCTAssertNil(result.head)
    }

    /// The forge preconditions arrive already classified, in gh's own words: there
    /// is no second place in this feature that decides what "no remote" looks like.
    func testNoRemoteAndNonGitHubRemoteComeBackInGhsOwnWords() async {
        for (stderr, expected) in [("no git remotes found", PullRequestRefusalReason.noGitRemote),
                                   ("none of the git remotes configured for this repository "
                                    + "point to a known GitHub host",
                                    PullRequestRefusalReason.unsupportedForge)] {
            let probe = healthyProbe()
            probe.script(["repo", "view"], fails(stderr))
            let git = GitRecorder(facts: healthyFacts())
            let result = await service(probe, git).eligibility(worktree: worktree)
            XCTAssertEqual(result.refusal?.reason, expected)
            XCTAssertEqual(result.refusal?.detail, stderr, "gh's own sentence is kept")
            XCTAssertFalse(result.refusal!.remedy.isEmpty)
        }
    }

    func testAuthenticationFailureIsItsOwnReasonNotAnApiError() async {
        let probe = healthyProbe()
        probe.script(["repo", "view"], fails("HTTP 401: Bad credentials"))
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .ghNotAuthenticated)
    }

    /// A branch GitHub has never seen. `needsPush` is set — but nothing is pushed;
    /// that is what the flag is for.
    func testBranchWithNoUpstreamIsBranchNotPushedAndSetsNeedsPush() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts(upstream: nil, ahead: nil))
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .branchNotPushed)
        XCTAssertTrue(result.needsPush)
        XCTAssertEqual(result.head, "topic")
        XCTAssertTrue(git.pushes.isEmpty, "discovering a push is owed must not perform one")
    }

    func testLocalCommitsAheadOfUpstreamAreUnpushedCommits() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts(ahead: 2))
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .unpushedCommits)
        XCTAssertTrue(result.needsPush)
        XCTAssertTrue(result.refusal!.detail.contains("2 commits"))
        XCTAssertTrue(git.pushes.isEmpty)
    }

    /// Cheap rungs come first: proposing a branch onto itself is decided locally and
    /// costs no round trip to GitHub.
    func testBaseEqualToHeadIsRefusedWithoutAskingGitHubAboutTheBase() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree, base: "topic")
        XCTAssertEqual(result.refusal?.reason, .baseEqualsHead)
        XCTAssertFalse(probe.invocations.contains { $0.first == "api" },
                       "the base's existence is irrelevant once it equals the head")
    }

    /// A base the user named and that is not there is a refusal, **not** a quiet
    /// substitution of the default branch. Retargeting a base somebody typed is the
    /// same class of guess this whole vocabulary exists to refuse.
    func testMissingNamedBaseIsRefusedRatherThanReplacedByTheDefaultBranch() async {
        let probe = healthyProbe()
        probe.script(["api"], fails("gh: Not Found (HTTP 404)"))
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree, base: "release/9")
        XCTAssertEqual(result.refusal?.reason, .baseRefMissing)
        XCTAssertEqual(result.resolvedBase, "release/9")
        XCTAssertNotEqual(result.resolvedBase, "main", "the default branch was not substituted")
    }

    /// Not knowing is not evidence of absence. A base lookup that failed for any
    /// reason other than 404 leaves the caller's base standing; GitHub gets the last
    /// word at create time, and that refusal is classified too.
    func testUnreadableBaseLookupTakesTheCallerAtTheirWordRatherThanRefusing() async {
        let probe = healthyProbe()
        probe.script(["api"], fails("HTTP 500: Internal Server Error"))
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree, base: "release/9")
        XCTAssertNil(result.refusal)
        XCTAssertEqual(result.resolvedBase, "release/9")
    }

    func testNoBaseNamedFallsBackToTheRepositoryDefaultBranch() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree, base: nil)
        XCTAssertNil(result.refusal)
        XCTAssertEqual(result.resolvedBase, "main")
        XCTAssertFalse(probe.invocations.contains { $0.first == "api" },
                       "the repository's own default branch needs no existence check")
    }

    /// `main` is never guessed. A repository whose default branch GitHub did not
    /// name is a repository whose base we do not know.
    func testNoDefaultBranchAndNoNamedBaseIsNoBaseRefNotMain() async {
        let probe = healthyProbe()
        probe.script(["repo", "view"], ok(["nameWithOwner": "hulryung/damson-ide"]))
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .noBaseRef)
        XCTAssertNil(result.resolvedBase)
    }

    func testSittingOnTheDefaultBranchIsBaseEqualsHead() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts(branch: "main", upstream: "origin/main"))
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .baseEqualsHead)
        XCTAssertEqual(result.resolvedBase, "main")
    }

    func testZeroCommitsBetweenBaseAndHeadIsNothingToPropose() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts(), commitsAhead: 0)
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .nothingToPropose)
        XCTAssertEqual(result.commitsAhead, 0)
        XCTAssertEqual(git.aheadQueries, ["origin/main"], "counted against the remote's base")
    }

    /// An uncountable base — one that was never fetched — is not zero. Refusing here
    /// would tell a user with real commits that they have nothing to propose.
    func testUncountableCommitsAreNotReportedAsNothingToPropose() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts(), commitsAhead: nil)
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertNil(result.refusal)
        XCTAssertNil(result.commitsAhead)
    }

    func testExistingOpenPullRequestBlocksAndCarriesTheRefToOpen() async {
        let probe = healthyProbe()
        probe.script(["pr", "view"], ok(["number": 42, "state": "OPEN",
                                         "url": "https://github.com/hulryung/damson-ide/pull/42",
                                         "headRefName": "topic", "title": "Existing"]))
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertEqual(result.refusal?.reason, .pullRequestExists)
        XCTAssertEqual(result.existingLookup, .found)
        XCTAssertEqual(result.existing?.number, 42)
        XCTAssertEqual(result.existing?.url, "https://github.com/hulryung/damson-ide/pull/42")
        XCTAssertFalse(result.canCreate)
    }

    /// GitHub itself allows a new pull request on a branch whose last one was merged
    /// or closed, so refusing would leave the user stuck. The old one is still
    /// reported — "there was one and it was merged" is worth seeing first.
    func testClosedPullRequestIsReportedButDoesNotBlockANewOne() async {
        for state in ["CLOSED", "MERGED"] {
            let probe = healthyProbe()
            probe.script(["pr", "view"], ok(["number": 7, "state": state,
                                             "url": "https://github.com/o/r/pull/7",
                                             "headRefName": "topic"]))
            let git = GitRecorder(facts: healthyFacts())
            let result = await service(probe, git).eligibility(worktree: worktree)
            XCTAssertNil(result.refusal, "state \(state) must not block a new pull request")
            XCTAssertEqual(result.existingLookup, .found)
            XCTAssertEqual(result.existing?.number, 7)
        }
    }

    func testAnEligibleWorktreeCarriesTheWholeEvidenceNotJustATrueFlag() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts(), commitsAhead: 5)
        let result = await service(probe, git).eligibility(worktree: worktree)
        XCTAssertTrue(result.canCreate)
        XCTAssertNil(result.refusal)
        XCTAssertEqual(result.head, "topic")
        XCTAssertEqual(result.resolvedBase, "main")
        XCTAssertEqual(result.commitsAhead, 5)
        XCTAssertFalse(result.needsPush)
        XCTAssertEqual(result.existingLookup, .notFound)
    }

    // MARK: - found / notFound / unavailable

    /// **The bug this feature is named for.** Orca swallowed a failed pull-request
    /// lookup, read the silence as "no pull request exists", and opened a second one
    /// on a branch that already had one. A lookup that failed is `.unavailable` and
    /// is never, under any failure shape, reported as `.notFound`.
    func testAFailedExistingLookupIsUnavailableAndNeverNotFound() async {
        let failures: [GitHubCLIOutcome] = [
            fails("HTTP 401: Bad credentials"),
            fails("HTTP 403: Resource not accessible by integration"),
            fails("HTTP 502: Bad Gateway"),
            fails("dial tcp: lookup api.github.com: no such host"),
            GitHubCLIOutcome(status: nil, timedOut: true),
            GitHubCLIOutcome(status: 0, stdout: "not json at all"),
            GitHubCLIOutcome(status: 0, stdout: "{}"),
        ]
        for outcome in failures {
            let probe = healthyProbe()
            probe.script(["pr", "view"], outcome)
            let git = GitRecorder(facts: healthyFacts())
            let result = await service(probe, git).eligibility(worktree: worktree)
            XCTAssertEqual(result.existingLookup, .unavailable,
                           "a lookup that failed is not a lookup that answered: \(outcome)")
            XCTAssertNotEqual(result.existingLookup, .notFound)
            XCTAssertNil(result.existing)
        }
    }

    /// The other half of the same rule: gh answering "there is none" really is
    /// `.notFound`, and must not be smeared into `.unavailable` either. Both
    /// directions matter — a UI that can never say "no pull request" is as useless
    /// as one that says it wrongly.
    func testGhSayingThereIsNoPullRequestIsNotFound() async {
        for stderr in ["no pull requests found for branch \"topic\"",
                       "no open pull requests found for branch \"topic\""] {
            let probe = healthyProbe()
            probe.script(["pr", "view"], fails(stderr))
            let git = GitRecorder(facts: healthyFacts())
            let result = await service(probe, git).eligibility(worktree: worktree)
            XCTAssertEqual(result.existingLookup, .notFound)
            XCTAssertNil(result.existing)
            XCTAssertNil(result.refusal)
        }
    }

    /// An unavailable lookup does not block creation — the spine's own contract says
    /// so — but the second line of defence is real: GitHub refuses a duplicate in its
    /// own words, and that refusal is classified.
    func testAnUnavailableLookupDoesNotBlockButGitHubStillRefusesADuplicate() async {
        let probe = healthyProbe()
        probe.script(["pr", "view"], fails("HTTP 502: Bad Gateway"))
        probe.script(["pr", "create"], fails(
            "a pull request for branch \"topic\" into branch \"main\" already exists: #42"))
        let git = GitRecorder(facts: healthyFacts())
        let subject = service(probe, git)

        let eligibility = await subject.eligibility(worktree: worktree)
        XCTAssertNil(eligibility.refusal, "we could not ask, so we do not claim to know")
        XCTAssertEqual(eligibility.existingLookup, .unavailable)

        let created = await subject.create(worktree: worktree, draft: PullRequestDraft(
            title: "Second", base: "main", head: "topic"))
        guard case .failure(let refusal) = created else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal.reason, .pullRequestExists)
    }

    // MARK: - Template discovery

    private func makeWorktree(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t92-template-\(UUID().uuidString)")
        for (path, body) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testTemplateIsFoundInGitHubsOwnOrderOfPrecedence() throws {
        // Every location at once: the first one wins, and removing it promotes the
        // next. `.github/*` beats the root, which beats `docs/`.
        let all = [
            ".github/PULL_REQUEST_TEMPLATE.md": "github dir",
            "PULL_REQUEST_TEMPLATE.md": "root",
            "docs/PULL_REQUEST_TEMPLATE.md": "docs",
        ]
        let first = try makeWorktree(all)
        XCTAssertEqual(PullRequestTemplate.find(in: first)?.body, "github dir")

        var without = all
        without[".github/PULL_REQUEST_TEMPLATE.md"] = nil
        let second = try makeWorktree(without)
        XCTAssertEqual(PullRequestTemplate.find(in: second)?.body, "root")
        XCTAssertEqual(PullRequestTemplate.find(in: second)?.relativePath,
                       "PULL_REQUEST_TEMPLATE.md")

        let third = try makeWorktree(["docs/PULL_REQUEST_TEMPLATE.md": "docs"])
        XCTAssertEqual(PullRequestTemplate.find(in: third)?.body, "docs")
    }

    func testLowercaseTemplateNameIsFoundAndReportedAsItIsSpelledOnDisk() throws {
        let root = try makeWorktree([".github/pull_request_template.md": "lower"])
        let found = PullRequestTemplate.find(in: root)
        XCTAssertEqual(found?.body, "lower")
        XCTAssertEqual(found?.relativePath, ".github/pull_request_template.md",
                       "the label must name the file git can actually find")
    }

    /// A repository with several templates keeps them in a directory. "First" is a
    /// name sort, not whatever order the filesystem happened to hand back — a picker
    /// that shows a different template on a colleague's machine is a bug that only
    /// appears on the colleague's machine.
    func testDirectoryTemplatesAreOrderedByNameNotByFilesystemLuck() throws {
        let root = try makeWorktree([
            ".github/PULL_REQUEST_TEMPLATE/zeta.md": "zeta",
            ".github/PULL_REQUEST_TEMPLATE/alpha.md": "alpha",
            ".github/PULL_REQUEST_TEMPLATE/notes.txt": "not markdown",
        ])
        let found = PullRequestTemplate.find(in: root)
        XCTAssertEqual(found?.body, "alpha")
        XCTAssertEqual(found?.relativePath, ".github/PULL_REQUEST_TEMPLATE/alpha.md")
    }

    func testSingleFileTemplateBeatsTheTemplateDirectory() throws {
        let root = try makeWorktree([
            ".github/PULL_REQUEST_TEMPLATE.md": "single",
            ".github/PULL_REQUEST_TEMPLATE/alpha.md": "from directory",
        ])
        XCTAssertEqual(PullRequestTemplate.find(in: root)?.body, "single")
    }

    /// Most repositories have none, and a pull request opened without one is
    /// completely ordinary. Absence is nil, never a refusal, and never a checklist
    /// Orchard invented.
    func testNoTemplateIsNilAndNotAnError() throws {
        let empty = try makeWorktree(["README.md": "hi"])
        XCTAssertNil(PullRequestTemplate.find(in: empty))
        XCTAssertNil(PullRequestTemplate.find(in: URL(fileURLWithPath: "/nonexistent/xyz")))
    }

    func testEligibilityCarriesTheTemplateEvenOnARefusalPath() async throws {
        let root = try makeWorktree([".github/PULL_REQUEST_TEMPLATE.md": "## Why\n"])
        let probe = healthyProbe()
        // A branch that still needs a push: the sheet should still be able to prefill
        // the body while the push button is on screen.
        let git = GitRecorder(facts: healthyFacts(upstream: nil, ahead: nil))
        let result = await service(probe, git).eligibility(worktree: root)
        XCTAssertEqual(result.refusal?.reason, .branchNotPushed)
        XCTAssertEqual(result.template, "## Why\n")
    }

    // MARK: - Creating

    /// Refused before anything is launched. GitHub will not take an untitled pull
    /// request, and Orchard will not write a title from the branch name.
    func testEmptyTitleIsRefusedBeforeGhIsLaunched() async {
        for title in ["", "   ", "\n\t "] {
            let probe = healthyProbe()
            let git = GitRecorder(facts: healthyFacts())
            let result = await service(probe, git).create(
                worktree: worktree,
                draft: PullRequestDraft(title: title, base: "main", head: "topic"))
            guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
            XCTAssertEqual(refusal.reason, .emptyTitle)
            XCTAssertTrue(probe.invocations.isEmpty, "nothing may be launched for title '\(title)'")
        }
    }

    func testCreateSendsTheDraftFlagOnlyWhenAsked() async {
        for isDraft in [false, true] {
            let probe = healthyProbe()
            probe.script(["pr", "create"], GitHubCLIOutcome(
                status: 0, stdout: "https://github.com/hulryung/damson-ide/pull/91\n"))
            let git = GitRecorder(facts: healthyFacts())
            _ = await service(probe, git).create(
                worktree: worktree,
                draft: PullRequestDraft(title: "T", body: "B", base: "main", head: "topic",
                                        isDraft: isDraft))
            let argv = probe.invocations.first { $0.first == "pr" && $0.dropFirst().first == "create" }
            XCTAssertEqual(argv?.contains("--draft"), isDraft)
            XCTAssertEqual(argv?.contains("--base"), true)
            XCTAssertEqual(argv?.contains("main"), true)
            XCTAssertEqual(argv?.contains("topic"), true)
            XCTAssertEqual(argv?.contains("B"), true, "the body is passed, never regenerated")
        }
    }

    func testCreateParsesTheUrlGhPrintsEvenWithProgressLinesAroundIt() async {
        let probe = healthyProbe()
        probe.script(["pr", "create"], GitHubCLIOutcome(status: 0, stdout: """

            Creating pull request for topic into main in hulryung/damson-ide

            https://github.com/hulryung/damson-ide/pull/128
            """))
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).create(
            worktree: worktree, draft: PullRequestDraft(title: "T", base: "main", head: "topic"))
        guard case .success(let ref) = result else { return XCTFail("expected a ref") }
        XCTAssertEqual(ref.number, 128)
        XCTAssertEqual(ref.repository, "hulryung/damson-ide")
        XCTAssertEqual(ref.url, "https://github.com/hulryung/damson-ide/pull/128")
    }

    /// gh exiting zero without printing a URL is not a success we can name. Returning
    /// a synthesised number would hand the caller a pull request that may not exist.
    func testCreateWithoutAUrlIsAnApiErrorNotAFabricatedRef() async {
        let probe = healthyProbe()
        probe.script(["pr", "create"], GitHubCLIOutcome(status: 0, stdout: "done\n"))
        let git = GitRecorder(facts: healthyFacts())
        let result = await service(probe, git).create(
            worktree: worktree, draft: PullRequestDraft(title: "T", base: "main", head: "topic"))
        guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal.reason, .apiError)
        XCTAssertTrue(refusal.detail.contains("done"), "gh's own output is kept")
    }

    func testCreateSurfacesGhsRefusalsWithTheirOwnNames() async {
        let cases: [(String, PullRequestRefusalReason)] = [
            ("No commits between main and topic", .nothingToPropose),
            ("must first push the branch to a remote", .branchNotPushed),
            ("HTTP 403: Resource not accessible by integration", .insufficientPermission),
            ("GraphQL: something entirely new", .apiError),
        ]
        for (stderr, expected) in cases {
            let probe = healthyProbe()
            probe.script(["pr", "create"], fails(stderr))
            let git = GitRecorder(facts: healthyFacts())
            let result = await service(probe, git).create(
                worktree: worktree,
                draft: PullRequestDraft(title: "T", base: "main", head: "topic"))
            guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
            XCTAssertEqual(refusal.reason, expected, "stderr: \(stderr)")
        }
    }

    // MARK: - Nothing pushes itself

    /// **The abstention rule.** `create` never pushes, whatever eligibility said.
    /// A tool that pushes because it judged a push was needed has made a
    /// network-visible decision on the user's behalf.
    func testCreateNeverPushesEvenWhenEligibilitySaidAPushWasNeeded() async {
        let probe = healthyProbe()
        probe.script(["pr", "create"], GitHubCLIOutcome(
            status: 0, stdout: "https://github.com/o/r/pull/5\n"))
        let git = GitRecorder(facts: healthyFacts(upstream: nil, ahead: nil))
        let subject = service(probe, git)

        let eligibility = await subject.eligibility(worktree: worktree)
        XCTAssertTrue(eligibility.needsPush)

        _ = await subject.create(worktree: worktree,
                                 draft: PullRequestDraft(title: "T", base: "main", head: "topic"))
        XCTAssertTrue(git.pushes.isEmpty, "create must never push, however obvious it looks")
    }

    func testPushHeadIsTheOnlyThingThatPushesAndItSaysWhereItWent() async {
        let probe = healthyProbe()
        let git = GitRecorder(facts: healthyFacts(upstream: nil, ahead: nil))
        let result = await service(probe, git).pushHead(worktree: worktree)
        guard case .success(let ref) = result else { return XCTFail("expected a push") }
        XCTAssertEqual(ref, "origin/topic")
        XCTAssertEqual(git.pushes, ["origin topic"])
    }

    func testPushHeadRefusesWhatItCannotPush() async {
        let cases: [(PullRequestGitFacts, String, PullRequestRefusalReason)] = [
            (PullRequestGitFacts(isRepository: false), "local", .notAWorktree),
            (PullRequestGitFacts(isRepository: true, branch: nil, headSha: "abc"),
             "local", .detachedHead),
            (PullRequestGitFacts(isRepository: true, branch: "topic", remotes: []),
             "local", .noGitRemote),
            (healthyFacts(), "mac-mini", .remoteWorkspace),
        ]
        for (facts, hostId, expected) in cases {
            let git = GitRecorder(facts: facts)
            let result = await service(healthyProbe(), git).pushHead(worktree: worktree,
                                                                    hostId: hostId)
            guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
            XCTAssertEqual(refusal.reason, expected)
            XCTAssertTrue(git.pushes.isEmpty, "a refused push is not a push")
        }
    }

    func testAFailedPushKeepsGitsOwnMessage() async {
        let git = GitRecorder(facts: healthyFacts(upstream: nil, ahead: nil))
        git.failPush("Updates were rejected because the remote contains work you do not have\nhint: …")
        let result = await service(healthyProbe(), git).pushHead(worktree: worktree)
        guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal.reason, .apiError)
        XCTAssertEqual(refusal.detail,
                       "Updates were rejected because the remote contains work you do not have")
    }

    // MARK: - Reading gh's URL back

    func testPullRequestUrlParsing() {
        let ref = PullRequestURL.parse("https://github.com/hulryung/damson-ide/pull/42")
        XCTAssertEqual(ref?.repository, "hulryung/damson-ide")
        XCTAssertEqual(ref?.number, 42)

        // Trailing path and punctuation are dropped; the canonical URL is stored.
        XCTAssertEqual(PullRequestURL.parse("  https://github.com/o/r/pull/9/files  ")?.url,
                       "https://github.com/o/r/pull/9")
        XCTAssertEqual(PullRequestURL.parse("see https://ghe.example.com/o/r/pull/3.")?.repository,
                       "o/r")

        XCTAssertNil(PullRequestURL.parse("https://github.com/o/r/pull/none"))
        XCTAssertNil(PullRequestURL.parse("https://github.com/o/r/pull/0"))
        XCTAssertNil(PullRequestURL.parse("nothing here at all"))
        XCTAssertNil(PullRequestURL.ref(in: "line one\nline two\n"))
    }

    // MARK: - The gateway extension

    func test404IsMissingAndEverythingElseIsCouldNotTell() async {
        let probe = FixtureGitHubCLI()
        probe.setExecutable("/usr/bin/gh")
        let gateway = GitHubPRGateway(probe: probe)

        probe.scriptFallback(GitHubCLIOutcome(status: 0, stdout: "main"))
        let exists = await gateway.remoteBranch("main", repository: "o/r", cwd: worktree)
        XCTAssertEqual(exists, .exists)

        probe.scriptFallback(fails("gh: Not Found (HTTP 404)"))
        let missing = await gateway.remoteBranch("nope", repository: "o/r", cwd: worktree)
        XCTAssertEqual(missing, .missing)

        probe.scriptFallback(fails("HTTP 401: Bad credentials"))
        guard case .couldNotTell(let refusal) =
                await gateway.remoteBranch("main", repository: "o/r", cwd: worktree) else {
            return XCTFail("a 401 is not evidence that a branch is absent")
        }
        XCTAssertEqual(refusal.reason, .ghNotAuthenticated)

        probe.setExecutable(nil)
        guard case .couldNotTell = await gateway.remoteBranch("main", repository: "o/r",
                                                              cwd: worktree) else {
            return XCTFail("no gh means we could not tell, not that the branch is gone")
        }
    }

    /// Branch names are not URL-safe by construction. `release/1.0` keeps its slash
    /// because that is a path in GitHub's API; `?` and `#` do not.
    func testBranchNamesArePathEscapedWithoutManglingSlashes() {
        XCTAssertEqual(GitHubPRGateway.pathEscaped("release/1.0"), "release/1.0")
        XCTAssertEqual(GitHubPRGateway.pathEscaped("fix/#12"), "fix/%2312")
        XCTAssertEqual(GitHubPRGateway.pathEscaped("a b"), "a%20b")
    }

    // MARK: - The published CLI surface

    /// The help an agent reads and the flags the binary accepts come from one
    /// table, so a refusal code that exists but is undocumented is a test failure
    /// rather than something a user discovers.
    func testPrCommandPublishesItsFlagsAndEveryRefusalCodeItCanEmit() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "pr" })
        for flag in ["worktree", "base", "title", "body", "draft", "cwd", "json"] {
            XCTAssertNotNil(spec.flag(named: flag), "pr must accept --\(flag)")
        }
        XCTAssertNil(spec.flag(named: "draft")?.valueHint, "--draft is a boolean flag")

        let notes = spec.notes.joined(separator: " ")
        let published: [PullRequestRefusalReason] = [
            .notAWorktree, .remoteWorkspace, .ghNotInstalled, .ghNotAuthenticated,
            .detachedHead, .noGitRemote, .unsupportedForge, .branchNotPushed,
            .unpushedCommits, .baseEqualsHead, .baseRefMissing, .noBaseRef,
            .nothingToPropose, .pullRequestExists, .emptyTitle, .apiError, .ghTimedOut,
        ]
        for reason in published {
            XCTAssertTrue(notes.contains(reason.rawValue),
                          "\(reason.rawValue) is reachable but undocumented")
        }
        XCTAssertTrue(notes.contains("unavailable"), "the third lookup state must be documented")
        XCTAssertTrue(notes.lowercased().contains("never pushes"),
                      "the no-silent-push rule belongs in the published contract")
    }

    /// The human output for a refusal carries all four parts, the way `orchard
    /// checks` does — and says "could not ask" rather than "none" for an
    /// unavailable lookup.
    func testEligibilityHumanOutputPrintsCodeHeadlineDetailAndRemedy() {
        let refused = OrchardHumanFormatter.pullRequestEligibility(.object([
            "head": .string("topic"), "base": .string("main"), "needsPush": .bool(true),
            "existingLookup": .string("unavailable"),
            "refusal": .object([
                "code": .string("branch_not_pushed"),
                "headline": .string("Branch not pushed"),
                "detail": .string("topic has no upstream branch"),
                "remedy": .string("Push the branch first."),
            ]),
        ]))
        XCTAssertTrue(refused.contains("Branch not pushed"))
        XCTAssertTrue(refused.contains("[branch_not_pushed]"))
        XCTAssertTrue(refused.contains("topic has no upstream branch"))
        XCTAssertTrue(refused.contains("Push the branch first."))
        XCTAssertTrue(refused.contains("push required"))
        XCTAssertTrue(refused.contains("could not ask"),
                      "an unavailable lookup must never read as 'no pull request'")

        let ready = OrchardHumanFormatter.pullRequestEligibility(.object([
            "head": .string("topic"), "base": .string("main"),
            "commitsAhead": .number(3), "needsPush": .bool(false),
            "existingLookup": .string("notFound"), "hasTemplate": .bool(true),
        ]))
        XCTAssertTrue(ready.contains("Ready to open a pull request"))
        XCTAssertTrue(ready.contains("topic → main"))
        XCTAssertTrue(ready.contains("3 commits ahead"))
        XCTAssertTrue(ready.contains("no pull request"))
        XCTAssertTrue(ready.contains("template"))
    }

    func testCreateHumanOutputNamesWhatWasOpenedAndWhere() {
        let text = OrchardHumanFormatter.pullRequestCreate(.object([
            "number": .number(128), "isDraft": .bool(true), "title": .string("A title"),
            "head": .string("topic"), "base": .string("main"),
            "repository": .string("hulryung/damson-ide"),
            "url": .string("https://github.com/hulryung/damson-ide/pull/128"),
        ]))
        XCTAssertTrue(text.contains("Opened #128 (draft) A title"))
        XCTAssertTrue(text.contains("topic → main on hulryung/damson-ide"))
        XCTAssertTrue(text.contains("https://github.com/hulryung/damson-ide/pull/128"))
    }

    /// Uncounted commits must not print as zero — the same distinction the service
    /// keeps, kept on the way to the terminal.
    func testUncountedCommitsPrintAsUncountedNotAsZero() {
        let text = OrchardHumanFormatter.pullRequestEligibility(.object([
            "head": .string("topic"), "base": .string("main"),
            "needsPush": .bool(false), "existingLookup": .string("notFound"),
        ]))
        XCTAssertTrue(text.contains("commits not counted"))
        XCTAssertFalse(text.contains("0 commits"))
    }
}
