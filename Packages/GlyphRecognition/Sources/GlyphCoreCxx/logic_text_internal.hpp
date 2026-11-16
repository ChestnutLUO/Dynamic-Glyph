#ifndef GLYPH_LOGIC_TEXT_INTERNAL_HPP
#define GLYPH_LOGIC_TEXT_INTERNAL_HPP

// Swift's String semantics for the pace area's C++ (logic_text.cpp): the
// text functions in glyph_common.h and the Character-level operations the
// matchers use. Not part of the ABI.
//
// Swift compares Strings and Characters under canonical equivalence and
// iterates them by Character, an extended grapheme cluster. `Text` keeps a
// string's scalars, its cluster boundaries as this toolchain's Swift draws
// them, and each cluster's canonical decomposition (NFD), which is what the
// comparisons use.

#include "glyph_logic_pace.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace glyph_text {

using Scalars = std::u32string;

/** UTF-8 to scalars; an invalid sequence becomes U+FFFD, as Swift decodes. */
Scalars decode(gc_string text);
Scalars decode(const std::string &text);
std::string encode(const Scalars &scalars);

/** `String.lowercased()`: each scalar's lowercase mapping, no context. */
Scalars lowercased(const Scalars &scalars);
/** `GameText.normalized(_:)`. */
Scalars normalized(const Scalars &scalars);
/** `GameText.compactTransmuter(_:)`. */
Scalars compactTransmuter(const Scalars &scalars);
/** `trimmingCharacters(in: .whitespaces)`: Foundation trims scalars. */
Scalars trimmingWhitespaces(const Scalars &scalars);

/** Cluster start offsets, ascending, starting with 0 (empty for no text). */
std::vector<std::size_t> clusterStarts(const Scalars &scalars);

/** The first scalar's `Character.isWhitespace`, as Swift decides it for a
 *  whole Character. */
bool isWhitespaceCharacter(char32_t first);
/** `Character.wholeNumberValue` when it is 1...8, else 0. */
int wholeNumberOneToEight(const Scalars &cluster);

/** A Swift String as Characters. */
class Text {
public:
    Text() = default;
    explicit Text(Scalars scalars);
    static Text of(const std::string &utf8) { return Text(decode(utf8)); }

    const Scalars &scalars() const { return scalars_; }
    std::size_t count() const { return keys_.size(); }
    bool empty() const { return scalars_.empty(); }
    /** Cluster `index`'s scalars, as stored. */
    Scalars character(std::size_t index) const;
    /** Cluster `index`'s canonical decomposition: what equality compares. */
    const Scalars &key(std::size_t index) const { return keys_[index]; }
    /** The text without its first or last `count` Characters (String's
     *  `dropFirst`, `dropLast`), as a new String. */
    Text droppingFirst(std::size_t count) const;
    Text droppingLast(std::size_t count) const;

    /** String `==`: canonical equivalence of the whole strings. */
    bool operator==(const Text &other) const { return decomposed_ == other.decomposed_; }
    bool operator!=(const Text &other) const { return !(*this == other); }
    /** `hasPrefix`, `hasSuffix`: Character by Character. */
    bool hasPrefix(const Text &prefix) const;
    bool hasSuffix(const Text &suffix) const;
    /** `contains(_ other:)` on Characters; false for an empty `other`, as
     *  Swift's is. */
    bool contains(const Text &other) const;
    /** Whether some Character equals `character` (one cluster's text). */
    bool containsCharacter(const Text &character) const;
    /** Whether the last Character equals `character`. */
    bool endsWithCharacter(const Text &character) const;

private:
    Scalars scalars_;
    std::vector<std::size_t> starts_;
    std::vector<Scalars> keys_;
    Scalars decomposed_;
};

/** `GameText` for one language, over its packs as Swift exports them
 *  (`GameText.tables`), without the headers. */
class GameTextMatcher {
public:
    struct Notice {
        Text key;
        gl_game_text_notice_kind notice;
    };
    struct Entry {
        Text key;
        Text item;
        std::string itemUTF8;
    };
    struct Pack {
        std::string code;
        std::vector<Notice> notices;
        Text droneFooter, hackingLabel, speedLabel, bonusTitle, bountyTitle;
        std::vector<Text> messageFragments, effectSuffixes, effectPrefixes;
        std::vector<Entry> items;
        std::vector<Entry> leadingWords;
    };

    GameTextMatcher(gc_language language, std::vector<Pack> packs, std::vector<Text> allBonusTitles);

    gc_language language() const { return language_; }
    /** The pack whose notice this is, or null; `notice` is set when found. */
    const Pack *notice(const Scalars &text, gl_game_text_notice_kind &notice) const;
    bool isDroneFooter(const Scalars &text) const;
    bool isHackingLabel(const Scalars &text) const;
    const Pack *hackingLabelPack(const Scalars &text) const;
    const Pack *bonusTitlePack(const Scalars &text) const;
    bool isSpeedLabel(const Scalars &text) const;
    gl_game_text_title_kind title(const Scalars &text) const;
    /** The effect's name, a static string, or null. */
    const char *effect(const Scalars &text) const;
    /** The item, owned by this matcher, or null. */
    const std::string *item(const Scalars &name, bool clipped) const;

private:
    gc_language language_;
    std::vector<Pack> packs_;
    std::vector<Text> otherBonusTitles_;
};

/** `GameLanguage(rawValue:)`; false for a code no language has. */
bool languageForCode(const std::string &code, gc_language &language);

}  // namespace glyph_text

/** The `gl_game_text` handle: shared by logic_language.cpp, which makes it,
 *  and logic_command.cpp, whose parser copies its matcher. */
struct gl_game_text {
    glyph_text::GameTextMatcher matcher;
    explicit gl_game_text(glyph_text::GameTextMatcher matcher) : matcher(std::move(matcher)) {}
};

#endif  // GLYPH_LOGIC_TEXT_INTERNAL_HPP
