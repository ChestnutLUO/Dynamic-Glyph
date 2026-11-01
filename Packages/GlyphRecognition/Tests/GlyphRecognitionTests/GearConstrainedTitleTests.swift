import CoreGraphics
import CoreText
import Foundation
import Testing
import GlyphRecognition
@testable import GlyphRecognitionImages

/// Constrained capture (Low Power Mode, a hot phone) reads a gear panel
/// without retries. It used to skip title recovery too, so a portal panel
/// whose name is only CJK characters, which the English item pass doesn't
/// read, was no panel at all (2026-10-28 session, hack 1). Now a missing or
/// unclear title gets one recovery pass in one language family. Titles here
/// are synthetic text drawn over the committed `four-base` fixture, or, where
/// a test depends on the score Vision gives a drawn name, scripted
/// (`GearScriptedTitleRead`): that score differs by machine.
///
/// Serialized: many synchronous Vision text requests at once never return on
/// the parallel test runner. The Vision reads also run off Swift's shared
/// cooperative pool (`offPool`): a synchronous Vision call holds its thread
/// for the whole request, and with the other Vision suites running in
/// parallel those blocked threads can starve the pool on a Mac.
@Suite("Constrained gear title recovery", .serialized, .timeLimit(.minutes(3)))
struct GearConstrainedTitleTests {
    static func english() -> GameLanguageMemory { GameLanguageMemory(language: .english, isAutomatic: false) }

    /// Hands a CGImage to the reading thread.
    struct Frame: @unchecked Sendable { let image: CGImage }

    /// Runs synchronous Vision work on a thread of its own and awaits it, so
    /// the test's pool thread is free while Vision runs. Expectations stay in
    /// the test body, on the test's own task.
    func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    func image(_ name: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("Gear/\(name).png"))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    /// The fixture's title painted over in the panel's colour and `title`
    /// drawn in its place, as `GearDropScreenReaderTests` does.
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

    func describe(_ passes: [GearReadPass]) -> String {
        passes.map { "\($0.purpose.rawValue) \($0.languages.joined(separator: "+")): \($0.lines) lines, "
            + "\($0.titleLines) title \($0.titleConfidences)" }.joined(separator: "; ")
    }

    @Test("Constrained, a portal panel with a Chinese-only name is read, with one title pass",
          arguments: GearConstrainedTitleFixtures.recoveredTitles)
    func chineseOnlyTitle(_ title: String) throws {
        // Scripted (build 102c): whether a drawn name reads at 1.0 on the
        // panel crop is up to the machine's Vision. Here the first family
        // reads it at 1.0 there, as on the Simulator.
        typealias Scripted = GearScriptedTitleRead
        let families = GearDropScreenReader.titleFamilies
        // The panel as it was: its own title read by the English item pass.
        let expected = GearDropTextParser().read(lines: [Scripted.title("Reference", 1)] + Scripted.rows,
                                                 bounds: Scripted.bounds, at: 0)
        try #require(expected.stage == .portal && !expected.entries.isEmpty)
        // The English item pass reads no title line (2026-10-28 hack 1) or one at 0.3.
        for panelTitle in [nil, 0.3] as [Double?] {
            let panel = Scripted.rows + (panelTitle.map { [Scripted.title(title, $0)] } ?? [])
            // The English item pass had no title it could use.
            try #require(panel.filter(Scripted.inTitleZone).allSatisfy { $0.confidence < 0.7 })
            let reading = try Scripted.read(panel: panel, retries: false) { _, languages in
                languages == families[0] ? [Scripted.title(title, 1)] : []
            }
            #expect(reading.evidence.stage == .portal, "\(reading.titlePasses)")
            #expect(reading.evidence.entries == expected.entries)
            #expect(reading.evidence.unreadableRows == 0)
            #expect(!reading.untitledPanel)
            // One title pass did, on the panel crop: no title-zone fallback.
            #expect(reading.titlePasses == [.init(crop: .panel, languages: families[0])], "\(reading.titlePasses)")
        }
    }

