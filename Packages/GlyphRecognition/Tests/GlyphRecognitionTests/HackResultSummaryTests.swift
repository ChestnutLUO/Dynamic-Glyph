import Foundation
import Testing
@testable import GlyphRecognition

@Suite("Hack result summaries")
struct HackResultSummaryTests {
    let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 3), hackID: 2,
                                    glyphs: ["help", "resistance", nil, "victory"])

    func result(finalHacking: Int? = 120, observedHacking: Int? = 120, finalSpeed: Int? = 49,
                observedSpeed: Int? = 49, outcomes: [GameSlotOutcome] = [.accepted, .rejected, .unknown, .accepted],
                state: HackResult.State = .partial, closedAt: Double? = 5) -> HackResult {
        var result = HackResult(context: context, outcomes: outcomes, outcomeTimes: outcomes.map { _ in nil })
        result.state = state
        result.finalHackingBonus = finalHacking; result.observedHackingBonus = observedHacking
        result.finalSpeedBonus = finalSpeed; result.observedSpeedBonus = observedSpeed
        result.closedAt = closedAt; result.closeReason = closedAt == nil ? nil : "panelLeft"
        return result
    }

    func entry(_ slot: Int, _ verdict: InputCheckVerdict?, _ outcome: GameSlotOutcome,
               _ status: ValidatorResultComparison.Status) -> ValidatorResultComparison.Entry {
        ValidatorResultComparison.Entry(slotIndex: slot, attemptID: slot + 1, validatorVerdict: verdict,
                                        gameOutcome: outcome, status: status)
    }

    @Test("Final and last-seen bonuses stay distinct; a never-read value stays missing")
    func bonuses() {
        let final = HackResultSummary(result: result(), comparison: [])
        #expect(final.hackingBonus == .init(percent: 120, isFinal: true))
        #expect(final.speedBonus == .init(percent: 49, isFinal: true))
        #expect(!final.hasProvisionalBonus)
        let lastSeen = HackResultSummary(result: result(finalHacking: nil, observedHacking: 90), comparison: [])
        #expect(lastSeen.hackingBonus == .init(percent: 90, isFinal: false))
        #expect(lastSeen.hasProvisionalBonus)
        let unread = HackResultSummary(result: result(finalSpeed: nil, observedSpeed: nil), comparison: [])
        #expect(unread.speedBonus == nil)
        #expect(HackResultSummary.percentText(unread.speedBonus) == nil)
        #expect(HackResultSummary.percentText(.init(percent: 0, isFinal: true)) == "0%")
    }

    @Test("Slots keep their Glyph, outcome and comparison; a missing entry is an unknown link")
    func slots() {
        let summary = HackResultSummary(result: result(), comparison: [
            entry(0, .matched, .accepted, .agreement),
            entry(1, .matched, .rejected, .disagreement),
        ])
        #expect(summary.slots.map(\.glyph) == ["help", "resistance", nil, "victory"])
        #expect(summary.slots.map(\.outcome) == [.accepted, .rejected, .unknown, .accepted])
        #expect(summary.slots[0].check == .matched && summary.slots[0].comparison == .agreement)
        #expect(summary.slots[3].check == nil && summary.slots[3].comparison == .unknownAssociation)
        #expect(summary.isClosed && summary.closeReason == "panelLeft")
        #expect(summary.runKey == "3/2")
    }

    @Test("A saved summary decodes to exactly what was shown")
    func codableRoundTrip() throws {
        let summary = HackResultSummary(result: result(finalHacking: nil, observedHacking: 90),
                                        comparison: [entry(1, .differs, .rejected, .agreement)])
        let decoded = try JSONDecoder().decode(HackResultSummary.self, from: JSONEncoder().encode(summary))
        #expect(decoded == summary)
        let timed = HackResultSummary.Slot(glyph: "help", outcome: .accepted, check: .matched,
                                           comparison: .agreement, drawSeconds: 1.25)
        #expect(try JSONDecoder().decode(HackResultSummary.Slot.self, from: JSONEncoder().encode(timed)) == timed)
        // Results saved before drawing times were kept still decode.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(timed)) as? [String: Any])
        object["drawSeconds"] = nil
        let old = try JSONDecoder().decode(HackResultSummary.Slot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.drawSeconds == nil && old.glyph == "help")
    }

    @Test("Only real disagreements are listed; coverage gaps and unknown links are not")
    func disagreements() {
        let summary = HackResultSummary(result: result(outcomes: [.accepted, .rejected, .accepted, .unknown]),
                                        comparison: [
            entry(0, .differs, .accepted, .disagreement),
            entry(1, .matched, .rejected, .disagreement),
            entry(2, .unavailable, .accepted, .coverageGap),
            entry(3, nil, .unknown, .unknownGameOutcome),
        ])
        #expect(summary.disagreementLines.count == 2)
        #expect(summary.disagreementLines[0].contains("1") && summary.disagreementLines[0].contains("warned"))
        #expect(summary.disagreementLines[1].contains("2") && summary.disagreementLines[1].contains("matched"))
    }

    @Test("Headlines never call an unread result a rejection", arguments: [
        (HackResult.State.awaiting, nil as String?, "Waiting for the result screen…"),
        (.complete, "panelLeft", "Result read"),
        (.partial, "panelLeft", "Result partly read"),
        (.notObserved, "resultTimeout", "No result screen seen"),
        (.notObserved, "captureStopped", "Stopped before the result screen"),
    ])
    func headlines(state: HackResult.State, reason: String?, expected: String) {
        let summary = HackResultSummary(captureSessionID: 1, hackID: 1, state: state, isClosed: reason != nil,
                                        closeReason: reason, hackingBonus: nil, speedBonus: nil, slots: [])
        #expect(summary.headline == expected)
    }

    @Test("Outcome labels and VoiceOver name the Glyph and say when the verdict is unread")
    func labels() {
        let summary = HackResultSummary(result: result(), comparison: [])
        #expect(HackResultSummary.outcomeLabel(.unknown) == "Unread")
        #expect(summary.accessibilityLabel(slot: 0) == "Glyph 1, help: accepted by the game")
        #expect(summary.accessibilityLabel(slot: 2) == "Glyph 3, ?: the game's verdict couldn't be read")
        #expect(summary.glyphCountLine == "4 Glyphs")
    }

    @Test("The log keeps one entry per hack, newest first, and replaces updates in place")
    func log() {
        var log = HackResultLog(limit: 2)
        func summary(_ hack: Int, _ state: HackResult.State) -> HackResultSummary {
            HackResultSummary(captureSessionID: 1, hackID: hack, state: state, isClosed: state != .awaiting,
                              closeReason: nil, hackingBonus: nil, speedBonus: nil, slots: [])
        }
        log.record(summary(1, .awaiting))
        log.record(summary(1, .complete))
        #expect(log.entries.map(\.state) == [.complete])
        log.record(summary(2, .awaiting))
        log.record(summary(3, .awaiting))
        #expect(log.entries.map(\.hackID) == [3, 2])
        log.record(summary(2, .partial))
        #expect(log.entries.map(\.hackID) == [3, 2] && log.entries[1].state == .partial)
    }

    @Test("A capture origin round-trips; older summaries read without one, and values from later builds read as unknown")
    func captureOrigin() throws {
        var summary = HackResultSummary(result: result(), comparison: [])
        let plain = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(HackResultSummary.self, from: plain).origin == nil)
        #expect(!String(decoding: plain, as: UTF8.self).contains("origin"), "No origin, no key: older builds read it as before")
        summary.origin = CaptureOrigin(appVersion: "0.1.0", appBuild: "73", captureMode: .gearOnly, gameLanguage: .japanese,
                                       gameLanguageSource: .chosen, utcOffsetMinutes: 345)
        #expect(try JSONDecoder().decode(HackResultSummary.self, from: JSONEncoder().encode(summary)) == summary)
        let later = Data(#"{"appBuild":"99","captureMode":"somethingNew","gameLanguage":"xx","gameLanguageSource":"guessed","utcOffsetMinutes":60}"#.utf8)
        let origin = try JSONDecoder().decode(CaptureOrigin.self, from: later)
        #expect(origin.appBuild == "99" && origin.utcOffsetMinutes == 60)
        #expect(origin.captureMode == nil && origin.gameLanguage == nil && origin.gameLanguageSource == nil)
        var withFaction = summary
        withFaction.origin?.playerFaction = .resistance
        #expect(try JSONDecoder().decode(HackResultSummary.self, from: JSONEncoder().encode(withFaction))
                    .origin?.playerFaction == .resistance)
        let unknown = Data(#"{"playerFaction":"neutral","utcOffsetMinutes":0}"#.utf8)
        #expect(try JSONDecoder().decode(CaptureOrigin.self, from: unknown).playerFaction == nil)
    }
}
