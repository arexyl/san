/*
 * The containment adapter of libpng's push reader. It holds no decoding
 * logic: it drives png_process_data, contains libpng's errors with its own
 * jump, and decides from structured records what libpng only warns about.
 *
 * Jump recovery. libpng is built without SETJMP, so it holds no jump code
 * of its own, and an error callback that returned would reach abort. Every
 * entry point arms _setjmp on the jump buffer of the decoder object before
 * its first libpng call, and the error callback, which never returns,
 * leaves libpng through _longjmp on that buffer. Every record that changes
 * after _setjmp lives in the decoder object, never in an automatic object
 * of the function that called _setjmp, whose value would be indeterminate
 * after the jump (C11 7.13.2.1). The jump crosses only C frames: a Zig hook
 * has returned before the adapter raises an error, and the adapter raises
 * one only from its info and row callbacks. After a jump, the adapter only
 * destroys the codec context.
 *
 * Strictness. libpng 1.6.59 tolerates faults that San rejects: it accepts
 * an unknown or compiled-out ancillary chunk before IHDR, after the last
 * row it only warns about a damaged end of the image data stream, it warns
 * about CRC errors in ancillary chunks, it skips bytes after IEND, and its
 * push reader never compares a palette index with the palette.
 * The adapter never reads a message. It classifies each warning by
 * the chunk that png_get_io_chunk_type names, and it observes zlib's
 * inflate for the image data: libpng's compiles rename their one call of
 * inflate to san_png_inflate, which calls zlib's inflate unchanged. A
 * decode completes only when IEND arrives after every row and after the
 * stream returned Z_STREAM_END with exactly the image's filtered size, and
 * no byte follows IEND. It checks that IHDR is the first chunk before
 * libpng sees its bytes, and every sample of a palette image against the
 * palette before the row reaches Zig.
 */

#include "adapter.h"

#include <png.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <zlib.h>

/* The configuration that the containment relies on. */
#if PNG_LIBPNG_VER != 10659
/* On another release, recheck that png_zlib_inflate in pngrutil.c is the
 * one call of inflate, that png_create_png_struct sets zstream.opaque to
 * the final png_struct, and that the push reader holds no saved bytes when
 * it reports IEND. The observer and the trailing-data count rely on them.
 */
#error "the adapter is checked against libpng 1.6.59"
#endif
#ifndef PNG_PROGRESSIVE_READ_SUPPORTED
#error "the adapter drives libpng's push reader"
#endif
#ifdef PNG_SEQUENTIAL_READ_SUPPORTED
#error "the sequential reader must stay out"
#endif
#ifdef PNG_SETJMP_SUPPORTED
#error "libpng must hold no jump of its own, so the adapter's is the only one"
#endif
#ifndef PNG_USER_MEM_SUPPORTED
#error "every allocation of libpng and zlib must reach the allocation hook"
#endif
#ifndef PNG_IO_STATE_SUPPORTED
#error "warnings are classified by png_get_io_chunk_type"
#endif
#ifndef PNG_WARNINGS_SUPPORTED
#error "the warning callback carries the strictness rules"
#endif
#ifndef PNG_BENIGN_READ_ERRORS_SUPPORTED
#error "benign errors must reach the warning callback, never the jump"
#endif
#ifndef PNG_SET_USER_LIMITS_SUPPORTED
#error "San's admission, not libpng's limit, decides a large image"
#endif
#if !defined( PNG_HANDLE_AS_UNKNOWN_SUPPORTED )    \
  || !defined( PNG_READ_UNKNOWN_CHUNKS_SUPPORTED ) \
  || !defined( PNG_SAVE_UNKNOWN_CHUNKS_SUPPORTED ) \
  || !defined( PNG_STORE_UNKNOWN_CHUNKS_SUPPORTED )
#error "acTL is found as a stored unknown chunk"
#endif
#ifdef PNG_DISABLE_ADLER32_CHECK_SUPPORTED
#error "no option may turn off the Adler-32 check of the image data"
#endif

/* libpng's push reader hands zlib one row at a time and counts it in
 * zlib's uInt, so the geometry guard below bounds a row by that type.
 */
_Static_assert( ( uInt ) -1 == UINT32_MAX, "zlib counts a row in 32 bits" );

/* A chunk name as png_get_io_chunk_type returns it. */
#define SAN_PNG_CHUNK( a, b, c, d )                                   \
  ( ( ( png_uint_32 ) ( a ) << 24 ) | ( ( png_uint_32 ) ( b ) << 16 ) \
    | ( ( png_uint_32 ) ( c ) << 8 ) | ( png_uint_32 ) ( d ) )

