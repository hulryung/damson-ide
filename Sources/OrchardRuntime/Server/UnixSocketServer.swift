import Darwin
import Foundation
import OrchardProtocol

public enum UnixSocketServerError: Error, CustomStringConvertible {
    case pathTooLong, bindFailed(Int32), listenFailed(Int32), runtimeAlreadyRunning(pid: Int32)
    public var description: String {
        switch self {
        case .pathTooLong: return "runtime socket path is too long"
        case .bindFailed(let code): return "could not bind runtime socket (errno \(code))"
        case .listenFailed(let code): return "could not listen on runtime socket (errno \(code))"
        case .runtimeAlreadyRunning(let pid): return "an Orchard runtime is already running (pid \(pid))"
        }
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public let metadata: RuntimeMetadata
    private let registry: CommandRegistry
    private let socketFD: Int32
    private let fileManager: FileManager
    private let dataDirectory: URL
    private let queue = DispatchQueue(label: "orchard.runtime.socket", attributes: .concurrent)
    private var source: DispatchSourceRead?

    public init(registry: CommandRegistry, fileManager: FileManager = .default,
                runtimeId: String = "rt_" + UUID().uuidString,
                authToken: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                dataDirectory: URL? = nil, mode: RuntimeMode = .app) throws {
        let resolvedData = dataDirectory ?? RuntimePaths.applicationSupport(fileManager: fileManager)
        if let owner = try? RuntimeDiscovery.load(fileManager: fileManager,
                                                  dataDirectory: resolvedData),
           kill(owner.pid, 0) == 0 || errno == EPERM {
            throw UnixSocketServerError.runtimeAlreadyRunning(pid: owner.pid)
        }
        RuntimeDiscovery.sweepStale(fileManager: fileManager, dataDirectory: resolvedData)
        let paths = try RuntimePaths.prepare(fileManager: fileManager, dataDirectory: resolvedData)
        // `prepare` already relocates `run/` under `$TMPDIR/orchard-<uid>/` when
        // `data/run/orchard-<pid>.sock` would exceed sun_path; this guard is the
        // last resort if even the fallback is too long.
        let socketURL = paths.run.appendingPathComponent(RuntimePaths.socketName())
        guard socketURL.path.utf8.count < RuntimePaths.unixSocketPathLimit else {
            throw UnixSocketServerError.pathTooLong
        }
        try? fileManager.removeItem(at: socketURL)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            if let base = bytes.baseAddress { memset(base, 0, bytes.count) }
            socketURL.path.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketURL.path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard result == 0 else { Darwin.close(fd); throw UnixSocketServerError.bindFailed(errno) }
        chmod(socketURL.path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else { Darwin.close(fd); throw UnixSocketServerError.listenFailed(errno) }
        socketFD = fd; self.registry = registry; self.fileManager = fileManager
        self.dataDirectory = paths.data
        metadata = RuntimeMetadata(runtimeId: runtimeId, pid: getpid(), socketPath: socketURL.path,
                                   authToken: authToken, mode: mode)
        try fileManager.createDirectory(at: paths.data, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder.orchard.encode(metadata)
        let temp = RuntimePaths.metadataURL(fileManager: fileManager, dataDirectory: paths.data).appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        chmod(temp.path, 0o600)
        let destination = RuntimePaths.metadataURL(fileManager: fileManager, dataDirectory: paths.data)
        if fileManager.fileExists(atPath: destination.path) { _ = try fileManager.replaceItemAt(destination, withItemAt: temp) }
        else { try fileManager.moveItem(at: temp, to: destination) }
    }

    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailable() }
        source.setCancelHandler { [socketFD] in Darwin.close(socketFD) }
        self.source = source; source.resume()
    }

    public func stop(fileManager: FileManager? = nil) {
        let fileManager = fileManager ?? self.fileManager
        source?.cancel(); source = nil
        try? fileManager.removeItem(atPath: metadata.socketPath)
        if let current = try? RuntimeDiscovery.load(fileManager: fileManager, dataDirectory: dataDirectory), current.runtimeId == metadata.runtimeId {
            try? fileManager.removeItem(at: RuntimePaths.metadataURL(fileManager: fileManager, dataDirectory: dataDirectory))
        }
    }

    private func acceptAvailable() {
        let fd = Darwin.accept(socketFD, nil, nil)
        guard fd >= 0 else { return }
        queue.async { [weak self] in self?.serve(fd); Darwin.close(fd) }
    }

    private func serve(_ fd: Int32) {
        var data = Data(); var byte: UInt8 = 0
        while data.count < 4 * 1024 * 1024 {
            let count = Darwin.read(fd, &byte, 1)
            if count <= 0 || byte == 10 { break }
            data.append(byte)
        }
        guard let request = try? JSONDecoder.orchard.decode(RPCRequest.self, from: data) else {
            write(.failure(id: "unknown", error: RPCError(code: "invalid_request", message: "request is not valid JSON")), to: fd); return
        }
        guard request.authToken == metadata.authToken else {
            write(.failure(id: request.id, error: RPCError(code: "unauthorized", message: "invalid runtime auth token")), to: fd); return
        }
        let semaphore = DispatchSemaphore(value: 0)
        var response: RPCResponse?
        Task { response = await registry.route(request); semaphore.signal() }
        while semaphore.wait(timeout: .now() + 15) == .timedOut {
            _ = Darwin.write(fd, Array("{\"_keepalive\":true}\n".utf8), 20)
        }
        let routed = response ?? .failure(id: request.id, error: RPCError(code: "internal_error", message: "handler returned no response"))
        write(RPCResponse(id: routed.id, ok: routed.ok, result: routed.result, error: routed.error,
                          meta: RPCMeta(runtimeId: metadata.runtimeId)), to: fd)
    }

    private func write(_ response: RPCResponse, to fd: Int32) {
        guard var data = try? JSONEncoder.orchard.encode(response) else { return }
        data.append(10); data.withUnsafeBytes { if let base = $0.baseAddress { _ = Darwin.write(fd, base, data.count) } }
    }
}
