import Foundation
import Testing

@Suite("Recording limit warnings")
struct RecordingLimitWarningTests {
    private func progress(bytes: Int = 0, duration: Double = 0) -> DebugRecordingStatus {
        DebugRecordingStatus(isRecording: true, framesAppended: 1, byteCount: bytes, coveredDuration: duration)
    }

    @Test("Both recording types warn at 90 percent, once", arguments: [RecordingKind.photos, .bugReport])
    func sizeThreshold(kind: RecordingKind) {
        let limits: DebugRecordingLimits = kind == .photos ? .album : .standard
        let threshold = Int(ceil(Double(limits.maximumBytes) * 0.9))
        var policy = RecordingLimitWarningPolicy(limits: limits)
        #expect(policy.update(progress(bytes: threshold - 1), elapsed: 0) == nil)
        #expect(policy.update(progress(bytes: threshold), elapsed: 0) == .size)
        #expect(policy.update(progress(bytes: threshold + 1), elapsed: limits.maximumDuration - 1) == nil)
    }

    @Test("A static screen still warns a minute before the wall-time cap", arguments: [RecordingKind.photos, .bugReport])
    func durationThreshold(kind: RecordingKind) {
        let limits: DebugRecordingLimits = kind == .photos ? .album : .standard
        var policy = RecordingLimitWarningPolicy(limits: limits)
        #expect(policy.update(progress(duration: 1), elapsed: limits.maximumDuration - 60.1) == nil)
        #expect(policy.update(progress(duration: 1), elapsed: limits.maximumDuration - 60) == .duration)
        #expect(policy.update(progress(bytes: limits.maximumBytes - 1), elapsed: limits.maximumDuration - 2) == nil)
    }

    @Test("Source coverage can approach its cap before wall time")
    func sourceDuration() {
        var policy = RecordingLimitWarningPolicy(limits: .standard)
        #expect(policy.update(progress(duration: 540), elapsed: 10) == .duration)
    }

    @Test("No nearing-limit warning for empty, stopped, finishing, or already capped recordings")
    func ineligible() {
        let statuses = [
            DebugRecordingStatus(isRecording: true, byteCount: 290 * 1024 * 1024),
            DebugRecordingStatus(isRecording: false, framesAppended: 1),
            DebugRecordingStatus(isRecording: true, framesAppended: 1, stopReason: .userStopped),
            progress(bytes: DebugRecordingLimits.standard.maximumBytes),
            progress(duration: DebugRecordingLimits.standard.maximumDuration)
        ]
        for status in statuses {
            var policy = RecordingLimitWarningPolicy(limits: .standard)
            #expect(policy.update(status, elapsed: 550) == nil)
        }
    }

    @Test("A stopped recorder reports finishing immediately, even while the encoder is blocked")
    func finishingStatus() throws {
        let directory = try TemporaryDirectory("recording-warning-finish")
        var limits = DebugRecordingLimits.standard
        limits.freeSpaceToStart = 0
        let recorder = try DebugScreenRecorder(directory: directory.url, limits: limits) { _ in }
        let release = recorder.blockEncoderForTesting()
        recorder.requestFinish(.diskSpace)
        let status = recorder.snapshotStatus()
        #expect(!status.isRecording)
        #expect(status.stopReason == .diskSpace)
        #expect(status.outcome == nil)
        release.signal()
        #expect(recorder.waitForFinish())
    }
}

@MainActor
@Suite("Recording warning delivery")
struct RecordingWarningDeliveryTests {
    private final class Sender: RecordingNotificationSending {
        var allowed = true
        var requests: [Bool] = []
        var posted: [String] = []
        var removed: [String] = []
        var pauseAuthorization = false
        var pausePost = false
        var failPost = false
        var authorizationWait: CheckedContinuation<Void, Never>?
        var postWait: CheckedContinuation<Void, Never>?

        func authorization(requestIfNeeded: Bool) async -> Bool {
            requests.append(requestIfNeeded)
            if pauseAuthorization { await withCheckedContinuation { authorizationWait = $0 } }
            return allowed
        }
        func post(message: String, identifier: String) async throws {
            if pausePost { await withCheckedContinuation { postWait = $0 } }
            if failPost { throw Failure() }
            posted.append(identifier)
        }
        func remove(identifier: String) { removed.append(identifier) }
    }

