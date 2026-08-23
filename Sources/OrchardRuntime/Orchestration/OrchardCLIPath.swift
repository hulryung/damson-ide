import Foundation

/// Resolves the absolute path of the `orchard` CLI this runtime should teach its
/// workers to call (T35, dogfood-1 finding 2).
///
/// The injected preamble used to say bare `orchard`. A worker PTY inherits a login
/// shell whose PATH usually has no `orchard` on it — a development build lives in
/// `.build/release`, and the app bundle ships its CLI inside `Contents/MacOS`. The
/// dogfood worker's first lifecycle call died with `command not found` and it only
/// settled after guessing the build path itself.
///
/// The resolution order goes from "what is provably running" outward: the serving
/// process's own executable, a sibling binary next to it, the enclosing app bundle,
/// then PATH and the conventional install prefixes. Every candidate is checked for
/// existence and the executable bit, so the value handed to a worker is a command
/// that ran on this machine, not a hopeful string.
public enum OrchardCLIPath {
    public static let commandName = "orchard"

    /// Where the resolved command came from — recorded in the runtime metadata so
    /// `orchard status` can say why a worker was told to call that path.
    public enum Origin: String, Sendable {
        case environmentOverride = "environment_override"
        case runningExecutable = "running_executable"
        case siblingOfExecutable = "sibling_of_executable"
        case applicationBundle = "application_bundle"
        /// A path written next to the running binary by whoever installed it — the
        /// app trampoline records the build's CLI here when it materializes its
        /// bundle somewhere the CLI does not travel to.
        case recordedInstallPath = "recorded_install_path"
        case searchPath = "search_path"
        case installPrefix = "install_prefix"
        /// Nothing on this machine resolved; the bare command name is the last resort.
        case unresolved = "unresolved"
    }

    public struct Resolution: Sendable, Equatable {
        public var command: String
        public var origin: Origin
        public var isAbsolute: Bool { command.hasPrefix("/") }

        public init(command: String, origin: Origin) {
            self.command = command
            self.origin = origin
        }
    }

    /// Sidecar file, relative to an `.app` bundle root, naming the CLI to use. The
    /// trampoline writes it because the bundle it materializes in `~/Library/Caches`
    /// is nowhere near the build directory the CLI lives in.
    public static let recordedPathRelativeToBundle = "Contents/Resources/orchard-cli-path"

    /// Conventional install prefixes, tried last and in this order.
    static let installPrefixes = [
        "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin",
    ]

    /// The command string to inject. Absolute whenever anything resolves.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               executableURL: URL? = Bundle.main.executableURL,
                               fileManager: FileManager = .default) -> String {
        resolution(environment: environment, executableURL: executableURL,
                   fileManager: fileManager).command
    }

    public static func resolution(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  executableURL: URL? = Bundle.main.executableURL,
                                  fileManager: FileManager = .default) -> Resolution {
        // 1. An explicit override wins: an installer or a test rig that knows where
        //    the CLI lives should not be second-guessed.
        if let override = environment["ORCHARD_CLI_COMMAND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           override.hasPrefix("/"), isExecutable(override, fileManager) {
            return Resolution(command: override, origin: .environmentOverride)
        }

        let executable = executableURL?.resolvingSymlinksInPath().standardizedFileURL
        if let executable {
            // 2. `orchard serve` IS the CLI: its own path is the answer.
            if executable.lastPathComponent == commandName,
               isExecutable(executable.path, fileManager) {
                return Resolution(command: executable.path, origin: .runningExecutable)
            }
            // 3. The app binary and the CLI are built side by side (.build/release,
            //    Contents/MacOS in a bundle).
            let sibling = executable.deletingLastPathComponent()
                .appendingPathComponent(commandName).path
            if isCLI(sibling, running: executable, fileManager) {
                return Resolution(command: sibling, origin: .siblingOfExecutable)
            }
            // 4. Elsewhere in the enclosing .app, or the path its installer recorded.
            if let bundle = enclosingBundle(of: executable) {
                if let recorded = recordedPath(inBundle: bundle, fileManager) {
                    return Resolution(command: recorded, origin: .recordedInstallPath)
                }
                if let bundled = bundledCandidate(inBundle: bundle, running: executable,
                                                  fileManager) {
                    return Resolution(command: bundled, origin: .applicationBundle)
                }
            }
        }

        // 5. PATH, in order.
        if let found = searchPath(environment: environment, fileManager: fileManager) {
            return Resolution(command: found, origin: .searchPath)
        }

        // 6. Conventional prefixes, then the user's own bin.
        var prefixes = installPrefixes
        if let home = environment["HOME"], !home.isEmpty {
            prefixes.append(home + "/.local/bin")
        }
        for prefix in prefixes {
            let candidate = prefix + "/" + commandName
            if isExecutable(candidate, fileManager) {
                return Resolution(command: candidate, origin: .installPrefix)
            }
        }
        return Resolution(command: commandName, origin: .unresolved)
    }

    /// `.../Orchard.app/Contents/MacOS/OrchardApp` → the enclosing `.app` root.
    static func enclosingBundle(of executable: URL) -> URL? {
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// The CLI shipped in the bundle. `Contents/MacOS` is already covered by the
    /// sibling check, so this looks at the other places a bundle carries a helper.
    private static func bundledCandidate(inBundle bundle: URL, running: URL,
                                         _ fileManager: FileManager) -> String? {
        for relative in ["Contents/MacOS", "Contents/Helpers", "Contents/Resources"] {
            let candidate = bundle.appendingPathComponent(relative)
                .appendingPathComponent(commandName).path
            if isCLI(candidate, running: running, fileManager) { return candidate }
        }
        return nil
    }

    /// An executable candidate that is not the running binary under another spelling.
    ///
    /// The app target is `OrchardApp` and its bundle executable is `Orchard`, both of
    /// which differ from `orchard` only in case — and macOS's default filesystem is
    /// case-insensitive, so `Contents/MacOS/orchard` resolves to the app binary
    /// itself. Handing a worker the GUI app as its CLI would be worse than handing it
    /// a bare command name.
    private static func isCLI(_ candidate: String, running: URL,
                              _ fileManager: FileManager) -> Bool {
        guard isExecutable(candidate, fileManager) else { return false }
        let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            .standardizedFileURL
        if resolved.path.compare(running.path, options: .caseInsensitive) == .orderedSame {
            return false
        }
        // Same inode reached by a different path is the same binary.
        let candidateID = fileIdentity(resolved.path, fileManager)
        let runningID = fileIdentity(running.path, fileManager)
        if let candidateID, let runningID, candidateID == runningID { return false }
        return true
    }

    private static func fileIdentity(_ path: String, _ fileManager: FileManager) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let inode = attributes[.systemFileNumber] as? Int,
              let device = attributes[.systemNumber] as? Int else { return nil }
        return "\(device):\(inode)"
    }

    private static func recordedPath(inBundle bundle: URL,
                                     _ fileManager: FileManager) -> String? {
        let sidecar = bundle.appendingPathComponent(recordedPathRelativeToBundle)
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let recorded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recorded.hasPrefix("/"), isExecutable(recorded, fileManager) else { return nil }
        return recorded
    }

    private static func searchPath(environment: [String: String],
                                   fileManager: FileManager) -> String? {
        guard let path = environment["PATH"], !path.isEmpty else { return nil }
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
            guard entry.hasPrefix("/") else { continue }
            let candidate = String(entry) + "/" + commandName
            if isExecutable(candidate, fileManager) { return candidate }
        }
        return nil
    }

    private static func isExecutable(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }
}
