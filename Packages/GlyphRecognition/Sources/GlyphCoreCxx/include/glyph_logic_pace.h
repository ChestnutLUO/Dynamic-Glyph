#ifndef GLYPH_LOGIC_PACE_H
#define GLYPH_LOGIC_PACE_H

/*
 * GlyphCore logic layer, area "pace". Follows the conventions in
 * glyph_common.h. The Swift types this mirrors are the oracle; the
 * equivalence tests in Tests/GlyphRecognitionTests/Cxx hold both to the same
 * output.
 *
 * Every name declared here starts with one of this area's object prefixes
 * (gl_text_, gl_pace_, gl_text_schedule_, gl_language_memory_, gl_game_text_,
 * gl_command_parser_, gl_command_capture_, gl_portal_), so the areas sharing
 * the umbrella module never collide.
 *
 * Text is compared as Swift compares it: by Characters (extended grapheme
 * clusters, as this toolchain's Swift segments them) under canonical
 * equivalence, so "ポ" and "ホ" + U+309A are the same key, as they are in a
 * Swift dictionary. The tables behind that are generated from Swift itself by
 * Tools/generate-text-tables.swift.
 */

#include "glyph_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Text (reference: Swift's String)                                          */

/** `String.count`: the number of Characters (extended grapheme clusters). */
int32_t gl_text_character_count(gc_string text);

/* ------------------------------------------------------------------------ */
/* Analysis pace (reference: AnalysisRateController in AnalysisGate.swift)  */

typedef enum gl_pace_mode {
    GL_PACE_MODE_ACTIVE = 0,
    GL_PACE_MODE_RESTING,
    GL_PACE_MODE_QUIET
} gl_pace_mode;

/** `AnalysisRateController.Policy`, field for field. */
typedef struct gl_pace_policy {
    double activeInterval;
    double quietInterval;
    double constrainedActiveInterval;
    double constrainedQuietInterval;
    double settle;
    int32_t changeThreshold;
    double switchMeanJump;
    double switchWindow;
    double switchBurst;
} gl_pace_policy;

/** `AnalysisRateController.Decision`. */
typedef struct gl_pace_decision {
    gl_pace_mode mode;
    double interval;
} gl_pace_decision;

/** The part of a `LumaGateReading?` the pace reads: whether there is one,
 *  its `isCandidate` and its `meanLuma`. */
typedef struct gl_pace_gate {
    bool has;
    bool isCandidate;
    double meanLuma;
} gl_pace_gate;

typedef struct gl_pace gl_pace;

/** `Policy()`: the defaults. */
gl_pace_policy gl_pace_policy_default(void);
/** `policy` may be NULL for the defaults. */
gl_pace *gl_pace_create(const gl_pace_policy *policy);
void gl_pace_destroy(gl_pace *pace);
void gl_pace_reset(gl_pace *pace);
gl_pace_decision gl_pace_decide(gl_pace *pace, double time, gl_pace_gate gate, bool busy, bool inHack,
                                bool constrained);
gl_pace_decision gl_pace_advance_still(gl_pace *pace, double time, bool busy, bool inHack, bool constrained);
gl_pace_policy gl_pace_get_policy(const gl_pace *pace);
gl_pace_mode gl_pace_get_mode(const gl_pace *pace);
bool gl_pace_entered_candidate(const gl_pace *pace);
bool gl_pace_switched_screen(const gl_pace *pace);
/** `AnalysisRateController.headerInterval(mode:inHack:constrained:)`. */
gc_opt_double gl_pace_header_interval(gl_pace_mode mode, bool inHack, bool constrained);

/* ------------------------------------------------------------------------ */
/* Text lane (reference: GameTextSchedule.swift)                             */

typedef enum gl_text_schedule_mode {
    GL_TEXT_SCHEDULE_MODE_HEADER = 0,
    GL_TEXT_SCHEDULE_MODE_RESULT,
    GL_TEXT_SCHEDULE_MODE_GEAR,
    GL_TEXT_SCHEDULE_MODE_PORTAL,
    GL_TEXT_SCHEDULE_MODE_COMMAND
} gl_text_schedule_mode;

