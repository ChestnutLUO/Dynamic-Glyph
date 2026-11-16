import Combine
import CoreData
import Foundation
import Testing
import TipKit
import GlyphRecognition

/// A stutter this guards against: every `AppTips.update` with a saved hack
/// invalidated Start here again. Each TipKit write is a Core Data save, which
/// posts `NSPersistentStoreRemoteChange`; `HackResults` reloads on it, and the
/// reload brings the app back to `AppTips.update`. These tests hold the tips
/// to "write only what changes": with 360 hacks, idle, no tip saves and no
/// hack-list reloads.
@MainActor
@Suite("Tip datastore writes")
struct TipDatastoreWritesTests {
    /// Counts what the app writes, and answers like TipKit: a tip stays
    /// invalidated.
    final class CountingDatastore: TipDatastore {
        var parameterWrites = 0
        var invalidations: [AppTip] = []
        var writes: Int { parameterWrites + invalidations.count }
        private var invalidated: Set<AppTip>

        init(invalidated: Set<AppTip> = []) { self.invalidated = invalidated }

        var savedHackCount = 0 { didSet { parameterWrites += 1 } }
        var isIdle = true { didSet { parameterWrites += 1 } }
        var floatingWindowOn = true { didSet { parameterWrites += 1 } }
        var gameLanguageRelevant = true { didSet { parameterWrites += 1 } }
        var shortcutsTipUnblocked = false { didSet { parameterWrites += 1 } }
        var appearanceTipUnblocked = false { didSet { parameterWrites += 1 } }

        func isInvalidated(_ tip: AppTip) -> Bool { invalidated.contains(tip) }
        func invalidate(_ tip: AppTip) {
            invalidations.append(tip)
            invalidated.insert(tip)
        }
    }

    static func saved(_ count: Int) -> [HackResultRecord] {
        (0..<count).map { RatingFixtures.record($0, at: RatingFixtures.base.addingTimeInterval(Double($0) * 60)) }
    }

    static func facts(_ count: Int, floatingWindowTipDone: Bool = false) -> TipFacts {
        TipFacts(saved: saved(count), isIdle: true, floatingWindowOn: true, chosenGameLanguage: nil,
                 detectedGameLanguage: nil, floatingWindowTipDone: floatingWindowTipDone)
    }

    @Test("With 360 saved hacks, updates with nothing new write nothing after the first")
    func repeatedUpdatesWriteOnce() {
        let datastore = CountingDatastore()
        let facts = Self.facts(360)
        AppTips.update(facts, in: datastore)
        #expect(datastore.invalidations == [.start])
        #expect(datastore.savedHackCount == 360)
        let first = datastore.writes
        // What the loop did: an update per reload, about 43 a second.
        for _ in 0..<430 { AppTips.update(facts, in: datastore) }
        #expect(datastore.writes == first, "No TipKit write when the facts are unchanged")
    }

    @Test("Start here, already retired at an earlier launch, is not invalidated again")
    func startRetiredEarlier() {
        let datastore = CountingDatastore(invalidated: [.start])
        datastore.savedHackCount = 360
        datastore.parameterWrites = 0
        for _ in 0..<100 { AppTips.update(Self.facts(360), in: datastore) }
        #expect(datastore.writes == 0)
    }

    @Test("Each changed fact is one write, and Start here is retired only by the first saved hack")
    func onlyChangesAreWritten() {
        let datastore = CountingDatastore()
        AppTips.update(Self.facts(0), in: datastore)
        #expect(datastore.writes == 0, "Defaults match a fresh install with nothing saved")
        AppTips.update(Self.facts(1), in: datastore)
        #expect(datastore.parameterWrites == 1 && datastore.invalidations == [.start])
        AppTips.update(Self.facts(2), in: datastore)
        #expect(datastore.parameterWrites == 2 && datastore.invalidations == [.start])
        AppTips.update(Self.facts(2, floatingWindowTipDone: true), in: datastore)
        #expect(datastore.parameterWrites == 3 && datastore.shortcutsTipUnblocked)
        AppTips.update(Self.facts(2, floatingWindowTipDone: true), in: datastore)
        #expect(datastore.parameterWrites == 3 && datastore.invalidations == [.start])
    }

    @Test("Changing the game language and opening Appearance retire their tips once")
    func retireOnce() {
        let datastore = CountingDatastore()
        for _ in 0..<5 {
            AppTips.retire(.gameLanguage, in: datastore)
            AppTips.retire(.appearance, in: datastore)
        }
        #expect(datastore.invalidations == [.gameLanguage, .appearance])
        let closed = CountingDatastore(invalidated: [.appearance])
        AppTips.retire(.appearance, in: closed)
        #expect(closed.writes == 0, "A tip closed or shown its one time is not written again")
    }

