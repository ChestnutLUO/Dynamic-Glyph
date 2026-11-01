import Combine
import AVFAudio
import Foundation
import CoreMedia
import UIKit
import GlyphRecognition

/// Owns the capture session, the tables and the evidence. Frames come from a
/// `CaptureBackend`, which knows nothing of recognition, recording or the
/// displays.
@MainActor
final class CaptureEngine: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "idle"
    @Published private(set) var imagesSaved = 0
    @Published private(set) var events: [String] = []
    @Published private(set) var evidenceFolder: String?
    @Published private(set) var isPreparing = false
    @Published private(set) var isStopping = false
    @Published private(set) var tableStatus = String(localized: "Not added yet",
                                                     comment: "Shape list status before a file is added.")
    @Published private(set) var sequenceStatus = CaptureEngine.sequenceNotAdded
    private static let sequenceNotAdded = String(localized: "Not added · predictions off",
                                                 comment: "Sequence list status before a file is added.")
    /// No sequence list has been added, or tried: the status is still the
    /// first one. A list that failed to load says why instead.
    var sequenceListNotAdded: Bool { sequenceStatus == Self.sequenceNotAdded }
    /// Why the shape list could not be loaded, if it could not. Kept apart
    /// from `tableStatus` so the home screen never has to parse that text.
    @Published private(set) var tableError: String?
    @Published private(set) var glyphCount = 0
    @Published private(set) var sequenceCount = 0
    /// What went wrong, in words for the player. `status` keeps the technical
    /// detail for the diagnostics page; this is only set when the player has
    /// something to do about it, and cleared when they try again.
    @Published private(set) var problem: String?
    // `recognition`, `recognitionHistory` and `display` change several times
    // a second while capturing, and only the app's own screens show them, so
    // they tell SwiftUI only while the app is on screen. Behind the game the
    // values stay current for the engine's own use, and the screens catch up
    // before the app's first frame back. The floating window and the Live
    // Activity take every snapshot in `apply` directly and are not affected.

    /// Only while session logs are kept; nil otherwise.
    private(set) var recognition: RecognitionDiagnostics? {
        willSet { interfaceWillChange() }
    }
    private(set) var recognitionHistory: [String] = [] {
        willSet { interfaceWillChange() }
    }
    private(set) var display: GlyphDisplaySnapshot {
        willSet { interfaceWillChange() }
    }
    /// Closed while the app is in the background, where no screen of it shows.
    private lazy var interfaceGate = InterfacePublishGate(
        isOpen: UIApplication.shared.applicationState != .background) { [weak self] in
            self?.objectWillChange.send()
        }

    private func interfaceWillChange() {
        interfaceGate.willChange()
    }

    /// Off by default and never persisted. Recording the whole display is an
    /// opt-in for one session at a time: it is read once when the stream
    /// starts, and the toggle is disabled while a session is running, because
    /// turning it on mid-session is a new consent decision rather than a
    /// setting change.
    @Published var debugRecordingEnabled = false
    @Published private(set) var recordingStatus: DebugRecordingStatus?

    /// The Glyph assistance switch in Settings, as the player left it. Read
    /// at each Start; the switch is disabled while a session runs. The first
    /// Glyph list this install loads turns it on (`GlyphAssistance`).
    @Published var glyphAssistancePreferred = AppPreferences().assistsGlyphs {
        didSet { preferences.assistsGlyphs = glyphAssistancePreferred }
    }

    /// A Glyph list is loaded. Without one there is no Glyph assistance
    /// switch to show, and capture reads gear only.
    var hasGlyphList: Bool { shapeTable != nil }

    /// Whether capture follows Glyph hacks: the switch is on and a Glyph list
    /// is loaded. Off reads only the item panels after each hack. Start is
    /// never blocked: without a usable list capture simply reads gear.
    var assistsGlyphs: Bool {
        GlyphAssistance.isInEffect(preferred: glyphAssistancePreferred, hasGlyphList: hasGlyphList)
    }

    /// The language Ingress shows, as chosen; nil reads it automatically.
    /// Read at each Start, like the other reading choices.
    @Published var gameLanguage = AppPreferences().gameLanguage {
        didSet { preferences.gameLanguage = gameLanguage }
    }
    /// The language automatic reading last found, shown in Settings.
    @Published private(set) var detectedGameLanguage = AppPreferences().detectedGameLanguage

    /// Whether sessions leave logs and screenshots in the app's folder. Read
    /// once when a session starts; the switch is disabled while one runs. A
    /// screen recording is stored with those logs, so it goes off with them.
    @Published var sessionDiagnosticsEnabled = AppPreferences().savesSessionDiagnostics {
        didSet {
            preferences.savesSessionDiagnostics = sessionDiagnosticsEnabled
            if !sessionDiagnosticsEnabled { debugRecordingEnabled = false }
        }
    }

    /// The capture's game language: the chosen one, or automatic, starting
    /// from the last one found or the iPhone's language. What automatic
    /// reading finds is kept for Settings and the next capture.
    private func makeLanguageMemory() -> GameLanguageMemory {
        let start = gameLanguage ?? GameLanguageMemory.startingGuess(remembered: detectedGameLanguage,
                                                                     preferredLanguages: Locale.preferredLanguages)
        return GameLanguageMemory(language: start, isAutomatic: gameLanguage == nil) { [weak self] found in
            Task { @MainActor in
                AppPreferences().detectedGameLanguage = found
                self?.detectedGameLanguage = found
            }
        }
    }

    /// A recording the player keeps, saved to Photos when it ends. Separate
    /// from the bug-report recording: no session folder, its own limits. Like
    /// that one it is a consent decision for one session, so it is never
    /// persisted and cannot be switched on while a session runs.
    @Published private(set) var albumRecordingEnabled = false
    @Published private(set) var albumRecordingStatus: DebugRecordingStatus?
    /// Outlives the session that produced it: saving finishes after Stop.
    @Published private(set) var albumRecordingResult: AlbumRecordingResult?
    /// The player declined add-only access to Photos when asked.
    @Published private(set) var albumAccessDenied = false
    /// How the player likes the recording made, so remembered, unlike the
    /// recording itself. The device's sound only, never the microphone.
    @Published var albumRecordingIncludesSound = AppPreferences().recordsSoundInPhotosRecording {
        didSet { preferences.recordsSoundInPhotosRecording = albumRecordingIncludesSound }
    }

    let pip = GlyphPiPController()
    let activity = GlyphActivityController()
    let recordingWarnings = RecordingLimitNotifications(sender: LocalRecordingNotifications())
    private let controlCenter = ControlCenterReporter()

    private let preferences = AppPreferences()

    @Published var pipEnabled = AppPreferences().showsFloatingWindow {
        didSet {
            // Setting a property in its own observer does not observe again.
            if !pipEnabled && floatingWindowRequired { pipEnabled = true }
            preferences.showsFloatingWindow = pipEnabled
            guard isCapturing else { return }
            if pipEnabled { pip.start(table: shapeTable, snapshot: display, collectsStats: evidence != nil) }
            else { pip.stop() }
        }
    }

    /// Off until the player turns it on. The Dynamic Island is a second
    /// display choice, not a requirement, and its update latency has not been
    /// measured on device.
    @Published var liveActivityEnabled = AppPreferences().showsLiveActivity {
        didSet {
            preferences.showsLiveActivity = liveActivityEnabled
            guard isCapturing else { return }
            liveActivityEnabled ? activity.start(with: display, table: shapeTable) : activity.stop()
        }
    }

    /// Off by default. Applies at once: the choice travels with the Island's
    /// content, so changing it sends an update.
    @Published var islandAnimationEnabled = AppPreferences().animatesIslandUpdates {
        didSet {
            preferences.animatesIslandUpdates = islandAnimationEnabled
            activity.animatesUpdates = islandAnimationEnabled
            activity.update(display, table: shapeTable)
        }
    }

    /// Exposed so the in-app tiles can draw diagrams from the same table the
    /// Picture in Picture renderer uses.
    private(set) var shapeTable: GlyphTable?
    private(set) var sequenceTable: SequenceTable?
    /// Observed by the result pages directly; results change far less often
    /// than the display, so they never wait for the interface throttle.
    let results: HackResults = {
        #if targetEnvironment(simulator)
        if ScreenshotDemo.isEnabled { return ScreenshotDemo.makeResults() }
        #endif
        let preferences = AppPreferences()
        let opened = HackResultStore.openPersistent(syncing: preferences.syncsHackResults)
        return HackResults(preferences: preferences, store: opened.store, storageError: opened.error,
                           reopen: HackResultStore.openPersistent(syncing:), widget: .shared)
    }()
    private let backend: CaptureBackend
    private var recognitionOutput: LiveGlyphOutput?
    private let recognitionQueue = DispatchQueue(label: "spikeB.recognition", qos: .userInitiated,
                                                  autoreleaseFrequency: .workItem)
    private var sessionID = UUID()
    /// The identifier the recognition core and the display snapshots carry.
    /// Monotonic so a late callback can never be mistaken for a current one.
    private var captureSessionCounter: UInt64 = 0
    private var captureSessionID = CaptureSessionID(rawValue: 0)
    private var cancellables: Set<AnyCancellable> = []

    private var evidence: EvidenceWriter?
    private var recorder: DebugScreenRecorder?
    private var albumRecorder: DebugScreenRecorder?
    /// Progress from an earlier recording must not overwrite a newer one's.
    private var albumRecordingID = UUID()
    private var startUptime: Double = 0
    /// Five refreshes a second is plenty for a diagnostic panel, and leaves the
    /// processor to recognition.
    private let interfacePublishInterval = 0.2
    private var lastInterfacePublish = -Double.infinity
    private var pendingHistory: [String] = []

    override init() {
        display = .waiting(sessionID: CaptureSessionID(rawValue: 0), liveness: .stopped,
                           acceptance: .provisionalOnly(reason: String(localized: "capture not started",
                                                                         comment: "Reason shown after 'Getting ready ·'.")))
        backend = Self.makeBackend()
        super.init()
        backend.delegate = self
        // A saved "off" from a system where the window was optional.
        if floatingWindowRequired { pipEnabled = true }
        Metrics.observeAppState()
        PowerMeter.shared.observeTextReads()
        pip.onEvent = { [weak self] message in self?.log(message) }
        activity.onEvent = { [weak self] message in self?.log(message) }
        activity.animatesUpdates = islandAnimationEnabled
        recordingWarnings.onEvent = { [weak self] message in self?.log(message) }
        controlCenter.start { [weak self] in
            Task { @MainActor in self?.stopFromControlCenter() }
        }
        // An activity surviving a crash would imply capture is still running.
        activity.reconcileLeftovers()
        // SwiftUI only watches the object it is given. The two display
        // controllers are separate observable objects, so their changes are
        // forwarded here or the Picture in Picture and Live Activity panels
        // would never refresh.
        // The floating window's statistics refresh twice a second, so these
        // too wait while the app is in the background.
        for child in [pip.objectWillChange.eraseToAnyPublisher(),
                      activity.objectWillChange.eraseToAnyPublisher(),
                      recordingWarnings.objectWillChange.eraseToAnyPublisher()] {
            child.sink { [weak self] _ in self?.interfaceWillChange() }.store(in: &cancellables)
        }
        // Posted on the main thread; the gate opens before the app's first
        // frame on return, so every screen draws the current values.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.interfaceGate.close() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.interfaceGate.open() }
            .store(in: &cancellables)
        // Evidence for when the sharing sheet leaves the app: the iOS 18-26
        // sheet reports nothing when it is dismissed.
        for (name, label) in [(UIApplication.willResignActiveNotification, "inactive"),
                              (UIApplication.didBecomeActiveNotification, "active")] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self, self.isPreparing else { return }
                    self.log("app \(label) while waiting for screen sharing")
                }
                .store(in: &cancellables)
        }
        // The Summary widget: reloads spaced out while capturing, and one
        // held back sent at Stop and when the app comes to the foreground.
        $isCapturing.removeDuplicates()
            .sink { SummaryWidgetPublisher.shared.isCapturing = $0 }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { _ in SummaryWidgetPublisher.shared.reloadIfPending() }
            .store(in: &cancellables)
        // The session log notes each change of what slows recognition while
        // capturing; these are posted on any thread.
        Publishers.Merge(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange),
                         NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.recognitionOutput != nil else { return }
                self.logSlowdown()
            }
            .store(in: &cancellables)
        loadStoredTables()
    }

    private static func makeBackend() -> CaptureBackend {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27, *) { return ScreenCaptureBackend() }
        #endif
        return ReplayKitBackend()
    }

    /// On iOS 18-26 the app keeps running over Ingress only while the
    /// floating window is open, so it cannot be turned off there.
    var floatingWindowRequired: Bool {
        #if targetEnvironment(simulator)
        // Screenshots show iOS 27's capture, not the simulator's ReplayKit fallback.
        if ScreenshotDemo.isEnabled { return false }
        #endif
        return backend.requiresFloatingWindow
    }

    // MARK: - Tables

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var tableURL: URL { documents.appendingPathComponent("glyph_line.csv") }
    private var sequenceURL: URL { documents.appendingPathComponent("glyph.csv") }

    /// Both tables are picked up from the Documents folder at launch, so a
    /// device test does not start with a file import.
    private func loadStoredTables() {
        // Before the list is read: an install that already had one keeps its
        // switch as it was, rather than having it turned on as a first import.
        var optIn = preferences.glyphAssistance
        optIn.migrate(listFileExists: FileManager.default.fileExists(atPath: tableURL.path))
        preferences.glyphAssistance = optIn
        #if targetEnvironment(simulator)
        // Screenshot demo: the app's own demo shapes, never the files in Documents.
        if ScreenshotDemo.isEnabled {
            shapeTable = ScreenshotDemo.shapeTable
            glyphCount = ScreenshotDemo.shapeTable.count
            tableStatus = "\(glyphCount) demo Glyphs (screenshot demo)"
            return
        }
        #endif
        if FileManager.default.fileExists(atPath: tableURL.path) {
            do { try loadTable(from: tableURL) }
            catch {
                tableError = String(localized: "The saved Glyph list couldn't be read: \(error.localizedDescription)",
                                    comment: "The placeholder is the system's error message.")
                tableStatus = tableError ?? ""
            }
        }
        if FileManager.default.fileExists(atPath: sequenceURL.path) {
            do { try loadSequenceTable(from: sequenceURL) }
            catch {
                sequenceStatus = String(localized: "The saved sequence list couldn't be read: \(error.localizedDescription)",
                                        comment: "The placeholder is the system's error message.")
            }
        }
    }

    private func loadTable(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let csv = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let table = try GlyphTable.parse(csv: csv)
        if url != tableURL { try data.write(to: tableURL, options: .atomic) }
        shapeTable = table
        noteGlyphListLoaded()
        glyphCount = table.count
        tableError = nil
        tableStatus = String(localized: "\(table.count) Glyphs loaded",
                             comment: "Shape list status. The number is how many Glyphs the list defines.")
        // A sequence table already loaded against the old shapes needs checking
        // again, because the names it refers to may no longer all exist.
        if let sequenceTable { describe(sequenceTable) }
    }

    /// The first Glyph list this install loads, imported or found in the
    /// app's folder, turns Glyph assistance on. Later ones leave the switch be.
    private func noteGlyphListLoaded() {
        var optIn = preferences.glyphAssistance
        optIn.listLoaded()
        preferences.glyphAssistance = optIn
        if glyphAssistancePreferred != optIn.preferred { glyphAssistancePreferred = optIn.preferred }
    }

    /// The sequence table is optional. Recognition and the display work without
    /// it; only prediction is lost, and the display says so rather than
    /// failing to start.
    private func loadSequenceTable(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let csv = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let table = try SequenceTable.parse(csv: csv)
        if url != sequenceURL { try data.write(to: sequenceURL, options: .atomic) }
        sequenceTable = table
        sequenceCount = table.count
        describe(table)
    }

    /// Cross-checks the two tables. A sequence naming a Glyph the shape table
    /// does not have cannot ever be drawn, and silently predicting it would be
    /// worse than saying the tables disagree.
    ///
    /// Each finding is a whole phrase of its own, joined only by the separator,
    /// so no translation has to be assembled from fragments.
    private func describe(_ table: SequenceTable) {
        var findings = [String(localized: "\(table.count) sequences",
                               comment: "Sequence list status: how many distinct sequences it holds.")]
        if table.rowCount != table.count {
            findings.append(String(localized: "\(table.rowCount) rows, duplicates merged",
                                   comment: "Sequence list status: the file had repeated rows."))
        }
        if let shapeTable {
            let known = Set(shapeTable.glyphs)
            let unknown = Set(table.sequences.flatMap { $0 }).subtracting(known).sorted()
            if !unknown.isEmpty {
                // Glyph names are the game's own and stay untranslated.
                let examples = unknown.prefix(3).map(\.name).joined(separator: ", ")
                    + (unknown.count > 3 ? "…" : "")
                findings.append(String(localized: "\(unknown.count) names missing from the Glyph list: \(examples)",
                                       comment: "Sequence list status. The number counts Glyph names the shape list lacks; then up to three of them."))
            }
        } else {
            findings.append(String(localized: "Glyph list not loaded, names unchecked",
                                   comment: "Sequence list status when there is no shape list to check it against."))
        }
        sequenceStatus = findings.joined(separator: " · ")
    }

    func importTable(_ result: Result<[URL], Error>) {
        importFile(result) { try self.loadTable(from: $0) } onError: {
            self.tableError = $0
            self.tableStatus = $0
        }
    }

    func importSequenceTable(_ result: Result<[URL], Error>) {
        importFile(result) { try self.loadSequenceTable(from: $0) } onError: { self.sequenceStatus = $0 }
    }

    private func importFile(_ result: Result<[URL], Error>, load: (URL) throws -> Void,
                            onError: (String) -> Void) {
        guard !isCapturing, !isPreparing, !isStopping else { return }
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try load(url)
        } catch {
            onError(String(localized: "Import failed: \(error.localizedDescription)",
                           comment: "The placeholder is the system's error message."))
        }
    }

    // MARK: - Picker

    func presentPicker() {
        guard !isCapturing, !isPreparing, !isStopping else { return }
        problem = nil
        guard backend.isAvailable else {
            status = "content sharing picker reports isAvailable == false"
            problem = String(localized: "Screen sharing isn't available right now. Try again in a moment.",
                             comment: "Shown when iOS will not offer screen sharing.")
            log("picker unavailable")
            return
        }
        // The previous session's writer is closed; it must not receive this
        // session's notes whether or not a new one is opened.
        evidence = nil
        if sessionDiagnosticsEnabled {
            do {
                let writer = try EvidenceWriter()
                // Preserve the exact runtime inputs alongside recognition evidence.
                if assistsGlyphs {
                    try Data(contentsOf: tableURL).write(to: writer.directory.appendingPathComponent("glyph_line.csv"))
                }
                if assistsGlyphs, FileManager.default.fileExists(atPath: sequenceURL.path) {
                    try Data(contentsOf: sequenceURL).write(to: writer.directory.appendingPathComponent("glyph.csv"))
                }
                evidence = writer
            } catch {
                status = "could not open evidence folder: \(error.localizedDescription)"
                problem = String(localized: "Couldn't prepare storage for this session: \(error.localizedDescription)",
                                 comment: "The placeholder is the system's error message.")
                return
            }
        }
        evidenceFolder = evidence?.directory.lastPathComponent
        sessionID = UUID()
        captureSessionCounter += 1
        captureSessionID = CaptureSessionID(rawValue: captureSessionCounter)
        imagesSaved = 0
        pendingHistory = []
        lastInterfacePublish = -.infinity
        events = []; recognition = nil; recognitionHistory = []
        recordingStatus = nil
        display = .waiting(sessionID: captureSessionID, liveness: .starting,
                           acceptance: .provisionalOnly(reason: String(localized: "waiting for the first frame",
                                                                         comment: "Reason shown after 'Getting ready ·'.")))
        isPreparing = true
        startUptime = ProcessInfo.processInfo.systemUptime

        // Establish a mixing policy before the capture service starts, because
        // a fresh session defaults to `soloAmbient`, which silences other audio
        // the moment anything activates it.
        //
        // `.ambient` rather than `.playback`: this app plays no audio at all,
        // and ambient never interrupts another app by construction. Picture in
        // Picture is the only thing here that needs `.playback`, and it asks
        // for it when the window opens. Claiming a playback category for a
        // session that will never play anything put this app in the frame for
        // silencing whatever the player was listening to.
        logAudioState("before picker configuration")
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
        } catch { log("capture audio policy failed: \(error)") }
        logAudioState("before picker")
        backend.requestConsent()
    }

    /// The player gave up waiting for screen sharing. The iOS 18-26 sheet
    /// says nothing when it is dismissed, and otherwise the app would wait
    /// out its timeout. A broadcast that begins after this is ended.
    func cancelStart() {
        guard isPreparing, !isStopping else { return }
        log("start cancelled by the player")
        status = "start cancelled"
        finishFailedStart()
    }

    func stop() {
        guard !isStopping, isCapturing || backend.hasSession else { return }
        recordingWarnings.endAll()
        let stoppingRecorder = recorder
        let stoppingAlbumRecorder = albumRecorder
        let output = recognitionOutput
        recognitionOutput = nil
        sessionID = UUID()
        isCapturing = false
        isPreparing = false
        isStopping = true
        PowerMeter.shared.end()
        pip.stop()
        activity.stop()
        // The recorder is finalized by LiveGlyphOutput.close(), which the stop
        // sequence below already awaits; dropping the reference here would
        // otherwise leave nothing to answer Stop recording with.
        display = .waiting(sessionID: captureSessionID, liveness: .stopped,
                           acceptance: .provisionalOnly(reason: String(localized: "capture stopped",
                                                                         comment: "Reason shown after 'Getting ready ·'.")))
        let backendStopped = backend.stop()
        Task {
            await backendStopped.value
            // Capture is over; what follows only finishes files.
            controlCenter.captureEnded()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                recognitionQueue.async {
                    if let output {
                        output.close()
                    } else {
                        for recorder in [stoppingRecorder, stoppingAlbumRecorder].compactMap({ $0 }) {
                            recorder.requestFinish(.sessionStopped)
                            recorder.waitForFinish()
                        }
                    }
                    continuation.resume()
                }
            }
            await MainActor.run {
                self.log("stopped after \(self.recognition.map { "\($0.counters.frames) frames, " } ?? "")"
                         + "\(self.imagesSaved) images")
                self.status = self.evidenceFolder.map { "stopped -- evidence in \($0)" }
                    ?? "stopped -- session logs off"
                // The old session callback is deliberately rejected after
                // sessionID changes. Publish its final status explicitly here.
                if let stoppingRecorder { self.recordingStatus = stoppingRecorder.snapshotStatus() }
                if let stoppingAlbumRecorder { self.albumRecordingStatus = stoppingAlbumRecorder.snapshotStatus() }
                self.evidence?.close()
                self.recorder = nil
                self.albumRecorder = nil
                self.isStopping = false
            }
        }
    }

    private func apply(_ update: LiveGlyphUpdate) {
        let meter = PowerMeter.shared
        let started = meter.now()
        defer { meter.finish(.displayUpdate, since: started) }
        // The display surfaces are not SwiftUI and take every snapshot.
        pip.update(update.snapshot)
        let activityStarted = meter.now()
        activity.update(update.snapshot, table: shapeTable)
        meter.finish(.liveActivity, since: activityStarted)

        if let diagnostics = update.diagnostics, diagnostics.changed {
            let match = diagnostics.state == "uniqueVisibleShape"
                ? diagnostics.names.joined(separator: ", ") : diagnostics.state
            pendingHistory.insert(String(format: "#%d · %.2fs  %@  [%@]",
                                         diagnostics.samples, diagnostics.elapsed, match, diagnostics.phase), at: 0)
            if pendingHistory.count > 80 { pendingHistory.removeLast() }
        }

        // Publishing rebuilds the whole view. At 20 Hz that competed with the
        // recognition queue for the processor, and the first field run lost
        // 30.7 seconds of capture to gaps -- every one of them while the app
        // was frontmost, none after it was backgrounded. Nothing on screen
        // needs five updates a second.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInterfacePublish >= interfacePublishInterval else { return }
        lastInterfacePublish = now
        if let diagnostics = update.diagnostics { recognition = diagnostics }
        display = update.snapshot
        if !pendingHistory.isEmpty {
            recognitionHistory = Array((pendingHistory + recognitionHistory).prefix(80))
            pendingHistory = []
        }
    }

    /// The Control Center switch was turned off while the app was capturing
    /// and listening: the same stop as Home's.
    func stopFromControlCenter() {
        guard isCapturing, !isStopping else { return }
        log("stop asked from Control Center")
        stop()
    }

    private func finishFailedStart() {
        guard !isStopping else { return }
        controlCenter.captureEnded()
        recordingWarnings.endAll()
        isStopping = true
        PowerMeter.shared.end()
        let output = recognitionOutput
        let stoppingRecorder = recorder
        let stoppingAlbumRecorder = albumRecorder
        sessionID = UUID()
        isPreparing = false
        isCapturing = false
        pip.stop()
        activity.stop()
        backend.reset()
        recognitionOutput = nil
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                recognitionQueue.async {
                    if let output {
                        output.close()
                    } else {
                        // The recorders may exist even if output setup failed.
                        for recorder in [stoppingRecorder, stoppingAlbumRecorder].compactMap({ $0 }) {
                            recorder.requestFinish(.sessionStopped)
                            recorder.waitForFinish()
                        }
                    }
                    continuation.resume()
                }
            }
            if let stoppingRecorder { recordingStatus = stoppingRecorder.snapshotStatus() }
            if let stoppingAlbumRecorder { albumRecordingStatus = stoppingAlbumRecorder.snapshotStatus() }
            recorder = nil
            albumRecorder = nil
            evidence?.close()
            isStopping = false
        }
    }

    /// Switches to the game. If the floating window would not open by itself
    /// on leaving, it is opened first and given a moment to appear, so the
    /// sequence is already on screen when Ingress comes up.
    func openIngress() async {
        if isCapturing, pipEnabled, pip.isRunning, !pip.isActive, !pip.isAutomaticFromInline {
            pip.openWindow()
            // `openWindow` gives up by itself after three seconds.
            for _ in 0..<35 where pip.isOpening && !pip.isActive {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let launcher = IngressLauncher { url, universalLinksOnly in
            await UIApplication.shared.open(url, options: universalLinksOnly ? [.universalLinksOnly: true] : [:])
        }
        let outcome = await launcher.launch()
        log("open Ingress: \(outcome)")
        if outcome == .failed {
            problem = String(localized: "Couldn't open Ingress or the App Store.",
                             comment: "Shown when neither the game nor its App Store page would open.")
        }
    }

    /// Turning it on asks for add-only access to Photos first, so the prompt
    /// comes here in Settings rather than when a recording ends mid-game.
    func setAlbumRecording(_ enabled: Bool) async {
        guard !isCapturing, !isPreparing, !isStopping else { return }
        guard enabled else {
            albumRecordingEnabled = false
            return
        }
        let allowed = await PhotoLibrarySaver.requestAccess()
        albumAccessDenied = !allowed
        albumRecordingEnabled = allowed
        if allowed { await recordingWarnings.requestAuthorization() }
    }

    func setDebugRecording(_ enabled: Bool) {
        guard !isCapturing, !isPreparing, !isStopping else { return }
        debugRecordingEnabled = enabled && sessionDiagnosticsEnabled
        if debugRecordingEnabled {
            Task { await recordingWarnings.requestAuthorization() }
        }
    }

    /// Ends the Photos recording now and saves it; capture keeps running.
    func stopAlbumRecording() {
        guard let albumRecorder else { return }
        recordingWarnings.end(.photos)
        log("album recording stopped by the user")
        albumRecorder.requestFinish(.userStopped)
    }

    /// A recorder that could not start never stops the session, as with the
    /// bug-report recording: it is logged and reported, and capture proceeds.
    private func startAlbumRecording() -> DebugScreenRecorder? {
        let recordingID = UUID()
        albumRecordingID = recordingID
        albumRecordingStatus = nil
        albumRecordingResult = nil
        recordingWarnings.begin(.photos, id: recordingID, limits: .album)
        do {
            let started = try AlbumRecording.start(
                recordsAudio: albumRecordingIncludesSound,
                fallbackDirectory: documents,
                save: { try await PhotoLibrarySaver.saveVideo(at: $0) },
                onStatus: { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.albumRecordingID == recordingID else { return }
                        self.albumRecordingStatus = status
                        self.recordingWarnings.update(.photos, id: recordingID, status: status)
                    }
                },
                onFinish: { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        self.log("album recording: \(result)")
                        if self.albumRecordingID == recordingID { self.albumRecordingResult = result }
                    }
                })
            log("album recording started")
            return started
        } catch {
            recordingWarnings.end(.photos)
            log("album recording unavailable: \(error)")
            albumRecordingResult = .failed(String(describing: error))
            return nil
        }
    }

    /// Finalizes the video while capture keeps running, so a tester who sees
    /// the problem three minutes in can attach a short file and keep playing.
    func stopRecording() {
        guard let recorder else { return }
        recordingWarnings.end(.bugReport)
        log("screen recording stopped by the user")
        recorder.requestFinish(.userStopped)
    }

    /// The last "slowed:" line of this capture, so only changes are logged.
    private var loggedSlowdown: String?

    /// Logs what slows recognition (Low Power Mode, heat) when it changes.
    private func logSlowdown() {
        PowerConditions.shared.refresh()
        let slowdown = PowerConditions.shared.current.slowdown
        guard slowdown != loggedSlowdown else { return }
        loggedSlowdown = slowdown
        log("slowed: \(slowdown)")
    }

    fileprivate func log(_ message: String) {
        let stamp = String(format: "%7.1fs", ProcessInfo.processInfo.systemUptime - startUptime)
        events.insert("\(stamp)  \(message)", at: 0)
        if events.count > 40 { events.removeLast() }
        evidence?.note(message)
    }

    private func logAudioState(_ stage: String) {
        let audio = AVAudioSession.sharedInstance()
        log("audio [\(stage)] category=\(audio.category.rawValue) mode=\(audio.mode.rawValue)"
            + " mixing=\(audio.categoryOptions.contains(.mixWithOthers))"
            + " otherAudioPlaying=\(audio.isOtherAudioPlaying)"
            + " pipEnabled=\(pipEnabled) pipOwnsAudio=\(pip.ownsAudioSession)")
    }

    /// The session log's row for one frame. Only called while logs are kept.
    private func record(_ frame: FrameTelemetry) {
        let meter = PowerMeter.shared
        let started = meter.now()
        defer { meter.finish(.telemetryRow, since: started) }
        let now = ProcessInfo.processInfo.systemUptime
        let facts = frame.facts
        let index = frame.index

        // The five-second cadence is decided on the recognition queue; a
        // buffer arriving here at all means an image was asked for.
        if let sampleBuffer = frame.buffer, evidence?.saveImage(sampleBuffer, index: index) == true {
            imagesSaved += 1
        }

        let rect = facts.contentRect.map { String(format: "%.0fx%.0f", $0.width, $0.height) } ?? "-"
        evidence?.appendRow([
            ISO8601DateFormatter().string(from: Date()),
            String(format: "%.3f", now),
            String(format: "%.3f", now - startUptime),
            String(index), facts.status.rawValue,
            String(facts.width), String(facts.height), facts.pixelFormat,
            facts.scaleFactor.map { String(format: "%.2f", $0) } ?? "-",
            facts.contentScale.map { String(format: "%.2f", $0) } ?? "-",
            rect,
            facts.orientation.map(String.init) ?? "-",
            String(facts.hash), frame.hashChanged ? "1" : "0",
            Metrics.appStateDescription,
            Metrics.describe(ProcessInfo.processInfo.thermalState),
            String(format: "%.1f", Metrics.physFootprintMB()),
            String(format: "%.3f", Metrics.cpuSeconds()),
            pip.isActive ? "1" : "0"
        ])
    }
}

