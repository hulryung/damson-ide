import DamsonControl
import Darwin
import Foundation

/// Flipped by the SIGTERM handler; a C signal handler cannot capture context, so the
/// flag must be a global.
private var keeperTerminating = false

/// The keeper daemon — Orchard's counterpart of the `damson-keeper` executable, built
/// INTO the app binary instead of shipped beside it: `KeeperDaemon.runIfInvoked()` is
/// the very first thing the app's `main` does, and when argv says
/// `__orchard-keeper <generation>` this process becomes the keeper and never reaches
/// any AppKit setup (no NSApplication, no Dock ghost, no trampoline).
///
/// The quit side spawns it from a per-generation COPY of the binary
/// (`KeeperClient.spawnKeeper`), holds arrive on the inherited socketpair (fd 3,
/// `keeperHandoffFD`), then the poll loop drains the masters and serves claims on the
/// generation's unix socket — the exact `KeeperProtocol` lockstep damson documents in
/// docs/SESSION-KEEPER.md. All behaviour lives in `KeeperCore` so it can be tested;
/// this file is just process setup: arguments, log file, signals, sockets.
public enum KeeperDaemon {
    /// Branch on the keeper argv marker. Returns normally (doing nothing) for an
    /// ordinary app launch; exits the process after the keeper run otherwise.
    public static func runIfInvoked() {
        let args = CommandLine.arguments
        guard args.count >= 3, args[1] == KeeperPaths.processMarker else { return }
        run(generation: args[2], binaryPath: args[0])
    }

    /// The keeper unlinks its own binary on exit — but ONLY a per-generation copy
    /// (`keeper-bin-*`). Someone running the real app binary with keeper args by hand
    /// must never delete their build product / installed app.
    private static func removeBinaryCopy(_ binaryPath: String) {
        guard (binaryPath as NSString).lastPathComponent.hasPrefix("keeper-bin-") else { return }
        unlink(binaryPath)
    }

    private static func run(generation: String, binaryPath: String) -> Never {
        let runtimeDir = KeeperPaths.ensureRuntimeDir()
        _ = runtimeDir
        let logPath = KeeperPaths.logPath(generation: generation)
        FileManager.default.createFile(atPath: logPath, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        let logHandle = FileHandle(forWritingAtPath: logPath)
        logHandle?.seekToEndOfFile()
        func log(_ msg: String) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
            logHandle?.write(line.data(using: .utf8) ?? Data())
        }

        signal(SIGPIPE, SIG_IGN)
        // SIGTERM (logout / user cleanup): close every master — the children get
        // SIGHUP, standard "terminal went away" — and exit. The handler only flips a
        // flag; poll returns EINTR and the loop notices.
        signal(SIGTERM) { _ in keeperTerminating = true }
        _ = chdir("/")

        log("keeper start generation=\(generation) pid=\(getpid())")

        let keeper = KeeperCore(shouldTerminate: { keeperTerminating }, log: log)

        // Phase 1: receive holds on the inherited socketpair (fd 3).
        keeper.receiveHolds(fd: keeperHandoffFD)
        close(keeperHandoffFD)

        guard !keeper.held.isEmpty else {
            log("nothing to hold — exiting")
            removeBinaryCopy(binaryPath)
            exit(0)
        }
        log("holding \(keeper.held.count) session(s)")

        // Phase 2: drain + serve claims.
        let sockPath = KeeperPaths.socketPath(generation: generation)
        unlink(sockPath)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            log("socket() failed")
            removeBinaryCopy(binaryPath)
            exit(1)
        }
        if let bindError = bindOrConnectUnix(fd: listenFD, path: sockPath, listen: true) {
            log("bind failed: \(bindError)")
            // Exiting closes every held master — the children get SIGHUP, exactly a
            // normal quit. Nothing strands. Drop our binary copy like the normal exit
            // path does.
            removeBinaryCopy(binaryPath)
            exit(1)
        }
        chmod(sockPath, 0o600)

        let outcome = keeper.run(listenFD: listenFD, generation: generation)
        log("keeper loop ended: \(outcome)")

        close(listenFD)
        unlink(sockPath)
        // The app runs us from a per-generation COPY in the runtime dir; clean it up.
        // (Unlinking a running binary is safe — the vnode lives until we exit.)
        removeBinaryCopy(binaryPath)
        log("keeper exit")
        exit(0)
    }
}
