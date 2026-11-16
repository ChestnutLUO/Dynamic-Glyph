// Command notices: CommandNoticeParser and CommandObservationSession
// (HackCommandSummary.swift), the queue, window and drone-mode logic of
// CommandNoticeCapture (GlyphRecognitionImages/CommandNoticeReader.swift)
// without its pixels, and DroneFooterProbe.matches.
//
// The observation session is a private copy here: the capture's summaries
// come from it, and the results area owns the session's own ABI.

#include "glyph_logic_pace.h"
#include "logic_text_internal.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <limits>
#include <map>
#include <new>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr double kInfinity = std::numeric_limits<double>::infinity();
/// `GameLanguage.english.confidence.clearNotice`.
constexpr double kEnglishClearNotice = 0.95;

std::string copy(gc_string text) {
    if (!text.bytes || text.length <= 0) return std::string();
    return std::string(text.bytes, static_cast<std::size_t>(text.length));
}

gc_string view(const std::string &text) { return gc_string{text.data(), static_cast<int32_t>(text.size())}; }

/// `CommandNoticeReading` with its language owned.
struct Reading {
    gl_game_text_notice_kind notice = GL_GAME_TEXT_NOTICE_NONE;
    double confidence = 0;
    std::optional<std::string> language;
    bool isClear = false;

    static Reading of(const gl_command_parser_reading &read) {
        Reading reading;
        reading.notice = read.notice;
        reading.confidence = read.confidence;
        if (read.hasLanguage) reading.language = copy(read.language);
        reading.isClear = read.isClear;
        return reading;
    }
};

gl_command_capture_command commandOf(gl_game_text_notice_kind notice) {
    switch (notice) {
    case GL_GAME_TEXT_NOTICE_SIMPLE: return GL_COMMAND_CAPTURE_COMMAND_SIMPLE;
    case GL_GAME_TEXT_NOTICE_COMPLEX: return GL_COMMAND_CAPTURE_COMMAND_COMPLEX;
    case GL_GAME_TEXT_NOTICE_REQUEST_KEY: return GL_COMMAND_CAPTURE_COMMAND_REQUEST_KEY;
    case GL_GAME_TEXT_NOTICE_NO_KEY: return GL_COMMAND_CAPTURE_COMMAND_NO_KEY;
    case GL_GAME_TEXT_NOTICE_KEYS_ONLY: return GL_COMMAND_CAPTURE_COMMAND_KEYS_ONLY;
    default: return GL_COMMAND_CAPTURE_COMMAND_NONE;
    }
}

bool isPresentation(gl_command_capture_command command) {
    return command == GL_COMMAND_CAPTURE_COMMAND_SIMPLE || command == GL_COMMAND_CAPTURE_COMMAND_COMPLEX;
}

struct Selection {
    gl_command_capture_status status = GL_COMMAND_CAPTURE_STATUS_NO_COMMAND_OBSERVED;
    gl_command_capture_command lastObserved = GL_COMMAND_CAPTURE_COMMAND_NONE;
    int64_t samples = 0;
    std::optional<std::string> language;
};

struct Summary {
    Selection presentation, gear;
    gl_command_capture_window_mode mode = GL_COMMAND_CAPTURE_WINDOW_MODE_UNKNOWN;
};

/// CommandObservationSession.
class ObservationSession {
public:
    int64_t beginNotice(double time) {
        nextID_ += 1;
        if (pending_.events.size() >= 128) { pending_.events.erase(pending_.events.begin()); pending_.lost = true; }
        pending_.events.push_back(Event{nextID_, time, epoch_, {}});
        return nextID_;
    }

    void accept(const Reading &read, int64_t id, double time) {
        if (Event *event = find(pending_, id)) { event->record(time, read); return; }
        for (auto &entry : bound_) {
            if (Event *event = find(entry.second, id)) { event->record(time, read); return; }
        }
    }

