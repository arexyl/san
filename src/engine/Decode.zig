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
//! byte ceilings of the lease, whose pixels it then allocates whole,
//! before the words of a scale. It
//! records the image and the output grid once the image limits pass,
//! whatever the later checks decide, so that a refused request can be
//! followed by one that fits.
//!
//! This build writes rows of every column: the whole image or a band of
//! its rows, at the image size or scaled down by the area average of
//! `Scale`. The codec delivers the rows above a band too, which the
//! decode only counts, and a band that ends above the last row of the
//! image satisfies the decode at its last row, so that the codec reads
//! no further. A row enters the lease when the image row that completes
//! it arrives.

const std = @import("std");
const Codec = @import("Codec.zig");
const Engine = @import("Engine.zig");
const Job = @import("Job.zig");
const Lease = @import("Lease.zig");
const Scale = @import("Scale.zig");

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
/// The rows of an admitted lease.
band: Band = undefined,
/// The scale of an admitted output below the image size.
scale: ?Scale = null,
/// The words of the scale, a block of the engine's heap.
workspace: ?[]u64 = null,
/// The image rows that the codec delivered.
rows: u32 = 0,
/// The rows of the lease that are written, from its top.
written: u32 = 0,

/// The rows of a lease in the output grid, and the image rows that they
/// cover.
pub const Band = struct {
    /// The grid row of the first row of the lease.
    top: u32,
    height: u32,
    /// The image rows [first, end) that the rows of the lease cover.
    first: u32,
    end: u32,

    /// Returns the grid rows that the image rows [top, bottom) of
    /// `admission` intersect, with the image rows that those cover.
    fn of(admission: Admission, top: u31, bottom: u31) Band {
        const image_height = admission.image.height;
        const height = admission.output_height;

        // Both axes fit 31 bits, so no term leaves 64 bits.
        const grid_top = @as(u64, top) * height / image_height;

        const grid_end =
            (@as(u64, bottom) * height + image_height - 1) / image_height;

        return .{
            .top = @intCast(grid_top),
            .height = @intCast(grid_end - grid_top),
            .first = Scale.firstSource(
                image_height,
                height,
                @intCast(grid_top),
            ),
            .end = Scale.endSource(image_height, height, @intCast(grid_end)),
        };
    }
};

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

/// Releases the codec of `decode` and the words of its scale.
pub fn close(decode: *Decode) void {
    decode.codec.vtable.destroy(decode.codec.ptr);

    if (decode.workspace) |workspace| decode.engine.heap.free(workspace.ptr);
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

    const region: Job.Request.Region = decode.requested.region orelse .{
        .left = 0,
        .top = 0,
        .right = image.width,
        .bottom = image.height,
    };

    // A region that leaves the image and one that this build does not
    // decode both fail before the byte ceilings, so that neither reads
    // as a lease that is too large.
    if (region.right > image.width or region.bottom > image.height) {
        return error.UnsupportedOperation;
    }

    if (region.left != 0 or region.right != image.width) {
        return error.UnsupportedOperation;
    }

    const scaled = admission.output_width != image.width;

    // The sums of a scale are exact only up to this area.
    if (scaled and @as(u64, image.width) * image.height > Scale.area_limit) {
        return error.UnsupportedOperation;
    }

    const band: Band = .of(admission, region.top, region.bottom);

    try decode.lease.allocate(engine, admission.output_width, band.height);

    // A decode that fails here ends its job, which reclaims the lease.
    if (scaled) {
        const words = Scale.words(admission.output_width);

        const bytes = std.math.mul(usize, words, @sizeOf(u64)) catch
            return error.BudgetExceeded;

        const memory = engine.heap.alloc(bytes) orelse
            return engine.heap.takeRefusal() orelse error.AllocationFailed;

        const workspace: [*]u64 = @ptrCast(memory);

        decode.workspace = workspace[0..words];

        decode.scale = .init(
            workspace[0..words],
            image.width,
            image.height,
            admission.output_width,
            admission.output_height,
            band.top,
        );
    }

    decode.band = band;
    decode.admitted = true;
}

/// Takes one row of the image. A row of the band enters the lease as
/// pixels of R, G, B, and an alpha of 255, or adds to the scale, whose
/// complete rows enter the lease.
fn write(ctx: *anyopaque, index: u32, samples: []const u8) Codec.Demand {
    const decode: *Decode = @ptrCast(@alignCast(ctx));

    // The codec delivers each row of an admitted image once, in order.
    std.debug.assert(decode.admitted);
    std.debug.assert(index == decode.rows);

    const image = decode.admission.?.image;
    const band = decode.band;

    decode.rows = index + 1;

    if (index < band.first) return .more;

    std.debug.assert(index < band.end);

    switch (image.layout) {
        .rgb8 => {
            std.debug.assert(samples.len == @as(usize, image.width) * 3);

            if (decode.scale) |*scale| {
                if (scale.add(index, samples)) {
                    scale.emit(decode.lease.row(decode.written));
                    decode.written += 1;
                }
            } else {
                expand(decode.lease.row(decode.written), samples);
                decode.written += 1;
            }
        },
    }

    // A job whose rows end with the image runs to the end of the image,
    // so that its codec checks the whole input.
    if (decode.rows == band.end and band.end != image.height) {
        return .satisfied;
    }

    return .more;
}

/// The pixels that one step of `expand` writes.
const step_pixels = 4;

