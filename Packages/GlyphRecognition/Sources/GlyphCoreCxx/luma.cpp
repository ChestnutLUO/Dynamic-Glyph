// Luminance and colour conversion, and the luma gate.
// Reference: LumaGate in AnalysisGate.swift; ImageDecoder.swift.

#include "glyph_core.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

// The Swift oracle never fuses a multiply and an add; neither may this file,
// or Int(x * Double(width)) could land one pixel away from it.
#if defined(__clang__)
#pragma clang fp contract(off)
#else
#pragma STDC FP_CONTRACT OFF
#endif

namespace {

constexpr int kDarkLevel = 20;
constexpr int kBrightLevel = 60;
constexpr double kMinimumDarkFraction = 0.6;
constexpr double kMaximumBrightFraction = 0.25;
constexpr double kArrayRowsLower = 0.30;
constexpr double kArrayRowsUpper = 0.85;
constexpr double kArrayColumnsLower = 0.03;
constexpr double kArrayColumnsUpper = 0.97;

/// `LumaGate.videoRangeTable`: ((v - 16) * 255 + 109) / 219, clamped to a byte.
inline uint8_t stretchVideoRange(int value) {
    const int stretched = ((value - 16) * 255 + 109) / 219;
    if (stretched < 0) return 0;
    if (stretched > 255) return 255;
    return static_cast<uint8_t>(stretched);
}

/// `LumaGate.read(bgra:)`'s fixed-point BT.601 weights. The sum of the weights
/// is 256, so the result never exceeds 255.
inline uint8_t lumaFromRGB(int red, int green, int blue) {
    return static_cast<uint8_t>((29 * blue + 150 * green + 77 * red) >> 8);
}

inline uint8_t clampByte(int value) {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return static_cast<uint8_t>(value);
}

/// `LumaGate.read(width:height:luma:)`. `luma(x, y)` is the pixel accessor.
template <typename Luma>
bool gateRead(int32_t width, int32_t height, int32_t step, Luma luma, gc_gate_reading *out) {
    if (out == nullptr || width <= 0 || height <= 0) return false;
    if (step < 1) step = 1;
    const int columns = GC_GATE_COLUMNS, rows = GC_GATE_ROWS;
    int64_t sums[GC_GATE_CELLS] = {};
    int64_t counts[GC_GATE_CELLS] = {};
    const int64_t top = static_cast<int64_t>(kArrayRowsLower * static_cast<double>(height));
    const int64_t bottom = static_cast<int64_t>(kArrayRowsUpper * static_cast<double>(height));
    const int64_t left = static_cast<int64_t>(kArrayColumnsLower * static_cast<double>(width));
    const int64_t right = static_cast<int64_t>(kArrayColumnsUpper * static_cast<double>(width));
    int64_t dark = 0, bright = 0, area = 0;
    for (int64_t y = step / 2; y < height; y += step) {
        int64_t rowCell = y * rows / height;
        if (rowCell > rows - 1) rowCell = rows - 1;
        const int64_t row = rowCell * columns;
        const bool inArrayRows = y >= top && y < bottom;
        for (int64_t x = step / 2; x < width; x += step) {
            const int value = luma(static_cast<int32_t>(x), static_cast<int32_t>(y));
            int64_t columnCell = x * columns / width;
            if (columnCell > columns - 1) columnCell = columns - 1;
            const int64_t cell = row + columnCell;
            sums[cell] += value;
            counts[cell] += 1;
            if (inArrayRows && x >= left && x < right) {
                area += 1;
                if (value < kDarkLevel) {
                    dark += 1;
                } else if (value > kBrightLevel) {
                    bright += 1;
                }
            }
        }
    }
    for (int cell = 0; cell < GC_GATE_CELLS; ++cell) {
        const int64_t mean = counts[cell] > 0 ? sums[cell] / counts[cell] : 0;
        out->cells[cell] = mean > 255 ? 255 : static_cast<uint8_t>(mean);
    }
    const double darkFraction = area > 0 ? static_cast<double>(dark) / static_cast<double>(area) : 1.0;
    const double brightFraction = area > 0 ? static_cast<double>(bright) / static_cast<double>(area) : 0.0;
    out->darkFraction = darkFraction;
    out->brightFraction = brightFraction;
    out->isCandidate = darkFraction >= kMinimumDarkFraction || brightFraction <= kMaximumBrightFraction;
    return true;
}

/// A rectangle clipped to the frame, or false when nothing is left or the
/// planes are malformed.
bool clipRegion(const gc_frame_planes &frame, int32_t &left, int32_t &top, int32_t &width, int32_t &height) {
    if (frame.base == nullptr || frame.width <= 0 || frame.height <= 0) return false;
    if (frame.bgra) {
        if (static_cast<int64_t>(frame.bytesPerRow) < static_cast<int64_t>(frame.width) * 4) return false;
    } else if (frame.bytesPerRow < frame.width) {
        return false;
    }
    const int64_t right = std::min<int64_t>(static_cast<int64_t>(left) + width, frame.width);
    const int64_t bottom = std::min<int64_t>(static_cast<int64_t>(top) + height, frame.height);
    left = std::max(left, 0);
    top = std::max(top, 0);
    if (right <= left || bottom <= top) return false;
    width = static_cast<int32_t>(right - left);
    height = static_cast<int32_t>(bottom - top);
    return true;
}

/// BT.709 in 16.16 fixed point. Video range stretches Y by 255/219 and the
/// chroma by 255/224 before the matrix; the factors are folded in.
struct NV12Coefficients {
    int32_t yScale;   // 255/219 or 1
    int32_t yOffset;
    int32_t rCr;      // 1.5748 (x 255/224)
    int32_t gCb;      // 0.1873
    int32_t gCr;      // 0.4681
    int32_t bCb;      // 1.8556
};
constexpr NV12Coefficients kFullRangeRGB{65536, 0, 103206, 12276, 30679, 121608};
constexpr NV12Coefficients kVideoRangeRGB{76309, 16, 117489, 13975, 34925, 138438};
constexpr int32_t kRoundingHalf = 1 << 15;

/// Columns [from, width) of one row. A chroma pair's three terms, rounding
/// included, are worked out once for the two pixels that share it; the sums
/// are the ones the per-pixel formula makes, so are the bytes.
void rgbRowScalar(const uint8_t *lumaRow, const uint8_t *chromaRow, int32_t from, int32_t width,
                  const NV12Coefficients &k, uint8_t *target) {
    for (int32_t x = from; x < width; x += 2) {
        const int32_t cb = static_cast<int32_t>(chromaRow[x]) - 128;
        const int32_t cr = static_cast<int32_t>(chromaRow[x + 1]) - 128;
        const int32_t red = k.rCr * cr + kRoundingHalf;
        const int32_t green = kRoundingHalf - k.gCb * cb - k.gCr * cr;
        const int32_t blue = k.bCb * cb + kRoundingHalf;
        const int32_t last = std::min(x + 2, width);
        for (int32_t column = x; column < last; ++column) {
            const int32_t luma = (static_cast<int32_t>(lumaRow[column]) - k.yOffset) * k.yScale;
            uint8_t *pixel = target + static_cast<size_t>(column) * 3;
            pixel[0] = clampByte((luma + red) >> 16);
            pixel[1] = clampByte((luma + green) >> 16);
            pixel[2] = clampByte((luma + blue) >> 16);
        }
    }
}

#if defined(__aarch64__)
/// The first columns of one row, 16 at a time, with the scalar arithmetic in
/// 32-bit lanes; returns where it stopped. `vqshrun_n_s32` shifts right by 16
/// and saturates below 0 and above 65535, then `vqmovn_u16` above 255, which
/// is `clampByte` of the shifted sum for every sum the formula reaches.
int32_t rgbRowNeon(const uint8_t *lumaRow, const uint8_t *chromaRow, int32_t width, const NV12Coefficients &k,
                   uint8_t *target) {
    const int32x4_t half = vdupq_n_s32(kRoundingHalf);
    const int16x8_t chromaCentre = vdupq_n_s16(128);
    const int16x8_t yOffset = vdupq_n_s16(static_cast<int16_t>(k.yOffset));
    int32_t x = 0;
    for (; x + 16 <= width; x += 16) {
        const uint8x16_t luma = vld1q_u8(lumaRow + x);
        // Eight Cb/Cr pairs, one for each two pixels.
        const uint8x8x2_t chroma = vld2_u8(chromaRow + x);
        const int16x8_t cb = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(chroma.val[0])), chromaCentre);
        const int16x8_t cr = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(chroma.val[1])), chromaCentre);
        const int32x4_t cbLow = vmovl_s16(vget_low_s16(cb)), cbHigh = vmovl_s16(vget_high_s16(cb));
        const int32x4_t crLow = vmovl_s16(vget_low_s16(cr)), crHigh = vmovl_s16(vget_high_s16(cr));
        const int32x4_t red[2] = {vmlaq_n_s32(half, crLow, k.rCr), vmlaq_n_s32(half, crHigh, k.rCr)};
        const int32x4_t green[2] = {vmlsq_n_s32(vmlsq_n_s32(half, cbLow, k.gCb), crLow, k.gCr),
                                    vmlsq_n_s32(vmlsq_n_s32(half, cbHigh, k.gCb), crHigh, k.gCr)};
        const int32x4_t blue[2] = {vmlaq_n_s32(half, cbLow, k.bCb), vmlaq_n_s32(half, cbHigh, k.bCb)};
        const int16x8_t lumaLow = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(luma))), yOffset);
        const int16x8_t lumaHigh = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(luma))), yOffset);
        const int32x4_t scaled[4] = {vmulq_n_s32(vmovl_s16(vget_low_s16(lumaLow)), k.yScale),
                                     vmulq_n_s32(vmovl_s16(vget_high_s16(lumaLow)), k.yScale),
                                     vmulq_n_s32(vmovl_s16(vget_low_s16(lumaHigh)), k.yScale),
                                     vmulq_n_s32(vmovl_s16(vget_high_s16(lumaHigh)), k.yScale)};
        const auto channel = [&scaled](const int32x4_t (&term)[2]) -> uint8x16_t {
            // Each pair's term, twice: once for each of its two pixels.
            const int32x4_t spread[4] = {vzip1q_s32(term[0], term[0]), vzip2q_s32(term[0], term[0]),
                                         vzip1q_s32(term[1], term[1]), vzip2q_s32(term[1], term[1])};
            uint16x4_t parts[4];
            for (int i = 0; i < 4; ++i) parts[i] = vqshrun_n_s32(vaddq_s32(scaled[i], spread[i]), 16);
            return vcombine_u8(vqmovn_u16(vcombine_u16(parts[0], parts[1])),
                               vqmovn_u16(vcombine_u16(parts[2], parts[3])));
        };
        uint8x16x3_t rgb;
        rgb.val[0] = channel(red);
        rgb.val[1] = channel(green);
        rgb.val[2] = channel(blue);
        vst3q_u8(target + static_cast<size_t>(x) * 3, rgb);
    }
    return x;
}
#endif

} // namespace

