import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// RPC contract for the file verbs through the in-memory server seam.
@MainActor
final class FileHandlerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-file-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, to name: String, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFolderWorkspace() throws -> (InMemoryRuntimeServer, Workspace, FileOpenCenter) {
        let folder = tmp.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("hello\n", to: "src/app.swift", in: folder)
        try write("notes\n", to: "README.md", in: folder)
        try write("secret", to: ".env", in: folder)

        let service = WorkspaceService(dataURL: tmp.appendingPathComponent("orchard-data.json"))
        let repo = try service.addRepo(path: folder, displayName: "ws")
        let listed = try service.listWorkspaces(repo: repo.id)
        let workspace = try XCTUnwrap(listed.first)
        let opens = FileOpenCenter()
        var registry = CommandRegistry()
        registry.register(FileCommandHandler(workspaces: service, opens: opens))
        let server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_files")
        return (server, workspace, opens)
    }

    private func call(_ server: InMemoryRuntimeServer, _ method: String,
                      _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    func testReadDirPreviewStatSearchRoundTrip() async throws {
        let (server, workspace, _) = try makeFolderWorkspace()
        let wt: [String: JSONValue] = ["worktree": .string(workspace.id)]

        let listing = await call(server, "file-read-dir", wt)
        XCTAssertTrue(listing.ok, listing.error?.message ?? "")
        let entries = try XCTUnwrap(listing.result?.objectValue?["entries"]?.arrayValue)
        let names = entries.compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertEqual(names, ["src", "README.md"])
        XCTAssertFalse(names.contains(".env"))

        let dotted = await call(server, "file-read-dir", wt.merging(["show-dotfiles": .bool(true)]) { $1 })
        let dottedNames = try XCTUnwrap(dotted.result?.objectValue?["entries"]?.arrayValue)
            .compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertTrue(dottedNames.contains(".env"))

        let preview = await call(server, "file-preview", wt.merging(["path": .string("README.md")]) { $1 })
        XCTAssertTrue(preview.ok, preview.error?.message ?? "")
        XCTAssertEqual(preview.result?.objectValue?["content"]?.stringValue, "notes\n")
        XCTAssertEqual(preview.result?.objectValue?["isBinary"]?.boolValue, false)

        let stat = await call(server, "file-stat", wt.merging(["path": .string("src")]) { $1 })
        XCTAssertEqual(stat.result?.objectValue?["isDirectory"]?.boolValue, true)

        let search = await call(server, "file-search", wt.merging(["query": .string("hello")]) { $1 })
        XCTAssertTrue(search.ok, search.error?.message ?? "")
        let hits = try XCTUnwrap(search.result?.objectValue?["matches"]?.arrayValue)
        XCTAssertEqual(hits.first?.objectValue?["path"]?.stringValue, "src/app.swift")
        XCTAssertEqual(hits.first?.objectValue?["line"]?.intValue
                       ?? hits.first?.objectValue?["line"]?.numberValue.map { Int($0) }, 1)
        XCTAssertEqual(hits.first?.objectValue?["excerpt"]?.stringValue, "hello")

        let filtered = await call(server, "file-list", wt.merging(["query": .string("md")]) { $1 })
        let files = try XCTUnwrap(filtered.result?.objectValue?["files"]?.arrayValue)
            .compactMap(\.stringValue)
        XCTAssertEqual(files, ["README.md"])
    }

    func testPathEscapeIsATypedError() async throws {
        let (server, workspace, _) = try makeFolderWorkspace()
        let response = await call(server, "file-preview", [
            "worktree": .string(workspace.id),
            "path": .string("../secret"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "path_escape")
    }

    func testFileOpenPostsNotification() async throws {
        let (server, workspace, opens) = try makeFolderWorkspace()
        var received: [FileOpenRequest] = []
        let task = Task {
            for await request in opens.events() {
                received.append(request)
                break
            }
        }
        // Give the subscriber a tick to register before posting.
        try await Task.sleep(nanoseconds: 20_000_000)
        let response = await call(server, "file-open", [
            "worktree": .string(workspace.id),
            "path": .string("README.md"),
        ])
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        XCTAssertEqual(response.result?.objectValue?["opened"]?.boolValue, true)
        XCTAssertEqual(response.result?.objectValue?["kind"]?.stringValue, "markdown")
        _ = await task.result
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.relativePath, "README.md")
        XCTAssertEqual(received.first?.mode, .edit)
    }

    func testFileDiffPrintsForkPointDiff() async throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@t.io"])
        try git(["config", "user.name", "Test"])
        try write("one\n", to: "tracked.txt", in: repo)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "init"])
        try write("two\n", to: "tracked.txt", in: repo)

        let service = WorkspaceService(dataURL: tmp.appendingPathComponent("orchard-data.json"))
        // Force a folder workspace so the checkout itself is the file-service root
        // (git worktrees are only listed after `worktree-create`).
        let record = try service.addRepo(path: repo, kind: .folder)
        let workspace = try XCTUnwrap(try service.listWorkspaces(repo: record.id).first)
        var registry = CommandRegistry()
        registry.register(FileCommandHandler(workspaces: service))
        let server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_diff")

        let response = await call(server, "file-diff", [
            "worktree": .string(workspace.id),
            "path": .string("tracked.txt"),
        ])
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        let diff = try XCTUnwrap(response.result?.objectValue?["diff"]?.stringValue)
        XCTAssertTrue(diff.contains("-one") || diff.contains("-one\n"))
        XCTAssertTrue(diff.contains("+two") || diff.contains("+two\n"))
    }

    func testFileOpenChangedNotifiesDiffTargets() async throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        let repo = tmp.appendingPathComponent("changed")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@t.io"])
        try git(["config", "user.name", "Test"])
        try write("a\n", to: "keep.txt", in: repo)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "init"])
        try write("b\n", to: "keep.txt", in: repo)
        try write("new\n", to: "fresh.txt", in: repo)

        let service = WorkspaceService(dataURL: tmp.appendingPathComponent("orchard-data.json"))
        let record = try service.addRepo(path: repo, kind: .folder)
        let workspace = try XCTUnwrap(try service.listWorkspaces(repo: record.id).first)
        let opens = FileOpenCenter()
        var registry = CommandRegistry()
        registry.register(FileCommandHandler(workspaces: service, opens: opens))
        let server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_changed")

        var received: [FileOpenRequest] = []
        let task = Task {
            for await request in opens.events() {
                received.append(request)
                if received.count >= 2 { break }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let response = await call(server, "file-open-changed", [
            "worktree": .string(workspace.id),
            "mode": .string("diff"),
        ])
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        XCTAssertEqual(response.result?.objectValue?["totalChanged"]?.intValue, 2)
        _ = await task.result
        XCTAssertEqual(Set(received.map(\.relativePath)), Set(["keep.txt", "fresh.txt"]))
        XCTAssertTrue(received.allSatisfy { $0.mode == .diff })
    }

    func testContentSearchIncludeGlobOverRPC() async throws {
        let (server, workspace, _) = try makeFolderWorkspace()
        let response = await call(server, "file-search", [
            "worktree": .string(workspace.id),
            "query": .string("hello"),
            "include": .string("*.swift"),
        ])
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        let hits = try XCTUnwrap(response.result?.objectValue?["matches"]?.arrayValue)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.objectValue?["path"]?.stringValue, "src/app.swift")

        let missed = await call(server, "file-search", [
            "worktree": .string(workspace.id),
            "query": .string("hello"),
            "include": .string("*.md"),
        ])
        XCTAssertEqual(missed.result?.objectValue?["matches"]?.arrayValue?.count, 0)
    }

    func testUnknownWorktreeIsTyped() async throws {
        let (server, _, _) = try makeFolderWorkspace()
        let response = await call(server, "file-stat", ["worktree": .string("nope")])
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error?.code)
    }
}
