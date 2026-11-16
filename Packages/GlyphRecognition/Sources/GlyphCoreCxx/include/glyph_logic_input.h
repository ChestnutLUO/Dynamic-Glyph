#ifndef GLYPH_LOGIC_INPUT_H
#define GLYPH_LOGIC_INPUT_H

/*
 * GlyphCore logic layer, area "input". Follows the conventions in
 * glyph_common.h. The Swift types this mirrors are the oracle; the
 * equivalence tests in Tests/GlyphRecognitionTests/Cxx hold both to the same
 * output.
 *
 * Two objects:
 * - `gl_input_validator`: `PlayerInputValidator` (PlayerInputValidator.swift).
 *   It does not see the presentation tracker: the caller passes the values
 *   `PlayerInputValidator.Context` reads from it, and the parts of
 *   `FrameEvidence` the validator reads, as plain structs.
 * - `gl_sequence_predictor`: `SequencePredictor.outlook` (SequencePredictor.swift,
 *   SequenceOutlook.swift) over the sequence table given at creation.
 *
 * Swift `Int` values cross as int64_t, so nothing is narrowed.
 */

#include "glyph_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Shared values                                                             */

/** A `Set<GlyphPath.Edge>`: bit `lower * 11 + upper` (node raw values 0...10,
 *  lower <= upper) of the 128-bit mask, `bits[0]` holding bits 0...63. */
typedef struct gl_input_edge_set {
    uint64_t bits[2];
} gl_input_edge_set;

/** `GlyphEdgeEvidence`: the edge and its samples. Coverage and presence are
 *  computed from the samples as the Swift properties do. */
typedef struct gl_input_edge_evidence {
    uint8_t lower;
    uint8_t upper;
    const double *samples;
    int32_t sampleCount;
} gl_input_edge_evidence;

/* ------------------------------------------------------------------------ */
/* Player input validation (reference: PlayerInputValidator.swift)           */

/** `InputCheckVerdict`. */
typedef enum gl_input_verdict {
    GL_INPUT_VERDICT_MATCHED = 0,
    GL_INPUT_VERDICT_DIFFERS,
    GL_INPUT_VERDICT_UNAVAILABLE
} gl_input_verdict;

/** `InputCheckUnavailableReason`, with NONE for a nil reason. */
typedef enum gl_input_reason {
    GL_INPUT_REASON_NONE = 0,
    GL_INPUT_REASON_MISSED_START,
    GL_INPUT_REASON_UNCONFIRMED_EXPECTATION,
    GL_INPUT_REASON_LAST_SLOT,
    GL_INPUT_REASON_MULTI_SLOT_JUMP,
    GL_INPUT_REASON_BACKWARD_MOVE,
    GL_INPUT_REASON_SHORT_WINDOW,
    GL_INPUT_REASON_DISAGREEING_SAMPLES,
    GL_INPUT_REASON_FRAME_GAP,
    GL_INPUT_REASON_STRIP_LOSS,
    GL_INPUT_REASON_PHASE_CHANGE,
    GL_INPUT_REASON_INVALID_CALIBRATION,
    GL_INPUT_REASON_SLOT_COUNT_CONFLICT,
    GL_INPUT_REASON_AMBIGUOUS_BOUNDARY,
    GL_INPUT_REASON_END_OF_STREAM,
    GL_INPUT_REASON_UNCLOSED_WINDOW,
    GL_INPUT_REASON_PARTIAL_EDGE
} gl_input_reason;

/** `InputCheckWindowEnd`. */
typedef enum gl_input_window_end {
    GL_INPUT_WINDOW_END_OPEN = 0,
    GL_INPUT_WINDOW_END_CLEAR_ARRAY,
    GL_INPUT_WINDOW_END_INTERRUPTED
} gl_input_window_end;

/** `InputCheckEvent.Kind`. */
typedef enum gl_input_event_kind {
    GL_INPUT_EVENT_STARTED = 0,
    GL_INPUT_EVENT_DRAWING_SAMPLE,
    GL_INPUT_EVENT_LIFTED,
    GL_INPUT_EVENT_SAMPLE,
    GL_INPUT_EVENT_VERDICT,
    GL_INPUT_EVENT_FINISHED,
    GL_INPUT_EVENT_UNCHECKED
} gl_input_event_kind;

