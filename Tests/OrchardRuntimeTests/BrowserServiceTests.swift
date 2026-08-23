import XCTest
@testable import OrchardRuntime
import OrchardProtocol

/// Workspace/tab model semantics of `BrowserService`: per-workspace containers,
/// active-tab tracking, host delegation, and the typed error vocabulary.
final class BrowserServiceTests: XCTestCase {
    private let wsA = "/tmp/ws-a"
    private let wsB = "/tmp/ws-b"

    private func makeService(host: FakeBrowserHost,
                             resolver: BrowserService.WorkspaceResolver? = nil) async -> BrowserService {
        let service = BrowserService(resolver: resolver)
        await service.attach(host: host)
        return service
    }

    func testVerbsWithoutHostFailTyped() async throws {
        let service = BrowserService()
        await expectBrowserError("browser_unavailable") {
            try await service.goto(workspace: self.wsA, url: "https://x.test")
        }
        await expectBrowserError("browser_unavailable") {
            try await service.createTab(workspace: self.wsA)
        }
    }

    func testGotoCreatesWorkspaceAndPageThenReusesActiveTab() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)

        let page = try await service.goto(workspace: wsA, url: "https://one.test")
        XCTAssertEqual(host.createdPages.count, 1)
        XCTAssertEqual(host.createdPages[0].workspace, wsA)
        XCTAssertEqual(host.navigations.last?.url, "https://one.test")

        let model = await service.workspaceModel(forKey: wsA)
        XCTAssertEqual(model?.pageIds, [page.id])
        XCTAssertEqual(model?.activePageId, page.id)

        _ = try await service.goto(workspace: wsA, url: "https://two.test")
        XCTAssertEqual(host.createdPages.count, 1, "second goto navigates the active tab")
        XCTAssertEqual(host.navigations.last?.url, "https://two.test")
    }

    func testSchemeLessURLsDefaultToHTTPS() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)
        _ = try await service.goto(workspace: wsA, url: "example.com/docs")
        XCTAssertEqual(host.navigations.last?.url, "https://example.com/docs")

        await expectBrowserError("invalid_argument") {
            try await service.goto(workspace: self.wsA, url: "   ")
        }
    }

    func testHistoryVerbsRequireATab() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)
        await expectBrowserError("browser_no_tab") {
            try await service.goBack(workspace: self.wsA)
        }
        await expectBrowserError("browser_tab_not_found") {
            try await service.reload(workspace: self.wsA, page: "pg_missing")
        }
    }

    func testTabCreateSwitchCloseLifecycle() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)

        let first = try await service.goto(workspace: wsA, url: "https://one.test")
        let second = try await service.createTab(workspace: wsA, url: "https://two.test")
        XCTAssertNotEqual(first.id, second.id)

        var model = await service.workspaceModel(forKey: wsA)
        XCTAssertEqual(model?.pageIds, [first.id, second.id])
        XCTAssertEqual(model?.activePageId, second.id, "new tab becomes active")

        _ = try await service.switchTab(workspace: wsA, page: first.id)
        model = await service.workspaceModel(forKey: wsA)
        XCTAssertEqual(model?.activePageId, first.id)
        XCTAssertEqual(host.shownPages.last, first.id)

        await expectBrowserError("browser_tab_not_found") {
            try await service.switchTab(workspace: self.wsA, page: "pg_missing")
        }

        try await service.closeTab(workspace: wsA)  // closes active = first
        XCTAssertEqual(host.closedPages, [first.id])
        model = await service.workspaceModel(forKey: wsA)
        XCTAssertEqual(model?.pageIds, [second.id])
        XCTAssertEqual(model?.activePageId, second.id, "surviving tab takes over")

        try await service.closeTab(workspace: wsA)
        await expectBrowserError("browser_no_tab") {
            try await service.goBack(workspace: self.wsA)
        }
    }

    func testWorkspacesAreIsolated() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)
        let a = try await service.goto(workspace: wsA, url: "https://a.test")
        let b = try await service.goto(workspace: wsB, url: "https://b.test")

        let listA = await service.listTabs(workspace: wsA)
        let listB = await service.listTabs(workspace: wsB)
        XCTAssertEqual(listA.pages.map(\.id), [a.id])
        XCTAssertEqual(listB.pages.map(\.id), [b.id])

        // Snapshot in A must not satisfy a click in B.
        _ = try await service.snapshot(workspace: wsA)
        await expectBrowserError("browser_stale_ref") {
            try await service.click(workspace: self.wsB, ref: "@e1")
        }
    }

    func testResolverCanonicalizesSelectors() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host, resolver: { selector in
            selector == "feature-x" ? "/repo/worktrees/feature-x" : nil
        })
        _ = try await service.goto(workspace: "feature-x", url: "https://x.test")
        // The name selector and the canonical path address the same workspace.
        let byPath = await service.listTabs(workspace: "/repo/worktrees/feature-x")
        XCTAssertEqual(byPath.pages.count, 1)
        XCTAssertEqual(host.createdPages[0].workspace, "/repo/worktrees/feature-x")

        // Unresolvable selectors fall back to the raw string.
        _ = try await service.goto(workspace: "/elsewhere", url: "https://y.test")
        XCTAssertEqual(host.createdPages[1].workspace, "/elsewhere")
    }

    @MainActor
    func testResolverMapsPathSelectorToProjectedPrimaryCheckout() async throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-browser-primary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.appendingPathComponent("checkout")
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
        try "x\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "init"])

        let workspaces = WorkspaceService(
            dataURL: tmp.appendingPathComponent("orchard-data.json"),
            worktreesRoot: tmp.appendingPathComponent("wt"))
        _ = try workspaces.addRepo(path: repo)
        let host = FakeBrowserHost()
        let service = await makeService(host: host, resolver: { selector in
            await MainActor.run { (try? workspaces.show(selector: selector))?.path }
        })
        _ = try await service.goto(workspace: "path:\(repo.path)", url: "https://x.test")
        XCTAssertEqual(host.createdPages[0].workspace, repo.standardizedFileURL.path)
        let byName = await service.listTabs(workspace: "name:checkout")
        XCTAssertEqual(byName.pages.count, 1)
    }

    func testFailedPageCreationLeavesNoPhantomTab() async throws {
        let host = FakeBrowserHost()
        host.createError = BrowserError("host_boom", "web view exploded")
        let service = await makeService(host: host)
        await expectBrowserError("host_boom") {
            try await service.goto(workspace: self.wsA, url: "https://x.test")
        }
        let model = await service.workspaceModel(forKey: wsA)
        XCTAssertTrue(model?.pageIds.isEmpty ?? true)
    }

    func testPageStateRefreshAndHostPush() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)
        let page = try await service.goto(workspace: wsA, url: "https://x.test")

        host.states[page.id] = BrowserPageState(url: "https://x.test/landed", title: "Landed",
                                                isLoading: false, canGoBack: true,
                                                canGoForward: false)
        let listed = await service.listTabs(workspace: wsA)
        XCTAssertEqual(listed.pages.first?.title, "Landed")
        XCTAssertEqual(listed.pages.first?.canGoBack, true)

        await service.pageDidUpdate(pageId: page.id,
                                    state: BrowserPageState(title: "Pushed", isLoading: true))
        let after = await service.listTabs(workspace: wsA)
        XCTAssertEqual(after.pages.first?.canGoBack, true, "pull path still wins on merge")
    }

    func testScreenshotWritesTempFileAndReturnsPath() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)
        _ = try await service.goto(workspace: wsA, url: "https://x.test")

        let shot = try await service.screenshot(workspace: wsA)
        defer { try? FileManager.default.removeItem(atPath: shot.path) }
        XCTAssertTrue(shot.path.hasSuffix(".png"))
        XCTAssertEqual(shot.byteCount, host.screenshotData.count)
        let written = FileManager.default.contents(atPath: shot.path)
        XCTAssertEqual(written, host.screenshotData)
    }

    func testConsoleAppliesLimitFromTheTail() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)
        let page = try await service.goto(workspace: wsA, url: "https://x.test")
        host.consoleLog[page.id] = (1...5).map {
            BrowserConsoleEntry(sequence: $0, level: "log", text: "line \($0)")
        }
        let all = try await service.console(workspace: wsA)
        XCTAssertEqual(all.count, 5)
        let tail = try await service.console(workspace: wsA, limit: 2)
        XCTAssertEqual(tail.map(\.sequence), [4, 5], "limit keeps the newest entries")
    }

    func testEvalReturnsJSONValueAndFailsTyped() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)
        _ = try await service.goto(workspace: wsA, url: "https://x.test")

        host.evalResult = #"{"ok":true,"value":{"n":3,"list":[1,2]}}"#
        let value = try await service.eval(workspace: wsA, expression: "({n:3,list:[1,2]})")
        XCTAssertEqual(value.objectValue?["n"]?.numberValue, 3)
        XCTAssertEqual(value.objectValue?["list"]?.arrayValue?.count, 2)

        host.evalResult = #"{"ok":false,"error":"ReferenceError: nope"}"#
        await expectBrowserError("browser_eval_failed") {
            try await service.eval(workspace: self.wsA, expression: "nope")
        }
    }
}
