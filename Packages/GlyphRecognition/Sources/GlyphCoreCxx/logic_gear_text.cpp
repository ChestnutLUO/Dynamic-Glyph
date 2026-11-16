/*
 * The gear text parser (GearDropTextParser.swift) and the parts of GameText
 * it calls: title(_:), effect(_:), item(named:clipped:) and
 * bonusTitleLanguage(_:), over the phrase tables Swift hands over at
 * creation. Swift works on Characters (extended grapheme clusters); so does
 * this file, with a segmentation built from tables generated from Swift's
 * own Unicode properties (see the comment above them).
 */

#include "logic_gear_internal.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <map>
#include <set>
#include <unordered_map>
#include <utility>

#pragma clang fp contract(off)

namespace glyphgear {

namespace {

struct ScalarRange {
    uint32_t first;
    uint32_t last;
};

/*
 * Generated on macOS 27 by iterating every Unicode scalar in Swift:
 * - kNumberRanges: `properties.numericType != nil`, which is what
 *   `Character.isNumber` tests on a Character's first scalar;
 * - kWhitespaceRanges: `properties.isWhitespace` (`Character.isWhitespace`);
 * - kTrimWhitespaceRanges: `CharacterSet.whitespaces`, which
 *   `trimmingCharacters(in: .whitespaces)` removes scalar by scalar;
 * - kGraphemeExtendRanges: the scalars `s` for which `"a" + s` is one
 *   Character (Extend, ZWJ and SpacingMark).
 * The generator checked `Character(s).isNumber` and `isWhitespace` against
 * the first two tables for every scalar, with no mismatch.
 */
static const ScalarRange kNumberRanges[] = {
    {0x30, 0x39}, {0xB2, 0xB3}, {0xB9, 0xB9}, {0xBC, 0xBE}, {0x660, 0x669}, {0x6F0, 0x6F9},
    {0x7C0, 0x7C9}, {0x966, 0x96F}, {0x9E6, 0x9EF}, {0x9F4, 0x9F9}, {0xA66, 0xA6F}, {0xAE6, 0xAEF},
    {0xB66, 0xB6F}, {0xB72, 0xB77}, {0xBE6, 0xBF2}, {0xC66, 0xC6F}, {0xC78, 0xC7E}, {0xCE6, 0xCEF},
    {0xD58, 0xD5E}, {0xD66, 0xD78}, {0xDE6, 0xDEF}, {0xE50, 0xE59}, {0xED0, 0xED9}, {0xF20, 0xF33},
    {0x1040, 0x1049}, {0x1090, 0x1099}, {0x1369, 0x137C}, {0x16EE, 0x16F0}, {0x17E0, 0x17E9},
    {0x17F0, 0x17F9}, {0x1810, 0x1819}, {0x1946, 0x194F}, {0x19D0, 0x19DA}, {0x1A80, 0x1A89},
    {0x1A90, 0x1A99}, {0x1B50, 0x1B59}, {0x1BB0, 0x1BB9}, {0x1C40, 0x1C49}, {0x1C50, 0x1C59},
    {0x2070, 0x2070}, {0x2074, 0x2079}, {0x2080, 0x2089}, {0x2150, 0x2182}, {0x2185, 0x2189},
    {0x2460, 0x249B}, {0x24EA, 0x24FF}, {0x2776, 0x2793}, {0x2CFD, 0x2CFD}, {0x3007, 0x3007},
    {0x3021, 0x3029}, {0x3038, 0x303A}, {0x3192, 0x3195}, {0x3220, 0x3229}, {0x3248, 0x324F},
    {0x3251, 0x325F}, {0x3280, 0x3289}, {0x32B1, 0x32BF}, {0x3405, 0x3405}, {0x3483, 0x3483},
    {0x382A, 0x382A}, {0x3B4D, 0x3B4D}, {0x4E00, 0x4E00}, {0x4E03, 0x4E03}, {0x4E07, 0x4E07},
    {0x4E09, 0x4E09}, {0x4E24, 0x4E24}, {0x4E5D, 0x4E5D}, {0x4E8C, 0x4E8C}, {0x4E94, 0x4E94},
    {0x4E96, 0x4E96}, {0x4EAC, 0x4EAC}, {0x4EBF, 0x4EC0}, {0x4EDF, 0x4EDF}, {0x4EE8, 0x4EE8},
    {0x4F0D, 0x4F0D}, {0x4F70, 0x4F70}, {0x4FE9, 0x4FE9}, {0x5006, 0x5006}, {0x5104, 0x5104},
    {0x5146, 0x5146}, {0x5169, 0x5169}, {0x516B, 0x516B}, {0x516D, 0x516D}, {0x5341, 0x5341},
    {0x5343, 0x5345}, {0x534C, 0x534C}, {0x53C1, 0x53C4}, {0x56DB, 0x56DB}, {0x58F1, 0x58F1},
    {0x58F9, 0x58F9}, {0x5E7A, 0x5E7A}, {0x5EFE, 0x5EFF}, {0x5F0C, 0x5F0E}, {0x5F10, 0x5F10},
    {0x62D0, 0x62D0}, {0x62FE, 0x62FE}, {0x634C, 0x634C}, {0x67D2, 0x67D2}, {0x6D1E, 0x6D1E},
    {0x6F06, 0x6F06}, {0x7396, 0x7396}, {0x767E, 0x767E}, {0x7695, 0x7695}, {0x79ED, 0x79ED},
    {0x8086, 0x8086}, {0x842C, 0x842C}, {0x8CAE, 0x8CAE}, {0x8CB3, 0x8CB3}, {0x8D30, 0x8D30},
    {0x920E, 0x920E}, {0x94A9, 0x94A9}, {0x9621, 0x9621}, {0x9646, 0x9646}, {0x964C, 0x964C},
    {0x9678, 0x9678}, {0x96F6, 0x96F6}, {0xA620, 0xA629}, {0xA6E6, 0xA6EF}, {0xA830, 0xA835},
    {0xA8D0, 0xA8D9}, {0xA900, 0xA909}, {0xA9D0, 0xA9D9}, {0xA9F0, 0xA9F9}, {0xAA50, 0xAA59},
    {0xABF0, 0xABF9}, {0xF96B, 0xF96B}, {0xF973, 0xF973}, {0xF978, 0xF978}, {0xF9B2, 0xF9B2},
    {0xF9D1, 0xF9D1}, {0xF9D3, 0xF9D3}, {0xF9FD, 0xF9FD}, {0xFF10, 0xFF19}, {0x10107, 0x10133},
    {0x10140, 0x10178}, {0x1018A, 0x1018B}, {0x102E1, 0x102FB}, {0x10320, 0x10323},
    {0x10341, 0x10341}, {0x1034A, 0x1034A}, {0x103D1, 0x103D5}, {0x104A0, 0x104A9},
    {0x10858, 0x1085F}, {0x10879, 0x1087F}, {0x108A7, 0x108AF}, {0x108FB, 0x108FF},
    {0x10916, 0x1091B}, {0x109BC, 0x109BD}, {0x109C0, 0x109CF}, {0x109D2, 0x109FF},
    {0x10A40, 0x10A48}, {0x10A7D, 0x10A7E}, {0x10A9D, 0x10A9F}, {0x10AEB, 0x10AEF},
    {0x10B58, 0x10B5F}, {0x10B78, 0x10B7F}, {0x10BA9, 0x10BAF}, {0x10CFA, 0x10CFF},
    {0x10D30, 0x10D39}, {0x10D40, 0x10D49}, {0x10E60, 0x10E7E}, {0x10F1D, 0x10F26},
    {0x10F51, 0x10F54}, {0x10FC5, 0x10FCB}, {0x11052, 0x1106F}, {0x110F0, 0x110F9},
    {0x11136, 0x1113F}, {0x111D0, 0x111D9}, {0x111E1, 0x111F4}, {0x112F0, 0x112F9},
    {0x11450, 0x11459}, {0x114D0, 0x114D9}, {0x11650, 0x11659}, {0x116C0, 0x116C9},
    {0x116D0, 0x116E3}, {0x11730, 0x1173B}, {0x118E0, 0x118F2}, {0x11950, 0x11959},
    {0x11BF0, 0x11BF9}, {0x11C50, 0x11C6C}, {0x11D50, 0x11D59}, {0x11DA0, 0x11DA9},
    {0x11DE0, 0x11DE9}, {0x11F50, 0x11F59}, {0x11FC0, 0x11FD4}, {0x12038, 0x12039},
    {0x12079, 0x12079}, {0x12226, 0x12226}, {0x1222B, 0x1222B}, {0x1230B, 0x1230B},
    {0x1230D, 0x1230D}, {0x12399, 0x12399}, {0x12400, 0x1246E}, {0x16130, 0x16139},
    {0x16A60, 0x16A69}, {0x16AC0, 0x16AC9}, {0x16B50, 0x16B59}, {0x16B5B, 0x16B61},
    {0x16D70, 0x16D79}, {0x16E80, 0x16E96}, {0x16FF4, 0x16FF6}, {0x1CCF0, 0x1CCF9},
    {0x1D2C0, 0x1D2D3}, {0x1D2E0, 0x1D2F3}, {0x1D360, 0x1D378}, {0x1D7CE, 0x1D7FF},
    {0x1E140, 0x1E149}, {0x1E2F0, 0x1E2F9}, {0x1E4F0, 0x1E4F9}, {0x1E5F1, 0x1E5FA},
    {0x1E8C7, 0x1E8CF}, {0x1E950, 0x1E959}, {0x1EC71, 0x1ECAB}, {0x1ECAD, 0x1ECAF},
    {0x1ECB1, 0x1ECB4}, {0x1ED01, 0x1ED2D}, {0x1ED2F, 0x1ED3D}, {0x1F100, 0x1F10C},
    {0x1FBF0, 0x1FBF9}, {0x20001, 0x20001}, {0x20064, 0x20064}, {0x200E2, 0x200E2},
    {0x20121, 0x20121}, {0x2092A, 0x2092A}, {0x20983, 0x20983}, {0x2098C, 0x2098C},
    {0x2099C, 0x2099C}, {0x20AEA, 0x20AEA}, {0x20AFD, 0x20AFD}, {0x20B19, 0x20B19},
    {0x22390, 0x22390}, {0x22998, 0x22998}, {0x23B1B, 0x23B1B}, {0x2626D, 0x2626D},
    {0x2F890, 0x2F890},
};
static const ScalarRange kWhitespaceRanges[] = {
    {0x9, 0xD}, {0x20, 0x20}, {0x85, 0x85}, {0xA0, 0xA0}, {0x1680, 0x1680}, {0x2000, 0x200A},
    {0x2028, 0x2029}, {0x202F, 0x202F}, {0x205F, 0x205F}, {0x3000, 0x3000},
};
static const ScalarRange kTrimWhitespaceRanges[] = {
    {0x9, 0x9}, {0x20, 0x20}, {0xA0, 0xA0}, {0x1680, 0x1680}, {0x2000, 0x200B}, {0x202F, 0x202F},
    {0x205F, 0x205F}, {0x3000, 0x3000},
};
static const ScalarRange kGraphemeExtendRanges[] = {
    {0x300, 0x36F}, {0x483, 0x489}, {0x591, 0x5BD}, {0x5BF, 0x5BF}, {0x5C1, 0x5C2}, {0x5C4, 0x5C5},
    {0x5C7, 0x5C7}, {0x610, 0x61A}, {0x64B, 0x65F}, {0x670, 0x670}, {0x6D6, 0x6DC}, {0x6DF, 0x6E4},
    {0x6E7, 0x6E8}, {0x6EA, 0x6ED}, {0x711, 0x711}, {0x730, 0x74A}, {0x7A6, 0x7B0}, {0x7EB, 0x7F3},
    {0x7FD, 0x7FD}, {0x816, 0x819}, {0x81B, 0x823}, {0x825, 0x827}, {0x829, 0x82D}, {0x859, 0x85B},
    {0x897, 0x89F}, {0x8CA, 0x8E1}, {0x8E3, 0x903}, {0x93A, 0x93C}, {0x93E, 0x94F}, {0x951, 0x957},
    {0x962, 0x963}, {0x981, 0x983}, {0x9BC, 0x9BC}, {0x9BE, 0x9C4}, {0x9C7, 0x9C8}, {0x9CB, 0x9CD},
    {0x9D7, 0x9D7}, {0x9E2, 0x9E3}, {0x9FE, 0x9FE}, {0xA01, 0xA03}, {0xA3C, 0xA3C}, {0xA3E, 0xA42},
    {0xA47, 0xA48}, {0xA4B, 0xA4D}, {0xA51, 0xA51}, {0xA70, 0xA71}, {0xA75, 0xA75}, {0xA81, 0xA83},
    {0xABC, 0xABC}, {0xABE, 0xAC5}, {0xAC7, 0xAC9}, {0xACB, 0xACD}, {0xAE2, 0xAE3}, {0xAFA, 0xAFF},
    {0xB01, 0xB03}, {0xB3C, 0xB3C}, {0xB3E, 0xB44}, {0xB47, 0xB48}, {0xB4B, 0xB4D}, {0xB55, 0xB57},
    {0xB62, 0xB63}, {0xB82, 0xB82}, {0xBBE, 0xBC2}, {0xBC6, 0xBC8}, {0xBCA, 0xBCD}, {0xBD7, 0xBD7},
    {0xC00, 0xC04}, {0xC3C, 0xC3C}, {0xC3E, 0xC44}, {0xC46, 0xC48}, {0xC4A, 0xC4D}, {0xC55, 0xC56},
    {0xC62, 0xC63}, {0xC81, 0xC83}, {0xCBC, 0xCBC}, {0xCBE, 0xCC4}, {0xCC6, 0xCC8}, {0xCCA, 0xCCD},
    {0xCD5, 0xCD6}, {0xCE2, 0xCE3}, {0xCF3, 0xCF3}, {0xD00, 0xD03}, {0xD3B, 0xD3C}, {0xD3E, 0xD44},
    {0xD46, 0xD48}, {0xD4A, 0xD4D}, {0xD57, 0xD57}, {0xD62, 0xD63}, {0xD81, 0xD83}, {0xDCA, 0xDCA},
    {0xDCF, 0xDD4}, {0xDD6, 0xDD6}, {0xDD8, 0xDDF}, {0xDF2, 0xDF3}, {0xE31, 0xE31}, {0xE33, 0xE3A},
    {0xE47, 0xE4E}, {0xEB1, 0xEB1}, {0xEB3, 0xEBC}, {0xEC8, 0xECE}, {0xF18, 0xF19}, {0xF35, 0xF35},
    {0xF37, 0xF37}, {0xF39, 0xF39}, {0xF3E, 0xF3F}, {0xF71, 0xF84}, {0xF86, 0xF87}, {0xF8D, 0xF97},
    {0xF99, 0xFBC}, {0xFC6, 0xFC6}, {0x102D, 0x1037}, {0x1039, 0x103E}, {0x1056, 0x1059},
    {0x105E, 0x1060}, {0x1071, 0x1074}, {0x1082, 0x1082}, {0x1084, 0x1086}, {0x108D, 0x108D},
    {0x109D, 0x109D}, {0x135D, 0x135F}, {0x1712, 0x1715}, {0x1732, 0x1734}, {0x1752, 0x1753},
    {0x1772, 0x1773}, {0x17B4, 0x17D3}, {0x17DD, 0x17DD}, {0x180B, 0x180D}, {0x180F, 0x180F},
    {0x1885, 0x1886}, {0x18A9, 0x18A9}, {0x1920, 0x192B}, {0x1930, 0x193B}, {0x1A17, 0x1A1B},
    {0x1A55, 0x1A5E}, {0x1A60, 0x1A60}, {0x1A62, 0x1A62}, {0x1A65, 0x1A7C}, {0x1A7F, 0x1A7F},
    {0x1AB0, 0x1ADD}, {0x1AE0, 0x1AEB}, {0x1B00, 0x1B04}, {0x1B34, 0x1B44}, {0x1B6B, 0x1B73},
    {0x1B80, 0x1B82}, {0x1BA1, 0x1BAD}, {0x1BE6, 0x1BF3}, {0x1C24, 0x1C37}, {0x1CD0, 0x1CD2},
    {0x1CD4, 0x1CE8}, {0x1CED, 0x1CED}, {0x1CF4, 0x1CF4}, {0x1CF7, 0x1CF9}, {0x1DC0, 0x1DFF},
    {0x200C, 0x200D}, {0x20D0, 0x20F0}, {0x2CEF, 0x2CF1}, {0x2D7F, 0x2D7F}, {0x2DE0, 0x2DFF},
    {0x302A, 0x302F}, {0x3099, 0x309A}, {0xA66F, 0xA672}, {0xA674, 0xA67D}, {0xA69E, 0xA69F},
    {0xA6F0, 0xA6F1}, {0xA802, 0xA802}, {0xA806, 0xA806}, {0xA80B, 0xA80B}, {0xA823, 0xA827},
    {0xA82C, 0xA82C}, {0xA880, 0xA881}, {0xA8B4, 0xA8C5}, {0xA8E0, 0xA8F1}, {0xA8FF, 0xA8FF},
    {0xA926, 0xA92D}, {0xA947, 0xA953}, {0xA980, 0xA983}, {0xA9B3, 0xA9C0}, {0xA9E5, 0xA9E5},
    {0xAA29, 0xAA36}, {0xAA43, 0xAA43}, {0xAA4C, 0xAA4D}, {0xAA7C, 0xAA7C}, {0xAAB0, 0xAAB0},
    {0xAAB2, 0xAAB4}, {0xAAB7, 0xAAB8}, {0xAABE, 0xAABF}, {0xAAC1, 0xAAC1}, {0xAAEB, 0xAAEF},
    {0xAAF5, 0xAAF6}, {0xABE3, 0xABEA}, {0xABEC, 0xABED}, {0xFB1E, 0xFB1E}, {0xFE00, 0xFE0F},
    {0xFE20, 0xFE2F}, {0xFF9E, 0xFF9F}, {0x101FD, 0x101FD}, {0x102E0, 0x102E0}, {0x10376, 0x1037A},
    {0x10A01, 0x10A03}, {0x10A05, 0x10A06}, {0x10A0C, 0x10A0F}, {0x10A38, 0x10A3A},
    {0x10A3F, 0x10A3F}, {0x10AE5, 0x10AE6}, {0x10D24, 0x10D27}, {0x10D69, 0x10D6D},
    {0x10EAB, 0x10EAC}, {0x10EFA, 0x10EFF}, {0x10F46, 0x10F50}, {0x10F82, 0x10F85},
    {0x11000, 0x11002}, {0x11038, 0x11046}, {0x11070, 0x11070}, {0x11073, 0x11074},
    {0x1107F, 0x11082}, {0x110B0, 0x110BA}, {0x110C2, 0x110C2}, {0x11100, 0x11102},
    {0x11127, 0x11134}, {0x11145, 0x11146}, {0x11173, 0x11173}, {0x11180, 0x11182},
    {0x111B3, 0x111C0}, {0x111C9, 0x111CC}, {0x111CE, 0x111CF}, {0x1122C, 0x11237},
    {0x1123E, 0x1123E}, {0x11241, 0x11241}, {0x112DF, 0x112EA}, {0x11300, 0x11303},
    {0x1133B, 0x1133C}, {0x1133E, 0x11344}, {0x11347, 0x11348}, {0x1134B, 0x1134D},
    {0x11357, 0x11357}, {0x11362, 0x11363}, {0x11366, 0x1136C}, {0x11370, 0x11374},
    {0x113B8, 0x113C0}, {0x113C2, 0x113C2}, {0x113C5, 0x113C5}, {0x113C7, 0x113CA},
    {0x113CC, 0x113D0}, {0x113D2, 0x113D2}, {0x113E1, 0x113E2}, {0x11435, 0x11446},
    {0x1145E, 0x1145E}, {0x114B0, 0x114C3}, {0x115AF, 0x115B5}, {0x115B8, 0x115C0},
    {0x115DC, 0x115DD}, {0x11630, 0x11640}, {0x116AB, 0x116B7}, {0x1171D, 0x1171F},
    {0x11722, 0x1172B}, {0x1182C, 0x1183A}, {0x11930, 0x11935}, {0x11937, 0x11938},
    {0x1193B, 0x1193E}, {0x11940, 0x11940}, {0x11942, 0x11943}, {0x119D1, 0x119D7},
    {0x119DA, 0x119E0}, {0x119E4, 0x119E4}, {0x11A01, 0x11A0A}, {0x11A33, 0x11A39},
    {0x11A3B, 0x11A3E}, {0x11A47, 0x11A47}, {0x11A51, 0x11A5B}, {0x11A8A, 0x11A99},
    {0x11B60, 0x11B67}, {0x11C2F, 0x11C36}, {0x11C38, 0x11C3F}, {0x11C92, 0x11CA7},
    {0x11CA9, 0x11CB6}, {0x11D31, 0x11D36}, {0x11D3A, 0x11D3A}, {0x11D3C, 0x11D3D},
    {0x11D3F, 0x11D45}, {0x11D47, 0x11D47}, {0x11D8A, 0x11D8E}, {0x11D90, 0x11D91},
    {0x11D93, 0x11D97}, {0x11EF3, 0x11EF6}, {0x11F00, 0x11F01}, {0x11F03, 0x11F03},
    {0x11F34, 0x11F3A}, {0x11F3E, 0x11F42}, {0x11F5A, 0x11F5A}, {0x13440, 0x13440},
    {0x13447, 0x13455}, {0x1611E, 0x1612F}, {0x16AF0, 0x16AF4}, {0x16B30, 0x16B36},
    {0x16F4F, 0x16F4F}, {0x16F51, 0x16F87}, {0x16F8F, 0x16F92}, {0x16FE4, 0x16FE4},
    {0x16FF0, 0x16FF1}, {0x1BC9D, 0x1BC9E}, {0x1CF00, 0x1CF2D}, {0x1CF30, 0x1CF46},
    {0x1D165, 0x1D169}, {0x1D16D, 0x1D172}, {0x1D17B, 0x1D182}, {0x1D185, 0x1D18B},
    {0x1D1AA, 0x1D1AD}, {0x1D242, 0x1D244}, {0x1DA00, 0x1DA36}, {0x1DA3B, 0x1DA6C},
    {0x1DA75, 0x1DA75}, {0x1DA84, 0x1DA84}, {0x1DA9B, 0x1DA9F}, {0x1DAA1, 0x1DAAF},
    {0x1E000, 0x1E006}, {0x1E008, 0x1E018}, {0x1E01B, 0x1E021}, {0x1E023, 0x1E024},
    {0x1E026, 0x1E02A}, {0x1E08F, 0x1E08F}, {0x1E130, 0x1E136}, {0x1E2AE, 0x1E2AE},
    {0x1E2EC, 0x1E2EF}, {0x1E4EC, 0x1E4EF}, {0x1E5EE, 0x1E5EF}, {0x1E6E3, 0x1E6E3},
    {0x1E6E6, 0x1E6E6}, {0x1E6EE, 0x1E6EF}, {0x1E6F5, 0x1E6F5}, {0x1E8D0, 0x1E8D6},
    {0x1E944, 0x1E94A}, {0x1F3FB, 0x1F3FF}, {0xE0020, 0xE007F}, {0xE0100, 0xE01EF},
};

template <size_t N>
bool inRanges(const ScalarRange (&ranges)[N], uint32_t scalar) {
    size_t low = 0, high = N;
    while (low < high) {
        size_t middle = (low + high) / 2;
        if (scalar < ranges[middle].first) high = middle;
        else if (scalar > ranges[middle].last) low = middle + 1;
        else return true;
    }
    return false;
}

struct Scalar {
    uint32_t value;
    size_t start;
    size_t length;
};

/* Invalid UTF-8 (never produced by Swift) is read one byte at a time as
 * U+FFFD, so nothing here reads past the end. */
std::vector<Scalar> decode(const std::string &text) {
    std::vector<Scalar> scalars;
    const auto *bytes = reinterpret_cast<const unsigned char *>(text.data());
    size_t size = text.size(), index = 0;
    while (index < size) {
        unsigned char lead = bytes[index];
        uint32_t value = 0xFFFD;
        size_t length = 1;
        auto continuation = [&](size_t offset) {
            return index + offset < size && (bytes[index + offset] & 0xC0) == 0x80;
        };
        if (lead < 0x80) {
            value = lead;
        } else if ((lead & 0xE0) == 0xC0 && continuation(1)) {
            value = (static_cast<uint32_t>(lead & 0x1F) << 6) | (bytes[index + 1] & 0x3F);
            length = 2;
        } else if ((lead & 0xF0) == 0xE0 && continuation(1) && continuation(2)) {
            value = (static_cast<uint32_t>(lead & 0x0F) << 12) | (static_cast<uint32_t>(bytes[index + 1] & 0x3F) << 6) |
                    (bytes[index + 2] & 0x3F);
            length = 3;
        } else if ((lead & 0xF8) == 0xF0 && continuation(1) && continuation(2) && continuation(3)) {
            value = (static_cast<uint32_t>(lead & 0x07) << 18) | (static_cast<uint32_t>(bytes[index + 1] & 0x3F) << 12) |
                    (static_cast<uint32_t>(bytes[index + 2] & 0x3F) << 6) | (bytes[index + 3] & 0x3F);
            length = 4;
        }
        scalars.push_back(Scalar{value, index, length});
        index += length;
    }
    return scalars;
}

bool isControl(uint32_t c) {
    return c <= 0x1F || (c >= 0x7F && c <= 0x9F) || c == 0xAD || c == 0x61C || c == 0x180E || c == 0x200B ||
           c == 0x200E || c == 0x200F || (c >= 0x2028 && c <= 0x202E) || (c >= 0x2060 && c <= 0x206F) ||
           c == 0xFEFF || (c >= 0xFFF0 && c <= 0xFFFB);
}

enum class Hangul { none, L, V, T, LV, LVT };

Hangul hangulOf(uint32_t c) {
    if ((c >= 0x1100 && c <= 0x115F) || (c >= 0xA960 && c <= 0xA97C)) return Hangul::L;
    if ((c >= 0x1160 && c <= 0x11A7) || (c >= 0xD7B0 && c <= 0xD7C6)) return Hangul::V;
    if ((c >= 0x11A8 && c <= 0x11FF) || (c >= 0xD7CB && c <= 0xD7FB)) return Hangul::T;
    if (c >= 0xAC00 && c <= 0xD7A3) return (c - 0xAC00) % 28 == 0 ? Hangul::LV : Hangul::LVT;
    return Hangul::none;
}

bool isPictographic(uint32_t c) {
    return (c >= 0x1F000 && c <= 0x1FAFF) || (c >= 0x2600 && c <= 0x27BF) || (c >= 0x2300 && c <= 0x23FF) ||
           (c >= 0x2B00 && c <= 0x2BFF) || c == 0xA9 || c == 0xAE || c == 0x203C || c == 0x2049 || c == 0x2122 ||
           c == 0x2139 || (c >= 0x2194 && c <= 0x21AA) || c == 0x3030 || c == 0x303D || c == 0x3297 || c == 0x3299;
}

bool isRegionalIndicator(uint32_t c) { return c >= 0x1F1E6 && c <= 0x1F1FF; }

/* Whether a Character boundary lies between `previous` and `current`. */
bool joins(const std::vector<Scalar> &scalars, size_t index, size_t clusterStart) {
    uint32_t previous = scalars[index - 1].value, current = scalars[index].value;
    if (previous == '\r' && current == '\n') return true;
    if (isControl(previous) || isControl(current)) return false;
    Hangul p = hangulOf(previous), c = hangulOf(current);
    if (p == Hangul::L && (c == Hangul::L || c == Hangul::V || c == Hangul::LV || c == Hangul::LVT)) return true;
    if ((p == Hangul::LV || p == Hangul::V) && (c == Hangul::V || c == Hangul::T)) return true;
    if ((p == Hangul::LVT || p == Hangul::T) && c == Hangul::T) return true;
    if (inRanges(kGraphemeExtendRanges, current)) return true;
    if (previous == 0x200D && isPictographic(current)) {
        for (size_t k = clusterStart; k + 1 < index; ++k)
            if (isPictographic(scalars[k].value)) return true;
        return false;
    }
    if (isRegionalIndicator(previous) && isRegionalIndicator(current)) {
        size_t run = 0;
        for (size_t k = index; k > clusterStart && isRegionalIndicator(scalars[k - 1].value); --k) ++run;
        return run % 2 == 1;
    }
    return false;
}

}  // namespace

std::vector<std::string> graphemes(const std::string &text) {
    std::vector<std::string> result;
    std::vector<Scalar> scalars = decode(text);
    size_t clusterStart = 0;
    for (size_t index = 0; index < scalars.size(); ++index) {
        if (index > 0 && joins(scalars, index, clusterStart)) {
            result.back().append(text, scalars[index].start, scalars[index].length);
            continue;
        }
        clusterStart = index;
        result.emplace_back(text, scalars[index].start, scalars[index].length);
    }
    return result;
}

uint32_t firstScalar(const std::string &character) {
    std::vector<Scalar> scalars = decode(character);
    return scalars.empty() ? 0 : scalars.front().value;
}

bool isWhitespaceCharacter(const std::string &character) {
    return !character.empty() && inRanges(kWhitespaceRanges, firstScalar(character));
}

bool isNumberCharacter(const std::string &character) {
    return !character.empty() && inRanges(kNumberRanges, firstScalar(character));
}

namespace {

std::string joined(const std::vector<std::string> &characters, size_t from = 0, size_t to = std::string::npos) {
    std::string result;
    to = std::min(to, characters.size());
    for (size_t index = from; index < to; ++index) result += characters[index];
    return result;
}

bool isASCIIDigit(const std::string &character) {
    return character.size() == 1 && character[0] >= '0' && character[0] <= '9';
}

/* `trimmingCharacters(in: .whitespaces)`, which works on scalars. */
std::string trimmedWhitespace(const std::string &text) {
    std::vector<Scalar> scalars = decode(text);
    size_t first = 0, last = scalars.size();
    while (first < last && inRanges(kTrimWhitespaceRanges, scalars[first].value)) ++first;
    while (last > first && inRanges(kTrimWhitespaceRanges, scalars[last - 1].value)) --last;
    if (first == last) return std::string();
    size_t start = scalars[first].start, end = scalars[last - 1].start + scalars[last - 1].length;
    return text.substr(start, end - start);
}

bool startsWith(const std::vector<std::string> &text, const std::vector<std::string> &prefix) {
    if (prefix.size() > text.size()) return false;
    return std::equal(prefix.begin(), prefix.end(), text.begin());
}

bool endsWith(const std::vector<std::string> &text, const std::vector<std::string> &suffix) {
    if (suffix.size() > text.size()) return false;
    return std::equal(suffix.begin(), suffix.end(), text.end() - static_cast<std::ptrdiff_t>(suffix.size()));
}

/* `String.contains(_:)` on Characters. An empty needle is contained. */
bool containsCharacters(const std::vector<std::string> &text, const std::vector<std::string> &needle) {
    if (needle.empty()) return true;
    if (needle.size() > text.size()) return false;
    return std::search(text.begin(), text.end(), needle.begin(), needle.end()) != text.end();
}

using NormalizeFunction = int32_t (*)(gc_string, char *, int32_t);

std::string viaBuffer(NormalizeFunction function, const std::string &text) {
    char stack[256];
    gc_string input = view(text);
    int32_t length = function(input, stack, static_cast<int32_t>(sizeof stack));
    if (length <= 0) return std::string();
    if (length <= static_cast<int32_t>(sizeof stack)) return std::string(stack, static_cast<size_t>(length));
    std::string buffer(static_cast<size_t>(length), '\0');
    int32_t written = function(input, &buffer[0], length);
    buffer.resize(written > 0 && written <= length ? static_cast<size_t>(written) : 0);
    return buffer;
}

std::string normalized(const std::string &text) { return viaBuffer(gc_normalize, text); }
std::string compactTransmuter(const std::string &text) { return viaBuffer(gc_compact_transmuter, text); }

const std::set<std::string> &levelledItems() {
    static const std::set<std::string> items = {"Resonator", "XMP Burster", "Power Cube", "Ultra Strike"};
    return items;
}

const std::set<std::string> &unlevelledItems() {
    static const std::set<std::string> items = {
        "Portal Key", "Portal Shield", "Turret", "Link Amp", "Multi-Hack", "JARVIS Virus", "Heat Sink",
        "Kinetic Capsule", "Hypercube", "Force Amp", "ADA Refactor", "Aegis Shield", "SoftBank Ultra Link",
        "Capsule", "Media", "ITO EN Transmuter (+)", "ITO EN Transmuter (-)"};
    return items;
}

std::optional<gc_language> languageForCode(const std::string &code) {
    if (code == "en") return GC_LANGUAGE_ENGLISH;
    if (code == "zh-Hans") return GC_LANGUAGE_SIMPLIFIED_CHINESE;
    if (code == "zh-Hant") return GC_LANGUAGE_TRADITIONAL_CHINESE;
    if (code == "ja") return GC_LANGUAGE_JAPANESE;
    if (code == "ko") return GC_LANGUAGE_KOREAN;
    return std::nullopt;
}

/** One `GameText` pack, as far as the gear matchers read it. */
struct Pack {
    std::string code;
    std::string bonusTitle;
    std::string bountyTitle;
    std::vector<std::vector<std::string>> messageFragments;
    std::vector<std::vector<std::string>> effectSuffixes;
    std::vector<std::vector<std::string>> effectPrefixes;
    /* `items` in the Swift dictionary's iteration order. */
    std::vector<std::pair<std::string, std::string>> items;
    std::vector<std::vector<std::string>> itemKeyCharacters;
    std::unordered_map<std::string, size_t> itemIndex;
    std::map<std::string, std::set<std::string>> leadingWords;
};

enum class Title { bonus, bounty, unsupported, message, other };

/* `GearDropTextParser.distance`: Levenshtein on Characters, 4 when the
 * lengths differ by more than 3. */
int distance(const std::string &first, const std::string &second) {
    std::vector<std::string> a = graphemes(first), b = graphemes(second);
    long difference = static_cast<long>(a.size()) - static_cast<long>(b.size());
    if (std::labs(difference) > 3) return 4;
    std::vector<int> previous(b.size() + 1);
    for (size_t j = 0; j <= b.size(); ++j) previous[j] = static_cast<int>(j);
    for (size_t i = 0; i < a.size(); ++i) {
        std::vector<int> next{static_cast<int>(i) + 1};
        for (size_t j = 0; j < b.size(); ++j) {
            next.push_back(std::min({next[j] + 1, previous[j + 1] + 1, previous[j] + (a[i] == b[j] ? 0 : 1)}));
        }
        previous = std::move(next);
    }
    return previous[b.size()];
}

}  // namespace

}  // namespace glyphgear

