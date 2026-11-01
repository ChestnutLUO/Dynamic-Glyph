import CoreGraphics
import CoreText
import Foundation
import Testing
import GlyphRecognition
@testable import GlyphRecognitionImages

/// Build 102b: without retries (constrained), the one title-recovery family
/// first reads the panel crop at 2x, as 101/102; only when that pass finds no
/// single title line at 0.7 or more does one more pass in the same family read
/// the title zone with a 0.03 margin (still 2x). With retries every family
/// reads the panel crop only, as before. On a Mac, the panel crop read the CJK-only
/// portal name of 2026-10-28 hack 1 on 9 of 40 frames, the title-zone crop on
/// 40 of 40 (2026-10-29 title probe, `zone0.03`).
///
/// Serialized, and every Vision read runs on a thread of its own (`offPool`):
/// a synchronous Vision call blocks its thread for the whole request, and
/// enough of those on Swift's shared pool deadlock the Mac test run. Drawn
/// CJK names are scripted (`cjkTitle`, build 102c): Vision's score for them
/// differs by machine.
@Suite("Constrained gear title pass with a title-zone fallback", .serialized, .timeLimit(.minutes(5)))
struct GearTitlePassScaleTests {
    /// Hands a CGImage to the reading thread.
    struct Frame: @unchecked Sendable { let image: CGImage }

