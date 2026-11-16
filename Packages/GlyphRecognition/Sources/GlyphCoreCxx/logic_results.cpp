// The results area of the logic layer: the result page parser, the hack
// result reducer, the validator comparison, the one-hack session that owns
// both, the evidence schedule, the command screen watch and the summary.
// Each mirrors its Swift oracle in Sources/GlyphRecognition rule for rule;
// see glyph_logic_results.h.

#include "glyph_logic_results.h"
#include "logic_text_internal.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

// Swift never fuses a multiply and an add; neither may this file, or a band
// edge could fall on the other side.
#pragma clang fp contract(off)

namespace {

using std::optional;
using std::string;
using std::vector;

constexpr double kInfinity = std::numeric_limits<double>::infinity();
// Bounds on what a caller may pass, far above anything the app produces
// (five slots, a few dozen OCR lines), so a corrupt count is refused rather
// than allocated.
constexpr int64_t kMaxSlots = 4096;

// ---------------------------------------------------------------------------
// Strings

bool validString(gc_string text) { return text.length <= 0 || text.bytes != nullptr; }

string toString(gc_string text) {
    if (text.length <= 0 || text.bytes == nullptr) return string();
    return string(text.bytes, static_cast<size_t>(text.length));
}

gc_string view(const string &text) { return gc_string{text.data(), static_cast<int32_t>(text.size())}; }

gl_result_opt_string viewOptional(const optional<string> &text) {
    if (!text) return gl_result_opt_string{false, gc_string{nullptr, 0}};
    return gl_result_opt_string{true, view(*text)};
}

bool readOptionalString(const gl_result_opt_string &text, optional<string> &out) {
    if (!text.has) { out.reset(); return true; }
    if (!validString(text.value)) return false;
    out = toString(text.value);
    return true;
}

/// `GameText.normalized(_:)` through the shared C implementation.
string normalized(const string &text) {
    char stack[256];
    gc_string input = view(text);
    int32_t length = gc_normalize(input, stack, static_cast<int32_t>(sizeof stack));
    if (length <= 0) return string();
    if (length <= static_cast<int32_t>(sizeof stack)) return string(stack, static_cast<size_t>(length));
    string result(static_cast<size_t>(length), '\0');
    int32_t written = gc_normalize(input, &result[0], length);
    result.resize(static_cast<size_t>(std::max<int32_t>(0, std::min(written, length))));
    return result;
}

/// Decodes UTF-8 into scalars. Swift strings are valid UTF-8; an invalid
/// byte becomes U+FFFD, as `String(decoding:as:)` makes it.
vector<uint32_t> scalars(const string &text) {
    vector<uint32_t> result;
    result.reserve(text.size());
    const auto *bytes = reinterpret_cast<const unsigned char *>(text.data());
    size_t index = 0, count = text.size();
    while (index < count) {
        unsigned char lead = bytes[index];
        uint32_t scalar = 0xFFFD;
        size_t length = 1;
        auto continuation = [&](size_t offset) {
            return index + offset < count && (bytes[index + offset] & 0xC0) == 0x80;
        };
        if (lead < 0x80) {
            scalar = lead;
        } else if (lead >= 0xC2 && lead <= 0xDF && continuation(1)) {
            scalar = ((lead & 0x1Fu) << 6) | (bytes[index + 1] & 0x3Fu);
            length = 2;
        } else if (lead >= 0xE0 && lead <= 0xEF && continuation(1) && continuation(2)) {
            uint32_t value = ((lead & 0x0Fu) << 12) | ((bytes[index + 1] & 0x3Fu) << 6) | (bytes[index + 2] & 0x3Fu);
            if (value >= 0x800 && (value < 0xD800 || value > 0xDFFF)) { scalar = value; length = 3; }
        } else if (lead >= 0xF0 && lead <= 0xF4 && continuation(1) && continuation(2) && continuation(3)) {
            uint32_t value = ((lead & 0x07u) << 18) | ((bytes[index + 1] & 0x3Fu) << 12)
                | ((bytes[index + 2] & 0x3Fu) << 6) | (bytes[index + 3] & 0x3Fu);
            if (value >= 0x10000 && value <= 0x10FFFF) { scalar = value; length = 4; }
        }
        result.push_back(scalar);
        index += length;
    }
    return result;
}

/// Unicode's White_Space property, which `Character.isWhitespace` reads
/// from a character's first scalar.
bool isWhitespace(uint32_t scalar) {
    return (scalar >= 0x09 && scalar <= 0x0D) || scalar == 0x20 || scalar == 0x85 || scalar == 0xA0
        || scalar == 0x1680 || (scalar >= 0x2000 && scalar <= 0x200A) || scalar == 0x2028 || scalar == 0x2029
        || scalar == 0x202F || scalar == 0x205F || scalar == 0x3000;
}

/// The value of a percentage line: ASCII digits then "%" or "％", spaces
/// ignored, at most 999. `ResultTextParser.read`'s `percentage(in:)`.
optional<int64_t> percentValue(const string &text) {
    vector<uint32_t> kept;
    for (uint32_t scalar : scalars(text)) {
        if (!isWhitespace(scalar)) kept.push_back(scalar);
    }
    if (kept.empty() || (kept.back() != '%' && kept.back() != 0xFF05)) return std::nullopt;
    kept.pop_back();
    if (kept.empty()) return std::nullopt;
    int64_t value = 0;
    for (uint32_t scalar : kept) {
        if (scalar < '0' || scalar > '9') return std::nullopt;
        int64_t digit = static_cast<int64_t>(scalar - '0');
        // `Int(_:)` fails on overflow; the line is then no value.
        if (value > (std::numeric_limits<int64_t>::max() - digit) / 10) return std::nullopt;
        value = value * 10 + digit;
    }
    if (value > 999) return std::nullopt;
    return value;
}

optional<gc_language> languageForCode(const string &code) {
    if (code == "en") return GC_LANGUAGE_ENGLISH;
    if (code == "zh-Hans") return GC_LANGUAGE_SIMPLIFIED_CHINESE;
    if (code == "zh-Hant") return GC_LANGUAGE_TRADITIONAL_CHINESE;
    if (code == "ja") return GC_LANGUAGE_JAPANESE;
    if (code == "ko") return GC_LANGUAGE_KOREAN;
    return std::nullopt;
}

// ---------------------------------------------------------------------------
// Values

struct Selection {
    gl_result_selection_status status = GL_RESULT_SELECTION_NO_COMMAND_OBSERVED;
    gl_result_command lastObserved = GL_RESULT_COMMAND_NONE;
    int64_t samples = 0;
    optional<string> language;

    bool operator==(const Selection &other) const {
        return status == other.status && lastObserved == other.lastObserved && samples == other.samples
            && language == other.language;
    }
};

struct Commands {
    Selection presentation;
    Selection gear;
    gl_result_command_mode mode = GL_RESULT_COMMAND_MODE_UNKNOWN;

    bool operator==(const Commands &other) const {
        return presentation == other.presentation && gear == other.gear && mode == other.mode;
    }
};

struct Context {
    uint64_t sessionID = 0;
    int64_t hackID = 0;
    vector<optional<string>> glyphs;
    optional<Commands> commands;

    bool operator==(const Context &other) const {
        return sessionID == other.sessionID && hackID == other.hackID && glyphs == other.glyphs
            && commands == other.commands;
    }
    bool operator!=(const Context &other) const { return !(*this == other); }
};

struct Line {
    string text;
    double confidence = 0, x = 0, y = 0, width = 0, height = 0;
};

struct Evidence {
    Context context;
    double sourceTime = 0;
    bool panelPresent = false;
    optional<int64_t> stageIndex, hackingBonus, speedBonus;
    vector<gl_result_appearance> appearances;
    vector<Line> lines;
    optional<gc_language> labelLanguage;
};

struct Hack {
    Context context;
    gl_result_state state = GL_RESULT_STATE_AWAITING;
    optional<double> firstPanelTime, lastPanelTime, finalStageTime;
    optional<int64_t> observedHackingBonus, observedSpeedBonus, finalHackingBonus, finalSpeedBonus;
    vector<gl_result_outcome> outcomes;
    vector<optional<double>> outcomeTimes;
    optional<double> closedAt;
    optional<string> closeReason;
    optional<double> inputStartedAt, inputEndedAt;

