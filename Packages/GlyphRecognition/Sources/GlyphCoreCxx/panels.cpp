// Result, gear and portal panel geometry, and the command notice box.
// Reference: ResultPanelDetector.swift, GearDropPanelDetector.swift,
// PortalScreenDetector.swift, CommandNoticeDetector in CommandNoticeReader.swift.

#include "glyph_core.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <vector>

// The Swift oracle never fuses a multiply and an add; neither may this file,
// or Int(x * Double(width)) could land one pixel away from it.
#if defined(__clang__)
#pragma clang fp contract(off)
#else
#pragma STDC FP_CONTRACT OFF
#endif

namespace {

/// `Int(value)` on a non-negative Double: truncation toward zero.
inline int32_t truncated(double value) { return static_cast<int32_t>(value); }

/// The portrait phone layouts the detectors were measured on.
inline bool isPortraitPhone(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) return false;
    const double aspect = static_cast<double>(height) / static_cast<double>(width);
    return aspect >= 2.1 && aspect <= 2.25 && width >= 280;
}

inline bool hasValidGeometry(const gc_gray_image &image) {
    return image.data != nullptr && image.width > 0 && image.height > 0 && image.bytesPerRow >= image.width;
}

inline bool hasValidGeometry(const gc_color_image &image) {
    return image.data != nullptr && image.width > 0 && image.height > 0 && image.bytesPerPixel >= 3 &&
           static_cast<int64_t>(image.bytesPerRow) >= static_cast<int64_t>(image.width) * image.bytesPerPixel &&
           image.redOffset >= 0 && image.redOffset < image.bytesPerPixel && image.greenOffset >= 0 &&
           image.greenOffset < image.bytesPerPixel && image.blueOffset >= 0 && image.blueOffset < image.bytesPerPixel;
}

inline uint8_t grayAt(const gc_gray_image &image, int32_t x, int32_t y) {
    return image.data[static_cast<size_t>(y) * static_cast<size_t>(image.bytesPerRow) + static_cast<size_t>(x)];
}

struct RGB {
    int red;
    int green;
    int blue;
};

/// A pixel of a colour band that holds frame rows from `bandTop`. False when
/// the frame row is outside the band or the column outside the width (the
/// Swift subscript would trap on the latter; a reader never asks for it).
inline bool pixelAt(const gc_color_image &image, int32_t bandTop, int32_t x, int32_t y, RGB *out) {
    const int32_t row = y - bandTop;
    if (row < 0 || row >= image.height || x < 0 || x >= image.width) return false;
    const uint8_t *pixel = image.data + static_cast<size_t>(row) * static_cast<size_t>(image.bytesPerRow) +
                           static_cast<size_t>(x) * static_cast<size_t>(image.bytesPerPixel);
    out->red = pixel[image.redOffset];
    out->green = pixel[image.greenOffset];
    out->blue = pixel[image.blueOffset];
    return true;
}

// ---------------------------------------------------------------------------
// Gear drop panel

inline bool isLavender(const gc_color_image &image, int32_t bandTop, int32_t x, int32_t y) {
    RGB p;
    if (!pixelAt(image, bandTop, x, y, &p)) return false;
    return p.red >= 65 && p.red < 220 && p.green >= 55 && std::abs(p.red - p.green) < 40 && p.blue > p.red + 15;
}

/// `border(_:from:to:)`: 74 of 80 samples across the row are lavender.
inline bool gearBorder(const gc_color_image &image, int32_t bandTop, int32_t y, double left, double right) {
    int hits = 0;
    const double width = static_cast<double>(image.width);
    for (int sample = 0; sample < 80; ++sample) {
        const int32_t x = truncated((left + static_cast<double>(sample) * (right - left) / 79) * width);
        if (isLavender(image, bandTop, x, y)) hits += 1;
    }
    return hits >= 74;
}

