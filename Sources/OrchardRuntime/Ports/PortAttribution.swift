import Foundation

/// Joins a listening process to a workspace when the process cwd is the worktree
/// path or a descendant of it. Nested worktrees win (longest matching prefix).
/// Failures return nil — callers skip the listener; they never fail the sweep.
public enum PortAttribution {
    public static func attribute(
        cwd: String?,
        to workspaces: [PortWorkspaceProbe]
    ) -> (workspace: PortWorkspaceProbe, confidence: PortAttributionConfidence)? {
        guard let cwd, !cwd.isEmpty, !workspaces.isEmpty else { return nil }
        let candidate = normalize(cwd)
        guard !candidate.isEmpty else { return nil }

        var best: PortWorkspaceProbe?
        var bestLength = 0
        for workspace in workspaces {
            let root = normalize(workspace.path)
            guard !root.isEmpty, isSameOrDescendant(candidate, of: root) else { continue }
            if root.count > bestLength {
                best = workspace
                bestLength = root.count
            }
        }
        return best.map { ($0, .cwd) }
    }

    public static func normalize(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        if value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        // standardizedFileURL collapses `.` / `..` without requiring the path to exist.
        if value.hasPrefix("/") || value.hasPrefix(".") {
            value = URL(fileURLWithPath: value).standardizedFileURL.path
            if value.count > 1, value.hasSuffix("/") { value.removeLast() }
        }
        return value
    }

    public static func isSameOrDescendant(_ candidate: String, of parent: String) -> Bool {
        candidate == parent || candidate.hasPrefix(parent + "/")
    }
}
