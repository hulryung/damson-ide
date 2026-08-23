import AppKit
import Combine
import Foundation
import OrchardRuntime
import WebKit

/// One embedded browser tab: owns its `WKWebView` and mirrors the web view's
/// facts into published state for SwiftUI. Created offscreen when a CLI verb
/// targets a workspace whose pane isn't open — the view is adopted into the
/// hierarchy later without reloading.
///
/// Everything read out of the page (titles, console text, script results) is
/// untrusted data: it is displayed or returned to callers, never executed.
@MainActor
final class BrowserTabModel: NSObject, ObservableObject, Identifiable {
    nonisolated let id: String
    let webView: WKWebView

    @Published private(set) var urlString: String = ""
    @Published private(set) var title: String = "New Tab"
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loadError: String?
    @Published private(set) var progress: Double = 0

    /// Reported to the runtime service so user-driven navigations (link clicks,
    /// JS redirects) invalidate snapshot refs exactly like verb-driven ones.
    var onCommit: ((String, String?) -> Void)?
    var onStateChange: ((String, BrowserPageState) -> Void)?

    private var consoleBuffer: [BrowserConsoleEntry] = []
    private var consoleSequence = 0
    private static let consoleCap = 500
    private var observers: [NSKeyValueObservation] = []

    init(id: String) {
        self.id = id
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserScripts.consoleCapture,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                 configuration: configuration)
        super.init()

        // The content controller retains its handlers; go through a weak proxy
        // so tab → configuration → handler → tab doesn't leak the web view.
        configuration.userContentController.add(WeakScriptMessageHandler(self),
                                                name: "orchardConsole")
        webView.navigationDelegate = self
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        observe()
    }

    deinit {
        observers.forEach { $0.invalidate() }
    }

    // MARK: - Facts

    var pageState: BrowserPageState {
        BrowserPageState(url: webView.url?.absoluteString,
                         title: webView.title,
                         isLoading: webView.isLoading,
                         canGoBack: webView.canGoBack,
                         canGoForward: webView.canGoForward,
                         loadError: loadError)
    }

    var consoleEntries: [BrowserConsoleEntry] { consoleBuffer }

    // MARK: - Operations (driven by the runtime service via BrowserManager)

    func load(_ url: URL) {
        loadError = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let text = result as? String {
                    continuation.resume(returning: text)
                } else {
                    // Our injected scripts always return a JSON string; anything
                    // else means the page replaced the world mid-flight.
                    continuation.resume(returning: #"{"ok":false,"error":"no result"}"#)
                }
            }
        }
    }

    func takeScreenshot() async throws -> Data {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? BrowserError(
                        "browser_screenshot_failed", "web view produced no image"))
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserError("browser_screenshot_failed", "could not encode PNG")
        }
        return png
    }

    func tearDown() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "orchardConsole")
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: - Mirroring

    private func observe() {
        observers = [
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in
                Task { @MainActor in self?.progress = self?.webView.estimatedProgress ?? 0 }
            },
        ]
    }

    private func sync() {
        urlString = webView.url?.absoluteString ?? urlString
        title = (webView.title?.isEmpty == false ? webView.title : nil) ?? title
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        onStateChange?(id, pageState)
    }

    fileprivate func appendConsole(level: String, text: String) {
        consoleSequence += 1
        consoleBuffer.append(BrowserConsoleEntry(sequence: consoleSequence,
                                                 level: level, text: text))
        if consoleBuffer.count > Self.consoleCap {
            consoleBuffer.removeFirst(consoleBuffer.count - Self.consoleCap)
        }
    }
}

extension BrowserTabModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loadError = nil
        onCommit?(id, webView.url?.absoluteString)
        sync()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = error.localizedDescription
        sync()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        loadError = error.localizedDescription
        sync()
    }
}

extension BrowserTabModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "orchardConsole",
              let body = message.body as? [String: Any] else { return }
        let level = (body["level"] as? String) ?? "log"
        let text = (body["text"] as? String) ?? ""
        appendConsole(level: level, text: text)
    }
}

/// Breaks the WKUserContentController retain cycle on its message handlers.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (NSObject & WKScriptMessageHandler)?

    init(_ target: NSObject & WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