#define SAN_PNG_IHDR SAN_PNG_CHUNK( 'I', 'H', 'D', 'R' )
#define SAN_PNG_PLTE SAN_PNG_CHUNK( 'P', 'L', 'T', 'E' )
#define SAN_PNG_IDAT SAN_PNG_CHUNK( 'I', 'D', 'A', 'T' )
#define SAN_PNG_IEND SAN_PNG_CHUNK( 'I', 'E', 'N', 'D' )
#define SAN_PNG_tRNS SAN_PNG_CHUNK( 't', 'R', 'N', 'S' )
#define SAN_PNG_gAMA SAN_PNG_CHUNK( 'g', 'A', 'M', 'A' )
#define SAN_PNG_cHRM SAN_PNG_CHUNK( 'c', 'H', 'R', 'M' )
#define SAN_PNG_sRGB SAN_PNG_CHUNK( 's', 'R', 'G', 'B' )
#define SAN_PNG_iCCP SAN_PNG_CHUNK( 'i', 'C', 'C', 'P' )
#define SAN_PNG_cICP SAN_PNG_CHUNK( 'c', 'I', 'C', 'P' )
#define SAN_PNG_mDCV SAN_PNG_CHUNK( 'm', 'D', 'C', 'V' )
#define SAN_PNG_cLLI SAN_PNG_CHUNK( 'c', 'L', 'L', 'I' )

/* The chunk list of png_set_keep_unknown_chunks: acTL alone. */
static const png_byte san_png_actl[ 5 ] = { 'a', 'c', 'T', 'L', '\0' };

/* The PNG signature. The first chunk's length and type follow it, and the
 * PNG specification requires that chunk to be IHDR.
 */
static const uint8_t san_png_signature[ 8 ] = {
  0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
};
static const uint8_t san_png_ihdr_type[ 4 ] = { 'I', 'H', 'D', 'R' };

/* The offset of the first chunk's type in the input, after the signature
 * and the chunk's length, and the end of that type.
 */
#define SAN_PNG_FIRST_TYPE 12
#define SAN_PNG_HEAD       16

struct san_png_decoder {
  /* The target of every jump out of libpng. */
  jmp_buf       jump;
  san_png_hooks hooks;
  png_structp   png;
  png_infop     info;
  /* The encoded size of one row, set at the first IDAT. */
  size_t row_bytes;
  /* The entries of the palette of a palette image, set at the first
   * IDAT.
   */
  uint32_t palette_entries;
  /* The pixels of one row, set at the first IDAT. */
  uint32_t width;
  /* The filtered size of the image: a filter byte and the encoded bytes
   * of every row.
   */
  uint64_t expected;
  /* What inflate produced for IDAT. */
  uint64_t produced;
  /* The bytes that followed IEND in its input portion. */
  size_t   trailing;
  uint32_t height;
  /* The rows delivered so far. */
  uint32_t       rows;
  uint32_t       warnings;
  san_png_status status;
  san_png_reason reason;
  /* The bits of one sample, set at the first IDAT. */
  uint8_t bit_depth;
  /* The image is a palette image: its samples index the palette. */
  uint8_t indexed;
  /* inflate returned Z_STREAM_END for IDAT. */
  uint8_t stream_end;
  /* The info callback has run. */
  uint8_t info_seen;
  /* The adapter itself is calling libpng from a callback. */
  uint8_t own_call;
  /* The end callback has run. */
  uint8_t ended;
  uint8_t color_warning;
  /* The bytes of the input so far, up to SAN_PNG_HEAD. */
  uint8_t head;
};

/* San's heap aligns its blocks to 16 bytes. */
_Static_assert( _Alignof( struct san_png_decoder ) <= 16,
                "the decoder object fits the heap's alignment" );

/* Returns the decoder object of png. libpng sets the error pointer on its
 * temporary creation struct too, so every callback finds the decoder the
 * same way, png_create_read_struct_2 included.
 */
static san_png_decoder *san_png_owner( png_const_structrp png ) {
  return png_get_error_ptr( png );
}

/* Records reason as the cause of the end unless another came first. */
static void san_png_fault( san_png_decoder *decoder, san_png_reason reason ) {
  if ( decoder->reason == SAN_PNG_REASON_NONE )
    decoder->reason = reason;
}

/* Ends the decode with the status of its first recorded reason, or of
 * reason when none is recorded, and returns that status.
 */
