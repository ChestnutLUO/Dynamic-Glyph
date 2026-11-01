import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
// For `InputCheckResult`, whose initializer is internal: the input-check
// badges' masks must take the fill too.
@testable import GlyphRecognition
import GlyphRecognitionImages

@Suite("Reading mode colours")
struct ReadingModeTintTests {
    private let policy = AnalysisRateController.Policy()

    @Test("The Diagnostics switch starts off and is remembered")
    func preferenceDefaultsOff() throws {
        let suite = "dynamicglyph-reading-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(!preferences.colorsFloatingWindowByMode)
        preferences.colorsFloatingWindowByMode = true
        #expect(AppPreferences(defaults: defaults).colorsFloatingWindowByMode)
        #expect(defaults.bool(forKey: AppPreferences.colorsFloatingWindowByModeKey))
    }

    @Test("Quiet is Idle, resting Waiting, active Reading; power saving off keeps the window's own fill")
    func modes() {
        func tint(_ mode: AnalysisRateController.Mode, _ interval: Double, saving: Bool = true,
                  inHack: Bool = false) -> ReadingModeTint {
            ReadingMode(mode: mode, interval: interval, powerSaving: saving, inHack: inHack).tint
        }
        #expect(tint(.quiet, policy.quietInterval) == .idle)
        #expect(tint(.resting, policy.quietInterval) == .waiting)
        #expect(tint(.active, policy.activeInterval) == .reading)
        #expect(tint(.active, policy.activeInterval, inHack: true) == .reading)
        #expect(tint(.quiet, policy.constrainedQuietInterval) == .backingOff)
        #expect(tint(.resting, policy.constrainedQuietInterval) == .backingOff)
        #expect(tint(.active, policy.constrainedActiveInterval) == .backingOff)
        #expect(tint(.active, policy.activeInterval, saving: false) == .none)
        #expect(ReadingModeTint.none.fill == nil)
        #expect(ReadingModeTint.legend.allSatisfy { $0.fill != nil })
    }

    @Test("Backing off is read from the rate the gate set: Low Power Mode in a hack keeps Reading at 20/s")
    func backingOffOnlyWhenHalved() {
        var gate = AnalysisRateController()
        let hack = gate.decide(at: 0, gate: nil, busy: false, inHack: true, constrained: true)
        let inHack = ReadingMode(hack, powerSaving: true, inHack: true, policy: gate.policy)
        #expect(!inHack.isBackingOff && inHack.tint == .reading && inHack.ratePerSecond == 20)
        #expect(inHack.label == "Reading (hack)")
        let between = gate.decide(at: 1, gate: nil, busy: true, inHack: false, constrained: true)
        let outside = ReadingMode(between, powerSaving: true, inHack: false, policy: gate.policy)
        #expect(outside.isBackingOff && outside.tint == .backingOff && outside.ratePerSecond == 10)
        #expect(outside.label == "Backing off (Reading)")
        let free = gate.decide(at: 2, gate: nil, busy: true, inHack: false, constrained: false)
        #expect(ReadingMode(free, powerSaving: true, inHack: false, policy: gate.policy).tint == .reading)
    }

