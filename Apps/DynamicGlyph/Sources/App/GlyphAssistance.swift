import Foundation

/// Glyph assistance is something a player opts into by adding a Glyph list
/// in Settings. Without a list the app reads gear only, whatever the stored
/// switch says, and nothing asks for the list.
///
/// The first list this install loads, imported in Settings or found in the
/// app's folder at launch, turns the switch on. After that the switch is the
/// player's: off stays off through relaunches and replacing the list. Pure,
/// so each rule can be tested; `AppPreferences` keeps it between launches.
struct GlyphAssistance: Equatable {
    /// The Settings switch, `capture.assistsGlyphs`. On by default, so an
    /// install that had a list and never touched the switch keeps it on.
    var preferred: Bool
    /// A Glyph list has loaded on this install at least once, or this install
    /// already had one when it first launched a version with this rule.
    var hasLoadedList: Bool
    /// `migrate(listFileExists:)` has run on this install.
    var migrated: Bool

    /// In effect only with the switch on and a Glyph list loaded. Every
    /// Glyph-or-gear branch in the app keys on this, not on the switch alone.
    static func isInEffect(preferred: Bool, hasGlyphList: Bool) -> Bool {
        preferred && hasGlyphList
    }

    /// The switch is shown only once there is a list for it to use; a list
    /// that is removed or fails to load takes the switch with it.
    static func showsSwitch(hasGlyphList: Bool) -> Bool { hasGlyphList }

    /// Once per install, at launch, before the stored list is read. An
    /// install that already has a list is not a first import: its switch
    /// stays exactly as the player left it. One without a list changes
    /// nothing now; its first list will turn the switch on.
    mutating func migrate(listFileExists: Bool) {
        guard !migrated else { return }
        if listFileExists { hasLoadedList = true }
        migrated = true
    }

    /// After a Glyph list loads successfully. Turns the switch on the first
    /// time only; returns whether it did.
    @discardableResult
    mutating func listLoaded() -> Bool {
        guard !hasLoadedList else { return false }
        hasLoadedList = true
        let turnedOn = !preferred
        preferred = true
        return turnedOn
    }
}
