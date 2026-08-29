import OrchardRuntime
import SwiftUI

/// Center `pull-request` tab: one pull request, read.
///
/// Four sections, in the order a reviewer needs them — what this pull request is,
/// what people said, what they said about particular lines, and what it touches.
///
/// There is no empty state anywhere in this file. Either a reading is on screen,
/// or a named refusal is, with its headline, `gh`'s own words and a remedy. The
/// notice is literally `ChecksNotice` from T88, reused rather than re-drawn, so
/// the two features cannot drift into two dialects of the same apology.
struct PullRequestPane: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var pullRequests: PullRequestModel
    let key: WorkbenchKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.background)
        // The read happens here, never in `body`: a view body may not run a
        // subprocess, and switching workspaces must not wait on GitHub.
        .task(id: store.selection) {
            guard let target = paneTarget else { return }
            guard pullRequests.reading(for: key) == nil,
                  pullRequests.refusal(for: key) == nil else { return }
            await pullRequests.refresh(target)
        }
        .onAppear { pullRequests.beginObservingAge() }
        .onDisappear { pullRequests.endObservingAge() }
    }

    private var reading: PullRequestReading? { pullRequests.reading(for: key) }

    /// The selection's target, but only when it is *this* pane's workspace.
    /// A refresh must never file its answer under a key this pane does not show.
    private var paneTarget: PullRequestTarget? {
        guard let target = store.pullRequestTarget(), target.key == key else { return nil }
        return target
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if let detail = reading?.detail {
                PullRequestHeader(detail: detail)
            } else {
                Text("Pull request").font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 8)
            if pullRequests.isLoading(key) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            if let url = reading.flatMap({ URL(string: $0.detail.ref.url) }) {
                Link("Open on GitHub", destination: url).font(Tokens.fontMeta)
            }
            Button {
                guard let target = paneTarget else { return }
                Task { await pullRequests.refresh(target) }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(paneTarget == nil || pullRequests.isLoading(key))
            .help("Ask GitHub again now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if let refusal = pullRequests.refusal(for: key) {
            ScrollView {
                ChecksNotice(symbol: "exclamationmark.triangle",
                             headline: refusal.headline,
                             detail: refusal.detail,
                             remedy: refusal.remedy,
                             code: refusal.code)
                    .padding(12)
            }
        } else if let reading {
            available(reading)
        } else if pullRequests.isLoading(key) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Reading the pull request from GitHub…")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            .padding(12)
        } else {
            ScrollView {
                ChecksNotice(symbol: "clock.arrow.circlepath",
                             headline: "Not read yet",
                             detail: "This workspace's pull request has not been read.",
                             remedy: "Press the refresh button to ask GitHub.")
                    .padding(12)
            }
        }
    }

    @ViewBuilder
    private func available(_ reading: PullRequestReading) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConversationSection(reading: reading)
                ReviewThreadsSection(reading: reading)
                FilesSection(reading: reading)
                footer(reading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Every reading ends with when it was taken, and against which head. This
    /// line is what stops an old answer from reading as a current one.
    @ViewBuilder
    private func footer(_ reading: PullRequestReading) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 1) {
            Text("read \(ChecksPresentation.age(pullRequests.age(for: key)))")
            if let sha = reading.headRefOid {
                Text("head \(sha.prefix(8)) · \(reading.detail.headRefName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Nothing here is cached — every refresh asks GitHub again.")
        }
        .font(Tokens.fontPill)
        .foregroundStyle(Tokens.textTertiary)
    }
}

// MARK: - Header

