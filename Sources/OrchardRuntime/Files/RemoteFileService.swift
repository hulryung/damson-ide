import Foundation

/// FileService-shaped reads against a workspace that lives on a remote host.
///
/// Every method here is a bounded `ssh` round trip. There is no local-path
/// fallback: a remote root handed to `FileManager` would either fail or find a
/// same-named directory on this machine. Bytes that cannot round-trip as UTF-8
/// are classified by `FileService.preview(data:)` — the same T75 rule as local.
public struct RemoteFileService: Sendable {
    let transport: RemoteFileTransport
    private let files: FileService

    public var runner: SSHRunner { transport.runner }
    public var root: String { transport.root }
    public var hostName: String { transport.hostName }

    public init(runner: SSHRunner, root: String, files: FileService = FileService()) throws {
        self.transport = try RemoteFileTransport(runner: runner, root: root)
        self.files = files
    }

    public func readDir(relativePath: String = "", showDotfiles: Bool = false) async throws -> [FileDirEntry] {
        try await transport.readDir(relativePath: relativePath, showDotfiles: showDotfiles)
    }

    public func preview(relativePath: String, maxBytes: Int? = nil) async throws -> FilePreview {
        let rel = try RemoteFilePath.requireSafe(relativePath)
        if rel.isEmpty { throw FileServiceError.invalidArgument("missing file path") }
        let ext = (rel as NSString).pathExtension.lowercased()
        let isImage = FileService.imageMIME[ext] != nil
        let budget = maxBytes ?? (isImage ? FileService.defaultBinaryBudget : FileService.defaultTextBudget)
        let read = try await transport.readData(relativePath: rel, maxBytes: budget)
        return try files.preview(data: read.data, relativePath: rel, maxBytes: budget)
    }

    public func readData(relativePath: String, maxBytes: Int? = nil) async throws -> Data {
        let rel = try RemoteFilePath.requireSafe(relativePath)
        if rel.isEmpty { throw FileServiceError.invalidArgument("missing file path") }
        let budget = maxBytes ?? FileService.defaultBinaryBudget
        return try await transport.readData(relativePath: rel, maxBytes: budget).data
    }

    public func stat(relativePath: String = "") async throws -> FileStatInfo {
        try await transport.stat(relativePath: relativePath)
    }

    public func list(query: String? = nil, showDotfiles: Bool = false,
                     limit: Int = FileService.defaultListLimit) async throws -> FileListResult {
        let cap = min(max(limit, 1), FileService.maxListLimit)
        return try await transport.list(query: query, showDotfiles: showDotfiles, limit: cap)
    }

    public func contentSearch(query: String,
                              options: FileContentSearchOptions = FileContentSearchOptions())
        async throws -> FileContentSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileServiceError.invalidArgument("search requires a query")
        }
        if trimmed.utf8.count > FileService.maxQueryBytes {
            throw FileServiceError.invalidArgument("query exceeds 8 KB")
        }
        var clamped = options
        clamped.limit = min(max(options.limit, 1), FileService.maxContentSearchLimit)
        clamped.perFileLimit = min(max(options.perFileLimit, 1), FileService.maxPerFileMatchLimit)
        return try await transport.contentSearch(query: trimmed, options: clamped)
    }
}