    /// `HackResult.inputSeconds`.
    optional<double> inputSeconds() const {
        if (!firstPanelTime || !inputStartedAt || !inputEndedAt) return std::nullopt;
        double start = *inputStartedAt, end = *inputEndedAt;
        if (!(end > start) || !(end - start < 120)) return std::nullopt;
        return end - start;
    }

    bool operator==(const Hack &other) const {
        return context == other.context && state == other.state && firstPanelTime == other.firstPanelTime
            && lastPanelTime == other.lastPanelTime && finalStageTime == other.finalStageTime
            && observedHackingBonus == other.observedHackingBonus
            && observedSpeedBonus == other.observedSpeedBonus && finalHackingBonus == other.finalHackingBonus
            && finalSpeedBonus == other.finalSpeedBonus && outcomes == other.outcomes
            && outcomeTimes == other.outcomeTimes && closedAt == other.closedAt
            && closeReason == other.closeReason && inputStartedAt == other.inputStartedAt
            && inputEndedAt == other.inputEndedAt;
    }
    bool operator!=(const Hack &other) const { return !(*this == other); }
};

optional<double> readOptionalDouble(gc_opt_double value) {
    return value.has ? optional<double>(value.value) : std::nullopt;
}
optional<int64_t> readOptionalInt(gl_result_opt_int value) {
    return value.has ? optional<int64_t>(value.value) : std::nullopt;
}
gc_opt_double emitOptional(const optional<double> &value) { return gc_opt_double{value.has_value(), value.value_or(0)}; }
gl_result_opt_int emitOptional(const optional<int64_t> &value) {
    return gl_result_opt_int{value.has_value(), value.value_or(0)};
}

bool readSelection(const gl_result_command_selection &in, Selection &out) {
    if (static_cast<int>(in.status) < 0 || static_cast<int>(in.status) > GL_RESULT_SELECTION_NOT_APPLICABLE) return false;
    if (static_cast<int>(in.lastObserved) < 0 || static_cast<int>(in.lastObserved) > GL_RESULT_COMMAND_KEYS_ONLY) return false;
    out.status = in.status;
    out.lastObserved = in.lastObserved;
    out.samples = in.samples;
    return readOptionalString(in.language, out.language);
}

bool readCommands(const gl_result_commands &in, Commands &out) {
    if (static_cast<int>(in.mode) < 0 || static_cast<int>(in.mode) > GL_RESULT_COMMAND_MODE_DRONE) return false;
    out.mode = in.mode;
    return readSelection(in.presentation, out.presentation) && readSelection(in.gear, out.gear);
}

gl_result_command_selection emitSelection(const Selection &selection) {
    return gl_result_command_selection{selection.status, selection.lastObserved, selection.samples,
                                       viewOptional(selection.language)};
}

gl_result_commands emitCommands(const Commands &commands) {
    return gl_result_commands{emitSelection(commands.presentation), emitSelection(commands.gear), commands.mode};
}

bool readContext(const gl_result_context *in, Context &out) {
    if (in == nullptr || in->glyphCount < 0 || in->glyphCount > kMaxSlots || (in->glyphCount > 0 && in->glyphs == nullptr)) {
        return false;
    }
    Context context;
    context.sessionID = in->sessionID;
    context.hackID = in->hackID;
    context.glyphs.resize(static_cast<size_t>(in->glyphCount));
    for (int32_t index = 0; index < in->glyphCount; index++) {
        if (!readOptionalString(in->glyphs[index], context.glyphs[static_cast<size_t>(index)])) return false;
    }
    if (in->hasCommands) {
        Commands commands;
        if (!readCommands(in->commands, commands)) return false;
        context.commands = std::move(commands);
    }
    out = std::move(context);
    return true;
}

bool validAppearance(gl_result_appearance appearance) {
    return static_cast<int>(appearance) >= 0 && static_cast<int>(appearance) <= GL_RESULT_APPEARANCE_UNREADABLE;
}
bool validOutcome(gl_result_outcome outcome) {
    return static_cast<int>(outcome) >= 0 && static_cast<int>(outcome) <= GL_RESULT_OUTCOME_UNKNOWN;
}

bool readLines(const gl_result_line *lines, int32_t count, vector<Line> &out) {
    if (count < 0 || (count > 0 && lines == nullptr)) return false;
    vector<Line> result(static_cast<size_t>(count));
    for (int32_t index = 0; index < count; index++) {
        const gl_result_line &line = lines[index];
        if (!validString(line.text)) return false;
        result[static_cast<size_t>(index)] = Line{toString(line.text), line.confidence, line.x, line.y,
                                                  line.width, line.height};
    }
    out = std::move(result);
    return true;
}

bool readAppearances(const gl_result_appearance *appearances, int32_t count, vector<gl_result_appearance> &out) {
    if (count < 0 || (count > 0 && appearances == nullptr)) return false;
    vector<gl_result_appearance> result(appearances, appearances + count);
    for (gl_result_appearance appearance : result) {
        if (!validAppearance(appearance)) return false;
    }
    out = std::move(result);
    return true;
}

bool readEvidence(const gl_result_evidence *in, Evidence &out) {
    if (in == nullptr) return false;
    Evidence evidence;
    if (!readContext(&in->context, evidence.context)) return false;
    evidence.sourceTime = in->sourceTime;
    evidence.panelPresent = in->panelPresent;
    evidence.stageIndex = readOptionalInt(in->stageIndex);
    evidence.hackingBonus = readOptionalInt(in->hackingBonus);
    evidence.speedBonus = readOptionalInt(in->speedBonus);
    if (!readAppearances(in->appearances, in->appearanceCount, evidence.appearances)) return false;
    if (!readLines(in->lines, in->lineCount, evidence.lines)) return false;
    if (in->hasLabelLanguage) {
        if (static_cast<int>(in->labelLanguage) < 0 || static_cast<int>(in->labelLanguage) > GC_LANGUAGE_KOREAN) return false;
        evidence.labelLanguage = in->labelLanguage;
    }
    out = std::move(evidence);
    return true;
}

bool readHack(const gl_result_hack *in, Hack &out) {
    if (in == nullptr || in->outcomeCount < 0 || in->outcomeCount > kMaxSlots
        || (in->outcomeCount > 0 && (in->outcomes == nullptr || in->outcomeTimes == nullptr))) {
        return false;
    }
    if (static_cast<int>(in->state) < 0 || static_cast<int>(in->state) > GL_RESULT_STATE_NOT_OBSERVED) return false;
    Hack hack;
    if (!readContext(&in->context, hack.context)) return false;
    hack.state = in->state;
    hack.firstPanelTime = readOptionalDouble(in->firstPanelTime);
    hack.lastPanelTime = readOptionalDouble(in->lastPanelTime);
    hack.finalStageTime = readOptionalDouble(in->finalStageTime);
    hack.observedHackingBonus = readOptionalInt(in->observedHackingBonus);
    hack.observedSpeedBonus = readOptionalInt(in->observedSpeedBonus);
    hack.finalHackingBonus = readOptionalInt(in->finalHackingBonus);
    hack.finalSpeedBonus = readOptionalInt(in->finalSpeedBonus);
    for (int32_t index = 0; index < in->outcomeCount; index++) {
        if (!validOutcome(in->outcomes[index])) return false;
        hack.outcomes.push_back(in->outcomes[index]);
        hack.outcomeTimes.push_back(readOptionalDouble(in->outcomeTimes[index]));
    }
    hack.closedAt = readOptionalDouble(in->closedAt);
    if (!readOptionalString(in->closeReason, hack.closeReason)) return false;
    hack.inputStartedAt = readOptionalDouble(in->inputStartedAt);
    hack.inputEndedAt = readOptionalDouble(in->inputEndedAt);
    out = std::move(hack);
    return true;
}

// Output buffers, kept by a handle until its next call.

struct ContextOut {
    vector<gl_result_opt_string> glyphs;

