import SwiftUI
import OrchardTerminals

/// Native chat overlay for an agent tab. The PTY stays mounted underneath;
/// this view is never a second session.
struct ChatView: View {
    @ObservedObject var controller: ChatPaneController
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let refusal = controller.refusal {
                refusalBanner(refusal)
            }
            Divider()
            composer
        }
        .background(Tokens.background)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if controller.items.isEmpty {
                        emptyState
                    }
                    ForEach(controller.items) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: controller.items.count) { _ in
                if let last = controller.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("Waiting for the conversation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("Prompts, replies, and working/permission/idle markers land here from the agent status stream. The terminal is still running underneath.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    @ViewBuilder
    private func row(_ item: ChatTranscriptItem) -> some View {
        switch item.role {
        case .user:
            bubble(item.text, alignment: .trailing, fill: Tokens.rowSelected)
        case .assistant:
            bubble(item.text, alignment: .leading, fill: Tokens.surface)
        case .marker:
            HStack {
                Spacer()
                Text(item.text)
                    .font(Tokens.fontPill)
                    .foregroundStyle(markerColor(item.projection))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Tokens.rowHover))
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    private func bubble(_ text: String, alignment: HorizontalAlignment, fill: Color) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 48) }
            Text(text)
                .font(Tokens.fontRow)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusCard).fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusCard)
                        .strokeBorder(Tokens.border, lineWidth: 1)
                )
                .frame(maxWidth: 560, alignment: alignment == .trailing ? .trailing : .leading)
            if alignment == .leading { Spacer(minLength: 48) }
        }
    }

    private func markerColor(_ projection: AgentRuntimeProjection?) -> Color {
        switch projection {
        case .working: return .accentColor
        case .permission: return .orange
        case .idle: return Tokens.Git.added
        case nil: return Tokens.textTertiary
        }
    }

    private func refusalBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $controller.draft)
                .font(.system(size: 13))
                .frame(minHeight: 44, maxHeight: 96)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radius)
                        .strokeBorder(Tokens.border)
                )
            Button(action: onSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.borderless)
            .disabled(controller.isSending
                      || controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send through the agent (⌘↩)")
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(10)
        .background(Tokens.surface)
    }
}
