extension Double {
    /// Seconds with millisecond resolution, for log reasons and display text.
    /// Written by hand because the recognition core deliberately imports no
    /// modules at all, not even Foundation.
    var secondsDescription: String {
        guard isFinite else { return "\(self) s" }
        let milliseconds = Int((self * 1000).rounded())
        let sign = milliseconds < 0 ? "-" : ""
        let magnitude = abs(milliseconds)
        let fraction = String(magnitude % 1000)
        let padded = String(repeating: "0", count: 3 - fraction.count) + fraction
        return "\(sign)\(magnitude / 1000).\(padded) s"
    }
}
