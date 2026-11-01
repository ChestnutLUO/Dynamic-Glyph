import Foundation
import Testing

/// Glyph assistance as an opt-in: in effect only with a Glyph list, switched
/// on by the first list, the player's switch after that, and existing installs
/// left as they were.
@Suite("Glyph assistance opt-in")
struct GlyphAssistanceTests {
    /// A defaults domain of its own, so the test neither reads nor clobbers
    /// the simulator's real settings.
    private func isolated() throws -> (AppPreferences, UserDefaults, String) {
        let suite = "dynamicglyph-glyph-assistance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    /// What `CaptureEngine.loadStoredTables` does at launch, then the result
    /// of a list loading if there is one that reads.
    private func launch(_ preferences: AppPreferences, listFile: Bool, listLoads: Bool) -> Bool {
        var optIn = preferences.glyphAssistance
        optIn.migrate(listFileExists: listFile)
        if listFile && listLoads { optIn.listLoaded() }
        preferences.glyphAssistance = optIn
        return GlyphAssistance.isInEffect(preferred: optIn.preferred, hasGlyphList: listFile && listLoads)
    }

    /// What `CaptureEngine.importTable` does after a list loads.
    private func importList(_ preferences: AppPreferences) {
        var optIn = preferences.glyphAssistance
        optIn.listLoaded()
        preferences.glyphAssistance = optIn
    }

    // MARK: - Rule 1: in effect only with the switch on and a list loaded

    @Test("Glyph assistance is in effect only with the switch on and a Glyph list loaded")
    func effectiveAssistance() {
        #expect(GlyphAssistance.isInEffect(preferred: true, hasGlyphList: true))
        #expect(!GlyphAssistance.isInEffect(preferred: true, hasGlyphList: false))
        #expect(!GlyphAssistance.isInEffect(preferred: false, hasGlyphList: true))
        #expect(!GlyphAssistance.isInEffect(preferred: false, hasGlyphList: false))
    }

    @Test("A fresh install reads gear only, though the stored switch defaults on")
    func freshInstallIsGearOnly() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(preferences.assistsGlyphs, "the switch's default is unchanged")
        #expect(!launch(preferences, listFile: false, listLoads: false))
        #expect(!preferences.hasLoadedGlyphList)
        #expect(preferences.migratedGlyphAssistanceOptIn)
        #expect(!GlyphAssistance.showsSwitch(hasGlyphList: false))
        // Relaunching without a list changes nothing and asks for nothing.
        #expect(!launch(preferences, listFile: false, listLoads: false))
        #expect(!preferences.hasLoadedGlyphList)
    }

    // MARK: - Rule 5: the first list turns it on; later the switch is the player's

