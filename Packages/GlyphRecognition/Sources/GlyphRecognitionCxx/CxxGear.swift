import Foundation
import GlyphCoreCxx
import GlyphRecognition

// The C++ arm of the gear logic (glyph_logic_gear.h): Swift values in, C
// structs across the ABI, Swift values out. Each class conforms to the
// protocol its Swift oracle conforms to, in GearProtocols.swift.
//
// Like the Swift values they replace, the stateful objects belong to one
// serial queue; the parser, which a reader may share, locks its handle.

// MARK: - Conversion

/// Memory for the C view of Swift values, freed with the arena. Keep it alive
/// across the call that reads the view (`withExtendedLifetime`).
final class CxxGearArena {
    private var blocks: [UnsafeMutableRawPointer] = []

    deinit { for block in blocks { block.deallocate() } }

    func string(_ text: String) -> gc_string {
        let bytes = Array(text.utf8)
        let block = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
        blocks.append(block)
        bytes.withUnsafeBytes { source in
            if let base = source.baseAddress { block.copyMemory(from: base, byteCount: bytes.count) }
        }
        return gc_string(bytes: block.assumingMemoryBound(to: CChar.self), length: Int32(clamping: bytes.count))
    }

    /// `values` must be plain C structs.
    func array<T>(_ values: [T]) -> UnsafePointer<T>? {
        guard !values.isEmpty else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: values.count)
        pointer.initialize(from: values, count: values.count)
        blocks.append(UnsafeMutableRawPointer(pointer))
        return UnsafePointer(pointer)
    }

    func strings(_ values: [String]) -> UnsafePointer<gc_string>? { array(values.map(string)) }
}

enum CxxGearValues {
    static let stages: [GearDropStage] = [.absent, .unknown, .portal, .bonus, .excluded, .unsupported]
    static let levels: [GearDropEntry.Level] = [.known, .notApplicable, .unreadable]
    static let rarities: [GearDropEntry.Rarity?] = [nil, .common, .rare, .veryRare, .unreadable]
    static let associations: [GearDropSummary.Association] = [
        .unassociated, .ordered, .orderedWithoutBonus, .bonusExpected, .noWaitingHack, .uncertainContinuity,
        .repeatedBonus,
    ]
    static let dispositions: [GearDropTracker.ReadingDisposition] = [
        .accepted, .invalidTime, .outOfOrder, .closedInterval, .nonPanel,
    ]
    static let displayStates: [GearDropDisplay.State] = [
        .waiting, .reading, .read, .partial, .unattached, .notRead, .watching,
    ]

