import Foundation
import Testing

/// What slows recognition, as Diagnostics ("Slowed: …") and the session log
/// ("slowed: …") say it: Low Power Mode and heat apart, so a report tells
/// one from the other. Verbatim tester text, never translated.
@Suite("Power slowdown wording")
struct PowerSlowdownWordingTests {
    typealias State = PowerConditions.State

    @Test("Each trigger, alone and together, has its own words")
    func wording() {
        let cases: [(Bool, ProcessInfo.ThermalState, String)] = [
            (false, .nominal, "no"), (false, .fair, "no"),
            (false, .serious, "warm (serious)"), (false, .critical, "warm (critical)"),
            (true, .nominal, "Low Power Mode"), (true, .fair, "Low Power Mode"),
            (true, .serious, "Low Power Mode, warm (serious)"), (true, .critical, "Low Power Mode, warm (critical)"),
        ]
        for (lowPower, thermal, expected) in cases {
            let state = State(lowPowerMode: lowPower, thermalState: thermal)
            #expect(state.slowdown == expected, "\(lowPower) \(thermal.rawValue)")
            // "no" exactly when recognition is not constrained.
            #expect((state.slowdown == "no") == !state.isConstrained)
        }
    }

    @Test("The session log keeps both triggers apart, with the thermal state by name")
    func logRow() {
        let row = State(lowPowerMode: true, thermalState: .serious).logRow
        #expect(row["lowPowerMode"] as? Bool == true && row["thermalState"] as? String == "serious")
        let names = [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical]
            .map { State(lowPowerMode: false, thermalState: $0).logRow["thermalState"] as? String }
        #expect(names == ["nominal", "fair", "serious", "critical"])
    }
}
