import SwiftUI
import GlyphRecognition

/// Width, height and sharpness of the floating window's canvas.
struct PiPCanvasControls: View {
    @ObservedObject var pip: GlyphPiPController
    @State private var width = Double(PiPCanvasConfiguration.standard.width)
    @State private var height = Double(PiPCanvasConfiguration.standard.height)
    @State private var resolution = Double(PiPCanvasConfiguration.standard.resolution)

    private var draft: PiPCanvasConfiguration {
        PiPCanvasConfiguration(width: Int(width), height: Int(height), resolution: Int(resolution))
    }

    var body: some View {
        DisclosureGroup("Shape and sharpness") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Width: \(Int(width))").font(.caption)
                Slider(value: $width, in: 256...640, step: 16)
                    .accessibilityLabel("Width")
                Text("Height: \(Int(height))").font(.caption)
                Slider(value: $height, in: 64...192, step: 8)
                    .accessibilityLabel("Height")
                Text("Sharpness: \(Int(resolution))× · \(draft.pixelWidth)×\(draft.pixelHeight) pixels")
                    .font(.caption)
                SteppedSlider(value: $resolution, range: 1...3, tickName: { "\(Int($0.rounded()))×" }) {
                    Text("Sharpness")
                }
                SliderTickLabels(labels: ["1×", "2×", "3×"])
                HStack {
                    Button("Apply") { pip.applyCanvas(draft) }
                        .disabled(draft == pip.canvas)
                    Spacer()
                    Button("Reset") {
                        let standard = PiPCanvasConfiguration.standard
                        width = Double(standard.width)
                        height = Double(standard.height)
                        resolution = Double(standard.resolution)
                        pip.applyCanvas(standard)
                    }
                }
                .buttonStyle(.borderless)
                Text("Width and height set the window's proportions; iOS decides its actual size.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            width = Double(pip.canvas.width)
            height = Double(pip.canvas.height)
            resolution = Double(pip.canvas.resolution)
        }
    }
}
