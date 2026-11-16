// Player input validation: PlayerInputValidator.swift, rule for rule.
// See glyph_logic_input.h for the ABI; the Swift validator is the oracle.

#include "glyph_logic_input.h"

#include <cmath>
#include <cstdint>
#include <memory>
#include <new>
#include <vector>

namespace {

constexpr int kNodeCount = 11;

bool edgeSetEqual(const gl_input_edge_set &a, const gl_input_edge_set &b) {
    return a.bits[0] == b.bits[0] && a.bits[1] == b.bits[1];
}

bool edgeSetEmpty(const gl_input_edge_set &set) { return set.bits[0] == 0 && set.bits[1] == 0; }

gl_input_edge_set edgeSetSubtracting(const gl_input_edge_set &a, const gl_input_edge_set &b) {
    return gl_input_edge_set{{a.bits[0] & ~b.bits[0], a.bits[1] & ~b.bits[1]}};
}

bool edgeSetDisjoint(const gl_input_edge_set &a, const gl_input_edge_set &b) {
    return (a.bits[0] & b.bits[0]) == 0 && (a.bits[1] & b.bits[1]) == 0;
}

void edgeSetInsert(gl_input_edge_set &set, uint8_t a, uint8_t b) {
    const int lower = a <= b ? a : b;
    const int upper = a <= b ? b : a;
    if (upper >= kNodeCount) return;  // Not a node; Swift cannot express it.
    const int bit = lower * kNodeCount + upper;
    set.bits[bit / 64] |= uint64_t(1) << (bit % 64);
}

/// `GlyphEdgeEvidence`, owning its samples.
struct EdgeEvidence {
    uint8_t lower;
    uint8_t upper;
    std::vector<double> samples;

    /// `coverage`: 0/0 is NaN for an empty edge, as in Swift.
    double coverage() const {
        int lit = 0;
        for (double sample : samples) {
            if (sample >= 0.18) ++lit;
        }
        return double(lit) / double(samples.size());
    }
    bool isPresent() const { return coverage() >= 0.8; }
};

std::vector<EdgeEvidence> copyEvidence(const gl_input_edge_evidence *evidence, int32_t count) {
    std::vector<EdgeEvidence> copied;
    copied.reserve(size_t(count));
    for (int32_t i = 0; i < count; ++i) {
        const gl_input_edge_evidence &item = evidence[i];
        EdgeEvidence edge{item.lower, item.upper, {}};
        if (item.samples != nullptr && item.sampleCount > 0) {
            edge.samples.assign(item.samples, item.samples + item.sampleCount);
        }
        copied.push_back(std::move(edge));
    }
    return copied;
}

struct Result {
    uint64_t sessionID = 0;
    int64_t hackID = 0;
    int64_t slotIndex = 0;
    int64_t attemptID = 0;
    int32_t expectedGlyph = -1;
    gl_input_verdict verdict = GL_INPUT_VERDICT_UNAVAILABLE;
    gl_input_reason reason = GL_INPUT_REASON_NONE;
    double sourceTime = 0;
    gc_opt_double startTime{false, 0};
    gc_opt_double liftTime{false, 0};
    std::vector<gl_input_sample> samples;
    gl_input_window_end windowEnd = GL_INPUT_WINDOW_END_INTERRUPTED;
};

bool optionalEqual(const gc_opt_double &a, const gc_opt_double &b) {
    if (a.has != b.has) return false;
    return !a.has || a.value == b.value;
}

/// The synthesized `InputCheckResult ==`: doubles compare with `==`, so a NaN
/// time makes a result unequal to itself, exactly as in Swift.
bool resultEqual(const Result &a, const Result &b) {
    if (a.sessionID != b.sessionID || a.hackID != b.hackID || a.slotIndex != b.slotIndex ||
        a.attemptID != b.attemptID || a.expectedGlyph != b.expectedGlyph || a.verdict != b.verdict ||
        a.reason != b.reason || !(a.sourceTime == b.sourceTime) || !optionalEqual(a.startTime, b.startTime) ||
        !optionalEqual(a.liftTime, b.liftTime) || a.samples.size() != b.samples.size() ||
        a.windowEnd != b.windowEnd) {
        return false;
    }
    for (size_t i = 0; i < a.samples.size(); ++i) {
        const gl_input_sample &x = a.samples[i], &y = b.samples[i];
        if (!(x.time == y.time) || !edgeSetEqual(x.edges, y.edges) || !edgeSetEqual(x.partialEdges, y.partialEdges)) {
            return false;
        }
    }
    return true;
}

struct Event {
    gl_input_event_kind kind;
    double time;
    int64_t hackID;
    int64_t slotIndex;
    int64_t attemptID;
    gl_input_reason reason;
    bool hasResult;
    Result result;
    std::vector<EdgeEvidence> edgeEvidence;
};

struct Attempt {
    int64_t index;
    int64_t id;
    int32_t glyph;
    gl_input_edge_set expected;
    gc_opt_double start;
    gc_opt_double lift{false, 0};
    std::vector<gl_input_sample> samples;
    /// The verdict shown while the window is still open, if any.
    bool hasPublished = false;
    Result published;
};

struct Sample {
    double time;
    bool clear;
    std::vector<EdgeEvidence> edges;