static san_png_status san_png_conclude( san_png_decoder *decoder,
                                        san_png_reason   reason ) {
  san_png_fault( decoder, reason );

  switch ( decoder->reason ) {
    case SAN_PNG_REASON_STOPPED :
      decoder->status = SAN_PNG_STATUS_STOPPED;
      break;
    case SAN_PNG_REASON_ANIMATED :
      decoder->status = SAN_PNG_STATUS_ANIMATED;
      break;
    case SAN_PNG_REASON_TRUNCATED :
      decoder->status = SAN_PNG_STATUS_TRUNCATED;
      break;
    default :
      decoder->status = SAN_PNG_STATUS_INVALID;
      break;
  }

  return decoder->status;
}

/* Records reason and leaves libpng through the error callback. Only the
 * info and row callbacks call it.
 */
static PNG_NORETURN void san_png_raise( png_const_structrp png,
                                        san_png_decoder   *decoder,
                                        san_png_reason     reason ) {
  san_png_fault( decoder, reason );
  png_error( png, "San ends the decode" );
}

/* Reports whether the image data stream ended verified: inflate returned
 * Z_STREAM_END after producing exactly the image's filtered size.
 */
static int san_png_verified( const san_png_decoder *decoder ) {
  return decoder->stream_end && decoder->produced == decoder->expected;
}

/* Reads the image header that libpng stored from IHDR. */
static void san_png_read_header( png_const_structrp png, png_const_inforp info,
                                 san_png_header *header ) {
  uint64_t bits;

  header->width      = png_get_image_width( png, info );
  header->height     = png_get_image_height( png, info );
  header->bit_depth  = png_get_bit_depth( png, info );
  header->color_type = png_get_color_type( png, info );
  header->interlace  = png_get_interlace_type( png, info );
  header->channels   = png_get_channels( png, info );

  header->transparency = png_get_valid( png, info, PNG_INFO_tRNS ) != 0;

  /* At most 2^31 - 1 pixels of 64 bits: no overflow. */
  bits = ( uint64_t ) header->width * header->channels * header->bit_depth;
  header->row_bytes = ( bits + 7 ) / 8;
}

/* Reports whether every sample of row, a row of a palette image, indexes
 * an entry of the palette. The PNG specification makes an index beyond the
 * palette an error. libpng's push reader checks it only while it applies
 * row transformations and reports it nowhere; only the sequential reader's
 * png_read_end does. A row packs its samples from the most significant
 * bit, and the unused bits at its end are no sample.
 */
static int san_png_indexes_valid( const san_png_decoder *decoder,
                                  png_const_bytep        row ) {
  unsigned depth = decoder->bit_depth;
  unsigned mask  = ( 1u << depth ) - 1u;
  uint32_t column;

  /* A palette with an entry for every index of the depth holds them all. */
  if ( decoder->palette_entries > mask )
    return 1;

  for ( column = 0; column < decoder->width; column += 1 ) {
    uint64_t bit   = ( uint64_t ) column * depth;
    unsigned shift = 8u - depth - ( unsigned ) ( bit % 8u );
    unsigned index = ( row[ bit / 8u ] >> shift ) & mask;

    if ( index >= decoder->palette_entries )
      return 0;
  }

  return 1;
}

/* The error callback. It never returns: it leaves libpng through the jump
 * that the running entry point armed.
 */
static PNG_NORETURN void san_png_error( png_structp     png,
                                        png_const_charp message ) {
  san_png_decoder *decoder = san_png_owner( png );

  ( void ) message;
  _longjmp( decoder->jump, 1 );
}

/* The warning callback. It only records, because libpng warns in the
 * middle of an operation that completes only after a normal return. It
 * classifies by the chunk that libpng is handling:
 * - IHDR, tRNS, IEND, and the PLTE of a palette image hold image-essential
 *   data, so a warning there fails the decode;
 * - a warning in IDAT before the verified end of the stream is a stream
 *   fault; after that end, it concerns unused bytes, which San ignores;
 * - optional color metadata takes the color fallback;
 * - any other warning is a diagnostic.
 * A warning during the adapter's own call of libpng concerns that call,
 * not the input, and stays a diagnostic.
 */