    void setMode(gl_command_capture_window_mode mode) { pending_.mode = mode; }
    void markObserved() { pending_.observed = true; }
    void loseCoverage(double time) { beginNotice(time); pending_.observed = true; }
    void beginEpoch(double time) { epoch_ += 1; loseCoverage(time); }
    void cancel() { pending_ = Window(); }

    void bind(int64_t hackID) {
        if (bound_.count(hackID)) return;
        bound_[hackID] = pending_;
        pending_ = Window();
        while (bound_.size() > 8) bound_.erase(bound_.begin());
    }

    Summary summary(int64_t hackID) const {
        const auto found = bound_.find(hackID);
        if (found == bound_.end() || !(found->second.observed || !found->second.events.empty())) {
            Summary unobserved;
            unobserved.presentation.status = GL_COMMAND_CAPTURE_STATUS_UNRESOLVED;
            unobserved.gear.status = GL_COMMAND_CAPTURE_STATUS_UNRESOLVED;
            if (found != bound_.end() && found->second.mode == GL_COMMAND_CAPTURE_WINDOW_MODE_DRONE) {
                unobserved.mode = GL_COMMAND_CAPTURE_WINDOW_MODE_DRONE;
                unobserved.gear.status = GL_COMMAND_CAPTURE_STATUS_NOT_APPLICABLE;
            }
            return unobserved;
        }
        const Window &window = found->second;
        Summary summary;
        summary.mode = window.mode;
        if (window.lost) {
            summary.presentation.status = GL_COMMAND_CAPTURE_STATUS_UNRESOLVED;
            summary.gear.status = GL_COMMAND_CAPTURE_STATUS_UNRESOLVED;
        }
        std::vector<const Event *> events;
        for (const Event &event : window.events) events.push_back(&event);
        std::sort(events.begin(), events.end(), [](const Event *a, const Event *b) {
            if (a->epoch != b->epoch) return a->epoch < b->epoch;
            if (a->time != b->time) return a->time < b->time;
            return a->id < b->id;
        });
        for (const Event *event : events) {
            // Swift takes the readable reads in its dictionary's order, which
            // is unspecified; here they are in the order they first came.
            std::vector<const Reading *> reads;
            for (const auto &entry : event->reads) {
                if (entry.second.notice != GL_GAME_TEXT_NOTICE_NONE) reads.push_back(&entry.second);
            }
            bool oneNotice = !reads.empty(), anyClear = false;
            for (const Reading *read : reads) {
                oneNotice = oneNotice && read->notice == reads.front()->notice;
                anyClear = anyClear || read->isClear;
            }
            if (!(oneNotice && (reads.size() >= 2 || anyClear))) {
                summary.presentation.status = GL_COMMAND_CAPTURE_STATUS_UNRESOLVED;
                summary.gear.status = GL_COMMAND_CAPTURE_STATUS_UNRESOLVED;
                continue;
            }
            const gl_command_capture_command command = commandOf(reads.front()->notice);
            if (command == GL_COMMAND_CAPTURE_COMMAND_NONE) continue;
            Selection selection;
            selection.status = GL_COMMAND_CAPTURE_STATUS_CONFIRMED;
            selection.lastObserved = command;
            selection.samples = static_cast<int64_t>(reads.size());
            selection.language = reads.front()->language;
            if (isPresentation(command)) summary.presentation = selection; else summary.gear = selection;
        }
        if (summary.mode == GL_COMMAND_CAPTURE_WINDOW_MODE_DRONE) {
            summary.gear.status = GL_COMMAND_CAPTURE_STATUS_NOT_APPLICABLE;
        }
        return summary;
    }

private:
    struct Event {
        int64_t id;
        double time;
        int64_t epoch;
        // Keyed by source time, as Swift's dictionary: a read at an equal
        // time replaces the earlier one (a NaN time equals none).
        std::vector<std::pair<double, Reading>> reads;

