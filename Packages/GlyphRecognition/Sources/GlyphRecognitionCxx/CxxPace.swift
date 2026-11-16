import CoreGraphics
import Foundation
import GlyphCoreCxx
import GlyphRecognition
import GlyphRecognitionImages

// The C++ arm of the pace area (glyph_logic_pace.h): the same protocols as
// the Swift types, with every decision made in C++. Values are converted at
// the ABI; integers wider than the ABI's 32 bits are clamped, which no real
// level, slot count or Glyph count comes near.

// MARK: - Conversions

/// The conversions at the ABI, private to this file so the other areas'
/// bridges in this module can name theirs freely.
private enum PaceABI {
    /// Calls `body` with `text` as UTF-8, valid for the call.
    static func withString<Result>(_ text: String, _ body: (gc_string) throws -> Result) rethrows -> Result {
        var text = text
        return try text.withUTF8 { buffer in
            try body(gc_string(bytes: buffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                               length: Int32(buffer.count)))
        }
    }

    static func string(_ text: gc_string) -> String {
        guard let bytes = text.bytes, text.length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.length)), as: UTF8.self)
    }

    static func language(_ language: GameLanguage) -> gc_language {
        gc_language(rawValue: UInt32(GameLanguage.allCases.firstIndex(of: language) ?? 0))
    }

    static func language(_ language: gc_language) -> GameLanguage {
        let index = Int(language.rawValue)
        return GameLanguage.allCases.indices.contains(index) ? GameLanguage.allCases[index] : .english
    }

    static let notices: [CommandNoticeReading.Notice] = [.simple, .complex, .requestKey, .noKey, .keysOnly, .invalid,
                                                         .drone]

    static func notice(_ notice: CommandNoticeReading.Notice?) -> gl_game_text_notice_kind {
        gl_game_text_notice_kind(rawValue: UInt32(notice.flatMap { notices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0))
    }

    static func notice(_ notice: gl_game_text_notice_kind) -> CommandNoticeReading.Notice? {
        let index = Int(notice.rawValue) - 1
        return notices.indices.contains(index) ? notices[index] : nil
    }

    static func faction(_ faction: PortalFaction?) -> gl_portal_faction {
        gl_portal_faction(rawValue: UInt32(faction.flatMap { PortalFaction.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0))
    }

    static func faction(_ faction: gl_portal_faction) -> PortalFaction? {
        let index = Int(faction.rawValue) - 1
        return PortalFaction.allCases.indices.contains(index) ? PortalFaction.allCases[index] : nil
    }

    static func optional(_ value: Double?) -> gc_opt_double { gc_opt_double(has: value != nil, value: value ?? 0) }

    static func optional(_ value: Int?) -> gc_opt_int32 {
        gc_opt_int32(has: value != nil, value: value.map { Int32(clamping: $0) } ?? 0)
    }

    static func evidence(_ cxx: gl_portal_evidence) -> PortalScreenEvidence {
        let resonators = cxx.resonatorCount > 0 && cxx.resonators != nil
            ? UnsafeBufferPointer(start: cxx.resonators, count: Int(cxx.resonatorCount)).map { Int($0) } : []
        return PortalScreenEvidence(sourceTime: cxx.sourceTime, resonators: resonators,
                                    unreadSlots: Int(cxx.unreadSlots),
                                    badgeHue: cxx.badgeHue.has ? cxx.badgeHue.value : nil, faction: faction(cxx.faction))
    }
}

/// Memory for one call's arguments, freed with the arena.
private final class PaceArena {
    private var blocks: [UnsafeMutableRawPointer] = []

    deinit { blocks.forEach { $0.deallocate() } }

    func array<Element>(_ elements: [Element]) -> UnsafePointer<Element>? {
        guard !elements.isEmpty else { return nil }
        let pointer = UnsafeMutablePointer<Element>.allocate(capacity: elements.count)
        pointer.initialize(from: elements, count: elements.count)
        blocks.append(UnsafeMutableRawPointer(pointer))
        return UnsafePointer(pointer)
    }

    func string(_ text: String) -> gc_string {
        let bytes = Array(text.utf8)
        guard let pointer = array(bytes) else { return gc_string(bytes: nil, length: 0) }
        return gc_string(bytes: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self), length: Int32(bytes.count))
    }

    func strings(_ texts: [String]) -> UnsafePointer<gc_string>? { array(texts.map(string)) }
}

// MARK: - Text

/// The shared text functions of glyph_common.h, for callers and tests.
public enum CxxText {
    /// `GameText.normalized(_:)`.
    public static func normalized(_ text: String) -> String { viaBuffer(text, gc_normalize) }

    /// `GameText.compactTransmuter(_:)`.
    public static func compactTransmuter(_ text: String) -> String { viaBuffer(text, gc_compact_transmuter) }

