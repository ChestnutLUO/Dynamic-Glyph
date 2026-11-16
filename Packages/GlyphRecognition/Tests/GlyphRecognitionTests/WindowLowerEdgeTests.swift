import Foundation
import Testing
import GlyphCoreCxx
import GlyphRecognitionImages
@testable import GlyphRecognition

/// Our own floating window's lower edge across the slot row, from the frames
/// in `Fixtures/WindowLowerEdge`. The expected answers are the
/// visible screens, read by eye; the variants move, recolour or replace the
/// recorded window on the same pixels.
@Suite("Slot strip below our own window's lower edge")
struct WindowLowerEdgeTests {
    static func band(_ file: String) throws -> FrameTopBand {
        try CxxSlotStripTests.band(ReferenceData.fixturesDirectory.appendingPathComponent("WindowLowerEdge/\(file)"))
    }

    /// The newer window's frames, whose row shows below the window: the
    /// highlighted slot and whether the countdown runs.
    static let cutFrames: [(file: String, highlight: Int, timer: Bool)] = [
        ("cut-0170.png", 0, false), ("cut-0186.png", 2, false), ("cut-0201.png", 4, false),
        ("cut-0227.png", 0, true), ("cut-0247.png", 1, true), ("cut-0281.png", 3, true), ("cut-0321.png", 4, true),
    ]

    /// The older window's frames, ending at the hexagon tops, and
    /// the reading the reader gave before our window's lower edge was traced:
    /// indicator centres in pixels of the 603 px frame.
    static let topFrames: [(file: String, highlight: Int, timer: Bool, centres: [Double])] = [
        ("tops-0225.png", 1, false, [156.5, 252.5, 349.5, 445.5]),
        ("tops-0241.png", 3, false, [156.5, 253.0, 349.5, 445.5]),
        ("tops-0317.png", 1, true, [156.5, 252.5, 349.5, 445.5]),
        ("tops-0371.png", 3, true, [156.5, 253.0, 349.5, 445.5]),
    ]

    /// The screens under the window that hold no slot row.
    static let screensWithoutRow = ["cut-0116.png", "cut-0411.png", "cut-0421.png"]

    /// The five-slot row's centres, as fractions of the width.
    static let fiveSlotCentres = [0.18, 0.34, 0.50, 0.66, 0.82]

    // MARK: Pixels

    /// Packed RGB rows a test can paint, then read as a band again.
    struct Canvas {
        let width: Int
        let height: Int
        let frameHeight: Int
        var pixels: [UInt8]

        init(_ band: FrameTopBand) {
            width = band.image.width
            height = band.image.height
            frameHeight = band.frameHeight
            pixels = band.image.pixels
        }

        subscript(x: Int, y: Int) -> [UInt8] {
            get { Array(pixels[((y * width + x) * 3)..<((y * width + x) * 3 + 3)]) }
            set { pixels.replaceSubrange(((y * width + x) * 3)..<((y * width + x) * 3 + 3), with: newValue) }
        }

        mutating func fill(rows: Range<Int>, columns: Range<Int>, _ colour: (Int, Int) -> [UInt8]) {
            for y in rows where y >= 0 && y < height {
                for x in columns where x >= 0 && x < width { self[x, y] = colour(x, y) }
            }
        }

        func band() throws -> FrameTopBand {
            FrameTopBand(image: try ColorImage(width: width, height: height, pixels: pixels), frameHeight: frameHeight)
        }
    }

    /// The recorded window, from its upper ring (row 108) to the shadow under
    /// its lower ring (row 165), at 603 × 1311.
    static let windowRows = 108..<166
    /// The window's columns, with its pointed ends.
    static let windowColumns = 19..<584
    /// The window's ring colour in these frames, the warning tone.
    static let recordedRing: [Int] = [240, 125, 130]

    /// The band with the window moved `dx` columns and `dy` rows. Rows the
    /// window leaves above are the game's black; rows it leaves at the bottom
    /// show the row under it continued upwards, as the hexagons' upright
    /// sides are; columns it leaves are black.
    static func shifted(_ band: FrameTopBand, dx: Int, dy: Int) throws -> FrameTopBand {
        let original = Canvas(band)
        var canvas = original
        let firstGameRow = windowRows.upperBound
        canvas.fill(rows: windowRows, columns: 0..<canvas.width) { x, y in
            y >= windowRows.upperBound + dy ? original[x, firstGameRow] : [0, 0, 0]
        }
        for y in windowRows {
            for x in 0..<canvas.width {
                let target = y + dy
                guard target >= 0, target < canvas.height else { continue }
                let source = x - dx
                canvas[x, target] = source >= 0 && source < canvas.width ? original[source, y] : [0, 0, 0]
            }
        }
        return try canvas.band()
    }

