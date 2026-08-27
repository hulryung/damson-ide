import Foundation
import OrchardCore
import OrchardRuntime
import SwiftUI

/// What the checks surfaces address: one workspace, named the way the runtime
/// names it. Built once by the store so no view has to know how a worktree id is
/// spelled.
struct ChecksTarget: Equatable {
    var key: WorkbenchKey
    var worktreeId: String
    var path: String
    var hostId: String
    var isFolder: Bool
}

/// The app's client of `ChecksService`.
///
/// Two rules from wave 25 shape this whole type:
///
/// * **No network or subprocess in a view body.** Views read `snapshot(for:)`,
///   which is a dictionary lookup. Reading GitHub happens in `refresh`, which is
///   called from `.task(id:)` and from the refresh button — never from `body`.
/// * **Nothing on the main thread.** `ChecksService` is an actor whose `gh` runs
///   on a detached utility task; this class only awaits it and publishes.
///
/// And T88's own rule: a snapshot is either available or carries a named reason,
/// so `ChecksSidebar` has no "nothing to show" branch to fall into.
@MainActor
final class ChecksModel: ObservableObject {
    /// Last reading per workspace. Cached here as well as in the service because
    /// the sidebar reads it on every redraw and an actor hop per redraw is not
    /// something a scrolling list can afford.
    @Published private(set) var snapshots: [WorkbenchKey: ChecksSnapshot] = [:]
    @Published private(set) var refreshing: Set<WorkbenchKey> = []
    /// Which check the details tab is showing, per workspace.
    @Published private(set) var selectedCheck: [WorkbenchKey: String] = [:]
    @Published private(set) var logs: [WorkbenchKey: CheckLogResult] = [:]
    @Published private(set) var loadingLog: Set<WorkbenchKey> = []
    /// Ticks once a second while any panel is on screen, so "checked 12s ago"
    /// stays true instead of freezing at the moment of the read.
    @Published private(set) var ageTick: Int = 0

    /// nil when the runtime could not be constructed. Every surface then shows a
    /// typed "no runtime" state rather than an empty panel.
    private let service: ChecksService?
    private var ageTimer: Timer?
    private var observers = 0

    init(service: ChecksService?) {
        self.service = service
    }

    var hasRuntime: Bool { service != nil }

    func snapshot(for key: WorkbenchKey?) -> ChecksSnapshot? {
        guard let key else { return nil }
        return snapshots[key]
    }

    func isRefreshing(_ key: WorkbenchKey?) -> Bool {
        guard let key else { return false }
        return refreshing.contains(key)
    }

    /// Age of the reading on screen. `ageTick` is what drives the redraw — it is
    /// `@Published`, so a panel observing this object re-reads the age every
    /// second. A reading shown without its age is a reading presented as now.
    func age(for key: WorkbenchKey?) -> TimeInterval? {
        guard let snapshot = snapshot(for: key) else { return nil }
        return max(0, Date().timeIntervalSince(snapshot.observedDate))
    }

    // MARK: - Reading

    /// Read this workspace's checks. `refresh: true` bypasses the service cache;
    /// otherwise a current reading (same commit, same branch, inside the TTL) is
    /// reused and no `gh` runs.
    func refresh(_ target: ChecksTarget, force: Bool = false) async {
        guard let service else {
            snapshots[target.key] = ChecksSnapshot(
                worktreeId: target.worktreeId, worktreePath: target.path, branch: nil,
                headSha: nil,
                unavailable: ChecksUnavailability(.apiError,
                    detail: "Orchard's runtime is not available in this window."))
            return
        }
        guard !refreshing.contains(target.key) else { return }
        refreshing.insert(target.key)
        defer { refreshing.remove(target.key) }
        let snapshot = await service.snapshot(
            worktreeId: target.worktreeId, path: target.path, hostId: target.hostId,
            kind: target.isFolder ? .folder : .worktree, refresh: force)
        snapshots[target.key] = snapshot
        // A check that is no longer in the rollup cannot stay selected: the details
        // tab would keep showing a run this reading does not contain.
        if let selected = selectedCheck[target.key],
           !snapshot.checks.contains(where: { $0.id == selected }) {
            selectedCheck[target.key] = nil
            logs[target.key] = nil
        }
    }