    /// `String.count`, as the C++ segments the text.
    public static func characterCount(_ text: String) -> Int { PaceABI.withString(text) { Int(gl_text_character_count($0)) } }

    private static func viaBuffer(_ text: String,
                                  _ function: (gc_string, UnsafeMutablePointer<CChar>?, Int32) -> Int32) -> String {
        PaceABI.withString(text) { input in
            var capacity = Int32(max(16, input.length * 4))
            while true {
                var buffer = [CChar](repeating: 0, count: Int(capacity))
                let length = buffer.withUnsafeMutableBufferPointer { function(input, $0.baseAddress, capacity) }
                if length <= capacity {
                    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                capacity = length
            }
        }
    }
}

// MARK: - Pace

/// `AnalysisRateController` in C++.
public final class CxxAnalysisRateController: AnalysisPacing {
    private let handle: OpaquePointer

    public init(policy: AnalysisRateController.Policy = AnalysisRateController.Policy()) {
        var cxx = gl_pace_policy(
            activeInterval: policy.activeInterval, quietInterval: policy.quietInterval,
            constrainedActiveInterval: policy.constrainedActiveInterval,
            constrainedQuietInterval: policy.constrainedQuietInterval, settle: policy.settle,
            changeThreshold: Int32(clamping: policy.changeThreshold), switchMeanJump: policy.switchMeanJump,
            switchWindow: policy.switchWindow, switchBurst: policy.switchBurst)
        guard let handle = gl_pace_create(&cxx) else { fatalError("gl_pace_create: out of memory") }
        self.handle = handle
    }

    deinit { gl_pace_destroy(handle) }

    public var policy: AnalysisRateController.Policy {
        let cxx = gl_pace_get_policy(handle)
        var policy = AnalysisRateController.Policy()
        policy.activeInterval = cxx.activeInterval
        policy.quietInterval = cxx.quietInterval
        policy.constrainedActiveInterval = cxx.constrainedActiveInterval
        policy.constrainedQuietInterval = cxx.constrainedQuietInterval
        policy.settle = cxx.settle
        policy.changeThreshold = Int(cxx.changeThreshold)
        policy.switchMeanJump = cxx.switchMeanJump
        policy.switchWindow = cxx.switchWindow
        policy.switchBurst = cxx.switchBurst
        return policy
    }

    public var mode: AnalysisRateController.Mode { Self.mode(gl_pace_get_mode(handle)) }
    public var enteredCandidate: Bool { gl_pace_entered_candidate(handle) }
    public var switchedScreen: Bool { gl_pace_switched_screen(handle) }

    public func decide(at time: Double, gate: LumaGateReading?, busy: Bool, inHack: Bool,
                       constrained: Bool) -> AnalysisRateController.Decision {
        let reading = gl_pace_gate(has: gate != nil, isCandidate: gate?.isCandidate ?? false,
                                   meanLuma: gate?.meanLuma ?? 0)
        return Self.decision(gl_pace_decide(handle, time, reading, busy, inHack, constrained))
    }

    public func advanceStill(at time: Double, busy: Bool, inHack: Bool,
                             constrained: Bool) -> AnalysisRateController.Decision {
        Self.decision(gl_pace_advance_still(handle, time, busy, inHack, constrained))
    }

    public func reset() { gl_pace_reset(handle) }

    public static func headerInterval(mode: AnalysisRateController.Mode, inHack: Bool, constrained: Bool) -> Double? {
        let cxx: gl_pace_mode = switch mode {
        case .active: GL_PACE_MODE_ACTIVE
        case .resting: GL_PACE_MODE_RESTING
        case .quiet: GL_PACE_MODE_QUIET
        }
        let interval = gl_pace_header_interval(cxx, inHack, constrained)
        return interval.has ? interval.value : nil
    }

    private static func mode(_ mode: gl_pace_mode) -> AnalysisRateController.Mode {
        switch mode {
        case GL_PACE_MODE_RESTING: .resting
        case GL_PACE_MODE_QUIET: .quiet
        default: .active
        }
    }

    private static func decision(_ decision: gl_pace_decision) -> AnalysisRateController.Decision {
        AnalysisRateController.Decision(mode: mode(decision.mode), interval: decision.interval)
    }
}

// MARK: - Text lane

/// `GameTextSchedule` in C++.
public final class CxxGameTextSchedule: GameTextScheduling {
    private let handle: OpaquePointer
    private static let modes: [GameTextSchedule.Mode] = [.header, .result, .gear, .portal, .command]

    public init() {
        guard let handle = gl_text_schedule_create() else { fatalError("gl_text_schedule_create: out of memory") }
        self.handle = handle
    }

    deinit { gl_text_schedule_destroy(handle) }

    public var inFlight: GameTextSchedule.Request? {
        var request = gl_text_schedule_request()
        return gl_text_schedule_in_flight(handle, &request) ? Self.request(request) : nil
    }

