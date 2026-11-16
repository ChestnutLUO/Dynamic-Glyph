import CoreGraphics
import CoreVideo
import Foundation
import GlyphRecognition
import GlyphRecognitionImages
import Testing

/// The `headerStillSkip` cut through the whole live output: the readings it
/// issues again reach the tracker and the command watch as the reads of those
/// frames would. The injected OCR reads the header's pixels, not the clock,
/// so a header that has not changed reads the same, as the cut assumes; each
/// read finishes only after the frame that asked for it, so it reaches the
/// next analysed frame on every run. Geometry, the tracker, the command
/// watch and the pace are the real pipeline's.
@Suite("Still header skip in the live output", .serialized)
struct HeaderStillWatchTests {
    /// Header shades the injected OCR reads, by the header's mean grey.
    enum Shade: UInt8, CaseIterable {
        /// Nothing recognised: a covered or blank header.
        case unreadable = 24
        case command = 110
        /// Readable text of another phase than the command channel.
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

    struct Run {
        /// Each played frame's time and whether the command watch held then.
        var watch: [(time: Double, watching: Bool)] = []
        var rows: [[String: Any]] = []
        var events: [(kind: TrackingEvent.Kind, time: Double)] = []
        var metrics: GameHeaderReader.Metrics

        /// Header looks the lane answered: reads, and skips of either kind.
        var looks: Int {
            metrics.headerInHackSubmitted + metrics.headerOutsideSubmitted + metrics.headerSkippedUnchanged
                + metrics.headerSkippedStillInHack + metrics.headerSkippedStillOutside
        }

        func released(after time: Double) -> Double? {
            watch.first { $0.time > time && !$0.watching }?.time
        }

        func watched(_ range: ClosedRange<Double>) -> Bool {
            let frames = watch.filter { range.contains($0.time) }
            return !frames.isEmpty && frames.allSatisfy(\.watching)
        }
    }