        void record(double readTime, const Reading &read) {
            for (auto &entry : reads) {
                if (entry.first == readTime) { entry.second = read; return; }
            }
            reads.emplace_back(readTime, read);
        }
    };
    struct Window {
        std::vector<Event> events;
        gl_command_capture_window_mode mode = GL_COMMAND_CAPTURE_WINDOW_MODE_UNKNOWN;
        bool lost = false;
        bool observed = false;
    };

    static Event *find(Window &window, int64_t id) {
        for (Event &event : window.events) {
            if (event.id == id) return &event;
        }
        return nullptr;
    }

    int64_t nextID_ = 0;
    int64_t epoch_ = 0;
    Window pending_;
    std::map<int64_t, Window> bound_;
};

/// `DroneFooterProbe.signatureTolerance`.
constexpr int kSignatureTolerance = 10;

bool signaturesMatch(const std::vector<uint8_t> &signature, const std::vector<uint8_t> &known) {
    if (signature.size() != known.size()) return false;
    int differing = 0;
    for (std::size_t index = 0; index < signature.size(); ++index) differing += signature[index] == known[index] ? 0 : 1;
    return differing <= kSignatureTolerance;
}

std::vector<uint8_t> bytes(const uint8_t *data, int32_t count) {
    if (!data || count <= 0) return {};
    return std::vector<uint8_t>(data, data + count);
}

}  // namespace

/* Parser ------------------------------------------------------------------ */

struct gl_command_parser {
    glyph_text::GameTextMatcher text;
    explicit gl_command_parser(glyph_text::GameTextMatcher text) : text(std::move(text)) {}
};

extern "C" {

gl_command_parser *gl_command_parser_create(const gl_game_text *text) {
    if (!text) return nullptr;
    try {
        return new gl_command_parser(text->matcher);
    } catch (...) {
        return nullptr;
    }
}

void gl_command_parser_destroy(gl_command_parser *parser) { delete parser; }

gl_command_parser_reading gl_command_parser_read(const gl_command_parser *parser,
                                                 const gl_command_parser_line *lines, int32_t count) {
    gl_command_parser_reading reading{GL_GAME_TEXT_NOTICE_NONE, 0, false, gc_string{nullptr, 0}, false};
    if (!parser) return reading;
    const bool english = parser->text.language() == GC_LANGUAGE_ENGLISH;
    const double noticeFloor = english ? 0.8 : 0.5, clearFloor = english ? kEnglishClearNotice : 0.5;
    if (count != 1 || !lines || !(lines[0].confidence >= noticeFloor)) return reading;
    const double confidence = lines[0].confidence;
    gl_game_text_notice_kind notice = GL_GAME_TEXT_NOTICE_NONE;
    const glyph_text::GameTextMatcher::Pack *pack = parser->text.notice(glyph_text::decode(lines[0].text), notice);
    reading.confidence = confidence;
    if (!pack) {
        reading.isClear = confidence >= kEnglishClearNotice;
        return reading;
    }
    const double clear = pack->code == "en" ? kEnglishClearNotice : clearFloor;
    reading.notice = notice;
    reading.hasLanguage = true;
    reading.language = view(pack->code);
    reading.isClear = confidence >= clear;
    return reading;
}

}  // extern "C"

/* Capture ----------------------------------------------------------------- */

struct gl_command_capture {
    struct Frame {
        int64_t id;
        double sourceTime;
        int64_t imageToken;
        bool isMode;
        int64_t generation;
        std::optional<std::vector<uint8_t>> signature;
    };
    struct Box {
        double width;
        std::vector<uint8_t> signature;
    };

    ObservationSession observer;
    std::deque<Frame> queue;
    std::optional<Box> box;
    std::optional<int64_t> noticeID;
    int samples = 0;
    double lastSampleTime = -kInfinity;
    std::vector<int64_t> dropped;
    double lastFrameTime = -kInfinity;
    bool missing = false;
    std::optional<double> droneAt;
    double lastModeProbe = -kInfinity;
    std::optional<std::vector<uint8_t>> droneSignature;
    int64_t modeCandidates = 0, modeReads = 0, modeReuses = 0;
    bool windowOpened = false;
    std::optional<double> windowStartedAt;
    int64_t generation = 0;
    int64_t minimumGeneration = 0;
    /// `noticeReadAt`: the latest notice crop read with a value in the open window.
    std::optional<double> noticeReadAt;

