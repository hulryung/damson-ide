/// Extractable status-bar copy (T71). The SwiftUI chips in OrchardApp render
/// these strings; bucketing still comes from T67's DashboardProjection.
public enum StatusBarProjection {
    /// Current workspace plus its branch. Empty/whitespace name is "No workspace";
    /// a missing branch is omitted rather than shown as a dangling separator.
    public static func workspaceLine(name: String?, branch: String?) -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedName.isEmpty { return "No workspace" }
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedBranch.isEmpty { return trimmedName }
        return "\(trimmedName) · \(trimmedBranch)"
    }

    /// T51 `runtimePresence.menuTitle` — the status bar reuses that wording so
    /// Dock, app menu, and the chip never disagree.
    public static func runtimeChip(_ indication: WindowLifecycle.RuntimeIndication) -> String {
        indication.menuTitle
    }

    /// Compact live-agent counts, one slot per dashboard bucket, glyphs first
    /// so a 26pt bar stays scannable. Order is the caller's (attention → idle).
    public static func bucketSummary(_ buckets: [StatusBarBucketCount]) -> String {
        buckets.map { "\($0.glyph)\($0.count)" }.joined(separator: "  ")
    }
}

/// One dashboard bucket as the status bar shows it. `id` is the bucket raw
/// value so the chip can stay typed without importing OrchardTerminals here.
public struct StatusBarBucketCount: Equatable, Sendable {
    public var id: String
    public var glyph: String
    public var count: Int

    public init(id: String, glyph: String, count: Int) {
        self.id = id
        self.glyph = glyph
        self.count = count
    }
}
