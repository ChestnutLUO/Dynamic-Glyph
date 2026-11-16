import CoreGraphics
import GlyphCoreCxx
import GlyphRecognitionImages

/// The `planeGate` cut's prefilters, in front of the drone footer's and the
/// command band's region renders. Each reads the capture's planes in place
/// and can only answer that a region certainly holds nothing for its
/// detector, which is then not rendered. Every other region is rendered and
/// detected as before, so while a prefilter passes every region its
/// detector would accept, the outcomes are the same (`RegionGateTests`).
/// Both engine arms use it: it runs beside the engine, like the region
/// renders.
public enum RegionGate {
    /// The band's brightest luma at or under which it is empty: the band
    /// detector sees nothing in a band without a grey level above 45, and
    /// Core Graphics' grey of a pixel stays within that margin of its luma.
    public static let emptyBandLuma = 30

    /// Whether the drone footer's label may hold a `DroneFooterProbe`
    /// candidate: at least half the yellow the probe asks for, counted under
    /// looser thresholds. True for planes it cannot read.
    public static func footerMayHoldCandidate(_ planes: FramePlanes) -> Bool {
        let rect = DroneFooterProbe.textRect(width: planes.width, height: planes.height)
        guard let count = yellowCount(planes, in: rect) else { return true }
        return count > footerYellowFloor(regionWidth: Int(rect.width))
    }

    /// The count `footerMayHoldCandidate` must exceed for a label region
    /// `regionWidth` wide: half the probe's floor, `9 yellow > 5 width`.
    public static func footerYellowFloor(regionWidth: Int) -> Int {
        regionWidth * 5 / 2 / 9
    }

    /// Whether the command band is certainly empty: no luma above
    /// `emptyBandLuma`. False for planes it cannot read.
    public static func bandIsEmpty(_ planes: FramePlanes) -> Bool {
        guard let brightest = maxLuma(planes, in: CommandNoticeDetector.band(width: planes.width,
                                                                             height: planes.height)) else {
            return false
        }
        return brightest <= emptyBandLuma
    }

    /// `gc_region_yellow_count` over a top-left rectangle; nil when the
    /// planes or the rectangle cannot be read.
    public static func yellowCount(_ planes: FramePlanes, in rect: CGRect) -> Int? {
        region(planes, rect) { frame, left, top, width, height in
            gc_region_yellow_count(frame, left, top, width, height)
        }
    }

    /// `gc_region_max_luma` over a top-left rectangle, in full range; nil
    /// when the planes or the rectangle cannot be read.
    public static func maxLuma(_ planes: FramePlanes, in rect: CGRect) -> Int? {
        region(planes, rect) { frame, left, top, width, height in
            gc_region_max_luma(frame, left, top, width, height)
        }
    }

    private static func region(_ planes: FramePlanes, _ rect: CGRect,
                               _ read: (gc_frame_planes, Int32, Int32, Int32, Int32) -> Int32) -> Int? {
        guard let width = Int32(exactly: planes.width), let height = Int32(exactly: planes.height),
              let bytesPerRow = Int32(exactly: planes.bytesPerRow),
              let chromaBytesPerRow = Int32(exactly: planes.chromaBytesPerRow),
              let left = Int32(exactly: rect.minX), let top = Int32(exactly: rect.minY),
              let regionWidth = Int32(exactly: rect.width), let regionHeight = Int32(exactly: rect.height) else {
            return nil
        }
        let videoRange: Bool
        switch planes.format {
        case .bgra: videoRange = false
        case .nv12(let range): videoRange = range
        }
        let frame = gc_frame_planes(base: planes.base.assumingMemoryBound(to: UInt8.self), bytesPerRow: bytesPerRow,
                                    chroma: planes.chroma?.assumingMemoryBound(to: UInt8.self),
                                    chromaBytesPerRow: chromaBytesPerRow, width: width, height: height,
                                    bgra: planes.format == .bgra, videoRange: videoRange)
        let value = read(frame, left, top, regionWidth, regionHeight)
        return value < 0 ? nil : Int(value)
    }
}
