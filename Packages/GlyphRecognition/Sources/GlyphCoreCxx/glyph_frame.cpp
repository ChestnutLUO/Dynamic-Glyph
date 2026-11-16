/*
 * GlyphFrameRecognizer and GlyphFrameSession in C++.
 * Oracles: Sources/GlyphRecognition/GlyphGeometry.swift,
 * GlyphFrameRecognizer.swift and GlyphFrameSession.swift. Every arithmetic
 * step runs in the Swift order so samples and ink pixels match exactly.
 */

#include "glyph_core_internal.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <new>
#include <vector>

#ifdef __clang__
#pragma clang fp contract(off)
#endif

namespace {

using glyphcore::kCanonicalX;
using glyphcore::kCanonicalY;

struct Point {
    double x;
    double y;
};

/* NodeArray.segment(_:_:passesThrough:) on the canonical positions. */
bool segmentPassesThrough(int a, int b, int c) {
    if (c == a || c == b) return false;
    const double px = kCanonicalX[a], py = kCanonicalY[a];
    const double qx = kCanonicalX[b], qy = kCanonicalY[b];
    const double rx = kCanonicalX[c], ry = kCanonicalY[c];
    const double cross = (qx - px) * (ry - py) - (qy - py) * (rx - px);
    if (!(std::fabs(cross) < 1e-9)) return false;
    const double dot = (rx - px) * (qx - px) + (ry - py) * (qy - py);
    const double lengthSquared = (qx - px) * (qx - px) + (qy - py) * (qy - py);
    return dot > 1e-9 && dot < lengthSquared - 1e-9;
}

/* GlyphGeometry.elementaryEdges, with a lookup from a node pair to its index. */
struct ElementaryEdges {
    int32_t count = 0;
    gc_edge edges[GC_MAX_ELEMENTARY_EDGES] = {};
    int32_t indexOf[GC_NODE_COUNT][GC_NODE_COUNT] = {};