/// `box(_:sides:sideColumns:from:to:)` over the rows of `rowsBegin..<rowsEnd` that
/// pass `gearBorder` with the same `left`/`right`. The Swift code filters the
/// rows first and then takes the first line and the first line 7.5% below it;
/// here the rows are walked once, which finds the same two.
bool gearBox(const gc_color_image &image, int32_t frameHeight, int32_t bandTop, int32_t rowsBegin, int32_t rowsEnd,
             double borderLeft, double borderRight, int sidesNeeded, const double (&sideColumns)[2][2],
             double left, double right, gc_panel_bounds *out) {
    const double height = static_cast<double>(frameHeight);
    int32_t top = -1, bottom = -1;
    for (int32_t y = rowsBegin; y < rowsEnd; ++y) {
        if (!gearBorder(image, bandTop, y, borderLeft, borderRight)) continue;
        if (top < 0) {
            top = y;
            if (static_cast<double>(top) / height >= 0.40) return false;
            continue;
        }
        if (static_cast<double>(y - top) / height >= 0.075) {
            bottom = y;
            break;
        }
    }
    if (top < 0 || bottom < 0) return false;
    // The title band's background must be dark across most of the box.
    int dark = 0;
    int32_t y = top + truncated(height * 0.009);
    if (y > frameHeight - 1) y = frameHeight - 1;
    const double width = static_cast<double>(image.width);
    for (int sample = 0; sample < 40; ++sample) {
        const int32_t x = truncated((left + static_cast<double>(sample) * (right - left) / 39) * width);
        RGB p;
        if (!pixelAt(image, bandTop, x, y, &p)) continue;
        if (p.red < 55 && p.green < 55 && p.blue < 85) dark += 1;
    }
    if (dark < 34) return false;
    // Item sparks can cross either horizontal stroke. A half-width stroke
    // needs independent support from BOTH vertical sides; a full-width one
    // needs one side at the panel's edge (the key inventory's narrower
    // cards stack, and a card's bottom border above the next card's makes a
    // box with no side there). Each side is tested over separate segments
    // so one spark does not erase it.
    static const double starts[3] = {0.1, 0.4, 0.7};
    const double span = static_cast<double>(bottom - top);
    int sides = 0;
    for (const auto &side : sideColumns) {
        const int32_t firstColumn = truncated(side[0] * width), lastColumn = truncated(side[1] * width);
        bool supported = false;
        for (int32_t x = firstColumn; x <= lastColumn && !supported; ++x) {
            for (double start : starts) {
                int hits = 0;
                for (int sample = 0; sample < 80; ++sample) {
                    const int32_t sampleY = top + truncated((start + static_cast<double>(sample) * 0.2 / 79) * span);
                    if (isLavender(image, bandTop, x, sampleY)) hits += 1;
                }
                if (hits >= 74) {
                    supported = true;
                    break;
                }
            }
        }
        if (supported) sides += 1;
    }
    if (sides < sidesNeeded) return false;
    out->top = static_cast<double>(top) / height;
    out->bottom = static_cast<double>(bottom) / height;
    return true;
}

// ---------------------------------------------------------------------------
// Portal screen

inline bool factionMatches(gc_faction faction, const RGB &p) {
    const int r = p.red, g = p.green, b = p.blue;
    switch (faction) {
    case GC_FACTION_RESISTANCE: return b > 80 && g > 60 && r < 110 && b - r > 40 && b >= g;
    case GC_FACTION_ENLIGHTENED: return g > 80 && r < 50 && b < 60 && g - b > 40;
    case GC_FACTION_MACHINA: return r > 110 && g < 40 && b < 30;
    case GC_FACTION_NONE: return false;
    }
    return false;
}

struct Bar {
    int32_t lower;
    int32_t upper;
};

/// A band of 0.36 of the height holds at most twelve bars of 0.03 of it; the
/// capacity has room for the aspect ratios the detector accepts.
constexpr int kMaxBars = 32;

