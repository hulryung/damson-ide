import Foundation

/// One embedded browser tab. `id` is runtime-minted (`pg_…`) and stable for the
/// page's lifetime; url/title/loading mirror the live web view via host callbacks
/// and on-demand state refreshes.
public struct BrowserPage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var url: String?
    public var title: String
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var loadError: String?

    public init(id: String, url: String? = nil, title: String = "New Tab",
                isLoading: Bool = false, canGoBack: Bool = false,
                canGoForward: Bool = false, loadError: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.loadError = loadError
    }
}

/// Per-workspace browser state (inventory §4): the outer container holding that
/// workspace's tabs. Keyed by the worktree path so the app pane and the CLI
/// (`--worktree <selector>` resolved through the workspace registry) agree on
/// identity without the browser layer owning selector semantics.
public struct BrowserWorkspace: Codable, Equatable, Sendable {
    public var key: String
    public var pageIds: [String]
    public var activePageId: String?

    public init(key: String, pageIds: [String] = [], activePageId: String? = nil) {
        self.key = key
        self.pageIds = pageIds
        self.activePageId = activePageId
    }
}

/// One browser session profile (T21, inventory §4): one profile ⇒ one
/// `WKWebsiteDataStore`, so cookies/localStorage are partitioned per profile.
/// `default` scope means the shared default store; `isolated` means a persistent
/// store keyed by the profile id. Persisted in orchard-data.json; the built-in
/// default profile is synthesized, never stored.
public struct BrowserProfile: Codable, Equatable, Sendable, Identifiable {
    public enum Scope: String, Codable, Sendable {
        case `default`, isolated
    }

    public var id: String
    public var label: String
    public var scope: Scope

    public init(id: String, label: String, scope: Scope) {
        self.id = id
        self.label = label
        self.scope = scope
    }

    /// The always-present profile backed by the shared default data store.
    /// Workspaces with no persisted binding use it.
    public static let defaultProfile = BrowserProfile(id: "default", label: "Default",
                                                      scope: .default)
}

/// Live web-view facts the host reports back to the service. Kept separate from
/// `BrowserPage` so the host never mutates service state directly.
public struct BrowserPageState: Codable, Equatable, Sendable {
    public var url: String?
    public var title: String?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var loadError: String?

    public init(url: String? = nil, title: String? = nil, isLoading: Bool = false,
                canGoBack: Bool = false, canGoForward: Bool = false,
                loadError: String? = nil) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.loadError = loadError
    }
}

/// One captured console message. `sequence` is per-page monotonic so `browser
/// console` output is ordered even when levels interleave.
public struct BrowserConsoleEntry: Codable, Equatable, Sendable {
    public var sequence: Int
    public var level: String
    public var text: String

    public init(sequence: Int, level: String, text: String) {
        self.sequence = sequence
        self.level = level
        self.text = text
    }
}

/// One interactive element surfaced by a snapshot: `@eN` in the outline. `index`
/// addresses `window.__orchardRefs.els[index]` in the page; role/name are kept so
/// stale-ref errors can say what the ref used to point at. `frame` is the owning
/// frame's id from the walker ("" = main frame, "f1"… = same-origin subframes) —
/// refs stay unique per page across frames because the counter spans the whole
/// traversal.
public struct BrowserSnapshotRef: Codable, Equatable, Sendable {
    public var ref: String
    public var index: Int
    public var role: String
    public var name: String
    public var frame: String

    public init(ref: String, index: Int, role: String, name: String, frame: String = "") {
        self.ref = ref
        self.index = index
        self.role = role
        self.name = name
        self.frame = frame
    }
}

/// The stored result of the latest snapshot of one page. Refs resolve only
/// against this generation: any navigation clears it, so an agent must
/// re-snapshot before interacting again (inventory §4 — errors, not guesses).
public struct BrowserPageSnapshot: Codable, Equatable, Sendable {
    /// Monotonic per page; embedded in the page-side element registry so an
    /// action script can detect it is running against a newer/older world.
    public var epoch: Int
    public var outline: String
    public var refs: [String: BrowserSnapshotRef]

    public init(epoch: Int, outline: String, refs: [String: BrowserSnapshotRef]) {
        self.epoch = epoch
        self.outline = outline
        self.refs = refs
    }
}

/// Typed browser failures; codes match the inventory (§4) vocabulary so agent
/// tooling can branch on them.
public struct BrowserError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public static func noTab(_ workspace: String) -> BrowserError {
        BrowserError("browser_no_tab", "workspace '\(workspace)' has no browser tab; run `browser goto` first")
    }

    public static func tabNotFound(_ pageId: String) -> BrowserError {
        BrowserError("browser_tab_not_found", "no browser tab '\(pageId)'")
    }

    public static func staleRef(_ detail: String) -> BrowserError {
        BrowserError("browser_stale_ref", detail + " — take a fresh `browser snapshot` and retry")
    }

    public static func unavailable() -> BrowserError {
        BrowserError("browser_unavailable", "no browser host attached; the Orchard app must be running")
    }

    public static func profileNotFound(_ selector: String) -> BrowserError {
        BrowserError("browser_profile_not_found",
                     "no browser profile '\(selector)'; see `browser tab profile list`")
    }

    public static func profileExists(_ label: String) -> BrowserError {
        BrowserError("browser_profile_exists", "a browser profile labeled '\(label)' already exists")
    }
}