    ElementaryEdges() {
        for (int a = 0; a < GC_NODE_COUNT; ++a) {
            for (int b = 0; b < GC_NODE_COUNT; ++b) indexOf[a][b] = -1;
        }
        for (int a = 0; a < GC_NODE_COUNT; ++a) {
            for (int b = a + 1; b < GC_NODE_COUNT; ++b) {
                bool interrupted = false;
                for (int c = 0; c < GC_NODE_COUNT && !interrupted; ++c) interrupted = segmentPassesThrough(a, b, c);
                if (interrupted || count >= GC_MAX_ELEMENTARY_EDGES) continue;
                edges[count] = gc_edge{static_cast<uint8_t>(a), static_cast<uint8_t>(b)};
                indexOf[a][b] = count;
                indexOf[b][a] = count;
                ++count;
            }
        }
    }
};

const ElementaryEdges &elementary() {
    static const ElementaryEdges edges;
    return edges;
}

/* GlyphGeometry.normalizedEdges over a template, as a bitmask of elementary
 * edge indices: every rendered segment is split at the nodes it crosses. */
uint64_t normalizedMask(const gc_template &glyph) {
    const ElementaryEdges &table = elementary();
    uint64_t mask = 0;
    const int32_t edgeCount = std::min<int32_t>(glyph.edgeCount, GC_MAX_TEMPLATE_EDGES);
    for (int32_t i = 0; i < edgeCount; ++i) {
        const int lower = std::min(glyph.edges[i].lower, glyph.edges[i].upper);
        const int upper = std::max(glyph.edges[i].lower, glyph.edges[i].upper);
        if (lower == upper || upper >= GC_NODE_COUNT) continue;
        const double ax = kCanonicalX[lower], ay = kCanonicalY[lower];
        const double dx = kCanonicalX[upper] - ax, dy = kCanonicalY[upper] - ay;
        struct Along {
            int node;
            double key;
        };
        Along nodes[GC_NODE_COUNT];
        int nodeCount = 0;
        for (int c = 0; c < GC_NODE_COUNT; ++c) {
            if (c != lower && c != upper && !segmentPassesThrough(lower, upper, c)) continue;
            nodes[nodeCount++] = Along{c, (kCanonicalX[c] - ax) * dx + (kCanonicalY[c] - ay) * dy};
        }
        std::sort(nodes, nodes + nodeCount, [](const Along &l, const Along &r) { return l.key < r.key; });
        for (int k = 0; k + 1 < nodeCount; ++k) {
            const int32_t index = table.indexOf[nodes[k].node][nodes[k + 1].node];
            if (index >= 0) mask |= uint64_t{1} << index;
        }
    }
    return mask;
}

int popcount64(uint64_t value) {
    int count = 0;
    while (value != 0) {
        value &= value - 1;
        ++count;
    }
    return count;
}

/* GlyphFrameRecognizer.convexHull: monotone chain over the node positions. */
int convexHull(const Point *points, int count, Point *hull) {
    Point sorted[GC_NODE_COUNT];
    std::copy(points, points + count, sorted);
    std::sort(sorted, sorted + count,
              [](const Point &l, const Point &r) { return l.x != r.x ? l.x < r.x : l.y < r.y; });
    if (count <= 2) {
        std::copy(sorted, sorted + count, hull);
        return count;
    }
    const auto cross = [](const Point &o, const Point &a, const Point &b) {
        return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    };
    Point lower[GC_NODE_COUNT], upper[GC_NODE_COUNT];
    int lowerCount = 0, upperCount = 0;
    for (int i = 0; i < count; ++i) {
        while (lowerCount >= 2 && cross(lower[lowerCount - 2], lower[lowerCount - 1], sorted[i]) <= 0) --lowerCount;
        lower[lowerCount++] = sorted[i];
    }
    for (int i = count - 1; i >= 0; --i) {
        while (upperCount >= 2 && cross(upper[upperCount - 2], upper[upperCount - 1], sorted[i]) <= 0) --upperCount;
        upper[upperCount++] = sorted[i];
    }
    int hullCount = 0;
    for (int i = 0; i + 1 < lowerCount; ++i) hull[hullCount++] = lower[i];
    for (int i = 0; i + 1 < upperCount; ++i) hull[hullCount++] = upper[i];
    return hullCount;
}

/* GlyphFrameRecognizer.isWithin: inside the polygon or within `margin` of it. */
bool isWithin(double margin, const Point *hull, int hullCount, Point point) {
    if (hullCount <= 2) return true;
    bool inside = true;
    double nearest = INFINITY;
    for (int index = 0; index < hullCount; ++index) {
        const Point a = hull[index], b = hull[(index + 1) % hullCount];
        const double ex = b.x - a.x, ey = b.y - a.y;
        const double ox = point.x - a.x, oy = point.y - a.y;
        if (ex * oy - ey * ox < 0) inside = false;
        const double t = std::min(1.0, std::max(0.0, (ox * ex + oy * ey) / (ex * ex + ey * ey)));
        const double dx = point.x - (a.x + t * ex), dy = point.y - (a.y + t * ey);
        nearest = std::min(nearest, dx * dx + dy * dy);
    }
    return inside || nearest <= margin * margin;
}

void clearObservation(gc_observation *out, gc_observation_state state) {
    std::memset(out, 0, sizeof(*out));
    out->state = state;
}

} // namespace

struct gc_session {
    std::vector<uint64_t> templates;
    int32_t maxEdgeDistance = 0;
    gc_hunt_options hunt = gc_hunt_options_default();
    glyphcore::ArrayHunter hunter;
    /* The returned observation's ink, and the hunt candidate's; swapped when
     * the candidate is adopted. */
    std::vector<int32_t> ink;
    std::vector<int32_t> candidateInk;
    gc_observation candidate;

    /* GlyphFrameSession state. */
    bool hasCalibration = false;
    gc_fit calibration{};
    bool hasPreviousTime = false;
    double previousTime = 0;
    bool hasValidatedAt = false;
    double validatedAt = 0;
    double lastFitAttempt = -INFINITY;

    /* GlyphFrameSession.reset() */
    void resetState() {
        hasCalibration = false;
        hasPreviousTime = false;
        hasValidatedAt = false;
        lastFitAttempt = -INFINITY;
    }
};

