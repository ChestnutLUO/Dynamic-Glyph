import CoreGraphics
import Foundation
import Testing
import GlyphRecognitionImages
@testable import GlyphRecognition

/// Composites the actual PiP renderer onto captured game pixels. These tests
/// need no external CSVs, so Cloud exercises the recognition/display boundary.
@Suite("Covered game evidence")
struct OverlayEvidenceTests {
    private let session = CaptureSessionID(rawValue: 42)

    private func band(_ name: String = "Phases/field-00443.png") throws -> FrameTopBand {
        let image = try #require(ImageDecoder.cgImage(from: Data(contentsOf:
            ReferenceData.fixturesDirectory.appendingPathComponent(name))))
        return try ImageDecoder.topBand(image)
    }

    private func cover(_ band: FrameTopBand, x: Int, y: Int, width: Int, height: Int,
                       pixels cover: [UInt8]) throws -> FrameTopBand {
        var pixels = band.image.pixels
        for row in 0..<height where y + row >= 0 && y + row < band.image.height {
            for column in 0..<width where x + column >= 0 && x + column < band.image.width {
                let offset = ((y + row) * band.image.width + x + column) * 3
                let source = (row * width + column) * 3
                pixels.replaceSubrange(offset..<(offset + 3), with: cover[source..<(source + 3)])
            }
        }
        return FrameTopBand(image: try ColorImage(width: band.image.width, height: band.image.height,
                                                  pixels: pixels), frameHeight: band.frameHeight)
    }

    /// The window as the app draws it, with its edge in `tone`.
    private func pip(width: Int, height: Int, tone: StatusTone) throws -> [UInt8] {
        // An owned tiny vocabulary; no reference-table dependency.
        let table = try GlyphTable.parse(csv: "test,03\n")
        let state: TrackingState = switch tone {
        case .idle: .inactive
        case .drawing: .input
        case .done: .completed
        case .warning, .tentative, .collecting: .presenting
        }
        let snapshot = GlyphDisplaySnapshot(captureSessionID: session, hackID: 1, revision: 1,
            liveness: .live, state: state, phaseSource: .headerText, acceptance: .trackingSequence,
            sourceFrameTime: 1, evidenceArrivalUptime: 10, expectedSlotCount: nil,
            slots: tone == .tentative ? [SlotObservation(index: 0, status: .inferred, glyph: GlyphID("test"))] : [],
            currentSlotIndex: nil, inputSlotIndex: nil, indicatorsObstructed: tone == .warning,
            slotCountConflict: false, isFrozen: false, provisionalGlyph: nil,
            provisionalExtensionCount: 0, outlook: .unavailable, calibrationSummary: "11 rings")
        try #require(snapshot.displayStatus(atUptime: 10).tone == tone)
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        GlyphDisplayRenderer(table: table).draw(snapshot, in: context,
            size: CGSize(width: width, height: height), atUptime: 10, windowCornerRadius: 13.5)
        return try ImageDecoder.decodeColor(#require(context.makeImage()),
            in: CGRect(x: 0, y: 0, width: width, height: height)).pixels
    }

    private func evidence(_ band: FrameTopBand, at time: Double) -> FrameEvidence {
        let reader = SlotStripReader()
        return FrameEvidence(sessionID: session, time: time,
            header: HeaderReading(phase: .presenting, matchedText: "incoming glyph sequence",
                                  confidence: 1, sourceTime: time),
            slots: try? reader.read(band).get(),
            shape: ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: []),
            hasValidCalibration: true, hasInputTimerBar: reader.hasTimerBar(band))
    }

    @Test("A PiP status edge over the timer region cannot end presentation", arguments: [StatusTone.tentative, .warning])
    func pipIsNotCountdown(tone: StatusTone) throws {
        let original = try band()
        for height in [71, 142] {
            let covered = try cover(original, x: 10, y: 302 - height, width: 284, height: height,
                                    pixels: pip(width: 284, height: height, tone: tone))
            #expect(!SlotStripReader().hasTimerBar(covered))
            var tracker = PresentationTracker(sessionID: session)
            for index in 0..<3 { _ = tracker.accept(evidence(original, at: 1 + Double(index) * 0.05)) }
            _ = tracker.accept(evidence(covered, at: 1.15))
            #expect(tracker.state == .presenting)
            #expect(tracker.phaseSource != .inputTimer)
        }
    }

    @Test("An opaque notification cannot turn four indicators into a trusted two-slot row", arguments: [0, 300])
    func missingWholeIndicators(left: Int) throws {
        let covered = try cover(band(), x: left, y: 135, width: 303, height: 100,
                                pixels: Array(repeating: 24, count: 303 * 100 * 3))
        #expect(SlotStripReader().read(covered) == .failure(.incompleteStrip))
        var tracker = PresentationTracker(sessionID: session)
        for index in 0..<3 { _ = tracker.accept(evidence(covered, at: 1 + Double(index) * 0.05)) }
        #expect(tracker.expectedSlotCount == nil)
        #expect(tracker.indicatorsObstructed)
    }

    @Test("A thin PiP border over the indicator tips leaves the full row readable", arguments: [StatusTone.tentative, .warning])
    func thinPiPOverIndicatorTips(tone: StatusTone) throws {
        let original = try band()
        let expected = try SlotStripReader().read(original).get()
        // The new field captures place a 380 x 38 pt window at the top:
        // approximately x=18, y=94, width=568, height=56 at capture scale.
        let covered = try cover(original, x: 18, y: 94, width: 568, height: 56,
                                pixels: pip(width: 568, height: 56, tone: tone))
        let reading = try SlotStripReader().read(covered).get()
        #expect(reading.slotCount == expected.slotCount)
        #expect(reading.highlightedIndex == expected.highlightedIndex)
        #expect(reading.isPartlyCovered)
        #expect(!reading.hasInputTimerBar)
    }

    @Test("PiP covering most or all indicators cannot produce a readable row", arguments: [80, 130, 150])
    func deepPiPCover(height: Int) throws {
        let covered = try cover(band(), x: 18, y: 94, width: 568, height: height,
                                pixels: pip(width: 568, height: height, tone: .warning))
        #expect(throws: SlotStripRejection.self) { try SlotStripReader().read(covered).get() }
    }

    @Test("PiP's own glyphs and border without game indicators cannot become a slot row")
    func pipWithoutIndicators() throws {
        let empty = FrameTopBand(image: try ColorImage(width: 603, height: 323,
            pixels: Array(repeating: 0, count: 603 * 323 * 3)), frameHeight: 1311)
        let covered = try cover(empty, x: 18, y: 94, width: 568, height: 56,
                                pixels: pip(width: 568, height: 56, tone: .tentative))
        #expect(SlotStripReader().read(covered) == .failure(.coveredByOverlay))
    }

    @Test("A window ending just above the strip leaves the row readable in every status colour",
          arguments: StatusTone.allCases)
    func windowEdgeAcrossIndicatorTips(tone: StatusTone) throws {
        let original = try band()
        let expected = try SlotStripReader().read(original).get()
        // As in the 2026-09-25 report: the window's lower edge lies on the
        // first four rows of the strip (136-139 at this scale), across the
        // tips of the indicators (from row 139).
        let window = try pip(width: 568, height: 56, tone: tone)
        let covered = try cover(original, x: 18, y: 84, width: 568, height: 56, pixels: window)
        let reading = try SlotStripReader().read(covered).get()
        #expect(reading.slotCount == expected.slotCount)
        #expect(reading.highlightedIndex == expected.highlightedIndex)
        #expect(reading.isPartlyCovered)

        // Nothing below it is hidden, so an empty screen is not "covered".
        let empty = FrameTopBand(image: try ColorImage(width: 603, height: 323,
            pixels: Array(repeating: 0, count: 603 * 323 * 3)), frameHeight: 1311)
        let bare = try cover(empty, x: 18, y: 84, width: 568, height: 56, pixels: window)
        #expect(SlotStripReader().read(bare) == .failure(.noMarkers))
    }

    private func covered(at time: Double, shape: ShapeEvidence.Kind, calibrated: Bool = true) -> FrameEvidence {
        FrameEvidence(sessionID: session, time: time, header: nil, slots: nil,
                      slotRejection: .coveredByOverlay,
                      shape: ShapeEvidence(kind: shape, glyph: shape == .uniqueVisibleShape ? GlyphID("test") : nil,
                                           edges: [], extensions: []),
                      hasValidCalibration: calibrated)
    }

    @Test("A window over the strip on the Glyph screen is reported before any hack is seen")
    func coveredBeforeAnyHack() {
        var tracker = PresentationTracker(sessionID: session)
        let kinds: [ShapeEvidence.Kind] = [.noStroke, .noStroke, .uniqueVisibleShape, .uniqueVisibleShape,
                                           .unrecognizedStroke, .noStroke, .unrecognizedStroke, .noStroke]
        var raised: Double?
        for (index, kind) in kinds.enumerated() {
            let time = 1 + Double(index) * 0.1
            _ = tracker.accept(covered(at: time, shape: kind))
            if raised == nil, tracker.indicatorsObstructed { raised = time }
        }
        // Raised after the grace, and kept while the player draws.
        let grace = PresentationTracker.Policy().indicatorObstructionGrace
        #expect(raised.map { $0 - 1 >= grace } == true)
        #expect(tracker.indicatorsObstructed)
        // Nothing is invented from it: no hack, no slots.
        #expect(tracker.state == .inactive)
        #expect(tracker.hackID == 0)
        #expect(tracker.slots.isEmpty)

        // Once the strip is readable again, or gone, the warning is withdrawn.
        _ = tracker.accept(FrameEvidence(sessionID: session, time: 2, header: nil, slots: nil,
                                         slotRejection: .noMarkers,
                                         shape: ShapeEvidence(kind: .noStroke, glyph: nil, edges: [], extensions: []),
                                         hasValidCalibration: true))
        #expect(!tracker.indicatorsObstructed)
    }

    @Test("A remembered calibration away from the Glyph screen does not raise it", arguments: [true, false])
    func coveredAwayFromTheGlyphScreen(calibrated: Bool) {
        var tracker = PresentationTracker(sessionID: session)
        for index in 0..<20 {
            // The home screen under a window: ink everywhere, never a clear
            // array or a Glyph, and possibly a calibration cached from before.
            let kind: ShapeEvidence.Kind = index % 2 == 0 ? .unexplainedInk : .unrecognizedStroke
            _ = tracker.accept(covered(at: 1 + Double(index) * 0.1, shape: kind, calibrated: calibrated))
        }
        #expect(!tracker.indicatorsObstructed)
        if !calibrated {
            for index in 0..<20 {
                _ = tracker.accept(covered(at: 5 + Double(index) * 0.1, shape: .noStroke, calibrated: false))
            }
            #expect(!tracker.indicatorsObstructed, "without the array there is no Glyph screen to speak of")
        }
    }

    @Test("A partly drained full track is readable, but an isolated gold edge is not")
    func fullTrackRequired() throws {
        let width = 603, height = 323
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        // Coordinates stated independently of the production layout constants.
        for y in 302..<306 {
            for x in 68..<536 {
                let offset = (y * width + x) * 3
                let color: [UInt8] = x < 340 ? [240, 180, 50] : [185, 165, 240]
                pixels.replaceSubrange(offset..<(offset + 3), with: color)
            }
        }
        let input = FrameTopBand(image: try ColorImage(width: width, height: height, pixels: pixels), frameHeight: 1311)
        #expect(SlotStripReader().hasTimerBar(input))
        let coveredRail = try cover(input, x: 340, y: 300, width: 200, height: 10,
                                    pixels: Array(repeating: 0, count: 200 * 10 * 3))
        #expect(!SlotStripReader().hasTimerBar(coveredRail))
    }

    @Test("A nearly expired gold or magenta countdown still has a complete rail")
    func nearlyExpiredTimer() throws {
        let width = 603, height = 323
        for progress: [UInt8] in [[240, 180, 50], [237, 55, 153]] {
            var pixels = [UInt8](repeating: 0, count: width * height * 3)
            for y in 302..<306 {
                for x in 68..<536 {
                    let offset = (y * width + x) * 3
                    let color: [UInt8] = (300..<330).contains(x) ? progress : [185, 165, 240]
                    pixels.replaceSubrange(offset..<(offset + 3), with: color)
                }
            }
            let band = FrameTopBand(image: try ColorImage(width: width, height: height,
                                                           pixels: pixels), frameHeight: 1311)
            #expect(SlotStripReader().hasTimerBar(band))
            let broken = try cover(band, x: 350, y: 300, width: 120, height: 10,
                                   pixels: Array(repeating: 0, count: 120 * 10 * 3))
            #expect(!SlotStripReader().hasTimerBar(broken))
        }
    }

    @Test("Complete centred rows with two through five indicators remain readable", arguments: [2, 3, 4, 5])
    func completeRows(count: Int) throws {
        let width = 600, height = 323
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<count {
            let center = 300 + (2 * index - count + 1) * 48
            for y in 145..<225 {
                for x in (center - 40)..<(center + 40) {
                    if y >= 149 && y < 221 && x >= center - 36 && x < center + 36 { continue }
                    let offset = (y * width + x) * 3
                    pixels.replaceSubrange(offset..<(offset + 3), with: [185, 165, 240])
                }
            }
        }
        let input = FrameTopBand(image: try ColorImage(width: width, height: height, pixels: pixels), frameHeight: 1311)
        #expect(try SlotStripReader().read(input).get().slotCount == count)
    }
}
