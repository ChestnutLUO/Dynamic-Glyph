import Testing
@testable import GlyphRecognition

/// Aggregate statistics over the reference table.
///
/// These are the figures the output design is built on, so they are pinned. Two
/// caveats are worth stating where they cannot be missed:
///
/// 1. They are computed by scanning the table directly, so on their own they do
///    **not** exercise the prefix index or `predict`. `statisticsAgreeWithPredict`
///    below closes that loop by recomputing every figure through `predict` and
///    requiring the two to agree.
/// 2. They are insensitive to individual rows — deleting one sequence leaves
///    every number here unchanged. The row-count assertions in
///    `ReferenceTableTests` are what guard against dropped data.
@Suite("Discrimination statistics", .enabled(if: ReferenceData.sequencesAvailable))
struct DiscriminationTests {
    private func predictor() throws -> SequencePredictor {
        SequencePredictor(table: try ReferenceData.sequenceTable())
    }

    @Test("One observed Glyph rarely resolves the sequence")
    func afterOne() throws {
        let d = try predictor().discrimination(afterObserving: 1)
        #expect(d.distinctPrefixes == 111)
        #expect(d.uniquelyDetermined == 22)
        #expect(d.medianCandidates == 4)
        #expect(d.worstCase == 18)
        #expect(abs(d.uniqueFraction - 0.198) < 0.005)
        #expect(abs(d.rowWeightedFraction - 0.041) < 0.005)
    }

    @Test("Two observed Glyphs usually resolve the sequence")
    func afterTwo() throws {
        let d = try predictor().discrimination(afterObserving: 2)
        #expect(d.distinctPrefixes == 410)
        #expect(d.uniquelyDetermined == 323)
        #expect(d.medianCandidates == 1)
        #expect(d.worstCase == 7)
        #expect(abs(d.uniqueFraction - 0.788) < 0.005)
        #expect(abs(d.rowWeightedFraction - 0.598) < 0.005)
    }

    @Test("Three observed Glyphs resolve all but a handful")
    func afterThree() throws {
        let d = try predictor().discrimination(afterObserving: 3)
        #expect(d.distinctPrefixes == 443)
        #expect(d.uniquelyDetermined == 410)
        #expect(abs(d.uniqueFraction - 0.926) < 0.005)
        #expect(abs(d.rowWeightedFraction - 0.849) < 0.005)
    }

    /// The number that actually matters for the product. Resolving a sequence
    /// only after its final Glyph has been shown is identification after the
    /// fact, not prediction — so sequences already finished by then are
    /// excluded. It is much less flattering than the 78.8% headline.
    @Test("Early resolution is well below the headline prefix figure")
    func earlyResolution() throws {
        let (resolved, eligible) = try predictor().earlyResolution(afterObserving: 2)
        #expect(eligible == 483)
        #expect(resolved == 280)
        #expect(abs(Double(resolved) / Double(eligible) - 0.58) < 0.01)
    }

    /// Ties the aggregates to the code that actually runs during a hack.
    ///
    /// `discrimination` scans the table directly; `predict` goes through the
    /// prefix index. Recomputing the same figures the second way and requiring
    /// agreement means a defect in the index can no longer hide behind
    /// statistics that were derived without it.
    @Test("The statistics agree when recomputed through predict",
          arguments: [1, 2, 3])
    func statisticsAgreeWithPredict(length: Int) throws {
        let table = try ReferenceData.sequenceTable()
        let predictor = SequencePredictor(table: table)
        let direct = predictor.discrimination(afterObserving: length)

        var sizesByPrefix: [[GlyphID]: Int] = [:]
        for sequence in table.sequences where sequence.count >= length {
            let prefix = Array(sequence.prefix(length))
            guard sizesByPrefix[prefix] == nil else { continue }
            sizesByPrefix[prefix] = predictor.predict(observed: prefix).candidates.count
        }

        let sizes = sizesByPrefix.values.sorted()
        #expect(sizes.count == direct.distinctPrefixes)
        #expect(sizes.filter { $0 == 1 }.count == direct.uniquelyDetermined)
        #expect(sizes[sizes.count / 2] == direct.medianCandidates)
        #expect(sizes.last == direct.worstCase)

        // And resolution agrees per sequence, not just in aggregate.
        let resolved = table.sequences
            .filter { $0.count >= length }
            .filter { predictor.predict(observed: Array($0.prefix(length))).isResolved }
            .count
        #expect(resolved == direct.resolvedSequences)
    }
}
