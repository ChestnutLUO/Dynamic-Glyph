// The presentation tracker, ported from PresentationTracker.swift with the
// value types of SlotObservation.swift and GamePhaseEvidence.swift. Every rule,
// threshold, order of checks and reason string follows the Swift tracker, so
// the equivalence tests can hold the two to the same events and the same
// state after every frame.
//
// Storage that changes size (slots, hypotheses, events, the strip readings
// kept as anchors) is held in member buffers whose elements are reused rather
// than destroyed, so a steady capture allocates nothing once they have grown.

#include "glyph_logic_tracker.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <utility>
#include <vector>

// Swift never fuses `a * b + c` into one rounding; keep the C++ arithmetic
// on the same path so a grid position cannot move by the last bit.
#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace {

/// `SequenceTable.maximumLength`.
constexpr int32_t kMaximumSequenceLength = 5;
constexpr int32_t kNodeCount = 11;

/// A set of undirected node pairs: bit `lower * 11 + upper`, nodes 0...10.
struct EdgeSet {
    uint64_t low = 0;
    uint64_t high = 0;

    void insert(int32_t a, int32_t b) {
        const int32_t lower = a <= b ? a : b;
        const int32_t upper = a <= b ? b : a;
        const int32_t bit = lower * kNodeCount + upper;
        if (bit < 64) {
            low |= uint64_t{1} << bit;
        } else {
            high |= uint64_t{1} << (bit - 64);
        }
    }
    int32_t count() const { return __builtin_popcountll(low) + __builtin_popcountll(high); }
    bool operator==(const EdgeSet &other) const { return low == other.low && high == other.high; }
    bool isStrictSubset(const EdgeSet &other) const {
        return (low & ~other.low) == 0 && (high & ~other.high) == 0 && !(*this == other);
    }
};

void appendInt(std::string &text, int64_t value) {
    char buffer[24];
    const int length = std::snprintf(buffer, sizeof buffer, "%lld", static_cast<long long>(value));
    text.append(buffer, static_cast<size_t>(length));
}

void appendUnsigned(std::string &text, uint64_t value) {
    char buffer[24];
    const int length = std::snprintf(buffer, sizeof buffer, "%llu", static_cast<unsigned long long>(value));
    text.append(buffer, static_cast<size_t>(length));
}

/// `Double.secondsDescription` (SecondsFormatting.swift): milliseconds rounded
/// half away from zero, as `rounded()` does. Swift traps on a value too large
/// for `Int`; here it saturates instead.
void appendSeconds(std::string &text, double seconds) {
    if (!std::isfinite(seconds)) {
        // Swift's own description of a non-finite Double.
        if (std::isnan(seconds)) {
            text.append(std::signbit(seconds) ? "-nan" : "nan");
        } else {
            text.append(seconds < 0 ? "-inf" : "inf");
        }
        text.append(" s");
        return;
    }
    const double scaled = std::round(seconds * 1000);
    int64_t milliseconds;
    if (scaled >= 9.2e18) {
        milliseconds = INT64_MAX;
    } else if (scaled <= -9.2e18) {
        milliseconds = INT64_MIN + 1;
    } else {
        milliseconds = static_cast<int64_t>(scaled);
    }
    if (milliseconds < 0) text.push_back('-');
    const uint64_t magnitude = milliseconds < 0 ? static_cast<uint64_t>(-milliseconds)
                                                : static_cast<uint64_t>(milliseconds);
    appendUnsigned(text, magnitude / 1000);
    text.push_back('.');
    const uint64_t fraction = magnitude % 1000;
    if (fraction < 100) text.push_back('0');
    if (fraction < 10) text.push_back('0');
    appendUnsigned(text, fraction);
    text.append(" s");
}

const char *stateName(gl_tracking_state state) {
    switch (state) {
    case GL_TRACKING_STATE_INACTIVE: return "inactive";
    case GL_TRACKING_STATE_COMMAND: return "command";
    case GL_TRACKING_STATE_PRESENTING: return "presenting";
    case GL_TRACKING_STATE_INPUT: return "input";
    case GL_TRACKING_STATE_COMPLETED: return "completed";
    case GL_TRACKING_STATE_INTERRUPTED: return "interrupted";
    }
    return "";
}

const char *sourceName(gl_phase_source source) {
    switch (source) {
    case GL_PHASE_SOURCE_HEADER_TEXT: return "headerText";
    case GL_PHASE_SOURCE_RETAINED: return "retained";
    case GL_PHASE_SOURCE_INPUT_TIMER: return "inputTimer";
    case GL_PHASE_SOURCE_PARTIAL_INPUT_TIMER: return "partialInputTimer";
    case GL_PHASE_SOURCE_INDICATOR_TRANSITION: return "indicatorTransition";
    case GL_PHASE_SOURCE_NONE: return "none";
    }
    return "";
}

struct OptDouble {
    bool has = false;
    double value = 0;

    void set(double v) { has = true; value = v; }
    void clear() { has = false; value = 0; }
    gc_opt_double c() const { return gc_opt_double{has, has ? value : 0}; }
    /// `Optional<Double> ==`: NaN is unequal to itself, as in Swift.
    bool operator==(const OptDouble &other) const {
        return has == other.has && (!has || value == other.value);
    }
};

struct OptInt {
    bool has = false;
    int32_t value = 0;

    void set(int32_t v) { has = true; value = v; }
    void clear() { has = false; value = 0; }
    gc_opt_int32 c() const { return gc_opt_int32{has, has ? value : 0}; }
    bool operator==(const OptInt &other) const { return has == other.has && (!has || value == other.value); }
    bool operator!=(const OptInt &other) const { return !(*this == other); }
};

/// `SlotStripReading`, kept between frames.
struct Reading {
    int32_t slotCount = 0;
    OptInt highlightedIndex;
    std::vector<double> markerCentersX;

    void assign(const Reading &other) {
        slotCount = other.slotCount;
        highlightedIndex = other.highlightedIndex;
        markerCentersX.assign(other.markerCentersX.begin(), other.markerCentersX.end());
    }
};

/// `SlotObservation`.
struct Slot {
    int32_t index = 0;
    gl_slot_status status = GL_SLOT_STATUS_PENDING;
    int32_t glyph = -1;
    std::vector<int32_t> alternatives;
    OptDouble firstSampleTime;
    OptDouble lastSampleTime;
    int64_t sampleCount = 0;
    bool hasBoundaryReason = false;
    std::string boundaryReason;

    /// `SlotObservation(index:)`, reusing this element's storage.
    void reset(int32_t newIndex) {
        index = newIndex;
        status = GL_SLOT_STATUS_PENDING;
        glyph = -1;
        alternatives.clear();
        firstSampleTime.clear();
        lastSampleTime.clear();
        sampleCount = 0;
        hasBoundaryReason = false;
        boundaryReason.clear();
    }
    void assign(const Slot &other) {
        index = other.index;
        status = other.status;
        glyph = other.glyph;
        alternatives.assign(other.alternatives.begin(), other.alternatives.end());
        firstSampleTime = other.firstSampleTime;
        lastSampleTime = other.lastSampleTime;
        sampleCount = other.sampleCount;
        hasBoundaryReason = other.hasBoundaryReason;
        boundaryReason.assign(other.boundaryReason);
    }
    void setReason(const std::string &reason) {
        hasBoundaryReason = true;
        boundaryReason.assign(reason);
    }
    void clearReason() {
        hasBoundaryReason = false;
        boundaryReason.clear();
    }
    bool isSettled() const {
        return status == GL_SLOT_STATUS_CONFIRMED || status == GL_SLOT_STATUS_INFERRED
            || status == GL_SLOT_STATUS_MISSING || status == GL_SLOT_STATUS_UNCERTAIN;
    }
    bool operator==(const Slot &other) const {
        return index == other.index && status == other.status && glyph == other.glyph
            && alternatives == other.alternatives && firstSampleTime == other.firstSampleTime
            && lastSampleTime == other.lastSampleTime && sampleCount == other.sampleCount
            && hasBoundaryReason == other.hasBoundaryReason
            && (!hasBoundaryReason || boundaryReason == other.boundaryReason);
    }
};

