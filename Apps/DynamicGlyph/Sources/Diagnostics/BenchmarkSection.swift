import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import GlyphRecognition

/// Where the benchmark is offered: TestFlight, and builds from Xcode run in
/// Debug or in the Simulator. Never in an App Store build.
enum BenchmarkAvailability {
    static var isAvailable: Bool {
        #if DEBUG || targetEnvironment(simulator)
        return true
        #else
        return isTestFlight
        #endif
    }

    /// TestFlight installs carry a sandbox receipt; App Store ones a
    /// production receipt. Read through a protocol, as the property is
    /// deprecated in favour of an asynchronous StoreKit call that may ask the
    /// player to sign in.
    static var isTestFlight: Bool {
        (Bundle.main as ReceiptLocating).appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }
}

private protocol ReceiptLocating {
    var appStoreReceiptURL: URL? { get }
}

extension Bundle: ReceiptLocating {}

/// Runs the benchmark and keeps its report for as long as the app runs, so
/// leaving Diagnostics neither stops a run nor loses the result.
@MainActor
final class RecordingBenchmarkModel: ObservableObject {
    static let shared = RecordingBenchmarkModel()

    struct Progress: Equatable {
        var run: Int
        var runs: Int
        var powerSaving: Bool
        var pace: BenchmarkPace
        var fraction: Double
    }

    @Published var mode: BenchmarkMode = .both
    @Published var passes: BenchmarkPasses = .both
    @Published private(set) var progress: Progress?
    @Published private(set) var fileName: String?
    @Published private(set) var lines: [String] = []
    @Published private(set) var message: String?

    var isRunning: Bool { progress != nil }

    private var cancellation: BenchmarkCancellation?
    private var watchers: Set<AnyCancellable> = []

