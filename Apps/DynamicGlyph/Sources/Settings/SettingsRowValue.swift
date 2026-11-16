import Foundation

/// What a row on the Settings main page shows on its trailing edge, before
/// the page it opens. A running recording is never hidden behind a page: it
/// replaces the row's On or Off.
enum SettingsRowValue: Equatable {
    /// No Glyph list yet: the Glyph list row's own "Not added yet".
    case notAdded
    /// How many Glyphs the Glyph list defines.
    case glyphs(Int)
    case off
    case on
    /// A recording's progress line, shown in orange while it runs.
    case recording(String)

    /// The Glyph data row: the Glyph list's size, or that none is added.
    static func glyphData(count: Int) -> SettingsRowValue {
        count == 0 ? .notAdded : .glyphs(count)
    }

    /// A row whose page turns something on: its progress line while it
    /// records, otherwise On or Off.
    static func switched(isOn: Bool, runningLine: String?) -> SettingsRowValue {
        if let runningLine { return .recording(runningLine) }
        return isOn ? .on : .off
    }

    /// Orange, in monospaced digits, rather than the secondary grey.
    var isRunning: Bool {
        if case .recording = self { return true }
        return false
    }

    /// The text, from the app's existing labels.
    var text: String {
        switch self {
        case .notAdded:
            return String(localized: "Not added yet", comment: "Shape list status before a file is added.")
        case .glyphs(let count):
            return String(localized: "\(count) Glyphs")
        case .off:
            return String(localized: "Off")
        case .on:
            return String(localized: "On")
        case .recording(let line):
            return line
        }
    }
}
