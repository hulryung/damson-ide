import Foundation

/// The seam between the browser service and WebKit. The app implements this over
/// per-workspace `WKWebView`s; tests implement it with scripted fakes — which is
/// what keeps ref bookkeeping and invalidation unit-testable without a web view
/// (and keeps `import WebKit` out of OrchardRuntime entirely).
///
/// All page addressing is by the service-minted page id. Hosts report navigation
/// back through `BrowserService.pageDidCommitNavigation` so user-initiated
/// navigations (link clicks, JS redirects) invalidate snapshots exactly like
/// service-driven ones.
public protocol BrowserWebHost: AnyObject, Sendable {
    /// Create the backing web view for a new page (offscreen if the pane for
    /// `workspace` is not open — CLI verbs must work before any UI exists).
    /// `profile` is the workspace's bound session profile: the host derives the
    /// web view's website data store from it (default scope ⇒ the shared default
    /// store; isolated ⇒ a persistent store keyed by the profile id).
    func createPage(workspace: String, pageId: String, profile: BrowserProfile) async throws
    func closePage(pageId: String) async
    /// Make the page the visibly selected tab if its pane is showing.
    func showPage(pageId: String) async

    func navigate(pageId: String, url: URL) async throws
    func goBack(pageId: String) async throws
    func goForward(pageId: String) async throws
    func reload(pageId: String) async throws

    /// Run a script in the page and return its string result. Every script the
    /// service sends returns a JSON string, so the host never interprets page
    /// content — it only ferries opaque text back (untrusted data).
    func evaluateJavaScript(pageId: String, script: String) async throws -> String

    func pageState(pageId: String) async throws -> BrowserPageState
    /// PNG bytes of the current viewport.
    func takeScreenshot(pageId: String) async throws -> Data
    func consoleEntries(pageId: String) async throws -> [BrowserConsoleEntry]
}