    bool showsNoDrawing() const {
        if (clear) return true;
        for (const EdgeEvidence &edge : edges) {
            if (edge.isPresent()) return false;
        }
        return true;
    }
};

struct Outcome {
    gl_input_verdict verdict;
    gl_input_reason reason;
};

}  // namespace

struct gl_input_validator {
    uint64_t sessionID;
    gl_input_policy policy;
    std::vector<gl_input_edge_set> templates;

    std::vector<Result> results;
    int64_t revision = 0;
    bool hasHackID = false;
    int64_t hackID = 0;
    bool hasPreviousTime = false;
    double previousTime = 0;
    bool hasIndex = false;
    int64_t index = 0;
    bool hasClearTime = false;
    double clearTime = 0;
    std::unique_ptr<Attempt> attempt;
    bool hasPendingIndex = false;
    int64_t pendingIndex = 0;
    std::unique_ptr<Sample> pendingSample;
    bool awaitingClear = false;
    int64_t nextAttemptID = 0;
    std::vector<Event> events;

    // ABI views, rebuilt on demand from the vectors above.
    std::vector<gl_input_event> eventViews;
    std::vector<std::vector<gl_input_edge_evidence>> eventEvidenceViews;
    std::vector<gl_input_result> resultViews;

    // MARK: accept