/** `GameTextSchedule.Request`. */
typedef struct gl_text_schedule_request {
    int64_t id;
    gl_text_schedule_mode mode;
    double sourceTime;
} gl_text_schedule_request;

/** The arguments of `take(at:...)`, in its order, without `admitsHeader`.
 *  The Swift defaults: minimumInterval 0.1, readsHeader true, no
 *  headerInterval, gearInterval 0.2, every other flag false. */
typedef struct gl_text_schedule_take_args {
    double time;
    bool panelCandidate;
    bool resultEligible;
    double minimumInterval;
    bool gearCandidate;
    bool headerPriority;
    bool portalCandidate;
    bool commandCandidate;
    bool readsHeader;
    gc_opt_double headerInterval;
    double gearInterval;
} gl_text_schedule_take_args;

typedef enum gl_text_schedule_take_status {
    /** `take` returned nil. */
    GL_TEXT_SCHEDULE_TAKE_NONE = 0,
    /** `take` returned the request written to `out`. */
    GL_TEXT_SCHEDULE_TAKE_GRANTED,
    /** The request would be a header read: this is where Swift calls
     *  `admitsHeader`. The caller evaluates it and passes the answer to
     *  `gl_text_schedule_admit`, which finishes the take. */
    GL_TEXT_SCHEDULE_TAKE_NEEDS_ADMISSION
} gl_text_schedule_take_status;

typedef struct gl_text_schedule gl_text_schedule;

gl_text_schedule *gl_text_schedule_create(void);
void gl_text_schedule_destroy(gl_text_schedule *schedule);
gl_text_schedule_take_status gl_text_schedule_take(gl_text_schedule *schedule,
                                                   const gl_text_schedule_take_args *args,
                                                   gl_text_schedule_request *out);
/** Finishes a take that needed admission. Returns whether a request was
 *  made (then written to `out`); false without a pending admission. Any
 *  other call on the handle drops a pending admission unanswered. */
bool gl_text_schedule_admit(gl_text_schedule *schedule, bool admitted, gl_text_schedule_request *out);
void gl_text_schedule_finish(gl_text_schedule *schedule, gl_text_schedule_request request, bool panelPresent);
/** `inFlight`: false when nil. */
bool gl_text_schedule_in_flight(const gl_text_schedule *schedule, gl_text_schedule_request *out);

/** `GameTextSchedule.Pace`: a lane's spacing while a found panel's rows are
 *  unconfirmed. Appended after the integration for the new-panel lane. */
typedef struct gl_text_schedule_pace {
    double minimumInterval;
    double gearInterval;
} gl_text_schedule_pace;

/** `take(at:...gearPanelPace:admitsHeader:)`: `gl_text_schedule_take` with
 *  `gearPanelPace`, which may be null (Swift's nil). Admission as there. */
gl_text_schedule_take_status gl_text_schedule_take_paced(gl_text_schedule *schedule,
                                                         const gl_text_schedule_take_args *args,
                                                         const gl_text_schedule_pace *gearPanelPace,
                                                         gl_text_schedule_request *out);
/** `finish(_:panelPresent:untitledPanel:)`. */
void gl_text_schedule_finish_untitled(gl_text_schedule *schedule, gl_text_schedule_request request,
                                      bool panelPresent, bool untitledPanel);
/** `observeGearPanel(_:at:previousPanelUnconfirmed:)`. `hasBounds` false is
 *  nil bounds. Returns whether a request is to be stopped (written to `out`). */
bool gl_text_schedule_observe_gear_panel(gl_text_schedule *schedule, bool hasBounds, double top, double bottom,
                                         double time, bool previousPanelUnconfirmed,
                                         gl_text_schedule_request *out);
