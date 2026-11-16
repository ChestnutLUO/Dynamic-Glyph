#ifndef GLYPH_CORE_H
#define GLYPH_CORE_H

/*
 * GlyphCore: the pixel recognition core in C++, behind a C ABI.
 *
 * This header is the contract between the C++ engine and the Swift bridge
 * (`GlyphRecognitionCxx`). Every function is a pure computation on memory the
 * caller owns, except the session, which caches the node array fit between
 * frames. Nothing here allocates on the caller's behalf except the session.
 *
 * Reference behaviour is the Swift code in `Sources/GlyphRecognition`. Where
 * an option says "the Swift behaviour", the Swift file named is the oracle
 * and the equivalence tests in `Tests/GlyphRecognitionTests/Cxx` hold the
 * two to the same output on the same pixels.
 *
 * Coordinates: top-left origin, x to the right, y down, like the images.
 * Fractions are of the full frame's width or height.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Images                                                                    */

/** An 8-bit luminance image, 0 black to 255 white, rows `bytesPerRow` apart.
 *  A capture's Y plane is used in place when it is already full range. */
typedef struct gc_gray_image {
    const uint8_t *data;
    int32_t width;
    int32_t height;
    int32_t bytesPerRow;
} gc_gray_image;

/** A packed colour image. `bytesPerPixel` is 3 (RGB, as `ColorImage`) or 4
 *  (BGRA straight from a capture); the offsets say where each channel sits
 *  within a pixel. Rows are `bytesPerRow` apart. */
typedef struct gc_color_image {
    const uint8_t *data;
    int32_t width;
    int32_t height;
    int32_t bytesPerRow;
    int32_t bytesPerPixel;
    int32_t redOffset;
    int32_t greenOffset;
    int32_t blueOffset;
} gc_color_image;

/** The ABI version this library was built from. The Swift bridge checks it. */
uint32_t gc_version(void);
#define GC_VERSION 1u

/* ------------------------------------------------------------------------ */
/* 1. Luminance and colour conversion (reference: LumaGate.swift,            */
/*    ImageDecoder.swift)                                                    */

/** Packs an NV12 Y plane into `out` (width * height bytes, no padding).
 *  Video range (16-235) is stretched to full range with the same table as
 *  `LumaGate.videoRangeTable`: ((v - 16) * 255 + 109) / 219, clamped. */
void gc_luma_from_plane(const uint8_t *yPlane, int32_t width, int32_t height, int32_t bytesPerRow,
                        bool videoRange, uint8_t *out);

/** Packs luma from 32-bit BGRA into `out`, with the fixed-point BT.601
 *  weights `LumaGate.read(bgra:)` uses: (29 B + 150 G + 77 R) >> 8. */
void gc_luma_from_bgra(const uint8_t *bgra, int32_t width, int32_t height, int32_t bytesPerRow, uint8_t *out);

/** Converts rows [rowTop, rowTop + rowCount) of an NV12 frame to packed RGB
 *  (3 bytes per pixel, red first, no padding) in `out`, BT.709, so the colour
 *  readers can run on a capture without Core Graphics. The CbCr plane is
 *  half resolution in both directions. */
void gc_rgb_from_nv12(const uint8_t *yPlane, int32_t yBytesPerRow, const uint8_t *cbcrPlane,
                      int32_t cbcrBytesPerRow, int32_t width, int32_t frameHeight, int32_t rowTop,
                      int32_t rowCount, bool videoRange, uint8_t *out);

#define GC_GATE_COLUMNS 12
#define GC_GATE_ROWS 24
#define GC_GATE_CELLS (GC_GATE_COLUMNS * GC_GATE_ROWS)

/** `LumaGateReading`. */
typedef struct gc_gate_reading {
    double darkFraction;
    double brightFraction;
    uint8_t cells[GC_GATE_CELLS];
    bool isCandidate;
} gc_gate_reading;

/** `LumaGate(step:).read(_:)` on a luma image. `step` >= 1. Returns false
 *  for an empty image. */
bool gc_gate_read(gc_gray_image luma, int32_t step, gc_gate_reading *out);

/** `LumaGate.read(bgra:...)`: the gate straight from a BGRA buffer. */
bool gc_gate_read_bgra(gc_color_image bgra, int32_t step, gc_gate_reading *out);

/* ------------------------------------------------------------------------ */
/* 2. Node array and Glyph reading (reference: NodeArrayDetector.swift,      */
/*    GlyphFrameRecognizer.swift, GlyphFrameSession.swift, GlyphGeometry)     */

#define GC_NODE_COUNT 11
#define GC_EDGE_SAMPLES 24
/** Capacity for the elementary lattice edges; the real count is
 *  `gc_elementary_edge_count()`. */
