import CoreGraphics
import CoreVideo
import Foundation
import GlyphRecognition
import GlyphRecognitionImages
import Testing

/// The `headerCoverSkip` cut: while the app's own window covers at least half
/// of the header's rows, the header is not read and no reading is issued.
/// The window is drawn by the app's renderer over synthetic header text
/// (`HeaderWindowMaskTests.frame`), and injected OCR stands in for Vision:
/// the frames make no claim about how any language's header reads, only
/// about which looks read.
@Suite("Header cover skip")
struct HeaderCoverSkipTests {
    private let session = CaptureSessionID(rawValue: 1)
    /// The header's rows in the 602x1310 frames: 78..<136, 58 rows.
    private static let headerRows = 78..<136

    private static let read = HeaderReading(phase: .presenting, matchedText: "INJECTED presenting",
                                            confidence: 0.9)

    /// A window of the mask tests' size whose top is at `top`.
    private static func window(top: Int) -> CGRect {
        CGRect(x: 17, y: top, width: 566, height: 57)
    }

    private func reader(cover: Bool = true, still: Bool = true, mask: Bool = false, meter: PowerMeter? = nil,
                        reads: ReadTimes) -> GameHeaderReader {
        GameHeaderReader(configuration: .init(skipsStillHeaders: still, masksHeaderWindow: mask,
                                              skipsCoveredHeaders: cover),
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

    /// Plays `frames` at 8 Hz, in a hack unless `inHack` is false, each look
    /// given its own top band unless `bands` is false, and returns the times
    /// read and what each look did with the lane.
    private func play(_ frames: [(image: CGImage, band: FrameTopBand)], reader: GameHeaderReader, reads: ReadTimes,
                      inHack: Bool = true, bands: Bool = true) async throws
        -> (reads: [Double], submissions: [GameHeaderReader.Submission]) {
        var submissions: [GameHeaderReader.Submission] = []
        for (index, frame) in frames.enumerated() {
            submissions.append(reader.submit(frame.image, at: Double(index) * 0.125, session: session,
                                             headerInterval: inHack ? nil : 0.1, inHack: inHack,
                                             topBand: bands ? frame.band : nil))
            try await finish(reader)
        }
        return (reads.values, submissions)
    }

    /// Five looks whose header text changes every time, so that no still
    /// skip could stand in for a read, under the window at `window`.
    private static func changing(window: CGRect?) throws -> [(image: CGImage, band: FrameTopBand)] {
        try (0..<5).map { try HeaderWindowMaskTests.frame(text: $0, window: window, elapsed: 3.5 + Double($0)) }
    }

    @Test("Under the window no look reads, none issues a reading, the lane stays free, and each is counted")
    func coveredSkips() async throws {
        let frames = try Self.changing(window: HeaderWindowMaskTests.window)
        let found = try #require(FloatingWindowFinder.find(in: frames[0].band))
        #expect(found.top <= Self.headerRows.lowerBound + 29, "The window is over most of the header: \(found)")
        let meter = PowerMeter(), reads = ReadTimes()
        meter.reset()
        let covered = reader(meter: meter, reads: reads)
        let hack = try await play(frames, reader: covered, reads: reads)
        #expect(hack.reads.isEmpty, "\(hack.reads)")
        #expect(hack.submissions.allSatisfy { $0 == .none })
        #expect(!covered.isReading)
        for index in frames.indices {
            #expect(covered.issuedReading(for: Double(index) * 0.125, session: session) == nil)
        }
        let outside = try await play(frames, reader: covered, reads: reads, inHack: false)
        #expect(outside.reads.isEmpty)
        let metrics = covered.snapshotMetrics(), snapshot = meter.snapshot()
        #expect(metrics.headerSkippedCoveredInHack == 5 && metrics.headerSkippedCoveredOutside == 5)
        #expect(metrics.headerInHackSubmitted == 0 && metrics.headerOutsideSubmitted == 0)
        #expect(metrics.headerSkippedStillInHack == 0 && metrics.headerSkippedMaskedInHack == 0)
        #expect(snapshot.total(.headerCoveredInHack).count == 5 && snapshot.total(.headerCoveredOutside).count == 5)
    }

    @Test("A skipped look leaves the lane to a result read of the same frame")
    func laneStaysFree() async throws {
        let frame = try HeaderWindowMaskTests.frame(), reads = ReadTimes()
        let context = ResultReadContext(sessionID: session, hackID: 1, glyphs: ["xm"])
        let reader = GameHeaderReader(
            configuration: .init(skipsStillHeaders: true, skipsCoveredHeaders: true),
            headerOperation: { _, time in reads.append(time); return Self.read.at(sourceTime: time) },
            resultOperation: { _, context, time in .init(context: context, sourceTime: time, panelPresent: true) })
        #expect(reader.submit(frame.image, at: 0, session: session, inHack: true, topBand: frame.band) == .none)
        #expect(reader.submit(frame.image, at: 0, session: session, resultContext: context, panelCandidate: true,
                              inHack: true, topBand: frame.band) == .read(.result))
        try await finish(reader)
        #expect(reader.takeResult()?.evidence.sourceTime == 0 && reads.values.isEmpty)
    }

