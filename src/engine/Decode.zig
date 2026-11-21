//! The decode of one live job: its codec, the admission of its image,
//! and the rows that it writes into the job's lease. A decode is the
//! target of its codec.
//!
//! A decode lives in the slot of its job, which never moves, from the
//! job's first step until its terminal outcome, because the codec calls
//! back with the address of the decode.
//!
//! The admission step of the job runs when the codec describes the
//! image, once, before the first row. It checks in this order: the image
//! limits, the region and the scale that the request left open, and the
//! byte ceilings of the lease, whose pixels it then allocates whole. It
//! records the image and the output grid once the image limits pass,
//! whatever the later checks decide, so that a refused request can be
//! followed by one that fits.
//!
//! This build writes the whole image at a scale of 1:1, and each row
//! enters the lease as its codec delivers it.

const std = @import("std");
const Codec = @import("Codec.zig");
const Engine = @import("Engine.zig");
const Job = @import("Job.zig");
const Lease = @import("Lease.zig");

const Decode = @This();

engine: *Engine,
/// The lease of the job. The admission step allocates its pixels.
lease: *Lease,
requested: Job.Request,
/// The codec, once `open` returned it.
codec: Codec,
/// The image and its output grid, once the image limits passed.
admission: ?Admission = null,
/// Whether the admission step admitted the lease, which then has its
/// pixels.
admitted: bool = false,
/// The image rows that the codec delivered. Each is in the lease.
rows: u32 = 0,

/// An image with the output grid of a request for it: the whole image
/// scaled uniformly to the largest output width, and never scaled up.
pub const Admission = struct {
    image: Codec.Image,
    output_width: u32,
    output_height: u32,

    /// Returns the grid of `image` under `max_output_width`, where 0
    /// asks for a scale of 1:1. The height rounds to the nearest row,
    /// halves up, and is at least one row.
    fn of(image: Codec.Image, max_output_width: u31) Admission {
        const output_width = if (max_output_width == 0)
            image.width
        else
            @min(max_output_width, image.width);

        // Both axes fit 31 bits, so no term leaves 64 bits.
        const doubled =
            2 * @as(u64, image.height) * output_width + image.width;

        const rows = @max(1, doubled / (2 * @as(u64, image.width)));

        return .{
            .image = image,
            .output_width = output_width,
            .output_height = @intCast(rows),
        };
    }
};

/// Returns the decode of a job of `engine` that writes into `lease`
/// under `requested`, without its codec.
pub fn init(engine: *Engine, lease: *Lease, requested: Job.Request) Decode {
    return .{
        .engine = engine,
        .lease = lease,
        .requested = requested,
        .codec = undefined,
    };
}

/// Opens the codec of `decode`, which stays in place from here on. A
/// failure leaves no codec.
pub fn open(decode: *Decode, cancel: Codec.Cancel) Codec.Error!void {
    const opener = decode.engine.opener;

    const target: Codec.Target = .{
        .ctx = decode,
        .admit = admit,
        .row = write,
    };

    decode.codec = try opener.open(
        opener.ptr,
        &decode.engine.heap,
        target,
        cancel,
    );
}

/// Releases the codec of `decode`.
pub fn close(decode: *Decode) void {
    decode.codec.vtable.destroy(decode.codec.ptr);
}

pub fn feed(decode: *Decode, bytes: []const u8) Codec.Error!Codec.Demand {
    return decode.codec.vtable.feed(decode.codec.ptr, bytes);
}

pub fn finish(decode: *Decode) Codec.Error!void {
    return decode.codec.vtable.finish(decode.codec.ptr);
}

