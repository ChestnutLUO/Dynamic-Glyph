/*
 * The gear logic: the drop tracker, the observation session, the evidence
 * schedule, the floating display and the two pixel readers, ported rule for
 * rule from their Swift oracles in Sources/GlyphRecognition (see
 * glyph_logic_gear.h). The text parser is in logic_gear_text.cpp.
 */

#include "logic_gear_internal.hpp"

#include <algorithm>
#include <cmath>
#include <deque>
#include <limits>
#include <map>
#include <set>
#include <utility>

// Swift never fuses a multiply and an add; neither may this file, or the
// rarity reader's sample positions could round differently.
#pragma clang fp contract(off)

namespace glyphgear {

namespace {

constexpr double kInfinity = std::numeric_limits<double>::infinity();

/* `Swift.max(_:_:)` returns `y >= x ? y : x`. */
inline double swiftMax(double x, double y) { return y >= x ? y : x; }
inline double swiftMin(double x, double y) { return y < x ? y : x; }

const char *const kTransmuterPlus = "ITO EN Transmuter (+)";
const char *const kTransmuterMinus = "ITO EN Transmuter (-)";

}  // namespace

/* ------------------------------------------------------------------------ */
/* Values                                                                    */

bool Entry::hasRarityMeter() const {
    if (levelState != GL_GEAR_LEVEL_NOT_APPLICABLE || !item) return false;
    return *item != "Portal Key" && *item != "Media";
}

gl_gear_rarity Entry::intrinsicRarity() const {
    if (levelState != GL_GEAR_LEVEL_NOT_APPLICABLE || !item) return GL_GEAR_RARITY_NONE;
    // GearDropEntry.fixedRarity.
    static const std::map<std::string, gl_gear_rarity> fixed = {
        {"Aegis Shield", GL_GEAR_RARITY_VERY_RARE},
        {"Hypercube", GL_GEAR_RARITY_VERY_RARE},
        {"ADA Refactor", GL_GEAR_RARITY_VERY_RARE},
        {"JARVIS Virus", GL_GEAR_RARITY_VERY_RARE},
        {"SoftBank Ultra Link", GL_GEAR_RARITY_VERY_RARE},
        {kTransmuterPlus, GL_GEAR_RARITY_VERY_RARE},
        {kTransmuterMinus, GL_GEAR_RARITY_VERY_RARE},
        {"Turret", GL_GEAR_RARITY_RARE},
        {"Force Amp", GL_GEAR_RARITY_RARE},
    };
    auto found = fixed.find(*item);
    return found == fixed.end() ? GL_GEAR_RARITY_NONE : found->second;
}

bool Entry::refines(const Entry &other) const {
    if (*this == other || column != other.column || row != other.row || quantity != other.quantity) return false;
    bool itemOK = !other.item || other.item == item;
    bool levelOK = other.levelState == GL_GEAR_LEVEL_UNREADABLE ||
                   (other.levelState == levelState && other.level == level);
    bool rarityOK = other.rarity == GL_GEAR_RARITY_NONE || other.rarity == GL_GEAR_RARITY_UNREADABLE ||
                    other.rarity == rarity;
    return itemOK && levelOK && rarityOK;
}

bool Entry::contradicts(const Entry &other) const {
    if (column != other.column || row != other.row || quantity != other.quantity) return true;
    if (item && other.item && *item != *other.item) return true;
    if (levelState != GL_GEAR_LEVEL_UNREADABLE && other.levelState != GL_GEAR_LEVEL_UNREADABLE &&
        (levelState != other.levelState || level != other.level))
        return true;
    auto known = [](gl_gear_rarity value) {
        return value != GL_GEAR_RARITY_NONE && value != GL_GEAR_RARITY_UNREADABLE;
    };
    return known(rarity) && known(other.rarity) && rarity != other.rarity;
}

std::vector<Entry> Entry::generalizations() const {
    std::vector<Entry> values{*this};
    auto add = [&values](const Entry &value) {
        for (const Entry &existing : values)
            if (existing == value) return;
        values.push_back(value);
    };
    // GearDropEntry(...) without `multiplied`: these carry none.
    auto make = [this](std::optional<std::string> name, gl_gear_level state, std::optional<int32_t> lvl) {
        Entry value;
        value.column = column;
        value.row = row;
        value.item = std::move(name);
        value.levelState = state;
        value.level = lvl;
        value.quantity = quantity;
        value.rarity = rarity;
        return value;
    };
    add(make(std::nullopt, levelState, level));
    add(make(item, GL_GEAR_LEVEL_UNREADABLE, std::nullopt));
    add(make(std::nullopt, GL_GEAR_LEVEL_UNREADABLE, std::nullopt));
    if (rarity != GL_GEAR_RARITY_NONE && rarity != GL_GEAR_RARITY_UNREADABLE) {
        // `for value in values` iterates the array as it was when the loop began.
        std::vector<Entry> snapshot = values;
        for (const Entry &value : snapshot) add(value.withRarity(GL_GEAR_RARITY_UNREADABLE));
    }
    return values;
}

int64_t Summary::recognizedQuantity() const {
    int64_t total = 0;
    for (const Panel &panel : panels)
        for (const Entry &entry : panel.entries)
            if (entry.item && entry.levelState != GL_GEAR_LEVEL_UNREADABLE) total += entry.quantity;
    return total;
}

int64_t Summary::unidentifiedQuantity() const {
    int64_t total = 0;
    for (const Panel &panel : panels)
        for (const Entry &entry : panel.entries)
            if (!entry.item || entry.levelState == GL_GEAR_LEVEL_UNREADABLE) total += entry.quantity;
    return total;
}

bool Summary::panelsReadInFull() const {
    if (panels.empty()) return false;
    for (const Panel &panel : panels)
        if (panel.partial) return false;
    return unidentifiedQuantity() == 0;
}

bool Summary::bothPanelsRead() const {
    if (panels.size() != 2 || panels[0].stage != GL_GEAR_STAGE_PORTAL || panels[1].stage != GL_GEAR_STAGE_BONUS)
        return false;
    for (const Panel &panel : panels)
        if (panel.partial) return false;
    return true;
}

/* ------------------------------------------------------------------------ */
/* Conversion                                                                */

Entry entryFrom(const gl_gear_entry &entry) {
    Entry value;
    value.column = entry.column;
    value.row = entry.row;
    if (entry.hasItem) value.item = toString(entry.item);
    value.levelState = entry.levelState;
    if (entry.level.has) value.level = entry.level.value;
    value.quantity = entry.quantity;
    value.rarity = entry.rarity;
    if (entry.hasMultiplied) value.multiplied = entry.multiplied;
    return value;
}

gl_gear_entry entryView(const Entry &entry) {
    gl_gear_entry out{};
    out.column = entry.column;
    out.row = entry.row;
    out.hasItem = entry.item.has_value();
    out.item = entry.item ? view(*entry.item) : gc_string{nullptr, 0};
    out.levelState = entry.levelState;
    out.level = gc_opt_int32{entry.level.has_value(), entry.level.value_or(0)};
    out.quantity = entry.quantity;
    out.rarity = entry.rarity;
    out.hasMultiplied = entry.multiplied.has_value();
    out.multiplied = entry.multiplied.value_or(false);
    return out;
}

namespace {

std::vector<std::string> stringsFrom(const gc_string *strings, int32_t count) {
    std::vector<std::string> values;
    if (strings == nullptr || count <= 0) return values;
    values.reserve(static_cast<size_t>(count));
    for (int32_t index = 0; index < count; ++index) values.push_back(toString(strings[index]));
    return values;
}

std::vector<Entry> entriesFrom(const gl_gear_entry *entries, int32_t count) {
    std::vector<Entry> values;
    if (entries == nullptr || count <= 0) return values;
    values.reserve(static_cast<size_t>(count));
    for (int32_t index = 0; index < count; ++index) values.push_back(entryFrom(entries[index]));
    return values;
}

}  // namespace

Summary summaryFrom(const gl_gear_summary &summary) {
    Summary value;
    value.groupID = summary.groupID;
    value.startedAt = summary.startedAt;
    value.closedAt = summary.closedAt;
    value.closeReason = toString(summary.closeReason);
    if (summary.hasHackID) value.hackID = summary.hackID;
    value.association = summary.association;
    if (summary.panels != nullptr && summary.panelCount > 0) {
        for (int32_t index = 0; index < summary.panelCount; ++index) {
            const gl_gear_panel &panel = summary.panels[index];
            Panel converted;
            converted.stage = panel.stage;
            converted.entries = entriesFrom(panel.entries, panel.entryCount);
            converted.partial = panel.partial;
            if (panel.hasEffects) converted.effects = stringsFrom(panel.effects, panel.effectCount);
            value.panels.push_back(std::move(converted));
        }
    }
    return value;
}

Evidence evidenceFrom(const gl_gear_evidence &evidence) {
    Evidence value;
    value.sourceTime = evidence.sourceTime;
    value.stage = evidence.stage;
    if (evidence.hasBounds) value.bounds = evidence.bounds;
    value.entries = entriesFrom(evidence.entries, evidence.entryCount);
    value.unreadableRows = evidence.unreadableRows;
    if (evidence.hasEffects) value.effects = stringsFrom(evidence.effects, evidence.effectCount);
    if (evidence.hasTitleLanguage) value.titleLanguage = evidence.titleLanguage;
    return value;
}

void SummaryExport::fill(Summary value, gl_gear_summary *out) {
    held_ = std::move(value);
    size_t entryCount = 0, effectCount = 0;
    for (const Panel &panel : held_.panels) {
        entryCount += panel.entries.size();
        if (panel.effects) effectCount += panel.effects->size();
    }
    panels_.clear();
    entries_.clear();
    effects_.clear();
    entries_.reserve(entryCount);
    effects_.reserve(effectCount);
    for (const Panel &panel : held_.panels) {
        gl_gear_panel converted{};
        converted.stage = panel.stage;
        converted.entryCount = static_cast<int32_t>(panel.entries.size());
        converted.entries = entries_.data() + entries_.size();
        for (const Entry &entry : panel.entries) entries_.push_back(entryView(entry));
        converted.partial = panel.partial;
        converted.hasEffects = panel.effects.has_value();
        converted.effects = effects_.data() + effects_.size();
        converted.effectCount = panel.effects ? static_cast<int32_t>(panel.effects->size()) : 0;
        if (panel.effects)
            for (const std::string &effect : *panel.effects) effects_.push_back(view(effect));
        panels_.push_back(converted);
    }
    gl_gear_summary result{};
    result.groupID = held_.groupID;
    result.startedAt = held_.startedAt;
    result.closedAt = held_.closedAt;
    result.closeReason = view(held_.closeReason);
    result.hasHackID = held_.hackID.has_value();
    result.hackID = held_.hackID.value_or(0);
    result.association = held_.association;
    result.panels = panels_.data();
    result.panelCount = static_cast<int32_t>(panels_.size());
    *out = result;
}

void EvidenceExport::fill(Evidence value, gl_gear_evidence *out) {
    held_ = std::move(value);
    entries_.clear();
    effects_.clear();
    for (const Entry &entry : held_.entries) entries_.push_back(entryView(entry));
    if (held_.effects)
        for (const std::string &effect : *held_.effects) effects_.push_back(view(effect));
    gl_gear_evidence result{};
    result.sourceTime = held_.sourceTime;
    result.stage = held_.stage;
    result.hasBounds = held_.bounds.has_value();
    result.bounds = held_.bounds.value_or(gc_panel_bounds{0, 0});
    result.entries = entries_.data();
    result.entryCount = static_cast<int32_t>(entries_.size());
    result.unreadableRows = held_.unreadableRows;
    result.hasEffects = held_.effects.has_value();
    result.effects = effects_.data();
    result.effectCount = static_cast<int32_t>(effects_.size());
    result.hasTitleLanguage = held_.titleLanguage.has_value();
    result.titleLanguage = held_.titleLanguage.value_or(GC_LANGUAGE_ENGLISH);
    *out = result;
}

/* ------------------------------------------------------------------------ */
/* Tracker                                                                   */

namespace {

/** `GearDropTracker.Slot`. */
struct Slot {
    struct Run {
        Entry value;
        double first;
        double last;
        int64_t count = 1;
    };
    std::vector<Run> runs;
    std::vector<Entry> confirmed;
    /// Every read of this cell, counted by the value read.
    std::vector<std::pair<Entry, int64_t>> tallies;
    bool conflictPending = false;
    std::vector<std::pair<int64_t, bool>> colors;

