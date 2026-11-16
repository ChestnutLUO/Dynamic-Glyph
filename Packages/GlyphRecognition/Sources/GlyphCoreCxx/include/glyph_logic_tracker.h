#ifndef GLYPH_LOGIC_TRACKER_H
#define GLYPH_LOGIC_TRACKER_H

/*
 * GlyphCore logic layer, area "tracker". Follows the conventions in
 * glyph_common.h. The Swift types this mirrors are the oracle; the
 * equivalence tests in Tests/GlyphRecognitionTests/Cxx hold both to the same
 * output.
 *
 * Swift oracles, in Sources/GlyphRecognition: PresentationTracker.swift
 * (`PresentationTracker`, `TrackingState`), SlotObservation.swift
 * (`SlotObservation`, `TrackingEvent`), GamePhaseEvidence.swift
 * (`CaptureSessionID`, `GamePhase`, `PhaseSource`, `HeaderReading`,
 * `HeaderPhraseMatcher`, `ShapeEvidence`, `FrameEvidence`) and
 * SlotStripReader.swift (`SlotStripReading`, `SlotStripRejection`).
 *
 * Glyphs are indices into the name-sorted list the caller passes to
 * `gl_tracker_create` (`GlyphTable.glyphs`). The tracker compares them by
 * index, sorts them by index (which is by name, the list being sorted) and
 * names them from that list where a reason string lists them. An index
 * outside the list is "no Glyph".
 */

#include "glyph_common.h"
#include "glyph_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Enums                                                                     */

/** `GamePhase`. */
typedef enum gl_game_phase {
    GL_GAME_PHASE_UNKNOWN = 0,
    GL_GAME_PHASE_COMMAND,
    GL_GAME_PHASE_PRESENTING,
    GL_GAME_PHASE_INPUT,
    GL_GAME_PHASE_COMPLETED
} gl_game_phase;

/** `TrackingState`. */
typedef enum gl_tracking_state {
    GL_TRACKING_STATE_INACTIVE = 0,
    GL_TRACKING_STATE_COMMAND,
    GL_TRACKING_STATE_PRESENTING,
    GL_TRACKING_STATE_INPUT,
    GL_TRACKING_STATE_COMPLETED,
    GL_TRACKING_STATE_INTERRUPTED
} gl_tracking_state;

/** `PhaseSource`, in declaration order: Swift's own `.none` case is last
 *  and is not an optional. */
typedef enum gl_phase_source {
    GL_PHASE_SOURCE_HEADER_TEXT = 0,
    GL_PHASE_SOURCE_RETAINED,
    GL_PHASE_SOURCE_INPUT_TIMER,
    GL_PHASE_SOURCE_PARTIAL_INPUT_TIMER,
    GL_PHASE_SOURCE_INDICATOR_TRANSITION,
    GL_PHASE_SOURCE_NONE
} gl_phase_source;

/** `SlotStripRejection?`. */
typedef enum gl_slot_rejection {
    GL_SLOT_REJECTION_NONE = 0,
    GL_SLOT_REJECTION_BAND_UNAVAILABLE,
    GL_SLOT_REJECTION_NO_MARKERS,
    GL_SLOT_REJECTION_TOO_MANY_MARKERS,
    GL_SLOT_REJECTION_UNEVEN_SPACING,
    GL_SLOT_REJECTION_INCONSISTENT_MARKER_WIDTHS,
    GL_SLOT_REJECTION_MULTIPLE_HIGHLIGHTS,
    GL_SLOT_REJECTION_INCOMPLETE_MARKER_HEIGHT,
    GL_SLOT_REJECTION_INCOMPLETE_STRIP,
    GL_SLOT_REJECTION_COVERED_BY_OVERLAY
} gl_slot_rejection;

/** `ShapeEvidence.Kind`. */
typedef enum gl_shape_kind {
    GL_SHAPE_KIND_UNAVAILABLE = 0,
    GL_SHAPE_KIND_NO_STROKE,
    GL_SHAPE_KIND_UNRECOGNIZED_STROKE,
    GL_SHAPE_KIND_UNEXPLAINED_INK,
    GL_SHAPE_KIND_AMBIGUOUS_SHAPE,
    GL_SHAPE_KIND_UNIQUE_VISIBLE_SHAPE
} gl_shape_kind;

/** `SlotObservation.Status`. */
typedef enum gl_slot_status {
    GL_SLOT_STATUS_PENDING = 0,
    GL_SLOT_STATUS_OBSERVING,
    GL_SLOT_STATUS_CONFIRMED,
    GL_SLOT_STATUS_INFERRED,
    GL_SLOT_STATUS_MISSING,
    GL_SLOT_STATUS_UNCERTAIN
} gl_slot_status;

