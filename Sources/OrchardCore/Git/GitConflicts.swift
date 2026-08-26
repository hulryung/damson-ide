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

/// Why a conflict operation was refused. Codes are stable so a pane, the CLI, or a test
/// can name the reason instead of matching on prose.
///
/// `notUTF8` exists because the two halves of this file work at different levels: taking a
/// whole side moves *bytes*, while picking hunks needs *lines* — and a file that is not
/// valid UTF-8 has no lossless line representation. Resolving it as text used to rewrite
/// every byte git could not decode as U+FFFD and stage the result, including bytes in
/// regions the user never looked at. Refusing is the only honest answer.
public enum GitConflictError: Error, Equatable, Sendable {
    /// The working file is not valid UTF-8 (or holds NUL bytes), so it has no hunks to pick.
    case notUTF8(String)
    /// The working file could not be read at all — it is missing, or not a regular file.
    case unreadable(String)
    /// Staging was refused because `<<<<<<<` / `>>>>>>>` are still in the file.
    case markersRemain(String)
    case writeFailed(String, String)

    public var code: String {
        switch self {
        case .notUTF8: return "not_utf8"
        case .unreadable: return "unreadable"
        case .markersRemain: return "markers_remain"
        case .writeFailed: return "write_failed"
        }
    }

    public var message: String {
        switch self {
        case .notUTF8(let path):
            return "\(path) is not UTF-8 text, so it cannot be resolved hunk by hunk without "
                 + "rewriting bytes nobody chose. Take one whole side instead — that copies "
                 + "the chosen version byte for byte."
        case .unreadable(let path):
            return "cannot read conflicted file \(path)"
        case .markersRemain(let path):
            return "\(path) still contains conflict markers"
        case .writeFailed(let path, let detail):
            return "cannot write \(path): \(detail)"
        }
    }

    /// `code — message`, the line a pane or CLI renders so a refusal is never a silent no-op.
    public var displayText: String { "\(code) — \(message)" }
}

extension GitConflictError: CustomStringConvertible {
    public var description: String { displayText }
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

    /// The same test against raw bytes, for a file that may not be UTF-8 at all.
    ///
    /// Markers are ASCII, so this needs no decoding — and decoding first is exactly the bug
    /// this file exists to close: a Latin-1 file would have to be corrupted into a `String`
    /// before it could be asked whether it still holds markers.
    public static func containsMarkers(_ data: Data) -> Bool {
        let open = Data(repeating: 0x3C, count: 7)    // "<<<<<<<"
        let close = Data(repeating: 0x3E, count: 7)   // ">>>>>>>"
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            if line.starts(with: open) || line.starts(with: close) { return true }
            if lineEnd == data.endIndex { break }
            lineStart = data.index(after: lineEnd)
        }
        return false
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

/// One index stage as the UI can show it. A side that is binary is *not* the same as a
/// side that does not exist, and rendering U+FFFD soup for the first is how a reviewer
/// concludes the file was already corrupt.
public enum GitConflictStageContent: Sendable, Equatable {
    case text(String)
    /// Bytes with no lossless text form — a real binary, or text in an encoding that is not
    /// UTF-8. Called `notText` rather than `binary` because a Latin-1 source file is very
    /// much text; it just isn't text *this* code may decode.
    case notText(byteCount: Int)

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }

