/// Source canvas geometry, not the floating window's size (which iOS owns).
/// Resolution changes pixel density without changing the layout proportions.
public struct PiPCanvasConfiguration: Sendable, Equatable {
    /// 1280 x 128 pixels: the 10:1 strip that was tested on the phone, at
    /// twice the density so its diagrams stay sharp when iOS scales it up.
    public static let standard = PiPCanvasConfiguration()
    /// The shapes setup offers, widest first. Each is 2x, so its pixel size is
    /// what the player sees labelled.
    public static let presets: [PiPCanvasConfiguration] = [
        .standard,
        PiPCanvasConfiguration(width: 512, height: 64, resolution: 2),
        PiPCanvasConfiguration(width: 640, height: 96, resolution: 2),
        PiPCanvasConfiguration(width: 640, height: 128, resolution: 2)
    ]
    public let width: Int
    public let height: Int
    public let resolution: Int

    public init(width: Int = 640, height: Int = 64, resolution: Int = 2) {
        self.width = min(640, max(256, width))
        self.height = min(192, max(64, height))
        self.resolution = min(3, max(1, resolution))
    }

    /// The floating window's corner radius, in window points. iOS does not
    /// publish it. Measured from a 2026-09-22 device capture, where a window
    /// 53 capture pixels tall had corners of about 12 (≈ 8.5 pt); rounded up,
    /// because an inner corner slightly too round still sits inside the
    /// window while one too tight shows its square end.
    public static let windowCornerRadius = 9.0

    /// That radius in canvas units, for a window `windowWidth` points wide.
    /// The window keeps the canvas's aspect ratio, so its width alone fixes
    /// the scale. Before iOS reports a width, assume one point per unit.
    public func cornerRadius(windowWidth: Double?) -> Double {
        guard let windowWidth, windowWidth > 0 else { return Self.windowCornerRadius }
        return Self.windowCornerRadius * Double(width) / windowWidth
    }

    public var pixelWidth: Int { width * resolution }
    public var pixelHeight: Int { height * resolution }
    public var aspectRatio: Double { Double(width) / Double(height) }
}
