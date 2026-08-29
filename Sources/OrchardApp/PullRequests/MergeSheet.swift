import OrchardRuntime
import SwiftUI

/// The confirmation in front of a merge.
///
/// This sheet *is* the second step of a two-step write. Opening it reads the pull
/// request and the repository's merge settings — that reading is what mints the
/// token `PullRequestActionService.merge` demands — and pressing the button
/// spends it. There is no path to `gh pr merge` that does not pass through a
/// rendered sentence naming the pull request, the method and the branch's fate.
///
/// ## What the design is defending against
///
/// Orchard is driven by agents. An accidental commit is a `git reset` away; an
/// accidental merge is a message in somebody else's inbox and a branch that may
/// no longer exist. So:
///
/// * **No default button.** `Merge` carries no keyboard shortcut at all. Return
///   does nothing in this sheet; Escape cancels. A merge cannot happen because a
///   window was focused when a key was pressed.
/// * **The tick starts off.** `deleteBranch` is `false` here, in `MergePlan`, in
///   the service signature and in the CLI. Four defaults, all the safe one.
/// * **The sentence is regenerated, never remembered.** It is a computed property
///   of the plan, and the plan changes with every radio button and every tick, so
///   the sentence on screen always describes the merge the button would perform.
/// * **`unknown` mergeability is a wait, not a wall and not permission.** The
///   button is disabled and the sheet says GitHub is still computing.
struct MergeSheet: View {
    let service: PullRequestActionService
    var onCompleted: (PullRequestActionReceipt) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    /// The one reading every plan in this sheet is derived from. Taken on open;
    /// re-taken only when the user asks.
    @State private var context: MergeContext?
    @State private var loadRefusal: PullRequestRefusal?
    @State private var loading = true
    @State private var method: MergeMethod = .merge
    /// Off. Only a tick makes it true.
    @State private var deleteBranch = false
    @State private var merging = false
    @State private var outcome: PullRequestActionResult?

