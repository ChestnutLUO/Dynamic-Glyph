import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GlyphRecognition
import GlyphRecognitionImages

@Suite("Luma gate before analysis")
struct LumaGateTests {
    /// The only fixtures that show the map, which the gate must let rest.
    static let maps: Set<String> = ["Frames/frame-02092.jpg", "Phases/field-00666.png"]

    /// Every full-size frame in the fixtures: hacks in every phase, command
    /// channels, banners, covered and edge cases, results, portal screens and
    /// item panels, plus the two maps.
    static func frames() throws -> [(name: String, image: LuminanceImage)] {
        let root = try ReferenceData.fixturesDirectory
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var frames: [(String, LuminanceImage)] = []
        for case let url as URL in enumerator where ["png", "jpg"].contains(url.pathExtension.lowercased()) {
            let image = try ImageDecoder.load(url)
            guard image.height > 1000, image.height > image.width else { continue }
            let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
                .replacingOccurrences(of: root.resolvingSymlinksInPath().path + "/", with: "")
            frames.append((name, image))
        }
        return frames.sorted { $0.0 < $1.0 }
    }

    @Test("Every game screen in the fixtures passes; the maps do not")
    func fixtures() throws {
        let frames = try Self.frames()
        #expect(frames.count >= 50, "fixtures went missing: \(frames.count)")
        var maps = 0
        for (name, image) in frames {
            let reading = try #require(LumaGate().read(image))
            if Self.maps.contains(where: { name.hasSuffix($0) }) {
                maps += 1
                #expect(!reading.isCandidate, "\(name): dark \(reading.darkFraction) bright \(reading.brightFraction)")
            } else {
                #expect(reading.isCandidate, "\(name) would be skipped: bright \(reading.brightFraction)")
                // Brightness alone lets every game screen through, with margin
                // for a slightly different phone; darkness is extra.
                #expect(reading.brightFraction <= LumaGate.maximumBrightFraction - 0.08, "\(name)")
            }
        }
        #expect(maps == 2)
    }

