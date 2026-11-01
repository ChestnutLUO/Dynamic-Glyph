import Foundation

enum RecordingKind: String, CaseIterable, Sendable {
    case photos, bugReport
}

enum RecordingLimitWarning: Sendable, Equatable {
    case size, duration

    func message(for kind: RecordingKind) -> String {
        switch (kind, self) {
        case (.photos, .size):
            return String(localized: "Your Photos recording is nearing its size limit. It will stop automatically at 1 GB. Glyph recognition will continue.",
                          comment: "Recording warning at 90 percent of the Photos video's size limit.")
        case (.photos, .duration):
            return String(localized: "Your Photos recording has one minute or less left before its 30-minute limit. Glyph recognition will continue.",
                          comment: "Recording warning with at most one minute remaining.")
        case (.bugReport, .size):
            return String(localized: "Your bug-report recording is nearing its size limit. It will stop automatically at 300 MB. Glyph recognition will continue.",
                          comment: "Recording warning at 90 percent of the bug-report video's size limit.")
        case (.bugReport, .duration):
            return String(localized: "Your bug-report recording has one minute or less left before its 10-minute limit. Glyph recognition will continue.",
                          comment: "Bug-report recording warning with at most one minute remaining.")
        }
    }
}

/// A single heads-up per recording, even if both limits are approached.
/// Elapsed time uses the recorder's wall-time cap as well as source coverage:
/// a static screen must not postpone the warning until another frame arrives.
struct RecordingLimitWarningPolicy {
    let limits: DebugRecordingLimits
    private(set) var didWarn = false

    mutating func update(_ status: DebugRecordingStatus, elapsed: Double) -> RecordingLimitWarning? {
        guard !didWarn, status.isRecording, status.stopReason == nil,
              status.framesAppended > 0 else { return nil }
        let duration = max(elapsed, status.coveredDuration)
        guard status.byteCount < limits.maximumBytes, duration < limits.maximumDuration else { return nil }
        let warning: RecordingLimitWarning?
        if Double(status.byteCount) >= Double(limits.maximumBytes) * 0.9 {
            warning = .size
        } else if duration >= max(0, limits.maximumDuration - 60) {
            warning = .duration
        } else {
            warning = nil
        }
        if warning != nil { didWarn = true }
        return warning
    }
}
