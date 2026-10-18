//! The parser of abi.tsv, the cross-check table of the Bindings, under
//! the section "Table format" of the Bindings readme. The same code runs
//! at compile time in the Android header checks and at run time in the
//! host tests.
//!
//! A parsed table satisfies every rule that the table alone can show:
//! printable ASCII, tabs, and LF with a final newline; the exact header
//! line; four nonempty fields per row; the seven kinds; the name and the
//! value of each kind, with canonical decimals in range; the ABI column;
//! and the uniqueness and pairing of rows. Completeness against the
//! header belongs to the checks that read both. `macroValue` reads the
//! form that the Table format gives an i32 or i64 macro in the header.

const std = @import("std");

/// The first line of every table.
pub const header_line = "kind\tname\tabi\tvalue";

/// The kind of a row. It selects the form of the name and the value.
pub const Kind = enum { i32, i64, type, size, @"align", offset, jni };

/// The abi column. `any` is the `*` of a row that holds on every ABI.
pub const Abi = enum {
    any,
    @"arm64-v8a",
    x86_64,

    fn parse(text: []const u8) ?Abi {
        if (std.mem.eql(u8, text, "*")) return .any;
        if (std.mem.eql(u8, text, "arm64-v8a")) return .@"arm64-v8a";
        if (std.mem.eql(u8, text, "x86_64")) return .x86_64;

        return null;
    }
};

/// A fixed-width integer type, the value of a type row.
pub const FixedWidth = enum {
    int8_t,
    int16_t,
    int32_t,
    int64_t,
    uint8_t,
    uint16_t,
    uint32_t,
    uint64_t,

    /// Returns the Zig integer type of the C type.
    pub fn Type(comptime fixed_width: FixedWidth) type {
        return switch (fixed_width) {
            .int8_t => i8,
            .int16_t => i16,
            .int32_t => i32,
            .int64_t => i64,
            .uint8_t => u8,
            .uint16_t => u16,
            .uint32_t => u32,
            .uint64_t => u64,
        };
    }
};

/// The parsed cell of the value column. The kind selects the variant:
/// `integer` for i32, i64, size, align, and offset; `fixed_width` for
/// type; `descriptor` for jni.
pub const Cell = union(enum) {
    integer: i64,
    fixed_width: FixedWidth,
    descriptor: []const u8,
};

/// One row of a parsed table.
pub const Row = struct {
    /// The line of the row; the header line is line 1.
    line: usize,
    kind: Kind,
    name: []const u8,
    abi: Abi,
    value: Cell,

    /// Reports whether the row holds on `abi`, which names one ABI.
    pub fn holdsOn(row: Row, abi: Abi) bool {
        std.debug.assert(abi != .any);

        return row.abi == .any or row.abi == abi;
    }

    /// Splits the name of a row that names a field, written
    /// `struct.field`, or returns null.
    pub fn field(row: Row) ?struct { []const u8, []const u8 } {
        const dot = std.mem.findScalar(u8, row.name, '.') orelse return null;

        return .{ row.name[0..dot], row.name[dot + 1 ..] };
    }
};

pub const Error = error{
    /// A byte is outside printable ASCII, tab, and LF.
    ForbiddenByte,
    /// The file is empty or does not end with a newline.
    MissingFinalNewline,
    /// The first line is not the header line.
    HeaderLine,
    BlankLine,
    /// A row has more or fewer than four fields.
    FieldCount,
    EmptyField,
    UnknownKind,
    /// The abi column is not `*`, `arm64-v8a`, or `x86_64`.
    UnknownAbi,
    /// An i32, i64, or jni row names an ABI instead of `*`.
    AbiNotAny,
    /// The name does not have the form of its kind.
    BadName,
    /// An integer is not a canonical decimal: `0|-?[1-9][0-9]*`.
    NotCanonical,
    /// An integer is outside the range of its kind.
    OutOfRange,
    /// A size, alignment, or offset is negative.
    Negative,
    /// The value of a type row is not a fixed-width type.
    UnknownType,
    /// The value of a jni row is not a JNI method descriptor.
    BadDescriptor,
    /// A kind, name, and abi combination appears twice.
    Duplicate,
    /// A per-ABI row and a `*` row share a kind and a name.
    MixedAbi,
    /// A per-ABI row has no row for the other ABI.
    UnpairedAbi,
};