    @Test("No window, a window over less than half of the header, or no top band reads every look")
    func uncoveredReads() async throws {
        // The ring the finder places lies a few rows inside the drawn
        // picture. Overlaps of 28 of the header's 58 rows, then 29: under
        // half reads, half skips.
        let probe = try #require(FloatingWindowFinder.find(in: HeaderWindowMaskTests.frame(window: Self.window(top: 100)).band))
        let inset = probe.top - 100
        #expect(probe.bottom > Self.headerRows.upperBound + 20)
        let under = try Self.changing(window: Self.window(top: Self.headerRows.upperBound - 28 - inset))
        let half = try Self.changing(window: Self.window(top: Self.headerRows.upperBound - 29 - inset))
        for (frames, top) in [(under, Self.headerRows.upperBound - 28), (half, Self.headerRows.upperBound - 29)] {
            let window = try #require(FloatingWindowFinder.find(in: frames[0].band), "The window is found")
            #expect(window.top == top, "\(window)")
        }
        let cases: [(String, [(image: CGImage, band: FrameTopBand)], Bool, Int)] = [
            ("no window", try Self.changing(window: nil), true, 5),
            ("under half", under, true, 5),
            ("half", half, true, 0),
            ("no band", try Self.changing(window: HeaderWindowMaskTests.window), false, 5)
        ]
        for (name, frames, bands, expected) in cases {
            let reads = ReadTimes()
            let reader = reader(reads: reads)
            let result = try await play(frames, reader: reader, reads: reads, bands: bands)
            #expect(result.reads.count == expected, "\(name): \(result.reads)")
            #expect(reader.snapshotMetrics().headerSkippedCoveredInHack == 5 - expected, "\(name)")
        }
    }

    @Test("Off reads under the window as before; on, it skips with or without the still skip and the mask")
    func switches() async throws {
        let frames = try Self.changing(window: HeaderWindowMaskTests.window)
        let offReads = ReadTimes()
        let off = try await play(frames, reader: reader(cover: false, reads: offReads), reads: offReads)
        #expect(off.reads == [0, 0.125, 0.25, 0.375, 0.5])
        for (still, mask) in [(false, false), (true, true), (false, true)] {
            let reads = ReadTimes()
            let on = try await play(frames, reader: reader(still: still, mask: mask, reads: reads), reads: reads)
            #expect(on.reads.isEmpty, "still \(still), mask \(mask): \(on.reads)")
        }
    }

    @Test("A still look the cadence holds is not counted, and a covered look issues no still reading")
    func composesWithStillSkip() async throws {
        let open = try HeaderWindowMaskTests.frame(window: nil)
        let covered = try HeaderWindowMaskTests.frame(window: HeaderWindowMaskTests.window)
        let reads = ReadTimes(), reader = reader(reads: reads)
        // A read with the window away anchors the still skip; the next look,
        // still, issues it again; then the window comes over the header.
        let result = try await play([open, open, covered, covered], reader: reader, reads: reads)
        #expect(result.reads == [0])
        #expect(reader.issuedReading(for: 0.125, session: session)?.reused == true)
        let metrics = reader.snapshotMetrics()
        #expect(metrics.headerSkippedStillInHack == 1 && metrics.headerSkippedCoveredInHack == 2)
        // The anchor's reading is at most 0.35 s old to be issued: at 0.5 s
        // the last one issued (0.125 s) has gone, and no covered look renewed it.
        #expect(reader.issuedReading(for: 0.5, session: session) == nil)
    }

