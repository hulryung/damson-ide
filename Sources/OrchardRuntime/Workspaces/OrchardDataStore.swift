import Foundation
import OrchardCore

/// Durable user-authored state: repo registry, worktree meta, lineage, generated-name
/// retirement, folder workspaces, custom board-status vocabulary.
///
/// Git worktree *facts* stay in v1's git-config persistence (see `WorktreeManager`) —
/// this file is the half that would drift if it tried to mirror `git worktree list`.
///
/// Writes are atomic: encode → write a sibling temp → `synchronize` → `replaceItemAt`.
/// A crash mid-write leaves the previous file intact.
public struct OrchardData: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var repos: [RepoRecord]
    public var folderWorkspaces: [FolderWorkspaceRecord]
    public var worktreeMeta: [String: WorktreeMeta]
    public var worktreeLineageById: [String: WorktreeLineage]
    public var retiredWorktreeNamesByRepo: [String: RetiredNameRegistry]
    public var workspaceStatusVocabulary: [WorkspaceStatusDefinition]
    public var automations: [Automation]
    public var automationRuns: [AutomationRun]
    /// T21 browser session profiles: user-created isolated profiles (the built-in
    /// default profile is synthesized, never stored) and each browser workspace's
    /// profile binding, keyed by workspace key (worktree path).
    public var browserProfiles: [BrowserProfile]
    public var browserWorkspaceProfiles: [String: String]
    /// T29 remote hosts: the registered SSH connection targets behind `ssh:<name>`
    /// execution host ids. A record here is a name for a target, never a claim that
    /// the target is reachable (see `HostLivenessVerdict`).
    public var hosts: [HostRecord]

    public init(schemaVersion: Int = 1,
                repos: [RepoRecord] = [],
                folderWorkspaces: [FolderWorkspaceRecord] = [],
                worktreeMeta: [String: WorktreeMeta] = [:],
                worktreeLineageById: [String: WorktreeLineage] = [:],
                retiredWorktreeNamesByRepo: [String: RetiredNameRegistry] = [:],
                workspaceStatusVocabulary: [WorkspaceStatusDefinition] = WorkspaceStatusDefinition.defaults,
                automations: [Automation] = [], automationRuns: [AutomationRun] = [],
                browserProfiles: [BrowserProfile] = [],
                browserWorkspaceProfiles: [String: String] = [:],
                hosts: [HostRecord] = []) {
        self.schemaVersion = schemaVersion
        self.repos = repos
        self.folderWorkspaces = folderWorkspaces
        self.worktreeMeta = worktreeMeta
        self.worktreeLineageById = worktreeLineageById
        self.retiredWorktreeNamesByRepo = retiredWorktreeNamesByRepo
        self.workspaceStatusVocabulary = workspaceStatusVocabulary
        self.automations = automations
        self.automationRuns = automationRuns
        self.browserProfiles = browserProfiles
        self.browserWorkspaceProfiles = browserWorkspaceProfiles
        self.hosts = hosts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, repos, folderWorkspaces, worktreeMeta, worktreeLineageById
        case retiredWorktreeNamesByRepo, workspaceStatusVocabulary, automations, automationRuns
        case browserProfiles, browserWorkspaceProfiles, hosts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        repos = try c.decodeIfPresent([RepoRecord].self, forKey: .repos) ?? []
        folderWorkspaces = try c.decodeIfPresent([FolderWorkspaceRecord].self, forKey: .folderWorkspaces) ?? []
        worktreeMeta = try c.decodeIfPresent([String: WorktreeMeta].self, forKey: .worktreeMeta) ?? [:]
        worktreeLineageById = try c.decodeIfPresent([String: WorktreeLineage].self, forKey: .worktreeLineageById) ?? [:]
        retiredWorktreeNamesByRepo = try c.decodeIfPresent([String: RetiredNameRegistry].self, forKey: .retiredWorktreeNamesByRepo) ?? [:]
        workspaceStatusVocabulary = try c.decodeIfPresent([WorkspaceStatusDefinition].self, forKey: .workspaceStatusVocabulary) ?? WorkspaceStatusDefinition.defaults
        automations = try c.decodeIfPresent([Automation].self, forKey: .automations) ?? []
        automationRuns = try c.decodeIfPresent([AutomationRun].self, forKey: .automationRuns) ?? []
        browserProfiles = try c.decodeIfPresent([BrowserProfile].self, forKey: .browserProfiles) ?? []
        browserWorkspaceProfiles = try c.decodeIfPresent([String: String].self, forKey: .browserWorkspaceProfiles) ?? [:]
        hosts = try c.decodeIfPresent([HostRecord].self, forKey: .hosts) ?? []
    }

    public static let empty = OrchardData()
}

