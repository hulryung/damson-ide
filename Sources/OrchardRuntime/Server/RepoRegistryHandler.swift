import Foundation
import OrchardProtocol

public struct RepositoryRecord: Codable, Equatable, Sendable {
    public let id: String; public let path: String; public let displayName: String; public let baseRef: String?
    public init(id: String = "repo_" + UUID().uuidString, path: String, displayName: String, baseRef: String? = nil) {
        self.id = id; self.path = path; self.displayName = displayName; self.baseRef = baseRef
    }
}

public actor RepoRegistryHandler: CommandHandler {
    public nonisolated let verbs = ["repo-list", "repo-add", "repo-show"]
    private let fileURL: URL
    private var repositories: [RepositoryRecord]

    private struct Store: Codable { var repositories: [RepositoryRecord] = [] }

    public init(fileURL: URL = RuntimePaths.applicationSupport().appendingPathComponent("orchard-data.json")) {
        self.fileURL = fileURL
        repositories = (try? JSONDecoder().decode(Store.self, from: Data(contentsOf: fileURL)))?.repositories ?? []
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        let params = request.params?.objectValue ?? [:]
        switch request.method {
        case "repo-list": return .success(id: request.id, result: encode(repositories))
        case "repo-add":
            guard let rawPath = params["path"]?.stringValue else { return missing(request, "path") }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            if let existing = repositories.first(where: { $0.path == path }) { return .success(id: request.id, result: encode(existing)) }
            let record = RepositoryRecord(path: path, displayName: params["display-name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent,
                                          baseRef: params["base-ref"]?.stringValue)
            repositories.append(record)
            do { try persist(); return .success(id: request.id, result: encode(record)) }
            catch { return .failure(id: request.id, error: RPCError(code: "store_write_failed", message: error.localizedDescription)) }
        case "repo-show":
            let selector = params["repo"]?.stringValue ?? params["id"]?.stringValue ?? params["path"]?.stringValue
            guard let selector else { return missing(request, "repo") }
            guard let record = repositories.first(where: { $0.id == selector.replacingOccurrences(of: "id:", with: "") || $0.path == selector.replacingOccurrences(of: "path:", with: "") }) else {
                return .failure(id: request.id, error: RPCError(code: "repo_not_found", message: "repository not found"))
            }
            return .success(id: request.id, result: encode(record))
        default: return .failure(id: request.id, error: RPCError(code: "unknown_command", message: request.method))
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder.orchard.encode(Store(repositories: repositories)).write(to: fileURL, options: .atomic)
        chmod(fileURL.path, 0o600)
    }
    private func encode<T: Encodable>(_ value: T) -> JSONValue {
        let data = try! JSONEncoder().encode(value); return try! JSONDecoder().decode(JSONValue.self, from: data)
    }
    private func missing(_ request: RPCRequest, _ name: String) -> RPCResponse {
        .failure(id: request.id, error: RPCError(code: "invalid_arguments", message: "missing --\(name)"))
    }
}
