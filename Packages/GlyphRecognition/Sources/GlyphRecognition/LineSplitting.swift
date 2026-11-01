extension StringProtocol {
    /// Splits on any newline, whatever the file's line endings.
    ///
    /// Not `split(separator: "\n")`: Swift treats CRLF as a single grapheme
    /// cluster, so a Character separator of `"\n"` silently fails to match it
    /// and the whole file comes back as one line. The reference data set mixes
    /// conventions — `glyph_line.csv` is LF, `glyph.csv` is CRLF — so this is
    /// load-bearing rather than defensive.
    func splitIntoLines() -> [SubSequence] {
        split(whereSeparator: \.isNewline)
    }
}
