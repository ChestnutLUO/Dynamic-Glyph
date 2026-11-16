import CoreGraphics
import Foundation
import Testing
import Vision
import GlyphCoreCxx
@testable import GlyphRecognition
@testable import GlyphRecognitionCxx
@testable import GlyphRecognitionImages

/// The C++ gear logic held to its Swift oracle: every scenario of the gear
/// oracle tests runs through both arms with the same inputs, and every
/// output is compared.
/// Serialized: the fixture tests run Vision, which hangs when many
/// synchronous requests run at once.
@Suite("C++ logic: gear", .serialized, .timeLimit(.minutes(5)))
struct CxxGearTests {

    // MARK: - Two arms, one transcript each

    /// Everything an arm returned, in call order. Doubles compare exactly.
    enum Output: Equatable {
        case summary(GearDropSummary?)
        case tracker(observing: Bool, disposition: GearDropTracker.ReadingDisposition, settled: Bool)
        case session(waiting: [GearDropObservationSession.Wait], events: [GearDropObservationSession.Event],
                     uncertain: Bool)
        case flag(Bool)
        case display(GearDropDisplay?, revision: Int)
        case entry(GearDropEntry?)
        case evidence(GearDropFrameEvidence)
        case position(Int?)
        case color(Bool?)
        case rarity(GearDropEntry.Rarity?)
    }

    final class Recorder {
        var outputs: [Output] = []
    }

    /// The session's members the oracle tests also call directly.
    protocol TestSession: GearDropSessioning {
        mutating func enqueue(hackID: Int, at time: Double)
        mutating func expire(at time: Double)
    }

    final class TrackerProbe {
        private var base: any GearDropTracking
        private let recorder: Recorder
        init(_ base: any GearDropTracking, _ recorder: Recorder) { self.base = base; self.recorder = recorder }

        var isObserving: Bool { base.isObserving }
        var readingDisposition: GearDropTracker.ReadingDisposition { base.readingDisposition }
        var currentPanelSettled: Bool { base.currentPanelSettled }

        private func log(_ summary: GearDropSummary?) -> GearDropSummary? {
            recorder.outputs.append(.summary(summary))
            recorder.outputs.append(.tracker(observing: base.isObserving, disposition: base.readingDisposition,
                                             settled: base.currentPanelSettled))
            return summary
        }

        @discardableResult func accept(_ evidence: GearDropFrameEvidence) -> GearDropSummary? {
            log(base.accept(evidence))
        }

        @discardableResult func observe(at time: Double, panelCandidate: Bool, continuityLost: Bool = false,
                                        pendingReadSourceTime: Double? = nil) -> GearDropSummary? {
            log(base.observe(at: time, panelCandidate: panelCandidate, continuityLost: continuityLost,
                             pendingReadSourceTime: pendingReadSourceTime))
        }

        @discardableResult func loseContinuity(at time: Double) -> GearDropSummary? {
            log(base.loseContinuity(at: time))
        }

        @discardableResult func finish(at time: Double, reason: String) -> GearDropSummary? {
            log(base.finish(at: time, reason: reason))
        }
    }

    final class SessionProbe {
        private var base: any TestSession
        private let recorder: Recorder
        init(_ base: any TestSession, _ recorder: Recorder) { self.base = base; self.recorder = recorder }

        var waiting: [GearDropObservationSession.Wait] { base.waiting }
        var events: [GearDropObservationSession.Event] { base.events }
        var isAssociationUncertain: Bool { base.isAssociationUncertain }

        private func log() {
            recorder.outputs.append(.session(waiting: base.waiting, events: base.events,
                                             uncertain: base.isAssociationUncertain))
        }

        @discardableResult func prepareFrame(at time: Double, continuityLost: Bool) -> Bool {
            let lost = base.prepareFrame(at: time, continuityLost: continuityLost)
            recorder.outputs.append(.flag(lost)); log()
            return lost
        }

        func observe(at time: Double, hackID: Int, inputVisible: Bool, gameProgressVisible: Bool = false,
                     inputPhase: TrackingState = .input) {
            base.observe(at: time, hackID: hackID, inputVisible: inputVisible,
                         gameProgressVisible: gameProgressVisible, inputPhase: inputPhase)
            log()
        }

        func enqueue(hackID: Int, at time: Double) { base.enqueue(hackID: hackID, at: time); log() }
        func accept(_ result: HackResult) { base.accept(result); log() }
        func expire(at time: Double) { base.expire(at: time); log() }
        func invalidate(at time: Double, reason: String) { base.invalidate(at: time, reason: reason); log() }

        @discardableResult func close(_ group: GearDropSummary) -> GearDropSummary {
            let attached = base.close(group)
            recorder.outputs.append(.summary(attached)); log()
            return attached
        }
    }

    final class DisplayProbe {
        private var base: any GearDropDisplaying
        private let recorder: Recorder
        init(_ base: any GearDropDisplaying, _ recorder: Recorder) { self.base = base; self.recorder = recorder }

        private func log() { recorder.outputs.append(.display(base.display, revision: base.revision)) }

        func update(waiting: [GearDropObservationSession.Wait], reading: Bool, associationUncertain: Bool,
                    at time: Double) {
            base.update(waiting: waiting, reading: reading, associationUncertain: associationUncertain, at: time)
            log()
        }
        func finished(_ group: GearDropSummary) { base.finished(group); log() }
        func ended(hackID: Int, at time: Double) { base.ended(hackID: hackID, at: time); log() }
    }

    final class ScheduleProbe {
        private var base: any GearEvidenceScheduling
        private let recorder: Recorder
        init(_ base: any GearEvidenceScheduling, _ recorder: Recorder) { self.base = base; self.recorder = recorder }

        @discardableResult func shouldSave(stage: GearDropStage, at time: Double) -> Bool {
            let value = base.shouldSave(stage: stage, at: time)
            recorder.outputs.append(.flag(value))
            return value
        }
        func didEnqueue(stage: GearDropStage, at time: Double) {
            base.didEnqueue(stage: stage, at: time)
            recorder.outputs.append(.flag(base.shouldSave(stage: stage, at: time)))
        }
    }

    final class ParserProbe {
        private let base: any GearDropTextParsing
        private let positionOf: (ResultTextLine, GearDropPanelBounds) -> Int?
        private let recorder: Recorder
        init(_ base: any GearDropTextParsing, position: @escaping (ResultTextLine, GearDropPanelBounds) -> Int?,
             _ recorder: Recorder) {
            self.base = base; self.positionOf = position; self.recorder = recorder
        }

        @discardableResult func parseEntry(_ text: String, row: Int, column: Int,
                                           clipped: Bool = false) -> GearDropEntry? {
            let entry = base.parseEntry(text, row: row, column: column, clipped: clipped)
            recorder.outputs.append(.entry(entry))
            return entry
        }

        @discardableResult func read(lines: [ResultTextLine], bounds: GearDropPanelBounds,
                                     at time: Double) -> GearDropFrameEvidence {
            let evidence = base.read(lines: lines, bounds: bounds, at: time)
            recorder.outputs.append(.evidence(evidence))
            recorder.outputs.append(.flag(base.showsUntitledPanel(lines: lines, bounds: bounds, at: time)))
            return evidence
        }

        @discardableResult func position(of line: ResultTextLine, in bounds: GearDropPanelBounds) -> Int? {
            let position = positionOf(line, bounds)
            recorder.outputs.append(.position(position))
            return position
        }
    }

    /// One arm: how to make each object, and where its outputs go.
    final class Rig {
        let name: String
        let recorder = Recorder()
        private let makeTracker: (GearDropTracker.Policy) -> any GearDropTracking
        private let makeSession: (GearDropObservationSession.Policy) -> any TestSession
        private let makeDisplay: (Bool) -> any GearDropDisplaying
        private let makeSchedule: () -> any GearEvidenceScheduling
        private let makeParser: (GameLanguage) -> any GearDropTextParsing
        private let positionOf: (ResultTextLine, GearDropPanelBounds) -> Int?
        private let colorOf: (ColorImage) -> Bool?
        private let rarityOf: (ColorImage) -> GearDropEntry.Rarity?

        init(name: String, tracker: @escaping (GearDropTracker.Policy) -> any GearDropTracking,
             session: @escaping (GearDropObservationSession.Policy) -> any TestSession,
             display: @escaping (Bool) -> any GearDropDisplaying,
             schedule: @escaping () -> any GearEvidenceScheduling,
             parser: @escaping (GameLanguage) -> any GearDropTextParsing,
             position: @escaping (ResultTextLine, GearDropPanelBounds) -> Int?,
             color: @escaping (ColorImage) -> Bool?, rarity: @escaping (ColorImage) -> GearDropEntry.Rarity?) {
            self.name = name; makeTracker = tracker; makeSession = session; makeDisplay = display
            makeSchedule = schedule; makeParser = parser; positionOf = position; colorOf = color; rarityOf = rarity
        }

        func tracker(policy: GearDropTracker.Policy = .init()) -> TrackerProbe {
            TrackerProbe(makeTracker(policy), recorder)
        }
        func session(policy: GearDropObservationSession.Policy = .init()) -> SessionProbe {
            SessionProbe(makeSession(policy), recorder)
        }
        func display(standalone: Bool = false) -> DisplayProbe { DisplayProbe(makeDisplay(standalone), recorder) }
        func schedule() -> ScheduleProbe { ScheduleProbe(makeSchedule(), recorder) }
        func parser(_ language: GameLanguage = .english) -> ParserProbe {
            ParserProbe(makeParser(language), position: positionOf, recorder)
        }
        @discardableResult func color(_ image: ColorImage) -> Bool? {
            let value = colorOf(image)
            recorder.outputs.append(.color(value))
            return value
        }
        @discardableResult func rarity(_ image: ColorImage) -> GearDropEntry.Rarity? {
            let value = rarityOf(image)
            recorder.outputs.append(.rarity(value))
            return value
        }

        static func swift() -> Rig {
            Rig(name: "swift", tracker: { GearDropTracker(policy: $0) },
                session: { GearDropObservationSession(policy: $0) },
                display: { GearDropDisplayTracker(standalone: $0) }, schedule: { GearEvidenceSchedule() },
                parser: { GearDropTextParser(language: $0) }, position: GearDropTextParser.position(of:in:),
                color: { GearQuantityColorReader().read($0) }, rarity: { GearRarityReader().read($0) })
        }

        static func cxx() -> Rig {
            Rig(name: "cpp", tracker: { CxxGearDropTracker(policy: $0) },
                session: { CxxGearDropObservationSession(policy: $0) },
                display: { CxxGearDropDisplayTracker(standalone: $0) }, schedule: { CxxGearEvidenceSchedule() },
                parser: { CxxGearDropTextParser(language: $0) }, position: CxxGearDropTextParser.position(of:in:),
                color: { CxxGearQuantityColorReader().read($0) }, rarity: { CxxGearRarityReader().read($0) })
        }
    }

    /// Runs `scenario` on both arms and compares every output. Returns how
    /// many outputs were compared.
    @discardableResult
    static func compare(_ name: String, sourceLocation: SourceLocation = #_sourceLocation,
                        _ scenario: (Rig) throws -> Void) rethrows -> Int {
        let swift = Rig.swift(), cxx = Rig.cxx()
        try scenario(swift)
        try scenario(cxx)
        let expected = swift.recorder.outputs, actual = cxx.recorder.outputs
        #expect(!expected.isEmpty, "\(name): the scenario produced no output", sourceLocation: sourceLocation)
        if expected != actual {
            let index = (0..<min(expected.count, actual.count)).first { expected[$0] != actual[$0] }
                ?? min(expected.count, actual.count)
            let swiftValue = index < expected.count ? String(describing: expected[index]) : "nothing"
            let cxxValue = index < actual.count ? String(describing: actual[index]) : "nothing"
            Issue.record("\(name): output \(index) of \(expected.count) differs.\nswift: \(swiftValue)\ncpp:   \(cxxValue)",
                         sourceLocation: sourceLocation)
        }
        return expected.count
    }

    // MARK: - Shared inputs (as in the oracle tests)

