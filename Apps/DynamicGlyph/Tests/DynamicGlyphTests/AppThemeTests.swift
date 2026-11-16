import Foundation
import SwiftUI
import Testing
import UIKit

@Suite("App themes")
struct AppThemeTests {
    static func hex(_ rgb: AppTheme.RGB) -> UInt32 {
        UInt32((rgb.red * 255).rounded()) << 16 | UInt32((rgb.green * 255).rounded()) << 8 | UInt32((rgb.blue * 255).rounded())
    }

    @Test("Default first, then the six themes in the design's order")
    func order() {
        #expect(AppTheme.allCases.first == .default)
        #expect(AppTheme.allCases == [.default, .violet, .orchid, .graphite, .cobalt, .emerald, .crimson])
    }

    @Test("The default theme keeps every colour the app had before themes")
    func defaultUnchanged() {
        let theme = AppTheme.default
        #expect(theme.appTint == nil)
        #expect(theme.spec.appTint == nil)
        #expect(theme.glyphAccentRGB == AppTheme.RGB(red: 0.80, green: 0.78, blue: 1.00))
        #expect(theme.glyphAccent == Color(red: 0.80, green: 0.78, blue: 1.00))
        #expect(theme.widgetAccentHex == AppTheme.HexPair(light: 0x0066CC, dark: 0x64A8FF))
        #expect(theme.controlTint == .blue)
        #expect(theme.hackingSeriesColor == .accentColor)
        #expect(theme.idleStartTint == .accentColor)
        #expect(!theme.changesGlyphAccent)
        #expect(theme.spec.iconName == nil)
    }

    @Test("The themes' tints, light and dark")
    func tints() throws {
        let expected: [AppTheme: (UInt32, UInt32)] = [
            .violet: (0x6B3FE0, 0x8E6CFF), .orchid: (0xA62BBF, 0xC35BDB), .graphite: (0x48484A, 0x8E8E93),
            .cobalt: (0x1F4FD8, 0x5B84FF), .emerald: (0x127A3A, 0x2EA043), .crimson: (0xC41E3A, 0xF2545B),
        ]
        #expect(Set(expected.keys) == Set(AppTheme.allCases.filter { $0 != .default }))
        for (theme, pair) in expected {
            let tint = try #require(theme.spec.appTint, "\(theme)")
            #expect(Self.hex(tint.light) == pair.0, "\(theme)")
            #expect(Self.hex(tint.dark) == pair.1, "\(theme)")
            #expect(theme.appTint != nil)
        }
    }

    @Test("The tint resolves to its light and dark value")
    func dynamicTint() throws {
        let tint = try #require(AppTheme.cobalt.appTint)
        let ui = UIColor(tint)
        let light = ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        light.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(abs(red - 0x1F / 255) < 0.01 && abs(green - 0x4F / 255) < 0.01 && abs(blue - 0xD8 / 255) < 0.01)
        dark.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(abs(red - 0x5B / 255) < 0.01 && abs(green - 0x84 / 255) < 0.01 && abs(blue - 0xFF / 255) < 0.01)
    }

    @Test("Each theme names its own icon, preview and catalog key")
    func assetsAreDistinct() {
        let specs = AppTheme.allCases.map(\.spec)
        #expect(Set(specs.map(\.nameKey)).count == specs.count)
        #expect(Set(specs.map(\.iconPreview)).count == specs.count)
        let icons = specs.compactMap(\.iconName)
        #expect(icons.count == specs.count - 1, "Every theme but the default has an alternate icon")
        #expect(Set(icons).count == icons.count)
        for theme in AppTheme.allCases where theme != .default {
            #expect(theme.spec.iconName == "DynamicGlyph\(theme.spec.nameKey)")
            #expect(theme.spec.iconPreview == "AppIconPreview-\(theme.spec.nameKey)")
        }
    }

