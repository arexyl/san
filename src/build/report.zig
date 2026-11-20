//! Report on a linked Android library, for the reader who reverse
//! engineers it. The report states what the inspection gate does not
//! judge, and it never fails for what it finds.
//!
//! Usage: report <abi> <artifact> <library> <libc stub> <output>
//!
//! <abi> and <artifact> are spelled as the inspection tool takes them.
//! <library> is the unstripped linked file, and <libc stub> the
//! API-level stub of Bionic's libc.so that the library links against,
//! whose exports are the libc names. The tool writes the report to
//! <output>:
//! - the GNU property bits of the ABI, required or not;
//! - the needed libraries;
//! - each libc name that the library imports or defines, with whether
//!   its call sites bind to Bionic or to a copy inside the library;
//! - the symbols that came from compiler_rt, with their sizes;
//! - the size of each section, and of each symbol, largest first.
//!
//! The tool exits 2 on a usage error, on a file that it cannot read or
//! write, and on a file that is not a 64-bit little-endian ELF library.

const std = @import("std");
const elf = std.elf;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const allowlist = @import("allowlist.zig");
const inspect = @import("inspect.zig");
const profile = @import("profile.zig");

/// The largest file that the tool reads.
const max_file_len = 1024 * 1024 * 1024;

/// The name of the FILE symbol of Zig's compiler_rt object.
const compiler_rt = "compiler_rt";

/// A feature bit of the GNU property note, with its name.
const Feature = struct {
    name: []const u8,
    bit: u32,
};

/// The type of the property that holds the feature bits of an ABI, and
/// the bits that the report names.
fn featuresOf(abi: profile.Abi) struct { u32, []const Feature } {
    return switch (abi) {
        // GNU_PROPERTY_AARCH64_FEATURE_1_AND.
        .@"arm64-v8a" => .{ 0xc000_0000, &.{
            .{ .name = "BTI", .bit = 1 << 0 },
            .{ .name = "PAC", .bit = 1 << 1 },
            .{ .name = "GCS", .bit = 1 << 2 },
        } },
        // GNU_PROPERTY_X86_FEATURE_1_AND.
        .x86_64 => .{ 0xc000_0002, &.{
            .{ .name = "IBT", .bit = 1 << 0 },
            .{ .name = "SHSTK", .bit = 1 << 1 },
        } },
    };
}

/// Returns the value of the property `wanted` in the GNU property notes
/// of `sections`, or 0 when no note holds it. A note is a 12-byte header,
/// the name `GNU`, and properties of a type, a size, and data padded to
/// 8 bytes.
fn propertyBits(sections: []const inspect.Section, wanted: u32) u32 {
    const note_type_property = 5;

    for (sections) |section| {
        if (section.type != .NOTE) continue;
        if (!std.mem.eql(u8, section.name, ".note.gnu.property")) continue;

        const note = section.contents;

        if (note.len < 16) continue;

        const name_len = std.mem.readInt(u32, note[0..4], .little);
        const desc_len = std.mem.readInt(u32, note[4..8], .little);
        const note_type = std.mem.readInt(u32, note[8..12], .little);

        const named = name_len == 4 and
            std.mem.eql(u8, note[12..16], "GNU\x00");

        if (!named or note_type != note_type_property) continue;
        if (desc_len > note.len - 16) continue;

        var rest = note[16..][0..desc_len];

        while (rest.len >= 8) {
            const kind = std.mem.readInt(u32, rest[0..4], .little);
            const size = std.mem.readInt(u32, rest[4..8], .little);

            if (size > rest.len - 8) break;

            if (kind == wanted and size >= 4) {
                return std.mem.readInt(u32, rest[8..12], .little);
            }

            const padded = std.mem.alignForward(usize, size, 8);

            if (padded > rest.len - 8) break;

            rest = rest[8 + padded ..];
        }
    }

    return 0;
}

/// A symbol of the static symbol table, which only the unstripped file
/// holds.
const StaticSymbol = struct {
    name: []const u8,
    kind: elf.STT,
    defined: bool,
    address: u64,
    size: u64,
    /// The name of the FILE symbol before a local symbol: the object
    /// that it came from. Null for a global symbol, which follows no
    /// FILE symbol.
    origin: ?[]const u8,

    /// Orders by size, largest first, then by name.
    fn bySize(_: void, a: StaticSymbol, b: StaticSymbol) bool {
        if (a.size != b.size) return a.size > b.size;

        return std.mem.lessThan(u8, a.name, b.name);
    }
};