    /// Drop this workspace's reading from both caches. Used when the user asks for
    /// a hard refresh — the button says "ask GitHub again", so it must.
    func invalidate(_ target: ChecksTarget) async {
        await service?.invalidate(path: target.path)
        snapshots[target.key] = nil
    }

    // MARK: - One check's log

    func selectedCheckID(for key: WorkbenchKey?) -> String? {
        guard let key else { return nil }
        return selectedCheck[key]
    }

    func selectedCheck(for key: WorkbenchKey?) -> CheckRunSummary? {
        guard let key, let id = selectedCheck[key] else { return nil }
        return snapshots[key]?.checks.first { $0.id == id }
    }

    func log(for key: WorkbenchKey?) -> CheckLogResult? {
        guard let key else { return nil }
        return logs[key]
    }

    func isLoadingLog(_ key: WorkbenchKey?) -> Bool {
        guard let key else { return false }
        return loadingLog.contains(key)
    }

    /// Point the details tab at a check and fetch its log.
    func select(_ check: CheckRunSummary, target: ChecksTarget) {
        selectedCheck[target.key] = check.id
        logs[target.key] = nil
        Task { await loadLog(check, target: target) }
    }

    func loadLog(_ check: CheckRunSummary, target: ChecksTarget) async {
        guard let service else { return }
        guard !loadingLog.contains(target.key) else { return }
        loadingLog.insert(target.key)
        defer { loadingLog.remove(target.key) }
        let result = await service.log(worktreeId: target.worktreeId, path: target.path,
                                       check: check)
        // The user may have moved on while the log was in flight; publishing it then
        // would put one check's output under another check's name.
        guard selectedCheck[target.key] == check.id else { return }
        logs[target.key] = result
    }

    // MARK: - Age ticker

    /// Reference-counted by the visible panels: no panel on screen, no timer.
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

/// Presentation rules shared by the sidebar, the card chip, and the details tab.
/// Kept separate from the views so they are checkable without a running app.
enum ChecksPresentation {
    /// "just now" / "12s ago" / "4m ago" / "2h ago". Never "" and never absent:
    /// the age is the thing that stops a cached reading from reading as current.
    static func age(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "age unknown" }
        if seconds < 2 { return "just now" }
        if seconds < 90 { return "\(Int(seconds))s ago" }
        if seconds < 5400 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    static func color(for bucket: CheckBucket) -> Color {
        switch bucket {
        case .pass: return .green
        case .fail: return .red
        case .pending: return .yellow
        case .cancelled: return .orange
        case .skipped: return Tokens.textTertiary
        case .neutral: return Tokens.textSecondary
        case .unknown: return .purple
        }
    }

    static func color(for rollup: ChecksRollup) -> Color {
        switch rollup {
        case .pass: return .green
        case .fail: return .red
        case .pending: return .yellow
        case .neutral: return Tokens.textSecondary
        case .none: return Tokens.textTertiary
        case .unknown: return .purple
        }
    }

    static func symbol(for rollup: ChecksRollup) -> String {
        switch rollup {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        case .neutral: return "circle"
        case .none: return "circle.dashed"
        case .unknown: return "questionmark.circle"
        }
    }

    /// "3 passed · 1 failed · 2 running". Built from the buckets actually present,
    /// so a bucket with no members never shows as a zero.
    static func countsLine(_ snapshot: ChecksSnapshot) -> String {
        let parts = snapshot.counts.map { "\($0.count) \($0.bucket.label.lowercased())" }
        return parts.joined(separator: " · ")
    }

    /// `#412 Title` for a PR, with the draft state carried because a draft PR's
    /// green checks do not mean the same thing as an open PR's.
    static func title(_ pr: PullRequestSummary) -> String {
        "#\(pr.number)\(pr.isDraft ? " (draft)" : "") \(pr.title)"
    }

    /// A duration for a completed check, from the two timestamps GitHub returns.
    /// Nil when either is missing — an invented duration is worse than none.
    static func duration(_ check: CheckRunSummary) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let startedAt = check.startedAt.flatMap(formatter.date(from:)),
              let completedAt = check.completedAt.flatMap(formatter.date(from:)) else {
            return nil
        }
        let seconds = Int(max(0, completedAt.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
