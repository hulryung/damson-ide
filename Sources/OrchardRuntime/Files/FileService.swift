import Foundation

/// Worktree-confined file reads. Every path is resolved against a caller-supplied
/// root; `..`, absolute paths, and symlink escapes are rejected before any IO
/// beyond the confinement check itself.
///
/// Listings are lazy (one directory at a time). Recursive name listing,
/// filename search, and full-text content search are bounded so a huge tree
/// can't stall the RPC.
public struct FileService: Sendable {
    /// Text preview cap. Matches Orca's mobile text read (`MOBILE_FILE_READ_MAX_BYTES`).
    public static let defaultTextBudget = 512 * 1024
    /// Image/binary preview cap when the caller does not supply `maxBytes`.
    public static let defaultBinaryBudget = 10 * 1024 * 1024
    /// NUL-in-the-first-chunk heuristic; same window git uses.
    public static let binarySniffBytes = 8192
    public static let defaultSearchLimit = 16
    public static let maxSearchLimit = 64
    public static let defaultListLimit = 2000
    public static let maxListLimit = 5000
    /// Full-text match cap (Orca's renderer search is 2000; we default lower).
    public static let defaultContentSearchLimit = 200
    public static let maxContentSearchLimit = 2000
    public static let defaultPerFileMatchLimit = 20
    public static let maxPerFileMatchLimit = 100
    /// Per-file read cap for content search (same as the text preview budget).
    public static let contentSearchFileByteBudget = defaultTextBudget
    /// Stop scanning once this many bytes have been read across files.
    public static let contentSearchTotalByteBudget = 8 * 1024 * 1024
    public static let maxExcerptLength = 200
    public static let maxQueryBytes = 8 * 1024