    /// Rec. 709 luma from the gamma-encoded sRGB pixels, as a capture's Y
    /// plane carries it, `shift` levels brighter (or darker) everywhere.
    static func captureLuma(_ url: URL, shift: Int) throws -> (width: Int, height: Int, luma: [UInt8]) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let luma = (0..<(width * height)).map { pixel -> UInt8 in
            let y = (54 * Int(rgba[pixel * 4]) + 183 * Int(rgba[pixel * 4 + 1]) + 19 * Int(rgba[pixel * 4 + 2])) >> 8
            return UInt8(clamping: y + shift)
        }
        return (width, height, luma)
    }

    @Test("As capture luma, even a few levels off, every game screen still passes and the maps still rest",
          arguments: [-6, -3, 0, 3, 6])
    func captureDomain(shift: Int) throws {
        let root = try ReferenceData.fixturesDirectory
        var checked = 0
        for (name, _) in try Self.frames() {
            let (width, height, luma) = try Self.captureLuma(root.appendingPathComponent(name), shift: shift)
            let reading = try #require(luma.withUnsafeBytes {
                LumaGate().read(plane: $0.baseAddress!, width: width, height: height, bytesPerRow: width,
                                videoRange: false)
            })
            let map = Self.maps.contains { name.hasSuffix($0) }
            #expect(reading.isCandidate == !map,
                    "\(name) shifted \(shift): dark \(reading.darkFraction) bright \(reading.brightFraction)")
            checked += 1
        }
        #expect(checked >= 50)
    }

    @Test("A Glyph drawn on the array, or the hack replacing a still screen, is a change")
    func changes() throws {
        let frames = Dictionary(uniqueKeysWithValues: try Self.frames().map { ($0.name, $0.image) })
        func reading(_ suffix: String) throws -> LumaGateReading {
            let image = try #require(frames.first { $0.key.hasSuffix(suffix) }?.value)
            return try #require(LumaGate().read(image))
        }
        let blank = try reading("Phases/field-00456.png"), glyph = try reading("Phases/field-00443.png")
        let command = try reading("Phases/field-00381.png"), portal = try reading("PortalLevel/portal-l6.png")
        #expect(blank.difference(from: blank) == 0)
        let threshold = AnalysisRateController.Policy().changeThreshold
        #expect(glyph.difference(from: blank) > threshold * 4)
        #expect(command.difference(from: portal) > threshold * 4)
    }

    @Test("A luma plane reads like the decoded image; video range is stretched to full")
    func planes() throws {
        let image = try ImageDecoder.load(ReferenceData.fixturesDirectory.appendingPathComponent("Phases/field-00443.png"))
        let decoded = try #require(LumaGate().read(image))
        let padded = image.width + 13
        var plane = [UInt8](repeating: 255, count: padded * image.height)
        for y in 0..<image.height { for x in 0..<image.width { plane[y * padded + x] = image[x, y] } }
        let fromPlane = plane.withUnsafeBytes {
            LumaGate().read(plane: $0.baseAddress!, width: image.width, height: image.height, bytesPerRow: padded,
                            videoRange: false)
        }
        #expect(fromPlane == decoded)
        #expect(LumaGate.videoRangeTable[16] == 0 && LumaGate.videoRangeTable[235] == 255)
        #expect(LumaGate.videoRangeTable[0] == 0 && LumaGate.videoRangeTable[255] == 255)
        // Video-range black is 16: still black to the gate.
        let black = [UInt8](repeating: 16, count: 64 * 128)
        let video = black.withUnsafeBytes {
            LumaGate().read(plane: $0.baseAddress!, width: 64, height: 128, bytesPerRow: 64, videoRange: true)
        }
        #expect(video?.darkFraction == 1 && video?.isCandidate == true)
        // A grey BGRA frame as bright as the map is not.
        let grey = [UInt8](repeating: 90, count: 64 * 128 * 4)
        let bgra = grey.withUnsafeBytes { LumaGate().read(bgra: $0.baseAddress!, width: 64, height: 128, bytesPerRow: 256) }
        #expect(bgra?.brightFraction == 1 && bgra?.isCandidate == false)
    }
}

@Suite("Analysis rate")
struct AnalysisRateControllerTests {
    static let map = LumaGateReading(darkFraction: 0.05, brightFraction: 0.4, cells: [40, 60], isCandidate: false)
    static let mapScrolled = LumaGateReading(darkFraction: 0.06, brightFraction: 0.45, cells: [80, 20], isCandidate: false)
    static let hack = LumaGateReading(darkFraction: 0.95, brightFraction: 0.02, cells: [3, 9], isCandidate: true)
    /// Drawn on `hack`: its overall luma moves 3 levels, as a Glyph's does
    /// on the fixtures (at most 4.2), short of a switch of screens.
    static let glyph = LumaGateReading(darkFraction: 0.93, brightFraction: 0.04, cells: [3, 15], isCandidate: true)

    /// Feeds 20-Hz decisions from `start` for `seconds`, returning the last.
    static func run(_ controller: inout AnalysisRateController, from start: Double, seconds: Double,
                    gate: (Int) -> LumaGateReading?, busy: Bool = false, inHack: Bool = false,
                    constrained: Bool = false) -> [AnalysisRateController.Decision] {
        (0..<Int(seconds * 20)).map { index in
            controller.decide(at: start + Double(index) * 0.05, gate: gate(index), busy: busy, inHack: inHack,
                              constrained: constrained)
        }
    }

