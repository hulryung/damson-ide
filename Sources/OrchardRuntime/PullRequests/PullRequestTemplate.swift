import Foundation

/// The repository's pull-request template, if it keeps one.
///
/// A template is a *convention*, not a configuration: GitHub finds it by looking
/// in a fixed list of places, and so do we. The list and its order are GitHub's,
/// so a repository that renders a template on github.com renders the same one
/// here. Nothing is generated when there is none — an empty body is the honest
/// prefill for a repository that never asked for one, and inventing a checklist
/// nobody agreed to is how a tool starts writing prose in the user's name.
public struct PullRequestTemplate: Equatable, Sendable {
    /// Where it was found, relative to the worktree root and spelled as the
    /// filesystem spells it — not as the candidate list spells it. On a
    /// case-insensitive volume `.github/PULL_REQUEST_TEMPLATE.md` and
    /// `.github/pull_request_template.md` are the same file, and the label should
    /// say which one is actually on disk.
    public var relativePath: String
    public var body: String

    public init(relativePath: String, body: String) {
        self.relativePath = relativePath
        self.body = body
    }
}

public extension PullRequestTemplate {

    /// Single-file locations, in the order GitHub resolves them.
    static let candidates = [
        ".github/PULL_REQUEST_TEMPLATE.md",
        ".github/pull_request_template.md",
        "PULL_REQUEST_TEMPLATE.md",
        "docs/PULL_REQUEST_TEMPLATE.md",
    ]

    /// A repository with several templates keeps them here, one per kind.
    static let directory = ".github/PULL_REQUEST_TEMPLATE"

    /// Anything larger than this is not a template somebody expects to edit in a
    /// sheet, and reading it would be a surprise cost on a UI path. Skipped rather
    /// than truncated: half a template is worse than none.
    static let maximumBytes = 1 << 20

    /// The template for this worktree, or nil when it keeps none.
    ///
    /// Absence is not an error and never becomes a refusal — most repositories have
    /// no template, and a pull request opened without one is completely ordinary.
    static func find(in worktree: URL,
                     fileManager: FileManager = .default) -> PullRequestTemplate? {
        for candidate in candidates {
            guard let found = resolve(candidate, in: worktree, fileManager: fileManager),
                  let body = read(found.url, fileManager: fileManager) else { continue }
            return PullRequestTemplate(relativePath: found.relativePath, body: body)
        }
        return firstInDirectory(worktree, fileManager: fileManager)
    }

    // MARK: - Resolution

    /// Resolve one candidate against the real directory listing.
    ///
    /// Exact case wins; a case-insensitive match is the fallback. Both are needed:
    /// on APFS-insensitive volumes `FileManager.fileExists` says yes to a spelling
    /// that is not on disk, and reporting that spelling back would put a path in
    /// the UI that `git` cannot find.
    private static func resolve(_ relativePath: String, in worktree: URL,
                                fileManager: FileManager)
        -> (url: URL, relativePath: String)? {
        var components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.popLast() else { return nil }
        let parent = components.reduce(worktree) { $0.appendingPathComponent($1) }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: parent.path) else {
            return nil
        }
        let match = entries.first { $0 == name }
            ?? entries.first { $0.lowercased() == name.lowercased() }
        guard let match else { return nil }
        let url = parent.appendingPathComponent(match)
        guard isReadableFile(url, fileManager: fileManager) else { return nil }
        return (url, (components + [match]).joined(separator: "/"))
    }

    /// The first `*.md` in `.github/PULL_REQUEST_TEMPLATE/`.
    ///
    /// "First" is a case-insensitive name sort, not whatever order the filesystem
    /// hands back: `contentsOfDirectory` makes no ordering promise, and a picker
    /// that shows a different template on different machines is a bug that only
    /// shows up on somebody else's laptop.
    private static func firstInDirectory(_ worktree: URL,
                                         fileManager: FileManager) -> PullRequestTemplate? {
        let folder = worktree.appendingPathComponent(directory)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: folder.path) else {
            return nil
        }
        let markdown = entries
            .filter { $0.lowercased().hasSuffix(".md") }
            .sorted { $0.lowercased() < $1.lowercased() }
        for name in markdown {
            let url = folder.appendingPathComponent(name)
            guard isReadableFile(url, fileManager: fileManager),
                  let body = read(url, fileManager: fileManager) else { continue }
            return PullRequestTemplate(relativePath: "\(directory)/\(name)", body: body)
        }
        return nil
    }

    private static func isReadableFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return true
    }

    /// nil for an unreadable or oversized file, so the search moves on to the next
    /// candidate instead of stopping at a file it cannot use.
    private static func read(_ url: URL, fileManager: FileManager) -> String? {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size, size > maximumBytes { return nil }
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        guard data.count <= maximumBytes else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
