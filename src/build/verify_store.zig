//! Verify the package store against a fresh fetch.
//!
//! Usage: verify-store <store dir> <work dir> <zig> <build file>
//!
//! Every path is absolute. Zig 0.17.0 accepts a store directory after an
//! existence check only, so an edited file, a changed mode, or an added
//! file passes every build. The tool empties <work dir>/fetch and runs
//! the explicit fetch into it with the network denied: Zig unpacks every
//! package from the global cache's p/, fails on a package missing there
//! instead of fetching it, and fails on a tarball whose content does not
//! match its hash. The tool then compares the fresh tree with the store.
//!
//! The comparison covers the entry kinds, the contents and permission
//! bits of files and directories, and symlink targets, and it never
//! follows a symlink. A file or symlink found only in the store is a
//! modification, because a fetched package holds only the files of its
//! paths filter. A directory that holds no file or symlink is no package
//! content: Zig 0.17.0's fetch of a git package leaves such directories
//! outside the paths filter, and a restore from p/ never creates them.
//! The tool prints every difference and exits 1 if there is one.
//! sandbox-exec denies the network, so the tool runs on macOS.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The sandbox profile of the fetch. It denies every outbound IP
/// connection, loopback included; it does not stop name resolution.
const network_denied =
    "(version 1)(allow default)(deny network-outbound (remote ip))";

/// Larger files are compared in pieces of this size.
const chunk_len = 64 * 1024;

/// How an entry of the store differs from the fresh fetch.
pub const Change = enum {
    only_in_store,
    only_in_fresh,
    kind,
    contents,
    mode,
    link_target,
    unsupported_kind,

    fn describe(change: Change) []const u8 {
        return switch (change) {
            .only_in_store => "only in the store",
            .only_in_fresh => "missing from the store",
            .kind => "a different kind of entry",
            .contents => "different contents",
            .mode => "different permission bits",
            .link_target => "a different symlink target",
            .unsupported_kind => "neither a file, a directory, nor a symlink",
        };
    }
};

pub const Difference = struct {
    /// The path relative to both roots.
    path: []const u8,
    change: Change,
};

/// The outcome of a comparison.
pub const Report = struct {
    differences: std.ArrayList(Difference) = .empty,
    files: usize = 0,
    directories: usize = 0,
    symlinks: usize = 0,

    fn add(
        report: *Report,
        arena: Allocator,
        path: []const u8,
        change: Change,
    ) Allocator.Error!void {
        const difference: Difference = .{ .path = path, .change = change };

        try report.differences.append(arena, difference);
    }
};

/// The failures of a comparison. The walk recurses, so its error set is
/// explicit.
pub const CompareError = Allocator.Error ||
    Io.Dir.Iterator.Error ||
    Io.Dir.StatFileError ||
    Io.Dir.OpenError ||
    Io.Dir.ReadLinkError ||
    Io.File.OpenError ||
    Io.File.LengthError ||
    Io.File.ReadPositionalError;

/// Compares the trees under `fresh` and `store` and records every
/// difference in `report`. `arena` owns the paths of the report.
pub fn compare(
    io: Io,
    arena: Allocator,
    fresh: Io.Dir,
    store: Io.Dir,
    report: *Report,
) CompareError!void {
    try compareDirectories(io, arena, fresh, store, "", report);
}

fn compareDirectories(
    io: Io,
    arena: Allocator,
    fresh: Io.Dir,
    store: Io.Dir,
    prefix: []const u8,
    report: *Report,
) CompareError!void {
    const fresh_names = try sortedNames(io, arena, fresh);

    const store_names = try sortedNames(io, arena, store);

    var fresh_index: usize = 0;
    var store_index: usize = 0;

    while (fresh_index < fresh_names.len or store_index < store_names.len) {
        const fresh_name = if (fresh_index < fresh_names.len)
            fresh_names[fresh_index]
        else
            null;

        const store_name = if (store_index < store_names.len)
            store_names[store_index]
        else
            null;

        const order = nameOrder(fresh_name, store_name);

        switch (order) {
            .lt => {
                const path = try join(arena, prefix, fresh_name.?);

                try reportOneSided(
                    io,
                    arena,
                    fresh,
                    fresh_name.?,
                    path,
                    .only_in_fresh,
                    report,
                );

                fresh_index += 1;
            },
            .gt => {
                const path = try join(arena, prefix, store_name.?);

                try reportOneSided(
                    io,
                    arena,
                    store,
                    store_name.?,
                    path,
                    .only_in_store,
                    report,
                );

                store_index += 1;
            },
            .eq => {
                try compareEntries(
                    io,
                    arena,
                    fresh,
                    store,
                    prefix,
                    fresh_name.?,
                    report,
                );

                fresh_index += 1;
                store_index += 1;
            },
        }
    }
}