extern "C" void gc_luma_from_plane(const uint8_t *yPlane, int32_t width, int32_t height, int32_t bytesPerRow,
                                   bool videoRange, uint8_t *out) {
    if (yPlane == nullptr || out == nullptr || width <= 0 || height <= 0 || bytesPerRow < width) return;
    uint8_t table[256];
    if (videoRange) {
        for (int value = 0; value < 256; ++value) table[value] = stretchVideoRange(value);
    }
    for (int32_t y = 0; y < height; ++y) {
        const uint8_t *row = yPlane + static_cast<size_t>(y) * static_cast<size_t>(bytesPerRow);
        uint8_t *target = out + static_cast<size_t>(y) * static_cast<size_t>(width);
        if (videoRange) {
            for (int32_t x = 0; x < width; ++x) target[x] = table[row[x]];
        } else {
            for (int32_t x = 0; x < width; ++x) target[x] = row[x];
        }
    }
}

extern "C" void gc_luma_from_bgra(const uint8_t *bgra, int32_t width, int32_t height, int32_t bytesPerRow,
                                  uint8_t *out) {
    if (bgra == nullptr || out == nullptr || width <= 0 || height <= 0) return;
    if (static_cast<int64_t>(bytesPerRow) < static_cast<int64_t>(width) * 4) return;
    for (int32_t y = 0; y < height; ++y) {
        const uint8_t *row = bgra + static_cast<size_t>(y) * static_cast<size_t>(bytesPerRow);
        uint8_t *target = out + static_cast<size_t>(y) * static_cast<size_t>(width);
        for (int32_t x = 0; x < width; ++x) {
            const uint8_t *pixel = row + static_cast<size_t>(x) * 4;
            target[x] = lumaFromRGB(pixel[2], pixel[1], pixel[0]);
        }
    }
}