using namespace glyphgear;

struct gl_gear_parser {
    gc_language language = GC_LANGUAGE_ENGLISH;
    std::vector<Pack> packs;
    std::set<std::string> allBonusTitles;
    std::string lastItem;
    EvidenceExport output;

    double lineFloor() const { return language == GC_LANGUAGE_ENGLISH ? 0.5 : 0.3; }
    double titleFloor() const { return language == GC_LANGUAGE_ENGLISH ? 0.7 : 0.5; }

    /* GameText.title(_:) */
    Title title(const std::string &text) const {
        std::string key = normalized(text);
        for (const Pack &pack : packs)
            if (pack.bonusTitle == key) return Title::bonus;
        for (const Pack &pack : packs)
            if (pack.bountyTitle == key) return Title::bounty;
        if (allBonusTitles.count(key) != 0) return Title::unsupported;
        std::vector<std::string> characters = graphemes(key);
        for (const Pack &pack : packs)
            for (const auto &fragment : pack.messageFragments)
                if (containsCharacters(characters, fragment)) return Title::message;
        return Title::other;
    }

    /* GameText.bonusTitleLanguage(_:) */
    std::optional<gc_language> bonusTitleLanguage(const std::string &text) const {
        std::string key = normalized(text);
        for (const Pack &pack : packs)
            if (pack.bonusTitle == key) return languageForCode(pack.code);
        return std::nullopt;
    }

