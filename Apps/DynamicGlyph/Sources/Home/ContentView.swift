import Combine
import GlyphRecognition
import SwiftUI
import TipKit
import UIKit
import UniformTypeIdentifiers

/// The app's tabs: the live sequence with its one thing to tap, the results
/// the game showed after each hack, and Settings, which holds everything a
/// tester needs without it being the first thing anyone sees.
struct ContentView: View {
    enum AppTab: Hashable { case home, results, settings }
    private enum TableKind { case shapes, sequences }

    @StateObject private var engine = CaptureEngine()
    @State private var tab = AppTab.home
    /// The Statistics page's range, here so a widget's link can set it:
    /// Day, live, at launch. Nothing of it is kept across launches.
    @State private var statisticsSelection = StatisticsSelection.preset(.day, now: Date(), oldest: nil)
    @State private var didInitializeTimeline = false
    @State private var importingTable = false
    // Keep the destination after dismissal: SwiftUI clears isPresented before
    // delivering the selected file to onCompletion.
    @State private var importKind = TableKind.shapes
    /// Until setup is finished, every launch opens it.
    #if targetEnvironment(simulator)
    // Screenshot demo opens on Home; the saved setup state is left as it is.
    @State private var showingSetup = AppPreferences().needsSetup && !ScreenshotDemo.isEnabled
    #else
    @State private var showingSetup = AppPreferences().needsSetup
    #endif
    @Environment(\.scenePhase) private var scenePhase
    /// The chosen theme, for Start at rest.
    @Environment(\.appTheme) private var theme
    /// Bumped to ask iOS for its rating sheet (`requestsReview`).
    @State private var reviewRequest = 0
    /// The newest saved hack once Home or Statistics has been on screen
    /// with it: the result has been seen, so a later arrival may ask.
    @State private var viewedResultID: String?
    /// The wait after arriving on Home or Statistics before deciding.
    @State private var reviewArrival: Task<Void, Never>?
    /// Tips 2 and 4 done (TipKit's status), for the order of Home's tips.
    @State private var floatingWindowTipDone = false
    @State private var shortcutsTipDone = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "hexagon", value: AppTab.home) {
                home.environment(\.isPiPHostActive, tab == .home)
            }
            Tab("Statistics", systemImage: "chart.bar", value: AppTab.results) {
                NavigationStack {
                    HackResultsView(engine: engine,
                                    showsFloatingWindowPreview: engine.isCapturing && engine.pipEnabled,
                                    assistsGlyphs: engine.assistsGlyphs,
                                    sessionDiagnosticsEnabled: engine.sessionDiagnosticsEnabled,
                                    shapeTable: engine.shapeTable, results: engine.results,
                                    timelineSelection: $statisticsSelection, showsTips: showsTips)
                }
                .environment(\.isPiPHostActive, tab == .results)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(engine: engine, onRunSetup: { showingSetup = true },
                             onImportTable: { chooseTable(.shapes) },
                             onImportSequences: { chooseTable(.sequences) })
                    .environment(\.isPiPHostActive, tab == .settings)
            }
        }
        .fullScreenCover(isPresented: $showingSetup) {
            SetupView(engine: engine) { showingSetup = false }
        }
        // The tips' parameters follow the saved hacks and the capture state.
        .onChange(of: tipFacts, initial: true) { _, facts in AppTips.update(facts) }
        .task {
            for await status in FloatingWindowTip().statusUpdates { floatingWindowTipDone = AppTips.isDone(status) }
        }
        .task {
            for await status in ShortcutsTip().statusUpdates { shortcutsTipDone = AppTips.isDone(status) }
        }
        .onReceive(engine.results.$records) { _ in
            // Published as it will change; read the store's hacks after.
            DispatchQueue.main.async { AppTips.update(tipFacts) }
        }
        // The automatic rating prompt, at a calm moment: arriving on Home or
        // Statistics, a second later, when ReviewPromptPolicy allows it.
        .requestsReview(on: reviewRequest)
        .onChange(of: tab, initial: true) { _, _ in arrivedForReview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { arrivedForReview() } else { reviewArrival?.cancel() }
        }
        // Item names in the game language chosen in Settings; on Automatic,
        // the one last found, else English.
        .environment(\.gameItemLanguage, GameLanguage.itemNameLanguage(chosen: engine.gameLanguage,
                                                                        detected: engine.detectedGameLanguage))
        // The Control Center button: on a cold launch its request is already
        // waiting when this screen appears, on a warm one it arrives while
        // the app comes forward or is already in front.
        .onAppear { answerControlStart(scenePhase) }
        .onChange(of: scenePhase) { _, phase in answerControlStart(phase) }
        .onReceive(ControlStartInbox.shared.posted) { answerControlStart(scenePhase) }
        // Start Dynamic Glyph in Shortcuts and Siri decides as Start here
        // does, from this screen's state, before it leaves its request above.
        .onAppear {
            let setup = $showingSetup
            // Weak: the context outlives any screen; without an engine the
            // intent falls back to what is on disk.
            StartCaptureContext.shared.home = { [weak engine] in
                guard let engine else { return nil }
                return StartCaptureConditions(isReading: engine.isCapturing,
                                              isGettingReady: engine.isPreparing || engine.isStopping || setup.wrappedValue)
            }
        }
        // The Home Screen widget opens Statistics on the widget's period, cold
        // or warm. Anything presented stays, as a tab tapped by hand leaves it.
        .onAppear {
            guard !didInitializeTimeline else { return }
            didInitializeTimeline = true
            let results = engine.results
            let oldest = (results.records.map(\.date) + results.drops.map(\.date)).min()
            statisticsSelection = .preset(.day, now: Date(), oldest: oldest)
            // Open Statistics from Shortcuts or Siri, asked before the
            // results were loaded: shown now, over the Day set just above.
            answerStatisticsRequest(isReady: true)
        }
        .onOpenURL { url in
            guard case .statistics(let period)? = AppLink(url: url) else { return }
            showStatistics(period)
        }
        .onReceive(StatisticsOpenInbox.shared.posted) { answerStatisticsRequest(isReady: didInitializeTimeline) }
        // One stable presenter for both tabs. Nested importers, especially on
        // a Form row, can prevent the Settings picker from appearing.
        .closesForControlStart($importingTable)
        .fileImporter(isPresented: $importingTable,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                      allowsMultipleSelection: false) { result in
            switch importKind {
            case .shapes: engine.importTable(result)
            case .sequences: engine.importSequenceTable(result)
            }
        }
    }

    private func chooseTable(_ kind: TableKind) {
        importKind = kind
        importingTable = true
    }

    /// Statistics, on `period` when one is given; as it was otherwise.
    private func showStatistics(_ period: StatisticsPeriod?) {
        tab = .results
        if let period {
            let results = engine.results
            let oldest = (results.records.map(\.date) + results.drops.map(\.date)).min()
            statisticsSelection = .preset(StatisticsRange.Preset(period), now: Date(), oldest: oldest)
        }
    }

    /// Open Statistics' period, once the page has its results; kept until then.
    private func answerStatisticsRequest(isReady: Bool) {
        guard let period = StatisticsOpenInbox.shared.take(isReady: isReady) else { return }
        showStatistics(period)
    }

    // MARK: - Control Center

    /// Starts as Home's Start button does, once the app is in front. Running,
    /// waiting for sharing or in setup, the app is only brought forward.
    private func answerControlStart(_ phase: ScenePhase) {
        // On the next turn, once a launching scene has made its window key:
        // the iOS 18-26 sheet is presented from it.
        DispatchQueue.main.async {
            let capture: ControlStartRequest.AppState.Capture =
                engine.isCapturing || engine.isStopping ? .running
                : engine.isPreparing ? .waitingForSharing : .idle
            let app = ControlStartRequest.AppState(isActive: phase == .active,
                                                   isSettingUp: showingSetup, capture: capture)
            switch ControlStartInbox.shared.resolve(app) {
            case .start:
                // Home shows the wait and its Cancel, or why Start can't run.
                tab = .home
                // A sheet of the app's own would hide iOS's or stop it from
                // appearing, so everything presented is closed first.
                Task { @MainActor in
                    guard await PresentationDismisser.clear() else { return }
                    engine.presentPicker()
                }
            case .skip(let reason):
                if reason == .waitingForSharing { tab = .home }
                // Nothing started: the switch, which the system may show On
                // after the tap, is read again.
                ControlChannel.reload()
            case .none, .wait:
                break
            }
        }
    }

    private var home: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if engine.assistsGlyphs {
                        HalfSecondClock { now in
                            SequenceCard(snapshot: engine.display, table: engine.shapeTable,
                                         predictionsOn: engine.sequenceCount > 0, now: now)
                        }
                    } else {
                        Button { tab = .results } label: {
                            HalfSecondClock { now in
                                GearCounterCard(snapshot: engine.display, results: engine.results, now: now)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if showsTips {
                        TipView(StartTip(), arrowEdge: .bottom).homeTipStyle()
                    }
                    startButton
                    if showsTips {
                        // One slot, two tips: the daily limit and their rules
                        // show at most one.
                        TipView(ShortcutsTip(), arrowEdge: nil).homeTipStyle()
                        TipView(AppearanceTip(), arrowEdge: nil).homeTipStyle()
                    }
                    ForEach(RecordingKind.allCases, id: \.self) { kind in
                        if let message = engine.recordingWarnings.messages[kind] {
                            Label(message, systemImage: "record.circle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .card()
                        }
                    }
                    if let problem = engine.problem {
                        // Already localized by the engine, so shown verbatim.
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if engine.assistsGlyphs {
                        Button { tab = .results } label: {
                            LastHackCard(results: engine.results)
                        }
                        .buttonStyle(.plain)
                    }
                    if showsTips {
                        TipView(FloatingWindowTip(), arrowEdge: .bottom).homeTipStyle()
                    }
                    DisplayChoicesCard(engine: engine)
                    if engine.isCapturing { runningCard } else { howItWorksCard }
                }
                .padding()
            }
            .navigationTitle("Dynamic Glyph")
        }
    }

    // MARK: - Tips and the rating prompt

    /// Never while capturing, getting ready or stopping, or in setup.
    private var showsTips: Bool {
        !engine.isCapturing && !engine.isPreparing && !engine.isStopping && !showingSetup
    }

    private var tipFacts: TipFacts {
        TipFacts(saved: engine.results.savedRecords, isIdle: showsTips, floatingWindowOn: engine.pipEnabled,
                 chosenGameLanguage: engine.gameLanguage, detectedGameLanguage: engine.detectedGameLanguage,
                 floatingWindowTipDone: floatingWindowTipDone, shortcutsTipDone: shortcutsTipDone)
    }

    private func arrivedForReview() {
        reviewArrival?.cancel()
        let arrivedOn = tab
        guard arrivedOn != .settings else { return }
        reviewArrival = Task { @MainActor in
            // Not mid-transition.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, tab == arrivedOn, scenePhase == .active else { return }
            considerReview(on: arrivedOn)
        }
    }

    private func considerReview(on arrivedOn: AppTab) {
        let finished = ReviewPromptPolicy.finishedHacks(engine.results.savedRecords)
        let latest = finished.max { $0.date < $1.date }
        let screen: ReviewPromptPolicy.Screen = arrivedOn == .home ? .home : arrivedOn == .results ? .statistics : .other
        let tipShowing: Bool = switch screen {
        case .home: showsTips && (StartTip().shouldDisplay || FloatingWindowTip().shouldDisplay
                                  || ShortcutsTip().shouldDisplay || AppearanceTip().shouldDisplay)
        case .statistics: showsTips && GameLanguageTip().shouldDisplay
        case .other: false
        }
        let record = ReviewPromptRecord()
        let version = ReviewPromptRecord.currentVersion
        let now = Date()
        let input = ReviewPromptPolicy.Input(
            savedHackCount: finished.count,
            savedHackDays: ReviewPromptPolicy.distinctDays(finished),
            latestHackIsClean: latest.map(ReviewPromptPolicy.isClean) ?? false,
            screen: screen,
            hasViewedLatestResult: latest != nil && viewedResultID == latest?.id,
            isCaptureActive: engine.isCapturing || engine.isPreparing || engine.isStopping,
            isFloatingWindowUp: engine.pip.isActive || engine.pip.isOpening,
            isPresentingSomething: showingSetup || importingTable || PresentationDismisser.isPresenting,
            isTipShowing: tipShowing,
            isFirstLaunchAfterUpdate: ReviewPromptSession.isFirstLaunchAfterUpdate,
            appVersion: version,
            lastAskedVersion: record.lastAskedVersion,
            lastAskedDate: record.lastAskedDate,
            now: now)
        // Seen now: the next calm arrival counts it as viewed.
        if screen != .other { viewedResultID = latest?.id }
        guard ReviewPromptPolicy.shouldAsk(input) else { return }
        record.recordAsk(version: version, at: now)
        reviewRequest += 1
    }

    // MARK: - Start and stop

    private var startButton: some View {
        VStack(spacing: 6) {
            Button {
                if engine.isCapturing { engine.stop() }
                else if engine.isPreparing { engine.cancelStart() }
                else { engine.presentPicker() }
            } label: {
                HStack(spacing: 8) {
                    if engine.isStopping { ProgressView().tint(.white) }
                    else { Image(systemName: engine.isCapturing ? "stop.fill" : engine.isPreparing ? "xmark" : "play.fill") }
                    Text(startTitle)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            // At rest the accent, which follows the theme, unless the theme
            // keeps it blue: red here means capturing.
            .tint(engine.isCapturing ? .red : engine.isPreparing ? .gray : theme.idleStartTint)
            .controlSize(.large)
            .disabled(engine.isStopping)
            // Right under Stop: once capture runs, going to the game is the
            // next thing to do.
            if engine.isCapturing { openIngressButton.padding(.top, 2) }
            if engine.isPreparing && !engine.isStopping {
                // The iOS 18-26 sheet says nothing when it is closed, so the
                // player is the one who knows it was.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for screen sharing to start. If you closed the iOS sheet without starting, tap Cancel.",
                         comment: "Under the Cancel button while the app waits for screen sharing.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            if !engine.isCapturing && !engine.isPreparing {
                StartCaption(results: engine.results, assistsGlyphs: engine.assistsGlyphs)
            }
        }
    }

    private var startTitle: LocalizedStringResource {
        if engine.isStopping { return LocalizedStringResource("Stopping…", comment: "Main button while capture stops.") }
        if engine.isPreparing {
            return LocalizedStringResource("Cancel", comment: "Main button while waiting for screen sharing: give up starting.")
        }
        return engine.isCapturing
            ? LocalizedStringResource("Stop", comment: "Main button: stop capturing the screen.")
            : LocalizedStringResource("Start", comment: "Main button: start capturing the screen.")
    }

    // MARK: - Guidance

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works").font(.headline)
            StepRow(number: 1, symbol: "play.circle",
                    text: "Tap Start and share your screen.")
            if engine.assistsGlyphs {
                StepRow(number: 2, symbol: "hexagon",
                        text: "Switch to Ingress and start a Glyph hack.")
                StepRow(number: 3, symbol: "pip",
                        text: "The sequence appears in a floating window, and stays there while you draw.")
            } else {
                StepRow(number: 2, symbol: "hexagon",
                        text: "Switch to Ingress and hack portals as usual.")
                StepRow(number: 3, symbol: "shippingbox",
                        text: "The items each hack drops are read from the game's item panels and counted in Statistics.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Running", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(.green)
            Text(engine.assistsGlyphs
                 ? LocalizedStringResource("Start a Glyph hack in Ingress. Keep the floating window clear of the slot row at the top of the game.")
                 : LocalizedStringResource("Hack portals in Ingress. Keep the floating window clear of the item panels that appear after each hack."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var openIngressButton: some View {
        Button {
            Task { await engine.openIngress() }
        } label: {
            Label("Open Ingress", systemImage: "arrow.up.forward.app")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.large)
    }
}

/// The uptime every half second, for the Home cards whose readings age:
/// only what is inside redraws on each tick, not the tabs around it, and
/// not while the app is in the background, where nothing of it shows. Back
/// in front, the time is read again before the first frame.
private struct HalfSecondClock<Content: View>: View {
    @ViewBuilder let content: (TimeInterval) -> Content
    @State private var now = ProcessInfo.processInfo.systemUptime
    /// Kept in state: a publisher made at each evaluation would never be
    /// the one subscribed to.
    @State private var ticks = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content(now)
            .onReceive(ticks) { _ in
                guard scenePhase != .background else { return }
                now = ProcessInfo.processInfo.systemUptime
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                now = ProcessInfo.processInfo.systemUptime
            }
    }
}

/// Under the Start button: what iOS will ask, and what leaves the phone.
/// Observes results on its own: they publish separately from the engine.
private struct StartCaption: View {
    @ObservedObject var results: HackResults
    let assistsGlyphs: Bool

    var body: some View {
        Group {
            if results.uploadsResults(assistsGlyphs: assistsGlyphs) {
                Label {
                    Text("iOS will ask to share your screen. The screen stays on your phone, but iCloud sync is on: each hack's results are uploaded to your iCloud.",
                         comment: "Under the Start button while saved results sync through iCloud.")
                } icon: {
                    Image(systemName: "icloud")
                }
                .foregroundStyle(.orange)
            } else {
                Text("iOS will ask to share your screen. Everything stays on your phone.",
                     comment: "Under the Start button.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .multilineTextAlignment(.center)
    }
}

private extension View {
    /// Home's tips sit like its cards: same width, corner and fill.
    func homeTipStyle() -> some View {
        tipBackground(Color(.secondarySystemBackground))
            .tipCornerRadius(16)
    }
}