    gl_result_context emit(const Context &context) {
        glyphs.clear();
        for (const auto &glyph : context.glyphs) glyphs.push_back(viewOptional(glyph));
        gl_result_context out{};
        out.sessionID = context.sessionID;
        out.hackID = context.hackID;
        out.glyphs = glyphs.empty() ? nullptr : glyphs.data();
        out.glyphCount = static_cast<int32_t>(glyphs.size());
        out.hasCommands = context.commands.has_value();
        if (context.commands) out.commands = emitCommands(*context.commands);
        return out;
    }
};

struct HackOut {
    ContextOut context;
    vector<gl_result_outcome> outcomes;
    vector<gc_opt_double> outcomeTimes;

    gl_result_hack emit(const Hack &hack) {
        outcomes = hack.outcomes;
        outcomeTimes.clear();
        for (const auto &time : hack.outcomeTimes) outcomeTimes.push_back(emitOptional(time));
        gl_result_hack out{};
        out.context = context.emit(hack.context);
        out.state = hack.state;
        out.firstPanelTime = emitOptional(hack.firstPanelTime);
        out.lastPanelTime = emitOptional(hack.lastPanelTime);
        out.finalStageTime = emitOptional(hack.finalStageTime);
        out.observedHackingBonus = emitOptional(hack.observedHackingBonus);
        out.observedSpeedBonus = emitOptional(hack.observedSpeedBonus);
        out.finalHackingBonus = emitOptional(hack.finalHackingBonus);
        out.finalSpeedBonus = emitOptional(hack.finalSpeedBonus);
        out.outcomes = outcomes.empty() ? nullptr : outcomes.data();
        out.outcomeTimes = outcomeTimes.empty() ? nullptr : outcomeTimes.data();
        out.outcomeCount = static_cast<int32_t>(outcomes.size());
        out.closedAt = emitOptional(hack.closedAt);
        out.closeReason = viewOptional(hack.closeReason);
        out.inputStartedAt = emitOptional(hack.inputStartedAt);
        out.inputEndedAt = emitOptional(hack.inputEndedAt);
        out.inputSeconds = emitOptional(hack.inputSeconds());
        return out;
    }
};

// ---------------------------------------------------------------------------
// HackResultTracker

template <typename Value> struct Run {
    optional<Value> value;
    double first = 0;
    double last = 0;
    int64_t count = 0;

    bool accept(const optional<Value> &next, double time, const gl_result_tracker_policy &policy) {
        if (!next) { *this = Run(); return false; }
        if (value != next || time - last > policy.maximumReadingGap + 1e-9) {
            value = next; first = time; count = 0;
        }
        last = time; count += 1;
        return count >= 2 && time - first + 1e-9 >= policy.minimumSpan;
    }
};

gl_result_tracker_policy defaultPolicy() { return gl_result_tracker_policy{0.1, 0.3, 0.2, 5.0}; }

struct Tracker {
    gl_result_tracker_policy policy;
    Hack result;
    int64_t revision = 0;
    double previousTime = -kInfinity;
    Run<int64_t> stage, hacking, speed;
    vector<Run<gl_result_appearance>> slots;
    std::set<size_t> conflictedSlots;
    optional<double> absentSince, exitSince;

    Tracker(Context context, gl_result_tracker_policy policy) : policy(policy) {
        size_t count = context.glyphs.size();
        result.context = std::move(context);
        result.outcomes.assign(count, GL_RESULT_OUTCOME_UNKNOWN);
        result.outcomeTimes.assign(count, std::nullopt);
        slots.assign(count, Run<gl_result_appearance>());
    }

    bool accept(const Evidence &evidence) {
        if (result.closedAt || evidence.context != result.context || !std::isfinite(evidence.sourceTime)
            || !(evidence.sourceTime > previousTime)) {
            return false;
        }
        Hack before = result;
        double time = evidence.sourceTime;
        previousTime = time;
        if (!evidence.panelPresent) {
            stage = Run<int64_t>(); hacking = Run<int64_t>(); speed = Run<int64_t>();
            slots.assign(slots.size(), Run<gl_result_appearance>());
            return false;
        }
        if (!result.firstPanelTime) result.firstPanelTime = time;
        result.lastPanelTime = time;
        absentSince.reset();
        if (evidence.hackingBonus) result.observedHackingBonus = evidence.hackingBonus;
        if (evidence.speedBonus) result.observedSpeedBonus = evidence.speedBonus;

        for (size_t index = 0; index < slots.size(); index++) {
            if (conflictedSlots.count(index)) continue;
            gl_result_appearance appearance = index < evidence.appearances.size()
                ? evidence.appearances[index] : GL_RESULT_APPEARANCE_UNREADABLE;
            optional<gl_result_appearance> known;
            if (appearance != GL_RESULT_APPEARANCE_UNREADABLE) known = appearance;
            if (slots[index].accept(known, time, policy) && known) {
                gl_result_outcome outcome = *known == GL_RESULT_APPEARANCE_GOLD
                    ? GL_RESULT_OUTCOME_ACCEPTED : GL_RESULT_OUTCOME_REJECTED;
                // Contradiction is uncertainty, not permission to overwrite a result.
                if (result.outcomes[index] != GL_RESULT_OUTCOME_UNKNOWN && result.outcomes[index] != outcome) {
                    conflictedSlots.insert(index);
                    result.outcomes[index] = GL_RESULT_OUTCOME_UNKNOWN;
                    result.outcomeTimes[index].reset();
                } else {
                    result.outcomes[index] = outcome;
                    if (!result.outcomeTimes[index]) result.outcomeTimes[index] = time;
                }
            }
        }

        int64_t finalIndex = static_cast<int64_t>(result.context.glyphs.size()) - 1;
        optional<int64_t> namedStage;
        if (evidence.stageIndex && *evidence.stageIndex >= 0
            && *evidence.stageIndex <= std::max<int64_t>(0, finalIndex)) {
            namedStage = evidence.stageIndex;
        }
        // A lit last contour reveals the final stage as its name does; a name
        // for an earlier slot contradicts it, so neither counts.
        bool finalRevealed = finalIndex >= 0 && finalIndex < static_cast<int64_t>(evidence.appearances.size())
            && evidence.appearances[static_cast<size_t>(finalIndex)] != GL_RESULT_APPEARANCE_UNREADABLE;
        optional<int64_t> validStage;
        if (finalRevealed) {
            if (!namedStage || *namedStage == finalIndex) validStage = finalIndex;
        } else {
            validStage = namedStage;
        }
        if ((stage.value != validStage || time - stage.last > policy.maximumReadingGap + 1e-9)
            && (!result.finalHackingBonus || !result.finalSpeedBonus)) {
            result.finalStageTime.reset();
        }
        bool stageAgrees = stage.accept(validStage, time, policy);
        bool atFinal = validStage && *validStage == finalIndex;
        bool finalStageConfirmed = stageAgrees && atFinal;
        if (finalStageConfirmed && !result.finalStageTime) result.finalStageTime = stage.first;
        if (atFinal) {
            if (evidence.hackingBonus && result.finalHackingBonus && *evidence.hackingBonus != *result.finalHackingBonus) {
                result.finalHackingBonus.reset();
            }
            if (evidence.speedBonus && result.finalSpeedBonus && *evidence.speedBonus != *result.finalSpeedBonus) {
                result.finalSpeedBonus.reset();
            }
            bool hackingAgrees = hacking.accept(evidence.hackingBonus, time, policy);
            bool speedAgrees = speed.accept(evidence.speedBonus, time, policy);
            if (finalStageConfirmed && hackingAgrees) result.finalHackingBonus = evidence.hackingBonus;
            if (finalStageConfirmed && speedAgrees) result.finalSpeedBonus = evidence.speedBonus;
        } else {
            hacking = Run<int64_t>(); speed = Run<int64_t>();
        }
        updateState();
        if (result != before) { revision += 1; return true; }
        return false;
    }

