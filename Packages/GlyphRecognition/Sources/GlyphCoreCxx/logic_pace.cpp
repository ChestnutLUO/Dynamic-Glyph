// The gate's pace (AnalysisRateController in AnalysisGate.swift) and the text
// lane (GameTextSchedule.swift), rule for rule. Times are compared exactly as
// the Swift code compares them, so non-finite times behave the same.

#include "glyph_logic_pace.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <new>
#include <vector>

namespace {

constexpr double kInfinity = std::numeric_limits<double>::infinity();

}  // namespace

struct gl_pace {
    gl_pace_policy policy;
    gl_pace_mode mode = GL_PACE_MODE_ACTIVE;
    bool enteredCandidate = false;
    bool switchedScreen = false;
    struct Look {
        double time;
        double mean;
    };
    std::vector<Look> recentMeans;
    double burstUntil = -kInfinity;
    bool hasQuietSince = false;
    double quietSince = 0;
    bool hasReading = false;
    bool lastCandidate = true;
    double lastTime = -kInfinity;

    explicit gl_pace(const gl_pace_policy &policy) : policy(policy) {}

    void reset() {
        mode = GL_PACE_MODE_ACTIVE; hasQuietSince = false; hasReading = false; lastCandidate = true;
        lastTime = -kInfinity; enteredCandidate = false; switchedScreen = false;
        recentMeans.clear(); burstUntil = -kInfinity;
    }

    gl_pace_decision decision(bool inHack, bool constrained) const {
        const bool halved = constrained && !inHack;
        const double interval = mode == GL_PACE_MODE_ACTIVE
            ? (halved ? policy.constrainedActiveInterval : policy.activeInterval)
            : (halved ? policy.constrainedQuietInterval : policy.quietInterval);
        return gl_pace_decision{mode, interval};
    }

    gl_pace_decision pace(double time, bool interesting, bool evidence, bool inHack, bool constrained) {
        if (interesting) {
            hasQuietSince = false;
            mode = GL_PACE_MODE_ACTIVE;
        } else if (evidence || mode != GL_PACE_MODE_ACTIVE) {
            const double since = hasQuietSince ? quietSince : time;
            quietSince = since; hasQuietSince = true;
            if (time - since >= policy.settle) mode = lastCandidate ? GL_PACE_MODE_RESTING : GL_PACE_MODE_QUIET;
        }
        return decision(inHack, constrained);
    }

    gl_pace_decision decide(double time, const gl_pace_gate &gate, bool busy, bool inHack, bool constrained) {
        if (time < lastTime) reset();
        lastTime = time;
        bool entered = false, switched = false;
        if (gate.has) {
            entered = hasReading && !lastCandidate && gate.isCandidate;
            hasReading = true;
            lastCandidate = gate.isCandidate;
            const double mean = gate.meanLuma, window = policy.switchWindow, jump = policy.switchMeanJump;
            recentMeans.erase(std::remove_if(recentMeans.begin(), recentMeans.end(),
                                             [&](const Look &look) { return time - look.time > window; }),
                              recentMeans.end());
            switched = gate.isCandidate && std::any_of(recentMeans.begin(), recentMeans.end(), [&](const Look &look) {
                return std::fabs(look.mean - mean) >= jump;
            });
            if (switched) { recentMeans.clear(); burstUntil = time + policy.switchBurst; }
            recentMeans.push_back(Look{time, mean});
        }
        const gl_pace_decision paced = pace(time, busy || inHack, gate.has, inHack, constrained);
        enteredCandidate = entered && paced.mode != GL_PACE_MODE_ACTIVE;
        switchedScreen = !enteredCandidate && lastCandidate && time < burstUntil && paced.mode != GL_PACE_MODE_ACTIVE;
        if (enteredCandidate || (switchedScreen && switched)) {
            return gl_pace_decision{GL_PACE_MODE_ACTIVE, policy.activeInterval};
        }
        if (switchedScreen) {
            return gl_pace_decision{GL_PACE_MODE_ACTIVE,
                                    constrained && !inHack ? policy.constrainedActiveInterval : policy.activeInterval};
        }
        return paced;
    }

