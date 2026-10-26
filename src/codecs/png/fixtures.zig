//! A deterministic PNG writer for the tests of the PNG decoder. It
//! generates every test image from a specification, so no generated
//! bytes enter the repository, and the host tests and an Android harness
//! can share it.
//!
//! The writer compresses nothing. It writes the image data as stored
//! deflate blocks, optionally with a final block of fixed Huffman codes
//! that holds literals only, and it computes the Adler-32 of the stream
//! and the CRC of every chunk itself. Each fault of `Faults` changes one
//! exact structure of an otherwise valid image, so a test names the rule
//! that the fault breaks.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The PNG signature.
pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// The length of the signature and the IHDR chunk, the prefix that holds
/// the image header.
pub const header_len = signature.len + 12 + 13;

/// The pixel formats of the writer: a color type and a bit depth. Below 8
/// bits, the samples of a row are packed from the most significant bit,
/// and a row whose bits do not fill its last byte leaves unused bits.
pub const Format = enum {
    gray1,
    gray2,
    gray4,
    gray8,
    gray16,
    rgb8,
    palette1,
    palette2,
    palette4,
    palette8,
    rgba8,

    pub fn colorType(format: Format) u8 {
        return switch (format) {
            .gray1, .gray2, .gray4, .gray8, .gray16 => 0,
            .rgb8 => 2,
            .palette1, .palette2, .palette4, .palette8 => 3,
            .rgba8 => 6,
        };
    }

    pub fn bitDepth(format: Format) u8 {
        return switch (format) {
            .gray1, .palette1 => 1,
            .gray2, .palette2 => 2,
            .gray4, .palette4 => 4,
            .gray8, .rgb8, .palette8, .rgba8 => 8,
            .gray16 => 16,
        };
    }

    /// Returns the samples of one pixel.
    pub fn channels(format: Format) u8 {
        return switch (format) {
            .gray1, .gray2, .gray4, .gray8, .gray16 => 1,
            .palette1, .palette2, .palette4, .palette8 => 1,
            .rgb8 => 3,
            .rgba8 => 4,
        };
    }

    /// Returns the bits of one pixel.
    pub fn pixelBits(format: Format) u32 {
        return @as(u32, format.channels()) * format.bitDepth();
    }

    /// Returns the filters' distance: the bytes of one pixel, and one
    /// byte below 8 bits per pixel.
    pub fn filterDistance(format: Format) usize {
        return @max(1, format.pixelBits() / 8);
    }
};

/// The filter types of PNG's adaptive filtering.
pub const Filter = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
};

/// The filters of the rows: one type for all, or the five types in turn,
/// row `r` taking type `r % 5`.
pub const Filters = union(enum) {
    all: Filter,
    cycle,

    fn of(filters: Filters, row: usize) Filter {
        return switch (filters) {
            .all => |filter| filter,
            .cycle => @fromBackingInt(@intCast(row % 5)),
        };
    }
};

/// A chunk that the writer emits as given, with its CRC.
pub const Chunk = struct {
    name: [4]u8,
    data: []const u8,
};

/// The kind of the final deflate block.
pub const Block = enum {
    /// Stored, like every other block.
    stored,
    /// Fixed Huffman codes, holding the bytes of the last row as
    /// literals.
    fixed,
};

/// The trailer of the zlib stream.
pub const Adler32 = enum {
    valid,
    /// The checksum with its lowest bit flipped.
    wrong,
    /// No trailer.
    missing,
    /// The first two of its four bytes.
    partial,
};

