// Text normalization shared by every parser (glyph_common.h), and the Swift
// String semantics the pace area's matchers use (logic_text_internal.hpp).
//
// What Swift does, measured on this toolchain (Tools/generate-text-tables.swift
// reads the tables from Swift itself; CxxTextTests checks every scalar and
// mixed strings against Swift):
//
// - `lowercased()` maps each scalar on its own, with no context (no final
//   sigma); U+0130 is the one scalar whose lowercase is two scalars.
// - `filter` runs over Characters, extended grapheme clusters, and keeps or
//   drops a whole cluster. `Character.isLetter`, `isNumber` and
//   `isWhitespace` are the first scalar's: "e" + U+0301 is a letter and
//   keeps its accent, " " + U+0301 is whitespace and loses it, U+FF9F alone
//   is a letter but after a space is dropped with it.
// - The clusters are UAX #29's with Swift's data, including the Indic
//   conjunct rule (GB9c). The break classes are measured from `String.count`
//   on short probes, since Swift does not expose the property.
// - Equality, dictionary keys, `hasPrefix`, `hasSuffix`, `contains` and
//   Character comparison are canonical equivalence, Character by Character:
//   "ポ" equals "ホ" + U+309A, and a precomposed Hangul syllable its jamo.

#include "logic_text_internal.hpp"
#include "glyph_logic_pace.h"

#include <algorithm>
#include <cstring>