#define GC_MAX_ELEMENTARY_EDGES 64
#define GC_MAX_TEMPLATES 512
#define GC_MAX_TEMPLATE_EDGES 24

/** `NodeArrayDetection`. `matchedNodes` is a bitmask: bit n set means node n
 *  (0...10, `a` = 10) matched a ring. */
typedef struct gc_fit {
    int32_t imageWidth;
    int32_t imageHeight;
    double originX;
    double originY;
    double sizeX;
    double sizeY;
    double nodeRadius;
    uint16_t matchedNodes;
    double rootMeanSquareError;
} gc_fit;

/** How the node array is hunted. The defaults reproduce `NodeArrayDetector`
 *  exactly; the other values are power cuts, each measured by replay against
 *  the defaults. */
typedef struct gc_hunt_options {
    /** Rows scanned for ring components, as fractions of the frame height.
     *  0 and 1 scan the whole frame (the Swift behaviour). A ring outside the
     *  rows is never found; the fit's bounds are still checked against the
     *  whole frame. */
    double rowTop;
    double rowBottom;
    /** Components are traced on every `scale`th pixel in both directions,
     *  then each surviving ring's centroid and radius are refined on the full
     *  pixels inside its box. 1 is the Swift behaviour. */
    int32_t scale;
} gc_hunt_options;

/** The Swift behaviour: whole frame, full resolution. */
gc_hunt_options gc_hunt_options_default(void);

/** `NodeArrayDetector().detect(in:)`. Returns false when no array is found.
 *  Allocates nothing that outlives the call; a session reuses its buffers
 *  across frames, so prefer `gc_session_observe` in a loop. */
bool gc_detect_array(gc_gray_image luma, const gc_hunt_options *options, gc_fit *out);

/** One undirected lattice edge between two nodes, lower index first. */
typedef struct gc_edge {
    uint8_t lower;
    uint8_t upper;
} gc_edge;

/** The elementary edges, in the order `GlyphGeometry.elementaryEdges` lists
 *  them (a < b ascending, no node in between). Observation samples use this
 *  order. */
int32_t gc_elementary_edge_count(void);
bool gc_elementary_edge(int32_t index, gc_edge *out);

/** One Glyph's path as the undirected edges of its node walk
 *  (`GlyphPath.undirectedEdges`), unnormalised: the core splits collinear
 *  through-node segments itself, as `GlyphGeometry.normalizedEdges` does. */
typedef struct gc_template {
    gc_edge edges[GC_MAX_TEMPLATE_EDGES];
    int32_t edgeCount;
} gc_template;

/** `GlyphFrameObservation.State`, plus NONE for "no observation". */
typedef enum gc_observation_state {
    GC_STATE_NONE = 0,
    GC_STATE_CALIBRATION_UNAVAILABLE,
    GC_STATE_CALIBRATION_MISMATCH,
    GC_STATE_NO_STROKE,
    GC_STATE_UNRECOGNIZED_STROKE,
    GC_STATE_UNEXPLAINED_INK,
    GC_STATE_AMBIGUOUS_SHAPE,
    GC_STATE_UNIQUE_VISIBLE_SHAPE
} gc_observation_state;

/** `GlyphCandidate`: `templateIndex` is the index the template had at
 *  session creation. */
typedef struct gc_candidate {
    int32_t templateIndex;
    int32_t distance;
} gc_candidate;

/** `GlyphFrameObservation`. The ink pixel indices are read separately with
 *  `gc_session_ink_pixels`. Candidates are sorted by (distance, templateIndex);
 *  the bridge passes templates sorted by name, so this is the Swift order.
 *  Extensions are template indices ascending. */
typedef struct gc_observation {
    gc_observation_state state;
    bool hasCalibration;
    gc_fit calibration;
    int32_t edgeCount;
    double samples[GC_MAX_ELEMENTARY_EDGES][GC_EDGE_SAMPLES];
    int32_t strokePixelCount;
    int32_t unexplainedInkPixelCount;
    int32_t candidateCount;
    gc_candidate candidates[GC_MAX_TEMPLATES];
    int32_t extensionCount;
    int32_t extensions[GC_MAX_TEMPLATES];
} gc_observation;

/** A live session: the templates, the cached fit and the reusable buffers.
 *  The ink pixels of the last observation are read with
 *  `gc_session_ink_pixels`. */
typedef struct gc_session gc_session;

/** Creates a session over `count` templates (at most GC_MAX_TEMPLATES) with
 *  `GlyphFrameRecognizer`'s edge distance limit (2 in the app). NULL when the
 *  arguments are out of range. */