/// The faults that the writer injects. Each default leaves the image
/// valid.
pub const Faults = struct {
    adler32: Adler32 = .valid,
    /// No final block and no trailer: the stream never ends.
    open_end: bool = false,
    /// Rows beyond the height, in the last block, filtered with type 0.
    surplus_rows: u32 = 0,
    /// Rows left out at the end of an otherwise complete stream.
    missing_rows: u32 = 0,
    /// A block of the reserved type 3 at the start of the stream.
    reserved_block: bool = false,
    /// The first byte of the zlib stream, CMF, in place of 0x78.
    cmf: ?u8 = null,
    /// The filter byte of one row, in place of its filter type.
    filter_byte: ?struct { row: u32, value: u8 } = null,
    /// Bytes after the stream, inside its last IDAT chunk.
    unused: usize = 0,
    /// The data size of one more IDAT chunk right after the stream's.
    consecutive: ?usize = null,
    /// A tIME chunk and one more IDAT chunk after the image data.
    nonconsecutive: bool = false,
    /// The first chunk of this name carries a wrong CRC.
    crc: ?[4]u8 = null,
    /// A second IHDR chunk right after the first.
    duplicate_ihdr: bool = false,
    /// A tEXt chunk between the signature and IHDR.
    before_ihdr: bool = false,
    /// Data inside IEND.
    iend_data: usize = 0,
    /// Bytes after IEND.
    trailing: usize = 0,
    /// The last sample of this row of a palette image indexes the entry
    /// after the palette's last, which the palette must leave free.
    palette_index: ?u32 = null,
};

/// A test image.
pub const Spec = struct {
    width: u32,
    height: u32,
    format: Format = .rgb8,
    /// Marks the image as Adam7 in IHDR. The image data stays laid out as
    /// a noninterlaced image.
    interlaced: bool = false,
    filters: Filters = .{ .all = .none },
    /// The seed of the samples.
    seed: u64 = 1,
    /// The entries of the palette that the writer adds to a palette
    /// image, from 1 to 256. The writer caps them at the indexes of the
    /// bit depth, because libpng silently truncates a longer palette.
    palette_entries: u16 = 4,
    /// Sets the unused bits at the end of each row, which the format
    /// leaves unspecified, instead of clearing them.
    fill_padding: bool = false,
    /// Chunks after IHDR, and after PLTE in a palette image, before the
    /// first IDAT chunk.
    before: []const Chunk = &.{},
    /// Chunks after the image data, before IEND.
    after: []const Chunk = &.{},
    /// The data size of each IDAT chunk; the last takes the rest. Zero
    /// puts the whole stream in one chunk.
    idat_size: usize = 0,
    /// Writes the image data. Without it, the image has no IDAT chunk.
    idat: bool = true,
    final_block: Block = .stored,
    faults: Faults = .{},

    /// Returns the bytes of one row without its filter byte.
    pub fn rowBytes(spec: Spec) usize {
        return (@as(usize, spec.width) * spec.format.pixelBits() + 7) / 8;
    }

    /// Returns the entries of the palette of a palette image.
    pub fn paletteLen(spec: Spec) u16 {
        const indexes = @as(u16, 1) << @intCast(spec.format.bitDepth());

        return @min(spec.palette_entries, indexes);
    }
};

/// A gAMA chunk of 1/2.2.
pub const gama: Chunk = .{
    .name = "gAMA".*,
    .data = &.{ 0x00, 0x00, 0xb1, 0x8f },
};

/// A tRNS chunk of an RGB image.
pub const trns_rgb: Chunk = .{
    .name = "tRNS".*,
    .data = &.{ 0x00, 0x01, 0x00, 0x02, 0x00, 0x03 },
};

/// A tIME chunk.
pub const time: Chunk = .{
    .name = "tIME".*,
    .data = &.{ 0x07, 0xea, 0x0a, 0x1a, 0x0c, 0x00, 0x00 },
};

/// An eXIf chunk with a big-endian TIFF header and no entry.
pub const exif: Chunk = .{
    .name = "eXIf".*,
    .data = &.{ 'M', 'M', 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08 },
};

/// An acTL chunk of an animated image: one frame, played forever.
pub const actl: Chunk = .{
    .name = "acTL".*,
    .data = &.{ 0, 0, 0, 1, 0, 0, 0, 0 },
};

/// A suggested palette of a truecolor image, with four entries.
pub const plte: Chunk = .{
    .name = "PLTE".*,
    .data = palette_colors[0 .. 3 * 4],
};