    /* GameText.effect(_:) */
    std::optional<std::string> effect(const std::string &text) const {
        std::vector<std::string> value = graphemes(compactTransmuter(text));
        while (!value.empty() && (value.back() == "." || value.back() == "。")) value.pop_back();
        const std::vector<std::string> *suffix = nullptr;
        for (const Pack &pack : packs) {
            for (const auto &candidate : pack.effectSuffixes)
                if (endsWith(value, candidate)) { suffix = &candidate; break; }
            if (suffix != nullptr) break;
        }
        if (suffix != nullptr) {
            value.resize(value.size() - suffix->size());
        } else {
            const std::vector<std::string> *prefix = nullptr;
            for (const Pack &pack : packs) {
                for (const auto &candidate : pack.effectPrefixes)
                    if (startsWith(value, candidate)) { prefix = &candidate; break; }
                if (prefix != nullptr) break;
            }
            if (prefix == nullptr) return std::nullopt;
            value.erase(value.begin(), value.begin() + static_cast<std::ptrdiff_t>(prefix->size()));
        }
        std::string remaining = joined(value);
        if (remaining == "itoen(+)" || remaining == "itoentransmuter(+)") return std::string("ITO EN (+)");
        if (remaining == "itoen(-)" || remaining == "itoentransmuter(-)") return std::string("ITO EN (-)");
        return std::nullopt;
    }

