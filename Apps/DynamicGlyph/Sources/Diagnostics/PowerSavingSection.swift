import Combine
import SwiftUI

/// The before/after switch for power saving, at the end of
/// Diagnostics, shown only where the tester tools are (not in App Store
/// builds). A tester control, so its text stays untranslated like the
/// readouts around it. Read when a capture starts.
///
/// Under it, the engine A/B: which arm runs the pixel
/// steps, which runs the logic after them, and the power cuts the engine runs
/// with, each a switch. Also read when a capture starts, and by the recording
/// benchmark.
///
/// Where the benchmark is offered (TestFlight, Debug, the Simulator), a
/// second switch colours the floating window's background by the gate's
/// mode, live, with its colours legend below it. Its text is translated.
struct PowerSavingSection: View {
    @AppStorage(AppPreferences.powerSavingKey) private var enabled = true
    @AppStorage(AppPreferences.recognitionEngineKey) private var engine = AppPreferences.defaultRecognitionEngine
    @AppStorage(AppPreferences.recognitionLogicKey) private var logic = AppPreferences.defaultRecognitionLogic
    @AppStorage(AppPreferences.colorsFloatingWindowByModeKey) private var colorsByMode = false
    /// The cuts are a set, which `@AppStorage` doesn't hold: read once, and
    /// written through the preferences on every change.
    @State private var cuts = AppPreferences().recognitionCuts

    var body: some View {
        // Tester tools: Debug, the Simulator and TestFlight only. Elsewhere
        // power saving is always on (`AppPreferences.effectivePowerSaving`).
        if BenchmarkAvailability.isAvailable { section }
    }

