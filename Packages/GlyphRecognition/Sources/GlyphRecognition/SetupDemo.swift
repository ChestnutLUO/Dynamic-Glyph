/// A made-up hack, played on a loop, for previewing the floating window before
/// any real capture: waiting, the sequence being presented, the player drawing
/// it with each Glyph checked, then the finished hack.
///
/// Nothing here is evidence. It builds display snapshots directly so the
/// preview goes through exactly the renderer the floating window uses.
public struct SetupDemo: Sendable {
    public static let slotCount = 5
    static let waitingDuration = 1.0
    static let glyphDuration = 1.0
    static let completedDuration = 1.0
    public static let loopDuration =
        waitingDuration + 2 * Double(slotCount) * glyphDuration + completedDuration

    /// Original shapes, so the preview has something to draw before the player
    /// has imported a shape list. The reference data carries no licence and is
    /// never bundled; these are not taken from it.
    public static let builtInTable = GlyphTable(entries: [
        GlyphID("demo1"): GlyphPath(encoded: "185")!,
        GlyphID("demo2"): GlyphPath(encoded: "3457")!,
        GlyphID("demo3"): GlyphPath(encoded: "0129")!,
        GlyphID("demo4"): GlyphPath(encoded: "6a7")!,
        GlyphID("demo5"): GlyphPath(encoded: "13679")!
    ])

    /// The table to draw with: the player's own when it can fill the demo.
    public let table: GlyphTable
    public let glyphs: [GlyphID]
    public let usesBuiltInShapes: Bool

    /// A full-length sequence from `sequences` whose shapes are all in `table`
    /// is used first, then the first shapes of `table`, then the built-in set.
    public init(table: GlyphTable?, sequences: SequenceTable? = nil) {
        if let table,
           let sequence = sequences?.sequences.first(where: {
               $0.count == Self.slotCount && $0.allSatisfy { table.path(for: $0) != nil }
           }) {
            self.table = table
            glyphs = sequence
            usesBuiltInShapes = false
        } else if let table, table.count >= Self.slotCount {
            self.table = table
            glyphs = Array(table.glyphs.prefix(Self.slotCount))
            usesBuiltInShapes = false
        } else {
            self.table = Self.builtInTable
            glyphs = Self.builtInTable.glyphs
            usesBuiltInShapes = true
        }
    }

    /// The display `elapsed` seconds into the loop. Pass the same `uptime` to
    /// the renderer, so the snapshot is never drawn as stale.
    public func snapshot(at elapsed: Double, uptime: Double) -> GlyphDisplaySnapshot {
        let loop = Self.loopDuration
        let time = elapsed.isFinite ? (elapsed.truncatingRemainder(dividingBy: loop) + loop)
            .truncatingRemainder(dividingBy: loop) : 0
        let session = CaptureSessionID(rawValue: 0)
        let presentingStart = Self.waitingDuration
        let inputStart = presentingStart + Double(Self.slotCount) * Self.glyphDuration
        let completedStart = inputStart + Double(Self.slotCount) * Self.glyphDuration

        var state = TrackingState.command
        var slots: [SlotObservation] = []
        var current: Int?
        var input: Int?
        var visible: GlyphID?
        var checks: [InputCheckResult] = []

        if time >= presentingStart {
            state = .presenting
            let shown = time < inputStart ? Int((time - presentingStart) / Self.glyphDuration) : Self.slotCount
            slots = glyphs.indices.map { index in
                if index < shown { return SlotObservation(index: index, status: .confirmed, glyph: glyphs[index]) }
                if index == shown { return SlotObservation(index: index, status: .observing) }
                return SlotObservation(index: index)
            }
            if shown < Self.slotCount {
                current = shown
                visible = glyphs[shown]
            }
        }
        if time >= inputStart {
            state = time >= completedStart ? .completed : .input
            let drawn = min(Self.slotCount, Int((time - inputStart) / Self.glyphDuration))
            if state == .input { input = drawn }
            // The last slot never gets a verdict, exactly as in the validator.
            checks = (0..<min(drawn, Self.slotCount - 1)).map { index in
                let lifted = inputStart + Double(index + 1) * Self.glyphDuration
                return InputCheckResult(sessionID: session, hackID: 1, slotIndex: index, attemptID: index + 1,
                                        expectedGlyph: glyphs[index], verdict: .matched, reason: nil,
                                        sourceTime: lifted, startTime: lifted - Self.glyphDuration,
                                        liftTime: lifted, samples: [], windowEnd: .clearArray)
            }
        }

        return GlyphDisplaySnapshot(
            captureSessionID: session, hackID: 1, revision: Int(time / 0.25),
            liveness: .live, state: state, phaseSource: .headerText, acceptance: .trackingSequence,
            sourceFrameTime: time, evidenceArrivalUptime: uptime,
            expectedSlotCount: state == .command ? nil : Self.slotCount, slots: slots,
            currentSlotIndex: current, inputSlotIndex: input, inputSlotObservedTime: input == nil ? nil : time,
            slotCountConflict: false, isFrozen: state == .input || state == .completed,
            provisionalGlyph: visible, provisionalExtensionCount: 0, outlook: .unavailable,
            calibrationSummary: "demo", inputChecks: checks)
    }
}

extension SetupDemo {
    /// Items in the gear preview's one drop.
    public static let gearItemCount = 6
    static let gearWatchingDuration = 2.0
    static let gearReadingDuration = 1.0
    /// As long as the floating window holds a finished drop.
    static let gearReadDuration = 3.0
    public static let gearLoopDuration = gearWatchingDuration + gearReadingDuration + gearReadDuration
        + gearWatchingDuration

    /// What the floating window shows during gear-only capture, on a loop:
    /// watching for gear, reading one drop, its item count, then watching
    /// again with the count so far. It never draws a Glyph, so setup can
    /// preview the window without Glyph assistance.
    public static func gearSnapshot(at elapsed: Double, uptime: Double) -> GlyphDisplaySnapshot {
        let loop = gearLoopDuration
        let time = elapsed.isFinite ? (elapsed.truncatingRemainder(dividingBy: loop) + loop)
            .truncatingRemainder(dividingBy: loop) : 0
        let readingStart = gearWatchingDuration
        let readStart = readingStart + gearReadingDuration
        let watchingAgain = readStart + gearReadDuration
        // The states GearDropDisplayTracker(standalone: true) reports.
        let gear: GearDropDisplay
        if time < readingStart {
            gear = GearDropDisplay(state: .watching, hackID: nil, itemCount: 0)
        } else if time < readStart {
            gear = GearDropDisplay(state: .reading, hackID: nil)
        } else if time < watchingAgain {
            gear = GearDropDisplay(state: .read, hackID: nil, itemCount: gearItemCount)
        } else {
            gear = GearDropDisplay(state: .watching, hackID: nil, itemCount: gearItemCount)
        }
        return GlyphDisplaySnapshot(
            captureSessionID: CaptureSessionID(rawValue: 0), hackID: 0, revision: 0,
            liveness: .live, state: .inactive, phaseSource: .none, acceptance: .trackingSequence,
            sourceFrameTime: time, evidenceArrivalUptime: uptime,
            expectedSlotCount: nil, slots: [], currentSlotIndex: nil, inputSlotIndex: nil,
            slotCountConflict: false, isFrozen: false,
            provisionalGlyph: nil, provisionalExtensionCount: 0, outlook: .unavailable,
            calibrationSummary: "demo", gear: gear)
    }
}
