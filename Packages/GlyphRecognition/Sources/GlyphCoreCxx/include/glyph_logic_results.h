#ifndef GLYPH_LOGIC_RESULTS_H
#define GLYPH_LOGIC_RESULTS_H

/*
 * GlyphCore logic layer, area "results". Follows the conventions in
 * glyph_common.h. The Swift types this mirrors are the oracle; the
 * equivalence tests in Tests/GlyphRecognitionTests/Cxx hold both to the same
 * output.
 *
 * Oracles, in Sources/GlyphRecognition: ResultTextParser, ResultFrameEvidence
 * (ResultTextLine, ResultReadContext, ResultFrameEvidence, HackResult),
 * HackResultTracker, ResultObservationSession, ResultEvidenceSchedule,
 * ValidatorResultComparison, HackResultSummary, HackResultPresentation (the
 * decisions, not the localized wording) and HackCommandSummary (the value and
 * CommandScreenWatch).
 *
 * Swift `Int` values (hack IDs, slot indices, attempt IDs, bonuses) cross as
 * int64_t so nothing is narrowed. Glyph names inside a ResultReadContext
 * cross as text: a context is a frozen record matched against OCR text, and
 * the tests build contexts with names outside any Glyph table. Glyphs taken
 * from the presentation tracker cross as indices into the Glyph list the
 * session was created with (glyph_common.h).
 *
 * String equality is bytewise. Swift compares strings by canonical
 * equivalence, which agrees for every Glyph name, command language code and
 * close reason the app produces (ASCII), and for any two strings in the same
 * Unicode normalization form.
 */

#include "glyph_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Enums, in Swift declaration order                                          */

/** `ResultSlotAppearance`. */
typedef enum gl_result_appearance {
    GL_RESULT_APPEARANCE_GOLD = 0,
    GL_RESULT_APPEARANCE_MAGENTA,
    GL_RESULT_APPEARANCE_UNREADABLE
} gl_result_appearance;

/** `GameSlotOutcome`. */
typedef enum gl_result_outcome {
    GL_RESULT_OUTCOME_ACCEPTED = 0,
    GL_RESULT_OUTCOME_REJECTED,
    GL_RESULT_OUTCOME_UNKNOWN
} gl_result_outcome;

/** `HackResult.State`. */
typedef enum gl_result_state {
    GL_RESULT_STATE_AWAITING = 0,
    GL_RESULT_STATE_PARTIAL,
    GL_RESULT_STATE_COMPLETE,
    GL_RESULT_STATE_NOT_OBSERVED
} gl_result_state;

/** `InputCheckVerdict`, optional where Swift has `InputCheckVerdict?`. */
typedef enum gl_result_verdict {
    GL_RESULT_VERDICT_NONE = 0,
    GL_RESULT_VERDICT_MATCHED,
    GL_RESULT_VERDICT_DIFFERS,
    GL_RESULT_VERDICT_UNAVAILABLE
} gl_result_verdict;

/** `ValidatorResultComparison.Status`. */
typedef enum gl_result_status {
    GL_RESULT_STATUS_AGREEMENT = 0,
    GL_RESULT_STATUS_DISAGREEMENT,
    GL_RESULT_STATUS_COVERAGE_GAP,
    GL_RESULT_STATUS_UNKNOWN_ASSOCIATION,
    GL_RESULT_STATUS_UNKNOWN_GAME_OUTCOME
} gl_result_status;

/** `HackCommand`, optional as `Selection.lastObserved` is. */
typedef enum gl_result_command {
    GL_RESULT_COMMAND_NONE = 0,
    GL_RESULT_COMMAND_SIMPLE,
    GL_RESULT_COMMAND_COMPLEX,
    GL_RESULT_COMMAND_REQUEST_KEY,
    GL_RESULT_COMMAND_NO_KEY,
    GL_RESULT_COMMAND_KEYS_ONLY
} gl_result_command;

