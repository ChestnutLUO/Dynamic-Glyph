// ScreenCaptureKit is not in the iOS Simulator SDK; the simulator build
// falls back to ReplayKitBackend so the app can be previewed there.
#if canImport(ScreenCaptureKit)
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Hands the capture stream's sound to the Photos recording.
///
/// A separate output on a queue of its own, so sound never waits behind
/// recognition and recognition never touches sound. The recorder is safe to
/// call from any queue and drops what it cannot take.
@available(iOS 27, *)
final class RecordingAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let recorder: DebugScreenRecorder

    init(recorder: DebugScreenRecorder) {
        self.recorder = recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(buffer) else { return }
        recorder.offerAudio(buffer)
    }
}

#endif