/** `readsGearPanel`. */
bool gl_text_schedule_reads_gear_panel(const gl_text_schedule *schedule);
/** `newGearPanel`. */
bool gl_text_schedule_new_gear_panel(const gl_text_schedule *schedule);
/** `cancelledGearRequest`: false when nil. */
bool gl_text_schedule_cancelled_gear_request(const gl_text_schedule *schedule, gl_text_schedule_request *out);

/* ------------------------------------------------------------------------ */
/* Game language memory (reference: GameLanguageMemory.swift)                */

typedef enum gl_language_memory_screen {
    GL_LANGUAGE_MEMORY_SCREEN_NOTICE = 0,
    GL_LANGUAGE_MEMORY_SCREEN_RESULT,
    GL_LANGUAGE_MEMORY_SCREEN_PANEL
} gl_language_memory_screen;

typedef struct gl_language_memory gl_language_memory;

gl_language_memory *gl_language_memory_create(gc_language language, bool isAutomatic, double retryInterval);
void gl_language_memory_destroy(gl_language_memory *memory);
gc_language gl_language_memory_current(const gl_language_memory *memory);
bool gl_language_memory_is_confirmed(const gl_language_memory *memory);
bool gl_language_memory_is_automatic(const gl_language_memory *memory);
double gl_language_memory_retry_interval(const gl_language_memory *memory);
/** `alternatives(at:on:)` into `out` (capacity 5); returns the count. */
int32_t gl_language_memory_alternatives(gl_language_memory *memory, double time, gl_language_memory_screen screen,
                                        gc_language out[5]);
/** `found(_:)`. Returns whether the language changed: the Swift class then
 *  calls its `onChange`, which the caller does instead. */
bool gl_language_memory_found(gl_language_memory *memory, gc_language found);
/** `panelReadingLanguage(at:bounds:)`: false for nil. */
bool gl_language_memory_panel_reading_language(gl_language_memory *memory, double time, double boundsTop,
                                               double boundsBottom, gc_language *out);
void gl_language_memory_remember_panel_reading(gl_language_memory *memory, gc_language language, double time,
                                               double boundsTop, double boundsBottom);
/** `GameLanguageMemory.startingGuess(remembered:preferredLanguages:)`. */
gc_language gl_language_memory_starting_guess(bool hasRemembered, gc_language remembered,
                                              const gc_string *preferredLanguages, int32_t count);

/* ------------------------------------------------------------------------ */
/* Game text matchers (reference: GameText.swift)                            */

/** `CommandNoticeReading.Notice?`. */
typedef enum gl_game_text_notice_kind {
    GL_GAME_TEXT_NOTICE_NONE = 0,
    GL_GAME_TEXT_NOTICE_SIMPLE,
    GL_GAME_TEXT_NOTICE_COMPLEX,
    GL_GAME_TEXT_NOTICE_REQUEST_KEY,
    GL_GAME_TEXT_NOTICE_NO_KEY,
    GL_GAME_TEXT_NOTICE_KEYS_ONLY,
    GL_GAME_TEXT_NOTICE_INVALID,
    GL_GAME_TEXT_NOTICE_DRONE
} gl_game_text_notice_kind;

/** `GameText.Title`. */
typedef enum gl_game_text_title_kind {
    GL_GAME_TEXT_TITLE_BONUS = 0,
    GL_GAME_TEXT_TITLE_BOUNTY,
    GL_GAME_TEXT_TITLE_UNSUPPORTED,
    GL_GAME_TEXT_TITLE_MESSAGE,
    GL_GAME_TEXT_TITLE_OTHER
} gl_game_text_title_kind;

typedef struct gl_game_text_notice_entry {
    gc_string text;
    gl_game_text_notice_kind notice;
} gl_game_text_notice_entry;

/** A shown name and the English item it names; also a leading word and one
 *  of the items it opens (`leadingWords`, one pair per member of each set). */
typedef struct gl_game_text_item_entry {
    gc_string shown;
    gc_string item;
} gl_game_text_item_entry;

