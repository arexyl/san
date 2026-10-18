//! Remove the generated directories of build/ and nothing else.
//!
//! Usage: clean <build dir> <target>...
//!
//! Every path is absolute. A target is a direct child of the build
//! directory other than the kept ones (cache, evidence, and artifacts),
//! and it must resolve to itself: a target that reaches another place
//! through a symlink is refused, while a symlink inside a target is
//! unlinked without being followed. Every target is judged before any is
//! removed. A refusal names the path and exits 2. An absent target is
//! success. Zig 0.17.0 has no remove-directory step, so `zig build clean`
//! runs this tool.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

/// The directories of build/ that clean preserves.
const kept_names = [_][]const u8{ "cache", "evidence", "artifacts" };

/// What clean may do with one target.
pub const Verdict = union(enum) {
    remove,
    absent,
    refuse: []const u8,
};

/// Decides what clean may do with `target`.
pub fn judge(
    io: Io,
    arena: Allocator,
    build_dir: []const u8,
    target: []const u8,
) !Verdict {
    if (!path.isAbsolute(build_dir) or !path.isAbsolute(target)) {
        return .{ .refuse = "the path is not absolute" };
    }

    if (std.mem.eql(u8, target, build_dir)) {
        return .{ .refuse = "it is the build/ root" };
    }

    const parent = path.dirname(target) orelse
        return .{ .refuse = "it is outside build/" };

    const name = path.basename(target);

    if (!std.mem.eql(u8, parent, build_dir) or name.len == 0 or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
    {
        return .{ .refuse = "it is not a direct child of build/" };
    }

    for (kept_names) |kept| {
        if (std.mem.eql(u8, name, kept)) {
            return .{ .refuse = "it is a kept directory of build/" };
        }
    }

    const cwd = Io.Dir.cwd();

    _ = cwd.statFile(io, target, .{ .follow_symlinks = false }) catch |err|
        switch (err) {
            error.FileNotFound => return .absent,
            else => |e| return e,
        };

    const build_stat = try cwd.statFile(io, build_dir, .{
        .follow_symlinks = false,
    });

    if (build_stat.kind != .directory) {
        return .{ .refuse = "build/ is not a plain directory" };
    }

    const build_real = try Io.Dir.realPathFileAbsoluteAlloc(
        io,
        build_dir,
        arena,
    );

    const target_real = Io.Dir.realPathFileAbsoluteAlloc(
        io,
        target,
        arena,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .refuse = "it is a symlink to a missing path",
        },
        else => |e| return e,
    };

    const expected = try path.join(arena, &.{ build_real, name });

    if (std.mem.eql(u8, target_real, expected)) return .remove;

    const inside = std.mem.startsWith(u8, target_real, build_real) and
        target_real.len > build_real.len and
        target_real[build_real.len] == path.sep;

    const reason = if (inside)
        try std.fmt.allocPrint(
            arena,
            "it resolves through a symlink to {s}, another path in build/",
            .{target_real},
        )
    else
        try std.fmt.allocPrint(
            arena,
            "it reaches outside build/ through a symlink to {s}",
            .{target_real},
        );

    return .{ .refuse = reason };
}

/// What clean did, or why it did nothing.
pub const Outcome = struct {
    refusals: []const []const u8,
    removed: []const []const u8,
    absent: []const []const u8,
};

/// Judges every target, then removes them only if none is refused.
pub fn clean(
    io: Io,
    arena: Allocator,
    build_dir: []const u8,
    targets: []const []const u8,
) !Outcome {
    var refusals: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var absent: std.ArrayList([]const u8) = .empty;

    const verdicts = try arena.alloc(Verdict, targets.len);

    for (targets, verdicts) |target, *verdict| {
        verdict.* = try judge(io, arena, build_dir, target);

        switch (verdict.*) {
            .refuse => |reason| try refusals.append(
                arena,
                try std.fmt.allocPrint(arena, "{s}: {s}", .{ target, reason }),
            ),
            .remove, .absent => {},
        }
    }

    if (refusals.items.len != 0) return .{
        .refusals = refusals.items,
        .removed = &.{},
        .absent = &.{},
    };

    for (targets, verdicts) |target, verdict| switch (verdict) {
        .remove => {
            try Io.Dir.cwd().deleteTree(io, target);
            try removed.append(arena, target);
        },
        .absent => try absent.append(arena, target),
        .refuse => unreachable,
    };

    return .{
        .refusals = &.{},
        .removed = removed.items,
        .absent = absent.items,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 3) {
        std.debug.print("usage: clean <build dir> <target>...\n", .{});
        std.process.exit(2);
    }

    const targets = try arena.alloc([]const u8, args.len - 2);

    for (args[2..], targets) |arg, *target| target.* = arg;

    const outcome = try clean(io, arena, args[1], targets);

    for (outcome.refusals) |refusal| {
        std.debug.print("clean: refusing {s}\n", .{refusal});
    }

    if (outcome.refusals.len != 0) std.process.exit(2);

    const stdout = Io.File.stdout();

    for (outcome.removed) |target| {
        const line = try std.fmt.allocPrint(arena, "clean: removed {s}\n", .{
            target,
        });

        try stdout.writeStreamingAll(io, line);
    }

    for (outcome.absent) |target| {
        const line = try std.fmt.allocPrint(arena, "clean: absent {s}\n", .{
            target,
        });

        try stdout.writeStreamingAll(io, line);
    }
}

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,
    build_dir: []const u8,

    fn init() !Fixture {
        var fixture: Fixture = .{
            .tmp = testing.tmpDir(.{}),
            .arena_state = .init(testing.allocator),
            .root = undefined,
            .build_dir = undefined,
        };
        errdefer fixture.deinit();

        const arena = fixture.arena_state.allocator();

        fixture.root = try fixture.tmp.dir.realPathFileAlloc(
            testing.io,
            ".",
            arena,
        );

        fixture.build_dir = try path.join(arena, &.{ fixture.root, "build" });

        return fixture;
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena_state.deinit();
        fixture.tmp.cleanup();
    }

    fn file(fixture: *Fixture, sub_path: []const u8) !void {
        const io = testing.io;

        if (path.dirname(sub_path)) |dir| {
            try fixture.tmp.dir.createDirPath(io, dir);
        }

        try fixture.tmp.dir.writeFile(io, .{
            .sub_path = sub_path,
            .data = "x",
        });
    }

    fn exists(fixture: *Fixture, sub_path: []const u8) bool {
        _ = fixture.tmp.dir.statFile(testing.io, sub_path, .{
            .follow_symlinks = false,
        }) catch return false;

        return true;
    }

    fn abs(fixture: *Fixture, sub_path: []const u8) ![]const u8 {
        return path.join(fixture.arena_state.allocator(), &.{
            fixture.root,
            sub_path,
        });
    }

    fn link(fixture: *Fixture, target: []const u8, sub_path: []const u8) !void {
        const absolute = try fixture.abs(target);

        try fixture.tmp.dir.symLink(testing.io, absolute, sub_path, .{
            .is_directory = true,
        });
    }

    fn run(fixture: *Fixture, sub_paths: []const []const u8) !Outcome {
        const arena = fixture.arena_state.allocator();

        const targets = try arena.alloc([]const u8, sub_paths.len);

        for (sub_paths, targets) |sub_path, *target| {
            target.* = try fixture.abs(sub_path);
        }

        return clean(testing.io, arena, fixture.build_dir, targets);
    }
};

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.find(u8, text, part) != null;
}

