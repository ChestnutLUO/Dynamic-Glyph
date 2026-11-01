import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionImages

/// Constrained capture (Low Power Mode, a hot phone) halves the shared lane's
/// pace. A gear panel that a read has found keeps the normal 0.2-s pace until
/// its rows are confirmed or it leaves: at 0.4 s a portal panel tapped on in
/// under a second got one read, and its rows need two (2026-10-27 reports,
/// hacks 6 and 10). A confirmed panel goes back to the slow pace, so Low Power
/// Mode still about halves the reads of a panel left on screen.
@Suite("Gear panel pace on the shared lane", .serialized)
struct GearPanelLaneTests {
    private let session = CaptureSessionID(rawValue: 1)
    private let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.42)

    private func image() throws -> CGImage {
        let width = 64, height = 200
        let pixels = [UInt8](repeating: 20, count: width * height * 3)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func settle(_ reader: GameHeaderReader) async throws {
        for _ in 0..<300 {
            if !reader.isReading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("OCR lane did not finish")
    }

    /// Frames every 0.1 s, about the constrained analysis pace; each read
    /// finishes before the next frame. Returns the times of the gear reads.
    private func run(constrained: Bool, panel: @escaping @Sendable (Double) -> GearDropStage?,
                     settled: (Double) -> Bool = { _ in false }, until end: Double) async throws -> [Double] {
        let reader = GameHeaderReader(
            headerOperation: { _, time in HeaderReading(phase: .unknown, matchedText: "", confidence: 0, sourceTime: time) },
            gearOperation: { _, bounds, time in
                GearDropFrameEvidence(sourceTime: time, stage: panel(time) ?? .unknown, bounds: bounds)
            })
        let frame = try image()
        var reads: [Double] = []
        var step = 0
        while Double(step) * 0.1 <= end + 1e-9 {
            let time = Double(step) * 0.1
            let shown = panel(time) != nil
            reader.submit(frame, at: time, session: session, gearBounds: shown ? bounds : nil,
                          readsHeader: false, constrained: constrained, gearPanelSettled: settled(time),
                          inHack: false)
            try await settle(reader)
            if let read = reader.takeGear() { reads.append(read.evidence.sourceTime) }
            step += 1
        }
        return reads
    }

    @Test("Constrained, a found panel is read every 0.2 s; after it leaves the next one starts at 0.4 s")
    func constrainedPanelPace() async throws {
        // A portal panel 0–0.6 s, its Bonus panel 0.6–1.2 s, nothing, then a
        // panel no read finds a title on, 1.6–3 s.
        let reads = try await run(constrained: true, panel: { time in
            time < 0.6 - 1e-9 ? .portal : time < 1.2 - 1e-9 ? .bonus : time >= 1.6 - 1e-9 ? .unknown : nil
        }, until: 3)
        let onPanels = reads.filter { $0 < 1.2 - 1e-9 }
        #expect(onPanels.map { ($0 * 10).rounded() } == [0, 2, 4, 6, 8, 10], "\(reads)")
        let unfound = reads.filter { $0 >= 1.6 - 1e-9 }
        #expect(unfound.count >= 2)
        #expect(zip(unfound.dropFirst(), unfound).allSatisfy { $0 - $1 >= 0.4 - 0.002 }, "\(unfound)")
    }

    @Test("Constrained, a panel whose rows are confirmed goes back to a read every 0.4 s")
    func settledPanel() async throws {
        // Confirmed after the reads at 0 and 0.2 s, as the tracker reports it
        // once the second read is in.
        let reads = try await run(constrained: true, panel: { $0 < 2 - 1e-9 ? .portal : nil },
                                  settled: { $0 >= 0.3 - 1e-9 }, until: 2)
        #expect(reads.map { ($0 * 10).rounded() } == [0, 2, 6, 10, 14, 18], "\(reads)")
    }

    @Test("Unconstrained, panel reads stay every 0.2 s")
    func normalPace() async throws {
        let reads = try await run(constrained: false, panel: { $0 < 1.2 - 1e-9 ? .portal : nil }, until: 1.5)
        #expect(reads.map { ($0 * 10).rounded() } == [0, 2, 4, 6, 8, 10], "\(reads)")
    }

    // MARK: - Through the capture output, with a recorded panel

    private final class Drops: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GearDrop] = []
        func append(_ drop: GearDrop) { lock.withLock { stored.append(drop) } }
        var values: [GearDrop] { lock.withLock { stored } }
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

    private func blank(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
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

    @Test("Low Power Mode: a portal panel tapped away after 0.35 s still gets two reads and keeps its items")
    func shortPanelInLowPowerMode() throws {
        try TestFixtures.requireScreenshots()
        let url = try #require(Bundle(for: GearPanelLaneBundleMarker.self).url(forResource: "five-base", withExtension: "png"))
        let panelImage = try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)))
        let panel = try pixelBuffer(panelImage)
        let map = try pixelBuffer(try blank(width: panelImage.width, height: panelImage.height))
        let drops = Drops()
        let output = try LiveGlyphOutput(table: nil, sequenceTable: nil, sessionID: session, directory: nil,
            readsResults: false, power: PowerConditions(center: NotificationCenter(), read: { .init(lowPowerMode: true) }),
            powerSaving: true, telemetry: { _ in }, deliverResult: { _ in },
            deliverDrop: { drops.append($0) }) { _ in }
        defer { output.close() }
        // 60 Hz: the panel for 0.35 s, then the map for a second.
        for index in 0..<81 {
            let time = Double(index) / 60
            output.process(CapturedFrame(sampleBuffer: try sample(time < 0.35 ? panel : map, at: time),
                                         metadata: CaptureFrameMetadata(status: .complete), arrivalUptime: 0, deliveryGapMilliseconds: nil,
                                         continuityBroken: false))
            let deadline = Date().addingTimeInterval(20)
            while output.isReadingText && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        #expect(output.textReadMetrics.gearSubmitted >= 2)
        let drop = try #require(drops.values.first, "no drop: the panel's rows were not confirmed")
        let items = drop.summary.panels.flatMap(\.entries).map { "\($0.item ?? "?") ×\($0.quantity)" }
        #expect(items.sorted() == ["Resonator ×1", "Turret ×1"])
        #expect(drops.values.count == 1)
    }
}

private final class GearPanelLaneBundleMarker: NSObject {}
