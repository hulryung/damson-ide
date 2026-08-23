import XCTest
@testable import OrchardRuntime

/// Snapshot ref bookkeeping — the invariant under test everywhere: refs belong
/// to the latest snapshot of a page and every navigation kills them (errors,
/// not guesses). All WKWebView-free via `FakeBrowserHost`.
final class BrowserSnapshotTests: XCTestCase {
    private let ws = "/tmp/ws-a"

    private func bootedService(host: FakeBrowserHost) async throws -> BrowserService {
        let service = BrowserService()
        await service.attach(host: host)
        _ = try await service.goto(workspace: ws, url: "https://fake.test/")
        return service
    }

    // MARK: - Outline building (pure)

    func testOutlineAssignsRefsToInteractiveElementsOnly() throws {
        let payload = try JSONDecoder().decode(
            BrowserWalkerPayload.self, from: Data(FakeBrowserHost.defaultPayload.utf8))
        let snap = BrowserSnapshotOutline.build(payload: payload, epoch: 3)

        XCTAssertEqual(snap.epoch, 3)
        XCTAssertEqual(snap.refs.count, 3)
        XCTAssertEqual(snap.refs["@e1"]?.role, "link")
        XCTAssertEqual(snap.refs["@e1"]?.index, 0)
        XCTAssertEqual(snap.refs["@e2"]?.name, "Search")
        XCTAssertEqual(snap.refs["@e3"]?.index, 2)
        XCTAssertNil(snap.refs["@e4"])

        XCTAssertTrue(snap.outline.contains("Page: Fake Page"))
        XCTAssertTrue(snap.outline.contains("URL: https://fake.test/"))
        XCTAssertTrue(snap.outline.contains(#"- heading "Welcome""#))
        XCTAssertFalse(snap.outline.contains("Welcome\" [@e"), "headings are not interactive")
        XCTAssertTrue(snap.outline.contains(#"- link "Docs" [@e1]"#))
        XCTAssertTrue(snap.outline.contains(#"- textbox "Search" (value: prefilled) [@e2]"#))
    }

    func testOutlineDisambiguatesDuplicateNamesAndIndentsByDepth() throws {
        let json = """
            {"title":"T","url":"u","truncated":true,"nodes":[
              {"d":0,"role":"list","name":"","value":"","i":-1},
              {"d":1,"role":"button","name":"Submit","value":"","i":0},
              {"d":1,"role":"button","name":"Submit","value":"","i":1},
              {"d":1,"role":"text","name":"plain words","value":"","i":-1}
            ]}
            """
        let payload = try JSONDecoder().decode(BrowserWalkerPayload.self, from: Data(json.utf8))
        let snap = BrowserSnapshotOutline.build(payload: payload, epoch: 1)

        XCTAssertTrue(snap.outline.contains(#"  - button "Submit" [@e1]"#))
        XCTAssertTrue(snap.outline.contains(#"  - button "Submit (2nd)" [@e2]"#))
        XCTAssertTrue(snap.outline.contains("  plain words"), "text nodes render bare, indented")
        XCTAssertTrue(snap.outline.contains("truncated at node budget"))
        // Both refs still resolve to their own element index despite equal names.
        XCTAssertEqual(snap.refs["@e1"]?.index, 0)
        XCTAssertEqual(snap.refs["@e2"]?.index, 1)
    }

    // MARK: - Ref lifecycle through the service

    func testSnapshotStoresRefsAndClickUsesElementIndex() async throws {
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)

        let result = try await service.snapshot(workspace: ws)
        XCTAssertEqual(result.refCount, 3)
        XCTAssertEqual(result.epoch, 1)
        XCTAssertEqual(result.page.url, "https://fake.test/", "snapshot refreshes page facts")

        try await service.click(workspace: ws, ref: "@e3")
        let clickScript = host.evaluated.last?.script ?? ""
        XCTAssertTrue(clickScript.contains("S.els[2]"), "@e3 resolves to element index 2")
        XCTAssertTrue(clickScript.contains("S.epoch !== 1"), "action pinned to snapshot epoch")
    }

    func testInteractionWithoutSnapshotIsStaleRef() async throws {
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)
        await expectBrowserError("browser_stale_ref") {
            try await service.click(workspace: self.ws, ref: "@e1")
        }
    }

    func testUnknownRefIsStaleRef() async throws {
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)
        _ = try await service.snapshot(workspace: ws)
        await expectBrowserError("browser_stale_ref") {
            try await service.fill(workspace: self.ws, ref: "@e9", text: "x")
        }
    }

    func testNavigationVerbInvalidatesRefs() async throws {
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)
        _ = try await service.snapshot(workspace: ws)

        _ = try await service.goto(workspace: ws, url: "https://fake.test/next")

        let pageId = host.createdPages[0].pageId
        let stored = await service.latestSnapshot(pageId: pageId)
        XCTAssertNil(stored, "navigation clears the stored snapshot")
        await expectBrowserError("browser_stale_ref") {
            try await service.click(workspace: self.ws, ref: "@e1")
        }
    }

    func testBackForwardReloadEachInvalidate() async throws {
        for verb in ["back", "forward", "reload"] {
            let host = FakeBrowserHost()
            let service = try await bootedService(host: host)
            _ = try await service.snapshot(workspace: ws)
            switch verb {
            case "back": _ = try await service.goBack(workspace: ws)
            case "forward": _ = try await service.goForward(workspace: ws)
            default: _ = try await service.reload(workspace: ws)
            }
            await expectBrowserError("browser_stale_ref") {
                try await service.type(workspace: self.ws, ref: "@e2", text: "x")
            }
        }
    }

    func testHostReportedNavigationInvalidatesRefs() async throws {
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)
        _ = try await service.snapshot(workspace: ws)

        // A link click inside the page: the service never asked for it.
        let pageId = host.createdPages[0].pageId
        await service.pageDidCommitNavigation(pageId: pageId, url: "https://fake.test/elsewhere")

        await expectBrowserError("browser_stale_ref") {
            try await service.click(workspace: self.ws, ref: "@e1")
        }
        let summary = await service.listTabs(workspace: ws)
        XCTAssertEqual(summary.pages.first?.url, "https://fake.test/elsewhere")
    }

    func testResnapshotBumpsEpochAndRevivesInteraction() async throws {
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)
        let first = try await service.snapshot(workspace: ws)
        _ = try await service.goto(workspace: ws, url: "https://fake.test/2")
        let second = try await service.snapshot(workspace: ws)

        XCTAssertGreaterThan(second.epoch, first.epoch)
        try await service.click(workspace: ws, ref: "@e1")
        let script = host.evaluated.last?.script ?? ""
        XCTAssertTrue(script.contains("S.epoch !== \(second.epoch)"))
    }

    func testPageSideStaleDetectionMapsToStaleRef() async throws {
        // Service-side state says the snapshot is live, but the page's world
        // moved on (e.g. a JS pushState swap) — the script's own epoch check is
        // the second line of defense.
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)
        _ = try await service.snapshot(workspace: ws)
        host.actionResult = #"{"ok":false,"error":"stale"}"#
        await expectBrowserError("browser_stale_ref") {
            try await service.click(workspace: self.ws, ref: "@e1")
        }
    }

    func testTypeWithoutRefNeedsNoSnapshotAndTargetsFocus() async throws {
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)
        try await service.type(workspace: ws, text: "hello")
        let script = host.evaluated.last?.script ?? ""
        XCTAssertTrue(script.contains("document.activeElement"))
        XCTAssertFalse(script.contains("__orchardRefs"), "focus typing skips the ref table")
    }

    func testFillEscapesTextIntoScriptLiteral() async throws {
        let host = FakeBrowserHost()
        let service = try await bootedService(host: host)
        _ = try await service.snapshot(workspace: ws)
        try await service.fill(workspace: ws, ref: "@e2",
                               text: "a\"b\\c\nd</script>")
        let script = host.evaluated.last?.script ?? ""
        XCTAssertTrue(script.contains(#"var v = "a\"b\\c\nd</script>";"#),
                      "CLI text reaches the page only as an escaped JS literal")
    }
}
