import Foundation
import Testing
@testable import GlyphRecognition

@Suite("Game languages")
struct GameTextTests {
    @Test("Each language's notices, drone footer and result labels, with English kept", arguments: [
        (GameLanguage.simplifiedChinese, ["简单入侵", "复杂入侵", "请求钥匙", "没有钥匙", "只有钥匙", "指令无效"],
         "遥控机画面", "入侵奖励：", "速度奖励："),
        (.traditionalChinese, ["簡單入侵", "複雜入侵", "請求鑰匙", "沒有鑰匙", "僅獲取鑰匙", "指令無效"],
         "遙控機畫面", "入侵獎勵：", "速度獎勵："),
        (.japanese, ["SIMPLE ハック", "COMPLEX ハック", "ポータルキーを要求", "NO KEY", "キーのみ", "無効なコマンド"],
         "ドローンの映像", "HACK BONUS:", "SPEED BONUS:"),
        (.korean, ["간단한 해킹", "복잡한 해킹", "키 요청", "키 없음", "키만", "잘못된 명령"],
         "드론 화면", "해킹 보너스:", "속도 보너스:"),
    ])
    func notices(_ sample: (GameLanguage, [String], String, String, String)) {
        let (language, notices, drone, hacking, speed) = sample
        let text = GameText(language)
        let expected: [CommandNoticeReading.Notice] = [.simple, .complex, .requestKey, .noKey, .keysOnly, .invalid]
        #expect(notices.map { text.notice($0)?.notice } == expected)
        #expect(text.notice("REQUEST KEY")?.language == "en", "English stays readable")
        #expect(text.isDroneFooter(drone) && text.isHackingLabel(hacking) && text.isSpeedLabel(speed))
        // Another language's text is not this language's.
        #expect(GameText(.english).notice(notices[0]) == nil || language == .japanese)
    }

    @Test("Panel titles: a Bonus title in a language without its pack is unsupported, not a portal")
    func titles() {
        let chinese = GameText(.simplifiedChinese)
        #expect(chinese.title("奖励物品：") == .bonus && chinese.title("已申领小目标") == .bounty)
        #expect(chinese.title("能量塔过热。尚需12秒冷却。") == .message)
        #expect(chinese.title("Bonus items:") == .bonus)
        #expect(GameText(.english).title("奖励物品:") == .unsupported)
        #expect(GameText(.english).title("ボーナス アイテム:") == .unsupported)
        let japanese = GameText(.japanese)
        #expect(japanese.title("ボーナスアイテム：") == .bonus && japanese.title("依頼完了") == .bounty)
        #expect(japanese.title("ポータルはまだヒート状態です。クールダウンまで残り30秒") == .message)
        #expect(japanese.title("Test location") == .other)
        #expect(GameText(.traditionalChinese).title("獎勵物品：") == .bonus)
        #expect(GameText(.korean).title("보너스 아이템:") == .bonus)
    }

    @Test("Effect lines, in each word order, keep their sign")
    func effects() {
        #expect(GameText(.simplifiedChinese).effect("ITO EN Transmuter (+) 已应用。") == "ITO EN (+)")
        #expect(GameText(.traditionalChinese).effect("已使用 ITO EN Transmuter (-)。") == "ITO EN (-)")
        #expect(GameText(.japanese).effect("ITO EN Transmuter（+）を適用しました。") == "ITO EN (+)")
        #expect(GameText(.korean).effect("ITO EN Transmuter (-)이(가) 적용되었습니다.") == "ITO EN (-)")
        #expect(GameText(.japanese).effect("ITO EN Transmuter を適用しました。") == nil)
        #expect(GameText(.english).effect("ITO EN (+) applied.") == "ITO EN (+)")
    }

