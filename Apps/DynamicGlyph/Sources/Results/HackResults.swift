import Foundation
import Combine
import CoreData
import GlyphRecognition
import UIKit

/// Hack results for the app's pages: this run's, in memory, merged with the
/// saved ones. A hack is saved once it closes, and only while keeping is on;
/// one still in progress is shown but not saved.
@MainActor
final class HackResults: ObservableObject {
    /// Newest first. Includes saved results even while reading is off.
    @Published private(set) var records: [HackResultRecord] = []
    /// Drop groups no Glyph hack claimed, newest first, saved like results.
    @Published private(set) var drops: [GearDropRecord] = []
    /// Already localized; nil while saving works.
    @Published private(set) var problem: String?
    /// What iCloud last reported; nil while sync is off.
    @Published private(set) var syncState: ICloudSyncState?

    /// Read at each Start: a running session keeps the choice it began with.
    @Published var readsResults: Bool {
        didSet { preferences.readsHackResults = readsResults }
    }
    @Published var keepsResults: Bool {
        didSet { preferences.keepsHackResults = keepsResults }
    }
    /// The tester switch. Capture also needs session logs and result reading.
    @Published var readsGear: Bool {
        didSet { preferences.readsGearDrops = readsGear }
    }
    @Published var savesGearPictures: Bool {
        didSet { preferences.savesGearPictures = savesGearPictures }
    }
    /// Applies at once: the store reopens with or without iCloud.
    @Published var syncsWithICloud: Bool {
        didSet {
            guard syncsWithICloud != oldValue else { return }
            preferences.syncsHackResults = syncsWithICloud
            reopenStore()
        }
    }

    /// New results will leave this iPhone: read, saved, and synced to the
    /// player's iCloud. What the Start page tells the player. Without Glyph
    /// assistance the item panels are read whatever the result switch says.
    func uploadsResults(assistsGlyphs: Bool) -> Bool {
        (readsResults || !assistsGlyphs) && keepsResults && syncsWithICloud
    }

    /// Changes whenever `records` or `drops` are set again: a save, delete,
    /// clear, new gear, a sync from another iPhone or a reopened store. Pages
    /// that derive from both redo their work only when it moves.
    private(set) var revision = 0

    var latest: HackResultRecord? { records.first }
    var retention: HackResultStore.Retention { store?.retention ?? HackResultStore.Retention() }

    private let preferences: AppPreferences
    private var store: HackResultStore?
    /// Opens the store again, syncing or not; nil where it can't be reopened.
    private let reopen: (@MainActor (Bool) -> (store: HackResultStore?, error: Error?))?
    private var remoteChanges: AnyCancellable?
    private var timeChanges: AnyCancellable?
    private var syncEvents: AnyCancellable?
    private var syncMonitor = ICloudSyncMonitor()
    private let now: () -> Date
    /// Capture session numbers restart at launch; this keeps saved keys unique.
    private let launchID = UUID()
    private var log = HackResultLog()
    private var dates: [String: Date] = [:]
    /// The UTC offset when each hack was first seen, which goes with its
    /// date: a later summary can come from after a time change.
    private var offsets: [String: Int] = [:]
    private var saved: [HackResultRecord] = [] {
        didSet { savedRevision += 1 }
    }
    /// Counts changes to what the store holds, which is all the widget shows.
    private var savedRevision = 0
    private var publishedRevision: Int?
    private var publishedDay: Date?
    /// Nil where nothing feeds a widget, as in tests.
    private let widget: SummaryWidgetPublisher?
    /// A closed hack is immutable. Keep its identity beyond Clear and the
    /// bounded memory log so retirement or late callbacks cannot restore it
    /// or apply a later persistence choice to it.
    private var closedKeys: Set<String> = []
    /// This run's hacks that reached the store. Once saved, the store decides
    /// whether one is shown: pruned, or deleted on another iPhone, it is gone.
    private var persistedKeys: Set<String> = []
    /// This run's gear, by result key. Kept apart from the result: a closed
    /// result is immutable, and gear arrives seconds to minutes after it.
    private var gear: [String: HackGearAttachment] = [:]
    /// Gear for these hacks is ignored: it arrived once already, or its
    /// result was cleared. Late OCR cannot bring either back.
    private var closedGearKeys: Set<String> = []
    private var savedDrops: [GearDropRecord] = [] {
        didSet { savedRevision += 1 }
    }
    /// This run's drops that weren't saved, newest first, bounded like the log.
    private var unsavedDrops: [GearDropRecord] = []
    /// A drop arrives once; one cleared or already received is ignored.
    private var closedDropKeys: Set<String> = []

