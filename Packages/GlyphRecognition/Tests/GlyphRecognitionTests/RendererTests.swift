import CoreGraphics
import Foundation
import Testing
@testable import GlyphRecognitionImages
@testable import GlyphRecognition

/// Renders into a bitmap and reads the pixels back.
///
/// The transform between a sample-buffer bitmap and the diagram's own top-left
/// origin is the one piece of the display that can be wrong in a way no model
/// test would catch: a vertically mirrored Glyph is still a perfectly plausible
/// picture, just of a different Glyph.
@Suite("Display rendering")
struct RendererTests {
    private let size = CGSize(width: 384, height: 96)

    @Test("Canvas bounds and resolution are clamped and preserve proportions")
    func configurableCanvas() {
        let clamped = PiPCanvasConfiguration(width: Int.max, height: Int.min, resolution: Int.max)
        #expect(clamped.pixelWidth == 1920)
        #expect(clamped.pixelHeight == 192)
        for width in [256, 384, 640] {
            for height in [64, 96, 192] {
                let canvas = PiPCanvasConfiguration(width: width, height: height, resolution: 3)
                #expect(canvas.aspectRatio == Double(width) / Double(height))
            }
        }
    }

    /// 640 x 64 is the canvas on the phone, and iOS gave it a window 353
    /// points wide: the canvas is shrunk to 0.55, so its share of a 9 pt
    /// corner is larger than 9.
    @Test("The window's corner radius is converted into canvas units")
    func cornerRadiusScale() {
        let canvas = PiPCanvasConfiguration(width: 640, height: 64)
        #expect(abs(canvas.cornerRadius(windowWidth: 353) - 9 * 640 / 353.0) < 1e-9)
        #expect(canvas.cornerRadius(windowWidth: 640) == PiPCanvasConfiguration.windowCornerRadius)
        #expect(canvas.cornerRadius(windowWidth: nil) == PiPCanvasConfiguration.windowCornerRadius)
        #expect(canvas.cornerRadius(windowWidth: 0) == PiPCanvasConfiguration.windowCornerRadius)
    }

    /// The system rounds the window's corners, so a square inner edge would
    /// leave the status colour fat at every corner. With the window's radius
    /// the content's corner is rounded away and the band stays even; along
    /// the sides nothing changes.
    @Test("The status edge's inner corners follow the window's rounding")
    func roundedInnerCorners() throws {
        let model = snapshot(slots: [], expected: nil)
        let square = try render(model, table: nil)
        let rounded = try render(model, table: nil, windowCornerRadius: 30)
        // The ring is 7.68 wide on a 96-tall canvas; (9, 9) is just inside it.
        let edge = Int(square[1, 48])
        let background = Int(square[9, 9])
        #expect(edge > background + 100, "the edge should be much brighter than the content")
        #expect(abs(Int(rounded[9, 9]) - edge) < 20, "the inner corner was not rounded away")
        // Mid-side, just inside the ring: content in both.
        #expect(abs(Int(rounded[192, 9]) - background) < 20)
        #expect(abs(Int(rounded[9, 48]) - background) < 20)
        // A radius smaller than the ring leaves the inner corner square.
        #expect(abs(Int(try render(model, table: nil, windowCornerRadius: 6)[9, 9]) - background) < 20)
    }

