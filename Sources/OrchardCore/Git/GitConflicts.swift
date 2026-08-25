import Foundation

// MARK: - Vocabulary

/// The in-progress git operation that produced the conflicts, as the working tree records
/// it. Detected from the control files git writes into the git dir — the same signals
/// `git status` reads — because a worktree in the middle of a rebase and one in the middle
/// of a merge need different words for "abort" and mean different things by "ours".
public enum GitConflictOperation: String, Sendable, Equatable, CaseIterable {
    case none, merge, rebase, cherryPick, revert

    /// Human label for the review header.
    public var label: String {
        switch self {
        case .none: return "No merge in progress"
        case .merge: return "Merge in progress"
        case .rebase: return "Rebase in progress"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        }
    }

    /// During a rebase git replays *your* commits onto the upstream, so the sides swap:
    /// "ours" is the branch being rebased onto, "theirs" is the commit being replayed.
    /// Saying "Ours"/"Theirs" without that caveat is how people resolve backwards.
    public var oursLabel: String {
        switch self {
        case .rebase: return "Ours (upstream)"
        default: return "Ours (current)"
        }
    }

    public var theirsLabel: String {
        switch self {
        case .rebase: return "Theirs (replayed commit)"
        default: return "Theirs (incoming)"
        }
    }

    public var isActive: Bool { self != .none }
}

/// Which of the three index stages a piece of content comes from. The numbers are git's
/// own (`:1:path`, `:2:path`, `:3:path`), not an invention here.
public enum GitConflictStage: Int, Sendable, Equatable, CaseIterable {
    case base = 1, ours = 2, theirs = 3

    public var label: String {
        switch self {
        case .base: return "Base"
        case .ours: return "Ours"
        case .theirs: return "Theirs"
        }
    }
}

/// One side of a two-sided choice, for whole-file resolutions.
public enum GitConflictSide: String, Sendable, Equatable, CaseIterable {
    case ours, theirs

    public var stage: GitConflictStage { self == .ours ? .ours : .theirs }
}

/// How a single path is conflicted, decoded from git's unmerged porcelain code. The kind
/// decides what the reviewer can even be offered: a both-modified file has hunks to pick
/// through, while a delete/modify conflict only has "keep the file" or "keep the delete".
public enum GitConflictKind: String, Sendable, Equatable, CaseIterable {
    case bothModified      // UU
    case bothAdded         // AA
    case bothDeleted       // DD
    case addedByUs         // AU
    case addedByThem       // UA
    case deletedByUs       // DU
    case deletedByThem     // UD

    /// The porcelain XY code this kind came from.
    public var code: String {
        switch self {
        case .bothModified: return "UU"
        case .bothAdded: return "AA"
        case .bothDeleted: return "DD"
        case .addedByUs: return "AU"
        case .addedByThem: return "UA"
        case .deletedByUs: return "DU"
        case .deletedByThem: return "UD"
        }
    }

    public static func from(code: String) -> GitConflictKind? {
        allCases.first { $0.code == code }
    }

    public var label: String {
        switch self {
        case .bothModified: return "Both modified"
        case .bothAdded: return "Both added"
        case .bothDeleted: return "Both deleted"
        case .addedByUs: return "Added by us"
        case .addedByThem: return "Added by them"
        case .deletedByUs: return "Deleted by us"
        case .deletedByThem: return "Deleted by them"
        }
    }

    /// Which index stages git holds for this kind. Asking for a stage that was never
    /// written is how a "base" pane ends up silently blank, so the UI asks first.
    public var stages: Set<GitConflictStage> {
        switch self {
        case .bothModified: return [.base, .ours, .theirs]
        case .bothAdded: return [.ours, .theirs]
        case .bothDeleted: return [.base]
        case .addedByUs: return [.ours]
        case .addedByThem: return [.theirs]
        case .deletedByUs: return [.base, .theirs]
        case .deletedByThem: return [.base, .ours]
        }
    }

    public func has(_ stage: GitConflictStage) -> Bool { stages.contains(stage) }

