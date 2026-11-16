// Portal level: PortalLevelRules and PortalLevelObserver (PortalLevel.swift)
// and PortalScreenParser (PortalScreenDetector.swift), rule for rule.

#include "glyph_logic_pace.h"
#include "logic_text_internal.hpp"

#include <algorithm>
#include <cmath>
#include <new>
#include <optional>
#include <vector>

namespace {

struct Levels {
    int32_t lowest;
    int32_t highest;
    int32_t count() const { return highest - lowest + 1; }
    bool contains(int32_t level) const { return level >= lowest && level <= highest; }
};

std::optional<Levels> levelsForGlyphCount(int32_t count) {
    switch (count) {
    case 1: return Levels{1, 1};
    case 2: return Levels{2, 2};
    case 3: return Levels{3, 5};
    case 4: return Levels{6, 7};
    case 5: return Levels{8, 8};
    default: return std::nullopt;
    }
}

struct CalibratedHue {
    int32_t level;
    double hue;
};
constexpr CalibratedHue kCalibratedHues[] = {{5, 343.5}, {6, 329}, {8, 259}};
constexpr double kCalibrationTolerance = 7.0;
/// The uncalibrated range a hue warmer than L5 allows.
constexpr Levels kWarmBadgeLevels{1, 4};

std::optional<Levels> levelsForBadgeHue(double hue) {
    if (!std::isfinite(hue)) return std::nullopt;
    const auto distance = [](double a, double b) {
        const double d = std::fmod(std::fabs(a - b), 360.0);
        return std::min(d, 360 - d);
    };
    for (const CalibratedHue &calibrated : kCalibratedHues) {
        if (distance(calibrated.hue, hue) <= kCalibrationTolerance) return Levels{calibrated.level, calibrated.level};
    }
    if (hue > kCalibratedHues[2].hue + kCalibrationTolerance && hue < kCalibratedHues[1].hue - kCalibrationTolerance) {
        return Levels{7, 7};
    }
    if (hue > kCalibratedHues[0].hue + kCalibrationTolerance || hue < 60) return kWarmBadgeLevels;
    return std::nullopt;
}

/// `PortalLevelRules.contradicts(_:_:)`.
bool contradicts(const Levels &range, const std::vector<Levels> &others) {
    if (others.empty()) return false;
    int32_t lowest = others.front().lowest, highest = others.front().highest;
    for (const Levels &other : others) {
        lowest = std::max(lowest, other.lowest);
        highest = std::min(highest, other.highest);
    }
    if (!(lowest <= highest)) return false;
    return range.highest < lowest || range.lowest > highest;
}

/// `trapped` is set where Swift's `lowest...highest` would trap.
std::optional<Levels> levelsForResonators(const int32_t *read, int32_t count, int32_t unread, bool &trapped) {
    trapped = false;
    int64_t known = 0, sum = 0;
    for (int32_t index = 0; read && index < count; ++index) {
        if (read[index] >= 1 && read[index] <= 8) { known += 1; sum += read[index]; }
    }
    const int64_t missing = std::max<int64_t>(0, 8 - known);
    if (known == 0 && !(unread > 0)) return std::nullopt;
    const int64_t lowest = std::max<int64_t>(1, sum / 8), highest = std::max<int64_t>(1, (sum + missing * 8) / 8);
    const int64_t upper = std::min<int64_t>(8, highest);
    if (lowest > upper) { trapped = true; return std::nullopt; }
    return Levels{static_cast<int32_t>(lowest), static_cast<int32_t>(upper)};
}

gl_portal_levels levelsView(const std::optional<Levels> &levels) {
    if (!levels) return gl_portal_levels{false, 0, 0};
    return gl_portal_levels{true, levels->lowest, levels->highest};
}

}  // namespace