    static let imageMIME: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "bmp": "image/bmp",
        "ico": "image/x-icon",
        "svg": "image/svg+xml",
        "avif": "image/avif",
        "heic": "image/heic",
    ]

    public init() {}

    // MARK: - Public API

    /// Immediate children of `relativePath` (empty = the root). Directories first,
    /// then Finder-style numeric name order. Dotfiles are omitted unless asked.
    public func readDir(root: URL, relativePath: String = "", showDotfiles: Bool = false)
        throws -> [FileDirEntry] {
        let dir = try resolve(root: root, relativePath: relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            throw FileServiceError.notFound(relativePath.isEmpty ? "." : relativePath)
        }
        guard isDir.boolValue else { throw FileServiceError.notADirectory }

        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])
        var entries: [FileDirEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            let name = url.lastPathComponent
            if name == "." || name == ".." { continue }
            if !showDotfiles && name.hasPrefix(".") { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = values.isSymbolicLink ?? false
            // Listings never follow the link: a symlink-to-dir stays a file row
            // until the caller expands it (which re-runs confinement on the target).
            let isDirectory = isSymlink ? false : (values.isDirectory ?? false)
            entries.append(FileDirEntry(name: name, isDirectory: isDirectory, isSymlink: isSymlink))
        }
        sortEntries(&entries)
        return entries
    }

    /// Byte-budgeted file contents with binary/image/MIME detection.
    /// Over-budget files throw `file_too_large` rather than shipping a truncated
    /// payload the client would then treat as complete.
    public func preview(root: URL, relativePath: String, maxBytes: Int? = nil) throws -> FilePreview {
        let url = try resolve(root: root, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileServiceError.notFound(relativePath)
        }
        let values = try resourceValues(at: url)
        if values.isDirectory ?? false { throw FileServiceError.notAFile }

        let size = Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0)
        let ext = url.pathExtension.lowercased()
        let mime = Self.imageMIME[ext]
        let isImage = mime != nil
        let budget = maxBytes ?? (isImage ? Self.defaultBinaryBudget : Self.defaultTextBudget)
        if size > budget { throw FileServiceError.fileTooLarge }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try preview(data: data, relativePath: relativePath, maxBytes: budget)
    }

    /// Classify already-read bytes the way `preview` does. The remote file transport
    /// (T85) must go through this so a Latin-1 file cannot become a String of U+FFFD
    /// just because it crossed ssh as text.
    public func preview(data: Data, relativePath: String, maxBytes: Int? = nil) throws -> FilePreview {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        let mime = Self.imageMIME[ext]
        let isImage = mime != nil
        let budget = maxBytes ?? (isImage ? Self.defaultBinaryBudget : Self.defaultTextBudget)
        if data.count > budget { throw FileServiceError.fileTooLarge }

        if let mime {
            return FilePreview(content: data.base64EncodedString(), isBinary: true, isImage: true,
                               mimeType: mime, byteLength: data.count)
        }
        guard let text = Self.text(of: data) else {
            // Two refusals, one shape: a NUL in the head is git's binary heuristic, and
            // everything else that fails a *strict* decode is content no String can carry
            // back to disk unchanged. Either way `content` stays empty rather than
            // handing the editor a buffer whose save would rewrite the file.
            return FilePreview(content: "", isBinary: true, isImage: false, mimeType: nil,
                               byteLength: data.count,
                               notTextReason: Self.containsNUL(data) ? .nulBytes : .notUTF8)
        }
        return FilePreview(content: text,
                           isBinary: false, isImage: false, mimeType: "text/plain",
                           byteLength: data.count)
    }

    /// The file's bytes, exactly as they sit on disk, subject to the same budget as
    /// `preview`. This is the read half of a byte-exact round trip: nothing here
    /// decodes, so `write(root:relativePath:data:)` can put back what this returned.
    public func readData(root: URL, relativePath: String, maxBytes: Int? = nil) throws -> Data {
        let url = try resolve(root: root, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileServiceError.notFound(relativePath)
        }
        let values = try resourceValues(at: url)
        if values.isDirectory ?? false { throw FileServiceError.notAFile }
        let budget = maxBytes ?? Self.defaultBinaryBudget
        let size = Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0)
        if size > budget { throw FileServiceError.fileTooLarge }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if data.count > budget { throw FileServiceError.fileTooLarge }
        return data
    }

    /// Atomic byte-exact write confined to `root`. Overwrites an existing file;
    /// creates a new file only when the parent directory already exists (the
    /// editor never mkdir's). Directories and path escapes are rejected.
    ///
    /// This is the primitive every write goes through: it puts down the caller's
    /// bytes and nothing else.
    @discardableResult
    public func write(root: URL, relativePath: String, data: Data) throws -> FileStatInfo {
        let url = try writeTarget(root: root, relativePath: relativePath)
        try data.write(to: url, options: .atomic)
        return try stat(root: root, relativePath: relativePath)
    }

    /// Atomic UTF-8 text write. Same confinement as the byte-exact overload, plus one
    /// refusal: the file already on disk must itself be UTF-8 text.
    ///
    /// The guard is the whole point of this wave. `String` → UTF-8 is exact, but the
    /// String an editor holds came from a *decode*, and a decode of non-UTF-8 bytes is
    /// lossy — writing it back replaces every byte git could not decode with U+FFFD,
    /// across the whole file, including regions nobody opened. `preview` already refuses
    /// to hand out such a String; this refuses the write even if one reached us anyway.
    /// Byte content that genuinely needs replacing goes through the `data:` overload.
    @discardableResult
    public func write(root: URL, relativePath: String, contents: String) throws -> FileStatInfo {
        let url = try writeTarget(root: root, relativePath: relativePath)
        try assertTextWritable(url: url, relativePath: relativePath)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return try stat(root: root, relativePath: relativePath)
    }

    /// Confinement + existence checks shared by both writes.
    private func writeTarget(root: URL, relativePath: String) throws -> URL {
        let url = try resolve(root: root, relativePath: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try resourceValues(at: url)
            if values.isDirectory ?? false { throw FileServiceError.notAFile }
        } else {
            var isDir: ObjCBool = false
            let parent = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir),
                  isDir.boolValue else {
                throw FileServiceError.notFound(relativePath)
            }
        }
        return url
    }

    /// Refuse a text write over bytes a text read could not have produced. A brand-new
    /// file has nothing to lose, so it passes; anything the editor could not have opened
    /// (over-budget, binary, undecodable) is refused with the reason named.
    private func assertTextWritable(url: URL, relativePath: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let size = Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0)
        if size == 0 { return }
        // Larger than the editor could ever have loaded, so this String cannot be a
        // decode of it — refusing beats truncating a file to whatever is in a buffer.
        if size > Self.defaultTextBudget { throw FileServiceError.fileTooLarge }
        guard let existing = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw FileServiceError.unreadable(relativePath)
        }
        if Self.text(of: existing) == nil { throw FileServiceError.notUTF8(relativePath) }
    }

    public func stat(root: URL, relativePath: String = "") throws -> FileStatInfo {
        let url = try resolve(root: root, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileServiceError.notFound(relativePath.isEmpty ? "." : relativePath)
        }
        let values = try resourceValues(at: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let isSymlink = values.isSymbolicLink ?? false
        let isDirectory = isSymlink ? false : (values.isDirectory ?? false)
        return FileStatInfo(size: size, isDirectory: isDirectory, isSymlink: isSymlink, mtime: mtime)
    }

    /// Recursive relative paths, optionally name-filtered. `.git` is never walked.
    /// Dot-directories are skipped unless `showDotfiles`. Result is sorted and capped.
    public func list(root: URL, query: String? = nil, showDotfiles: Bool = false,
                     limit: Int = FileService.defaultListLimit) throws -> FileListResult {
        let cap = clamp(limit, lo: 1, hi: Self.maxListLimit)
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var matches: [String] = []
        var total = 0
        try walk(root: root, showDotfiles: showDotfiles) { rel, name, isDir in
            if isDir { return }
            if !needle.isEmpty {
                let hayName = name.lowercased()
                let hayPath = rel.lowercased()
                let q = needle.lowercased()
                if !hayName.contains(q) && !hayPath.contains(q) { return }
            }
            total += 1
            if matches.count < cap { matches.append(rel) }
        }
        matches.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return FileListResult(files: matches, totalCount: total, truncated: total > matches.count)
    }

    /// Bounded filename search (basename-first ranking). Not full-text.
    public func search(root: URL, query: String, showDotfiles: Bool = false,
                       limit: Int = FileService.defaultSearchLimit) throws -> FileSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileServiceError.invalidArgument("search requires a query")
        }
        let cap = clamp(limit, lo: 1, hi: Self.maxSearchLimit)
        let q = trimmed.lowercased()
        var ranked: [(score: Int, path: String, name: String)] = []
        try walk(root: root, showDotfiles: showDotfiles) { rel, name, isDir in
            if isDir { return }
            let hayName = name.lowercased()
            let hayPath = rel.lowercased()
            let score: Int
            if hayName == q {
                score = 0
            } else if hayName.hasPrefix(q) {
                score = 1
            } else if hayName.contains(q) {
                score = 2
            } else if hayPath.contains(q) {
                score = 3
            } else {
                return
            }
            ranked.append((score, rel, name))
        }
        ranked.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        let total = ranked.count
        let hits = ranked.prefix(cap).map { FileSearchHit(relativePath: $0.path, basename: $0.name) }
        return FileSearchResult(files: Array(hits), totalCount: total, truncated: total > cap)
    }

    /// Bounded full-text search. Binary files (NUL sniff) and over-budget files
    /// are skipped; include/exclude globs match worktree-relative paths.
    /// Results never leave the root — the walker already refuses symlink escapes.
    public func contentSearch(root: URL, query: String,
                              options: FileContentSearchOptions = FileContentSearchOptions())
        throws -> FileContentSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileServiceError.invalidArgument("search requires a query")
        }
        if trimmed.utf8.count > Self.maxQueryBytes {
            throw FileServiceError.invalidArgument("query exceeds 8 KB")
        }
        let cap = clamp(options.limit, lo: 1, hi: Self.maxContentSearchLimit)
        let perFile = clamp(options.perFileLimit, lo: 1, hi: Self.maxPerFileMatchLimit)
        let fileBudget = max(1, options.fileByteBudget)
        let totalBudget = max(1, options.totalByteBudget)
        let excerptCap = max(16, options.maxExcerptLength)
        let include = try options.include.map(FileGlob.init)
        let exclude = try options.exclude.map(FileGlob.init)
        let compare: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]

        var matches: [FileContentHit] = []
        var scanned = 0
        var truncated = false
        try walk(root: root, showDotfiles: options.showDotfiles) { rel, _, isDir in
            if truncated { return }
            if isDir { return }
            if !include.isEmpty && !FileGlob.any(include, matches: rel) { return }
            if FileGlob.any(exclude, matches: rel) { return }
            let kind = self.kind(of: rel)
            if kind == "image" || kind == "binary" { return }

            let url: URL
            do {
                url = try resolve(root: root, relativePath: rel)
            } catch {
                // Symlink escape, vanished file, etc. — skip this entry rather
                // than aborting the whole search.
                return
            }
            let size = Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber)?.int64Value ?? 0)
            if size <= 0 || size > fileBudget { return }
            if scanned + size > totalBudget {
                truncated = true
                return
            }
            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                return
            }
            if data.count > fileBudget || Self.containsNUL(data) { return }
            scanned += data.count
            // Display-only decode. Search never writes, so a lossy fallback here costs a
            // mojibake excerpt rather than a rewritten file — and dropping Latin-1 files
            // entirely would hide ASCII matches that are really there. Nothing in this
            // function may be routed to a write; use `readData` for that.
            let text = Self.text(of: data) ?? String(decoding: data, as: UTF8.self)

            var lineNo = 0
            var fileHits = 0
            text.enumerateLines { line, stop in
                lineNo += 1
                guard line.range(of: trimmed, options: compare) != nil else { return }
                if matches.count >= cap || fileHits >= perFile {
                    truncated = true
                    stop = true
                    return
                }
                matches.append(FileContentHit(
                    path: rel, line: lineNo,
                    excerpt: Self.excerpt(line: line, query: trimmed, options: compare,
                                          maxLength: excerptCap)))
                fileHits += 1
                if matches.count >= cap || fileHits >= perFile {
                    // A later line or file may still match; the next iteration
                    // (or the next file) sets truncated if so. Conservative:
                    // hitting the cap is enough of a bound signal.
                    if matches.count >= cap { truncated = true }
                }
            }
        }
        matches.sort { a, b in
            let pathOrder = a.path.localizedStandardCompare(b.path)
            if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
            return a.line < b.line
        }
        if matches.count > cap {
            matches = Array(matches.prefix(cap))
            truncated = true
        }
        return FileContentSearchResult(matches: matches, totalCount: matches.count,
                                       truncated: truncated)
    }

    /// Classify a path the way `file open` reports `kind`.
    public func kind(of relativePath: String) -> String {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if Self.imageMIME[ext] != nil { return "image" }
        switch ext {
        case "md", "mdx", "markdown": return "markdown"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "svg",
             "pdf", "zip", "mp3", "mp4", "mov", "avif", "heic", "woff", "woff2":
            return "binary"
        default: return "text"
        }
    }

    // MARK: - Path confinement

    /// Resolve `relativePath` to a URL that is still inside `root` after
    /// standardization and, if the path exists, after following symlinks.
    public func resolve(root: URL, relativePath: String) throws -> URL {
        let rootStd = root.standardizedFileURL
        let rootPath = rootStd.path
        guard !rootPath.isEmpty else {
            throw FileServiceError.invalidArgument("empty worktree root")
        }

        let raw = relativePath.replacingOccurrences(of: "\\", with: "/")
        if raw.contains("\0") {
            throw FileServiceError.pathEscape("path contains a NUL byte")
        }
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            throw FileServiceError.pathEscape("absolute paths are not allowed")
        }

        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return existingOrSelf(rootStd)
        }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." {
                throw FileServiceError.pathEscape(
                    "path '\(relativePath)' is not a safe worktree-relative path")
            }
        }

        var url = rootStd
        for part in parts { url.appendPathComponent(part) }
        let standardized = url.standardizedFileURL
        try assertInside(standardized.path, root: rootPath, original: relativePath)

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir) {
            let real = standardized.resolvingSymlinksInPath()
            let realRoot = rootStd.resolvingSymlinksInPath()
            try assertInside(real.path, root: realRoot.path, original: relativePath)
            return real
        }
        return standardized
    }

    /// Relativize an absolute path that already lives inside `root`; otherwise
    /// treat it as a relative path (which `resolve` will still confine).
    public func relativePath(from raw: String, root: URL) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: trimmed).standardizedFileURL
            let rootStd = root.standardizedFileURL
            try assertInside(candidate.path, root: rootStd.path, original: trimmed)
            if candidate.path == rootStd.path { return "" }
            let prefix = rootStd.path.hasSuffix("/") ? rootStd.path : rootStd.path + "/"
            return String(candidate.path.dropFirst(prefix.count))
        }
        return trimmed.replacingOccurrences(of: "\\", with: "/")
    }

    // MARK: - Internals

    private func walk(root: URL, showDotfiles: Bool,
                      visit: (_ relativePath: String, _ name: String, _ isDirectory: Bool) throws -> Void)
        throws {
        let rootStd = try resolve(root: root, relativePath: "")
        guard let enumerator = FileManager.default.enumerator(
            at: rootStd,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        let prefix = rootStd.path.hasSuffix("/") ? rootStd.path : rootStd.path + "/"
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if name == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = values.isSymbolicLink ?? false
            let isDirectory = isSymlink ? false : (values.isDirectory ?? false)
            if !showDotfiles && name.hasPrefix(".") {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            if rel.isEmpty { continue }
            try visit(rel, name, isDirectory)
            // Don't walk through a symlink: its target may sit outside the root.
            if isSymlink { enumerator.skipDescendants() }
        }
    }

    private func resourceValues(at url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw FileServiceError.notFound(url.lastPathComponent)
        }
    }

    private func existingOrSelf(_ url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return url.resolvingSymlinksInPath()
        }
        return url
    }

    private func assertInside(_ path: String, root: String, original: String) throws {
        if path == root { return }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) { return }
        throw FileServiceError.pathEscape(
            "path '\(original)' resolves outside the worktree root")
    }

    private func sortEntries(_ entries: inout [FileDirEntry]) {
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func clamp(_ value: Int, lo: Int, hi: Int) -> Int {
        min(max(value, lo), hi)
    }

    static func containsNUL(_ data: Data) -> Bool {
        let window = data.prefix(binarySniffBytes)
        return window.contains(0)
    }

    /// Decode bytes as text, or nil when they are not text that can survive the trip back
    /// to disk. A NUL in the head is git's own binary heuristic; the rest is decided by
    /// actually performing the round trip.
    ///
    /// Neither obvious decoder is enough on its own. `String(decoding:as:)` substitutes
    /// U+FFFD for every undecodable byte and calls it success. `String(data:encoding:.utf8)`
    /// is strict about that, but *eats a leading byte-order mark* — so a BOM'd UTF-8 file
    /// would come back three bytes shorter than it went in, which is the same silent
    /// rewrite wearing a friendlier face. So: decode, then re-encode and demand the bytes
    /// match. That tests the exact property callers need rather than a proxy for it.
    static func text(of data: Data) -> String? {
        if containsNUL(data) { return nil }
        let decoded = String(decoding: data, as: UTF8.self)
        guard decoded.utf8.count == data.count, decoded.utf8.elementsEqual(data) else { return nil }
        return decoded
    }

    /// Window the matching line around the first hit so a minified 2 MB line
    /// can't blow the RPC payload.
    static func excerpt(line: String, query: String, options: String.CompareOptions,
                        maxLength: Int) -> String {
        if line.count <= maxLength { return line }
        guard let match = line.range(of: query, options: options) else {
            return String(line.prefix(maxLength)) + "…"
        }
        let matchLen = line.distance(from: match.lowerBound, to: match.upperBound)
        let remain = max(maxLength - matchLen, 0)
        let leftBudget = remain / 2
        let matchStart = line.distance(from: line.startIndex, to: match.lowerBound)
        var windowStart = max(0, matchStart - leftBudget)
        let windowEnd = min(line.count, windowStart + maxLength)
        windowStart = max(0, windowEnd - maxLength)
        let start = line.index(line.startIndex, offsetBy: windowStart)
        let end = line.index(line.startIndex, offsetBy: windowEnd)
        var snippet = String(line[start..<end])
        if windowStart > 0 { snippet = "…" + snippet }
        if windowEnd < line.count { snippet += "…" }
        return snippet
    }
}