extern "C" void gc_rgb_from_nv12(const uint8_t *yPlane, int32_t yBytesPerRow, const uint8_t *cbcrPlane,
                                 int32_t cbcrBytesPerRow, int32_t width, int32_t frameHeight, int32_t rowTop,
                                 int32_t rowCount, bool videoRange, uint8_t *out) {
    if (yPlane == nullptr || cbcrPlane == nullptr || out == nullptr) return;
    if (width <= 0 || frameHeight <= 0 || rowCount <= 0) return;
    // The chroma row holds a Cb/Cr pair for every two luma columns.
    if (yBytesPerRow < width || cbcrBytesPerRow < ((width + 1) / 2) * 2) return;
    const NV12Coefficients &k = videoRange ? kVideoRangeRGB : kFullRangeRGB;
    for (int32_t index = 0; index < rowCount; ++index) {
        const int32_t y = rowTop + index;
        uint8_t *target = out + static_cast<size_t>(index) * static_cast<size_t>(width) * 3;
        if (y < 0 || y >= frameHeight) {
            for (int32_t x = 0; x < width * 3; ++x) target[x] = 0;
            continue;
        }
        const uint8_t *lumaRow = yPlane + static_cast<size_t>(y) * static_cast<size_t>(yBytesPerRow);
        const uint8_t *chromaRow = cbcrPlane + static_cast<size_t>(y / 2) * static_cast<size_t>(cbcrBytesPerRow);
#if defined(__aarch64__)
        const int32_t vectorised = rgbRowNeon(lumaRow, chromaRow, width, k, target);
#else
        const int32_t vectorised = 0;
#endif
        rgbRowScalar(lumaRow, chromaRow, vectorised, width, k, target);
    }
}