    /// Only content-vs-content conflicts leave `<<<<<<<` markers in the working file.
    /// The rest are resolved whole-file, because there is no text to merge.
    public var hasInlineMarkers: Bool { self == .bothModified || self == .bothAdded }

    /// What choosing this side actually does, in plain words — "keep ours" means
    /// *delete the file* in half of these cases, and a button that doesn't say so is a trap.
    public func actionLabel(for side: GitConflictSide) -> String {
        has(side.stage) ? "Keep \(side.rawValue)" : "Keep \(side.rawValue) (delete file)"
    }
}

/// One conflicted path as `git status` reports it.
public struct GitConflictedFile: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { path }
    /// Repo-relative path.
    public let path: String
    public let kind: GitConflictKind

    public init(path: String, kind: GitConflictKind) {
        self.path = path
        self.kind = kind
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

/// Everything the conflict-review tab needs in one value: what operation is stuck, and
/// which paths are unmerged.
public struct GitConflictSummary: Sendable, Equatable {
    public let operation: GitConflictOperation
    public let files: [GitConflictedFile]

    public static let none = GitConflictSummary(operation: .none, files: [])

    public init(operation: GitConflictOperation, files: [GitConflictedFile]) {
        self.operation = operation
        self.files = files
    }

    public var fileCount: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }

    /// True when the tab has something to show. An operation can be in progress with zero
    /// conflicts left (everything staged, waiting for `git commit --continue`), and that is
    /// still worth a tab — it's the state where the user has to be told what to do next.
    public var isActive: Bool { operation.isActive || !files.isEmpty }

    /// Header line: what is stuck and how much of it is left.
    public var headline: String {
        guard isActive else { return "No conflicts" }
        let noun = fileCount == 1 ? "file" : "files"
        if files.isEmpty {
            return "\(operation.label) — all conflicts resolved"
        }
        return "\(operation.label) — \(fileCount) conflicted \(noun)"
    }

    /// What the user does next once nothing is unmerged. Deliberately names the git command
    /// instead of offering a button: continuing a rebase or committing a merge is a
    /// history-changing act, and this tab resolves files, it does not finish operations.
    public var nextStepHint: String? {
        guard files.isEmpty, operation.isActive else { return nil }
        switch operation {
        case .rebase: return "Run `git rebase --continue` in a terminal to finish."
        case .merge: return "Run `git commit` in a terminal to finish the merge."
        case .cherryPick: return "Run `git cherry-pick --continue` in a terminal to finish."
        case .revert: return "Run `git revert --continue` in a terminal to finish."
        case .none: return nil
        }
    }
}

// MARK: - Marker parsing

/// What to do with one conflicted hunk.
public enum GitConflictChoice: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// Leave the markers exactly as they are — an undecided hunk must never be silently
    /// collapsed to one side.
    case unresolved
    case ours, theirs
    /// Both sides, ours first, markers dropped.
    case both

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .unresolved: return "Undecided"
        case .ours: return "Ours"
        case .theirs: return "Theirs"
        case .both: return "Both"
        }
    }
}

/// One `<<<<<<< / ======= / >>>>>>>` region in a working-tree file.
public struct GitConflictHunk: Sendable, Equatable, Identifiable, Hashable {
    /// Ordinal within the file; also the key callers use to record a choice.
    public let index: Int
    public var id: Int { index }
    /// Label git wrote after `<<<<<<<` (usually the current branch).
    public let oursLabel: String
    /// Label git wrote after `>>>>>>>` (the incoming ref).
    public let theirsLabel: String
    /// Label after `|||||||`, present only with `merge.conflictStyle = diff3`.
    public let baseLabel: String?
    public let ours: [String]
    public let theirs: [String]
    /// Common ancestor lines, only when the file carries diff3 markers.
    public let base: [String]?
    /// Half-open line range this hunk occupies in the file, markers included.
    public let range: Range<Int>

