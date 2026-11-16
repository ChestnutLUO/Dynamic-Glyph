#ifndef GLYPH_COMMON_H
#define GLYPH_COMMON_H

/*
 * Conventions shared by every GlyphCore ABI header of the logic layer.
 *
 * - Objects with state are opaque handles: `gl_<name>_create` returns one,
 *   `gl_<name>_destroy` frees it, `gl_<name>_reset` is the Swift `reset()`.
 *   Every other function on a handle mirrors one Swift method or property,
 *   named `gl_<name>_<method>`. Handles are not thread-safe; one serial
 *   queue owns them, as the Swift values were owned.
 * - Values are plain C structs mirroring the Swift value types field for
 *   field, in the same order. Optionals are a `has` flag beside the value.
 *   Variable-length results use a count plus a fixed capacity array when the
 *   bound is small and known, or a pointer owned by the handle, valid until
 *   its next call, when it is not.
 * - Strings are UTF-8 as `gc_string`, not necessarily NUL-terminated.
 *   Strings a function returns are owned by the handle, valid until its next
 *   call. Text the logic matches against (phrase packs, item names, labels)
 *   is passed in at creation from the Swift `GameText`, which stays the one
 *   source of that data.
 * - Glyphs cross the ABI as indices into the Glyph table's name-sorted list
 *   (`GlyphTable.glyphs`), as the pixel core's templates do. Sequences are
 *   arrays of such indices. -1 is "no Glyph".
 * - Times are seconds as double, the frames' own clock. Non-finite times
 *   are handled as the Swift code handles them, never trapped on.
 * - Enums mirror the Swift cases in declaration order, with an explicit
 *   `_NONE = 0` first wherever Swift has an optional of the enum.
 * - Nothing allocates on the caller's behalf except `create`. A function
 *   that cannot act (null handle, out-of-range argument) returns false or
 *   the `_NONE` value and changes nothing.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** UTF-8 text, `length` bytes at `bytes`. Not necessarily NUL-terminated. */
typedef struct gc_string {
    const char *bytes;
    int32_t length;
} gc_string;

typedef struct gc_opt_double {
    bool has;
    double value;
} gc_opt_double;

typedef struct gc_opt_int32 {
    bool has;
    int32_t value;
} gc_opt_int32;

/* Text normalization, shared by every parser. Implemented by the "pace"
 * area in logic_text.cpp; the other areas call it. Both must equal the Swift
 * functions on every Unicode scalar, which the pace task proves with tables
 * generated from Swift's own `Character.isLetter`, `isNumber` and
 * `lowercased()` over the whole code space. */

/** `GameText.normalized(_:)`: lowercased letters and digits only, as UTF-8
 *  into `out` (capacity `capacity` bytes). Returns the length written, or
 *  the length needed when it exceeds the capacity (then `out` is untouched). */
int32_t gc_normalize(gc_string text, char *out, int32_t capacity);

/** `GameText.compactTransmuter(_:)`: lowercased, whitespace removed, the
 *  dash, plus and parenthesis variants folded. Same contract as above. */
int32_t gc_compact_transmuter(gc_string text, char *out, int32_t capacity);

/** `GameLanguage`, in `GameLanguage.allCases` order. */
typedef enum gc_language {
    GC_LANGUAGE_ENGLISH = 0,
    GC_LANGUAGE_SIMPLIFIED_CHINESE,
    GC_LANGUAGE_TRADITIONAL_CHINESE,
    GC_LANGUAGE_JAPANESE,
    GC_LANGUAGE_KOREAN
} gc_language;

#ifdef __cplusplus
}
#endif

#endif /* GLYPH_COMMON_H */
