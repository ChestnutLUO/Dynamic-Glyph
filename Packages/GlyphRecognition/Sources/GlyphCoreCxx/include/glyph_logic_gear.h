#ifndef GLYPH_LOGIC_GEAR_H
#define GLYPH_LOGIC_GEAR_H

/*
 * GlyphCore logic layer, area "gear". Follows the conventions in
 * glyph_common.h. The Swift types this mirrors are the oracle; the
 * equivalence tests in Tests/GlyphRecognitionTests/Cxx hold both to the same
 * output.
 *
 * Oracles, in Sources/GlyphRecognition: GearDropTextParser,
 * GearDropFrameEvidence, GearDropTracker, GearDropObservationSession,
 * GearDropSummary, GearEvidenceSchedule, GearQuantityColorReader,
 * GearRarityReader and GearDropDisplayTracker.
 *
 * Swift `Int` fields that hold identities or counts that can grow (hack and
 * group identities, quantities, revisions) are int64_t; positions, rows,
 * columns, levels and row counts are int32_t.
 */

#include "glyph_common.h"
#include "glyph_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Values (GearDropFrameEvidence.swift, GearDropSummary.swift)               */

/** `GearDropStage`. */
typedef enum gl_gear_stage {
    GL_GEAR_STAGE_ABSENT = 0,
    GL_GEAR_STAGE_UNKNOWN,
    GL_GEAR_STAGE_PORTAL,
    GL_GEAR_STAGE_BONUS,
    GL_GEAR_STAGE_EXCLUDED,
    GL_GEAR_STAGE_UNSUPPORTED
} gl_gear_stage;

/** `GearDropEntry.Level`. */
typedef enum gl_gear_level {
    GL_GEAR_LEVEL_KNOWN = 0,
    GL_GEAR_LEVEL_NOT_APPLICABLE,
    GL_GEAR_LEVEL_UNREADABLE
} gl_gear_level;

/** `GearDropEntry.Rarity?`: NONE is nil. */
typedef enum gl_gear_rarity {
    GL_GEAR_RARITY_NONE = 0,
    GL_GEAR_RARITY_COMMON,
    GL_GEAR_RARITY_RARE,
    GL_GEAR_RARITY_VERY_RARE,
    GL_GEAR_RARITY_UNREADABLE
} gl_gear_rarity;

/** `GearDropEntry`. `item` is read only when `hasItem`. */
typedef struct gl_gear_entry {
    int32_t column;
    int32_t row;
    bool hasItem;
    gc_string item;
    gl_gear_level levelState;
    gc_opt_int32 level;
    int64_t quantity;
    gl_gear_rarity rarity;
    bool hasMultiplied;
    bool multiplied;
} gl_gear_entry;

/** `GearDropEntry.intrinsicRarity`: NONE when the item has no fixed rarity. */
gl_gear_rarity gl_gear_entry_intrinsic_rarity(const gl_gear_entry *entry);

/** `GearDropEntry.hasRarityMeter`. */
bool gl_gear_entry_has_rarity_meter(const gl_gear_entry *entry);

/** `GearDropFrameEvidence`. `bounds` uses the pixel core's panel bounds.
 *  `effects` is read only when `hasEffects`. */
typedef struct gl_gear_evidence {
    double sourceTime;
    gl_gear_stage stage;
    bool hasBounds;
    gc_panel_bounds bounds;
    const gl_gear_entry *entries;
    int32_t entryCount;
    int32_t unreadableRows;
    bool hasEffects;
    const gc_string *effects;
    int32_t effectCount;
    bool hasTitleLanguage;
    gc_language titleLanguage;
} gl_gear_evidence;

/** `GearDropSummary.Panel`. */
typedef struct gl_gear_panel {
    gl_gear_stage stage;
    const gl_gear_entry *entries;
    int32_t entryCount;
    bool partial;
    bool hasEffects;
    const gc_string *effects;
    int32_t effectCount;
} gl_gear_panel;

/** `GearDropSummary.Association`. */
typedef enum gl_gear_association {
    GL_GEAR_ASSOCIATION_UNASSOCIATED = 0,
    GL_GEAR_ASSOCIATION_ORDERED,
    GL_GEAR_ASSOCIATION_ORDERED_WITHOUT_BONUS,
    GL_GEAR_ASSOCIATION_BONUS_EXPECTED,
    GL_GEAR_ASSOCIATION_NO_WAITING_HACK,
    GL_GEAR_ASSOCIATION_UNCERTAIN_CONTINUITY,
    /** Appended after the integration, as Swift appended the case. */
    GL_GEAR_ASSOCIATION_REPEATED_BONUS
} gl_gear_association;