    gl_pace_decision advanceStill(double time, bool busy, bool inHack, bool constrained) {
        enteredCandidate = false; switchedScreen = false;
        if (!std::isfinite(time) || !(time >= lastTime)) return decision(inHack, constrained);
        return pace(time, busy || inHack, hasReading, inHack, constrained);
    }
};

extern "C" {

gl_pace_policy gl_pace_policy_default(void) {
    return gl_pace_policy{0.049, 0.249, 0.099, 0.499, 2.0, 3, 8.0, 0.3, 1.0};
}

gl_pace *gl_pace_create(const gl_pace_policy *policy) {
    return new (std::nothrow) gl_pace(policy ? *policy : gl_pace_policy_default());
}

void gl_pace_destroy(gl_pace *pace) { delete pace; }

void gl_pace_reset(gl_pace *pace) {
    if (pace) pace->reset();
}

gl_pace_decision gl_pace_decide(gl_pace *pace, double time, gl_pace_gate gate, bool busy, bool inHack,
                                bool constrained) {
    if (!pace) return gl_pace_decision{GL_PACE_MODE_ACTIVE, 0};
    return pace->decide(time, gate, busy, inHack, constrained);
}

gl_pace_decision gl_pace_advance_still(gl_pace *pace, double time, bool busy, bool inHack, bool constrained) {
    if (!pace) return gl_pace_decision{GL_PACE_MODE_ACTIVE, 0};
    return pace->advanceStill(time, busy, inHack, constrained);
}

gl_pace_policy gl_pace_get_policy(const gl_pace *pace) { return pace ? pace->policy : gl_pace_policy_default(); }

gl_pace_mode gl_pace_get_mode(const gl_pace *pace) { return pace ? pace->mode : GL_PACE_MODE_ACTIVE; }

bool gl_pace_entered_candidate(const gl_pace *pace) { return pace && pace->enteredCandidate; }

bool gl_pace_switched_screen(const gl_pace *pace) { return pace && pace->switchedScreen; }

gc_opt_double gl_pace_header_interval(gl_pace_mode mode, bool inHack, bool constrained) {
    if (!(mode != GL_PACE_MODE_QUIET || inHack)) return gc_opt_double{false, 0};
    const double interval = inHack ? 0.1 : 0.5;
    return gc_opt_double{true, constrained ? interval * 2 : interval};
}

}  // extern "C"

struct gl_text_schedule {
    bool hasInFlight = false;
    gl_text_schedule_request inFlight{};
    double lastSubmission = -kInfinity;
    int64_t nextID = 0;
    bool resultConfirmed = false;
    bool rejectedCandidate = false;
    int confirmedMisses = 0;
    double lastGearSubmission = -kInfinity;
    int gearMisses = 0;
    bool readsGearPanel = false;
    bool gearGeometryStayed = false;
    double lastPortalSubmission = -kInfinity;
    double lastHeaderSubmission = -kInfinity;
    static constexpr int maximumConfirmedMisses = 3;
    static constexpr double newPanelShift = 0.01;
    static constexpr double stillPanelTolerance = 0.003;
    struct Bounds { double top; double bottom; };
    bool hasObservedGearBounds = false;
    Bounds observedGearBounds{};
    double observedGearTime = -kInfinity;
    bool observedGearStill = false;
    /// `observedGearResting`: this frame's and the previous frame's steps were still.
    bool observedGearResting = false;
    bool hasGearReadBounds = false;
    Bounds gearReadBounds{};
    bool gearReadStill = false;
    bool gearAbsentSinceRead = false;
    bool gearReadProtected = false;
    bool cancelledSinceGearRead = false;
    bool newGearPanel = false;
    bool hasCancelledGearRequest = false;
    gl_text_schedule_request cancelledGearRequest{};
    /// A header take waiting for the caller's `admitsHeader`.
    bool pendingAdmission = false;
    double pendingTime = 0;

