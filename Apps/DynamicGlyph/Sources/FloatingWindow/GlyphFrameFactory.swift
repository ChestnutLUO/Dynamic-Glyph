import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import GlyphRecognition
import GlyphRecognitionImages

/// Turns a display snapshot into a sample buffer for the Picture in Picture
/// layer. Adapted from Spike A's diagnostic frame factory: the IOSurface-backed
/// pool, the cached format description and the display-immediately attachment
/// are the parts that had to be right for the layer to show anything at all.
final class GlyphFrameFactory {
    let canvas: PiPCanvasConfiguration
    let width: Int
    let height: Int

    private var pool: CVPixelBufferPool?
    private var formatDescription: CMFormatDescription?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let renderer: GlyphDisplayRenderer
    private let table: GlyphTable?
    /// One renderer per debug fill, made the first time that fill is drawn.
    /// Used on the render queue only, like the rest of the factory.
    private var tintedRenderers: [ReadingModeTint: GlyphDisplayRenderer] = [:]

    /// 4:1. The device gave Picture in Picture 189 x 106 points for a 16:9
    /// source, which rendered the old layout at 0.37 scale and made every word
    /// on it unreadable. A wide, short canvas asks for a strip instead, and
    /// carries only the diagrams.
    init(table: GlyphTable?, canvas: PiPCanvasConfiguration = .standard) {
        self.canvas = canvas
        self.width = canvas.pixelWidth
        self.height = canvas.pixelHeight
        self.table = table
        self.renderer = GlyphDisplayRenderer(table: table)
        makePool()
    }

    private func makePool() {
        // IOSurface backing is required for Picture in Picture; without it the
        // layer silently renders nothing.
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
        pool = created
    }

    /// Draws the snapshot into a fresh buffer. Returns nil if the pool is
    /// exhausted, which is a backpressure signal, not an error to paper over.
    /// `windowWidth` is the floating window's width in points, when iOS has
    /// reported one; it sets how round the status edge's inner corners are.
    /// `tint` is the Diagnostics debug fill; `.none` draws exactly as before.
    func makePixelBuffer(_ snapshot: GlyphDisplaySnapshot, atUptime now: Double,
                         windowWidth: Double?, tint: ReadingModeTint = .none) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(canvas.resolution), y: CGFloat(canvas.resolution))
        renderer(for: tint).draw(snapshot, in: context, size: CGSize(width: canvas.width, height: canvas.height),
                                 atUptime: now, windowCornerRadius: canvas.cornerRadius(windowWidth: windowWidth))
        return buffer
    }

    /// The renderer with `tint`'s fill as its background: the interior and
    /// the masks cut from it change, nothing else. `.none` is the renderer
    /// with the default palette, untouched.
    func renderer(for tint: ReadingModeTint) -> GlyphDisplayRenderer {
        guard let fill = tint.fill else { return renderer }
        if let cached = tintedRenderers[tint] { return cached }
        var palette = renderer.palette
        palette.background = fill
        let tinted = GlyphDisplayRenderer(table: table, palette: palette)
        tintedRenderers[tint] = tinted
        return tinted
    }

    /// Wraps an already drawn buffer with a fresh presentation time, so a model
    /// that has not changed can keep the layer fed without redrawing pixels.
    func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        // Dimensions and pixel format are fixed by the pool, so this is built
        // once; rebuilding it per frame is a measurable allocation source.
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: formatDescription, sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
