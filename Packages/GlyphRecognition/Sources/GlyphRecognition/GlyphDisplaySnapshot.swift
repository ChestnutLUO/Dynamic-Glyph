import Foundation

/// Whether the app is allowed to treat tracked slots as a real sequence.
///
/// Before capture has produced a frame there is nothing to track, and the
/// honest display is the one that claims nothing about the required sequence.
public enum AcceptanceMode: Sendable, Equatable {
    case trackingSequence
    case provisionalOnly(reason: String)

    public var isTracking: Bool { self == .trackingSequence }
}

/// Live capture health, as far as the display is concerned.
public enum CaptureLiveness: String, Sendable, Equatable {
    case starting, live, interrupted, stopped
}

/// What the display is doing, in one value, so that the words on it and the
/// colour around its edge are always the same answer.
///
/// The order these are tested in is a priority order: anything that makes the
/// display untrustworthy outranks anything it would otherwise be saying.
public enum DisplayStatus: String, Sendable, Equatable {
    /// Capture has ended.
    case stopped
    /// No new frames are arriving; whatever is shown is old.
    case stale
    /// Our own window, or a notification, is sitting on evidence we need.
    case obstructed
    /// A sequence retained without verified slot positions.
    case inferred
    /// Shapes as seen, not a claim about the required sequence.
    case provisional
    /// The indicator count changed mid-hack, so positions cannot be trusted.
    case conflicted
    /// Nothing to show: no Glyph screen, or the command channel.
    case waiting
    /// The sequence is being presented and collected.
    case collecting
    /// The presentation is over and the player is drawing.
    case yourTurn
    /// The hack finished.
    case complete
    /// The phase could not be read.
    case unknownPhase

    /// Whether this is a state the player can act on, as opposed to one that
    /// says the display is not currently worth trusting.
    public var isTrustworthy: Bool {
        switch self {
        case .stopped, .stale, .obstructed, .conflicted, .unknownPhase: return false
        case .inferred, .provisional, .waiting, .collecting, .yourTurn, .complete: return true
        }
    }
}

/// The colour a status is shown in, named for what it means rather than its
/// hue. The Picture in Picture edge and the Dynamic Island keyline both take it
/// from here, so the same status is the same colour wherever the player looks,
/// while each surface keeps its own palette.
public enum StatusTone: String, Sendable, Equatable, CaseIterable {
    /// The display is not currently worth trusting.
    case warning
    /// Something is shown, but not as a verified sequence.
    case tentative
    /// Nothing to follow yet.
    case idle
    /// The sequence is being collected.
    case collecting
    /// The player is drawing.
    case drawing
    /// The hack finished.
    case done
}

extension DisplayStatus {
    public var tone: StatusTone {
        switch self {
        case .stopped, .stale, .obstructed, .conflicted: return .warning
        case .inferred, .provisional: return .tentative
        case .waiting, .unknownPhase: return .idle
        case .collecting: return .collecting
        case .yourTurn: return .drawing
        case .complete: return .done
        }
    }
}

/// The single immutable value every surface renders.
///
/// PiP, the inline preview and the Live Activity all read this and nothing
/// else, so they cannot disagree about slot order, candidate count or how
/// certain any of it is. Rendering consumes this; it never decides anything.
public struct GlyphDisplaySnapshot: Sendable, Equatable {
    public let captureSessionID: CaptureSessionID
    public let hackID: Int
    /// Increases whenever anything here changed. Renderers redraw on this.
    public let revision: Int
    public let inputChecks: [InputCheckResult]

    public let liveness: CaptureLiveness
    public let state: TrackingState
    public let phaseSource: PhaseSource
    public let acceptance: AcceptanceMode

    /// The source frame's own timestamp, for correlating with the raw logs.
    public let sourceFrameTime: Double
    /// Host uptime when that frame finished being analyzed. Age must be
    /// measured against this and nothing else: the capture clock and the host
    /// clock are not guaranteed to be the same domain, and subtracting across
    /// them would produce a confident, wrong freshness.
    public let evidenceArrivalUptime: Double

