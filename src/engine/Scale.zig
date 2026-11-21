//! The area average of an image that is scaled down to an output grid.
//! Image rows of R, G, and B samples go in, in order, and grid rows of
//! pixels come out as they complete.
//!
//! Each output pixel is the mean of the image area that it covers, where
//! a pixel that it covers in part counts by that part. With an image of
//! w by h pixels and a grid of W by H, one axis is measured in units of
//! which an image column spans W and a grid column w, and the other in
//! units of which an image row spans H and a grid row h. Every overlap is
//! then an integer, and the weights of one output pixel sum to w * h.
//!
//! The sums are exact, and each sample is quantized once: to the nearest
//! value, halves up.

const std = @import("std");

const Scale = @This();

image_width: u32,
image_height: u32,
width: u32,
height: u32,
/// The current image row, summed along the row into each grid column:
/// three sums per column.
across: []u64,
/// The grid row `row` so far: the rows of `across`, each times its
/// overlap with that grid row.
down: []u64,
/// The grid row that `down` holds.
row: u32,
/// The units by which the last image row reaches below the grid row
/// `row`. They belong to the next grid row.
below: u64 = 0,

/// The largest image area whose sums fit 64 bits: a sum is at most 255
/// times the area, and the rounding adds half the area.
pub const area_limit: u64 = 1 << 56;

/// The 64-bit words that a scale to `width` columns works in.
pub fn words(width: u32) usize {
    return @as(usize, width) * 6;
}

/// Returns the scale of an image to a grid that is no larger on either
/// axis, starting at the grid row `first`. `workspace` holds
/// `words(width)` words and stays with the scale.
pub fn init(
    workspace: []u64,
    image_width: u32,
    image_height: u32,
    width: u32,
    height: u32,
    first: u32,
) Scale {
    std.debug.assert(width != 0 and width <= image_width);
    std.debug.assert(height != 0 and height <= image_height);
    std.debug.assert(first < height);
    std.debug.assert(workspace.len == words(width));

    std.debug.assert(
        @as(u64, image_width) * image_height <= area_limit,
    );

    const half = workspace.len / 2;

    @memset(workspace[half..], 0);

    return .{
        .image_width = image_width,
        .image_height = image_height,
        .width = width,
        .height = height,
        .across = workspace[0..half],
        .down = workspace[half..],
        .row = first,
    };
}

/// Returns the first image row that the grid row `row` covers, in an
/// image of `image_height` rows and a grid of `height`.
pub fn firstSource(image_height: u32, height: u32, row: u32) u32 {
    return @intCast(@as(u64, row) * image_height / height);
}

/// Returns the image row after the last one that the grid rows before
/// `end` cover.
pub fn endSource(image_height: u32, height: u32, end: u32) u32 {
    const units = @as(u64, end) * image_height;

    return @intCast((units + height - 1) / height);
}

/// Adds the image row `index`, which the current grid row covers, and
/// returns whether that grid row is complete. A complete row is taken
/// with `emit` before the next image row.
pub fn add(scale: *Scale, index: u32, samples: []const u8) bool {
    std.debug.assert(samples.len == @as(usize, scale.image_width) * 3);
    std.debug.assert(scale.below == 0);

    const top = @as(u64, index) * scale.height;
    const bottom = top + scale.height;
    const row_top = @as(u64, scale.row) * scale.image_height;
    const row_bottom = row_top + scale.image_height;

    std.debug.assert(top < row_bottom and bottom > row_top);

    scale.sumAcross(samples);
    scale.addDown(@min(bottom, row_bottom) - @max(top, row_top));

    if (bottom < row_bottom) return false;

    scale.below = bottom - row_bottom;

    return true;
}

/// Writes the complete grid row into `pixels` as R, G, B, and an alpha
/// of 255, and starts the next grid row with the part of the last image
/// row that reaches into it.
pub fn emit(scale: *Scale, pixels: []u8) void {
    std.debug.assert(pixels.len == @as(usize, scale.width) * 4);

    const area = @as(u64, scale.image_width) * scale.image_height;

    for (0..scale.width) |column| {
        const pixel = pixels[column * 4 ..][0..4];

        for (scale.down[column * 3 ..][0..3], pixel[0..3]) |sum, *sample| {
            sample.* = @intCast((sum + area / 2) / area);
        }

        pixel[3] = 0xff;
    }

    @memset(scale.down, 0);
    scale.row += 1;

    // The last grid row ends with the image, so nothing reaches below it.
    if (scale.below != 0) scale.addDown(scale.below);

    scale.below = 0;
}

