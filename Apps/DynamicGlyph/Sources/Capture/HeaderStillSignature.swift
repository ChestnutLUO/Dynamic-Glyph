import GlyphRecognition

/// The `headerStillSkip` cut's picture of the header: the mean grey level of
/// each cell of a grid laid over `HeaderTextRecognizer.headerRect`. Two
/// signatures of frames of the same size that differ by at most `tolerance`
/// grey levels on average show a still header, whose text a read would
/// return unchanged.
///
/// The grid, the cell rule and the tolerance were measured on the Y plane of
/// six English recordings at 602, 603, 880 and 1206 pixels wide. Two frames of different phases within
/// 2 s differed by at least 21.1 grey levels (7,823 pairs); successive frames
/// with the same text by p50 0.00, p99 5.59 and at most 17, 93.8% within 1.0.
/// A tolerance of 1.0 against the last real read, forced again at 1 s,
/// skipped 74% of in-hack reads and 38% outside, with no wrong phase and no
/// frame late over 15 phase changes. Grey comes here from the RGB the engine
/// hands over, by the luma gate's weights, not from the Y plane: on those
/// recordings the same grid compared across the Y plane and Core Graphics grey changed
/// its template counts by at most one read. No readable Japanese or Chinese
/// header has been measured: the method does not depend on the script, but
/// its margins there are inferred.
struct HeaderStillSignature: Equatable, Sendable {
    static let columns = 160
    static let rows = 16
    /// Mean absolute difference over the grid, in grey levels, at or below
    /// which a header is still.
    static let tolerance = 1.0

    /// The grid itself, built by `StillSignature`'s cell rule.
    let grid: StillSignature
    var frameWidth: Int { grid.frameWidth }
    var frameHeight: Int { grid.frameHeight }
    /// `columns` x `rows` cell means, row by row.
    var cells: [UInt8] { grid.cells }

    /// The grid over `rows` of `pixels`, packed RGB `width` pixels wide with
    /// no padding, from a frame of `frameWidth` by `frameHeight`. A cell is
    /// the integer mean of its pixels, cell edges at `index * size / count`,
    /// and at least one pixel wide and tall, as it was measured. Nil
    /// when the rows are empty or not all in `pixels`.
    init?(rgb pixels: [UInt8], width: Int, rows: Range<Int>, frameWidth: Int, frameHeight: Int) {
        guard let grid = StillSignature(rgb: pixels, width: width, rows: rows, frameWidth: frameWidth,
                                        frameHeight: frameHeight, columns: Self.columns, gridRows: Self.rows) else {
            return nil
        }
        self.grid = grid
    }

    /// The mean absolute difference between the two grids, in grey levels;
    /// nil for frames of different sizes, which never compare as still.
    func meanDifference(from other: HeaderStillSignature) -> Double? {
        grid.meanDifference(from: other.grid)
    }

    func isStill(comparedWith other: HeaderStillSignature) -> Bool {
        grid.isStill(comparedWith: other.grid, tolerance: Self.tolerance)
    }

    // MARK: - The headerWindowMask cut

    /// Pixels the window's rectangle grows by on every side before its
    /// cells are left out: its anti-aliased corners and edge.
    static let windowPadding = 2
    /// Most pixels any edge of the window may move between the anchor's
    /// frame and this one. Found windows stood within 3 px from frame to
    /// frame in 97 to 100% of each measured recording; more is a move or a
    /// misplaced edge, and the whole header is compared.
    static let windowShift = 2
    /// Least share of the grid's cells the window may leave. Under it too
    /// little of the header shows to see a change, and the look reads.
    static let minimumKeptShare = 0.15

    /// Whether the header is still against `other` once the cells under the
    /// app's own window are left out: `window` found in this frame,
    /// `otherWindow` in the other's, both in frame pixels, the grid laid
    /// over `rows` of frames `frameWidth` wide. The two windows must stand
    /// within `windowShift` of each other; their union, grown by
    /// `windowPadding`, is left out, and at least `minimumKeptShare` of the
    /// cells must remain. False otherwise, and when the window misses the
    /// header: the whole grid has already been compared then.
    func isStill(comparedWith other: HeaderStillSignature, outside window: FloatingWindowFinder.Window,
                 otherWindow: FloatingWindowFinder.Window, rows: Range<Int>) -> Bool {
        guard window.shift(from: otherWindow) <= Self.windowShift else { return false }
        let covered = window.union(otherWindow)
        let padding = Self.windowPadding
        guard let mask = StillCellMask(columns: Self.columns, rows: Self.rows, width: frameWidth, height: rows.count,
                                       left: covered.left - padding, top: covered.top - padding - rows.lowerBound,
                                       right: covered.right + padding,
                                       bottom: covered.bottom + padding - rows.lowerBound) else { return false }
        return grid.isStill(comparedWith: other.grid, tolerance: Self.tolerance, excluding: mask,
                            minimumKeptShare: Self.minimumKeptShare)
    }
}
