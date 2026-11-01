import SwiftUI
import UIKit
import GlyphRecognition

/// First-run setup: what the app does, the risk to the player's account,
/// where it should show what it reads, and the floating window's shape and
/// sharpness. Every choice is saved as it is made; setup only counts as
/// finished on its last page.
///
/// Setup never asks for a Glyph list: that is added in Settings. Every line
/// with a Glyph version and a gear version takes the Glyph one only while
/// Glyph assistance is in effect, so a new player sees gear wording only.
struct SetupView: View {
    @ObservedObject var engine: CaptureEngine
    let onFinish: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var flow: SetupFlow
    @State private var history: [SetupStep] = [.welcome]
    @State private var canvas: PiPCanvasConfiguration

    private let preferences = AppPreferences()

    init(engine: CaptureEngine, onFinish: @escaping () -> Void) {
        self.engine = engine
        self.onFinish = onFinish
        let preferences = AppPreferences()
        _flow = State(initialValue: SetupFlow(
            detected: .current, reportedIsland: preferences.reportedDynamicIsland,
            wantsIsland: engine.liveActivityEnabled,
            activitiesEnabled: engine.activity.areActivitiesEnabled,
            floatingWindowEnabled: engine.pipEnabled,
            floatingWindowRequired: engine.floatingWindowRequired))
        _canvas = State(initialValue: SetupFlow.startingCanvas(saved: engine.pip.canvas))
    }

    private var step: SetupStep { history.last ?? .welcome }

