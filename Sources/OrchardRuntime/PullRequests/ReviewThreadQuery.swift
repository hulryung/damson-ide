import Foundation

/// Line-anchored review threads, which `gh pr view --json` cannot give us.
///
/// Verified against gh 2.98.0: `--json comments` returns issue comments
/// (`IC_…` ids, no `path`, no `line`) and `--json reviews` returns review
/// *bodies* only. Neither carries a single line anchor. The threads live behind
/// GraphQL's `reviewThreads` connection, so that is what this asks for.
///
/// The connection is paginated and this file's whole reason to exist is that the
/// pagination is honest. A pull request with 101 threads must not quietly show
/// 100. Every reading therefore carries GitHub's own `totalCount` beside the
/// threads it actually fetched, so a shortfall is arithmetic rather than a guess.

// MARK: - What a reading saw, and what it did not

/// One reading of a pull request's review threads.
///
/// `threads` is what we have; `totalCount` is what GitHub says exists. When they
/// disagree the difference is named in `missingThreads` and rendered — never
/// swallowed. The same discipline applies one level down: a thread with more
/// comments than one page holds records the remainder in `truncatedComments`
/// rather than ending on a comment that looks like the last word.
public struct ReviewThreadReading: Equatable, Sendable {
    public var threads: [ReviewThread]
    /// How many review threads GitHub reports on this pull request.
    public var totalCount: Int
    /// Threads GitHub has that this reading does not carry. Non-zero only when
    /// the page budget ran out before the connection did.
    public var missingThreads: Int
    /// Thread id → comments GitHub has beyond the ones fetched for that thread.
    public var truncatedComments: [String: Int]
    /// How many GraphQL round trips this reading cost. Asserted in tests, and
    /// the number that proves pagination happened rather than being claimed.
    public var pagesFetched: Int

    public init(threads: [ReviewThread], totalCount: Int, missingThreads: Int = 0,
                truncatedComments: [String: Int] = [:], pagesFetched: Int = 1) {
        self.threads = threads
        self.totalCount = totalCount
        self.missingThreads = missingThreads
        self.truncatedComments = truncatedComments
        self.pagesFetched = pagesFetched
    }

    public static let empty = ReviewThreadReading(threads: [], totalCount: 0, pagesFetched: 0)

    /// True when every thread, and every comment in every thread, was fetched.
    public var isComplete: Bool { missingThreads == 0 && truncatedComments.isEmpty }