static void san_png_warning( png_structp png, png_const_charp message ) {
  san_png_decoder *decoder = san_png_owner( png );

  ( void ) message;

  if ( decoder->warnings != UINT32_MAX )
    decoder->warnings += 1;

  if ( decoder->own_call )
    return;

  switch ( png_get_io_chunk_type( png ) ) {
    case SAN_PNG_IHDR :
    case SAN_PNG_tRNS :
    case SAN_PNG_IEND :
      san_png_fault( decoder, SAN_PNG_REASON_ESSENTIAL );
      break;
    case SAN_PNG_PLTE :
      if ( png_get_color_type( png, decoder->info ) == PNG_COLOR_TYPE_PALETTE )
        san_png_fault( decoder, SAN_PNG_REASON_ESSENTIAL );
      break;
    case SAN_PNG_IDAT :
      if ( !san_png_verified( decoder ) )
        san_png_fault( decoder, SAN_PNG_REASON_STREAM );
      break;
    case SAN_PNG_gAMA :
    case SAN_PNG_cHRM :
    case SAN_PNG_sRGB :
    case SAN_PNG_iCCP :
    case SAN_PNG_cICP :
    case SAN_PNG_mDCV :
    case SAN_PNG_cLLI :
      decoder->color_warning = 1;
      break;
    default :
      break;
  }
}

/* The allocation callback. It returns null on a refusal and never jumps,
 * because libpng and zlib go on after a null from png_malloc_warn,
 * png_malloc_base, or zalloc with state that only a normal return
 * completes. The hook records the refusal, which decides the outcome.
 */
static png_voidp san_png_malloc( png_structp png, png_alloc_size_t size ) {
  san_png_decoder *decoder = san_png_owner( png );

  return decoder->hooks.alloc( decoder->hooks.ctx, size );
}

static void san_png_free( png_structp png, png_voidp block ) {
  san_png_decoder *decoder = san_png_owner( png );

  decoder->hooks.free( decoder->hooks.ctx, block );
}

/* Reports whether an acTL chunk precedes the image data. libpng 1.6.59 has
 * no acTL handler; the adapter keeps acTL alone as an unknown chunk, so
 * libpng stores it, and no other unknown chunk.
 */
static int san_png_animated( png_const_structrp png, png_inforp info ) {
  png_unknown_chunkp unknowns = NULL;
  int                count    = png_get_unknown_chunks( png, info, &unknowns );
  int                index;

  for ( index = 0; index < count; index += 1 ) {
    if ( memcmp( unknowns[ index ].name, san_png_actl, 4 ) == 0 )
      return 1;
  }

  return 0;
}

/* The info callback, at the first IDAT chunk. libpng calls it again for an
 * IDAT chunk after another chunk that follows the image data, so a second
 * call fails before any hook or setter.
 */
static void san_png_info( png_structp png, png_infop info ) {
  san_png_decoder *decoder = san_png_owner( png );
  san_png_header   header;

  if ( decoder->info_seen )
    san_png_raise( png, decoder, SAN_PNG_REASON_NONCONSECUTIVE );

  decoder->info_seen = 1;

  /* A fault in a chunk before the image data fails before any row. */
  if ( decoder->reason != SAN_PNG_REASON_NONE )
    san_png_raise( png, decoder, decoder->reason );

  if ( san_png_animated( png, info ) )
    san_png_raise( png, decoder, SAN_PNG_REASON_ANIMATED );

  san_png_read_header( png, info, &header );

  /* A row and its filter byte must fit zlib's 32-bit count. */
  if ( header.row_bytes >= UINT32_MAX )
    san_png_raise( png, decoder, SAN_PNG_REASON_GEOMETRY );

  /* Below 2^31 rows of below 2^32 bytes: no overflow. */
  decoder->row_bytes = ( size_t ) header.row_bytes;
  decoder->height    = header.height;
  decoder->expected  = ( uint64_t ) header.height * ( header.row_bytes + 1 );
  decoder->width     = header.width;
  decoder->bit_depth = header.bit_depth;

  /* libpng fails a palette image without a palette before this call, and
   * holds from 1 to 2^depth entries. An image without a readable palette
   * keeps zero entries, so each of its samples fails the check.
   */
  if ( header.color_type == PNG_COLOR_TYPE_PALETTE ) {
    png_colorp palette = NULL;
    int        entries = 0;

    decoder->indexed = 1;

    if ( png_get_PLTE( png, info, &palette, &entries ) != 0 && entries > 0 )
      decoder->palette_entries = ( uint32_t ) entries;
  }

  if ( decoder->hooks.header( decoder->hooks.ctx, &header )
       != SAN_PNG_CONTINUE )
    san_png_raise( png, decoder, SAN_PNG_REASON_STOPPED );

  decoder->own_call = 1;
  png_read_update_info( png, info );
  decoder->own_call = 0;
}

