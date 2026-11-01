import SwiftUI
import UIKit
import GlyphRecognition

/// The readouts the research build put on its main screen, unchanged in
/// substance, for testers and bug reports.
struct DiagnosticsView: View {
    @ObservedObject var engine: CaptureEngine

    var body: some View {
        List {
            if !engine.sessionDiagnosticsEnabled {
                Section {
                    Text("Recognition and capture readouts are gathered only while Save logs and screenshots is on, so the app does no extra work without it.")
                        .font(.caption)
                }
            }
            Section("Session") {
                Text(engine.status).font(.caption)
                row("folder", engine.evidenceFolder ?? "-")
                Text(engine.tableStatus).font(.caption)
                Text(engine.sequenceStatus).font(.caption)
            }
            Section("Recognition") { recognitionReadout }
            Section("Capture") { captureReadout }
            Section("Floating window") {
                Text(engine.pip.status).font(.caption)
                if let size = engine.pip.renderSize {
                    row("window", "\(size) · source \(engine.pip.canvas.pixelWidth)×\(engine.pip.canvas.pixelHeight)")
                }
                let stats = engine.pip.stats
                Text(String(format: "%llu ticks · %llu enqueued · %llu redraws · %llu not ready · %llu pool misses · %llu renderer failures",
                            stats.ticks, stats.enqueued, stats.redraws, stats.notReady,
                            stats.poolExhausted, stats.rendererFailures))
                    .font(.system(size: 11, design: .monospaced))
            }
            Section("Dynamic Island") {
                Text(engine.activity.status).font(.caption)
                Text(String(format: "%d updates sent · %d coalesced · last request %.0f ms",
                            engine.activity.updatesSent, engine.activity.updatesCoalesced,
                            engine.activity.lastUpdateMilliseconds))
                    .font(.system(size: 11, design: .monospaced))
                Text(String(format: "%d new content · %d renewals only · %d compact changed",
                            engine.activity.updatesChangedKey, engine.activity.updatesRenewalOnly,
                            engine.activity.updatesChangedCompact))
                    .font(.system(size: 11, design: .monospaced))
            }
            // A tester readout: Debug, the Simulator and TestFlight only.
            if BenchmarkAvailability.isAvailable {
                Section {
                    // Read once a second while shown; the meter counts whether
                    // or not anyone looks, and whether or not logs are kept.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(PowerReport.lines(PowerMeter.shared.snapshot()).enumerated()), id: \.offset) {
                                Text($0.element)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                    Button {
                        UIPasteboard.general.string = PowerReport.lines(PowerMeter.shared.snapshot())
                            .joined(separator: "\n")
                    } label: {
                        Text(verbatim: "Copy")
                    }
                } header: {
                    Text(verbatim: "Power")
                } footer: {
                    // Raw readouts, like the logs they mirror, stay untranslated.
                    Text(verbatim: "This capture session, frozen at Stop. /min is the rate over the last 60 s. Text reads are Vision requests, "
                         + "timed as they run. Steps: ms/run, ms per analysed frame this session, and over the last 60 s. "
                         + "Longest: each one's slowest run and when it ended (m:ss into the session). "
                         + "Untimed is CPU time minus the timed work that does not overlap. "
                         + "CPU is this app's, in % of one core; on iOS 18-26 the broadcast extension's is not included.")
                }
            }
            Section {
                ForEach(engine.recognitionHistory, id: \.self) { line in
                    Text(line).font(.system(size: 12, design: .monospaced))
                }
            } header: {
                Text("Recent observations · newest first")
            } footer: {
                Text("Shapes as the recognizer saw them, with the tracked phase in brackets. A shape here is not a slot: only the sequence reflects verified boundaries.")
            }
            Section("Capture events") {
                ForEach(engine.events, id: \.self) { line in
                    Text(line).font(.system(size: 11, design: .monospaced))
                }
            }
            PowerSavingSection()
            BenchmarkSection(engine: engine)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var recognitionReadout: some View {
        if let result = engine.recognition {
            Text(result.state == "uniqueVisibleShape" ? result.names.joined(separator: ", ") : result.state)
                .font(.headline)
            // Raw readouts, like the logs they mirror, stay untranslated.
            Text(verbatim: "\(result.extensions) possible longer shapes · phase \(result.phase)").font(.caption)
            Text(verbatim: "slots: \(result.slotSummary)").font(.caption)
            Text(verbatim: "header: \(result.headerSummary)").font(.caption)
            Text(result.calibration).font(.caption)
            Text(String(format: "%d samples · %.1f ms/sample · %d screenshots queued",
                        result.samples, result.milliseconds, result.snapshotCount)).font(.caption)
            Text(engine.display.calibrationSummary).font(.caption)
            if let error = result.error { Text(error).font(.caption).foregroundStyle(.red) }
        } else {
            Text("Calibration is acquired automatically when all 11 empty node rings are visible.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var captureReadout: some View {
        let counters = engine.recognition?.counters ?? CaptureCounters()
        let f = engine.recognition?.lastFacts
        row("frames", "\(counters.frames)")
        // A stream of `.idle` frames is not a pass: it means nothing on the
        // display changed, which is what a frozen capture looks like.
        row("complete", "\(counters.completeFrames)   idle \(counters.idleFrames)")
        row("changed", "\(counters.changedFrames)")
        row("images", "\(engine.imagesSaved)")
        row("size", f.map { "\($0.width)x\($0.height)  \($0.pixelFormat)" } ?? "-")
        row("status", f?.status.rawValue ?? "-")
        row("orientation", f?.orientation.map(String.init) ?? "-")
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).font(.system(size: 12, design: .monospaced)) }
    }
}
