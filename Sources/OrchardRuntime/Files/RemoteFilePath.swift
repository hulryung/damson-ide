import Foundation

/// String-only path confinement for a workspace whose files live on another machine.
///
/// `FileService.resolve` uses `URL` + `FileManager`, which would either fail or —
/// the original hazard — find a same-named directory *here* and answer with the
/// wrong repo. Remote paths stay strings and are confined before they ever become
/// an ssh argument.
enum RemoteFilePath {
    /// Worktree-relative path, or empty for the root. Rejects NUL, `.`, `..`, empty
    /// segments, and absolute/home-relative spellings — the same set `FileService`
    /// refuses, so a path that is unsafe locally is unsafe over ssh too.
    static func requireSafe(_ relativePath: String) throws -> String {
        let raw = relativePath.replacingOccurrences(of: "\\", with: "/")
        if raw.contains("\0") {
            throw FileServiceError.pathEscape("path contains a NUL byte")
        }
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            throw FileServiceError.pathEscape("absolute paths are not allowed")
        }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "" }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." {
                throw FileServiceError.pathEscape(
                    "path '\(relativePath)' is not a safe worktree-relative path")
            }
        }
        return trimmed
    }

    /// Relativize an absolute path that already lives inside `root`; otherwise treat
    /// it as a relative path (which `requireSafe` still confines). Normalization of
    /// `..` is allowed only for the absolute form, matching `FileService.relativePath`.
    static func relativePath(from raw: String, root: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("/") {
            let rootStd = normalize(root)
            let candidate = normalize(trimmed)
            try assertInside(candidate, root: rootStd, original: trimmed)
            if candidate == rootStd { return "" }
            let prefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"
            return String(candidate.dropFirst(prefix.count))
        }
        return try requireSafe(trimmed)
    }

    static func requireAbsoluteRoot(_ root: String) throws -> String {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileServiceError.invalidArgument("empty worktree root")
        }
        guard trimmed.hasPrefix("/") else {
            throw FileServiceError.invalidArgument("remote worktree root must be absolute")
        }
        return normalize(trimmed)
    }

    static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        let joined = parts.joined(separator: "/")
        if isAbsolute { return joined.isEmpty ? "/" : "/" + joined }
        return joined
    }

    static func assertInside(_ path: String, root: String, original: String) throws {
        if path == root { return }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) { return }
        throw FileServiceError.pathEscape(
            "path '\(original)' resolves outside the worktree root")
    }
}