/// Where a parse failed.
pub const Diagnostic = struct {
    line: usize = 0,
    /// The earlier line of a Duplicate or MixedAbi failure.
    other_line: usize = 0,
    /// The byte of a ForbiddenByte failure.
    byte: u8 = 0,
};

/// A failed parse, formatted as `abi.tsv:<line>: <reason>`.
pub const Failure = struct {
    err: Error,
    diagnostic: Diagnostic,

    pub fn format(
        failure: Failure,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("abi.tsv:{d}: {s}", .{
            failure.diagnostic.line,
            describe(failure.err),
        });

        switch (failure.err) {
            error.ForbiddenByte => try writer.print(
                " (0x{x:0>2})",
                .{failure.diagnostic.byte},
            ),
            error.Duplicate, error.MixedAbi => try writer.print(
                " (line {d})",
                .{failure.diagnostic.other_line},
            ),
            else => {},
        }
    }
};

/// Returns the reason of a failure.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.ForbiddenByte => "a byte outside printable ASCII, tab, and LF",
        error.MissingFinalNewline => "the file does not end with a newline",
        error.HeaderLine => "the first line is not kind, name, abi, and " ++
            "value, separated by tabs",
        error.BlankLine => "a blank line",
        error.FieldCount => "a row without exactly four fields",
        error.EmptyField => "an empty field",
        error.UnknownKind => "an unknown kind",
        error.UnknownAbi => "an abi other than *, arm64-v8a, and x86_64",
        error.AbiNotAny => "an i32, i64, or jni row that names an ABI",
        error.BadName => "a name without the form of its kind",
        error.NotCanonical => "an integer that is not a canonical decimal",
        error.OutOfRange => "an integer outside the range of its kind",
        error.Negative => "a negative size, alignment, or offset",
        error.UnknownType => "a type that is not a fixed-width integer type",
        error.BadDescriptor => "a value that is not a JNI method descriptor",
        error.Duplicate => "a kind, name, and abi that an earlier row has",
        error.MixedAbi => "a per-ABI row together with a * row",
        error.UnpairedAbi => "a per-ABI row without a row for the other ABI",
    };
}

/// Returns the number of rows of `text`: its lines without the header
/// line.
pub fn rowCount(text: []const u8) usize {
    return std.mem.countScalar(u8, text, '\n') -| 1;
}

/// Parses `text` into `rows`, which holds exactly rowCount(text) rows,
/// and returns them. On failure, `diagnostic` locates the error.
pub fn parse(
    text: []const u8,
    rows: []Row,
    diagnostic: *Diagnostic,
) Error![]Row {
    @setEvalBranchQuota(200_000);
    std.debug.assert(rows.len == rowCount(text));
    diagnostic.* = .{};

    try checkBytes(text, diagnostic);

    var lines = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');

    diagnostic.line = 1;
    if (!std.mem.eql(u8, lines.first(), header_line)) return error.HeaderLine;

    for (rows, 2..) |*row, line| {
        diagnostic.line = line;
        row.* = try parseRow(lines.next().?, line);
    }

    try checkRows(rows, diagnostic);

    return rows;
}

fn checkBytes(text: []const u8, diagnostic: *Diagnostic) Error!void {
    var line: usize = 1;

    for (text) |byte| switch (byte) {
        '\n' => line += 1,
        '\t', ' '...'~' => {},
        else => {
            diagnostic.line = line;
            diagnostic.byte = byte;

            return error.ForbiddenByte;
        },
    };

    if (text.len == 0 or text[text.len - 1] != '\n') {
        diagnostic.line = line;

        return error.MissingFinalNewline;
    }
}

fn parseRow(text: []const u8, line: usize) Error!Row {
    if (text.len == 0) return error.BlankLine;

    var fields: [4][]const u8 = undefined;

    var parts = std.mem.splitScalar(u8, text, '\t');

    for (&fields) |*item| {
        item.* = parts.next() orelse return error.FieldCount;

        if (item.len == 0) return error.EmptyField;
    }

    if (parts.next() != null) return error.FieldCount;

    const kind = std.meta.stringToEnum(Kind, fields[0]) orelse
        return error.UnknownKind;

    const abi = Abi.parse(fields[2]) orelse return error.UnknownAbi;

    switch (kind) {
        .i32, .i64, .jni => if (abi != .any) return error.AbiNotAny,
        .type, .size, .@"align", .offset => {},
    }

    if (!nameFits(kind, fields[1])) return error.BadName;

    return .{
        .line = line,
        .kind = kind,
        .name = fields[1],
        .abi = abi,
        .value = try parseValue(kind, fields[3]),
    };
}

