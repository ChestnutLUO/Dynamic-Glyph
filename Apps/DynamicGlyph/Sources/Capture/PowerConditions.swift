import CoreVideo
import Foundation
import GlyphRecognition
import GlyphRecognitionImages

/// Low Power Mode and the device's thermal state, read where recognition
/// decides how much work a frame gets.
///
/// Either one constrains recognition: Low Power Mode, or a thermal state of
/// serious or critical. Constrained, analysis and text reading outside a hack
/// run at half rate and gear reads skip their retries; everything returns as
/// soon as the condition clears. Notifications arrive on arbitrary threads, so
/// the state is read under a lock.
final class PowerConditions: @unchecked Sendable {
    struct State: Equatable, Sendable {
        var lowPowerMode = false
        var thermalState: ProcessInfo.ThermalState = .nominal

        var isConstrained: Bool { lowPowerMode || thermalState == .serious || thermalState == .critical }

        /// What slows recognition now, for Diagnostics and the session log,
        /// untranslated: "no", "Low Power Mode", "warm (serious)", "warm
        /// (critical)", or Low Power Mode and heat together, such as "Low
        /// Power Mode, warm (serious)". "no" exactly when not constrained.
        var slowdown: String {
            var causes: [String] = []
            if lowPowerMode { causes.append("Low Power Mode") }
            switch thermalState {
            case .serious: causes.append("warm (serious)")
            case .critical: causes.append("warm (critical)")
            default: break
            }
            return causes.isEmpty ? "no" : causes.joined(separator: ", ")
        }

        /// For the session's debug logs: the two triggers apart.
        var logRow: [String: Any] {
            let thermal: String
            switch thermalState {
            case .nominal: thermal = "nominal"
            case .fair: thermal = "fair"
            case .serious: thermal = "serious"
            case .critical: thermal = "critical"
            @unknown default: thermal = "unknown"
            }
            return ["lowPowerMode": lowPowerMode, "thermalState": thermal]
        }

        static func current() -> State {
            State(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                  thermalState: ProcessInfo.processInfo.thermalState)
        }
    }

    /// Shared by every capture session; it only ever observes.
    static let shared = PowerConditions()

    private let lock = NSLock()
    private var state: State
    private let read: @Sendable () -> State
    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter

    init(center: NotificationCenter = .default, read: @escaping @Sendable () -> State = { State.current() }) {
        self.center = center
        self.read = read
        state = read()
        let names: [Notification.Name] = [.NSProcessInfoPowerStateDidChange,
                                          ProcessInfo.thermalStateDidChangeNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refresh() }
        }
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    var current: State { lock.withLock { state } }
    var isConstrained: Bool { current.isConstrained }

    func refresh() {
        let fresh = read()
        lock.withLock { state = fresh }
    }
}

extension FramePlanes {
    /// Locks `pixels` for reading around `body`, which gets the buffer's
    /// planes as an engine reads them: both biplanar 4:2:0 variants and
    /// BGRA. Nil for any other format, or when the buffer can't be locked;
    /// the engine then falls back to the rendered image, or the gate stays
    /// silent and never slows analysis down. The planes are valid only
    /// inside `body`.
    static func withLocked<Result>(_ pixels: CVPixelBuffer,
                                   _ body: (FramePlanes?) throws -> Result) rethrows -> Result {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return try body(nil) }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        return try body(locked(pixels))
    }

    /// The planes of a buffer the caller has locked; see `withLocked`.
    private static func locked(_ pixels: CVPixelBuffer) -> FramePlanes? {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(pixels) >= 1,
                  let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
            // The gate needs only luma; a buffer without its chroma plane
            // still gets that much.
            let chroma = CVPixelBufferGetPlaneCount(pixels) >= 2 ? CVPixelBufferGetBaseAddressOfPlane(pixels, 1) : nil
            return FramePlanes(format: .nv12(videoRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                               width: CVPixelBufferGetWidthOfPlane(pixels, 0),
                               height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                               base: UnsafeRawPointer(luma), bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0),
                               chroma: chroma.map(UnsafeRawPointer.init),
                               chromaBytesPerRow: chroma == nil ? 0 : CVPixelBufferGetBytesPerRowOfPlane(pixels, 1))
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
            return FramePlanes(format: .bgra, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                               base: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))
        default:
            return nil
        }
    }
}

extension LumaGate {
    /// The gate straight from a captured buffer's luma, without converting it.
    /// Nil for a format it doesn't know. Live capture reads the gate through
    /// its engine; this is the same reading on the Swift arm, for tests and
    /// tools that have only the buffer.
    func read(_ pixels: CVPixelBuffer) -> LumaGateReading? {
        FramePlanes.withLocked(pixels) { planes in
            planes.flatMap { SwiftFrameRecognitionEngine(table: nil).gate($0, step: step) }
        }
    }
}