    static func string(_ value: gc_string) -> String {
        guard let bytes = value.bytes, value.length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(value.length)), as: UTF8.self)
    }

    static func strings(_ base: UnsafePointer<gc_string>?, _ count: Int32) -> [String] {
        guard let base, count > 0 else { return [] }
        return UnsafeBufferPointer(start: base, count: Int(count)).map(string)
    }

    static func stage(_ value: GearDropStage) -> gl_gear_stage {
        gl_gear_stage(rawValue: UInt32(stages.firstIndex(of: value) ?? 0))
    }

    static func stage(_ value: gl_gear_stage) -> GearDropStage {
        let index = Int(value.rawValue)
        return stages.indices.contains(index) ? stages[index] : .unknown
    }

    static func language(_ value: GameLanguage) -> gc_language {
        gc_language(rawValue: UInt32(GameLanguage.allCases.firstIndex(of: value) ?? 0))
    }

    static func language(_ value: gc_language) -> GameLanguage? {
        let index = Int(value.rawValue)
        return GameLanguage.allCases.indices.contains(index) ? GameLanguage.allCases[index] : nil
    }

    static func entry(_ value: GearDropEntry, in arena: CxxGearArena) -> gl_gear_entry {
        gl_gear_entry(
            column: Int32(clamping: value.column), row: Int32(clamping: value.row),
            hasItem: value.item != nil, item: value.item.map(arena.string) ?? gc_string(bytes: nil, length: 0),
            levelState: gl_gear_level(rawValue: UInt32(levels.firstIndex(of: value.levelState) ?? 2)),
            level: gc_opt_int32(has: value.level != nil, value: Int32(clamping: value.level ?? 0)),
            quantity: Int64(value.quantity),
            rarity: gl_gear_rarity(rawValue: UInt32(rarities.firstIndex(of: value.rarity) ?? 0)),
            hasMultiplied: value.multiplied != nil, multiplied: value.multiplied ?? false)
    }

    static func entry(_ value: gl_gear_entry) -> GearDropEntry {
        let level = Int(value.levelState.rawValue), rarity = Int(value.rarity.rawValue)
        return GearDropEntry(
            column: Int(value.column), row: Int(value.row), item: value.hasItem ? string(value.item) : nil,
            levelState: levels.indices.contains(level) ? levels[level] : .unreadable,
            level: value.level.has ? Int(value.level.value) : nil, quantity: Int(value.quantity),
            rarity: rarities.indices.contains(rarity) ? rarities[rarity] : nil,
            multiplied: value.hasMultiplied ? value.multiplied : nil)
    }

    static func entries(_ base: UnsafePointer<gl_gear_entry>?, _ count: Int32) -> [GearDropEntry] {
        guard let base, count > 0 else { return [] }
        return UnsafeBufferPointer(start: base, count: Int(count)).map(entry)
    }

    static func evidence(_ value: GearDropFrameEvidence, in arena: CxxGearArena) -> gl_gear_evidence {
        gl_gear_evidence(
            sourceTime: value.sourceTime, stage: stage(value.stage), hasBounds: value.bounds != nil,
            bounds: gc_panel_bounds(top: value.bounds?.top ?? 0, bottom: value.bounds?.bottom ?? 0),
            entries: arena.array(value.entries.map { entry($0, in: arena) }),
            entryCount: Int32(clamping: value.entries.count), unreadableRows: Int32(clamping: value.unreadableRows),
            hasEffects: value.effects != nil, effects: arena.strings(value.effects ?? []),
            effectCount: Int32(clamping: value.effects?.count ?? 0),
            hasTitleLanguage: value.titleLanguage != nil,
            titleLanguage: language(value.titleLanguage ?? .english))
    }

    static func evidence(_ value: gl_gear_evidence) -> GearDropFrameEvidence {
        GearDropFrameEvidence(
            sourceTime: value.sourceTime, stage: stage(value.stage),
            bounds: value.hasBounds ? GearDropPanelBounds(top: value.bounds.top, bottom: value.bounds.bottom) : nil,
            entries: entries(value.entries, value.entryCount), unreadableRows: Int(value.unreadableRows),
            effects: value.hasEffects ? strings(value.effects, value.effectCount) : nil,
            titleLanguage: value.hasTitleLanguage ? language(value.titleLanguage) : nil)
    }

    static func summary(_ value: GearDropSummary, in arena: CxxGearArena) -> gl_gear_summary {
        let panels = value.panels.map { panel in
            gl_gear_panel(
                stage: stage(panel.stage), entries: arena.array(panel.entries.map { entry($0, in: arena) }),
                entryCount: Int32(clamping: panel.entries.count), partial: panel.partial,
                hasEffects: panel.effects != nil, effects: arena.strings(panel.effects ?? []),
                effectCount: Int32(clamping: panel.effects?.count ?? 0))
        }
        return gl_gear_summary(
            groupID: Int64(value.groupID), startedAt: value.startedAt, closedAt: value.closedAt,
            closeReason: arena.string(value.closeReason), hasHackID: value.hackID != nil,
            hackID: Int64(value.hackID ?? 0),
            association: gl_gear_association(rawValue: UInt32(associations.firstIndex(of: value.association) ?? 0)),
            panels: arena.array(panels), panelCount: Int32(clamping: panels.count))
    }

    static func summary(_ value: gl_gear_summary) -> GearDropSummary {
        let panels: [GearDropSummary.Panel] = value.panels.map { base in
            UnsafeBufferPointer(start: base, count: Int(max(value.panelCount, 0))).map { panel in
                GearDropSummary.Panel(stage: stage(panel.stage), entries: entries(panel.entries, panel.entryCount),
                                      partial: panel.partial,
                                      effects: panel.hasEffects ? strings(panel.effects, panel.effectCount) : nil)
            }
        } ?? []
        let association = Int(value.association.rawValue)
        return GearDropSummary(
            groupID: Int(value.groupID), startedAt: value.startedAt, closedAt: value.closedAt,
            closeReason: string(value.closeReason), hackID: value.hasHackID ? Int(value.hackID) : nil,
            association: associations.indices.contains(association) ? associations[association] : .unassociated,
            panels: panels)
    }

    static func wait(_ value: GearDropObservationSession.Wait) -> gl_gear_wait {
        gl_gear_wait(hackID: Int64(value.hackID), startedAt: value.startedAt, lastProgress: value.lastProgress,
                     hasFinalBonus: value.finalBonus != nil, finalBonus: Int64(value.finalBonus ?? 0))
    }

    static func wait(_ value: gl_gear_wait) -> GearDropObservationSession.Wait {
        GearDropObservationSession.Wait(hack: Int(value.hackID), startedAt: value.startedAt,
                                        lastProgress: value.lastProgress,
                                        finalBonus: value.hasFinalBonus ? Int(value.finalBonus) : nil)
    }

    /// Creation fails only on malformed arguments, which the callers here
    /// never pass.
    static func created(_ handle: OpaquePointer?, _ name: String) -> OpaquePointer {
        guard let handle else { preconditionFailure("the C++ gear \(name) could not be created") }
        return handle
    }

    static func withColorImage<T>(_ image: ColorImage, _ body: (gc_color_image) -> T) -> T {
        image.pixels.withUnsafeBufferPointer { buffer in
            body(gc_color_image(data: buffer.baseAddress, width: Int32(clamping: image.width),
                                height: Int32(clamping: image.height), bytesPerRow: Int32(clamping: image.width * 3),
                                bytesPerPixel: 3, redOffset: 0, greenOffset: 1, blueOffset: 2))
        }
    }
}

