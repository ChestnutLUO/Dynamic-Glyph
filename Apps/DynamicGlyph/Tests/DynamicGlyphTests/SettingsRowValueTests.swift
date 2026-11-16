import Testing

/// The trailing values of the Settings main page's rows.
@Suite("Settings row values")
struct SettingsRowValueTests {
    @Test("Glyph data says Not added yet until a Glyph list is loaded, then its size")
    func glyphData() {
        #expect(SettingsRowValue.glyphData(count: 0) == .notAdded)
        #expect(SettingsRowValue.glyphData(count: 1) == .glyphs(1))
        #expect(SettingsRowValue.glyphData(count: 42) == .glyphs(42))
    }

    @Test("A switched row says On or Off, and a running recording's line instead")
    func switched() {
        #expect(SettingsRowValue.switched(isOn: false, runningLine: nil) == .off)
        #expect(SettingsRowValue.switched(isOn: true, runningLine: nil) == .on)
        // Shown even if the switch reads off, so a recording is never hidden.
        #expect(SettingsRowValue.switched(isOn: true, runningLine: "Recording · 01:05 · 12 MB")
                == .recording("Recording · 01:05 · 12 MB"))
        #expect(SettingsRowValue.switched(isOn: false, runningLine: "Recording · 00:01 · 1 MB")
                == .recording("Recording · 00:01 · 1 MB"))
    }

    @Test("Only a running recording is orange, and its line is shown as is")
    func running() {
        #expect(SettingsRowValue.recording("Recording · 01:05 · 12 MB").isRunning)
        #expect(SettingsRowValue.recording("Recording · 01:05 · 12 MB").text == "Recording · 01:05 · 12 MB")
        for value in [SettingsRowValue.notAdded, .glyphs(3), .on, .off] {
            #expect(!value.isRunning, "\(value)")
            #expect(!value.text.isEmpty, "\(value)")
        }
    }
}