fn nameFits(kind: Kind, name: []const u8) bool {
    return switch (kind) {
        .i32, .i64 => std.mem.startsWith(u8, name, "SAN_") and
            isIdentifier(name),
        .type => isIdentifier(name) or isField(name),
        .size, .@"align" => isIdentifier(name),
        .offset => isField(name),
        .jni => isMethodName(name),
    };
}

fn parseValue(kind: Kind, text: []const u8) Error!Cell {
    switch (kind) {
        .i32 => {
            const value = try decimal(text);

            if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
                return error.OutOfRange;
            }

            return .{ .integer = value };
        },
        .i64 => return .{ .integer = try decimal(text) },
        .size, .@"align", .offset => {
            const value = try decimal(text);

            if (value < 0) return error.Negative;

            return .{ .integer = value };
        },
        .type => {
            const fixed_width = std.meta.stringToEnum(FixedWidth, text) orelse
                return error.UnknownType;

            return .{ .fixed_width = fixed_width };
        },
        .jni => {
            if (!isMethodDescriptor(text)) return error.BadDescriptor;

            return .{ .descriptor = text };
        },
    }
}

/// Parses a canonical decimal, `0|-?[1-9][0-9]*`, in the i64 range.
fn decimal(text: []const u8) Error!i64 {
    const negative = text[0] == '-';
    const digits = if (negative) text[1..] else text;

    if (digits.len == 0) return error.NotCanonical;

    for (digits) |digit| {
        if (!std.ascii.isDigit(digit)) return error.NotCanonical;
    }

    if (digits[0] == '0' and (digits.len > 1 or negative)) {
        return error.NotCanonical;
    }

    return std.fmt.parseInt(i64, text, 10) catch |err| switch (err) {
        error.Overflow => error.OutOfRange,
        error.InvalidCharacter => unreachable,
    };
}

/// Returns the value of the body of a header macro, or null when the body
/// does not have the form of an i32 or i64 macro: a decimal integer
/// constant `N`, or `( -N )` for a negative value, with N a canonical
/// decimal of the i64 range.
pub fn macroValue(body: []const u8) ?i64 {
    const open = "( -";
    const close = " )";

    const negative = body.len > open.len + close.len and
        std.mem.startsWith(u8, body, open) and
        std.mem.endsWith(u8, body, close);

    if (!negative) return unsignedDecimal(body);

    const inner = body[open.len .. body.len - close.len];

    const magnitude = unsignedDecimal(inner) orelse return null;

    if (magnitude == 0) return null;

    return -magnitude;
}

/// Returns the name that the table gives the type `T`, the declaration
/// `name` of the translated module `Translation`. A translated
/// `struct_<typedef>` takes the name of its typedef when the translation
/// declares that typedef as the same type, so a struct and its typedef
/// share one set of rows.
pub fn typeName(
    comptime Translation: type,
    comptime name: []const u8,
    comptime T: type,
) []const u8 {
    const prefix = "struct_";

    if (comptime !std.mem.startsWith(u8, name, prefix)) return name;

    const typedef = name[prefix.len..];

    if (!@hasDecl(Translation, typedef)) return name;
    if (@TypeOf(@field(Translation, typedef)) != type) return name;
    if (@field(Translation, typedef) != T) return name;

    return typedef;
}

/// Parses a canonical decimal without a sign, `0|[1-9][0-9]*`, in the i64
/// range, or returns null.
fn unsignedDecimal(text: []const u8) ?i64 {
    if (text.len == 0 or text[0] == '-') return null;

    return decimal(text) catch null;
}

