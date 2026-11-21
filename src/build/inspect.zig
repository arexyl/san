//! Inspect a linked Android library against the rules of San's
//! inspection gate.
//!
//! Usage: inspect <abi> <artifact> <library>
//!
//! <abi> is an ABI of the build profile, spelled as -Dabi takes it.
//! <artifact> is a kind of `allowlist.Artifact`, which declares the
//! exports. <library> is the path of the linked file. The tool reads the
//! whole file and checks it with std.elf against every `Rule`. It prints
//! one line for each failure, which names the rule, and exits 1 when any
//! rule fails. It exits 2 on a usage error and on a file that it cannot
//! read. A pass does not show that Android loads or runs the library.

const std = @import("std");
const elf = std.elf;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const allowlist = @import("allowlist.zig");
const profile = @import("profile.zig");

/// The smallest alignment of a LOAD segment: the page size of the
/// profile, on which every San artifact must map.
pub const min_load_align = profile.page_size;

/// The largest file that the tool reads. An unstripped library with its
/// debug sections stays far below it.
const max_file_len = 1024 * 1024 * 1024;

/// The mask and the bits of the A64 `svc #imm16` encoding,
/// 0xD4000001 | imm16 << 5.
const svc_mask: u32 = 0xFFE0001F;
const svc_bits: u32 = 0xD4000001;

/// The kinds of `allowlist.Artifact`, spelled as the tool takes them.
const artifact_names = names: {
    var text: []const u8 = "";

    for (std.enums.values(allowlist.Artifact)) |artifact| {
        text = text ++ (if (text.len == 0) "" else ", ") ++ @tagName(artifact);
    }

    break :names text;
};

/// A rule of the inspection, in the order of the report.
pub const Rule = enum {
    /// The file is an ELF file whose headers and dynamic tables the tool
    /// can read, and its section headers describe the dynamic segment
    /// that the loader reads. No other rule can be judged without it.
    format,
    /// The file is a 64-bit little-endian ELF file, as both ABIs require.
    class,
    /// The machine is the ABI's: AArch64 on arm64-v8a, x86-64 on x86_64.
    machine,
    /// The global or weak defined dynamic symbols, of any visibility, are
    /// exactly the exports that the artifact declares.
    /// Hiding the rest lets LTO and section collection drop what the
    /// exports do not reach, and no San symbol can interpose a system one.
    exports,
    /// Every undefined dynamic symbol is on the import allowlist, in a
    /// library that the artifact needs, so each dependency on the system
    /// has a named consumer and reason.
    imports,
    /// The DT_NEEDED entries are exactly the allowed libraries of the
    /// artifact. An extra library brings code that the device may lack
    /// or that the allowlist forbids, and a missing one leaves the
    /// imports without a provider.
    needed,
    /// Every LOAD segment is aligned to at least `min_load_align`.
    load_align,
    /// A PT_GNU_STACK entry exists, and none marks the stack executable,
    /// so data on the stack never runs as code.
    gnu_stack,
    /// No DT_TEXTREL entry and no DF_TEXTREL flag: a text relocation
    /// makes code pages writable, and Android refuses it from API level
    /// 23.
    textrel,
    /// On arm64-v8a, no executable section holds an svc instruction.
    /// Without libc, Zig's standard library reaches the kernel through
    /// raw svc instructions, which import nothing, so the imports rule
    /// cannot see them.
    svc,
};

/// A failed rule and what failed.
pub const Failure = struct {
    rule: Rule,
    detail: []const u8,
};

/// Checks `bytes`, the file of an `artifact` library for `abi`, against
/// every rule, and returns the failures in the order of `Rule`. A format
/// or class failure ends the inspection, because the other rules read
/// the tables of a 64-bit little-endian file. `arena` owns the result.
pub fn inspect(
    arena: Allocator,
    bytes: []const u8,
    abi: profile.Abi,
    artifact: allowlist.Artifact,
) Allocator.Error![]const Failure {
    var failures: Failures = .{ .arena = arena };

    const identified = bytes.len >= elf.EI.NIDENT and
        std.mem.eql(u8, bytes[0..elf.MAGIC.len], elf.MAGIC);

    if (!identified) {
        try failures.add(.format, "the file is not an ELF file", .{});

        return failures.list.items;
    }

    const class: elf.CLASS = @fromBackingInt(bytes[elf.EI.CLASS]);
    const data: elf.DATA = @fromBackingInt(bytes[elf.EI.DATA]);

    if (class != .@"64" or data != .@"2LSB") {
        try failures.add(
            .class,
            "class {d} and data encoding {d}; {t} needs ELFCLASS64 ({d}) " ++
                "and ELFDATA2LSB ({d})",
            .{
                @backingInt(class),
                @backingInt(data),
                abi,
                @backingInt(elf.CLASS.@"64"),
                @backingInt(elf.DATA.@"2LSB"),
            },
        );

        return failures.list.items;
    }

    var problem: []const u8 = "";

    const image = Image.read(arena, bytes, &problem) catch |err| switch (err) {
        error.Malformed => {
            try failures.add(.format, "{s}", .{problem});

            return failures.list.items;
        },
        error.OutOfMemory => |e| return e,
    };

    try checkMachine(&failures, image, abi);
    try checkExports(&failures, image, artifact);
    try checkImports(&failures, image, artifact);
    try checkNeeded(&failures, image, artifact);
    try checkLoadAlign(&failures, image);
    try checkGnuStack(&failures, image);
    try checkTextrel(&failures, image);
    try checkSvc(&failures, image, abi);

    return failures.list.items;
}

/// The failures of one inspection, allocated in `arena`.
const Failures = struct {
    arena: Allocator,
    list: std.ArrayList(Failure) = .empty,

    fn add(
        failures: *Failures,
        rule: Rule,
        comptime template: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        const detail = try std.fmt.allocPrint(failures.arena, template, args);

        try failures.list.append(failures.arena, .{
            .rule = rule,
            .detail = detail,
        });
    }
};

/// A section header with its name and its bytes in the file.
pub const Section = struct {
    name: []const u8,
    type: elf.SHT,
    flags: u64,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    entsize: u64,
    /// The bytes of the section in the file; empty for SHT_NOBITS.
    contents: []const u8,
};

