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
/// Two things re-apply that fit after the first layout (T31 → T59):
///
/// * `gridChanged` bumps `gridGeneration` so the short-vs-overflow alignment is
///   re-decided from the grid that is actually there (T31).
/// * `AttachFitDriver` puts the surface itself through the pass a fresh spawn
///   gets for free. A fresh pane is empty when its surface is framed: the
///   surface's `layout()` sizes the PTY, then the prompt paints into a matching
///   grid. A keeper-adopted pane carries content the other way round — its
///   replay and post-SIGWINCH repaint can land before the surface has a frame,
///   so Damson's size report, follow re-pin and version-keyed render either ran
///   against a placeholder geometry or never ran against that content. The
///   driver waits for both a real frame and painted content, then re-runs the
///   surface's `layout()` and forces a render that bypasses the dedupe key —
///   once per surface, for every session, so adopted and fresh panes take the
///   same path by construction (this also covers a window re-opened over a live
///   session, T51).
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
                contentRows: TerminalPaneFit.contentRows(in: session.grid),
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
}

private struct TerminalFitSurface: NSViewRepresentable {
    let session: DamsonSession
    var isActive: Bool
    var onFocus: (() -> Void)?

    func makeCoordinator() -> AttachFitDriver { AttachFitDriver() }

    func makeNSView(context: Context) -> DamsonSurfaceView {
        let view = DamsonSurfaceView(session: session)
        view.isActive = isActive
        view.onFocus = onFocus
        view.clipsToBounds = true
        context.coordinator.attach(view: view, session: session)
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

/// Drives `TerminalPaneFit.AttachFit` for one surface: feeds it the surface's
/// frame changes and the session's grid changes, and when it fires, re-runs the
/// surface's own fit pass. Everything it touches is Damson public API:
/// `layout()` (size report + follow re-pin) via `needsLayout` /
/// `layoutSubtreeIfNeeded()`, and `repaintNow()` (a render that ignores the
/// grid-version dedupe, so a frame drawn for the wrong geometry is replaced
/// even when the grid itself did not change).
@MainActor
final class AttachFitDriver {
    private var fit = TerminalPaneFit.AttachFit()
    private var subscriptions = Set<AnyCancellable>()
    private weak var view: DamsonSurfaceView?

    func attach(view: DamsonSurfaceView, session: DamsonSession) {
        self.view = view
        view.postsFrameChangedNotifications = true
        NotificationCenter.default
            .publisher(for: NSView.frameDidChangeNotification, object: view)
            .sink { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.note(.frame(ready: Self.hasFrame(view)))
                }
            }
            .store(in: &subscriptions)
        session.gridChanged
            .sink { [weak self, weak session] in
                MainActor.assumeIsolated {
                    guard let self, let session else { return }
                    self.note(.gridChange(hasContent: TerminalPaneFit.hasContent(session.grid)))
                }
            }
            .store(in: &subscriptions)
        // Seed with what is already true. An adopted session may hold replayed
        // content before this surface exists; the frame then completes the pair.
        note(.gridChange(hasContent: TerminalPaneFit.hasContent(session.grid)))
        note(.frame(ready: Self.hasFrame(view)))
    }

    private static func hasFrame(_ view: NSView) -> Bool {
        view.bounds.width > 0 && view.bounds.height > 0
    }

    private func note(_ event: TerminalPaneFit.AttachFit.Event) {
        guard fit.note(event) else { return }
        refit()
    }

    /// Deferred one turn: the frame notification arrives mid-layout, and the
    /// grid change arrives inside the parser / resize call. Running the pass
    /// after both have unwound means the size report sees the final frame and
    /// the render sees the final grid.
    private func refit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view else { return }
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            view.repaintNow()
        }
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