    std::optional<bool> multipliedFor(const Entry &entry) const {
        int64_t red = 0, reads = 0;
        for (const auto &color : colors) {
            if (color.first != entry.quantity) continue;
            ++reads;
            if (color.second) ++red;
        }
        int64_t white = reads - red;
        if (red >= 2 && white == 0) return true;
        if (white >= 2 && red == 0) return false;
        return std::nullopt;
    }

    /// `support(for:)`: reads of `value` or of something more specific.
    int64_t support(const Entry &value) const {
        int64_t total = 0;
        for (const auto &tally : tallies)
            if (tally.first == value || tally.first.refines(value)) total += tally.second;
        return total;
    }

    /// `outweighs`: twice the support and at least two reads more. The
    /// reasoning is in GearDropTracker.swift.
    static bool outweighs(int64_t strong, int64_t weak) { return strong >= 2 * weak && strong >= weak + 2; }

    struct Standing {
        Entry value;
        int64_t support;
    };

    /// `standing`: confirmed values, from the most supported down, without
    /// those a contradicting value already kept far outweighs.
    std::vector<Standing> standing() const {
        std::vector<Standing> ranked;
        for (const Entry &value : confirmed) ranked.push_back({value, support(value)});
        std::stable_sort(ranked.begin(), ranked.end(),
                         [](const Standing &a, const Standing &b) { return a.support > b.support; });
        std::vector<Standing> kept;
        for (const Standing &candidate : ranked) {
            bool outweighed = false;
            for (const Standing &other : kept)
                if (other.value.contradicts(candidate.value) && outweighs(other.support, candidate.support)) {
                    outweighed = true;
                    break;
                }
            if (!outweighed) kept.push_back(candidate);
        }
        return kept;
    }