    /// What to render in place of content that has no text form.
    public var placeholder: String? {
        guard case .notText(let bytes) = self else { return nil }
        let noun = bytes == 1 ? "byte" : "bytes"
        return "(not UTF-8 text — \(bytes) \(noun); nothing safe to show)"
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

    /// The worktree's own git dir, resolved the way git resolves it — without asking git.
    ///
    /// `rev-parse --absolute-git-dir` is a whole process, and on the workspace-switch path
    /// it was one of two spawns buying facts that a `stat` and a one-line file read
    /// already answer: `<worktree>/.git` is either the directory itself (a primary
    /// checkout) or a file holding `gitdir: <path>` (a linked worktree). The `rev-parse`
    /// remains as the fallback for a layout neither shape covers, so a repo this reader
    /// does not understand degrades to the old cost rather than to a wrong answer.
    func gitDirectory(worktree: URL) -> URL? {
        if let direct = Self.gitDirectoryWithoutGit(worktree: worktree) { return direct }
        guard let out = git.line(in: worktree, ["rev-parse", "--absolute-git-dir"]) else {
            return nil
        }
        return URL(fileURLWithPath: out)
    }

    /// `<worktree>/.git` read as git reads it, or nil when it is neither a directory nor a
    /// `gitdir:` pointer.
    public static func gitDirectoryWithoutGit(worktree: URL) -> URL? {
        let dotGit = worktree.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }
        let target = String(trimmed.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
        return URL(fileURLWithPath: target, relativeTo: worktree).standardizedFileURL
    }

    /// The repo-wide git dir shared by every worktree (`refs/`, `packed-refs`, `objects/`).
    /// A linked worktree's git dir holds a `commondir` file naming it; for a primary
    /// checkout the two are the same directory.
    public static func commonDirectory(gitDirectory: URL) -> URL {
        let marker = gitDirectory.appendingPathComponent("commondir")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
            return gitDirectory
        }
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return gitDirectory }
        if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
        return URL(fileURLWithPath: target, relativeTo: gitDirectory).standardizedFileURL
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

    /// The same summary built from unmerged entries a caller already has.
    ///
    /// `GitService.facts` runs `git status --porcelain=v2 -z`, which names every unmerged
    /// path and its conflict code; asking `git status --porcelain` again for the identical
    /// list was the expensive half of every `refreshConflicts`. This spelling exists so
    /// that reading costs nothing extra.
    public func summary(worktree: URL,
                        unmerged: [GitStatusPorcelainV2.Unmerged]) -> GitConflictSummary {
        let files = unmerged
            .compactMap { entry in
                GitConflictKind.from(code: entry.code)
                    .map { GitConflictedFile(path: entry.path, kind: $0) }
            }
            .sorted { $0.path < $1.path }
        // The operation still has to be asked for even with no conflicted files: a merge
        // whose conflicts are all staged is mid-flight and unfinished, and that is exactly
        // the state where the user needs to be told what to do next.
        return GitConflictSummary(operation: operation(worktree: worktree), files: files)
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

    /// Contents of one index stage as the bytes git holds, or nil when git holds no such
    /// stage for this path (the side that deleted the file, or a base that never existed).
    ///
    /// This is the only content read that a resolution may write back: `git show` emits the
    /// blob verbatim, and nothing here decodes it.
    public func stageContentsData(worktree: URL, path: String, stage: GitConflictStage) -> Data? {
        // `:N:path` is resolved relative to the top of the working tree, which is exactly
        // what porcelain paths are relative to.
        git.queryData(in: worktree, ["show", ":\(stage.rawValue):\(path)"])
    }

    /// Contents of one index stage as text, or nil when the stage is absent **or its bytes
    /// are not UTF-8 text**. Strict on purpose: a lossy decode here is content that looks
    /// resolvable and silently isn't. Use `stageContent` when "there is no such side" and
    /// "that side is binary" need different words, and `stageContentsData` to write.
    public func stageContents(worktree: URL, path: String, stage: GitConflictStage) -> String? {
        stageContentsData(worktree: worktree, path: path, stage: stage).flatMap(Self.text(of:))
    }

    /// One stage, classified for display: text to show, or a byte count to describe.
    public func stageContent(worktree: URL, path: String,
                             stage: GitConflictStage) -> GitConflictStageContent? {
        guard let data = stageContentsData(worktree: worktree, path: path, stage: stage) else {
            return nil
        }
        if let text = Self.text(of: data) { return .text(text) }
        return .notText(byteCount: data.count)
    }

    /// The working-tree file parsed into hunks, or a typed refusal saying why it has none.
    ///
    /// Throwing rather than returning nil is what lets `resolve` refuse instead of writing:
    /// a caller that cannot tell "no conflict regions" from "these bytes are not text" ends
    /// up rewriting the file either way.
    public func readDocument(worktree: URL, path: String) throws -> GitConflictDocument {
        let url = worktree.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            throw GitConflictError.unreadable(path)
        }
        guard let text = Self.text(of: data) else {
            throw GitConflictError.notUTF8(path)
        }
        return GitConflictDocument.parse(text)
    }