    static bool sameRequest(const gl_text_schedule_request &a, const gl_text_schedule_request &b) {
        // Swift compares the requests field for field: a NaN time is never equal.
        return a.id == b.id && a.mode == b.mode && a.sourceTime == b.sourceTime;
    }

    static bool differs(const Bounds &a, const Bounds &b, double tolerance) {
        return std::abs(a.top - b.top) > tolerance || std::abs(a.bottom - b.bottom) > tolerance;
    }

    bool observeGearPanel(bool hasBounds, Bounds bounds, double time, bool previousPanelUnconfirmed,
                          gl_text_schedule_request *out) {
        pendingAdmission = false;
        const bool hadPrevious = hasObservedGearBounds;
        const Bounds previous = observedGearBounds;
        const bool previousStill = observedGearStill;
        hasObservedGearBounds = hasBounds; observedGearBounds = hasBounds ? bounds : Bounds{}; observedGearTime = time;
        if (!hasBounds) {
            observedGearStill = false;
            observedGearResting = false;
            if (hasGearReadBounds) gearAbsentSinceRead = true;
            return false;
        }
        observedGearStill = hadPrevious ? !differs(bounds, previous, stillPanelTolerance) : false;
        observedGearResting = observedGearStill && previousStill;
        if (!hasGearReadBounds) return false;
        const Bounds start = gearReadBounds;
        bool moved;
        if (!gearReadStill && !gearAbsentSinceRead) {
            if (bounds.top - start.top > newPanelShift) {
                moved = true;
            } else {
                if (observedGearResting) { gearReadBounds = bounds; gearReadStill = true; }
                return false;
            }
        } else {
            moved = differs(bounds, start, newPanelShift);
        }
        if (!(moved && gearMisses < 3)) return false;
        hasGearReadBounds = false;
        newGearPanel = true;
        if (!(hasInFlight && inFlight.mode == GL_TEXT_SCHEDULE_MODE_GEAR && !hasCancelledGearRequest
              && !gearReadProtected && !previousPanelUnconfirmed)) {
            return false;
        }
        cancelledGearRequest = inFlight; hasCancelledGearRequest = true;
        cancelledSinceGearRead = true;
        readsGearPanel = false;
        if (out) *out = inFlight;
        return true;
    }

    gl_text_schedule_request submit(double time, gl_text_schedule_mode mode, bool wantsGear, bool wantsPortal) {
        lastSubmission = time; nextID += 1;
        const gl_text_schedule_request request{nextID, mode, time};
        if (wantsGear) {
            lastGearSubmission = time; gearGeometryStayed = true;
            // The geometry this read starts on, if this frame's was observed.
            const bool observed = observedGearTime == time && hasObservedGearBounds;
            hasGearReadBounds = observed; gearReadBounds = observed ? observedGearBounds : Bounds{};
            gearReadStill = observed && observedGearResting;
            gearAbsentSinceRead = false; newGearPanel = false;
            gearReadProtected = cancelledSinceGearRead; cancelledSinceGearRead = false;
        }
        if (wantsPortal) lastPortalSubmission = time;
        if (mode == GL_TEXT_SCHEDULE_MODE_HEADER || mode == GL_TEXT_SCHEDULE_MODE_COMMAND) lastHeaderSubmission = time;
        inFlight = request; hasInFlight = true;
        return request;
    }

