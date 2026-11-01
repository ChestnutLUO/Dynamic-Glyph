import Foundation
import Testing
@testable import GlyphRecognition

/// When a hack's presentation command wasn't resolved its Glyph count is
/// unreliable: it can still flag a conflict, which widens the level to the
/// strongest source as before, but it never narrows the level. The
/// uncalibrated badge range warmer than L5 (L1–L4) doesn't narrow it either.
/// Together they had put an L7 portal at L3–L4 (2026-10-27, hack 1: badge
/// read as L1–L4, 3 Glyphs, one L6 resonator and 7 unread). The resonators,
/// calibrated hues and the L7 band narrow as before; a settled count changes
/// nothing.
@Suite("Portal level with an unresolved command")
struct PortalLevelCommandTests {
    /// Warmer than L5 on both sides of red: the uncalibrated L1–L4 range.
    static let warmHues = [355.0, 10.0]

    @Test("Hack 1's inputs no longer give L3–L4: the range keeps L7")
    func reportHack1() throws {
        for hue in Self.warmHues {
            let estimate = try #require(PortalLevelRules.estimate(resonators: [6], unreadSlots: 7, badgeHue: hue,
                                                                  glyphCount: 3, glyphCountSettled: false))
            #expect(estimate.lowest == 1 && estimate.highest == 7, "\(estimate)")
            #expect(estimate.level == nil && estimate.confidence == .low && !estimate.conflict)
            // What was read stays on record.
            #expect(estimate.badgeLevels == [1, 2, 3, 4] && estimate.glyphCount == 3)
        }
        // An unreliable count and a warm badge alone narrow nothing.
        #expect(PortalLevelRules.estimate(resonators: nil, unreadSlots: nil, badgeHue: 10,
                                          glyphCount: 3, glyphCountSettled: false) == nil)
    }

    @Test("Hacks 4, 6 and 10 of the same session stay L7")
    func reportHacks4610() throws {
        // As recorded: (resonators, unread, settled). Badge in the L7 band, 4 Glyphs.
        for (ring, unread, settled) in [([8, 6, 6], 5, false), ([], 8, false), ([6, 6, 8, 7], 4, true)] {
            let estimate = try #require(PortalLevelRules.estimate(resonators: ring, unreadSlots: unread, badgeHue: 295,
                                                                  glyphCount: 4, glyphCountSettled: settled))
            #expect(estimate.level == 7 && estimate.confidence == .medium && !estimate.conflict, "\(ring)")
        }
    }

    @Test("A contradicting count still flags the conflict, as on 2026-10-23 (spikeB hack 2)")
    func contradictingCount() throws {
        // No resonator read, badge at 347° (calibrated L5), 4 Glyphs (L6–L7), command unresolved.
        let spikeB2 = try #require(PortalLevelRules.estimate(resonators: [], unreadSlots: 8, badgeHue: 347.1,
                                                             glyphCount: 4, glyphCountSettled: false))
        #expect(spikeB2.conflict && spikeB2.lowest == 1 && spikeB2.highest == 8 && spikeB2.confidence == .low)
        #expect(spikeB2 == PortalLevelRules.estimate(resonators: [], unreadSlots: 8, badgeHue: 347.1, glyphCount: 4))
        // Others: a full L8 ring against 3 Glyphs; an L8 badge against 3 Glyphs.
        for (ring, unread, hue) in [(Array(repeating: 8, count: 8), 0, nil), (nil, nil, 259.0)] as [([Int]?, Int?, Double?)] {
            let unresolved = PortalLevelRules.estimate(resonators: ring, unreadSlots: unread, badgeHue: hue,
                                                       glyphCount: 3, glyphCountSettled: false)
            let before = PortalLevelRules.estimate(resonators: ring, unreadSlots: unread, badgeHue: hue, glyphCount: 3)
            #expect(unresolved == before && unresolved?.conflict == true && unresolved?.level == 8)
        }
    }

    @Test("An agreeing but unreliable count never narrows the level")
    func agreeingCountDoesNotNarrow() throws {
        // [5, 4, 6] and five unread allow L1–L6; 4 Glyphs (L6–L7) would make it L6.
        let partial = try #require(PortalLevelRules.estimate(resonators: [5, 4, 6], unreadSlots: 5, badgeHue: nil,
                                                             glyphCount: 4, glyphCountSettled: false))
        #expect(partial.lowest == 1 && partial.highest == 6 && !partial.conflict)
        let withoutCount = PortalLevelRules.estimate(resonators: [5, 4, 6], unreadSlots: 5, badgeHue: nil, glyphCount: nil)
        #expect(partial.level == withoutCount?.level && partial.confidence == withoutCount?.confidence)
        #expect(partial.glyphCount == 4, "the count stays recorded")
        // A count alone tells nothing when it's unreliable.
        #expect(PortalLevelRules.estimate(resonators: nil, unreadSlots: nil, badgeHue: nil,
                                          glyphCount: 4, glyphCountSettled: false) == nil)
    }

    @Test("With the command known, every reading is unchanged")
    func settledUnchanged() throws {
        let cases: [([Int]?, Int?, Double?, Int?)] = [
            ([6], 7, 355, 3), ([6], 7, 10, 3), ([8, 6, 6], 5, 295, 4), ([], 8, 295, 4), ([], 8, 347.1, 4),
            ([5, 4, 6], 5, 343, 3), (Array(repeating: 8, count: 8), 0, nil, 3), (nil, nil, nil, 4), (nil, nil, 10, 3),
        ]
        for (ring, unread, hue, count) in cases {
            let settled = PortalLevelRules.estimate(resonators: ring, unreadSlots: unread, badgeHue: hue,
                                                    glyphCount: count, glyphCountSettled: true)
            let before = PortalLevelRules.estimate(resonators: ring, unreadSlots: unread, badgeHue: hue, glyphCount: count)
            #expect(settled == before)
        }
        let hack1 = try #require(PortalLevelRules.estimate(resonators: [6], unreadSlots: 7, badgeHue: 10, glyphCount: 3))
        #expect(hack1.lowest == 3 && hack1.highest == 4, "the settled path is build 100's")
    }

    @Test("A resolved presentation command, or a command window seen without one, settles the count")
    func commandsSettle() {
        #expect(!HackCommandSummary.unobserved.settlesGlyphCount)
        var summary = HackCommandSummary()
        #expect(summary.settlesGlyphCount, "window seen, no command")
        summary.presentation.status = .confirmed; summary.presentation.lastObserved = .complex
        #expect(summary.settlesGlyphCount)
        summary.presentation.status = .unresolved
        #expect(!summary.settlesGlyphCount)
        summary.presentation.status = .noCommandObserved; summary.gear.status = .unresolved
        #expect(summary.settlesGlyphCount, "a key command doesn't change the count")
    }
}
