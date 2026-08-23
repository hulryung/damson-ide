import Foundation

/// One child of a directory listing. Listings are passive: a symlink is never
/// followed here, so `isDirectory` is false for a link even when its target is
/// a directory. Expand/stat resolve the target and apply the same confinement.
public struct FileDirEntry: Codable, Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool

    public init(name: String, isDirectory: Bool, isSymlink: Bool) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

/// Byte-budgeted preview of one file. Images travel as base64 with a MIME type;
/// other binaries return empty `content` so a huge blob never crosses the wire.
public struct FilePreview: Codable, Equatable, Sendable {
    public var content: String
    public var isBinary: Bool
    public var isImage: Bool
    public var mimeType: String?
    public var byteLength: Int
    public var truncated: Bool

    public init(content: String, isBinary: Bool, isImage: Bool, mimeType: String?,
                byteLength: Int, truncated: Bool = false) {
        self.content = content
        self.isBinary = isBinary
        self.isImage = isImage
        self.mimeType = mimeType
        self.byteLength = byteLength
        self.truncated = truncated
    }
}

public struct FileStatInfo: Codable, Equatable, Sendable {
    public var size: Int64
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var mtime: Double

    public init(size: Int64, isDirectory: Bool, isSymlink: Bool, mtime: Double) {
        self.size = size
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.mtime = mtime
    }
}

public struct FileListResult: Codable, Equatable, Sendable {
    public var files: [String]
    public var totalCount: Int
    public var truncated: Bool

    public init(files: [String], totalCount: Int, truncated: Bool) {
        self.files = files
        self.totalCount = totalCount
        self.truncated = truncated
    }
}

public struct FileSearchHit: Codable, Equatable, Sendable {
    public var relativePath: String
    public var basename: String

    public init(relativePath: String, basename: String) {
        self.relativePath = relativePath
        self.basename = basename
    }
}

public struct FileSearchResult: Codable, Equatable, Sendable {
    public var files: [FileSearchHit]
    public var totalCount: Int
    public var truncated: Bool

    public init(files: [FileSearchHit], totalCount: Int, truncated: Bool) {
        self.files = files
        self.totalCount = totalCount
        self.truncated = truncated
    }
}

/// One full-text match. `path` is worktree-relative; `line` is 1-indexed.
public struct FileContentHit: Codable, Equatable, Sendable {
    public var path: String
    public var line: Int
    public var excerpt: String

    public init(path: String, line: Int, excerpt: String) {
        self.path = path
        self.line = line
        self.excerpt = excerpt
    }
}

public struct FileContentSearchResult: Codable, Equatable, Sendable {
    public var matches: [FileContentHit]
    public var totalCount: Int
    public var truncated: Bool

    public init(matches: [FileContentHit], totalCount: Int, truncated: Bool) {
        self.matches = matches
        self.totalCount = totalCount
        self.truncated = truncated
    }
}

/// Bounds and glob filters for `FileService.contentSearch`.
public struct FileContentSearchOptions: Equatable, Sendable {
    public var include: [String]
    public var exclude: [String]
    public var caseSensitive: Bool
    public var showDotfiles: Bool
    public var limit: Int
    public var perFileLimit: Int
    public var fileByteBudget: Int
    public var totalByteBudget: Int
    public var maxExcerptLength: Int

    public init(include: [String] = [],
                exclude: [String] = [],
                caseSensitive: Bool = false,
                showDotfiles: Bool = false,
                limit: Int = FileService.defaultContentSearchLimit,
                perFileLimit: Int = FileService.defaultPerFileMatchLimit,
                fileByteBudget: Int = FileService.contentSearchFileByteBudget,
                totalByteBudget: Int = FileService.contentSearchTotalByteBudget,
                maxExcerptLength: Int = FileService.maxExcerptLength) {
        self.include = include
        self.exclude = exclude
        self.caseSensitive = caseSensitive
        self.showDotfiles = showDotfiles
        self.limit = limit
        self.perFileLimit = perFileLimit
        self.fileByteBudget = fileByteBudget
        self.totalByteBudget = totalByteBudget
        self.maxExcerptLength = maxExcerptLength
    }
}

