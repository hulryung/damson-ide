import Foundation

/// Worktree-confined file reads. Every path is resolved against a caller-supplied
/// root; `..`, absolute paths, and symlink escapes are rejected before any IO
/// beyond the confinement check itself.
///
/// Listings are lazy (one directory at a time). Recursive name listing and
/// filename search are bounded so a huge tree can't stall the RPC. Full-text
/// search is out of scope (wave 3).
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

    private static let imageMIME: [String: String] = [
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
        if data.count > budget { throw FileServiceError.fileTooLarge }

        if let mime {
            return FilePreview(content: data.base64EncodedString(), isBinary: true, isImage: true,
                               mimeType: mime, byteLength: data.count)
        }
        if Self.containsNUL(data) {
            return FilePreview(content: "", isBinary: true, isImage: false, mimeType: nil,
                               byteLength: data.count)
        }
        return FilePreview(content: String(decoding: data, as: UTF8.self),
                           isBinary: false, isImage: false, mimeType: "text/plain",
                           byteLength: data.count)
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

    private static func containsNUL(_ data: Data) -> Bool {
        let window = data.prefix(binarySniffBytes)
        return window.contains(0)
    }
}