/// A dynamic symbol, decoded from its Elf64.Sym record.
pub const Symbol = struct {
    name: []const u8,
    bind: elf.STB,
    defined: bool,

    const name_at = @offsetOf(elf.Elf64.Sym, "name");
    const info_at = @offsetOf(elf.Elf64.Sym, "info");
    const shndx_at = @offsetOf(elf.Elf64.Sym, "shndx");

    /// Decodes a little-endian record whose name lies in `strings`, or
    /// returns null when the name does not.
    fn decode(
        record: *const [@sizeOf(elf.Elf64.Sym)]u8,
        strings: []const u8,
    ) ?Symbol {
        const name = std.mem.readInt(u32, record[name_at..][0..4], .little);

        const shndx = std.mem.readInt(u16, record[shndx_at..][0..2], .little);

        const info = record[info_at];

        return .{
            .name = stringAt(strings, name) orelse return null,
            .bind = @fromBackingInt(@as(u4, @truncate(info >> 4))),
            .defined = shndx != elf.SHN_UNDEF,
        };
    }

    /// Reports whether the symbol counts as an export: a defined global or
    /// weak symbol, whatever its visibility. The generic ABI turns a
    /// hidden or internal symbol local in a linked object, so one in the
    /// dynamic table is malformed. The tool counts it rather than trust
    /// that the loader reads the visibility before it binds the name.
    pub fn exported(symbol: Symbol) bool {
        const binding = symbol.bind == .GLOBAL or symbol.bind == .WEAK;

        return symbol.defined and binding;
    }
};

/// The parts of a 64-bit little-endian ELF file that the rules read, with
/// every offset, size, and name checked against the file.
pub const Image = struct {
    header: elf.Header,
    segments: []const elf.Elf64.Phdr,
    sections: []const Section,
    /// The dynamic symbols without the null symbol at index 0.
    symbols: []const Symbol,
    /// The names of the DT_NEEDED entries.
    needed: []const []const u8,
    /// Whether the dynamic section holds DT_TEXTREL.
    textrel: bool,
    /// The union of every DT_FLAGS value.
    flags: u64,

    pub const ReadError = Allocator.Error || error{Malformed};

    /// Reads `bytes`, whose identification already names a 64-bit
    /// little-endian file. On error.Malformed, `problem` holds the reason.
    pub fn read(
        arena: Allocator,
        bytes: []const u8,
        problem: *[]const u8,
    ) ReadError!Image {
        var reader: Io.Reader = .fixed(bytes);

        const header = elf.Header.read(&reader) catch return malformed(
            problem,
            "the ELF header is truncated or invalid",
        );

        const segments = try readSegments(arena, bytes, header, problem);

        const sections = try readSections(arena, bytes, header, problem);

        const symtab = try onlySection(sections, .DYNSYM, problem);

        const dynamic = try onlySection(sections, .DYNAMIC, problem);

        const strings = try linkedStrings(sections, symtab, dynamic, problem);

        try matchDynamicSegment(segments, dynamic, problem);

        const entries = try readDynamic(arena, bytes, header, dynamic, problem);

        const strtab = entries.strtab orelse
            return malformed(problem, "the dynamic section has no DT_STRTAB");

        const symtab_addr = entries.symtab orelse
            return malformed(problem, "the dynamic section has no DT_SYMTAB");

        if (strtab != strings.addr or symtab_addr != symtab.addr) {
            return malformed(problem, "DT_STRTAB or DT_SYMTAB differs from " ++
                "the address of the section that the headers name");
        }

        const needed = try arena.alloc([]const u8, entries.needed.len);

        for (entries.needed, needed) |offset, *name| {
            name.* = stringAt(strings.contents, offset) orelse return malformed(
                problem,
                "a DT_NEEDED name lies outside the dynamic string table",
            );
        }

        const symbols = try readSymbols(
            arena,
            symtab.contents,
            strings.contents,
            problem,
        );

        return .{
            .header = header,
            .segments = segments,
            .sections = sections,
            .symbols = symbols,
            .needed = needed,
            .textrel = entries.textrel,
            .flags = entries.flags,
        };
    }
};

fn malformed(problem: *[]const u8, reason: []const u8) error{Malformed} {
    problem.* = reason;

    return error.Malformed;
}

/// Reports whether `size` bytes at `offset` lie inside `bytes`.
fn within(bytes: []const u8, offset: u64, size: u64) bool {
    const end = std.math.add(u64, offset, size) catch return false;

    return end <= bytes.len;
}

/// Returns the NUL-terminated string at `offset` of `table`, or null when
/// it does not lie inside the table.
pub fn stringAt(table: []const u8, offset: u64) ?[]const u8 {
    if (offset >= table.len) return null;

    const rest = table[@intCast(offset)..];

    const end = std.mem.findScalar(u8, rest, 0) orelse return null;

    return rest[0..end];
}

fn readSegments(
    arena: Allocator,
    bytes: []const u8,
    header: elf.Header,
    problem: *[]const u8,
) Image.ReadError![]const elf.Elf64.Phdr {
    const entry_size = @sizeOf(elf.Elf64.Phdr);

    if (header.phnum == 0) {
        return malformed(problem, "the file has no program headers");
    }

    if (header.phentsize != entry_size) {
        return malformed(problem, "the program headers are not ELF64 " ++
            "program headers");
    }

    if (!within(bytes, header.phoff, @as(u64, header.phnum) * entry_size)) {
        return malformed(problem, "the program header table lies outside " ++
            "the file");
    }

    const segments = try arena.alloc(elf.Elf64.Phdr, header.phnum);

    var iterator = header.iterateProgramHeadersBuffer(bytes);

    for (segments) |*segment| {
        segment.* = (iterator.next() catch null) orelse return malformed(
            problem,
            "a program header is truncated",
        );
    }

    return segments;
}

