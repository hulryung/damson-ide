import DamsonControl
import Darwin
import Foundation

/// Everything the next app instance needs to resurrect a pane around its
/// still-running child. Mirrors `PTYHost.PTYHandoff` field-for-field but with a public
/// initializer, so the service layer and tests can construct one without a live PTY.
public struct KeeperPTYHandoff: Sendable {
    public let fd: Int32
    public let pid: pid_t
    public let startSec: UInt64
    public let startUsec: UInt64
    public let cwd: String?
    /// Bytes already read from the kernel but not yet delivered to the parser —
    /// dropping them would tear an escape sequence in half for the adopting parser.
    public let tail: Data

    public init(fd: Int32, pid: pid_t, startSec: UInt64, startUsec: UInt64,
                cwd: String?, tail: Data) {
        self.fd = fd
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
        self.cwd = cwd
        self.tail = tail
    }
}

/// What the launch side gets back per claimed pane: the master fd plus the handoff
/// tail and everything the child printed while the app was down.
public struct KeeperAdoptedPTY: Sendable {
    public let fd: Int32
    public let pid: pid_t
    public let startSec: UInt64
    public let startUsec: UInt64
    public let buffer: Data

    public init(fd: Int32, pid: pid_t, startSec: UInt64, startUsec: UInt64, buffer: Data) {
        self.fd = fd
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
        self.buffer = buffer
    }
}

/// What a claim conversation established, beyond the fds it recovered.
///
/// The distinction the boot side needs is not "did I get this pane back" but *why not*.
/// A keeper that ANSWERED and reported a pane as no longer alive observed the EOF
/// itself: that is real evidence the child ended. A keeper that never answered — it
/// crashed, it timed out, its socket is gone — tells us nothing at all. For a local
/// pane the two collapse into the same outcome (the pane closes either way). For a
/// remote one they are rule 2's whole distinction: evidence of an ending, versus loss
/// of contact with the only process that could report one.
///
/// Subscript/`count`/`isEmpty` forward to the recovered panes, so a caller that only
/// wants the fds reads exactly as it did before.
public struct KeeperClaimOutcome: Sendable {
    public let panes: [String: KeeperAdoptedPTY]
    /// Whether a keeper answered the claim at all.
    public let answered: Bool
    /// Uuids an *answering* keeper accounted for as no longer alive — reported dead in
    /// its inventory, absent from it entirely, or refused mid-claim. Empty when no
    /// keeper answered, because then nothing was observed.
    public let ended: Set<String>

    public init(panes: [String: KeeperAdoptedPTY], answered: Bool, ended: Set<String>) {
        self.panes = panes
        self.answered = answered
        self.ended = ended
    }

    public subscript(uuid: String) -> KeeperAdoptedPTY? { panes[uuid] }
    public var isEmpty: Bool { panes.isEmpty }
    public var count: Int { panes.count }

    /// Whether the keeper positively accounted for this pane's child being gone, as
    /// opposed to us never having heard from the keeper.
    public func endingObserved(_ uuid: String) -> Bool { answered && ended.contains(uuid) }
}

/// The app side of the keeper handshake — Orchard's counterpart of damson's
/// `SessionHandoff`, speaking the same public `KeeperProtocol` (DamsonControl).
///
/// The socket conversations (`sendHolds`, `claimConversation`) are separated from
/// process management (`spawnKeeper`, `claim`) so tests can drive the exact wire
/// protocol against a fake peer on a socketpair without spawning anything.
public enum KeeperClient {
    // MARK: - Quit side

    /// Hand each (uuid, handoff) pair to the keeper over `socket`: one `hold` line +
    /// one SCM_RIGHTS fd message per pane, each acked, then a final `done`.
    ///
    /// OUR copy of every fd is closed here on both paths — on success because the
    /// keeper now holds a reference and our copy must go so the keeper's later close
    /// is the LAST close (the SIGHUP contract); on failure because the child should
    /// see exactly what a normal quit delivers. Returns the uuids the keeper acked.
    public static func sendHolds(socket: Int32,
                                 holds: [(uuid: String, handoff: KeeperPTYHandoff)]) -> Set<String> {
        var held: Set<String> = []
        for (uuid, handoff) in holds {
            let hold = KeeperHold(
                op: "hold", uuid: uuid, pid: Int32(handoff.pid),
                startSec: handoff.startSec, startUsec: handoff.startUsec,
                tail: handoff.tail.base64EncodedString())
            var ok = keeperWriteLine(fd: socket, hold)
            if ok {
                ok = KeeperFDPass.send(socket, fd: handoff.fd, payload: 0x46) > 0
            }
            if ok, let ackLine = keeperReadLine(fd: socket),
               let ack = keeperDecode(KeeperAck.self, ackLine), ack.ok {
                close(handoff.fd)
                held.insert(uuid)
            } else {
                NSLog("orchard: keeper handoff failed for %@ — closing (child will HUP)", uuid)
                close(handoff.fd)
            }
        }
        _ = keeperWriteLine(fd: socket, KeeperHold(op: "done"))
        _ = keeperReadLine(fd: socket)   // final ack — best effort
        return held
    }

