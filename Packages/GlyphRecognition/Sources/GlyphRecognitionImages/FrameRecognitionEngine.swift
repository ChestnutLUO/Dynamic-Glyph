import CoreGraphics
import Foundation
import GlyphRecognition

/// A captured frame's raw pixels, valid only for the duration of the call
/// they are passed to. The capture source locks the buffer around the call.
public struct FramePlanes: @unchecked Sendable {
    // Unchecked: raw pointers the caller keeps alive for the call.
    public enum Format: Sendable, Equatable {
        /// Biplanar 4:2:0: a Y plane and an interleaved CbCr plane at half
        /// resolution. Video range is 16-235.
        case nv12(videoRange: Bool)
        /// Packed 32-bit BGRA, little-endian: blue first.
        case bgra
    }

    public let format: Format
    public let width: Int
    public let height: Int
    /// The Y plane for NV12, the whole buffer for BGRA.
    public let base: UnsafeRawPointer
    public let bytesPerRow: Int
    /// The CbCr plane, NV12 only.
    public let chroma: UnsafeRawPointer?
    public let chromaBytesPerRow: Int

    public init(format: Format, width: Int, height: Int, base: UnsafeRawPointer, bytesPerRow: Int,
                chroma: UnsafeRawPointer? = nil, chromaBytesPerRow: Int = 0) {
        self.format = format
        self.width = width
        self.height = height
        self.base = base
        self.bytesPerRow = bytesPerRow
        self.chroma = chroma
        self.chromaBytesPerRow = chromaBytesPerRow
    }
}

/// One frame handed to an engine. The planes are the capture's own pixels;
/// `image` renders the frame through Core Image on first use, which the
/// Swift arm needs for every step and the text lane needs for OCR. A replay
/// of decoded pictures has no planes and only the image.
public struct FrameInput {
    public let planes: FramePlanes?
    public let image: () throws -> CGImage
    public let time: Double

    public init(planes: FramePlanes?, time: Double, image: @escaping () throws -> CGImage) {
        self.planes = planes
        self.image = image
        self.time = time
    }
}

/// What the caller wants from this frame. Mirrors the decisions
/// `LiveGlyphOutput.process` makes before the pixel steps.
public struct FrameAnalysisRequest: Sendable, Equatable {
    /// Glyph assistance is on: result check, array search and Glyph read.
    public var assistsGlyphs: Bool
    /// The pace allows the array search; a quiet screen skips it.
    public var searchesArray: Bool
    /// Gear reading is on: look for an item panel.
    public var checksGear: Bool
    /// Look for the portal screen before a hack.
    public var checksPortal: Bool
    /// Read the slot strip and the input timer from the top band.
    public var readsStrip: Bool

    public init(assistsGlyphs: Bool, searchesArray: Bool, checksGear: Bool, checksPortal: Bool, readsStrip: Bool) {
        self.assistsGlyphs = assistsGlyphs
        self.searchesArray = searchesArray
        self.checksGear = checksGear
        self.checksPortal = checksPortal
        self.readsStrip = readsStrip
    }
}

/// How long each pixel step took, in nanoseconds, for the Power section.
/// A step that did not run is nil. The names are `PowerMetric`'s.
public struct FrameStepTimings: Sendable, Equatable {
    public var conversion: UInt64?
    public var decode: UInt64?
    public var gearCheck: UInt64?
    public var portalCheck: UInt64?
    public var resultCheck: UInt64?
    public var gridHunt: UInt64?
    public var glyphRead: UInt64?
    public var slotStrip: UInt64?
    public init() {}
}

/// Everything the pixel steps found in one frame. The tracker, the text
/// lane and the displays consume this; they never see which engine made it.
public struct FrameAnalysis {
    public var gearBounds: GearDropPanelBounds?
    /// The faction of the portal screen's resonator bars, or nil when no
    /// portal screen was found or the check did not run.
    public var portalFaction: PortalFaction?
    public var portalCandidate: Bool { portalFaction != nil }
    public var resultCandidate = false
    public var observation: GlyphFrameObservation?
    /// Nil when the strip was not read (no image, or not requested).
    public var slots: Result<SlotStripReading, SlotStripRejection>?
    /// Our own floating window over one side of the slot row, when the strip
    /// was read and the full reading failed because of it.
    public var slotCover: SlotStripWindowCover?
    public var hasInputTimerBar = false
    /// The decoded top band, when the engine made one: the header reader
    /// reuses its pixels for the unchanged-header check.
    public var topBand: FrameTopBand?
    /// The frame as a CGImage, when the engine made one. The text lane needs
    /// it; an engine that works on the planes leaves it nil until asked.
    public var image: CGImage?
    public var timings = FrameStepTimings()
    public init() {}
}

