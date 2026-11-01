import Foundation
import WidgetKit

/// Writes the widget's summary to the App Group and asks WidgetKit to read it
/// again. A summary that encodes to the bytes last written is skipped, so a
/// change that doesn't touch what the widget shows costs no reload.
///
/// While capturing, hacks are saved one after another and WidgetKit gives an
/// app few reloads: the file is still written every time, but the widget is
/// reloaded at most once per `captureReloadInterval`, a reload held back
/// then follows at the end of it, and at Stop and when the app comes to the
/// foreground.
@MainActor
final class SummaryWidgetPublisher {
    static let shared = SummaryWidgetPublisher(url: StatisticsWidgetSummary.fileURL) {
        WidgetCenter.shared.reloadTimelines(ofKind: StatisticsWidgetSummary.kind)
    }

    static let captureReloadInterval: TimeInterval = 5 * 60

    private let url: URL?
    private let reload: () -> Void
    private let now: () -> Date
    /// Runs the action after the interval; a task by default, a stand-in in tests.
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Nil until the first write of this run, which always happens: the file
    /// may be from before a crash or an older build.
    private var written: Data?
    private var lastReload: Date?
    /// A write the widget hasn't been reloaded for yet.
    private var reloadPending = false
    private var reloadScheduled = false

    /// A capture session is running: reloads are spaced out. Ending one
    /// reloads the widget if a write is waiting.
    var isCapturing = false {
        didSet {
            if oldValue && !isCapturing { reloadIfPending() }
        }
    }

    /// `url` nil writes nothing, as where the App Group isn't available.
    init(url: URL?, now: @escaping () -> Date = Date.init,
         schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil,
         reload: @escaping () -> Void) {
        self.url = url
        self.reload = reload
        self.now = now
        self.schedule = schedule ?? { delay, action in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                action()
            }
        }
    }

    /// `force` writes and reloads even the bytes last written, and while
    /// capturing: after a change of time zone or clock, when the same file
    /// is read for other days.
    func publish(_ summary: StatisticsWidgetSummary, force: Bool = false) {
        guard let url else { return }
        let data = try? summary.encoded()
        if !force, let data, data == written { return }
        do {
            guard let data else { throw CocoaError(.coderInvalidValue) }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            written = data
        } catch {
            // An old file could still count a deleted hack: none is better.
            try? FileManager.default.removeItem(at: url)
            written = nil
        }
        if force {
            reloadNow()
        } else {
            requestReload()
        }
    }

    /// The app came to the foreground: a reload held back goes now.
    func reloadIfPending() {
        if reloadPending { reloadNow() }
    }

    private func requestReload() {
        guard isCapturing, let lastReload else { return reloadNow() }
        let wait = Self.captureReloadInterval - now().timeIntervalSince(lastReload)
        guard wait > 0 else { return reloadNow() }
        reloadPending = true
        guard !reloadScheduled else { return }
        reloadScheduled = true
        schedule(wait) { [weak self] in
            guard let self else { return }
            reloadScheduled = false
            reloadIfPending()
        }
    }

    private func reloadNow() {
        reloadPending = false
        lastReload = now()
        reload()
    }
}