    @Test("The App Group copy round-trips, and anything unreadable is the default")
    func mirror() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(AppTheme.mirrorFileName)
        let mirror = AppThemeMirror(url: url)
        #expect(mirror.read() == .default)
        for theme in AppTheme.allCases {
            #expect(mirror.write(theme))
            #expect(mirror.read() == theme)
        }
        try Data("theme9\n".utf8).write(to: url)
        #expect(mirror.read() == .default)
        try Data("emerald\n".utf8).write(to: url)
        #expect(mirror.read() == .emerald)
        #expect(AppThemeMirror(url: nil).read() == .default)
        #expect(!AppThemeMirror(url: nil).write(.violet))
    }

    @Test("Preferences keep the theme in defaults and copy it to the App Group")
    func preferences() throws {
        let suite = "AppThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mirror = AppThemeMirror(url: directory.appendingPathComponent(AppTheme.mirrorFileName))
        let preferences = AppearancePreferences(defaults: defaults, mirror: mirror)
        #expect(preferences.theme == .default)
        preferences.theme = .crimson
        #expect(defaults.string(forKey: AppTheme.defaultsKey) == "crimson")
        #expect(mirror.read() == .crimson)
        // A restore that left the App Group behind.
        #expect(mirror.write(.default))
        #expect(preferences.syncMirror())
        #expect(mirror.read() == .crimson)
        #expect(!preferences.syncMirror())
        defaults.set("gone", forKey: AppTheme.defaultsKey)
        #expect(preferences.theme == .default)
    }
}

@Suite("App icon choices")
struct AppIconChoiceTests {
    @Test("One icon per theme, the primary for the default")
    func perTheme() {
        #expect(AppIconChoice.allCases.map(\.theme) == AppTheme.allCases)
        #expect(AppIconChoice.default.alternateIconName == nil)
        for choice in AppIconChoice.allCases {
            #expect(AppIconChoice(alternateIconName: choice.alternateIconName) == choice)
        }
        #expect(AppIconChoice(alternateIconName: "Unknown") == .default)
    }

    @Test("An alternate counts as bundled only when the Info.plist lists it")
    func bundled() {
        let violet = AppIconChoice(theme: .violet)
        let info: [String: Any] = ["CFBundleIcons": ["CFBundleAlternateIcons": ["DynamicGlyphViolet": ["CFBundleIconName": "DynamicGlyphViolet"]]]]
        #expect(AppIconChoice.isBundled(violet, infoDictionary: info))
        #expect(!AppIconChoice.isBundled(AppIconChoice(theme: .crimson), infoDictionary: info))
        #expect(!AppIconChoice.isBundled(violet, infoDictionary: [:]))
        #expect(AppIconChoice.isBundled(.default, infoDictionary: nil))
    }
}

/// A theme added to `AppTheme.spec` needs its icon, preview, build setting
/// and name in four languages; read from the source tree, so skipped where
/// there is no checkout.
@Suite("Theme assets in the project")
struct ThemeProjectTests {
    static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var checkoutAvailable: Bool {
        FileManager.default.fileExists(atPath: app.appendingPathComponent("project.yml").path)
    }

    @Test("Every alternate icon is a source, in the build setting, and has its .icon package",
          .enabled(if: checkoutAvailable))
    func icons() throws {
        let project = try String(contentsOf: Self.app.appendingPathComponent("project.yml"), encoding: .utf8)
        // The folded value's lines, under the key.
        let setting = project.split(separator: "\n")
            .drop { !$0.contains("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES:") }
            .dropFirst().prefix { $0.hasPrefix("          ") }
            .joined(separator: " ")
        let listed = Set(setting.split(separator: " ").map(String.init))
        let icons = AppTheme.allCases.compactMap(\.spec.iconName)
        #expect(listed == Set(icons))
        for icon in icons {
            #expect(project.contains("      - \(icon).icon\n"), "\(icon) is not a source")
            let json = Self.app.appendingPathComponent("\(icon).icon/icon.json")
            #expect(FileManager.default.fileExists(atPath: json.path), "\(icon).icon")
        }
    }

    @Test("Every preview tile is in Media.xcassets", .enabled(if: checkoutAvailable))
    func previews() {
        for theme in AppTheme.allCases {
            let name = theme.spec.iconPreview
            let png = Self.app.appendingPathComponent("Media.xcassets/\(name).imageset/\(name).png")
            #expect(FileManager.default.fileExists(atPath: png.path), "\(name)")
        }
    }

    @Test("Every theme's name is translated, and kept by hand in the catalog", .enabled(if: checkoutAvailable))
    func names() throws {
        let url = Self.app.appendingPathComponent("Sources/Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        for theme in AppTheme.allCases {
            let entry = try #require(strings[theme.spec.nameKey], "\(theme.spec.nameKey)")
            let state = entry["extractionState"] as? String
            #expect(state == "manual", "\(theme.spec.nameKey)")
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in ["ja", "zh-Hans", "zh-Hant"] {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                #expect(!value.isEmpty, "\(theme.spec.nameKey) in \(language)")
            }
        }
    }
}
