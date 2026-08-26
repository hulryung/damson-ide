import XCTest
@testable import OrchardRuntime

/// What the explorer's watcher costs to arm, against a real checkout named by the
/// environment:
///
///     ORCHARD_BENCH_REPO=~/dev/CAN-debugger-hw swift test --filter FileWatcherBaselineBenchTests
///
/// Skipped when the variable is unset. It reads and never writes. Before T87 this walk
/// happened inside `FileWatcher.start`, which a workspace selection called from a view
/// update — so this number was paid on the main actor on every switch.
final class FileWatcherBaselineBenchTests: XCTestCase {
    func testBaselineWalkCost() throws {
        guard let raw = ProcessInfo.processInfo.environment["ORCHARD_BENCH_REPO"] else {
            throw XCTSkip("set ORCHARD_BENCH_REPO to a checkout to measure")
        }
        let repo = URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
        var entries: [String: FileWatchIdentity] = [:]
        let start = DispatchTime.now().uptimeNanoseconds
        entries = try FileWatchReconciler.identities(root: repo)
        let walk = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        let watcher = FileWatcher(debounce: 0.05)
        defer { watcher.stop() }
        let armStart = DispatchTime.now().uptimeNanoseconds
        try watcher.start(root: repo)
        let arm = Double(DispatchTime.now().uptimeNanoseconds - armStart) / 1_000_000

        print("""
        ORCHARD_BENCH \(repo.lastPathComponent): baseline walk \
        \(String(format: "%.1f", walk)) ms over \(entries.count) entries, \
        FileWatcher.start \(String(format: "%.2f", arm)) ms
        """)
        XCTAssertGreaterThan(entries.count, 0)
    }
}
