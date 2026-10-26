//! The host test of San's libpng configuration header against libpng's
//! prebuilt default, scripts/pnglibconf.h.prebuilt of the pinned libpng
//! package. San derives its header from the default only by turning
//! options off: both headers name the same options, San's header turns on
//! no option that the default leaves off, and every setting keeps its
//! value. DISABLE_ADLER32_CHECK stays off, so no option can turn off the
//! Adler-32 check of the image data stream.
//!
//! The parser accepts only the lines of libpng's format, in its order. A
//! directive outside the option and setting lines therefore fails the
//! parse instead of escaping the comparison.

const std = @import("std");
const pnglibconf = @import("pnglibconf");
const testing = std.testing;

/// An option, PNG_<name>_SUPPORTED, and whether the header defines it.
const Option = struct {
    name: []const u8,
    on: bool,
};

/// A setting, PNG_<name>, and the text of its value.
const Setting = struct {
    name: []const u8,
    value: []const u8,
};

/// A parsed configuration header. Its names and values point into the
/// parsed text.
const Header = struct {
    options: []const Option,
    settings: []const Setting,

    fn deinit(header: Header, gpa: std.mem.Allocator) void {
        gpa.free(header.options);
        gpa.free(header.settings);
    }

    fn option(header: Header, name: []const u8) ?Option {
        for (header.options) |item| {
            if (std.mem.eql(u8, item.name, name)) return item;
        }

        return null;
    }

    fn setting(header: Header, name: []const u8) ?Setting {
        for (header.settings) |item| {
            if (std.mem.eql(u8, item.name, name)) return item;
        }

        return null;
    }
};

const ParseError = error{
    /// A line that libpng's format does not have at its place.
    UnexpectedLine,
    /// The text ends before the end of the include guard and its final
    /// newline.
    Truncated,
    /// An option or a setting appears twice.
    Duplicate,
} || std.mem.Allocator.Error;

/// The part of the header that a line belongs to, in the order of
/// libpng's format.
const Part = enum {
    /// Comments and blank lines before the include guard.
    head,
    /// After #ifndef PNGLCONF_H, before #define PNGLCONF_H.
    guard,
    /// After the include guard, before the options.
    guarded,
    options,
    /// After the options, before the settings.
    between,
    settings,
    /// After the settings, before the end of the include guard.
    tail,
    /// After the end of the include guard: nothing.
    closed,
};

/// Parses a configuration header in libpng's format. On an error,
/// `line` holds the number of the line that caused it.
fn parse(
    gpa: std.mem.Allocator,
    text: []const u8,
    line: *usize,
) ParseError!Header {
    var options: std.ArrayList(Option) = .empty;
    defer options.deinit(gpa);

    var settings: std.ArrayList(Setting) = .empty;
    defer settings.deinit(gpa);

    var part: Part = .head;
    var in_comment = false;

    line.* = 0;

    const body = std.mem.cutSuffix(u8, text, "\n") orelse
        return error.Truncated;

    var lines = std.mem.splitScalar(u8, body, '\n');

    while (lines.next()) |current| {
        line.* += 1;

        if (in_comment) {
            in_comment = !try endsComment(current);

            continue;
        }

        switch (part) {
            .head => {
                if (current.len == 0) continue;

                if (std.mem.cutPrefix(u8, current, "/*")) |rest| {
                    in_comment = !try endsComment(rest);
                } else if (std.mem.eql(u8, current, "#ifndef PNGLCONF_H")) {
                    part = .guard;
                } else return error.UnexpectedLine;
            },
            .guard => part = try expect(
                current,
                "#define PNGLCONF_H",
                .guarded,
            ),
            .guarded => part = try expect(current, "/* options */", .options),
            .options => {
                if (std.mem.eql(u8, current, "/* end of options */")) {
                    part = .between;

                    continue;
                }

                const option = parseOption(current) orelse
                    return error.UnexpectedLine;

                for (options.items) |item| {
                    if (std.mem.eql(u8, item.name, option.name)) {
                        return error.Duplicate;
                    }
                }

                try options.append(gpa, option);
            },
            .between => part = try expect(
                current,
                "/* settings */",
                .settings,
            ),
            .settings => {
                if (std.mem.eql(u8, current, "/* end of settings */")) {
                    part = .tail;

                    continue;
                }

                const setting = parseSetting(current) orelse
                    return error.UnexpectedLine;

                for (settings.items) |item| {
                    if (std.mem.eql(u8, item.name, setting.name)) {
                        return error.Duplicate;
                    }
                }

                try settings.append(gpa, setting);
            },
            .tail => part = try expect(
                current,
                "#endif /* PNGLCONF_H */",
                .closed,
            ),
            .closed => return error.UnexpectedLine,
        }
    }

    if (part != .closed or in_comment) return error.Truncated;

    const owned_options = try options.toOwnedSlice(gpa);
    errdefer gpa.free(owned_options);

    const owned_settings = try settings.toOwnedSlice(gpa);

    return .{ .options = owned_options, .settings = owned_settings };
}