// MARK: - Tracker

/// `GearDropTracker` in C++.
public final class CxxGearDropTracker: GearDropTracking {
    private let handle: OpaquePointer

    public init(policy: GearDropTracker.Policy = GearDropTracker.Policy()) {
        var cPolicy = gl_gear_tracker_policy(
            minimumSpan: policy.minimumSpan, maximumReadingGap: policy.maximumReadingGap,
            departureSpan: policy.departureSpan, maximumCompletionWait: policy.maximumCompletionWait,
            groupLimit: policy.groupLimit)
        handle = CxxGearValues.created(
            gl_gear_tracker_create_with_return_window(&cPolicy, policy.bonusReturnWindow), "tracker")
    }

    deinit { gl_gear_tracker_destroy(handle) }

    public var isObserving: Bool { gl_gear_tracker_is_observing(handle) }

    public var currentPanelSettled: Bool { gl_gear_tracker_current_panel_settled(handle) }

    public var readingDisposition: GearDropTracker.ReadingDisposition {
        let index = Int(gl_gear_tracker_reading_disposition(handle).rawValue)
        return CxxGearValues.dispositions.indices.contains(index) ? CxxGearValues.dispositions[index] : .nonPanel
    }

    private func closed(_ call: (UnsafeMutablePointer<gl_gear_summary>) -> Bool) -> GearDropSummary? {
        var summary = gl_gear_summary()
        return call(&summary) ? CxxGearValues.summary(summary) : nil
    }

    public func accept(_ evidence: GearDropFrameEvidence) -> GearDropSummary? {
        let arena = CxxGearArena()
        var value = CxxGearValues.evidence(evidence, in: arena)
        return withExtendedLifetime(arena) { closed { gl_gear_tracker_accept(handle, &value, $0) } }
    }

