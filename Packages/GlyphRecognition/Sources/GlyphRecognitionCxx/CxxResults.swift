import GlyphCoreCxx
import GlyphRecognition

// The C++ arm of the results area, over `glyph_logic_results.h`. Same inputs
// and outputs as the Swift types in `Sources/GlyphRecognition`; the rules run
// in C++. Each class wraps one handle: a reference type, so a copy shares its
// state, unlike the Swift structs. Not thread-safe: one serial queue owns
// each, as it owns the Swift value.

// MARK: - Result page text

/// The C++ `ResultTextParser`.
public final class CxxResultTextParser: ResultTextParsing {
    public let language: GameLanguage
    private let pointer: OpaquePointer

    public init(language: GameLanguage = .english) {
        self.language = language
        let tables = GameText(language).tables
        let created: OpaquePointer? = ResultArena.with { arena in
            let rows = tables.map { table in
                gl_result_text_table(code: arena.string(table.code), hackingLabel: arena.string(table.hackingLabel),
                                     speedLabel: arena.string(table.speedLabel))
            }
            return gl_result_parser_create(ResultValues.language(language), arena.array(rows), Int32(rows.count))
        }
        guard let created else { preconditionFailure("gl_result_parser_create refused the \(language) tables") }
        pointer = created
    }

    deinit { gl_result_parser_destroy(pointer) }

    public func read(lines: [ResultTextLine], context: ResultReadContext, at time: Double,
                     appearances: [ResultSlotAppearance] = []) -> ResultFrameEvidence {
        ResultArena.with { arena in
            var coreContext = ResultValues.context(context, arena)
            let coreLines = lines.map { ResultValues.line($0, arena) }
            let coreAppearances = appearances.map(ResultValues.appearance)
            var out = gl_result_evidence()
            guard gl_result_parser_read(pointer, arena.array(coreLines), Int32(coreLines.count), &coreContext, time,
                                        arena.array(coreAppearances), Int32(coreAppearances.count), &out) else {
                preconditionFailure("gl_result_parser_read refused its input")
            }
            return ResultValues.evidence(out)
        }
    }
}

// MARK: - Hack result and comparison

/// The C++ `HackResultTracker`. Also what `CxxResultObservationSession.tracker`
/// hands out: a value of the session's tracker, which later calls on the
/// session do not change.
public final class CxxHackResultTracker: HackResultTracking {
    fileprivate let pointer: OpaquePointer

    public init(context: ResultReadContext, policy: HackResultTracker.Policy = HackResultTracker.Policy()) {
        var corePolicy = gl_result_tracker_policy(minimumSpan: policy.minimumSpan,
                                                  maximumReadingGap: policy.maximumReadingGap,
                                                  panelExitSpan: policy.panelExitSpan, resultWait: policy.resultWait)
        let created: OpaquePointer? = ResultArena.with { arena in
            var coreContext = ResultValues.context(context, arena)
            return gl_result_tracker_create(&coreContext, &corePolicy)
        }
        guard let created else { preconditionFailure("gl_result_tracker_create refused its context") }
        pointer = created
    }

    fileprivate init(pointer: OpaquePointer) { self.pointer = pointer }

    deinit { gl_result_tracker_destroy(pointer) }

    public var result: HackResult {
        var out = gl_result_hack()
        guard gl_result_tracker_result(pointer, &out) else { preconditionFailure("gl_result_tracker_result failed") }
        return ResultValues.hack(out)
    }

    public var revision: Int { Int(gl_result_tracker_revision(pointer)) }

    @discardableResult
    public func accept(_ evidence: ResultFrameEvidence) -> Bool {
        ResultArena.with { arena in
            var coreEvidence = ResultValues.evidence(evidence, arena)
            return gl_result_tracker_accept(pointer, &coreEvidence)
        }
    }

    public func observeFrame(at time: Double, inputVisible: Bool, exitVisible: Bool, panelCandidate: Bool) {
        gl_result_tracker_observe_frame(pointer, time, inputVisible, exitVisible, panelCandidate)
    }

    public func finish(at time: Double, reason: String) {
        ResultArena.with { arena in gl_result_tracker_finish(pointer, time, arena.string(reason)) }
    }
}

/// The C++ `ValidatorResultComparison`. Also what
/// `CxxResultObservationSession.comparison` hands out, as a value.
public final class CxxValidatorResultComparison: ValidatorResultComparing {
    fileprivate let pointer: OpaquePointer

    public init(context: ResultReadContext) {
        let created: OpaquePointer? = ResultArena.with { arena in
            var coreContext = ResultValues.context(context, arena)
            return gl_result_comparison_create(&coreContext)
        }
        guard let created else { preconditionFailure("gl_result_comparison_create refused its context") }
        pointer = created
    }

    fileprivate init(pointer: OpaquePointer) { self.pointer = pointer }

    deinit { gl_result_comparison_destroy(pointer) }

    public var supersededAttemptIDs: Set<Int> {
        var ids: UnsafePointer<Int64>?
        var count: Int32 = 0
        guard gl_result_comparison_superseded(pointer, &ids, &count) else { return [] }
        return Set(ResultValues.buffer(ids, count).map { Int($0) })
    }

