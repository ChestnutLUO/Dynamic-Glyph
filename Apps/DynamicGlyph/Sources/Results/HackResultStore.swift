import Foundation
import SwiftData
import GlyphRecognition

enum HackResultSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [HackResultSchemaV1.SavedHackResult.self] }

    /// One hack's conclusion. The summary is kept encoded with its format
    /// version, so a record this build cannot read is left alone rather than
    /// reinterpreted or overwritten.
    @Model
    final class SavedHackResult {
        @Attribute(.unique) var key: String
        var date: Date
        var summaryVersion: Int
        var summary: Data

        init(key: String, date: Date, summaryVersion: Int, summary: Data) {
            self.key = key
            self.date = date
            self.summaryVersion = summaryVersion
            self.summary = summary
        }
    }
}

/// Adds the gear read after a hack as its own record, keyed like the hack's
/// result. A saved result is never rewritten to add it.
enum HackResultSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    // Named in full: a bare `SavedHackResult` is the current version's class,
    // which would change this released version and strand every store
    // written with it.
    static var models: [any PersistentModel.Type] {
        [HackResultSchemaV1.SavedHackResult.self, HackResultSchemaV2.SavedHackGear.self]
    }

    @Model
    final class SavedHackGear {
        @Attribute(.unique) var key: String
        var date: Date
        var gearVersion: Int
        var gear: Data

        init(key: String, date: Date, gearVersion: Int, gear: Data) {
            self.key = key
            self.date = date
            self.gearVersion = gearVersion
            self.gear = gear
        }
    }
}

/// The same records in a form iCloud can mirror: CloudKit allows no unique
/// attributes and needs a default for every attribute. The store keeps keys
/// unique itself, and reads past any duplicate a sync could leave.
enum HackResultSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [HackResultSchemaV3.SavedHackResult.self, HackResultSchemaV3.SavedHackGear.self]
    }

    @Model
    final class SavedHackResult {
        var key: String = ""
        var date: Date = Date.distantPast
        var summaryVersion: Int = 0
        var summary: Data = Data()

        init(key: String, date: Date, summaryVersion: Int, summary: Data) {
            self.key = key
            self.date = date
            self.summaryVersion = summaryVersion
            self.summary = summary
        }
    }

    @Model
    final class SavedHackGear {
        var key: String = ""
        var date: Date = Date.distantPast
        var gearVersion: Int = 0
        var gear: Data = Data()

        init(key: String, date: Date, gearVersion: Int, gear: Data) {
            self.key = key
            self.date = date
            self.gearVersion = gearVersion
            self.gear = gear
        }
    }
}

/// Adds drop groups no Glyph hack claimed, each its own record. A new
/// entity, so builds that don't know it neither read nor prune it.
enum HackResultSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [HackResultSchemaV3.SavedHackResult.self, HackResultSchemaV3.SavedHackGear.self,
         HackResultSchemaV4.SavedGearDrop.self]
    }

    @Model
    final class SavedGearDrop {
        var key: String = ""
        var date: Date = Date.distantPast
        var dropVersion: Int = 0
        var drop: Data = Data()

        init(key: String, date: Date, dropVersion: Int, drop: Data) {
            self.key = key
            self.date = date
            self.dropVersion = dropVersion
            self.drop = drop
        }
    }
}

/// Later schema versions add a stage here instead of replacing earlier ones.
enum HackResultMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [HackResultSchemaV1.self, HackResultSchemaV2.self, HackResultSchemaV3.self, HackResultSchemaV4.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: HackResultSchemaV1.self, toVersion: HackResultSchemaV2.self),
         .lightweight(fromVersion: HackResultSchemaV2.self, toVersion: HackResultSchemaV3.self),
         .lightweight(fromVersion: HackResultSchemaV3.self, toVersion: HackResultSchemaV4.self)]
    }
}

typealias SavedHackResult = HackResultSchemaV3.SavedHackResult
typealias SavedHackGear = HackResultSchemaV3.SavedHackGear
typealias SavedGearDrop = HackResultSchemaV4.SavedGearDrop

