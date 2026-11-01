import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

/// A gear read whose title went unread, though its body is a drop panel's
/// (the effect line or known item rows), is a panel with an unread title, not
/// a miss: it doesn't back the lane off, so the Bonus panel that replaces it
/// in the same place is read on time. (The capture output's own rejection
/// count, which slows analysis after a settle time, still counts it.)
/// Constrained, such a title now gets one recovery pass. Each read's OCR
/// passes are logged to the session's gear log as counts and confidences,
/// never text. Panels are the committed `five-base`/`five-bonus` fixtures,
/// with synthetic titles drawn or painted out at run time. The logs also
/// tell Low Power Mode from heat: each read and frame logs both triggers.
@Suite("Untitled gear panels on the shared lane", .serialized)
struct GearUntitledLaneTests {
    private let session = CaptureSessionID(rawValue: 1)
    private let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.42)

    // MARK: - The lane, with injected reads

    private func smallImage() throws -> CGImage {
        let width = 64, height = 200
        let pixels = [UInt8](repeating: 20, count: width * height * 3)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Constrained frames every 0.1 s; each read finishes before the next.
    private func laneReads(untitled: Bool) async throws -> [(time: Double, stage: GearDropStage)] {
        let reader = GameHeaderReader(
            headerOperation: { _, time in HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time) },
            gearReadingOperation: { _, bounds, time in
                // A portal panel whose title is never read until 1.3 s, then its Bonus panel.
                time < 1.3 - 1e-9
                    ? GearPanelReading(evidence: GearDropFrameEvidence(sourceTime: time, stage: .unknown, bounds: bounds),
                                       untitledPanel: untitled)
                    : GearPanelReading(evidence: GearDropFrameEvidence(sourceTime: time, stage: .bonus, bounds: bounds))
            })
        let frame = try smallImage()
        var reads: [(Double, GearDropStage)] = []
        for step in 0...25 {
            let time = Double(step) / 10
            reader.submit(frame, at: time, session: session, gearBounds: bounds, readsHeader: false,
                          constrained: true, gearPanelSettled: false, inHack: false)
            for _ in 0..<300 where reader.isReading { try await Task.sleep(for: .milliseconds(5)) }
            if let read = reader.takeGear() { reads.append((read.evidence.sourceTime, read.evidence.stage)) }
        }
        return reads
    }

    @Test("Constrained lane: untitled reads keep the panel's cadence, so its Bonus panel is read on time")
    func laneKeepsCadence() async throws {
        let reads = try await laneReads(untitled: true)
        let tenths = reads.map { Int(($0.time * 10).rounded()) }
        #expect(Array(tenths.prefix(4)) == [0, 4, 8, 12], "\(tenths)")
        let firstBonus = try #require(reads.first { $0.stage == .bonus })
        #expect(firstBonus.time - 1.3 <= 0.4 + 1e-9, "Bonus first read \(firstBonus.time)")
        // Found, it gets the panel pace: its second read 0.2 s later.
        let bonus = reads.filter { $0.stage == .bonus }.map { Int(($0.time * 10).rounded()) }
        #expect(bonus.count >= 2 && bonus[1] - bonus[0] == 2, "\(bonus)")
    }

    @Test("Constrained lane: reads that show no panel at all still back off, as before")
    func laneStillBacksOff() async throws {
        let reads = try await laneReads(untitled: false)
        let tenths = reads.map { Int(($0.time * 10).rounded()) }
        #expect(Array(tenths.prefix(4)) == [0, 4, 8, 18], "\(tenths)")
    }

    // MARK: - Through the capture output

    private final class Drops: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GearDrop] = []
        func append(_ drop: GearDrop) { lock.withLock { stored.append(drop) } }
        var values: [GearDrop] { lock.withLock { stored } }
    }

    private final class Clock: @unchecked Sendable {
        var now: UInt64 = 0
        func set(_ seconds: Double) { now = UInt64((seconds * 1e9).rounded()) }
    }

    private func image(_ name: String) throws -> CGImage {
        let url = try TestFixtures.url(name, "png")
        return try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)))
    }

    /// `five-base` with its title painted out in the panel's colour and, if
    /// given, `title` drawn in its place. Test-only; nothing is saved.
    private func retitled(_ title: String?) throws -> CGImage {
        let base = try image("five-base")
        let context = try #require(CGContext(data: nil, width: base.width, height: base.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: 1, y: -1)
        // Between the top border (rows 379-380) and the first item row (440).
        context.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 20, y: 386, width: 522, height: 48))
        if let title {
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName("PingFangTC-Regular" as CFString, 18, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 0.75, green: 0.70, blue: 0.95, alpha: 1)
            ]))
            context.textPosition = CGPoint(x: (562 - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: 420)
            CTLineDraw(line, context)
        }
        return try #require(context.makeImage())
    }

    private func blank(like image: CGImage) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(context.makeImage())
    }

    private func pixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
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
        return pixels
    }

    private func sample(_ buffer: CVPixelBuffer, at seconds: Double) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample)
        return try #require(sample)
    }

    private struct Run {
        let directory: TemporaryDirectory
        let drops: [GearDrop]
        /// The `kind: reading` rows of gear-drops.jsonl.
        let readings: [[String: Any]]
        let log: String
    }

    /// Gear-only capture at 60 Hz, each frame waiting for its text read, as a
    /// phone that keeps up.
    private func run(_ script: [(CVPixelBuffer, Double)], lowPower: Bool) throws -> Run {
        let directory = try TemporaryDirectory("untitled-gear")
        let clock = Clock()
        let meter = PowerMeter(clock: { clock.now }, cpuTime: { 0 }, thermalState: { 0 })
        meter.reset()
        let drops = Drops()
        let output = try LiveGlyphOutput(table: nil, sequenceTable: nil, sessionID: session, directory: directory.url,
            readsResults: false, power: PowerConditions(center: NotificationCenter(), read: { .init(lowPowerMode: lowPower) }),
            powerSaving: true, meter: meter, telemetry: { _ in }, deliverResult: { _ in },
            deliverDrop: { drops.append($0) }) { _ in }
        var index = 0
        for (buffer, seconds) in script {
            let frames = Int((seconds * 60).rounded())
            for _ in 0..<frames {
                let time = Double(index) / 60
                clock.set(time)
                output.process(CapturedFrame(sampleBuffer: try sample(buffer, at: time),
                    metadata: CaptureFrameMetadata(status: .complete), arrivalUptime: 100 + time,
                    deliveryGapMilliseconds: nil, continuityBroken: false))
                let deadline = Date().addingTimeInterval(20)
                while output.isReadingText && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                index += 1
            }
        }
        output.close()
        let log = try String(contentsOf: directory.url.appendingPathComponent("gear-drops.jsonl"), encoding: .utf8)
        let rows = try log.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        return Run(directory: directory, drops: drops.values, readings: rows.filter { $0["kind"] as? String == "reading" },
                   log: log)
    }

    private func items(_ drop: GearDrop?, _ stage: GearDropStage) -> [String] {
        (drop?.summary.panels ?? []).filter { $0.stage == stage }.flatMap(\.entries)
            .map { "\($0.item ?? "?") ×\($0.quantity)" }.sorted()
    }

    @Test("A portal panel read with no title keeps the pace: its Bonus panel in the same place is read on time and kept")
    func bonusAfterUntitledPanel() throws {
        let untitled = try pixelBuffer(try retitled(nil)), bonus = try pixelBuffer(try image("five-bonus"))
        let map = try pixelBuffer(try blank(like: try image("five-base")))
        // 1.5 s of the untitled panel, 1 s of its Bonus panel, then the map.
        let result = try run([(untitled, 1.5), (bonus, 1.0), (map, 0.5)], lowPower: false)
        func time(_ row: [String: Any]) -> Double { row["sourceTime"] as? Double ?? -1 }
        let unread = result.readings.filter { time($0) < 1.5 - 1e-9 }
        #expect(unread.count >= 5 && unread.allSatisfy {
            $0["disposition"] as? String == "nonPanel" && $0["untitledPanel"] as? Bool == true
        }, "the painted-out title must leave the panel untitled: \(unread.count) reads")
        let bonusReads = result.readings.filter { $0["stage"] as? String == "bonus" }.map(time)
        let first = try #require(bonusReads.first, "the Bonus panel was never read")
        #expect(first - 1.5 <= 0.2 + 0.02, "first Bonus read \(first - 1.5) s after it came")
        #expect(result.drops.count == 1)
        #expect(items(result.drops.first, .bonus) == ["Power Cube ×1", "Resonator ×1", "XMP Burster ×1"],
                "\(items(result.drops.first, .bonus))")
        #expect(items(result.drops.first, .portal).isEmpty, "nothing of the untitled panel is stored")
    }

    @Test("Low Power Mode: a Chinese-only portal title is recovered; the logs hold pass counts, confidences and both power triggers, no text",
          arguments: ["測試用傳送門"])
    func constrainedTitleAndLog(_ title: String) throws {
        let panel = try pixelBuffer(try retitled(title))
        let map = try pixelBuffer(try blank(like: try image("five-base")))
        let result = try run([(panel, 1.0), (map, 0.5)], lowPower: true)
        // Read as a portal panel and kept, as without Low Power Mode.
        #expect(result.drops.count == 1)
        #expect(items(result.drops.first, .portal) == ["Resonator ×1", "Turret ×1"], "\(result.readings.count) reads")
        #expect(result.readings.contains { $0["stage"] as? String == "portal" })
        // Every read logs each OCR pass, with counts and confidences only.
        let keys: Set<String> = ["purpose", "languages", "lines", "titleLines", "titleConfidences", "milliseconds"]
        #expect(!result.readings.isEmpty)
        for row in result.readings {
            let passes = try #require(row["passes"] as? [[String: Any]], "a reading without its passes")
            #expect(passes.first?["purpose"] as? String == "panel")
            for pass in passes {
                #expect(Set(pass.keys) == keys)
                #expect(pass["lines"] as? Int != nil && pass["titleLines"] as? Int != nil
                        && pass["milliseconds"] as? Double != nil)
                #expect((pass["titleConfidences"] as? [Double])?.count == pass["titleLines"] as? Int)
                #expect((pass["languages"] as? [String])?.isEmpty == false)
            }
        }
        // The two power triggers apart, on every read and every analysed frame.
        #expect(result.readings.allSatisfy {
            $0["lowPowerMode"] as? Bool == true && $0["thermalState"] as? String == "nominal"
                && $0["powerConstrained"] as? Bool == true
        })
        let frames = try String(contentsOf: result.directory.url.appendingPathComponent("recognition.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(!frames.isEmpty && frames.allSatisfy {
            $0["lowPowerMode"] as? Bool == true && $0["thermalState"] as? String == "nominal"
        })
        let titlePasses = result.readings.flatMap { ($0["passes"] as? [[String: Any]]) ?? [] }
            .filter { $0["purpose"] as? String == "title" }
        #expect(!titlePasses.isEmpty, "the title-recovery pass is logged")
        #expect(titlePasses.allSatisfy { ($0["languages"] as? [String])?.isEmpty == false })
        // No recognized text in any session log: not the title, nor any of its characters.
        let files = try FileManager.default.contentsOfDirectory(at: result.directory.url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(title), "\(file.lastPathComponent)")
            #expect(!title.contains { text.contains($0) }, "\(file.lastPathComponent)")
            #expect(!text.contains("\"text\""), "\(file.lastPathComponent)")
        }
    }
}