/** `GameText.Table` without `headers` (the tracker area's), as Swift
 *  exports it: the strings already normalized where the pack keeps them so. */
typedef struct gl_game_text_pack {
    gc_string code;
    const gl_game_text_notice_entry *notices;
    int32_t noticeCount;
    gc_string droneFooter;
    gc_string hackingLabel;
    gc_string speedLabel;
    gc_string bonusTitle;
    gc_string bountyTitle;
    const gc_string *messageFragments;
    int32_t messageFragmentCount;
    const gc_string *effectSuffixes;
    int32_t effectSuffixCount;
    const gc_string *effectPrefixes;
    int32_t effectPrefixCount;
    const gl_game_text_item_entry *items;
    int32_t itemCount;
    const gl_game_text_item_entry *leadingWords;
    int32_t leadingWordCount;
} gl_game_text_pack;

/** `notice(_:)`'s result. `language` is a pack's code, owned by the handle
 *  for its lifetime. */
typedef struct gl_game_text_notice_match {
    gl_game_text_notice_kind notice;
    gc_string language;
} gl_game_text_notice_match;

typedef struct gl_game_text gl_game_text;

/** `GameText(language)` from its `tables`, in their order, and
 *  `GameText.allBonusTitles`. Everything is copied. */
gl_game_text *gl_game_text_create(gc_language language, const gl_game_text_pack *packs, int32_t packCount,
                                  const gc_string *allBonusTitles, int32_t allBonusTitleCount);
void gl_game_text_destroy(gl_game_text *text);
gc_language gl_game_text_language(const gl_game_text *text);
/* The matchers never change the handle: strings they return are the handle's
 * own (or static), valid for its lifetime, so calls may run concurrently. */
bool gl_game_text_notice(const gl_game_text *text, gc_string line, gl_game_text_notice_match *out);
bool gl_game_text_is_drone_footer(const gl_game_text *text, gc_string line);
bool gl_game_text_is_hacking_label(const gl_game_text *text, gc_string line);
bool gl_game_text_hacking_label_language(const gl_game_text *text, gc_string line, gc_language *out);
bool gl_game_text_bonus_title_language(const gl_game_text *text, gc_string line, gc_language *out);
bool gl_game_text_is_speed_label(const gl_game_text *text, gc_string line);
gl_game_text_title_kind gl_game_text_title(const gl_game_text *text, gc_string line);
/** `effect(_:)`: false for nil. */
bool gl_game_text_effect(const gl_game_text *text, gc_string line, gc_string *out);
/** `item(named:clipped:)`: false for nil. */
bool gl_game_text_item(const gl_game_text *text, gc_string name, bool clipped, gc_string *out);

/* ------------------------------------------------------------------------ */
/* Command notices (reference: CommandNoticeParser in HackCommandSummary.swift,
 * CommandNoticeCapture in GlyphRecognitionImages/CommandNoticeReader.swift,
 * DroneFooterProbe.matches)                                                 */

/** `CommandNoticeReading`. `language` is valid until the next call on the
 *  handle that returned it (input readings: for the call). */
typedef struct gl_command_parser_reading {
    gl_game_text_notice_kind notice;
    double confidence;
    bool hasLanguage;
    gc_string language;
    bool isClear;
} gl_command_parser_reading;

/** One recognized line: text and confidence. */
typedef struct gl_command_parser_line {
    gc_string text;
    double confidence;
} gl_command_parser_line;

typedef struct gl_command_parser gl_command_parser;

/** `CommandNoticeParser(language:)`, over a copy of `text`. */
gl_command_parser *gl_command_parser_create(const gl_game_text *text);
void gl_command_parser_destroy(gl_command_parser *parser);
gl_command_parser_reading gl_command_parser_read(const gl_command_parser *parser,
                                                 const gl_command_parser_line *lines, int32_t count);

