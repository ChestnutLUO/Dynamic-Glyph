#if targetEnvironment(simulator)
import Foundation
import SwiftData
import SwiftUI
import GlyphRecognition

/// Simulator-only data for App Store screenshots: made-up hacks and gear in an
/// in-memory store, and the app's own demo shapes, so Home, Statistics and a
/// hack's details look in use without game pictures, personal data or the
/// third-party Glyph tables. Nothing here is compiled into a device build.
/// The Summary widget shows the demo hacks too, until a launch without it.
///
/// On with the Settings switch below, or `-screenshotDemo YES` at launch.
/// Read once per launch: the switch applies after a relaunch.
enum ScreenshotDemo {
    static let defaultsKey = "screenshotDemo"
    static let isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)

    /// Generic words, drawn with the app's original demo shapes rather than
    /// the game's: no reference data is used.
    static let glyphNames = ["Harmony", "Peace", "Advance", "Civilization", "Truth"]

    /// `SetupDemo.builtInTable`'s shapes under `glyphNames`, so result tiles
    /// draw a diagram for every name the demo hacks use.
    static let shapeTable: GlyphTable = {
        let builtIn = SetupDemo.builtInTable
        var entries: [GlyphID: GlyphPath] = [:]
        for (name, id) in zip(glyphNames, builtIn.glyphs) {
            if let path = builtIn.path(for: id) { entries[GlyphID(name)] = path }
        }
        return GlyphTable(entries: entries)
    }()

    /// Kept for the app's life: the store holds only a context.
    @MainActor private static var container: ModelContainer?

    /// Results backed by an in-memory store that never syncs, seeded with the
    /// demo hacks. Their choices live in a separate defaults suite, reset at
    /// each launch, so the player's own result settings are left alone.
    @MainActor
    static func makeResults(now: Date = Date()) -> HackResults {
        let suiteName = "org.szres.DynamicGlyph.screenshotDemo"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.register(defaults: [
            "results.read": true, "results.keep": true, "results.iCloudSync": false,
            "results.gear.read": true, "results.gear.pictures": false
        ])
        let preferences = AppPreferences(defaults: defaults)
        do {
            let demoContainer = try HackResultStore.makeContainer(inMemory: true, syncing: false)
            container = demoContainer
            let store = HackResultStore(container: demoContainer)
            try seed(store, now: now)
            // Written for the Summary widget too, so it fills with the demo
            // hacks; a launch without the demo writes the real ones again.
            return HackResults(preferences: preferences, store: store, widget: .shared)
        } catch {
            return HackResults(preferences: preferences, store: nil, storageError: error)
        }
    }

    // MARK: - Demo hacks

    private struct Item {
        let name: String
        var level: Int? = nil
        var quantity = 1
        var rarity: GearDropEntry.Rarity? = nil
        var multiplied: Bool? = nil
    }

    private enum Gear {
        case read(portal: [Item], bonus: [Item])
        case notRead
        /// Gear reading was off for this hack.
        case off
    }

    private struct Hack {
        let daysAgo: Int
        /// Minutes after midnight; today's hacks are minutes before now instead.
        let minutes: Int
        let level: Int
        let faction: PortalFaction
        /// Indices into `glyphNames`; three, four or five by portal level.
        let glyphs: [Int]
        var rejected: Set<Int> = []
        let speedBonus: Int
        /// Seconds per Glyph from the input screen to submitting.
        let pace: Double
        let presentation: HackCommand?
        let keys: HackCommand?
        let gear: Gear
    }

    private static let hacks: [Hack] = [
        Hack(daysAgo: 0, minutes: 18, level: 8, faction: .enlightened, glyphs: [0, 1, 2, 3, 4], speedBonus: 24,
             pace: 1.6, presentation: .complex, keys: .requestKey,
             gear: .read(portal: [Item(name: "Resonator", level: 8, quantity: 2),
                                  Item(name: "XMP Burster", level: 8, quantity: 3),
                                  Item(name: "Portal Key"),
                                  Item(name: "Power Cube", level: 7)],
                         bonus: [Item(name: "Ultra Strike", level: 8, quantity: 2),
                                 Item(name: "Heat Sink", rarity: .rare),
                                 Item(name: "Resonator", level: 7, quantity: 2)])),
        Hack(daysAgo: 0, minutes: 74, level: 7, faction: .resistance, glyphs: [2, 0, 3, 1], speedBonus: 19,
             pace: 1.8, presentation: .complex, keys: .noKey,
             gear: .read(portal: [Item(name: "Resonator", level: 7, quantity: 3),
                                  Item(name: "XMP Burster", level: 7, quantity: 2)],
                         bonus: [Item(name: "Portal Shield", rarity: .common),
                                 Item(name: "XMP Burster", level: 6, quantity: 2)])),
        Hack(daysAgo: 1, minutes: 19 * 60 + 42, level: 6, faction: .resistance, glyphs: [1, 4, 2, 0],
             rejected: [3], speedBonus: 9, pace: 2.2, presentation: .simple, keys: .requestKey,
             gear: .read(portal: [Item(name: "Resonator", level: 6, quantity: 2),
                                  Item(name: "Portal Key"),
                                  Item(name: "Power Cube", level: 6, quantity: 2)],
                         bonus: [Item(name: "XMP Burster", level: 6, quantity: 2)])),
        // Late in the evening, so a timed range across midnight has a hack.
        Hack(daysAgo: 1, minutes: 23 * 60 + 10, level: 7, faction: .enlightened, glyphs: [0, 4, 1, 3], speedBonus: 18,
             pace: 1.8, presentation: .complex, keys: .noKey,
             gear: .read(portal: [Item(name: "Resonator", level: 7, quantity: 2),
                                  Item(name: "Power Cube", level: 7)],
                         bonus: [Item(name: "XMP Burster", level: 7, quantity: 2)])),
        Hack(daysAgo: 1, minutes: 12 * 60 + 5, level: 5, faction: .enlightened, glyphs: [3, 0, 2], speedBonus: 28,
             pace: 1.5, presentation: .complex, keys: nil,
             gear: .read(portal: [Item(name: "Resonator", level: 5, quantity: 3, multiplied: true),
                                  Item(name: "XMP Burster", level: 5, quantity: 2, multiplied: true)],
                         bonus: [Item(name: "Multi-Hack", rarity: .common)])),
        Hack(daysAgo: 2, minutes: 18 * 60 + 30, level: 8, faction: .machina, glyphs: [4, 2, 1, 3, 0],
             rejected: [4], speedBonus: 15, pace: 1.9, presentation: .complex, keys: .requestKey,
             gear: .read(portal: [Item(name: "XMP Burster", level: 8, quantity: 2),
                                  Item(name: "Resonator", level: 8),
                                  Item(name: "Portal Key")],
                         bonus: [Item(name: "Ultra Strike", level: 8),
                                 Item(name: "Power Cube", level: 8, quantity: 2),
                                 Item(name: "Portal Shield", rarity: .veryRare)])),
        Hack(daysAgo: 3, minutes: 8 * 60 + 50, level: 7, faction: .enlightened, glyphs: [0, 3, 4, 1], speedBonus: 21,
             pace: 1.7, presentation: .complex, keys: .noKey, gear: .notRead),
        Hack(daysAgo: 3, minutes: 17 * 60 + 12, level: 6, faction: .resistance, glyphs: [2, 1, 0, 4], speedBonus: 17,
             pace: 1.9, presentation: .complex, keys: .requestKey,
             gear: .read(portal: [Item(name: "Resonator", level: 6, quantity: 2),
                                  Item(name: "XMP Burster", level: 5, quantity: 2),
                                  Item(name: "Portal Key")],
                         bonus: [Item(name: "Heat Sink", rarity: .common),
                                 Item(name: "Resonator", level: 6)])),
        Hack(daysAgo: 4, minutes: 20 * 60 + 3, level: 5, faction: .resistance, glyphs: [4, 1, 3],
             rejected: [1], speedBonus: 6, pace: 2.4, presentation: .simple, keys: nil, gear: .off),
        Hack(daysAgo: 5, minutes: 13 * 60 + 27, level: 8, faction: .enlightened, glyphs: [1, 3, 0, 4, 2], speedBonus: 22,
             pace: 1.7, presentation: .complex, keys: .requestKey,
             gear: .read(portal: [Item(name: "Resonator", level: 8, quantity: 2),
                                  Item(name: "XMP Burster", level: 7, quantity: 2),
                                  Item(name: "Portal Key")],
                         bonus: [Item(name: "Ultra Strike", level: 7, quantity: 2),
                                 Item(name: "Link Amp", rarity: .rare)])),
        Hack(daysAgo: 6, minutes: 10 * 60 + 15, level: 7, faction: .resistance, glyphs: [3, 2, 4, 0], speedBonus: 12,
             pace: 2.0, presentation: .complex, keys: .noKey,
             gear: .read(portal: [Item(name: "Resonator", level: 7, quantity: 2),
                                  Item(name: "Power Cube", level: 7)],
                         bonus: [Item(name: "XMP Burster", level: 7, quantity: 3)])),
        // The week before, so the 7-day totals have something to compare with.
        // Days 7, 8 and 10 ago stay empty: a past day with no hacks.
        Hack(daysAgo: 9, minutes: 18 * 60, level: 6, faction: .enlightened, glyphs: [0, 2, 1, 4],
             rejected: [2], speedBonus: 8, pace: 2.3, presentation: .simple, keys: .requestKey,
             gear: .read(portal: [Item(name: "Resonator", level: 6, quantity: 2), Item(name: "Portal Key")],
                         bonus: [Item(name: "XMP Burster", level: 6)])),
        Hack(daysAgo: 11, minutes: 12 * 60 + 40, level: 5, faction: .resistance, glyphs: [2, 4, 3], speedBonus: 14,
             pace: 2.1, presentation: .complex, keys: nil,
             gear: .read(portal: [Item(name: "Resonator", level: 5, quantity: 2)],
                         bonus: [Item(name: "Power Cube", level: 5)]))
    ]

    /// Saved through the store's own calls, as a capture would save them.
    @MainActor
    private static func seed(_ store: HackResultStore, now: Date) throws {
        for ((index, hack), date) in zip(hacks.enumerated(), hackDates(now: now)) {
            // One capture session a day, numbered from 1, hacks counted in it.
            let session = UInt64(hack.daysAgo + 1)
            let hackID = index + 1
            let key = "screenshot-demo/\(session)/\(hackID)"
            try store.save(summary(hack, session: session, hackID: hackID), key: key, date: date, now: now)
            if let gear = attachment(hack, session: session, hackID: hackID) {
                try store.saveGear(gear, key: key, date: date)
            }
        }
    }

    /// When each demo hack happened: today's minutes before `now`, earlier
    /// ones at their time of day.
    static func hackDates(now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return hacks.map { hack in
            if hack.daysAgo == 0 { return now.addingTimeInterval(-Double(hack.minutes) * 60) }
            let day = calendar.date(byAdding: .day, value: -hack.daysAgo, to: today) ?? today
            return calendar.date(byAdding: .minute, value: hack.minutes, to: day) ?? day
        }
    }

    private static func summary(_ hack: Hack, session: UInt64, hackID: Int) -> HackResultSummary {
        let count = hack.glyphs.count
        let slots = hack.glyphs.enumerated().map { index, glyph -> HackResultSummary.Slot in
            let accepted = !hack.rejected.contains(index)
            // The last Glyph is never checked or timed, as in a real capture.
            let isLast = index == count - 1
            return HackResultSummary.Slot(
                glyph: glyphNames[glyph], outcome: accepted ? .accepted : .rejected,
                check: isLast ? nil : (accepted ? InputCheckVerdict.matched : InputCheckVerdict.differs),
                comparison: isLast ? .unknownAssociation : .agreement,
                drawSeconds: isLast ? nil : hack.pace * 0.6 + Double((glyph + index) % 3) * 0.15)
        }
        let acceptedCount = count - hack.rejected.count
        var commands = HackCommandSummary()
        commands.mode = .portal
        if let command = hack.presentation { commands.presentation = confirmed(command) }
        if let command = hack.keys { commands.gear = confirmed(command) }
        return HackResultSummary(
            captureSessionID: session, hackID: hackID, state: .complete, isClosed: true, closeReason: "panelLeft",
            hackingBonus: .init(percent: acceptedCount * 100 / count, isFinal: true),
            speedBonus: .init(percent: hack.speedBonus, isFinal: true),
            slots: slots, inputSeconds: hack.pace * Double(count), commands: commands)
    }

    private static func confirmed(_ command: HackCommand) -> HackCommandSummary.Selection {
        var selection = HackCommandSummary.Selection()
        selection.status = .confirmed
        selection.lastObserved = command
        selection.samples = 3
        selection.language = "en"
        return selection
    }

    private static func attachment(_ hack: Hack, session: UInt64, hackID: Int) -> HackGearAttachment? {
        let reading: HackGearAttachment.Reading
        switch hack.gear {
        case .off:
            return nil
        case .notRead:
            reading = .notRead(reason: "waitExpired")
        case .read(let portal, let bonus):
            reading = .read(GearDropSummary(
                groupID: hackID, startedAt: 0, closedAt: 2, closeReason: "panelLeft", hackID: hackID,
                association: .ordered, panels: [panel(.portal, portal), panel(.bonus, bonus)]))
        }
        // The level from a full ring of resonators that agrees with the Glyph count.
        let ring: [Int] = switch hack.level {
        case 8: [8, 8, 8, 8, 8, 8, 8, 8]
        case 7: [8, 8, 8, 8, 7, 7, 6, 6]
        case 6: [7, 7, 6, 6, 6, 6, 5, 5]
        default: [6, 6, 5, 5, 5, 5, 4, 4]
        }
        var level = PortalLevelRules.estimate(resonators: ring, unreadSlots: 0, badgeHue: nil,
                                              glyphCount: hack.glyphs.count)
        level?.factionCode = hack.faction.rawValue
        return HackGearAttachment(captureSessionID: session, hackID: hackID, reading: reading, pictures: [],
                                  portalLevel: level)
    }

    private static func panel(_ stage: GearDropStage, _ items: [Item]) -> GearDropSummary.Panel {
        let entries = items.enumerated().map { index, item in
            GearDropEntry(column: index % 2, row: index / 2, item: item.name,
                          levelState: item.level == nil ? .notApplicable : .known, level: item.level,
                          quantity: item.quantity, rarity: item.rarity, multiplied: item.multiplied ?? false)
        }
        return GearDropSummary.Panel(stage: stage, entries: entries, partial: false)
    }
}

/// The last row of Settings, on the Simulator only. Not localized: it never
/// reaches a player.
struct ScreenshotDemoSection: View {
    @AppStorage(ScreenshotDemo.defaultsKey) private var isOn = false

    var body: some View {
        Section {
            Toggle(isOn: $isOn) { Text(verbatim: "Screenshot demo data") }
        } footer: {
            Text(verbatim: "Simulator only. Relaunch the app to apply.")
        }
    }
}
#endif
