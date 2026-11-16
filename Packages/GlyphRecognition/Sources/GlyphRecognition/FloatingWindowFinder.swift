/// Finds the app's own Picture in Picture window in the top band of a
/// captured frame, so that a still check can leave the window's pixels out.
///
/// iOS tells an app nothing of where its Picture in Picture window is, and
/// the screen capture includes it. `GlyphDisplayRenderer` draws the window
/// as a ring of one status colour, about 8% of the window's height thick,
/// round-cornered, around a dark interior. The finder looks for that ring:
/// two horizontal ring bands of one colour, each one ring thick, the lower
/// at least two rings below the upper; both sides one ring thick in the same
/// colour, found on three rows clear of the corners; a dark interior.
///
/// The rules and their thresholds were measured for the header window mask
/// and tuned on the top bands of 21 recordings, about 46,000 frames at 562
/// to 603 pixels wide. What it finds is a window over the header in 17 of
/// them; game boxes, tabs, bars and home screens it rejects. Anything it
/// cannot place returns nil, and a caller then compares every pixel as before.
public enum FloatingWindowFinder {
    /// The window's rectangle in the band's pixels: `left` and `top`
    /// inclusive, `right` and `bottom` exclusive.
    public struct Window: Equatable, Sendable {
        public let left: Int
        public let top: Int
        public let right: Int
        public let bottom: Int

        public init(left: Int, top: Int, right: Int, bottom: Int) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }

        /// The largest distance, in pixels, between this window's edges and
        /// `other`'s.
        public func shift(from other: Window) -> Int {
            max(abs(left - other.left), abs(top - other.top), abs(right - other.right), abs(bottom - other.bottom))
        }

