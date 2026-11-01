import CoreGraphics
import CoreMedia
import Foundation

/// A captured frame's status, restated without any capture framework.
///
/// Recognition and the recorder are deliberately free of ScreenCaptureKit so
/// they can be driven by synthetic frames, and by another capture source.
/// Passing a `Bool` here instead would throw away the difference between
/// "nothing changed on screen" and "the stream was interrupted", which are not
/// the same thing to recognition or to a bug report.
enum CaptureFrameStatus: String, Sendable, Equatable {
    case complete, idle, blank, suspended, started, stopped, unknown
}

/// What a capture source reports about one frame besides its pixels.
///
/// Everything but `status` is optional because not every source says it. The
/// geometry fields are for the session log only; recognition derives its
/// regions from the delivered buffer.
struct CaptureFrameMetadata: Sendable, Equatable {
    var status: CaptureFrameStatus = .unknown
    var displayTime: UInt64?
    var scaleFactor: Double?
    var contentScale: Double?
    var contentRect: CGRect?
    var screenRect: CGRect?
    /// EXIF-style orientation, 1 meaning upright; nil when the source is silent.
    var orientation: UInt32?
}

/// One callback's frame, as recognition receives it from any capture source.
///
/// Whether a pause in callbacks means frames were lost depends on how the
/// source behaves on a still screen, so the source decides `continuityBroken`
/// and recognition only acts on it.
struct CapturedFrame: @unchecked Sendable {
    // Unchecked for the sample buffer, which the source hands over and does
    // not touch again.
    let sampleBuffer: CMSampleBuffer
    let metadata: CaptureFrameMetadata
    /// When the callback ran, on the system uptime clock.
    let arrivalUptime: Double
    /// Time since the source's previous callback; nil for its first.
    let deliveryGapMilliseconds: Double?
    /// The source cannot vouch that nothing was lost since its previous callback.
    let continuityBroken: Bool
}

/// Tells a stalled stream from a still screen by how long callbacks stop.
///
/// Only valid for a source that keeps calling back while nothing changes, as
/// ScreenCaptureKit does with idle frames: for such a source, a long silence
/// means frames were lost. A source that goes quiet on a still screen needs a
/// different rule.
struct CallbackGapMonitor: Sendable {
    struct Arrival: Equatable {
        let gapMilliseconds: Double?
        let continuityBroken: Bool
    }

    let stallThreshold: Double
    private var lastArrival: Double?

    init(stallThreshold: Double = 1.0) {
        self.stallThreshold = stallThreshold
    }

    mutating func arrive(at uptime: Double) -> Arrival {
        defer { lastArrival = uptime }
        guard let lastArrival else { return Arrival(gapMilliseconds: nil, continuityBroken: false) }
        let gap = uptime - lastArrival
        return Arrival(gapMilliseconds: gap * 1000, continuityBroken: gap > stallThreshold)
    }
}