    /// `mostSpecific(_:)`: the value that refines every other one.
    static std::optional<Entry> mostSpecific(const std::vector<Standing> &values) {
        for (const Standing &best : values) {
            bool all = true;
            for (const Standing &other : values)
                if (!(other.value == best.value || best.value.refines(other.value))) { all = false; break; }
            if (all) return best.value;
        }
        return std::nullopt;
    }

    std::optional<Entry> resolved() const { return mostSpecific(standing()); }

    static bool contains(const std::vector<Entry> &values, const Entry &value) {
        for (const Entry &existing : values)
            if (existing == value) return true;
        return false;
    }

    /// The panel was away for `duration`: that time does not count
    /// towards the reading gap of the reads taken before it left.
    void pause(double duration) {
        for (Run &run : runs) run.last += duration;
    }

    void accept(const Entry &entry, double time, const gl_gear_tracker_policy &policy) {
        std::vector<Entry> supported = entry.generalizations();
        std::vector<Run> next;
        for (Run run : runs) {
            if (contains(supported, run.value)) {
                if (time - run.last > policy.maximumReadingGap + 1e-9) {
                    run.first = time;
                    run.count = 0;
                }
                run.last = time;
                run.count += 1;
            } else if (run.value.refines(entry)) {
                // Lost detail neither votes nor contradicts.
            } else {
                continue;
            }
            next.push_back(std::move(run));
        }
        for (const Entry &value : supported) {
            bool present = false;
            for (const Run &run : next)
                if (run.value == value) { present = true; break; }
            if (!present) next.push_back(Run{value, time, time, 1});
        }
        runs = std::move(next);
        bool tallied = false;
        for (auto &tally : tallies)
            if (tally.first == entry) { tally.second += 1; tallied = true; break; }
        if (!tallied) tallies.emplace_back(entry, 1);
        for (const Run &run : runs) {
            if (run.count >= 2 && run.last - run.first + 1e-9 >= policy.minimumSpan &&
                !contains(confirmed, run.value))
                confirmed.push_back(run.value);
        }
        std::vector<Standing> kept = standing();
        if (auto best = mostSpecific(kept)) {
            bool agrees = entry == *best || entry.refines(*best) || best->refines(entry);
            int64_t read = support(entry);
            bool outweighed = false;
            for (const Standing &other : kept)
                if (other.value.contradicts(entry) && outweighs(other.support, read)) { outweighed = true; break; }
            conflictPending = !agrees && !outweighed;
        }
    }
};

}  // namespace

}  // namespace glyphgear

using namespace glyphgear;

struct gl_gear_tracker {
    gl_gear_tracker_policy policy;
    /// `Policy.bonusReturnWindow`, which the frozen policy struct lacks.
    double bonusReturnWindow = 2.0;
    gl_gear_disposition readingDisposition = GL_GEAR_DISPOSITION_NON_PANEL;
    int64_t nextGroupID = 1;
    std::optional<int64_t> groupID;
    double startedAt = 0;
    double lastReading = -std::numeric_limits<double>::infinity();
    double closedThrough = -std::numeric_limits<double>::infinity();
    std::optional<gl_gear_stage> currentStage;
    std::vector<Panel> panels;
    std::map<int64_t, Slot> slots;
    std::optional<int32_t> fewestUnreadableRows;
    std::optional<Slot> effectSlot;
    std::optional<double> absentSince;
    std::optional<double> departedAt;
    /// A departed Bonus panel with rows unconfirmed, kept open in case it
    /// was only hidden. `closeTime` is when the group would have closed.
    struct Hold {
        double since;
        double closeTime;
        std::optional<double> returnedAt;
        std::optional<double> absentAgainSince;
    };
    std::optional<Hold> hold;
    bool hasHeld = false;
    SummaryExport output;

    /// The current panel as it would be saved now.
    std::optional<Panel> currentPanel() const {
        if (!currentStage) return std::nullopt;
        std::vector<std::optional<Entry>> settled;
        for (const auto &pair : slots) {
            const Slot &slot = pair.second;
            std::optional<Entry> best = slot.conflictPending ? std::nullopt : slot.resolved();
            if (best) settled.push_back(best->withMultiplied(slot.multipliedFor(*best)));
            else settled.push_back(std::nullopt);
        }
        std::vector<Entry> entries;
        for (const auto &value : settled)
            if (value) entries.push_back(*value);
        std::optional<std::string> effect;
        if (effectSlot && !effectSlot->conflictPending) {
            if (auto best = effectSlot->resolved()) effect = best->item;
        }
        bool partial = entries.empty() || entries.size() != settled.size() ||
                       fewestUnreadableRows.value_or(1) > 0 || (effectSlot.has_value() && !effect);
        Panel panel;
        panel.stage = *currentStage;
        panel.entries = std::move(entries);
        panel.partial = partial;
        if (effect) panel.effects = std::vector<std::string>{*effect};
        return panel;
    }

    bool currentPanelSettled() const {
        if (hold) return false;
        auto panel = currentPanel();
        return panel && !panel->partial;
    }

    void savePanel() {
        if (auto panel = currentPanel()) panels.push_back(std::move(*panel));
        slots.clear();
        fewestUnreadableRows.reset();
        effectSlot.reset();
    }

    std::optional<Summary> finish(double time, const std::string &reason) {
        if (!groupID || !std::isfinite(time) || !(time >= startedAt)) return std::nullopt;
        std::string closeReason = reason;
        if (hold) {
            // A held panel had already left: the group ends when it did.
            time = swiftMax(startedAt, swiftMin(time, hold->closeTime));
            closeReason = "panelLeft";
        }
        savePanel();
        if (closeReason == "continuityLost")
            for (Panel &panel : panels) panel.partial = true;
        Summary summary;
        summary.groupID = *groupID;
        summary.startedAt = startedAt;
        summary.closedAt = time;
        summary.closeReason = closeReason;
        summary.association = GL_GEAR_ASSOCIATION_UNASSOCIATED;
        summary.panels = panels;
        groupID.reset();
        currentStage.reset();
        panels.clear();
        absentSince.reset();
        departedAt.reset();
        hold.reset();
        hasHeld = false;
        closedThrough = time;
        return summary;
    }

    std::optional<Summary> loseContinuity(double time) {
        if (!std::isfinite(time)) return std::nullopt;
        auto closed = finish(time, "continuityLost");
        closedThrough = swiftMax(closedThrough, time);
        return closed;
    }

