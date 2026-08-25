import XCTest
@testable import OrchardTerminals

/// T30: row-fit snapping and scroll-anchor preservation are pure geometry — they
/// must not depend on a live Damson surface. The container uses these numbers to
/// pad around the PTY, never to resize it.
final class TerminalPaneFitTests: XCTestCase {

    private let cell = TerminalPaneFit.Metrics(
        cellWidth: 8, cellHeight: 16, padding: CGSize(width: 4, height: 4))

    // MARK: - Cell snapping

    func testSnapsHeightToWholeCellsAndParksRemainderOnTheContainer() {
        // 8pt padding top+bottom = 8; 10.5 cells of usable height → 10 rows.
        let container = CGSize(width: 80 + 8, height: 16 * 10 + 8 + 8) // 8pt leftover
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        XCTAssertEqual(layout.cols, 10)
        XCTAssertEqual(layout.rows, 10)
        XCTAssertEqual(layout.contentSize.height, 16 * 10 + 8)
        XCTAssertEqual(layout.leftover.height, 8)
        XCTAssertEqual(
            (layout.contentSize.height - cell.padding.height * 2)
                .truncatingRemainder(dividingBy: cell.cellHeight),
            0,
            "snapped height must be a whole number of cells plus padding")
    }

    func testSnapsWidthTheSameWay() {
        let container = CGSize(width: 8 * 12 + 8 + 3, height: 16 * 5 + 8)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        XCTAssertEqual(layout.cols, 12)
        XCTAssertEqual(layout.leftover.width, 3)
        XCTAssertEqual(
            (layout.contentSize.width - cell.padding.width * 2)
                .truncatingRemainder(dividingBy: cell.cellWidth),
            0)
    }

    func testExactMultipleLeavesNoRemainder() {
        let container = CGSize(width: 8 * 20 + 8, height: 16 * 7 + 8)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        XCTAssertEqual(layout.cols, 20)
        XCTAssertEqual(layout.rows, 7)
        XCTAssertEqual(layout.leftover, .zero)
    }

