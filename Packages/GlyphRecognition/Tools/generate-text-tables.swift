// Writes Sources/GlyphCoreCxx/text_tables.inc: the Unicode data the C++ text
// functions need to equal Swift's `GameText.normalized`, `compactTransmuter`
// and the String operations the matchers use.
//
// Every table is read from Swift itself on this toolchain, over every scalar
// 0...0x10FFFF, so the C++ follows the runtime's Unicode version:
//   - letter or number: `Character(s).isLetter || .isNumber`
//   - whitespace: `Character(s).isWhitespace`; the trim set is Foundation's
//     `CharacterSet.whitespaces`
//   - lowercase: `String(Character(s)).lowercased()` where it differs
//   - whole numbers 1...8: `Character(s).wholeNumberValue`
//   - grapheme break behaviour, measured with `String.count` on short probes
//     (see `breakClass`), since the property itself is not public
//   - canonical combining class (`properties.canonicalCombiningClass`) and
//     canonical decompositions (Foundation, each checked equal under Swift's
//     own `==`), for the canonical equivalence Swift's comparisons use
//
// Run from Packages/GlyphRecognition: `swift Tools/generate-text-tables.swift`.

import Foundation

func scalars(_ values: [UInt32]) -> String {
    var view = String.UnicodeScalarView()
    for value in values { view.append(Unicode.Scalar(value)!) }
    return String(view)
}

func count(_ values: [UInt32]) -> Int { scalars(values).count }

let a: UInt32 = 0x61, extend: UInt32 = 0x300, zwj: UInt32 = 0x200D, pict: UInt32 = 0x1F600
let hangulL: UInt32 = 0x1100, hangulV: UInt32 = 0x1161, hangulT: UInt32 = 0x11A8, hangulLV: UInt32 = 0xAC00
let consonant: UInt32 = 0x915, linker: UInt32 = 0x94D

/// Grapheme break classes, in the order of `gl_break_class` in logic_text_internal.hpp.
enum BreakClass: Int {
    case other, cr, lf, control, extend, zwj, spacingMark, prepend, regionalIndicator, l, v, t, lv, lvt, pictographic
}

func breakClass(_ s: UInt32) -> BreakClass {
    if s == 0x0D { return .cr }
    if s == 0x0A { return .lf }
    // A control breaks even before a combining mark; nothing else does.
    if count([a, s]) == 2, count([s, extend]) == 2 { return .control }
    if count([s, a]) == 1 { return .prepend }
    if count([a, s]) == 1 {
        if count([pict, s, pict]) == 1 { return .zwj }
        // Only Extend may sit between a pictograph and the joiner (GB11).
        return count([pict, s, zwj, pict]) == 1 ? .extend : .spacingMark
    }
    if count([hangulL, s]) == 1 {
        if count([s, hangulL]) == 1 { return .l }
        if count([s, hangulV]) == 1 { return count([hangulV, s]) == 1 ? .v : .lv }
        if count([s, hangulT]) == 1 { return .lvt }
        fatalError(String(format: "unclassified Hangul %04X", s))
    }
    if count([hangulT, s]) == 1, count([hangulLV, s]) == 1 { return .t }
    if count([s, s]) == 1, count([s, s, s]) == 2 { return .regionalIndicator }
    if count([s, zwj, pict]) == 1 { return .pictographic }
    return .other
}

/// Indic conjunct break (GB9c): 1 consonant, 2 linker, 3 extend.
func conjunctClass(_ s: UInt32, _ kind: BreakClass) -> Int {
    switch kind {
    case .extend, .zwj, .spacingMark:
        if count([consonant, s, consonant]) == 1 { return 2 }
        if count([consonant, s, linker, consonant]) == 1 { return 3 }
        return 0
    case .other:
        return count([s, linker, consonant]) == 1 ? 1 : 0
    default:
        return 0
    }
}

struct Ranges {
    var items: [(lo: UInt32, hi: UInt32, value: Int)] = []
    mutating func add(_ s: UInt32, _ value: Int) {
        if let last = items.last, last.hi + 1 == s, last.value == value { items[items.count - 1].hi = s }
        else { items.append((s, s, value)) }
    }
}

var letterOrNumber = Ranges(), whitespace = Ranges(), trim = Ranges(), breaks = Ranges(), conjunct = Ranges()
var combining = Ranges()
var lowerSingle: [(UInt32, UInt32)] = []
var lowerMulti: [(UInt32, [UInt32])] = []
var wholeNumbers: [(UInt32, Int)] = []
var decompositions: [(UInt32, [UInt32])] = []

