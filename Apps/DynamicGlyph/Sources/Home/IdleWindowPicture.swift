import SwiftUI
import GlyphRecognition
import GlyphRecognitionImages

/// The gear-only floating window at rest, drawn once by the renderer the
/// window uses, at the canvas's own pixel size. Drawn again only when the
/// canvas changes: no timer, no animation.
struct IdleWindowPicture: View {
    /// Observed for its canvas, which Settings can change while Home is away.
    @ObservedObject var pip: GlyphPiPController
    private var canvas: PiPCanvasConfiguration { pip.canvas }
    @State private var image: CGImage?
    @State private var drawnCanvas: PiPCanvasConfiguration?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: CGFloat(canvas.resolution)).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .onAppear(perform: draw)
        .onChange(of: canvas) { _, _ in draw() }
        // The layer under it already reads as the floating window preview.
        .accessibilityHidden(true)
    }

    private func draw() {
        guard drawnCanvas != canvas || image == nil else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        image = GlyphDisplayRenderer(table: nil)
            .image(IdleWindowPreview.snapshot(uptime: uptime), canvas: canvas, atUptime: uptime, windowWidth: nil)
        drawnCanvas = canvas
    }
}
