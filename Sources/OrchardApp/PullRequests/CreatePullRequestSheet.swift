import OrchardRuntime
import SwiftUI

/// The app's client of `PullRequestCreationService`.
///
/// Wave 25's two rules apply unchanged. **No network or subprocess in a view
/// body:** the view reads published properties, and every `gh`/git call happens in
/// `.task` or in a button's action. **Nothing on the main thread:** the service
/// runs its subprocesses on detached utility tasks; this class only awaits them.
///
/// And T92's own rule, which is the reason `push` is a separate method with its
/// own published flag: nothing here pushes as a side effect of anything else.
@MainActor
final class CreatePullRequestModel: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    /// Empty means "the repository's default branch", which is what the service
    /// resolves when no base is named. Never pre-filled with a guess.
    @Published var base = ""
    @Published var isDraft = false

    @Published private(set) var eligibility: PullRequestCreationEligibility?
    @Published private(set) var bases: [String] = []
    @Published private(set) var isChecking = false
    @Published private(set) var isCreating = false
    @Published private(set) var isPushing = false
    @Published private(set) var created: PullRequestRef?
    /// A refusal from an *action* the user took, kept apart from the eligibility
    /// banner so a failed create does not overwrite the reason the button was
    /// disabled.
    @Published private(set) var actionRefusal: PullRequestRefusal?

    /// True once the template has been offered, so a re-check does not overwrite a
    /// body the user has started editing.
    private var bodyTouchedByUser = false
    private let service = PullRequestCreationService()

    var canCreate: Bool {
        guard let eligibility, eligibility.canCreate else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCreating && !isChecking
    }

    func noteBodyEdited() { bodyTouchedByUser = true }

    /// Re-read eligibility. Called from `.task` and after a push — never from a
    /// view body, and never on a timer: this costs two `gh` round trips.
    func check(worktree: URL, hostId: String, branch: String?) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let requested = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await service.eligibility(worktree: worktree,
                                               base: requested.isEmpty ? nil : requested,
                                               hostId: hostId)
        eligibility = result
        actionRefusal = nil
        // The template is an offer, not an imposition: it fills an untouched body
        // and never overwrites one the user has typed into.
        if !bodyTouchedByUser, body.isEmpty, let template = result.template {
            body = template
        }
        if title.isEmpty, let head = result.head ?? branch {
            title = Self.titleSuggestion(fromBranch: head)
        }
        bases = await service.candidateBases(worktree: worktree)
    }

    func create(worktree: URL) async {
        guard let eligibility, let head = eligibility.head,
              let resolved = eligibility.resolvedBase else { return }
        isCreating = true
        defer { isCreating = false }
        let draft = PullRequestDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                     body: body, base: resolved, head: head, isDraft: isDraft)
        switch await service.create(worktree: worktree, draft: draft) {
        case .success(let ref):
            created = ref
            actionRefusal = nil
        case .failure(let refusal):
            actionRefusal = refusal
        }
    }

    /// Pushing is its own button and its own method. The only path in this file
    /// that writes to a remote without the user having pressed "Create".
    func push(worktree: URL, hostId: String, branch: String?) async {
        guard !isPushing else { return }
        isPushing = true
        switch await service.pushHead(worktree: worktree, hostId: hostId) {
        case .success:
            actionRefusal = nil
        case .failure(let refusal):
            actionRefusal = refusal
        }
        isPushing = false
        await check(worktree: worktree, hostId: hostId, branch: branch)
    }

    /// A branch name turned into prose, as a *starting point the user can see and
    /// edit*. This is the only place anything is suggested, it happens in a field
    /// on screen, and `create` still refuses an empty title — nothing is invented
    /// behind the user's back.
    static func titleSuggestion(fromBranch branch: String) -> String {
        let tail = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = tail.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return "" }
        return first.uppercased() + words.dropFirst()
    }
}