    /// The panel left. A Bonus panel with rows unconfirmed holds the group
    /// open instead of closing it, once per group.
    std::optional<Summary> leave(double time, double since, bool returned) {
        auto panel = currentPanel();
        if (hasHeld || currentStage != GL_GEAR_STAGE_BONUS || !(panel && panel->partial))
            return finish(time, "panelLeft");
        hasHeld = true;
        Hold away;
        away.since = since;
        away.closeTime = time;
        if (returned) away.returnedAt = time;
        hold = away;
        return std::nullopt;
    }

    std::optional<Summary> observeHeld(double time, bool panelCandidate, std::optional<double> pending) {
        if (!hold) return std::nullopt;
        Hold away = *hold;
        double deadline = away.closeTime + bonusReturnWindow;
        if (panelCandidate) {
            if (!away.returnedAt && time <= deadline + 1e-9) away.returnedAt = time;
            away.absentAgainSince.reset();
        } else if (away.returnedAt) {
            if (!away.absentAgainSince) away.absentAgainSince = time;
        }
        hold = away;
        bool waiting = false;
        if (pending) {
            double source = *pending;
            waiting = std::isfinite(source) && source >= startedAt && source >= closedThrough && source <= time &&
                      source <= deadline && time - source <= policy.maximumCompletionWait;
        }
        if (!waiting && (time > deadline || time - startedAt > policy.groupLimit)) return finish(time, "panelLeft");
        return std::nullopt;
    }

    void resume(double time) {
        if (!hold) return;
        Hold away = *hold;
        double duration = swiftMax(0, swiftMin(away.returnedAt.value_or(time), time) - away.since);
        for (auto &pair : slots) pair.second.pause(duration);
        if (effectSlot) effectSlot->pause(duration);
        hold.reset();
        departedAt.reset();
        absentSince = away.absentAgainSince;
    }

    std::optional<Summary> observe(double time, bool panelCandidate, bool continuityLost,
                                   std::optional<double> pending) {
        if (continuityLost) return loseContinuity(time);
        if (!std::isfinite(time) || !groupID || !(time >= startedAt)) return std::nullopt;
        if (hold) return observeHeld(time, panelCandidate, pending);
        if (panelCandidate) {
            if (absentSince && time - *absentSince + 1e-9 >= policy.departureSpan)
                return leave(time, *absentSince, true);
            absentSince.reset();
        } else {
            if (!absentSince) absentSince = time;
            if (time - *absentSince + 1e-9 >= policy.departureSpan) departedAt = absentSince;
        }
        bool draining = false;
        if (pending) {
            double source = *pending;
            draining = std::isfinite(source) && source >= startedAt && source >= closedThrough && source <= time &&
                       source < absentSince.value_or(kInfinity) && time - source <= policy.maximumCompletionWait;
        }
        if (time - startedAt > policy.groupLimit) {
            if (draining) return std::nullopt;
            return finish(time, "groupTimeout");
        }
        if (departedAt && !draining) return leave(time, *departedAt, false);
        return std::nullopt;
    }

    std::optional<Summary> accept(const Evidence &evidence) {
        double time = evidence.sourceTime;
        if (!std::isfinite(time)) {
            readingDisposition = GL_GEAR_DISPOSITION_INVALID_TIME;
            return std::nullopt;
        }
        if (!(time >= closedThrough)) {
            readingDisposition = GL_GEAR_DISPOSITION_CLOSED_INTERVAL;
            return std::nullopt;
        }
        if (!(time > lastReading)) {
            readingDisposition = GL_GEAR_DISPOSITION_OUT_OF_ORDER;
            return std::nullopt;
        }
        lastReading = time;
        if (evidence.stage != GL_GEAR_STAGE_PORTAL && evidence.stage != GL_GEAR_STAGE_BONUS) {
            readingDisposition = GL_GEAR_DISPOSITION_NON_PANEL;
            return std::nullopt;
        }
        readingDisposition = GL_GEAR_DISPOSITION_ACCEPTED;
        std::optional<Summary> closed;
        if (!hold && departedAt && time >= *departedAt && evidence.stage == GL_GEAR_STAGE_BONUS) {
            // Read on a frame after the departure: the panel came back.
            closed = leave(time, *departedAt, true);
        }
        if (hold && time >= hold->since) {
            // Only the Bonus panel, back in time, joins; a portal panel is
            // the next drop and never does.
            if (evidence.stage == GL_GEAR_STAGE_BONUS && time <= hold->closeTime + bonusReturnWindow + 1e-9) {
                resume(time);
            } else {
                closed = finish(time, "panelLeft");
            }
        } else if (!hold && departedAt && time >= *departedAt) {
            closed = finish(time, "panelLeft");
        } else if (currentStage == GL_GEAR_STAGE_BONUS && evidence.stage == GL_GEAR_STAGE_PORTAL) {
            closed = finish(time, "nextPortalPanel");
        }
        if (!groupID) {
            groupID = nextGroupID;
            nextGroupID += 1;
            startedAt = time;
        }
        if (absentSince && time >= *absentSince) absentSince.reset();
        if (currentStage != evidence.stage) {
            savePanel();
            currentStage = evidence.stage;
        }
        for (const Entry &entry : evidence.entries) {
            Slot &slot = slots[entry.position()];
            slot.accept(entry.withMultiplied(std::nullopt), time, policy);
            if (entry.multiplied) slot.colors.emplace_back(entry.quantity, *entry.multiplied);
        }
        fewestUnreadableRows = std::min(fewestUnreadableRows.value_or(evidence.unreadableRows), evidence.unreadableRows);
        if (evidence.effects) {
            for (const std::string &effect : *evidence.effects) {
                if (effect != "ITO EN (+)" && effect != "ITO EN (-)") continue;
                if (!effectSlot) effectSlot = Slot();
                Entry value;
                value.column = 0;
                value.row = 0;
                value.item = effect;
                value.levelState = GL_GEAR_LEVEL_NOT_APPLICABLE;
                value.quantity = 1;
                effectSlot->accept(value, time, policy);
            }
        }
        return closed;
    }
};