    public func observe(at time: Double, panelCandidate: Bool, continuityLost: Bool = false,
                        pendingReadSourceTime: Double? = nil) -> GearDropSummary? {
        let pending = gc_opt_double(has: pendingReadSourceTime != nil, value: pendingReadSourceTime ?? 0)
        return closed { gl_gear_tracker_observe(handle, time, panelCandidate, continuityLost, pending, $0) }
    }

    public func loseContinuity(at time: Double) -> GearDropSummary? {
        closed { gl_gear_tracker_lose_continuity(handle, time, $0) }
    }

    public func finish(at time: Double, reason: String) -> GearDropSummary? {
        let arena = CxxGearArena()
        let cReason = arena.string(reason)
        return withExtendedLifetime(arena) { closed { gl_gear_tracker_finish(handle, time, cReason, $0) } }
    }
}

// MARK: - Observation session

/// `GearDropObservationSession` in C++.
public final class CxxGearDropObservationSession: GearDropSessioning {
    private let handle: OpaquePointer
    /// The C++ event list only grows; the converted prefix is kept.
    private var convertedEvents: [GearDropObservationSession.Event] = []

    public init(policy: GearDropObservationSession.Policy = GearDropObservationSession.Policy()) {
        var cPolicy = gl_gear_session_policy(inactivityLimit: policy.inactivityLimit,
                                             absoluteLimit: policy.absoluteLimit,
                                             maximumWaiting: Int64(policy.maximumWaiting))
        handle = CxxGearValues.created(
            gl_gear_session_create_with_repeat_window(&cPolicy, policy.repeatedBonusWindow), "session")
    }

    deinit { gl_gear_session_destroy(handle) }

    public var waiting: [GearDropObservationSession.Wait] {
        var count: Int32 = 0
        guard let base = gl_gear_session_waiting(handle, &count), count > 0 else { return [] }
        return UnsafeBufferPointer(start: base, count: Int(count)).map(CxxGearValues.wait)
    }

    public var events: [GearDropObservationSession.Event] {
        var count: Int32 = 0
        let base = gl_gear_session_events(handle, &count)
        if let base, Int(count) > convertedEvents.count {
            for event in UnsafeBufferPointer(start: base, count: Int(count))[convertedEvents.count...] {
                convertedEvents.append(GearDropObservationSession.Event(
                    at: event.time, hackID: event.hasHackID ? Int(event.hackID) : nil,
                    reason: CxxGearValues.string(event.reason)))
            }
        }
        return convertedEvents
    }

    public var isAssociationUncertain: Bool { gl_gear_session_is_association_uncertain(handle) }

    @discardableResult
    public func prepareFrame(at time: Double, continuityLost: Bool) -> Bool {
        gl_gear_session_prepare_frame(handle, time, continuityLost)
    }

    public func observe(at time: Double, hackID: Int, inputVisible: Bool, gameProgressVisible: Bool = false,
                        inputPhase: TrackingState = .input) {
        gl_gear_session_observe(handle, time, Int64(hackID), inputVisible, gameProgressVisible, inputPhase == .input)
    }

    public func enqueue(hackID: Int, at time: Double) {
        gl_gear_session_enqueue(handle, Int64(hackID), time)
    }

    public func accept(_ result: HackResult) {
        gl_gear_session_accept_result(handle, Int64(result.context.hackID), result.finalHackingBonus != nil,
                                      Int64(result.finalHackingBonus ?? 0))
    }

    public func close(_ group: GearDropSummary) -> GearDropSummary {
        let arena = CxxGearArena()
        var value = CxxGearValues.summary(group, in: arena)
        var attached = gl_gear_summary()
        let closed = withExtendedLifetime(arena) { gl_gear_session_close(handle, &value, &attached) }
        // Only a null argument fails, which cannot happen here.
        return closed ? CxxGearValues.summary(attached) : group
    }

    public func expire(at time: Double) { gl_gear_session_expire(handle, time) }

    public func invalidate(at time: Double, reason: String) {
        let arena = CxxGearArena()
        let cReason = arena.string(reason)
        withExtendedLifetime(arena) { gl_gear_session_invalidate(handle, time, cReason) }
    }
}

