//! A PNG of 2 by 3 pixels of RGB samples of 8 bits, built at compile
//! time: each row unfiltered, in one IDAT chunk that holds one stored
//! deflate block. Tests that cannot link the writer of the test images
//! decode it: the tests of the JNI layer and the device harness of the
//! C ABI.

const std = @import("std");

pub const width = 2;
pub const height = 3;

/// The samples of the image, row by row.
pub const samples = [height * row_samples]u8{
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
};

/// The samples of one row, and its bytes in the image data with its
/// filter byte.
const row_samples = width * 3;
const row_bytes = row_samples + 1;

/// The encoded image.
pub const bytes = signature ++ chunk("IHDR", &header) ++
    chunk("IDAT", &stream) ++ chunk("IEND", &.{});

/// The bytes of the encoded image up to the end of the row `count`, so
/// that a decode of them yields `count` rows and then lacks input.
pub fn through(comptime count: usize) usize {
    return signature.len + chunk("IHDR", &header).len + chunk_head +
        stream_head + count * row_bytes;
}

/// The offset of the last byte of the CRC of the image data.
pub const data_crc_at = bytes.len - chunk("IEND", &.{}).len - 1;

const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// The width and the height, a bit depth of 8, color type 2, and no
/// interlace.
const header = [_]u8{ 0, 0, 0, width, 0, 0, 0, height, 8, 2, 0, 0, 0 };

/// The length and the type of a chunk, and the zlib header with the
/// header of one stored block, in bytes.
const chunk_head = 8;
const stream_head = 7;

/// The rows with their filter bytes, which say that no row is filtered.
const rows = rows: {
    var filtered: [height * row_bytes]u8 = undefined;

    for (0..height) |row| {
        const at = row * row_bytes;

        filtered[at] = 0;

        @memcpy(
            filtered[at + 1 ..][0..row_samples],
            samples[row * row_samples ..][0..row_samples],
        );
    }

    break :rows filtered;
};

/// The zlib stream: its header, one final stored block with its length
/// and the complement of the length, the rows, and their checksum.
const stream = stream: {
    const len: u8 = rows.len;

    var checksum: [4]u8 = undefined;

    std.mem.writeInt(u32, &checksum, std.hash.Adler32.hash(&rows), .big);

    break :stream [stream_head]u8{ 0x78, 0x01, 0x01, len, 0, ~len, 0xff } ++
        rows ++ checksum;
};

/// Returns the chunk of `name` over `data`, with its length and CRC.
fn chunk(
    comptime name: *const [4]u8,
    comptime data: []const u8,
) [data.len + 12]u8 {
    // The CRC builds its table of 256 entries at compile time.
    @setEvalBranchQuota(10_000);

    var encoded: [data.len + 12]u8 = undefined;

    std.mem.writeInt(u32, encoded[0..4], data.len, .big);

    encoded[4..8].* = name.*;
    @memcpy(encoded[chunk_head..][0..data.len], data);

    std.mem.writeInt(
        u32,
        encoded[chunk_head + data.len ..][0..4],
        std.hash.Crc32.hash(encoded[4 .. chunk_head + data.len]),
        .big,
    );

    return encoded;
}
