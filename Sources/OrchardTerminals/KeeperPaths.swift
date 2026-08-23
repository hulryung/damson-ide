import Darwin
import Foundation

/// Where Orchard's keeper artifacts live. Orchard runs its own keeper (built into the
/// app executable — see `KeeperDaemon`), so it keeps its own runtime directory rather
/// than sharing damson's: an Orchard keeper socket can never collide with, or be swept
/// by, a damson instance's discovery logic.
///
/// The directory convention mirrors `damsonRuntimeDir()`:
///   1. `$XDG_RUNTIME_DIR/orchard`
///   2. `$TMPDIR/orchard-{uid}` (macOS default — TMPDIR is always set)
///   3. `/tmp/orchard-{uid}`
public enum KeeperPaths {
    /// argv[1] sentinel that turns the Orchard app binary into the keeper daemon
    /// (`KeeperDaemon.runIfInvoked()` branches on it before any AppKit setup).
    public static let processMarker = "__orchard-keeper"

    public static func runtimeDir() -> String {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("orchard")
        }
        let uid = getuid()
        if let tmp = env["TMPDIR"], !tmp.isEmpty {
            return (tmp as NSString).appendingPathComponent("orchard-\(uid)")
        }
        return "/tmp/orchard-\(uid)"
    }

    @discardableResult
    public static func ensureRuntimeDir() -> String {
        let dir = runtimeDir()
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// The keeper's claim socket for one handoff generation. The generation is short
    /// (8 hex chars) on purpose: this whole path must fit `sockaddr_un`'s 104 bytes
    /// even under a deep `$TMPDIR`.
    public static func socketPath(generation: String) -> String {
        (runtimeDir() as NSString).appendingPathComponent("keeper-\(generation).sock")
    }

    public static func logPath(generation: String) -> String {
        (runtimeDir() as NSString).appendingPathComponent("keeper-\(generation).log")
    }

    /// The keeper runs from a per-generation COPY of the app binary (`keeper-bin-<gen>`),
    /// exactly as damson does: the copy is immune to the original being replaced by an
    /// update, and `pkill -f OrchardApp` never matches it. The keeper unlinks its own
    /// copy on exit.
    public static func binaryCopyPath(generation: String) -> String {
        (runtimeDir() as NSString).appendingPathComponent("keeper-bin-\(generation)")
    }

    /// Short on purpose (see `socketPath`); eight hex chars is ample for
    /// "my keeper vs a stale one".
    public static func mintGeneration() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
