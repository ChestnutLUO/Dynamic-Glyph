// The slot indicator strip and the input countdown bar, ported from
// SlotStripReader.swift and GameUILayout.swift. Every rounding, threshold and
// order of checks follows the Swift reader so the equivalence tests can hold
// the two to the same reading on the same pixels.

#include "glyph_core.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <type_traits>
#include <vector>

// Swift never fuses `a * b + c` into one rounding; keep the C++ arithmetic
// on the same path so a tolerance comparison cannot flip on the last bit.
#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace {

struct Range {
    int32_t lower;
    int32_t upper;
    bool empty() const { return lower >= upper; }
};

/// `FrameTopBand.rows(_:_:)`: fractions of the frame height, clamped to the band.
Range bandRows(const gc_color_image &band, int32_t frameHeight, double top, double bottom) {
    const double height = static_cast<double>(frameHeight);
    const int32_t first = std::max<int32_t>(0, static_cast<int32_t>(std::floor(top * height)));
    const int32_t last = std::min<int32_t>(band.height, static_cast<int32_t>(std::ceil(bottom * height)));
    return first < last ? Range{first, last} : Range{0, 0};
}

/// `GameUILayout.bannerEdgeTolerance(frameHeight:)`.
int32_t bannerEdgeTolerance(int32_t frameHeight) {
    return std::max<int32_t>(1, static_cast<int32_t>(std::ceil(0.002 * static_cast<double>(frameHeight))));
}

struct EdgeColumns {
    int32_t margin;
    int32_t zone;
};

/// `GameUILayout.slotEdgeColumns(frameWidth:maximumSlots:)` for `GC_MAX_SLOTS`:
/// columns at each side that no indicator can reach (`margin`, 0.04 of the
/// width by default) or start in (`zone`, 0.1775), after a 0.01 allowance.
EdgeColumns slotEdgeColumns(const gc_layout &layout, int32_t frameWidth) {
    const double allowance = 0.01;
    const double outerCentre = 0.5 - static_cast<double>(GC_MAX_SLOTS - 1) / 2 * layout.slotCenterPitch
        - layout.slotCenterTolerance;
    const double width = static_cast<double>(frameWidth);
    const int32_t margin = static_cast<int32_t>((outerCentre - layout.slotMarkerMaximumWidth / 2 - allowance) * width);
    const int32_t zone = static_cast<int32_t>((outerCentre + layout.slotMarkerMinimumWidth / 2 - allowance) * width);
    return EdgeColumns{std::max<int32_t>(0, margin), std::max<int32_t>(0, zone)};
}

struct Pixel {
    uint8_t red;
    uint8_t green;
    uint8_t blue;
};

inline Pixel pixelAt(const gc_color_image &image, int32_t x, int32_t y) {
    const uint8_t *base = image.data + static_cast<size_t>(y) * static_cast<size_t>(image.bytesPerRow)
        + static_cast<size_t>(x) * static_cast<size_t>(image.bytesPerPixel);
    return Pixel{base[image.redOffset], base[image.greenOffset], base[image.blueOffset]};
}

inline bool isGold(const Pixel &p) {
    return p.red > 150 && p.green > 90 && p.blue < 110 && static_cast<int>(p.red) - static_cast<int>(p.blue) > 70;
}

inline bool isViolet(const Pixel &p) {
    return p.blue > 110 && p.blue >= p.red && p.blue >= p.green;
}

inline bool isLit(const Pixel &p) {
    return std::max(p.red, std::max(p.green, p.blue)) >= 60;
}

bool validBand(const gc_color_image &band) {
    return band.data != nullptr && band.width > 0 && band.height > 0
        && (band.bytesPerPixel == 3 || band.bytesPerPixel == 4)
        && band.bytesPerRow >= band.width * band.bytesPerPixel
        && band.redOffset >= 0 && band.redOffset < band.bytesPerPixel
        && band.greenOffset >= 0 && band.greenOffset < band.bytesPerPixel
        && band.blueOffset >= 0 && band.blueOffset < band.bytesPerPixel;
}

/// `SlotStripReader.litRowsFromTop(_:in:)`.
int32_t litRowsFromTop(const gc_color_image &band, const gc_layout &layout, Range rows) {
    const int32_t required = static_cast<int32_t>(
        std::ceil(layout.bannerMinimumRowCoverage * static_cast<double>(band.width)));
    int32_t count = 0;
    for (int32_t y = rows.lower; y < rows.upper; ++y) {
        int32_t lit = 0;
        for (int32_t x = 0; x < band.width; ++x) {
            if (isLit(pixelAt(band, x, y))) lit += 1;
        }
        if (lit < required) break;
        count += 1;
    }
    return count;
}

/// `SlotStripReader.firstRowBelowBanner(litRowsFromTop:band:)`; false for nil.
bool firstRowBelowBanner(const gc_color_image &band, int32_t frameHeight, const gc_layout &layout,
                         int32_t litRows, int32_t *row) {
    const int32_t stripTop = bandRows(band, frameHeight, layout.slotStripTop, layout.slotStripBottom).lower;
    const int32_t minimumRows = std::max<int32_t>(
        1, static_cast<int32_t>(std::ceil(layout.bannerMinimumHeight * static_cast<double>(frameHeight))));
    if (litRows < minimumRows) return false;
    *row = stripTop + litRows + bannerEdgeTolerance(frameHeight);
    return true;
}

