import SwiftUI
import GlyphRecognition
import GlyphRecognitionImages

/// The floating window's frame for `canvas`, animating the setup demo. Drawn
/// by the renderer Picture in Picture uses, at the canvas's own pixel size,
/// so the preview is the window rather than a picture of it.
struct SetupCanvasPreview: View {
    let canvas: PiPCanvasConfiguration
    /// The Glyph demo while Glyph assistance is in effect; nil shows what
    /// gear-only capture's window shows, with no Glyph at all.
    let demo: SetupDemo?
    @State private var started = Date()

    private func previewSnapshot(at elapsed: Double, uptime: Double) -> GlyphDisplaySnapshot {
        demo?.snapshot(at: elapsed, uptime: uptime) ?? SetupDemo.gearSnapshot(at: elapsed, uptime: uptime)
    }

    var body: some View {
        GeometryReader { geometry in
            // 15 Hz, the floating window's own render rate.
            TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
                let uptime = ProcessInfo.processInfo.systemUptime
                let snapshot = previewSnapshot(at: context.date.timeIntervalSince(started), uptime: uptime)
                if let frame = GlyphDisplayRenderer(table: demo?.table)
                    .image(snapshot, canvas: canvas, atUptime: uptime, windowWidth: geometry.size.width) {
                    Image(decorative: frame, scale: CGFloat(canvas.resolution))
                        .resizable()
                        .interpolation(.high)
                }
            }
        }
        .aspectRatio(canvas.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: PiPCanvasConfiguration.windowCornerRadius))
        .accessibilityLabel("Floating window preview")
    }
}
