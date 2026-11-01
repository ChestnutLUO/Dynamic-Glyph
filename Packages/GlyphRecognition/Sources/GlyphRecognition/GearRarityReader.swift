/// Reads the three slanted rarity bars, not the item's icon or OCR punctuation.
/// Input is a small meter crop: 7.4% of frame width by 2.6% of frame height,
/// starting at x=12.3% (+46.5% for the right column), centred on the item row.
public struct GearRarityReader: Sendable {
    private enum Ink: Equatable { case common, rare, veryRare, inactive, background, unknown }
    public init() {}

    public func read(_ image: ColorImage) -> GearDropEntry.Rarity? {
        guard image.width >= 16, image.height >= 12 else { return nil }
        let centers = [0.216, 0.459, 0.702]
        var readings: Set<GearDropEntry.Rarity> = []
        // Small shifts allow rounded crop coordinates, different resolutions,
        // and the row pitch quantization used by the text parser.
        for dx in -4...4 {
            for dy in -3...3 {
                func sample(_ x: Double, _ y: Double) -> Ink {
                    let px = Int((x + Double(dx) * 0.02) * Double(image.width)
                        + (0.5 - y) * Double(image.height) * 0.35)
                    let py = Int((y + Double(dy) * 0.05) * Double(image.height))
                    guard px >= 0, px < image.width, py >= 0, py < image.height else { return .unknown }
                    return ink(image[px, py])
                }
                let labels: [Ink?] = centers.map { center in
                    let samples = [-0.16, -0.08, 0, 0.08, 0.16].flatMap { y in
                        [-0.02, 0, 0.02].map { x in sample(center + x, 0.5 + y) }
                    }
                    return [Ink.common, .rare, .veryRare, .inactive].first { label in
                        samples.filter { $0 == label }.count >= 11
                    }
                }
                // Three lit areas in one large coloured object are not bars.
                let separated = [0.3375, 0.5805].allSatisfy { x in
                    [-0.12, -0.06, 0, 0.06, 0.12].filter { sample(x, 0.5 + $0) == .background }.count >= 3
                }
                guard separated else { continue }
                if labels == [.common, .inactive, .inactive] { readings.insert(.common) }
                else if labels == [.rare, .rare, .inactive] { readings.insert(.rare) }
                else if labels == [.veryRare, .veryRare, .veryRare] { readings.insert(.veryRare) }
            }
        }
        return readings.count == 1 ? readings.first : nil
    }

    private func ink(_ pixel: (red: UInt8, green: UInt8, blue: UInt8)) -> Ink {
        let r = Double(pixel.red), g = Double(pixel.green), b = Double(pixel.blue)
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        if high < 45 { return .background }
        if delta < 22, high < 160 { return .inactive }
        guard high >= 75, delta / high >= 0.25 else { return .unknown }
        var hue: Double
        if high == r { hue = 60 * (g - b) / delta }
        else if high == g { hue = 120 + 60 * (b - r) / delta }
        else { hue = 240 + 60 * (r - g) / delta }
        if hue < 0 { hue += 360 }
        switch hue {
        case 135...180: return .common
        case 245...285: return .rare
        case 300...340: return .veryRare
        default: return .unknown
        }
    }
}
