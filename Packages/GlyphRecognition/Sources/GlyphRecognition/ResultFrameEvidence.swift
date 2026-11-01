/// Normalized coordinates use the full frame's top-left origin.
public struct ResultTextLine: Sendable, Equatable {
    public let text: String
    public let confidence: Double
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.text = text; self.confidence = confidence
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Appearance and stage are separate: an unsuccessful slot still has a turn
/// in the animation, even though its bonus does not increase.
public enum ResultSlotAppearance: String, Sendable, Equatable {
    case gold, magenta, unreadable
}

public enum GameSlotOutcome: String, Sendable, Equatable, Codable {
    case accepted, rejected, unknown
}

/// Frozen when OCR is submitted, never reconstructed from a newer hack.
public struct ResultReadContext: Sendable, Equatable {
    public let sessionID: CaptureSessionID
    public let hackID: Int
    public let glyphs: [String?]
    public let commands: HackCommandSummary?

    public init(sessionID: CaptureSessionID, hackID: Int, glyphs: [String?], commands: HackCommandSummary? = nil) {
        self.sessionID = sessionID; self.hackID = hackID; self.glyphs = glyphs
        self.commands = commands
    }
}

public struct ResultFrameEvidence: Sendable, Equatable {
    public let context: ResultReadContext
    public let sourceTime: Double
    public let panelPresent: Bool
    public let stageIndex: Int?
    public let hackingBonus: Int?
    public let speedBonus: Int?
    public let appearances: [ResultSlotAppearance]
    public let lines: [ResultTextLine]

    /// The game language whose own Hacking Bonus label was read; nil for
    /// no label. Only a language's own text names it: Japanese keeps SPEED
    /// BONUS in English.
    public let labelLanguage: GameLanguage?

    public init(context: ResultReadContext, sourceTime: Double, panelPresent: Bool,
                stageIndex: Int? = nil, hackingBonus: Int? = nil, speedBonus: Int? = nil,
                appearances: [ResultSlotAppearance] = [], lines: [ResultTextLine] = [],
                labelLanguage: GameLanguage? = nil) {
        self.context = context; self.sourceTime = sourceTime; self.panelPresent = panelPresent
        self.stageIndex = stageIndex; self.hackingBonus = hackingBonus; self.speedBonus = speedBonus
        self.appearances = appearances; self.lines = lines; self.labelLanguage = labelLanguage
    }
}

/// No screen data, framework objects, or recognition work lives in the reducer.
public struct HackResult: Sendable, Equatable {
    public enum State: String, Sendable, Codable { case awaiting, partial, complete, notObserved }
    public let context: ResultReadContext
    public var state: State = .awaiting
    public var firstPanelTime: Double?
    public var lastPanelTime: Double?
    public var finalStageTime: Double?
    public var observedHackingBonus: Int?
    public var observedSpeedBonus: Int?
    public var finalHackingBonus: Int?
    public var finalSpeedBonus: Int?
    public var outcomes: [GameSlotOutcome]
    public var outcomeTimes: [Double?]
    public var closedAt: Double?
    public var closeReason: String?
    /// The first and last frames that showed the input screen before the
    /// result appeared.
    public var inputStartedAt: Double?
    public var inputEndedAt: Double?

    /// How long the player drew, from the input screen to submitting: only
    /// once the result appeared, so an abandoned hack has none. Frame
    /// sampling makes it short by up to one frame interval at each end.
    public var inputSeconds: Double? {
        guard firstPanelTime != nil, let start = inputStartedAt, let end = inputEndedAt,
              end > start, end - start < 120 else { return nil }
        return end - start
    }
}