fn readSections(
    arena: Allocator,
    bytes: []const u8,
    header: elf.Header,
    problem: *[]const u8,
) Image.ReadError![]const Section {
    const entry_size = @sizeOf(elf.Elf64.Shdr);

    if (header.shnum == 0) {
        return malformed(problem, "the file has no section headers");
    }

    if (header.shentsize != entry_size) {
        return malformed(problem, "the section headers are not ELF64 " ++
            "section headers");
    }

    if (!within(bytes, header.shoff, @as(u64, header.shnum) * entry_size)) {
        return malformed(problem, "the section header table lies outside " ++
            "the file");
    }

    if (header.shstrndx >= header.shnum) {
        return malformed(problem, "the section name table index is out " ++
            "of range");
    }

    const sections = try arena.alloc(Section, header.shnum);

    const name_offsets = try arena.alloc(u32, header.shnum);

    var iterator = header.iterateSectionHeadersBuffer(bytes);

    for (sections, name_offsets) |*section, *name_offset| {
        const raw = (iterator.next() catch null) orelse return malformed(
            problem,
            "a section header is truncated",
        );

        const kind: elf.SHT = @fromBackingInt(raw.sh_type);

        const contents = contentsOf(
            bytes,
            kind,
            raw.sh_offset,
            raw.sh_size,
        ) orelse return malformed(problem, "a section lies outside the file");

        name_offset.* = raw.sh_name;

        section.* = .{
            .name = "",
            .type = kind,
            .flags = raw.sh_flags,
            .addr = raw.sh_addr,
            .offset = raw.sh_offset,
            .size = raw.sh_size,
            .link = raw.sh_link,
            .entsize = raw.sh_entsize,
            .contents = contents,
        };
    }

    const names = sections[header.shstrndx];

    if (names.type != .STRTAB) {
        return malformed(problem, "the section name table is not a string " ++
            "table");
    }

    for (sections, name_offsets) |*section, name_offset| {
        section.name = stringAt(names.contents, name_offset) orelse
            return malformed(problem, "a section name lies outside the " ++
                "section name table");
    }

    return sections;
}

/// Returns the bytes of a section, or null when they do not lie inside
/// `bytes`. A SHT_NOBITS section occupies no bytes of the file.
fn contentsOf(
    bytes: []const u8,
    kind: elf.SHT,
    offset: u64,
    size: u64,
) ?[]const u8 {
    if (kind == .NOBITS) return &.{};

    if (!within(bytes, offset, size)) return null;

    return bytes[@intCast(offset)..][0..@intCast(size)];
}

/// Returns the one section of type `kind`. The loader reads one dynamic
/// section and one dynamic symbol table, so a file with none or with two
/// cannot be judged.
fn onlySection(
    sections: []const Section,
    kind: elf.SHT,
    problem: *[]const u8,
) error{Malformed}!Section {
    var found: ?Section = null;
    var count: usize = 0;

    for (sections) |section| {
        if (section.type != kind) continue;

        found = section;
        count += 1;
    }

    if (count != 1) {
        return malformed(problem, "the file needs exactly one SHT_DYNSYM " ++
            "and one SHT_DYNAMIC section");
    }

    return found.?;
}

/// Returns the dynamic string table, which the dynamic symbol table and
/// the dynamic section both link.
fn linkedStrings(
    sections: []const Section,
    symtab: Section,
    dynamic: Section,
    problem: *[]const u8,
) error{Malformed}!Section {
    const record_sizes = symtab.entsize == @sizeOf(elf.Elf64.Sym) and
        dynamic.entsize == @sizeOf(elf.Elf64_Dyn) and
        symtab.size % @sizeOf(elf.Elf64.Sym) == 0 and
        dynamic.size % @sizeOf(elf.Elf64_Dyn) == 0;

    if (!record_sizes) {
        return malformed(problem, "the dynamic symbol table or the dynamic " ++
            "section does not hold whole ELF64 records");
    }

    if (symtab.link != dynamic.link or dynamic.link >= sections.len) {
        return malformed(problem, "the dynamic symbol table and the dynamic " ++
            "section do not link one string table");
    }

    const strings = sections[dynamic.link];

    if (strings.type != .STRTAB) {
        return malformed(problem, "the dynamic string table is not a " ++
            "string table");
    }

    return strings;
}

/// Fails unless the one PT_DYNAMIC segment covers exactly the dynamic
/// section, in the file and in memory, so the tool reads what the loader
/// reads.
fn matchDynamicSegment(
    segments: []const elf.Elf64.Phdr,
    dynamic: Section,
    problem: *[]const u8,
) error{Malformed}!void {
    var count: usize = 0;

    for (segments) |segment| {
        if (segment.type != .DYNAMIC) continue;

        count += 1;

        if (segment.offset != dynamic.offset or
            segment.vaddr != dynamic.addr or
            segment.filesz != dynamic.size)
        {
            return malformed(problem, "the dynamic segment and the dynamic " ++
                "section differ");
        }
    }

    if (count != 1) {
        return malformed(problem, "the file needs exactly one dynamic " ++
            "segment");
    }
}

/// The entries of the dynamic section that the rules and the checks of
/// the format read, up to DT_NULL.
const DynamicEntries = struct {
    /// The string table offsets of the DT_NEEDED names.
    needed: []const u64,
    strtab: ?u64 = null,
    symtab: ?u64 = null,
    textrel: bool = false,
    flags: u64 = 0,
};

fn readDynamic(
    arena: Allocator,
    bytes: []const u8,
    header: elf.Header,
    dynamic: Section,
    problem: *[]const u8,
) Image.ReadError!DynamicEntries {
    var needed: std.ArrayList(u64) = .empty;

    var entries: DynamicEntries = .{ .needed = &.{} };

    var iterator = header.iterateDynamicSectionBuffer(
        bytes,
        dynamic.offset,
        dynamic.size,
    );

    while (true) {
        const entry = (iterator.next() catch null) orelse return malformed(
            problem,
            "the dynamic section has no DT_NULL",
        );

        switch (entry.d_tag) {
            elf.DT_NULL => break,
            elf.DT_NEEDED => try needed.append(arena, entry.d_val),
            elf.DT_STRTAB => entries.strtab = entry.d_val,
            elf.DT_SYMTAB => entries.symtab = entry.d_val,
            elf.DT_TEXTREL => entries.textrel = true,
            elf.DT_FLAGS => entries.flags |= entry.d_val,
            else => {},
        }
    }

    entries.needed = needed.items;

    return entries;
}

fn readSymbols(
    arena: Allocator,
    table: []const u8,
    strings: []const u8,
    problem: *[]const u8,
) Image.ReadError![]const Symbol {
    const record_size = @sizeOf(elf.Elf64.Sym);

    const count = table.len / record_size;

    if (count == 0) {
        return malformed(problem, "the dynamic symbol table lacks the null " ++
            "symbol");
    }

    const symbols = try arena.alloc(Symbol, count - 1);

    for (symbols, 1..) |*symbol, index| {
        const record = table[index * record_size ..][0..record_size];

        symbol.* = Symbol.decode(record, strings) orelse return malformed(
            problem,
            "a dynamic symbol name lies outside the dynamic string table",
        );
    }

    return symbols;
}