    @Test("A name every family reads at 0.5 stays unread: the 0.7 floor is unchanged; it is an untitled panel")
    func halfConfidenceName() throws {
        // As 2026-10-28 hack 3: the English pass has no title line and every
        // family scores the name 0.5, in either crop, unconstrained as well.
        // Scripted (build 102c): a drawn name's score is up to the machine's
        // Vision (a Mac's zh-Hant pass read this one at 1.0, the Simulator
        // at 0.5); this checks the 0.7 floor itself.
        typealias Scripted = GearScriptedTitleRead
        let families = GearDropScreenReader.titleFamilies
        for retries in [false, true] {
            let reading = try Scripted.read(panel: Scripted.rows, retries: retries) { _, _ in
                [Scripted.title("测试地点", 0.5)]
            }
            #expect(reading.evidence.stage == .unknown && reading.evidence.entries.isEmpty,
                    "retries \(retries): \(reading.titlePasses)")
            #expect(reading.untitledPanel, "retries \(retries): its rows are a drop panel's")
            let titles = reading.titlePasses
            #expect(retries ? titles.count == 3 : titles.count <= 2, "\(titles)")
            if retries {
                // Every family, on the panel crop, as before.
                #expect(titles.map(\.languages) == families && titles.allSatisfy { $0.crop == .panel }, "\(titles)")
            } else {
                // One family: the panel crop, then the title-zone fallback.
                #expect(titles.allSatisfy { $0.languages == families[0] }, "\(titles)")
            }
        }
    }

    @Test("Constrained, text that is no portal title never becomes a panel",
          arguments: ["", "Bounty Claimed", "獎勵物品:", "奖励物品:"])
    func noPanelTitles(_ title: String) async throws {
        let frame = Frame(image: try replacingTitle(in: image("four-base"), with: title))
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame.image))
        let reading = try await offPool {
            try GearDropScreenReader.reading(frame.image, bounds: bounds, sourceTime: 1,
                titleMemory: GearTitleLanguageMemory(), languages: Self.english(), retries: false,
                rereadsUnreadableRows: true)
        }
        #expect(reading.evidence.stage != .portal && reading.evidence.stage != .bonus,
                "\(reading.evidence.stage) \(describe(reading.passes))")
        #expect(reading.evidence.entries.isEmpty)
        #expect(reading.passes.filter { $0.purpose == .title }.count <= 2)
    }

    @Test("Constrained, a panel with its title painted out is an untitled panel, never a portal panel")
    func paintedOutTitle() async throws {
        let frame = Frame(image: try replacingTitle(in: image("four-base"), with: ""))
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame.image))
        let reading = try await offPool {
            try GearDropScreenReader.reading(frame.image, bounds: bounds, sourceTime: 1,
                languages: Self.english(), retries: false, rereadsUnreadableRows: true)
        }
        #expect(reading.evidence.stage == .unknown && reading.evidence.entries.isEmpty)
        #expect(reading.untitledPanel, "its rows are a drop panel's: \(describe(reading.passes))")
    }

    @Test("A blank screen read as if it held a panel is neither a panel nor an untitled one")
    func blankIsNoPanel() async throws {
        let width = 562, height = 1218
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let frame = Frame(image: try #require(context.makeImage()))
        let reading = try await offPool {
            try GearDropScreenReader.reading(frame.image, bounds: GearDropPanelBounds(top: 0.29, bottom: 0.42),
                sourceTime: 1, languages: Self.english(), retries: false, rereadsUnreadableRows: true)
        }
        #expect(reading.evidence.stage == .unknown && !reading.untitledPanel)
    }

    // MARK: - One family, without Vision

    static let bounds = GearDropPanelBounds(top: 0.286, bottom: 0.383)
    static let title = ResultTextLine(text: "Reference", confidence: 1, x: 0.29, y: 0.306, width: 0.42, height: 0.024)

    @Test("Constrained recovery tries one family: the remembered one, else the first")
    func oneFamily() throws {
        let reader = GearDropScreenReader()
        let families = GearDropScreenReader.titleFamilies
        // Only the Japanese family would read it.
        var asked: [[String]] = []
        let first = try reader.recoverTitle(bounds: Self.bounds, sourceTime: 1, memory: nil, passes: 1) { languages in
            asked.append(languages); return languages == families[1] ? [Self.title] : []
        }
        #expect(first.isEmpty && asked == [families[0]], "one pass, zh-Hant first: \(asked)")

        let memory = GearTitleLanguageMemory()
        memory.remember(families[1], at: 0.8)
        asked = []
        let remembered = try reader.recoverTitle(bounds: Self.bounds, sourceTime: 1, memory: memory, passes: 1) { languages in
            asked.append(languages); return languages == families[1] ? [Self.title] : []
        }
        #expect(remembered.count == 1 && asked == [families[1]], "\(asked)")

        // Unconstrained, every family as before.
        asked = []
        let all = try reader.recoverTitle(bounds: Self.bounds, sourceTime: 1, memory: nil) { languages in
            asked.append(languages); return languages == families[2] ? [Self.title] : []
        }
        #expect(all.count == 1 && asked == families, "\(asked)")
    }

    @Test("A recovered title must still be one line at 0.7 or more")
    func recoveryFloorUnchanged() throws {
        let reader = GearDropScreenReader()
        let half = ResultTextLine(text: "Reference", confidence: 0.5, x: 0.29, y: 0.306, width: 0.42, height: 0.024)
        #expect(try reader.recoverTitle(bounds: Self.bounds, sourceTime: 1, memory: nil, passes: 1) { _ in [half] }
            .isEmpty)
        #expect(try reader.recoverTitle(bounds: Self.bounds, sourceTime: 1, memory: nil, passes: 1) { _ in
            [Self.title, Self.title] }.isEmpty)
    }
}