/// `bars(from:to:)`: runs of band rows with a faction pixel in the columns,
/// kept when their length is within `shortest...longest`. Filtering while
/// collecting keeps the Swift order.
int portalBars(const gc_color_image &image, gc_faction faction, int32_t frameHeight, int32_t bandTop,
               double x0, double x1, int32_t shortest, int32_t longest, Bar *bars) {
    const double width = static_cast<double>(image.width);
    const int32_t firstColumn = truncated(x0 * width), endColumn = truncated(x1 * width);
    int32_t bandBegin, bandEnd;
    gc_portal_band(frameHeight, &bandBegin, &bandEnd);
    int count = 0;
    int32_t start = -1;
    auto close = [&](int32_t end) {
        const int32_t length = end - start;
        if (length >= shortest && length <= longest && count < kMaxBars) bars[count++] = Bar{start, end};
        start = -1;
    };
    for (int32_t y = bandBegin; y < bandEnd; ++y) {
        const int32_t row = y - bandTop;
        bool lit = false;
        if (row >= 0 && row < image.height) {
            for (int32_t x = firstColumn; x < endColumn && !lit; ++x) {
                RGB p;
                if (pixelAt(image, bandTop, x, y, &p) && factionMatches(faction, p)) lit = true;
            }
        }
        if (lit && start < 0) start = y;
        if (!lit && start >= 0) close(y);
    }
    if (start >= 0) close(bandEnd);
    return count;
}

/// `pairs(of:in:frameHeight:bandTop:)`: left bars with a right bar at the
/// same height, within 1.2% of the frame at both ends.
int portalPairs(const gc_color_image &image, gc_faction faction, int32_t frameHeight, int32_t bandTop) {
    const double height = static_cast<double>(frameHeight);
    const int32_t shortest = truncated(height * 0.03), longest = truncated(height * 0.08);
    const double offset = height * 0.012;
    Bar left[kMaxBars], right[kMaxBars];
    const int leftCount = portalBars(image, faction, frameHeight, bandTop, 0, 0.1, shortest, longest, left);
    const int rightCount = portalBars(image, faction, frameHeight, bandTop, 0.9, 1, shortest, longest, right);
    int pairs = 0;
    for (int i = 0; i < leftCount; ++i) {
        for (int j = 0; j < rightCount; ++j) {
            if (std::fabs(static_cast<double>(right[j].lower - left[i].lower)) <= offset &&
                std::fabs(static_cast<double>(right[j].upper - left[i].upper)) <= offset) {
                pairs += 1;
                break;
            }
        }
    }
    return pairs;
}

/// `CommandNoticeDetector.isEdgeObject(_:width:)`: a run of lit columns that
/// reaches within w/20 of an edge and stays on that side of the centre column
/// is an object at the edge, no part of a notice box.
inline bool isCommandEdgeObject(int32_t first, int32_t last, int32_t w) {
    const int32_t margin = w / 20;
    return (first < margin && 2 * last < w - 1) || (last >= w - margin && 2 * first > w - 1);
}

} // namespace

// ---------------------------------------------------------------------------

extern "C" bool gc_result_candidate(gc_gray_image luma) {
    if (!hasValidGeometry(luma) || !isPortraitPhone(luma.width, luma.height)) return false;
    const int32_t width = luma.width, height = luma.height;
    int32_t radius = width / 180;
    if (radius < 1) radius = 1;
    auto bright = [&](double x, double y) -> bool {
        const int32_t px = truncated(x * static_cast<double>(width));
        int32_t py = truncated(y * static_cast<double>(height));
        if (py > height - 1) py = height - 1;
        if (py < 0) py = 0;
        for (int32_t dx = -radius; dx <= radius; ++dx) {
            int32_t xx = px + dx;
            if (xx > width - 1) xx = width - 1;
            if (xx < 0) xx = 0;
            if (grayAt(luma, xx, py) > 65) return true;
        }
        return false;
    };
    // Two tall sides, away from the labels, value flashes, and timer.
    int left = 0, right = 0;
    for (int step = 0; step < 20; ++step) {
        const double y = 0.34 + static_cast<double>(step) * 0.012;
        if (bright(0.086, y)) left += 1;
        if (bright(0.920, y)) right += 1;
    }
    return left >= 16 && right >= 16;
}