extern "C" {

gl_gear_rarity gl_gear_entry_intrinsic_rarity(const gl_gear_entry *entry) {
    if (entry == nullptr) return GL_GEAR_RARITY_NONE;
    return entryFrom(*entry).intrinsicRarity();
}

bool gl_gear_entry_has_rarity_meter(const gl_gear_entry *entry) {
    if (entry == nullptr) return false;
    return entryFrom(*entry).hasRarityMeter();
}

int64_t gl_gear_summary_recognized_quantity(const gl_gear_summary *summary) {
    return summary == nullptr ? 0 : summaryFrom(*summary).recognizedQuantity();
}

int64_t gl_gear_summary_unidentified_quantity(const gl_gear_summary *summary) {
    return summary == nullptr ? 0 : summaryFrom(*summary).unidentifiedQuantity();
}

bool gl_gear_summary_panels_read_in_full(const gl_gear_summary *summary) {
    return summary != nullptr && summaryFrom(*summary).panelsReadInFull();
}

bool gl_gear_summary_both_panels_read(const gl_gear_summary *summary) {
    return summary != nullptr && summaryFrom(*summary).bothPanelsRead();
}

gc_string gl_gear_disposition_name(gl_gear_disposition disposition) {
    static const std::string names[] = {"accepted", "invalidTime", "outOfOrder", "closedInterval", "nonPanel"};
    int index = static_cast<int>(disposition);
    if (index < 0 || index > 4) return gc_string{nullptr, 0};
    return view(names[index]);
}

gl_gear_tracker_policy gl_gear_tracker_policy_default(void) {
    gl_gear_tracker_policy policy;
    policy.minimumSpan = 0.1;
    policy.maximumReadingGap = 1.2;
    policy.departureSpan = 0.15;
    policy.maximumCompletionWait = 2.0;
    policy.groupLimit = 5.0;
    return policy;
}

gl_gear_tracker *gl_gear_tracker_create(const gl_gear_tracker_policy *policy) {
    auto *tracker = new gl_gear_tracker();
    tracker->policy = policy != nullptr ? *policy : gl_gear_tracker_policy_default();
    return tracker;
}

gl_gear_tracker *gl_gear_tracker_create_with_return_window(const gl_gear_tracker_policy *policy,
                                                           double bonusReturnWindow) {
    auto *tracker = gl_gear_tracker_create(policy);
    tracker->bonusReturnWindow = bonusReturnWindow;
    return tracker;
}

void gl_gear_tracker_destroy(gl_gear_tracker *tracker) { delete tracker; }

static bool exportSummary(gl_gear_tracker *tracker, std::optional<Summary> summary, gl_gear_summary *out) {
    if (!summary) return false;
    if (out != nullptr) tracker->output.fill(std::move(*summary), out);
    return true;
}

bool gl_gear_tracker_accept(gl_gear_tracker *tracker, const gl_gear_evidence *evidence, gl_gear_summary *out) {
    if (tracker == nullptr || evidence == nullptr) return false;
    return exportSummary(tracker, tracker->accept(evidenceFrom(*evidence)), out);
}

bool gl_gear_tracker_observe(gl_gear_tracker *tracker, double time, bool panelCandidate, bool continuityLost,
                             gc_opt_double pendingReadSourceTime, gl_gear_summary *out) {
    if (tracker == nullptr) return false;
    std::optional<double> pending;
    if (pendingReadSourceTime.has) pending = pendingReadSourceTime.value;
    return exportSummary(tracker, tracker->observe(time, panelCandidate, continuityLost, pending), out);
}

bool gl_gear_tracker_lose_continuity(gl_gear_tracker *tracker, double time, gl_gear_summary *out) {
    if (tracker == nullptr) return false;
    return exportSummary(tracker, tracker->loseContinuity(time), out);
}

bool gl_gear_tracker_finish(gl_gear_tracker *tracker, double time, gc_string reason, gl_gear_summary *out) {
    if (tracker == nullptr) return false;
    return exportSummary(tracker, tracker->finish(time, toString(reason)), out);
}

bool gl_gear_tracker_is_observing(const gl_gear_tracker *tracker) {
    return tracker != nullptr && tracker->groupID.has_value();
}

bool gl_gear_tracker_current_panel_settled(const gl_gear_tracker *tracker) {
    return tracker != nullptr && tracker->currentPanelSettled();
}

gl_gear_disposition gl_gear_tracker_reading_disposition(const gl_gear_tracker *tracker) {
    return tracker == nullptr ? GL_GEAR_DISPOSITION_NON_PANEL : tracker->readingDisposition;
}

}  // extern "C"

/* ------------------------------------------------------------------------ */
/* Observation session                                                       */

struct gl_gear_session {
    gl_gear_session_policy policy;
    std::vector<gl_gear_wait> waiting;
    std::vector<gl_gear_event> events;
    /* Event reasons; a deque never moves its elements, so `events` can
     * point into it. */
    std::deque<std::string> reasons;
    std::set<int64_t> seen;
    std::optional<int64_t> lastInputHack;
    std::optional<double> lastFrameTime;
    bool associationUncertain = false;
    double uncertainSince = -std::numeric_limits<double>::infinity();
    /// `Policy.repeatedBonusWindow`, which the frozen policy struct lacks.
    double repeatedBonusWindow = 2.0;
    /// When the last group closed, if it ended on a Bonus panel.
    double lastBonusEnd = -std::numeric_limits<double>::infinity();
    SummaryExport output;

    void appendEvent(double time, std::optional<int64_t> hackID, const std::string &reason) {
        reasons.push_back(reason);
        gl_gear_event event{};
        event.time = time;
        event.hasHackID = hackID.has_value();
        event.hackID = hackID.value_or(0);
        event.reason = view(reasons.back());
        events.push_back(event);
    }

    bool prepareFrame(double time, bool continuityLost) {
        if (!std::isfinite(time)) return false;
        bool lost = continuityLost || (lastFrameTime && time < *lastFrameTime);
        lastFrameTime = swiftMax(lastFrameTime.value_or(time), time);
        if (lost) invalidate(time, "frameGap");
        return lost;
    }

    void observe(double time, int64_t hackID, bool inputVisible, bool gameProgressVisible, bool inputPhaseIsInput) {
        if (!std::isfinite(time)) return;
        if (lastFrameTime && time < *lastFrameTime) return;
        lastFrameTime = time;
        if (inputVisible && inputPhaseIsInput && hackID > 0) {
            lastInputHack = hackID;
        } else if (lastInputHack) {
            int64_t ended = *lastInputHack;
            enqueue(ended, time);
            lastInputHack.reset();
        }
        if (gameProgressVisible)
            for (gl_gear_wait &wait : waiting) wait.lastProgress = time;
        expire(time);
        settleUncertainty(time);
    }

    void enqueue(int64_t hackID, double time) {
        if (!std::isfinite(time) || hackID <= 0 || !seen.insert(hackID).second) return;
        for (gl_gear_wait &wait : waiting) wait.lastProgress = time;
        gl_gear_wait wait{};
        wait.hackID = hackID;
        wait.startedAt = time;
        wait.lastProgress = time;
        waiting.push_back(wait);
        appendEvent(time, hackID, "waiting");
        if (static_cast<int64_t>(waiting.size()) > policy.maximumWaiting) invalidate(time, "queueLimit");
    }

    void acceptResult(int64_t hackID, std::optional<int64_t> finalBonus) {
        for (gl_gear_wait &wait : waiting) {
            if (wait.hackID != hackID) continue;
            wait.hasFinalBonus = finalBonus.has_value();
            wait.finalBonus = finalBonus.value_or(0);
            return;
        }
    }

