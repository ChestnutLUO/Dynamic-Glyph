import Foundation
import Testing
import GlyphRecognition
@testable import GlyphRecognitionImages

/// Which rows a gear read rereads on its own frame. Constrained capture (Low
/// Power Mode, a hot phone) used to reread none; it now rereads, once, a row
/// the panel read left unparsed, as a red "x1 Portal Key" was in all five
/// reads of a 2026-10-27 portal panel.
@Suite("Gear row rereads")
struct GearRowRereadTests {
    static func entry(_ column: Int, _ row: Int, item: String? = "Resonator", level: Int? = 7,
                      quantity: Int = 1, red: Bool? = false) -> GearDropEntry {
        GearDropEntry(column: column, row: row, item: item, levelState: level == nil ? .notApplicable : .known,
                      level: level, quantity: quantity, multiplied: red)
    }

    func rereads(_ positions: Set<Int>, _ entries: [GearDropEntry], unreadable: Int,
                 _ scope: GearDropScreenReader.RowRereads, asked: inout [Int]) -> [Int] {
        var log: [Int] = []
        let result = GearDropScreenReader.rereadPositions(positions, entries: entries, unreadableRows: unreadable,
                                                          scope: scope) { log.append($0.position); return $0.multiplied }
        asked = log
        return result
    }

    @Test("Constrained: one reread of the unparsed row, none of a red or read one")
    func constrainedUnparsedRow() {
        // The hack 4 portal panel: the key's column unparsed, a red L7 Resonator read.
        var asked: [Int] = []
        let read = [Self.entry(1, 0, red: true)]
        #expect(rereads([0, 1], read, unreadable: 1, .unparsed, asked: &asked) == [0])
        #expect(asked.isEmpty, "no colour check, and no pixels for it")
        // Nothing counted unreadable: no reread, so an odd panel's empty
        // column costs no OCR pass.
        #expect(rereads([0, 1], read, unreadable: 0, .unparsed, asked: &asked).isEmpty)
        // Several unparsed rows: each once, in order.
        #expect(rereads([0, 1, 2, 3], read, unreadable: 2, .unparsed, asked: &asked) == [0, 2, 3])
        // A row read without a name is an entry, not an unreadable row.
        #expect(rereads([0, 1], [Self.entry(0, 0, item: nil), Self.entry(1, 0)], unreadable: 1, .unparsed,
                        asked: &asked).isEmpty)
    }

    @Test("Unconstrained rereads are unchanged: unparsed, unnamed, level unread, or not clearly white")
    func unresolvedRows() {
        var asked: [Int] = []
        let entries = [Self.entry(0, 0, red: false), Self.entry(1, 0, red: true), Self.entry(0, 1, item: nil),
                       Self.entry(1, 1, red: nil),
                       GearDropEntry(column: 0, row: 2, item: "XMP Burster", levelState: .unreadable,
                                     level: nil, quantity: 2, multiplied: false)]
        #expect(rereads([0, 1, 2, 3, 4, 5], entries, unreadable: 0, .unresolved, asked: &asked) == [1, 2, 3, 4, 5])
        #expect(asked == [0, 1, 3], "colour is asked only when it decides")
    }
}