/// Sums the samples of one image row into each grid column, each
/// sample times the units of the column that it covers.
fn sumAcross(scale: *Scale, samples: []const u8) void {
    const image_width: u64 = scale.image_width;
    const width: u64 = scale.width;

    for (0..scale.width) |column| {
        const left = column * image_width;
        const right = left + image_width;

        var sums: [3]u64 = @splat(0);
        var source: usize = @intCast(left / width);

        while (source * width < right) : (source += 1) {
            const covered =
                @min((source + 1) * width, right) - @max(source * width, left);

            for (&sums, samples[source * 3 ..][0..3]) |*sum, sample| {
                sum.* += covered * sample;
            }
        }

        scale.across[column * 3 ..][0..3].* = sums;
    }
}

/// Adds the sums of the current image row to the current grid row,
/// times the `units` of that grid row that the image row covers.
fn addDown(scale: *Scale, units: u64) void {
    for (scale.down, scale.across) |*sum, across| sum.* += units * across;
}

const testing = std.testing;

/// The units that the cell `cell` of a grid with cells of `size` units
/// shares with the cell `other` of a grid with cells of `other_size`.
fn shared(cell: u64, size: u64, other: u64, other_size: u64) u128 {
    const low = @max(cell * size, other * other_size);
    const high = @min((cell + 1) * size, (other + 1) * other_size);

    return if (high > low) high - low else 0;
}

/// The area average of one sample of one output pixel, over every pixel
/// of the image at once.
fn expected(
    samples: []const u8,
    image_width: u32,
    image_height: u32,
    width: u32,
    height: u32,
    column: u32,
    row: u32,
    channel: usize,
) u8 {
    var sum: u128 = 0;

    for (0..image_height) |y| {
        const rows = shared(y, height, row, image_height);

        for (0..image_width) |x| {
            const columns = shared(x, width, column, image_width);
            const sample = samples[(y * image_width + x) * 3 + channel];

            sum += rows * columns * sample;
        }
    }

    const area = @as(u128, image_width) * image_height;

    return @intCast((sum + area / 2) / area);
}

/// Scales `samples` and checks every grid row from `first` on against
/// the average over the whole image. Returns the image rows that the
/// scale took.
fn expectScaled(
    samples: []const u8,
    image_width: u32,
    image_height: u32,
    width: u32,
    height: u32,
    first: u32,
) !u32 {
    const workspace = try testing.allocator.alloc(u64, words(width));
    defer testing.allocator.free(workspace);

    const pixels = try testing.allocator.alloc(u8, @as(usize, width) * 4);
    defer testing.allocator.free(pixels);

    var scale: Scale =
        .init(workspace, image_width, image_height, width, height, first);

    const start = firstSource(image_height, height, first);
    const end = endSource(image_height, height, height);

    try testing.expectEqual(image_height, end);

    var row = first;

    for (start..end) |index| {
        const row_bytes = @as(usize, image_width) * 3;
        const source = samples[index * row_bytes ..][0..row_bytes];

        if (!scale.add(@intCast(index), source)) continue;

        scale.emit(pixels);

        for (0..width) |column| {
            for (0..3) |channel| {
                try testing.expectEqual(expected(
                    samples,
                    image_width,
                    image_height,
                    width,
                    height,
                    @intCast(column),
                    row,
                    channel,
                ), pixels[column * 4 + channel]);
            }

            try testing.expectEqual(0xff, pixels[column * 4 + 3]);
        }

        row += 1;
    }

    try testing.expectEqual(height, row);

    return @intCast(end - start);
}

/// Returns an image of pseudo-random samples.
fn noise(image_width: u32, image_height: u32, seed: u64) ![]u8 {
    const samples = try testing.allocator.alloc(
        u8,
        @as(usize, image_width) * image_height * 3,
    );

    var prng: std.Random.DefaultPrng = .init(seed);

    prng.random().bytes(samples);

    return samples;
}

