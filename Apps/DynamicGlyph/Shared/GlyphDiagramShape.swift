import SwiftUI
import GlyphRecognition

/// The SwiftUI half of the shared diagram contract.
///
/// It takes its points from the same `GlyphDiagramLayout` the Picture in
/// Picture renderer uses, so the two cannot drift apart. SwiftUI's y already
/// increases downwards, which is the layout's declared convention, so no flip
/// is applied here — and none should be added.
///
/// Shared source: this file belongs to both the app and the widget extension,
/// so the Dynamic Island draws the same geometry as everything else.
struct GlyphDiagramShape: Shape {
    let path: GlyphPath
    var layout = GlyphDiagramLayout()

    func path(in rect: CGRect) -> Path {
        let point = layout.placer(in: rect)
        var result = Path()
        for segment in layout.segments(for: path) {
            result.move(to: point(segment.from))
            result.addLine(to: point(segment.to))
        }
        return result
    }
}

/// The array a Glyph is drawn on, faintly, behind it: the outer hexagon and
/// all eleven nodes. Many Glyphs are the same shape at a different size or
/// position, and without the array there is nothing to measure a stroke
/// against. The Picture in Picture renderer draws the same frame; give this
/// the same layout as the `GlyphDiagramShape` it sits behind.
struct GlyphArrayFrame: View {
    var layout = GlyphDiagramLayout()
    var lineWidth: CGFloat = 1
    var nodeRadius: CGFloat = 1.5
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            OutlineShape(layout: layout)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            // Filled dots, never rings: rings are what the array detector
            // locks on to, and this app's own display is captured.
            NodesShape(layout: layout, radius: nodeRadius).fill()
        }
        // The Glyph tints are pale; on a light background the frame has to
        // step back further to stay below them.
        .foregroundStyle(.secondary.opacity(colorScheme == .dark ? 0.5 : 0.22))
        .accessibilityHidden(true)
    }

    private struct OutlineShape: Shape {
        let layout: GlyphDiagramLayout

        func path(in rect: CGRect) -> Path {
            let point = layout.placer(in: rect)
            var result = Path()
            result.addLines(layout.outline().map(point))
            result.closeSubpath()
            return result
        }
    }

    private struct NodesShape: Shape {
        let layout: GlyphDiagramLayout
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            let point = layout.placer(in: rect)
            var result = Path()
            for position in layout.nodePositions() {
                let centre = point(position)
                result.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                             width: radius * 2, height: radius * 2))
            }
            return result
        }
    }
}

private extension GlyphDiagramLayout {
    /// Maps unit-tile coordinates into `rect`, square and centred.
    func placer(in rect: CGRect) -> (SIMD2<Double>) -> CGPoint {
        let placed = frame(in: SIMD2(Double(rect.minX), Double(rect.minY)),
                           size: SIMD2(Double(rect.width), Double(rect.height)))
        return { unit in
            CGPoint(x: placed.origin.x + unit.x * placed.side,
                    y: placed.origin.y + unit.y * placed.side)
        }
    }
}