/** `HackCommandSummary.Selection.Status`. */
typedef enum gl_result_selection_status {
    GL_RESULT_SELECTION_NO_COMMAND_OBSERVED = 0,
    GL_RESULT_SELECTION_CONFIRMED,
    GL_RESULT_SELECTION_UNRESOLVED,
    GL_RESULT_SELECTION_NOT_APPLICABLE
} gl_result_selection_status;

/** `HackCommandSummary.Mode`. */
typedef enum gl_result_command_mode {
    GL_RESULT_COMMAND_MODE_UNKNOWN = 0,
    GL_RESULT_COMMAND_MODE_PORTAL,
    GL_RESULT_COMMAND_MODE_DRONE
} gl_result_command_mode;

/** `ResultEvidenceSchedule.Selection?`. */
typedef enum gl_result_schedule_selection {
    GL_RESULT_SCHEDULE_NONE = 0,
    GL_RESULT_SCHEDULE_DETECTION,
    GL_RESULT_SCHEDULE_ANIMATION,
    GL_RESULT_SCHEDULE_DECISION,
    GL_RESULT_SCHEDULE_BUDGET_EXHAUSTED
} gl_result_schedule_selection;

/** `CommandScreenWatch.Action`. */
typedef enum gl_command_watch_action {
    GL_COMMAND_WATCH_ACTION_NONE = 0,
    GL_COMMAND_WATCH_ACTION_INTERRUPT,
    GL_COMMAND_WATCH_ACTION_CANCEL
} gl_command_watch_action;

/** `InputCheckEvent.Kind`. */
typedef enum gl_result_event_kind {
    GL_RESULT_EVENT_STARTED = 0,
    GL_RESULT_EVENT_DRAWING_SAMPLE,
    GL_RESULT_EVENT_LIFTED,
    GL_RESULT_EVENT_SAMPLE,
    GL_RESULT_EVENT_VERDICT,
    GL_RESULT_EVENT_FINISHED,
    GL_RESULT_EVENT_UNCHECKED
} gl_result_event_kind;

/** `GamePhase`. */
typedef enum gl_result_phase {
    GL_RESULT_PHASE_UNKNOWN = 0,
    GL_RESULT_PHASE_COMMAND,
    GL_RESULT_PHASE_PRESENTING,
    GL_RESULT_PHASE_INPUT,
    GL_RESULT_PHASE_COMPLETED
} gl_result_phase;

/** `SlotStripRejection?`. */
typedef enum gl_result_rejection {
    GL_RESULT_REJECTION_NONE = 0,
    GL_RESULT_REJECTION_BAND_UNAVAILABLE,
    GL_RESULT_REJECTION_NO_MARKERS,
    GL_RESULT_REJECTION_TOO_MANY_MARKERS,
    GL_RESULT_REJECTION_UNEVEN_SPACING,
    GL_RESULT_REJECTION_INCONSISTENT_MARKER_WIDTHS,
    GL_RESULT_REJECTION_MULTIPLE_HIGHLIGHTS,
    GL_RESULT_REJECTION_INCOMPLETE_MARKER_HEIGHT,
    GL_RESULT_REJECTION_INCOMPLETE_STRIP,
    GL_RESULT_REJECTION_COVERED_BY_OVERLAY
} gl_result_rejection;

/** `TrackingState`, the presentation tracker's state. */
typedef enum gl_result_tracking_state {
    GL_RESULT_TRACKING_INACTIVE = 0,
    GL_RESULT_TRACKING_COMMAND,
    GL_RESULT_TRACKING_PRESENTING,
    GL_RESULT_TRACKING_INPUT,
    GL_RESULT_TRACKING_COMPLETED,
    GL_RESULT_TRACKING_INTERRUPTED
} gl_result_tracking_state;

/** `SlotObservation.Status`. */
typedef enum gl_result_slot_status {
    GL_RESULT_SLOT_PENDING = 0,
    GL_RESULT_SLOT_OBSERVING,
    GL_RESULT_SLOT_CONFIRMED,
    GL_RESULT_SLOT_INFERRED,
    GL_RESULT_SLOT_MISSING,
    GL_RESULT_SLOT_UNCERTAIN
} gl_result_slot_status;

