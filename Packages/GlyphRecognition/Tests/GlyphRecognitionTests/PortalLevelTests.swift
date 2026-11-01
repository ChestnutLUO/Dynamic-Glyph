import Foundation
import CoreGraphics
import Testing
@testable import GlyphRecognition
import GlyphRecognitionImages

@Suite("Portal level from resonators, badge and Glyph count")
struct PortalLevelTests {
    @Test("Glyph count gives the game's level ranges")
    func glyphCounts() {
        #expect(PortalLevelRules.levels(forGlyphCount: 1) == 1...1)
        #expect(PortalLevelRules.levels(forGlyphCount: 2) == 2...2)
        #expect(PortalLevelRules.levels(forGlyphCount: 3) == 3...5)
        #expect(PortalLevelRules.levels(forGlyphCount: 4) == 6...7)
        #expect(PortalLevelRules.levels(forGlyphCount: 5) == 8...8)
        #expect(PortalLevelRules.levels(forGlyphCount: 0) == nil && PortalLevelRules.levels(forGlyphCount: 6) == nil)
    }

    @Test("Eight resonators give the exact level; unread slots widen it")
    func resonatorSums() {
        // Field test 2, hack 2: 8, 6, 7, 6, 6, 6, 8, 7 sums to 54.
        #expect(PortalLevelRules.levels(forResonators: [8, 6, 7, 6, 6, 6, 8, 7], unread: 0) == 6...6)
        #expect(PortalLevelRules.levels(forResonators: Array(repeating: 8, count: 8), unread: 0) == 8...8)
        // Three read: each unread slot may be empty or L8.
        #expect(PortalLevelRules.levels(forResonators: [5, 4, 6], unread: 5) == 1...6)
        #expect(PortalLevelRules.levels(forResonators: [], unread: 0) == nil)
    }

    @Test("Calibrated badge hues give one level; others only a range")
    func badgeHues() {
        #expect(PortalLevelRules.levels(forBadgeHue: 259) == 8...8)
        #expect(PortalLevelRules.levels(forBadgeHue: 330) == 6...6)
        #expect(PortalLevelRules.levels(forBadgeHue: 344) == 5...5)
        #expect(PortalLevelRules.levels(forBadgeHue: 295) == 7...7)
        #expect(PortalLevelRules.levels(forBadgeHue: 10) == 1...4)
        #expect(PortalLevelRules.levels(forBadgeHue: 180) == nil)
    }