    public func take(at time: Double, panelCandidate: Bool, resultEligible: Bool, minimumInterval: Double = 0.1,
                     gearCandidate: Bool = false, headerPriority: Bool = false, portalCandidate: Bool = false,
                     commandCandidate: Bool = false, readsHeader: Bool = true, headerInterval: Double? = nil,
                     gearInterval: Double = 0.2, gearPanelPace: GameTextSchedule.Pace? = nil,
                     admitsHeader: () -> Bool = { true }) -> GameTextSchedule.Request? {
        var args = gl_text_schedule_take_args(
            time: time, panelCandidate: panelCandidate, resultEligible: resultEligible,
            minimumInterval: minimumInterval, gearCandidate: gearCandidate, headerPriority: headerPriority,
            portalCandidate: portalCandidate, commandCandidate: commandCandidate, readsHeader: readsHeader,
            headerInterval: PaceABI.optional(headerInterval), gearInterval: gearInterval)
        var request = gl_text_schedule_request()
        let status: gl_text_schedule_take_status
        if let gearPanelPace {
            var pace = gl_text_schedule_pace(minimumInterval: gearPanelPace.minimumInterval,
                                             gearInterval: gearPanelPace.gearInterval)
            status = gl_text_schedule_take_paced(handle, &args, &pace, &request)
        } else {
            status = gl_text_schedule_take_paced(handle, &args, nil, &request)
        }
        switch status {
        case GL_TEXT_SCHEDULE_TAKE_GRANTED:
            return Self.request(request)
        case GL_TEXT_SCHEDULE_TAKE_NEEDS_ADMISSION:
            return gl_text_schedule_admit(handle, admitsHeader(), &request) ? Self.request(request) : nil
        default:
            return nil
        }
    }

    public func finish(_ request: GameTextSchedule.Request, panelPresent: Bool = false, untitledPanel: Bool = false) {
        gl_text_schedule_finish_untitled(handle, Self.request(request), panelPresent, untitledPanel)
    }

    public func observeGearPanel(_ bounds: GearDropPanelBounds?, at time: Double,
                                 previousPanelUnconfirmed: Bool = false) -> GameTextSchedule.Request? {
        var request = gl_text_schedule_request()
        return gl_text_schedule_observe_gear_panel(handle, bounds != nil, bounds?.top ?? 0, bounds?.bottom ?? 0,
                                                   time, previousPanelUnconfirmed, &request)
            ? Self.request(request) : nil
    }

    /// `readsGearPanel`.
    public var readsGearPanel: Bool { gl_text_schedule_reads_gear_panel(handle) }
    /// `newGearPanel`.
    public var newGearPanel: Bool { gl_text_schedule_new_gear_panel(handle) }
    /// `cancelledGearRequest`.
    public var cancelledGearRequest: GameTextSchedule.Request? {
        var request = gl_text_schedule_request()
        return gl_text_schedule_cancelled_gear_request(handle, &request) ? Self.request(request) : nil
    }

    private static func request(_ request: GameTextSchedule.Request) -> gl_text_schedule_request {
        let mode = modes.firstIndex(of: request.mode) ?? 0
        return gl_text_schedule_request(id: Int64(request.id), mode: gl_text_schedule_mode(rawValue: UInt32(mode)),
                                        sourceTime: request.sourceTime)
    }

    private static func request(_ request: gl_text_schedule_request) -> GameTextSchedule.Request {
        let index = Int(request.mode.rawValue)
        return .make(id: Int(request.id), mode: modes.indices.contains(index) ? modes[index] : .header,
                     sourceTime: request.sourceTime)
    }
}

// MARK: - Game language memory

/// `GameLanguageMemory` in C++. Locked like the Swift class, and calls
/// `onChange` outside the lock as it does.
public final class CxxGameLanguageMemory: GameLanguageRemembering, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: OpaquePointer
    private let onChange: @Sendable (GameLanguage) -> Void

    public init(language: GameLanguage, isAutomatic: Bool, retryInterval: Double = 1,
                onChange: @escaping @Sendable (GameLanguage) -> Void = { _ in }) {
        guard let handle = gl_language_memory_create(PaceABI.language(language), isAutomatic, retryInterval) else {
            fatalError("gl_language_memory_create: out of memory")
        }
        self.handle = handle
        self.onChange = onChange
    }

    deinit { gl_language_memory_destroy(handle) }

    public var current: GameLanguage { lock.withLock { PaceABI.language(gl_language_memory_current(handle)) } }
    public var isConfirmed: Bool { lock.withLock { gl_language_memory_is_confirmed(handle) } }
    public var isAutomatic: Bool { lock.withLock { gl_language_memory_is_automatic(handle) } }
    public var retryInterval: Double { lock.withLock { gl_language_memory_retry_interval(handle) } }

