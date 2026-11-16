import Foundation
import Testing
import GlyphRecognitionCxx
@testable import GlyphRecognition

/// The C++ text functions (`gc_normalize`, `gc_compact_transmuter` and the
/// Character count behind the matchers) held to Swift's `GameText.normalized`,
/// `compactTransmuter` and `String.count`, byte for byte: on every Unicode
/// scalar, on every string the oracle tests read, and on seeded random
/// strings built to exercise grapheme clusters.
@Suite("C++ text: normalization and Characters")
struct CxxTextTests {
    /// UTF-8 equality, not Swift's canonical `==`.
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    static func hex(_ text: String) -> String {
        text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    @Test("Every scalar normalizes and compacts as in Swift", arguments: Array(0..<17))
    func everyScalar(plane: Int) {
        var checked = 0
        var mismatches: [String] = []
        for value in UInt32(plane << 16)..<UInt32((plane + 1) << 16) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(Character(scalar))
            checked += 1
            if !Self.same(GameText.normalized(text), CxxText.normalized(text)) {
                mismatches.append(String(format: "normalized %04X", value))
            }
            if !Self.same(GameText.compactTransmuter(text), CxxText.compactTransmuter(text)) {
                mismatches.append(String(format: "compact %04X", value))
            }
        }
        #expect(checked == (plane == 0 ? 0x10000 - 0x800 : 0x10000))
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(20))")
    }

    /// Every string the pace area's oracle tests read, plus the phrase packs.
    static var oracleStrings: [String] {
        var strings = [
            "简单入侵", "复杂入侵", "请求钥匙", "没有钥匙", "只有钥匙", "指令无效", "遥控机画面", "入侵奖励：", "速度奖励：",
            "簡單入侵", "複雜入侵", "請求鑰匙", "沒有鑰匙", "僅獲取鑰匙", "指令無效", "遙控機畫面", "入侵獎勵：", "速度獎勵：",
            "SIMPLE ハック", "COMPLEX ハック", "ポータルキーを要求", "NO KEY", "キーのみ", "無効なコマンド", "ドローンの映像",
            "HACK BONUS:", "SPEED BONUS:", "간단한 해킹", "복잡한 해킹", "키 요청", "키 없음", "키만", "잘못된 명령", "드론 화면",
            "해킹 보너스:", "속도 보너스:", "REQUEST KEY", "奖励物品：", "已申领小目标", "能量塔过热。尚需12秒冷却。", "Bonus items:",
            "奖励物品:", "ボーナス アイテム:", "ボーナスアイテム：", "依頼完了", "ポータルはまだヒート状態です。クールダウンまで残り30秒",
            "Test location", "獎勵物品：", "보너스 아이템:", "ITO EN Transmuter (+) 已应用。", "已使用 ITO EN Transmuter (-)。",
            "ITO EN Transmuter（+）を適用しました。", "ITO EN Transmuter (-)이(가) 적용되었습니다.", "ITO EN Transmuter を適用しました。",
            "ITO EN (+) applied.", "XMP 能量炮", "动能储存胶囊", "Power Cube", "Jarvis Virus", "XMPバースター", "Aegisシールド",
            "ポータル シールド", "能量塔鑰匙", "Portal Key", "포탈 쉴드", "이지스 실드", "Aegis", "ポータル", "Kinetic", "XMPバースタ",
            "パワーキュー", "ポータ", "キネティック…", "动能储存…", "储存…", "ITO EN Transm…", "ITO EN (-)", "ITO EN (+)",
            "ITO EN (–)", "ITO EN（-）", "ITO EN ()", "ITO EN", "ITO EN (", "ITO EN Transmuter", "复杂入侵", "COMPLEX HACK",
            "NO KEY EXTRA", "ONLY", "SPEED", "REQUEST KEV", "DRONE FOOTAGE", "L8", "B1gHack3r", "l6 A", "I7", "18", "L 5",
            "TidepoolL..", "A L4", "k3r 9", "L9", "L0", "x8", "L88", "L7", "17", "L8 L8", "L1", "MOVE RECALL", "HACKING BONUS:",
            "命令频道正在打开…", "正在接收符文序列…", "开始！", "符文入侵完成", "開啟指令頻道…", "正在接收 GLYPH 序列…",
            "コマンドチャンネルを開いています...", "グリフを受信中…", "Go!", "ハック完了。ボーナスを計算中…", "명령 채널 열림…",
            "해킹 완료. 보너스 계산 중...", "开始 Glyph Hack", "L6 x1 XMPバースタ", "L5 x2 XMPバースタ", "L5 x1 レゾネーター",
            "120%", "70%", "zh-Hant-TW", "zh-Hans-CN", "fr-FR", "ja-JP", "en",
        ]
        for language in GameLanguage.allCases {
            for table in GameText(language).tables {
                strings += Array(table.notices.keys) + Array(table.items.keys) + Array(table.items.values)
                strings += Array(table.leadingWords.keys) + table.messageFragments + table.effectSuffixes
                strings += table.effectPrefixes
                strings += [table.droneFooter, table.hackingLabel, table.speedLabel, table.bonusTitle, table.bountyTitle]
            }
        }
        return strings
    }

    @Test("Every string the oracle tests read normalizes, compacts and counts as in Swift")
    func oracleStringsMatch() {
        for text in Self.oracleStrings {
            #expect(Self.same(GameText.normalized(text), CxxText.normalized(text)), "\(text)")
            #expect(Self.same(GameText.compactTransmuter(text), CxxText.compactTransmuter(text)), "\(text)")
            #expect(text.count == CxxText.characterCount(text), "\(text)")
        }
    }

    /// Scalars that exercise every grapheme rule and every special case of
    /// the two functions, beside random scalars from the whole code space.
    static let interesting: [UInt32] = [
        0x41, 0x61, 0x5A, 0x30, 0x39, 0x20, 0x09, 0x0A, 0x0D, 0x01, 0x7F, 0x85, 0xA0, 0x2E, 0x2D, 0x2B, 0x28, 0x29,
        0x4C, 0x6C, 0x49, 0x7C, 0x5E, 0x31, 0x38,
        0x130, 0x3A3, 0x3C2, 0xDF, 0x1E9E, 0x1F88, 0x2C2F, 0xC5, 0xE9, 0xFB01,
        0x300, 0x301, 0x308, 0x316, 0x345, 0x5B0, 0x903, 0x93C, 0x94D, 0x915, 0x937, 0x924, 0x9CD, 0x995, 0xD4E, 0xD15,
        0x600, 0x605, 0x110BD, 0x200C, 0x200D, 0xFE0F, 0x20E3,
        0x1100, 0x1161, 0x11A8, 0xAC00, 0xAC01, 0xD7A3, 0xA960, 0xD7B0, 0xD7CB,
        0x1F600, 0x1F3FB, 0x1F1E6, 0x1F1EF, 0x1F1F5, 0x2764, 0x1F468, 0x1F469,
        0x30DD, 0x30DB, 0x309A, 0x3099, 0x30FC, 0xFF8A, 0xFF9E, 0xFF9F, 0x3000, 0x3002, 0x2026, 0xFF0E,
        0xF91D, 0x6B04, 0x2F800, 0x4E00, 0x516B, 0x2460, 0x663, 0x2167,
        0x2212, 0xFF0D, 0x2013, 0x2014, 0x2010, 0xFF0B, 0xFF08, 0xFF09, 0x2003, 0x2028, 0x1680, 0xFEFF, 0xAD,
        0xFFFD, 0xFDD0, 0xE000, 0xE0001, 0xE0020, 0x10FFFF,
    ]

    /// A seeded random string of `length` scalars.
    static func randomString(_ random: inout PaceRandom, length: Int) -> String {
        var view = String.UnicodeScalarView()
        for _ in 0..<length {
            if random.below(4) == 0 {
                var value: UInt32
                repeat { value = UInt32(random.below(0x110000)) } while (0xD800...0xDFFF).contains(value)
                view.append(Unicode.Scalar(value)!)
            } else {
                view.append(Unicode.Scalar(interesting[random.below(interesting.count)])!)
            }
        }
        return String(view)
    }

    @Test("Random strings with clusters of every kind normalize, compact and count as in Swift",
          arguments: [1, 2, 3] as [UInt64])
    func randomStrings(seed: UInt64) {
        var random = PaceRandom(seed: seed)
        var mismatches: [String] = []
        for _ in 0..<40_000 {
            let text = Self.randomString(&random, length: 1 + random.below(8))
            if !Self.same(GameText.normalized(text), CxxText.normalized(text)) { mismatches.append("n \(Self.hex(text))") }
            if !Self.same(GameText.compactTransmuter(text), CxxText.compactTransmuter(text)) {
                mismatches.append("c \(Self.hex(text))")
            }
            if text.count != CxxText.characterCount(text) { mismatches.append("count \(Self.hex(text))") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(20))")
    }

    @Test("The grapheme rule found in Swift: a cluster is kept or dropped whole, by its first scalar")
    func clusterRule() {
        // Kept with its accent; dropped with the space; U+FF9F is a letter
        // alone but not after a space; U+0130 lowercases to two scalars.
        for text in ["e\u{301}x", " \u{301}x", "\u{FF9F}", " \u{FF9F}", "\u{130}", "ΑΣ", "a\u{200D}\u{1F600}",
                     "1\u{20E3}", "\r\n", "\u{600}a", "\u{915}\u{94D}\u{937}", "\u{1100}\u{1161}\u{11A8}",
                     "−\n\u{301}", "ITO EN (−\u{301})"] {
            #expect(Self.same(GameText.normalized(text), CxxText.normalized(text)), "\(Self.hex(text))")
            #expect(Self.same(GameText.compactTransmuter(text), CxxText.compactTransmuter(text)), "\(Self.hex(text))")
            #expect(text.count == CxxText.characterCount(text), "\(Self.hex(text))")
        }
        #expect(Self.same(CxxText.normalized("e\u{301}x"), "e\u{301}x"))
        #expect(Self.same(CxxText.normalized(" \u{301}x"), "x"))
        #expect(Self.same(CxxText.normalized("ΑΣ"), "ασ"), "no final sigma")
    }
}

/// SplitMix64: the seeded generator of the pace area's randomized tests.
struct PaceRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<bound.
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }

    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }

    /// Uniform in range.
    mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }

    mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
}
