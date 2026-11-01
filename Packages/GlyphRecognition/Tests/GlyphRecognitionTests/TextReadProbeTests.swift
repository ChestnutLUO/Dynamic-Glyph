import Foundation
import Testing
@testable import GlyphRecognitionImages

/// The probe's observer, which the app points at its power meter once at
/// launch and keeps for the whole session. Build 97 crashed 31 minutes in:
/// each report left the stored closure one layer of thunks deeper, so the
/// ~3,300th call overflowed the reading thread's stack.
///
/// The observer is process-wide, so the suite runs one test at a time and
/// counts only the reports made on its own thread: other suites' Vision
/// reads may report through the probe meanwhile. That thread has a large
/// stack, so a regression fails these checks instead of crashing the run.
@Suite("Text read probe", .serialized)
struct TextReadProbeTests {
    @Test("A report is no deeper on the stack after 2,000 reports than the first")
    func depthStaysFlat() {
        let reports = 2_000
        let depths = Self.onOwnThread { () -> [UInt] in
            let calls = OwnCalls()
            TextReadProbe.setObserver { _, _ in
                guard calls.isOwn else { return }
                calls.depths.append(Self.stackAddress())
            }
            defer { TextReadProbe.setObserver(nil) }
            for _ in 0..<reports {
                TextReadProbe.finish(.headerFast, since: TextReadProbe.start())
            }
            return calls.depths
        }
        #expect(depths.count == reports, "every report reached the observer")
        guard let first = depths.first, let last = depths.last else { return }
        // The stack grows down: a deeper call has a lower address.
        let grown = Int(bitPattern: first) - Int(bitPattern: last)
        #expect(abs(grown) <= 512, "the last report ran \(grown) bytes deeper than the first")
    }

    @Test("A report costs as much after 20,000 reports as in the first thousand")
    func costStaysFlat() {
        let batches = 20, batchSize = 1_000
        let (costs, reported) = Self.onOwnThread { () -> ([Double], Int) in
            let calls = OwnCalls()
            TextReadProbe.setObserver { _, _ in
                guard calls.isOwn else { return }
                calls.count += 1
            }
            defer { TextReadProbe.setObserver(nil) }
            var costs: [Double] = []
            var times = [UInt64](repeating: 0, count: batchSize)
            for _ in 0..<batches {
                for index in times.indices {
                    let started = TextReadProbe.start()
                    TextReadProbe.finish(.headerFast, since: started)
                    times[index] = TextReadProbe.start() &- started
                }
                costs.append(Self.typicalMean(times))
            }
            return (costs, calls.count)
        }
        #expect(reported == batches * batchSize, "every report reached the observer")
        guard let first = costs.first, let last = costs.last else { return }
        #expect(last <= 2 * first + 1_000,
                "a report took \(Int(last)) ns on average in the last thousand, \(Int(first)) ns in the first")
    }

    /// The mean of the fastest 90 %: a call the scheduler interrupted says
    /// nothing about the probe.
    static func typicalMean(_ nanoseconds: [UInt64]) -> Double {
        let kept = nanoseconds.sorted().prefix(nanoseconds.count * 9 / 10)
        return Double(kept.reduce(0, +)) / Double(max(1, kept.count))
    }

    /// Where this call's frame is on the stack.
    @inline(never)
    static func stackAddress() -> UInt {
        var marker: UInt8 = 0
        return withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
    }

    /// Runs `body` on a new thread with a 256 MB stack and waits for it.
    static func onOwnThread<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
        let outcome = Outcome<Result>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome.value = body()
            done.signal()
        }
        thread.stackSize = 256 << 20
        thread.start()
        done.wait()
        return outcome.value!
    }
}

/// What the observer saw on the thread that made it. Touched by that thread
/// only.
private final class OwnCalls: @unchecked Sendable {
    let owner = UInt(bitPattern: pthread_self())
    var depths: [UInt] = []
    var count = 0
    var isOwn: Bool { UInt(bitPattern: pthread_self()) == owner }

    init() { depths.reserveCapacity(2_000) }
}

private final class Outcome<Value>: @unchecked Sendable {
    var value: Value?
}
