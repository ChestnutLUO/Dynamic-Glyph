// The game language memory (GameLanguageMemory.swift) and the game text
// matchers (GameText.swift: notice, isDroneFooter, the labels, title,
// effect and item), over the phrase packs Swift passes in at creation.

#include "glyph_logic_pace.h"
#include "logic_text_internal.hpp"

#include <array>
#include <cmath>
#include <limits>
#include <new>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace glyph_text {
namespace {

constexpr std::array<const char *, 5> kLanguageCodes = {"en", "zh-Hans", "zh-Hant", "ja", "ko"};

/** The literals the matchers compare against, as Swift Strings. */
struct Literals {
    Text ellipsis = Text::of("\xE2\x80\xA6");  // …
    Text threeDots = Text::of("...");
    Text dot = Text::of(".");
    Text ideographicStop = Text::of("\xE3\x80\x82");  // 。
    Text itoenPlus = Text::of("itoen(+)");
    Text itoenTransmuterPlus = Text::of("itoentransmuter(+)");
    Text itoenMinus = Text::of("itoen(-)");
    Text itoenTransmuterMinus = Text::of("itoentransmuter(-)");
};

const Literals &literals() {
    static const Literals value;
    return value;
}

}  // namespace

bool languageForCode(const std::string &code, gc_language &language) {
    for (std::size_t index = 0; index < kLanguageCodes.size(); ++index) {
        if (code == kLanguageCodes[index]) { language = static_cast<gc_language>(index); return true; }
    }
    return false;
}

GameTextMatcher::GameTextMatcher(gc_language language, std::vector<Pack> packs, std::vector<Text> allBonusTitles)
    : language_(language), packs_(std::move(packs)), otherBonusTitles_(std::move(allBonusTitles)) {}

const GameTextMatcher::Pack *GameTextMatcher::notice(const Scalars &text, gl_game_text_notice_kind &notice) const {
    const Text key(normalized(text));
    for (const Pack &pack : packs_) {
        for (const Notice &entry : pack.notices) {
            if (entry.key == key) { notice = entry.notice; return &pack; }
        }
    }
    return nullptr;
}

bool GameTextMatcher::isDroneFooter(const Scalars &text) const {
    const Text key(normalized(text));
    for (const Pack &pack : packs_) {
        if (pack.droneFooter == key) return true;
    }
    return false;
}

bool GameTextMatcher::isHackingLabel(const Scalars &text) const { return hackingLabelPack(text) != nullptr; }

const GameTextMatcher::Pack *GameTextMatcher::hackingLabelPack(const Scalars &text) const {
    const Text key(normalized(text));
    for (const Pack &pack : packs_) {
        if (pack.hackingLabel == key) return &pack;
    }
    return nullptr;
}

const GameTextMatcher::Pack *GameTextMatcher::bonusTitlePack(const Scalars &text) const {
    const Text key(normalized(text));
    for (const Pack &pack : packs_) {
        if (pack.bonusTitle == key) return &pack;
    }
    return nullptr;
}

bool GameTextMatcher::isSpeedLabel(const Scalars &text) const {
    const Text key(normalized(text));
    for (const Pack &pack : packs_) {
        if (pack.speedLabel == key) return true;
    }
    return false;
}

gl_game_text_title_kind GameTextMatcher::title(const Scalars &text) const {
    const Text key(normalized(text));
    for (const Pack &pack : packs_) {
        if (pack.bonusTitle == key) return GL_GAME_TEXT_TITLE_BONUS;
    }
    for (const Pack &pack : packs_) {
        if (pack.bountyTitle == key) return GL_GAME_TEXT_TITLE_BOUNTY;
    }
    for (const Text &title : otherBonusTitles_) {
        if (title == key) return GL_GAME_TEXT_TITLE_UNSUPPORTED;
    }
    for (const Pack &pack : packs_) {
        for (const Text &fragment : pack.messageFragments) {
            if (key.contains(fragment)) return GL_GAME_TEXT_TITLE_MESSAGE;
        }
    }
    return GL_GAME_TEXT_TITLE_OTHER;
}

const char *GameTextMatcher::effect(const Scalars &text) const {
    Text value(compactTransmuter(text));
    const Literals &literal = literals();
    while (value.endsWithCharacter(literal.dot) || value.endsWithCharacter(literal.ideographicStop)) {
        value = value.droppingLast(1);
    }
    bool stripped = false;
    for (const Pack &pack : packs_) {
        for (const Text &suffix : pack.effectSuffixes) {
            if (!value.hasSuffix(suffix)) continue;
            value = value.droppingLast(suffix.count());
            stripped = true;
            break;
        }
        if (stripped) break;
    }
    if (!stripped) {
        for (const Pack &pack : packs_) {
            for (const Text &prefix : pack.effectPrefixes) {
                if (!value.hasPrefix(prefix)) continue;
                value = value.droppingFirst(prefix.count());
                stripped = true;
                break;
            }
            if (stripped) break;
        }
    }
    if (!stripped) return nullptr;
    if (value == literal.itoenPlus || value == literal.itoenTransmuterPlus) return "ITO EN (+)";
    if (value == literal.itoenMinus || value == literal.itoenTransmuterMinus) return "ITO EN (-)";
    return nullptr;
}

