// ScreenCaptureKit is not in the iOS Simulator SDK; the simulator build
// falls back to ReplayKitBackend so the app can be previewed there.
#if canImport(ScreenCaptureKit)
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Turns ScreenCaptureKit's screen callbacks into `CapturedFrame`s.
///
/// Everything specific to the framework stays here: which output type is the
/// screen, how a frame's status and geometry are attached, and how callbacks
/// behave while the screen is still.
// Sendability relies on queue confinement, as for the recognition output it
// feeds: the stream calls back on one serial queue.
@available(iOS 27, *)
final class ScreenCaptureFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let recognition: LiveGlyphOutput
    /// ScreenCaptureKit keeps delivering idle frames with a repeated timestamp
    /// while the screen is still, so a pause in callbacks is a stall, never a
    /// still screen.
    private var gaps = CallbackGapMonitor()

    init(recognition: LiveGlyphOutput) {
        self.recognition = recognition
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(buffer) else { return }
        let arrival = ProcessInfo.processInfo.systemUptime
        let gap = gaps.arrive(at: arrival)
        recognition.process(CapturedFrame(sampleBuffer: buffer, metadata: Self.metadata(of: buffer),
                                          arrivalUptime: arrival, deliveryGapMilliseconds: gap.gapMilliseconds,
                                          continuityBroken: gap.continuityBroken))
    }

    static func metadata(of sampleBuffer: CMSampleBuffer) -> CaptureFrameMetadata {
        var metadata = CaptureFrameMetadata()
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(array) > 0 else { return metadata }
        let raw = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFDictionary.self)
        let info = raw as? [SCStreamFrameInfo: Any] ?? [:]
        if let n = info[.status] as? Int { metadata.status = status(SCFrameStatus(rawValue: n)) }
        if let n = info[.displayTime] as? UInt64 { metadata.displayTime = n }
        if let n = info[.scaleFactor] as? Double { metadata.scaleFactor = n }
        if let n = info[.contentScale] as? Double { metadata.contentScale = n }
        if let d = info[.contentRect] as? NSDictionary {
            metadata.contentRect = CGRect(dictionaryRepresentation: d)
        }
        if let d = info[.screenRect] as? NSDictionary {
            metadata.screenRect = CGRect(dictionaryRepresentation: d)
        }
        // Available on iOS 27; this is the ScreenCaptureKit counterpart to
        // ReplayKit's RPVideoSampleOrientationKey.
        if let n = info[.videoOrientation] as? UInt32 { metadata.orientation = n }
        return metadata
    }

    private static func status(_ status: SCFrameStatus?) -> CaptureFrameStatus {
        switch status {
        case .complete?: return .complete
        case .idle?: return .idle
        case .blank?: return .blank
        case .suspended?: return .suspended
        case .started?: return .started
        case .stopped?: return .stopped
        default: return .unknown
        }
    }
}

#endif