    public func observe(_ evidence: FrameEvidence, inputVisible: Bool) {
        var frame = ResultValues.frame(evidence)
        gl_result_comparison_observe(pointer, &frame, inputVisible)
    }

    public func accept(_ events: [InputCheckEvent]) {
        ResultArena.with { arena in
            let coreEvents = events.map { ResultValues.event($0, arena) }
            gl_result_comparison_accept(pointer, arena.array(coreEvents), Int32(coreEvents.count))
        }
    }

    public func compare(_ result: HackResult) -> [ValidatorResultComparison.Entry] {
        ResultArena.with { arena in
            var coreResult = ResultValues.hack(result, arena)
            var entries: UnsafePointer<gl_result_entry>?
            var count: Int32 = 0
            guard gl_result_comparison_compare(pointer, &coreResult, &entries, &count) else {
                preconditionFailure("gl_result_comparison_compare refused its result")
            }
            return ResultValues.buffer(entries, count).map(ResultValues.entry)
        }
    }
}

// MARK: - Session

/// The C++ `ResultObservationSession`.
public final class CxxResultObservationSession: ResultObserving {
    private let pointer: OpaquePointer
    private let indexByName: [String: Int32]

    /// `glyphs` is the Glyph table's name-sorted list (`GlyphTable.glyphs`),
    /// which the presentation tracker's slots are looked up in.
    public init(glyphs: [GlyphID]) {
        var index: [String: Int32] = [:]
        for (position, glyph) in glyphs.enumerated() where index[glyph.name] == nil { index[glyph.name] = Int32(position) }
        indexByName = index
        let created: OpaquePointer? = ResultArena.with { arena in
            let names = glyphs.map { arena.string($0.name) }
            return gl_result_session_create(arena.array(names), Int32(names.count))
        }
        guard let created else { preconditionFailure("gl_result_session_create refused \(glyphs.count) Glyphs") }
        pointer = created
    }

    private init(pointer: OpaquePointer, indexByName: [String: Int32]) {
        self.pointer = pointer
        self.indexByName = indexByName
    }

    deinit { gl_result_session_destroy(pointer) }

    /// A separate session with this one's state, as `var copy = session` is
    /// for the Swift struct.
    public func copy() -> CxxResultObservationSession {
        guard let created = gl_result_session_create_copy(pointer) else {
            preconditionFailure("gl_result_session_create_copy failed")
        }
        return CxxResultObservationSession(pointer: created, indexByName: indexByName)
    }

    /// As assigning `ResultObservationSession()`.
    public func reset() { gl_result_session_reset(pointer) }

    public var context: ResultReadContext? {
        var out = gl_result_context()
        guard gl_result_session_context(pointer, &out) else { return nil }
        return ResultValues.context(out)
    }

    public var tracker: CxxHackResultTracker? {
        gl_result_tracker_create_from_session(pointer).map { CxxHackResultTracker(pointer: $0) }
    }

    public var comparison: CxxValidatorResultComparison? {
        gl_result_comparison_create_from_session(pointer).map { CxxValidatorResultComparison(pointer: $0) }
    }

    public func observe(_ evidence: FrameEvidence, presentation: some PresentationTracking, panelCandidate: Bool,
                        imageAnalyzed: Bool = true, commands: HackCommandSummary? = nil) -> HackResult? {
        observe(evidence, state: presentation.state, hackID: presentation.hackID,
                expectedSlotCount: presentation.expectedSlotCount, slots: presentation.slots,
                unknownPhaseGrace: presentation.policy.unknownPhaseGrace, panelCandidate: panelCandidate,
                imageAnalyzed: imageAnalyzed, commands: commands)
    }

    /// The same, with the presentation tracker's values given directly, so any
    /// tracker arm can supply them.
    public func observe(_ evidence: FrameEvidence, state: TrackingState, hackID: Int, expectedSlotCount: Int?,
                        slots: [SlotObservation], unknownPhaseGrace: Double, panelCandidate: Bool,
                        imageAnalyzed: Bool = true, commands: HackCommandSummary? = nil) -> HackResult? {
        ResultArena.with { arena in
            var frame = ResultValues.frame(evidence)
            let coreSlots = slots.map { slot in
                gl_result_slot(index: Int64(slot.index), status: ResultValues.slotStatus(slot.status),
                               glyph: slot.glyph.flatMap { indexByName[$0.name] } ?? -1)
            }
            var presentation = gl_result_presentation(
                state: ResultValues.trackingState(state), hackID: Int64(hackID),
                expectedSlotCount: ResultValues.optional(expectedSlotCount), slots: arena.array(coreSlots),
                slotCount: Int32(coreSlots.count), unknownPhaseGrace: unknownPhaseGrace)
            var coreCommands = commands.map { ResultValues.commands($0, arena) } ?? gl_result_commands()
            var retired = gl_result_hack()
            let didRetire = withUnsafePointer(to: &coreCommands) { commandsPointer in
                gl_result_session_observe(pointer, &frame, &presentation, panelCandidate, imageAnalyzed,
                                          commands == nil ? nil : commandsPointer, &retired)
            }
            return didRetire ? ResultValues.hack(retired) : nil
        }
    }

