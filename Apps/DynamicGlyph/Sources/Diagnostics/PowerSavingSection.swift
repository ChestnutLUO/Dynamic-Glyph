import Combine
import SwiftUI

/// The before/after switch for power saving, at the end of
/// Diagnostics, shown only where the tester tools are (not in App Store
/// builds). A tester control, so its text stays untranslated like the
/// readouts around it. Read when a capture starts.
///
/// Where the benchmark is offered (TestFlight, Debug, the Simulator), a
/// second switch colours the floating window's background by the gate's
/// mode, live, with its colours legend below it. Its text is translated.
struct PowerSavingSection: View {
    @AppStorage(AppPreferences.powerSavingKey) private var enabled = true
    @AppStorage(AppPreferences.colorsFloatingWindowByModeKey) private var colorsByMode = false

    var body: some View {
        // Tester tools: Debug, the Simulator and TestFlight only. Elsewhere
        // power saving is always on (`AppPreferences.effectivePowerSaving`).
        if BenchmarkAvailability.isAvailable { section }
    }

    private var section: some View {
        Section {
            Toggle(isOn: $enabled) { Text(verbatim: "Power saving") }
            SlowdownReadout()
            if BenchmarkAvailability.isAvailable {
                Toggle(isOn: $colorsByMode) { Text("Color floating window by reading mode") }
                    .onChange(of: colorsByMode) { _, _ in ReadingModeSignal.shared.applyPreference() }
                ReadingModeLegend()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Rests analysis on the map, reads the header less often between hacks, analyzes only the newest frame, and halves rates in Low Power Mode or when the iPhone is hot. Off runs the pipeline as before. Takes effect at the next Start.")
                if BenchmarkAvailability.isAvailable {
                    Text("For testing with power saving on. Colors show the reading mode, not measured speed. Power shows the mode and maximum reading rate.")
                }
            }
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
    /// capped at 28 pt (Colo, msg 764), so it doesn't shrink to a dot.
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