private struct PullRequestHeader: View {
    let detail: PullRequestDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(detail.ref.number)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.textSecondary)
                Text(detail.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }
            HStack(spacing: 5) {
                StatusPill(symbol: PullRequestPresentation.symbol(for: detail.state),
                           text: detail.state.label,
                           color: PullRequestPresentation.color(for: detail.state))
                if detail.isDraft {
                    StatusPill(symbol: "pencil.circle", text: "Draft",
                               color: Tokens.textTertiary)
                }
                StatusPill(symbol: PullRequestPresentation.symbol(for: detail.reviewDecision),
                           text: detail.reviewDecision.label,
                           color: PullRequestPresentation.color(for: detail.reviewDecision))
                StatusPill(symbol: PullRequestPresentation.symbol(for: detail.mergeable),
                           text: PullRequestPresentation.label(for: detail.mergeable),
                           color: PullRequestPresentation.color(for: detail.mergeable))
            }
            HStack(spacing: 6) {
                Text(detail.baseRefName).monospaced()
                Image(systemName: "arrow.left").font(.system(size: 8))
                Text(detail.headRefName).monospaced()
                Text("·")
                Text("+\(detail.additions)").foregroundStyle(Tokens.Git.added)
                Text("−\(detail.deletions)").foregroundStyle(Tokens.Git.deleted)
                Text("·")
                Text("\(detail.changedFiles) \(detail.changedFiles == 1 ? "file" : "files")")
            }
            .font(Tokens.fontMeta)
            .foregroundStyle(Tokens.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            // GitHub's own mergeStateStatus, verbatim, beside our collapsed
            // word — so the collapse is never the only record of what it said.
            .help(helpText)
        }
    }

    private var helpText: String {
        var parts = ["\(detail.ref.repository)#\(detail.ref.number)"]
        if let status = detail.mergeStateStatus, !status.isEmpty {
            parts.append("GitHub mergeStateStatus: \(status)")
        }
        if let created = detail.createdAt {
            parts.append("opened \(PullRequestPresentation.absolute(created))")
        }
        return parts.joined(separator: "\n")
    }
}

private struct StatusPill: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(Tokens.fontPill)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Sections

private struct SectionTitle: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(Tokens.fontSection)
            if let trailing {
                Text(trailing)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The pull request's own description, then every timeline comment and review
/// body, oldest first.
private struct ConversationSection: View {
    let reading: PullRequestReading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Conversation",
                         trailing: reading.conversation.isEmpty
                            ? nil
                            : "\(reading.conversation.count)")
            // The description is the opening post of the conversation, so it is
            // rendered as one rather than hidden in the header.
            if !reading.detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CommentCard(author: reading.detail.author,
                            date: reading.detail.createdAt,
                            text: reading.detail.body,
                            isEdited: false,
                            reviewState: nil,
                            isCurrentReview: false,
                            roleLabel: "opened this")
            }
            if reading.conversation.isEmpty {
                ChecksNotice(symbol: "bubble.left",
                             headline: "No comments yet",
                             detail: "Nobody has commented on or reviewed this pull request.",
                             remedy: nil)
            } else {
                ForEach(reading.conversation) { entry in
                    CommentCard(author: entry.comment.author,
                                date: entry.comment.createdAt,
                                text: entry.comment.body,
                                isEdited: entry.comment.isEdited,
                                reviewState: entry.reviewState,
                                isCurrentReview: entry.isCurrentReview,
                                roleLabel: nil)
                }
            }
        }
    }
}

/// Line-anchored threads, grouped by file.
private struct ReviewThreadsSection: View {
    let reading: PullRequestReading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Review threads", trailing: countLine)
            if let refusal = reading.threadsRefusal {
                ChecksNotice(symbol: "exclamationmark.triangle",
                             headline: refusal.headline,
                             detail: refusal.detail,
                             remedy: refusal.remedy,
                             code: refusal.code)
            } else if let shortfall = reading.threads.shortfallSummary {
                // Never silent. If threads or replies are missing, the count is
                // on screen beside the ones that are not.
                ChecksNotice(symbol: "ellipsis.circle",
                             headline: "Not every thread is shown",
                             detail: shortfall,
                             remedy: "Open the pull request on GitHub to read the rest.")
            }
            if reading.threads.threads.isEmpty, reading.threadsRefusal == nil {
                ChecksNotice(symbol: "text.line.first.and.arrowtriangle.forward",
                             headline: "No line comments",
                             detail: "No review comments are anchored to lines in this diff.",
                             remedy: nil)
            }
            ForEach(reading.threads.byFile, id: \.path) { group in
                ThreadFileGroup(path: group.path, threads: group.threads,
                                truncated: reading.threads.truncatedComments)
            }
        }
    }

    private var countLine: String? {
        let threads = reading.threads.threads
        guard !threads.isEmpty else { return nil }
        var parts = ["\(threads.count)"]
        let unresolved = reading.unresolvedThreadCount
        if unresolved > 0 { parts.append("\(unresolved) unresolved") }
        let outdated = reading.outdatedThreadCount
        if outdated > 0 { parts.append("\(outdated) outdated") }
        return parts.joined(separator: " · ")
    }
}

