#ifndef GLYPH_CORE_INTERNAL_HPP
#define GLYPH_CORE_INTERNAL_HPP

/*
 * Shared between node_array.cpp and glyph_frame.cpp: the canonical lattice
 * and the hunt the session reuses across frames. Not part of the ABI.
 */

#include "glyph_core.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace glyphcore {

/* NodeArray.canonical: node n is at index n, `a` is 10. */
constexpr double kCanonicalX[GC_NODE_COUNT] = {0.50, 0.00, 1.00, 0.25, 0.75, 0.50, 0.25, 0.75, 0.00, 1.00, 0.50};
constexpr double kCanonicalY[GC_NODE_COUNT] = {0.000, 0.250, 0.250, 0.375, 0.375, 0.500, 0.625, 0.625, 0.750, 0.750, 1.000};

inline uint8_t pixelAt(const gc_gray_image &image, int32_t x, int32_t y) {
    return image.data[static_cast<size_t>(y) * static_cast<size_t>(image.bytesPerRow) + static_cast<size_t>(x)];
}

/* LuminanceImage.sample: the nearest pixel by rounded(), 0 outside the frame. */
double sampleLuma(const gc_gray_image &image, double x, double y);

/* NULL and out-of-range values fall back to the defaults. */
gc_hunt_options sanitizedHuntOptions(const gc_hunt_options *options);

/* NodeArrayDetector, with its buffers kept between calls so a session in a
 * steady state allocates nothing. */
class ArrayHunter {
public:
    bool detect(const gc_gray_image &image, const gc_hunt_options &options, gc_fit *out);

private:
    struct Ring {
        double centerX;
        double centerY;
        double radius;
    };
    struct Band {
        int32_t top;
        int32_t bottom;
    };

    void collectRings(const gc_gray_image &image, Band band);
    void collectRingsScaled(const gc_gray_image &image, Band band, int32_t scale);
    bool acceptRing(const gc_gray_image &image, int32_t count, double sumX, double sumY, int32_t minX, int32_t maxX,
                    int32_t minY, int32_t maxY, Ring *ring) const;

    std::vector<uint8_t> visited_;
    std::vector<int32_t> stack_;
    std::vector<Ring> rings_;
};

} // namespace glyphcore

#endif /* GLYPH_CORE_INTERNAL_HPP */