/// `SlotStripReader.hasTimerBar(_:)`.
bool hasTimerBar(const gc_color_image &band, int32_t frameHeight, const gc_layout &layout) {
    const Range rows = bandRows(band, frameHeight, layout.inputTimerBarTop, layout.inputTimerBarBottom);
    if (rows.empty()) return false;
    const double width = static_cast<double>(band.width);
    const int32_t required = static_cast<int32_t>(layout.inputTimerBarMinimumWidth * width);
    const double tolerance = layout.inputTimerEndpointTolerance * width;
    const double expectedLeft = layout.inputTimerTrackLeft * width;
    const double expectedRight = layout.inputTimerTrackRight * width;
    const int32_t maximumGap = std::max<int32_t>(1, static_cast<int32_t>(width * 0.005));
    for (int32_t y = rows.lower; y < rows.upper; ++y) {
        bool hasStart = false;
        int32_t start = 0;
        int32_t last = -1;
        int32_t progressRun = 0, longestProgressRun = 0;
        auto matchesTrack = [&]() {
            if (!hasStart) return false;
            return std::fabs(static_cast<double>(start) - expectedLeft) <= tolerance
                && std::fabs(static_cast<double>(last) - expectedRight) <= tolerance
                && longestProgressRun >= required;
        };
        for (int32_t x = 0; x < band.width; ++x) {
            const Pixel p = pixelAt(band, x, y);
            const bool magenta = p.red > 130 && p.blue > 65
                && static_cast<int>(p.red) - static_cast<int>(p.green) > 45
                && static_cast<int>(p.blue) - static_cast<int>(p.green) > 20;
            const bool progress = isGold(p) || magenta;
            if (progress || isViolet(p)) {
                if (!hasStart) { hasStart = true; start = x; }
                last = x;
                progressRun = progress ? progressRun + 1 : 0;
                longestProgressRun = std::max(longestProgressRun, progressRun);
            } else {
                progressRun = 0;
                if (hasStart && x - last > maximumGap) {
                    if (matchesTrack()) return true;
                    hasStart = false;
                    longestProgressRun = 0;
                }
            }
        }
        if (matchesTrack()) return true;
    }
    return false;
}

struct Marker {
    int32_t first;
    int32_t last;
    int32_t gold;
    int32_t violet;
    int32_t width() const { return last - first + 1; }
};

struct Extent {
    int32_t top;
    int32_t bottom;
    int32_t width;
};

/// Per-column tallies over the rows read, sized by the band's width.
struct Columns {
    std::vector<int32_t> gold;
    std::vector<int32_t> violet;
    std::vector<int32_t> firstRows;
    std::vector<int32_t> lastRows;
    std::vector<int32_t> lit;

    explicit Columns(const gc_color_image &band)
        : gold(static_cast<size_t>(band.width), 0),
          violet(static_cast<size_t>(band.width), 0),
          firstRows(static_cast<size_t>(band.width), band.height),
          lastRows(static_cast<size_t>(band.width), -1),
          lit(static_cast<size_t>(band.width), 0) {}
};

// `SlotStripReader.windowCover`'s constants (SlotStripWindowCover.swift).
constexpr double kWindowSideRowShare = 0.9;
constexpr double kWindowSideMinimumShare = 0.04;
constexpr double kWindowSideMaximumWidth = 0.06;
constexpr double kWindowInset = 0.05;
constexpr int kWindowSideColourTolerance = 24;
constexpr int kWindowInteriorContrast = 40;
/// `SlotStripReader.windowSideBlendColumns`: the ring's boundary pixel,
/// lit or not, between the side and the interior sampled.
constexpr int32_t kWindowSideBlendColumns = 1;

inline int grey(const Pixel &p) {
    return (77 * static_cast<int>(p.red) + 150 * static_cast<int>(p.green) + 29 * static_cast<int>(p.blue)) >> 8;
}

/// `SlotStripReader.median(_:)`: the upper median.
uint8_t median(std::vector<uint8_t> &values) {
    std::sort(values.begin(), values.end());
    return values[values.size() / 2];
}

/// `SlotStripReader.hasPartialTimerBar(_:covered:side:)`.
bool hasPartialTimerBar(const gc_color_image &band, int32_t frameHeight, const gc_layout &layout,
                        int32_t coveredLower, int32_t coveredUpper, bool rightSide) {
    const Range rows = bandRows(band, frameHeight, layout.inputTimerBarTop, layout.inputTimerBarBottom);
    if (rows.empty()) return false;
    const int32_t width = band.width;
    const double widthValue = static_cast<double>(width);
    const int32_t required = static_cast<int32_t>(layout.inputTimerBarMinimumWidth * widthValue);
    const double tolerance = layout.inputTimerEndpointTolerance * widthValue;
    const double expectedStart = (rightSide ? layout.inputTimerTrackLeft : layout.inputTimerTrackRight) * widthValue;
    const int32_t maximumGap = std::max<int32_t>(1, static_cast<int32_t>(widthValue * 0.005));
    const int32_t step = rightSide ? 1 : -1;
    for (int32_t y = rows.lower; y < rows.upper; ++y) {
        bool hasStart = false;
        int32_t start = 0;
        int32_t last = 0;
        int32_t progressRun = 0, longestProgressRun = 0;
        auto matches = [&]() {
            if (!hasStart) return false;
            const bool reachesWindow = rightSide ? last + maximumGap + 1 >= coveredLower
                                                 : last - maximumGap - 1 <= coveredUpper;
            return std::fabs(static_cast<double>(start) - expectedStart) <= tolerance && reachesWindow
                && longestProgressRun >= required;
        };
        for (int32_t x = rightSide ? 0 : width - 1; x >= 0 && x < width; x += step) {
            const Pixel p = pixelAt(band, x, y);
            const bool magenta = p.red > 130 && p.blue > 65
                && static_cast<int>(p.red) - static_cast<int>(p.green) > 45
                && static_cast<int>(p.blue) - static_cast<int>(p.green) > 20;
            const bool progress = isGold(p) || magenta;
            if (progress || isViolet(p)) {
                if (!hasStart) { hasStart = true; start = x; }
                last = x;
                progressRun = progress ? progressRun + 1 : 0;
                longestProgressRun = std::max(longestProgressRun, progressRun);
            } else {
                progressRun = 0;
                if (hasStart && std::abs(x - last) > maximumGap) {
                    if (matches()) return true;
                    hasStart = false;
                    longestProgressRun = 0;
                }
            }
        }
        if (matches()) return true;
    }
    return false;
}