/** Which `HackResultSummary.headline` a summary shows. */
typedef enum gl_result_headline {
    GL_RESULT_HEADLINE_AWAITING = 0,
    GL_RESULT_HEADLINE_COMPLETE,
    GL_RESULT_HEADLINE_PARTIAL,
    /** `notObserved` closed by "captureStopped". */
    GL_RESULT_HEADLINE_STOPPED_BEFORE_RESULT,
    /** `notObserved` for any other reason. */
    GL_RESULT_HEADLINE_NO_RESULT_SCREEN
} gl_result_headline;

/* ------------------------------------------------------------------------ */
/* Values                                                                      */

/** A Swift `Int?`. */
typedef struct gl_result_opt_int {
    bool has;
    int64_t value;
} gl_result_opt_int;

/** A Swift `String?`. */
typedef struct gl_result_opt_string {
    bool has;
    gc_string value;
} gl_result_opt_string;

/** `HackCommandSummary.Selection`. `effective` is `gl_result_command_effective`. */
typedef struct gl_result_command_selection {
    gl_result_selection_status status;
    gl_result_command lastObserved;
    int64_t samples;
    gl_result_opt_string language;
} gl_result_command_selection;

/** `HackCommandSummary`. */
typedef struct gl_result_commands {
    gl_result_command_selection presentation;
    gl_result_command_selection gear;
    gl_result_command_mode mode;
} gl_result_commands;

/** `ResultReadContext`. `glyphs[i]` is the confirmed Glyph's name or nil. */
typedef struct gl_result_context {
    uint64_t sessionID;
    int64_t hackID;
    const gl_result_opt_string *glyphs;
    int32_t glyphCount;
    bool hasCommands;
    gl_result_commands commands;
} gl_result_context;

/** `ResultTextLine`: normalized coordinates, full frame, top-left origin. */
typedef struct gl_result_line {
    gc_string text;
    double confidence;
    double x;
    double y;
    double width;
    double height;
} gl_result_line;

/** `ResultFrameEvidence`. */
typedef struct gl_result_evidence {
    gl_result_context context;
    double sourceTime;
    bool panelPresent;
    gl_result_opt_int stageIndex;
    gl_result_opt_int hackingBonus;
    gl_result_opt_int speedBonus;
    const gl_result_appearance *appearances;
    int32_t appearanceCount;
    const gl_result_line *lines;
    int32_t lineCount;
    bool hasLabelLanguage;
    gc_language labelLanguage;
} gl_result_evidence;

/** `HackResult`. `outcomes` and `outcomeTimes` each have `outcomeCount`
 *  elements. `inputSeconds` is computed as Swift's computed property is. */
typedef struct gl_result_hack {
    gl_result_context context;
    gl_result_state state;
    gc_opt_double firstPanelTime;
    gc_opt_double lastPanelTime;
    gc_opt_double finalStageTime;
    gl_result_opt_int observedHackingBonus;
    gl_result_opt_int observedSpeedBonus;
    gl_result_opt_int finalHackingBonus;
    gl_result_opt_int finalSpeedBonus;
    const gl_result_outcome *outcomes;
    const gc_opt_double *outcomeTimes;
    int32_t outcomeCount;
    gc_opt_double closedAt;
    gl_result_opt_string closeReason;
    gc_opt_double inputStartedAt;
    gc_opt_double inputEndedAt;
    gc_opt_double inputSeconds;
} gl_result_hack;

/** `HackResultTracker.Policy`. */
typedef struct gl_result_tracker_policy {
    double minimumSpan;
    double maximumReadingGap;
    double panelExitSpan;
    double resultWait;
} gl_result_tracker_policy;

/** The fields of `FrameEvidence` the result session and the comparison read.
 *  `hasInputTimerBar` is the Swift property, which already includes the
 *  strip's own timer bar. */
typedef struct gl_result_frame {
    uint64_t sessionID;
    double time;
    bool hasHeader;
    gl_result_phase headerPhase;
    double headerSourceTime;
    bool hasSlots;
    int64_t slotCount;
    gl_result_opt_int highlightedIndex;
    gl_result_rejection slotRejection;
    bool hasInputTimerBar;
} gl_result_frame;

