extension SlotStripReader {
    /// Share of the sampled columns a ring row of the window's lower edge
    /// holds within `windowSideColourTolerance` of its median colour. In a
    /// field report the ring rows held 0.92 to 1.00 in every status colour;
    /// the antialiased row under them, which blends with the game below, fell
    /// to 0.87.
    static let windowEdgeColumnShare = 0.9
    /// The thinnest ring band, in rows. That report's windows drew 4 or 5.
    static let windowEdgeMinimumRows = 2

    /// Where our own floating window's lower edge leaves the strip readable:
    /// per column, the first row below the window's ring and its shadow, or
    /// nil when the lit row `lastCoveredRow` is not the lower edge of our
    /// window.
    ///
    /// Our window draws a ring of one status colour around a darker interior
    /// (`FloatingWindowFinder`). Its lower edge is a band of rows near
    /// `lastCoveredRow`, each one smooth colour across the middle half of
    /// that row's lit span and as bright as a ring (`FloatingWindowFinder
    /// .ringFloor`), no thicker than a ring (`maximumRingShare` of the frame
    /// height), its last row within the edge tolerance of `lastCoveredRow`
    /// (the antialiased row under the ring blends with the game below it).
    /// The rows one band thickness above it must be darker by
    /// `windowInteriorContrast`. A bright banner, a bright or dark bar, video
    /// or a game panel fails one of these.
    ///
    /// The edge is curved: it rises towards the window's ends, and on a
    /// smaller window its last rows can light less than a whole row. So each
    /// column is followed down from the band through pixels of the ring's
    /// colour, at most the band's own thickness further, and the column is
    /// read only below that, `lastCoveredRow` and the edge tolerance. The
    /// bound keeps an indicator of the ring's colour right under the edge
    /// from being followed down as ring. Where the edge rises, the uniform
    /// cut below `lastCoveredRow` still applies.
    func windowLowerEdge(_ band: FrameTopBand, lastCoveredRow: Int) -> [Int]? {
        let image = band.image
        let width = image.width
        guard lastCoveredRow >= 0, lastCoveredRow < image.height else { return nil }
        guard let first = (0..<width).first(where: { Self.isLit(image[$0, lastCoveredRow]) }),
              let last = (0..<width).last(where: { Self.isLit(image[$0, lastCoveredRow]) }) else { return nil }
        let quarter = (last - first) / 4
        let sampled = (first + quarter)...(last - quarter)
        let required = Int((Self.windowEdgeColumnShare * Double(sampled.count)).rounded(.up))
        let tolerance = Self.windowSideColourTolerance

        func medianColour(_ y: Int) -> (UInt8, UInt8, UInt8) {
            var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
            for x in sampled {
                let (r, g, b) = image[x, y]
                reds.append(r); greens.append(g); blues.append(b)
            }
            return (Self.median(reds), Self.median(greens), Self.median(blues))
        }
        func near(_ pixel: (UInt8, UInt8, UInt8), _ colour: (UInt8, UInt8, UInt8)) -> Bool {
            abs(Int(pixel.0) - Int(colour.0)) <= tolerance && abs(Int(pixel.1) - Int(colour.1)) <= tolerance
                && abs(Int(pixel.2) - Int(colour.2)) <= tolerance
        }
        func isRingRow(_ y: Int) -> Bool {
            guard y >= 0, y < image.height else { return false }
            let colour = medianColour(y)
            guard Self.grey(colour.0, colour.1, colour.2) >= FloatingWindowFinder.ringFloor else { return false }
            return sampled.filter { near(image[$0, y], colour) }.count >= required
        }

        let edgeTolerance = layout.bannerEdgeTolerance(frameHeight: band.frameHeight)
        guard let lowest = stride(from: lastCoveredRow + edgeTolerance, through: lastCoveredRow - edgeTolerance,
                                  by: -1).first(where: isRingRow) else { return nil }
        let thickest = max(2.0, FloatingWindowFinder.maximumRingShare * Double(band.frameHeight))
        // A band already thicker than a ring is refused however far it runs.
        var top = lowest, bottom = lowest
        while Double(bottom - top + 1) <= thickest, isRingRow(top - 1) { top -= 1 }
        while Double(bottom - top + 1) <= thickest, isRingRow(bottom + 1) { bottom += 1 }
        let thickness = bottom - top + 1
        guard thickness >= Self.windowEdgeMinimumRows, Double(thickness) <= thickest,
              top - thickness >= 0 else { return nil }

        let ring = medianColour((top + bottom) / 2)
        var interiorGreys: [Int] = []
        for y in (top - thickness)..<top {
            for x in sampled {
                let (r, g, b) = image[x, y]
                interiorGreys.append(Self.grey(r, g, b))
            }
        }
        interiorGreys.sort()
        guard interiorGreys[interiorGreys.count / 2] <= Self.grey(ring.0, ring.1, ring.2) - Self.windowInteriorContrast
        else { return nil }

        return (0..<width).map { x in
            var end = bottom
            if near(image[x, end], ring) {
                while end + 1 < image.height, end + 1 <= bottom + thickness, near(image[x, end + 1], ring) {
                    end += 1
                }
            }
            return max(end, lastCoveredRow) + 1 + edgeTolerance
        }
    }