    // Storage for what the ABI returns, valid until the next call.
    std::vector<gl_command_capture_frame> frameViews;
    std::vector<int64_t> droppedView;
    Frame takenFrame{};
    std::string presentationLanguage, gearLanguage;

    void cancel() {
        observer.cancel(); queue.clear(); box.reset(); noticeID.reset(); samples = 0; dropped.clear();
        missing = false; windowOpened = false; windowStartedAt.reset(); droneAt.reset();
        generation += 1; lastFrameTime = -kInfinity; lastModeProbe = -kInfinity; noticeReadAt.reset();
    }

    bool beginFrame(double time) {
        if (!std::isfinite(time) || time == lastFrameTime) return false;
        if (time < lastFrameTime) cancel();
        lastFrameTime = time;
        if (!windowOpened) {
            if (droneAt && time >= *droneAt && time - *droneAt <= 5) observer.setMode(GL_COMMAND_CAPTURE_WINDOW_MODE_DRONE);
            droneAt.reset(); windowOpened = true; windowStartedAt = time;
            observer.markObserved();
        }
        return true;
    }

    bool observeBox(double time, const gl_command_capture_box *current, bool obscured) {
        if (!current) {
            box.reset(); noticeID.reset(); samples = 0;
            if (obscured) {
                if (!missing) { observer.loseCoverage(time); missing = true; }
            } else {
                missing = false;
            }
            return false;
        }
        missing = false;
        Box next{current->width, bytes(current->signature, current->signatureCount)};
        int64_t difference = std::numeric_limits<int64_t>::max();
        if (box) {
            difference = 0;
            const std::size_t shared = std::min(box->signature.size(), next.signature.size());
            for (std::size_t index = 0; index < shared; ++index) difference += box->signature[index] != next.signature[index];
        }
        if (!box || difference > 35 || std::fabs((box ? box->width : 0) - next.width) > 3) {
            noticeID = observer.beginNotice(time); samples = 0; box = std::move(next);
        }
        return samples < 2 && (samples == 0 || time - lastSampleTime >= 0.045) && noticeID.has_value();
    }

    void addSample(double time, int64_t token) {
        if (!noticeID) return;
        samples += 1; lastSampleTime = time;
        if (queue.size() >= 16) queue.pop_front();
        queue.push_back(Frame{*noticeID, time, token, false, generation, std::nullopt});
    }

    bool modeProbeDue(double time, bool panelShowing) const {
        return !windowOpened && !panelShowing && time - lastModeProbe >= 1;
    }

    gl_command_capture_footer modeCandidate(double time, const std::vector<uint8_t> &signature) {
        modeCandidates += 1;
        if (droneSignature && signaturesMatch(signature, *droneSignature)) {
            lastModeProbe = time;
            modeReuses += 1;
            droneAt = time;
            return GL_COMMAND_CAPTURE_FOOTER_REUSED;
        }
        return queue.size() < 16 ? GL_COMMAND_CAPTURE_FOOTER_READ : GL_COMMAND_CAPTURE_FOOTER_QUEUE_FULL;
    }

    void addModeRead(double time, std::vector<uint8_t> signature, int64_t token) {
        lastModeProbe = time;
        modeReads += 1;
        queue.push_back(Frame{0, time, token, true, generation, std::move(signature)});
    }

