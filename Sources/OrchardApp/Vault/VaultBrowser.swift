import Foundation
import OrchardRuntime

/// Observation of the runtime's archive inventory for the Vault window (T49).
/// Refreshed on focus and a modest timer like the orchestration browser — the
/// listing is a metadata query plus a bounded content scan, never the hot path.
///
/// Everything the window decides (grouping, filter matching, retention selection)
/// happens in `VaultProjection` / `ArchiveRetention`; this type only holds state and
/// hands work to the runtime.
@MainActor
final class VaultBrowser: ObservableObject {
    static let refreshInterval: TimeInterval = 12

    @Published private(set) var snapshot = VaultSnapshot.empty {
        didSet { filtered = VaultProjection.filtered(snapshot, query: filter) }
    }
    @Published var filter = "" {
        didSet {
            guard filter != oldValue else { return }
            filtered = VaultProjection.filtered(snapshot, query: filter)
        }
    }
    /// `snapshot` narrowed by `filter` — recomputed only when one of them changes,
    /// never per render pass.
    @Published private(set) var filtered = VaultSnapshot.empty
    @Published var selection: String?
    @Published var archive: OrchestrationArchiveView?
    @Published var showRaw = false
    /// A parseable transcript pin renders as its message stream unless the reader
    /// asks for the document verbatim.
    @Published var showTranscriptSource = false
    /// The loaded pin's message stream, parsed once when the archive loads — a pin
    /// runs to megabytes, so it must never be re-parsed per render pass. Nil when the
    /// archive is not a transcript, or is one that does not parse as a message stream.
    @Published private(set) var parsedTranscript: [VaultTranscriptMessage]?
    @Published var lastError: String?
    @Published var lastRefreshed: Date?

    /// Dry-run preview awaiting confirmation. Non-nil is what presents the sheet, so
    /// a delete can never be reached without one.
    @Published var prunePlan: ArchivePrunePlan?
    @Published var pruneReceipt: ArchivePruneReceipt?
    @Published var isPruning = false

    var selectedLocation: (run: VaultRunGroup, task: VaultTaskGroup, archive: VaultArchiveRow)? {
        guard let selection else { return nil }
        return snapshot.location(dispatchID: selection)
    }

    /// What the reader should render as a message stream: the parsed pin, unless the
    /// reader asked for the document verbatim.
    var transcriptMessages: [VaultTranscriptMessage]? {
        showTranscriptSource ? nil : parsedTranscript
    }

    func refresh(from store: AppStore) async {
        guard let orchestration = store.runtime?.orchestration else {
            snapshot = .empty
            archive = nil
            lastError = store.runtime == nil
                ? "Runtime is unavailable; worker archives cannot be read."
                : nil
            return
        }
        do {
            snapshot = try await orchestration.vaultSnapshot()
            lastError = nil
            lastRefreshed = Date()
            if let selection, snapshot.archive(dispatchID: selection) == nil {
                // Pruned or reset out from under the reader.
                self.selection = nil
                archive = nil
                parsedTranscript = nil
            }
            await loadArchive(from: store)
        } catch {
            lastError = String(describing: error)
        }
    }

    func select(_ dispatchID: String?, store: AppStore) async {
        selection = dispatchID
        showRaw = false
        showTranscriptSource = false
        await loadArchive(from: store)
    }

    private func loadArchive(from store: AppStore) async {
        guard let selection, let orchestration = store.runtime?.orchestration else {
            archive = nil
            parsedTranscript = nil
            return
        }
        do {
            archive = try await orchestration.vaultArchive(dispatchID: selection)
        } catch {
            archive = nil
            lastError = String(describing: error)
        }
        parsedTranscript = archive.flatMap { view in
            view.isTranscript ? view.transcript.flatMap(VaultProjection.transcriptMessages) : nil
        }
    }

    // MARK: - Retention

    /// Compute the dry run. Writes nothing; presenting the plan is what lets the
    /// user reach the delete.
    func preparePrune(from store: AppStore) async {
        guard let orchestration = store.runtime?.orchestration else {
            lastError = "Runtime is unavailable; archives cannot be pruned."
            return
        }
        pruneReceipt = nil
        do {
            prunePlan = try await orchestration.vaultPrunePreview(
                policy: store.settings.archiveRetentionPolicy)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Execute the previewed plan. The runtime recomputes it and deletes only what is
    /// still selectable, so a run that went live since the preview keeps its archives.
    func confirmPrune(from store: AppStore) async {
        guard let plan = prunePlan, !plan.isEmpty,
              let orchestration = store.runtime?.orchestration else { return }
        isPruning = true
        defer { isPruning = false }
        do {
            pruneReceipt = try await orchestration.vaultPrune(
                policy: plan.policy, confirming: plan.dispatchIDs)
            prunePlan = nil
            await refresh(from: store)
        } catch {
            lastError = String(describing: error)
            prunePlan = nil
        }
    }

    func cancelPrune() {
        prunePlan = nil
    }
}
