/// Reads the colour of an item's "x2" quantity. The game prints an ordinary
/// quantity in white and a multiplied one, such as the first hack of the
/// day's, in red. Input is the OCR box of the quantity text alone: level
/// colours sit beside it, and L4 and L5 are red and pink themselves.
public struct GearQuantityColorReader: Sendable {
    public init() {}

    /// True for red, false for white, nil when the text is too faint or its
    /// pixels are not almost all one of the two, as when the box also takes
    /// in a level or a sparkle crosses it.
    public func read(_ image: ColorImage) -> Bool? {
        var ink = 0, red = 0, white = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = image[x, y]
                let r = Double(pixel.red), g = Double(pixel.green), b = Double(pixel.blue)
                let high = max(r, g, b), low = min(r, g, b)
                // The panel's background is a dark navy; text is brighter.
                guard high >= 90 else { continue }
                ink += 1
                let saturation = (high - low) / high
                if saturation < 0.3 { white += 1; continue }
                guard high == r, saturation >= 0.5 else { continue }
                // Hue within 20° either side of pure red.
                let hue = 60 * (g - b) / (high - low)
                if abs(hue) <= 20 { red += 1 }
            }
        }
        guard ink >= 20 else { return nil }
        if Double(red) >= 0.85 * Double(ink) { return true }
        if Double(white) >= 0.85 * Double(ink) { return false }
        return nil
    }
}