    private var section: some View {
        Section {
            Toggle(isOn: $enabled) { Text(verbatim: "Power saving") }
            SlowdownReadout()
            Picker(selection: $engine) {
                ForEach(RecognitionEngineChoice.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
            } label: {
                Text("Recognition engine")
            }
            Picker(selection: $logic) {
                ForEach(RecognitionLogicChoice.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
            } label: {
                Text("Recognition logic")
            }
            ForEach(RecognitionCut.allCases, id: \.self) { cut in
                Toggle(isOn: binding(cut)) {
                    VStack(alignment: .leading, spacing: 2) {
                        title(cut)
                        explanation(cut).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if BenchmarkAvailability.isAvailable {
                Toggle(isOn: $colorsByMode) { Text("Color floating window by reading mode") }
                    .onChange(of: colorsByMode) { _, _ in ReadingModeSignal.shared.applyPreference() }
                ReadingModeLegend()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Rests analysis on the map, reads the header less often between hacks, analyzes only the newest frame, and halves rates in Low Power Mode or when the iPhone is hot. Off runs the pipeline as before. Takes effect at the next Start.")
                Text("Unless set here or in Settings, a capture runs New: the C++ engine with Swift logic, Direct planes, Lazy image, both hunt cuts, Plane gate, Header still skip and Gear lean read. Old is the Swift engine and logic with no cuts. The engine and its cuts take effect at the next Start; Power says which engine ran. Only the C++ engine honours Direct planes and the hunt cuts.",
                     comment: "Diagnostics, Power saving, engine A/B: footer. 'New' and 'Old' are the two choices of Settings' Recognition engine page; 'Direct planes', 'Lazy image', the hunt cuts, 'Plane gate', 'Header still skip' and 'Gear lean read' are the switch titles above. 'Power' is the untranslated title of a Diagnostics section; 'Start' the capture button.")
                Text("Recognition logic runs the sequence tracking, result, gear and command reading, and the text parsers in Swift or C++. It takes effect at the next Start; Power says which ran.")
                if BenchmarkAvailability.isAvailable {
                    Text("For testing with power saving on. Colors show the reading mode, not measured speed. Power shows the mode and maximum reading rate.")
                }
            }
        }
    }

    private func binding(_ cut: RecognitionCut) -> Binding<Bool> {
        Binding(get: { cuts.contains(cut) }, set: { on in
            if on { cuts.insert(cut) } else { cuts.remove(cut) }
            AppPreferences().recognitionCuts = cuts
        })
    }

    private func title(_ cut: RecognitionCut) -> Text {
        switch cut {
        case .directPlanes: return Text("Direct planes")
        case .lazyImage: return Text("Lazy image")
        case .huntBand: return Text("Hunt in the array band")
        case .huntHalf: return Text("Hunt at half resolution")
        case .planeGate: return Text("Plane gate")
        case .portalSettle: return Text("Portal settle")
        case .headerStillSkip: return Text("Header still skip")
        case .gearSettle: return Text("Gear settle")
        case .resultSettle: return Text("Result settle")
        case .gearLeanRead: return Text("Gear lean read")
        case .gearLanguageSettle: return Text("Gear language settle")
        case .headerWindowMask: return Text("Header window mask")
        case .headerCoverSkip: return Text("Header cover skip")
        }
    }

    private func explanation(_ cut: RecognitionCut) -> Text {
        switch cut {
        case .directPlanes:
            return Text("Reads luma and colour from the captured planes, without the Core Image render. C++ only.")
        case .lazyImage:
            return Text("Renders the frame only when the text reader takes it, not for every analysed frame.")
        case .huntBand:
            return Text("Searches for the node array only in the rows the gate calls the array area. C++ only.")
        case .huntHalf:
            return Text("Finds ring components on every second pixel, then measures them on the full pixels. C++ only.")
        case .planeGate:
            return Text("Skips rendering the drone footer and the command band when the captured planes show nothing there.")
        case .portalSettle:
            return Text("Stops reading a portal screen once its levels have settled.")
        case .headerStillSkip:
            return Text("Skips reading the header while it has not changed since the last read, at most a second, during a hack too.")
        case .gearSettle:
            return Text("Once every row of a gear drop panel is confirmed, reads it only once a second while it stays still.")
        case .resultSettle:
            return Text("Once a hack's result is complete and read the same twice, reads it only once a second while it stays still.")
        case .gearLeanRead:
            return Text("Skips rereading a gear row read whole with a red quantity or an empty cell, and the separate quantity check in a game not in English.")
        case .gearLanguageSettle:
            return Text("Once the game's language is found, reads gear drop panels in it alone unless a panel shows another language.")
        case .headerWindowMask:
            return Text("With Header still skip, leaves the floating window out when it covers part of the header, so that changes inside the window alone don't cause a read.")
        case .headerCoverSkip:
            return Text("Doesn't read the header while the floating window covers at least half of it, as nothing can be read there.")
        }
    }
}

/// What slows recognition right now (Low Power Mode, heat), live. A tester
/// readout, untranslated like the others.
private struct SlowdownReadout: View {
    @State private var slowdown = Self.read()

    var body: some View {
        Text(verbatim: "Slowed: \(slowdown)")
            .foregroundStyle(.secondary)
            .onReceive(Publishers.Merge(
                NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange),
                NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification))
                .receive(on: DispatchQueue.main)) { _ in slowdown = Self.read() }
    }

    private static func read() -> String {
        // The shared conditions refresh on these notifications too, on
        // whichever thread posts them: read them fresh rather than race.
        PowerConditions.shared.refresh()
        return PowerConditions.shared.current.slowdown
    }
}

/// The four fills, each with its mode and what it means.
private struct ReadingModeLegend: View {
    /// Swatch side: 12 pt at the default size, growing with the text and
    /// capped at 28 pt, so it doesn't shrink to a dot.
    @ScaledMetric(relativeTo: .subheadline) private var swatchSide: CGFloat = 12
    /// Half the footnote's cap height, so the swatch centres on the first
    /// line's capitals and stays beside the mode name when the line wraps.
    @ScaledMetric(relativeTo: .footnote) private var halfCapHeight: CGFloat = 4.6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(.idle, Text("Idle: map or other screens, read slowly"))
            row(.waiting, Text("Waiting: game screen, read slowly until a hack"))
            row(.reading, Text("Reading: full rate, including during a hack"))
            row(.backingOff, Text("Backing off: Low Power Mode or heat halves the maximum reading rate"))
        }
        .font(.footnote)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func row(_ tint: ReadingModeTint, _ label: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(cgColor: tint.fill ?? CGColor(gray: 0, alpha: 0)))
                // The darkest fills are close to a dark cell's own colour.
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                .frame(width: min(swatchSide, 28), height: min(swatchSide, 28))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + halfCapHeight }
                .accessibilityHidden(true)
            label.fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ReadingModeSignal {
    /// Shows the fill when the Diagnostics switch is on, in builds that
    /// offer it. Read when the floating window starts and when the switch
    /// changes, so it applies to an open window at once.
    func applyPreference() {
        isShown = BenchmarkAvailability.isAvailable && AppPreferences().colorsFloatingWindowByMode
    }
}