    public func accept(_ evidence: ResultFrameEvidence) {
        ResultArena.with { arena in
            var coreEvidence = ResultValues.evidence(evidence, arena)
            gl_result_session_accept_evidence(pointer, &coreEvidence)
        }
    }

    public func accept(_ events: [InputCheckEvent]) {
        ResultArena.with { arena in
            let coreEvents = events.map { ResultValues.event($0, arena) }
            gl_result_session_accept_events(pointer, arena.array(coreEvents), Int32(coreEvents.count))
        }
    }

    public func finish(at time: Double, reason: String) {
        ResultArena.with { arena in gl_result_session_finish(pointer, time, arena.string(reason)) }
    }
}

// MARK: - Schedule and command watch

/// The C++ `ResultEvidenceSchedule`.
public final class CxxResultEvidenceSchedule: ResultEvidenceScheduling {
    private let pointer: OpaquePointer

    public init() {
        guard let created = gl_result_schedule_create() else { preconditionFailure("gl_result_schedule_create failed") }
        pointer = created
    }

    deinit { gl_result_schedule_destroy(pointer) }

    /// As assigning `ResultEvidenceSchedule()`.
    public func reset() { gl_result_schedule_reset(pointer) }

    public func select(_ evidence: ResultFrameEvidence, decision: Bool) -> ResultEvidenceSchedule.Selection? {
        let selection = ResultArena.with { arena in
            var coreEvidence = ResultValues.evidence(evidence, arena)
            return gl_result_schedule_select(pointer, &coreEvidence, decision)
        }
        switch selection {
        case GL_RESULT_SCHEDULE_DETECTION: return .detection
        case GL_RESULT_SCHEDULE_ANIMATION: return .animation
        case GL_RESULT_SCHEDULE_DECISION: return .decision
        case GL_RESULT_SCHEDULE_BUDGET_EXHAUSTED: return .budgetExhausted
        default: return nil
        }
    }
}

/// The C++ `CommandScreenWatch`.
public final class CxxCommandScreenWatch: CommandScreenWatching {
    private let pointer: OpaquePointer

    public init(flicker: Double = 0.5, leave: Double = 2.0) {
        guard let created = gl_command_watch_create(flicker, leave) else {
            preconditionFailure("gl_command_watch_create failed")
        }
        pointer = created
    }

    deinit { gl_command_watch_destroy(pointer) }

    public var watching: Bool { gl_command_watch_watching(pointer) }

    public func observe(at time: Double, calibrated: Bool, commandPhase: Bool,
                        complete: Bool) -> CommandScreenWatch.Action {
        switch gl_command_watch_observe(pointer, time, calibrated, commandPhase, complete) {
        case GL_COMMAND_WATCH_ACTION_INTERRUPT: return .interrupt
        case GL_COMMAND_WATCH_ACTION_CANCEL: return .cancel
        default: return .none
        }
    }

    public func stop() { gl_command_watch_stop(pointer) }

    public func reset() { gl_command_watch_reset(pointer) }
}

/// `CommandPhaseContext` in C++.
public final class CxxCommandPhaseContext: CommandPhaseContexting {
    private let pointer: OpaquePointer

    public init(leave: Double = CommandScreenWatch().leave) {
        guard let created = gl_command_context_create(leave) else {
            preconditionFailure("gl_command_context_create failed")
        }
        pointer = created
    }

    deinit { gl_command_context_destroy(pointer) }

    public var leave: Double {
        get { gl_command_context_leave(pointer) }
        set { gl_command_context_set_leave(pointer, newValue) }
    }

    public func header(_ reading: HeaderReading) {
        ResultArena.with { arena in
            gl_command_context_header(pointer, ResultValues.phase(reading.phase), arena.string(reading.matchedText),
                                      reading.sourceTime)
        }
    }

    public static func isReadable(_ reading: HeaderReading) -> Bool {
        ResultArena.with { arena in
            gl_command_context_is_readable(ResultValues.phase(reading.phase), arena.string(reading.matchedText))
        }
    }

    public func notice(at time: Double) { gl_command_context_notice(pointer, time) }

    public func noticeRead(at sourceTime: Double?) {
        gl_command_context_notice_read(pointer, gc_opt_double(has: sourceTime != nil, value: sourceTime ?? 0))
    }

    public func isCurrent(at time: Double) -> Bool { gl_command_context_is_current(pointer, time) }

    public func reset() { gl_command_context_reset(pointer) }
}

// MARK: - Summary and its presentation

/// `HackResultSummary(result:comparison:)` and the decisions of its
/// presentation, made in C++. The wording stays in Swift's string catalog.
public enum CxxHackResultSummary {
    /// Which `HackResultSummary.headline` a summary shows.
    public enum Headline: Sendable, Equatable {
        case awaiting, complete, partial, stoppedBeforeResult, noResultScreen
    }

    public static func make(result: HackResult, comparison: [ValidatorResultComparison.Entry]) -> HackResultSummary {
        ResultArena.with { arena in
            withSummary(result, comparison, arena) { ResultValues.summary($0) }
        }
    }

