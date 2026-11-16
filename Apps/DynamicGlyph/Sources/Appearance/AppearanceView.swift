import SwiftUI

/// Settings › Appearance: the app icons and colour
/// themes as tile grids, free for everyone. Every tile applies at once.
struct AppearanceView: View {
    @Environment(AppearanceStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
              count: dynamicTypeSize.isAccessibilitySize ? 2 : 4)
    }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AppIconChoice.allCases) { choice in
                        AppearanceTile(name: choice.name, isSelected: store.iconChoice == choice,
                                       outline: .rounded,
                                       action: { Task { await store.setIcon(choice) } }) {
                            AppIconPreview(choice: choice, size: 58)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 14)
            } header: {
                Text("App Icon", comment: "Appearance: the app icon section.")
            }
            Section {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AppTheme.allCases) { theme in
                        AppearanceTile(name: theme.name, isSelected: store.theme == theme,
                                       outline: .circle,
                                       action: { store.setTheme(theme) }) {
                            ThemeSwatch(theme: theme, size: 52)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 14)
            } header: {
                Text("Theme", comment: "Appearance: the colour theme section.")
            }
            Section {
                ThemePreview(theme: store.theme)
            } header: {
                Text("Preview", comment: "Appearance: a sample of the theme's accent beside the colours that never change.")
            } footer: {
                Text("A theme changes the app's accent color. Colors that carry a meaning, such as reading status and multiplied items, always stay the same.",
                     comment: "Appearance: under the themes.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refreshIconChoice() }
    }
}

/// The theme's accent beside the colours a theme never changes, so the
/// player sees what stays. Decorative: VoiceOver skips it.
private struct ThemePreview: View {
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array([18, 30, 12, 44, 26, 38].enumerated()), id: \.offset) { _, height in
                    // The theme's colour, as the hacks-per-day chart draws it;
                    // from the theme itself, not the environment's accent.
                    // The legend below keeps the Hacking series' own colour.
                    RoundedRectangle(cornerRadius: 4).fill(theme.displayTint)
                        .frame(width: 22, height: CGFloat(height))
                }
            }
            HStack(spacing: 12) {
                legend("Hacking", theme.hackingSeriesColor)
                legend("Speed", .orange)
                legend("Accepted", .green)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "L7 Resonator")
                    Text("multiplied", comment: "Hack card, one item: the game showed its quantity in red, as on the first hack of the day.")
                        .font(.caption).foregroundStyle(.red)
                }
                Spacer()
                // Red, as the game prints a multiplied quantity.
                Text(verbatim: "×2").foregroundStyle(.red)
            }
            // Home's Start at rest, as this theme shows it.
            Text("Start")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.idleStartTint))
            windowStrip
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 2)
        .accessibilityHidden(true)
    }

    /// The floating window's colours on its own dark ground: collected in
    /// the theme's Glyph accent, reading amber and predicted cyan as always.
    /// Its caption on a line of its own, so no language crowds the dots.
    private var windowStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Floating window").font(.caption2).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 10) {
                dot(theme.glyphAccent, "Collected")
                dot(Color(red: 1.00, green: 0.78, blue: 0.30), "Reading")
                dot(Color(red: 0.45, green: 0.85, blue: 0.95), "Predicted")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(red: 0.04, green: 0.05, blue: 0.08)))
    }

    private func legend(_ title: LocalizedStringResource, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dot(_ color: Color, _ title: LocalizedStringResource) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
    }
}
