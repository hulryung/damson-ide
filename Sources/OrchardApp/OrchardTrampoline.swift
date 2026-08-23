import AppKit
import Foundation
import OrchardRuntime

/// Relaunches Orchard inside its own `.app` bundle when run as a raw binary, so it gets
/// its own dock icon, name, and GUI-app registration — independent of damson.
/// Mirrors damson's `AppBundleTrampoline`. Skipped if `ORCHARD_NO_TRAMPOLINE=1`.
enum OrchardTrampoline {
    private static let bundleID = "app.damson.orchard"
    private static let bundleName = "Orchard"
    private static let appDirName = "Orchard.app"

    static func relaunchInAppBundleIfNeeded() {
        if ProcessInfo.processInfo.environment["ORCHARD_NO_TRAMPOLINE"] != nil { return }
        guard let executablePath = Bundle.main.executablePath else { return }
        if executablePath.contains(".app/Contents/MacOS/") { return }

        let bundleURL = cachedBundleURL()
        let executableURL = URL(fileURLWithPath: executablePath)
        do {
            try materializeBundle(at: bundleURL, withExecutableFrom: executableURL)
            try relaunch(bundleURL: bundleURL)
            exit(0)
        } catch {
            NSLog("orchard trampoline: %@", error.localizedDescription)
        }
    }

    private static func cachedBundleURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return caches.appendingPathComponent("orchard/\(appDirName)")
    }

    private static func materializeBundle(at bundleURL: URL, withExecutableFrom srcURL: URL) throws {
        let fm = FileManager.default
        let contentsDir = bundleURL.appendingPathComponent("Contents")
        let macosDir = contentsDir.appendingPathComponent("MacOS")
        let dstBinaryURL = macosDir.appendingPathComponent(bundleName)
        try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try infoPlist().write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: dstBinaryURL.path) { try fm.removeItem(at: dstBinaryURL) }
        try fm.copyItem(at: srcURL, to: dstBinaryURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstBinaryURL.path)

        // Sibling frameworks (RPATH @loader_path) must travel with the binary.
        let srcDir = srcURL.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension == "framework" {
                let dst = macosDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try? fm.copyItem(at: entry, to: dst)
            }
        }

        let resourcesDir = contentsDir.appendingPathComponent("Resources")
        try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

        if let iconURL = Bundle.module.url(forResource: "Orchard", withExtension: "icns") {
            let dstIcon = resourcesDir.appendingPathComponent("Orchard.icns")
            if fm.fileExists(atPath: dstIcon.path) { try? fm.removeItem(at: dstIcon) }
            try? fm.copyItem(at: iconURL, to: dstIcon)
        }

        // T35: workers are handed ORCHARD_CLI_COMMAND as an absolute path, and this
        // bundle lives in ~/Library/Caches — nowhere near the build the CLI was
        // compiled into. Carry the CLI in when it exists, and either way record the
        // path resolved from THIS location (which can still see the build directory)
        // so the relaunched copy resolves the same command instead of a bare
        // `orchard` a worker's login shell cannot find.
        carryCLI(from: srcDir, contentsDir: contentsDir, resourcesDir: resourcesDir)
    }

    /// The CLI goes into `Contents/Helpers`, never `Contents/MacOS`: this bundle's
    /// executable is `Orchard`, which on a case-insensitive filesystem IS the path
    /// `Contents/MacOS/orchard` — copying there would overwrite the app itself.
    private static func carryCLI(from srcDir: URL, contentsDir: URL, resourcesDir: URL) {
        let fm = FileManager.default
        let source = srcDir.appendingPathComponent(OrchardCLIPath.commandName)
        if fm.isExecutableFile(atPath: source.path) {
            let helpersDir = contentsDir.appendingPathComponent("Helpers")
            try? fm.createDirectory(at: helpersDir, withIntermediateDirectories: true)
            let destination = helpersDir.appendingPathComponent(OrchardCLIPath.commandName)
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            if (try? fm.copyItem(at: source, to: destination)) != nil {
                try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: destination.path)
                return
            }
        }
        let resolution = OrchardCLIPath.resolution()
        guard resolution.origin != .unresolved else { return }
        let sidecar = resourcesDir.appendingPathComponent(
            (OrchardCLIPath.recordedPathRelativeToBundle as NSString).lastPathComponent)
        try? Data(resolution.command.utf8).write(to: sidecar, options: .atomic)
    }

    private static func infoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key><string>\(bundleName)</string>
            <key>CFBundleIdentifier</key><string>\(bundleID)</string>
            <key>CFBundleName</key><string>\(bundleName)</string>
            <key>CFBundleVersion</key><string>0.0.1</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleIconFile</key><string>Orchard</string>
            <key>NSHighResolutionCapable</key><true/>
        </dict>
        </plist>
        """
    }

    private static func relaunch(bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-F", bundleURL.path]
        try process.run()
    }
}