const std::string *GameTextMatcher::item(const Scalars &name, bool clipped) const {
    static const std::string plus = "ITO EN Transmuter (+)", minus = "ITO EN Transmuter (-)";
    const Literals &literal = literals();
    {
        const Text compact(compactTransmuter(name));
        if (compact == literal.itoenTransmuterPlus || compact == literal.itoenPlus) return &plus;
        if (compact == literal.itoenTransmuterMinus || compact == literal.itoenMinus) return &minus;
    }
    Text shown(trimmingWhitespaces(name));
    const bool ellipsis = shown.hasSuffix(literal.ellipsis) || shown.hasSuffix(literal.threeDots);
    if (shown.hasSuffix(literal.ellipsis)) shown = shown.droppingLast(1);
    else if (shown.hasSuffix(literal.threeDots)) shown = shown.droppingLast(3);
    if (shown.containsCharacter(literal.ellipsis) || shown.containsCharacter(literal.dot)) return nullptr;
    const Text key(normalized(shown.scalars()));
    if (key.empty()) return nullptr;
    if (!ellipsis) {
        for (const Pack &pack : packs_) {
            for (const Entry &entry : pack.items) {
                if (entry.key == key) return &entry.itemUTF8;
            }
        }
    }
    if (!ellipsis && !clipped && language_ != GC_LANGUAGE_ENGLISH) {
        // The union of every pack's set for this key, compared as Strings.
        std::vector<const Entry *> items;
        for (const Pack &pack : packs_) {
            for (const Entry &entry : pack.leadingWords) {
                if (!(entry.key == key)) continue;
                bool seen = false;
                for (const Entry *other : items) seen = seen || other->item == entry.item;
                if (!seen) items.push_back(&entry);
            }
        }
        if (items.size() == 1) return &items.front()->itemUTF8;
    }
    if (!(ellipsis || clipped)) return nullptr;
    std::vector<const Entry *> candidates;
    for (const Pack &pack : packs_) {
        for (const Entry &entry : pack.items) {
            if (!(entry.key.hasPrefix(key) && entry.key.count() > key.count())) continue;
            bool seen = false;
            for (const Entry *other : candidates) seen = seen || other->item == entry.item;
            if (!seen) candidates.push_back(&entry);
        }
    }
    if (candidates.size() != 1) return nullptr;
    const Entry *item = candidates.front();
    const Text *full = nullptr;
    for (const Pack &pack : packs_) {
        for (const Entry &entry : pack.items) {
            if (entry.item == item->item && entry.key.hasPrefix(key)) { full = &entry.key; break; }
        }
        if (full) break;
    }
    if (!full || key.count() < 3 || !(static_cast<double>(key.count()) >= static_cast<double>(full->count()) * 0.5)) {
        return nullptr;
    }
    return &item->itemUTF8;
}

}  // namespace glyph_text

namespace {

using glyph_text::GameTextMatcher;
using glyph_text::Text;

std::string copy(gc_string text) {
    if (!text.bytes || text.length <= 0) return std::string();
    return std::string(text.bytes, static_cast<std::size_t>(text.length));
}

Text textOf(gc_string text) { return Text(glyph_text::decode(text)); }

std::vector<Text> textsOf(const gc_string *strings, int32_t count) {
    std::vector<Text> texts;
    for (int32_t index = 0; strings && index < count; ++index) texts.push_back(textOf(strings[index]));
    return texts;
}

std::vector<GameTextMatcher::Entry> entriesOf(const gl_game_text_item_entry *entries, int32_t count) {
    std::vector<GameTextMatcher::Entry> result;
    for (int32_t index = 0; entries && index < count; ++index) {
        result.push_back(GameTextMatcher::Entry{textOf(entries[index].shown), textOf(entries[index].item),
                                                copy(entries[index].item)});
    }
    return result;
}

gc_string view(const std::string &text) { return gc_string{text.data(), static_cast<int32_t>(text.size())}; }

}  // namespace

