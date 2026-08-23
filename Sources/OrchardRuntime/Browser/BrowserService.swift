import Foundation
import OrchardProtocol

/// Snapshot + page facts returned by the snapshot verb.
public struct BrowserSnapshotResult: Sendable {
    public var page: BrowserPage
    public var outline: String
    public var refCount: Int
    public var epoch: Int
}

/// Where a screenshot landed. The file lives in the temp directory: callers copy
/// it out if they want it to survive.
public struct BrowserScreenshotResult: Sendable {
    public var page: BrowserPage
    public var path: String
    public var byteCount: Int
}

/// One workspace's tabs as reported by `browser tab list`.
public struct BrowserWorkspaceSummary: Sendable {
    public var key: String
    public var activePageId: String?
    public var pages: [BrowserPage]
}

/// Per-workspace embedded-browser state machine (inventory §4). Owns the
/// `BrowserWorkspace`/`BrowserPage` model and the per-page `@eN` ref tables;
/// delegates everything that needs a real web view to the attached
/// `BrowserWebHost`. An actor so RPC handlers and MainActor host callbacks can
/// call in without a shared-state race.
///
/// Ref lifecycle rule: refs belong to the *latest* snapshot of a page and are
/// invalidated by every navigation (verb-driven or user-driven via
/// `pageDidCommitNavigation`). Interactions against anything else fail with
/// `browser_stale_ref` — errors, not guesses.
public actor BrowserService {
    /// Maps a CLI `--worktree` selector to a canonical workspace key (the
    /// worktree path). nil / resolution failure falls back to the raw selector
    /// so the browser works for paths that were never registered as worktrees.
    public typealias WorkspaceResolver = @Sendable (String) async -> String?

    private struct PageRecord {
        var page: BrowserPage
        var workspaceKey: String
        var snapshot: BrowserPageSnapshot?
        var epochCounter = 0
    }

    // Weak: the app-side host owns web views and observes this service; the
    // service must not keep the app's view layer alive.
    private weak var host: (any BrowserWebHost)?
    private let resolver: WorkspaceResolver?
    private var workspaces: [String: BrowserWorkspace] = [:]
    private var pages: [String: PageRecord] = [:]

    public init(resolver: WorkspaceResolver? = nil) {
        self.resolver = resolver
    }

    public func attach(host: any BrowserWebHost) {
        self.host = host
    }

    // MARK: - Navigation verbs

    @discardableResult
    public func goto(workspace selector: String, page pageId: String? = nil,
                     url raw: String) async throws -> BrowserPage {
        let host = try requireHost()
        let url = try Self.normalizeURL(raw)
        let key = await resolveKey(selector)
        let id: String
        if let pageId {
            guard workspaces[key]?.pageIds.contains(pageId) == true else {
                throw BrowserError.tabNotFound(pageId)
            }
            id = pageId
        } else if let active = workspaces[key]?.activePageId {
            id = active
        } else {
            id = try await createPage(key: key)
        }
        beginNavigation(pageId: id, url: url.absoluteString)
        try await host.navigate(pageId: id, url: url)
        return await refreshedPage(id)
    }

    @discardableResult
    public func goBack(workspace: String, page: String? = nil) async throws -> BrowserPage {
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        beginNavigation(pageId: id, url: nil)
        try await host.goBack(pageId: id)
        return await refreshedPage(id)
    }

    @discardableResult
    public func goForward(workspace: String, page: String? = nil) async throws -> BrowserPage {
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        beginNavigation(pageId: id, url: nil)
        try await host.goForward(pageId: id)
        return await refreshedPage(id)
    }

    @discardableResult
    public func reload(workspace: String, page: String? = nil) async throws -> BrowserPage {
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        beginNavigation(pageId: id, url: nil)
        try await host.reload(pageId: id)
        return await refreshedPage(id)
    }

    // MARK: - Snapshot + interaction

    public func snapshot(workspace: String, page: String? = nil) async throws -> BrowserSnapshotResult {
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        let epoch = (pages[id]?.epochCounter ?? 0) + 1
        let raw = try await host.evaluateJavaScript(pageId: id,
                                                    script: BrowserScripts.snapshot(epoch: epoch))
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrowserWalkerPayload.self, from: data) else {
            throw BrowserError("browser_snapshot_failed",
                               "snapshot script returned an unreadable payload")
        }
        let snapshot = BrowserSnapshotOutline.build(payload: payload, epoch: epoch)
        guard var record = pages[id] else { throw BrowserError.tabNotFound(id) }
        record.epochCounter = epoch
        record.snapshot = snapshot
        record.page.url = payload.url
        record.page.title = payload.title.isEmpty ? record.page.title : payload.title
        pages[id] = record
        return BrowserSnapshotResult(page: record.page, outline: snapshot.outline,
                                     refCount: snapshot.refs.count, epoch: epoch)
    }

    public func click(workspace: String, page: String? = nil, ref: String) async throws {
        let (host, id, snap, entry) = try await resolveRef(workspace: workspace, page: page, ref: ref)
        let out = try await host.evaluateJavaScript(
            pageId: id, script: BrowserScripts.click(epoch: snap.epoch, index: entry.index))
        try Self.checkActionOutcome(out, ref: ref)
    }

    public func fill(workspace: String, page: String? = nil, ref: String,
                     text: String) async throws {
        let (host, id, snap, entry) = try await resolveRef(workspace: workspace, page: page, ref: ref)
        let out = try await host.evaluateJavaScript(
            pageId: id, script: BrowserScripts.fill(epoch: snap.epoch, index: entry.index, text: text))
        try Self.checkActionOutcome(out, ref: ref)
    }

    /// With a ref: focus that element and append. Without: type into whatever
    /// currently has focus (no snapshot required).
    public func type(workspace: String, page: String? = nil, ref: String? = nil,
                     text: String) async throws {
        if let ref {
            let (host, id, snap, entry) = try await resolveRef(workspace: workspace, page: page, ref: ref)
            let out = try await host.evaluateJavaScript(
                pageId: id, script: BrowserScripts.type(epoch: snap.epoch, index: entry.index, text: text))
            try Self.checkActionOutcome(out, ref: ref)
            return
        }
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        let out = try await host.evaluateJavaScript(
            pageId: id, script: BrowserScripts.type(epoch: 0, index: -1, text: text))
        try Self.checkActionOutcome(out, ref: nil)
    }

    // MARK: - Read verbs

    public func screenshot(workspace: String, page: String? = nil,
                           fileManager: FileManager = .default) async throws -> BrowserScreenshotResult {
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        let data = try await host.takeScreenshot(pageId: id)
        let dir = fileManager.temporaryDirectory.appendingPathComponent("orchard-browser",
                                                                        isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let file = dir.appendingPathComponent("\(id)-\(stamp).png")
        try data.write(to: file, options: .atomic)
        let page = await refreshedPage(id)
        return BrowserScreenshotResult(page: page, path: file.path, byteCount: data.count)
    }

    /// Evaluate an expression in the page and return its JSON-encoded value.
    /// The result is page-controlled text: callers must treat it as untrusted
    /// data, never as something to execute.
    public func eval(workspace: String, page: String? = nil,
                     expression: String) async throws -> JSONValue {
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        let raw = try await host.evaluateJavaScript(pageId: id,
                                                    script: BrowserScripts.eval(expression: expression))
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            throw BrowserError("browser_eval_failed", "eval returned an unreadable payload")
        }
        if object["ok"]?.boolValue == true {
            return object["value"] ?? .null
        }
        throw BrowserError("browser_eval_failed",
                           object["error"]?.stringValue ?? "eval failed in page")
    }

    public func console(workspace: String, page: String? = nil,
                        limit: Int? = nil) async throws -> [BrowserConsoleEntry] {
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        let entries = try await host.consoleEntries(pageId: id)
        if let limit, limit >= 0, entries.count > limit {
            return Array(entries.suffix(limit))
        }
        return entries
    }

    // MARK: - Tabs

    public func listTabs(workspace selector: String) async -> BrowserWorkspaceSummary {
        let key = await resolveKey(selector)
        guard let ws = workspaces[key] else {
            return BrowserWorkspaceSummary(key: key, activePageId: nil, pages: [])
        }
        var out: [BrowserPage] = []
        for id in ws.pageIds {
            out.append(await refreshedPage(id))
        }
        return BrowserWorkspaceSummary(key: key, activePageId: ws.activePageId, pages: out)
    }

    @discardableResult
    public func createTab(workspace selector: String, url: String? = nil) async throws -> BrowserPage {
        _ = try requireHost()
        let key = await resolveKey(selector)
        let id = try await createPage(key: key)
        setActive(key: key, pageId: id)
        await host?.showPage(pageId: id)
        if let url {
            return try await goto(workspace: key, page: id, url: url)
        }
        return await refreshedPage(id)
    }

    public func closeTab(workspace selector: String, page: String? = nil) async throws {
        let id = try await resolvePage(workspace: selector, page: page)
        guard let record = pages.removeValue(forKey: id) else { return }
        let key = record.workspaceKey
        if var ws = workspaces[key] {
            ws.pageIds.removeAll { $0 == id }
            if ws.activePageId == id {
                ws.activePageId = ws.pageIds.last
            }
            workspaces[key] = ws
            if let next = ws.activePageId {
                await host?.showPage(pageId: next)
            }
        }
        await host?.closePage(pageId: id)
    }

    @discardableResult
    public func switchTab(workspace selector: String, page pageId: String) async throws -> BrowserPage {
        let key = await resolveKey(selector)
        guard workspaces[key]?.pageIds.contains(pageId) == true else {
            throw BrowserError.tabNotFound(pageId)
        }
        setActive(key: key, pageId: pageId)
        await host?.showPage(pageId: pageId)
        return await refreshedPage(pageId)
    }

    // MARK: - Host callbacks

    /// The host reports every committed navigation — including link clicks and
    /// JS redirects the service never asked for — so snapshot refs die with the
    /// document they were taken from.
    public func pageDidCommitNavigation(pageId: String, url: String?) {
        guard var record = pages[pageId] else { return }
        record.snapshot = nil
        if let url { record.page.url = url }
        record.page.isLoading = true
        record.page.loadError = nil
        pages[pageId] = record
    }

    /// Loading/title/history facts pushed by the host as the web view changes.
    public func pageDidUpdate(pageId: String, state: BrowserPageState) {
        guard var record = pages[pageId] else { return }
        record.page = Self.merge(record.page, state: state)
        pages[pageId] = record
    }

    /// Test / diagnostic hook: the latest snapshot's refs for a page (nil after
    /// invalidation).
    public func latestSnapshot(pageId: String) -> BrowserPageSnapshot? {
        pages[pageId]?.snapshot
    }

    public func workspaceModel(forKey key: String) -> BrowserWorkspace? {
        workspaces[key]
    }

    // MARK: - Internals

    private func requireHost() throws -> any BrowserWebHost {
        guard let host else { throw BrowserError.unavailable() }
        return host
    }

    private func resolveKey(_ selector: String) async -> String {
        guard let resolver else { return selector }
        return await resolver(selector) ?? selector
    }

    private func resolvePage(workspace selector: String, page pageId: String?) async throws -> String {
        let key = await resolveKey(selector)
        guard let ws = workspaces[key] else {
            if let pageId { throw BrowserError.tabNotFound(pageId) }
            throw BrowserError.noTab(selector)
        }
        if let pageId {
            guard ws.pageIds.contains(pageId) else { throw BrowserError.tabNotFound(pageId) }
            return pageId
        }
        guard let active = ws.activePageId else { throw BrowserError.noTab(selector) }
        return active
    }

    private func resolveRef(workspace: String, page: String?, ref: String) async throws
        -> (any BrowserWebHost, String, BrowserPageSnapshot, BrowserSnapshotRef) {
        let host = try requireHost()
        let id = try await resolvePage(workspace: workspace, page: page)
        guard let snap = pages[id]?.snapshot else {
            throw BrowserError.staleRef("no live snapshot for this page")
        }
        guard let entry = snap.refs[ref] else {
            throw BrowserError.staleRef("ref '\(ref)' is not in the latest snapshot")
        }
        return (host, id, snap, entry)
    }

    /// Mint the page id and register the model only after the host succeeds, so
    /// a failed web-view creation leaves no phantom tab.
    private func createPage(key: String) async throws -> String {
        let host = try requireHost()
        let id = "pg_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
        try await host.createPage(workspace: key, pageId: id)
        var ws = workspaces[key] ?? BrowserWorkspace(key: key)
        ws.pageIds.append(id)
        if ws.activePageId == nil { ws.activePageId = id }
        workspaces[key] = ws
        pages[id] = PageRecord(page: BrowserPage(id: id), workspaceKey: key)
        return id
    }

    private func setActive(key: String, pageId: String) {
        guard var ws = workspaces[key] else { return }
        ws.activePageId = pageId
        workspaces[key] = ws
    }

    private func beginNavigation(pageId: String, url: String?) {
        guard var record = pages[pageId] else { return }
        record.snapshot = nil
        if let url { record.page.url = url }
        record.page.isLoading = true
        record.page.loadError = nil
        pages[pageId] = record
    }

    private func refreshedPage(_ id: String) async -> BrowserPage {
        if let host, let state = try? await host.pageState(pageId: id) {
            // Re-read after the await: another call may have interleaved.
            if var current = pages[id] {
                current.page = Self.merge(current.page, state: state)
                pages[id] = current
            }
        }
        return pages[id]?.page ?? BrowserPage(id: id)
    }

    private static func merge(_ page: BrowserPage, state: BrowserPageState) -> BrowserPage {
        var page = page
        if let url = state.url { page.url = url }
        if let title = state.title, !title.isEmpty { page.title = title }
        page.isLoading = state.isLoading
        page.canGoBack = state.canGoBack
        page.canGoForward = state.canGoForward
        page.loadError = state.loadError
        return page
    }

    private static func checkActionOutcome(_ raw: String, ref: String?) throws {
        struct Outcome: Decodable { var ok: Bool; var error: String? }
        guard let data = raw.data(using: .utf8),
              let outcome = try? JSONDecoder().decode(Outcome.self, from: data) else {
            throw BrowserError("browser_action_failed", "action script returned an unreadable payload")
        }
        if outcome.ok { return }
        if outcome.error == "stale" {
            let label = ref.map { "ref '\($0)'" } ?? "the target element"
            throw BrowserError.staleRef("the page changed under \(label)")
        }
        throw BrowserError("browser_action_failed", outcome.error ?? "action failed in page")
    }

    /// Scheme-less input is a browser URL bar convention; default it to https.
    static func normalizeURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrowserError("invalid_argument", "missing url")
        }
        let candidate: String
        if trimmed.contains("://") || trimmed.hasPrefix("about:") || trimmed.hasPrefix("data:") {
            candidate = trimmed
        } else {
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate), url.scheme != nil else {
            throw BrowserError("invalid_argument", "not a loadable url: '\(raw)'")
        }
        return url
    }
}