    bool take(double time, Frame &out) {
        const auto expired = [time](const Frame &frame) {
            return time < frame.sourceTime || time - frame.sourceTime > 1;
        };
        for (const Frame &frame : queue) {
            if (!frame.isMode && expired(frame)) dropped.push_back(frame.id);
        }
        queue.erase(std::remove_if(queue.begin(), queue.end(), expired), queue.end());
        if (queue.empty()) return false;
        out = std::move(queue.front());
        queue.pop_front();
        return true;
    }

    void interrupt(double time) {
        if (!windowOpened) return;
        observer.loseCoverage(time);
        box.reset(); noticeID.reset(); samples = 0;
    }

    void invalidateQueue(double time) {
        if (windowOpened) observer.beginEpoch(time);
        generation += 1;
        minimumGeneration = generation;
        queue.clear(); box.reset(); noticeID.reset(); samples = 0; dropped.clear();
        lastFrameTime = -kInfinity; lastSampleTime = -kInfinity;
        lastModeProbe = -kInfinity; droneAt.reset();
        missing = false; noticeReadAt.reset();
    }

    void accept(const Reading &read, const gl_command_capture_frame &frame) {
        if (frame.generation < minimumGeneration) return;
        if (frame.isMode) {
            if (read.notice == GL_GAME_TEXT_NOTICE_DRONE && frame.hasSignature) {
                droneSignature = bytes(frame.signature, frame.signatureCount);
            }
            if (frame.generation != generation) return;
            if (read.notice == GL_GAME_TEXT_NOTICE_DRONE) {
                if (windowStartedAt && frame.sourceTime <= *windowStartedAt && *windowStartedAt - frame.sourceTime <= 5) {
                    observer.setMode(GL_COMMAND_CAPTURE_WINDOW_MODE_DRONE);
                } else if (!windowOpened) {
                    droneAt = frame.sourceTime;
                }
            }
            return;
        }
        if (read.notice != GL_GAME_TEXT_NOTICE_NONE && frame.generation == generation) {
            const double base = noticeReadAt.value_or(frame.sourceTime);
            noticeReadAt = frame.sourceTime >= base ? frame.sourceTime : base;
        }
        observer.accept(read, frame.id, frame.sourceTime);
    }

    void bind(int64_t hackID) {
        observer.bind(hackID);
        generation += 1; box.reset(); noticeID.reset(); samples = 0;
        windowOpened = false; windowStartedAt.reset(); droneAt.reset(); noticeReadAt.reset();
    }

    static gl_command_capture_frame view(const Frame &frame) {
        gl_command_capture_frame out{};
        out.id = frame.id;
        out.sourceTime = frame.sourceTime;
        out.imageToken = frame.imageToken;
        out.isMode = frame.isMode;
        out.generation = frame.generation;
        out.hasSignature = frame.signature.has_value();
        out.signature = frame.signature ? frame.signature->data() : nullptr;
        out.signatureCount = frame.signature ? static_cast<int32_t>(frame.signature->size()) : 0;
        return out;
    }
};

namespace {

gl_command_capture_selection selectionView(const Selection &selection, std::string &storage) {
    gl_command_capture_selection out{};
    out.status = selection.status;
    out.lastObserved = selection.lastObserved;
    out.samples = selection.samples;
    out.hasLanguage = selection.language.has_value();
    storage = selection.language.value_or(std::string());
    out.language = out.hasLanguage ? view(storage) : gc_string{nullptr, 0};
    return out;
}

}  // namespace

