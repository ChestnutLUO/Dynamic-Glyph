import Testing
import GlyphRecognition

/// Home's floating-window preview before Start: the real idle gear window,
/// laid over the Picture in Picture layer, only while nothing draws into it.
@Suite("Idle floating-window preview")
struct IdleWindowPreviewTests {
    private func shows(capturing: Bool = false, preparing: Bool = false, stopping: Bool = false,
                       running: Bool = false, assists: Bool = false) -> Bool {
        IdleWindowPreview.shows(isCapturing: capturing, isPreparing: preparing, isStopping: stopping,
                                floatingWindowRunning: running, assistsGlyphs: assists)
    }

    @Test("Shown only before Start in gear-only mode, and gone once the window renders")
    func whenShown() {
        #expect(shows())
        #expect(!shows(capturing: true))
        #expect(!shows(preparing: true))
        #expect(!shows(stopping: true))
        #expect(!shows(running: true), "the render loop owns the layer once it runs")
        #expect(!shows(assists: true), "with Glyph assistance, Home is as before: no demo Glyphs")
    }

    @Test("It is the real idle gear window: watching, with no count and no Glyph")
    func idleSnapshot() throws {
        let snapshot = IdleWindowPreview.snapshot(uptime: 50)
        let gear = try #require(snapshot.visibleGear(atUptime: 50))
        #expect(gear.state == .watching && gear.itemCount == 0)
        #expect(gear.compactValue == "0")
        #expect(snapshot.tileStyles.isEmpty && snapshot.provisionalGlyph == nil)
    }
}