/// The colors of a palette of 256 entries. A palette takes its first
/// entries.
const palette_colors = colors: {
    var colors: [3 * 256]u8 = undefined;

    for (&colors, 0..) |*byte, index| byte.* = @truncate(index * 73 + 41);

    break :colors colors;
};

/// A cHRM chunk with the chromaticities of sRGB.
pub const chrm: Chunk = .{
    .name = "cHRM".*,
    .data = &bigEndian(&.{
        31270, 32900, // white point
        64000, 33000, // red
        30000, 60000, // green
        15000, 6000, // blue
    }),
};

/// An sRGB chunk with the perceptual rendering intent.
pub const srgb: Chunk = .{ .name = "sRGB".*, .data = &.{0} };

/// A cICP chunk of BT.709 primaries, the sRGB transfer function, RGB
/// without a matrix, and full range.
pub const cicp: Chunk = .{ .name = "cICP".*, .data = &.{ 1, 13, 0, 1 } };

/// An mDCV chunk: the primaries and white point of a display in units of
/// 0.00002, then its largest and smallest luminance, 1000 and 0.0001
/// candelas per square meter, in units of 0.0001.
pub const mdcv: Chunk = .{
    .name = "mDCV".*,
    .data = &(bigEndian16(&.{
        34000, 16000, // red
        13250, 34500, // green
        7500, 3000, // blue
        15635, 16450, // white point
    }) ++ bigEndian(&.{ 10_000_000, 1 })),
};

/// A cLLI chunk: a largest content light level of 1000 and a largest
/// frame-average light level of 400 candelas per square meter, in units
/// of 0.0001.
pub const clli: Chunk = .{
    .name = "cLLI".*,
    .data = &bigEndian(&.{ 10_000_000, 4_000_000 }),
};

/// An iCCP chunk whose profile, 200 zero bytes in one stored deflate
/// block, declares a length of zero. libpng inflates the start of the
/// profile while it handles iCCP, then rejects the profile with a benign
/// error.
pub const iccp: Chunk = .{ .name = "iCCP".*, .data = &iccp_data };

const iccp_profile: [200]u8 = @splat(0);

const iccp_data = "icc".* ++ [_]u8{
    0, // the end of the keyword
    0, // compression method: deflate
    0x78, 0x01, // the zlib header
    0x01, 0xc8, 0x00, 0x37, 0xff, // a final stored block of 200 bytes
} ++ iccp_profile ++ bigEndian(&.{std.hash.Adler32.hash(&iccp_profile)});

/// Returns `values` as big-endian 32-bit integers.
fn bigEndian(comptime values: []const u32) [4 * values.len]u8 {
    var bytes: [4 * values.len]u8 = undefined;

    for (values, 0..) |value, index| {
        std.mem.writeInt(u32, bytes[4 * index ..][0..4], value, .big);
    }

    return bytes;
}

/// Returns `values` as big-endian 16-bit integers.
fn bigEndian16(comptime values: []const u16) [2 * values.len]u8 {
    var bytes: [2 * values.len]u8 = undefined;

    for (values, 0..) |value, index| {
        std.mem.writeInt(u16, bytes[2 * index ..][0..2], value, .big);
    }

    return bytes;
}

/// Fills `buffer` with the data of a tEXt or iTXt chunk: a keyword, its
/// terminator, and text. `buffer` holds at least 2 bytes.
pub fn text(buffer: []u8) []const u8 {
    const keyword = "Comment";

    const len: usize = @min(keyword.len, buffer.len - 1);

    @memcpy(buffer[0..len], keyword[0..len]);
    buffer[len] = 0;

    for (buffer[len + 1 ..], 0..) |*byte, index| {
        byte.* = 'a' + @as(u8, @intCast(index % 26));
    }

    return buffer;
}

/// Returns the rows of the image without filter bytes, unused bits
/// included: what a decoder that applies no transformation delivers. The
/// caller owns the slice.
pub fn samples(gpa: Allocator, spec: Spec) Allocator.Error![]u8 {
    const row_bytes = spec.rowBytes();

    const raw = try gpa.alloc(u8, row_bytes * spec.height);

    var prng: std.Random.DefaultPrng = .init(spec.seed);

    const random = prng.random();

    random.bytes(raw);

    for (0..spec.height) |row| {
        const line = raw[row * row_bytes ..][0..row_bytes];

        if (spec.format.colorType() == 3) indexPalette(spec, line, row);

        padRow(spec, line);
    }

    return raw;
}

