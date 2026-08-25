import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// T35: the discovery + injection halves of the dogfood-1 fixes — the accepted engine
/// vocabulary an agent reads out of `agent-context`, and the absolute `orchard`
/// command the runtime hands to every worker PTY.
final class DispatchErgonomicsTests: XCTestCase {

    // MARK: - agent-context enumerates the engines (dogfood-1 finding 1)

    /// `OrchardProtocol` cannot import the engine registry (no dependencies by
    /// design), so the published vocabulary is a literal. This is the guard that keeps
    /// the literal and the registry the same list.
    func testPublishedEngineIdentifiersMatchTheRegistry() {
        XCTAssertEqual(OrchardAgentEngines.acceptedIdentifiers,
                       AgentEngineRegistry.acceptedIdentifiers,
                       "agent-context advertises a different engine vocabulary than the "
                           + "runtime accepts; update OrchardAgentEngines.acceptedIdentifiers")
    }

    func testWorkerStartAgentFlagEnumeratesTheAcceptedEngines() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "worker-start" })
        let agent = try XCTUnwrap(spec.flags.first { $0.name == "agent" })
        let allowed = try XCTUnwrap(agent.allowedValues,
                                    "--agent must enumerate its values, not just hint a shape")
        XCTAssertTrue(allowed.contains("claude"))
        XCTAssertTrue(allowed.contains("claude-code"))
        for id in allowed {
            XCTAssertNotNil(AgentEngineRegistry.engine(id: id), "advertised but unusable: \(id)")
        }
    }

    func testTerminalEngineFlagEnumeratesTheAcceptedEngines() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "terminal" })
        let engine = try XCTUnwrap(spec.flags.first { $0.name == "engine" })
        XCTAssertEqual(engine.allowedValues, AgentEngineRegistry.acceptedIdentifiers)
    }

    func testWorkerReadSourceFlagEnumeratesItsValuesAndOffersRaw() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "worker-read" })
        let source = try XCTUnwrap(spec.flags.first { $0.name == "source" })
        XCTAssertEqual(source.allowedValues, ["auto", "transcript", "terminal"])
        let raw = try XCTUnwrap(spec.flags.first { $0.name == "raw" })
        XCTAssertNil(raw.valueHint, "--raw is a boolean flag")
        let limit = try XCTUnwrap(spec.flags.first { $0.name == "limit" })
        XCTAssertTrue(limit.summary.contains("\(WorkerReadPaging.defaultLimit)"),
                      "CommandSpec --limit must name the default (\(limit.summary))")
        XCTAssertEqual(WorkerReadPaging.defaultLimit, 200)
        XCTAssertTrue(spec.notes.contains { $0.contains("\(WorkerReadPaging.defaultLimit)") },
                      spec.notes.joined(separator: " | "))
        XCTAssertTrue(spec.notes.contains { $0.contains("hasOlder") },
                      spec.notes.joined(separator: " | "))
    }

    /// `allowedValues` is additive on the wire: metadata written by an older runtime
    /// (no key) must still decode.
    func testFlagSpecDecodesWithoutAllowedValues() throws {
        let json = #"{"name":"agent","summary":"Agent type","valueHint":"agent","required":false}"#
        let flag = try JSONDecoder().decode(FlagSpec.self, from: Data(json.utf8))
        XCTAssertEqual(flag.name, "agent")
        XCTAssertNil(flag.allowedValues)
        XCTAssertEqual(flag.aliases, [])
    }

    // MARK: - The injected CLI command (dogfood-1 finding 2)

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-cli-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func makeExecutable(_ url: URL) throws -> URL {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// `orchard serve` IS the CLI: the answer is its own absolute path.
    func testResolvesTheRunningExecutableWhenItIsTheCLI() throws {
        let directory = try scratchDirectory()
        let binary = try makeExecutable(directory.appendingPathComponent("orchard"))
        let resolution = OrchardCLIPath.resolution(
            environment: [:], executableURL: binary)
        XCTAssertEqual(resolution.origin, .runningExecutable)
        XCTAssertEqual(resolution.command, binary.resolvingSymlinksInPath().path)
        XCTAssertTrue(resolution.isAbsolute)
    }

    /// The app and the CLI are built side by side; the app must find its sibling.
    func testResolvesTheSiblingCLINextToTheAppBinary() throws {
        let directory = try scratchDirectory()
        let cli = try makeExecutable(directory.appendingPathComponent("orchard"))
        let app = try makeExecutable(directory.appendingPathComponent("OrchardApp"))
        let resolution = OrchardCLIPath.resolution(environment: [:], executableURL: app)
        XCTAssertEqual(resolution.origin, .siblingOfExecutable)
        XCTAssertEqual(resolution.command, cli.resolvingSymlinksInPath().path)
    }

    func testResolvesTheCLIShippedElsewhereInTheAppBundle() throws {
        let directory = try scratchDirectory()
        let bundle = directory.appendingPathComponent("Orchard.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        for path in [macOS, resources] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let app = try makeExecutable(macOS.appendingPathComponent("OrchardApp"))
        let cli = try makeExecutable(resources.appendingPathComponent("orchard"))
        let resolution = OrchardCLIPath.resolution(environment: [:], executableURL: app)
        XCTAssertEqual(resolution.origin, .applicationBundle)
        XCTAssertEqual(resolution.command, cli.resolvingSymlinksInPath().path)
    }

    /// The trampoline materializes a bundle in `~/Library/Caches` that the CLI does
    /// not travel to; it records the resolved path there instead. This is the exact
    /// configuration dogfood-1 ran in.
    func testResolvesTheRecordedInstallPathWrittenIntoTheBundle() throws {
        let directory = try scratchDirectory()
        let cli = try makeExecutable(directory.appendingPathComponent("orchard"))
        let bundle = directory.appendingPathComponent("Orchard.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        for path in [macOS, resources] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let app = try makeExecutable(macOS.appendingPathComponent("Orchard"))
        try Data("\(cli.path)\n".utf8).write(
            to: resources.appendingPathComponent("orchard-cli-path"))

        let resolution = OrchardCLIPath.resolution(
            environment: ["PATH": "/nonexistent-orchard-dir"], executableURL: app)
        XCTAssertEqual(resolution.origin, .recordedInstallPath)
        XCTAssertEqual(resolution.command, cli.path)
    }

    /// A recorded path that no longer names a runnable binary is ignored, not passed
    /// on to a worker as a command that will fail.
    func testAStaleRecordedInstallPathIsIgnored() throws {
        let directory = try scratchDirectory()
        let bundle = directory.appendingPathComponent("Orchard.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        for path in [macOS, resources] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let app = try makeExecutable(macOS.appendingPathComponent("Orchard"))
        try Data("/nonexistent/build/orchard\n".utf8).write(
            to: resources.appendingPathComponent("orchard-cli-path"))
        let resolution = OrchardCLIPath.resolution(
            environment: ["PATH": "/nonexistent-orchard-dir"], executableURL: app)
        XCTAssertEqual(resolution.origin, .unresolved)
    }

    func testFallsBackToTheSearchPath() throws {
        let host = try scratchDirectory()
        let elsewhere = try scratchDirectory()
        let cli = try makeExecutable(elsewhere.appendingPathComponent("orchard"))
        let app = try makeExecutable(host.appendingPathComponent("SomeOtherBinary"))
        let resolution = OrchardCLIPath.resolution(
            environment: ["PATH": "/nonexistent-orchard-dir:\(elsewhere.path)"],
            executableURL: app)
        XCTAssertEqual(resolution.origin, .searchPath)
        XCTAssertEqual(resolution.command, cli.path)
    }

    func testAnAbsoluteEnvironmentOverrideWins() throws {
        let directory = try scratchDirectory()
        let installed = try makeExecutable(directory.appendingPathComponent("orchard-pinned"))
        let running = try makeExecutable(directory.appendingPathComponent("orchard"))
        let resolution = OrchardCLIPath.resolution(
            environment: ["ORCHARD_CLI_COMMAND": installed.path], executableURL: running)
        XCTAssertEqual(resolution.origin, .environmentOverride)
        XCTAssertEqual(resolution.command, installed.path)
    }

    /// A bare or missing override is ignored — the point of the override is to name a
    /// real binary, and honouring `orchard` here would reintroduce the bug.
    func testABareOverrideIsIgnored() throws {
        let directory = try scratchDirectory()
        let running = try makeExecutable(directory.appendingPathComponent("orchard"))
        let resolution = OrchardCLIPath.resolution(
            environment: ["ORCHARD_CLI_COMMAND": "orchard"], executableURL: running)
        XCTAssertEqual(resolution.origin, .runningExecutable)
        XCTAssertTrue(resolution.isAbsolute)
    }

    /// macOS is case-insensitive by default, so the app bundle's own `Orchard`
    /// executable answers to the path `Contents/MacOS/orchard`. Resolution must not
    /// hand a worker the GUI app as its CLI.
    func testTheAppBinaryIsNeverMistakenForTheCLIOnACaseInsensitiveFilesystem() throws {
        let directory = try scratchDirectory()
        let bundle = directory.appendingPathComponent("Orchard.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let app = try makeExecutable(macOS.appendingPathComponent("Orchard"))

        let resolution = OrchardCLIPath.resolution(
            environment: ["PATH": "/nonexistent-orchard-dir"], executableURL: app)
        XCTAssertNotEqual(resolution.command, app.path)
        XCTAssertEqual(resolution.origin, .unresolved)
    }

    /// A directory named `orchard`, or a non-executable file, is not a CLI.
    func testNonExecutableCandidatesAreSkipped() throws {
        let directory = try scratchDirectory()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("orchard"), withIntermediateDirectories: true)
        let app = try makeExecutable(directory.appendingPathComponent("OrchardApp"))
        let resolution = OrchardCLIPath.resolution(
            environment: ["PATH": "/nonexistent-orchard-dir"], executableURL: app)
        XCTAssertNotEqual(resolution.origin, .siblingOfExecutable)
    }

    /// The last resort is honest about being one.
    func testUnresolvedIsReportedAsSuch() throws {
        let directory = try scratchDirectory()
        let app = try makeExecutable(directory.appendingPathComponent("OrchardApp"))
        let resolution = OrchardCLIPath.resolution(
            environment: ["PATH": "/nonexistent-orchard-dir", "HOME": directory.path],
            executableURL: app)
        XCTAssertEqual(resolution.origin, .unresolved)
        XCTAssertEqual(resolution.command, "orchard")
    }

    /// End to end in this very test process: the built `orchard` binary sits next to
    /// the test runner's package products, so resolution finds a real absolute path.
    func testResolutionInThisBuildProducesARunnableAbsolutePath() throws {
        let resolution = OrchardCLIPath.resolution()
        try XCTSkipIf(resolution.origin == .unresolved,
                      "no orchard binary is installed or built in this environment")
        XCTAssertTrue(resolution.isAbsolute, resolution.command)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolution.command))
    }
}