    /// `store` is nil when saving is impossible; `storageError` says why.
    init(preferences: AppPreferences = AppPreferences(), store: HackResultStore?, storageError: Error? = nil,
         reopen: (@MainActor (Bool) -> (store: HackResultStore?, error: Error?))? = nil,
         widget: SummaryWidgetPublisher? = nil, now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.store = store
        self.widget = widget
        self.reopen = reopen
        self.now = now
        readsResults = preferences.readsHackResults
        keepsResults = preferences.keepsHackResults
        readsGear = preferences.readsGearDrops
        savesGearPictures = preferences.savesGearPictures
        syncsWithICloud = preferences.syncsHackResults
        if let storageError { problem = Self.unavailable(storageError) }
        do {
            try store?.prune(now: now())
            saved = try store?.records() ?? []
            savedDrops = try store?.drops() ?? []
        } catch {
            report(error)
        }
        rebuild()
        // Results synced from the player's other iPhones arrive here.
        remoteChanges = NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        // A new time zone, or the clock set, moves every day's midnight: the
        // widget's days are cut again and every Summary widget reloaded.
        timeChanges = NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.timeChanged() } }
        if syncsWithICloud { syncState = syncMonitor.state }
        // This app has one iCloud store, so every event is this store's.
        syncEvents = NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .compactMap { $0.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.receiveSyncEvent(id: event.identifier, type: event.type, endDate: event.endDate,
                                           succeeded: event.succeeded, error: event.error)
                }
            }
    }

    /// One store sync event starting or ending. Events from a store closed by
    /// turning sync off are ignored, and so is how a closed store's steps end.
    func receiveSyncEvent(id: UUID, type: NSPersistentCloudKitContainer.EventType, endDate: Date?,
                          succeeded: Bool, error: Error?) {
        guard syncsWithICloud else { return }
        syncMonitor.receive(id: id, type: type, endDate: endDate, succeeded: succeeded, error: error)
        syncState = syncMonitor.state
    }

    /// Pull to refresh: rereads the saved results once any running sync step
    /// ends, or `timeout` passes. CloudKit has no call that asks for a sync,
    /// and the store stays open: closing it cancels the steps in flight and
    /// sets its mirroring up again. The store imports by itself when it opens
    /// and when iCloud pushes another iPhone's changes.
    func refresh(timeout: Duration = .seconds(20)) async {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
        while syncsWithICloud, syncMonitor.isSyncing, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        reload()
    }

    func receive(_ summary: HackResultSummary) {
        let key = storageKey(summary)
        guard !closedKeys.contains(key) else { return }
        if summary.isClosed { closedKeys.insert(key) }
        var summary = summary
        if dates[key] == nil { offsets[key] = summary.origin?.utcOffsetMinutes }
        // Language and build come from the latest summary, which may have
        // seen the game's language confirmed.
        summary.origin?.utcOffsetMinutes = offsets[key]
        let date = dates[key] ?? now()
        dates[key] = date
        log.record(summary)
        if summary.isClosed, keepsResults, let store {
            do {
                try store.save(summary, key: key, date: date, now: now())
                persistedKeys.insert(key)
                // Gear that arrived first is saved with the result that owns it.
                if let attachment = gear[key] { try store.saveGear(attachment, key: key, date: date) }
                try readSaved(from: store)
            } catch {
                report(error)
            }
        }
        rebuild()
    }

    /// Gear for one hack. It follows the choice its result made: saved when
    /// the result was saved, kept until the app closes otherwise.
    func receiveGear(_ attachment: HackGearAttachment) {
        let key = "\(launchID.uuidString)/\(attachment.runKey)"
        guard closedGearKeys.insert(key).inserted else { return }
        gear[key] = attachment
        if let store, saved.contains(where: { $0.id == key }) {
            do {
                try store.saveGear(attachment, key: key, date: dates[key] ?? now())
                saved = try store.records()
            } catch {
                report(error)
            }
        }
        rebuild()
    }

    /// A drop group no Glyph hack claimed. Saved at once while keeping is on:
    /// a group is closed when it arrives.
    func receiveDrop(_ drop: GearDrop) {
        let key = "\(launchID.uuidString)/\(drop.runKey)"
        guard closedDropKeys.insert(key).inserted else { return }
        let record = GearDropRecord(id: key, date: now(), drop: drop)
        if keepsResults, let store {
            do {
                try store.saveDrop(drop, key: key, date: record.date, now: now())
                try readSaved(from: store)
                rebuild()
                return
            } catch {
                report(error)
            }
        }
        unsavedDrops.insert(record, at: 0)
        if unsavedDrops.count > HackResultLog().limit { unsavedDrops.removeLast(unsavedDrops.count - HackResultLog().limit) }
        rebuild()
    }

    /// Removes saved results and drops and this run's finished ones. A hack
    /// still in progress stays, so it can still be completed.
    func clear() {
        do {
            try store?.clear()
            saved = []
            savedDrops = []
        } catch {
            report(error)
        }
        unsavedDrops = []
        let open = log.entries.filter { !$0.isClosed }
        log = HackResultLog()
        for summary in open.reversed() { log.record(summary) }
        // Gear for a cleared hack must not reappear when its reading arrives.
        let openKeys = Set(open.map(storageKey))
        closedGearKeys.formUnion(closedKeys)
        gear = gear.filter { openKeys.contains($0.key) }
        rebuild()
    }

    /// Deletes the chosen hacks, with their gear, and drops, by record id. A
    /// hack still in progress is kept whatever is asked, as Clear keeps it.
    /// The page changes only once the store has deleted every saved one; on
    /// failure nothing changes and the error says why. A deleted hack or
    /// drop delivered again, or gear read late for it, stays deleted.
    func delete(hacks: Set<String>, drops: Set<String>) throws {
        let open = Set(log.entries.filter { !$0.isClosed }.map(storageKey))
        let hackKeys = hacks.subtracting(open)
        guard !hackKeys.isEmpty || !drops.isEmpty else { return }
        if let store {
            try store.delete(resultKeys: hackKeys, dropKeys: drops)
        } else if saved.contains(where: { hackKeys.contains($0.id) })
                    || savedDrops.contains(where: { drops.contains($0.id) }) {
            // Shown from a store that has since failed to reopen.
            throw DeletionError.storeUnavailable
        }
        saved.removeAll { hackKeys.contains($0.id) }
        savedDrops.removeAll { drops.contains($0.id) }
        unsavedDrops.removeAll { drops.contains($0.id) }
        closedKeys.formUnion(hackKeys)
        closedGearKeys.formUnion(hackKeys)
        closedDropKeys.formUnion(drops)
        gear = gear.filter { !hackKeys.contains($0.key) }
        // rebuild() shows this run's unsaved hacks from the log.
        let kept = log.entries.filter { !hackKeys.contains(storageKey($0)) }
        log = HackResultLog()
        for summary in kept.reversed() { log.record(summary) }
        rebuild()
    }

    enum DeletionError: LocalizedError {
        case storeUnavailable
        var errorDescription: String? {
            String(localized: "Saved results can't be reached on this iPhone right now.",
                   comment: "Statistics page: deleting selected history failed because the results store couldn't be opened.")
        }
    }

    /// Only the saved records change: this run's results, and every choice
    /// made about them, stay as they are.
    private func reopenStore() {
        syncMonitor.storeClosed()
        syncState = syncsWithICloud ? syncMonitor.state : nil
        guard let reopen else { return }
        // Release the old container before opening the same file again.
        store = nil
        let opened = reopen(syncsWithICloud)
        store = opened.store
        problem = opened.error.map(Self.unavailable)
        reload()
    }

    /// Both collections: saving either prunes both, by age and by count.
    private func readSaved(from store: HackResultStore) throws {
        saved = try store.records()
        savedDrops = try store.drops()
    }

    private func reload() {
        guard let store else { return }
        do {
            try readSaved(from: store)
        } catch {
            report(error)
        }
        rebuild()
    }

    private static func unavailable(_ error: Error) -> String {
        String(localized: "Results can't be saved on this iPhone right now (\(error.localizedDescription)). They're kept until the app closes.",
               comment: "Hack results page. The placeholder is the system's error message.")
    }

    private func storageKey(_ summary: HackResultSummary) -> String {
        "\(launchID.uuidString)/\(summary.runKey)"
    }

    private func report(_ error: Error) {
        problem = String(localized: "Saving results failed: \(error.localizedDescription)",
                         comment: "Hack results page. The placeholder is the system's error message.")
    }

    private func rebuild() {
        let savedKeys = Set(saved.map(\.id))
        let unsaved = log.entries.compactMap { summary -> HackResultRecord? in
            let key = storageKey(summary)
            guard !savedKeys.contains(key), !persistedKeys.contains(key) else { return nil }
            return HackResultRecord(id: key, date: dates[key] ?? now(), summary: summary, gear: gear[key])
        }
        let stored = saved.map { record -> HackResultRecord in
            var record = record
            record.gear = record.gear ?? gear[record.id]
            return record
        }
        records = (unsaved + stored).sorted { $0.date > $1.date }
        let savedDropKeys = Set(savedDrops.map(\.id))
        drops = (unsavedDrops.filter { !savedDropKeys.contains($0.id) } + savedDrops).sorted { $0.date > $1.date }
        revision += 1
        publishWidget()
    }

    /// The time zone or clock changed: the summary is written and the
    /// widgets reloaded again even if its bytes are the same.
    func timeChanged() {
        NSTimeZone.resetSystemTimeZone()
        publishedDay = nil
        publishedRevision = nil
        publishWidget(force: true)
    }

    /// Hands the widget what the store now holds: after a save, delete,
    /// clear or prune, a sync from another iPhone, a reopened store, and at
    /// launch. This run's unsaved hacks stay out, since the widget outlives
    /// the run. With no store nothing is written: nothing saved can have
    /// changed, and the last summary is still what was saved.
    private func publishWidget(force: Bool = false) {
        guard let widget, store != nil else { return }
        let now = now(), day = Calendar.current.startOfDay(for: now)
        guard savedRevision != publishedRevision || day != publishedDay else { return }
        publishedRevision = savedRevision
        publishedDay = day
        widget.publish(StatisticsWidgetSummary(records: saved, drops: savedDrops, now: now), force: force)
    }
}