public struct FileWatchChange: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case created
        case deleted
        case renamed
    }

    public var kind: Kind
    public var relativePath: String
    /// Set for `.renamed`: the path before the rename.
    public var previousRelativePath: String?

    public init(kind: Kind, relativePath: String, previousRelativePath: String? = nil) {
        self.kind = kind
        self.relativePath = relativePath
        self.previousRelativePath = previousRelativePath
    }
}

public struct FileWatchBatch: Equatable, Sendable {
    public var changes: [FileWatchChange]
    /// The watched root itself vanished; the explorer should stop and surface an error.
    public var rootDeleted: Bool

    public init(changes: [FileWatchChange] = [], rootDeleted: Bool = false) {
        self.changes = changes
        self.rootDeleted = rootDeleted
    }
}

/// Request posted when an agent asks the app to focus a file (`file open` /
/// `file open-changed`). The explorer (or any other in-process client)
/// subscribes; the CLI itself never waits on a UI.
public struct FileOpenRequest: Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case edit, diff
    }

    public var worktreeId: String
    public var worktreePath: String
    public var relativePath: String
    public var mode: Mode

    public init(worktreeId: String, worktreePath: String, relativePath: String, mode: Mode) {
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.relativePath = relativePath
        self.mode = mode
    }
}

public struct FileOpenResult: Codable, Equatable, Sendable {
    public var worktree: String
    public var relativePath: String
    public var kind: String
    public var opened: Bool
    public var reason: String?

    public init(worktree: String, relativePath: String, kind: String, opened: Bool,
                reason: String? = nil) {
        self.worktree = worktree
        self.relativePath = relativePath
        self.kind = kind
        self.opened = opened
        self.reason = reason
    }
}

public struct FileDiffResult: Codable, Equatable, Sendable {
    public var worktree: String
    public var path: String
    public var diff: String
    public var baseRef: String

    public init(worktree: String, path: String, diff: String, baseRef: String) {
        self.worktree = worktree
        self.path = path
        self.diff = diff
        self.baseRef = baseRef
    }
}

public struct FileOpenChangedRecord: Codable, Equatable, Sendable {
    public var path: String
    public var mode: String
    public var opened: Bool
    public var skipped: Bool
    public var reason: String?

    public init(path: String, mode: String, opened: Bool, skipped: Bool, reason: String? = nil) {
        self.path = path
        self.mode = mode
        self.opened = opened
        self.skipped = skipped
        self.reason = reason
    }
}

public struct FileOpenChangedResult: Codable, Equatable, Sendable {
    public var worktree: String
    public var mode: String
    public var opened: [FileOpenChangedRecord]
    public var skipped: [FileOpenChangedRecord]
    public var totalChanged: Int

    public init(worktree: String, mode: String, opened: [FileOpenChangedRecord],
                skipped: [FileOpenChangedRecord], totalChanged: Int) {
        self.worktree = worktree
        self.mode = mode
        self.opened = opened
        self.skipped = skipped
        self.totalChanged = totalChanged
    }
}

public struct FileServiceError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    public static func invalidArgument(_ message: String) -> FileServiceError {
        FileServiceError("invalid_argument", message)
    }

    public static func notFound(_ path: String) -> FileServiceError {
        FileServiceError("not_found", "no such file: \(path)")
    }

    public static func pathEscape(_ message: String) -> FileServiceError {
        FileServiceError("path_escape", message)
    }

    public static let fileTooLarge = FileServiceError("file_too_large", "file exceeds preview budget")
    public static let notADirectory = FileServiceError("not_a_directory", "path is not a directory")
    public static let notAFile = FileServiceError("not_a_file", "path is not a file")
}

/// In-process fan-out for `file open` / `file open-changed`. The app explorer
/// (and tests) subscribe; posting never blocks on a listener.
public final class FileOpenCenter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<FileOpenRequest>.Continuation] = [:]

    public init() {}

    /// Number of live subscribers (test/diagnostic surface).
    public var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }

    public func events() -> AsyncStream<FileOpenRequest> {
        // Register immediately so a subscriber that has called `events()`
        // cannot miss a `post` that races the first `for await`.
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: FileOpenRequest.self)
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    public func post(_ request: FileOpenRequest) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(request)
        }
    }
}