extern "C" {

gl_game_text *gl_game_text_create(gc_language language, const gl_game_text_pack *packs, int32_t packCount,
                                  const gc_string *allBonusTitles, int32_t allBonusTitleCount) {
    if ((packCount > 0 && !packs) || packCount < 0) return nullptr;
    try {
        std::vector<GameTextMatcher::Pack> converted;
        for (int32_t index = 0; index < packCount; ++index) {
            const gl_game_text_pack &source = packs[index];
            GameTextMatcher::Pack pack;
            pack.code = copy(source.code);
            for (int32_t notice = 0; source.notices && notice < source.noticeCount; ++notice) {
                pack.notices.push_back(GameTextMatcher::Notice{textOf(source.notices[notice].text),
                                                               source.notices[notice].notice});
            }
            pack.droneFooter = textOf(source.droneFooter);
            pack.hackingLabel = textOf(source.hackingLabel);
            pack.speedLabel = textOf(source.speedLabel);
            pack.bonusTitle = textOf(source.bonusTitle);
            pack.bountyTitle = textOf(source.bountyTitle);
            pack.messageFragments = textsOf(source.messageFragments, source.messageFragmentCount);
            pack.effectSuffixes = textsOf(source.effectSuffixes, source.effectSuffixCount);
            pack.effectPrefixes = textsOf(source.effectPrefixes, source.effectPrefixCount);
            pack.items = entriesOf(source.items, source.itemCount);
            pack.leadingWords = entriesOf(source.leadingWords, source.leadingWordCount);
            converted.push_back(std::move(pack));
        }
        return new gl_game_text(GameTextMatcher(language, std::move(converted),
                                                textsOf(allBonusTitles, allBonusTitleCount)));
    } catch (...) {
        return nullptr;
    }
}

void gl_game_text_destroy(gl_game_text *text) { delete text; }

gc_language gl_game_text_language(const gl_game_text *text) {
    return text ? text->matcher.language() : GC_LANGUAGE_ENGLISH;
}

bool gl_game_text_notice(const gl_game_text *text, gc_string line, gl_game_text_notice_match *out) {
    if (!text) return false;
    gl_game_text_notice_kind notice = GL_GAME_TEXT_NOTICE_NONE;
    const GameTextMatcher::Pack *pack = text->matcher.notice(glyph_text::decode(line), notice);
    if (!pack) return false;
    if (out) *out = gl_game_text_notice_match{notice, view(pack->code)};
    return true;
}

bool gl_game_text_is_drone_footer(const gl_game_text *text, gc_string line) {
    return text && text->matcher.isDroneFooter(glyph_text::decode(line));
}

bool gl_game_text_is_hacking_label(const gl_game_text *text, gc_string line) {
    return text && text->matcher.isHackingLabel(glyph_text::decode(line));
}

bool gl_game_text_hacking_label_language(const gl_game_text *text, gc_string line, gc_language *out) {
    if (!text) return false;
    const GameTextMatcher::Pack *pack = text->matcher.hackingLabelPack(glyph_text::decode(line));
    gc_language language = GC_LANGUAGE_ENGLISH;
    if (!pack || !glyph_text::languageForCode(pack->code, language)) return false;
    if (out) *out = language;
    return true;
}

bool gl_game_text_bonus_title_language(const gl_game_text *text, gc_string line, gc_language *out) {
    if (!text) return false;
    const GameTextMatcher::Pack *pack = text->matcher.bonusTitlePack(glyph_text::decode(line));
    gc_language language = GC_LANGUAGE_ENGLISH;
    if (!pack || !glyph_text::languageForCode(pack->code, language)) return false;
    if (out) *out = language;
    return true;
}

bool gl_game_text_is_speed_label(const gl_game_text *text, gc_string line) {
    return text && text->matcher.isSpeedLabel(glyph_text::decode(line));
}

gl_game_text_title_kind gl_game_text_title(const gl_game_text *text, gc_string line) {
    return text ? text->matcher.title(glyph_text::decode(line)) : GL_GAME_TEXT_TITLE_OTHER;
}

bool gl_game_text_effect(const gl_game_text *text, gc_string line, gc_string *out) {
    if (!text) return false;
    const char *effect = text->matcher.effect(glyph_text::decode(line));
    if (!effect) return false;
    if (out) *out = gc_string{effect, static_cast<int32_t>(std::char_traits<char>::length(effect))};
    return true;
}

bool gl_game_text_item(const gl_game_text *text, gc_string name, bool clipped, gc_string *out) {
    if (!text) return false;
    const std::string *item = text->matcher.item(glyph_text::decode(name), clipped);
    if (!item) return false;
    if (out) *out = view(*item);
    return true;
}

}  // extern "C"

/* Game language memory ---------------------------------------------------- */

