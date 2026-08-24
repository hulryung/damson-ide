import XCTest
@testable import OrchardRuntime

/// A `HostCommandRunner` that answers from a script instead of spawning `ssh`.
/// Invocation count is the idle/gating pin: a sweep with no remote surface must
/// not call this at all.
private final class ScriptedProber: HostCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HostCommandResult]
    private var index = 0
    private(set) var invocations: [[String]] = []
    var fallback: HostCommandResult

    init(results: [HostCommandResult] = [],
         fallback: HostCommandResult = HostCommandResult(exitCode: 0)) {
        self.results = results
        self.fallback = fallback
    }

    func enqueue(_ result: HostCommandResult) {
        lock.lock(); results.append(result); lock.unlock()
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return invocations.count
    }

    func run(_ argv: [String], timeout: TimeInterval) async -> HostCommandResult {
        answer(argv)
    }

    private func answer(_ argv: [String]) -> HostCommandResult {
        lock.lock(); defer { lock.unlock() }
        invocations.append(argv)
        if index < results.count {
            let result = results[index]
            index += 1
            return result
        }
        return fallback
    }
}

private final class SurfaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HostLivenessSurface
    init(_ value: HostLivenessSurface = HostLivenessSurface()) { self.value = value }
    var current: HostLivenessSurface {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// T45 host-liveness producer: sweep gating, publication, status transitions, and
/// the rule that reachability never mutates workspace / worktree / host-record state.
final class HostLivenessTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-liveness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() -> OrchardDataStore {
        OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
    }

    private func makeService(store: OrchardDataStore,
                             runner: ScriptedProber,
                             surface: @escaping @Sendable () async -> HostLivenessSurface,
                             interval: TimeInterval = 60) -> HostLivenessService {
        let registry = HostRegistry(store: store, sshConfig: { [] })
        return HostLivenessService(
            hosts: { registry.list() },
            surface: surface,
            runner: runner,
            probeTimeout: 1,
            interval: interval)
    }

    // MARK: - Sweep gating

    func testSweepIsIdleWhenNoRemoteSurfaceExists() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: nil, port: nil)
        let runner = ScriptedProber()
        let service = makeService(store: store, runner: runner, surface: { HostLivenessSurface() })

        let snapshot = await service.sweep()
        XCTAssertTrue(snapshot.idle)
        XCTAssertEqual(runner.callCount, 0)
        XCTAssertNil(service.status(for: "build"))
    }

    func testLoopStaysIdleWhenNoRemoteSurfaceExists() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: nil, port: nil)
        let runner = ScriptedProber()
        let box = SurfaceBox()
        let service = makeService(store: store, runner: runner,
                                  surface: { box.current }, interval: 0.05)
        let stream = service.snapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        service.start()
        let published = await withTimeout(seconds: 2) { () -> Bool in
            await iterator.next() != nil
        }
        service.stop()
        XCTAssertEqual(published, true, "expected the loop to publish at least one idle sweep")
        XCTAssertEqual(runner.callCount, 0)
        XCTAssertTrue(service.snapshot().idle)
    }

    func testSweepProbesWhenARemoteRepoExists() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: "ci", port: nil,
                            source: .sshConfig)
        try store.modify {
            $0.repos.append(RepoRecord(path: "/home/ci/app", displayName: "app",
                                       hostId: "ssh:build"))
        }
        let runner = ScriptedProber(results: [HostCommandResult(exitCode: 0)])
        let surface = HostLivenessSurface.collect(repos: store.load().repos, terminals: [])
        XCTAssertEqual(surface.hostNames, ["build"])
        let service = makeService(store: store, runner: runner, surface: { surface })

        let snapshot = await service.sweep()
        XCTAssertFalse(snapshot.idle)
        XCTAssertEqual(runner.callCount, 1)
        XCTAssertEqual(service.status(for: "build")?.status, .reachable)
        XCTAssertEqual(Array(runner.invocations.first?.suffix(2) ?? []), ["build", "true"])
    }

    func testSweepProbesWhenARemotePaneExistsAndNotForUnusedHosts() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: nil, port: nil)
        _ = try registry.add(name: "laptop", hostname: "10.0.0.7", user: nil, port: nil)
        let runner = ScriptedProber()
        // A remote pane on `build` is enough to wake the producer; `laptop` has no
        // remote surface and must not be probed.
        let service = makeService(store: store, runner: runner,
                                  surface: { HostLivenessSurface(hostNames: ["build"]) })

        _ = await service.sweep()
        XCTAssertEqual(runner.callCount, 1)
        XCTAssertNotNil(service.status(for: "build"))
        XCTAssertNil(service.status(for: "laptop"))
    }

    func testSweepProbesEachHostOnceEvenIfSeveralSurfacesShareIt() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: nil, port: nil)
        let runner = ScriptedProber()
        // Two remote repos + a pane, all on `build`: still one probe.
        let service = makeService(store: store, runner: runner,
                                  surface: { HostLivenessSurface(hostNames: ["build"]) })
        _ = await service.sweep()
        XCTAssertEqual(runner.callCount, 1)
    }

    func testCollectIgnoresLocalRepos() {
        let remote = RepoRecord(path: "/home/ci/app", displayName: "app", hostId: "ssh:build")
        let local = RepoRecord(path: "/tmp/app", displayName: "local", hostId: "local")
        let surface = HostLivenessSurface.collect(repos: [remote, local], terminals: [])
        XCTAssertEqual(surface.hostNames, ["build"])
        XCTAssertTrue(surface.isActive)
        XCTAssertFalse(HostLivenessSurface().isActive)
    }

    // MARK: - Publication

    func testSweepPublishesStatusLastCheckedAndLatency() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: nil, port: nil)
        let runner = ScriptedProber(results: [HostCommandResult(exitCode: 0)])
        let service = makeService(store: store, runner: runner,
                                  surface: { HostLivenessSurface(hostNames: ["build"]) })
        let before = Date()
        let snapshot = await service.sweep()
        let live = try XCTUnwrap(snapshot.status(for: "build"))
        XCTAssertEqual(live.status, .reachable)
        XCTAssertEqual(live.executionHostId, "ssh:build")
        XCTAssertGreaterThanOrEqual(live.lastCheckedAt, before)
        XCTAssertLessThanOrEqual(live.lastCheckedAt, Date().addingTimeInterval(1))
        XCTAssertNotNil(live.latencyMs)
        XCTAssertGreaterThanOrEqual(live.latencyMs ?? -1, 0)
        XCTAssertNil(live.note)
        XCTAssertFalse(snapshot.idle)
    }

    func testPublishFromHostCheckIsVisibleOnTheSnapshot() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: nil, port: nil)
        let runner = ScriptedProber(results: [HostCommandResult(exitCode: 0)])
        let service = makeService(store: store, runner: runner, surface: { HostLivenessSurface() })
        let record = try registry.require(name: "build")
        let result = await HostProbe.check(host: record, runner: runner, timeout: 1)
        service.publish(result)
        XCTAssertEqual(service.status(for: "build")?.status, .reachable)
        // Publishing a one-shot does not start probing the idle loop.
        XCTAssertTrue(service.snapshot().idle)
    }

    func testSnapshotsStreamYieldsAfterASweep() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: nil, port: nil)
        let runner = ScriptedProber()
        let service = makeService(store: store, runner: runner,
                                  surface: { HostLivenessSurface(hostNames: ["build"]) })
        let stream = service.snapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let sweep = Task { await service.sweep() }
        let published = await iterator.next()
        _ = await sweep.value
        XCTAssertEqual(published?.status(for: "build")?.status, .reachable)
        service.stop()
    }

    func testIntervalFromEnvironmentClamps() {
        XCTAssertEqual(HostLivenessService.intervalFromEnvironment([:]),
                       HostLivenessService.defaultInterval)
        XCTAssertEqual(HostLivenessService.intervalFromEnvironment(
            [HostLivenessService.environmentKey: "45"]), 45)
        XCTAssertEqual(HostLivenessService.intervalFromEnvironment(
            [HostLivenessService.environmentKey: "1"]),
                       HostLivenessService.minimumInterval)
        XCTAssertEqual(HostLivenessService.intervalFromEnvironment(
            [HostLivenessService.environmentKey: "999"]),
                       HostLivenessService.maximumInterval)
    }

    // MARK: - Status transitions

    func testStatusTransitionsReachableToAuthRequiredToUnreachable() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        _ = try registry.add(name: "build", hostname: "build.internal", user: "ci", port: nil)
        let runner = ScriptedProber(results: [
            HostCommandResult(exitCode: 0),
            HostCommandResult(exitCode: 255, stderr: "ci@build: Permission denied (publickey).\n"),
            HostCommandResult(exitCode: 255, stderr: "ssh: connect to host build.internal port 22: Connection refused\n"),
        ])
        let service = makeService(store: store, runner: runner,
                                  surface: { HostLivenessSurface(hostNames: ["build"]) })

        _ = await service.sweep()
        XCTAssertEqual(service.status(for: "build")?.status, .reachable)
        XCTAssertNil(service.status(for: "build")?.note)

        _ = await service.sweep()
        XCTAssertEqual(service.status(for: "build")?.status, .authRequired)
        XCTAssertNil(service.status(for: "build")?.note)

        _ = await service.sweep()
        let unreachable = try XCTUnwrap(service.status(for: "build"))
        XCTAssertEqual(unreachable.status, .unreachable)
        XCTAssertEqual(unreachable.note,
                       "Unreachable is loss of contact, not evidence that anything on build stopped.")
        XCTAssertFalse(unreachable.note?.localizedCaseInsensitiveContains("died") ?? true)
        XCTAssertFalse(unreachable.note?.localizedCaseInsensitiveContains("exited") ?? true)
    }

    func testChipHelpNeverImpliesRemoteWorkStopped() {
        let unreachable = HostProbeResult(
            name: "build", executionHostId: "ssh:build", status: .unreachable,
            detail: "connection refused", command: "ssh …", timedOut: false,
            note: "Unreachable is loss of contact, not evidence that anything on build stopped.",
            lastCheckedAt: Date().addingTimeInterval(-12))
        let help = HostLivenessPresentation.chipHelp(name: "build", result: unreachable)
        XCTAssertTrue(help.contains("unreachable"), help)
        XCTAssertTrue(help.contains("12s ago"), help)
        XCTAssertTrue(help.contains("loss of contact"), help)
        XCTAssertFalse(help.localizedCaseInsensitiveContains("died"), help)
        XCTAssertFalse(help.localizedCaseInsensitiveContains("exited"), help)
        XCTAssertFalse(help.localizedCaseInsensitiveContains("worker"), help)

        let reachable = HostProbeResult(
            name: "build", executionHostId: "ssh:build", status: .reachable,
            detail: "ok", command: "ssh …", timedOut: false,
            lastCheckedAt: Date())
        XCTAssertEqual(HostLivenessPresentation.chipStatusLine(reachable),
                       "reachable · just now")
        XCTAssertEqual(HostLivenessPresentation.ageLabel(seconds: 12), "12s ago")
        XCTAssertEqual(HostLivenessPresentation.ageLabel(seconds: 120), "2m ago")
    }

    // MARK: - No side effects

    func testReachabilityChangeDoesNotMutateHostsReposOrWorktrees() async throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        let added = try registry.add(name: "build", hostname: "build.internal",
                                     user: "ci", port: 2222, source: .sshConfig)
        let repo = RepoRecord(path: "/home/ci/app", displayName: "app", hostId: "ssh:build")
        let worktree = RemoteWorktreeRecord(
            id: "\(repo.id)::/home/ci/app", repoId: repo.id, hostId: "ssh:build",
            path: "/home/ci/app", branch: "main", isPrimary: true)
        try store.modify {
            $0.repos.append(repo)
            $0.remoteWorktrees.append(worktree)
        }
        let before = store.load()
        XCTAssertEqual(before.hosts, [added])

        let runner = ScriptedProber(results: [
            HostCommandResult(exitCode: 0),
            HostCommandResult(exitCode: 255, stderr: "Connection refused\n"),
        ])
        let service = makeService(store: store, runner: runner,
                                  surface: { HostLivenessSurface(hostNames: ["build"]) })

        _ = await service.sweep()
        XCTAssertEqual(service.status(for: "build")?.status, .reachable)
        _ = await service.sweep()
        XCTAssertEqual(service.status(for: "build")?.status, .unreachable)

        let after = store.load()
        XCTAssertEqual(after, before, "liveness is in-memory; orchard-data.json must not change")
        XCTAssertEqual(after.hosts, before.hosts)
        XCTAssertEqual(after.repos, before.repos)
        XCTAssertEqual(after.remoteWorktrees, before.remoteWorktrees)
        // The producer has no orchestration / worker seam: a status change cannot
        // settle a dispatch, mark a worker exited, or rewrite a workspace id.
    }

    private func withTimeout<T>(seconds: TimeInterval, _ work: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }
}
