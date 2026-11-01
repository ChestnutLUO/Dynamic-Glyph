/// Rate limiting is based on the last snapshot actually queued, not the last
/// observation. A transition skipped by the limiter remains eligible while
/// its shape is still visible. Never accumulate pending images in this value.
struct SnapshotSchedule {
    private var lastKey: String?
    private var lastTime = -Double.infinity
    private(set) var count = 0

    func wantsSnapshot(key: String, at time: Double) -> Bool {
        count < 400 && key != lastKey && (time < lastTime || time - lastTime >= 0.19)
    }

    mutating func didQueue(key: String, at time: Double) {
        lastKey = key
        lastTime = time
        count += 1
    }
}
