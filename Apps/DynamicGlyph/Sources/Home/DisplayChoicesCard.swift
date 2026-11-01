import SwiftUI
import GlyphRecognition

/// Where the sequence shows: the floating window, with its preview, and the
/// Dynamic Island.
struct DisplayChoicesCard: View {
    @ObservedObject var engine: CaptureEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(engine.assistsGlyphs
                 ? LocalizedStringResource("Show the sequence in")
                 : LocalizedStringResource("Show gear drops in"))
                .font(.headline)
            Toggle(isOn: $engine.pipEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Floating window")
                    Text(engine.assistsGlyphs
                         ? LocalizedStringResource("Stays on top of Ingress while you draw.")
                         : LocalizedStringResource("Stays on top of Ingress and shows each drop as it's read."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(engine.isPreparing || engine.isStopping || engine.floatingWindowRequired)
            if engine.floatingWindowRequired {
                Text(FloatingWindowRequirement.explanation)
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Picture in Picture opens from this layer, so it has to stay in
            // the hierarchy and visible; it doubles as a preview.
            SampleBufferHostView(layer: engine.pip.layer)
                .aspectRatio(engine.pip.canvas.aspectRatio, contentMode: .fit)
                // Before Start, in gear-only mode, the window at rest instead
                // of an empty black bar. Laid over the layer, never drawn into
                // it, and gone once the render loop runs.
                .overlay {
                    if IdleWindowPreview.shows(isCapturing: engine.isCapturing, isPreparing: engine.isPreparing,
                                               isStopping: engine.isStopping,
                                               floatingWindowRunning: engine.pip.isRunning,
                                               assistsGlyphs: engine.assistsGlyphs) {
                        IdleWindowPicture(pip: engine.pip)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Floating window preview")
            if engine.pip.isRunning {
                Button(engine.pip.isActive || engine.pip.isOpening
                       ? LocalizedStringResource("Hide floating window")
                       : LocalizedStringResource("Show floating window")) {
                    if engine.pip.isActive || engine.pip.isOpening { engine.pip.closeWindow() }
                    else { engine.pip.openWindow() }
                }
                .buttonStyle(.bordered)
                if engine.pip.wasDismissedByUser {
                    Text("The floating window was closed. Tap Show to bring it back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem = engine.pip.openingProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Toggle(isOn: $engine.liveActivityEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dynamic Island")
                    Text(!engine.activity.areActivitiesEnabled
                         ? LocalizedStringResource("Turn on Live Activities for this app in the Settings app.")
                         : engine.assistsGlyphs
                         ? LocalizedStringResource("The next Glyph in the Island and on the Lock Screen.")
                         : LocalizedStringResource("Each drop's item count in the Island and on the Lock Screen."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!engine.activity.areActivitiesEnabled)
        }
        .card()
    }
}