    public var state: (language: GameLanguage, isConfirmed: Bool) {
        lock.withLock {
            (PaceABI.language(gl_language_memory_current(handle)), gl_language_memory_is_confirmed(handle))
        }
    }

    public func alternatives(at time: Double, on screen: GameLanguageMemory.Screen) -> [GameLanguage] {
        let cxx: gl_language_memory_screen = switch screen {
        case .notice: GL_LANGUAGE_MEMORY_SCREEN_NOTICE
        case .result: GL_LANGUAGE_MEMORY_SCREEN_RESULT
        case .panel: GL_LANGUAGE_MEMORY_SCREEN_PANEL
        }
        var out = [gc_language](repeating: GC_LANGUAGE_ENGLISH, count: 5)
        let count = lock.withLock {
            out.withUnsafeMutableBufferPointer { gl_language_memory_alternatives(handle, time, cxx, $0.baseAddress) }
        }
        return out.prefix(Int(count)).map { PaceABI.language($0) }
    }

    public func found(_ found: GameLanguage) {
        let changed = lock.withLock { gl_language_memory_found(handle, PaceABI.language(found)) }
        if changed { onChange(found) }
    }

    public func panelReadingLanguage(at time: Double, bounds: GearDropPanelBounds) -> GameLanguage? {
        var language = GC_LANGUAGE_ENGLISH
        let found = lock.withLock {
            gl_language_memory_panel_reading_language(handle, time, bounds.top, bounds.bottom, &language)
        }
        return found ? PaceABI.language(language) : nil
    }

    public func rememberPanelReading(_ language: GameLanguage, at time: Double, bounds: GearDropPanelBounds) {
        lock.withLock {
            gl_language_memory_remember_panel_reading(handle, PaceABI.language(language), time, bounds.top, bounds.bottom)
        }
    }

    public static func startingGuess(remembered: GameLanguage?, preferredLanguages: [String]) -> GameLanguage {
        let arena = PaceArena()
        let strings = arena.strings(preferredLanguages)
        return PaceABI.language(gl_language_memory_starting_guess(
            remembered != nil, remembered.map { PaceABI.language($0) } ?? GC_LANGUAGE_ENGLISH, strings, Int32(preferredLanguages.count)))
    }
}

// MARK: - Game text

/// `GameText`'s matchers in C++, over the phrase packs Swift exports. The
/// handle never changes after creation, so it may be shared.
public final class CxxGameText: GameTextMatching, @unchecked Sendable {
    let handle: OpaquePointer
    public let language: GameLanguage

    public init(_ language: GameLanguage = .english) {
        self.language = language
        let arena = PaceArena()
        let packs = GameText(language).tables.map { table -> gl_game_text_pack in
            let notices = table.notices.sorted { $0.key < $1.key }.map {
                gl_game_text_notice_entry(text: arena.string($0.key), notice: PaceABI.notice($0.value))
            }
            let items = table.items.sorted { $0.key < $1.key }.map {
                gl_game_text_item_entry(shown: arena.string($0.key), item: arena.string($0.value))
            }
            let leading = table.leadingWords.sorted { $0.key < $1.key }.flatMap { word, items in
                items.sorted().map { gl_game_text_item_entry(shown: arena.string(word), item: arena.string($0)) }
            }
            return gl_game_text_pack(
                code: arena.string(table.code), notices: arena.array(notices), noticeCount: Int32(notices.count),
                droneFooter: arena.string(table.droneFooter), hackingLabel: arena.string(table.hackingLabel),
                speedLabel: arena.string(table.speedLabel), bonusTitle: arena.string(table.bonusTitle),
                bountyTitle: arena.string(table.bountyTitle), messageFragments: arena.strings(table.messageFragments),
                messageFragmentCount: Int32(table.messageFragments.count),
                effectSuffixes: arena.strings(table.effectSuffixes), effectSuffixCount: Int32(table.effectSuffixes.count),
                effectPrefixes: arena.strings(table.effectPrefixes), effectPrefixCount: Int32(table.effectPrefixes.count),
                items: arena.array(items), itemCount: Int32(items.count), leadingWords: arena.array(leading),
                leadingWordCount: Int32(leading.count))
        }
        let titles = GameText.allBonusTitles.sorted()
        guard let handle = gl_game_text_create(PaceABI.language(language), arena.array(packs), Int32(packs.count),
                                               arena.strings(titles), Int32(titles.count)) else {
            fatalError("gl_game_text_create: out of memory")
        }
        self.handle = handle
    }

    deinit { gl_game_text_destroy(handle) }

    public func notice(_ text: String) -> (notice: CommandNoticeReading.Notice, language: String)? {
        var match = gl_game_text_notice_match()
        guard PaceABI.withString(text, { gl_game_text_notice(handle, $0, &match) }),
              let notice = PaceABI.notice(match.notice) else { return nil }
        return (notice, PaceABI.string(match.language))
    }

