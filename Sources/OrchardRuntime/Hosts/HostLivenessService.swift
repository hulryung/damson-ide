import Foundation
import OrchardTerminals

/// The remote surfaces that keep the host-liveness producer awake: a remote repo
/// or a remote pane. An empty surface means the loop is fully idle — no `ssh` at all.
public struct HostLivenessSurface: Equatable, Sendable {
    /// Registered host names that currently have a remote repo or remote pane.
    public var hostNames: Set<String>

    public init(hostNames: Set<String> = []) {
        self.hostNames = hostNames
    }

    public var isActive: Bool { !hostNames.isEmpty }

    /// Unique `ssh:<name>` suffixes from remote repos and remote panes. Unparseable
    /// or local ids are ignored — they are not a reason to start probing.
    public static func collect(repos: [RepoRecord],
                               terminals: [TerminalSummary]) -> HostLivenessSurface {
        var names = Set<String>()
        for repo in repos {
            if let name = sshHostName(repo.hostId) { names.insert(name) }
        }
        for terminal in terminals {
            if let name = sshHostName(terminal.executionHostId) { names.insert(name) }
        }
        return HostLivenessSurface(hostNames: names)
    }

    private static func sshHostName(_ raw: String?) -> String? {
        guard let raw, let id = ExecutionHostId(rawValue: raw), id.kind == .ssh else {
            return nil
        }
        return id.name
    }
}

/// Last published per-host reachability. In-memory only: a failed probe never
/// writes the host record, and a status change never mutates a workspace,
/// worktree, terminal, or worker (docs/design/remote-hosts.md §1 rule 2, §3).
public struct HostLivenessSnapshot: Equatable, Sendable {
    /// Last probe per registered host name.
    public var hosts: [String: HostProbeResult]
    /// Unix ms of the last completed sweep, whether or not it probed.
    public var sweptAt: Double
    /// True when the last sweep skipped probing because no remote surface existed.
    public var idle: Bool

    public static let empty = HostLivenessSnapshot(hosts: [:], sweptAt: 0, idle: true)

    public init(hosts: [String: HostProbeResult] = [:], sweptAt: Double = 0, idle: Bool = true) {
        self.hosts = hosts
        self.sweptAt = sweptAt
        self.idle = idle
    }

    public func status(for name: String) -> HostProbeResult? { hosts[name] }

    public func status(forHostId hostId: String?) -> HostProbeResult? {
        guard let hostId, let id = ExecutionHostId(rawValue: hostId), id.kind == .ssh else {
            return nil
        }
        return hosts[id.name]
    }
}

/// User-facing reachability copy. Age labels and chip help live here so no surface
/// can invent a fourth verdict or word an unreachable host as remote work stopping.
public enum HostLivenessPresentation {
    public static func ageLabel(since date: Date, now: Date = Date()) -> String {
        ageLabel(seconds: now.timeIntervalSince(date))
    }

    public static func ageLabel(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Compact status + age for a chip (`reachable · 12s ago`).
    public static func chipStatusLine(_ result: HostProbeResult, now: Date = Date()) -> String {
        "\(result.status.rawValue) · \(ageLabel(since: result.lastCheckedAt, now: now))"
    }

    /// Tooltip copy. Unreachable always carries the rule-2 reminder; nothing here
    /// says remote work stopped, died, or exited.
    public static func chipHelp(name: String, result: HostProbeResult,
                                now: Date = Date()) -> String {
        let age = ageLabel(since: result.lastCheckedAt, now: now)
        switch result.status {
        case .reachable:
            return "\(name) is reachable (checked \(age))."
        case .authRequired:
            return "\(name) answered but needs credentials (checked \(age))."
        case .unreachable:
            let note = result.note ?? (
                "Unreachable is loss of contact, not evidence that anything on \(name) stopped.")
            return "\(name) is unreachable (checked \(age)). \(note)"
        }
    }
}

/// Periodic bounded host-reachability producer.
///
/// Reuses `HostProbe` (same argv, same classification, one probe per host per sweep).
/// The loop stays fully idle — no `ssh` — unless at least one remote repo or remote
/// pane exists. Reachability is published in memory only; callers must not fold a
/// status change into workspace, worktree, terminal, or worker state.
public final class HostLivenessService: @unchecked Sendable {
    public static let defaultInterval: TimeInterval = 30
    public static let minimumInterval: TimeInterval = 5
    public static let maximumInterval: TimeInterval = 300
    public static let environmentKey = "ORCHARD_HOST_LIVENESS_INTERVAL"