    public static func headline(result: HackResult, comparison: [ValidatorResultComparison.Entry]) -> Headline {
        ResultArena.with { arena in
            withSummary(result, comparison, arena) { summary in
                var value = summary
                switch gl_result_summary_headline(&value) {
                case GL_RESULT_HEADLINE_COMPLETE: return .complete
                case GL_RESULT_HEADLINE_PARTIAL: return .partial
                case GL_RESULT_HEADLINE_STOPPED_BEFORE_RESULT: return .stoppedBeforeResult
                case GL_RESULT_HEADLINE_NO_RESULT_SCREEN: return .noResultScreen
                default: return .awaiting
                }
            }
        }
    }

    public static func hasProvisionalBonus(result: HackResult, comparison: [ValidatorResultComparison.Entry]) -> Bool {
        ResultArena.with { arena in
            withSummary(result, comparison, arena) { summary in
                var value = summary
                return gl_result_summary_has_provisional_bonus(&value)
            }
        }
    }

    /// The slots `disagreementLines` lists, in order.
    public static func disagreements(result: HackResult, comparison: [ValidatorResultComparison.Entry]) -> [Int] {
        ResultArena.with { arena in
            withSummary(result, comparison, arena) { summary in
                var value = summary
                var indices = [Int32](repeating: 0, count: max(1, Int(summary.slotCount)))
                let count = indices.withUnsafeMutableBufferPointer { buffer in
                    gl_result_summary_disagreements(&value, buffer.baseAddress, Int32(buffer.count))
                }
                return indices.prefix(max(0, Int(count))).map { Int($0) }
            }
        }
    }

    /// `HackCommandSummary.Selection.effective`.
    public static func effective(_ selection: HackCommandSummary.Selection) -> HackCommand? {
        ResultArena.with { arena in
            var value = ResultValues.selection(selection, arena)
            return ResultValues.command(gl_result_command_effective(&value))
        }
    }

    private static func withSummary<T>(_ result: HackResult, _ comparison: [ValidatorResultComparison.Entry],
                                       _ arena: ResultArena, _ body: (gl_result_summary) -> T) -> T {
        var coreResult = ResultValues.hack(result, arena)
        let entries = comparison.map(ResultValues.entry)
        var slots = [gl_result_summary_slot](repeating: gl_result_summary_slot(), count: max(1, result.outcomes.count))
        var summary = gl_result_summary()
        let count = slots.withUnsafeMutableBufferPointer { buffer in
            gl_result_summary_make(&coreResult, arena.array(entries), Int32(entries.count), &summary,
                                   buffer.baseAddress, Int32(buffer.count))
        }
        guard count >= 0, count <= Int32(slots.count) else { preconditionFailure("gl_result_summary_make failed") }
        return slots.withUnsafeBufferPointer { buffer in
            summary.slots = summary.slotCount > 0 ? buffer.baseAddress : nil
            return body(summary)
        }
    }
}

// MARK: - Values across the ABI

/// Memory for one call's arguments: strings and arrays the C++ side reads
/// during the call and copies. Freed when the call returns.
final class ResultArena {
    private var allocations: [UnsafeMutableRawPointer] = []

    static func with<T>(_ body: (ResultArena) -> T) -> T {
        let arena = ResultArena()
        return withExtendedLifetime(arena) { body(arena) }
    }

    deinit { for allocation in allocations { allocation.deallocate() } }

    func string(_ text: String) -> gc_string {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return gc_string(bytes: nil, length: 0) }
        let storage = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        bytes.withUnsafeBytes { raw in
            UnsafeMutableRawPointer(storage).copyMemory(from: raw.baseAddress!, byteCount: bytes.count)
        }
        allocations.append(UnsafeMutableRawPointer(storage))
        return gc_string(bytes: storage, length: Int32(bytes.count))
    }

    func optionalString(_ text: String?) -> gl_result_opt_string {
        text.map { gl_result_opt_string(has: true, value: string($0)) }
            ?? gl_result_opt_string(has: false, value: gc_string(bytes: nil, length: 0))
    }

    /// The C structs passed here are plain values, so the memory needs no
    /// deinitialization.
    func array<T>(_ values: [T]) -> UnsafePointer<T>? {
        guard !values.isEmpty else { return nil }
        let storage = UnsafeMutablePointer<T>.allocate(capacity: values.count)
        storage.initialize(from: values, count: values.count)
        allocations.append(UnsafeMutableRawPointer(storage))
        return UnsafePointer(storage)
    }
}

