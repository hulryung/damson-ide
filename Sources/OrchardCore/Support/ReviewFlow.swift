import Foundation

/// One node in the review file tree. Directory labels already have unary chains
/// collapsed (`Sources/OrchardCore/Git`) so the reviewer is not clicking through
/// empty single-child folders. Files carry the original `GitFileChange`.
public struct ReviewPathNode: Equatable, Sendable, Identifiable {
    public var id: String { path }
    /// Repo-relative path of this file or the collapsed directory.
    public let path: String
    /// Visible label: filename for files, collapsed chain for directories.
    public let label: String
    public let file: GitFileChange?
    public let children: [ReviewPathNode]
    /// Total files under this node (1 for a file).
    public let fileCount: Int

    public init(path: String, label: String, file: GitFileChange?,
                children: [ReviewPathNode], fileCount: Int) {
        self.path = path
        self.label = label
        self.file = file
        self.children = children
        self.fileCount = fileCount
    }

    /// `OutlineGroup` children: `nil` marks a leaf file so it is not expandable.
    public var outlineChildren: [ReviewPathNode]? {
        file == nil ? children : nil
    }
}

/// Groups a fork-point change set into a directory tree whose unary directory
/// chains have been collapsed. Staged-ness is irrelevant: the input is already
/// `GitService.diffStat` against the worktree's base commit.
public enum ReviewFileTree {
    public static func collapsedRoots(from files: [GitFileChange]) -> [ReviewPathNode] {
        let root = Node()
        for file in files {
            insert(file, into: root)
        }
        return materialize(root, prefix: "")
    }

    private final class Node {
        var file: GitFileChange?
        var children: [String: Node] = [:]
    }

    private static func insert(_ file: GitFileChange, into root: Node) {
        let parts = file.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        var current = root
        for (index, part) in parts.enumerated() {
            if current.children[part] == nil { current.children[part] = Node() }
            current = current.children[part]!
            if index == parts.count - 1 { current.file = file }
        }
    }

    private static func materialize(_ node: Node, prefix: String) -> [ReviewPathNode] {
        node.children.keys.sorted().map { name in
            collapse(name: name, node: node.children[name]!, prefix: prefix)
        }
    }

    private static func collapse(name: String, node: Node, prefix: String) -> ReviewPathNode {
        var labelParts = [name]
        var path = prefix.isEmpty ? name : prefix + "/" + name
        var current = node

        // Absorb unary *directory* children. A directory that only holds one
        // file is left intact — the folder is still a useful landmark.
        while current.file == nil,
              current.children.count == 1,
              let (childName, child) = current.children.first,
              child.file == nil {
            labelParts.append(childName)
            path += "/" + childName
            current = child
        }

        if let file = current.file, current.children.isEmpty {
            return ReviewPathNode(path: path, label: file.fileName, file: file,
                                  children: [], fileCount: 1)
        }

        let children = materialize(current, prefix: path)
        let count = children.reduce(0) { $0 + $1.fileCount }
        return ReviewPathNode(
            path: path,
            label: labelParts.joined(separator: "/"),
            file: current.file,
            children: children,
            fileCount: count)
    }
}

/// Hunk headers in a unified diff (`@@ … @@`). Line indices match
/// `String.components(separatedBy: "\n")` so they line up with `DiffLine.parse`.
public enum ReviewHunkIndex {
    /// 0-based line numbers of hunk headers. Content lines that merely start
    /// with `+@@` / `-@@` / ` @@` are not headers.
    public static func lineIndices(inDiff text: String) -> [Int] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            line.hasPrefix("@@") ? index : nil
        }
    }

    /// Wrap-around step. Empty lists stay at 0 so the caller can ignore the result.
    public static func move(current: Int, count: Int, delta: Int) -> Int {
        guard count > 0 else { return 0 }
        let start = ((current % count) + count) % count
        let next = start + delta
        return ((next % count) + count) % count
    }

    /// Keep a selection valid after the diff is reloaded with a different hunk count.
    public static func clamp(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current, 0), count - 1)
    }

    public static func positionLabel(current: Int, count: Int) -> String {
        if count == 0 { return "0 hunks" }
        return "\(current + 1)/\(count)"
    }
}

/// Push-button copy derived from `GitWorktreeStatus.unpushedCommits`.
///
/// `nil` is *no upstream* (normal for a fresh agent branch) — not the same as
/// `0`, which means the upstream exists and this branch is up to date.
public enum ReviewUpstreamState: Equatable, Sendable {
    case noUpstream
    case upToDate
    case ahead(Int)

    public init(unpushedCommits: Int?) {
        switch unpushedCommits {
        case .none:
            self = .noUpstream
        case .some(0):
            self = .upToDate
        case .some(let count):
            self = .ahead(count)
        }
    }

    public var buttonTitle: String {
        switch self {
        case .noUpstream: return "Push -u"
        case .upToDate: return "Up to date"
        case .ahead(1): return "Push 1 commit"
        case .ahead(let count): return "Push \(count) commits"
        }
    }

    public var help: String {
        switch self {
        case .noUpstream:
            return "No upstream — push and set upstream (git push -u)"
        case .upToDate:
            return "Already up to date with upstream"
        case .ahead(1):
            return "1 commit ahead of upstream"
        case .ahead(let count):
            return "\(count) commits ahead of upstream"
        }
    }

    public var canPush: Bool {
        switch self {
        case .upToDate: return false
        case .noUpstream, .ahead: return true
        }
    }
}

/// Commit is an explicit user action: a non-empty message and a dirty tree.
/// Whitespace-only messages never reach `GitService.commitAll`.
public enum ReviewCommitGate {
    public static func isMessageUsable(_ message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func canCommit(message: String, hasUncommittedChanges: Bool, isBusy: Bool) -> Bool {
        !isBusy && hasUncommittedChanges && isMessageUsable(message)
    }
}

/// Prefer git's own stderr (already embedded in `GitError.message`) over the
/// generic Swift "operation couldn't be completed" wrapper.
public enum ReviewGitFailure {
    public static func displayText(_ error: Error) -> String {
        if let git = error as? GitError { return git.message }
        return error.localizedDescription
    }
}