    /// Independently counted, never inferred from how many Glyphs were read.
    public let expectedSlotCount: Int?
    public let slots: [SlotObservation]
    public let currentSlotIndex: Int?
    /// Which slot the player is on, during input. Display only.
    public let inputSlotIndex: Int?
    /// Source time the gold indicator was last read. Guidance that rests on a
    /// reading this old is withdrawn rather than shown dimmed, because "draw
    /// this now" is an instruction and a stale one points at the wrong Glyph.
    public let inputSlotObservedTime: Double?
    /// The indicators were legible and have stopped being so mid-hack — a
    /// notification banner, or the Picture in Picture window, sitting on the strip.
    public let indicatorsObstructed: Bool
    public let slotCountConflict: Bool
    public let isFrozen: Bool

    /// A shape visible right now that is not part of any slot yet.
    public let provisionalGlyph: GlyphID?
    /// How many table shapes strictly contain the provisional one, i.e. how
    /// many ways it could still be the beginning of something longer.
    public let provisionalExtensionCount: Int

    public let outlook: SequenceOutlook
    /// Calibration state in one line, for the diagnostic corner.
    public let calibrationSummary: String
    public let gear: GearDropDisplay?

    public init(captureSessionID: CaptureSessionID, hackID: Int, revision: Int,
                liveness: CaptureLiveness, state: TrackingState, phaseSource: PhaseSource,
                acceptance: AcceptanceMode, sourceFrameTime: Double, evidenceArrivalUptime: Double,
                expectedSlotCount: Int?, slots: [SlotObservation], currentSlotIndex: Int?,
                inputSlotIndex: Int?, inputSlotObservedTime: Double? = nil,
                indicatorsObstructed: Bool = false,
                slotCountConflict: Bool, isFrozen: Bool,
                provisionalGlyph: GlyphID?, provisionalExtensionCount: Int,
                outlook: SequenceOutlook, calibrationSummary: String,
                inputChecks: [InputCheckResult] = [], inputCheckRevision: Int = 0,
                gear: GearDropDisplay? = nil, gearRevision: Int = 0) {
        self.captureSessionID = captureSessionID
        self.hackID = hackID
        self.revision = revision + inputCheckRevision + gearRevision
        self.gear = gear
        self.inputChecks = inputChecks
        self.liveness = liveness
        self.state = state
        self.phaseSource = phaseSource
        self.acceptance = acceptance
        self.sourceFrameTime = sourceFrameTime
        self.evidenceArrivalUptime = evidenceArrivalUptime
        self.expectedSlotCount = expectedSlotCount
        self.slots = slots
        self.currentSlotIndex = currentSlotIndex
        self.inputSlotIndex = inputSlotIndex
        self.inputSlotObservedTime = inputSlotObservedTime
        self.indicatorsObstructed = indicatorsObstructed
        self.slotCountConflict = slotCountConflict
        self.isFrozen = isFrozen
        self.provisionalGlyph = provisionalGlyph
        self.provisionalExtensionCount = provisionalExtensionCount
        self.outlook = outlook
        self.calibrationSummary = calibrationSummary
    }

    public static func waiting(sessionID: CaptureSessionID, liveness: CaptureLiveness,
                               acceptance: AcceptanceMode) -> GlyphDisplaySnapshot {
        GlyphDisplaySnapshot(
            captureSessionID: sessionID, hackID: 0, revision: 0, liveness: liveness,
            state: .inactive, phaseSource: .none, acceptance: acceptance,
            sourceFrameTime: 0, evidenceArrivalUptime: 0, expectedSlotCount: nil, slots: [],
            currentSlotIndex: nil, inputSlotIndex: nil, slotCountConflict: false, isFrozen: false,
            provisionalGlyph: nil, provisionalExtensionCount: 0, outlook: .unavailable,
            calibrationSummary: "waiting for an empty array")
    }

    /// What the floating window shows during gear-only capture before any
    /// item panel: "Watching for gear", with no count. The state
    /// `GearDropDisplayTracker(standalone: true)` reports between drops when
    /// nothing has been read yet, so a picture of the idle window can show
    /// it without inventing anything. Live as of `uptime`, so draw it with
    /// the same uptime.
    public static func gearOnlyIdle(uptime: Double) -> GlyphDisplaySnapshot {
        GlyphDisplaySnapshot(
            captureSessionID: CaptureSessionID(rawValue: 0), hackID: 0, revision: 0, liveness: .live,
            state: .inactive, phaseSource: .none, acceptance: .trackingSequence,
            sourceFrameTime: 0, evidenceArrivalUptime: uptime, expectedSlotCount: nil, slots: [],
            currentSlotIndex: nil, inputSlotIndex: nil, slotCountConflict: false, isFrozen: false,
            provisionalGlyph: nil, provisionalExtensionCount: 0, outlook: .unavailable,
            calibrationSummary: "idle", gear: GearDropDisplay(state: .watching, hackID: nil, itemCount: 0))
    }