namespace glyph_text {
namespace {

struct gl_text_range {
    char32_t lo;
    char32_t hi;
};

struct gl_text_valued_range {
    char32_t lo;
    char32_t hi;
    int value;
};

struct gl_text_pair {
    char32_t from;
    char32_t to;
};

struct gl_text_expansion {
    char32_t from;
    int count;
    char32_t parts[3];
};

struct gl_text_decomposition {
    char32_t scalar;
    int offset;
    int length;
};

#include "text_tables.inc"

enum BreakClass {
    kOther = 0, kCR, kLF, kControl, kExtend, kZWJ, kSpacingMark, kPrepend, kRegionalIndicator,
    kL, kV, kT, kLV, kLVT, kPictographic
};

enum ConjunctClass { kConjunctNone = 0, kConsonant, kLinker, kConjunctExtend };

template <typename Range, std::size_t N>
const Range *findRange(const Range (&ranges)[N], char32_t scalar) {
    const Range *end = ranges + N;
    const Range *found = std::upper_bound(ranges, end, scalar,
                                          [](char32_t value, const Range &range) { return value < range.lo; });
    if (found == ranges) return nullptr;
    --found;
    return scalar <= found->hi ? found : nullptr;
}

template <std::size_t N>
int valueIn(const gl_text_valued_range (&ranges)[N], char32_t scalar) {
    const gl_text_valued_range *range = findRange(ranges, scalar);
    return range ? range->value : 0;
}

template <std::size_t N>
const gl_text_pair *findPair(const gl_text_pair (&pairs)[N], char32_t scalar) {
    const gl_text_pair *end = pairs + N;
    const gl_text_pair *found = std::lower_bound(pairs, end, scalar,
                                                 [](const gl_text_pair &pair, char32_t value) { return pair.from < value; });
    return found != end && found->from == scalar ? found : nullptr;
}

bool isLetterOrNumber(char32_t scalar) { return findRange(kLetterOrNumber, scalar) != nullptr; }

int breakClass(char32_t scalar) { return valueIn(kBreakClass, scalar); }

int conjunctClass(char32_t scalar) { return valueIn(kConjunctClass, scalar); }

int combiningClass(char32_t scalar) { return valueIn(kCombiningClass, scalar); }

constexpr char32_t kHangulBase = 0xAC00, kHangulLBase = 0x1100, kHangulVBase = 0x1161, kHangulTBase = 0x11A7;
constexpr int kHangulVCount = 21, kHangulTCount = 28, kHangulCount = 11172;

void appendDecomposition(char32_t scalar, Scalars &out) {
    if (scalar >= kHangulBase && scalar < kHangulBase + kHangulCount) {
        const int index = static_cast<int>(scalar - kHangulBase);
        out.push_back(kHangulLBase + index / (kHangulVCount * kHangulTCount));
        out.push_back(kHangulVBase + (index % (kHangulVCount * kHangulTCount)) / kHangulTCount);
        if (index % kHangulTCount != 0) out.push_back(kHangulTBase + index % kHangulTCount);
        return;
    }
    const gl_text_decomposition *end = kDecomposition + sizeof(kDecomposition) / sizeof(kDecomposition[0]);
    const gl_text_decomposition *found = std::lower_bound(
        kDecomposition, end, scalar, [](const gl_text_decomposition &entry, char32_t value) { return entry.scalar < value; });
    if (found != end && found->scalar == scalar) {
        out.append(kDecompositionScalars + found->offset, static_cast<std::size_t>(found->length));
    } else {
        out.push_back(scalar);
    }
}

/** Canonical decomposition with canonical ordering: NFD. */
Scalars decompose(const Scalars &scalars, std::size_t begin, std::size_t end) {
    Scalars out;
    out.reserve(end - begin);
    for (std::size_t index = begin; index < end; ++index) appendDecomposition(scalars[index], out);
    // Reorder each run of non-starters by combining class, stably.
    std::size_t index = 0;
    while (index < out.size()) {
        if (combiningClass(out[index]) == 0) { ++index; continue; }
        std::size_t runEnd = index;
        while (runEnd < out.size() && combiningClass(out[runEnd]) != 0) ++runEnd;
        std::stable_sort(out.begin() + static_cast<std::ptrdiff_t>(index), out.begin() + static_cast<std::ptrdiff_t>(runEnd),
                         [](char32_t a, char32_t b) { return combiningClass(a) < combiningClass(b); });
        index = runEnd;
    }
    return out;
}

bool isControlClass(int kind) { return kind == kCR || kind == kLF || kind == kControl; }

}  // namespace

Scalars decode(gc_string text) {
    Scalars out;
    if (!text.bytes || text.length <= 0) return out;
    const auto *bytes = reinterpret_cast<const unsigned char *>(text.bytes);
    const std::size_t length = static_cast<std::size_t>(text.length);
    out.reserve(length);
    std::size_t index = 0;
    while (index < length) {
        const unsigned char lead = bytes[index];
        if (lead < 0x80) { out.push_back(lead); ++index; continue; }
        int needed = 0;
        char32_t scalar = 0;
        unsigned char lowest = 0x80, highest = 0xBF;
        if (lead >= 0xC2 && lead <= 0xDF) { needed = 1; scalar = lead & 0x1F; }
        else if (lead >= 0xE0 && lead <= 0xEF) {
            needed = 2; scalar = lead & 0x0F;
            if (lead == 0xE0) lowest = 0xA0;
            if (lead == 0xED) highest = 0x9F;
        } else if (lead >= 0xF0 && lead <= 0xF4) {
            needed = 3; scalar = lead & 0x07;
            if (lead == 0xF0) lowest = 0x90;
            if (lead == 0xF4) highest = 0x8F;
        } else {
            out.push_back(0xFFFD); ++index; continue;
        }
        // The maximal valid prefix of a sequence becomes one U+FFFD.
        std::size_t next = index + 1;
        int taken = 0;
        while (taken < needed && next < length) {
            const unsigned char byte = bytes[next];
            const unsigned char low = taken == 0 ? lowest : 0x80, high = taken == 0 ? highest : 0xBF;
            if (byte < low || byte > high) break;
            scalar = (scalar << 6) | (byte & 0x3F);
            ++next; ++taken;
        }
        out.push_back(taken == needed ? scalar : 0xFFFD);
        index = next;
    }
    return out;
}

Scalars decode(const std::string &text) {
    return decode(gc_string{text.data(), static_cast<int32_t>(text.size())});
}

std::string encode(const Scalars &scalars) {
    std::string out;
    out.reserve(scalars.size());
    for (char32_t scalar : scalars) {
        if (scalar < 0x80) {
            out.push_back(static_cast<char>(scalar));
        } else if (scalar < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (scalar >> 6)));
            out.push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
        } else if (scalar < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (scalar >> 12)));
            out.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (scalar >> 18)));
            out.push_back(static_cast<char>(0x80 | ((scalar >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
        }
    }
    return out;
}

Scalars lowercased(const Scalars &scalars) {
    Scalars out;
    out.reserve(scalars.size());
    for (char32_t scalar : scalars) {
        if (const gl_text_pair *pair = findPair(kLowercase, scalar)) { out.push_back(pair->to); continue; }
        bool expanded = false;
        for (const gl_text_expansion &expansion : kLowercaseMulti) {
            if (expansion.from != scalar) continue;
            out.append(expansion.parts, static_cast<std::size_t>(expansion.count));
            expanded = true;
            break;
        }
        if (!expanded) out.push_back(scalar);
    }
    return out;
}

std::vector<std::size_t> clusterStarts(const Scalars &scalars) {
    std::vector<std::size_t> starts;
    if (scalars.empty()) return starts;
    starts.push_back(0);
    int previous = breakClass(scalars[0]);
    int regionalRun = previous == kRegionalIndicator ? 1 : 0;
    // GB11: 1 after a pictograph and Extends, 2 after those and a ZWJ.
    int pictographic = previous == kPictographic ? 1 : 0;
    // GB9c: 1 after a consonant and conjunct Extends, 2 once a linker followed.
    int conjunct = conjunctClass(scalars[0]) == kConsonant ? 1 : 0;
    for (std::size_t index = 1; index < scalars.size(); ++index) {
        const int current = breakClass(scalars[index]);
        const int currentConjunct = conjunctClass(scalars[index]);
        bool join;
        if (previous == kCR && current == kLF) join = true;                                  // GB3
        else if (isControlClass(previous) || isControlClass(current)) join = false;          // GB4, GB5
        else if (previous == kL && (current == kL || current == kV || current == kLV || current == kLVT)) join = true;  // GB6
        else if ((previous == kLV || previous == kV) && (current == kV || current == kT)) join = true;  // GB7
        else if ((previous == kLVT || previous == kT) && current == kT) join = true;         // GB8
        else if (current == kExtend || current == kZWJ || current == kSpacingMark) join = true;  // GB9, GB9a
        else if (previous == kPrepend) join = true;                                          // GB9b
        else if (currentConjunct == kConsonant && conjunct == 2) join = true;                // GB9c
        else if (previous == kZWJ && current == kPictographic && pictographic == 2) join = true;  // GB11
        else if (previous == kRegionalIndicator && current == kRegionalIndicator) join = regionalRun % 2 == 1;  // GB12, GB13
        else join = false;                                                                   // GB999
        if (!join) starts.push_back(index);

        regionalRun = current == kRegionalIndicator ? regionalRun + 1 : 0;
        if (current == kPictographic) pictographic = 1;
        else if (current == kExtend && pictographic == 1) pictographic = 1;
        else if (current == kZWJ && pictographic == 1) pictographic = 2;
        else pictographic = 0;
        if (currentConjunct == kConsonant) conjunct = 1;
        else if (currentConjunct == kLinker && conjunct >= 1) conjunct = 2;
        else if (currentConjunct == kConjunctExtend && conjunct >= 1) { /* unchanged */ }
        else conjunct = 0;
        previous = current;
    }
    return starts;
}

bool isWhitespaceCharacter(char32_t first) { return findRange(kWhitespace, first) != nullptr; }

int wholeNumberOneToEight(const Scalars &cluster) {
    if (cluster.size() != 1) return 0;
    const gl_text_pair *pair = findPair(kWholeNumberOneToEight, cluster[0]);
    return pair ? static_cast<int>(pair->to) : 0;
}

Scalars normalized(const Scalars &scalars) {
    const Scalars lower = lowercased(scalars);
    const std::vector<std::size_t> starts = clusterStarts(lower);
    Scalars out;
    out.reserve(lower.size());
    for (std::size_t index = 0; index < starts.size(); ++index) {
        const std::size_t begin = starts[index], end = index + 1 < starts.size() ? starts[index + 1] : lower.size();
        if (isLetterOrNumber(lower[begin])) out.append(lower, begin, end - begin);
    }
    return out;
}

Scalars compactTransmuter(const Scalars &scalars) {
    const Scalars lower = lowercased(scalars);
    std::vector<std::size_t> starts = clusterStarts(lower);
    Scalars kept;
    kept.reserve(lower.size());
    for (std::size_t index = 0; index < starts.size(); ++index) {
        const std::size_t begin = starts[index], end = index + 1 < starts.size() ? starts[index + 1] : lower.size();
        if (!isWhitespaceCharacter(lower[begin])) kept.append(lower, begin, end - begin);
    }
    // `filter` made a new String: its Characters are found again before `map`.
    starts = clusterStarts(kept);
    Scalars out;
    out.reserve(kept.size());
    for (std::size_t index = 0; index < starts.size(); ++index) {
        const std::size_t begin = starts[index], end = index + 1 < starts.size() ? starts[index + 1] : kept.size();
        if (end - begin == 1) {
            switch (kept[begin]) {
            case 0x2212: case 0xFF0D: case 0x2013: case 0x2014: case 0x2010: out.push_back(U'-'); continue;
            case 0xFF0B: out.push_back(U'+'); continue;
            case 0xFF08: out.push_back(U'('); continue;
            case 0xFF09: out.push_back(U')'); continue;
            default: break;
            }
        }
        out.append(kept, begin, end - begin);
    }
    return out;
}

Scalars trimmingWhitespaces(const Scalars &scalars) {
    std::size_t begin = 0, end = scalars.size();
    while (begin < end && findRange(kTrimWhitespace, scalars[begin])) ++begin;
    while (end > begin && findRange(kTrimWhitespace, scalars[end - 1])) --end;
    return scalars.substr(begin, end - begin);
}

Text::Text(Scalars scalars) : scalars_(std::move(scalars)), starts_(clusterStarts(scalars_)) {
    keys_.reserve(starts_.size());
    for (std::size_t index = 0; index < starts_.size(); ++index) {
        const std::size_t end = index + 1 < starts_.size() ? starts_[index + 1] : scalars_.size();
        keys_.push_back(decompose(scalars_, starts_[index], end));
        decomposed_ += keys_.back();
    }
}

Scalars Text::character(std::size_t index) const {
    const std::size_t end = index + 1 < starts_.size() ? starts_[index + 1] : scalars_.size();
    return scalars_.substr(starts_[index], end - starts_[index]);
}

Text Text::droppingFirst(std::size_t count) const {
    if (count >= starts_.size()) return Text();
    return Text(scalars_.substr(starts_[count]));
}

Text Text::droppingLast(std::size_t count) const {
    if (count >= starts_.size()) return Text();
    return Text(scalars_.substr(0, starts_[starts_.size() - count]));
}

bool Text::hasPrefix(const Text &prefix) const {
    if (prefix.count() > count()) return false;
    for (std::size_t index = 0; index < prefix.count(); ++index) {
        if (keys_[index] != prefix.keys_[index]) return false;
    }
    return true;
}

bool Text::hasSuffix(const Text &suffix) const {
    if (suffix.count() > count()) return false;
    const std::size_t offset = count() - suffix.count();
    for (std::size_t index = 0; index < suffix.count(); ++index) {
        if (keys_[offset + index] != suffix.keys_[index]) return false;
    }
    return true;
}

bool Text::contains(const Text &other) const {
    if (other.count() == 0 || other.count() > count()) return false;
    for (std::size_t start = 0; start + other.count() <= count(); ++start) {
        bool equal = true;
        for (std::size_t index = 0; index < other.count() && equal; ++index) {
            equal = keys_[start + index] == other.keys_[index];
        }
        if (equal) return true;
    }
    return false;
}

bool Text::containsCharacter(const Text &character) const {
    if (character.count() != 1) return false;
    for (const Scalars &key : keys_) {
        if (key == character.keys_[0]) return true;
    }
    return false;
}

bool Text::endsWithCharacter(const Text &character) const {
    return character.count() == 1 && !keys_.empty() && keys_.back() == character.keys_[0];
}

}  // namespace glyph_text

namespace {

int32_t writeOut(const glyph_text::Scalars &scalars, char *out, int32_t capacity) {
    const std::string utf8 = glyph_text::encode(scalars);
    const auto length = static_cast<int32_t>(utf8.size());
    if (length > capacity || (length > 0 && !out)) return length;
    if (length > 0) std::memcpy(out, utf8.data(), utf8.size());
    return length;
}

}  // namespace

extern "C" int32_t gc_normalize(gc_string text, char *out, int32_t capacity) {
    return writeOut(glyph_text::normalized(glyph_text::decode(text)), out, capacity);
}

extern "C" int32_t gc_compact_transmuter(gc_string text, char *out, int32_t capacity) {
    return writeOut(glyph_text::compactTransmuter(glyph_text::decode(text)), out, capacity);
}

extern "C" int32_t gl_text_character_count(gc_string text) {
    return static_cast<int32_t>(glyph_text::clusterStarts(glyph_text::decode(text)).size());
}
