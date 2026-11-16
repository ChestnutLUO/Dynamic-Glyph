// `HeaderPhraseMatcher` from GamePhaseEvidence.swift: header lines to a game
// phase. The words of a line come from `gc_normalize` (glyph_common.h), the
// same letters-and-digits rule as `GameText.normalized`, applied per Unicode
// scalar so that whatever it drops becomes a word break, as
// `HeaderPhraseMatcher.normalize` makes it one.

#include "glyph_logic_tracker.h"

#include <cstdint>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace {

struct Phrase {
    gl_game_phase phase;
    std::vector<std::string> words;
    /// `words.joined()`, for `matchesWithin`.
    std::string joined;
    bool requiresExactMatch;
    bool matchesWithin;
};

struct Hit {
    gl_game_phase phase;
    double confidence;
    std::string matchedText;
};

/// Decodes one scalar at `bytes[*position]`, advancing past it. Malformed
/// UTF-8 decodes as U+FFFD, one byte at a time.
uint32_t decodeScalar(const unsigned char *bytes, size_t length, size_t *position) {
    const size_t start = *position;
    const unsigned char lead = bytes[start];
    size_t extra;
    uint32_t scalar;
    if (lead < 0x80) {
        *position = start + 1;
        return lead;
    } else if (lead >= 0xC2 && lead <= 0xDF) {
        extra = 1;
        scalar = lead & 0x1F;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
        extra = 2;
        scalar = lead & 0x0F;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
        extra = 3;
        scalar = lead & 0x07;
    } else {
        *position = start + 1;
        return 0xFFFD;
    }
    if (start + extra >= length) {
        *position = start + 1;
        return 0xFFFD;
    }
    for (size_t index = 1; index <= extra; ++index) {
        const unsigned char next = bytes[start + index];
        if ((next & 0xC0) != 0x80) {
            *position = start + 1;
            return 0xFFFD;
        }
        scalar = (scalar << 6) | (next & 0x3F);
    }
    const uint32_t minimum = extra == 1 ? 0x80 : extra == 2 ? 0x800 : 0x10000;
    if (scalar < minimum || scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF)) {
        *position = start + 1;
        return 0xFFFD;
    }
    *position = start + extra + 1;
    return scalar;
}

/// Scalars that extend the character before them rather than starting one
/// (the common Grapheme_Extend blocks, the joiner and variation selectors).
/// Swift keeps or drops such a scalar with the character it belongs to.
bool extendsCharacter(uint32_t scalar) {
    return (scalar >= 0x0300 && scalar <= 0x036F) || (scalar >= 0x1AB0 && scalar <= 0x1AFF)
        || (scalar >= 0x1DC0 && scalar <= 0x1DFF) || (scalar >= 0x20D0 && scalar <= 0x20FF)
        || (scalar >= 0xFE20 && scalar <= 0xFE2F) || (scalar >= 0xFE00 && scalar <= 0xFE0F)
        || scalar == 0x200D || scalar == 0x3099 || scalar == 0x309A
        || (scalar >= 0xE0100 && scalar <= 0xE01EF);
}

}  // namespace

struct gl_header_matcher {
    std::vector<Phrase> phrases;
    double minimumConfidence = 0.35;

    // Per-call buffers, reused.
    std::vector<std::string> words;
    size_t wordCount = 0;
    std::string joinedWords;
    std::vector<Hit> hits;
    size_t hitCount = 0;
    std::string result;

    /// `HeaderPhraseMatcher.normalize(_:)` into `words[0..<wordCount]`.
    void normalize(gc_string text) {
        wordCount = 0;
        if (!text.bytes || text.length <= 0) return;
        const auto *bytes = reinterpret_cast<const unsigned char *>(text.bytes);
        const size_t length = static_cast<size_t>(text.length);
        std::string *current = nullptr;
        bool previousKept = false;
        char lowered[64];
        size_t position = 0;
        while (position < length) {
            const size_t start = position;
            const uint32_t scalar = decodeScalar(bytes, length, &position);
            if (extendsCharacter(scalar)) {
                if (previousKept && current) current->append(text.bytes + start, position - start);
                continue;
            }
            const int32_t written = gc_normalize(
                gc_string{text.bytes + start, static_cast<int32_t>(position - start)}, lowered,
                static_cast<int32_t>(sizeof lowered));
            if (written > 0 && written <= static_cast<int32_t>(sizeof lowered)) {
                if (!current) {
                    if (wordCount == words.size()) words.emplace_back();
                    current = &words[wordCount++];
                    current->clear();
                }
                current->append(lowered, static_cast<size_t>(written));
                previousKept = true;
            } else {
                current = nullptr;
                previousKept = false;
            }
        }
    }

