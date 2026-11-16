/// One run of indicator-coloured columns in the slot strip.
struct StripMarker {
    let range: ClosedRange<Int>
    let gold: Int
    let violet: Int
}

/// What a strip read found: the full reading or why there is none, and,
/// when our own floating window covers one side of the row, what still
/// shows beside it.
public struct SlotStripObservation: Sendable, Equatable {
    public let reading: Result<SlotStripReading, SlotStripRejection>
    public let cover: SlotStripWindowCover?

    public init(reading: Result<SlotStripReading, SlotStripRejection>, cover: SlotStripWindowCover?) {
        self.reading = reading
        self.cover = cover
    }
}

/// Our own floating window over one side of the slot row, and what shows
/// beside it. Nothing here is a full reading: the slot count, the
/// presentation and a new hack are never read from it.
public struct SlotStripWindowCover: Sendable, Equatable {
    public enum Side: String, Sendable, Equatable {
        case left, right
    }

    /// The frame edge the window covers the row up to.
    public let side: Side
    /// The covered columns, as fractions of the frame width: from the
    /// frame's left edge or the window's side, to the window's side or the
    /// frame's right edge.
    public let coveredFrom: Double
    public let coveredTo: Double
    /// The indicators outside the covered columns, when they pass the
    /// ordinary width, height and colour rules.
    public let row: PartialSlotStripReading?
    /// The countdown's rail runs from its visible end to the window with
    /// progress on it: the input countdown, its far end under the window.
    public let hasPartialInputTimerBar: Bool

    public init(side: Side, coveredFrom: Double, coveredTo: Double, row: PartialSlotStripReading?,
                hasPartialInputTimerBar: Bool) {
        self.side = side
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
        self.row = row
        self.hasPartialInputTimerBar = hasPartialInputTimerBar
    }
}

/// The indicators that show beside our own window over one side of the row.
///
/// The reader does not say how many slots the row has: only a count known
/// from full readings can place these markers (`resolved(slotCount:)`).
public struct PartialSlotStripReading: Sendable, Equatable {
    /// Visible indicator centres, as fractions of the frame width, left to right.
    public let markerCentersX: [Double]
    /// The highlighted one among `markerCentersX`, if one is.
    public let highlightedMarker: Int?
    /// The covered columns, as `SlotStripWindowCover` gives them.
    public let coveredFrom: Double
    public let coveredTo: Double
    /// The row's geometry, `GameUILayout.slotCenterPitch` and
    /// `slotCenterTolerance` of the layout it was read with.
    public let centerPitch: Double
    public let centerTolerance: Double

    public init(markerCentersX: [Double], highlightedMarker: Int?, coveredFrom: Double, coveredTo: Double,
                centerPitch: Double = GameUILayout().slotCenterPitch,
                centerTolerance: Double = GameUILayout().slotCenterTolerance) {
        self.markerCentersX = markerCentersX
        self.highlightedMarker = highlightedMarker
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
        self.centerPitch = centerPitch
        self.centerTolerance = centerTolerance
    }

    /// Where the visible indicators sit in a row of `slotCount`.
    public struct Resolution: Sendable, Equatable {
        /// The slot of each visible indicator, left to right.
        public let slotIndices: [Int]
        /// The slot of the highlighted visible indicator. Nil when no
        /// visible indicator is highlighted: the highlight may be under the
        /// window, and which hidden slot it is on is unknown.
        public let highlightedIndex: Int?
    }

    /// The visible indicators placed in a centred row of `slotCount`, or nil
    /// when they cannot be: every visible centre must sit on that row's
    /// grid, and every position without a visible indicator must lie inside
    /// the covered columns.
    public func resolved(slotCount: Int) -> Resolution? {
        guard slotCount >= 1, slotCount <= SequenceTable.maximumLength, !markerCentersX.isEmpty,
              markerCentersX.count <= slotCount else { return nil }
        let midpoint = Double(slotCount - 1) / 2
        func expected(_ index: Int) -> Double { 0.5 + (Double(index) - midpoint) * centerPitch }
        var indices: [Int] = []
        for center in markerCentersX {
            guard let index = (0..<slotCount).first(where: { abs(center - expected($0)) <= centerTolerance }),
                  index > (indices.last ?? -1) else { return nil }
            indices.append(index)
        }
        for index in 0..<slotCount where !indices.contains(index) {
            let position = expected(index)
            guard position >= coveredFrom, position <= coveredTo else { return nil }
        }
        if let highlightedMarker, !indices.indices.contains(highlightedMarker) { return nil }
        return Resolution(slotIndices: indices, highlightedIndex: highlightedMarker.map { indices[$0] })
    }
}

