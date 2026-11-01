import Foundation
import Testing

/// Checks every string catalog in the repository, the app's and widget's as
/// well as this package's, because a missing translation fails silently at run
/// time: the string simply shows in English.
///
/// Read from the source tree, so it skips where there is no checkout (Xcode
/// Cloud runs tests on a machine that has only the built bundle).
@Suite("Localization catalogs")
struct LocalizationCatalogTests {
    static let languages = ["ja", "zh-Hans", "zh-Hant"]

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let catalogs = [
        "Apps/DynamicGlyph/Sources/Resources/Localizable.xcstrings",
        "Apps/DynamicGlyph/Sources/Resources/InfoPlist.xcstrings",
        "Apps/DynamicGlyph/Sources/Resources/AppShortcuts.xcstrings",
        "Apps/DynamicGlyph/Widget/Localizable.xcstrings",
        "Apps/DynamicGlyph/Broadcast/Localizable.xcstrings",
        "Packages/GlyphRecognition/Sources/GlyphRecognition/Localizable.xcstrings",
        "Packages/GlyphRecognition/Sources/GlyphRecognitionImages/Localizable.xcstrings",
    ].map { repository.appendingPathComponent($0) }

    static var checkoutAvailable: Bool {
        catalogs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The format specifiers a string consumes, positions stripped, as a
    /// multiset: `%1$lld` and `%lld` are the same argument, reordered.
    static func specifiers(_ text: String) -> [String] {
        let pattern = /%(?:\d+\$)?(lld|ld|d|@|f|\.\d+f)/
        return text.matches(of: pattern).map { String($0.output.1) }.sorted()
    }

    /// The `${name}` placeholders of App Intents strings, such as Siri
    /// phrases' `${applicationName}`, as a multiset.
    static func tokens(_ text: String) -> [String] {
        text.matches(of: /\$\{[A-Za-z]+\}/).map { String($0.output) }.sorted()
    }

    @Test("Every string has a Japanese, Simplified and Traditional Chinese translation with matching placeholders",
          .enabled(if: checkoutAvailable), arguments: catalogs)
    func complete(_ url: URL) throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty, "\(url.lastPathComponent) holds no strings")
        for (key, entry) in strings {
            if entry["shouldTranslate"] as? Bool == false { continue }
            // Strings no longer in the code are dropped by the next sync;
            // translating them would be wasted work.
            if entry["extractionState"] as? String == "stale" { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in Self.languages {
                let localization = localizations[language] as? [String: Any]
                let unit = localization?["stringUnit"] as? [String: Any]
                // Siri phrases (AppShortcuts.xcstrings) hold a set: one or
                // more phrases in each language for each English one.
                let set = (localization?["stringSet"] as? [String: Any])?["values"] as? [String]
                let values = (set ?? [unit?["value"] as? String ?? ""]).filter { !$0.isEmpty }
                #expect(!values.isEmpty, "\(url.pathComponents.suffix(3).joined(separator: "/")): '\(key)' has no \(language) translation")
                for value in values {
                    #expect(Self.specifiers(value) == Self.specifiers(key),
                            "'\(key)' in \(language) uses \(Self.specifiers(value)), source uses \(Self.specifiers(key))")
                    #expect(Self.tokens(value) == Self.tokens(key),
                            "'\(key)' in \(language) uses \(Self.tokens(value)), source uses \(Self.tokens(key))")
                }
            }
        }
    }

    /// English plural forms, by plural category, of the entry for `key`.
    static func englishPlurals(_ entry: [String: Any]) -> [String: String] {
        let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
        let plural = (english?["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.compactMapValues { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    @Test("English plural forms keep the source's placeholders", .enabled(if: checkoutAvailable), arguments: catalogs)
    func englishPluralSpecifiers(_ url: URL) throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        for (key, entry) in strings {
            for (category, value) in Self.englishPlurals(entry) {
                #expect(Self.specifiers(value) == Self.specifiers(key), "'\(key)' English \(category) is '\(value)'")
            }
        }
    }

    /// English uses its one form for 1 only; 0 and 2 take the key's other form.
    @Test("The Summary widget's counts say 1 hack, 0 or 2 hacks, in English", .enabled(if: checkoutAvailable))
    func summaryWidgetPlurals() throws {
        let url = Self.repository.appendingPathComponent("Apps/DynamicGlyph/Widget/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        let expected = [
            "%lld hacks": "%lld hack", "%lld drops": "%lld drop", "%lld items": "%lld item",
            "Includes %lld bonus items": "Includes %lld bonus item",
        ]
        for (key, one) in expected {
            let entry = try #require(strings[key], "'\(key)' is missing from the widget catalog")
            #expect(Self.englishPlurals(entry) == ["one": one, "other": key], "'\(key)'")
        }
    }

    @Test("Specifiers are compared by argument, not by position")
    func specifierParsing() {
        #expect(Self.specifiers("%1$lld of %2$@") == Self.specifiers("%lld of %@"))
        #expect(Self.specifiers("%lld×%lld") == ["lld", "lld"])
        #expect(Self.specifiers("%@ · %@") != Self.specifiers("%@"))
    }
}
