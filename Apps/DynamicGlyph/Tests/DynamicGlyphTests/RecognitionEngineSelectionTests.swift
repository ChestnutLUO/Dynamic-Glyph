import Foundation
import Testing

/// Settings' Old (Swift) or New (C++) choice: what it writes, what it reads
/// back, and the custom state Diagnostics or an earlier build can leave.
@Suite("Recognition engine selection in Settings")
struct RecognitionEngineSelectionTests {
    private typealias Configuration = RecognitionEngineSelection.Configuration

    private static let defaultCuts: Set<RecognitionCut> = [.directPlanes, .lazyImage, .huntBand, .huntHalf,
                                                           .planeGate, .headerStillSkip, .gearLeanRead]

    private func isolated() throws -> (AppPreferences, UserDefaults, String) {
        let suite = "dynamicglyph-selection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    private func configuration(_ preferences: AppPreferences) -> Configuration {
        Configuration(engine: preferences.recognitionEngine, logic: preferences.recognitionLogic,
                      cuts: preferences.recognitionCuts)
    }

    @Test("A fresh install shows New, which is the defaults: C++ engine, Swift logic, the seven cuts")
    func freshInstall() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RecognitionEngineSelection(preferences) == .new)
        #expect(RecognitionEngineSelection.new.configuration
                == Configuration(engine: .cpp, logic: .swift, cuts: Self.defaultCuts))
        #expect(RecognitionEngineSelection.new.configuration == configuration(preferences))
        #expect(RecognitionEngineSelection.old.configuration == Configuration(engine: .swift, logic: .swift, cuts: []))
        #expect(RecognitionEngineSelection.custom.configuration == nil)
    }

    @Test("Each choice writes the engine, the logic and the cuts, and reads back after a relaunch")
    func roundTrip() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Cuts a tester set in Diagnostics are replaced by either choice.
        preferences.recognitionCuts = [.lazyImage, .huntBand, .planeGate]
        for choice in [RecognitionEngineSelection.old, .new, .old, .new] {
            choice.apply(to: preferences)
            let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
            #expect(RecognitionEngineSelection(relaunched) == choice)
            let expected = choice == .new ? Configuration(engine: .cpp, logic: .swift, cuts: Self.defaultCuts)
                                          : Configuration(engine: .swift, logic: .swift, cuts: [])
            #expect(configuration(relaunched) == expected)
        }
        // Old stores its empty list, so the defaults don't come back.
        RecognitionEngineSelection.old.apply(to: preferences)
        #expect(defaults.stringArray(forKey: AppPreferences.recognitionCutsKey) == [])
    }

    @Test("Anything but Old or New shows Custom, which changes nothing until a choice is made")
    func custom() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let others = [
            // New as an earlier build stored it, now with the default cuts.
            Configuration(engine: .cpp, logic: .cpp, cuts: Self.defaultCuts),
            // Old as an earlier build stored it, now with the default cuts.
            Configuration(engine: .swift, logic: .swift, cuts: Self.defaultCuts),
            Configuration(engine: .swift, logic: .swift, cuts: [.lazyImage]),
            Configuration(engine: .cpp, logic: .swift, cuts: []),
            // New as the build before the header still skip was a default
            // stored it: the four cuts without it.
            Configuration(engine: .cpp, logic: .swift,
                          cuts: Self.defaultCuts.subtracting([.planeGate, .headerStillSkip, .gearLeanRead])),
            // New as the build before the plane gate was a default stored it:
            // the five cuts without it.
            Configuration(engine: .cpp, logic: .swift,
                          cuts: Self.defaultCuts.subtracting([.planeGate, .gearLeanRead])),
            // New as the build before the gear lean read was a default stored
            // it: the six cuts without it.
            Configuration(engine: .cpp, logic: .swift, cuts: Self.defaultCuts.subtracting([.gearLeanRead])),
            Configuration(engine: .cpp, logic: .swift, cuts: Self.defaultCuts.union([.gearSettle])),
            Configuration(engine: .cpp, logic: .swift, cuts: Self.defaultCuts.union([.portalSettle])),
            Configuration(engine: .cpp, logic: .swift, cuts: [.directPlanes, .lazyImage, .huntBand]),
            Configuration(engine: .swift, logic: .cpp, cuts: [])
        ]
        for other in others {
            preferences.recognitionEngine = other.engine
            preferences.recognitionLogic = other.logic
            preferences.recognitionCuts = other.cuts
            #expect(RecognitionEngineSelection(preferences) == .custom, "\(other)")
            RecognitionEngineSelection.custom.apply(to: preferences)
            #expect(configuration(preferences) == other)
            RecognitionEngineSelection.old.apply(to: preferences)
            #expect(RecognitionEngineSelection(preferences) == .old)
        }
        #expect(RecognitionEngineSelection.choices == [.old, .new])
        #expect(Set([RecognitionEngineSelection.old.label, RecognitionEngineSelection.new.label,
                     RecognitionEngineSelection.custom.label]).count == 3)
    }

    @Test("A tester who chose on an earlier build, with no cuts stored, sees Custom and runs the default cuts",
          arguments: ["cpp", "swift"])
    func earlierBuildChoice(engineAndLogic: String) throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        // The earlier picker wrote both keys, never the cuts: New wrote C++
        // twice, Old Swift twice.
        defaults.set(engineAndLogic, forKey: AppPreferences.recognitionEngineKey)
        defaults.set(engineAndLogic, forKey: AppPreferences.recognitionLogicKey)
        #expect(RecognitionEngineSelection(preferences) == .custom)
        #expect(preferences.recognitionEngine.rawValue == engineAndLogic)
        #expect(preferences.recognitionLogic.rawValue == engineAndLogic)
        #expect(preferences.recognitionCuts == Self.defaultCuts)
        RecognitionEngineSelection.new.apply(to: preferences)
        #expect(RecognitionEngineSelection(preferences) == .new)
    }
}