    void observeFrame(double time, bool inputVisible, bool exitVisible, bool panelCandidate) {
        if (!std::isfinite(time) || result.closedAt) return;
        if (inputVisible && !result.firstPanelTime) {
            if (!result.inputStartedAt) result.inputStartedAt = time;
            result.inputEndedAt = time;
        }
        if (inputVisible) {
            exitSince.reset();
        } else if (exitVisible || panelCandidate) {
            if (!exitSince) exitSince = time;
        }
        if (panelCandidate) {
            absentSince.reset();
        } else if (result.lastPanelTime && time > *result.lastPanelTime) {
            if (!absentSince) absentSince = time;
            if (time - *absentSince >= policy.panelExitSpan) finish(time, "panelLeft");
        }
        if (exitSince) {
            double since = *exitSince;
            double lastPanel = result.lastPanelTime.value_or(since);
            // Swift's max(x, y) is y >= x ? y : x.
            double start = lastPanel >= since ? lastPanel : since;
            if (time - start > policy.resultWait) finish(time, "resultTimeout");
        }
    }

    void finish(double time, const string &reason) {
        if (result.closedAt) return;
        result.closedAt = time;
        result.closeReason = reason;
        updateState();
        revision += 1;
    }

    void updateState() {
        if (!result.firstPanelTime) {
            result.state = result.closedAt ? GL_RESULT_STATE_NOT_OBSERVED : GL_RESULT_STATE_AWAITING;
        } else {
            bool anyUnknown = std::find(result.outcomes.begin(), result.outcomes.end(), GL_RESULT_OUTCOME_UNKNOWN)
                != result.outcomes.end();
            result.state = result.finalHackingBonus && result.finalSpeedBonus && !anyUnknown
                ? GL_RESULT_STATE_COMPLETE : GL_RESULT_STATE_PARTIAL;
        }
    }
};

// ---------------------------------------------------------------------------
// ValidatorResultComparison

struct Frame {
    uint64_t sessionID = 0;
    double time = 0;
    bool hasHeader = false;
    gl_result_phase headerPhase = GL_RESULT_PHASE_UNKNOWN;
    double headerSourceTime = 0;
    bool hasSlots = false;
    int64_t slotCount = 0;
    optional<int64_t> highlightedIndex;
    gl_result_rejection slotRejection = GL_RESULT_REJECTION_NONE;
    bool hasInputTimerBar = false;
};

bool readFrame(const gl_result_frame *in, Frame &out) {
    if (in == nullptr) return false;
    if (static_cast<int>(in->headerPhase) < 0 || static_cast<int>(in->headerPhase) > GL_RESULT_PHASE_COMPLETED) return false;
    if (static_cast<int>(in->slotRejection) < 0
        || static_cast<int>(in->slotRejection) > GL_RESULT_REJECTION_COVERED_BY_OVERLAY) {
        return false;
    }
    out.sessionID = in->sessionID;
    out.time = in->time;
    out.hasHeader = in->hasHeader;
    out.headerPhase = in->headerPhase;
    out.headerSourceTime = in->headerSourceTime;
    out.hasSlots = in->hasSlots;
    out.slotCount = in->slotCount;
    out.highlightedIndex = in->hasSlots ? readOptionalInt(in->highlightedIndex) : std::nullopt;
    out.slotRejection = in->slotRejection;
    out.hasInputTimerBar = in->hasInputTimerBar;
    return true;
}

struct CheckEvent {
    gl_result_event_kind kind = GL_RESULT_EVENT_STARTED;
    double time = 0;
    int64_t hackID = 0, slotIndex = 0, attemptID = 0;
    bool hasReason = false;
    bool hasResult = false;
    uint64_t resultSessionID = 0;
    string expectedGlyph;
    gl_result_verdict verdict = GL_RESULT_VERDICT_NONE;
    bool hasStartTime = false;
    optional<double> liftTime;
};

bool readEvents(const gl_result_check_event *events, int32_t count, vector<CheckEvent> &out) {
    if (count < 0 || (count > 0 && events == nullptr)) return false;
    vector<CheckEvent> result;
    result.reserve(static_cast<size_t>(count));
    for (int32_t index = 0; index < count; index++) {
        const gl_result_check_event &in = events[index];
        if (static_cast<int>(in.kind) < 0 || static_cast<int>(in.kind) > GL_RESULT_EVENT_UNCHECKED) return false;
        CheckEvent event;
        event.kind = in.kind;
        event.time = in.time;
        event.hackID = in.hackID;
        event.slotIndex = in.slotIndex;
        event.attemptID = in.attemptID;
        event.hasReason = in.hasReason;
        event.hasResult = in.hasResult;
        if (in.hasResult) {
            if (!validString(in.result.expectedGlyph)) return false;
            if (static_cast<int>(in.result.verdict) <= GL_RESULT_VERDICT_NONE
                || static_cast<int>(in.result.verdict) > GL_RESULT_VERDICT_UNAVAILABLE) {
                return false;
            }
            event.resultSessionID = in.result.sessionID;
            event.expectedGlyph = toString(in.result.expectedGlyph);
            event.verdict = in.result.verdict;
            event.hasStartTime = in.result.startTime.has;
            event.liftTime = readOptionalDouble(in.result.liftTime);
        }
        result.push_back(std::move(event));
    }
    out = std::move(result);
    return true;
}

struct Entry {
    int64_t slotIndex = 0;
    optional<int64_t> attemptID;
    gl_result_verdict validatorVerdict = GL_RESULT_VERDICT_NONE;
    gl_result_outcome gameOutcome = GL_RESULT_OUTCOME_UNKNOWN;
    gl_result_status status = GL_RESULT_STATUS_UNKNOWN_ASSOCIATION;
    optional<double> drawSeconds;
};

struct Comparison {
    struct Check {
        gl_result_verdict verdict;
        bool hasStartTime;
        optional<double> liftTime;
    };

    Context context;
    std::set<int64_t> supersededAttemptIDs;
    std::map<int64_t, int64_t> attempts;
    std::map<int64_t, Check> checks;
    std::map<int64_t, double> firstInk;
    optional<int64_t> highlight;
    optional<int64_t> candidate;
    int64_t candidateCount = 0;
    optional<double> lastTime;

    explicit Comparison(Context context) : context(std::move(context)) {}

    void observe(const Frame &frame, bool inputVisible) {
        if (frame.sessionID != context.sessionID || !inputVisible) return;
        if (lastTime && !(frame.time > *lastTime)) return;
        bool gap = lastTime ? frame.time - *lastTime > 0.102 : false;
        lastTime = frame.time;
        if (gap || !frame.hasSlots || frame.slotCount != static_cast<int64_t>(context.glyphs.size())
            || !frame.highlightedIndex) {
            invalidate(0); highlight.reset(); candidate.reset(); candidateCount = 0;
            return;
        }
        int64_t index = *frame.highlightedIndex;
        if (candidate == index) { candidateCount += 1; } else { candidate = index; candidateCount = 1; }
        if (!(candidateCount >= 2) || highlight == index) return;
        if (highlight) {
            int64_t old = *highlight;
            if (index < old) invalidate(index);
            else if (old < std::numeric_limits<int64_t>::max() && index > old + 1) invalidate(old);
        }
        highlight = index;
    }

    void accept(const vector<CheckEvent> &events) {
        for (const CheckEvent &event : events) {
            if (event.hackID != context.hackID) continue;
            if (event.slotIndex < 0 || event.slotIndex >= static_cast<int64_t>(context.glyphs.size())) continue;
            if (event.kind == GL_RESULT_EVENT_STARTED) {
                invalidate(event.slotIndex);
                attempts[event.slotIndex] = event.attemptID;
                if (!event.hasReason) firstInk[event.slotIndex] = event.time;
            }
            if (event.hasResult && event.resultSessionID == context.sessionID) {
                auto attempt = attempts.find(event.slotIndex);
                const auto &glyph = context.glyphs[static_cast<size_t>(event.slotIndex)];
                if (attempt != attempts.end() && attempt->second == event.attemptID && glyph
                    && *glyph == event.expectedGlyph) {
                    checks[event.slotIndex] = Check{event.verdict, event.hasStartTime, event.liftTime};
                }
            }
        }
    }

