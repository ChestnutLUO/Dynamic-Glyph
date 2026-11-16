// Sequence prediction: SequencePredictor.predict and .outlook over a
// SequenceTable, rule for rule. See glyph_logic_input.h.

#include "glyph_logic_input.h"

#include <algorithm>
#include <cstdint>
#include <new>
#include <string>
#include <vector>

namespace {

/// `SequenceTable.maximumLength`.
constexpr int64_t kMaximumLength = 5;

struct Sequence {
    std::vector<int32_t> glyphs;
    /// `map(\.name).joined(separator: ",")`, the display order's key.
    std::string joinedNames;
};

}  // namespace

struct gl_sequence_predictor {
    std::vector<std::string> names;
    /// Distinct, non-empty, in first-seen order: `SequenceTable.sequences`.
    std::vector<Sequence> sequences;

    // The last outlook's arrays, which the returned struct points into.
    std::vector<int32_t> observedStore;
    std::vector<const Sequence *> shownStore;
    std::vector<gl_sequence_candidate> candidateViews;
    std::vector<int32_t> suffixStore;
    std::vector<std::vector<int32_t>> alternativeStore;
    std::vector<gl_glyph_list> alternativeViews;

    bool hasPrefix(const Sequence &sequence, const int32_t *observed, int32_t count) const {
        if (int64_t(sequence.glyphs.size()) < int64_t(count)) return false;
        for (int32_t i = 0; i < count; ++i) {
            if (observed[i] < 0 || sequence.glyphs[size_t(i)] != observed[i]) return false;
        }
        return true;
    }

    /// `SequenceTable.isComplete`: the observation is itself a sequence.
    bool isComplete(const int32_t *observed, int32_t count) const {
        for (const Sequence &sequence : sequences) {
            if (int64_t(sequence.glyphs.size()) == int64_t(count) && hasPrefix(sequence, observed, count)) return true;
        }
        return false;
    }

    void outlook(const int32_t *observed, int32_t observedCount, bool hasExpectedLength, int64_t expectedLength,
                 int32_t limit, gl_sequence_outlook &out) {
        observedStore.assign(observed, observed + observedCount);

        auto result = [&](gl_prediction_state state, const std::vector<const Sequence *> &matches,
                          bool mayBeComplete) {
            const double weight = matches.empty() ? 0 : 1.0 / double(matches.size());
            const size_t shown = std::min(matches.size(), size_t(limit));
            shownStore.assign(matches.begin(), matches.begin() + std::ptrdiff_t(shown));
            candidateViews.clear();
            for (const Sequence *sequence : shownStore) {
                candidateViews.push_back(gl_sequence_candidate{
                    gl_glyph_list{sequence->glyphs.data(), int32_t(sequence->glyphs.size())}, weight});
            }
            alternativeStore.clear();
            size_t longest = 0;
            for (const Sequence *sequence : matches) longest = std::max(longest, sequence->glyphs.size());
            if (int64_t(longest) > int64_t(observedCount)) {
                for (size_t position = size_t(observedCount); position < longest; ++position) {
                    std::vector<int32_t> choices;
                    for (const Sequence *sequence : matches) {
                        if (sequence->glyphs.size() > position) choices.push_back(sequence->glyphs[position]);
                    }
                    // Distinct Glyphs sorted by name: the vocabulary is name-sorted.
                    std::sort(choices.begin(), choices.end());
                    choices.erase(std::unique(choices.begin(), choices.end()), choices.end());
                    alternativeStore.push_back(std::move(choices));
                }
            }
            alternativeViews.clear();
            for (const std::vector<int32_t> &choices : alternativeStore) {
                alternativeViews.push_back(gl_glyph_list{choices.data(), int32_t(choices.size())});
            }
            suffixStore.clear();
            if (state == GL_PREDICTION_STATE_RESOLVED && matches.size() == 1) {
                const std::vector<int32_t> &glyphs = matches[0]->glyphs;
                if (int64_t(glyphs.size()) > int64_t(observedCount)) {
                    suffixStore.assign(glyphs.begin() + observedCount, glyphs.end());
                }
            }
            out.state = state;
            out.observed = gl_glyph_list{observedStore.data(), int32_t(observedStore.size())};
            out.hasExpectedLength = hasExpectedLength;
            out.expectedLength = hasExpectedLength ? expectedLength : 0;
            out.candidateCount = int64_t(matches.size());
            out.candidates = candidateViews.data();
            out.shownCandidateCount = int32_t(candidateViews.size());
            out.predictedSuffix = gl_glyph_list{suffixStore.data(), int32_t(suffixStore.size())};
            out.suffixAlternatives = alternativeViews.data();
            out.suffixAlternativeCount = int32_t(alternativeViews.size());
            out.observationMayBeComplete = mayBeComplete;
        };
        const std::vector<const Sequence *> none;

        if (hasExpectedLength) {
            // Fewer slots than Glyphs collected, or a count outside what the
            // game presents.
            if (!(expectedLength >= 1 && expectedLength <= kMaximumLength) || expectedLength < int64_t(observedCount)) {
                result(GL_PREDICTION_STATE_LENGTH_CONFLICT, none, false);
                return;
            }
        }

        // `predict(observed:)`: the table's candidates for the prefix, shorter
        // first, then by joined names.
        std::vector<const Sequence *> matches;
        for (const Sequence &sequence : sequences) {
            if (observedCount == 0 || hasPrefix(sequence, observed, observedCount)) matches.push_back(&sequence);
        }
        if (matches.empty() && observedCount > 0) {
            result(GL_PREDICTION_STATE_CONTRADICTED, none, false);
            return;
        }
        std::stable_sort(matches.begin(), matches.end(), [](const Sequence *a, const Sequence *b) {
            if (a->glyphs.size() != b->glyphs.size()) return a->glyphs.size() < b->glyphs.size();
            return a->joinedNames < b->joinedNames;
        });

        if (hasExpectedLength) {
            std::vector<const Sequence *> filtered;
            for (const Sequence *sequence : matches) {
                if (int64_t(sequence->glyphs.size()) == expectedLength) filtered.push_back(sequence);
            }
            matches = std::move(filtered);
            if (matches.empty()) {
                result(GL_PREDICTION_STATE_LENGTH_CONFLICT, none, false);
                return;
            }
        }

        const bool mayBeComplete = isComplete(observed, observedCount) &&
                                   (!hasExpectedLength || expectedLength == int64_t(observedCount));
        if (observedCount == 0) {
            result(GL_PREDICTION_STATE_UNOBSERVED, matches, mayBeComplete);
            return;
        }
        result(matches.size() == 1 ? GL_PREDICTION_STATE_RESOLVED : GL_PREDICTION_STATE_AMBIGUOUS, matches,
               mayBeComplete);
    }
};