/// A list whose elements outlive `clear()`, so their strings and arrays keep
/// their capacity for the next use.
template <typename T>
struct ReusableList {
    std::vector<T> storage;
    size_t count = 0;

    T &append() {
        if (count == storage.size()) storage.emplace_back();
        return storage[count++];
    }
    void clear() { count = 0; }
    bool empty() const { return count == 0; }
    T &operator[](size_t index) { return storage[index]; }
    const T &operator[](size_t index) const { return storage[index]; }
};

/// `PresentationTracker.Hypothesis`. Only the first and last of its sample
/// times are ever read, and how many there are.
struct Hypothesis {
    int32_t glyph;
    EdgeSet edges;
    double firstTime;
    double lastTime;
    int64_t count;
};

struct Event {
    gl_tracking_event_kind kind = GL_TRACKING_EVENT_PHASE_CHANGED;
    double time = 0;
    int64_t hackID = 0;
    OptInt slotIndex;
    int32_t glyph = -1;
    std::string reason;
    int64_t sampleCount = 0;
};

/// `PartialSlotStripReading.resolved(slotCount:)`: the visible indicators'
/// slots into `indices` and the highlighted one's into `highlighted`; false
/// for nil.
bool resolvePartial(const gl_partial_slot_reading &reading, int32_t slotCount, int32_t *indices,
                    OptInt *highlighted) {
    const int32_t count = reading.markerCentersX != nullptr && reading.markerCount > 0 ? reading.markerCount : 0;
    if (slotCount < 1 || slotCount > kMaximumSequenceLength || count == 0 || count > slotCount) return false;
    const double midpoint = static_cast<double>(slotCount - 1) / 2;
    auto expected = [&](int32_t index) {
        return 0.5 + (static_cast<double>(index) - midpoint) * reading.centerPitch;
    };
    bool mapped[kMaximumSequenceLength] = {};
    int32_t last = -1;
    for (int32_t marker = 0; marker < count; ++marker) {
        const double center = reading.markerCentersX[marker];
        int32_t found = -1;
        for (int32_t index = 0; index < slotCount; ++index) {
            if (std::fabs(center - expected(index)) <= reading.centerTolerance) {
                found = index;
                break;
            }
        }
        if (found < 0 || found <= last) return false;
        indices[marker] = found;
        mapped[found] = true;
        last = found;
    }
    for (int32_t index = 0; index < slotCount; ++index) {
        if (mapped[index]) continue;
        const double position = expected(index);
        if (!(position >= reading.coveredFrom && position <= reading.coveredTo)) return false;
    }
    highlighted->clear();
    if (reading.highlightedMarker.has) {
        const int32_t marker = reading.highlightedMarker.value;
        if (marker < 0 || marker >= count) return false;
        highlighted->set(indices[marker]);
    }
    return true;
}

/// One frame's evidence, read once from the C struct.
struct Evidence {
    double time;
    bool hasHeader;
    gl_game_phase headerPhase;
    double headerSourceTime;
    bool hasSlots;
    Reading *reading;  // the tracker's scratch copy of the frame's strip
    gl_slot_rejection slotRejection;
    gl_shape_kind shapeKind;
    int32_t glyph;
    EdgeSet edges;
    bool hasValidCalibration;
    bool hasInputTimerBar;
    bool hasPartialSlots;
    gl_partial_slot_reading partialSlots;  // its centres are the caller's, for the call
    bool hasPartialInputTimerBar;
};

}  // namespace

struct gl_tracker {
    uint64_t sessionID;
    gl_tracking_policy policy;
    std::vector<std::string> glyphNames;

    gl_tracking_state state = GL_TRACKING_STATE_INACTIVE;
    gl_phase_source phaseSource = GL_PHASE_SOURCE_NONE;
    int64_t hackID = 0;
    ReusableList<Slot> slots;
    OptInt currentSlotIndex;
    OptInt inputSlotIndex;
    bool slotCountConflict = false;
    int64_t revision = 0;
    OptDouble lastEvidenceTime;
    OptDouble lastPhaseTime;
    bool isFrozen = false;
    bool observedPresentationForCurrentHack = false;
    OptDouble lastIndicatorTime;
    bool indicatorsObstructed = false;
    OptDouble coveredSince;

    std::vector<Hypothesis> hypotheses;
    /// `[slotCount: votes]`.
    std::vector<std::pair<int32_t, int64_t>> slotCountVotes;
    OptInt inferredFromIndex;
    OptInt nextInferredIndex;
    OptDouble blankSince;
    OptDouble lastSlotReleasedSince;
    bool hasPrelude = false;
    Reading preludeReading;
    double preludeFirstTime = 0;
    double preludeLastTime = 0;
    int64_t preludeSamples = 0;
    OptDouble inputHighlightTime;
    bool hasAnchor = false;
    Reading anchor;
    bool freshIndicatorStart = false;
    OptDouble lastStripReadingTime;
    bool stripReturnedAfterAbsence = false;

    // Per-call buffers.
    ReusableList<Event> events;
    Reading frameReading;
    std::string reasonText;
    std::string innerReason;
    std::vector<size_t> stableScratch;
    std::vector<int32_t> qualifiedScratch;
    // The display state before the frame, for the revision.
    gl_tracking_state beforeState = GL_TRACKING_STATE_INACTIVE;
    gl_phase_source beforeSource = GL_PHASE_SOURCE_NONE;
    int64_t beforeHackID = 0;
    OptInt beforeCurrent;
    OptInt beforeInput;
    bool beforeObstructed = false;
    ReusableList<Slot> beforeSlots;

    // MARK: Helpers

    bool validGlyph(int32_t glyph) const {
        return glyph >= 0 && static_cast<size_t>(glyph) < glyphNames.size();
    }

    Event &pushEvent(gl_tracking_event_kind kind, double time, OptInt slotIndex = OptInt{}, int32_t glyph = -1,
                     int64_t sampleCount = 0) {
        Event &event = events.append();
        event.kind = kind;
        event.time = time;
        event.hackID = hackID;
        event.slotIndex = slotIndex;
        event.glyph = glyph;
        event.reason.clear();
        event.sampleCount = sampleCount;
        return event;
    }

    static OptInt some(int32_t value) {
        OptInt result;
        result.set(value);
        return result;
    }

    bool isStable(const Hypothesis &hypothesis) const {
        return hypothesis.count >= policy.minimumStableSamples
            && hypothesis.lastTime - hypothesis.firstTime >= policy.minimumStableInterval;
    }

    int64_t qualifiedVoteCount(int32_t *onlyKey) const {
        int64_t qualified = 0;
        for (const auto &vote : slotCountVotes) {
            if (vote.second >= policy.slotCountVotesRequired) {
                ++qualified;
                if (onlyKey) *onlyKey = vote.first;
            }
        }
        return qualified;
    }

    OptInt expectedSlotCount() const {
        OptInt result;
        if (slotCountConflict) return result;
        int32_t only = 0;
        if (qualifiedVoteCount(&only) == 1) result.set(only);
        return result;
    }