    static std::string associationName(gl_gear_association association) {
        switch (association) {
        case GL_GEAR_ASSOCIATION_UNASSOCIATED: return "unassociated";
        case GL_GEAR_ASSOCIATION_ORDERED: return "ordered";
        case GL_GEAR_ASSOCIATION_ORDERED_WITHOUT_BONUS: return "orderedWithoutBonus";
        case GL_GEAR_ASSOCIATION_BONUS_EXPECTED: return "bonusExpected";
        case GL_GEAR_ASSOCIATION_NO_WAITING_HACK: return "noWaitingHack";
        case GL_GEAR_ASSOCIATION_UNCERTAIN_CONTINUITY: return "uncertainContinuity";
        case GL_GEAR_ASSOCIATION_REPEATED_BONUS: return "repeatedBonus";
        }
        return "";
    }

    Summary close(Summary group) {
        double time = group.closedAt;
        expire(time);
        settleUncertainty(time);
        group.hackID.reset();
        const double previousBonusEnd = lastBonusEnd;
        lastBonusEnd = !group.panels.empty() && group.panels.back().stage == GL_GEAR_STAGE_BONUS
            ? time : -std::numeric_limits<double>::infinity();
        // A Bonus panel with no row read, first seen soon after the last
        // group ended on a Bonus panel, is most likely that panel again.
        if (group.panels.size() == 1 && group.panels.front().stage == GL_GEAR_STAGE_BONUS &&
            group.panels.front().entries.empty() && group.startedAt >= previousBonusEnd &&
            group.startedAt - previousBonusEnd <= repeatedBonusWindow) {
            group.association = GL_GEAR_ASSOCIATION_REPEATED_BONUS;
            return group;
        }
        if (waiting.empty()) {
            group.association =
                associationUncertain ? GL_GEAR_ASSOCIATION_UNCERTAIN_CONTINUITY : GL_GEAR_ASSOCIATION_NO_WAITING_HACK;
            return group;
        }
        gl_gear_wait oldest = waiting.front();
        bool hasBonusPanel = false;
        for (const Panel &panel : group.panels)
            if (panel.stage == GL_GEAR_STAGE_BONUS) hasBonusPanel = true;
        if (!hasBonusPanel && oldest.hasFinalBonus && oldest.finalBonus > 0) {
            group.association = GL_GEAR_ASSOCIATION_BONUS_EXPECTED;
            return group;
        }
        waiting.erase(waiting.begin());
        if (associationUncertain) {
            group.association = GL_GEAR_ASSOCIATION_UNCERTAIN_CONTINUITY;
            appendEvent(time, oldest.hackID, "uncertainContinuity");
        } else {
            group.association = hasBonusPanel ? GL_GEAR_ASSOCIATION_ORDERED : GL_GEAR_ASSOCIATION_ORDERED_WITHOUT_BONUS;
            group.hackID = oldest.hackID;
            appendEvent(time, oldest.hackID, associationName(group.association));
        }
        settleUncertainty(time);
        return group;
    }

    void expire(double time) {
        std::vector<gl_gear_wait> expired;
        for (const gl_gear_wait &wait : waiting) {
            if (time - wait.lastProgress > policy.inactivityLimit || time - wait.startedAt > policy.absoluteLimit)
                expired.push_back(wait);
        }
        if (expired.empty()) return;
        associationUncertain = true;
        uncertainSince = time;
        std::set<int64_t> ids;
        for (const gl_gear_wait &wait : expired) {
            appendEvent(time, wait.hackID, "waitTimeout");
            ids.insert(wait.hackID);
        }
        std::vector<gl_gear_wait> kept;
        for (const gl_gear_wait &wait : waiting)
            if (ids.count(wait.hackID) == 0) kept.push_back(wait);
        waiting = std::move(kept);
    }

    void invalidate(double time, const std::string &reason) {
        if (!waiting.empty()) {
            associationUncertain = true;
            uncertainSince = time;
        }
        for (const gl_gear_wait &wait : waiting) appendEvent(time, wait.hackID, reason);
        waiting.clear();
        lastInputHack.reset();
    }

    void settleUncertainty(double time) {
        if (!associationUncertain || !waiting.empty() || !(time - uncertainSince >= policy.inactivityLimit)) return;
        associationUncertain = false;
        appendEvent(time, std::nullopt, "orderRestored");
    }
};

extern "C" {

gl_gear_session_policy gl_gear_session_policy_default(void) {
    gl_gear_session_policy policy;
    policy.inactivityLimit = 30.0;
    policy.absoluteLimit = 120.0;
    policy.maximumWaiting = 16;
    return policy;
}

gl_gear_session *gl_gear_session_create(const gl_gear_session_policy *policy) {
    auto *session = new gl_gear_session();
    session->policy = policy != nullptr ? *policy : gl_gear_session_policy_default();
    return session;
}

gl_gear_session *gl_gear_session_create_with_repeat_window(const gl_gear_session_policy *policy,
                                                           double repeatedBonusWindow) {
    auto *session = gl_gear_session_create(policy);
    session->repeatedBonusWindow = repeatedBonusWindow;
    return session;
}

void gl_gear_session_destroy(gl_gear_session *session) { delete session; }

bool gl_gear_session_prepare_frame(gl_gear_session *session, double time, bool continuityLost) {
    return session != nullptr && session->prepareFrame(time, continuityLost);
}

void gl_gear_session_observe(gl_gear_session *session, double time, int64_t hackID, bool inputVisible,
                             bool gameProgressVisible, bool inputPhaseIsInput) {
    if (session != nullptr) session->observe(time, hackID, inputVisible, gameProgressVisible, inputPhaseIsInput);
}

void gl_gear_session_enqueue(gl_gear_session *session, int64_t hackID, double time) {
    if (session != nullptr) session->enqueue(hackID, time);
}

void gl_gear_session_accept_result(gl_gear_session *session, int64_t hackID, bool hasFinalHackingBonus,
                                   int64_t finalHackingBonus) {
    if (session == nullptr) return;
    std::optional<int64_t> bonus;
    if (hasFinalHackingBonus) bonus = finalHackingBonus;
    session->acceptResult(hackID, bonus);
}

bool gl_gear_session_close(gl_gear_session *session, const gl_gear_summary *group, gl_gear_summary *out) {
    if (session == nullptr || group == nullptr || out == nullptr) return false;
    session->output.fill(session->close(summaryFrom(*group)), out);
    return true;
}

void gl_gear_session_expire(gl_gear_session *session, double time) {
    if (session != nullptr) session->expire(time);
}

void gl_gear_session_invalidate(gl_gear_session *session, double time, gc_string reason) {
    if (session != nullptr) session->invalidate(time, toString(reason));
}

const gl_gear_wait *gl_gear_session_waiting(const gl_gear_session *session, int32_t *count) {
    if (session == nullptr) {
        if (count != nullptr) *count = 0;
        return nullptr;
    }
    if (count != nullptr) *count = static_cast<int32_t>(session->waiting.size());
    return session->waiting.data();
}

const gl_gear_event *gl_gear_session_events(const gl_gear_session *session, int32_t *count) {
    if (session == nullptr) {
        if (count != nullptr) *count = 0;
        return nullptr;
    }
    if (count != nullptr) *count = static_cast<int32_t>(session->events.size());
    return session->events.data();
}

bool gl_gear_session_is_association_uncertain(const gl_gear_session *session) {
    return session != nullptr && session->associationUncertain;
}

}  // extern "C"