/// The pixel recognition core: one of two arms of the engine A/B.
///
/// Both arms take the same frames and return the same `FrameAnalysis`, so
/// everything downstream (the presentation tracker, the result and gear
/// observers, the text lane) is shared and only the pixel work differs. The
/// Swift arm is the shipped pipeline; the C++ arm is the port and carries the
/// power cuts as options.
///
/// Not thread-safe: an engine belongs to one capture's serial queue, like
/// `GlyphFrameSession` did.
public protocol FrameRecognitionEngine: AnyObject {
    /// Short name for logs and the Power section: "swift" or "cpp".
    var name: String { get }

    /// The luma gate straight from the capture's pixels, before anything is
    /// converted. Nil for a format the engine doesn't read.
    func gate(_ planes: FramePlanes, step: Int) -> LumaGateReading?

    /// The pixel steps for one admitted frame.
    func analyze(_ input: FrameInput, request: FrameAnalysisRequest) throws -> FrameAnalysis

    /// `GlyphFrameSession.reset()`: forget the array fit.
    func resetSession()
    /// `GlyphFrameSession.validatedAt`.
    var sessionValidatedAt: Double? { get }
    /// `GlyphFrameSession.calibration`.
    var sessionCalibration: NodeArrayDetection? { get }
}

/// The Swift arm: the pipeline as shipped, step for step and in the same
/// order as `LiveGlyphOutput.process` ran it before the engines existed.
public final class SwiftFrameRecognitionEngine: FrameRecognitionEngine {
    public let name = "swift"
    private var session: GlyphFrameSession?
    private let layout: GameUILayout
    private let slotReader: SlotStripReader
    private let gateReader = LumaGate()

    /// A nil `table` reads panels only, as gear-only capture does.
    public init(table: GlyphTable?, layout: GameUILayout = GameUILayout()) {
        session = table.map(GlyphFrameSession.init(table:))
        self.layout = layout
        slotReader = SlotStripReader(layout: layout)
    }

    public func gate(_ planes: FramePlanes, step: Int) -> LumaGateReading? {
        let gate = LumaGate(step: step)
        switch planes.format {
        case .nv12(let videoRange):
            return gate.read(plane: planes.base, width: planes.width, height: planes.height,
                             bytesPerRow: planes.bytesPerRow, videoRange: videoRange)
        case .bgra:
            return gate.read(bgra: planes.base, width: planes.width, height: planes.height,
                             bytesPerRow: planes.bytesPerRow)
        }
    }

    public func analyze(_ input: FrameInput, request: FrameAnalysisRequest) throws -> FrameAnalysis {
        var analysis = FrameAnalysis()
        let conversionStarted = DispatchTime.now().uptimeNanoseconds
        let image = try input.image()
        analysis.timings.conversion = DispatchTime.now().uptimeNanoseconds &- conversionStarted
        analysis.image = image
        // A failed panel check is no reason to lose the frame for Glyphs.
        if request.checksGear {
            let started = DispatchTime.now().uptimeNanoseconds
            analysis.gearBounds = try? GearDropScreenReader().bounds(in: image)
            analysis.timings.gearCheck = DispatchTime.now().uptimeNanoseconds &- started
        }
        if request.checksPortal {
            let started = DispatchTime.now().uptimeNanoseconds
            analysis.portalFaction = (try? PortalScreenReader().faction(image)) ?? nil
            analysis.timings.portalCheck = DispatchTime.now().uptimeNanoseconds &- started
        }
        if request.assistsGlyphs {
            let decodeStarted = DispatchTime.now().uptimeNanoseconds
            let luminance = try ImageDecoder.decode(image)
            analysis.timings.decode = DispatchTime.now().uptimeNanoseconds &- decodeStarted
            let panelStarted = DispatchTime.now().uptimeNanoseconds
            analysis.resultCandidate = ResultPanelDetector().isCandidate(luminance)
            analysis.timings.resultCheck = DispatchTime.now().uptimeNanoseconds &- panelStarted
            if request.searchesArray, session != nil {
                let started = DispatchTime.now().uptimeNanoseconds
                analysis.observation = session?.observe(luminance, at: input.time)
                let total = DispatchTime.now().uptimeNanoseconds &- started
                // The session times its own hunt; the rest is the Glyph read.
                let hunt = session?.lastGridHuntNanoseconds.map { min($0, total) }
                analysis.timings.gridHunt = hunt
                analysis.timings.glyphRead = total &- (hunt ?? 0)
            }
        }
        if request.readsStrip {
            let started = DispatchTime.now().uptimeNanoseconds
            if let band = try? ImageDecoder.topBand(image, layout: layout) {
                analysis.topBand = band
                let observation = slotReader.observe(band)
                analysis.slots = observation.reading
                analysis.slotCover = observation.cover
                analysis.hasInputTimerBar = slotReader.hasTimerBar(band)
            }
            analysis.timings.slotStrip = DispatchTime.now().uptimeNanoseconds &- started
        }
        return analysis
    }

    public func resetSession() { session?.reset() }
    public var sessionValidatedAt: Double? { session?.validatedAt }
    public var sessionCalibration: NodeArrayDetection? { session?.calibration }
}
