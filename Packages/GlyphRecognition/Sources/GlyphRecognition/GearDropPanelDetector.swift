/// A cheap candidate, not a stage classifier. Coordinates scale with the
/// measured portrait layouts; the panel's bottom follows its row count.
public struct GearDropPanelDetector: Sendable {
    public init() {}

    /// The rows of a frame the detector samples, so a caller can decode only
    /// this band instead of the whole frame.
    public static func band(frameHeight: Int) -> Range<Int> {
        let height = Double(frameHeight)
        return Int(height * 0.275)..<min(frameHeight, Int(height * 0.62) + Int(height * 0.009) + 2)
    }

    public func candidate(in image: ColorImage) -> GearDropPanelBounds? {
        candidate(in: image, frameHeight: image.height, bandTop: 0)
    }

    /// `image` holds frame rows starting at `bandTop`, full frame width.
    public func candidate(in image: ColorImage, frameHeight: Int, bandTop: Int) -> GearDropPanelBounds? {
        let aspect = Double(frameHeight) / Double(image.width)
        guard (2.1...2.25).contains(aspect), image.width >= 280 else { return nil }
        let height = Double(frameHeight)
        func pixel(_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8)? {
            let row = y - bandTop
            guard row >= 0, row < image.height else { return nil }
            return image[x, row]
        }
        func lavender(_ x: Int, _ y: Int) -> Bool {
            guard let p = pixel(x, y) else { return false }
            let r = Int(p.red), g = Int(p.green), b = Int(p.blue)
            return r >= 65 && r < 220 && g >= 55 && abs(r - g) < 40 && b > r + 15
        }
        func border(_ y: Int, from left: Double = 0.055, to right: Double = 0.945) -> Bool {
            var hits = 0
            for sample in 0..<80 {
                let x = Int((left + Double(sample) * (right - left) / 79) * Double(image.width))
                if lavender(x, y) { hits += 1 }
            }
            return hits >= 74
        }
        func box(_ lines: [Int], sides needed: Int, sideColumns: [(Double, Double)],
                 from left: Double = 0.06, to right: Double = 0.94) -> GearDropPanelBounds? {
            guard let top = lines.first, Double(top) / height < 0.40,
                  let bottom = lines.first(where: { Double($0 - top) / height >= 0.075 }) else { return nil }
            // The title band's background must be dark across most of the box.
            var dark = 0
            let y = min(frameHeight - 1, top + Int(height * 0.009))
            for sample in 0..<40 {
                let x = Int((left + Double(sample) * (right - left) / 39) * Double(image.width))
                guard let p = pixel(x, y) else { continue }
                if p.red < 55 && p.green < 55 && p.blue < 85 { dark += 1 }
            }
            guard dark >= 34 else { return nil }
            var sides = 0
            // Item sparks can cross either horizontal stroke. A half-width
            // stroke needs independent support from BOTH vertical sides.
            // A full-width one needs one side at the panel's edge: the key
            // inventory's narrower cards stack, and a card's bottom border
            // above the next card's makes a box with no side there.
            // Test separate side segments so a spark crossing one segment
            // does not erase the rectangle. Each keeps the 74/80 rule.
            for (left, right) in sideColumns {
                let columns = Int(left * Double(image.width))...Int(right * Double(image.width))
                let side = columns.contains { x in
                    [0.1, 0.4, 0.7].contains { start in
                        var hits = 0
                        for sample in 0..<80 {
                            let y = top + Int((start + Double(sample) * 0.2 / 79) * Double(bottom - top))
                            if lavender(x, y) { hits += 1 }
                        }
                        return hits >= 74
                    }
                }
                if side { sides += 1 }
            }
            guard sides >= needed else { return nil }
            return GearDropPanelBounds(top: Double(top) / height, bottom: Double(bottom) / height)
        }
        let rows = Int(height * 0.275)..<Int(height * 0.62)
        // Measured panel sides sit at 0.030-0.032 and 0.968-0.970 of the
        // width; the key inventory's cards at 0.069-0.071 and 0.929. The
        // full-width side search also reaches outward to 0.015/0.985, so a
        // wider phone whose margin stays fixed in points keeps its panel,
        // while its inner edges stay where the spark path's are.
        if let bounds = box(rows.filter { border($0) }, sides: 1,
                            sideColumns: [(0.015, 0.042), (0.958, 0.985)]) { return bounds }
        for (left, right) in [(0.52, 0.945), (0.055, 0.48)] {
            if let bounds = box(rows.filter { border($0, from: left, to: right) }, sides: 2,
                                sideColumns: [(0.028, 0.042), (0.958, 0.972)],
                                from: left, to: right) { return bounds }
        }
        return nil
    }
}
