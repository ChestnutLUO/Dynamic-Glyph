import Foundation
import GlyphRecognition

/// Choices the player makes once and expects to find again on the next launch.
///
/// Screen recording is deliberately not here: recording the whole display is a
/// consent decision for one session, not a setting.
struct AppPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var showsFloatingWindow: Bool {
        get { bool("display.floatingWindow", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "display.floatingWindow") }
    }

    var showsLiveActivity: Bool {
        get { bool("display.liveActivity", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "display.liveActivity") }
    }

    /// Whether the Dynamic Island keeps the system's update animation. Off by
    /// default: on a phone it slid the compact Island on every update.
    var animatesIslandUpdates: Bool {
        get { bool("display.liveActivity.animatesUpdates", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "display.liveActivity.animatesUpdates") }
    }

    /// Whether a session leaves its logs and screenshots in the app's folder.
    /// The language Ingress shows, as the player chose it; nil reads it
    /// automatically. Ingress has its own language setting, apart from iOS.
    var gameLanguage: GameLanguage? {
        get { defaults.string(forKey: "game.language").flatMap(GameLanguage.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: "game.language") }
    }

    /// The player's faction, set in Settings; nil until set. Only Resistance
    /// and Enlightened can be chosen. Stamped on each record as it is made,
    /// so changing it never changes what earlier hacks say.
    var playerFaction: PortalFaction? {
        get { defaults.string(forKey: "game.playerFaction").flatMap(PortalFaction.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: "game.playerFaction") }
    }

    /// The language automatic reading last found, where the next capture starts.
    var detectedGameLanguage: GameLanguage? {
        get { defaults.string(forKey: "game.detectedLanguage").flatMap(GameLanguage.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: "game.detectedLanguage") }
    }

    /// Off until the player asks for it: they include pictures of the screen.
    var savesSessionDiagnostics: Bool {
        get { bool("diagnostics.saveSessions", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "diagnostics.saveSessions") }
    }

    /// Whether a session reads the game's result screen after each hack. Off
    /// means no result text recognition runs at all.
    var readsHackResults: Bool {
        get { bool("results.read", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "results.read") }
    }

    /// Whether results read this way are kept after the app closes. Separate
    /// from session logs: a result holds no pictures of the screen.
    var keepsHackResults: Bool {
        get { bool("results.keep", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "results.keep") }
    }

    /// Whether saved results are mirrored to the player's private iCloud. Off
    /// until the player asks: results otherwise never leave the phone.
    var syncsHackResults: Bool {
        get { bool("results.iCloudSync", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "results.iCloudSync") }
    }

    /// The Glyph assistance switch as the player left it. It takes effect
    /// only while a Glyph list is loaded (`GlyphAssistance.isInEffect`); off,
    /// or with no list, capture reads only the item panels after each hack.
    var assistsGlyphs: Bool {
        get { bool("capture.assistsGlyphs", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "capture.assistsGlyphs") }
    }

    /// Set once a Glyph list has loaded on this install, so only the first
    /// one turns Glyph assistance on.
    var hasLoadedGlyphList: Bool {
        get { bool("capture.glyphList.hasLoaded", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "capture.glyphList.hasLoaded") }
    }

    /// Set once this install has run the Glyph assistance opt-in migration.
    var migratedGlyphAssistanceOptIn: Bool {
        get { bool("capture.glyphList.optInMigrated", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "capture.glyphList.optInMigrated") }
    }

    /// The switch and the opt-in markers together, read and written as one.
    var glyphAssistance: GlyphAssistance {
        get {
            GlyphAssistance(preferred: assistsGlyphs, hasLoadedList: hasLoadedGlyphList,
                            migrated: migratedGlyphAssistanceOptIn)
        }
        nonmutating set {
            // Written only when changed: an untouched switch stays unset, and
            // so keeps following its default.
            if newValue.preferred != assistsGlyphs { assistsGlyphs = newValue.preferred }
            hasLoadedGlyphList = newValue.hasLoadedList
            migratedGlyphAssistanceOptIn = newValue.migrated
        }
    }

    /// Whether a session reads the item panels after each hack. A tester
    /// feature: it works only while session logs are kept.
    var readsGearDrops: Bool {
        get { bool("results.gear.read", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "results.gear.read") }
    }

    /// Whether gear reading keeps a picture of each item panel, title hidden,
    /// in the session's logs. On by default: checking a reading needs them.
    var savesGearPictures: Bool {
        get { bool("results.gear.pictures", default: true) }
        nonmutating set { defaults.set(newValue, forKey: "results.gear.pictures") }
    }

    /// Asks iOS to keep the floating window out of screenshots and screen
    /// recordings.
    var protectsFloatingWindowFromCapture: Bool {
        get { bool("pip.preventsCapture", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "pip.preventsCapture") }
    }

    /// Whether a recording saved to Photos includes the device's sound.
    var recordsSoundInPhotosRecording: Bool {
        get { bool("recording.photos.includesSound", default: false) }
        nonmutating set { defaults.set(newValue, forKey: "recording.photos.includesSound") }
    }

    /// Phase 1 power saving, read when a capture starts. A tester switch in
    /// Diagnostics, so one build can compare the pipeline with and without it.
    static let powerSavingKey = "diagnostics.powerSavingPhase1"
    var powerSaving: Bool {
        get { bool(Self.powerSavingKey, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Self.powerSavingKey) }
    }

    /// Power saving as a capture uses it. The switch exists only where the
    /// tester tools do (`toolsAvailable`: Debug, the Simulator, TestFlight);
    /// elsewhere, as in an App Store build, it is always on, so a `false`
    /// stored by a TestFlight install can't carry over unseen.
    static func effectivePowerSaving(stored: Bool, toolsAvailable: Bool) -> Bool {
        stored || !toolsAvailable
    }

    /// Colours the floating window's background by the analysis gate's mode.
    /// A TestFlight-only debug switch in Diagnostics, off until a tester asks.
    static let colorsFloatingWindowByModeKey = "diagnostics.floatingWindowModeColors"
    var colorsFloatingWindowByMode: Bool {
        get { bool(Self.colorsFloatingWindowByModeKey, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Self.colorsFloatingWindowByModeKey) }
    }

    /// Raised when setup gains a page every player should see; anyone who
    /// finished an older version is shown it again.
    static let currentSetupVersion = 1

    /// The setup version the player last finished. Zero until setup reaches
    /// its last page: quitting partway shows it again on the next launch.
    var completedSetupVersion: Int {
        get { defaults.integer(forKey: "setup.completedVersion") }
        nonmutating set { defaults.set(newValue, forKey: "setup.completedVersion") }
    }

    var needsSetup: Bool { completedSetupVersion < Self.currentSetupVersion }

    /// The player's answer to "Does your iPhone have a Dynamic Island?", kept
    /// for when setup runs again. Nil until they have answered.
    var reportedDynamicIsland: Bool? {
        get { (defaults.object(forKey: "setup.reportedDynamicIsland") as? NSNumber)?.boolValue }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: "setup.reportedDynamicIsland") }
            else { defaults.removeObject(forKey: "setup.reportedDynamicIsland") }
        }
    }

    /// `bool(forKey:)` reads a missing key as false, which would turn the
    /// floating window off for everyone who has never touched the switch.
    private func bool(_ key: String, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? fallback
    }
}
