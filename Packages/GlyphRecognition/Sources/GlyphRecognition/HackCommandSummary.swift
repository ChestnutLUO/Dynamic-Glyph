/// The game's acknowledgement, rather than the name of the shape drawn.
public enum HackCommand: String, Codable, Sendable, CaseIterable {
    case simple, complex, requestKey, noKey, keysOnly
    public var isPresentation: Bool { self == .simple || self == .complex }
}

public struct HackCommandSummary: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case unknown, portal, drone }
    public struct Selection: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable { case noCommandObserved, confirmed, unresolved, notApplicable }
        public var status: Status = .noCommandObserved
        public var lastObserved: HackCommand?
        public var samples: Int = 0
        public var language: String?
        /// An unresolved later notice must not leave an older command effective.
        public var effective: HackCommand? { status == .confirmed ? lastObserved : nil }
        public init() {}

        private enum CodingKeys: String, CodingKey { case status, lastObserved, samples, language }
        /// A key missing from saved history takes its default, so fields can
        /// be added without breaking older records.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            status = try values.decodeIfPresent(Status.self, forKey: .status) ?? .noCommandObserved
            lastObserved = try values.decodeIfPresent(HackCommand.self, forKey: .lastObserved)
            samples = try values.decodeIfPresent(Int.self, forKey: .samples) ?? 0
            language = try values.decodeIfPresent(String.self, forKey: .language)
        }
    }
    public var presentation = Selection()
    public var gear = Selection()
    public var mode: Mode = .unknown
    public init() {}

    private enum CodingKeys: String, CodingKey { case presentation, gear, mode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        presentation = try values.decodeIfPresent(Selection.self, forKey: .presentation) ?? Selection()
        gear = try values.decodeIfPresent(Selection.self, forKey: .gear) ?? Selection()
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .unknown
    }

    /// Whether the hack's Glyph count can place its portal level: the
    /// presentation command was read, or its window was seen without one.
    /// An unresolved command may have changed the count.
    public var settlesGlyphCount: Bool {
        presentation.status == .confirmed || presentation.status == .noCommandObserved
    }

    /// Nothing was seen of the command window: the capture began later, or
    /// the window was never on screen. Unknown, never "no command".
    static var unobserved: HackCommandSummary {
        var summary = HackCommandSummary()
        summary.presentation.status = .unresolved
        summary.gear.status = .unresolved
        return summary
    }
}

/// No arbitrary OCR strings or image data leave the notice reader.
public struct CommandNoticeReading: Sendable, Equatable {
    public enum Notice: String, Sendable, Codable {
        case simple, complex, requestKey, noKey, keysOnly, invalid, drone
        public var command: HackCommand? { HackCommand(rawValue: rawValue) }
    }
    public let notice: Notice?
    public let confidence: Double
    public let language: String?
    /// Clear enough to stand as the only read of its notice: the level
    /// depends on the script (see GameLanguage.Confidence).
    public let isClear: Bool
    public init(notice: Notice?, confidence: Double, language: String? = nil, isClear: Bool? = nil) {
        self.notice = notice; self.confidence = confidence; self.language = language
        self.isClear = isClear ?? (confidence >= GameLanguage.english.confidence.clearNotice)
    }
}

public struct CommandNoticeParser: Sendable {
    public let text: GameText
    public init(language: GameLanguage = .english) { text = GameText(language) }
    public func read(_ lines: [(String, Double)]) -> CommandNoticeReading {
        let floor = text.language.confidence
        guard lines.count == 1, let line = lines.first, line.1 >= floor.notice else {
            return .init(notice: nil, confidence: 0)
        }
        // The whole line must be one known notice; spaces and marks don't count.
        guard let match = text.notice(line.0) else { return .init(notice: nil, confidence: line.1) }
        // Vision reads Latin text at the same coarse levels in a Chinese or
        // Japanese request, so an English phrase there counts, but only
        // English's own level makes one read enough; otherwise two must agree.
        let clear = match.language == GameLanguage.english.rawValue
            ? GameLanguage.english.confidence.clearNotice : floor.clearNotice
        return .init(notice: match.notice, confidence: line.1, language: match.language, isClear: line.1 >= clear)
    }
}

