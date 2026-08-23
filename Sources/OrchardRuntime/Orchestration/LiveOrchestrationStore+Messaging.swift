import Foundation
import OrchardOrchestration
import OrchardProtocol

// Messaging verbs: send / check / reply / ask / inbox.
//
// `send` folds the CLI sugar flags (--task-id --dispatch-id --outcome --files-modified
// --report-path --phase) into the payload object exactly as Orca's RPC layer does, so
// T1's lifecycle reconciliation sees the payload shape it was built for.
extension LiveOrchestrationStore {
    // MARK: - send

    public func send(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let subject = p.str("subject"), !subject.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "send requires --subject")
        }
        let caller = await identity(p)
        let to = p.str("to")
        let type = try Self.messageType(p.str("type")) ?? .status
        let priority = try Self.messagePriority(p.str("priority")) ?? .normal
        let payloadText = Self.mergedPayloadText(p)
        let directory = await context.terminals()

        return try await idempotent(p, method: "send") {
            let runID = try self.resolveRunID(p, caller: caller, to: to)
            _ = try self.requireRun(runID)
            let receipt = try self.store.sendMessage(
                OutboundMessage(
                    from: caller.handle ?? "cli",
                    senderPaneKey: caller.paneKey,
                    to: to,
                    runID: runID,
                    subject: subject,
                    body: p.str("body") ?? "",
                    type: type,
                    priority: priority,
                    threadID: p.str("thread-id"),
                    payload: payloadText),
                terminals: directory.map(\.entry),
                agentStatus: { handle in directory.first { $0.entry.handle == handle }?.agentStatus })
            var result: [String: JSONValue] = [
                "messageIds": .array(receipt.messages.map { .string($0.id) }),
                "count": .number(Double(receipt.messages.count)),
                "runId": .string(runID),
                "type": .string(type.rawValue),
            ]
            if let thread = receipt.messages.first?.threadID {
                result["threadId"] = .string(thread)
            }
            if let lifecycle = Self.json(receipt.lifecycle) {
                result["lifecycle"] = lifecycle
            }
            return .object(result)
        }
    }

    /// The payload column text: an explicit `--payload` object merged with the CLI
    /// sugar flags. Flags win over payload keys — they are the documented contract the
    /// preamble teaches, so a stale payload blob must not shadow them.
    static func mergedPayloadText(_ p: [String: JSONValue]) -> String? {
        var payload: [String: JSONValue] = [:]
        switch p["payload"] {
        case .some(.object(let o)):
            payload = o
        case .some(.string(let s)):
            if let data = s.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
               case .object(let o) = parsed {
                payload = o
            }
        default:
            break
        }
        if let v = p.str("task-id") { payload["taskId"] = .string(v) }
        if let v = p.str("dispatch-id") { payload["dispatchId"] = .string(v) }
        if let v = p.str("outcome") { payload["outcome"] = .string(v) }
        if let files = p.csv("files-modified") {
            payload["filesModified"] = .array(files.map(JSONValue.string))
        }
        if let v = p.str("report-path") { payload["reportPath"] = .string(v) }
        if let v = p.str("phase") { payload["phase"] = .string(v) }
        guard !payload.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(payload)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func json(_ lifecycle: LifecycleReconciliation?) -> JSONValue? {
        switch lifecycle {
        case nil, .some(.ignored):
            return nil
        case .suppressed:
            return .object(["status": .string("suppressed")])
        case .rejected(let code, let reason):
            return .object([
                "status": .string("rejected"),
                "code": .string(code),
                "reason": .string(reason),
            ])
        case .completed(let taskID, let dispatchID):
            return .object([
                "status": .string("settled"),
                "outcome": .string("succeeded"),
                "taskId": .string(taskID),
                "dispatchId": .string(dispatchID),
            ])
        case .failed(let taskID, let dispatchID):
            return .object([
                "status": .string("settled"),
                "outcome": .string("failed"),
                "taskId": .string(taskID),
                "dispatchId": .string(dispatchID),
            ])
        case .heartbeatRecorded(let dispatchID):
            return .object([
                "status": .string("heartbeat_recorded"),
                "dispatchId": .string(dispatchID),
            ])
        }
    }

    // MARK: - check

    public func check(_ p: [String: JSONValue]) async throws -> JSONValue {
        let caller = await identity(p)
        let types = try Self.messageTypes(p.csv("types"))
        return try await mapped {
            // Coordinator mode when a Run is in scope (explicit --run or the caller's
            // pane binds one); otherwise worker mode against the terminal's mailboxes.
            if let explicit = p.str("run"), !explicit.isEmpty {
                return try await self.coordinatorCheck(runID: explicit, p, caller: caller, types: types)
            }
            if let pane = caller.paneKey, let bound = try self.store.runForCoordinatorPane(pane) {
                return try await self.coordinatorCheck(runID: bound.id, p, caller: caller, types: types)
            }
            if caller.handle != nil {
                return try await self.workerCheck(p, caller: caller, types: types)
            }
            let runs = try self.store.listRuns()
            if runs.count == 1 {
                return try await self.coordinatorCheck(runID: runs[0].id, p, caller: caller, types: types)
            }
            throw RPCServiceError(
                code: "invalid_argument",
                message: "check requires --run <id> or --terminal <handle> to pick a mailbox.")
        }
    }

    /// The Run-delivery path: oldest outstanding FIFO batch (max 50), replayed verbatim
    /// until `--ack`; `--types` only gates what wakes a fresh delivery; the consumer
    /// generation is re-read on every fetch so a rebind mid-wait fences this caller.
    private func coordinatorCheck(
        runID: String, _ p: [String: JSONValue],
        caller: CallerIdentity, types: [MessageType]?
    ) async throws -> JSONValue {
        var run = try requireRun(runID)
        try requireCoordinatorAuthority(run, caller: caller)
        let address = "run:\(runID)"

        var acknowledged: JSONValue?
        if let deliveryID = p.str("ack"), !deliveryID.isEmpty {
            let (delivery, duplicate) = try store.acknowledgeRunDelivery(
                runID: runID, consumerGeneration: run.consumerGeneration, deliveryID: deliveryID)
            acknowledged = .object([
                "deliveryId": .string(delivery.id),
                "duplicate": .bool(duplicate),
            ])
        }

        if p.flag("peek") || p.flag("unread") {
            let unread = try store.unreadMessages(to: address, types: types)
            return Self.checkResult(runID: runID, messages: unread, extra: [
                "peeked": .bool(true),
                "acknowledged": acknowledged ?? .null,
            ])
        }
        if p.flag("all") {
            let history = try store.messageHistory(
                to: address, limit: p.int("limit") ?? 100, types: types)
            return Self.checkResult(runID: runID, messages: history, extra: [
                "all": .bool(true),
                "acknowledged": acknowledged ?? .null,
            ])
        }

        var batch = try store.getOrCreateRunDelivery(
            runID: runID, consumerGeneration: run.consumerGeneration, wakeTypes: types)
        if batch == nil, p.flag("wait") {
            let deadline = Date().addingTimeInterval(Self.timeoutSeconds(
                p, default: Self.defaultCheckWaitSeconds))
            let typeSet = types.map(Set.init)
            while batch == nil {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                let outcome = await waitCenter.waitForMessage(
                    recipient: address, types: typeSet, timeout: remaining)
                if case .timedOut = outcome { break }
                // Re-read the binding: a run-use during the wait bumps the generation
                // and this consumer must fence, not silently read the new batch.
                run = try requireRun(runID)
                try requireCoordinatorAuthority(run, caller: caller)
                batch = try store.getOrCreateRunDelivery(
                    runID: runID, consumerGeneration: run.consumerGeneration, wakeTypes: types)
            }
        }
        guard let batch else {
            return Self.checkResult(runID: runID, messages: [], extra: [
                "timedOut": .bool(p.flag("wait")),
                "acknowledged": acknowledged ?? .null,
            ])
        }
        return Self.checkResult(runID: runID, messages: batch.messages, extra: [
            "deliveryId": .string(batch.delivery.id),
            "replayed": .bool(batch.replayed),
            "acknowledged": acknowledged ?? .null,
        ])
    }

    /// Worker mode: the terminal's own mailbox plus its live dispatch address. The
    /// default read consumes (marks read); `--peek` looks without consuming; `--all`
    /// is history. `--wait` re-reads on every arrival hint until something lands.
    private func workerCheck(
        _ p: [String: JSONValue], caller: CallerIdentity, types: [MessageType]?
    ) async throws -> JSONValue {
        guard let handle = caller.handle else {
            throw RPCServiceError(code: "invalid_argument", message: "check requires --terminal")
        }
        var addresses = [handle]
        if let dispatch = try store.activeDispatchForAssignee(handle: handle, paneKey: caller.paneKey) {
            addresses.append("dispatch:\(dispatch.id)")
        }

        if p.flag("all") {
            let limit = p.int("limit") ?? 100
            let merged = try addresses
                .flatMap { try store.messageHistory(to: $0, limit: limit, types: types) }
                .sorted { $0.sequence > $1.sequence }
                .prefix(limit)
            return Self.checkResult(runID: nil, messages: Array(merged), extra: ["all": .bool(true)])
        }

        func unread() throws -> [OrchestrationMessage] {
            try addresses.flatMap { try store.unreadMessages(to: $0, types: types) }
                .sorted { $0.sequence < $1.sequence }
        }

        var messages = try unread()
        if messages.isEmpty, p.flag("wait") {
            let deadline = Date().addingTimeInterval(Self.timeoutSeconds(
                p, default: Self.defaultCheckWaitSeconds))
            let typeSet = types.map(Set.init)
            while messages.isEmpty {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                // Two mailboxes but one waiter slot: wake on any arrival matching the
                // type filter, then re-read our own addresses. A wake for somebody
                // else's mail costs one empty read (the wait center's documented model).
                let outcome = await waitCenter.waitForMessage(
                    recipient: nil, types: typeSet, timeout: remaining)
                if case .timedOut = outcome { break }
                messages = try unread()
            }
        }
        if !p.flag("peek"), !messages.isEmpty {
            try store.markAsRead(messages.map(\.id))
        }
        return Self.checkResult(runID: nil, messages: messages, extra: [
            "timedOut": .bool(messages.isEmpty && p.flag("wait")),
            "peeked": .bool(p.flag("peek")),
        ])
    }

    static func checkResult(
        runID: String?, messages: [OrchestrationMessage], extra: [String: JSONValue]
    ) -> JSONValue {
        var result: [String: JSONValue] = [
            "messages": .array(messages.map(json)),
            "count": .number(Double(messages.count)),
        ]
        if let runID { result["runId"] = .string(runID) }
        for (key, value) in extra where value != .null {
            result[key] = value
        }
        return .object(result)
    }

    // MARK: - reply

    public func reply(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let messageID = p.str("id"), !messageID.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "reply requires --id")
        }
        guard let body = p.str("body"), !body.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "reply requires --body")
        }
        let caller = await identity(p)
        return try await idempotent(p, method: "reply") {
            guard let original = try self.store.message(messageID) else {
                throw RPCServiceError(code: "message_not_found", message: "Message \(messageID) was not found.")
            }
            // A question gets the answer path: records answer state, closes the loop
            // for the blocked `ask`, and is idempotent on the same body.
            if let question = try self.store.question(messageID) {
                let run = try self.requireRun(question.runID)
                try self.requireCoordinatorAuthority(run, caller: caller)
                let (answered, answer, duplicate) = try self.store.answerQuestion(
                    messageID: messageID, runID: run.id,
                    consumerGeneration: run.consumerGeneration, body: body)
                // T1's answer path marks the reply read (ask returns thread state), so
                // it never fires onMessageArrived — wake the blocked ask ourselves.
                self.waitCenter.notifyMessageArrived(
                    recipient: "dispatch:\(answered.dispatchID)", type: .status)
                return .object([
                    "questionId": .string(answered.messageID),
                    "answerMessageId": .string(answer.id),
                    "status": .string(answered.status.rawValue),
                    "duplicate": .bool(duplicate),
                ])
            }
            let receipt = try self.store.sendMessage(OutboundMessage(
                from: caller.handle ?? "cli",
                senderPaneKey: caller.paneKey,
                to: original.fromHandle,
                runID: original.runID,
                subject: "Re: \(original.subject)",
                body: body,
                type: .status,
                priority: .normal,
                threadID: original.threadID ?? original.id))
            let sent = receipt.messages[0]
            return .object([
                "messageId": .string(sent.id),
                "threadId": Self.optional(sent.threadID),
                "to": .string(sent.toHandle),
            ])
        }
    }

    // MARK: - ask

    public func ask(_ p: [String: JSONValue]) async throws -> JSONValue {
        let caller = await identity(p)
        guard let handle = caller.handle else {
            throw RPCServiceError(code: "invalid_argument", message: "ask requires --from <terminal handle>")
        }
        return try await mapped {
            let questionMessageID: String
            let dispatchID: String
            if let resume = p.str("resume"), !resume.isEmpty {
                guard let question = try self.store.question(resume) else {
                    throw RPCServiceError(code: "question_not_found", message: "Question \(resume) was not found.")
                }
                guard let dispatch = try self.store.dispatchContext(question.dispatchID),
                      dispatch.assigneeHandle == handle || dispatch.assigneePaneKey == caller.paneKey else {
                    throw RPCServiceError(
                        code: "consumer_fenced",
                        message: "Terminal \(handle) does not own the Dispatch behind question \(resume).")
                }
                questionMessageID = question.messageID
                dispatchID = question.dispatchID
            } else {
                guard let text = p.str("question"), !text.isEmpty else {
                    throw RPCServiceError(
                        code: "invalid_argument", message: "ask requires --question or --resume")
                }
                guard let dispatch = try self.store.activeDispatchForAssignee(
                    handle: handle, paneKey: caller.paneKey) else {
                    throw RPCServiceError(
                        code: "dispatch_inactive",
                        message: "Terminal \(handle) has no active Dispatch to ask from.")
                }
                let created = try self.store.createQuestion(
                    runID: dispatch.runID, dispatchID: dispatch.id,
                    askerHandle: handle, question: text,
                    options: p.csv("options") ?? [])
                questionMessageID = created.question.messageID
                dispatchID = dispatch.id
            }
            return try await self.awaitAnswer(
                questionMessageID: questionMessageID, dispatchID: dispatchID,
                timeout: Self.timeoutSeconds(p, default: Self.defaultAskSeconds,
                                             max: Self.maxAskSeconds))
        }
    }

    /// Block until the question is answered or closed, or the timeout lapses. The wait
    /// center wakes us when `reply` lands an answer; a short poll floor backstops
    /// answers written by paths that don't notify.
    private func awaitAnswer(
        questionMessageID: String, dispatchID: String, timeout: TimeInterval
    ) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let question = try store.question(questionMessageID) else {
                throw RPCServiceError(
                    code: "question_not_found", message: "Question \(questionMessageID) disappeared.")
            }
            switch question.status {
            case .answered:
                return .object([
                    "status": .string("answered"),
                    "messageId": .string(question.messageID),
                    "answerMessageId": Self.optional(question.answerMessageID),
                    "answer": Self.optional(question.answerBody),
                ])
            case .closed:
                throw RPCServiceError(
                    code: "dispatch_inactive",
                    message: "Question \(questionMessageID) was closed because its Dispatch settled.")
            case .pending:
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    return .object([
                        "status": .string("pending"),
                        "messageId": .string(question.messageID),
                        "timedOut": .bool(true),
                        "resume": .string("\(context.cliCommand) ask --resume \(question.messageID)"),
                    ])
                }
                _ = await waitCenter.waitForMessage(
                    recipient: "dispatch:\(dispatchID)", types: nil,
                    timeout: min(remaining, 2))
            }
        }
    }

    // MARK: - inbox

    public func inbox(_ p: [String: JSONValue]) async throws -> JSONValue {
        let caller = await identity(p)
        let limit = max(1, p.int("limit") ?? 20)
        let full = p.flag("full")
        return try await mapped {
            var addresses: [String] = []
            if let handle = caller.handle {
                addresses.append(handle)
                if let pane = caller.paneKey, let run = try self.store.runForCoordinatorPane(pane) {
                    addresses.append("run:\(run.id)")
                }
                if let dispatch = try self.store.activeDispatchForAssignee(
                    handle: handle, paneKey: caller.paneKey) {
                    addresses.append("dispatch:\(dispatch.id)")
                }
            } else if let runID = p.str("run") {
                addresses.append("run:\(runID)")
            } else {
                let runs = try self.store.listRuns()
                guard runs.count == 1 else {
                    throw RPCServiceError(
                        code: "invalid_argument",
                        message: "inbox requires --terminal (or --run) to pick a mailbox.")
                }
                addresses.append("run:\(runs[0].id)")
            }
            let merged = try addresses
                .flatMap { try self.store.messageHistory(to: $0, limit: limit) }
                .sorted { $0.sequence > $1.sequence }
                .prefix(limit)
            let rows = merged.map { message -> JSONValue in
                guard !full, case .object(var row) = Self.json(message) else {
                    return Self.json(message)
                }
                if message.body.count > 200 {
                    row["body"] = .string(String(message.body.prefix(200)) + "…")
                }
                return .object(row)
            }
            return .object([
                "messages": .array(rows),
                "count": .number(Double(rows.count)),
            ])
        }
    }

    // MARK: - Shared parsing

    static func messageType(_ raw: String?) throws -> MessageType? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let type = MessageType(rawValue: raw) else {
            throw RPCServiceError(code: "invalid_argument", message: "unknown message type '\(raw)'")
        }
        return type
    }

    static func messagePriority(_ raw: String?) throws -> MessagePriority? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let priority = MessagePriority(rawValue: raw) else {
            throw RPCServiceError(code: "invalid_argument", message: "unknown priority '\(raw)'")
        }
        return priority
    }

    static func messageTypes(_ names: [String]?) throws -> [MessageType]? {
        guard let names, !names.isEmpty else { return nil }
        return try names.map { name in
            guard let type = MessageType(rawValue: name) else {
                throw RPCServiceError(code: "invalid_argument", message: "unknown message type '\(name)'")
            }
            return type
        }
    }

    static func timeoutSeconds(
        _ p: [String: JSONValue], default defaultSeconds: TimeInterval,
        max maxSeconds: TimeInterval? = nil
    ) -> TimeInterval {
        guard let ms = p.int("timeout-ms") else { return defaultSeconds }
        let seconds = Swift.max(0, TimeInterval(ms) / 1000)
        if let maxSeconds { return Swift.min(seconds, maxSeconds) }
        return seconds
    }
}
