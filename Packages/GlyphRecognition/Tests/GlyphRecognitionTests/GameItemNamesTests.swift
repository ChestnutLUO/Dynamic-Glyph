import Foundation
import Testing
@testable import GlyphRecognition

/// Item names shown in the game's language: each item in the player's sheet
/// has exactly the sheet's name in Chinese and Japanese, and English
/// everywhere else or wherever a name is missing.
///
/// The sheet is read from the source tree, so the sheet checks skip where
/// there is no checkout, as the Localization catalogs suite does.
@Suite("Game item names")
struct GameItemNamesTests {
    static let sheet = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Docs/GAME_TEXT_TRANSLATIONS_ALL.csv")

    static var sheetAvailable: Bool { FileManager.default.fileExists(atPath: sheet.path) }

    /// The sheet's columns for each language with its own names.
    static let columns: [(GameLanguage, Int)] = [(.simplifiedChinese, 4), (.traditionalChinese, 5), (.japanese, 6)]

    /// RFC 4180 fields: quoted fields may hold commas and doubled quotes.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var characters = Array(text).makeIterator()
        var pending: Character? = nil
        while let character = pending ?? characters.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = characters.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" { quoted = true
            } else if character == "," { row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" { row.append(field); rows.append(row); row = []; field = ""
            } else if character != "\r" { field.append(character) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// The item rows: English name, then the row's cells. "Item, shortened"
    /// is an example of a name cut short ("Kinetic C…"), not an item.
    static func items() throws -> [(String, [String])] {
        try rows(String(contentsOf: sheet, encoding: .utf8))
            .filter { $0.first?.hasPrefix("Item,") == true && $0.first != "Item, shortened" }
            .map { ($0[1], $0) }
    }

    @Test("Every item in the sheet has exactly its sheet name in zh-Hans, zh-Hant and ja",
          .enabled(if: sheetAvailable))
    func everyItemMapsToItsSheetName() throws {
        let items = try Self.items()
        #expect(items.count == 21, "the sheet's item rows")
        let english = Set(items.map(\.0))
        #expect(english.count == items.count, "one row per item")
        // The sheet's items are the ones the recognizers save.
        #expect(english == GameText.levelledItems.union(GameText.unlevelledItems))
        for (language, column) in Self.columns {
            let table = try #require(GameItemNames.names[language])
            #expect(Set(table.keys) == english, "\(language): no item missing, none extra")
            for (item, cells) in items {
                let sheetName = cells[column].trimmingCharacters(in: .whitespaces)
                #expect(!sheetName.isEmpty, "\(language) \(item): the sheet has a name")
                #expect(GameLanguage.itemName(item, shownIn: language) == sheetName, "\(language) \(item)")
            }
            // Exactly one: no two items share a shown name.
            let shown = english.map { GameLanguage.itemName($0, shownIn: language) }
            #expect(Set(shown).count == english.count, "\(language): names are distinct")
        }
    }

    @Test("Names the game leaves in English stay English")
    func englishInTheGame() {
        for item in ["Power Cube", "Portal Key", "Hypercube"] {
            #expect(GameLanguage.itemName(item, shownIn: .simplifiedChinese) == item)
        }
        #expect(GameLanguage.itemName("Capsule", shownIn: .traditionalChinese) == "Capsule")
        #expect(GameLanguage.itemName("Resonator", shownIn: .simplifiedChinese) == "共振器")
        #expect(GameLanguage.itemName("XMP Burster", shownIn: .japanese) == "XMPバースター")
        #expect(GameLanguage.itemName("Portal Key", shownIn: .traditionalChinese) == "能量塔鑰匙")
    }

    @Test("English, Korean and no language show English", arguments: [GameLanguage?.none, .english, .korean])
    func otherLanguagesShowEnglish(_ language: GameLanguage?) {
        for item in GameText.levelledItems.union(GameText.unlevelledItems) {
            #expect(GameLanguage.itemName(item, shownIn: language) == item)
        }
    }

    @Test("A missing or empty name falls back to English")
    func missingFallsBack() {
        #expect(GameItemNames.name("Resonator", in: [:]) == "Resonator")
        #expect(GameItemNames.name("Resonator", in: ["Resonator": ""]) == "Resonator")
        for language in [GameLanguage.simplifiedChinese, .traditionalChinese, .japanese] {
            #expect(GameLanguage.itemName("Some New Item", shownIn: language) == "Some New Item")
        }
    }

    @Test("Each shown name reads back as its item", arguments: [GameLanguage.simplifiedChinese, .traditionalChinese, .japanese])
    func shownNamesReadBack(_ language: GameLanguage) {
        let text = GameText(language)
        for item in GameText.levelledItems.union(GameText.unlevelledItems) {
            #expect(text.item(named: GameLanguage.itemName(item, shownIn: language)) == item, "\(language) \(item)")
        }
    }

    // MARK: Which language: chosen, else detected, else English

    @Test("A language chosen in Settings wins over the one found",
          arguments: GameLanguage.allCases, [GameLanguage?.none, .simplifiedChinese, .traditionalChinese, .japanese, .korean, .english])
    func chosenWins(_ chosen: GameLanguage, _ detected: GameLanguage?) {
        #expect(GameLanguage.itemNameLanguage(chosen: chosen, detected: detected) == chosen)
    }

    @Test("Automatic follows the language found", arguments: GameLanguage.allCases)
    func automaticFollowsDetected(_ detected: GameLanguage) {
        #expect(GameLanguage.itemNameLanguage(chosen: nil, detected: detected) == detected)
    }

    @Test("Automatic with nothing found shows English")
    func automaticWithoutDetectionIsEnglish() {
        let language = GameLanguage.itemNameLanguage(chosen: nil, detected: nil)
        #expect(language == nil)
        #expect(GameLanguage.itemName("Resonator", shownIn: language) == "Resonator")
    }

    @Test("Automatic shows the found game's names",
          arguments: [(GameLanguage.simplifiedChinese, "共振器"), (.traditionalChinese, "共振器"), (.japanese, "レゾネーター"),
                      (.korean, "Resonator"), (.english, "Resonator")])
    func automaticNames(_ detected: GameLanguage, _ resonator: String) {
        let language = GameLanguage.itemNameLanguage(chosen: nil, detected: detected)
        #expect(GameLanguage.itemName("Resonator", shownIn: language) == resonator)
    }

    // MARK: VoiceOver labels of the item chips

    @Test("A chip's VoiceOver label reads the count and the name as shown",
          arguments: [(GameLanguage?.none, "7 XMP Burster"), (.english, "7 XMP Burster"), (.korean, "7 XMP Burster"),
                      (.simplifiedChinese, "7 XMP 能量炮"), (.traditionalChinese, "7 XMP 能量炮"), (.japanese, "7 XMPバースター")])
    func chipLabel(_ language: GameLanguage?, _ expected: String) {
        #expect(GameLanguage.itemCountLabel(7, "XMP Burster", shownIn: language) == expected)
    }

    @Test("Every chip label matches the visible name", arguments: [GameLanguage?.none, .simplifiedChinese, .traditionalChinese, .japanese])
    func chipLabelsMatchNames(_ language: GameLanguage?) {
        for item in GameText.levelledItems.union(GameText.unlevelledItems) {
            #expect(GameLanguage.itemCountLabel(3, item, shownIn: language) == "3 " + GameLanguage.itemName(item, shownIn: language))
        }
    }

    @Test("A chip label for an unknown item or English-kept name stays English")
    func chipLabelFallback() {
        #expect(GameLanguage.itemCountLabel(2, "Some New Item", shownIn: .japanese) == "2 Some New Item")
        #expect(GameLanguage.itemCountLabel(1, "Heat Sink", shownIn: .simplifiedChinese) == "1 Heat Sink")
    }
}
