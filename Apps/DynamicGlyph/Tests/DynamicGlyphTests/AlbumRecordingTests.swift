import AVFoundation
import Foundation
import Testing

/// The recording the player keeps: real encoding with synthetic frames, and a
/// stand-in for Photos, so what happens to the file afterwards is checked
/// without a photo library.
@Suite("Recording to Photos", .serialized)
struct AlbumRecordingTests {
    private typealias Frames = SyntheticFrames

    /// Collects what the recording reports from the queues it reports on.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [AlbumRecordingResult] = []
        private var saves = 0

        func finished(_ result: AlbumRecordingResult) { lock.lock(); results.append(result); lock.unlock() }
        func saved() { lock.lock(); saves += 1; lock.unlock() }
        var all: [AlbumRecordingResult] { lock.lock(); defer { lock.unlock() }; return results }
        var saveCount: Int { lock.lock(); defer { lock.unlock() }; return saves }

        func first(within seconds: Double = 20) throws -> AlbumRecordingResult {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let result = all.first { return result }
                usleep(10_000)
            }
            throw SyntheticFrames.Failure("no result within \(seconds) seconds")
        }
    }

    private struct PhotosRefused: LocalizedError {
        var errorDescription: String? { "the library refused the file" }
    }

    /// The album limits, without their free-space margin, which a simulator's
    /// disk may not have, and with a finish deadline a cold simulator's
    /// encoder can meet: these tests follow the file, and the watchdog has its
    /// own test. A freshly erased iPhone SE simulator took 10 to 27 s for its
    /// first encoder session.
    private var limits: DebugRecordingLimits {
        var limits = DebugRecordingLimits.album
        limits.freeSpaceToStart = 0
        limits.freeSpaceToContinue = 0
        limits.finishDeadline = 120
        return limits
    }

    private func contents(_ directory: TemporaryDirectory) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
    }

    @Test("A finished recording is handed to Photos once, and its working folder removed")
    func savedToPhotos() async throws {
        try Frames.warmEncoderHardware()
        let work = try TemporaryDirectory("album-work")
        let files = try TemporaryDirectory("album-files")
        let library = try TemporaryDirectory("album-library")
        let outcome = Outcome()
        let recorder = try AlbumRecording.start(
            limits: limits, workRoot: work.url, fallbackDirectory: files.url,
            save: { movie in
                // What Photos does with `shouldMoveFile`.
                outcome.saved()
                try FileManager.default.moveItem(at: movie, to: library.url.appendingPathComponent("saved.mp4"))
            },
            onStatus: { _ in }, onFinish: outcome.finished)
        #expect(try contents(work).count == 1, "the working folder should exist while recording")

        try Frames.offerAtCadence(to: recorder, count: 10, origin: 500)
        recorder.requestFinish(.userStopped)
        // The session ending afterwards must not save a second copy.
        recorder.requestFinish(.sessionStopped)

        #expect(try outcome.first() == .saved)
        usleep(300_000)
        #expect(outcome.all.count == 1)
        #expect(outcome.saveCount == 1)
        #expect(try contents(work).isEmpty, "the working folder was left behind")
        #expect(try contents(files).isEmpty)

        let asset = AVURLAsset(url: library.url.appendingPathComponent("saved.mp4"))
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1, "Photos was given an unplayable file")
    }

    @Test("When Photos refuses the video, it is kept in the app's folder instead")
    func keptWhenPhotosRefuses() throws {
        try Frames.warmEncoderHardware()
        let work = try TemporaryDirectory("album-work")
        let files = try TemporaryDirectory("album-files")
        let outcome = Outcome()
        let recorder = try AlbumRecording.start(
            limits: limits, workRoot: work.url, fallbackDirectory: files.url,
            save: { _ in throw PhotosRefused() },
            onStatus: { _ in }, onFinish: outcome.finished)

        try Frames.offerAtCadence(to: recorder, count: 10, origin: 700)
        recorder.requestFinish(.userStopped)

        guard case .keptInFiles(let name, let reason) = try outcome.first() else {
            Issue.record("expected the video to be kept in Files, got \(outcome.all)")
            return
        }
        #expect(reason == "the library refused the file")
        #expect(name.hasPrefix("DynamicGlyph-recording-") && name.hasSuffix(".mp4"))
        #expect(try contents(files) == [name])
        let size = try FileManager.default.attributesOfItem(
            atPath: files.url.appendingPathComponent(name).path)[.size] as? Int
        #expect((size ?? 0) > 0)
        #expect(try contents(work).isEmpty)
    }

    @Test("A recording that never received a frame saves nothing")
    func nothingRecorded() throws {
        let work = try TemporaryDirectory("album-work")
        let files = try TemporaryDirectory("album-files")
        let outcome = Outcome()
        let recorder = try AlbumRecording.start(
            limits: limits, workRoot: work.url, fallbackDirectory: files.url,
            save: { _ in outcome.saved() },
            onStatus: { _ in }, onFinish: outcome.finished)

        recorder.requestFinish(.sessionStopped)

        #expect(try outcome.first() == .nothingRecorded)
        #expect(outcome.saveCount == 0)
        #expect(try contents(work).isEmpty)
        #expect(try contents(files).isEmpty)
    }

    @Test("Too little free space to start leaves nothing behind")
    func refusedToStart() throws {
        let work = try TemporaryDirectory("album-work")
        let files = try TemporaryDirectory("album-files")
        var limits = limits
        limits.freeSpaceToStart = .max
        #expect(throws: DebugScreenRecorder.Failure.self) {
            _ = try AlbumRecording.start(limits: limits, workRoot: work.url, fallbackDirectory: files.url,
                                         save: { _ in }, onStatus: { _ in }, onFinish: { _ in })
        }
        #expect(try contents(work).isEmpty)
    }
}
