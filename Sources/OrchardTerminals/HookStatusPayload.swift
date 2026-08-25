import Foundation

/// Fields a hook or OSC 9999 JSON payload can carry beyond the turn-state keyword.
///
/// Hook CLIs already send `last_assistant_message` / `lastAssistantMessage` (and the
/// user prompt) on their lifecycle events — Orca's `AgentStatusPayload` is the same
/// shape. Chat view-mode reads these fields off the status stream; it must not scrape
/// the PTY grid for prose.
public struct HookStatusFields: Equatable, Sendable {
    public var prompt: String?
    public var lastAssistantMessage: String?
    public var toolName: String?
    public var toolInput: String?
    /// Provider-owned conversation identifier. Claude lifecycle hooks call this
    /// `session_id`; retaining it lets orchestration prove and pin the exact JSONL.
    public var providerSessionID: String?
    /// Pending AskUserQuestion / approval payload. Dashboard cards project this
    /// into `askSummary` only while the agent is in the attention bucket.
    public var interactivePrompt: String?

    public init(prompt: String? = nil, lastAssistantMessage: String? = nil,
                toolName: String? = nil, toolInput: String? = nil,
                providerSessionID: String? = nil,
                interactivePrompt: String? = nil) {
        self.prompt = prompt
        self.lastAssistantMessage = lastAssistantMessage
        self.toolName = toolName
        self.toolInput = toolInput
        self.providerSessionID = providerSessionID
        self.interactivePrompt = interactivePrompt
    }

    /// True when at least one optional field is present. Empty payloads are a no-op
    /// so a keyword-only OSC (`9999;idle`) does not look like new chat evidence.
    public var hasValues: Bool {
        prompt != nil || lastAssistantMessage != nil || toolName != nil || toolInput != nil
            || providerSessionID != nil || interactivePrompt != nil
    }

    /// Overlay non-nil incoming fields. Omission means "no new info", not "clear"
    /// — later tool-use hooks often drop the prompt, and clearing would wipe the
    /// cached user turn the chat projector keys on.
    public mutating func merge(_ other: HookStatusFields) {
        if let prompt = other.prompt { self.prompt = prompt }
        if let lastAssistantMessage = other.lastAssistantMessage {
            self.lastAssistantMessage = lastAssistantMessage
        }
        if let toolName = other.toolName { self.toolName = toolName }
        if let toolInput = other.toolInput { self.toolInput = toolInput }
        if let providerSessionID = other.providerSessionID {
            self.providerSessionID = providerSessionID
        }
        if let interactivePrompt = other.interactivePrompt {
            self.interactivePrompt = interactivePrompt
        }
    }

    /// Parse a hook POST body or OSC 9999 JSON payload. Unknown / non-object JSON
    /// yields an empty value rather than throwing — a garbled hook must not take
    /// the status stream down.
    public static func parse(json: Data) -> HookStatusFields {
        guard !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return HookStatusFields() }
        return parse(object: object)
    }

    public static func parse(jsonString: String) -> HookStatusFields {
        parse(json: Data(jsonString.utf8))
    }

    public static func parse(object: [String: Any]) -> HookStatusFields {
        HookStatusFields(
            prompt: firstString(object, keys: ["prompt", "user_prompt"]),
            lastAssistantMessage: normalizeAssistant(
                firstString(object, keys: ["lastAssistantMessage", "last_assistant_message"])),
            toolName: clip(firstString(object, keys: ["toolName", "tool_name"]),
                           max: agentStatusToolNameMax),
            toolInput: clip(firstString(object, keys: ["toolInput", "tool_input"]),
                            max: agentStatusToolInputMax),
            providerSessionID: clip(
                firstString(object, keys: ["session_id", "sessionId", "provider_session_id"]),
                max: agentStatusProviderSessionIDMax),
            interactivePrompt: clip(
                firstString(object, keys: ["interactivePrompt", "interactive_prompt"]),
                max: agentStatusInteractivePromptMax))
    }
}

/// Cap on `lastAssistantMessage` (Orca's `AGENT_STATUS_ASSISTANT_MESSAGE_MAX_LENGTH`).
/// 8 KB fits a multi-paragraph summary and bounds a buggy agent spamming huge strings.
public let agentStatusAssistantMessageMax = 8_000
public let agentStatusToolNameMax = 60
public let agentStatusToolInputMax = 160
public let agentStatusProviderSessionIDMax = 256
/// Orca `AGENT_STATUS_INTERACTIVE_PROMPT_MAX_LENGTH` — generous so AskUserQuestion
/// JSON survives; the dashboard then clips to a short `askSummary`.
public let agentStatusInteractivePromptMax = 16_000

private func firstString(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = object[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}

/// Collapse exotic line breaks, cap blank-line runs at one, then clip to the
/// assistant-message budget. Swift's `prefix` is character-based, so truncation
/// cannot split a surrogate pair the way a byte cap would.
func normalizeAssistant(_ raw: String?) -> String? {
    guard let raw else { return nil }
    var text = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\u{2028}", with: "\n")
        .replacingOccurrences(of: "\u{2029}", with: "\n")
    while text.contains("\n\n\n") {
        text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    return clip(text, max: agentStatusAssistantMessageMax)
}

private func clip(_ value: String?, max: Int) -> String? {
    guard let value else { return nil }
    if value.count <= max { return value }
    return String(value.prefix(max))
}