    @Test("A lazy frame is never rendered for the window, nor for a covered look")
    func lazyFrame() async throws {
        let frame = try HeaderWindowMaskTests.frame(), renders = ReadTimes(), reads = ReadTimes()
        let reader = reader(reads: reads)
        let lazy = GameHeaderReader.LazyFrame(width: frame.image.width, height: frame.image.height,
                                              whole: { renders.append(-1); return frame.image }) { rect in
            renders.append(rect.minY)
            return frame.image.cropping(to: rect)
        }
        for time in [0, 0.125] {
            reader.submit(lazy, at: time, session: session, inHack: true, topBand: frame.band)
            try await finish(reader)
        }
        #expect(reads.values.isEmpty && renders.values.isEmpty)
        // Without a band the window can't be looked for: the read renders
        // the header, as before.
        reader.submit(lazy, at: 0.25, session: session, inHack: true)
        try await finish(reader)
        #expect(reads.values == [0.25] && renders.values.count == 1)
    }

    @Test("A covered command read reads its notice alone, renders nothing for the header, and is counted")
    func commandRead() async throws {
        try TestFixtures.requireScreenshots()
        let notice = try #require(ImageDecoder.cgImage(from: Data(contentsOf: try TestFixtures.url("simple", "png"))))
        let frame = try HeaderWindowMaskTests.frame(), open = try HeaderWindowMaskTests.frame(window: nil)
        let renders = ReadTimes()
        for (name, picture, cover, expectsHeader) in [("covered", frame, true, false), ("open", open, true, true),
                                                      ("off", frame, false, true)] {
            let reads = ReadTimes(), meter = PowerMeter()
            meter.reset()
            let reader = reader(cover: cover, meter: meter, reads: reads)
            let lazy = GameHeaderReader.LazyFrame(width: picture.image.width, height: picture.image.height,
                                                  whole: { renders.append(-1); return picture.image }) { rect in
                renders.append(rect.minY)
                return picture.image.cropping(to: rect)
            }
            let commands = CommandNoticeCapture()
            try commands.observe(band: notice, at: 0.2)
            let before = renders.values.count
            #expect(reader.submit(lazy, at: 0.2, session: session, commands: commands, inHack: true,
                                  topBand: picture.band) == .read(.command), "\(name)")
            try await finish(reader)
            #expect(reader.takeCommand()?.0.sourceTime == 0.2, "\(name)")
            #expect(reads.values == (expectsHeader ? [0.2] : []), "\(name): \(reads.values)")
            #expect(renders.values.count - before == (expectsHeader ? 1 : 0), "\(name)")
            #expect((reader.latestReading(session: session) != nil) == expectsHeader, "\(name)")
            let metrics = reader.snapshotMetrics()
            #expect(metrics.headerSkippedCoveredInHack == (expectsHeader ? 0 : 1), "\(name)")
            #expect(metrics.headerInHackSubmitted == (expectsHeader ? 1 : 0), "\(name)")
            #expect(meter.snapshot().total(.headerCoveredInHack).count == (expectsHeader ? 0 : 1), "\(name)")
        }
    }

    @Test("The Power report shows covered skips under the header rows only when the cut ran")
    func powerReport() throws {
        let meter = PowerMeter(clock: { 0 }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: false), engine: "cpp",
                    cuts: [.headerStillSkip])
        #expect(!PowerReport.lines(meter.snapshot()).contains { $0.hasPrefix("cover") })
        meter.reset(languages: GameLanguageMemory(language: .english, isAutomatic: false), engine: "cpp",
                    cuts: [.headerStillSkip, .headerCoverSkip])
        meter.count(.headerCoveredInHack, 6)
        meter.count(.headerCoveredOutside, 3)
        let lines = PowerReport.lines(meter.snapshot())
        let still = try #require(lines.firstIndex { $0.hasPrefix(PowerMetric.headerStillOutside.label) })
        let covered = try #require(lines.firstIndex { $0.hasPrefix(PowerMetric.headerCoveredInHack.label) })
        #expect(covered == still + 2, "After the still rows and their note: \(lines)")
        #expect(lines.contains { $0.hasPrefix("cover hack") && $0.contains(" 6") })
        #expect(lines.contains { $0.hasPrefix("cover out") && $0.contains(" 3") })
        #expect(lines.allSatisfy { $0.count <= 42 }, "\(lines.filter { $0.count > 42 })")
        #expect(PowerMetric.headerCovered.allSatisfy { $0.label.count <= 11 && !PowerMetric.topLevel.contains($0) })
        #expect(Array(PowerMetric.allCases.suffix(2)) == PowerMetric.headerCovered,
                "Added at the end, so the raw values before keep their order")
    }

    @Test("The cut is last among the cuts, off by default and honoured by the Swift engine")
    func cutConventions() {
        #expect(RecognitionCut.allCases.last == .headerCoverSkip)
        #expect(!AppPreferences.defaultRecognitionCuts.contains(.headerCoverSkip))
        #expect(RecognitionCut.swiftEngineCuts.contains(.headerCoverSkip))
    }
}

