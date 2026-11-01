import Foundation
import Testing
import GlyphRecognition

@Suite("App preferences")
struct AppPreferencesTests {
    /// A defaults domain of its own, so the test neither reads nor clobbers
    /// the simulator's real settings.
    private func isolated() throws -> (AppPreferences, UserDefaults, String) {
        let suite = "dynamicglyph-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    @Test("A first launch shows the floating window, and nothing else is switched on")
    func firstLaunchDefaults() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(preferences.showsFloatingWindow)
        #expect(preferences.assistsGlyphs, "Glyph assistance stays on for everyone who had it")
        #expect(!preferences.showsLiveActivity)
        #expect(!preferences.animatesIslandUpdates)
        #expect(!preferences.savesSessionDiagnostics)
        #expect(!preferences.readsGearDrops)
        // Only a sub-choice of gear reading, which itself starts off.
        #expect(preferences.savesGearPictures)
        #expect(!preferences.protectsFloatingWindowFromCapture)
        #expect(!preferences.recordsSoundInPhotosRecording)
        #expect(preferences.powerSaving, "Phase 1 power saving starts on")
        preferences.powerSaving = false
        #expect(!AppPreferences(defaults: defaults).powerSaving)
        preferences.powerSaving = true
        #expect(preferences.needsSetup)
        #expect(preferences.completedSetupVersion == 0)
        #expect(preferences.reportedDynamicIsland == nil)
    }

    @Test("Choices survive into a new instance, as they would into a new launch")
    func choicesPersist() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.showsFloatingWindow = false
        preferences.showsLiveActivity = true
        preferences.animatesIslandUpdates = true
        preferences.savesSessionDiagnostics = true
        preferences.readsGearDrops = true
        preferences.savesGearPictures = false
        preferences.protectsFloatingWindowFromCapture = true
        preferences.recordsSoundInPhotosRecording = true
        preferences.assistsGlyphs = false

        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(!relaunched.showsFloatingWindow)
        #expect(relaunched.showsLiveActivity)
        #expect(relaunched.animatesIslandUpdates)
        #expect(relaunched.savesSessionDiagnostics)
        #expect(relaunched.readsGearDrops)
        #expect(!relaunched.savesGearPictures)
        #expect(relaunched.protectsFloatingWindowFromCapture)
        #expect(relaunched.recordsSoundInPhotosRecording)
        #expect(!relaunched.assistsGlyphs)
    }

    @Test("The game language is read automatically until chosen, and the one found is kept")
    func gameLanguage() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(preferences.gameLanguage == nil && preferences.detectedGameLanguage == nil)
        preferences.detectedGameLanguage = .japanese
        preferences.gameLanguage = .simplifiedChinese
        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(relaunched.gameLanguage == .simplifiedChinese && relaunched.detectedGameLanguage == .japanese)
        relaunched.gameLanguage = nil
        #expect(AppPreferences(defaults: try #require(UserDefaults(suiteName: suite))).gameLanguage == nil)
        // An unknown stored value reads as automatic, not as a crash or English.
        defaults.set("xx", forKey: "game.language")
        #expect(AppPreferences(defaults: defaults).gameLanguage == nil)
    }

    @Test("The player's faction is unset until chosen, persists, and can be cleared")
    func playerFaction() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(preferences.playerFaction == nil)
        preferences.playerFaction = .resistance
        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(relaunched.playerFaction == .resistance)
        relaunched.playerFaction = .enlightened
        #expect(preferences.playerFaction == .enlightened)
        relaunched.playerFaction = nil
        #expect(preferences.playerFaction == nil)
        defaults.set("future-faction", forKey: "game.playerFaction")
        #expect(preferences.playerFaction == nil)
    }

    @Test("Setup stays due until its current version is finished, and can be run again")
    func setupCompletion() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.reportedDynamicIsland = false
        preferences.completedSetupVersion = AppPreferences.currentSetupVersion - 1
        #expect(preferences.needsSetup, "an older setup is shown again")
        preferences.completedSetupVersion = AppPreferences.currentSetupVersion

        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(!relaunched.needsSetup)
        #expect(relaunched.reportedDynamicIsland == false)
        relaunched.completedSetupVersion = 0
        relaunched.reportedDynamicIsland = nil
        #expect(relaunched.needsSetup)
        #expect(relaunched.reportedDynamicIsland == nil)
    }
}
