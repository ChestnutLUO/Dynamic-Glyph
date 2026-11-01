/// Identifies one capture session. A tracker rejects evidence carrying any
/// other value, which is what stops an asynchronous header analysis started
/// before a stop/start from being applied to the session that followed it.
public struct CaptureSessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { String(rawValue) }
}

/// The screens of one Glyph hack.
///
/// `unknown` is a first-class answer, not a failure to be smoothed away: a
/// header that could not be read must not be guessed at, because every slot
/// commit is gated on knowing the phase.
public enum GamePhase: String, Sendable, Equatable, CaseIterable {
    case unknown, command, presenting, input, completed
}

/// Where a phase came from. Recorded per decision so a wrong commit can be
/// traced back to the evidence that allowed it.
public enum PhaseSource: String, Sendable, Equatable {
    /// Text recognized in the header region.
    case headerText
    /// Header unreadable; the phase was retained from an earlier frame.
    case retained
    /// A visible countdown below the strip, within an already observed hack.
    case inputTimer
    /// A stable unselected indicator row followed by selection of slot zero.
    case indicatorTransition
    /// No evidence at all.
    case none
}

/// One reading of the header region.
///
/// `sourceTime` is the timestamp of the frame the text was read from, which is
/// not the frame the reading is being applied to: header analysis is expensive
/// enough to run behind the sampling cadence. Carrying it makes the lag visible
/// to the tracker instead of letting a stale phase pass for a current one.
public struct HeaderReading: Sendable, Equatable {
    public let phase: GamePhase
    /// The normalized text that matched, for the log. Empty when nothing did.
    public let matchedText: String
    /// The recognizer's own confidence for the matched line, 0...1.
    public let confidence: Double
    public let sourceTime: Double

    public init(phase: GamePhase, matchedText: String, confidence: Double, sourceTime: Double = 0) {
        self.phase = phase
        self.matchedText = matchedText
        self.confidence = confidence
        self.sourceTime = sourceTime
    }

    public func at(sourceTime: Double) -> HeaderReading {
        HeaderReading(phase: phase, matchedText: matchedText, confidence: confidence, sourceTime: sourceTime)
    }
}

/// Classifies header text without any text-recognition framework, so the
/// phrases, the normalization and the thresholds are all testable on their own.
///
/// Only the English portrait strings present in the fixtures are listed. Any
/// other language or layout produces `unknown`, which is the honest answer
/// until a capture in that layout has been checked.
public struct HeaderPhraseMatcher: Sendable {
    public struct Phrase: Sendable, Equatable {
        public let phase: GamePhase
        /// Normalized words that must all appear, in order.
        public let words: [String]
        /// The header must consist of exactly these words. Used for very short
        /// phrases, where a substring match would fire on unrelated text.
        public let requiresExactMatch: Bool
        /// Found anywhere in the line's letters, spaces ignored: Chinese and
        /// Japanese headers are one run of characters, not separate words.
        public let matchesWithin: Bool

        public init(phase: GamePhase, words: [String], requiresExactMatch: Bool = false,
                    matchesWithin: Bool = false) {
            self.phase = phase
            self.words = words
            self.requiresExactMatch = requiresExactMatch
            self.matchesWithin = matchesWithin
        }
    }

    public static let englishPortrait: [Phrase] = GameText(.english).headerPhrases

    public let phrases: [Phrase]
    /// Lines below this are ignored entirely.
    public let minimumConfidence: Double

    public init(phrases: [Phrase] = HeaderPhraseMatcher.englishPortrait,
                minimumConfidence: Double = 0.35) {
        self.phrases = phrases
        self.minimumConfidence = minimumConfidence
    }

    /// The headers of one game language, and English.
    public init(language: GameLanguage) {
        self.init(phrases: GameText(language).headerPhrases, minimumConfidence: language.confidence.header)
    }