    @Test("Headers match within a line in Chinese, Japanese and Korean", arguments: [
        (GameLanguage.simplifiedChinese, "命令频道正在打开…", GamePhase.command),
        (.simplifiedChinese, "正在接收符文序列…", .presenting), (.simplifiedChinese, "开始！", .input),
        (.simplifiedChinese, "符文入侵完成", .completed),
        (.traditionalChinese, "開啟指令頻道…", .command), (.traditionalChinese, "正在接收 GLYPH 序列…", .presenting),
        (.japanese, "コマンドチャンネルを開いています...", .command), (.japanese, "グリフを受信中…", .presenting),
        (.japanese, "Go!", .input), (.japanese, "ハック完了。ボーナスを計算中…", .completed),
        (.korean, "명령 채널 열림…", .command), (.korean, "해킹 완료. 보너스 계산 중...", .completed),
    ])
    func headers(_ sample: (GameLanguage, String, GamePhase)) {
        let reading = HeaderPhraseMatcher(language: sample.0).read(lines: [(sample.1, 1)])
        #expect(reading.phase == sample.2)
        // "开始" alone is the input header; within a longer line it is not.
        if sample.2 == .input {
            #expect(HeaderPhraseMatcher(language: sample.0).read(lines: [("开始 Glyph Hack", 1)]).phase == .unknown)
        }
    }

    @Test("Item names in each language map to the English item", arguments: [
        (GameLanguage.simplifiedChinese, "XMP 能量炮", "XMP Burster"), (.simplifiedChinese, "动能储存胶囊", "Kinetic Capsule"),
        (.simplifiedChinese, "Power Cube", "Power Cube"), (.simplifiedChinese, "Jarvis Virus", "JARVIS Virus"),
        (.japanese, "XMPバースター", "XMP Burster"), (.japanese, "Aegisシールド", "Aegis Shield"),
        (.japanese, "ポータル シールド", "Portal Shield"),
        (.traditionalChinese, "能量塔鑰匙", "Portal Key"), (.traditionalChinese, "Portal Key", "Portal Key"),
        (.korean, "포탈 쉴드", "Portal Shield"), (.korean, "이지스 실드", "Aegis Shield"),
    ])
    func items(_ sample: (GameLanguage, String, String)) {
        #expect(GameText(sample.0).item(named: sample.1) == sample.2)
    }

    @Test("A name cut at its column's edge counts when it starts exactly one item's name")
    func clippedNames() {
        let japanese = GameText(.japanese)
        // Recorded: a two-word name loses its last word, with no "…".
        #expect(japanese.item(named: "Aegis") == "Aegis Shield")
        #expect(japanese.item(named: "ポータル") == "Portal Shield", "ポータルキー is one word")
        #expect(GameText(.english).item(named: "Kinetic") == nil, "English shortens with …")
        #expect(japanese.item(named: "XMPバースタ", clipped: true) == "XMP Burster")
        #expect(japanese.item(named: "パワーキュー", clipped: true) == "Power Cube")
        #expect(japanese.item(named: "パワーキュー") == nil, "Not at the edge: not a shortened name")
        #expect(japanese.item(named: "ポータ", clipped: true) == nil, "Shield or key")
        // At the edge a cut may fall inside a word: ポータル could be ポータルキー.
        #expect(japanese.item(named: "ポータル", clipped: true) == nil)
        #expect(japanese.item(named: "キネティック…") == "Kinetic Capsule")
        #expect(GameText(.simplifiedChinese).item(named: "动能储存…") == "Kinetic Capsule")
        #expect(GameText(.simplifiedChinese).item(named: "储存…") == nil, "Capsule or Kinetic Capsule")
        #expect(japanese.item(named: "ITO EN Transm…") == nil, "The sign is cut off")
        // A drop row's short name keeps its sign, so it names one transmuter.
        let english = GameText(.english)
        #expect(english.item(named: "ITO EN (-)") == "ITO EN Transmuter (-)")
        #expect(english.item(named: "ITO EN (+)") == "ITO EN Transmuter (+)")
        #expect(english.item(named: "ITO EN (–)") == "ITO EN Transmuter (-)", "An en dash read for the minus")
        #expect(japanese.item(named: "ITO EN（-）") == "ITO EN Transmuter (-)")
        for unsigned in ["ITO EN ()", "ITO EN", "ITO EN (", "ITO EN Transmuter"] {
            #expect(english.item(named: unsigned) == nil, "\(unsigned)")
        }
    }

