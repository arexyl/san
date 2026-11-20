/* The test-only source of the stack protector test. Only the device test
 * library of that test links it, and it never enters the San library.
 *
 * san_canary_write fills a 16-byte buffer of its own frame with a count of
 * bytes that the caller chooses. A count above 16 runs over the canary of
 * the frame, so the function ends in __stack_chk_fail instead of a return.
 */

#include <stddef.h>

/* Writes count bytes at p. The function is never inlined, so the compiler
 * sees no buffer size at the write: it neither removes the write nor turns
 * it into a bounds trap of its own.
 */
__attribute__( ( noinline ) ) static void fill( volatile unsigned char *p,
                                                size_t count ) {
  for ( size_t i = 0; i < count; i++ ) {
    p[ i ] = ( unsigned char ) i;
  }
}

void san_canary_write( size_t count ) {
  volatile unsigned char buffer[ 16 ];

  fill( buffer, count );
}
