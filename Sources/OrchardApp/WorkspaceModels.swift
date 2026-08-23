import Foundation
import OrchardCore
import OrchardRuntime

/// Sidebar card ordering (inventory §6).
enum CardOrdering: String, CaseIterable, Identifiable {
    case manual, recent
    var id: String { rawValue }
    var label: String { self == .manual ? "Manual" : "Recent" }
}

/// What the workbench is showing — a project's checkout or one of its worktrees.
enum WorkbenchKey: Hashable {
    case projectRoot(UUID)
    case worktree(UUID)
}

/// Per-tab chrome on an agent terminal: the raw PTY, or a native chat overlay
/// of the same session. Persisted for the app session only.
enum TabViewMode: String, Hashable, Codable {
    case terminal, chat
}

enum TabKind: String, CaseIterable, Hashable, Identifiable {
    case terminal, diff, editor, browser
    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .diff: return "Diff"
        case .editor: return "Editor"
        case .browser: return "Browser"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .diff: return "plusminus"
        case .editor: return "doc.text"
        case .browser: return "globe"
        }
    }
}

enum SplitAxis: String, Hashable {
    case horizontal, vertical
}

struct WorkbenchTab: Identifiable, Hashable {
    let id: UUID
    var kind: TabKind
    var title: String
    /// When set, the terminal tab renders that agent's `DamsonSession` instead of a shell.
    var agentID: UUID?
    /// Agent tabs only. Chat is an overlay on the live PTY, never a second session.
    var viewMode: TabViewMode

    var isAgentTab: Bool { agentID != nil }

    init(id: UUID = UUID(), kind: TabKind, title: String? = nil, agentID: UUID? = nil,
         viewMode: TabViewMode = .terminal) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.label
        self.agentID = agentID
        self.viewMode = agentID == nil ? .terminal : viewMode
    }
}

struct TabGroup: Identifiable, Hashable {
    let id: UUID
    var tabs: [WorkbenchTab]
    var selectedID: UUID

    init(id: UUID = UUID(), tabs: [WorkbenchTab], selectedID: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.selectedID = selectedID ?? tabs.first?.id ?? id
    }

    var selected: WorkbenchTab? { tabs.first { $0.id == selectedID } ?? tabs.first }
}

/// Recursive split tree. Leaves are tab groups; interior nodes are H/V splits.
indirect enum SplitNode: Identifiable, Hashable {
    case group(TabGroup)
    case split(id: UUID, axis: SplitAxis, first: SplitNode, second: SplitNode)

    var id: UUID {
        switch self {
        case .group(let g): return g.id
        case .split(let id, _, _, _): return id
        }
    }

    static func makeDefault() -> SplitNode {
        let term = WorkbenchTab(kind: .terminal)
        let diff = WorkbenchTab(kind: .diff)
        return .group(TabGroup(tabs: [term, diff], selectedID: term.id))
    }

    mutating func mutateGroup(_ groupID: UUID, _ body: (inout TabGroup) -> Void) -> Bool {
        switch self {
        case .group(var group):
            guard group.id == groupID else { return false }
            body(&group)
            self = .group(group)
            return true
        case .split(let id, let axis, var first, var second):
            if first.mutateGroup(groupID, body) {
                self = .split(id: id, axis: axis, first: first, second: second)
                return true
            }
            if second.mutateGroup(groupID, body) {
                self = .split(id: id, axis: axis, first: first, second: second)
                return true
            }
            return false
        }
    }

    mutating func splitGroup(_ groupID: UUID, axis: SplitAxis) -> Bool {
        switch self {
        case .group(let group) where group.id == groupID:
            let extra = WorkbenchTab(kind: .terminal)
            let sibling = TabGroup(tabs: [extra], selectedID: extra.id)
            self = .split(id: UUID(), axis: axis, first: .group(group), second: .group(sibling))
            return true
        case .group:
            return false
        case .split(let id, let existing, var first, var second):
            if first.splitGroup(groupID, axis: axis) {
                self = .split(id: id, axis: existing, first: first, second: second)
                return true
            }
            if second.splitGroup(groupID, axis: axis) {
                self = .split(id: id, axis: existing, first: first, second: second)
                return true
            }
            return false
        }
    }

    func firstGroupID() -> UUID? {
        switch self {
        case .group(let g): return g.id
        case .split(_, _, let first, _): return first.firstGroupID()
        }
    }

    func selectedTab(in groupID: UUID) -> WorkbenchTab? {
        switch self {
        case .group(let g) where g.id == groupID:
            return g.selected
        case .group:
            return nil
        case .split(_, _, let first, let second):
            return first.selectedTab(in: groupID) ?? second.selectedTab(in: groupID)
        }
    }
}

