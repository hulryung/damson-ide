import Foundation

/// One engine row for the ⌘N picker: a single canonical id, with its alias
/// shown once in the label (`claude (claude-code)`). Aliases are never listed
/// as separate choices — that was the v1 drift that made `--agent claude`
/// look like a different engine from `claude-code`.
public struct EngineListingItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let aliases: [String]

    public init(id: String, label: String, aliases: [String] = []) {
        self.id = id
        self.label = label
        self.aliases = aliases
    }
}

/// UI-free composer planning: fan-out names, engine rows, base-ref seeding,
/// and the two validations the sheet shows inline (empty name, bad fan-out).
///
/// Kept out of SwiftUI so the collision rules can be unit-tested without a
/// window. `WorktreeManager.create` still uniquifies as a safety net; this
/// plan is what the composer *intends* so titles and cards get `-2`/`-3`
/// instead of N copies of the same label.
public enum ComposerPlanning {
    /// Matches the steppers in the composer and settings. Zero and 9+ are
    /// rejected rather than silently clamped, so a bad value is visible.
    public static let fanOutRange = 1...8

    // MARK: - Validation

    /// Why this draft cannot be created, or `nil` when it can. Name is
    /// sanitized the same way a worktree directory is, so "!!!" fails here
    /// instead of becoming an empty leaf at `git worktree add`.
    public static func validationError(name: String, count: Int) -> String? {
        if !WorktreeNaming.isValid(name) {
            return "Give this worktree a name that contains at least one letter or number."
        }
        if !fanOutRange.contains(count) {
            return "Fan-out must be between \(fanOutRange.lowerBound) and \(fanOutRange.upperBound)."
        }
        return nil
    }

    // MARK: - Fan-out names

    /// N independent worktree leaves for one prompt. The first free name is
    /// unsuffixed; collisions (existing worktrees *and* earlier slots in this
    /// batch) take `-2`, `-3`, … — the same rule `WorktreeManager` uses on
    /// branches and directories, never a UUID.
    public static func fanOutNames(name: String, count: Int, taken: Set<String>) -> [String] {
        let leaf = WorktreeNaming.sanitize(name)
        guard !leaf.isEmpty, count > 0 else { return [] }
        var used = taken
        var names: [String] = []
        names.reserveCapacity(count)
        for _ in 0..<count {
            let next = uniqueName(leaf, taken: used)
            names.append(next)
            used.insert(next)
        }
        return names
    }

    /// First free name using the v1 `-2`, `-3` suffix rule. The desired leaf
    /// is tried as-is; only a collision adds a number, and that number starts
    /// at 2 so we never emit `name-1`.
    public static func uniqueName(_ desired: String, taken: Set<String>) -> String {
        guard taken.contains(desired) else { return desired }
        var n = 2
        while taken.contains("\(desired)-\(n)") { n += 1 }
        return "\(desired)-\(n)"
    }

    // MARK: - Base refs

    /// Picker contents: the repo's resolved default first, then local
    /// branches, de-duplicated. `origin/main` is a valid default and is not a
    /// local branch, so it has to be inserted rather than hoped-for in the
    /// `git for-each-ref refs/heads` list.
    public static func seedBaseRefs(resolvedDefault: String, localBranches: [String]) -> [String] {
        var seen = Set<String>()
        var refs: [String] = []
        let seed = resolvedDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seed.isEmpty {
            refs.append(seed)
            seen.insert(seed)
        }
        for branch in localBranches {
            let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            refs.append(name)
            seen.insert(name)
        }
        return refs
    }

    // MARK: - Engine listing

    /// One row per canonical engine. Extra spellings appear in the label
    /// once (`claude (claude-code)`); they are never extra rows.
    public static func engineListing<S: Sequence>(
        engines: S
    ) -> [EngineListingItem] where S.Element == (id: String, aliases: [String]) {
        var seen = Set<String>()
        var items: [EngineListingItem] = []
        for engine in engines {
            let id = engine.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let key = id.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let aliases = uniqueAliases(engine.aliases, canonicalID: id)
            let label: String
            if let alias = aliases.first {
                label = "\(alias) (\(id))"
            } else {
                label = id
            }
            items.append(EngineListingItem(id: id, label: label, aliases: aliases))
        }
        return items
    }

    private static func uniqueAliases(_ aliases: [String], canonicalID: String) -> [String] {
        let canonical = canonicalID.lowercased()
        var seen = Set<String>()
        var out: [String] = []
        for raw in aliases {
            let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !alias.isEmpty else { continue }
            let key = alias.lowercased()
            guard key != canonical, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(alias)
        }
        return out
    }
}
