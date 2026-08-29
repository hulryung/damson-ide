import Foundation

/// Reading a pull request: its detail, its conversation, its line-anchored review
/// threads, and its files.
///
/// **There is no cache here, and there is nowhere to put one.** T87's rule is
/// that a value nobody is watching is a value that can quietly become a lie, and
/// nothing watches GitHub — a review lands, a thread resolves, a check flips,
/// and no local event fires. So this type is a `struct` with no `var` state: a
/// cache is not merely absent, it is unrepresentable. What callers get instead
/// is `observedAt` on every reading, so a panel showing a two-minute-old answer
/// says so rather than presenting it as now.

// MARK: - The conversation

/// One entry in the chronological conversation.
///
/// A submitted review and a timeline comment are both "somebody said something",
/// which is why they merge into one list, but they are not the same act and the
/// pane must be able to tell them apart. `origin` is that distinction, and it
/// keeps GitHub's own word for a review's state — the review vocabulary is wider
/// than `ReviewVerdict`'s three *writable* values, and `DISMISSED` in particular
/// has no write counterpart. Flattening it to "commented" would report a
/// withdrawn approval as an ordinary remark.
public struct ConversationEntry: Equatable, Sendable, Identifiable {
    public enum Origin: Equatable, Sendable {
        /// An issue comment on the pull request's timeline.
        case timelineComment
        /// A submitted review. `state` is GitHub's verbatim word: APPROVED,
        /// CHANGES_REQUESTED, COMMENTED, DISMISSED.
        case review(state: String)
    }

    public var comment: PullRequestComment
    public var origin: Origin
    /// True when this review is still the author's standing verdict, per
    /// GitHub's own `latestReviews`. A "changes requested" that was later
    /// superseded by an approval is false here, so the pane can show it as
    /// history rather than as an open objection.
    public var isCurrentReview: Bool

    public var id: String { comment.id }

    public var isReview: Bool {
        if case .review = origin { return true }
        return false
    }

    /// GitHub's word for a review's state, or nil for a timeline comment.
    public var reviewState: String? {
        if case .review(let state) = origin { return state }
        return nil
    }

    public init(comment: PullRequestComment, origin: Origin,
                isCurrentReview: Bool = false) {
        self.comment = comment
        self.origin = origin
        self.isCurrentReview = isCurrentReview
    }
}

// MARK: - One reading

/// Everything one read of a pull request saw, and when it saw it.
///
/// Partial readings are first-class. The detail and the review threads come from
/// two different GitHub APIs and either can fail alone, so a reading can carry a
/// good header and a named refusal for the threads. That beats both alternatives:
/// failing the whole read loses information the user can act on, and showing an
/// empty thread list would claim there are none.
public struct PullRequestReading: Equatable, Sendable {
    public var detail: PullRequestDetail
    /// Timeline comments and submitted review bodies, oldest first.
    public var conversation: [ConversationEntry]
    public var threads: ReviewThreadReading
    public var files: [PullRequestFile]
    /// When this reading was taken. Every surface renders its age.
    public var observedAt: Date
    /// Set when review threads could not be read even though the detail could.
    public var threadsRefusal: PullRequestRefusal?

    public init(detail: PullRequestDetail, conversation: [ConversationEntry] = [],
                threads: ReviewThreadReading = .empty, files: [PullRequestFile] = [],
                observedAt: Date = Date(), threadsRefusal: PullRequestRefusal? = nil) {
        self.detail = detail
        self.conversation = conversation
        self.threads = threads
        self.files = files
        self.observedAt = observedAt
        self.threadsRefusal = threadsRefusal
    }

    /// The commit this reading describes. A reading is dropped rather than
    /// redrawn when this changes — see `PullRequestModel`.
    public var headRefOid: String? { detail.headRefOid }

    /// Files GitHub counted that this reading does not list. `gh pr view --json
    /// files` asks for one page, so a pull request touching more files than that
    /// page holds comes back short; the difference is stated, not hidden.
    public var missingFiles: Int { max(0, detail.changedFiles - files.count) }

    /// Threads whose anchor line no longer exists in the head. Shown and marked —
    /// there is no call site anywhere that removes these.
    public var outdatedThreadCount: Int { threads.threads.filter(\.isOutdated).count }
    public var unresolvedThreadCount: Int { threads.threads.filter { !$0.isResolved }.count }
}

// MARK: - The service

/// Reads a pull request through `GitHubPRGateway`. Stateless by construction.
public struct PullRequestReadService: Sendable {
    public let gateway: GitHubPRGateway
    public let maxThreadPages: Int
    private let now: @Sendable () -> Date