/// Makes every sample of `line`, row `row` of a palette image, index an
/// entry of the palette, except the one that the faults place beyond it.
fn indexPalette(spec: Spec, line: []u8, row: usize) void {
    const depth = spec.format.bitDepth();
    const entries = spec.paletteLen();

    for (0..spec.width) |column| {
        const index = sampleAt(line, column, depth);

        setSample(line, column, depth, @intCast(index % entries));
    }

    const target = spec.faults.palette_index orelse return;

    if (target != row) return;

    if (entries == @as(u16, 1) << @intCast(depth)) {
        @panic("the palette leaves no index beyond its last entry");
    }

    setSample(line, spec.width - 1, depth, @intCast(entries));
}

/// Clears the unused bits at the end of `line`, or sets them under
/// `fill_padding`.
fn padRow(spec: Spec, line: []u8) void {
    const used = @as(usize, spec.width) * spec.format.pixelBits() % 8;

    if (used == 0) return;

    const unused: u8 = @as(u8, 0xff) >> @intCast(used);

    if (spec.fill_padding) {
        line[line.len - 1] |= unused;
    } else {
        line[line.len - 1] &= ~unused;
    }
}

/// Returns sample `index` of a row of samples of `depth` bits, at most 8,
/// packed from the most significant bit.
fn sampleAt(line: []const u8, index: usize, depth: u8) u8 {
    const bit = index * depth;
    const shift: u3 = @intCast(8 - depth - bit % 8);
    const mask: u8 = @truncate((@as(u16, 1) << @intCast(depth)) - 1);

    return (line[bit / 8] >> shift) & mask;
}

/// Sets sample `index` of a row of samples of `depth` bits to `value`.
fn setSample(line: []u8, index: usize, depth: u8, value: u8) void {
    const bit = index * depth;
    const shift: u3 = @intCast(8 - depth - bit % 8);
    const mask: u8 = @truncate((@as(u16, 1) << @intCast(depth)) - 1);

    line[bit / 8] &= ~(mask << shift);
    line[bit / 8] |= (value & mask) << shift;
}

/// Returns the encoded image. The caller owns the slice.
pub fn encode(gpa: Allocator, spec: Spec) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try out.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;

    std.mem.writeInt(u32, ihdr[0..4], spec.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], spec.height, .big);
    ihdr[8] = spec.format.bitDepth();
    ihdr[9] = spec.format.colorType();
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = @intFromBool(spec.interlaced);

    var writer: ChunkWriter = .{
        .gpa = gpa,
        .out = &out,
        .faults = spec.faults,
    };

    if (spec.faults.before_ihdr) try writer.chunk("tEXt".*, "Comment\x00x");

    try writer.chunk("IHDR".*, &ihdr);

    if (spec.faults.duplicate_ihdr) try writer.chunk("IHDR".*, &ihdr);

    if (spec.format.colorType() == 3) {
        const len = 3 * @as(usize, spec.paletteLen());

        try writer.chunk("PLTE".*, palette_colors[0..len]);
    }

    for (spec.before) |extra| try writer.chunk(extra.name, extra.data);

    if (spec.idat) try writeImageData(gpa, &writer, spec);

    for (spec.after) |extra| try writer.chunk(extra.name, extra.data);

    const iend = try gpa.alloc(u8, spec.faults.iend_data);
    defer gpa.free(iend);

    @memset(iend, 0);
    try writer.chunk("IEND".*, iend);
    try out.appendNTimes(gpa, 0x5a, spec.faults.trailing);

    return out.toOwnedSlice(gpa);
}

