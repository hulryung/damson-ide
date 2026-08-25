import SwiftUI

/// Which right-sidebar section is showing. Files is T9's explorer; source-control
/// is T70. The picker lives here so RootView only swaps the chrome hook.
enum RightSidebarSection: String, CaseIterable, Identifiable {
    case files
    case sourceControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .sourceControl: return "Source Control"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .sourceControl: return "arrow.triangle.branch"
        }
    }
}

/// Trailing-edge host: section picker + the selected pane. Replaces the T9-only
/// explorer hook so source-control can sit beside files without rewriting the
/// explorer itself.
struct RightSidebar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            // Keep the explorer mounted so its file-open listener stays alive
            // while source-control is showing.
            ZStack {
                FileExplorerSidebar()
                    .opacity(store.rightSidebarSection == .files ? 1 : 0)
                    .allowsHitTesting(store.rightSidebarSection == .files)
                if store.rightSidebarSection == .sourceControl {
                    SourceControlSidebar()
                }
            }
        }
        .background(Tokens.sidebar)
    }

    private var picker: some View {
        HStack(spacing: 2) {
            ForEach(RightSidebarSection.allCases) { section in
                Button {
                    store.rightSidebarSection = section
                } label: {
                    Label(section.title, systemImage: section.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(Tokens.fontMeta)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.radius)
                                .fill(store.rightSidebarSection == section
                                      ? Tokens.rowSelected : Color.clear)
                        )
                        .foregroundStyle(store.rightSidebarSection == section
                                         ? Tokens.text : Tokens.textSecondary)
                }
                .buttonStyle(.plain)
                .help(section.title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

extension View {
    /// T70 chrome hook: workbench + right sidebar (files / source-control).
    func rightSidebar() -> some View {
        HSplitView {
            self
            RightSidebar()
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 380)
        }
    }
}
