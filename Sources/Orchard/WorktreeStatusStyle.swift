import SwiftUI
import DamsonOrchestrator

/// Presentation for a worktree row's state.
///
/// The sidebar answers one question — *does this need me?* — so its vocabulary is
/// deliberately coarser than `AgentRuntimeState`. Anything blocking is amber and animated;
/// everything else is quiet. The detailed agent state lives one level down, on the agent row.
extension WorktreeDisplayState {
    var color: Color {
        switch self {
        case .idle: return Tokens.textTertiary
        case .hasChanges: return Tokens.Git.modified
        case .starting: return Tokens.textSecondary
        case .working: return .accentColor
        case .needsApproval: return .orange
        case .needsInput: return .yellow
        case .agentIdle: return .green
        case .done: return Tokens.textSecondary
        case .failed: return .red
        }
    }

    /// SF Symbol shown in the row's leading status lane. A filled dot is the resting form;
    /// distinct glyphs are reserved for the states worth interrupting the user for, so a
    /// scan down the sidebar picks them out without reading a single label.
    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .hasChanges: return "circle.dotted"
        case .starting: return "circle.dashed"
        case .working: return "circle.fill"
        case .needsApproval: return "exclamationmark.circle.fill"
        case .needsInput: return "questionmark.circle.fill"
        case .agentIdle: return "circle.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    /// Whether the status glyph should pulse. Only `.working` does — a moving element in a
    /// list of twelve is a strong signal, so it has to mean exactly one thing.
    var pulses: Bool { self == .working }
}

/// The leading status lane of a worktree row: a fixed-width column holding one glyph, so
/// titles stay aligned no matter which state each row is in.
struct WorktreeStatusDot: View {
    let state: WorktreeDisplayState
    var size: CGFloat = 9

    @State private var pulse = false

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(state.color)
            .opacity(state.pulses && pulse ? 0.35 : 1)
            .animation(state.pulses
                       ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                       : .default,
                       value: pulse)
            .onAppear { pulse = state.pulses }
            .onChange(of: state.pulses) { pulse = $0 }
            .frame(width: 14)
            .help(state.label)
    }
}

/// A compact `+N −M` pair. Rendered only where it earns its space: the diff pane header and
/// the worktree row's meta line.
struct DiffStatBadge: View {
    let stat: GitDiffStat
    var body: some View {
        if !stat.isEmpty {
            HStack(spacing: 4) {
                if stat.added > 0 {
                    Text("+\(stat.added)").foregroundStyle(Tokens.Git.added)
                }
                if stat.deleted > 0 {
                    Text("−\(stat.deleted)").foregroundStyle(Tokens.Git.deleted)
                }
            }
            .font(Tokens.fontMeta)
            .monospacedDigit()
            .help("\(stat.fileCount) changed \(stat.fileCount == 1 ? "file" : "files")")
        }
    }
}

extension GitFileChange.Kind {
    var color: Color {
        switch self {
        case .added: return Tokens.Git.added
        case .modified: return Tokens.Git.modified
        case .deleted: return Tokens.Git.deleted
        case .untracked: return Tokens.Git.untracked
        case .conflicted: return Tokens.Git.conflicted
        case .typeChanged: return Tokens.Git.modified
        }
    }
}