public struct RepoRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case git, folder }

    public var id: String
    public var path: String
    public var displayName: String
    public var baseRef: String
    public var kind: Kind
    public var addedAt: Date
    /// The `ExecutionHostId` raw value the checkout lives on (`local` today; see
    /// docs/design/remote-hosts.md for the staged remote-worktree work).
    public var hostId: String

    public init(id: String = UUID().uuidString.lowercased(),
                path: String,
                displayName: String? = nil,
                baseRef: String = "HEAD",
                kind: Kind = .git,
                addedAt: Date = Date(),
                hostId: String = "local") {
        self.id = id
        self.path = path
        let fallback = URL(fileURLWithPath: path).lastPathComponent
        if let displayName, !displayName.isEmpty {
            self.displayName = displayName
        } else {
            self.displayName = fallback
        }
        self.baseRef = baseRef
        self.kind = kind
        self.addedAt = addedAt
        self.hostId = hostId
    }
}

public struct FolderWorkspaceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var repoId: String
    public var instanceId: String
    public var folderPath: String
    public var name: String
    public var comment: String
    public var workspaceStatus: String?
    public var isPinned: Bool
    public var isUnread: Bool
    public var isArchived: Bool
    public var sortOrder: Int
    public var lastActivityAt: Date
    public var createdAt: Date
    public var linkedIssue: String?
    public var linkedPR: String?

    public init(id: String,
                repoId: String,
                instanceId: String = UUID().uuidString,
                folderPath: String,
                name: String,
                comment: String = "",
                workspaceStatus: String? = nil,
                isPinned: Bool = false,
                isUnread: Bool = false,
                isArchived: Bool = false,
                sortOrder: Int = 0,
                lastActivityAt: Date = Date(),
                createdAt: Date = Date(),
                linkedIssue: String? = nil,
                linkedPR: String? = nil) {
        self.id = id
        self.repoId = repoId
        self.instanceId = instanceId
        self.folderPath = folderPath
        self.name = name
        self.comment = comment
        self.workspaceStatus = workspaceStatus
        self.isPinned = isPinned
        self.isUnread = isUnread
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.lastActivityAt = lastActivityAt
        self.createdAt = createdAt
        self.linkedIssue = linkedIssue
        self.linkedPR = linkedPR
    }
}

public final class OrchardDataStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cache: OrchardData

    public init(url: URL) {
        self.url = url
        self.cache = Self.read(from: url)
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orchard", isDirectory: true)
            .appendingPathComponent("orchard-data.json")
    }

    public func load() -> OrchardData {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    public func modify(_ body: (inout OrchardData) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var next = cache
        body(&next)
        try Self.write(next, to: url)
        cache = next
    }

    public func replace(_ data: OrchardData) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.write(data, to: url)
        cache = data
    }

    // MARK: - Atomic IO

    private static func read(from url: URL) -> OrchardData {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONBridge.decoder.decode(OrchardData.self, from: data)
        else { return .empty }
        return decoded
    }

    /// Encode to a sibling temp, fsync, then replace the destination. A crash
    /// between encode and replace leaves the previous `orchard-data.json` intact.
    private static func write(_ state: OrchardData, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = try JSONBridge.encoder.encode(state)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [
            .posixPermissions: 0o600
        ])
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: payload)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
