import Foundation

/// Joins a listening process to a workspace when the process cwd is the worktree
/// path or a descendant of it. Nested worktrees win (longest matching prefix).
/// Failures return nil — callers skip the listener; they never fail the sweep.
public enum PortAttribution {
    public struct PreparedWorkspace: Sendable {
        public let workspace: PortWorkspaceProbe
        fileprivate let normalizedPath: String
    }

    public static func prepare(_ workspaces: [PortWorkspaceProbe]) -> [PreparedWorkspace] {
        workspaces.compactMap { workspace in
            let path = normalize(workspace.path)
            return path.isEmpty ? nil : PreparedWorkspace(workspace: workspace, normalizedPath: path)
        }.sorted { $0.normalizedPath.count > $1.normalizedPath.count }
    }

    public static func attribute(
        cwd: String?,
        to workspaces: [PortWorkspaceProbe]
    ) -> (workspace: PortWorkspaceProbe, confidence: PortAttributionConfidence)? {
        attributePrepared(cwd: cwd, to: prepare(workspaces))
    }

    public static func attributePrepared(
        cwd: String?,
        to workspaces: [PreparedWorkspace]
    ) -> (workspace: PortWorkspaceProbe, confidence: PortAttributionConfidence)? {
        guard let cwd, !cwd.isEmpty, !workspaces.isEmpty else { return nil }
        let candidate = normalize(cwd)
        guard !candidate.isEmpty else { return nil }

        for prepared in workspaces {
            if isSameOrDescendant(candidate, of: prepared.normalizedPath) {
                return (prepared.workspace, .cwd)
            }
        }
        return nil
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
