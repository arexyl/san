//! The test inputs of the PNG decoder: how a test splits its
//! input into portions, San's strictness over libpng as a table of
//! generated images and their outcomes, and the image of the
//! failure-injection tests.

const std = @import("std");
const Decoder = @import("Decoder.zig");
const fixtures = @import("fixtures.zig");

const Error = Decoder.Error;
const Reason = Decoder.Reason;

/// How a test splits its input into portions.
pub const Plan = union(enum) {
    /// One portion.
    whole,
    /// One byte per portion.
    bytewise,
    /// Portions of 1 to 97 bytes, drawn from this seed.
    seeded: u64,
    /// Two portions, split at this offset.
    split: usize,
    /// This prefix alone.
    prefix: usize,
};

/// The plans of every strictness case. libpng's push reader takes
/// different paths through its save buffer for each of them.
pub const plans = [_]Plan{
    .whole,
    .bytewise,
    .{ .seeded = 1 },
    .{ .seeded = 2 },
    .{ .seeded = 3 },
};

/// Feeds `bytes` to `decoder` in the portions of `plan`, then finishes
/// the decode. Returns the first failure.
pub fn feed(decoder: *Decoder, bytes: []const u8, plan: Plan) Error!void {
    switch (plan) {
        .whole => _ = try decoder.feed(bytes),
        .bytewise => for (0..bytes.len) |at| {
            _ = try decoder.feed(bytes[at..][0..1]);
        },
        .seeded => |seed| {
            var prng: std.Random.DefaultPrng = .init(seed);

            const random = prng.random();

            var rest = bytes;

            while (rest.len != 0) {
                const len = @min(rest.len, random.intRangeAtMost(usize, 1, 97));

                _ = try decoder.feed(rest[0..len]);
                rest = rest[len..];
            }
        },
        .split => |at| {
            _ = try decoder.feed(bytes[0..at]);
            _ = try decoder.feed(bytes[at..]);
        },
        .prefix => |len| _ = try decoder.feed(bytes[0..len]),
    }

    try decoder.finish();
}

/// A short tEXt chunk.
pub const short_text: fixtures.Chunk = .{
    .name = "tEXt".*,
    .data = "Comment\x00hello",
};

/// An eXIf chunk whose first four bytes are no TIFF header.
const headless_exif: fixtures.Chunk = .{
    .name = "eXIf".*,
    .data = "XX\x00\x00\x00\x00\x00\x08",
};

/// One rule of San's strictness over libpng, as an input and its
/// outcome.
pub const Case = struct {
    name: []const u8,
    spec: fixtures.Spec,
    /// The failure, or null for success.
    expected: ?Error = null,
    reason: Reason = .none,
    /// The rule fails the decode before any row.
    rowless: bool = false,
    /// The rule fails the decode before the header callback.
    headerless: bool = false,
    color_warning: bool = false,
    /// libpng warns, and the warning stays a diagnostic.
    warned: bool = false,
};

/// The image of the strictness table.
const width = 6;
const height = 5;