    func testTinyPaneStillReportsOneCellAndFillsTheContainer() {
        let container = CGSize(width: 10, height: 10)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        XCTAssertEqual(layout.cols, 1)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.contentSize, container)
        XCTAssertEqual(layout.leftover, .zero)
    }

    func testZeroContainerDoesNotGoNegative() {
        let layout = TerminalPaneFit.layout(container: .zero, metrics: cell)
        XCTAssertEqual(layout.cols, 1)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.contentSize, .zero)
    }

    // MARK: - Top-align short content

    func testShortContentTopAlignsSoTheFirstRowIsFullyVisible() {
        let container = CGSize(width: 88, height: 16 * 10 + 8 + 5)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        let contentRows = TerminalPaneFit.contentRowCount(
            scrollback: 0, lastOccupiedViewportRow: 0)
        XCTAssertTrue(TerminalPaneFit.shouldTopAlign(
            contentRows: contentRows, viewportRows: layout.rows))
        let frame = TerminalPaneFit.surfaceFrame(
            container: container, layout: layout, contentRows: contentRows)
        XCTAssertEqual(frame.origin, .zero, "row 0 must sit at the top of the pane")
        XCTAssertEqual(frame.height, layout.contentSize.height)
        XCTAssertLessThan(frame.maxY, container.height)
    }

    func testFilledGridThatFitsStillTopAligns() {
        let container = CGSize(width: 88, height: 16 * 10 + 8 + 5)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        let contentRows = TerminalPaneFit.contentRowCount(
            scrollback: 0, lastOccupiedViewportRow: layout.rows - 1)
        XCTAssertEqual(contentRows, layout.rows)
        XCTAssertTrue(TerminalPaneFit.shouldTopAlign(
            contentRows: contentRows, viewportRows: layout.rows))
        let frame = TerminalPaneFit.surfaceFrame(
            container: container, layout: layout, contentRows: contentRows)
        XCTAssertEqual(frame.origin.y, 0)
    }

    func testOverflowingContentBottomAlignsTheSurface() {
        let container = CGSize(width: 88, height: 16 * 10 + 8 + 5)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        let contentRows = TerminalPaneFit.contentRowCount(
            scrollback: 40, lastOccupiedViewportRow: layout.rows - 1)
        XCTAssertFalse(TerminalPaneFit.shouldTopAlign(
            contentRows: contentRows, viewportRows: layout.rows))
        let frame = TerminalPaneFit.surfaceFrame(
            container: container, layout: layout, contentRows: contentRows)
        XCTAssertEqual(frame.origin.y, layout.leftover.height)
        XCTAssertEqual(frame.maxY, container.height)
    }

    func testContentRowCountCountsThePromptLineOnAnEmptyScreen() {
        XCTAssertEqual(
            TerminalPaneFit.contentRowCount(scrollback: 0, lastOccupiedViewportRow: 0),
            1)
        XCTAssertEqual(
            TerminalPaneFit.contentRowCount(scrollback: 3, lastOccupiedViewportRow: 4),
            8)
    }

    // MARK: - Anchor preservation

    func testFollowBottomKeepsTheLastRowsVisible() {
        let top = TerminalPaneFit.preservedTopLine(
            followingBottom: true, anchorLine: 12,
            contentRows: 100, newViewportRows: 20)
        XCTAssertEqual(top, 80)
    }

    func testScrolledUpPreservesTheAnchorLine() {
        let top = TerminalPaneFit.preservedTopLine(
            followingBottom: false, anchorLine: 15,
            contentRows: 100, newViewportRows: 20)
        XCTAssertEqual(top, 15)
    }

    func testAnchorIsClampedWhenTheViewportGrowsPastIt() {
        let top = TerminalPaneFit.preservedTopLine(
            followingBottom: false, anchorLine: 90,
            contentRows: 100, newViewportRows: 30)
        XCTAssertEqual(top, 70)
    }

    func testNegativeAnchorClampsToTheTop() {
        let top = TerminalPaneFit.preservedTopLine(
            followingBottom: false, anchorLine: -4,
            contentRows: 50, newViewportRows: 10)
        XCTAssertEqual(top, 0)
    }

    func testShortDocumentAlwaysPinsToRowZeroAcrossResize() {
        XCTAssertEqual(
            TerminalPaneFit.preservedTopLine(
                followingBottom: true, anchorLine: 9,
                contentRows: 4, newViewportRows: 24),
            0)
        XCTAssertEqual(
            TerminalPaneFit.preservedTopLine(
                followingBottom: false, anchorLine: 2,
                contentRows: 8, newViewportRows: 20),
            0)
    }

    func testGrowingTheViewportWhileFollowingBottomRewindsTheTopLine() {
        let before = TerminalPaneFit.preservedTopLine(
            followingBottom: true, anchorLine: 0,
            contentRows: 80, newViewportRows: 20)
        let after = TerminalPaneFit.preservedTopLine(
            followingBottom: true, anchorLine: before,
            contentRows: 80, newViewportRows: 30)
        XCTAssertEqual(before, 60)
        XCTAssertEqual(after, 50)
    }

    // MARK: - Attach re-fit (T31 → T59)

    /// Fresh spawn order: the surface is framed while the grid is still empty,
    /// the size report's own grid-change carries no paint, and the prompt paint
    /// is what completes the pair.
    func testAttachFitFiresOnTheFirstPaintIntoAFramedSurface() {
        var fit = TerminalPaneFit.AttachFit()
        XCTAssertTrue(fit.isPending)
        XCTAssertFalse(fit.note(.frame(ready: true)), "a frame with nothing painted has nothing to fit")
        XCTAssertFalse(fit.note(.gridChange(hasContent: false)),
                       "a resize's own grid-change on an empty grid is not a paint")
        XCTAssertTrue(fit.note(.gridChange(hasContent: true)),
                      "the first paint into a framed surface re-runs the fit pass")
        XCTAssertFalse(fit.isPending)
        XCTAssertFalse(fit.note(.gridChange(hasContent: true)),
                       "later paints use the ordinary path, not a second latch")
        XCTAssertFalse(fit.note(.frame(ready: true)), "nor do later frame changes")
    }

    /// Keeper-adoption order: the replay and the child's post-SIGWINCH repaint
    /// are parsed before the surface has a frame. Content alone must not fire —
    /// there is no geometry to fit against yet — and a zero frame is no frame.
    func testAttachFitDefersToTheFrameWhenContentLandedFirst() {
        var fit = TerminalPaneFit.AttachFit()
        XCTAssertFalse(fit.note(.gridChange(hasContent: true)))
        XCTAssertFalse(fit.note(.frame(ready: false)))
        XCTAssertTrue(fit.isPending)
        XCTAssertTrue(fit.note(.frame(ready: true)),
                      "the frame completing the pair re-fits the already-painted grid")
        XCTAssertFalse(fit.isPending)
    }

    func testAttachFitIgnoresContentlessChurnBeforeTheFirstPaint() {
        var fit = TerminalPaneFit.AttachFit()
        XCTAssertFalse(fit.note(.frame(ready: true)))
        for _ in 0..<5 {
            XCTAssertFalse(fit.note(.gridChange(hasContent: false)))
        }
        XCTAssertTrue(fit.isPending, "the adoption jiggle's resizes must not spend the latch")
    }

    /// A frame that comes and goes (the surface hidden, then shown) before any
    /// paint still fires exactly once, on the paint.
    func testAttachFitTracksTheLatestFrameState() {
        var fit = TerminalPaneFit.AttachFit()
        XCTAssertFalse(fit.note(.frame(ready: true)))
        XCTAssertFalse(fit.note(.frame(ready: false)))
        XCTAssertFalse(fit.note(.gridChange(hasContent: true)),
                       "content while unframed waits for a frame")
        XCTAssertTrue(fit.note(.frame(ready: true)))
    }

    func testEmptyPreReplayGridTopAlignsThenShortReplayStaysTopAligned() {
        let container = CGSize(width: 88, height: 16 * 10 + 8 + 5)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)

        // Pre-replay: empty parser, prompt line only — same as a fresh pane.
        let empty = TerminalPaneFit.contentRowCount(
            scrollback: 0, lastOccupiedViewportRow: 0)
        XCTAssertTrue(TerminalPaneFit.shouldTopAlign(
            contentRows: empty, viewportRows: layout.rows))
        XCTAssertEqual(
            TerminalPaneFit.surfaceFrame(
                container: container, layout: layout, contentRows: empty).origin,
            .zero)

        // First paint after attach: keeper preamble + a short shell prompt at row 0.
        var fit = TerminalPaneFit.AttachFit()
        XCTAssertFalse(fit.note(.frame(ready: true)))
        XCTAssertTrue(fit.note(.gridChange(hasContent: true)))
        let short = TerminalPaneFit.contentRowCount(
            scrollback: 0, lastOccupiedViewportRow: 0)
        let frame = TerminalPaneFit.surfaceFrame(
            container: container, layout: layout, contentRows: short)
        XCTAssertEqual(frame.origin.y, 0, "row 0 must stay fully visible after replay")
        XCTAssertEqual(frame.height, layout.contentSize.height)
        XCTAssertGreaterThan(layout.leftover.height, 0)
        XCTAssertLessThan(frame.maxY, container.height)
    }
}