    void invalidate(int64_t from) {
        for (auto attempt = attempts.lower_bound(from); attempt != attempts.end();) {
            supersededAttemptIDs.insert(attempt->second);
            checks.erase(attempt->first);
            firstInk.erase(attempt->first);
            attempt = attempts.erase(attempt);
        }
    }

    vector<Entry> compare(const Hack &result) const {
        vector<Entry> entries;
        if (result.context != context) return entries;
        for (size_t position = 0; position < result.outcomes.size(); position++) {
            int64_t index = static_cast<int64_t>(position);
            gl_result_outcome outcome = result.outcomes[position];
            auto checkIt = checks.find(index);
            const Check *check = checkIt == checks.end() ? nullptr : &checkIt->second;
            auto attemptIt = attempts.find(index);
            gl_result_status status;
            if (outcome == GL_RESULT_OUTCOME_UNKNOWN) {
                status = GL_RESULT_STATUS_UNKNOWN_GAME_OUTCOME;
            } else if (attemptIt == attempts.end()) {
                status = GL_RESULT_STATUS_UNKNOWN_ASSOCIATION;
            } else if (check == nullptr || check->verdict == GL_RESULT_VERDICT_UNAVAILABLE) {
                status = GL_RESULT_STATUS_COVERAGE_GAP;
            } else {
                bool agrees = (outcome == GL_RESULT_OUTCOME_ACCEPTED && check->verdict == GL_RESULT_VERDICT_MATCHED)
                    || (outcome == GL_RESULT_OUTCOME_REJECTED && check->verdict == GL_RESULT_VERDICT_DIFFERS);
                status = agrees ? GL_RESULT_STATUS_AGREEMENT : GL_RESULT_STATUS_DISAGREEMENT;
            }
            optional<double> drawSeconds;
            auto ink = firstInk.find(index);
            if (check != nullptr && check->hasStartTime && ink != firstInk.end() && check->liftTime) {
                double start = ink->second, lift = *check->liftTime;
                if (lift > start && lift - start < 30) drawSeconds = lift - start;
            }
            Entry entry;
            entry.slotIndex = index;
            if (attemptIt != attempts.end()) entry.attemptID = attemptIt->second;
            entry.validatorVerdict = check ? check->verdict : GL_RESULT_VERDICT_NONE;
            entry.gameOutcome = outcome;
            entry.status = status;
            entry.drawSeconds = drawSeconds;
            entries.push_back(entry);
        }
        return entries;
    }
};

// ---------------------------------------------------------------------------
// ResultEvidenceSchedule

struct Schedule {
    optional<Context> context;
    bool detectionSaved = false;
    optional<double> firstNumeric;
    double lastSaved = -kInfinity;
    bool exhausted = false;

    gl_result_schedule_selection select(const Evidence &evidence, bool decision) {
        if (context != evidence.context) { *this = Schedule(); context = evidence.context; }
        if (!evidence.panelPresent) return GL_RESULT_SCHEDULE_NONE;
        if (!firstNumeric && (evidence.hackingBonus || evidence.speedBonus)) firstNumeric = evidence.sourceTime;
        if (decision) { lastSaved = evidence.sourceTime; return GL_RESULT_SCHEDULE_DECISION; }
        if (!detectionSaved) { detectionSaved = true; lastSaved = evidence.sourceTime; return GL_RESULT_SCHEDULE_DETECTION; }
        if (!firstNumeric) return GL_RESULT_SCHEDULE_NONE;
        if (evidence.sourceTime - *firstNumeric > 2.5) {
            if (exhausted) return GL_RESULT_SCHEDULE_NONE;
            exhausted = true;
            return GL_RESULT_SCHEDULE_BUDGET_EXHAUSTED;
        }
        if (!(evidence.sourceTime - lastSaved >= 0.198)) return GL_RESULT_SCHEDULE_NONE;
        lastSaved = evidence.sourceTime;
        return GL_RESULT_SCHEDULE_ANIMATION;
    }
};

}  // namespace

// ---------------------------------------------------------------------------
// Handles

struct gl_result_parser {
    gc_language language;
    struct Table {
        string code;
        string hackingLabel;
        string speedLabel;
    };
    vector<Table> tables;
    Evidence evidence;
    ContextOut contextOut;
    vector<gl_result_line> linesOut;

    bool isHackingLabel(const string &key) const {
        return std::any_of(tables.begin(), tables.end(), [&](const Table &table) { return table.hackingLabel == key; });
    }
    bool isSpeedLabel(const string &key) const {
        return std::any_of(tables.begin(), tables.end(), [&](const Table &table) { return table.speedLabel == key; });
    }
    optional<gc_language> hackingLabelLanguage(const string &key) const {
        for (const Table &table : tables) {
            if (table.hackingLabel == key) return languageForCode(table.code);
        }
        return std::nullopt;
    }
};

struct gl_result_tracker {
    std::shared_ptr<Tracker> state;
    HackOut out;

    Tracker &mutableState() {
        if (state.use_count() > 1) state = std::make_shared<Tracker>(*state);
        return *state;
    }
};

struct gl_result_comparison {
    std::shared_ptr<Comparison> state;
    vector<gl_result_entry> entries;
    vector<int64_t> superseded;

    Comparison &mutableState() {
        if (state.use_count() > 1) state = std::make_shared<Comparison>(*state);
        return *state;
    }
};

struct gl_result_session {
    vector<string> glyphNames;
    // Shared with the values `create_from_session` hands out, and copied
    // before any change while shared, so each keeps the value it was given.
    std::shared_ptr<Tracker> tracker;
    std::shared_ptr<Comparison> comparison;
    optional<Hack> retired;
    HackOut retiredOut;
    ContextOut contextOut;

    Tracker &mutableTracker() {
        if (tracker.use_count() > 1) tracker = std::make_shared<Tracker>(*tracker);
        return *tracker;
    }
    Comparison &mutableComparison() {
        if (comparison.use_count() > 1) comparison = std::make_shared<Comparison>(*comparison);
        return *comparison;
    }
};

struct gl_result_schedule {
    Schedule state;
};

struct gl_command_watch {
    double flicker = 0.5;
    double leave = 2.0;
    bool watching = false;
    optional<double> calibratedAt;
    optional<double> lostAt;
};

// ---------------------------------------------------------------------------
// ResultTextParser

gl_result_parser *gl_result_parser_create(gc_language language, const gl_result_text_table *tables, int32_t tableCount) {
    if (static_cast<int>(language) < 0 || static_cast<int>(language) > GC_LANGUAGE_KOREAN) return nullptr;
    if (tableCount < 0 || (tableCount > 0 && tables == nullptr)) return nullptr;
    auto *parser = new gl_result_parser();
    parser->language = language;
    for (int32_t index = 0; index < tableCount; index++) {
        const gl_result_text_table &table = tables[index];
        if (!validString(table.code) || !validString(table.hackingLabel) || !validString(table.speedLabel)) {
            delete parser;
            return nullptr;
        }
        parser->tables.push_back({toString(table.code), toString(table.hackingLabel), toString(table.speedLabel)});
    }
    return parser;
}

void gl_result_parser_destroy(gl_result_parser *parser) { delete parser; }

