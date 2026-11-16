import CoreGraphics
import Dispatch
import Foundation
import GlyphCoreCxx
import GlyphRecognition
import GlyphRecognitionImages

/// The ABI the bridge was written against.
public enum GlyphCore {
    /// The ABI version the linked core was built from.
    public static var version: UInt32 { gc_version() }
    /// The version this bridge was written against.
    public static let expectedVersion: UInt32 = 1
}

/// The power cuts that live inside the C++ engine, each off by default, so
/// the engine with no cuts is the port alone.
public struct CxxEngineCuts: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Luma and colour straight from the capture's planes: no Core Image
    /// render and no Core Graphics decode. Without planes the frame is read
    /// from its image as before.
    public static let directPlanes = CxxEngineCuts(rawValue: 1 << 0)
    /// The node array is hunted only in the rows the luma gate calls the
    /// array area (`LumaGate.arrayRows`).
    public static let huntBand = CxxEngineCuts(rawValue: 1 << 1)
    /// Rings are traced on every second pixel, then measured on the full
    /// pixels inside each box.
    public static let huntHalf = CxxEngineCuts(rawValue: 1 << 2)
}

/// The C++ arm of the engine A/B, over the C ABI in `glyph_core.h`.
///
/// Without `directPlanes`, or for a frame without planes, it runs the Swift
/// arm's steps in the Swift arm's order on the same Core Graphics decodes and
/// hands those buffers to the core, so its output is the Swift arm's. With
/// `directPlanes` it reads the capture's planes and never renders the image.
///
/// Not thread-safe, like every engine: one capture's serial queue owns it.
public final class CxxFrameRecognitionEngine: FrameRecognitionEngine {
    public enum PlaneError: Error, Equatable, CustomStringConvertible {
        /// The planes' sizes or strides cannot describe a frame, or an NV12
        /// frame has no chroma plane.
        case malformed(String)

        public var description: String {
            switch self {
            case .malformed(let reason): return "malformed frame planes: \(reason)"
            }
        }
    }

    /// A shape list the core cannot hold. A player can import any list, so
    /// this is the caller's to handle, never a crash: the Swift engine takes
    /// any list.
    public enum TableError: Error, Equatable, CustomStringConvertible {
        /// More Glyphs than `maxGlyphs`.
        case tooManyGlyphs(count: Int)
        /// A Glyph whose walk has more distinct edges than `maxGlyphEdges`.
        case tooManyEdges(glyph: GlyphID, edges: Int)
        /// The core refused the session for a reason the checks above do not
        /// foresee, such as memory.
        case sessionRefused(glyphs: Int)

        public var description: String {
            switch self {
            case .tooManyGlyphs(let count):
                return "\(count) Glyphs, the C++ engine takes at most \(CxxFrameRecognitionEngine.maxGlyphs)"
            case .tooManyEdges(let glyph, let edges):
                return "\(glyph.name) has \(edges) edges, the C++ engine takes at most "
                    + "\(CxxFrameRecognitionEngine.maxGlyphEdges)"
            case .sessionRefused(let glyphs):
                return "the C++ core refused a session of \(glyphs) Glyphs"
            }
        }
    }

    /// The most Glyphs a session holds, and the most distinct edges in one
    /// Glyph's walk: the core's fixed arrays, `GC_MAX_TEMPLATES` and
    /// `GC_MAX_TEMPLATE_EDGES`.
    public static let maxGlyphs = Int(GC_MAX_TEMPLATES)
    public static let maxGlyphEdges = Int(GC_MAX_TEMPLATE_EDGES)

    /// Throws the first limit `table` exceeds; the engine can be made for
    /// it when this returns.
    public static func check(_ table: GlyphTable) throws(TableError) {
        guard table.count <= maxGlyphs else { throw .tooManyGlyphs(count: table.count) }
        for id in table.glyphs {
            guard let edges = table.path(for: id)?.undirectedEdges.count, edges > maxGlyphEdges else { continue }
            throw .tooManyEdges(glyph: id, edges: edges)
        }
    }

    public let name = "cpp"
    public let cuts: CxxEngineCuts
    public private(set) var sessionValidatedAt: Double?
    public private(set) var sessionCalibration: NodeArrayDetection?