    /* GameText.item(named:clipped:) */
    std::optional<std::string> item(const std::string &name, bool clipped) const {
        std::string compact = compactTransmuter(name);
        if (compact == "itoentransmuter(+)" || compact == "itoen(+)") return std::string("ITO EN Transmuter (+)");
        if (compact == "itoentransmuter(-)" || compact == "itoen(-)") return std::string("ITO EN Transmuter (-)");
        std::vector<std::string> shown = graphemes(trimmedWhitespace(name));
        bool unicodeEllipsis = !shown.empty() && shown.back() == "…";
        bool dots = shown.size() >= 3 && shown[shown.size() - 1] == "." && shown[shown.size() - 2] == "." &&
                    shown[shown.size() - 3] == ".";
        bool ellipsis = unicodeEllipsis || dots;
        if (unicodeEllipsis) shown.pop_back();
        else if (dots) shown.resize(shown.size() - 3);
        for (const std::string &character : shown)
            if (character == "…" || character == ".") return std::nullopt;
        std::string key = normalized(joined(shown));
        if (key.empty()) return std::nullopt;
        if (!ellipsis) {
            for (const Pack &pack : packs) {
                auto found = pack.itemIndex.find(key);
                if (found != pack.itemIndex.end()) return pack.items[found->second].second;
            }
        }
        if (!ellipsis && !clipped && language != GC_LANGUAGE_ENGLISH) {
            std::set<std::string> items;
            for (const Pack &pack : packs) {
                auto found = pack.leadingWords.find(key);
                if (found != pack.leadingWords.end()) items.insert(found->second.begin(), found->second.end());
            }
            if (items.size() == 1) return *items.begin();
        }
        if (!ellipsis && !clipped) return std::nullopt;
        std::vector<std::string> keyCharacters = graphemes(key);
        std::set<std::string> candidates;
        for (const Pack &pack : packs) {
            for (size_t index = 0; index < pack.items.size(); ++index) {
                const auto &characters = pack.itemKeyCharacters[index];
                if (startsWith(characters, keyCharacters) && characters.size() > keyCharacters.size())
                    candidates.insert(pack.items[index].second);
            }
        }
        if (candidates.size() != 1) return std::nullopt;
        const std::string &match = *candidates.begin();
        const std::vector<std::string> *full = nullptr;
        for (const Pack &pack : packs) {
            for (size_t index = 0; index < pack.items.size(); ++index) {
                if (pack.items[index].second == match && startsWith(pack.itemKeyCharacters[index], keyCharacters)) {
                    full = &pack.itemKeyCharacters[index];
                    break;
                }
            }
            if (full != nullptr) break;
        }
        if (full == nullptr || keyCharacters.size() < 3 ||
            !(static_cast<double>(keyCharacters.size()) >= static_cast<double>(full->size()) * 0.5))
            return std::nullopt;
        return match;
    }