/// Returns the symbols of the static symbol table of `sections` other
/// than its FILE symbols, or none when the file holds no such table.
fn readStaticSymbols(
    arena: Allocator,
    sections: []const inspect.Section,
) Allocator.Error![]const StaticSymbol {
    const record_len = @sizeOf(elf.Elf64.Sym);

    const table = for (sections) |section| {
        if (section.type == .SYMTAB) break section;
    } else return &.{};

    if (table.link >= sections.len) return &.{};

    const strings = sections[table.link].contents;

    var symbols: std.ArrayList(StaticSymbol) = .empty;
    var origin: ?[]const u8 = null;

    // The symbol at index 0 is the null symbol.
    var at: usize = record_len;

    while (at + record_len <= table.contents.len) : (at += record_len) {
        const record = table.contents[at..][0..record_len];

        const name_at = std.mem.readInt(u32, record[0..4], .little);
        const shndx = std.mem.readInt(u16, record[6..8], .little);
        const address = std.mem.readInt(u64, record[8..16], .little);
        const size = std.mem.readInt(u64, record[16..24], .little);

        const info = record[4];

        const kind: elf.STT = @fromBackingInt(@as(u4, @truncate(info)));
        const bind: elf.STB = @fromBackingInt(@as(u4, @truncate(info >> 4)));

        const name = inspect.stringAt(strings, name_at) orelse continue;

        if (kind == .FILE) {
            origin = name;

            continue;
        }

        try symbols.append(arena, .{
            .name = name,
            .kind = kind,
            .defined = shndx != elf.SHN_UNDEF,
            .address = address,
            .size = size,
            .origin = if (bind == .LOCAL) origin else null,
        });
    }

    return symbols.items;
}

/// Reports whether `symbols` holds an import of `name`.
fn imports(symbols: []const inspect.Symbol, name: []const u8) bool {
    for (symbols) |symbol| {
        if (!symbol.defined and std.mem.eql(u8, symbol.name, name)) return true;
    }

    return false;
}

