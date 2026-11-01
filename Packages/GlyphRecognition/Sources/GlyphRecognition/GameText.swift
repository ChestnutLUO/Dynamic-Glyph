import Foundation

/// The language Ingress shows, set by the player: the game has its own
/// language setting, independent of the iPhone's.
public enum GameLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"

    /// Checked against a recording of the game in this language. The others
    /// come from the player's sheet alone and may need corrections.
    public var isRecorded: Bool { self == .english || self == .simplifiedChinese || self == .japanese }

    /// Vision's languages, the game's own first. English follows because
    /// both games leave some text in English.
    public var recognitionLanguages: [String] {
        switch self {
        case .english: return ["en-US"]
        case .simplifiedChinese: return ["zh-Hans", "en-US"]
        case .traditionalChinese: return ["zh-Hant", "en-US"]
        case .japanese: return ["ja-JP", "en-US"]
        case .korean: return ["ko-KR", "en-US"]
        }
    }

    /// The language's own name, as a language menu shows it.
    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    /// Vision's fast recognition reads Latin script only.
    public var needsAccurateRecognition: Bool { self != .english }

    /// The lowest recognition confidence each kind of text needs. Vision
    /// reports Chinese, Japanese and Korean text at coarse levels, 0.3, 0.5
    /// or 1, even when every character is right, so their floors sit on those
    /// levels. Exact phrases, and two agreeing reads of item rows, remain the
    /// guard against misreads.
    public struct Confidence: Sendable, Equatable {
        /// An item row, a result label or percentage.
        public let line: Double
        /// A panel title.
        public let title: Double
        /// A notice box, and the drone footer.
        public let notice: Double
        /// One read of a notice clear enough to stand alone.
        public let clearNotice: Double
        public let header: Double
    }

    public var confidence: Confidence {
        self == .english
            ? Confidence(line: 0.5, title: 0.7, notice: 0.8, clearNotice: 0.95, header: 0.35)
            : Confidence(line: 0.3, title: 0.5, notice: 0.5, clearNotice: 0.5, header: 0.3)
    }
}

/// Every game phrase the recognizers match, for one game language, from the
/// player's sheet and recordings (Docs/GAME_TEXT_TRANSLATIONS_ALL.csv).
/// Matching is exact after `GameText.normalized`: case, spaces and
/// punctuation don't count, and nothing is matched loosely.
public struct GameText: Sendable {
    public let language: GameLanguage
    private let packs: [Pack]

    public init(_ language: GameLanguage = .english) {
        self.language = language
        // The game's own text first; English remains, as both games keep some.
        packs = language == .english ? [.english] : [Pack.of(language), .english]
    }

    /// Lowercased letters and digits only. Kana, kanji and hanzi are letters,
    /// as is the long-vowel mark "ー".
    public static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Headers, notices, result labels

    public var headerPhrases: [HeaderPhraseMatcher.Phrase] { packs.flatMap(\.headers) }

    /// The notice and the language it was read in.
    public func notice(_ text: String) -> (notice: CommandNoticeReading.Notice, language: String)? {
        let key = Self.normalized(text)
        for pack in packs { if let notice = pack.notices[key] { return (notice, pack.code) } }
        return nil
    }

    public func isDroneFooter(_ text: String) -> Bool {
        let key = Self.normalized(text)
        return packs.contains { $0.droneFooter == key }
    }

    public func isHackingLabel(_ text: String) -> Bool {
        let key = Self.normalized(text)
        return packs.contains { $0.hackingLabel == key }
    }

    /// The language whose own Hacking Bonus label this is.
    public func hackingLabelLanguage(_ text: String) -> GameLanguage? {
        let key = Self.normalized(text)
        return packs.first { $0.hackingLabel == key }.flatMap { GameLanguage(rawValue: $0.code) }
    }

    /// The language whose own Bonus title this is.
    public func bonusTitleLanguage(_ text: String) -> GameLanguage? {
        let key = Self.normalized(text)
        return packs.first { $0.bonusTitle == key }.flatMap { GameLanguage(rawValue: $0.code) }
    }