/// Writes chunks with their CRCs, and spoils the CRC of the first chunk
/// that the faults name.
const ChunkWriter = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    faults: Faults,
    spoiled: bool = false,

    fn chunk(writer: *ChunkWriter, name: [4]u8, data: []const u8) !void {
        var crc: std.hash.Crc32 = .init();

        crc.update(&name);
        crc.update(data);

        var value = crc.final();

        if (writer.faults.crc) |target| {
            if (!writer.spoiled and std.mem.eql(u8, &target, &name)) {
                value ^= 1;
                writer.spoiled = true;
            }
        }

        var length: [4]u8 = undefined;
        var trailer: [4]u8 = undefined;

        std.mem.writeInt(u32, &length, @intCast(data.len), .big);
        std.mem.writeInt(u32, &trailer, value, .big);

        try writer.out.appendSlice(writer.gpa, &length);
        try writer.out.appendSlice(writer.gpa, &name);
        try writer.out.appendSlice(writer.gpa, data);
        try writer.out.appendSlice(writer.gpa, &trailer);
    }
};

/// Writes the IDAT chunks of the image and the IDAT faults after them.
fn writeImageData(gpa: Allocator, writer: *ChunkWriter, spec: Spec) !void {
    const filtered = try filterRows(gpa, spec);
    defer gpa.free(filtered);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);

    try writeZlib(gpa, &stream, filtered, spec);
    try stream.appendNTimes(gpa, 0xa5, spec.faults.unused);

    const size = if (spec.idat_size == 0) stream.items.len else spec.idat_size;

    var rest = stream.items;

    while (true) {
        const part = rest[0..@min(size, rest.len)];

        try writer.chunk("IDAT".*, part);
        rest = rest[part.len..];

        if (rest.len == 0) break;
    }

    if (spec.faults.consecutive) |len| {
        const extra = try gpa.alloc(u8, len);
        defer gpa.free(extra);

        @memset(extra, 0x3c);
        try writer.chunk("IDAT".*, extra);
    }

    if (spec.faults.nonconsecutive) {
        try writer.chunk(time.name, time.data);
        try writer.chunk("IDAT".*, &.{ 0x3c, 0x3c, 0x3c, 0x3c });
    }
}

/// Returns the filtered rows of the image: each row's filter byte and
/// its filtered bytes, with the surplus and missing rows of the faults.
fn filterRows(gpa: Allocator, spec: Spec) ![]u8 {
    const raw = try samples(gpa, spec);
    defer gpa.free(raw);

    const row_bytes = spec.rowBytes();
    const bpp = spec.format.filterDistance();
    const kept = spec.height - @min(spec.height, spec.faults.missing_rows);
    const rows = kept + spec.faults.surplus_rows;

    const filtered = try gpa.alloc(u8, rows * (row_bytes + 1));

    for (0..kept) |row| {
        const line = raw[row * row_bytes ..][0..row_bytes];

        const above: ?[]const u8 = if (row == 0)
            null
        else
            raw[(row - 1) * row_bytes ..][0..row_bytes];

        const out = filtered[row * (row_bytes + 1) ..][0 .. row_bytes + 1];

        const filter = spec.filters.of(row);

        out[0] = @backingInt(filter);
        filterRow(filter, line, above, bpp, out[1..]);

        if (spec.faults.filter_byte) |fault| {
            if (fault.row == row) out[0] = fault.value;
        }
    }

    // Surplus rows hold filter type 0 and bytes that no row has.
    @memset(filtered[kept * (row_bytes + 1) ..], 0);

    return filtered;
}

/// Filters `line`, the row below `above`, with `filter` into `out`.
fn filterRow(
    filter: Filter,
    line: []const u8,
    above: ?[]const u8,
    bpp: usize,
    out: []u8,
) void {
    for (line, out, 0..) |sample, *byte, index| {
        const a: u8 = if (index >= bpp) line[index - bpp] else 0;
        const b: u8 = if (above) |prior| prior[index] else 0;

        const c: u8 = if (above != null and index >= bpp)
            above.?[index - bpp]
        else
            0;

        const predicted: u8 = switch (filter) {
            .none => 0,
            .sub => a,
            .up => b,
            .average => @intCast((@as(u16, a) + b) / 2),
            .paeth => paeth(a, b, c),
        };

        byte.* = sample -% predicted;
    }
}