test "clean removes work and reports and keeps the rest" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.file("build/work/x/a");
    try fixture.file("build/reports/r");
    try fixture.file("build/cache/zig/keep");
    try fixture.file("build/evidence/e");
    try fixture.file("build/artifacts/a");
    try fixture.file("build/top");

    const outcome = try fixture.run(&.{ "build/work", "build/reports" });

    try testing.expectEqual(0, outcome.refusals.len);
    try testing.expectEqual(2, outcome.removed.len);
    try testing.expect(!fixture.exists("build/work"));
    try testing.expect(!fixture.exists("build/reports"));
    try testing.expect(fixture.exists("build/cache/zig/keep"));
    try testing.expect(fixture.exists("build/evidence/e"));
    try testing.expect(fixture.exists("build/artifacts/a"));
    try testing.expect(fixture.exists("build/top"));
}

test "clean treats absent targets and an absent build dir as success" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    const outcome = try fixture.run(&.{ "build/work", "build/reports" });

    try testing.expectEqual(0, outcome.refusals.len);
    try testing.expectEqual(2, outcome.absent.len);
}

test "clean refuses the root, kept directories, and outside paths" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.file("build/cache/zig/keep");
    try fixture.file("build/work/a");
    try fixture.file("other/o");

    const refused = [_][]const u8{
        "build",
        "build/cache",
        "build/evidence",
        "build/artifacts",
        "other",
        "build/work/a",
        "build/..",
    };

    for (refused) |sub_path| {
        const outcome = try fixture.run(&.{ "build/work", sub_path });

        try testing.expectEqual(1, outcome.refusals.len);
        try testing.expect(contains(outcome.refusals[0], sub_path));
        try testing.expect(fixture.exists("build/work/a"));
    }

    try testing.expect(fixture.exists("build/cache/zig/keep"));
    try testing.expect(fixture.exists("other/o"));
}

test "clean refuses a target that leaves build/ through a symlink" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.file("outside/keep");
    try fixture.file("build/cache/zig/keep");
    try fixture.link("outside", "build/work");
    try fixture.link("build/cache", "build/reports");

    const escape = try fixture.run(&.{"build/work"});

    try testing.expectEqual(1, escape.refusals.len);
    try testing.expect(contains(escape.refusals[0], "outside build/"));

    const inner = try fixture.run(&.{"build/reports"});

    try testing.expectEqual(1, inner.refusals.len);
    try testing.expect(contains(inner.refusals[0], "another path"));
    try testing.expect(fixture.exists("outside/keep"));
    try testing.expect(fixture.exists("build/cache/zig/keep"));
}

test "clean refuses every target when one is refused" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.file("outside/keep");
    try fixture.file("build/reports/r");
    try fixture.link("outside", "build/work");

    const outcome = try fixture.run(&.{ "build/reports", "build/work" });

    try testing.expectEqual(1, outcome.refusals.len);
    try testing.expectEqual(0, outcome.removed.len);
    try testing.expect(fixture.exists("build/reports/r"));
}

test "clean unlinks a symlink inside a target without following it" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.file("outside/keep");
    try fixture.tmp.dir.createDirPath(testing.io, "build/work");
    try fixture.link("outside", "build/work/escape");

    const outcome = try fixture.run(&.{"build/work"});

    try testing.expectEqual(0, outcome.refusals.len);
    try testing.expect(!fixture.exists("build/work"));
    try testing.expect(fixture.exists("outside/keep"));
}