/// A drop group no Glyph hack claimed: an ordinary hack's, one whose hack
/// couldn't be told, or any group read with Glyph assistance off. A group is
/// what the game showed between two departures of its panels, not a
/// confirmed hack: queued hacks, missed panels or a capture started midway
/// can leave its owner unknown. Its association says why none claimed it.
struct GearDrop: Codable, Equatable, Sendable {
    let captureSessionID: UInt64
    let summary: GearDropSummary
    /// Pictures of its panels, oldest first; empty when saving them was off.
    var pictures: [HackGearPicture] = []
    /// The session's log folder in Documents, for a report; nil while logs
    /// were off, and in drops saved before reports.
    var sessionFolder: String? = nil
    /// How it was captured; nil in drops saved before this was kept.
    var origin: CaptureOrigin? = nil
    var runKey: String { "\(captureSessionID)/drop-\(summary.groupID)" }

    var panelPictures: [HackGearPicture] { HackGearPicture.onePerPanel(pictures) }
}

/// One saved or in-memory drop group.
struct GearDropRecord: Identifiable, Equatable {
    let id: String
    let date: Date
    /// Nil for a saved drop in a format this build does not know.
    let drop: GearDrop?
}

/// The gear read after one hack, or why none was.
struct HackGearAttachment: Codable, Equatable, Sendable {
    enum Reading: Codable, Equatable, Sendable {
        case read(GearDropSummary)
        /// The hack stopped waiting without a drop group: timed out, capture
        /// stopped, or a gap in the frames.
        case notRead(reason: String)
    }
    let captureSessionID: UInt64
    let hackID: Int
    let reading: Reading
    /// Pictures of this hack's item panels, oldest first. Empty when saving
    /// them was off; absent in gear saved before pictures existed.
    var pictures: [HackGearPicture]? = nil
    /// The hacked portal's level and how sure it is; absent in gear saved
    /// before portal levels were read.
    var portalLevel: PortalLevelEstimate? = nil
    /// The session's log folder in Documents, for a report; nil while logs
    /// were off, and in gear saved before reports.
    var sessionFolder: String? = nil
    /// How it was captured; nil in gear saved before this was kept.
    var origin: CaptureOrigin? = nil
    /// Matches `HackResultSummary.runKey`.
    var runKey: String { "\(captureSessionID)/\(hackID)" }
}

extension HackGearAttachment {
    var panelPictures: [HackGearPicture] { HackGearPicture.onePerPanel(pictures ?? []) }
}

/// A panel picture in a session's log folder. Deleting that session's logs
/// deletes the picture; the reading stays.
struct HackGearPicture: Codable, Equatable, Sendable {
    /// `<session folder>/<file>`, relative to the app's Documents folder.
    let path: String
    let stage: GearDropStage

    /// One picture per panel for checking a reading. The session keeps up to
    /// four of each panel for reports; they look nearly alike, so the sheet
    /// shows the middle one: the first can catch the panel sliding in.
    /// The unmasked frame saved beside a crop: `gear-full-<time>.jpg`.
    static func fullFrameName(_ cropName: String) -> String {
        cropName.hasPrefix("gear-") ? "gear-full-" + cropName.dropFirst("gear-".count) : cropName
    }

    /// The whole frame this crop came from, if it was saved: sessions before
    /// full frames have only the crop.
    func fullFrameURL(in root: URL) -> URL? {
        url(in: root).map { $0.deletingLastPathComponent().appendingPathComponent(Self.fullFrameName($0.lastPathComponent)) }
    }

    static func onePerPanel(_ pictures: [HackGearPicture]) -> [HackGearPicture] {
        [GearDropStage.portal, .bonus].compactMap { stage in
            let panel = pictures.filter { $0.stage == stage }
            return panel.isEmpty ? nil : panel[panel.count / 2]
        }
    }

    /// Nil unless the path is exactly one folder and one file inside `root`,
    /// so a stored record can never point elsewhere.
    func url(in root: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parts[0].hasPrefix("spikeB-"), parts[1].hasPrefix("gear-"), parts[1].hasSuffix(".jpg") else { return nil }
        return root.appendingPathComponent(String(parts[0]), isDirectory: true).appendingPathComponent(String(parts[1]))
    }
}

/// One row of the results page, saved or only in memory.
struct HackResultRecord: Identifiable, Equatable {
    let id: String
    let date: Date
    /// Nil for a saved record in a format this build does not know.
    let summary: HackResultSummary?
    /// Nil when gear was not read for this hack, or is in an unknown format.
    var gear: HackGearAttachment? = nil
    /// Gear was saved for this hack in a format this build can't read.
    var gearUnreadable = false

    /// A hack still being read can't be deleted. A saved record is closed,
    /// even one in a format this build can't read.
    var isDeletable: Bool { summary?.isClosed ?? true }
}