/** The fields of `InputCheckResult` the comparison reads. `verdict` is never
 *  NONE. `startTime` matters only for being present. */
typedef struct gl_result_check {
    uint64_t sessionID;
    gc_string expectedGlyph;
    gl_result_verdict verdict;
    gc_opt_double startTime;
    gc_opt_double liftTime;
} gl_result_check;

/** The fields of `InputCheckEvent` the comparison reads: `hasReason` is
 *  `reason != nil`, `hasResult` says whether `result` is set. */
typedef struct gl_result_check_event {
    gl_result_event_kind kind;
    double time;
    int64_t hackID;
    int64_t slotIndex;
    int64_t attemptID;
    bool hasReason;
    bool hasResult;
    gl_result_check result;
} gl_result_check_event;

/** One `SlotObservation`: `glyph` is an index into the session's Glyph list,
 *  -1 for none. */
typedef struct gl_result_slot {
    int64_t index;
    gl_result_slot_status status;
    int32_t glyph;
} gl_result_slot;

/** What `ResultObservationSession.observe` reads from the presentation
 *  tracker, as plain values. */
typedef struct gl_result_presentation {
    gl_result_tracking_state state;
    int64_t hackID;
    gl_result_opt_int expectedSlotCount;
    const gl_result_slot *slots;
    int32_t slotCount;
    /** `PresentationTracker.policy.unknownPhaseGrace`. */
    double unknownPhaseGrace;
} gl_result_presentation;

/** `ValidatorResultComparison.Entry`. */
typedef struct gl_result_entry {
    int64_t slotIndex;
    gl_result_opt_int attemptID;
    gl_result_verdict validatorVerdict;
    gl_result_outcome gameOutcome;
    gl_result_status status;
    gc_opt_double drawSeconds;
} gl_result_entry;

/** `HackResultSummary.Bonus?`. */
typedef struct gl_result_bonus {
    bool has;
    int64_t percent;
    bool isFinal;
} gl_result_bonus;

/** `HackResultSummary.Slot`. */
typedef struct gl_result_summary_slot {
    gl_result_opt_string glyph;
    gl_result_outcome outcome;
    gl_result_verdict check;
    gl_result_status comparison;
    gc_opt_double drawSeconds;
} gl_result_summary_slot;

/** `HackResultSummary` without `origin`, which the app sets. */
typedef struct gl_result_summary {
    uint64_t captureSessionID;
    int64_t hackID;
    gl_result_state state;
    bool isClosed;
    gl_result_opt_string closeReason;
    gl_result_bonus hackingBonus;
    gl_result_bonus speedBonus;
    const gl_result_summary_slot *slots;
    int32_t slotCount;
    gc_opt_double inputSeconds;
    bool hasCommands;
    gl_result_commands commands;
} gl_result_summary;

/** The parts of one `GameText.Table` the result parser matches, normalized
 *  as the table stores them. Pass `GameText(language).tables` in order, the
 *  game's own language first. */
typedef struct gl_result_text_table {
    gc_string code;
    gc_string hackingLabel;
    gc_string speedLabel;
} gl_result_text_table;

/* ------------------------------------------------------------------------ */
/* Handles                                                                     */

typedef struct gl_result_parser gl_result_parser;
typedef struct gl_result_tracker gl_result_tracker;
typedef struct gl_result_comparison gl_result_comparison;
typedef struct gl_result_session gl_result_session;
typedef struct gl_result_schedule gl_result_schedule;
typedef struct gl_command_watch gl_command_watch;
typedef struct gl_command_context gl_command_context;

/* --- ResultTextParser ----------------------------------------------------- */

/** `ResultTextParser(language:)`. The tables are copied. */
gl_result_parser *gl_result_parser_create(gc_language language, const gl_result_text_table *tables,
                                          int32_t tableCount);
void gl_result_parser_destroy(gl_result_parser *parser);

/** `read(lines:context:at:appearances:)`. The evidence's arrays and strings
 *  are owned by the parser until its next call. */
