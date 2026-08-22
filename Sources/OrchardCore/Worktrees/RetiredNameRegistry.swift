import Foundation

/// Compact, never-evicting registry of generated worktree names already issued
/// for one repo.
///
/// A spent name's directory may still hold agent conversation state keyed by
/// that path, so reissuing it would hand the next occupant the previous
/// occupant's transcripts. Entries are never removed on workspace deletion;
/// the registry grows monotonically until the repo itself is removed.
///
/// Compaction: names come from a fixed pool and the suggester only reaches
/// tier N+1 once every tier-N name is taken, so a completed tier is exactly
/// `pool.count` entries that no longer need listing. `exhaustedTiers` covers
/// every tier at or below it; `names` holds only what sits above it.
public struct RetiredNameRegistry: Codable, Equatable, Sendable {
    public var exhaustedTiers: Int
    public var names: [String]

    public init(exhaustedTiers: Int = 0, names: [String] = []) {
        self.exhaustedTiers = max(0, exhaustedTiers)
        self.names = names
    }

    public static let empty = RetiredNameRegistry()

    public var isEmpty: Bool { exhaustedTiers == 0 && names.isEmpty }
}

public enum RetiredNames {
    /// Widest tier `poolNameTier` will parse; a watermark past it could never
    /// be reached by a generated name.
    public static let maxExhaustedTiers = 999_999

    /// Tier 1 is the bare pool name; tier N is `name-N`.
    public static func nameAtTier(_ poolName: String, tier: Int) -> String {
        tier <= 1 ? poolName : "\(poolName)-\(tier)"
    }

    /// Null for anything the suggester never emits — a non-pool base, or a
    /// collision variant like `apricot-2-3` — so no watermark can cover those.
    /// Load-bearing for user-typed names: `fix-login-2` must not read as
    /// retired just because tier 2 is spent. `apricot-1` is also null: tier 1
    /// is the bare pool name, never the `-1` suffix.
    public static func poolNameTier(_ name: String, pool: Set<String>) -> Int? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if pool.contains(normalized) { return 1 }
        guard let dash = normalized.lastIndex(of: "-") else { return nil }
        let base = String(normalized[..<dash])
        let suffix = String(normalized[normalized.index(after: dash)...])
        guard pool.contains(base),
              let tier = Int(suffix), suffix == String(tier),
              tier >= 2, tier <= maxExhaustedTiers else { return nil }
        return tier
    }

    public static func isRetired(_ name: String, registry: RetiredNameRegistry,
                                 pool: Set<String>) -> Bool {
        lookup(registry, pool: pool)(name)
    }

    /// Membership without reconstructing a compacted tier. Built once per
    /// create attempt because the create loop may probe many names.
    public static func lookup(_ registry: RetiredNameRegistry,
                              pool: Set<String>) -> (String) -> Bool {
        let explicit = Set(registry.names.map { $0.lowercased() })
        let exhausted = min(max(0, registry.exhaustedTiers), maxExhaustedTiers)
        return { name in
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if explicit.contains(normalized) { return true }
            if let tier = poolNameTier(normalized, pool: pool) {
                return tier <= exhausted
            }
            return false
        }
    }

    /// Folds every completed tier into the watermark and drops the names it
    /// now covers. Tiers can complete out of order (a collision can spend
    /// `apricot-2` while tier 1 is still open); those higher-tier names wait
    /// in the explicit set until their own tier completes.
    public static func compact(_ registry: RetiredNameRegistry,
                               pool: [String]) -> RetiredNameRegistry {
        let poolSet = Set(pool)
        var exhausted = min(max(0, registry.exhaustedTiers), maxExhaustedTiers)
        var names = Set(registry.names.map { $0.lowercased() })
        while exhausted < maxExhaustedTiers, tierIsComplete(names, tier: exhausted + 1, pool: pool) {
            exhausted += 1
        }
        names = names.filter { name in
            guard let tier = poolNameTier(name, pool: poolSet) else { return true }
            return tier > exhausted
        }
        return RetiredNameRegistry(exhaustedTiers: exhausted,
                                   names: names.sorted())
    }

    /// Returns nil when nothing changed, so callers can skip the write.
    public static func adding(_ incoming: [String],
                              to registry: RetiredNameRegistry,
                              pool: [String]) -> RetiredNameRegistry? {
        let poolSet = Set(pool)
        let isRetired = lookup(registry, pool: poolSet)
        let added = incoming.filter { !isRetired($0) }
        guard !added.isEmpty else { return nil }
        return compact(
            RetiredNameRegistry(exhaustedTiers: registry.exhaustedTiers,
                                names: registry.names + added.map { $0.lowercased() }),
            pool: pool)
    }

    private static func tierIsComplete(_ names: Set<String>, tier: Int, pool: [String]) -> Bool {
        for poolName in pool {
            if !names.contains(nameAtTier(poolName, tier: tier)) { return false }
        }
        return true
    }
}
