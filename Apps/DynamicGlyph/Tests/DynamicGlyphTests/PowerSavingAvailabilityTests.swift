import Testing

/// The power-saving switch is a tester tool, shown only where the others are
/// (Debug, the Simulator, TestFlight). Where it isn't shown, as in an App
/// Store build, capture always saves power, whatever an earlier TestFlight
/// install stored.
@Suite("Power saving where the tester tools are hidden")
struct PowerSavingAvailabilityTests {
    @Test("With the tools, the stored switch decides; without them, power saving is always on")
    func effective() {
        #expect(AppPreferences.effectivePowerSaving(stored: true, toolsAvailable: true))
        #expect(!AppPreferences.effectivePowerSaving(stored: false, toolsAvailable: true))
        #expect(AppPreferences.effectivePowerSaving(stored: true, toolsAvailable: false))
        #expect(AppPreferences.effectivePowerSaving(stored: false, toolsAvailable: false),
                "a false stored by a TestFlight install can't switch it off unseen")
    }
}