    private let layout: GameUILayout
    private var coreLayout: gc_layout
    /// Nil without a table: panels only, as gear-only capture reads.
    private let session: OpaquePointer?
    /// Template index to Glyph, in the order the session was created with.
    private let glyphs: [GlyphID]
    // Per-frame state and buffers, kept between frames and grown on demand,
    // so a steady capture allocates none of them again.
    private var sessionResult = gc_session_result()
    private var lumaBuffer: [UInt8] = []
    /// The colour bands of the frame being analysed, converted from NV12
    /// once however many checks read them.
    private var colorRows = ColorRowCache()
    /// Handed out as the frame's `FrameTopBand`. Shared with that value
    /// until the caller lets go of it, so it is copied only while kept.
    private var topBandPixels: [UInt8] = []

    /// A nil `table` reads panels only, as gear-only capture does. Throws
    /// when the core cannot hold `table` (`check(_:)`). A core built apart
    /// from this bridge stops the app: that is a build error, not input.
    public init(table: GlyphTable?, layout: GameUILayout = GameUILayout(),
                cuts: CxxEngineCuts = []) throws(TableError) {
        precondition(gc_version() == GC_VERSION && GC_VERSION == GlyphCore.expectedVersion,
                     "GlyphCore ABI mismatch: library \(gc_version()), header \(GC_VERSION), "
                     + "bridge \(GlyphCore.expectedVersion). Rebuild the core and the bridge together.")
        Self.checkElementaryEdges()
        self.layout = layout
        self.cuts = cuts
        coreLayout = Self.coreLayout(layout)
        guard let table else {
            glyphs = []
            session = nil
            return
        }
        try Self.check(table)
        // `GlyphTable.glyphs` is sorted, which is the order the Swift
        // recognizer keeps its templates in and breaks candidate ties by.
        let paths = table.glyphs.compactMap { id in table.path(for: id).map { (id, $0) } }
        glyphs = paths.map(\.0)
        let templates = paths.map { Self.template(for: $0.1) }
        var hunt = gc_hunt_options_default()
        if cuts.contains(.huntBand) {
            hunt.rowTop = LumaGate.arrayRows.lowerBound
            hunt.rowBottom = LumaGate.arrayRows.upperBound
        }
        if cuts.contains(.huntHalf) { hunt.scale = 2 }
        let created = templates.withUnsafeBufferPointer { buffer in
            gc_session_create(buffer.baseAddress, Int32(buffer.count), 2, &hunt)
        }
        guard let created else { throw .sessionRefused(glyphs: templates.count) }
        session = created
    }

    deinit {
        if let session { gc_session_destroy(session) }
    }

    // MARK: - Gate

    public func gate(_ planes: FramePlanes, step: Int) -> LumaGateReading? {
        guard let frame = try? Frame(planes) else { return nil }
        let step = Int32(clamping: max(1, step))
        var reading = gc_gate_reading()
        let found: Bool
        switch planes.format {
        case .nv12(videoRange: false):
            found = gc_gate_read(frame.plane, step, &reading)
        case .nv12(videoRange: true):
            // The core's gate reads full-range luma, so a video-range plane
            // is stretched first, with the table `LumaGate` samples through.
            found = withConvertedLuma(frame) { gc_gate_read($0, step, &reading) }
        case .bgra:
            found = gc_gate_read_bgra(frame.bgra(rows: 0..<frame.height), step, &reading)
        }
        return found ? Self.gateReading(reading) : nil
    }

    // MARK: - Analysis

    public func analyze(_ input: FrameInput, request: FrameAnalysisRequest) throws -> FrameAnalysis {
        if cuts.contains(.directPlanes), let planes = input.planes {
            return try analyze(Frame(planes), time: input.time, request: request)
        }
        return try analyzeImage(input, request: request)
    }

