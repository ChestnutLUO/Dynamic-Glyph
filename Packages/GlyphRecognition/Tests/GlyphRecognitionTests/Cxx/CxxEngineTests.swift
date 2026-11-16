import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import GlyphRecognition
import GlyphRecognitionCxx
import GlyphRecognitionImages
@testable import GlyphReplay

/// The C++ engine through its Swift bridge, held to the Swift arm frame by
/// frame on the fixture corpus.
@Suite("C++ engine: the bridge against the Swift arm", .serialized)
struct CxxEngineTests {
    static let folders = ["Frames", "Recording", "Phases", "Covered", "Banner", "WindowEdge", "AssistiveTouch",
                          "OneGlyph", "Results", "Gear", "PortalLevel", "Commands", "EdgeTab"]

    static let everything = FrameAnalysisRequest(assistsGlyphs: true, searchesArray: true, checksGear: true,
                                                 checksPortal: true, readsStrip: true)

    struct Fixture {
        let name: String
        let image: CGImage
    }

    static func fixtures(in folders: [String]) throws -> [Fixture] {
        var result: [Fixture] = []
        for folder in folders {
            let directory = try ReferenceData.fixturesDirectory.appendingPathComponent(folder)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { ["png", "jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
            for name in names {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let image = try #require(ImageDecoder.cgImage(from: data), "\(folder)/\(name) does not decode")
                result.append(Fixture(name: "\(folder)/\(name)", image: image))
            }
        }
        return result
    }

    /// Nil when the shapes table is missing: the engines then read panels
    /// only, and the Glyph parts are skipped as in the other suites.
    static func table() throws -> GlyphTable? {
        ReferenceData.shapesAvailable ? try ReferenceData.glyphTable() : nil
    }

    static func imageInput(_ image: CGImage, time: Double = 0) -> FrameInput {
        FrameInput(planes: nil, time: time) { image }
    }

    // MARK: - Comparisons

    static func expectFitsMatch(_ cxx: NodeArrayDetection?, _ swift: NodeArrayDetection?, _ label: String,
                                tolerance: Double = 1e-6, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((cxx == nil) == (swift == nil), "\(label): fit presence", sourceLocation: sourceLocation)
        guard let cxx, let swift else { return }
        #expect(cxx.imageWidth == swift.imageWidth && cxx.imageHeight == swift.imageHeight, "\(label): fit size",
                sourceLocation: sourceLocation)
        #expect(cxx.matchedNodes == swift.matchedNodes, "\(label): matched nodes", sourceLocation: sourceLocation)
        let shifts = [cxx.origin.x - swift.origin.x, cxx.origin.y - swift.origin.y, cxx.size.x - swift.size.x,
                      cxx.size.y - swift.size.y, cxx.nodeRadius - swift.nodeRadius,
                      cxx.rootMeanSquareError - swift.rootMeanSquareError]
        #expect(shifts.allSatisfy { abs($0) <= tolerance }, "\(label): fit \(cxx) vs \(swift)",
                sourceLocation: sourceLocation)
    }