/// `SlotStripReader.windowCover(...)`: our own floating window over one side
/// of the row, written to `out`'s cover fields; nothing when there is none.
/// The markers are segmented again, as `read` segments them.
void windowCover(const gc_color_image &band, int32_t frameHeight, const gc_layout &layout, Range rows,
                 const Columns &columns, gc_slot_reading *out) {
    const int32_t width = band.width;
    const int32_t rowCount = rows.upper - rows.lower;
    const int32_t required = static_cast<int32_t>(std::ceil(kWindowSideRowShare * static_cast<double>(rowCount)));
    auto isSide = [&](int32_t x) { return columns.lit[static_cast<size_t>(x)] >= required; };
    const int32_t inset = static_cast<int32_t>(kWindowInset * static_cast<double>(width));
    if (!(width > 2 * (inset + 1))) return;
    bool right = false, left = false;
    for (int32_t x = width - 1 - inset; x < width; ++x) right = right || isSide(x);
    for (int32_t x = 0; x <= inset; ++x) left = left || isSide(x);
    if (right == left) return;

    int32_t nearFirst = -1, nearLast = -1;
    if (right) {
        for (int32_t x = 0; x < width; ++x) {
            if (isSide(x)) { nearFirst = x; break; }
        }
        if (nearFirst < 0) return;
        nearLast = nearFirst;
        while (nearLast + 1 < width && isSide(nearLast + 1)) nearLast += 1;
    } else {
        for (int32_t x = width - 1; x >= 0; --x) {
            if (isSide(x)) { nearLast = x; break; }
        }
        if (nearLast < 0) return;
        nearFirst = nearLast;
        while (nearFirst > 0 && isSide(nearFirst - 1)) nearFirst -= 1;
    }
    const int32_t nearCount = nearLast - nearFirst + 1;
    const int32_t thinnest = std::max<int32_t>(
        2, static_cast<int32_t>(std::ceil(kWindowSideMinimumShare * static_cast<double>(rowCount))));
    const int32_t thickest = static_cast<int32_t>(kWindowSideMaximumWidth * static_cast<double>(width));
    if (nearCount < thinnest || nearCount > thickest) return;
    const int32_t skip = kWindowSideBlendColumns;
    const int32_t interior[2] = {right ? nearLast + skip + 1 : nearFirst - skip - 1,
                                 right ? nearLast + skip + 2 : nearFirst - skip - 2};
    for (int32_t x : interior) {
        if (x < 0 || x >= width) return;
    }

    const int32_t middle = (nearFirst + nearLast) / 2;
    std::vector<uint8_t> reds, greens, blues;
    reds.reserve(static_cast<size_t>(rowCount));
    greens.reserve(static_cast<size_t>(rowCount));
    blues.reserve(static_cast<size_t>(rowCount));
    for (int32_t y = rows.lower; y < rows.upper; ++y) {
        const Pixel p = pixelAt(band, middle, y);
        reds.push_back(p.red);
        greens.push_back(p.green);
        blues.push_back(p.blue);
    }
    const Pixel ring{median(reds), median(greens), median(blues)};
    int32_t smooth = 0;
    for (int32_t y = rows.lower; y < rows.upper; ++y) {
        const Pixel p = pixelAt(band, middle, y);
        if (std::abs(static_cast<int>(p.red) - static_cast<int>(ring.red)) <= kWindowSideColourTolerance
            && std::abs(static_cast<int>(p.green) - static_cast<int>(ring.green)) <= kWindowSideColourTolerance
            && std::abs(static_cast<int>(p.blue) - static_cast<int>(ring.blue)) <= kWindowSideColourTolerance) {
            smooth += 1;
        }
    }
    if (smooth < required) return;

    std::vector<int> interiorGreys;
    interiorGreys.reserve(static_cast<size_t>(rowCount) * 2);
    for (int32_t x : interior) {
        for (int32_t y = rows.lower; y < rows.upper; ++y) interiorGreys.push_back(grey(pixelAt(band, x, y)));
    }
    std::sort(interiorGreys.begin(), interiorGreys.end());
    if (interiorGreys[interiorGreys.size() / 2] > grey(ring) - kWindowInteriorContrast) return;

    const int32_t coveredLower = right ? nearFirst : 0;
    const int32_t coveredUpper = right ? width - 1 : nearLast;
    out->windowSide = right ? GC_WINDOW_RIGHT : GC_WINDOW_LEFT;
    out->coveredFrom = static_cast<double>(coveredLower) / static_cast<double>(width);
    out->coveredTo = static_cast<double>(coveredUpper + 1) / static_cast<double>(width);
    out->hasPartialTimerBar = hasPartialTimerBar(band, frameHeight, layout, coveredLower, coveredUpper, right);

    // `rowBeside`: the markers wholly outside the covered columns, held to
    // the ordinary width, height and single-highlight rules.
    const EdgeColumns edge = slotEdgeColumns(layout, width);
    const double minimumWidth = layout.slotMarkerMinimumWidth * static_cast<double>(width);
    const double maximumWidth = layout.slotMarkerMaximumWidth * static_cast<double>(width);
    Marker visible[GC_MAX_SLOTS];
    int32_t visibleCount = 0;
    bool valid = true;
    bool hasStart = false;
    Marker current{0, 0, 0, 0};
    for (int32_t x = 0; x <= width && valid; ++x) {
        const bool on = x < width
            && columns.gold[static_cast<size_t>(x)] + columns.violet[static_cast<size_t>(x)]
                >= layout.slotMarkerMinimumColumnHits;
        if (on) {
            if (!hasStart) { hasStart = true; current = Marker{x, x, 0, 0}; }
            current.gold += columns.gold[static_cast<size_t>(x)];
            current.violet += columns.violet[static_cast<size_t>(x)];
        } else if (hasStart) {
            current.last = x - 1;
            hasStart = false;
            if ((current.first < edge.margin && current.last < edge.zone)
                || (current.last >= width - edge.margin && current.first >= width - edge.zone)) {
                continue;
            }
            if (!(current.last < coveredLower || current.first > coveredUpper)) continue;
            if (visibleCount == GC_MAX_SLOTS) { valid = false; break; }
            const double markerWidth = static_cast<double>(current.width());
            if (!(markerWidth >= minimumWidth && markerWidth <= maximumWidth)) { valid = false; break; }
            int32_t top = band.height, bottom = -1;
            for (int32_t column = current.first; column <= current.last; ++column) {
                top = std::min(top, columns.firstRows[static_cast<size_t>(column)]);
                bottom = std::max(bottom, columns.lastRows[static_cast<size_t>(column)]);
            }
            if (!(static_cast<double>(bottom - top + 1) >= markerWidth * 0.8)) { valid = false; break; }
            visible[visibleCount++] = current;
        }
    }
    if (!valid || visibleCount == 0) return;
    int32_t highlightCount = 0, highlighted = -1;
    for (int32_t i = 0; i < visibleCount; ++i) {
        if (visible[i].gold > visible[i].violet) {
            if (highlightCount == 0) highlighted = i;
            highlightCount += 1;
        }
    }
    if (highlightCount > 1) return;
    out->hasPartialRow = true;
    out->partialCount = visibleCount;
    out->partialHighlightedMarker = highlighted;
    for (int32_t i = 0; i < visibleCount; ++i) {
        out->partialCentersX[i] = (static_cast<double>(visible[i].first) + static_cast<double>(visible[i].last)) / 2
            / static_cast<double>(width);
    }
}

