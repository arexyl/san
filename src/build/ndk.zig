//! The NDK root of a San build: the validation of the one explicit root
//! and the registration of its configure-time reads. In this profile San
//! takes only system headers from the NDK; no NDK tool runs.

const std = @import("std");
const profile = @import("profile.zig");

/// An NDK revision as `Pkg.Revision` in `source.properties` records it.
pub const Revision = struct {
    major: u32,
    minor: u32,
    build: u32,
    /// The label of a prerelease, such as `beta1`, or null for a release.
    pre: ?[]const u8 = null,
};

pub const ParseRevisionError = error{
    /// The file has no `Pkg.Revision` key, or the key has no value.
    Missing,
    /// The value is not `major.minor.build` in decimal, optionally
    /// followed by `-` and an alphanumeric prerelease label.
    Garbled,
};

/// A validated NDK root for one target.
pub const Root = struct {
    path: []const u8,
    revision: Revision,
    /// `<sysroot>/usr/include`, then `<sysroot>/usr/include/<triple>`:
    /// the order of a Zig libc description.
    include_dirs: [2][]const u8,
};

/// The outcome of opening an NDK root: the root, or a message that names
/// the rejected input.
pub const Opened = union(enum) {
    ok: Root,
    rejected: []const u8,
};

/// Returns the name of the NDK's prebuilt directory for a host OS, or
/// null when the NDK ships no prebuilt for it.
pub fn hostTag(os_tag: std.Target.Os.Tag) ?[]const u8 {
    return switch (os_tag) {
        .macos => "darwin-x86_64",
        .linux => "linux-x86_64",
        else => null,
    };
}

/// Returns the trimmed `Pkg.Revision` value of a `source.properties`
/// file, or null when the key is absent.
pub fn revisionText(bytes: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");

    while (lines.next()) |line| {
        const equals = std.mem.findScalar(u8, line, '=') orelse continue;

        const key = std.mem.trim(u8, line[0..equals], " \t");

        if (!std.mem.eql(u8, key, "Pkg.Revision")) continue;

        return std.mem.trim(u8, line[equals + 1 ..], " \t");
    }

    return null;
}

/// Parses the `Pkg.Revision` value of an NDK `source.properties` file.
pub fn parseRevision(bytes: []const u8) ParseRevisionError!Revision {
    const value = revisionText(bytes) orelse return error.Missing;

    if (value.len == 0) return error.Missing;

    const dash = std.mem.findScalar(u8, value, '-');

    const pre = if (dash) |at| value[at + 1 ..] else null;

    if (pre) |label| {
        if (label.len == 0) return error.Garbled;

        for (label) |char| {
            if (!std.ascii.isAlphanumeric(char)) return error.Garbled;
        }
    }

    const numeric = value[0 .. dash orelse value.len];

    var parts = std.mem.splitScalar(u8, numeric, '.');

    var numbers: [3]u32 = undefined;

    for (&numbers) |*number| {
        const part = parts.next() orelse return error.Garbled;

        number.* = std.fmt.parseUnsigned(u32, part, 10) catch
            return error.Garbled;
    }

    if (parts.next() != null) return error.Garbled;

    return .{
        .major = numbers[0],
        .minor = numbers[1],
        .build = numbers[2],
        .pre = pre,
    };
}

/// Opens the NDK at `root` for the target `triple`. It requires a release
/// of the profile's major revision, and the major `guard_major` of
/// -Dguard-ndk-major when it is set. Every configure-time read of the root
/// is registered with the configuration cache.
pub fn open(
    b: *std.Build,
    root: []const u8,
    triple: []const u8,
    guard_major: ?u32,
) Opened {
    if (root.len == 0) {
        return .{ .rejected = "-Dndk is empty; pass the absolute NDK root" };
    }

    if (!std.fs.path.isAbsolute(root)) {
        return .{ .rejected = b.fmt(
            "-Dndk={s} is not absolute; pass the absolute NDK root",
            .{root},
        ) };
    }

    const host_os = b.graph.host.result.os.tag;

    const host = hostTag(host_os) orelse return .{ .rejected = b.fmt(
        "the NDK has no prebuilt sysroot for the host OS {t}",
        .{host_os},
    ) };

    const properties = b.pathJoin(&.{ root, "source.properties" });

    trackContents(b, properties);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        properties,
        b.graph.arena,
        .limited(64 * 1024),
    ) catch |err| return .{ .rejected = switch (err) {
        error.FileNotFound => b.fmt(
            "-Dndk={s} is not an NDK root: {s} does not exist",
            .{ root, properties },
        ),
        else => b.fmt(
            "-Dndk={s}: cannot read {s}: {t}",
            .{ root, properties, err },
        ),
    } };

    const text = revisionText(bytes) orelse "";

    const revision = parseRevision(bytes) catch |err| return .{
        .rejected = b.fmt(
            "-Dndk={s}: Pkg.Revision in {s} is {t}: '{s}'",
            .{ root, properties, err, text },
        ),
    };

    if (revision.pre != null) {
        return .{ .rejected = b.fmt(
            "-Dndk={s} is the NDK prerelease {s}; this build requires a " ++
                "release of major {d}",
            .{ root, text, profile.ndk_major },
        ) };
    }

    if (profile.unmetNdkMajor(revision.major, guard_major)) |major| {
        return .{ .rejected = b.fmt(
            "-Dndk={s} is NDK {s}; this build requires major {d}",
            .{ root, text, major },
        ) };
    }

    const sysroot = b.pathJoin(&.{
        root, "toolchains", "llvm", "prebuilt", host, "sysroot",
    });

    const include_dirs: [2][]const u8 = .{
        b.pathJoin(&.{ sysroot, "usr", "include" }),
        b.pathJoin(&.{ sysroot, "usr", "include", triple }),
    };

    for (include_dirs) |dir| {
        trackPresence(b, dir);

        std.Io.Dir.cwd().access(b.graph.io, dir, .{}) catch |err| {
            return .{ .rejected = b.fmt(
                "-Dndk={s}: missing system include directory {s}: {t}",
                .{ root, dir, err },
            ) };
        };
    }

    return .{ .ok = .{
        .path = root,
        .revision = revision,
        .include_dirs = include_dirs,
    } };
}

