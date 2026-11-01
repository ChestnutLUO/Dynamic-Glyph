import SwiftUI

/// Captions under a slider's evenly spaced ticks. iOS draws a `SliderTick` as
/// a dot and leaves its label to accessibility, so the value each dot stands
/// for has to be written underneath. The first and last ticks sit half a thumb
/// in from the track's ends, which is `inset`.
struct SliderTickLabels: View {
    let labels: [String]
    var inset: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let span = max(0, geometry.size.width - 2 * inset)
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let fraction = labels.count > 1 ? CGFloat(index) / CGFloat(labels.count - 1) : 0.5
                Text(verbatim: label)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: inset + span * fraction, y: geometry.size.height / 2)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}
