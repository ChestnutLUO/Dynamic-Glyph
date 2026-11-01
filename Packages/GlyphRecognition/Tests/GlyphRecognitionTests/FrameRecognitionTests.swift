import Foundation
import Testing
import GlyphRecognitionImages
@testable import GlyphRecognition

@Suite("Pixel recognition")
struct FrameRecognitionTests {
    private func frame(_ number: String) throws -> LuminanceImage {
        try ImageDecoder.load(ReferenceData.fixturesDirectory
            .appendingPathComponent("Frames/frame-\(number).jpg"))
    }

    @Test("Spike B 2389 locates all eleven rings and reports no stroke", .enabled(if: ReferenceData.shapesAvailable))
    func emptyPresentation() throws {
        let image = try frame("02389")
        #expect(image.width == 603 && image.height == 1311)
        let result = GlyphFrameRecognizer(table: try ReferenceData.glyphTable()).calibrateAndObserve(image)
        let fit = try #require(result.calibration)
        #expect(fit.matchedNodes.count == 11)
        #expect(abs(fit.origin.x - 74.8) < 1)
        #expect(abs(fit.origin.y - 454.7) < 1)
        #expect(abs(fit.size.x - 451.7) < 1)
        #expect(abs(fit.size.y - 542.3) < 1)
        #expect(fit.rootMeanSquareError < 1)
        #expect(result.state == .noStroke)
        #expect(result.edges.isEmpty)
        #expect(result.candidates.isEmpty)
    }

    @Test("Spike B 2690 has ink and an occluded node, but no complete Glyph", .enabled(if: ReferenceData.shapesAvailable))
    func partialPlayerInput() throws {
        let result = GlyphFrameRecognizer(table: try ReferenceData.glyphTable()).calibrateAndObserve(try frame("02690"))
        let fit = try #require(result.calibration)
        #expect(fit.matchedNodes.count == 10)
        #expect(!fit.matchedNodes.contains(NodeIndex(rawValue: 8)!))
        #expect(result.strokePixelCount > 100)
        #expect(result.state == .unrecognizedStroke)
        #expect(result.exactMatches.isEmpty)
    }

    @Test("A real map screen with bright roads is not a Glyph array", .enabled(if: ReferenceData.shapesAvailable))
    func mapIsNotAnArray() throws {
        let result = GlyphFrameRecognizer(table: try ReferenceData.glyphTable()).calibrateAndObserve(try frame("02092"))
        #expect(result.state == .calibrationUnavailable)
        #expect(result.candidates.isEmpty)
    }

    @Test("Array fitting follows scale and translation", arguments: [0.6, 1.0, 1.6])
    func scaledArray(scale: Double) throws {
        let canvas = Raster(scale: scale, offset: SIMD2(-9, 17))
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        #expect(fit.matchedNodes.count == 11)
        #expect(abs(fit.origin.x - canvas.point(40, 130).x) < 1.5)
        #expect(abs(fit.origin.y - canvas.point(40, 130).y) < 1.5)
        #expect(abs(fit.size.x - 240 * scale) < 2)
    }

    @Test("Known raster shapes resolve without any ordered path input", .enabled(if: ReferenceData.shapesAvailable))
    func independentlyDrawnShapes() throws {
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        // Pixel coordinates specified independently of GlyphPath/NodeArray.
        let cases: [(String, [(Double, Double)])] = [
            ("advance", [(160,130), (100,238), (40,346)]),
            ("clear", [(160,130), (160,418)]),
            ("all", [(160,130), (40,202), (40,346), (160,418), (280,346), (280,202), (160,130)]),
            ("balance", [(160,130), (160,274), (100,310), (40,346), (160,418), (280,346), (220,310), (160,274)])
        ]
        for (name, points) in cases {
            var canvas = Raster()
            let calibration = try #require(NodeArrayDetector().detect(in: canvas.image()))
            for (a, b) in zip(points, points.dropFirst()) {
                canvas.line(from: canvas.point(a.0, a.1), to: canvas.point(b.0, b.1))
            }
            let result = recognizer.observe(try canvas.image(), calibration: calibration)
            #expect(result.state == .uniqueVisibleShape, "\(name): \(result.state)")
            #expect(result.exactMatches == [GlyphID(name)], "\(name): \(result.candidates)")
        }
    }

