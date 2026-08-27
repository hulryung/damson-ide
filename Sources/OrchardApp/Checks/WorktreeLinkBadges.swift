import OrchardCore
import SwiftUI

/// The card's typed link properties (inventory §2: `issue`, `linear-issue`,
/// `jira-issue`, `pr`).
///
/// One badge per link, drawn with the tracker's own icon. A link whose text typed
/// to nothing keeps a plain link icon and says so on hover — the card shows
/// "untyped", never a tracker nobody chose.
struct WorktreeLinkBadges: View {
    let links: [WorktreeLink]

    var body: some View {
        if !links.isEmpty {
            HStack(spacing: 4) {
                ForEach(links) { link in
                    badge(link)
                }
            }
        }
    }

    @ViewBuilder
    private func badge(_ link: WorktreeLink) -> some View {
        let content = HStack(spacing: 2) {
            Image(systemName: link.kind.symbol).font(.system(size: 8))
            Text(link.display)
                .font(Tokens.fontPill)
                .lineLimit(1)
        }
        .foregroundStyle(link.kind == .untyped ? Tokens.textTertiary : Tokens.textSecondary)
        .help(helpText(link))

        if let raw = link.url, let url = URL(string: raw) {
            Link(destination: url) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private func helpText(_ link: WorktreeLink) -> String {
        switch link.kind {
        case .untyped:
            return "\(link.raw) — untyped. Orchard does not guess which tracker this is; "
                + "set it with orchard worktree set --issue \(link.raw) --link-kind linear-issue|jira-issue."
        default:
            return "\(link.kind.label): \(link.raw)"
        }
    }
}