    /// The plan the button would spend, recomputed from the reading on every
    /// change. Pure — no network — which is what lets the sentence stay true as
    /// the user tries methods.
    private var plan: MergePlan? {
        guard let context else { return nil }
        return service.plan(from: context, method: method, deleteBranch: deleteBranch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 380, maxHeight: 640)
        // The read happens here, not in `body`: a view body may not run a
        // subprocess, and this one runs two.
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.map { "Merge \($0.ref.repository)#\($0.ref.number)" } ?? "Merge")
                    .font(.system(size: 13, weight: .semibold))
                Text(plan?.title ?? "Reading the pull request…")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let loadRefusal {
            ChecksNotice(symbol: "exclamationmark.triangle",
                         headline: loadRefusal.headline, detail: loadRefusal.detail,
                         remedy: loadRefusal.remedy, code: loadRefusal.code)
        } else if let plan {
            methodPicker(plan)
            branchToggle(plan)
            confirmationLine(plan)
            readinessNotice(plan)
            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome, !outcome.didSucceed {
                outcomeNotice(outcome)
            }
        } else if !loading {
            ChecksNotice(symbol: "questionmark.circle", headline: "No pull request",
                         detail: "Nothing was read for this worktree.",
                         remedy: "Open a pull request for this branch first.")
        }
    }

    /// Only the methods the repository allows — and when the settings read did
    /// not land, all three plus a warning saying we could not tell. A picker that
    /// silently hides a working button and a picker that silently offers a broken
    /// one are the same bug.
    private func methodPicker(_ plan: MergePlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Method")
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                if !plan.policy.isAuthoritative {
                    Text("settings unread")
                        .font(Tokens.fontPill)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Tokens.rowHover))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            ForEach(plan.policy.methods, id: \.rawValue) { option in
                methodRow(option)
            }
        }
    }

    private func methodRow(_ option: MergeMethod) -> some View {
        let selected = option == method
        return Button {
            method = option
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.accentColor : Tokens.textTertiary)
                Text(option.label)
                    .font(Tokens.fontRow)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .fill(selected ? Tokens.selectionFill : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(merging)
    }

    private func branchToggle(_ plan: MergePlan) -> some View {
        Toggle(isOn: $deleteBranch) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete \(plan.headRefName) after merging")
                    .font(Tokens.fontRow)
                Text("Off unless you turn it on. Deleting a branch is not undone by "
                    + "reverting the merge.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(merging)
    }

    /// The sentence. Everything above it is a control; this is the thing somebody
    /// is actually agreeing to, so it is set apart and reads as prose.
    private func confirmationLine(_ plan: MergePlan) -> some View {
        Text(plan.sentence)
            .font(Tokens.fontRow)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusCard)
                    .fill(Tokens.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radiusCard)
                    .stroke(Tokens.border))
    }

    @ViewBuilder
    private func readinessNotice(_ plan: MergePlan) -> some View {
        switch plan.readiness {
        case .ready:
            EmptyView()
        case .stillComputing:
            ChecksNotice(symbol: "clock",
                         headline: "GitHub is still working out whether this can merge",
                         detail: "Mergeability is being computed. Merging now would be a "
                            + "guess, so the button stays off.",
                         remedy: "Re-read in a moment — it usually takes seconds.")
        case .refused(let refusal):
            ChecksNotice(symbol: "exclamationmark.triangle",
                         headline: refusal.headline, detail: refusal.detail,
                         remedy: refusal.remedy, code: refusal.code)
        }
    }

    @ViewBuilder
    private func outcomeNotice(_ result: PullRequestActionResult) -> some View {
        switch result {
        case .refused(let refusal):
            ChecksNotice(symbol: "exclamationmark.triangle",
                         headline: refusal.headline, detail: refusal.detail,
                         remedy: refusal.remedy, code: refusal.code)
        case .mergeabilityUnknown(let pending):
            ChecksNotice(symbol: "clock", headline: pending.headline,
                         detail: pending.detail, remedy: pending.remedy)
        case .needsConfirmation(let confirmation):
            // Reachable only if the reading moved under the sheet between the plan
            // and the press. Saying so is the honest message; re-reading is the fix.
            ChecksNotice(symbol: "hand.raised", headline: "The pull request changed",
                         detail: confirmation.sentence,
                         remedy: "Re-read it and confirm again. Nothing was sent.")
        case .succeeded:
            EmptyView()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await load() }
            } label: {
                Label("Re-read", systemImage: "arrow.clockwise")
                    .font(Tokens.fontMeta)
            }
            .buttonStyle(.borderless)
            .disabled(loading || merging)
            .help("Ask GitHub again, then rebuild the confirmation from what it says")

            Spacer(minLength: 8)
            if merging { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(merging)
            Button("Merge") { merge() }
                // No keyboard shortcut, and emphatically not `.defaultAction`.
                // The one gesture that merges is a click on a button that sits
                // under a sentence naming what it will do.
                .disabled(!(plan?.readiness.isReady ?? false) || merging || loading)
                .help(mergeHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var mergeHelp: String {
        guard let plan else { return "Nothing has been read yet" }
        switch plan.readiness {
        case .ready: return plan.sentence
        case .stillComputing: return "GitHub has not decided whether this merges"
        case .refused(let refusal): return "\(refusal.headline). \(refusal.remedy)"
        }
    }

    // MARK: - Acting

    private func load() async {
        loading = true
        loadRefusal = nil
        let result = await service.mergeContext()
        await MainActor.run {
            loading = false
            switch result {
            case .failure(let refusal):
                loadRefusal = refusal
                context = nil
            case .success(let value):
                context = value
                loadRefusal = nil
                // Land on a method the repository actually allows, so the first
                // sentence the user reads is one that could happen.
                if !value.policy.allows(method) {
                    method = value.policy.methods.first ?? .merge
                }
            }
        }
    }

    private func merge() {
        guard let plan, plan.readiness.isReady, !merging else { return }
        merging = true
        outcome = nil
        Task {
            let result = await service.merge(plan: plan, confirmation: plan.confirmation.token)
            await MainActor.run {
                merging = false
                outcome = result
                if let receipt = result.receipt {
                    onCompleted(receipt)
                    dismiss()
                }
            }
        }
    }
}
