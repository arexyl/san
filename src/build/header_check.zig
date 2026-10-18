//! The compile-time checks of the translated Bindings header for one
//! Android ABI. The object compiles only when every check holds:
//! - abi.tsv parses under the Table format of the Bindings readme;
//! - every row that holds on this ABI names a declaration of the
//!   translation and matches it: a constant by its value, a type by its
//!   fixed-width type, and a size, an alignment, or an offset by Zig's
//!   layout of the translated type, which is not clang's;
//! - every SAN_ macro of the header is a decimal `N` or `( -N )`, and its
//!   translation has that value;
//! - the table is complete in both directions: every SAN_ macro of the
//!   header and of the translation has an i32 or i64 row, and every
//!   typedef and struct that the header declares has its rows;
//! - the function prototypes, which have no row kind, match San's
//!   expectation of the header, and the header declares no other
//!   function;
//! - the target of an arm64-v8a object reserves x18.
//!
//! The header declares what its translation holds and the translation of
//! its system includes lacks, whatever the names. jni rows belong to the
//! Kotlin declarations and only parse here.

const std = @import("std");
const builtin = @import("builtin");
const bindings = @import("bindings");
const san = @import("san");
const system = @import("system");
const table = @import("table");

const abi: table.Abi = switch (builtin.cpu.arch) {
    .aarch64 => .@"arm64-v8a",
    .x86_64 => .x86_64,
    else => @compileError("the header check compiles only for an Android ABI"),
};

/// The include guard of the header, the one SAN_ macro without a row.
const include_guard = "SAN_H";

/// San's expectation of each function of the header.
const prototypes = .{
    .{ "san_binding_establish", fn (i32) callconv(.c) i32 },
    .{
        "san_engine_create",
        fn ([*c]const san.san_engine_limits, [*c]i64) callconv(.c) i32,
    },
    .{ "san_engine_shutdown", fn (i64) callconv(.c) i32 },
};

const rows = parsed: {
    var buffer: [table.rowCount(bindings.table)]table.Row = undefined;
    var diagnostic: table.Diagnostic = .{};

    _ = table.parse(bindings.table, &buffer, &diagnostic) catch |err| {
        fail("{f}", .{table.Failure{ .err = err, .diagnostic = diagnostic }});
    };

    break :parsed buffer;
};

comptime {
    if (!builtin.abi.isAndroid()) {
        @compileError("the header check compiles only for Android");
    }

    if (abi == .@"arm64-v8a" and !builtin.cpu.has(.aarch64, .reserve_x18)) {
        @compileError("the arm64-v8a target does not reserve x18");
    }
}

// Every row that holds on this ABI matches the translation.
comptime {
    @setEvalBranchQuota(200_000);

    for (rows) |row| {
        if (row.holdsOn(abi)) checkRow(row);
    }
}

// Every SAN_ macro of the header has the form of an i32 or i64 macro, is
// translated with the value of that form, and has a row.
comptime {
    @setEvalBranchQuota(200_000);

    const define = "\n#define ";
    var rest: []const u8 = bindings.header;

    while (std.mem.find(u8, rest, define)) |at| {
        rest = rest[at + define.len ..];

        const name = rest[0..identifierEnd(rest)];

        if (!std.mem.startsWith(u8, name, "SAN_")) continue;
        if (std.mem.eql(u8, name, include_guard)) continue;

        const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;

        const body = std.mem.trim(u8, rest[name.len..line_end], " \t");

        const value = table.macroValue(body) orelse fail(
            "san.h: the macro {s} is '{s}', not a decimal N or ( -N )",
            .{ name, body },
        );

        if (!@hasDecl(san, name)) {
            fail("san.h: the macro {s} is missing from the translation", .{
                name,
            });
        }

        if (@field(san, name) != value) {
            fail("san.h: the macro {s} is {d}, and its translation {d}", .{
                name,
                value,
                @field(san, name),
            });
        }

        requireConstantRow(name);
    }
}

// Every declaration of the header has its rows or its prototype: a SAN_
// macro its i32 or i64 row, a typedef or a struct its type, size, align,
// and offset rows, and a function San's prototype.
comptime {
    @setEvalBranchQuota(200_000);

    for (@typeInfo(san).@"struct".decl_names) |name| {
        if (@hasDecl(system, name)) continue;
        if (std.mem.eql(u8, name, include_guard)) continue;

        const declaration = @field(san, name);

        if (@TypeOf(declaration) == type) {
            requireTypeRows(name, declaration);
        } else if (@typeInfo(@TypeOf(declaration)) == .@"fn") {
            if (!hasPrototype(name)) {
                fail("translation: San expects no function {s}", .{name});
            }
        } else if (std.mem.startsWith(u8, name, "SAN_")) {
            requireConstantRow(name);
        } else {
            fail("translation: san.h declares {s}, which is neither a " ++
                "type, a function, nor a SAN_ macro", .{name});
        }
    }
}

// Every function that San expects is translated with its prototype.
comptime {
    for (prototypes) |prototype| {
        const name, const Expected = prototype;

        if (!@hasDecl(san, name)) {
            fail("translation: the function {s} is missing", .{name});
        }

        const Actual = @TypeOf(@field(san, name));

        if (Actual != Expected) {
            fail("translation: {s} is {s}, San expects {s}", .{
                name,
                @typeName(Actual),
                @typeName(Expected),
            });
        }
    }
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    @compileError(std.fmt.comptimePrint(format, args));
}