    @Test("A Japanese panel row cut at the column edge is read with its level and quantity")
    func clippedPanelRow() throws {
        let parser = GearDropTextParser(language: .japanese)
        let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.46)
        func line(_ text: String, x: Double, y: Double, width: Double) -> ResultTextLine {
            ResultTextLine(text: text, confidence: 1, x: x, y: y, width: width, height: 0.014)
        }
        let evidence = parser.read(lines: [
            line("ボーナス アイテム:", x: 0.3, y: 0.30, width: 0.4),
            line("L6 x1 XMPバースタ", x: 0.12, y: 0.35, width: 0.35),
            line("L5 x2 XMPバースタ", x: 0.60, y: 0.35, width: 0.34),
            line("L5 x1 レゾネーター", x: 0.12, y: 0.386, width: 0.30),
        ], bounds: bounds, at: 1)
        #expect(evidence.stage == .bonus)
        #expect(evidence.entries.map(\.item) == ["XMP Burster", "XMP Burster", "Resonator"])
        #expect(evidence.entries.map(\.level) == [6, 5, 5])
        #expect(evidence.unreadableRows == 0)
    }

    @Test("Automatic reading tries the other languages at most once per interval and keeps what it finds")
    func languageMemory() {
        final class Changes: @unchecked Sendable {
            let lock = NSLock()
            var values: [GameLanguage] = []
        }
        let changes = Changes()
        let memory = GameLanguageMemory(language: .english, isAutomatic: true, retryInterval: 3) { found in
            changes.lock.withLock { changes.values.append(found) }
        }
        #expect(memory.alternatives(at: 10, on: .result) == [.simplifiedChinese, .traditionalChinese, .japanese, .korean])
        #expect(memory.alternatives(at: 11, on: .result).isEmpty, "An unread screen costs one extra read per interval")
        #expect(!memory.alternatives(at: 11, on: .notice).isEmpty, "Each kind of screen waits on its own")
        #expect(!memory.alternatives(at: 13, on: .result).isEmpty)
        #expect(!memory.isConfirmed)
        memory.found(.english)
        #expect(memory.state.language == .english && memory.state.isConfirmed, "Finding the current language confirms it")
        #expect(changes.lock.withLock { changes.values }.isEmpty, "Confirming isn't a change to remember")
        memory.found(.japanese)
        memory.found(.japanese)
        #expect(memory.current == .japanese && changes.lock.withLock { changes.values } == [.japanese])
        #expect(memory.alternatives(at: 20, on: .panel).contains(.english), "A mistaken find can be corrected")
        let chosen = GameLanguageMemory(language: .korean, isAutomatic: false)
        #expect(chosen.alternatives(at: 10, on: .notice).isEmpty)
        chosen.found(.english)
        #expect(chosen.current == .korean, "A chosen language never changes")
        #expect(!chosen.isConfirmed)
    }

    @Test("A temporary panel reader expires and never changes the saved or chosen game language")
    func temporaryPanelReader() {
        let bounds = GearDropPanelBounds(top: 0.3, bottom: 0.5)
        let memory = GameLanguageMemory(language: .english, isAutomatic: true)
        memory.rememberPanelReading(.japanese, at: 10, bounds: bounds)
        #expect(memory.current == .english)
        #expect(memory.panelReadingLanguage(at: 10.1, bounds: bounds) == .japanese)
        #expect(memory.panelReadingLanguage(at: 16, bounds: bounds) == nil)
        memory.rememberPanelReading(.japanese, at: 20, bounds: bounds)
        #expect(memory.panelReadingLanguage(at: 19, bounds: bounds) == nil)
        memory.rememberPanelReading(.japanese, at: 20, bounds: bounds)
        #expect(memory.panelReadingLanguage(at: 20.1, bounds: .init(top: 0.3, bottom: 0.6)) == nil)
        memory.rememberPanelReading(.japanese, at: 20, bounds: bounds)
        memory.found(.simplifiedChinese)
        #expect(memory.panelReadingLanguage(at: 20.1, bounds: bounds) == nil)
        let chosen = GameLanguageMemory(language: .english, isAutomatic: false)
        chosen.rememberPanelReading(.japanese, at: 1, bounds: bounds)
        #expect(chosen.panelReadingLanguage(at: 1.1, bounds: bounds) == nil && chosen.current == .english)
    }

    @Test("Automatic reading starts from the last language found, else the iPhone's")
    func startingGuess() {
        #expect(GameLanguageMemory.startingGuess(remembered: .korean, preferredLanguages: ["ja-JP"]) == .korean)
        #expect(GameLanguageMemory.startingGuess(remembered: nil, preferredLanguages: ["zh-Hant-TW", "en"]) == .traditionalChinese)
        #expect(GameLanguageMemory.startingGuess(remembered: nil, preferredLanguages: ["zh-Hans-CN"]) == .simplifiedChinese)
        #expect(GameLanguageMemory.startingGuess(remembered: nil, preferredLanguages: ["fr-FR", "ja-JP"]) == .japanese)
        #expect(GameLanguageMemory.startingGuess(remembered: nil, preferredLanguages: ["fr-FR"]) == .english)
    }

    @Test("Chinese, Japanese and Korean reads count at Vision's coarse confidence levels")
    func coarseConfidence() {
        let chinese = CommandNoticeParser(language: .simplifiedChinese).read([("复杂入侵", 0.5)])
        #expect(chinese.notice == .complex && chinese.isClear)
        #expect(CommandNoticeParser(language: .simplifiedChinese).read([("复杂入侵", 0.3)]).notice == nil)
        let english = CommandNoticeParser().read([("COMPLEX HACK", 0.85)])
        #expect(english.notice == .complex && !english.isClear, "English keeps its stricter levels")
        // Japanese keeps NO KEY in English, read at 0.5 like Japanese text:
        // it counts, but needs a second read unless read at English's level.
        let fallback = CommandNoticeParser(language: .japanese).read([("NO KEY", 0.5)])
        #expect(fallback.notice == .noKey && fallback.language == "en" && !fallback.isClear)
        #expect(CommandNoticeParser(language: .japanese).read([("NO KEY", 1)]).isClear)
    }

    @Test("A result page names its language only by that language's own label")
    func resultLabelLanguage() {
        let context = ResultReadContext(sessionID: CaptureSessionID(rawValue: 1), hackID: 1, glyphs: ["xm"])
        func page(_ hacking: String, _ speed: String) -> [ResultTextLine] {
            [ResultTextLine(text: hacking, confidence: 1, x: 0.3, y: 0.33, width: 0.4, height: 0.02),
             ResultTextLine(text: "120%", confidence: 1, x: 0.4, y: 0.40, width: 0.2, height: 0.03),
             ResultTextLine(text: speed, confidence: 1, x: 0.3, y: 0.49, width: 0.4, height: 0.02),
             ResultTextLine(text: "70%", confidence: 1, x: 0.4, y: 0.56, width: 0.2, height: 0.03)]
        }
        let japanese = ResultTextParser(language: .japanese).read(lines: page("HACK BONUS:", "SPEED BONUS:"), context: context, at: 1)
        #expect(japanese.panelPresent && japanese.labelLanguage == .japanese && japanese.hackingBonus == 120)
        // English labels read in any language, and name English, not Japanese.
        let english = ResultTextParser(language: .japanese).read(lines: page("HACKING BONUS:", "SPEED BONUS:"), context: context, at: 1)
        #expect(english.panelPresent && english.labelLanguage == .english)
        let chinese = ResultTextParser(language: .simplifiedChinese).read(lines: page("入侵奖励：", "速度奖励："), context: context, at: 1)
        #expect(chinese.labelLanguage == .simplifiedChinese && chinese.speedBonus == 70)
    }
}
