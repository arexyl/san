//! Check the install prefix of stage-device.
//!
//! Usage: install-prefix <expected> <prefix>
//!
//! stage-device installs the inspected files of one ABI and mode, and a
//! device run takes them from the directory named after both,
//! build/work/<abi>-<mode>/ under the San root. Zig resolves the install
//! prefix only when the build runs, so no configure-time check can read
//! it, and without --prefix Zig installs into zig-out/ at the San root,
//! where no build output may appear. stage-device runs this check before
//! both installs. It exits 0 when <prefix> names the directory
//! <expected>, 1 when it names another one, and 2 on a usage error.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Reports whether `prefix` names the directory `expected`. Both must be
/// absolute. They are compared after a lexical resolution, so a trailing
/// separator or a `.` component changes nothing; a symbolic link is not
/// followed.
pub fn matches(
    gpa: Allocator,
    expected: []const u8,
    prefix: []const u8,
) Allocator.Error!bool {
    const absolute = std.fs.path.isAbsolute(expected) and
        std.fs.path.isAbsolute(prefix);

    if (!absolute) return false;

    const wanted = try std.fs.path.resolve(gpa, &.{expected});
    defer gpa.free(wanted);

    const given = try std.fs.path.resolve(gpa, &.{prefix});
    defer gpa.free(given);

    return std.mem.eql(u8, wanted, given);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 3) {
        std.debug.print("usage: install-prefix <expected> <prefix>\n", .{});
        std.process.exit(2);
    }

    if (try matches(arena, args[1], args[2])) return;

    std.debug.print("install-prefix: stage-device installs into {s} " ++
        "alone, not into {s}; pass --prefix {s}\n", .{
        args[1],
        args[2],
        args[1],
    });

    std.process.exit(1);
}

const testing = std.testing;

test "the prefix matches its directory in any lexical spelling" {
    const expected = "/san/build/work/arm64-v8a-safe";

    const spellings = [_][]const u8{
        "/san/build/work/arm64-v8a-safe",
        "/san/build/work/arm64-v8a-safe/",
        "/san/build/./work/arm64-v8a-safe",
        "/san/build/work/x86_64-safe/../arm64-v8a-safe",
    };

    for (spellings) |prefix| {
        try testing.expect(try matches(testing.allocator, expected, prefix));
    }
}

test "another directory or a relative prefix does not match" {
    const expected = "/san/build/work/arm64-v8a-safe";

    const prefixes = [_][]const u8{
        "/san/zig-out",
        "/san/build/work/arm64-v8a-debug",
        "/san/build/work/x86_64-safe",
        "/san/build/work",
        "/san/build/work/arm64-v8a-safe/lib",
        "build/work/arm64-v8a-safe",
    };

    for (prefixes) |prefix| {
        try testing.expect(!try matches(testing.allocator, expected, prefix));
    }

    try testing.expect(!try matches(
        testing.allocator,
        "build/work/arm64-v8a-safe",
        "build/work/arm64-v8a-safe",
    ));
}