    func start(_ url: URL, engine: CaptureEngine) {
        guard !isRunning else { return }
        guard !engine.isCapturing, !engine.isPreparing else {
            message = "Stop the capture session first."
            return
        }
        guard !engine.assistsGlyphs || engine.shapeTable != nil else {
            message = "Add a shape list first: hacks are read with it."
            return
        }
        let configuration = BenchmarkConfiguration(
            table: engine.assistsGlyphs ? engine.shapeTable : nil, sequenceTable: engine.sequenceTable,
            readsResults: engine.results.readsResults, readsGear: engine.results.readsGear,
            language: engine.gameLanguage ?? GameLanguageMemory.startingGuess(
                remembered: engine.detectedGameLanguage, preferredLanguages: Locale.preferredLanguages),
            automaticLanguage: engine.gameLanguage == nil)
        let cancellation = BenchmarkCancellation()
        self.cancellation = cancellation
        // Accuracy Off, accuracy On, then real pace Off and On.
        let runs = passes.paces.flatMap { pace in mode.runs.map { (pace: pace, powerSaving: $0) } }
        fileName = url.lastPathComponent
        lines = []
        message = nil
        progress = Progress(run: 1, runs: runs.count, powerSaving: runs[0].powerSaving, pace: runs[0].pace,
                            fraction: 0)
        // A capture session needs the meter's text-read hook and the CPU:
        // the benchmark gives way to it. So it does when the app leaves the
        // screen, where real-time pacing no longer holds.
        engine.$isCapturing.filter { $0 }.sink { [weak self] _ in self?.cancel("A capture session started.") }
            .store(in: &watchers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.cancel("The app left the screen.") }
            .store(in: &watchers)
        // A run lasts as long as the movie: the screen must stay on.
        UIApplication.shared.isIdleTimerDisabled = true

        let accessing = url.startAccessingSecurityScopedResource()
        Task { [self] in
            var results: [BenchmarkRunResult] = []
            var failure: String?
            for (index, run) in runs.enumerated() where !cancellation.isCancelled {
                progress = Progress(run: index + 1, runs: runs.count, powerSaving: run.powerSaving, pace: run.pace,
                                    fraction: 0)
                do {
                    // Each run decodes the file anew.
                    let source = try await BenchmarkFrameSource(url: url)
                    let result = await Self.run(source, configuration: configuration, powerSaving: run.powerSaving,
                                                pace: run.pace, cancellation: cancellation) { [weak self] fraction in
                        Task { @MainActor in self?.progress?.fraction = fraction }
                    }
                    results.append(result)
                    lines = BenchmarkReport.report(results)
                    if let error = result.error { failure = error; break }
                } catch {
                    failure = String(describing: error)
                    break
                }
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
            UIApplication.shared.isIdleTimerDisabled = false
            watchers.removeAll()
            if let failure { message = failure }
            progress = nil
            self.cancellation = nil
        }
    }

    func cancel(_ reason: String? = nil) {
        guard let cancellation, !cancellation.isCancelled else { return }
        cancellation.cancel()
        if let reason { message = "Cancelled: " + reason }
    }

    /// On a thread of its own: the run sleeps between frames.
    nonisolated private static func run(_ source: BenchmarkFrameSource, configuration: BenchmarkConfiguration,
                                        powerSaving: Bool, pace: BenchmarkPace,
                                        cancellation: BenchmarkCancellation,
                                        progress: @escaping @Sendable (Double) -> Void) async -> BenchmarkRunResult {
        let box = UncheckedBox(source)
        return await withCheckedContinuation { done in
            let thread = Thread {
                let runner = BenchmarkRunner(configuration: configuration, powerSaving: powerSaving, pace: pace,
                                             cancellation: cancellation, progress: progress)
                done.resume(returning: runner.run(box.value))
            }
            thread.name = "org.szres.DynamicGlyph.benchmark.feeder"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

/// Hands a value to the thread that alone uses it from then on.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Settings > Diagnostics > Benchmark: a screen recording from Files, run
/// through the capture pipeline in real time with power saving off, on, or
/// both. A tester tool, so its text stays untranslated like the readouts
/// around it. The recording is read where it lies and never copied or sent.
struct BenchmarkSection: View {
    @ObservedObject var engine: CaptureEngine
    @ObservedObject private var model = RecordingBenchmarkModel.shared
    @State private var choosing = false

    var body: some View {
        if BenchmarkAvailability.isAvailable {
            Section {
                Picker(selection: $model.mode) {
                    Text(verbatim: "Off").tag(BenchmarkMode.off)
                    Text(verbatim: "On").tag(BenchmarkMode.on)
                    Text(verbatim: "Both").tag(BenchmarkMode.both)
                } label: {
                    Text(verbatim: "Power saving")
                }
                .disabled(model.isRunning)
                Picker(selection: $model.passes) {
                    Text(verbatim: "Accuracy").tag(BenchmarkPasses.accuracy)
                    Text(verbatim: "Real pace").tag(BenchmarkPasses.realTime)
                    Text(verbatim: "Both").tag(BenchmarkPasses.both)
                } label: {
                    Text(verbatim: "Passes")
                }
                .disabled(model.isRunning)
                if let progress = model.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Run \(progress.run) of \(progress.runs) · \(progress.pace.label) · "
                             + "power saving " + (progress.powerSaving ? "on" : "off"))
                        ProgressView(value: progress.fraction)
                        if let name = model.fileName {
                            Text(verbatim: name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Button(role: .destructive) { model.cancel() } label: { Text(verbatim: "Cancel") }
                } else {
                    Button { choosing = true } label: { Text(verbatim: "Choose screen recording…") }
                        .disabled(engine.isCapturing || engine.isPreparing)
                        .fileImporter(isPresented: $choosing, allowedContentTypes: [.movie]) { result in
                            if case .success(let url) = result { model.start(url, engine: engine) }
                        }
                }
                if let message = model.message {
                    Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                }
                if !model.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { Text(verbatim: $0.element) }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = model.lines.joined(separator: "\n")
                    } label: {
                        Text(verbatim: "Copy")
                    }
                }
            } header: {
                Text(verbatim: "Benchmark")
            } footer: {
                Text(verbatim: "Runs a screen recording through the capture pipeline with power saving off, on, "
                     + "or off then on. Accuracy feeds every frame a capture would deliver (20 a second) and "
                     + "waits for each to be read, so nothing is dropped and a run repeats exactly: it compares "
                     + "the Glyphs and hack starts, in movie time. Real pace plays the movie as a live capture, "
                     + "dropping what live capture would drop, for the power figures. "
                     + "Nothing is saved to results or statistics, and the Island, the floating window and "
                     + "the Power section are left alone. The recording stays where it is. "
                     + "Hack start: from the first frame the header showed the hack's first phase "
                     + "(in Both, as the Off run saw it) to the frame the hack was recognised. "
                     + "CPU is this app's, including decoding the movie.")
            }
        }
    }
}