fn checkRows(rows: []const Row, diagnostic: *Diagnostic) Error!void {
    for (rows, 0..) |row, index| {
        diagnostic.line = row.line;

        for (rows[0..index]) |earlier| {
            if (earlier.kind != row.kind) continue;
            if (!std.mem.eql(u8, earlier.name, row.name)) continue;

            diagnostic.other_line = earlier.line;
            if (earlier.abi == row.abi) return error.Duplicate;
            if (earlier.abi == .any or row.abi == .any) return error.MixedAbi;
        }

        if (row.abi != .any and !hasPeer(rows, row)) {
            return error.UnpairedAbi;
        }
    }
}

/// Reports whether `rows` holds the row of `row` for the other ABI.
fn hasPeer(rows: []const Row, row: Row) bool {
    for (rows) |peer| {
        if (peer.kind != row.kind) continue;
        if (!std.mem.eql(u8, peer.name, row.name)) continue;
        if (peer.abi != .any and peer.abi != row.abi) return true;
    }

    return false;
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or std.ascii.isDigit(text[0])) return false;

    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }

    return true;
}

fn isField(text: []const u8) bool {
    const dot = std.mem.findScalar(u8, text, '.') orelse return false;

    return isIdentifier(text[0..dot]) and isIdentifier(text[dot + 1 ..]);
}

fn isJavaIdentifier(text: []const u8) bool {
    if (text.len == 0 or std.ascii.isDigit(text[0])) return false;

    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '$') {
            return false;
        }
    }

    return true;
}

/// Reports whether `text` is a binary class name such as
/// `app/hakusan/reader/san/SanAbi`.
fn isClassName(text: []const u8) bool {
    var segments = std.mem.splitScalar(u8, text, '/');

    while (segments.next()) |segment| {
        if (!isJavaIdentifier(segment)) return false;
    }

    return true;
}

/// Reports whether `text` is a JNI method written
/// `binary/class/Name.method`.
fn isMethodName(text: []const u8) bool {
    const dot = std.mem.findScalarLast(u8, text, '.') orelse return false;

    return isClassName(text[0..dot]) and isJavaIdentifier(text[dot + 1 ..]);
}

/// Reports whether `text` is a JNI method descriptor such as `(J[J)I`.
fn isMethodDescriptor(text: []const u8) bool {
    if (text[0] != '(') return false;

    var index: usize = 1;

    while (index < text.len and text[index] != ')') {
        index = fieldTypeEnd(text, index) orelse return false;
    }

    if (index == text.len) return false;

    const result = index + 1;

    if (result < text.len and text[result] == 'V') {
        return result + 1 == text.len;
    }

    return fieldTypeEnd(text, result) == text.len;
}

/// Returns the end of the JNI field type that starts at `start`, or
/// null when none starts there.
fn fieldTypeEnd(text: []const u8, start: usize) ?usize {
    var index = start;
    while (index < text.len and text[index] == '[') index += 1;

    if (index == text.len) return null;

    switch (text[index]) {
        'B', 'C', 'D', 'F', 'I', 'J', 'S', 'Z' => return index + 1,
        'L' => {
            const end = std.mem.findScalarPos(u8, text, index + 1, ';') orelse
                return null;

            if (!isClassName(text[index + 1 .. end])) return null;

            return end + 1;
        },
        else => return null,
    }
}

const testing = std.testing;

const valid =
    "kind\tname\tabi\tvalue\n" ++
    "i32\tSAN_ABI_VERSION\t*\t0\n" ++
    "i32\tSAN_STATUS_CANCELED\t*\t-7\n" ++
    "i64\tSAN_NO_HANDLE\t*\t0\n" ++
    "type\tsan_status\t*\tint32_t\n" ++
    "type\tsan_engine_limits.aggregate_budget_bytes\t*\tint64_t\n" ++
    "size\tsan_engine_limits\t*\t8\n" ++
    "align\tsan_engine_limits\tarm64-v8a\t8\n" ++
    "align\tsan_engine_limits\tx86_64\t8\n" ++
    "offset\tsan_engine_limits.aggregate_budget_bytes\t*\t0\n" ++
    "jni\tapp/hakusan/reader/san/SanAbi.engineCreate\t*\t(J[J)I\n";

/// A table that fails to parse: the error, the line, and the text.
const Case = struct { Error, usize, []const u8 };

