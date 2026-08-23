import AppKit
import Combine
import DamsonTerminal
import OrchardTerminals
import SwiftUI

/// Cell-snapped host for a `DamsonSurfaceView`.
///
/// Damson's public surface has no scroll-to-top / content-inset / frame-alignment
/// hook we can drive from the container (`backend` is private; `DamsonSurfaceView`
/// is `final`). `sizeThatFits` returns the largest whole-cell size that fits the
/// proposed pane so SwiftUI never hands Damson a fractional row. Leftover pixels
/// stay on the SwiftUI parent: short documents top-align so row 0 is fully
/// visible; overflowing content bottom-aligns. Damson's own follow-bottom /
/// content-anchor path keeps scroll stable when the snapped row count changes.
///
/// Adopted panes need a second pass: keeper preamble replay is delivered on the
/// next main-queue turn, so the first layout sees an empty grid. Subscribing to
/// `gridChanged` re-applies the same snap/align once that grid arrives — the
/// path fresh panes already get from their first prompt paint.
struct TerminalFitHost: View {
    @ObservedObject var session: DamsonSession
    var isActive: Bool
    var onFocus: (() -> Void)?
    /// Bumped on `gridChanged` so short-vs-overflow alignment and the snapped
    /// frame re-apply after an adopted pane's async preamble replay. Read in
    /// `body` so SwiftUI invalidates without recreating the surface.
    @State private var gridGeneration = 0

    var body: some View {
        GeometryReader { geo in
            let _ = gridGeneration
            let metrics = TerminalCellMetrics.measure(config: session.config)
            let layout = TerminalPaneFit.layout(container: geo.size, metrics: metrics)
            let top = TerminalPaneFit.shouldTopAlign(
                contentRows: Self.contentRows(in: session),
                viewportRows: layout.rows)
            Color(nsColor: session.config.backgroundColor)
                .overlay(alignment: top ? .topLeading : .bottomLeading) {
                    TerminalFitSurface(session: session, isActive: isActive, onFocus: onFocus)
                }
        }
        .onReceive(session.gridChanged) { _ in
            gridGeneration += 1
        }
    }

    static func contentRows(in session: DamsonSession) -> Int {
        let grid = session.grid
        var lastOccupied = max(grid.cursorRow, 0)
        for r in (0..<grid.rows).reversed() {
            if grid.row(r).contains(where: { $0.char != " " }) {
                lastOccupied = max(lastOccupied, r)
                break
            }
        }
        return TerminalPaneFit.contentRowCount(
            scrollback: grid.scrollback.count,
            lastOccupiedViewportRow: lastOccupied)
    }
}

private struct TerminalFitSurface: NSViewRepresentable {
    let session: DamsonSession
    var isActive: Bool
    var onFocus: (() -> Void)?

    func makeNSView(context: Context) -> DamsonSurfaceView {
        let view = DamsonSurfaceView(session: session)
        view.isActive = isActive
        view.onFocus = onFocus
        view.clipsToBounds = true
        return view
    }

    func updateNSView(_ view: DamsonSurfaceView, context: Context) {
        view.isActive = isActive
        view.onFocus = onFocus
        view.clipsToBounds = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DamsonSurfaceView, context: Context) -> CGSize {
        let proposed = CGSize(
            width: proposal.width ?? nsView.bounds.width,
            height: proposal.height ?? nsView.bounds.height)
        guard proposed.width > 0, proposed.height > 0 else { return proposed }
        let metrics = TerminalCellMetrics.measure(config: session.config)
        let layout = TerminalPaneFit.layout(container: proposed, metrics: metrics)
        return layout.contentSize
    }
}

/// Cell size matching Damson's `reportSizeIfChanged` (`"M"` advance +
/// NSLayoutManager line height of the nerd-fallback font) so the snapped
/// frame yields the same cols/rows the surface would have chosen.
enum TerminalCellMetrics {
    static func measure(config: DamsonConfig) -> TerminalPaneFit.Metrics {
        let font = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        let glyphSize = ("M" as NSString).size(withAttributes: [.font: font])
        return TerminalPaneFit.Metrics(
            cellWidth: max(glyphSize.width, 1),
            cellHeight: max(lineHeight(font: font), 1),
            padding: CGSize(width: config.padding.width, height: config.padding.height))
    }

    private static func lineHeight(font: NSFont) -> CGFloat {
        let lm = NSLayoutManager()
        let storage = NSTextStorage(string: "M\nM\nM", attributes: [.font: font])
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 10_000, height: 10_000))
        lm.addTextContainer(container)
        lm.ensureLayout(for: container)
        return lm.usedRect(for: container).height / 3.0
    }
}
