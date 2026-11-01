import SwiftUI

/// A slider that moves in whole steps, with a tick at each one.
///
/// Ticks on the track need iOS 26. Earlier systems draw the plain track; the
/// `SliderTickLabels` beneath it still say what each step stands for.
struct SteppedSlider<Label: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// What a tick is called to accessibility; never shown.
    let tickName: (Double) -> String
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(iOS 26, *) {
            Slider(value: $value, in: range, step: 1, label: label, tick: { value in
                SliderTick(value) { Text(verbatim: tickName(value)) }
            })
        } else {
            Slider(value: $value, in: range, step: 1, label: label)
        }
    }
}