// `SlotStripReader.windowLowerEdge`'s constants (SlotStripWindowEdge.swift),
// and those of `FloatingWindowFinder` it shares.
constexpr double kWindowEdgeColumnShare = 0.9;
constexpr int32_t kWindowEdgeMinimumRows = 2;
constexpr int kRingFloor = 60;
constexpr double kMaximumRingShare = 0.015;

inline bool nearColour(const Pixel &p, const Pixel &colour) {
    return std::abs(static_cast<int>(p.red) - static_cast<int>(colour.red)) <= kWindowSideColourTolerance
        && std::abs(static_cast<int>(p.green) - static_cast<int>(colour.green)) <= kWindowSideColourTolerance
        && std::abs(static_cast<int>(p.blue) - static_cast<int>(colour.blue)) <= kWindowSideColourTolerance;
}

/// `SlotStripReader.windowLowerEdge(_:lastCoveredRow:)`: our own window's
/// lower edge across the strip, as the first row read in each column, written
/// to `firstRows`; false when the lit row is not our window's lower edge.
bool windowLowerEdge(const gc_color_image &band, int32_t frameHeight, int32_t lastCoveredRow,
                     std::vector<int32_t> &firstRows) {
    const int32_t width = band.width;
    if (lastCoveredRow < 0 || lastCoveredRow >= band.height) return false;
    int32_t first = -1, last = -1;
    for (int32_t x = 0; x < width; ++x) {
        if (isLit(pixelAt(band, x, lastCoveredRow))) {
            if (first < 0) first = x;
            last = x;
        }
    }
    if (first < 0) return false;
    const int32_t quarter = (last - first) / 4;
    const int32_t sampledFirst = first + quarter, sampledLast = last - quarter;
    const int32_t sampledCount = sampledLast - sampledFirst + 1;
    const int32_t required = static_cast<int32_t>(std::ceil(kWindowEdgeColumnShare * static_cast<double>(sampledCount)));

    // `median`'s value without sorting: this runs on every row searched.
    auto upperMedian = [](std::vector<uint8_t> &values) {
        const auto middle = values.begin() + static_cast<std::ptrdiff_t>(values.size() / 2);
        std::nth_element(values.begin(), middle, values.end());
        return *middle;
    };
    std::vector<uint8_t> reds, greens, blues;
    reds.reserve(static_cast<size_t>(sampledCount));
    greens.reserve(static_cast<size_t>(sampledCount));
    blues.reserve(static_cast<size_t>(sampledCount));
    auto medianColour = [&](int32_t y) {
        reds.clear();
        greens.clear();
        blues.clear();
        for (int32_t x = sampledFirst; x <= sampledLast; ++x) {
            const Pixel p = pixelAt(band, x, y);
            reds.push_back(p.red);
            greens.push_back(p.green);
            blues.push_back(p.blue);
        }
        return Pixel{upperMedian(reds), upperMedian(greens), upperMedian(blues)};
    };
    auto isRingRow = [&](int32_t y) {
        if (y < 0 || y >= band.height) return false;
        const Pixel colour = medianColour(y);
        if (grey(colour) < kRingFloor) return false;
        int32_t count = 0;
        for (int32_t x = sampledFirst; x <= sampledLast; ++x) {
            if (nearColour(pixelAt(band, x, y), colour)) count += 1;
        }
        return count >= required;
    };

    const int32_t edgeTolerance = bannerEdgeTolerance(frameHeight);
    int32_t lowest = -1;
    for (int32_t y = lastCoveredRow + edgeTolerance; y >= lastCoveredRow - edgeTolerance; --y) {
        if (isRingRow(y)) { lowest = y; break; }
    }
    if (lowest < 0) return false;
    const double thickest = std::max(2.0, kMaximumRingShare * static_cast<double>(frameHeight));
    // A band already thicker than a ring is refused however far it runs.
    int32_t top = lowest, bottom = lowest;
    while (static_cast<double>(bottom - top + 1) <= thickest && isRingRow(top - 1)) top -= 1;
    while (static_cast<double>(bottom - top + 1) <= thickest && isRingRow(bottom + 1)) bottom += 1;
    const int32_t thickness = bottom - top + 1;
    if (thickness < kWindowEdgeMinimumRows || static_cast<double>(thickness) > thickest || top - thickness < 0) {
        return false;
    }

    const Pixel ring = medianColour((top + bottom) / 2);
    std::vector<int> interiorGreys;
    interiorGreys.reserve(static_cast<size_t>(thickness) * static_cast<size_t>(sampledCount));
    for (int32_t y = top - thickness; y < top; ++y) {
        for (int32_t x = sampledFirst; x <= sampledLast; ++x) interiorGreys.push_back(grey(pixelAt(band, x, y)));
    }
    std::sort(interiorGreys.begin(), interiorGreys.end());
    if (interiorGreys[interiorGreys.size() / 2] > grey(ring) - kWindowInteriorContrast) return false;

    firstRows.assign(static_cast<size_t>(width), 0);
    for (int32_t x = 0; x < width; ++x) {
        int32_t end = bottom;
        if (nearColour(pixelAt(band, x, end), ring)) {
            while (end + 1 < band.height && end + 1 <= bottom + thickness
                   && nearColour(pixelAt(band, x, end + 1), ring)) {
                end += 1;
            }
        }
        firstRows[static_cast<size_t>(x)] = std::max(end, lastCoveredRow) + 1 + edgeTolerance;
    }
    return true;
}

