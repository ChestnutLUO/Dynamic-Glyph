/// A packed, top-left-origin, 8-bit luminance image. Platform image decoding
/// belongs in an adapter; the recognition core only needs these pixels.
public struct LuminanceImage: Sendable {
    public enum ValidationError: Error { case invalidDimensions, invalidPixelCount }

    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        let count = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !count.overflow else {
            throw ValidationError.invalidDimensions
        }
        guard pixels.count == count.partialValue else { throw ValidationError.invalidPixelCount }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// Nearest-pixel sampling; out-of-frame points have no evidence.
    func sample(_ point: SIMD2<Double>) -> Double {
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return Double(self[x, y])
    }
}