    public typealias HostSource = @Sendable () async -> [HostRecord]
    public typealias SurfaceSource = @Sendable () async -> HostLivenessSurface

    private let hosts: HostSource
    private let surface: SurfaceSource
    private let runner: HostCommandRunner
    private let probeTimeout: TimeInterval
    private let lock = NSLock()
    private var interval: TimeInterval
    private var current = HostLivenessSnapshot.empty
    private var loop: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<HostLivenessSnapshot>.Continuation] = [:]

    public init(hosts: @escaping HostSource,
                surface: @escaping SurfaceSource,
                runner: HostCommandRunner = ProcessHostCommandRunner(),
                probeTimeout: TimeInterval = HostProbe.defaultTimeout,
                interval: TimeInterval = HostLivenessService.defaultInterval) {
        self.hosts = hosts
        self.surface = surface
        self.runner = runner
        self.probeTimeout = probeTimeout
        self.interval = max(0.02, interval)
    }

    public func snapshot() -> HostLivenessSnapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func status(for name: String) -> HostProbeResult? {
        snapshot().status(for: name)
    }

    public func status(forHostId hostId: String?) -> HostProbeResult? {
        snapshot().status(forHostId: hostId)
    }

    public func setInterval(_ value: TimeInterval) {
        lock.lock(); interval = max(0.02, value); lock.unlock()
    }

    /// Current snapshot immediately, then each completed sweep or published probe.
    public func snapshots() -> AsyncStream<HostLivenessSnapshot> {
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

    /// One bounded sweep. Public so tests (and on-demand RPC / Open Remote) can run
    /// without the timer. Idle when no remote repo or remote pane exists: the runner
    /// is not called.
    @discardableResult
    public func sweep() async -> HostLivenessSnapshot {
        let surface = await self.surface()
        guard surface.isActive else {
            return publishIdleKeepingHosts()
        }

        let records = await hosts()
        var next = snapshot().hosts
        var seen = Set<String>()
        // Registry order, one probe per host, and only hosts that currently have a
        // remote surface. An unused registered host is not a reason to start ssh.
        for record in records where surface.hostNames.contains(record.name) {
            if seen.contains(record.name) { continue }
            seen.insert(record.name)
            next[record.name] = await HostProbe.check(
                host: record, runner: runner, timeout: probeTimeout)
        }
        let snapshot = HostLivenessSnapshot(
            hosts: next,
            sweptAt: Date().timeIntervalSince1970 * 1000,
            idle: false)
        publish(snapshot)
        return snapshot
    }

    /// Record a user-initiated probe (`host check`, Open Remote on-open) into the
    /// same snapshot the periodic loop publishes. Does not start the loop and does
    /// not touch any workspace, worktree, terminal, or worker state.
    public func publish(_ result: HostProbeResult) {
        lock.lock()
        var hosts = current.hosts
        hosts[result.name] = result
        let snapshot = HostLivenessSnapshot(
            hosts: hosts,
            sweptAt: Date().timeIntervalSince1970 * 1000,
            idle: current.idle)
        current = snapshot
        let pending = Array(continuations.values)
        lock.unlock()
        for continuation in pending { continuation.yield(snapshot) }
    }

    deinit { stop() }

    private func publishIdleKeepingHosts() -> HostLivenessSnapshot {
        let hosts = snapshot().hosts
        let idle = HostLivenessSnapshot(
            hosts: hosts,
            sweptAt: Date().timeIntervalSince1970 * 1000,
            idle: true)
        publish(idle)
        return idle
    }

    private func publish(_ snapshot: HostLivenessSnapshot) {
        lock.lock()
        current = snapshot
        let pending = Array(continuations.values)
        lock.unlock()
        for continuation in pending { continuation.yield(snapshot) }
    }

    private func currentInterval() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return interval
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
        guard let raw = environment[environmentKey],
              let value = TimeInterval(raw) else {
            return defaultInterval
        }
        return clamp(value)
    }
}
