/// A packed, top-left-origin, 8-bit RGB image.
///
/// The shape recognizer works on luminance, but two pieces of game evidence are
/// colour: the selected slot indicator is gold among pale violet ones, and the
/// countdown has gold progress over a violet rail. Those distinctions do not
/// survive a conversion to grey, so those readers take this instead.
///
/// Only the regions that need colour are decoded, so the luminance path that
/// the recognition tests validate stays byte-for-byte unchanged.
public struct ColorImage: Sendable {
    public enum ValidationError: Error { case invalidDimensions, invalidPixelCount }

    public let width: Int
    public let height: Int
    /// Three bytes per pixel, red first, row-major with no padding.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !pixelCount.overflow else { throw ValidationError.invalidDimensions }
        let byteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 3)
        guard !byteCount.overflow, pixels.count == byteCount.partialValue else {
            throw ValidationError.invalidPixelCount
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let base = (y * width + x) * 3
        return (pixels[base], pixels[base + 1], pixels[base + 2])
    }
}

/// The top strip of a delivered frame, starting at its first row.
///
/// The game's header text, slot indicators and input countdown all sit in a
/// fixed fraction of the screen height, so a reader needs the height of the
/// whole frame to resolve `GameUILayout` fractions even though it is only given
/// the strip. Carrying the two together stops a caller from pairing a crop with
/// the wrong frame height.
public struct FrameTopBand: Sendable {
    public let image: ColorImage
    /// Height of the frame the strip was cut from, in the same pixels.
    public let frameHeight: Int

    public init(image: ColorImage, frameHeight: Int) {
        precondition(frameHeight >= image.height,
                     "A top band cannot be taller than the frame it came from")
        self.image = image
        self.frameHeight = frameHeight
    }

    /// Rows of the frame this strip actually contains, clamped to it.
    public func rows(_ top: Double, _ bottom: Double) -> Range<Int> {
        let first = max(0, Int((top * Double(frameHeight)).rounded(.down)))
        let last = min(image.height, Int((bottom * Double(frameHeight)).rounded(.up)))
        return first < last ? first..<last : 0..<0
    }
}
