import Foundation
import OrchardCore
import OrchardRuntime
import SwiftUI

/// What the pull-request pane addresses: one workspace, named the way the
/// runtime names it.
struct PullRequestTarget: Equatable {
    var key: WorkbenchKey
    var path: String
    var hostId: String
}

/// The app's client of `PullRequestReadService`.
///
/// Same two rules wave 25 imposed on `ChecksModel`, for the same reasons:
///
/// * **No subprocess in a view body.** Views read `reading(for:)`, a dictionary
///   lookup. GitHub is read in `refresh`, called from `.task(id:)` and from the
///   refresh button.
/// * **Nothing on the main thread.** The service runs `gh` on a detached utility
///   task; this class awaits it and publishes.
///
/// And T93's own rule: **there is no cache**, here or in the service. What this
/// holds is the last reading it was given, stamped with when it was taken, and
/// every surface renders that age. The distinction matters — a cache decides
/// when an old value is still true, and nothing local can decide that about a
/// pull request, because a review lands on GitHub without anything on this
/// machine hearing about it.
@MainActor
final class PullRequestModel: ObservableObject {
    /// Last reading per workspace, whatever its age.
    @Published private(set) var readings: [WorkbenchKey: PullRequestReading] = [:]
    /// Why the last read failed, when it did. Never both this and a reading for
    /// the same key: a refusal replaces the reading it could not refresh, so the
    /// pane cannot show stale content under a fresh error.
    @Published private(set) var refusals: [WorkbenchKey: PullRequestRefusal] = [:]
    @Published private(set) var loading: Set<WorkbenchKey> = []
    /// Ticks once a second while a pane is on screen, so "read 12s ago" stays
    /// true rather than freezing at the moment of the read.
    @Published private(set) var ageTick: Int = 0

    private let service: PullRequestReadService?
    private var ageTimer: Timer?
    private var observers = 0

    init(service: PullRequestReadService?) {
        self.service = service
    }

    var hasRuntime: Bool { service != nil }

    func reading(for key: WorkbenchKey?) -> PullRequestReading? {
        guard let key else { return nil }
        return readings[key]
    }

    func refusal(for key: WorkbenchKey?) -> PullRequestRefusal? {
        guard let key else { return nil }
        return refusals[key]
    }

    func isLoading(_ key: WorkbenchKey?) -> Bool {
        guard let key else { return false }
        return loading.contains(key)
    }

    /// Age of the reading on screen. A reading shown without its age is a
    /// reading presented as now.
    func age(for key: WorkbenchKey?) -> TimeInterval? {
        guard let reading = reading(for: key) else { return nil }
        return max(0, Date().timeIntervalSince(reading.observedAt))
    }

    // MARK: - Reading

    /// Read this workspace's pull request. Always asks GitHub — there is nothing
    /// to serve it from.
    func refresh(_ target: PullRequestTarget) async {
        guard let service else {
            refusals[target.key] = PullRequestRefusal(.apiError,
                detail: "Orchard's runtime is not available in this window.")
            readings[target.key] = nil
            return
        }
        // A remote workspace's branch lives on another machine; answering from
        // this machine's `gh` would describe a different checkout entirely.
        guard target.hostId == "local" else {
            refusals[target.key] = PullRequestRefusal(.remoteWorkspace,
                detail: "This workspace's files live on \(target.hostId).")
            readings[target.key] = nil
            return
        }
        guard !loading.contains(target.key) else { return }
        loading.insert(target.key)
        defer { loading.remove(target.key) }

        switch await service.read(worktree: URL(fileURLWithPath: target.path)) {
        case .success(let reading):
            readings[target.key] = reading
            refusals[target.key] = nil
        case .failure(let refusal):
            refusals[target.key] = refusal
            readings[target.key] = nil
        }
    }

    func forget(_ key: WorkbenchKey) {
        readings[key] = nil
        refusals[key] = nil
    }

    // MARK: - Age ticking

    func beginObservingAge() {
        observers += 1
        guard ageTimer == nil else { return }
        ageTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ageTick &+= 1 }
        }
    }

    func endObservingAge() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        ageTimer?.invalidate()
        ageTimer = nil
    }
}

