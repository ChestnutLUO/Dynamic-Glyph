import SwiftUI
import GlyphRecognition
import TipKit

// The pages the Settings main page's rows open. Each holds a section that
// was on the one long page before 1.2's regroup, moved as it was: the same
// controls, bindings, footers and `.disabled(isBusy)`. The page title stands
// in for the section header it had.

/// Capture is running or changing state: the controls that would disturb it
/// are disabled, as they were on the one long page.
@MainActor private func settingsBusy(_ engine: CaptureEngine) -> Bool {
    engine.isCapturing || engine.isPreparing || engine.isStopping
}

/// A recording's progress, or the recorder's last message once it stopped.
func settingsRecordingLine(_ status: DebugRecordingStatus) -> String {
    // The recorder's own messages are technical and stay in English.
    if let message = status.message, !status.isRecording { return message }
    let elapsed = Duration.seconds(Int(status.coveredDuration)).formatted(.time(pattern: .minuteSecond))
    let size = ByteCountFormatter.string(fromByteCount: Int64(status.byteCount), countStyle: .file)
    return String(localized: "Recording · \(elapsed) · \(size)",
                  comment: "Screen recording progress. First: minutes and seconds recorded. Second: file size.")
}

// MARK: - Game language

/// Ingress has its own language setting, apart from the iPhone's; the
/// game's text can only be read in its own script.
struct GameLanguageSettingsPage: View {
    @ObservedObject var engine: CaptureEngine
    private var isBusy: Bool { settingsBusy(engine) }

