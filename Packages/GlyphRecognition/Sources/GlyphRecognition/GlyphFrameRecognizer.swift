/// Spatial contrast samples along an elementary edge, excluding node rings.
/// Values describe support, not probabilities. Bins can be accumulated over time.
public struct GlyphEdgeEvidence: Sendable {
    public let edge: GlyphPath.Edge
    public let samples: [Double]
    public var coverage: Double {
        Double(samples.filter { $0 >= 0.18 }.count) / Double(samples.count)
    }
    public var isPresent: Bool { coverage >= 0.8 }
}

public struct GlyphFrameObservation: Sendable {
    public enum State: String, Sendable {
        case calibrationUnavailable, calibrationMismatch
        case noStroke, unrecognizedStroke, unexplainedInk, ambiguousShape, uniqueVisibleShape
    }
    public let state: State
    public let calibration: NodeArrayDetection?
    public let evidence: [GlyphEdgeEvidence]
    public let strokePixelCount: Int
    public let unexplainedInkPixelCount: Int
    /// Ordered by edge difference then name; these are not confidence scores.
    public let candidates: [GlyphCandidate]
    /// Templates that strictly contain the detected edges, independent of the
    /// nearest-match distance limit. Empty evidence does not propose extensions.
    public let extensions: [GlyphID]
    // Retained for spatial accounting when a fading trail is accumulated.
    let inkPixels: [Int]
    public var edges: Set<GlyphPath.Edge> { Set(evidence.filter(\.isPresent).map(\.edge)) }
    public var exactMatches: [GlyphID] { candidates.filter { $0.distance == 0 }.map(\.id) }
    /// A visible shape may still be the beginning of a longer Glyph. Only a
    /// presentation boundary can establish that the drawing is complete.
    public var hasUniqueVisibleShape: Bool { state == .uniqueVisibleShape }
}

/// Analyzes an upright frame. The caller owns game-phase and Glyph boundaries;
/// player-input strokes must never become observations of the presentation.
public struct GlyphFrameRecognizer: Sendable {
    private let templates: [(id: GlyphID, edges: Set<GlyphPath.Edge>)]
    public let maxEdgeDistance: Int

    public init(table: GlyphTable, maxEdgeDistance: Int = 2) {
        precondition(maxEdgeDistance >= 0)
        self.maxEdgeDistance = maxEdgeDistance
        templates = table.glyphs.compactMap { id in
            table.path(for: id).map { (id, GlyphGeometry.normalizedEdges($0.undirectedEdges)) }
        }
    }

    /// The exact normalized template used for pixel recognition. Player-input
    /// validation uses this same vocabulary without normalizing measured edges.
    public func expectedEdges(for glyph: GlyphID) -> Set<GlyphPath.Edge>? {
        templates.first { $0.id == glyph }?.edges
    }

    /// Bootstrap/diagnostic operation. Strokes often obscure enough rings to
    /// make this fail on a valid Glyph screen. Failure is NOT a screen-exit
    /// signal. Live recognition should use observe(_:calibration:) with a fit
    /// acquired on an empty array.
    public func calibrateAndObserve(_ image: LuminanceImage) -> GlyphFrameObservation {
        guard let fit = NodeArrayDetector().detect(in: image) else {
            return unavailable(.calibrationUnavailable)
        }
        return observe(image, calibration: fit)
    }

    private func unavailable(_ state: GlyphFrameObservation.State) -> GlyphFrameObservation {
        GlyphFrameObservation(state: state, calibration: nil, evidence: [], strokePixelCount: 0,
                              unexplainedInkPixelCount: 0, candidates: [], extensions: [], inkPixels: [])
    }