fn checkRow(comptime row: table.Row) void {
    switch (row.kind) {
        .i32, .i64 => checkConstant(row),
        .type => checkFixedWidth(row),
        .size, .@"align" => {
            const T = namedType(row, row.name);

            const actual = if (row.kind == .size) @sizeOf(T) else @alignOf(T);

            if (actual != row.value.integer) {
                fail("abi.tsv:{d}: {t} of {s} is {d}, the table says {d}", .{
                    row.line,
                    row.kind,
                    row.name,
                    actual,
                    row.value.integer,
                });
            }
        },
        .offset => {
            const T, const field = fieldOf(row);

            const actual = @offsetOf(T, field);

            if (actual != row.value.integer) {
                fail("abi.tsv:{d}: offset of {s} is {d}, the table says {d}", .{
                    row.line,
                    row.name,
                    actual,
                    row.value.integer,
                });
            }
        },
        .jni => {},
    }
}

/// Compares a constant by its value. The range of the value belongs to
/// the parser, so the width of the translated C type never matters.
fn checkConstant(comptime row: table.Row) void {
    if (!@hasDecl(san, row.name)) {
        fail("abi.tsv:{d}: {s} names no declaration of the translation", .{
            row.line,
            row.name,
        });
    }

    const value = @field(san, row.name);

    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {},
        else => fail("abi.tsv:{d}: {s} is not an integer constant", .{
            row.line,
            row.name,
        }),
    }

    if (value != row.value.integer) {
        fail("abi.tsv:{d}: {s} is {d}, the table says {d}", .{
            row.line,
            row.name,
            value,
            row.value.integer,
        });
    }
}

fn checkFixedWidth(comptime row: table.Row) void {
    const fixed_width = row.value.fixed_width;

    const Expected = fixed_width.Type();

    const Actual = if (row.field() != null) actual: {
        const T, const field = fieldOf(row);

        break :actual @FieldType(T, field);
    } else namedType(row, row.name);

    if (Actual != Expected) {
        fail("abi.tsv:{d}: {s} is {s}, the table says {t}", .{
            row.line,
            row.name,
            @typeName(Actual),
            fixed_width,
        });
    }

    const c_name = @tagName(fixed_width);

    if (@hasDecl(san, c_name) and @field(san, c_name) != Expected) {
        fail("translation: {s} is {s}, not {s}", .{
            c_name,
            @typeName(@field(san, c_name)),
            @typeName(Expected),
        });
    }
}

/// Returns the declaration `name` of the translation, which must be a
/// type.
fn namedType(comptime row: table.Row, comptime name: []const u8) type {
    if (!@hasDecl(san, name)) {
        fail("abi.tsv:{d}: {s} names no declaration of the translation", .{
            row.line,
            name,
        });
    }

    const declaration = @field(san, name);

    if (@TypeOf(declaration) != type) {
        fail("abi.tsv:{d}: {s} is not a type", .{ row.line, name });
    }

    return declaration;
}

/// Returns the struct type and the field of a row written
/// `struct.field`.
fn fieldOf(comptime row: table.Row) struct { type, []const u8 } {
    const struct_name, const field = row.field().?;

    const T = namedType(row, struct_name);

    if (@typeInfo(T) != .@"struct") {
        fail("abi.tsv:{d}: {s} is not a struct", .{ row.line, struct_name });
    }

    if (!@hasField(T, field)) {
        fail("abi.tsv:{d}: {s} has no field {s}", .{
            row.line,
            struct_name,
            field,
        });
    }

    return .{ T, field };
}

fn hasRow(comptime kind: table.Kind, comptime name: []const u8) bool {
    for (rows) |row| {
        if (row.kind != kind or !row.holdsOn(abi)) continue;
        if (std.mem.eql(u8, row.name, name)) return true;
    }

    return false;
}

fn requireRow(comptime kind: table.Kind, comptime name: []const u8) void {
    if (!hasRow(kind, name)) {
        fail("abi.tsv: no {t} row for {s} on {t}", .{ kind, name, abi });
    }
}

fn requireConstantRow(comptime name: []const u8) void {
    if (!hasRow(.i32, name) and !hasRow(.i64, name)) {
        fail("abi.tsv: no i32 or i64 row for the macro {s}", .{name});
    }
}

/// Requires the rows of a typedef or a struct of the translation: size
/// and align, a type row for an integer typedef, and type and offset
/// rows for each field of a struct.
fn requireTypeRows(comptime name: []const u8, comptime T: type) void {
    const canonical = table.typeName(san, name, T);

    requireRow(.size, canonical);
    requireRow(.@"align", canonical);

    switch (@typeInfo(T)) {
        .int => requireRow(.type, canonical),
        .@"struct" => |info| for (info.field_names) |field| {
            requireRow(.type, canonical ++ "." ++ field);
            requireRow(.offset, canonical ++ "." ++ field);
        },
        else => fail("translation: {s} is a {t}, which no row describes", .{
            name,
            @typeInfo(T),
        }),
    }
}

fn hasPrototype(comptime name: []const u8) bool {
    inline for (prototypes) |prototype| {
        if (std.mem.eql(u8, prototype[0], name)) return true;
    }

    return false;
}

fn identifierEnd(text: []const u8) usize {
    for (text, 0..) |char, end| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return end;
    }

    return text.len;
}