/** `PlayerInputValidator.Policy`, field for field. */
typedef struct gl_input_policy {
    int64_t minimumSamples;
    double minimumSpan;
    int64_t minimumDifferingSamples;
    double minimumDifferingSpan;
    double minimumPartialCoverage;
    double maximumFrameGap;
} gl_input_policy;

/** `PlayerInputValidator.Policy()`'s values. */
gl_input_policy gl_input_policy_default(void);

/** `InputCheckSample`. */
typedef struct gl_input_sample {
    double time;
    gl_input_edge_set edges;
    gl_input_edge_set partialEdges;
} gl_input_sample;

/** `InputCheckResult`. `expectedGlyph` is a Glyph index; `samples` is owned by
 *  the validator (see the lifetime note on `gl_input_validator_accept`). */
typedef struct gl_input_result {
    uint64_t sessionID;
    int64_t hackID;
    int64_t slotIndex;
    int64_t attemptID;
    int32_t expectedGlyph;
    gl_input_verdict verdict;
    gl_input_reason reason;
    double sourceTime;
    gc_opt_double startTime;
    gc_opt_double liftTime;
    const gl_input_sample *samples;
    int32_t sampleCount;
    gl_input_window_end windowEnd;
} gl_input_result;

/** `InputCheckEvent`. `edgeEvidence` repeats the evidence the event was made
 *  from, samples included, owned by the validator. */
typedef struct gl_input_event {
    gl_input_event_kind kind;
    double time;
    int64_t hackID;
    int64_t slotIndex;
    int64_t attemptID;
    gl_input_reason reason;
    bool hasResult;
    gl_input_result result;
    const gl_input_edge_evidence *edgeEvidence;
    int32_t edgeEvidenceCount;
} gl_input_event;

/** What `accept` reads from `FrameEvidence`. */
typedef struct gl_input_frame {
    uint64_t sessionID;
    double time;
    /** `slots != nil`, then its `slotCount` and `highlightedIndex`. */
    bool hasSlots;
    int64_t slotCount;
    bool hasHighlightedIndex;
    int64_t highlightedIndex;
    /** `shape.kind != .unavailable` and `shape.kind == .noStroke`. */
    bool shapeAvailable;
    bool shapeNoStroke;
    bool hasValidCalibration;
} gl_input_frame;

/** What the validator reads from one `SlotObservation`. `glyph` is a Glyph
 *  index, -1 for nil or a Glyph outside the table. */
typedef struct gl_input_slot {
    int64_t index;
    bool isConfirmed;
    int32_t glyph;
} gl_input_slot;

/** `PlayerInputValidator.Context`, field for field; `isInputState` is
 *  `state == .input`. */
typedef struct gl_input_context {
    bool isInputState;
    int64_t hackID;
    const gl_input_slot *slots;
    int32_t slotObservationCount;
    bool hasExpectedSlotCount;
    int64_t expectedSlotCount;
    bool observedPresentation;
    bool slotCountConflict;
    bool indicatorsObstructed;
} gl_input_context;

typedef struct gl_input_validator gl_input_validator;

/** `PlayerInputValidator(table:sessionID:policy:)`. `expectedEdges[i]` is
 *  `GlyphFrameRecognizer(table:).expectedEdges(for:)` of the i-th Glyph of the
 *  name-sorted table, for `glyphCount` Glyphs. NULL when `glyphCount` is
 *  negative, `expectedEdges` is NULL with a positive count, or `policy` is NULL. */
gl_input_validator *gl_input_validator_create(const gl_input_edge_set *expectedEdges, int32_t glyphCount,
                                              uint64_t sessionID, const gl_input_policy *policy);
void gl_input_validator_destroy(gl_input_validator *validator);

/** `accept(_:context:edgeEvidence:)`. Writes the returned events' count and
 *  returns them. Events, results and every array they point to are owned by
 *  the validator and valid until its next accept, finish or destroy. Returns
 *  NULL with a zero count when an argument is NULL (and changes nothing). */
const gl_input_event *gl_input_validator_accept(gl_input_validator *validator, const gl_input_frame *frame,
                                                const gl_input_context *context,
                                                const gl_input_edge_evidence *edgeEvidence,
                                                int32_t edgeEvidenceCount, int32_t *eventCount);

