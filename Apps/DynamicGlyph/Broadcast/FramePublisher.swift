import CoreMedia
import CoreVideo
import Foundation
import ReplayKit
import VideoToolbox

/// Scales each broadcast frame to the width recognition was measured at, in
/// full-range 4:2:0, and publishes it into the ring for the app. Recognition
/// happens in the app, not here.
// Sendability: the writer and the scaler are only touched under `lock`.
final class FramePublisher: @unchecked Sendable {
    private let lock = NSLock()
    private let ring: FrameRingMapping
    private let writer: FrameRingWriter
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int)?
    private var lastPresentation = -Double.infinity
    private var timer: DispatchSourceTimer?
    private var stopReported = false
    private var stopObserver: DarwinObserver?

    /// `onStopRequested` runs once, when the app asks this broadcast to end.
    init(onStopRequested: @escaping @Sendable () -> Void) throws {
        guard let url = BroadcastChannel.ringURL else { throw CocoaError(.fileNoSuchFile) }
        ring = try FrameRingMapping.create(at: url, layout: BroadcastChannel.layout)
        writer = FrameRingWriter(ring: ring)
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        transfer = session
        writer.begin()

        let check: @Sendable () -> Void = { [weak self] in
            guard let self, self.lock.withLock({ () -> Bool in
                guard !self.stopReported, self.writer.isStopRequested else { return false }
                self.stopReported = true
                // Ending the broadcast may terminate this process before
                // broadcastFinished, so the app hears it from the ring first.
                self.writer.end(.finished, reason: .stopRequested)
                return true
            }) else { return }
            onStopRequested()
        }
        stopObserver = DarwinObserver(BroadcastChannel.stopRequested, handler: check)
        // The heartbeat is independent of frames, so a still screen that
        // delivers none is not mistaken for a dead extension.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.lock.withLock {
                self?.writer.heartbeat()
                if let peak = Self.peakFootprint() { self?.writer.report(peakFootprint: peak) }
            }
            check()
        }
        timer.resume()
        self.timer = timer
    }

    func offer(_ sampleBuffer: CMSampleBuffer) {
        let arrival = FrameRingClock.uptimeNanoseconds()
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard presentation.isFinite, let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                           attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 0
        let published = lock.withLock { () -> Bool in
            // 20 Hz, as LiveGlyphOutput samples; dropped before any copying.
            guard presentation < lastPresentation || presentation - lastPresentation >= 0.049 else { return false }
            guard let scaled = scale(source) else { return false }
            lastPresentation = presentation
            return writer.publish(scaled, presentationTime: presentation, orientation: orientation,
                                  arrivalUptime: arrival) != .notRunning
        }
        if published { BroadcastChannel.post(BroadcastChannel.framesPublished) }
    }

    func pause() { lock.withLock { writer.end(.paused) } }

    func resume() { lock.withLock { writer.end(.running) } }

    func finish() {
        timer?.cancel()
        timer = nil
        stopObserver = nil
        lock.withLock {
            if let peak = Self.peakFootprint() { writer.report(peakFootprint: peak) }
            // After a stop the app asked for, keep that as the reason.
            if !stopReported { writer.end(.finished, reason: .broadcastFinished) }
        }
    }

    /// The kernel's own high-water mark, so a spike between heartbeats counts.
    private static func peakFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, info.ledger_phys_footprint_peak > 0 else { return nil }
        return UInt64(info.ledger_phys_footprint_peak)
    }

    /// Under `lock`.
    private func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let size = BroadcastChannel.scaledSize(width: CVPixelBufferGetWidth(source),
                                               height: CVPixelBufferGetHeight(source))
        guard size.width > 0, size.height > 0, let transfer else { return nil }
        if poolSize.map({ $0 != size }) ?? true {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = size
        }
        var scaled: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaled) == kCVReturnSuccess,
              let scaled, VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr
        else { return nil }
        return scaled
    }
}
