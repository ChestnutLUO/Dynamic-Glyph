/*
 * NodeArrayDetector in C++: bright ring components, then a lattice fit.
 * Oracle: Sources/GlyphRecognition/NodeArrayDetector.swift. With the default
 * options every arithmetic step runs in the Swift order so the result is
 * bit-identical; the band and scale cuts are the hunt options in glyph_core.h.
 */

#include "glyph_core_internal.hpp"

#include <algorithm>
#include <cmath>

/* Swift never fuses a multiply and an add; clang does by default. */
#ifdef __clang__
#pragma clang fp contract(off)
#endif

namespace glyphcore {

namespace {

constexpr uint8_t kRingThreshold = 160;
constexpr int32_t kMinRings = 8;
constexpr int32_t kMaxRings = 128;

struct Match {
    int32_t node;
    int32_t ring;
};

/* The greedy node-order assignment, `NodeArrayDetector.match`. */
template <typename RingT>
int32_t matchRings(const std::vector<RingT> &rings, double originX, double originY, double sizeX, double sizeY,
                   double tolerance, Match *out) {
    bool used[kMaxRings] = {};
    int32_t count = 0;
    for (int32_t node = 0; node < GC_NODE_COUNT; ++node) {
        const double targetX = originX + kCanonicalX[node] * sizeX;
        const double targetY = originY + kCanonicalY[node] * sizeY;
        int32_t nearest = -1;
        double distance = tolerance * tolerance;
        for (size_t index = 0; index < rings.size(); ++index) {
            if (used[index]) continue;
            const double dx = rings[index].centerX - targetX;
            const double dy = rings[index].centerY - targetY;
            const double squared = dx * dx + dy * dy;
            if (squared < distance) {
                distance = squared;
                nearest = static_cast<int32_t>(index);
            }
        }
        if (nearest >= 0) {
            used[nearest] = true;
            out[count++] = Match{node, nearest};
        }
    }
    return count;
}

} // namespace

double sampleLuma(const gc_gray_image &image, double x, double y) {
    const double rx = std::round(x), ry = std::round(y);
    if (!(rx >= 0) || !(ry >= 0) || !(rx < image.width) || !(ry < image.height)) return 0;
    return pixelAt(image, static_cast<int32_t>(rx), static_cast<int32_t>(ry));
}

gc_hunt_options sanitizedHuntOptions(const gc_hunt_options *options) {
    gc_hunt_options result = gc_hunt_options_default();
    if (options == nullptr) return result;
    if (std::isfinite(options->rowTop)) result.rowTop = std::min(1.0, std::max(0.0, options->rowTop));
    if (std::isfinite(options->rowBottom)) result.rowBottom = std::min(1.0, std::max(0.0, options->rowBottom));
    if (options->scale > 1) result.scale = options->scale;
    return result;
}

bool ArrayHunter::acceptRing(const gc_gray_image &image, int32_t count, double sumX, double sumY, int32_t minX,
                             int32_t maxX, int32_t minY, int32_t maxY, Ring *ring) const {
    const double scale = static_cast<double>(std::min(image.width, image.height));
    const double bw = static_cast<double>(maxX - minX + 1), bh = static_cast<double>(maxY - minY + 1);
    const double diameter = (bw + bh) / 2;
    const double fill = static_cast<double>(count) / (bw * bh);
    if (!(diameter >= std::max(5.0, scale * 0.015)) || !(diameter <= scale * 0.07) || !(bw / bh >= 0.75) ||
        !(bw / bh <= 1.33) || !(fill >= 0.15) || !(fill <= 0.65)) {
        return false;
    }
    const double centerX = sumX / static_cast<double>(count), centerY = sumY / static_cast<double>(count);
    if (!(sampleLuma(image, centerX, centerY) < kRingThreshold)) return false; // a ring has a hole
    *ring = Ring{centerX, centerY, diameter / 2};
    return true;
}

void ArrayHunter::collectRings(const gc_gray_image &image, Band band) {
    const int32_t w = image.width;
    const size_t rows = static_cast<size_t>(band.bottom - band.top);
    visited_.assign(static_cast<size_t>(w) * rows, 0);
    stack_.clear();
    rings_.clear();
    const auto visitedIndex = [&](int32_t x, int32_t y) {
        return static_cast<size_t>(y - band.top) * static_cast<size_t>(w) + static_cast<size_t>(x);
    };
    for (int32_t startY = band.top; startY < band.bottom; ++startY) {
        for (int32_t startX = 0; startX < w; ++startX) {
            if (pixelAt(image, startX, startY) < kRingThreshold || visited_[visitedIndex(startX, startY)]) continue;
            stack_.push_back(startY * w + startX);
            visited_[visitedIndex(startX, startY)] = 1;
            int32_t count = 0;
            double sumX = 0, sumY = 0;
            int32_t minX = w, minY = image.height, maxX = 0, maxY = 0;
            while (!stack_.empty()) {
                const int32_t index = stack_.back();
                stack_.pop_back();
                const int32_t x = index % w, y = index / w;
                count += 1;
                sumX += static_cast<double>(x);
                sumY += static_cast<double>(y);
                minX = std::min(minX, x);
                maxX = std::max(maxX, x);
                minY = std::min(minY, y);
                maxY = std::max(maxY, y);
                const int32_t yLow = std::max(band.top, y - 1), yHigh = std::min(band.bottom - 1, y + 1);
                const int32_t xLow = std::max(0, x - 1), xHigh = std::min(w - 1, x + 1);
                for (int32_t ny = yLow; ny <= yHigh; ++ny) {
                    for (int32_t nx = xLow; nx <= xHigh; ++nx) {
                        const size_t v = visitedIndex(nx, ny);
                        if (!visited_[v] && pixelAt(image, nx, ny) >= kRingThreshold) {
                            visited_[v] = 1;
                            stack_.push_back(ny * w + nx);
                        }
                    }
                }
            }
            Ring ring;
            if (acceptRing(image, count, sumX, sumY, minX, maxX, minY, maxY, &ring)) {
                rings_.push_back(ring);
                if (rings_.size() > static_cast<size_t>(kMaxRings)) return; // the fit rejects more than 128 anyway
            }
        }
    }
}

/* The `scale` cut: components are traced on the coarse grid of every
 * scale-th pixel, obviously oversized or undersized ones are dropped, and the
 * rest are re-measured on all the pixels inside the coarse box grown by
 * `scale` on every side. */
void ArrayHunter::collectRingsScaled(const gc_gray_image &image, Band band, int32_t scale) {
    const int32_t w = image.width;
    const int32_t rows = band.bottom - band.top;
    const int32_t coarseWidth = (w + scale - 1) / scale;
    const int32_t coarseRows = (rows + scale - 1) / scale;
    visited_.assign(static_cast<size_t>(coarseWidth) * static_cast<size_t>(coarseRows), 0);
    stack_.clear();
    rings_.clear();
    const double frameScale = static_cast<double>(std::min(image.width, image.height));
    const double slack = 2.0 * scale;
    const double minDiameter = std::max(5.0, frameScale * 0.015) - slack;
    const double maxDiameter = frameScale * 0.07 + slack;
    const auto fullX = [&](int32_t cx) { return cx * scale; };
    const auto fullY = [&](int32_t cy) { return band.top + cy * scale; };
    for (int32_t startCY = 0; startCY < coarseRows; ++startCY) {
        for (int32_t startCX = 0; startCX < coarseWidth; ++startCX) {
            const size_t startIndex = static_cast<size_t>(startCY) * coarseWidth + startCX;
            if (visited_[startIndex] || pixelAt(image, fullX(startCX), fullY(startCY)) < kRingThreshold) continue;
            stack_.push_back(static_cast<int32_t>(startIndex));
            visited_[startIndex] = 1;
            int32_t minCX = coarseWidth, minCY = coarseRows, maxCX = 0, maxCY = 0;
            while (!stack_.empty()) {
                const int32_t index = stack_.back();
                stack_.pop_back();
                const int32_t cx = index % coarseWidth, cy = index / coarseWidth;
                minCX = std::min(minCX, cx);
                maxCX = std::max(maxCX, cx);
                minCY = std::min(minCY, cy);
                maxCY = std::max(maxCY, cy);
                for (int32_t ny = std::max(0, cy - 1); ny <= std::min(coarseRows - 1, cy + 1); ++ny) {
                    for (int32_t nx = std::max(0, cx - 1); nx <= std::min(coarseWidth - 1, cx + 1); ++nx) {
                        const size_t v = static_cast<size_t>(ny) * coarseWidth + nx;
                        if (!visited_[v] && pixelAt(image, fullX(nx), fullY(ny)) >= kRingThreshold) {
                            visited_[v] = 1;
                            stack_.push_back(static_cast<int32_t>(v));
                        }
                    }
                }
            }
            const double coarseDiameter =
                (static_cast<double>(maxCX - minCX + 1) + static_cast<double>(maxCY - minCY + 1)) * scale / 2;
            if (coarseDiameter < minDiameter || coarseDiameter > maxDiameter) continue;

            // Refine on the full pixels inside the scaled box grown by `scale`.
            const int32_t x0 = std::max(0, fullX(minCX) - scale), x1 = std::min(w - 1, fullX(maxCX) + scale);
            const int32_t y0 = std::max(band.top, fullY(minCY) - scale);
            const int32_t y1 = std::min(band.bottom - 1, fullY(maxCY) + scale);
            int32_t count = 0;
            double sumX = 0, sumY = 0;
            int32_t minX = w, minY = image.height, maxX = 0, maxY = 0;
            for (int32_t y = y0; y <= y1; ++y) {
                for (int32_t x = x0; x <= x1; ++x) {
                    if (pixelAt(image, x, y) < kRingThreshold) continue;
                    count += 1;
                    sumX += static_cast<double>(x);
                    sumY += static_cast<double>(y);
                    minX = std::min(minX, x);
                    maxX = std::max(maxX, x);
                    minY = std::min(minY, y);
                    maxY = std::max(maxY, y);
                }
            }
            if (count == 0) continue;
            Ring ring;
            if (!acceptRing(image, count, sumX, sumY, minX, maxX, minY, maxY, &ring)) continue;
            // Two coarse fragments of one ring measure the same pixels.
            bool duplicate = false;
            for (const Ring &known : rings_) {
                if (known.centerX == ring.centerX && known.centerY == ring.centerY) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            rings_.push_back(ring);
            if (rings_.size() > static_cast<size_t>(kMaxRings)) return;
        }
    }
}

bool ArrayHunter::detect(const gc_gray_image &image, const gc_hunt_options &options, gc_fit *out) {
    if (out == nullptr || image.data == nullptr || image.width <= 0 || image.height <= 0 ||
        image.bytesPerRow < image.width) {
        return false;
    }
    const int32_t w = image.width, h = image.height;
    Band band{0, h};
    if (options.rowTop > 0) band.top = std::min(h, static_cast<int32_t>(std::floor(options.rowTop * h)));
    if (options.rowBottom < 1) {
        band.bottom = std::max(band.top, std::min(h, static_cast<int32_t>(std::ceil(options.rowBottom * h))));
    }
    if (band.bottom <= band.top) return false;
    if (options.scale > 1) {
        collectRingsScaled(image, band, options.scale);
    } else {
        collectRings(image, band);
    }
    if (rings_.size() < static_cast<size_t>(kMinRings) || rings_.size() > static_cast<size_t>(kMaxRings)) return false;

    const double minSide = static_cast<double>(std::min(w, h));
    bool haveBest = false;
    gc_fit best{};
    int32_t bestCount = 0;
    Match matches[GC_NODE_COUNT];
    double radii[GC_NODE_COUNT];

    for (const Ring &top : rings_) {
        for (const Ring &bottom : rings_) {
            const double height = bottom.centerY - top.centerY;
            if (!(height >= minSide * 0.35) || !(std::fabs(top.centerX - bottom.centerX) < height * 0.015)) continue;
            const double centerX = (top.centerX + bottom.centerX) / 2;
            for (const Ring &side : rings_) {
                const double relativeY = (side.centerY - top.centerY) / height;
                if (!(std::min(std::fabs(relativeY - 0.25), std::fabs(relativeY - 0.75)) < 0.015)) continue;
                const double width = 2 * std::fabs(side.centerX - centerX);
                if (!(width / height >= 0.65) || !(width / height <= 1.05)) continue;
                double origin[2] = {centerX - width / 2, top.centerY};
                double size[2] = {width, height};
                const double tolerance = std::max(2.0, height * 0.012);
                int32_t count = matchRings(rings_, origin[0], origin[1], size[0], size[1], tolerance, matches);
                if (count < kMinRings) continue;

                // Least squares removes centroid noise from the three anchors.
                for (int axis = 0; axis < 2; ++axis) {
                    const double *canonical = axis == 0 ? kCanonicalX : kCanonicalY;
                    double meanX = 0, meanY = 0;
                    for (int32_t i = 0; i < count; ++i) {
                        meanX = meanX + canonical[matches[i].node];
                    }
                    meanX = meanX / static_cast<double>(count);
                    for (int32_t i = 0; i < count; ++i) {
                        const Ring &ring = rings_[matches[i].ring];
                        meanY = meanY + (axis == 0 ? ring.centerX : ring.centerY);
                    }
                    meanY = meanY / static_cast<double>(count);
                    double variance = 0, covariance = 0;
                    for (int32_t i = 0; i < count; ++i) {
                        const double x = canonical[matches[i].node];
                        variance = variance + (x - meanX) * (x - meanX);
                    }
                    for (int32_t i = 0; i < count; ++i) {
                        const Ring &ring = rings_[matches[i].ring];
                        const double x = canonical[matches[i].node];
                        const double y = axis == 0 ? ring.centerX : ring.centerY;
                        covariance = covariance + (x - meanX) * (y - meanY);
                    }
                    size[axis] = covariance / variance;
                    origin[axis] = meanY - size[axis] * meanX;
                }
                count = matchRings(rings_, origin[0], origin[1], size[0], size[1], tolerance, matches);
                if (count < kMinRings || !(origin[0] >= 0) || !(origin[1] >= 0) || !(origin[0] + size[0] < w) ||
                    !(origin[1] + size[1] < h)) {
                    continue;
                }
                double sum = 0;
                for (int32_t i = 0; i < count; ++i) {
                    const Ring &ring = rings_[matches[i].ring];
                    const double dx = ring.centerX - (origin[0] + kCanonicalX[matches[i].node] * size[0]);
                    const double dy = ring.centerY - (origin[1] + kCanonicalY[matches[i].node] * size[1]);
                    sum = sum + (dx * dx + dy * dy);
                }
                const double error = std::sqrt(sum / static_cast<double>(count));
                for (int32_t i = 0; i < count; ++i) radii[i] = rings_[matches[i].ring].radius;
                std::sort(radii, radii + count);
                uint16_t matched = 0;
                for (int32_t i = 0; i < count; ++i) matched |= static_cast<uint16_t>(1u << matches[i].node);

                if (!haveBest || count > bestCount || (count == bestCount && error < best.rootMeanSquareError)) {
                    haveBest = true;
                    bestCount = count;
                    best.imageWidth = w;
                    best.imageHeight = h;
                    best.originX = origin[0];
                    best.originY = origin[1];
                    best.sizeX = size[0];
                    best.sizeY = size[1];
                    best.nodeRadius = radii[count / 2];
                    best.matchedNodes = matched;
                    best.rootMeanSquareError = error;
                }
            }
        }
    }
    if (!haveBest) return false;
    *out = best;
    return true;
}

} // namespace glyphcore

extern "C" gc_hunt_options gc_hunt_options_default(void) {
    gc_hunt_options options;
    options.rowTop = 0;
    options.rowBottom = 1;
    options.scale = 1;
    return options;
}

extern "C" bool gc_detect_array(gc_gray_image luma, const gc_hunt_options *options, gc_fit *out) {
    glyphcore::ArrayHunter hunter;
    return hunter.detect(luma, glyphcore::sanitizedHuntOptions(options), out);
}