/// The `headerCoverSkip` cut through the whole live output, beside the still
/// skip alone: the app's window drawn over the header of a command channel
/// whose band shows a notice. The injected OCR reads nothing a covered header
/// would give; geometry, the tracker, the command watch and the pace are the
/// real pipeline's.
@Suite("Header cover skip in the live output", .serialized)
struct HeaderCoverSkipWatchTests {
    struct Run {
        var watch: [(time: Double, watching: Bool)] = []
        var rows: [[String: Any]] = []
        var events: [(kind: TrackingEvent.Kind, time: Double)] = []
        var metrics: GameHeaderReader.Metrics
        var reads = 0

        var headerRows: [[String: Any]] { rows.filter { $0["headerSourceTime"] != nil } }
    }

    /// Plays `end` seconds at 60 Hz with the window's top at `windowTopShare`
    /// of the header's height, so it covers the rest of the header's rows.
    /// The injected OCR gives `reading` at each read's time.
    static func play(cuts: Set<RecognitionCut>, until end: Double, windowTopShare: Double,
                     reading: @escaping @Sendable (Double) -> HeaderReading) throws -> Run {
        let directory = try TemporaryDirectory("cover-watch")
        let clock = CoverSourceClock()
        let meter = PowerMeter(clock: { clock.nanoseconds }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let gate = CoverCurrentGate()
        let reads = ReadTimes()
        let events = WatchReproductionValues<LiveGlyphTrace>()
        let output = try LiveGlyphOutput(
            table: SetupDemo.builtInTable, sequenceTable: nil, sessionID: CaptureSessionID(rawValue: 7),
            directory: directory.url, readsResults: true,
            power: PowerConditions(center: NotificationCenter(), read: { .init() }), cuts: cuts, meter: meter,
            headerOperation: { _, time in
                reads.append(time)
                await gate.current.wait()
                return reading(time)
            }, trace: { events.append($0) },
            telemetry: { _ in }, deliverResult: { _ in }, deliver: { _ in })
        let channel = try paint(Frames.recorded("field-00381"), windowTopShare: windowTopShare)
        let drawn = try paint(CommandDrawingFrame.make(), windowTopShare: windowTopShare)
        var run = Run(metrics: output.textReadMetrics)
        for index in 0...Int((end * 60).rounded()) {
            let time = Double(index) / 60
            clock.set(time)
            let opened = AsyncHeaderGate()
            gate.current = opened
            output.process(CapturedFrame(sampleBuffer: try Frames.sample(index == 0 ? channel : drawn, at: time),
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
        run.reads = reads.values.count
        output.close()
        let text = try String(contentsOf: directory.url.appendingPathComponent("recognition.jsonl"), encoding: .utf8)
        run.rows = try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        run.events = events.values.flatMap { $0.events.map { ($0.kind, $0.time) } }
        return run
    }

    /// The header rows, with a two-row guard, striped grey and black, then
    /// the window, a grey ring around a dark interior, from `windowTopShare`
    /// of the header's height down past its bottom.
    private static func paint(_ buffer: CVPixelBuffer, windowTopShare: Double) throws -> CVPixelBuffer {
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
            for x in 0..<width { luma[y * stride + x] = x % 8 < 4 ? 110 : 0 }
        }
        let left = Int(0.028 * Double(width)), right = width - left
        let windowHeight = (right - left) / 10
        let windowTop = Int(headerTop + windowTopShare * (headerBottom - headerTop))
        let ring = max(3, windowHeight * 8 / 100)
        for y in windowTop..<min(height, windowTop + windowHeight) {
            for x in left..<right {
                let onRing = y < windowTop + ring || y >= windowTop + windowHeight - ring
                    || x < left + ring || x >= right - ring
                luma[y * stride + x] = onRing ? 180 : 16
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

    private static let unreadable: @Sendable (Double) -> HeaderReading = {
        HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: $0)
    }

    @Test("Under the window the header is never read and the frames carry no header reading; tracking is unchanged")
    func coveredHeaderIsNotRead() throws {
        let off = try Self.play(cuts: [.headerStillSkip], until: 3, windowTopShare: 0.1, reading: Self.unreadable)
        let on = try Self.play(cuts: [.headerStillSkip, .headerCoverSkip], until: 3, windowTopShare: 0.1,
                               reading: Self.unreadable)
        print("COVER WATCH covered: header reads off \(off.reads) on \(on.reads); covered "
              + "\(on.metrics.headerSkippedCoveredInHack)/\(on.metrics.headerSkippedCoveredOutside); "
              + "rows with a header off \(off.headerRows.count) on \(on.headerRows.count)")
        #expect(off.reads > 0 && !off.headerRows.isEmpty, "Without the cut the covered header is read")
        #expect(on.reads == 0, "No header OCR, command reads included: \(on.reads)")
        #expect(on.metrics.headerInHackSubmitted + on.metrics.headerOutsideSubmitted == 0)
        #expect(on.metrics.headerSkippedCoveredInHack + on.metrics.headerSkippedCoveredOutside > 0)
        #expect(on.headerRows.isEmpty, "No frame is given a header reading")
        #expect(on.events.map(\.kind) == off.events.map(\.kind), "\(on.events) against \(off.events)")
    }

    @Test("A window over less than half of the header changes nothing: the same reads, readings and tracking")
    func partlyCoveredHeaderReads() throws {
        let command: @Sendable (Double) -> HeaderReading = {
            HeaderReading(phase: .command, matchedText: "INJECTED command", confidence: 1, sourceTime: $0)
        }
        let off = try Self.play(cuts: [.headerStillSkip], until: 3, windowTopShare: 0.6, reading: command)
        let on = try Self.play(cuts: [.headerStillSkip, .headerCoverSkip], until: 3, windowTopShare: 0.6,
                               reading: command)
        #expect(on.metrics.headerSkippedCoveredInHack == 0 && on.metrics.headerSkippedCoveredOutside == 0)
        #expect(on.reads == off.reads && on.reads > 0)
        #expect(on.headerRows.count == off.headerRows.count)
        let phases = { (run: Run) in run.headerRows.map { "\($0["headerSourceTime"] ?? "") \($0["headerPhase"] ?? "")" } }
        #expect(phases(on) == phases(off))
        #expect(on.events.map(\.kind) == off.events.map(\.kind))
        #expect(on.watch.map(\.watching) == off.watch.map(\.watching))
    }
}

/// The meter's clock, set to each frame's source time.
private final class CoverSourceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    var nanoseconds: UInt64 { lock.withLock { now } }
    func set(_ seconds: Double) { lock.withLock { now = UInt64((seconds * 1e9).rounded()) } }
}

/// The gate a read in flight waits on: the frame that asked for it opens it
/// once `process` has returned.
private final class CoverCurrentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = AsyncHeaderGate()
    var current: AsyncHeaderGate {
        get { lock.withLock { gate } }
        set { lock.withLock { gate = newValue } }
    }
}
