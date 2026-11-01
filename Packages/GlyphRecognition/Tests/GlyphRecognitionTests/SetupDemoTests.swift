import CoreGraphics
import Testing
import GlyphRecognitionImages
@testable import GlyphRecognition

@Suite("Setup preview")
struct SetupDemoTests {
    @Test("The standard canvas is 1280 x 128 pixels and every preset is within the limits")
    func canvasPresets() {
        let standard = PiPCanvasConfiguration.standard
        #expect(standard == PiPCanvasConfiguration(width: 640, height: 64, resolution: 2))
        #expect(standard.pixelWidth == 1280 && standard.pixelHeight == 128)
        #expect(PiPCanvasConfiguration.presets.first == standard)
        #expect(Set(PiPCanvasConfiguration.presets.map(\.aspectRatio)).count == PiPCanvasConfiguration.presets.count)
        for preset in PiPCanvasConfiguration.presets {
            // Unchanged by the clamps, so what setup labels is what is applied.
            #expect(PiPCanvasConfiguration(width: preset.width, height: preset.height,
                                           resolution: preset.resolution) == preset)
            #expect(preset.resolution == 2)
        }
    }

    @Test("The demo uses a full sequence, then the player's shapes, then its own")
    func demoSources() {
        let own = SetupDemo(table: nil)
        #expect(own.usesBuiltInShapes)
        #expect(own.glyphs.count == SetupDemo.slotCount)
        #expect(own.glyphs.allSatisfy { own.table.path(for: $0) != nil })

        let small = GlyphTable(entries: [GlyphID("alpha"): GlyphPath(encoded: "038")!])
        #expect(SetupDemo(table: small).usesBuiltInShapes, "too few shapes to fill five slots")

        let names = ["a1", "a2", "a3", "a4", "a5", "a6"]
        let paths = ["01", "12", "23", "34", "45", "56"]
        let table = GlyphTable(entries: Dictionary(uniqueKeysWithValues: zip(names, paths).map {
            (GlyphID($0), GlyphPath(encoded: $1)!)
        }))
        let shapes = SetupDemo(table: table)
        #expect(!shapes.usesBuiltInShapes)
        #expect(shapes.glyphs == Array(table.glyphs.prefix(5)))

        let sequence = ["a6", "a2", "a6", "a3", "a1"].map { GlyphID($0) }
        let unknown = ["a1", "a2", "zz", "a3", "a4"].map { GlyphID($0) }
        let sequences = SequenceTable(sequences: [unknown, Array(sequence.prefix(3)), sequence])
        #expect(SetupDemo(table: table, sequences: sequences).glyphs == sequence)
    }

    @Test("One loop waits, presents, checks each drawn Glyph but the last, and finishes")
    func demoTimeline() {
        let demo = SetupDemo(table: nil)
        let glyphs = demo.glyphs
        func at(_ time: Double) -> GlyphDisplaySnapshot { demo.snapshot(at: time, uptime: 100) }

        #expect(at(0.5).state == .command)
        #expect(at(0.5).tileStyles.isEmpty)

        #expect(at(1.5).state == .presenting)
        #expect(at(1.5).tileStyles.first == .observing(glyphs[0]))
        #expect(at(3.5).tileStyles.prefix(3) == [.confirmed(glyphs[0]), .confirmed(glyphs[1]), .observing(glyphs[2])])

        #expect(at(6.5).state == .input)
        #expect(at(6.5).inputSlotIndex == 0)
        #expect(at(6.5).inputChecks.isEmpty)
        #expect(at(6.5).tileStyles == glyphs.map { .confirmed($0) })
        #expect(at(7.5).inputSlotIndex == 1)
        #expect(at(7.5).inputCheckDisplay(for: 0, atUptime: 100)?.verdict == .matched)
        #expect(at(7.5).inputCheckDisplay(for: 0, atUptime: 100)?.showsSymbol == true)
        #expect(at(10.5).inputChecks.map(\.slotIndex) == [0, 1, 2, 3])
        #expect(at(10.5).inputCheckDisplay(for: 0, atUptime: 100)?.showsSymbol == false, "the check mark expires")

        #expect(at(11.5).state == .completed)
        #expect(at(11.5).inputSlotIndex == nil)
        #expect(at(11.5).inputChecks.count == SetupDemo.slotCount - 1)

        #expect(at(SetupDemo.loopDuration + 0.5) == at(0.5))
        #expect(at(-0.5) == at(SetupDemo.loopDuration - 0.5))
        #expect(!at(0.5).isStale(atUptime: 100, threshold: 1.5))
    }

    @Test("Every preset renders at its labelled pixel size, and the frames change")
    func previewImages() throws {
        let demo = SetupDemo(table: nil)
        let renderer = GlyphDisplayRenderer(table: demo.table)
        for canvas in PiPCanvasConfiguration.presets {
            let image = try #require(renderer.image(demo.snapshot(at: 3.5, uptime: 100), canvas: canvas,
                                                    atUptime: 100, windowWidth: 353))
            #expect(image.width == canvas.pixelWidth)
            #expect(image.height == canvas.pixelHeight)
        }
        let waiting = try #require(renderer.image(demo.snapshot(at: 0.5, uptime: 100), canvas: .standard,
                                                  atUptime: 100, windowWidth: nil))
        let drawing = try #require(renderer.image(demo.snapshot(at: 7.5, uptime: 100), canvas: .standard,
                                                  atUptime: 100, windowWidth: nil))
        #expect(waiting.dataProvider?.data != drawing.dataProvider?.data)
    }

    @Test("The gear preview shows gear-only capture's window and never a Glyph")
    func gearPreview() throws {
        func at(_ time: Double) -> GlyphDisplaySnapshot { SetupDemo.gearSnapshot(at: time, uptime: 100) }
        func gear(_ time: Double) -> GearDropDisplay? { at(time).visibleGear(atUptime: 100) }

        #expect(gear(0.5) == GearDropDisplay(state: .watching, hackID: nil, itemCount: 0))
        #expect(gear(2.5)?.state == .reading)
        #expect(gear(3.5) == GearDropDisplay(state: .read, hackID: nil, itemCount: SetupDemo.gearItemCount))
        #expect(gear(6.5) == GearDropDisplay(state: .watching, hackID: nil, itemCount: SetupDemo.gearItemCount))
        #expect(at(SetupDemo.gearLoopDuration + 0.5) == at(0.5))
        for time in stride(from: 0.0, to: SetupDemo.gearLoopDuration, by: 0.25) {
            let snapshot = at(time)
            #expect(snapshot.slots.isEmpty && snapshot.tileStyles.isEmpty && snapshot.provisionalGlyph == nil)
            #expect(snapshot.visibleGear(atUptime: 100) != nil, "the window shows gear at \(time) s")
        }

        // Drawn without any shape table, as gear-only capture is.
        let renderer = GlyphDisplayRenderer(table: nil)
        let watching = try #require(renderer.image(at(0.5), canvas: .standard, atUptime: 100, windowWidth: nil))
        let read = try #require(renderer.image(at(3.5), canvas: .standard, atUptime: 100, windowWidth: nil))
        #expect(watching.width == PiPCanvasConfiguration.standard.pixelWidth)
        #expect(watching.dataProvider?.data != read.dataProvider?.data)
    }

    /// Home's floating-window preview before Start, in gear-only mode.
    @Test("The gear-only idle window says it is watching for gear, with no count and no Glyph")
    func gearOnlyIdle() throws {
        let idle = GlyphDisplaySnapshot.gearOnlyIdle(uptime: 100)
        let gear = try #require(idle.visibleGear(atUptime: 100))
        #expect(gear == GearDropDisplay(state: .watching, hackID: nil, itemCount: 0))
        // The same state the tracker reports in gear-only capture before any drop.
        var tracker = GearDropDisplayTracker(standalone: true)
        tracker.update(waiting: [], reading: false, associationUncertain: false, at: 0)
        #expect(tracker.display == gear)
        #expect(gear.message(currentHackID: idle.hackID) == "Watching for gear")
        #expect(idle.slots.isEmpty && idle.tileStyles.isEmpty && idle.provisionalGlyph == nil)
        let image = try #require(GlyphDisplayRenderer(table: nil).image(idle, canvas: .standard, atUptime: 100,
                                                                        windowWidth: nil))
        #expect(image.width == PiPCanvasConfiguration.standard.pixelWidth)
    }
}