/// San's strictness over libpng: one case per rule.
pub const strictness = [_]Case{
    .{
        .name = "valid",
        .spec = .{ .width = width, .height = height, .filters = .cycle },
    },
    .{
        .name = "valid palette image",
        .spec = .{ .width = width, .height = height, .format = .palette8 },
    },
    .{
        .name = "valid fixed Huffman block",
        .spec = .{ .width = width, .height = height, .final_block = .fixed },
    },
    .{
        .name = "valid in many IDAT chunks",
        .spec = .{ .width = width, .height = height, .idat_size = 5 },
    },
    .{
        .name = "Adler-32 mismatch",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .adler32 = .wrong },
        },
        .expected = error.InvalidContent,
        .reason = .stream,
    },
    .{
        .name = "Adler-32 missing",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .adler32 = .missing },
        },
        .expected = error.InvalidContent,
        .reason = .libpng,
    },
    .{
        .name = "Adler-32 cut short",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .adler32 = .partial },
        },
        .expected = error.InvalidContent,
        .reason = .libpng,
    },
    .{
        .name = "stream without an end",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .open_end = true },
        },
        .expected = error.InvalidContent,
        .reason = .libpng,
    },
    .{
        .name = "surplus row without an end",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .open_end = true, .surplus_rows = 1 },
        },
        .expected = error.InvalidContent,
        .reason = .stream,
    },
    .{
        .name = "surplus row before a valid end",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .surplus_rows = 1 },
        },
        .expected = error.InvalidContent,
        .reason = .stream,
    },
    .{
        .name = "stream end before the last row",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .missing_rows = 1 },
        },
        .expected = error.InvalidContent,
        .reason = .incomplete,
    },
    .{
        .name = "reserved block type",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .reserved_block = true },
        },
        .expected = error.InvalidContent,
        .reason = .stream,
        .rowless = true,
    },
    .{
        .name = "zlib header with a window above 32 KiB",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .cmf = 0x87 },
        },
        .expected = error.InvalidContent,
        .reason = .stream,
        .rowless = true,
    },
    .{
        .name = "unused bytes after the stream in its last IDAT",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .unused = 19 },
        },
        .warned = true,
    },
    .{
        .name = "consecutive IDAT after the stream",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .consecutive = 9 },
        },
        .warned = true,
    },
    .{
        .name = "IDAT after another chunk after the image data",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .nonconsecutive = true },
        },
        .expected = error.InvalidContent,
        .reason = .nonconsecutive,
    },
    .{
        .name = "bytes after IEND",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .trailing = 8 },
        },
        .expected = error.InvalidContent,
        .reason = .trailing,
    },
    .{
        .name = "IHDR CRC",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .crc = "IHDR".* },
        },
        .expected = error.InvalidContent,
        .reason = .libpng,
        .rowless = true,
        .headerless = true,
    },
    .{
        .name = "duplicate IHDR",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .duplicate_ihdr = true },
        },
        .expected = error.InvalidContent,
        .reason = .libpng,
        .rowless = true,
        .headerless = true,
    },
    .{
        .name = "ancillary chunk before IHDR",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .before_ihdr = true },
        },
        .expected = error.InvalidContent,
        .reason = .first_chunk,
        .rowless = true,
        .headerless = true,
    },
    .{
        .name = "IDAT CRC",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .crc = "IDAT".* },
        },
        .expected = error.InvalidContent,
        .reason = .libpng,
    },
    .{
        .name = "PLTE CRC of a palette image",
        .spec = .{
            .width = width,
            .height = height,
            .format = .palette8,
            .faults = .{ .crc = "PLTE".* },
        },
        .expected = error.InvalidContent,
        .reason = .libpng,
        .rowless = true,
        .headerless = true,
    },
    .{
        .name = "PLTE CRC of a truecolor image",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{fixtures.plte},
            .faults = .{ .crc = "PLTE".* },
        },
        .warned = true,
    },
    .{
        .name = "tRNS CRC",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{fixtures.trns_rgb},
            .faults = .{ .crc = "tRNS".* },
        },
        .expected = error.InvalidContent,
        .reason = .essential,
        .rowless = true,
        .headerless = true,
    },
    .{
        .name = "tRNS after the image data",
        .spec = .{
            .width = width,
            .height = height,
            .after = &.{fixtures.trns_rgb},
        },
        .expected = error.InvalidContent,
        .reason = .essential,
    },
    .{
        .name = "tEXt CRC",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{short_text},
            .faults = .{ .crc = "tEXt".* },
        },
        .warned = true,
    },
    .{
        .name = "tIME CRC",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{fixtures.time},
            .faults = .{ .crc = "tIME".* },
        },
        .warned = true,
    },
    .{
        .name = "eXIf CRC",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{fixtures.exif},
            .faults = .{ .crc = "eXIf".* },
        },
        .warned = true,
    },
    .{
        .name = "duplicate eXIf",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{ fixtures.exif, fixtures.exif },
        },
        .warned = true,
    },
    .{
        .name = "eXIf without a TIFF header",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{headless_exif},
        },
        .warned = true,
    },
    .{
        .name = "IEND CRC",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .crc = "IEND".* },
        },
        .expected = error.InvalidContent,
        .reason = .essential,
    },
    .{
        .name = "IEND with data",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .iend_data = 4 },
        },
        .expected = error.InvalidContent,
        .reason = .essential,
    },
    .{
        .name = "filter type 5",
        .spec = .{
            .width = width,
            .height = height,
            .faults = .{ .filter_byte = .{ .row = 2, .value = 5 } },
        },
        .expected = error.InvalidContent,
        .reason = .libpng,
    },
    .{
        .name = "no IDAT",
        .spec = .{ .width = width, .height = height, .idat = false },
        .expected = error.InvalidContent,
        .reason = .libpng,
        .rowless = true,
        .headerless = true,
    },
    .{
        .name = "acTL before the image data",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{fixtures.actl},
        },
        .expected = error.UnsupportedFormat,
        .reason = .animated,
        .rowless = true,
        .headerless = true,
    },
    .{
        .name = "interlaced image",
        .spec = .{ .width = width, .height = height, .interlaced = true },
        .expected = error.UnsupportedFormat,
        .reason = .stopped,
        .rowless = true,
        .headerless = true,
    },
} ++ color_metadata ++ bit_depths ++ palette_indexes;

