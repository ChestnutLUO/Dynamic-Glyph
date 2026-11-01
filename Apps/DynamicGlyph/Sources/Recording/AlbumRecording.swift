import Foundation

/// What became of a recording the player asked to keep.
enum AlbumRecordingResult: Sendable, Equatable {
    case saved
    /// Photos refused it, so it was moved into the app's folder instead,
    /// where the Files app can reach it. Carries the file name and why.
    case keptInFiles(name: String, reason: String)
    /// No frame was ever written, so there was nothing to save.
    case nothingRecorded
    /// The movie could not be finished or moved anywhere useful.
    case failed(String)
}

/// A screen recording the player keeps, handed to Photos when it ends.
///
/// Separate from the bug-report recording on purpose: it needs no session
/// folder, runs under its own limits, and its movie lives in a private
/// temporary folder only until Photos has it. The encoding itself is the
/// same `DebugScreenRecorder`, fed the same analyzed frames.
///
/// Free of Photos and UIKit, with the save passed in, so the tests can drive
/// the whole path with synthetic frames on a simulator.
enum AlbumRecording {
    typealias Save = @Sendable (URL) async throws -> Void

    /// Starts a recorder whose movie is saved by `save` once it has finished,
    /// whichever way it finishes: Stop, the end of the session, or a cap.
    ///
    /// `onStatus` receives every progress report, `onFinish` the outcome of
    /// the save, exactly once.
    static func start(limits: DebugRecordingLimits = .album,
                      recordsAudio: Bool = false,
                      workRoot: URL = FileManager.default.temporaryDirectory,
                      fallbackDirectory: URL,
                      save: @escaping Save,
                      onStatus: @escaping @Sendable (DebugRecordingStatus) -> Void,
                      onFinish: @escaping @Sendable (AlbumRecordingResult) -> Void) throws -> DebugScreenRecorder {
        let directory = workRoot.appendingPathComponent("album-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let job = Job(directory: directory, fallbackDirectory: fallbackDirectory, save: save, onFinish: onFinish)
        do {
            return try DebugScreenRecorder(directory: directory, limits: limits,
                                           recordsAudio: recordsAudio) { status in
                onStatus(status)
                job.recordingChanged(status)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Holds only what the save needs, not the recorder, so the recorder's
    /// status callback can own it without a reference cycle.
    private final class Job: @unchecked Sendable {
        private let directory: URL
        private let fallbackDirectory: URL
        private let save: Save
        private let onFinish: @Sendable (AlbumRecordingResult) -> Void
        private let lock = NSLock()
        private var started = false

        init(directory: URL, fallbackDirectory: URL, save: @escaping Save,
             onFinish: @escaping @Sendable (AlbumRecordingResult) -> Void) {
            self.directory = directory
            self.fallbackDirectory = fallbackDirectory
            self.save = save
            self.onFinish = onFinish
        }

        func recordingChanged(_ status: DebugRecordingStatus) {
            guard !status.isRecording, let outcome = status.outcome else { return }
            lock.lock()
            guard !started else { lock.unlock(); return }
            started = true
            lock.unlock()
            let movie = directory.appendingPathComponent("screen-recording.mp4")
            switch outcome {
            case .finished:
                Task.detached { [self] in onFinish(await keep(movie)) }
            case .notStarted:
                try? FileManager.default.removeItem(at: directory)
                onFinish(.nothingRecorded)
            case .failed, .timedOut:
                // A writer that timed out may still be cancelled on its own
                // queue, which can remove the file, so it is not moved here.
                onFinish(.failed(status.message ?? outcome.rawValue))
            }
        }

        private func keep(_ movie: URL) async -> AlbumRecordingResult {
            do {
                try await save(movie)
                try? FileManager.default.removeItem(at: directory)
                return .saved
            } catch {
                let name = "DynamicGlyph-recording-" + ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-") + ".mp4"
                do {
                    try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: movie, to: fallbackDirectory.appendingPathComponent(name))
                    try? FileManager.default.removeItem(at: directory)
                    return .keptInFiles(name: name, reason: error.localizedDescription)
                } catch let moveError {
                    // The only copy stays where it is rather than being deleted.
                    return .failed("\(error.localizedDescription); \(moveError.localizedDescription)")
                }
            }
        }
    }
}

extension DebugRecordingLimits {
    /// A recording kept for its own sake runs longer than a bug report's. At
    /// 4 Mbit/s the duration cap lands before the byte cap. The start margin
    /// leaves room for Photos to import the finished file.
    static let album: DebugRecordingLimits = {
        var limits = DebugRecordingLimits.standard
        limits.maximumDuration = 30 * 60
        limits.maximumBytes = 1024 * 1024 * 1024
        limits.freeSpaceToStart = 1536 * 1024 * 1024
        return limits
    }()
}