/// Returns `valid` with the row at `line` replaced by `row`, or with a
/// row added when `line` is past the end.
fn withRow(comptime line: usize, comptime row: []const u8) []const u8 {
    return comptime replaced: {
        var lines = std.mem.splitScalar(u8, valid, '\n');

        var text: []const u8 = "";
        var number: usize = 1;

        while (lines.next()) |current| : (number += 1) {
            if (current.len == 0) break;
            text = text ++ (if (number == line) row else current) ++ "\n";
        }

        if (line >= number) text = text ++ row ++ "\n";

        break :replaced text;
    };
}

/// Returns a table of the header line and one row.
fn oneRow(comptime row: []const u8) []const u8 {
    return header_line ++ "\n" ++ row ++ "\n";
}

fn parseText(
    text: []const u8,
    diagnostic: *Diagnostic,
) (Error || std.mem.Allocator.Error)![]Row {
    const rows = try testing.allocator.alloc(Row, rowCount(text));
    errdefer testing.allocator.free(rows);

    return parse(text, rows, diagnostic);
}

fn expectFailures(cases: []const Case) !void {
    for (cases) |case| {
        const expected, const line, const text = case;
        var diagnostic: Diagnostic = .{};

        const result = parseText(text, &diagnostic);

        if (result) |rows| {
            testing.allocator.free(rows);
            std.debug.print("unexpected success: {s}\n", .{text});

            return error.TestUnexpectedSuccess;
        } else |err| {
            try testing.expectEqual(expected, err);
            try testing.expectEqual(line, diagnostic.line);
        }
    }
}

test "a valid table parses into typed rows" {
    var diagnostic: Diagnostic = .{};

    const rows = try parseText(valid, &diagnostic);
    defer testing.allocator.free(rows);

    try testing.expectEqual(10, rows.len);
    try testing.expectEqual(Kind.i32, rows[1].kind);
    try testing.expectEqual(-7, rows[1].value.integer);
    try testing.expectEqual(FixedWidth.int64_t, rows[4].value.fixed_width);
    try testing.expectEqual(Abi.@"arm64-v8a", rows[6].abi);
    try testing.expectEqual(9, rows[7].line);
    try testing.expectEqualStrings("(J[J)I", rows[9].value.descriptor);
    try testing.expect(rows[6].holdsOn(.@"arm64-v8a"));
    try testing.expect(!rows[6].holdsOn(.x86_64));
    try testing.expect(rows[5].holdsOn(.x86_64));
}

test "the bytes are printable ASCII, tabs, and LF with a final newline" {
    try expectFailures(&.{
        .{ error.ForbiddenByte, 3, withRow(3, "i32\tSAN_A\x01\t*\t1") },
        .{ error.ForbiddenByte, 2, withRow(2, "i32\tSAN_A\t*\t1\r") },
        .{ error.ForbiddenByte, 2, withRow(2, "i32\tSAN_\xc3\xa9\t*\t1") },
        .{ error.ForbiddenByte, 4, withRow(4, "i64\tSAN_A\t*\t1\x7f") },
        .{ error.MissingFinalNewline, 11, valid[0 .. valid.len - 1] },
        .{ error.MissingFinalNewline, 1, "" },
    });
}

test "the header line is exact" {
    try expectFailures(&.{
        .{ error.HeaderLine, 1, "kind\tname\tabi\n" },
        .{ error.HeaderLine, 1, "kind\tname\tabi\tvalue\t\n" },
        .{ error.HeaderLine, 1, "kind name abi value\n" },
    });
}

test "each row has four nonempty fields and no blank line" {
    try expectFailures(&.{
        .{ error.BlankLine, 3, withRow(3, "") },
        .{ error.FieldCount, 2, withRow(2, "i32\tSAN_A\t*") },
        .{ error.FieldCount, 2, withRow(2, "i32\tSAN_A\t*\t1\t2") },
        .{ error.EmptyField, 2, withRow(2, "i32\t\t*\t1") },
        .{ error.EmptyField, 2, withRow(2, "i32\tSAN_A\t*\t") },
    });
}