/** `HackCommand?`. */
typedef enum gl_command_capture_command {
    GL_COMMAND_CAPTURE_COMMAND_NONE = 0,
    GL_COMMAND_CAPTURE_COMMAND_SIMPLE,
    GL_COMMAND_CAPTURE_COMMAND_COMPLEX,
    GL_COMMAND_CAPTURE_COMMAND_REQUEST_KEY,
    GL_COMMAND_CAPTURE_COMMAND_NO_KEY,
    GL_COMMAND_CAPTURE_COMMAND_KEYS_ONLY
} gl_command_capture_command;

/** `HackCommandSummary.Selection.Status`. */
typedef enum gl_command_capture_status {
    GL_COMMAND_CAPTURE_STATUS_NO_COMMAND_OBSERVED = 0,
    GL_COMMAND_CAPTURE_STATUS_CONFIRMED,
    GL_COMMAND_CAPTURE_STATUS_UNRESOLVED,
    GL_COMMAND_CAPTURE_STATUS_NOT_APPLICABLE
} gl_command_capture_status;

/** `HackCommandSummary.Mode`. */
typedef enum gl_command_capture_window_mode {
    GL_COMMAND_CAPTURE_WINDOW_MODE_UNKNOWN = 0,
    GL_COMMAND_CAPTURE_WINDOW_MODE_PORTAL,
    GL_COMMAND_CAPTURE_WINDOW_MODE_DRONE
} gl_command_capture_window_mode;

/** `HackCommandSummary.Selection`. */
typedef struct gl_command_capture_selection {
    gl_command_capture_status status;
    gl_command_capture_command lastObserved;
    int64_t samples;
    bool hasLanguage;
    gc_string language;
} gl_command_capture_selection;

/** `HackCommandSummary`. */
typedef struct gl_command_capture_hack_summary {
    gl_command_capture_selection presentation;
    gl_command_capture_selection gear;
    gl_command_capture_window_mode mode;
} gl_command_capture_hack_summary;

/** `CommandNoticeFrame` with its image replaced by the caller's token for
 *  it. `signature` (when `hasSignature`) is `signatureCount` bytes. */
typedef struct gl_command_capture_frame {
    int64_t id;
    double sourceTime;
    int64_t imageToken;
    bool isMode;
    int64_t generation;
    bool hasSignature;
    const uint8_t *signature;
    int32_t signatureCount;
} gl_command_capture_frame;

/** What `CommandNoticeDetector.detect` found: the box's rect width and its
 *  signature. */
typedef struct gl_command_capture_box {
    double width;
    const uint8_t *signature;
    int32_t signatureCount;
} gl_command_capture_box;

typedef enum gl_command_capture_footer {
    /** The confirmed footer's pixels again: a candidate, no read. */
    GL_COMMAND_CAPTURE_FOOTER_REUSED = 0,
    /** A candidate to read: the caller crops it and calls
     *  `gl_command_capture_add_mode_read` when the crop is made. */
    GL_COMMAND_CAPTURE_FOOTER_READ,
    /** A candidate, but the queue is full: nothing is read. */
    GL_COMMAND_CAPTURE_FOOTER_QUEUE_FULL
} gl_command_capture_footer;

typedef struct gl_command_capture gl_command_capture;

/* `CommandNoticeCapture` without its pixels: the caller runs the detector,
 * the footer probe and the crops, and passes what they found. Frames the
 * functions return (and their signatures) are valid until the next call. */
gl_command_capture *gl_command_capture_create(void);
void gl_command_capture_destroy(gl_command_capture *capture);
/** `observe(band:at:)` up to decoding the band. False: the frame is skipped
 *  (a repeated or non-finite time), and the caller stops. */
bool gl_command_capture_begin_frame(gl_command_capture *capture, double time);
/** The rest of `observe(band:at:)`: `box` is the detector's box or NULL;
 *  `obscured` (read only without a box) whether the band's lower rows are
 *  covered. Returns whether a sample is due: the caller crops the band to
 *  the box and, when the crop is made, calls `gl_command_capture_add_sample`. */