extern "C" {

gl_portal_levels gl_portal_rules_levels_for_glyph_count(int32_t count) {
    return levelsView(levelsForGlyphCount(count));
}

gl_portal_levels gl_portal_rules_levels_for_badge_hue(double hue) { return levelsView(levelsForBadgeHue(hue)); }

bool gl_portal_rules_levels_for_resonators(const int32_t *read, int32_t count, int32_t unread,
                                           gl_portal_levels *out) {
    bool trapped = false;
    const std::optional<Levels> levels = levelsForResonators(read, count, unread, trapped);
    if (trapped) return false;
    if (out) *out = levelsView(levels);
    return true;
}

bool gl_portal_rules_estimate(const gl_portal_rules_input *input, gl_portal_estimate *out) {
    return gl_portal_rules_estimate_settled(input, true, out);
}

bool gl_portal_rules_estimate_settled(const gl_portal_rules_input *input, bool glyphCountSettled,
                                      gl_portal_estimate *out) {
    if (!input) return false;
    std::optional<Levels> ring;
    if (input->hasResonators) {
        bool trapped = false;
        ring = levelsForResonators(input->resonators, input->resonatorCount,
                                   input->unreadSlots.has ? input->unreadSlots.value : 0, trapped);
        if (trapped) return false;
    }
    const bool ringExact = ring && ring->count() == 1;
    const std::optional<Levels> readBadge = input->badgeHue.has ? levelsForBadgeHue(input->badgeHue.value)
                                                                : std::nullopt;
    const bool warm = readBadge && readBadge->lowest == kWarmBadgeLevels.lowest
        && readBadge->highest == kWarmBadgeLevels.highest;
    const std::optional<Levels> badge = !glyphCountSettled && warm ? std::nullopt : readBadge;
    const std::optional<Levels> count = input->glyphCount.has ? levelsForGlyphCount(input->glyphCount.value)
                                                              : std::nullopt;
    std::vector<Levels> others;
    if (ring) others.push_back(*ring);
    if (badge) others.push_back(*badge);
    const std::optional<Levels> glyphs = glyphCountSettled || (count && contradicts(*count, others))
        ? count : std::nullopt;
    // Strongest first: an exact ring, then the badge, then the count.
    std::vector<Levels> sources;
    for (const auto &source : {ring, badge, glyphs}) {
        if (source) sources.push_back(*source);
    }
    if (sources.empty()) return false;
    int32_t lowest = sources.front().lowest, highest = sources.front().highest;
    for (const Levels &source : sources) {
        lowest = std::max(lowest, source.lowest);
        highest = std::min(highest, source.highest);
    }
    const bool conflict = lowest > highest;
    const Levels range = conflict ? sources.front() : Levels{lowest, highest};
    const std::optional<int32_t> level = range.count() == 1 ? std::optional<int32_t>(range.lowest) : std::nullopt;
    int agreeing = 0;
    for (const Levels &source : sources) agreeing += source.contains(range.lowest) && source.contains(range.highest);
    gl_portal_confidence confidence;
    if (conflict || !level) confidence = GL_PORTAL_CONFIDENCE_LOW;
    else if (ringExact && agreeing >= 2) confidence = GL_PORTAL_CONFIDENCE_HIGH;
    else if (ringExact || (badge && badge->count() == 1 && agreeing >= 2)) confidence = GL_PORTAL_CONFIDENCE_MEDIUM;
    else confidence = GL_PORTAL_CONFIDENCE_LOW;
    if (!out) return true;
    *out = gl_portal_estimate{};
    out->level = gc_opt_int32{level.has_value(), level.value_or(0)};
    out->lowest = range.lowest;
    out->highest = range.highest;
    out->confidence = confidence;
    out->conflict = conflict;
    out->hasResonators = input->hasResonators;
    out->resonators = input->hasResonators ? input->resonators : nullptr;
    out->resonatorCount = input->hasResonators ? input->resonatorCount : 0;
    out->unreadSlots = input->unreadSlots;
    out->hasBadgeLevels = readBadge.has_value();
    if (readBadge) {
        for (int32_t value = readBadge->lowest; value <= readBadge->highest && out->badgeLevelCount < 8; ++value) {
            out->badgeLevels[out->badgeLevelCount++] = value;
        }
    }
    out->glyphCount = input->glyphCount;
    out->faction = input->faction;
    return true;
}

}  // extern "C"