enum GearConstrainedTitleFixtures {
    /// Synthetic Chinese-only names the English item pass doesn't read (no
    /// title line, as on 2026-10-28 hack 1's frames) or reads at 0.3; the
    /// first family reads each at 1.0 on the Simulator. Scripted lines'
    /// text (`chineseOnlyTitle`).
    static let recoveredTitles = ["測試傳送", "參考地標", "測試用傳送門"]
}

/// A gear read's title recovery with a scripted recognizer in place of
/// Vision (build 102c, Ato 1908). The score Vision gives a title drawn at run
/// time differs by machine: on a Mac the 2x zh-Hant pass read a name at 1.0
/// that the Simulator reads at 0.5. Tests of the 0.7 floor and of the title
/// passes script those reads instead.
///
/// Production pieces, in `readPanel`'s order: the title-zone filter on the
/// panel pass's lines and the English title floor; `recoverTitle` (family
/// order, the 0.7 floor, one family without retries) through its
/// `recognize` seam, inside which, without retries, `needsTitleFallback`
/// decides the title-zone pass after the panel-crop pass, as `readPanel`'s
/// closure does; then the English parser for the stage, rows and an untitled
/// panel. `readPanel` itself, whose OCR is private, runs with Vision in the
/// tests on recorded or painted-out panels (`fallbackOnlyConstrained`,
/// `paintedOutTitle`, `recordedPanels`). Rows are known items, as
/// `GearUntitledPanelTests`; no recognized or session text.
enum GearScriptedTitleRead {
    enum Crop: String, Sendable { case panel, zone }

    struct Pass: Equatable, Sendable, CustomStringConvertible {
        let crop: Crop
        let languages: [String]
        var description: String { "\(crop.rawValue) \(languages.joined(separator: "+"))" }
    }

    struct Reading {
        let evidence: GearDropFrameEvidence
        let untitledPanel: Bool
        /// Each scripted title pass, in order.
        let titlePasses: [Pass]
    }

    static let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.46)

    static func title(_ text: String, _ confidence: Double) -> ResultTextLine {
        ResultTextLine(text: text, confidence: confidence, x: 0.29, y: 0.30, width: 0.42, height: 0.024)
    }

    static func row(_ text: String, x: Double = 0.1) -> ResultTextLine {
        ResultTextLine(text: text, confidence: 1, x: x, y: 0.386, width: 0.35, height: 0.014)
    }

    /// Two known items in the first row, as the English item pass reads them.
    static let rows = [row("L6 x1 Power Cube"), row("L6 x1 Resonator", x: 0.58)]

    /// `recoverTitle`'s and `readPanel`'s title zone.
    static func inTitleZone(_ line: ResultTextLine) -> Bool {
        line.y >= bounds.top && line.y + line.height <= bounds.bottom + 0.003
            && line.x >= 0.025 && line.x + line.width <= 0.98
            && line.y + line.height / 2 < bounds.top + 0.045
    }

    /// An English game's read of a panel whose item pass gave `panel`;
    /// `script` answers each title pass (its crop and family) in Vision's place.
    static func read(panel: [ResultTextLine], retries: Bool,
                     memory: GearTitleLanguageMemory = GearTitleLanguageMemory(),
                     script: (Crop, [String]) -> [ResultTextLine]) throws -> Reading {
        var lines = panel, passes: [Pass] = []
        let titles = lines.filter(inTitleZone)
        let floor = GameLanguage.english.confidence.title
        if titles.isEmpty || (titles.count == 1 && titles[0].confidence < floor) {
            let recovered = try GearDropScreenReader().recoverTitle(bounds: bounds, sourceTime: 1, memory: memory,
                                                                    passes: retries ? nil : 1) { languages in
                passes.append(Pass(crop: .panel, languages: languages))
                let read = script(.panel, languages)
                guard !retries, GearDropScreenReader.needsTitleFallback(read, bounds: bounds) else { return read }
                passes.append(Pass(crop: .zone, languages: languages))
                return script(.zone, languages)
            }
            if !recovered.isEmpty {
                lines.removeAll { titles.contains($0) }
                lines += recovered
            }
        }
        let parser = GearDropTextParser()
        let evidence = parser.read(lines: lines, bounds: bounds, at: 1)
        return Reading(evidence: evidence,
                       untitledPanel: evidence.stage == .unknown
                           && parser.showsUntitledPanel(lines: lines, bounds: bounds, at: 1),
                       titlePasses: passes)
    }
}