    public func isSpeedLabel(_ text: String) -> Bool {
        let key = Self.normalized(text)
        return packs.contains { $0.speedLabel == key }
    }

    // MARK: - Gear panels

    public enum Title: Equatable, Sendable { case bonus, bounty, unsupported, message, other }

    /// A panel title. Another game language's Bonus title is `unsupported`,
    /// not a portal name; a cooldown or scanner message is `message`.
    public func title(_ text: String) -> Title {
        let key = Self.normalized(text)
        if packs.contains(where: { $0.bonusTitle == key }) { return .bonus }
        if packs.contains(where: { $0.bountyTitle == key }) { return .bounty }
        if Self.otherBonusTitles.contains(key) { return .unsupported }
        if packs.contains(where: { pack in pack.messageFragments.contains(where: key.contains) }) { return .message }
        return .other
    }

    /// Bonus titles of game languages without a pack yet.
    private static let otherBonusTitles: Set<String> = Set(
        GameLanguage.allCases.map { normalized(Pack.of($0).bonusTitle) })

    /// The effect a line says was applied, such as "ITO EN (+)". The sign
    /// must be read: an effect line without one is not an effect.
    public func effect(_ text: String) -> String? {
        var value = Self.compactTransmuter(text)
        while let last = value.last, last == "." || last == "。" { value.removeLast() }
        // "…applied" in most languages; "已使用…" leads in Traditional Chinese.
        if let suffix = packs.lazy.flatMap(\.effectSuffixes).first(where: value.hasSuffix) {
            value = String(value.dropLast(suffix.count))
        } else if let prefix = packs.lazy.flatMap(\.effectPrefixes).first(where: value.hasPrefix) {
            value = String(value.dropFirst(prefix.count))
        } else { return nil }
        switch value {
        case "itoen(+)", "itoentransmuter(+)": return "ITO EN (+)"
        case "itoen(-)", "itoentransmuter(-)": return "ITO EN (-)"
        default: return nil
        }
    }

    /// The English item a panel row names. A name ending in "…" or "...", or
    /// `clipped` at its column's edge, is its start: it counts only if that
    /// start begins exactly one item's name and is long enough to tell.
    public func item(named name: String, clipped: Bool = false) -> String? {
        if let transmuter = Self.transmuter(name) { return transmuter }
        var shown = name.trimmingCharacters(in: .whitespaces)
        let ellipsis = shown.hasSuffix("…") || shown.hasSuffix("...")
        if shown.hasSuffix("…") { shown.removeLast() } else if shown.hasSuffix("...") { shown.removeLast(3) }
        // A mark left inside is garbled text, not a shortened name.
        guard !shown.contains("…"), !shown.contains(".") else { return nil }
        let key = Self.normalized(shown)
        guard !key.isEmpty else { return nil }
        if !ellipsis, let item = packs.lazy.compactMap({ $0.items[key] }).first { return item }
        // Japanese panels drop a name's last word when it doesn't fit:
        // "Aegis" for Aegis シールド. Whole opening words must name one item.
        // Only a row that stops short of its column's edge: at the edge the
        // cut may fall inside a word, as it would in ポータルキー.
        if !ellipsis, !clipped, language != .english {
            let items = Set(packs.flatMap { $0.leadingWords[key] ?? [] })
            // A one-word name can't lose a word, so ポータル is the shield,
            // never ポータルキー.
            if items.count == 1, let item = items.first { return item }
        }
        guard ellipsis || clipped else { return nil }
        // Both transmuters share every start without their sign, so their
        // names are never candidates here.
        let candidates = Set(packs.flatMap { pack in
            pack.items.filter { name, _ in name.hasPrefix(key) && name.count > key.count }.map { ($0.value) }
        })
        guard candidates.count == 1, let item = candidates.first,
              let full = packs.lazy.compactMap({ pack in
                  pack.items.first { $0.value == item && $0.key.hasPrefix(key) }?.key }).first,
              key.count >= 3, Double(key.count) >= Double(full.count) * 0.5 else { return nil }
        return item
    }

