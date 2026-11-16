import CoreGraphics
import CoreVideo
import Foundation
import Testing
import GlyphRecognition
import GlyphRecognitionCxx
import GlyphRecognitionImages

/// The `planeGate` cut skips a region render only where `RegionGate` says
/// the planes certainly hold nothing for the region's detector. These hold
/// that to the detectors on the rendered pixels, as the capture would
/// render them, in the three formats it delivers: every footer the probe
/// takes as a candidate passes the gate, and every band the gate calls
/// empty is one the band detector sees no grey level above 45 in.
@Suite("Plane gate: a superset of the footer and band detectors")
struct RegionGateTests {
    /// The capture's planes, locked for reading around `body`.
    static func withPlanes<Result>(_ pixels: CVPixelBuffer, _ body: (FramePlanes) throws -> Result) throws -> Result {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else {
            throw RegionRenderTests.Failure(description: "could not lock the buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let planes: FramePlanes
        switch CVPixelBufferGetPixelFormatType(pixels) {
        case kCVPixelFormatType_32BGRA:
            planes = FramePlanes(format: .bgra, width: CVPixelBufferGetWidth(pixels),
                                 height: CVPixelBufferGetHeight(pixels),
                                 base: UnsafeRawPointer(try #require(CVPixelBufferGetBaseAddress(pixels))),
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))
        case let format:
            planes = FramePlanes(format: .nv12(videoRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                 width: CVPixelBufferGetWidthOfPlane(pixels, 0),
                                 height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                                 base: UnsafeRawPointer(try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))),
                                 bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0),
                                 chroma: CVPixelBufferGetBaseAddressOfPlane(pixels, 1).map(UnsafeRawPointer.init),
                                 chromaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1))
        }
        return try body(planes)
    }

    /// One frame through both gates and both detectors.
    struct Observation {
        let footerCandidate: Bool
        let footerPasses: Bool
        /// Yellow under the gate's thresholds, the gate's floor and the
        /// probe's: a candidate needs more than the probe's floor of its own
        /// yellow, the gate more than its floor of this count.
        let gateYellow: Int, gateFloor: Int, probeFloor: Int
        let bandEmpty: Bool
        let bandPlaneLuma: Int
        /// The brightest grey the band detector gets from the rendered band.
        let bandGrey: Int
    }

    static func observe(_ pixels: CVPixelBuffer) throws -> Observation {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let footerRect = DroneFooterProbe.textRect(width: width, height: height)
        let bandRect = CommandNoticeDetector.band(width: width, height: height)
        let footer = try RegionRenderTests.renderRegion(pixels, footerRect)
        let candidate = DroneFooterProbe.candidate(try DroneFooterProbe.textPixels(region: footer, frameWidth: width,
                                                                                   frameHeight: height))
        let band = try ImageDecoder.decode(try RegionRenderTests.renderRegion(pixels, bandRect))
        return try withPlanes(pixels) { planes in
            Observation(footerCandidate: candidate != nil, footerPasses: RegionGate.footerMayHoldCandidate(planes),
                        gateYellow: try #require(RegionGate.yellowCount(planes, in: footerRect)),
                        gateFloor: RegionGate.footerYellowFloor(regionWidth: Int(footerRect.width)),
                        probeFloor: Int(footerRect.width) * 5 / 9,
                        bandEmpty: RegionGate.bandIsEmpty(planes),
                        bandPlaneLuma: try #require(RegionGate.maxLuma(planes, in: bandRect)),
                        bandGrey: Int(band.pixels.max() ?? 0))
        }
    }

    /// What a set of frames showed of both gates.
    struct Tally: CustomStringConvertible {
        var frames = 0, candidates = 0, footerGated = 0, bandsEmpty = 0
        /// The smallest gate count of a candidate over the gate's floor.
        var leastCandidateRatio = Double.infinity
        /// The brightest band grey among bands called empty (at most 45),
        /// and the dimmest plane luma among bands with a grey above 45 (above
        /// `RegionGate.emptyBandLuma`).
        var brightestEmptyGrey = 0, dimmestLitPlaneLuma = Int.max
        var failures: [String] = []

        mutating func add(_ observation: Observation, _ context: String) {
            frames += 1
            if observation.footerCandidate {
                candidates += 1
                leastCandidateRatio = min(leastCandidateRatio,
                                          Double(observation.gateYellow) / Double(max(1, observation.gateFloor)))
                if !observation.footerPasses { failures.append("\(context): footer candidate gated") }
            }
            if !observation.footerPasses { footerGated += 1 }
            if observation.bandEmpty {
                bandsEmpty += 1
                brightestEmptyGrey = max(brightestEmptyGrey, observation.bandGrey)
                if observation.bandGrey > 45 { failures.append("\(context): band grey \(observation.bandGrey) gated") }
            }
            if observation.bandGrey > 45 { dimmestLitPlaneLuma = min(dimmestLitPlaneLuma, observation.bandPlaneLuma) }
        }

        var description: String {
            "\(frames) frames: \(candidates) footer candidates, least gate yellow \(leastCandidateRatio)x its floor; "
                + "footer gated \(footerGated); band empty \(bandsEmpty), brightest grey there \(brightestEmptyGrey), "
                + "dimmest plane luma of a lit band \(dimmestLitPlaneLuma)"
        }
    }

    /// Every full-screen fixture: the folders of frames, not of crops.
    static func fixtureFrames() throws -> [String] {
        let root = try ReferenceData.fixturesDirectory
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        return try folders.filter { $0 != "Commands" }.flatMap { folder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path))
                ?? []
            return try names.filter { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") }.sorted().compactMap { name -> String? in
                let image = try RegionRenderTests.image("\(folder)/\(name)")
                return image.height > image.width ? "\(folder)/\(name)" : nil
            }
        }
    }

    /// A recorded command band drawn into its rectangle of an otherwise
    /// black frame.
    static func bandFrame(_ name: String, width: Int, height: Int) throws -> CGImage {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures/Commands"))
        let band = try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rect = CommandNoticeDetector.band(width: width, height: height)
        context.draw(band, in: CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width,
                                      height: rect.height))
        return try #require(context.makeImage())
    }

    @Test("Every footer candidate passes the gate and every band it calls empty is dark, in every fixture frame, format and attachment set, at its own size and a phone's")
    func supersetOverFixtures() throws {
        var phases = Tally(), commands = Tally(), all = Tally()
        for path in try Self.fixtureFrames() {
            let source = try RegionRenderTests.image(path)
            for size in [(source.width, source.height), (1206, 2622)] {
                for (format, name, attachments) in RegionRenderTests.buffers {
                    let pixels = try RegionRenderTests.pixelBuffer(source, width: size.0, height: size.1,
                                                                   format: format, attachments: attachments)
                    let context = "\(path) \(size.0)x\(size.1) \(name)"
                    let observation = try Self.observe(pixels)
                    all.add(observation, context)
                    if path.hasPrefix("Phases/") { phases.add(observation, context) }
                }
            }
        }
        let bands = try FileManager.default.contentsOfDirectory(
            atPath: ReferenceData.fixturesDirectory.appendingPathComponent("Commands").path)
            .filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }.sorted()
        for band in bands {
            let source = try Self.bandFrame(band, width: 602, height: 1310)
            for (format, name, attachments) in RegionRenderTests.buffers {
                let pixels = try RegionRenderTests.pixelBuffer(source, width: 602, height: 1310, format: format,
                                                               attachments: attachments)
                let observation = try Self.observe(pixels)
                commands.add(observation, "Commands/\(band) \(name)")
                all.add(observation, "Commands/\(band) \(name)")
            }
        }
        #expect(all.failures.isEmpty, "\(all.failures)")
        #expect(all.candidates > 0 && all.bandsEmpty > 0 && all.footerGated > 0,
                "the fixtures must exercise both gates both ways: \(all)")
        print("RegionGateTests: all \(all)")
        print("RegionGateTests: Phases \(phases)")
        print("RegionGateTests: Commands \(commands)")
    }

    @Test("A dark screen is gated in every format; a band lit to grey 60 and a footer line of yellow above the gate's floor are not")
    func floors() throws {
        func frame(band: UInt8, footerYellow: Int) throws -> CGImage {
            let width = 602, height = 1310
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let bandRect = CommandNoticeDetector.band(width: width, height: height)
            context.setFillColor(CGColor(gray: Double(band) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: Double(height) - bandRect.maxY, width: bandRect.width, height: bandRect.height))
            // One row of saturated yellow, centred in the label: too little
            // for the probe, more than the gate's floor.
            let label = DroneFooterProbe.textRect(width: width, height: height)
            context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1))
            context.fill(CGRect(x: (label.midX - Double(footerYellow) / 2).rounded(),
                                y: (Double(height) - label.midY).rounded(), width: Double(footerYellow), height: 1))
            return try #require(context.makeImage())
        }
        let dark = try frame(band: 0, footerYellow: 0)
        let lit = try frame(band: 60, footerYellow: 0)
        let label = DroneFooterProbe.textRect(width: 602, height: 1310)
        let floor = RegionGate.footerYellowFloor(regionWidth: Int(label.width))
        let faint = try frame(band: 0, footerYellow: floor + 40)
        for (format, name, attachments) in RegionRenderTests.buffers {
            func observe(_ image: CGImage) throws -> Observation {
                try Self.observe(try RegionRenderTests.pixelBuffer(image, width: 602, height: 1310, format: format,
                                                                   attachments: attachments))
            }
            let darkSeen = try observe(dark)
            #expect(darkSeen.bandEmpty && !darkSeen.footerPasses && darkSeen.bandGrey <= 45, "\(name): \(darkSeen)")
            let litSeen = try observe(lit)
            #expect(!litSeen.bandEmpty && litSeen.bandGrey > 45, "\(name): \(litSeen)")
            let faintSeen = try observe(faint)
            #expect(faintSeen.footerPasses && !faintSeen.footerCandidate, "\(name): \(faintSeen)")
        }
    }

    @Test("The plane scans count and clip as documented, and answer nil for planes they cannot read")
    func scans() throws {
        let width = 8, height = 4
        var luma = [UInt8](repeating: 16, count: width * height)
        var chroma = [UInt8](repeating: 128, count: width * height / 2)
        // Row 1: Y 71 with Cb 119 is yellow; Y 70 or Cb 120 is not.
        luma[1 * width + 0] = 71; luma[1 * width + 1] = 71; chroma[0] = 119
        luma[1 * width + 2] = 70; luma[1 * width + 3] = 71; chroma[2] = 119
        luma[1 * width + 4] = 71; chroma[4] = 120
        luma[3 * width + 7] = 235
        try luma.withUnsafeBytes { lumaBytes in
            try chroma.withUnsafeBytes { chromaBytes in
                let base = try #require(lumaBytes.baseAddress)
                func planes(videoRange: Bool, chroma: UnsafeRawPointer?) -> FramePlanes {
                    FramePlanes(format: .nv12(videoRange: videoRange), width: width, height: height,
                                base: base, bytesPerRow: width, chroma: chroma,
                                chromaBytesPerRow: chroma == nil ? 0 : width)
                }
                let video = planes(videoRange: true, chroma: chromaBytes.baseAddress)
                let full = planes(videoRange: false, chroma: chromaBytes.baseAddress)
                #expect(RegionGate.yellowCount(video, in: CGRect(x: 0, y: 0, width: width, height: height)) == 3)
                #expect(RegionGate.yellowCount(video, in: CGRect(x: 1, y: 1, width: 2, height: 1)) == 1)
                #expect(RegionGate.yellowCount(video, in: CGRect(x: -4, y: -4, width: 100, height: 100)) == 3)
                #expect(RegionGate.yellowCount(video, in: CGRect(x: 8, y: 0, width: 4, height: 4)) == nil)
                #expect(RegionGate.maxLuma(video, in: CGRect(x: 0, y: 0, width: width, height: height)) == 255)
                #expect(RegionGate.maxLuma(full, in: CGRect(x: 0, y: 0, width: width, height: height)) == 235)
                #expect(RegionGate.maxLuma(video, in: CGRect(x: 0, y: 2, width: width, height: 1)) == 0)
                #expect(RegionGate.maxLuma(video, in: CGRect(x: 0, y: 0, width: width, height: 0)) == nil)
                let noChroma = planes(videoRange: false, chroma: nil)
                #expect(RegionGate.yellowCount(noChroma, in: CGRect(x: 0, y: 0, width: width, height: height)) == nil)
                #expect(RegionGate.footerMayHoldCandidate(noChroma), "unreadable planes are rendered")
            }
        }
        // BGRA: R > 110, G > 80, 5 B < 4 G; luma as the gate reads it.
        let pixels: [UInt8] = [0, 81, 111, 255, 64, 80, 111, 255, 65, 81, 111, 255, 64, 81, 110, 255,
                               255, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]
        try pixels.withUnsafeBytes { bytes in
            let base = try #require(bytes.baseAddress)
            let bgra = FramePlanes(format: .bgra, width: 4, height: 2, base: base, bytesPerRow: 16)
            #expect(RegionGate.yellowCount(bgra, in: CGRect(x: 0, y: 0, width: 4, height: 2)) == 1)
            #expect(RegionGate.maxLuma(bgra, in: CGRect(x: 0, y: 0, width: 4, height: 2)) == 255)
            #expect(RegionGate.maxLuma(bgra, in: CGRect(x: 1, y: 1, width: 3, height: 1)) == 0)
            let short = FramePlanes(format: .bgra, width: 4, height: 2, base: base, bytesPerRow: 8)
            #expect(RegionGate.maxLuma(short, in: CGRect(x: 0, y: 0, width: 4, height: 2)) == nil)
            #expect(!RegionGate.bandIsEmpty(short), "unreadable planes are rendered")
        }
    }
}