    void accept(const gl_input_frame &frame, const gl_input_context &context,
                const gl_input_edge_evidence *edgeEvidence, int32_t edgeEvidenceCount) {
        events.clear();
        if (frame.sessionID != sessionID) return;
        if (!std::isfinite(frame.time)) {
            invalidate(GL_INPUT_REASON_FRAME_GAP, hasPreviousTime ? previousTime : 0);
            return;
        }
        if (!hasHackID || hackID != context.hackID) {
            hasHackID = true;
            hackID = context.hackID;
            if (!results.empty()) {
                results.clear();
                revision += 1;
            }
            discardAttempt();
            hasPreviousTime = false;
        }
        if (hasPreviousTime) {
            if (frame.time == previousTime) {
                events.clear();
                return;
            }
            if (frame.time < previousTime || frame.time - previousTime > policy.maximumFrameGap + 1e-9) {
                invalidate(GL_INPUT_REASON_FRAME_GAP, frame.time);
                previousTime = previousTime > frame.time ? previousTime : frame.time;
                return;
            }
        }
        hasPreviousTime = true;
        previousTime = frame.time;
        if (!context.isInputState || !context.observedPresentation) {
            invalidate(GL_INPUT_REASON_PHASE_CHANGE, frame.time);
            return;
        }
        if (context.slotCountConflict || !context.hasExpectedSlotCount) {
            invalidate(GL_INPUT_REASON_SLOT_COUNT_CONFLICT, frame.time);
            return;
        }
        const int64_t count = context.expectedSlotCount;
        if (context.indicatorsObstructed || !frame.hasSlots || frame.slotCount != count ||
            !frame.hasHighlightedIndex || frame.highlightedIndex < 0 || frame.highlightedIndex >= count) {
            invalidate(GL_INPUT_REASON_STRIP_LOSS, frame.time);
            return;
        }
        const int64_t highlighted = frame.highlightedIndex;
        if (!frame.hasValidCalibration || !frame.shapeAvailable) {
            invalidate(GL_INPUT_REASON_INVALID_CALIBRATION, frame.time);
            return;
        }
        if (attempt && !slotConfirms(context, attempt->index, attempt->glyph)) {
            Attempt drawing = *attempt;
            emit(GL_INPUT_EVENT_UNCHECKED, drawing, frame.time, GL_INPUT_REASON_UNCONFIRMED_EXPECTATION);
            if (drawing.hasPublished) {
                removeResults([&](const Result &r) { return r.attemptID == drawing.id; });
                revision += 1;
            }
            discardAttempt();
            setIndex(highlighted);
            awaitingClear = true;
            return;
        }
        Sample sample{frame.time, frame.shapeNoStroke, copyEvidence(edgeEvidence, edgeEvidenceCount)};
        if (!hasIndex) {
            setIndex(highlighted);
            consume(sample, context);
            return;
        }
        const int64_t current = index;
        if (highlighted != current) {
            // Keep the first candidate frame; it is part of the post-lift
            // window if the next independent sample confirms this advance.
            if (!(hasPendingIndex && pendingIndex == highlighted && pendingSample)) {
                if (hasPendingIndex) invalidate(GL_INPUT_REASON_AMBIGUOUS_BOUNDARY, frame.time);
                hasPendingIndex = true;
                pendingIndex = highlighted;
                pendingSample.reset(new Sample(std::move(sample)));
                return;
            }
            Sample first = std::move(*pendingSample);
            hasPendingIndex = false;
            pendingSample.reset();
            if (highlighted != current + 1) {
                const gl_input_reason reason =
                    highlighted < current ? GL_INPUT_REASON_BACKWARD_MOVE : GL_INPUT_REASON_MULTI_SLOT_JUMP;
                end(reason, frame.time, false);
                if (highlighted < current) {
                    std::vector<Result> retained;
                    for (const Result &result : results) {
                        if (result.slotIndex < highlighted) retained.push_back(result);
                    }
                    if (!resultsEqual(retained, results)) {
                        results = std::move(retained);
                        revision += 1;
                    }
                }
                discardAttempt();
                setIndex(highlighted);
                if (sample.clear) {
                    hasClearTime = true;
                    clearTime = sample.time;
                }
                return;
            }
            if (attempt && attempt->lift.has) invalidate(GL_INPUT_REASON_UNCLOSED_WINDOW, frame.time);
            if (!attempt) begin(current, gc_opt_double{false, 0}, first.time, context, nullptr);
            setIndex(highlighted);
            hasClearTime = false;
            awaitingClear = true;
            if (attempt) {
                attempt->lift = gc_opt_double{true, first.time};
                emit(GL_INPUT_EVENT_LIFTED, *attempt, first.time);
            }
            consume(first, context);
            consume(sample, context);
        } else {
            if (hasPendingIndex) {
                invalidate(GL_INPUT_REASON_AMBIGUOUS_BOUNDARY, frame.time);
                setIndex(highlighted);
            }
            consume(sample, context);
        }
    }

    void finish(double time) {
        events.clear();
        invalidate(GL_INPUT_REASON_END_OF_STREAM, time);
    }

    // MARK: helpers

    void setIndex(int64_t value) {
        hasIndex = true;
        index = value;
    }

    static bool slotConfirms(const gl_input_context &context, int64_t slotIndex, int32_t glyph) {
        for (int32_t i = 0; i < context.slotObservationCount; ++i) {
            const gl_input_slot &slot = context.slots[i];
            if (slot.index == slotIndex && slot.isConfirmed && slot.glyph >= 0 && slot.glyph == glyph) return true;
        }
        return false;
    }

    template <typename Predicate> void removeResults(Predicate predicate) {
        std::vector<Result> kept;
        kept.reserve(results.size());
        for (Result &result : results) {
            if (!predicate(result)) kept.push_back(std::move(result));
        }
        results = std::move(kept);
    }

    static bool resultsEqual(const std::vector<Result> &a, const std::vector<Result> &b) {
        if (a.size() != b.size()) return false;
        for (size_t i = 0; i < a.size(); ++i) {
            if (!resultEqual(a[i], b[i])) return false;
        }
        return true;
    }

