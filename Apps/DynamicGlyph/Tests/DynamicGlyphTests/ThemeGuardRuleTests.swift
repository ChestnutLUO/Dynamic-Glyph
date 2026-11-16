import SwiftUI
import Testing

/// The places a theme's hue would read as a meaning colour keep their
/// colour: green is Accepted on the Hacking chart,
/// red is capturing on Home's Start and warning in the floating window, a
/// blue or grey there would read as collecting, predicted, idle or done.
@Suite("Theme guard rules")
struct ThemeGuardRuleTests {
    static let pinnedHacking: Set<AppTheme> = [.emerald, .crimson]

    @Test("Emerald and Crimson keep the Hacking series the default blue, in the app and in the widget",
          arguments: AppTheme.allCases)
    func hacking(_ theme: AppTheme) {
        let pinned = Self.pinnedHacking.contains(theme)
        #expect(theme.pinsHackingToDefault == pinned)
        if pinned {
            #expect(theme.widgetAccentHex == AppTheme.default.widgetAccentHex)
            #expect(theme.widgetAccentHex == AppTheme.HexPair(light: 0x0066CC, dark: 0x64A8FF))
            #expect(theme.hackingSeriesColor == .blue)
            #expect(ChartSeries.hacking.color(theme: theme) == .blue)
            #expect(StatisticsPanelStyle.app.color(.hacking, theme: theme) == .blue)
        } else {
            // The accent, which the app's root sets to the theme's tint.
            #expect(theme.hackingSeriesColor == .accentColor)
            #expect(ChartSeries.hacking.color(theme: theme) == .accentColor)
        }
        // Speed and Accepted never follow a theme.
        #expect(ChartSeries.speed.color(theme: theme) == .orange)
        #expect(ChartSeries.accepted.color(theme: theme) == .green)
    }

    @Test("Themes that don't pin Hacking give the widget their own colour")
    func widgetHackingFollowsTheOthers() {
        for theme in AppTheme.allCases where theme != .default && !Self.pinnedHacking.contains(theme) {
            #expect(theme.widgetAccentHex != AppTheme.default.widgetAccentHex, "\(theme)")
        }
    }

    @Test("Only Crimson keeps Home's idle Start system blue", arguments: AppTheme.allCases)
    func idleStart(_ theme: AppTheme) {
        #expect(theme.pinsIdleStartToBlue == (theme == .crimson))
        #expect(theme.idleStartTint == (theme == .crimson ? .blue : .accentColor))
    }

    @Test("Only Violet and Orchid change the floating window's and the Island's Glyph accent")
    func glyphAccent() {
        let changing = Set(AppTheme.allCases.filter(\.changesGlyphAccent))
        #expect(changing == [.violet, .orchid])
        for theme in AppTheme.allCases where !changing.contains(theme) {
            #expect(theme.glyphAccentRGB == AppTheme.RGB(red: 0.80, green: 0.78, blue: 1.00), "\(theme)")
        }
        #expect(AppTheme.violet.glyphAccentRGB == AppTheme.RGB(red: 0.76, green: 0.64, blue: 1.00))
        #expect(AppTheme.orchid.glyphAccentRGB == AppTheme.RGB(red: 0.97, green: 0.65, blue: 0.93))
    }
}
