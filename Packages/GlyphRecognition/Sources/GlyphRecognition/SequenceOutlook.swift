/// What can and cannot be said about the rest of the sequence.
///
/// A single explicit state, because the underlying `Prediction` answers the
/// question with an empty array in three different situations — finished,
/// ambiguous and contradicted — and a renderer that reads emptiness as an
/// answer will show a confident blank for a Glyph it failed to recognize.
public enum PredictionState: String, Sendable, Equatable {
    /// No sequence table is loaded. Recognition still works.
    case unavailable
    /// Nothing has been confirmed yet, so every sequence is still possible.
    case unobserved
    /// Several sequences remain consistent.
    case ambiguous
    /// Exactly one remains — conditional on the observation being right and the
    /// table being complete, which is not the same as being certain.
    case resolved
    /// The observed prefix appears in no sequence: a Glyph was misread, a
    /// boundary was misjudged, or the table is missing a row.
    case contradicted
    /// The independently counted slots disagree with the observations or
    /// exclude every sequence consistent with them.
    case lengthConflict
}

/// The predictor's answer, packaged for display.
public struct SequenceOutlook: Sendable, Equatable {
    public let state: PredictionState
    /// The contiguous confirmed prefix this was computed from.
    public let observed: [GlyphID]
    /// The independently detected slot count, when there is one.
    public let expectedLength: Int?
    /// How many sequences remain consistent, after any length filtering.
    public let candidateCount: Int
    /// A bounded, stably ordered sample for display. Ordering is not a ranking.
    public let candidates: [SequenceCandidate]
    /// The Glyphs still to come. Populated only when `state == .resolved`.
    public let predictedSuffix: [GlyphID]
    /// For each position after the observations, the distinct Glyphs the
    /// remaining candidates put there. One entry means every candidate agrees.
    public let suffixAlternatives: [[GlyphID]]
    /// The observation is itself a complete sequence in the table. It can be
    /// true while longer continuations also remain.
    public let observationMayBeComplete: Bool

    public static let unavailable = SequenceOutlook(
        state: .unavailable, observed: [], expectedLength: nil, candidateCount: 0,
        candidates: [], predictedSuffix: [], suffixAlternatives: [], observationMayBeComplete: false)

    public init(state: PredictionState, observed: [GlyphID], expectedLength: Int?,
                candidateCount: Int, candidates: [SequenceCandidate], predictedSuffix: [GlyphID],
                suffixAlternatives: [[GlyphID]], observationMayBeComplete: Bool) {
        self.state = state
        self.observed = observed
        self.expectedLength = expectedLength
        self.candidateCount = candidateCount
        self.candidates = candidates
        self.predictedSuffix = predictedSuffix
        self.suffixAlternatives = suffixAlternatives
        self.observationMayBeComplete = observationMayBeComplete
    }
}

extension SequencePredictor {
    /// Prediction that can also use an independently counted slot count.
    ///
    /// `predict(observed:)` is left exactly as it was; this filters its result.
    /// Length is genuinely new information — the field capture's four observed
    /// Glyphs are a complete table sequence *and* the prefix of a five-Glyph
    /// one, and only the four visible slot indicators separate them — so it is
    /// applied when known and ignored when not, never inferred from the
    /// observations themselves.
    public func outlook(observed: [GlyphID], expectedLength: Int? = nil,
                        displayCandidateLimit: Int = 8) -> SequenceOutlook {
        func result(_ state: PredictionState, _ matches: [[GlyphID]],
                    mayBeComplete: Bool = false) -> SequenceOutlook {
            let weight = matches.isEmpty ? 0 : 1.0 / Double(matches.count)
            let shown = matches.prefix(displayCandidateLimit)
                .map { SequenceCandidate(glyphs: $0, weight: weight) }
            var alternatives: [[GlyphID]] = []
            let longest = matches.map(\.count).max() ?? 0
            if longest > observed.count {
                for position in observed.count..<longest {
                    let choices = Set(matches.compactMap { $0.count > position ? $0[position] : nil })
                    alternatives.append(choices.sorted())
                }
            }
            let suffix = state == .resolved && matches.count == 1
                ? Array(matches[0].dropFirst(observed.count)) : []
            return SequenceOutlook(state: state, observed: observed, expectedLength: expectedLength,
                                   candidateCount: matches.count, candidates: Array(shown),
                                   predictedSuffix: suffix, suffixAlternatives: alternatives,
                                   observationMayBeComplete: mayBeComplete)
        }

        if let length = expectedLength {
            guard (1...SequenceTable.maximumLength).contains(length), length >= observed.count else {
                // Fewer slots than Glyphs collected, or a count outside what the
                // game presents. Truncating the prefix to fit would throw away a
                // real observation to satisfy a suspect measurement.
                return result(.lengthConflict, [])
            }
        }

        let base = predict(observed: observed)
        guard !base.isContradicted else { return result(.contradicted, []) }

        var matches = base.candidates.map(\.glyphs)
        if let length = expectedLength {
            matches = matches.filter { $0.count == length }
            guard !matches.isEmpty else { return result(.lengthConflict, []) }
        }

        let mayBeComplete = base.observationMayBeComplete
            && (expectedLength == nil || expectedLength == observed.count)
        if observed.isEmpty { return result(.unobserved, matches, mayBeComplete: mayBeComplete) }
        return result(matches.count == 1 ? .resolved : .ambiguous, matches, mayBeComplete: mayBeComplete)
    }
}