/** `TrackingEvent.Kind`. */
typedef enum gl_tracking_event_kind {
    GL_TRACKING_EVENT_PHASE_CHANGED = 0,
    GL_TRACKING_EVENT_HACK_STARTED,
    GL_TRACKING_EVENT_SLOT_ADVANCED,
    GL_TRACKING_EVENT_SLOT_COMMITTED,
    GL_TRACKING_EVENT_SLOT_INFERRED,
    GL_TRACKING_EVENT_SLOT_MISSING,
    GL_TRACKING_EVENT_SLOT_UNCERTAIN,
    GL_TRACKING_EVENT_EVIDENCE_INVALIDATED,
    GL_TRACKING_EVENT_SLOT_COUNT_CONFLICT,
    GL_TRACKING_EVENT_SEQUENCE_FROZEN,
    GL_TRACKING_EVENT_HACK_COMPLETED,
    GL_TRACKING_EVENT_STALE_EVIDENCE_REJECTED
} gl_tracking_event_kind;

/* ------------------------------------------------------------------------ */
/* Values                                                                    */

/** `HeaderReading`. `matchedText` is only carried; the tracker reads the
 *  phase and `sourceTime`. */
typedef struct gl_header_reading {
    gl_game_phase phase;
    gc_string matchedText;
    double confidence;
    double sourceTime;
} gl_header_reading;

/** `SlotStripReading`. `markerCentersX` holds `markerCount` fractions of the
 *  frame width, left to right, owned by the caller for the call. */
typedef struct gl_slot_strip_reading {
    int32_t slotCount;
    gc_opt_int32 highlightedIndex;
    const double *markerCentersX;
    int32_t markerCount;
    bool hasInputTimerBar;
    bool isPartlyCovered;
} gl_slot_strip_reading;

/** `PartialSlotStripReading`. `markerCentersX` holds `markerCount`
 *  fractions of the frame width, left to right, owned by the caller for the
 *  call. */
typedef struct gl_partial_slot_reading {
    const double *markerCentersX;
    int32_t markerCount;
    gc_opt_int32 highlightedMarker;
    double coveredFrom;
    double coveredTo;
    double centerPitch;
    double centerTolerance;
} gl_partial_slot_reading;

/** `PartialSlotStripReading.resolved(slotCount:)`. False for nil; otherwise
 *  the slot of each visible indicator in `slotIndices`, which has room for
 *  `markerCount` of them, and the highlighted one's slot in
 *  `highlightedIndex`. */
bool gl_partial_slot_resolve(const gl_partial_slot_reading *reading, int32_t slotCount, int32_t *slotIndices,
                             gc_opt_int32 *highlightedIndex);

/** `ShapeEvidence`. `glyph` is -1 unless the kind is a unique visible shape.
 *  `edges` is the set of undirected node pairs (nodes 0...10; duplicates
 *  count once). `extensions` are Glyph indices; the tracker carries them in
 *  the ABI for completeness and does not read them, as Swift does not. */
typedef struct gl_shape_evidence {
    gl_shape_kind kind;
    int32_t glyph;
    const gc_edge *edges;
    int32_t edgeCount;
    const int32_t *extensions;
    int32_t extensionCount;
} gl_shape_evidence;

/** `FrameEvidence`. Optionals are `has` flags. As in Swift's initializer,
 *  the frame has an input timer bar when `hasInputTimerBar` is set or the
 *  slot reading says so. */
typedef struct gl_frame_evidence {
    uint64_t sessionID;
    double time;
    bool hasHeader;
    gl_header_reading header;
    bool hasSlots;
    gl_slot_strip_reading slots;
    gl_slot_rejection slotRejection;
    gl_shape_evidence shape;
    bool hasValidCalibration;
    bool hasInputTimerBar;
    bool hasPartialSlots;
    gl_partial_slot_reading partialSlots;
    bool hasPartialInputTimerBar;
} gl_frame_evidence;

/** `PresentationTracker.Policy`, field for field. */
typedef struct gl_tracking_policy {
    double minimumStableInterval;
    int32_t minimumStableSamples;
    double maximumFrameGap;
    double unknownPhaseGrace;
    double stalenessThreshold;
    int32_t slotCountVotesRequired;
    double indicatorObstructionGrace;
    double minimumBlankInterval;
    bool entersPresentationFromIndicators;
    bool closesLastSlotOnRelease;
    double minimumStripAbsenceForNewHack;
} gl_tracking_policy;

/** `PresentationTracker.Policy()`. */
gl_tracking_policy gl_tracking_policy_default(void);

/** `TrackingEvent`. `glyph` is -1 for none. `reason` is owned by the
 *  tracker, valid until its next `gl_tracker_accept`, `gl_tracker_reset` or
 *  `gl_tracker_destroy`. */
typedef struct gl_tracking_event {
    gl_tracking_event_kind kind;
    double time;
    int64_t hackID;
    gc_opt_int32 slotIndex;
    int32_t glyph;
    gc_string reason;
    int64_t sampleCount;
} gl_tracking_event;

/** `SlotObservation`. `glyph` is -1 for none. `alternatives` and
 *  `boundaryReason` point into the tracker, valid until its next
 *  `gl_tracker_accept`, `gl_tracker_invalidate_phase`, `gl_tracker_reset`
 *  or `gl_tracker_destroy`. */