    /// The Swift arm's steps on the Swift arm's decodes, buffer for buffer.
    private func analyzeImage(_ input: FrameInput, request: FrameAnalysisRequest) throws -> FrameAnalysis {
        var analysis = FrameAnalysis()
        let conversionStarted = Self.now()
        let image = try input.image()
        analysis.timings.conversion = Self.now() &- conversionStarted
        analysis.image = image
        let frameHeight = Int32(clamping: image.height)
        // A failed panel check is no reason to lose the frame for Glyphs.
        if request.checksGear {
            let started = Self.now()
            var top: Int32 = 0, bottom: Int32 = 0
            gc_gear_band(frameHeight, &top, &bottom)
            analysis.gearBounds = Self.decodedBand(image, rows: top..<max(top, bottom)).flatMap { band in
                Self.withColor(band) { Self.gearBounds($0, frameHeight: frameHeight, bandTop: top) }
            }
            analysis.timings.gearCheck = Self.now() &- started
        }
        if request.checksPortal {
            let started = Self.now()
            var top: Int32 = 0, bottom: Int32 = 0
            gc_portal_band(frameHeight, &top, &bottom)
            analysis.portalFaction = Self.decodedBand(image, rows: top..<max(top, bottom)).flatMap { band in
                Self.withColor(band) { Self.faction(gc_portal_faction($0, frameHeight, top)) }
            }
            analysis.timings.portalCheck = Self.now() &- started
        }
        if request.assistsGlyphs {
            let decodeStarted = Self.now()
            let luminance = try ImageDecoder.decode(image)
            analysis.timings.decode = Self.now() &- decodeStarted
            luminance.pixels.withUnsafeBufferPointer { pixels in
                let gray = gc_gray_image(data: pixels.baseAddress, width: Int32(luminance.width),
                                         height: Int32(luminance.height), bytesPerRow: Int32(luminance.width))
                readGlyphs(gray, time: input.time, request: request, into: &analysis)
            }
        }
        if request.readsStrip {
            let started = Self.now()
            if let band = try? ImageDecoder.topBand(image, layout: layout) {
                analysis.topBand = band
                Self.withColor(band.image) { readStrip($0, frameHeight: Int32(band.frameHeight), into: &analysis) }
            }
            analysis.timings.slotStrip = Self.now() &- started
        }
        return analysis
    }

    /// The same steps on the capture's planes: no image, no Core Graphics.
    /// Luma is the Y plane in place (full range) or one conversion (video
    /// range, BGRA); colour is the BGRA buffer in place or a conversion of
    /// only the rows each reader samples.
    private func analyze(_ frame: Frame, time: Double, request: FrameAnalysisRequest) throws -> FrameAnalysis {
        var analysis = FrameAnalysis()
        var gearTop: Int32 = 0, gearBottom: Int32 = 0, portalTop: Int32 = 0, portalBottom: Int32 = 0
        gc_gear_band(frame.height, &gearTop, &gearBottom)
        gc_portal_band(frame.height, &portalTop, &portalBottom)
        let gearRows = gearTop..<max(gearTop, gearBottom), portalRows = portalTop..<max(portalTop, portalBottom)
        if case .nv12 = frame.format {
            colorRows.begin(width: frame.width, window: Self.hull(request.checksGear ? gearRows : nil,
                                                                  request.checksPortal ? portalRows : nil))
        }
        defer { colorRows.end() }
        if request.checksGear {
            let started = Self.now()
            let top = gearRows.lowerBound
            analysis.gearBounds = withColorRows(frame, gearRows) { band in
                Self.gearBounds(band, frameHeight: frame.height, bandTop: top)
            } ?? nil
            analysis.timings.gearCheck = Self.now() &- started
        }
        if request.checksPortal {
            let started = Self.now()
            let top = portalRows.lowerBound
            analysis.portalFaction = withColorRows(frame, portalRows) { band in
                Self.faction(gc_portal_faction(band, frame.height, top))
            } ?? nil
            analysis.timings.portalCheck = Self.now() &- started
        }
        if request.assistsGlyphs {
            switch frame.format {
            case .nv12(videoRange: false):
                analysis.timings.decode = 0
                readGlyphs(frame.plane, time: time, request: request, into: &analysis)
            case .nv12(videoRange: true), .bgra:
                let decodeStarted = Self.now()
                prepareLuma(frame)
                analysis.timings.decode = Self.now() &- decodeStarted
                lumaBuffer.withUnsafeBufferPointer { buffer in
                    let gray = gc_gray_image(data: buffer.baseAddress, width: frame.width, height: frame.height,
                                             bytesPerRow: frame.width)
                    readGlyphs(gray, time: time, request: request, into: &analysis)
                }
            }
        }
        if request.readsStrip {
            let started = Self.now()
            readTopBand(frame, into: &analysis)
            analysis.timings.slotStrip = Self.now() &- started
        }
        return analysis
    }

