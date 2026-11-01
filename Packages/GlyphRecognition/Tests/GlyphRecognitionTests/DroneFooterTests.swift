import Foundation
import CoreGraphics
import CoreText
import Testing
import GlyphRecognition
@testable import GlyphRecognitionImages

/// The drone footer probe on the field run's real drone frame
/// (`Phases/field-00666.png`, "DRONE FOOTAGE" at the bottom). Pixels first:
/// what is a candidate, what is cut for the read, what is skipped. The text
/// reads are in the serialized suite below.
@Suite("Drone footer probe")
struct DroneFooterProbeTests {
    static func fixture(_ path: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent(path))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    static func drone() throws -> CGImage { try fixture("Phases/field-00666.png") }

    static func candidate(_ image: CGImage) throws -> DroneFooterProbe.Candidate? {
        let rect = DroneFooterProbe.textRect(width: image.width, height: image.height)
        return DroneFooterProbe.candidate(try ImageDecoder.decodeColor(image, in: rect))
    }

    /// `base` with `bottom`'s lowest 8% drawn over its own.
    static func compose(_ base: CGImage, bottom: CGImage) throws -> CGImage {
        let canvas = try #require(CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        canvas.draw(base, in: full)
        // Core Graphics' origin is the bottom left.
        canvas.clip(to: CGRect(x: 0, y: 0, width: Double(base.width), height: Double(base.height) * 0.08))
        canvas.draw(bottom, in: full)
        return try #require(canvas.makeImage())
    }