/// Reports whether `symbols` holds an export of `name`.
fn exports(symbols: []const inspect.Symbol, name: []const u8) bool {
    for (symbols) |symbol| {
        if (!symbol.exported()) continue;

        if (std.mem.eql(u8, symbol.name, name)) return true;
    }

    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The inputs of one report.
pub const Subject = struct {
    abi: profile.Abi,
    artifact: allowlist.Artifact,
    /// The length of the library's file in bytes.
    file_len: usize,
    library: inspect.Image,
    /// The dynamic symbols of the libc stub. A name that the stub exports
    /// is a libc name.
    libc: []const inspect.Symbol,
};

/// Writes the report on `subject` to `out`.
pub fn write(
    arena: Allocator,
    out: *Io.Writer,
    subject: Subject,
) (Allocator.Error || Io.Writer.Error)!void {
    const library = subject.library;

    const symbols = try readStaticSymbols(arena, library.sections);

    try out.print("inspection report: {t} for {t}, {d} bytes\n", .{
        subject.artifact,
        subject.abi,
        subject.file_len,
    });

    try out.writeAll("\nGNU properties\n");

    const property, const features = featuresOf(subject.abi);

    const bits = propertyBits(library.sections, property);

    for (features) |feature| {
        try out.print("  {s}: {s}\n", .{
            feature.name,
            if (bits & feature.bit != 0) "present" else "absent",
        });
    }

    try out.writeAll("\nneeded libraries\n");

    for (library.needed) |name| try out.print("  {s}\n", .{name});

    try writeLibcNames(arena, out, subject, symbols);
    try writeCompilerRt(arena, out, symbols);

    try out.writeAll("\nsections, in bytes\n");

    for (library.sections) |section| {
        if (section.name.len == 0) continue;

        try out.print("  {d:>9}  {s}\n", .{ section.size, section.name });
    }

    try writeSymbols(arena, out, symbols);
}

/// Writes each libc name that the library imports or defines, in the
/// order of the names. An import binds its call sites to Bionic, and a
/// definition binds them to the copy inside the library.
fn writeLibcNames(
    arena: Allocator,
    out: *Io.Writer,
    subject: Subject,
    symbols: []const StaticSymbol,
) (Allocator.Error || Io.Writer.Error)!void {
    var names: std.ArrayList([]const u8) = .empty;

    for (subject.library.symbols) |symbol| {
        if (symbol.defined or !exports(subject.libc, symbol.name)) continue;

        try names.append(arena, symbol.name);
    }

    for (symbols) |symbol| {
        if (!symbol.defined or !exports(subject.libc, symbol.name)) continue;
        if (imports(subject.library.symbols, symbol.name)) continue;

        try names.append(arena, symbol.name);
    }

    std.mem.sort([]const u8, names.items, {}, lessThan);

    try out.writeAll("\nlibc names\n");

    for (names.items) |name| {
        if (imports(subject.library.symbols, name)) {
            try out.print("  {s}: Bionic\n", .{name});
        }

        for (symbols) |symbol| {
            if (!symbol.defined) continue;
            if (!std.mem.eql(u8, symbol.name, name)) continue;

            try out.print("  {s}: embedded, {d} bytes, from {s}\n", .{
                name,
                symbol.size,
                symbol.origin orelse "a global definition",
            });
        }
    }
}

/// Writes the defined symbols that follow the FILE symbol of compiler_rt,
/// largest first, with their count and the bytes that they cover.
/// compiler_rt names one routine twice, as `memcpy` and under its own
/// name, so the bytes count each address once.
fn writeCompilerRt(
    arena: Allocator,
    out: *Io.Writer,
    symbols: []const StaticSymbol,
) (Allocator.Error || Io.Writer.Error)!void {
    var helpers: std.ArrayList(StaticSymbol) = .empty;
    var bytes: u64 = 0;

    for (symbols) |symbol| {
        const origin = symbol.origin orelse continue;

        if (!symbol.defined or !std.mem.eql(u8, origin, compiler_rt)) continue;
        if (symbol.kind != .FUNC and symbol.kind != .OBJECT) continue;

        const alias = for (helpers.items) |earlier| {
            if (earlier.address == symbol.address) break true;
        } else false;

        if (!alias) bytes += symbol.size;

        try helpers.append(arena, symbol);
    }

    std.mem.sort(StaticSymbol, helpers.items, {}, StaticSymbol.bySize);

    try out.print("\nembedded compiler_rt symbols: {d}, {d} bytes\n", .{
        helpers.items.len,
        bytes,
    });

    for (helpers.items) |helper| {
        try out.print("  {d:>9}  {s}\n", .{ helper.size, helper.name });
    }
}

/// Writes every defined function and object with a size, largest first.
fn writeSymbols(
    arena: Allocator,
    out: *Io.Writer,
    symbols: []const StaticSymbol,
) (Allocator.Error || Io.Writer.Error)!void {
    var sized: std.ArrayList(StaticSymbol) = .empty;

    for (symbols) |symbol| {
        if (!symbol.defined or symbol.size == 0) continue;
        if (symbol.kind != .FUNC and symbol.kind != .OBJECT) continue;

        try sized.append(arena, symbol);
    }

    std.mem.sort(StaticSymbol, sized.items, {}, StaticSymbol.bySize);

    try out.print("\nsymbols, in bytes: {d}\n", .{sized.items.len});

    for (sized.items) |symbol| {
        try out.print("  {d:>9}  {s}  {s}\n", .{
            symbol.size,
            if (symbol.kind == .FUNC) "function" else "object  ",
            symbol.name,
        });
    }
}

const Arguments = struct {
    abi: profile.Abi,
    artifact: allowlist.Artifact,
    library: []const u8,
    libc: []const u8,
    output: []const u8,
};

fn parseArguments(args: []const [:0]const u8) ?Arguments {
    if (args.len != 6) return null;

    return .{
        .abi = std.meta.stringToEnum(profile.Abi, args[1]) orelse return null,
        .artifact = std.meta.stringToEnum(allowlist.Artifact, args[2]) orelse
            return null,
        .library = args[3],
        .libc = args[4],
        .output = args[5],
    };
}

/// Reads the ELF file at `path`, or ends the tool with exit 2.
fn readImage(io: Io, arena: Allocator, path: []const u8) !struct {
    usize,
    inspect.Image,
} {
    const bytes = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(max_file_len),
    ) catch |err| {
        std.debug.print("report: cannot read {s}: {t}\n", .{ path, err });

        std.process.exit(2);
    };

    const identified = bytes.len >= elf.EI.NIDENT and
        std.mem.eql(u8, bytes[0..elf.MAGIC.len], elf.MAGIC) and
        bytes[elf.EI.CLASS] == @backingInt(elf.CLASS.@"64") and
        bytes[elf.EI.DATA] == @backingInt(elf.DATA.@"2LSB");

    var problem: []const u8 = "the file is not a 64-bit little-endian ELF file";

    if (identified) {
        if (inspect.Image.read(arena, bytes, &problem)) |image| {
            return .{ bytes.len, image };
        } else |err| switch (err) {
            error.Malformed => {},
            error.OutOfMemory => |e| return e,
        }
    }

    std.debug.print("report: {s}: {s}\n", .{ path, problem });

    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const arguments = parseArguments(args) orelse {
        std.debug.print(
            "usage: report <abi> <artifact> <library> <libc stub> <output>\n",
            .{},
        );

        std.process.exit(2);
    };

    const file_len, const library = try readImage(io, arena, arguments.library);

    _, const libc = try readImage(io, arena, arguments.libc);

    var text: Io.Writer.Allocating = .init(arena);

    try write(arena, &text.writer, .{
        .abi = arguments.abi,
        .artifact = arguments.artifact,
        .file_len = file_len,
        .library = library,
        .libc = libc.symbols,
    });

    Io.Dir.cwd().writeFile(io, .{
        .sub_path = arguments.output,
        .data = text.written(),
    }) catch |err| {
        std.debug.print("report: cannot write {s}: {t}\n", .{
            arguments.output,
            err,
        });

        std.process.exit(2);
    };
}

