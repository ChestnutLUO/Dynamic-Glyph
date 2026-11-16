/// Public factories for the values the C++ engine's bridge
/// (`GlyphRecognitionCxx`) builds from the core's C structs. Inside this
/// module the memberwise initializers are internal; the bridge lives in
/// another module and must reproduce exactly what the Swift readers return,
/// including the ink pixels the stroke accumulator keeps. Factories rather
/// than public initializers, which would be ambiguous with the memberwise
/// ones within this module.
extension GlyphFrameObservation {
    public static func bridged(state: State, calibration: NodeArrayDetection?, evidence: [GlyphEdgeEvidence],
                               strokePixelCount: Int, unexplainedInkPixelCount: Int, candidates: [GlyphCandidate],
                               extensions: [GlyphID], inkPixels: [Int]) -> GlyphFrameObservation {
        GlyphFrameObservation(state: state, calibration: calibration, evidence: evidence,
                              strokePixelCount: strokePixelCount, unexplainedInkPixelCount: unexplainedInkPixelCount,
                              candidates: candidates, extensions: extensions, inkPixels: inkPixels)
    }
}

extension GlyphEdgeEvidence {
    public static func bridged(edge: GlyphPath.Edge, samples: [Double]) -> GlyphEdgeEvidence {
        GlyphEdgeEvidence(edge: edge, samples: samples)
    }
}

extension NodeArrayDetection {
    public static func bridged(imageWidth: Int, imageHeight: Int, origin: SIMD2<Double>, size: SIMD2<Double>,
                               nodeRadius: Double, matchedNodes: Set<NodeIndex>,
                               rootMeanSquareError: Double) -> NodeArrayDetection {
        NodeArrayDetection(imageWidth: imageWidth, imageHeight: imageHeight, origin: origin, size: size,
                           nodeRadius: nodeRadius, matchedNodes: matchedNodes,
                           rootMeanSquareError: rootMeanSquareError)
    }
}

extension LumaGateReading {
    public static func bridged(darkFraction: Double, brightFraction: Double, cells: [UInt8],
                               isCandidate: Bool) -> LumaGateReading {
        LumaGateReading(darkFraction: darkFraction, brightFraction: brightFraction, cells: cells,
                        isCandidate: isCandidate)
    }
}