    /* GearDropTextParser.parseEntry(_:row:column:clipped:) */
    std::optional<Entry> parseEntry(const std::string &text, int32_t row, int32_t column, bool clipped) const {
        if (row < 0 || row >= 7 || column < 0 || column >= 2) return std::nullopt;
        std::vector<std::string> characters = graphemes(text);
        std::vector<size_t> markers;
        for (size_t index = 0; index < characters.size(); ++index) {
            const std::string &character = characters[index];
            if ((character == "x" || character == "X" || character == "×") && index + 1 < characters.size() &&
                isASCIIDigit(characters[index + 1]))
                markers.push_back(index);
        }
        if (markers.size() != 1) return std::nullopt;
        size_t marker = markers.front();
        size_t end = marker + 1;
        while (end < characters.size() && isASCIIDigit(characters[end])) ++end;
        int64_t quantity = 0;
        for (size_t index = marker + 1; index < end; ++index) {
            int digit = characters[index][0] - '0';
            if (quantity > (INT64_MAX - digit) / 10) return std::nullopt;  // Int(_:) fails on overflow
            quantity = quantity * 10 + digit;
        }
        if (quantity < 1 || quantity > 9999 || end >= characters.size()) return std::nullopt;
        // `split(whereSeparator: \.isWhitespace).joined(separator: " ")`.
        std::string name;
        {
            std::string word;
            for (size_t index = end; index < characters.size(); ++index) {
                if (isWhitespaceCharacter(characters[index])) {
                    if (!word.empty()) {
                        if (!name.empty()) name += ' ';
                        name += word;
                        word.clear();
                    }
                } else {
                    word += characters[index];
                }
            }
            if (!word.empty()) {
                if (!name.empty()) name += ' ';
                name += word;
            }
        }
        if (name.empty()) return std::nullopt;
        std::vector<std::string> nameCharacters = graphemes(name);
        // `name.uppercased().contains(" AP")`: only a lone a/A and p/P
        // uppercase to the Characters "A" and "P".
        for (size_t index = 0; index + 2 < nameCharacters.size(); ++index) {
            if (nameCharacters[index] == " " && (nameCharacters[index + 1] == "a" || nameCharacters[index + 1] == "A") &&
                (nameCharacters[index + 2] == "p" || nameCharacters[index + 2] == "P"))
                return std::nullopt;
        }
        std::optional<std::string> found = item(name, clipped);
        bool hasPlus = std::find(nameCharacters.begin(), nameCharacters.end(), "+") != nameCharacters.end();
        if (hasPlus && found != std::optional<std::string>("ITO EN Transmuter (+)")) return std::nullopt;
        std::vector<std::string> prefix;
        for (size_t index = 0; index < marker; ++index)
            if (!isWhitespaceCharacter(characters[index])) prefix.push_back(characters[index]);
        bool levelled = found && levelledItems().count(*found) != 0;
        bool unlevelled = found && unlevelledItems().count(*found) != 0;
        std::optional<int32_t> level;
        if (!unlevelled && !prefix.empty() && isASCIIDigit(prefix.back())) {
            int32_t value = prefix.back()[0] - '0';
            if (value >= 1 && value <= 8) {
                const std::string *before = prefix.size() >= 2 ? &prefix[prefix.size() - 2] : nullptr;
                if (before != nullptr && *before == "L") {
                    level = value;
                } else if (levelled) {
                    if (!(before != nullptr && isNumberCharacter(*before) && *before != "1")) level = value;
                }
            }
        }
        Entry entry;
        entry.column = column;
        entry.row = row;
        entry.item = found;
        entry.levelState = level ? GL_GEAR_LEVEL_KNOWN : (unlevelled ? GL_GEAR_LEVEL_NOT_APPLICABLE : GL_GEAR_LEVEL_UNREADABLE);
        entry.level = level;
        entry.quantity = quantity;
        return entry.withRarity(entry.intrinsicRarity());
    }

