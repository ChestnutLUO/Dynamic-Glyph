/// Finds the key card on a frame: the large dark rectangle a key's quantity
/// and portal name are shown on.
///
/// This is the port of CountIngressKeys' rectangle stage. The original
/// thresholds the frame at 110, flood-fills the dark regions (`not(bw)` in
/// regionprops), and crops the second-largest one: the screen background
/// around the card is the largest, and the card's dark interior — bounded by
/// its brighter border, photo and text — is the next one. Rather than
/// trusting that ordering blindly, this port walks the largest components in
/// size order and returns the first whose bounding box falls in one of the
/// two known aspect-ratio bands. A phone screenshot's background (about 2.2
/// tall over wide) is outside both, and a card's interior would have to be
/// beaten by three larger, in-band rectangles before it was missed.
///
/// The interior must stay connected at the threshold: bright photo or text
/// pixels that cut it in two defeat the flood fill, as they do in the
/// original. The bands are device-dependent — the original measured
/// 1.65-1.68 and 0.96-0.98 on an iPhone 6, 1.4-1.6 and 0.8-0.9 on a Moto G —
/// so they are policy, and the defaults here span both measurements.
public struct KeyCardDetector: Sendable {
    public struct Policy: Sendable {
        /// Pixels at or above this are bright; the flood fill runs on the rest.
        /// CountIngressKeys thresholds at 110.
        public var brightThreshold: UInt8 = 110
        /// Height/width of an Inventory key card. Measured 1.65-1.68 on an
        /// iPhone 6 and 1.4-1.6 on a Moto G 2nd Gen.
        public var inventoryAspectRatio: ClosedRange<Double> = 1.35...1.85
        /// Height/width of a Capsule or Key Locker key card. Measured 0.96-0.98
        /// on an iPhone 6 and 0.8-0.9 on a Moto G 2nd Gen.
        public var capsuleAspectRatio: ClosedRange<Double> = 0.75...1.05
        /// A card is at least this fraction of the frame's area, and at most
        /// this fraction: a component larger than the screen itself is the
        /// background, and a sliver is noise.
        public var cardAreaFraction: ClosedRange<Double> = 0.01...0.6
        /// Neither side of a card is smaller than this, in pixels.
        public var minimumCardSide = 48
        /// A frame with fewer dark regions than this carries no readable card.
        /// CountIngressKeys requires 50 before it reads a frame; a synthetic
        /// or heavily compressed frame can legitimately show fewer.
        public var minimumRegions = 8
        /// How many of the largest dark components are tried, in size order.
        public var candidateComponents = 4

        public init() {}
    }

    public let policy: Policy

    public init(policy: Policy = Policy()) { self.policy = policy }

    public func detect(in image: LuminanceImage) -> KeyCardBounds? {
        let components = darkComponents(in: image)
        guard components.count >= policy.minimumRegions else { return nil }
        let frameArea = Double(image.width * image.height)
        let largest = components
            .sorted { $0.area > $1.area }
            .prefix(policy.candidateComponents)
        for component in largest {
            let width = component.maxX - component.minX + 1
            let height = component.maxY - component.minY + 1
            guard width >= policy.minimumCardSide, height >= policy.minimumCardSide else { continue }
            let fraction = Double(width * height) / frameArea
            guard policy.cardAreaFraction.contains(fraction) else { continue }
            let ratio = Double(height) / Double(width)
            if policy.inventoryAspectRatio.contains(ratio) {
                return KeyCardBounds(x: component.minX, y: component.minY,
                                     width: width, height: height, kind: .inventory)
            }
            if policy.capsuleAspectRatio.contains(ratio) {
                return KeyCardBounds(x: component.minX, y: component.minY,
                                     width: width, height: height, kind: .capsule)
            }
        }
        return nil
    }

    private struct Component {
        let area: Int
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
    }

    /// Four-connected flood fill over the dark mask, collecting bounding
    /// boxes. The same shape of pass the node-array detector runs on bright
    /// pixels.
    private func darkComponents(in image: LuminanceImage) -> [Component] {
        let w = image.width, h = image.height
        var visited = [Bool](repeating: false, count: image.pixels.count)
        var stack: [Int] = []
        var components: [Component] = []
        for start in image.pixels.indices where image.pixels[start] < policy.brightThreshold && !visited[start] {
            stack.append(start)
            visited[start] = true
            var count = 0
            var minX = w, minY = h, maxX = 0, maxY = 0
            while let index = stack.popLast() {
                let x = index % w, y = index / w
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                // Neighbours in packed row-major order. The horizontal ones
                // are bounded by the row so a row's start and end never
                // connect through the index arithmetic.
                let left = x > 0 ? index - 1 : -1
                let right = x < w - 1 ? index + 1 : -1
                for neighbour in [left, right, index - w, index + w] {
                    guard neighbour >= 0, neighbour < image.pixels.count,
                          !visited[neighbour],
                          image.pixels[neighbour] < policy.brightThreshold else { continue }
                    visited[neighbour] = true
                    stack.append(neighbour)
                }
            }
            components.append(Component(area: count, minX: minX, minY: minY, maxX: maxX, maxY: maxY))
        }
        return components
    }
}
