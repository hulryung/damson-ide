import Foundation
import XCTest
@testable import OrchardRuntime

/// Scripted `BrowserWebHost` — the WKWebView stand-in that makes ref
/// bookkeeping and invalidation testable headlessly. Distinguishes the three
/// script families by their distinctive source fragments (snapshot registers
/// `window.__orchardRefs = { epoch:` …, eval wraps `eval(`), the same strings a
/// real page would receive.
final class FakeBrowserHost: BrowserWebHost, @unchecked Sendable {
    private let lock = NSLock()

    private var _createdPages: [(workspace: String, pageId: String, profile: BrowserProfile)] = []
    private var _closedPages: [String] = []
    private var _shownPages: [String] = []
    private var _navigations: [(pageId: String, url: String)] = []
    private var _historyCalls: [(pageId: String, op: String)] = []
    private var _evaluated: [(pageId: String, script: String)] = []

    var snapshotPayload = FakeBrowserHost.defaultPayload
    var actionResult = #"{"ok":true}"#
    var evalResult = #"{"ok":true,"value":null}"#
    var states: [String: BrowserPageState] = [:]
    var screenshotData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    var consoleLog: [String: [BrowserConsoleEntry]] = [:]
    var createError: BrowserError?

    static let defaultPayload = """
        {"title":"Fake Page","url":"https://fake.test/","truncated":false,"nodes":[
          {"d":0,"role":"heading","name":"Welcome","value":"","i":-1},
          {"d":0,"role":"link","name":"Docs","value":"","i":0},
          {"d":0,"role":"textbox","name":"Search","value":"prefilled","i":1},
          {"d":0,"role":"button","name":"Go","value":"","i":2}
        ]}
        """

    var createdPages: [(workspace: String, pageId: String, profile: BrowserProfile)] { lock.withLock { _createdPages } }
    var closedPages: [String] { lock.withLock { _closedPages } }
    var shownPages: [String] { lock.withLock { _shownPages } }
    var navigations: [(pageId: String, url: String)] { lock.withLock { _navigations } }
    var historyCalls: [(pageId: String, op: String)] { lock.withLock { _historyCalls } }
    var evaluated: [(pageId: String, script: String)] { lock.withLock { _evaluated } }

    func createPage(workspace: String, pageId: String, profile: BrowserProfile) async throws {
        if let createError { throw createError }
        lock.withLock { _createdPages.append((workspace, pageId, profile)) }
    }

    func closePage(pageId: String) async {
        lock.withLock { _closedPages.append(pageId) }
    }

    func showPage(pageId: String) async {
        lock.withLock { _shownPages.append(pageId) }
    }

    func navigate(pageId: String, url: URL) async throws {
        lock.withLock { _navigations.append((pageId, url.absoluteString)) }
    }

    func goBack(pageId: String) async throws {
        lock.withLock { _historyCalls.append((pageId, "back")) }
    }

    func goForward(pageId: String) async throws {
        lock.withLock { _historyCalls.append((pageId, "forward")) }
    }

    func reload(pageId: String) async throws {
        lock.withLock { _historyCalls.append((pageId, "reload")) }
    }

    func evaluateJavaScript(pageId: String, script: String) async throws -> String {
        lock.withLock { _evaluated.append((pageId, script)) }
        if script.contains("window.__orchardRefs = { epoch:") { return snapshotPayload }
        if script.contains("var r = eval(") { return evalResult }
        return actionResult
    }

    func pageState(pageId: String) async throws -> BrowserPageState {
        states[pageId] ?? BrowserPageState()
    }

    func takeScreenshot(pageId: String) async throws -> Data {
        screenshotData
    }

    func consoleEntries(pageId: String) async throws -> [BrowserConsoleEntry] {
        consoleLog[pageId] ?? []
    }
}

/// Shared assertion: an async call fails with the given browser error code.
func expectBrowserError<T>(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                           _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected \(code), got success", file: file, line: line)
    } catch let err as BrowserError {
        XCTAssertEqual(err.code, code, file: file, line: line)
    } catch {
        XCTFail("expected \(code), got \(error)", file: file, line: line)
    }
}