    public init(index: Int, oursLabel: String, theirsLabel: String, baseLabel: String?,
                ours: [String], theirs: [String], base: [String]?, range: Range<Int>) {
        self.index = index
        self.oursLabel = oursLabel
        self.theirsLabel = theirsLabel
        self.baseLabel = baseLabel
        self.ours = ours
        self.theirs = theirs
        self.base = base
        self.range = range
    }

    /// 1-based first line of the hunk, for a "line 42" label.
    public var startLine: Int { range.lowerBound + 1 }

    public func lines(for choice: GitConflictChoice) -> [String] {
        switch choice {
        case .ours: return ours
        case .theirs: return theirs
        case .both: return ours + theirs
        case .unresolved: return []
        }
    }
}

/// A working-tree file split into plain lines plus the conflicted regions inside it.
///
/// Pure text in, pure text out: no git process is involved, which is what makes the
/// resolution rules testable without a repo. An unterminated conflict region (a file the
/// user half-edited) is deliberately *not* reported as a hunk — rewriting a region whose
/// end we never found would corrupt the file.
public struct GitConflictDocument: Sendable, Equatable {
    public let lines: [String]
    public let hunks: [GitConflictHunk]
    /// Whether the source text ended with a newline, so a rewrite preserves it exactly.
    public let hasTrailingNewline: Bool

    public init(lines: [String], hunks: [GitConflictHunk], hasTrailingNewline: Bool) {
        self.lines = lines
        self.hunks = hunks
        self.hasTrailingNewline = hasTrailingNewline
    }

    public var hunkCount: Int { hunks.count }
    public var hasConflictMarkers: Bool { !hunks.isEmpty }

    private static let oursMarker = "<<<<<<<"
    private static let baseMarker = "|||||||"
    private static let splitMarker = "======="
    private static let theirsMarker = ">>>>>>>"

