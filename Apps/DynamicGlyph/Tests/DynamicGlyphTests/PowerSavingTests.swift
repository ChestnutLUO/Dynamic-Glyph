import CoreMedia
import CoreVideo
import Foundation
import Testing

@Suite("Newest frame only")
struct LatestFrameSlotTests {
    @Test("A frame waiting behind a busy consumer is replaced, and only one take is scheduled")
    func newestWins() {
        let slot = LatestFrameSlot<Int>()
        #expect(slot.put(1), "the first frame schedules a take")
        #expect(!slot.put(2) && !slot.put(3), "later ones only replace it")
        #expect(slot.take() == 3)
        #expect(slot.superseded == 2)
        #expect(slot.take() == nil, "nothing left once taken")
        #expect(slot.put(4), "a frame after the take schedules the next one")
        #expect(slot.take() == 4)
    }

    @Test("A frame arriving while the consumer works waits for the next take, never queues")
    func consumerBusy() {
        let slot = LatestFrameSlot<Int>()
        var scheduled = 0, processed: [Int] = []
        if slot.put(1) { scheduled += 1 }
        // The consumer takes 1 and is busy with it while 2...5 arrive.
        let working = slot.take()
        for frame in 2...5 where slot.put(frame) { scheduled += 1 }
        processed += [working, slot.take()].compactMap { $0 }
        #expect(processed == [1, 5])
        #expect(scheduled == 2)
        #expect(slot.superseded == 3)
    }

    @Test("Clearing drops the waiting frame")
    func clear() {
        let slot = LatestFrameSlot<Int>()
        _ = slot.put(1)
        slot.clear()
        #expect(slot.take() == nil)
    }

    @Test("A replaced frame's continuity break is carried by the frame that replaces it")
    func continuity() throws {
        let slot = LatestFrameSlot<CapturedFrame>(merge: CapturedFrame.superseding)
        let buffer = try Frames.sample(try Frames.solid(width: 16, height: 32), at: 0)
        func frame(_ arrival: Double, broken: Bool) -> CapturedFrame {
            CapturedFrame(sampleBuffer: buffer, metadata: CaptureFrameMetadata(status: .complete),
                          arrivalUptime: arrival, deliveryGapMilliseconds: 33, continuityBroken: broken)
        }
        _ = slot.put(frame(1, broken: true))
        _ = slot.put(frame(2, broken: false))
        let taken = try #require(slot.take())
        #expect(taken.arrivalUptime == 2 && taken.continuityBroken)
        _ = slot.put(frame(3, broken: false))
        _ = slot.put(frame(4, broken: false))
        #expect(slot.take()?.continuityBroken == false)
    }
}

@Suite("Low Power Mode and thermal state")
struct PowerConditionsTests {
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var value = PowerConditions.State()
        var state: PowerConditions.State {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @Test("Low Power Mode, serious and critical constrain; nominal and fair do not")
    func constrains() {
        #expect(!PowerConditions.State().isConstrained)
        #expect(PowerConditions.State(lowPowerMode: true).isConstrained)
        #expect(!PowerConditions.State(thermalState: .fair).isConstrained)
        #expect(PowerConditions.State(thermalState: .serious).isConstrained)
        #expect(PowerConditions.State(thermalState: .critical).isConstrained)
    }

    @Test("Each notification rereads the state, and recognition restores as soon as it clears")
    func notifications() {
        let center = NotificationCenter(), source = Source()
        let conditions = PowerConditions(center: center, read: { source.state })
        #expect(!conditions.isConstrained)
        source.state.lowPowerMode = true
        #expect(!conditions.isConstrained, "read only when told")
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(conditions.isConstrained)
        source.state = .init(lowPowerMode: false, thermalState: .serious)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(conditions.isConstrained)
        source.state.thermalState = .fair
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(!conditions.isConstrained)
    }
}
