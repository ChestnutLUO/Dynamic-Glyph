import AVFoundation
import CoreMedia
import CoreVideo
import Testing
import UIKit
import GlyphRecognition

@MainActor
@Suite("PiP inline preview ownership")
struct PiPHostTests {
    private func visibleHost(in window: UIWindow, size: CGSize) -> SampleBufferHostView.LayerView {
        let host = SampleBufferHostView.LayerView(frame: CGRect(origin: .zero, size: size))
        window.addSubview(host)
        host.layoutIfNeeded()
        return host
    }

    @Test("Constructing an off-screen tab cannot steal or resize the visible layer")
    func offscreenConstruction() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let layer = AVSampleBufferDisplayLayer()
        let visible = visibleHost(in: window, size: CGSize(width: 360, height: 90))
        visible.attach(layer)
        #expect(layer.superlayer === visible.layer)
        let offscreen = SampleBufferHostView.LayerView(frame: .zero)
        offscreen.attach(layer)
        offscreen.layoutSubviews()
        #expect(layer.superlayer === visible.layer)
        #expect(layer.frame == visible.bounds)
    }

    @Test("Only the selected tab may own the layer even when UIKit retains both views")
    func tabSwitch() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let layer = AVSampleBufferDisplayLayer()
        let home = visibleHost(in: window, size: CGSize(width: 360, height: 90))
        let settings = visibleHost(in: window, size: CGSize(width: 320, height: 80))
        home.attach(layer, isActive: true)
        settings.attach(layer, isActive: false)
        settings.layoutSubviews()
        #expect(layer.superlayer === home.layer && layer.frame == home.bounds)
        // SwiftUI may activate the new tab before updating the old one.
        settings.attach(layer, isActive: true)
        home.attach(layer, isActive: false)
        home.bounds = .zero
        home.layoutSubviews()
        #expect(layer.superlayer === settings.layer && layer.frame == settings.bounds)
        home.removeFromSuperview()
        #expect(layer.superlayer === settings.layer)
        // And the reverse update order must also work on the way back.
        settings.attach(layer, isActive: false)
        home.frame = CGRect(x: 0, y: 0, width: 360, height: 90)
        window.addSubview(home)
        home.attach(layer, isActive: true)
        #expect(layer.superlayer === home.layer && layer.frame == home.bounds)
    }

    @Test("A selected host waits for attachment and nonempty layout, then releases on removal")
    func mountAndUnmount() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let layer = AVSampleBufferDisplayLayer()
        let host = SampleBufferHostView.LayerView(frame: .zero)
        host.attach(layer)
        window.addSubview(host)
        #expect(layer.superlayer == nil)
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 90)
        host.layoutSubviews()
        #expect(layer.superlayer === host.layer && layer.frame == host.bounds)
        host.removeFromSuperview()
        #expect(layer.superlayer == nil)
    }

    @Test("The initial waiting preview contains visible pixels and an immediately displayable frame")
    func initialFrame() throws {
        let factory = GlyphFrameFactory(table: nil)
        let snapshot = GlyphDisplaySnapshot.waiting(sessionID: CaptureSessionID(rawValue: 1), liveness: .live,
                                                    acceptance: .trackingSequence)
        let buffer = try #require(factory.makePixelBuffer(snapshot, atUptime: 1, windowWidth: nil))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var visible = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                if max(base[offset], max(base[offset + 1], base[offset + 2])) > 120 { visible += 1 }
            }
        }
        #expect(visible > 20)
        let sample = try #require(factory.makeSampleBuffer(from: buffer))
        #expect(CMSampleBufferIsValid(sample))
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]])
        #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true)
    }
}