// MARK: - Evidence schedule

/// `GearEvidenceSchedule` in C++.
public final class CxxGearEvidenceSchedule: GearEvidenceScheduling {
    private let handle: OpaquePointer

    public init() { handle = CxxGearValues.created(gl_gear_schedule_create(), "schedule") }
    deinit { gl_gear_schedule_destroy(handle) }

    public func shouldSave(stage: GearDropStage, at time: Double) -> Bool {
        gl_gear_schedule_should_save(handle, CxxGearValues.stage(stage), time)
    }

    public func didEnqueue(stage: GearDropStage, at time: Double) {
        gl_gear_schedule_did_enqueue(handle, CxxGearValues.stage(stage), time)
    }
}

// MARK: - Floating display

/// `GearDropDisplayTracker` in C++. The display's text, symbol and tone are
/// `GearDropDisplay`'s own, in Swift.
public final class CxxGearDropDisplayTracker: GearDropDisplaying {
    private let handle: OpaquePointer

    public init(standalone: Bool = false) {
        handle = CxxGearValues.created(gl_gear_display_create(standalone), "display")
    }
    deinit { gl_gear_display_destroy(handle) }

    public var display: GearDropDisplay? {
        var value = gl_gear_display_value()
        guard gl_gear_display_get(handle, &value) else { return nil }
        let index = Int(value.state.rawValue)
        let state = CxxGearValues.displayStates.indices.contains(index) ? CxxGearValues.displayStates[index] : .waiting
        return GearDropDisplay(state: state, hackID: value.hasHackID ? Int(value.hackID) : nil,
                               itemCount: value.hasItemCount ? Int(value.itemCount) : nil,
                               waitingCount: Int(value.waitingCount))
    }

    public var revision: Int { Int(gl_gear_display_revision(handle)) }

    public func update(waiting: [GearDropObservationSession.Wait], reading: Bool, associationUncertain: Bool,
                       at time: Double) {
        let values = waiting.map(CxxGearValues.wait)
        values.withUnsafeBufferPointer { buffer in
            gl_gear_display_update(handle, buffer.baseAddress, Int32(clamping: buffer.count), reading,
                                   associationUncertain, time)
        }
    }

    public func finished(_ group: GearDropSummary) {
        let arena = CxxGearArena()
        var value = CxxGearValues.summary(group, in: arena)
        withExtendedLifetime(arena) { gl_gear_display_finished(handle, &value) }
    }

    public func ended(hackID: Int, at time: Double) { gl_gear_display_ended(handle, Int64(hackID), time) }
}

// MARK: - Text parser

/// `GearDropTextParser` in C++, over the language's `GameText.tables`.
/// Thread-safe: a lock serializes its handle, whose output buffers each
/// call reuses.
public final class CxxGearDropTextParser: GearDropTextParsing, @unchecked Sendable {
    public let language: GameLanguage
    private let handle: OpaquePointer
    private let lock = NSLock()

    public init(language: GameLanguage = .english) {
        self.language = language
        let arena = CxxGearArena()
        let tables = GameText(language).tables.map { table -> gl_gear_text_table in
            let items = table.items.map { gl_gear_text_pair(key: arena.string($0.key), value: arena.string($0.value)) }
            let leading = table.leadingWords.flatMap { words, items in
                items.sorted().map { gl_gear_text_pair(key: arena.string(words), value: arena.string($0)) }
            }
            return gl_gear_text_table(
                code: arena.string(table.code), bonusTitle: arena.string(table.bonusTitle),
                bountyTitle: arena.string(table.bountyTitle),
                messageFragments: arena.strings(table.messageFragments),
                messageFragmentCount: Int32(table.messageFragments.count),
                effectSuffixes: arena.strings(table.effectSuffixes),
                effectSuffixCount: Int32(table.effectSuffixes.count),
                effectPrefixes: arena.strings(table.effectPrefixes),
                effectPrefixCount: Int32(table.effectPrefixes.count),
                items: arena.array(items), itemCount: Int32(items.count),
                leadingWords: arena.array(leading), leadingWordCount: Int32(leading.count))
        }
        let titles = GameText.allBonusTitles.sorted()
        let created = withExtendedLifetime(arena) {
            gl_gear_parser_create(CxxGearValues.language(language), arena.array(tables), Int32(tables.count),
                                  arena.strings(titles), Int32(titles.count))
        }
        // Only malformed arguments fail, and these come from GameText.
        handle = CxxGearValues.created(created, "parser")
    }