gc_session *gc_session_create(const gc_template *templates, int32_t count, int32_t maxEdgeDistance,
                              const gc_hunt_options *hunt);
void gc_session_destroy(gc_session *session);

/** `GlyphFrameSession.reset()`. */
void gc_session_reset(gc_session *session);

/** What `GlyphFrameSession.observe(_:at:)` returns and records. */
typedef struct gc_session_result {
    /** False when the Swift method would return nil. */
    bool hasObservation;
    gc_observation observation;
    /** `lastGridHuntNanoseconds`: set only when a hunt ran this call. */
    bool huntRan;
    uint64_t huntNanoseconds;
    /** `validatedAt`, after this call. */
    bool hasValidatedAt;
    double validatedAt;
    /** `calibration`, after this call. */
    bool hasCalibration;
    gc_fit calibration;
} gc_session_result;

/** `GlyphFrameSession.observe(_:at:)`. The session keeps its own buffers for
 *  the hunt and the ink pixels, so a steady state allocates nothing. */
void gc_session_observe(gc_session *session, gc_gray_image luma, double time, gc_session_result *out);

/** `GlyphFrameRecognizer.observe(_:calibration:)` on the session's
 *  templates with a given fit; `out->calibration` is set to `fit`. */
void gc_session_observe_with_fit(gc_session *session, gc_gray_image luma, const gc_fit *fit,
                                 gc_observation *out);

/** The last observation's `inkPixels` (row-major indices y * width + x, in
 *  scan order), valid until the next observe, reset or destroy. */
const int32_t *gc_session_ink_pixels(const gc_session *session, int32_t *count);

/* ------------------------------------------------------------------------ */
/* 3. Slot strip and input timer (reference: SlotStripReader.swift,          */
/*    GameUILayout.swift)                                                    */

#define GC_MAX_SLOTS 5

/** `GameUILayout`, field for field. */
typedef struct gc_layout {
    double headerTextTop;
    double headerTextBottom;
    double slotStripTop;
    double slotStripBottom;
    double inputTimerBarTop;
    double inputTimerBarBottom;
    double inputTimerBarMinimumWidth;
    double slotMarkerMinimumWidth;
    double slotMarkerMaximumWidth;
    int32_t slotMarkerMinimumColumnHits;
    double slotPitchTolerance;
    double slotCenterPitch;
    double slotCenterTolerance;
    double inputTimerTrackLeft;
    double inputTimerTrackRight;
    double inputTimerEndpointTolerance;
    double bannerMinimumRowCoverage;
    double bannerMinimumHeight;
    double coveredMarkerMinimumHeight;
} gc_layout;

/** `GameUILayout()`'s measured values. */
gc_layout gc_layout_default(void);

/** `SlotStripRejection`, with OK for a reading. */
typedef enum gc_slot_status {
    GC_SLOT_OK = 0,
    GC_SLOT_BAND_UNAVAILABLE,
    GC_SLOT_NO_MARKERS,
    GC_SLOT_TOO_MANY_MARKERS,
    GC_SLOT_UNEVEN_SPACING,
    GC_SLOT_INCONSISTENT_MARKER_WIDTHS,
    GC_SLOT_MULTIPLE_HIGHLIGHTS,
    GC_SLOT_INCOMPLETE_MARKER_HEIGHT,
    GC_SLOT_INCOMPLETE_STRIP,
    GC_SLOT_COVERED_BY_OVERLAY
} gc_slot_status;

/** `SlotStripWindowCover.Side`, with NONE for no window. */
typedef enum gc_window_side {
    GC_WINDOW_NONE = 0,
    GC_WINDOW_LEFT,
    GC_WINDOW_RIGHT
} gc_window_side;

/** `SlotStripReading`; `highlightedIndex` is -1 for none. The fields from
 *  `windowSide` on are `SlotStripObservation.cover`: set only when the
 *  reading failed and our own window covers one side of the row. */
typedef struct gc_slot_reading {
    gc_slot_status status;
    int32_t slotCount;
    int32_t highlightedIndex;
    double markerCentersX[GC_MAX_SLOTS];
    bool hasInputTimerBar;
    bool isPartlyCovered;
    gc_window_side windowSide;
    double coveredFrom;
    double coveredTo;
    /** `SlotStripWindowCover.row`: `partialCount` centres, the highlighted
     *  one's index or -1. */
    bool hasPartialRow;
    int32_t partialCount;
    int32_t partialHighlightedMarker;
    double partialCentersX[GC_MAX_SLOTS];
    bool hasPartialTimerBar;
} gc_slot_reading;