    @Test("The rating prompt's record: a launch of the same version and a second check write nothing")
    func reviewRecordWritesOnce() throws {
        let suite = "TipDatastoreWritesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = ReviewPromptRecord(defaults: defaults)
        #expect(record.registerLaunch(version: "1.2"))
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                              object: defaults, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(!record.registerLaunch(version: "1.2"))
        #expect(changes == 0, "The same version launching again stores nothing")
        // Asked once: the policy refuses this version from then on, so the
        // app never reaches `recordAsk` for it again.
        record.recordAsk(version: "1.2", at: RatingFixtures.base)
        var input = ReviewPromptPolicyTests.ready
        #expect(ReviewPromptPolicy.shouldAsk(input) && input.appVersion == "1.2")
        input.lastAskedVersion = record.lastAskedVersion
        input.lastAskedDate = record.lastAskedDate
        #expect(ReviewPromptPolicy.reasonsNotToAsk(input).contains(.askedThisVersion))
    }
}

/// The loop end to end with TipKit's real datastore, in a folder of its own:
/// `HackResults` with 360 saved hacks, wired to `AppTips.update` as
/// ContentView wires it (`.onReceive($records)`, then update on main), and
/// updates driven on top while idle, as any other trigger would.
@MainActor
@Suite("Tips and the hack list, idle", .serialized)
struct TipsIdleLoopTests {
    static let datastoreFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("TipsIdleLoopTests-\(UUID().uuidString)", isDirectory: true)

    /// TipKit is configured once per process.
    static let configured: Bool = {
        try? FileManager.default.createDirectory(at: datastoreFolder, withIntermediateDirectories: true)
        do {
            try Tips.configure([.datastoreLocation(.url(datastoreFolder))])
            return true
        } catch {
            return false
        }
    }()

    final class Counter {
        var value = 0
    }

    @Test("360 saved hacks and the app idle for 10 seconds: no tip saves and no hack-list reloads")
    func idleWithSavedHacks() async throws {
        try #require(Self.configured, "TipKit datastore in a temporary folder")
        let suite = "TipsIdleLoopTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let now = Date()
        for hack in 0..<360 {
            try store.save(RatingFixtures.summary(hack), key: "idle/1/\(hack)",
                           date: now.addingTimeInterval(-Double(hack) * 600), now: now)
        }
        let results = HackResults(preferences: AppPreferences(defaults: defaults), store: store)
        #expect(results.savedRecords.count == 360)

        // TipKit's saves, seen as the app sees them; and the hack list's reloads.
        let tipSaves = Counter(), reloads = Counter()
        let tipKitFolder = Self.datastoreFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
                                                              object: nil, queue: nil) { note in
            let url = (note.userInfo?[NSPersistentStoreURLKey] as? URL)?
                .standardizedFileURL.resolvingSymlinksInPath().path ?? ""
            guard url.hasPrefix(tipKitFolder) else { return }
            DispatchQueue.main.async { tipSaves.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let datastore = LiveTipDatastore(defaults: defaults)
        func facts() -> TipFacts {
            TipFacts(saved: results.savedRecords, isIdle: true, floatingWindowOn: true,
                     chosenGameLanguage: nil, detectedGameLanguage: nil)
        }
        // ContentView: `.onReceive(engine.results.$records)`, then update.
        let wiring = results.$records.dropFirst().sink { _ in
            reloads.value += 1
            DispatchQueue.main.async { AppTips.update(facts(), in: datastore) }
        }
        defer { wiring.cancel() }

        /// Waits for a second with no TipKit save and no reload; false if
        /// none comes within `limit` seconds.
        func settle(within limit: Int) async throws -> Bool {
            for _ in 0..<limit {
                let before = (tipSaves.value, reloads.value)
                try await Task.sleep(for: .seconds(1))
                if (tipSaves.value, reloads.value) == before { return true }
            }
            return false
        }

        // Launch: the parameters take the saved hacks and Start here is
        // retired, on a fresh datastore; then the app quiets down.
        AppTips.update(facts(), in: datastore)
        #expect(datastore.isInvalidated(.start))
        #expect(try await settle(within: 10), "The launch's writes come to an end")
        print("TipsIdleLoopTests launch: \(tipSaves.value) TipKit saves, \(reloads.value) reloads")
        #expect(tipSaves.value >= 1, "TipKit's saves are seen here, so the zeros below mean something")
        #expect(reloads.value == 0, "TipKit's saves are not the hack list's")

        // Idle for 10 seconds, the facts unchanged and updates coming in
        // ten times a second. Without the guard the app saved and reloaded
        // about 43 times a second here.
        tipSaves.value = 0; reloads.value = 0
        for _ in 0..<100 {
            AppTips.update(facts(), in: datastore)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(tipSaves.value == 0, "TipKit saves while idle")
        #expect(reloads.value == 0, "Hack-list reloads while idle")

        // The next launch: Start here is known retired before TipKit has
        // loaded its status.
        let nextLaunch = LiveTipDatastore(defaults: defaults)
        #expect(nextLaunch.isInvalidated(.start))
        for _ in 0..<50 { AppTips.update(facts(), in: nextLaunch) }
        try await Task.sleep(for: .seconds(1))
        #expect(tipSaves.value == 0 && reloads.value == 0, "Unchanged facts at a new launch")

        // A real parameter change is saved, and still doesn't reload the list.
        datastore.isIdle = false
        for _ in 0..<50 where tipSaves.value == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(tipSaves.value >= 1, "A changed fact is saved")
        datastore.isIdle = true
        #expect(try await settle(within: 10))
        #expect(reloads.value == 0, "TipKit's saves never reload the hack list")
    }
}
