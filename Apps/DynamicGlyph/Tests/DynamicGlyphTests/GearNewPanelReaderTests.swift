import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

/// Build 103, decision (a): a new gear panel, told by its geometry, stops the
/// gear read in flight; the stopped read keeps the lane until it returns, so
/// two reads never run at once, and the new panel's first read follows with no
/// spacing. Constrained, analysis runs at 20 Hz while a panel shows. The lane
/// tests inject reads (no Vision); the capture-output tests read the committed
/// `five-base`/`five-bonus` fixtures through the app's own lane, with the
/// frames driven from a thread of their own, never Swift's shared pool.
@Suite("Build 103: new gear panels on the shared lane", .serialized)
struct GearNewPanelReaderTests {
    private let session = CaptureSessionID(rawValue: 1)
    static let settled = GearDropPanelBounds(top: 0.2847, bottom: 0.4156)
    static let slide = [0.3155, 0.3097, 0.3026, 0.2883].map { GearDropPanelBounds(top: $0, bottom: $0 + 0.1309) }

    // MARK: - The lane, with injected reads

    /// Injected gear reads: each runs `durations` in turn (the last repeats),
    /// stops when cancelled if `honoursStops`, and counts reads running at once.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var durations: [TimeInterval]
        private let honoursStops: Bool
        private var running = 0
        private(set) var mostAtOnce = 0
        private(set) var started: [Double] = []
        init(_ durations: [TimeInterval], honoursStops: Bool = true) {
            self.durations = durations; self.honoursStops = honoursStops
        }
        func read(_ bounds: GearDropPanelBounds, _ time: Double, _ token: GearReadCancellation) throws -> GearPanelReading {
            let duration: TimeInterval = lock.withLock {
                running += 1; mostAtOnce = max(mostAtOnce, running); started.append(time)
                return durations.count > 1 ? durations.removeFirst() : durations[0]
            }
            defer { lock.withLock { running -= 1 } }
            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline {
                if honoursStops { try token.check() }
                Thread.sleep(forTimeInterval: 0.002)
            }
            return GearPanelReading(evidence: GearDropFrameEvidence(sourceTime: time, stage: .portal, bounds: bounds))
        }
        var startedTimes: [Double] { lock.withLock { started } }
    }

    private func image() throws -> CGImage {
        let width = 64, height = 200
        let pixels = [UInt8](repeating: 20, count: width * height * 3)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func reader(_ reads: Reads) -> GameHeaderReader {
        GameHeaderReader(
            headerOperation: { _, time in HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time) },
            cancellableGearReadingOperation: { _, bounds, time, token in try reads.read(bounds, time, token) })
    }

    private func submit(_ reader: GameHeaderReader, _ frame: CGImage, at time: Double, _ bounds: GearDropPanelBounds?,
                        unconfirmed: Bool = false) {
        reader.submit(frame, at: time, session: session, gearBounds: bounds, readsHeader: false, constrained: true,
                      gearPanelSettled: true, gearPanelUnconfirmed: unconfirmed, inHack: false)
    }

    private func waitWhileReading(_ reader: GameHeaderReader, seconds: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while reader.isReading {
            if Date() > deadline { return false }
            try await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func waitForStart(_ reads: Reads, count: Int) async throws {
        for _ in 0..<1000 where reads.startedTimes.count < count { try await Task.sleep(for: .milliseconds(2)) }
        #expect(reads.startedTimes.count >= count)
    }

    @Test("A new panel stops the running read, which keeps the lane until it returns; the new panel is read at once")
    func stopsThenReadsAtOnce() async throws {
        let reads = Reads([3, 0.05])
        let reader = reader(reads), frame = try image()
        reader.observeGearPanel(Self.settled, at: -0.05)
        submit(reader, frame, at: 0, Self.settled)
        try await waitForStart(reads, count: 1)
        submit(reader, frame, at: 0.05, Self.settled)
        // The Bonus panel slides in.
        submit(reader, frame, at: 0.1, Self.slide[0])
        #expect(reader.isReading, "the stopped read still owns the lane")
        #expect(try await waitWhileReading(reader, seconds: 2), "the read was not stopped")
        #expect(reader.takeGear() == nil, "a stopped read delivers nothing")
        let cancels = reader.takeGearCancels()
        #expect(cancels.count == 1)
        #expect(cancels.first?.stopped == true && cancels.first?.sourceTime == 0 && cancels.first?.requestedAt == 0.1)
        #expect((cancels.first?.latencyMilliseconds ?? .infinity) < 2000)
        var metrics = reader.snapshotMetrics()
        #expect(metrics.gearCancelRequested == 1 && metrics.gearCancelStopped == 1 && metrics.gearCancelFinished == 0)
        #expect(metrics.failed == 0 && metrics.gearError == nil, "a stop is no failure")
        // 0.15 s after the stopped read started: constrained, a gear read
        // waits 0.4 s and any read 0.2 s; the new panel's first doesn't.
        submit(reader, frame, at: 0.15, Self.slide[1])
        metrics = reader.snapshotMetrics()
        #expect(metrics.gearSubmitted == 2, "\(reads.startedTimes)")
        #expect(try await waitWhileReading(reader, seconds: 2))
        #expect(reader.takeGear()?.evidence.sourceTime == 0.15)
        #expect(reads.mostAtOnce == 1, "never two reads at once")
    }

    @Test("A read that finishes before it can stop is delivered as usual; the new panel's read still follows at once")
    func finishedReadDelivered() async throws {
        let reads = Reads([0.3, 0.05], honoursStops: false)
        let reader = reader(reads), frame = try image()
        reader.observeGearPanel(Self.settled, at: -0.05)
        submit(reader, frame, at: 0, Self.settled)
        try await waitForStart(reads, count: 1)
        submit(reader, frame, at: 0.1, Self.slide[0])
        #expect(try await waitWhileReading(reader, seconds: 2))
        #expect(reader.takeGear()?.evidence.sourceTime == 0)
        #expect(reader.takeGearCancels().first?.stopped == false)
        #expect(reader.snapshotMetrics().gearCancelFinished == 1)
        submit(reader, frame, at: 0.15, Self.slide[1])
        #expect(reader.snapshotMetrics().gearSubmitted == 2)
        #expect(try await waitWhileReading(reader, seconds: 2))
        #expect(reads.mostAtOnce == 1)
    }

    @Test("A read of a panel with rows unconfirmed runs on; the new panel's first read still has no spacing")
    func unconfirmedRunsOn() async throws {
        let reads = Reads([0.3, 0.05])
        let reader = reader(reads), frame = try image()
        reader.observeGearPanel(Self.settled, at: -0.05)
        submit(reader, frame, at: 0, Self.settled)
        try await waitForStart(reads, count: 1)
        submit(reader, frame, at: 0.1, Self.slide[0], unconfirmed: true)
        #expect(try await waitWhileReading(reader, seconds: 2))
        #expect(reader.snapshotMetrics().gearCancelRequested == 0)
        #expect(reader.takeGear()?.evidence.sourceTime == 0)
        submit(reader, frame, at: 0.15, Self.slide[1], unconfirmed: true)
        #expect(reader.snapshotMetrics().gearSubmitted == 2)
        #expect(try await waitWhileReading(reader, seconds: 2))
    }

    @Test("The same panel, still or with spark jitter, never stops its own reads")
    func samePanelNeverStopped() async throws {
        let reads = Reads([0.03])
        let reader = reader(reads), frame = try image()
        for step in 0..<60 {
            let time = Double(step) * 0.05
            let jitter = [0, 0.0015, -0.0007, 0.0012, -0.0015][step % 5]
            let bounds = step < 4 ? Self.slide[step]
                : GearDropPanelBounds(top: 0.2847 + jitter, bottom: 0.4156 + jitter / 2)
            submit(reader, frame, at: time, bounds)
            #expect(try await waitWhileReading(reader, seconds: 2))
            _ = reader.takeGear()
        }
        #expect(reader.snapshotMetrics().gearCancelRequested == 0)
        #expect(reader.snapshotMetrics().gearSubmitted >= 7)
    }

    // MARK: - Through the capture output, recorded panels

    struct Buffer: @unchecked Sendable { let pixels: CVPixelBuffer }

    final class Drops: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GearDrop] = []
        func append(_ drop: GearDrop) { lock.withLock { stored.append(drop) } }
        var values: [GearDrop] { lock.withLock { stored } }
    }

    /// The test's frame loop on a thread of its own: it waits on each text
    /// read, which runs Vision in the app's lane.
    func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    private func fixture(_ name: String) throws -> CGImage {
        try #require(ImageDecoder.cgImage(from: Data(contentsOf: TestFixtures.url(name, "png"))))
    }

    /// `image` moved down by `fraction` of its height, as a panel sliding in.
    private func shifted(_ image: CGImage, by fraction: Double) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Core Graphics' origin is the bottom left: down is a smaller y.
        let dy = (fraction * Double(image.height)).rounded()
        context.draw(image, in: CGRect(x: 0, y: -dy, width: Double(image.width), height: Double(image.height)))
        return try #require(context.makeImage())
    }

    private func blank(like image: CGImage) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(context.makeImage())
    }

    private func pixelBuffer(_ image: CGImage) throws -> Buffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: image.width,
            height: image.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Buffer(pixels: pixels)
    }

    struct Run: Sendable {
        let drops: [GearDrop]
        /// `recognition.jsonl` frame times and `gear-drops.jsonl` rows, as JSON text.
        let analysed: [Double]
        let gearLog: String
    }

    /// Gear-only capture in Low Power Mode at 60 Hz; each frame waits for its
    /// text read, as a phone that keeps up.
    private func run(_ script: [(Buffer, Int)]) async throws -> Run {
        let directory = try TemporaryDirectory("new-panel-gear")
        let session = session
        let drops = Drops()
        return try await offPool {
            let output = try LiveGlyphOutput(table: nil, sequenceTable: nil, sessionID: session, directory: directory.url,
                readsResults: false, power: PowerConditions(center: NotificationCenter(), read: { .init(lowPowerMode: true) }),
                powerSaving: true, telemetry: { _ in }, deliverResult: { _ in },
                deliverDrop: { drops.append($0) }) { _ in }
            var index = 0
            for (buffer, frames) in script {
                for _ in 0..<frames {
                    let time = Double(index) / 60
                    output.process(CapturedFrame(sampleBuffer: try Frames.sample(buffer.pixels, at: time),
                        metadata: CaptureFrameMetadata(status: .complete), arrivalUptime: 100 + time,
                        deliveryGapMilliseconds: nil, continuityBroken: false))
                    let deadline = Date().addingTimeInterval(20)
                    while output.isReadingText && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                    index += 1
                }
            }
            output.close()
            let frames = try String(contentsOf: directory.url.appendingPathComponent("recognition.jsonl"), encoding: .utf8)
                .split(separator: "\n").compactMap { line -> Double? in
                    let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    return row?["presentationTime"] as? Double
                }
            let log = try String(contentsOf: directory.url.appendingPathComponent("gear-drops.jsonl"), encoding: .utf8)
            return Run(drops: drops.values, analysed: frames, gearLog: log)
        }
    }

    private func readings(_ log: String) -> [[String: Any]] {
        log.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["kind"] as? String == "reading" }
    }

    private func items(_ drop: GearDrop?, _ stage: GearDropStage) -> [String] {
        (drop?.summary.panels ?? []).filter { $0.stage == stage }.flatMap(\.entries)
            .map { "\($0.item ?? "?") ×\($0.quantity)" }.sorted()
    }

    @Test("Low Power Mode: analysis runs at 20 Hz while a gear panel shows, every 0.1 s before and after")
    func twentyHertzOnPanels() async throws {
        let panel = try fixture("five-base")
        let base = try pixelBuffer(panel), map = try pixelBuffer(try blank(like: panel))
        // A second of map, a second of panel, a second of map.
        let result = try await run([(map, 60), (base, 60), (map, 60)])
        let before = result.analysed.filter { $0 > 0.15 && $0 < 1 - 1e-9 }
        let during = result.analysed.filter { $0 > 1.1 && $0 < 2 - 1e-9 }
        let after = result.analysed.filter { $0 > 2.2 }
        func gaps(_ times: [Double]) -> [Double] { zip(times, times.dropFirst()).map { $1 - $0 } }
        #expect(!before.isEmpty && gaps(before).allSatisfy { $0 >= 0.099 - 1e-6 }, "\(gaps(before))")
        #expect(during.count >= 16 && gaps(during).allSatisfy { $0 <= 0.051 }, "\(gaps(during))")
        #expect(!after.isEmpty && gaps(after).allSatisfy { $0 >= 0.099 - 1e-6 }, "\(gaps(after))")
        #expect(result.drops.count == 1)
        #expect(items(result.drops.first, .portal) == ["Resonator ×1", "Turret ×1"])
    }

    @Test("Low Power Mode: a 0.45-s Bonus panel sliding in where the portal panel was is read on its first frame and kept")
    func slidingBonusKept() async throws {
        let base = try fixture("five-base"), bonus = try fixture("five-bonus")
        let map = try pixelBuffer(try blank(like: base))
        // Its first four 20-fps frames 0.031, 0.025, 0.018 and 0.004 below its place.
        var script: [(Buffer, Int)] = [(map, 12), (try pixelBuffer(base), 72)]
        for shift in [0.0308, 0.025, 0.0179, 0.0036] { script.append((try pixelBuffer(try shifted(bonus, by: shift)), 3)) }
        script += [(try pixelBuffer(bonus), 15), (map, 30)]
        let result = try await run(script)
        let rows = readings(result.gearLog)
        func time(_ row: [String: Any]) -> Double { row["sourceTime"] as? Double ?? -1 }
        let bonusReads = rows.filter { $0["stage"] as? String == "bonus" }.map(time)
        let first = try #require(bonusReads.first, "the Bonus panel was never read")
        #expect(first - 1.4 <= 0.051, "first Bonus read \(first - 1.4) s after it came")
        #expect(bonusReads.count >= 2)
        #expect(result.drops.count == 1)
        #expect(items(result.drops.first, .bonus) == ["Power Cube ×1", "Resonator ×1", "XMP Burster ×1"],
                "\(items(result.drops.first, .bonus))")
        #expect(items(result.drops.first, .portal) == ["Resonator ×1", "Turret ×1"])
        #expect(!result.gearLog.contains("\"text\""))
    }
}
