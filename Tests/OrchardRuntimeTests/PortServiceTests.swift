import Darwin
import XCTest
@testable import OrchardRuntime

final class PortServiceTests: XCTestCase {
    private let fixtureLsof = [
        "p123",
        "cnode",
        "n127.0.0.1:5173",
        "p456",
        "cnginx",
        "n*:80",
        "p789",
        "cpython",
        "n[::1]:8000",
    ].joined(separator: "\n")

    private let workspaces = [
        PortWorkspaceProbe(id: "r::/repo", repoId: "r", displayName: "main", path: "/repo"),
        PortWorkspaceProbe(id: "r::/repo/wt", repoId: "r", displayName: "feature", path: "/repo/wt"),
    ]

    func testSweepSkipsProbeWhenNoWorkspacesAreOpen() async {
        let probe = FixturePortProbe(fixtureLsof)
        let service = PortService(
            workspaces: { [] },
            probe: probe,
            cwdLookup: { _ in "/repo/wt" },
            interval: 0.05)
        await service.sweep()
        XCTAssertEqual(probe.invocations, 0)
        XCTAssertTrue(service.snapshot().ports.isEmpty)

        service.start()
        try? await Task.sleep(nanoseconds: 120_000_000)
        service.stop()
        XCTAssertEqual(probe.invocations, 0)
    }

    func testSweepParsesOnceAndAttributesByCwdContainment() async {
        let probe = FixturePortProbe(fixtureLsof)
        let service = PortService(
            workspaces: { self.workspaces },
            probe: probe,
            cwdLookup: { pid in
                switch pid {
                case 123: return "/repo/wt/packages/app"
                case 456: return "/usr"
                case 789: return "/repo"
                default: return nil
                }
            },
            interval: 60)
        let snapshot = await service.sweep()
        XCTAssertEqual(probe.invocations, 1)
        XCTAssertEqual(snapshot.ports.map(\.port), [5173, 8000])
        XCTAssertEqual(snapshot.ports.map(\.worktreeId), ["r::/repo/wt", "r::/repo"])
        XCTAssertEqual(snapshot.ports.first?.processName, "node")
        XCTAssertEqual(snapshot.ports.first?.connectHost, "127.0.0.1")
        XCTAssertEqual(snapshot.ports.last?.processName, "python")
        XCTAssertNil(snapshot.ports.first { $0.pid == 456 }, "unattributed listeners are skipped")
    }

    func testCwdLookupFailureIsSkippedNotFatal() async {
        let probe = FixturePortProbe("p1\ncnode\nn127.0.0.1:3000\n")
        let service = PortService(
            workspaces: { self.workspaces },
            probe: probe,
            cwdLookup: { _ in nil },
            interval: 60)
        let snapshot = await service.sweep()
        XCTAssertTrue(snapshot.ports.isEmpty)
        XCTAssertNil(snapshot.unavailableReason)
    }

    func testIntervalFromEnvironmentClamps() {
        XCTAssertEqual(PortService.intervalFromEnvironment([:]), PortService.defaultInterval)
        XCTAssertEqual(PortService.intervalFromEnvironment(["ORCHARD_PORTS_SWEEP_INTERVAL": "6"]), 6)
        XCTAssertEqual(PortService.intervalFromEnvironment(["ORCHARD_PORTS_SWEEP_INTERVAL": "1"]),
                       PortService.minimumInterval)
        XCTAssertEqual(PortService.intervalFromEnvironment(["ORCHARD_PORTS_SWEEP_INTERVAL": "99"]),
                       PortService.maximumInterval)
    }

    func testLibprocLookupOfSelfIsBestEffort() {
        let cwd = ProcessWorkingDirectory.lookup(pid: getpid())
        XCTAssertNotNil(cwd)
        XCTAssertFalse(cwd?.isEmpty ?? true)
    }
}