bool gl_command_capture_observe_box(gl_command_capture *capture, double time, const gl_command_capture_box *box,
                                    bool obscured);
void gl_command_capture_add_sample(gl_command_capture *capture, double time, int64_t imageToken);
/** `observeMode(in:at:panelShowing:)`'s first guard: whether to probe now. */
bool gl_command_capture_mode_probe_due(gl_command_capture *capture, double time, bool panelShowing);
/** The probe found a footer candidate with this signature. */
gl_command_capture_footer gl_command_capture_mode_candidate(gl_command_capture *capture, double time,
                                                            const uint8_t *signature, int32_t signatureCount);
void gl_command_capture_add_mode_read(gl_command_capture *capture, double time, const uint8_t *signature,
                                      int32_t signatureCount, int64_t imageToken);
/** `take(at:)`: false for nil. */
bool gl_command_capture_take(gl_command_capture *capture, double time, gl_command_capture_frame *out);
/** `takeDropped()`: the ids at `*ids`, valid until the next call. */
int32_t gl_command_capture_take_dropped(gl_command_capture *capture, const int64_t **ids);
void gl_command_capture_interrupt(gl_command_capture *capture, double time);
void gl_command_capture_invalidate_queue(gl_command_capture *capture, double time);
void gl_command_capture_accept(gl_command_capture *capture, gl_command_parser_reading read,
                               const gl_command_capture_frame *frame);
void gl_command_capture_bind(gl_command_capture *capture, int64_t hackID);
void gl_command_capture_cancel(gl_command_capture *capture);
gl_command_capture_hack_summary gl_command_capture_summary(gl_command_capture *capture, int64_t hackID);
bool gl_command_capture_shows_notice(const gl_command_capture *capture);
/** `queue`: the frames at `*frames`, valid until the next call. */
int32_t gl_command_capture_queue(gl_command_capture *capture, const gl_command_capture_frame **frames);
int64_t gl_command_capture_mode_candidates(const gl_command_capture *capture);
int64_t gl_command_capture_mode_reads(const gl_command_capture *capture);
int64_t gl_command_capture_mode_reuses(const gl_command_capture *capture);
/** `noticeReadAt`: false when nil. Appended after the integration. */
bool gl_command_capture_notice_read_at(const gl_command_capture *capture, double *out);
/** `DroneFooterProbe.matches(_:_:)`. */
bool gl_command_capture_footer_signatures_match(const uint8_t *signature, int32_t signatureCount,
                                                const uint8_t *known, int32_t knownCount);

/* ------------------------------------------------------------------------ */
/* Portal level (reference: PortalLevel.swift, PortalScreenParser in        */
/* PortalScreenDetector.swift)                                               */

/** `PortalFaction?`. */
typedef enum gl_portal_faction {
    GL_PORTAL_FACTION_NONE = 0,
    GL_PORTAL_FACTION_RESISTANCE,
    GL_PORTAL_FACTION_ENLIGHTENED,
    GL_PORTAL_FACTION_MACHINA
} gl_portal_faction;

/** `PortalScreenEvidence`. `resonators` is `resonatorCount` levels. */
typedef struct gl_portal_evidence {
    double sourceTime;
    const int32_t *resonators;
    int32_t resonatorCount;
    int32_t unreadSlots;
    gc_opt_double badgeHue;
    gl_portal_faction faction;
} gl_portal_evidence;

/** `PortalLevelObserver.Policy`. */
typedef struct gl_portal_observer_policy {
    double attachWindow;
    double sameScreen;
} gl_portal_observer_policy;

typedef struct gl_portal_observer gl_portal_observer;

gl_portal_observer_policy gl_portal_observer_policy_default(void);
/** `policy` may be NULL for the defaults. */
gl_portal_observer *gl_portal_observer_create(const gl_portal_observer_policy *policy);
void gl_portal_observer_destroy(gl_portal_observer *observer);
void gl_portal_observer_accept(gl_portal_observer *observer, const gl_portal_evidence *evidence);
/** `claim(at:)`: false for nil. `out->resonators` is valid until the next
 *  call. */
