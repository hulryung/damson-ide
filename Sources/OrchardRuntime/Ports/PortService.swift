import Foundation

public typealias PortWorkspaceSource = @Sendable () async -> [PortWorkspaceProbe]

/// Timer-driven listening-port sweep. One `lsof` per tick, parse once, attribute
/// by cwd containment, publish a snapshot. Never wired to PTY output events.
///
/// The loop keeps running while started so it can resume when workspaces appear;
/// when the workspace list is empty the tick skips the probe entirely.
public final class PortService: @unchecked Sendable {
    public static let defaultInterval: TimeInterval = 8
    public static let minimumInterval: TimeInterval = 2
    public static let maximumInterval: TimeInterval = 30

    private let workspaces: PortWorkspaceSource
    private let probe: any PortProbe
    private let cwdLookup: ProcessWorkingDirectoryLookup
    private let lock = NSLock()
    private var interval: TimeInterval
    private var current = PortScanSnapshot.empty
    private var loop: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<PortScanSnapshot>.Continuation] = [:]

    public init(workspaces: @escaping PortWorkspaceSource,
                probe: any PortProbe = LsofPortProbe(),
                cwdLookup: @escaping ProcessWorkingDirectoryLookup = ProcessWorkingDirectory.libproc,
                interval: TimeInterval = PortService.defaultInterval) {
        self.workspaces = workspaces
        self.probe = probe
        self.cwdLookup = cwdLookup
        self.interval = max(0.02, interval)
    }

    public func snapshot() -> PortScanSnapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func setInterval(_ value: TimeInterval) {
        lock.lock(); interval = max(0.02, value); lock.unlock()
    }

    /// Current snapshot immediately, then each completed sweep.
    public func snapshots() -> AsyncStream<PortScanSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuation.yield(current)
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.sweep()
                let seconds = self.currentInterval()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    public func stop() {
        lock.lock()
        let task = loop
        loop = nil
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        task?.cancel()
        for continuation in pending.values { continuation.finish() }
    }

    /// One bounded sweep. Public so tests (and on-demand RPC) can run without the timer.
    @discardableResult
    public func sweep() async -> PortScanSnapshot {
        let probes = await workspaces()
        guard !probes.isEmpty else {
            let empty = PortScanSnapshot(
                platform: "darwin",
                scannedAt: Date().timeIntervalSince1970 * 1000,
                ports: [])
            publish(empty)
            return empty
        }

        let output = await probe.listeningOutput()
        let raw = LsofParser.parse(output)
        var cwdCache: [Int32: String?] = [:]
        var attributed: [WorkspaceListeningPort] = []
        attributed.reserveCapacity(raw.count)

        for listener in raw {
            var enriched = listener
            if let pid = listener.pid {
                if let cached = cwdCache[pid] {
                    enriched.cwd = cached
                } else {
                    let cwd = cwdLookup(pid)
                    cwdCache[pid] = cwd
                    enriched.cwd = cwd
                }
            }
            guard let match = PortAttribution.attribute(cwd: enriched.cwd, to: probes) else {
                continue
            }
            let bind = enriched.host
            let connect = LsofParser.connectHost(forBindHost: bind)
            let id = "\(connect):\(enriched.port):\(enriched.pid.map(String.init) ?? "unknown")"
            attributed.append(WorkspaceListeningPort(
                id: id, bindHost: bind, connectHost: connect, port: enriched.port,
                pid: enriched.pid, processName: enriched.processName,
                worktreeId: match.workspace.id, repoId: match.workspace.repoId,
                displayName: match.workspace.displayName, path: match.workspace.path,
                confidence: match.confidence))
        }

        attributed.sort {
            if $0.port != $1.port { return $0.port < $1.port }
            if $0.worktreeId != $1.worktreeId { return $0.worktreeId < $1.worktreeId }
            return $0.connectHost < $1.connectHost
        }
        if attributed.count > LsofParser.maxPorts {
            attributed = Array(attributed.prefix(LsofParser.maxPorts))
        }

        let next = PortScanSnapshot(
            platform: "darwin",
            scannedAt: Date().timeIntervalSince1970 * 1000,
            ports: attributed)
        publish(next)
        return next
    }

    deinit { stop() }

    private func currentInterval() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return interval
    }

    private func publish(_ snapshot: PortScanSnapshot) {
        lock.lock()
        current = snapshot
        let pending = Array(continuations.values)
        lock.unlock()
        for continuation in pending {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock(); continuations.removeValue(forKey: id); lock.unlock()
    }

    public static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(maximumInterval, max(minimumInterval, value))
    }

    public static func intervalFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        guard let raw = environment["ORCHARD_PORTS_SWEEP_INTERVAL"],
              let value = TimeInterval(raw) else {
            return defaultInterval
        }
        return clamp(value)
    }
}