// MARK: - Capture backend

extension CaptureEngine: CaptureBackendDelegate {
    func captureBackendWillStart() -> CaptureSinks? {
        // Nil reads gear only.
        let table = assistsGlyphs ? shapeTable : nil
        guard table != nil || !assistsGlyphs else {
            log("Ignoring filter update while a stream is already active")
            return nil
        }
        let runID = sessionID
        // Created before the backend configures capture, so sound is captured
        // only when a recording that wants it actually started.
        albumRecorder = albumRecordingEnabled ? startAlbumRecording() : nil

        // A failed recorder must never stop a capture session: it is logged,
        // surfaced, and the session proceeds without a video.
        var sessionRecorder: DebugScreenRecorder?
        if debugRecordingEnabled, let evidence {
            recordingWarnings.begin(.bugReport, id: runID, limits: .standard)
            do {
                sessionRecorder = try DebugScreenRecorder(directory: evidence.directory) { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.sessionID == runID else { return }
                        self.recordingStatus = status
                        self.recordingWarnings.update(.bugReport, id: runID, status: status)
                        if let message = status.message { self.log(message) }
                    }
                }
                log("screen recording started -> \(sessionRecorder?.movieURL.lastPathComponent ?? "-")")
            } catch {
                recordingWarnings.end(.bugReport)
                log("screen recording unavailable: \(error)")
                recordingStatus = DebugRecordingStatus(isRecording: false,
                                                       message: "unavailable: \(error)")
            }
        }
        recorder = sessionRecorder