    @Test("Inferred observations remain dashed and cannot become next-glyph guidance")
    func inferredStyle() {
        let model = snapshot(slots: [SlotObservation(index: 0, status: .inferred, glyph: GlyphID("see"))],
                             expected: nil, state: .input, inputSlotIndex: 0)
        #expect(model.tileStyles == [.inferred(GlyphID("see"))])
        #expect(model.tileStyles[0].isDashed)
        #expect(model.note(for: model.tileStyles[0]) == "Inferred · position unverified")
        #expect(model.statusLine(atUptime: 10).contains("positions unverified"))
        #expect(model.upcomingGuidance() == nil)
        let verified = snapshot(slots: [SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("see"))],
                                expected: 1, state: .input, inputSlotIndex: 0)
        #expect(verified.upcomingGuidance()?.styles == [.confirmed(GlyphID("see"))])
    }

    private func render(_ snapshot: GlyphDisplaySnapshot, table: GlyphTable?,
                        windowCornerRadius: CGFloat = 0, size: CGSize? = nil) throws -> LuminanceImage {
        let size = size ?? self.size
        let width = Int(size.width), height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else {
                throw CocoaError(.featureUnsupported)
            }
            GlyphDisplayRenderer(table: table).draw(snapshot, in: context, size: size, atUptime: 10,
                                                    windowCornerRadius: windowCornerRadius)
        }
        // Row zero of the buffer is the top row of the image, both for a
        // bitmap context and for the pixel buffer the display layer is handed.
        // That is exactly why the renderer flips the context: without it,
        // Core Graphics would write its y = 0 into the last row.
        var grey = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let value = (Int(pixels[base + 2]) * 299 + Int(pixels[base + 1]) * 587
                             + Int(pixels[base]) * 114) / 1000
                grey[y * width + x] = UInt8(min(255, value))
            }
        }
        return try LuminanceImage(width: width, height: height, pixels: grey)
    }

    private func snapshot(slots: [SlotObservation], expected: Int?,
                          outlook: SequenceOutlook = .unavailable,
                          state: TrackingState = .presenting, inputSlotIndex: Int? = nil,
                          gear: GearDropDisplay? = nil) -> GlyphDisplaySnapshot {
        GlyphDisplaySnapshot(
            captureSessionID: CaptureSessionID(rawValue: 1), hackID: 1, revision: 1,
            liveness: .live, state: state, phaseSource: .headerText,
            acceptance: .trackingSequence, sourceFrameTime: 5, evidenceArrivalUptime: 10,
            expectedSlotCount: expected, slots: slots, currentSlotIndex: nil, inputSlotIndex: inputSlotIndex,
            slotCountConflict: false, isFrozen: false, provisionalGlyph: nil,
            provisionalExtensionCount: 0, outlook: outlook, calibrationSummary: "11 rings", gear: gear)
    }

    @Test("PiP renders gear status after a hack without replacing active Glyph tiles")
    func gearStatus() throws {
        let gear = GearDropDisplay(state: .reading, hackID: 1, waitingCount: 1)
        let blank = try render(snapshot(slots: [], expected: nil, state: .completed), table: nil)
        let reading = try render(snapshot(slots: [], expected: nil, state: .completed, gear: gear), table: nil)
        let active = try render(snapshot(slots: [], expected: nil, state: .input), table: nil)
        let activeWithGear = try render(snapshot(slots: [], expected: nil, state: .input, gear: gear), table: nil)
        var changed = 0, changedDuringInput = 0
        for y in 10..<85 {
            for x in 10..<370 {
                if blank[x, y] != reading[x, y] { changed += 1 }
                if active[x, y] != activeWithGear[x, y] { changedDuringInput += 1 }
            }
        }
        #expect(changed > 100)
        #expect(changedDuringInput == 0)
    }

    @Test("The waiting hint is as large as the gear status", arguments: [CGSize(width: 380, height: 38), CGSize(width: 384, height: 96)])
    func messageSizes(_ canvas: CGSize) throws {
        // Rows holding text: brighter than the dark background, inside the edge.
        func textRows(_ image: LuminanceImage) -> ClosedRange<Int>? {
            let rows = (0..<image.height).filter { y in
                (Int(canvas.width * 0.1)..<Int(canvas.width * 0.9)).contains { x in image[x, y] > 90 }
                    && y > Int(canvas.height * 0.1) && y < Int(canvas.height * 0.9)
            }
            guard let first = rows.first, let last = rows.last else { return nil }
            return first...last
        }
        let idle = try render(snapshot(slots: [], expected: nil, state: .inactive), table: nil, size: canvas)
        let gear = try render(snapshot(slots: [], expected: nil, state: .completed,
                                       gear: GearDropDisplay(state: .waiting, hackID: 1, waitingCount: 1)),
                              table: nil, size: canvas)
        let hint = try #require(textRows(idle)), status = try #require(textRows(gear))
        // Cap height and baseline agree; descenders may differ by a pixel.
        #expect(abs(hint.lowerBound - status.lowerBound) <= 1, "hint \(hint), gear \(status)")
        #expect(abs(hint.count - status.count) <= 3, "hint \(hint), gear \(status)")
    }

    /// Ink in the half of a tile a Glyph should occupy, ignoring the caption
    /// row and the status edge.
    private func ink(_ image: LuminanceImage, _ rect: (x: Range<Int>, y: Range<Int>)) -> Int {
        var count = 0
        for y in rect.y where y < image.height {
            for x in rect.x where x < image.width { if image[x, y] > 110 { count += 1 } }
        }
        return count
    }

    @Test("An asymmetric Glyph is drawn the right way up and the right way round", .enabled(if: ReferenceData.shapesAvailable))
    func orientation() throws {
        let table = try ReferenceData.glyphTable()
        // future = 2479: entirely in the right half of its tile, descending.
        let rendered = try render(snapshot(
            slots: [SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("future"))],
            expected: 1), table: table)
        // One tile spans the full content width. Diagram area only, inside
        // the status edge. With one slot the diagram is a centred square, at
        // x 162-222 and y 18-78, from the renderer's inset, status-edge and
        // tile arithmetic on a 384 x 96 canvas.
        let box = (x: 165..<220, y: 18..<72, midX: 192, midY: 45)
        let left = ink(rendered, (x: box.x.lowerBound..<box.midX, y: box.y))
        let right = ink(rendered, (x: box.midX..<box.x.upperBound, y: box.y))
        #expect(right > left * 3, "future must be drawn on the right: left=\(left) right=\(right)")

        // begin = 06a7 reaches the apex and the base, so it fills the tile
        // vertically; its topmost ink must be near the top of the diagram box.
        let begins = try render(snapshot(
            slots: [SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("begin"))],
            expected: 1), table: table)
        #expect(ink(begins, (x: box.x, y: box.y.lowerBound..<box.midY)) > 0)
        #expect(ink(begins, (x: box.x, y: box.midY..<box.y.upperBound)) > 0)

        // The decisive comparison: `see` = 03 runs from the apex down to the
        // upper-left inner node, so its ink is in the TOP half of the tile. A
        // vertically flipped renderer puts it in the bottom half.
        let see = try render(snapshot(
            slots: [SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("see"))],
            expected: 1), table: table)
        let seeUpper = ink(see, (x: box.x, y: box.y.lowerBound..<box.midY))
        let seeLower = ink(see, (x: box.x, y: box.midY..<box.y.upperBound))
        #expect(seeUpper > seeLower * 3, "see must sit high: upper=\(seeUpper) lower=\(seeLower)")
    }

    /// `see` = 03 uses two nodes at the top of the array. Without the frame
    /// its tile would be dark everywhere else, and a small shape at the top
    /// would look the same as a larger one anywhere. The base node is well
    /// away from the stroke, so anything drawn there is the frame.
    @Test("Every Glyph sits on a visible array, drawn dimmer than the stroke", .enabled(if: ReferenceData.shapesAvailable))
    func arrayFrame() throws {
        let table = try ReferenceData.glyphTable()
        let see = try render(snapshot(
            slots: [SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("see"))],
            expected: 1), table: table)
        // The same tile arithmetic as the orientation test: the diagram square
        // is x 162-222, y 18-78, and the layout's 0.06 inset puts the base node
        // at its bottom centre.
        let square = (x: 162.3, y: 18.3, side: 59.3)
        let inset = 0.06 * square.side
        let base = (x: Int(square.x + square.side / 2), y: Int(square.y + square.side - inset))
        // The square's corner lies outside the hexagon: plain background.
        let background = Int(see[Int(square.x) + 2, Int(square.y) + 2])
        var brightest = 0
        for y in (base.y - 2)...(base.y + 2) {
            for x in (base.x - 2)...(base.x + 2) { brightest = max(brightest, Int(see[x, y])) }
        }
        #expect(brightest > background + 25, "no frame at the base node: \(brightest) vs \(background)")
        // Dimmer than any stroke colour, so the Glyph still reads first.
        #expect(brightest < 110, "the frame is as bright as a stroke: \(brightest)")
    }

    /// The window is captured along with the game. A frame of eleven nodes is
    /// the closest the display has come to looking like the array itself, so
    /// render it as large as a phone screen and check the calibrator refuses
    /// it. The calibrator needs the apex, the base and eight nodes in all;
    /// `simple` = 67 touches only the two lower inner nodes, which leaves nine
    /// untouched including both anchors: the most array-like tile there is.
    @Test("The array frame cannot be calibrated onto", .enabled(if: ReferenceData.shapesAvailable))
    func frameIsNotAnArray() throws {
        let table = try ReferenceData.glyphTable()
        let side = 600
        for glyph in ["simple", "future"] {
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                              bitsPerComponent: 8, bytesPerRow: side * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                  | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw CocoaError(.featureUnsupported)
                }
                GlyphDisplayRenderer(table: table).draw(
                    snapshot(slots: [SlotObservation(index: 0, status: .confirmed, glyph: GlyphID(glyph))],
                             expected: 1),
                    in: context, size: CGSize(width: side, height: side), atUptime: 10)
            }
            var grey = [UInt8](repeating: 0, count: side * side)
            for pixel in 0..<(side * side) {
                let base = pixel * 4
                grey[pixel] = UInt8((Int(pixels[base + 2]) * 299 + Int(pixels[base + 1]) * 587
                                     + Int(pixels[base]) * 114) / 1000)
            }
            let image = try LuminanceImage(width: side, height: side, pixels: grey)
            #expect(NodeArrayDetector().detect(in: image) == nil, "calibrated onto the frame behind \(glyph)")
        }
    }

    /// The window used to carry a lime hairline so the app could find itself
    /// in its own capture. It was dropped as clutter; this keeps it from
    /// creeping back, in any status the edge can show.
    @Test("No state draws a green border", .enabled(if: ReferenceData.shapesAvailable))
    func noGreenBorder() throws {
        let table = try ReferenceData.glyphTable()
        let models = [
            snapshot(slots: [], expected: nil),
            snapshot(slots: [SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("see"))],
                     expected: 1, state: .input, inputSlotIndex: 0),
            snapshot(slots: [SlotObservation(index: 0, status: .inferred, glyph: GlyphID("see"))],
                     expected: nil),
            snapshot(slots: [SlotObservation(index: 0, status: .missing)], expected: 1, state: .completed)
        ]
        let width = Int(size.width), height = Int(size.height)
        for model in models {
            for uptime in [10.0, 13.0] {
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
                        throw CocoaError(.featureUnsupported)
                    }
                    GlyphDisplayRenderer(table: table).draw(model, in: context, size: size, atUptime: uptime)
                }
                // BGRA in memory. Green well above both other channels is the
                // old marker's signature; no palette colour comes near it.
                let green = stride(from: 0, to: pixels.count, by: 4).filter { base in
                    let b = Int(pixels[base]), g = Int(pixels[base + 1]), r = Int(pixels[base + 2])
                    return g >= 150 && g - r >= 55 && g - b >= 55
                }.count
                #expect(green == 0, "\(green) green pixels in \(model.displayStatus(atUptime: uptime))")
            }
        }
    }

    @Test("The edge colour follows the status, and says so in the same words")
    func edgeColourFollowsStatus() {
        let renderer = GlyphDisplayRenderer(table: nil)
        let live = snapshot(slots: [], expected: nil)
        #expect(live.displayStatus(atUptime: 10) == .collecting)
        // Stale outranks whatever the phase was; the colour and the words agree.
        #expect(live.displayStatus(atUptime: 13) == .stale)
        #expect(live.statusLine(atUptime: 13) == "Paused")
        let warning = renderer.statusColour(live, atUptime: 13)
        #expect(warning == renderer.palette.warning)
        #expect(renderer.statusColour(live, atUptime: 10) == renderer.palette.predicted)
    }

    @Test("Observed, predicted and missing slots are captioned differently", .enabled(if: ReferenceData.isAvailable))
    func captionsDistinguishEvidence() throws {
        let predictor = SequencePredictor(table: try ReferenceData.sequenceTable())
        let outlook = predictor.outlook(observed: [GlyphID("change"), GlyphID("perspective")],
                                        expectedLength: 4)
        let renderer = GlyphDisplayRenderer(table: try ReferenceData.glyphTable())
        let model = snapshot(slots: [
            SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("change")),
            SlotObservation(index: 1, status: .confirmed, glyph: GlyphID("perspective")),
            SlotObservation(index: 2), SlotObservation(index: 3)
        ], expected: 4, outlook: outlook)
        let styles = model.tileStyles
        #expect(styles.count == 4)
        if case .confirmed(let id) = styles[0] { #expect(id.name == "change") } else { Issue.record("slot 1") }
        if case .predicted(let id) = styles[2] { #expect(id.name == "begin") } else { Issue.record("slot 3") }
        if case .predicted(let id) = styles[3] { #expect(id.name == "new") } else { Issue.record("slot 4") }
        #expect(renderer.predictionLine(model).contains("One sequence matches"))

        // A missed slot keeps its position and says so.
        let missed = snapshot(slots: [
            SlotObservation(index: 0, status: .confirmed, glyph: GlyphID("change")),
            SlotObservation(index: 1, status: .missing),
            SlotObservation(index: 2, status: .confirmed, glyph: GlyphID("begin"))
        ], expected: 3, outlook: predictor.outlook(observed: [GlyphID("change")], expectedLength: 3))
        let missedStyles = missed.tileStyles
        if case .missing = missedStyles[1] {} else { Issue.record("slot 2 should be missing") }
        if case .confirmed(let id) = missedStyles[2] { #expect(id.name == "begin") }
        else { Issue.record("slot 3 keeps its place") }
    }

    @Test("A stale or obstructed display says so instead of looking fresh")
    func honestStatusLines() throws {
        var model = snapshot(slots: [], expected: nil)
        #expect(model.statusLine(atUptime: 10) == "Watching the sequence")
        #expect(model.statusLine(atUptime: 13) == "Paused")

        model = GlyphDisplaySnapshot(
            captureSessionID: CaptureSessionID(rawValue: 1), hackID: 1, revision: 1,
            liveness: .live, state: .presenting, phaseSource: .headerText,
            acceptance: .trackingSequence, sourceFrameTime: 5, evidenceArrivalUptime: 10,
            expectedSlotCount: nil, slots: [], currentSlotIndex: nil, inputSlotIndex: nil,
            indicatorsObstructed: true, slotCountConflict: false, isFrozen: false, provisionalGlyph: nil,
            provisionalExtensionCount: 0, outlook: .unavailable, calibrationSummary: "11 rings")
        #expect(model.statusLine(atUptime: 10) == "Slot row covered · move the window")
        #expect(GlyphDisplayRenderer(table: nil).waitingText(model, atUptime: 10)
                == "Slot row covered · move the window")
    }
}
