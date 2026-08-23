import Darwin
import Foundation
import OrchardProtocol

public enum RuntimePaths {
    public static func applicationSupport(fileManager: FileManager = .default) -> URL {
        if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url.appendingPathComponent("Orchard", isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Orchard", isDirectory: true)
    }

    public static func prepare(fileManager: FileManager = .default,
                               dataDirectory: URL? = nil) throws -> (data: URL, run: URL) {
        let data = dataDirectory ?? applicationSupport(fileManager: fileManager)
        try? fileManager.createDirectory(at: data, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        do {
            let run = data.appendingPathComponent("run", isDirectory: true)
            try fileManager.createDirectory(at: run, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: run.path)
            return (data, run)
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Orchard-\(getuid())", isDirectory: true)
            try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallback.path)
            return (data, fallback)
        }
    }

    public static func metadataURL(fileManager: FileManager = .default,
                                   dataDirectory: URL? = nil) -> URL {
        (dataDirectory ?? applicationSupport(fileManager: fileManager))
            .appendingPathComponent("orchard-runtime.json")
    }
}

public enum RuntimeDiscovery {
    public static func load(fileManager: FileManager = .default,
                            dataDirectory: URL? = nil) throws -> RuntimeMetadata {
        try JSONDecoder.orchard.decode(RuntimeMetadata.self,
                                       from: Data(contentsOf: RuntimePaths.metadataURL(
                                        fileManager: fileManager, dataDirectory: dataDirectory)))
    }

    /// Removes metadata/socket only when the recorded process is gone. Never unlinks a live runtime.
    public static func sweepStale(fileManager: FileManager = .default,
                                  dataDirectory: URL? = nil) {
        guard let metadata = try? load(fileManager: fileManager,
                                       dataDirectory: dataDirectory) else { return }
        if kill(metadata.pid, 0) == 0 || errno == EPERM { return }
        try? fileManager.removeItem(atPath: metadata.socketPath)
        try? fileManager.removeItem(at: RuntimePaths.metadataURL(
            fileManager: fileManager, dataDirectory: dataDirectory))
    }
}

extension JSONEncoder {
    static var orchard: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]; return value }
}
extension JSONDecoder {
    static var orchard: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