extern "C" {

gl_sequence_predictor *gl_sequence_predictor_create(const gc_string *names, int32_t nameCount,
                                                    const int32_t *const *sequences,
                                                    const int32_t *sequenceLengths, int32_t sequenceCount) {
    if (nameCount < 0 || sequenceCount < 0) return nullptr;
    if ((nameCount > 0 && names == nullptr) ||
        (sequenceCount > 0 && (sequences == nullptr || sequenceLengths == nullptr))) {
        return nullptr;
    }
    gl_sequence_predictor *predictor = new (std::nothrow) gl_sequence_predictor();
    if (predictor == nullptr) return nullptr;
    for (int32_t i = 0; i < nameCount; ++i) {
        if (names[i].length < 0 || (names[i].length > 0 && names[i].bytes == nullptr)) {
            delete predictor;
            return nullptr;
        }
        predictor->names.emplace_back(names[i].bytes == nullptr ? "" : std::string(names[i].bytes, size_t(names[i].length)));
    }
    for (int32_t i = 0; i < sequenceCount; ++i) {
        const int32_t length = sequenceLengths[i];
        if (length < 0 || (length > 0 && sequences[i] == nullptr)) {
            delete predictor;
            return nullptr;
        }
        Sequence sequence;
        for (int32_t j = 0; j < length; ++j) {
            const int32_t glyph = sequences[i][j];
            if (glyph < 0 || glyph >= nameCount) {
                delete predictor;
                return nullptr;
            }
            if (j > 0) sequence.joinedNames += ',';
            sequence.joinedNames += predictor->names[size_t(glyph)];
            sequence.glyphs.push_back(glyph);
        }
        if (sequence.glyphs.empty()) continue;
        const bool repeated = std::any_of(predictor->sequences.begin(), predictor->sequences.end(),
                                          [&](const Sequence &seen) { return seen.glyphs == sequence.glyphs; });
        if (!repeated) predictor->sequences.push_back(std::move(sequence));
    }
    return predictor;
}

void gl_sequence_predictor_destroy(gl_sequence_predictor *predictor) { delete predictor; }

bool gl_sequence_predictor_outlook(gl_sequence_predictor *predictor, const int32_t *observed,
                                   int32_t observedCount, bool hasExpectedLength, int64_t expectedLength,
                                   int32_t displayCandidateLimit, gl_sequence_outlook *out) {
    if (predictor == nullptr || out == nullptr || observedCount < 0 || displayCandidateLimit < 0 ||
        (observedCount > 0 && observed == nullptr)) {
        return false;
    }
    predictor->outlook(observed, observedCount, hasExpectedLength, expectedLength, displayCandidateLimit, *out);
    return true;
}

}  // extern "C"