const testing = std.testing;

/// Returns a section of the tests.
fn testSection(
    name: []const u8,
    kind: elf.SHT,
    link: u32,
    contents: []const u8,
) inspect.Section {
    return .{
        .name = name,
        .type = kind,
        .flags = 0,
        .addr = 0,
        .offset = 0,
        .size = contents.len,
        .link = link,
        .entsize = 0,
        .contents = contents,
    };
}

/// Returns a GNU property note with one property of `kind` and `value`,
/// after a property of another kind, as a linker writes them.
fn propertyNote(kind: u32, value: u32) [48]u8 {
    var note: [48]u8 = @splat(0);

    std.mem.writeInt(u32, note[0..4], 4, .little);
    std.mem.writeInt(u32, note[4..8], 32, .little);
    std.mem.writeInt(u32, note[8..12], 5, .little);
    @memcpy(note[12..16], "GNU\x00");

    // A property that the report does not name, with 4 bytes of data and
    // 4 bytes of padding.
    std.mem.writeInt(u32, note[16..20], 0xc000_8000, .little);
    std.mem.writeInt(u32, note[20..24], 4, .little);
    std.mem.writeInt(u32, note[24..28], 0xffff_ffff, .little);

    std.mem.writeInt(u32, note[32..36], kind, .little);
    std.mem.writeInt(u32, note[36..40], 4, .little);
    std.mem.writeInt(u32, note[40..44], value, .little);

    return note;
}

test "the property bits come from the GNU property note of the ABI" {
    const arm = propertyNote(0xc000_0000, 0b011);

    const sections = [_]inspect.Section{
        testSection(".note.android.ident", .NOTE, 0, &arm),
        testSection(".note.gnu.property", .NOTE, 0, &arm),
    };

    try testing.expectEqual(0b011, propertyBits(&sections, 0xc000_0000));
    try testing.expectEqual(0, propertyBits(&sections, 0xc000_0002));
    try testing.expectEqual(0, propertyBits(sections[0..1], 0xc000_0000));

    // A truncated note and a note of another name give no bit.
    for (0..arm.len) |len| {
        const cut = [_]inspect.Section{
            testSection(".note.gnu.property", .NOTE, 0, arm[0..len]),
        };

        try testing.expectEqual(0, propertyBits(&cut, 0xc000_0000));
    }
}

/// Appends one record of a static symbol table to `table`.
fn appendSymbol(
    table: *std.ArrayList(u8),
    name_at: u32,
    kind: elf.STT,
    bind: elf.STB,
    shndx: u16,
    address: u64,
    size: u64,
) !void {
    var record: [@sizeOf(elf.Elf64.Sym)]u8 = @splat(0);

    std.mem.writeInt(u32, record[0..4], name_at, .little);
    record[4] = @as(u8, @backingInt(bind)) << 4 | @backingInt(kind);
    std.mem.writeInt(u16, record[6..8], shndx, .little);
    std.mem.writeInt(u64, record[8..16], address, .little);
    std.mem.writeInt(u64, record[16..24], size, .little);

    try table.appendSlice(testing.allocator, &record);
}