test "kinds and the abi column are closed sets" {
    try expectFailures(&.{
        .{ error.UnknownKind, 2, withRow(2, "u32\tSAN_A\t*\t1") },
        .{ error.UnknownKind, 2, withRow(2, "#i32\tSAN_A\t*\t1") },
        .{ error.UnknownAbi, 7, withRow(7, "size\tsan_x\tany\t8") },
        .{ error.UnknownAbi, 7, withRow(7, "size\tsan_x\tarm64\t8") },
        .{ error.AbiNotAny, 2, withRow(2, "i32\tSAN_A\tx86_64\t1") },
        .{ error.AbiNotAny, 11, withRow(11, "jni\ta/B.c\tx86_64\t()V") },
    });
}

test "names have the form of their kind" {
    try expectFailures(&.{
        .{ error.BadName, 2, withRow(2, "i32\tOTHER_A\t*\t1") },
        .{ error.BadName, 2, withRow(2, "i32\tSAN_\"A\"\t*\t1") },
        .{ error.BadName, 7, withRow(7, "size\tsan_x.y\t*\t8") },
        .{ error.BadName, 10, withRow(10, "offset\tsan_x\t*\t0") },
        .{ error.BadName, 5, withRow(5, "type\t1san\t*\tint32_t") },
        .{ error.BadName, 11, withRow(11, "jni\tSanAbi\t*\t()V") },
        .{ error.BadName, 11, withRow(11, "jni\ta//B.c\t*\t()V") },
    });
}

test "integers are canonical decimals in range" {
    try expectFailures(&.{
        .{ error.NotCanonical, 2, oneRow("i32\tSAN_X\t*\t+1") },
        .{ error.NotCanonical, 2, oneRow("i32\tSAN_X\t*\t01") },
        .{ error.NotCanonical, 2, oneRow("i32\tSAN_X\t*\t-0") },
        .{ error.NotCanonical, 2, oneRow("i32\tSAN_X\t*\t-") },
        .{ error.NotCanonical, 2, oneRow("i32\tSAN_X\t*\t1_000") },
        .{ error.NotCanonical, 2, oneRow("i32\tSAN_X\t*\t0x10") },
        .{ error.OutOfRange, 2, oneRow("i32\tSAN_X\t*\t2147483648") },
        .{ error.OutOfRange, 2, oneRow("i32\tSAN_X\t*\t-2147483649") },
        .{ error.OutOfRange, 2, oneRow("i64\tSAN_X\t*\t9223372036854775808") },
        .{ error.Negative, 2, oneRow("size\tsan_x\t*\t-8") },
    });
}

test "the extreme decimals of each range parse" {
    const text = header_line ++ "\n" ++
        "i32\tSAN_A\t*\t-2147483648\n" ++
        "i32\tSAN_B\t*\t2147483647\n" ++
        "i64\tSAN_C\t*\t-9223372036854775808\n" ++
        "i64\tSAN_D\t*\t9223372036854775807\n";

    var diagnostic: Diagnostic = .{};

    const rows = try parseText(text, &diagnostic);
    defer testing.allocator.free(rows);

    try testing.expectEqual(std.math.minInt(i32), rows[0].value.integer);
    try testing.expectEqual(std.math.maxInt(i64), rows[3].value.integer);
}

test "a header macro is a decimal N or ( -N )" {
    const accepted = [_]struct { []const u8, i64 }{
        .{ "0", 0 },
        .{ "1", 1 },
        .{ "( -1 )", -1 },
        .{ "( -12 )", -12 },
        .{ "9223372036854775807", std.math.maxInt(i64) },
        .{ "( -9223372036854775807 )", -std.math.maxInt(i64) },
    };

    const rejected = [_][]const u8{
        "",
        "0x1",
        "01",
        "+1",
        "-1",
        "1u",
        "1L",
        "(1)",
        "(-1)",
        "( - 1 )",
        "( -0 )",
        "( -01 )",
        "( - )",
        "( -1)",
        "(  -1 )",
        "9223372036854775808",
        "1 /* one */",
    };

    for (accepted) |case| {
        const body, const value = case;

        try testing.expectEqual(value, macroValue(body).?);
    }

    for (rejected) |body| {
        if (macroValue(body)) |value| {
            std.debug.print("accepted '{s}' as {d}\n", .{ body, value });

            return error.TestUnexpectedResult;
        }
    }
}

