/// Cheap portrait-layout gate for OCR. Only the result reader's two labels can
/// confirm a panel; these border samples never establish a game outcome.
public struct ResultPanelDetector: Sendable {
    public init() {}

    public func isCandidate(_ image: LuminanceImage) -> Bool {
        let aspect = Double(image.height) / Double(image.width)
        guard (2.1...2.25).contains(aspect), image.width >= 280 else { return false }
        func bright(_ x: Double, _ y: Double) -> Bool {
            let px = Int(x * Double(image.width)), py = Int(y * Double(image.height))
            let radius = max(1, image.width / 180)
            return (-radius...radius).contains { dx in
                let xx = min(image.width - 1, max(0, px + dx))
                return image[xx, min(image.height - 1, max(0, py))] > 65
            }
        }
        // Two tall sides, away from the labels, value flashes, and timer.
        let left = (0..<20).filter { bright(0.086, 0.34 + Double($0) * 0.012) }.count
        let right = (0..<20).filter { bright(0.920, 0.34 + Double($0) * 0.012) }.count
        return left >= 16 && right >= 16
    }
}
