import CoreGraphics
import Foundation
import Testing
@testable import GlyphRecognition
@testable import GlyphRecognitionImages

/// Build 103: a gear read can be stopped (`GearReadCancellation`) when a new
/// panel replaces the one it reads. Stopped, it throws and returns nothing;
/// left alone, the token changes nothing. The time from the stop to the read's
/// return is printed (`GEAR103-CANCEL-LATENCY`), for the fix notes. Vision runs
/// on a thread of its own (`offPool`), never on Swift's shared pool, and the
/// suite is serialized: the reads here run one at a time.
@Suite("Build 103: stopping a gear read", .serialized, .timeLimit(.minutes(3)))
struct GearReadCancellationTests {
    struct Frame: @unchecked Sendable { let image: CGImage }

    func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    func image(_ name: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent("Gear/\(name).png"))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    static func english() -> GameLanguageMemory { GameLanguageMemory(language: .english, isAutomatic: false) }

    struct Outcome: Sendable {
        let reading: GearPanelReading?
        let stopped: Bool
        /// When the read returned, on the uptime clock.
        let returned: Double
    }

    func read(_ frame: Frame, bounds: GearDropPanelBounds, retries: Bool,
              cancellation: GearReadCancellation?) throws -> Outcome {
        do {
            let reading = try GearDropScreenReader.reading(frame.image, bounds: bounds, sourceTime: 1,
                titleMemory: GearTitleLanguageMemory(), languages: Self.english(), retries: retries,
                rereadsUnreadableRows: true, cancellation: cancellation)
            return Outcome(reading: reading, stopped: false, returned: ProcessInfo.processInfo.systemUptime)
        } catch {
            guard cancellation?.isCancelled == true else { throw error }
            return Outcome(reading: nil, stopped: true, returned: ProcessInfo.processInfo.systemUptime)
        }
    }

    @Test("A token left alone changes nothing: same evidence, same passes", arguments: [false, true])
    func untouchedToken(retries: Bool) async throws {
        let frame = Frame(image: try image("five-base"))
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame.image))
        let plain = try await offPool { try self.read(frame, bounds: bounds, retries: retries, cancellation: nil) }
        let tokened = try await offPool {
            try self.read(frame, bounds: bounds, retries: retries, cancellation: GearReadCancellation())
        }
        #expect(plain.reading?.evidence == tokened.reading?.evidence)
        #expect(plain.reading?.passes.map(\.purpose) == tokened.reading?.passes.map(\.purpose))
        #expect(plain.reading?.evidence.stage == .portal)
    }

    @Test("A read stopped before it starts runs no OCR and throws")
    func stoppedBeforeStart() async throws {
        let frame = Frame(image: try image("five-base"))
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame.image))
        let token = GearReadCancellation()
        token.cancel()
        let started = ProcessInfo.processInfo.systemUptime
        let outcome = try await offPool { try self.read(frame, bounds: bounds, retries: false, cancellation: token) }
        #expect(outcome.stopped && outcome.reading == nil)
        #expect(outcome.returned - started < 0.5)
    }

    @Test("A read stopped while it runs returns nothing, or all it read if it had finished; prints the latency")
    func stoppedWhileRunning() async throws {
        let frame = Frame(image: try image("five-base"))
        let bounds = try #require(try GearDropScreenReader().bounds(in: frame.image))
        // How long a whole read takes here, constrained and not.
        var whole: [Bool: Double] = [:]
        for retries in [false, true] {
            let started = ProcessInfo.processInfo.systemUptime
            let outcome = try await offPool { try self.read(frame, bounds: bounds, retries: retries, cancellation: nil) }
            whole[retries] = outcome.returned - started
        }
        var lines: [String] = [String(format: "whole read: constrained %.0f ms, with retries %.0f ms",
                                      (whole[false] ?? 0) * 1000, (whole[true] ?? 0) * 1000)]
        for retries in [false, true] {
            var latencies: [Double] = []
            for delay in [0.02, 0.05, 0.1, 0.2, 0.3, 0.5] {
                let token = GearReadCancellation()
                let started = ProcessInfo.processInfo.systemUptime
                async let outcome = offPool { try self.read(frame, bounds: bounds, retries: retries, cancellation: token) }
                try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                let asked = ProcessInfo.processInfo.systemUptime
                token.cancel()
                let result = try await outcome
                if result.stopped {
                    #expect(result.reading == nil)
                    latencies.append(max(0, result.returned - asked))
                } else {
                    // Finished before the stop could land: a whole read.
                    #expect(result.reading?.evidence.stage == .portal)
                }
                lines.append(String(format: "%@ stop after %.0f ms: %@ %.1f ms after the stop (read began %.0f ms before)",
                                    retries ? "retries" : "constrained", delay * 1000,
                                    result.stopped ? "stopped" : "finished",
                                    (result.returned - asked) * 1000, (asked - started) * 1000))
            }
            if !latencies.isEmpty {
                let sorted = latencies.sorted()
                lines.append(String(format: "%@: %d stopped, latency median %.1f ms, max %.1f ms",
                                    retries ? "retries" : "constrained", sorted.count,
                                    sorted[sorted.count / 2] * 1000, (sorted.last ?? 0) * 1000))
            }
        }
        print("GEAR103-CANCEL-LATENCY\n" + lines.joined(separator: "\n"))
        // Never two Vision requests at once here: each read awaited in turn.
    }
}
