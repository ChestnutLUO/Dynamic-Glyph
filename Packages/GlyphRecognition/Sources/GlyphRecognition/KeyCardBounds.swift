/// Which inventory surface a key card was seen on. The card's proportions
/// differ: an Inventory card is taller than wide, a Capsule or Key Locker
/// card is about as wide as tall. This is the distinction
/// CountIngressKeys makes with two aspect-ratio ranges.
public enum KeyCardKind: String, Sendable, Equatable, Codable {
    case inventory
    case capsule
}

/// A rectangle in source-image pixels, top-left origin, like the frames the
/// recognition core consumes. The image packages convert this to their own
/// rectangle types.
public struct PixelRect: Sendable, Equatable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// The key card's rectangle in source-image pixels.
public struct KeyCardBounds: Sendable, Equatable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let kind: KeyCardKind

    public init(x: Int, y: Int, width: Int, height: Int, kind: KeyCardKind) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.kind = kind
    }

    /// Height over width, the ratio the detector gates on. The original
    /// MATLAB script calls this the aspect ratio and keeps one range per
    /// surface.
    public var aspectRatio: Double { Double(height) / Double(width) }

    /// The card's rectangle as a source-pixel rect.
    public var rect: PixelRect { PixelRect(x: x, y: y, width: width, height: height) }

    /// The card's quantity strip: "x12" sits here at the top of the card. An
    /// Inventory card holding a single key shows no quantity at all.
    public func countRegion(layout: KeyCardLayout = KeyCardLayout()) -> PixelRect {
        let fraction = layout.kindLayout(kind).countHeight
        let height = max(1, Int((Double(self.height) * fraction).rounded(.down)))
        return PixelRect(x: x, y: y, width: width, height: min(height, self.height))
    }

    /// The card's portal-name strip, near the bottom of the card.
    public func nameRegion(layout: KeyCardLayout = KeyCardLayout()) -> PixelRect {
        let fractions = layout.kindLayout(kind)
        let top = min(self.height - 1, Int((Double(self.height) * fractions.nameTop).rounded(.down)))
        let height = max(1, Int((Double(self.height) * fractions.nameHeight).rounded(.down)))
        let bottom = min(self.height, top + height)
        return PixelRect(x: x, y: y + top, width: width, height: bottom - top)
    }
}

/// The fractions of a card's height each reading strip occupies. The defaults
/// are the proportions CountIngressKeys measured on 2018 screen recordings
/// (an iPhone 6 and a Moto G 2nd Gen): the quantity strip is the card's top
/// 1/6.2 (Capsule) or 1/10 (Inventory), and the name strip runs from
/// H - H/4.5 to H - H/4.5 + H/8 (Capsule) or H - H/8 to H - H/8 + H/15
/// (Inventory). They have not been re-measured on Ingress Prime captures;
/// a reader that reads nothing should try adjusted fractions here before
/// the geometry is declared wrong.
public struct KeyCardLayout: Sendable, Equatable {
    public struct KindLayout: Sendable, Equatable {
        /// The quantity strip's height over the card's height.
        public let countHeight: Double
        /// Where the name strip starts, over the card's height, from the top.
        public let nameTop: Double
        /// The name strip's height over the card's height.
        public let nameHeight: Double

        public init(countHeight: Double, nameTop: Double, nameHeight: Double) {
            self.countHeight = countHeight; self.nameTop = nameTop; self.nameHeight = nameHeight
        }
    }

    public var inventory: KindLayout
    public var capsule: KindLayout

    public init(inventory: KindLayout = KindLayout(countHeight: 1.0 / 10.0,
                                                   nameTop: 1.0 - 1.0 / 8.0,
                                                   nameHeight: 1.0 / 15.0),
                capsule: KindLayout = KindLayout(countHeight: 1.0 / 6.2,
                                                 nameTop: 1.0 - 1.0 / 4.5,
                                                 nameHeight: 1.0 / 8.0)) {
        self.inventory = inventory
        self.capsule = capsule
    }

    public func kindLayout(_ kind: KeyCardKind) -> KindLayout {
        kind == .inventory ? inventory : capsule
    }
}