    @Test("The map slows analysis to 4 Hz after two seconds; a game screen replacing it gets its first frame analyzed at once")
    func backOffAndReturn() {
        var controller = AnalysisRateController()
        let decisions = Self.run(&controller, from: 10, seconds: 3, gate: { $0 % 2 == 0 ? Self.map : Self.mapScrolled })
        #expect(decisions.prefix(40).allSatisfy { $0.mode == .active && $0.interval == 0.049 })
        #expect(decisions.suffix(19).allSatisfy { $0.mode == .quiet && $0.interval == 0.249 })
        let back = controller.decide(at: 13.01, gate: Self.hack, busy: false, inHack: false, constrained: false)
        #expect(back == .init(mode: .active, interval: 0.049))
        #expect(controller.enteredCandidate && controller.mode == .resting, "one full look, no settling restarted")
        // The map's brightness gone is a switch of screens: a second at the
        // active rate follows, so a fade that hid the array from the entry
        // look cannot cost the first Glyph.
        #expect(controller.decide(at: 13.06, gate: Self.glyph, busy: false, inHack: false, constrained: false)
            == .init(mode: .active, interval: 0.049))
        #expect(!controller.enteredCandidate && controller.switchedScreen)
        // Without evidence from those looks, the pace is slow again after it.
        #expect(controller.decide(at: 14.06, gate: Self.glyph, busy: false, inHack: false, constrained: false)
            == .init(mode: .resting, interval: 0.249))
        #expect(!controller.enteredCandidate && !controller.switchedScreen)
        // Constrained, the entry look is still analyzed: a 20-Hz look always passes its interval.
        _ = Self.run(&controller, from: 14, seconds: 3, gate: { _ in Self.map }, constrained: true)
        #expect(controller.decide(at: 17, gate: Self.hack, busy: false, inHack: false, constrained: true)
            == .init(mode: .active, interval: 0.049))
    }

    @Test("A dark screen rests after the settle time, changing or not, keeping the whole pipeline; only evidence wakes it")
    func stillScreen() {
        var controller = AnalysisRateController()
        let still = Self.run(&controller, from: 0, seconds: 5, gate: { _ in Self.hack })
        // Two seconds from the first look with nothing to follow.
        #expect(still.prefix(40).allSatisfy { $0.mode == .active })
        #expect(still.dropFirst(40).allSatisfy { $0 == .init(mode: .resting, interval: 0.249) })
        // Resting is never quiet: the array search and the header go on.
        #expect(AnalysisRateController.headerInterval(mode: .resting, inHack: false, constrained: false) == 0.5)
        // A change on a candidate is no evidence (it used to wake analysis).
        #expect(controller.decide(at: 5, gate: Self.glyph, busy: false, inHack: false, constrained: false)
            == .init(mode: .resting, interval: 0.249))
        // Evidence from that slow look (array, slots, timer, notice) does, on the next look.
        #expect(controller.decide(at: 5.05, gate: Self.glyph, busy: true, inHack: false, constrained: false)
            == .init(mode: .active, interval: 0.049))
        // A map replacing the still screen is quiet at once: nothing changed
        // that a reader cares about.
        _ = Self.run(&controller, from: 6, seconds: 5, gate: { _ in Self.hack })
        #expect(controller.mode == .resting)
        #expect(controller.decide(at: 11.5, gate: Self.map, busy: false, inHack: false, constrained: false).mode == .quiet)
    }

    @Test("A hack or a busy reader never slows down, whatever the gate says")
    func busy() {
        var controller = AnalysisRateController()
        #expect(Self.run(&controller, from: 0, seconds: 6, gate: { _ in Self.map }, inHack: true)
            .allSatisfy { $0 == .init(mode: .active, interval: 0.049) })
        #expect(Self.run(&controller, from: 6, seconds: 6, gate: { _ in Self.map }, busy: true)
            .allSatisfy { $0.mode == .active })
    }

    @Test("Frames without pixels neither wake nor rest analysis")
    func withoutPixels() {
        var controller = AnalysisRateController()
        #expect(Self.run(&controller, from: 0, seconds: 6, gate: { _ in nil }).allSatisfy { $0.mode == .active })
        _ = Self.run(&controller, from: 6, seconds: 3, gate: { _ in Self.map })
        #expect(controller.mode == .quiet)
        #expect(Self.run(&controller, from: 9, seconds: 1, gate: { _ in nil }).allSatisfy { $0.mode == .quiet })
    }

    @Test("Constrained, everything outside a hack runs at half rate")
    func constrained() {
        var controller = AnalysisRateController()
        let waiting = controller.decide(at: 0, gate: Self.hack, busy: false, inHack: false, constrained: true)
        #expect(waiting == .init(mode: .active, interval: 0.099))
        let hack = controller.decide(at: 0.1, gate: Self.glyph, busy: false, inHack: true, constrained: true)
        #expect(hack == .init(mode: .active, interval: 0.049))
        _ = Self.run(&controller, from: 1, seconds: 3, gate: { _ in Self.map }, constrained: true)
        #expect(controller.decide(at: 4, gate: Self.map, busy: false, inHack: false, constrained: true)
            == .init(mode: .quiet, interval: 0.499))
    }

    @Test("A restarted clock starts over at the full rate")
    func restartedClock() {
        var controller = AnalysisRateController()
        _ = Self.run(&controller, from: 100, seconds: 3, gate: { _ in Self.map })
        #expect(controller.mode == .quiet)
        #expect(controller.decide(at: 5, gate: Self.map, busy: false, inHack: false, constrained: false).mode == .active)
    }

    /// Still looks at 4 Hz from `start` for `seconds`, as a source that
    /// delivers nothing on a still screen would ask for them.
    static func still(_ controller: inout AnalysisRateController, from start: Double, seconds: Double,
                      busy: Bool = false, inHack: Bool = false) -> [AnalysisRateController.Decision] {
        (1...Int(seconds * 4)).map { index in
            controller.advanceStill(at: start + Double(index) * 0.25, busy: busy, inHack: inHack, constrained: false)
        }
    }

    @Test("A still screen settles exactly as unchanged frames would: Waiting after a game screen, Idle after the map")
    func stillLooksSettle() {
        for reading in [Self.hack, Self.map] {
            var still = AnalysisRateController(), frames = AnalysisRateController()
            _ = still.decide(at: 0, gate: reading, busy: false, inHack: false, constrained: false)
            _ = frames.decide(at: 0, gate: reading, busy: false, inHack: false, constrained: false)
            let looks = Self.still(&still, from: 0, seconds: 6)
            let unchanged = (1...24).map {
                frames.decide(at: Double($0) * 0.25, gate: reading, busy: false, inHack: false, constrained: false)
            }
            #expect(looks == unchanged)
        }
        // A game screen with nothing busy rests two seconds in, as with
        // frames; the map goes quiet two seconds in.
        var hack = AnalysisRateController()
        _ = hack.decide(at: 10, gate: Self.hack, busy: false, inHack: false, constrained: false)
        let resting = Self.still(&hack, from: 10, seconds: 5)
        #expect(resting.prefix(7).allSatisfy { $0.mode == .active })
        #expect(resting.dropFirst(7).allSatisfy { $0 == .init(mode: .resting, interval: 0.249) })
        var map = AnalysisRateController()
        _ = map.decide(at: 10, gate: Self.map, busy: false, inHack: false, constrained: false)
        let quiet = Self.still(&map, from: 10, seconds: 3)
        #expect(quiet.prefix(7).allSatisfy { $0.mode == .active })
        #expect(quiet.suffix(4).allSatisfy { $0 == .init(mode: .quiet, interval: 0.249) })
    }

    @Test("A still screen never slows a hack or a busy reader down")
    func stillWhileBusy() {
        var controller = AnalysisRateController()
        _ = controller.decide(at: 0, gate: Self.map, busy: false, inHack: true, constrained: false)
        #expect(Self.still(&controller, from: 0, seconds: 6, inHack: true).allSatisfy { $0.mode == .active })
        #expect(Self.still(&controller, from: 6, seconds: 6, busy: true).allSatisfy { $0.mode == .active })
        // Once the reader lets go, the still screen settles from then on.
        let after = Self.still(&controller, from: 12, seconds: 3)
        #expect(after.prefix(7).allSatisfy { $0.mode == .active } && after.last?.mode == .quiet)
    }

    @Test("Without a frame with pixels, a still screen proves nothing; frames without pixels still neither wake nor rest")
    func stillWithoutPixels() {
        var controller = AnalysisRateController()
        _ = Self.run(&controller, from: 0, seconds: 1, gate: { _ in nil })
        #expect(Self.still(&controller, from: 1, seconds: 6).allSatisfy { $0.mode == .active })
        // Frames without pixels after a reading keep their old rule.
        _ = controller.decide(at: 8, gate: Self.map, busy: false, inHack: false, constrained: false)
        #expect(Self.run(&controller, from: 8.05, seconds: 4, gate: { _ in nil }).allSatisfy { $0.mode == .active })
    }

    @Test("A frame after still looks is judged on its own: evidence wakes at once, a change alone stays at rest, an early timestamp restarts nothing")
    func frameAfterStillLooks() {
        var controller = AnalysisRateController()
        _ = controller.decide(at: 100, gate: Self.hack, busy: false, inHack: false, constrained: false)
        _ = Self.still(&controller, from: 100, seconds: 5)
        #expect(controller.mode == .resting)
        // The next frame's own time is a little before the last still look,
        // which was extrapolated: an unchanged one keeps resting.
        #expect(controller.decide(at: 104.98, gate: Self.hack, busy: false, inHack: false, constrained: false)
            == .init(mode: .resting, interval: 0.249))
        #expect(controller.decide(at: 104.99, gate: Self.glyph, busy: false, inHack: false, constrained: false)
            == .init(mode: .resting, interval: 0.249))
        #expect(controller.decide(at: 104.995, gate: Self.glyph, busy: true, inHack: false, constrained: false)
            == .init(mode: .active, interval: 0.049))
        // The evidence gone, it settles again before resting.
        let settling = Self.run(&controller, from: 105, seconds: 2.5, gate: { _ in Self.hack })
        #expect(settling.prefix(40).allSatisfy { $0.mode == .active } && settling.last?.mode == .resting)
        // A still look from before the last frame is out of date: it changes nothing.
        _ = Self.still(&controller, from: 105, seconds: 5)
        #expect(controller.mode == .resting)
        #expect(controller.advanceStill(at: 50, busy: false, inHack: false, constrained: false)
            == .init(mode: .resting, interval: 0.249))
        #expect(controller.mode == .resting)
        // A real step back in time still restarts the clock.
        #expect(controller.decide(at: 5, gate: Self.hack, busy: false, inHack: false, constrained: false).mode == .active)
    }

    @Test("A dark map that changes on every frame settles to 4 Hz within the settle time and stays there",
          arguments: [false, true])
    func darkChangingMap(constrained: Bool) {
        // The field's map at night: a candidate (dark and dim), its luma
        // different on every look, with no array, slots, timer or notice.
        let night = LumaGateReading(darkFraction: 0.7, brightFraction: 0.05, cells: [10, 22], isCandidate: true)
        let moved = LumaGateReading(darkFraction: 0.68, brightFraction: 0.06, cells: [22, 10], isCandidate: true)
        #expect(night.difference(from: moved) > AnalysisRateController.Policy().changeThreshold)
        var controller = AnalysisRateController()
        let decisions = Self.run(&controller, from: 50, seconds: 60, gate: { $0 % 2 == 0 ? night : moved },
                                 constrained: constrained)
        let slow = constrained ? 0.499 : 0.249
        #expect(decisions.prefix(40).allSatisfy { $0.mode == .active })
        #expect(decisions.dropFirst(40).allSatisfy { $0 == .init(mode: .resting, interval: slow) },
                "not one look back at the full rate in a minute")
        #expect(!controller.enteredCandidate)
        // Resting keeps the header at the waiting cadence: it can still see a command channel.
        #expect(AnalysisRateController.headerInterval(mode: controller.mode, inHack: false, constrained: constrained)
            == (constrained ? 1.0 : 0.5))
    }

    @Test("Positive evidence or a followed hack returns 20 Hz on the very look it is reported, constrained or not")
    func evidenceWakes() {
        let night = LumaGateReading(darkFraction: 0.7, brightFraction: 0.05, cells: [10, 22], isCandidate: true)
        for constrained in [false, true] {
            var controller = AnalysisRateController()
            _ = Self.run(&controller, from: 0, seconds: 3, gate: { _ in night }, constrained: constrained)
            #expect(controller.mode == .resting)
            // `busy`: the caller found the array, the slot strip, the timer or a notice.
            let busy = controller.decide(at: 3, gate: night, busy: true, inHack: false, constrained: constrained)
            #expect(busy == .init(mode: .active, interval: constrained ? 0.099 : 0.049))
            // `inHack` keeps 20 Hz even constrained.
            let hack = controller.decide(at: 3.05, gate: night, busy: false, inHack: true, constrained: constrained)
            #expect(hack == .init(mode: .active, interval: 0.049))
            // The evidence gone, the pace stays active for the settle time, then rests.
            let after = Self.run(&controller, from: 3.1, seconds: 3, gate: { _ in night }, constrained: constrained)
            #expect(after.prefix(39).allSatisfy { $0.mode == .active })
            #expect(after.suffix(15).allSatisfy { $0.mode == .resting })
            // A still screen with evidence wakes too.
            #expect(controller.advanceStill(at: 6.2, busy: true, inHack: false, constrained: constrained).mode == .active)
        }
    }

    @Test("A candidate replaced by a much darker or brighter one is analyzed at once, then for a second at the active rate",
          arguments: [false, true])
    func screenSwitch(constrained: Bool) {
        // Overall luma 16, as a dim night map; the hack screen's is 6.
        let night = LumaGateReading(darkFraction: 0.7, brightFraction: 0.05, cells: [10, 22], isCandidate: true)
        let moved = LumaGateReading(darkFraction: 0.68, brightFraction: 0.06, cells: [22, 10], isCandidate: true)
        #expect(abs(night.meanLuma - Self.hack.meanLuma) >= AnalysisRateController.Policy().switchMeanJump)
        let slow = constrained ? 0.499 : 0.249, burst = constrained ? 0.099 : 0.049
        var controller = AnalysisRateController()
        let map = Self.run(&controller, from: 0, seconds: 3, gate: { $0 % 2 == 0 ? night : moved },
                           constrained: constrained)
        #expect(map.suffix(20).allSatisfy { $0 == .init(mode: .resting, interval: slow) },
                "a map that moves but keeps its brightness is no switch")
        // The switching look passes any interval since the last sample.
        #expect(controller.decide(at: 3, gate: Self.hack, busy: false, inHack: false, constrained: constrained)
            == .init(mode: .active, interval: 0.049))
        #expect(controller.switchedScreen && !controller.enteredCandidate && controller.mode == .resting)
        let after = Self.run(&controller, from: 3.05, seconds: 1.5, gate: { $0 % 2 == 0 ? Self.hack : Self.glyph },
                             constrained: constrained)
        #expect(after.prefix(19).allSatisfy { $0 == .init(mode: .active, interval: burst) })
        // A Glyph drawn and cleared is no new switch; settling was never restarted.
        #expect(after.dropFirst(20).allSatisfy { $0 == .init(mode: .resting, interval: slow) })
        #expect(!controller.switchedScreen)
        // A fade spread over several looks still counts.
        var fading = AnalysisRateController()
        _ = Self.run(&fading, from: 0, seconds: 3, gate: { _ in night }, constrained: constrained)
        let steps = [[8, 20], [7, 17], [5, 13], [3, 9]].map {
            LumaGateReading(darkFraction: 0.8, brightFraction: 0.04, cells: $0, isCandidate: true)
        }
        let fade = steps.enumerated().map { index, gate in
            fading.decide(at: 3 + Double(index) * 0.05, gate: gate, busy: false, inHack: false, constrained: constrained)
        }
        #expect(fade.last == .init(mode: .active, interval: 0.049))
    }

    @Test("The header is read at 10 Hz in a hack, 2 Hz while waiting, not at all on a quiet screen")
    func headerIntervals() {
        #expect(AnalysisRateController.headerInterval(mode: .active, inHack: true, constrained: false) == 0.1)
        #expect(AnalysisRateController.headerInterval(mode: .active, inHack: false, constrained: false) == 0.5)
        #expect(AnalysisRateController.headerInterval(mode: .quiet, inHack: false, constrained: false) == nil)
        #expect(AnalysisRateController.headerInterval(mode: .active, inHack: true, constrained: true) == 0.2)
        #expect(AnalysisRateController.headerInterval(mode: .active, inHack: false, constrained: true) == 1.0)
    }
}