    public init(gateway: GitHubPRGateway,
                maxThreadPages: Int = ReviewThreadQuery.maxPages,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.gateway = gateway
        self.maxThreadPages = maxThreadPages
        self.now = now
    }

    public init(probe: any GitHubCLIProbe = SystemGitHubCLI(),
                timeout: TimeInterval = 20,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(gateway: GitHubPRGateway(probe: probe, timeout: timeout), now: now)
    }

    /// Fields for the detail-only read. Exactly what `PullRequestDecoder` can fill.
    public static let detailFields = PullRequestDecoder.viewFields

    /// Fields for the full read. A superset of `detailFields`, so one
    /// `gh pr view` answers the header, the conversation and the files together —
    /// the decoder ignores the keys it was not built for.
    public static let readFields = PullRequestDecoder.viewFields
        + ",comments,reviews,latestReviews,files"

    // MARK: Detail

    /// The pull request for this worktree's current branch.
    ///
    /// One subprocess. `gh pr view` resolves the branch from `cwd` itself, so
    /// this costs no `git` either.
    public func detail(worktree: URL,
                       number: Int? = nil) async -> Result<PullRequestDetail, PullRequestRefusal> {
        await view(worktree: worktree, number: number, fields: Self.detailFields)
            .map(\.0)
    }