    /// The band with the window's ring, and its antialiased lower row, in
    /// another status colour.
    static func recoloured(_ band: FrameTopBand, ring colour: [UInt8]) throws -> FrameTopBand {
        var canvas = Canvas(band)
        for y in windowRows {
            for x in 0..<canvas.width {
                let pixel = canvas[x, y]
                if zip(pixel, recordedRing).allSatisfy({ abs(Int($0) - $1) <= 48 }) { canvas[x, y] = colour }
            }
        }
        return try canvas.band()
    }

    /// Status colours of our window's ring that pass as indicator violet or
    /// gold: drawing lavender, done gold, collecting cyan, idle grey.
    static let ringTones: [[UInt8]] = [[190, 180, 240], [245, 220, 120], [150, 236, 245], [130, 134, 148]]

    // MARK: Reading through the cut

    static func expectFiveSlots(_ result: Result<SlotStripReading, SlotStripRejection>, highlight: Int, timer: Bool,
                                _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let comment = Comment(rawValue: label)
        guard case .success(let reading) = result else {
            Issue.record(Comment(rawValue: "\(label): \(result)"), sourceLocation: sourceLocation)
            return
        }
        #expect(reading.slotCount == 5, comment, sourceLocation: sourceLocation)
        #expect(reading.highlightedIndex == highlight, comment, sourceLocation: sourceLocation)
        #expect(reading.hasInputTimerBar == timer, comment, sourceLocation: sourceLocation)
        #expect(reading.isPartlyCovered, comment, sourceLocation: sourceLocation)
        #expect(zip(reading.markerCentersX, fiveSlotCentres).allSatisfy { abs($0 - $1) <= 0.003 }, comment,
                sourceLocation: sourceLocation)
    }

    /// Swift and C++ read the band alike, field for field, and the C++
    /// reading is returned with Swift's.
    @discardableResult
    static func bothArms(_ band: FrameTopBand, _ label: String, sourceLocation: SourceLocation = #_sourceLocation)
        -> Result<SlotStripReading, SlotStripRejection> {
        let swift = SlotStripReader().read(band)
        let cxx = CxxSlotStripTests.readCxx(band)
        #expect(cxx.reading.status == CxxSlotStripTests.status(of: swift), Comment(rawValue: label),
                sourceLocation: sourceLocation)
        if case .success(let reading) = swift, cxx.reading.status == GC_SLOT_OK {
            CxxSlotStripTests.expectEqual(cxx.reading, reading, label, sourceLocation: sourceLocation)
        }
        return swift
    }

    @Test("The row below our window's curved lower edge reads five slots on both engines")
    func cutRows() throws {
        for (file, highlight, timer) in Self.cutFrames {
            Self.expectFiveSlots(Self.bothArms(try Self.band(file), file), highlight: highlight, timer: timer, file)
        }
    }

    @Test("A window ending at the hexagon tops reads as it did before")
    func windowAtHexagonTops() throws {
        for (file, highlight, timer, centres) in Self.topFrames {
            let reading = try Self.bothArms(try Self.band(file), file).get()
            #expect(reading.slotCount == 4 && reading.highlightedIndex == highlight, Comment(rawValue: file))
            #expect(reading.hasInputTimerBar == timer && reading.isPartlyCovered, Comment(rawValue: file))
            #expect(reading.markerCentersX == centres.map { $0 / 603 }, Comment(rawValue: file))
        }
    }

    @Test("The command screen and the result panel under the window give no row")
    func screensWithoutRow() throws {
        for file in Self.screensWithoutRow {
            let observation = SlotStripReader().observe(try Self.band(file))
            #expect(throws: SlotStripRejection.self, Comment(rawValue: file)) { try observation.reading.get() }
            #expect(observation.cover == nil, Comment(rawValue: file))
            Self.bothArms(try Self.band(file), file)
        }
    }

    @Test("Both window generations are found as our window's lower edge, and the edge is traced per column")
    func edgeFound() throws {
        let reader = SlotStripReader()
        // The newer window: its ring ends on row 164, so rows from 168
        // (the edge tolerance below) are read in every column.
        for (file, _, _) in Self.cutFrames {
            let edge = try #require(reader.windowLowerEdge(try Self.band(file), lastCoveredRow: 164),
                                    Comment(rawValue: file))
            #expect(edge.count == 603 && edge.allSatisfy { $0 >= 168 }, Comment(rawValue: file))
            #expect(edge[60..<540].allSatisfy { $0 == 168 }, Comment(rawValue: file))
        }
        // The older window, a rounded rectangle ending on row 149.
        for (file, _, _, _) in Self.topFrames {
            let edge = try #require(reader.windowLowerEdge(try Self.band(file), lastCoveredRow: 149),
                                    Comment(rawValue: file))
            // A lavender ring runs on into a few violet hexagon apexes on
            // row 150, one row at most.
            let middle = edge[30..<570]
            #expect(middle.allSatisfy { $0 == 153 || $0 == 154 }, Comment(rawValue: file))
            #expect(middle.filter { $0 == 153 }.count >= 530, Comment(rawValue: file))
        }
    }

    @Test("The window moved a few pixels each way still leaves the same row",
          arguments: [(0, -4), (0, -2), (0, 2), (0, 4), (0, 8), (-8, 0), (8, 0), (-6, 3), (6, -3)])
    func shiftedWindow(dx: Int, dy: Int) throws {
        for (file, highlight, timer) in Self.cutFrames {
            let label = "\(file) moved \(dx), \(dy)"
            Self.expectFiveSlots(Self.bothArms(try Self.shifted(Self.band(file), dx: dx, dy: dy), label),
                                 highlight: highlight, timer: timer, label)
        }
    }

    @Test("Every status colour of the ring leaves the same row, moved or not", arguments: ringTones)
    func ringColours(tone: [UInt8]) throws {
        for (file, highlight, timer) in Self.cutFrames {
            let recoloured = try Self.recoloured(Self.band(file), ring: tone)
            Self.expectFiveSlots(Self.bothArms(recoloured, "\(file) in \(tone)"), highlight: highlight,
                                 timer: timer, "\(file) in \(tone)")
            for (dx, dy) in [(0, -3), (0, 3), (5, 0)] {
                let label = "\(file) in \(tone) moved \(dx), \(dy)"
                Self.expectFiveSlots(Self.bothArms(try Self.shifted(recoloured, dx: dx, dy: dy), label),
                                     highlight: highlight, timer: timer, label)
            }
        }
    }

    @Test("A bowed lower edge whose lowest rows light less than a whole row is traced, not read",
          arguments: ringTones)
    func bowedEdge(tone: [UInt8]) throws {
        // The ring continued five rows lower across the middle 161 columns,
        // over three indicators: 0.27 of a row, so the whole-row test stops
        // at row 164 and the uniform cut at row 168 would leave rows 168 and
        // 169 of ring, which pass as indicator colour, across them.
        for (file, highlight, timer) in Self.cutFrames {
            var canvas = Canvas(try Self.recoloured(Self.band(file), ring: tone))
            canvas.fill(rows: 165..<170, columns: 220..<381) { _, _ in tone }
            let band = try canvas.band()
            let edge = try #require(SlotStripReader().windowLowerEdge(band, lastCoveredRow: 164))
            #expect(edge[220..<381].allSatisfy { $0 == 173 }, Comment(rawValue: file))
            // Never more than the ring's 5 rows below it, and elsewhere the
            // uniform cut, but for a few columns where the recoloured shadow
            // row under the ring now has the ring's colour.
            #expect(edge.allSatisfy { (168...173).contains($0) }, Comment(rawValue: file))
            let outside = Array(edge[60..<220]) + Array(edge[381..<540])
            #expect(outside.filter { $0 == 168 }.count >= outside.count * 9 / 10, Comment(rawValue: file))
            Self.expectFiveSlots(Self.bothArms(band, "\(file) bowed in \(tone)"), highlight: highlight,
                                 timer: timer, "\(file) bowed in \(tone)")
        }
    }

    // MARK: What must not read

    @Test("The window lowered until the indicators lose their full width or height leaves no row")
    func loweredWindow() throws {
        for (file, highlight, timer) in Self.cutFrames {
            let band = try Self.band(file)
            for dy in stride(from: 0, through: 72, by: 2) {
                let label = "\(file) lowered \(dy)"
                let result = Self.bothArms(try Self.shifted(band, dx: 0, dy: dy), label)
                // Never a shortened or completed row: either the row as seen
                // without the window moved, or nothing.
                if case .success = result {
                    Self.expectFiveSlots(result, highlight: highlight, timer: timer, label)
                }
                // 0.4 of the 79 px width shows down to a cut at row 194,
                // where the upright sides still run (they end near row 203).
                if dy <= 20 { #expect((try? result.get()) != nil, Comment(rawValue: label)) }
                if dy >= 32 { #expect((try? result.get()) == nil, Comment(rawValue: label)) }
            }
        }
    }

    /// The recorded window with its lower edge or interior changed so that
    /// it is no longer our window's: the old rule refuses the row under it,
    /// and so must the new one.
    enum Impostor: String, CaseIterable {
        case darkEdge, noisyEdge, brightInterior, ringColouredInterior

        func paint(_ canvas: inout Canvas) {
            let columns = WindowLowerEdgeTests.windowColumns
            switch self {
            case .darkEdge:
                // Lit, but too dark for a ring.
                canvas.fill(rows: 160..<165, columns: columns) { _, _ in [40, 44, 64] }
            case .noisyEdge:
                var state: UInt32 = 12_345
                canvas.fill(rows: 160..<165, columns: columns) { _, _ in
                    (0..<3).map { _ in
                        state = state &* 1_103_515_245 &+ 12_345
                        return UInt8(truncatingIfNeeded: state >> 16)
                    }
                }
            case .brightInterior:
                // Brighter than the ring, above the dark seam on row 159.
                canvas.fill(rows: 114..<159, columns: columns) { _, _ in [200, 200, 200] }
            case .ringColouredInterior:
                // The ring's colour running far above it: a panel, not a ring.
                canvas.fill(rows: 141..<159, columns: columns) { _, _ in [240, 125, 130] }
            }
        }
    }

    @Test("A window whose edge or interior is unlike ours leaves no row", arguments: Impostor.allCases)
    func impostors(impostor: Impostor) throws {
        for (file, _, _) in Self.cutFrames {
            var canvas = Canvas(try Self.band(file))
            impostor.paint(&canvas)
            let band = try canvas.band()
            let label = "\(file) under \(impostor.rawValue)"
            let lastCovered = try #require(Self.lastCoveredRow(band), Comment(rawValue: label))
            #expect(SlotStripReader().windowLowerEdge(band, lastCoveredRow: lastCovered) == nil,
                    Comment(rawValue: label))
            #expect(throws: SlotStripRejection.self, Comment(rawValue: label)) {
                try Self.bothArms(band, label).get()
            }
        }
    }

    /// The strip's last row lit across `bannerMinimumRowCoverage` of the width.
    static func lastCoveredRow(_ band: FrameTopBand) -> Int? {
        let layout = GameUILayout()
        let required = Int((layout.bannerMinimumRowCoverage * Double(band.image.width)).rounded(.up))
        return band.rows(layout.slotStripTop, layout.slotStripBottom).last { y in
            (0..<band.image.width).filter { SlotStripReader.isLit(band.image[$0, y]) }.count >= required
        }
    }

    /// The columns of the five-slot row's indicator `index`, glow included.
    static func indicatorColumns(_ index: Int) -> Range<Int> {
        let centre = Int((fiveSlotCentres[index] * 603).rounded())
        return (centre - 46)..<(centre + 47)
    }

    @Test("Below the window, a missing or misplaced indicator or bare fragments leave no row")
    func incompleteRows() throws {
        let below = Self.windowRows.upperBound..<260
        for (file, _, _) in Self.cutFrames {
            let band = try Self.band(file)
            for index in [0, 2, 4] {
                var canvas = Canvas(band)
                canvas.fill(rows: below, columns: Self.indicatorColumns(index)) { _, _ in [0, 0, 0] }
                #expect(throws: SlotStripRejection.self, Comment(rawValue: "\(file) without \(index)")) {
                    try Self.bothArms(try canvas.band(), "\(file) without \(index)").get()
                }
            }
            // The last indicator moved 24 px off its place.
            var moved = Canvas(band)
            let columns = Self.indicatorColumns(4)
            moved.fill(rows: below, columns: columns) { _, _ in [0, 0, 0] }
            let original = Canvas(band)
            moved.fill(rows: below, columns: (columns.lowerBound + 24)..<min(603, columns.upperBound + 24)) { x, y in
                original[x - 24, y]
            }
            #expect(throws: SlotStripRejection.self, Comment(rawValue: "\(file) off the grid")) {
                try Self.bothArms(try moved.band(), "\(file) off the grid").get()
            }
            // Only the indicators' bottom points, below row 206.
            var fragments = Canvas(band)
            fragments.fill(rows: Self.windowRows.upperBound..<206, columns: 0..<603) { _, _ in [0, 0, 0] }
            #expect(throws: SlotStripRejection.self, Comment(rawValue: "\(file) fragments")) {
                try Self.bothArms(try fragments.band(), "\(file) fragments").get()
            }
        }
    }
}
