import Combine
import Foundation
import OrchardTerminals

/// Per-pane chat projection: folds the terminal service's agent-status stream
/// into a bounded in-memory transcript and submits composer text through the
/// verified injection pipeline. Typed refusals stay visible — a permission
/// block is a blocked state, not a silent drop.
@MainActor
final class ChatPaneController: ObservableObject {
    @Published private(set) var items: [ChatTranscriptItem] = []
    @Published var draft = ""
    @Published var refusal: String?
    @Published var isSending = false
    @Published private(set) var projection: AgentRuntimeProjection?

    private var projector = ChatTranscriptProjector()
    private var listenTask: Task<Void, Never>?
    private(set) var liveHandle: String?

    func start(handle: String, service: TerminalService) {
        if liveHandle == handle, listenTask != nil { return }
        listenTask?.cancel()
        liveHandle = handle
        listenTask = Task { [weak self] in
            do {
                let stream = try service.agentStatusUpdates(handle: handle)
                for await snapshot in stream {
                    guard !Task.isCancelled else { break }
                    self?.ingest(snapshot)
                }
            } catch {
                self?.refusal = (error as? TerminalServiceError)?.message
                    ?? String(describing: error)
            }
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
    }

    func ingest(_ snapshot: AgentStatusSnapshot) {
        liveHandle = snapshot.terminalHandle
        projection = snapshot.projection
        items = projector.apply(snapshot)
    }

    func submit(handle: String, service: TerminalService) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        refusal = nil
        defer { isSending = false }
        do {
            let result = try await service.send(handle: handle, text: text, enter: true)
            if result.accepted {
                draft = ""
                return
            }
            switch result.refusedReason {
            case .permission:
                refusal = "Agent is waiting for permission — the prompt was not sent."
            case .noAgent:
                refusal = "No live agent in this terminal."
            case nil:
                refusal = "Send was refused."
            }
        } catch let error as TerminalServiceError {
            switch error {
            case .promptBlocked:
                refusal = "Agent hit a permission prompt during send — the submission is parked."
            case .promptStalled:
                refusal = "Agent never left idle after the prompt was typed."
            default:
                refusal = error.message
            }
        } catch {
            refusal = String(describing: error)
        }
    }
}