    void consume(const Sample &sample, const gl_input_context &context) {
        if (attempt && attempt->lift.has) {
            Attempt &drawing = *attempt;
            if (sample.showsNoDrawing()) {
                Outcome outcome;
                if (!drawing.start.has) {
                    outcome = {GL_INPUT_VERDICT_UNAVAILABLE, GL_INPUT_REASON_MISSED_START};
                } else {
                    Outcome assessed;
                    if (assessment(drawing, true, assessed)) outcome = assessed;
                    else outcome = {GL_INPUT_VERDICT_UNAVAILABLE, GL_INPUT_REASON_SHORT_WINDOW};
                }
                complete(drawing, outcome.verdict, outcome.reason, sample.time, GL_INPUT_WINDOW_END_CLEAR_ARRAY);
                attempt.reset();
                hasClearTime = true;
                clearTime = sample.time;
                awaitingClear = false;
            } else {
                gl_input_sample recorded{sample.time, {{0, 0}}, {{0, 0}}};
                for (const EdgeEvidence &edge : sample.edges) {
                    if (edge.isPresent()) edgeSetInsert(recorded.edges, edge.lower, edge.upper);
                }
                for (const EdgeEvidence &edge : sample.edges) {
                    if (!edge.isPresent() && edge.coverage() >= policy.minimumPartialCoverage) {
                        edgeSetInsert(recorded.partialEdges, edge.lower, edge.upper);
                    }
                }
                drawing.samples.push_back(recorded);
                emit(GL_INPUT_EVENT_SAMPLE, drawing, sample.time, GL_INPUT_REASON_NONE, nullptr, &sample.edges);
                Outcome outcome;
                if (drawing.start.has && assessment(drawing, false, outcome) &&
                    (!drawing.hasPublished || outcome.verdict != drawing.published.verdict ||
                     outcome.reason != drawing.published.reason)) {
                    Result result = makeResult(drawing, outcome.verdict, outcome.reason, sample.time,
                                               GL_INPUT_WINDOW_END_OPEN);
                    drawing.published = result;
                    drawing.hasPublished = true;
                    store(result);
                    emit(GL_INPUT_EVENT_VERDICT, drawing, sample.time, outcome.reason, &result);
                }
            }
            return;
        }
        if (awaitingClear) {
            if (sample.showsNoDrawing()) {
                awaitingClear = false;
                hasClearTime = true;
                clearTime = sample.time;
            }
            return;
        }
        if (sample.clear) {
            if (attempt) {
                // Clearing without an advance is not a proven submission.
                emit(GL_INPUT_EVENT_UNCHECKED, *attempt, sample.time, GL_INPUT_REASON_AMBIGUOUS_BOUNDARY);
                attempt.reset();
            }
            hasClearTime = true;
            clearTime = sample.time;
        } else if (!attempt && hasIndex) {
            begin(index, gc_opt_double{hasClearTime, hasClearTime ? clearTime : 0}, sample.time, context,
                  &sample.edges);
            hasClearTime = false;
        } else if (attempt) {
            emit(GL_INPUT_EVENT_DRAWING_SAMPLE, *attempt, sample.time, GL_INPUT_REASON_NONE, nullptr, &sample.edges);
        }
    }

    void begin(int64_t slotIndex, gc_opt_double start, double time, const gl_input_context &context,
               const std::vector<EdgeEvidence> *edges) {
        const int64_t expectedCount = context.hasExpectedSlotCount ? context.expectedSlotCount : 0;
        if (!(slotIndex < expectedCount - 1)) return;
        const gl_input_slot *slot = nullptr;
        for (int32_t i = 0; i < context.slotObservationCount; ++i) {
            if (context.slots[i].index == slotIndex) {
                slot = &context.slots[i];
                break;
            }
        }
        if (slot == nullptr || !slot->isConfirmed || slot->glyph < 0 || size_t(slot->glyph) >= templates.size()) {
            return;
        }
        nextAttemptID += 1;
        std::unique_ptr<Attempt> drawing(new Attempt{slotIndex, nextAttemptID, slot->glyph, templates[size_t(slot->glyph)],
                                                     start, gc_opt_double{false, 0}, {}, false, Result()});
        attempt = std::move(drawing);
        if (start.has) {
            bool found = false;
            for (const Result &result : results) {
                if (result.slotIndex == slotIndex) found = true;
            }
            if (found) {
                removeResults([&](const Result &r) { return r.slotIndex == slotIndex; });
                revision += 1;
            }
        }
        emit(GL_INPUT_EVENT_STARTED, *attempt, time, start.has ? GL_INPUT_REASON_NONE : GL_INPUT_REASON_MISSED_START,
             nullptr, edges);
    }