    gl_text_schedule_take_status take(const gl_text_schedule_take_args &args, const gl_text_schedule_pace *gearPanelPace,
                                      gl_text_schedule_request *out) {
        pendingAdmission = false;
        const double time = args.time;
        if (!std::isfinite(time)) return GL_TEXT_SCHEDULE_TAKE_NONE;
        if (!args.panelCandidate || !args.resultEligible) {
            resultConfirmed = false; rejectedCandidate = false; confirmedMisses = 0;
        }
        if (!args.gearCandidate) { gearGeometryStayed = false; readsGearPanel = false; }
        if (hasInFlight) return GL_TEXT_SCHEDULE_TAKE_NONE;
        const bool wantsResult = args.resultEligible && args.panelCandidate && (resultConfirmed || !rejectedCandidate);
        if (!args.gearCandidate) gearMisses = 0;
        const bool gearBackedOff = gearMisses >= 3;
        const gl_text_schedule_pace *panelPace = args.gearCandidate && readsGearPanel ? gearPanelPace : nullptr;
        const bool firstOfNewPanel = args.gearCandidate && newGearPanel && !gearBackedOff;
        const double gearSpacing = firstOfNewPanel ? 0
            : gearBackedOff ? std::max(1.0, args.gearInterval)
            : panelPace ? panelPace->gearInterval : args.gearInterval;
        const bool wantsGear = args.gearCandidate && !args.headerPriority && !wantsResult
            && time - lastGearSubmission >= gearSpacing - 0.002;
        const bool wantsPortal = args.portalCandidate && !args.headerPriority && !wantsResult && !wantsGear
            && time - lastPortalSubmission >= 0.2 - 0.002;
        const bool headerWaitsForGear = args.gearCandidate && !args.headerPriority && !gearBackedOff;
        const bool headerDue = args.headerInterval.has
            ? (time < lastHeaderSubmission || time - lastHeaderSubmission >= args.headerInterval.value - 0.002)
            : true;
        if (!((args.readsHeader && headerDue && !headerWaitsForGear) || wantsResult || wantsGear || wantsPortal
              || args.commandCandidate)) {
            return GL_TEXT_SCHEDULE_TAKE_NONE;
        }
        const double tolerance = wantsResult ? 0.002 : 0;
        const double spacing = !wantsResult && wantsGear
            ? (firstOfNewPanel ? 0 : panelPace ? panelPace->minimumInterval : args.minimumInterval)
            : args.minimumInterval;
        if (!(time < lastSubmission || time - lastSubmission >= spacing - tolerance)) {
            return GL_TEXT_SCHEDULE_TAKE_NONE;
        }
        const gl_text_schedule_mode mode = wantsResult ? GL_TEXT_SCHEDULE_MODE_RESULT
            : wantsGear ? GL_TEXT_SCHEDULE_MODE_GEAR
            : wantsPortal ? GL_TEXT_SCHEDULE_MODE_PORTAL
            : args.commandCandidate ? GL_TEXT_SCHEDULE_MODE_COMMAND
            : GL_TEXT_SCHEDULE_MODE_HEADER;
        if (mode == GL_TEXT_SCHEDULE_MODE_HEADER) {
            // A header is neither gear nor portal, so admission needs only the time.
            pendingAdmission = true; pendingTime = time;
            return GL_TEXT_SCHEDULE_TAKE_NEEDS_ADMISSION;
        }
        const gl_text_schedule_request request = submit(time, mode, wantsGear, wantsPortal);
        if (out) *out = request;
        return GL_TEXT_SCHEDULE_TAKE_GRANTED;
    }

    bool admit(bool admitted, gl_text_schedule_request *out) {
        if (!pendingAdmission) return false;
        pendingAdmission = false;
        if (!admitted) return false;
        const gl_text_schedule_request request = submit(pendingTime, GL_TEXT_SCHEDULE_MODE_HEADER, false, false);
        if (out) *out = request;
        return true;
    }