/// `SlotStripReader.couldReadBelowWindowEdge(gold:violet:firstRows:lastRows:)`:
/// whether a read below our window's traced lower edge could find a row,
/// from the tallies of the read below the uniform cut. The traced read counts
/// a subset of those pixels, so each of its markers lies within a run of
/// columns lit here and is no taller than that run's indicator rows; a row
/// needs such a marker at every place of the centred grid for some count.
bool couldReadBelowWindowEdge(const Columns &columns, const gc_layout &layout) {
    const int32_t width = static_cast<int32_t>(columns.gold.size());
    const double minimumWidth = layout.slotMarkerMinimumWidth * static_cast<double>(width);
    const double minimumHeight = std::min(0.8, layout.coveredMarkerMinimumHeight) * minimumWidth;
    // Where a marker of the minimum width could be centred in each run tall
    // enough to hold one; a run per marker at most, and a strip has fewer
    // runs than columns.
    struct CentreRange { double lower, upper; };
    std::vector<CentreRange> centreRanges;
    auto hits = [&](int32_t x) {
        return columns.gold[static_cast<size_t>(x)] + columns.violet[static_cast<size_t>(x)];
    };
    int32_t x = 0;
    while (x < width) {
        if (hits(x) < layout.slotMarkerMinimumColumnHits) { ++x; continue; }
        const int32_t first = x;
        int32_t top = std::numeric_limits<int32_t>::max(), bottom = std::numeric_limits<int32_t>::min();
        while (x < width && hits(x) >= layout.slotMarkerMinimumColumnHits) {
            top = std::min(top, columns.firstRows[static_cast<size_t>(x)]);
            bottom = std::max(bottom, columns.lastRows[static_cast<size_t>(x)]);
            ++x;
        }
        const int32_t last = x - 1;
        const double half = (minimumWidth - 1) / 2;
        if (static_cast<double>(last - first + 1) >= minimumWidth
            && static_cast<double>(bottom - top + 1) >= minimumHeight) {
            centreRanges.push_back(CentreRange{static_cast<double>(first) + half, static_cast<double>(last) - half});
        }
    }
    const double tolerance = layout.slotCenterTolerance * static_cast<double>(width) + 1;
    for (int32_t count = 1; count <= GC_MAX_SLOTS; ++count) {
        bool everyPlace = true;
        for (int32_t index = 0; index < count && everyPlace; ++index) {
            const double place = static_cast<double>(width)
                * (0.5 + (static_cast<double>(index) - static_cast<double>(count - 1) / 2) * layout.slotCenterPitch);
            bool held = false;
            for (const CentreRange &range : centreRanges) {
                if (range.lower <= place + tolerance && range.upper >= place - tolerance) { held = true; break; }
            }
            everyPlace = held;
        }
        if (everyPlace) return true;
    }
    return false;
}