// MARK: - Store seam

extension AppStore {
    /// The workspace the pull-request pane should read, or nil when the
    /// selection cannot name one. Pure lookups, safe to call from a view body.
    func pullRequestTarget() -> PullRequestTarget? {
        guard let key = selection, let root = workspaceRoot(for: key) else { return nil }
        return PullRequestTarget(key: key,
                                 path: root.standardizedFileURL.path,
                                 hostId: executionHostId(for: key) ?? "local")
    }
}

// MARK: - Presentation

/// Colours, symbols and words for the pull-request surfaces.
///
/// Kept beside the model rather than in `DesignTokens` so the whole feature
/// reads in one directory, exactly as T88 kept `ChecksPresentation`.
enum PullRequestPresentation {

    static func color(for state: PullRequestState) -> Color {
        switch state {
        case .open: return .green
        case .merged: return .purple
        case .closed: return .red
        case .unknown: return Tokens.textTertiary
        }
    }

    static func symbol(for state: PullRequestState) -> String {
        switch state {
        case .open: return "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    static func color(for decision: ReviewDecision) -> Color {
        switch decision {
        case .approved: return .green
        case .changesRequested: return .red
        case .reviewRequired: return .yellow
        case .undecided: return Tokens.textTertiary
        case .unknown: return .purple
        }
    }

    static func symbol(for decision: ReviewDecision) -> String {
        switch decision {
        case .approved: return "checkmark.seal.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .reviewRequired: return "person.crop.circle.badge.questionmark"
        case .undecided: return "circle.dashed"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Mergeability is deliberately three words, not two. `unknown` is GitHub
    /// still computing the merge commit — a real state that must read as
    /// "checking", never as mergeable.
    static func label(for mergeable: MergeabilityState) -> String {
        switch mergeable {
        case .mergeable: return "No conflicts"
        case .conflicting: return "Conflicts"
        case .unknown: return "Mergeability unknown"
        }
    }

    static func color(for mergeable: MergeabilityState) -> Color {
        switch mergeable {
        case .mergeable: return .green
        case .conflicting: return .red
        case .unknown: return Tokens.textTertiary
        }
    }

    static func symbol(for mergeable: MergeabilityState) -> String {
        switch mergeable {
        case .mergeable: return "arrow.triangle.merge"
        case .conflicting: return "exclamationmark.triangle.fill"
        case .unknown: return "clock.arrow.circlepath"
        }
    }

    /// A review's verdict as the conversation labels it. GitHub's own word is
    /// kept for states we cannot write, so a dismissed review says "dismissed"
    /// rather than borrowing one of the three verdicts we can submit.
    static func label(forReviewState state: String) -> String {
        switch state.uppercased() {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "requested changes"
        case "COMMENTED": return "reviewed"
        case "DISMISSED": return "review dismissed"
        default: return state.replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }

    static func color(forReviewState state: String) -> Color {
        switch state.uppercased() {
        case "APPROVED": return .green
        case "CHANGES_REQUESTED": return .red
        case "COMMENTED": return Tokens.textSecondary
        case "DISMISSED": return .orange
        default: return .purple
        }
    }

    static func symbol(forReviewState state: String) -> String {
        switch state.uppercased() {
        case "APPROVED": return "checkmark.circle.fill"
        case "CHANGES_REQUESTED": return "exclamationmark.octagon.fill"
        case "COMMENTED": return "text.bubble"
        case "DISMISSED": return "arrow.uturn.backward.circle"
        default: return "questionmark.circle"
        }
    }

    /// The line a thread is anchored to, in words. The wording itself lives in
    /// `ReviewThread.anchorDescription` in the runtime, where it is tested.
    static func anchor(_ thread: ReviewThread) -> String { thread.anchorDescription }

    /// "+120 −8" with a real minus sign rather than a hyphen.
    static func diffstat(additions: Int, deletions: Int) -> String {
        "+\(additions) −\(deletions)"
    }

    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
