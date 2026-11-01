/// What the row of slot indicators shows, independent of any shape matching.
///
/// This is the evidence that makes a presented sequence collectable: the number
/// of indicators is the sequence length, and the single gold indicator is the
/// slot the game is currently on. A change of highlight is a *verified*
/// boundary in a way that a blank frame or an elapsed timer is not.
public struct SlotStripReading: Sendable, Equatable {
    /// Number of indicators, always within `SequenceTable.maximumLength`.
    public let slotCount: Int
    /// The highlighted indicator, if exactly one is highlighted. Nil means the
    /// strip is present but nothing is selected yet, which is what the screen
    /// shows between the header appearing and the first Glyph.
    public let highlightedIndex: Int?
    /// Indicator centres, as fractions of the frame width, left to right.
    public let markerCentersX: [Double]
    /// The player-input countdown bar is drawn. Corroborating evidence only:
    /// the header text is what names the phase.
    public let hasInputTimerBar: Bool
    /// The tops of the indicators were hidden by a banner or a thin window,
    /// and the row was read from what showed below its edge.
    public let isPartlyCovered: Bool

    public init(slotCount: Int, highlightedIndex: Int?, markerCentersX: [Double], hasInputTimerBar: Bool,
                isPartlyCovered: Bool = false) {
        self.slotCount = slotCount
        self.highlightedIndex = highlightedIndex
        self.markerCentersX = markerCentersX
        self.hasInputTimerBar = hasInputTimerBar
        self.isPartlyCovered = isPartlyCovered
    }
}

/// Why a strip could not be read. Reported rather than collapsed into nil so a
/// log can distinguish "no strip on this screen" from "a strip we distrust".
public enum SlotStripRejection: String, Sendable, Equatable, Error {
    case bandUnavailable
    case noMarkers
    case tooManyMarkers
    case unevenSpacing
    case inconsistentMarkerWidths
    case multipleHighlights
    case incompleteMarkerHeight
    case incompleteStrip
    /// The lower edge of something, such as the floating window, crosses the
    /// strip: the indicators are hidden rather than absent.
    case coveredByOverlay
}

/// Finds the hexagonal slot indicators by colour.
///
/// Colour is load-bearing and cannot be recovered from the luminance the shape
/// recognizer uses: the indicators are pale violet outlines and the selected
/// one is gold, and both are bright. The thresholds below separate the two
/// populations cleanly on every fixture — a selected indicator contributes
/// ~1900 gold and 0 violet pixels, an unselected one ~1000 violet and 0 gold.
public struct SlotStripReader: Sendable {
    public let layout: GameUILayout

    public init(layout: GameUILayout = GameUILayout()) {
        self.layout = layout
    }

