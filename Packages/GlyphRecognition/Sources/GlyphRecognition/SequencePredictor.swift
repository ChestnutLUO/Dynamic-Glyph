/// Turns a partial observation into the set of sequences still consistent with it.
public struct SequencePredictor: Sendable {
    private let table: SequenceTable

    public init(table: SequenceTable) {
        self.table = table
    }

    public func predict(observed: [GlyphID]) -> Prediction {
        let matches = table.candidates(forPrefix: observed)
        // Ordering is for stable presentation only. Shorter first, then
        // alphabetical -- there is no model saying shorter sequences are more
        // likely, and this ordering must not be read as a ranking.
        let ranked = matches
            .sorted { ($0.count, $0.map(\.name).joined(separator: ",")) <
                      ($1.count, $1.map(\.name).joined(separator: ",")) }
            .map { SequenceCandidate(glyphs: $0, weight: 1.0 / Double(matches.count)) }
        return Prediction(observed: observed,
                          candidates: ranked,
                          observationMayBeComplete: table.isComplete(observed))
    }

    /// How discriminating an observation of `length` Glyphs is.
    ///
    /// Two denominators, because they answer different questions and the
    /// difference is large. `uniqueFraction` is per *distinct prefix*: given a
    /// prefix, how often is it unambiguous. `rowWeightedFraction` is per
    /// *sequence*: if every sequence were equally likely to come up, how often
    /// would a player's hack be resolved. The first is a property of the table;
    /// the second is closer to an encounter rate — though only under the
    /// assumption that sequences are uniformly distributed, which is unverified.
    ///
    /// Computed by scanning the table directly rather than through `predict`,
    /// so these figures do not exercise the prefix index. Correctness of
    /// lookup is established separately.
    public func discrimination(afterObserving length: Int) -> Discrimination {
        precondition(length > 0, "A zero-length prefix discriminates nothing")
        let eligible = table.sequences.filter { $0.count >= length }
        var bucketSizes: [[GlyphID]: Int] = [:]
        for sequence in eligible {
            bucketSizes[Array(sequence.prefix(length)), default: 0] += 1
        }
        let sizes = bucketSizes.values.sorted()
        guard !sizes.isEmpty else {
            return Discrimination(prefixLength: length, distinctPrefixes: 0, uniquelyDetermined: 0,
                                  medianCandidates: 0, worstCase: 0,
                                  eligibleSequences: 0, resolvedSequences: 0)
        }
        let resolved = eligible.filter { bucketSizes[Array($0.prefix(length))] == 1 }.count
        return Discrimination(
            prefixLength: length,
            distinctPrefixes: sizes.count,
            uniquelyDetermined: sizes.filter { $0 == 1 }.count,
            medianCandidates: sizes[sizes.count / 2],
            worstCase: sizes[sizes.count - 1],
            eligibleSequences: eligible.count,
            resolvedSequences: resolved
        )
    }

    /// Of the sequences that still have something left to predict after
    /// `length` observations, how many are resolved by them.
    ///
    /// This is the figure that matters for the product: resolving a sequence
    /// only once its last Glyph has already been shown is identification after
    /// the fact, not prediction.
    public func earlyResolution(afterObserving length: Int) -> (resolved: Int, eligible: Int) {
        let eligible = table.sequences.filter { $0.count > length }
        var bucketSizes: [[GlyphID]: Int] = [:]
        for sequence in table.sequences where sequence.count >= length {
            bucketSizes[Array(sequence.prefix(length)), default: 0] += 1
        }
        let resolved = eligible.filter { bucketSizes[Array($0.prefix(length))] == 1 }.count
        return (resolved, eligible.count)
    }

    public struct Discrimination: Hashable, Sendable {
        public let prefixLength: Int
        public let distinctPrefixes: Int
        public let uniquelyDetermined: Int
        public let medianCandidates: Int
        public let worstCase: Int
        public let eligibleSequences: Int
        public let resolvedSequences: Int

        /// Share of *prefixes* of this length that pin the sequence exactly.
        public var uniqueFraction: Double {
            distinctPrefixes == 0 ? 0 : Double(uniquelyDetermined) / Double(distinctPrefixes)
        }

        /// Share of *sequences* resolved, assuming each is equally likely.
        public var rowWeightedFraction: Double {
            eligibleSequences == 0 ? 0 : Double(resolvedSequences) / Double(eligibleSequences)
        }
    }
}

public struct SequenceCandidate: Hashable, Sendable {
    public let glyphs: [GlyphID]

    /// Conditional weight: `1/n` over the `n` candidates still consistent.
    ///
    /// Not a confidence. It says nothing about whether the observation itself
    /// was read correctly, so a lone candidate carries weight 1.0 even when it
    /// only survived because a misread Glyph happened to form another valid
    /// prefix. Recognition confidence has to be carried alongside, not inferred
    /// from this.
    public let weight: Double

    public init(glyphs: [GlyphID], weight: Double) {
        self.glyphs = glyphs
        self.weight = weight
    }
}

/// What the renderers are given: what has been seen, and what it could mean.
public struct Prediction: Hashable, Sendable {
    public let observed: [GlyphID]
    public let candidates: [SequenceCandidate]

    /// The observation is itself a complete sequence in the table.
    ///
    /// Can be true at the same time as `candidates` containing longer
    /// sequences: the hack may have ended, or may continue.
    public let observationMayBeComplete: Bool

    public init(observed: [GlyphID], candidates: [SequenceCandidate],
                observationMayBeComplete: Bool = false) {
        self.observed = observed
        self.candidates = candidates
        self.observationMayBeComplete = observationMayBeComplete
    }

    /// Exactly one sequence remains consistent.
    ///
    /// Conditional on the observation being correct and the table being
    /// complete. It is not a statement that the answer is right.
    public var isResolved: Bool { candidates.count == 1 }

    /// Nothing in the table matches — a Glyph was misread, or the table is
    /// missing a sequence, or the sequence boundary was misjudged.
    public var isContradicted: Bool { candidates.isEmpty && !observed.isEmpty }

    /// The Glyphs still to come, when the sequence has resolved.
    ///
    /// Empty can mean resolved-and-finished, ambiguous, or contradicted, so
    /// callers must check `isResolved` and `isContradicted` rather than reading
    /// emptiness as an answer.
    public var remaining: [GlyphID] {
        guard let only = candidates.first, isResolved else { return [] }
        return Array(only.glyphs.dropFirst(observed.count))
    }
}