extern "C" void gc_gear_band(int32_t frameHeight, int32_t *top, int32_t *bottom) {
    if (top == nullptr || bottom == nullptr) return;
    if (frameHeight <= 0) {
        *top = 0;
        *bottom = 0;
        return;
    }
    const double height = static_cast<double>(frameHeight);
    *top = truncated(height * 0.275);
    const int32_t end = truncated(height * 0.62) + truncated(height * 0.009) + 2;
    *bottom = end < frameHeight ? end : frameHeight;
}

extern "C" bool gc_gear_candidate(gc_color_image band, int32_t frameHeight, int32_t bandTop, gc_panel_bounds *out) {
    if (out == nullptr || !hasValidGeometry(band) || !isPortraitPhone(band.width, frameHeight)) return false;
    const double height = static_cast<double>(frameHeight);
    const int32_t rowsBegin = truncated(height * 0.275), rowsEnd = truncated(height * 0.62);
    // Measured panel sides sit at 0.030-0.032 and 0.968-0.970 of the width;
    // the key inventory's cards at 0.069-0.071 and 0.929. The full-width
    // search reaches outward to 0.015/0.985 for wider phones.
    static const double fullSides[2][2] = {{0.015, 0.042}, {0.958, 0.985}};
    static const double halfSides[2][2] = {{0.028, 0.042}, {0.958, 0.972}};
    if (gearBox(band, frameHeight, bandTop, rowsBegin, rowsEnd, 0.055, 0.945, 1, fullSides, 0.06, 0.94, out)) {
        return true;
    }
    static const double halves[2][2] = {{0.52, 0.945}, {0.055, 0.48}};
    for (const auto &half : halves) {
        if (gearBox(band, frameHeight, bandTop, rowsBegin, rowsEnd, half[0], half[1], 2, halfSides, half[0], half[1],
                    out)) {
            return true;
        }
    }
    return false;
}

extern "C" void gc_portal_band(int32_t frameHeight, int32_t *top, int32_t *bottom) {
    if (top == nullptr || bottom == nullptr) return;
    if (frameHeight <= 0) {
        *top = 0;
        *bottom = 0;
        return;
    }
    const double height = static_cast<double>(frameHeight);
    *top = truncated(height * 0.30);
    *bottom = truncated(height * 0.66);
}

extern "C" gc_faction gc_portal_faction(gc_color_image band, int32_t frameHeight, int32_t bandTop) {
    if (!hasValidGeometry(band) || !isPortraitPhone(band.width, frameHeight)) return GC_FACTION_NONE;
    static const gc_faction factions[3] = {GC_FACTION_RESISTANCE, GC_FACTION_ENLIGHTENED, GC_FACTION_MACHINA};
    int counts[3];
    for (int i = 0; i < 3; ++i) counts[i] = portalPairs(band, factions[i], frameHeight, bandTop);
    // The faction with the most pairs, two at least; a tie names neither.
    int best = -1;
    bool tied = false;
    for (int i = 0; i < 3; ++i) {
        if (counts[i] < 2) continue;
        if (best < 0 || counts[i] > counts[best]) {
            best = i;
            tied = false;
        } else if (counts[i] == counts[best]) {
            tied = true;
        }
    }
    if (best < 0 || tied) return GC_FACTION_NONE;
    return factions[best];
}