fn machineOf(abi: profile.Abi) elf.EM {
    return switch (abi) {
        .@"arm64-v8a" => .AARCH64,
        .x86_64 => .X86_64,
    };
}

fn checkMachine(
    failures: *Failures,
    image: Image,
    abi: profile.Abi,
) Allocator.Error!void {
    const expected = machineOf(abi);

    if (image.header.machine == expected) return;

    try failures.add(.machine, "machine {d}; {t} needs {d} ({t})", .{
        @backingInt(image.header.machine),
        abi,
        @backingInt(expected),
        expected,
    });
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }

    return false;
}

fn checkExports(
    failures: *Failures,
    image: Image,
    artifact: allowlist.Artifact,
) Allocator.Error!void {
    const declared = artifact.exports();

    for (image.symbols) |symbol| {
        if (!symbol.exported() or contains(declared, symbol.name)) continue;

        try failures.add(
            .exports,
            "{s} is exported, but the {t} artifact does not declare it",
            .{ symbol.name, artifact },
        );
    }

    for (declared) |name| {
        if (exportsName(image.symbols, name)) continue;

        try failures.add(
            .exports,
            "{s} is declared for the {t} artifact, but the file does not " ++
                "export it",
            .{ name, artifact },
        );
    }
}

fn exportsName(symbols: []const Symbol, name: []const u8) bool {
    for (symbols) |symbol| {
        if (symbol.exported() and std.mem.eql(u8, symbol.name, name)) {
            return true;
        }
    }

    return false;
}

fn checkImports(
    failures: *Failures,
    image: Image,
    artifact: allowlist.Artifact,
) Allocator.Error!void {
    for (image.symbols) |symbol| {
        if (symbol.defined) continue;

        if (allowlist.importEntry(artifact, symbol.name) != null) continue;

        try failures.add(
            .imports,
            "{s} is imported, but the allowlist does not name it for the " ++
                "{t} artifact",
            .{ symbol.name, artifact },
        );
    }
}

fn checkNeeded(
    failures: *Failures,
    image: Image,
    artifact: allowlist.Artifact,
) Allocator.Error!void {
    for (image.needed) |name| {
        if (allowlist.needs(artifact, name)) continue;

        try failures.add(
            .needed,
            "{s} is needed, but it is not an allowed library of the {t} " ++
                "artifact",
            .{ name, artifact },
        );
    }

    for (allowlist.libraries) |library| {
        if (!library.serves(artifact)) continue;

        if (contains(image.needed, library.name)) continue;

        try failures.add(
            .needed,
            "{s} is an allowed library of the {t} artifact, but no " ++
                "DT_NEEDED entry names it",
            .{ library.name, artifact },
        );
    }
}

fn checkLoadAlign(failures: *Failures, image: Image) Allocator.Error!void {
    for (image.segments, 0..) |segment, index| {
        if (segment.type != .LOAD or segment.@"align" >= min_load_align) {
            continue;
        }

        try failures.add(
            .load_align,
            "the LOAD segment of program header {d} is aligned to {d} " ++
                "bytes, below {d}",
            .{ index, segment.@"align", min_load_align },
        );
    }
}

fn checkGnuStack(failures: *Failures, image: Image) Allocator.Error!void {
    var present = false;

    for (image.segments, 0..) |segment, index| {
        if (segment.type != elf.PT.GNU_STACK) continue;

        present = true;

        if (!segment.flags.X) continue;

        try failures.add(
            .gnu_stack,
            "the PT_GNU_STACK of program header {d} makes the stack " ++
                "executable",
            .{index},
        );
    }

    if (present) return;

    try failures.add(
        .gnu_stack,
        "the file has no PT_GNU_STACK, which keeps the stack " ++
            "non-executable",
        .{},
    );
}

fn checkTextrel(failures: *Failures, image: Image) Allocator.Error!void {
    if (image.textrel) {
        try failures.add(.textrel, "the dynamic section holds DT_TEXTREL", .{});
    }

    if (image.flags & elf.DF_TEXTREL != 0) {
        try failures.add(.textrel, "DT_FLAGS carries DF_TEXTREL", .{});
    }
}

fn checkSvc(
    failures: *Failures,
    image: Image,
    abi: profile.Abi,
) Allocator.Error!void {
    switch (abi) {
        .@"arm64-v8a" => {},
        // x86_64 instructions have variable length, so a scan of words
        // cannot find syscall; that scan needs an instruction decoder.
        .x86_64 => return,
    }

    for (image.sections) |section| {
        if (section.flags & elf.SHF_EXECINSTR == 0) continue;

        // A64 instructions are little-endian words at addresses that are
        // multiples of 4, whatever the address of the section.
        const skip: usize = @intCast((4 - section.addr % 4) % 4);

        if (skip >= section.contents.len) continue;

        const words = section.contents[skip..];

        var at: usize = 0;

        while (at + 4 <= words.len) : (at += 4) {
            const word = std.mem.readInt(u32, words[at..][0..4], .little);

            if (word & svc_mask != svc_bits) continue;

            // The address wraps instead of failing on a corrupt section
            // address, because it only labels the failure.
            try failures.add(.svc, "svc #0x{x} at 0x{x} in {s}", .{
                (word >> 5) & 0xffff,
                section.addr +% @as(u64, skip + at),
                section.name,
            });
        }
    }
}

const Arguments = struct {
    abi: profile.Abi,
    artifact: allowlist.Artifact,
    path: []const u8,
};

