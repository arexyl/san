//! zlib's Adler-32, the check of a zlib stream, which `inflate` computes
//! over every byte that it produces. The build leaves zlib's own
//! `adler32.c` out, which adds one byte at a time, and zlib's calls bind
//! the function of this file. A step here adds 16 bytes as one vector,
//! which compiles to the baseline of each target, so nothing detects a
//! feature at run time.
//!
//! The checksum holds two sums modulo 65521: `a`, one plus every byte,
//! and `b`, the sum of every value that `a` took. A block of n bytes
//! adds its bytes to `a`, and to `b` n times the earlier `a` plus each
//! byte times the count of bytes from it to the end of the block.

const std = @import("std");

/// The largest prime below 65536.
const base = 65521;

/// The bytes of one vector step.
const step = 16;

/// The most bytes that two sums below `base` take before 32 bits
/// overflow, zlib's NMAX, which is a whole count of steps.
const span = 5552;

const Wide = @Vector(step, u16);

/// The count of bytes from each byte of a step to the end of the step.
const weights: Wide = .{ 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };

comptime {
    std.debug.assert(span % step == 0);

    // Hidden, as every C symbol of the codecs is: only zlib binds it.
    @export(&adler32, .{ .name = "adler32", .visibility = .hidden });
}

/// zlib's `adler32`: `adler` over `len` more bytes at `buf`, and the
/// checksum of no byte for a null `buf`.
fn adler32(adler: c_ulong, buf: ?[*]const u8, len: c_uint) callconv(.c) c_ulong {
    const bytes = buf orelse return 1;

    return update(@truncate(adler), bytes[0..len]);
}

/// Returns `checksum` over `bytes` more. Both sums of `checksum` are
/// below `base`, as those of every result are.
pub fn update(checksum: u32, bytes: []const u8) u32 {
    var a: u32 = checksum & 0xffff;
    var b: u32 = checksum >> 16;
    var rest = bytes;

    while (rest.len != 0) {
        var chunk = rest[0..@min(rest.len, span)];

        rest = rest[chunk.len..];

        while (chunk.len >= step) {
            const block: @Vector(step, u8) = chunk[0..step].*;
            const wide: Wide = block;

            // A product is at most 16 times 255, and the sum of all at
            // most 136 times 255, so neither leaves 16 bits.
            b += step * a + @reduce(.Add, wide *% weights);
            a += @reduce(.Add, wide);
            chunk = chunk[step..];
        }

        for (chunk) |byte| {
            a += byte;
            b += a;
        }

        a %= base;
        b %= base;
    }

    return b << 16 | a;
}

const testing = std.testing;

/// The checksum by its definition, one byte and two reductions at a time.
fn reference(checksum: u32, bytes: []const u8) u32 {
    var a: u32 = checksum & 0xffff;
    var b: u32 = checksum >> 16;

    for (bytes) |byte| {
        a = (a + byte) % base;
        b = (b + a) % base;
    }

    return b << 16 | a;
}

/// Fills `bytes` with values that repeat in no short period.
fn fill(bytes: []u8) void {
    var state: u32 = 0x9e3779b9;

    for (bytes) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 24);
    }
}

test "known checksums" {
    try testing.expectEqual(1, update(1, ""));
    try testing.expectEqual(0x00620062, update(1, "a"));
    try testing.expectEqual(0x024d0127, update(1, "abc"));
    try testing.expectEqual(0x11e60398, update(1, "Wikipedia"));
}

test "every short length at every offset equals the definition" {
    var bytes: [3 * step + 3 + 3]u8 = undefined;

    fill(&bytes);

    for (0..4) |offset| {
        for (0..bytes.len - offset + 1) |len| {
            const part = bytes[offset..][0..len];

            try testing.expectEqual(reference(1, part), update(1, part));
        }
    }
}

test "lengths around the span equal the definition" {
    var bytes: [3 * span + step + 1]u8 = undefined;

    fill(&bytes);

    const lengths = [_]usize{
        span - step - 1, span - 1,     span,         span + 1,
        span + step,     2 * span - 1, 2 * span + 7, bytes.len,
    };

    for (lengths) |len| {
        try testing.expectEqual(reference(1, bytes[0..len]), update(1, bytes[0..len]));
    }
}

test "the largest sums over the largest bytes stay within 32 bits" {
    const bytes: [2 * span + step + 5]u8 = @splat(0xff);
    const largest = (base - 1) << 16 | (base - 1);

    try testing.expectEqual(reference(largest, &bytes), update(largest, &bytes));
}

test "a checksum continues over the parts of its bytes" {
    var bytes: [span + 100]u8 = undefined;

    fill(&bytes);

    const whole = update(1, &bytes);

    for ([_]usize{ 0, 1, step - 1, step, 37, span, bytes.len }) |cut| {
        try testing.expectEqual(whole, update(update(1, bytes[0..cut]), bytes[cut..]));
    }
}

test "the function that zlib calls starts at one and takes a null buffer" {
    const bytes = "Wikipedia";

    try testing.expectEqual(1, adler32(0, null, 0));
    try testing.expectEqual(1, adler32(7, null, 9));
    try testing.expectEqual(0x11e60398, adler32(1, bytes, bytes.len));

    // zlib reads the low 32 bits of the checksum and nothing above them.
    try testing.expectEqual(0x11e60398, adler32(0x1_0000_0001, bytes, bytes.len));
}
