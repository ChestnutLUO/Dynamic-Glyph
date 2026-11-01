/// The name of a Glyph, as used by both the shape table and the sequence table.
public struct GlyphID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var description: String { name }

    public static func < (lhs: GlyphID, rhs: GlyphID) -> Bool {
        lhs.name < rhs.name
    }
}
