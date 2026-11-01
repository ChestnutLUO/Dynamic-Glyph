/// Maps Glyph names to the node walk that draws them.
///
/// The table is supplied at run time rather than compiled in: the reference
/// data set carries no licence, so it is treated as an input, not as source.
///
/// Two lookups are offered and they are not interchangeable.
/// `glyph(matchingEdges:)` is the one recognition should use — it identifies a
/// Glyph by the node pairs the stroke connects, so it is unaffected by which
/// way the stroke was drawn. `glyph(matching:)` additionally requires the walk
/// order to agree, which is only useful when comparing against the data set's
/// own notation.
public struct GlyphTable: Sendable {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case wrongColumnCount(line: Int, found: Int)
        case emptyName(line: Int)
        case invalidShape(line: Int, shape: String)
        case duplicateName(line: Int, name: GlyphID)

        public var description: String {
            switch self {
            case .empty: return "no rows"
            case .wrongColumnCount(let l, let n): return "line \(l): expected 2 columns, found \(n)"
            case .emptyName(let l): return "line \(l): empty name"
            case .invalidShape(let l, let s): return "line \(l): invalid shape \"\(s)\""
            case .duplicateName(let l, let n): return "line \(l): duplicate name \(n)"
            }
        }
    }

    private let pathsByID: [GlyphID: GlyphPath]
    private let idsByPath: [GlyphPath: GlyphID]
    private let idsByEdges: [Set<GlyphPath.Edge>: GlyphID]

    public init(entries: [GlyphID: GlyphPath]) {
        self.pathsByID = entries
        // Distinct names can share a walk or an edge set; keep the
        // lexicographically first so lookup is deterministic across runs.
        self.idsByPath = Dictionary(entries.map { ($0.value, $0.key) }, uniquingKeysWith: min)
        self.idsByEdges = Dictionary(entries.map { ($0.value.undirectedEdges, $0.key) },
                                     uniquingKeysWith: min)
    }

    /// Parses the reference shape table: exactly `name,shape` per row.
    ///
    /// Strict on purpose. Surplus columns, an empty name, an unparseable shape
    /// or a repeated name are all errors rather than rows to skip, because a
    /// silently dropped Glyph becomes a recognition failure that looks like a
    /// vision bug. An optional header is tolerated only as the very first line.
    public static func parse(csv: String) throws -> GlyphTable {
        var entries: [GlyphID: GlyphPath] = [:]
        var lineNumber = 0

        for rawLine in csv.splitIntoLines() {
            lineNumber += 1
            let line = rawLine.trimmingWhitespace()
            if line.isEmpty { continue }

            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingWhitespace() }

            // A header is only a header on line 1. The same text later in the
            // file is a malformed row and is reported as one.
            if lineNumber == 1, fields.count >= 2, fields[1].hasPrefix("shape") { continue }

            guard fields.count == 2 else {
                throw ParseError.wrongColumnCount(line: lineNumber, found: fields.count)
            }
            guard !fields[0].isEmpty else { throw ParseError.emptyName(line: lineNumber) }
            guard let path = GlyphPath(encoded: fields[1]) else {
                throw ParseError.invalidShape(line: lineNumber, shape: fields[1])
            }
            let id = GlyphID(fields[0])
            guard entries[id] == nil else {
                throw ParseError.duplicateName(line: lineNumber, name: id)
            }
            entries[id] = path
        }

        guard !entries.isEmpty else { throw ParseError.empty }
        return GlyphTable(entries: entries)
    }

    public var count: Int { pathsByID.count }
    public var glyphs: [GlyphID] { pathsByID.keys.sorted() }
    public func path(for id: GlyphID) -> GlyphPath? { pathsByID[id] }

    // MARK: - Direction-independent lookup (use this for recognition)

    /// Identifies a Glyph by the node pairs its stroke connects.
    ///
    /// Direction-independent, so a stroke drawn either way resolves to the same
    /// Glyph. This is the lookup recognition should use.
    public func glyph(matchingEdges path: GlyphPath) -> GlyphID? {
        idsByEdges[path.undirectedEdges]
    }

    /// Nearest matches by how many edges differ, closest first.
    ///
    /// The distance is the size of the symmetric difference: one missed or one
    /// spurious segment costs 1. Also direction-independent.
    public func nearestByEdges(to path: GlyphPath, maxDistance: Int = 2) -> [GlyphCandidate] {
        let edges = path.undirectedEdges
        return pathsByID
            .map { GlyphCandidate(id: $0.key,
                                  distance: edges.symmetricDifference($0.value.undirectedEdges).count) }
            .filter { $0.distance <= maxDistance }
            .sorted()
    }

    // MARK: - Order-sensitive lookup (for comparing against the data set)

    /// Exact match on the ordered walk. Fails for a stroke drawn in reverse —
    /// prefer `glyph(matchingEdges:)` unless order genuinely matters.
    public func glyph(matching path: GlyphPath) -> GlyphID? { idsByPath[path] }

    /// Nearest matches by edit distance over the ordered walk.
    public func nearest(to path: GlyphPath, maxDistance: Int = 2) -> [GlyphCandidate] {
        pathsByID
            .map { GlyphCandidate(id: $0.key, distance: path.editDistance(to: $0.value)) }
            .filter { $0.distance <= maxDistance }
            .sorted()
    }

    /// Names that trace the same nodes in the opposite order.
    ///
    /// Empty for this vocabulary, which is what makes edge-set lookup a
    /// complete key rather than a lossy one.
    public var mirrorPairs: [(GlyphID, GlyphID)] {
        var seen: Set<GlyphID> = []
        var pairs: [(GlyphID, GlyphID)] = []
        for id in glyphs {
            guard !seen.contains(id), let path = pathsByID[id] else { continue }
            guard let partner = idsByPath[path.reversed], partner != id else { continue }
            seen.insert(id); seen.insert(partner)
            pairs.append((min(id, partner), max(id, partner)))
        }
        return pairs
    }

    /// Glyphs sharing an undirected edge set — the collisions edge-set lookup
    /// could not resolve. Empty for this vocabulary.
    public var edgeSetCollisions: [[GlyphID]] {
        Dictionary(grouping: glyphs) { pathsByID[$0]!.undirectedEdges }
            .values.filter { $0.count > 1 }.map { $0.sorted() }
    }
}

public struct GlyphCandidate: Hashable, Sendable, Comparable {
    public let id: GlyphID
    public let distance: Int

    public init(id: GlyphID, distance: Int) {
        self.id = id
        self.distance = distance
    }

    public static func < (lhs: GlyphCandidate, rhs: GlyphCandidate) -> Bool {
        (lhs.distance, lhs.id) < (rhs.distance, rhs.id)
    }
}

extension GlyphPath {
    /// Levenshtein distance over the node walk.
    public func editDistance(to other: GlyphPath) -> Int {
        let a = nodes, b = other.nodes
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

extension StringProtocol {
    func trimmingWhitespace() -> String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