fn parseArguments(args: []const [:0]const u8) ?Arguments {
    if (args.len != 4) return null;

    return .{
        .abi = std.meta.stringToEnum(profile.Abi, args[1]) orelse return null,
        .artifact = std.meta.stringToEnum(allowlist.Artifact, args[2]) orelse
            return null,
        .path = args[3],
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const arguments = parseArguments(args) orelse {
        std.debug.print("usage: inspect <abi> <artifact> <library>\n" ++
            "  <abi>: " ++ profile.abi_names ++ "\n" ++
            "  <artifact>: " ++ artifact_names ++ "\n", .{});

        std.process.exit(2);
    };

    const bytes = Io.Dir.cwd().readFileAlloc(
        io,
        arguments.path,
        arena,
        .limited(max_file_len),
    ) catch |err| {
        std.debug.print("inspect: cannot read {s}: {t}\n", .{
            arguments.path,
            err,
        });

        std.process.exit(2);
    };

    const failures = try inspect(
        arena,
        bytes,
        arguments.abi,
        arguments.artifact,
    );

    for (failures) |failure| {
        std.debug.print("inspect: {t}: {s}\n", .{
            failure.rule,
            failure.detail,
        });
    }

    if (failures.len != 0) {
        std.debug.print("inspect: {s} fails the inspection for {t} {t}\n", .{
            arguments.path,
            arguments.abi,
            arguments.artifact,
        });

        std.process.exit(1);
    }

    const summary = try std.fmt.allocPrint(
        arena,
        "inspect: {s} passes every rule for {t} {t}\n",
        .{ arguments.path, arguments.abi, arguments.artifact },
    );

    try Io.File.stdout().writeStreamingAll(io, summary);
}

const testing = std.testing;

/// A64 instruction words of the tests.
const nop: u32 = 0xd503201f;
const ret: u32 = 0xd65f03c0;
const svc_0: u32 = 0xd4000001;

/// The properties of a synthetic ELF64 shared library. The defaults
/// describe a png_device_test library for arm64-v8a that passes every
/// rule; each test changes one property.
const Synthetic = struct {
    machine: elf.EM = .AARCH64,
    exports: []const Global = &.{.{ .name = "san_png_device_test" }},
    imports: []const Global = &.{ .{ .name = "malloc" }, .{ .name = "free" } },
    needed: []const []const u8 = &.{"libc.so"},
    load_align: u64 = min_load_align,
    /// The flags of PT_GNU_STACK, or null for no PT_GNU_STACK.
    gnu_stack: ?elf.PF = .{ .R = true, .W = true },
    textrel: bool = false,
    /// The value of DT_FLAGS, or 0 for no DT_FLAGS entry.
    dynamic_flags: u64 = 0,
    /// The words of the one executable section.
    code: []const u32 = &.{ nop, ret },

    const Global = struct {
        name: []const u8,
        bind: elf.STB = .GLOBAL,
        visibility: elf.STV = .DEFAULT,
    };

    /// A change of one byte of a built image: the byte at `at` is
    /// replaced by its exclusive or with `mask`.
    const Patch = struct {
        at: usize,
        mask: u8,
    };

    const text_index = 1;
    const dynsym_index = 2;
    const dynstr_index = 3;
    const dynamic_index = 4;
    const shstrtab_index = 5;
    const section_count = 6;

    /// One entry of the dynamic section.
    const Entry = struct {
        tag: i64,
        value: u64,
    };

    /// Returns the image in one little-endian buffer: the ELF header, the
    /// program headers, .text, .dynsym, .dynstr, .dynamic, .shstrtab, and
    /// the section headers. One LOAD segment maps the file from its
    /// start, so every address equals its file offset.
    fn build(synthetic: Synthetic, arena: Allocator) ![]u8 {
        var dynstr: Io.Writer.Allocating = .init(arena);
        var shstrtab: Io.Writer.Allocating = .init(arena);

        try dynstr.writer.writeByte(0);
        try shstrtab.writer.writeByte(0);

        const phnum: u16 = if (synthetic.gnu_stack == null) 2 else 3;

        const text_offset: u64 = @sizeOf(elf.Elf64.Ehdr) +
            @as(u64, phnum) * @sizeOf(elf.Elf64.Phdr);

        var symbols: std.ArrayList(elf.Elf64.Sym) = .empty;

        try symbols.append(arena, .{
            .name = 0,
            .info = .{ .type = .NOTYPE, .bind = .LOCAL },
            .other = .{ .visibility = .DEFAULT },
            .shndx = elf.SHN_UNDEF,
            .value = 0,
            .size = 0,
        });

        for (synthetic.exports) |symbol| {
            try symbols.append(arena, .{
                .name = try intern(&dynstr, symbol.name),
                .info = .{ .type = .FUNC, .bind = symbol.bind },
                .other = .{ .visibility = symbol.visibility },
                .shndx = text_index,
                .value = text_offset,
                .size = 4,
            });
        }

        for (synthetic.imports) |symbol| {
            try symbols.append(arena, .{
                .name = try intern(&dynstr, symbol.name),
                .info = .{ .type = .FUNC, .bind = symbol.bind },
                .other = .{ .visibility = symbol.visibility },
                .shndx = elf.SHN_UNDEF,
                .value = 0,
                .size = 0,
            });
        }

        const needed = try arena.alloc(u32, synthetic.needed.len);

        for (synthetic.needed, needed) |name, *offset| {
            offset.* = try intern(&dynstr, name);
        }

        const names = [section_count]u32{
            0,
            try intern(&shstrtab, ".text"),
            try intern(&shstrtab, ".dynsym"),
            try intern(&shstrtab, ".dynstr"),
            try intern(&shstrtab, ".dynamic"),
            try intern(&shstrtab, ".shstrtab"),
        };

        const text_size: u64 = synthetic.code.len * 4;

        const dynsym_offset = std.mem.alignForward(
            u64,
            text_offset + text_size,
            8,
        );

        const dynstr_size: u64 = dynstr.written().len;

        const dynsym_size: u64 = symbols.items.len * @sizeOf(elf.Elf64.Sym);
        const dynstr_offset = dynsym_offset + dynsym_size;

        const dynamic_offset = std.mem.alignForward(
            u64,
            dynstr_offset + dynstr_size,
            8,
        );

        var entries: std.ArrayList(Entry) = .empty;

        for (needed) |offset| {
            try entries.append(arena, .{
                .tag = elf.DT_NEEDED,
                .value = offset,
            });
        }

        try entries.appendSlice(arena, &.{
            .{ .tag = elf.DT_STRTAB, .value = dynstr_offset },
            .{ .tag = elf.DT_SYMTAB, .value = dynsym_offset },
            .{ .tag = elf.DT_STRSZ, .value = dynstr_size },
            .{ .tag = elf.DT_SYMENT, .value = @sizeOf(elf.Elf64.Sym) },
        });

        if (synthetic.textrel) {
            try entries.append(arena, .{ .tag = elf.DT_TEXTREL, .value = 0 });
        }

        if (synthetic.dynamic_flags != 0) {
            try entries.append(arena, .{
                .tag = elf.DT_FLAGS,
                .value = synthetic.dynamic_flags,
            });
        }

        try entries.append(arena, .{ .tag = elf.DT_NULL, .value = 0 });

        const shstrtab_size: u64 = shstrtab.written().len;

        const dynamic_size: u64 = entries.items.len * @sizeOf(elf.Elf64_Dyn);
        const shstrtab_offset = dynamic_offset + dynamic_size;

        const shoff = std.mem.alignForward(
            u64,
            shstrtab_offset + shstrtab_size,
            8,
        );

        var out: Io.Writer.Allocating = .init(arena);

        const w = &out.writer;

        try w.writeStruct(elf.Elf64.Ehdr{
            .ident = .{
                .class = .@"64",
                .data = .@"2LSB",
                .version = 1,
                .osabi = .NONE,
                .abiversion = 0,
            },
            .type = .DYN,
            .machine = synthetic.machine,
            .version = 1,
            .entry = 0,
            .phoff = @sizeOf(elf.Elf64.Ehdr),
            .shoff = shoff,
            .flags = .{ .int = 0 },
            .ehsize = @sizeOf(elf.Elf64.Ehdr),
            .phentsize = @sizeOf(elf.Elf64.Phdr),
            .phnum = phnum,
            .shentsize = @sizeOf(elf.Elf64.Shdr),
            .shnum = section_count,
            .shstrndx = shstrtab_index,
        }, .little);

        try w.writeStruct(elf.Elf64.Phdr{
            .type = .LOAD,
            .flags = .{ .R = true, .X = true },
            .offset = 0,
            .vaddr = 0,
            .paddr = 0,
            .filesz = shoff,
            .memsz = shoff,
            .@"align" = synthetic.load_align,
        }, .little);

        try w.writeStruct(elf.Elf64.Phdr{
            .type = .DYNAMIC,
            .flags = .{ .R = true, .W = true },
            .offset = dynamic_offset,
            .vaddr = dynamic_offset,
            .paddr = dynamic_offset,
            .filesz = dynamic_size,
            .memsz = dynamic_size,
            .@"align" = 8,
        }, .little);

        if (synthetic.gnu_stack) |flags| {
            try w.writeStruct(elf.Elf64.Phdr{
                .type = elf.PT.GNU_STACK,
                .flags = flags,
                .offset = 0,
                .vaddr = 0,
                .paddr = 0,
                .filesz = 0,
                .memsz = 0,
                .@"align" = 0,
            }, .little);
        }

        try padTo(&out, text_offset);

        for (synthetic.code) |word| try w.writeInt(u32, word, .little);

        try padTo(&out, dynsym_offset);

        for (symbols.items) |symbol| try w.writeStruct(symbol, .little);

        try w.writeAll(dynstr.written());
        try padTo(&out, dynamic_offset);

        for (entries.items) |entry| {
            try w.writeInt(i64, entry.tag, .little);
            try w.writeInt(u64, entry.value, .little);
        }

        try w.writeAll(shstrtab.written());
        try padTo(&out, shoff);

        const headers = [section_count]elf.Elf64.Shdr{
            sectionHeader(0, .NULL, .{}, 0, 0, 0, 0),
            sectionHeader(
                names[text_index],
                .PROGBITS,
                .{ .ALLOC = true, .EXECINSTR = true },
                text_offset,
                text_size,
                0,
                0,
            ),
            sectionHeader(
                names[dynsym_index],
                .DYNSYM,
                .{ .ALLOC = true },
                dynsym_offset,
                dynsym_size,
                dynstr_index,
                @sizeOf(elf.Elf64.Sym),
            ),
            sectionHeader(
                names[dynstr_index],
                .STRTAB,
                .{ .ALLOC = true },
                dynstr_offset,
                dynstr_size,
                0,
                0,
            ),
            sectionHeader(
                names[dynamic_index],
                .DYNAMIC,
                .{ .ALLOC = true, .WRITE = true },
                dynamic_offset,
                dynamic_size,
                dynstr_index,
                @sizeOf(elf.Elf64_Dyn),
            ),
            sectionHeader(
                names[shstrtab_index],
                .STRTAB,
                .{},
                shstrtab_offset,
                shstrtab_size,
                0,
                0,
            ),
        };

        for (headers) |header| try w.writeStruct(header, .little);

        return out.written();
    }

    /// Builds the image and applies `patch` to it.
    fn buildPatched(
        synthetic: Synthetic,
        arena: Allocator,
        patch: ?Patch,
    ) ![]u8 {
        const bytes = try synthetic.build(arena);

        if (patch) |change| bytes[change.at] ^= change.mask;

        return bytes;
    }

    /// Appends `name` to a string table and returns its offset.
    fn intern(table: *Io.Writer.Allocating, name: []const u8) !u32 {
        const offset: u32 = @intCast(table.written().len);

        try table.writer.writeAll(name);
        try table.writer.writeByte(0);

        return offset;
    }

    fn padTo(out: *Io.Writer.Allocating, offset: u64) !void {
        const len = out.written().len;

        std.debug.assert(len <= offset);

        try out.writer.splatByteAll(0, @intCast(offset - len));
    }

    /// Returns a section header whose address equals its offset when the
    /// section is allocated.
    fn sectionHeader(
        name: u32,
        kind: elf.SHT,
        shf: elf.SHF,
        offset: u64,
        size: u64,
        link: u32,
        entsize: u64,
    ) elf.Elf64.Shdr {
        return .{
            .name = name,
            .type = kind,
            .flags = .{ .shf = shf },
            .addr = if (shf.ALLOC) offset else 0,
            .offset = offset,
            .size = size,
            .link = link,
            .info = 0,
            .addralign = if (shf.ALLOC) 8 else 1,
            .entsize = entsize,
        };
    }
};

/// Fails unless the rules of `failures` are exactly `expected`, in order,
/// and prints the failures when they are not.
fn expectRules(expected: []const Rule, failures: []const Failure) !void {
    errdefer for (failures) |failure| {
        std.debug.print("  {t}: {s}\n", .{ failure.rule, failure.detail });
    };

    try testing.expectEqual(expected.len, failures.len);

    for (expected, failures) |rule, failure| {
        try testing.expectEqual(rule, failure.rule);
    }
}

fn mentions(text: []const u8, part: []const u8) bool {
    return std.mem.find(u8, text, part) != null;
}

test "a library with every property right passes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const arm64 = try Synthetic.build(.{}, arena);

    try expectRules(&.{}, try inspect(
        arena,
        arm64,
        .@"arm64-v8a",
        .png_device_test,
    ));

    const x86_64 = try Synthetic.build(.{ .machine = .X86_64 }, arena);

    try expectRules(&.{}, try inspect(
        arena,
        x86_64,
        .x86_64,
        .png_device_test,
    ));

    const san = try Synthetic.build(.{
        .exports = &.{.{ .name = "JNI_OnLoad" }},
        .imports = &.{
            .{ .name = "malloc" },
            .{ .name = "AndroidBitmap_getInfo" },
            .{ .name = "AndroidBitmap_getDataSpace" },
            .{ .name = "AndroidBitmap_lockPixels" },
            .{ .name = "AndroidBitmap_unlockPixels" },
        },
        .needed = &.{ "libc.so", "libjnigraphics.so" },
    }, arena);

    try expectRules(&.{}, try inspect(arena, san, .@"arm64-v8a", .san));
}

