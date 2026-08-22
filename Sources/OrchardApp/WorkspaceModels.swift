import Foundation
import OrchardCore

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

    init(id: UUID = UUID(), kind: TabKind, title: String? = nil, agentID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.label
        self.agentID = agentID
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

/// User-authored card meta. T4 will own this in `orchard-data.json`; until that
/// lands the app keeps a sidecar so status / sort / recency survive relaunch.
struct WorkspaceCardMeta: Codable, Equatable {
    var statusID: String
    var sortOrder: Int
    var lastActivityAt: Date
}

@MainActor
final class WorkspaceMetaStore: ObservableObject {
    @Published private var items: [UUID: WorkspaceCardMeta] = [:]
    private let url: URL
    private var nextSort = 0

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = root.appendingPathComponent("Orchard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("orchard-ui-meta.json")
        load()
    }

    func status(for id: UUID) -> WorkspaceStatus {
        if let raw = items[id]?.statusID, let status = WorkspaceStatus(rawValue: raw) {
            return status
        }
        return .todo
    }

    func setStatus(_ status: WorkspaceStatus, for id: UUID) {
        var meta = ensure(id)
        meta.statusID = status.rawValue
        items[id] = meta
        persist()
    }

    func sortOrder(for id: UUID) -> Int { items[id]?.sortOrder ?? 0 }

    func lastActivity(for id: UUID) -> Date { items[id]?.lastActivityAt ?? .distantPast }

    func touch(_ id: UUID) {
        var meta = ensure(id)
        meta.lastActivityAt = Date()
        items[id] = meta
        persist()
    }

    func move(_ id: UUID, delta: Int, among ids: [UUID]) {
        guard let index = ids.firstIndex(of: id) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        var ordered = ids
        ordered.swapAt(index, target)
        for (sort, item) in ordered.enumerated() {
            var meta = ensure(item)
            meta.sortOrder = sort
            items[item] = meta
        }
        persist()
        objectWillChange.send()
    }

    func ensure(_ id: UUID, status: WorkspaceStatus = .todo) -> WorkspaceCardMeta {
        if let existing = items[id] { return existing }
        let meta = WorkspaceCardMeta(statusID: status.rawValue, sortOrder: nextSort, lastActivityAt: Date())
        nextSort += 1
        items[id] = meta
        persist()
        return meta
    }

    func remove(_ id: UUID) {
        items[id] = nil
        persist()
    }

    private struct FilePayload: Codable {
        var items: [String: WorkspaceCardMeta]
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(FilePayload.self, from: data)
        else { return }
        var decoded: [UUID: WorkspaceCardMeta] = [:]
        var maxSort = 0
        for (key, value) in payload.items {
            guard let id = UUID(uuidString: key) else { continue }
            decoded[id] = value
            maxSort = max(maxSort, value.sortOrder)
        }
        items = decoded
        nextSort = maxSort + 1
    }

    private func persist() {
        let payload = FilePayload(items: Dictionary(uniqueKeysWithValues: items.map { ($0.key.uuidString, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
