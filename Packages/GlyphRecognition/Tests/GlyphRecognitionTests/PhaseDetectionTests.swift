import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import Vision
import GlyphRecognitionImages
@testable import GlyphRecognition

/// Runs the real text recognizer over real captured screens.
///
/// The phrase matching is tested on its own elsewhere; this is the part that
/// can only be checked against pixels — whether the measured header crop
/// actually contains the text, and whether a busy unrelated screen is refused
/// instead of being forced into a phase.
///
/// Swift Testing will not accept `@available` on a suite, so each test narrows
/// availability itself. Text recognition needs macOS 15; the recognition core
/// still supports older systems and the package's declared minimum is left as
/// it was. The repository's own toolchain requires far newer than that, so in
/// practice these always run.
@Suite("Phase detection on captured screens")
struct PhaseDetectionTests {
    private func image(_ path: String) throws -> CGImage {
        let url = try ReferenceData.fixturesDirectory.appendingPathComponent(path)
        guard let image = ImageDecoder.cgImage(from: try Data(contentsOf: url)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }

    @Test("Each captured screen is named by its own header text")
    func fieldScreens() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let recognizer = HeaderTextRecognizer()
        let expected: [(String, GamePhase)] = [
            ("Phases/field-00381.png", .command),
            ("Phases/field-00443.png", .presenting),
            ("Phases/field-00456.png", .presenting),
            ("Phases/field-00472.png", .presenting),
            ("Phases/field-00492.png", .input),
            ("Phases/field-00615.png", .completed)
        ]
        for (file, phase) in expected {
            let reading = try await recognizer.read(image(file), sourceTime: 1)
            #expect(reading.phase == phase, "\(file) read as \(reading.phase) (\(reading.matchedText))")
            #expect(reading.sourceTime == 1)
        }
    }

    @Test("The redacted map is left unknown rather than forced into a phase")
    func mapScreenIsUnknown() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let recognizer = HeaderTextRecognizer()
        // Privacy masking removed the portal title. This checks only the
        // remaining pixels; unrelated readable text is tested separately below.
        let reading = try await recognizer.read(image("Phases/field-00666.png"), sourceTime: 1)
        #expect(reading.phase == .unknown, "read as \(reading.phase) (\(reading.matchedText))")
    }

    @Test("Readable unrelated header pixels are refused even when OCR succeeds")
    func unrelatedReadableText() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        // Owned synthetic text, placed explicitly in pixels, independent of
        // the production crop fractions. No private capture content is used.
        let context = try #require(CGContext(data: nil, width: 603, height: 1311,
            bitsPerComponent: 8, bytesPerRow: 603,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 603, height: 1311))
        context.translateBy(x: 0, y: 1311)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: 145, y: 116)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "GARDEN EXHIBIT", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName("Helvetica" as CFString, 30, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 1, alpha: 1)
            ]))
        CTLineDraw(line, context)
        let frame = try #require(context.makeImage())
        let recognizer = HeaderTextRecognizer()
        let crop = try #require(recognizer.headerCrop(of: frame))
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        let observations = try await request.perform(on: crop)
        let text = observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").uppercased()
        #expect(text == "GARDEN EXHIBIT", "The negative must contain readable text, not an empty crop")
        let reading = try await recognizer.read(frame, sourceTime: 1)
        #expect(reading.phase == .unknown)
    }

    @Test("A crop with no header text at all is unknown, not a guess")
    func absentText() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let recognizer = HeaderTextRecognizer()
        // The array region of a presentation frame: real pixels, real Glyph,
        // no header. Reading a phase out of this would mean the region
        // measurements had drifted onto the wrong part of the screen.
        let frame = try image("Phases/field-00443.png")
        let middle = try #require(frame.cropping(to: CGRect(x: 0, y: Double(frame.height) * 0.35,
                                                            width: Double(frame.width),
                                                            height: Double(frame.height) * 0.1)))
        let reading = try await recognizer.read(middle, sourceTime: 1)
        #expect(reading.phase == .unknown)
    }

    @Test("The header crop stops short of the slot indicators")
    func cropExcludesIndicators() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let recognizer = HeaderTextRecognizer()
        let frame = try image("Phases/field-00443.png")
        let crop = try #require(recognizer.headerCrop(of: frame))
        // Indicator glow starts at 0.107 of the frame height; the crop must end
        // before it, or hexagons would be offered to the text recognizer.
        #expect(Double(crop.height) + recognizer.layout.headerTextTop * Double(frame.height)
                <= 0.107 * Double(frame.height))
        #expect(crop.height > 30)
    }
}