    /// Seconds since the evidence behind this snapshot arrived.
    public func age(atUptime now: Double) -> Double {
        evidenceArrivalUptime > 0 ? max(0, now - evidenceArrivalUptime) : 0
    }

    public func isStale(atUptime now: Double, threshold: Double) -> Bool {
        evidenceArrivalUptime > 0 && age(atUptime: now) > threshold
    }

    /// The one line that explains the display's current honesty, chosen in one
    /// place so PiP, the inline preview and the Live Activity agree on it.
    /// What the display is doing, as one value.
    ///
    /// Both the words and the colour on the window's edge come from this, so
    /// they cannot end up telling the player different things.
    public func displayStatus(atUptime now: Double,
                              stalenessThreshold: Double = 1.5) -> DisplayStatus {
        if liveness == .stopped { return .stopped }
        if isStale(atUptime: now, threshold: stalenessThreshold) { return .stale }
        if slots.contains(where: { $0.status == .inferred }) { return .inferred }
        if indicatorsObstructed { return .obstructed }
        if case .provisionalOnly = acceptance { return .provisional }
        if slotCountConflict { return .conflicted }
        switch state {
        case .inactive, .command: return .waiting
        case .presenting: return .collecting
        case .input: return .yourTurn
        case .completed: return .complete
        case .interrupted: return .unknownPhase
        }
    }

    public func statusLine(atUptime now: Double, stalenessThreshold: Double = 1.5) -> String {
        if let gear = visibleGear(atUptime: now) { return gear.message(currentHackID: hackID) }
        switch displayStatus(atUptime: now, stalenessThreshold: stalenessThreshold) {
        case .stopped:
            return String(localized: "Not running", bundle: #bundle,
                          comment: "Status line: capture is off.")
        case .stale:
            return String(localized: "Paused", bundle: #bundle,
                          comment: "Status line: the screen feed stopped sending new frames.")
        case .obstructed:
            return String(localized: "Slot row covered · move the window", bundle: #bundle,
                          comment: "Status line: something covers the game's row of hexagon slots.")
        case .inferred:
            return String(localized: "Best guess · positions unverified", bundle: #bundle,
                          comment: "Status line: the sequence order was inferred, not read.")
        case .provisional:
            if case .provisionalOnly(let reason) = acceptance {
                return String(localized: "Getting ready · \(reason)", bundle: #bundle,
                              comment: "Status line while starting. The placeholder is a short reason, e.g. 'waiting for the first frame'.")
            }
            return String(localized: "Getting ready", bundle: #bundle, comment: "Status line while starting.")
        case .conflicted:
            return String(localized: "Slot count changed · positions unreliable", bundle: #bundle,
                          comment: "Status line: the number of slots in the hack changed.")
        case .waiting:
            return state == .command
                ? String(localized: "Get ready · the sequence is coming", bundle: #bundle,
                         comment: "Status line: the game is about to show the Glyph sequence.")
                : String(localized: "Waiting for a Glyph hack", bundle: #bundle,
                         comment: "Status line: no Glyph hack on screen yet. 'Glyph hack' is an Ingress term.")
        case .collecting:
            return phaseSource == .retained
                ? String(localized: "Watching the sequence · header hidden", bundle: #bundle,
                         comment: "Status line: collecting the sequence while the game's header text is covered.")
                : String(localized: "Watching the sequence", bundle: #bundle,
                         comment: "Status line: the game is showing the Glyph sequence.")
        case .yourTurn:
            return String(localized: "Your turn · draw the sequence", bundle: #bundle,
                          comment: "Status line: the player now draws the Glyphs.")
        case .complete:
            return String(localized: "Hack complete", bundle: #bundle,
                          comment: "Status line: the Glyph hack finished.")
        case .unknownPhase:
            return String(localized: "Lost sight of the game", bundle: #bundle,
                          comment: "Status line: the app can no longer tell what the game is showing.")
        }
    }

    /// Drawing and presentation always take precedence over queued gear.
    public func visibleGear(atUptime now: Double) -> GearDropDisplay? {
        guard liveness == .live, !isStale(atUptime: now, threshold: 1.5),
              state != .command, state != .presenting, state != .input else { return nil }
        return gear
    }
}
