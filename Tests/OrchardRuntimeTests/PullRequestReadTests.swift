import XCTest
@testable import OrchardRuntime

/// T93 — reading a pull request.
///
/// Everything here is fixture-driven: no network, no `gh` binary, no repository.
/// The shapes the fixtures use were taken from live `gh` 2.98.0 output against
/// public pull requests, which is why the awkward ones are here at all — an
/// outdated thread whose `line` is null, and a `latestReviews` entry whose `id`
/// is the empty string.
final class PullRequestReadTests: XCTestCase {

    private let cwd = URL(fileURLWithPath: "/tmp/worktree")

    // MARK: - Doubles

    private func fixture(_ outcomes: [([String], GitHubCLIOutcome)]) -> FixtureGitHubCLI {
        let probe = FixtureGitHubCLI()
        probe.setExecutable("/usr/bin/gh")
        for (prefix, outcome) in outcomes { probe.script(prefix, outcome) }
        return probe
    }

    private func ok(_ stdout: String) -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: 0, stdout: stdout)
    }

    private func failed(_ stderr: String, status: Int32 = 1) -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: status, stdout: "", stderr: stderr)
    }

    private func service(_ probe: any GitHubCLIProbe,
                         maxThreadPages: Int = ReviewThreadQuery.maxPages) -> PullRequestReadService {
        PullRequestReadService(gateway: GitHubPRGateway(probe: probe, timeout: 5),
                               maxThreadPages: maxThreadPages,
                               now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    /// `FixtureGitHubCLI` keys on the first three argv words, so both pages of a
    /// paginated GraphQL query collide on `api graphql`. This double keys on the
    /// cursor instead — which makes it a *sharper* test than a response queue
    /// would be: page two is only served if the code actually sent the cursor
    /// page one handed it.
    private final class PagingGitHubCLI: GitHubCLIProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var _invocations: [[String]] = []
        /// cursor (nil for the first page) → what `gh` prints.
        let pages: [String?: GitHubCLIOutcome]
        let prView: GitHubCLIOutcome?

        init(pages: [String?: GitHubCLIOutcome], prView: GitHubCLIOutcome? = nil) {
            self.pages = pages
            self.prView = prView
        }

        var invocations: [[String]] { lock.withLock { _invocations } }

        func resolvedExecutable() -> String? { "/usr/bin/gh" }

        func run(_ arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitHubCLIOutcome {
            lock.withLock { _invocations.append(arguments) }
            if arguments.first == "pr", let prView {
                return prView
            }
            let cursor = arguments.first { $0.hasPrefix("after=") }
                .map { String($0.dropFirst("after=".count)) }
            return pages[cursor]
                ?? GitHubCLIOutcome(status: 1, stderr: "unscripted cursor \(cursor ?? "nil")")
        }
    }

    // MARK: - Fixtures

    private func prViewJSON(number: Int = 42,
                            extra: String = "") -> String {
        """
        {
          "number": \(number),
          "title": "Read a pull request",
          "body": "Adds the reading side.\\n\\n```swift\\nlet x = 1\\n```",
          "url": "https://github.com/hulryung/damson-ide/pull/\(number)",
          "state": "OPEN",
          "isDraft": false,
          "author": {"login": "hulryung", "avatarUrl": "https://example/a.png"},
          "baseRefName": "main",
          "headRefName": "hulryung/t93-pr-read",
          "headRefOid": "abc1234def",
          "reviewDecision": "CHANGES_REQUESTED",
          "mergeable": "MERGEABLE",
          "mergeStateStatus": "BLOCKED",
          "additions": 120,
          "deletions": 8,
          "changedFiles": 3,
          "createdAt": "2026-08-29T04:00:00Z",
          "updatedAt": "2026-08-29T04:30:00.123Z"\(extra.isEmpty ? "" : ",\n  " + extra)
        }
        """
    }

    private func threadPage(cursor: String?, hasNext: Bool, totalCount: Int,
                            nodes: String) -> String {
        """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{
          "totalCount": \(totalCount),
          "pageInfo": {"hasNextPage": \(hasNext), "endCursor": \(cursor.map { "\"\($0)\"" } ?? "null")},
          "nodes": [\(nodes)]
        }}}}}
        """
    }

    private func threadNode(id: String, path: String, line: String = "10",
                            startLine: String = "null",
                            originalLine: String = "null",
                            originalStartLine: String = "null",
                            outdated: Bool = false, resolved: Bool = false,
                            commentCount: Int = 1,
                            commentTotal: Int? = nil) -> String {
        let comments = (0..<commentCount).map { index in
            """
            {"id":"PRRC_\(id)_\(index)","author":{"login":"reviewer\(index)",
             "avatarUrl":"https://example/r.png"},
             "body":"Please rename this.","createdAt":"2026-08-29T05:0\(index):00Z",
             "includesCreatedEdit":false}
            """
        }.joined(separator: ",")
        return """
        {"id":"\(id)","isResolved":\(resolved),"isOutdated":\(outdated),
         "path":"\(path)","line":\(line),"startLine":\(startLine),
         "originalLine":\(originalLine),"originalStartLine":\(originalStartLine),
         "diffSide":"RIGHT",
         "comments":{"totalCount":\(commentTotal ?? commentCount),"nodes":[\(comments)]}}
        """
    }

    // MARK: - The detail read

    func testDetailIsOneSubprocessAndDecodesTheHeader() async {
        let probe = fixture([(["pr", "view"], ok(prViewJSON()))])
        let result = await service(probe).detail(worktree: cwd)
        guard case .success(let detail) = result else { return XCTFail("expected a detail") }

        XCTAssertEqual(detail.ref.number, 42)
        XCTAssertEqual(detail.ref.repository, "hulryung/damson-ide")
        XCTAssertEqual(detail.state, .open)
        XCTAssertEqual(detail.baseRefName, "main")
        XCTAssertEqual(detail.headRefName, "hulryung/t93-pr-read")
        XCTAssertEqual(detail.reviewDecision, .changesRequested)
        XCTAssertEqual(detail.mergeable, .mergeable)
        XCTAssertEqual(detail.mergeStateStatus, "BLOCKED")
        XCTAssertEqual(detail.additions, 120)
        XCTAssertEqual(detail.deletions, 8)
        XCTAssertEqual(detail.changedFiles, 3)
        XCTAssertEqual(probe.invocations.count, 1, "the common path is one gh")
        XCTAssertEqual(probe.invocations.first?.prefix(2).joined(separator: " "), "pr view")
    }

    /// The repository is read off the URL gh already returned rather than spent
    /// as a second `gh repo view` — that is what keeps the path at one process.
    func testRepositoryComesFromTheUrlGhAlreadySent() {
        XCTAssertEqual(
            PullRequestReadService.repository(fromURL: "https://github.com/o/r/pull/9"), "o/r")
        XCTAssertNil(PullRequestReadService.repository(fromURL: nil))
        XCTAssertNil(PullRequestReadService.repository(fromURL: "https://github.com/only-owner"))
    }

    func testAPullRequestWithNoUrlIsRefusedRatherThanGivenAnInventedRepository() async {
        let probe = fixture([(["pr", "view"], ok(#"{"number": 7, "title": "x"}"#))])
        let result = await service(probe).detail(worktree: cwd)
        guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal.reason, .apiError)
        XCTAssertTrue(refusal.detail.contains("repository"), refusal.detail)
    }

    func testJsonWithoutANumberIsARefusalNotAnEmptyPullRequest() async {
        let probe = fixture([(["pr", "view"],
                              ok(#"{"url": "https://github.com/o/r/pull/1", "title": "x"}"#))])
        let result = await service(probe).detail(worktree: cwd)
        guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal.reason, .apiError)
    }

    // MARK: - Refusal paths

    func testEveryRefusalPathIsNamedAndCarriesARemedy() async {
        let cases: [(GitHubCLIOutcome, PullRequestRefusalReason)] = [
            (failed("no pull requests found for branch \"topic\""), .noPullRequest),
            (failed("To get started with GitHub CLI, please run: gh auth login"), .ghNotAuthenticated),
            (failed("no git remotes found"), .noGitRemote),
            (failed("none of the git remotes point to a known GitHub host"), .unsupportedForge),
            (failed("fatal: not a git repository"), .notAWorktree),
            (failed("HTTP 403: Resource not accessible by integration"), .insufficientPermission),
            (failed("something nobody has ever seen"), .apiError),
            (GitHubCLIOutcome(status: nil, timedOut: true), .ghTimedOut),
            (ok("this is not json"), .apiError),
        ]
        for (outcome, expected) in cases {
            let probe = fixture([(["pr", "view"], outcome)])
            let result = await service(probe).detail(worktree: cwd)
            guard case .failure(let refusal) = result else {
                return XCTFail("expected a refusal for \(expected)")
            }
            XCTAssertEqual(refusal.reason, expected)
            XCTAssertFalse(refusal.headline.isEmpty)
            XCTAssertFalse(refusal.remedy.isEmpty, "\(expected) must offer a next step")
        }
    }

    func testMissingGhIsNamedWithoutLaunchingAnything() async {
        let probe = FixtureGitHubCLI()
        probe.setExecutable(nil)
        let result = await service(probe).read(worktree: cwd)
        guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal.reason, .ghNotInstalled)
        XCTAssertTrue(probe.invocations.isEmpty)
    }

    // MARK: - Review threads: pagination

    func testPaginatesAcrossTwoPagesAndKeepsEveryThread() async {
        let page1 = threadPage(cursor: "CURSOR1", hasNext: true, totalCount: 3,
                               nodes: [threadNode(id: "T1", path: "a.swift", line: "10"),
                                       threadNode(id: "T2", path: "b.swift", line: "20")]
                                   .joined(separator: ","))
        let page2 = threadPage(cursor: nil, hasNext: false, totalCount: 3,
                               nodes: threadNode(id: "T3", path: "a.swift", line: "30"))
        let probe = PagingGitHubCLI(pages: [nil: ok(page1), "CURSOR1": ok(page2)],
                                    prView: ok(prViewJSON()))

        let result = await service(probe).read(worktree: cwd)
        guard case .success(let reading) = result else { return XCTFail("expected a reading") }

        XCTAssertEqual(reading.threads.threads.map(\.id), ["T1", "T2", "T3"])
        XCTAssertEqual(reading.threads.totalCount, 3)
        XCTAssertEqual(reading.threads.pagesFetched, 2)
        XCTAssertEqual(reading.threads.missingThreads, 0)
        XCTAssertTrue(reading.threads.isComplete)
        XCTAssertNil(reading.threads.shortfallSummary, "nothing is missing, so nothing is claimed")
        // One `pr view` plus exactly two graphql pages.
        XCTAssertEqual(probe.invocations.count, 3)
        XCTAssertTrue(probe.invocations[2].contains("after=CURSOR1"),
                      "page two must be requested with page one's cursor")
    }

    /// The rule the whole file exists for: 101 threads must never show as 100
    /// with no mention of the one that is missing.
    func testAPageBudgetShortfallIsCountedNotSilentlyTruncated() async {
        let page1 = threadPage(cursor: "CURSOR1", hasNext: true, totalCount: 101,
                               nodes: threadNode(id: "T1", path: "a.swift"))
        let probe = PagingGitHubCLI(pages: [nil: ok(page1)], prView: ok(prViewJSON()))

        // One page of budget, and GitHub says there are 101 threads.
        let result = await service(probe, maxThreadPages: 1).read(worktree: cwd)
        guard case .success(let reading) = result else { return XCTFail("expected a reading") }

        XCTAssertEqual(reading.threads.threads.count, 1)
        XCTAssertEqual(reading.threads.totalCount, 101)
        XCTAssertEqual(reading.threads.missingThreads, 100)
        XCTAssertFalse(reading.threads.isComplete)
        let summary = reading.threads.shortfallSummary
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("100"), summary ?? "")
        XCTAssertTrue(summary!.contains("101"), summary ?? "")
    }

    func testRepliesBeyondOnePageAreCountedPerThread() async {
        let page = threadPage(cursor: nil, hasNext: false, totalCount: 1,
                              nodes: threadNode(id: "T1", path: "a.swift",
                                                commentCount: 2, commentTotal: 7))
        let probe = PagingGitHubCLI(pages: [nil: ok(page)], prView: ok(prViewJSON()))
        let result = await service(probe).read(worktree: cwd)
        guard case .success(let reading) = result else { return XCTFail("expected a reading") }

        XCTAssertEqual(reading.threads.truncatedComments["T1"], 5)
        XCTAssertFalse(reading.threads.isComplete)
        XCTAssertTrue(reading.threads.shortfallSummary?.contains("5 older") ?? false,
                      reading.threads.shortfallSummary ?? "nil")
    }

    /// A later page that fails must not throw away the threads already in hand.
    func testAFailingSecondPageKeepsThePagesAlreadyReadAndSaysWhatIsMissing() async {
        let page1 = threadPage(cursor: "CURSOR1", hasNext: true, totalCount: 4,
                               nodes: threadNode(id: "T1", path: "a.swift"))
        let probe = PagingGitHubCLI(pages: [nil: ok(page1),
                                            "CURSOR1": failed("HTTP 502: Bad gateway")],
                                    prView: ok(prViewJSON()))
        let result = await service(probe).read(worktree: cwd)
        guard case .success(let reading) = result else { return XCTFail("expected a reading") }

        XCTAssertEqual(reading.threads.threads.map(\.id), ["T1"])
        XCTAssertEqual(reading.threads.missingThreads, 3)
        XCTAssertNil(reading.threadsRefusal, "a partial page is a shortfall, not a dead read")
    }

    // MARK: - Review threads: shape

    /// The finding this task turned on: an outdated thread comes back with
    /// `line: null`, and its anchor survives only in `originalLine`.
    func testAnOutdatedThreadSurvivesWithTheLineItWasWrittenAgainst() async {
        let page = threadPage(cursor: nil, hasNext: false, totalCount: 2, nodes: [
            threadNode(id: "OLD", path: "a.swift", line: "null", startLine: "null",
                       originalLine: "47", outdated: true, resolved: true),
            threadNode(id: "NEW", path: "a.swift", line: "12", originalLine: "12"),
        ].joined(separator: ","))
        let probe = PagingGitHubCLI(pages: [nil: ok(page)], prView: ok(prViewJSON()))

        let result = await service(probe).read(worktree: cwd)
        guard case .success(let reading) = result else { return XCTFail("expected a reading") }

        XCTAssertEqual(reading.threads.threads.count, 2, "an outdated thread is never dropped")
        let outdated = reading.threads.threads.first { $0.id == "OLD" }
        XCTAssertNotNil(outdated)
        XCTAssertTrue(outdated!.isOutdated)
        XCTAssertEqual(outdated!.line, 47, "the anchor falls back to originalLine")
        XCTAssertEqual(outdated!.anchorDescription, "was line 47",
                       "past tense, because that line is not in the head any more")
        XCTAssertEqual(reading.outdatedThreadCount, 1)

        let current = reading.threads.threads.first { $0.id == "NEW" }
        XCTAssertEqual(current?.anchorDescription, "line 12")
    }

    func testAnchorWordingCoversRangesSidesAndFileLevelThreads() {
        func thread(line: Int?, startLine: Int? = nil, side: DiffSide = .right,
                    outdated: Bool = false) -> ReviewThread {
            ReviewThread(id: "T", path: "a", line: line, startLine: startLine,
                         diffSide: side, isResolved: false, isOutdated: outdated, comments: [])
        }
        XCTAssertEqual(thread(line: 5).anchorDescription, "line 5")
        XCTAssertEqual(thread(line: 9, startLine: 5).anchorDescription, "lines 5–9")
        XCTAssertEqual(thread(line: 5, side: .left).anchorDescription, "line 5 (before)")
        XCTAssertEqual(thread(line: nil).anchorDescription, "whole file")
        XCTAssertEqual(thread(line: nil, outdated: true).anchorDescription,
                       "whole file, outdated")
        XCTAssertEqual(thread(line: 9, startLine: 9).anchorDescription, "line 9",
                       "a one-line range is not a range")
    }

    func testThreadsGroupByFileAndOrderByAnchor() {
        let reading = ReviewThreadReading(threads: [
            ReviewThread(id: "b", path: "z.swift", line: 5, isResolved: false,
                         isOutdated: false, comments: []),
            ReviewThread(id: "a", path: "a.swift", line: 30, isResolved: false,
                         isOutdated: false, comments: []),
            ReviewThread(id: "c", path: "a.swift", line: nil, isResolved: false,
                         isOutdated: false, comments: []),
            ReviewThread(id: "d", path: "a.swift", line: 10, isResolved: false,
                         isOutdated: true, comments: []),
        ], totalCount: 4)

        let groups = reading.byFile
        XCTAssertEqual(groups.map(\.path), ["a.swift", "z.swift"])
        XCTAssertEqual(groups[0].threads.map(\.id), ["c", "d", "a"],
                       "file-level first, then by line; outdated threads sort like any other")
    }

    /// A GraphQL error must never decode to zero threads: "no review threads" is
    /// a claim, and this would be making it without knowing.
    func testAGraphqlErrorIsARefusalNotAnEmptyThreadList() {
        let body: [String: Any] = [
            "data": ["repository": NSNull()],
            "errors": [["message": "Could not resolve to a Repository with the name 'o/r'."]],
        ]
        let decoded = ReviewThreadQuery.decodePage(body)
        guard case .failure(let refusal) = decoded else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal.reason, .apiError)
        XCTAssertTrue(refusal.detail.contains("Could not resolve"), refusal.detail)
    }

    func testThreadsThatFailEntirelyLeaveTheRestOfTheReadingIntact() async {
        let probe = PagingGitHubCLI(pages: [nil: failed("HTTP 502: Bad gateway")],
                                    prView: ok(prViewJSON()))
        let result = await service(probe).read(worktree: cwd)
        guard case .success(let reading) = result else {
            return XCTFail("the detail read succeeded, so the reading must survive")
        }
        XCTAssertEqual(reading.detail.ref.number, 42)
        XCTAssertEqual(reading.threadsRefusal?.reason, .apiError)
        XCTAssertFalse(reading.threadsRefusal?.remedy.isEmpty ?? true)
        XCTAssertTrue(reading.threads.threads.isEmpty)
    }

    func testAThreadWithNoIdIsDroppedRatherThanGivenOne() {
        XCTAssertNil(ReviewThreadQuery.thread(from: ["path": "a.swift", "line": 3]))
        XCTAssertNil(ReviewThreadQuery.comment(from: ["body": "hi"]))
    }

    func testTheQueryAsksForTheFieldsAnOutdatedThreadNeeds() {
        let document = ReviewThreadQuery.document()
        for field in ["originalLine", "originalStartLine", "isOutdated", "totalCount",
                      "hasNextPage", "endCursor", "diffSide"] {
            XCTAssertTrue(document.contains(field), "query must ask for \(field)")
        }
        // The first page must not send an empty cursor; GitHub rejects one.
        let first = ReviewThreadQuery.arguments(owner: "o", name: "r", number: 1, after: nil)
        XCTAssertFalse(first.contains { $0.hasPrefix("after=") })
        let second = ReviewThreadQuery.arguments(owner: "o", name: "r", number: 1, after: "C")
        XCTAssertTrue(second.contains("after=C"))
        XCTAssertTrue(second.contains("-F"), "number must reach GraphQL as an Int")
        XCTAssertTrue(second.contains("number=1"))
    }

    // MARK: - Conversation

    private func conversationJSON() -> String {
        let extra = """
        "comments": [
          {"id":"IC_1","author":{"login":"andy"},"body":"Is this ready?",
           "createdAt":"2026-08-29T06:00:00Z","includesCreatedEdit":true}
        ],
        "reviews": [
          {"id":"PRR_1","author":{"login":"steiza"},"body":"Looks workable.",
           "submittedAt":"2026-08-29T05:00:00Z","state":"APPROVED",
           "includesCreatedEdit":false},
          {"id":"PRR_2","author":{"login":"will"},"body":"Needs tests.",
           "submittedAt":"2026-08-29T07:00:00Z","state":"CHANGES_REQUESTED",
           "includesCreatedEdit":false},
          {"id":"PRR_3","author":{"login":"will"},"body":"",
           "submittedAt":"2026-08-29T07:30:00Z","state":"COMMENTED",
           "includesCreatedEdit":false},
          {"id":"PRR_4","author":{"login":"nobody"},"body":"draft, unsent",
           "submittedAt":null,"state":"PENDING","includesCreatedEdit":false},
          {"id":"PRR_5","author":{"login":"dana"},"body":"",
           "submittedAt":"2026-08-29T08:00:00Z","state":"APPROVED",
           "includesCreatedEdit":false}
        ],
        "latestReviews": [
          {"id":"","author":{"login":"will"},"body":"Needs tests.",
           "submittedAt":"2026-08-29T07:00:00Z","state":"CHANGES_REQUESTED"},
          {"id":"","author":{"login":"dana"},"body":"",
           "submittedAt":"2026-08-29T08:00:00Z","state":"APPROVED"}
        ],
        "files": [
          {"path":"a.swift","additions":10,"deletions":2,"changeType":"MODIFIED"},
          {"path":"b.swift","additions":1,"deletions":0,"changeType":"ADDED"}
        ]
        """
        return prViewJSON(extra: extra)
    }

    func testAReviewLandsInTheConversationWithItsVerdictAttached() async {
        let probe = PagingGitHubCLI(
            pages: [nil: ok(threadPage(cursor: nil, hasNext: false, totalCount: 0, nodes: ""))],
            prView: ok(conversationJSON()))
        let result = await service(probe).read(worktree: cwd)
        guard case .success(let reading) = result else { return XCTFail("expected a reading") }

        let approved = reading.conversation.first { $0.id == "PRR_1" }
        XCTAssertNotNil(approved)
        XCTAssertEqual(approved?.comment.reviewVerdict, .approve,
                       "the body and the verdict travel together")
        XCTAssertEqual(approved?.reviewState, "APPROVED")
        XCTAssertTrue(approved?.isReview ?? false)

        let changes = reading.conversation.first { $0.id == "PRR_2" }
        XCTAssertEqual(changes?.comment.reviewVerdict, .requestChanges)

        let comment = reading.conversation.first { $0.id == "IC_1" }
        XCTAssertNil(comment?.comment.reviewVerdict, "a timeline comment has no verdict")
        XCTAssertEqual(comment?.origin, .timelineComment)
        XCTAssertTrue(comment?.comment.isEdited ?? false)
    }

    func testTheConversationIsChronologicalAcrossBothSources() async {
        let probe = PagingGitHubCLI(
            pages: [nil: ok(threadPage(cursor: nil, hasNext: false, totalCount: 0, nodes: ""))],
            prView: ok(conversationJSON()))
        guard case .success(let reading) = await service(probe).read(worktree: cwd) else {
            return XCTFail("expected a reading")
        }
        // 05:00 review, 06:00 comment, 07:00 review, 08:00 review.
        XCTAssertEqual(reading.conversation.map(\.id), ["PRR_1", "IC_1", "PRR_2", "PRR_5"])
    }

    func testUnsentAndContentlessReviewsStayOutOfTheConversation() async {
        let probe = PagingGitHubCLI(
            pages: [nil: ok(threadPage(cursor: nil, hasNext: false, totalCount: 0, nodes: ""))],
            prView: ok(conversationJSON()))
        guard case .success(let reading) = await service(probe).read(worktree: cwd) else {
            return XCTFail("expected a reading")
        }
        let ids = reading.conversation.map(\.id)
        XCTAssertFalse(ids.contains("PRR_4"), "a PENDING review has not been submitted")
        XCTAssertFalse(ids.contains("PRR_3"),
                       "an empty COMMENTED review is the wrapper around line comments")
        XCTAssertTrue(ids.contains("PRR_5"),
                      "an empty APPROVAL is kept — there the verdict is the message")
    }

    /// `latestReviews` comes back with empty ids, so "still standing" has to be
    /// matched on author plus submission time.
    func testASupersededVerdictIsMarkedEvenThoughLatestReviewsHasNoIds() async {
        let probe = PagingGitHubCLI(
            pages: [nil: ok(threadPage(cursor: nil, hasNext: false, totalCount: 0, nodes: ""))],
            prView: ok(conversationJSON()))
        guard case .success(let reading) = await service(probe).read(worktree: cwd) else {
            return XCTFail("expected a reading")
        }
        XCTAssertTrue(reading.conversation.first { $0.id == "PRR_2" }?.isCurrentReview ?? false,
                      "will's changes-requested is still their standing verdict")
        XCTAssertFalse(reading.conversation.first { $0.id == "PRR_1" }?.isCurrentReview ?? true,
                       "steiza's approval is not in latestReviews, so it does not stand")
    }

    func testDismissedKeepsGithubsWordAndTakesNoWritableVerdict() {
        XCTAssertNil(PullRequestConversation.verdict(forReviewState: "DISMISSED"))
        XCTAssertNil(PullRequestConversation.verdict(forReviewState: "SOMETHING_NEW"))
        XCTAssertEqual(PullRequestConversation.verdict(forReviewState: "approved"), .approve)
        XCTAssertEqual(PullRequestConversation.verdict(forReviewState: "COMMENTED"), .comment)

        let entry = PullRequestConversation.reviewEntry(
            from: ["id": "PRR_9", "state": "DISMISSED", "body": "never mind",
                   "submittedAt": "2026-08-29T09:00:00Z"],
            currentKeys: [])
        XCTAssertEqual(entry?.reviewState, "DISMISSED")
        XCTAssertNil(entry?.comment.reviewVerdict,
                     "there is no gh flag for dismissed, so no verdict is invented")
    }

    // MARK: - Files

    func testFilesDecodeWithTheirDiffstat() async {
        let probe = PagingGitHubCLI(
            pages: [nil: ok(threadPage(cursor: nil, hasNext: false, totalCount: 0, nodes: ""))],
            prView: ok(conversationJSON()))
        guard case .success(let reading) = await service(probe).read(worktree: cwd) else {
            return XCTFail("expected a reading")
        }
        XCTAssertEqual(reading.files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(reading.files.first?.additions, 10)
        XCTAssertEqual(reading.files.first?.deletions, 2)
        // changedFiles is 3 in the fixture but only two files came back.
        XCTAssertEqual(reading.missingFiles, 1, "a short file list is stated, not hidden")
    }

    func testAFileWithNoPathIsDropped() {
        let files = PullRequestReadService.files(from: [
            "files": [["additions": 1], ["path": "", "additions": 2],
                      ["path": "ok.swift", "additions": 3, "deletions": 4]],
        ])
        XCTAssertEqual(files.map(\.path), ["ok.swift"])
    }

    // MARK: - Absent optional fields

    /// `--json` returns exactly the fields asked for, and a pull request can
    /// legitimately have no body, no author, no reviews and no files. None of
    /// that may crash, and none of it may become a reassuring default.
    func testAbsentOptionalFieldsDecodeWithoutCrashingOrInventing() async {
        let sparse = """
        {"number": 3, "url": "https://github.com/o/r/pull/3"}
        """
        let probe = PagingGitHubCLI(
            pages: [nil: ok(threadPage(cursor: nil, hasNext: false, totalCount: 0, nodes: ""))],
            prView: ok(sparse))
        guard case .success(let reading) = await service(probe).read(worktree: cwd) else {
            return XCTFail("expected a reading")
        }
        XCTAssertEqual(reading.detail.state, .unknown, "absent state is unknown, never open")
        XCTAssertEqual(reading.detail.mergeable, .unknown)
        XCTAssertNil(reading.detail.author)
        XCTAssertEqual(reading.detail.body, "")
        XCTAssertTrue(reading.conversation.isEmpty)
        XCTAssertTrue(reading.files.isEmpty)
        XCTAssertEqual(reading.missingFiles, 0)
        XCTAssertEqual(reading.threads.totalCount, 0)
        XCTAssertNil(reading.threads.shortfallSummary)
    }

    func testAThreadNodeWithEveryOptionalFieldAbsentStillDecodes() {
        let thread = ReviewThreadQuery.thread(from: ["id": "T1"])
        XCTAssertNotNil(thread)
        XCTAssertEqual(thread?.path, "")
        XCTAssertNil(thread?.line)
        XCTAssertEqual(thread?.diffSide, .right, "gh's own default side")
        XCTAssertFalse(thread?.isResolved ?? true)
        XCTAssertFalse(thread?.isOutdated ?? true)
        XCTAssertTrue(thread?.comments.isEmpty ?? false)
    }

    func testACommentWithNoTimestampIsTheEpochNotNow() {
        let comment = ReviewThreadQuery.comment(from: ["id": "C1", "body": "hi"])
        XCTAssertEqual(comment?.createdAt, Date(timeIntervalSince1970: 0),
                       "a visibly wrong date beats an invisibly wrong 'just now'")
    }

    // MARK: - Staleness

    func testEveryReadingCarriesWhenItWasTaken() async {
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = PagingGitHubCLI(
            pages: [nil: ok(threadPage(cursor: nil, hasNext: false, totalCount: 0, nodes: ""))],
            prView: ok(prViewJSON()))
        guard case .success(let reading) = await service(probe).read(worktree: cwd) else {
            return XCTFail("expected a reading")
        }
        XCTAssertEqual(reading.observedAt, taken)
        XCTAssertEqual(reading.headRefOid, "abc1234def")
    }

    /// Two reads run `gh` twice. There is no cache to hit, which is the point:
    /// nothing local can know when a pull request stopped being true.
    func testEveryReadAsksGithubAgain() async {
        let probe = fixture([(["pr", "view"], ok(prViewJSON()))])
        let read = service(probe)
        _ = await read.detail(worktree: cwd)
        _ = await read.detail(worktree: cwd)
        XCTAssertEqual(probe.invocations.count, 2)
    }

    // MARK: - Markdown

    func testFencedCodeSurvivesAsCodeRatherThanBecomingProse() {
        let blocks = PullRequestMarkdown.blocks("""
        Try this:

        ```swift
        let x = 1

        let y = 2
        ```

        Done.
        """)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph("Try this:"))
        XCTAssertEqual(blocks[1], .code(language: "swift", text: "let x = 1\n\nlet y = 2"),
                       "a blank line inside a fence does not end the block")
        XCTAssertEqual(blocks[2], .paragraph("Done."))
    }

    func testAnUnterminatedFenceKeepsTheRestOfTheCommentInstead() {
        let blocks = PullRequestMarkdown.blocks("```\nno closing fence\nmore")
        XCTAssertEqual(blocks, [.code(language: nil, text: "no closing fence\nmore")])
    }

    func testHeadingsListsQuotesAndRules() {
        let blocks = PullRequestMarkdown.blocks("""
        ## Why

        - first
        - [ ] todo
        - [x] done
        2. second

        > quoted
        > still quoted

        ---
        #notaheading
        """)
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "Why"))
        XCTAssertEqual(blocks[1], .listItem(marker: "•", text: "first", depth: 0))
        XCTAssertEqual(blocks[2], .listItem(marker: "☐", text: "todo", depth: 0))
        XCTAssertEqual(blocks[3], .listItem(marker: "☑", text: "done", depth: 0))
        XCTAssertEqual(blocks[4], .listItem(marker: "2.", text: "second", depth: 0),
                       "an ordered list keeps the author's own numbering")
        XCTAssertEqual(blocks[5], .quote("quoted\nstill quoted"))
        XCTAssertEqual(blocks[6], .rule)
        XCTAssertEqual(blocks[7], .paragraph("#notaheading"),
                       "ATX needs a space; a hashtag is prose")
    }

    func testNewlinesInsideAParagraphAreKept() {
        // GitHub renders a single newline in a comment as a line break, so a
        // pasted stack trace must not be re-wrapped into one run of prose.
        XCTAssertEqual(PullRequestMarkdown.blocks("line one\nline two"),
                       [.paragraph("line one\nline two")])
    }

    func testCarriageReturnsFromGithubDoNotLeakIntoTheText() {
        // Live bodies come back CRLF-terminated.
        XCTAssertEqual(PullRequestMarkdown.blocks("a\r\n\r\nb"),
                       [.paragraph("a"), .paragraph("b")])
    }

    func testATableIsKeptAsRowsSoItCanBeRenderedMonospaced() {
        let blocks = PullRequestMarkdown.blocks("""
        | a | b |
        |---|---|
        | 1 | 2 |

        after
        """)
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let rows) = blocks[0] else { return XCTFail("expected a table") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(blocks[1], .paragraph("after"))
    }

    func testAStrayPipeInProseIsNotATable() {
        XCTAssertEqual(PullRequestMarkdown.blocks("use a | b in the shell"),
                       [.paragraph("use a | b in the shell")])
    }

    func testAnEmptyBodyProducesNoBlocks() {
        XCTAssertTrue(PullRequestMarkdown.blocks("").isEmpty)
        XCTAssertTrue(PullRequestMarkdown.blocks("   \n\n  ").isEmpty)
    }

    /// Found against a live pull request: GitHub's PR template is mostly HTML
    /// comments, and GitHub hides them. Rendering them would put three
    /// paragraphs of template instructions in a body the author never wrote.
    func testHtmlCommentsAreHiddenExactlyAsGithubHidesThem() {
        let blocks = PullRequestMarkdown.blocks("""
        <!--
        Thank you for contributing!
        Write for a reviewer who has not worked here.
        -->
        Real content.
        <!-- inline --> and more.
        """)
        XCTAssertEqual(blocks, [.paragraph("Real content.\n and more.")])
    }

    func testAnUnclosedHtmlCommentSwallowsTheRestRatherThanLeakingMarkup() {
        XCTAssertEqual(PullRequestMarkdown.blocks("keep me\n<!-- never closed\nhidden"),
                       [.paragraph("keep me")])
    }

    /// A comment shown *as an example* inside a fence is content, not chrome.
    func testHtmlCommentsInsideCodeFencesSurvive() {
        let blocks = PullRequestMarkdown.blocks("```html\n<!-- example -->\n```")
        XCTAssertEqual(blocks, [.code(language: "html", text: "<!-- example -->")])
    }

    /// The one HTML rule: only comments are special. A `<details>` block is
    /// content and is left verbatim rather than half-stripped into nonsense.
    func testOtherHtmlIsLeftVerbatimRatherThanHalfStripped() {
        let blocks = PullRequestMarkdown.blocks("<details><summary>Logs</summary>\n\nbody\n</details>")
        XCTAssertEqual(blocks.first, .paragraph("<details><summary>Logs</summary>"))
    }
}
