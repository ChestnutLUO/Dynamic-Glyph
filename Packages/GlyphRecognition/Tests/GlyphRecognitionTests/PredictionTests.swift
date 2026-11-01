import Testing
@testable import GlyphRecognition

/// Prediction behaviour, specified against small hand-written tables where the
/// expected answer can be stated exactly.
///
/// The aggregate statistics over the reference data live in
/// `DiscriminationTests`. They are useful, but they cannot establish that
/// lookup returns the right rows in the right order — an implementation that
/// returned constants would satisfy them.
@Suite("Prediction behaviour")
struct PredictionTests {
    private func g(_ names: String...) -> [GlyphID] { names.map(GlyphID.init) }

    /// a,b,c  /  a,b,d  /  a,e  /  f,g
    private var table: SequenceTable {
        SequenceTable(sequences: [g("a","b","c"), g("a","b","d"), g("a","e"), g("f","g")])
    }

    @Test("An ambiguous prefix lists every consistent sequence, shortest first")
    func ambiguousPrefix() {
        let p = SequencePredictor(table: table).predict(observed: g("a"))
        #expect(p.candidates.map(\.glyphs) == [g("a","e"), g("a","b","c"), g("a","b","d")])
        #expect(p.candidates.allSatisfy { abs($0.weight - 1.0 / 3.0) < 1e-12 })
        #expect(!p.isResolved)
        #expect(!p.isContradicted)
        #expect(p.remaining.isEmpty)
    }

    @Test("A resolving prefix names the exact remaining Glyphs")
    func resolvingPrefix() {
        let p = SequencePredictor(table: table).predict(observed: g("a","b","c"))
        #expect(p.isResolved)
        #expect(p.candidates.count == 1)
        #expect(p.candidates[0].glyphs == g("a","b","c"))
        #expect(p.candidates[0].weight == 1.0)
        #expect(p.remaining.isEmpty)   // resolved *and* finished
    }

    @Test("Resolution mid-sequence projects the suffix exactly")
    func resolutionProjectsSuffix() {
        // "f" is unique to one sequence, so one observation resolves it.
        let p = SequencePredictor(table: table).predict(observed: g("f"))
        #expect(p.isResolved)
        #expect(p.remaining == g("g"))
    }

    @Test("An impossible prefix is contradicted, not guessed")
    func contradiction() {
        let p = SequencePredictor(table: table).predict(observed: g("a","z"))
        #expect(p.candidates.isEmpty)
        #expect(p.isContradicted)
        #expect(!p.isResolved)
        #expect(p.remaining.isEmpty)
    }

    @Test("An observation longer than any sequence is contradicted")
    func overlongObservation() {
        let p = SequencePredictor(table: table).predict(observed: g("a","e","x","y"))
        #expect(p.isContradicted)
    }

    @Test("An empty observation is neither resolved nor contradicted")
    func emptyObservation() {
        let p = SequencePredictor(table: table).predict(observed: [])
        #expect(p.candidates.count == 4)
        #expect(!p.isResolved)
        #expect(!p.isContradicted)
    }

    @Test("Repeated Glyphs keep their positions")
    func repeatedGlyphs() {
        let t = SequenceTable(sequences: [g("a","a","b"), g("a","b","a")])
        let p = SequencePredictor(table: t).predict(observed: g("a","a"))
        #expect(p.isResolved)
        #expect(p.remaining == g("b"))
    }

    /// The reference file lists two sequences twice. Indexed naively that makes
    /// a sequence with one distinct answer report two candidates and look
    /// unresolved — so duplicates are collapsed, and the repeat count is kept
    /// separately rather than thrown away.
    @Test("Duplicate rows collapse but their count is retained")
    func duplicateRows() {
        let t = SequenceTable(sequences: [g("a","b"), g("a","b"), g("c","d")])
        #expect(t.rowCount == 3)
        #expect(t.count == 2)
        #expect(t.weight(of: g("a","b")) == 2)
        #expect(t.weight(of: g("c","d")) == 1)

        let p = SequencePredictor(table: t).predict(observed: g("a"))
        #expect(p.candidates.count == 1, "duplicate must not present as ambiguity")
        #expect(p.isResolved)
        #expect(p.remaining == g("b"))
    }

    @Test("Duplicates in the real table do not create phantom ambiguity", .enabled(if: ReferenceData.sequencesAvailable))
    func duplicatesInReferenceData() throws {
        let t = try ReferenceData.sequenceTable()
        #expect(t.rowCount == 542)
        #expect(t.count == 540)
        let duplicated = g("have","harmony","together","end","mystery")
        #expect(t.weight(of: duplicated) == 2)
        let p = SequencePredictor(table: t).predict(observed: Array(duplicated.prefix(4)))
        #expect(p.candidates.map(\.glyphs) == [duplicated])
        #expect(p.isResolved)
    }

    /// A prefix can be a finished sequence *and* the start of longer ones. The
    /// caller has to be told both, or it will either cut a hack short or wait
    /// for a Glyph that never comes.
    @Test("A terminal prefix reports completion and continuation together")
    func terminalPrefix() {
        let t = SequenceTable(sequences: [g("a","b"), g("a","b","c")])
        let p = SequencePredictor(table: t).predict(observed: g("a","b"))
        #expect(p.observationMayBeComplete)
        #expect(p.candidates.count == 2)
        #expect(!p.isResolved)
        #expect(t.continuations(after: g("a","b")) == [GlyphID("c")])
    }

    @Test("pursue,conflict is a real terminal prefix in the reference data", .enabled(if: ReferenceData.sequencesAvailable))
    func terminalPrefixInReferenceData() throws {
        let t = try ReferenceData.sequenceTable()
        let observed = g("pursue","conflict")
        #expect(t.isComplete(observed))
        let p = SequencePredictor(table: t).predict(observed: observed)
        #expect(p.observationMayBeComplete)
        #expect(p.candidates.count == 3, "one complete plus two longer")
    }

    @Test("A weight is a conditional share, not a confidence")
    func weightsAreConditional() {
        let p = SequencePredictor(table: table).predict(observed: g("a","b"))
        #expect(p.candidates.count == 2)
        #expect(p.candidates.allSatisfy { $0.weight == 0.5 })
        // A lone survivor scores 1.0 even though nothing here says the
        // observation was read correctly.
        let lone = SequencePredictor(table: table).predict(observed: g("f"))
        #expect(lone.candidates[0].weight == 1.0)
    }

    @Test("Prefix lookup agrees with a direct scan for every prefix", .enabled(if: ReferenceData.sequencesAvailable))
    func prefixIndexMatchesScan() throws {
        let t = try ReferenceData.sequenceTable()
        var checked = 0
        for sequence in t.sequences {
            for length in 1...sequence.count {
                let prefix = Array(sequence.prefix(length))
                let scanned = t.sequences.filter { $0.count >= length && Array($0.prefix(length)) == prefix }
                #expect(Set(t.candidates(forPrefix: prefix)) == Set(scanned))
                checked += 1
            }
        }
        #expect(checked > 2000)
    }
}
