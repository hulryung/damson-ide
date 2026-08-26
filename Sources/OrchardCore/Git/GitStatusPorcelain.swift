import Foundation

/// One `git status --porcelain=v2 --branch -uall -z` reading.
///
/// Five separate `git` spawns used to fetch these five facts — the branch name, whether
/// there is an upstream, how far ahead of it HEAD is, whether the working tree is dirty,
/// and which files are untracked. Porcelain v2 carries all of them in a single process,
/// which is the whole point: a workspace switch was never blocked by one slow git call,
/// it was blocked by six fast ones per worktree.
public struct GitStatusPorcelainV2: Equatable, Sendable {
    /// Short branch name. `"HEAD"` when detached, matching what
    /// `rev-parse --abbrev-ref HEAD` used to report; empty when git said nothing.
    public var branch: String
    /// Upstream ref (`origin/main`), or nil when the branch tracks nothing.
    public var upstream: String?
    /// Commits on HEAD that the upstream does not have. Meaningless without `upstream`.
    public var ahead: Int
    public var behind: Int
    /// Any tracked modification, conflict, or untracked file — the same question
    /// `git status --porcelain` non-emptiness answered.
    public var hasChanges: Bool
    /// Untracked paths, worktree-relative. `-uall` lists files, not directories, so this
    /// matches what `ls-files --others --exclude-standard` produced.
    public var untracked: [String]
    /// Unmerged paths and their conflict code (`UU`, `AA`, `DU`, …), in the order git
    /// printed them.
    ///
    /// The same reading that answers "is this tree dirty" already names every conflict,
    /// so the conflict summary does not need a `git status --porcelain` of its own —
    /// that second spawn was the more expensive half of `refreshConflicts`.
    public var unmerged: [Unmerged]

    /// One `u` record: the worktree-relative path and git's two-letter conflict code.
    public struct Unmerged: Equatable, Sendable {
        public let path: String
        public let code: String
        public init(path: String, code: String) {
            self.path = path
            self.code = code
        }
    }

    public init(branch: String = "", upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                hasChanges: Bool = false, untracked: [String] = [],
                unmerged: [Unmerged] = []) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.hasChanges = hasChanges
        self.untracked = untracked
        self.unmerged = unmerged
    }

    /// The argument vector this parser expects. Kept next to the parser so the two can
    /// never drift — a `-z` parser fed non-`-z` output misreads quoted paths silently.
    public static let arguments = ["status", "--porcelain=v2", "--branch",
                                   "--untracked-files=all", "-z"]

    /// Parse `-z` framed porcelain v2. Unknown header lines and unknown record types are
    /// ignored rather than fatal, so a newer git that adds one cannot make the whole
    /// reading unusable.
    public static func parse(_ output: String) -> GitStatusPorcelainV2 {
        var result = GitStatusPorcelainV2()
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            guard let marker = field.first else { continue }
            switch marker {
            case "#":
                applyHeader(field, to: &result)
            case "1":
                // `1 <XY> …` ordinary change. One field each.
                guard field.dropFirst().first == " " else { continue }
                result.hasChanges = true
            case "u":
                // `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`: ten
                // space-separated columns, then the path — which runs to the NUL, so a
                // path containing spaces survives only if it is taken as the remainder
                // rather than as the last token.
                guard field.dropFirst().first == " " else { continue }
                result.hasChanges = true
                let code = String(field.dropFirst(2).prefix(2))
                if let path = Self.field(field, after: 10), !path.isEmpty {
                    result.unmerged.append(Unmerged(path: path, code: code))
                }
            case "2":
                // A rename/copy record is followed by a second field holding the
                // original path; consuming it here is what keeps the walk aligned.
                guard field.dropFirst().first == " " else { continue }
                result.hasChanges = true
                if i < fields.count { i += 1 }
            case "?":
                guard field.dropFirst().first == " " else { continue }
                result.hasChanges = true
                result.untracked.append(String(field.dropFirst(2)))
            default:
                continue
            }
        }
        return result
    }

    /// Everything after the first `columns` spaces in a porcelain record, or nil when the
    /// record has fewer columns than that. The remainder is returned verbatim, which is
    /// what makes a path with spaces in it survive.
    static func field(_ record: String, after columns: Int) -> String? {
        var seen = 0
        var index = record.startIndex
        while index < record.endIndex {
            if record[index] == " " {
                seen += 1
                if seen == columns {
                    return String(record[record.index(after: index)...])
                }
            }
            index = record.index(after: index)
        }
        return nil
    }

    private static func applyHeader(_ field: String, to result: inout GitStatusPorcelainV2) {
        let parts = field.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "branch.head":
            guard parts.count >= 3 else { return }
            // git says "(detached)"; every caller here has always seen the literal
            // "HEAD" for that state, and changing the word would change what the
            // sidebar renders for a detached worktree.
            result.branch = parts[2] == "(detached)" ? "HEAD" : parts[2]
        case "branch.upstream":
            guard parts.count >= 3 else { return }
            result.upstream = parts[2]
        case "branch.ab":
            guard parts.count >= 4 else { return }
            result.ahead = Int(parts[2].dropFirst()) ?? 0      // "+N"
            result.behind = Int(parts[3].dropFirst()) ?? 0     // "-M"
        default:
            return
        }
    }
}