/// The ordinary checks after segmentation; `read` calls it and looks for our
/// own window when it fails. `windowEdge`, when not null, is our window's
/// lower edge: per column, the first row read.
gc_slot_status fullReading(const gc_color_image &band, int32_t frameHeight, const gc_layout &layout,
                           int32_t belowOverlay, const std::vector<int32_t> *windowEdge, bool hasFirstVisibleRow,
                           int32_t firstVisibleRow, const Columns &columns, int32_t *markerCountOut,
                           gc_slot_reading *out);

/// `SlotStripReader.read(_:belowOverlay:windowEdge:gatesEdgeSearch:findsCover:cover:rowBelowEdgePossible:)`,
/// always finding the cover and gating the edge search. `belowOverlay` < 0
/// stands for nil, and a null `windowEdge` for nil. A read below
/// `belowOverlay` without `windowEdge` that gets as far as segmenting sets
/// `*rowBelowEdgePossible` when it is not null.
gc_slot_status read(const gc_color_image &band, int32_t frameHeight, const gc_layout &layout,
                    int32_t belowOverlay, const std::vector<int32_t> *windowEdge, bool *rowBelowEdgePossible,
                    gc_slot_reading *out) {
    const Range stripRows = bandRows(band, frameHeight, layout.slotStripTop, layout.slotStripBottom);
    if (stripRows.empty()) return GC_SLOT_BAND_UNAVAILABLE;
    const int32_t width = band.width;
    const int32_t litRows = litRowsFromTop(band, layout, stripRows);
    int32_t firstVisibleRow = 0;
    const bool hasFirstVisibleRow = firstRowBelowBanner(band, frameHeight, layout, litRows, &firstVisibleRow);
    // A banner reaching the bottom hides the strip; it does not establish
    // that the game's indicators disappeared.
    if ((hasFirstVisibleRow ? firstVisibleRow : stripRows.lower) >= stripRows.upper) {
        return GC_SLOT_COVERED_BY_OVERLAY;
    }
    const int32_t firstRow = std::max(hasFirstVisibleRow ? firstVisibleRow : stripRows.lower,
                                      belowOverlay >= 0 ? belowOverlay : stripRows.lower);
    if (firstRow >= stripRows.upper) return GC_SLOT_COVERED_BY_OVERLAY;
    const Range rows{firstRow, stripRows.upper};

    // The game's indicators never light a whole row. A row that is, below
    // any banner, is the lower edge of a window over the indicators.
    const int32_t wholeRow = static_cast<int32_t>(
        std::ceil(layout.bannerMinimumRowCoverage * static_cast<double>(width)));
    Columns columns(band);
    bool hasLastCoveredRow = false;
    int32_t lastCoveredRow = 0;
    // Two copies of the per-pixel loop, so that the ordinary reads, which
    // are nearly all of them, carry no test for our window's edge.
    auto tally = [&](auto belowWindowEdge) {
        for (int32_t y = rows.lower; y < rows.upper; ++y) {
            int32_t lit = 0;
            for (int32_t x = 0; x < width; ++x) {
                const Pixel p = pixelAt(band, x, y);
                if (!isLit(p)) continue;
                lit += 1;
                if constexpr (decltype(belowWindowEdge)::value) {
                    if (y < (*windowEdge)[static_cast<size_t>(x)]) continue;
                }
                columns.lit[static_cast<size_t>(x)] += 1;
                if (isGold(p)) columns.gold[static_cast<size_t>(x)] += 1;
                else if (isViolet(p)) columns.violet[static_cast<size_t>(x)] += 1;
                else continue;
                int32_t &first = columns.firstRows[static_cast<size_t>(x)];
                int32_t &last = columns.lastRows[static_cast<size_t>(x)];
                first = std::min(first, y);
                last = std::max(last, y);
            }
            if (lit >= wholeRow) { hasLastCoveredRow = true; lastCoveredRow = y; }
        }
    };
    if (windowEdge != nullptr) tally(std::true_type{});
    else tally(std::false_type{});

    if (hasLastCoveredRow) {
        // A thin PiP can end just inside the strip. Discard its border and
        // shadow, then require the ordinary checks on what remains. Never read
        // the window's own glyphs as indicators.
        if (belowOverlay >= 0) return GC_SLOT_COVERED_BY_OVERLAY;
        const int32_t firstUncoveredRow = lastCoveredRow + 1 + bannerEdgeTolerance(frameHeight);
        // An edge confined to the strip's first rows reaches no further than
        // the indicator tips, so it is not what hid anything missing below it.
        const bool endsAtStripTop = lastCoveredRow < stripRows.lower + litRows;
        bool rowBelowEdgePossible = false;
        const gc_slot_status status = read(band, frameHeight, layout, firstUncoveredRow, nullptr,
                                           &rowBelowEdgePossible, out);
        if (status == GC_SLOT_OK) return status;
        // Our own window's lower edge cuts every indicator by the same curved
        // edge, as a banner does with a straight one; only when the row fails
        // the thin-window rule, and only when what showed below that rule's
        // cut could still hold a row (`SlotStripReader`).
        std::vector<int32_t> edge;
        if (rowBelowEdgePossible && windowLowerEdge(band, frameHeight, lastCoveredRow, edge)
            && read(band, frameHeight, layout, firstUncoveredRow, &edge, nullptr, out) == GC_SLOT_OK) {
            return GC_SLOT_OK;
        }
        return endsAtStripTop ? status : GC_SLOT_COVERED_BY_OVERLAY;
    }

    if (rowBelowEdgePossible != nullptr && belowOverlay >= 0 && windowEdge == nullptr) {
        *rowBelowEdgePossible = couldReadBelowWindowEdge(columns, layout);
    }
    int32_t markerCount = 0;
    const gc_slot_status status = fullReading(band, frameHeight, layout, belowOverlay, windowEdge, hasFirstVisibleRow,
                                              firstVisibleRow, columns, &markerCount, out);
    // Our own window over one side of the row breaks the full reading with
    // its own ring and content. Only then, and only with no banner or window
    // edge across the strip, is what shows beside it read.
    if (status != GC_SLOT_OK && markerCount > 0 && belowOverlay < 0 && !hasFirstVisibleRow) {
        windowCover(band, frameHeight, layout, rows, columns, out);
    }
    return status;
}