test "each defect fails its own rule and no other" {
    const Case = struct {
        name: []const u8,
        synthetic: Synthetic = .{},
        patch: ?Synthetic.Patch = null,
        rule: Rule,
    };

    const cases = [_]Case{
        .{
            .name = "an extra export",
            .synthetic = .{ .exports = &.{
                .{ .name = "san_png_device_test" },
                .{ .name = "san_extra" },
            } },
            .rule = .exports,
        },
        .{
            .name = "a foreign import",
            .synthetic = .{ .imports = &.{
                .{ .name = "malloc" },
                .{ .name = "getenv" },
            } },
            .rule = .imports,
        },
        .{
            .name = "DT_NEEDED libm.so",
            .synthetic = .{ .needed = &.{ "libc.so", "libm.so" } },
            .rule = .needed,
        },
        .{
            .name = "p_align 4096",
            .synthetic = .{ .load_align = 4096 },
            .rule = .load_align,
        },
        .{
            .name = "a missing PT_GNU_STACK",
            .synthetic = .{ .gnu_stack = null },
            .rule = .gnu_stack,
        },
        .{
            .name = "PF_X on PT_GNU_STACK",
            .synthetic = .{ .gnu_stack = .{ .R = true, .W = true, .X = true } },
            .rule = .gnu_stack,
        },
        .{
            .name = "DT_TEXTREL",
            .synthetic = .{ .textrel = true },
            .rule = .textrel,
        },
        .{
            .name = "DF_TEXTREL",
            .synthetic = .{ .dynamic_flags = elf.DF_TEXTREL },
            .rule = .textrel,
        },
        .{
            .name = "an svc word",
            .synthetic = .{ .code = &.{ nop, svc_0, ret } },
            .rule = .svc,
        },
        .{
            .name = "the wrong machine",
            .synthetic = .{ .machine = .X86_64 },
            .rule = .machine,
        },
        .{
            .name = "the 32-bit class",
            .patch = .{ .at = elf.EI.CLASS, .mask = 0x03 },
            .rule = .class,
        },
        .{
            .name = "the big-endian data encoding",
            .patch = .{ .at = elf.EI.DATA, .mask = 0x03 },
            .rule = .class,
        },
    };

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        const bytes = try case.synthetic.buildPatched(arena, case.patch);

        const failures = try inspect(
            arena,
            bytes,
            .@"arm64-v8a",
            .png_device_test,
        );

        try expectRules(&.{case.rule}, failures);
    }
}

