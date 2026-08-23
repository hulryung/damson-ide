import AppKit
import OrchardRuntime

/// Token colors for the workbench editor. The chrome stays monochrome; these
/// are the VS Code Dark+ hues already used for git status, so syntax sits on
/// the same darkAqua palette without a second theme.
enum EditorSyntaxTheme {
    static let `default` = NSColor.labelColor
    static let keyword = NSColor(hex: 0x569CD6)
    static let string = NSColor(hex: 0xCE9178)
    static let comment = NSColor(hex: 0x6A9955)
    static let number = NSColor(hex: 0xB5CEA8)
    static let type = NSColor(hex: 0x4EC9B0)

    static func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .text: return `default`
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        }
    }
}