/// Registers the contents of the file at the absolute `path`.
///
/// Zig 0.17.0 fails the whole configuration with an opaque
/// FileSystemFailure when a tracked file does not exist, so an absent
/// file is registered through its presence instead.
fn trackContents(b: *std.Build, path: []const u8) void {
    if (exists(b, path)) {
        b.dependOnFileContents(b.graph.cwdRelativePath(path));
    } else {
        trackPresence(b, path);
    }
}

/// Registers whether the absolute `path` exists, through the entries of
/// its nearest existing ancestor directory: the appearance or removal of
/// a component changes those entries.
fn trackPresence(b: *std.Build, path: []const u8) void {
    var ancestor = std.fs.path.dirname(path);

    while (ancestor) |dir| : (ancestor = std.fs.path.dirname(dir)) {
        if (!exists(b, dir)) continue;

        b.dependOnDirectoryContents(b.graph.cwdRelativePath(dir));

        return;
    }
}

fn exists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;

    return true;
}

const testing = std.testing;

test "ndk revision 30 parses" {
    const revision = try parseRevision(
        \\Pkg.Desc = Android NDK
        \\Pkg.Revision = 30.0.16248370
        \\Pkg.BaseRevision = 30.0.16248370
        \\
    );

    try testing.expectEqual(Revision{
        .major = 30,
        .minor = 0,
        .build = 16248370,
    }, revision);
}

test "a prerelease revision parses with its label" {
    const revision = try parseRevision("Pkg.Revision = 30.0.16248370-beta1\n");

    try testing.expectEqual(@as(u32, 30), revision.major);
    try testing.expectEqual(@as(u32, 16248370), revision.build);
    try testing.expectEqualStrings("beta1", revision.pre.?);
}

test "a revision with CRLF line ends and spaces parses" {
    const revision = try parseRevision(
        "Pkg.Desc = Android NDK\r\n  Pkg.Revision\t=  29.0.14206865 \r\n",
    );

    try testing.expectEqual(@as(u32, 29), revision.major);
}

test "an absent, empty, or garbled revision fails with its own error" {
    const cases = [_]struct { ParseRevisionError, []const u8 }{
        .{ error.Missing, "Pkg.Desc = Android NDK\n" },
        .{ error.Missing, "Pkg.Revision =\n" },
        .{ error.Garbled, "Pkg.Revision = abc\n" },
        .{ error.Garbled, "Pkg.Revision = 30.0\n" },
        .{ error.Garbled, "Pkg.Revision = 30.0.1.2\n" },
        .{ error.Garbled, "Pkg.Revision = 30.-1.2\n" },
        .{ error.Garbled, "Pkg.Revision = 30.0.1-\n" },
        .{ error.Garbled, "Pkg.Revision = 30.0.1-beta 1\n" },
        .{ error.Garbled, "Pkg.Revision = 30.0.1-rc-1\n" },
        .{ error.Garbled, "Pkg.Revision = 30.0-beta1\n" },
    };

    for (cases) |case| {
        try testing.expectError(case[0], parseRevision(case[1]));
    }
}

test "host tags cover macOS and Linux only" {
    try testing.expectEqualStrings("darwin-x86_64", hostTag(.macos).?);
    try testing.expectEqualStrings("linux-x86_64", hostTag(.linux).?);
    try testing.expect(hostTag(.windows) == null);
}