bool gl_result_parser_read(gl_result_parser *parser, const gl_result_line *lines, int32_t lineCount,
                           const gl_result_context *context, double time, const gl_result_appearance *appearances,
                           int32_t appearanceCount, gl_result_evidence *out) {
    if (parser == nullptr || out == nullptr) return false;
    Evidence evidence;
    vector<gl_result_appearance> appearanceList;
    if (!readContext(context, evidence.context) || !readLines(lines, lineCount, evidence.lines)
        || !readAppearances(appearances, appearanceCount, appearanceList)) {
        return false;
    }
    // `GameLanguage.confidence.line`.
    double floor = parser->language == GC_LANGUAGE_ENGLISH ? 0.5 : 0.3;
    vector<const Line *> reliable;
    for (const Line &line : evidence.lines) {
        if (line.confidence >= floor) reliable.push_back(&line);
    }
    auto inBand = [](const Line &line, double low, double high) {
        double centre = line.y + line.height / 2;
        return low <= centre && centre <= high && line.x >= 0.06 && line.x + line.width <= 0.95;
    };
    vector<const Line *> hackingLines;
    for (const Line *line : reliable) {
        if (inBand(*line, 0.30, 0.37) && parser->isHackingLabel(normalized(line->text))) hackingLines.push_back(line);
    }
    bool hackingLabel = !hackingLines.empty();
    bool speedLabel = std::any_of(reliable.begin(), reliable.end(), [&](const Line *line) {
        return inBand(*line, 0.46, 0.53) && parser->isSpeedLabel(normalized(line->text));
    });
    bool present = hackingLabel && speedLabel;
    auto percentage = [&](double low, double high) -> optional<int64_t> {
        std::set<int64_t> unique;
        for (const Line *line : reliable) {
            if (!inBand(*line, low, high)) continue;
            if (auto value = percentValue(line->text)) unique.insert(*value);
        }
        return unique.size() == 1 ? optional<int64_t>(*unique.begin()) : std::nullopt;
    };
    vector<string> names;
    for (const Line *line : reliable) {
        if (inBand(*line, 0.18, 0.24)) names.push_back(normalized(line->text));
    }
    vector<int64_t> indices;
    for (size_t index = 0; index < evidence.context.glyphs.size(); index++) {
        const auto &glyph = evidence.context.glyphs[index];
        if (!glyph) continue;
        string key = normalized(*glyph);
        if (std::find(names.begin(), names.end(), key) != names.end()) indices.push_back(static_cast<int64_t>(index));
    }
    // Repeated names cannot identify their animation stage on their own.
    optional<int64_t> stage = indices.size() == 1 ? optional<int64_t>(indices.front()) : std::nullopt;

    evidence.sourceTime = time;
    evidence.panelPresent = present;
    if (present) {
        evidence.stageIndex = stage;
        evidence.hackingBonus = percentage(0.375, 0.445);
        evidence.speedBonus = percentage(0.535, 0.605);
        evidence.appearances = std::move(appearanceList);
        for (const Line *line : hackingLines) {
            if (auto language = parser->hackingLabelLanguage(normalized(line->text))) {
                evidence.labelLanguage = language;
                break;
            }
        }
    }
    parser->evidence = std::move(evidence);

    const Evidence &stored = parser->evidence;
    parser->linesOut.clear();
    for (const Line &line : stored.lines) {
        parser->linesOut.push_back(gl_result_line{view(line.text), line.confidence, line.x, line.y, line.width, line.height});
    }
    gl_result_evidence result{};
    result.context = parser->contextOut.emit(stored.context);
    result.sourceTime = stored.sourceTime;
    result.panelPresent = stored.panelPresent;
    result.stageIndex = emitOptional(stored.stageIndex);
    result.hackingBonus = emitOptional(stored.hackingBonus);
    result.speedBonus = emitOptional(stored.speedBonus);
    result.appearances = stored.appearances.empty() ? nullptr : stored.appearances.data();
    result.appearanceCount = static_cast<int32_t>(stored.appearances.size());
    result.lines = parser->linesOut.empty() ? nullptr : parser->linesOut.data();
    result.lineCount = static_cast<int32_t>(parser->linesOut.size());
    result.hasLabelLanguage = stored.labelLanguage.has_value();
    result.labelLanguage = stored.labelLanguage.value_or(GC_LANGUAGE_ENGLISH);
    *out = result;
    return true;
}

// ---------------------------------------------------------------------------
// HackResultTracker

gl_result_tracker_policy gl_result_tracker_policy_default(void) { return defaultPolicy(); }

gl_result_tracker *gl_result_tracker_create(const gl_result_context *context, const gl_result_tracker_policy *policy) {
    Context value;
    if (!readContext(context, value)) return nullptr;
    auto *tracker = new gl_result_tracker();
    tracker->state = std::make_shared<Tracker>(std::move(value), policy ? *policy : defaultPolicy());
    return tracker;
}

gl_result_tracker *gl_result_tracker_create_from_session(const gl_result_session *session) {
    if (session == nullptr || !session->tracker) return nullptr;
    auto *tracker = new gl_result_tracker();
    tracker->state = session->tracker;
    return tracker;
}

void gl_result_tracker_destroy(gl_result_tracker *tracker) { delete tracker; }

bool gl_result_tracker_accept(gl_result_tracker *tracker, const gl_result_evidence *evidence) {
    Evidence value;
    if (tracker == nullptr || !readEvidence(evidence, value)) return false;
    return tracker->mutableState().accept(value);
}

void gl_result_tracker_observe_frame(gl_result_tracker *tracker, double time, bool inputVisible, bool exitVisible,
                                     bool panelCandidate) {
    if (tracker == nullptr) return;
    tracker->mutableState().observeFrame(time, inputVisible, exitVisible, panelCandidate);
}

void gl_result_tracker_finish(gl_result_tracker *tracker, double time, gc_string reason) {
    if (tracker == nullptr || !validString(reason)) return;
    tracker->mutableState().finish(time, toString(reason));
}

bool gl_result_tracker_result(gl_result_tracker *tracker, gl_result_hack *out) {
    if (tracker == nullptr || out == nullptr) return false;
    *out = tracker->out.emit(tracker->state->result);
    return true;
}

int64_t gl_result_tracker_revision(const gl_result_tracker *tracker) {
    return tracker == nullptr ? -1 : tracker->state->revision;
}

// ---------------------------------------------------------------------------
// ValidatorResultComparison

gl_result_comparison *gl_result_comparison_create(const gl_result_context *context) {
    Context value;
    if (!readContext(context, value)) return nullptr;
    auto *comparison = new gl_result_comparison();
    comparison->state = std::make_shared<Comparison>(std::move(value));
    return comparison;
}

gl_result_comparison *gl_result_comparison_create_from_session(const gl_result_session *session) {
    if (session == nullptr || !session->comparison) return nullptr;
    auto *comparison = new gl_result_comparison();
    comparison->state = session->comparison;
    return comparison;
}

void gl_result_comparison_destroy(gl_result_comparison *comparison) { delete comparison; }

void gl_result_comparison_observe(gl_result_comparison *comparison, const gl_result_frame *frame, bool inputVisible) {
    Frame value;
    if (comparison == nullptr || !readFrame(frame, value)) return;
    comparison->mutableState().observe(value, inputVisible);
}

void gl_result_comparison_accept(gl_result_comparison *comparison, const gl_result_check_event *events, int32_t count) {
    vector<CheckEvent> values;
    if (comparison == nullptr || !readEvents(events, count, values)) return;
    comparison->mutableState().accept(values);
}

bool gl_result_comparison_compare(gl_result_comparison *comparison, const gl_result_hack *result,
                                  const gl_result_entry **entries, int32_t *count) {
    Hack hack;
    if (comparison == nullptr || entries == nullptr || count == nullptr || !readHack(result, hack)) return false;
    comparison->entries.clear();
    for (const Entry &entry : comparison->state->compare(hack)) {
        comparison->entries.push_back(gl_result_entry{entry.slotIndex, emitOptional(entry.attemptID),
                                                      entry.validatorVerdict, entry.gameOutcome, entry.status,
                                                      emitOptional(entry.drawSeconds)});
    }
    *entries = comparison->entries.empty() ? nullptr : comparison->entries.data();
    *count = static_cast<int32_t>(comparison->entries.size());
    return true;
}

bool gl_result_comparison_superseded(gl_result_comparison *comparison, const int64_t **ids, int32_t *count) {
    if (comparison == nullptr || ids == nullptr || count == nullptr) return false;
    const auto &superseded = comparison->state->supersededAttemptIDs;
    comparison->superseded.assign(superseded.begin(), superseded.end());
    *ids = comparison->superseded.empty() ? nullptr : comparison->superseded.data();
    *count = static_cast<int32_t>(comparison->superseded.size());
    return true;
}

// ---------------------------------------------------------------------------
// ResultObservationSession