    /// Runs synchronous Vision work on a thread of its own and awaits it, so
    /// no pool thread waits on Vision. Expectations stay in the test body.
    func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    func fixture(_ path: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("\(path).png"))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    /// `four-base` with its title painted over in the panel's colour and
    /// owned text drawn in its place.
    func replacingTitle(in image: CGImage, with title: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 20, y: 399, width: 522, height: 44))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("PingFangTC-Regular" as CFString, 18, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.75, green: 0.70, blue: 0.95, alpha: 1)
        ]))
        context.textPosition = CGPoint(x: (562 - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: 433)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }

    static func english() -> GameLanguageMemory { GameLanguageMemory(language: .english, isAutomatic: false) }

    static func describe(_ passes: [GearReadPass]) -> String {
        passes.map { "\($0.purpose.rawValue) \($0.languages.joined(separator: "+")): \($0.lines) lines, "
            + "\($0.titleLines) title \($0.titleConfidences)" }.joined(separator: "; ")
    }

    static func items(_ evidence: GearDropFrameEvidence) -> [String] {
        evidence.entries.map { "\($0.level.map { "L\($0) " } ?? "")\($0.item ?? "?") x\($0.quantity)" }
    }

    // MARK: - (a) The fallback decision and its crop, without Vision

    static let decisionBounds = GearDropPanelBounds(top: 0.286, bottom: 0.383)
    static func line(_ confidence: Double, y: Double = 0.306) -> ResultTextLine {
        ResultTextLine(text: "Reference", confidence: confidence, x: 0.29, y: y, width: 0.42, height: 0.024)
    }

    @Test("A panel-crop title pass gets the title-zone fallback unless it found one title line at 0.7 or more")
    func fallbackDecision() {
        let bounds = Self.decisionBounds
        #expect(!GearDropScreenReader.needsTitleFallback([Self.line(1)], bounds: bounds))
        #expect(!GearDropScreenReader.needsTitleFallback([Self.line(0.7)], bounds: bounds))
        // A row line below the title zone doesn't count either way.
        #expect(!GearDropScreenReader.needsTitleFallback([Self.line(1), Self.line(0.3, y: 0.34)], bounds: bounds))
        #expect(GearDropScreenReader.needsTitleFallback([], bounds: bounds))
        #expect(GearDropScreenReader.needsTitleFallback([Self.line(0.5)], bounds: bounds))
        #expect(GearDropScreenReader.needsTitleFallback([Self.line(1), Self.line(1)], bounds: bounds))
        #expect(GearDropScreenReader.needsTitleFallback([Self.line(1, y: 0.34)], bounds: bounds))
    }

    @Test("The fallback crops the title zone with a 0.03 margin across the panel crop's width, in whole pixels")
    func fallbackRect() {
        let panel = CGRect(x: 20, y: 300, width: 523, height: 400)
        // 0.27 ... 0.375 of the height.
        #expect(GearDropScreenReader.titleZoneRect(panel, bounds: GearDropPanelBounds(top: 0.3, bottom: 0.7), imageHeight: 1000)
            == CGRect(x: 20, y: 270, width: 523, height: 105))
        // Not above the frame.
        #expect(GearDropScreenReader.titleZoneRect(panel, bounds: GearDropPanelBounds(top: 0.01, bottom: 0.5), imageHeight: 1000)
            == CGRect(x: 20, y: 0, width: 523, height: 85))
        // Not below the panel.
        #expect(GearDropScreenReader.titleZoneRect(panel, bounds: GearDropPanelBounds(top: 0.3, bottom: 0.35), imageHeight: 1000)
            == CGRect(x: 20, y: 270, width: 523, height: 80))
        let odd = GearDropScreenReader.titleZoneRect(panel, bounds: GearDropPanelBounds(top: 0.3333, bottom: 0.7), imageHeight: 1217)
        #expect(odd == odd.integral)
        #expect(odd.minY <= (0.3333 - 0.03) * 1217 && odd.maxY >= (0.3333 + 0.075) * 1217)
    }

    // MARK: - (b) CJK portal titles, constrained and unconstrained

    /// Owned CJK-only names; the English item pass doesn't read them.
    static let cjkTitles = ["測試傳送", "參考地標", "測試用傳送門", "测试传送门"]

    @Test("A CJK-only portal name is read, constrained (one family, at most two passes) and unconstrained (one pass per family)",
          arguments: cjkTitles, [false, true])
    func cjkTitle(_ title: String, retries: Bool) throws {
        // Scripted (build 102c, `GearScriptedTitleRead`): which crop and family
        // read a drawn name at 0.7 or more is up to the machine's Vision.
        // Each case reads the name both ways a family can.
        typealias Scripted = GearScriptedTitleRead
        let families = GearDropScreenReader.titleFamilies
        let expected = GearDropTextParser().read(lines: [Scripted.title("Reference", 1)] + Scripted.rows,
                                                 bounds: Scripted.bounds, at: 0)
        try #require(expected.stage == .portal && !expected.entries.isEmpty)
        // (label, script, the title passes it takes)
        typealias Script = (Scripted.Crop, [String]) -> [ResultTextLine]
        let scripts: [(String, Script, [Scripted.Pass])]
        if retries {
            scripts = [
                ("the first family reads it on the panel crop",
                 { _, languages in [Scripted.title(title, languages == families[0] ? 1 : 0.5)] },
                 [.init(crop: .panel, languages: families[0])]),
                ("the first family at 0.5 (1.0 on the title zone, never asked), the second reads it",
                 { crop, languages in [Scripted.title(title, crop == .zone || languages == families[1] ? 1 : 0.5)] },
                 [.init(crop: .panel, languages: families[0]), .init(crop: .panel, languages: families[1])]),
            ]
        } else {
            scripts = [
                ("the panel crop reads it",
                 { _, languages in [Scripted.title(title, languages == families[0] ? 1 : 0.5)] },
                 [.init(crop: .panel, languages: families[0])]),
                ("the panel crop at 0.5, the title zone reads it (2026-10-28 hack 1 on a Mac)",
                 { crop, _ in [Scripted.title(title, crop == .zone ? 1 : 0.5)] },
                 [.init(crop: .panel, languages: families[0]), .init(crop: .zone, languages: families[0])]),
            ]
        }
        for (label, script, passes) in scripts {
            let reading = try Scripted.read(panel: Scripted.rows, retries: retries, script: script)
            #expect(reading.evidence.stage == .portal, "\(label): \(reading.titlePasses)")
            #expect(reading.evidence.entries == expected.entries, "\(label)")
            #expect(reading.evidence.unreadableRows == 0, "\(label)")
            #expect(!reading.untitledPanel, "\(label)")
            let titlePasses = reading.titlePasses
            #expect(!titlePasses.isEmpty, "the title pass read it: \(label)")
            if retries {
                #expect(Set(titlePasses.map(\.languages)).count == titlePasses.count
                        && titlePasses.allSatisfy { $0.crop == .panel },
                        "no fallback with retries: \(label): \(titlePasses)")
            } else {
                #expect(titlePasses.count <= 2 && Set(titlePasses.map(\.languages)).count == 1,
                        "one family: \(label): \(titlePasses)")
            }
            #expect(titlePasses == passes, "\(label): \(titlePasses)")
        }
    }

    @Test("A painted-out title gets the fallback only without retries: two passes in one family; with retries one per family")
    func fallbackOnlyConstrained() async throws {
        let frame = Frame(image: try replacingTitle(in: fixture("Gear/four-base"), with: ""))
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame.image))
        for retries in [false, true] {
            let reading = try await offPool {
                try GearDropScreenReader.reading(frame.image, bounds: bounds, sourceTime: 1,
                    titleMemory: GearTitleLanguageMemory(), languages: Self.english(), retries: retries,
                    rereadsUnreadableRows: true)
            }
            #expect(reading.evidence.stage == .unknown && reading.evidence.entries.isEmpty)
            #expect(reading.untitledPanel, "\(Self.describe(reading.passes))")
            let families = reading.passes.filter { $0.purpose == .title }.map(\.languages)
            if retries {
                #expect(families == GearDropScreenReader.titleFamilies, "\(Self.describe(reading.passes))")
            } else {
                #expect(families == [GearDropScreenReader.titleFamilies[0], GearDropScreenReader.titleFamilies[0]],
                        "\(Self.describe(reading.passes))")
            }
        }
    }

    // MARK: - (c) Recorded panels read as their own tests expect, retries on and off

    struct Expected: Sendable, CustomTestStringConvertible {
        let path: String
        let language: GameLanguage
        let stage: GearDropStage
        /// The rows as `items`, when the fixture's test names them.
        let items: [String]?
        let count: Int
        let quantity: Int
        var testDescription: String { path }
    }

    /// Copied from `GearDropScreenReaderTests` ("Sanitized recorded
    /// panels…", "An English portal heading…") and `GameLanguageImageTests`
    /// ("A Chinese Bonus panel…", "A Japanese panel…").
    static let recorded: [Expected] = [
        Expected(path: "Gear/four-base", language: .english, stage: .portal, items: nil, count: 2, quantity: 3),
        Expected(path: "Gear/four-bonus", language: .english, stage: .bonus, items: nil, count: 5, quantity: 13),
        Expected(path: "Gear/five-base", language: .english, stage: .portal, items: nil, count: 2, quantity: 2),
        Expected(path: "Gear/five-bonus", language: .english, stage: .bonus, items: nil, count: 3, quantity: 3),
        Expected(path: "Gear/multiplied-base", language: .english, stage: .portal, items: nil, count: 1, quantity: 2),
        Expected(path: "Gear/multiplied-bonus", language: .english, stage: .bonus, items: nil, count: 5, quantity: 24),
        Expected(path: "Gear/latin-title-chinese", language: .simplifiedChinese, stage: .portal,
                 items: ["L6 XMP Burster x1", "L6 Resonator x1"], count: 2, quantity: 2),
        Expected(path: "Languages/zh-bonus", language: .simplifiedChinese, stage: .bonus,
                 items: ["L6 XMP Burster x4", "L5 XMP Burster x1", "L6 Resonator x5"], count: 3, quantity: 10),
        Expected(path: "Languages/ja-portal-cut", language: .japanese, stage: .portal,
                 items: ["Aegis Shield x1", "Portal Shield x1", "L6 XMP Burster x1", "L5 XMP Burster x2",
                         "L5 Resonator x1"], count: 5, quantity: 6)
    ]

    @Test("Recorded English, Chinese and Japanese panels read as their own tests expect, retries on and off",
          arguments: recorded, [true, false])
    func recordedPanels(_ sample: Expected, retries: Bool) async throws {
        let frame = Frame(image: try fixture(sample.path))
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame.image))
        let reading = try await offPool {
            try GearDropScreenReader.reading(frame.image, bounds: bounds, sourceTime: 1,
                titleMemory: GearTitleLanguageMemory(),
                languages: GameLanguageMemory(language: sample.language, isAutomatic: false), retries: retries,
                rereadsUnreadableRows: true)
        }
        let evidence = reading.evidence
        #expect(evidence.stage == sample.stage, "\(Self.describe(reading.passes))")
        if let items = sample.items {
            #expect(Self.items(evidence) == items)
        }
        #expect(evidence.entries.count == sample.count, "\(Self.items(evidence))")
        #expect(evidence.entries.reduce(0) { $0 + $1.quantity } == sample.quantity, "\(Self.items(evidence))")
        #expect(evidence.unreadableRows == 0)
        #expect(!reading.untitledPanel)
    }
}
