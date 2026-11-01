import Dispatch

/// A live, provisional frame session. This caches geometry, not game phase:
/// none of its observations may be appended to a sequence without an external
/// presentation boundary. Timestamps must be monotonic seconds.
public struct GlyphFrameSession: Sendable {
    public private(set) var calibration: NodeArrayDetection?
    private let recognizer: GlyphFrameRecognizer
    private var previousTime: Double?
    /// When the fit last matched all 11 rings on an empty array. The fit is
    /// kept up to eight seconds after it, so it alone does not show that the
    /// array is still on screen.
    public private(set) var validatedAt: Double?
    private var lastFitAttempt = -Double.infinity
    /// How long the last `observe` spent hunting for the node array, or nil
    /// when it did not hunt. Measurement only, for the app's power readout.
    public private(set) var lastGridHuntNanoseconds: UInt64?

    public init(table: GlyphTable) { recognizer = GlyphFrameRecognizer(table: table) }

    public mutating func reset() {
        calibration = nil
        previousTime = nil
        validatedAt = nil
        lastFitAttempt = -.infinity
    }

    public mutating func observe(_ image: LuminanceImage, at time: Double) -> GlyphFrameObservation? {
        lastGridHuntNanoseconds = nil
        guard time.isFinite else { reset(); return nil }
        if let previousTime, time < previousTime || time - previousTime > 1 { reset() }
        previousTime = time
        if let fit = calibration,
           fit.imageWidth != image.width || fit.imageHeight != image.height { reset(); previousTime = time }
        // A cached fit is not evidence that the array is still on screen.
        // Periodically reacquire it on a clean empty array, and expire it when
        // no such validation has been possible for eight seconds.
        if let validatedAt, time - validatedAt > 8 { calibration = nil }
        var observation = calibration.map { recognizer.observe(image, calibration: $0) }
        if calibration == nil || (observation?.state == .noStroke && time - lastFitAttempt >= 0.5) {
            lastFitAttempt = time
            let huntStarted = DispatchTime.now().uptimeNanoseconds
            let detected = NodeArrayDetector().detect(in: image)
            lastGridHuntNanoseconds = DispatchTime.now().uptimeNanoseconds &- huntStarted
            if let fit = detected, fit.matchedNodes.count == 11 {
                let candidate = recognizer.observe(image, calibration: fit)
                if candidate.state == .noStroke {
                    calibration = fit
                    validatedAt = time
                    observation = candidate
                }
            }
        }
        return observation
    }
}