    /// The working-tree file, parsed into hunks. Nil when the file is gone (a delete
    /// conflict) or is not UTF-8 text — `readDocument` says which.
    public func document(worktree: URL, path: String) -> GitConflictDocument? {
        try? readDocument(worktree: worktree, path: path)
    }

    /// Decode bytes as text, or nil when they are not text a resolution may round-trip.
    ///
    /// Two separate refusals wear one return value: a NUL in the head is git's own binary
    /// heuristic, and `String(data:encoding:)` is *strict* where `String(decoding:as:)`
    /// would have quietly substituted U+FFFD for every undecodable byte.
    static func text(of data: Data) -> String? {
        if data.prefix(8000).contains(0) { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // `String(data:encoding:.utf8)` is strict about undecodable bytes but still
        // swallows a leading BOM, so a resolve would drop EF BB BF from a file whose
        // header the user never touched. Anything that does not re-encode to the same
        // bytes is refused (typed `notUTF8`) rather than silently rewritten.
        guard Data(text.utf8) == data else { return nil }
        return text
    }

    // MARK: Resolution

    /// Write `choices` into the working file and, when nothing is left undecided, stage it.
    ///
    /// Staging is gated on a fully-decided file on purpose: `git add` on a file that still
    /// holds `<<<<<<<` marks the conflict resolved and lets the markers reach a commit.
    ///
    /// Throws `GitConflictError.notUTF8` rather than resolving a file whose bytes cannot
    /// survive the trip through `String` — see the type's note.
    @discardableResult
    public func resolve(worktree: URL, path: String,
                        choices: [Int: GitConflictChoice],
                        stageWhenResolved: Bool = true) throws -> GitConflictResolution {
        let document = try readDocument(worktree: worktree, path: path)
        let text = document.resolvedText(choices: choices)
        let remaining = document.unresolvedHunks(choices: choices).count
        try write(text, worktree: worktree, path: path)
        let staged = remaining == 0 && stageWhenResolved
        if staged { try stage(worktree: worktree, path: path) }
        return GitConflictResolution(path: path, text: text,
                                     remainingHunks: remaining, staged: staged)
    }

    /// Take one whole side for a path, whatever kind of conflict it is — the only route a
    /// binary conflict has, and therefore the one that has to be exact.
    ///
    /// The chosen index stage is copied **byte for byte**, including its file mode: a blob
    /// is content plus a mode, and staging content with the wrong mode is a change the user
    /// never made. When the chosen side deleted the file, the resolution *is* the delete —
    /// the file is removed and the removal staged, rather than leaving the other side's
    /// content sitting there.
    public func take(_ side: GitConflictSide, worktree: URL, path: String) throws {
        let url = worktree.appendingPathComponent(path)
        guard let data = stageContentsData(worktree: worktree, path: path, stage: side.stage) else {
            try? FileManager.default.removeItem(at: url)
            try git.run(in: worktree, ["rm", "-q", "-f", "--", path])
            return
        }
        let mode = indexMode(worktree: worktree, path: path, stage: side.stage)
        if mode == "120000" {
            // A symlink blob holds its target as content; writing it as a regular file would
            // stage a type change nobody asked for.
            try writeSymlink(target: data, worktree: worktree, path: path)
        } else {
            try write(data, worktree: worktree, path: path, mode: mode)
        }
        try stage(worktree: worktree, path: path)
    }

    /// Stage a path the user resolved by hand (in the editor, or in another tool).
    /// Refuses while conflict markers remain — staging then would bury them in a commit.
    public func stage(worktree: URL, path: String) throws {
        let url = worktree.appendingPathComponent(path)
        // Scanned as bytes: a Latin-1 file still has ASCII markers, and it must not have to
        // be decoded (and so corrupted) to be asked. Files git itself calls binary keep the
        // old exemption — a stray `<<<<<<<` inside a blob is not a marker.
        if let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0),
           GitConflictDocument.containsMarkers(data) {
            throw GitConflictError.markersRemain(path)
        }
        try git.run(in: worktree, ["add", "--", path])
    }

