import AVFoundation
import CoreMedia
import Foundation
import Testing

/// The optional sound track: real encoding, synthetic 48 kHz stereo sound.
@Suite("Recording sound", .serialized)
struct RecordingSoundTests {
    private typealias Frames = SyntheticFrames

    /// 1024 frames of silent 48 kHz stereo float, the shape of a capture buffer.
    private static func sound(at seconds: Double, frames: Int = 1024) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0,
                                             layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw SyntheticFrames.Failure("could not describe the sound format") }
        let length = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: length, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: length) == noErr else {
            throw SyntheticFrames.Failure("could not allocate sound")
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
                sampleCount: frames, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
                packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample else {
            throw SyntheticFrames.Failure("could not wrap sound")
        }
        return sample
    }

    /// These tests check what ends up in the movie, not how fast it is
    /// finished; the watchdog has its own test with a wedged encoder. On a
    /// freshly erased iPhone SE simulator a recording with sound took up to
    /// 2.8 s to finish even after a warm-up, too close to the 5 s production
    /// deadline to test against it.
    private static let patience = 120.0

    private func recorder(_ name: String, deadline: Double = patience)
        throws -> (DebugScreenRecorder, TemporaryDirectory) {
        let directory = try TemporaryDirectory("sound-\(name)")
        var limits = DebugRecordingLimits.standard
        limits.freeSpaceToStart = 0
        limits.freeSpaceToContinue = 0
        limits.finishDeadline = deadline
        return (try DebugScreenRecorder(directory: directory.url, limits: limits, recordsAudio: true) { _ in },
                directory)
    }

    /// One second of 20 Hz frames with sound alongside, at the producer's pace.
    private func offerWithSound(to recorder: DebugScreenRecorder, origin: Double) throws {
        let description = try Frames.formatDescription()
        let soundStep = 1024.0 / 48_000
        var soundTime = origin
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<20 {
            let delay = start + Double(index) / 20 - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let time = origin + Double(index) / 20
            recorder.offer(try Frames.sample(index: index, at: time, description: description),
                           at: time, status: .complete)
            while soundTime < time + 0.05 {
                recorder.offerAudio(try Self.sound(at: soundTime))
                soundTime += soundStep
            }
        }
    }

    private func tracks(_ directory: TemporaryDirectory) async throws -> (video: Int, audio: Int) {
        let asset = AVURLAsset(url: directory.url.appendingPathComponent("screen-recording.mp4"))
        return (try await asset.loadTracks(withMediaType: .video).count,
                try await asset.loadTracks(withMediaType: .audio).count)
    }

    @Test("Sound offered alongside the frames becomes the movie's audio track")
    func soundTrack() async throws {
        try Frames.warmEncoderHardware()
        let (recorder, directory) = try recorder("track")
        try offerWithSound(to: recorder, origin: 300)
        recorder.requestFinish(.userStopped)
        try #require(recorder.waitForFinish())

        let status = recorder.snapshotStatus()
        #expect(status.outcome == .finished)
        #expect(status.audioSamplesAppended > 0)
        let found = try await tracks(directory)
        #expect(found.video == 1 && found.audio == 1, "tracks: \(found)")
    }

    @Test("A recording with sound switched on but nothing playing is still a good movie")
    func silentGame() async throws {
        try Frames.warmEncoderHardware()
        let (recorder, directory) = try recorder("silent")
        try Frames.offerAtCadence(to: recorder, count: 10, origin: 400)
        recorder.requestFinish(.userStopped)
        try #require(recorder.waitForFinish())

        #expect(recorder.snapshotStatus().outcome == .finished)
        #expect(try await tracks(directory).video == 1)
    }

    @Test("Sound from before the first frame is dropped and counted")
    func soundBeforeTheMovie() throws {
        try Frames.warmEncoderHardware()
        // Held, not discarded: the folder is removed when it is released.
        let (recorder, directory) = try recorder("early")
        defer { withExtendedLifetime(directory) {} }
        for index in 0..<5 { recorder.offerAudio(try Self.sound(at: 100 + Double(index) * 0.02)) }
        try Frames.offerAtCadence(to: recorder, count: 4, origin: 200)
        recorder.requestFinish(.userStopped)
        try #require(recorder.waitForFinish())

        let status = recorder.snapshotStatus()
        #expect(status.audioSamplesDropped == 5)
        #expect(status.audioSamplesAppended == 0)
    }

    @Test("A bug report recording ignores sound")
    func videoOnlyByDefault() throws {
        let directory = try TemporaryDirectory("sound-off")
        var limits = DebugRecordingLimits.standard
        limits.freeSpaceToStart = 0
        let recorder = try DebugScreenRecorder(directory: directory.url, limits: limits) { _ in }
        recorder.offerAudio(try Self.sound(at: 1))
        recorder.requestFinish(.sessionStopped)
        #expect(recorder.waitForFinish())
        let status = recorder.snapshotStatus()
        #expect(status.audioSamplesAppended == 0 && status.audioSamplesDropped == 0)
    }
}