    void snapshotDisplay() {
        beforeState = state;
        beforeSource = phaseSource;
        beforeHackID = hackID;
        beforeCurrent = currentSlotIndex;
        beforeInput = inputSlotIndex;
        beforeObstructed = indicatorsObstructed;
        beforeSlots.clear();
        for (size_t index = 0; index < slots.count; ++index) beforeSlots.append().assign(slots[index]);
    }

    bool displayChanged() const {
        if (beforeState != state || beforeSource != phaseSource || beforeHackID != hackID
            || beforeCurrent != currentSlotIndex || beforeInput != inputSlotIndex
            || beforeObstructed != indicatorsObstructed || beforeSlots.count != slots.count) {
            return true;
        }
        for (size_t index = 0; index < slots.count; ++index) {
            if (!(beforeSlots[index] == slots[index])) return true;
        }
        return false;
    }

    // MARK: Evidence

    void accept(const gl_frame_evidence &input) {
        events.clear();
        if (input.sessionID != sessionID) {
            Event &event = pushEvent(GL_TRACKING_EVENT_STALE_EVIDENCE_REJECTED, input.time);
            event.reason.assign("evidence from capture session ");
            appendUnsigned(event.reason, input.sessionID);
            return;
        }
        Evidence evidence = read(input);

        if (lastEvidenceTime.has) {
            const double last = lastEvidenceTime.value;
            if (evidence.time < last) {
                reasonText.assign("source time moved backwards");
                invalidateTentative(evidence.time, reasonText);
                state = GL_TRACKING_STATE_INTERRUPTED;
                phaseSource = GL_PHASE_SOURCE_NONE;
                lastStripReadingTime.clear();
                lastPhaseTime.clear();
            } else if (evidence.time - last > policy.maximumFrameGap) {
                reasonText.assign("frame gap of ");
                appendSeconds(reasonText, evidence.time - last);
                invalidateTentative(evidence.time, reasonText);
                state = GL_TRACKING_STATE_INTERRUPTED;
                phaseSource = GL_PHASE_SOURCE_NONE;
            }
        }
        lastEvidenceTime.set(evidence.time);
        if (evidence.hasSlots) {
            if (!lastStripReadingTime.has
                || evidence.time - lastStripReadingTime.value >= policy.minimumStripAbsenceForNewHack) {
                stripReturnedAfterAbsence = true;
            }
            lastStripReadingTime.set(evidence.time);
        }

        snapshotDisplay();
        applyPhase(evidence);
        applySlots(evidence);
        applyFallback(evidence);
        applyShape(evidence);
        if (state == GL_TRACKING_STATE_PRESENTING) stripReturnedAfterAbsence = false;
        if (!events.empty() || displayChanged()) ++revision;
    }

    Evidence read(const gl_frame_evidence &input) {
        Evidence evidence{};
        evidence.time = input.time;
        evidence.hasHeader = input.hasHeader;
        evidence.headerPhase = input.header.phase;
        evidence.headerSourceTime = input.header.sourceTime;
        evidence.hasSlots = input.hasSlots;
        evidence.reading = &frameReading;
        if (input.hasSlots) {
            const gl_slot_strip_reading &strip = input.slots;
            frameReading.slotCount = strip.slotCount;
            // A negative highlight cannot index a slot; Swift would trap on it.
            if (strip.highlightedIndex.has && strip.highlightedIndex.value >= 0) {
                frameReading.highlightedIndex.set(strip.highlightedIndex.value);
            } else {
                frameReading.highlightedIndex.clear();
            }
            if (strip.markerCentersX && strip.markerCount > 0) {
                frameReading.markerCentersX.assign(strip.markerCentersX, strip.markerCentersX + strip.markerCount);
            } else {
                frameReading.markerCentersX.clear();
            }
        }
        evidence.slotRejection = input.slotRejection;
        evidence.shapeKind = input.shape.kind;
        evidence.glyph = validGlyph(input.shape.glyph) ? input.shape.glyph : -1;
        if (input.shape.edges && input.shape.edgeCount > 0) {
            for (int32_t index = 0; index < input.shape.edgeCount; ++index) {
                const gc_edge edge = input.shape.edges[index];
                if (edge.lower < kNodeCount && edge.upper < kNodeCount) evidence.edges.insert(edge.lower, edge.upper);
            }
        }
        evidence.hasValidCalibration = input.hasValidCalibration;
        // `FrameEvidence.init`: the frame's flag or the strip's.
        evidence.hasInputTimerBar = input.hasInputTimerBar || (input.hasSlots && input.slots.hasInputTimerBar);
        evidence.hasPartialSlots = input.hasPartialSlots;
        evidence.partialSlots = input.partialSlots;
        evidence.hasPartialInputTimerBar = input.hasPartialInputTimerBar;
        return evidence;
    }

    void invalidatePhase() {
        lastPhaseTime.clear();
        if (state != GL_TRACKING_STATE_INACTIVE) state = GL_TRACKING_STATE_INTERRUPTED;
        phaseSource = GL_PHASE_SOURCE_NONE;
        ++revision;
    }

    void reset() {
        state = GL_TRACKING_STATE_INACTIVE;
        phaseSource = GL_PHASE_SOURCE_NONE;
        slots.clear();
        hypotheses.clear();
        slotCountVotes.clear();
        currentSlotIndex.clear();
        inputSlotIndex.clear();
        inputHighlightTime.clear();
        slotCountConflict = false;
        isFrozen = false;
        observedPresentationForCurrentHack = false;
        lastIndicatorTime.clear();
        indicatorsObstructed = false;
        coveredSince.clear();
        lastEvidenceTime.clear();
        lastPhaseTime.clear();
        inferredFromIndex.clear();
        nextInferredIndex.clear();
        blankSince.clear();
        lastSlotReleasedSince.clear();
        hasPrelude = false;
        hasAnchor = false;
        freshIndicatorStart = false;
        lastStripReadingTime.clear();
        stripReturnedAfterAbsence = false;
        ++revision;
    }

    // MARK: Phase

    /// `currentPhase`: false for inactive and interrupted.
    bool currentPhase(gl_game_phase *phase) const {
        switch (state) {
        case GL_TRACKING_STATE_COMMAND: *phase = GL_GAME_PHASE_COMMAND; return true;
        case GL_TRACKING_STATE_PRESENTING: *phase = GL_GAME_PHASE_PRESENTING; return true;
        case GL_TRACKING_STATE_INPUT: *phase = GL_GAME_PHASE_INPUT; return true;
        case GL_TRACKING_STATE_COMPLETED: *phase = GL_GAME_PHASE_COMPLETED; return true;
        case GL_TRACKING_STATE_INACTIVE:
        case GL_TRACKING_STATE_INTERRUPTED: return false;
        }
        return false;
    }

    gl_tracking_state trackingState(gl_game_phase phase) const {
        switch (phase) {
        case GL_GAME_PHASE_UNKNOWN:
            return state == GL_TRACKING_STATE_INACTIVE ? GL_TRACKING_STATE_INACTIVE : GL_TRACKING_STATE_INTERRUPTED;
        case GL_GAME_PHASE_COMMAND: return GL_TRACKING_STATE_COMMAND;
        case GL_GAME_PHASE_PRESENTING: return GL_TRACKING_STATE_PRESENTING;
        case GL_GAME_PHASE_INPUT: return GL_TRACKING_STATE_INPUT;
        case GL_GAME_PHASE_COMPLETED: return GL_TRACKING_STATE_COMPLETED;
        }
        return state == GL_TRACKING_STATE_INACTIVE ? GL_TRACKING_STATE_INACTIVE : GL_TRACKING_STATE_INTERRUPTED;
    }

