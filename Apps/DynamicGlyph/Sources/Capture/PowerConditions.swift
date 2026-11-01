import CoreVideo
import Foundation
import GlyphRecognition

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

extension LumaGate {
    /// The gate straight from a captured buffer's luma, without converting it.
    /// Nil for a format it doesn't know, which then never slows analysis down.
    func read(_ pixels: CVPixelBuffer) -> LumaGateReading? {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(pixels) >= 1,
                  let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
            return read(plane: base, width: CVPixelBufferGetWidthOfPlane(pixels, 0),
                        height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                        bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0),
                        videoRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
            return read(bgra: base, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))
        default:
            return nil
        }
    }
}