test "the defect details name what failed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const bytes = try Synthetic.build(.{
        .exports = &.{
            .{ .name = "san_png_device_test" },
            .{ .name = "san_extra" },
        },
        .imports = &.{ .{ .name = "malloc" }, .{ .name = "getenv" } },
        .needed = &.{ "libc.so", "libm.so" },
        .load_align = 4096,
    }, arena);

    const failures = try inspect(
        arena,
        bytes,
        .@"arm64-v8a",
        .png_device_test,
    );

    try expectRules(&.{ .exports, .imports, .needed, .load_align }, failures);
    try testing.expect(mentions(failures[0].detail, "san_extra"));
    try testing.expect(mentions(failures[1].detail, "getenv"));
    try testing.expect(mentions(failures[2].detail, "libm.so"));
    try testing.expect(mentions(failures[3].detail, "4096"));
}

test "a missing declared export or a missing libc.so fails" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const unexported = try Synthetic.build(.{ .exports = &.{} }, arena);

    try expectRules(&.{.exports}, try inspect(
        arena,
        unexported,
        .@"arm64-v8a",
        .png_device_test,
    ));

    const unneeded = try Synthetic.build(.{ .needed = &.{} }, arena);

    try expectRules(&.{.needed}, try inspect(
        arena,
        unneeded,
        .@"arm64-v8a",
        .png_device_test,
    ));

    // The San library declares another export and needs a second library.
    const png = try Synthetic.build(.{}, arena);

    try expectRules(&.{ .exports, .exports, .needed }, try inspect(
        arena,
        png,
        .@"arm64-v8a",
        .san,
    ));
}

test "only the San library may need the Android bitmap library" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const copy: Synthetic.Global = .{ .name = "AndroidBitmap_lockPixels" };
    const both = [_][]const u8{ "libc.so", "libjnigraphics.so" };

    // A test library with the San library's DT_NEEDED entries.
    const needing = try Synthetic.build(.{ .needed = &both }, arena);

    const needed = try inspect(
        arena,
        needing,
        .@"arm64-v8a",
        .png_device_test,
    );

    try expectRules(&.{.needed}, needed);
    try testing.expect(mentions(needed[0].detail, "libjnigraphics.so"));

    // A test library with an import of the copy operation. A real link
    // of it also needs the library; the rules are judged apart here.
    const importing = try Synthetic.build(.{
        .imports = &.{ .{ .name = "malloc" }, copy },
    }, arena);

    const imported = try inspect(
        arena,
        importing,
        .@"arm64-v8a",
        .png_device_test,
    );

    try expectRules(&.{.imports}, imported);
    try testing.expect(mentions(imported[0].detail, copy.name));

    // The San library without the Android bitmap library, whose import
    // then has no provider.
    const unprovided = try Synthetic.build(.{
        .exports = &.{.{ .name = "JNI_OnLoad" }},
        .imports = &.{ .{ .name = "malloc" }, copy },
    }, arena);

    const missing = try inspect(arena, unprovided, .@"arm64-v8a", .san);

    try expectRules(&.{.needed}, missing);
    try testing.expect(mentions(missing[0].detail, "libjnigraphics.so"));

    // No artifact may take another function of the Android bitmap
    // library.
    const compressing = try Synthetic.build(.{
        .exports = &.{.{ .name = "JNI_OnLoad" }},
        .imports = &.{.{ .name = "AndroidBitmap_compress" }},
        .needed = &both,
    }, arena);

    try expectRules(&.{.imports}, try inspect(
        arena,
        compressing,
        .@"arm64-v8a",
        .san,
    ));
}