    static func isGold(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool {
        red > 150 && green > 90 && blue < 110 && Int(red) - Int(blue) > 70
    }

    static func isViolet(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool {
        blue > 110 && blue >= red && blue >= green
    }

    public func read(_ band: FrameTopBand) -> Result<SlotStripReading, SlotStripRejection> {
        read(band, belowOverlay: nil)
    }

    private func read(_ band: FrameTopBand, belowOverlay: Int?) -> Result<SlotStripReading, SlotStripRejection> {
        let stripRows = band.rows(layout.slotStripTop, layout.slotStripBottom)
        guard !stripRows.isEmpty else { return .failure(.bandUnavailable) }
        let image = band.image
        let width = image.width
        let litRows = litRowsFromTop(band, in: stripRows)
        let firstVisibleRow = firstRowBelowBanner(litRowsFromTop: litRows, band: band)
        // A banner reaching the bottom hides the strip; it does not establish
        // that the game's indicators disappeared.
        guard (firstVisibleRow ?? stripRows.lowerBound) < stripRows.upperBound else {
            return .failure(.coveredByOverlay)
        }
        let firstRow = max(firstVisibleRow ?? stripRows.lowerBound, belowOverlay ?? stripRows.lowerBound)
        guard firstRow < stripRows.upperBound else { return .failure(.coveredByOverlay) }
        let rows = firstRow..<stripRows.upperBound

        // The game's indicators never light a whole row. A row that is, below
        // any banner, is the lower edge of a window over the indicators --
        // including a run at the very top of the strip too short to be a
        // banner: a window ending just above the strip lays its border across
        // the indicator tips, and every status colour of our own window's
        // edge passes as indicator violet or gold.
        let wholeRow = Int((layout.bannerMinimumRowCoverage * Double(width)).rounded(.up))
        var goldColumns = [Int](repeating: 0, count: width)
        var violetColumns = [Int](repeating: 0, count: width)
        var firstRows = [Int](repeating: image.height, count: width)
        var lastRows = [Int](repeating: -1, count: width)
        var lastCoveredRow: Int?
        for y in rows {
            var lit = 0
            for x in 0..<width {
                let (r, g, b) = image[x, y]
                if max(r, max(g, b)) < 60 { continue }
                lit += 1
                if Self.isGold(r, g, b) { goldColumns[x] += 1 }
                else if Self.isViolet(r, g, b) { violetColumns[x] += 1 }
                else { continue }
                firstRows[x] = min(firstRows[x], y)
                lastRows[x] = max(lastRows[x], y)
            }
            if lit >= wholeRow { lastCoveredRow = y }
        }

        if let lastCoveredRow {
            // A thin PiP can end just inside the strip, leaving almost the
            // whole indicator row visible. Discard its border and shadow, then
            // require the ordinary full-height, count and geometry checks on
            // what remains. Never read the window's own glyphs as indicators.
            guard belowOverlay == nil else { return .failure(.coveredByOverlay) }
            let firstUncoveredRow = lastCoveredRow + 1 + layout.bannerEdgeTolerance(frameHeight: band.frameHeight)
            // An edge confined to the strip's first rows reaches no further
            // than the indicator tips, so it is not what hid anything missing
            // below it. Calling that covered would warn the player to move a
            // window that is out of the way, on every screen without a strip.
            let endsAtStripTop = lastCoveredRow < stripRows.lowerBound + litRows
            switch read(band, belowOverlay: firstUncoveredRow) {
            case .success(let reading): return .success(reading)
            case .failure(let rejection): return .failure(endsAtStripTop ? rejection : .coveredByOverlay)
            }
        }

        var markers: [(range: ClosedRange<Int>, gold: Int, violet: Int)] = []
        var start: Int?
        var gold = 0, violet = 0
        for x in 0...width {
            let on = x < width && goldColumns[x] + violetColumns[x] >= layout.slotMarkerMinimumColumnHits
            if on {
                if start == nil { start = x; gold = 0; violet = 0 }
                gold += goldColumns[x]; violet += violetColumns[x]
            } else if let first = start {
                markers.append((first...(x - 1), gold, violet))
                start = nil
            }
        }

        let minimumWidth = layout.slotMarkerMinimumWidth * Double(width)
        let maximumWidth = layout.slotMarkerMaximumWidth * Double(width)
        let sized = markers.filter {
            let w = Double($0.range.count)
            return w >= minimumWidth && w <= maximumWidth
        }
        guard !sized.isEmpty else { return .failure(markers.isEmpty ? .noMarkers : .inconsistentMarkerWidths) }
        // Every marker that survived the width filter must be a slot: a strip
        // with one indicator rejected as too wide is a misread, not a shorter
        // sequence, so demand that nothing was dropped.
        guard sized.count == markers.count else { return .failure(.inconsistentMarkerWidths) }
        guard sized.count <= SequenceTable.maximumLength else { return .failure(.tooManyMarkers) }

        let markerExtents = sized.map { marker in
            (top: marker.range.map { firstRows[$0] }.min() ?? image.height,
             bottom: marker.range.map { lastRows[$0] }.max() ?? -1,
             width: marker.range.count)
        }
        // A strip under PiP must retain nearly the full marker height. Reading
        // only the bottom fragments could otherwise silently shorten the row.
        // Below a banner every marker is cut by the same straight edge, so a
        // marker may instead run up to that edge, provided enough of it shows
        // to have kept its full width.
        guard markerExtents.allSatisfy({ extent in
            let height = Double(extent.bottom - extent.top + 1)
            if height >= Double(extent.width) * 0.8 { return true }
            guard belowOverlay == nil, let firstVisibleRow else { return false }
            return extent.top <= firstVisibleRow + layout.bannerEdgeTolerance(frameHeight: band.frameHeight)
                && height >= Double(extent.width) * layout.coveredMarkerMinimumHeight
        }) else {
            return .failure(.incompleteMarkerHeight)
        }

        let centers = sized.map { (Double($0.range.lowerBound) + Double($0.range.upperBound)) / 2 }
        if sized.count >= 3 {
            let pitches = zip(centers, centers.dropFirst()).map { $1 - $0 }
            let mean = pitches.reduce(0, +) / Double(pitches.count)
            guard mean > 0, pitches.allSatisfy({ abs($0 - mean) <= mean * layout.slotPitchTolerance }) else {
                return .failure(.unevenSpacing)
            }
        }

        // The complete row is centred on the screen at a fixed pitch. Merely
        // counting remaining markers would turn four slots with the first two
        // covered into a supposedly verified two-slot sequence. A level 1
        // portal's hack has one Glyph: its lone indicator must sit at the
        // centre, which no marker left over from a longer row does.
        let midpoint = Double(centers.count - 1) / 2
        guard centers.enumerated().allSatisfy({ index, center in
            let expected = 0.5 + (Double(index) - midpoint) * layout.slotCenterPitch
            return abs(center / Double(width) - expected) <= layout.slotCenterTolerance
        }) else { return .failure(.incompleteStrip) }

        let highlights = sized.indices.filter { sized[$0].gold > sized[$0].violet }
        guard highlights.count <= 1 else { return .failure(.multipleHighlights) }

        // Below a window's edge the indicators were cut only if they run up to
        // it; an edge that merely touches the top of the strip hid nothing.
        let cutBelowWindow = belowOverlay.map { cut in markerExtents.contains { $0.top <= cut } } ?? false
        return .success(SlotStripReading(
            slotCount: sized.count,
            highlightedIndex: highlights.first,
            markerCentersX: centers.map { $0 / Double(width) },
            hasInputTimerBar: hasTimerBar(band),
            isPartlyCovered: firstVisibleRow != nil || cutBelowWindow))
    }

    /// How many rows at the top of the strip something bright hangs over.
    ///
    /// An iOS notification slides down over the header and the tops of the
    /// indicators while the game carries on underneath, and a window placed
    /// just above the strip can reach its first rows with its border. Across
    /// the strip either lights almost every column of a row, while the game's
    /// own indicators leave most of a row dark, so only a run of such rows
    /// starting at the top of the strip counts.
    func litRowsFromTop(_ band: FrameTopBand, in rows: Range<Int>) -> Int {
        let image = band.image
        let required = Int((layout.bannerMinimumRowCoverage * Double(image.width)).rounded(.up))
        var count = 0
        for y in rows {
            var lit = 0
            for x in 0..<image.width {
                let (r, g, b) = image[x, y]
                if max(r, max(g, b)) >= 60 { lit += 1 }
            }
            guard lit >= required else { break }
            count += 1
        }
        return count
    }

    /// The first strip row below a banner hanging over the strip, or nil when
    /// the lit run is too short to be one.
    ///
    /// The banner's frosted glass passes a blurred, recoloured copy of the
    /// indicators, which must not be read as indicators. A dark window, such
    /// as Picture in Picture, is not a banner: its lower edge inside the strip
    /// is reported as `coveredByOverlay`.
    func firstRowBelowBanner(litRowsFromTop count: Int, band: FrameTopBand) -> Int? {
        let stripTop = band.rows(layout.slotStripTop, layout.slotStripBottom).lowerBound
        let minimumRows = max(1, Int((layout.bannerMinimumHeight * Double(band.frameHeight)).rounded(.up)))
        guard count >= minimumRows else { return nil }
        // The banner's lower edge is antialiased and shadowed.
        return stripTop + count + layout.bannerEdgeTolerance(frameHeight: band.frameHeight)
    }

    /// The complete countdown track below the indicators. Its centred progress
    /// shrinks and turns magenta near the end, while the violet rail still
    /// spans the same screen coordinates. A PiP edge alone is not a timer.
    public func hasTimerBar(_ band: FrameTopBand) -> Bool {
        let rows = band.rows(layout.inputTimerBarTop, layout.inputTimerBarBottom)
        guard !rows.isEmpty else { return false }
        let image = band.image
        let required = Int(layout.inputTimerBarMinimumWidth * Double(image.width))
        let tolerance = layout.inputTimerEndpointTolerance * Double(image.width)
        let expectedLeft = layout.inputTimerTrackLeft * Double(image.width)
        let expectedRight = layout.inputTimerTrackRight * Double(image.width)
        // A few compression/antialiasing pixels may interrupt the thin rail.
        let maximumGap = max(1, Int(Double(image.width) * 0.005))
        for y in rows {
            var start: Int?
            var last = -1
            var progressRun = 0, longestProgressRun = 0
            func matchesTrack() -> Bool {
                guard let start else { return false }
                return abs(Double(start) - expectedLeft) <= tolerance
                    && abs(Double(last) - expectedRight) <= tolerance
                    && longestProgressRun >= required
            }
            for x in 0..<image.width {
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
                    if start != nil, x - last > maximumGap {
                        if matchesTrack() { return true }
                        start = nil
                        longestProgressRun = 0
                    }
                }
            }
            if matchesTrack() { return true }
        }
        return false
    }
}