    deinit { gl_gear_parser_destroy(handle) }

    public func read(lines: [ResultTextLine], bounds: GearDropPanelBounds, at time: Double) -> GearDropFrameEvidence {
        let arena = CxxGearArena()
        let cLines = lines.map {
            gl_gear_text_line(text: arena.string($0.text), confidence: $0.confidence, x: $0.x, y: $0.y,
                              width: $0.width, height: $0.height)
        }
        lock.lock(); defer { lock.unlock() }
        var evidence = gl_gear_evidence()
        withExtendedLifetime(arena) {
            cLines.withUnsafeBufferPointer { buffer in
                gl_gear_parser_read(handle, buffer.baseAddress, Int32(clamping: buffer.count),
                                    gc_panel_bounds(top: bounds.top, bottom: bounds.bottom), time, &evidence)
            }
        }
        return CxxGearValues.evidence(evidence)
    }

    public func showsUntitledPanel(lines: [ResultTextLine], bounds: GearDropPanelBounds, at time: Double) -> Bool {
        let arena = CxxGearArena()
        let cLines = lines.map {
            gl_gear_text_line(text: arena.string($0.text), confidence: $0.confidence, x: $0.x, y: $0.y,
                              width: $0.width, height: $0.height)
        }
        lock.lock(); defer { lock.unlock() }
        return withExtendedLifetime(arena) {
            cLines.withUnsafeBufferPointer { buffer in
                gl_gear_parser_shows_untitled_panel(handle, buffer.baseAddress, Int32(clamping: buffer.count),
                                                    gc_panel_bounds(top: bounds.top, bottom: bounds.bottom), time)
            }
        }
    }

    public func parseEntry(_ text: String, row: Int, column: Int, clipped: Bool = false) -> GearDropEntry? {
        guard let row32 = Int32(exactly: row), let column32 = Int32(exactly: column) else { return nil }
        let arena = CxxGearArena()
        let cText = arena.string(text)
        lock.lock(); defer { lock.unlock() }
        var entry = gl_gear_entry()
        let parsed = withExtendedLifetime(arena) {
            gl_gear_parser_parse_entry(handle, cText, row32, column32, clipped, &entry)
        }
        return parsed ? CxxGearValues.entry(entry) : nil
    }

    public static func position(of line: ResultTextLine, in bounds: GearDropPanelBounds) -> Int? {
        // The position reads only the box, so the text is not copied.
        var cLine = gl_gear_text_line(text: gc_string(bytes: nil, length: 0), confidence: line.confidence,
                                      x: line.x, y: line.y, width: line.width, height: line.height)
        var position: Int32 = 0
        guard gl_gear_position(&cLine, gc_panel_bounds(top: bounds.top, bottom: bounds.bottom), &position) else {
            return nil
        }
        return Int(position)
    }
}

// MARK: - Pixel readers

/// `GearQuantityColorReader` in C++.
public struct CxxGearQuantityColorReader: Sendable {
    public init() {}

    public func read(_ image: ColorImage) -> Bool? {
        var multiplied = false
        let read = CxxGearValues.withColorImage(image) { gl_gear_quantity_color_read($0, &multiplied) }
        return read ? multiplied : nil
    }
}

/// `GearRarityReader` in C++.
public struct CxxGearRarityReader: Sendable {
    public init() {}

    public func read(_ image: ColorImage) -> GearDropEntry.Rarity? {
        let index = Int(CxxGearValues.withColorImage(image) { gl_gear_rarity_read($0) }.rawValue)
        return CxxGearValues.rarities.indices.contains(index) ? CxxGearValues.rarities[index] : nil
    }
}
