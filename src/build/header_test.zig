//! The host test of the translated Bindings header against abi.tsv. It
//! checks what holds on every target, in both directions: the constants
//! by their values, and the fixed-width types of the typedefs and the
//! struct fields. Sizes, alignments, and offsets depend on the target,
//! so the Android objects of header_check.zig assert them for each ABI.
//! The header declares what its translation holds and the translation of
//! its system includes lacks, whatever the names.

const std = @import("std");
const bindings = @import("bindings");
const san = @import("san");
const system = @import("system");
const table = @import("table");
const testing = std.testing;

/// The include guard of the header, the one SAN_ macro without a row.
const include_guard = "SAN_H";

/// A SAN_ constant of the translation.
const Constant = struct {
    name: []const u8,
    value: i64,
};

/// A typedef or a struct field of the translation, with its fixed-width
/// type, or null when its type is none of them.
const Typed = struct {
    name: []const u8,
    fixed_width: ?table.FixedWidth,
};

const decl_names = @typeInfo(san).@"struct".decl_names;

/// The SAN_ constants of the translation, except the include guard.
const constants = collect: {
    @setEvalBranchQuota(100_000);

    var list: [decl_names.len]Constant = undefined;
    var count: usize = 0;

    for (decl_names) |name| {
        if (!std.mem.startsWith(u8, name, "SAN_")) continue;
        if (std.mem.eql(u8, name, include_guard)) continue;

        const value = @field(san, name);

        switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => {},
            else => @compileError("translation: " ++ name ++
                " is not an integer constant"),
        }

        list[count] = .{ .name = name, .value = value };
        count += 1;
    }

    break :collect list[0..count].*;
};

/// The integer typedefs and the struct fields that the header declares,
/// under the names that the table gives them.
const typed = collect: {
    @setEvalBranchQuota(100_000);

    var list: [decl_names.len * 8]Typed = undefined;
    var count: usize = 0;

    for (decl_names) |name| {
        if (@hasDecl(system, name)) continue;

        const declaration = @field(san, name);

        if (@TypeOf(declaration) != type) continue;

        // A tagged struct shares the rows of its typedef.
        if (!std.mem.eql(u8, table.typeName(san, name, declaration), name)) {
            continue;
        }

        switch (@typeInfo(declaration)) {
            .int => {
                list[count] = .{
                    .name = name,
                    .fixed_width = fixedWidthOf(declaration),
                };

                count += 1;
            },
            .@"struct" => |info| for (info.field_names) |field| {
                const Field = @FieldType(declaration, field);

                list[count] = .{
                    .name = name ++ "." ++ field,
                    .fixed_width = fixedWidthOf(Field),
                };

                count += 1;
            },
            else => {},
        }
    }

    break :collect list[0..count].*;
};

fn fixedWidthOf(comptime T: type) ?table.FixedWidth {
    for (std.enums.values(table.FixedWidth)) |fixed_width| {
        if (fixed_width.Type() == T) return fixed_width;
    }

    return null;
}

/// Parses the pinned table. The caller owns the returned rows.
fn parseTable() ![]table.Row {
    const rows = try testing.allocator.alloc(
        table.Row,
        table.rowCount(bindings.table),
    );
    errdefer testing.allocator.free(rows);

    var diagnostic: table.Diagnostic = .{};

    return table.parse(bindings.table, rows, &diagnostic) catch |err| {
        std.debug.print("{f}\n", .{table.Failure{
            .err = err,
            .diagnostic = diagnostic,
        }});

        return err;
    };
}

fn findConstant(name: []const u8) ?Constant {
    for (constants) |constant| {
        if (std.mem.eql(u8, constant.name, name)) return constant;
    }

    return null;
}

fn findTyped(name: []const u8) ?Typed {
    for (typed) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }

    return null;
}

fn hasRow(
    rows: []const table.Row,
    kinds: []const table.Kind,
    name: []const u8,
) bool {
    for (rows) |row| {
        if (std.mem.findScalar(table.Kind, kinds, row.kind) == null) continue;
        if (std.mem.eql(u8, row.name, name)) return true;
    }

    return false;
}

test "every constant row matches the translated constant" {
    const rows = try parseTable();
    defer testing.allocator.free(rows);

    var checked: usize = 0;

    for (rows) |row| {
        if (row.kind != .i32 and row.kind != .i64) continue;

        const constant = findConstant(row.name) orelse {
            std.debug.print("abi.tsv:{d}: {s} names no constant of the " ++
                "translation\n", .{ row.line, row.name });

            return error.TestUnexpectedResult;
        };

        try testing.expectEqual(row.value.integer, constant.value);
        checked += 1;
    }

    try testing.expect(checked > 0);
}

test "every translated constant has an i32 or i64 row" {
    const rows = try parseTable();
    defer testing.allocator.free(rows);

    for (constants) |constant| {
        if (hasRow(rows, &.{ .i32, .i64 }, constant.name)) continue;

        std.debug.print("abi.tsv: no i32 or i64 row for {s}\n", .{
            constant.name,
        });

        return error.TestUnexpectedResult;
    }
}

test "every type row matches the translated fixed-width type" {
    const rows = try parseTable();
    defer testing.allocator.free(rows);

    var checked: usize = 0;

    for (rows) |row| {
        if (row.kind != .type) continue;

        const item = findTyped(row.name) orelse {
            std.debug.print("abi.tsv:{d}: {s} names no integer typedef or " ++
                "field of the translation\n", .{ row.line, row.name });

            return error.TestUnexpectedResult;
        };

        try testing.expectEqual(row.value.fixed_width, item.fixed_width);
        checked += 1;
    }

    try testing.expect(checked > 0);
}

test "every translated typedef and field has a type row" {
    const rows = try parseTable();
    defer testing.allocator.free(rows);

    for (typed) |item| {
        if (hasRow(rows, &.{.type}, item.name)) continue;

        std.debug.print("abi.tsv: no type row for {s}\n", .{item.name});

        return error.TestUnexpectedResult;
    }
}
