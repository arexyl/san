//! The Android harness of libsan_canary_test.so, the device test library
//! of the stack protector. It needs the library through DT_NEEDED and
//! runs beside it on the device:
//! `LD_LIBRARY_PATH=. ./san-canary-harness <mode>`.
//!
//! Modes:
//! - `control`: a write that fills the buffer exactly. It returns, and
//!   the harness prints a summary and exits 0.
//! - `overflow`: a write that runs over the canary. The stack protector
//!   ends the process, so this mode passes only when the process dies of
//!   a signal. A return is a failure: the harness prints a summary and
//!   exits 1.
//!
//! The harness exits 2 on a usage error.

const std = @import("std");

pub const panic = @import("engine").android_panic;

pub const std_options: std.Options = .{
    // The failure of the stack protector reaches the system's crash
    // handler unchanged, so that the tombstone records it.
    .enable_segfault_handler = false,
};

/// The one export of libsan_canary_test.so.
extern fn san_canary_test(count: usize) void;

/// The size of the buffer of the test, and a count that runs over the
/// canary behind it.
const buffer_len = 16;
const overflow_len = 64;

const usage = "usage: san-canary-harness control | overflow\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const mode = if (args.len == 2) args[1] else "";

    var buffer: [256]u8 = undefined;

    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);

    const out = &stdout.interface;

    if (std.mem.eql(u8, mode, "control")) {
        san_canary_test(buffer_len);

        try out.writeAll("control ok\nsummary passed=1 failed=0\n");
        try out.flush();

        return 0;
    }

    if (std.mem.eql(u8, mode, "overflow")) {
        try out.writeAll("overflow starts\n");
        try out.flush();

        san_canary_test(overflow_len);

        try out.writeAll("overflow FAIL\nsummary passed=0 failed=1\n");
        try out.flush();

        return 1;
    }

    try std.Io.File.stderr().writeStreamingAll(io, usage);

    return 2;
}