extern "C" bool gc_gate_read(gc_gray_image luma, int32_t step, gc_gate_reading *out) {
    if (luma.data == nullptr || luma.bytesPerRow < luma.width) return false;
    const uint8_t *data = luma.data;
    const size_t bytesPerRow = static_cast<size_t>(luma.bytesPerRow);
    return gateRead(luma.width, luma.height, step,
                    [data, bytesPerRow](int32_t x, int32_t y) -> int {
                        return data[static_cast<size_t>(y) * bytesPerRow + static_cast<size_t>(x)];
                    },
                    out);
}

extern "C" bool gc_gate_read_bgra(gc_color_image bgra, int32_t step, gc_gate_reading *out) {
    if (bgra.data == nullptr || bgra.bytesPerPixel < 3) return false;
    if (static_cast<int64_t>(bgra.bytesPerRow) < static_cast<int64_t>(bgra.width) * bgra.bytesPerPixel) return false;
    if (bgra.redOffset < 0 || bgra.redOffset >= bgra.bytesPerPixel || bgra.greenOffset < 0 ||
        bgra.greenOffset >= bgra.bytesPerPixel || bgra.blueOffset < 0 || bgra.blueOffset >= bgra.bytesPerPixel) {
        return false;
    }
    const uint8_t *data = bgra.data;
    const size_t bytesPerRow = static_cast<size_t>(bgra.bytesPerRow);
    const size_t bytesPerPixel = static_cast<size_t>(bgra.bytesPerPixel);
    const size_t red = static_cast<size_t>(bgra.redOffset), green = static_cast<size_t>(bgra.greenOffset),
                 blue = static_cast<size_t>(bgra.blueOffset);
    return gateRead(bgra.width, bgra.height, step,
                    [=](int32_t x, int32_t y) -> int {
                        const uint8_t *pixel = data + static_cast<size_t>(y) * bytesPerRow +
                                               static_cast<size_t>(x) * bytesPerPixel;
                        return lumaFromRGB(pixel[red], pixel[green], pixel[blue]);
                    },
                    out);
}

extern "C" int32_t gc_region_max_luma(gc_frame_planes frame, int32_t left, int32_t top, int32_t width,
                                      int32_t height) {
    if (!clipRegion(frame, left, top, width, height)) return -1;
    int brightest = 0;
    for (int32_t y = top; y < top + height && brightest < 255; ++y) {
        const uint8_t *row = frame.base + static_cast<size_t>(y) * static_cast<size_t>(frame.bytesPerRow);
        if (frame.bgra) {
            for (int32_t x = left; x < left + width; ++x) {
                const uint8_t *pixel = row + static_cast<size_t>(x) * 4;
                brightest = std::max<int>(brightest, lumaFromRGB(pixel[2], pixel[1], pixel[0]));
            }
        } else {
            for (int32_t x = left; x < left + width; ++x) brightest = std::max<int>(brightest, row[x]);
        }
    }
    // The stretch is monotonic, so the brightest stored value stretches to
    // the brightest full-range one.
    return frame.bgra || !frame.videoRange ? brightest : stretchVideoRange(brightest);
}

extern "C" int32_t gc_region_yellow_count(gc_frame_planes frame, int32_t left, int32_t top, int32_t width,
                                          int32_t height) {
    if (!clipRegion(frame, left, top, width, height)) return -1;
    if (!frame.bgra) {
        if (frame.chroma == nullptr || frame.chromaBytesPerRow < ((frame.width + 1) / 2) * 2) return -1;
    }
    int32_t count = 0;
    for (int32_t y = top; y < top + height; ++y) {
        const uint8_t *row = frame.base + static_cast<size_t>(y) * static_cast<size_t>(frame.bytesPerRow);
        if (frame.bgra) {
            for (int32_t x = left; x < left + width; ++x) {
                const uint8_t *pixel = row + static_cast<size_t>(x) * 4;
                const int blue = pixel[0], green = pixel[1], red = pixel[2];
                if (red > 110 && green > 80 && 5 * blue < 4 * green) ++count;
            }
        } else {
            const uint8_t *chromaRow =
                frame.chroma + static_cast<size_t>(y / 2) * static_cast<size_t>(frame.chromaBytesPerRow);
            for (int32_t x = left; x < left + width; ++x) {
                if (row[x] > 70 && chromaRow[static_cast<size_t>(x / 2) * 2] < 120) ++count;
            }
        }
    }
    return count;
}
