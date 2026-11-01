import CoreGraphics
import Foundation
import Testing
import GlyphRecognition
@testable import GlyphRecognitionImages

/// Serialized: many synchronous Vision text requests at once never return on
/// the parallel test runner. The time limit turns any such hang into a failure.
@Suite("Recorded conclusion screens", .serialized, .timeLimit(.minutes(2)))
struct ResultScreenReaderTests {
    func image(_ name: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("Results/\(name).png"))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    @Test("A deliberate STRONG error is magenta, final bonuses 40/0; PiP hides the upper row")
    func errorCapture() throws {
        let frame = try image("five-final")
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1,
                                        glyphs: ["old", "nature", "less", "strong", "now"])
        #expect(ResultPanelDetector().isCandidate(try ImageDecoder.decode(frame)))
        let result = try ResultScreenReader().read(frame, context: context, sourceTime: 26.3)
        #expect(result.panelPresent && result.stageIndex == 4)
        #expect(result.hackingBonus == 40 && result.speedBonus == 0)
        #expect(result.appearances == [.gold, .gold, .gold, .magenta, .gold])
    }

    @Test("The correct four-Glyph capture reads 120/55 and four gold contours")
    func correctCapture() throws {
        let frame = try image("four-final")
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1,
                                        glyphs: ["truth", "idea", "discover", "xm"])
        let result = try ResultScreenReader().read(frame, context: context, sourceTime: 33.85)
        #expect(result.panelPresent && result.stageIndex == 3)
        #expect(result.hackingBonus == 120 && result.speedBonus == 55)
        #expect(result.appearances == [.gold, .gold, .gold, .gold])
    }

    @Test("A one-Glyph result reads 38%/96% and its gold contour; the 3 is not read as Cyrillic Ze")
    func oneGlyphCapture() throws {
        let frame = try image("one-final")
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1, glyphs: ["pure"])
        let result = try ResultScreenReader().read(frame, context: context, sourceTime: 98.0)
        #expect(result.panelPresent && result.stageIndex == 0)
        #expect(result.hackingBonus == 38 && result.speedBonus == 96)
        #expect(result.appearances == [.gold])
    }

    @Test("Only a value line with a look-alike, where no value was read, earns a second look")
    func lookAlikeTrigger() {
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1, glyphs: ["pure"])
        func line(_ text: String, y: Double) -> ResultTextLine {
            ResultTextLine(text: text, confidence: 1, x: 0.35, y: y, width: 0.3, height: 0.05)
        }
        let unread = ResultFrameEvidence(context: context, sourceTime: 1, panelPresent: true)
        #expect(ResultScreenReader.hasLookAlike([line("З8%", y: 0.38)], evidence: unread))
        #expect(ResultScreenReader.hasLookAlike([line("9б%", y: 0.54)], evidence: unread))
        #expect(!ResultScreenReader.hasLookAlike([line("...", y: 0.38)], evidence: unread), "Loading dots are no value yet")
        #expect(!ResultScreenReader.hasLookAlike([line("З8%", y: 0.70)], evidence: unread), "Outside both value bands")
        let read = ResultFrameEvidence(context: context, sourceTime: 1, panelPresent: true, hackingBonus: 38, speedBonus: 96)
        #expect(!ResultScreenReader.hasLookAlike([line("З8%", y: 0.38)], evidence: read))
    }

    @Test("Three Glyphs sit closer than even thirds; both outer contours still read gold")
    func threeGlyphCapture() throws {
        let frame = try image("three-final")
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1,
                                        glyphs: ["capture", "shapers", "portal"])
        #expect(try ResultScreenReader().appearances(in: frame, count: 3) == [.gold, .gold, .gold])
        let result = try ResultScreenReader(language: .simplifiedChinese).read(frame, context: context, sourceTime: 1)
        #expect(result.panelPresent && result.hackingBonus == 86 && result.speedBonus == 79)
        #expect(result.appearances == [.gold, .gold, .gold])
    }

    @Test("Hexagon centres follow the game's spacing for each Glyph count")
    func slotCenters() {
        #expect(ResultScreenReader.slotCenters(count: 1) == [0.5])
        for (count, measured) in [3: [0.207, 0.498, 0.791], 4: [0.129, 0.376, 0.621, 0.867],
                                  5: [0.1, 0.3, 0.5, 0.7, 0.9]] {
            let centers = ResultScreenReader.slotCenters(count: count)
            #expect(centers.count == count)
            #expect(zip(centers, measured).allSatisfy { abs($0 - $1) < 0.01 }, "\(count): \(centers)")
        }
    }

    @Test("Label-only detection never turns missing numbers into zero or outcomes")
    func labels() throws {
        let frame = try image("labels")
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1,
                                        glyphs: ["old", "nature", "less", "strong", "now"])
        let result = try ResultScreenReader().read(frame, context: context, sourceTime: 24.1)
        #expect(result.panelPresent)
        #expect(result.hackingBonus == nil && result.speedBonus == nil && result.stageIndex == nil)
        #expect(result.appearances.allSatisfy { $0 == .unreadable })
    }

    @Test("A covered row allows bonus reading without invented slot outcomes")
    func coveredRow() throws {
        let frame = try image("five-final")
        let canvas = try #require(CGContext(data: nil, width: frame.width, height: frame.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: Double(frame.height) * 0.76,
                           width: Double(frame.width), height: Double(frame.height) * 0.24))
        let covered = try #require(canvas.makeImage())
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1,
                                        glyphs: ["old", "nature", "less", "strong", "now"])
        let result = try ResultScreenReader().read(covered, context: context, sourceTime: 26.3)
        #expect(result.hackingBonus == 40 && result.speedBonus == 0)
        #expect(result.stageIndex == nil && result.appearances.allSatisfy { $0 == .unreadable })
    }
    @Test("Presentation, input, and portal screens cannot establish conclusion fields")
    func otherScreens() throws {
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1, glyphs: ["xm"])
        for name in ["field-00381", "field-00443", "field-00492", "field-00666"] {
            let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("Phases/\(name).png"))
            let frame = try #require(ImageDecoder.cgImage(from: data))
            let result = try ResultScreenReader().read(frame, context: context, sourceTime: 1)
            #expect(!result.panelPresent && result.hackingBonus == nil && result.appearances.isEmpty)
        }
    }

}
