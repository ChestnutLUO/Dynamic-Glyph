import Foundation
import CloudKit
import CoreData
import Testing
import GlyphRecognition

@MainActor
@Suite("iCloud sync status")
struct ICloudSyncStatusTests {
    /// The shape of a field report: every record of an export rejected
    /// because the player's iCloud was full.
    func fullStorage() -> CKError {
        let records = (0..<3).map { CKRecord.ID(recordName: "record-\($0)") }
        let partial = Dictionary(uniqueKeysWithValues: records.map {
            ($0, CKError(.quotaExceeded, userInfo: [CKErrorRetryAfterKey: 307.0]) as Error)
        })
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: partial])
    }

    @Test("A full iCloud is recognized directly, inside a partial failure, and wrapped by Core Data")
    func storageFull() {
        #expect(ICloudSyncProblem(CKError(.quotaExceeded)) == .storageFull)
        #expect(ICloudSyncProblem(fullStorage()) == .storageFull)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134_400,
                              userInfo: [NSUnderlyingErrorKey: fullStorage() as NSError])
        #expect(ICloudSyncProblem(wrapped) == .storageFull)
    }

    @Test("Other CloudKit errors say what the player can do, or give the code for a report")
    func otherProblems() {
        #expect(ICloudSyncProblem(CKError(.notAuthenticated)) == .notSignedIn)
        #expect(ICloudSyncProblem(CKError(.networkUnavailable)) == .offline)
        #expect(ICloudSyncProblem(CKError(.networkFailure)) == .offline)
        #expect(ICloudSyncProblem(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0]))
                == .busy(retryAfter: 120))
        #expect(ICloudSyncProblem(CKError(.zoneBusy)) == .busy(retryAfter: nil))
        #expect(ICloudSyncProblem(CKError(.badContainer, userInfo: ["ServerErrorDescription": "Bad container"]))
                == .rejected(code: CKError.Code.badContainer.rawValue, detail: "Bad container"))
        #expect(ICloudSyncProblem(CKError(.serverRecordChanged, userInfo: [NSLocalizedDescriptionKey: "Changed"]))
                == .other(code: CKError.Code.serverRecordChanged.rawValue, detail: "Changed"))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "Nope"])
        #expect(ICloudSyncProblem(cocoa) == .other(code: 4, detail: "Nope"))
    }

    @Test("A failed batch reports the record error that failed it, not the batch failures it caused")
    func batchFailure() {
        func batch(_ cause: CKError) -> CKError {
            var partial: [CKRecord.ID: Error] = [CKRecord.ID(recordName: "cause"): cause]
            for index in 0..<5 {
                partial[CKRecord.ID(recordName: "batch-\(index)")] = CKError(.batchRequestFailed)
            }
            return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: partial])
        }
        let schema = CKError(.invalidArguments, userInfo: [
            "ServerErrorDescription": "Cannot create or modify field 'CD_summary' in record 'CD_SavedHackResult' in production schema"])
        #expect(ICloudSyncProblem(batch(schema)) == .rejected(
            code: CKError.Code.invalidArguments.rawValue,
            detail: "Cannot create or modify field 'CD_summary' in record 'CD_SavedHackResult' in production schema"))
        #expect(ICloudSyncProblem(batch(CKError(.quotaExceeded))) == .storageFull)
        let changed = ICloudSyncProblem(batch(CKError(.serverRecordChanged)))
        if case .other(let code, _) = changed { #expect(code == CKError.Code.serverRecordChanged.rawValue) }
        else { Issue.record("Expected other, got \(changed)") }
        // A batch with nothing but batch failures still says so.
        let only = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey:
            [CKRecord.ID(recordName: "a"): CKError(.batchRequestFailed) as Error]])
        if case .other(let code, _) = ICloudSyncProblem(only) { #expect(code == CKError.Code.batchRequestFailed.rawValue) }
        else { Issue.record("Expected other") }
    }

    @Test("Sync shows running, then the last success; a failure stays until a sync succeeds")
    func monitor() {
        var monitor = ICloudSyncMonitor()
        #expect(monitor.state == .starting)
        let first = UUID(), second = UUID(), end = Date(timeIntervalSince1970: 1000)
        monitor.receive(id: first, type: .import, endDate: nil, succeeded: false, error: nil)
        monitor.receive(id: second, type: .export, endDate: nil, succeeded: false, error: nil)
        #expect(monitor.state == .syncing)
        monitor.receive(id: first, type: .import, endDate: end, succeeded: true, error: nil)
        #expect(monitor.state == .syncing, "Another event is still running")
        monitor.receive(id: second, type: .export, endDate: end, succeeded: true, error: nil)
        #expect(monitor.state == .synced(end))
        let retry = UUID()
        monitor.receive(id: retry, type: .export, endDate: end, succeeded: false, error: fullStorage())
        #expect(monitor.state == .failed(.storageFull))
        monitor.receive(id: UUID(), type: .export, endDate: nil, succeeded: false, error: nil)
        #expect(monitor.state == .failed(.storageFull), "A retry doesn't hide the problem")
        monitor.receive(id: UUID(), type: .export, endDate: end, succeeded: false, error: nil)
        #expect(monitor.state == .failed(.other(code: 0, detail: nil)))
    }

    @Test("A setup that succeeds isn't a sync; the import after it is")
    func setupIsNotSynced() {
        var monitor = ICloudSyncMonitor()
        let setup = UUID(), end = Date(timeIntervalSince1970: 1000)
        monitor.receive(id: setup, type: .setup, endDate: nil, succeeded: false, error: nil)
        monitor.receive(id: setup, type: .setup, endDate: end, succeeded: true, error: nil)
        #expect(monitor.state == .syncing)
        monitor.receive(id: UUID(), type: .import, endDate: end, succeeded: true, error: nil)
        #expect(monitor.state == .synced(end))
        // A setup still fails visibly.
        monitor.receive(id: UUID(), type: .setup, endDate: end, succeeded: false, error: fullStorage())
        #expect(monitor.state == .failed(.storageFull))
    }

    @Test("Switching sync cancels the closed store's steps; however they end, they neither fail nor hold up the new one")
    func closedStoreSteps() {
        var monitor = ICloudSyncMonitor()
        let cancelled = UUID(), abandoned = UUID(), end = Date(timeIntervalSince1970: 1000)
        monitor.receive(id: cancelled, type: .export, endDate: nil, succeeded: false, error: nil)
        monitor.receive(id: abandoned, type: .import, endDate: nil, succeeded: false, error: nil)
        monitor.storeClosed()
        #expect(monitor.state == .starting && !monitor.isSyncing)
        monitor.receive(id: cancelled, type: .export, endDate: end, succeeded: false, error: CocoaError(.userCancelled))
        #expect(monitor.state == .starting)
        // The abandoned import never ends; the new store's import still finishes the sync.
        monitor.receive(id: UUID(), type: .import, endDate: end, succeeded: true, error: nil)
        #expect(monitor.state == .synced(end))
    }

    @Test("The status exists only while sync is on, and starts over with each switch")
    func results() throws {
        let suite = "dynamicglyph-sync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let results = HackResults(preferences: AppPreferences(defaults: defaults),
                                  store: HackResultStore(container: try HackResultStore.makeContainer(inMemory: true)))
        #expect(results.syncState == nil)
        results.receiveSyncEvent(id: UUID(), type: .export, endDate: Date(), succeeded: false, error: fullStorage())
        #expect(results.syncState == nil, "Events of a store that doesn't sync are ignored")
        results.syncsWithICloud = true
        #expect(results.syncState == .starting)
        results.receiveSyncEvent(id: UUID(), type: .export, endDate: Date(), succeeded: false, error: fullStorage())
        #expect(results.syncState == .failed(.storageFull))
        results.syncsWithICloud = false
        #expect(results.syncState == nil)
        results.syncsWithICloud = true
        #expect(results.syncState == .starting)
    }

    func syncingResults(opened: @escaping () -> Void = {}) throws -> (HackResults, HackResultStore, () -> Void) {
        let suite = "dynamicglyph-refresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let synced = HackResultStore(container: try HackResultStore.makeContainer(inMemory: true))
        let results = HackResults(preferences: AppPreferences(defaults: defaults),
                                  store: HackResultStore(container: try HackResultStore.makeContainer(inMemory: true)),
                                  reopen: { _ in opened(); return (synced, nil) })
        return (results, synced, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test("A refresh never reopens the store, syncing or not")
    func refreshKeepsStore() async throws {
        var reopened = 0
        let (results, _, cleanUp) = try syncingResults { reopened += 1 }
        defer { cleanUp() }
        await results.refresh(timeout: .seconds(5))
        #expect(reopened == 0)
        results.syncsWithICloud = true
        #expect(reopened == 1)
        let clock = ContinuousClock(), start = clock.now
        await results.refresh(timeout: .seconds(5))
        #expect(reopened == 1)
        #expect(clock.now - start < .seconds(1), "Nothing is syncing, so there is nothing to wait for")
    }

    @Test("A refresh waits for the running sync step, then rereads what it brought")
    func refreshWaitsForSync() async throws {
        let (results, synced, cleanUp) = try syncingResults()
        defer { cleanUp() }
        results.syncsWithICloud = true
        let importing = UUID()
        results.receiveSyncEvent(id: importing, type: .import, endDate: nil, succeeded: false, error: nil)
        let clock = ContinuousClock(), start = clock.now
        let finishing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            // A hack from another iPhone, arriving with the import.
            try synced.save(HackResultSummary(captureSessionID: 7, hackID: 9, state: .complete, isClosed: true,
                                              closeReason: "panelLeft", hackingBonus: nil, speedBonus: nil, slots: []),
                            key: "other/7/9", date: Date(), now: Date())
            results.receiveSyncEvent(id: importing, type: .import, endDate: Date(), succeeded: true, error: nil)
        }
        await results.refresh(timeout: .seconds(10))
        try await finishing.value
        #expect(clock.now - start >= .milliseconds(250) && clock.now - start < .seconds(5))
        #expect(results.records.compactMap(\.summary?.hackID) == [9])
        if case .synced = results.syncState {} else { Issue.record("Expected synced, got \(String(describing: results.syncState))") }
    }

    @Test("A failed sync step or the time limit ends a refresh")
    func refreshEnds() async throws {
        let (results, _, cleanUp) = try syncingResults()
        defer { cleanUp() }
        results.syncsWithICloud = true
        let export = UUID()
        results.receiveSyncEvent(id: export, type: .export, endDate: nil, succeeded: false, error: nil)
        let clock = ContinuousClock()
        var start = clock.now
        await results.refresh(timeout: .milliseconds(400))
        #expect(clock.now - start >= .milliseconds(400) && clock.now - start < .seconds(3))
        let failing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            results.receiveSyncEvent(id: export, type: .export, endDate: Date(), succeeded: false, error: fullStorage())
        }
        start = clock.now
        await results.refresh(timeout: .seconds(10))
        await failing.value
        #expect(clock.now - start < .seconds(5))
        #expect(results.syncState == .failed(.storageFull))
    }
}