    struct Line {
        std::string text;
        double confidence, x, y, width, height;
    };

    /* GearDropTextParser.read(lines:bounds:at:) */
    Evidence read(const std::vector<Line> &lines, gc_panel_bounds bounds, double time) const;

    /* GearDropTextParser.body(_:bounds:): the rows and effects under the title. */
    struct Body {
        std::vector<Entry> entries;
        int32_t unreadable = 0;
        std::vector<std::string> effects;
    };
    Body body(const std::vector<const Line *> &contained, gc_panel_bounds bounds) const;

    /* GearDropTextParser.showsUntitledPanel(lines:bounds:at:) */
    bool showsUntitledPanel(const std::vector<Line> &lines, gc_panel_bounds bounds, double time) const;
};

namespace glyphgear {
namespace {

/* GearDropTextParser.position(of:in:). Swift's Int(_:) traps on a row
 * that is not finite or does not fit an Int; that is nil here. */
std::optional<int32_t> positionOf(double x, double y, double width, double height, gc_panel_bounds bounds) {
    double rounded = std::round((y + height / 2 - bounds.top - 0.067) / 0.036);
    if (!std::isfinite(rounded) || rounded < -9.2e18 || rounded > 9.2e18) return std::nullopt;
    int64_t row = static_cast<int64_t>(rounded);
    int32_t column = x < 0.5 ? 0 : 1;
    if (row < 0 || row >= 7 || !(x + width <= (column == 0 ? 0.50 : 0.98))) return std::nullopt;
    return static_cast<int32_t>(row * 2 + column);
}

}  // namespace
}  // namespace glyphgear