    @Test("Rates are the gate's caps, 20, 10, 4 and 2 a second, with the legend's words")
    func ratesAndLabels() {
        #expect(ReadingMode(mode: .active, interval: policy.activeInterval, powerSaving: true, inHack: false)
            .ratePerSecond == 20)
        #expect(ReadingMode(mode: .active, interval: policy.constrainedActiveInterval, powerSaving: true,
                            inHack: false).ratePerSecond == 10)
        #expect(ReadingMode(mode: .quiet, interval: policy.quietInterval, powerSaving: true, inHack: false)
            .ratePerSecond == 4)
        let resting = ReadingMode(mode: .resting, interval: policy.constrainedQuietInterval, powerSaving: true,
                                  inHack: false)
        #expect(resting.ratePerSecond == 2 && resting.label == "Backing off (Waiting)")
        #expect(ReadingMode(mode: .quiet, interval: policy.quietInterval, powerSaving: true, inHack: false)
            .label == "Idle")
        #expect(ReadingMode(mode: .active, interval: policy.activeInterval, powerSaving: false, inHack: false)
            .label == "Off (saving off)")
    }

    @Test("The signal counts changes, not publishes, and shows the fill only while the switch is on")
    func signal() {
        let signal = ReadingModeSignal()
        #expect(signal.tint == .none && signal.displayed == .none)
        for _ in 0..<50 { signal.publish(.idle) }
        signal.publish(.reading)
        signal.publish(.reading)
        #expect(signal.changes == 2)
        #expect(signal.displayed == .none, "off by default")
        signal.isShown = true
        #expect(signal.displayed == .reading)
        signal.isShown = false
        #expect(signal.displayed == .none && signal.tint == .reading)
    }

    @Test("The Power readout gives the mode and its rate as text, with the frames analysed in the last second")
    func powerReadout() {
        let clock = Clock()
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        clock.now = 100_200_000_000
        meter.reset()
        #expect(PowerReport.readingModeLine(meter.snapshot()) == nil, "nothing before the first look")
        meter.noteAnalysisMode(.resting, at: 0, current: ReadingMode(
            mode: .resting, interval: policy.constrainedQuietInterval, powerSaving: true, inHack: false))
        clock.now = 100_500_000_000
        meter.count(.framesAnalysed)
        meter.count(.framesAnalysed)
        clock.now = 101_300_000_000
        let snapshot = meter.snapshot()
        #expect(snapshot.analysedLastSecond == 2)
        #expect(PowerReport.readingModeLine(snapshot) == "now Backing off (Waiting) 2/s · last s 2")
        #expect(PowerReport.lines(snapshot).contains("now Backing off (Waiting) 2/s · last s 2"))
        #expect(PowerReport.lines(snapshot).allSatisfy { $0.count <= 42 })
    }
}

private final class Clock: @unchecked Sendable {
    var now: UInt64 = 0
}

// MARK: - Rendering

/// The floating window drawn through the frame factory with each fill, as
/// PNGs for review and as pixels for the checks: debug off is the renderer's
/// own output, the status edge never changes, no patch of the old background
/// is left, and strokes and messages keep their contrast on every fill.
///
/// The PNGs go to `DG_SHOTS_DIR` when set (`TEST_RUNNER_DG_SHOTS_DIR` for
/// `xcodebuild test`), otherwise to the temporary directory.
@Suite("Reading mode colours in the floating window")
struct ReadingModeRenderTests {
    static let canvas = PiPCanvasConfiguration.standard
    static let now = 100.0
    /// The narrowest window seen on a device, 189 pt, and about a phone's
    /// width, both at 3x.
    static let sizes: [(name: String, width: Int)] = [("native", canvas.pixelWidth), ("small-189pt", 567),
                                                      ("large-390pt", 1170)]
    static let tints: [ReadingModeTint] = [.none] + ReadingModeTint.legend
    static let session = CaptureSessionID(rawValue: 7)

    enum Scene: String, CaseIterable {
        case waiting, gear, glyphs, checks
    }

    // MARK: Snapshots