    /// Glyph assistance in effect: the switch on and a Glyph list loaded.
    private var assistsGlyphs: Bool { engine.assistsGlyphs }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    page
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(step)
                // With Reduce Motion on, pages don't slide in.
                .transition(reduceMotion
                            ? AnyTransition.opacity
                            : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                          removal: .opacity))
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .toolbar {
                if history.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") {
                            changeHistory { _ = history.popLast() }
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the Settings app, where Live Activities live.
            if phase == .active { flow.activitiesEnabled = engine.activity.areActivitiesEnabled }
        }
        .onChange(of: engine.pipEnabled) { _, enabled in flow.floatingWindowEnabled = enabled }
    }

    private func advance() {
        changeHistory { history.append(flow.next(after: step)) }
    }

    /// Moves between pages, animated unless Reduce Motion is on.
    private func changeHistory(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : Animation.default, change)
    }

    // MARK: - Pages

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcome
        case .accountWarning: accountWarning
        case .dynamicIsland: dynamicIsland
        case .liveActivities: liveActivities
        case .floatingWindow: floatingWindow
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(symbol: "hexagon", title: "Welcome to Dynamic Glyph",
                   text: assistsGlyphs
                   ? LocalizedStringResource("It watches your Glyph hack and keeps the sequence in view while you draw.")
                   : LocalizedStringResource("It reads the gear each hack drops and keeps count for you.",
                                             comment: "Setup, welcome page subtitle, reading gear only."))
            PrivacyNote(results: engine.results, assistsGlyphs: assistsGlyphs)
            VStack(alignment: .leading, spacing: 14) {
                StepRow(number: 1, symbol: "play.circle", text: "Tap Start and share your screen.")
                if assistsGlyphs {
                    StepRow(number: 2, symbol: "hexagon", text: "Switch to Ingress and start a Glyph hack.")
                    StepRow(number: 3, symbol: "pip",
                            text: "The sequence appears in a floating window, and stays there while you draw.")
                } else {
                    // Home's own gear-only steps.
                    StepRow(number: 2, symbol: "hexagon", text: "Switch to Ingress and hack portals as usual.")
                    StepRow(number: 3, symbol: "shippingbox",
                            text: "The items each hack drops are read from the game's item panels and counted in Statistics.")
                }
            }
            .card()
        }
    }

    /// The README's "Before you install this", for players who never read it.
    private var accountWarning: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text("Before you use it").font(.title2.bold())
            Text("Dynamic Glyph is unofficial software, made by a player, with no connection to Niantic Spatial, who run Ingress. Their Player Guidelines list “using modified or unofficial software” as cheating. This app does not modify the game and never talks to it: it reads your own screen, on your own phone. The guidelines draw no line between software that changes the game and software that helps you play it.")
            Text("A violation can lead to a warning, degraded gameplay, suspension or permanent termination, sometimes without warning, and can reach every Niantic Spatial product. That risk is yours.")
                .bold()
            // At accessibility sizes the links stack, so neither is squeezed.
            let links = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 16))
            links {
                link("Player Guidelines", destination: Self.guidelinesURL)
                link("Terms of Service", destination: Self.termsURL)
            }
            .font(.callout.bold())
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A link at least 44 points high, tappable across its whole frame.
    private func link(_ title: LocalizedStringResource, destination: URL) -> some View {
        Link(destination: destination) {
            Text(title)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private static let guidelinesURL = URL(string: "https://www.nianticspatial.com/en/guidelines")!
    private static let termsURL = URL(string: "https://nianticspatial.com/terms")!

    @ViewBuilder private var dynamicIsland: some View {
        IslandIllustration().frame(maxWidth: .infinity)
        if flow.hasIsland == nil {
            header(symbol: nil, title: "Does your iPhone have a Dynamic Island?",
                   text: "It's the black pill at the top of the screen that grows to show what's going on.")
        } else if assistsGlyphs {
            header(symbol: nil, title: "Show the sequence in the Dynamic Island?",
                   text: "The Island shows the Glyph to draw now and the one after it. The Lock Screen shows the same.")
        } else {
            header(symbol: nil, title: "Show gear drops in the Dynamic Island?",
                   text: "The Island shows how many items each drop had. The Lock Screen shows the same.")
        }
    }

    private var liveActivities: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(symbol: "livephoto", title: "Turn on Live Activities",
                   text: "The Dynamic Island needs Live Activities, and they are off for Dynamic Glyph. In the Settings app, open Dynamic Glyph and turn on Live Activities.")
            if flow.activitiesEnabled {
                Label("Live Activities are on.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                Text("You can also do this later. The Dynamic Island switch on the home screen says when they are off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var floatingWindow: some View {
        VStack(alignment: .leading, spacing: 16) {
            if flow.canTurnOffFloatingWindow {
                header(symbol: "pip", title: "Also show a floating window?",
                       text: assistsGlyphs
                       ? LocalizedStringResource("It stays on top of Ingress and shows the whole sequence, not just the next Glyph.")
                       : LocalizedStringResource("It stays on top of Ingress and shows each drop as it's read."))
                Toggle("Floating window", isOn: $engine.pipEnabled)
            } else {
                header(symbol: "pip", title: "Set up the floating window",
                       text: assistsGlyphs
                       ? LocalizedStringResource("It stays on top of Ingress while you draw and shows the whole sequence.")
                       : LocalizedStringResource("It stays on top of Ingress and shows each drop as it's read."))
                if flow.floatingWindowRequired {
                    Label(FloatingWindowRequirement.explanation, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if flow.usesIsland {
                    Label(assistsGlyphs
                          ? LocalizedStringResource("Live Activities are off, so the Dynamic Island can't show the sequence yet. The floating window stays on until they are.")
                          : LocalizedStringResource("Live Activities are off, so the Dynamic Island can't show drops yet. The floating window stays on until they are.",
                                                    comment: "Setup, floating window page, reading gear only: the Island was chosen but Live Activities are off."),
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if flow.showsFloatingWindow {
                preview
                shapeSlider
                sharpnessSlider
                if assistsGlyphs { placementNote }
                Text("For other shapes, use Settings › Floating window › Shape and sharpness. iOS decides the window's size; pinch it to make it bigger or smaller.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if flow.hasIsland == false {
                Button("My iPhone has a Dynamic Island") {
                    flow.reportedIsland = true
                    preferences.reportedDynamicIsland = true
                    changeHistory { history.append(.dynamicIsland) }
                }
                .font(.footnote)
            }
        }
    }

    /// The preset shapes from tallest to thinnest, one slider tick each.
    private static let shapes = PiPCanvasConfiguration.presets.sorted { $0.aspectRatio < $1.aspectRatio }

    /// Whether the canvas has `other`'s proportions, whatever its sharpness.
    private func hasShape(of other: PiPCanvasConfiguration) -> Bool {
        canvas.width == other.width && canvas.height == other.height
    }

    /// A shape set in Settings sits on the nearest tick until the slider moves.
    private var shapeIndex: Binding<Double> {
        Binding(get: {
            let index = Self.shapes.firstIndex(where: hasShape(of:)) ?? Self.shapes.indices.min {
                abs(Self.shapes[$0].aspectRatio - canvas.aspectRatio) < abs(Self.shapes[$1].aspectRatio - canvas.aspectRatio)
            } ?? 0
            return Double(index)
        }, set: { value in
            let shape = Self.shapes[min(Self.shapes.count - 1, max(0, Int(value.rounded())))]
            canvas = PiPCanvasConfiguration(width: shape.width, height: shape.height, resolution: canvas.resolution)
        })
    }

    private var shapeSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shape").font(.headline)
                Spacer()
                if !Self.shapes.contains(where: hasShape(of:)) {
                    Text("Custom").foregroundStyle(.secondary)
                }
                Text(verbatim: Self.ratio(canvas)).monospacedDigit()
                if hasShape(of: .standard) {
                    Text("Recommended").font(.caption).foregroundStyle(.secondary)
                }
            }
            SteppedSlider(value: shapeIndex, range: 0...Double(Self.shapes.count - 1),
                          tickName: { Self.ratio(Self.shapes[Int($0.rounded())]) }) {
                Text("Shape")
            }
            SliderTickLabels(labels: Self.shapes.map(Self.ratio))
        }
    }

    private var sharpnessSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sharpness").font(.headline)
                Spacer()
                Text(verbatim: "\(canvas.resolution)× · \(canvas.pixelWidth) × \(canvas.pixelHeight) px")
                    .monospacedDigit()
                if canvas.resolution == PiPCanvasConfiguration.standard.resolution {
                    Text("Recommended").font(.caption).foregroundStyle(.secondary)
                }
            }
            SteppedSlider(value: Binding(get: { Double(canvas.resolution) }, set: { value in
                canvas = PiPCanvasConfiguration(width: canvas.width, height: canvas.height,
                                                resolution: Int(value.rounded()))
            }), range: 1...3, tickName: { "\(Int($0.rounded()))×" }) {
                Text("Sharpness")
            }
            SliderTickLabels(labels: ["1×", "2×", "3×"])
            Text("The window is drawn at this many pixels per point. A sharper window takes a little more power to draw; 2× suits most phones.",
                 comment: "Setup, floating window page, under Sharpness.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// With Glyph assistance in effect, the Glyph demo; otherwise what the
    /// window shows while reading gear, with no Glyph at all.
    private var preview: some View {
        let demo = assistsGlyphs ? SetupDemo(table: engine.shapeTable, sequences: engine.sequenceTable) : nil
        let showsOwnGlyphs = demo.map { !$0.usesBuiltInShapes } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            SetupCanvasPreview(canvas: canvas, demo: demo)
            Text(showsOwnGlyphs
                 ? LocalizedStringResource("Preview with your Glyph list.",
                                           comment: "Under the setup preview when a shape list is loaded.")
                 : LocalizedStringResource("Preview of the floating window's shape and sharpness.",
                                           comment: "Under the setup preview when it shows no Glyph list."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The window can sit anywhere, including over the slot row the app reads.
    /// Any shape taller than the standard strip covers more of the game.
    @ViewBuilder private var placementNote: some View {
        if hasShape(of: .standard) {
            Label("Keep the window clear of the slot row at the top of the game — the row of markers that shows how many Glyphs are coming. The app reads the sequence from it.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("A taller window covers more of the game", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.bold())
                Text("If it covers the slot row at the top of the game, the app can't read the sequence. While the Glyphs are being shown, drag the window down, or tuck it against the side of the screen to hide it, then bring it back to draw.")
                    .font(.callout)
            }
            .foregroundStyle(.orange)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 20) {
            if assistsGlyphs {
                header(symbol: "checkmark.seal", title: "You're set",
                       text: "Tap Start on the home screen, share your screen, then open a Glyph hack in Ingress.")
            } else {
                header(symbol: "checkmark.seal", title: "You're set",
                       text: "Tap Start on the home screen, share your screen, then hack portals in Ingress.")
            }
            VStack(alignment: .leading, spacing: 10) {
                if flow.hasIsland == true {
                    summary("Dynamic Island", Text(!flow.usesIsland
                            ? LocalizedStringResource("Off", comment: "Setup summary: this display will not be used.")
                            : flow.islandShowsSequence
                            ? LocalizedStringResource("On", comment: "Setup summary: this display will show the sequence.")
                            : LocalizedStringResource("Waiting for Live Activities",
                                                      comment: "Setup summary: the Dynamic Island was chosen, but Live Activities are off for the app.")))
                }
                summary("Floating window", flow.showsFloatingWindow
                        ? Text(verbatim: "\(canvas.pixelWidth) × \(canvas.pixelHeight)")
                        : Text(LocalizedStringResource("Off", comment: "Setup summary: this display will not be used.")))
                if assistsGlyphs {
                    // Already localized by the engine.
                    summary("Glyph list", Text(verbatim: engine.tableStatus))
                } else {
                    summary("Reads", Text(LocalizedStringResource("Gear drops",
                                                                  comment: "Setup summary: what the app reads after each hack.")))
                }
            }
            .card()
            Text("You can change any of this later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if assistsGlyphs { ResultReadingChoice(results: engine.results) }
        }
    }

    // MARK: - Buttons

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 8) {
            switch step {
            case .welcome:
                primary("Get started") { advance() }
            case .accountWarning:
                primary("I understand") { advance() }
            case .dynamicIsland:
                if flow.hasIsland == nil {
                    primary("Yes") {
                        flow.reportedIsland = true
                        preferences.reportedDynamicIsland = true
                    }
                    secondary("No") {
                        flow.reportedIsland = false
                        preferences.reportedDynamicIsland = false
                        advance()
                    }
                } else {
                    primary("Use the Dynamic Island") {
                        flow.wantsIsland = true
                        engine.liveActivityEnabled = true
                        advance()
                    }
                    secondary("Not now") {
                        flow.wantsIsland = false
                        engine.liveActivityEnabled = false
                        advance()
                    }
                }
            case .liveActivities:
                primary("Continue") { advance() }
            case .floatingWindow:
                primary("Continue") {
                    // Until the Island can show the sequence, this is the only display.
                    if !flow.canTurnOffFloatingWindow { engine.pipEnabled = true }
                    if flow.showsFloatingWindow, canvas != engine.pip.canvas { engine.pip.applyCanvas(canvas) }
                    advance()
                }
            case .done:
                primary("Finish") {
                    preferences.completedSetupVersion = AppPreferences.currentSetupVersion
                    onFinish()
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func primary(_ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func secondary(_ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Pieces

    private func header(symbol: String?, title: LocalizedStringResource, text: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(Color.accentColor)
            }
            Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(_ label: LocalizedStringResource, _ value: Text) -> some View {
        HStack {
            Text(label)
            Spacer()
            value.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private static func ratio(_ canvas: PiPCanvasConfiguration) -> String {
        let value = canvas.aspectRatio
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)):1" : "\(rounded):1"
    }
}

/// What leaves the phone. Observes results on its own, as below.
private struct PrivacyNote: View {
    @ObservedObject var results: HackResults
    let assistsGlyphs: Bool

    var body: some View {
        Label(results.uploadsResults(assistsGlyphs: assistsGlyphs)
              ? LocalizedStringResource("Screen sharing stays on your phone, and the recording indicator stays visible the whole time. iCloud sync is on, so saved hack results are uploaded to your iCloud.")
              : LocalizedStringResource("Screen sharing stays on your phone, and the recording indicator stays visible the whole time. Nothing is uploaded."),
              systemImage: results.uploadsResults(assistsGlyphs: assistsGlyphs) ? "icloud" : "lock")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// The result-reading switch, observed on its own: the setup view watches the
/// engine, and results publish separately from it.
private struct ResultReadingChoice: View {
    @ObservedObject var results: HackResults

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $results.readsResults) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read results from the game")
                    Text(results.syncsWithICloud
                         ? LocalizedStringResource("After each hack, reads the bonuses and which Glyphs the game accepted from its result screen. Saved results stay on your phone and in your iCloud.")
                         : LocalizedStringResource("After each hack, reads the bonuses and which Glyphs the game accepted from its result screen. Everything stays on your phone."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // Gear is matched to each hack's result, so it needs result reading.
            if results.readsResults {
                Toggle(isOn: $results.readsGear) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read gear")
                        Text("Also reads the item panels after each hack and shows what the hack gave you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("You can change this later in Statistics.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

/// The top of an iPhone with a Dynamic Island, so "the black pill" needs no
/// knowledge of the hardware's name. Proportions follow an iPhone 16 Pro: the
/// display's corner is about 14% of its width, the Island 32% of it and 3%
/// below its top edge. The bezel's corner is concentric with the display's,
/// and the phone fades out rather than being cut off square.
private struct IslandIllustration: View {
    private let displayWidth = 200.0
    private let bezel = 7.0

    var body: some View {
        let displayRadius = displayWidth * 0.14
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: displayRadius + bezel, style: .continuous)
                .fill(Color(.systemGray))
                .frame(width: displayWidth + 2 * bezel, height: 170)
            RoundedRectangle(cornerRadius: displayRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .frame(width: displayWidth, height: 170 - bezel)
                .padding(.top, bezel)
            Capsule()
                .fill(Color.black)
                .frame(width: displayWidth * 0.32, height: displayWidth * 0.095)
                .padding(.top, bezel + displayWidth * 0.03)
        }
        .frame(height: 120, alignment: .top)
        // Fade the flattened drawing, or the bezel shows through the fading screen.
        .compositingGroup()
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .accessibilityHidden(true)
    }
}