    void applyPhase(const Evidence &evidence) {
        gl_game_phase resolved = GL_GAME_PHASE_UNKNOWN;
        gl_phase_source source = GL_PHASE_SOURCE_NONE;
        gl_game_phase retained = GL_GAME_PHASE_UNKNOWN;

        if (evidence.hasHeader && evidence.headerPhase != GL_GAME_PHASE_UNKNOWN
            && evidence.headerSourceTime <= evidence.time
            && evidence.time - evidence.headerSourceTime <= policy.unknownPhaseGrace) {
            resolved = evidence.headerPhase;
            source = GL_PHASE_SOURCE_HEADER_TEXT;
            // Swift's `max(x, y)` is `y >= x ? y : x` and `min(x, y)` is
            // `y < x ? y : x`; kept literally so NaN resolves the same way.
            const double x = lastPhaseTime.has ? lastPhaseTime.value : -INFINITY;
            const double y = evidence.time < evidence.headerSourceTime ? evidence.time : evidence.headerSourceTime;
            lastPhaseTime.set(y >= x ? y : x);
        } else if (!hasAnchor && lastPhaseTime.has && std::isfinite(lastPhaseTime.value)
                   && evidence.time >= lastPhaseTime.value
                   && evidence.time - lastPhaseTime.value <= policy.unknownPhaseGrace
                   && currentPhase(&retained)) {
            resolved = retained;
            source = GL_PHASE_SOURCE_RETAINED;
        }

        const bool indicatorPresentation = presentationFromIndicators(
            evidence, source == GL_PHASE_SOURCE_HEADER_TEXT && resolved != GL_GAME_PHASE_PRESENTING);
        if (source != GL_PHASE_SOURCE_HEADER_TEXT && indicatorPresentation) {
            resolved = GL_GAME_PHASE_PRESENTING;
            source = GL_PHASE_SOURCE_INDICATOR_TRANSITION;
        }

        if (evidence.hasInputTimerBar && evidence.hasValidCalibration && observedPresentationForCurrentHack
            && (state == GL_TRACKING_STATE_PRESENTING || state == GL_TRACKING_STATE_INPUT
                || state == GL_TRACKING_STATE_INTERRUPTED)
            && resolved != GL_GAME_PHASE_COMMAND && resolved != GL_GAME_PHASE_COMPLETED) {
            resolved = GL_GAME_PHASE_INPUT;
            source = GL_PHASE_SOURCE_INPUT_TIMER;
            lastPhaseTime.set(evidence.time);
        }

        // Our own window over one side of the strip: the countdown's visible
        // part keeps input that is already established, and nothing more.
        if (source != GL_PHASE_SOURCE_INPUT_TIMER && evidence.hasPartialInputTimerBar && evidence.hasValidCalibration
            && observedPresentationForCurrentHack && state == GL_TRACKING_STATE_INPUT
            && resolved != GL_GAME_PHASE_COMMAND && resolved != GL_GAME_PHASE_PRESENTING
            && resolved != GL_GAME_PHASE_COMPLETED) {
            resolved = GL_GAME_PHASE_INPUT;
            source = GL_PHASE_SOURCE_PARTIAL_INPUT_TIMER;
            lastPhaseTime.set(evidence.time);
        }

        const gl_tracking_state target = trackingState(resolved);
        if (target == state) {
            phaseSource = source;
            return;
        }

        if (state == GL_TRACKING_STATE_PRESENTING) {
            if (target == GL_TRACKING_STATE_INPUT) {
                if (source == GL_PHASE_SOURCE_INPUT_TIMER && !evidence.hasSlots && currentSlotIndex.has) {
                    const int32_t index = currentSlotIndex.value;
                    const int32_t base = inferredFromIndex.has ? inferredFromIndex.value : index;
                    inferredFromIndex.set(index < base ? index : base);
                }
                reasonText.assign("presentation ended, player input began");
                finalizeCurrentSlot(evidence.time, reasonText);
            } else {
                reasonText.assign("left presentation for ");
                reasonText.append(stateName(target));
                invalidateTentative(evidence.time, reasonText);
            }
        }

        if (target == GL_TRACKING_STATE_PRESENTING) {
            if (shouldStartNewHack(evidence, source == GL_PHASE_SOURCE_INDICATOR_TRANSITION && freshIndicatorStart
                                                 && stripReturnedAfterAbsence)) {
                startHack(evidence.time);
            } else {
                Event &event = pushEvent(GL_TRACKING_EVENT_PHASE_CHANGED, evidence.time);
                event.reason.assign("resumed presentation after ");
                event.reason.append(stateName(state));
            }
        }

        if (target == GL_TRACKING_STATE_COMMAND) {
            hypotheses.clear();
            currentSlotIndex.clear();
            observedPresentationForCurrentHack = false;
            discardRetainedSequence(evidence.time, "command channel opened");
        }

        if (target == GL_TRACKING_STATE_INPUT && !observedPresentationForCurrentHack) {
            discardRetainedSequence(evidence.time, "input began but no presentation was observed");
        }

        if (target == GL_TRACKING_STATE_INPUT && !isFrozen) {
            isFrozen = true;
            pushEvent(GL_TRACKING_EVENT_SEQUENCE_FROZEN, evidence.time)
                .reason.assign("player input began; presented sequence retained");
        }

        if (target == GL_TRACKING_STATE_COMPLETED) {
            observedPresentationForCurrentHack = false;
            isFrozen = true;
            pushEvent(GL_TRACKING_EVENT_HACK_COMPLETED, evidence.time).reason.assign("completion screen");
        }

        Event &changed = pushEvent(GL_TRACKING_EVENT_PHASE_CHANGED, evidence.time);
        changed.reason.assign(stateName(state));
        changed.reason.append(" -> ");
        changed.reason.append(stateName(target));
        changed.reason.append(" via ");
        changed.reason.append(sourceName(source));
        state = target;
        phaseSource = source;
        if (target != GL_TRACKING_STATE_INPUT) {
            inputSlotIndex.clear();
            inputHighlightTime.clear();
        }
    }

    bool shouldStartNewHack(const Evidence &evidence, bool fresh) const {
        if (!(state == GL_TRACKING_STATE_INTERRUPTED && hackID > 0 && !isFrozen)) return true;
        if (fresh) return true;
        if (evidence.hasSlots) {
            const OptInt expected = expectedSlotCount();
            if (expected.has && evidence.reading->slotCount != expected.value) return true;
        }
        return false;
    }

    static bool agrees(const Reading &reading, const Reading &other) {
        if (reading.slotCount != other.slotCount || reading.markerCentersX.size() != other.markerCentersX.size()) {
            return false;
        }
        for (size_t index = 0; index < reading.markerCentersX.size(); ++index) {
            if (!(std::fabs(reading.markerCentersX[index] - other.markerCentersX[index]) <= 0.02)) return false;
        }
        return true;
    }