    void finish(const gl_text_schedule_request &request, bool panelPresent, bool untitledPanel) {
        pendingAdmission = false;
        if (!(hasInFlight && sameRequest(inFlight, request))) return;
        hasInFlight = false;
        if (request.mode == GL_TEXT_SCHEDULE_MODE_GEAR && hasCancelledGearRequest
            && sameRequest(request, cancelledGearRequest)) {
            hasCancelledGearRequest = false;
            readsGearPanel = false;
            if (gearMisses > 0) gearMisses = std::min(3, gearMisses + 1);
            return;
        }
        if (request.mode == GL_TEXT_SCHEDULE_MODE_GEAR) {
            if (panelPresent) gearMisses = 0;
            else if (!untitledPanel) gearMisses = std::min(3, gearMisses + 1);
            readsGearPanel = panelPresent && gearGeometryStayed;
            return;
        }
        if (request.mode != GL_TEXT_SCHEDULE_MODE_RESULT) return;
        if (panelPresent) {
            resultConfirmed = true; rejectedCandidate = false; confirmedMisses = 0;
        } else if (resultConfirmed) {
            confirmedMisses += 1;
            if (confirmedMisses >= maximumConfirmedMisses) { resultConfirmed = false; rejectedCandidate = true; }
        } else {
            rejectedCandidate = true;
        }
    }
};

extern "C" {

gl_text_schedule *gl_text_schedule_create(void) { return new (std::nothrow) gl_text_schedule(); }

void gl_text_schedule_destroy(gl_text_schedule *schedule) { delete schedule; }

gl_text_schedule_take_status gl_text_schedule_take(gl_text_schedule *schedule,
                                                   const gl_text_schedule_take_args *args,
                                                   gl_text_schedule_request *out) {
    if (!schedule || !args) return GL_TEXT_SCHEDULE_TAKE_NONE;
    return schedule->take(*args, nullptr, out);
}

gl_text_schedule_take_status gl_text_schedule_take_paced(gl_text_schedule *schedule,
                                                         const gl_text_schedule_take_args *args,
                                                         const gl_text_schedule_pace *gearPanelPace,
                                                         gl_text_schedule_request *out) {
    if (!schedule || !args) return GL_TEXT_SCHEDULE_TAKE_NONE;
    return schedule->take(*args, gearPanelPace, out);
}

bool gl_text_schedule_admit(gl_text_schedule *schedule, bool admitted, gl_text_schedule_request *out) {
    return schedule && schedule->admit(admitted, out);
}

void gl_text_schedule_finish(gl_text_schedule *schedule, gl_text_schedule_request request, bool panelPresent) {
    if (schedule) schedule->finish(request, panelPresent, false);
}

void gl_text_schedule_finish_untitled(gl_text_schedule *schedule, gl_text_schedule_request request,
                                      bool panelPresent, bool untitledPanel) {
    if (schedule) schedule->finish(request, panelPresent, untitledPanel);
}

bool gl_text_schedule_observe_gear_panel(gl_text_schedule *schedule, bool hasBounds, double top, double bottom,
                                         double time, bool previousPanelUnconfirmed,
                                         gl_text_schedule_request *out) {
    return schedule && schedule->observeGearPanel(hasBounds, {top, bottom}, time, previousPanelUnconfirmed, out);
}

bool gl_text_schedule_reads_gear_panel(const gl_text_schedule *schedule) {
    return schedule && schedule->readsGearPanel;
}

bool gl_text_schedule_new_gear_panel(const gl_text_schedule *schedule) {
    return schedule && schedule->newGearPanel;
}

bool gl_text_schedule_cancelled_gear_request(const gl_text_schedule *schedule, gl_text_schedule_request *out) {
    if (!schedule || !schedule->hasCancelledGearRequest) return false;
    if (out) *out = schedule->cancelledGearRequest;
    return true;
}

bool gl_text_schedule_in_flight(const gl_text_schedule *schedule, gl_text_schedule_request *out) {
    if (!schedule || !schedule->hasInFlight) return false;
    if (out) *out = schedule->inFlight;
    return true;
}

}  // extern "C"