/* ------------------------------------------------------------------------ */
/* Evidence schedule                                                         */

struct gl_gear_schedule {
    static constexpr int perStageLimit = 4;
    static constexpr double minimumInterval = 0.5;
    int portalCount = 0;
    int bonusCount = 0;
    double lastPortal = -std::numeric_limits<double>::infinity();
    double lastBonus = -std::numeric_limits<double>::infinity();

    bool shouldSave(gl_gear_stage stage, double time) const {
        if (!std::isfinite(time)) return false;
        switch (stage) {
        case GL_GEAR_STAGE_PORTAL: return portalCount < perStageLimit && time - lastPortal + 1e-9 >= minimumInterval;
        case GL_GEAR_STAGE_BONUS: return bonusCount < perStageLimit && time - lastBonus + 1e-9 >= minimumInterval;
        default: return false;
        }
    }

    void didEnqueue(gl_gear_stage stage, double time) {
        if (!shouldSave(stage, time)) return;
        switch (stage) {
        case GL_GEAR_STAGE_PORTAL:
            portalCount += 1;
            lastPortal = time;
            break;
        case GL_GEAR_STAGE_BONUS:
            bonusCount += 1;
            lastBonus = time;
            break;
        default: break;
        }
    }
};

extern "C" {

gl_gear_schedule *gl_gear_schedule_create(void) { return new gl_gear_schedule(); }

void gl_gear_schedule_destroy(gl_gear_schedule *schedule) { delete schedule; }

bool gl_gear_schedule_should_save(const gl_gear_schedule *schedule, gl_gear_stage stage, double time) {
    return schedule != nullptr && schedule->shouldSave(stage, time);
}

void gl_gear_schedule_did_enqueue(gl_gear_schedule *schedule, gl_gear_stage stage, double time) {
    if (schedule != nullptr) schedule->didEnqueue(stage, time);
}

}  // extern "C"

/* ------------------------------------------------------------------------ */
/* Floating display                                                          */

namespace {

bool sameDisplay(const std::optional<gl_gear_display_value> &a, const std::optional<gl_gear_display_value> &b) {
    if (a.has_value() != b.has_value()) return false;
    if (!a) return true;
    return a->state == b->state && a->hasHackID == b->hasHackID && (!a->hasHackID || a->hackID == b->hackID) &&
           a->hasItemCount == b->hasItemCount && (!a->hasItemCount || a->itemCount == b->itemCount) &&
           a->waitingCount == b->waitingCount;
}

gl_gear_display_value displayValue(gl_gear_display_state state, std::optional<int64_t> hackID,
                                   std::optional<int64_t> itemCount, int64_t waitingCount) {
    gl_gear_display_value value{};
    value.state = state;
    value.hasHackID = hackID.has_value();
    value.hackID = hackID.value_or(0);
    value.hasItemCount = itemCount.has_value();
    value.itemCount = itemCount.value_or(0);
    value.waitingCount = waitingCount;
    return value;
}

}  // namespace

struct gl_gear_display {
    std::optional<gl_gear_display_value> display;
    int64_t revision = 0;
    std::optional<gl_gear_display_value> completion;
    double completedAt = -std::numeric_limits<double>::infinity();
    bool standalone = false;
    int64_t standaloneItems = 0;

    void finished(const Summary &group) {
        // The last group's Bonus panel found again adds nothing: that group's
        // completion stays.
        if (group.association == GL_GEAR_ASSOCIATION_REPEATED_BONUS) return;
        gl_gear_display_state state;
        if (standalone) {
            state = group.panelsReadInFull() ? GL_GEAR_DISPLAY_READ : GL_GEAR_DISPLAY_PARTIAL;
            standaloneItems += group.recognizedQuantity();
        } else {
            state = !group.hackID ? GL_GEAR_DISPLAY_UNATTACHED
                    : (group.bothPanelsRead() && group.unidentifiedQuantity() == 0) ? GL_GEAR_DISPLAY_READ
                                                                                     : GL_GEAR_DISPLAY_PARTIAL;
        }
        completion = displayValue(state, group.hackID, group.recognizedQuantity(), 0);
        completedAt = group.closedAt;
    }

    void ended(int64_t hackID, double time) {
        if (completedAt == time) return;
        completion = displayValue(GL_GEAR_DISPLAY_NOT_READ, hackID, std::nullopt, 0);
        completedAt = time;
    }

    void update(const gl_gear_wait *waiting, int32_t count, bool reading, bool associationUncertain, double time) {
        std::optional<gl_gear_display_value> next;
        bool hasWaiting = waiting != nullptr && count > 0;
        if (completion && time >= completedAt && time - completedAt < 4) {
            next = completion;
        } else if (reading || hasWaiting) {
            std::optional<int64_t> hackID;
            if (!associationUncertain && hasWaiting) hackID = waiting[0].hackID;
            next = displayValue(reading ? GL_GEAR_DISPLAY_READING : GL_GEAR_DISPLAY_WAITING, hackID, std::nullopt,
                                hasWaiting ? count : 0);
        } else if (standalone) {
            next = displayValue(GL_GEAR_DISPLAY_WATCHING, std::nullopt, standaloneItems, 0);
        }
        if (!sameDisplay(next, display)) {
            display = next;
            revision += 1;
        }
    }
};

extern "C" {

gl_gear_display *gl_gear_display_create(bool standalone) {
    auto *display = new gl_gear_display();
    display->standalone = standalone;
    return display;
}

void gl_gear_display_destroy(gl_gear_display *display) { delete display; }

void gl_gear_display_update(gl_gear_display *display, const gl_gear_wait *waiting, int32_t waitingCount,
                            bool reading, bool associationUncertain, double time) {
    if (display != nullptr) display->update(waiting, waitingCount, reading, associationUncertain, time);
}

void gl_gear_display_finished(gl_gear_display *display, const gl_gear_summary *group) {
    if (display != nullptr && group != nullptr) display->finished(summaryFrom(*group));
}

void gl_gear_display_ended(gl_gear_display *display, int64_t hackID, double time) {
    if (display != nullptr) display->ended(hackID, time);
}

bool gl_gear_display_get(const gl_gear_display *display, gl_gear_display_value *out) {
    if (display == nullptr || !display->display) return false;
    if (out != nullptr) *out = *display->display;
    return true;
}

int64_t gl_gear_display_revision(const gl_gear_display *display) {
    return display == nullptr ? 0 : display->revision;
}

}  // extern "C"