/// The Paeth predictor of the PNG specification.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const estimate = @as(i16, a) + b - c;
    const pa = @abs(estimate - a);
    const pb = @abs(estimate - b);
    const pc = @abs(estimate - c);

    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;

    return c;
}

/// The largest data of a stored deflate block.
const stored_max = 65535;

/// Writes the zlib stream of `filtered` with the faults of `spec`.
fn writeZlib(
    gpa: Allocator,
    stream: *std.ArrayList(u8),
    filtered: []const u8,
    spec: Spec,
) !void {
    const faults = spec.faults;

    // CMF 0x78 declares deflate with a 32 KiB window; FLG 0x01 makes the
    // pair a multiple of 31 without a preset dictionary.
    try stream.appendSlice(gpa, &.{ faults.cmf orelse 0x78, 0x01 });

    var bits: BitWriter = .{ .gpa = gpa, .out = stream };

    if (faults.reserved_block) try bits.write(0b110, 3);

    const last_row = @min(filtered.len, spec.rowBytes() + 1);

    const tail = switch (spec.final_block) {
        .stored => 0,
        .fixed => last_row,
    };

    // Stored blocks hold the data before the tail; the last of them is
    // final unless a fixed block follows or the stream stays open. An
    // image of one row with a fixed tail has one empty stored block.
    var rest = filtered[0 .. filtered.len - tail];

    while (true) {
        const part = rest[0..@min(stored_max, rest.len)];

        rest = rest[part.len..];

        const final = rest.len == 0 and tail == 0 and !faults.open_end;

        try bits.storedBlock(part, final);

        if (rest.len == 0) break;
    }

    if (tail != 0) {
        try bits.fixedBlock(filtered[filtered.len - tail ..], !faults.open_end);
    }

    try bits.flush();

    if (faults.open_end) return;

    var checksum = std.hash.Adler32.hash(filtered);

    if (faults.adler32 == .wrong) checksum ^= 1;

    var trailer: [4]u8 = undefined;

    std.mem.writeInt(u32, &trailer, checksum, .big);

    switch (faults.adler32) {
        .valid, .wrong => try stream.appendSlice(gpa, &trailer),
        .missing => {},
        .partial => try stream.appendSlice(gpa, trailer[0..2]),
    }
}

/// Writes deflate bits: least significant bit first within each byte,
/// as RFC 1951 orders them.
const BitWriter = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    pending: u32 = 0,
    count: u5 = 0,

    /// Writes the low `len` bits of `value`, least significant first.
    fn write(writer: *BitWriter, value: u32, len: u5) !void {
        for (0..len) |shift| {
            const bit: u32 = (value >> @intCast(shift)) & 1;

            writer.pending |= bit << writer.count;
            writer.count +%= 1;

            if (writer.count == 8) try writer.emit();
        }
    }

    /// Writes a Huffman code of `len` bits, most significant first.
    fn code(writer: *BitWriter, value: u32, len: u5) !void {
        var shift = len;

        while (shift > 0) {
            shift -= 1;
            try writer.write((value >> shift) & 1, 1);
        }
    }

    fn emit(writer: *BitWriter) !void {
        try writer.out.append(writer.gpa, @truncate(writer.pending));
        writer.pending = 0;
        writer.count = 0;
    }

    /// Pads the current byte with zero bits.
    fn flush(writer: *BitWriter) !void {
        if (writer.count != 0) try writer.emit();
    }

    fn storedBlock(writer: *BitWriter, data: []const u8, final: bool) !void {
        try writer.write(@intFromBool(final), 1);
        try writer.write(0b00, 2);
        try writer.flush();

        const len: u16 = @intCast(data.len);

        var header: [4]u8 = undefined;

        std.mem.writeInt(u16, header[0..2], len, .little);
        std.mem.writeInt(u16, header[2..4], ~len, .little);

        try writer.out.appendSlice(writer.gpa, &header);
        try writer.out.appendSlice(writer.gpa, data);
    }

    /// Writes `data` as literals of the fixed Huffman codes, and the end
    /// of the block.
    fn fixedBlock(writer: *BitWriter, data: []const u8, final: bool) !void {
        try writer.write(@intFromBool(final), 1);
        try writer.write(0b01, 2);

        for (data) |literal| {
            if (literal < 144) {
                try writer.code(0x30 + @as(u32, literal), 8);
            } else {
                try writer.code(0x190 + @as(u32, literal) - 144, 9);
            }
        }

        // The end-of-block symbol, 256, has the 7-bit code zero.
        try writer.code(0, 7);
    }
};