namespace glyphgear {
namespace {

/* The lines inside the panel box, as both `read` and `showsUntitledPanel` filter them. */
std::vector<const gl_gear_parser::Line *> containedLines(const std::vector<gl_gear_parser::Line> &lines,
                                                         gc_panel_bounds bounds) {
    std::vector<const gl_gear_parser::Line *> contained;
    for (const gl_gear_parser::Line &line : lines) {
        if (line.y >= bounds.top && line.y + line.height <= bounds.bottom + 0.003 && line.x >= 0.025 &&
            line.x + line.width <= 0.98)
            contained.push_back(&line);
    }
    return contained;
}

}  // namespace
}  // namespace glyphgear

Evidence gl_gear_parser::read(const std::vector<Line> &lines, gc_panel_bounds bounds, double time) const {
    auto bare = [&](gl_gear_stage stage) {
        Evidence evidence;
        evidence.sourceTime = time;
        evidence.stage = stage;
        evidence.bounds = bounds;
        return evidence;
    };
    std::vector<const Line *> contained = containedLines(lines, bounds);
    std::vector<const Line *> titles;
    for (const Line *line : contained)
        if (line->y + line->height / 2 < bounds.top + 0.045) titles.push_back(line);
    if (titles.size() != 1 || !(titles.front()->confidence >= titleFloor())) return bare(GL_GEAR_STAGE_UNKNOWN);
    const Line &titleLine = *titles.front();
    std::string key = normalized(titleLine.text);
    gl_gear_stage stage;
    switch (title(titleLine.text)) {
    case Title::bonus: stage = GL_GEAR_STAGE_BONUS; break;
    case Title::unsupported: stage = GL_GEAR_STAGE_UNSUPPORTED; break;
    case Title::bounty: stage = GL_GEAR_STAGE_EXCLUDED; break;
    case Title::message: stage = GL_GEAR_STAGE_UNKNOWN; break;
    case Title::other:
        stage = key.empty() || distance(key, "bonusitems") <= 3 || distance(key, "bountyclaimed") <= 3
                    ? GL_GEAR_STAGE_UNKNOWN
                    : GL_GEAR_STAGE_PORTAL;
        break;
    }
    if (stage != GL_GEAR_STAGE_PORTAL && stage != GL_GEAR_STAGE_BONUS) return bare(stage);
    Body parsed = body(contained, bounds);
    Evidence evidence = bare(stage);
    evidence.entries = std::move(parsed.entries);
    evidence.unreadableRows = parsed.unreadable;
    if (parsed.effects.size() == 1) evidence.effects = parsed.effects;
    if (stage == GL_GEAR_STAGE_BONUS) evidence.titleLanguage = bonusTitleLanguage(titleLine.text);
    return evidence;
}

