import Foundation
import OrchardCore
import OrchardRuntime

/// The store-side seam for the checks surfaces (T88).
///
/// Kept out of `AppStore.swift` so the whole feature reads in one directory; the
/// store itself owns only the `ChecksModel` reference. Nothing here runs git or
/// `gh` — it resolves *identity* (which workspace, spelled as the runtime spells
/// it) and manages the check-details tab.
extension AppStore {
    /// The workspace the checks surfaces should read, or nil when the selection
    /// cannot name one. Pure lookups, safe to call from a view body.
    func checksTarget() -> ChecksTarget? {
        guard let key = selection, let root = workspaceRoot(for: key) else { return nil }
        let hostId = executionHostId(for: key) ?? "local"
        let path = root.standardizedFileURL.path
        return ChecksTarget(key: key, worktreeId: worktreeIdentity(for: key, path: path),
                            path: path, hostId: hostId, isFolder: false)
    }

    /// `<repoId>::<path>` when the owning project has a registry id, else the path
    /// alone. Only ever a label on the reading, so an unregistered project still
    /// gets checks rather than an error about identity.
    private func worktreeIdentity(for key: WorkbenchKey, path: String) -> String {
        let projectID: UUID?
        switch key {
        case .projectRoot(let id): projectID = id
        case .worktree(let id):
            projectID = projects.first { $0.record(id: id) != nil }?.id
        }
        guard let projectID,
              let repoID = projects.first(where: { $0.id == projectID })?.repoID else {
            return path
        }
        return WorktreeIdentity.make(repoId: repoID, path: path)
    }

    /// Open the check-details tab for the current workspace, or focus it if it is
    /// already open. Unlike the conflict tab this one is never opened on its own:
    /// it appears because the user clicked a check.
    func openCheckDetails() {
        guard let key = selection else { return }
        if let found = ensureLayout(for: key).findTab(kind: .checkDetails) {
            selectTab(found.tabID, in: found.groupID, key: key)
            return
        }
        guard let groupID = focusedGroupID ?? ensureLayout(for: key).firstGroupID() else { return }
        let tab = WorkbenchTab(kind: .checkDetails)
        updateLayout(key) { node in
            _ = node.mutateGroup(groupID) { group in
                group.tabs.append(tab)
                group.selectedID = tab.id
            }
        }
    }
}
