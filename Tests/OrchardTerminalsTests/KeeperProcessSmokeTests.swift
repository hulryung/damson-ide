import Darwin
import Foundation
import XCTest
@testable import OrchardTerminals

/// Process-level smoke of the REAL keeper: spawns the actual app binary as a
/// per-generation keeper copy (posix_spawn, fd-3 socketpair, SETSID,
/// CLOEXEC_DEFAULT), hands it a held descriptor, lets it buffer output "while the
/// app is down", then claims everything back and watches the keeper clean up after
/// itself.
///
/// Opt-in, because it needs a built `OrchardApp` binary and leaves a short-lived
/// child process — not something the ordinary unit run should depend on:
///
///   swift build --product OrchardApp
///   ORCHARD_APP_BINARY=$PWD/.build/debug/OrchardApp \
///     swift test --filter KeeperProcessSmokeTests
///
/// What this still cannot cover is the full app quit/relaunch loop (windows, real
/// PTYs, agent panes) — that remains the manual smoke.
final class KeeperProcessSmokeTests: XCTestCase {

    func testSpawnHoldClaimAgainstTheRealKeeperProcess() throws {
        guard let binary = ProcessInfo.processInfo.environment["ORCHARD_APP_BINARY"],
              !binary.isEmpty else {
            throw XCTSkip("set ORCHARD_APP_BINARY to a built OrchardApp to run the keeper process smoke")
        }

        // A pipe stands in for a PTY master/child pair.
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let readEnd = fds[0], writeEnd = fds[1]

        let generation = KeeperPaths.mintGeneration()
        let copyPath = KeeperPaths.binaryCopyPath(generation: generation)
        guard let sock = KeeperClient.spawnKeeper(generation: generation,
                                                  executablePath: binary) else {
            close(readEnd); close(writeEnd)
            return XCTFail("keeper failed to spawn from \(binary)")
        }

        let handoff = KeeperPTYHandoff(fd: readEnd, pid: getpid(), startSec: 1, startUsec: 2,
                                       cwd: "/tmp", tail: Data("TAIL-".utf8))
        let held = KeeperClient.sendHolds(socket: sock, holds: [("smoke-a", handoff)])
        close(sock)
        XCTAssertEqual(held, ["smoke-a"], "the real keeper must ack the hold")

        // "While the app is down": the child keeps printing; the keeper must drain it.
        write(writeEnd, "while-down", 10)
        usleep(300_000)

        // "Next boot": claim the inventory back.
        let claimed = KeeperClient.claim(generation: generation, wanted: ["smoke-a"])
        let adopted = try XCTUnwrap(claimed["smoke-a"], "the survivor must be claimable")
        XCTAssertEqual(adopted.buffer, Data("TAIL-while-down".utf8),
                       "handoff tail + everything buffered while away, in order")

        // The reclaimed descriptor is live.
        write(writeEnd, "after", 5)
        var buf = [UInt8](repeating: 0, count: 32)
        var n = -1
        for _ in 0..<50 {   // the fd rides over as non-blocking
            n = read(adopted.fd, &buf, buf.count)
            if n > 0 { break }
            usleep(20_000)
        }
        XCTAssertEqual(n, 5)
        XCTAssertEqual(String(decoding: buf[0..<5], as: UTF8.self), "after")
        close(adopted.fd)
        close(writeEnd)

        // `end` was sent: the keeper exits and cleans up its socket and binary copy.
        let sockPath = KeeperPaths.socketPath(generation: generation)
        var cleaned = false
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: copyPath),
               !FileManager.default.fileExists(atPath: sockPath) {
                cleaned = true
                break
            }
            usleep(100_000)
        }
        XCTAssertTrue(cleaned, "the keeper must unlink its per-generation copy and socket on exit")
        let log = (try? String(contentsOfFile: KeeperPaths.logPath(generation: generation),
                               encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("claimed uuid=smoke-a"), "keeper log should record the claim:\n\(log)")
        XCTAssertTrue(log.contains("keeper loop ended: claimed"), "keeper log should record the outcome:\n\(log)")
    }
}
