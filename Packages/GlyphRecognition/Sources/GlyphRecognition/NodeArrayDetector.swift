/// An axis-aligned fit to the eleven node rings, in source-image pixels.
public struct NodeArrayDetection: Sendable, Equatable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let origin: SIMD2<Double>
    public let size: SIMD2<Double>
    public let nodeRadius: Double
    public let matchedNodes: Set<NodeIndex>
    public let rootMeanSquareError: Double

    public var positions: [SIMD2<Double>] {
        NodeArray.canonical.fitted(to: (origin, size))
    }
}

/// Finds bright annular components, then requires agreement with the entire
/// lattice. UI circles and letters alone must not count as an array.
///
/// The initial fit needs visible apex/base rings and at least eight rings in
/// total. Calibrate on the empty presentation screen, and reuse that fit while
/// strokes obscure rings. Rotation and perspective are not supported.
public struct NodeArrayDetector: Sendable {
    public init() {}

    public func detect(in image: LuminanceImage) -> NodeArrayDetection? {
        let rings = components(in: image)
        guard rings.count >= 8, rings.count <= 128 else { return nil }
        let canonical = NodeArray.canonical.positions
        var best: NodeArrayDetection?

        for top in rings {
            for bottom in rings {
                let height = bottom.center.y - top.center.y
                guard height >= Double(min(image.width, image.height)) * 0.35,
                      abs(top.center.x - bottom.center.x) < height * 0.015 else { continue }
                let centerX = (top.center.x + bottom.center.x) / 2
                for side in rings {
                    let relativeY = (side.center.y - top.center.y) / height
                    guard min(abs(relativeY - 0.25), abs(relativeY - 0.75)) < 0.015 else { continue }
                    let width = 2 * abs(side.center.x - centerX)
                    guard width / height >= 0.65, width / height <= 1.05 else { continue }
                    var origin = SIMD2(centerX - width / 2, top.center.y)
                    var size = SIMD2(width, height)
                    let tolerance = max(2, height * 0.012)
                    var matches = match(rings, origin: origin, size: size, tolerance: tolerance)
                    guard matches.count >= 8 else { continue }

                    // Least squares removes centroid noise from the three anchors.
                    for axis in 0...1 {
                        let xs = matches.map { canonical[$0.node][axis] }
                        let ys = matches.map { rings[$0.ring].center[axis] }
                        let mx = xs.reduce(0, +) / Double(xs.count)
                        let my = ys.reduce(0, +) / Double(ys.count)
                        let variance = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
                        let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
                        size[axis] = covariance / variance
                        origin[axis] = my - size[axis] * mx
                    }
                    matches = match(rings, origin: origin, size: size, tolerance: tolerance)
                    guard matches.count >= 8, origin.x >= 0, origin.y >= 0,
                          origin.x + size.x < Double(image.width),
                          origin.y + size.y < Double(image.height) else { continue }
                    let error = (matches.reduce(0.0) { result, m in
                        let delta = rings[m.ring].center - (origin + canonical[m.node] * size)
                        return result + (delta * delta).sum()
                    } / Double(matches.count)).squareRoot()
                    let radii = matches.map { rings[$0.ring].radius }.sorted()
                    let fit = NodeArrayDetection(
                        imageWidth: image.width, imageHeight: image.height,
                        origin: origin, size: size, nodeRadius: radii[radii.count / 2],
                        matchedNodes: Set(matches.map { NodeIndex(rawValue: $0.node)! }),
                        rootMeanSquareError: error)
                    if best == nil || fit.matchedNodes.count > best!.matchedNodes.count ||
                        (fit.matchedNodes.count == best!.matchedNodes.count && error < best!.rootMeanSquareError) {
                        best = fit
                    }
                }
            }
        }
        return best
    }

    private struct Ring {
        let center: SIMD2<Double>
        let radius: Double
    }

    private func match(_ rings: [Ring], origin: SIMD2<Double>, size: SIMD2<Double>,
                       tolerance: Double) -> [(node: Int, ring: Int)] {
        var used: Set<Int> = []
        var matches: [(node: Int, ring: Int)] = []
        for (node, p) in NodeArray.canonical.positions.enumerated() {
            let target = origin + p * size
            var nearest: Int?
            var distance = tolerance * tolerance
            for (index, ring) in rings.enumerated() where !used.contains(index) {
                let delta = ring.center - target
                let squared = (delta * delta).sum()
                if squared < distance { distance = squared; nearest = index }
            }
            if let nearest { used.insert(nearest); matches.append((node, nearest)) }
        }
        return matches
    }

    private func components(in image: LuminanceImage) -> [Ring] {
        let w = image.width, h = image.height
        let scale = Double(min(w, h))
        var visited = [Bool](repeating: false, count: image.pixels.count)
        var stack: [Int] = []
        var rings: [Ring] = []
        for start in image.pixels.indices where image.pixels[start] >= 160 && !visited[start] {
            stack.append(start)
            visited[start] = true
            var count = 0, sx = 0.0, sy = 0.0
            var minX = w, minY = h, maxX = 0, maxY = 0
            while let index = stack.popLast() {
                let x = index % w, y = index / w
                count += 1; sx += Double(x); sy += Double(y)
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) {
                        let next = ny * w + nx
                        if !visited[next] && image.pixels[next] >= 160 {
                            visited[next] = true; stack.append(next)
                        }
                    }
                }
            }
            let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
            let diameter = (bw + bh) / 2
            let fill = Double(count) / (bw * bh)
            guard diameter >= max(5, scale * 0.015), diameter <= scale * 0.07,
                  bw / bh >= 0.75, bw / bh <= 1.33, fill >= 0.15, fill <= 0.65 else { continue }
            let center = SIMD2(sx / Double(count), sy / Double(count))
            guard image.sample(center) < 160 else { continue } // a ring has a hole
            rings.append(Ring(center: center, radius: diameter / 2))
        }
        return rings
    }
}