gl_result_session *gl_result_session_create(const gc_string *glyphNames, int32_t glyphCount) {
    if (glyphCount < 0 || (glyphCount > 0 && glyphNames == nullptr)) return nullptr;
    auto *session = new gl_result_session();
    for (int32_t index = 0; index < glyphCount; index++) {
        if (!validString(glyphNames[index])) { delete session; return nullptr; }
        session->glyphNames.push_back(toString(glyphNames[index]));
    }
    return session;
}

gl_result_session *gl_result_session_create_copy(const gl_result_session *session) {
    if (session == nullptr) return nullptr;
    auto *copy = new gl_result_session();
    copy->glyphNames = session->glyphNames;
    copy->tracker = session->tracker;
    copy->comparison = session->comparison;
    return copy;
}

void gl_result_session_destroy(gl_result_session *session) { delete session; }

void gl_result_session_reset(gl_result_session *session) {
    if (session == nullptr) return;
    session->tracker.reset();
    session->comparison.reset();
    session->retired.reset();
}

bool gl_result_session_observe(gl_result_session *session, const gl_result_frame *frame,
                               const gl_result_presentation *presentation, bool panelCandidate, bool imageAnalyzed,
                               const gl_result_commands *commands, gl_result_hack *retired) {
    Frame evidence;
    if (session == nullptr || retired == nullptr || presentation == nullptr || !readFrame(frame, evidence)) return false;
    if (presentation->slotCount < 0 || (presentation->slotCount > 0 && presentation->slots == nullptr)) return false;
    if (static_cast<int>(presentation->state) < 0
        || static_cast<int>(presentation->state) > GL_RESULT_TRACKING_INTERRUPTED) {
        return false;
    }
    if (presentation->expectedSlotCount.has && presentation->expectedSlotCount.value > kMaxSlots) return false;
    optional<Commands> commandSummary;
    if (commands != nullptr) {
        Commands value;
        if (!readCommands(*commands, value)) return false;
        commandSummary = std::move(value);
    }

    session->retired.reset();
    if (session->tracker && session->tracker->result.context.hackID != presentation->hackID) {
        session->mutableTracker().finish(evidence.time, "newHack");
        session->retired = session->tracker->result;
        session->tracker.reset();
        session->comparison.reset();
    }
    if (!session->tracker && presentation->state == GL_RESULT_TRACKING_INPUT && presentation->expectedSlotCount.has
        && presentation->expectedSlotCount.value > 0) {
        Context context;
        context.sessionID = evidence.sessionID;
        context.hackID = presentation->hackID;
        for (int64_t index = 0; index < presentation->expectedSlotCount.value; index++) {
            optional<string> name;
            for (int32_t position = 0; position < presentation->slotCount; position++) {
                const gl_result_slot &slot = presentation->slots[position];
                if (slot.index != index) continue;
                if (slot.status == GL_RESULT_SLOT_CONFIRMED && slot.glyph >= 0
                    && slot.glyph < static_cast<int32_t>(session->glyphNames.size())) {
                    name = session->glyphNames[static_cast<size_t>(slot.glyph)];
                }
                break;
            }
            context.glyphs.push_back(std::move(name));
        }
        context.commands = commandSummary;
        session->tracker = std::make_shared<Tracker>(context, defaultPolicy());
        session->comparison = std::make_shared<Comparison>(std::move(context));
    }
    if (imageAnalyzed) {
        // Any current input cue suffices, with the presentation tracker's own
        // source-time freshness rule for the header.
        bool inputHeader = evidence.hasHeader && evidence.headerPhase == GL_RESULT_PHASE_INPUT
            && evidence.headerSourceTime <= evidence.time
            && evidence.time - evidence.headerSourceTime <= presentation->unknownPhaseGrace;
        bool inputVisible = !panelCandidate
            && (inputHeader || evidence.hasInputTimerBar || evidence.highlightedIndex.has_value());
        if (session->comparison) session->mutableComparison().observe(evidence, inputVisible);
        if (session->tracker) {
            session->mutableTracker().observeFrame(evidence.time, inputVisible,
                                                   evidence.slotRejection == GL_RESULT_REJECTION_NO_MARKERS,
                                                   panelCandidate);
        }
    }
    if (!session->retired) return false;
    *retired = session->retiredOut.emit(*session->retired);
    return true;
}

void gl_result_session_accept_evidence(gl_result_session *session, const gl_result_evidence *evidence) {
    Evidence value;
    if (session == nullptr || !session->tracker || !readEvidence(evidence, value)) return;
    session->mutableTracker().accept(value);
}

void gl_result_session_accept_events(gl_result_session *session, const gl_result_check_event *events, int32_t count) {
    vector<CheckEvent> values;
    if (session == nullptr || !session->comparison || !readEvents(events, count, values)) return;
    session->mutableComparison().accept(values);
}

void gl_result_session_finish(gl_result_session *session, double time, gc_string reason) {
    if (session == nullptr || !session->tracker || !validString(reason)) return;
    session->mutableTracker().finish(time, toString(reason));
}

bool gl_result_session_context(gl_result_session *session, gl_result_context *out) {
    if (session == nullptr || out == nullptr || !session->tracker || session->tracker->result.closedAt) return false;
    *out = session->contextOut.emit(session->tracker->result.context);
    return true;
}

// ---------------------------------------------------------------------------
// ResultEvidenceSchedule

gl_result_schedule *gl_result_schedule_create(void) { return new gl_result_schedule(); }

void gl_result_schedule_destroy(gl_result_schedule *schedule) { delete schedule; }

void gl_result_schedule_reset(gl_result_schedule *schedule) {
    if (schedule != nullptr) schedule->state = Schedule();
}

gl_result_schedule_selection gl_result_schedule_select(gl_result_schedule *schedule, const gl_result_evidence *evidence,
                                                       bool decision) {
    Evidence value;
    if (schedule == nullptr || !readEvidence(evidence, value)) return GL_RESULT_SCHEDULE_NONE;
    return schedule->state.select(value, decision);
}

// ---------------------------------------------------------------------------
// CommandScreenWatch

gl_command_watch *gl_command_watch_create(double flicker, double leave) {
    auto *watch = new gl_command_watch();
    watch->flicker = flicker;
    watch->leave = leave;
    return watch;
}

void gl_command_watch_destroy(gl_command_watch *watch) { delete watch; }

gl_command_watch_action gl_command_watch_observe(gl_command_watch *watch, double time, bool calibrated,
                                                 bool commandPhase, bool complete) {
    if (watch == nullptr) return GL_COMMAND_WATCH_ACTION_NONE;
    if (calibrated) watch->calibratedAt = time;
    bool recent = watch->calibratedAt
        ? (time >= *watch->calibratedAt && time - *watch->calibratedAt <= watch->flicker) : false;
    gl_command_watch_action action = GL_COMMAND_WATCH_ACTION_NONE;
    if (watch->watching && !recent && complete) { action = GL_COMMAND_WATCH_ACTION_INTERRUPT; watch->lostAt = time; }
    if (recent) {
        watch->lostAt.reset();
    } else if (watch->lostAt && time - *watch->lostAt >= watch->leave) {
        action = GL_COMMAND_WATCH_ACTION_CANCEL;
        watch->lostAt.reset();
    }
    watch->watching = recent && commandPhase;
    return action;
}

void gl_command_watch_stop(gl_command_watch *watch) {
    if (watch != nullptr) watch->watching = false;
}

void gl_command_watch_reset(gl_command_watch *watch) {
    if (watch == nullptr) return;
    watch->watching = false;
    watch->calibratedAt.reset();
    watch->lostAt.reset();
}

bool gl_command_watch_watching(const gl_command_watch *watch) { return watch != nullptr && watch->watching; }

// ---------------------------------------------------------------------------
// CommandPhaseContext

struct gl_command_context {
    double leave = 2.0;
    optional<double> evidenceAt;
    /// Readable header text of another phase.
    optional<double> contraryAt;
    /// A header reading that recognised nothing.
    optional<double> unreadAt;
    /// The latest notice read with a value in the open command window.
    optional<double> noticeReadAt;
};

namespace {

/// `max(value ?? time, time)`, as Swift's `max` picks: the second when equal.
void advance(optional<double> &value, double time) {
    const double base = value.value_or(time);
    value = time >= base ? time : base;
}

} // namespace

