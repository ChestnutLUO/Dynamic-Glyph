import CoreGraphics
import CoreVideo
import Foundation
import GlyphRecognition
import GlyphRecognitionImages
import Testing

/// The `headerWindowMask` cut: with `headerStillSkip`, a header that is not
/// still is compared again without the cells under the app's own window.
/// The window is drawn by the app's renderer over synthetic header text, and
/// injected OCR stands in for Vision: the frames make no claim about how any
/// language's header reads, only about which looks read.
@Suite("Header window mask")
struct HeaderWindowMaskTests {
    private let session = CaptureSessionID(rawValue: 1)
    static let width = 602
    static let height = 1310
    /// Over the header's rows 78..<136, leaving 15 of them above it, as in
    /// the measured 602-wide recordings.
    static let window = CGRect(x: 17, y: 93, width: 566, height: 57)

    /// A frame whose header shows `text`'s stripes, under the app's window
    /// at `window` showing the setup demo `elapsed` seconds in, or none.
    static func frame(text: Int = 0, window: CGRect? = window,
                      elapsed: Double = 3.5) throws -> (image: CGImage, band: FrameTopBand) {
        let width = Self.width, height = Self.height
        let header = HeaderTextRecognizer().headerRect(width: width, height: height)
        let rows = Int(header.minY)..<Int(header.maxY)
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = rows.contains(y)
                    ? ((x / 6 + text) % 4 == 0 && (y / 5) % 3 != 2 ? 210 : 20)
                    : UInt8(18 + (x * 13 + y * 7) % 31)
                let offset = (y * width + x) * 4
                rgba[offset] = value; rgba[offset + 1] = value; rgba[offset + 2] = value &+ 6
            }
        }
        let image: CGImage? = try rgba.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.interpolationQuality = .high
            if let window {
                let demo = SetupDemo(table: nil)
                let picture = try #require(GlyphDisplayRenderer(table: demo.table).image(
                    demo.snapshot(at: elapsed, uptime: 100), canvas: .standard, atUptime: 100,
                    windowWidth: Double(window.width) / 2))
                // The context's y runs bottom up from the bitmap's last row.
                context.draw(picture, in: CGRect(x: window.minX, y: CGFloat(height) - window.maxY,
                                                 width: window.width, height: window.height))
            }
            return context.makeImage()
        }
        let frame = try #require(image)
        return (frame, try ImageDecoder.topBand(frame))
    }

    private static let read = HeaderReading(phase: .presenting, matchedText: "INJECTED presenting",
                                            confidence: 0.9)

    private func reader(still: Bool = true, mask: Bool = true, meter: PowerMeter? = nil,
                        reads: ReadTimes) -> GameHeaderReader {
        GameHeaderReader(configuration: .init(skipsStillHeaders: still, masksHeaderWindow: mask),
                         headerOperation: { _, time in
                             reads.append(time)
                             return Self.read.at(sourceTime: time)
                         }, meter: meter)
    }

    private func finish(_ reader: GameHeaderReader) async throws {
        for _ in 0..<200 {
            if !reader.isReading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("OCR lane did not finish")
    }

    /// Plays `frames` in a hack at 8 Hz, each look given its own top band
    /// unless `bands` is false, and returns the times read.
    private func play(_ frames: [(image: CGImage, band: FrameTopBand)], reader: GameHeaderReader,
                      reads: ReadTimes, bands: Bool = true) async throws -> [Double] {
        for (index, frame) in frames.enumerated() {
            reader.submit(frame.image, at: Double(index) * 0.125, session: session, inHack: true,
                          topBand: bands ? frame.band : nil)
            try await finish(reader)
        }
        return reads.values
    }

    @Test("The window's changes alone skip, issuing the last read's reading; off, the still skip reads them")
    func windowChangesSkip() async throws {
        let frames = try [3.5, 0.5, 7.5, 10.5, 3.5].map { try Self.frame(elapsed: $0) }
        #expect(!frames[1].band.image.pixels.elementsEqual(frames[0].band.image.pixels))
        let offReads = ReadTimes()
        let off = try await play(frames, reader: reader(mask: false, reads: offReads), reads: offReads)
        #expect(off.count >= 4, "Without the mask each change of the window reads: \(off)")
        let meter = PowerMeter(), onReads = ReadTimes()
        meter.reset()
        let masked = reader(meter: meter, reads: onReads)
        let on = try await play(frames, reader: masked, reads: onReads)
        #expect(on == [0], "Only the first look reads: \(on)")
        #expect(masked.issuedReading(for: 0.5, session: session)
                == .init(reading: Self.read.at(sourceTime: 0.5), reused: true))
        let metrics = masked.snapshotMetrics()
        #expect(metrics.headerSkippedMaskedInHack + metrics.headerSkippedStillInHack == 4)
        #expect(metrics.headerSkippedMaskedInHack >= 3 && metrics.headerSkippedMaskedOutside == 0)
        let snapshot = meter.snapshot()
        #expect(snapshot.total(.headerMaskedInHack).count == UInt64(metrics.headerSkippedMaskedInHack))
        #expect(snapshot.total(.headerStillInHack).count == UInt64(metrics.headerSkippedStillInHack))
    }

    @Test("A change of the header outside the window reads, the window still or changing")
    func headerChangeReads() async throws {
        let base = try Self.frame(), changed = try Self.frame(text: 1)
        let changedUnderNewWindow = try Self.frame(text: 2, elapsed: 7.5)
        let reads = ReadTimes()
        let result = try await play([base, changed, changedUnderNewWindow], reader: reader(reads: reads), reads: reads)
        #expect(result == [0, 0.125, 0.25])
    }

    @Test("A window moved, gone or leaving too little of the header compares the whole header and reads")
    func windowElsewhereReads() async throws {
        let base = try Self.frame()
        let moved = try Self.frame(window: Self.window.offsetBy(dx: 0, dy: 4), elapsed: 7.5)
        let gone = try Self.frame(window: nil)
        // Covering all but the header's first five rows, under the share left.
        let low = CGRect(x: 17, y: 83, width: 566, height: 57)
        let lowBase = try Self.frame(window: low), lowChanged = try Self.frame(window: low, elapsed: 7.5)
        for (name, frames) in [("moved", [base, moved]), ("gone", [base, gone]), ("low", [lowBase, lowChanged])] {
            let reads = ReadTimes()
            let result = try await play(frames, reader: reader(reads: reads), reads: reads)
            #expect(result == [0, 0.125], "\(name): \(result)")
        }
        #expect(FloatingWindowFinder.find(in: lowBase.band) != nil, "The low window is found, yet reads")
    }

    @Test("Without the still skip the mask does nothing; without a top band it compares nothing")
    func needsStillSkipAndBand() async throws {
        let frames = try [3.5, 0.5, 7.5].map { try Self.frame(elapsed: $0) }
        let alone = ReadTimes(), plain = ReadTimes()
        let maskAlone = try await play(frames, reader: reader(still: false, mask: true, reads: alone), reads: alone)
        let neither = try await play(frames, reader: reader(still: false, mask: false, reads: plain), reads: plain)
        #expect(maskAlone == neither && maskAlone.count == 3)
        let noBand = ReadTimes()
        let unbanded = try await play(frames, reader: reader(reads: noBand), reads: noBand, bands: false)
        #expect(unbanded.count == 3, "No band, no grid: every look reads, as with the still skip alone")
    }

    @Test("Masked skips keep the still skip's limits: the age limit reads, and a still header skips unmasked")
    func stillSkipLimits() async throws {
        let still = try Self.frame(), changing = try Self.frame(elapsed: 7.5)
        let reads = ReadTimes(), masked = reader(reads: reads)
        var frames = [still]
        for index in 1...9 { frames.append(index % 2 == 0 ? still : changing) }
        let result = try await play(frames, reader: masked, reads: reads)
        #expect(result == [0, 1.0], "The anchor's read is a second old at 1.0: \(result)")
        let metrics = masked.snapshotMetrics()
        #expect(metrics.headerSkippedStillInHack == 3 && metrics.headerSkippedMaskedInHack == 5,
                "Looks like the anchor skip unmasked, the others masked: \(metrics)")
    }

    @Test("The Power report shows masked skips under the still skips only when the cut ran")
    func powerReport() throws {
        let meter = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: false), engine: "cpp",
                    cuts: [.headerStillSkip])
        #expect(!PowerReport.lines(meter.snapshot()).contains { $0.hasPrefix("masked") })
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: false), engine: "cpp",
                    cuts: [.headerStillSkip, .headerWindowMask])
        meter.count(.headerMaskedInHack, 4)
        let lines = PowerReport.lines(meter.snapshot())
        let still = try #require(lines.firstIndex { $0.hasPrefix(PowerMetric.headerStillOutside.label) })
        let masked = try #require(lines.firstIndex { $0.hasPrefix(PowerMetric.headerMaskedInHack.label) })
        #expect(masked == still + 2, "After the still rows and their note: \(lines)")
        #expect(lines.contains { $0.hasPrefix("masked hack") && $0.contains(" 4") })
        #expect(lines.allSatisfy { $0.count <= 42 }, "\(lines.filter { $0.count > 42 })")
        #expect(PowerMetric.headerMasked.allSatisfy { $0.label.count <= 11 && !PowerMetric.topLevel.contains($0) })
        #expect(Array(PowerMetric.allCases.suffix(4).prefix(2)) == PowerMetric.headerMasked,
                "Added after the cases before it, so their raw values keep their order")
    }
}