typedef struct gl_slot_observation {
    int32_t index;
    gl_slot_status status;
    int32_t glyph;
    const int32_t *alternatives;
    int32_t alternativeCount;
    gc_opt_double firstSampleTime;
    gc_opt_double lastSampleTime;
    int64_t sampleCount;
    bool hasBoundaryReason;
    gc_string boundaryReason;
} gl_slot_observation;

/* ------------------------------------------------------------------------ */
/* PresentationTracker                                                       */

typedef struct gl_tracker gl_tracker;

/** `PresentationTracker(sessionID:policy:)`. `glyphNames` is the name-sorted
 *  Glyph list (`GlyphTable.glyphs`), copied; evidence and events index it.
 *  A NULL policy is the default. Returns NULL for a negative count or a
 *  NULL list with a positive count. */
gl_tracker *gl_tracker_create(uint64_t sessionID, const gl_tracking_policy *policy, const gc_string *glyphNames,
                              int32_t glyphCount);
void gl_tracker_destroy(gl_tracker *tracker);

/** `reset()`. */
void gl_tracker_reset(gl_tracker *tracker);

/** `accept(_:)`. Writes up to `capacity` events to `out` and returns how many
 *  the frame produced; when that exceeds `capacity`, the rest are read with
 *  `gl_tracker_last_events`. Returns 0 for a NULL tracker or evidence. */
int32_t gl_tracker_accept(gl_tracker *tracker, const gl_frame_evidence *evidence, gl_tracking_event *out,
                          int32_t capacity);

/** The events of the last `gl_tracker_accept`, again: up to `capacity` of them
 *  into `out`; returns how many there are. */
int32_t gl_tracker_last_events(const gl_tracker *tracker, gl_tracking_event *out, int32_t capacity);

/** `invalidatePhase()`. */
void gl_tracker_invalidate_phase(gl_tracker *tracker);

uint64_t gl_tracker_session_id(const gl_tracker *tracker);
gl_tracking_policy gl_tracker_policy(const gl_tracker *tracker);
gl_tracking_state gl_tracker_state(const gl_tracker *tracker);
gl_phase_source gl_tracker_phase_source(const gl_tracker *tracker);
int64_t gl_tracker_hack_id(const gl_tracker *tracker);
int64_t gl_tracker_revision(const gl_tracker *tracker);
gc_opt_double gl_tracker_last_evidence_time(const gl_tracker *tracker);
gc_opt_double gl_tracker_last_phase_time(const gl_tracker *tracker);
gc_opt_double gl_tracker_last_indicator_time(const gl_tracker *tracker);
gc_opt_int32 gl_tracker_expected_slot_count(const gl_tracker *tracker);
gc_opt_int32 gl_tracker_current_slot_index(const gl_tracker *tracker);
gc_opt_int32 gl_tracker_input_slot_index(const gl_tracker *tracker);
bool gl_tracker_indicators_obstructed(const gl_tracker *tracker);
bool gl_tracker_slot_count_conflict(const gl_tracker *tracker);
bool gl_tracker_is_frozen(const gl_tracker *tracker);
bool gl_tracker_observed_presentation_for_current_hack(const gl_tracker *tracker);

/** `slots`: up to `capacity` observations into `out`; returns the count. */
int32_t gl_tracker_slots(const gl_tracker *tracker, gl_slot_observation *out, int32_t capacity);

/** `confirmedPrefix`: up to `capacity` Glyph indices into `out`; returns the
 *  prefix length. */
int32_t gl_tracker_confirmed_prefix(const gl_tracker *tracker, int32_t *out, int32_t capacity);

/* ------------------------------------------------------------------------ */
/* HeaderPhraseMatcher                                                       */

/** `HeaderPhraseMatcher.Phrase`. `words` are already normalized, as the
 *  packs store them. */
typedef struct gl_header_phrase {
    gl_game_phase phase;
    const gc_string *words;
    int32_t wordCount;
    bool requiresExactMatch;
    bool matchesWithin;
} gl_header_phrase;

/** One recognized line: `(text: String, confidence: Double)`. */
typedef struct gl_header_line {
    gc_string text;
    double confidence;
} gl_header_line;

typedef struct gl_header_matcher gl_header_matcher;

/** `HeaderPhraseMatcher(phrases:minimumConfidence:)`; the phrases are copied.
 *  Pass `GameText(language).headerPhrases` and
 *  `language.confidence.header` for `HeaderPhraseMatcher(language:)`.
 *  Returns NULL for a negative count or a NULL array with a positive count. */
gl_header_matcher *gl_header_matcher_create(const gl_header_phrase *phrases, int32_t count,
                                            double minimumConfidence);
void gl_header_matcher_destroy(gl_header_matcher *matcher);

/** `read(lines:)`. `matchedText` is owned by the matcher, valid until its
 *  next call. `sourceTime` is 0, as Swift's reading is. A NULL matcher
 *  reads unknown. */
gl_header_reading gl_header_matcher_read(gl_header_matcher *matcher, const gl_header_line *lines, int32_t count);

#ifdef __cplusplus
}
#endif

#endif /* GLYPH_LOGIC_TRACKER_H */