/* ------------------------------------------------------------------------ */
/* Pixel readers                                                             */

namespace {

struct RGB {
    double red;
    double green;
    double blue;
};

bool usable(const gc_color_image &image) {
    return image.data != nullptr && image.width > 0 && image.height > 0 && image.bytesPerPixel > 0 &&
           image.redOffset >= 0 && image.greenOffset >= 0 && image.blueOffset >= 0 &&
           image.redOffset < image.bytesPerPixel && image.greenOffset < image.bytesPerPixel &&
           image.blueOffset < image.bytesPerPixel && image.bytesPerRow >= image.width * image.bytesPerPixel;
}

inline RGB pixelAt(const gc_color_image &image, int64_t x, int64_t y) {
    const uint8_t *pixel = image.data + static_cast<size_t>(y) * static_cast<size_t>(image.bytesPerRow) +
                           static_cast<size_t>(x) * static_cast<size_t>(image.bytesPerPixel);
    return RGB{static_cast<double>(pixel[image.redOffset]), static_cast<double>(pixel[image.greenOffset]),
               static_cast<double>(pixel[image.blueOffset])};
}

/* Swift's variadic max and min: max(max(x, y), z). */
inline double max3(double a, double b, double c) { return swiftMax(swiftMax(a, b), c); }
inline double swiftMin(double x, double y) { return y < x ? y : x; }
inline double min3(double a, double b, double c) { return swiftMin(swiftMin(a, b), c); }

enum class Ink { common, rare, veryRare, inactive, background, unknown };

Ink inkOf(const RGB &pixel) {
    double r = pixel.red, g = pixel.green, b = pixel.blue;
    double high = max3(r, g, b), low = min3(r, g, b), delta = high - low;
    if (high < 45) return Ink::background;
    if (delta < 22 && high < 160) return Ink::inactive;
    if (!(high >= 75 && delta / high >= 0.25)) return Ink::unknown;
    double hue;
    if (high == r) hue = 60 * (g - b) / delta;
    else if (high == g) hue = 120 + 60 * (b - r) / delta;
    else hue = 240 + 60 * (r - g) / delta;
    if (hue < 0) hue += 360;
    if (hue >= 135 && hue <= 180) return Ink::common;
    if (hue >= 245 && hue <= 285) return Ink::rare;
    if (hue >= 300 && hue <= 340) return Ink::veryRare;
    return Ink::unknown;
}

}  // namespace

extern "C" {

bool gl_gear_quantity_color_read(gc_color_image image, bool *multiplied) {
    if (!usable(image)) return false;
    int64_t ink = 0, red = 0, white = 0;
    for (int64_t y = 0; y < image.height; ++y) {
        for (int64_t x = 0; x < image.width; ++x) {
            RGB pixel = pixelAt(image, x, y);
            double r = pixel.red, g = pixel.green, b = pixel.blue;
            double high = max3(r, g, b), low = min3(r, g, b);
            if (!(high >= 90)) continue;
            ink += 1;
            double saturation = (high - low) / high;
            if (saturation < 0.3) {
                white += 1;
                continue;
            }
            if (!(high == r && saturation >= 0.5)) continue;
            double hue = 60 * (g - b) / (high - low);
            if (std::fabs(hue) <= 20) red += 1;
        }
    }
    if (ink < 20) return false;
    bool value;
    if (static_cast<double>(red) >= 0.85 * static_cast<double>(ink)) value = true;
    else if (static_cast<double>(white) >= 0.85 * static_cast<double>(ink)) value = false;
    else return false;
    if (multiplied != nullptr) *multiplied = value;
    return true;
}

gl_gear_rarity gl_gear_rarity_read(gc_color_image image) {
    if (!usable(image) || image.width < 16 || image.height < 12) return GL_GEAR_RARITY_NONE;
    static const double centers[3] = {0.216, 0.459, 0.702};
    static const double sampleYs[5] = {-0.16, -0.08, 0, 0.08, 0.16};
    static const double sampleXs[3] = {-0.02, 0, 0.02};
    static const double gaps[2] = {0.3375, 0.5805};
    static const double gapYs[5] = {-0.12, -0.06, 0, 0.06, 0.12};
    const double width = static_cast<double>(image.width), height = static_cast<double>(image.height);
    bool sawCommon = false, sawRare = false, sawVeryRare = false;
    for (int dx = -4; dx <= 4; ++dx) {
        for (int dy = -3; dy <= 3; ++dy) {
            auto sample = [&](double x, double y) {
                double fx = (x + static_cast<double>(dx) * 0.02) * width + (0.5 - y) * height * 0.35;
                double fy = (y + static_cast<double>(dy) * 0.05) * height;
                // Int(_:) truncates toward zero; every value here is finite.
                int64_t px = static_cast<int64_t>(fx);
                int64_t py = static_cast<int64_t>(fy);
                if (px < 0 || px >= image.width || py < 0 || py >= image.height) return Ink::unknown;
                return inkOf(pixelAt(image, px, py));
            };
            // Each label is nil (-1) or the first ink with 11 of 15 samples.
            int labels[3];
            for (int index = 0; index < 3; ++index) {
                Ink samples[15];
                int count = 0;
                for (double y : sampleYs)
                    for (double x : sampleXs) samples[count++] = sample(centers[index] + x, 0.5 + y);
                labels[index] = -1;
                static const Ink order[4] = {Ink::common, Ink::rare, Ink::veryRare, Ink::inactive};
                for (Ink label : order) {
                    int matches = 0;
                    for (Ink value : samples)
                        if (value == label) ++matches;
                    if (matches >= 11) {
                        labels[index] = static_cast<int>(label);
                        break;
                    }
                }
            }
            bool separated = true;
            for (double x : gaps) {
                int background = 0;
                for (double offset : gapYs)
                    if (sample(x, 0.5 + offset) == Ink::background) ++background;
                if (background < 3) {
                    separated = false;
                    break;
                }
            }
            if (!separated) continue;
            const int common = static_cast<int>(Ink::common), rare = static_cast<int>(Ink::rare),
                      veryRare = static_cast<int>(Ink::veryRare), inactive = static_cast<int>(Ink::inactive);
            if (labels[0] == common && labels[1] == inactive && labels[2] == inactive) sawCommon = true;
            else if (labels[0] == rare && labels[1] == rare && labels[2] == inactive) sawRare = true;
            else if (labels[0] == veryRare && labels[1] == veryRare && labels[2] == veryRare) sawVeryRare = true;
        }
    }
    int kinds = (sawCommon ? 1 : 0) + (sawRare ? 1 : 0) + (sawVeryRare ? 1 : 0);
    if (kinds != 1) return GL_GEAR_RARITY_NONE;
    if (sawCommon) return GL_GEAR_RARITY_COMMON;
    if (sawRare) return GL_GEAR_RARITY_RARE;
    return GL_GEAR_RARITY_VERY_RARE;
}

}  // extern "C"
