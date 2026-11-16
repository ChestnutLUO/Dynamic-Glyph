import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// The colour themes, free for everyone. A theme changes
/// the accent only: the app's tint, the lavender of collected Glyphs and of
/// the "drawing" edge in the floating window and the Dynamic Island (Violet
/// and Orchid only), the Hacking chart series and the Summary widget's
/// Hacking colour (not Emerald or Crimson), and the Control Center switch's
/// tint.
///
/// Never themed, because they carry meaning: the reading-mode fills, the
/// amber of a Glyph being read, the cyan of a predicted one and of
/// collecting, done white, idle grey, warning and uncertain red, multiplied
/// red, Accepted green, Speed orange and the other chart series, faction and
/// rarity colours, and Home's red/grey Start while capturing or preparing.
///
/// `default` reproduces every colour the app had before themes, exactly.
/// Every per-theme value is in `spec`; nothing else counts or names themes.
/// Hues that share a meaning colour's keep it where it would be misread
/// (see `Spec.hacking`, `Spec.pinsIdleStartToBlue` and `Spec.glyphAccent`).
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    // The order of the grids and the icon list. The raw
    // values are what defaults and the App Group copy keep.
    case `default`
    case violet
    case orchid
    case graphite
    case cobalt
    case emerald
    case crimson

    var id: String { rawValue }

    /// Where the app keeps the choice, in standard defaults.
    static let defaultsKey = "appearance.theme"
    /// The App Group copy the widget extension reads.
    static let mirrorFileName = "AppTheme.txt"

    /// Components as the existing colours are written, for SwiftUI's
    /// `Color(red:green:blue:)` and Core Graphics' `CGColor(red:green:blue:alpha:)`.
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(hex: UInt32) {
            self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
        }

        var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
    }

    /// A colour in light and dark appearance, as hex.
    struct HexPair: Equatable, Sendable {
        var light: UInt32
        var dark: UInt32
    }

    /// Everything one theme decides, in one place. Adding, replacing or
    /// reordering a theme is a case above and its row in `spec`, plus its
    /// `.icon` package (listed in project.yml), its preview image and its
    /// name in the string catalog. Nothing else counts or names themes.
    struct Spec: Sendable {
        /// The name's key in the app's string catalog (Default, Violet...),
        /// shared by the theme and the icon of the same colour. Entries are
        /// kept by hand in the catalog ("manual"), since the key is not a
        /// literal in code.
        var nameKey: String
        /// The app's tint in light and dark appearance; nil keeps the system's.
        var appTint: (light: RGB, dark: RGB)?
        /// Collected Glyphs and the "drawing" edge in the floating window and
        /// the Island, on their dark ground. Only a hue no state there uses
        /// may differ from `defaultGlyphAccent`.
        var glyphAccent: RGB
        /// The Hacking series: the app's charts and the Summary widget. Nil
        /// pins it to the default blue, for a hue that would read as a
        /// meaning colour on the same chart (green is Accepted).
        var hacking: HexPair?
        /// Home's Start button at rest stays system blue, for a hue that
        /// would read as capturing's red.
        var pinsIdleStartToBlue = false
        /// The alternate `.icon` package of the same colour, for
        /// `setAlternateIconName` and ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES;
        /// nil is the primary icon.
        var iconName: String?
        /// Its 180-pixel tile in Media.xcassets: an image, not an app icon.
        var iconPreview: String
    }

    /// The lavender of `GlyphDisplayRenderer.Palette.confirmed` and the
    /// Island's observed tint.
    static let defaultGlyphAccent = RGB(red: 0.80, green: 0.78, blue: 1.00)

    /// The Summary widget's Hacking blue before themes.
    static let defaultHacking = HexPair(light: 0x0066CC, dark: 0x64A8FF)

    private static func tint(_ light: UInt32, _ dark: UInt32) -> (light: RGB, dark: RGB) {
        (RGB(hex: light), RGB(hex: dark))
    }

    /// The table: each theme's values.
    var spec: Spec {
        switch self {
        case .default:
            return Spec(nameKey: "Default", appTint: nil, glyphAccent: Self.defaultGlyphAccent,
                        hacking: Self.defaultHacking,
                        iconName: nil, iconPreview: "AppIconPreview-Default")
        case .violet:
            return Spec(nameKey: "Violet", appTint: Self.tint(0x6B3FE0, 0x8E6CFF),
                        glyphAccent: RGB(red: 0.76, green: 0.64, blue: 1.00),
                        hacking: HexPair(light: 0x6B3FE0, dark: 0xA68CFF),
                        iconName: "DynamicGlyphViolet", iconPreview: "AppIconPreview-Violet")
        case .orchid:
            return Spec(nameKey: "Orchid", appTint: Self.tint(0xA62BBF, 0xC35BDB),
                        glyphAccent: RGB(red: 0.97, green: 0.65, blue: 0.93),
                        hacking: HexPair(light: 0xA62BBF, dark: 0xE089F5),
                        iconName: "DynamicGlyphOrchid", iconPreview: "AppIconPreview-Orchid")
        case .graphite:
            // A grey in the window would read as idle grey or done white.
            return Spec(nameKey: "Graphite", appTint: Self.tint(0x48484A, 0x8E8E93),
                        glyphAccent: Self.defaultGlyphAccent,
                        hacking: HexPair(light: 0x48484A, dark: 0xC7C7CC),
                        iconName: "DynamicGlyphGraphite", iconPreview: "AppIconPreview-Graphite")
        case .cobalt:
            // A blue in the window would read as collecting or predicted cyan.
            return Spec(nameKey: "Cobalt", appTint: Self.tint(0x1F4FD8, 0x5B84FF),
                        glyphAccent: Self.defaultGlyphAccent,
                        hacking: HexPair(light: 0x1F4FD8, dark: 0x8FAAFF),
                        iconName: "DynamicGlyphCobalt", iconPreview: "AppIconPreview-Cobalt")
        case .emerald:
            // Green is the reading fill in the window and Accepted on the chart.
            return Spec(nameKey: "Emerald", appTint: Self.tint(0x127A3A, 0x2EA043),
                        glyphAccent: Self.defaultGlyphAccent,
                        hacking: nil,
                        iconName: "DynamicGlyphEmerald", iconPreview: "AppIconPreview-Emerald")
        case .crimson:
            // Red is warning in the window and capturing on Home's Start.
            return Spec(nameKey: "Crimson", appTint: Self.tint(0xC41E3A, 0xF2545B),
                        glyphAccent: Self.defaultGlyphAccent,
                        hacking: nil, pinsIdleStartToBlue: true,
                        iconName: "DynamicGlyphCrimson", iconPreview: "AppIconPreview-Crimson")
        }
    }

    /// The Hacking series stays the default blue.
    var pinsHackingToDefault: Bool { spec.hacking == nil }

    /// Home's Start button at rest stays system blue.
    var pinsIdleStartToBlue: Bool { spec.pinsIdleStartToBlue }

    /// Whether the floating window and the Island take another colour than
    /// the default lavender.
    var changesGlyphAccent: Bool { spec.glyphAccent != Self.defaultGlyphAccent }

    /// The app's tint. Nil keeps the system's, as the app had before themes.
    var appTint: Color? {
        spec.appTint.map { Color(uiColor: Self.dynamic($0.light.uiColor, $0.dark.uiColor)) }
    }

    /// The tint as the theme tiles and the Settings icon show it: system
    /// blue for the default.
    var displayTint: Color { appTint ?? Color(uiColor: .systemBlue) }

    /// The light and dark accents, for the split theme swatch.
    var tintPair: (light: Color, dark: Color) {
        guard let tint = spec.appTint else {
            let blue = UIColor.systemBlue
            return (Color(uiColor: blue.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))),
                    Color(uiColor: blue.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))))
        }
        return (Color(uiColor: tint.light.uiColor), Color(uiColor: tint.dark.uiColor))
    }

    var glyphAccentRGB: RGB { spec.glyphAccent }

    var glyphAccent: Color {
        Color(red: glyphAccentRGB.red, green: glyphAccentRGB.green, blue: glyphAccentRGB.blue)
    }

    var glyphAccentCGColor: CGColor {
        CGColor(red: glyphAccentRGB.red, green: glyphAccentRGB.green, blue: glyphAccentRGB.blue, alpha: 1)
    }

    /// The Summary widget's Hacking colour, light and dark: the default
    /// blue when the theme pins it.
    var widgetAccentHex: HexPair { spec.hacking ?? Self.defaultHacking }

    /// The Summary widget's Hacking colour.
    var widgetAccent: Color {
        Color(uiColor: Self.dynamic(RGB(hex: widgetAccentHex.light).uiColor, RGB(hex: widgetAccentHex.dark).uiColor))
    }

    /// The Hacking series in the app's charts: the accent, which follows
    /// the theme, or system blue when the theme pins it.
    var hackingSeriesColor: Color { pinsHackingToDefault ? .blue : .accentColor }

    /// Home's Start button at rest: the accent, or system blue when the
    /// theme pins it.
    var idleStartTint: Color { pinsIdleStartToBlue ? .blue : .accentColor }

    /// The Control Center switch's tint while on: the app's blue by default.
    var controlTint: Color { appTint ?? .blue }

    /// The theme the widget extension sees: the App Group copy.
    static var mirrored: AppTheme { AppThemeMirror.appGroup.read() }

    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

/// The App Group copy of the theme: a small file, like the Summary widget's
/// period, so the widget and the Live Activity read what the app last wrote.
struct AppThemeMirror: Sendable {
    let url: URL?

    static var appGroup: AppThemeMirror {
        AppThemeMirror(url: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: StatisticsWidgetSummary.appGroup)?
            .appendingPathComponent(AppTheme.mirrorFileName))
    }

    /// The default theme when there is no file or it names no theme.
    func read() -> AppTheme {
        url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { AppTheme(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .default
    }

    @discardableResult
    func write(_ theme: AppTheme) -> Bool {
        guard let url else { return false }
        do {
            try Data(theme.rawValue.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.default
}

extension EnvironmentValues {
    /// The chosen theme, set at the app's root, for the few views whose
    /// colour depends on more than the accent (the Hacking series, Home's
    /// Start). The widget extension leaves it at the default.
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