/// Reports the entry `name` of `dir`, which only one tree holds, as
/// `change`. A directory reports the files and symlinks below it, so a
/// directory that holds none of them reports nothing.
fn reportOneSided(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    name: []const u8,
    path: []const u8,
    change: Change,
    report: *Report,
) CompareError!void {
    const stat = try dir.statFile(io, name, .{ .follow_symlinks = false });

    if (stat.kind != .directory) return report.add(arena, path, change);

    var child = try dir.openDir(io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer child.close(io);

    const names = try sortedNames(io, arena, child);

    for (names) |child_name| {
        const child_path = try join(arena, path, child_name);

        try reportOneSided(
            io,
            arena,
            child,
            child_name,
            child_path,
            change,
            report,
        );
    }
}

/// Orders the next names of a merge; an exhausted side sorts last.
fn nameOrder(fresh: ?[]const u8, store: ?[]const u8) std.math.Order {
    const fresh_name = fresh orelse return .gt;
    const store_name = store orelse return .lt;

    return std.mem.order(u8, fresh_name, store_name);
}

fn compareEntries(
    io: Io,
    arena: Allocator,
    fresh: Io.Dir,
    store: Io.Dir,
    prefix: []const u8,
    name: []const u8,
    report: *Report,
) CompareError!void {
    const path = try join(arena, prefix, name);

    const options: Io.Dir.StatFileOptions = .{ .follow_symlinks = false };

    const fresh_stat = try fresh.statFile(io, name, options);

    const store_stat = try store.statFile(io, name, options);

    if (fresh_stat.kind != store_stat.kind) {
        return report.add(arena, path, .kind);
    }

    switch (fresh_stat.kind) {
        .directory, .file => if (mode(fresh_stat) != mode(store_stat)) {
            try report.add(arena, path, .mode);
        },
        else => {},
    }

    switch (fresh_stat.kind) {
        .directory => {
            report.directories += 1;

            const options_dir: Io.Dir.OpenOptions = .{
                .iterate = true,
                .follow_symlinks = false,
            };

            var fresh_child = try fresh.openDir(io, name, options_dir);
            defer fresh_child.close(io);

            var store_child = try store.openDir(io, name, options_dir);
            defer store_child.close(io);

            try compareDirectories(
                io,
                arena,
                fresh_child,
                store_child,
                path,
                report,
            );
        },
        .file => {
            report.files += 1;

            if (!try sameContents(io, fresh, store, name)) {
                try report.add(arena, path, .contents);
            }
        },
        .sym_link => {
            report.symlinks += 1;

            var fresh_buffer: [std.fs.max_path_bytes]u8 = undefined;
            var store_buffer: [std.fs.max_path_bytes]u8 = undefined;

            const fresh_len = try fresh.readLink(io, name, &fresh_buffer);

            const store_len = try store.readLink(io, name, &store_buffer);

            const fresh_target = fresh_buffer[0..fresh_len];
            const store_target = store_buffer[0..store_len];

            if (!std.mem.eql(u8, fresh_target, store_target)) {
                try report.add(arena, path, .link_target);
            }
        },
        else => try report.add(arena, path, .unsupported_kind),
    }
}

fn mode(stat: Io.File.Stat) std.posix.mode_t {
    return stat.permissions.toMode() & 0o7777;
}

/// Returns the entry names of `dir` in byte order.
fn sortedNames(io: Io, arena: Allocator, dir: Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;

    var entries = dir.iterate();

    while (try entries.next(io)) |entry| {
        try names.append(arena, try arena.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, lessThan);

    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn join(arena: Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return arena.dupe(u8, name);

    return std.fs.path.join(arena, &.{ prefix, name });
}

/// Reports whether the files `name` of `fresh` and `store` hold the same
/// bytes.
fn sameContents(
    io: Io,
    fresh: Io.Dir,
    store: Io.Dir,
    name: []const u8,
) !bool {
    const fresh_file = try fresh.openFile(io, name, .{});
    defer fresh_file.close(io);

    const store_file = try store.openFile(io, name, .{});
    defer store_file.close(io);

    if (try fresh_file.length(io) != try store_file.length(io)) return false;

    var fresh_buffer: [chunk_len]u8 = undefined;
    var store_buffer: [chunk_len]u8 = undefined;
    var offset: u64 = 0;

    while (true) : (offset += chunk_len) {
        const fresh_len = try fresh_file.readPositionalAll(
            io,
            &fresh_buffer,
            offset,
        );

        const store_len = try store_file.readPositionalAll(
            io,
            &store_buffer,
            offset,
        );

        const fresh_chunk = fresh_buffer[0..fresh_len];
        const store_chunk = store_buffer[0..store_len];

        if (!std.mem.eql(u8, fresh_chunk, store_chunk)) return false;
        if (fresh_len < chunk_len) return true;
    }
}

/// The arguments of the tool, all absolute paths.
const Arguments = struct {
    store: []const u8,
    work: []const u8,
    zig: []const u8,
    build_file: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const arguments = parseArguments(args) orelse {
        std.debug.print("usage: verify-store <store dir> <work dir> <zig> " ++
            "<build file>, all absolute\n", .{});

        std.process.exit(2);
    };

    const fresh_path = try fetchFresh(io, arena, arguments);

    var fresh = try Io.Dir.openDirAbsolute(io, fresh_path, .{
        .iterate = true,
    });
    defer fresh.close(io);

    var store = Io.Dir.openDirAbsolute(io, arguments.store, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        std.debug.print("verify-store: cannot open the store {s}: {t}\n", .{
            arguments.store,
            err,
        });

        std.process.exit(1);
    };
    defer store.close(io);

    var report: Report = .{};

    try compare(io, arena, fresh, store, &report);

    for (report.differences.items) |difference| {
        std.debug.print("verify-store: {s}: {s}\n", .{
            difference.path,
            difference.change.describe(),
        });
    }

    if (report.differences.items.len != 0) {
        std.debug.print("verify-store: the store {s} differs from the fresh " ++
            "fetch in {d} entries\n", .{
            arguments.store,
            report.differences.items.len,
        });

        std.process.exit(1);
    }

    const summary = try std.fmt.allocPrint(
        arena,
        "verify-store: the store {s} equals the fresh fetch: {d} files, " ++
            "{d} directories, {d} symlinks\n",
        .{ arguments.store, report.files, report.directories, report.symlinks },
    );

    try Io.File.stdout().writeStreamingAll(io, summary);
}

fn parseArguments(args: []const [:0]const u8) ?Arguments {
    if (args.len != 5) return null;

    for (args[1..]) |arg| {
        if (!std.fs.path.isAbsolute(arg)) return null;
    }

    return .{
        .store = args[1],
        .work = args[2],
        .zig = args[3],
        .build_file = args[4],
    };
}

/// Empties `<work>/fetch`, runs the explicit fetch into it with the
/// network denied, and returns the path of the fresh store. A failed
/// fetch ends the process.
fn fetchFresh(io: Io, arena: Allocator, arguments: Arguments) ![]const u8 {
    const root = try std.fs.path.join(arena, &.{ arguments.work, "fetch" });

    try Io.Dir.cwd().deleteTree(io, root);
    try Io.Dir.cwd().createDirPath(io, root);

    const packages = try std.fs.path.join(arena, &.{ root, "packages" });

    const cache = try std.fs.path.join(arena, &.{ root, "cache" });

    var child = try std.process.spawn(io, .{ .argv = &.{
        "/usr/bin/sandbox-exec",
        "-p",
        network_denied,
        arguments.zig,
        "build",
        "--fetch=all",
        "--build-file",
        arguments.build_file,
        "--pkg-dir",
        packages,
        "--cache-dir",
        cache,
    } });
    defer child.kill(io);

    const term = try child.wait(io);

    if (!term.success()) {
        std.debug.print("verify-store: the fetch with the network denied " ++
            "{f}; p/ lacks a package or holds a tarball that does not match " ++
            "its hash, so run the explicit fetch again\n", .{term});

        std.process.exit(1);
    }

    return packages;
}

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    fresh: Io.Dir,
    store: Io.Dir,

    fn init() !Fixture {
        const io = testing.io;

        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        try tmp.dir.createDirPath(io, "fresh");
        try tmp.dir.createDirPath(io, "store");

        const fresh = try tmp.dir.openDir(io, "fresh", .{ .iterate = true });

        const store = try tmp.dir.openDir(io, "store", .{ .iterate = true });

        return .{
            .tmp = tmp,
            .arena_state = .init(testing.allocator),
            .fresh = fresh,
            .store = store,
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.fresh.close(testing.io);
        fixture.store.close(testing.io);
        fixture.arena_state.deinit();
        fixture.tmp.cleanup();
    }

    /// Writes the same package into both trees.
    fn package(fixture: *Fixture) !void {
        for ([_]Io.Dir{ fixture.fresh, fixture.store }) |root| {
            try writeFile(root, "p-1/build.zig", "pub fn build() void {}\n");
            try writeFile(root, "p-1/src/a.zig", "pub const a = 1;\n");
            try writeFile(root, "p-1/tool.sh", "#!/bin/sh\n");
            try setMode(root, "p-1/tool.sh", 0o777);
            try root.symLink(testing.io, "src/a.zig", "p-1/link", .{});
        }
    }

    fn run(fixture: *Fixture) !Report {
        var report: Report = .{};

        const arena = fixture.arena_state.allocator();

        try compare(testing.io, arena, fixture.fresh, fixture.store, &report);

        return report;
    }
};

fn writeFile(root: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |dir| {
        try root.createDirPath(testing.io, dir);
    }

    try root.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
}

fn setMode(root: Io.Dir, sub_path: []const u8, value: std.posix.mode_t) !void {
    try root.setFilePermissions(testing.io, sub_path, .fromMode(value), .{});
}

fn expectOne(report: Report, path: []const u8, change: Change) !void {
    try testing.expectEqual(1, report.differences.items.len);

    const difference = report.differences.items[0];

    try testing.expectEqualStrings(path, difference.path);
    try testing.expectEqual(change, difference.change);
}

test "equal trees have no difference" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.package();

    const report = try fixture.run();

    try testing.expectEqual(0, report.differences.items.len);
    try testing.expectEqual(3, report.files);
    try testing.expectEqual(2, report.directories);
    try testing.expectEqual(1, report.symlinks);
}

test "an edited file differs in its contents" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.package();
    try writeFile(fixture.store, "p-1/src/a.zig", "pub const a = 2;\n");

    try expectOne(try fixture.run(), "p-1/src/a.zig", .contents);
}

test "a file of equal length with other bytes differs" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    var large: [3 * chunk_len + 5]u8 = @splat('x');

    try fixture.package();
    try writeFile(fixture.fresh, "p-1/large", &large);
    large[2 * chunk_len + 1] = 'y';
    try writeFile(fixture.store, "p-1/large", &large);

    try expectOne(try fixture.run(), "p-1/large", .contents);
}