/// Reports whether a comment ends in `rest`, the text of a line after the
/// comment's start. Text after the end of a comment fails, so that a
/// comment cannot hide a directive behind it.
fn endsComment(rest: []const u8) ParseError!bool {
    const end = std.mem.find(u8, rest, "*/") orelse return false;

    if (end + 2 != rest.len) return error.UnexpectedLine;

    return true;
}

/// Returns `next` when `current` is the line `expected`.
fn expect(
    current: []const u8,
    expected: []const u8,
    next: Part,
) ParseError!Part {
    if (!std.mem.eql(u8, current, expected)) return error.UnexpectedLine;

    return next;
}

/// Parses `#define PNG_<name>_SUPPORTED` and its off form,
/// `/*#undef PNG_<name>_SUPPORTED*/`.
fn parseOption(current: []const u8) ?Option {
    if (std.mem.cutPrefix(u8, current, "#define PNG_")) |rest| {
        const name = std.mem.cutSuffix(u8, rest, "_SUPPORTED") orelse
            return null;

        if (!isName(name)) return null;

        return .{ .name = name, .on = true };
    }

    const rest = std.mem.cutPrefix(u8, current, "/*#undef PNG_") orelse
        return null;

    const name = std.mem.cutSuffix(u8, rest, "_SUPPORTED*/") orelse
        return null;

    if (!isName(name)) return null;

    return .{ .name = name, .on = false };
}

/// Parses `#define PNG_<name> <value>`.
fn parseSetting(current: []const u8) ?Setting {
    const rest = std.mem.cutPrefix(u8, current, "#define PNG_") orelse
        return null;

    const name, const value = std.mem.cut(u8, rest, " ") orelse return null;

    if (!isName(name) or value.len == 0) return null;

    return .{ .name = name, .value = value };
}

fn isName(text: []const u8) bool {
    if (text.len == 0) return false;

    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }

    return true;
}

const Mismatch = error{
    /// One header names an option that the other lacks.
    OptionSet,
    /// San's header turns on an option that the default leaves off.
    TurnedOn,
    /// One header lacks a setting of the other, or a value differs.
    Setting,
    /// DISABLE_ADLER32_CHECK is on or absent in San's header.
    Adler32Check,
};

/// Checks that `san` derives from `prebuilt` only by turning options off.
/// On an error, `name` holds the option or setting that caused it.
fn checkDerivation(
    san: Header,
    prebuilt: Header,
    name: *[]const u8,
) Mismatch!void {
    for (san.options) |option| {
        name.* = option.name;

        const default = prebuilt.option(option.name) orelse
            return error.OptionSet;

        if (option.on and !default.on) return error.TurnedOn;
    }

    for (prebuilt.options) |option| {
        name.* = option.name;

        if (san.option(option.name) == null) return error.OptionSet;
    }

    for (san.settings) |setting| {
        name.* = setting.name;

        const default = prebuilt.setting(setting.name) orelse
            return error.Setting;

        if (!std.mem.eql(u8, setting.value, default.value)) {
            return error.Setting;
        }
    }

    for (prebuilt.settings) |setting| {
        name.* = setting.name;

        if (san.setting(setting.name) == null) return error.Setting;
    }

    name.* = "DISABLE_ADLER32_CHECK";

    const adler32 = san.option(name.*) orelse return error.Adler32Check;

    if (adler32.on) return error.Adler32Check;
}

/// Parses the header `text` of the file `file`, and prints the line of a
/// failure.
fn parseNamed(file: []const u8, text: []const u8) ParseError!Header {
    var line: usize = 0;

    return parse(testing.allocator, text, &line) catch |err| {
        std.debug.print("{s}:{d}: {t}\n", .{ file, line, err });

        return err;
    };
}

test "san's header derives from the default only by turning options off" {
    const san = try parseNamed("san pnglibconf.h", pnglibconf.san);
    defer san.deinit(testing.allocator);

    const prebuilt = try parseNamed(
        "scripts/pnglibconf.h.prebuilt",
        pnglibconf.prebuilt,
    );
    defer prebuilt.deinit(testing.allocator);

    try testing.expect(prebuilt.options.len > 0);
    try testing.expect(prebuilt.settings.len > 0);

    var name: []const u8 = "";

    checkDerivation(san, prebuilt, &name) catch |err| {
        std.debug.print("pnglibconf.h: {t} at PNG_{s}\n", .{ err, name });

        return err;
    };
}

/// A small header in libpng's format, with one off option and one setting.
const sample =
    \\/* comment */
    \\
    \\/* a comment
    \\ * over lines */
    \\#ifndef PNGLCONF_H
    \\#define PNGLCONF_H
    \\/* options */
    \\#define PNG_READ_SUPPORTED
    \\/*#undef PNG_DISABLE_ADLER32_CHECK_SUPPORTED*/
    \\/* end of options */
    \\/* settings */
    \\#define PNG_ZLIB_VERNUM 0 /* unknown */
    \\/* end of settings */
    \\#endif /* PNGLCONF_H */
    \\
;

/// Returns `sample` with its first `old` replaced by `new`.
fn mutate(old: []const u8, new: []const u8) ![]u8 {
    const at = std.mem.find(u8, sample, old) orelse return error.NoSuchText;

    return std.mem.concat(testing.allocator, u8, &.{
        sample[0..at],
        new,
        sample[at + old.len ..],
    });
}

