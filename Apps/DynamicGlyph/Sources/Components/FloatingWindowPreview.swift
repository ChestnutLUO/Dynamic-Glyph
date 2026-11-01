import SwiftUI

/// The floating window's live layer, for the tabs other than Home.
///
/// The window opens only from a layer that is in the window hierarchy,
/// including when the player leaves the app from whichever tab is showing.
/// Each tab offers a host, but only the selected tab may attach the shared
/// layer: TabView can retain inactive views in the window hierarchy.
struct FloatingWindowPreview: View {
    @ObservedObject var engine: CaptureEngine

    var body: some View {
        if engine.isCapturing && engine.pipEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text("Floating window").font(.subheadline.bold()).foregroundStyle(.secondary)
                SampleBufferHostView(layer: engine.pip.layer)
                    .aspectRatio(engine.pip.canvas.aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Floating window preview")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}
