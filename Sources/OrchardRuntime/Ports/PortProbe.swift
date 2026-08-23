import Foundation
import os

/// One bounded `lsof` (or fixture) invocation. The sweep calls this once per tick.
public protocol PortProbe: Sendable {
    func listeningOutput() async -> String
}

/// Production probe: a single `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`. Failure, a
/// timeout, or a missing binary yields empty output — never thrown.
public struct LsofPortProbe: PortProbe {
    public static let defaultExecutable = "/usr/sbin/lsof"
    public static let defaultArguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]

    public var executablePath: String
    public var arguments: [String]
    public var timeout: TimeInterval

    public init(executablePath: String = LsofPortProbe.defaultExecutable,
                arguments: [String] = LsofPortProbe.defaultArguments,
                timeout: TimeInterval = 3) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.timeout = timeout
    }

    public func listeningOutput() async -> String {
        await Task.detached(priority: .utility) { () -> String in
            Self.run(executablePath: executablePath, arguments: arguments, timeout: timeout)
        }.value
    }

    static func run(executablePath: String, arguments: [String],
                    timeout: TimeInterval) -> String {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Test double that returns canned `lsof -Fn` text and counts invocations.
public final class FixturePortProbe: PortProbe, @unchecked Sendable {
    public var output: String
    private let count = OSAllocatedUnfairLock(initialState: 0)

    public init(_ output: String = "") {
        self.output = output
    }

    public var invocations: Int { count.withLock { $0 } }

    public func listeningOutput() async -> String {
        count.withLock { $0 += 1 }
        return output
    }
}