/// Invalid optional color metadata takes the color fallback: a CRC fault
/// in each color chunk, and an ICC profile that libpng rejects. libpng
/// inflates the profile while it handles iCCP, and that output is no
/// image data.
const color_metadata = [_]Case{
    colorCrc(fixtures.gama),
    colorCrc(fixtures.chrm),
    colorCrc(fixtures.srgb),
    colorCrc(fixtures.iccp),
    colorCrc(fixtures.cicp),
    colorCrc(fixtures.mdcv),
    colorCrc(fixtures.clli),
    .{
        .name = "iCCP profile that libpng rejects",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{fixtures.iccp},
        },
        .color_warning = true,
        .warned = true,
    },
};

/// Returns the case of a CRC fault in `chunk`, an optional color chunk.
fn colorCrc(comptime chunk: fixtures.Chunk) Case {
    return .{
        .name = &chunk.name ++ " CRC",
        .spec = .{
            .width = width,
            .height = height,
            .before = &.{chunk},
            .faults = .{ .crc = chunk.name },
        },
        .color_warning = true,
        .warned = true,
    };
}

/// The width of the images below 8 bits per sample. Its rows leave
/// unused bits in their last byte at 1, 2, and 4 bits.
const packed_width = 13;

/// The image's filtered size depends on the bytes of a row, which round
/// up below 8 bits per pixel: a valid image with every filter type and
/// one with a surplus row, at every bit depth other than 8.
const bit_depths = depthCases(.gray1) ++ depthCases(.gray2) ++
    depthCases(.gray4) ++ depthCases(.gray16) ++ depthCases(.palette1) ++
    depthCases(.palette2) ++ depthCases(.palette4);

fn depthCases(comptime format: fixtures.Format) [2]Case {
    const spec: fixtures.Spec = .{
        .width = packed_width,
        .height = height,
        .format = format,
        .filters = .cycle,
    };

    var surplus = spec;

    surplus.faults.surplus_rows = 1;

    return .{
        .{ .name = "valid " ++ @tagName(format), .spec = spec },
        .{
            .name = "surplus row at " ++ @tagName(format),
            .spec = surplus,
            .expected = error.InvalidContent,
            .reason = .stream,
        },
    };
}

/// A sample beyond the palette fails the decode at its row, at every bit
/// depth of a palette image. The unused bits at the end of a row are no
/// sample.
const palette_indexes = [_]Case{
    paletteIndex(.palette1, 1, 0),
    paletteIndex(.palette2, 3, 2),
    paletteIndex(.palette4, 4, 4),
    paletteIndex(.palette8, 4, 1),
    .{
        .name = "unused bits of a palette row",
        .spec = .{
            .width = packed_width,
            .height = height,
            .format = .palette1,
            .palette_entries = 1,
            .fill_padding = true,
        },
    },
};

/// Returns the case of an index beyond a palette of `entries` entries in
/// row `row` of an image in `format`.
fn paletteIndex(
    comptime format: fixtures.Format,
    comptime entries: u16,
    comptime row: u32,
) Case {
    return .{
        .name = "palette index beyond the palette at " ++ @tagName(format),
        .spec = .{
            .width = packed_width,
            .height = height,
            .format = format,
            .palette_entries = entries,
            .faults = .{ .palette_index = row },
        },
        .expected = error.InvalidContent,
        .reason = .palette_index,
        .rowless = row == 0,
    };
}

/// The image of the injection and budget tests. libpng goes on after a
/// refused allocation for its eXIf chunk, so the refusal alone fails the
/// decode.
pub const small: fixtures.Spec = .{
    .width = 7,
    .height = 3,
    .filters = .cycle,
    .before = &.{ fixtures.gama, short_text, fixtures.exif },
    .idat_size = 23,
};