struct gl_language_memory {
    gc_language language;
    bool isAutomatic;
    double retryInterval;
    bool confirmed = false;
    std::array<bool, 3> hasLastAttempt{};
    std::array<double, 3> lastAttempt{};
    bool hasPanelReading = false;
    gc_language panelLanguage = GC_LANGUAGE_ENGLISH;
    double panelTop = 0, panelBottom = 0, panelTime = 0;

    gl_language_memory(gc_language language, bool isAutomatic, double retryInterval)
        : language(language), isAutomatic(isAutomatic), retryInterval(retryInterval) {}
};

extern "C" {

gl_language_memory *gl_language_memory_create(gc_language language, bool isAutomatic, double retryInterval) {
    return new (std::nothrow) gl_language_memory(language, isAutomatic, retryInterval);
}

void gl_language_memory_destroy(gl_language_memory *memory) { delete memory; }

gc_language gl_language_memory_current(const gl_language_memory *memory) {
    return memory ? memory->language : GC_LANGUAGE_ENGLISH;
}

bool gl_language_memory_is_confirmed(const gl_language_memory *memory) { return memory && memory->confirmed; }

bool gl_language_memory_is_automatic(const gl_language_memory *memory) { return memory && memory->isAutomatic; }

double gl_language_memory_retry_interval(const gl_language_memory *memory) {
    return memory ? memory->retryInterval : 0;
}

int32_t gl_language_memory_alternatives(gl_language_memory *memory, double time, gl_language_memory_screen screen,
                                        gc_language out[5]) {
    const int index = static_cast<int>(screen);
    if (!memory || index < 0 || index > 2) return 0;
    const double last = memory->hasLastAttempt[index] ? memory->lastAttempt[index]
                                                      : -std::numeric_limits<double>::infinity();
    const double interval = screen == GL_LANGUAGE_MEMORY_SCREEN_NOTICE ? memory->retryInterval / 2
                                                                       : memory->retryInterval;
    if (!(memory->isAutomatic && std::isfinite(time) && (time < last || time - last >= interval))) return 0;
    memory->hasLastAttempt[index] = true;
    memory->lastAttempt[index] = time;
    int32_t count = 0;
    for (int language = 0; language < 5; ++language) {
        if (language == static_cast<int>(memory->language)) continue;
        if (out) out[count] = static_cast<gc_language>(language);
        ++count;
    }
    return count;
}

bool gl_language_memory_found(gl_language_memory *memory, gc_language found) {
    if (!memory) return false;
    const bool changed = memory->isAutomatic && found != memory->language;
    if (changed) { memory->language = found; memory->hasPanelReading = false; }
    if (memory->isAutomatic) memory->confirmed = true;
    return changed;
}

bool gl_language_memory_panel_reading_language(gl_language_memory *memory, double time, double boundsTop,
                                               double boundsBottom, gc_language *out) {
    if (!memory) return false;
    if (!(memory->isAutomatic && memory->hasPanelReading && std::isfinite(time) && time >= memory->panelTime
          && time - memory->panelTime <= 5 && std::fabs(memory->panelTop - boundsTop) <= 0.003
          && std::fabs(memory->panelBottom - boundsBottom) <= 0.003)) {
        memory->hasPanelReading = false;
        return false;
    }
    if (out) *out = memory->panelLanguage;
    return true;
}

void gl_language_memory_remember_panel_reading(gl_language_memory *memory, gc_language language, double time,
                                               double boundsTop, double boundsBottom) {
    if (!memory || !memory->isAutomatic || !std::isfinite(time)) return;
    memory->hasPanelReading = true;
    memory->panelLanguage = language;
    memory->panelTime = time;
    memory->panelTop = boundsTop;
    memory->panelBottom = boundsBottom;
}

gc_language gl_language_memory_starting_guess(bool hasRemembered, gc_language remembered,
                                              const gc_string *preferredLanguages, int32_t count) {
    if (hasRemembered) return remembered;
    for (int32_t index = 0; preferredLanguages && index < count; ++index) {
        const Text code(glyph_text::lowercased(glyph_text::decode(preferredLanguages[index])));
        const auto starts = [&](const char *prefix) { return code.hasPrefix(Text::of(prefix)); };
        if (starts("zh-hant") || starts("zh-tw") || starts("zh-hk")) return GC_LANGUAGE_TRADITIONAL_CHINESE;
        if (starts("zh")) return GC_LANGUAGE_SIMPLIFIED_CHINESE;
        if (starts("ja")) return GC_LANGUAGE_JAPANESE;
        if (starts("ko")) return GC_LANGUAGE_KOREAN;
        if (starts("en")) return GC_LANGUAGE_ENGLISH;
    }
    return GC_LANGUAGE_ENGLISH;
}

}  // extern "C"