    public static let levelledItems: Set<String> = ["Resonator", "XMP Burster", "Power Cube", "Ultra Strike"]
    public static let unlevelledItems: Set<String> = ["Portal Key", "Portal Shield", "Turret", "Link Amp",
        "Multi-Hack", "JARVIS Virus", "Heat Sink", "Kinetic Capsule", "Hypercube", "Force Amp",
        "ADA Refactor", "Aegis Shield", "SoftBank Ultra Link", "Capsule", "Media",
        "ITO EN Transmuter (+)", "ITO EN Transmuter (-)"]

    /// Transmuters are named alike in every language; only the sign tells
    /// them apart, so it is compared with the name, not stripped. A drop row
    /// shows the short name, "ITO EN (-)", as the effect line does.
    private static func transmuter(_ name: String) -> String? {
        switch compactTransmuter(name) {
        case "itoentransmuter(+)", "itoen(+)": return "ITO EN Transmuter (+)"
        case "itoentransmuter(-)", "itoen(-)": return "ITO EN Transmuter (-)"
        default: return nil
        }
    }

    static func compactTransmuter(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace }.map { character -> Character in
            switch character {
            // Minus signs and the dashes OCR reads one as.
            case "−", "－", "–", "—", "‐": return "-"
            case "＋": return "+"
            case "（": return "("
            case "）": return ")"
            default: return character
            }
        })
    }

    // MARK: - Packs

    private struct Pack: Sendable {
        let code: String
        let headers: [HeaderPhraseMatcher.Phrase]
        /// Normalized notice text.
        let notices: [String: CommandNoticeReading.Notice]
        let droneFooter: String
        let hackingLabel: String
        let speedLabel: String
        let bonusTitle: String
        let bountyTitle: String
        /// Parts of the messages shown in a panel instead of drops.
        let messageFragments: [String]
        /// Normalized, after the effect's name: "applied", "已应用".
        let effectSuffixes: [String]
        /// Before the effect's name, where the language puts it first.
        var effectPrefixes: [String] = []
        /// Normalized shown name to English item; transmuters are separate.
        let items: [String: String]
        /// A multi-word name's opening words, normalized, to its item.
        var leadingWords: [String: Set<String>] = [:]

        static func of(_ language: GameLanguage) -> Pack {
            switch language {
            case .english: return .english
            case .simplifiedChinese: return .simplifiedChinese
            case .traditionalChinese: return .traditionalChinese
            case .japanese: return .japanese
            case .korean: return .korean
            }
        }

        static func table(_ names: [(String, String)]) -> [String: String] {
            Dictionary(names.map { (GameText.normalized($0.0), $0.1) }, uniquingKeysWith: { first, _ in first })
        }

        /// The opening words of each multi-word name: "ポータル" for
        /// ポータル シールド. A single-word name has none.
        static func leading(_ names: [(String, String)]) -> [String: Set<String>] {
            var result: [String: Set<String>] = [:]
            for (shown, item) in names {
                let words = shown.split(whereSeparator: \.isWhitespace).map(String.init)
                guard words.count > 1 else { continue }
                for count in 1..<words.count {
                    result[GameText.normalized(words.prefix(count).joined()), default: []].insert(item)
                }
            }
            return result
        }

        static let english = Pack(
            code: "en",
            headers: [
                .init(phase: .command, words: ["command", "channel", "open"]),
                .init(phase: .presenting, words: ["incoming", "glyph", "sequence"]),
                .init(phase: .completed, words: ["glyph", "hack", "complete"]),
                // "GO!" is two characters. Anything less strict than a whole-header
                // match would classify stray map text as the input phase.
                .init(phase: .input, words: ["go"], requiresExactMatch: true),
            ],
            notices: ["simplehack": .simple, "complexhack": .complex, "requestkey": .requestKey,
                      "nokey": .noKey, "onlykey": .keysOnly, "invalidcommand": .invalid],
            droneFooter: "dronefootage", hackingLabel: "hackingbonus", speedLabel: "speedbonus",
            bonusTitle: "bonusitems", bountyTitle: "bountyclaimed",
            messageFragments: ["bonus", "bounty", "claimed", "hacking", "speed", "cooldown", "scanner", "portalnot"],
            effectSuffixes: ["applied"],
            items: table((levelledItems.union(unlevelledItems)).filter { !$0.hasPrefix("ITO EN") }.map { ($0, $0) }))

        // Recorded on 2026-09-25 and 2026-09-29: notices, drone footer, result
        // labels, Bonus title and ten item names. The headers, the other
        // messages and the remaining names come from the player's sheet only.
        static let simplifiedChineseNames: [(String, String)] = [
                ("共振器", "Resonator"), ("XMP 能量炮", "XMP Burster"), ("破甲弹", "Ultra Strike"),
                ("能量塔护盾", "Portal Shield"), ("埃癸斯盾", "Aegis Shield"), ("多次入侵模组", "Multi-Hack"),
                ("SoftBank 超连结", "SoftBank Ultra Link"), ("储存胶囊", "Capsule"),
                ("动能储存胶囊", "Kinetic Capsule"), ("媒体", "Media"),
            ]

        static let simplifiedChinese = Pack(
            code: "zh-Hans",
            headers: [
                .init(phase: .command, words: ["命令频道"], matchesWithin: true),
                .init(phase: .presenting, words: ["接收符文序列"], matchesWithin: true),
                .init(phase: .completed, words: ["符文入侵完成"], matchesWithin: true),
                .init(phase: .input, words: ["开始"], requiresExactMatch: true),
            ],
            notices: ["简单入侵": .simple, "复杂入侵": .complex, "请求钥匙": .requestKey,
                      "没有钥匙": .noKey, "只有钥匙": .keysOnly, "指令无效": .invalid],
            droneFooter: "遥控机画面", hackingLabel: "入侵奖励", speedLabel: "速度奖励",
            bonusTitle: "奖励物品", bountyTitle: "已申领小目标",
            messageFragments: ["过热", "冷却", "扫描器", "不在行动范围"],
            effectSuffixes: ["已应用"],
            items: table(simplifiedChineseNames), leadingWords: leading(simplifiedChineseNames))

        // Recorded on 2026-09-29: notices except SIMPLE and INVALID, drone
        // footer, result labels, Bonus title, the cooldown message and eight
        // item names. The rest comes from the player's sheet only.
        static let japaneseNames: [(String, String)] = [
                ("レゾネーター", "Resonator"), ("XMPバースター", "XMP Burster"), ("ウルトラ ストライク", "Ultra Strike"),
                ("パワーキューブ", "Power Cube"), ("ポータル シールド", "Portal Shield"), ("Aegis シールド", "Aegis Shield"),
                ("ターレット", "Turret"), ("フォースアンプ", "Force Amp"), ("ヒートシンク", "Heat Sink"),
                ("マルチハック", "Multi-Hack"), ("リンクアンプ", "Link Amp"), ("SoftBank ウルトラリンク", "SoftBank Ultra Link"),
                ("ポータルキー", "Portal Key"), ("ハイパーキューブ", "Hypercube"), ("ADA リファクター", "ADA Refactor"),
                ("ジャービス ウイルス", "JARVIS Virus"), ("カプセル", "Capsule"), ("キネティックカプセル", "Kinetic Capsule"),
                ("メディア", "Media"),
            ]

        static let japanese = Pack(
            code: "ja",
            headers: [
                .init(phase: .command, words: ["コマンドチャンネル"], matchesWithin: true),
                .init(phase: .presenting, words: ["グリフを受信中"], matchesWithin: true),
                .init(phase: .completed, words: ["ハック完了"], matchesWithin: true),
            ],
            notices: ["simpleハック": .simple, "complexハック": .complex, "ポータルキーを要求": .requestKey,
                      "キーのみ": .keysOnly, "無効なコマンド": .invalid],
            droneFooter: "ドローンの映像", hackingLabel: "hackbonus", speedLabel: "speedbonus",
            bonusTitle: "ボーナスアイテム", bountyTitle: "依頼完了",
            messageFragments: ["ヒート状態", "クールダウン", "スキャナー", "有効範囲外"],
            effectSuffixes: ["を適用しました"],
            items: table(japaneseNames), leadingWords: leading(japaneseNames))

        // From the player's sheet only; no recording yet. The sheet gives
        // 能量塔鑰匙 for Portal Key, which may be the inventory's name: English
        // "Portal Key" still matches.
        static let traditionalChineseNames: [(String, String)] = [
                ("共振器", "Resonator"), ("XMP 能量炮", "XMP Burster"), ("破甲彈", "Ultra Strike"),
                ("能量塔護盾", "Portal Shield"), ("埃癸斯盾", "Aegis Shield"), ("多次入侵模組", "Multi-Hack"),
                ("SoftBank 超連線", "SoftBank Ultra Link"), ("能量塔鑰匙", "Portal Key"),
                ("動能儲存膠囊", "Kinetic Capsule"), ("媒體", "Media"),
            ]

        static let traditionalChinese = Pack(
            code: "zh-Hant",
            headers: [
                .init(phase: .command, words: ["指令頻道"], matchesWithin: true),
                .init(phase: .presenting, words: ["接收glyph序列"], matchesWithin: true),
                .init(phase: .completed, words: ["符文入侵完成"], matchesWithin: true),
            ],
            notices: ["簡單入侵": .simple, "複雜入侵": .complex, "請求鑰匙": .requestKey,
                      "沒有鑰匙": .noKey, "僅獲取鑰匙": .keysOnly, "指令無效": .invalid],
            droneFooter: "遙控機畫面", hackingLabel: "入侵獎勵", speedLabel: "速度獎勵",
            bonusTitle: "獎勵物品", bountyTitle: "已申領小目標",
            messageFragments: ["過熱", "冷卻", "掃描器", "不在行動範圍"],
            effectSuffixes: [], effectPrefixes: ["已使用"],
            items: table(traditionalChineseNames), leadingWords: leading(traditionalChineseNames))

        // From the player's sheet only; no recording yet. The sheet spells
        // 쉴드 for Portal Shield and 실드 for Aegis Shield, as given.
        static let koreanNames: [(String, String)] = [
                ("레저네이터", "Resonator"), ("XMP 버스터", "XMP Burster"), ("울트라 스트라이크", "Ultra Strike"),
                ("파워 큐브", "Power Cube"), ("포탈 쉴드", "Portal Shield"), ("이지스 실드", "Aegis Shield"),
                ("터렛", "Turret"), ("포스 앰프", "Force Amp"), ("히트 싱크", "Heat Sink"),
                ("멀티핵", "Multi-Hack"), ("링크 앰프", "Link Amp"), ("SoftBank 울트라 링크", "SoftBank Ultra Link"),
                ("포탈 키", "Portal Key"), ("하이퍼 큐브", "Hypercube"), ("ADA 리팩터", "ADA Refactor"),
                ("자비스 바이러스", "JARVIS Virus"), ("캡슐", "Capsule"), ("키네틱 캡슐", "Kinetic Capsule"),
                ("미디어", "Media"),
            ]

        static let korean = Pack(
            code: "ko",
            headers: [
                .init(phase: .command, words: ["명령채널"], matchesWithin: true),
                .init(phase: .presenting, words: ["글리프시퀀스"], matchesWithin: true),
                .init(phase: .completed, words: ["해킹완료"], matchesWithin: true),
            ],
            notices: ["간단한해킹": .simple, "복잡한해킹": .complex, "키요청": .requestKey,
                      "키없음": .noKey, "키만": .keysOnly, "잘못된명령": .invalid],
            droneFooter: "드론화면", hackingLabel: "해킹보너스", speedLabel: "속도보너스",
            bonusTitle: "보너스아이템", bountyTitle: "현상금완료",
            messageFragments: ["과열", "냉각", "스캐너", "범위벗어남"],
            effectSuffixes: ["이(가)적용되었습니다"],
            items: table(koreanNames), leadingWords: leading(koreanNames))
    }
}
