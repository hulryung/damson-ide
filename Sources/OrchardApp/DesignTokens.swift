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

    static let text = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    static let fontPill = Font.system(size: 10, weight: .semibold)
    static let fontMeta = Font.system(size: 11)
    static let fontRow = Font.system(size: 13)
    static let fontHeader = Font.system(size: 11, weight: .semibold)
    static let fontMono = Font.system(size: 11.5, design: .monospaced)

    /// Chrome rounding. Kept small on purpose: the sidebar rows and the workbench
    /// tabs read as one surface with edges, not as pills floating on a list.
    static let radius: CGFloat = 3
    static let radiusCard: CGFloat = 6
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