        let languages = makeLanguageMemory()
        PowerMeter.shared.reset(languages: languages)
        // Stamped on each record as it is delivered, with the language read
        // by then and the iPhone's UTC offset at that moment.
        let mode: CaptureOrigin.Mode = table == nil ? .gearOnly : .glyphAssistance
        let origin: @Sendable () -> CaptureOrigin = { CaptureOrigin.current(mode: mode, languages: languages) }
        do {
            let output = try LiveGlyphOutput(
                table: table, sequenceTable: sequenceTable, sessionID: captureSessionID,
                directory: evidence?.directory,
                recorders: [sessionRecorder, albumRecorder].compactMap { $0 },
                readsResults: results.readsResults,
                // Pictures of the panels go into the session folder, so they
                // are kept only while logs are.
                readsGear: results.readsGear, savesGearPictures: results.savesGearPictures,
                languages: languages,
                // Read once per session: switching it mid-capture changes nothing.
                // Always on where the switch isn't shown (App Store builds).
                powerSaving: AppPreferences.effectivePowerSaving(stored: preferences.powerSaving,
                                                                 toolsAvailable: BenchmarkAvailability.isAvailable),
                // The floating window's debug fill, when Diagnostics asks for it.
                readingMode: .shared,
                telemetry: { [weak self] frame in
                    Task { @MainActor in
                        guard let self, self.sessionID == runID else { return }
                        self.record(frame)
                    }
                },
                // Not gated on the run: the result closed by Stop arrives
                // after the run has ended, and carries its own hack identity.
                deliverResult: { [results] summary in
                    var summary = summary
                    summary.origin = origin()
                    Task { @MainActor in results.receive(summary) }
                },
                // Like results: gear arrives after the hack, sometimes after Stop.
                deliverGear: { [results] attachment in
                    var attachment = attachment
                    attachment.origin = origin()
                    Task { @MainActor in results.receiveGear(attachment) }
                },
                deliverDrop: { [results] drop in
                    var drop = drop
                    drop.origin = origin()
                    Task { @MainActor in results.receiveDrop(drop) }
                }) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.sessionID == runID else { return }
                        self.apply(update)
                    }
                }
            recognitionOutput = output
            log("power saving \(output.powerSaving ? "on" : "off")")
            loggedSlowdown = nil
            logSlowdown()
            logAudioState("before startCapture")
            return CaptureSinks(recognition: output, recognitionQueue: recognitionQueue,
                                soundRecorder: albumRecorder?.recordsAudio == true ? albumRecorder : nil)
        } catch {
            status = "addStreamOutput failed: \(error.localizedDescription)"
            problem = String(localized: "Couldn't start watching the screen. Please try again.",
                             comment: "Shown when screen capture fails to start.")
            log("addStreamOutput FAILED \(error)")
            finishFailedStart()
            return nil
        }
    }

    func captureBackendDidStart() {
        logAudioState("after startCapture")
        isPreparing = false
        isCapturing = true
        status = "capturing -- open Picture in Picture, then launch Ingress"
        log("startCapture ok")
        // A broadcast reports itself through the ring, even with the app suspended.
        controlCenter.captureStarted(reportsHeartbeat: !backend.requiresFloatingWindow)
        // Rendering only starts once capture is running, so the consent sheet
        // and the Picture in Picture window are never competing for the
        // screen at the same moment.
        if pipEnabled {
            pip.start(table: shapeTable, snapshot: display, collectsStats: evidence != nil)
        }
        if liveActivityEnabled {
            activity.start(with: display, table: shapeTable)
        }
    }

    func captureBackend(didFail failure: CaptureBackendFailure) {
        let endsSession = failure.endsSession(whileCapturing: isCapturing)
        if failure.endsRunningCapture { isCapturing = false }
        // A stop from the Control Center switch is asked for, like Home's Stop: no message.
        if let message = failure.problem { problem = message }
        if failure == .stoppedFromControlCenter { log("stopped from Control Center") }
        if endsSession { finishFailedStart() }
    }

    func captureBackendNote(_ message: String, status: String?) {
        if let status { self.status = status }
        log(message)
    }
}