    /// The fit is required: a drawn-over array usually cannot be calibrated.
    /// Invalidate it after rotation, resizing, or a screen-layout change.
    public func observe(_ image: LuminanceImage,
                        calibration fit: NodeArrayDetection) -> GlyphFrameObservation {
        guard fit.imageWidth == image.width, fit.imageHeight == image.height else {
            return unavailable(.calibrationMismatch)
        }
        let positions = fit.positions
        let halfWidth = max(1, fit.size.x * 0.006)
        let evidence = GlyphGeometry.elementaryEdges.map { edge in
            let from = positions[edge.lower.rawValue], to = positions[edge.upper.rawValue]
            let delta = to - from
            let length = (delta * delta).sum().squareRoot()
            let direction = delta / length
            let normal = SIMD2(-direction.y, direction.x)
            let trim = min(length * 0.3, fit.nodeRadius * 1.9)
            let samples = (0..<24).map { index -> Double in
                let distance = trim + (length - 2 * trim) * (Double(index) + 0.5) / 24
                let point = from + direction * distance
                let center = [-1.0, 0, 1].map { image.sample(point + normal * ($0 * halfWidth)) }.max()!
                let offset = halfWidth * 4 + fit.nodeRadius * 0.2
                let background = (image.sample(point + normal * offset) + image.sample(point - normal * offset)) / 2
                guard center >= 60 else { return 0 }
                return min(1, max(0, (center - background) / 128))
            }
            return GlyphEdgeEvidence(edge: edge, samples: samples)
        }

        // Distinguish an empty array from ink that establishes no complete
        // lattice edge. Exclude the bright node rings and their glow, and the
        // corners of the bounding box outside the hexagon of outer nodes: no
        // stroke can be drawn there, but a floating button parked at the
        // screen edge (AssistiveTouch) reaches into them.
        var inkPixels: [Int] = []
        let maskRadiusSquared = fit.nodeRadius * fit.nodeRadius * 3.61
        let hull = Self.convexHull(positions)
        let glowMargin = max(2, fit.size.x * 0.015)
        let minX = max(0, Int(fit.origin.x)), maxX = min(image.width - 1, Int(fit.origin.x + fit.size.x))
        let minY = max(0, Int(fit.origin.y)), maxY = min(image.height - 1, Int(fit.origin.y + fit.size.y))
        for y in minY...maxY {
            for x in minX...maxX where image[x, y] >= 80 {
                let point = SIMD2(Double(x), Double(y))
                guard Self.isWithin(glowMargin, of: hull, point) else { continue }
                if !positions.contains(where: { p in
                    let d = point - p
                    return (d * d).sum() <= maskRadiusSquared
                }) { inkPixels.append(y * image.width + x) }
            }
        }
        return classify(evidence: evidence, calibration: fit, inkPixels: inkPixels)
    }

    func classify(evidence: [GlyphEdgeEvidence], calibration: NodeArrayDetection,
                  inkPixels: [Int]) -> GlyphFrameObservation {
        let edges = Set(evidence.filter(\.isPresent).map(\.edge))
        let candidates: [GlyphCandidate] = edges.isEmpty ? [] : templates.map {
            GlyphCandidate(id: $0.id, distance: edges.symmetricDifference($0.edges).count)
        }.filter { $0.distance <= maxEdgeDistance }.sorted()
        let exactCount = candidates.filter { $0.distance == 0 }.count
        let extensions = edges.isEmpty ? [] : templates.filter { edges.isStrictSubset(of: $0.edges) }.map(\.id)
        // Measure actual spatial support, not length * guessed stroke width:
        // overlaps, glow and different raster widths make area estimates weak.
        let positions = calibration.positions
        let segments = edges.map { (positions[$0.lower.rawValue], positions[$0.upper.rawValue]) }
        let inkRadius = max(2, calibration.size.x * 0.015)
        let unexplained = inkPixels.filter { index in
            let point = SIMD2(Double(index % calibration.imageWidth), Double(index / calibration.imageWidth))
            return !segments.contains { a, b in
                let delta = b - a
                let t = min(1, max(0, ((point - a) * delta).sum() / (delta * delta).sum()))
                let distance = point - (a + t * delta)
                return (distance * distance).sum() <= inkRadius * inkRadius
            }
        }.count
        let excessiveInk = unexplained > max(24, Int(Double(inkPixels.count) * 0.35))
        let state: GlyphFrameObservation.State
        if exactCount > 0 && excessiveInk { state = .unexplainedInk }
        else if exactCount == 1 { state = .uniqueVisibleShape }
        else if exactCount > 1 { state = .ambiguousShape }
        else if edges.isEmpty && inkPixels.count < max(6, Int(calibration.size.x * 0.025)) { state = .noStroke }
        else { state = .unrecognizedStroke }
        return GlyphFrameObservation(state: state, calibration: calibration, evidence: evidence,
                                     strokePixelCount: inkPixels.count, unexplainedInkPixelCount: unexplained,
                                     candidates: candidates, extensions: extensions, inkPixels: inkPixels)
    }

    /// By monotone chain, ordered so the interior lies on the non-negative
    /// side of every edge's cross product.
    static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Inside the convex polygon, or no further than `margin` outside it.
    static func isWithin(_ margin: Double, of hull: [SIMD2<Double>], _ point: SIMD2<Double>) -> Bool {
        guard hull.count > 2 else { return true }
        var inside = true
        var nearest = Double.infinity
        for index in hull.indices {
            let a = hull[index], b = hull[(index + 1) % hull.count]
            let edge = b - a, offset = point - a
            if edge.x * offset.y - edge.y * offset.x < 0 { inside = false }
            let t = min(1, max(0, (offset * edge).sum() / (edge * edge).sum()))
            let distance = point - (a + t * edge)
            nearest = min(nearest, (distance * distance).sum())
        }
        return inside || nearest <= margin * margin
    }
}