    /// Whether a read below our window's traced lower edge could find a row,
    /// judged from the read below the thin-window rule's uniform cut, which
    /// failed: per column, its gold and violet hits and the first and last
    /// rows holding either.
    ///
    /// The traced edge is never above that cut, so the traced read counts a
    /// subset of the same pixels: in each column its indicator hits are no
    /// more, its first indicator row no higher and its last no lower. Each
    /// marker it finds therefore lies within a run of columns that already
    /// had `slotMarkerMinimumColumnHits` here, and is no taller than that
    /// run's rows of indicator colour. A row of n markers needs one at each
    /// place of the centred grid, each at least `slotMarkerMinimumWidth`
    /// wide and, under the edge or not, at least `coveredMarkerMinimumHeight`
    /// of that tall, its centre within `slotCenterTolerance` of its place.
    /// When for every n from 1 to the longest sequence some place has no run
    /// that could hold such a marker, the traced read must fail, and the
    /// edge need not be searched. Map, command and other screens under a
    /// window that ends inside the strip are ruled out this way.
    ///
    /// The bounds are loose on purpose (a marker's centre is allowed to the
    /// full extent its run allows, and a pixel more of tolerance), so that
    /// the gate only ever skips searches that cannot succeed.
    func couldReadBelowWindowEdge(gold: [Int], violet: [Int], firstRows: [Int], lastRows: [Int]) -> Bool {
        let width = gold.count
        let minimumWidth = layout.slotMarkerMinimumWidth * Double(width)
        let minimumHeight = min(0.8, layout.coveredMarkerMinimumHeight) * minimumWidth
        // Where a marker of the minimum width could be centred in each run
        // tall enough to hold one.
        var centreRanges: [ClosedRange<Double>] = []
        var x = 0
        while x < width {
            guard gold[x] + violet[x] >= layout.slotMarkerMinimumColumnHits else { x += 1; continue }
            let first = x
            var top = Int.max, bottom = Int.min
            while x < width, gold[x] + violet[x] >= layout.slotMarkerMinimumColumnHits {
                top = min(top, firstRows[x])
                bottom = max(bottom, lastRows[x])
                x += 1
            }
            let last = x - 1
            let half = (minimumWidth - 1) / 2
            if Double(last - first + 1) >= minimumWidth, Double(bottom - top + 1) >= minimumHeight {
                centreRanges.append((Double(first) + half)...(Double(last) - half))
            }
        }
        let tolerance = layout.slotCenterTolerance * Double(width) + 1
        return (1...SequenceTable.maximumLength).contains { count in
            (0..<count).allSatisfy { index in
                let place = Double(width)
                    * (0.5 + (Double(index) - Double(count - 1) / 2) * layout.slotCenterPitch)
                return centreRanges.contains { $0.lowerBound <= place + tolerance && $0.upperBound >= place - tolerance }
            }
        }
    }

    static func isLit(_ pixel: (UInt8, UInt8, UInt8)) -> Bool {
        max(pixel.0, max(pixel.1, pixel.2)) >= 60
    }
}
