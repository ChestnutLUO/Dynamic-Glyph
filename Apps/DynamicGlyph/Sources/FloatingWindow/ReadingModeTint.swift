import CoreGraphics
import Foundation
import os
import GlyphRecognition

/// The floating window's debug fill: what the analysis gate is doing now, as
/// the colour behind the Glyphs. A TestFlight-only switch in Diagnostics
/// turns it on; off, the window keeps its own background exactly.
///
/// Only the interior background changes (and the small masks the renderer
/// cuts out of it, such as behind an input check's badge). The status edge,
/// the strokes, the text and the layout stay as they are.
enum ReadingModeTint: UInt8, CaseIterable, Sendable {
    /// The renderer's own background: debug off, power saving off, or no
    /// analysis yet.
    case none
    /// `quiet`: the map or another screen without the game's hack view.
    case idle
    /// `resting`: a still game screen, waiting for a hack.
    case waiting
    /// `active`: full speed, including every hack.
    case reading
    /// Low Power Mode or heat is actually halving the analysis rate. Inside a
    /// hack the rate stays full, so this never shows there.
    case backingOff

    /// The interior fill, or nil for the renderer's own background: the
    /// design note's reference fills (Colo, msgs 749 and 758). Every stroke keeps at least 3:1
    /// and every message 4.5:1 on each (see `ReadingModeTintTests`). The
    /// Diagnostics legend reads them from here too.
    var fill: CGColor? {
        switch self {
        case .none: return nil
        case .idle: return Self.color(0x333336)
        case .waiting: return Self.color(0x3D2470)
        case .reading: return Self.color(0x0B3D24)
        case .backingOff: return Self.color(0x4A2900)
        }
    }

    /// The colours legend order: every tint that has a fill.
    static let legend: [ReadingModeTint] = [.idle, .waiting, .reading, .backingOff]

    /// In sRGB, so the window shows the reference hex values themselves.
    /// `CGColor(red:green:blue:alpha:)` is generic RGB, which the frame's
    /// device RGB turns lighter: #17191F came out as #1E2129.
    private static func color(_ hex: UInt32) -> CGColor {
        let components: [CGFloat] = [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                     CGFloat(hex & 0xFF) / 255, 1]
        return CGColorSpace(name: CGColorSpace.sRGB).flatMap { CGColor(colorSpace: $0, components: components) }
            ?? CGColor(red: components[0], green: components[1], blue: components[2], alpha: 1)
    }
}

/// The gate's pace for one 20-Hz look, as it actually is: the mode it chose
/// and the interval it set. A plain value, built per look without allocating.
struct ReadingMode: Equatable, Sendable {
    var mode: AnalysisRateController.Mode
    /// Minimum seconds between analysed frames now.
    var interval: Double
    var powerSaving: Bool
    var inHack: Bool
    /// The interval the mode has when nothing constrains it.
    var nominalInterval: Double

    init(mode: AnalysisRateController.Mode, interval: Double, powerSaving: Bool, inHack: Bool,
         policy: AnalysisRateController.Policy = .init()) {
        self.mode = mode
        self.interval = interval
        self.powerSaving = powerSaving
        self.inHack = inHack
        nominalInterval = mode == .active ? policy.activeInterval : policy.quietInterval
    }

    init(_ decision: AnalysisRateController.Decision, powerSaving: Bool, inHack: Bool,
         policy: AnalysisRateController.Policy) {
        self.init(mode: decision.mode, interval: decision.interval, powerSaving: powerSaving, inHack: inHack,
                  policy: policy)
    }

    /// Low Power Mode or heat is slowing analysis down right now. Read from
    /// the interval the gate set, not from the conditions: in a hack the gate
    /// keeps the full rate even in Low Power Mode, and then this is false.
    var isBackingOff: Bool { powerSaving && interval > nominalInterval + 0.0005 }

    var tint: ReadingModeTint {
        guard powerSaving else { return .none }
        if isBackingOff { return .backingOff }
        switch mode {
        case .quiet: return .idle
        case .resting: return .waiting
        case .active: return .reading
        }
    }

    /// Analyses a second at most, at the current interval: 20, 10, 4 or 2.
    var ratePerSecond: Int { interval > 0 ? Int((1 / interval).rounded()) : 0 }

    /// The Diagnostics readout's words for the mode, in English like the
    /// rest of that readout. The same words as the colours legend.
    var label: String {
        guard powerSaving else { return "Off (saving off)" }
        let name: String
        switch mode {
        case .quiet: name = "Idle"
        case .resting: name = "Waiting"
        case .active: name = inHack ? "Reading (hack)" : "Reading"
        }
        return isBackingOff ? "Backing off (\(name))" : name
    }
}

/// Hands the live capture's tint to the floating window's render loop.
/// Written by the analysis queue only when the tint changes, read by the
/// render loop at 15 Hz; an uncontended `os_unfair_lock` either way.
final class ReadingModeSignal: @unchecked Sendable {
    /// The live capture's. The benchmark and tests use their own, or none.
    static let shared = ReadingModeSignal()

    private struct State {
        var tint = ReadingModeTint.none
        var isShown = false
        var changes: UInt64 = 0
    }

    private var state = State()
    private let lock: os_unfair_lock_t

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body(&state)
    }

    /// The tint the gate's pace calls for now.
    func publish(_ tint: ReadingModeTint) {
        withLock { state in
            guard state.tint != tint else { return }
            state.tint = tint
            state.changes &+= 1
        }
    }

    /// The Diagnostics switch, where it is offered.
    var isShown: Bool {
        get { withLock { $0.isShown } }
        set { withLock { $0.isShown = newValue } }
    }

    var tint: ReadingModeTint { withLock { $0.tint } }

    /// What the floating window draws: the tint while the switch is on,
    /// otherwise its own background.
    var displayed: ReadingModeTint { withLock { $0.isShown ? $0.tint : .none } }

    /// How many times the tint changed: once per change, never per frame.
    var changes: UInt64 { withLock { $0.changes } }
}