/** `GearDropSummary`. */
typedef struct gl_gear_summary {
    int64_t groupID;
    double startedAt;
    double closedAt;
    gc_string closeReason;
    bool hasHackID;
    int64_t hackID;
    gl_gear_association association;
    const gl_gear_panel *panels;
    int32_t panelCount;
} gl_gear_summary;

/** `GearDropSummary.recognizedQuantity`, `unidentifiedQuantity`,
 *  `panelsReadInFull` and `bothPanelsRead`. */
int64_t gl_gear_summary_recognized_quantity(const gl_gear_summary *summary);
int64_t gl_gear_summary_unidentified_quantity(const gl_gear_summary *summary);
bool gl_gear_summary_panels_read_in_full(const gl_gear_summary *summary);
bool gl_gear_summary_both_panels_read(const gl_gear_summary *summary);

/* ------------------------------------------------------------------------ */
/* Text parser (GearDropTextParser.swift, GameText's gear matchers)          */

/** A normalized key and its value, one entry of a `GameText.Table` map. */
typedef struct gl_gear_text_pair {
    gc_string key;
    gc_string value;
} gl_gear_text_pair;

/** The parts of one `GameText.Table` the gear parser matches against, as
 *  the Swift table holds them. `items` lists the table's `items` in the
 *  dictionary's own iteration order, which `GameText.item(named:clipped:)`
 *  depends on for a shortened name's full length. `leadingWords` holds one
 *  pair per opening words and item. */
typedef struct gl_gear_text_table {
    gc_string code;
    gc_string bonusTitle;
    gc_string bountyTitle;
    const gc_string *messageFragments;
    int32_t messageFragmentCount;
    const gc_string *effectSuffixes;
    int32_t effectSuffixCount;
    const gc_string *effectPrefixes;
    int32_t effectPrefixCount;
    const gl_gear_text_pair *items;
    int32_t itemCount;
    const gl_gear_text_pair *leadingWords;
    int32_t leadingWordCount;
} gl_gear_text_table;

/** `ResultTextLine`: one OCR line, in fractions of the frame. */
typedef struct gl_gear_text_line {
    gc_string text;
    double confidence;
    double x;
    double y;
    double width;
    double height;
} gl_gear_text_line;

typedef struct gl_gear_parser gl_gear_parser;

/** `GearDropTextParser(language:)`: `tables` are `GameText(language).tables`,
 *  the game's own pack first; `allBonusTitles` is `GameText.allBonusTitles`.
 *  Everything is copied. NULL when the arguments are malformed. */
gl_gear_parser *gl_gear_parser_create(gc_language language, const gl_gear_text_table *tables, int32_t tableCount,
                                      const gc_string *allBonusTitles, int32_t allBonusTitleCount);
void gl_gear_parser_destroy(gl_gear_parser *parser);

/** `parseEntry(_:row:column:clipped:)`. False for nil. The entry's item
 *  string is owned by the parser until its next call. */
bool gl_gear_parser_parse_entry(gl_gear_parser *parser, gc_string text, int32_t row, int32_t column, bool clipped,
                                gl_gear_entry *out);

/** `read(lines:bounds:at:)`. Entries and effects are owned by the parser
 *  until its next call. */
void gl_gear_parser_read(gl_gear_parser *parser, const gl_gear_text_line *lines, int32_t count,
                         gc_panel_bounds bounds, double time, gl_gear_evidence *out);

/** `GearDropTextParser.position(of:in:)`. False for nil, and for a line
 *  whose row Swift could not convert to an Int (it would trap). */
bool gl_gear_position(const gl_gear_text_line *line, gc_panel_bounds bounds, int32_t *out);

/** `showsUntitledPanel(lines:bounds:at:)`. Appended after the integration. */
bool gl_gear_parser_shows_untitled_panel(gl_gear_parser *parser, const gl_gear_text_line *lines, int32_t count,
                                         gc_panel_bounds bounds, double time);

/* ------------------------------------------------------------------------ */
/* Tracker (GearDropTracker.swift)                                           */

/** `GearDropTracker.ReadingDisposition`. */
typedef enum gl_gear_disposition {
    GL_GEAR_DISPOSITION_ACCEPTED = 0,
    GL_GEAR_DISPOSITION_INVALID_TIME,
    GL_GEAR_DISPOSITION_OUT_OF_ORDER,
    GL_GEAR_DISPOSITION_CLOSED_INTERVAL,
    GL_GEAR_DISPOSITION_NON_PANEL
} gl_gear_disposition;

