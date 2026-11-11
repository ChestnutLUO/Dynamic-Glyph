/// What OCR read off one key card, handed to `PortalKeyCounter`.
/// The count and name may both be nil: a frame that found no readable text
/// still carries its fingerprint, which is what the deduplication needs.
public struct KeyCardFrameReading: Sendable {
    /// The frame's presentation time, in seconds. Readings must arrive in
    /// increasing order.
    public let sourceTime: Double
    public let card: KeyCardBounds
    /// The name strip's digest, for the same-card decision.
    public let fingerprint: NameRegionFingerprint
    /// The parsed key quantity, when the count strip read as one.
    public let count: Int?
    /// The cleaned portal name, when the name strip read as one.
    public let name: String?

    public init(sourceTime: Double, card: KeyCardBounds, fingerprint: NameRegionFingerprint,
                count: Int?, name: String?) {
        self.sourceTime = sourceTime; self.card = card
        self.fingerprint = fingerprint; self.count = count; self.name = name
    }
}