    struct Run {
        gl_input_edge_set edges;
        std::vector<const gl_input_sample *> samples;
    };

    static bool holds(const Run &run, int64_t samples, double span) {
        if (run.samples.empty()) return false;
        const double first = run.samples.front()->time, last = run.samples.back()->time;
        return int64_t(run.samples.size()) >= samples && last - first + 1e-9 >= span;
    }

    /// The verdict the post-lift samples support so far; false while an open
    /// window supports none yet.
    bool assessment(const Attempt &drawing, bool closed, Outcome &out) const {
        std::vector<Run> runs;
        for (const gl_input_sample &sample : drawing.samples) {
            if (!runs.empty() && edgeSetEqual(runs.back().edges, sample.edges)) {
                runs.back().samples.push_back(&sample);
            } else {
                runs.push_back(Run{sample.edges, {&sample}});
            }
        }
        // An empty set is ink without any lattice edge: not a reading of the drawing.
        std::vector<const Run *> stable;
        for (const Run &run : runs) {
            if (!edgeSetEmpty(run.edges) && holds(run, policy.minimumSamples, policy.minimumSpan)) {
                stable.push_back(&run);
            }
        }
        std::vector<gl_input_edge_set> readings;
        for (const Run *run : stable) {
            bool seen = false;
            for (const gl_input_edge_set &reading : readings) {
                if (edgeSetEqual(reading, run->edges)) seen = true;
            }
            if (!seen) readings.push_back(run->edges);
        }
        if (readings.size() > 1) {
            out = {GL_INPUT_VERDICT_UNAVAILABLE, GL_INPUT_REASON_DISAGREEING_SAMPLES};
            return true;
        }
        if (readings.size() == 1 && edgeSetEqual(readings[0], drawing.expected)) {
            out = {GL_INPUT_VERDICT_MATCHED, GL_INPUT_REASON_NONE};
            return true;
        }
        if (!closed) return false;
        bool anyDiffering = false;
        for (const Run *run : stable) {
            if (holds(*run, policy.minimumDifferingSamples, policy.minimumDifferingSpan)) anyDiffering = true;
        }
        if (!anyDiffering) {
            out = {GL_INPUT_VERDICT_UNAVAILABLE, GL_INPUT_REASON_SHORT_WINDOW};
            return true;
        }
        // Every stable run has the same reading here. Partial support in any
        // stable run makes a missing edge uncertain.
        bool undecided = false;
        for (const Run *run : stable) {
            const gl_input_edge_set missing = edgeSetSubtracting(drawing.expected, run->edges);
            for (const gl_input_sample *sample : run->samples) {
                if (!edgeSetDisjoint(sample->partialEdges, missing)) undecided = true;
            }
        }
        out = undecided ? Outcome{GL_INPUT_VERDICT_UNAVAILABLE, GL_INPUT_REASON_PARTIAL_EDGE}
                        : Outcome{GL_INPUT_VERDICT_DIFFERS, GL_INPUT_REASON_NONE};
        return true;
    }

    Result makeResult(const Attempt &drawing, gl_input_verdict verdict, gl_input_reason reason, double time,
                      gl_input_window_end windowEnd) const {
        // An unchanged verdict keeps the time it was first shown.
        const bool unchanged =
            drawing.hasPublished && drawing.published.verdict == verdict && drawing.published.reason == reason;
        Result result;
        result.sessionID = sessionID;
        result.hackID = hasHackID ? hackID : 0;
        result.slotIndex = drawing.index;
        result.attemptID = drawing.id;
        result.expectedGlyph = drawing.glyph;
        result.verdict = verdict;
        result.reason = reason;
        result.sourceTime = unchanged ? drawing.published.sourceTime : time;
        result.startTime = drawing.start;
        result.liftTime = drawing.lift;
        result.samples = drawing.samples;
        result.windowEnd = windowEnd;
        return result;
    }