/** `accept(_:tracker:edgeEvidence:)`: as above, after checking the tracker's
 *  session ID against the validator's. */
const gl_input_event *gl_input_validator_accept_tracker(gl_input_validator *validator,
                                                        uint64_t trackerSessionID,
                                                        const gl_input_frame *frame,
                                                        const gl_input_context *context,
                                                        const gl_input_edge_evidence *edgeEvidence,
                                                        int32_t edgeEvidenceCount, int32_t *eventCount);

/** `finish(at:)`. Same ownership as accept. */
const gl_input_event *gl_input_validator_finish(gl_input_validator *validator, double time,
                                                int32_t *eventCount);

/** `results`, in slot order. Valid until the next accept, finish or destroy. */
const gl_input_result *gl_input_validator_results(gl_input_validator *validator, int32_t *count);

/** `revision`. */
int64_t gl_input_validator_revision(const gl_input_validator *validator);

/* ------------------------------------------------------------------------ */
/* Sequence prediction (reference: SequencePredictor.swift,                  */
/* SequenceOutlook.swift)                                                    */

/** `PredictionState`. */
typedef enum gl_prediction_state {
    GL_PREDICTION_STATE_UNAVAILABLE = 0,
    GL_PREDICTION_STATE_UNOBSERVED,
    GL_PREDICTION_STATE_AMBIGUOUS,
    GL_PREDICTION_STATE_RESOLVED,
    GL_PREDICTION_STATE_CONTRADICTED,
    GL_PREDICTION_STATE_LENGTH_CONFLICT
} gl_prediction_state;

/** A Glyph index list. */
typedef struct gl_glyph_list {
    const int32_t *glyphs;
    int32_t count;
} gl_glyph_list;

/** `SequenceCandidate`. */
typedef struct gl_sequence_candidate {
    gl_glyph_list glyphs;
    double weight;
} gl_sequence_candidate;

/** `SequenceOutlook`, field for field. Arrays are owned by the predictor and
 *  valid until its next outlook or destroy. */
typedef struct gl_sequence_outlook {
    gl_prediction_state state;
    gl_glyph_list observed;
    bool hasExpectedLength;
    int64_t expectedLength;
    int64_t candidateCount;
    const gl_sequence_candidate *candidates;
    int32_t shownCandidateCount;
    gl_glyph_list predictedSuffix;
    const gl_glyph_list *suffixAlternatives;
    int32_t suffixAlternativeCount;
    bool observationMayBeComplete;
} gl_sequence_outlook;

typedef struct gl_sequence_predictor gl_sequence_predictor;

/** `SequencePredictor(table: SequenceTable(sequences:))`. The vocabulary is
 *  `names[0..<nameCount]`, sorted as Swift sorts `GlyphID`; Glyph indices in
 *  this object's calls are indices into it. The predictor's display order
 *  compares the names' UTF-8 bytes, which is Swift's order for the
 *  table's (NFC) names. `sequences[i]` holds `sequenceLengths[i]` indices.
 *  Empty and repeated sequences are dropped, keeping first-seen order, as
 *  `SequenceTable` does. NULL when an index is out of range or a count is
 *  negative. */
gl_sequence_predictor *gl_sequence_predictor_create(const gc_string *names, int32_t nameCount,
                                                    const int32_t *const *sequences,
                                                    const int32_t *sequenceLengths, int32_t sequenceCount);
void gl_sequence_predictor_destroy(gl_sequence_predictor *predictor);

/** `outlook(observed:expectedLength:displayCandidateLimit:)`. An observed
 *  index of -1 (a Glyph outside the vocabulary) matches no sequence. Returns
 *  false, writing nothing, for a NULL argument (`observed` may be NULL when
 *  `observedCount` is 0), a negative count, or a negative limit. */
bool gl_sequence_predictor_outlook(gl_sequence_predictor *predictor, const int32_t *observed,
                                   int32_t observedCount, bool hasExpectedLength, int64_t expectedLength,
                                   int32_t displayCandidateLimit, gl_sequence_outlook *out);

#ifdef __cplusplus
}
#endif

#endif /* GLYPH_LOGIC_INPUT_H */
