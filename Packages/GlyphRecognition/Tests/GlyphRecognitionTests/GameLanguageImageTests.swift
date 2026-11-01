import Foundation
import CoreGraphics
import CoreText
import Testing
@testable import GlyphRecognition
@testable import GlyphRecognitionImages

/// Serialized, like the other Vision suites: many synchronous text requests
/// at once never return on the parallel runner.
@Suite("Recorded game languages", .serialized, .timeLimit(.minutes(2)))
struct GameLanguageImageTests {
    func image(_ name: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("Languages/\(name).png"))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    func items(_ evidence: GearDropFrameEvidence) -> [String] {
        evidence.entries.map { "\($0.level.map { "L\($0) " } ?? "")\($0.item ?? "?") x\($0.quantity)" }
    }

    /// Replace one row of the masked Japanese fixture with a shared English
    /// item, reproducing the mixed-language panel without a private capture.
    func mixedJapanesePanel() throws -> CGImage {
        let frame = try image("ja-portal-cut")
        let canvas = try #require(CGContext(data: nil, width: frame.width, height: frame.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let y = Double(frame.height) * (1 - 0.37)
        canvas.setFillColor(CGColor(gray: 0.06, alpha: 1))
        canvas.fill(CGRect(x: Double(frame.width) * 0.54, y: y,
                          width: Double(frame.width) * 0.44, height: Double(frame.height) * 0.036))
        canvas.textMatrix = .identity
        canvas.textPosition = CGPoint(x: Double(frame.width) * 0.56, y: y + 8)
        let text = NSAttributedString(string: "L6 x1 Power Cube", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString,
                Double(frame.width) * 0.022, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
        CTLineDraw(CTLineCreateWithAttributedString(text), canvas)
        return try #require(canvas.makeImage())
    }

    @Test("A Chinese Bonus panel reads its title and every row")
    func chineseBonus() throws {
        let frame = try image("zh-bonus")
        let reader = GearDropScreenReader(language: .simplifiedChinese)
        let bounds = try #require(try reader.bounds(in: frame))
        let evidence = try reader.read(frame, bounds: bounds, sourceTime: 1)
        #expect(evidence.stage == .bonus)
        #expect(items(evidence) == ["L6 XMP Burster x4", "L5 XMP Burster x1", "L6 Resonator x5"])
        #expect(evidence.unreadableRows == 0)
    }

    @Test("A Japanese panel reads names cut at a word and at the column edge")
    func japaneseCutNames() throws {
        let frame = try image("ja-portal-cut")
        let reader = GearDropScreenReader(language: .japanese)
        let bounds = try #require(try reader.bounds(in: frame))
        let evidence = try reader.read(frame, bounds: bounds, sourceTime: 1)
        #expect(evidence.stage == .portal)
        #expect(items(evidence) == ["Aegis Shield x1", "Portal Shield x1", "L6 XMP Burster x1",
                                    "L5 XMP Burster x2", "L5 Resonator x1"])
        #expect(evidence.entries.first?.rarity == .veryRare)
    }

    @Test("Automatic reading finds the language from its own Bonus title, never from shared text")
    func detectFromPanel() throws {
        let bonus = try image("zh-bonus")
        let memory = GameLanguageMemory(language: .english, isAutomatic: true)
        let bounds = try #require(try GearDropScreenReader().bounds(in: bonus))
        let evidence = try GearDropScreenReader.read(bonus, bounds: bounds, sourceTime: 1, languages: memory)
        #expect(memory.current == .simplifiedChinese && evidence.titleLanguage == .simplifiedChinese)
        #expect(evidence.entries.filter { $0.item != nil }.count == 3)
        // A portal panel names no language: its title is a portal's, and its
        // names can be English in several games.
        let portal = try image("ja-portal-cut")
        let unsure = GameLanguageMemory(language: .english, isAutomatic: true)
        let portalBounds = try #require(try GearDropScreenReader().bounds(in: portal))
        let portalRead = try GearDropScreenReader.read(portal, bounds: portalBounds, sourceTime: 1, languages: unsure)
        #expect(portalRead.entries.filter { $0.item != nil }.count == 5)
        #expect(unsure.current == .english)
        // A chosen language is kept even where it reads nothing.
        let chosen = GameLanguageMemory(language: .japanese, isAutomatic: false)
        _ = try GearDropScreenReader.read(bonus, bounds: bounds, sourceTime: 1, languages: chosen)
        #expect(chosen.current == .japanese)
    }

    func fixture(_ path: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("\(path).png"))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    @Test("Reading a screen in the current language confirms it, but not English text Japanese games share")
    func confirmation() throws {
        let bonus = try image("zh-bonus")
        let bounds = try #require(try GearDropScreenReader().bounds(in: bonus))
        let chinese = GameLanguageMemory(language: .simplifiedChinese, isAutomatic: true)
        #expect(!chinese.isConfirmed, "A starting guess is not a finding")
        _ = try GearDropScreenReader.read(bonus, bounds: bounds, sourceTime: 1, languages: chinese)
        #expect(chinese.state.language == .simplifiedChinese && chinese.state.isConfirmed)
        let capture = CommandNoticeCapture()
        try capture.observe(band: image("zh-complex"), at: 1)
        let notice = try #require(capture.take(at: 1))
        let fromNotice = GameLanguageMemory(language: .simplifiedChinese, isAutomatic: true)
        #expect(try CommandNoticeReader.read(notice, languages: fromNotice).notice == .complex)
        #expect(fromNotice.isConfirmed)
        // No game leaves the Bonus title in English, so it confirms English.
        let englishBonus = try fixture("Gear/four-bonus")
        let english = GameLanguageMemory(language: .english, isAutomatic: true)
        _ = try GearDropScreenReader.read(englishBonus, bounds: try #require(try GearDropScreenReader().bounds(in: englishBonus)),
                                          sourceTime: 1, languages: english)
        #expect(english.state.language == .english && english.state.isConfirmed)
        // Japanese games print the result labels and NO KEY in English.
        let labels = GameLanguageMemory(language: .english, isAutomatic: true)
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1,
                                        glyphs: ["truth", "idea", "discover", "xm"])
        #expect(try ResultScreenReader.read(fixture("Results/four-final"), context: context, sourceTime: 1,
                                            languages: labels).panelPresent)
        let noKeyCapture = CommandNoticeCapture()
        try noKeyCapture.observe(band: fixture("Commands/no-key"), at: 1)
        let noKey = try #require(noKeyCapture.take(at: 1))
        #expect(try CommandNoticeReader.read(noKey, languages: labels).notice?.command == .noKey)
        #expect(!labels.isConfirmed)
        // A portal panel's title is a portal's: it names no language.
        let portal = try image("ja-portal-cut")
        let unsure = GameLanguageMemory(language: .japanese, isAutomatic: true)
        _ = try GearDropScreenReader.read(portal, bounds: try #require(try GearDropScreenReader().bounds(in: portal)),
                                          sourceTime: 1, languages: unsure)
        #expect(!unsure.isConfirmed)
        let chosen = GameLanguageMemory(language: .simplifiedChinese, isAutomatic: false)
        _ = try GearDropScreenReader.read(bonus, bounds: bounds, sourceTime: 1, languages: chosen)
        #expect(!chosen.isConfirmed, "A chosen language is the player's, not a finding")
    }

    @Test("A Chinese notice reads in Chinese, and automatic reading finds Chinese from it")
    func chineseNotice() throws {
        let capture = CommandNoticeCapture()
        try capture.observe(band: image("zh-complex"), at: 1)
        let frame = try #require(capture.take(at: 1))
        let chinese = try CommandNoticeReader(language: .simplifiedChinese).read(frame)
        #expect(chinese.notice == .complex && chinese.language == "zh-Hans" && chinese.isClear)
        #expect(try CommandNoticeReader().read(frame).notice == nil, "English can't read it")
        let memory = GameLanguageMemory(language: .english, isAutomatic: true)
        #expect(try CommandNoticeReader.read(frame, languages: memory).notice == .complex)
        #expect(memory.current == .simplifiedChinese)
    }

    @Test("A panel with any unnamed row tries the other languages")
    func mixedPanelRetries() {
        func entry(_ item: String?) -> GearDropEntry {
            GearDropEntry(column: 0, row: 0, item: item, levelState: .known, level: 8, quantity: 1)
        }
        let mixed = GearDropFrameEvidence(sourceTime: 1, stage: .portal, entries: [entry("Power Cube"), entry(nil)])
        #expect(GearDropScreenReader.needsOtherLanguages(mixed))
        let read = GearDropFrameEvidence(sourceTime: 1, stage: .bonus, entries: [entry("Power Cube")])
        #expect(!GearDropScreenReader.needsOtherLanguages(read))
        let unreadable = GearDropFrameEvidence(sourceTime: 1, stage: .bonus, entries: [entry("Power Cube")], unreadableRows: 1)
        #expect(GearDropScreenReader.needsOtherLanguages(unreadable))
        #expect(!GearDropScreenReader.needsOtherLanguages(GearDropFrameEvidence(sourceTime: 1, stage: .excluded)))
        #expect(GearDropScreenReader.needsOtherLanguages(GearDropFrameEvidence(sourceTime: 1, stage: .unsupported)))
    }

    @Test("Automatic reading recovers a mixed portal panel on successive samples without changing the game language")
    func mixedPortalRows() throws {
        let frame = try mixedJapanesePanel()
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame))
        let memory = GameLanguageMemory(language: .english, isAutomatic: true)
        let expected = ["Aegis Shield x1", "L6 Power Cube x1", "L6 XMP Burster x1",
                        "L5 XMP Burster x2", "L5 Resonator x1"]
        var tracker = GearDropTracker()
        for time in [1.0, 1.1] {
            let read = try GearDropScreenReader.read(frame, bounds: bounds, sourceTime: time, languages: memory)
            #expect(read.stage == .portal && read.unreadableRows == 0)
            #expect(items(read) == expected)
            #expect(memory.current == .english)
            #expect(memory.panelReadingLanguage(at: time, bounds: bounds) == .japanese)
            _ = tracker.accept(read)
        }
        let finished = tracker.finish(at: 1.2, reason: "test")
        let summary = try #require(finished)
        #expect(summary.recognizedQuantity == 6)
        #expect(summary.panels.first?.partial == false)
        #expect(summary.panels.first?.entries.map(\.item) == ["Aegis Shield", "Power Cube", "XMP Burster",
                                                              "XMP Burster", "Resonator"])
        // A Bonus title can subsequently identify the game language.
        let bonus = try image("zh-bonus")
        let bonusBounds = try #require(try GearDropScreenReader().bounds(in: bonus))
        let read = try GearDropScreenReader.read(bonus, bounds: bonusBounds, sourceTime: 3, languages: memory)
        #expect(read.titleLanguage == .simplifiedChinese && memory.current == .simplifiedChinese)
    }

    @Test("A better portal read must use localized evidence and preserve recognized rows and quantities")
    func portalRecoveryGuards() {
        func entry(_ item: String?, _ quantity: Int = 1, _ column: Int = 0) -> GearDropEntry {
            .init(column: column, row: 0, item: item, levelState: .known, level: 8, quantity: quantity)
        }
        func read(_ entries: [GearDropEntry]) -> GearDropFrameEvidence {
            .init(sourceTime: 1, stage: .portal, entries: entries)
        }
        let original = read([entry("Power Cube"), entry(nil, 2, 1)])
        let recovered = read([entry("Power Cube"), entry("Resonator", 2, 1)])
        #expect(GearDropScreenReader.improvesPortal(recovered, over: original, localizedPositions: [1]))
        #expect(!GearDropScreenReader.improvesPortal(recovered, over: original, localizedPositions: []))
        #expect(!GearDropScreenReader.improvesPortal(read([entry("XMP Burster"), entry("Resonator", 2, 1)]),
                                                    over: original, localizedPositions: [1]))
        #expect(!GearDropScreenReader.improvesPortal(read([entry("Power Cube"), entry("Resonator", 3, 1)]),
                                                    over: original, localizedPositions: [1]))
    }
}