gc_slot_status fullReading(const gc_color_image &band, int32_t frameHeight, const gc_layout &layout,
                           int32_t belowOverlay, const std::vector<int32_t> *windowEdge, bool hasFirstVisibleRow,
                           int32_t firstVisibleRow, const Columns &columns, int32_t *markerCountOut,
                           gc_slot_reading *out) {
    const int32_t width = band.width;
    // Marker segmentation over 0...width. Only the sized markers are kept,
    // and only as many as can still be a strip: the counts alone decide the
    // rejections, in the Swift order.
    Marker sized[GC_MAX_SLOTS + 1];
    int32_t markerCount = 0, sizedCount = 0;
    const double minimumWidth = layout.slotMarkerMinimumWidth * static_cast<double>(width);
    const double maximumWidth = layout.slotMarkerMaximumWidth * static_cast<double>(width);
    const EdgeColumns edge = slotEdgeColumns(layout, width);
    bool hasStart = false;
    Marker current{0, 0, 0, 0};
    for (int32_t x = 0; x <= width; ++x) {
        const bool on = x < width
            && columns.gold[static_cast<size_t>(x)] + columns.violet[static_cast<size_t>(x)]
                >= layout.slotMarkerMinimumColumnHits;
        if (on) {
            if (!hasStart) { hasStart = true; current = Marker{x, x, 0, 0}; }
            current.gold += columns.gold[static_cast<size_t>(x)];
            current.violet += columns.violet[static_cast<size_t>(x)];
        } else if (hasStart) {
            current.last = x - 1;
            hasStart = false;
            // An object at the left or right edge is set aside rather than
            // distrusted as a misread indicator (`SlotStripReader`).
            if ((current.first < edge.margin && current.last < edge.zone)
                || (current.last >= width - edge.margin && current.first >= width - edge.zone)) {
                continue;
            }
            markerCount += 1;
            const double w = static_cast<double>(current.width());
            if (w >= minimumWidth && w <= maximumWidth) {
                if (sizedCount <= GC_MAX_SLOTS) sized[sizedCount] = current;
                sizedCount += 1;
            }
        }
    }

    *markerCountOut = markerCount;
    if (sizedCount == 0) return markerCount == 0 ? GC_SLOT_NO_MARKERS : GC_SLOT_INCONSISTENT_MARKER_WIDTHS;
    // Every marker that survived the width filter must be a slot: a strip
    // with one indicator rejected as too wide is a misread, not a shorter
    // sequence, so demand that nothing was dropped.
    if (sizedCount != markerCount) return GC_SLOT_INCONSISTENT_MARKER_WIDTHS;
    if (sizedCount > GC_MAX_SLOTS) return GC_SLOT_TOO_MANY_MARKERS;

    Extent extents[GC_MAX_SLOTS];
    for (int32_t i = 0; i < sizedCount; ++i) {
        int32_t top = band.height, bottom = -1;
        for (int32_t x = sized[i].first; x <= sized[i].last; ++x) {
            top = std::min(top, columns.firstRows[static_cast<size_t>(x)]);
            bottom = std::max(bottom, columns.lastRows[static_cast<size_t>(x)]);
        }
        extents[i] = Extent{top, bottom, sized[i].width()};
    }
    // A strip under PiP must retain nearly the full marker height. Below a
    // banner every marker is cut by the same straight edge, so a marker may
    // instead run up to that edge, provided enough of it shows to have kept
    // its full width. Below our own window's lower edge the same holds, with
    // the edge traced column by column.
    const int32_t edgeTolerance = bannerEdgeTolerance(frameHeight);
    for (int32_t i = 0; i < sizedCount; ++i) {
        const Extent &extent = extents[i];
        const double height = static_cast<double>(extent.bottom - extent.top + 1);
        const double markerWidth = static_cast<double>(extent.width);
        if (height >= markerWidth * 0.8) continue;
        if (windowEdge != nullptr) {
            bool reachesEdge = false;
            for (int32_t x = sized[i].first; x <= sized[i].last && !reachesEdge; ++x) {
                reachesEdge = columns.firstRows[static_cast<size_t>(x)]
                    <= (*windowEdge)[static_cast<size_t>(x)] + edgeTolerance;
            }
            if (!(reachesEdge && height >= markerWidth * layout.coveredMarkerMinimumHeight)) {
                return GC_SLOT_INCOMPLETE_MARKER_HEIGHT;
            }
            continue;
        }
        if (belowOverlay >= 0 || !hasFirstVisibleRow) return GC_SLOT_INCOMPLETE_MARKER_HEIGHT;
        const bool cutByBanner = extent.top <= firstVisibleRow + edgeTolerance
            && height >= markerWidth * layout.coveredMarkerMinimumHeight;
        if (!cutByBanner) return GC_SLOT_INCOMPLETE_MARKER_HEIGHT;
    }

    double centers[GC_MAX_SLOTS];
    for (int32_t i = 0; i < sizedCount; ++i) {
        centers[i] = (static_cast<double>(sized[i].first) + static_cast<double>(sized[i].last)) / 2;
    }
    if (sizedCount >= 3) {
        double pitches[GC_MAX_SLOTS - 1];
        double sum = 0;
        for (int32_t i = 0; i + 1 < sizedCount; ++i) {
            pitches[i] = centers[i + 1] - centers[i];
            sum += pitches[i];
        }
        const double mean = sum / static_cast<double>(sizedCount - 1);
        if (!(mean > 0)) return GC_SLOT_UNEVEN_SPACING;
        for (int32_t i = 0; i + 1 < sizedCount; ++i) {
            if (!(std::fabs(pitches[i] - mean) <= mean * layout.slotPitchTolerance)) return GC_SLOT_UNEVEN_SPACING;
        }
    }

    // The complete row is centred on the screen at a fixed pitch, so a
    // fragment of a longer row cannot pass as a shorter sequence.
    const double midpoint = static_cast<double>(sizedCount - 1) / 2;
    for (int32_t i = 0; i < sizedCount; ++i) {
        const double offset = (static_cast<double>(i) - midpoint) * layout.slotCenterPitch;
        const double expected = 0.5 + offset;
        const double actual = centers[i] / static_cast<double>(width);
        if (!(std::fabs(actual - expected) <= layout.slotCenterTolerance)) return GC_SLOT_INCOMPLETE_STRIP;
    }

    int32_t highlightCount = 0, highlightedIndex = -1;
    for (int32_t i = 0; i < sizedCount; ++i) {
        if (sized[i].gold > sized[i].violet) {
            if (highlightCount == 0) highlightedIndex = i;
            highlightCount += 1;
        }
    }
    if (highlightCount > 1) return GC_SLOT_MULTIPLE_HIGHLIGHTS;

    // Below a window's edge the indicators were cut only if they run up to
    // it; an edge that merely touches the top of the strip hid nothing.
    bool cutBelowWindow = false;
    if (belowOverlay >= 0) {
        for (int32_t i = 0; i < sizedCount; ++i) {
            if (extents[i].top <= belowOverlay) { cutBelowWindow = true; break; }
        }
    }

    out->status = GC_SLOT_OK;
    out->slotCount = sizedCount;
    out->highlightedIndex = highlightedIndex;
    for (int32_t i = 0; i < GC_MAX_SLOTS; ++i) {
        out->markerCentersX[i] = i < sizedCount ? centers[i] / static_cast<double>(width) : 0;
    }
    out->hasInputTimerBar = hasTimerBar(band, frameHeight, layout);
    out->isPartlyCovered = hasFirstVisibleRow || cutBelowWindow || windowEdge != nullptr;
    return GC_SLOT_OK;
}

