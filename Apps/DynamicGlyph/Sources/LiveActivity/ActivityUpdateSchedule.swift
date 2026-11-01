/// Coalesces activity content using an injected monotonic clock. Freshness is
/// renewed only by an incoming observation, never by replaying a timer's cache.
struct ActivityUpdateSchedule<Content> {
    /// How often the Island may change. Faster while the player is drawing,
    /// when the Glyph to draw next is the whole point of the display; slower
    /// otherwise, because every update costs battery and system budget.
    struct Pace: Equatable {
        let minimumInterval: Double
        let refreshInterval: Double

        static var standard: Pace { Pace(minimumInterval: 0.4, refreshInterval: 1) }
        // A fresh change still gets the 0.15 s path. Re-sending unchanged
        // guidance twice a second repeatedly animates the tiny Island glyph;
        // renew well before its three-second stale deadline instead.
        static var input: Pace { Pace(minimumInterval: 0.15, refreshInterval: 1.5) }
        /// Between gear drops nothing changes but the claim that capture runs.
        static var watching: Pace { Pace(minimumInterval: 0.4, refreshInterval: 10) }
    }

    struct Update {
        let content: Content
        let key: String
        /// Expiry of the underlying observation, in host uptime. A delayed
        /// flush must not grant an old observation another freshness interval.
        let freshUntil: Double?
        let pace: Pace
    }

    /// Clock jitter allowance, as in the recorder's frame gate: without it a
    /// renewal due at exactly the interval slips to the next observation.
    private static var tolerance: Double { 0.002 }

    private(set) var pending: Update?
    /// An update has been handed to the system and not yet acknowledged.
    /// Only one is ever outstanding: two in flight can finish out of order and
    /// leave the older one on screen.
    private(set) var isSending = false
    private var lastKey: String?
    private var lastSent = -Double.infinity

    mutating func didSend(key: String, at now: Double) {
        lastKey = key
        lastSent = now
        pending = nil
    }

    /// Returns the delay until a pending update may be sent, or nil when no
    /// update is needed. Every offer supersedes the previous pending value,
    /// including an A → B → A transition back to the already displayed state.
    mutating func offer(_ content: Content, key: String, freshUntil: Double?, at now: Double,
                        pace: Pace = .standard) -> Double? {
        pending = nil
        if let freshUntil, freshUntil <= now { return nil }
        if key == lastKey {
            guard freshUntil != nil, now - lastSent >= pace.refreshInterval - Self.tolerance else { return nil }
        }
        pending = Update(content: content, key: key, freshUntil: freshUntil, pace: pace)
        return delayUntilDue(at: now)
    }

    /// Seconds until the pending update may be sent; nil when there is none.
    func delayUntilDue(at now: Double) -> Double? {
        guard let pending else { return nil }
        let delay = lastSent + pending.pace.minimumInterval - now
        return delay > Self.tolerance ? delay : 0
    }

    /// The update to send now, if one is due and none is still outstanding.
    /// A refused take keeps the pending update for the next attempt.
    mutating func take(at now: Double) -> Update? {
        guard !isSending, let update = pending,
              now >= lastSent + update.pace.minimumInterval - Self.tolerance else { return nil }
        pending = nil
        if let expiry = update.freshUntil, expiry <= now { return nil }
        didSend(key: update.key, at: now)
        isSending = true
        return update
    }

    /// The system has taken the last update.
    mutating func sendFinished() {
        isSending = false
    }
}
