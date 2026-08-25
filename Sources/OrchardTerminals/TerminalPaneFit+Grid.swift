import DamsonTerminal
import Foundation

/// The grid-reading half of the pane fit: how many document rows carry content,
/// and whether anything has been painted at all. Lives here (not in the app) so
/// a test can drive a headless `DamsonSession` through the adoption sequence
/// and read the exact numbers `TerminalFitHost` decides from.
extension TerminalPaneFit {

    /// Document rows that have content, as the host reads them: scrollback plus
    /// the live viewport through the last non-blank row (or the cursor row,
    /// whichever is lower). An empty screen still counts its prompt line.
    public static func contentRows(in grid: Grid) -> Int {
        var lastOccupied = max(grid.cursorRow, 0)
        for r in stride(from: grid.rows - 1, through: 0, by: -1) {
            if grid.row(r).contains(where: { $0.char != " " }) {
                lastOccupied = max(lastOccupied, r)
                break
            }
        }
        return contentRowCount(
            scrollback: grid.scrollback.count,
            lastOccupiedViewportRow: lastOccupied)
    }

    /// Whether anything has been painted: scrollback, a non-blank viewport cell,
    /// or a cursor that left the home row. A resize's own `gridChanged` on an
    /// empty grid is not a paint — `AttachFit` must not fire on it.
    public static func hasContent(_ grid: Grid) -> Bool {
        if !grid.scrollback.isEmpty || grid.cursorRow > 0 { return true }
        for r in 0..<max(grid.rows, 0) where grid.row(r).contains(where: { $0.char != " " }) {
            return true
        }
        return false
    }
}