bool gl_portal_observer_claim(gl_portal_observer *observer, double time, gl_portal_evidence *out);

/** `PortalLevelEstimate.Confidence`. */
typedef enum gl_portal_confidence {
    GL_PORTAL_CONFIDENCE_LOW = 0,
    GL_PORTAL_CONFIDENCE_MEDIUM,
    GL_PORTAL_CONFIDENCE_HIGH
} gl_portal_confidence;

/** The arguments of `PortalLevelRules.estimate(resonators:unreadSlots:
 *  badgeHue:glyphCount:)`, plus the screen's faction that
 *  `estimate(screen:glyphCount:)` adds. */
typedef struct gl_portal_rules_input {
    bool hasResonators;
    const int32_t *resonators;
    int32_t resonatorCount;
    gc_opt_int32 unreadSlots;
    gc_opt_double badgeHue;
    gc_opt_int32 glyphCount;
    gl_portal_faction faction;
} gl_portal_rules_input;

/** `PortalLevelEstimate`; `faction` stands for `factionCode`.
 *  `resonators` points at the input's levels. */
typedef struct gl_portal_estimate {
    gc_opt_int32 level;
    int32_t lowest;
    int32_t highest;
    gl_portal_confidence confidence;
    bool conflict;
    bool hasResonators;
    const int32_t *resonators;
    int32_t resonatorCount;
    gc_opt_int32 unreadSlots;
    bool hasBadgeLevels;
    int32_t badgeLevels[8];
    int32_t badgeLevelCount;
    gc_opt_int32 glyphCount;
    gl_portal_faction faction;
} gl_portal_estimate;

/** An inclusive level range; `has` false for nil. */
typedef struct gl_portal_levels {
    bool has;
    int32_t lowest;
    int32_t highest;
} gl_portal_levels;

gl_portal_levels gl_portal_rules_levels_for_glyph_count(int32_t count);
gl_portal_levels gl_portal_rules_levels_for_badge_hue(double hue);
/** False where Swift would trap on an empty range (more than eight levels
 *  read); `out` is then untouched. */
bool gl_portal_rules_levels_for_resonators(const int32_t *read, int32_t count, int32_t unread,
                                           gl_portal_levels *out);
/** `estimate`: false for nil, and where Swift would trap (see above). */
bool gl_portal_rules_estimate(const gl_portal_rules_input *input, gl_portal_estimate *out);
/** `estimate(...glyphCountSettled:)`; `gl_portal_rules_estimate` is this
 *  with `glyphCountSettled` true. Appended after the integration. */
bool gl_portal_rules_estimate_settled(const gl_portal_rules_input *input, bool glyphCountSettled,
                                      gl_portal_estimate *out);

/** `PortalScreenParser.read(lines:badgeHue:at:faction:yellowLabels:)`.
 *  `resonatorsOut` has room for the eight levels a read keeps at most;
 *  `out->resonators` points at it. */
typedef struct gl_portal_parser_line {
    gc_string text;
    double confidence;
} gl_portal_parser_line;

void gl_portal_parser_read(const gl_portal_parser_line *lines, int32_t count, gc_opt_double badgeHue, double time,
                           gl_portal_faction faction, const int32_t *yellowLabels, int32_t yellowLabelCount,
                           int32_t resonatorsOut[8], gl_portal_evidence *out);
/** `PortalScreenParser.levels(in:)` into `out` (capacity `capacity`).
 *  Returns the count, or the count needed when it exceeds the capacity
 *  (then `out` is untouched). */
int32_t gl_portal_parser_levels(gc_string text, int32_t *out, int32_t capacity);
/** `PortalScreenParser.isLevelOneYellow(hues:)`. */
bool gl_portal_parser_is_level_one_yellow(const double *hues, int32_t count);

#ifdef __cplusplus
}
#endif

#endif /* GLYPH_LOGIC_PACE_H */