enum ResultValues {
    static func buffer<T>(_ pointer: UnsafePointer<T>?, _ count: Int32) -> UnsafeBufferPointer<T> {
        guard let pointer, count > 0 else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: pointer, count: Int(count))
    }

    static func string(_ text: gc_string) -> String {
        guard let bytes = text.bytes, text.length > 0 else { return "" }
        return bytes.withMemoryRebound(to: UInt8.self, capacity: Int(text.length)) {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(text.length)), as: UTF8.self)
        }
    }

    static func string(_ text: gl_result_opt_string) -> String? { text.has ? string(text.value) : nil }

    static func optional(_ value: Int?) -> gl_result_opt_int {
        gl_result_opt_int(has: value != nil, value: Int64(value ?? 0))
    }

    static func optional(_ value: Double?) -> gc_opt_double { gc_opt_double(has: value != nil, value: value ?? 0) }

    static func int(_ value: gl_result_opt_int) -> Int? { value.has ? Int(value.value) : nil }

    static func double(_ value: gc_opt_double) -> Double? { value.has ? value.value : nil }

    // Enums

    static func language(_ language: GameLanguage) -> gc_language {
        switch language {
        case .english: return GC_LANGUAGE_ENGLISH
        case .simplifiedChinese: return GC_LANGUAGE_SIMPLIFIED_CHINESE
        case .traditionalChinese: return GC_LANGUAGE_TRADITIONAL_CHINESE
        case .japanese: return GC_LANGUAGE_JAPANESE
        case .korean: return GC_LANGUAGE_KOREAN
        }
    }

    static func language(_ language: gc_language) -> GameLanguage {
        switch language {
        case GC_LANGUAGE_SIMPLIFIED_CHINESE: return .simplifiedChinese
        case GC_LANGUAGE_TRADITIONAL_CHINESE: return .traditionalChinese
        case GC_LANGUAGE_JAPANESE: return .japanese
        case GC_LANGUAGE_KOREAN: return .korean
        default: return .english
        }
    }

    static func appearance(_ appearance: ResultSlotAppearance) -> gl_result_appearance {
        switch appearance {
        case .gold: return GL_RESULT_APPEARANCE_GOLD
        case .magenta: return GL_RESULT_APPEARANCE_MAGENTA
        case .unreadable: return GL_RESULT_APPEARANCE_UNREADABLE
        }
    }

    static func appearance(_ appearance: gl_result_appearance) -> ResultSlotAppearance {
        switch appearance {
        case GL_RESULT_APPEARANCE_GOLD: return .gold
        case GL_RESULT_APPEARANCE_MAGENTA: return .magenta
        default: return .unreadable
        }
    }

    static func outcome(_ outcome: GameSlotOutcome) -> gl_result_outcome {
        switch outcome {
        case .accepted: return GL_RESULT_OUTCOME_ACCEPTED
        case .rejected: return GL_RESULT_OUTCOME_REJECTED
        case .unknown: return GL_RESULT_OUTCOME_UNKNOWN
        }
    }

    static func outcome(_ outcome: gl_result_outcome) -> GameSlotOutcome {
        switch outcome {
        case GL_RESULT_OUTCOME_ACCEPTED: return .accepted
        case GL_RESULT_OUTCOME_REJECTED: return .rejected
        default: return .unknown
        }
    }

    static func state(_ state: HackResult.State) -> gl_result_state {
        switch state {
        case .awaiting: return GL_RESULT_STATE_AWAITING
        case .partial: return GL_RESULT_STATE_PARTIAL
        case .complete: return GL_RESULT_STATE_COMPLETE
        case .notObserved: return GL_RESULT_STATE_NOT_OBSERVED
        }
    }

    static func state(_ state: gl_result_state) -> HackResult.State {
        switch state {
        case GL_RESULT_STATE_PARTIAL: return .partial
        case GL_RESULT_STATE_COMPLETE: return .complete
        case GL_RESULT_STATE_NOT_OBSERVED: return .notObserved
        default: return .awaiting
        }
    }

    static func verdict(_ verdict: InputCheckVerdict?) -> gl_result_verdict {
        switch verdict {
        case .matched: return GL_RESULT_VERDICT_MATCHED
        case .differs: return GL_RESULT_VERDICT_DIFFERS
        case .unavailable: return GL_RESULT_VERDICT_UNAVAILABLE
        case nil: return GL_RESULT_VERDICT_NONE
        }
    }

    static func verdict(_ verdict: gl_result_verdict) -> InputCheckVerdict? {
        switch verdict {
        case GL_RESULT_VERDICT_MATCHED: return .matched
        case GL_RESULT_VERDICT_DIFFERS: return .differs
        case GL_RESULT_VERDICT_UNAVAILABLE: return .unavailable
        default: return nil
        }
    }

    static func status(_ status: ValidatorResultComparison.Status) -> gl_result_status {
        switch status {
        case .agreement: return GL_RESULT_STATUS_AGREEMENT
        case .disagreement: return GL_RESULT_STATUS_DISAGREEMENT
        case .coverageGap: return GL_RESULT_STATUS_COVERAGE_GAP
        case .unknownAssociation: return GL_RESULT_STATUS_UNKNOWN_ASSOCIATION
        case .unknownGameOutcome: return GL_RESULT_STATUS_UNKNOWN_GAME_OUTCOME
        }
    }

    static func status(_ status: gl_result_status) -> ValidatorResultComparison.Status {
        switch status {
        case GL_RESULT_STATUS_AGREEMENT: return .agreement
        case GL_RESULT_STATUS_DISAGREEMENT: return .disagreement
        case GL_RESULT_STATUS_COVERAGE_GAP: return .coverageGap
        case GL_RESULT_STATUS_UNKNOWN_GAME_OUTCOME: return .unknownGameOutcome
        default: return .unknownAssociation
        }
    }

    static func command(_ command: HackCommand?) -> gl_result_command {
        switch command {
        case .simple: return GL_RESULT_COMMAND_SIMPLE
        case .complex: return GL_RESULT_COMMAND_COMPLEX
        case .requestKey: return GL_RESULT_COMMAND_REQUEST_KEY
        case .noKey: return GL_RESULT_COMMAND_NO_KEY
        case .keysOnly: return GL_RESULT_COMMAND_KEYS_ONLY
        case nil: return GL_RESULT_COMMAND_NONE
        }
    }

    static func command(_ command: gl_result_command) -> HackCommand? {
        switch command {
        case GL_RESULT_COMMAND_SIMPLE: return .simple
        case GL_RESULT_COMMAND_COMPLEX: return .complex
        case GL_RESULT_COMMAND_REQUEST_KEY: return .requestKey
        case GL_RESULT_COMMAND_NO_KEY: return .noKey
        case GL_RESULT_COMMAND_KEYS_ONLY: return .keysOnly
        default: return nil
        }
    }

    static func selectionStatus(_ status: HackCommandSummary.Selection.Status) -> gl_result_selection_status {
        switch status {
        case .noCommandObserved: return GL_RESULT_SELECTION_NO_COMMAND_OBSERVED
        case .confirmed: return GL_RESULT_SELECTION_CONFIRMED
        case .unresolved: return GL_RESULT_SELECTION_UNRESOLVED
        case .notApplicable: return GL_RESULT_SELECTION_NOT_APPLICABLE
        }
    }

    static func selectionStatus(_ status: gl_result_selection_status) -> HackCommandSummary.Selection.Status {
        switch status {
        case GL_RESULT_SELECTION_CONFIRMED: return .confirmed
        case GL_RESULT_SELECTION_UNRESOLVED: return .unresolved
        case GL_RESULT_SELECTION_NOT_APPLICABLE: return .notApplicable
        default: return .noCommandObserved
        }
    }

    static func mode(_ mode: HackCommandSummary.Mode) -> gl_result_command_mode {
        switch mode {
        case .unknown: return GL_RESULT_COMMAND_MODE_UNKNOWN
        case .portal: return GL_RESULT_COMMAND_MODE_PORTAL
        case .drone: return GL_RESULT_COMMAND_MODE_DRONE
        }
    }

    static func mode(_ mode: gl_result_command_mode) -> HackCommandSummary.Mode {
        switch mode {
        case GL_RESULT_COMMAND_MODE_PORTAL: return .portal
        case GL_RESULT_COMMAND_MODE_DRONE: return .drone
        default: return .unknown
        }
    }

    static func eventKind(_ kind: InputCheckEvent.Kind) -> gl_result_event_kind {
        switch kind {
        case .started: return GL_RESULT_EVENT_STARTED
        case .drawingSample: return GL_RESULT_EVENT_DRAWING_SAMPLE
        case .lifted: return GL_RESULT_EVENT_LIFTED
        case .sample: return GL_RESULT_EVENT_SAMPLE
        case .verdict: return GL_RESULT_EVENT_VERDICT
        case .finished: return GL_RESULT_EVENT_FINISHED
        case .unchecked: return GL_RESULT_EVENT_UNCHECKED
        }
    }

    static func phase(_ phase: GamePhase) -> gl_result_phase {
        switch phase {
        case .unknown: return GL_RESULT_PHASE_UNKNOWN
        case .command: return GL_RESULT_PHASE_COMMAND
        case .presenting: return GL_RESULT_PHASE_PRESENTING
        case .input: return GL_RESULT_PHASE_INPUT
        case .completed: return GL_RESULT_PHASE_COMPLETED
        }
    }

    static func rejection(_ rejection: SlotStripRejection?) -> gl_result_rejection {
        switch rejection {
        case nil: return GL_RESULT_REJECTION_NONE
        case .bandUnavailable: return GL_RESULT_REJECTION_BAND_UNAVAILABLE
        case .noMarkers: return GL_RESULT_REJECTION_NO_MARKERS
        case .tooManyMarkers: return GL_RESULT_REJECTION_TOO_MANY_MARKERS
        case .unevenSpacing: return GL_RESULT_REJECTION_UNEVEN_SPACING
        case .inconsistentMarkerWidths: return GL_RESULT_REJECTION_INCONSISTENT_MARKER_WIDTHS
        case .multipleHighlights: return GL_RESULT_REJECTION_MULTIPLE_HIGHLIGHTS
        case .incompleteMarkerHeight: return GL_RESULT_REJECTION_INCOMPLETE_MARKER_HEIGHT
        case .incompleteStrip: return GL_RESULT_REJECTION_INCOMPLETE_STRIP
        case .coveredByOverlay: return GL_RESULT_REJECTION_COVERED_BY_OVERLAY
        }
    }

    static func trackingState(_ state: TrackingState) -> gl_result_tracking_state {
        switch state {
        case .inactive: return GL_RESULT_TRACKING_INACTIVE
        case .command: return GL_RESULT_TRACKING_COMMAND
        case .presenting: return GL_RESULT_TRACKING_PRESENTING
        case .input: return GL_RESULT_TRACKING_INPUT
        case .completed: return GL_RESULT_TRACKING_COMPLETED
        case .interrupted: return GL_RESULT_TRACKING_INTERRUPTED
        }
    }

    static func slotStatus(_ status: SlotObservation.Status) -> gl_result_slot_status {
        switch status {
        case .pending: return GL_RESULT_SLOT_PENDING
        case .observing: return GL_RESULT_SLOT_OBSERVING
        case .confirmed: return GL_RESULT_SLOT_CONFIRMED
        case .inferred: return GL_RESULT_SLOT_INFERRED
        case .missing: return GL_RESULT_SLOT_MISSING
        case .uncertain: return GL_RESULT_SLOT_UNCERTAIN
        }
    }

    // Swift to C, for the duration of one call

    static func selection(_ selection: HackCommandSummary.Selection, _ arena: ResultArena) -> gl_result_command_selection {
        gl_result_command_selection(status: selectionStatus(selection.status), lastObserved: command(selection.lastObserved),
                                    samples: Int64(selection.samples), language: arena.optionalString(selection.language))
    }

    static func commands(_ commands: HackCommandSummary, _ arena: ResultArena) -> gl_result_commands {
        gl_result_commands(presentation: selection(commands.presentation, arena), gear: selection(commands.gear, arena),
                           mode: mode(commands.mode))
    }

    static func context(_ context: ResultReadContext, _ arena: ResultArena) -> gl_result_context {
        let glyphs = context.glyphs.map(arena.optionalString)
        return gl_result_context(sessionID: context.sessionID.rawValue, hackID: Int64(context.hackID),
                                 glyphs: arena.array(glyphs), glyphCount: Int32(glyphs.count),
                                 hasCommands: context.commands != nil,
                                 commands: context.commands.map { commands($0, arena) } ?? gl_result_commands())
    }

    static func line(_ line: ResultTextLine, _ arena: ResultArena) -> gl_result_line {
        gl_result_line(text: arena.string(line.text), confidence: line.confidence, x: line.x, y: line.y,
                       width: line.width, height: line.height)
    }

    static func evidence(_ evidence: ResultFrameEvidence, _ arena: ResultArena) -> gl_result_evidence {
        let appearances = evidence.appearances.map(appearance)
        let lines = evidence.lines.map { line($0, arena) }
        return gl_result_evidence(
            context: context(evidence.context, arena), sourceTime: evidence.sourceTime,
            panelPresent: evidence.panelPresent, stageIndex: optional(evidence.stageIndex),
            hackingBonus: optional(evidence.hackingBonus), speedBonus: optional(evidence.speedBonus),
            appearances: arena.array(appearances), appearanceCount: Int32(appearances.count),
            lines: arena.array(lines), lineCount: Int32(lines.count),
            hasLabelLanguage: evidence.labelLanguage != nil,
            labelLanguage: evidence.labelLanguage.map(language) ?? GC_LANGUAGE_ENGLISH)
    }

    static func hack(_ result: HackResult, _ arena: ResultArena) -> gl_result_hack {
        let outcomes = result.outcomes.map(outcome)
        // Swift keeps the two arrays the same length; the ABI has one count.
        let times = (0..<outcomes.count).map { index in
            optional(index < result.outcomeTimes.count ? result.outcomeTimes[index] : nil)
        }
        return gl_result_hack(
            context: context(result.context, arena), state: state(result.state),
            firstPanelTime: optional(result.firstPanelTime), lastPanelTime: optional(result.lastPanelTime),
            finalStageTime: optional(result.finalStageTime),
            observedHackingBonus: optional(result.observedHackingBonus),
            observedSpeedBonus: optional(result.observedSpeedBonus),
            finalHackingBonus: optional(result.finalHackingBonus), finalSpeedBonus: optional(result.finalSpeedBonus),
            outcomes: arena.array(outcomes), outcomeTimes: arena.array(times), outcomeCount: Int32(outcomes.count),
            closedAt: optional(result.closedAt), closeReason: arena.optionalString(result.closeReason),
            inputStartedAt: optional(result.inputStartedAt), inputEndedAt: optional(result.inputEndedAt),
            inputSeconds: optional(result.inputSeconds))
    }

    static func frame(_ evidence: FrameEvidence) -> gl_result_frame {
        gl_result_frame(
            sessionID: evidence.sessionID.rawValue, time: evidence.time, hasHeader: evidence.header != nil,
            headerPhase: phase(evidence.header?.phase ?? .unknown), headerSourceTime: evidence.header?.sourceTime ?? 0,
            hasSlots: evidence.slots != nil, slotCount: Int64(evidence.slots?.slotCount ?? 0),
            highlightedIndex: optional(evidence.slots?.highlightedIndex), slotRejection: rejection(evidence.slotRejection),
            hasInputTimerBar: evidence.hasInputTimerBar)
    }

    static func event(_ event: InputCheckEvent, _ arena: ResultArena) -> gl_result_check_event {
        let check = event.result.map { result in
            gl_result_check(sessionID: result.sessionID.rawValue, expectedGlyph: arena.string(result.expectedGlyph.name),
                            verdict: verdict(result.verdict), startTime: optional(result.startTime),
                            liftTime: optional(result.liftTime))
        }
        return gl_result_check_event(
            kind: eventKind(event.kind), time: event.time, hackID: Int64(event.hackID),
            slotIndex: Int64(event.slotIndex), attemptID: Int64(event.attemptID), hasReason: event.reason != nil,
            hasResult: check != nil, result: check ?? gl_result_check())
    }

    static func entry(_ entry: ValidatorResultComparison.Entry) -> gl_result_entry {
        gl_result_entry(slotIndex: Int64(entry.slotIndex), attemptID: optional(entry.attemptID),
                        validatorVerdict: verdict(entry.validatorVerdict), gameOutcome: outcome(entry.gameOutcome),
                        status: status(entry.status), drawSeconds: optional(entry.drawSeconds))
    }

    // C to Swift

    static func selection(_ selection: gl_result_command_selection) -> HackCommandSummary.Selection {
        var value = HackCommandSummary.Selection()
        value.status = selectionStatus(selection.status)
        value.lastObserved = command(selection.lastObserved)
        value.samples = Int(selection.samples)
        value.language = string(selection.language)
        return value
    }

    static func commands(_ commands: gl_result_commands) -> HackCommandSummary {
        var value = HackCommandSummary()
        value.presentation = selection(commands.presentation)
        value.gear = selection(commands.gear)
        value.mode = mode(commands.mode)
        return value
    }

    static func context(_ context: gl_result_context) -> ResultReadContext {
        ResultReadContext(sessionID: CaptureSessionID(rawValue: context.sessionID), hackID: Int(context.hackID),
                          glyphs: buffer(context.glyphs, context.glyphCount).map(string),
                          commands: context.hasCommands ? commands(context.commands) : nil)
    }

    static func evidence(_ evidence: gl_result_evidence) -> ResultFrameEvidence {
        ResultFrameEvidence(
            context: context(evidence.context), sourceTime: evidence.sourceTime, panelPresent: evidence.panelPresent,
            stageIndex: int(evidence.stageIndex), hackingBonus: int(evidence.hackingBonus),
            speedBonus: int(evidence.speedBonus),
            appearances: buffer(evidence.appearances, evidence.appearanceCount).map(appearance),
            lines: buffer(evidence.lines, evidence.lineCount).map { line in
                ResultTextLine(text: string(line.text), confidence: line.confidence, x: line.x, y: line.y,
                               width: line.width, height: line.height)
            },
            labelLanguage: evidence.hasLabelLanguage ? language(evidence.labelLanguage) : nil)
    }

    static func hack(_ hack: gl_result_hack) -> HackResult {
        // `HackResult` has no public initializer; a fresh tracker's result is
        // the one way to make one outside its module, and every other field
        // is a public `var`.
        var result = HackResultTracker(context: context(hack.context)).result
        result.state = state(hack.state)
        result.firstPanelTime = double(hack.firstPanelTime)
        result.lastPanelTime = double(hack.lastPanelTime)
        result.finalStageTime = double(hack.finalStageTime)
        result.observedHackingBonus = int(hack.observedHackingBonus)
        result.observedSpeedBonus = int(hack.observedSpeedBonus)
        result.finalHackingBonus = int(hack.finalHackingBonus)
        result.finalSpeedBonus = int(hack.finalSpeedBonus)
        result.outcomes = buffer(hack.outcomes, hack.outcomeCount).map(outcome)
        result.outcomeTimes = buffer(hack.outcomeTimes, hack.outcomeCount).map(double)
        result.closedAt = double(hack.closedAt)
        result.closeReason = string(hack.closeReason)
        result.inputStartedAt = double(hack.inputStartedAt)
        result.inputEndedAt = double(hack.inputEndedAt)
        return result
    }

    static func entry(_ entry: gl_result_entry) -> ValidatorResultComparison.Entry {
        ValidatorResultComparison.Entry(slotIndex: Int(entry.slotIndex), attemptID: int(entry.attemptID),
                                        verdict: verdict(entry.validatorVerdict),
                                        outcome: outcome(entry.gameOutcome), status: status(entry.status),
                                        drawSeconds: double(entry.drawSeconds))
    }

    static func summary(_ summary: gl_result_summary) -> HackResultSummary {
        func bonus(_ bonus: gl_result_bonus) -> HackResultSummary.Bonus? {
            bonus.has ? HackResultSummary.Bonus(percent: Int(bonus.percent), isFinal: bonus.isFinal) : nil
        }
        return HackResultSummary(
            captureSessionID: summary.captureSessionID, hackID: Int(summary.hackID), state: state(summary.state),
            isClosed: summary.isClosed, closeReason: string(summary.closeReason),
            hackingBonus: bonus(summary.hackingBonus), speedBonus: bonus(summary.speedBonus),
            slots: buffer(summary.slots, summary.slotCount).map { slot in
                HackResultSummary.Slot(glyph: string(slot.glyph), outcome: outcome(slot.outcome),
                                       check: verdict(slot.check), comparison: status(slot.comparison),
                                       drawSeconds: double(slot.drawSeconds))
            },
            inputSeconds: double(summary.inputSeconds),
            commands: summary.hasCommands ? commands(summary.commands) : nil)
    }
}