    static func expectObservationsMatch(_ cxx: GlyphFrameObservation?, _ swift: GlyphFrameObservation?,
                                        _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((cxx == nil) == (swift == nil), "\(label): observation presence", sourceLocation: sourceLocation)
        guard let cxx, let swift else { return }
        #expect(cxx.state == swift.state, "\(label): state \(cxx.state) vs \(swift.state)",
                sourceLocation: sourceLocation)
        expectFitsMatch(cxx.calibration, swift.calibration, "\(label) calibration", sourceLocation: sourceLocation)
        #expect(cxx.evidence.map(\.edge) == swift.evidence.map(\.edge), "\(label): evidence edges",
                sourceLocation: sourceLocation)
        for (c, s) in zip(cxx.evidence, swift.evidence) {
            let worst = zip(c.samples, s.samples).map { abs($0 - $1) }.max() ?? 0
            #expect(c.samples.count == s.samples.count && worst <= 1e-9, "\(label): edge \(s.edge) samples, \(worst)",
                    sourceLocation: sourceLocation)
        }
        #expect(cxx.edges == swift.edges, "\(label): present edges", sourceLocation: sourceLocation)
        #expect(cxx.candidates == swift.candidates, "\(label): candidates", sourceLocation: sourceLocation)
        #expect(cxx.extensions == swift.extensions, "\(label): extensions", sourceLocation: sourceLocation)
        #expect(cxx.strokePixelCount == swift.strokePixelCount, "\(label): stroke pixels",
                sourceLocation: sourceLocation)
        #expect(cxx.unexplainedInkPixelCount == swift.unexplainedInkPixelCount, "\(label): unexplained ink",
                sourceLocation: sourceLocation)
        #expect(cxx.inkPixels == swift.inkPixels, "\(label): ink pixels", sourceLocation: sourceLocation)
    }

    static func expectSlotsMatch(_ cxx: Result<SlotStripReading, SlotStripRejection>?,
                                 _ swift: Result<SlotStripReading, SlotStripRejection>?, _ label: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        switch (cxx, swift) {
        case (nil, nil):
            break
        case (.success(let c)?, .success(let s)?):
            #expect(c.slotCount == s.slotCount && c.highlightedIndex == s.highlightedIndex
                    && c.hasInputTimerBar == s.hasInputTimerBar && c.isPartlyCovered == s.isPartlyCovered,
                    "\(label): slots \(c) vs \(s)", sourceLocation: sourceLocation)
            #expect(c.markerCentersX.count == s.markerCentersX.count
                    && zip(c.markerCentersX, s.markerCentersX).allSatisfy { abs($0 - $1) <= 1e-9 },
                    "\(label): marker centres \(c.markerCentersX) vs \(s.markerCentersX)",
                    sourceLocation: sourceLocation)
        case (.failure(let c)?, .failure(let s)?):
            #expect(c == s, "\(label): rejection \(c) vs \(s)", sourceLocation: sourceLocation)
        default:
            Issue.record("\(label): slots \(String(describing: cxx)) vs \(String(describing: swift))",
                         sourceLocation: sourceLocation)
        }
    }

    static func expectTopBandsMatch(_ cxx: FrameTopBand?, _ swift: FrameTopBand?, _ label: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((cxx == nil) == (swift == nil), "\(label): top band presence", sourceLocation: sourceLocation)
        guard let cxx, let swift else { return }
        #expect(cxx.frameHeight == swift.frameHeight && cxx.image.width == swift.image.width
                && cxx.image.height == swift.image.height && cxx.image.pixels == swift.image.pixels,
                "\(label): top band pixels", sourceLocation: sourceLocation)
    }

    /// Which steps ran, from the timings: their values are not compared.
    static func steps(_ timings: FrameStepTimings) -> [Bool] {
        [timings.conversion, timings.decode, timings.gearCheck, timings.portalCheck, timings.resultCheck,
         timings.gridHunt, timings.glyphRead, timings.slotStrip].map { $0 != nil }
    }

    static func expectAnalysesMatch(_ cxx: FrameAnalysis, _ swift: FrameAnalysis, _ label: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        let gear = "\(String(describing: cxx.gearBounds)) vs \(String(describing: swift.gearBounds))"
        #expect(cxx.gearBounds == swift.gearBounds, "\(label): gear \(gear)", sourceLocation: sourceLocation)
        #expect(cxx.portalFaction == swift.portalFaction, "\(label): portal", sourceLocation: sourceLocation)
        #expect(cxx.resultCandidate == swift.resultCandidate, "\(label): result", sourceLocation: sourceLocation)
        expectObservationsMatch(cxx.observation, swift.observation, label, sourceLocation: sourceLocation)
        expectSlotsMatch(cxx.slots, swift.slots, label, sourceLocation: sourceLocation)
        #expect(cxx.hasInputTimerBar == swift.hasInputTimerBar, "\(label): timer bar", sourceLocation: sourceLocation)
        expectTopBandsMatch(cxx.topBand, swift.topBand, label, sourceLocation: sourceLocation)
        #expect(steps(cxx.timings) == steps(swift.timings), "\(label): steps run", sourceLocation: sourceLocation)
        #expect((cxx.image == nil) == (swift.image == nil), "\(label): image presence", sourceLocation: sourceLocation)
    }

    static func expectSessionsMatch(_ cxx: FrameRecognitionEngine, _ swift: FrameRecognitionEngine, _ label: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(cxx.sessionValidatedAt == swift.sessionValidatedAt, "\(label): validatedAt",
                sourceLocation: sourceLocation)
        expectFitsMatch(cxx.sessionCalibration, swift.sessionCalibration, "\(label) session calibration",
                        sourceLocation: sourceLocation)
    }

    // MARK: - (a) Every fixture, from the decoded image

    @Test("Every fixture reads the same through both engines from the decoded image")
    func fixturesMatch() throws {
        let table = try Self.table()
        let fixtures = try Self.fixtures(in: Self.folders)
        #expect(fixtures.count >= 60, "fixtures went missing: \(fixtures.count)")
        var observations = 0, slots = 0, gear = 0, portal = 0, result = 0
        for fixture in fixtures {
            let swift = SwiftFrameRecognitionEngine(table: table)
            let cxx = try CxxFrameRecognitionEngine(table: table)
            let input = Self.imageInput(fixture.image)
            let expected = try swift.analyze(input, request: Self.everything)
            let actual = try cxx.analyze(input, request: Self.everything)
            Self.expectAnalysesMatch(actual, expected, fixture.name)
            Self.expectSessionsMatch(cxx, swift, fixture.name)
            if expected.observation != nil { observations += 1 }
            if case .success? = expected.slots { slots += 1 }
            if expected.gearBounds != nil { gear += 1 }
            if expected.portalCandidate { portal += 1 }
            if expected.resultCandidate { result += 1 }
        }
        print("CxxEngineTests fixtures: \(fixtures.count) compared; observations \(observations), "
              + "slot readings \(slots), gear panels \(gear), portal screens \(portal), result panels \(result)")
        if table != nil { #expect(observations > 0) }
        #expect(slots > 0 && gear > 0 && portal > 0 && result > 0, "some fixture exercises every reader")
    }

    @Test("Without a table both engines read panels only")
    func panelsOnly() throws {
        let fixture = try #require(try Self.fixtures(in: ["Recording"]).first)
        let swift = SwiftFrameRecognitionEngine(table: nil)
        let cxx = try CxxFrameRecognitionEngine(table: nil)
        let input = Self.imageInput(fixture.image)
        let actual = try cxx.analyze(input, request: Self.everything)
        Self.expectAnalysesMatch(actual, try swift.analyze(input, request: Self.everything), fixture.name)
        #expect(actual.observation == nil && actual.timings.gridHunt == nil && actual.timings.glyphRead == nil)
        #expect(cxx.sessionValidatedAt == nil && cxx.sessionCalibration == nil)
        cxx.resetSession()
    }

    // MARK: - (b) A session over the recording

    @Test("A session over the recording follows the Swift arm frame by frame", .enabled(if: ReferenceData.shapesAvailable))
    func recordingSession() throws {
        let table = try ReferenceData.glyphTable()
        let frames = try Self.fixtures(in: ["Recording"])
        try #require(frames.count >= 2)
        let swift = SwiftFrameRecognitionEngine(table: table)
        let cxx = try CxxFrameRecognitionEngine(table: table)
        var calibrated = 0
        for (index, frame) in frames.enumerated() {
            let time = Double(index) * 0.05
            let label = "\(frame.name) t=\(time)"
            let expected = try swift.analyze(Self.imageInput(frame.image, time: time), request: Self.everything)
            let actual = try cxx.analyze(Self.imageInput(frame.image, time: time), request: Self.everything)
            Self.expectObservationsMatch(actual.observation, expected.observation, label)
            Self.expectSessionsMatch(cxx, swift, label)
            if swift.sessionCalibration != nil { calibrated += 1 }
        }
        #expect(calibrated > 0, "the recording calibrates at least once")

        // The session keeps its state over frames that skip the search, and
        // a request that skips a step leaves its field empty in both arms.
        let lighter = [
            FrameAnalysisRequest(assistsGlyphs: true, searchesArray: false, checksGear: false, checksPortal: true,
                                 readsStrip: false),
            FrameAnalysisRequest(assistsGlyphs: false, searchesArray: true, checksGear: true, checksPortal: false,
                                 readsStrip: true),
            Self.everything
        ]
        for (index, frame) in frames.enumerated() {
            let time = Double(frames.count + index) * 0.05
            let request = lighter[index % lighter.count]
            let label = "\(frame.name) t=\(time) request \(index % lighter.count)"
            let expected = try swift.analyze(Self.imageInput(frame.image, time: time), request: request)
            let actual = try cxx.analyze(Self.imageInput(frame.image, time: time), request: request)
            Self.expectAnalysesMatch(actual, expected, label)
            Self.expectSessionsMatch(cxx, swift, label)
        }

        swift.resetSession()
        cxx.resetSession()
        #expect(cxx.sessionValidatedAt == nil && cxx.sessionCalibration == nil)
        let expected = try swift.analyze(Self.imageInput(frames[0].image, time: 100), request: Self.everything)
        let actual = try cxx.analyze(Self.imageInput(frames[0].image, time: 100), request: Self.everything)
        Self.expectAnalysesMatch(actual, expected, "after reset")
        Self.expectSessionsMatch(cxx, swift, "after reset")
        #expect(actual.timings.gridHunt != nil, "a reset session hunts on the next frame")
    }

    // MARK: - (c) Direct planes

    enum PlaneFormat: String, CaseIterable {
        case bgra
        case nv12Full = "nv12 full"
        case nv12Video = "nv12 video"

        var pixelFormat: OSType {
            switch self {
            case .bgra: return kCVPixelFormatType_32BGRA
            case .nv12Full: return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            case .nv12Video: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
        }
    }

    /// The fixture drawn into a capture-like pixel buffer. NV12 comes from
    /// the same BGRA drawing through the test's own BT.709 conversion, with
    /// each chroma sample the mean of its 2 x 2 block.
    static func pixelBuffer(_ image: CGImage, format: PlaneFormat) throws -> CVPixelBuffer {
        let width = image.width, height = image.height
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format.pixelFormat, nil, &created)
                == kCVReturnSuccess)
        let buffer = try #require(created)
        let bgraRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bgraRow * height)
        try bgra.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bgraRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if format == .bgra {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<bgraRow { base[y * stride + x] = bgra[y * bgraRow + x] }
            }
            return buffer
        }
        let video = format == .nv12Video
        let lumaPlane = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let chromaPlane = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let pixel = y * bgraRow + x * 4
            return (Double(bgra[pixel + 2]), Double(bgra[pixel + 1]), Double(bgra[pixel]))
        }
        func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = rgb(x, y)
                let value = luma(r, g, b)
                lumaPlane[y * lumaStride + x] = byte(video ? 16 + value * 219 / 255 : value)
            }
        }
        for cy in 0..<((height + 1) / 2) {
            for cx in 0..<((width + 1) / 2) {
                var r = 0.0, g = 0.0, b = 0.0, count = 0.0
                for y in (cy * 2)..<min(height, cy * 2 + 2) {
                    for x in (cx * 2)..<min(width, cx * 2 + 2) {
                        let pixel = rgb(x, y)
                        r += pixel.0; g += pixel.1; b += pixel.2; count += 1
                    }
                }
                r /= count; g /= count; b /= count
                let value = luma(r, g, b)
                let scale = video ? 224.0 / 255 : 1
                chromaPlane[cy * chromaStride + cx * 2] = byte(128 + (b - value) / 1.8556 * scale)
                chromaPlane[cy * chromaStride + cx * 2 + 1] = byte(128 + (r - value) / 1.5748 * scale)
            }
        }
        return buffer
    }

    /// The locked buffer as the capture hands it to an engine.
    static func withPlanes<R>(_ buffer: CVPixelBuffer, format: PlaneFormat, _ body: (FramePlanes) throws -> R) throws -> R {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let planes: FramePlanes
        switch format {
        case .bgra:
            planes = FramePlanes(format: .bgra, width: width, height: height,
                                 base: UnsafeRawPointer(try #require(CVPixelBufferGetBaseAddress(buffer))),
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        case .nv12Full, .nv12Video:
            planes = FramePlanes(format: .nv12(videoRange: format == .nv12Video), width: width, height: height,
                                 base: UnsafeRawPointer(try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))),
                                 bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                                 chroma: CVPixelBufferGetBaseAddressOfPlane(buffer, 1).map(UnsafeRawPointer.init),
                                 chromaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        }
        return try body(planes)
    }

    static func swiftGate(_ planes: FramePlanes, step: Int) -> LumaGateReading? {
        switch planes.format {
        case .bgra:
            return LumaGate(step: step).read(bgra: planes.base, width: planes.width, height: planes.height,
                                             bytesPerRow: planes.bytesPerRow)
        case .nv12(let videoRange):
            return LumaGate(step: step).read(plane: planes.base, width: planes.width, height: planes.height,
                                             bytesPerRow: planes.bytesPerRow, videoRange: videoRange)
        }
    }

    static func describe(_ slots: Result<SlotStripReading, SlotStripRejection>?) -> String {
        switch slots {
        case nil: return "none"
        case .success(let reading)?:
            return "\(reading.slotCount) slots, lit \(reading.highlightedIndex.map(String.init) ?? "-")"
        case .failure(let rejection)?: return rejection.rawValue
        }
    }

    static func slotStatus(_ slots: Result<SlotStripReading, SlotStripRejection>?) -> String {
        switch slots {
        case nil: return "none"
        case .success?: return "ok"
        case .failure(let rejection)?: return rejection.rawValue
        }
    }

    @Test("Direct planes: no image, the gate on the same memory, and recognition against the Swift arm")
    func directPlanes() throws {
        let table = try Self.table()
        var chosen: [Fixture] = Array(try Self.fixtures(in: ["Recording"]).prefix(2))
        for folder in ["Phases", "Results", "Gear", "PortalLevel", "Commands"] {
            chosen += try Self.fixtures(in: [folder]).prefix(1)
        }
        var disagreements: [String] = []
        for fixture in chosen {
            let expected = try SwiftFrameRecognitionEngine(table: table)
                .analyze(Self.imageInput(fixture.image), request: Self.everything)
            for format in PlaneFormat.allCases {
                let label = "\(format.rawValue) \(fixture.name)"
                let buffer = try Self.pixelBuffer(fixture.image, format: format)
                let engine = try CxxFrameRecognitionEngine(table: table, cuts: .directPlanes)
                var rendered = false
                let actual = try Self.withPlanes(buffer, format: format) { planes in
                    for step in [1, 4] {
                        #expect(engine.gate(planes, step: step) == Self.swiftGate(planes, step: step),
                                "\(label): gate at step \(step)")
                    }
                    return try engine.analyze(FrameInput(planes: planes, time: 0) {
                        rendered = true
                        return fixture.image
                    }, request: Self.everything)
                }
                #expect(!rendered, "\(label): the image was rendered")
                #expect(actual.image == nil && actual.timings.conversion == nil, "\(label): image or conversion")
                #expect(actual.topBand?.frameHeight == fixture.image.height
                        && actual.topBand?.image.width == fixture.image.width, "\(label): top band size")
                if format == .bgra {
                    // The colour readers see exactly the decoded pixels in
                    // place; only the luma differs from Core Graphics' grey.
                    #expect(actual.gearBounds == expected.gearBounds, "\(label): gear")
                    #expect(actual.portalFaction == expected.portalFaction, "\(label): portal")
                    Self.expectSlotsMatch(actual.slots, expected.slots, label)
                    #expect(actual.hasInputTimerBar == expected.hasInputTimerBar, "\(label): timer")
                    Self.expectTopBandsMatch(actual.topBand, expected.topBand, label)
                }
                let swiftState = expected.observation?.state.rawValue ?? "none"
                let cxxState = actual.observation?.state.rawValue ?? "none"
                print("direct-planes \(label): result \(actual.resultCandidate)/\(expected.resultCandidate), "
                      + "gear \(actual.gearBounds != nil)/\(expected.gearBounds != nil), "
                      + "portal \(actual.portalCandidate)/\(expected.portalCandidate), "
                      + "observation \(cxxState)/\(swiftState), "
                      + "candidates \(actual.observation?.candidates.map(\.id.name) ?? [])/"
                      + "\(expected.observation?.candidates.map(\.id.name) ?? []), "
                      + "slots \(Self.describe(actual.slots))/\(Self.describe(expected.slots)), "
                      + "timer \(actual.hasInputTimerBar)/\(expected.hasInputTimerBar) (planes/Swift)")
                if cxxState != swiftState || Self.slotStatus(actual.slots) != Self.slotStatus(expected.slots) {
                    disagreements.append(label)
                }
            }
        }
        print("direct-planes disagreements on observation state or slot status: "
              + (disagreements.isEmpty ? "none" : disagreements.joined(separator: "; ")))
    }

    @Test("Report: a direct-planes session over the recording against the Swift arm",
          .enabled(if: ReferenceData.shapesAvailable))
    func directPlanesSession() throws {
        let table = try ReferenceData.glyphTable()
        let frames = try Self.fixtures(in: ["Recording"])
        for format in PlaneFormat.allCases {
            let swift = SwiftFrameRecognitionEngine(table: table)
            let cxx = try CxxFrameRecognitionEngine(table: table, cuts: .directPlanes)
            var rows: [String] = [], differing = 0, largestShift = 0.0
            for (index, frame) in frames.enumerated() {
                let time = Double(index) * 0.05
                let expected = try swift.analyze(Self.imageInput(frame.image, time: time), request: Self.everything)
                let buffer = try Self.pixelBuffer(frame.image, format: format)
                var rendered = false
                let actual = try Self.withPlanes(buffer, format: format) { planes in
                    try cxx.analyze(FrameInput(planes: planes, time: time) {
                        rendered = true
                        return frame.image
                    }, request: Self.everything)
                }
                #expect(!rendered, "\(format.rawValue) \(frame.name): the image was rendered")
                let c = actual.observation, s = expected.observation
                if c?.state != s?.state || c?.candidates != s?.candidates { differing += 1 }
                if let cf = cxx.sessionCalibration, let sf = swift.sessionCalibration {
                    largestShift = max(largestShift, abs(cf.origin.x - sf.origin.x), abs(cf.origin.y - sf.origin.y),
                                       abs(cf.size.x - sf.size.x), abs(cf.size.y - sf.size.y))
                }
                func summary(_ observation: GlyphFrameObservation?) -> String {
                    guard let observation else { return "none" }
                    let exact = observation.exactMatches.map(\.name).joined(separator: ",")
                    return "\(observation.state.rawValue) [\(exact)] \(observation.candidates.count) candidates"
                }
                rows.append("\(frame.name): \(summary(c)) / \(summary(s))")
            }
            print("direct-planes session \(format.rawValue) (planes / Swift): \(differing) of \(frames.count) frames "
                  + "differ in state or candidates; largest fit shift \(largestShift) px\n  "
                  + rows.joined(separator: "\n  "))
        }
    }

    @Test("Direct planes keep a band the caller still holds, and refuse malformed planes")
    func directPlaneBuffers() throws {
        let frames = try Self.fixtures(in: ["Recording"])
        try #require(frames.count >= 2)
        let engine = try CxxFrameRecognitionEngine(table: nil, cuts: .directPlanes)
        let readsStrip = FrameAnalysisRequest(assistsGlyphs: true, searchesArray: true, checksGear: false,
                                              checksPortal: false, readsStrip: true)
        var bands: [FrameTopBand] = []
        for frame in [frames[0], frames.last!, frames[0]] {
            let buffer = try Self.pixelBuffer(frame.image, format: .nv12Full)
            let analysis = try Self.withPlanes(buffer, format: .nv12Full) { planes in
                try engine.analyze(FrameInput(planes: planes, time: 0) { frame.image }, request: readsStrip)
            }
            bands.append(try #require(analysis.topBand))
        }
        #expect(bands[0].image.pixels == bands[2].image.pixels, "the same frame gives the same band")
        #expect(bands[0].image.pixels != bands[1].image.pixels, "a later frame did not overwrite a kept band")

        let pixel: [UInt8] = [0, 0, 0, 0]
        try pixel.withUnsafeBytes { bytes in
            let base = try #require(bytes.baseAddress)
            let noChroma = FramePlanes(format: .nv12(videoRange: false), width: 1, height: 1, base: base, bytesPerRow: 1)
            let shortRows = FramePlanes(format: .bgra, width: 2, height: 1, base: base, bytesPerRow: 4)
            for planes in [noChroma, shortRows] {
                #expect(throws: CxxFrameRecognitionEngine.PlaneError.self) {
                    try engine.analyze(FrameInput(planes: planes, time: 0) { frames[0].image }, request: readsStrip)
                }
                #expect(engine.gate(planes, step: 4) == nil)
            }
        }
    }

    @Test("Direct planes without planes read the image, as the Swift arm does")
    func directPlanesWithoutPlanes() throws {
        let table = try Self.table()
        let fixture = try #require(try Self.fixtures(in: ["Recording"]).first)
        var rendered = false
        let input = FrameInput(planes: nil, time: 0) {
            rendered = true
            return fixture.image
        }
        let actual = try CxxFrameRecognitionEngine(table: table, cuts: .directPlanes).analyze(input, request: Self.everything)
        #expect(rendered && actual.image != nil)
        let expected = try SwiftFrameRecognitionEngine(table: table).analyze(Self.imageInput(fixture.image),
                                                                             request: Self.everything)
        Self.expectAnalysesMatch(actual, expected, fixture.name)
    }

    // MARK: - (d) Hunt cuts through the engine

    @Test("The hunt band and the half-resolution hunt keep the recording's fits through the engine",
          .enabled(if: ReferenceData.shapesAvailable),
          arguments: [("huntBand", CxxEngineCuts.huntBand), ("huntHalf", CxxEngineCuts.huntHalf)])
    func huntCuts(label: String, cut: CxxEngineCuts) throws {
        let table = try ReferenceData.glyphTable()
        let frames = try Self.fixtures(in: ["Recording"])
        let swift = SwiftFrameRecognitionEngine(table: table)
        let cxx = try CxxFrameRecognitionEngine(table: table, cuts: cut)
        var largestShift = 0.0, fits = 0
        for (index, frame) in frames.enumerated() {
            let time = Double(index) * 0.05
            let name = "\(label) \(frame.name)"
            let expected = try swift.analyze(Self.imageInput(frame.image, time: time), request: Self.everything)
            let actual = try cxx.analyze(Self.imageInput(frame.image, time: time), request: Self.everything)
            #expect(actual.observation?.state == expected.observation?.state, "\(name): state")
            #expect(actual.observation?.candidates == expected.observation?.candidates, "\(name): candidates")
            #expect(cxx.sessionValidatedAt == swift.sessionValidatedAt, "\(name): validatedAt")
            #expect((cxx.sessionCalibration == nil) == (swift.sessionCalibration == nil), "\(name): calibration")
            if let c = cxx.sessionCalibration, let s = swift.sessionCalibration {
                fits += 1
                #expect(c.matchedNodes == s.matchedNodes, "\(name): matched nodes")
                largestShift = max(largestShift, abs(c.origin.x - s.origin.x), abs(c.origin.y - s.origin.y),
                                   abs(c.size.x - s.size.x), abs(c.size.y - s.size.y),
                                   abs(c.nodeRadius - s.nodeRadius))
            }
        }
        print("CxxEngineTests \(label): \(fits) fits over \(frames.count) Recording frames, "
              + "largest shift from the Swift fit \(largestShift) px")
        #expect(fits > 0)
        #expect(largestShift < 0.5, "\(label) moved the fit by \(largestShift) px")
    }

    // MARK: - (e) Version, and the replay's flags

    /// A list of `count` Glyphs, each one edge, named apart.
    static func table(glyphs count: Int) -> GlyphTable {
        let path = GlyphPath(nodes: [NodeIndex(rawValue: 0), NodeIndex(rawValue: 1)].compactMap { $0 })
        return GlyphTable(entries: Dictionary(uniqueKeysWithValues: (0..<count).map { (GlyphID("g\($0)"), path) }))
    }

    /// One Glyph whose walk crosses `edges` distinct edges. With 11 nodes, a
    /// prime count, stepping by 1, then by 2, and so on, each round visits
    /// every node and joins pairs no other step joins.
    static func table(edges: Int) -> GlyphTable {
        let steps = (1...(NodeIndex.count - 1) / 2).flatMap { step in
            (1...NodeIndex.count).map { round in round * step % NodeIndex.count }
        }
        let path = GlyphPath(nodes: ([0] + steps.prefix(edges)).compactMap(NodeIndex.init(rawValue:)))
        #expect(path.undirectedEdges.count == edges)
        return GlyphTable(entries: [GlyphID("long"): path])
    }

    @Test("A list at the core's limits makes the engine; one over either limit throws instead of stopping the app")
    func tableLimits() throws {
        #expect(CxxFrameRecognitionEngine.maxGlyphs == 512 && CxxFrameRecognitionEngine.maxGlyphEdges == 24)
        let atGlyphs = Self.table(glyphs: CxxFrameRecognitionEngine.maxGlyphs)
        try CxxFrameRecognitionEngine.check(atGlyphs)
        #expect(try CxxFrameRecognitionEngine(table: atGlyphs).name == "cpp")
        let overGlyphs = Self.table(glyphs: CxxFrameRecognitionEngine.maxGlyphs + 1)
        #expect(throws: CxxFrameRecognitionEngine.TableError.tooManyGlyphs(count: 513)) {
            try CxxFrameRecognitionEngine(table: overGlyphs)
        }
        let atEdges = Self.table(edges: CxxFrameRecognitionEngine.maxGlyphEdges)
        try CxxFrameRecognitionEngine.check(atEdges)
        #expect(try CxxFrameRecognitionEngine(table: atEdges, cuts: [.directPlanes, .huntBand, .huntHalf]).name == "cpp")
        let overEdges = Self.table(edges: CxxFrameRecognitionEngine.maxGlyphEdges + 1)
        #expect(throws: CxxFrameRecognitionEngine.TableError.tooManyEdges(glyph: GlyphID("long"), edges: 25)) {
            try CxxFrameRecognitionEngine(table: overEdges)
        }
        #expect("\(CxxFrameRecognitionEngine.TableError.tooManyGlyphs(count: 513))"
                == "513 Glyphs, the C++ engine takes at most 512")
        #expect("\(CxxFrameRecognitionEngine.TableError.tooManyEdges(glyph: GlyphID("long"), edges: 25))"
                == "long has 25 edges, the C++ engine takes at most 24")
        // Gear only has no list to refuse.
        #expect(try CxxFrameRecognitionEngine(table: nil).name == "cpp")
        // The replay refuses the C++ engine for such a list rather than run Swift under its name.
        #expect(throws: ReplayError.self) {
            try makeReplayEngine(.cpp, cuts: [], table: overEdges, layout: GameUILayout())
        }
        #expect(try makeReplayEngine(.swift, cuts: [], table: overEdges, layout: GameUILayout()).name == "swift")
    }

    @Test("The linked core is the ABI the bridge was written for")
    func version() throws {
        #expect(GlyphCore.version == GlyphCore.expectedVersion)
        #expect(try CxxFrameRecognitionEngine(table: nil).name == "cpp")
    }

    @Test("The replay's engine and cut flags parse by name and refuse C++ cuts on the Swift engine")
    func replayFlags() throws {
        #expect(try ReplayEngine.parse("cpp") == .cpp)
        #expect(throws: ReplayError.self) { try ReplayEngine.parse("rust") }
        #expect(try ReplayCut.parse("huntBand,,lazyImage,huntBand") == [.huntBand, .lazyImage])
        #expect(throws: ReplayError.self) { try ReplayCut.parse("huntBand,bogus") }
        try ReplayCut.validate([.lazyImage, .planeGate, .portalSettle, .headerStillSkip], engine: .swift)
        #expect(try ReplayCut.parse("headerStillSkip") == [.headerStillSkip])
        #expect(try ReplayCut.parse("gearSettle,portalSettle") == [.gearSettle, .portalSettle])
        try ReplayCut.validate([.gearSettle, .resultSettle], engine: .swift)
        #expect(try ReplayCut.parse("gearLeanRead") == [.gearLeanRead])
        try ReplayCut.validate([.gearLeanRead], engine: .swift)
        #expect(try ReplayCut.parse("gearLanguageSettle,gearLeanRead") == [.gearLanguageSettle, .gearLeanRead])
        try ReplayCut.validate([.gearLanguageSettle], engine: .swift)
        #expect(try ReplayCut.parse("headerStillSkip,headerWindowMask") == [.headerStillSkip, .headerWindowMask])
        try ReplayCut.validate([.headerStillSkip, .headerWindowMask], engine: .swift)
        #expect(try ReplayCut.parse("headerStillSkip,headerCoverSkip") == [.headerStillSkip, .headerCoverSkip])
        try ReplayCut.validate([.headerCoverSkip], engine: .swift)
        try ReplayCut.validate(Set(ReplayCut.allCases), engine: .cpp)
        #expect(throws: ReplayError.self) { try ReplayCut.validate([.huntHalf], engine: .swift) }
        #expect(ReplayCut.engineCuts(Set(ReplayCut.allCases)) == [.directPlanes, .huntBand, .huntHalf])
        #expect(ReplayCut.engineCuts([.lazyImage]) == [])
    }
}