        /// The smallest rectangle holding both windows.
        public func union(_ other: Window) -> Window {
            Window(left: min(left, other.left), top: min(top, other.top),
                   right: max(right, other.right), bottom: max(bottom, other.bottom))
        }
    }

    /// Largest channel step between neighbouring pixels along a ring row.
    static let smoothStep = 24
    /// Least grey of a ring pixel. The dimmest status colour, the idle grey,
    /// stays well above it.
    static let ringFloor = 60
    /// Least length of a ring row's straight run, as a share of the width.
    static let minimumRun = 0.45
    /// Largest channel distance between the two ring bands, and between a
    /// pixel and the ring's colour for the pixel to count as ring.
    static let colourTolerance = 48.0
    /// Least amount the interior's median grey stays below the ring's.
    static let interiorContrast = 40.0
    /// Thickest ring band, as a share of the frame's height (at least two
    /// rows).
    static let maximumRingShare = 0.015
    /// Each ring band's thickness over the window's height. In those
    /// recordings windows measured 0.046 to 0.088; game boxes 0.011 to 0.034.
    static let ringRatio = 0.04...0.14
    /// Pixels the window keeps from the band's sides.
    static let margin = 2
    /// Width over height. The recordings' windows measured 7.3 to 10.2.
    static let aspect = 2.0...14.0

    private struct Band {
        let top: Int
        let bottom: Int
        let left: Int
        let right: Int
        let colour: (Double, Double, Double)
    }

    /// The ring's colour as a pixel is tested against it: each channel of
    /// the two bands' mean colour, truncated, within `tolerance`.
    private struct RingColour {
        let red: Int
        let green: Int
        let blue: Int
        let tolerance = Int(colourTolerance)
    }

    /// The window in `band`, packed RGB, or nil when none is found.
    public static func find(in band: FrameTopBand) -> Window? {
        find(rgb: band.image.pixels, width: band.image.width, rows: band.image.height,
             frameHeight: band.frameHeight)
    }

    /// The window in `rows` rows of `pixels`, packed RGB `width` pixels wide
    /// with no padding, cut from the top of a frame `frameHeight` tall. Nil
    /// when none is found or the pixels are not all there.
    public static func find(rgb pixels: [UInt8], width: Int, rows: Int, frameHeight: Int) -> Window? {
        guard width > 2 * margin, rows > 0, frameHeight >= rows, pixels.count >= width * rows * 3 else {
            return nil
        }
        return pixels.withUnsafeBufferPointer { rgb in
            Search(rgb: rgb, width: width, rows: rows, frameHeight: frameHeight).window()
        }
    }

    private struct Search {
        let rgb: UnsafeBufferPointer<UInt8>
        let width: Int
        let rows: Int
        let frameHeight: Int

        func channel(_ x: Int, _ y: Int, _ c: Int) -> Int { Int(rgb[(y * width + x) * 3 + c]) }

        func grey(_ x: Int, _ y: Int) -> Int {
            let index = (y * width + x) * 3
            return (77 * Int(rgb[index]) + 150 * Int(rgb[index + 1]) + 29 * Int(rgb[index + 2])) >> 8
        }

        func isRing(_ x: Int, _ y: Int, _ ring: RingColour) -> Bool {
            let index = (y * width + x) * 3
            return abs(Int(rgb[index]) - ring.red) <= ring.tolerance
                && abs(Int(rgb[index + 1]) - ring.green) <= ring.tolerance
                && abs(Int(rgb[index + 2]) - ring.blue) <= ring.tolerance
        }

        /// The row's longest run of neighbour steps that are smooth and
        /// bright on both sides: its first step and its count of steps. The
        /// earliest wins a tie.
        func longestRun(_ y: Int) -> (start: Int, length: Int) {
            var best = (start: 0, length: 0)
            var start = 0
            var length = 0
            var previousGrey = grey(0, y)
            for x in 1..<width {
                let currentGrey = grey(x, y)
                var step = 0
                for c in 0..<3 { step = max(step, abs(channel(x, y, c) - channel(x - 1, y, c))) }
                if step <= smoothStep, currentGrey >= ringFloor, previousGrey >= ringFloor {
                    if length == 0 { start = x - 1 }
                    length += 1
                    if length > best.length { best = (start, length) }
                } else {
                    length = 0
                }
                previousGrey = currentGrey
            }
            return best
        }

        /// The median of each channel over `count` pixels of row `y` from
        /// `start`, as `numpy.median` gives it.
        func medianColour(_ y: Int, _ start: Int, _ count: Int) -> (Double, Double, Double) {
            var values = [Double](repeating: 0, count: 3)
            for c in 0..<3 {
                var histogram = [Int](repeating: 0, count: 256)
                for x in start..<(start + count) { histogram[channel(x, y, c)] += 1 }
                values[c] = Self.median(histogram, count: count)
            }
            return (values[0], values[1], values[2])
        }

        static func median(_ histogram: [Int], count: Int) -> Double {
            func value(at rank: Int) -> Int {
                var seen = 0
                for (level, n) in histogram.enumerated() {
                    seen += n
                    if seen > rank { return level }
                }
                return histogram.count - 1
            }
            if count % 2 == 1 { return Double(value(at: count / 2)) }
            return Double(value(at: count / 2 - 1) + value(at: count / 2)) / 2
        }

        /// Runs of rows whose longest smooth run spans most of the width,
        /// each no thicker than a ring.
        func ringBands() -> [Band] {
            let thickest = max(2.0, maximumRingShare * Double(frameHeight))
            var runs: [(start: Int, length: Int)] = []
            runs.reserveCapacity(rows)
            for y in 0..<rows { runs.append(longestRun(y)) }
            let least = minimumRun * Double(width)
            var bands: [Band] = []
            var first: Int?
            for y in 0...rows {
                let edge = y < rows && Double(runs[y].length) >= least
                if edge, first == nil {
                    first = y
                } else if !edge, let top = first {
                    first = nil
                    guard Double(y - top) <= thickest else { continue }
                    let middle = (top + y - 1) / 2
                    let left = runs[top..<y].map(\.start).min() ?? 0
                    let right = (runs[top..<y].map { $0.start + $0.length }.max() ?? 0) + 1
                    let run = runs[middle]
                    bands.append(Band(top: top, bottom: y, left: left, right: right,
                                      colour: medianColour(middle, run.start, run.length + 1)))
                }
            }
            return bands
        }

        /// Scanning from `start` towards `stop` (exclusive), the first
        /// ring pixel, or `stop` when there is none.
        func firstHit(_ y: Int, _ ring: RingColour, from start: Int, to stop: Int,
                      step: Int) -> Int {
            var x = start
            while x != stop, !isRing(x, y, ring) { x += step }
            return x
        }

        /// Scanning from `start` towards `stop` (exclusive), the far end of
        /// the first run of ring pixels; nil when there is none.
        func firstRunEnd(_ y: Int, _ ring: RingColour, from start: Int, to stop: Int,
                         step: Int) -> Int? {
            var x = firstHit(y, ring, from: start, to: stop, step: step)
            guard x != stop else { return nil }
            while x + step != stop, isRing(x + step, y, ring) { x += step }
            return x
        }

        func window() -> Window? {
            let bands = ringBands()
            var best: Window?
            for (index, upper) in bands.enumerated() {
                for lower in bands[(index + 1)...] {
                    if let found = pair(upper, lower), found.right - found.left > best.map({ $0.right - $0.left }) ?? 0 {
                        best = found
                    }
                }
            }
            return best
        }

        /// The window whose upper ring is `a` and lower ring `b`, if they
        /// are one.
        func pair(_ a: Band, _ b: Band) -> Window? {
            let thickness = max(a.bottom - a.top, b.bottom - b.top)
            let height = b.bottom - a.top
            let colourDistance = max(abs(a.colour.0 - b.colour.0), abs(a.colour.1 - b.colour.1),
                                     abs(a.colour.2 - b.colour.2))
            guard colourDistance <= colourTolerance else { return nil }
            let shareLeft = max(a.left, b.left)
            let shareRight = min(a.right, b.right)
            guard Double(shareRight - shareLeft) >= 0.9 * Double(min(a.right - a.left, b.right - b.left)),
                  b.top - a.bottom >= 2 * thickness,
                  a.top >= 2, b.bottom + 1 < rows else { return nil }
            let mean = ((a.colour.0 + b.colour.0) / 2, (a.colour.1 + b.colour.1) / 2, (a.colour.2 + b.colour.2) / 2)
            let ringGrey = (77 * mean.0 + 150 * mean.1 + 29 * mean.2) / 256
            let ring = RingColour(red: Int(mean.0), green: Int(mean.1), blue: Int(mean.2))
            // A ring is a line: when the rows just outside both bands are its
            // colour too, the bands are part of something larger.
            func ringShare(_ y: Int) -> Double {
                guard shareRight > shareLeft else { return 0 }
                var count = 0
                for x in shareLeft..<shareRight where isRing(x, y, ring) { count += 1 }
                return Double(count) / Double(shareRight - shareLeft)
            }
            guard !(ringShare(a.top - 2) > 0.6 && ringShare(b.bottom + 1) > 0.6) else { return nil }
            let low = max(0, min(a.left, b.left) - height)
            let high = min(width, max(a.right, b.right) + height)
            let innerLeft = shareLeft + 2
            let innerRight = shareRight - 3
            guard innerLeft > low - 1, innerLeft < width, innerRight >= 0, innerRight < high else { return nil }
            // A side is one ring thick: art of its colour beside it is not the
            // window, so a side ends at most two rings past its first pixel.
            let sideReach = 2 * thickness + 2
            var lefts: [Int] = []
            var rights: [Int] = []
            for k in 2...4 {
                let y = a.top + height * k / 6
                guard let leftEnd = firstRunEnd(y, ring, from: innerLeft, to: low - 1, step: -1),
                      let rightEnd = firstRunEnd(y, ring, from: innerRight, to: high, step: 1) else { continue }
                lefts.append(max(leftEnd, firstHit(y, ring, from: innerLeft, to: low - 1, step: -1) - sideReach))
                rights.append(min(rightEnd, firstHit(y, ring, from: innerRight, to: high, step: 1) + sideReach) + 1)
            }
            guard lefts.count == 3, let left = lefts.min(), let leftMost = lefts.max(),
                  let right = rights.max(), let rightLeast = rights.min(),
                  leftMost - left <= sideReach, right - rightLeast <= sideReach,
                  left >= margin, right <= width - margin,
                  aspect.contains(Double(right - left) / Double(height)) else { return nil }
            guard let interior = interiorMedian(top: a.bottom + thickness, bottom: b.top - thickness,
                                                left: left + 3 * thickness, right: right - 3 * thickness),
                  interior <= ringGrey - interiorContrast else { return nil }
            let heightValue = Double(height)
            guard ringRatio.contains(Double(a.bottom - a.top) / heightValue),
                  ringRatio.contains(Double(b.bottom - b.top) / heightValue) else { return nil }
            return Window(left: left, top: a.top, right: right, bottom: b.bottom)
        }

        /// The median grey of every second row of the rectangle; nil when it
        /// is empty.
        func interiorMedian(top: Int, bottom: Int, left: Int, right: Int) -> Double? {
            guard top < bottom, left < right, top >= 0, bottom <= rows, left >= 0, right <= width else { return nil }
            var histogram = [Int](repeating: 0, count: 256)
            var count = 0
            for y in stride(from: top, to: bottom, by: 2) {
                for x in left..<right { histogram[grey(x, y)] += 1 }
                count += right - left
            }
            return Self.median(histogram, count: count)
        }
    }
}