    static let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.46)

    static func line(_ text: String, x: Double = 0.1, y: Double = 0.35, width: Double = 0.35,
                     confidence: Double = 1) -> ResultTextLine {
        ResultTextLine(text: text, confidence: confidence, x: x, y: y, width: width, height: 0.014)
    }

    static func frame(_ time: Double, stage: GearDropStage = .portal, quantity: Int = 2,
                      unreadable: Int = 0) -> GearDropFrameEvidence {
        .init(sourceTime: time, stage: stage, entries: [
            GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .known, level: 6, quantity: quantity)
        ], unreadableRows: unreadable)
    }

    static func result(hack: Int, bonus: Int?) -> HackResult {
        var result = HackResult(context: ResultReadContext(sessionID: .init(rawValue: 1), hackID: hack, glyphs: ["xm"]),
                                outcomes: [.unknown], outcomeTimes: [nil])
        result.finalHackingBonus = bonus
        return result
    }

    /// Every entry text the oracle tests parse.
    static let entryTexts: [String] = {
        var texts = ["L6 x8 XMP Burster", "x1 Portal Key", "6 x8 XMP Burster", "15 x2 XMP Burster",
                     "1*)8 x1 XMP Burster", "(*) 15 x2 XMP Burster", "L* L7 x1 XMP Burster", "68 x1 Resonator",
                     "15 x2 New item", "L5 x2 New item", "L9 x8 XMP Burster", "x2 ITO EN Tr…", "/// x1 ITO EN (-)",
                     "\"4 /ll x1 ITO EN (-)", "/// x1 ITO EN (+)", "x2 New item", "L6 XMP Burster", "x0 Turret",
                     "+435 AP", "x1 Turret x2", "x999999 Turret", "x2 Portal S…", "/// x1 Hypercube",
                     "/// x1 Force Amp", "x1 ITO EN Transmuter (−)", "x2 能量塔护盾", "L8 x10 XMP Burster",
                     "8 X2 Resonator", "×3 Portal Shield", "Resonator", "x2 x3", "Box Xmp", "L8 x",
                     "x99999999999999999999 Turret", "x0005 Turret", "L8 x2 Resonator ap", "L8 x2 Media AP",
                     "x1 Heat Sink +", "x1 ITO EN (+) applied", "x1   Portal\tShield  ", "１ x2 Resonator",
                     "五8 x2 Resonator", "x2Turret", "x2", "L 8 x2 Resonator", "L8x2 Resonator",
                     "x999 Turret", "x1000 Turret", "x9999 Turret", "x10000 Turret", "x9223372036854775807 Turret",
                     "x9223372036854775808 Turret"]
        for bars in ["//", "III", "11", "111"] { texts.append("\(bars) x1 Turret") }
        for name in ["Kinetic C...", "Kinetic C…", "Kinetic Cap...", "Kinetic Capsul…", "Kinetic..."] {
            texts.append("// x1 \(name)")
        }
        for name in ["K...", "Kinetic C", "Kinetic Cr...", "Kinetic...Capsule", "Kinetic C......", "ITO EN Tr...",
                     "Portal…", "Unknown...", "Kinetic Capsule", "ITO EN Transmuter", "ITO EN Transmuter ()",
                     "Unknown Media Title", "Quantum Capsule", "Fracker", "Key Locker", "Unknown"] {
            texts.append("x1 \(name)")
        }
        for name in ["Resonator", "XMP Burster", "Power Cube", "Ultra Strike"] {
            for level in 1...8 { texts.append("L\(level) x2 \(name)") }
        }
        for name in ["Portal Key", "Portal Shield", "Turret", "Link Amp", "Multi-Hack", "JARVIS Virus", "Heat Sink",
                     "Kinetic Capsule", "Hypercube", "Force Amp", "ADA Refactor", "Aegis Shield",
                     "SoftBank Ultra Link", "Capsule", "Media", "ITO EN Transmuter (+)", "ITO EN Transmuter (-)"] {
            texts.append("III x2 \(name)")
            texts.append("x1 \(name)")
        }
        return texts
    }()

    // MARK: - Parser scenarios, in every language

    @Test("Entry grammar: every entry text of the oracle tests, at each place and clipping",
          arguments: GameLanguage.allCases)
    func entryGrammar(_ language: GameLanguage) {
        Self.compare("entryGrammar \(language)") { rig in
            let parser = rig.parser(language)
            for text in Self.entryTexts {
                parser.parseEntry(text, row: 0, column: 0)
                parser.parseEntry(text, row: 2, column: 1, clipped: true)
                parser.parseEntry(text, row: 6, column: 0, clipped: false)
            }
            for (row, column) in [(-1, 0), (7, 0), (0, 2), (0, -1)] {
                parser.parseEntry("L6 x8 XMP Burster", row: row, column: column)
            }
        }
    }

    @Test("Item names from each language's own table, whole, shortened and by opening words",
          arguments: GameLanguage.allCases)
    func tableNames(_ language: GameLanguage) {
        Self.compare("tableNames \(language)") { rig in
            let parser = rig.parser(language)
            for table in GameText(language).tables {
                for key in table.items.keys.sorted() {
                    let characters = Array(key)
                    let half = String(characters.prefix(max(1, characters.count / 2)))
                    let most = String(characters.dropLast())
                    for text in ["x2 \(key)", "L5 x2 \(key)", "III x1 \(key)", "x1 \(half)…", "x1 \(most)...",
                                 "x3 \(half)", "x1 \(key) \(key)"] {
                        parser.parseEntry(text, row: 1, column: 0)
                        parser.parseEntry(text, row: 1, column: 1, clipped: true)
                    }
                }
                for words in table.leadingWords.keys.sorted() {
                    parser.parseEntry("x1 \(words)", row: 0, column: 0)
                    parser.parseEntry("x1 \(words)", row: 0, column: 0, clipped: true)
                    parser.parseEntry("x1 \(words)…", row: 0, column: 0)
                }
                for title in [table.bonusTitle, table.bountyTitle] + table.messageFragments {
                    parser.read(lines: [Self.line(title, x: 0.3, y: 0.31), Self.line("L6 x2 XMP Burster")],
                                bounds: Self.bounds, at: 1)
                }
                for suffix in table.effectSuffixes {
                    parser.read(lines: [Self.line("Test location", x: 0.3, y: 0.31),
                                        Self.line("ITO EN (+) \(suffix).", x: 0.28, y: 0.34, width: 0.44),
                                        Self.line("x1 Portal Shield", y: 0.386)], bounds: Self.bounds, at: 1)
                }
                for prefix in table.effectPrefixes {
                    parser.read(lines: [Self.line("Test location", x: 0.3, y: 0.31),
                                        Self.line("\(prefix)ITO EN (-)", x: 0.28, y: 0.34, width: 0.44),
                                        Self.line("x1 Portal Shield", y: 0.386)], bounds: Self.bounds, at: 1)
                }
            }
        }
    }

    @Test("Titles, positions, effect lines and effect rows read the same", arguments: GameLanguage.allCases)
    func panelReads(_ language: GameLanguage) {
        let bounds = Self.bounds
        let line = Self.line
        Self.compare("panelReads \(language)") { rig in
            let parser = rig.parser(language)
            // titles
            let row = line("L6 x2 XMP Burster", 0.1, 0.35, 0.35, 1)
            for title in ["Bonus items:", "Bonvs items:", "Bounty Claimed", "Bounty Clalmed", "奖励物品:",
                          "獎勵物品:", "Test location", "", "Hacking Bonus", "Portal cooldown", "ボーナスアイテム:"] {
                parser.read(lines: [line(title, 0.3, 0.31, 0.35, 1), row], bounds: bounds, at: 1)
            }
            parser.read(lines: [row], bounds: bounds, at: 1)
            parser.read(lines: [line("Bonus items:", 0.1, 0.31, 0.35, 0.2), row], bounds: bounds, at: 1)
            parser.read(lines: [line("Bonus items:", 0.1, 0.31, 0.35, 0.6), row], bounds: bounds, at: 1)
            parser.read(lines: [line("Bonus items:", 0.1, 0.31, 0.35, 1), line("Other", 0.5, 0.31, 0.3, 1), row],
                        bounds: bounds, at: 1)
            // positions
            parser.read(lines: [line("Bonus items:", 0.1, 0.31, 0.35, 1), line("L6 x2 XMP Burster", 0.1, 0.35, 0.35, 1),
                                line("L8 x1 Resonator", 0.58, 0.35, 0.35, 1), line("L5 x30 Resonator", 0.1, 0.386, 0.35, 1),
                                line("L8 x99 Power Cube", 0.1, 0.50, 0.35, 1)], bounds: bounds, at: 0)
            // fragments of one row, out of order, one of them unconfident
            parser.read(lines: [line("Test location", 0.3, 0.31, 0.35, 1), line("XMP Burster", 0.2, 0.35, 0.25, 1),
                                line("L6 x2", 0.1, 0.35, 0.08, 1), line("x1 Turret", 0.58, 0.35, 0.3, 0.4),
                                line("x1 Portal Key", 0.1, 0.386, 0.38, 1), line("x1 Media", 0.6, 0.386, 0.39, 1)],
                        bounds: bounds, at: 2)
            // effect lines
            let effectLines = [line("Test location", 0.3, 0.31, 0.35, 1),
                               line("ITO EN (+) applied.", 0.28, 0.34, 0.44, 1),
                               line("/// x1 Portal Shield", 0.1, 0.386, 0.35, 1),
                               line("L8 x2 Resonator", 0.58, 0.386, 0.35, 1)]
            parser.read(lines: effectLines, bounds: bounds, at: 1)
            parser.read(lines: effectLines + [line("ITO EN (-) applied", 0.28, 0.345, 0.44, 1)], bounds: bounds, at: 1)
            for (text, confidence, y) in [("Secret location applied.", 1.0, 0.34), ("ITO EN (+) applied.", 0.4, 0.34),
                                          ("ITO EN (+) applied.", 1.0, 0.42), ("ITO EN Transmuter (−) applied.", 1.0, 0.34),
                                          ("ito en (-) APPLIED", 1.0, 0.34), ("ITO EN applied.", 1.0, 0.34),
                                          ("ITO EN (+/-) applied.", 1.0, 0.34), ("ITO EN (+) applied. extra", 1.0, 0.34),
                                          ("ITO EN (+) applled.", 1.0, 0.34), ("已使用ITO EN (+)", 1.0, 0.34),
                                          ("ITO EN（＋）已应用。", 1.0, 0.34)] {
                parser.read(lines: [line("Reference panel", 0.3, 0.31, 0.35, 1), line(text, 0.28, y, 0.44, confidence),
                                    line("x1 Portal Shield", 0.1, 0.386, 0.35, 1)], bounds: bounds, at: 0)
            }
            // effect rows
            let tall = GearDropPanelBounds(top: 0.29, bottom: 0.61)
            var lines = [line("Reference panel", 0.3, 0.31, 0.35, 1)]
            for row in 1...6 {
                for column in 0...1 {
                    lines.append(line("L8 x2 Resonator", column == 0 ? 0.1 : 0.58, 0.35 + Double(row) * 0.036, 0.35, 1))
                }
            }
            parser.read(lines: lines, bounds: tall, at: 0.2)
            lines.append(line("ITO EN (+) applied.", 0.28, 0.34, 0.44, 1))
            parser.read(lines: lines, bounds: tall, at: 0)
            for line in lines { parser.position(of: line, in: tall) }
            // a Chinese row the screen reader tests place
            let chinese = GearDropPanelBounds(top: 0.28626, bottom: 0.38321)
            parser.position(of: ResultTextLine(text: "x2 能量塔护盾", confidence: 1, x: 0.20, y: chinese.top + 0.058,
                                               width: 0.24, height: 0.018), in: chinese)
            // lines across the column edge, below the rows, and not finite
            for (x, y, width) in [(0.3, 0.35, 0.25), (0.6, 0.35, 0.39), (0.1, 0.70, 0.3), (0.1, 0.20, 0.3),
                                  (0.49, 0.36, 0.01), (0.5, 0.36, 0.4)] {
                parser.position(of: line("x1 Turret", x, y, width, 1), in: bounds)
            }
            parser.read(lines: [line("Test location", 0.3, 0.31, 0.35, 1), line("x1 Turret", .nan, 0.35, 0.3, 1),
                                line("x1 Media", 0.1, 0.35, .nan, 1), line("x1 Hypercube", 0.6, 0.35, 0.3, .nan)],
                        bounds: bounds, at: 3)
        }
    }

    @Test("Seeded random item rows and panels parse alike", arguments: GameLanguage.allCases)
    func parserFuzz(_ language: GameLanguage) {
        var names = ["XMP Burster", "Resonator", "Portal Shield", "Kinetic Capsule", "ITO EN (+)", "ITO EN Tr…",
                     "Portal S…", "Unknown", "Power Cube", "Heat Sink", "Media", "AP", "能量塔护盾", "ポータルキー"]
        for table in GameText(language).tables { names += table.items.keys.sorted().prefix(12) }
        let prefixes = ["", "L8 ", "L1 ", "15 ", "6 ", "III ", "/// ", "11 ", "L* L7 ", "(*) 1", "5", "\"4 /ll "]
        let markers = ["x", "X", "×", "x ", "*"]
        let quantities = ["1", "2", "30", "999", "1000", "9999", "10000", "0", "007", ""]
        let titles = ["Bonus items:", "Test location", "Bounty Claimed", "奖励物品:", "Bonvs items:", ""]
        let compared = Self.compare("parser fuzz \(language)") { rig in
            var random = SplitMix64(state: 0x6765_6172 &+ UInt64(GameLanguage.allCases.firstIndex(of: language) ?? 0))
            let parser = rig.parser(language)
            func row() -> String {
                var text = random.pick(prefixes) + random.pick(markers) + random.pick(quantities) + " " + random.pick(names)
                if random.chance(15) { text += random.pick(["...", "…", " x2", " +", "  ", "\t"]) }
                return text
            }
            for _ in 0..<2_000 {
                parser.parseEntry(row(), row: random.below(8) - 1 + (random.chance(80) ? 1 : 0), column: random.below(2),
                                  clipped: random.chance(30))
            }
            for time in 0..<300 {
                var lines = [ResultTextLine(text: random.pick(titles), confidence: random.pick([1, 0.6, 0.4]),
                                            x: 0.3, y: 0.31, width: 0.35, height: 0.014)]
                for _ in 0..<random.below(8) {
                    let column = random.below(2)
                    lines.append(ResultTextLine(text: random.chance(10) ? "ITO EN (+) applied." : row(),
                                                confidence: random.pick([1, 0.9, 0.45, 0.2]),
                                                x: (column == 0 ? 0.1 : 0.58) + Double(random.below(5)) * 0.01,
                                                y: 0.33 + Double(random.below(12)) * 0.018,
                                                width: 0.3 + Double(random.below(12)) * 0.01, height: 0.014))
                }
                parser.read(lines: lines, bounds: Self.bounds, at: Double(time))
                for line in lines { parser.position(of: line, in: Self.bounds) }
            }
        }
        print("C++ gear: parser fuzz \(language): \(compared) outputs compared")
    }

    // MARK: - Tracker scenarios

    @Test("Every tracker scenario of the oracle tests")
    func trackerScenarios() {
        let frame = Self.frame
        var compared = 0

        compared += Self.compare("kineticAbbreviation") { rig in
            let parser = rig.parser()
            let tracker = rig.tracker()
            for (time, name) in [(0.0, "Kinetic C..."), (0.2, "Kinetic Capsule")] {
                if let entry = parser.parseEntry("x1 \(name)", row: 2, column: 1) {
                    tracker.accept(.init(sourceTime: time, stage: .bonus, entries: [entry.withRarity(.rare)]))
                }
            }
            tracker.finish(at: 0.3, reason: "test")
        }
        compared += Self.compare("counts") { rig in
            let tracker = rig.tracker()
            for t in [0.0, 0.05, 0.1, 0.2] { tracker.accept(frame(t, .portal, 2, 0)) }
            for t in [0.3, 0.4, 0.6] { tracker.accept(frame(t, .bonus, 6, 0)) }
            tracker.finish(at: 0.7, reason: "test")
            tracker.finish(at: 0.8, reason: "duplicate")
        }
        compared += Self.compare("shortPanel") { rig in
            for times in [[0.0], [0.0, 0.0], [0.0, 0.05]] {
                let tracker = rig.tracker()
                for time in times { tracker.accept(frame(time, .portal, 2, 0)) }
                tracker.finish(at: 0.2, reason: "test")
            }
        }
        for latency in [0.3, 1.6] {
            compared += Self.compare("departureDrainsBonus \(latency)") { rig in
                let tracker = rig.tracker()
                tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.2, .portal, 2, 0))
                tracker.accept(frame(1, .bonus, 6, 0))
                tracker.observe(at: 1.3, panelCandidate: false)
                let completion = 1.2 + latency
                tracker.observe(at: completion, panelCandidate: false, pendingReadSourceTime: 1.2)
                tracker.accept(frame(1.2, .bonus, 6, 0))
                tracker.observe(at: completion + 0.05, panelCandidate: false)
            }
        }
        compared += Self.compare("boundedCompletionWait") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.2, .portal, 2, 0))
            tracker.observe(at: 0.3, panelCandidate: false)
            tracker.observe(at: 0.5, panelCandidate: false, pendingReadSourceTime: 0.25)
            tracker.observe(at: 2.3, panelCandidate: false, pendingReadSourceTime: 0.25)
            tracker.accept(frame(0.25, .bonus, 2, 0))
            tracker.accept(frame(3, .portal, 2, 0))
            tracker.observe(at: 3.2, panelCandidate: false, continuityLost: true, pendingReadSourceTime: 3.1)
            tracker.accept(frame(3.1, .bonus, 2, 0))
        }
        for pending in [false, true] {
            compared += Self.compare("pendingDoesNotMergePortalDrops \(pending)") { rig in
                func resonator(_ time: Double) -> GearDropFrameEvidence {
                    .init(sourceTime: time, stage: .portal, entries: [
                        .init(column: 0, row: 0, item: "Resonator", levelState: .known, level: 6, quantity: 2)
                    ])
                }
                let tracker = rig.tracker()
                tracker.accept(resonator(0)); tracker.accept(resonator(0.1))
                tracker.observe(at: 0.2, panelCandidate: false)
                tracker.observe(at: 0.4, panelCandidate: false, pendingReadSourceTime: pending ? 0.15 : nil)
                tracker.observe(at: 1.7, panelCandidate: true, pendingReadSourceTime: pending ? 0.15 : nil)
                tracker.accept(frame(1.7, .portal, 5, 0))
                tracker.accept(frame(1.9, .portal, 5, 0))
                tracker.finish(at: 2, reason: "test")
            }
        }
        for source in [0.2, 0.3] {
            compared += Self.compare("pendingOutsideDeparture \(source)") { rig in
                let tracker = rig.tracker()
                tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.1, .portal, 2, 0))
                tracker.observe(at: 0.2, panelCandidate: false)
                tracker.observe(at: 0.4, panelCandidate: false, pendingReadSourceTime: source)
            }
        }
        compared += Self.compare("completionPreservesDeparture") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.1, .portal, 2, 0))
            tracker.observe(at: 0.2, panelCandidate: false)
            tracker.observe(at: 0.4, panelCandidate: false, pendingReadSourceTime: 0.15)
            tracker.accept(frame(0.15, .portal, 2, 0))
            tracker.observe(at: 1.7, panelCandidate: true)
        }
        compared += Self.compare("completionAfterDeparture") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.1, .portal, 2, 0))
            tracker.observe(at: 0.2, panelCandidate: false)
            tracker.observe(at: 0.4, panelCandidate: false, pendingReadSourceTime: 0.15)
            tracker.accept(frame(1.7, .portal, 5, 0))
            tracker.accept(frame(1.9, .portal, 5, 0))
            tracker.finish(at: 2, reason: "test")
        }
        compared += Self.compare("transientAbsence") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.1, .portal, 2, 0))
            tracker.observe(at: 0.2, panelCandidate: false)
            tracker.observe(at: 0.25, panelCandidate: true, pendingReadSourceTime: 0.15)
            tracker.accept(frame(0.3, .portal, 2, 0))
            tracker.finish(at: 0.4, reason: "test")
        }
        for latency in [0.025, 0.3, 0.5] {
            compared += Self.compare("delayedLaneKeepsGroupsSeparate \(latency)") { rig in
                let tracker = rig.tracker()
                tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.1, .portal, 2, 0))
                var pending: (readyAt: Double, evidence: GearDropFrameEvidence)? = (0.15 + latency, frame(0.15, .portal, 2, 0))
                var lastSubmission = -Double.infinity
                for tick in 4...28 {
                    let time = Double(tick) * 0.05
                    if let ready = pending, time + 1e-9 >= ready.readyAt {
                        tracker.accept(ready.evidence)
                        pending = nil
                    }
                    let visible = time >= 0.4 && time < 1.2
                    tracker.observe(at: time, panelCandidate: visible, pendingReadSourceTime: pending?.evidence.sourceTime)
                    if visible, pending == nil, time - lastSubmission >= 0.2 - 1e-9 {
                        pending = (time + 0.025, frame(time, .portal, 5, 0))
                        lastSubmission = time
                    }
                }
                tracker.finish(at: 1.5, reason: "test")
            }
        }
        compared += Self.compare("lateShieldContradiction") { rig in
            func shield(_ time: Double, quantity: Int) -> GearDropFrameEvidence {
                .init(sourceTime: time, stage: .bonus, entries: [
                    .init(column: 0, row: 0, item: "Portal Shield", levelState: .notApplicable,
                          level: nil, quantity: quantity, rarity: .common)
                ])
            }
            let tracker = rig.tracker()
            for (time, quantity) in [(387.157, 1), (387.457, 11), (387.757, 11)] {
                tracker.accept(shield(time, quantity: quantity))
            }
            tracker.observe(at: 388.357, panelCandidate: false)
            tracker.observe(at: 388.507, panelCandidate: false, pendingReadSourceTime: 388.307)
            tracker.accept(shield(388.307, quantity: 1))
            tracker.finish(at: 388.6, reason: "test")
        }
        compared += Self.compare("conflicts") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.1, .portal, 2, 0))
            tracker.accept(frame(0.2, .portal, 8, 0))
            tracker.finish(at: 0.3, reason: "test")
            let late = 1 + GearDropTracker.Policy().maximumReadingGap + 0.1
            tracker.accept(frame(1, .portal, 2, 0)); tracker.accept(frame(late, .portal, 2, 0))
            tracker.finish(at: late + 0.1, reason: "test")
        }
        compared += Self.compare("slowBonusReads") { rig in
            let tracker = rig.tracker()
            tracker.accept(Self.reportedPanel(40.240, stage: .bonus))
            tracker.accept(Self.reportedPanel(41.149, stage: .bonus))
            tracker.finish(at: 41.850, reason: "panelLeft")
        }
        compared += Self.compare("slowReadsOfReportedDrop") { rig in
            let tracker = rig.tracker()
            let reads: [(Double, GearDropStage)] = [(38.113, .unknown), (38.814, .portal), (39.264, .unknown),
                                                    (39.414, .portal), (40.240, .bonus), (41.149, .bonus)]
            var pending = reads[...]
            for step in 0..<80 {
                let time = 38.1 + Double(step) * 0.05
                while let read = pending.first, read.0 <= time + 1e-9 {
                    tracker.accept(read.1 == .unknown ? GearDropFrameEvidence(sourceTime: read.0, stage: .unknown)
                                                      : Self.reportedPanel(read.0, stage: read.1))
                    pending = pending.dropFirst()
                }
                tracker.observe(at: time, panelCandidate: time < 41.7)
            }
        }
        compared += Self.compare("adjacentGroups") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.1, .portal, 2, 0))
            tracker.accept(frame(0.2, .bonus, 2, 0)); tracker.accept(frame(0.3, .bonus, 2, 0))
            tracker.accept(frame(0.4, .portal, 2, 0))
            tracker.accept(frame(0.5, .portal, 2, 0))
            tracker.finish(at: 0.6, reason: "test")
        }
        compared += Self.compare("incomplete") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 1)); tracker.accept(frame(0.1, .portal, 2, 1))
            tracker.finish(at: 0.2, reason: "test")
        }
        compared += Self.compare("gap") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 0))
            tracker.observe(at: 2, panelCandidate: true, continuityLost: true)
        }
        compared += Self.compare("lostDetail") { rig in
            func weak(_ time: Double) -> GearDropFrameEvidence {
                .init(sourceTime: time, stage: .bonus, entries: [
                    GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .unreadable, level: nil, quantity: 2)
                ])
            }
            let tracker = rig.tracker()
            for t in [0.0, 0.25, 0.5] { tracker.accept(frame(t, .bonus, 2, 0)) }
            tracker.accept(weak(0.75))
            tracker.accept(frame(1.0, .bonus, 2, 0))
            tracker.accept(weak(1.25))
            tracker.finish(at: 1.4, reason: "test")
            let second = rig.tracker()
            second.accept(frame(0, .bonus, 2, 0))
            second.accept(weak(0.25)); second.accept(weak(0.5))
            second.finish(at: 0.6, reason: "test")
        }
        compared += Self.compare("conflictResolves") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(0.25, .portal, 2, 0))
            tracker.accept(frame(0.5, .portal, 8, 0))
            tracker.accept(frame(0.75, .portal, 2, 0))
            tracker.finish(at: 0.8, reason: "test")
            let twice = rig.tracker()
            for (t, q) in [(0.0, 2), (0.25, 2), (0.5, 8), (0.75, 8)] { twice.accept(frame(t, .portal, q, 0)) }
            twice.finish(at: 0.8, reason: "test")
        }
        compared += Self.compare("conflictSupport") { rig in
            // GearConflictSupportTests: support settles a contradiction only
            // with a clear margin; every read's settled state is compared.
            for quantities in [[2, 2, 2, 2, 21, 21, 2, 2], [21, 21, 2, 2, 2, 2], [2, 2, 2, 2, 21, 21],
                               [2, 21, 2, 21, 21, 2, 2, 2, 2, 2], [2, 2, 21, 21], [2, 2, 2, 21, 21],
                               [2, 2, 2, 21], [2, 2, 21], [2, 2, 2, 21, 21, 21]] {
                let tracker = rig.tracker()
                for (index, quantity) in quantities.enumerated() {
                    tracker.accept(.init(sourceTime: Double(index) * 0.2, stage: .portal, entries: [
                        .init(column: 0, row: 0, item: "Portal Shield", levelState: .notApplicable, level: nil,
                              quantity: quantity, rarity: index == 0 ? .unreadable : .common, multiplied: true)
                    ], effects: [index % 3 == 2 ? "ITO EN (-)" : "ITO EN (+)"]))
                }
                tracker.finish(at: Double(quantities.count) * 0.2, reason: "test")
            }
        }
        compared += Self.compare("missingDetailDoesNotVote") { rig in
            func weak(_ time: Double) -> GearDropFrameEvidence {
                .init(sourceTime: time, stage: .portal, entries: [
                    GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .unreadable, level: nil, quantity: 2)
                ])
            }
            let late = GearDropTracker.Policy().maximumReadingGap + 0.1
            for supportingTimes in [[0.0, 0.05], [0.0, late]] {
                let tracker = rig.tracker()
                for time in (supportingTimes + [0.2, 0.3, late / 2]).sorted() {
                    tracker.accept(supportingTimes.contains(time) ? frame(time, .portal, 2, 0) : weak(time))
                }
                tracker.finish(at: late + 0.1, reason: "test")
            }
        }
        compared += Self.compare("effectLine") { rig in
            let parser = rig.parser()
            let lines = [Self.line("Test location", x: 0.3, y: 0.31),
                         Self.line("ITO EN (+) applied.", x: 0.28, y: 0.34, width: 0.44),
                         Self.line("/// x1 Portal Shield", y: 0.386), Self.line("L8 x2 Resonator", x: 0.58, y: 0.386)]
            let tracker = rig.tracker()
            tracker.accept(parser.read(lines: lines, bounds: Self.bounds, at: 1))
            tracker.accept(parser.read(lines: lines, bounds: Self.bounds, at: 1.25))
            tracker.finish(at: 1.4, reason: "test")
        }
        compared += Self.compare("effectRows") { rig in
            let parser = rig.parser()
            let tall = GearDropPanelBounds(top: 0.29, bottom: 0.61)
            var lines = [Self.line("Reference panel", x: 0.3, y: 0.31)]
            for row in 1...6 {
                for column in 0...1 {
                    lines.append(Self.line("L8 x2 Resonator", x: column == 0 ? 0.1 : 0.58, y: 0.35 + Double(row) * 0.036))
                }
            }
            let plain = parser.read(lines: lines, bounds: tall, at: 0.2)
            lines.append(Self.line("ITO EN (+) applied.", x: 0.28, y: 0.34, width: 0.44))
            let withEffect = parser.read(lines: lines, bounds: tall, at: 0)
            let tracker = rig.tracker()
            tracker.accept(withEffect)
            tracker.accept(plain)
            tracker.accept(parser.read(lines: lines, bounds: tall, at: 0.3))
            tracker.finish(at: 0.4, reason: "test")
        }
        compared += Self.compare("effectAgreement") { rig in
            func reading(_ time: Double, _ effect: String?, stage: GearDropStage = .portal) -> GearDropFrameEvidence {
                .init(sourceTime: time, stage: stage, entries: frame(time, .portal, 2, 0).entries,
                      effects: effect.map { [$0] })
            }
            let plus = "ITO EN (+)", minus = "ITO EN (-)"
            let late = GearDropTracker.Policy().maximumReadingGap + 0.1
            for reads: [(Double, String?)] in [[(0, plus), (0.2, nil)], [(0, plus), (0.05, plus), (0.2, nil)],
                                              [(0, plus), (late, plus)], [(0, plus), (0.2, minus)],
                                              [(0, plus), (0.2, plus), (0.3, minus), (0.5, minus)]] {
                let tracker = rig.tracker()
                for (time, effect) in reads { tracker.accept(reading(time, effect)) }
                tracker.finish(at: late + 0.1, reason: "test")
            }
            let tracker = rig.tracker()
            tracker.accept(reading(0, plus)); tracker.accept(reading(0.2, plus))
            tracker.accept(reading(0.3, nil))
            tracker.accept(reading(0.4, nil, stage: .bonus)); tracker.accept(reading(0.6, nil, stage: .bonus))
            tracker.finish(at: 0.7, reason: "test")
        }
        // Quantity colour votes (GearQuantityColorTests).
        func coloured(_ reads: [(Double, Int, Bool?)]) -> (Rig) -> Void {
            { rig in
                let tracker = rig.tracker()
                for (time, quantity, multiplied) in reads {
                    tracker.accept(.init(sourceTime: time, stage: .portal, entries: [
                        GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .known, level: 8,
                                      quantity: quantity, multiplied: multiplied)
                    ]))
                }
                tracker.finish(at: 1, reason: "test")
            }
        }
        for reads: [(Double, Int, Bool?)] in [[(0, 2, true), (0.1, 2, true)], [(0, 2, false), (0.1, 2, false)],
                                              [(0, 2, true), (0.1, 2, nil)], [(0, 2, true), (0.1, 2, false), (0.2, 2, true)],
                                              [(0, 1, false), (0.05, 1, false), (0.3, 2, true), (0.4, 2, true), (0.5, 2, nil)]] {
            compared += Self.compare("colour votes \(reads.map(\.0))", coloured(reads))
        }
        // Rarity votes (GearRarityTests).
        func shieldFrame(_ time: Double, rarity: GearDropEntry.Rarity?, row: Int = 0) -> GearDropFrameEvidence {
            .init(sourceTime: time, stage: .portal, entries: [
                .init(column: 0, row: row, item: "Portal Shield", levelState: .notApplicable, level: nil,
                      quantity: 2, rarity: rarity)])
        }
        compared += Self.compare("rarity agreement") { rig in
            let late = GearDropTracker.Policy().maximumReadingGap + 0.1
            for times in [[0.0], [0.0, 0.05], [0.0, late]] {
                let tracker = rig.tracker()
                for time in (times + [0.5, 0.7]).sorted() {
                    tracker.accept(shieldFrame(time, rarity: times.contains(time) ? .veryRare : .unreadable))
                }
                tracker.finish(at: late + 0.1, reason: "test")
            }
            let tracker = rig.tracker()
            tracker.accept(shieldFrame(0, rarity: .rare)); tracker.accept(shieldFrame(0.2, rarity: .rare))
            tracker.accept(shieldFrame(0.4, rarity: .unreadable))
            tracker.finish(at: 0.5, reason: "test")
        }
        compared += Self.compare("rarity conflicts") { rig in
            let tracker = rig.tracker()
            for (time, rarity) in [(0.0, GearDropEntry.Rarity.rare), (0.2, .rare), (0.4, .veryRare), (0.6, .veryRare)] {
                tracker.accept(shieldFrame(time, rarity: rarity))
            }
            tracker.finish(at: 0.7, reason: "test")
        }
        compared += Self.compare("rarity distinctRows") { rig in
            let tracker = rig.tracker()
            for time in [0.0, 0.2] {
                tracker.accept(.init(sourceTime: time, stage: .portal,
                    entries: shieldFrame(time, rarity: .rare).entries + shieldFrame(time, rarity: .veryRare, row: 1).entries))
            }
            tracker.finish(at: 0.3, reason: "test")
        }
        for item in ["Aegis Shield", "Hypercube", "ADA Refactor", "JARVIS Virus", "SoftBank Ultra Link",
                     "ITO EN Transmuter (+)", "ITO EN Transmuter (-)", "Turret", "Force Amp"] {
            compared += Self.compare("fixedRarityIdentity \(item)") { rig in
                let parser = rig.parser()
                guard let entry = parser.parseEntry("x1 \(item)", row: 0, column: 0) else { return }
                for name in ["Portal Shield", "Heat Sink", "Multi-Hack", "Link Amp", "Kinetic Capsule", "Capsule", "Unknown"] {
                    parser.parseEntry("x1 \(name)", row: 0, column: 0)
                }
                for times in [[0.0], [0.0, 0.05], [0.0, 0.2]] {
                    let tracker = rig.tracker()
                    for time in times { tracker.accept(.init(sourceTime: time, stage: .bonus, entries: [entry])) }
                    tracker.finish(at: 0.3, reason: "test")
                }
            }
        }
        // The capture-rate panels, driven by the shared Swift text schedule.
        func shortPanel(duration: Double, interval: Double, latency: Double) -> (Rig) -> Void {
            { rig in
                var schedule = GameTextSchedule()
                let tracker = rig.tracker()
                var pending: GameTextSchedule.Request?
                for step in 0..<Int((duration + 1) / interval) {
                    let time = Double(step) * interval
                    let visible = time < duration
                    if let request = pending, request.sourceTime + latency <= time + 1e-9 {
                        schedule.finish(request, panelPresent: true)
                        tracker.accept(frame(request.sourceTime, .portal, 2, 0))
                        pending = nil
                    }
                    tracker.observe(at: time, panelCandidate: visible)
                    if visible, let request = schedule.take(at: time, panelCandidate: false, resultEligible: false,
                                                            gearCandidate: true, readsHeader: false) {
                        pending = request
                    }
                }
            }
        }
        for latency in [0.05, 0.15, 0.25] {
            compared += Self.compare("shortPanelAtCaptureRate \(latency)",
                                     shortPanel(duration: 0.4, interval: 0.05, latency: latency))
        }
        compared += Self.compare("shortPanelSlowReads 0.6", shortPanel(duration: 0.6, interval: 0.05, latency: 0.35))
        compared += Self.compare("shortPanelSlowReads 0.4", shortPanel(duration: 0.4, interval: 0.05, latency: 0.35))
        // Non-finite times and policies other than the default.
        compared += Self.compare("non-finite times") { rig in
            let tracker = rig.tracker()
            tracker.accept(frame(.nan, .portal, 2, 0)); tracker.accept(frame(.infinity, .portal, 2, 0))
            tracker.accept(frame(0, .portal, 2, 0)); tracker.accept(frame(-.infinity, .portal, 2, 0))
            tracker.observe(at: .nan, panelCandidate: false); tracker.observe(at: 0.1, panelCandidate: false,
                                                                              pendingReadSourceTime: .nan)
            tracker.finish(at: .nan, reason: "test"); tracker.loseContinuity(at: .infinity)
            tracker.finish(at: 0.2, reason: "test")
        }
        compared += Self.compare("custom policy") { rig in
            var policy = GearDropTracker.Policy()
            policy.minimumSpan = 0.3; policy.departureSpan = 0.5; policy.groupLimit = 1; policy.maximumReadingGap = 0.25
            let tracker = rig.tracker(policy: policy)
            for t in stride(from: 0.0, through: 2.0, by: 0.1) {
                tracker.accept(frame(t, t < 1 ? .portal : .bonus, 2, 0))
                tracker.observe(at: t + 0.05, panelCandidate: t < 1.6, pendingReadSourceTime: t)
            }
            tracker.finish(at: 3, reason: "test")
        }
        print("C++ gear: tracker scenarios compared \(compared) outputs")
    }

    /// A reported drop (GearDropRecognitionTests.reportedPanel).
    static func reportedPanel(_ time: Double, stage: GearDropStage) -> GearDropFrameEvidence {
        func entry(_ column: Int, _ row: Int, _ item: String, _ level: Int?, _ quantity: Int) -> GearDropEntry {
            .init(column: column, row: row, item: item, levelState: level == nil ? .notApplicable : .known,
                  level: level, quantity: quantity)
        }
        let entries = stage == .portal
            ? [entry(0, 0, "Portal Key", nil, 1), entry(1, 0, "Resonator", 7, 4)]
            : [entry(0, 0, "Portal Key", nil, 1), entry(1, 0, "Power Cube", 7, 1),
               entry(0, 1, "XMP Burster", 8, 1), entry(1, 1, "XMP Burster", 7, 3),
               entry(0, 2, "Resonator", 8, 2), entry(1, 2, "Resonator", 7, 3),
               entry(0, 3, "Resonator", 6, 1)]
        return .init(sourceTime: time, stage: stage, entries: entries, unreadableRows: 0)
    }

    // MARK: - Session, schedule and display scenarios

    @Test("Every session, schedule and display scenario of the oracle tests")
    func sessionScenarios() {
        let frame = Self.frame
        var compared = 0

        compared += Self.compare("queueAfterActualInput") { rig in
            let session = rig.session()
            session.observe(at: 9.7, hackID: 1, inputVisible: true, inputPhase: .presenting)
            session.observe(at: 9.78, hackID: 1, inputVisible: false, inputPhase: .presenting)
            session.observe(at: 10.39, hackID: 1, inputVisible: true, inputPhase: .input)
            session.observe(at: 16.24, hackID: 1, inputVisible: false, inputPhase: .completed)
        }
        compared += Self.compare("queue") { rig in
            let session = rig.session()
            for id in 1...3 { session.enqueue(hackID: id, at: Double(id)) }
            let tracker = rig.tracker()
            tracker.accept(frame(4, .portal, 2, 0)); tracker.accept(frame(4.1, .bonus, 2, 0))
            if let group = tracker.finish(at: 4.2, reason: "test") { session.close(group) }
        }
        compared += Self.compare("serverWait") { rig in
            let session = rig.session()
            session.observe(at: 0, hackID: 1, inputVisible: true)
            for t in stride(from: 0.5, through: 55, by: 0.5) {
                session.observe(at: t, hackID: 1, inputVisible: false, gameProgressVisible: true)
            }
            for t in stride(from: 55.5, through: 84, by: 0.5) { session.observe(at: t, hackID: 1, inputVisible: false) }
            for t in stride(from: 84.5, through: 86, by: 0.5) { session.observe(at: t, hackID: 1, inputVisible: false) }
        }
        compared += Self.compare("expiredQueueDoesNotShift") { rig in
            for explicitExpiry in [false, true] {
                let session = rig.session()
                session.enqueue(hackID: 1, at: 0)
                session.enqueue(hackID: 2, at: 110)
                if explicitExpiry { session.expire(at: 121) }
                let tracker = rig.tracker()
                tracker.accept(frame(122, .portal, 2, 0)); tracker.accept(frame(122.2, .portal, 2, 0))
                tracker.accept(frame(123, .bonus, 2, 0)); tracker.accept(frame(123.2, .bonus, 2, 0))
                guard let group = tracker.finish(at: 125, reason: "panelLeft") else { continue }
                session.close(group)
                session.expire(at: 150)
                session.enqueue(hackID: 3, at: 151)
                session.close(GearDropSummary(groupID: 2, startedAt: 152, closedAt: 153, closeReason: "panelLeft",
                                              hackID: nil, association: .unassociated, panels: group.panels))
            }
        }
        compared += Self.compare("gapOwnership") { rig in
            let session = rig.session()
            let tracker = rig.tracker()
            session.enqueue(hackID: 1, at: 0)
            session.prepareFrame(at: 0, continuityLost: false)
            for time in [0.0, 0.2] { tracker.accept(frame(time, .portal, 2, 0)) }
            for time in [0.4, 0.6] { tracker.accept(frame(time, .bonus, 2, 0)) }
            session.prepareFrame(at: 0.6, continuityLost: false)
            session.prepareFrame(at: 2, continuityLost: true)
            if let group = tracker.loseContinuity(at: 2) { session.close(group) }
            tracker.accept(frame(0.8, .portal, 2, 0))
            tracker.accept(frame(2.1, .bonus, 8, 0))
            tracker.accept(frame(2.3, .bonus, 8, 0))
            tracker.finish(at: 2.4, reason: "panelLeft")
            let empty = rig.tracker()
            empty.loseContinuity(at: 2)
            empty.accept(frame(0.8, .portal, 2, 0))
        }
        compared += Self.compare("evidenceBudgets") { rig in
            for bonusDuration in [0.4, 1.8] {
                let schedule = rig.schedule()
                for index in 0..<Int((1.8 + bonusDuration) / 0.2) {
                    let time = Double(index) * 0.2
                    let stage: GearDropStage = index < 9 ? .portal : .bonus
                    if schedule.shouldSave(stage: stage, at: time) { schedule.didEnqueue(stage: stage, at: time) }
                }
            }
            let schedule = rig.schedule()
            for time in [0.0, 0.5, 1.0, 1.5] { schedule.didEnqueue(stage: .portal, at: time) }
            schedule.shouldSave(stage: .portal, at: 2)
            schedule.shouldSave(stage: .bonus, at: 1.6)
            schedule.shouldSave(stage: .bonus, at: 1.7)
            for stage in [GearDropStage.absent, .unknown, .excluded, .unsupported] {
                schedule.shouldSave(stage: stage, at: 5); schedule.didEnqueue(stage: stage, at: 5)
            }
            schedule.shouldSave(stage: .bonus, at: .nan); schedule.didEnqueue(stage: .bonus, at: .infinity)
        }
        compared += Self.compare("groupsWithoutBonus") { rig in
            func group(bonus: Bool, at time: Double) -> GearDropSummary? {
                let tracker = rig.tracker()
                tracker.accept(frame(time, .portal, 2, 0)); tracker.accept(frame(time + 0.25, .portal, 2, 0))
                if bonus {
                    tracker.accept(frame(time + 0.5, .bonus, 2, 0)); tracker.accept(frame(time + 0.75, .bonus, 2, 0))
                }
                return tracker.finish(at: time + 1, reason: "test")
            }
            let session = rig.session()
            session.enqueue(hackID: 7, at: 0); session.accept(Self.result(hack: 7, bonus: 0))
            session.enqueue(hackID: 8, at: 1); session.accept(Self.result(hack: 8, bonus: 120))
            session.accept(Self.result(hack: 9, bonus: 50))
            for (bonus, time) in [(false, 2.0), (false, 4.0), (true, 6.0), (true, 8.0)] {
                if let closed = group(bonus: bonus, at: time) { session.close(closed) }
            }
        }
        compared += Self.compare("orderRestored") { rig in
            let session = rig.session()
            var now = 0.0
            func frames(until end: Double, hack: Int = 0, input: Bool = false) {
                while now < end { now += 0.5; session.observe(at: now, hackID: hack, inputVisible: input) }
            }
            frames(until: 1, hack: 1, input: true); frames(until: 40)
            frames(until: 75)
            frames(until: 80, hack: 2, input: true); frames(until: 85)
            let tracker = rig.tracker()
            tracker.accept(frame(now, .portal, 2, 0)); tracker.accept(frame(now + 0.25, .portal, 2, 0))
            tracker.accept(frame(now + 0.5, .bonus, 2, 0)); tracker.accept(frame(now + 0.75, .bonus, 2, 0))
            if let group = tracker.finish(at: now + 1, reason: "panelLeft") { session.close(group) }
        }
        compared += Self.compare("stillScreen") { rig in
            let session = rig.session()
            session.enqueue(hackID: 1, at: 0)
            session.prepareFrame(at: 0, continuityLost: false)
            session.prepareFrame(at: 2, continuityLost: false)
            session.prepareFrame(at: 1, continuityLost: false)
            let idle = rig.session()
            idle.prepareFrame(at: 5, continuityLost: true)
            idle.prepareFrame(at: .nan, continuityLost: true)
        }
        compared += Self.compare("queueLimit") { rig in
            var policy = GearDropObservationSession.Policy()
            policy.maximumWaiting = 3
            let session = rig.session(policy: policy)
            for id in [1, 2, 2, 0, -4, 3, 4, 5] { session.enqueue(hackID: id, at: Double(id)) }
            session.enqueue(hackID: 6, at: .nan)
            session.invalidate(at: 9, reason: "captureStopped")
            session.enqueue(hackID: 7, at: 10)
            session.invalidate(at: 11, reason: "endOfStream")
        }
        // GearDropDisplayTests.
        func displayGroup(hackID: Int? = 1, partial: Bool = false) -> GearDropSummary {
            let entry = GearDropEntry(column: 0, row: 0, item: "Hypercube", levelState: .notApplicable, level: nil, quantity: 2)
            return GearDropSummary(groupID: 1, startedAt: 2, closedAt: 4, closeReason: "panelLeft", hackID: hackID,
                association: hackID == nil ? .uncertainContinuity : .ordered,
                panels: [.init(stage: .portal, entries: [entry], partial: partial),
                         .init(stage: .bonus, entries: [entry], partial: false)])
        }
        compared += Self.compare("display lifecycle") { rig in
            let queue = rig.session()
            let display = rig.display()
            display.update(waiting: [], reading: false, associationUncertain: false, at: 0)
            queue.enqueue(hackID: 1, at: 0); queue.enqueue(hackID: 2, at: 1)
            display.update(waiting: queue.waiting, reading: false, associationUncertain: false, at: 1)
            display.update(waiting: queue.waiting, reading: false, associationUncertain: false, at: 1.1)
            display.update(waiting: queue.waiting, reading: true, associationUncertain: false, at: 2)
            display.finished(queue.close(displayGroup()))
            for time in [4.0, 4.05, 4.4, 5, 7.9] {
                display.update(waiting: queue.waiting, reading: true, associationUncertain: false, at: time)
            }
            display.update(waiting: queue.waiting, reading: false, associationUncertain: false, at: 8)
            display.ended(hackID: 2, at: 9)
            display.update(waiting: [], reading: false, associationUncertain: false, at: 9)
            display.update(waiting: [], reading: false, associationUncertain: false, at: 13)
        }
        compared += Self.compare("display uncertainty") { rig in
            let display = rig.display()
            display.finished(displayGroup(partial: true))
            display.update(waiting: [], reading: false, associationUncertain: false, at: 4)
            display.finished(displayGroup(hackID: nil))
            display.ended(hackID: 1, at: 4)
            display.update(waiting: [], reading: false, associationUncertain: true, at: 4)
        }
        compared += Self.compare("display standalone") { rig in
            let display = rig.display(standalone: true)
            display.update(waiting: [], reading: false, associationUncertain: false, at: 0)
            let entry = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 8, quantity: 3)
            display.finished(GearDropSummary(groupID: 1, startedAt: 2, closedAt: 4, closeReason: "panelLeft", hackID: nil,
                association: .noWaitingHack, panels: [.init(stage: .portal, entries: [entry], partial: false)]))
            display.update(waiting: [], reading: false, associationUncertain: false, at: 4)
            display.update(waiting: [], reading: false, associationUncertain: false, at: 8.5)
            display.finished(GearDropSummary(groupID: 2, startedAt: 8, closedAt: 9, closeReason: "panelLeft", hackID: nil,
                association: .noWaitingHack, panels: [.init(stage: .portal, entries: [entry], partial: true)]))
            display.update(waiting: [], reading: false, associationUncertain: false, at: 9)
            display.update(waiting: [], reading: false, associationUncertain: false, at: 13.5)
        }
        print("C++ gear: session, schedule and display scenarios compared \(compared) outputs")
    }

    // MARK: - Held Bonus panels and repeated Bonus groups

    /// `GearDropAssociationTests.groups` through one arm: frames at 20 Hz, a
    /// completed read taken before the frame's geometry.
    static func playAssociation(_ rig: Rig, _ reads: [GearDropAssociationTests.Read],
                                policy: GearDropTracker.Policy = .init()) -> [GearDropSummary] {
        let tracker = rig.tracker(policy: policy)
        var pending = reads[...]
        var closed: [GearDropSummary] = []
        for step in 0..<200 {
            let time = 123347.797013 + Double(step) * 0.05
            while let read = pending.first, read.time + read.latency <= time {
                if let group = tracker.accept(read.evidence) { closed.append(group) }
                pending = pending.dropFirst()
            }
            let inFlight = pending.first.flatMap { $0.time <= time ? $0.time : nil }
            if let group = tracker.observe(at: time, panelCandidate: GearDropAssociationTests.panelShown(at: time),
                                           pendingReadSourceTime: inFlight) { closed.append(group) }
        }
        if let group = tracker.finish(at: 123400, reason: "endOfStream") { closed.append(group) }
        return closed
    }

    /// `GearDropBonusHoldTests.play` through one arm.
    static func playHold(_ rig: Rig, _ reads: [GearDropFrameEvidence], shown: (Int) -> Bool, frames: Int = 120,
                         continuityLostAt lost: Int? = nil, policy: GearDropTracker.Policy = .init()) -> [GearDropSummary] {
        let tracker = rig.tracker(policy: policy)
        var pending = reads[...]
        var closed: [GearDropSummary] = []
        for frame in 0...frames {
            let now = GearDropBonusHoldTests.time(frame)
            while let read = pending.first, read.sourceTime + 0.05 <= now + 1e-9 {
                if let group = tracker.accept(read) { closed.append(group) }
                pending = pending.dropFirst()
            }
            let inFlight = pending.first.flatMap { $0.sourceTime <= now ? $0.sourceTime : nil }
            if let group = tracker.observe(at: now, panelCandidate: shown(frame), continuityLost: frame == lost,
                                           pendingReadSourceTime: inFlight) { closed.append(group) }
        }
        if let group = tracker.finish(at: GearDropBonusHoldTests.time(frames + 1), reason: "endOfStream") {
            closed.append(group)
        }
        return closed
    }

    /// Closes `groups` into a session with two hacks waiting, and a display, as
    /// the association tests do.
    static func attach(_ rig: Rig, _ groups: [GearDropSummary], policy: GearDropObservationSession.Policy = .init(),
                       waits: [(Int, Double)] = [(1, 123327.835325125), (2, 123344.138057541)]) {
        let session = rig.session(policy: policy)
        let display = rig.display()
        for (hack, time) in waits { session.enqueue(hackID: hack, at: time) }
        for group in groups {
            let attached = session.close(group)
            display.finished(attached)
            display.update(waiting: session.waiting, reading: false, associationUncertain: false,
                           at: attached.closedAt)
        }
    }

    @Test("Every held-Bonus, found-again and repeated-Bonus scenario of the oracle tests, and other windows")
    func heldBonusScenarios() {
        typealias Association = GearDropAssociationTests
        typealias Hold = GearDropBonusHoldTests
        var compared = 0
        var trackerWindows: [GearDropTracker.Policy] = [.init()]
        for window in [0.0, 0.5, 1.2, 5.0] {
            var policy = GearDropTracker.Policy(); policy.bonusReturnWindow = window; trackerWindows.append(policy)
        }
        for (index, policy) in trackerWindows.enumerated() {
            let readSets: [(String, [Association.Read])] = [
                ("refound", Association.reads()),
                ("refoundUnread", Association.reads(refound: [], refoundUnreadable: 3)),
                ("refoundOther", Association.reads(refound: [Association.item(0, 0, "Turret", level: nil, 1)])),
            ]
            for (name, reads) in readSets {
                compared += Self.compare("association \(name) window \(index)") { rig in
                    Self.attach(rig, Self.playAssociation(rig, reads, policy: policy))
                }
            }
            let holds: [(String, [GearDropFrameEvidence], (Int) -> Bool, Int?)] = [
                ("joins", [Hold.portal(0), Hold.portal(4), Hold.bonus(20), Hold.bonus(52)],
                 { $0 < 30 || (52..<56).contains($0) }, nil),
                ("onScreenGap", [Hold.bonus(2), Hold.bonus(36)], { $0 < 30 || (36..<40).contains($0) }, nil),
                ("portalNeverJoins", [Hold.portal(0), Hold.portal(4), Hold.bonus(20), Hold.portal(52, quantity: 2),
                                      Hold.portal(56, quantity: 2)], { $0 < 30 || (52..<70).contains($0) }, nil),
                ("windowPasses", [Hold.portal(0), Hold.portal(4), Hold.bonus(20)], { $0 < 30 }, nil),
                ("confirmedClosesAtOnce", [Hold.portal(0), Hold.portal(4), Hold.bonus(20), Hold.bonus(24)],
                 { $0 < 30 }, nil),
                ("continuityLostWhileHeld", [Hold.portal(0), Hold.portal(4), Hold.bonus(20)], { $0 < 30 }, 40),
                ("confirmedThenFoundAgain", [Hold.portal(0), Hold.portal(4), Hold.bonus(20), Hold.bonus(24),
                                             Hold.bonus(52, [], unreadable: 2)],
                 { $0 < 30 || (52..<56).contains($0) }, nil),
                ("heldOnlyOnce", [Hold.portal(0), Hold.portal(4), Hold.bonus(20), Hold.bonus(40), Hold.bonus(70)],
                 { $0 < 30 || (40..<44).contains($0) || (70..<74).contains($0) }, nil),
                ("unreadableBonusFoundAgain", [Hold.portal(0), Hold.bonus(20, unreadable: 1),
                                               Hold.bonus(46, Array(Hold.rows.prefix(1)), unreadable: 1)],
                 { $0 < 30 || (46..<60).contains($0) }, nil),
                ("lostDuringHold", [Hold.portal(0), Hold.portal(4), Hold.bonus(20), Hold.bonus(52)],
                 { $0 < 30 || (52..<56).contains($0) }, 50),
            ]
            for (name, reads, shown, lost) in holds {
                compared += Self.compare("hold \(name) window \(index)") { rig in
                    Self.attach(rig, Self.playHold(rig, reads, shown: shown, continuityLostAt: lost, policy: policy),
                                waits: [(1, -10), (2, -5)])
                }
            }
        }
        // GearDropAssociationTests.repeatedBonusPanel: the groups an earlier
        // version logged before the hold, closed through each arm's session.
        let bonus = GearDropSummary.Panel(stage: .bonus, entries: [], partial: true)
        let firstPanels = [GearDropSummary.Panel(stage: .portal,
                                                 entries: [Association.item(0, 0, "Resonator", level: 8, 1)],
                                                 partial: false), bonus]
        let build95 = [
            GearDropSummary(groupID: 1, startedAt: 123347.797, closedAt: 123350.797, closeReason: "panelLeft",
                            hackID: nil, association: .unassociated, panels: firstPanels),
            GearDropSummary(groupID: 2, startedAt: 123351.648, closedAt: 123351.998, closeReason: "panelLeft",
                            hackID: nil, association: .unassociated, panels: [bonus]),
        ]
        compared += Self.compare("repeatedBonusPanel") { rig in
            Self.attach(rig, build95 + Self.playAssociation(rig, Association.reads()).dropFirst())
        }
        // GearDropAssociationTests.emptyBonusStillClaims, at the default
        // window and others.
        let row = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 6, quantity: 2)
        let portal = GearDropSummary.Panel(stage: .portal, entries: [row], partial: false)
        let readBonus = GearDropSummary.Panel(stage: .bonus, entries: [row], partial: false)
        let emptyBonus = GearDropSummary.Panel(stage: .bonus, entries: [], partial: true)
        let emptyPortal = GearDropSummary.Panel(stage: .portal, entries: [], partial: true)
        let cases: [([GearDropSummary.Panel]?, Double, [GearDropSummary.Panel])] = [
            (nil, 10.5, [emptyBonus]), ([portal], 10.5, [emptyBonus]), ([portal, readBonus], 12.5, [emptyBonus]),
            ([portal, readBonus], 10.5, [readBonus]), ([portal, readBonus], 10.5, [emptyPortal, emptyBonus]),
            ([portal, readBonus], 10.5, [emptyBonus]), ([portal, readBonus], 12.0, [emptyBonus]),
            ([portal, readBonus], 12.0001, [emptyBonus]), ([portal, readBonus], 9.5, [emptyBonus]),
            ([portal, emptyBonus], 10.5, [emptyBonus]), ([readBonus], 10.5, [emptyBonus]),
            ([portal, readBonus], 10.5, [emptyBonus, emptyBonus]),
        ]
        for window in [2.0, 0.0, 0.5, 1.9999, 2.5, -1] {
            var policy = GearDropObservationSession.Policy(); policy.repeatedBonusWindow = window
            compared += Self.compare("emptyBonusStillClaims window \(window)") { rig in
                for (previous, start, panels) in cases {
                    let session = rig.session(policy: policy)
                    let display = rig.display()
                    session.enqueue(hackID: 1, at: 0); session.enqueue(hackID: 2, at: 1)
                    if let previous {
                        display.finished(session.close(GearDropSummary(groupID: 1, startedAt: 8, closedAt: 10,
                            closeReason: "panelLeft", hackID: nil, association: .unassociated, panels: previous)))
                    }
                    display.finished(session.close(GearDropSummary(groupID: 2, startedAt: start, closedAt: start + 0.5,
                        closeReason: "panelLeft", hackID: nil, association: .unassociated, panels: panels)))
                    display.update(waiting: session.waiting, reading: false, associationUncertain: false, at: 11)
                    session.invalidate(at: 12, reason: "captureStopped")
                    session.close(GearDropSummary(groupID: 3, startedAt: 12.5, closedAt: 13, closeReason: "panelLeft",
                        hackID: nil, association: .unassociated, panels: [emptyBonus]))
                }
            }
        }
        print("C++ gear: held-Bonus scenarios compared \(compared) outputs")
    }

    @Test("Untitled panels: every body of GearUntitledPanelTests reads the same and shows a panel alike",
          arguments: GameLanguage.allCases)
    func untitledPanels(_ language: GameLanguage) {
        let line = Self.line, bounds = Self.bounds
        let effect = line("ITO EN (+) applied.", 0.3, 0.34, 0.35, 1)
        let rows = [line("L6 x1 Power Cube", 0.1, 0.386, 0.35, 1), line("L6 x1 Resonator", 0.58, 0.386, 0.35, 1)]
        let bodies: [[ResultTextLine]] = [
            [effect] + rows, [effect], rows,
            [line("Somewhere", 0.3, 0.31, 0.35, 1), line("Elsewhere", 0.3, 0.315, 0.35, 1)] + rows,
            [line("Bonus items:", 0.3, 0.31, 0.35, 0.3)] + rows, [line("Bonvs items:", 0.3, 0.31, 0.35, 1)] + rows,
            [], [line("x2 Something new", 0.1, 0.386, 0.35, 1)], [line("L6 x1 Resonator", 0.1, 0.386, 0.35, 0.2)],
            [line("ITO EN (+) applied.", 0.3, 0.34, 0.35, 0.4)],
            [line("Hello agent", 0.1, 0.386, 0.35, 1), line("Map text", 0.58, 0.42, 0.35, 1)],
            [line("Bounty Claimed", 0.3, 0.31, 0.35, 1)] + rows, [line("奖励物品:", 0.3, 0.31, 0.35, 1)] + rows,
            [line("ボーナスアイテム:", 0.3, 0.31, 0.35, 1)] + rows, [line("Test location", 0.3, 0.31, 0.35, 1)] + rows,
            [line("Bonus items:", 0.3, 0.31, 0.35, 1)] + rows,
            [line("x1 Portal Key", 0.1, 0.386, 0.35, 1)], [line("x1 能量塔护盾", 0.1, 0.386, 0.35, 1)],
            [line("ITO EN (+) applied.", 0.3, 0.60, 0.35, 1)], [line("L6 x1 Resonator", 0.1, 0.70, 0.35, 1)],
            [line("L6 x1 Resonator", .nan, 0.386, 0.35, 1)], [line("ITO EN (+) applied.", 0.3, 0.34, 0.35, .nan)],
        ]
        Self.compare("untitledPanels \(language)") { rig in
            let parser = rig.parser(language)
            for lines in bodies {
                // Outputs compare with ==, so times stay finite: NaN is never equal to itself.
                for at in [1.0, 3.5] { parser.read(lines: lines, bounds: bounds, at: at) }
                parser.read(lines: lines, bounds: GearDropPanelBounds(top: 0.29, bottom: 0.61), at: 1)
            }
        }
    }

    // MARK: - Entry facts across the ABI

    @Test("Intrinsic rarity, rarity meters and summary counts agree with Swift")
    func entryFacts() {
        let items: [String?] = [nil, "Portal Key", "Media", "Portal Shield", "Turret", "Force Amp", "Aegis Shield",
                                "Hypercube", "ADA Refactor", "JARVIS Virus", "SoftBank Ultra Link",
                                "ITO EN Transmuter (+)", "ITO EN Transmuter (-)", "Resonator", "Heat Sink", "Unknown"]
        var panels: [GearDropSummary.Panel] = []
        for item in items {
            for level in [GearDropEntry.Level.known, .notApplicable, .unreadable] {
                let entry = GearDropEntry(column: 1, row: 2, item: item, levelState: level,
                                          level: level == .known ? 5 : nil, quantity: 3)
                let arena = CxxGearArena()
                var value = CxxGearValues.entry(entry, in: arena)
                let rarity = withExtendedLifetime(arena) { gl_gear_entry_intrinsic_rarity(&value) }
                let meter = withExtendedLifetime(arena) { gl_gear_entry_has_rarity_meter(&value) }
                #expect(CxxGearValues.rarities[Int(rarity.rawValue)] == entry.intrinsicRarity, "\(entry)")
                #expect(meter == entry.hasRarityMeter, "\(entry)")
                #expect(CxxGearValues.entry(value) == entry)
                panels.append(.init(stage: level == .known ? .portal : .bonus, entries: [entry], partial: false))
            }
        }
        for set in [[], panels, Array(panels.prefix(2)), [panels[1], panels[0]],
                       [GearDropSummary.Panel(stage: .portal, entries: [], partial: true), panels[4]]] {
            let summary = GearDropSummary(groupID: 3, startedAt: 1, closedAt: 2, closeReason: "test", hackID: 4,
                                          association: .ordered, panels: set)
            let arena = CxxGearArena()
            var value = CxxGearValues.summary(summary, in: arena)
            withExtendedLifetime(arena) {
                #expect(Int(gl_gear_summary_recognized_quantity(&value)) == summary.recognizedQuantity)
                #expect(Int(gl_gear_summary_unidentified_quantity(&value)) == summary.unidentifiedQuantity)
                #expect(gl_gear_summary_panels_read_in_full(&value) == summary.panelsReadInFull)
                #expect(gl_gear_summary_both_panels_read(&value) == summary.bothPanelsRead)
                #expect(CxxGearValues.summary(value) == summary)
            }
        }
        for disposition in CxxGearValues.dispositions {
            let index = UInt32(CxxGearValues.dispositions.firstIndex(of: disposition) ?? 0)
            #expect(CxxGearValues.string(gl_gear_disposition_name(gl_gear_disposition(rawValue: index)))
                    == disposition.rawValue)
        }
    }

    // MARK: - Pixel readers

    typealias RGB = (UInt8, UInt8, UInt8)

    /// GearQuantityColorTests' quantity box.
    static func box(_ ink: RGB, other: RGB? = nil, strokes: Int = 3) throws -> ColorImage {
        let width = 36, height = 22, background: RGB = (17, 17, 32)
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                var rgb = background
                if (3..<19).contains(y), x % 10 < 3, x / 10 < strokes { rgb = ink }
                if let other, x < 6, (3..<19).contains(y) { rgb = other }
                let offset = (y * width + x) * 3
                pixels[offset] = rgb.0; pixels[offset + 1] = rgb.1; pixels[offset + 2] = rgb.2
            }
        }
        return try ColorImage(width: width, height: height, pixels: pixels)
    }

    /// GearRarityTests' meter.
    static func meter(_ bars: [RGB], width: Int = 42, height: Int = 32, shiftX: Double = 0, shiftY: Double = 0,
                      solid: Bool = false) throws -> ColorImage {
        var pixels = [UInt8](repeating: 15, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let fy = Double(y) / Double(height) - shiftY
                for (index, center) in [0.216, 0.459, 0.702].enumerated() where index < bars.count {
                    let barX = (center + shiftX) * Double(width) + (0.5 - fy) * Double(height) * 0.35
                    if solid || ((0.23...0.77).contains(fy) && abs(Double(x) - barX) <= Double(width) * 0.065) {
                        let rgb = bars[index], offset = (y * width + x) * 3
                        pixels[offset] = rgb.0; pixels[offset + 1] = rgb.1; pixels[offset + 2] = rgb.2
                    }
                }
            }
        }
        return try ColorImage(width: width, height: height, pixels: pixels)
    }

    @Test("The quantity colour and rarity readers agree on the oracle tests' images and their variations")
    func syntheticReaders() throws {
        let red: RGB = (200, 0, 35), faintRed: RGB = (117, 0, 18), white: RGB = (235, 235, 240)
        let levelFive: RGB = (186, 0, 52), levelEight: RGB = (150, 40, 244)
        let common: RGB = (65, 185, 150), rare: RGB = (170, 115, 245), veryRare: RGB = (240, 70, 185)
        let inactive: RGB = (80, 80, 85)
        var boxes = [try Self.box(red), try Self.box(faintRed), try Self.box(white),
                     try Self.box(white, other: levelFive), try Self.box(red, other: levelEight),
                     try Self.box(levelEight), try Self.box(red, strokes: 0), try Self.box((60, 0, 10))]
        for value in stride(from: 0, through: 255, by: 15) {
            for strokes in [1, 2, 3] {
                boxes.append(try Self.box((UInt8(value), 0, UInt8(255 - value)), strokes: strokes))
                boxes.append(try Self.box((255, UInt8(value), UInt8(value / 2)), strokes: strokes))
                boxes.append(try Self.box((UInt8(value), UInt8(value), UInt8(value)), other: red, strokes: strokes))
            }
        }
        var meters: [ColorImage] = []
        let patterns: [[RGB]] = [[common, inactive, inactive], [rare, rare, inactive], [veryRare, veryRare, veryRare],
                                 [inactive, inactive, inactive], [rare, inactive, inactive], [common, common, inactive],
                                 [veryRare, veryRare, inactive], [common, rare, veryRare], [common], [rare, rare],
                                 [(220, 220, 220), inactive, inactive]]
        for bars in patterns {
            for scale in [1, 2, 3] {
                for shift in [-0.04, 0, 0.04] {
                    meters.append(try Self.meter(bars, width: 42 * scale, height: 32 * scale, shiftX: shift, shiftY: shift))
                }
            }
            meters.append(try Self.meter(bars, solid: true))
            meters.append(try Self.meter(bars, width: 16, height: 12))
            meters.append(try Self.meter(bars, width: 15, height: 12))
        }
        let readers = Self.compare("synthetic readers") { rig in
            for image in boxes + meters { rig.color(image); rig.rarity(image) }
        }
        print("C++ gear: synthetic reader outputs compared: \(readers) on \(boxes.count + meters.count) images")
    }

    // MARK: - Gear fixtures

    struct Fixture: Sendable {
        let name: String
        let image: CGImage
        let bounds: GearDropPanelBounds
    }

    static func fixtures() throws -> [Fixture] {
        let directory = try ReferenceData.fixturesDirectory.appendingPathComponent("Gear")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { file in
            let image = try #require(ImageDecoder.cgImage(from: try Data(contentsOf: file)), "\(file.lastPathComponent)")
            // The isolated-row crops have no whole panel; their tests give these bounds.
            let bounds = try GearDropScreenReader().bounds(in: image)
                ?? GearDropPanelBounds(top: 0.28626, bottom: 0.4549618320610687)
            return Fixture(name: file.lastPathComponent, image: image, bounds: bounds)
        }
    }

    @Test("Both readers agree on every meter crop and on sliding windows over every Gear fixture's panel")
    func fixtureReaders() throws {
        let fixtures = try Self.fixtures()
        #expect(fixtures.count >= 11)
        var regions = 0
        let compared = try Self.compare("fixture readers") { rig in
            for fixture in fixtures {
                let image = fixture.image, width = Double(image.width), height = Double(image.height)
                let bounds = fixture.bounds
                // The screen reader's meter crop at each position.
                for position in 0..<14 {
                    let row = position / 2, column = position % 2
                    let centerY = bounds.top + 0.067 + Double(row) * 0.036
                    let rect = CGRect(x: (0.123 + Double(column) * 0.465) * width, y: (centerY - 0.013) * height,
                                      width: 0.074 * width, height: 0.026 * height).integral
                    guard rect.minY >= 0, rect.maxY <= height else { continue }
                    let pixels = try ImageDecoder.decodeColor(image, in: rect)
                    rig.rarity(pixels); rig.color(pixels)
                    if rig.name == "swift" { regions += 1 }
                }
                // Windows the size of a quantity box and of a meter, over the
                // panel, cut from one decode of it.
                let top = Int(bounds.top * height), bottom = Int(bounds.bottom * height)
                let panel = try ImageDecoder.decodeColor(image, in: CGRect(x: 0, y: top, width: image.width,
                                                                           height: bottom - top))
                for (boxWidth, boxHeight, step) in [(36, 22, 16), (Int(0.074 * width), Int(0.026 * height), 12)] {
                    var y = 0
                    while y + boxHeight <= panel.height {
                        var x = 0
                        while x + boxWidth <= panel.width {
                            let pixels = try Self.crop(panel, x: x, y: y, width: boxWidth, height: boxHeight)
                            rig.color(pixels); rig.rarity(pixels)
                            if rig.name == "swift" { regions += 1 }
                            x += step
                        }
                        y += step
                    }
                }
            }
        }
        print("C++ gear: fixture reader outputs compared: \(compared) over \(regions) regions")
    }

    static func crop(_ image: ColorImage, x: Int, y: Int, width: Int, height: Int) throws -> ColorImage {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 3)
        for row in y..<(y + height) {
            let start = (row * image.width + x) * 3
            pixels += image.pixels[start..<(start + width * 3)]
        }
        return try ColorImage(width: width, height: height, pixels: pixels)
    }

    /// One Vision line, and its quantity marker's box in source pixels, as
    /// `GearDropScreenReader.recognize` makes them.
    struct VisionLine: Sendable {
        let line: ResultTextLine
        let quantity: CGRect?
    }

    static let visionAvailable: Bool = {
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { return false }
        let request = VNRecognizeTextRequest()
        return (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil
    }()

    static func recognize(_ image: CGImage, rect: CGRect, languages: [String]) throws -> [VisionLine] {
        guard let crop = image.cropping(to: rect),
              let canvas = CGContext(data: nil, width: crop.width * 2, height: crop.height * 2, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        canvas.interpolationQuality = .high
        canvas.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width * 2, height: crop.height * 2))
        guard let enlarged = canvas.makeImage() else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        request.automaticallyDetectsLanguage = false
        try VNImageRequestHandler(cgImage: enlarged).perform([request])
        return (request.results ?? []).compactMap { observation -> VisionLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let line = ResultTextLine(text: best.string, confidence: Double(best.confidence),
                x: (rect.minX + box.minX * rect.width) / Double(image.width),
                y: (rect.minY + (1 - box.maxY) * rect.height) / Double(image.height),
                width: box.width * rect.width / Double(image.width),
                height: box.height * rect.height / Double(image.height))
            guard let marker = GearDropScreenReader.quantityRange(in: best.string),
                  let quantity = try? best.boundingBox(for: marker)?.boundingBox else {
                return VisionLine(line: line, quantity: nil)
            }
            return VisionLine(line: line, quantity: CGRect(x: rect.minX + quantity.minX * rect.width,
                y: rect.minY + (1 - quantity.maxY) * rect.height,
                width: quantity.width * rect.width, height: quantity.height * rect.height))
        }
    }

    @Test("The parser reads Vision's lines from every Gear fixture alike, in every language, and the colour reader its quantity boxes",
          .enabled(if: CxxGearTests.visionAvailable, "Vision text recognition is unavailable"))
    func fixtureLines() throws {
        let families = [["en-US", "zh-Hans"], ["zh-Hans", "en-US"], ["zh-Hant", "en-US"], ["ja-JP", "en-US"],
                        ["ko-KR", "en-US"]]
        var sets: [(fixture: Fixture, lines: [VisionLine])] = []
        for fixture in try Self.fixtures() {
            let image = fixture.image, bounds = fixture.bounds
            let rect = CGRect(x: Double(image.width) * 0.035, y: bounds.top * Double(image.height),
                              width: Double(image.width) * 0.93,
                              height: (bounds.bottom - bounds.top) * Double(image.height)).integral
            for languages in families {
                sets.append((fixture, try Self.recognize(image, rect: rect, languages: languages)))
            }
        }
        let lineCount = sets.reduce(0) { $0 + $1.lines.count }
        #expect(lineCount > 0, "Vision read no lines")
        var boxes = 0
        let compared = try Self.compare("fixture lines") { rig in
            let parsers = GameLanguage.allCases.map { rig.parser($0) }
            for (fixture, recognized) in sets {
                let bounds = fixture.bounds, lines = recognized.map(\.line)
                for parser in parsers {
                    parser.read(lines: lines, bounds: bounds, at: 1)
                    var rows: [Int: [ResultTextLine]] = [:]
                    for line in lines {
                        let position = parser.position(of: line, in: bounds)
                        parser.parseEntry(line.text, row: (position ?? 0) / 2, column: (position ?? 0) % 2)
                        parser.parseEntry(line.text, row: (position ?? 0) / 2, column: (position ?? 0) % 2, clipped: true)
                        if let position { rows[position, default: []].append(line) }
                    }
                    for (position, fragments) in rows.sorted(by: { $0.key < $1.key }) {
                        let ordered = fragments.sorted { $0.x < $1.x }
                        let right = ordered.map { $0.x + $0.width }.max() ?? 0
                        let clipped = right >= (position % 2 == 0 ? 0.50 : 0.98) - 0.05
                        parser.parseEntry(ordered.map(\.text).joined(separator: " "), row: position / 2,
                                          column: position % 2, clipped: clipped)
                    }
                }
                // The colour reader on the quantity boxes Vision found.
                let image = fixture.image
                let panel = CGRect(x: 0, y: bounds.top * Double(image.height), width: Double(image.width),
                                   height: (bounds.bottom - bounds.top) * Double(image.height))
                for box in recognized.compactMap(\.quantity) {
                    let crop = box.intersection(panel).integral
                    guard !crop.isEmpty else { continue }
                    let pixels = try ImageDecoder.decodeColor(image, in: crop)
                    rig.color(pixels)
                    if rig.name == "swift" { boxes += 1 }
                }
            }
        }
        print("C++ gear: Vision fixture outputs compared: \(compared) from \(lineCount) lines in \(sets.count) reads, \(boxes) quantity boxes")
    }

    // MARK: - Random walk

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
        mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
    }

    static let walkSteps = 2_000

    /// Random evidence and calls through a tracker, a session, a display and
    /// a schedule wired as the app wires them. Random draws never depend on
    /// an arm's output, so both arms receive the same calls.
    static func walk(_ rig: Rig, seed: UInt64) {
        var random = SplitMix64(state: seed)
        let tight = seed % 3 == 0
        var trackerPolicy = GearDropTracker.Policy()
        var sessionPolicy = GearDropObservationSession.Policy()
        if tight {
            trackerPolicy.minimumSpan = 0.05; trackerPolicy.maximumReadingGap = 0.6; trackerPolicy.departureSpan = 0.1
            trackerPolicy.maximumCompletionWait = 1; trackerPolicy.groupLimit = 3
            sessionPolicy.inactivityLimit = 8; sessionPolicy.absoluteLimit = 20; sessionPolicy.maximumWaiting = 3
            trackerPolicy.bonusReturnWindow = 0.8; sessionPolicy.repeatedBonusWindow = 0.7
        } else if seed % 3 == 2 {
            trackerPolicy.bonusReturnWindow = 0; sessionPolicy.repeatedBonusWindow = 5
        }
        let tracker = rig.tracker(policy: trackerPolicy)
        let session = rig.session(policy: sessionPolicy)
        let display = rig.display(standalone: seed % 3 == 2)
        let schedule = rig.schedule()
        let items: [String?] = [nil, "XMP Burster", "Resonator", "Portal Shield", "Turret", "Hypercube", "Portal Key"]
        let rarities: [GearDropEntry.Rarity?] = [nil, .common, .rare, .veryRare, .unreadable]
        let phases: [TrackingState] = [.inactive, .command, .presenting, .input, .completed, .interrupted]
        let reasons = ["test", "panelLeft", "continuityLost", "captureStopped", "endOfStream"]
        var time = 0.0
        var nextHack = 1

        func randomEntry() -> GearDropEntry {
            let levelState = random.pick([GearDropEntry.Level.known, .notApplicable, .unreadable])
            let level: Int? = levelState == .known ? 1 + random.below(8) : (random.chance(5) ? 3 : nil)
            return GearDropEntry(column: random.below(2), row: random.below(4), item: random.pick(items),
                                 levelState: levelState, level: level, quantity: 1 + random.below(3),
                                 rarity: random.pick(rarities), multiplied: random.pick([nil, true, false]))
        }
        func vary(_ entry: GearDropEntry) -> GearDropEntry {
            switch random.below(10) {
            case 0: return GearDropEntry(column: entry.column, row: entry.row, item: entry.item, levelState: .unreadable,
                                         level: nil, quantity: entry.quantity, rarity: entry.rarity,
                                         multiplied: entry.multiplied)
            case 1: return GearDropEntry(column: entry.column, row: entry.row, item: nil, levelState: entry.levelState,
                                         level: entry.level, quantity: entry.quantity, rarity: entry.rarity,
                                         multiplied: entry.multiplied)
            case 2: return entry.withRarity(.unreadable)
            case 3: return GearDropEntry(column: entry.column, row: entry.row, item: entry.item,
                                         levelState: entry.levelState, level: entry.level,
                                         quantity: entry.quantity + 1, rarity: entry.rarity, multiplied: entry.multiplied)
            case 4: return entry.withMultiplied(random.pick([nil, true, false]))
            default: return entry
            }
        }
        var panel = (0..<2).map { _ in randomEntry() }
        let effects: [[String]?] = [nil, nil, nil, ["ITO EN (+)"], ["ITO EN (-)"], ["ITO EN (+)", "ITO EN (-)"],
                                    ["Other"], []]

        func close(_ group: GearDropSummary?) {
            guard let group else { return }
            display.finished(session.close(group))
        }

        for _ in 0..<walkSteps {
            switch random.below(100) {
            case 0..<78: time += Double(random.below(30)) * 0.01
            case 78..<86: break
            case 86..<93: time -= Double(random.below(50)) * 0.01
            default: time += Double(random.below(400)) * 0.1
            }
            var at = time
            if random.chance(1) { at = random.pick([Double.nan, .infinity, -.infinity]) }
            let action = random.below(100)
            switch action {
            case 0..<35:
                if random.chance(12) { panel = (0..<(1 + random.below(3))).map { _ in randomEntry() } }
                let entries = panel.compactMap { random.chance(90) ? vary($0) : nil }
                let stage = random.pick([GearDropStage.portal, .portal, .portal, .bonus, .bonus, .bonus, .unknown,
                                         .excluded, .unsupported, .absent])
                let source = at - Double(random.below(4)) * 0.1
                let evidence = GearDropFrameEvidence(
                    sourceTime: source, stage: stage,
                    bounds: random.chance(50) ? GearDropPanelBounds(top: 0.29, bottom: 0.46) : nil,
                    entries: entries, unreadableRows: random.chance(20) ? random.below(3) : 0,
                    effects: random.pick(effects), titleLanguage: random.pick([nil, GameLanguage.english, .japanese]))
                let enqueue = random.chance(50)
                close(tracker.accept(evidence))
                if schedule.shouldSave(stage: stage, at: source), enqueue {
                    schedule.didEnqueue(stage: stage, at: source)
                }
            case 35..<65:
                let pending: Double? = random.pick([nil, nil, at - 0.1, at - 0.5, at - 3, at + 1, .nan])
                close(tracker.observe(at: at, panelCandidate: random.chance(60), continuityLost: random.chance(2),
                                      pendingReadSourceTime: pending))
            case 65..<68: close(tracker.loseContinuity(at: at))
            case 68..<72: close(tracker.finish(at: at, reason: random.pick(reasons)))
            case 72..<80: session.prepareFrame(at: at, continuityLost: random.chance(5))
            case 80..<92:
                let hack = random.below(nextHack + 1)
                session.observe(at: at, hackID: hack, inputVisible: random.chance(40),
                                gameProgressVisible: random.chance(30), inputPhase: random.pick(phases))
                if random.chance(20) { nextHack += 1 }
            case 92..<95:
                session.enqueue(hackID: random.below(nextHack + 2) - 1, at: at)
                nextHack += 1
            case 95..<97:
                session.accept(result(hack: random.below(nextHack + 1), bonus: random.pick([nil, 0, 120])))
            case 97: session.expire(at: time)
            case 98: session.invalidate(at: time, reason: random.pick(["frameGap", "captureStopped", "queueLimit"]))
            default: display.ended(hackID: random.below(nextHack + 1), at: random.chance(50) ? at : time)
            }
            display.update(waiting: session.waiting, reading: tracker.isObserving,
                           associationUncertain: session.isAssociationUncertain, at: at)
        }
        close(tracker.finish(at: time + 100, reason: "endOfStream"))
    }

    @Test("A seeded random walk of 2,000 steps through both arms matches after every step",
          arguments: [UInt64(1), 2, 3])
    func randomWalk(_ seed: UInt64) {
        var oracle: [Output] = []
        let compared = Self.compare("random walk \(seed)") { rig in
            Self.walk(rig, seed: seed)
            if rig.name == "swift" { oracle = rig.recorder.outputs }
        }
        var groups = 0, confirmed = 0, attached = 0, repeated = 0, settledFrames = 0
        var reasons: Set<String> = [], dispositions: Set<String> = []
        for output in oracle {
            switch output {
            case .summary(let summary?):
                groups += 1
                confirmed += summary.panels.reduce(0) { $0 + $1.entries.count }
                if summary.hackID != nil { attached += 1 }
                if summary.association == .repeatedBonus { repeated += 1 }
                reasons.insert(summary.closeReason)
            case .session(_, let events, _): reasons.formUnion(events.map(\.reason))
            case .tracker(_, let disposition, let settled):
                dispositions.insert(disposition.rawValue)
                if settled { settledFrames += 1 }
            default: break
            }
        }
        // The walk must reach the rules it is meant to compare.
        #expect(groups > 20 && confirmed > 20 && attached > 0 && dispositions.count == 5 && settledFrames > 0)
        print("C++ gear: random walk seed \(seed): \(Self.walkSteps) steps, \(compared) outputs compared; "
              + "\(groups) summaries with \(confirmed) settled entries, \(attached) attached, "
              + "\(repeated) repeated Bonus; \(settledFrames) settled-panel states; "
              + "reasons \(reasons.sorted()); dispositions \(dispositions.sorted())")
    }
}

extension GearDropObservationSession: CxxGearTests.TestSession {}
extension CxxGearDropObservationSession: CxxGearTests.TestSession {}
