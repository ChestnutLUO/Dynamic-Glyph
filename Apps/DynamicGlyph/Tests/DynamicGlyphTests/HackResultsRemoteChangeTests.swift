import Combine
import CoreData
import Foundation
import Testing
import GlyphRecognition

/// `HackResults` reloads on `NSPersistentStoreRemoteChange`, which every
/// Core Data store in the app posts, TipKit's datastore too. Only its own
/// store's changes (an iCloud import, say) are new results; TipKit's saves
/// must not be taken for them.
@MainActor
@Suite("Hack list: remote changes of its own store only", .serialized)
struct HackResultsRemoteChangeTests {
    final class Counter {
        var value = 0
    }

    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HackResultsRemoteChangeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func isolatedPreferences() throws -> (AppPreferences, String) {
        let suite = "dynamicglyph-remote-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppPreferences(defaults: defaults), suite)
    }

    private func storeFile(_ name: String) -> URL {
        folder.appendingPathComponent("\(name).store")
    }

    private func openStore(_ name: String) throws -> HackResultStore {
        HackResultStore(container: try HackResultStore.makeContainer(inMemory: false, url: storeFile(name)))
    }

    /// Reloads of the list: each one publishes `records` again.
    private func countReloads(_ results: HackResults) -> (Counter, AnyCancellable) {
        let reloads = Counter()
        let sink = results.$records.dropFirst().sink { _ in reloads.value += 1 }
        return (reloads, sink)
    }

    /// Posted as Core Data posts it: off the main thread, with the store's
    /// file and the posting coordinator.
    private func postRemoteChange(_ url: URL?) async throws {
        let userInfo: [AnyHashable: Any]? = url.map { [NSPersistentStoreURLKey: $0] }
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil, userInfo: userInfo)
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    /// A Core Data store of another framework, set up as TipKit's is: history
    /// tracking and remote-change notifications on.
    private func foreignContainer() throws -> NSPersistentContainer {
        let entity = NSEntityDescription()
        entity.name = "Thing"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let attribute = NSAttributeDescription()
        attribute.name = "value"
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = true
        entity.properties = [attribute]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let description = NSPersistentStoreDescription(url: storeFile("Foreign"))
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        let container = NSPersistentContainer(name: "Foreign", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container
    }

    @Test("Another Core Data store's save, like TipKit's, does not reload the list")
    func foreignStoreSave() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = try openStore("Own")
        try store.save(RatingFixtures.summary(1), key: "remote/1/1", date: Date(), now: Date())
        let results = HackResults(preferences: preferences, store: store)
        let foreign = try foreignContainer()
        try await Task.sleep(for: .milliseconds(300))
        let (reloads, sink) = countReloads(results)
        defer { sink.cancel() }
        let posted = Counter()
        let observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
                                                              object: nil, queue: nil) { _ in
            DispatchQueue.main.async { posted.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for value in 0..<5 {
            let context = foreign.newBackgroundContext()
            try context.performAndWait {
                let thing = NSManagedObject(entity: foreign.managedObjectModel.entitiesByName["Thing"]!,
                                            insertInto: context)
                thing.setValue(value, forKey: "value")
                try context.save()
            }
        }
        for _ in 0..<30 where posted.value < 5 { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(posted.value >= 5, "The foreign saves posted remote changes")
        #expect(reloads.value == 0)

        // Nor does one with no store named.
        try await postRemoteChange(nil)
        #expect(reloads.value == 0)
    }

    @Test("Its own store's remote change, as an iCloud import posts it, reloads the list")
    func ownStoreChange() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = try openStore("Own")
        let results = HackResults(preferences: preferences, store: store)
        #expect(results.savedRecords.isEmpty)
        try await Task.sleep(for: .milliseconds(300))

        // Another process (iCloud's mirroring, say) adds a hack to the file.
        let importer = try openStore("Own")
        try importer.save(RatingFixtures.summary(7), key: "remote/1/7", date: Date(), now: Date())
        try await Task.sleep(for: .milliseconds(500))
        let (reloads, sink) = countReloads(results)
        defer { sink.cancel() }

        try await postRemoteChange(storeFile("Own"))
        #expect(reloads.value == 1)
        #expect(results.savedRecords.map(\.id) == ["remote/1/7"])
        // The same file, spelled another way.
        try await postRemoteChange(folder.appendingPathComponent(".").appendingPathComponent("Own.store"))
        #expect(reloads.value == 2)
    }

    @Test("After iCloud sync is switched and the store reopened, the new store's changes count, not the old one's")
    func reopenedStore() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        preferences.syncsHackResults = false
        let local = try openStore("Local")
        var opened: [Bool] = []
        let results = HackResults(preferences: preferences, store: local, reopen: { syncing in
            opened.append(syncing)
            // A container of its own for each choice, as the iCloud one is.
            return (try? self.openStore(syncing ? "Synced" : "Local"), nil)
        })
        try await Task.sleep(for: .milliseconds(300))
        let (reloads, sink) = countReloads(results)
        defer { sink.cancel() }

        try await postRemoteChange(storeFile("Local"))
        try await postRemoteChange(storeFile("Synced"))
        #expect(reloads.value == 1, "Before the switch only the local store counts")

        results.syncsWithICloud = true
        #expect(opened == [true])
        reloads.value = 0
        try await postRemoteChange(storeFile("Local"))
        #expect(reloads.value == 0, "The closed store's changes no longer count")
        try await postRemoteChange(storeFile("Synced"))
        #expect(reloads.value == 1)

        results.syncsWithICloud = false
        #expect(opened == [true, false])
        reloads.value = 0
        try await postRemoteChange(storeFile("Synced"))
        try await postRemoteChange(storeFile("Local"))
        #expect(reloads.value == 1)
    }
}
