/// Evidence that ONE Glyph presentation ended. This must come from outside
/// shape matching (e.g. a verified presentation-slot transition), never from
/// an exact edge match or a timeout alone. Game-phase detection is not built.
public enum GlyphCompletion: Sendable {
    case unconfirmed
    case presentationBoundary
}

public struct GlyphFrameSummary: Sendable {
    public let state: GlyphFrameObservation.State
    public let edges: Set<GlyphPath.Edge>
    public let exactMatches: [GlyphID]
    public let extensions: [GlyphID]
}

public struct GlyphStrokeResult: Sendable {
    public let observation: GlyphFrameObservation
    public let frames: [GlyphFrameSummary]
    public let completion: GlyphCompletion
    /// Two frames exactly matched shapes whose edges are not nested. This can
    /// be a missed boundary OR a legitimate fading trail; conservatively defer.
    public let possibleBoundaryCrossing: Bool
    public var frameCount: Int { frames.count }

    /// Sequence-ready only under the caller's explicit boundary assertion.
    /// Provenance can flag some missed boundaries but cannot prove their absence.
    public var acceptedGlyph: GlyphID? {
        guard completion == .presentationBoundary, !possibleBoundaryCrossing,
              observation.hasUniqueVisibleShape else { return nil }
        return observation.exactMatches.first
    }
}

/// Accumulates ONE presentation with a fixed calibration and vocabulary.
/// Sampling is performed here so tiny independent fit differences cannot mix
/// spatial bins. Start a new accumulator if the layout or orientation changes.
public struct GlyphStrokeAccumulator: Sendable {
    public enum AccumulationError: Error { case imageSizeChanged, frameLimitExceeded }
    public let calibration: NodeArrayDetection
    public let maximumFrames: Int
    private let recognizer: GlyphFrameRecognizer
    private var evidence: [GlyphEdgeEvidence] = []
    private var inkPixels: Set<Int> = []
    private var frames: [GlyphFrameSummary] = []
    private var possibleBoundaryCrossing = false

    public init(calibration: NodeArrayDetection, recognizer: GlyphFrameRecognizer, maximumFrames: Int = 300) {
        precondition(maximumFrames > 0)
        self.calibration = calibration
        self.recognizer = recognizer
        self.maximumFrames = maximumFrames
    }

    /// A rejected frame invalidates the accumulated drawing. Callers must not
    /// finish an old partial result after silently losing part of the capture.
    @discardableResult
    public mutating func append(_ image: LuminanceImage) throws -> GlyphFrameObservation {
        guard image.width == calibration.imageWidth, image.height == calibration.imageHeight else {
            reset()
            throw AccumulationError.imageSizeChanged
        }
        guard frames.count < maximumFrames else {
            reset()
            throw AccumulationError.frameLimitExceeded
        }
        let observation = recognizer.observe(image, calibration: calibration)
        let edges = observation.edges
        if observation.hasUniqueVisibleShape && frames.contains(where: {
            $0.state == .uniqueVisibleShape && !$0.edges.isSubset(of: edges) && !edges.isSubset(of: $0.edges)
        }) { possibleBoundaryCrossing = true }
        if evidence.isEmpty { evidence = observation.evidence }
        else {
            evidence = zip(evidence, observation.evidence).map { old, new in
                GlyphEdgeEvidence(edge: old.edge, samples: zip(old.samples, new.samples).map { max($0, $1) })
            }
        }
        inkPixels.formUnion(observation.inkPixels)
        frames.append(GlyphFrameSummary(state: observation.state, edges: edges,
                                       exactMatches: observation.exactMatches, extensions: observation.extensions))
        return observation
    }

    /// Consumes the drawing. Default output is provisional, even if the union
    /// exactly matches a template with no possible extensions.
    public mutating func finish(completion: GlyphCompletion = .unconfirmed) -> GlyphStrokeResult? {
        defer { reset() }
        guard !frames.isEmpty else { return nil }
        return GlyphStrokeResult(
            observation: recognizer.classify(evidence: evidence, calibration: calibration, inkPixels: Array(inkPixels)),
            frames: frames, completion: completion, possibleBoundaryCrossing: possibleBoundaryCrossing)
    }

    public mutating func reset() {
        evidence = []
        inkPixels = []
        frames = []
        possibleBoundaryCrossing = false
    }
}
