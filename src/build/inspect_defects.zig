//! The root of the deliberately defective libraries of check-inspect.
//!
//! Each library has the link shape of San's libraries and the export set
//! of the PNG device test library, plus one defect that a rule of the
//! inspection must reject. The build selects the defect through the
//! `options` module, links the library, and expects the inspection to
//! exit 1 and name the defect's rule. The library without a defect is
//! the control: it must pass every rule, so that each rejection comes
//! from its defect alone. The build never installs or runs these
//! libraries.
//!
//! Some defects live in the link rather than in this code: an extra name
//! in the version script, a 4 KiB page size, and the libm.so stub as a
//! link input. This root then exports the extra name and calls into
//! libm, so that the link keeps what the defect needs.
//!
//! The link drops a shared library that no symbol binds to, so every
//! library of this root takes Bionic's heap, as every San library does,
//! and needs libc.so like the San library.

const builtin = @import("builtin");
const options = @import("options");

pub const panic = @import("engine").android_panic;

/// Bionic's heap, which the San library takes for its accounted heap.
extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;

/// Two functions of Bionic that no San library may take: getenv is in
/// libc.so but outside the import allowlist, and pow is a function of
/// libm.so, which no San library may need. Zig's compiler_rt holds no
/// pow, so the call binds to libm.so.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn pow(x: f64, y: f64) f64;

/// The declared export of the PNG device test library. Its result
/// depends on the heap and on the selected defect's code, so the link
/// keeps both.
export fn san_png_device_test(input: u64, output: *u64) void {
    const block = malloc(input);

    output.* = @intFromPtr(block) +% defective(input);
    free(block);
}

fn defective(input: u64) u64 {
    return switch (options.defect) {
        .none, .extra_export, .small_pages => input,
        .getenv_import => if (getenv("SAN")) |value| value[0] else input,
        // Both operands vary, so the optimizer cannot replace the call,
        // as it replaces pow(x, 0.5) with a square root.
        .libm_needed => @bitCast(pow(
            @floatFromInt(input),
            @floatFromInt(input >> 1),
        )),
        .svc => supervisorCall(input),
    };
}

comptime {
    if (options.defect == .extra_export) {
        @export(&extra, .{ .name = options.extra_export });
    }
}

/// An export that the artifact does not declare.
fn extra() callconv(.c) void {}

/// An svc instruction, which nothing ever executes. It stands for a raw
/// system call of Zig code without libc, which imports nothing.
fn supervisorCall(input: u64) u64 {
    if (builtin.cpu.arch != .aarch64) {
        @compileError("the svc defect is an arm64 instruction");
    }

    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [arg] "{x0}" (input),
        : .{ .memory = true });
}
