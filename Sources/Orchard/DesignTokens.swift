import SwiftUI
import AppKit

/// Orchard's visual tokens.
///
/// The rule, borrowed from orca's style guide: **the chrome is monochrome and color is
/// reserved for state.** Orchard spends its whole life framing someone else's tool — a
/// terminal running an agent — so its own surfaces should recede. Sidebar, toolbars, and
/// panels use macOS's semantic colors; saturated color appears only on a status dot, a git
/// decoration, or a destructive action.
///
/// The app pins itself to `darkAqua` (see `main.swift`), so the semantic colors below always
/// resolve to their dark values and the literal colors are specified for a dark background
/// only. Accent tint and increased-contrast still come through the semantic colors for free.
enum Tokens {

    // MARK: - Surfaces

    /// App canvas behind panels.
    static let background = Color(nsColor: .windowBackgroundColor)
    /// Panels lifted off the canvas: cards, headers, the diff pane.
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// Sidebar background. `.underPageBackgroundColor` is what AppKit uses for source lists.
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    /// Every hairline: dividers, input outlines, card edges.
    static let border = Color(nsColor: .separatorColor)
    /// Hover/active background for list rows and ghost buttons.
    static let rowHover = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    /// The persistently-selected row.
    static let rowSelected = Color.accentColor.opacity(0.18)

    // MARK: - Text

    static let text = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Type scale
    //
    // Matches orca's dense-list scale. Sizes are points rather than px, so they land a touch
    // larger than the web app — correct for AppKit, where 13pt is the standard control size.

    /// 10pt uppercase meta — repo pills, tiny badges.
    static let fontPill = Font.system(size: 10, weight: .semibold)
    /// 11pt — branch names, agent-row prompts, secondary meta.
    static let fontMeta = Font.system(size: 11)
    /// 13pt — sidebar row titles, dense list rows.
    static let fontRow = Font.system(size: 13)
    /// 13pt semibold — section headers.
    static let fontHeader = Font.system(size: 11, weight: .semibold)
    /// Monospace for paths, diffs, and anything literal.
    static let fontMono = Font.system(size: 11.5, design: .monospaced)

    // MARK: - Geometry

    static let radius: CGFloat = 6
    static let radiusCard: CGFloat = 8
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 280
    static let sidebarMaxWidth: CGFloat = 500

    // MARK: - Git decoration
    //
    // VS Code's dark-theme git palette, so anyone moving between the two isn't surprised by
    // what "green" means. Used ONLY for git status — reusing them for unrelated state would
    // break the convention that makes them readable at a glance.

    enum Git {
        static let added = Color(hex: 0x81B88B)
        static let modified = Color(hex: 0xE2C08D)
        static let deleted = Color(hex: 0xC74E39)
        static let untracked = Color(hex: 0x73C991)
        static let conflicted = Color(hex: 0xE4676B)
        static let ignored = Color(nsColor: .tertiaryLabelColor)

        /// Diff line colors — a low-alpha wash behind added/removed lines rather than solid
        /// fills, so the code on top stays legible.
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
