/// A picture of one rectangle of a frame that tells whether it has changed:
/// the mean grey level of each cell of a grid laid over it. Two signatures
/// of the same grid over frames of the same size, compared by their mean
/// absolute difference, show a still rectangle when that difference is
/// within a tolerance measured for what the rectangle holds.
///
/// The cell rule is the one the header measurements used: cell edges at
/// `index * size / count`, every cell at least one pixel wide and tall, and
/// a cell's grey the integer mean of its pixels' grey. Its first user is the
/// `headerStillSkip` cut's header grid; it takes any grid over any rectangle.
public struct StillSignature: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let frameWidth: Int
    public let frameHeight: Int
    /// `columns` x `rows` cell means, row by row.
    public let cells: [UInt8]

    /// The grid over a region `width` pixels wide and `height` tall, of a
    /// frame `frameWidth` by `frameHeight`. `rowSum(y, left, right)` is the
    /// summed grey of the region's row `y` from column `left` up to `right`,
    /// both relative to the region. Nil for an empty region or grid.
    public init?(columns: Int, rows: Int, width: Int, height: Int, frameWidth: Int, frameHeight: Int,
                 rowSum: (_ y: Int, _ left: Int, _ right: Int) -> Int) {
        guard columns > 0, rows > 0, width > 0, height > 0 else { return nil }
        var cells = [UInt8](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let top = row * height / rows
            let bottom = max(top + 1, (row + 1) * height / rows)
            for column in 0..<columns {
                let left = column * width / columns
                let right = max(left + 1, (column + 1) * width / columns)
                var sum = 0
                for y in top..<bottom { sum += rowSum(y, left, right) }
                cells[row * columns + column] = UInt8(sum / ((bottom - top) * (right - left)))
            }
        }
        self.columns = columns
        self.rows = rows
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.cells = cells
    }

    /// The grid over `rows` of `pixels`, packed RGB `width` pixels wide with
    /// no padding, from a frame of `frameWidth` by `frameHeight`. Grey is the
    /// luma gate's: `LumaGate`'s fixed-point BT.601 weights. Nil when the rows
    /// are empty or not all in `pixels`.
    public init?(rgb pixels: [UInt8], width: Int, rows: Range<Int>, frameWidth: Int, frameHeight: Int,
                 columns: Int, gridRows: Int) {
        guard width > 0, !rows.isEmpty, rows.lowerBound >= 0,
              pixels.count >= rows.upperBound * width * 3 else { return nil }
        let signature: StillSignature? = pixels.withUnsafeBufferPointer { rgb in
            StillSignature(columns: columns, rows: gridRows, width: width, height: rows.count,
                           frameWidth: frameWidth, frameHeight: frameHeight) { y, left, right in
                var sum = 0
                var index = ((rows.lowerBound + y) * width + left) * 3
                for _ in left..<right {
                    sum += (77 * Int(rgb[index]) + 150 * Int(rgb[index + 1]) + 29 * Int(rgb[index + 2])) >> 8
                    index += 3
                }
                return sum
            }
        }
        guard let signature else { return nil }
        self = signature
    }

    /// The mean absolute difference between the two grids, in grey levels;
    /// nil for another grid or frames of different sizes, which never
    /// compare as still.
    public func meanDifference(from other: StillSignature) -> Double? {
        guard columns == other.columns, rows == other.rows, frameWidth == other.frameWidth,
              frameHeight == other.frameHeight, cells.count == other.cells.count, !cells.isEmpty else { return nil }
        var sum = 0
        for index in cells.indices { sum += abs(Int(cells[index]) - Int(other.cells[index])) }
        return Double(sum) / Double(cells.count)
    }

    /// Within `tolerance` grey levels on average of `other`.
    public func isStill(comparedWith other: StillSignature, tolerance: Double) -> Bool {
        meanDifference(from: other).map { $0 <= tolerance } ?? false
    }

    /// The mean absolute difference over the cells `mask` keeps; nil for
    /// another grid, frames of different sizes, a mask of another grid, or
    /// a mask that keeps no cell.
    public func meanDifference(from other: StillSignature, excluding mask: StillCellMask) -> Double? {
        guard mask.columns == columns, mask.rows == rows, mask.keptCount > 0,
              meanDifference(from: other) != nil else { return nil }
        var sum = 0
        for index in cells.indices where !mask.excluded[index] {
            sum += abs(Int(cells[index]) - Int(other.cells[index]))
        }
        return Double(sum) / Double(mask.keptCount)
    }

    /// Within `tolerance` grey levels on average of `other` over the cells
    /// `mask` keeps, when it keeps at least `minimumKeptShare` of them. A
    /// mask that keeps fewer is not still: too few cells are left to see a
    /// change.
    public func isStill(comparedWith other: StillSignature, tolerance: Double, excluding mask: StillCellMask,
                        minimumKeptShare: Double) -> Bool {
        guard mask.keptShare >= minimumKeptShare else { return false }
        return meanDifference(from: other, excluding: mask).map { $0 <= tolerance } ?? false
    }
}

/// Cells of a `StillSignature` grid left out of a comparison: those a
/// rectangle of the grid's region touches, by the grid's own cell rule.
public struct StillCellMask: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// `columns` x `rows` flags, row by row; true for a cell left out.
    public let excluded: [Bool]
    /// Cells the comparison keeps.
    public let keptCount: Int
    /// The share of the grid's cells the comparison keeps.
    public var keptShare: Double { Double(keptCount) / Double(columns * rows) }

    /// The cells of a `columns` x `rows` grid over a region `width` by
    /// `height` that the rectangle from `left`, `top` up to `right`,
    /// `bottom` (exclusive, in the region's pixels, any of them outside it)
    /// touches. Nil for an empty grid or region, or a rectangle that touches
    /// no cell.
    public init?(columns: Int, rows: Int, width: Int, height: Int,
                 left: Int, top: Int, right: Int, bottom: Int) {
        guard columns > 0, rows > 0, width > 0, height > 0 else { return nil }
        var excluded = [Bool](repeating: false, count: columns * rows)
        var count = 0
        for row in 0..<rows {
            let cellTop = row * height / rows
            let cellBottom = max(cellTop + 1, (row + 1) * height / rows)
            guard cellTop < bottom, cellBottom > top else { continue }
            for column in 0..<columns {
                let cellLeft = column * width / columns
                let cellRight = max(cellLeft + 1, (column + 1) * width / columns)
                guard cellLeft < right, cellRight > left else { continue }
                excluded[row * columns + column] = true
                count += 1
            }
        }
        guard count > 0 else { return nil }
        self.columns = columns
        self.rows = rows
        self.excluded = excluded
        self.keptCount = columns * rows - count
    }
}