    /// The mode git records for one stage of a conflicted path (`100644`, `100755`,
    /// `120000`), or nil when the stage is absent.
    func indexMode(worktree: URL, path: String, stage: GitConflictStage) -> String? {
        guard let out = git.query(in: worktree, ["ls-files", "--stage", "-z", "--", path]) else {
            return nil
        }
        // "<mode> <sha> <stage>\t<path>", NUL-terminated per record.
        for record in out.split(separator: "\0", omittingEmptySubsequences: true) {
            let head = record.prefix(while: { $0 != "\t" }).split(separator: " ")
            guard head.count >= 3, Int(head[2]) == stage.rawValue else { continue }
            return String(head[0])
        }
        return nil
    }

    // MARK: Writing

    /// Overwrite the working file with exact bytes. Written via a temporary sibling +
    /// atomic replace so an interrupted write can never leave a half-resolved file behind.
    ///
    /// `mode` is git's own (`100755` / `100644`), applied after the replace because an
    /// atomic write creates a *new* file and inherits nothing from the one it replaced —
    /// which is how a resolution silently drops a script's executable bit.
    public func write(_ data: Data, worktree: URL, path: String, mode: String? = nil) throws {
        let url = worktree.appendingPathComponent(path)
        let existing = Self.permissions(of: url)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // An atomic replace cannot follow a symlink into place; drop it first so the
            // path holds the file we just decided on.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try? FileManager.default.removeItem(at: url)
            }
            try data.write(to: url, options: .atomic)
            // Start from the file's own bits (or what the umask just gave a new file) and
            // let git's mode decide only the executable ones — forcing 0644/0755 outright
            // would override a umask the user set on purpose.
            var wanted = existing ?? Self.permissions(of: url) ?? 0o644
            switch mode {
            case "100755": wanted |= 0o111
            case "100644": wanted &= ~0o111
            default: break
            }
            if wanted != Self.permissions(of: url) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: wanted)], ofItemAtPath: url.path)
            }
        } catch {
            throw GitConflictError.writeFailed(path, error.localizedDescription)
        }
    }

    /// Overwrite the working file with text. UTF-8 in, UTF-8 out — every caller of this
    /// reads its text through `readDocument`, which refuses anything that would not survive.
    public func write(_ text: String, worktree: URL, path: String) throws {
        try write(Data(text.utf8), worktree: worktree, path: path)
    }

    /// Replace the path with a symlink to `target` (a symlink blob's content is its target).
    private func writeSymlink(target: Data, worktree: URL, path: String) throws {
        let url = worktree.appendingPathComponent(path)
        guard let destination = String(data: target, encoding: .utf8), !destination.isEmpty else {
            throw GitConflictError.notUTF8(path)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if (try? url.checkResourceIsReachable()) == true
                || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try? FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createSymbolicLink(atPath: url.path,
                                                       withDestinationPath: destination)
        } catch {
            throw GitConflictError.writeFailed(path, error.localizedDescription)
        }
    }

    private static func permissions(of url: URL) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue
    }
}