/** The Swift raw value, "accepted" ... "nonPanel". Static storage. */
gc_string gl_gear_disposition_name(gl_gear_disposition disposition);

/** `GearDropTracker.Policy`. */
typedef struct gl_gear_tracker_policy {
    double minimumSpan;
    double maximumReadingGap;
    double departureSpan;
    double maximumCompletionWait;
    double groupLimit;
} gl_gear_tracker_policy;

gl_gear_tracker_policy gl_gear_tracker_policy_default(void);

typedef struct gl_gear_tracker gl_gear_tracker;

/** `GearDropTracker(policy:)`; NULL `policy` is the default. */
gl_gear_tracker *gl_gear_tracker_create(const gl_gear_tracker_policy *policy);
void gl_gear_tracker_destroy(gl_gear_tracker *tracker);

/* Each returns true when a group closed and fills `out`, owned by the
 * tracker until its next call. */

/** `accept(_:)`. */
bool gl_gear_tracker_accept(gl_gear_tracker *tracker, const gl_gear_evidence *evidence, gl_gear_summary *out);
/** `observe(at:panelCandidate:continuityLost:pendingReadSourceTime:)`. */
bool gl_gear_tracker_observe(gl_gear_tracker *tracker, double time, bool panelCandidate, bool continuityLost,
                             gc_opt_double pendingReadSourceTime, gl_gear_summary *out);
/** `loseContinuity(at:)`. */
bool gl_gear_tracker_lose_continuity(gl_gear_tracker *tracker, double time, gl_gear_summary *out);
/** `finish(at:reason:)`. */
bool gl_gear_tracker_finish(gl_gear_tracker *tracker, double time, gc_string reason, gl_gear_summary *out);

bool gl_gear_tracker_is_observing(const gl_gear_tracker *tracker);
gl_gear_disposition gl_gear_tracker_reading_disposition(const gl_gear_tracker *tracker);

/* Appended after the integration, for the held Bonus panel. */

/** `GearDropTracker(policy:)` with `Policy.bonusReturnWindow`, which
 *  `gl_gear_tracker_policy` lacks; `gl_gear_tracker_create` uses 2 s. */
gl_gear_tracker *gl_gear_tracker_create_with_return_window(const gl_gear_tracker_policy *policy,
                                                           double bonusReturnWindow);
/** `currentPanelSettled`. */
bool gl_gear_tracker_current_panel_settled(const gl_gear_tracker *tracker);

/* ------------------------------------------------------------------------ */
/* Observation session (GearDropObservationSession.swift)                    */

/** `GearDropObservationSession.Policy`. */
typedef struct gl_gear_session_policy {
    double inactivityLimit;
    double absoluteLimit;
    int64_t maximumWaiting;
} gl_gear_session_policy;

gl_gear_session_policy gl_gear_session_policy_default(void);

/** `GearDropObservationSession.Wait`. */
typedef struct gl_gear_wait {
    int64_t hackID;
    double startedAt;
    double lastProgress;
    bool hasFinalBonus;
    int64_t finalBonus;
} gl_gear_wait;

/** `GearDropObservationSession.Event`. */
typedef struct gl_gear_event {
    double time;
    bool hasHackID;
    int64_t hackID;
    gc_string reason;
} gl_gear_event;

typedef struct gl_gear_session gl_gear_session;

/** `GearDropObservationSession(policy:)`; NULL `policy` is the default. */
gl_gear_session *gl_gear_session_create(const gl_gear_session_policy *policy);
void gl_gear_session_destroy(gl_gear_session *session);

/** `prepareFrame(at:continuityLost:)`. */
bool gl_gear_session_prepare_frame(gl_gear_session *session, double time, bool continuityLost);
/** `observe(at:hackID:inputVisible:gameProgressVisible:inputPhase:)`;
 *  `inputPhaseIsInput` is `inputPhase == .input`, all the session reads. */
void gl_gear_session_observe(gl_gear_session *session, double time, int64_t hackID, bool inputVisible,
                             bool gameProgressVisible, bool inputPhaseIsInput);
/** `enqueue(hackID:at:)`. */
void gl_gear_session_enqueue(gl_gear_session *session, int64_t hackID, double time);
/** `accept(_ result: HackResult)`, with the two fields it reads:
 *  `result.context.hackID` and `result.finalHackingBonus`. */