extern "C" {

gl_command_capture *gl_command_capture_create(void) { return new (std::nothrow) gl_command_capture(); }

void gl_command_capture_destroy(gl_command_capture *capture) { delete capture; }

bool gl_command_capture_begin_frame(gl_command_capture *capture, double time) {
    return capture && capture->beginFrame(time);
}

bool gl_command_capture_observe_box(gl_command_capture *capture, double time, const gl_command_capture_box *box,
                                    bool obscured) {
    return capture && capture->observeBox(time, box, obscured);
}

void gl_command_capture_add_sample(gl_command_capture *capture, double time, int64_t imageToken) {
    if (capture) capture->addSample(time, imageToken);
}

bool gl_command_capture_mode_probe_due(gl_command_capture *capture, double time, bool panelShowing) {
    return capture && capture->modeProbeDue(time, panelShowing);
}

gl_command_capture_footer gl_command_capture_mode_candidate(gl_command_capture *capture, double time,
                                                            const uint8_t *signature, int32_t signatureCount) {
    if (!capture) return GL_COMMAND_CAPTURE_FOOTER_QUEUE_FULL;
    return capture->modeCandidate(time, bytes(signature, signatureCount));
}

void gl_command_capture_add_mode_read(gl_command_capture *capture, double time, const uint8_t *signature,
                                      int32_t signatureCount, int64_t imageToken) {
    if (capture) capture->addModeRead(time, bytes(signature, signatureCount), imageToken);
}

bool gl_command_capture_take(gl_command_capture *capture, double time, gl_command_capture_frame *out) {
    if (!capture || !capture->take(time, capture->takenFrame)) return false;
    if (out) *out = gl_command_capture::view(capture->takenFrame);
    return true;
}

int32_t gl_command_capture_take_dropped(gl_command_capture *capture, const int64_t **ids) {
    if (!capture) return 0;
    capture->droppedView = std::move(capture->dropped);
    capture->dropped.clear();
    if (ids) *ids = capture->droppedView.data();
    return static_cast<int32_t>(capture->droppedView.size());
}

void gl_command_capture_interrupt(gl_command_capture *capture, double time) {
    if (capture) capture->interrupt(time);
}

void gl_command_capture_invalidate_queue(gl_command_capture *capture, double time) {
    if (capture) capture->invalidateQueue(time);
}

void gl_command_capture_accept(gl_command_capture *capture, gl_command_parser_reading read,
                               const gl_command_capture_frame *frame) {
    if (capture && frame) capture->accept(Reading::of(read), *frame);
}

void gl_command_capture_bind(gl_command_capture *capture, int64_t hackID) {
    if (capture) capture->bind(hackID);
}

void gl_command_capture_cancel(gl_command_capture *capture) {
    if (capture) capture->cancel();
}

gl_command_capture_hack_summary gl_command_capture_summary(gl_command_capture *capture, int64_t hackID) {
    gl_command_capture_hack_summary out{};
    if (!capture) return out;
    const Summary summary = capture->observer.summary(hackID);
    out.presentation = selectionView(summary.presentation, capture->presentationLanguage);
    out.gear = selectionView(summary.gear, capture->gearLanguage);
    out.mode = summary.mode;
    return out;
}

bool gl_command_capture_notice_read_at(const gl_command_capture *capture, double *out) {
    if (!capture || !capture->noticeReadAt) return false;
    if (out) *out = *capture->noticeReadAt;
    return true;
}

bool gl_command_capture_shows_notice(const gl_command_capture *capture) {
    return capture && capture->box.has_value();
}

int32_t gl_command_capture_queue(gl_command_capture *capture, const gl_command_capture_frame **frames) {
    if (!capture) return 0;
    capture->frameViews.clear();
    for (const auto &frame : capture->queue) capture->frameViews.push_back(gl_command_capture::view(frame));
    if (frames) *frames = capture->frameViews.data();
    return static_cast<int32_t>(capture->frameViews.size());
}

int64_t gl_command_capture_mode_candidates(const gl_command_capture *capture) {
    return capture ? capture->modeCandidates : 0;
}

int64_t gl_command_capture_mode_reads(const gl_command_capture *capture) { return capture ? capture->modeReads : 0; }

int64_t gl_command_capture_mode_reuses(const gl_command_capture *capture) { return capture ? capture->modeReuses : 0; }

bool gl_command_capture_footer_signatures_match(const uint8_t *signature, int32_t signatureCount,
                                                const uint8_t *known, int32_t knownCount) {
    return signaturesMatch(bytes(signature, signatureCount), bytes(known, knownCount));
}

}  // extern "C"