    public func isDroneFooter(_ text: String) -> Bool { PaceABI.withString(text) { gl_game_text_is_drone_footer(handle, $0) } }
    public func isHackingLabel(_ text: String) -> Bool { PaceABI.withString(text) { gl_game_text_is_hacking_label(handle, $0) } }
    public func isSpeedLabel(_ text: String) -> Bool { PaceABI.withString(text) { gl_game_text_is_speed_label(handle, $0) } }

    public func hackingLabelLanguage(_ text: String) -> GameLanguage? {
        var language = GC_LANGUAGE_ENGLISH
        return PaceABI.withString(text) { gl_game_text_hacking_label_language(handle, $0, &language) }
            ? PaceABI.language(language) : nil
    }

    public func bonusTitleLanguage(_ text: String) -> GameLanguage? {
        var language = GC_LANGUAGE_ENGLISH
        return PaceABI.withString(text) { gl_game_text_bonus_title_language(handle, $0, &language) }
            ? PaceABI.language(language) : nil
    }

    public func title(_ text: String) -> GameText.Title {
        switch PaceABI.withString(text, { gl_game_text_title(handle, $0) }) {
        case GL_GAME_TEXT_TITLE_BONUS: .bonus
        case GL_GAME_TEXT_TITLE_BOUNTY: .bounty
        case GL_GAME_TEXT_TITLE_UNSUPPORTED: .unsupported
        case GL_GAME_TEXT_TITLE_MESSAGE: .message
        default: .other
        }
    }

    public func effect(_ text: String) -> String? {
        var out = gc_string()
        return PaceABI.withString(text) { gl_game_text_effect(handle, $0, &out) } ? PaceABI.string(out) : nil
    }

    public func item(named name: String, clipped: Bool = false) -> String? {
        var out = gc_string()
        return PaceABI.withString(name) { gl_game_text_item(handle, $0, clipped, &out) } ? PaceABI.string(out) : nil
    }
}

// MARK: - Command notices

/// `CommandNoticeParser` in C++.
public final class CxxCommandNoticeParser: CommandNoticeParsing, @unchecked Sendable {
    private let handle: OpaquePointer

    public init(language: GameLanguage = .english) {
        let text = CxxGameText(language)
        guard let handle = gl_command_parser_create(text.handle) else {
            fatalError("gl_command_parser_create: out of memory")
        }
        self.handle = handle
    }

    deinit { gl_command_parser_destroy(handle) }

    public func read(_ lines: [(String, Double)]) -> CommandNoticeReading {
        let arena = PaceArena()
        let converted = lines.map { gl_command_parser_line(text: arena.string($0.0), confidence: $0.1) }
        return CxxCommandNoticeCapture.reading(gl_command_parser_read(handle, arena.array(converted),
                                                                      Int32(converted.count)))
    }
}

/// `CommandNoticeCapture` with its queue, window and drone-mode decisions in
/// C++. The band detector, the footer probe and the crops are the Swift
/// pixel code; the crops wait here, by token, while C++ holds their frames.
public final class CxxCommandNoticeCapture: CommandNoticeCapturing {
    private let handle: OpaquePointer
    private var images: [Int64: CGImage] = [:]
    private var nextToken: Int64 = 0

    public init() {
        guard let handle = gl_command_capture_create() else { fatalError("gl_command_capture_create: out of memory") }
        self.handle = handle
    }

    deinit { gl_command_capture_destroy(handle) }

    public var showsNotice: Bool { gl_command_capture_shows_notice(handle) }
    public var noticeReadAt: Double? {
        var time = 0.0
        return gl_command_capture_notice_read_at(handle, &time) ? time : nil
    }
    public var modeCandidates: Int { Int(gl_command_capture_mode_candidates(handle)) }
    public var modeReads: Int { Int(gl_command_capture_mode_reads(handle)) }
    public var modeReuses: Int { Int(gl_command_capture_mode_reuses(handle)) }

    public var queue: [CommandNoticeFrame] { queuedFrames().compactMap(frame) }

    public func observe(band: CGImage, at time: Double) throws {
        guard gl_command_capture_begin_frame(handle, time) else { return }
        defer { prune() }
        let pixels = try ImageDecoder.decode(band)
        guard let current = CommandNoticeDetector().detect(pixels) else {
            // An overlay or unreadable box is not an empty command window.
            let obscured = (pixels.height / 5..<pixels.height).contains { y in
                (0..<pixels.width).filter { pixels[$0, y] > 45 }.count > pixels.width / 8
            }
            _ = gl_command_capture_observe_box(handle, time, nil, obscured)
            return
        }
        let due = current.signature.withUnsafeBufferPointer { signature in
            var box = gl_command_capture_box(width: Double(current.rect.width), signature: signature.baseAddress,
                                             signatureCount: Int32(signature.count))
            return gl_command_capture_observe_box(handle, time, &box, false)
        }
        guard due, let crop = band.cropping(to: current.rect) else { return }
        gl_command_capture_add_sample(handle, time, store(crop))
    }

