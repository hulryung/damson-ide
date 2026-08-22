import Foundation

/// Naming rules for worktrees and their branches.
///
/// Names are user-facing in three places at once — the sidebar row, the branch in
/// `git branch`, and the directory in a shell prompt — so they are generated to read well
/// rather than to be unique-by-construction. Collisions are resolved by a `-2`, `-3` suffix
/// (see `WorktreeManager.create`), never by embedding a UUID.
public enum WorktreeNaming {
    /// Collapse a free-text label into something valid as both a git ref component and a
    /// directory name.
    ///
    /// `..` is collapsed because `git check-ref-format` rejects refs containing it; leading
    /// and trailing dots/dashes are trimmed for the same reason.
    public static func sanitize(_ raw: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.contains("..") { out = out.replacingOccurrences(of: "..", with: ".") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return String(trimmed.prefix(60))
    }

    /// Whether a name is usable at all after sanitizing.
    public static func isValid(_ raw: String) -> Bool { !sanitize(raw).isEmpty }

    /// Friendly default names, so a user who just wants to start an agent doesn't have to
    /// invent a label first. Orca uses marine creatures; the orchard theme here is fruit.
    /// The generated-name pool is also the retirement vocabulary: a spent name is never
    /// reissued (the old directory may still hold agent conversation state keyed to it).
    public static let suggestedNames = [
        "apricot", "bramble", "cherry", "damson", "elderberry", "fig", "greengage",
        "hazel", "juniper", "kumquat", "lychee", "mulberry", "nectarine", "olive",
        "peach", "quince", "russet", "sloe", "tamarind", "vine", "walnut", "yuzu",
        "apple", "blackberry", "blueberry", "cantaloupe", "clementine", "cranberry",
        "date", "gooseberry", "grapefruit", "honeydew", "lemon", "lime", "mango",
        "papaya", "pear", "persimmon", "pineapple", "plum", "pomegranate",
        "raspberry", "strawberry", "tangerine",
    ]

    public static let suggestedNameSet: Set<String> = Set(suggestedNames)

    /// First suggested name not already taken (and not permanently retired), falling
    /// back to a numbered variant once the list is exhausted. Collision suffixes
    /// (`-2`, `-3`) are the v1 uniquifier and stay; retirement is an additional
    /// never-reissue gate on top.
    public static func suggestName(taken: Set<String>,
                                   isRetired: (String) -> Bool = { _ in false }) -> String {
        for name in suggestedNames where !taken.contains(name) && !isRetired(name) {
            return name
        }
        var n = 2
        while true {
            for name in suggestedNames {
                let candidate = "\(name)-\(n)"
                if !taken.contains(candidate) && !isRetired(candidate) { return candidate }
            }
            n += 1
        }
    }

    public static func suggestName(taken: Set<String>,
                                   retired: RetiredNameRegistry) -> String {
        let lookup = RetiredNames.lookup(retired, pool: suggestedNameSet)
        return suggestName(taken: taken, isRetired: lookup)
    }

    /// Branch prefix, so every agent branch is namespaced away from the user's own branches
    /// and is obvious in `git branch` output. Defaults to the git username when one is
    /// configured (matching how a team reads branch ownership), else "orchard".
    public static func branchPrefix(gitUserName: String?) -> String {
        guard let raw = gitUserName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "orchard" }
        let sanitized = sanitize(raw)
        return sanitized.isEmpty ? "orchard" : sanitized
    }

    /// Full branch name for a worktree leaf name.
    public static func branchName(prefix: String, name: String) -> String {
        let leaf = sanitize(name)
        let safeLeaf = leaf.isEmpty ? "agent" : leaf
        return prefix.isEmpty ? safeLeaf : "\(prefix)/\(safeLeaf)"
    }
}