namespace {

/* GlyphFrameRecognizer.observe(_:calibration:) followed by classify. */
void observeWithFit(const gc_session &session, const gc_gray_image &image, const gc_fit &fit, gc_observation *out,
                    std::vector<int32_t> &ink) {
    ink.clear();
    if (image.data == nullptr || image.width <= 0 || image.height <= 0 || fit.imageWidth != image.width ||
        fit.imageHeight != image.height) {
        clearObservation(out, GC_STATE_CALIBRATION_MISMATCH);
        out->calibration = fit;
        return;
    }
    clearObservation(out, GC_STATE_NONE);
    out->hasCalibration = true;
    out->calibration = fit;

    Point positions[GC_NODE_COUNT];
    for (int n = 0; n < GC_NODE_COUNT; ++n) {
        positions[n] = Point{fit.originX + kCanonicalX[n] * fit.sizeX, fit.originY + kCanonicalY[n] * fit.sizeY};
    }
    const ElementaryEdges &table = elementary();
    const double halfWidth = std::max(1.0, fit.sizeX * 0.006);
    out->edgeCount = table.count;
    uint64_t present = 0;
    for (int32_t e = 0; e < table.count; ++e) {
        const Point from = positions[table.edges[e].lower], to = positions[table.edges[e].upper];
        const double deltaX = to.x - from.x, deltaY = to.y - from.y;
        const double length = std::sqrt(deltaX * deltaX + deltaY * deltaY);
        const double directionX = deltaX / length, directionY = deltaY / length;
        const double normalX = -directionY, normalY = directionX;
        const double trim = std::min(length * 0.3, fit.nodeRadius * 1.9);
        int32_t supporting = 0;
        for (int index = 0; index < GC_EDGE_SAMPLES; ++index) {
            const double distance = trim + (length - 2 * trim) * (static_cast<double>(index) + 0.5) / 24;
            const double pointX = from.x + directionX * distance, pointY = from.y + directionY * distance;
            double center = -INFINITY;
            for (double k = -1.0; k <= 1.0; k += 1.0) {
                const double value = glyphcore::sampleLuma(image, pointX + normalX * (k * halfWidth),
                                                           pointY + normalY * (k * halfWidth));
                if (value > center) center = value;
            }
            const double offset = halfWidth * 4 + fit.nodeRadius * 0.2;
            const double background = (glyphcore::sampleLuma(image, pointX + normalX * offset, pointY + normalY * offset) +
                                       glyphcore::sampleLuma(image, pointX - normalX * offset, pointY - normalY * offset)) /
                                      2;
            double sample = 0;
            if (center >= 60) sample = std::min(1.0, std::max(0.0, (center - background) / 128));
            out->samples[e][index] = sample;
            if (sample >= 0.18) ++supporting;
        }
        const double coverage = static_cast<double>(supporting) / static_cast<double>(GC_EDGE_SAMPLES);
        if (coverage >= 0.8) present |= uint64_t{1} << e;
    }

    // Ink inside the array's box, away from the node rings and their glow,
    // and no further than the glow margin outside the hexagon of outer nodes.
    const double maskRadiusSquared = fit.nodeRadius * fit.nodeRadius * 3.61;
    Point hull[GC_NODE_COUNT];
    const int hullCount = convexHull(positions, GC_NODE_COUNT, hull);
    const double glowMargin = std::max(2.0, fit.sizeX * 0.015);
    const double lastX = static_cast<double>(image.width - 1), lastY = static_cast<double>(image.height - 1);
    const int32_t minX = static_cast<int32_t>(std::min(lastX, std::max(0.0, fit.originX)));
    const int32_t maxX = static_cast<int32_t>(std::min(lastX, std::max(0.0, fit.originX + fit.sizeX)));
    const int32_t minY = static_cast<int32_t>(std::min(lastY, std::max(0.0, fit.originY)));
    const int32_t maxY = static_cast<int32_t>(std::min(lastY, std::max(0.0, fit.originY + fit.sizeY)));
    for (int32_t y = minY; y <= maxY; ++y) {
        for (int32_t x = minX; x <= maxX; ++x) {
            if (glyphcore::pixelAt(image, x, y) < 80) continue;
            const Point point{static_cast<double>(x), static_cast<double>(y)};
            if (!isWithin(glowMargin, hull, hullCount, point)) continue;
            bool onRing = false;
            for (int n = 0; n < GC_NODE_COUNT && !onRing; ++n) {
                const double dx = point.x - positions[n].x, dy = point.y - positions[n].y;
                onRing = dx * dx + dy * dy <= maskRadiusSquared;
            }
            if (!onRing) ink.push_back(y * image.width + x);
        }
    }

    // classify
    const bool noEdges = present == 0;
    int32_t exactCount = 0;
    if (!noEdges) {
        for (size_t t = 0; t < session.templates.size(); ++t) {
            const int32_t distance = popcount64(present ^ session.templates[t]);
            if (distance > session.maxEdgeDistance) continue;
            out->candidates[out->candidateCount++] = gc_candidate{static_cast<int32_t>(t), distance};
            if (distance == 0) ++exactCount;
        }
        std::sort(out->candidates, out->candidates + out->candidateCount,
                  [](const gc_candidate &l, const gc_candidate &r) {
                      return l.distance != r.distance ? l.distance < r.distance : l.templateIndex < r.templateIndex;
                  });
        for (size_t t = 0; t < session.templates.size(); ++t) {
            const uint64_t glyph = session.templates[t];
            if ((present & glyph) == present && present != glyph) out->extensions[out->extensionCount++] = static_cast<int32_t>(t);
        }
    }
    // Measure actual spatial support of the present edges, not an area estimate.
    struct Segment {
        Point a;
        Point b;
    };
    Segment segments[GC_MAX_ELEMENTARY_EDGES];
    int segmentCount = 0;
    for (int32_t e = 0; e < table.count; ++e) {
        if ((present >> e) & 1u) segments[segmentCount++] = Segment{positions[table.edges[e].lower], positions[table.edges[e].upper]};
    }
    const double inkRadius = std::max(2.0, fit.sizeX * 0.015);
    int32_t unexplained = 0;
    for (const int32_t index : ink) {
        const Point point{static_cast<double>(index % fit.imageWidth), static_cast<double>(index / fit.imageWidth)};
        bool explained = false;
        for (int s = 0; s < segmentCount && !explained; ++s) {
            const double dx = segments[s].b.x - segments[s].a.x, dy = segments[s].b.y - segments[s].a.y;
            const double t = std::min(1.0, std::max(0.0, ((point.x - segments[s].a.x) * dx + (point.y - segments[s].a.y) * dy) /
                                                             (dx * dx + dy * dy)));
            const double distanceX = point.x - (segments[s].a.x + t * dx);
            const double distanceY = point.y - (segments[s].a.y + t * dy);
            explained = distanceX * distanceX + distanceY * distanceY <= inkRadius * inkRadius;
        }
        if (!explained) ++unexplained;
    }
    const int32_t inkCount = static_cast<int32_t>(ink.size());
    const bool excessiveInk = unexplained > std::max<int32_t>(24, static_cast<int32_t>(static_cast<double>(inkCount) * 0.35));
    gc_observation_state state;
    if (exactCount > 0 && excessiveInk) {
        state = GC_STATE_UNEXPLAINED_INK;
    } else if (exactCount == 1) {
        state = GC_STATE_UNIQUE_VISIBLE_SHAPE;
    } else if (exactCount > 1) {
        state = GC_STATE_AMBIGUOUS_SHAPE;
    } else if (noEdges && inkCount < std::max<int32_t>(6, static_cast<int32_t>(fit.sizeX * 0.025))) {
        state = GC_STATE_NO_STROKE;
    } else {
        state = GC_STATE_UNRECOGNIZED_STROKE;
    }
    out->state = state;
    out->strokePixelCount = inkCount;
    out->unexplainedInkPixelCount = unexplained;
}

} // namespace

