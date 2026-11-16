import SwiftUI
import GlyphRecognition
import TipKit

/// Everything the home screen leaves out: the data files, fine-tuning the
/// floating window, bug-report recording, and the diagnostics a tester reads.
/// Short rows in three groups, each opening its page (SettingsPages.swift),
/// the way the iPhone's own Settings works.
struct SettingsView: View {
    @ObservedObject var engine: CaptureEngine
    var onRunSetup: () -> Void = {}
    var onImportTable: () -> Void
    var onImportSequences: () -> Void

    private var isBusy: Bool { engine.isCapturing || engine.isPreparing || engine.isStopping }
    /// `AppPreferences.playerFaction`'s key: empty until the player sets it.
    @AppStorage("game.playerFaction") private var playerFactionCode = ""
    /// The Recognition engine row's value, following its page and Diagnostics.
    @State private var recognitionSelection = RecognitionEngineSelection(AppPreferences())
    @Environment(AppearanceStore.self) private var appearance

    var body: some View {
        NavigationStack {
            Form {
                readingGroup
                whileYouPlayGroup
                recordingGroup
                rateAndSource
                support
                Section {
                    Button("Run setup again") {
                        AppPreferences().completedSetupVersion = 0
                        onRunSetup()
                    }
                    .disabled(isBusy)
                    LabeledContent("Version", value: SupportContact.appVersion)
                }
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
        .onReceive(RecognitionEngineSelection.changes) { recognitionSelection = $0 }
    }

    // MARK: - Reading

    /// What capture reads. The rows open their pages and stay tappable while
    /// capturing, so people can look; the controls inside are disabled.
    private var readingGroup: some View {
        Section {
            // Only once a Glyph list is loaded: before that there is no
            // Glyph assistance to switch, and nothing here promotes it.
            if showsGlyphAssistance {
                Toggle(isOn: $engine.glyphAssistancePreferred) {
                    Label {
                        Text("Glyph assistance")
                    } icon: {
                        SettingsIcon(systemName: "hand.draw.fill", background: SettingsSquare.purple)
                    }
                }
                .disabled(isBusy)
            }
            NavigationLink {
                GameLanguageSettingsPage(engine: engine)
            } label: {
                LabeledContent {
                    // As the page's list names it.
                    if let language = engine.gameLanguage {
                        Text(verbatim: language.nativeName)
                    } else {
                        Text("Automatic")
                    }
                } label: {
                    Label {
                        Text("Game language")
                    } icon: {
                        SettingsIcon(systemName: "globe", background: SettingsSquare.blue)
                    }
                }
            }
            NavigationLink {
                PlayerFactionSettingsPage()
            } label: {
                LabeledContent {
                    playerFactionValue
                } label: {
                    Label {
                        Text("Your faction")
                    } icon: {
                        // The chosen side's colour; grey while not set.
                        SettingsIcon(systemName: "flag.fill", background: playerFactionSquare)
                    }
                }
            }
            NavigationLink {
                GlyphDataSettingsPage(engine: engine, onImportTable: onImportTable,
                                      onImportSequences: onImportSequences)
            } label: {
                LabeledContent {
                    rowValue(.glyphData(count: engine.glyphCount))
                } label: {
                    Label {
                        Text("Glyph data")
                    } icon: {
                        SettingsIcon(systemName: "list.bullet.rectangle.fill", background: SettingsSquare.orange)
                    }
                }
            }
            NavigationLink {
                RecognitionEngineSettingsPage(engine: engine)
            } label: {
                LabeledContent {
                    Text(verbatim: recognitionSelection.label)
                } label: {
                    Label {
                        Text("Recognition engine")
                    } icon: {
                        SettingsIcon(systemName: "cpu", background: SettingsSquare.brown)
                    }
                }
            }
        } header: {
            Text(LocalizedStringResource("settings.group.reading", defaultValue: "Reading",
                                         comment: "Settings group header: Glyph assistance, game language, faction and Glyph data, what capture reads. Not the Appearance preview's Reading, the Glyph being read."))
        } footer: {
            // The one footer on the main page besides Get support's: what the
            // switch does, beside it.
            if showsGlyphAssistance {
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
    }

    private var showsGlyphAssistance: Bool {
        GlyphAssistance.showsSwitch(hasGlyphList: engine.hasGlyphList)
    }

    /// The faction picker's own words for the chosen value.
    @ViewBuilder private var playerFactionValue: some View {
        switch playerFactionCode {
        case PortalFaction.resistance.rawValue: Text(verbatim: "Resistance")
        case PortalFaction.enlightened.rawValue: Text(verbatim: "Enlightened")
        default: Text("Not set")
        }
    }

    /// The faction row's square: the chosen side's colour, grey when not set.
    private var playerFactionSquare: Color {
        switch playerFactionCode {
        case PortalFaction.resistance.rawValue: SettingsSquare.resistance
        case PortalFaction.enlightened.rawValue: SettingsSquare.enlightened
        default: SettingsSquare.factionUnset
        }
    }

    // MARK: - While you play

    private var whileYouPlayGroup: some View {
        Section {
            NavigationLink {
                FloatingWindowSettingsPage(engine: engine)
            } label: {
                Label {
                    Text("Floating window")
                } icon: {
                    SettingsIcon(systemName: "pip.fill", background: SettingsSquare.indigo)
                }
            }
            NavigationLink {
                DynamicIslandSettingsPage(engine: engine)
            } label: {
                Label {
                    Text("Dynamic Island")
                } icon: {
                    SettingsIcon(systemName: "capsule.fill", background: SettingsSquare.island)
                }
            }
            appearanceRow
        } header: {
            Text("While you play", comment: "Settings group header: the floating window, the Dynamic Island and Appearance.")
        }
    }

    // MARK: - Recording and reports

    /// A running recording shows on its row, in orange, so it's never
    /// hidden behind a page.
    private var recordingGroup: some View {
        Section {
            NavigationLink {
                AlbumRecordingSettingsPage(engine: engine)
            } label: {
                LabeledContent {
                    rowValue(.switched(isOn: engine.albumRecordingEnabled,
                                       runningLine: runningLine(engine.albumRecordingStatus)))
                } label: {
                    Label {
                        Text("Recording")
                    } icon: {
                        SettingsIcon(systemName: "record.circle.fill", background: SettingsSquare.red)
                    }
                }
            }
            NavigationLink {
                BugReportsSettingsPage(engine: engine)
            } label: {
                LabeledContent {
                    rowValue(.switched(isOn: engine.sessionDiagnosticsEnabled,
                                       runningLine: runningLine(engine.recordingStatus)))
                } label: {
                    Label {
                        Text("Bug reports")
                    } icon: {
                        SettingsIcon(systemName: "ladybug.fill", background: SettingsSquare.green)
                    }
                }
            }
        } header: {
            Text("Recording and reports", comment: "Settings group header: recording to Photos and bug reports.")
        }
    }

    private func runningLine(_ status: DebugRecordingStatus?) -> String? {
        guard let status, status.isRecording else { return nil }
        return settingsRecordingLine(status)
    }

    /// A row's trailing value: secondary, as `LabeledContent` styles it, or
    /// orange with steady digits while a recording runs.
    @ViewBuilder private func rowValue(_ value: SettingsRowValue) -> some View {
        if value.isRunning {
            Text(verbatim: value.text).monospacedDigit().foregroundStyle(.orange)
        } else {
            Text(verbatim: value.text)
        }
    }

    // MARK: - Appearance

    /// The theme and app icon, free for everyone. Its square is the
    /// theme's own tint.
    private var appearanceRow: some View {
        NavigationLink {
            AppearanceView()
                // What the themes tip suggests is done.
                .onAppear { AppTips.retire(.appearance) }
        } label: {
            Label {
                Text("Appearance")
            } icon: {
                SettingsIcon(systemName: "paintpalette.fill", background: appearance.theme.displayTint)
            }
        }
    }

    // MARK: - Rate and source code

    /// Two rows that leave the app, styled like Get support's: no header,
    /// no footer, no chevron.
    private var rateAndSource: some View {
        Section {
            Link(destination: RatingLinks.writeReview) {
                Label("Rate on the App Store", systemImage: "star")
            }
            Link(destination: RatingLinks.sourceCode) {
                Label {
                    // One text, so at large sizes both lines flow from the
                    // leading edge like the Rate row's, and VoiceOver reads
                    // title then subtitle. A line separator, not "\n": at
                    // accessibility sizes the icon sits inline as the first
                    // line's indent, and a new paragraph would get it again.
                    // The subtitle is the label grey of Email's address, not
                    // a shade of the link's tint.
                    Text("Source code on GitHub", comment: "Settings row that opens the app's source code on GitHub.")
                        + Text(verbatim: "\u{2028}")
                        + Text("If it's useful to you, give it a star.",
                               comment: "Settings, under Source code on GitHub. A star is GitHub's bookmark.")
                            .font(.footnote)
                            .foregroundStyle(Color(.secondaryLabel))
                } icon: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
            }
            .contextMenu {
                Button("Copy link", systemImage: "doc.on.doc") {
                    UIPasteboard.general.url = RatingLinks.sourceCode
                }
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
            Text("Report a problem or ask a question. For a problem with recognition, share a report from Bug reports › Session logs and reports along with your message.")
        }
    }
}

/// The squares' colours, iOS Settings' own. They stay the same in Dark;
/// only the Dynamic Island's lightens, so it isn't lost on a dark row.
enum SettingsSquare {
    static let purple = Color(red: 0xAF / 255, green: 0x52 / 255, blue: 0xDE / 255)
    static let blue = Color(red: 0x00 / 255, green: 0x7A / 255, blue: 0xFF / 255)
    static let brown = Color(red: 0xA2 / 255, green: 0x84 / 255, blue: 0x5E / 255)
    static let orange = Color(red: 0xFF / 255, green: 0x95 / 255, blue: 0x00 / 255)
    static let indigo = Color(red: 0x58 / 255, green: 0x56 / 255, blue: 0xD6 / 255)
    static let red = Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x30 / 255)
    static let green = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    // The faction row: one value each, the same in light and dark.
    static let factionUnset = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
    static let resistance = Color(red: 0x0E / 255, green: 0x86 / 255, blue: 0xCF / 255)
    static let enlightened = Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x3F / 255)
    static let island = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255, alpha: 1)
            : UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    })
}