    var body: some View {
        Form {
            Section {
                Picker("Game language", selection: $engine.gameLanguage) {
                    Text("Automatic").tag(GameLanguage?.none)
                    ForEach(GameLanguage.allCases, id: \.self) { language in
                        // Each language in its own name, as a language menu shows it.
                        Text(verbatim: language.nativeName).tag(GameLanguage?.some(language))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(isBusy)
                // What the game language tip suggests is done.
                .onChange(of: engine.gameLanguage) { _, _ in AppTips.retire(.gameLanguage) }
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
        .navigationTitle("Game language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Your faction

/// The player's own faction, so a hacked portal can be told as theirs,
/// the other side's or Machina's. Read as each record is made.
struct PlayerFactionSettingsPage: View {
    /// `AppPreferences.playerFaction`'s key: empty until the player sets it.
    @AppStorage("game.playerFaction") private var playerFactionCode = ""

    var body: some View {
        Form {
            Section {
                Picker("Your faction", selection: $playerFactionCode) {
                    Text("Not set").tag("")
                    // Game terms, as the English game names them.
                    Text(verbatim: "Resistance").tag(PortalFaction.resistance.rawValue)
                    Text(verbatim: "Enlightened").tag(PortalFaction.enlightened.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Saved with each hack from now on, so exports can tell your faction's portals from the other side's and Machina's. Hacks already saved keep what they had.")
            }
        }
        .navigationTitle("Your faction")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Glyph data

struct GlyphDataSettingsPage: View {
    @ObservedObject var engine: CaptureEngine
    var onImportTable: () -> Void
    var onImportSequences: () -> Void
    private var isBusy: Bool { settingsBusy(engine) }

    var body: some View {
        Form {
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
            } footer: {
                Text(isBusy
                     ? LocalizedStringResource("Stop watching to change these files.")
                     : LocalizedStringResource("The Glyph list is glyph_line.csv and the sequence list is glyph.csv. You can also drop them into this app's folder in the Files app.",
                                               comment: "Settings footer. Keep the two file names exactly as written."))
            }
        }
        .navigationTitle("Glyph data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Recognition engine

/// The player's choice of recognition: New, the default C++ engine and its
/// power cuts, or Old, the Swift recognition shipped before it. One choice
/// sets the pixel engine, the logic and the cuts; Diagnostics can still set
/// them apart, which shows as custom. Read when capture starts, like the rest
/// of reading.
struct RecognitionEngineSettingsPage: View {
    @ObservedObject var engine: CaptureEngine
    // Follows Diagnostics' pickers and switches too.
    @State private var current = RecognitionEngineSelection(AppPreferences())
    private var isBusy: Bool { settingsBusy(engine) }

    var body: some View {
        Form {
            Section {
                Picker("Recognition engine", selection: Binding(
                    get: { current },
                    set: { choice in
                        let preferences = AppPreferences()
                        choice.apply(to: preferences)
                        current = RecognitionEngineSelection(preferences)
                    })) {
                    ForEach(RecognitionEngineSelection.choices, id: \.self) { choice in
                        Text(verbatim: choice.label).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if current == .custom {
                    Text(verbatim: RecognitionEngineSelection.custom.label).foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New, the default, is the same recognition with its pixel work rewritten in C++, and uses less power. Old is the Swift recognition the app used before. Both should recognize the same; the Power section in Diagnostics shows which engine is running.",
                         comment: "Settings, recognition engine page footer. \"New\" and \"Old\" are the two choices above it. Keep \"C++\", \"Swift\" and \"Power\" (a Diagnostics section with an untranslated title) as written.")
                    if isBusy { Text("Changes to reading apply the next time you tap Start.") }
                }
            }
        }
        .onReceive(RecognitionEngineSelection.changes) { current = $0 }
        .navigationTitle("Recognition engine")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Floating window

struct FloatingWindowSettingsPage: View {
    @ObservedObject var engine: CaptureEngine

    var body: some View {
        Form {
            Section {
                Toggle("Hide from screenshots", isOn: Binding(
                    get: { engine.pip.preventsCapture },
                    set: { engine.pip.setPreventsCapture($0) }))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if engine.pip.preventsCapture {
                        Text("Screenshots and screen recordings show the window as black, including this app's own screen recording.")
                    }
                    Text("Pinch the window to resize it, drag to move it, or tuck it against the side of the screen to reach what's underneath.")
                }
            }
            // Its own section, open: "Shape and sharpness".
            PiPCanvasControls(pip: engine.pip)
        }
        .navigationTitle("Floating window")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Dynamic Island

struct DynamicIslandSettingsPage: View {
    @ObservedObject var engine: CaptureEngine

    var body: some View {
        Form {
            Section {
                Toggle("Animate changes", isOn: $engine.islandAnimationEnabled)
            } footer: {
                Text("Off, the Island switches to the next Glyph instantly. On, iOS slides and fades each update, which can look like the Island is shaking.")
            }
        }
        .navigationTitle("Dynamic Island")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Recording to Photos

struct AlbumRecordingSettingsPage: View {
    @ObservedObject var engine: CaptureEngine
    private var isBusy: Bool { settingsBusy(engine) }

    var body: some View {
        Form {
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
                    Text(settingsRecordingLine(status))
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
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if engine.albumAccessDenied {
                        Text("Allow Dynamic Glyph to add to Photos in the Settings app to use this.")
                            .foregroundStyle(.orange)
                    }
                    Text("Records the whole screen during the next session, including notifications, and saves the video to Photos when you stop. It stops by itself after 30 minutes or 1 GB. Separate from the bug report recording.")
                    if engine.albumRecordingEnabled {
                        Text("Sound is what the phone plays, such as the game's. The microphone is never recorded.")
                        RecordingWarningExplanation(engine: engine)
                    }
                }
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
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
}

// MARK: - Bug reports

struct BugReportsSettingsPage: View {
    @ObservedObject var engine: CaptureEngine
    private var isBusy: Bool { settingsBusy(engine) }

    var body: some View {
        Form {
            Section {
                Toggle("Save logs and screenshots", isOn: $engine.sessionDiagnosticsEnabled)
                    .disabled(isBusy)
                Toggle("Record the screen", isOn: Binding(
                    get: { engine.debugRecordingEnabled }, set: { engine.setDebugRecording($0) }))
                    .disabled(isBusy || !engine.sessionDiagnosticsEnabled)
                if let status = engine.recordingStatus {
                    Text(settingsRecordingLine(status))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if status.isRecording {
                        Button("Stop recording", role: .destructive) { engine.stopRecording() }
                    }
                }
                if let warning = engine.recordingWarnings.messages[.bugReport] {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("When this is on, each session keeps a log and pictures of what the app saw, which can include notifications on screen. Recording the screen needs it.")
                    if engine.debugRecordingEnabled { RecordingWarningExplanation(engine: engine) }
                    Label("This records everything on your screen, not just the game: notifications, messages and anything you type. It's saved unencrypted in the app's folder and stops after 10 minutes or 300 MB. Turn it on only to report a problem, and watch the video yourself before sharing it.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(engine.debugRecordingEnabled ? .orange : .secondary)
                }
            }
            Section {
                NavigationLink("Session logs and reports") {
                    SessionReportsView(activeFolder: engine.isCapturing || engine.isStopping
                                       ? engine.evidenceFolder : nil)
                }
                NavigationLink("Diagnostics") { DiagnosticsView(engine: engine) }
            } footer: {
                Text("Technical readouts for testing and bug reports.")
            }
        }
        .navigationTitle("Bug reports")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The recording limit warnings, under both recordings' switches.
private struct RecordingWarningExplanation: View {
    @ObservedObject var engine: CaptureEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Warns once at 90% of the size limit or with one minute remaining.")
            if engine.recordingWarnings.notificationsAllowed == false {
                Text("Notifications are off. Warnings will appear in this app. Allow notifications in Settings to see them while playing.")
                    .foregroundStyle(.orange)
            }
        }
    }
}
