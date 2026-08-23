import Darwin
import Foundation
import OrchardProtocol

public enum RuntimePaths {
    /// `sockaddr_un.sun_path` capacity on Darwin (104). The stored C string must
    /// be strictly shorter so the trailing NUL still fits.
    public static var unixSocketPathLimit: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    public static func applicationSupport(fileManager: FileManager = .default) -> URL {
        if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url.appendingPathComponent("Orchard", isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Orchard", isDirectory: true)
    }

    /// `$TMPDIR/orchard-<uid>/` — used when `data/run/orchard-<pid>.sock` would
    /// exceed `sun_path`, or when the preferred run directory cannot be created.
    /// Data stays in the requested directory; only the socket moves.
    public static func temporarySocketRoot() -> URL {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { value in
            value.isEmpty ? nil : value
        } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp, isDirectory: true)
            .appendingPathComponent("orchard-\(getuid())", isDirectory: true)
    }

    public static func socketName(pid: pid_t = getpid()) -> String {
        "orchard-\(pid).sock"
    }

    public static func prepare(fileManager: FileManager = .default,
                               dataDirectory: URL? = nil) throws -> (data: URL, run: URL) {
        let data = dataDirectory ?? applicationSupport(fileManager: fileManager)
        try? fileManager.createDirectory(at: data, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        let preferredRun = data.appendingPathComponent("run", isDirectory: true)
        let preferredSocket = preferredRun.appendingPathComponent(socketName())
        if preferredSocket.path.utf8.count < unixSocketPathLimit {
            do {
                try fileManager.createDirectory(at: preferredRun, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preferredRun.path)
                return (data, preferredRun)
            } catch {
                return (data, try makeTemporaryRunDirectory(fileManager: fileManager))
            }
        }
        return (data, try makeTemporaryRunDirectory(fileManager: fileManager))
    }

    private static func makeTemporaryRunDirectory(fileManager: FileManager) throws -> URL {
        let fallback = temporarySocketRoot()
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallback.path)
        return fallback
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