    @Test("The first Glyph list imported turns Glyph assistance on")
    func firstImportTurnsOn() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = launch(preferences, listFile: false, listLoads: false)
        // Even an install whose switch was stored off.
        preferences.assistsGlyphs = false
        importList(preferences)
        #expect(preferences.assistsGlyphs)
        #expect(preferences.hasLoadedGlyphList)
        #expect(GlyphAssistance.showsSwitch(hasGlyphList: true))
        #expect(GlyphAssistance.isInEffect(preferred: preferences.assistsGlyphs, hasGlyphList: true))
    }

    @Test("A list dropped into the app's folder counts as the first import at the next launch")
    func firstListFoundAtLaunch() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = launch(preferences, listFile: false, listLoads: false)
        preferences.assistsGlyphs = false
        #expect(launch(preferences, listFile: true, listLoads: true))
        #expect(preferences.assistsGlyphs && preferences.hasLoadedGlyphList)
    }

    @Test("Off stays off through relaunches and replacing the list")
    func laterImportsKeepOff() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = launch(preferences, listFile: false, listLoads: false)
        importList(preferences)
        preferences.assistsGlyphs = false
        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(!launch(relaunched, listFile: true, listLoads: true))
        #expect(!relaunched.assistsGlyphs)
        importList(relaunched)
        #expect(!relaunched.assistsGlyphs, "replacing the list leaves the switch off")
        // And on stays on.
        relaunched.assistsGlyphs = true
        importList(relaunched)
        #expect(launch(relaunched, listFile: true, listLoads: true))
    }

    @Test("Only the first list loaded reports turning the switch on")
    func listLoadedOnce() {
        var optIn = GlyphAssistance(preferred: false, hasLoadedList: false, migrated: true)
        let first = optIn.listLoaded()
        #expect(first)
        #expect(optIn == GlyphAssistance(preferred: true, hasLoadedList: true, migrated: true))
        optIn.preferred = false
        let second = optIn.listLoaded()
        #expect(!second)
        #expect(!optIn.preferred)
    }

    // MARK: - Rule 6: a list removed or unreadable takes the switch with it

    @Test("A list that is removed or fails to load hides the switch and falls back to gear")
    func removedListFallsBack() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = launch(preferences, listFile: false, listLoads: false)
        importList(preferences)
        #expect(launch(preferences, listFile: true, listLoads: true))
        // Removed from the app's folder.
        #expect(!launch(preferences, listFile: false, listLoads: false))
        #expect(!GlyphAssistance.showsSwitch(hasGlyphList: false))
        // There but unreadable.
        #expect(!launch(preferences, listFile: true, listLoads: false))
        // The switch keeps the player's choice for when a list is back.
        #expect(preferences.assistsGlyphs && preferences.hasLoadedGlyphList)
        preferences.assistsGlyphs = false
        importList(preferences)
        #expect(!preferences.assistsGlyphs, "a list added again is not a first import")
    }

    // MARK: - Rule 7: existing installs

    @Test("An existing install with a list keeps its switch as it was, on or off")
    func existingInstallWithList() throws {
        for stored in [nil, true, false] as [Bool?] {
            let (preferences, defaults, suite) = try isolated()
            defer { defaults.removePersistentDomain(forName: suite) }
            // An older version: the switch as the player left it, no markers.
            if let stored { preferences.assistsGlyphs = stored }
            let inEffect = launch(preferences, listFile: true, listLoads: true)
            #expect(preferences.assistsGlyphs == (stored ?? true), "stored \(String(describing: stored))")
            #expect(inEffect == (stored ?? true))
            #expect(preferences.hasLoadedGlyphList && preferences.migratedGlyphAssistanceOptIn)
            // Untouched stays untouched, and so keeps following the default.
            if stored == nil { #expect(defaults.object(forKey: "capture.assistsGlyphs") == nil) }
            // Replacing the list later is not a first import either.
            preferences.assistsGlyphs = false
            importList(preferences)
            #expect(!preferences.assistsGlyphs)
        }
    }

    @Test("An existing install with an unreadable list keeps its switch for when the list is fixed")
    func existingInstallWithUnreadableList() throws {
        let (preferences, defaults, suite) = try isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.assistsGlyphs = false
        #expect(!launch(preferences, listFile: true, listLoads: false))
        importList(preferences)
        #expect(!preferences.assistsGlyphs)
    }

    @Test("An existing install with no list reads gear only, and its first list turns assistance on")
    func existingInstallWithoutList() throws {
        for stored in [nil, true, false] as [Bool?] {
            let (preferences, defaults, suite) = try isolated()
            defer { defaults.removePersistentDomain(forName: suite) }
            if let stored { preferences.assistsGlyphs = stored }
            #expect(!launch(preferences, listFile: false, listLoads: false))
            #expect(preferences.assistsGlyphs == (stored ?? true), "nothing is rewritten at launch")
            #expect(!preferences.hasLoadedGlyphList)
            importList(preferences)
            #expect(preferences.assistsGlyphs)
        }
    }

    @Test("The migration runs once: a list found on a later launch is a first import")
    func migrationRunsOnce() {
        var optIn = GlyphAssistance(preferred: false, hasLoadedList: false, migrated: false)
        optIn.migrate(listFileExists: false)
        #expect(optIn == GlyphAssistance(preferred: false, hasLoadedList: false, migrated: true))
        optIn.migrate(listFileExists: true)
        #expect(!optIn.hasLoadedList)
        let turnedOn = optIn.listLoaded()
        #expect(turnedOn)
    }
}