fn parseSample(text: []const u8) ParseError!Header {
    var line: usize = 0;

    return parse(testing.allocator, text, &line);
}

test "the sample parses into its option and setting" {
    const header = try parseSample(sample);
    defer header.deinit(testing.allocator);

    try testing.expectEqual(2, header.options.len);
    try testing.expect(header.option("READ").?.on);
    try testing.expect(!header.option("DISABLE_ADLER32_CHECK").?.on);

    try testing.expectEqualStrings(
        "0 /* unknown */",
        header.setting("ZLIB_VERNUM").?.value,
    );
}

test "a line outside libpng's format fails the parse" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "#ifndef", "#define PNG_SETJMP_SUPPORTED\n#ifndef" },
        .{ "/* comment */", "/* comment */ #define PNG_SETJMP_SUPPORTED" },
        .{ " * over lines */", " * over lines */ #undef PNG_READ_SUPPORTED" },
        .{
            "#define PNGLCONF_H",
            "#define PNGLCONF_H\n#define PNG_SETJMP_SUPPORTED",
        },
        .{
            "/* settings */",
            "#define PNG_SETJMP_SUPPORTED\n/* settings */",
        },
        .{
            "#endif /* PNGLCONF_H */\n",
            "#endif /* PNGLCONF_H */\n#define PNG_SETJMP_SUPPORTED\n",
        },
        .{ "#define PNG_READ_SUPPORTED", "#define PNG_READ_SUPPORTED 1" },
        .{ "#define PNG_READ_SUPPORTED", "#undef PNG_READ_SUPPORTED" },
        .{ "/* end of options */", "/* note */\n/* end of options */" },
        .{ "PNG_ZLIB_VERNUM 0 /* unknown */", "PNG_ZLIB_VERNUM" },
    };

    for (cases) |case| {
        const text = try mutate(case[0], case[1]);
        defer testing.allocator.free(text);

        try testing.expectError(error.UnexpectedLine, parseSample(text));
    }
}

test "a repeated option or setting fails the parse" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{
            "#define PNG_READ_SUPPORTED",
            "#define PNG_READ_SUPPORTED\n/*#undef PNG_READ_SUPPORTED*/",
        },
        .{
            "#define PNG_ZLIB_VERNUM 0 /* unknown */",
            "#define PNG_ZLIB_VERNUM 0\n#define PNG_ZLIB_VERNUM 0",
        },
    };

    for (cases) |case| {
        const text = try mutate(case[0], case[1]);
        defer testing.allocator.free(text);

        try testing.expectError(error.Duplicate, parseSample(text));
    }
}

test "a header without the end of its include guard fails the parse" {
    const text = try mutate("#endif /* PNGLCONF_H */\n", "");
    defer testing.allocator.free(text);

    try testing.expectError(error.Truncated, parseSample(text));
}

test "the derivation check names each kind of difference" {
    const cases = [_]struct { Mismatch, []const u8, []const u8 }{
        .{
            error.TurnedOn,
            "/*#undef PNG_DISABLE_ADLER32_CHECK_SUPPORTED*/",
            "#define PNG_DISABLE_ADLER32_CHECK_SUPPORTED",
        },
        .{
            error.OptionSet,
            "#define PNG_READ_SUPPORTED",
            "#define PNG_READ_SUPPORTED\n#define PNG_WRITE_SUPPORTED",
        },
        .{ error.OptionSet, "#define PNG_READ_SUPPORTED\n", "" },
        .{ error.Setting, "VERNUM 0 /* unknown */", "VERNUM 0x1320" },
        .{ error.Setting, "#define PNG_ZLIB_VERNUM 0 /* unknown */\n", "" },
    };

    const default = try parseSample(sample);
    defer default.deinit(testing.allocator);

    for (cases) |case| {
        const text = try mutate(case[1], case[2]);
        defer testing.allocator.free(text);

        const san = try parseSample(text);
        defer san.deinit(testing.allocator);

        var name: []const u8 = "";

        try testing.expectError(case[0], checkDerivation(san, default, &name));
    }

    var name: []const u8 = "";

    try checkDerivation(default, default, &name);

    const off = try mutate(
        "#define PNG_READ_SUPPORTED",
        "/*#undef PNG_READ_SUPPORTED*/",
    );
    defer testing.allocator.free(off);

    const turned_off = try parseSample(off);
    defer turned_off.deinit(testing.allocator);

    try checkDerivation(turned_off, default, &name);
}

test "the derivation check requires the adler-32 check" {
    const text = try mutate(
        "/*#undef PNG_DISABLE_ADLER32_CHECK_SUPPORTED*/\n",
        "",
    );
    defer testing.allocator.free(text);

    const san = try parseSample(text);
    defer san.deinit(testing.allocator);

    const default = try parseSample(text);
    defer default.deinit(testing.allocator);

    var name: []const u8 = "";

    try testing.expectError(
        error.Adler32Check,
        checkDerivation(san, default, &name),
    );
}