@Suite("Header cadence between hacks")
struct HeaderCadenceTests {
    @Test("An unchanged eligible header consumes no lane time, cadence or request ID")
    func unchangedHeaderAdmission() throws {
        var schedule = GameTextSchedule()
        let firstRequest = schedule.take(at: 0, panelCandidate: false, resultEligible: false,
                                         headerInterval: 0.5)
        let first = try #require(firstRequest)
        schedule.finish(first)
        var checked = 0
        let skipped = schedule.take(at: 0.5, panelCandidate: false, resultEligible: false,
                                    headerInterval: 0.5, admitsHeader: { checked += 1; return false })
        #expect(skipped == nil && schedule.inFlight == nil)
        #expect(checked == 1)
        let changedRequest = schedule.take(at: 0.55, panelCandidate: false, resultEligible: false,
                                           headerInterval: 0.5)
        let changed = try #require(changedRequest)
        #expect(changed.mode == .header && changed.sourceTime == 0.55)
        #expect(changed.id == first.id + 1)
    }

    @Test("Panels and commands never consult header admission")
    func sharedLaneBypassesHeaderAdmission() throws {
        for mode in [GameTextSchedule.Mode.result, .gear, .portal, .command] {
            var schedule = GameTextSchedule()
            var checked = false
            let candidate = schedule.take(at: 0, panelCandidate: mode == .result,
                resultEligible: true, gearCandidate: mode == .gear, portalCandidate: mode == .portal,
                commandCandidate: mode == .command, readsHeader: false,
                admitsHeader: { checked = true; return false })
            let request = try #require(candidate)
            #expect(request.mode == mode)
            #expect(!checked)
        }
    }