test "a pixel that covers whole pixels is their mean, halves up" {
    // Two rows of two pixels become one pixel. The means are 0.25, 0.5,
    // and 254.75.
    const samples = [_]u8{
        0, 0, 255, 0, 1, 255,
        1, 1, 255, 0, 0, 254,
    };

    var workspace: [6]u64 = undefined;
    var pixel: [4]u8 = undefined;

    var scale: Scale = .init(&workspace, 2, 2, 1, 1, 0);

    try testing.expect(!scale.add(0, samples[0..6]));
    try testing.expect(scale.add(1, samples[6..12]));

    scale.emit(&pixel);

    try testing.expectEqual([4]u8{ 0, 1, 255, 0xff }, pixel);
}

test "a pixel that covers pixels in part weighs them by that part" {
    // Three pixels become two: each output pixel covers one pixel whole
    // and half of the middle one, so the means are 30 and 60.
    const samples = [_]u8{ 0, 0, 0, 90, 90, 90, 45, 45, 45 };

    var workspace: [12]u64 = undefined;
    var pixels: [8]u8 = undefined;

    var scale: Scale = .init(&workspace, 3, 1, 2, 1, 0);

    try testing.expect(scale.add(0, &samples));

    scale.emit(&pixels);

    try testing.expectEqual(
        [8]u8{ 30, 30, 30, 0xff, 60, 60, 60, 0xff },
        pixels,
    );
}

test "every grid row is the average over the image at each ratio" {
    const Case = struct { w: u32, h: u32, width: u32, height: u32 };

    const cases = [_]Case{
        // The ratios of the ordinary page, the long segment, and the
        // large page, at a small size.
        .{ .w = 40, .h = 60, .width = 27, .height = 41 },
        .{ .w = 36, .h = 100, .width = 27, .height = 75 },
        .{ .w = 91, .h = 137, .width = 24, .height = 36 },
        // One axis keeps its size, and one collapses to a single cell.
        .{ .w = 7, .h = 5, .width = 3, .height = 5 },
        .{ .w = 5, .h = 9, .width = 5, .height = 4 },
        .{ .w = 13, .h = 11, .width = 1, .height = 1 },
        .{ .w = 2, .h = 3, .width = 1, .height = 2 },
    };

    for (cases, 0..) |case, seed| {
        const samples = try noise(case.w, case.h, seed);
        defer testing.allocator.free(samples);

        const taken = try expectScaled(
            samples,
            case.w,
            case.h,
            case.width,
            case.height,
            0,
        );

        try testing.expectEqual(case.h, taken);
    }
}

test "the extremes of a sample stay themselves" {
    for ([_]u8{ 0, 255 }) |value| {
        const samples = try testing.allocator.alloc(u8, 9 * 7 * 3);
        defer testing.allocator.free(samples);

        @memset(samples, value);

        var workspace: [24]u64 = undefined;
        var pixels: [16]u8 = undefined;

        var scale: Scale = .init(&workspace, 9, 7, 4, 3, 0);

        for (0..7) |index| {
            if (!scale.add(@intCast(index), samples[index * 27 ..][0..27])) {
                continue;
            }

            scale.emit(&pixels);

            for (0..4) |column| {
                try testing.expectEqual(
                    [4]u8{ value, value, value, 0xff },
                    pixels[column * 4 ..][0..4].*,
                );
            }
        }
    }
}

test "a scale that starts below the top takes only the rows it covers" {
    const samples = try noise(36, 100, 7);
    defer testing.allocator.free(samples);

    // The grid rows from 30 on cover the image rows from 40 on.
    try testing.expectEqual(60, try expectScaled(samples, 36, 100, 27, 75, 30));

    // The grid row 31 starts inside the image row 41, which it shares
    // with the row above it.
    try testing.expectEqual(59, try expectScaled(samples, 36, 100, 27, 75, 31));
}

test "the source rows of grid rows round outward" {
    // With 10 image rows and 4 grid rows, a grid row spans 2.5 image
    // rows.
    try testing.expectEqual(0, firstSource(10, 4, 0));
    try testing.expectEqual(2, firstSource(10, 4, 1));
    try testing.expectEqual(5, firstSource(10, 4, 2));
    try testing.expectEqual(3, endSource(10, 4, 1));
    try testing.expectEqual(5, endSource(10, 4, 2));
    try testing.expectEqual(10, endSource(10, 4, 4));
}

test "the sums of the largest area stay within 64 bits" {
    // A sum is at most 255 times the area, and the rounding adds half
    // the area.
    const largest: u128 = @as(u128, 255) * area_limit + area_limit / 2;

    try testing.expect(largest <= std.math.maxInt(u64));
}