/// Clears the full reading; the window cover fields stay.
void clearReading(gc_slot_reading *out, gc_slot_status status) {
    out->status = status;
    out->slotCount = 0;
    out->highlightedIndex = -1;
    for (int32_t i = 0; i < GC_MAX_SLOTS; ++i) out->markerCentersX[i] = 0;
    out->hasInputTimerBar = false;
    out->isPartlyCovered = false;
}

void clearCover(gc_slot_reading *out) {
    out->windowSide = GC_WINDOW_NONE;
    out->coveredFrom = 0;
    out->coveredTo = 0;
    out->hasPartialRow = false;
    out->partialCount = 0;
    out->partialHighlightedMarker = -1;
    for (int32_t i = 0; i < GC_MAX_SLOTS; ++i) out->partialCentersX[i] = 0;
    out->hasPartialTimerBar = false;
}

} // namespace

extern "C" gc_layout gc_layout_default(void) {
    gc_layout layout;
    layout.headerTextTop = 0.060;
    layout.headerTextBottom = 0.104;
    layout.slotStripTop = 0.104;
    layout.slotStripBottom = 0.176;
    layout.inputTimerBarTop = 0.218;
    layout.inputTimerBarBottom = 0.246;
    layout.inputTimerBarMinimumWidth = 0.03;
    layout.slotMarkerMinimumWidth = 0.085;
    layout.slotMarkerMaximumWidth = 0.190;
    layout.slotMarkerMinimumColumnHits = 3;
    layout.slotPitchTolerance = 0.18;
    layout.slotCenterPitch = 0.16;
    layout.slotCenterTolerance = 0.035;
    layout.inputTimerTrackLeft = 0.11;
    layout.inputTimerTrackRight = 0.89;
    layout.inputTimerEndpointTolerance = 0.035;
    layout.bannerMinimumRowCoverage = 0.75;
    layout.bannerMinimumHeight = 0.004;
    layout.coveredMarkerMinimumHeight = 0.4;
    return layout;
}

extern "C" void gc_slot_strip_read(gc_color_image band, int32_t frameHeight, const gc_layout *layout,
                                   gc_slot_reading *out) {
    if (out == nullptr) return;
    if (!validBand(band)) {
        clearReading(out, GC_SLOT_BAND_UNAVAILABLE);
        clearCover(out);
        return;
    }
    const gc_layout resolved = layout != nullptr ? *layout : gc_layout_default();
    gc_slot_reading reading;
    clearReading(&reading, GC_SLOT_OK);
    clearCover(&reading);
    const gc_slot_status status = read(band, frameHeight, resolved, -1, nullptr, nullptr, &reading);
    if (status != GC_SLOT_OK) clearReading(&reading, status);
    *out = reading;
}

extern "C" bool gc_timer_bar(gc_color_image band, int32_t frameHeight, const gc_layout *layout) {
    if (!validBand(band)) return false;
    const gc_layout resolved = layout != nullptr ? *layout : gc_layout_default();
    return hasTimerBar(band, frameHeight, resolved);
}
