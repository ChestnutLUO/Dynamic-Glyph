import Foundation
import Testing

/// The flag a red quantity sets is shown as "multiplied" (加倍, 倍増), the
/// players' word, never "in red": the owner confirmed red always means the
/// game multiplied the drop (msg 2015, check updated with his OK in msg 2031).
/// Read from the source tree, like `LocalizationCatalogTests`.
@Suite("Red quantities are labelled multiplied")
struct InRedLabelTests {
    static let catalogs = [
        "Apps/DynamicGlyph/Sources/Resources/Localizable.xcstrings",
        "Apps/DynamicGlyph/Widget/Localizable.xcstrings",
    ].map { LocalizationCatalogTests.repository.appendingPathComponent($0) }

    static var checkoutAvailable: Bool {
        catalogs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func strings(_ url: URL) throws -> [String: [String: Any]] {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try #require(catalog?["strings"] as? [String: [String: Any]])
    }

    static func value(_ entry: [String: Any]?, _ language: String) -> String? {
        let localizations = entry?["localizations"] as? [String: Any]
        let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    @Test("Each catalog has the count, the app the item tag, in the agreed words; none says in red",
          .enabled(if: checkoutAvailable))
    func catalogs() throws {
        let terms = ["ja": "倍増", "zh-Hans": "加倍", "zh-Hant": "加倍"]
        for url in Self.catalogs {
            let strings = try Self.strings(url)
            let count = strings["%lld multiplied"]
            #expect(count != nil, "\(url.lastPathComponent)")
            for (language, term) in terms {
                #expect(Self.value(count, language) == "\(term) %lld")
            }
            for (key, entry) in strings {
                #expect(!key.localizedCaseInsensitiveContains("in red"), "\(key)")
                for language in terms.keys {
                    let text = Self.value(entry, language) ?? ""
                    #expect(!text.contains("赤表示") && !text.contains("红字") && !text.contains("紅字"), "\(key) in \(language)")
                }
            }
        }
        let app = try Self.strings(Self.catalogs[0])
        for (language, term) in terms { #expect(Self.value(app["multiplied"], language) == term) }
    }
}