/* The row callback. The count covers a noninterlaced image, whose rows
 * arrive in order in pass 0; any other row fails the decode.
 */
static void san_png_row( png_structp png, png_bytep row, png_uint_32 index,
                         int pass ) {
  san_png_decoder *decoder = san_png_owner( png );
  san_png_verdict  verdict;

  if ( decoder->reason != SAN_PNG_REASON_NONE )
    san_png_raise( png, decoder, decoder->reason );

  if ( row == NULL || pass != 0 || index != decoder->rows )
    san_png_raise( png, decoder, SAN_PNG_REASON_ROW_ORDER );

  if ( decoder->indexed && !san_png_indexes_valid( decoder, row ) )
    san_png_raise( png, decoder, SAN_PNG_REASON_PALETTE_INDEX );

  verdict
    = decoder->hooks.row( decoder->hooks.ctx, index, row, decoder->row_bytes );

  if ( verdict != SAN_PNG_CONTINUE )
    san_png_raise( png, decoder, SAN_PNG_REASON_STOPPED );

  decoder->rows += 1;
}

/* The end callback, after IEND. It only records: the push reader processes
 * nothing after IEND, and at this point it holds no saved bytes, so the
 * unprocessed rest of the current input is exactly what follows IEND.
 * Pausing with save 0 returns that count and stops the processing.
 */
static void san_png_end( png_structp png, png_infop info ) {
  san_png_decoder *decoder = san_png_owner( png );

  ( void ) info;
  decoder->ended    = 1;
  decoder->trailing = png_process_data_pause( png, 0 );
}

/* The observer of zlib's inflate. libpng's compiles call it in place of
 * inflate, and zlib.h declares it there. It calls zlib's inflate unchanged
 * and records, for IDAT only, the bytes produced, Z_STREAM_END, and any
 * other result than Z_OK as a stream fault. zstream.opaque is the
 * png_struct, which png_create_png_struct sets for zalloc.
 */
int san_png_inflate( z_streamp stream, int flush );

int san_png_inflate( z_streamp stream, int flush ) {
  png_const_structrp png       = stream->opaque;
  san_png_decoder   *decoder   = san_png_owner( png );
  uInt               available = stream->avail_out;
  int                result;

  if ( png_get_io_chunk_type( png ) != SAN_PNG_IDAT )
    return inflate( stream, flush );

  result             = inflate( stream, flush );
  decoder->produced += available - stream->avail_out;

  if ( result == Z_STREAM_END )
    decoder->stream_end = 1;
  else if ( result != Z_OK )
    san_png_fault( decoder, SAN_PNG_REASON_STREAM );

  return result;
}

/* Releases the codec context and the decoder object. */
static void san_png_release( san_png_decoder *decoder ) {
  san_png_hooks hooks = decoder->hooks;

  png_destroy_read_struct( &decoder->png, &decoder->info, NULL );
  hooks.free( hooks.ctx, decoder );
}

san_png_decoder *san_png_create( const san_png_hooks *hooks ) {
  san_png_decoder *decoder = hooks->alloc( hooks->ctx, sizeof *decoder );

  if ( decoder == NULL )
    return NULL;

  memset( decoder, 0, sizeof *decoder );
  decoder->hooks  = *hooks;
  decoder->status = SAN_PNG_STATUS_NEED_INPUT;

  if ( _setjmp( decoder->jump ) != 0 ) {
    san_png_release( decoder );
    return NULL;
  }

  decoder->png = png_create_read_struct_2(
    PNG_LIBPNG_VER_STRING, decoder, san_png_error, san_png_warning, decoder,
    san_png_malloc, san_png_free );

  if ( decoder->png == NULL ) {
    san_png_release( decoder );
    return NULL;
  }

  decoder->info = png_create_info_struct( decoder->png );

  if ( decoder->info == NULL ) {
    san_png_release( decoder );
    return NULL;
  }

  /* libpng keeps its default CRC actions and its read default for benign
   * errors. Its width and height limits open, as libpng's own comment
   * names it, so that San's admission decides the category of a large
   * image. Its chunk cache and chunk allocation limits keep their
   * defaults.
   */
  png_set_keep_unknown_chunks( decoder->png, PNG_HANDLE_CHUNK_ALWAYS,
                               san_png_actl, 1 );

  png_set_user_limits( decoder->png, 0x7fffffff, 0x7fffffff );

  png_set_progressive_read_fn( decoder->png, decoder, san_png_info, san_png_row,
                               san_png_end );

  return decoder;
}