    public func observeEmptyBand(at time: Double) {
        guard gl_command_capture_begin_frame(handle, time) else { return }
        defer { prune() }
        _ = gl_command_capture_observe_box(handle, time, nil, false)
    }

    public func modeProbeDue(at time: Double, panelShowing: Bool = false) -> Bool {
        gl_command_capture_mode_probe_due(handle, time, panelShowing)
    }

    @discardableResult
    public func observeMode(in image: CGImage, at time: Double, panelShowing: Bool = false) throws -> Bool {
        guard modeProbeDue(at: time, panelShowing: panelShowing) else { return false }
        return probeMode(try DroneFooterProbe.textPixels(in: image), at: time) { DroneFooterProbe.readCrop(image) }
    }

    @discardableResult
    public func observeMode(footer: CGImage, frameWidth: Int, frameHeight: Int, at time: Double,
                            panelShowing: Bool = false) throws -> Bool {
        guard modeProbeDue(at: time, panelShowing: panelShowing) else { return false }
        let pixels = try DroneFooterProbe.textPixels(region: footer, frameWidth: frameWidth, frameHeight: frameHeight)
        return probeMode(pixels, at: time) { DroneFooterProbe.readCrop(region: footer) }
    }

    private func probeMode(_ pixels: ColorImage, at time: Double, readCrop: () -> CGImage?) -> Bool {
        guard let candidate = DroneFooterProbe.candidate(pixels) else { return false }
        let footer = candidate.signature.withUnsafeBufferPointer {
            gl_command_capture_mode_candidate(handle, time, $0.baseAddress, Int32($0.count))
        }
        guard footer == GL_COMMAND_CAPTURE_FOOTER_READ, let crop = readCrop() else { return true }
        let token = store(crop)
        candidate.signature.withUnsafeBufferPointer {
            gl_command_capture_add_mode_read(handle, time, $0.baseAddress, Int32($0.count), token)
        }
        return true
    }

    public func take(at time: Double) -> CommandNoticeFrame? {
        defer { prune() }
        var taken = gl_command_capture_frame()
        guard gl_command_capture_take(handle, time, &taken) else { return nil }
        let result = frame(taken)
        images[taken.imageToken] = nil
        return result
    }

    public func takeDropped() -> [Int] {
        var ids: UnsafePointer<Int64>?
        let count = Int(gl_command_capture_take_dropped(handle, &ids))
        guard let ids, count > 0 else { return [] }
        return UnsafeBufferPointer(start: ids, count: count).map { Int($0) }
    }

    public func interrupt(at time: Double) { gl_command_capture_interrupt(handle, time) }

    public func invalidateQueue(at time: Double) {
        gl_command_capture_invalidate_queue(handle, time)
        prune()
    }

    public func accept(_ read: CommandNoticeReading, frame: CommandNoticeFrame) {
        let arena = PaceArena()
        let reading = gl_command_parser_reading(
            notice: PaceABI.notice(read.notice), confidence: read.confidence,
            hasLanguage: read.language != nil, language: arena.string(read.language ?? ""), isClear: read.isClear)
        var cxxFrame = gl_command_capture_frame(
            id: Int64(frame.id), sourceTime: frame.sourceTime, imageToken: 0, isMode: frame.isMode,
            generation: Int64(frame.generation), hasSignature: frame.signature != nil,
            signature: arena.array(frame.signature ?? []), signatureCount: Int32(frame.signature?.count ?? 0))
        gl_command_capture_accept(handle, reading, &cxxFrame)
    }

    public func bind(hackID: Int) { gl_command_capture_bind(handle, Int64(hackID)) }

    public func cancel() {
        gl_command_capture_cancel(handle)
        prune()
    }

    public func summary(hackID: Int) -> HackCommandSummary {
        let cxx = gl_command_capture_summary(handle, Int64(hackID))
        var summary = HackCommandSummary()
        summary.presentation = Self.selection(cxx.presentation)
        summary.gear = Self.selection(cxx.gear)
        summary.mode = switch cxx.mode {
        case GL_COMMAND_CAPTURE_WINDOW_MODE_PORTAL: .portal
        case GL_COMMAND_CAPTURE_WINDOW_MODE_DRONE: .drone
        default: .unknown
        }
        return summary
    }

    static func reading(_ reading: gl_command_parser_reading) -> CommandNoticeReading {
        CommandNoticeReading(notice: PaceABI.notice(reading.notice), confidence: reading.confidence,
                             language: reading.hasLanguage ? PaceABI.string(reading.language) : nil,
                             isClear: reading.isClear)
    }