/** `SlotStripReader(layout:).observe(_:)` on a `FrameTopBand`: `band` holds
 *  the frame's first rows, full width; `frameHeight` resolves the fractions. */
void gc_slot_strip_read(gc_color_image band, int32_t frameHeight, const gc_layout *layout, gc_slot_reading *out);

/** `SlotStripReader.hasTimerBar(_:)`. */
bool gc_timer_bar(gc_color_image band, int32_t frameHeight, const gc_layout *layout);

/* ------------------------------------------------------------------------ */
/* 4. Panels and notices (reference: ResultPanelDetector.swift,              */
/*    GearDropPanelDetector.swift, PortalScreenDetector.swift,                */
/*    CommandNoticeReader.swift's CommandNoticeDetector)                      */

/** `ResultPanelDetector().isCandidate(_:)` on the whole frame's luma. */
bool gc_result_candidate(gc_gray_image luma);

/** `GearDropPanelDetector.band(frameHeight:)`: rows [top, bottom). */
void gc_gear_band(int32_t frameHeight, int32_t *top, int32_t *bottom);

/** `GearDropPanelBounds`, as fractions of the frame height. */
typedef struct gc_panel_bounds {
    double top;
    double bottom;
} gc_panel_bounds;

/** `GearDropPanelDetector().candidate(in:frameHeight:bandTop:)`: `band`
 *  holds frame rows from `bandTop`, full width. */
bool gc_gear_candidate(gc_color_image band, int32_t frameHeight, int32_t bandTop, gc_panel_bounds *out);

/** `PortalScreenDetector.band(frameHeight:)`: rows [top, bottom). */
void gc_portal_band(int32_t frameHeight, int32_t *top, int32_t *bottom);

/** `PortalFaction`, with NONE for "not a portal screen". */
typedef enum gc_faction {
    GC_FACTION_NONE = 0,
    GC_FACTION_RESISTANCE,
    GC_FACTION_ENLIGHTENED,
    GC_FACTION_MACHINA
} gc_faction;

/** `PortalScreenDetector().faction(_:frameHeight:bandTop:)`. */
gc_faction gc_portal_faction(gc_color_image band, int32_t frameHeight, int32_t bandTop);

/** `CommandNoticeDetector.band(width:height:)`: the band's rows [top, bottom)
 *  over the full width. */
void gc_command_band(int32_t frameWidth, int32_t frameHeight, int32_t *top, int32_t *bottom);

/** `CommandNoticeDetector.Box`: the rect in the band's own pixels and the
 *  64 x 16 signature, row-major, 1 where the sample is brighter than 140. */
typedef struct gc_command_box {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
    uint8_t signature[64 * 16];
} gc_command_box;

/** `CommandNoticeDetector().detect(_:)` on the band's luma. */
bool gc_command_box_detect(gc_gray_image bandLuma, gc_command_box *out);

/* ------------------------------------------------------------------------ */
/* 5. Region prefilters (the `planeGate` cut, appended last). Each          */
/*    reads a top-left rectangle of the capture's planes in place. It can   */
/*    only say that the rectangle certainly holds nothing for its detector, */
/*    which is then not rendered; anything else is rendered and detected as */
/*    before.                                                               */

/** A capture's planes: NV12 (the Y plane and the interleaved CbCr plane at
 *  half resolution in both directions) or packed little-endian BGRA. */
typedef struct gc_frame_planes {
    /** The Y plane, or the BGRA buffer. */
    const uint8_t *base;
    int32_t bytesPerRow;
    /** The CbCr plane; NULL for BGRA. */
    const uint8_t *chroma;
    int32_t chromaBytesPerRow;
    int32_t width;
    int32_t height;
    bool bgra;
    /** NV12 only: Y in 16-235, chroma in 16-240. */
    bool videoRange;
} gc_frame_planes;

/** The brightest luma in the rectangle: the Y plane, stretched to full range
 *  as `gc_luma_from_plane` does, or BGRA's luma as `gc_luma_from_bgra`. -1
 *  when the frame or the rectangle (clipped to the frame) is empty or
 *  malformed. */
int32_t gc_region_max_luma(gc_frame_planes frame, int32_t left, int32_t top, int32_t width, int32_t height);

/** The pixels of the rectangle that could be the drone footer's yellow
 *  under thresholds looser than `DroneFooterProbe`'s: NV12 Y > 70 and Cb <
 *  120, as stored; BGRA R > 110, G > 80 and 5 B < 4 G. -1 as for
 *  `gc_region_max_luma`. */
int32_t gc_region_yellow_count(gc_frame_planes frame, int32_t left, int32_t top, int32_t width, int32_t height);

#ifdef __cplusplus
}
#endif

#endif /* GLYPH_CORE_H */