for value in UInt32(0)...0x10FFFF {
    guard let scalar = Unicode.Scalar(value) else { continue }
    let character = Character(scalar)
    if character.isLetter || character.isNumber { letterOrNumber.add(value, 1) }
    if character.isWhitespace { whitespace.add(value, 1) }
    if CharacterSet.whitespaces.contains(scalar) { trim.add(value, 1) }
    let lower = String(character).lowercased().unicodeScalars.map(\.value)
    if lower.count == 1, lower[0] != value { lowerSingle.append((value, lower[0])) }
    if lower.count > 1 { lowerMulti.append((value, lower)) }
    if let number = character.wholeNumberValue, (1...8).contains(number) { wholeNumbers.append((value, number)) }
    let kind = breakClass(value)
    if kind != .other { breaks.add(value, kind.rawValue) }
    let conjunctKind = conjunctClass(value, kind)
    if conjunctKind != 0 { conjunct.add(value, conjunctKind) }
    let ccc = Int(scalar.properties.canonicalCombiningClass.rawValue)
    if ccc != 0 { combining.add(value, ccc) }
    // Hangul syllables decompose algorithmically in the C++.
    if !(0xAC00...0xD7A3).contains(value) {
        let decomposed = String(character).decomposedStringWithCanonicalMapping
        let parts = decomposed.unicodeScalars.map(\.value)
        if parts != [value] {
            guard String(character) == decomposed else {
                fatalError(String(format: "Foundation's decomposition of %04X is not equal under Swift", value))
            }
            decompositions.append((value, parts))
        }
    }
}

func hex(_ value: UInt32) -> String { String(format: "0x%04X", value) }

var out = """
// Generated by Tools/generate-text-tables.swift from Swift's own Unicode
// data. Do not edit; run `swift Tools/generate-text-tables.swift` from
// Packages/GlyphRecognition instead.
// \(ProcessInfo.processInfo.operatingSystemVersionString)

"""

func emitRanges(_ name: String, _ ranges: Ranges, valued: Bool) {
    if valued {
        out += "static const gl_text_valued_range \(name)[] = {\n"
        for item in ranges.items { out += "    {\(hex(item.lo)), \(hex(item.hi)), \(item.value)},\n" }
    } else {
        out += "static const gl_text_range \(name)[] = {\n"
        for item in ranges.items { out += "    {\(hex(item.lo)), \(hex(item.hi))},\n" }
    }
    out += "};\n\n"
}

emitRanges("kLetterOrNumber", letterOrNumber, valued: false)
emitRanges("kWhitespace", whitespace, valued: false)
emitRanges("kTrimWhitespace", trim, valued: false)
emitRanges("kBreakClass", breaks, valued: true)
emitRanges("kConjunctClass", conjunct, valued: true)
emitRanges("kCombiningClass", combining, valued: true)

out += "static const gl_text_pair kLowercase[] = {\n"
for (from, to) in lowerSingle { out += "    {\(hex(from)), \(hex(to))},\n" }
out += "};\n\n"

out += "static const gl_text_expansion kLowercaseMulti[] = {\n"
for (from, parts) in lowerMulti {
    precondition(parts.count <= 3)
    let padded = parts + Array(repeating: 0, count: 3 - parts.count)
    out += "    {\(hex(from)), \(parts.count), {\(padded.map(hex).joined(separator: ", "))}},\n"
}
out += "};\n\n"

out += "static const gl_text_pair kWholeNumberOneToEight[] = {\n"
for (scalar, number) in wholeNumbers { out += "    {\(hex(scalar)), \(number)},\n" }
out += "};\n\n"

var flat: [UInt32] = []
out += "static const gl_text_decomposition kDecomposition[] = {\n"
for (scalar, parts) in decompositions {
    out += "    {\(hex(scalar)), \(flat.count), \(parts.count)},\n"
    flat += parts
}
out += "};\n\n"
out += "static const char32_t kDecompositionScalars[] = {\n"
for start in stride(from: 0, to: flat.count, by: 10) {
    out += "    " + flat[start..<min(flat.count, start + 10)].map(hex).joined(separator: ", ") + ",\n"
}
out += "};\n"

let target = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sources/GlyphCoreCxx/text_tables.inc")
try out.write(to: target, atomically: true, encoding: .utf8)
print("wrote \(target.path): \(letterOrNumber.items.count) letter/number ranges, \(lowerSingle.count) lowercase pairs, "
      + "\(lowerMulti.count) multi, \(breaks.items.count) break ranges, \(conjunct.items.count) conjunct ranges, "
      + "\(combining.items.count) ccc ranges, \(decompositions.count) decompositions, \(wholeNumbers.count) numbers")