/// The sample bytes that one step of `expand` reads: those of its pixels
/// and the four after them, which it drops.
const step_samples = 16;

/// Writes the RGB samples of a row as opaque pixels.
///
/// A step reorders 16 sample bytes at once into the pixels of the first
/// 12, so the steps end where fewer than 16 sample bytes remain, and the
/// last pixels go one by one. The vector compiles to the baseline of
/// each target, so nothing detects a feature at run time.
fn expand(pixels: []u8, samples: []const u8) void {
    comptime std.debug.assert(step_pixels * Lease.pixel_bytes == step_samples);

    std.debug.assert(samples.len % 3 == 0);
    std.debug.assert(pixels.len == samples.len / 3 * Lease.pixel_bytes);

    const Step = @Vector(step_samples, u8);

    // The alpha comes from the bits below and not from a second operand of
    // the shuffle: a shuffle of the samples with a vector of 0xff compiles
    // to moves of single bytes on arm64, and this one to a table lookup.
    // The index of an alpha byte is any valid one.
    const order: @Vector(step_samples, i32) = .{
        0, 1, 2, 0, 3, 4,  5,  0,
        6, 7, 8, 0, 9, 10, 11, 0,
    };

    const alpha: Step = .{
        0, 0, 0, 0xff, 0, 0, 0, 0xff,
        0, 0, 0, 0xff, 0, 0, 0, 0xff,
    };

    var source = samples;
    var target = pixels;

    while (source.len >= step_samples) {
        const rgb: Step = source[0..step_samples].*;

        target[0..step_samples].* = @shuffle(u8, rgb, undefined, order) | alpha;
        source = source[step_pixels * 3 ..];
        target = target[step_samples..];
    }

    while (source.len != 0) {
        target[0..3].* = source[0..3].*;
        target[3] = 0xff;
        source = source[3..];
        target = target[Lease.pixel_bytes..];
    }
}

const testing = std.testing;

test "a row of samples becomes opaque pixels at every width" {
    const widest = 40;
    const guard = 0xa5;

    var samples: [3 * widest]u8 = undefined;

    // No sample equals the alpha of a pixel or the guard.
    for (&samples, 0..) |*sample, index| sample.* = @intCast(index + 1);

    for (0..widest + 1) |width| {
        var row: [8 + Lease.pixel_bytes * widest + 8]u8 = @splat(guard);
        const pixels = row[8..][0 .. width * Lease.pixel_bytes];

        expand(pixels, samples[0 .. width * 3]);

        for (0..width) |column| {
            const pixel = pixels[column * Lease.pixel_bytes ..][0..Lease.pixel_bytes];

            try testing.expectEqualSlices(u8, samples[column * 3 ..][0..3], pixel[0..3]);
            try testing.expectEqual(0xff, pixel[3]);
        }

        // Nothing outside the row changed.
        for (row[0..8]) |byte| try testing.expectEqual(guard, byte);
        for (row[8 + pixels.len ..]) |byte| try testing.expectEqual(guard, byte);
    }
}

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

test "a band holds the grid rows of its region and reads the rows they cover" {
    const Case = struct {
        height: u31,
        cap: u31,
        top: u31,
        bottom: u31,
        band: Band,
    };

    const cases = [_]Case{
        // At the image size, the band is the region.
        .{
            .height = 4,
            .cap = 0,
            .top = 1,
            .bottom = 3,
            .band = .{ .top = 1, .height = 2, .first = 1, .end = 3 },
        },
        .{
            .height = 4,
            .cap = 0,
            .top = 0,
            .bottom = 4,
            .band = .{ .top = 0, .height = 4, .first = 0, .end = 4 },
        },
        // 100 rows scale to 75, so a grid row covers 1.33 image rows. A
        // region on the edges of grid rows reads exactly its rows.
        .{
            .height = 100,
            .cap = 27,
            .top = 40,
            .bottom = 60,
            .band = .{ .top = 30, .height = 15, .first = 40, .end = 60 },
        },
        // A region inside those edges holds the same grid rows, so it
        // reads one row above and one below itself.
        .{
            .height = 100,
            .cap = 27,
            .top = 41,
            .bottom = 59,
            .band = .{ .top = 30, .height = 15, .first = 40, .end = 60 },
        },
        // One image row of the same image lies in one grid row, which
        // covers a second image row in part.
        .{
            .height = 100,
            .cap = 27,
            .top = 40,
            .bottom = 41,
            .band = .{ .top = 30, .height = 1, .first = 40, .end = 42 },
        },
        // An image row on the edge of two grid rows takes both.
        .{
            .height = 100,
            .cap = 27,
            .top = 41,
            .bottom = 42,
            .band = .{ .top = 30, .height = 2, .first = 40, .end = 43 },
        },
        // The last rows end with the image.
        .{
            .height = 100,
            .cap = 27,
            .top = 99,
            .bottom = 100,
            .band = .{ .top = 74, .height = 1, .first = 98, .end = 100 },
        },
    };

    for (cases) |case| {
        const admission: Admission = .of(imageOf(36, case.height), case.cap);

        try testing.expectEqual(
            case.band,
            Band.of(admission, case.top, case.bottom),
        );
    }
}

test "the grid of the largest image stays within 64 bits" {
    const largest = std.math.maxInt(u31);

    const admission: Admission = .of(imageOf(largest, largest), 0);

    try testing.expectEqual(largest, admission.output_width);
    try testing.expectEqual(largest, admission.output_height);
}