    /// True when any line looks like a conflict marker, terminated or not. Used to refuse
    /// to stage a file that still carries markers.
    public static func containsMarkers(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.hasPrefix(oursMarker) || line.hasPrefix(theirsMarker)
        }
    }

    public static func parse(_ text: String) -> GitConflictDocument {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trailing = text.hasSuffix("\n")
        // "a\nb\n" splits to ["a", "b", ""] — that final empty element is the newline, not
        // a line of the file.
        if trailing, !lines.isEmpty { lines.removeLast() }

        var hunks: [GitConflictHunk] = []
        var i = 0
        while i < lines.count {
            guard lines[i].hasPrefix(oursMarker) else { i += 1; continue }
            guard let hunk = scan(lines, from: i, index: hunks.count) else {
                // No closing marker: the rest of the file is left alone.
                i += 1
                continue
            }
            hunks.append(hunk)
            i = hunk.range.upperBound
        }
        return GitConflictDocument(lines: lines, hunks: hunks, hasTrailingNewline: trailing)
    }

    /// Scan one complete region starting at `start`, or nil if it never closes.
    private static func scan(_ lines: [String], from start: Int, index: Int) -> GitConflictHunk? {
        var ours: [String] = [], theirs: [String] = [], base: [String]? = nil
        var baseLabel: String? = nil
        var section = 0   // 0 = ours, 1 = base (diff3), 2 = theirs
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix(oursMarker) {
                // A nested/restarted region means the first one never closed.
                return nil
            } else if line.hasPrefix(baseMarker), section == 0 {
                section = 1
                base = []
                baseLabel = label(after: baseMarker, in: line)
            } else if line.hasPrefix(splitMarker), section < 2 {
                section = 2
            } else if line.hasPrefix(theirsMarker) {
                guard section == 2 else { return nil }
                return GitConflictHunk(
                    index: index,
                    oursLabel: label(after: oursMarker, in: lines[start]) ?? "ours",
                    theirsLabel: label(after: theirsMarker, in: line) ?? "theirs",
                    baseLabel: baseLabel,
                    ours: ours, theirs: theirs, base: base,
                    range: start..<(i + 1))
            } else {
                switch section {
                case 0: ours.append(line)
                case 1: base?.append(line)
                default: theirs.append(line)
                }
            }
            i += 1
        }
        return nil
    }

    private static func label(after marker: String, in line: String) -> String? {
        let rest = line.dropFirst(marker.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Rebuild the file with each hunk replaced by the chosen side. Hunks with no recorded
    /// choice — or an explicit `.unresolved` — keep their markers verbatim, so a partial
    /// pass through a big file never loses the parts you haven't decided yet.
    public func resolvedText(choices: [Int: GitConflictChoice]) -> String {
        var out: [String] = []
        var cursor = 0
        for hunk in hunks {
            if cursor < hunk.range.lowerBound {
                out.append(contentsOf: lines[cursor..<hunk.range.lowerBound])
            }
            let choice = choices[hunk.index] ?? .unresolved
            if choice == .unresolved {
                out.append(contentsOf: lines[hunk.range])
            } else {
                out.append(contentsOf: hunk.lines(for: choice))
            }
            cursor = hunk.range.upperBound
        }
        if cursor < lines.count {
            out.append(contentsOf: lines[cursor...])
        }
        var text = out.joined(separator: "\n")
        if hasTrailingNewline, !text.isEmpty { text += "\n" }
        return text
    }

    /// Hunks still carrying markers under `choices`.
    public func unresolvedHunks(choices: [Int: GitConflictChoice]) -> [GitConflictHunk] {
        hunks.filter { (choices[$0.index] ?? .unresolved) == .unresolved }
    }

    public func isFullyResolved(choices: [Int: GitConflictChoice]) -> Bool {
        unresolvedHunks(choices: choices).isEmpty
    }
}

/// What a write actually did. `staged` is the honest answer to "is git done with this
/// file": a file written with markers still in it is saved but *not* added, because
/// staging it would tell the merge a lie.
public struct GitConflictResolution: Sendable, Equatable {
    public let path: String
    public let text: String
    public let remainingHunks: Int
    public let staged: Bool

    public init(path: String, text: String, remainingHunks: Int, staged: Bool) {
        self.path = path
        self.text = text
        self.remainingHunks = remainingHunks
        self.staged = staged
    }
}

// MARK: - Service

/// Read/resolve the conflicts in a worktree. Every method shells out through `GitRunner`;
/// nothing is cached, so the caller decides refresh cadence exactly as it does for
/// `GitService`.
///
/// Deliberately narrow: this type resolves *files*. It never runs `merge --abort`,
/// `rebase --continue`, or `commit` — finishing or abandoning an operation rewrites
/// history, and that stays an explicit act the user performs in a terminal.
public struct GitConflictService: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = .shared) {
        self.git = git
    }

    // MARK: Detection

    /// Which operation is mid-flight, from the control files in the git dir. A worktree has
    /// its own git dir (`.git/worktrees/<name>`), so this is asked per worktree and
    /// resolved through `rev-parse` rather than by guessing at `<path>/.git`.
    public func operation(worktree: URL) -> GitConflictOperation {
        guard let gitDir = gitDirectory(worktree: worktree) else { return .none }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: gitDir.appendingPathComponent(name).path)
        }
        // Rebase first: an interactive rebase that hits a conflict writes rebase-merge/ and
        // (for a merge-strategy step) MERGE_HEAD too, and calling that "a merge" would put
        // the wrong words on the ours/theirs buttons.
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return .none
    }

    private func gitDirectory(worktree: URL) -> URL? {
        guard let out = git.line(in: worktree, ["rev-parse", "--absolute-git-dir"]) else {
            return nil
        }
        return URL(fileURLWithPath: out)
    }

    /// Unmerged paths, from `git status --porcelain -z`.
    public func conflictedFiles(worktree: URL) -> [GitConflictedFile] {
        guard let out = git.query(in: worktree, ["status", "--porcelain", "-z"]) else { return [] }
        return Self.parsePorcelain(out)
    }

    /// Operation + files in one value.
    public func summary(worktree: URL) -> GitConflictSummary {
        GitConflictSummary(operation: operation(worktree: worktree),
                           files: conflictedFiles(worktree: worktree))
    }

    /// Decode `git status --porcelain -z` output into the unmerged entries only.
    ///
    /// The `-z` framing is what makes this safe: paths with spaces or newlines arrive
    /// intact. Rename/copy entries carry a *second* NUL-terminated field (the origin path)
    /// which must be consumed, or every record after the first rename is read one field out
    /// of step and the parse silently invents paths.
    public static func parsePorcelain(_ text: String) -> [GitConflictedFile] {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var files: [GitConflictedFile] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            let path = String(field.dropFirst(3))
            // R./C. entries are "XY new\0old\0" — skip the origin field.
            if code.hasPrefix("R") || code.hasPrefix("C") { i += 1 }
            if let kind = GitConflictKind.from(code: code) {
                files.append(GitConflictedFile(path: path, kind: kind))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: Content

    /// Contents of one index stage, or nil when git holds no such stage for this path
    /// (the side that deleted the file, or a base that never existed).
    public func stageContents(worktree: URL, path: String, stage: GitConflictStage) -> String? {
        // `:N:path` is resolved relative to the top of the working tree, which is exactly
        // what porcelain paths are relative to.
        git.query(in: worktree, ["show", ":\(stage.rawValue):\(path)"])
    }

    /// The working-tree file, parsed into hunks. Nil when the file is gone (a delete
    /// conflict) or unreadable as UTF-8.
    public func document(worktree: URL, path: String) -> GitConflictDocument? {
        let url = worktree.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8000).contains(0) { return nil }   // binary: no hunks to pick
        return GitConflictDocument.parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: Resolution

    /// Write `choices` into the working file and, when nothing is left undecided, stage it.
    ///
    /// Staging is gated on a fully-decided file on purpose: `git add` on a file that still
    /// holds `<<<<<<<` marks the conflict resolved and lets the markers reach a commit.
    @discardableResult
    public func resolve(worktree: URL, path: String,
                        choices: [Int: GitConflictChoice],
                        stageWhenResolved: Bool = true) throws -> GitConflictResolution {
        guard let document = document(worktree: worktree, path: path) else {
            throw GitError("cannot read conflicted file \(path)")
        }
        let text = document.resolvedText(choices: choices)
        let remaining = document.unresolvedHunks(choices: choices).count
        try write(text, worktree: worktree, path: path)
        let staged = remaining == 0 && stageWhenResolved
        if staged { try stage(worktree: worktree, path: path) }
        return GitConflictResolution(path: path, text: text,
                                     remainingHunks: remaining, staged: staged)
    }

    /// Take one whole side for a path, whatever kind of conflict it is. When the chosen
    /// side deleted the file, the resolution *is* the delete — the file is removed and the
    /// removal staged, rather than leaving the other side's content sitting there.
    public func take(_ side: GitConflictSide, worktree: URL, path: String) throws {
        let url = worktree.appendingPathComponent(path)
        if let content = stageContents(worktree: worktree, path: path, stage: side.stage) {
            try write(content, worktree: worktree, path: path)
            try stage(worktree: worktree, path: path)
        } else {
            try? FileManager.default.removeItem(at: url)
            try git.run(in: worktree, ["rm", "-q", "-f", "--", path])
        }
    }

    /// Stage a path the user resolved by hand (in the editor, or in another tool).
    /// Refuses while conflict markers remain — staging then would bury them in a commit.
    public func stage(worktree: URL, path: String) throws {
        let url = worktree.appendingPathComponent(path)
        if let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0),
           GitConflictDocument.containsMarkers(String(decoding: data, as: UTF8.self)) {
            throw GitError("\(path) still contains conflict markers")
        }
        try git.run(in: worktree, ["add", "--", path])
    }

    /// Overwrite the working file. Written via a temporary sibling + atomic replace so an
    /// interrupted write can never leave a half-resolved file behind.
    public func write(_ text: String, worktree: URL, path: String) throws {
        let url = worktree.appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw GitError("cannot write \(path): \(error.localizedDescription)")
        }
    }
}