/// Source-ordered acknowledgements. Pixel capture registers a notice before OCR
/// runs, so an unread final replacement cannot silently preserve an older value.
public struct CommandObservationSession: Sendable {
    private struct Event: Sendable {
        let id: Int
        let time: Double
        let epoch: Int
        var reads: [Double: CommandNoticeReading] = [:]
    }
    private struct Window: Sendable {
        var events: [Event] = []
        var mode: HackCommandSummary.Mode = .unknown
        var lost = false
        /// The command screen was on screen at some point for this window.
        var observed = false
    }
    private var nextID = 0
    private var epoch = 0
    private var pending = Window()
    private var bound: [Int: Window] = [:]
    public init() {}

    public mutating func beginNotice(at time: Double) -> Int {
        nextID += 1
        if pending.events.count >= 128 { pending.events.removeFirst(); pending.lost = true }
        pending.events.append(Event(id: nextID, time: time, epoch: epoch))
        return nextID
    }

    public mutating func accept(_ read: CommandNoticeReading, id: Int, at time: Double) {
        if let index = pending.events.firstIndex(where: { $0.id == id }) {
            pending.events[index].reads[time] = read
        } else {
            for key in bound.keys {
                if let index = bound[key]?.events.firstIndex(where: { $0.id == id }) {
                    bound[key]?.events[index].reads[time] = read
                    break
                }
            }
        }
    }

    public mutating func setMode(_ mode: HackCommandSummary.Mode) { pending.mode = mode }
    public mutating func markObserved() { pending.observed = true }
    /// An overlay, a dropped frame or a brief loss of the screen: a notice may
    /// have been missed, so both settings become uncertain.
    public mutating func loseCoverage(at time: Double) { _ = beginNotice(at: time); pending.observed = true }
    /// Source times order observations only inside one capture-clock epoch.
    /// Keep the uncertain command window; do not attach it to a different hack.
    public mutating func beginEpoch(at time: Double) {
        epoch += 1
        loseCoverage(at: time)
    }
    /// The player left the hack: its commands can't belong to a later one.
    public mutating func cancel() { pending = Window() }
    public mutating func bind(hackID: Int) {
        guard bound[hackID] == nil else { return }
        bound[hackID] = pending
        pending = Window()
        for key in bound.keys.sorted().dropLast(8) { bound[key] = nil }
    }

    public func summary(hackID: Int) -> HackCommandSummary {
        guard let window = bound[hackID], window.observed || !window.events.isEmpty else {
            var unobserved = HackCommandSummary.unobserved
            if let mode = bound[hackID]?.mode, mode == .drone { unobserved.mode = .drone; unobserved.gear.status = .notApplicable }
            return unobserved
        }
        var summary = HackCommandSummary()
        summary.mode = window.mode
        if window.lost { summary.presentation.status = .unresolved; summary.gear.status = .unresolved }
        // Preserve source ordering for out-of-order registration within an
        // epoch; restarted numeric timestamps cannot precede older epochs.
        for event in window.events.sorted(by: {
            if $0.epoch != $1.epoch { return $0.epoch < $1.epoch }
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.id < $1.id
        }) {
            // An unreadable read beside clear ones is a frame caught mid-change,
            // not a second notice; only readable reads can disagree.
            let reads = Array(event.reads.values).filter { $0.notice != nil }
            let notices = Set(reads.compactMap(\.notice))
            guard !reads.isEmpty, notices.count == 1,
                  reads.count >= 2 || reads.contains(where: \.isClear),
                  let notice = notices.first else {
                summary.presentation.status = .unresolved; summary.gear.status = .unresolved
                continue
            }
            guard let command = notice.command else { continue }
            var selection = HackCommandSummary.Selection()
            selection.status = .confirmed; selection.lastObserved = command
            selection.samples = reads.count; selection.language = reads.first?.language
            if command.isPresentation { summary.presentation = selection } else { summary.gear = selection }
        }
        if summary.mode == .drone { summary.gear.status = .notApplicable }
        return summary
    }
}

/// Whether a hack's command phase is still current while the node array is
/// fitted only from the cache, as when command strokes cover its rings.
/// Header text recognition runs behind the sampler on its own schedule, so
/// most frames carry no fresh reading: a frame without one is no evidence
/// against the phase. Readable header text of any other phase ends it at
/// once, and so does `leave` seconds without command evidence, so cached
/// geometry can never hold the watch through the cache's eight seconds.
///
/// A reading that recognised nothing (unknown, no matched text) ends the
/// phase too, unless a notice of this command window has been read: the
/// command screen's header is mostly unreadable while a command is drawn,
/// and a read notice shows that this is a command screen. Nothing else
/// tells such a window from an unreadable screen after a hack.
public struct CommandPhaseContext: Sendable {
    public var leave = CommandScreenWatch().leave
    private var evidenceAt: Double?
    /// Readable header text of another phase.
    private var contraryAt: Double?
    /// A header reading that recognised nothing.
    private var unreadAt: Double?
    /// The latest notice read with a value in the open command window.
    private var noticeReadAt: Double?
    public init() {}

