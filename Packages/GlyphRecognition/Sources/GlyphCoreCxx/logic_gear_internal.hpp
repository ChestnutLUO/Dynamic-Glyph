#ifndef LOGIC_GEAR_INTERNAL_HPP
#define LOGIC_GEAR_INTERNAL_HPP

/*
 * Shared between logic_gear.cpp and logic_gear_text.cpp: the gear value
 * types as C++ values, and their conversion to and from the ABI structs.
 * Not part of the ABI.
 */

#include "glyph_logic_gear.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace glyphgear {

inline std::string toString(gc_string text) {
    if (text.bytes == nullptr || text.length <= 0) return std::string();
    return std::string(text.bytes, static_cast<size_t>(text.length));
}

inline gc_string view(const std::string &text) {
    return gc_string{text.data(), static_cast<int32_t>(text.size())};
}

/** `GearDropEntry`. */
struct Entry {
    int32_t column = 0;
    int32_t row = 0;
    std::optional<std::string> item;
    gl_gear_level levelState = GL_GEAR_LEVEL_UNREADABLE;
    std::optional<int32_t> level;
    int64_t quantity = 0;
    gl_gear_rarity rarity = GL_GEAR_RARITY_NONE;
    std::optional<bool> multiplied;

    int64_t position() const { return static_cast<int64_t>(row) * 2 + column; }
    bool operator==(const Entry &other) const {
        return column == other.column && row == other.row && item == other.item &&
               levelState == other.levelState && level == other.level && quantity == other.quantity &&
               rarity == other.rarity && multiplied == other.multiplied;
    }
    bool operator!=(const Entry &other) const { return !(*this == other); }

    Entry withRarity(gl_gear_rarity value) const {
        Entry copy = *this;
        copy.rarity = value;
        return copy;
    }
    Entry withMultiplied(std::optional<bool> value) const {
        Entry copy = *this;
        copy.multiplied = value;
        return copy;
    }
    bool hasRarityMeter() const;
    gl_gear_rarity intrinsicRarity() const;
    /** `refines(_:)`, in GearDropTracker.swift. */
    bool refines(const Entry &other) const;
    /** `contradicts(_:)`, in GearDropTracker.swift. */
    bool contradicts(const Entry &other) const;
    /** `generalizations`, in GearDropTracker.swift. */
    std::vector<Entry> generalizations() const;
};

/** `GearDropSummary.Panel`. */
struct Panel {
    gl_gear_stage stage = GL_GEAR_STAGE_UNKNOWN;
    std::vector<Entry> entries;
    bool partial = false;
    std::optional<std::vector<std::string>> effects;
};

/** `GearDropSummary`. */
struct Summary {
    int64_t groupID = 0;
    double startedAt = 0;
    double closedAt = 0;
    std::string closeReason;
    std::optional<int64_t> hackID;
    gl_gear_association association = GL_GEAR_ASSOCIATION_UNASSOCIATED;
    std::vector<Panel> panels;

    int64_t recognizedQuantity() const;
    int64_t unidentifiedQuantity() const;
    bool panelsReadInFull() const;
    bool bothPanelsRead() const;
};

/** `GearDropFrameEvidence`. */
struct Evidence {
    double sourceTime = 0;
    gl_gear_stage stage = GL_GEAR_STAGE_UNKNOWN;
    std::optional<gc_panel_bounds> bounds;
    std::vector<Entry> entries;
    int32_t unreadableRows = 0;
    std::optional<std::vector<std::string>> effects;
    std::optional<gc_language> titleLanguage;
};

Entry entryFrom(const gl_gear_entry &entry);
Summary summaryFrom(const gl_gear_summary &summary);
Evidence evidenceFrom(const gl_gear_evidence &evidence);

/** Owns the C view of one value until it is replaced: the strings and
 *  arrays the returned struct points into. */
class SummaryExport {
public:
    void fill(Summary value, gl_gear_summary *out);

private:
    Summary held_;
    std::vector<gl_gear_panel> panels_;
    std::vector<gl_gear_entry> entries_;
    std::vector<gc_string> effects_;
};

class EvidenceExport {
public:
    void fill(Evidence value, gl_gear_evidence *out);

private:
    Evidence held_;
    std::vector<gl_gear_entry> entries_;
    std::vector<gc_string> effects_;
};

/** The C view of an entry; its item points into `entry`. */
gl_gear_entry entryView(const Entry &entry);

/* Characters (extended grapheme clusters), in logic_gear_text.cpp. */
std::vector<std::string> graphemes(const std::string &text);
/** `Character.isWhitespace` and `Character.isNumber`: the first scalar's
 *  property. */
bool isWhitespaceCharacter(const std::string &character);
bool isNumberCharacter(const std::string &character);

}  // namespace glyphgear

#endif /* LOGIC_GEAR_INTERNAL_HPP */