    @Test("Agreeing sources raise confidence; disagreement is a conflict, not a guess")
    func combining() throws {
        let full = try #require(PortalLevelRules.estimate(resonators: [8, 6, 7, 6, 6, 6, 8, 7], unreadSlots: 0,
                                                          badgeHue: 329, glyphCount: 4))
        #expect(full.level == 6 && full.confidence == .high && !full.conflict)
        let ringOnly = try #require(PortalLevelRules.estimate(resonators: Array(repeating: 8, count: 8),
                                                              unreadSlots: 0, badgeHue: nil, glyphCount: nil))
        #expect(ringOnly.level == 8 && ringOnly.confidence == .medium)
        let partial = try #require(PortalLevelRules.estimate(resonators: [5, 4, 6], unreadSlots: 5,
                                                             badgeHue: 343, glyphCount: 3))
        #expect(partial.level == 5 && partial.confidence == .medium)
        let countOnly = try #require(PortalLevelRules.estimate(resonators: nil, unreadSlots: nil,
                                                               badgeHue: nil, glyphCount: 4))
        #expect(countOnly.level == nil && countOnly.lowest == 6 && countOnly.highest == 7 && countOnly.confidence == .low)
        // An L8 ring against a 3-Glyph hack: keep the ring, flag the conflict.
        let conflict = try #require(PortalLevelRules.estimate(resonators: Array(repeating: 8, count: 8),
                                                              unreadSlots: 0, badgeHue: nil, glyphCount: 3))
        #expect(conflict.conflict && conflict.level == 8 && conflict.confidence == .low)
        #expect(PortalLevelRules.estimate(resonators: nil, unreadSlots: nil, badgeHue: nil, glyphCount: nil) == nil)
    }

    @Test("Only level labels count; digits in agent names never do")
    func labels() {
        let parser = PortalScreenParser()
        func line(_ text: String) -> ResultTextLine {
            ResultTextLine(text: text, confidence: 1, x: 0.05, y: 0.4, width: 0.1, height: 0.02)
        }
        let read = parser.read(lines: ["L8", "B1gHack3r", "l6 A", "I7", "18", "L 5", "ChestnutL..", "A L4", "k3r 9"].map(line),
                               badgeHue: nil, at: 1)
        #expect(read.resonators == [8, 6, 7, 8, 5, 4])
        #expect(read.unreadSlots == 2)
        #expect(parser.read(lines: ["L9", "L0", "x8", "L88"].map(line), badgeHue: nil, at: 1).resonators.isEmpty)
    }

    @Test("A portal screen attaches to the next hack only, within its window")
    func observer() throws {
        var observer = PortalLevelObserver()
        observer.accept(PortalScreenEvidence(sourceTime: 10, resonators: [8, 8, 8], unreadSlots: 5, badgeHue: nil))
        // The same screen fading in: the fuller read stays.
        observer.accept(PortalScreenEvidence(sourceTime: 10.25, resonators: [8], unreadSlots: 7, badgeHue: 259))
        let firstValue = PortalLevelRules.estimate(screen: observer.claim(at: 13), glyphCount: 5)
        let first = try #require(firstValue)
        #expect(first.level == 8 && first.resonators == [8, 8, 8])
        // The next hack has no portal screen: only its Glyph count is left.
        let secondValue = PortalLevelRules.estimate(screen: observer.claim(at: 30), glyphCount: 3)
        let second = try #require(secondValue)
        #expect(second.resonators == nil && second.level == nil && second.lowest == 3)
        // A screen long before the hack is another visit, not this hack's.
        observer.accept(PortalScreenEvidence(sourceTime: 40, resonators: [6, 6], unreadSlots: 6, badgeHue: 329))
        let staleValue = PortalLevelRules.estimate(screen: observer.claim(at: 55), glyphCount: 4)
        let stale = try #require(staleValue)
        #expect(stale.resonators == nil && stale.badgeLevels == nil)
        // A later screen beyond the fade replaces an earlier, fuller one.
        observer.accept(PortalScreenEvidence(sourceTime: 60, resonators: [8, 8, 8, 8], unreadSlots: 4, badgeHue: 259))
        observer.accept(PortalScreenEvidence(sourceTime: 63, resonators: [5], unreadSlots: 7, badgeHue: 343))
        let replacedValue = PortalLevelRules.estimate(screen: observer.claim(at: 65), glyphCount: 3)
        let replaced = try #require(replacedValue)
        #expect(replaced.resonators == [5] && replaced.level == 5)
    }

    @Test("A different faction replaces a fuller screen, even during the fade window",
          arguments: [PortalFaction.enlightened, .machina], [0, 1])
    func observerFactionChange(faction: PortalFaction, count: Int) throws {
        var observer = PortalLevelObserver()
        observer.accept(PortalScreenEvidence(sourceTime: 10, resonators: Array(repeating: 8, count: 8),
                                            unreadSlots: 0, badgeHue: 259, faction: .resistance))
        observer.accept(PortalScreenEvidence(sourceTime: 11, resonators: Array(repeating: 1, count: count),
                                            unreadSlots: 8 - count, badgeHue: nil, faction: faction))
        let claimed = observer.claim(at: 12)
        let screen = try #require(claimed)
        #expect(screen.faction == faction && screen.sourceTime == 11)
        #expect(screen.resonators == Array(repeating: 1, count: count))
        #expect(screen.badgeHue == nil, "The previous portal's badge cannot cross the boundary")
        #expect(observer.claim(at: 13) == nil)
    }

    @Test("A later screen with unread labels replaces old labels and badge")
    func observerUnreadLaterScreen() throws {
        var observer = PortalLevelObserver()
        observer.accept(PortalScreenEvidence(sourceTime: 10, resonators: [8, 8, 8],
                                            unreadSlots: 5, badgeHue: 259, faction: .resistance))
        observer.accept(PortalScreenEvidence(sourceTime: 12, resonators: [],
                                            unreadSlots: 8, badgeHue: nil, faction: .resistance))
        let claimed = observer.claim(at: 13)
        let screen = try #require(claimed)
        #expect(screen.sourceTime == 12 && screen.resonators.isEmpty && screen.badgeHue == nil)
    }

    @Test("A fading screen retains its labels and latest badge; older callbacks cannot replace it")
    func observerFadingAndOutOfOrder() throws {
        var observer = PortalLevelObserver()
        observer.accept(PortalScreenEvidence(sourceTime: 10, resonators: [1, 1, 1],
                                            unreadSlots: 5, badgeHue: nil, faction: .machina))
        observer.accept(PortalScreenEvidence(sourceTime: 10.5, resonators: [],
                                            unreadSlots: 8, badgeHue: 10, faction: .machina))
        observer.accept(PortalScreenEvidence(sourceTime: 9, resonators: [8, 8, 8, 8],
                                            unreadSlots: 4, badgeHue: 259, faction: .resistance))
        let claimed = observer.claim(at: 11)
        let screen = try #require(claimed)
        #expect(screen.resonators == [1, 1, 1] && screen.faction == .machina && screen.badgeHue == 10)
    }

    @Test("A portal read finishing after the hack starts cannot attach to the next hack")
    func observerLateCallback() {
        var observer = PortalLevelObserver()
        let first = observer.claim(at: 10)
        #expect(first == nil)
        observer.accept(PortalScreenEvidence(sourceTime: 9, resonators: [8, 8, 8, 8],
                                            unreadSlots: 4, badgeHue: 259, faction: .resistance))
        let second = observer.claim(at: 12)
        #expect(second == nil)
    }

    func fixture(_ name: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("PortalLevel/\(name).png"))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    @Test("Recorded portal screens are found and their badge read; maps with beams are not",
          arguments: [("portal-l6", 6), ("portal-l5", 5), ("portal-l8", 8)])
    func recordedPortals(_ sample: (String, Int)) throws {
        let reader = PortalScreenReader()
        let frame = try fixture(sample.0)
        #expect(try reader.isCandidate(frame))
        let hue = try #require(try reader.badgeHue(in: frame))
        #expect(PortalLevelRules.levels(forBadgeHue: hue) == sample.1...sample.1)
    }

    @Test("Portal screens are found in each faction's bar colour, which names the faction",
          arguments: [("portal-l6", PortalFaction.resistance), ("portal-l5", .resistance), ("portal-l8", .resistance),
                      ("enlightened-a", .enlightened), ("enlightened-b", .enlightened),
                      ("machina-a", .machina), ("machina-b", .machina)])
    func factions(_ sample: (String, PortalFaction)) throws {
        let reader = PortalScreenReader()
        let frame = try fixture(sample.0)
        #expect(try reader.faction(frame) == sample.1)
        #expect(try reader.isCandidate(frame))
    }

    @Test("A screen's faction is kept in its evidence and in the claim a hack makes")
    func factionCarried() throws {
        let evidence = PortalScreenParser().read(lines: [], badgeHue: nil, at: 10, faction: .machina)
        #expect(evidence.faction == .machina)
        var observer = PortalLevelObserver()
        observer.accept(evidence)
        #expect(observer.claim(at: 11)?.faction == .machina)
        let older = #"{"sourceTime":1,"resonators":[8],"unreadSlots":7}"#
        #expect(try JSONDecoder().decode(PortalScreenEvidence.self, from: Data(older.utf8)).faction == nil,
                "Evidence logged before factions still decodes")
    }

    @Test("Only a mostly yellow L counts as L1's, and only a single level on its line is replaced")
    func yellowRule() {
        #expect(PortalScreenParser.isLevelOneYellow(hues: Array(repeating: 65, count: 40)))
        #expect(PortalScreenParser.isLevelOneYellow(hues: Array(repeating: 65, count: 30) + Array(repeating: 280, count: 10)))
        #expect(!PortalScreenParser.isLevelOneYellow(hues: Array(repeating: 65, count: 10)), "Too few pixels")
        #expect(!PortalScreenParser.isLevelOneYellow(hues: Array(repeating: 280, count: 40)), "L7's purple")
        #expect(!PortalScreenParser.isLevelOneYellow(hues: Array(repeating: 10, count: 40)), "L4's red")
        #expect(!PortalScreenParser.isLevelOneYellow(hues: Array(repeating: 65, count: 20) + Array(repeating: 258, count: 20)),
                "Half yellow is not enough")
        func line(_ text: String) -> ResultTextLine { ResultTextLine(text: text, confidence: 1, x: 0, y: 0, width: 0.1, height: 0.02) }
        let parser = PortalScreenParser()
        let lines = [line("L7"), line("17"), line("L8"), line("L7"), line("L8 L8")]
        let read = parser.read(lines: lines, badgeHue: nil, at: 1, yellowLabels: [0, 1, 4])
        #expect(read.resonators == [1, 1, 8, 7, 8, 8])
    }

    @Test("The recorded L1 misread resolves to high confidence without a conflict")
    func yellowEstimate() throws {
        // Local Vision probe of the 2026-10-05 Machina screen: six L1s
        // and one L7 before correction; the seventh L is yellow.
        let lines = ["L1", "L1", "L1", "L1", "L1", "L1", "L7"].map {
            ResultTextLine(text: $0, confidence: 1, x: 0, y: 0, width: 0.1, height: 0.02)
        }
        let screen = PortalScreenParser().read(lines: lines, badgeHue: nil, at: 1,
                                               faction: .machina, yellowLabels: [6])
        let estimate = try #require(PortalLevelRules.estimate(screen: screen, glyphCount: 1))
        #expect(estimate.level == 1 && estimate.confidence == .high && !estimate.conflict)
        #expect(estimate.faction == .machina)
    }

    @Test("A hack's estimate keeps its screen's faction; older and later saved estimates still decode")
    func factionInEstimate() throws {
        let screen = PortalScreenEvidence(sourceTime: 1, resonators: [1, 1, 1, 1, 1, 1, 1, 1], unreadSlots: 0,
                                          badgeHue: nil, faction: .machina)
        let estimate = try #require(PortalLevelRules.estimate(screen: screen, glyphCount: 1))
        #expect(estimate.faction == .machina && estimate.level == 1)
        #expect(PortalLevelRules.estimate(screen: nil, glyphCount: 4)?.faction == nil)
        let saved = try JSONDecoder().decode(PortalLevelEstimate.self, from: JSONEncoder().encode(estimate))
        #expect(saved == estimate && saved.faction == .machina)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(estimate)) as? [String: Any])
        object.removeValue(forKey: "factionCode")
        let older = try JSONDecoder().decode(PortalLevelEstimate.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.faction == nil && older.level == 1)
        object["factionCode"] = "neutral"
        let later = try JSONDecoder().decode(PortalLevelEstimate.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(later.faction == nil && later.level == 1, "A faction this build doesn't know reads as unknown")
    }

    @Test("Drop panels over the map, and a map full of Machina beams, are not portal screens",
          arguments: ["map-drop", "map-drop-602", "map-machina"])
    func recordedMaps(_ name: String) throws {
        #expect(try !PortalScreenReader().isCandidate(try fixture(name)))
    }

    @Test("Portal reads share the lane, yield to gear, and never run during input")
    func schedule() throws {
        var schedule = GameTextSchedule()
        let duringInputValue = schedule.take(at: 0, panelCandidate: false, resultEligible: false,
                                             headerPriority: true, portalCandidate: true)
        let duringInput = try #require(duringInputValue)
        #expect(duringInput.mode == .header)
        schedule.finish(duringInput)
        let portalValue = schedule.take(at: 0.2, panelCandidate: false, resultEligible: false, portalCandidate: true)
        let portal = try #require(portalValue)
        #expect(portal.mode == .portal)
        schedule.finish(portal)
        // Between portal reads the header keeps its turn.
        let headerValue = schedule.take(at: 0.32, panelCandidate: false, resultEligible: false, portalCandidate: true)
        #expect(try #require(headerValue).mode == .header)
        schedule.finish(try #require(headerValue))
        let gearValue = schedule.take(at: 0.5, panelCandidate: false, resultEligible: false,
                                      gearCandidate: true, portalCandidate: true)
        #expect(try #require(gearValue).mode == .gear)
    }
}
