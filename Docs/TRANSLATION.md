# Translation guide

The app is written in English and localized into Japanese (`ja`), Simplified
Chinese (`zh-Hans`) and Traditional Chinese (`zh-Hant`). Every user-facing
string lives in a string catalog, one per target:

| Catalog | Strings |
|---|---|
| `Apps/DynamicGlyph/Sources/Resources/Localizable.xcstrings` | The app's screens |
| `Apps/DynamicGlyph/Sources/Resources/InfoPlist.xcstrings` | Permission prompts shown by iOS |
| `Apps/DynamicGlyph/Widget/Localizable.xcstrings` | Dynamic Island and Lock Screen |
| `Packages/GlyphRecognition/Sources/GlyphRecognition/Localizable.xcstrings` | Status line, slot captions and notes |
| `Packages/GlyphRecognition/Sources/GlyphRecognitionImages/Localizable.xcstrings` | Floating window text, prediction line |

## Adding or changing a string

- In SwiftUI views, a string literal is already localizable. Use
  `Text(verbatim:)` for text that must never be translated.
- Everywhere else, use `String(localized:comment:)`. Hand computed text to views
  as `LocalizedStringResource`.
- In the recognition package, always pass `bundle: #bundle`, or the string is
  looked up in the app's catalog and silently stays English.
- Give each string a `comment` saying where it appears and what every
  placeholder holds.
- Never build a sentence from fragments. Word order differs between these
  languages; write each variant as a whole string, as `footnote`, `qualifier`
  and the report footer do.
- Anything with a count gets English plural variants (`one`/`other`) in the
  catalog. Japanese and Chinese need only one form.

Building in Xcode adds new strings to the catalogs. From the command line,
`xcodebuild` does not write them back; run
`xcrun xcstringstool sync <catalog> --stringsdata <files>` with the target's
`.stringsdata` files from DerivedData to do the same thing.
The `Localization catalogs` suite in the package tests fails if any string
lacks a translation, or if a translation's placeholders don't match the source.

After a catalog changes, check the built app actually carries it: an incremental
`xcodebuild` can leave a bundle without its `*.lproj` folders, and a clean build
restores them. The package's resources must be built by Xcode;
`swift build --build-system native` copies the catalog uncompiled, which only
matters for the command-line tools, and they are English-only.

To see a language without changing the phone's, set **Run → Options → App
Language** in the scheme, or use the app's own language in the Settings app.

## Review state

The current Japanese and Chinese translations were machine-written and are
marked **Needs Review** in the catalogs. A native speaker who plays Ingress
should read them in the app and mark each one Translated.

## Glossary

Keep these exactly as shown.

| English | 日本語 | 简体中文 | 繁體中文 | Note |
|---|---|---|---|---|
| Dynamic Glyph | Dynamic Glyph | Dynamic Glyph | Dynamic Glyph | App name; never translated |
| Ingress | Ingress | Ingress | Ingress | Game name |
| Glyph names (`body`, `hide`, …) | as in game | as in game | as in game | Never translated |
| Glyph | グリフ | Glyph | Glyph | Chinese-speaking players use the English word |
| Glyph hack | グリフハック | Glyph Hack | Glyph Hack | |
| hack | ハック | Hack | Hack | |
| sequence | シーケンス | 序列 | 序列 | |
| slot | スロット | 槽位 | 槽位 | One hexagon in the game's row |
| row (of hexagons) | 列 | 排 | 排 | The game's row of slots; keep one term |
| row (in a file) | 行 | 行 | 列 | CSV rows; 列 is Taiwan's spreadsheet term |
| shape list (`glyph_line.csv`) | 形状リスト | 形状列表 | 形狀清單 | Keep file names as written |
| sequence list (`glyph.csv`) | シーケンスリスト | 序列列表 | 序列清單 | |
| floating window | フローティングウインドウ | 悬浮窗 | 浮動視窗 | Picture in Picture |
| Dynamic Island | Dynamic Island | 灵动岛 | 動態島 | Apple's own terms |
| Live Activities | ライブアクティビティ | 实时活动 | 即時動態 | Apple's own terms |
| Lock Screen | ロック画面 | 锁定屏幕 | 鎖定畫面 | Apple's own terms |
| Settings app | 「設定」App | “设置”App | 「設定」App | Apple's own terms |
| Files app | 「ファイル」App | “文件”App | 「檔案」App | Apple's own terms |
| session | セッション | 会话 | 工作階段 | |
| report | レポート | 报告 | 報告 | |
| Bug reports | 不具合の報告 | 错误报告 | 錯誤回報 | 回報 is the Taiwanese idiom |
| Start / Stop | 開始 / 停止 | 开始 / 停止 | 開始 / 停止 | Main button |
