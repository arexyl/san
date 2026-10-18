//! The ambient inputs of an invocation: the environment variables
//! through which Zig would take a package store, a local cache, a libc
//! description, a standard library, an install root, or a global cache
//! from outside San's own layout. A
//! supported invocation passes every path flag explicitly and sets
//! ZIG_GLOBAL_CACHE_DIR to San's own global cache. build.zig refuses
//! each other input at configure time with a message that names it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A variable that a supported invocation leaves unset, with the reason.
pub const Forbidden = struct {
    name: []const u8,
    reason: []const u8,
};

/// The variables that a supported invocation leaves unset.
pub const forbidden = [_]Forbidden{
    .{
        .name = "ZIG_LOCAL_PKG_DIR",
        .reason = "San's invocations name the package store with " ++
            "--pkg-dir and --system",
    },
    .{
        .name = "ZIG_LOCAL_CACHE_DIR",
        .reason = "San's invocations name the local cache with --cache-dir",
    },
    .{
        .name = "ZIG_LIBC",
        .reason = "San's build takes no libc description from the " ++
            "environment",
    },
    .{
        .name = "ZIG_LIB_DIR",
        .reason = "San's build uses the standard library of the Zig " ++
            "that runs it, also as translate-c's --zig-lib",
    },
    .{
        .name = "DESTDIR",
        .reason = "San's install step writes only under the --prefix " ++
            "that the invocation names",
    },
};

/// The variable that selects the global cache. Zig 0.17.0 has no flag
/// for it, and without it the cache follows XDG_CACHE_HOME and HOME.
pub const global_cache_name = "ZIG_GLOBAL_CACHE_DIR";

/// An ambient input that the build refuses.
pub const Refusal = union(enum) {
    /// A variable of `forbidden` is set, to any value.
    forbidden: Forbidden,
    /// ZIG_GLOBAL_CACHE_DIR is unset.
    global_cache_unset,
    /// ZIG_GLOBAL_CACHE_DIR names another path, or a relative one. The
    /// value borrows from the environment map.
    global_cache_other: []const u8,

    /// Writes the refusal as one line that names the variable.
    /// `global_cache` is San's own global cache.
    pub fn write(
        refusal: Refusal,
        writer: *std.Io.Writer,
        global_cache: []const u8,
    ) std.Io.Writer.Error!void {
        switch (refusal) {
            .forbidden => |variable| try writer.print(
                "{s} is set; unset it: {s}\n",
                .{ variable.name, variable.reason },
            ),
            .global_cache_unset => try writer.print(
                "{s} is unset; set it to {s}, San's own global cache\n",
                .{ global_cache_name, global_cache },
            ),
            .global_cache_other => |value| try writer.print(
                "{s} is {s}; set it to {s}, San's own global cache\n",
                .{ global_cache_name, value, global_cache },
            ),
        }
    }
};

/// Returns every ambient input of `environ` that the build refuses.
/// `global_cache` is the absolute path of San's own global cache. The
/// caller owns the returned slice, and the refusals borrow the values
/// of `environ`.
pub fn check(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    global_cache: []const u8,
) Allocator.Error![]Refusal {
    var refusals: std.ArrayList(Refusal) = .empty;
    errdefer refusals.deinit(gpa);

    for (forbidden) |variable| {
        if (environ.get(variable.name) != null) {
            try refusals.append(gpa, .{ .forbidden = variable });
        }
    }

    if (environ.get(global_cache_name)) |value| {
        if (!try samePath(gpa, value, global_cache)) {
            try refusals.append(gpa, .{ .global_cache_other = value });
        }
    } else {
        try refusals.append(gpa, .global_cache_unset);
    }

    return refusals.toOwnedSlice(gpa);
}

/// Reports whether the absolute path `value` names `expected` once both
/// are resolved lexically. A relative value never does: coord.py runs
/// from the Hakusan root, so a relative value follows the caller's
/// working directory.
fn samePath(
    gpa: Allocator,
    value: []const u8,
    expected: []const u8,
) Allocator.Error!bool {
    if (!std.fs.path.isAbsolute(value)) return false;

    const resolved_value = try std.fs.path.resolveAlloc(gpa, &.{value});
    defer gpa.free(resolved_value);

    const resolved_expected = try std.fs.path.resolveAlloc(gpa, &.{expected});
    defer gpa.free(resolved_expected);

    return std.mem.eql(u8, resolved_value, resolved_expected);
}

