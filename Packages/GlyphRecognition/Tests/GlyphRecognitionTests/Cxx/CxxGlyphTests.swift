import Foundation
import Testing
import GlyphCoreCxx
import GlyphRecognitionImages
@testable import GlyphRecognition

/// The C++ node array hunt, Glyph observation and frame session held to the
/// Swift oracle on the same decoded pixels.
@Suite("C++ core: node array and Glyph frame", .serialized)
struct CxxGlyphTests {
    private static let folders = ["Frames", "Recording", "Phases", "Covered", "Banner", "WindowEdge",
                                  "AssistiveTouch", "OneGlyph"]

    private struct Fixture {
        let folder: String
        let name: String
        let image: LuminanceImage
    }

    private static func fixtures(in folders: [String]) throws -> [Fixture] {
        var result: [Fixture] = []
        for folder in folders {
            let directory = try ReferenceData.fixturesDirectory.appendingPathComponent(folder)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let data = try Data(contentsOf: file)
                let cgImage = try #require(ImageDecoder.cgImage(from: data), "\(folder)/\(file.lastPathComponent)")
                result.append(Fixture(folder: folder, name: "\(folder)/\(file.lastPathComponent)",
                                      image: try ImageDecoder.decode(cgImage)))
            }
        }
        #expect(!result.isEmpty)
        return result
    }

    private static func withGray<T>(_ image: LuminanceImage, _ body: (gc_gray_image) throws -> T) rethrows -> T {
        try image.pixels.withUnsafeBufferPointer { buffer in
            try body(gc_gray_image(data: buffer.baseAddress, width: Int32(image.width), height: Int32(image.height),
                                   bytesPerRow: Int32(image.width)))
        }
    }

    private static func templates(from table: GlyphTable) throws -> [gc_template] {
        try table.glyphs.map { id in
            let edges = try #require(table.path(for: id)).undirectedEdges
                .sorted { ($0.lower.rawValue, $0.upper.rawValue) < ($1.lower.rawValue, $1.upper.rawValue) }
            try #require(edges.count <= Int(GC_MAX_TEMPLATE_EDGES))
            var template = gc_template()
            withUnsafeMutablePointer(to: &template.edges) { pointer in
                let base = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: gc_edge.self)
                for (index, edge) in edges.enumerated() {
                    base[index] = gc_edge(lower: UInt8(edge.lower.rawValue), upper: UInt8(edge.upper.rawValue))
                }
            }
            template.edgeCount = Int32(edges.count)
            return template
        }
    }

    private final class Session {
        let pointer: OpaquePointer
        init(_ table: GlyphTable, hunt: gc_hunt_options = gc_hunt_options_default()) throws {
            let templates = try CxxGlyphTests.templates(from: table)
            var options = hunt
            pointer = try #require(templates.withUnsafeBufferPointer { buffer in
                gc_session_create(buffer.baseAddress, Int32(buffer.count), 2, &options)
            })
        }
        deinit { gc_session_destroy(pointer) }

        var inkPixels: [Int] {
            var count: Int32 = 0
            guard let base = gc_session_ink_pixels(pointer, &count) else { return [] }
            return UnsafeBufferPointer(start: base, count: Int(count)).map(Int.init)
        }
    }

    private static func gcFit(_ fit: NodeArrayDetection) -> gc_fit {
        var mask: UInt16 = 0
        for node in fit.matchedNodes { mask |= UInt16(1) << UInt16(node.rawValue) }
        return gc_fit(imageWidth: Int32(fit.imageWidth), imageHeight: Int32(fit.imageHeight),
                      originX: fit.origin.x, originY: fit.origin.y, sizeX: fit.size.x, sizeY: fit.size.y,
                      nodeRadius: fit.nodeRadius, matchedNodes: mask, rootMeanSquareError: fit.rootMeanSquareError)
    }

    private static func matchedMask(_ fit: NodeArrayDetection) -> UInt16 { gcFit(fit).matchedNodes }

    private static func expectFitsMatch(_ cxx: gc_fit, _ swift: NodeArrayDetection, _ name: String,
                                        tolerance: Double = 1e-6) {
        #expect(cxx.imageWidth == Int32(swift.imageWidth) && cxx.imageHeight == Int32(swift.imageHeight), "\(name)")
        #expect(cxx.matchedNodes == matchedMask(swift), "\(name) matched nodes")
        #expect(abs(cxx.originX - swift.origin.x) <= tolerance, "\(name) origin.x \(cxx.originX) vs \(swift.origin.x)")
        #expect(abs(cxx.originY - swift.origin.y) <= tolerance, "\(name) origin.y \(cxx.originY) vs \(swift.origin.y)")
        #expect(abs(cxx.sizeX - swift.size.x) <= tolerance, "\(name) size.x \(cxx.sizeX) vs \(swift.size.x)")
        #expect(abs(cxx.sizeY - swift.size.y) <= tolerance, "\(name) size.y \(cxx.sizeY) vs \(swift.size.y)")
        #expect(abs(cxx.nodeRadius - swift.nodeRadius) <= tolerance, "\(name) radius")
        #expect(abs(cxx.rootMeanSquareError - swift.rootMeanSquareError) <= tolerance, "\(name) rms")
    }

    private static func state(_ swift: GlyphFrameObservation.State) -> gc_observation_state {
        switch swift {
        case .calibrationUnavailable: return GC_STATE_CALIBRATION_UNAVAILABLE
        case .calibrationMismatch: return GC_STATE_CALIBRATION_MISMATCH
        case .noStroke: return GC_STATE_NO_STROKE
        case .unrecognizedStroke: return GC_STATE_UNRECOGNIZED_STROKE
        case .unexplainedInk: return GC_STATE_UNEXPLAINED_INK
        case .ambiguousShape: return GC_STATE_AMBIGUOUS_SHAPE
        case .uniqueVisibleShape: return GC_STATE_UNIQUE_VISIBLE_SHAPE
        }
    }

    private static func samples(_ observation: inout gc_observation) -> [[Double]] {
        let edges = Int(observation.edgeCount)
        return withUnsafePointer(to: &observation.samples) { pointer in
            let base = UnsafeRawPointer(pointer).assumingMemoryBound(to: Double.self)
            return (0..<edges).map { edge in
                (0..<Int(GC_EDGE_SAMPLES)).map { base[edge * Int(GC_EDGE_SAMPLES) + $0] }
            }
        }
    }

    private static func candidates(_ observation: inout gc_observation) -> [gc_candidate] {
        withUnsafePointer(to: &observation.candidates) { pointer in
            let base = UnsafeRawPointer(pointer).assumingMemoryBound(to: gc_candidate.self)
            return (0..<Int(observation.candidateCount)).map { base[$0] }
        }
    }

    private static func extensions(_ observation: inout gc_observation) -> [Int32] {
        withUnsafePointer(to: &observation.extensions) { pointer in
            let base = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int32.self)
            return (0..<Int(observation.extensionCount)).map { base[$0] }
        }
    }

    private static func expectObservationsMatch(_ cxx: inout gc_observation, ink: [Int], _ swift: GlyphFrameObservation,
                                                table: GlyphTable, _ name: String) {
        #expect(cxx.state == state(swift.state), "\(name) state \(cxx.state) vs \(swift.state)")
        #expect(cxx.hasCalibration == (swift.calibration != nil), "\(name) calibration presence")
        if let fit = swift.calibration { expectFitsMatch(cxx.calibration, fit, "\(name) calibration", tolerance: 0) }
        #expect(Int(cxx.edgeCount) == swift.evidence.count, "\(name) edge count")
        let cxxSamples = samples(&cxx)
        var cxxPresent: Set<GlyphPath.Edge> = []
        for (index, evidence) in swift.evidence.enumerated() where index < cxxSamples.count {
            #expect(evidence.edge == GlyphGeometry.elementaryEdges[index], "\(name) edge order \(index)")
            let row = cxxSamples[index]
            #expect(row.count == evidence.samples.count)
            for (i, sample) in evidence.samples.enumerated() where i < row.count {
                #expect(abs(row[i] - sample) <= 1e-9, "\(name) edge \(evidence.edge) sample \(i): \(row[i]) vs \(sample)")
            }
            let coverage = Double(row.filter { $0 >= 0.18 }.count) / Double(row.count)
            if coverage >= 0.8 { cxxPresent.insert(evidence.edge) }
        }
        #expect(cxxPresent == swift.edges, "\(name) present edges")
        let cxxCandidates = candidates(&cxx)
        #expect(cxxCandidates.count == swift.candidates.count, "\(name) candidate count")
        for (c, s) in zip(cxxCandidates, swift.candidates) {
            #expect(table.glyphs[Int(c.templateIndex)] == s.id && Int(c.distance) == s.distance,
                    "\(name) candidate \(table.glyphs[Int(c.templateIndex)]) \(c.distance) vs \(s.id) \(s.distance)")
        }
        let cxxExtensions = extensions(&cxx).map { table.glyphs[Int($0)] }
        #expect(cxxExtensions == swift.extensions, "\(name) extensions")
        #expect(Int(cxx.strokePixelCount) == swift.strokePixelCount, "\(name) stroke pixels")
        #expect(Int(cxx.unexplainedInkPixelCount) == swift.unexplainedInkPixelCount, "\(name) unexplained ink")
        #expect(ink == swift.inkPixels, "\(name) ink pixel indices (\(ink.count) vs \(swift.inkPixels.count))")
    }

    // MARK: - Geometry

    @Test("The elementary edges are GlyphGeometry's, in the same order")
    func elementaryEdges() {
        let swift = GlyphGeometry.elementaryEdges
        #expect(Int(gc_elementary_edge_count()) == swift.count)
        for (index, edge) in swift.enumerated() {
            var cxx = gc_edge()
            #expect(gc_elementary_edge(Int32(index), &cxx))
            #expect(Int(cxx.lower) == edge.lower.rawValue && Int(cxx.upper) == edge.upper.rawValue, "edge \(index)")
        }
        var beyond = gc_edge()
        #expect(!gc_elementary_edge(Int32(swift.count), &beyond))
        #expect(!gc_elementary_edge(-1, &beyond))
    }

    @Test("The default hunt options are the Swift behaviour")
    func defaultOptions() {
        let options = gc_hunt_options_default()
        #expect(options.rowTop == 0 && options.rowBottom == 1 && options.scale == 1)
    }

    // MARK: - Node array

    @Test("gc_detect_array matches NodeArrayDetector on every fixture")
    func detectArrayMatchesSwift() throws {
        let detector = NodeArrayDetector()
        var found = 0
        for fixture in try Self.fixtures(in: Self.folders) {
            let swift = detector.detect(in: fixture.image)
            var options = gc_hunt_options_default()
            var cxx = gc_fit()
            let detected = Self.withGray(fixture.image) { gc_detect_array($0, &options, &cxx) }
            #expect(detected == (swift != nil), "\(fixture.name): C++ \(detected), Swift \(swift != nil)")
            if let swift, detected {
                found += 1
                Self.expectFitsMatch(cxx, swift, fixture.name)
            }
        }
        #expect(found > 0)
    }

    @Test("A NULL options pointer and an empty image are handled")
    func detectArrayEdgeCases() throws {
        let image = try #require(try Self.fixtures(in: ["Frames"]).first?.image)
        var cxx = gc_fit()
        let withDefaults = Self.withGray(image) { gc_detect_array($0, nil, &cxx) }
        var options = gc_hunt_options_default()
        var again = gc_fit()
        let explicit = Self.withGray(image) { gc_detect_array($0, &options, &again) }
        #expect(withDefaults == explicit)
        if withDefaults { #expect(cxx.originX == again.originX && cxx.matchedNodes == again.matchedNodes) }
        var empty = gc_fit()
        #expect(!gc_detect_array(gc_gray_image(data: nil, width: 0, height: 0, bytesPerRow: 0), nil, &empty))
    }

    // MARK: - Observation

    @Test("gc_session_observe_with_fit matches GlyphFrameRecognizer.observe", .enabled(if: ReferenceData.shapesAvailable))
    func observationMatchesSwift() throws {
        let table = try ReferenceData.glyphTable()
        let recognizer = GlyphFrameRecognizer(table: table)
        let session = try Session(table)
        let detector = NodeArrayDetector()
        var compared = 0
        for fixture in try Self.fixtures(in: Self.folders) {
            guard let fit = detector.detect(in: fixture.image) else { continue }
            let swift = recognizer.observe(fixture.image, calibration: fit)
            var cxxFit = Self.gcFit(fit)
            var cxx = gc_observation()
            Self.withGray(fixture.image) { gc_session_observe_with_fit(session.pointer, $0, &cxxFit, &cxx) }
            Self.expectObservationsMatch(&cxx, ink: session.inkPixels, swift, table: table, fixture.name)
            compared += 1
        }
        #expect(compared > 0)
    }

    @Test("A fit for another frame size is a calibration mismatch", .enabled(if: ReferenceData.shapesAvailable))
    func observationMismatch() throws {
        let table = try ReferenceData.glyphTable()
        let fixture = try #require(try Self.fixtures(in: ["Frames"]).first)
        let session = try Session(table)
        var fit = gc_fit(imageWidth: 1, imageHeight: 1, originX: 0, originY: 0, sizeX: 1, sizeY: 1, nodeRadius: 1,
                         matchedNodes: 0x7FF, rootMeanSquareError: 0)
        var cxx = gc_observation()
        Self.withGray(fixture.image) { gc_session_observe_with_fit(session.pointer, $0, &fit, &cxx) }
        #expect(cxx.state == GC_STATE_CALIBRATION_MISMATCH)
        #expect(!cxx.hasCalibration && cxx.edgeCount == 0 && cxx.candidateCount == 0)
        #expect(session.inkPixels.isEmpty)
    }

    // MARK: - Session

    private struct Step {
        let frame: Int
        let time: Double
    }

    /// Feeds the same frames and times to both sessions and compares after every step.
    private static func runSessions(_ steps: [Step], frames: [Fixture], table: GlyphTable, label: String) throws
        -> [(swift: GlyphFrameObservation?, calibration: NodeArrayDetection?)] {
        var swift = GlyphFrameSession(table: table)
        let cxx = try Session(table)
        var trace: [(swift: GlyphFrameObservation?, calibration: NodeArrayDetection?)] = []
        for (index, step) in steps.enumerated() {
            let fixture = frames[step.frame]
            let name = "\(label) step \(index) \(fixture.name) t=\(step.time)"
            let observation = swift.observe(fixture.image, at: step.time)
            var result = gc_session_result()
            withGray(fixture.image) { gc_session_observe(cxx.pointer, $0, step.time, &result) }
            #expect(result.hasObservation == (observation != nil), "\(name) observation presence")
            if let observation, result.hasObservation {
                expectObservationsMatch(&result.observation, ink: cxx.inkPixels, observation, table: table, name)
            }
            #expect(result.huntRan == (swift.lastGridHuntNanoseconds != nil), "\(name) hunt ran")
            #expect(result.hasValidatedAt == (swift.validatedAt != nil), "\(name) validatedAt presence")
            if let validatedAt = swift.validatedAt, result.hasValidatedAt {
                #expect(result.validatedAt == validatedAt, "\(name) validatedAt")
            }
            #expect(result.hasCalibration == (swift.calibration != nil), "\(name) calibration presence")
            if let calibration = swift.calibration, result.hasCalibration {
                expectFitsMatch(result.calibration, calibration, "\(name) calibration", tolerance: 1e-6)
            }
            trace.append((observation, swift.calibration))
        }
        return trace
    }

    @Test("The session follows GlyphFrameSession over the recording, with resets and expiry",
          .enabled(if: ReferenceData.shapesAvailable))
    func sessionMatchesSwift() throws {
        let table = try ReferenceData.glyphTable()
        let frames = try Self.fixtures(in: ["Recording"])
        try #require(frames.count >= 2)
        let steady = frames.indices.map { Step(frame: $0, time: Double($0) * 0.05) }
        let trace = try Self.runSessions(steady, frames: frames, table: table, label: "steady")
        #expect(trace.contains { $0.calibration != nil }, "the recording calibrates at least once")

        // A backwards step, then a gap over a second, then a 9 s jump: each resets.
        var clock = 0.0
        var jumpy: [Step] = []
        for (index, frame) in frames.indices.enumerated() {
            switch index {
            case 2: clock -= 0.03
            case 4: clock += 2
            case 6: clock += 9
            default: clock += 0.05
            }
            jumpy.append(Step(frame: frame, time: clock))
        }
        jumpy.append(Step(frame: frames.indices.first!, time: .infinity))
        jumpy.append(Step(frame: frames.indices.first!, time: clock + 0.05))
        _ = try Self.runSessions(jumpy, frames: frames, table: table, label: "jumpy")

        // The eight-second expiry needs a fit that cannot be revalidated: a
        // frame with a stroke on it, repeated with steps under the gap rule.
        guard let clean = trace.firstIndex(where: { $0.swift?.state == .noStroke }),
              let stroked = trace.firstIndex(where: { $0.swift != nil && $0.swift?.state != .noStroke }) else {
            print("CxxGlyphTests: no stroked recording frame; expiry exercised by the jump only")
            return
        }
        var slow: [Step] = [Step(frame: clean, time: 0)]
        for index in 1...11 { slow.append(Step(frame: stroked, time: Double(index) * 0.9)) }
        slow.append(Step(frame: clean, time: 10.3))
        let expiry = try Self.runSessions(slow, frames: frames, table: table, label: "expiry")
        #expect(expiry[0].calibration != nil)
        #expect(expiry.dropFirst().dropLast().contains { $0.calibration == nil }, "the fit expired after eight seconds")
        #expect(expiry.last?.calibration != nil, "the clean frame recalibrates")
    }

    @Test("gc_session_reset clears the fit and the ink", .enabled(if: ReferenceData.shapesAvailable))
    func sessionReset() throws {
        let table = try ReferenceData.glyphTable()
        let frames = try Self.fixtures(in: ["Recording"])
        let session = try Session(table)
        var result = gc_session_result()
        for (index, fixture) in frames.enumerated() {
            Self.withGray(fixture.image) { gc_session_observe(session.pointer, $0, Double(index) * 0.05, &result) }
        }
        gc_session_reset(session.pointer)
        #expect(session.inkPixels.isEmpty)
        Self.withGray(frames[0].image) { gc_session_observe(session.pointer, $0, 100, &result) }
        #expect(result.huntRan, "a reset session hunts on the next frame")
        if result.hasValidatedAt { #expect(result.validatedAt == 100) }
    }

    @Test("gc_session_create rejects out-of-range arguments")
    func sessionCreateBounds() {
        var options = gc_hunt_options_default()
        #expect(gc_session_create(nil, 1, 2, &options) == nil)
        #expect(gc_session_create(nil, 0, -1, &options) == nil)
        #expect(gc_session_create(nil, Int32(GC_MAX_TEMPLATES) + 1, 2, &options) == nil)
        let empty = gc_session_create(nil, 0, 2, nil)
        #expect(empty != nil)
        gc_session_destroy(empty)
    }

    // MARK: - Cuts

    private static let bandCut: gc_hunt_options = {
        var options = gc_hunt_options_default()
        options.rowTop = 0.30
        options.rowBottom = 0.85
        return options
    }()

    private static let halfCut: gc_hunt_options = {
        var options = gc_hunt_options_default()
        options.scale = 2
        return options
    }()

    @Test("The hunt band and the half-resolution hunt keep the recording's fits",
          arguments: [("band 0.30-0.85", bandCut), ("scale 2", halfCut)])
    func cutsKeepTheFit(label: String, cut: gc_hunt_options) throws {
        let detector = NodeArrayDetector()
        var swiftFound = 0, cutFound = 0, bothFound = 0, lost: [String] = [], gained: [String] = []
        var maxOriginShift = 0.0, maxSizeShift = 0.0, maxRadiusShift = 0.0
        var options = cut
        for fixture in try Self.fixtures(in: Self.folders) {
            let swift = detector.detect(in: fixture.image)
            var cxx = gc_fit()
            let detected = Self.withGray(fixture.image) { gc_detect_array($0, &options, &cxx) }
            if swift != nil { swiftFound += 1 }
            if detected { cutFound += 1 }
            switch (swift, detected) {
            case (let swift?, true):
                bothFound += 1
                maxOriginShift = max(maxOriginShift, abs(cxx.originX - swift.origin.x), abs(cxx.originY - swift.origin.y))
                maxSizeShift = max(maxSizeShift, abs(cxx.sizeX - swift.size.x), abs(cxx.sizeY - swift.size.y))
                maxRadiusShift = max(maxRadiusShift, abs(cxx.nodeRadius - swift.nodeRadius))
                if fixture.folder == "Recording" && swift.matchedNodes.count == 11 {
                    #expect(cxx.matchedNodes == 0x7FF, "\(label) \(fixture.name) matched \(cxx.matchedNodes)")
                }
            case (let swift?, false):
                lost.append(fixture.name)
                if fixture.folder == "Recording" && swift.matchedNodes.count == 11 {
                    Issue.record("\(label) lost the fit on \(fixture.name)")
                }
            case (nil, true):
                gained.append(fixture.name)
            case (nil, false):
                break
            }
        }
        print("CxxGlyphTests cut \(label): Swift fits \(swiftFound), cut fits \(cutFound), both \(bothFound); "
            + "max origin shift \(maxOriginShift) px, max size shift \(maxSizeShift) px, "
            + "max radius shift \(maxRadiusShift) px; lost \(lost); gained \(gained)")
    }

    // MARK: - Timing

    @Test("Hunt timing, default options against each cut", .enabled(if: ReferenceData.shapesAvailable))
    func huntTiming() throws {
        let table = try ReferenceData.glyphTable()
        let frames = try Self.fixtures(in: ["Recording"])
        var lines: [String] = []
        for (label, options) in [("default", gc_hunt_options_default()), ("band 0.30-0.85", Self.bandCut),
                                 ("scale 2", Self.halfCut)] {
            let session = try Session(table, hunt: options)
            var result = gc_session_result()
            var total: UInt64 = 0, hunts = 0
            for pass in 0..<3 {
                for fixture in frames {
                    gc_session_reset(session.pointer)
                    let started = DispatchTime.now().uptimeNanoseconds
                    Self.withGray(fixture.image) { gc_session_observe(session.pointer, $0, 1, &result) }
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- started
                    #expect(result.huntRan)
                    if pass > 0 { total += elapsed; hunts += 1 }
                }
            }
            lines.append("\(label): mean \(total / UInt64(max(1, hunts))) ns per gc_session_observe with a hunt over \(hunts) calls")
        }
        print("CxxGlyphTests timing (\(frames.count) Recording frames, \(frames.first?.image.width ?? 0)x\(frames.first?.image.height ?? 0)):\n  "
            + lines.joined(separator: "\n  "))
    }
}