    private static func selection(_ cxx: gl_command_capture_selection) -> HackCommandSummary.Selection {
        var selection = HackCommandSummary.Selection()
        selection.status = switch cxx.status {
        case GL_COMMAND_CAPTURE_STATUS_CONFIRMED: .confirmed
        case GL_COMMAND_CAPTURE_STATUS_UNRESOLVED: .unresolved
        case GL_COMMAND_CAPTURE_STATUS_NOT_APPLICABLE: .notApplicable
        default: .noCommandObserved
        }
        let commands: [HackCommand] = [.simple, .complex, .requestKey, .noKey, .keysOnly]
        let index = Int(cxx.lastObserved.rawValue) - 1
        selection.lastObserved = commands.indices.contains(index) ? commands[index] : nil
        selection.samples = Int(cxx.samples)
        selection.language = cxx.hasLanguage ? PaceABI.string(cxx.language) : nil
        return selection
    }

    private func store(_ image: CGImage) -> Int64 {
        nextToken += 1
        images[nextToken] = image
        return nextToken
    }

    private func queuedFrames() -> [gl_command_capture_frame] {
        var frames: UnsafePointer<gl_command_capture_frame>?
        let count = Int(gl_command_capture_queue(handle, &frames))
        guard let frames, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: frames, count: count))
    }

    /// Lets go of the crops whose frames C++ no longer holds.
    private func prune() {
        let held = Set(queuedFrames().map(\.imageToken))
        images = images.filter { held.contains($0.key) }
    }

    private func frame(_ cxx: gl_command_capture_frame) -> CommandNoticeFrame? {
        guard let image = images[cxx.imageToken] else {
            assertionFailure("a queued frame lost its crop")
            return nil
        }
        let signature = cxx.hasSignature
            ? Array(UnsafeBufferPointer(start: cxx.signature, count: Int(cxx.signatureCount))) : nil
        return .make(id: Int(cxx.id), sourceTime: cxx.sourceTime, image: image, isMode: cxx.isMode,
                     generation: Int(cxx.generation), signature: signature)
    }
}

/// `DroneFooterProbe.matches(_:_:)` in C++.
public enum CxxDroneFooterProbe {
    public static func matches(_ signature: [UInt8], _ known: [UInt8]) -> Bool {
        signature.withUnsafeBufferPointer { signature in
            known.withUnsafeBufferPointer { known in
                gl_command_capture_footer_signatures_match(signature.baseAddress, Int32(signature.count),
                                                           known.baseAddress, Int32(known.count))
            }
        }
    }
}

// MARK: - Portal level

/// `PortalLevelObserver` in C++.
public final class CxxPortalLevelObserver: PortalLevelObserving {
    private let handle: OpaquePointer

    public init(policy: PortalLevelObserver.Policy = PortalLevelObserver.Policy()) {
        var cxx = gl_portal_observer_policy(attachWindow: policy.attachWindow, sameScreen: policy.sameScreen)
        guard let handle = gl_portal_observer_create(&cxx) else { fatalError("gl_portal_observer_create: out of memory") }
        self.handle = handle
    }

    deinit { gl_portal_observer_destroy(handle) }

    public func accept(_ evidence: PortalScreenEvidence) {
        let resonators = evidence.resonators.map { Int32(clamping: $0) }
        resonators.withUnsafeBufferPointer { levels in
            var cxx = gl_portal_evidence(
                sourceTime: evidence.sourceTime, resonators: levels.baseAddress, resonatorCount: Int32(levels.count),
                unreadSlots: Int32(clamping: evidence.unreadSlots), badgeHue: PaceABI.optional(evidence.badgeHue),
                faction: PaceABI.faction(evidence.faction))
            gl_portal_observer_accept(handle, &cxx)
        }
    }

    public func claim(at time: Double) -> PortalScreenEvidence? {
        var out = gl_portal_evidence()
        return gl_portal_observer_claim(handle, time, &out) ? PaceABI.evidence(out) : nil
    }
}

/// `PortalScreenParser` in C++.
public struct CxxPortalScreenParser: PortalScreenParsing {
    public init() {}

    public func read(lines: [ResultTextLine], badgeHue: Double?, at time: Double, faction: PortalFaction? = nil,
                     yellowLabels: Set<Int> = []) -> PortalScreenEvidence {
        let arena = PaceArena()
        let converted = lines.map { gl_portal_parser_line(text: arena.string($0.text), confidence: $0.confidence) }
        let yellow = yellowLabels.sorted().map { Int32(clamping: $0) }
        var resonators = [Int32](repeating: 0, count: 8)
        var out = gl_portal_evidence()
        resonators.withUnsafeMutableBufferPointer { buffer in
            gl_portal_parser_read(arena.array(converted), Int32(converted.count), PaceABI.optional(badgeHue), time,
                                  PaceABI.faction(faction), arena.array(yellow), Int32(yellow.count),
                                  buffer.baseAddress, &out)
        }
        let read = resonators.prefix(Int(out.resonatorCount)).map { Int($0) }
        return PortalScreenEvidence(sourceTime: out.sourceTime, resonators: read, unreadSlots: Int(out.unreadSlots),
                                    badgeHue: out.badgeHue.has ? out.badgeHue.value : nil,
                                    faction: PaceABI.faction(out.faction))
    }

