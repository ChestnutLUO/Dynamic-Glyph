import Testing
@testable import GlyphRecognition

struct KeyCountParsingTests {
    @Test("A quantity marker and its digits read as the count")
    func markers() {
        #expect(KeyCountParsing.count(in: "x12", kind: .inventory) == 12)
        #expect(KeyCountParsing.count(in: "X105", kind: .capsule) == 105)
        #expect(KeyCountParsing.count(in: "×3", kind: .capsule) == 3)
        #expect(KeyCountParsing.count(in: "x12l", kind: .capsule) == 12)
        // A gap between the marker and its digits is an OCR artifact; the
        // digit run after it is still the best available read.
        #expect(KeyCountParsing.count(in: "  x 7 ", kind: .capsule) == 7)
    }

    @Test("An Inventory card without a marker holds one key")
    func inventoryDefault() {
        #expect(KeyCountParsing.count(in: "", kind: .inventory) == 1)
        #expect(KeyCountParsing.count(in: "unparsable", kind: .inventory) == 1)
    }

    @Test("A Capsule card without a marker reads nothing rather than a guess")
    func capsuleNeedsEvidence() {
        #expect(KeyCountParsing.count(in: "", kind: .capsule) == nil)
        #expect(KeyCountParsing.count(in: "unparsable", kind: .capsule) == nil)
        #expect(KeyCountParsing.count(in: "x0", kind: .capsule) == nil) // zero is not a count
        #expect(KeyCountParsing.count(in: "x10000", kind: .capsule) == nil) // beyond any real stack
    }

    @Test("A digit run without a marker is the Capsule card's best read")
    func digitRun() {
        #expect(KeyCountParsing.count(in: "42", kind: .capsule) == 42)
    }

    @Test("A doubled marker still falls through to the digit run")
    func doubledMarker() {
        #expect(KeyCountParsing.count(in: "xx12", kind: .capsule) == 12)
    }

    @Test("Names lose the punctuation OCR scatters around them")
    func cleaning() {
        #expect(KeyNameCleaning.cleaned(" Test Portal ") == "TestPortal")
        #expect(KeyNameCleaning.cleaned("台北【101】大楼") == "台北101大楼")
        #expect(KeyNameCleaning.cleaned("(A - B)_2024?") == "AB2024")
        #expect(KeyNameCleaning.cleaned("").isEmpty)
    }
}
