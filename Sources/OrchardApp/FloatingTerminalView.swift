import SwiftUI
import DamsonTerminal
import OrchardCore
import OrchardTerminals

/// Always-on-top window bound to an existing pane's live `DamsonSession`.
/// Closing this view must not terminate that session (T71).
struct FloatingTerminalView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if let tab = store.floatingWorkbenchTab(),
               let session = store.existingDamsonSession(for: tab) {
                surface(tab: tab, session: session)
            } else {
                PlaceholderPane(
                    symbol: "rectangle.on.rectangle",
                    title: "No live session",
                    detail: "This window shows an existing pane's terminal. Close it — the session stays with the pane.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.background)
    }

    @ViewBuilder
    private func surface(tab: WorkbenchTab, session: DamsonSession) -> some View {
        let surfaceID = "\(tab.agentID ?? tab.id):\(store.paneGeneration[tab.id] ?? 0)"
        ZStack(alignment: .top) {
            // Same DamsonSession as the workbench pane — never a second PTY.
            TerminalFitHost(session: session, isActive: tab.viewMode != .chat)
                .id(surfaceID)
            if tab.isAgentTab, tab.viewMode == .chat {
                ChatView(controller: store.chatController(for: tab)) {
                    Task { await store.submitChat(for: tab) }
                }
            }
            if let note = store.connectionEndedNote(for: tab) {
                ConnectionEndedBanner(tab: tab, note: note)
            }
        }
    }
}