    public func resetSession() {
        if let session { gc_session_reset(session) }
        sessionValidatedAt = nil
        sessionCalibration = nil
    }

    // MARK: - Steps

    private func readGlyphs(_ gray: gc_gray_image, time: Double, request: FrameAnalysisRequest,
                            into analysis: inout FrameAnalysis) {
        let panelStarted = Self.now()
        analysis.resultCandidate = gc_result_candidate(gray)
        analysis.timings.resultCheck = Self.now() &- panelStarted
        guard request.searchesArray, let session else { return }
        let started = Self.now()
        gc_session_observe(session, gray, time, &sessionResult)
        sessionValidatedAt = sessionResult.hasValidatedAt ? sessionResult.validatedAt : nil
        sessionCalibration = sessionResult.hasCalibration ? Self.detection(sessionResult.calibration) : nil
        analysis.observation = sessionResult.hasObservation ? currentObservation(session) : nil
        let total = Self.now() &- started
        // The session times its own hunt; the rest is the Glyph read.
        let hunt = sessionResult.huntRan ? min(sessionResult.huntNanoseconds, total) : nil
        analysis.timings.gridHunt = hunt
        analysis.timings.glyphRead = total &- (hunt ?? 0)
    }

    private func readStrip(_ band: gc_color_image, frameHeight: Int32, into analysis: inout FrameAnalysis) {
        var reading = gc_slot_reading()
        gc_slot_strip_read(band, frameHeight, &coreLayout, &reading)
        analysis.slots = Self.slots(reading)
        analysis.slotCover = Self.cover(reading, layout: layout)
        analysis.hasInputTimerBar = gc_timer_bar(band, frameHeight, &coreLayout)
    }

    /// The top band from the planes, as `ImageDecoder.topBand` cuts it from
    /// an image: the first rows down to `layout.topBandBottom`, rounded up.
    private func readTopBand(_ frame: Frame, into analysis: inout FrameAnalysis) {
        let rows = min(Int(frame.height), Int((layout.topBandBottom * Double(frame.height)).rounded(.up)))
        guard rows > 0 else { return }
        let width = Int(frame.width)
        let count = width * rows * 3
        // Taken out of the member so the buffer is uniquely referenced again
        // once the previous frame's band has been released.
        var pixels = topBandPixels
        topBandPixels = []
        if pixels.count != count { pixels = [UInt8](repeating: 0, count: count) }
        pixels.withUnsafeMutableBufferPointer { out in
            switch frame.format {
            case .nv12(let videoRange):
                gc_rgb_from_nv12(frame.base, frame.bytesPerRow, frame.chroma, frame.chromaBytesPerRow, frame.width,
                                 frame.height, 0, Int32(rows), videoRange, out.baseAddress)
            case .bgra:
                Self.packRGB(fromBGRA: frame, rows: rows, into: out)
            }
        }
        switch frame.format {
        case .nv12:
            pixels.withUnsafeBufferPointer { buffer in
                readStrip(Self.rgb(buffer.baseAddress, width: frame.width, rows: Int32(rows)), frameHeight: frame.height,
                          into: &analysis)
            }
        case .bgra:
            readStrip(frame.bgra(rows: 0..<Int32(rows)), frameHeight: frame.height, into: &analysis)
        }
        if let image = try? ColorImage(width: width, height: rows, pixels: pixels) {
            analysis.topBand = FrameTopBand(image: image, frameHeight: Int(frame.height))
        }
        topBandPixels = pixels
    }

    /// Frame rows `rows` as a colour image: the BGRA buffer in place, or an
    /// NV12 conversion of those rows, shared with the frame's other checks
    /// through `colorRows`. Nil for no rows, as the Swift readers get no
    /// band to read then.
    private func withColorRows<R>(_ frame: Frame, _ rows: Range<Int32>, _ body: (gc_color_image) -> R) -> R? {
        guard !rows.isEmpty else { return nil }
        switch frame.format {
        case .bgra:
            return body(frame.bgra(rows: rows))
        case .nv12(let videoRange):
            return colorRows.withRows(rows, width: frame.width, convert: { run, out in
                gc_rgb_from_nv12(frame.base, frame.bytesPerRow, frame.chroma, frame.chromaBytesPerRow, frame.width,
                                 frame.height, run.lowerBound, Int32(run.count), videoRange, out)
            }, { pixels in
                body(Self.rgb(pixels, width: frame.width, rows: Int32(rows.count)))
            })
        }
    }