/// The `headerWindowMask` cut through the whole live output, beside the still
/// skip alone: a window over the header's lower rows whose content changes
/// every quarter second, over a command channel whose header then changes.
/// The injected OCR reads the header's rows above the window, as Vision
/// would read the text the window leaves; geometry, the tracker, the command
/// watch and the pace are the real pipeline's.
@Suite("Header window mask in the live output", .serialized)
struct HeaderWindowMaskWatchTests {
    /// Header shades the injected OCR reads, by the visible rows' mean grey.
    enum Shade: UInt8, CaseIterable {
        case unreadable = 24
        case command = 110
        case contrary = 200

        func reading(at time: Double) -> HeaderReading {
            switch self {
            case .unreadable: return HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time)
            case .command: return HeaderReading(phase: .command, matchedText: "INJECTED command", confidence: 1,
                                                sourceTime: time)
            case .contrary: return HeaderReading(phase: .unknown, matchedText: "conflicting phrases", confidence: 0,
                                                 sourceTime: time)
            }
        }
    }

    /// The share of the header's height above the window, and the share the
    /// injected OCR reads: inside it, clear of the window's padding.
    static let windowTopShare = 0.45
    static let readShare = 0.3

    struct Run {
        var watch: [(time: Double, watching: Bool)] = []
        var rows: [[String: Any]] = []
        var events: [(kind: TrackingEvent.Kind, time: Double)] = []
        var metrics: GameHeaderReader.Metrics

        var looks: Int {
            metrics.headerInHackSubmitted + metrics.headerOutsideSubmitted + metrics.headerSkippedUnchanged
                + metrics.headerSkippedStillInHack + metrics.headerSkippedStillOutside
                + metrics.headerSkippedMaskedInHack + metrics.headerSkippedMaskedOutside
        }

        func released(after time: Double) -> Double? {
            watch.first { $0.time > time && !$0.watching }?.time
        }

        func watched(_ range: ClosedRange<Double>) -> Bool {
            let frames = watch.filter { range.contains($0.time) }
            return !frames.isEmpty && frames.allSatisfy(\.watching)
        }
    }

    static func play(cuts: Set<RecognitionCut>, until end: Double,
                     shade: @escaping @Sendable (Double) -> Shade) throws -> Run {
        let directory = try TemporaryDirectory("mask-watch")
        let clock = MaskSourceClock()
        let meter = PowerMeter(clock: { clock.nanoseconds }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let gate = MaskCurrentGate()
        let events = WatchReproductionValues<LiveGlyphTrace>()
        let output = try LiveGlyphOutput(
            table: SetupDemo.builtInTable, sequenceTable: nil, sessionID: CaptureSessionID(rawValue: 7),
            directory: directory.url, readsResults: true,
            power: PowerConditions(center: NotificationCenter(), read: { .init() }), cuts: cuts, meter: meter,
            headerOperation: { image, time in
                let shade = try Self.shade(of: image)
                await gate.current.wait()
                return shade.reading(at: time)
            }, trace: { events.append($0) },
            telemetry: { _ in }, deliverResult: { _ in }, deliver: { _ in })
        // Each shade with the window in each of its two states.
        var frames: [String: (channel: CVPixelBuffer, drawn: CVPixelBuffer)] = [:]
        for shade in Shade.allCases {
            for state in 0..<2 {
                frames["\(shade)-\(state)"] = (try paint(Frames.recorded("field-00381"), shade, window: state),
                                               try paint(CommandDrawingFrame.make(), shade, window: state))
            }
        }
        var run = Run(metrics: output.textReadMetrics)
        for index in 0...Int((end * 60).rounded()) {
            let time = Double(index) / 60
            let pair = try #require(frames["\(shade(time))-\(Int(time * 4) % 2)"])
            clock.set(time)
            let opened = AsyncHeaderGate()
            gate.current = opened
            output.process(CapturedFrame(sampleBuffer: try Frames.sample(index == 0 ? pair.channel : pair.drawn, at: time),
                                         metadata: CaptureFrameMetadata(status: .complete),
                                         arrivalUptime: 1000 + time, deliveryGapMilliseconds: nil,
                                         continuityBroken: false))
            opened.signal()
            let deadline = Date().addingTimeInterval(20)
            while output.isReadingText {
                guard Date() < deadline else { throw Frames.Failure(description: "The injected read did not finish") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            run.watch.append((time, meter.snapshot().gateOccupancy.current.has(.commandWatch)))
        }
        run.metrics = output.textReadMetrics
        output.close()
        let text = try String(contentsOf: directory.url.appendingPathComponent("recognition.jsonl"), encoding: .utf8)
        run.rows = try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        run.events = events.values.flatMap { $0.events.map { ($0.kind, $0.time) } }
        return run
    }

    /// The shade of the header's rows above the window: twice their mean
    /// grey, as they are striped half dark.
    private static func shade(of image: GameHeaderReader.HeaderImage) throws -> Shade {
        let crop: CGImage
        switch image {
        case .frame(let frame): crop = try #require(HeaderTextRecognizer().headerCrop(of: frame))
        case .region(let region): crop = region
        }
        let grey = try ImageDecoder.decode(crop)
        let rows = max(1, Int(Double(grey.height) * readShare))
        let visible = grey.pixels.prefix(rows * grey.width)
        let mean = 2 * Double(visible.reduce(0) { $0 + Int($1) }) / Double(max(1, visible.count))
        return try #require(Shade.allCases.min { abs(Double($0.rawValue) - mean) < abs(Double($1.rawValue) - mean) })
    }

    /// The header rows, with a two-row guard, striped in `shade` and black,
    /// so that no row of them is one smooth run; then the window, a grey
    /// ring around a dark interior, over the header's lower rows, its
    /// interior's block and its ring's grey set by `window`.
    private static func paint(_ buffer: CVPixelBuffer, _ shade: Shade, window state: Int) throws -> CVPixelBuffer {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let height = CVPixelBufferGetHeight(buffer), width = CVPixelBufferGetWidth(buffer)
        let layout = GameUILayout()
        let headerTop = layout.headerTextTop * Double(height), headerBottom = layout.headerTextBottom * Double(height)
        let top = max(0, Int(floor(headerTop)) - 2)
        let bottom = min(height, Int(ceil(headerBottom)) + 2)
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in top..<bottom {
            for x in 0..<width { luma[y * stride + x] = x % 8 < 4 ? shade.rawValue : 0 }
        }
        let left = Int(0.028 * Double(width)), right = width - left
        let windowHeight = (right - left) / 10
        let windowTop = Int(headerTop + windowTopShare * (headerBottom - headerTop))
        let ring = max(3, windowHeight * 8 / 100)
        let ringGrey: UInt8 = state == 0 ? 180 : 150
        for y in windowTop..<min(height, windowTop + windowHeight) {
            for x in left..<right {
                let onRing = y < windowTop + ring || y >= windowTop + windowHeight - ring
                    || x < left + ring || x >= right - ring
                let inBlock = x >= left + (state == 0 ? 40 : 200) && x < left + (state == 0 ? 120 : 280)
                    && y >= windowTop + 2 * ring && y < windowTop + windowHeight - 2 * ring
                luma[y * stride + x] = onRing ? ringGrey : (inBlock ? 235 : 16)
            }
        }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaBottom = max(bottom, windowTop + windowHeight)
        for y in max(0, top / 2 - 1)..<min(CVPixelBufferGetHeightOfPlane(buffer, 1), (chromaBottom + 1) / 2 + 1) {
            memset(chroma + y * chromaStride, 128, chromaStride)
        }
        return buffer
    }

    @Test("A header that stops reading as the command channel ends the watch as without the mask, while the window's changes skip",
          arguments: [Shade.unreadable, .contrary])
    func changedHeaderReleasesWatch(_ after: Shade) throws {
        let change = 3.0
        let shade: @Sendable (Double) -> Shade = { $0 <= change ? .command : after }
        let off = try Self.play(cuts: [.headerStillSkip], until: 5, shade: shade)
        let on = try Self.play(cuts: [.headerStillSkip, .headerWindowMask], until: 5, shade: shade)
        let offRelease = try #require(off.released(after: 0.1))
        let onRelease = try #require(on.released(after: 0.1))
        print("MASK WATCH \(after): released off \(offRelease) on \(onRelease); header reads off "
              + "\(off.metrics.headerInHackSubmitted) on \(on.metrics.headerInHackSubmitted), "
              + "masked skips \(on.metrics.headerSkippedMaskedInHack)")
        #expect(off.watched(0.1...change) && on.watched(0.1...change), "Watched while the header reads command")
        #expect(on.metrics.headerSkippedMaskedInHack > 0, "The window's changes were skipped")
        #expect(on.metrics.headerInHackSubmitted < off.metrics.headerInHackSubmitted)
        #expect(on.looks == off.looks, "Every look is a read or a skip in both: on \(on.looks), off \(off.looks)")
        #expect(abs(onRelease - offRelease) <= 0.05 + 1e-9, "off \(offRelease), on \(onRelease)")
        let after = on.rows.filter { ($0["headerSourceTime"] as? Double ?? 0) > change }
        #expect(!after.isEmpty && after.allSatisfy { $0["headerPhase"] as? String != "command" },
                "No command reading reused past the change")
        let first = try #require(after.first)
        #expect(first["headerReused"] == nil, "The changed header was read: \(first)")
        #expect(on.events.map(\.kind) == off.events.map(\.kind), "\(on.events) against \(off.events)")
        for (a, b) in zip(on.events, off.events) {
            #expect(abs(a.time - b.time) <= 0.05 + 1e-9, "\(a) against \(b)")
        }
    }

    @Test("Off, the window's changes are read as the still skip alone reads them; nothing is counted masked")
    func offCountsNothing() throws {
        let run = try Self.play(cuts: [.headerStillSkip], until: 2, shade: { _ in .command })
        #expect(run.metrics.headerSkippedMaskedInHack == 0 && run.metrics.headerSkippedMaskedOutside == 0)
    }
}

/// The meter's clock, set to each frame's source time.
private final class MaskSourceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    var nanoseconds: UInt64 { lock.withLock { now } }
    func set(_ seconds: Double) { lock.withLock { now = UInt64((seconds * 1e9).rounded()) } }
}

/// The gate a read in flight waits on: the frame that asked for it opens it
/// once `process` has returned.
private final class MaskCurrentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = AsyncHeaderGate()
    var current: AsyncHeaderGate {
        get { lock.withLock { gate } }
        set { lock.withLock { gate = newValue } }
    }
}