/// User-authored card meta, persisted in T4's `orchard-data.json`
/// (`OrchardDataStore.worktreeMeta`) — the wave-2 seam close that retires the
/// pre-integration `orchard-ui-meta.json` sidecar. Records are keyed by worktree
/// id (`<repoId>::<path>`) once the owning repo is registered; until then a
/// synthetic `app::<uuid>` key holds the meta and `register` migrates it.
@MainActor
final class WorkspaceMetaStore: ObservableObject {
    private let store: OrchardDataStore
    /// Record UUID (git-config instance id) → worktree id key in the data store.
    private var keys: [UUID: String] = [:]

    init(store: OrchardDataStore) {
        self.store = store
    }

    private func key(for id: UUID) -> String {
        keys[id] ?? "app::\(id.uuidString.lowercased())"
    }

    private func meta(for id: UUID) -> WorktreeMeta? {
        store.load().worktreeMeta[key(for: id)]
    }

    /// Bind a record to its real worktree id, migrating any meta stored under the
    /// synthetic key while the repo id was still unknown.
    func register(_ id: UUID, key newKey: String) {
        let oldKey = key(for: id)
        keys[id] = newKey
        guard oldKey != newKey else { return }
        try? store.modify { data in
            if let moved = data.worktreeMeta.removeValue(forKey: oldKey),
               data.worktreeMeta[newKey] == nil {
                data.worktreeMeta[newKey] = moved
            }
        }
        objectWillChange.send()
    }

    /// Board-column id as stored. Unknown or missing ids fall back to `todo`
    /// so a custom vocabulary entry that was later removed still has a slot.
    func statusID(for id: UUID) -> String {
        meta(for: id)?.workspaceStatus ?? WorkspaceStatus.todo.rawValue
    }

    func status(for id: UUID) -> WorkspaceStatus {
        WorkspaceStatus(rawValue: statusID(for: id)) ?? .todo
    }

    func setStatus(_ status: WorkspaceStatus, for id: UUID) {
        setStatusID(status.rawValue, for: id)
    }

    func setStatusID(_ statusID: String, for id: UUID) {
        mutate(id) { $0.workspaceStatus = statusID }
    }

    func sortOrder(for id: UUID) -> Int { meta(for: id)?.sortOrder ?? 0 }

    func lastActivity(for id: UUID) -> Date { meta(for: id)?.lastActivityAt ?? .distantPast }

    func isArchived(for id: UUID) -> Bool { meta(for: id)?.isArchived ?? false }

    func setArchived(_ archived: Bool, for id: UUID) {
        mutate(id) { $0.isArchived = archived }
    }

    func touch(_ id: UUID) {
        mutate(id) { $0.lastActivityAt = Date() }
    }

    func move(_ id: UUID, delta: Int, among ids: [UUID]) {
        guard let index = ids.firstIndex(of: id) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        var ordered = ids
        ordered.swapAt(index, target)
        for (sort, item) in ordered.enumerated() {
            mutate(item, touchActivity: false) { $0.sortOrder = sort }
        }
        objectWillChange.send()
    }

    @discardableResult
    func ensure(_ id: UUID, status: WorkspaceStatus = .todo) -> WorktreeMeta {
        if let existing = meta(for: id) { return existing }
        let data = store.load()
        let nextSort = (data.worktreeMeta.values.map(\.sortOrder).max() ?? -1) + 1
        var created = WorktreeMeta(instanceId: id.uuidString, displayName: "")
        created.workspaceStatus = status.rawValue
        created.sortOrder = nextSort
        let storageKey = key(for: id)
        try? store.modify { $0.worktreeMeta[storageKey] = created }
        objectWillChange.send()
        return created
    }

    func remove(_ id: UUID) {
        let storageKey = key(for: id)
        try? store.modify { $0.worktreeMeta.removeValue(forKey: storageKey) }
        keys[id] = nil
        objectWillChange.send()
    }

    private func mutate(_ id: UUID, touchActivity: Bool = true,
                        _ body: (inout WorktreeMeta) -> Void) {
        let storageKey = key(for: id)
        try? store.modify { data in
            var meta = data.worktreeMeta[storageKey]
                ?? WorktreeMeta(instanceId: id.uuidString, displayName: "")
            body(&meta)
            if touchActivity { meta.lastActivityAt = Date() }
            data.worktreeMeta[storageKey] = meta
        }
        objectWillChange.send()
    }
}