extern "C" void gc_command_band(int32_t frameWidth, int32_t frameHeight, int32_t *top, int32_t *bottom) {
    if (top == nullptr || bottom == nullptr) return;
    if (frameWidth <= 0 || frameHeight <= 0) {
        *top = 0;
        *bottom = 0;
        return;
    }
    // CGRect(x: 0, y: h * 0.16, width: w, height: h * 0.13).integral: the
    // origin floored, the far edge ceiled.
    const double height = static_cast<double>(frameHeight);
    const double y = height * 0.16;
    const double maxY = y + height * 0.13;
    int32_t first = static_cast<int32_t>(std::floor(y));
    int32_t end = static_cast<int32_t>(std::ceil(maxY));
    if (first < 0) first = 0;
    if (end > frameHeight) end = frameHeight;
    if (end < first) end = first;
    *top = first;
    *bottom = end;
}

extern "C" bool gc_command_box_detect(gc_gray_image bandLuma, gc_command_box *out) {
    if (out == nullptr || !hasValidGeometry(bandLuma)) return false;
    const int32_t w = bandLuma.width, h = bandLuma.height;
    // Each column's first and last lit row, -1 when it has none.
    std::vector<int32_t> firstRows(static_cast<size_t>(w), -1), lastRows(static_cast<size_t>(w), -1);
    for (int32_t y = 0; y < h; ++y) {
        const uint8_t *row = bandLuma.data + static_cast<size_t>(y) * static_cast<size_t>(bandLuma.bytesPerRow);
        for (int32_t x = 0; x < w; ++x) {
            if (row[x] <= 45) continue;
            if (firstRows[static_cast<size_t>(x)] < 0) firstRows[static_cast<size_t>(x)] = y;
            lastRows[static_cast<size_t>(x)] = y;
        }
    }
    // The bounding box of every lit pixel, less objects at the edges.
    int32_t left = w, right = 0, top = h, bottom = 0;
    for (int32_t x = 0; x < w;) {
        if (lastRows[static_cast<size_t>(x)] < 0) { ++x; continue; }
        int32_t end = x;
        while (end + 1 < w && lastRows[static_cast<size_t>(end + 1)] >= 0) ++end;
        if (!isCommandEdgeObject(x, end, w)) {
            if (x < left) left = x;
            if (end > right) right = end;
            for (int32_t column = x; column <= end; ++column) {
                top = std::min(top, firstRows[static_cast<size_t>(column)]);
                bottom = std::max(bottom, lastRows[static_cast<size_t>(column)]);
            }
        }
        x = end + 1;
    }
    const int32_t width = right - left, height = bottom - top;
    if (!(width > w / 5 && width < w * 4 / 5 && height > h / 4 && height < h * 3 / 4 &&
          std::abs(left + right - w) < w / 16 && top > 1 && bottom < h - 2)) {
        return false;
    }
    // Require horizontal borders on both sides of the text, not just a
    // centered phrase on a result or a floating window.
    auto border = [&](int32_t start, int32_t end) -> bool {
        for (int32_t y = start; y <= end; ++y) {
            int32_t hits = 0;
            for (int32_t x = left; x <= right; ++x) {
                if (grayAt(bandLuma, x, y) > 45) hits += 1;
            }
            if (hits > width * 4 / 5) return true;
        }
        return false;
    };
    const int32_t topEnd = bottom < top + 5 ? bottom : top + 5;
    const int32_t bottomStart = top > bottom - 5 ? top : bottom - 5;
    if (!border(top, topEnd) || !border(bottomStart, bottom)) return false;
    for (int32_t y = 0; y < 16; ++y) {
        for (int32_t x = 0; x < 64; ++x) {
            const int32_t sampleX = left + x * width / 64, sampleY = top + y * height / 16;
            out->signature[y * 64 + x] = grayAt(bandLuma, sampleX, sampleY) > 140 ? 1 : 0;
        }
    }
    out->x = left - 1;
    out->y = top - 1;
    out->width = width + 3;
    out->height = height + 3;
    return true;
}
