import Foundation

/// Item names as the game shows them, for display only. Saved records,
/// statistics and exports keep the English name (`GearDropEntry.item`); a
/// view turns it into the game's name at the last moment.
///
/// Taken verbatim from a community translation sheet, including the names
/// the game leaves in English, such as Power Cube in Chinese. Kept apart from
/// `GameText`'s tables, which are normalized for matching and leave out the
/// names English already matches.
extension GameLanguage {
    /// The name the game shows for `item`, an English item name as saved,
    /// in `language` (see `itemNameLanguage`). Only Chinese and Japanese
    /// have their own names; English, Korean and nil show English, as does
    /// any item the table doesn't name.
    public static func itemName(_ item: String, shownIn language: GameLanguage?) -> String {
        guard let language, let names = GameItemNames.names[language] else { return item }
        return GameItemNames.name(item, in: names)
    }

    /// The language item names are shown in: the one chosen in Settings, or
    /// on Automatic (nil) the one automatic reading last found; nil, so
    /// English, when none was found. Never the iPhone's language: that is
    /// only where reading starts, not what the game shows.
    public static func itemNameLanguage(chosen: GameLanguage?, detected: GameLanguage?) -> GameLanguage? {
        chosen ?? detected
    }

    /// What VoiceOver reads for an item count, with the name as shown:
    /// "7 共振器".
    public static func itemCountLabel(_ total: Int, _ item: String, shownIn language: GameLanguage?) -> String {
        "\(total) \(itemName(item, shownIn: language))"
    }
}

enum GameItemNames {
    /// The languages with their own names: English item to the game's name.
    static let names: [GameLanguage: [String: String]] = [
        .simplifiedChinese: simplifiedChinese,
        .traditionalChinese: traditionalChinese,
        .japanese: japanese,
    ]

    /// English when the table has no name, or an empty one, for `item`.
    static func name(_ item: String, in table: [String: String]) -> String {
        guard let name = table[item], !name.isEmpty else { return item }
        return name
    }

    static let simplifiedChinese: [String: String] = [
        "Resonator": "共振器", "XMP Burster": "XMP 能量炮", "Ultra Strike": "破甲弹", "Power Cube": "Power Cube",
        "Portal Shield": "能量塔护盾", "Aegis Shield": "埃癸斯盾", "Turret": "Turret", "Force Amp": "Force Amp",
        "Heat Sink": "Heat Sink", "Multi-Hack": "多次入侵模组", "Link Amp": "Link Amp",
        "SoftBank Ultra Link": "SoftBank 超连结",
        "ITO EN Transmuter (+)": "ITO EN Transmuter (+)", "ITO EN Transmuter (-)": "ITO EN Transmuter (-)",
        "Portal Key": "Portal Key", "Hypercube": "Hypercube", "ADA Refactor": "ADA Refactor",
        "JARVIS Virus": "Jarvis Virus", "Capsule": "储存胶囊", "Kinetic Capsule": "动能储存胶囊", "Media": "媒体",
    ]

    static let traditionalChinese: [String: String] = [
        "Resonator": "共振器", "XMP Burster": "XMP 能量炮", "Ultra Strike": "破甲彈", "Power Cube": "Power Cube",
        "Portal Shield": "能量塔護盾", "Aegis Shield": "埃癸斯盾", "Turret": "Turret", "Force Amp": "Force Amp",
        "Heat Sink": "Heat Sink", "Multi-Hack": "多次入侵模組", "Link Amp": "Link Amp",
        "SoftBank Ultra Link": "SoftBank 超連線",
        "ITO EN Transmuter (+)": "ITO EN Transmuter (+)", "ITO EN Transmuter (-)": "ITO EN Transmuter (-)",
        "Portal Key": "能量塔鑰匙", "Hypercube": "Hypercube", "ADA Refactor": "ADA Refactor",
        "JARVIS Virus": "Jarvis Virus", "Capsule": "Capsule", "Kinetic Capsule": "動能儲存膠囊", "Media": "媒體",
    ]

    static let japanese: [String: String] = [
        "Resonator": "レゾネーター", "XMP Burster": "XMPバースター", "Ultra Strike": "ウルトラ ストライク",
        "Power Cube": "パワーキューブ", "Portal Shield": "ポータル シールド", "Aegis Shield": "Aegis シールド",
        "Turret": "ターレット", "Force Amp": "フォースアンプ", "Heat Sink": "ヒートシンク", "Multi-Hack": "マルチハック",
        "Link Amp": "リンクアンプ", "SoftBank Ultra Link": "SoftBank ウルトラリンク",
        "ITO EN Transmuter (+)": "ITO EN Transmuter (+)", "ITO EN Transmuter (-)": "ITO EN Transmuter (-)",
        "Portal Key": "ポータルキー", "Hypercube": "ハイパーキューブ", "ADA Refactor": "ADA リファクター",
        "JARVIS Virus": "ジャービス ウイルス", "Capsule": "カプセル", "Kinetic Capsule": "キネティックカプセル",
        "Media": "メディア",
    ]
}