    /// The command channel with its array fitted at 0, then a command drawn
    /// over the array from the next frame, at 60 Hz to `end`, the header
    /// painted `shade(time)`.
    static func play(cuts: Set<RecognitionCut>, until end: Double,
                     shade: @escaping @Sendable (Double) -> Shade) throws -> Run {
        let directory = try TemporaryDirectory("still-watch")
        let clock = SourceClock()
        let meter = PowerMeter(clock: { clock.nanoseconds }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let gate = CurrentGate()
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
        var frames: [Shade: (channel: CVPixelBuffer, drawn: CVPixelBuffer)] = [:]
        for shade in Shade.allCases {
            frames[shade] = (try paint(Frames.recorded("field-00381"), shade),
                             try paint(CommandDrawingFrame.make(), shade))
        }
        var run = Run(metrics: output.textReadMetrics)
        for index in 0...Int((end * 60).rounded()) {
            let time = Double(index) / 60
            let pair = try #require(frames[shade(time)])
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

    /// The header's mean grey, as the read was given it: the whole frame or
    /// its header rectangle alone.
    private static func shade(of image: GameHeaderReader.HeaderImage) throws -> Shade {
        let crop: CGImage
        switch image {
        case .frame(let frame): crop = try #require(HeaderTextRecognizer().headerCrop(of: frame))
        case .region(let region): crop = region
        }
        let grey = try ImageDecoder.decode(crop)
        let mean = Double(grey.pixels.reduce(0) { $0 + Int($1) }) / Double(max(1, grey.pixels.count))
        return try #require(Shade.allCases.min { abs(Double($0.rawValue) - mean) < abs(Double($1.rawValue) - mean) })
    }

    /// The header rows, with a two-row guard, painted one neutral grey.
    private static func paint(_ buffer: CVPixelBuffer, _ shade: Shade) throws -> CVPixelBuffer {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let height = CVPixelBufferGetHeight(buffer), width = CVPixelBufferGetWidth(buffer)
        let layout = GameUILayout()
        let top = max(0, Int(floor(layout.headerTextTop * Double(height))) - 2)
        let bottom = min(height, Int(ceil(layout.headerTextBottom * Double(height))) + 2)
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        for y in top..<bottom {
            memset(luma + y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), Int32(shade.rawValue), width)
        }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in max(0, top / 2 - 1)..<min(CVPixelBufferGetHeightOfPlane(buffer, 1), (bottom + 1) / 2 + 1) {
            memset(chroma + y * chromaStride, 128, chromaStride)
        }
        return buffer
    }

    @Test("A header that stops reading as the command channel ends the watch when real reads would, with no command reused past it",
          arguments: [Shade.unreadable, .contrary])
    func changedHeaderReleasesWatch(_ after: Shade) throws {
        let change = 3.0
        let shade: @Sendable (Double) -> Shade = { $0 <= change ? .command : after }
        let off = try Self.play(cuts: [], until: 5, shade: shade)
        let on = try Self.play(cuts: [.headerStillSkip], until: 5, shade: shade)
        let offRelease = try #require(off.released(after: 0.1))
        let onRelease = try #require(on.released(after: 0.1))
        print("STILL WATCH \(after): released off \(offRelease) on \(onRelease); header reads off "
              + "\(off.metrics.headerInHackSubmitted) on \(on.metrics.headerInHackSubmitted), "
              + "still skips \(on.metrics.headerSkippedStillInHack)")
        #expect(off.watched(0.1...change) && on.watched(0.1...change), "Watched while the header reads command")
        // Both runs answer the header at the same frames; a reading issued
        // again reaches its own frame's row, a read the next one's.
        #expect(onRelease <= offRelease + 1e-9 && offRelease - onRelease <= 0.05 + 1e-9,
                "off \(offRelease), on \(onRelease)")
        #expect(on.metrics.headerSkippedStillInHack > 0 && on.looks == off.looks,
                "Every look is a read or a skip in both: on \(on.looks), off \(off.looks)")
        #expect(on.rows.contains { $0["headerReused"] as? Bool == true && $0["headerPhase"] as? String == "command" },
                "The cut reused command readings before the change")
        // No frame after the change carries the command channel, and the
        // first one answered was read, not reused.
        let after = on.rows.filter { ($0["headerSourceTime"] as? Double ?? 0) > change }
        #expect(!after.isEmpty && after.allSatisfy { $0["headerPhase"] as? String != "command" })
        let first = try #require(after.first)
        #expect(first["headerReused"] == nil, "The changed header was read: \(first)")
        // The tracker saw the same events, each at most a frame earlier.
        #expect(on.events.map(\.kind) == off.events.map(\.kind), "\(on.events) against \(off.events)")
        for (a, b) in zip(on.events, off.events) {
            #expect(a.time <= b.time + 1e-9 && b.time - a.time <= 0.05 + 1e-9, "\(a) against \(b)")
        }
    }

    @Test("Off, the live output reuses nothing: no reading is marked reused and no still skip is counted")
    func offReusesNothing() throws {
        let run = try Self.play(cuts: [], until: 2, shade: { _ in .command })
        #expect(run.rows.allSatisfy { $0["headerReused"] == nil })
        #expect(run.metrics.headerSkippedStillInHack == 0 && run.metrics.headerSkippedStillOutside == 0)
        // In a hack the still header is read at the lane's 0.1-s cadence,
        // every second or, with the 60-Hz clock's rounding, third analysed
        // frame: none of them is skipped.
        let analysed = run.rows.count, reads = run.metrics.headerInHackSubmitted + run.metrics.headerOutsideSubmitted
        #expect(reads >= analysed / 3 && reads <= analysed / 2 + 1, "\(reads) reads of \(analysed) frames")
    }
}

/// The meter's clock, set to each frame's source time.
private final class SourceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    var nanoseconds: UInt64 { lock.withLock { now } }
    func set(_ seconds: Double) { lock.withLock { now = UInt64((seconds * 1e9).rounded()) } }
}

/// The gate a read in flight waits on: the frame that asked for it opens it
/// once `process` has returned.
private final class CurrentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = AsyncHeaderGate()
    var current: AsyncHeaderGate {
        get { lock.withLock { gate } }
        set { lock.withLock { gate = newValue } }
    }
}
