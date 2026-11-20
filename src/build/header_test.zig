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

/// The suffix of the length macro of a report.
const length_suffix = "_LENGTH";

/// Checks the report rule of the Table format on `rows` and returns the
/// count of reports. The i32 row `SAN_<REPORT>_LENGTH` names a report,
/// and every other constant row that starts with `SAN_<REPORT>_` is one
/// of its elements: an i32 row, whose values run from zero to the length
/// minus one, each once.
fn checkReports(rows: []const table.Row) !usize {
    var reports: usize = 0;

    for (rows) |length_row| {
        if (length_row.kind != .i32) continue;

        const report = std.mem.cutSuffix(
            u8,
            length_row.name,
            length_suffix,
        ) orelse continue;

        const length = std.math.cast(usize, length_row.value.integer) orelse
            return error.ReportLength;

        const seen = try testing.allocator.alloc(bool, length);
        defer testing.allocator.free(seen);

        @memset(seen, false);

        for (rows) |row| {
            if (row.kind != .i32 and row.kind != .i64) continue;
            if (row.line == length_row.line) continue;

            const element = std.mem.cutPrefix(u8, row.name, report) orelse
                continue;

            if (!std.mem.startsWith(u8, element, "_")) continue;
            if (row.kind != .i32) return error.ReportIndex;

            const index = std.math.cast(usize, row.value.integer) orelse
                return error.ReportIndex;

            if (index >= length or seen[index]) return error.ReportIndex;

            seen[index] = true;
        }

        if (std.mem.findScalar(bool, seen, false) != null) {
            return error.ReportIndex;
        }

        reports += 1;
    }

    return reports;
}

/// Returns an i32 row of the name and the value on `line`.
fn constantRow(line: usize, name: []const u8, value: i64) table.Row {
    return .{
        .line = line,
        .kind = .i32,
        .name = name,
        .abi = .any,
        .value = .{ .integer = value },
    };
}

test "the elements of each report run from zero to its length minus one" {
    const rows = try parseTable();
    defer testing.allocator.free(rows);

    // The counters report and the job report.
    try testing.expectEqual(2, try checkReports(rows));
}

test "a report with a missing, repeated, or outlying element is refused" {
    const valid = [_]table.Row{
        constantRow(2, "SAN_A_REPORT_FIRST", 0),
        constantRow(3, "SAN_A_REPORT_LENGTH", 2),
        constantRow(4, "SAN_A_REPORT_SECOND", 1),
        // Neither starts with the report's name and an underscore.
        constantRow(5, "SAN_A_REPORTED", 7),
        constantRow(6, "SAN_A_STATUS", 1),
    };

    try testing.expectEqual(1, try checkReports(&valid));
    try testing.expectEqual(0, try checkReports(valid[3..]));

    const refused = [_]struct { usize, table.Row }{
        // A repeated index, which leaves another one missing.
        .{ 2, constantRow(4, "SAN_A_REPORT_SECOND", 0) },
        // An index at the length, and one below zero.
        .{ 2, constantRow(4, "SAN_A_REPORT_SECOND", 2) },
        .{ 0, constantRow(2, "SAN_A_REPORT_FIRST", -1) },
        // A length that leaves an element out, and one that lacks one.
        .{ 1, constantRow(3, "SAN_A_REPORT_LENGTH", 1) },
        .{ 1, constantRow(3, "SAN_A_REPORT_LENGTH", 3) },
        // An element that the report's prefix claims.
        .{ 3, constantRow(5, "SAN_A_REPORT_THIRD", 7) },
    };

    for (refused) |case| {
        var rows = valid;

        rows[case[0]] = case[1];

        try testing.expectError(error.ReportIndex, checkReports(&rows));
    }

    var negative = valid;

    negative[1] = constantRow(3, "SAN_A_REPORT_LENGTH", -1);

    try testing.expectError(error.ReportLength, checkReports(&negative));

    // An element is an i32 row, also with an index that would fit.
    var wide = valid;

    wide[2].kind = .i64;

    try testing.expectError(error.ReportIndex, checkReports(&wide));
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