    bool matches(const Phrase &phrase) const {
        if (phrase.requiresExactMatch) {
            if (phrase.words.size() != wordCount) return false;
            for (size_t index = 0; index < wordCount; ++index) {
                if (words[index] != phrase.words[index]) return false;
            }
            return true;
        }
        if (phrase.matchesWithin) return joinedWords.find(phrase.joined) != std::string::npos;
        const size_t needed = phrase.words.size();
        if (needed > wordCount) return false;
        for (size_t start = 0; start + needed <= wordCount; ++start) {
            bool all = true;
            for (size_t offset = 0; offset < needed; ++offset) {
                if (words[start + offset] != phrase.words[offset]) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
        }
        return false;
    }

    gl_header_reading read(const gl_header_line *lines, int32_t count) {
        hitCount = 0;
        for (int32_t line = 0; lines && line < count; ++line) {
            if (!(lines[line].confidence >= minimumConfidence)) continue;
            normalize(lines[line].text);
            if (wordCount == 0) continue;
            joinedWords.clear();
            for (size_t index = 0; index < wordCount; ++index) joinedWords.append(words[index]);
            for (const Phrase &phrase : phrases) {
                if (!matches(phrase)) continue;
                if (hitCount == hits.size()) hits.emplace_back();
                Hit &hit = hits[hitCount++];
                hit.phase = phrase.phase;
                hit.confidence = lines[line].confidence;
                hit.matchedText.clear();
                for (size_t index = 0; index < wordCount; ++index) {
                    if (index > 0) hit.matchedText.push_back(' ');
                    hit.matchedText.append(words[index]);
                }
            }
        }
        bool onePhase = hitCount > 0;
        for (size_t index = 1; index < hitCount; ++index) {
            if (hits[index].phase != hits[0].phase) {
                onePhase = false;
                break;
            }
        }
        gl_header_reading reading{};
        reading.sourceTime = 0;
        if (!onePhase) {
            result.assign(hitCount == 0 ? "" : "conflicting phrases");
            reading.phase = GL_GAME_PHASE_UNKNOWN;
            reading.confidence = 0;
        } else {
            // `max(by:)` keeps the first of equal maxima.
            size_t best = 0;
            for (size_t index = 1; index < hitCount; ++index) {
                if (hits[best].confidence < hits[index].confidence) best = index;
            }
            result.assign(hits[best].matchedText);
            reading.phase = hits[best].phase;
            reading.confidence = hits[best].confidence;
        }
        reading.matchedText = gc_string{result.data(), static_cast<int32_t>(result.size())};
        return reading;
    }
};

extern "C" {

gl_header_matcher *gl_header_matcher_create(const gl_header_phrase *phrases, int32_t count,
                                            double minimumConfidence) {
    if (count < 0 || (count > 0 && !phrases)) return nullptr;
    gl_header_matcher *matcher = new (std::nothrow) gl_header_matcher();
    if (!matcher) return nullptr;
    matcher->minimumConfidence = minimumConfidence;
    matcher->phrases.reserve(static_cast<size_t>(count));
    for (int32_t index = 0; index < count; ++index) {
        const gl_header_phrase &source = phrases[index];
        Phrase phrase;
        phrase.phase = source.phase;
        phrase.requiresExactMatch = source.requiresExactMatch;
        phrase.matchesWithin = source.matchesWithin;
        for (int32_t word = 0; source.words && word < source.wordCount; ++word) {
            const gc_string text = source.words[word];
            phrase.words.emplace_back(text.bytes && text.length > 0
                                          ? std::string(text.bytes, static_cast<size_t>(text.length))
                                          : std::string());
            phrase.joined.append(phrase.words.back());
        }
        matcher->phrases.push_back(std::move(phrase));
    }
    return matcher;
}

void gl_header_matcher_destroy(gl_header_matcher *matcher) { delete matcher; }

gl_header_reading gl_header_matcher_read(gl_header_matcher *matcher, const gl_header_line *lines, int32_t count) {
    if (!matcher) {
        gl_header_reading reading{};
        reading.phase = GL_GAME_PHASE_UNKNOWN;
        reading.matchedText = gc_string{"", 0};
        return reading;
    }
    return matcher->read(lines, count);
}

}  // extern "C"