gl_command_context *gl_command_context_create(double leave) {
    auto *context = new gl_command_context();
    context->leave = leave;
    return context;
}

void gl_command_context_destroy(gl_command_context *context) { delete context; }

double gl_command_context_leave(const gl_command_context *context) { return context ? context->leave : 0; }

void gl_command_context_set_leave(gl_command_context *context, double leave) {
    if (context != nullptr) context->leave = leave;
}

bool gl_command_context_is_readable(gl_result_phase phase, gc_string matchedText) {
    if (phase != GL_RESULT_PHASE_UNKNOWN) return true;
    // `matchedText.allSatisfy(\.isWhitespace)` over Characters.
    const glyph_text::Text text(glyph_text::decode(matchedText));
    for (std::size_t index = 0; index < text.count(); ++index) {
        if (!glyph_text::isWhitespaceCharacter(text.character(index)[0])) return true;
    }
    return false;
}

void gl_command_context_header(gl_command_context *context, gl_result_phase phase, gc_string matchedText,
                               double sourceTime) {
    if (context == nullptr || !std::isfinite(sourceTime)) return;
    if (phase == GL_RESULT_PHASE_COMMAND) {
        advance(context->evidenceAt, sourceTime);
    } else if (gl_command_context_is_readable(phase, matchedText)) {
        advance(context->contraryAt, sourceTime);
    } else {
        advance(context->unreadAt, sourceTime);
    }
}

void gl_command_context_notice(gl_command_context *context, double time) {
    if (context == nullptr || !std::isfinite(time)) return;
    advance(context->evidenceAt, time);
}

void gl_command_context_notice_read(gl_command_context *context, gc_opt_double sourceTime) {
    if (context == nullptr) return;
    if (!sourceTime.has || !std::isfinite(sourceTime.value)) { context->noticeReadAt.reset(); return; }
    context->noticeReadAt = sourceTime.value;
    advance(context->evidenceAt, sourceTime.value);
}

bool gl_command_context_is_current(const gl_command_context *context, double time) {
    if (context == nullptr || !context->evidenceAt) return false;
    const double evidenceAt = *context->evidenceAt;
    if (!(time >= evidenceAt && time - evidenceAt <= context->leave)) return false;
    // Evidence on the same frame as a contrary reading is current.
    if (context->contraryAt && *context->contraryAt > evidenceAt) return false;
    if (!context->noticeReadAt && context->unreadAt && *context->unreadAt > evidenceAt) return false;
    return true;
}

void gl_command_context_reset(gl_command_context *context) {
    if (context == nullptr) return;
    context->evidenceAt.reset(); context->contraryAt.reset(); context->unreadAt.reset();
    context->noticeReadAt.reset();
}

// ---------------------------------------------------------------------------
// HackCommandSummary, HackResultSummary and its presentation

gl_result_command gl_result_command_effective(const gl_result_command_selection *selection) {
    if (selection == nullptr || selection->status != GL_RESULT_SELECTION_CONFIRMED) return GL_RESULT_COMMAND_NONE;
    return selection->lastObserved;
}

int32_t gl_result_summary_make(const gl_result_hack *result, const gl_result_entry *entries, int32_t entryCount,
                               gl_result_summary *out, gl_result_summary_slot *slots, int32_t capacity) {
    if (result == nullptr || out == nullptr || entryCount < 0 || (entryCount > 0 && entries == nullptr)
        || result->outcomeCount < 0 || (result->outcomeCount > 0 && result->outcomes == nullptr)
        || result->context.glyphCount < 0 || (result->context.glyphCount > 0 && result->context.glyphs == nullptr)) {
        return -1;
    }
    int32_t count = result->outcomeCount;
    if (count > capacity || (count > 0 && slots == nullptr)) return count;

    auto bonus = [](gl_result_opt_int final, gl_result_opt_int observed) {
        if (final.has) return gl_result_bonus{true, final.value, true};
        if (observed.has) return gl_result_bonus{true, observed.value, false};
        return gl_result_bonus{false, 0, false};
    };
    // A slot's first entry wins, as `Dictionary(uniquingKeysWith:)` keeps it.
    std::map<int64_t, const gl_result_entry *> bySlot;
    for (int32_t index = 0; index < entryCount; index++) bySlot.emplace(entries[index].slotIndex, &entries[index]);

    for (int32_t index = 0; index < count; index++) {
        auto found = bySlot.find(index);
        const gl_result_entry *entry = found == bySlot.end() ? nullptr : found->second;
        gl_result_summary_slot slot{};
        slot.glyph = index < result->context.glyphCount ? result->context.glyphs[index]
                                                        : gl_result_opt_string{false, gc_string{nullptr, 0}};
        slot.outcome = result->outcomes[index];
        slot.check = entry ? entry->validatorVerdict : GL_RESULT_VERDICT_NONE;
        slot.comparison = entry ? entry->status : GL_RESULT_STATUS_UNKNOWN_ASSOCIATION;
        slot.drawSeconds = entry ? entry->drawSeconds : gc_opt_double{false, 0};
        slots[index] = slot;
    }

    optional<double> inputSeconds;
    if (result->firstPanelTime.has && result->inputStartedAt.has && result->inputEndedAt.has) {
        double start = result->inputStartedAt.value, end = result->inputEndedAt.value;
        if (end > start && end - start < 120) inputSeconds = end - start;
    }
    gl_result_summary summary{};
    summary.captureSessionID = result->context.sessionID;
    summary.hackID = result->context.hackID;
    summary.state = result->state;
    summary.isClosed = result->closedAt.has;
    summary.closeReason = result->closeReason;
    summary.hackingBonus = bonus(result->finalHackingBonus, result->observedHackingBonus);
    summary.speedBonus = bonus(result->finalSpeedBonus, result->observedSpeedBonus);
    summary.slots = count > 0 ? slots : nullptr;
    summary.slotCount = count;
    summary.inputSeconds = emitOptional(inputSeconds);
    summary.hasCommands = result->context.hasCommands;
    summary.commands = result->context.commands;
    *out = summary;
    return count;
}

gl_result_headline gl_result_summary_headline(const gl_result_summary *summary) {
    if (summary == nullptr) return GL_RESULT_HEADLINE_AWAITING;
    switch (summary->state) {
    case GL_RESULT_STATE_AWAITING: return GL_RESULT_HEADLINE_AWAITING;
    case GL_RESULT_STATE_COMPLETE: return GL_RESULT_HEADLINE_COMPLETE;
    case GL_RESULT_STATE_PARTIAL: return GL_RESULT_HEADLINE_PARTIAL;
    case GL_RESULT_STATE_NOT_OBSERVED: break;
    }
    static const string stopped = "captureStopped";
    bool captureStopped = summary->closeReason.has && validString(summary->closeReason.value)
        && toString(summary->closeReason.value) == stopped;
    return captureStopped ? GL_RESULT_HEADLINE_STOPPED_BEFORE_RESULT : GL_RESULT_HEADLINE_NO_RESULT_SCREEN;
}

bool gl_result_summary_has_provisional_bonus(const gl_result_summary *summary) {
    if (summary == nullptr) return false;
    return (summary->hackingBonus.has && !summary->hackingBonus.isFinal)
        || (summary->speedBonus.has && !summary->speedBonus.isFinal);
}

int32_t gl_result_summary_disagreements(const gl_result_summary *summary, int32_t *slotIndices, int32_t capacity) {
    if (summary == nullptr || summary->slotCount < 0 || (summary->slotCount > 0 && summary->slots == nullptr)) return -1;
    vector<int32_t> found;
    for (int32_t index = 0; index < summary->slotCount; index++) {
        const gl_result_summary_slot &slot = summary->slots[index];
        if (slot.comparison == GL_RESULT_STATUS_DISAGREEMENT && slot.outcome != GL_RESULT_OUTCOME_UNKNOWN) {
            found.push_back(index);
        }
    }
    int32_t count = static_cast<int32_t>(found.size());
    if (count > capacity || (count > 0 && slotIndices == nullptr)) return count;
    std::copy(found.begin(), found.end(), slotIndices);
    return count;
}