extern "C" int32_t gc_elementary_edge_count(void) { return elementary().count; }

extern "C" bool gc_elementary_edge(int32_t index, gc_edge *out) {
    const ElementaryEdges &table = elementary();
    if (out == nullptr || index < 0 || index >= table.count) return false;
    *out = table.edges[index];
    return true;
}

extern "C" gc_session *gc_session_create(const gc_template *templates, int32_t count, int32_t maxEdgeDistance,
                                         const gc_hunt_options *hunt) {
    if (count < 0 || count > GC_MAX_TEMPLATES || maxEdgeDistance < 0 || (count > 0 && templates == nullptr)) {
        return nullptr;
    }
    gc_session *session = new (std::nothrow) gc_session();
    if (session == nullptr) return nullptr;
    session->templates.reserve(static_cast<size_t>(count));
    for (int32_t i = 0; i < count; ++i) session->templates.push_back(normalizedMask(templates[i]));
    session->maxEdgeDistance = maxEdgeDistance;
    session->hunt = glyphcore::sanitizedHuntOptions(hunt);
    std::memset(&session->candidate, 0, sizeof(session->candidate));
    return session;
}

extern "C" void gc_session_destroy(gc_session *session) { delete session; }

extern "C" void gc_session_reset(gc_session *session) {
    if (session == nullptr) return;
    session->resetState();
    session->ink.clear();
}