    @Test("Faint translated strokes survive noise", .enabled(if: ReferenceData.shapesAvailable), arguments: [0.6, 1.6])
    func faintStroke(scale: Double) throws {
        var canvas = Raster(scale: scale, offset: SIMD2(-9, 17))
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        canvas.line(from: canvas.point(160, 130), to: canvas.point(160, 418), value: 85)
        // Deterministic sparse bright noise, independent of the recognition bins.
        for i in stride(from: 17, to: canvas.pixels.count, by: 379) { canvas.pixels[i] = 180 }
        let result = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
            .observe(try canvas.image(), calibration: fit)
        #expect(result.exactMatches == [GlyphID("clear")])
    }

    @Test("An isolated crossing or partial segment is not a complete edge", .enabled(if: ReferenceData.shapesAvailable))
    func partialStroke() throws {
        var canvas = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        canvas.line(from: canvas.point(160, 170), to: canvas.point(160, 195))
        let result = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
            .observe(try canvas.image(), calibration: fit)
        #expect(result.state == .unrecognizedStroke)
        #expect(result.edges.isEmpty)
        #expect(result.candidates.isEmpty)
    }

    @Test("Every reference shape survives rasterization, including crossings and imperfect", .enabled(if: ReferenceData.shapesAvailable))
    func vocabularyRasterization() throws {
        let table = try ReferenceData.glyphTable()
        let recognizer = GlyphFrameRecognizer(table: table)
        let blank = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: blank.image()))
        for id in table.glyphs {
            var canvas = blank
            let path = try #require(table.path(for: id))
            // The renderer draws the original walk, including long/overlapping
            // segments. It does not use the recognizer's edge normalization.
            for (a, b) in zip(path.nodes, path.nodes.dropFirst()) {
                canvas.line(from: canvas.nodes[a.rawValue], to: canvas.nodes[b.rawValue])
            }
            let result = recognizer.observe(try canvas.image(), calibration: fit)
            #expect(result.exactMatches == [id], "\(id): \(result.candidates)")
            #expect(result.hasUniqueVisibleShape, "\(id): \(result.state), unexplained=\(result.unexplainedInkPixelCount)")
        }
    }

    @Test("Fading parts combine within one Glyph, then reset for the next", .enabled(if: ReferenceData.shapesAvailable))
    func temporalAccumulation() throws {
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        let blank = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: blank.image()))
        var accumulator = GlyphStrokeAccumulator(calibration: fit, recognizer: recognizer)
        #expect(accumulator.finish() == nil)
        // Three separated views, neither contains a whole 0-to-5 or 5-to-a edge.
        for (start, end) in [(130.0,230.0), (215.0,325.0), (310.0,418.0)] {
            var canvas = blank
            canvas.line(from: canvas.point(160, start), to: canvas.point(160, end))
            let partial = try accumulator.append(canvas.image())
            #expect(partial.exactMatches.isEmpty)
        }
        let finished = accumulator.finish(completion: .presentationBoundary)
        let combined = try #require(finished)
        #expect(combined.observation.exactMatches == [GlyphID("clear")])
        #expect(combined.acceptedGlyph == GlyphID("clear"))
        #expect(combined.frameCount == 3)
        #expect(accumulator.finish() == nil)
        try accumulator.append(blank.image())
        #expect(accumulator.finish()?.observation.state == .noStroke)
    }

    @Test("Geometry changes reject stale calibration and cross-frame accumulation", .enabled(if: ReferenceData.shapesAvailable))
    func geometryChanges() throws {
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        let blank = try Raster().image()
        let first = recognizer.calibrateAndObserve(blank)
        let fit = try #require(first.calibration)
        let resized = try Raster(scale: 0.6).image()
        #expect(recognizer.observe(resized, calibration: fit).state == .calibrationMismatch)
        var accumulator = GlyphStrokeAccumulator(calibration: fit, recognizer: recognizer)
        try accumulator.append(blank)
        #expect(throws: GlyphStrokeAccumulator.AccumulationError.self) {
            try accumulator.append(resized)
        }
        #expect(accumulator.finish() == nil)
    }

    @Test("Same-shape aliases remain ambiguous")
    func aliases() throws {
        let path = try #require(GlyphPath(encoded: "05a"))
        let recognizer = GlyphFrameRecognizer(table: GlyphTable(entries: [GlyphID("a"): path, GlyphID("b"): path]))
        var canvas = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        canvas.line(from: canvas.point(160, 130), to: canvas.point(160, 418))
        let result = recognizer.observe(try canvas.image(), calibration: fit)
        #expect(result.state == .ambiguousShape)
        #expect(result.exactMatches == [GlyphID("a"), GlyphID("b")])
    }

    @Test("Invalid pixel buffers are rejected before indexing")
    func malformedImages() {
        #expect(throws: LuminanceImage.ValidationError.self) { try LuminanceImage(width: 0, height: 1, pixels: []) }
        #expect(throws: LuminanceImage.ValidationError.self) { try LuminanceImage(width: Int.max, height: 2, pixels: []) }
        #expect(throws: LuminanceImage.ValidationError.self) { try LuminanceImage(width: 2, height: 2, pixels: [0]) }
    }

    @Test("An exact partial drawing exposes the longer templates it can become", .enabled(if: ReferenceData.shapesAvailable))
    func partialExactMatches() throws {
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        let cases: [(String, String, [(Double, Double)])] = [
            ("see", "advance", [(160,130), (100,238)]),
            ("advance", "attack", [(40,346), (100,238), (160,130)]),
            ("use", "capture", [(280,202), (220,310), (160,274)]),
            ("all", "clear_all", [(160,130), (40,202), (40,346), (160,418), (280,346), (280,202), (160,130)])
        ]
        for (visible, longer, points) in cases {
            var canvas = Raster()
            let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
            for (a, b) in zip(points, points.dropFirst()) {
                canvas.line(from: canvas.point(a.0, a.1), to: canvas.point(b.0, b.1))
            }
            let result = recognizer.observe(try canvas.image(), calibration: fit)
            #expect(result.exactMatches == [GlyphID(visible)])
            #expect(result.extensions.contains(GlyphID(longer)))
            var accumulator = GlyphStrokeAccumulator(calibration: fit, recognizer: recognizer)
            try accumulator.append(canvas.image())
            let provisional = accumulator.finish()
            #expect(provisional?.acceptedGlyph == nil)
            // A verified boundary can complete a short Glyph even though
            // longer templates contain it. Supersets alone cannot decide this.
            try accumulator.append(canvas.image())
            let completed = accumulator.finish(completion: .presentationBoundary)
            #expect(completed?.acceptedGlyph == GlyphID(visible))
        }
    }

    @Test("clear then all records a possible missed boundary and refuses acceptance", .enabled(if: ReferenceData.shapesAvailable))
    func crossGlyphUnion() throws {
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        let blank = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: blank.image()))
        var clear = blank
        clear.line(from: clear.point(160, 130), to: clear.point(160, 418))
        var all = blank
        let points = [(160.0,130.0), (40,202), (40,346), (160,418), (280,346), (280,202), (160,130)]
        for (a, b) in zip(points, points.dropFirst()) {
            all.line(from: all.point(a.0, a.1), to: all.point(b.0, b.1))
        }
        var accumulator = GlyphStrokeAccumulator(calibration: fit, recognizer: recognizer)
        try accumulator.append(clear.image())
        try accumulator.append(all.image())
        let finished = accumulator.finish(completion: .presentationBoundary)
        let result = try #require(finished)
        #expect(result.observation.exactMatches == [GlyphID("clear_all")])
        #expect(result.frames.map(\.exactMatches) == [[GlyphID("clear")], [GlyphID("all")]])
        #expect(result.frameCount == 2)
        #expect(result.possibleBoundaryCrossing)
        #expect(result.acceptedGlyph == nil)
        // Repeated complete Glyphs in separate slots are separate observations.
        for _ in 0..<2 {
            try accumulator.append(clear.image())
            let repeated = accumulator.finish(completion: .presentationBoundary)
            #expect(repeated?.acceptedGlyph == GlyphID("clear"))
            #expect(repeated?.frameCount == 1)
        }
    }

    @Test("Non-named fragments need an explicit boundary even when their union has an exact match", .enabled(if: ReferenceData.shapesAvailable))
    func fragmentUnionIsProvisional() throws {
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        let blank = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: blank.image()))
        var accumulator = GlyphStrokeAccumulator(calibration: fit, recognizer: recognizer)
        var first = blank, second = blank
        first.line(from: first.point(160,130), to: first.point(100,238))
        second.line(from: second.point(100,238), to: second.point(40,346))
        try accumulator.append(first.image())
        try accumulator.append(second.image())
        let finished = accumulator.finish()
        let result = try #require(finished)
        #expect(result.observation.exactMatches == [GlyphID("advance")])
        #expect(result.acceptedGlyph == nil)
        #expect(result.frameCount == 2)
    }

    @Test("Substantial off-lattice ink downgrades an otherwise exact edge match", .enabled(if: ReferenceData.shapesAvailable))
    func unexplainedInk() throws {
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        var canvas = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        canvas.line(from: canvas.point(160,130), to: canvas.point(160,418))
        for y in 170...190 {
            canvas.line(from: canvas.point(60, Double(y)), to: canvas.point(135, Double(y)))
            canvas.line(from: canvas.point(185, Double(y + 190)), to: canvas.point(260, Double(y + 190)))
        }
        let result = recognizer.observe(try canvas.image(), calibration: fit)
        #expect(result.exactMatches == [GlyphID("clear")]) // geometric key remains available for diagnosis
        #expect(result.state == .unexplainedInk)
        #expect(!result.hasUniqueVisibleShape)
        #expect(result.unexplainedInkPixelCount > result.strokePixelCount / 2)
        var accumulator = GlyphStrokeAccumulator(calibration: fit, recognizer: recognizer)
        try accumulator.append(canvas.image())
        #expect(accumulator.finish(completion: .presentationBoundary)?.acceptedGlyph == nil)
    }

    @Test("Drawn-over arrays require calibration acquired before the stroke", .enabled(if: ReferenceData.shapesAvailable), arguments: ["clear", "balance", "clear_all"])
    func mandatoryCalibration(name: String) throws {
        let table = try ReferenceData.glyphTable()
        let recognizer = GlyphFrameRecognizer(table: table)
        var canvas = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        let path = try #require(table.path(for: GlyphID(name)))
        for (a, b) in zip(path.nodes, path.nodes.dropFirst()) {
            canvas.line(from: canvas.nodes[a.rawValue], to: canvas.nodes[b.rawValue])
        }
        let image = try canvas.image()
        #expect(NodeArrayDetector().detect(in: image) == nil)
        #expect(recognizer.calibrateAndObserve(image).state == .calibrationUnavailable)
        #expect(recognizer.observe(image, calibration: fit).exactMatches == [GlyphID(name)])
    }

    @Test("Fixed calibration handles small independent fit differences on real frames", .enabled(if: ReferenceData.shapesAvailable))
    func stableCalibration() throws {
        let blank = try frame("02389"), input = try frame("02690")
        let first = try #require(NodeArrayDetector().detect(in: blank))
        let second = try #require(NodeArrayDetector().detect(in: input))
        #expect(first != second)
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        var accumulator = GlyphStrokeAccumulator(calibration: first, recognizer: recognizer)
        try accumulator.append(blank)
        try accumulator.append(input)
        let finished = accumulator.finish()
        #expect(finished?.frameCount == 2)
        #expect(finished?.acceptedGlyph == nil)
    }

    @Test("Frame limit discards a drawing instead of silently losing its boundary", .enabled(if: ReferenceData.shapesAvailable))
    func boundedHistory() throws {
        let image = try Raster().image()
        let fit = try #require(NodeArrayDetector().detect(in: image))
        var accumulator = GlyphStrokeAccumulator(calibration: fit,
            recognizer: GlyphFrameRecognizer(table: try ReferenceData.glyphTable()), maximumFrames: 2)
        try accumulator.append(image)
        try accumulator.append(image)
        #expect(throws: GlyphStrokeAccumulator.AccumulationError.frameLimitExceeded) {
            try accumulator.append(image)
        }
        #expect(accumulator.finish() == nil)
    }

    @Test("Spatial coverage policy accepts a small gap and rejects a twenty-percent gap", .enabled(if: ReferenceData.shapesAvailable), arguments: [10, 16, 20, 25])
    func gapBoundary(percent: Int) throws {
        var canvas = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        let halfGap = 144 * Double(percent) / 200
        canvas.line(from: canvas.point(160,130), to: canvas.point(160,202 - halfGap))
        canvas.line(from: canvas.point(160,202 + halfGap), to: canvas.point(160,274))
        let result = GlyphFrameRecognizer(table: try ReferenceData.glyphTable()).observe(try canvas.image(), calibration: fit)
        let edge = GlyphPath.Edge(NodeIndex(rawValue: 0)!, NodeIndex(rawValue: 5)!)
        let evidence = try #require(result.evidence.first { $0.edge == edge })
        #expect(evidence.isPresent == (percent < 20), "gap \(percent)%: coverage=\(evidence.coverage)")
    }

    @Test("Twenty of twenty-four contrast bins are required; weak bins do not count")
    func supportBoundary() {
        let edge = GlyphPath.Edge(NodeIndex(rawValue: 0)!, NodeIndex(rawValue: 5)!)
        #expect(!GlyphEdgeEvidence(edge: edge, samples: Array(repeating: 0.18, count: 19) + Array(repeating: 0, count: 5)).isPresent)
        #expect(GlyphEdgeEvidence(edge: edge, samples: Array(repeating: 0.18, count: 20) + Array(repeating: 0, count: 4)).isPresent)
        #expect(!GlyphEdgeEvidence(edge: edge, samples: Array(repeating: 0.179, count: 24)).isPresent)
    }

    @Test("A line needs absolute brightness as well as contrast", .enabled(if: ReferenceData.shapesAvailable), arguments: [UInt8(59), UInt8(60)])
    func brightnessBoundary(value: UInt8) throws {
        var canvas = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        canvas.line(from: canvas.point(160,130), to: canvas.point(160,418), value: value)
        let result = GlyphFrameRecognizer(table: try ReferenceData.glyphTable()).observe(try canvas.image(), calibration: fit)
        #expect(result.edges.count == (value == 60 ? 2 : 0))
    }

    @Test("Near-match candidates obey the default and configured distance cutoffs")
    func candidateDistanceLimit() throws {
        let table = try GlyphTable.parse(csv: "exact,03\none,038\ntwo,038a\nthree,038a9")
        var canvas = Raster()
        let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
        canvas.line(from: canvas.point(160,130), to: canvas.point(100,238))
        let result = GlyphFrameRecognizer(table: table).observe(try canvas.image(), calibration: fit)
        #expect(result.candidates == [GlyphCandidate(id: GlyphID("exact"), distance: 0),
                                     GlyphCandidate(id: GlyphID("one"), distance: 1),
                                     GlyphCandidate(id: GlyphID("two"), distance: 2)])
        #expect(result.extensions == [GlyphID("one"), GlyphID("three"), GlyphID("two")])
        let strict = GlyphFrameRecognizer(table: table, maxEdgeDistance: 0).observe(try canvas.image(), calibration: fit)
        #expect(strict.candidates == [GlyphCandidate(id: GlyphID("exact"), distance: 0)])
        #expect(strict.extensions == result.extensions)
    }

    @Test("Reflected asymmetric pixel shapes do not keep the original name", .enabled(if: ReferenceData.shapesAvailable))
    func asymmetricPixelLabels() throws {
        let cases: [(String, [(Double, Double)])] = [
            ("see", [(160,130), (220,238)]),
            ("advance", [(160,130), (220,238), (280,346)]),
            ("use", [(40,202), (100,310), (160,274)])
        ]
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        for (original, points) in cases {
            var canvas = Raster()
            let fit = try #require(NodeArrayDetector().detect(in: canvas.image()))
            for (a, b) in zip(points, points.dropFirst()) {
                canvas.line(from: canvas.point(a.0,a.1), to: canvas.point(b.0,b.1))
            }
            let observation = recognizer.observe(try canvas.image(), calibration: fit)
            #expect(!observation.exactMatches.contains(GlyphID(original)))
        }
    }

    @Test("Truncated image data is rejected instead of becoming an empty observation")
    func damagedImage() throws {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("Frames/frame-02389.jpg"))
        #expect(try ImageDecoder.decode(data).width == 603)
        for length in [data.count / 2, data.count - 100] {
            #expect(throws: ImageDecoder.DecodeError.self) { try ImageDecoder.decode(Data(data.prefix(length))) }
        }
        #expect(throws: ImageDecoder.DecodeError.self) { try ImageDecoder.decode(Data("not an image".utf8)) }
    }

    private func touchFrame(_ sample: String) throws -> LuminanceImage {
        try ImageDecoder.load(ReferenceData.fixturesDirectory
            .appendingPathComponent("AssistiveTouch/touch-\(sample).png"))
    }

    /// An owned one-entry vocabulary: an empty array needs no reference table.
    private func tinyTable() throws -> GlyphTable { try GlyphTable.parse(csv: "test,03\n") }

    @Test("An AssistiveTouch button beside the array leaves it empty and calibratable")
    func assistiveTouchBesideArray() throws {
        // The 2026-09-26 report: the button's rim reaches into the corner of
        // the array's bounding box, and the second and third hacks were lost.
        let image = try touchFrame("01903")
        let result = GlyphFrameRecognizer(table: try tinyTable()).calibrateAndObserve(image)
        #expect(result.calibration?.matchedNodes.count == 11)
        #expect(result.state == .noStroke)
        #expect(result.strokePixelCount == 0)

        var session = GlyphFrameSession(table: try tinyTable())
        #expect(session.observe(image, at: 1)?.state == .noStroke)
        #expect(session.calibration != nil)
    }

    @Test("A Glyph presented beside the AssistiveTouch button is still named", .enabled(if: ReferenceData.shapesAvailable))
    func glyphBesideAssistiveTouch() throws {
        let recognizer = GlyphFrameRecognizer(table: try ReferenceData.glyphTable())
        let fit = try #require(recognizer.calibrateAndObserve(try touchFrame("01903")).calibration)
        let observation = recognizer.observe(try touchFrame("01913"), calibration: fit)
        #expect(observation.state == .uniqueVisibleShape)
        #expect(observation.exactMatches == [GlyphID("save")])
    }

    @Test("Stray ink inside the hexagon still counts; in the box corners outside it, it does not")
    func strayInkPlacement() throws {
        let empty = try touchFrame("01903")
        let recognizer = GlyphFrameRecognizer(table: try tinyTable())
        let fit = try #require(recognizer.calibrateAndObserve(empty).calibration)
        let positions = fit.positions
        func blot(at center: SIMD2<Double>) throws -> LuminanceImage {
            var pixels = empty.pixels
            for y in Int(center.y) - 8...Int(center.y) + 8 {
                for x in Int(center.x) - 8...Int(center.x) + 8
                where (Double(x) - center.x) * (Double(x) - center.x) + (Double(y) - center.y) * (Double(y) - center.y) <= 64 {
                    pixels[y * empty.width + x] = 200
                }
            }
            return try LuminanceImage(width: empty.width, height: empty.height, pixels: pixels)
        }
        // Between the top node and the two upper-left nodes: where a stroke can be.
        let inside = (positions[0] + positions[1] + positions[3]) / 3
        #expect(recognizer.observe(try blot(at: inside), calibration: fit).state == .unrecognizedStroke)
        // The top-right corner of the bounding box, which no stroke can reach.
        let corner = SIMD2(fit.origin.x + fit.size.x - 10, fit.origin.y + 10)
        #expect(recognizer.observe(try blot(at: corner), calibration: fit).state == .noStroke)
    }
}