test "a changed executable bit differs in its mode" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.package();
    try setMode(fixture.store, "p-1/tool.sh", 0o644);

    try expectOne(try fixture.run(), "p-1/tool.sh", .mode);
}

test "a file only in the store is a modification" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.package();
    try writeFile(fixture.store, "p-1/extra-unlisted.txt", "extra\n");
    try writeFile(fixture.store, "q-1/build.zig", "\n");

    const report = try fixture.run();

    try testing.expectEqual(2, report.differences.items.len);

    const extra_file = report.differences.items[0];
    const extra_package = report.differences.items[1];

    try testing.expectEqualStrings("p-1/extra-unlisted.txt", extra_file.path);
    try testing.expectEqual(Change.only_in_store, extra_file.change);
    try testing.expectEqualStrings("q-1/build.zig", extra_package.path);
    try testing.expectEqual(Change.only_in_store, extra_package.change);
}

test "a directory without files only in one tree is no difference" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.package();
    try fixture.store.createDirPath(testing.io, "p-1/test/cases/include/next");
    try fixture.fresh.createDirPath(testing.io, "p-1/empty");

    const report = try fixture.run();

    try testing.expectEqual(0, report.differences.items.len);
}

test "a package missing from the store differs in each of its files" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.package();
    try fixture.store.deleteTree(testing.io, "p-1");

    const report = try fixture.run();

    const expected = [_][]const u8{
        "p-1/build.zig",
        "p-1/link",
        "p-1/src/a.zig",
        "p-1/tool.sh",
    };

    try testing.expectEqual(expected.len, report.differences.items.len);

    for (expected, report.differences.items) |path, difference| {
        try testing.expectEqualStrings(path, difference.path);
        try testing.expectEqual(Change.only_in_fresh, difference.change);
    }
}

test "a changed symlink target differs, and no symlink is followed" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.package();
    try fixture.store.deleteFile(testing.io, "p-1/link");
    try fixture.store.symLink(testing.io, "../../outside", "p-1/link", .{});

    try expectOne(try fixture.run(), "p-1/link", .link_target);
}

test "a file replaced by a directory differs in its kind" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    try fixture.package();
    try fixture.store.deleteFile(testing.io, "p-1/build.zig");
    try fixture.store.createDirPath(testing.io, "p-1/build.zig");

    try expectOne(try fixture.run(), "p-1/build.zig", .kind);
}

test "the arguments are four absolute paths" {
    const short = [_][:0]const u8{ "verify-store", "/s", "/w", "/z" };
    const relative = [_][:0]const u8{ "verify-store", "/s", "w", "/z", "/b" };
    const complete = [_][:0]const u8{ "verify-store", "/s", "/w", "/z", "/b" };

    try testing.expect(parseArguments(&short) == null);
    try testing.expect(parseArguments(&relative) == null);
    try testing.expectEqualStrings("/w", parseArguments(&complete).?.work);
}