test "weak symbols and every visibility are exports, and weak imports count" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const extras = [_]Synthetic.Global{
        .{ .name = "san_weak", .bind = .WEAK },
        .{ .name = "san_protected", .visibility = .PROTECTED },
        .{ .name = "san_hidden", .visibility = .HIDDEN },
        .{ .name = "san_internal", .visibility = .INTERNAL },
    };

    for (extras) |extra| {
        const bytes = try Synthetic.build(.{ .exports = &.{
            .{ .name = "san_png_device_test" },
            extra,
        } }, arena);

        try expectRules(&.{.exports}, try inspect(
            arena,
            bytes,
            .@"arm64-v8a",
            .png_device_test,
        ));
    }

    const weak_import = try Synthetic.build(.{ .imports = &.{
        .{ .name = "malloc" },
        .{ .name = "dlopen", .bind = .WEAK },
    } }, arena);

    try expectRules(&.{.imports}, try inspect(
        arena,
        weak_import,
        .@"arm64-v8a",
        .png_device_test,
    ));
}

test "the svc scan matches the svc encoding and nothing near it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    // svc #0, svc #0x80, and svc #0xffff.
    const svc_words = [_]u32{ svc_0, 0xd4001001, 0xd41fffe1 };

    // hvc #0, smc #0, brk #0, hlt #0, udf #0, nop, and ret.
    const other_words = [_]u32{
        0xd4000002,
        0xd4000003,
        0xd4200000,
        0xd4400000,
        0x00000000,
        nop,
        ret,
    };

    const bytes = try Synthetic.build(.{
        .code = &(svc_words ++ other_words),
    }, arena);

    const failures = try inspect(
        arena,
        bytes,
        .@"arm64-v8a",
        .png_device_test,
    );

    try expectRules(&.{ .svc, .svc, .svc }, failures);
    try testing.expect(mentions(failures[0].detail, "svc #0x0 "));
    try testing.expect(mentions(failures[1].detail, "svc #0x80 "));
    try testing.expect(mentions(failures[2].detail, "svc #0xffff "));
    try testing.expect(mentions(failures[2].detail, "in .text"));
}

test "x86_64 libraries skip the svc scan" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const bytes = try Synthetic.build(.{
        .machine = .X86_64,
        .code = &.{svc_0},
    }, arena);

    try expectRules(&.{}, try inspect(
        arena,
        bytes,
        .x86_64,
        .png_device_test,
    ));

    try expectRules(&.{ .machine, .svc }, try inspect(
        arena,
        bytes,
        .@"arm64-v8a",
        .png_device_test,
    ));
}

test "a dynamic segment that differs from the dynamic section fails" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    // The low byte of p_offset of the second program header, PT_DYNAMIC.
    const offset_at = @sizeOf(elf.Elf64.Ehdr) + @sizeOf(elf.Elf64.Phdr) +
        @offsetOf(elf.Elf64.Phdr, "offset");

    const bytes = try Synthetic.buildPatched(.{}, arena, .{
        .at = offset_at,
        .mask = 0x08,
    });

    const failures = try inspect(
        arena,
        bytes,
        .@"arm64-v8a",
        .png_device_test,
    );

    try expectRules(&.{.format}, failures);
    try testing.expect(mentions(failures[0].detail, "dynamic segment"));
}

test "a file that is not an ELF library fails the format rule" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const inputs = [_][]const u8{ "", "\x7fELF", "#!/bin/sh\nexit 0\n" };

    for (inputs) |bytes| {
        try expectRules(&.{.format}, try inspect(
            arena,
            bytes,
            .@"arm64-v8a",
            .png_device_test,
        ));
    }
}

test "every truncation of a library fails the format rule" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const bytes = try Synthetic.build(.{}, arena_state.allocator());

    for (0..bytes.len) |len| {
        var run_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer run_state.deinit();

        errdefer std.debug.print("length: {d}\n", .{len});

        try expectRules(&.{.format}, try inspect(
            run_state.allocator(),
            bytes[0..len],
            .@"arm64-v8a",
            .png_device_test,
        ));
    }
}

test "a corrupt byte anywhere ends in a result, never in a crash" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const bytes = try Synthetic.build(.{}, arena_state.allocator());

    const masks = [_]u8{ 0x01, 0x80, 0xff };

    for (0..bytes.len) |at| {
        for (masks) |mask| {
            var run_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer run_state.deinit();

            bytes[at] ^= mask;
            defer bytes[at] ^= mask;

            _ = try inspect(
                run_state.allocator(),
                bytes,
                .@"arm64-v8a",
                .png_device_test,
            );
        }
    }
}

test "the arguments name an abi, an artifact, and a file" {
    const valid = parseArguments(&.{
        "inspect",
        "arm64-v8a",
        "png_device_test",
        "libsan.so",
    }).?;

    try testing.expectEqual(profile.Abi.@"arm64-v8a", valid.abi);
    try testing.expectEqual(.png_device_test, valid.artifact);
    try testing.expectEqualStrings("libsan.so", valid.path);

    const invalid = [_][]const [:0]const u8{
        &.{ "inspect", "arm64-v8a", "png_device_test" },
        &.{ "inspect", "armeabi-v7a", "san", "libsan.so" },
        &.{ "inspect", "x86_64", "png-device-test", "libsan.so" },
        &.{ "inspect", "x86_64", "san", "libsan.so", "extra" },
    };

    for (invalid) |args| {
        try testing.expectEqual(null, parseArguments(args));
    }

    try testing.expectEqualStrings(
        "san, png_device_test, abi_device_test, canary_device_test",
        artifact_names,
    );
}