/* Reports whether the next len bytes of the input keep IHDR as the first
 * chunk. libpng 1.6.59 accepts an unknown or compiled-out ancillary chunk
 * before IHDR. The check compares each byte of the first chunk's type as it
 * arrives, so it holds no bytes of its own. A wrong signature ends the
 * check, because libpng rejects the signature itself.
 */
static int san_png_head_valid( san_png_decoder *decoder, const uint8_t *bytes,
                               size_t len ) {
  size_t i;

  for ( i = 0; i < len && decoder->head < SAN_PNG_HEAD; i += 1 ) {
    unsigned at = decoder->head;

    decoder->head += 1;

    if ( at < sizeof san_png_signature ) {
      if ( bytes[ i ] != san_png_signature[ at ] )
        decoder->head = SAN_PNG_HEAD;
    } else if ( at >= SAN_PNG_FIRST_TYPE ) {
      if ( bytes[ i ] != san_png_ihdr_type[ at - SAN_PNG_FIRST_TYPE ] )
        return 0;
    }
  }

  return 1;
}

/* Settles the status after png_process_data returned normally. */
static san_png_status san_png_settle( san_png_decoder *decoder ) {
  if ( decoder->reason != SAN_PNG_REASON_NONE )
    return san_png_conclude( decoder, decoder->reason );

  if ( !decoder->ended )
    return decoder->status = SAN_PNG_STATUS_NEED_INPUT;

  if ( decoder->trailing != 0 )
    return san_png_conclude( decoder, SAN_PNG_REASON_TRAILING );

  if ( decoder->rows != decoder->height || !san_png_verified( decoder ) )
    return san_png_conclude( decoder, SAN_PNG_REASON_INCOMPLETE );

  return decoder->status = SAN_PNG_STATUS_ENDED;
}

san_png_status san_png_feed( san_png_decoder *decoder, const uint8_t *bytes,
                             size_t len ) {
  if ( decoder->status == SAN_PNG_STATUS_ENDED && len != 0 )
    return san_png_conclude( decoder, SAN_PNG_REASON_TRAILING );

  if ( decoder->status != SAN_PNG_STATUS_NEED_INPUT )
    return decoder->status;

  if ( !san_png_head_valid( decoder, bytes, len ) )
    return san_png_conclude( decoder, SAN_PNG_REASON_FIRST_CHUNK );

  if ( _setjmp( decoder->jump ) != 0 )
    return san_png_conclude( decoder, SAN_PNG_REASON_LIBPNG );

  /* libpng only reads the input, although its prototype is not const. */
  png_process_data( decoder->png, decoder->info, ( png_bytep ) bytes, len );

  return san_png_settle( decoder );
}

san_png_status san_png_finish( san_png_decoder *decoder ) {
  if ( decoder->status == SAN_PNG_STATUS_ENDED )
    return decoder->status = SAN_PNG_STATUS_DONE;

  if ( decoder->status != SAN_PNG_STATUS_NEED_INPUT )
    return decoder->status;

  return san_png_conclude( decoder, SAN_PNG_REASON_TRUNCATED );
}

int32_t san_png_get_header( san_png_decoder *decoder, san_png_header *header ) {
  if ( decoder->status != SAN_PNG_STATUS_NEED_INPUT
       && decoder->status != SAN_PNG_STATUS_ENDED )
    return 0;

  if ( _setjmp( decoder->jump ) != 0 ) {
    san_png_conclude( decoder, SAN_PNG_REASON_LIBPNG );
    return 0;
  }

  /* png_set_IHDR raises an error on a zero width, so a nonzero width in a
   * live context means that IHDR passed libpng's checks.
   */
  if ( png_get_image_width( decoder->png, decoder->info ) == 0 )
    return 0;

  san_png_read_header( decoder->png, decoder->info, header );

  return 1;
}

void san_png_get_report( const san_png_decoder *decoder,
                         san_png_report        *report ) {
  report->reason        = decoder->reason;
  report->warnings      = decoder->warnings;
  report->color_warning = decoder->color_warning;
}

void san_png_destroy( san_png_decoder *decoder ) {
  if ( decoder == NULL )
    return;

  /* libpng's release raises no error with San's callbacks; the armed
   * jump keeps the error callback's contract all the same.
   */
  if ( _setjmp( decoder->jump ) != 0 ) {
    decoder->hooks.free( decoder->hooks.ctx, decoder );
    return;
  }

  san_png_release( decoder );
}
