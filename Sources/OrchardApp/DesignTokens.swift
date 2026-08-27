import SwiftUI
import AppKit

/// Orchard's visual tokens.
///
/// The chrome is monochrome and color is reserved for state. Orchard spends its
/// life framing someone else's tool — a terminal running an agent — so its own
/// surfaces recede. The app pins itself to `darkAqua`, so semantic colors always
/// resolve to their dark values.
enum Tokens {

    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let rowHover = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let rowSelected = Color.accentColor.opacity(0.18)

    /// Selection in the workspace list and the tab strip is *neutral*, never an
    /// accent tint. Those surfaces already spend colour on things that mean
    /// something — the status glyph, git counts, the unread dot, a host's
    /// reachability — and a blue wash underneath makes a card argue with its own
    /// contents. So the fill only lifts the surface, and a brighter neutral edge
    /// does the actual "this one" work. (`docs/research/orca-chrome.md` §1.)
    static let selectionFill = Color(nsColor: .labelColor).opacity(0.10)
    static let selectionEdge = Color(nsColor: .labelColor).opacity(0.55)
    /// A hair less lift than a selected row: a tab sits on `surface`, which is
    /// already brighter than the sidebar.
    static let tabActiveFill = Color(nsColor: .labelColor).opacity(0.06)

    static let text = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    static let fontPill = Font.system(size: 10, weight: .semibold)
    static let fontMeta = Font.system(size: 11)
    static let fontRow = Font.system(size: 13)
    static let fontHeader = Font.system(size: 11, weight: .semibold)
    static let fontMono = Font.system(size: 11.5, design: .monospaced)
    /// A group header in the workspace list is a *title*, not a caption: same
    /// size as the card titles under it, separated by weight alone. Sizing it
    /// down and greying it out — the usual sidebar caption move — buries the
    /// only label that says which repo a run of cards belongs to.
    static let fontSection = Font.system(size: 13, weight: .semibold)
    /// Tab titles sit one step below row text so a saturated strip stays quiet.
    static let fontTab = Font.system(size: 12)

    /// Chrome rounding. Kept small on purpose: the sidebar rows and the workbench
    /// tabs read as one surface with edges, not as pills floating on a list.
    static let radius: CGFloat = 3
    static let radiusCard: CGFloat = 6
    /// Fixed chrome heights, so the sidebar's group headers and the workbench's
    /// tab strip share one rhythm instead of each falling out of their content.
    static let tabStripHeight: CGFloat = 32
    static let sectionHeaderHeight: CGFloat = 28
    /// The selection marker: a bar on the edge that faces the content the
    /// selection owns — bottom of an active tab, leading edge of a picked row.
    static let selectionBarWidth: CGFloat = 2
    static let sidebarMinWidth: CGFloat = 220
    /// Fixed status-bar height: the bottom safe-area inset does not propagate
    /// into the split view's AppKit-backed columns, so panes that pin content
    /// to their bottom edge pad by this instead of the safe area.
    static let statusBarHeight: CGFloat = 26
    /// Smallest pane a terminal is still usable in. `HSplitView`'s own minimum is a
    /// hint that nested splits do not honour, so the split action enforces this.
    static let paneMinWidth: CGFloat = 240
    static let paneMinHeight: CGFloat = 140
    static let sidebarIdealWidth: CGFloat = 280
    static let sidebarMaxWidth: CGFloat = 500

    /// VS Code dark-theme git palette. Used ONLY for git status.
    enum Git {
        static let added = Color(hex: 0x81B88B)
        static let modified = Color(hex: 0xE2C08D)
        static let deleted = Color(hex: 0xC74E39)
        static let untracked = Color(hex: 0x73C991)
        static let conflicted = Color(hex: 0xE4676B)
        static let addedLine = Color(hex: 0x81B88B).opacity(0.16)
        static let deletedLine = Color(hex: 0xC74E39).opacity(0.16)
        static let hunkHeader = Color(hex: 0x569CD6)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
