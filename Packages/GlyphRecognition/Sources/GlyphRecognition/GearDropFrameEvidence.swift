/// Coordinates are normalized to the original frame, with a top-left origin.
public struct GearDropPanelBounds: Sendable, Equatable, Codable {
    public let top: Double
    public let bottom: Double
    public init(top: Double, bottom: Double) { self.top = top; self.bottom = bottom }
}

/// A title is classified in the reader and immediately discarded. In particular,
/// neither portal titles nor hashes of them become group or hack identities.
public enum GearDropStage: String, Sendable, Codable {
    case absent, unknown, portal, bonus, excluded, unsupported
}

public struct GearDropEntry: Sendable, Equatable, Codable {
    public enum Level: String, Sendable, Codable { case known, notApplicable, unreadable }
    public enum Rarity: String, Sendable, Codable { case common, rare, veryRare, unreadable }
    public let column: Int
    public let row: Int
    /// An allowlisted English name; nil for unknown or unsupported truncations.
    public let item: String?
    public let levelState: Level
    public let level: Int?
    public let quantity: Int
    /// Nil in older records and for items without a rarity meter. An attempted
    /// but inconclusive pixel reading is explicitly unreadable. A fixed rarity
    /// can instead follow from the recognized item identity (see intrinsicRarity).
    public let rarity: Rarity?
    /// The game printed the quantity in red: a multiplier, such as the first
    /// hack of the day's, applied to this drop. Nil when the colour was not
    /// read, as in older records, or was unclear.
    public let multiplied: Bool?
    public var position: Int { row * 2 + column }

    public init(column: Int, row: Int, item: String?, levelState: Level,
                level: Int?, quantity: Int, rarity: Rarity? = nil, multiplied: Bool? = nil) {
        self.column = column; self.row = row; self.item = item
        self.levelState = levelState; self.level = level; self.quantity = quantity; self.rarity = rarity
        self.multiplied = multiplied
    }

    /// Decides whether to inspect the meter, never which rarity to assign.
    public var hasRarityMeter: Bool {
        guard levelState == .notApplicable, let item else { return false }
        return !["Portal Key", "Media"].contains(item)
    }

    /// Items that exist in one rarity only. This is catalog knowledge, not
    /// evidence that a meter was visible, and it replaces any meter reading.
    /// Items with several rarities still need pixels.
    public var intrinsicRarity: Rarity? {
        guard levelState == .notApplicable, let item else { return nil }
        return Self.fixedRarity[item]
    }

    /// See Docs/GEAR_DROP_ITEMS.md for the sources. Portal Shield, Heat Sink,
    /// Multi-Hack, Link Amp, Kinetic Capsule and Capsule are not listed: they
    /// come in more than one rarity, or theirs isn't established.
    static let fixedRarity: [String: Rarity] = [
        "Aegis Shield": .veryRare, "Hypercube": .veryRare,
        "ADA Refactor": .veryRare, "JARVIS Virus": .veryRare,
        "SoftBank Ultra Link": .veryRare,
        "ITO EN Transmuter (+)": .veryRare, "ITO EN Transmuter (-)": .veryRare,
        "Turret": .rare, "Force Amp": .rare,
    ]

    public func withRarity(_ rarity: Rarity?) -> Self {
        Self(column: column, row: row, item: item, levelState: levelState, level: level,
             quantity: quantity, rarity: rarity, multiplied: multiplied)
    }

    public func withMultiplied(_ multiplied: Bool?) -> Self {
        Self(column: column, row: row, item: item, levelState: levelState, level: level,
             quantity: quantity, rarity: rarity, multiplied: multiplied)
    }
}

public struct GearDropFrameEvidence: Sendable, Equatable, Codable {
    public let sourceTime: Double
    public let stage: GearDropStage
    public let bounds: GearDropPanelBounds?
    public let entries: [GearDropEntry]
    /// Includes malformed, obscured and low-confidence text rows. A confirmed
    /// quantity does not establish coverage of rows the reader could not parse.
    public let unreadableRows: Int
    /// Item effects the panel says were applied, such as "ITO EN (+)".
    public let effects: [String]?
    /// The game language whose own Bonus title was read; nil otherwise.
    public let titleLanguage: GameLanguage?

    public init(sourceTime: Double, stage: GearDropStage, bounds: GearDropPanelBounds? = nil,
                entries: [GearDropEntry] = [], unreadableRows: Int = 0, effects: [String]? = nil,
                titleLanguage: GameLanguage? = nil) {
        self.sourceTime = sourceTime; self.stage = stage; self.bounds = bounds
        self.entries = entries; self.unreadableRows = unreadableRows; self.effects = effects
        self.titleLanguage = titleLanguage
    }
}
