import CoreGraphics
import CoreText
import Foundation
import GlyphRecognition

/// Draws a `GlyphDisplaySnapshot`. Used by the Picture in Picture sample-buffer
/// renderer and by the tests; it lives here rather than in the app so the
/// coordinate transform and the orientation of the diagrams can be checked on
/// the host, against a bitmap, without a device.
///
/// **Coordinate system.** The context is put into a top-left origin, y-down
/// space before anything is drawn, matching `GlyphDiagramLayout` and UIKit. The
/// text matrix is flipped back so glyphs are not drawn upside down. A
/// sample-buffer bitmap arrives y-up, so this transform is not cosmetic: get it
/// wrong and every Glyph is vertically mirrored into a different, plausible
/// Glyph.
///
/// It renders state; it never decides anything. Where the model is uncertain
/// the drawing says so, in words and in line style as well as in colour.
public struct GlyphDisplayRenderer {
    public struct Palette {
        public var background = CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        public var confirmed = CGColor(red: 0.80, green: 0.78, blue: 1.00, alpha: 1)
        public var observing = CGColor(red: 1.00, green: 0.78, blue: 0.30, alpha: 1)
        public var predicted = CGColor(red: 0.45, green: 0.85, blue: 0.95, alpha: 1)
        public var unknown = CGColor(red: 0.55, green: 0.55, blue: 0.62, alpha: 1)
        public var warning = CGColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1)
        public var primaryText = CGColor(red: 0.95, green: 0.95, blue: 1.00, alpha: 1)
        /// Nothing happening, and nothing wrong.
        public var idle = CGColor(red: 0.42, green: 0.44, blue: 0.52, alpha: 1)
        public var secondaryText = CGColor(red: 0.62, green: 0.63, blue: 0.72, alpha: 1)
        /// The array behind each Glyph: visible on the background, well below
        /// every stroke colour.
        public var frame = CGColor(red: 0.30, green: 0.31, blue: 0.38, alpha: 1)
        public init() {}
    }

    public let palette: Palette
    private let table: GlyphTable?
    private let layout: GlyphDiagramLayout

    public init(table: GlyphTable?, palette: Palette = Palette(),
                layout: GlyphDiagramLayout = GlyphDiagramLayout(inset: 0.06)) {
        self.table = table
        self.palette = palette
        self.layout = layout
    }

    /// `windowCornerRadius` is the rounding the system clips the window to,
    /// in canvas units (`PiPCanvasConfiguration.cornerRadius(windowWidth:)`),
    /// so the status edge's inner corners can follow it. Zero for a square
    /// destination.
    public func draw(_ snapshot: GlyphDisplaySnapshot, in context: CGContext,
                     size: CGSize, atUptime now: Double, windowCornerRadius: CGFloat = 0) {
        context.saveGState()
        defer { context.restoreGState() }
        // Top-left origin, y increasing downwards, for everything below.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)


        // The window this is scaled into measured 189 x 106 points on device,
        // so the canvas carries one row of diagrams and nothing else: names,
        // notes, candidate counts and a status line were all illegible there.
        // State is a colour around the edge rather than a word: Picture in
        // Picture can be tucked against the side of the screen so that only a
        // sliver of the window shows, and the sliver that survives is the edge.
        // The system clips the window to rounded corners, so the edge fills
        // the whole canvas and the content sits in a rounded rectangle
        // concentric with that clip: a square inner corner would leave the
        // edge thick at each corner and thin along the sides.
        let ringWidth = max(4, size.height * 0.08)
        context.setFillColor(statusColour(snapshot, atUptime: now))
        context.fill(CGRect(origin: .zero, size: size))
        let content = CGRect(origin: .zero, size: size).insetBy(dx: ringWidth, dy: ringWidth)
        let innerRadius = min(max(0, windowCornerRadius - ringWidth), content.height / 2, content.width / 2)
        context.setFillColor(palette.background)
        context.addPath(CGPath(roundedRect: content, cornerWidth: innerRadius, cornerHeight: innerRadius,
                               transform: nil))
        context.fillPath()

        let inset = ringWidth + 5
        let row = CGRect(x: inset, y: inset,
                         width: size.width - inset * 2,
                         height: size.height - inset * 2)
        if let gear = snapshot.visibleGear(atUptime: now) {
            drawMessage(gear.message(currentHackID: snapshot.hackID), color: palette.primaryText,
                        in: context, rect: row)
        } else { drawTiles(snapshot, in: context, rect: row, atUptime: now) }
    }

    /// A line in place of the tiles, such as the gear status or "Start a
    /// Glyph hack in Ingress.": one size for all, so no message is harder to
    /// read in the small window than another.
    private func drawMessage(_ text: String, color: CGColor, in context: CGContext, rect: CGRect) {
        let fontSize = max(10, min(rect.height * 0.5, rect.width / 24))
        draw(text: text, at: CGPoint(x: rect.minX + 4, y: rect.midY - fontSize * 0.6),
             size: fontSize, weight: .semibold, color: color, in: context, maxWidth: rect.width - 8)
    }

    // MARK: - Tiles

    private func drawTiles(_ snapshot: GlyphDisplaySnapshot, in context: CGContext,
                           rect: CGRect, atUptime now: Double) {
        let styles = snapshot.tileStyles
        guard !styles.isEmpty else {
            drawMessage(waitingText(snapshot, atUptime: now), color: palette.secondaryText, in: context, rect: rect)
            return
        }
        let columnWidth = rect.width / CGFloat(styles.count)
        for (index, style) in styles.enumerated() {
            let column = CGRect(x: rect.minX + CGFloat(index) * columnWidth, y: rect.minY,
                                width: columnWidth, height: rect.height)
            drawTile(style, index: index, snapshot: snapshot, in: context, rect: column, atUptime: now)
        }
    }

    private func drawTile(_ style: TileStyle, index: Int, snapshot: GlyphDisplaySnapshot,
                          in context: CGContext, rect: CGRect, atUptime now: Double) {
        let colour = colour(for: style)
        // The slot the game is on: being presented, or being drawn.
        if snapshot.currentSlotIndex == index || snapshot.inputSlotIndex == index {
            context.setStrokeColor(colour.copy(alpha: 0.8) ?? colour)
            context.setLineWidth(max(1.5, rect.height * 0.035))
            context.setLineDash(phase: 0, lengths: [])
            let box = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.02)
            context.stroke(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4,
                                  transform: nil).boundingBox)
        }
        let diagram = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.08)
        switch style {
        case .confirmed(let id), .observing(let id), .inferred(let id), .predicted(let id):
            drawDiagram(for: id, in: context, rect: diagram, colour: colour, dashed: style.isDashed)
        case .alternatives, .uncertain, .missing, .pending:
            drawPlaceholder(in: context, rect: diagram, colour: colour)
        }
        if let check = snapshot.inputCheckDisplay(for: index, atUptime: now) {
            let markColour = check.verdict == .differs ? palette.warning : palette.primaryText
            if check.verdict == .differs {
                context.setStrokeColor(palette.warning)
                context.setLineWidth(max(2, rect.height * 0.035))
                context.setLineDash(phase: 0, lengths: [])
                context.stroke(rect.insetBy(dx: 2, dy: 2))
            }
            if check.showsSymbol {
                let side = max(12, rect.height * 0.24)
                let badge = CGRect(x: rect.maxX - side - 2, y: rect.minY + 2, width: side, height: side)
                context.setFillColor(palette.background)
                context.fillEllipse(in: badge)
                draw(text: check.verdict.symbol, at: CGPoint(x: badge.minX + 2, y: badge.minY),
                     size: side * 0.85, weight: .semibold, color: markColour, in: context, maxWidth: side)
            }
        }
    }

    private func drawDiagram(for id: GlyphID, in context: CGContext, rect: CGRect,
                             colour: CGColor, dashed: Bool) {
        guard let path = table?.path(for: id) else {
            drawPlaceholder(in: context, rect: rect, colour: palette.unknown)
            return
        }
        let placed = layout.frame(in: SIMD2(Double(rect.minX), Double(rect.minY)),
                                  size: SIMD2(Double(rect.width), Double(rect.height)))
        func point(_ unit: SIMD2<Double>) -> CGPoint {
            CGPoint(x: placed.origin.x + unit.x * placed.side, y: placed.origin.y + unit.y * placed.side)
        }
        let dot = max(1.5, placed.side * 0.022)
        drawArrayFrame(in: context, point: point, side: placed.side, dot: dot)
        // Small filled markers, never the game's bright hollow rings: eleven
        // rings in a row are exactly what `NodeArrayDetector` locks on to, and
        // the app must not be able to calibrate onto a picture of itself.
        context.setFillColor(colour.copy(alpha: 0.35) ?? colour)
        for position in layout.visitedNodes(of: path) {
            let centre = point(position)
            context.fillEllipse(in: CGRect(x: centre.x - dot, y: centre.y - dot,
                                           width: dot * 2, height: dot * 2))
        }
        context.setStrokeColor(colour)
        context.setLineWidth(max(2, placed.side * 0.045))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: dashed ? [placed.side * 0.09, placed.side * 0.06] : [])
        context.beginPath()
        for segment in layout.segments(for: path) {
            context.move(to: point(segment.from))
            context.addLine(to: point(segment.to))
        }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }

    /// The array a Glyph is drawn on, faintly, behind it: the outer hexagon
    /// and all eleven nodes. Many Glyphs are the same shape at a different
    /// size or position, and without the array there is nothing to measure
    /// the stroke against. Dim enough that the stroke is still what reads
    /// first, and filled dots for the same reason as the visited nodes.
    private func drawArrayFrame(in context: CGContext, point: (SIMD2<Double>) -> CGPoint,
                                side: Double, dot: Double) {
        let colour = palette.frame
        context.setLineDash(phase: 0, lengths: [])
        context.setStrokeColor(colour)
        context.setLineWidth(max(1, side * 0.02))
        context.setLineJoin(.round)
        let corners = layout.outline().map(point)
        if let first = corners.first {
            context.beginPath()
            context.move(to: first)
            for corner in corners.dropFirst() { context.addLine(to: corner) }
            context.closePath()
            context.strokePath()
        }
        context.setFillColor(colour)
        for position in layout.nodePositions() {
            let centre = point(position)
            context.fillEllipse(in: CGRect(x: centre.x - dot, y: centre.y - dot,
                                           width: dot * 2, height: dot * 2))
        }
    }

    private func drawPlaceholder(in context: CGContext, rect: CGRect, colour: CGColor) {
        let placed = layout.frame(in: SIMD2(Double(rect.minX), Double(rect.minY)),
                                  size: SIMD2(Double(rect.width), Double(rect.height)))
        let box = CGRect(x: placed.origin.x, y: placed.origin.y, width: placed.side, height: placed.side)
        context.setStrokeColor(colour.copy(alpha: 0.5) ?? colour)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [6, 5])
        context.stroke(box.insetBy(dx: box.width * 0.18, dy: box.height * 0.18))
        context.setLineDash(phase: 0, lengths: [])
        draw(text: "?", at: CGPoint(x: box.midX - box.width * 0.16, y: box.midY - box.height * 0.36),
             size: max(10, box.height * 0.6), weight: .semibold, color: colour, in: context)
    }

    // MARK: - Model to style

    private func colour(for style: TileStyle) -> CGColor {
        switch style {
        case .confirmed: return palette.confirmed
        case .observing, .inferred: return palette.observing
        case .predicted, .alternatives: return palette.predicted
        case .uncertain, .missing: return palette.warning
        case .pending: return palette.unknown
        }
    }

    func waitingText(_ snapshot: GlyphDisplaySnapshot, atUptime now: Double) -> String {
        if snapshot.indicatorsObstructed {
            return snapshot.statusLine(atUptime: now)
        }
        switch snapshot.state {
        case .command:
            return String(localized: "Get ready — the sequence is coming.", bundle: #bundle,
                          comment: "Floating window, before the sequence is shown.")
        case .completed:
            return String(localized: "This hack's sequence wasn't caught.", bundle: #bundle,
                          comment: "Floating window, after a hack with no collected Glyphs.")
        default:
            return String(localized: "Start a Glyph hack in Ingress.", bundle: #bundle,
                          comment: "Floating window, when no hack is on screen. 'Glyph hack' is an Ingress term.")
        }
    }

    /// One colour per `StatusTone`.
    public func statusColour(_ snapshot: GlyphDisplaySnapshot, atUptime now: Double) -> CGColor {
        switch snapshot.visibleGear(atUptime: now)?.tone ?? snapshot.displayStatus(atUptime: now).tone {
        case .warning: return palette.warning
        case .tentative: return palette.observing
        case .idle: return palette.idle
        case .collecting: return palette.predicted
        case .drawing: return palette.confirmed
        case .done: return palette.primaryText
        }
    }

    public func predictionLine(_ snapshot: GlyphDisplaySnapshot) -> String {
        let outlook = snapshot.outlook
        let length = snapshot.expectedSlotCount.map {
            String(localized: "\($0) Glyphs", bundle: #bundle,
                   comment: "How many Glyphs this hack has.")
        } ?? String(localized: "length not seen yet", bundle: #bundle,
                    comment: "The number of Glyphs in this hack is not known yet.")
        switch outlook.state {
        case .unavailable:
            return String(localized: "Predictions off · \(length)", bundle: #bundle,
                          comment: "Prediction line: no sequence list. The placeholder is the hack's length, e.g. '4 Glyphs'.")
        case .unobserved:
            return String(localized: "Waiting for the first Glyph · \(length)", bundle: #bundle,
                          comment: "Prediction line. The placeholder is the hack's length, e.g. '4 Glyphs'.")
        case .ambiguous:
            return String(localized: "\(outlook.candidateCount) sequences still possible · \(length)", bundle: #bundle,
                          comment: "Prediction line. First: how many sequences fit so far. Second: the hack's length, e.g. '4 Glyphs'.")
        case .resolved:
            return outlook.observationMayBeComplete
                ? String(localized: "One sequence matches, and it may already be complete · \(length)", bundle: #bundle,
                         comment: "Prediction line. The placeholder is the hack's length, e.g. '4 Glyphs'.")
                : String(localized: "One sequence matches what was seen · \(length)", bundle: #bundle,
                         comment: "Prediction line. The placeholder is the hack's length, e.g. '4 Glyphs'.")
        case .contradicted:
            return String(localized: "Doesn't match any known sequence · shown as seen", bundle: #bundle,
                          comment: "Prediction line: the Glyphs seen fit no sequence in the list, so they are shown unchanged.")
        case .lengthConflict:
            return String(localized: "Length doesn't fit what was seen · \(length)", bundle: #bundle,
                          comment: "Prediction line. The placeholder is the hack's length, e.g. '4 Glyphs'.")
        }
    }

    // MARK: - Text

    enum Weight { case regular, semibold }

    private func draw(text: String, at origin: CGPoint, size: CGFloat, weight: Weight,
                      color: CGColor, in context: CGContext, maxWidth: CGFloat? = nil) {
        guard !text.isEmpty else { return }
        let font = CTFontCreateUIFontForLanguage(weight == .semibold ? .emphasizedSystem : .system,
                                                 size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var shown = text
        if let maxWidth {
            // Trim rather than let a long Glyph name run into the next tile.
            while shown.count > 3,
                  CTLineGetTypographicBounds(makeLine(shown, font: font, color: color), nil, nil, nil)
                    > Double(maxWidth) {
                shown = String(shown.dropLast())
            }
            if shown != text { shown = String(shown.dropLast()) + "…" }
        }
        let line = makeLine(shown, font: font, color: color)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + size)
        CTLineDraw(line, context)
    }

    private func makeLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        // Core Text's own attribute names: the UIKit and AppKit keys are not
        // available to a target that imports neither.
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]))
    }
}
