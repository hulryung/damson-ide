import Foundation
import OrchardProtocol

/// RPC verbs for the embedded browser (`browser goto|back|forward|reload|
/// snapshot|click|fill|type|screenshot|eval|console|tab` in the CLI, hyphenated
/// here to match the envelope convention).
public final class BrowserCommandHandler: CommandHandler, Sendable {
    public let verbs = [
        "browser-goto", "browser-back", "browser-forward", "browser-reload",
        "browser-snapshot", "browser-click", "browser-fill", "browser-type",
        "browser-screenshot", "browser-eval", "browser-console", "browser-tab",
    ]

    private let service: BrowserService

    public init(service: BrowserService) {
        self.service = service
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let err as BrowserError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch {
            return .failure(id: request.id, error: RPCError(code: "internal_error",
                                                            message: String(describing: error)))
        }
    }

    private func dispatch(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params ?? .object([:])
        let workspace = try requiredWorkspace(params)
        let page = params.string("page")

        switch request.method {
        case "browser-goto":
            guard let url = params.string("url") else {
                throw BrowserError("invalid_argument", "browser-goto requires --url")
            }
            return try await pageResult(service.goto(workspace: workspace, page: page, url: url))
        case "browser-back":
            return try await pageResult(service.goBack(workspace: workspace, page: page))
        case "browser-forward":
            return try await pageResult(service.goForward(workspace: workspace, page: page))
        case "browser-reload":
            return try await pageResult(service.reload(workspace: workspace, page: page))
        case "browser-snapshot":
            let snap = try await service.snapshot(workspace: workspace, page: page)
            return try JSONBridge.value(SnapshotResult(page: snap.page, outline: snap.outline,
                                                       refCount: snap.refCount, epoch: snap.epoch))
        case "browser-click":
            let ref = try requiredRef(params)
            try await service.click(workspace: workspace, page: page, ref: ref)
            return try JSONBridge.value(ActionResult(done: true, ref: ref))
        case "browser-fill":
            let ref = try requiredRef(params)
            let text = try requiredText(params, verb: "browser-fill")
            try await service.fill(workspace: workspace, page: page, ref: ref, text: text)
            return try JSONBridge.value(ActionResult(done: true, ref: ref))
        case "browser-type":
            let text = try requiredText(params, verb: "browser-type")
            let ref = params.string("ref")
            try await service.type(workspace: workspace, page: page, ref: ref, text: text)
            return try JSONBridge.value(ActionResult(done: true, ref: ref))
        case "browser-screenshot":
            let shot = try await service.screenshot(workspace: workspace, page: page)
            return try JSONBridge.value(ScreenshotResult(page: shot.page, path: shot.path,
                                                         byteCount: shot.byteCount))
        case "browser-eval":
            guard let expr = params.string("js", "expression"), !expr.isEmpty else {
                throw BrowserError("invalid_argument", "browser-eval requires --js")
            }
            let value = try await service.eval(workspace: workspace, page: page, expression: expr)
            return .object(["value": value])
        case "browser-console":
            let entries = try await service.console(workspace: workspace, page: page,
                                                    limit: params.field("limit")?.intValue)
            return try JSONBridge.value(ConsoleResult(entries: entries))
        case "browser-tab":
            return try await tab(params, workspace: workspace, page: page)
        default:
            throw BrowserError("unknown_command", "no handler for '\(request.method)'")
        }
    }

    private func tab(_ params: JSONValue, workspace: String, page: String?) async throws -> JSONValue {
        let action = params.string("action")
            ?? params.field("_args")?.arrayValue?.first?.stringValue
            ?? "list"
        switch action {
        case "profile":
            return try await tabProfile(params, workspace: workspace)
        case "list":
            let summary = await service.listTabs(workspace: workspace)
            return try JSONBridge.value(TabListResult(
                workspace: summary.key, activePageId: summary.activePageId, tabs: summary.pages))
        case "create":
            return try await pageResult(service.createTab(workspace: workspace,
                                                          url: params.string("url")))
        case "close":
            try await service.closeTab(workspace: workspace, page: page)
            return try JSONBridge.value(ClosedResult(closed: true))
        case "switch":
            guard let page else {
                throw BrowserError("invalid_argument", "browser tab switch requires --page")
            }
            return try await pageResult(service.switchTab(workspace: workspace, page: page))
        default:
            throw BrowserError("invalid_argument",
                               "unknown tab action '\(action)' (list|create|close|switch|profile)")
        }
    }

    /// `browser tab profile <verb>` — the CLI delivers the verb as the second
    /// positional (`_args` = ["profile", "<verb>"]); defaults to `list`.
    private func tabProfile(_ params: JSONValue, workspace: String) async throws -> JSONValue {
        let action = params.field("_args")?.arrayValue?.dropFirst().first?.stringValue ?? "list"
        switch action {
        case "list":
            let profiles = await service.listProfiles()
            return try JSONBridge.value(ProfileListResult(profiles: profiles))
        case "create":
            guard let label = params.string("label"), !label.isEmpty else {
                throw BrowserError("invalid_argument", "browser tab profile create requires --label")
            }
            let profile = try await service.createProfile(label: label)
            return try JSONBridge.value(ProfileResult(workspace: nil, profile: profile))
        case "set":
            guard let selector = params.string("profile"), !selector.isEmpty else {
                throw BrowserError("invalid_argument",
                                   "browser tab profile set requires --profile <id|label>")
            }
            let bound = try await service.bindProfile(workspace: workspace, profile: selector)
            return try JSONBridge.value(ProfileResult(workspace: bound.workspace,
                                                      profile: bound.profile))
        case "show":
            let bound = await service.boundProfile(workspace: workspace)
            return try JSONBridge.value(ProfileResult(workspace: bound.workspace,
                                                      profile: bound.profile))
        default:
            throw BrowserError("invalid_argument",
                               "unknown profile action '\(action)' (list|create|set|show)")
        }
    }

    private func pageResult(_ page: BrowserPage) throws -> JSONValue {
        try JSONBridge.value(PageResult(page: page))
    }

    private func requiredWorkspace(_ params: JSONValue) throws -> String {
        guard let selector = params.string("worktree", "workspace"), !selector.isEmpty else {
            throw BrowserError("invalid_argument", "missing --worktree selector")
        }
        return selector
    }

    private func requiredRef(_ params: JSONValue) throws -> String {
        guard let ref = params.string("ref"), !ref.isEmpty else {
            throw BrowserError("invalid_argument", "missing --ref (take a `browser snapshot` first)")
        }
        return ref
    }

    private func requiredText(_ params: JSONValue, verb: String) throws -> String {
        guard let text = params.string("text", "value") else {
            throw BrowserError("invalid_argument", "\(verb) requires --text")
        }
        return text
    }
}

private struct PageResult: Encodable {
    var page: BrowserPage
}

private struct SnapshotResult: Encodable {
    var page: BrowserPage
    var outline: String
    var refCount: Int
    var epoch: Int
}

private struct ActionResult: Encodable {
    var done: Bool
    var ref: String?
}

private struct ScreenshotResult: Encodable {
    var page: BrowserPage
    var path: String
    var byteCount: Int
}

private struct ConsoleResult: Encodable {
    var entries: [BrowserConsoleEntry]
}

private struct TabListResult: Encodable {
    var workspace: String
    var activePageId: String?
    var tabs: [BrowserPage]
}

private struct ProfileListResult: Encodable {
    var profiles: [BrowserProfile]
}

private struct ProfileResult: Encodable {
    var workspace: String?
    var profile: BrowserProfile
}

private struct ClosedResult: Encodable {
    var closed: Bool
}
