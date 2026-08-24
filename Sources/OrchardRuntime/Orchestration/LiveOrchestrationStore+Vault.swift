import Foundation
import OrchardOrchestration

// The Vault's read/prune seam (docs/REBUILD-PLAN.md T49). Reads are observation only
// and reuse the same decode `worker-read` serves; the single mutation deletes archive
// rows and nothing else, and only ones a freshly recomputed plan still selects.

extension LiveOrchestrationStore {
    /// Every archive in the store, grouped run → task → dispatch, with runs that still
    /// hold live coordination marked so the UI can say why they will never be pruned.
    public func vaultSnapshot(
        contentScanLimit: Int = OrchestrationStore.defaultArchiveScanLimit
    ) throws -> VaultSnapshot {
        VaultProjection.snapshot(
            records: try store.listWorkerArchives(contentScanLimit: contentScanLimit),
            liveRunIDs: try store.liveRunIDs(),
            scanLimit: max(0, contentScanLimit))
    }

    /// The pinned archive for a dispatch, decoded exactly as `worker-read` decodes it
    /// (cleaned `lines` / `rawLines`, or a transcript pin's `content`). Nil when the
    /// dispatch has nothing pinned.
    public func vaultArchive(dispatchID: String) throws -> OrchestrationArchiveView? {
        try viewArchive(dispatchID: dispatchID)
    }

    /// The dry-run: what this policy would delete right now, and how much it frees.
    /// Nothing is written.
    public func vaultPrunePreview(
        policy: ArchiveRetentionPolicy,
        now: Date = Date(),
        additionalProtectedRunIDs: Set<String> = []
    ) throws -> ArchivePrunePlan {
        // Metadata only: a preview never needs archive text, and loading it for every
        // run would make the dry-run more expensive than the delete.
        let records = try store.listWorkerArchives(contentScanLimit: 0)
        let live = try store.liveRunIDs()
        return ArchiveRetention.plan(
            records: records, policy: policy, now: now,
            protectedRunIDs: live.union(additionalProtectedRunIDs))
    }

    /// Execute a previewed prune. The plan is recomputed against the current store and
    /// only the intersection is deleted: an archive whose run went live between the
    /// preview and the confirmation is skipped and reported, never deleted on the
    /// strength of a stale preview.
    @discardableResult
    public func vaultPrune(
        policy: ArchiveRetentionPolicy,
        confirming previewed: [String],
        now: Date = Date(),
        additionalProtectedRunIDs: Set<String> = []
    ) throws -> ArchivePruneReceipt {
        guard !previewed.isEmpty else { return .empty }
        let plan = try vaultPrunePreview(
            policy: policy, now: now, additionalProtectedRunIDs: additionalProtectedRunIDs)
        let stillSelected = Set(plan.dispatchIDs)
        let deletable = previewed.filter { stillSelected.contains($0) }
        let receipt = try store.deleteWorkerTerminalArchives(dispatchIDs: deletable)
        let deleted = Set(receipt.dispatchIDs)
        return ArchivePruneReceipt(
            deletedCount: receipt.deletedCount,
            freedBytes: receipt.freedBytes,
            deletedDispatchIDs: receipt.dispatchIDs,
            skippedDispatchIDs: previewed.filter { !deleted.contains($0) })
    }
}
