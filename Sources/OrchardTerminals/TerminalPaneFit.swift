import Foundation

/// Geometry for snapping a terminal pane to whole cells and keeping scroll
/// stable across a row-count change.
///
/// Damson's grid is bottom-anchored: when the container is not a cell multiple,
/// the leftover fraction clips the first visible row. We never change the PTY
/// size to hide that remainder — we shrink the surface to the largest whole-cell
/// rect that fits and park the leftover pixels on the container. Short content
/// (document rows ≤ viewport rows) is top-aligned so row 0 is fully visible;
/// overflowing content is bottom-aligned so a follow-bottom prompt sits flush
/// with the pane bottom.
public enum TerminalPaneFit {

    public struct Metrics: Equatable {
        public var cellWidth: CGFloat
        public var cellHeight: CGFloat
        /// Damson-style inset: width is left+right each, height is top+bottom each.
        public var padding: CGSize

        public init(cellWidth: CGFloat, cellHeight: CGFloat, padding: CGSize) {
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
            self.padding = padding
        }
    }

    public struct Layout: Equatable {
        public var cols: Int
        public var rows: Int
        /// Snapped surface size (whole cells + padding). Never larger than the container.
        public var contentSize: CGSize
        /// Pixels left on the container after snapping. Not part of the PTY.
        public var leftover: CGSize

        public init(cols: Int, rows: Int, contentSize: CGSize, leftover: CGSize) {
            self.cols = cols
            self.rows = rows
            self.contentSize = contentSize
            self.leftover = leftover
        }
    }

    /// Largest whole-cell rect that fits in `container` after Damson padding.
    /// A pane smaller than one cell + padding cannot snap and fills the container.
    public static func layout(container: CGSize, metrics: Metrics) -> Layout {
        let cellW = max(metrics.cellWidth, 1)
        let cellH = max(metrics.cellHeight, 1)
        let padW = max(metrics.padding.width, 0)
        let padH = max(metrics.padding.height, 0)

        let usableW = max(container.width - padW * 2, 0)
        let usableH = max(container.height - padH * 2, 0)
        let cols = max(Int(floor(usableW / cellW)), 1)
        let rows = max(Int(floor(usableH / cellH)), 1)

        var contentW = CGFloat(cols) * cellW + padW * 2
        var contentH = CGFloat(rows) * cellH + padH * 2
        if contentW > container.width { contentW = max(container.width, 0) }
        if contentH > container.height { contentH = max(container.height, 0) }

        return Layout(
            cols: cols,
            rows: rows,
            contentSize: CGSize(width: contentW, height: contentH),
            leftover: CGSize(
                width: max(container.width - contentW, 0),
                height: max(container.height - contentH, 0)
            )
        )
    }

    /// Document rows that actually have content: scrollback plus the live
    /// viewport through `lastOccupiedViewportRow` (inclusive). Empty screens
    /// still count the prompt line so a new shell is treated as short content.
    public static func contentRowCount(scrollback: Int, lastOccupiedViewportRow: Int) -> Int {
        max(scrollback, 0) + max(lastOccupiedViewportRow, 0) + 1
    }

    /// Short content is top-aligned so the first row sits fully visible at the
    /// top. Overflow (scrollback, a filled grid) keeps the surface at the bottom.
    public static func shouldTopAlign(contentRows: Int, viewportRows: Int) -> Bool {
        contentRows <= max(viewportRows, 1)
    }

    /// Surface frame inside a flipped container (y = 0 is the top). Leftover
    /// width stays on the trailing edge; leftover height stays on the unused
    /// vertical edge so no partial cell is in the surface.
    public static func surfaceFrame(container: CGSize, layout: Layout, contentRows: Int) -> CGRect {
        let size = CGSize(
            width: min(layout.contentSize.width, max(container.width, 0)),
            height: min(layout.contentSize.height, max(container.height, 0))
        )
        let leftoverY = max(container.height - size.height, 0)
        let y: CGFloat = shouldTopAlign(contentRows: contentRows, viewportRows: layout.rows)
            ? 0
            : leftoverY
        return CGRect(x: 0, y: y, width: size.width, height: size.height)
    }

    /// Unified row that should sit at the top of the viewport after a resize.
    /// Bottom-following keeps the last `newViewportRows` of the document in
    /// view; otherwise `anchorLine` is preserved and clamped. A document that
    /// fits the new viewport always returns 0 (first row fully visible at top).
    public static func preservedTopLine(
        followingBottom: Bool,
        anchorLine: Int,
        contentRows: Int,
        newViewportRows: Int
    ) -> Int {
        let viewport = max(newViewportRows, 1)
        let content = max(contentRows, 0)
        if content <= viewport { return 0 }
        let maxTop = content - viewport
        if followingBottom { return maxTop }
        return min(max(anchorLine, 0), maxTop)
    }

    /// One-shot re-fit latch for a surface attaching to a session (T31 → T59).
    ///
    /// A fresh spawn's surface exists before anything is painted: its first
    /// `layout()` sizes the PTY, and the prompt paints into a grid that already
    /// matches the viewport. A keeper-adopted session is the other way round —
    /// its replay (`PTYHost.adopt` → next main-queue turn) and the child's
    /// post-SIGWINCH repaint can land while the surface has no frame yet, so the
    /// surface's own fit pass (size report, follow re-pin, dedupe-keyed render)
    /// ran against a placeholder geometry or never ran against that content at
    /// all. The same shape recurs when a window is re-opened over a live session
    /// (T51).
    ///
    /// The latch fires exactly once per surface, when BOTH facts hold: the
    /// surface has a real frame, and the grid holds painted content. Whichever
    /// arrives last triggers the re-fit; a resize's own contentless
    /// `gridChanged` never counts as a paint. After it fires, later changes use
    /// the ordinary path without a special case.
    public struct AttachFit: Equatable {
        public enum Event: Equatable {
            /// The surface's frame changed; `ready` is "non-zero width and height".
            case frame(ready: Bool)
            /// The session's grid changed; `hasContent` is "something is painted".
            case gridChange(hasContent: Bool)
        }

        private var frameReady = false
        private var contentSeen = false
        private var fired = false

        public init() {}

        public var isPending: Bool { !fired }

        /// Record an event. True exactly once — the moment a framed surface has
        /// painted content to fit.
        public mutating func note(_ event: Event) -> Bool {
            switch event {
            case .frame(let ready):
                frameReady = ready
            case .gridChange(let hasContent):
                if hasContent { contentSeen = true }
            }
            guard !fired, frameReady, contentSeen else { return false }
            fired = true
            return true
        }
    }
}
