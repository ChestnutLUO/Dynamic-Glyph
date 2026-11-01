import Foundation

extension GearDropEntry.Rarity {
    public var label: String {
        switch self {
        case .common: return String(localized: "Common", bundle: #bundle, comment: "Item rarity badge, read from one green bar.")
        case .rare: return String(localized: "Rare", bundle: #bundle, comment: "Item rarity badge, read from two purple bars.")
        case .veryRare: return String(localized: "Very rare", bundle: #bundle, comment: "Item rarity badge, read from three pink bars.")
        case .unreadable: return String(localized: "Rarity unread", bundle: #bundle, comment: "Item rarity badge: its meter could not be confirmed.")
        }
    }
}

/// Small, confirmed display facts shared by PiP and the Live Activity.
public struct GearDropDisplay: Sendable, Equatable, Hashable, Codable {
    public enum State: String, Sendable, Codable {
        case waiting, reading, read, partial, unattached, notRead
        /// Gear-only capture between drops; `itemCount` is the capture's items so far.
        case watching
    }
    public let state: State
    public let hackID: Int?
    public let itemCount: Int?
    public let waitingCount: Int

    public init(state: State, hackID: Int?, itemCount: Int? = nil, waitingCount: Int = 0) {
        self.state = state; self.hackID = hackID; self.itemCount = itemCount; self.waitingCount = waitingCount
    }

    public var renderKey: String { "\(state.rawValue):\(hackID ?? -1):\(itemCount ?? -1):\(waitingCount)" }
    public var symbol: String {
        switch state {
        case .waiting: return "hourglass"
        case .watching: return "shippingbox"
        case .reading: return "viewfinder"
        case .read: return "shippingbox.fill"
        case .partial, .unattached, .notRead: return "exclamationmark.triangle"
        }
    }
    /// Waiting counts are queued hacks; completed counts are recognized items.
    public var compactValue: String { itemCount.map(String.init) ?? (waitingCount > 0 ? String(waitingCount) : "–") }
    public var tone: StatusTone {
        switch state {
        case .waiting, .watching: return .idle
        case .reading: return .collecting
        case .read: return .done
        case .partial, .unattached, .notRead: return .tentative
        }
    }
    public func message(currentHackID: Int) -> String {
        let text: String
        switch state {
        case .waiting:
            text = String(localized: "Waiting for gear…", bundle: #bundle, comment: "Floating display: keep the game visible until item panels arrive.")
        case .reading:
            text = String(localized: "Reading gear…", bundle: #bundle, comment: "Floating display: item panels are being read.")
        case .read:
            text = String(localized: "\(itemCount ?? 0) items read", bundle: #bundle, comment: "Floating display: count of recognized items in both panels, not total inventory.")
        case .partial:
            text = String(localized: "Gear partly read · \(itemCount ?? 0) recognized", bundle: #bundle, comment: "Floating display: count of identified items; some evidence is missing.")
        case .unattached:
            text = String(localized: "Gear read · hack uncertain", bundle: #bundle, comment: "Floating display: a drop group cannot be assigned to a hack.")
        case .notRead:
            text = String(localized: "Gear not read", bundle: #bundle, comment: "Floating display: waiting for item panels ended without a reading.")
        case .watching:
            text = (itemCount ?? 0) > 0
                ? String(localized: "Watching for gear · \(itemCount ?? 0) items so far", bundle: #bundle, comment: "Floating display, gear-only capture: items recognized since Start, not total inventory.")
                : String(localized: "Watching for gear", bundle: #bundle, comment: "Floating display, gear-only capture: no item panel yet.")
        }
        if let hackID, hackID != currentHackID {
            return String(localized: "Earlier hack · \(text)", bundle: #bundle, comment: "Floating display: the placeholder is the gear status of an earlier queued hack.")
        }
        return text
    }
}

/// Holds a completion long enough to survive Activity update coalescing, then
/// returns to the remaining queue. A new capture creates a fresh instance.
public struct GearDropDisplayTracker: Sendable {
    public private(set) var display: GearDropDisplay?
    public private(set) var revision = 0
    private var completion: GearDropDisplay?
    private var completedAt = -Double.infinity
    /// Gear-only capture: no Glyph hack is tracked, so a group belongs to no
    /// hack by design, and between drops the display says it is watching.
    private let standalone: Bool
    private var standaloneItems = 0
    public init(standalone: Bool = false) { self.standalone = standalone }

    public mutating func finished(_ group: GearDropSummary) {
        // The last group's Bonus panel found again adds nothing: that group's
        // completion stays.
        guard group.association != .repeatedBonus else { return }
        let state: GearDropDisplay.State
        if standalone {
            // Without a Glyph hack there is no Bonus panel to expect: what
            // counts is that every panel shown was read in full.
            state = group.panelsReadInFull ? .read : .partial
            standaloneItems += group.recognizedQuantity
        } else {
            state = group.hackID == nil ? .unattached
                : group.bothPanelsRead && group.unidentifiedQuantity == 0 ? .read : .partial
        }
        completion = GearDropDisplay(state: state, hackID: group.hackID, itemCount: group.recognizedQuantity)
        completedAt = group.closedAt
    }

    public mutating func ended(hackID: Int, at time: Double) {
        // An unattached reading is more informative than its queue retirement.
        guard completedAt != time else { return }
        completion = GearDropDisplay(state: .notRead, hackID: hackID)
        completedAt = time
    }

    public mutating func update(waiting: [GearDropObservationSession.Wait], reading: Bool,
                                associationUncertain: Bool, at time: Double) {
        let next: GearDropDisplay?
        if let completion, time >= completedAt, time - completedAt < 4 {
            next = completion
        } else if reading || !waiting.isEmpty {
            next = GearDropDisplay(state: reading ? .reading : .waiting,
                hackID: associationUncertain ? nil : waiting.first?.hackID, waitingCount: waiting.count)
        } else if standalone {
            next = GearDropDisplay(state: .watching, hackID: nil, itemCount: standaloneItems)
        } else { next = nil }
        if next != display { display = next; revision += 1 }
    }
}
