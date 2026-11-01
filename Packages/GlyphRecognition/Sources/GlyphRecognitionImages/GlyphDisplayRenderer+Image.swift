import CoreGraphics
import GlyphRecognition

extension GlyphDisplayRenderer {
    /// The floating window's frame as an image, drawn exactly as the Picture in
    /// Picture frame factory draws it: `canvas.pixelWidth` x `pixelHeight`,
    /// with the layout in canvas units scaled by the resolution. Lets setup
    /// preview a canvas without the one layer Picture in Picture opens from.
    public func image(_ snapshot: GlyphDisplaySnapshot, canvas: PiPCanvasConfiguration,
                      atUptime now: Double, windowWidth: Double?) -> CGImage? {
        guard let context = CGContext(data: nil, width: canvas.pixelWidth, height: canvas.pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(canvas.resolution), y: CGFloat(canvas.resolution))
        draw(snapshot, in: context, size: CGSize(width: canvas.width, height: canvas.height),
             atUptime: now, windowCornerRadius: canvas.cornerRadius(windowWidth: windowWidth))
        return context.makeImage()
    }
}