private struct ThreadFileGroup: View {
    let path: String
    let threads: [ReviewThread]
    let truncated: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text").font(.system(size: 9))
                Text(path)
                    .font(Tokens.fontMono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.textSecondary)
            ForEach(threads) { thread in
                ThreadCard(thread: thread, hiddenReplies: truncated[thread.id] ?? 0)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Tokens.radiusCard).fill(Tokens.surface))
    }
}

/// One thread. An outdated thread is drawn here exactly like a current one and
/// marked; there is no branch in this file that removes it.
private struct ThreadCard: View {
    let thread: ReviewThread
    let hiddenReplies: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(PullRequestPresentation.anchor(thread))
                    .font(Tokens.fontPill)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.textSecondary)
                if thread.isResolved {
                    StatusPill(symbol: "checkmark.circle", text: "Resolved", color: .green)
                }
                if thread.isOutdated {
                    StatusPill(symbol: "clock.badge.exclamationmark",
                               text: "Outdated", color: .orange)
                }
                Spacer(minLength: 0)
            }
            .help(thread.isOutdated
                  ? "The lines this thread was written against are no longer in the head commit. "
                    + "It is shown at the line it was written at."
                  : "Anchored to the \(thread.diffSide == .left ? "base" : "head") side of the diff.")
            ForEach(thread.comments) { comment in
                CommentCard(author: comment.author, date: comment.createdAt,
                            text: comment.body, isEdited: comment.isEdited,
                            reviewState: nil, isCurrentReview: false, roleLabel: nil,
                            compact: true)
            }
            if hiddenReplies > 0 {
                Text("\(hiddenReplies) older \(hiddenReplies == 1 ? "reply is" : "replies are") not shown.")
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(thread.isResolved ? Tokens.border : Color.orange.opacity(0.6))
                .frame(width: Tokens.selectionBarWidth)
        }
    }
}

private struct FilesSection: View {
    let reading: PullRequestReading

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Files",
                         trailing: PullRequestPresentation.diffstat(
                            additions: reading.detail.additions,
                            deletions: reading.detail.deletions))
            if reading.files.isEmpty {
                ChecksNotice(symbol: "doc",
                             headline: "No files listed",
                             detail: "gh returned no file list for this pull request.",
                             remedy: "Open it on GitHub to see the diff.")
            }
            ForEach(reading.files) { file in
                HStack(spacing: 6) {
                    Text(file.path)
                        .font(Tokens.fontMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("+\(file.additions)")
                        .foregroundStyle(Tokens.Git.added)
                    Text("−\(file.deletions)")
                        .foregroundStyle(Tokens.Git.deleted)
                }
                .font(Tokens.fontPill)
                .monospacedDigit()
            }
            if reading.missingFiles > 0 {
                Text("\(reading.missingFiles) more "
                     + (reading.missingFiles == 1 ? "file is" : "files are")
                     + " changed but were not listed by gh.")
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }
}

// MARK: - One comment