/* Observer ---------------------------------------------------------------- */

struct gl_portal_observer {
    struct Evidence {
        double sourceTime;
        std::vector<int32_t> resonators;
        int32_t unreadSlots;
        std::optional<double> badgeHue;
        gl_portal_faction faction;

        static Evidence of(const gl_portal_evidence &evidence) {
            Evidence copy;
            copy.sourceTime = evidence.sourceTime;
            if (evidence.resonators && evidence.resonatorCount > 0) {
                copy.resonators.assign(evidence.resonators, evidence.resonators + evidence.resonatorCount);
            }
            copy.unreadSlots = evidence.unreadSlots;
            if (evidence.badgeHue.has) copy.badgeHue = evidence.badgeHue.value;
            copy.faction = evidence.faction;
            return copy;
        }
    };

    gl_portal_observer_policy policy;
    std::optional<Evidence> best;
    std::optional<double> badge;
    std::optional<double> lastReadAt;
    std::optional<double> claimedThrough;
    Evidence claimed{};

    explicit gl_portal_observer(const gl_portal_observer_policy &policy) : policy(policy) {}

    void accept(const gl_portal_evidence &input) {
        const double time = input.sourceTime;
        if (!std::isfinite(time) || (claimedThrough && !(time > *claimedThrough))
            || (lastReadAt && !(time >= *lastReadAt))) {
            return;
        }
        lastReadAt = time;
        Evidence evidence = Evidence::of(input);
        const bool sameScreen = best
            && time - best->sourceTime <= policy.sameScreen
            && !(best->faction != GL_PORTAL_FACTION_NONE && evidence.faction != GL_PORTAL_FACTION_NONE
                 && best->faction != evidence.faction);
        if (!sameScreen) {
            badge = evidence.badgeHue;
            best = std::move(evidence);
            return;
        }
        if (evidence.badgeHue) badge = evidence.badgeHue;
        if (best && best->resonators.size() > evidence.resonators.size()) return;
        best = std::move(evidence);
    }

    bool claim(double time, gl_portal_evidence *out) {
        if (!std::isfinite(time)) return false;
        const double through = claimedThrough ? *claimedThrough : time;
        claimedThrough = time >= through ? time : through;
        std::optional<Evidence> recent = std::move(best);
        const std::optional<double> latestBadge = badge;
        best.reset(); badge.reset(); lastReadAt.reset();
        if (!recent || !(recent->sourceTime <= time) || !(time - recent->sourceTime <= policy.attachWindow)) return false;
        claimed = std::move(*recent);
        if (latestBadge) claimed.badgeHue = latestBadge;
        if (out) {
            out->sourceTime = claimed.sourceTime;
            out->resonators = claimed.resonators.data();
            out->resonatorCount = static_cast<int32_t>(claimed.resonators.size());
            out->unreadSlots = claimed.unreadSlots;
            out->badgeHue = gc_opt_double{claimed.badgeHue.has_value(), claimed.badgeHue.value_or(0)};
            out->faction = claimed.faction;
        }
        return true;
    }
};

extern "C" {

gl_portal_observer_policy gl_portal_observer_policy_default(void) { return gl_portal_observer_policy{10.0, 1.5}; }

gl_portal_observer *gl_portal_observer_create(const gl_portal_observer_policy *policy) {
    return new (std::nothrow) gl_portal_observer(policy ? *policy : gl_portal_observer_policy_default());
}

void gl_portal_observer_destroy(gl_portal_observer *observer) { delete observer; }

void gl_portal_observer_accept(gl_portal_observer *observer, const gl_portal_evidence *evidence) {
    if (observer && evidence) observer->accept(*evidence);
}

bool gl_portal_observer_claim(gl_portal_observer *observer, double time, gl_portal_evidence *out) {
    return observer && observer->claim(time, out);
}

}  // extern "C"

/* Parser ------------------------------------------------------------------ */

