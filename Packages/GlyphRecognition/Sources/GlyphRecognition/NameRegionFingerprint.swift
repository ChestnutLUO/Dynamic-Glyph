/// A small grayscale digest of a key card's portal-name strip.
///
/// CountIngressKeys decides whether two frames show the same card by the
/// cross-correlation of their name strips (`corr2`), skipping OCR when the
/// coefficient is 0.75 or more. This port averages the strip down to a fixed
/// size, mean-centres it and normalizes its length, so the correlation of
/// two fingerprints is their Pearson coefficient — `corr2` of the pooled
/// strips. The pooling also absorbs the few pixels of scroll drift between
/// adjacent frames.
public struct NameRegionFingerprint: Sendable, Equatable {
    /// The digest is size x size values.
    public let size: Int
    /// Mean-centred, unit length, row-major.
    public let values: [Double]

    /// A frame where every pooled cell is equal (a blank strip) centres to
    /// zero and correlates with nothing, including itself: two unread strips
    /// are never called the same card.
    public init(image: LuminanceImage, size: Int = 32) {
        precondition(size > 1, "A fingerprint needs more than one cell per side")
        self.size = size
        var pooled = [Double](repeating: 0, count: size * size)
        for row in 0..<size {
            let y0 = row * image.height / size
            let y1 = max(y0 + 1, (row + 1) * image.height / size)
            for column in 0..<size {
                let x0 = column * image.width / size
                let x1 = max(x0 + 1, (column + 1) * image.width / size)
                var sum = 0.0
                for y in y0..<y1 {
                    let base = y * image.width
                    for x in x0..<x1 { sum += Double(image.pixels[base + x]) }
                }
                pooled[row * size + column] = sum / Double((x1 - x0) * (y1 - y0))
            }
        }
        let mean = pooled.reduce(0, +) / Double(pooled.count)
        var centred = pooled.map { $0 - mean }
        let norm = centred.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 1e-9 {
            for index in centred.indices { centred[index] /= norm }
        } else {
            centred = [Double](repeating: 0, count: pooled.count)
        }
        values = centred
    }

    /// The Pearson correlation of the two strips, in -1...1. A flat strip
    /// correlates with nothing.
    public func correlation(with other: NameRegionFingerprint) -> Double {
        guard other.size == size, values.count == other.values.count else { return 0 }
        let dot = zip(values, other.values).reduce(0) { $0 + $1.0 * $1.1 }
        return min(1, max(-1, dot))
    }
}
