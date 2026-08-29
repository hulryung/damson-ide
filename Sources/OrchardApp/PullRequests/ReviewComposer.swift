import OrchardRuntime
import SwiftUI

/// Write and submit a pull-request review.
///
/// Presented as a sheet from `PullRequestPane` (T93). It owns nothing but its own
/// draft: the pull request it acts on is whichever one the service's worktree
/// resolves, and the receipt goes back to the presenter through `onCompleted` so
/// the pane can reload without this view knowing what a pane is.
///
/// ## Two rules it exists to enforce
///
/// **The disabled button says why.** A "Submit" that is grey and silent is a dead
/// end with no remedy — the thing `PullRequestRefusalReason` was written to stop.
/// The reason under the button is the same `PullRequestRefusal` the service would
/// return, produced by the same `ReviewSubmission.refusal`, so what the button
/// says and what the runtime would do cannot drift.
///
/// **Nothing submits from a bare keypress.** Return inserts a newline in the body,
/// because a review body is prose and prose has paragraphs. ⌘Return submits, and
/// only when the button it mirrors is enabled — an explicit chord on a visible,
/// legal action. There is no default-action button in this sheet.
struct ReviewComposer: View {
    /// The runtime seam. A `Sendable` struct, so holding one in a view is fine —
    /// what is not fine is calling it from `body`, and nothing here does.
    let service: PullRequestActionService
    /// Which pull request the header names. Passed in rather than read here: the
    /// pane already has it, and a second `gh pr view` to draw a title is a round
    /// trip for decoration.
    let ref: PullRequestRef
    let title: String
    /// Handed the receipt when something landed, so the presenter can reload.
    var onCompleted: (PullRequestActionReceipt) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var verdict: ReviewVerdict = .comment
    @State private var body_: String = ""
    @State private var submitting = false
    @State private var outcome: PullRequestActionResult?
    @FocusState private var bodyFocused: Bool

    /// The single source of truth for "can this be sent". The service asks the
    /// same type the same question before it launches anything.
    private var submission: ReviewSubmission {
        ReviewSubmission(verdict: verdict, body: body_)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    verdictPicker
                    bodyField
                    if let outcome, !outcome.didSucceed {
                        outcomeNotice(outcome)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 420, maxHeight: 620)
        .onAppear { bodyFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.bubble")
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Review \(ref.repository)#\(ref.number)")
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Verdict

    private var verdictPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Verdict")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            // Radio rows rather than a segmented control: each verdict carries a
            // consequence, and a sentence naming it does not fit in a segment.
            ForEach(ReviewVerdict.allCases, id: \.rawValue) { option in
                verdictRow(option)
            }
        }
    }

    private func verdictRow(_ option: ReviewVerdict) -> some View {
        let selected = option == verdict
        return Button {
            verdict = option
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.accentColor : Tokens.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.submitLabel)
                            .font(Tokens.fontRow)
                        if option.requiresBody {
                            Text("body required")
                                .font(Tokens.fontPill)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Tokens.rowHover))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                    }
                    Text(option.submitDescription)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .fill(selected ? Tokens.selectionFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(submitting)
    }

    // MARK: - Body

    private var bodyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Body")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            TextEditor(text: $body_)
                .font(Tokens.fontMono)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radius)
                        .fill(Tokens.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radius)
                        .stroke(Tokens.border))
                .focused($bodyFocused)
                .disabled(submitting)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // The refusal that would come back from the runtime, shown before the
            // round trip that would produce it.
            if let refusal = submission.refusal {
                Label("\(refusal.headline). \(refusal.remedy)",
                      systemImage: "exclamationmark.circle")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let receipt = outcome?.receipt {
                Label(receipt.summary, systemImage: "checkmark.circle")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if submitting { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(submitting)
            Button(submission.verdict.submitLabel) { submit() }
                // ⌘Return, not Return: Return belongs to the body field, and a
                // review must not be submitted by a keystroke aimed at a
                // paragraph break. Deliberately not `.defaultAction`.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!submission.canSubmit || submitting)
                .help(submission.refusal?.headline ?? "Send this review to GitHub")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func outcomeNotice(_ result: PullRequestActionResult) -> some View {
        switch result {
        case .refused(let refusal):
            ChecksNotice(symbol: "exclamationmark.triangle",
                         headline: refusal.headline, detail: refusal.detail,
                         remedy: refusal.remedy, code: refusal.code)
        case .needsConfirmation(let confirmation):
            ChecksNotice(symbol: "hand.raised",
                         headline: "Confirmation required",
                         detail: confirmation.sentence,
                         remedy: "Nothing was sent.")
        case .mergeabilityUnknown(let pending):
            ChecksNotice(symbol: "clock", headline: pending.headline,
                         detail: pending.detail, remedy: pending.remedy)
        case .succeeded:
            EmptyView()
        }
    }

    // MARK: - Acting

    /// The only place this view talks to GitHub, and it is a button action — not
    /// `body`, not `.task`, not `onChange`. A review is sent because somebody
    /// pressed a button that said what it would do.
    private func submit() {
        guard submission.canSubmit, !submitting else { return }
        let draft = submission
        submitting = true
        outcome = nil
        Task {
            let result = await service.submitReview(verdict: draft.verdict, body: draft.body)
            await MainActor.run {
                submitting = false
                outcome = result
                if let receipt = result.receipt {
                    onCompleted(receipt)
                    dismiss()
                }
            }
        }
    }
}