    /// Packed full-range luma for a video-range plane or a BGRA buffer, in
    /// `lumaBuffer`.
    private func prepareLuma(_ frame: Frame) {
        let count = Int(frame.width) * Int(frame.height)
        if lumaBuffer.count < count { lumaBuffer = [UInt8](repeating: 0, count: count) }
        lumaBuffer.withUnsafeMutableBufferPointer { out in
            switch frame.format {
            case .nv12(let videoRange):
                gc_luma_from_plane(frame.base, frame.width, frame.height, frame.bytesPerRow, videoRange,
                                   out.baseAddress)
            case .bgra:
                gc_luma_from_bgra(frame.base, frame.width, frame.height, frame.bytesPerRow, out.baseAddress)
            }
        }
    }

    private func withConvertedLuma<R>(_ frame: Frame, _ body: (gc_gray_image) -> R) -> R {
        prepareLuma(frame)
        return lumaBuffer.withUnsafeBufferPointer { buffer in
            body(gc_gray_image(data: buffer.baseAddress, width: frame.width, height: frame.height,
                               bytesPerRow: frame.width))
        }
    }

    private func currentObservation(_ session: OpaquePointer) -> GlyphFrameObservation? {
        var inkCount: Int32 = 0
        let ink = gc_session_ink_pixels(session, &inkCount)
        let inkPixels = ink.map { base in UnsafeBufferPointer(start: base, count: Int(inkCount)).map(Int.init) } ?? []
        return withUnsafePointer(to: &sessionResult.observation) { pointer in
            Self.observation(pointer, glyphs: glyphs, inkPixels: inkPixels)
        }
    }

    // MARK: - Planes

    /// Validated planes, with the sizes the ABI takes.
    private struct Frame {
        let format: FramePlanes.Format
        let width: Int32
        let height: Int32
        let base: UnsafePointer<UInt8>
        let bytesPerRow: Int32
        let chroma: UnsafePointer<UInt8>?
        let chromaBytesPerRow: Int32

        init(_ planes: FramePlanes) throws {
            guard planes.width > 0, planes.height > 0, let width = Int32(exactly: planes.width),
                  let height = Int32(exactly: planes.height), let bytesPerRow = Int32(exactly: planes.bytesPerRow)
            else { throw PlaneError.malformed("\(planes.width)x\(planes.height), \(planes.bytesPerRow) bytes per row") }
            format = planes.format
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
            base = planes.base.assumingMemoryBound(to: UInt8.self)
            switch planes.format {
            case .bgra:
                guard planes.bytesPerRow >= planes.width * 4 else {
                    throw PlaneError.malformed("BGRA rows of \(planes.bytesPerRow) bytes for \(planes.width) pixels")
                }
                chroma = nil
                chromaBytesPerRow = 0
            case .nv12:
                let chromaRow = (planes.width + 1) / 2 * 2
                guard planes.bytesPerRow >= planes.width, let chromaPlane = planes.chroma,
                      planes.chromaBytesPerRow >= chromaRow,
                      let chromaBytesPerRow = Int32(exactly: planes.chromaBytesPerRow) else {
                    throw PlaneError.malformed("NV12 rows of \(planes.bytesPerRow) and \(planes.chromaBytesPerRow) "
                                               + "bytes for \(planes.width) pixels, chroma "
                                               + (planes.chroma == nil ? "missing" : "present"))
                }
                chroma = chromaPlane.assumingMemoryBound(to: UInt8.self)
                self.chromaBytesPerRow = chromaBytesPerRow
            }
        }

        /// The Y plane in place, which is the luma of a full-range frame.
        var plane: gc_gray_image {
            gc_gray_image(data: base, width: width, height: height, bytesPerRow: bytesPerRow)
        }

        /// Frame rows `rows` of a BGRA buffer in place.
        func bgra(rows: Range<Int32>) -> gc_color_image {
            gc_color_image(data: base + Int(rows.lowerBound) * Int(bytesPerRow), width: width,
                           height: Int32(rows.count), bytesPerRow: bytesPerRow, bytesPerPixel: 4,
                           redOffset: 2, greenOffset: 1, blueOffset: 0)
        }
    }