    public static func isLevelOneYellow(hues: [Double]) -> Bool {
        hues.withUnsafeBufferPointer { gl_portal_parser_is_level_one_yellow($0.baseAddress, Int32($0.count)) }
    }

    /// `PortalScreenParser.levels(in:)`.
    public static func levels(in text: String) -> [Int] {
        PaceABI.withString(text) { input in
            var capacity: Int32 = 16
            while true {
                var out = [Int32](repeating: 0, count: Int(capacity))
                let count = out.withUnsafeMutableBufferPointer { gl_portal_parser_levels(input, $0.baseAddress, capacity) }
                if count <= capacity { return out.prefix(Int(count)).map { Int($0) } }
                capacity = count
            }
        }
    }
}

/// `PortalLevelRules` in C++. Where Swift would trap on an empty range (more
/// than eight levels read), these return nil.
public enum CxxPortalLevelRules {
    public static func levels(forGlyphCount count: Int) -> ClosedRange<Int>? {
        range(gl_portal_rules_levels_for_glyph_count(Int32(clamping: count)))
    }

    public static func levels(forBadgeHue hue: Double) -> ClosedRange<Int>? {
        range(gl_portal_rules_levels_for_badge_hue(hue))
    }

    public static func levels(forResonators read: [Int], unread: Int) -> ClosedRange<Int>? {
        let levels = read.map { Int32(clamping: $0) }
        var out = gl_portal_levels()
        let made = levels.withUnsafeBufferPointer {
            gl_portal_rules_levels_for_resonators($0.baseAddress, Int32($0.count), Int32(clamping: unread), &out)
        }
        return made ? range(out) : nil
    }

    public static func estimate(screen: PortalScreenEvidence?, glyphCount: Int?,
                                glyphCountSettled: Bool = true) -> PortalLevelEstimate? {
        estimate(resonators: screen?.resonators, unreadSlots: screen?.unreadSlots, badgeHue: screen?.badgeHue,
                 glyphCount: glyphCount, glyphCountSettled: glyphCountSettled, faction: screen?.faction)
    }

    public static func estimate(resonators: [Int]?, unreadSlots: Int?, badgeHue: Double?,
                                glyphCount: Int?, glyphCountSettled: Bool = true) -> PortalLevelEstimate? {
        estimate(resonators: resonators, unreadSlots: unreadSlots, badgeHue: badgeHue, glyphCount: glyphCount,
                 glyphCountSettled: glyphCountSettled, faction: nil)
    }

    private static func estimate(resonators: [Int]?, unreadSlots: Int?, badgeHue: Double?, glyphCount: Int?,
                                 glyphCountSettled: Bool, faction: PortalFaction?) -> PortalLevelEstimate? {
        let levels = (resonators ?? []).map { Int32(clamping: $0) }
        var out = gl_portal_estimate()
        let made = levels.withUnsafeBufferPointer { buffer in
            var input = gl_portal_rules_input(
                hasResonators: resonators != nil, resonators: buffer.baseAddress, resonatorCount: Int32(buffer.count),
                unreadSlots: PaceABI.optional(unreadSlots), badgeHue: PaceABI.optional(badgeHue), glyphCount: PaceABI.optional(glyphCount),
                faction: PaceABI.faction(faction))
            return gl_portal_rules_estimate_settled(&input, glyphCountSettled, &out)
        }
        guard made else { return nil }
        let badgeLevels: [Int]? = out.hasBadgeLevels
            ? withUnsafeBytes(of: out.badgeLevels) { Array($0.bindMemory(to: Int32.self).prefix(Int(out.badgeLevelCount))) }
                .map { Int($0) }
            : nil
        // The inputs echo back as given, not through the ABI's 32 bits.
        return .make(level: out.level.has ? Int(out.level.value) : nil, lowest: Int(out.lowest),
                     highest: Int(out.highest), confidence: confidence(out.confidence), conflict: out.conflict,
                     resonators: resonators, unreadSlots: unreadSlots, badgeLevels: badgeLevels,
                     glyphCount: glyphCount, factionCode: PaceABI.faction(out.faction)?.rawValue)
    }

    private static func confidence(_ cxx: gl_portal_confidence) -> PortalLevelEstimate.Confidence {
        switch cxx {
        case GL_PORTAL_CONFIDENCE_HIGH: .high
        case GL_PORTAL_CONFIDENCE_MEDIUM: .medium
        default: .low
        }
    }

    private static func range(_ levels: gl_portal_levels) -> ClosedRange<Int>? {
        levels.has ? Int(levels.lowest)...Int(levels.highest) : nil
    }
}