bool gl_result_parser_read(gl_result_parser *parser, const gl_result_line *lines, int32_t lineCount,
                           const gl_result_context *context, double time,
                           const gl_result_appearance *appearances, int32_t appearanceCount,
                           gl_result_evidence *out);

/* --- HackResultTracker ---------------------------------------------------- */

gl_result_tracker_policy gl_result_tracker_policy_default(void);

/** `HackResultTracker(context:policy:)`; a null policy is the default. */
gl_result_tracker *gl_result_tracker_create(const gl_result_context *context,
                                            const gl_result_tracker_policy *policy);
/** The session's `tracker`, as a value: later calls on the session do not
 *  change it, nor do calls on it change the session. Null when the session
 *  has no tracker. */
gl_result_tracker *gl_result_tracker_create_from_session(const gl_result_session *session);
void gl_result_tracker_destroy(gl_result_tracker *tracker);

/** `accept(_:)`: true when the result changed. */
bool gl_result_tracker_accept(gl_result_tracker *tracker, const gl_result_evidence *evidence);
/** `observeFrame(at:inputVisible:exitVisible:panelCandidate:)`. */
void gl_result_tracker_observe_frame(gl_result_tracker *tracker, double time, bool inputVisible,
                                     bool exitVisible, bool panelCandidate);
/** `finish(at:reason:)`. */
void gl_result_tracker_finish(gl_result_tracker *tracker, double time, gc_string reason);
/** `result`, owned by the tracker until its next call. */
bool gl_result_tracker_result(gl_result_tracker *tracker, gl_result_hack *out);
/** `revision`; -1 for a null tracker. */
int64_t gl_result_tracker_revision(const gl_result_tracker *tracker);

/* --- ValidatorResultComparison -------------------------------------------- */

/** `ValidatorResultComparison(context:)`. */
gl_result_comparison *gl_result_comparison_create(const gl_result_context *context);
/** The session's `comparison`, as a value, like the tracker's. Null when the
 *  session has none. */
gl_result_comparison *gl_result_comparison_create_from_session(const gl_result_session *session);
void gl_result_comparison_destroy(gl_result_comparison *comparison);

/** `observe(_:inputVisible:)`. */
void gl_result_comparison_observe(gl_result_comparison *comparison, const gl_result_frame *frame,
                                  bool inputVisible);
/** `accept(_:)`. */
void gl_result_comparison_accept(gl_result_comparison *comparison, const gl_result_check_event *events,
                                 int32_t count);
/** `compare(_:)`: the entries, owned by the comparison until its next call. */
bool gl_result_comparison_compare(gl_result_comparison *comparison, const gl_result_hack *result,
                                  const gl_result_entry **entries, int32_t *count);
/** `supersededAttemptIDs`, ascending, owned until the next call. */
bool gl_result_comparison_superseded(gl_result_comparison *comparison, const int64_t **ids, int32_t *count);

/* --- ResultObservationSession --------------------------------------------- */

/** `ResultObservationSession()`. `glyphNames` is the Glyph table's
 *  name-sorted list, which `gl_result_slot.glyph` indexes. */
gl_result_session *gl_result_session_create(const gc_string *glyphNames, int32_t glyphCount);
/** A copy of the session's value, as Swift's `var b = a`. */
gl_result_session *gl_result_session_create_copy(const gl_result_session *session);
void gl_result_session_destroy(gl_result_session *session);
/** Back to `ResultObservationSession()`, keeping the Glyph list. */
void gl_result_session_reset(gl_result_session *session);

/** `observe(_:presentation:panelCandidate:imageAnalyzed:commands:)`. A null
 *  `commands` is nil. Returns true and fills `retired`, owned by the session
 *  until its next call, when a new hack retired the previous one. */
bool gl_result_session_observe(gl_result_session *session, const gl_result_frame *frame,
                               const gl_result_presentation *presentation, bool panelCandidate,
                               bool imageAnalyzed, const gl_result_commands *commands,
                               gl_result_hack *retired);
/** `accept(_ evidence:)`. */
void gl_result_session_accept_evidence(gl_result_session *session, const gl_result_evidence *evidence);
/** `accept(_ events:)`. */
void gl_result_session_accept_events(gl_result_session *session, const gl_result_check_event *events,
                                     int32_t count);