const testing = std.testing;

const san_global_cache = "/San/build/cache/zig-global";

/// An environment and the refusals of its check, which borrow from it.
const Checked = struct {
    environ: std.process.Environ.Map,
    refusals: []Refusal,

    fn init(pairs: []const [2][]const u8) !Checked {
        var environ: std.process.Environ.Map = .init(testing.allocator);
        errdefer environ.deinit();

        for (pairs) |pair| try environ.put(pair[0], pair[1]);

        const refusals = try check(
            testing.allocator,
            &environ,
            san_global_cache,
        );

        return .{ .environ = environ, .refusals = refusals };
    }

    fn deinit(checked: *Checked) void {
        testing.allocator.free(checked.refusals);
        checked.environ.deinit();
    }
};

test "a supported environment has no refusal" {
    var checked: Checked = try .init(&.{
        .{ global_cache_name, san_global_cache },
        .{ "HOME", "/Users/someone" },
    });
    defer checked.deinit();

    try testing.expectEqual(0, checked.refusals.len);
}

test "each forbidden variable is refused by name, even when empty" {
    for (forbidden) |variable| {
        for ([_][]const u8{ "/elsewhere", "" }) |value| {
            var checked: Checked = try .init(&.{
                .{ global_cache_name, san_global_cache },
                .{ variable.name, value },
            });
            defer checked.deinit();

            try testing.expectEqual(1, checked.refusals.len);

            const refused = checked.refusals[0].forbidden;

            try testing.expectEqualStrings(variable.name, refused.name);
        }
    }
}

test "an unset global cache is refused" {
    var checked: Checked = try .init(&.{});
    defer checked.deinit();

    try testing.expectEqual(1, checked.refusals.len);
    try testing.expect(checked.refusals[0] == .global_cache_unset);
}

test "another or a relative global cache is refused" {
    const values = [_][]const u8{
        "/Users/someone/.cache/zig",
        "/San/build/cache/zig",
        "San/build/cache/zig-global",
        "build/cache/zig-global",
    };

    for (values) |value| {
        var checked: Checked = try .init(&.{.{ global_cache_name, value }});
        defer checked.deinit();

        try testing.expectEqual(1, checked.refusals.len);

        const refusal = checked.refusals[0];

        try testing.expectEqualStrings(value, refusal.global_cache_other);
    }
}

test "the global cache compares after lexical resolution" {
    const values = [_][]const u8{
        "/San/build/cache/zig-global/",
        "/San/build/./cache/zig-global",
        "/San/build/work/../cache/zig-global",
    };

    for (values) |value| {
        var checked: Checked = try .init(&.{.{ global_cache_name, value }});
        defer checked.deinit();

        try testing.expectEqual(0, checked.refusals.len);
    }
}

test "every refusal is reported, and each line names its variable" {
    var checked: Checked = try .init(&.{
        .{ "ZIG_LIBC", "/libc.txt" },
        .{ "ZIG_LOCAL_PKG_DIR", "/pkg" },
        .{ "ZIG_LOCAL_CACHE_DIR", "/cache" },
        .{ "ZIG_LIB_DIR", "/lib/zig" },
        .{ "DESTDIR", "/stage" },
    });
    defer checked.deinit();

    var message: std.Io.Writer.Allocating = .init(testing.allocator);
    defer message.deinit();

    for (checked.refusals) |refusal| {
        try refusal.write(&message.writer, san_global_cache);
    }

    const written = message.written();

    const unset = global_cache_name ++ " is unset";

    try testing.expectEqual(forbidden.len + 1, checked.refusals.len);
    try testing.expect(std.mem.find(u8, written, unset) != null);

    for (forbidden) |variable| {
        try testing.expect(std.mem.find(u8, written, variable.name) != null);
    }
}