const testing = std.testing;

test "a valid image has the signature, IHDR, IDAT, and IEND in order" {
    const bytes = try encode(testing.allocator, .{ .width = 3, .height = 2 });
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, &signature, bytes[0..8]);
    try testing.expectEqualSlices(u8, "IHDR", bytes[12..16]);
    try testing.expectEqualSlices(u8, "IDAT", bytes[header_len + 4 ..][0..4]);
    try testing.expectEqualSlices(u8, "IEND", bytes[bytes.len - 8 ..][0..4]);
}

test "the samples follow the seed" {
    const first = try samples(testing.allocator, .{ .width = 5, .height = 3 });
    defer testing.allocator.free(first);

    const again = try samples(testing.allocator, .{ .width = 5, .height = 3 });
    defer testing.allocator.free(again);

    const other = try samples(testing.allocator, .{
        .width = 5,
        .height = 3,
        .seed = 2,
    });
    defer testing.allocator.free(other);

    try testing.expectEqualSlices(u8, first, again);
    try testing.expect(!std.mem.eql(u8, first, other));
}

test "the zlib stream inflates to the filtered rows" {
    const spec: Spec = .{
        .width = 7,
        .height = 5,
        .filters = .cycle,
        .final_block = .fixed,
    };

    const filtered = try filterRows(testing.allocator, spec);
    defer testing.allocator.free(filtered);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(testing.allocator);

    try writeZlib(testing.allocator, &stream, filtered, spec);

    var input: std.Io.Reader = .fixed(stream.items);

    var buffer: [std.compress.flate.max_window_len]u8 = undefined;

    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &buffer);

    const inflated = try inflate.reader.allocRemaining(
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(inflated);

    try testing.expectEqualSlices(u8, filtered, inflated);
}

test "the iCCP chunk holds a zlib stream of its profile" {
    // The keyword "icc", its end, and the compression method precede the
    // stream.
    var input: std.Io.Reader = .fixed(iccp.data[5..]);

    var buffer: [std.compress.flate.max_window_len]u8 = undefined;

    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &buffer);

    const inflated = try inflate.reader.allocRemaining(
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(inflated);

    try testing.expectEqualSlices(u8, &iccp_profile, inflated);
}

test "packed rows index their palette and keep their unused bits" {
    const spec: Spec = .{
        .width = 13,
        .height = 3,
        .format = .palette2,
        .palette_entries = 3,
        .faults = .{ .palette_index = 1 },
    };

    const raw = try samples(testing.allocator, spec);
    defer testing.allocator.free(raw);

    // 13 samples of 2 bits fill 26 bits of 4 bytes.
    try testing.expectEqual(4, spec.rowBytes());
    try testing.expectEqual(3 * 4, raw.len);

    for (0..spec.height) |row| {
        const line = raw[row * 4 ..][0..4];

        try testing.expectEqual(0, line[3] & 0x3f);

        for (0..spec.width) |column| {
            const index = sampleAt(line, column, 2);

            if (row == 1 and column == spec.width - 1) {
                try testing.expectEqual(3, index);
            } else {
                try testing.expect(index < 3);
            }
        }
    }

    var filled = spec;

    filled.fill_padding = true;

    const padded = try samples(testing.allocator, filled);
    defer testing.allocator.free(padded);

    for (0..spec.height) |row| {
        try testing.expectEqual(0x3f, padded[row * 4 + 3] & 0x3f);
    }
}