    static func snapshot(_ scene: Scene) -> GlyphDisplaySnapshot {
        let demo = (1...5).map { GlyphID("demo\($0)") }
        func make(state: TrackingState, slots: [SlotObservation], expected: Int?, current: Int? = nil,
                  input: Int? = nil, provisional: GlyphID? = nil, outlook: SequenceOutlook = .unavailable,
                  checks: [InputCheckResult] = [], gear: GearDropDisplay? = nil) -> GlyphDisplaySnapshot {
            GlyphDisplaySnapshot(captureSessionID: session, hackID: 1, revision: 3, liveness: .live, state: state,
                                 phaseSource: .headerText, acceptance: .trackingSequence, sourceFrameTime: 10,
                                 evidenceArrivalUptime: now, expectedSlotCount: expected, slots: slots,
                                 currentSlotIndex: current, inputSlotIndex: input, slotCountConflict: false,
                                 isFrozen: false, provisionalGlyph: provisional, provisionalExtensionCount: 0,
                                 outlook: outlook, calibrationSummary: "", inputChecks: checks,
                                 inputCheckRevision: checks.isEmpty ? 0 : 1, gear: gear)
        }
        switch scene {
        case .waiting:
            return make(state: .inactive, slots: [], expected: nil)
        case .gear:
            return make(state: .completed, slots: [], expected: nil,
                        gear: GearDropDisplay(state: .read, hackID: 1, itemCount: 12))
        case .glyphs:
            // Confirmed, a shape the list lacks (drawn as unknown), the one
            // being presented, and two predicted.
            let observed = [demo[0], GlyphID("notInList"), demo[2]]
            let outlook = SequenceOutlook(state: .resolved, observed: observed, expectedLength: 5,
                                          candidateCount: 1, candidates: [], predictedSuffix: [demo[3], demo[4]],
                                          suffixAlternatives: [], observationMayBeComplete: false)
            return make(state: .presenting,
                        slots: [SlotObservation(index: 0, status: .confirmed, glyph: demo[0]),
                                SlotObservation(index: 1, status: .confirmed, glyph: observed[1]),
                                SlotObservation(index: 2, status: .observing)],
                        expected: 5, current: 2, provisional: demo[2], outlook: outlook)
        case .checks:
            func check(_ slot: Int, _ verdict: InputCheckVerdict) -> InputCheckResult {
                InputCheckResult(sessionID: session, hackID: 1, slotIndex: slot, attemptID: slot + 1,
                                 expectedGlyph: demo[slot], verdict: verdict, reason: nil, sourceTime: 10,
                                 startTime: 9, liftTime: 9.5, samples: [])
            }
            return make(state: .input,
                        slots: (0..<4).map { SlotObservation(index: $0, status: .confirmed, glyph: demo[$0]) },
                        expected: 4, input: 3,
                        checks: [check(0, .matched), check(1, .differs), check(2, .unavailable)])
        }
    }

    // MARK: Pixels

    struct RGB: Equatable, CustomStringConvertible {
        var r: UInt8, g: UInt8, b: UInt8
        var description: String { "(\(r), \(g), \(b))" }
    }

    /// RGBA, straight from an opaque image.
    struct Pixels {
        let width: Int, height: Int
        var bytes: [UInt8]

        init(_ image: CGImage, width: Int, height: Int) throws {
            self.width = width
            self.height = height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        /// Mid-gray, for a contact sheet's gaps.
        init(width: Int, height: Int, gray: UInt8) {
            self.width = width
            self.height = height
            bytes = [UInt8](repeating: gray, count: width * height * 4)
            for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        }

        mutating func paste(_ other: Pixels, atRow row: Int) {
            let rowBytes = width * 4
            for y in 0..<other.height {
                let source = y * rowBytes, target = (row + y) * rowBytes
                bytes.replaceSubrange(target..<(target + rowBytes), with: other.bytes[source..<(source + rowBytes)])
            }
        }

        /// Row 0 at the top.
        func rgb(_ x: Int, _ y: Int) -> RGB {
            let offset = (y * width + x) * 4
            return RGB(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2])
        }
    }