/// One `git diff --raw --numstat -z <base> --` reading: change kind *and* line counts
/// for every path, from a single spawn.
///
/// git emits both requested formats in one run, so asking for `--name-status` and
/// `--numstat` separately — which is what this replaced — paid two process spawns for
/// two halves of the same walk.
public enum GitRawNumstat {
    public struct Entry: Equatable, Sendable {
        public let path: String
        /// git's status letter (`M`, `A`, `D`, `T`, `U`), or nil when only counts
        /// were reported for this path.
        public let statusLetter: String?
        public let added: Int
        public let deleted: Int
        /// git reported `-` for both counts — a binary blob.
        public let isBinary: Bool
    }

    /// `--no-renames` is explicit rather than assumed. `diff.renames` defaults to *on*,
    /// and a detected rename changes the framing of both formats: `--numstat -z` emits a
    /// three-field record whose path field is empty, and `--raw -z` follows its record
    /// with two paths instead of one. Turning it off is what the file list has always
    /// claimed to want (a rename reads as delete+add) and it is what keeps this parse
    /// unambiguous.
    public static func arguments(baseRef: String) -> [String] {
        ["diff", "--no-renames", "--raw", "--numstat", "-z", baseRef, "--"]
    }

    /// Parse the interleaved `-z` output. Records are recognized by shape rather than by
    /// section order: a raw record's first field starts with `:` and its path is the next
    /// field, while a numstat record is a single tab-separated field. That keeps the
    /// parser correct whichever order git chooses to print the two formats in.
    public static func parse(_ output: String) -> [Entry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var letters: [String: String] = [:]
        var counts: [(path: String, added: Int, deleted: Int, binary: Bool)] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            if field.hasPrefix(":") {
                // ":<srcMode> <dstMode> <srcSha> <dstSha> <STATUS>" then the path.
                guard i + 1 < fields.count else { break }
                let path = fields[i + 1]
                if let letter = field.split(separator: " ").last.map(String.init) {
                    letters[path] = letter
                }
                i += 2
                continue
            }
            i += 1
            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let binary = parts[0] == "-" || parts[1] == "-"
            counts.append((String(parts[2]), Int(parts[0]) ?? 0, Int(parts[1]) ?? 0, binary))
        }
        return counts.map {
            Entry(path: $0.path, statusLetter: letters[$0.path],
                  added: $0.added, deleted: $0.deleted, isBinary: $0.binary)
        }
    }
}