    /// A header reading, by the source time of the frame it read.
    public mutating func header(_ reading: HeaderReading) {
        let sourceTime = reading.sourceTime
        guard sourceTime.isFinite else { return }
        if reading.phase == .command {
            evidenceAt = max(evidenceAt ?? sourceTime, sourceTime)
        } else if Self.isReadable(reading) {
            contraryAt = max(contraryAt ?? sourceTime, sourceTime)
        } else {
            unreadAt = max(unreadAt ?? sourceTime, sourceTime)
        }
    }

    /// A reading of `phase` without its text: an unknown one recognised nothing.
    public mutating func header(_ phase: GamePhase, at sourceTime: Double) {
        header(HeaderReading(phase: phase, matchedText: "", confidence: 0, sourceTime: sourceTime))
    }

    /// Whether a reading recognised header text. The phrase matcher leaves
    /// `matchedText` empty exactly when no phrase matched, as it is for an
    /// unreadable or missing crop; an unknown reading with text is two
    /// different phases' phrases at once, so readable non-command text.
    public static func isReadable(_ reading: HeaderReading) -> Bool {
        reading.phase != .unknown || !reading.matchedText.allSatisfy(\.isWhitespace)
    }

    /// A notice box on the analyzed frame at `time`: a command being entered.
    public mutating func notice(at time: Double) {
        guard time.isFinite else { return }
        evidenceAt = max(evidenceAt ?? time, time)
    }

    /// The open command window's latest notice read with a value, by its
    /// crop's source time (`CommandNoticeCapture.noticeReadAt`), or nil when
    /// it has none or has been bound, cancelled or invalidated. A read is
    /// command evidence; while there is one, readings that recognised
    /// nothing are no evidence against the phase.
    public mutating func noticeRead(at sourceTime: Double?) {
        guard let sourceTime, sourceTime.isFinite else { noticeReadAt = nil; return }
        noticeReadAt = sourceTime
        evidenceAt = max(evidenceAt ?? sourceTime, sourceTime)
    }

    public func isCurrent(at time: Double) -> Bool {
        guard let evidenceAt, time >= evidenceAt, time - evidenceAt <= leave else { return false }
        // Evidence on the same frame as a contrary reading is current.
        if let contraryAt, contraryAt > evidenceAt { return false }
        if noticeReadAt == nil, let unreadAt, unreadAt > evidenceAt { return false }
        return true
    }

    /// A clock epoch ended: old source times identify nothing on the new one.
    public mutating func reset() { evidenceAt = nil; contraryAt = nil; unreadAt = nil; noticeReadAt = nil }
}

/// Whether the command notice band is being watched, from each analyzed
/// frame. A calibration dropout shorter than `flicker`, as while a command is
/// drawn over the array, keeps watching; a longer absence loses coverage; an
/// absence of `leave` means the player left the hack's command window.
public struct CommandScreenWatch: Sendable {
    public enum Action: Equatable, Sendable { case none, interrupt, cancel }
    public var flicker = 0.5
    public var leave = 2.0
    public private(set) var watching = false
    private var calibratedAt: Double?
    private var lostAt: Double?
    public init() {}

    /// `commandPhase` is false while a hack is presented or drawn, or while the
    /// input timer shows. `complete` frames alone can show the screen left.
    public mutating func observe(at time: Double, calibrated: Bool, commandPhase: Bool,
                                 complete: Bool) -> Action {
        if calibrated { calibratedAt = time }
        let recent = calibratedAt.map { time >= $0 && time - $0 <= flicker } ?? false
        var action = Action.none
        if watching, !recent, complete { action = .interrupt; lostAt = time }
        if recent { lostAt = nil }
        else if let lost = lostAt, time - lost >= leave { action = .cancel; lostAt = nil }
        watching = recent && commandPhase
        return action
    }

    /// A gap in the frames: watching stops until the next analyzed frame.
    public mutating func stop() { watching = false }

    /// A clock epoch ended: old calibration/loss times must not re-arm the
    /// watch when the restarted clock later reaches those numeric values.
    public mutating func reset() {
        watching = false
        calibratedAt = nil
        lostAt = nil
    }
}
