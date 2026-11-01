import SwiftUI

/// A numbered instruction, used by the home screen and setup.
struct StepRow: View {
    let number: Int
    let symbol: String
    let text: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number, format: .number)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