    /// The frame factory's own buffer, as the layer would get it, read out
    /// at `width` x `height` while the buffer is still held.
    static func render(_ scene: Scene, tint: ReadingModeTint, factory: GlyphFrameFactory,
                       width: Int? = nil, height: Int? = nil) throws -> Pixels {
        let buffer = try #require(factory.makePixelBuffer(snapshot(scene), atUptime: now,
                                                          windowWidth: nil, tint: tint))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let context = try #require(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let image = try #require(context.makeImage())
        return try Pixels(image, width: width ?? image.width, height: height ?? image.height)
    }

    /// The interior as drawn: a plain stretch at the far right of the
    /// waiting message's row. The palette is generic RGB, so the old
    /// background is drawn lighter than its components say.
    static func renderedFill(_ tint: ReadingModeTint, factory: GlyphFrameFactory) throws -> RGB {
        let pixels = try render(.waiting, tint: tint, factory: factory)
        return pixels.rgb(pixels.width - 20, pixels.height / 2)
    }

    static func near(_ a: RGB, _ b: RGB) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= 1 && abs(Int(a.g) - Int(b.g)) <= 1 && abs(Int(a.b) - Int(b.b)) <= 1
    }

    static func bytes(_ color: CGColor) -> RGB {
        let c = color.components ?? [0, 0, 0]
        func byte(_ v: CGFloat) -> UInt8 { UInt8((v * 255).rounded()) }
        return RGB(r: byte(c[0]), g: byte(c[1]), b: byte(c[2]))
    }

    // MARK: Contrast (WCAG 2)

    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func luminance(_ color: CGColor) -> Double {
        let c = (color.components ?? [0, 0, 0]).map(Double.init)
        return luminance(c[0], c[1], c[2])
    }

    static func luminance(_ rgb: RGB) -> Double {
        luminance(Double(rgb.r) / 255, Double(rgb.g) / 255, Double(rgb.b) / 255)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    static var outputDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["DG_SHOTS_DIR"] ?? environment["TEST_RUNNER_DG_SHOTS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("pip-reading-mode", isDirectory: true)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                       1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func makeImage(_ pixels: Pixels) throws -> CGImage {
        var bytes = pixels.bytes
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try #require(context.makeImage())
        }
    }

    // MARK: Tests

    @Test("Every stroke keeps 3:1 and every message 4.5:1 on all four fills")
    func paletteContrast() {
        let palette = GlyphDisplayRenderer(table: nil).palette
        let strokes: [(String, CGColor)] = [("confirmed", palette.confirmed), ("observing", palette.observing),
                                            ("predicted", palette.predicted), ("warning", palette.warning),
                                            ("unknown", palette.unknown), ("check mark", palette.primaryText)]
        let text: [(String, CGColor)] = [("gear message", palette.primaryText),
                                         ("waiting message", palette.secondaryText)]
        for tint in ReadingModeTint.legend {
            let fill = Self.luminance(tint.fill!)
            for (name, colour) in strokes {
                #expect(Self.contrast(Self.luminance(colour), fill) >= 3, "\(name) on \(tint)")
            }
            for (name, colour) in text {
                #expect(Self.contrast(Self.luminance(colour), fill) >= 4.5, "\(name) on \(tint)")
            }
        }
    }

    @Test("Debug off draws exactly as before; a fill changes the interior and its masks, never the edge",
          arguments: Scene.allCases)
    func pixels(_ scene: Scene) throws {
        let table = SetupDemo.builtInTable
        let factory = GlyphFrameFactory(table: table, canvas: Self.canvas)
        let width = Self.canvas.pixelWidth, height = Self.canvas.pixelHeight
        let original = try Pixels(try #require(GlyphDisplayRenderer(table: table)
            .image(Self.snapshot(scene), canvas: Self.canvas, atUptime: Self.now, windowWidth: nil)),
            width: width, height: height)
        let off = try Self.render(scene, tint: .none, factory: factory)
        #expect(off.bytes == original.bytes, "debug off must match the renderer's own output")

        let background = try Self.renderedFill(.none, factory: factory)
        // The status edge: 0.08 of the canvas height, in pixels; a margin
        // short of its antialiased inner side.
        let edge = Int(Double(Self.canvas.height) * 0.08 * Double(Self.canvas.resolution)) - 2
        for tint in ReadingModeTint.legend {
            let tinted = try Self.render(scene, tint: tint, factory: factory)
            var edgeDiffers = 0, leftover = 0
            for y in 0..<height {
                for x in 0..<width {
                    let inEdge = y < edge || y >= height - edge || x < edge || x >= width - edge
                    if inEdge, tinted.rgb(x, y) != off.rgb(x, y) { edgeDiffers += 1 }
                    if !inEdge, tinted.rgb(x, y) == background { leftover += 1 }
                }
            }
            #expect(edgeDiffers == 0, "\(scene) \(tint): the status edge changed in \(edgeDiffers) pixels")
            #expect(leftover == 0, "\(scene) \(tint): \(leftover) pixels of the old background remain")
            // A plain stretch of interior, inside the edge at the far right
            // of the middle row, shows the fill.
            // The reference hex values themselves, within rounding.
            let fill = Self.bytes(tint.fill!)
            let sample = tinted.rgb(width - 20, height / 2)
            #expect(scene == .glyphs || scene == .checks || Self.near(sample, fill),
                    "\(scene) \(tint): \(sample) is not the fill \(fill)")
        }
    }

    @Test("PNGs of every scene on every fill, at the canvas size and at a small and a large window")
    func images() throws {
        let directory = Self.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factory = GlyphFrameFactory(table: SetupDemo.builtInTable, canvas: Self.canvas)
        let aspect = Double(Self.canvas.pixelHeight) / Double(Self.canvas.pixelWidth)
        var report = ["scene  tint  size  peak contrast of the brightest interior pixel per tile vs the fill"]
        for (sizeName, width) in Self.sizes {
            let height = Int((Double(width) * aspect).rounded())
            var sheet: [Pixels] = []
            for scene in Scene.allCases {
                for tint in Self.tints {
                    let pixels = try Self.render(scene, tint: tint, factory: factory, width: width, height: height)
                    sheet.append(pixels)
                    let name = "pip-\(scene.rawValue)-\(tint)-\(sizeName).png"
                    try Self.writePNG(Self.makeImage(pixels), to: directory.appendingPathComponent(name))
                    let fill = Self.luminance(try Self.renderedFill(tint, factory: factory))
                    // Peak contrast per tile (or the message row), inside the edge.
                    let edge = Int(Double(height) * 0.08) + 2
                    let columns = scene == .glyphs ? 5 : scene == .checks ? 4 : 1
                    var peaks: [String] = []
                    let inner = width - 2 * edge
                    for column in 0..<columns {
                        var peak = 1.0
                        let from = edge + inner * column / columns, to = edge + inner * (column + 1) / columns
                        for y in edge..<(height - edge) {
                            for x in from..<to {
                                peak = max(peak, Self.contrast(Self.luminance(pixels.rgb(x, y)), fill))
                            }
                        }
                        peaks.append(String(format: "%.2f", peak))
                        if sizeName == "native" {
                            #expect(peak >= (scene == .waiting || scene == .gear ? 4.5 : 3),
                                    "\(scene) \(tint) column \(column): \(peak)")
                        }
                    }
                    report.append("\(scene.rawValue)  \(tint)  \(sizeName) \(width)x\(height)  "
                                  + peaks.joined(separator: " "))
                }
            }
            // One sheet per size: scenes top to bottom, each on no fill, then
            // Idle, Waiting, Reading and Backing off.
            let gap = 6
            var sheetPixels = Pixels(width: width, height: sheet.count * (height + gap) - gap, gray: 128)
            for (index, pixels) in sheet.enumerated() {
                sheetPixels.paste(pixels, atRow: index * (height + gap))
            }
            try Self.writePNG(Self.makeImage(sheetPixels),
                              to: directory.appendingPathComponent("pip-sheet-\(sizeName).png"))
        }
        let palette = GlyphDisplayRenderer(table: nil).palette
        report.append("")
        report.append("palette contrast on each fill from nominal components (WCAG 2): strokes need 3, messages 4.5")
        let named: [(String, CGColor)] = [("confirmed", palette.confirmed), ("observing", palette.observing),
                                          ("predicted", palette.predicted), ("warning", palette.warning),
                                          ("unknown", palette.unknown), ("primaryText", palette.primaryText),
                                          ("secondaryText", palette.secondaryText), ("frame", palette.frame)]
        for tint in Self.tints {
            let fill = Self.luminance(tint.fill ?? palette.background)
            report.append("\(tint): " + named.map {
                String(format: "%@ %.2f", $0.0, Self.contrast(Self.luminance($0.1), fill))
            }.joined(separator: ", "))
        }
        try report.joined(separator: "\n").write(to: directory.appendingPathComponent("contrast.txt"),
                                                 atomically: true, encoding: .utf8)
    }
}