extension SlotStripReader {
    /// A side of the window lights a strip column in at least this share of
    /// the strip's rows. The game's indicators, highlight and glow
    /// included, light at most 0.74 of them in a field report with a window
    /// over the strip.
    static let windowSideRowShare = 0.9
    /// The thinnest window side, as a share of the strip's height: a window
    /// covering the strip is at least as tall as the strip, and its ring is
    /// at least 0.04 of its height (`FloatingWindowFinder.ringRatio`).
    static let windowSideMinimumShare = 0.04
    /// The thickest window side, as a share of the frame width. That report's
    /// window, 0.16 of the frame tall, had a side 16 px of 603 wide (0.027).
    static let windowSideMaximumWidth = 0.06
    /// Columns the window may keep from the frame edge, as a share of the
    /// width. That report's window ended 16 px of 603 from the edge (0.027).
    static let windowInset = 0.05
    /// Largest channel distance from the side's colour for a pixel of it.
    static let windowSideColourTolerance = 24
    /// Least amount the interior's median grey stays below the side's grey,
    /// as `FloatingWindowFinder.interiorContrast`.
    static let windowInteriorContrast = 40
    /// Columns between the side's last lit column and the interior sampled
    /// beyond it. The ring's inner boundary falls between pixels: the pixel
    /// it crosses blends ring and interior, and is lit or not depending on
    /// the ring's colour and where the boundary falls. A frame resampled by
    /// up to a pixel, as a recording scaled back to the capture size is,
    /// spreads the boundary over at most one more such pixel. The grey ring
    /// of that report, in its native 602 px video, left a blend
    /// column of grey 45 unlit beside a ring of grey 79; the interior past
    /// it is grey 28.
    static let windowSideBlendColumns = 1

