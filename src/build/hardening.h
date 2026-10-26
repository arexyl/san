/* The hardening check of every C compile of San.
 *
 * The build forces this header into every C translation unit with
 * -include. clang applies every -D and -U of the command line before it
 * reads a forced header, so the macros below show the final effect of
 * the compiler's own flags and San's later ones. The header defines and
 * includes nothing, so it needs no include guard. It only fails the
 * compile when a hardening flag did not take effect.
 */

/* FORTIFY stays off: its __*_chk calls would import Bionic's checks or
 * bind the trapping copies of Zig's compiler_rt. Zig 0.17.0 defines
 * _FORTIFY_SOURCE=2 for C in ReleaseSafe, and San's -U_FORTIFY_SOURCE
 * must come after that definition.
 */
#if defined(_FORTIFY_SOURCE)
#error "_FORTIFY_SOURCE is defined: -U_FORTIFY_SOURCE must follow its -D"
#endif

/* Every C function with an array or an address-taken local carries a
 * canary. Zig 0.17.0 passes -fno-stack-protector first to the C of a
 * module without libc, and San's later -fstack-protector-strong must
 * win; clang then sets __SSP_STRONG__ to 2.
 */
#if !defined(__SSP_STRONG__) || __SSP_STRONG__ != 2
#error "the strong stack protector is off: pass -fstack-protector-strong"
#endif

/* On Android arm64, every C object carries BTI and PAC, because the
 * linker drops the property for the whole library when one object lacks
 * it. Every C frame also keeps its return address on the shadow call
 * stack in x18, which the Android target reserves. Neither applies to
 * another target, such as an arm64 macOS host.
 */
#if defined(__aarch64__) && defined(__ANDROID__)

#if !defined(__ARM_FEATURE_BTI_DEFAULT)
#error "BTI is off: pass -mbranch-protection=standard"
#endif

#if !defined(__ARM_FEATURE_PAC_DEFAULT)
#error "PAC is off: pass -mbranch-protection=standard"
#endif

#if !defined(__has_feature)
#error "the compiler cannot report ShadowCallStack: compile with clang"
#else
#if !__has_feature(shadow_call_stack)
#error "ShadowCallStack is off: pass -fsanitize=shadow-call-stack"
#endif
#endif

#endif