void gl_gear_session_accept_result(gl_gear_session *session, int64_t hackID, bool hasFinalHackingBonus,
                                   int64_t finalHackingBonus);
/** `close(_:)`: the group as attached, owned by the session until its next
 *  call. False only for a null argument. */
bool gl_gear_session_close(gl_gear_session *session, const gl_gear_summary *group, gl_gear_summary *out);
/** `expire(at:)`. */
void gl_gear_session_expire(gl_gear_session *session, double time);
/** `invalidate(at:reason:)`. */
void gl_gear_session_invalidate(gl_gear_session *session, double time, gc_string reason);

/** `waiting`, oldest first, valid until the session's next call. */
const gl_gear_wait *gl_gear_session_waiting(const gl_gear_session *session, int32_t *count);
/** `events`, oldest first, valid until the session's next call. The list
 *  only grows, so a caller can convert just the new tail. */
const gl_gear_event *gl_gear_session_events(const gl_gear_session *session, int32_t *count);
bool gl_gear_session_is_association_uncertain(const gl_gear_session *session);

/** `GearDropObservationSession(policy:)` with `Policy.repeatedBonusWindow`,
 *  which `gl_gear_session_policy` lacks; `gl_gear_session_create` uses 2 s.
 *  Appended after the integration. */
gl_gear_session *gl_gear_session_create_with_repeat_window(const gl_gear_session_policy *policy,
                                                           double repeatedBonusWindow);

/* ------------------------------------------------------------------------ */
/* Evidence schedule (GearEvidenceSchedule.swift)                            */

typedef struct gl_gear_schedule gl_gear_schedule;

gl_gear_schedule *gl_gear_schedule_create(void);
void gl_gear_schedule_destroy(gl_gear_schedule *schedule);
/** `shouldSave(stage:at:)`. */
bool gl_gear_schedule_should_save(const gl_gear_schedule *schedule, gl_gear_stage stage, double time);
/** `didEnqueue(stage:at:)`. */
void gl_gear_schedule_did_enqueue(gl_gear_schedule *schedule, gl_gear_stage stage, double time);

/* ------------------------------------------------------------------------ */
/* Floating display (GearDropDisplay.swift)                                  */

/** `GearDropDisplay.State`. */
typedef enum gl_gear_display_state {
    GL_GEAR_DISPLAY_WAITING = 0,
    GL_GEAR_DISPLAY_READING,
    GL_GEAR_DISPLAY_READ,
    GL_GEAR_DISPLAY_PARTIAL,
    GL_GEAR_DISPLAY_UNATTACHED,
    GL_GEAR_DISPLAY_NOT_READ,
    GL_GEAR_DISPLAY_WATCHING
} gl_gear_display_state;

/** `GearDropDisplay`'s stored fields; its text and symbols stay in Swift. */
typedef struct gl_gear_display_value {
    gl_gear_display_state state;
    bool hasHackID;
    int64_t hackID;
    bool hasItemCount;
    int64_t itemCount;
    int64_t waitingCount;
} gl_gear_display_value;

typedef struct gl_gear_display gl_gear_display;

/** `GearDropDisplayTracker(standalone:)`. */
gl_gear_display *gl_gear_display_create(bool standalone);
void gl_gear_display_destroy(gl_gear_display *display);
/** `update(waiting:reading:associationUncertain:at:)`. */
void gl_gear_display_update(gl_gear_display *display, const gl_gear_wait *waiting, int32_t waitingCount,
                            bool reading, bool associationUncertain, double time);
/** `finished(_:)`. */
void gl_gear_display_finished(gl_gear_display *display, const gl_gear_summary *group);
/** `ended(hackID:at:)`. */
void gl_gear_display_ended(gl_gear_display *display, int64_t hackID, double time);
/** `display`: false for nil. */
bool gl_gear_display_get(const gl_gear_display *display, gl_gear_display_value *out);
/** `revision`. */
int64_t gl_gear_display_revision(const gl_gear_display *display);

/* ------------------------------------------------------------------------ */
/* Pixel readers (GearQuantityColorReader.swift, GearRarityReader.swift)     */

/** `GearQuantityColorReader().read(_:)` on the quantity text's box: returns
 *  false for nil, else true with `*multiplied` set (red true, white false). */
bool gl_gear_quantity_color_read(gc_color_image image, bool *multiplied);

/** `GearRarityReader().read(_:)` on the meter crop; NONE for nil. */
gl_gear_rarity gl_gear_rarity_read(gc_color_image image);

#ifdef __cplusplus
}
#endif

#endif /* GLYPH_LOGIC_GEAR_H */