    static func grey(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Int {
        (77 * Int(red) + 150 * Int(green) + 29 * Int(blue)) >> 8
    }

    /// Our own floating window over one side of the row, found from the
    /// strip's column statistics, with the markers beside it and the
    /// countdown's visible part.
    ///
    /// A side of the window is a vertical edge: a run of columns lit through
    /// the strip's height in one smooth ring colour, with the darker
    /// interior beyond it, and a lit column within the window's inset of the
    /// frame edge, its far side. The game's indicators never light a column
    /// through the strip's height. Lit columns within the inset of both
    /// edges, a side too thin or thick, a colour that changes down the
    /// column or an interior as bright as the ring are no window here. The
    /// interior is sampled past the column the ring's boundary blends into
    /// (`windowSideBlendColumns`).
    func windowCover(_ band: FrameTopBand, rows: Range<Int>, litColumns: [Int], markers: [StripMarker],
                     firstRows: [Int], lastRows: [Int]) -> SlotStripWindowCover? {
        let image = band.image
        let width = image.width
        let required = Int((Self.windowSideRowShare * Double(rows.count)).rounded(.up))
        func isSide(_ x: Int) -> Bool { litColumns[x] >= required }
        let inset = Int(Self.windowInset * Double(width))
        guard width > 2 * (inset + 1) else { return nil }
        let right = ((width - 1 - inset)..<width).contains(where: isSide)
        let left = (0...inset).contains(where: isSide)
        guard right != left else { return nil }
        let side: SlotStripWindowCover.Side = right ? .right : .left

        // The window's side nearest the middle: the innermost lit-through
        // column and the run it belongs to.
        var near: ClosedRange<Int>
        if side == .right {
            guard let first = (0..<width).first(where: isSide) else { return nil }
            var last = first
            while last + 1 < width, isSide(last + 1) { last += 1 }
            near = first...last
        } else {
            guard let last = (0..<width).last(where: isSide) else { return nil }
            var first = last
            while first > 0, isSide(first - 1) { first -= 1 }
            near = first...last
        }
        let thinnest = max(2, Int((Self.windowSideMinimumShare * Double(rows.count)).rounded(.up)))
        let thickest = Int(Self.windowSideMaximumWidth * Double(width))
        guard near.count >= thinnest, near.count <= thickest else { return nil }
        let skip = Self.windowSideBlendColumns
        let interior = side == .right ? [near.upperBound + skip + 1, near.upperBound + skip + 2]
                                      : [near.lowerBound - skip - 1, near.lowerBound - skip - 2]
        guard interior.allSatisfy({ $0 >= 0 && $0 < width }) else { return nil }

        // One colour down the side's middle column.
        let middle = (near.lowerBound + near.upperBound) / 2
        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        for y in rows {
            let (r, g, b) = image[middle, y]
            reds.append(r); greens.append(g); blues.append(b)
        }
        let ring = (Self.median(reds), Self.median(greens), Self.median(blues))
        let tolerance = Self.windowSideColourTolerance
        let smooth = rows.filter { y in
            let (r, g, b) = image[middle, y]
            return abs(Int(r) - Int(ring.0)) <= tolerance && abs(Int(g) - Int(ring.1)) <= tolerance
                && abs(Int(b) - Int(ring.2)) <= tolerance
        }.count
        guard smooth >= required else { return nil }

        // A darker interior beyond the blended boundary.
        var interiorGreys: [Int] = []
        for x in interior {
            for y in rows {
                let (r, g, b) = image[x, y]
                interiorGreys.append(Self.grey(r, g, b))
            }
        }
        interiorGreys.sort()
        let interiorGrey = interiorGreys[interiorGreys.count / 2]
        guard interiorGrey <= Self.grey(ring.0, ring.1, ring.2) - Self.windowInteriorContrast else { return nil }

        let covered = side == .right ? near.lowerBound...(width - 1) : 0...near.upperBound
        let coveredFrom = Double(covered.lowerBound) / Double(width)
        let coveredTo = Double(covered.upperBound + 1) / Double(width)
        return SlotStripWindowCover(
            side: side, coveredFrom: coveredFrom, coveredTo: coveredTo,
            row: rowBeside(covered, band: band, markers: markers, firstRows: firstRows, lastRows: lastRows,
                           coveredFrom: coveredFrom, coveredTo: coveredTo),
            hasPartialInputTimerBar: hasPartialTimerBar(band, covered: covered, side: side))
    }

    /// The markers wholly outside the covered columns, held to the ordinary
    /// width, height and single-highlight rules. A marker reaching into the
    /// covered columns is the window's own. Nil when none shows or one fails.
    private func rowBeside(_ covered: ClosedRange<Int>, band: FrameTopBand, markers: [StripMarker],
                           firstRows: [Int], lastRows: [Int], coveredFrom: Double,
                           coveredTo: Double) -> PartialSlotStripReading? {
        let width = band.image.width
        let visible = markers.filter { $0.range.upperBound < covered.lowerBound || $0.range.lowerBound > covered.upperBound }
        guard !visible.isEmpty, visible.count <= SequenceTable.maximumLength else { return nil }
        let minimumWidth = layout.slotMarkerMinimumWidth * Double(width)
        let maximumWidth = layout.slotMarkerMaximumWidth * Double(width)
        for marker in visible {
            let markerWidth = Double(marker.range.count)
            guard markerWidth >= minimumWidth, markerWidth <= maximumWidth else { return nil }
            let top = marker.range.map { firstRows[$0] }.min() ?? band.image.height
            let bottom = marker.range.map { lastRows[$0] }.max() ?? -1
            guard Double(bottom - top + 1) >= markerWidth * 0.8 else { return nil }
        }
        let highlights = visible.indices.filter { visible[$0].gold > visible[$0].violet }
        guard highlights.count <= 1 else { return nil }
        let centers = visible.map { (Double($0.range.lowerBound) + Double($0.range.upperBound)) / 2 / Double(width) }
        return PartialSlotStripReading(markerCentersX: centers, highlightedMarker: highlights.first,
                                       coveredFrom: coveredFrom, coveredTo: coveredTo,
                                       centerPitch: layout.slotCenterPitch, centerTolerance: layout.slotCenterTolerance)
    }

    /// The countdown with its far end under the window: on one row, a run of
    /// rail starting at the rail's visible end, unbroken but for the timer
    /// bar's small gaps up to the window's side, with a progress run as long
    /// as `hasTimerBar` requires. The empty rail drawn before input has no
    /// progress, and label text has gaps.
    func hasPartialTimerBar(_ band: FrameTopBand, covered: ClosedRange<Int>, side: SlotStripWindowCover.Side) -> Bool {
        let rows = band.rows(layout.inputTimerBarTop, layout.inputTimerBarBottom)
        guard !rows.isEmpty else { return false }
        let image = band.image
        let width = image.width
        let required = Int(layout.inputTimerBarMinimumWidth * Double(width))
        let tolerance = layout.inputTimerEndpointTolerance * Double(width)
        let expectedStart = (side == .right ? layout.inputTimerTrackLeft : layout.inputTimerTrackRight)
            * Double(width)
        let maximumGap = max(1, Int(Double(width) * 0.005))
        // Columns walked from the visible end towards the window.
        let step = side == .right ? 1 : -1
        for y in rows {
            var start: Int?
            var last = 0
            var progressRun = 0, longestProgressRun = 0
            func matches() -> Bool {
                guard let start else { return false }
                let reachesWindow = side == .right ? last + maximumGap + 1 >= covered.lowerBound
                                                   : last - maximumGap - 1 <= covered.upperBound
                return abs(Double(start) - expectedStart) <= tolerance && reachesWindow
                    && longestProgressRun >= required
            }
            var x = side == .right ? 0 : width - 1
            while x >= 0, x < width {
                let (r, g, b) = image[x, y]
                let magenta = r > 130 && b > 65 && Int(r) - Int(g) > 45 && Int(b) - Int(g) > 20
                let progress = Self.isGold(r, g, b) || magenta
                if progress || Self.isViolet(r, g, b) {
                    if start == nil { start = x }
                    last = x
                    progressRun = progress ? progressRun + 1 : 0
                    longestProgressRun = max(longestProgressRun, progressRun)
                } else {
                    progressRun = 0
                    if start != nil, abs(x - last) > maximumGap {
                        if matches() { return true }
                        start = nil
                        longestProgressRun = 0
                    }
                }
                x += step
            }
            if matches() { return true }
        }
        return false
    }

    /// The upper median, as the C++ reader takes it.
    static func median(_ values: [UInt8]) -> UInt8 {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
