import Darwin
import DamsonControl
import Foundation
import XCTest
@testable import OrchardTerminals

/// The keeper protocol end to end against a REAL peer: `KeeperClient`'s quit-side and
/// launch-side conversations run on the test thread while `KeeperCore` (the daemon's
/// behaviour) serves the other end of a socketpair on a background queue — the exact
/// lockstep both processes speak, including the SCM_RIGHTS fd messages, without
/// spawning anything.
final class KeeperProtocolClientTests: XCTestCase {

    private func socketPair() -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }

    private func nonBlockingPipe() -> (readEnd: Int32, writeEnd: Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let fl = fcntl(fds[0], F_GETFL)
        _ = fcntl(fds[0], F_SETFL, fl | O_NONBLOCK)
        return (fds[0], fds[1])
    }

    // MARK: - fd passing

    /// The Swift SCM_RIGHTS port must deliver a NEW, WORKING descriptor: bytes written
    /// to the original pipe must be readable through the received fd.
    func testFDPassDeliversAWorkingDescriptor() {
        let (a, b) = socketPair()
        let (readEnd, writeEnd) = nonBlockingPipe()

        XCTAssertGreaterThan(KeeperFDPass.send(a, fd: readEnd, payload: 0x46), 0)
        var received: Int32 = -1
        var payload: UInt8 = 0
        XCTAssertGreaterThan(KeeperFDPass.recv(b, outFD: &received, payload: &payload), 0)
        XCTAssertEqual(payload, 0x46)
        XCTAssertGreaterThanOrEqual(received, 0)
        XCTAssertNotEqual(received, readEnd, "the peer must get its own descriptor")

        write(writeEnd, "ping", 4)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(received, &buf, buf.count)
        XCTAssertEqual(n, 4)
        XCTAssertEqual(String(decoding: buf[0..<4], as: UTF8.self), "ping")

        close(a); close(b); close(readEnd); close(writeEnd); close(received)
    }

    // MARK: - quit side (hold framing)

    /// `sendHolds` against a real `receiveHolds`: the keeper ends up holding a live
    /// descriptor for the acked uuid (draining sees fresh child output), the handoff
    /// tail seeds its buffer, and our copy of the fd was closed.
    func testSendHoldsAgainstRealReceiver() {
        let (appEnd, keeperEnd) = socketPair()
        let (readEnd, writeEnd) = nonBlockingPipe()
        let keeper = KeeperCore()

        let served = expectation(description: "receiveHolds finished")
        DispatchQueue.global().async {
            keeper.receiveHolds(fd: keeperEnd)
            served.fulfill()
        }

        let handoff = KeeperPTYHandoff(fd: readEnd, pid: 424_242, startSec: 7, startUsec: 9,
                                       cwd: "/tmp", tail: Data("TAIL".utf8))
        let held = KeeperClient.sendHolds(socket: appEnd, holds: [("uuid-a", handoff)])
        wait(for: [served], timeout: 5)

        XCTAssertEqual(held, ["uuid-a"])
        XCTAssertEqual(keeper.held.count, 1)
        XCTAssertEqual(keeper.held[0].uuid, "uuid-a")
        XCTAssertEqual(keeper.held[0].pid, 424_242)
        XCTAssertEqual(keeper.held[0].startSec, 7)
        XCTAssertEqual(keeper.held[0].buffer, Data("TAIL".utf8))

        // The keeper's descriptor is independent of ours (sendHolds closed ours) and
        // still reads the child's output.
        write(writeEnd, "ping", 4)
        keeper.drain(0)
        XCTAssertEqual(keeper.held[0].buffer, Data("TAILping".utf8))
        XCTAssertTrue(keeper.held[0].alive)

        close(appEnd); close(keeperEnd); close(writeEnd)
        keeper.closeAllHeld(reason: "test teardown")
    }

    // MARK: - launch side (claim conversation)

    /// The whole claim conversation against a real `serveClaim`: inventory → claim →
    /// grant + fd → ack → end. The claimed pane comes back with the keeper's buffer
    /// and a working descriptor; the missing uuid is skipped without derailing the
    /// conversation; `end` stops the keeper with nothing left held.
    func testClaimConversationAgainstRealServer() {
        let (clientEnd, serverEnd) = socketPair()
        let (readEnd, writeEnd) = nonBlockingPipe()
        let keeper = KeeperCore()
        keeper.adopt([KeeperHeld(uuid: "uuid-a", fd: readEnd, pid: 31_337,
                                 startSec: 3, startUsec: 5,
                                 buffer: Data("history".utf8), alive: true)])

        let served = expectation(description: "serveClaim finished")
        var ended = false
        DispatchQueue.global().async {
            ended = keeper.serveClaim(conn: serverEnd, generation: "G")
            served.fulfill()
        }

        let out = KeeperClient.claimConversation(socket: clientEnd, generation: "G",
                                                 wanted: ["uuid-a", "ghost"])
        wait(for: [served], timeout: 5)

        XCTAssertTrue(ended, "`end` must tell the keeper to exit")
        XCTAssertEqual(out.count, 1)
        let adopted = out["uuid-a"]
        XCTAssertEqual(adopted?.pid, 31_337)
        XCTAssertEqual(adopted?.startSec, 3)
        XCTAssertEqual(adopted?.buffer, Data("history".utf8))
        XCTAssertTrue(keeper.held.isEmpty, "a claimed pane must leave the keeper")

        // The reclaimed descriptor is live: fresh child output arrives through it.
        if let fd = adopted?.fd {
            write(writeEnd, "pong", 4)
            var buf = [UInt8](repeating: 0, count: 16)
            let n = read(fd, &buf, buf.count)
            XCTAssertEqual(n, 4)
            XCTAssertEqual(String(decoding: buf[0..<4], as: UTF8.self), "pong")
            close(fd)
        }
        close(clientEnd); close(writeEnd)
    }

    /// A generation mismatch (a stale keeper from some other handoff) yields nothing —
    /// and loses the keeper nothing.
    func testClaimAgainstWrongGenerationYieldsNothing() {
        let (clientEnd, serverEnd) = socketPair()
        let (readEnd, writeEnd) = nonBlockingPipe()
        let keeper = KeeperCore()
        keeper.adopt([KeeperHeld(uuid: "uuid-a", fd: readEnd, pid: 1,
                                 startSec: 0, startUsec: 0, buffer: Data(), alive: true)])

        let served = expectation(description: "serveClaim finished")
        DispatchQueue.global().async {
            _ = keeper.serveClaim(conn: serverEnd, generation: "REAL")
            served.fulfill()
        }
        let out = KeeperClient.claimConversation(socket: clientEnd, generation: "STALE",
                                                 wanted: ["uuid-a"])
        wait(for: [served], timeout: 5)

        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(keeper.held.count, 1)
        XCTAssertTrue(keeper.held[0].alive)

        close(clientEnd); close(writeEnd)
        keeper.closeAllHeld(reason: "test teardown")
    }

    /// `claim` (the socket-connecting wrapper) against a missing keeper: no socket at
    /// the generation's path → empty, quickly and without throwing.
    func testClaimWithNoKeeperAnsweringReturnsEmpty() {
        let out = KeeperClient.claim(generation: "nosuchgen", wanted: ["x"])
        XCTAssertTrue(out.isEmpty)
    }
}
