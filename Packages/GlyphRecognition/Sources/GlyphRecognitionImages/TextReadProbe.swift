import Foundation
import os

/// The screen a Vision text request was reading, for the app's power readout.
public enum TextReadKind: Int, CaseIterable, Sendable {
    case headerFast, headerAccurate, resultPanel, commandNotice, droneFooter, gearPanel, portalScreen
    /// The drone footer read fast, for English; `droneFooter` is accurate.
    case droneFooterFast
}

/// Times each Vision text request, for the Diagnostics page's Power section.
/// Measurement only: it changes nothing about what is read or when. With no
/// observer set, as in the replay tool and the package's tests, a request
/// costs two clock reads and one uncontended lock.
public enum TextReadProbe {
    /// Called on the reading thread with the request's duration in
    /// nanoseconds, failed requests included. Must be cheap.
    public typealias Observer = @Sendable (TextReadKind, UInt64) -> Void

    /// Boxed: a closure kept directly in the lock's generic state is written
    /// back through `withLock`'s `inout` on every read, wrapped in one more
    /// pair of reabstraction thunks each time, until a call overflows the
    /// stack (build 97). A class reference is stored and read as it is.
    private final class ObserverBox: Sendable {
        let call: Observer
        init(_ call: @escaping Observer) { self.call = call }
    }

    private static let observer = OSAllocatedUnfairLock<ObserverBox?>(initialState: nil)

    public static func setObserver(_ newValue: Observer?) {
        let box = newValue.map { ObserverBox($0) }
        observer.withLock { $0 = box }
    }

    @inline(__always)
    static func start() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func finish(_ kind: TextReadKind, since started: UInt64) {
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- started
        observer.withLock { $0 }?.call(kind, elapsed)
    }

    /// Runs one synchronous Vision call and reports how long it took.
    static func measure<T>(_ kind: TextReadKind, _ body: () throws -> T) rethrows -> T {
        let started = start()
        defer { finish(kind, since: started) }
        return try body()
    }
}