/// Source Control → "Pull Request…".
///
/// The banner is the point of the sheet. Every reason a pull request cannot be
/// opened is shown as its headline, `gh`'s own words and the one thing to do about
/// it, and the Create button is disabled *because* of that reason rather than for
/// an unexplained one. When the branch has not been pushed, the remedy is a button
/// the user presses — Orchard never pushes on its own.
struct CreatePullRequestSheet: View {
    let worktree: URL
    let hostId: String
    let branch: String?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = CreatePullRequestModel()
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let ref = model.created {
                        opened(ref)
                    } else {
                        banner
                        titleField
                        routeRow
                        bodyField
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 460, maxHeight: 640)
        .task {
            titleFocused = true
            await model.check(worktree: worktree, hostId: hostId, branch: branch)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Open a Pull Request")
                    .font(.system(size: 13, weight: .semibold))
                Text(branch ?? "this worktree")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.isChecking {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The whole reason this sheet exists. A refusal is never a greyed-out button
    /// with no explanation: it is a headline, gh's own sentence, and a remedy.
    @ViewBuilder
    private var banner: some View {
        if let refusal = model.actionRefusal {
            RefusalBanner(refusal: refusal, symbol: "exclamationmark.octagon")
        }
        if let eligibility = model.eligibility {
            if let refusal = eligibility.refusal {
                VStack(alignment: .leading, spacing: 8) {
                    RefusalBanner(refusal: refusal, symbol: "exclamationmark.triangle")
                    if eligibility.needsPush {
                        pushRow
                    }
                    if let existing = eligibility.existing {
                        existingRow(existing)
                    }
                }
            } else {
                readyRow(eligibility)
            }
        } else if model.isChecking {
            Label("Checking whether a pull request can be opened…", systemImage: "clock")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
        }
    }

    private func readyRow(_ eligibility: PullRequestCreationEligibility) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(commitsPhrase(eligibility))
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .font(Tokens.fontMeta)
            .foregroundStyle(Tokens.textSecondary)
            // The third state, spelled out. "We could not ask" is not "there is
            // none", and the sheet says which one it means.
            if eligibility.existingLookup == .unavailable {
                Text("Orchard could not check whether a pull request already exists — "
                    + "this is not the same as there being none.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let existing = eligibility.existing {
                existingRow(existing)
            }
        }
    }

    private func commitsPhrase(_ eligibility: PullRequestCreationEligibility) -> String {
        let route = "\(eligibility.head ?? "?") → \(eligibility.resolvedBase ?? "?")"
        guard let count = eligibility.commitsAhead else {
            return "\(route) · commits not counted"
        }
        return "\(route) · \(count) commit\(count == 1 ? "" : "s") ahead"
    }

    private func existingRow(_ ref: PullRequestRef) -> some View {
        HStack(spacing: 6) {
            Text("#\(ref.number) already exists for this branch")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
            if let url = URL(string: ref.url) {
                Link("Open it", destination: url).font(Tokens.fontMeta)
            }
        }
    }

    /// Push is an explicit act. The button says exactly which ref it will create,
    /// and nothing on this sheet pushes without it being pressed.
    private var pushRow: some View {
        HStack(spacing: 8) {
            Button(model.isPushing ? "Pushing…" : "Push branch") {
                Task { await model.push(worktree: worktree, hostId: hostId, branch: branch) }
            }
            .controlSize(.small)
            .disabled(model.isPushing || model.isChecking)
            .help("git push --set-upstream. Nothing is pushed until you press this.")
            Text("GitHub cannot see this branch yet.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
        }
    }

    // MARK: - Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Title").font(Tokens.fontHeader).foregroundStyle(Tokens.textSecondary)
            TextField("What this pull request does", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .font(Tokens.fontRow)
                .focused($titleFocused)
                .help("Required. An empty title is refused before anything is sent to GitHub.")
        }
    }

    private var routeRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Base").font(Tokens.fontHeader).foregroundStyle(Tokens.textSecondary)
                basePicker
            }
            Spacer(minLength: 8)
            Toggle("Draft", isOn: $model.isDraft)
                .toggleStyle(.checkbox)
                .font(Tokens.fontRow)
                .help("Open it as a draft pull request.")
        }
    }

    /// Remote branches only — a base lives on the remote, and offering a local-only
    /// branch would offer one that cannot be selected. "Repository default" is a
    /// real entry rather than a pre-filled guess at `main`.
    private var basePicker: some View {
        Menu {
            Button("Repository default") { rechecking { model.base = "" } }
            if !model.bases.isEmpty { Divider() }
            ForEach(model.bases, id: \.self) { name in
                Button(name) { rechecking { model.base = name } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(baseLabel).font(Tokens.fontRow).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isChecking)
    }

    private var baseLabel: String {
        if !model.base.isEmpty { return model.base }
        if let resolved = model.eligibility?.resolvedBase { return "\(resolved) (default)" }
        return "Repository default"
    }

    private var bodyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Description").font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                if model.eligibility?.template != nil {
                    Text("prefilled from the repository's template")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            // Bound through a setter rather than `.onChange` so a template offer
            // never overwrites text the user has already started editing — and so
            // this compiles on the deployment target, where `onChange` has the old
            // signature.
            TextEditor(text: Binding(get: { model.body },
                                     set: { model.body = $0; model.noteBodyEdited() }))
                .font(Tokens.fontMono)
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Tokens.border))
        }
    }

    private func opened(_ ref: PullRequestRef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Opened #\(ref.number) on \(ref.repository)", systemImage: "checkmark.seal")
                .font(Tokens.fontRow)
            if let url = URL(string: ref.url) {
                Link(ref.url, destination: url).font(Tokens.fontMeta)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(model.created == nil ? "Cancel" : "Close") { dismiss() }
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
            if model.created == nil {
                Button(model.isCreating ? "Opening…" : "Create") {
                    Task { await model.create(worktree: worktree) }
                }
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
                .help(model.eligibility?.refusal.map { "\($0.headline). \($0.remedy)" }
                    ?? "Open the pull request on GitHub.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Tokens.surface)
    }

    private func rechecking(_ change: () -> Void) {
        change()
        Task { await model.check(worktree: worktree, hostId: hostId, branch: branch) }
    }
}

/// A refusal, drawn the way `ChecksNotice` draws one: headline, `gh`'s own words,
/// the remedy, and the code so a bug report can name it.
private struct RefusalBanner: View {
    let refusal: PullRequestRefusal
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(refusal.headline)
                        .font(Tokens.fontRow)
                        .fontWeight(.semibold)
                    Text(refusal.code)
                        .font(Tokens.fontPill)
                        .foregroundStyle(Tokens.textTertiary)
                }
                if !refusal.detail.isEmpty {
                    Text(refusal.detail)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(refusal.remedy)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.selectionFill))
    }
}