    bool presentationFromIndicators(const Evidence &evidence, bool contradictoryHeader) {
        freshIndicatorStart = false;
        if (!(policy.entersPresentationFromIndicators && !contradictoryHeader && state != GL_TRACKING_STATE_INPUT
              && evidence.hasValidCalibration && !evidence.hasInputTimerBar && evidence.hasSlots)) {
            hasPrelude = false;
            hasAnchor = false;
            return false;
        }
        const Reading &reading = *evidence.reading;
        if (hasAnchor) {
            if (state == GL_TRACKING_STATE_PRESENTING && !slotCountConflict && agrees(reading, anchor)) {
                const int32_t anchorSelected = anchor.highlightedIndex.has ? anchor.highlightedIndex.value : 0;
                if (reading.highlightedIndex.has && reading.highlightedIndex.value >= anchorSelected) {
                    anchor.assign(reading);
                    return true;
                }
                if (!reading.highlightedIndex.has && anchor.highlightedIndex.has
                    && anchor.highlightedIndex.value == reading.slotCount - 1) {
                    return true;
                }
            }
            hasAnchor = false;
        }
        if (!reading.highlightedIndex.has && evidence.shapeKind == GL_SHAPE_KIND_NO_STROKE) {
            if (hasPrelude && agrees(reading, preludeReading) && evidence.time > preludeLastTime
                && evidence.time - preludeLastTime <= policy.maximumFrameGap) {
                preludeSamples += 1;
                preludeLastTime = evidence.time;
            } else {
                hasPrelude = true;
                preludeReading.assign(reading);
                preludeFirstTime = evidence.time;
                preludeLastTime = evidence.time;
                preludeSamples = 1;
            }
            return false;
        }
        // Swift's `defer { indicatorPrelude = nil }`: every exit from here on.
        const bool verified = reading.highlightedIndex.has && reading.highlightedIndex.value == 0 && hasPrelude
            && agrees(reading, preludeReading) && preludeSamples >= policy.minimumStableSamples
            && preludeLastTime - preludeFirstTime >= policy.minimumStableInterval
            && evidence.time >= preludeLastTime && evidence.time - preludeLastTime <= policy.maximumFrameGap;
        hasPrelude = false;
        if (!verified) return false;
        hasAnchor = true;
        anchor.assign(reading);
        freshIndicatorStart = true;
        return true;
    }

    void startHack(double time) {
        hackID += 1;
        slots.clear();
        hypotheses.clear();
        slotCountVotes.clear();
        slotCountConflict = false;
        currentSlotIndex.clear();
        inputSlotIndex.clear();
        inputHighlightTime.clear();
        inferredFromIndex.clear();
        nextInferredIndex.clear();
        blankSince.clear();
        lastIndicatorTime.clear();
        indicatorsObstructed = false;
        coveredSince.clear();
        isFrozen = false;
        observedPresentationForCurrentHack = true;
        Event &event = pushEvent(GL_TRACKING_EVENT_HACK_STARTED, time);
        event.reason.assign("presentation screen after ");
        event.reason.append(stateName(state));
    }

    // MARK: Slots

    void applySlots(const Evidence &evidence) {
        if (state == GL_TRACKING_STATE_PRESENTING || state == GL_TRACKING_STATE_INPUT) {
            if (evidence.hasSlots) {
                lastIndicatorTime.set(evidence.time);
                indicatorsObstructed = false;
            } else if (!lastIndicatorTime.has
                       || evidence.time - lastIndicatorTime.value > policy.indicatorObstructionGrace) {
                indicatorsObstructed = true;
            }
        } else if (evidence.hasValidCalibration && evidence.slotRejection == GL_SLOT_REJECTION_COVERED_BY_OVERLAY) {
            const bool arrayInView = evidence.shapeKind == GL_SHAPE_KIND_NO_STROKE
                || evidence.shapeKind == GL_SHAPE_KIND_UNIQUE_VISIBLE_SHAPE;
            if (!coveredSince.has && arrayInView) coveredSince.set(evidence.time);
            indicatorsObstructed = coveredSince.has
                && evidence.time - coveredSince.value >= policy.indicatorObstructionGrace;
        } else {
            coveredSince.clear();
            indicatorsObstructed = false;
        }
        if (!evidence.hasSlots && state == GL_TRACKING_STATE_INPUT
            && (evidence.hasPartialSlots || evidence.hasPartialInputTimerBar)) {
            applyPartialInputSlots(evidence);
            return;
        }
        if (!evidence.hasSlots) return;
        const Reading &reading = *evidence.reading;

        if (state == GL_TRACKING_STATE_PRESENTING || state == GL_TRACKING_STATE_INPUT) {
            bool found = false;
            for (auto &vote : slotCountVotes) {
                if (vote.first == reading.slotCount) {
                    vote.second += 1;
                    found = true;
                    break;
                }
            }
            if (!found) slotCountVotes.emplace_back(reading.slotCount, 1);
            if (qualifiedVoteCount(nullptr) > 1 && !slotCountConflict) {
                slotCountConflict = true;
                reasonText.assign("slot count changed mid-hack");
                invalidateTentative(evidence.time, reasonText);
                qualifiedScratch.clear();
                for (const auto &vote : slotCountVotes) {
                    if (vote.second >= policy.slotCountVotesRequired) {
                        // Sorted as it is gathered: there are at most a few.
                        auto position = qualifiedScratch.begin();
                        while (position != qualifiedScratch.end() && *position < vote.first) ++position;
                        qualifiedScratch.insert(position, vote.first);
                    }
                }
                Event &event = pushEvent(GL_TRACKING_EVENT_SLOT_COUNT_CONFLICT, evidence.time);
                event.reason.assign("counts ");
                for (size_t index = 0; index < qualifiedScratch.size(); ++index) {
                    if (index > 0) event.reason.push_back('/');
                    appendInt(event.reason, qualifiedScratch[index]);
                }
            }
        }

        switch (state) {
        case GL_TRACKING_STATE_PRESENTING: {
            ensureSlots(reading.slotCount - 1);
            if (!reading.highlightedIndex.has) {
                releaseLastSlot(evidence, reading);
                return;
            }
            const int32_t highlighted = reading.highlightedIndex.value;
            lastSlotReleasedSince.clear();
            if (inferredFromIndex.has) {
                for (size_t index = static_cast<size_t>(inferredFromIndex.value); index < slots.count; ++index) {
                    slots[index].reset(static_cast<int32_t>(index));
                }
                if (static_cast<int64_t>(slots.count) > reading.slotCount) {
                    const int64_t keep = reading.slotCount > 0 ? reading.slotCount : 0;
                    slots.count = static_cast<size_t>(keep);
                }
                currentSlotIndex.clear();
                hypotheses.clear();
                inferredFromIndex.clear();
                nextInferredIndex.clear();
                blankSince.clear();
                pushEvent(GL_TRACKING_EVENT_EVIDENCE_INVALIDATED, evidence.time)
                    .reason.assign("indicators restored; inferred positions discarded");
            }
            if (!currentSlotIndex.has) {
                openSlot(highlighted, evidence.time);
                return;
            }
            const int32_t open = currentSlotIndex.value;
            if (highlighted > open) {
                reasonText.assign("indicator advanced to slot ");
                appendInt(reasonText, static_cast<int64_t>(highlighted) + 1);
                finalizeCurrentSlot(evidence.time, reasonText);
                for (int32_t skipped = open + 1; skipped < highlighted; ++skipped) {
                    ensureSlots(skipped);
                    slots[static_cast<size_t>(skipped)].status = GL_SLOT_STATUS_MISSING;
                    reasonText.assign("indicator skipped this slot");
                    slots[static_cast<size_t>(skipped)].setReason(reasonText);
                    pushEvent(GL_TRACKING_EVENT_SLOT_MISSING, evidence.time, some(skipped))
                        .reason.assign("indicator skipped this slot");
                }
                openSlot(highlighted, evidence.time);
                pushEvent(GL_TRACKING_EVENT_SLOT_ADVANCED, evidence.time, some(highlighted))
                    .reason.assign("verified indicator transition");
            } else if (highlighted < open) {
                reasonText.assign("indicator moved back to slot ");
                appendInt(reasonText, static_cast<int64_t>(highlighted) + 1);
                invalidateTentative(evidence.time, reasonText);
            }
            break;
        }
        case GL_TRACKING_STATE_INPUT: {
            bool anyInferred = false;
            for (size_t index = 0; index < slots.count; ++index) {
                if (slots[index].status == GL_SLOT_STATUS_INFERRED) {
                    anyInferred = true;
                    break;
                }
            }
            if (anyInferred) {
                inputSlotIndex.clear();
                inputHighlightTime.clear();
            } else if (reading.highlightedIndex.has) {
                inputSlotIndex.set(reading.highlightedIndex.value);
                inputHighlightTime.set(evidence.time);
            } else if (inputHighlightTime.has && evidence.time >= inputHighlightTime.value
                       && evidence.time - inputHighlightTime.value <= policy.indicatorObstructionGrace) {
                // Between indicators, not off them: hold the slot.
            } else {
                inputSlotIndex.clear();
                inputHighlightTime.clear();
            }
            break;
        }
        default:
            break;
        }
    }