    private struct Failure: Error {}
    private let near = DebugRecordingStatus(isRecording: true, framesAppended: 1, byteCount: 990 * 1024 * 1024)

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure()
    }

    @Test("Denied permission keeps the in-app warning and never asks again at the limit")
    func denied() async throws {
        let sender = Sender()
        sender.allowed = false
        let warnings = RecordingLimitNotifications(sender: sender)
        await warnings.requestAuthorization()
        let id = UUID()
        warnings.begin(.photos, id: id, limits: .album, at: 0)
        warnings.update(.photos, id: id, status: near, at: 1)
        try await waitUntil { sender.requests.count == 2 }
        #expect(sender.requests == [true, false])
        #expect(warnings.notificationsAllowed == false)
        #expect(warnings.messages[.photos] != nil)
        #expect(sender.posted.isEmpty)
        warnings.end(.photos)
        #expect(warnings.messages.isEmpty)
    }

    @Test("Concurrent recordings have independent warnings and a new recording resets the allowance")
    func independentRecordings() async throws {
        let sender = Sender()
        let warnings = RecordingLimitNotifications(sender: sender)
        let photos = UUID(), debug = UUID()
        warnings.begin(.photos, id: photos, limits: .album, at: 0)
        warnings.begin(.bugReport, id: debug, limits: .standard, at: 0)
        warnings.update(.photos, id: photos, status: near, at: 1)
        let debugNear = DebugRecordingStatus(isRecording: true, framesAppended: 1, byteCount: 290 * 1024 * 1024)
        warnings.update(.bugReport, id: debug, status: debugNear, at: 1)
        warnings.update(.photos, id: photos, status: near, at: 2)
        try await waitUntil { sender.posted.count == 2 }
        #expect(Set(sender.posted).count == 2)
        #expect(warnings.messages.count == 2)
        let replacement = UUID()
        warnings.begin(.photos, id: replacement, limits: .album, at: 3)
        warnings.update(.photos, id: photos, status: near, at: 4)
        #expect(warnings.messages[.photos] == nil)
        warnings.update(.photos, id: replacement, status: near, at: 4)
        try await waitUntil { sender.posted.count == 3 }
        warnings.endAll()
        #expect(warnings.messages.isEmpty)
    }

    @Test("Stop while checking permission prevents a late notification")
    func stopDuringAuthorization() async throws {
        let sender = Sender()
        sender.pauseAuthorization = true
        let warnings = RecordingLimitNotifications(sender: sender)
        let id = UUID()
        warnings.begin(.photos, id: id, limits: .album, at: 0)
        warnings.update(.photos, id: id, status: near, at: 1)
        try await waitUntil { sender.authorizationWait != nil }
        warnings.endAll()
        sender.authorizationWait?.resume()
        sender.authorizationWait = nil
        // Let the resumed task run before checking that it did not deliver.
        try await Task.sleep(for: .milliseconds(20))
        #expect(sender.posted.isEmpty)
        #expect(warnings.messages.isEmpty)
    }

    @Test("An add completing after Stop is removed without touching the next recording")
    func stopDuringPost() async throws {
        let sender = Sender()
        sender.pausePost = true
        let warnings = RecordingLimitNotifications(sender: sender)
        let first = UUID(), next = UUID()
        warnings.begin(.photos, id: first, limits: .album, at: 0)
        warnings.update(.photos, id: first, status: near, at: 1)
        try await waitUntil { sender.postWait != nil }
        warnings.begin(.photos, id: next, limits: .album, at: 2)
        sender.postWait?.resume()
        sender.postWait = nil
        try await waitUntil { sender.posted.count == 1 && sender.removed.count == 2 }
        #expect(sender.removed.allSatisfy { $0 == sender.posted.first })
        sender.pausePost = false
        warnings.update(.photos, id: next, status: near, at: 3)
        try await waitUntil { sender.posted.count == 2 }
        #expect(!sender.removed.contains(sender.posted[1]))
    }

    @Test("Terminal progress removes the warning and rejects out-of-order progress")
    func terminalProgress() async throws {
        let sender = Sender()
        let warnings = RecordingLimitNotifications(sender: sender)
        let id = UUID()
        warnings.begin(.photos, id: id, limits: .album, at: 0)
        warnings.update(.photos, id: id, status: near, at: 1)
        try await waitUntil { sender.posted.count == 1 }
        warnings.update(.photos, id: id, status: DebugRecordingStatus(isRecording: false), at: 2)
        warnings.update(.photos, id: id, status: near, at: 3)
        #expect(warnings.messages.isEmpty)
        #expect(sender.removed == sender.posted)
    }

    @Test("Delivery failure leaves the in-app warning and logs the failure")
    func failedDelivery() async throws {
        let sender = Sender()
        sender.failPost = true
        let warnings = RecordingLimitNotifications(sender: sender)
        var events: [String] = []
        warnings.onEvent = { events.append($0) }
        let id = UUID()
        warnings.begin(.photos, id: id, limits: .album, at: 0)
        warnings.update(.photos, id: id, status: near, at: 1)
        try await waitUntil { events.count == 2 }
        #expect(events.last?.contains("failed") == true)
        #expect(warnings.messages[.photos] != nil)
    }
}