    /// One sentence naming exactly what is missing, or nil when nothing is.
    ///
    /// This is the string the pane renders. It exists so that "incomplete" can
    /// never be communicated by an absence — there is always a sentence, and it
    /// always carries the count.
    public var shortfallSummary: String? {
        var parts: [String] = []
        if missingThreads > 0 {
            parts.append("\(missingThreads) of \(totalCount) review "
                + (totalCount == 1 ? "thread is" : "threads are") + " not shown")
        }
        if !truncatedComments.isEmpty {
            let hidden = truncatedComments.values.reduce(0, +)
            let threadWord = truncatedComments.count == 1 ? "thread" : "threads"
            parts.append("\(hidden) older \(hidden == 1 ? "reply is" : "replies are") "
                + "not shown in \(truncatedComments.count) \(threadWord)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + "."
    }

    /// Threads grouped by file, each group's threads ordered by their anchor.
    ///
    /// Outdated threads are grouped and sorted exactly like current ones. They
    /// are never filtered out here, and there is deliberately no parameter that
    /// would let a caller ask for that.
    public var byFile: [(path: String, threads: [ReviewThread])] {
        Dictionary(grouping: threads, by: \.path)
            .map { (path: $0.key, threads: $0.value.sorted(by: Self.anchorOrder)) }
            .sorted { $0.path < $1.path }
    }

    /// A thread with no line anchor (a file-level comment) sorts before the
    /// line-anchored ones rather than being dropped for lacking a sort key.
    static func anchorOrder(_ a: ReviewThread, _ b: ReviewThread) -> Bool {
        switch (a.line, b.line) {
        case (nil, nil): return a.id < b.id
        case (nil, _): return true
        case (_, nil): return false
        case (let x?, let y?): return x == y ? a.id < b.id : x < y
        }
    }
}

// MARK: - Reading a thread's anchor

public extension ReviewThread {
    /// The thread's line anchor, in words.
    ///
    /// An outdated thread's number is where the comment was *written*
    /// (`originalLine`), because the line it pointed at is not in the head any
    /// more. Saying "line 47" for a line that no longer exists would be a quiet
    /// lie, so the phrasing goes into the past tense instead: same number, told
    /// truthfully. Lives here rather than in the view so it can be tested.
    var anchorDescription: String {
        guard let line else {
            return isOutdated ? "whole file, outdated" : "whole file"
        }
        let range: String
        if let startLine, startLine != line {
            range = "lines \(startLine)–\(line)"
        } else {
            range = "line \(line)"
        }
        let side = diffSide == .left ? " (before)" : ""
        return isOutdated ? "was \(range)\(side)" : "\(range)\(side)"
    }
}

// MARK: - The query

/// Fetches every review thread on a pull request, one page at a time.
public struct ReviewThreadQuery: Sendable {
    /// GitHub's ceiling for a connection page is 100; asking for it means the
    /// overwhelming majority of pull requests cost exactly one round trip.
    public static let threadPageSize = 100
    /// Comments within a thread. A review thread with more than 50 replies is
    /// vanishingly rare, and the remainder is counted rather than dropped.
    public static let commentPageSize = 50
    /// A hard stop on round trips, so a pathological pull request cannot hold a
    /// pane open indefinitely. Hitting it is reported as missing threads — the
    /// budget bounds the *cost*, never the honesty.
    public static let maxPages = 20

    public let gateway: GitHubPRGateway
    public let maxPages: Int

    public init(gateway: GitHubPRGateway, maxPages: Int = ReviewThreadQuery.maxPages) {
        self.gateway = gateway
        self.maxPages = max(1, maxPages)
    }

    /// The GraphQL document, built once per call so the page sizes are visible in
    /// the query text rather than implied by the decoder.
    ///
    /// `originalLine` / `originalStartLine` are here for a reason found by
    /// reading live data: an **outdated** thread comes back with `line: null` and
    /// `startLine: null`, because the line it was written against no longer
    /// exists in the head. The anchor it *was* written against survives in
    /// `originalLine`. Without these two fields an outdated thread renders with
    /// no line at all — which is "shown but not really", and the task's rule is
    /// that an outdated thread is shown and marked.
    public static func document(threadPageSize: Int = ReviewThreadQuery.threadPageSize,
                                commentPageSize: Int = ReviewThreadQuery.commentPageSize) -> String {
        """
        query($owner:String!,$name:String!,$number:Int!,$after:String){
          repository(owner:$owner,name:$name){
            pullRequest(number:$number){
              reviewThreads(first:\(threadPageSize),after:$after){
                totalCount
                pageInfo{hasNextPage endCursor}
                nodes{
                  id isResolved isOutdated path line startLine
                  originalLine originalStartLine diffSide
                  comments(first:\(commentPageSize)){
                    totalCount
                    nodes{ id author{login avatarUrl} body createdAt includesCreatedEdit }
                  }
                }
              }
            }
          }
        }
        """
    }

    /// argv for one page.
    ///
    /// `owner` and `name` go in with `-f` (always a string) and `number` with
    /// `-F` (must reach GraphQL as an Int, since the variable is declared
    /// `Int!`). On the first page `after` is omitted entirely: the variable is
    /// declared nullable, so an absent value is `null`, whereas passing an empty
    /// string would be a cursor GitHub rejects.
    public static func arguments(owner: String, name: String, number: Int,
                                 after: String?) -> [String] {
        var argv = ["api", "graphql",
                    "-f", "query=" + document(),
                    "-f", "owner=" + owner,
                    "-f", "name=" + name,
                    "-F", "number=\(number)"]
        if let after, !after.isEmpty { argv += ["-f", "after=" + after] }
        return argv
    }

    /// Fetch every review thread, following `pageInfo.endCursor` until GitHub
    /// says there is no next page or the page budget runs out.
    public func fetch(owner: String, name: String, number: Int,
                      cwd: URL) async -> Result<ReviewThreadReading, PullRequestRefusal> {
        var threads: [ReviewThread] = []
        var truncated: [String: Int] = [:]
        var cursor: String?
        var totalCount = 0
        var pages = 0

        while pages < maxPages {
            let argv = Self.arguments(owner: owner, name: name, number: number, after: cursor)
            switch await gateway.json(argv, cwd: cwd) {
            case .failure(let refusal):
                // A first page that fails is a failed reading. A *later* page that
                // fails is not: we already hold real threads, and throwing them
                // away to report a clean error would lose more than it explains.
                // The shortfall is recorded and rendered instead.
                guard pages > 0 else { return .failure(refusal) }
                return .success(ReviewThreadReading(
                    threads: threads, totalCount: totalCount,
                    missingThreads: max(0, totalCount - threads.count),
                    truncatedComments: truncated, pagesFetched: pages))
            case .success(let json):
                switch Self.decodePage(json) {
                case .failure(let refusal):
                    guard pages > 0 else { return .failure(refusal) }
                    return .success(ReviewThreadReading(
                        threads: threads, totalCount: totalCount,
                        missingThreads: max(0, totalCount - threads.count),
                        truncatedComments: truncated, pagesFetched: pages))
                case .success(let page):
                    pages += 1
                    totalCount = page.totalCount
                    threads += page.threads
                    truncated.merge(page.truncatedComments) { current, _ in current }
                    guard page.hasNextPage, let next = page.endCursor, !next.isEmpty else {
                        // Ran to the end of the connection. Anything GitHub counted
                        // that we did not collect is still reported: a totalCount we
                        // cannot account for is a shortfall even without a next page.
                        return .success(ReviewThreadReading(
                            threads: threads, totalCount: max(totalCount, threads.count),
                            missingThreads: max(0, totalCount - threads.count),
                            truncatedComments: truncated, pagesFetched: pages))
                    }
                    cursor = next
                }
            }
        }

        // Budget exhausted with pages still to go. Say how many are missing.
        return .success(ReviewThreadReading(
            threads: threads, totalCount: max(totalCount, threads.count),
            missingThreads: max(0, totalCount - threads.count),
            truncatedComments: truncated, pagesFetched: pages))
    }

    // MARK: - Decoding

    public struct Page: Equatable, Sendable {
        public var threads: [ReviewThread]
        public var totalCount: Int
        public var hasNextPage: Bool
        public var endCursor: String?
        public var truncatedComments: [String: Int]
    }

    /// One GraphQL page → threads.
    ///
    /// A GraphQL `errors` array is a refusal even when it arrives beside data.
    /// `gh` exits non-zero in that case and the gateway classifies it, so this is
    /// belt and braces — but the failure it guards against is the one that would
    /// hurt most: an error silently decoding to zero threads and rendering as
    /// "no review threads on this pull request".
    public static func decodePage(_ json: [String: Any]) -> Result<Page, PullRequestRefusal> {
        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let message = errors.compactMap { $0["message"] as? String }
                .first ?? "GitHub returned a GraphQL error with no message."
            return .failure(PullRequestRefusal(.apiError, detail: message))
        }
        guard let data = json["data"] as? [String: Any] else {
            return .failure(PullRequestRefusal(.apiError,
                detail: "GraphQL response had no data object."))
        }
        // `repository: null` and `pullRequest: null` are how GraphQL says "not
        // found" when it also returned an errors array we have already checked.
        // Reaching here with either null means a shape we do not understand.
        guard let repository = data["repository"] as? [String: Any] else {
            return .failure(PullRequestRefusal(.apiError,
                detail: "GraphQL returned no repository for this query."))
        }
        guard let pullRequest = repository["pullRequest"] as? [String: Any] else {
            return .failure(PullRequestRefusal(.noPullRequest,
                detail: "GraphQL returned no pull request for that number."))
        }
        guard let connection = pullRequest["reviewThreads"] as? [String: Any] else {
            return .failure(PullRequestRefusal(.apiError,
                detail: "GraphQL returned a pull request with no reviewThreads connection."))
        }

        let nodes = connection["nodes"] as? [[String: Any]] ?? []
        let pageInfo = connection["pageInfo"] as? [String: Any] ?? [:]
        var threads: [ReviewThread] = []
        var truncated: [String: Int] = [:]
        for node in nodes {
            guard let thread = self.thread(from: node) else { continue }
            threads.append(thread)
            let comments = node["comments"] as? [String: Any] ?? [:]
            let total = comments["totalCount"] as? Int ?? thread.comments.count
            if total > thread.comments.count {
                truncated[thread.id] = total - thread.comments.count
            }
        }
        return .success(Page(
            threads: threads,
            totalCount: connection["totalCount"] as? Int ?? threads.count,
            hasNextPage: pageInfo["hasNextPage"] as? Bool ?? false,
            endCursor: pageInfo["endCursor"] as? String,
            truncatedComments: truncated))
    }

    /// One `reviewThreads.nodes[]` entry.
    ///
    /// The anchor rule: `line` when the thread still points at a live line, and
    /// `originalLine` when it does not. `isOutdated` travels with it, so a
    /// caller always knows whether the number it is holding is where the thread
    /// is now or where it was written. Both nil is a real shape too — a
    /// file-level comment — and stays nil rather than being invented as line 1.
    public static func thread(from node: [String: Any]) -> ReviewThread? {
        guard let id = node["id"] as? String, !id.isEmpty else { return nil }
        let comments = (node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return ReviewThread(
            id: id,
            path: node["path"] as? String ?? "",
            line: node["line"] as? Int ?? node["originalLine"] as? Int,
            startLine: node["startLine"] as? Int ?? node["originalStartLine"] as? Int,
            diffSide: DiffSide(gh: node["diffSide"] as? String),
            isResolved: node["isResolved"] as? Bool ?? false,
            isOutdated: node["isOutdated"] as? Bool ?? false,
            comments: comments.compactMap(comment(from:)))
    }

    /// One review comment. A comment with no id is dropped rather than given a
    /// synthesised one: an id we invented would collide across readings and make
    /// a thread look like it changed when it did not.
    public static func comment(from node: [String: Any]) -> PullRequestComment? {
        guard let id = node["id"] as? String, !id.isEmpty else { return nil }
        return PullRequestComment(
            id: id,
            author: PullRequestDecoder.actor(node["author"]),
            body: node["body"] as? String ?? "",
            // GraphQL always sends createdAt on a comment. If it ever does not,
            // the epoch is a visibly wrong date; `Date()` would be an invisibly
            // wrong one that reads as "just now".
            createdAt: PullRequestDecoder.date(node["createdAt"]) ?? Date(timeIntervalSince1970: 0),
            isEdited: node["includesCreatedEdit"] as? Bool ?? false,
            reviewVerdict: nil)
    }
}