test "a report names the bindings, the helpers, and the sizes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    // Offsets: san 1, compiler_rt 5, memcpy 17, engine 24, JNI_OnLoad 31,
    // malloc 42, memcpyFast 49.
    const strings = "\x00san\x00compiler_rt\x00memcpy\x00engine\x00" ++
        "JNI_OnLoad\x00malloc\x00memcpyFast\x00";

    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(testing.allocator);

    try appendSymbol(&table, 0, .NOTYPE, .LOCAL, 0, 0, 0);
    try appendSymbol(&table, 1, .FILE, .LOCAL, 0xfff1, 0, 0);
    try appendSymbol(&table, 24, .OBJECT, .LOCAL, 2, 0x4000, 24);
    try appendSymbol(&table, 5, .FILE, .LOCAL, 0xfff1, 0, 0);
    // compiler_rt names one routine twice.
    try appendSymbol(&table, 17, .FUNC, .LOCAL, 1, 0x1000, 260);
    try appendSymbol(&table, 49, .FUNC, .LOCAL, 1, 0x1000, 260);
    try appendSymbol(&table, 31, .FUNC, .GLOBAL, 1, 0x2000, 336);
    try appendSymbol(&table, 42, .FUNC, .GLOBAL, 0, 0, 0);

    const note = propertyNote(0xc000_0000, 0b011);

    const sections = [_]inspect.Section{
        testSection("", .NULL, 0, ""),
        testSection(".note.gnu.property", .NOTE, 0, &note),
        testSection(".symtab", .SYMTAB, 3, table.items),
        testSection(".strtab", .STRTAB, 0, strings),
    };

    const library: inspect.Image = .{
        .header = undefined,
        .segments = &.{},
        .sections = &sections,
        .symbols = &.{
            .{ .name = "JNI_OnLoad", .bind = .GLOBAL, .defined = true },
            .{ .name = "malloc", .bind = .GLOBAL, .defined = false },
            .{ .name = "not_libc", .bind = .GLOBAL, .defined = false },
        },
        .needed = &.{"libc.so"},
        .textrel = false,
        .flags = 0,
    };

    const libc = [_]inspect.Symbol{
        .{ .name = "malloc", .bind = .GLOBAL, .defined = true },
        .{ .name = "memcpy", .bind = .WEAK, .defined = true },
        .{ .name = "free", .bind = .GLOBAL, .defined = true },
    };

    var text: Io.Writer.Allocating = .init(arena);

    try write(arena, &text.writer, .{
        .abi = .@"arm64-v8a",
        .artifact = .san,
        .file_len = 4096,
        .library = library,
        .libc = &libc,
    });

    try testing.expectEqualStrings(
        \\inspection report: san for arm64-v8a, 4096 bytes
        \\
        \\GNU properties
        \\  BTI: present
        \\  PAC: present
        \\  GCS: absent
        \\
        \\needed libraries
        \\  libc.so
        \\
        \\libc names
        \\  malloc: Bionic
        \\  memcpy: embedded, 260 bytes, from compiler_rt
        \\
        \\embedded compiler_rt symbols: 2, 260 bytes
        \\        260  memcpy
        \\        260  memcpyFast
        \\
        \\sections, in bytes
        \\         48  .note.gnu.property
        \\        192  .symtab
        \\         60  .strtab
        \\
        \\symbols, in bytes: 4
        \\        336  function  JNI_OnLoad
        \\        260  function  memcpy
        \\        260  function  memcpyFast
        \\         24  object    engine
        \\
    , text.written());
}

test "a library without a static symbol table reports no symbol" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const sections = [_]inspect.Section{testSection("", .NULL, 0, "")};

    const symbols = try readStaticSymbols(arena_state.allocator(), &sections);

    try testing.expectEqual(0, symbols.len);
    try testing.expectEqual(0, propertyBits(&sections, 0xc000_0002));
}

test "the arguments name an abi, an artifact, and three files" {
    const good = [_][:0]const u8{
        "report", "x86_64", "san", "libsan.so", "libc.so", "out.txt",
    };

    const arguments = parseArguments(&good).?;

    try testing.expectEqual(.x86_64, arguments.abi);
    try testing.expectEqual(.san, arguments.artifact);
    try testing.expectEqualStrings("out.txt", arguments.output);

    try testing.expectEqual(null, parseArguments(good[0..5]));

    const unknown = [_][:0]const u8{
        "report", "arm64", "san", "libsan.so", "libc.so", "out.txt",
    };

    try testing.expectEqual(null, parseArguments(&unknown));
}
