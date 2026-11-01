/// The enumerated set of Glyph sequences the game draws from.
///
/// Sequences are not generated freely, which is the whole reason prediction
/// from a partial observation works at all.
///
/// Rows are deduplicated. The reference file contains the same sequence twice
/// in two places; indexing it twice would make a sequence with exactly one
/// distinct answer report two candidates and therefore look unresolved. The
/// repeat count is kept separately as `weight(of:)` in case it ever turns out
/// to carry frequency information — on present evidence it is just a data entry
/// artefact.
public struct SequenceTable: Sendable {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case interiorGap(line: Int, contents: String)
        case tooManyGlyphs(line: Int, found: Int)

        public var description: String {
            switch self {
            case .empty: return "no rows"
            case .interiorGap(let l, let c): return "line \(l): empty field between names in \"\(c)\""
            case .tooManyGlyphs(let l, let n): return "line \(l): \(n) glyphs, maximum is 5"
            }
        }
    }

    /// The longest sequence the game presents (L8 portals).
    public static let maximumLength = 5

    /// Distinct sequences, in first-seen order.
    public let sequences: [[GlyphID]]

    /// Total rows parsed, including repeats. Differs from `sequences.count`
    /// exactly when the source contains duplicates.
    public let rowCount: Int

    private let weights: [[GlyphID]: Int]
    private let byPrefix: [[GlyphID]: [[GlyphID]]]
    private let complete: Set<[GlyphID]>

    public init(sequences input: [[GlyphID]]) {
        let nonEmpty = input.filter { !$0.isEmpty }
        self.rowCount = nonEmpty.count

        var seen: Set<[GlyphID]> = []
        var distinct: [[GlyphID]] = []
        var counts: [[GlyphID]: Int] = [:]
        for sequence in nonEmpty {
            counts[sequence, default: 0] += 1
            if seen.insert(sequence).inserted { distinct.append(sequence) }
        }
        self.sequences = distinct
        self.weights = counts
        self.complete = seen

        // Index every prefix once, so a lookup during a hack is a dictionary
        // hit rather than a scan of the whole table.
        var index: [[GlyphID]: [[GlyphID]]] = [:]
        for sequence in distinct {
            for length in 1...sequence.count {
                index[Array(sequence.prefix(length)), default: []].append(sequence)
            }
        }
        self.byPrefix = index
    }

    /// Parses the reference sequence table: Glyph names in order, padded to a
    /// fixed column count with trailing empty fields.
    ///
    /// Only *trailing* padding is stripped. An empty field between two names is
    /// a malformed row, not a row with a hole to close up — silently closing it
    /// would invent a sequence that does not exist.
    public static func parse(csv: String) throws -> SequenceTable {
        var parsed: [[GlyphID]] = []
        var lineNumber = 0

        for rawLine in csv.splitIntoLines() {
            lineNumber += 1
            let line = rawLine.trimmingWhitespace()
            if line.isEmpty { continue }

            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingWhitespace() }
            while let last = fields.last, last.isEmpty { fields.removeLast() }
            if fields.isEmpty { continue }

            if fields.contains(where: \.isEmpty) {
                throw ParseError.interiorGap(line: lineNumber, contents: line)
            }
            guard fields.count <= maximumLength else {
                throw ParseError.tooManyGlyphs(line: lineNumber, found: fields.count)
            }
            parsed.append(fields.map(GlyphID.init))
        }

        guard !parsed.isEmpty else { throw ParseError.empty }
        return SequenceTable(sequences: parsed)
    }

    /// Number of distinct sequences.
    public var count: Int { sequences.count }

    /// How many times this exact sequence appeared in the source.
    public func weight(of sequence: [GlyphID]) -> Int { weights[sequence] ?? 0 }

    /// Every sequence consistent with what has been observed so far.
    ///
    /// An empty prefix returns everything; an unknown prefix returns nothing,
    /// which is the signal that a Glyph was misread.
    public func candidates(forPrefix prefix: [GlyphID]) -> [[GlyphID]] {
        guard !prefix.isEmpty else { return sequences }
        return byPrefix[prefix] ?? []
    }

    /// Whether the observation is itself a complete sequence.
    ///
    /// Not the same as having no continuations: 37 sequences in the reference
    /// table are both complete in their own right and a prefix of something
    /// longer, so "it could stop here" and "it could continue" are both true at
    /// once and a caller has to be told both.
    public func isComplete(_ observed: [GlyphID]) -> Bool { complete.contains(observed) }

    /// Every distinct Glyph that could come next.
    public func continuations(after prefix: [GlyphID]) -> Set<GlyphID> {
        Set(candidates(forPrefix: prefix).compactMap { sequence in
            sequence.count > prefix.count ? sequence[prefix.count] : nil
        })
    }
}