    /// A strip like the drone footer's, with `draw` painting into its
    /// label region (bottom-left origin) on a dark background.
    static func strip(width: Int = 603, height: Int = 1311,
                      _ draw: (CGContext, CGRect) -> Void) throws -> CGImage {
        let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(red: 0.12, green: 0.06, blue: 0.16, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let label = CGRect(x: 0, y: Double(height) * 0.01, width: Double(width), height: Double(height) * 0.045)
        draw(canvas, label)
        return try #require(canvas.makeImage())
    }

    static let yellow = CGColor(red: 0.98, green: 0.85, blue: 0.40, alpha: 1)

    @Test("The real drone frame is a candidate, and its read is the label's small crop")
    func realDroneFrame() throws {
        let frame = try Self.drone()
        let candidate = try #require(try Self.candidate(frame))
        #expect(candidate.yellow > 500)
        let capture = CommandNoticeCapture()
        #expect(try capture.observeMode(in: frame, at: 1))
        #expect(capture.modeReads == 1)
        let queued = try #require(capture.take(at: 1))
        #expect(queued.isMode && queued.signature == candidate.signature)
        // 60% of the width and 4.5% of the height: 363×60 of a 603×1311
        // frame, where the old crop was the strip's full 603 columns.
        #expect(queued.image.width == 363 && queued.image.height == 60)
        // A full-resolution frame's crop is scaled down to the same rows.
        let rect = DroneFooterProbe.textRect(width: 1206, height: 2622)
        #expect(rect.height > 64)
        let large = try #require(CGContext(data: nil, width: 1206, height: 2622, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        large.draw(frame, in: CGRect(x: 0, y: 0, width: 1206, height: 2622))
        let scaled = try #require(large.makeImage())
        #expect(try Self.candidate(scaled) != nil)
        let crop = try #require(DroneFooterProbe.readCrop(scaled))
        #expect(crop.height == DroneFooterProbe.maximumReadHeight)
        let expectedWidth = (rect.width * Double(DroneFooterProbe.maximumReadHeight) / rect.height).rounded()
        #expect(abs(Double(crop.width) - expectedWidth) <= 1)
    }

    @Test("While an item panel shows, a drone footer under it is not read")
    func gearPanelSkipsTheProbe() throws {
        let panel = try Self.fixture("Gear/multiplied-bonus.png")
        // The masked panel alone has no footer at all.
        #expect(try Self.candidate(panel) == nil)
        // The same panel over the drone view's footer: the panel is found,
        // and the footer would be a candidate.
        let frame = try Self.compose(panel, bottom: Self.drone())
        #expect(try GearDropScreenReader().bounds(in: frame) != nil)
        #expect(try Self.candidate(frame) != nil)
        let capture = CommandNoticeCapture()
        #expect(try !capture.observeMode(in: frame, at: 1, panelShowing: true))
        #expect(try !capture.observeMode(in: frame, at: 2.5, panelShowing: true))
        #expect(capture.queue.isEmpty && capture.modeCandidates == 0)
        // Once the panel is gone the next look reads the footer at once.
        #expect(try capture.observeMode(in: frame, at: 3, panelShowing: false))
        #expect(capture.queue.count == 1 && capture.modeReads == 1)
    }

    @Test("Other recorded screens are not drone candidates", arguments: [
        "Phases/field-00381.png", "Phases/field-00443.png", "Phases/field-00492.png", "Phases/field-00615.png",
        "Recording/sample-23600.png", "Recording/sample-26300.png", "Results/three-final.png",
        "PortalLevel/portal-l8.png", "PortalLevel/map-drop-602.png", "OneGlyph/one-01868.png",
        "AssistiveTouch/touch-01903.png", "Gear/four-bonus.png", "Languages/zh-bonus.png"])
    func otherScreens(_ path: String) throws {
        let frame = try Self.fixture(path)
        #expect(try Self.candidate(frame) == nil)
        let capture = CommandNoticeCapture()
        #expect(try !capture.observeMode(in: frame, at: 1))
        #expect(capture.queue.isEmpty)
    }

    @Test("A solid yellow bar, a corner's colour or a few yellow pixels are not a label")
    func yellowThatIsNotALabel() throws {
        let bar = try Self.strip { context, label in
            context.setFillColor(Self.yellow)
            context.fill(label.insetBy(dx: 40, dy: 10))
        }
        #expect(try Self.candidate(bar) == nil)
        let corner = try Self.strip { context, label in
            context.setFillColor(Self.yellow)
            // Plenty of yellow, but at the left of the region.
            for index in 0..<8 { context.fill(CGRect(x: 130 + Double(index) * 9, y: label.minY + 15, width: 4, height: 20)) }
        }
        #expect(try Self.candidate(corner) == nil)
        let sparse = try Self.strip { context, label in
            context.setFillColor(Self.yellow)
            context.fill(CGRect(x: 290, y: label.minY + 20, width: 20, height: 4))
        }
        #expect(try Self.candidate(sparse) == nil)
        // Centred letters on the tab are.
        let letters = try Self.strip { context, label in
            context.setFillColor(Self.yellow)
            for index in 0..<12 { context.fill(CGRect(x: 205 + Double(index) * 16, y: label.minY + 18, width: 5, height: 20)) }
        }
        #expect(try Self.candidate(letters) != nil)
    }

    @Test("Once a read confirms the footer, the same pixels are the drone view with no read")
    func confirmedFooterIsReused() throws {
        let frame = try Self.drone()
        let capture = CommandNoticeCapture()
        try capture.observeMode(in: frame, at: 1)
        let first = try #require(capture.take(at: 1))
        // Once a second at most, as before.
        #expect(try !capture.observeMode(in: frame, at: 1.5))
        capture.accept(.init(notice: .drone, confidence: 1, language: "en"), frame: first)
        capture.bind(hackID: 1)
        // The next hack's look: no read, yet the drone view is known when its
        // command window opens.
        #expect(try capture.observeMode(in: frame, at: 10))
        #expect(capture.queue.isEmpty && capture.modeReuses == 1 && capture.modeReads == 1)
        let band = try Self.fixture("Commands/empty.png")
        try capture.observe(band: band, at: 11)
        capture.bind(hackID: 2)
        #expect(capture.summary(hackID: 2).mode == .drone)
        #expect(capture.summary(hackID: 2).gear.status == .notApplicable)
        // Different yellow lettering is read again.
        let other = try Self.strip { context, label in
            context.setFillColor(Self.yellow)
            for index in 0..<12 { context.fill(CGRect(x: 205 + Double(index) * 16, y: label.minY + 18, width: 5, height: 20)) }
        }
        #expect(try capture.observeMode(in: other, at: 20))
        #expect(capture.queue.count == 1 && capture.modeReads == 2)
        // A footer read as something else teaches nothing.
        let unknown = CommandNoticeCapture()
        try unknown.observeMode(in: frame, at: 1)
        unknown.accept(.init(notice: nil, confidence: 0), frame: try #require(unknown.take(at: 1)))
        #expect(try unknown.observeMode(in: frame, at: 2))
        #expect(unknown.modeReads == 2 && unknown.modeReuses == 0)
    }

    @Test("Signatures match only the same footer")
    func signatures() throws {
        let real = try #require(try Self.candidate(try Self.drone()))
        #expect(DroneFooterProbe.matches(real.signature, real.signature))
        var shifted = real.signature
        for index in 0..<DroneFooterProbe.signatureTolerance { shifted[index] ^= 1 }
        #expect(DroneFooterProbe.matches(shifted, real.signature))
        shifted[DroneFooterProbe.signatureTolerance] ^= 1
        #expect(!DroneFooterProbe.matches(shifted, real.signature))
        #expect(!DroneFooterProbe.matches([], real.signature))
    }
}

/// Vision on the drone footer. Serialized, like the other Vision suites.
@Suite("Drone footer reads", .serialized, .timeLimit(.minutes(2)))
struct DroneFooterReadTests {
    /// The real frame's label replaced by `text` in the same yellow, size and
    /// place, on the tab's own colour.
    static func footer(_ text: String) throws -> CGImage {
        let frame = try DroneFooterProbeTests.drone()
        let width = Double(frame.width), height = Double(frame.height)
        let canvas = try #require(CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The English label sits in rows 1256-1273 (top-left origin) of 1311,
        // columns 201-402 of 603.
        canvas.setFillColor(CGColor(red: 0.16, green: 0.07, blue: 0.22, alpha: 1))
        canvas.fill(CGRect(x: 185, y: height - 1280, width: 233, height: 30))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): DroneFooterProbeTests.yellow]))
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        canvas.textMatrix = .identity
        canvas.textPosition = CGPoint(x: (width - lineWidth) / 2, y: height - 1274)
        CTLineDraw(line, canvas)
        return try #require(canvas.makeImage())
    }

    static func modeFrame(_ image: CGImage) throws -> CommandNoticeFrame {
        let capture = CommandNoticeCapture()
        #expect(try capture.observeMode(in: image, at: 1), "a drone footer candidate")
        return try #require(capture.take(at: 1))
    }

    @Test("The real drone frame's small crop reads as the drone footer, fast and accurate")
    func realFooter() throws {
        let frame = try Self.modeFrame(try DroneFooterProbeTests.drone())
        let reader = CommandNoticeReader(language: .english)
        #expect(try reader.read(frame).notice == .drone)
        #expect(try reader.readsDroneFooterFast(frame), "fast recognition reads DRONE FOOTAGE")
        // The capture path, with the language memory the app passes.
        let memory = GameLanguageMemory(language: .english, isAutomatic: false)
        #expect(try CommandNoticeReader.read(frame, languages: memory).notice == .drone)
    }

    @Test("Each language's footer is a candidate and reads on the small crop", arguments: [
        (GameLanguage.english, "DRONE FOOTAGE"), (.simplifiedChinese, "遥控机画面"), (.traditionalChinese, "遙控機畫面"),
        (.japanese, "ドローンの映像"), (.korean, "드론 화면")])
    func languages(_ sample: (GameLanguage, String)) throws {
        let frame = try Self.modeFrame(try Self.footer(sample.1))
        #expect(frame.image.height <= DroneFooterProbe.maximumReadHeight)
        let reading = try CommandNoticeReader(language: sample.0).read(frame)
        #expect(reading.notice == .drone, "\(sample.0.rawValue) \(sample.1)")
        #expect(reading.language == sample.0.rawValue)
    }

    @Test("The command band is still read accurately and a non-footer is not the drone view")
    func notAFooter() throws {
        let frame = try Self.modeFrame(try Self.footer("MOVE RECALL"))
        #expect(try CommandNoticeReader(language: .english).read(frame).notice == nil)
    }
}