    /// `applyPartialInputSlots(_:)`.
    void applyPartialInputSlots(const Evidence &evidence) {
        bool anyInferred = false;
        for (size_t index = 0; index < slots.count; ++index) {
            if (slots[index].status == GL_SLOT_STATUS_INFERRED) {
                anyInferred = true;
                break;
            }
        }
        const OptInt count = expectedSlotCount();
        int32_t indices[kMaximumSequenceLength];
        OptInt highlighted;
        if (!anyInferred && (evidence.hasInputTimerBar || evidence.hasPartialInputTimerBar) && count.has
            && evidence.hasPartialSlots && resolvePartial(evidence.partialSlots, count.value, indices, &highlighted)
            && highlighted.has) {
            inputSlotIndex.set(highlighted.value);
            inputHighlightTime.set(evidence.time);
        } else {
            inputSlotIndex.clear();
            inputHighlightTime.clear();
        }
    }

    void releaseLastSlot(const Evidence &evidence, const Reading &strip) {
        bool anyStable = false;
        for (const Hypothesis &hypothesis : hypotheses) {
            if (isStable(hypothesis)) {
                anyStable = true;
                break;
            }
        }
        if (!(policy.closesLastSlotOnRelease && currentSlotIndex.has
              && currentSlotIndex.value == strip.slotCount - 1 && !inferredFromIndex.has
              && evidence.shapeKind == GL_SHAPE_KIND_NO_STROKE && anyStable)) {
            lastSlotReleasedSince.clear();
            return;
        }
        const double since = lastSlotReleasedSince.has ? lastSlotReleasedSince.value : evidence.time;
        lastSlotReleasedSince.set(since);
        if (!(evidence.time - since >= policy.minimumBlankInterval)) return;
        lastSlotReleasedSince.clear();
        reasonText.assign("last indicator released after the array cleared");
        finalizeCurrentSlot(evidence.time, reasonText);
    }

    void ensureSlots(int32_t index) {
        if (index < 0) return;
        while (static_cast<int64_t>(slots.count) <= index) {
            const int32_t next = static_cast<int32_t>(slots.count);
            slots.append().reset(next);
        }
    }

    void openSlot(int32_t index, double time) {
        ensureSlots(index);
        for (int32_t earlier = 0; earlier < index; ++earlier) {
            Slot &slot = slots[static_cast<size_t>(earlier)];
            if (slot.status != GL_SLOT_STATUS_PENDING) continue;
            slot.status = GL_SLOT_STATUS_MISSING;
            reasonText.assign("presentation was already past this slot");
            slot.setReason(reasonText);
            pushEvent(GL_TRACKING_EVENT_SLOT_MISSING, time, some(earlier)).reason.assign("joined presentation late");
        }
        Slot &slot = slots[static_cast<size_t>(index)];
        if (!slot.isSettled()) {
            slot.status = GL_SLOT_STATUS_OBSERVING;
            slot.clearReason();
        }
        currentSlotIndex.set(index);
        hypotheses.clear();
        lastSlotReleasedSince.clear();
    }

    void sortedGlyphs(const std::vector<size_t> &which, std::vector<int32_t> &out) const {
        out.clear();
        for (size_t hypothesis : which) {
            const int32_t glyph = hypotheses[hypothesis].glyph;
            auto position = out.begin();
            while (position != out.end() && *position < glyph) ++position;
            out.insert(position, glyph);
        }
    }

    /// `reason` must not be `innerReason`, which this composes into.
    void finalizeCurrentSlot(double time, const std::string &reason) {
        if (!currentSlotIndex.has) return;
        const int32_t index = currentSlotIndex.value;
        currentSlotIndex.clear();
        ensureSlots(index);
        Slot &slot = slots[static_cast<size_t>(index)];
        if (slot.isSettled()) {
            hypotheses.clear();
            return;
        }

        stableScratch.clear();
        for (size_t position = 0; position < hypotheses.size(); ++position) {
            if (isStable(hypotheses[position])) stableScratch.push_back(position);
        }
        slot.setReason(reason);

        if (stableScratch.empty()) {
            const bool sawSomething = !hypotheses.empty();
            slot.status = sawSomething ? GL_SLOT_STATUS_UNCERTAIN : GL_SLOT_STATUS_MISSING;
            if (sawSomething) {
                stableScratch.clear();
                int64_t samples = 0;
                for (size_t position = 0; position < hypotheses.size(); ++position) {
                    stableScratch.push_back(position);
                    samples += hypotheses[position].count;
                }
                sortedGlyphs(stableScratch, slot.alternatives);
                Event &event = pushEvent(GL_TRACKING_EVENT_SLOT_UNCERTAIN, time, some(index), -1, samples);
                event.reason.assign(reason);
                event.reason.append("; no shape held long enough");
            } else {
                Event &event = pushEvent(GL_TRACKING_EVENT_SLOT_MISSING, time, some(index));
                event.reason.assign(reason);
                event.reason.append("; no shape evidence");
            }
            hypotheses.clear();
            return;
        }

        if (stableScratch.size() == 1) {
            commit(hypotheses[stableScratch[0]], index, time, reason, nullptr, 0);
            hypotheses.clear();
            return;
        }

        // Ordered by edge count, ties in their original order (Swift's sort
        // is stable, and a tie can never be nested anyway).
        for (size_t i = 1; i < stableScratch.size(); ++i) {
            const size_t moving = stableScratch[i];
            size_t j = i;
            while (j > 0 && hypotheses[moving].edges.count() < hypotheses[stableScratch[j - 1]].edges.count()) {
                stableScratch[j] = stableScratch[j - 1];
                --j;
            }
            stableScratch[j] = moving;
        }
        bool nested = true;
        for (size_t i = 0; i + 1 < stableScratch.size(); ++i) {
            if (!hypotheses[stableScratch[i]].edges.isStrictSubset(hypotheses[stableScratch[i + 1]].edges)) {
                nested = false;
                break;
            }
        }
        if (!nested) {
            slot.status = GL_SLOT_STATUS_UNCERTAIN;
            sortedGlyphs(stableScratch, slot.alternatives);
            int64_t samples = 0;
            for (size_t position : stableScratch) samples += hypotheses[position].count;
            Event &event = pushEvent(GL_TRACKING_EVENT_SLOT_UNCERTAIN, time, some(index), -1, samples);
            event.reason.assign(reason);
            event.reason.append("; ");
            appendInt(event.reason, static_cast<int64_t>(stableScratch.size()));
            event.reason.append(" unrelated stable shapes");
            hypotheses.clear();
            return;
        }
        innerReason.assign(reason);
        innerReason.append("; grew through ");
        appendInt(innerReason, static_cast<int64_t>(stableScratch.size()));
        innerReason.append(" nested shapes");
        const Hypothesis largest = hypotheses[stableScratch.back()];
        // The smaller shapes, smallest first, as alternatives.
        qualifiedScratch.clear();
        for (size_t i = 0; i + 1 < stableScratch.size(); ++i) qualifiedScratch.push_back(hypotheses[stableScratch[i]].glyph);
        commit(largest, index, time, innerReason, qualifiedScratch.data(), qualifiedScratch.size());
        hypotheses.clear();
    }

