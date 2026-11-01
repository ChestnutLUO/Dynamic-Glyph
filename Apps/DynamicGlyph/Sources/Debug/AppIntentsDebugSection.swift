#if DEBUG || targetEnvironment(simulator)
import SwiftUI

/// Runs the Shortcuts and Siri actions' own code from Settings, so they can
/// be tried where Siri can't reach, such as an unsigned Simulator build, and
/// shows what each would say. Like the benchmark, never in an App Store build.
struct AppIntentsDebugSection: View {
    var body: some View {
        Section {
            NavigationLink {
                AppIntentsDebugView()
            } label: {
                Text(verbatim: "App Intents")
            }
            .accessibilityIdentifier("debug-intents")
        } footer: {
            Text(verbatim: "Debug and Simulator only. Runs each Shortcuts action as Siri would.")
        }
    }
}

private struct AppIntentsDebugView: View {
    @State private var outcome = ""
    @State private var isRunning = false

    var body: some View {
        Form {
            Section {
                Button {
                    run {
                        let answer = await StartCaptureIntent.run()
                        return String(localized: answer.dialog)
                    }
                } label: {
                    Text(verbatim: "Start Dynamic Glyph")
                }
                .accessibilityIdentifier("debug-intents-start")
                Button {
                    run {
                        let outcome = await StopCaptureIntent.run()
                        return String(localized: outcome.dialog)
                    }
                } label: {
                    Text(verbatim: "Stop Dynamic Glyph")
                }
                .accessibilityIdentifier("debug-intents-stop")
                ForEach(StatisticsShortcutPeriod.allCases, id: \.self) { period in
                    Button {
                        run {
                            OpenStatisticsIntent.run(period)
                            return "Open Statistics: \(period.rawValue) (no dialog)"
                        }
                    } label: {
                        Text(verbatim: "Open Statistics: \(period.rawValue)")
                    }
                    .accessibilityIdentifier("debug-intents-statistics-\(period.rawValue)")
                }
            }
            .disabled(isRunning)
            Section {
                Text(verbatim: isRunning ? "Running…" : outcome)
                    .accessibilityIdentifier("debug-intents-outcome")
            } header: {
                Text(verbatim: "Outcome")
            }
        }
        .navigationTitle(Text(verbatim: "App Intents"))
    }

    private func run(_ action: @escaping @MainActor () async -> String) {
        isRunning = true
        Task { @MainActor in
            outcome = await action()
            isRunning = false
        }
    }
}
#endif
