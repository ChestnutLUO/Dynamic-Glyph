import GlyphRecognition

/// Home's floating-window preview before Start.
///
/// The preview is the Picture in Picture layer itself, and before Start
/// nothing has been drawn into it, so it showed as a black bar. In gear-only
/// mode Home draws the real idle gear window ("Watching for gear") as a
/// picture laid over the layer, never into it: the layer stays in place and
/// visible, as Picture in Picture needs, and what the real window shows is
/// only ever drawn by the render loop. The picture goes as soon as the
/// render loop starts. Pure, so when it shows can be tested.
enum IdleWindowPreview {
    static func shows(isCapturing: Bool, isPreparing: Bool, isStopping: Bool,
                      floatingWindowRunning: Bool, assistsGlyphs: Bool) -> Bool {
        // With Glyph assistance in effect the window's idle state is today's:
        // nothing is laid over it, and no demo Glyph is shown on Home.
        !assistsGlyphs && !isCapturing && !isPreparing && !isStopping && !floatingWindowRunning
    }

    /// The real gear-only window before any item panel, with no count.
    static func snapshot(uptime: Double) -> GlyphDisplaySnapshot {
        .gearOnlyIdle(uptime: uptime)
    }
}