    void store(const Result &result) {
        const int64_t slotIndex = result.slotIndex;
        removeResults([&](const Result &r) { return r.slotIndex == slotIndex; });
        // Insert keeping slot order; results are already sorted and hold no
        // other entry for this slot, so this is Swift's append-then-sort.
        size_t position = results.size();
        for (size_t i = 0; i < results.size(); ++i) {
            if (results[i].slotIndex > slotIndex) {
                position = i;
                break;
            }
        }
        results.insert(results.begin() + std::ptrdiff_t(position), result);
        revision += 1;
    }

    void complete(const Attempt &drawing, gl_input_verdict verdict, gl_input_reason reason, double time,
                  gl_input_window_end windowEnd = GL_INPUT_WINDOW_END_INTERRUPTED) {
        Result result = makeResult(drawing, verdict, reason, time, windowEnd);
        store(result);
        emit(GL_INPUT_EVENT_FINISHED, drawing, time, reason, &result);
    }

    /// Ends the open attempt without a clear.
    void end(gl_input_reason reason, double time, bool showingUnavailable) {
        if (!attempt) return;
        std::unique_ptr<Attempt> drawing = std::move(attempt);
        if (!drawing->lift.has) {
            emit(GL_INPUT_EVENT_UNCHECKED, *drawing, time, reason);
        } else if (drawing->hasPublished) {
            complete(*drawing, drawing->published.verdict, drawing->published.reason, time);
        } else if (showingUnavailable) {
            complete(*drawing, GL_INPUT_VERDICT_UNAVAILABLE, reason, time);
        } else {
            emit(GL_INPUT_EVENT_UNCHECKED, *drawing, time, reason);
        }
    }

    void invalidate(gl_input_reason reason, double time) {
        end(reason, time, true);
        discardAttempt();
    }

    void discardAttempt() {
        attempt.reset();
        hasIndex = false;
        hasClearTime = false;
        hasPendingIndex = false;
        pendingSample.reset();
        awaitingClear = false;
    }

    void emit(gl_input_event_kind kind, const Attempt &drawing, double time,
              gl_input_reason reason = GL_INPUT_REASON_NONE, const Result *result = nullptr,
              const std::vector<EdgeEvidence> *edges = nullptr) {
        Event event{kind, time, hasHackID ? hackID : 0, drawing.index, drawing.id, reason, result != nullptr,
                    result != nullptr ? *result : Result(), edges != nullptr ? *edges : std::vector<EdgeEvidence>()};
        events.push_back(std::move(event));
    }

    // MARK: ABI views

    static gl_input_result view(const Result &result) {
        return gl_input_result{result.sessionID, result.hackID, result.slotIndex, result.attemptID,
                               result.expectedGlyph, result.verdict, result.reason, result.sourceTime,
                               result.startTime, result.liftTime,
                               result.samples.empty() ? nullptr : result.samples.data(),
                               int32_t(result.samples.size()), result.windowEnd};
    }

    const gl_input_event *eventView(int32_t *count) {
        eventViews.clear();
        eventEvidenceViews.assign(events.size(), {});
        for (size_t i = 0; i < events.size(); ++i) {
            const Event &event = events[i];
            std::vector<gl_input_edge_evidence> &evidence = eventEvidenceViews[i];
            for (const EdgeEvidence &edge : event.edgeEvidence) {
                evidence.push_back(gl_input_edge_evidence{edge.lower, edge.upper,
                    edge.samples.empty() ? nullptr : edge.samples.data(), int32_t(edge.samples.size())});
            }
            gl_input_event item{};
            item.kind = event.kind;
            item.time = event.time;
            item.hackID = event.hackID;
            item.slotIndex = event.slotIndex;
            item.attemptID = event.attemptID;
            item.reason = event.reason;
            item.hasResult = event.hasResult;
            if (event.hasResult) item.result = view(event.result);
            item.edgeEvidence = evidence.empty() ? nullptr : evidence.data();
            item.edgeEvidenceCount = int32_t(evidence.size());
            eventViews.push_back(item);
        }
        *count = int32_t(eventViews.size());
        return eventViews.empty() ? nullptr : eventViews.data();
    }

