import Foundation
import Testing
import GlyphCoreCxx
import GlyphRecognitionImages
@testable import GlyphRecognition

/// Holds the C++ slot strip reader to the Swift `SlotStripReader` on the same
/// pixels: every fixture band, decoded through Core Graphics, must give the
/// same reading or the same rejection, and the same timer bar answer.
@Suite("C++ slot strip equivalence")
struct CxxSlotStripTests {
    /// The fixture folders the equivalence corpus is drawn from. A folder is iterated, not its files named, so
    /// a new fixture is covered without a new test.
    static let fixtureFolders = ["Frames", "Recording", "Phases", "Covered", "Banner", "WindowEdge",
                                 "AssistiveTouch", "OneGlyph", "Results", "Gear", "PortalLevel", "Commands",
                                 "EdgeTab", "WindowCover", "WindowLowerEdge"]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]

    static func fixtureImages(in folder: String) throws -> [URL] {
        let directory = try ReferenceData.fixturesDirectory.appendingPathComponent(folder)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func band(_ url: URL) throws -> FrameTopBand {
        let data = try Data(contentsOf: url)
        let image = try #require(ImageDecoder.cgImage(from: data), "\(url.lastPathComponent) did not decode")
        return try ImageDecoder.topBand(image)
    }

    /// The Swift result in the C ABI's terms, for a one-line comparison.
    static func status(of result: Result<SlotStripReading, SlotStripRejection>) -> gc_slot_status {
        switch result {
        case .success: return GC_SLOT_OK
        case .failure(let rejection):
            switch rejection {
            case .bandUnavailable: return GC_SLOT_BAND_UNAVAILABLE
            case .noMarkers: return GC_SLOT_NO_MARKERS
            case .tooManyMarkers: return GC_SLOT_TOO_MANY_MARKERS
            case .unevenSpacing: return GC_SLOT_UNEVEN_SPACING
            case .inconsistentMarkerWidths: return GC_SLOT_INCONSISTENT_MARKER_WIDTHS
            case .multipleHighlights: return GC_SLOT_MULTIPLE_HIGHLIGHTS
            case .incompleteMarkerHeight: return GC_SLOT_INCOMPLETE_MARKER_HEIGHT
            case .incompleteStrip: return GC_SLOT_INCOMPLETE_STRIP
            case .coveredByOverlay: return GC_SLOT_COVERED_BY_OVERLAY
            }
        }
    }

    /// Runs the C++ reader and the timer bar on a band's packed RGB pixels.
    static func readCxx(_ band: FrameTopBand, layout: gc_layout = gc_layout_default())
        -> (reading: gc_slot_reading, timer: Bool) {
        var layout = layout
        return band.image.pixels.withUnsafeBufferPointer { pixels in
            let image = gc_color_image(data: pixels.baseAddress, width: Int32(band.image.width),
                                       height: Int32(band.image.height), bytesPerRow: Int32(band.image.width * 3),
                                       bytesPerPixel: 3, redOffset: 0, greenOffset: 1, blueOffset: 2)
            var reading = gc_slot_reading()
            gc_slot_strip_read(image, Int32(band.frameHeight), &layout, &reading)
            let timer = gc_timer_bar(image, Int32(band.frameHeight), &layout)
            return (reading, timer)
        }
    }

    static func expectEqual(_ cxx: gc_slot_reading, _ swift: SlotStripReading, _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let comment = Comment(rawValue: label)
        #expect(Int(cxx.slotCount) == swift.slotCount, comment, sourceLocation: sourceLocation)
        #expect(Int(cxx.highlightedIndex) == (swift.highlightedIndex ?? -1), comment, sourceLocation: sourceLocation)
        let centers = withUnsafeBytes(of: cxx.markerCentersX) { raw in
            Array(raw.bindMemory(to: Double.self).prefix(Int(cxx.slotCount)))
        }
        #expect(centers.count == swift.markerCentersX.count, comment, sourceLocation: sourceLocation)
        for (actual, expected) in zip(centers, swift.markerCentersX) {
            #expect(abs(actual - expected) <= 1e-9, comment, sourceLocation: sourceLocation)
        }
        #expect(cxx.hasInputTimerBar == swift.hasInputTimerBar, comment, sourceLocation: sourceLocation)
        #expect(cxx.isPartlyCovered == swift.isPartlyCovered, comment, sourceLocation: sourceLocation)
    }

    /// The C reading's window cover fields against `SlotStripObservation.cover`.
    static func expectEqual(_ cxx: gc_slot_reading, _ swift: SlotStripWindowCover?, _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let comment = Comment(rawValue: label)
        guard let swift else {
            #expect(cxx.windowSide == GC_WINDOW_NONE && !cxx.hasPartialRow && !cxx.hasPartialTimerBar,
                    comment, sourceLocation: sourceLocation)
            return
        }
        #expect(cxx.windowSide == (swift.side == .left ? GC_WINDOW_LEFT : GC_WINDOW_RIGHT), comment,
                sourceLocation: sourceLocation)
        #expect(cxx.coveredFrom == swift.coveredFrom && cxx.coveredTo == swift.coveredTo, comment,
                sourceLocation: sourceLocation)
        #expect(cxx.hasPartialTimerBar == swift.hasPartialInputTimerBar, comment, sourceLocation: sourceLocation)
        #expect(cxx.hasPartialRow == (swift.row != nil), comment, sourceLocation: sourceLocation)
        guard let row = swift.row, cxx.hasPartialRow else { return }
        let centers = withUnsafeBytes(of: cxx.partialCentersX) { raw in
            Array(raw.bindMemory(to: Double.self).prefix(Int(cxx.partialCount)))
        }
        #expect(centers == row.markerCentersX, comment, sourceLocation: sourceLocation)
        #expect(Int(cxx.partialHighlightedMarker) == (row.highlightedMarker ?? -1), comment,
                sourceLocation: sourceLocation)
    }

    @Test("Every fixture band reads the same in C++ as in Swift", arguments: fixtureFolders)
    func fixturesMatch(folder: String) throws {
        let urls = try Self.fixtureImages(in: folder)
        #expect(!urls.isEmpty, Comment(rawValue: "\(folder) has no fixture images"))
        let reader = SlotStripReader()
        for url in urls {
            let label = "\(folder)/\(url.lastPathComponent)"
            let band = try Self.band(url)
            let observation = reader.observe(band)
            let swift = observation.reading
            let cxx = Self.readCxx(band)
            #expect(cxx.reading.status == Self.status(of: swift), Comment(rawValue: label))
            if case .success(let reading) = swift, cxx.reading.status == GC_SLOT_OK {
                Self.expectEqual(cxx.reading, reading, label)
            }
            Self.expectEqual(cxx.reading, observation.cover, label)
            #expect(cxx.timer == reader.hasTimerBar(band), Comment(rawValue: label))
        }
    }

    @Test("Our window at every size, either side, reads the same in C++ as in Swift")
    func resizedWindowCover() throws {
        let reader = SlotStripReader()
        for url in try Self.fixtureImages(in: "WindowCover") {
            for (label, band) in try WindowCoverTests.sizes(url.lastPathComponent) {
                for (side, sided) in [("", band), ("mirrored ", try WindowCoverTests.mirrored(band))] {
                    let observation = reader.observe(sided)
                    let cxx = Self.readCxx(sided)
                    #expect(cxx.reading.status == Self.status(of: observation.reading), Comment(rawValue: side + label))
                    Self.expectEqual(cxx.reading, observation.cover, side + label)
                }
            }
        }
    }

    @Test("Our window over the left of the row reads the same in C++ as in Swift")
    func mirroredWindowCover() throws {
        let reader = SlotStripReader()
        for url in try Self.fixtureImages(in: "WindowCover") {
            let label = "mirrored WindowCover/\(url.lastPathComponent)"
            let band = try WindowCoverTests.mirrored(Self.band(url))
            let observation = reader.observe(band)
            let cxx = Self.readCxx(band)
            #expect(cxx.reading.status == Self.status(of: observation.reading), Comment(rawValue: label))
            Self.expectEqual(cxx.reading, observation.cover, label)
        }
    }

    @Test("The edge tab changes C++ readings as little as Swift's, and C++ reads it as Swift does",
          arguments: EdgeTab.Side.allCases)
    func edgeTab(side: EdgeTab.Side) throws {
        let reader = SlotStripReader()
        for (label, image) in try EdgeTab.frames() {
            let plain = Self.readCxx(try ImageDecoder.topBand(EdgeTab.draw(image, side: nil)))
            let band = try ImageDecoder.topBand(EdgeTab.draw(image, side: side))
            let tabbed = Self.readCxx(band)
            let swift = reader.read(band)
            #expect(EdgeTab.keeps(Self.status(of: swift), plain: plain.reading.status), Comment(rawValue: label))
            #expect(tabbed.reading.status == Self.status(of: swift), Comment(rawValue: label))
            if case .success(let reading) = swift, tabbed.reading.status == GC_SLOT_OK {
                Self.expectEqual(tabbed.reading, reading, label)
                Self.expectEqual(plain.reading, reading, label)
            }
            #expect(tabbed.timer == plain.timer && tabbed.timer == reader.hasTimerBar(band), Comment(rawValue: label))
        }
    }

    @Test("The default layout matches GameUILayout field for field")
    func defaultLayout() {
        let cxx = gc_layout_default()
        let swift = GameUILayout()
        #expect(cxx.headerTextTop == swift.headerTextTop)
        #expect(cxx.headerTextBottom == swift.headerTextBottom)
        #expect(cxx.slotStripTop == swift.slotStripTop)
        #expect(cxx.slotStripBottom == swift.slotStripBottom)
        #expect(cxx.inputTimerBarTop == swift.inputTimerBarTop)
        #expect(cxx.inputTimerBarBottom == swift.inputTimerBarBottom)
        #expect(cxx.inputTimerBarMinimumWidth == swift.inputTimerBarMinimumWidth)
        #expect(cxx.slotMarkerMinimumWidth == swift.slotMarkerMinimumWidth)
        #expect(cxx.slotMarkerMaximumWidth == swift.slotMarkerMaximumWidth)
        #expect(Int(cxx.slotMarkerMinimumColumnHits) == swift.slotMarkerMinimumColumnHits)
        #expect(cxx.slotPitchTolerance == swift.slotPitchTolerance)
        #expect(cxx.slotCenterPitch == swift.slotCenterPitch)
        #expect(cxx.slotCenterTolerance == swift.slotCenterTolerance)
        #expect(cxx.inputTimerTrackLeft == swift.inputTimerTrackLeft)
        #expect(cxx.inputTimerTrackRight == swift.inputTimerTrackRight)
        #expect(cxx.inputTimerEndpointTolerance == swift.inputTimerEndpointTolerance)
        #expect(cxx.bannerMinimumRowCoverage == swift.bannerMinimumRowCoverage)
        #expect(cxx.bannerMinimumHeight == swift.bannerMinimumHeight)
        #expect(cxx.coveredMarkerMinimumHeight == swift.coveredMarkerMinimumHeight)
        #expect(Int(GC_MAX_SLOTS) == SequenceTable.maximumLength)
    }

    /// Four outlined indicators at the measured pitch, the second one gold,
    /// with a grey banner over their tops and a countdown track below: a
    /// reading with every field set. Authored like `SlotStripTests.bannerBand`.
    private func syntheticBand() throws -> FrameTopBand {
        let width = 603, height = 323
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        func put(_ x: Int, _ y: Int, _ color: [UInt8]) {
            let offset = (y * width + x) * 3
            pixels.replaceSubrange(offset..<(offset + 3), with: color)
        }
        for index in 0..<4 {
            let center = 301 + (2 * index - 3) * 48
            for y in 145..<225 {
                for x in (center - 40)..<(center + 40) {
                    if y >= 149 && y < 221 && x >= center - 36 && x < center + 36 { continue }
                    put(x, y, index == 1 ? [240, 180, 50] : [185, 165, 240])
                }
            }
        }
        for y in 60..<175 { for x in 10..<593 { put(x, y, [128, 130, 135]) } }
        // The track: a violet rail from 0.11 to 0.89 of the width, gold progress
        // over its left half.
        for y in 300..<306 {
            for x in 66..<537 { put(x, y, x < 300 ? [240, 180, 50] : [185, 165, 240]) }
        }
        return FrameTopBand(image: try ColorImage(width: width, height: height, pixels: pixels), frameHeight: 1311)
    }

    @Test("Padded BGRA rows read the same as packed RGB")
    func pixelLayouts() throws {
        let band = try syntheticBand()
        let swift = try SlotStripReader().read(band).get()
        #expect(swift.slotCount == 4 && swift.highlightedIndex == 1 && swift.isPartlyCovered && swift.hasInputTimerBar)

        let rgb = Self.readCxx(band)
        #expect(rgb.reading.status == GC_SLOT_OK)
        Self.expectEqual(rgb.reading, swift, "packed RGB")
        #expect(rgb.timer)

        // The same pixels as 4-byte BGRA with 13 bytes of padding on every row.
        let width = band.image.width, height = band.image.height
        let bytesPerRow = width * 4 + 13
        var bgra = [UInt8](repeating: 0xAB, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = band.image[x, y]
                let base = y * bytesPerRow + x * 4
                bgra[base] = b; bgra[base + 1] = g; bgra[base + 2] = r; bgra[base + 3] = 0xFF
            }
        }
        var layout = gc_layout_default()
        let padded: (reading: gc_slot_reading, timer: Bool) = bgra.withUnsafeBufferPointer { buffer in
            let image = gc_color_image(data: buffer.baseAddress, width: Int32(width), height: Int32(height),
                                       bytesPerRow: Int32(bytesPerRow), bytesPerPixel: 4,
                                       redOffset: 2, greenOffset: 1, blueOffset: 0)
            var reading = gc_slot_reading()
            gc_slot_strip_read(image, Int32(band.frameHeight), &layout, &reading)
            return (reading, gc_timer_bar(image, Int32(band.frameHeight), &layout))
        }
        #expect(padded.reading.status == GC_SLOT_OK)
        Self.expectEqual(padded.reading, swift, "padded BGRA")
        #expect(padded.timer)
        let rgbCenters = withUnsafeBytes(of: rgb.reading.markerCentersX) { Array($0.bindMemory(to: Double.self)) }
        let bgraCenters = withUnsafeBytes(of: padded.reading.markerCentersX) { Array($0.bindMemory(to: Double.self)) }
        #expect(rgbCenters == bgraCenters)
    }

    /// Hand-authored scenes for the rejections no fixture reaches, after
    /// `SlotStripTests`: outlined boxes of marker size placed where the rule
    /// under test says they must not be.
    enum Scene: String, CaseIterable {
        case unevenClutter, offCentreMarker, twoHighlights, sixMarkers, bannerTooLow, bannerOverStrip,
             partialWidthCover, windowOverStrip, windowAboveStrip,
             edgeTabRight, edgeTabLeft, edgeTabsFiveSlots, edgeTabOnly, edgeTabUnderBanner, edgeTabBesideWindow,
             edgeObjectTouchingMarker, edgeObjectOverMarker, edgeObjectOffCentre, edgeObjectBeyondStarts,
             markerFragment

        /// What the Swift reader says of the scene, so the scene is known to
        /// reach the rule it was drawn for before the two arms are compared.
        var expectedStatus: gc_slot_status {
            switch self {
            case .unevenClutter: return GC_SLOT_UNEVEN_SPACING
            case .offCentreMarker: return GC_SLOT_INCOMPLETE_STRIP
            case .twoHighlights: return GC_SLOT_MULTIPLE_HIGHLIGHTS
            case .sixMarkers: return GC_SLOT_TOO_MANY_MARKERS
            case .bannerTooLow: return GC_SLOT_INCOMPLETE_MARKER_HEIGHT
            case .bannerOverStrip, .partialWidthCover, .windowOverStrip: return GC_SLOT_COVERED_BY_OVERLAY
            case .windowAboveStrip: return GC_SLOT_OK
            // The recorded tab beside the indicators is no indicator, and
            // no reason to distrust them.
            case .edgeTabRight, .edgeTabLeft, .edgeTabsFiveSlots, .edgeObjectBeyondStarts: return GC_SLOT_OK
            case .edgeTabOnly: return GC_SLOT_NO_MARKERS
            case .edgeTabUnderBanner, .edgeTabBesideWindow: return GC_SLOT_COVERED_BY_OVERLAY
            // An edge object that reaches an indicator, or the place where
            // one may start, is distrusted as any wide marker is; so is what
            // is left of an indicator another object cut.
            case .edgeObjectTouchingMarker, .edgeObjectOverMarker, .markerFragment:
                return GC_SLOT_INCONSISTENT_MARKER_WIDTHS
            case .edgeObjectOffCentre: return GC_SLOT_INCOMPLETE_STRIP
            }
        }

        /// The bottoms of four indicators below a dark window's lower edge.
        private func draw(into fill: (Range<Int>, Range<Int>, [UInt8]) -> Void) {
            let violet: [UInt8] = [185, 165, 240]
            for index in 0..<4 {
                let center = 301 + (2 * index - 3) * 48
                fill(210..<225, (center - 40)..<(center - 36), violet)
                fill(210..<225, (center + 36)..<(center + 40), violet)
                fill(221..<225, (center - 40)..<(center + 40), violet)
            }
            fill(80..<200, 20..<583, [8, 12, 18])
            fill(200..<208, 20..<583, [78, 80, 90])
        }

        func band() throws -> FrameTopBand {
            let width = 603, height = 323
            var pixels = [UInt8](repeating: 0, count: width * height * 3)
            func fill(_ ys: Range<Int>, _ xs: Range<Int>, _ color: [UInt8]) {
                for y in ys { for x in xs {
                    let offset = (y * width + x) * 3
                    pixels.replaceSubrange(offset..<(offset + 3), with: color)
                } }
            }
            func box(left: Int, _ color: [UInt8]) {
                for y in 150..<220 { for x in left..<(left + 70) {
                    guard y < 154 || y >= 216 || x < left + 4 || x >= left + 66 else { continue }
                    fill(y..<(y + 1), x..<(x + 1), color)
                } }
            }
            let violet: [UInt8] = [185, 165, 240], gold: [UInt8] = [240, 180, 50]
            func row(_ count: Int, highlighted: Set<Int> = [], halfWidth: Int = 40) {
                for index in 0..<count {
                    let center = 301 + (2 * index - (count - 1)) * 48
                    for y in 145..<225 { for x in (center - halfWidth)..<(center + halfWidth) {
                        if y >= 149 && y < 221 && x >= center - halfWidth + 4 && x < center + halfWidth - 4 { continue }
                        fill(y..<(y + 1), x..<(x + 1), highlighted.contains(index) ? gold : violet)
                    } }
                }
            }
            // The recorded tab, grey from its antialiased first column at
            // 0.939 of the width to the edge, over frame rows 90-239.
            func tab(right: Bool) {
                let columns = right ? 566..<width : 0..<(width - 566)
                fill(90..<240, columns, [137, 137, 137])
                fill(90..<240, right ? 566..<567 : (width - 567)..<(width - 566), [87, 87, 87])
            }
            switch self {
            case .unevenClutter:
                for (index, left) in [40, 170, 440].enumerated() { box(left: left, index == 0 ? gold : violet) }
            case .offCentreMarker:
                box(left: 120, violet)
            case .twoHighlights:
                row(4, highlighted: [0, 2])
            case .sixMarkers:
                // Narrow enough that six of them do not light a whole row.
                row(6, halfWidth: 30)
            case .bannerTooLow:
                row(4)
                fill(60..<205, 10..<593, [128, 130, 135])
            case .bannerOverStrip:
                row(4)
                fill(60..<240, 10..<593, [128, 130, 135])
            case .partialWidthCover:
                row(4)
                fill(60..<175, 0..<300, [128, 130, 135])
            case .windowOverStrip:
                Self.windowOverStrip.draw(into: fill)
            case .windowAboveStrip:
                row(4)
                fill(130..<137, 20..<583, [78, 80, 90])
                fill(137..<139, 20..<583, [8, 12, 18])
            case .edgeTabRight:
                row(4, highlighted: [1])
                tab(right: true)
            case .edgeTabLeft:
                row(4, highlighted: [1])
                tab(right: false)
            case .edgeTabsFiveSlots:
                // Narrower than measured, so that the flat tops of five
                // authored boxes and both tabs do not light a whole row.
                row(5, highlighted: [4], halfWidth: 34)
                tab(right: true)
                tab(right: false)
            case .edgeTabOnly:
                tab(right: true)
            case .edgeTabUnderBanner:
                row(4)
                fill(60..<240, 10..<593, [128, 130, 135])
                tab(right: true)
            case .edgeTabBesideWindow:
                Self.windowOverStrip.draw(into: fill)
                tab(right: true)
            case .edgeObjectTouchingMarker:
                // Grey from the fifth indicator's right side to the edge,
                // short of the rows its tops and bottoms would light whole.
                row(5)
                fill(150..<220, 533..<width, [137, 137, 137])
            case .edgeObjectOverMarker:
                row(4)
                fill(90..<240, 440..<width, [137, 137, 137])
            case .edgeObjectOffCentre:
                // Clear of the fourth indicator, but starting where a fifth
                // could (before 0.8225 of the width): a marker-sized run
                // that is read as a fifth one, off its place.
                row(4)
                fill(100..<240, 492..<width, [137, 137, 137])
            case .edgeObjectBeyondStarts:
                // The same object starting beyond any indicator's start.
                row(4)
                fill(100..<240, 500..<width, [137, 137, 137])
            case .markerFragment:
                // A dark object over the left of the fifth indicator leaves a
                // narrow fragment that reaches no edge.
                row(5)
                fill(100..<240, 450..<500, [8, 12, 18])
            }
            return FrameTopBand(image: try ColorImage(width: width, height: height, pixels: pixels),
                                frameHeight: 1311)
        }
    }

    @Test("Hand-authored scenes reach the same rejection in C++ as in Swift", arguments: Scene.allCases)
    func syntheticScenes(scene: Scene) throws {
        let band = try scene.band()
        let swift = SlotStripReader().read(band)
        #expect(Self.status(of: swift) == scene.expectedStatus, Comment(rawValue: scene.rawValue))
        let cxx = Self.readCxx(band)
        #expect(cxx.reading.status == Self.status(of: swift), Comment(rawValue: scene.rawValue))
        if case .success(let reading) = swift, cxx.reading.status == GC_SLOT_OK {
            Self.expectEqual(cxx.reading, reading, scene.rawValue)
        }
        #expect(cxx.timer == SlotStripReader().hasTimerBar(band), Comment(rawValue: scene.rawValue))
    }

    @Test("An empty or malformed band is unavailable, not a crash")
    func malformedBand() {
        var layout = gc_layout_default()
        var reading = gc_slot_reading()
        let empty = gc_color_image(data: nil, width: 0, height: 0, bytesPerRow: 0, bytesPerPixel: 3,
                                   redOffset: 0, greenOffset: 1, blueOffset: 2)
        gc_slot_strip_read(empty, 1311, &layout, &reading)
        #expect(reading.status == GC_SLOT_BAND_UNAVAILABLE)
        #expect(reading.slotCount == 0 && reading.highlightedIndex == -1)
        #expect(!gc_timer_bar(empty, 1311, &layout))
    }
}