namespace {

using glyph_text::Scalars;
using glyph_text::Text;

bool isLevelLetter(const Text &word, std::size_t index) {
    const Scalars &key = word.key(index);
    return key == U"L" || key == U"l" || key == U"I" || key == U"|";
}

int wholeNumber(const Text &word, std::size_t index) {
    return glyph_text::wholeNumberOneToEight(word.character(index));
}

/** `text.split(whereSeparator: \.isWhitespace).map(String.init)`. */
std::vector<Text> words(const Text &text) {
    std::vector<Text> result;
    Scalars current;
    for (std::size_t index = 0; index < text.count(); ++index) {
        const Scalars character = text.character(index);
        if (glyph_text::isWhitespaceCharacter(character[0])) {
            if (!current.empty()) { result.emplace_back(current); current.clear(); }
        } else {
            current += character;
        }
    }
    if (!current.empty()) result.emplace_back(current);
    return result;
}

std::vector<int32_t> levelsIn(gc_string input) {
    const std::vector<Text> split = words(Text(glyph_text::decode(input)));
    if (split.size() == 1 && split[0].count() == 2 && split[0].key(0) == U"1") {
        const int value = wholeNumber(split[0], 1);
        if (value >= 1 && value <= 8) return {value};
    }
    std::vector<int32_t> found;
    std::size_t index = 0;
    while (index < split.size()) {
        Scalars kept;
        for (std::size_t character = 0; character < split[index].count(); ++character) {
            const Scalars &key = split[index].key(character);
            if (key == U"A" || key == U"^") continue;
            kept += split[index].character(character);
        }
        const Text word(kept);
        if (word.count() == 2 && isLevelLetter(word, 0) && wholeNumber(word, 1) >= 1) {
            found.push_back(wholeNumber(word, 1));
        } else if (word.count() == 1 && isLevelLetter(word, 0) && index + 1 < split.size()
                   && split[index + 1].count() == 1 && wholeNumber(split[index + 1], 0) >= 1) {
            found.push_back(wholeNumber(split[index + 1], 0));
            index += 1;
        }
        index += 1;
    }
    return found;
}

}  // namespace

extern "C" {

void gl_portal_parser_read(const gl_portal_parser_line *lines, int32_t count, gc_opt_double badgeHue, double time,
                           gl_portal_faction faction, const int32_t *yellowLabels, int32_t yellowLabelCount,
                           int32_t resonatorsOut[8], gl_portal_evidence *out) {
    std::vector<int32_t> levels;
    for (int32_t index = 0; lines && index < count; ++index) {
        if (!(lines[index].confidence >= 0.4)) continue;
        const std::vector<int32_t> read = levelsIn(lines[index].text);
        bool yellow = false;
        for (int32_t label = 0; yellowLabels && label < yellowLabelCount; ++label) yellow = yellow || yellowLabels[label] == index;
        if (yellow && read.size() == 1) levels.push_back(1);
        else levels.insert(levels.end(), read.begin(), read.end());
    }
    const int32_t kept = static_cast<int32_t>(std::min<std::size_t>(8, levels.size()));
    for (int32_t index = 0; resonatorsOut && index < kept; ++index) resonatorsOut[index] = levels[index];
    if (!out) return;
    out->sourceTime = time;
    out->resonators = resonatorsOut;
    out->resonatorCount = resonatorsOut ? kept : 0;
    out->unreadSlots = 8 - out->resonatorCount;
    out->badgeHue = badgeHue;
    out->faction = faction;
}

int32_t gl_portal_parser_levels(gc_string text, int32_t *out, int32_t capacity) {
    const std::vector<int32_t> levels = levelsIn(text);
    const auto count = static_cast<int32_t>(levels.size());
    if (count > capacity || (count > 0 && !out)) return count;
    std::copy(levels.begin(), levels.end(), out);
    return count;
}

bool gl_portal_parser_is_level_one_yellow(const double *hues, int32_t count) {
    if (!hues || count < 20) return false;
    int32_t yellow = 0;
    for (int32_t index = 0; index < count; ++index) yellow += hues[index] >= 50 && hues[index] <= 78;
    return static_cast<double>(yellow) >= static_cast<double>(count) * 0.6;
}

}  // extern "C"
