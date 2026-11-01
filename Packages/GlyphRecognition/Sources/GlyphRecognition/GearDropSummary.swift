public struct GearDropSummary: Sendable, Equatable, Codable {
    public struct Panel: Sendable, Equatable, Codable {
        public let stage: GearDropStage
        public var entries: [GearDropEntry]
        public var partial: Bool
        /// Item effects this panel showed, such as "ITO EN (+)"; absent in
        /// readings saved before effects were read.
        public var effects: [String]?
        public init(stage: GearDropStage, entries: [GearDropEntry], partial: Bool, effects: [String]? = nil) {
            self.stage = stage; self.entries = entries; self.partial = partial; self.effects = effects
        }
    }

    /// How a group was matched to a hack. Ordinary hacks are invisible to the
    /// capture, so an ordered match is the best available, never proof.
    public enum Association: String, Sendable, Codable {
        /// Not yet matched against the queue.
        case unassociated
        /// The oldest waiting hack, by order.
        case ordered
        /// The oldest waiting hack, by order, although no Bonus panel showed:
        /// its result was 0% or unread, so an ordinary hack's group can't be
        /// ruled out.
        case orderedWithoutBonus
        /// No Bonus panel, while the oldest waiting hack's result promised
        /// bonus items: most likely an ordinary hack's group.
        case bonusExpected
        /// No hack was waiting for drops.
        case noWaitingHack
        /// A wait expired or capture continuity was lost; order cannot safely
        /// identify subsequent groups during this capture session.
        case uncertainContinuity
        /// A Bonus panel with no row read, found again just after the previous
        /// group ended on a Bonus panel: that panel, lost for a moment under
        /// pickup sparks. It claims no hack and adds nothing.
        case repeatedBonus
    }

    public let groupID: Int
    public let startedAt: Double
    public let closedAt: Double
    public let closeReason: String
    public var hackID: Int?
    public var association: Association
    public let panels: [Panel]

    public init(groupID: Int, startedAt: Double, closedAt: Double, closeReason: String, hackID: Int?,
                association: Association, panels: [Panel]) {
        self.groupID = groupID; self.startedAt = startedAt; self.closedAt = closedAt
        self.closeReason = closeReason; self.hackID = hackID; self.association = association
        self.panels = panels
    }
    public var recognizedQuantity: Int {
        panels.flatMap(\.entries).filter { $0.item != nil && $0.levelState != .unreadable }
            .reduce(0) { $0 + $1.quantity }
    }
    public var unidentifiedQuantity: Int {
        panels.flatMap(\.entries).filter { $0.item == nil || $0.levelState == .unreadable }
            .reduce(0) { $0 + $1.quantity }
    }
    /// Every panel shown was read with no unidentified row. Rows or panels
    /// never seen can't be counted, so this is coverage of what was seen.
    public var panelsReadInFull: Bool {
        !panels.isEmpty && panels.allSatisfy { !$0.partial } && unidentifiedQuantity == 0
    }
    /// Coverage of the two observed summaries, never a claim about inventory.
    public var bothPanelsRead: Bool {
        panels.count == 2 && panels[0].stage == .portal && panels[1].stage == .bonus
            && panels.allSatisfy { !$0.partial }
    }
}