/// Small independent software renderer. Distances to actual line segments
/// generate pixels; there is no access to the detector's sampling positions.
private struct Raster {
    let width: Int
    let height: Int
    let scale: Double
    let offset: SIMD2<Double>
    var pixels: [UInt8]
    var nodes: [SIMD2<Double>] {
        [(160.0,130.0),(40,202),(280,202),(100,238),(220,238),(160,274),
         (100,310),(220,310),(40,346),(280,346),(160,418)].map { point($0.0, $0.1) }
    }

    init(scale: Double = 1, offset: SIMD2<Double> = .zero) {
        self.scale = scale; self.offset = offset
        width = Int(320 * scale); height = Int(520 * scale)
        pixels = [UInt8](repeating: 8, count: width * height)
        for p in nodes {
            for y in max(0, Int(p.y - 9 * scale))...min(height - 1, Int(p.y + 9 * scale)) {
                for x in max(0, Int(p.x - 9 * scale))...min(width - 1, Int(p.x + 9 * scale)) {
                    let d = SIMD2(Double(x), Double(y)) - p
                    let radius = (d * d).sum().squareRoot() / scale
                    if radius >= 5.5 && radius <= 7.5 { pixels[y * width + x] = 230 }
                }
            }
        }
    }

    func point(_ x: Double, _ y: Double) -> SIMD2<Double> { (SIMD2(x, y) + offset) * scale }
    func image() throws -> LuminanceImage { try LuminanceImage(width: width, height: height, pixels: pixels) }

    mutating func line(from a: SIMD2<Double>, to b: SIMD2<Double>, value: UInt8 = 210) {
        let radius = max(1, 2 * scale), delta = b - a
        let lengthSquared = (delta * delta).sum()
        for y in max(0, Int(min(a.y, b.y) - radius))...min(height - 1, Int(max(a.y, b.y) + radius)) {
            for x in max(0, Int(min(a.x, b.x) - radius))...min(width - 1, Int(max(a.x, b.x) + radius)) {
                let p = SIMD2(Double(x), Double(y))
                let t = min(1, max(0, ((p - a) * delta).sum() / lengthSquared))
                let d = p - (a + t * delta)
                if (d * d).sum() <= radius * radius { pixels[y * width + x] = max(value, pixels[y * width + x]) }
            }
        }
    }
}