    private static func packRGB(fromBGRA frame: Frame, rows: Int, into out: UnsafeMutableBufferPointer<UInt8>) {
        guard let destination = out.baseAddress else { return }
        let width = Int(frame.width), stride = Int(frame.bytesPerRow)
        for y in 0..<rows {
            let source = frame.base + y * stride
            let row = destination + y * width * 3
            for x in 0..<width {
                row[x * 3] = source[x * 4 + 2]
                row[x * 3 + 1] = source[x * 4 + 1]
                row[x * 3 + 2] = source[x * 4]
            }
        }
    }

    // MARK: - Conversions

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Frame rows decoded exactly as `GearDropScreenReader.bounds(in:)` and
    /// `PortalScreenReader.faction(_:)` decode them; nil where those throw.
    private static func decodedBand(_ image: CGImage, rows: Range<Int32>) -> ColorImage? {
        try? ImageDecoder.decodeColor(image, in: CGRect(x: 0, y: Int(rows.lowerBound), width: image.width,
                                                        height: rows.count))
    }

    /// The rows from the first to the last of either range; empty for none.
    private static func hull(_ first: Range<Int32>?, _ second: Range<Int32>?) -> Range<Int32> {
        switch (first.flatMap { $0.isEmpty ? nil : $0 }, second.flatMap { $0.isEmpty ? nil : $0 }) {
        case let (first?, second?):
            return min(first.lowerBound, second.lowerBound)..<max(first.upperBound, second.upperBound)
        case let (only?, nil), let (nil, only?):
            return only
        case (nil, nil):
            return 0..<0
        }
    }

    private static func rgb(_ data: UnsafePointer<UInt8>?, width: Int32, rows: Int32) -> gc_color_image {
        gc_color_image(data: data, width: width, height: rows, bytesPerRow: width * 3, bytesPerPixel: 3, redOffset: 0,
                       greenOffset: 1, blueOffset: 2)
    }

    private static func withColor<R>(_ image: ColorImage, _ body: (gc_color_image) -> R) -> R {
        image.pixels.withUnsafeBufferPointer { pixels in
            body(rgb(pixels.baseAddress, width: Int32(image.width), rows: Int32(image.height)))
        }
    }

    private static func gearBounds(_ band: gc_color_image, frameHeight: Int32, bandTop: Int32) -> GearDropPanelBounds? {
        var bounds = gc_panel_bounds()
        guard gc_gear_candidate(band, frameHeight, bandTop, &bounds) else { return nil }
        return GearDropPanelBounds(top: bounds.top, bottom: bounds.bottom)
    }

    private static func faction(_ faction: gc_faction) -> PortalFaction? {
        switch faction {
        case GC_FACTION_RESISTANCE: return .resistance
        case GC_FACTION_ENLIGHTENED: return .enlightened
        case GC_FACTION_MACHINA: return .machina
        default: return nil
        }
    }

    private static func gateReading(_ reading: gc_gate_reading) -> LumaGateReading {
        var reading = reading
        let cells = withUnsafeBytes(of: &reading.cells) { Array($0) }
        return LumaGateReading.bridged(darkFraction: reading.darkFraction, brightFraction: reading.brightFraction,
                               cells: cells, isCandidate: reading.isCandidate)
    }

    static func detection(_ fit: gc_fit) -> NodeArrayDetection {
        let matched = Set(NodeIndex.all.filter { fit.matchedNodes & (UInt16(1) << UInt16($0.rawValue)) != 0 })
        return NodeArrayDetection.bridged(imageWidth: Int(fit.imageWidth), imageHeight: Int(fit.imageHeight),
                                  origin: SIMD2(fit.originX, fit.originY), size: SIMD2(fit.sizeX, fit.sizeY),
                                  nodeRadius: fit.nodeRadius, matchedNodes: matched,
                                  rootMeanSquareError: fit.rootMeanSquareError)
    }