extern "C" void gc_session_observe(gc_session *session, gc_gray_image luma, double time, gc_session_result *out) {
    if (out == nullptr) return;
    std::memset(out, 0, sizeof(*out));
    if (session == nullptr) return;
    gc_session &s = *session;
    const auto report = [&] {
        out->hasValidatedAt = s.hasValidatedAt;
        out->validatedAt = s.validatedAt;
        out->hasCalibration = s.hasCalibration;
        out->calibration = s.calibration;
        if (!out->hasObservation) s.ink.clear();
    };
    if (!std::isfinite(time)) {
        s.resetState();
        report();
        return;
    }
    if (s.hasPreviousTime && (time < s.previousTime || time - s.previousTime > 1)) s.resetState();
    s.hasPreviousTime = true;
    s.previousTime = time;
    if (s.hasCalibration && (s.calibration.imageWidth != luma.width || s.calibration.imageHeight != luma.height)) {
        s.resetState();
        s.hasPreviousTime = true;
        s.previousTime = time;
    }
    // A cached fit is not evidence that the array is still on screen.
    if (s.hasValidatedAt && time - s.validatedAt > 8) s.hasCalibration = false;
    if (s.hasCalibration) {
        observeWithFit(s, luma, s.calibration, &out->observation, s.ink);
        out->hasObservation = true;
    }
    if (!s.hasCalibration || (out->observation.state == GC_STATE_NO_STROKE && time - s.lastFitAttempt >= 0.5)) {
        s.lastFitAttempt = time;
        const auto huntStarted = std::chrono::steady_clock::now();
        gc_fit fit{};
        const bool found = s.hunter.detect(luma, s.hunt, &fit);
        const auto elapsed = std::chrono::steady_clock::now() - huntStarted;
        out->huntRan = true;
        out->huntNanoseconds =
            static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count());
        if (found && fit.matchedNodes == 0x7FF) {
            observeWithFit(s, luma, fit, &s.candidate, s.candidateInk);
            if (s.candidate.state == GC_STATE_NO_STROKE) {
                s.hasCalibration = true;
                s.calibration = fit;
                s.hasValidatedAt = true;
                s.validatedAt = time;
                out->observation = s.candidate;
                out->hasObservation = true;
                std::swap(s.ink, s.candidateInk);
            }
        }
    }
    report();
}

extern "C" void gc_session_observe_with_fit(gc_session *session, gc_gray_image luma, const gc_fit *fit,
                                            gc_observation *out) {
    if (out == nullptr) return;
    if (session == nullptr || fit == nullptr) {
        clearObservation(out, GC_STATE_CALIBRATION_UNAVAILABLE);
        return;
    }
    observeWithFit(*session, luma, *fit, out, session->ink);
}

extern "C" const int32_t *gc_session_ink_pixels(const gc_session *session, int32_t *count) {
    if (session == nullptr) {
        if (count != nullptr) *count = 0;
        return nullptr;
    }
    if (count != nullptr) *count = static_cast<int32_t>(session->ink.size());
    return session->ink.empty() ? nullptr : session->ink.data();
}
