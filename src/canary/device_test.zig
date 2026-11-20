//! The root of libsan_canary_test.so, the device test library of the
//! stack protector. It has the link shape of San's library, so its C
//! code binds the same __stack_chk_fail as the C code of the San library
//! would: Bionic's, or the copy of compiler_rt when the link takes
//! compiler_rt. Its one export writes a count of bytes into a 16-byte
//! buffer of a C frame.

pub const panic = @import("engine").android_panic;

/// The C function of the test, which every C compile of San hides.
extern fn san_canary_write(count: usize) void;

/// The largest count of a test. A larger one would write far beyond the
/// frames of the test, so it is a bug of the caller.
const max_count = 256;

export fn san_canary_test(count: usize) void {
    if (count > max_count) @panic("the canary test writes 256 bytes at most");

    san_canary_write(count);
}