gl_gear_parser::Body gl_gear_parser::body(const std::vector<const Line *> &contained, gc_panel_bounds bounds) const {
    std::vector<const Line *> body;
    for (const Line *line : contained)
        if (line->y + line->height / 2 >= bounds.top + 0.045) body.push_back(line);
    std::set<std::string> effectSet;
    std::vector<const Line *> items;
    for (const Line *line : body) {
        std::optional<std::string> label;
        if (line->confidence >= titleFloor() && line->y + line->height / 2 < bounds.top + 0.09)
            label = effect(line->text);
        if (label) effectSet.insert(*label);
        else items.push_back(line);
    }
    std::vector<std::string> effects(effectSet.begin(), effectSet.end());
    std::map<int32_t, std::vector<const Line *>> rows;
    int32_t unreadable = effects.size() > 1 ? 1 : 0;
    for (const Line *line : items) {
        auto position = positionOf(line->x, line->y, line->width, line->height, bounds);
        if (!position) {
            unreadable += 1;
            continue;
        }
        rows[*position].push_back(line);
    }
    std::vector<Entry> entries;
    for (auto &pair : rows) {
        int32_t position = pair.first;
        std::vector<const Line *> fragments = pair.second;
        bool confident = true;
        for (const Line *line : fragments)
            if (!(line->confidence >= lineFloor())) confident = false;
        if (!confident) {
            unreadable += 1;
            continue;
        }
        std::stable_sort(fragments.begin(), fragments.end(),
                         [](const Line *a, const Line *b) { return a->x < b->x; });
        int32_t column = position % 2;
        double right = fragments.front()->x + fragments.front()->width;
        for (size_t index = 1; index < fragments.size(); ++index) {
            double value = fragments[index]->x + fragments[index]->width;
            if (right < value) right = value;
        }
        bool clipped = right >= (column == 0 ? 0.50 : 0.98) - 0.05;
        std::string text;
        for (size_t index = 0; index < fragments.size(); ++index) {
            if (index > 0) text += ' ';
            text += fragments[index]->text;
        }
        if (auto entry = parseEntry(text, position / 2, column, clipped)) entries.push_back(*entry);
        else unreadable += 1;
    }
    Body parsed;
    parsed.entries = std::move(entries);
    parsed.unreadable = unreadable + (items.empty() ? 1 : 0);
    parsed.effects = std::move(effects);
    return parsed;
}

bool gl_gear_parser::showsUntitledPanel(const std::vector<Line> &lines, gc_panel_bounds bounds, double time) const {
    if (read(lines, bounds, time).stage != GL_GEAR_STAGE_UNKNOWN) return false;
    Body parsed = body(containedLines(lines, bounds), bounds);
    if (!parsed.effects.empty()) return true;
    for (const Entry &entry : parsed.entries)
        if (entry.item) return true;
    return false;
}

extern "C" {

gl_gear_parser *gl_gear_parser_create(gc_language language, const gl_gear_text_table *tables, int32_t tableCount,
                                      const gc_string *allBonusTitles, int32_t allBonusTitleCount) {
    if (tableCount < 0 || (tableCount > 0 && tables == nullptr) || allBonusTitleCount < 0 ||
        (allBonusTitleCount > 0 && allBonusTitles == nullptr) || static_cast<int>(language) < 0 ||
        static_cast<int>(language) > static_cast<int>(GC_LANGUAGE_KOREAN))
        return nullptr;
    auto characterLists = [](const gc_string *strings, int32_t count) {
        std::vector<std::vector<std::string>> values;
        for (int32_t index = 0; strings != nullptr && index < count; ++index)
            values.push_back(graphemes(toString(strings[index])));
        return values;
    };
    auto *parser = new gl_gear_parser();
    parser->language = language;
    for (int32_t index = 0; index < tableCount; ++index) {
        const gl_gear_text_table &table = tables[index];
        Pack pack;
        pack.code = toString(table.code);
        pack.bonusTitle = toString(table.bonusTitle);
        pack.bountyTitle = toString(table.bountyTitle);
        pack.messageFragments = characterLists(table.messageFragments, table.messageFragmentCount);
        pack.effectSuffixes = characterLists(table.effectSuffixes, table.effectSuffixCount);
        pack.effectPrefixes = characterLists(table.effectPrefixes, table.effectPrefixCount);
        for (int32_t item = 0; table.items != nullptr && item < table.itemCount; ++item) {
            std::string key = toString(table.items[item].key);
            if (pack.itemIndex.count(key) == 0) pack.itemIndex[key] = pack.items.size();
            pack.itemKeyCharacters.push_back(graphemes(key));
            pack.items.emplace_back(key, toString(table.items[item].value));
        }
        for (int32_t word = 0; table.leadingWords != nullptr && word < table.leadingWordCount; ++word)
            pack.leadingWords[toString(table.leadingWords[word].key)].insert(toString(table.leadingWords[word].value));
        parser->packs.push_back(std::move(pack));
    }
    for (int32_t index = 0; index < allBonusTitleCount; ++index)
        parser->allBonusTitles.insert(toString(allBonusTitles[index]));
    return parser;
}

void gl_gear_parser_destroy(gl_gear_parser *parser) { delete parser; }

bool gl_gear_parser_parse_entry(gl_gear_parser *parser, gc_string text, int32_t row, int32_t column, bool clipped,
                                gl_gear_entry *out) {
    if (parser == nullptr) return false;
    auto entry = parser->parseEntry(toString(text), row, column, clipped);
    if (!entry) return false;
    if (out != nullptr) {
        parser->lastItem = entry->item.value_or(std::string());
        *out = entryView(*entry);
        out->item = entry->item ? view(parser->lastItem) : gc_string{nullptr, 0};
    }
    return true;
}

void gl_gear_parser_read(gl_gear_parser *parser, const gl_gear_text_line *lines, int32_t count,
                         gc_panel_bounds bounds, double time, gl_gear_evidence *out) {
    if (parser == nullptr || out == nullptr) return;
    std::vector<gl_gear_parser::Line> converted;
    for (int32_t index = 0; lines != nullptr && index < count; ++index) {
        const gl_gear_text_line &line = lines[index];
        converted.push_back(gl_gear_parser::Line{toString(line.text), line.confidence, line.x, line.y, line.width,
                                                 line.height});
    }
    parser->output.fill(parser->read(converted, bounds, time), out);
}

bool gl_gear_parser_shows_untitled_panel(gl_gear_parser *parser, const gl_gear_text_line *lines, int32_t count,
                                         gc_panel_bounds bounds, double time) {
    if (parser == nullptr) return false;
    std::vector<gl_gear_parser::Line> converted;
    for (int32_t index = 0; lines != nullptr && index < count; ++index) {
        const gl_gear_text_line &line = lines[index];
        converted.push_back(gl_gear_parser::Line{toString(line.text), line.confidence, line.x, line.y, line.width,
                                                 line.height});
    }
    return parser->showsUntitledPanel(converted, bounds, time);
}

bool gl_gear_position(const gl_gear_text_line *line, gc_panel_bounds bounds, int32_t *out) {
    if (line == nullptr) return false;
    auto position = positionOf(line->x, line->y, line->width, line->height, bounds);
    if (!position) return false;
    if (out != nullptr) *out = *position;
    return true;
}

}  // extern "C"