    @Test("A skipped header still records a panel candidate disappearing")
    func skippedHeaderKeepsCandidateBookkeeping() throws {
        var schedule = GameTextSchedule()
        let rejectedRequest = schedule.take(at: 0, panelCandidate: true, resultEligible: true)
        let rejected = try #require(rejectedRequest)
        schedule.finish(rejected, panelPresent: false)
        let skipped = schedule.take(at: 0.5, panelCandidate: false, resultEligible: true,
                                    admitsHeader: { false })
        #expect(skipped == nil)
        let newPanelRequest = schedule.take(at: 0.55, panelCandidate: true, resultEligible: true)
        let newPanel = try #require(newPanelRequest)
        #expect(newPanel.mode == .result, "New geometry must get its normal probe after the gap")
    }

    @Test("A header interval slows header reads only")
    func headerOnly() {
        var schedule = GameTextSchedule()
        var headers: [Double] = []
        for index in 0..<40 {
            let time = Double(index) * 0.05
            if let request = schedule.take(at: time, panelCandidate: false, resultEligible: false, headerInterval: 0.5) {
                headers.append(time)
                schedule.finish(request)
            }
        }
        #expect(headers.count == 4)
        #expect(zip(headers, headers.dropFirst()).allSatisfy { $1 - $0 >= 0.498 })
        // A portal screen still gets its own cadence in between.
        var portals = 0
        for index in 0..<10 {
            let time = 10 + Double(index) * 0.05
            if let request = schedule.take(at: time, panelCandidate: false, resultEligible: false,
                                           portalCandidate: true, headerInterval: 0.5) {
                if request.mode == .portal { portals += 1 }
                schedule.finish(request)
            }
        }
        #expect(portals >= 2)
        // No interval keeps the lane's own 10 Hz.
        var fast = GameTextSchedule(), count = 0
        for index in 0..<20 {
            if let request = fast.take(at: Double(index) * 0.05, panelCandidate: false, resultEligible: false) {
                count += 1; fast.finish(request)
            }
        }
        #expect((8...10).contains(count))
    }
}