    /// Lowercased, with everything that is not a letter or digit becoming a
    /// single space. "Command channel open…" and "COMMAND  CHANNEL OPEN" both
    /// normalize to "command channel open".
    public static func normalize(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber { current.append(character) }
            else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The phase named by the best line, or `unknown`.
    ///
    /// Two different phrases matching in one header is a contradiction, not a
    /// reason to pick the first: it returns `unknown`.
    public func read(lines: [(text: String, confidence: Double)]) -> HeaderReading {
        var hits: [HeaderReading] = []
        for line in lines where line.confidence >= minimumConfidence {
            let words = Self.normalize(line.text)
            guard !words.isEmpty else { continue }
            for phrase in phrases where matches(phrase, in: words) {
                hits.append(HeaderReading(phase: phrase.phase,
                                          matchedText: words.joined(separator: " "),
                                          confidence: line.confidence))
            }
        }
        let phases = Set(hits.map(\.phase))
        guard phases.count == 1, let best = hits.max(by: { $0.confidence < $1.confidence }) else {
            return HeaderReading(phase: .unknown,
                                 matchedText: hits.isEmpty ? "" : "conflicting phrases",
                                 confidence: 0)
        }
        return best
    }

    private func matches(_ phrase: Phrase, in words: [String]) -> Bool {
        if phrase.requiresExactMatch { return words == phrase.words }
        if phrase.matchesWithin { return words.joined().contains(phrase.words.joined()) }
        guard phrase.words.count <= words.count else { return false }
        for start in 0...(words.count - phrase.words.count) {
            if Array(words[start..<(start + phrase.words.count)]) == phrase.words { return true }
        }
        return false
    }
}

/// The shape half of a frame's evidence, reduced from `GlyphFrameObservation`
/// so the tracker never sees pixels.
public struct ShapeEvidence: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// No fit yet, or the frame could not be analyzed.
        case unavailable
        case noStroke
        case unrecognizedStroke
        case unexplainedInk
        case ambiguousShape
        case uniqueVisibleShape
    }

    public let kind: Kind
    /// Set only for `uniqueVisibleShape`.
    public let glyph: GlyphID?
    public let edges: Set<GlyphPath.Edge>
    /// Templates that strictly contain `edges`; a shape that may still grow.
    public let extensions: [GlyphID]

    public init(kind: Kind, glyph: GlyphID?, edges: Set<GlyphPath.Edge>, extensions: [GlyphID]) {
        self.kind = kind
        self.glyph = glyph
        self.edges = edges
        self.extensions = extensions
    }

    public static let unavailable = ShapeEvidence(kind: .unavailable, glyph: nil, edges: [], extensions: [])

    public init(_ observation: GlyphFrameObservation) {
        switch observation.state {
        case .uniqueVisibleShape:
            self.init(kind: .uniqueVisibleShape, glyph: observation.exactMatches.first,
                      edges: observation.edges, extensions: observation.extensions)
        case .ambiguousShape:
            self.init(kind: .ambiguousShape, glyph: nil, edges: observation.edges,
                      extensions: observation.extensions)
        case .unexplainedInk:
            self.init(kind: .unexplainedInk, glyph: nil, edges: observation.edges,
                      extensions: observation.extensions)
        case .unrecognizedStroke:
            self.init(kind: .unrecognizedStroke, glyph: nil, edges: observation.edges,
                      extensions: observation.extensions)
        case .noStroke:
            self.init(kind: .noStroke, glyph: nil, edges: [], extensions: [])
        case .calibrationUnavailable, .calibrationMismatch:
            self = .unavailable
        }
    }
}

/// Everything one sampled frame contributes to the tracker.
///
/// Assembled by the app's Apple-specific adapters; the tracker itself never
/// touches an image, a text recognizer or a clock.
public struct FrameEvidence: Sendable {
    public let sessionID: CaptureSessionID
    /// The source frame's presentation timestamp, in seconds on a monotonic
    /// clock. Not the time the analysis finished.
    public let time: Double
    /// Nil when the header could not be analyzed on this frame, which is
    /// different from analyzing it and finding nothing.
    public let header: HeaderReading?
    /// Nil when no strip could be read. `rejection` says why, for the log.
    public let slots: SlotStripReading?
    public let slotRejection: SlotStripRejection?
    public let shape: ShapeEvidence
    /// The frame's geometry fit is valid and matches the layout.
    public let hasValidCalibration: Bool
    /// Read independently of the indicators.
    public let hasInputTimerBar: Bool

    public init(sessionID: CaptureSessionID, time: Double, header: HeaderReading?,
                slots: SlotStripReading?, slotRejection: SlotStripRejection? = nil,
                shape: ShapeEvidence, hasValidCalibration: Bool, hasInputTimerBar: Bool = false) {
        self.sessionID = sessionID
        self.time = time
        self.header = header
        self.slots = slots
        self.slotRejection = slotRejection
        self.shape = shape
        self.hasValidCalibration = hasValidCalibration
        self.hasInputTimerBar = hasInputTimerBar || slots?.hasInputTimerBar == true
    }
}