    private static func state(_ state: gc_observation_state) -> GlyphFrameObservation.State? {
        switch state {
        case GC_STATE_CALIBRATION_UNAVAILABLE: return .calibrationUnavailable
        case GC_STATE_CALIBRATION_MISMATCH: return .calibrationMismatch
        case GC_STATE_NO_STROKE: return .noStroke
        case GC_STATE_UNRECOGNIZED_STROKE: return .unrecognizedStroke
        case GC_STATE_UNEXPLAINED_INK: return .unexplainedInk
        case GC_STATE_AMBIGUOUS_SHAPE: return .ambiguousShape
        case GC_STATE_UNIQUE_VISIBLE_SHAPE: return .uniqueVisibleShape
        default: return nil
        }
    }

    private static func observation(_ pointer: UnsafePointer<gc_observation>, glyphs: [GlyphID],
                                    inkPixels: [Int]) -> GlyphFrameObservation? {
        guard let state = state(pointer.pointee.state) else { return nil }
        let raw = UnsafeRawPointer(pointer)
        let samplesPerEdge = Int(GC_EDGE_SAMPLES)
        let samples = (raw + MemoryLayout<gc_observation>.offset(of: \.samples)!).assumingMemoryBound(to: Double.self)
        let edges = GlyphGeometry.elementaryEdges
        let evidence = (0..<min(Int(pointer.pointee.edgeCount), edges.count)).map { index in
            GlyphEdgeEvidence.bridged(edge: edges[index],
                              samples: Array(UnsafeBufferPointer(start: samples + index * samplesPerEdge,
                                                                 count: samplesPerEdge)))
        }
        func glyph(_ index: Int32) -> GlyphID? {
            glyphs.indices.contains(Int(index)) ? glyphs[Int(index)] : nil
        }
        let candidateBase = (raw + MemoryLayout<gc_observation>.offset(of: \.candidates)!)
            .assumingMemoryBound(to: gc_candidate.self)
        let candidates = UnsafeBufferPointer(start: candidateBase, count: Int(pointer.pointee.candidateCount))
            .compactMap { candidate in
                glyph(candidate.templateIndex).map { GlyphCandidate(id: $0, distance: Int(candidate.distance)) }
            }
        let extensionBase = (raw + MemoryLayout<gc_observation>.offset(of: \.extensions)!)
            .assumingMemoryBound(to: Int32.self)
        let extensions = UnsafeBufferPointer(start: extensionBase, count: Int(pointer.pointee.extensionCount))
            .compactMap(glyph)
        return GlyphFrameObservation.bridged(
            state: state,
            calibration: pointer.pointee.hasCalibration ? detection(pointer.pointee.calibration) : nil,
            evidence: evidence, strokePixelCount: Int(pointer.pointee.strokePixelCount),
            unexplainedInkPixelCount: Int(pointer.pointee.unexplainedInkPixelCount), candidates: candidates,
            extensions: extensions, inkPixels: inkPixels)
    }

    /// `SlotStripObservation.cover` from the C reading's cover fields.
    static func cover(_ reading: gc_slot_reading, layout: GameUILayout) -> SlotStripWindowCover? {
        let side: SlotStripWindowCover.Side
        switch reading.windowSide {
        case GC_WINDOW_LEFT: side = .left
        case GC_WINDOW_RIGHT: side = .right
        default: return nil
        }
        var row: PartialSlotStripReading?
        if reading.hasPartialRow {
            var reading = reading
            let count = max(0, min(Int(reading.partialCount), Int(GC_MAX_SLOTS)))
            let centers = withUnsafeBytes(of: &reading.partialCentersX) {
                Array($0.bindMemory(to: Double.self).prefix(count))
            }
            row = PartialSlotStripReading(
                markerCentersX: centers,
                highlightedMarker: reading.partialHighlightedMarker >= 0 ? Int(reading.partialHighlightedMarker) : nil,
                coveredFrom: reading.coveredFrom, coveredTo: reading.coveredTo,
                centerPitch: layout.slotCenterPitch, centerTolerance: layout.slotCenterTolerance)
        }
        return SlotStripWindowCover(side: side, coveredFrom: reading.coveredFrom, coveredTo: reading.coveredTo,
                                    row: row, hasPartialInputTimerBar: reading.hasPartialTimerBar)
    }