private struct CommentCard: View {
    let author: GitHubActor?
    let date: Date?
    let text: String
    let isEdited: Bool
    /// GitHub's own review state, when this comment came in as a review.
    let reviewState: String?
    let isCurrentReview: Bool
    /// Extra words for the byline, e.g. "opened this".
    let roleLabel: String?
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            byline
            MarkdownBody(source: text)
        }
        .padding(compact ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    /// A review is visually distinct from a plain comment: it carries a verdict
    /// glyph, a tinted edge in the verdict's colour, and the verdict in words.
    /// A plain comment gets none of those, so the two can never be confused.
    @ViewBuilder
    private var background: some View {
        if let reviewState {
            let color = PullRequestPresentation.color(forReviewState: reviewState)
            RoundedRectangle(cornerRadius: Tokens.radius)
                .fill(color.opacity(0.07))
                .overlay(alignment: .leading) {
                    Rectangle().fill(color.opacity(0.7))
                        .frame(width: Tokens.selectionBarWidth)
                }
        } else {
            RoundedRectangle(cornerRadius: Tokens.radius).fill(Tokens.rowHover.opacity(0.35))
        }
    }

    private var byline: some View {
        HStack(spacing: 5) {
            if let reviewState {
                Image(systemName: PullRequestPresentation.symbol(forReviewState: reviewState))
                    .font(.system(size: 10))
                    .foregroundStyle(PullRequestPresentation.color(forReviewState: reviewState))
            }
            Text(author?.login ?? "ghost")
                .font(Tokens.fontMeta)
                .fontWeight(.semibold)
            if let reviewState {
                Text(PullRequestPresentation.label(forReviewState: reviewState))
                    .font(Tokens.fontMeta)
                    .foregroundStyle(PullRequestPresentation.color(forReviewState: reviewState))
            } else if let roleLabel {
                Text(roleLabel)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            // A superseded verdict is history, not a standing objection.
            if reviewState != nil, !isCurrentReview {
                Text("superseded")
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
                    .help("A later review by the same person replaced this one.")
            }
            if isEdited {
                Text("edited")
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer(minLength: 4)
            if let date, date.timeIntervalSince1970 > 0 {
                Text(PullRequestPresentation.absolute(date))
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .foregroundStyle(Tokens.text)
    }
}

// MARK: - Markdown

/// GitHub-flavoured markdown, rendered from `PullRequestMarkdown.blocks`.
///
/// Block structure is decided in the runtime (and tested there); inline spans —
/// bold, italic, links, inline code — are handed to Foundation's own markdown
/// parser. Neither half is a reimplementation and there is no dependency.
struct MarkdownBody: View {
    let source: String

    var body: some View {
        let blocks = PullRequestMarkdown.blocks(source)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: PullRequestMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownBody.inline(text))
                .font(Tokens.fontRow)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(MarkdownBody.inline(text))
                .font(.system(size: level <= 2 ? 14 : 13, weight: .semibold))
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(Tokens.fontRow)
                    .foregroundStyle(Tokens.textSecondary)
                Text(MarkdownBody.inline(text))
                    .font(Tokens.fontRow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote(let text):
            Text(MarkdownBody.inline(text))
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Tokens.border).frame(width: 2)
                }
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .table(let rows):
            // Monospaced and horizontally scrollable, so the author's own pipe
            // alignment is what lines the columns up.
            CodeBlock(language: nil, text: rows.joined(separator: "\n"))
        case .rule:
            Divider()
        }
    }

    /// Inline markdown only. `.inlineOnlyPreservingWhitespace` keeps the newlines
    /// inside a paragraph, which matters because GitHub renders a single newline
    /// in a comment as a line break — re-wrapping would mangle pasted output.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

/// A fenced code block. Scrolls sideways rather than wrapping: wrapped code is
/// harder to read than code you have to scroll, and a review is mostly code.
private struct CodeBlock: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Tokens.fontMono)
                    .textSelection(.enabled)
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.radius).fill(Tokens.background))
        .overlay(RoundedRectangle(cornerRadius: Tokens.radius).stroke(Tokens.border, lineWidth: 1))
    }
}
