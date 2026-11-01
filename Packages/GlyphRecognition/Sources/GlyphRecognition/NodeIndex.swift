/// One of the eleven nodes of the Glyph array.
///
/// The published data set encodes nodes as the characters `0`–`9` and `a`,
/// which is where the eleven-node count is confirmed rather than assumed.
public struct NodeIndex: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Number of nodes in the array.
    public static let count = 11

    public let rawValue: Int

    public init?(rawValue: Int) {
        guard (0..<Self.count).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init?(character: Character) {
        guard let value = character.hexDigitValue, value < Self.count else { return nil }
        self.rawValue = value
    }

    /// The character this node is written as in the data set.
    public var character: Character {
        Character(String(rawValue, radix: 16))
    }

    public var description: String { String(character) }

    public static func < (lhs: NodeIndex, rhs: NodeIndex) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Every node, in ascending order.
    public static let all: [NodeIndex] = (0..<count).compactMap(NodeIndex.init(rawValue:))
}