    static func slots(_ reading: gc_slot_reading) -> Result<SlotStripReading, SlotStripRejection> {
        let rejection: SlotStripRejection
        switch reading.status {
        case GC_SLOT_OK:
            var reading = reading
            let count = max(0, min(Int(reading.slotCount), Int(GC_MAX_SLOTS)))
            let centers = withUnsafeBytes(of: &reading.markerCentersX) { Array($0.bindMemory(to: Double.self).prefix(count)) }
            return .success(SlotStripReading(
                slotCount: Int(reading.slotCount),
                highlightedIndex: reading.highlightedIndex >= 0 ? Int(reading.highlightedIndex) : nil,
                markerCentersX: centers, hasInputTimerBar: reading.hasInputTimerBar,
                isPartlyCovered: reading.isPartlyCovered))
        case GC_SLOT_NO_MARKERS: rejection = .noMarkers
        case GC_SLOT_TOO_MANY_MARKERS: rejection = .tooManyMarkers
        case GC_SLOT_UNEVEN_SPACING: rejection = .unevenSpacing
        case GC_SLOT_INCONSISTENT_MARKER_WIDTHS: rejection = .inconsistentMarkerWidths
        case GC_SLOT_MULTIPLE_HIGHLIGHTS: rejection = .multipleHighlights
        case GC_SLOT_INCOMPLETE_MARKER_HEIGHT: rejection = .incompleteMarkerHeight
        case GC_SLOT_INCOMPLETE_STRIP: rejection = .incompleteStrip
        case GC_SLOT_COVERED_BY_OVERLAY: rejection = .coveredByOverlay
        default: rejection = .bandUnavailable
        }
        return .failure(rejection)
    }

    private static func coreLayout(_ layout: GameUILayout) -> gc_layout {
        gc_layout(headerTextTop: layout.headerTextTop, headerTextBottom: layout.headerTextBottom,
                  slotStripTop: layout.slotStripTop, slotStripBottom: layout.slotStripBottom,
                  inputTimerBarTop: layout.inputTimerBarTop, inputTimerBarBottom: layout.inputTimerBarBottom,
                  inputTimerBarMinimumWidth: layout.inputTimerBarMinimumWidth,
                  slotMarkerMinimumWidth: layout.slotMarkerMinimumWidth,
                  slotMarkerMaximumWidth: layout.slotMarkerMaximumWidth,
                  slotMarkerMinimumColumnHits: Int32(clamping: layout.slotMarkerMinimumColumnHits),
                  slotPitchTolerance: layout.slotPitchTolerance, slotCenterPitch: layout.slotCenterPitch,
                  slotCenterTolerance: layout.slotCenterTolerance, inputTimerTrackLeft: layout.inputTimerTrackLeft,
                  inputTimerTrackRight: layout.inputTimerTrackRight,
                  inputTimerEndpointTolerance: layout.inputTimerEndpointTolerance,
                  bannerMinimumRowCoverage: layout.bannerMinimumRowCoverage,
                  bannerMinimumHeight: layout.bannerMinimumHeight,
                  coveredMarkerMinimumHeight: layout.coveredMarkerMinimumHeight)
    }

    private static func template(for path: GlyphPath) -> gc_template {
        // At most `maxGlyphEdges`: `init` checked the table first.
        let edges = path.undirectedEdges
            .sorted { ($0.lower.rawValue, $0.upper.rawValue) < ($1.lower.rawValue, $1.upper.rawValue) }
        var template = gc_template()
        withUnsafeMutableBytes(of: &template.edges) { bytes in
            let slots = bytes.bindMemory(to: gc_edge.self)
            for (index, edge) in edges.enumerated() {
                slots[index] = gc_edge(lower: UInt8(edge.lower.rawValue), upper: UInt8(edge.upper.rawValue))
            }
        }
        template.edgeCount = Int32(edges.count)
        return template
    }

    /// Observation samples arrive in the core's edge order and are labelled
    /// with `GlyphGeometry`'s; the two must be the same list.
    private static func checkElementaryEdges() {
        let edges = GlyphGeometry.elementaryEdges
        precondition(Int(gc_elementary_edge_count()) == edges.count,
                     "GlyphCore has \(gc_elementary_edge_count()) elementary edges, GlyphGeometry \(edges.count)")
        for (index, edge) in edges.enumerated() {
            var core = gc_edge()
            precondition(gc_elementary_edge(Int32(index), &core)
                         && Int(core.lower) == edge.lower.rawValue && Int(core.upper) == edge.upper.rawValue,
                         "GlyphCore's elementary edge \(index) is not GlyphGeometry's \(edge)")
        }
    }
}
