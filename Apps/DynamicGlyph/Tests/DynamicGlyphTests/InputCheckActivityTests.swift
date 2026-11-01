import Foundation
import Testing
import GlyphRecognition

@Suite("Input check activity payload")
struct InputCheckActivityTests {
    @Test("Gear status changes the Island key and remains compatible with old payloads")
    func gearPayload() throws {
        let blank = GlyphActivityContentState(slots: [], phase: "completed", statusLine: "",
            predictionState: "unavailable", candidateCount: 0, expectedSlotCount: nil,
            hackID: 1, revision: 1, isProvisional: false)
        #expect(try JSONDecoder().decode(GlyphActivityContentState.self, from: JSONEncoder().encode(blank)).gear == nil)
        var keys: Set<String> = []
        for state: GearDropDisplay.State in [.waiting, .reading, .read, .partial, .unattached, .notRead, .watching] {
            var content = blank
            content.gear = GearDropDisplay(state: state, hackID: 1, itemCount: 16, waitingCount: 2)
            #expect(content.semanticKey != blank.semanticKey)
            keys.insert(content.semanticKey)
            let data = try JSONEncoder().encode(content)
            #expect(data.count < 4096)
            #expect(try JSONDecoder().decode(GlyphActivityContentState.self, from: data) == content)
            var schedule = ActivityUpdateSchedule<GlyphActivityContentState>()
            schedule.didSend(key: blank.semanticKey, at: 0)
            _ = schedule.offer(content, key: content.semanticKey, freshUntil: 3, at: 0.05)
            _ = schedule.offer(content, key: content.semanticKey, freshUntil: 3.2, at: 0.2)
            #expect(schedule.take(at: 0.4)?.content.gear == content.gear)
        }
        #expect(keys.count == 7)
    }
    @Test("Guidance and drop readings lapse in 3 s, watching in 30 s, and waiting never")
    func freshness() {
        var content = GlyphActivityContentState(slots: [], phase: "inactive", statusLine: "",
            predictionState: "unavailable", candidateCount: 0, expectedSlotCount: nil,
            hackID: 0, revision: 1, isProvisional: false)
        #expect(content.freshnessLifetime == nil)
        content.gear = GearDropDisplay(state: .watching, hackID: nil, itemCount: 12)
        #expect(content.freshnessLifetime == 30)
        content.gear = GearDropDisplay(state: .read, hackID: nil, itemCount: 4)
        #expect(content.freshnessLifetime == 3)
        content.gear = nil
        content.upcoming = [.init(provenance: .observed, name: "alpha", shape: "038")]
        #expect(content.freshnessLifetime == 3)
    }

    @Test("Every verdict changes the send key and survives the widget payload round trip")
    func payload() throws {
        let blank = GlyphActivityContentState(
            slots: [.init(provenance: .observed, name: "alpha", shape: "038")],
            phase: "input", statusLine: "", predictionState: "unavailable", candidateCount: 0,
            expectedSlotCount: 2, hackID: 1, revision: 1, isProvisional: false)
        for verdict: InputCheckVerdict in [.matched, .differs, .unavailable] {
            var checked = blank
            checked.slots[0].inputCheck = InputCheckDisplay(verdict: verdict, expectedGlyph: "alpha",
                                                           sourceTime: 10, attemptID: 1)
            #expect(checked.semanticKey != blank.semanticKey)
            let data = try JSONEncoder().encode(checked)
            let decoded = try JSONDecoder().decode(GlyphActivityContentState.self, from: data)
            #expect(decoded == checked)
            #expect(decoded.slots[0].inputCheck?.verdict == verdict)
            #expect(decoded.slots[0].inputCheck?.sourceTime == 10)
        }
    }

    @Test("Five verdicts fit the Activity content budget and check-mark expiry changes the key")
    func sizeAndExpiry() throws {
        let check = InputCheckDisplay(verdict: .matched, expectedGlyph: "clear_all", sourceTime: 100,
                                      attemptID: 100)
        let slot = GlyphActivityContentState.Slot(provenance: .observed, name: "clear_all",
                                                  shape: "0568a975", inputCheck: check)
        let state = GlyphActivityContentState(slots: Array(repeating: slot, count: 5),
            phase: "input", statusLine: "Your turn", predictionState: "resolved", candidateCount: 1,
            expectedSlotCount: 5, hackID: 1, revision: 10, isProvisional: false)
        #expect(try JSONEncoder().encode(state).count < 4096)
        var expired = state
        expired.slots[0].inputCheck = InputCheckDisplay(verdict: .matched, expectedGlyph: "clear_all",
                                                       sourceTime: 100, attemptID: 100, showsSymbol: false)
        #expect(expired.semanticKey != state.semanticKey)
    }
}
