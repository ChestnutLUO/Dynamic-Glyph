import Foundation
import Testing
import GlyphCoreCxx
import GlyphRecognitionImages
@testable import GlyphRecognition

/// The search for our window's lower edge is skipped when what showed below
/// the thin-window rule's cut could not hold a row
/// (`SlotStripReader.couldReadBelowWindowEdge`). It must change no reading:
/// every band here is observed with the gate and with the search run every
/// time, and read by the C++ reader, which gates alike.
@Suite("Edge search gate")
struct EdgeSearchGateTests {
    /// The gated and ungated observations are equal, field for field, and
    /// the C++ reading and cover equal the Swift ones.
    static func expectUnchanged(_ band: FrameTopBand, _ label: String,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let reader = SlotStripReader()
        let gated = reader.observe(band, gatesEdgeSearch: true)
        let searched = reader.observe(band, gatesEdgeSearch: false)
        #expect(gated == searched, Comment(rawValue: label), sourceLocation: sourceLocation)
        let cxx = CxxSlotStripTests.readCxx(band).reading
        #expect(cxx.status == CxxSlotStripTests.status(of: gated.reading), Comment(rawValue: label),
                sourceLocation: sourceLocation)
        if case .success(let reading) = gated.reading, cxx.status == GC_SLOT_OK {
            CxxSlotStripTests.expectEqual(cxx, reading, label, sourceLocation: sourceLocation)
        }
        CxxSlotStripTests.expectEqual(cxx, gated.cover, label, sourceLocation: sourceLocation)
    }

    @Test("Every fixture reads the same with the gate as with the search every time",
          arguments: CxxSlotStripTests.fixtureFolders)
    func fixtures(folder: String) throws {
        for url in try CxxSlotStripTests.fixtureImages(in: folder) {
            Self.expectUnchanged(try CxxSlotStripTests.band(url), "\(folder)/\(url.lastPathComponent)")
        }
    }

    @Test("Our window's lower edge moved, recoloured, bowed and lowered reads the same with the gate")
    func lowerEdgeVariants() throws {
        let moves = [(0, -4), (0, -2), (0, 2), (0, 4), (0, 8), (-8, 0), (8, 0), (-6, 3), (6, -3)]
        for (file, _, _) in WindowLowerEdgeTests.cutFrames + WindowLowerEdgeTests.screensWithoutRow.map({ ($0, 0, false) }) {
            let band = try WindowLowerEdgeTests.band(file)
            for (dx, dy) in moves {
                Self.expectUnchanged(try WindowLowerEdgeTests.shifted(band, dx: dx, dy: dy), "\(file) moved \(dx), \(dy)")
            }
            for dy in stride(from: 0, through: 72, by: 2) {
                Self.expectUnchanged(try WindowLowerEdgeTests.shifted(band, dx: 0, dy: dy), "\(file) lowered \(dy)")
            }
            for tone in WindowLowerEdgeTests.ringTones {
                let recoloured = try WindowLowerEdgeTests.recoloured(band, ring: tone)
                Self.expectUnchanged(recoloured, "\(file) in \(tone)")
                var bowed = WindowLowerEdgeTests.Canvas(recoloured)
                bowed.fill(rows: 165..<170, columns: 220..<381) { _, _ in tone }
                Self.expectUnchanged(try bowed.band(), "\(file) bowed in \(tone)")
            }
        }
    }

    @Test("Covers that are not our window, and rows missing an indicator, read the same with the gate")
    func impostorsAndIncompleteRows() throws {
        let below = WindowLowerEdgeTests.windowRows.upperBound..<260
        for (file, _, _) in WindowLowerEdgeTests.cutFrames {
            let band = try WindowLowerEdgeTests.band(file)
            for impostor in WindowLowerEdgeTests.Impostor.allCases {
                var canvas = WindowLowerEdgeTests.Canvas(band)
                impostor.paint(&canvas)
                Self.expectUnchanged(try canvas.band(), "\(file) under \(impostor.rawValue)")
            }
            for index in 0..<5 {
                var canvas = WindowLowerEdgeTests.Canvas(band)
                canvas.fill(rows: below, columns: WindowLowerEdgeTests.indicatorColumns(index)) { _, _ in [0, 0, 0] }
                Self.expectUnchanged(try canvas.band(), "\(file) without \(index)")
            }
            var fragments = WindowLowerEdgeTests.Canvas(band)
            fragments.fill(rows: WindowLowerEdgeTests.windowRows.upperBound..<206, columns: 0..<603) { _, _ in [0, 0, 0] }
            Self.expectUnchanged(try fragments.band(), "\(file) fragments")
        }
    }

    @Test("The window beside the row, mirrored and at other sizes, reads the same with the gate")
    func windowCoverVariants() throws {
        for url in try CxxSlotStripTests.fixtureImages(in: "WindowCover") {
            for (label, band) in try WindowCoverTests.sizes(url.lastPathComponent) {
                Self.expectUnchanged(band, label)
                Self.expectUnchanged(try WindowCoverTests.mirrored(band), "\(label) mirrored")
            }
        }
        for url in try CxxSlotStripTests.fixtureImages(in: "WindowLowerEdge") {
            let band = try CxxSlotStripTests.band(url)
            Self.expectUnchanged(try WindowCoverTests.mirrored(band), "\(url.lastPathComponent) mirrored")
        }
    }

    // MARK: The gate itself

    /// Tallies over a 603 px row below a cut: indicator columns `runs`, each
    /// lit with indicator colour from `top` to `bottom`.
    static func columns(_ runs: [(range: Range<Int>, top: Int, bottom: Int)], width: Int = 603)
        -> (gold: [Int], violet: [Int], firstRows: [Int], lastRows: [Int]) {
        var violet = [Int](repeating: 0, count: width)
        var firstRows = [Int](repeating: 323, count: width)
        var lastRows = [Int](repeating: -1, count: width)
        for run in runs {
            for x in run.range {
                violet[x] = run.bottom - run.top + 1
                firstRows[x] = run.top
                lastRows[x] = run.bottom
            }
        }
        return ([Int](repeating: 0, count: width), violet, firstRows, lastRows)
    }

    static func couldRead(_ runs: [(range: Range<Int>, top: Int, bottom: Int)]) -> Bool {
        let tallies = columns(runs)
        return SlotStripReader().couldReadBelowWindowEdge(gold: tallies.gold, violet: tallies.violet,
                                                          firstRows: tallies.firstRows, lastRows: tallies.lastRows)
    }

    @Test("The gate passes any run that could hold a marker on the grid, and only those")
    func gateBounds() {
        // 0.085 of 603 px is 51.3: a run of 52 columns can hold a marker, and
        // 0.4 of that is 20.5 rows.
        #expect(Self.couldRead([(276..<328, 170, 190)]))
        #expect(!Self.couldRead([(276..<327, 170, 230)]))
        #expect(!Self.couldRead([(276..<328, 170, 189)]))
        // The lone indicator's place is the centre, within 0.035 of the
        // width and a pixel: 21.1 + 1 px.
        #expect(Self.couldRead([(254..<306, 170, 200)]))
        #expect(!Self.couldRead([(252..<304, 170, 200)]))
        // Two runs away from the centre hold the two-slot row's places.
        let two = [0.42, 0.58].map { Int(($0 * 603).rounded()) }
        #expect(Self.couldRead(two.map { (($0 - 26)..<($0 + 26), 170, 200) }))
        // One of them alone holds no row of any count.
        #expect(!Self.couldRead([((two[1] - 26)..<(two[1] + 26), 170, 200)]))
        // A run as wide as the strip can hold a marker anywhere.
        #expect(Self.couldRead([(10..<593, 170, 200)]))
        // Nothing lit with indicator colour.
        #expect(!Self.couldRead([]))
    }
}
