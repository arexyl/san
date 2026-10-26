/*
 * The containment adapter of libpng's push reader: the one interface
 * between San's Zig code and its C code for PNG.
 *
 * Zig calls the functions below, and the adapter reaches Zig only through
 * the hook table that it receives at creation. The decoder object is
 * opaque: the adapter allocates it through the allocation hook, so it
 * counts against the caller's budget, and it holds the jump buffer and
 * every record that changes while libpng runs.
 *
 * A libpng error leaves libpng through the adapter's own jump, and every
 * function returns an ordinary status. After a terminal status, the only
 * call that remains is san_png_destroy.
 *
 * The header includes only <stddef.h> and <stdint.h>, so that the
 * translation for Zig sees no libpng, zlib, or setjmp declaration.
 */
#ifndef SAN_PNG_ADAPTER_H
#define SAN_PNG_ADAPTER_H

#include <stddef.h>
#include <stdint.h>

/* The decoder object of one decode. */
typedef struct san_png_decoder san_png_decoder;

/* The answer of a header or row hook. */
typedef int32_t san_png_verdict;

/* Go on decoding. */
#define SAN_PNG_CONTINUE 0
/*
 * Stop the decode. The adapter raises a libpng error after the hook has
 * returned, and the call that is running returns SAN_PNG_STATUS_STOPPED.
 * The hook's owner holds the cause.
 */
#define SAN_PNG_STOP 1

/*
 * The image header as IHDR declares it. row_bytes is the size of one
 * encoded row without its filter byte.
 */
typedef struct san_png_header {
    uint32_t width;
    uint32_t height;
    uint8_t bit_depth;
    uint8_t color_type;
    /* Zero for a noninterlaced image, one for Adam7. */
    uint8_t interlace;
    uint8_t channels;
    uint64_t row_bytes;
} san_png_header;

/*
 * The callbacks of one decoder, each called with ctx. alloc returns a block
 * aligned to 16 bytes, or null after it recorded the refusal; it never
 * jumps. free releases a block of alloc without its size, and ignores
 * null. header runs once, at the first IDAT chunk, before any row. row
 * runs for each row in order; its bytes stay valid only during the call.
 */
typedef struct san_png_hooks {
    void *ctx;
    void *(*alloc)(void *ctx, size_t size);
    void (*free)(void *ctx, void *block);
    san_png_verdict (*header)(void *ctx, const san_png_header *header);
    san_png_verdict (*row)(
        void *ctx,
        uint32_t index,
        const uint8_t *bytes,
        size_t len);
} san_png_hooks;

/* The status of a call. */
typedef int32_t san_png_status;

/* The input so far is consistent; the decode needs more of it. */
#define SAN_PNG_STATUS_NEED_INPUT 0
/*
 * IEND passed every check: every row arrived in order, and the image data
 * stream ended verified. The decode succeeds only at san_png_finish.
 */
#define SAN_PNG_STATUS_ENDED 1
/* san_png_finish after SAN_PNG_STATUS_ENDED: the decode succeeded. */
#define SAN_PNG_STATUS_DONE 2
/* A hook returned SAN_PNG_STOP. */
#define SAN_PNG_STATUS_STOPPED 3
/* san_png_finish before IEND, without a recorded fault. */
#define SAN_PNG_STATUS_TRUNCATED 4
/* An acTL chunk precedes the image data: an animated image. */
#define SAN_PNG_STATUS_ANIMATED 5
/* The input violates the format or San's strictness rules. */
#define SAN_PNG_STATUS_INVALID 6

/*
 * Why a decode ended without success. The status alone decides the
 * category; the reason serves diagnostics and tests. The first recorded
 * reason stays.
 */
typedef int32_t san_png_reason;

/* No fault is recorded. */
#define SAN_PNG_REASON_NONE 0
/* libpng raised an error of its own. */
#define SAN_PNG_REASON_LIBPNG 1
/* libpng warned about IHDR, tRNS, IEND, or the PLTE of a palette image. */
#define SAN_PNG_REASON_ESSENTIAL 2
/* The image data stream failed before its verified end. */
#define SAN_PNG_REASON_STREAM 3
/* IEND arrived before every row or before the verified stream end. */
#define SAN_PNG_REASON_INCOMPLETE 4
/* An IDAT chunk follows another chunk after the image data. */
#define SAN_PNG_REASON_NONCONSECUTIVE 5
/* Bytes follow IEND. */
#define SAN_PNG_REASON_TRAILING 6
/* An acTL chunk precedes the image data. */
#define SAN_PNG_REASON_ANIMATED 7
/* A hook returned SAN_PNG_STOP. */
#define SAN_PNG_REASON_STOPPED 8
/* The input ended before IEND. */
#define SAN_PNG_REASON_TRUNCATED 9
/* A row is too long for the push reader to address. */
#define SAN_PNG_REASON_GEOMETRY 10
/* libpng delivered a row out of order. */
#define SAN_PNG_REASON_ROW_ORDER 11
/* A sample of a palette image indexes no entry of the palette. */
#define SAN_PNG_REASON_PALETTE_INDEX 12
/* A chunk other than IHDR follows the signature. */
#define SAN_PNG_REASON_FIRST_CHUNK 13

/* The records of a decoder that outlive its outcome. */
typedef struct san_png_report {
    san_png_reason reason;
    /* Every warning of libpng, a diagnostic or a fault. */
    uint32_t warnings;
    /*
     * One when optional color metadata (gAMA, cHRM, sRGB, iCCP, cICP,
     * mDCV, or cLLI) drew a warning, so the color fallback applies.
     */
    uint8_t color_warning;
} san_png_report;

/*
 * Creates a decoder that calls *hooks, which the call copies. Returns null
 * when an allocation failed or libpng refused the setup.
 */
san_png_decoder *san_png_create(const san_png_hooks *hooks);

/*
 * Feeds the next len bytes of the encoded image, which the call only reads.
 * Returns SAN_PNG_STATUS_NEED_INPUT, SAN_PNG_STATUS_ENDED, or a terminal
 * status. Bytes after IEND end the decode as SAN_PNG_STATUS_INVALID, in
 * this call or a later one.
 */
san_png_status san_png_feed(
    san_png_decoder *decoder,
    const uint8_t *bytes,
    size_t len);

/*
 * Ends the input. Returns SAN_PNG_STATUS_DONE after SAN_PNG_STATUS_ENDED,
 * and otherwise a terminal status.
 */
san_png_status san_png_finish(san_png_decoder *decoder);

/*
 * Writes the image header to *header and returns one once libpng has read
 * IHDR. Returns zero before IHDR and after a terminal status.
 */
int32_t san_png_get_header(
    san_png_decoder *decoder,
    san_png_header *header);

/* Writes the records of the decoder to *report. */
void san_png_get_report(
    const san_png_decoder *decoder,
    san_png_report *report);

/*
 * Releases the codec context and the decoder object through the free hook.
 * Ignores null.
 */
void san_png_destroy(san_png_decoder *decoder);

#endif /* SAN_PNG_ADAPTER_H */