    /// Spawn the keeper detached (own session, survives us) with the handoff
    /// socketpair on fd 3. Returns our end of the pair, or nil when the keeper could
    /// not be started (the caller then closes its released fds — the children get
    /// SIGHUP, equivalent to a normal quit).
    ///
    /// The keeper runs from a per-generation COPY of `executablePath` (normally the
    /// running app binary itself; see `KeeperDaemon`): the copy is immune to the
    /// original being replaced by an update, and no pkill against the app's name ever
    /// matches it. The keeper unlinks the copy when it exits.
    public static func spawnKeeper(generation: String, executablePath: String) -> Int32? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            NSLog("orchard: keeper source binary not found at %@", executablePath)
            return nil
        }
        KeeperPaths.ensureRuntimeDir()
        let copyPath = KeeperPaths.binaryCopyPath(generation: generation)
        do {
            try FileManager.default.copyItem(atPath: executablePath, toPath: copyPath)
        } catch {
            NSLog("orchard: keeper copy failed: %@", String(describing: error))
            return nil
        }

        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            try? FileManager.default.removeItem(atPath: copyPath)
            return nil
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        // POSIX_SPAWN_CLOEXEC_DEFAULT closes EVERYTHING not named here — crucial: a
        // stray inherited pty fd in the keeper would silently defeat last-close SIGHUP
        // forever.
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_adddup2(&fileActions, pair[1], keeperHandoffFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] =
            [strdup(copyPath), strdup(KeeperPaths.processMarker), strdup(generation), nil]
        // Inherit OUR environment — the keeper derives its runtime dir from TMPDIR,
        // and an empty environment would silently send it to the /tmp fallback while
        // the claiming app looks in $TMPDIR: the claim would never find it.
        let rc = posix_spawn(&pid, copyPath, &fileActions, &attr, argv, environ)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        for p in argv where p != nil { free(p) }
        close(pair[1])
        guard rc == 0 else {
            NSLog("orchard: keeper spawn failed rc=%d", rc)
            close(pair[0])
            try? FileManager.default.removeItem(atPath: copyPath)
            return nil
        }
        disableSIGPIPE(pair[0])
        NSLog("orchard: keeper spawned pid=%d generation=%@", pid, generation)
        return pair[0]
    }

    // MARK: - Launch side

    /// Claim the surviving panes of `generation` back from its keeper. Returns
    /// whatever could be claimed (empty when the keeper is gone or held nothing
    /// useful). Panes the keeper holds that aren't in `wanted` are closed by the
    /// keeper at `end` — their records no longer exist in the saved state.
    public static func claim(generation: String, wanted: [String]) -> KeeperClaimOutcome {
        let path = KeeperPaths.socketPath(generation: generation)
        var sock: Int32 = -1
        for attempt in 0..<3 {
            if attempt > 0 { usleep(200_000) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            if bindOrConnectUnix(fd: fd, path: path, listen: false) == nil {
                sock = fd
                break
            }
            close(fd)
        }
        guard sock >= 0 else {
            NSLog("orchard: no keeper answering for generation %@", generation)
            // Nothing was observed, so nothing is claimed about any held child.
            return KeeperClaimOutcome(panes: [:], answered: false, ended: [])
        }
        defer { close(sock) }
        disableSIGPIPE(sock)
        return claimConversation(socket: sock, generation: generation, wanted: wanted)
    }

    /// The whole claim conversation on an already-connected socket: hello →
    /// inventory → per-uuid claim/ack → end. Split out so tests can run it against
    /// `KeeperCore.serveClaim` on a socketpair.
    public static func claimConversation(socket: Int32, generation: String,
                                         wanted: [String]) -> KeeperClaimOutcome {
        guard keeperWriteLine(fd: socket, KeeperClaimHello(generation: generation)),
              let invLine = keeperReadLine(fd: socket),
              let inventory = keeperDecode(KeeperInventory.self, invLine), inventory.ok else {
            // A rejected hello (wrong generation) is not an answer *about these panes*:
            // whatever that keeper holds, it is not ours to conclude anything about.
            return KeeperClaimOutcome(panes: [:], answered: false, ended: [])
        }
        let alive = Set(inventory.sessions.filter(\.alive).map(\.uuid))
        // Everything we asked about that the keeper did not list as alive, it accounted
        // for: reported dead, or already closed and dropped from its inventory.
        var ended = Set(wanted.filter { !alive.contains($0) })

        var out: [String: KeeperAdoptedPTY] = [:]
        for uuid in wanted where alive.contains(uuid) {
            guard keeperWriteLine(fd: socket, KeeperClaimRequest(op: "claim", uuid: uuid)),
                  let grantLine = keeperReadLine(fd: socket),
                  let grant = keeperDecode(KeeperClaimGrant.self, grantLine), grant.ok else {
                // The keeper refused the grant — typically "died during claim", the
                // final drain finding EOF. That is still the keeper observing an end.
                ended.insert(uuid)
                continue
            }
            var fd: Int32 = -1
            var byte: UInt8 = 0
            let r = KeeperFDPass.recv(socket, outFD: &fd, payload: &byte)
            guard r > 0, fd >= 0, let pid = grant.pid else {
                if fd >= 0 { close(fd) }
                continue
            }
            _ = keeperWriteLine(fd: socket, KeeperClaimRequest(op: "ack"))
            out[uuid] = KeeperAdoptedPTY(
                fd: fd, pid: pid,
                startSec: grant.startSec ?? 0, startUsec: grant.startUsec ?? 0,
                buffer: grant.buffer.flatMap { Data(base64Encoded: $0) } ?? Data())
        }
        _ = keeperWriteLine(fd: socket, KeeperClaimRequest(op: "end"))
        _ = keeperReadLine(fd: socket)   // best effort
        if !out.isEmpty {
            NSLog("orchard: adopted %d surviving pane(s)", out.count)
        }
        return KeeperClaimOutcome(panes: out, answered: true, ended: ended)
    }
}