/// The admission step. A refusal ends the job with its category.
fn admit(ctx: *anyopaque, image: Codec.Image) Codec.Refusal!void {
    const decode: *Decode = @ptrCast(@alignCast(ctx));
    const engine = decode.engine;

    // The codec describes one image, with both axes at least 1.
    std.debug.assert(decode.admission == null);
    std.debug.assert(image.width != 0 and image.height != 0);

    if (image.width > engine.image_axis_pixels) return error.BudgetExceeded;
    if (image.height > engine.image_axis_pixels) return error.BudgetExceeded;

    // Both axes fit 31 bits, so the area fits 64 bits.
    if (@as(u64, image.width) * image.height > engine.image_area_pixels) {
        return error.BudgetExceeded;
    }

    const admission: Admission = .of(image, decode.requested.max_output_width);

    decode.admission = admission;

    // A region that leaves the image and one that this build does not
    // decode both fail before the byte ceilings, so that neither reads
    // as a lease that is too large.
    if (decode.requested.region) |region| {
        const whole = region.left == 0 and region.top == 0 and
            region.right == image.width and region.bottom == image.height;

        if (!whole) return error.UnsupportedOperation;
    }

    if (admission.output_width != image.width) {
        return error.UnsupportedOperation;
    }

    try decode.lease.allocate(
        engine,
        admission.output_width,
        admission.output_height,
    );

    decode.admitted = true;
}

/// Writes one row of the image into the lease, as pixels of R, G, B,
/// and an alpha of 255. This build wants every row of the image.
fn write(ctx: *anyopaque, index: u32, samples: []const u8) Codec.Demand {
    const decode: *Decode = @ptrCast(@alignCast(ctx));

    // The codec delivers each row of an admitted image once, in order.
    std.debug.assert(decode.admitted);
    std.debug.assert(index == decode.rows);

    const image = decode.admission.?.image;
    const pixels = decode.lease.row(index);

    switch (image.layout) {
        .rgb8 => {
            std.debug.assert(samples.len == @as(usize, image.width) * 3);

            for (0..image.width) |column| {
                const pixel = pixels[column * Lease.pixel_bytes ..];

                pixel[0..3].* = samples[column * 3 ..][0..3].*;
                pixel[3] = 0xff;
            }
        },
    }

    decode.rows = index + 1;

    return .more;
}

const testing = std.testing;

fn imageOf(width: u31, height: u31) Codec.Image {
    return .{ .width = width, .height = height, .layout = .rgb8 };
}

test "a width of zero or of at least the image width keeps the image grid" {
    const image = imageOf(1600, 2400);

    for ([_]u31{ 0, 1600, 1601, std.math.maxInt(u31) }) |max_output_width| {
        try testing.expectEqual(Admission{
            .image = image,
            .output_width = 1600,
            .output_height = 2400,
        }, Admission.of(image, max_output_width));
    }
}

test "a smaller width scales the height to the nearest row, halves up" {
    const Case = struct { width: u31, height: u31, cap: u31, rows: u32 };

    const cases = [_]Case{
        // 40000 * 1080 / 1440 is exact.
        .{ .width = 1440, .height = 40000, .cap = 1080, .rows = 30000 },
        // 5 * 1 / 2 is 2.5, which rounds up.
        .{ .width = 2, .height = 5, .cap = 1, .rows = 3 },
        // 4 * 1 / 3 is 1.33, and 5 * 1 / 3 is 1.67.
        .{ .width = 3, .height = 4, .cap = 1, .rows = 1 },
        .{ .width = 3, .height = 5, .cap = 1, .rows = 2 },
        // 1 * 1 / 3 rounds to no row, and the grid keeps one.
        .{ .width = 3, .height = 1, .cap = 1, .rows = 1 },
    };

    for (cases) |case| {
        const admission: Admission =
            .of(imageOf(case.width, case.height), case.cap);

        try testing.expectEqual(case.cap, admission.output_width);
        try testing.expectEqual(case.rows, admission.output_height);
    }
}

test "the grid of the largest image stays within 64 bits" {
    const largest = std.math.maxInt(u31);

    const admission: Admission = .of(imageOf(largest, largest), 0);

    try testing.expectEqual(largest, admission.output_width);
    try testing.expectEqual(largest, admission.output_height);
}