    const gl_input_result *resultView(int32_t *count) {
        resultViews.clear();
        for (const Result &result : results) resultViews.push_back(view(result));
        *count = int32_t(resultViews.size());
        return resultViews.empty() ? nullptr : resultViews.data();
    }
};

extern "C" {

gl_input_policy gl_input_policy_default(void) {
    return gl_input_policy{3, 0.1, 5, 0.2, 0.3, 0.1};
}

gl_input_validator *gl_input_validator_create(const gl_input_edge_set *expectedEdges, int32_t glyphCount,
                                              uint64_t sessionID, const gl_input_policy *policy) {
    if (glyphCount < 0 || (glyphCount > 0 && expectedEdges == nullptr) || policy == nullptr) return nullptr;
    gl_input_validator *validator = new (std::nothrow) gl_input_validator();
    if (validator == nullptr) return nullptr;
    validator->sessionID = sessionID;
    validator->policy = *policy;
    validator->templates.assign(expectedEdges, expectedEdges + glyphCount);
    return validator;
}

void gl_input_validator_destroy(gl_input_validator *validator) { delete validator; }

static bool acceptArgumentsValid(const gl_input_validator *validator, const gl_input_frame *frame,
                                 const gl_input_context *context, const gl_input_edge_evidence *edgeEvidence,
                                 int32_t edgeEvidenceCount, const int32_t *eventCount) {
    return validator != nullptr && frame != nullptr && context != nullptr && eventCount != nullptr &&
           edgeEvidenceCount >= 0 && (edgeEvidenceCount == 0 || edgeEvidence != nullptr) &&
           context->slotObservationCount >= 0 && (context->slotObservationCount == 0 || context->slots != nullptr);
}

const gl_input_event *gl_input_validator_accept(gl_input_validator *validator, const gl_input_frame *frame,
                                                const gl_input_context *context,
                                                const gl_input_edge_evidence *edgeEvidence,
                                                int32_t edgeEvidenceCount, int32_t *eventCount) {
    if (!acceptArgumentsValid(validator, frame, context, edgeEvidence, edgeEvidenceCount, eventCount)) {
        if (eventCount != nullptr) *eventCount = 0;
        return nullptr;
    }
    validator->accept(*frame, *context, edgeEvidence, edgeEvidenceCount);
    return validator->eventView(eventCount);
}

const gl_input_event *gl_input_validator_accept_tracker(gl_input_validator *validator,
                                                        uint64_t trackerSessionID,
                                                        const gl_input_frame *frame,
                                                        const gl_input_context *context,
                                                        const gl_input_edge_evidence *edgeEvidence,
                                                        int32_t edgeEvidenceCount, int32_t *eventCount) {
    if (!acceptArgumentsValid(validator, frame, context, edgeEvidence, edgeEvidenceCount, eventCount)) {
        if (eventCount != nullptr) *eventCount = 0;
        return nullptr;
    }
    // Swift returns [] here without touching the validator's state.
    if (trackerSessionID != validator->sessionID) {
        *eventCount = 0;
        return nullptr;
    }
    validator->accept(*frame, *context, edgeEvidence, edgeEvidenceCount);
    return validator->eventView(eventCount);
}

const gl_input_event *gl_input_validator_finish(gl_input_validator *validator, double time, int32_t *eventCount) {
    if (validator == nullptr || eventCount == nullptr) {
        if (eventCount != nullptr) *eventCount = 0;
        return nullptr;
    }
    validator->finish(time);
    return validator->eventView(eventCount);
}

const gl_input_result *gl_input_validator_results(gl_input_validator *validator, int32_t *count) {
    if (validator == nullptr || count == nullptr) {
        if (count != nullptr) *count = 0;
        return nullptr;
    }
    return validator->resultView(count);
}

int64_t gl_input_validator_revision(const gl_input_validator *validator) {
    return validator == nullptr ? 0 : validator->revision;
}

}  // extern "C"