/** `finish(at:reason:)`. */
void gl_result_session_finish(gl_result_session *session, double time, gc_string reason);
/** `context`: false when nil. Owned by the session until its next call. */
bool gl_result_session_context(gl_result_session *session, gl_result_context *out);

/* --- ResultEvidenceSchedule ----------------------------------------------- */

gl_result_schedule *gl_result_schedule_create(void);
void gl_result_schedule_destroy(gl_result_schedule *schedule);
/** Back to `ResultEvidenceSchedule()`. */
void gl_result_schedule_reset(gl_result_schedule *schedule);
/** `select(_:decision:)`. */
gl_result_schedule_selection gl_result_schedule_select(gl_result_schedule *schedule,
                                                       const gl_result_evidence *evidence, bool decision);

/* --- CommandScreenWatch --------------------------------------------------- */

/** `CommandScreenWatch()` with its `flicker` and `leave` (0.5 and 2.0 by
 *  default in Swift). */
gl_command_watch *gl_command_watch_create(double flicker, double leave);
void gl_command_watch_destroy(gl_command_watch *watch);
/** `observe(at:calibrated:commandPhase:complete:)`. */
gl_command_watch_action gl_command_watch_observe(gl_command_watch *watch, double time, bool calibrated,
                                                 bool commandPhase, bool complete);
/** `stop()`. */
void gl_command_watch_stop(gl_command_watch *watch);
/** `reset()`. */
void gl_command_watch_reset(gl_command_watch *watch);
/** `watching`. */
bool gl_command_watch_watching(const gl_command_watch *watch);

/* --- CommandPhaseContext -------------------------------------------------- */

/** `CommandPhaseContext()` with its `leave` (`CommandScreenWatch().leave`,
 *  2.0, in Swift). */
gl_command_context *gl_command_context_create(double leave);
void gl_command_context_destroy(gl_command_context *context);
/** `leave`. */
double gl_command_context_leave(const gl_command_context *context);
void gl_command_context_set_leave(gl_command_context *context, double leave);
/** `header(_:)`: a header reading's phase, matched text (UTF-8) and source time. */
void gl_command_context_header(gl_command_context *context, gl_result_phase phase, gc_string matchedText,
                               double sourceTime);
/** `isReadable(_:)`. */
bool gl_command_context_is_readable(gl_result_phase phase, gc_string matchedText);
/** `notice(at:)`. */
void gl_command_context_notice(gl_command_context *context, double time);
/** `noticeRead(at:)`; no value is nil. */
void gl_command_context_notice_read(gl_command_context *context, gc_opt_double sourceTime);
/** `isCurrent(at:)`. */
bool gl_command_context_is_current(const gl_command_context *context, double time);
/** `reset()`. */
void gl_command_context_reset(gl_command_context *context);

/* --- Values: HackCommandSummary, HackResultSummary, presentation ------------ */

/** `Selection.effective`. */
gl_result_command gl_result_command_effective(const gl_result_command_selection *selection);

/** `HackResultSummary(result:comparison:)`. Writes the summary and, when
 *  `capacity` suffices, its slots into `slots`; returns the slot count needed
 *  (then nothing is written when it exceeds `capacity`), or -1 for a null
 *  argument. The summary's strings point into `result`'s. */
int32_t gl_result_summary_make(const gl_result_hack *result, const gl_result_entry *entries, int32_t entryCount,
                               gl_result_summary *out, gl_result_summary_slot *slots, int32_t capacity);
/** Which `headline` the summary shows. */
gl_result_headline gl_result_summary_headline(const gl_result_summary *summary);
/** `hasProvisionalBonus`. */
bool gl_result_summary_has_provisional_bonus(const gl_result_summary *summary);
/** The slots `disagreementLines` lists, in order: indices into `slots`.
 *  Same capacity contract as `gl_result_summary_make`. */
int32_t gl_result_summary_disagreements(const gl_result_summary *summary, int32_t *slotIndices, int32_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* GLYPH_LOGIC_RESULTS_H */