    void commit(const Hypothesis &hypothesis, int32_t index, double time, const std::string &reason,
                const int32_t *alternatives, size_t alternativeCount) {
        const bool inferred = inferredFromIndex.has && index >= inferredFromIndex.value;
        Slot &slot = slots[static_cast<size_t>(index)];
        slot.status = inferred ? GL_SLOT_STATUS_INFERRED : GL_SLOT_STATUS_CONFIRMED;
        slot.glyph = hypothesis.glyph;
        slot.alternatives.assign(alternatives, alternatives + alternativeCount);
        slot.firstSampleTime.set(hypothesis.firstTime);
        slot.lastSampleTime.set(hypothesis.lastTime);
        slot.sampleCount = hypothesis.count;
        slot.setReason(reason);
        Event &event = pushEvent(inferred ? GL_TRACKING_EVENT_SLOT_INFERRED : GL_TRACKING_EVENT_SLOT_COMMITTED, time,
                                 some(index), hypothesis.glyph, hypothesis.count);
        event.reason.assign(reason);
    }

    // MARK: Shapes

    void applyFallback(const Evidence &evidence) {
        if (!(state == GL_TRACKING_STATE_PRESENTING && !isFrozen && evidence.hasValidCalibration
              && !evidence.hasSlots)) {
            blankSince.clear();
            return;
        }
        if (phaseSource != GL_PHASE_SOURCE_HEADER_TEXT) {
            blankSince.clear();
            return;
        }
        if (!inferredFromIndex.has) {
            int32_t first;
            if (currentSlotIndex.has) {
                first = currentSlotIndex.value;
            } else {
                first = static_cast<int32_t>(slots.count);
                for (size_t index = 0; index < slots.count; ++index) {
                    if (!slots[index].isSettled()) {
                        first = static_cast<int32_t>(index);
                        break;
                    }
                }
            }
            inferredFromIndex.set(first);
            nextInferredIndex.set(first);
        }
        if (evidence.shapeKind == GL_SHAPE_KIND_NO_STROKE) {
            if (!blankSince.has) blankSince.set(evidence.time);
            if (blankSince.has && evidence.time - blankSince.value >= policy.minimumBlankInterval
                && currentSlotIndex.has && !hypotheses.empty()) {
                const int32_t index = currentSlotIndex.value;
                reasonText.assign("clear array during presentation; position unverified");
                finalizeCurrentSlot(evidence.time, reasonText);
                nextInferredIndex.set(index + 1);
            }
            return;
        }
        blankSince.clear();
        if (evidence.shapeKind == GL_SHAPE_KIND_UNIQUE_VISIBLE_SHAPE && !currentSlotIndex.has
            && nextInferredIndex.has) {
            const OptInt expected = expectedSlotCount();
            const int32_t bound = expected.has ? expected.value : kMaximumSequenceLength;
            if (nextInferredIndex.value < bound) openSlot(nextInferredIndex.value, evidence.time);
        }
    }

    void applyShape(const Evidence &evidence) {
        if (!(state == GL_TRACKING_STATE_PRESENTING && phaseSource != GL_PHASE_SOURCE_NONE && currentSlotIndex.has
              && evidence.hasValidCalibration)) {
            return;
        }
        if (!(evidence.shapeKind == GL_SHAPE_KIND_UNIQUE_VISIBLE_SHAPE && evidence.glyph >= 0)) return;
        const size_t index = static_cast<size_t>(currentSlotIndex.value);
        if (index >= slots.count) return;
        Slot &slot = slots[index];
        if (slot.isSettled()) return;

        Hypothesis *existing = nullptr;
        for (Hypothesis &hypothesis : hypotheses) {
            if (hypothesis.glyph == evidence.glyph) {
                existing = &hypothesis;
                break;
            }
        }
        if (existing) {
            // Only a genuinely later source frame is another observation.
            if (evidence.time <= existing->lastTime) return;
            existing->lastTime = evidence.time;
            existing->count += 1;
        } else {
            hypotheses.push_back(Hypothesis{evidence.glyph, evidence.edges, evidence.time, evidence.time, 1});
        }
        slot.status = GL_SLOT_STATUS_OBSERVING;
        if (!slot.firstSampleTime.has) slot.firstSampleTime.set(evidence.time);
        slot.lastSampleTime.set(evidence.time);
    }

    void discardRetainedSequence(double time, const char *reason) {
        if (slots.empty() && slotCountVotes.empty()) return;
        Event &event = pushEvent(GL_TRACKING_EVENT_EVIDENCE_INVALIDATED, time);
        // The discarded Glyphs' names, joined by commas, built in the event's
        // own buffer after the reason.
        event.reason.assign(reason);
        const size_t reasonLength = event.reason.size();
        event.reason.append("; discarded ");
        const size_t namesStart = event.reason.size();
        bool first = true;
        for (size_t index = 0; index < slots.count; ++index) {
            const int32_t glyph = slots[index].glyph;
            if (glyph < 0) continue;
            if (!first) event.reason.push_back(',');
            first = false;
            if (validGlyph(glyph)) event.reason.append(glyphNames[static_cast<size_t>(glyph)]);
        }
        if (event.reason.size() == namesStart) event.reason.resize(reasonLength);

        slots.clear();
        hypotheses.clear();
        slotCountVotes.clear();
        slotCountConflict = false;
        currentSlotIndex.clear();
        inputSlotIndex.clear();
        inputHighlightTime.clear();
        isFrozen = false;
        inferredFromIndex.clear();
        nextInferredIndex.clear();
        blankSince.clear();
    }

    void invalidateTentative(double time, const std::string &reason) {
        hasPrelude = false;
        hasAnchor = false;
        blankSince.clear();
        nextInferredIndex.clear();
        if (hypotheses.empty() && !currentSlotIndex.has) return;
        hypotheses.clear();
        if (currentSlotIndex.has && static_cast<size_t>(currentSlotIndex.value) < slots.count) {
            Slot &slot = slots[static_cast<size_t>(currentSlotIndex.value)];
            if (!slot.isSettled()) {
                slot.status = GL_SLOT_STATUS_PENDING;
                slot.firstSampleTime.clear();
                slot.lastSampleTime.clear();
            }
        }
        currentSlotIndex.clear();
        pushEvent(GL_TRACKING_EVENT_EVIDENCE_INVALIDATED, time).reason.assign(reason);
    }

    // MARK: Output

    void write(const Event &event, gl_tracking_event *out) const {
        out->kind = event.kind;
        out->time = event.time;
        out->hackID = event.hackID;
        out->slotIndex = event.slotIndex.c();
        out->glyph = event.glyph;
        out->reason = gc_string{event.reason.data(), static_cast<int32_t>(event.reason.size())};
        out->sampleCount = event.sampleCount;
    }

    int32_t copyEvents(gl_tracking_event *out, int32_t capacity) const {
        if (out && capacity > 0) {
            const size_t limit = events.count < static_cast<size_t>(capacity) ? events.count
                                                                               : static_cast<size_t>(capacity);
            for (size_t index = 0; index < limit; ++index) write(events[index], &out[index]);
        }
        return static_cast<int32_t>(events.count);
    }
};

