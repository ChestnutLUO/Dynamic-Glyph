import Foundation
import CloudKit
import CoreData

/// Why iCloud sync stopped, told apart so the player knows what to do.
enum ICloudSyncProblem: Equatable {
    /// The player's iCloud storage is full: the private database counts
    /// against it.
    case storageFull
    case notSignedIn
    case offline
    /// CloudKit asked to wait; it retries by itself.
    case busy(retryAfter: TimeInterval?)
    /// CloudKit refused the app's records or container: a problem with the
    /// app's iCloud setup, such as a schema not deployed to Production,
    /// that retrying won't fix. `detail` is CloudKit's own message.
    case rejected(code: Int, detail: String?)
    /// Any other CloudKit error, by code and message, for a report.
    case other(code: Int, detail: String?)

    static let rejectedCodes: Set<CKError.Code> = [.invalidArguments, .serverRejectedRequest, .badContainer,
                                                    .missingEntitlement, .badDatabase, .incompatibleVersion,
                                                    .permissionFailure]

    /// CloudKit reports a failed batch as a partial failure holding each
    /// record's own error, and Core Data can wrap it in another error. In an
    /// atomic batch one record's error fails the rest with
    /// `batchRequestFailed`, which only points at that error.
    init(_ error: Error) {
        guard let error = Self.cloudKitError(in: error as NSError) else {
            let error = error as NSError
            self = .other(code: error.code, detail: Self.detail(of: error))
            return
        }
        let children = error.code == .partialFailure
            ? Array((error.partialErrorsByItemID ?? [:]).values).compactMap { $0 as? CKError }
            : []
        let causes = children.filter { $0.code != .batchRequestFailed }
        let errors = !causes.isEmpty ? causes : !children.isEmpty ? children : [error]
        let codes = errors.map(\.code)
        if codes.contains(.quotaExceeded) { self = .storageFull }
        else if codes.contains(.notAuthenticated) { self = .notSignedIn }
        else if codes.contains(where: { [.networkUnavailable, .networkFailure].contains($0) }) { self = .offline }
        else if let busy = errors.first(where: { [.serviceUnavailable, .requestRateLimited, .zoneBusy].contains($0.code) }) {
            self = .busy(retryAfter: busy.retryAfterSeconds ?? error.retryAfterSeconds)
        } else if let rejected = errors.first(where: { Self.rejectedCodes.contains($0.code) }) {
            self = .rejected(code: rejected.code.rawValue, detail: Self.detail(of: rejected as NSError))
        } else {
            // The most common cause, so a report names the one that matters.
            let counts = Dictionary(grouping: errors, by: \.code)
            let cause = counts.max { ($0.value.count, $1.key.rawValue) < ($1.value.count, $0.key.rawValue) }?.value.first ?? error
            self = .other(code: cause.code.rawValue, detail: Self.detail(of: cause as NSError))
        }
    }

    /// CloudKit's server message when it sent one, else the error's own text.
    private static func detail(of error: NSError) -> String? {
        // The value of CloudKit's CKErrorServerDescriptionKey, which is not in
        // its public headers.
        let text = (error.userInfo["ServerErrorDescription"] as? String) ?? error.localizedDescription
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
    }

    private static func cloudKitError(in error: NSError) -> CKError? {
        if error.domain == CKError.errorDomain { return CKError(_nsError: error) }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
        return cloudKitError(in: underlying)
    }
}

enum ICloudSyncState: Equatable {
    /// On, and nothing has finished yet.
    case starting
    case syncing
    case synced(Date)
    /// Kept until a later sync succeeds, so a retry doesn't hide it.
    case failed(ICloudSyncProblem)
}

/// Folds the store's sync events, which only say when each setup, import or
/// export starts and ends, into one state for the page.
struct ICloudSyncMonitor: Equatable {
    private(set) var state = ICloudSyncState.starting
    private var running: Set<UUID> = []
    /// Steps of a store since closed. Closing it cancels them, and however
    /// they end says nothing about the store open now.
    private var closed: Set<UUID> = []

    mutating func receive(id: UUID, type: NSPersistentCloudKitContainer.EventType, endDate: Date?,
                          succeeded: Bool, error: Error?) {
        guard let endDate else {
            running.insert(id)
            if case .failed = state { return }
            state = .syncing
            return
        }
        guard closed.remove(id) == nil else { return }
        running.remove(id)
        guard succeeded else {
            state = .failed(error.map(ICloudSyncProblem.init) ?? .other(code: 0, detail: nil))
            return
        }
        // A setup only reaches iCloud; nothing has synced until an import or
        // export ends.
        guard type != .setup else { return }
        state = running.isEmpty ? .synced(endDate) : .syncing
    }

    /// A setup, import or export has started and not ended.
    var isSyncing: Bool { !running.isEmpty }

    /// Sync was switched, so the store closes to open again: its running
    /// steps are cancelled and the status starts over.
    mutating func storeClosed() {
        closed.formUnion(running)
        running = []
        state = .starting
    }
}
