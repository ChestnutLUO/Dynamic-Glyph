import SwiftUI
import GlyphRecognition

/// Everything the home screen leaves out: the data files, fine-tuning the
/// floating window, bug-report recording, and the diagnostics a tester reads.
struct SettingsView: View {
    @ObservedObject var engine: CaptureEngine
    var onRunSetup: () -> Void = {}
    var onImportTable: () -> Void
    var onImportSequences: () -> Void

    private var isBusy: Bool { engine.isCapturing || engine.isPreparing || engine.isStopping }
    /// `AppPreferences.playerFaction`'s key: empty until the player sets it.
    @AppStorage("game.playerFaction") private var playerFactionCode = ""

    var body: some View {
        NavigationStack {
            Form {
                // Only once a Glyph list is loaded: before that there is no
                // Glyph assistance to switch, and nothing here promotes it.
                if GlyphAssistance.showsSwitch(hasGlyphList: engine.hasGlyphList) { reading }
                gameLanguage
                playerFaction
                floatingWindow
                dynamicIsland
                albumRecording
                bugReports
                support
                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView(engine: engine) }
                } footer: {
                    Text("Technical readouts for testing and bug reports.")
                }
                Section {
                    Button("Run setup again") {
                        AppPreferences().completedSetupVersion = 0
                        onRunSetup()
                    }
                    .disabled(isBusy)
                } footer: {
                    Text("Walks through the Dynamic Island and the floating window again.",
                         comment: "Settings footer under Run setup again.")
                }
                Section {
                    LabeledContent("Version", value: SupportContact.appVersion)
                }
                // Last, and quiet: where a Glyph list is added. Glyph
                // assistance appears at the top once one is loaded.
                glyphData
                #if targetEnvironment(simulator)
                ScreenshotDemoSection()
                #endif
                #if DEBUG || targetEnvironment(simulator)
                AppIntentsDebugSection()
                #endif
            }
            // Above the list rather than in it: a list drops rows scrolled
            // out of view, and the layer with them.
            .safeAreaInset(edge: .top, spacing: 0) {
                // Hide the padding and background along with the preview;
                // an empty preview otherwise leaves an opaque top inset.
                if engine.isCapturing && engine.pipEnabled {
                    FloatingWindowPreview(engine: engine)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .background(Color(.systemGroupedBackground), ignoresSafeAreaEdges: [])
                }
            }
            // A form's automatic edge effect is the hard one: with no preview
            // over it, rows scrolled under the title showed as a frosted
            // rectangle behind the Dynamic Island. Fade them, as Home does.
            .softTopScrollEdge()
            .navigationTitle("Settings")
        }
    }

    // MARK: - What capture reads

    private var reading: some View {
        Section {
            Toggle("Glyph assistance", isOn: $engine.glyphAssistancePreferred).disabled(isBusy)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.glyphAssistancePreferred
                     ? LocalizedStringResource("Follows each Glyph hack and shows its sequence while you draw, using your Glyph list.",
                                               comment: "Settings footer: Glyph assistance on. Shown only once a Glyph list is loaded.")
                     : LocalizedStringResource("Off: only the item panels after each hack are read and counted. Your Glyph list stays saved.",
                                               comment: "Settings footer: Glyph assistance off. Shown only once a Glyph list is loaded."))
                if isBusy { Text("Changes to reading apply the next time you tap Start.") }
            }
        }
    }

    // MARK: - Game language

    /// Ingress has its own language setting, apart from the iPhone's; the
    /// game's text can only be read in its own script.
    private var gameLanguage: some View {
        Section {
            Picker("Game language", selection: $engine.gameLanguage) {
                Text("Automatic").tag(GameLanguage?.none)
                ForEach(GameLanguage.allCases, id: \.self) { language in
                    // Each language in its own name, as a language menu shows it.
                    Text(verbatim: language.nativeName).tag(GameLanguage?.some(language))
                }
            }
            .disabled(isBusy)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if engine.gameLanguage == nil {
                    if let detected = engine.detectedGameLanguage {
                        Text("Found from the game's screens: \(detected.nativeName).",
                             comment: "Settings, game language. The placeholder is a language's own name, such as 日本語.")
                    } else {
                        Text("Found from the game's screens during your first hack.")
                    }
                }
                Text("Choose the language Ingress shows, if it isn't found. 繁體中文 and 한국어 come from translated text and haven't been checked in the game yet.")
            }
        }
    }

    /// The player's own faction, so a hacked portal can be told as theirs,
    /// the other side's or Machina's. Read as each record is made.
    private var playerFaction: some View {
        Section {
            Picker("Your faction", selection: $playerFactionCode) {
                Text("Not set").tag("")
                // Game terms, as the English game names them.
                Text(verbatim: "Resistance").tag(PortalFaction.resistance.rawValue)
                Text(verbatim: "Enlightened").tag(PortalFaction.enlightened.rawValue)
            }
        } footer: {
            Text("Saved with each hack from now on, so exports can tell your faction's portals from the other side's and Machina's. Hacks already saved keep what they had.")
        }
    }

    // MARK: - Glyph data

    private var glyphData: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glyph list")
                Text(engine.tableStatus).font(.caption).foregroundStyle(.secondary)
            }
            Button(engine.glyphCount == 0
                   ? LocalizedStringResource("Add Glyph list…")
                   : LocalizedStringResource("Replace Glyph list…")) {
                onImportTable()
            }
            .disabled(isBusy)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sequence list · optional")
                Group {
                    // Predictions need a Glyph list, so until there is one the
                    // row says only that nothing is added, as the Glyph list's does.
                    if engine.sequenceListNotAdded && !engine.hasGlyphList {
                        Text("Not added yet", comment: "Shape list status before a file is added.")
                    } else {
                        Text(engine.sequenceStatus)
                    }
                    // Only once a Glyph list is loaded: before that it would
                    // be the one line here advertising Glyph assistance.
                    if engine.sequenceCount == 0 && engine.hasGlyphList {
                        Text("Add one to see predicted Glyphs before they appear.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Button(engine.sequenceCount == 0
                   ? LocalizedStringResource("Add sequence list…")
                   : LocalizedStringResource("Replace sequence list…")) {
                onImportSequences()
            }
            .disabled(isBusy)
        } header: {
            Text("Glyph data")
        } footer: {
            Text(isBusy
                 ? LocalizedStringResource("Stop watching to change these files.")
                 : LocalizedStringResource("The Glyph list is glyph_line.csv and the sequence list is glyph.csv. You can also drop them into this app's folder in the Files app.",
                                           comment: "Settings footer. Keep the two file names exactly as written."))
        }
    }

    // MARK: - Floating window

    private var floatingWindow: some View {
        Section {
            PiPCanvasControls(pip: engine.pip)
            Toggle("Hide playback controls", isOn: Binding(
                get: { engine.pip.hidesPlaybackControls },
                set: { engine.pip.setHidesPlaybackControls($0) }))
            Toggle("Hide from screenshots", isOn: Binding(
                get: { engine.pip.preventsCapture },
                set: { engine.pip.setPreventsCapture($0) }))
        } header: {
            Text("Floating window")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let note = engine.pip.playbackControlsNote { Text(note) }
                if engine.pip.preventsCapture {
                    Text("Screenshots and screen recordings show the window as black, including this app's own screen recording.")
                }
                Text("Pinch the window to resize it, drag to move it, or tuck it against the side of the screen to reach what's underneath.")
            }
        }
    }

    // MARK: - Dynamic Island

    private var dynamicIsland: some View {
        Section {
            Toggle("Animate changes", isOn: $engine.islandAnimationEnabled)
        } header: {
            Text("Dynamic Island")
        } footer: {
            Text("Off, the Island switches to the next Glyph instantly. On, iOS slides and fades each update, which can look like the Island is shaking.")
        }
    }

    // MARK: - Recording to Photos

    private var albumRecording: some View {
        Section {
            Toggle("Save a recording to Photos", isOn: Binding(
                get: { engine.albumRecordingEnabled },
                set: { enabled in Task { await engine.setAlbumRecording(enabled) } }))
                .disabled(isBusy)
            if engine.albumRecordingEnabled {
                Toggle("Include sound", isOn: $engine.albumRecordingIncludesSound)
                    .disabled(isBusy)
            }
            if let status = engine.albumRecordingStatus, status.isRecording {
                Text(recordingLine(status))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Stop and save to Photos") { engine.stopAlbumRecording() }
            }
            if let warning = engine.recordingWarnings.messages[.photos] {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if let result = engine.albumRecordingResult {
                Text(albumResultLine(result))
                    .font(.caption)
                    .foregroundStyle(result == .saved ? Color.secondary : Color.orange)
            }
        } header: {
            Text("Recording")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if engine.albumAccessDenied {
                    Text("Allow Dynamic Glyph to add to Photos in the Settings app to use this.")
                        .foregroundStyle(.orange)
                }
                Text("Records the whole screen during the next session, including notifications, and saves the video to Photos when you stop. It stops by itself after 30 minutes or 1 GB. Separate from the bug report recording.")
                if engine.albumRecordingEnabled {
                    Text("Sound is what the phone plays, such as the game's. The microphone is never recorded.")
                    recordingWarningExplanation
                }
            }
        }
    }

    private func albumResultLine(_ result: AlbumRecordingResult) -> String {
        switch result {
        case .saved:
            return String(localized: "Saved to Photos.", comment: "After a recording was added to Photos.")
        case .keptInFiles(let name, let reason):
            return String(localized: "Couldn't save to Photos (\(reason)). The video is in this app's folder in the Files app as \(name).",
                          comment: "First placeholder: the system's reason. Second: the video's file name.")
        case .nothingRecorded:
            return String(localized: "Nothing was recorded.", comment: "A recording ended before any frame was written.")
        case .failed(let reason):
            return String(localized: "The recording couldn't be saved: \(reason)",
                          comment: "The placeholder is a technical reason.")
        }
    }

    // MARK: - Bug reports

    private var bugReports: some View {
        Section {
            NavigationLink("Session logs and reports") {
                SessionReportsView(activeFolder: engine.isCapturing || engine.isStopping
                                   ? engine.evidenceFolder : nil)
            }
            Toggle("Save logs and screenshots", isOn: $engine.sessionDiagnosticsEnabled)
                .disabled(isBusy)
            Toggle("Record the screen", isOn: Binding(
                get: { engine.debugRecordingEnabled }, set: { engine.setDebugRecording($0) }))
                .disabled(isBusy || !engine.sessionDiagnosticsEnabled)
            if let status = engine.recordingStatus {
                Text(recordingLine(status))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if status.isRecording {
                    Button("Stop recording", role: .destructive) { engine.stopRecording() }
                }
            }
            if let warning = engine.recordingWarnings.messages[.bugReport] {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Bug reports")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("When this is on, each session keeps a log and pictures of what the app saw, which can include notifications on screen. Recording the screen needs it.")
                if engine.debugRecordingEnabled { recordingWarningExplanation }
                Label("This records everything on your screen, not just the game: notifications, messages and anything you type. It's saved unencrypted in the app's folder and stops after 10 minutes or 300 MB. Turn it on only to report a problem, and watch the video yourself before sharing it.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(engine.debugRecordingEnabled ? .orange : .secondary)
            }
        }
    }

    private var recordingWarningExplanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Warns once at 90% of the size limit or with one minute remaining.")
            if engine.recordingWarnings.notificationsAllowed == false {
                Text("Notifications are off. Warnings will appear in this app. Allow notifications in Settings to see them while playing.")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Support

    private var support: some View {
        Section {
            if let mail = SupportContact.emailURL(appVersion: SupportContact.appVersion,
                                                  systemVersion: UIDevice.current.systemVersion,
                                                  hardware: SupportContact.hardware) {
                Link(destination: mail) {
                    LabeledContent {
                        Text(verbatim: SupportContact.email)
                    } label: {
                        Label("Email", systemImage: "envelope")
                    }
                }
                .contextMenu {
                    Button("Copy address", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = SupportContact.email
                    }
                }
            }
            Link(destination: SupportContact.telegram) {
                LabeledContent {
                    Text(verbatim: SupportContact.telegramDisplay)
                } label: {
                    Label("Telegram channel", systemImage: "paperplane")
                }
            }
        } header: {
            Text("Get support")
        } footer: {
            Text("Report a problem or ask a question. For a problem with recognition, share a report from Session logs and reports along with your message.")
        }
    }

    private func recordingLine(_ status: DebugRecordingStatus) -> String {
        // The recorder's own messages are technical and stay in English.
        if let message = status.message, !status.isRecording { return message }
        let elapsed = Duration.seconds(Int(status.coveredDuration)).formatted(.time(pattern: .minuteSecond))
        let size = ByteCountFormatter.string(fromByteCount: Int64(status.byteCount), countStyle: .file)
        return String(localized: "Recording · \(elapsed) · \(size)",
                      comment: "Screen recording progress. First: minutes and seconds recorded. Second: file size.")
    }
}