    /// Detail plus the raw JSON it came from, so the full read can decode the
    /// conversation and the files from the same payload rather than asking twice.
    private func view(worktree: URL, number: Int?, fields: String) async
        -> Result<(PullRequestDetail, [String: Any]), PullRequestRefusal> {
        var argv = ["pr", "view"]
        if let number { argv.append(String(number)) }
        argv += ["--json", fields]
        switch await gateway.json(argv, cwd: worktree) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let json):
            guard let repository = Self.repository(fromURL: json["url"] as? String) else {
                return .failure(PullRequestRefusal(.apiError,
                    detail: "gh returned a pull request with no usable URL, "
                        + "so the repository it belongs to cannot be named."))
            }
            guard let detail = PullRequestDecoder.detail(from: json, repository: repository) else {
                return .failure(PullRequestRefusal(.apiError,
                    detail: "gh returned JSON with no pull-request number."))
            }
            return .success((detail, json))
        }
    }

    // MARK: The whole reading

    /// Detail, conversation, files and review threads.
    ///
    /// Two GitHub round trips on the common path: one `gh pr view --json` for
    /// everything `gh` can answer, and one `gh api graphql` for the line-anchored
    /// threads it cannot. Extra graphql calls happen only when the thread
    /// connection actually has more pages.
    public func read(worktree: URL,
                     number: Int? = nil) async -> Result<PullRequestReading, PullRequestRefusal> {
        let viewed = await view(worktree: worktree, number: number, fields: Self.readFields)
        guard case .success(let (detail, json)) = viewed else {
            return .failure(viewed.refusalOrUnknown)
        }

        let conversation = PullRequestConversation.entries(from: json)
        let files = Self.files(from: json)

        var reading = PullRequestReading(detail: detail, conversation: conversation,
                                         threads: .empty, files: files,
                                         observedAt: now())

        guard let (owner, name) = Self.split(repository: detail.ref.repository) else {
            reading.threadsRefusal = PullRequestRefusal(.apiError,
                detail: "Could not split \"\(detail.ref.repository)\" into an owner and a name, "
                    + "so review threads could not be requested.")
            return .success(reading)
        }
        let query = ReviewThreadQuery(gateway: gateway, maxPages: maxThreadPages)
        switch await query.fetch(owner: owner, name: name,
                                 number: detail.ref.number, cwd: worktree) {
        case .success(let threads):
            reading.threads = threads
        case .failure(let refusal):
            // The header, the conversation and the files are real and already in
            // hand. Losing them because the second API refused would be a worse
            // answer than showing them beside a named reason the threads are gone.
            reading.threadsRefusal = refusal
        }
        return .success(reading)
    }

    // MARK: Decoding the parts gh answers

    /// `gh pr view --json files` → `[PullRequestFile]`.
    public static func files(from json: [String: Any]) -> [PullRequestFile] {
        let nodes = json["files"] as? [[String: Any]] ?? []
        return nodes.compactMap { node in
            guard let path = node["path"] as? String, !path.isEmpty else { return nil }
            return PullRequestFile(path: path,
                                   additions: node["additions"] as? Int ?? 0,
                                   deletions: node["deletions"] as? Int ?? 0)
        }
    }

    /// `https://github.com/<owner>/<repo>/pull/<n>` → `owner/repo`.
    ///
    /// Read off the URL `gh` already returned rather than spent as a second
    /// `gh repo view`, which is what keeps the common path at one subprocess.
    public static func repository(fromURL url: String?) -> String? {
        guard let url, let parsed = URL(string: url) else { return nil }
        let parts = parsed.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    static func split(repository: String) -> (owner: String, name: String)? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

private extension Result where Success == (PullRequestDetail, [String: Any]),
                               Failure == PullRequestRefusal {
    var refusalOrUnknown: PullRequestRefusal {
        if case .failure(let refusal) = self { return refusal }
        return PullRequestRefusal(.apiError, detail: "unreachable")
    }
}

// MARK: - Conversation decoding

/// Timeline comments and submitted reviews, merged into one chronological list.
public enum PullRequestConversation {

    /// GitHub's review state → the verdict we can also *write*.
    ///
    /// `DISMISSED` deliberately maps to nil: there is no `gh pr review` flag for
    /// it, and giving it one of the other three would misreport what happened.
    /// The state itself survives on `ConversationEntry.origin`.
    public static func verdict(forReviewState state: String) -> ReviewVerdict? {
        switch state.uppercased() {
        case "APPROVED": return .approve
        case "CHANGES_REQUESTED": return .requestChanges
        case "COMMENTED": return .comment
        default: return nil
        }
    }

    /// Merge `comments`, `reviews` and `latestReviews` into one list, oldest first.
    ///
    /// `reviews` is the complete history and the only source of entries.
    /// `latestReviews` is used *only* to mark which of them still stands, because
    /// its entries come back with an empty `id` (verified against gh 2.98.0) and
    /// so cannot be deduplicated against `reviews` by identity at all.
    public static func entries(from json: [String: Any]) -> [ConversationEntry] {
        var entries: [ConversationEntry] = []

        for node in json["comments"] as? [[String: Any]] ?? [] {
            guard let comment = timelineComment(from: node) else { continue }
            entries.append(ConversationEntry(comment: comment, origin: .timelineComment))
        }

        let current = currentReviewKeys(json["latestReviews"] as? [[String: Any]] ?? [])
        for node in json["reviews"] as? [[String: Any]] ?? [] {
            guard let entry = reviewEntry(from: node, currentKeys: current) else { continue }
            entries.append(entry)
        }

        return entries.sorted {
            $0.comment.createdAt == $1.comment.createdAt
                ? $0.id < $1.id
                : $0.comment.createdAt < $1.comment.createdAt
        }
    }

    /// One issue comment. An empty body is dropped: a timeline comment *is* its
    /// body, so an empty one carries nothing a reader could act on.
    static func timelineComment(from node: [String: Any]) -> PullRequestComment? {
        guard let id = node["id"] as? String, !id.isEmpty else { return nil }
        let body = node["body"] as? String ?? ""
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PullRequestComment(
            id: id,
            author: PullRequestDecoder.actor(node["author"]),
            body: body,
            createdAt: PullRequestDecoder.date(node["createdAt"]) ?? Date(timeIntervalSince1970: 0),
            isEdited: node["includesCreatedEdit"] as? Bool ?? false,
            reviewVerdict: nil)
    }

    /// One submitted review.
    ///
    /// Two rules, both about not reporting things that were not said:
    ///
    /// * A `PENDING` review is a draft only its author can see. It has not been
    ///   submitted, so it is not part of the conversation.
    /// * An empty-bodied `COMMENTED` review is the wrapper GitHub creates when
    ///   somebody leaves only line comments. Its content is the review threads,
    ///   which are rendered in their own section; showing the wrapper too would
    ///   put an empty bubble in the timeline. An empty-bodied *approval* is kept,
    ///   because there the verdict is the whole message.
    static func reviewEntry(from node: [String: Any],
                            currentKeys: Set<String>) -> ConversationEntry? {
        guard let id = node["id"] as? String, !id.isEmpty else { return nil }
        let state = (node["state"] as? String ?? "").uppercased()
        guard state != "PENDING" else { return nil }
        let body = node["body"] as? String ?? ""
        let isEmpty = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !(isEmpty && state == "COMMENTED") else { return nil }

        let submitted = PullRequestDecoder.date(node["submittedAt"])
            ?? PullRequestDecoder.date(node["createdAt"])
            ?? Date(timeIntervalSince1970: 0)
        let author = PullRequestDecoder.actor(node["author"])
        let comment = PullRequestComment(
            id: id, author: author, body: body, createdAt: submitted,
            isEdited: node["includesCreatedEdit"] as? Bool ?? false,
            reviewVerdict: verdict(forReviewState: state))
        return ConversationEntry(
            comment: comment, origin: .review(state: state.isEmpty ? "UNKNOWN" : state),
            isCurrentReview: currentKeys.contains(key(login: author?.login,
                                                      submittedAt: node["submittedAt"])))
    }

    /// `latestReviews` carries no usable id, so "is this review still the
    /// author's standing verdict" is matched on author plus submission time —
    /// the pair GitHub does send, and which is unique per reviewer.
    static func currentReviewKeys(_ nodes: [[String: Any]]) -> Set<String> {
        Set(nodes.compactMap { node -> String? in
            let login = PullRequestDecoder.actor(node["author"])?.login
            guard login != nil || node["submittedAt"] != nil else { return nil }
            return key(login: login, submittedAt: node["submittedAt"])
        })
    }

    static func key(login: String?, submittedAt: Any?) -> String {
        "\(login ?? "")@\(submittedAt as? String ?? "")"
    }
}

// MARK: - Markdown

/// GitHub-flavoured markdown, split into the blocks a pane can lay out.
///
/// This is a *block* splitter only, and deliberately so. Inline spans — bold,
/// links, inline code — are handed to Foundation's own
/// `AttributedString(markdown:)` at render time, which already does them
/// correctly and costs no dependency. What Foundation will not do is block
/// structure: it flattens a fenced code block into a paragraph, which for a code
/// review is the one thing that must not happen. So the split happens here and
/// the spans happen there, and neither half is reimplemented.
///
/// Lives in the runtime rather than beside the view because it is a pure
/// function over a string, and the runtime is where this package can test one.
public enum PullRequestMarkdown {

    public enum Block: Equatable, Sendable {
        /// Prose. Newlines are preserved: GitHub renders a single newline in a
        /// comment as a line break, and a diff pasted into a comment is ruined
        /// by re-wrapping it.
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `marker` is the literal bullet or number to draw, so an ordered list
        /// keeps the author's own numbering instead of being renumbered.
        case listItem(marker: String, text: String, depth: Int)
        case quote(String)
        /// `language` is the fence's info string when there is one.
        case code(language: String?, text: String)
        /// A GFM table, kept as its raw rows. Rendered in a monospaced font so
        /// the author's own pipe alignment lines up. Laying it out as a real
        /// grid is the one piece of markdown this deliberately does not attempt
        /// — see the report.
        case table(rows: [String])
        case rule
    }

    public static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraph = []
        }
        func flushQuote() {
            let text = quote.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.quote(text))
            }
            quote = []
        }
        func flushAll() { flushParagraph(); flushQuote() }

        let lines = withoutHTMLComments(
            source.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n"))

        var index = 0
        while index < lines.count {
            let line = lines[index]

            if let fence = fenceToken(line) {
                flushAll()
                var body: [String] = []
                index += 1
                // An unterminated fence still closes at end of input: dropping the
                // rest of a comment because someone forgot three backticks would
                // lose more than it protects.
                while index < lines.count, !closesFence(lines[index], fence: fence) {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushAll()
                index += 1
                continue
            }

            if isThematicBreak(line) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = heading(line) {
                flushAll()
                blocks.append(heading)
                index += 1
                continue
            }

            if let stripped = quotePrefix(line) {
                flushParagraph()
                quote.append(stripped)
                index += 1
                continue
            }

            if let rows = tableRun(lines, from: index) {
                flushAll()
                blocks.append(.table(rows: rows))
                index += rows.count
                continue
            }

            if let item = listItem(line) {
                flushAll()
                blocks.append(item)
                index += 1
                continue
            }

            flushQuote()
            paragraph.append(line)
            index += 1
        }
        flushAll()
        return blocks
    }

    // MARK: HTML comments

    /// Drop `<!-- … -->` regions, including ones spanning several lines.
    ///
    /// Found against a live pull request: GitHub's own PR template is mostly
    /// HTML comments, and every markdown renderer — GitHub's included — hides
    /// them. Rendering them would open a real pull request with three
    /// paragraphs of template instructions the author never wrote and nobody
    /// can see on GitHub. This is the *only* HTML this file treats specially:
    /// a comment is unambiguously not content, whereas a `<details>` block is,
    /// and is left verbatim rather than half-stripped. See the report.
    ///
    /// Fenced code is skipped, so a comment shown *as an example* survives.
    static func withoutHTMLComments(_ lines: [String]) -> [String] {
        var output: [String] = []
        var fence: Fence?
        var inComment = false

        for line in lines {
            if let open = fence {
                output.append(line)
                if closesFence(line, fence: open) { fence = nil }
                continue
            }
            if inComment {
                guard let end = line.range(of: "-->") else { continue }
                let rest = String(line[end.upperBound...])
                // The remainder of the line can open a second comment.
                let (cleaned, stillOpen) = stripComments(rest)
                inComment = stillOpen
                if !cleaned.trimmingCharacters(in: .whitespaces).isEmpty {
                    output.append(cleaned)
                }
                continue
            }
            if let token = fenceToken(line) {
                fence = token
                output.append(line)
                continue
            }
            let (cleaned, stillOpen) = stripComments(line)
            inComment = stillOpen
            // A line that was *only* a comment becomes a blank line rather than
            // vanishing, so it still separates the paragraphs around it.
            output.append(cleaned)
        }
        return output
    }

    /// Remove every complete `<!-- … -->` on one line. Returns the remainder and
    /// whether a comment is still open at end of line.
    static func stripComments(_ line: String) -> (String, Bool) {
        var text = line
        while let start = text.range(of: "<!--") {
            guard let end = text.range(of: "-->", range: start.upperBound..<text.endIndex) else {
                return (String(text[text.startIndex..<start.lowerBound]), true)
            }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return (text, false)
    }

    // MARK: Line shapes

    struct Fence { var character: Character; var count: Int; var language: String? }

    /// An opening fence: three or more backticks or tildes, up to three spaces in.
    static func fenceToken(_ line: String) -> Fence? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let first = trimmed.first,
              first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not itself contain a backtick.
        if first == "`", info.contains("`") { return nil }
        return Fence(character: first, count: run.count,
                     language: info.isEmpty ? nil : info)
    }

    static func closesFence(_ line: String, fence: Fence) -> Bool {
        let trimmed = line.drop { $0 == " " }
        let run = trimmed.prefix { $0 == fence.character }
        guard run.count >= fence.count else { return false }
        return trimmed.dropFirst(run.count).allSatisfy { $0 == " " }
    }

    static func isThematicBreak(_ line: String) -> Bool {
        let squeezed = line.filter { $0 != " " }
        guard squeezed.count >= 3 else { return false }
        return squeezed.allSatisfy { $0 == "-" } || squeezed.allSatisfy { $0 == "*" }
            || squeezed.allSatisfy { $0 == "_" }
    }

    static func heading(_ line: String) -> Block? {
        let trimmed = line.drop { $0 == " " }
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        // `#hashtag` is not a heading; ATX requires a space after the run.
        guard rest.isEmpty || rest.first == " " else { return nil }
        return .heading(level: hashes.count,
                        text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func quotePrefix(_ line: String) -> String? {
        let trimmed = line.drop { $0 == " " }
        guard trimmed.first == ">" else { return nil }
        var rest = trimmed.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// A GFM table starting at `index`: a header row, a delimiter row of dashes
    /// and pipes, then its body. Recognised as a run so the rows stay together;
    /// nil when the shape does not match, which leaves a stray pipe in prose
    /// being treated as prose.
    static func tableRun(_ lines: [String], from index: Int) -> [String]? {
        guard index + 1 < lines.count,
              lines[index].contains("|"), isTableDelimiter(lines[index + 1]) else { return nil }
        var rows = [lines[index], lines[index + 1]]
        var cursor = index + 2
        while cursor < lines.count, lines[cursor].contains("|"),
              !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(lines[cursor])
            cursor += 1
        }
        return rows
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        let squeezed = line.filter { !$0.isWhitespace }
        guard squeezed.contains("|"), squeezed.contains("-") else { return false }
        return squeezed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" }
    }

    static func listItem(_ line: String) -> Block? {
        let indent = line.prefix { $0 == " " }.count
        let trimmed = line.drop { $0 == " " }
        guard let first = trimmed.first else { return nil }
        let depth = min(indent / 2, 4)

        if first == "-" || first == "*" || first == "+" {
            let rest = trimmed.dropFirst()
            guard rest.first == " " else { return nil }
            let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            // A GFM task list is a checklist, and a PR description's checklist is
            // usually the point of it. `[ ]` / `[x]` become boxes rather than
            // being left as literal brackets after a bullet.
            if text.hasPrefix("[ ] ") {
                return .listItem(marker: "☐", text: String(text.dropFirst(4)), depth: depth)
            }
            if text.lowercased().hasPrefix("[x] ") {
                return .listItem(marker: "☑", text: String(text.dropFirst(4)), depth: depth)
            }
            return .listItem(marker: "•", text: text, depth: depth)
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        var rest = trimmed.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return .listItem(marker: "\(digits).",
                         text: rest.dropFirst().trimmingCharacters(in: .whitespaces),
                         depth: depth)
    }
}
