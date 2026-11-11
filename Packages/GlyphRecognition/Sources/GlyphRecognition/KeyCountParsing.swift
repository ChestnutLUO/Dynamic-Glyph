/// Reads the key quantity off the count strip's OCR text, and cleans the
/// portal name the name strip produced.
///
/// CountIngressKeys matches `[xX](.+)[\]1lI]` and maps lone `I`, `l`, `i`
/// and `|` to 1 — repairs for MATLAB's `ocr` on that strip. The port keeps
/// the structure (a quantity marker followed by digits) and drops the
/// letter-shaped repairs: Vision reads the marker and digits directly, and
/// where it does not, a lone wrong character should not turn into a
/// confident count.
public enum KeyCountParsing {
    /// The quantity after an `x`, `X` or `×` marker, as Ingress shows it.
    /// Without a marker, an Inventory card holds a single key — the game
    /// shows no count for it, and CountIngressKeys reads 1 — while a Capsule
    /// or Key Locker card always shows one, so any digit run there is the
    /// best available read. Out-of-range or unparsable text reads nothing.
    public static func count(in text: String, kind: KeyCardKind) -> Int? {
        if let marker = quantityRange(in: text) {
            return parsed(text[marker].dropFirst())
        }
        if kind == .inventory { return 1 }
        for token in text.split(whereSeparator: { !$0.isNumber }) {
            if let count = parsed(token) { return count }
        }
        return nil
    }

    /// The `x` and its digit run, if the text holds exactly one marker with
    /// a digit after it. The same shape of rule the gear reader applies to
    /// item quantities.
    public static func quantityRange(in text: String) -> Range<String.Index>? {
        func isDigit(_ index: String.Index) -> Bool {
            index < text.endIndex && text[index].isASCII && text[index].isNumber
        }
        let markers = text.indices.filter {
            ["x", "X", "×"].contains(text[$0]) && isDigit(text.index(after: $0))
        }
        guard markers.count == 1, let marker = markers.first else { return nil }
        var end = text.index(after: marker)
        while isDigit(end) { end = text.index(after: end) }
        return marker..<end
    }

    private static func parsed(_ text: some StringProtocol) -> Int? {
        guard let count = Int(text), (1...9999).contains(count) else { return nil }
        return count
    }
}

/// Removes the punctuation OCR leaves around a portal name, so two readings
/// of the same name compare equal. The stripped set is CountIngressKeys'
/// cleanup list; its `脘` → `院` repair stays out — that is a repair for one
/// MATLAB/Tesseract confusion pair, not a rule about names, and a
/// misread name should stay visible rather than be silently corrected.
public enum KeyNameCleaning {
    static let stripped: Set<Character> = [
        " ", "\u{00A0}", "\\", "\u{FE68}", "\u{2035}", "_", "|", "`", "\u{2016}",
        "\u{2025}", "\u{FE52}", "\u{2026}", "\u{2018}", "\u{2019}", ".", "\u{FE5C}",
        "{", "}", "-", "[", "]", "\u{3010}", "\u{3011}", "(", ")", "\u{3014}",
        "\u{3015}", "\u{FF08}", "\u{FF09}", "\u{3017}", "\u{3016}", "\u{FE5F}",
        "\u{FE5E}", ",", "\u{FF0C}", "!", "\u{FF01}", "?", "\u{FF1F}", "\"", "'",
        ":", ";", "\u{FF1A}", "\u{FF1B}", "*", "#", "/", "~"
    ]

    public static func cleaned(_ text: String) -> String {
        String(text.filter { !stripped.contains($0) })
    }
}
