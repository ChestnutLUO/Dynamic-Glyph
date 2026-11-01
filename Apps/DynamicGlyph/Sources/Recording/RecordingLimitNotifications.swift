import Combine
import Foundation
import UserNotifications

@MainActor
protocol RecordingNotificationSending {
    func authorization(requestIfNeeded: Bool) async -> Bool
    func post(message: String, identifier: String) async throws
    func remove(identifier: String)
}

/// Local notifications work while Ingress is in front; no server or push
/// registration is involved. Permission is requested from the recording toggle.
@MainActor
final class LocalRecordingNotifications: NSObject, RecordingNotificationSending, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func authorization(requestIfNeeded: Bool) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined where requestIfNeeded:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    func post(message: String, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Recording limit approaching",
                               comment: "Title of a local notification before screen recording reaches a limit.")
        content.body = message
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func remove(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix("recording-limit.") ? [.banner, .list, .sound] : []
    }
}

/// Matches progress and asynchronous delivery to an individual recording.
/// A stopped or replaced recording cannot send a late warning into a new run.
@MainActor
final class RecordingLimitNotifications: ObservableObject {
    @Published private(set) var messages: [RecordingKind: String] = [:]
    @Published private(set) var notificationsAllowed: Bool?
    var onEvent: ((String) -> Void)?

    private struct Run {
        let id: UUID
        let started: Double
        var policy: RecordingLimitWarningPolicy
        var delivery: Task<Void, Never>?
        var identifier: String { "recording-limit.\(id.uuidString)" }
    }

    private let sender: any RecordingNotificationSending
    private var runs: [RecordingKind: Run] = [:]

    init(sender: any RecordingNotificationSending) { self.sender = sender }

    func requestAuthorization() async {
        notificationsAllowed = await sender.authorization(requestIfNeeded: true)
    }

    func begin(_ kind: RecordingKind, id: UUID, limits: DebugRecordingLimits,
               at uptime: Double = ProcessInfo.processInfo.systemUptime) {
        end(kind)
        runs[kind] = Run(id: id, started: uptime, policy: RecordingLimitWarningPolicy(limits: limits))
    }

    func update(_ kind: RecordingKind, id: UUID, status: DebugRecordingStatus,
                at uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard var run = runs[kind], run.id == id else { return }
        guard status.isRecording, status.stopReason == nil else { end(kind); return }
        let warning = run.policy.update(status, elapsed: max(0, uptime - run.started))
        runs[kind] = run
        guard let warning else { return }
        let message = warning.message(for: kind)
        messages[kind] = message
        onEvent?("\(kind.rawValue) recording approaching \(warning) limit")
        let identifier = run.identifier
        runs[kind]?.delivery = Task { [weak self, sender] in
            let allowed = await sender.authorization(requestIfNeeded: false)
            guard let self, !Task.isCancelled, self.runs[kind]?.id == id else { return }
            self.notificationsAllowed = allowed
            guard allowed else { return }
            do {
                try await sender.post(message: message, identifier: identifier)
                // Stop can race the notification center's asynchronous add.
                if Task.isCancelled || self.runs[kind]?.id != id { sender.remove(identifier: identifier) }
            } catch {
                self.onEvent?("recording limit notification failed: \(error.localizedDescription)")
            }
        }
    }

    func end(_ kind: RecordingKind) {
        if let run = runs.removeValue(forKey: kind) {
            run.delivery?.cancel()
            sender.remove(identifier: run.identifier)
        }
        messages[kind] = nil
    }

    func endAll() { for kind in RecordingKind.allCases { end(kind) } }
}