test "a tagged struct takes the name of its typedef" {
    const Translation = struct {
        pub const struct_san_a = extern struct { x: i32 };
        pub const san_a = struct_san_a;
        pub const struct_san_b = extern struct { y: i32 };
        pub const san_b = i32;
        pub const san_c = i32;
    };

    try testing.expectEqualStrings(
        "san_a",
        typeName(Translation, "struct_san_a", Translation.struct_san_a),
    );

    try testing.expectEqualStrings(
        "struct_san_b",
        typeName(Translation, "struct_san_b", Translation.struct_san_b),
    );

    try testing.expectEqualStrings(
        "san_c",
        typeName(Translation, "san_c", Translation.san_c),
    );
}

test "type and jni values have their forms" {
    try expectFailures(&.{
        .{ error.UnknownType, 2, oneRow("type\tsan_status\t*\tint") },
        .{ error.UnknownType, 2, oneRow("type\tsan_status\t*\tint32") },
        .{ error.BadDescriptor, 2, oneRow("jni\ta/B.c\t*\tJ[J)I") },
        .{ error.BadDescriptor, 2, oneRow("jni\ta/B.c\t*\t(J[J)") },
        .{ error.BadDescriptor, 2, oneRow("jni\ta/B.c\t*\t(J[J)IV") },
        .{ error.BadDescriptor, 2, oneRow("jni\ta/B.c\t*\t(Q)I") },
        .{ error.BadDescriptor, 2, oneRow("jni\ta/B.c\t*\t(L;)V") },
        .{ error.BadDescriptor, 2, oneRow("jni\ta/B.c\t*\t(Lapp/;)V") },
        .{ error.BadDescriptor, 2, oneRow("jni\ta/B.c\t*\t([)V") },
        .{ error.BadDescriptor, 2, oneRow("jni\ta/B.c\t*\t(J)VV") },
    });
}

test "valid jni descriptors parse" {
    const text = header_line ++ "\n" ++
        "jni\ta/B.c\t*\t()V\n" ++
        "jni\ta/B.d\t*\t(I)I\n" ++
        "jni\ta/B.e\t*\t([[JLjava/lang/String;Z)[B\n" ++
        "jni\ta/B$C.f\t*\t(La/B$C;)Ljava/lang/Object;\n";

    var diagnostic: Diagnostic = .{};

    const rows = try parseText(text, &diagnostic);
    defer testing.allocator.free(rows);

    try testing.expectEqual(4, rows.len);
}

test "rows are unique and per-ABI rows come in pairs" {
    try expectFailures(&.{
        .{ error.Duplicate, 12, withRow(12, "i32\tSAN_ABI_VERSION\t*\t0") },
        .{
            error.Duplicate,
            12,
            withRow(12, "align\tsan_engine_limits\tx86_64\t8"),
        },
        .{ error.MixedAbi, 12, withRow(12, "align\tsan_engine_limits\t*\t8") },
        .{
            error.MixedAbi,
            12,
            withRow(12, "size\tsan_engine_limits\tx86_64\t8"),
        },
        .{ error.UnpairedAbi, 12, withRow(12, "size\tsan_status\tx86_64\t4") },
    });
}

test "a failure formats with its file and line" {
    var diagnostic: Diagnostic = .{};

    const result = parseText(withRow(3, "i32\tSAN_A\x01\t*\t1"), &diagnostic);

    try testing.expectError(error.ForbiddenByte, result);

    var message: std.Io.Writer.Allocating = .init(testing.allocator);
    defer message.deinit();

    const failure: Failure = .{
        .err = error.ForbiddenByte,
        .diagnostic = diagnostic,
    };

    try message.writer.print("{f}", .{failure});

    try testing.expectEqualStrings(
        "abi.tsv:3: a byte outside printable ASCII, tab, and LF (0x01)",
        message.written(),
    );
}

test "the pinned table parses" {
    const text = @import("bindings").table;

    var diagnostic: Diagnostic = .{};

    const rows = try testing.allocator.alloc(Row, rowCount(text));
    defer testing.allocator.free(rows);

    _ = parse(text, rows, &diagnostic) catch |err| {
        std.debug.print("{f}\n", .{Failure{
            .err = err,
            .diagnostic = diagnostic,
        }});

        return err;
    };

    try testing.expect(rows.len > 0);
}
