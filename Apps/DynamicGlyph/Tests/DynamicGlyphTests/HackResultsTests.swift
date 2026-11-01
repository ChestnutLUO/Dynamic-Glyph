import CoreData
import Foundation
import SwiftData
import Testing
import GlyphRecognition

@MainActor
@Suite("Hack results store and page model")
struct HackResultsTests {
    private func isolatedPreferences() throws -> (AppPreferences, UserDefaults, String) {
        let suite = "dynamicglyph-results-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    private func summary(hack: Int, state: HackResult.State, closed: Bool, session: UInt64 = 1,
                         hacking: Int? = 120) -> HackResultSummary {
        HackResultSummary(captureSessionID: session, hackID: hack, state: state, isClosed: closed,
                          closeReason: closed ? "panelLeft" : nil,
                          hackingBonus: hacking.map { .init(percent: $0, isFinal: state == .complete) },
                          speedBonus: .init(percent: 49, isFinal: state == .complete),
                          slots: [.init(glyph: "help", outcome: .accepted, check: .matched, comparison: .agreement)])
    }

    /// A clock the test advances by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test("Command metadata survives storage and cannot be replaced after the result closes")
    func commandsInHistory() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        var commands = HackCommandSummary()
        commands.gear.status = .confirmed; commands.gear.lastObserved = .keysOnly
        commands.gear.samples = 1; commands.gear.language = "en"
        let completed = HackResultSummary(captureSessionID: 1, hackID: 1, state: .complete, isClosed: true,
                                          closeReason: "panelLeft", hackingBonus: nil, speedBonus: nil,
                                          slots: [], commands: commands)
        results.receive(completed)
        results.receive(summary(hack: 1, state: .complete, closed: true))
        #expect(try store.records().first?.summary?.commands == commands)
        #expect(results.records.first?.summary?.commands == commands)
        let relaunched = HackResults(preferences: preferences, store: store)
        #expect(relaunched.records.first?.summary?.commands == commands)
    }

    @Test("A hack is shown while in progress and saved once, when it closes")
    func savesOnClose() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try HackResultStore.makeContainer(inMemory: true)
        let store = HackResultStore(container: container)
        let results = HackResults(preferences: preferences, store: store)
        results.receive(summary(hack: 1, state: .awaiting, closed: false))
        #expect(results.records.count == 1)
        #expect(try store.records().isEmpty)
        results.receive(summary(hack: 1, state: .partial, closed: false))
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receive(summary(hack: 1, state: .complete, closed: true))
        #expect(results.records.count == 1)
        #expect(results.records.first?.summary?.state == .complete)
        let saved = try store.records()
        #expect(saved.count == 1)
        #expect(saved.first?.summary == summary(hack: 1, state: .complete, closed: true))
        // A new page model over the same store sees it, as a relaunch would.
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        #expect(relaunched.records.map(\.summary) == [summary(hack: 1, state: .complete, closed: true)])
    }

    @Test("With keeping off, results stay in memory and nothing is saved")
    func keepingOff() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.keepsHackResults = false
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        results.receive(summary(hack: 1, state: .complete, closed: true))
        #expect(results.records.count == 1)
        #expect(try store.records().isEmpty)
    }

    @Test("Retention removes entries past 90 days and beyond the count limit")
    func retention() throws {
        let clock = Clock()
        var limits = HackResultStore.Retention()
        limits.maximumCount = 3
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true), retention: limits)
        let old = clock.now.addingTimeInterval(-91 * 24 * 60 * 60)
        try store.save(summary(hack: 1, state: .complete, closed: true), key: "old", date: old, now: clock.now)
        #expect(try store.records().isEmpty)
        for hack in 2...6 {
            try store.save(summary(hack: hack, state: .complete, closed: true), key: "k\(hack)",
                           date: clock.now.addingTimeInterval(Double(hack)), now: clock.now)
        }
        #expect(try store.records().map(\.id) == ["k6", "k5", "k4"])
        // Pruning also runs at launch, against the time then.
        clock.now = clock.now.addingTimeInterval(95 * 24 * 60 * 60)
        try store.prune(now: clock.now)
        #expect(try store.records().isEmpty)
    }

    @Test("Clearing removes saved and finished results but keeps a hack in progress")
    func clear() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receive(summary(hack: 2, state: .awaiting, closed: false))
        results.clear()
        #expect(try store.records().isEmpty)
        #expect(results.records.map(\.summary?.hackID) == [2])
        results.receive(summary(hack: 2, state: .complete, closed: true))
        #expect(try store.records().count == 1)
    }

    @Test("Cleared hacks ignore retirement and late open deliveries, including after memory eviction")
    func clearedResultsStayCleared() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        for hack in 1...55 { results.receive(summary(hack: hack, state: .complete, closed: true)) }
        results.receive(summary(hack: 56, state: .awaiting, closed: false))
        results.clear()
        // Both a hack evicted from the 50-entry memory log and the latest
        // closed hack can be delivered again. Neither may undo Clear.
        for hack in [1, 55] {
            results.receive(summary(hack: hack, state: .complete, closed: true))
            results.receive(summary(hack: hack, state: .partial, closed: false))
        }
        #expect(results.records.map(\.summary?.hackID) == [56])
        #expect(try store.records().isEmpty)
        results.receive(summary(hack: 56, state: .complete, closed: true))
        #expect(try store.records().map(\.summary?.hackID) == [56])
    }

    @Test("Enabling persistence cannot save an earlier unkept hack on retirement")
    func persistenceChoiceAtClosure() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.keepsHackResults = false
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.keepsResults = true
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receive(summary(hack: 1, state: .awaiting, closed: false))
        #expect(try store.records().isEmpty)
        #expect(results.records.first?.summary?.state == .complete)
        results.receive(summary(hack: 2, state: .complete, closed: true))
        #expect(try store.records().map(\.summary?.hackID) == [2])
    }

    @Test("Without a store, results are kept in memory and the reason is shown")
    func storeUnavailable() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let results = HackResults(preferences: preferences, store: nil, storageError: CocoaError(.fileWriteNoPermission))
        #expect(results.problem != nil)
        results.receive(summary(hack: 1, state: .complete, closed: true))
        #expect(results.records.count == 1)
    }

    @Test("Hacks from different capture sessions stay separate, newest first")
    func sessionsStaySeparate() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store, now: { clock.now })
        results.receive(summary(hack: 1, state: .complete, closed: true, session: 1, hacking: 60))
        clock.now = clock.now.addingTimeInterval(60)
        results.receive(summary(hack: 1, state: .complete, closed: true, session: 2, hacking: 90))
        #expect(results.records.map(\.summary?.hackingBonus?.percent) == [90, 60])
        #expect(try store.records().count == 2)
    }

    @Test("A saved record in an unknown format is listed, not reinterpreted")
    func unknownFormat() throws {
        let container = try HackResultStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(SavedHackResult(key: "future", date: Date(), summaryVersion: 99, summary: Data("{}".utf8)))
        try context.save()
        let records = try HackResultStore(container: container).records()
        #expect(records.count == 1 && records.first?.summary == nil)
    }

    @Test("Switch choices persist and default to on")
    func preferences() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(preferences.readsHackResults && preferences.keepsHackResults)
        let results = HackResults(preferences: preferences, store: nil)
        results.readsResults = false
        results.keepsResults = false
        let relaunched = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(!relaunched.readsHackResults && !relaunched.keepsHackResults)
    }

    private func gear(hack: Int, session: UInt64 = 1, quantity: Int = 2) -> HackGearAttachment {
        let entry = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 8, quantity: quantity)
        let group = GearDropSummary(groupID: hack, startedAt: 10, closedAt: 14, closeReason: "panelLeft", hackID: hack,
                                    association: .ordered, panels: [.init(stage: .portal, entries: [entry], partial: false,
                                                                        effects: ["ITO EN (+)"])])
        return HackGearAttachment(captureSessionID: session, hackID: hack, reading: .read(group))
    }

    @Test("Gear read after a saved result is saved with it and survives a relaunch")
    func gearSaved() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try HackResultStore.makeContainer(inMemory: true)
        let results = HackResults(preferences: preferences, store: HackResultStore(container: container))
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receiveGear(gear(hack: 1))
        #expect(results.records.first?.gear == gear(hack: 1))
        // A second reading for the same hack never replaces the first.
        results.receiveGear(gear(hack: 1, quantity: 9))
        #expect(results.records.first?.gear == gear(hack: 1))
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        #expect(relaunched.records.first?.gear == gear(hack: 1))
    }

    @Test("Different shield rarities survive saved history and relaunch separately")
    func gearRaritySaved() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try HackResultStore.makeContainer(inMemory: true)
        let results = HackResults(preferences: preferences, store: HackResultStore(container: container))
        results.receive(summary(hack: 1, state: .complete, closed: true))
        let entries: [GearDropEntry] = [
            .init(column: 0, row: 0, item: "Portal Shield", levelState: .notApplicable, level: nil, quantity: 2, rarity: .rare),
            .init(column: 0, row: 1, item: "Portal Shield", levelState: .notApplicable, level: nil, quantity: 1, rarity: .veryRare)]
        let group = GearDropSummary(groupID: 1, startedAt: 10, closedAt: 14, closeReason: "panelLeft", hackID: 1,
            association: .ordered, panels: [.init(stage: .portal, entries: entries, partial: false)])
        let attachment = HackGearAttachment(captureSessionID: 1, hackID: 1, reading: .read(group))
        results.receiveGear(attachment)
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        #expect(relaunched.records.first?.gear == attachment)
    }

    @Test("Gear that arrives before its result closes is saved when the result is")
    func gearBeforeClose() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        results.receive(summary(hack: 1, state: .partial, closed: false))
        results.receiveGear(gear(hack: 1))
        #expect(results.records.first?.gear == gear(hack: 1))
        #expect(try store.records().isEmpty)
        results.receive(summary(hack: 1, state: .complete, closed: true))
        #expect(try store.records().first?.gear == gear(hack: 1))
    }

    @Test("With keeping off, gear stays in memory; a gear-only hack is never saved")
    func gearNotKept() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.keepsHackResults = false
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receiveGear(gear(hack: 1))
        #expect(results.records.first?.gear == gear(hack: 1))
        try store.saveGear(gear(hack: 2), key: "no-result", date: Date())
        #expect(try store.records().isEmpty)
    }

    @Test("Clearing results also stops a late gear reading from bringing a hack back")
    func gearAfterClear() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receive(summary(hack: 2, state: .partial, closed: false))
        results.clear()
        results.receiveGear(gear(hack: 1))
        results.receiveGear(gear(hack: 2))
        #expect(results.records.map(\.summary?.hackID) == [2])
        #expect(results.records.first?.gear == gear(hack: 2))
        #expect(try store.records().isEmpty)
    }

    @Test("Retention removes a hack's gear with its result")
    func gearRetention() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var limits = HackResultStore.Retention()
        limits.maximumCount = 1
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true), retention: limits)
        try store.save(summary(hack: 1, state: .complete, closed: true), key: "a", date: now, now: now)
        try store.saveGear(gear(hack: 1), key: "a", date: now)
        try store.save(summary(hack: 2, state: .complete, closed: true), key: "b", date: now.addingTimeInterval(1), now: now)
        try store.saveGear(gear(hack: 2), key: "b", date: now)
        let records = try store.records()
        #expect(records.map(\.id) == ["b"] && records.first?.gear == gear(hack: 2))
        try store.save(summary(hack: 3, state: .complete, closed: true), key: "c", date: now.addingTimeInterval(2), now: now)
        #expect(try store.records().map(\.gear) == [nil])
    }

    @Test("Gear synced before its result is kept for it, unless it is past the age limit")
    func gearBeforeItsResult() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let container = try HackResultStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let store = HackResultStore(container: container)
        // As an import can leave them: gear whose result is still on its way.
        let fresh = try JSONEncoder().encode(gear(hack: 1)), old = try JSONEncoder().encode(gear(hack: 2))
        context.insert(SavedHackGear(key: "other/1", date: now, gearVersion: 1, gear: fresh))
        context.insert(SavedHackGear(key: "other/2", date: now.addingTimeInterval(-91 * 24 * 60 * 60),
                                     gearVersion: 1, gear: old))
        try context.save()
        try store.save(summary(hack: 3, state: .complete, closed: true), key: "here/3", date: now, now: now)
        #expect(try context.fetch(FetchDescriptor<SavedHackGear>()).map(\.key) == ["other/1"])
        context.insert(SavedHackResult(key: "other/1", date: now, summaryVersion: 1,
                                       summary: try JSONEncoder().encode(summary(hack: 1, state: .complete, closed: true))))
        try context.save()
        #expect(try store.records().first { $0.id == "other/1" }?.gear == gear(hack: 1))
    }

    @Test("A store written by the first version opens with its results and no gear")
    func migratesVersionOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gear-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("HackResults.store")
        do {
            let schema = Schema(versionedSchema: HackResultSchemaV1.self)
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration("HackResults", schema: schema, url: url))
            let context = ModelContext(old)
            let data = try JSONEncoder().encode(summary(hack: 1, state: .complete, closed: true))
            context.insert(HackResultSchemaV1.SavedHackResult(key: "old", date: Date(), summaryVersion: 1, summary: data))
            try context.save()
        }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: false, url: url))
        let records = try store.records()
        #expect(records.map(\.id) == ["old"] && records.first?.gear == nil)
        try store.saveGear(gear(hack: 1), key: "old", date: Date())
        #expect(try store.records().first?.gear == gear(hack: 1))
    }

    @Test("A panel picture resolves only to one gear JPEG inside one session folder")
    func picturePaths() throws {
        let root = URL(fileURLWithPath: "/tmp/documents", isDirectory: true)
        let good = HackGearPicture(path: "spikeB-2026-09-25T01-56-13Z/gear-110.310000.jpg", stage: .portal)
        #expect(good.url(in: root)?.path == "/tmp/documents/spikeB-2026-09-25T01-56-13Z/gear-110.310000.jpg")
        for path in ["../spikeB-x/gear-1.jpg", "spikeB-x/../gear-1.jpg", "spikeB-x/sub/gear-1.jpg", "/spikeB-x/gear-1.jpg",
                     "spikeB-x/frames.csv", "other/gear-1.jpg", "spikeB-x/", "gear-1.jpg"] {
            #expect(HackGearPicture(path: path, stage: .bonus).url(in: root) == nil, "\(path)")
        }
    }

    @Test("Gear saved before pictures existed still opens, with no pictures")
    func gearWithoutPictures() throws {
        var attachment = gear(hack: 1)
        attachment.pictures = [HackGearPicture(path: "spikeB-x/gear-1.jpg", stage: .bonus)]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
        #expect(object["pictures"] != nil)
        object.removeValue(forKey: "pictures")
        let decoded = try JSONDecoder().decode(HackGearAttachment.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.pictures == nil && decoded.reading == attachment.reading)
    }

    @Test("A portal level is saved with the gear, and older gear opens without one")
    func portalLevelSaved() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try HackResultStore.makeContainer(inMemory: true)
        let results = HackResults(preferences: preferences, store: HackResultStore(container: container))
        results.receive(summary(hack: 1, state: .complete, closed: true))
        var attachment = gear(hack: 1)
        attachment.portalLevel = PortalLevelRules.estimate(resonators: [8, 6, 7, 6, 6, 6, 8, 7], unreadSlots: 0,
                                                           badgeHue: 329, glyphCount: 4)
        results.receiveGear(attachment)
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        let level = try #require(relaunched.records.first?.gear?.portalLevel)
        #expect(level.level == 6 && level.confidence == .high && level.glyphCount == 4)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
        object.removeValue(forKey: "portalLevel")
        let older = try JSONDecoder().decode(HackGearAttachment.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.portalLevel == nil && older.reading == attachment.reading)
    }

    @Test("A hack's portal faction is saved with its gear and survives a relaunch")
    func portalFactionSaved() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try HackResultStore.makeContainer(inMemory: true)
        let results = HackResults(preferences: preferences, store: HackResultStore(container: container))
        results.receive(summary(hack: 1, state: .complete, closed: true))
        var attachment = gear(hack: 1)
        let screen = PortalScreenEvidence(sourceTime: 1, resonators: [1, 1, 1, 1, 1, 1, 1, 1], unreadSlots: 0,
                                          badgeHue: nil, faction: .machina)
        attachment.portalLevel = PortalLevelRules.estimate(screen: screen, glyphCount: 1)
        results.receiveGear(attachment)
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        #expect(relaunched.records.first?.gear?.portalLevel?.faction == .machina)
    }

    @Test("Checking a reading shows one picture per panel, the middle of those saved")
    func onePicturePerPanel() {
        var attachment = gear(hack: 1)
        #expect(attachment.panelPictures.isEmpty)
        attachment.pictures = (0..<4).map { HackGearPicture(path: "spikeB-x/gear-p\($0).jpg", stage: .portal) }
            + (0..<3).map { HackGearPicture(path: "spikeB-x/gear-b\($0).jpg", stage: .bonus) }
        #expect(attachment.panelPictures.map(\.path) == ["spikeB-x/gear-p2.jpg", "spikeB-x/gear-b1.jpg"])
        attachment.pictures = [HackGearPicture(path: "spikeB-x/gear-b0.jpg", stage: .bonus)]
        #expect(attachment.panelPictures.map(\.stage) == [.bonus])
    }

    @Test("The saved schema is one iCloud can mirror: no unique attributes, a default for each")
    func cloudKitSchema() {
        let schema = Schema(versionedSchema: HackResultSchemaV4.self)
        #expect(schema.entities.map(\.name).sorted() == ["SavedGearDrop", "SavedHackGear", "SavedHackResult"])
        for entity in schema.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name)")
            for attribute in entity.attributes {
                #expect(!attribute.isUnique, "\(entity.name).\(attribute.name)")
                #expect(attribute.isOptional || attribute.defaultValue != nil, "\(entity.name).\(attribute.name)")
            }
        }
        // The check sees the constraint iCloud rejects.
        let original = Schema(versionedSchema: HackResultSchemaV1.self).entities.flatMap(\.attributes)
        #expect(original.contains { $0.isUnique })
    }

    /// Stores on players' phones record these hashes; a migration plan finds
    /// a store by them. A released version that changes, even by naming a
    /// newer class, strands every store written with it. The V2 values are
    /// the ones a real store written by that version recorded. V4 is pinned
    /// from its first build, before any store was written with it.
    @Test("Released schema versions keep the model hashes their stores recorded",
          arguments: [("V1", HackResultSchemaV1.models, ["SavedHackResult": "t1ocD0m1jdw4RDCHIoJxK7Ki4UZv05R/7/J35aNSQPs="]),
                      ("V2", HackResultSchemaV2.models, ["SavedHackResult": "t1ocD0m1jdw4RDCHIoJxK7Ki4UZv05R/7/J35aNSQPs=",
                                                         "SavedHackGear": "7PP20zAnJ+ZD/Xu44zXEgDgCcUNbZ4WmULj36VYwt8Q="]),
                      ("V3", HackResultSchemaV3.models, ["SavedHackResult": "726lLcoZY7Y42SHlpf8XEVoWU/II2OiFYwBRSU/oyjU=",
                                                         "SavedHackGear": "mtcVKiU5SQwWOb59yzbsTAcvgqWpOWAbt3PqE9MuQ84="]),
                      ("V4", HackResultSchemaV4.models, ["SavedHackResult": "726lLcoZY7Y42SHlpf8XEVoWU/II2OiFYwBRSU/oyjU=",
                                                         "SavedHackGear": "mtcVKiU5SQwWOb59yzbsTAcvgqWpOWAbt3PqE9MuQ84=",
                                                         "SavedGearDrop": "zU5TNynDlbnEh5BPpoPWA+njUchviH1jIRV5XTvUZ3c="])])
    func releasedSchemaHashes(_ version: (String, [any PersistentModel.Type], [String: String])) throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: version.1))
        let hashes = model.entityVersionHashesByName.mapValues { $0.base64EncodedString() }
        #expect(hashes == version.2, "\(version.0)")
    }

    @Test("A store written with gear opens under the syncable schema with everything in it")
    func migratesVersionTwo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("HackResults.store")
        let result = summary(hack: 1, state: .complete, closed: true)
        do {
            let schema = Schema(versionedSchema: HackResultSchemaV2.self)
            let old = try ModelContainer(for: schema, migrationPlan: nil,
                                         configurations: ModelConfiguration("HackResults", schema: schema, url: url,
                                                                            cloudKitDatabase: .none))
            let context = ModelContext(old)
            context.insert(HackResultSchemaV1.SavedHackResult(key: "v2", date: Date(), summaryVersion: 1,
                                                              summary: try JSONEncoder().encode(result)))
            context.insert(HackResultSchemaV2.SavedHackGear(key: "v2", date: Date(), gearVersion: 1,
                                                            gear: try JSONEncoder().encode(gear(hack: 1))))
            try context.save()
        }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: false, url: url))
        let records = try store.records()
        #expect(records.map(\.id) == ["v2"] && records.first?.summary == result)
        #expect(records.first?.gear == gear(hack: 1))
    }

    @Test("A second copy of a hack, as a sync can leave, is read once and removed by the next prune or save")
    func duplicates() throws {
        let container = try HackResultStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let data = try JSONEncoder().encode(summary(hack: 1, state: .complete, closed: true))
        let gearData = try JSONEncoder().encode(gear(hack: 1))
        for _ in 0..<2 {
            context.insert(SavedHackResult(key: "twice", date: Date(), summaryVersion: 1, summary: data))
            context.insert(SavedHackGear(key: "twice", date: Date(), gearVersion: 1, gear: gearData))
        }
        try context.save()
        let store = HackResultStore(container: container)
        #expect(try store.records().map(\.id) == ["twice"])
        try store.prune(now: Date())
        #expect(try context.fetchCount(FetchDescriptor<SavedHackResult>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<SavedHackGear>()) == 1)
        context.insert(SavedHackResult(key: "twice", date: Date(), summaryVersion: 1, summary: data))
        try context.save()
        try store.save(summary(hack: 1, state: .partial, closed: true), key: "twice", date: Date(), now: Date())
        #expect(try store.records().map(\.summary?.state) == [.partial])
        #expect(try context.fetchCount(FetchDescriptor<SavedHackResult>()) == 1)
    }

    @Test("iCloud sync is off by default; turning it on reopens the store and keeps this run's results")
    func syncSwitch() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!preferences.syncsHackResults)
        let container = try HackResultStore.makeContainer(inMemory: true)
        var opened: [Bool] = []
        // The reopened store stands in for the synced one: it already has a
        // hack from another iPhone.
        let synced = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        try synced.save(summary(hack: 9, state: .complete, closed: true, session: 7), key: "other/7/9",
                        date: Date(), now: Date())
        let results = HackResults(preferences: preferences, store: HackResultStore(container: container),
                                  reopen: { syncing in opened.append(syncing); return (synced, nil) })
        results.receive(summary(hack: 1, state: .awaiting, closed: false))
        results.syncsWithICloud = true
        results.syncsWithICloud = true
        #expect(opened == [true])
        #expect(AppPreferences(defaults: try #require(UserDefaults(suiteName: suite))).syncsHackResults)
        #expect(Set(results.records.compactMap(\.summary?.hackID)) == [1, 9])
        // This run's hack is saved to the reopened store when it closes.
        results.receive(summary(hack: 1, state: .complete, closed: true))
        #expect(try synced.records().count == 2)
        #expect(results.problem == nil)
    }

    @Test("Results leave the phone only while they're read, kept and synced")
    func uploadsResults() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let results = HackResults(preferences: preferences,
                                  store: HackResultStore(container: try HackResultStore.makeContainer(inMemory: true)))
        results.readsResults = true
        results.keepsResults = true
        #expect(!results.uploadsResults(assistsGlyphs: true))
        results.syncsWithICloud = true
        #expect(results.uploadsResults(assistsGlyphs: true))
        results.keepsResults = false
        #expect(!results.uploadsResults(assistsGlyphs: true), "Nothing new is saved, so nothing new is uploaded")
        results.keepsResults = true
        results.readsResults = false
        #expect(!results.uploadsResults(assistsGlyphs: true))
        #expect(results.uploadsResults(assistsGlyphs: false), "Gear-only capture reads the item panels anyway")
    }

    @Test("A store that can't reopen keeps results in memory and says why")
    func syncReopenFailure() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let results = HackResults(preferences: preferences,
                                  store: HackResultStore(container: try HackResultStore.makeContainer(inMemory: true)),
                                  reopen: { _ in (nil, CocoaError(.fileReadNoPermission)) })
        results.syncsWithICloud = true
        results.receive(summary(hack: 1, state: .complete, closed: true))
        #expect(results.records.count == 1)
        #expect(results.problem != nil)
    }

    // MARK: - Drops no Glyph hack claimed

    private func drop(group: Int, session: UInt64 = 1, quantity: Int = 2,
                      association: GearDropSummary.Association = .noWaitingHack) -> GearDrop {
        let entry = GearDropEntry(column: 0, row: 0, item: "Power Cube", levelState: .known, level: 7, quantity: quantity)
        let summary = GearDropSummary(groupID: group, startedAt: 10, closedAt: 14, closeReason: "panelLeft", hackID: nil,
                                      association: association,
                                      panels: [.init(stage: .portal, entries: [entry], partial: false)])
        return GearDrop(captureSessionID: session, summary: summary)
    }

    @Test("A drop is saved once with its association and survives a relaunch")
    func dropSaved() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let container = try HackResultStore.makeContainer(inMemory: true)
        let results = HackResults(preferences: preferences, store: HackResultStore(container: container), now: { clock.now })
        results.receiveDrop(drop(group: 1, association: .uncertainContinuity))
        clock.now = clock.now.addingTimeInterval(30)
        results.receiveDrop(drop(group: 2))
        // Delivered again, as a late callback could: neither copy replaces it.
        results.receiveDrop(drop(group: 2, quantity: 9))
        #expect(results.drops.map(\.drop) == [drop(group: 2), drop(group: 1, association: .uncertainContinuity)])
        #expect(results.records.isEmpty, "A drop is not a hack")
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        #expect(relaunched.drops.map(\.drop?.summary.association) == [.noWaitingHack, .uncertainContinuity])
        #expect(try HackResultStore(container: container).drops().count == 2)
    }

    @Test("With keeping off, drops stay in memory, bounded like results")
    func dropsNotKept() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.keepsHackResults = false
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        for group in 1...60 { results.receiveDrop(drop(group: group)) }
        #expect(results.drops.count == HackResultLog().limit)
        #expect(results.drops.first?.drop?.summary.groupID == 60)
        #expect(try store.drops().isEmpty)
    }

    @Test("Clearing removes saved and unsaved drops, and a late delivery can't bring one back")
    func dropsCleared() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store)
        results.receiveDrop(drop(group: 1))
        results.keepsResults = false
        results.receiveDrop(drop(group: 2))
        #expect(results.drops.count == 2)
        results.clear()
        #expect(results.drops.isEmpty)
        #expect(try store.drops().isEmpty)
        results.keepsResults = true
        results.receiveDrop(drop(group: 1))
        #expect(try results.drops.isEmpty && store.drops().isEmpty)
        results.receiveDrop(drop(group: 3))
        #expect(results.drops.map(\.drop?.summary.groupID) == [3])
    }

    @Test("Drops age out after 90 days and have their own count limit")
    func dropRetention() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var limits = HackResultStore.Retention()
        limits.maximumCount = 2
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true), retention: limits)
        try store.save(summary(hack: 1, state: .complete, closed: true), key: "hack", date: now, now: now)
        try store.saveDrop(drop(group: 1), key: "old", date: now.addingTimeInterval(-91 * 24 * 60 * 60), now: now)
        #expect(try store.drops().isEmpty)
        for group in 2...4 {
            try store.saveDrop(drop(group: group), key: "d\(group)", date: now.addingTimeInterval(Double(group)), now: now)
        }
        #expect(try store.drops().map(\.id) == ["d4", "d3"])
        #expect(try store.records().map(\.id) == ["hack"], "Drops don't count against hacks")
        try store.prune(now: now.addingTimeInterval(95 * 24 * 60 * 60))
        #expect(try store.drops().isEmpty)
    }

    @Test("Saving a hack or a drop retires expired history of both kinds from the page")
    func pruneAcrossCollections() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: preferences, store: store, now: { clock.now })
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receiveDrop(drop(group: 1))
        // The app stays open past the age limit; the next save prunes both.
        clock.now = clock.now.addingTimeInterval(91 * 24 * 60 * 60)
        results.receiveDrop(drop(group: 2))
        #expect(try store.records().isEmpty)
        #expect(results.records.isEmpty, "The expired hack left with the drop's save")
        #expect(results.drops.map(\.drop?.summary.groupID) == [2])
        clock.now = clock.now.addingTimeInterval(91 * 24 * 60 * 60)
        results.receive(summary(hack: 2, state: .complete, closed: true))
        #expect(try store.drops().isEmpty)
        #expect(results.drops.isEmpty, "The expired drop left with the hack's save")
        #expect(results.records.map(\.summary?.hackID) == [2])
    }

    @Test("A second copy of a drop, as a sync can leave, is read once and removed by the next prune")
    func dropDuplicates() throws {
        let container = try HackResultStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let data = try JSONEncoder().encode(drop(group: 1))
        for _ in 0..<2 { context.insert(SavedGearDrop(key: "twice", date: Date(), dropVersion: 1, drop: data)) }
        try context.save()
        let store = HackResultStore(container: container)
        #expect(try store.drops().map(\.id) == ["twice"])
        try store.prune(now: Date())
        #expect(try context.fetchCount(FetchDescriptor<SavedGearDrop>()) == 1)
        try store.saveDrop(drop(group: 1, quantity: 5), key: "twice", date: Date(), now: Date())
        #expect(try store.drops().first?.drop == drop(group: 1, quantity: 5))
        #expect(try context.fetchCount(FetchDescriptor<SavedGearDrop>()) == 1)
    }

    @Test("A drop saved in an unknown format is listed, not reinterpreted")
    func dropUnknownFormat() throws {
        let container = try HackResultStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(SavedGearDrop(key: "future", date: Date(), dropVersion: 99, drop: Data("{}".utf8)))
        try context.save()
        let drops = try HackResultStore(container: container).drops()
        #expect(drops.count == 1 && drops.first?.drop == nil)
    }

    @Test("A store written by the syncable version opens with no drops and keeps everything")
    func migratesVersionThree() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drop-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("HackResults.store")
        let result = summary(hack: 1, state: .complete, closed: true)
        do {
            let schema = Schema(versionedSchema: HackResultSchemaV3.self)
            let old = try ModelContainer(for: schema, migrationPlan: nil,
                                         configurations: ModelConfiguration("HackResults", schema: schema, url: url,
                                                                            cloudKitDatabase: .none))
            let context = ModelContext(old)
            context.insert(HackResultSchemaV3.SavedHackResult(key: "v3", date: Date(), summaryVersion: 1,
                                                              summary: try JSONEncoder().encode(result)))
            context.insert(HackResultSchemaV3.SavedHackGear(key: "v3", date: Date(), gearVersion: 1,
                                                            gear: try JSONEncoder().encode(gear(hack: 1))))
            try context.save()
        }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: false, url: url))
        let records = try store.records()
        #expect(records.map(\.id) == ["v3"] && records.first?.summary == result && records.first?.gear == gear(hack: 1))
        #expect(try store.drops().isEmpty)
        try store.saveDrop(drop(group: 1), key: "drop", date: Date(), now: Date())
        #expect(try store.drops().map(\.id) == ["drop"])
    }

    @Test("Turning sync on reopens the store with the drops already in it")
    func dropsSyncReopen() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let synced = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        try synced.saveDrop(drop(group: 5, session: 7), key: "other/7/drop-5", date: Date(), now: Date())
        let results = HackResults(preferences: preferences,
                                  store: HackResultStore(container: try HackResultStore.makeContainer(inMemory: true)),
                                  reopen: { _ in (synced, nil) })
        results.syncsWithICloud = true
        #expect(results.drops.map(\.id) == ["other/7/drop-5"])
        results.receiveDrop(drop(group: 1))
        #expect(try synced.drops().count == 2)
    }

    // MARK: - Deleting chosen history

    @Test("Deleting removes only the chosen hacks, their gear and drops: every copy, in any format")
    func storeDeletesChosenKeys() throws {
        let container = try HackResultStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let result = try JSONEncoder().encode(summary(hack: 1, state: .complete, closed: true))
        let gearData = try JSONEncoder().encode(gear(hack: 1))
        let dropData = try JSONEncoder().encode(drop(group: 1))
        for _ in 0..<2 {
            context.insert(SavedHackResult(key: "a", date: Date(), summaryVersion: 1, summary: result))
            context.insert(SavedHackGear(key: "a", date: Date(), gearVersion: 1, gear: gearData))
            context.insert(SavedGearDrop(key: "d1", date: Date(), dropVersion: 1, drop: dropData))
        }
        context.insert(SavedHackResult(key: "b", date: Date(), summaryVersion: 1, summary: result))
        context.insert(SavedHackGear(key: "b", date: Date(), gearVersion: 1, gear: gearData))
        // Gear whose result hasn't synced yet isn't anyone's to delete.
        context.insert(SavedHackGear(key: "orphan", date: Date(), gearVersion: 1, gear: gearData))
        context.insert(SavedHackResult(key: "futureHack", date: Date(), summaryVersion: 99, summary: Data("{}".utf8)))
        context.insert(SavedGearDrop(key: "d2", date: Date(), dropVersion: 1, drop: dropData))
        context.insert(SavedGearDrop(key: "future", date: Date(), dropVersion: 99, drop: Data("{}".utf8)))
        try context.save()
        let store = HackResultStore(container: container)
        try store.delete(resultKeys: [], dropKeys: [])
        #expect(try context.fetchCount(FetchDescriptor<SavedHackResult>()) == 4)
        for _ in 0..<2 {
            // Repeating it, or naming keys that aren't there, changes nothing more.
            try store.delete(resultKeys: ["a", "futureHack", "absent"], dropKeys: ["d1", "future", "absent"])
            #expect(try context.fetch(FetchDescriptor<SavedHackResult>()).map(\.key) == ["b"])
            #expect(try context.fetch(FetchDescriptor<SavedHackGear>()).map(\.key).sorted() == ["b", "orphan"])
            #expect(try context.fetch(FetchDescriptor<SavedGearDrop>()).map(\.key) == ["d2"])
        }
    }

    @Test("Deleting chosen hacks and drops keeps a hack in progress, and late deliveries stay deleted")
    func deleteChosen() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let container = try HackResultStore.makeContainer(inMemory: true)
        let store = HackResultStore(container: container)
        let results = HackResults(preferences: preferences, store: store, now: { clock.now })
        for hack in 1...2 {
            results.receive(summary(hack: hack, state: .complete, closed: true))
            clock.now = clock.now.addingTimeInterval(10)
        }
        results.receiveGear(gear(hack: 2))
        results.receive(summary(hack: 3, state: .partial, closed: false))
        results.receiveDrop(drop(group: 1))
        results.receiveDrop(drop(group: 2))
        func id(_ hack: Int) throws -> String { try #require(results.records.first { $0.summary?.hackID == hack }?.id) }
        func dropID(_ group: Int) throws -> String { try #require(results.drops.first { $0.drop?.summary.groupID == group }?.id) }
        let (first, second, open) = (try id(1), try id(2), try id(3))
        #expect(results.records.first { $0.id == open }?.isDeletable == false)
        #expect(results.records.first { $0.id == first }?.isDeletable == true)
        try results.delete(hacks: [first, second, open], drops: [dropID(1)])
        #expect(results.records.map(\.summary?.hackID) == [3], "A hack still being read is never deleted")
        #expect(results.drops.map(\.drop?.summary.groupID) == [2])
        #expect(try store.records().isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<SavedHackGear>()) == 0)
        #expect(try store.drops().map(\.drop?.summary.groupID) == [2])
        // Delivered again, or read late: none of them come back.
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receiveGear(gear(hack: 1))
        results.receiveDrop(drop(group: 1))
        #expect(results.records.map(\.summary?.hackID) == [3])
        #expect(results.drops.map(\.drop?.summary.groupID) == [2])
        #expect(try store.records().isEmpty && store.drops().count == 1)
        // The hack in progress closes and is saved as usual.
        results.receive(summary(hack: 3, state: .complete, closed: true))
        #expect(try store.records().map(\.summary?.hackID) == [3])
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        #expect(relaunched.records.map(\.summary?.hackID) == [3])
        #expect(relaunched.drops.map(\.drop?.summary.groupID) == [2])
    }

    @Test("A hack and a drop never saved stay deleted when the page rebuilds")
    func deleteUnsaved() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.keepsHackResults = false
        let results = HackResults(preferences: preferences,
                                  store: HackResultStore(container: try HackResultStore.makeContainer(inMemory: true)))
        results.receive(summary(hack: 1, state: .complete, closed: true))
        results.receive(summary(hack: 2, state: .complete, closed: true))
        results.receiveDrop(drop(group: 1))
        let hack = try #require(results.records.first { $0.summary?.hackID == 1 }?.id)
        let group = try #require(results.drops.first?.id)
        try results.delete(hacks: [hack], drops: [group])
        // Anything new rebuilds the page from this run's log.
        results.receive(summary(hack: 3, state: .complete, closed: true))
        results.receiveDrop(drop(group: 2))
        results.receiveGear(gear(hack: 1))
        #expect(results.records.map(\.summary?.hackID).sorted { ($0 ?? 0) < ($1 ?? 0) } == [2, 3])
        #expect(results.drops.map(\.drop?.summary.groupID) == [2])
    }

    @Test("Records from another iPhone, or in an unknown format, are deleted by their own ids")
    func deleteForeignRecords() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try HackResultStore.makeContainer(inMemory: true)
        let store = HackResultStore(container: container)
        try store.save(summary(hack: 9, state: .complete, closed: true, session: 7), key: "other/7/9",
                       date: Date(), now: Date())
        try store.saveGear(gear(hack: 9, session: 7), key: "other/7/9", date: Date())
        try store.saveDrop(drop(group: 5, session: 7), key: "other/7/drop-5", date: Date(), now: Date())
        let context = ModelContext(container)
        context.insert(SavedHackResult(key: "future", date: Date(), summaryVersion: 99, summary: Data("{}".utf8)))
        try context.save()
        let results = HackResults(preferences: preferences, store: store)
        let unknown = try #require(results.records.first { $0.summary == nil })
        #expect(unknown.isDeletable)
        try results.delete(hacks: ["other/7/9", unknown.id], drops: ["other/7/drop-5"])
        #expect(results.records.isEmpty && results.drops.isEmpty)
        #expect(try store.records().isEmpty && store.drops().isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<SavedHackGear>()) == 0)
    }

    @Test("Without a store, saved records shown can't be deleted and stay; unsaved ones can")
    func deleteWithoutStore() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        try store.saveDrop(drop(group: 5), key: "saved-drop", date: Date(), now: Date())
        let results = HackResults(preferences: preferences, store: store,
                                  reopen: { _ in (nil, CocoaError(.fileReadNoPermission)) })
        results.syncsWithICloud = true
        results.receive(summary(hack: 1, state: .complete, closed: true))
        let hack = try #require(results.records.first?.id)
        #expect(throws: HackResults.DeletionError.self) {
            try results.delete(hacks: [hack], drops: ["saved-drop"])
        }
        #expect(results.records.count == 1 && results.drops.map(\.id) == ["saved-drop"],
                "A failed delete changes nothing")
        try results.delete(hacks: [hack], drops: [])
        #expect(results.records.isEmpty)
        #expect(try store.drops().map(\.id) == ["saved-drop"])
    }

    @Test("A record's capture origin survives saving, later updates, gear arriving and a relaunch")
    func originSaved() throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try HackResultStore.makeContainer(inMemory: true)
        let results = HackResults(preferences: preferences, store: HackResultStore(container: container))
        // The hack starts before a daylight-saving change and closes after
        // it, by when the game's language has been confirmed.
        let startOrigin = CaptureOrigin(appVersion: "0.1.0", appBuild: "73", captureMode: .glyphAssistance,
                                        gameLanguage: .english, gameLanguageSource: .assumed,
                                        utcOffsetMinutes: 60, playerFaction: .resistance)
        var endOrigin = startOrigin
        endOrigin.gameLanguage = .simplifiedChinese
        endOrigin.gameLanguageSource = .detected
        endOrigin.utcOffsetMinutes = 120
        var hackOrigin = endOrigin
        hackOrigin.utcOffsetMinutes = 60
        var gearOrigin = endOrigin
        gearOrigin.utcOffsetMinutes = 540
        gearOrigin.playerFaction = .enlightened
        var open = summary(hack: 1, state: .partial, closed: false)
        open.origin = startOrigin
        var closed = summary(hack: 1, state: .complete, closed: true)
        closed.origin = endOrigin
        results.receive(open)
        results.receive(closed)
        preferences.playerFaction = .enlightened
        // A changed setting and a duplicate late summary cannot rewrite
        // the player's faction on a hack that has already closed.
        var repeated = closed
        repeated.origin?.playerFaction = .enlightened
        results.receive(repeated)
        var attachment = gear(hack: 1)
        attachment.origin = gearOrigin
        results.receiveGear(attachment)
        var drop = drop(group: 1)
        drop.origin = CaptureOrigin(appVersion: "0.1.0", appBuild: "73", captureMode: .gearOnly,
                                    gameLanguage: .english, gameLanguageSource: .chosen, utcOffsetMinutes: -420)
        results.receiveDrop(drop)
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        let record = try #require(relaunched.records.first)
        #expect(record.summary?.origin == hackOrigin,
                "The offset stays the one its date was taken in; the language is the latest; gear never rewrites it")
        #expect(results.records.first?.summary?.origin == hackOrigin, "Before a relaunch too")
        #expect(record.gear?.origin == gearOrigin)
        #expect(relaunched.drops.first?.drop?.origin == drop.origin)
        // Gear saved before origins were kept still opens, with none.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
        object.removeValue(forKey: "origin")
        let older = try JSONDecoder().decode(HackGearAttachment.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.origin == nil && older.reading == attachment.reading)
    }

    @Test("An open hack takes the latest summary's faction, including clearing it; closure freezes it", arguments: [
        (nil as PortalFaction?, PortalFaction.resistance as PortalFaction?),
        (.resistance, .enlightened),
        (.enlightened, nil),
    ])
    func factionUpdatesUntilClosure(initial: PortalFaction?, latest: PortalFaction?) throws {
        let (preferences, defaults, suite) = try isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try HackResultStore.makeContainer(inMemory: true)
        let store = HackResultStore(container: container)
        let results = HackResults(preferences: preferences, store: store)
        let languages = GameLanguageMemory(language: .english, isAutomatic: false)
        let zone = try #require(TimeZone(secondsFromGMT: 60 * 60))
        func currentOrigin() -> CaptureOrigin {
            CaptureOrigin.current(mode: .glyphAssistance, languages: languages,
                                  playerFaction: preferences.playerFaction, timeZone: zone)
        }
        preferences.playerFaction = initial
        var open = summary(hack: 1, state: .awaiting, closed: false)
        open.origin = currentOrigin()
        results.receive(open)
        #expect(results.records.first?.summary?.origin?.playerFaction == initial)

        preferences.playerFaction = latest
        #expect(results.records.first?.summary?.origin?.playerFaction == initial,
                "Changing the preference alone does not rewrite the last delivered summary")
        open = summary(hack: 1, state: .partial, closed: false)
        open.origin = currentOrigin()
        results.receive(open)
        #expect(results.records.first?.summary?.origin?.playerFaction == latest)
        #expect(try store.records().isEmpty)

        var closed = summary(hack: 1, state: .complete, closed: true)
        closed.origin = currentOrigin()
        results.receive(closed)
        #expect(try store.records().first?.summary == closed)

        preferences.playerFaction = latest == .resistance ? .enlightened : .resistance
        var duplicate = closed
        duplicate.origin = currentOrigin()
        results.receive(duplicate)
        duplicate = summary(hack: 1, state: .partial, closed: false)
        duplicate.origin = currentOrigin()
        results.receive(duplicate)
        var attachment = gear(hack: 1)
        attachment.origin = currentOrigin()
        results.receiveGear(attachment)
        var repeatedGear = gear(hack: 1, quantity: 9)
        repeatedGear.origin = currentOrigin()
        results.receiveGear(repeatedGear)

        let saved = try #require(try store.records().first)
        #expect(saved.summary == closed, "Late summaries and gear cannot rewrite even a nil closed faction")
        #expect(saved.gear == attachment, "The first gear reading also stays frozen")
        #expect(results.records.first?.summary == closed)
        let relaunched = HackResults(preferences: preferences, store: HackResultStore(container: container))
        #expect(relaunched.records.first?.summary == closed)
        #expect(relaunched.records.first?.gear == attachment)
    }

    @Test("Old or malformed faction metadata keeps the rest of each saved container readable", arguments: [
        nil as String?, #""neutral""#, "null", "42", "true", "{}", "[]",
    ])
    func oldCaptureOrigin(playerFactionJSON: String?) throws {
        let suffix = playerFactionJSON.map { ",\"playerFaction\":\($0)" } ?? ""
        let data = Data("{\"appBuild\":\"73\",\"captureMode\":\"glyphAssistance\",\"gameLanguage\":\"en\",\"gameLanguageSource\":\"chosen\",\"utcOffsetMinutes\":60\(suffix)}".utf8)
        let oldOrigin = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = CaptureOrigin(appVersion: nil, appBuild: "73", captureMode: .glyphAssistance,
                                     gameLanguage: .english, gameLanguageSource: .chosen, utcOffsetMinutes: 60)
        func replacingOrigin<T: Codable>(_ value: T) throws -> T {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object["origin"] = oldOrigin
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
        }
        var expectedSummary = summary(hack: 1, state: .complete, closed: true)
        expectedSummary.origin = expected
        #expect(try replacingOrigin(expectedSummary) == expectedSummary)
        var expectedGear = gear(hack: 1)
        expectedGear.origin = expected
        #expect(try replacingOrigin(expectedGear) == expectedGear)
        var expectedDrop = drop(group: 1)
        expectedDrop.origin = expected
        #expect(try replacingOrigin(expectedDrop) == expectedDrop)
    }

    @Test("Gear saved in a format this build can't read is told apart from no gear")
    func unreadableGear() throws {
        let container = try HackResultStore.makeContainer(inMemory: true)
        let store = HackResultStore(container: container)
        for key in ["future", "broken", "none"] {
            try store.save(summary(hack: 1, state: .complete, closed: true), key: key, date: Date(), now: Date())
        }
        let context = ModelContext(container)
        context.insert(SavedHackGear(key: "future", date: Date(), gearVersion: 99, gear: Data("{}".utf8)))
        context.insert(SavedHackGear(key: "broken", date: Date(), gearVersion: 1, gear: Data("{}".utf8)))
        try context.save()
        let records = Dictionary(uniqueKeysWithValues: try store.records().map { ($0.id, $0) })
        #expect(records["future"]?.gearUnreadable == true && records["future"]?.gear == nil)
        #expect(records["broken"]?.gearUnreadable == true)
        #expect(records["none"]?.gearUnreadable == false)
    }
}