extern "C" {

gl_tracking_policy gl_tracking_policy_default(void) {
    gl_tracking_policy policy;
    policy.minimumStableInterval = 0.045;
    policy.minimumStableSamples = 2;
    policy.maximumFrameGap = 1.0;
    policy.unknownPhaseGrace = 0.75;
    policy.stalenessThreshold = 1.5;
    policy.slotCountVotesRequired = 2;
    policy.indicatorObstructionGrace = 0.35;
    policy.minimumBlankInterval = 0.045;
    policy.entersPresentationFromIndicators = true;
    policy.closesLastSlotOnRelease = true;
    policy.minimumStripAbsenceForNewHack = 1.5;
    return policy;
}

gl_tracker *gl_tracker_create(uint64_t sessionID, const gl_tracking_policy *policy, const gc_string *glyphNames,
                              int32_t glyphCount) {
    if (glyphCount < 0 || (glyphCount > 0 && !glyphNames)) return nullptr;
    gl_tracker *tracker = new (std::nothrow) gl_tracker();
    if (!tracker) return nullptr;
    tracker->sessionID = sessionID;
    tracker->policy = policy ? *policy : gl_tracking_policy_default();
    tracker->glyphNames.reserve(static_cast<size_t>(glyphCount));
    for (int32_t index = 0; index < glyphCount; ++index) {
        const gc_string name = glyphNames[index];
        if (name.bytes && name.length > 0) {
            tracker->glyphNames.emplace_back(name.bytes, static_cast<size_t>(name.length));
        } else {
            tracker->glyphNames.emplace_back();
        }
    }
    tracker->hypotheses.reserve(8);
    tracker->slotCountVotes.reserve(8);
    tracker->stableScratch.reserve(8);
    tracker->qualifiedScratch.reserve(8);
    return tracker;
}

void gl_tracker_destroy(gl_tracker *tracker) { delete tracker; }

void gl_tracker_reset(gl_tracker *tracker) {
    if (tracker) tracker->reset();
}

int32_t gl_tracker_accept(gl_tracker *tracker, const gl_frame_evidence *evidence, gl_tracking_event *out,
                          int32_t capacity) {
    if (!tracker || !evidence) return 0;
    tracker->accept(*evidence);
    return tracker->copyEvents(out, capacity);
}

int32_t gl_tracker_last_events(const gl_tracker *tracker, gl_tracking_event *out, int32_t capacity) {
    return tracker ? tracker->copyEvents(out, capacity) : 0;
}

void gl_tracker_invalidate_phase(gl_tracker *tracker) {
    if (tracker) tracker->invalidatePhase();
}

uint64_t gl_tracker_session_id(const gl_tracker *tracker) { return tracker ? tracker->sessionID : 0; }

gl_tracking_policy gl_tracker_policy(const gl_tracker *tracker) {
    return tracker ? tracker->policy : gl_tracking_policy_default();
}

bool gl_partial_slot_resolve(const gl_partial_slot_reading *reading, int32_t slotCount, int32_t *slotIndices,
                             gc_opt_int32 *highlightedIndex) {
    if (reading == nullptr || slotIndices == nullptr) return false;
    // Room for the largest row; only `markerCount` of them are copied out.
    int32_t indices[kMaximumSequenceLength];
    OptInt highlighted;
    if (!resolvePartial(*reading, slotCount, indices, &highlighted)) return false;
    for (int32_t marker = 0; marker < reading->markerCount; ++marker) slotIndices[marker] = indices[marker];
    if (highlightedIndex != nullptr) *highlightedIndex = highlighted.c();
    return true;
}

gl_tracking_state gl_tracker_state(const gl_tracker *tracker) {
    return tracker ? tracker->state : GL_TRACKING_STATE_INACTIVE;
}

gl_phase_source gl_tracker_phase_source(const gl_tracker *tracker) {
    return tracker ? tracker->phaseSource : GL_PHASE_SOURCE_NONE;
}

int64_t gl_tracker_hack_id(const gl_tracker *tracker) { return tracker ? tracker->hackID : 0; }

int64_t gl_tracker_revision(const gl_tracker *tracker) { return tracker ? tracker->revision : 0; }

gc_opt_double gl_tracker_last_evidence_time(const gl_tracker *tracker) {
    return tracker ? tracker->lastEvidenceTime.c() : gc_opt_double{false, 0};
}

gc_opt_double gl_tracker_last_phase_time(const gl_tracker *tracker) {
    return tracker ? tracker->lastPhaseTime.c() : gc_opt_double{false, 0};
}

gc_opt_double gl_tracker_last_indicator_time(const gl_tracker *tracker) {
    return tracker ? tracker->lastIndicatorTime.c() : gc_opt_double{false, 0};
}

gc_opt_int32 gl_tracker_expected_slot_count(const gl_tracker *tracker) {
    return tracker ? tracker->expectedSlotCount().c() : gc_opt_int32{false, 0};
}

gc_opt_int32 gl_tracker_current_slot_index(const gl_tracker *tracker) {
    return tracker ? tracker->currentSlotIndex.c() : gc_opt_int32{false, 0};
}

gc_opt_int32 gl_tracker_input_slot_index(const gl_tracker *tracker) {
    return tracker ? tracker->inputSlotIndex.c() : gc_opt_int32{false, 0};
}

bool gl_tracker_indicators_obstructed(const gl_tracker *tracker) {
    return tracker ? tracker->indicatorsObstructed : false;
}

bool gl_tracker_slot_count_conflict(const gl_tracker *tracker) {
    return tracker ? tracker->slotCountConflict : false;
}

bool gl_tracker_is_frozen(const gl_tracker *tracker) { return tracker ? tracker->isFrozen : false; }

bool gl_tracker_observed_presentation_for_current_hack(const gl_tracker *tracker) {
    return tracker ? tracker->observedPresentationForCurrentHack : false;
}

int32_t gl_tracker_slots(const gl_tracker *tracker, gl_slot_observation *out, int32_t capacity) {
    if (!tracker) return 0;
    const size_t count = tracker->slots.count;
    if (out && capacity > 0) {
        const size_t limit = count < static_cast<size_t>(capacity) ? count : static_cast<size_t>(capacity);
        for (size_t index = 0; index < limit; ++index) {
            const Slot &slot = tracker->slots[index];
            gl_slot_observation &observation = out[index];
            observation.index = slot.index;
            observation.status = slot.status;
            observation.glyph = slot.glyph;
            observation.alternatives = slot.alternatives.empty() ? nullptr : slot.alternatives.data();
            observation.alternativeCount = static_cast<int32_t>(slot.alternatives.size());
            observation.firstSampleTime = slot.firstSampleTime.c();
            observation.lastSampleTime = slot.lastSampleTime.c();
            observation.sampleCount = slot.sampleCount;
            observation.hasBoundaryReason = slot.hasBoundaryReason;
            observation.boundaryReason = gc_string{slot.boundaryReason.data(),
                                                   static_cast<int32_t>(slot.boundaryReason.size())};
        }
    }
    return static_cast<int32_t>(count);
}

int32_t gl_tracker_confirmed_prefix(const gl_tracker *tracker, int32_t *out, int32_t capacity) {
    if (!tracker) return 0;
    int32_t length = 0;
    for (size_t index = 0; index < tracker->slots.count; ++index) {
        const Slot &slot = tracker->slots[index];
        if (slot.status != GL_SLOT_STATUS_CONFIRMED || slot.glyph < 0) break;
        if (out && length < capacity) out[length] = slot.glyph;
        ++length;
    }
    return length;
}

}  // extern "C"