/// The saved results. Every call reports failure rather than hiding it; the
/// caller decides what the player is told.
@MainActor
final class HackResultStore {
    struct Retention {
        var maximumCount = 1_000
        var maximumAge: TimeInterval = 90 * 24 * 60 * 60
    }

    static let summaryVersion = 1
    static let gearVersion = 1
    static let dropVersion = 1
    /// The player's private database in this container. It must match the
    /// app's iCloud entitlement.
    static let cloudContainer = "iCloud.org.szres.DynamicGlyph"

    let retention: Retention
    private let context: ModelContext

    init(container: ModelContainer, retention: Retention = Retention()) {
        self.retention = retention
        context = ModelContext(container)
    }

    /// The on-disk store, or nil with the reason it could not be opened.
    /// `syncing` mirrors it to the player's iCloud.
    static func openPersistent(syncing: Bool) -> (store: HackResultStore?, error: Error?) {
        do {
            return (HackResultStore(container: try makeContainer(inMemory: false, syncing: syncing)), nil)
        } catch {
            return (nil, error)
        }
    }

    /// `url` places the store elsewhere; tests use it to migrate an old file.
    static func makeContainer(inMemory: Bool, url: URL? = nil, syncing: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HackResultSchemaV4.self)
        // Never `.automatic`: that syncs whenever the app has the entitlement,
        // whatever the player chose.
        let database: ModelConfiguration.CloudKitDatabase = syncing ? .private(cloudContainer) : .none
        let configuration = url.map { ModelConfiguration("HackResults", schema: schema, url: $0, cloudKitDatabase: database) }
            ?? ModelConfiguration("HackResults", schema: schema, isStoredInMemoryOnly: inMemory,
                                  cloudKitDatabase: database)
        return try ModelContainer(for: schema, migrationPlan: HackResultMigrationPlan.self,
                                  configurations: configuration)
    }

    /// Inserts the hack, or replaces its earlier copy, then applies retention.
    func save(_ summary: HackResultSummary, key: String, date: Date, now: Date) throws {
        let data = try JSONEncoder().encode(summary)
        let copies = try context.fetch(FetchDescriptor<SavedHackResult>(predicate: #Predicate { $0.key == key }))
        if let existing = copies.first {
            existing.summary = data
            existing.summaryVersion = Self.summaryVersion
            for copy in copies.dropFirst() { context.delete(copy) }
        } else {
            context.insert(SavedHackResult(key: key, date: date, summaryVersion: Self.summaryVersion, summary: data))
        }
        try prune(now: now)
    }

    /// Saves gear for a hack whose result is saved. Gear for a hack that has
    /// no saved result is not kept: it would outlive its row.
    func saveGear(_ gear: HackGearAttachment, key: String, date: Date) throws {
        var result = FetchDescriptor<SavedHackResult>(predicate: #Predicate { $0.key == key })
        result.fetchLimit = 1
        guard try context.fetchCount(result) > 0 else { return }
        let data = try JSONEncoder().encode(gear)
        let copies = try context.fetch(FetchDescriptor<SavedHackGear>(predicate: #Predicate { $0.key == key }))
        if let existing = copies.first {
            existing.gear = data
            existing.gearVersion = Self.gearVersion
            for copy in copies.dropFirst() { context.delete(copy) }
        } else {
            context.insert(SavedHackGear(key: key, date: date, gearVersion: Self.gearVersion, gear: data))
        }
        try context.save()
    }

    /// Inserts the drop, or replaces its earlier copy, then applies retention.
    func saveDrop(_ drop: GearDrop, key: String, date: Date, now: Date) throws {
        let data = try JSONEncoder().encode(drop)
        let copies = try context.fetch(FetchDescriptor<SavedGearDrop>(predicate: #Predicate { $0.key == key }))
        if let existing = copies.first {
            existing.drop = data
            existing.dropVersion = Self.dropVersion
            for copy in copies.dropFirst() { context.delete(copy) }
        } else {
            context.insert(SavedGearDrop(key: key, date: date, dropVersion: Self.dropVersion, drop: data))
        }
        try prune(now: now)
    }

    /// Removes what is older than the age limit, then the oldest beyond the
    /// count limit, whichever removes an entry first, and any second copy of
    /// a hack. Drops have their own count, so a day of ordinary hacks can't
    /// push Glyph hacks out. Rows are deleted one by one, never in a batch,
    /// so that iCloud sync deletes them on the player's other iPhones too.
    func prune(now: Date) throws {
        let cutoff = now.addingTimeInterval(-retention.maximumAge)
        var kept: Set<String> = [], removed: Set<String> = []
        let newestFirst = FetchDescriptor<SavedHackResult>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        for record in try context.fetch(newestFirst) {
            if record.date < cutoff || kept.contains(record.key) || kept.count >= retention.maximumCount {
                context.delete(record)
                removed.insert(record.key)
            } else {
                kept.insert(record.key)
            }
        }
        // Gear goes with its hack's result. Gear whose result isn't here is
        // kept: a sync can bring the gear first, and deleting it would delete
        // it on every iPhone.
        var keptGear: Set<String> = []
        for gear in try context.fetch(FetchDescriptor<SavedHackGear>())
        where gear.date < cutoff || (removed.contains(gear.key) && !kept.contains(gear.key))
            || !keptGear.insert(gear.key).inserted {
            context.delete(gear)
        }
        var keptDrops: Set<String> = []
        let dropsNewestFirst = FetchDescriptor<SavedGearDrop>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        for drop in try context.fetch(dropsNewestFirst) {
            if drop.date < cutoff || keptDrops.contains(drop.key) || keptDrops.count >= retention.maximumCount {
                context.delete(drop)
            } else {
                keptDrops.insert(drop.key)
            }
        }
        try context.save()
    }

    /// Newest first; until the next prune, a copy synced from elsewhere is read once.
    func drops() throws -> [GearDropRecord] {
        var seen: Set<String> = []
        let descriptor = FetchDescriptor<SavedGearDrop>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        return try context.fetch(descriptor).filter { seen.insert($0.key).inserted }.map { saved in
            let drop = saved.dropVersion == Self.dropVersion
                ? try? JSONDecoder().decode(GearDrop.self, from: saved.drop) : nil
            return GearDropRecord(id: saved.key, date: saved.date, drop: drop)
        }
    }

    func records() throws -> [HackResultRecord] {
        var gear: [String: HackGearAttachment] = [:]
        var unreadable: Set<String> = []
        for saved in try context.fetch(FetchDescriptor<SavedHackGear>()) where gear[saved.key] == nil {
            if saved.gearVersion == Self.gearVersion,
               let attachment = try? JSONDecoder().decode(HackGearAttachment.self, from: saved.gear) {
                gear[saved.key] = attachment
            } else {
                unreadable.insert(saved.key)
            }
        }
        // Until the next prune, a copy synced from elsewhere is read once.
        var seen: Set<String> = []
        let descriptor = FetchDescriptor<SavedHackResult>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        return try context.fetch(descriptor).filter { seen.insert($0.key).inserted }.map { saved in
            let summary = saved.summaryVersion == Self.summaryVersion
                ? try? JSONDecoder().decode(HackResultSummary.self, from: saved.summary) : nil
            return HackResultRecord(id: saved.key, date: saved.date, summary: summary, gear: gear[saved.key],
                                    gearUnreadable: gear[saved.key] == nil && unreadable.contains(saved.key))
        }
    }

    /// Deletes these hacks with their gear, and these drops: every copy a
    /// sync left, in any format. Rows go one by one, like `prune`, so iCloud
    /// deletes them on the other iPhones too, and are saved once: if the save
    /// fails, nothing is deleted. Gear whose key wasn't asked for stays, even
    /// without a result, since a sync can bring gear before its result.
    func delete(resultKeys: Set<String>, dropKeys: Set<String>) throws {
        guard !resultKeys.isEmpty || !dropKeys.isEmpty else { return }
        let results = Array(resultKeys), drops = Array(dropKeys)
        do {
            let savedResults = try context.fetch(FetchDescriptor<SavedHackResult>(
                predicate: #Predicate { results.contains($0.key) }))
            let savedGear = try context.fetch(FetchDescriptor<SavedHackGear>(
                predicate: #Predicate { results.contains($0.key) }))
            let savedDrops = try context.fetch(FetchDescriptor<SavedGearDrop>(
                predicate: #Predicate { drops.contains($0.key) }))
            for record in savedResults { context.delete(record) }
            for gear in savedGear { context.delete(gear) }
            for drop in savedDrops { context.delete(drop) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// One by one, like `prune`, so iCloud clears the other iPhones too.
    func clear() throws {
        for record in try context.fetch(FetchDescriptor<SavedHackResult>()) { context.delete(record) }
        for gear in try context.fetch(FetchDescriptor<SavedHackGear>()) { context.delete(gear) }
        for drop in try context.fetch(FetchDescriptor<SavedGearDrop>()) { context.delete(drop) }
        try context.save()
    }
}
