//! Stage a set of inspected San artifacts with its manifest.
//!
//! Usage: manifest check <san root> <record>
//!        manifest stage <san root> <record> <sets> <builder> <version>
//!                       <zig> <ndk> <optimize> (<path> <file>)...
//!
//! <san root> is the absolute root of San's checkout. `check` runs before
//! the build of a set and writes the commit of the checkout to <record>.
//! `stage` runs after it: <sets> is the directory that holds one set per
//! San commit, <builder> is `local`, <version>, <zig>, and <ndk> are the
//! San version, the Zig version, and the NDK revision of the build, and
//! <optimize> is the mode of San's own code. Each <file> is copied to
//! <path> inside the set.
//!
//! `stage` writes the set to <sets>/<San commit>/: every file at its
//! path, and `manifest.json`, which names the San commit, the Bindings
//! commit, the builder, the toolchain, the mode, and the size and the
//! SHA-256 of every file. A consumer checks each file against it. The
//! tool builds the set in a directory beside its place and renames it
//! there, so a set is whole or absent, and a later run replaces an
//! earlier set of the same commit.
//!
//! The manifest describes a commit, so both commands refuse a checkout
//! that could differ from one. They exit 1, with a line that names the
//! reason, when:
//! - <san root> is not the root of its own Git checkout, because the
//!   commit of an enclosing checkout says nothing about San;
//! - `git status` reports a change, an untracked file, or a submodule
//!   that differs, in whatever way, from the commit;
//! - an ignored file lies among the build inputs, or the index hides a
//!   file from the status, in San or in share/bindings;
//! - share/bindings is not a checkout of its own at the commit that San
//!   records for it.
//! `stage` also exits 1 when the commit is no longer the one of <record>:
//! the checkout moved while the build ran. Git runs without the GIT_
//! variables of the environment, which could point it elsewhere.
//!
//! The tool exits 2 on a usage error and on a file that it cannot read
//! or write. The absence of Git is a failure, never a clean tree.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The largest file of a set.
const max_file_len = 1024 * 1024 * 1024;

/// The path of the Bindings checkout inside San's root.
const bindings_path = "share/bindings";

/// The tracked paths of San's root that a build reads. An ignored file
/// under one of them could change a build without changing the status.
const build_inputs = [_][]const u8{
    "src",
    "share",
    "build.zig",
    "build.zig.zon",
};

/// The listing of the ignored files of a checkout, before its paths.
const list_ignored = [_][]const u8{
    "ls-files",
    "--others",
    "--ignored",
    "--exclude-standard",
    "--",
};

/// The name of the manifest inside a set.
pub const manifest_name = "manifest.json";

/// The suffix of the directory in which a set is built.
const partial_suffix = ".partial";

/// Who built a set. Only a local build exists so far.
pub const Builder = enum { local };

/// The manifest of a set, in the shape of its JSON.
pub const Manifest = struct {
    /// The version of this shape. A reader refuses another one.
    format: u32 = 1,
    san: San,
    bindings: Bindings,
    builder: struct { kind: Builder },
    toolchain: Toolchain,
    components: []const Component,
    files: []const File,

    pub const San = struct {
        version: []const u8,
        /// The commit of San's checkout, as 40 hexadecimal digits.
        commit: []const u8,
    };

    pub const Bindings = struct {
        /// The commit that San records for share/bindings.
        commit: []const u8,
    };

    pub const Toolchain = struct {
        zig: []const u8,
        ndk: []const u8,
    };

    /// A separately compiled part of the library with its mode.
    pub const Component = struct {
        name: []const u8,
        optimize: []const u8,
    };

    pub const File = struct {
        /// The path inside the set, with `/` between its segments.
        path: []const u8,
        size: u64,
        /// The SHA-256 of the file, as 64 lowercase hexadecimal digits.
        sha256: []const u8,
    };

    /// Writes the manifest as indented JSON with a final newline.
    pub fn write(manifest: Manifest, out: *Io.Writer) Io.Writer.Error!void {
        try out.print("{f}\n", .{
            std.json.fmt(manifest, .{ .whitespace = .indent_2 }),
        });
    }
};

/// Returns the SHA-256 of `bytes` as 64 lowercase hexadecimal digits.
pub fn sha256Hex(bytes: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;

    Sha256.hash(bytes, &digest, .{});

    return std.fmt.bytesToHex(digest, .lower);
}

/// Reports whether `path` names a file inside a set: relative, with `/`
/// between segments that are neither empty, `.`, nor `..`, and not the
/// manifest itself.
pub fn isSetPath(path: []const u8) bool {
    if (path.len == 0 or std.mem.eql(u8, path, manifest_name)) return false;

    var segments = std.mem.splitScalar(u8, path, '/');

    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.mem.findScalar(u8, segment, '\\') != null) return false;
    }

    return true;
}

/// Reports whether `text` is a Git commit name: 40 hexadecimal digits.
pub fn isCommit(text: []const u8) bool {
    if (text.len != 40) return false;

    for (text) |char| {
        if (!std.ascii.isHex(char)) return false;
    }

    return true;
}

/// Returns the first line of `listing`, the output of `git ls-files -v`,
/// whose file the index hides from the status, or null when it hides
/// none. Each line is a tag, a space, and a path. A lowercase tag marks a
/// file that Git assumes unchanged, and `S` one that it skips in the
/// worktree; an edit of either leaves the status empty.
pub fn hiddenEntry(listing: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, listing, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.ascii.isLower(line[0]) or line[0] == 'S') return line;
    }

    return null;
}

/// A file to stage: its path inside the set and where the build left it.
const Source = struct {
    path: []const u8,
    file: []const u8,
};

/// The arguments of `stage`.
const Stage = struct {
    root: []const u8,
    record: []const u8,
    sets: []const u8,
    builder: Builder,
    version: []const u8,
    zig: []const u8,
    ndk: []const u8,
    optimize: []const u8,
    sources: []const Source,
};

const Command = union(enum) {
    check: struct {
        root: []const u8,
        record: []const u8,
    },
    stage: Stage,
};

fn parseArguments(
    arena: Allocator,
    args: []const [:0]const u8,
) Allocator.Error!?Command {
    if (args.len < 4 or !std.fs.path.isAbsolute(args[2])) return null;

    if (std.mem.eql(u8, args[1], "check")) {
        if (args.len != 4) return null;

        return .{ .check = .{ .root = args[2], .record = args[3] } };
    }

    if (!std.mem.eql(u8, args[1], "stage")) return null;

    const fixed = 10;

    if (args.len <= fixed or (args.len - fixed) % 2 != 0) return null;

    const sources = try arena.alloc(Source, (args.len - fixed) / 2);

    for (sources, 0..) |*source, index| {
        source.* = .{
            .path = args[fixed + 2 * index],
            .file = args[fixed + 2 * index + 1],
        };

        if (!isSetPath(source.path)) return null;

        for (sources[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.path, source.path)) return null;
        }
    }

    return .{ .stage = .{
        .root = args[2],
        .record = args[3],
        .sets = args[4],
        .builder = std.meta.stringToEnum(Builder, args[5]) orelse return null,
        .version = args[6],
        .zig = args[7],
        .ndk = args[8],
        .optimize = args[9],
        .sources = sources,
    } };
}

const usage =
    \\usage: manifest check <san root> <record>
    \\       manifest stage <san root> <record> <sets> <builder> <version>
    \\                      <zig> <ndk> <optimize> (<path> <file>)...
    \\  <san root>: the absolute root of San's checkout
    \\  <builder>: local
    \\  <path>: a relative path inside the set, each one once
    \\
;

/// Ends the tool with exit 1 and the reason that the checkout is refused.
fn refuse(comptime template: []const u8, args: anytype) noreturn {
    std.debug.print("manifest: " ++ template ++ "\n", args);

    std.process.exit(1);
}

/// Ends the tool with exit 2 and the file that it cannot read or write.
fn fail(comptime template: []const u8, args: anytype) noreturn {
    std.debug.print("manifest: " ++ template ++ "\n", args);

    std.process.exit(2);
}

/// Git, run without the GIT_ variables of the tool's environment: they
/// can name another repository, index, or configuration.
const Git = struct {
    io: Io,
    arena: Allocator,
    environ: Environ.Map,

    fn init(io: Io, arena: Allocator, inherited: *const Environ.Map) !Git {
        var environ = try inherited.clone(arena);

        // The keys of a map move when one is removed, so the loop takes
        // them from a copy.
        const names = try arena.dupe([]const u8, environ.keys());

        for (names) |name| {
            if (std.mem.startsWith(u8, name, "GIT_")) {
                _ = environ.orderedRemove(name);
            }
        }

        return .{ .io = io, .arena = arena, .environ = environ };
    }

    /// Runs git in `directory` and returns its output without the final
    /// newline. A git that cannot start, or that fails, ends the tool: a
    /// checkout that git cannot describe is never clean.
    fn run(
        git: *const Git,
        directory: []const u8,
        args: []const []const u8,
    ) ![]const u8 {
        const argv = try std.mem.concat(git.arena, []const u8, &.{
            &.{"git"},
            args,
        });

        const result = std.process.run(git.arena, git.io, .{
            .argv = argv,
            .cwd = .{ .path = directory },
            .environ_map = &git.environ,
        }) catch |err| {
            refuse("cannot run git in {s}: {t}", .{ directory, err });
        };

        if (!result.term.success()) {
            refuse("git {s} in {s} {f}: {s}", .{
                args[0],
                directory,
                result.term,
                std.mem.trimEnd(u8, result.stderr, "\n"),
            });
        }

        return std.mem.trimEnd(u8, result.stdout, "\n");
    }

    /// Returns the real path of the root of the checkout that holds
    /// `directory`.
    fn topLevel(git: *const Git, directory: []const u8) ![]const u8 {
        const top = try git.run(directory, &.{
            "rev-parse",
            "--show-toplevel",
        });

        return realPath(git.io, git.arena, top);
    }

    /// Ends the tool when the checkout at `root` holds an ignored file
    /// under `paths`, or everywhere when `paths` is empty, or when its
    /// index hides a file from the status.
    fn refuseHidden(
        git: *const Git,
        root: []const u8,
        paths: []const []const u8,
    ) !void {
        const ignored = try git.run(root, try std.mem.concat(
            git.arena,
            []const u8,
            &.{ &list_ignored, paths },
        ));

        if (ignored.len != 0) {
            refuse("{s} holds ignored files among the inputs of a build, " ++
                "which no commit names; remove:\n{s}", .{ root, ignored });
        }

        const listing = try git.run(root, &.{ "ls-files", "-v" });

        if (hiddenEntry(listing)) |line| {
            refuse("the index of {s} hides a file from the status, so an " ++
                "edit of it would pass unseen: {s}", .{ root, line });
        }
    }
};

/// Returns the real path of the absolute `path`, or ends the tool.
fn realPath(io: Io, arena: Allocator, path: []const u8) []const u8 {
    return Io.Dir.realPathFileAbsoluteAlloc(io, path, arena) catch |err|
        fail("cannot resolve {s}: {t}", .{ path, err });
}

/// The commits of a clean checkout.
const Tree = struct {
    commit: []const u8,
    bindings: []const u8,
};

/// Returns the commits of the clean checkout at `root`, or ends the tool
/// with the reason that the checkout is refused.
fn cleanTree(git: *const Git, root: []const u8) !Tree {
    const real_root = realPath(git.io, git.arena, root);

    const top = try git.topLevel(root);

    if (!std.mem.eql(u8, real_root, top)) {
        refuse("{s} is not the root of its Git checkout, which is {s}; a " ++
            "manifest names the commit of San's own checkout", .{ root, top });
    }

    // The configuration can hide untracked files and the changes of a
    // submodule from a plain status, so the status names both in full.
    const status = try git.run(root, &.{
        "status",
        "--porcelain",
        "--untracked-files=all",
        "--ignore-submodules=none",
    });

    if (status.len != 0) {
        refuse("the tree differs from its commit, so no manifest can name " ++
            "it; commit or remove:\n{s}", .{status});
    }

    try git.refuseHidden(root, &build_inputs);

    const commit = try git.run(root, &.{ "rev-parse", "--verify", "HEAD" });

    const recorded = try git.run(root, &.{
        "rev-parse",
        "--verify",
        "HEAD:" ++ bindings_path,
    });

    const bindings_root = try std.fs.path.join(git.arena, &.{
        root,
        bindings_path,
    });

    // In a directory that is no checkout of its own, git answers for the
    // checkout around it, which here is San's.
    const bindings_top = try git.topLevel(bindings_root);

    const real_bindings = realPath(git.io, git.arena, bindings_root);

    if (!std.mem.eql(u8, bindings_top, real_bindings)) {
        refuse("{s} is not a checkout of its own; initialize the submodule", .{
            bindings_path,
        });
    }

    const checked_out = try git.run(bindings_root, &.{
        "rev-parse",
        "--verify",
        "HEAD",
    });

    if (!std.mem.eql(u8, recorded, checked_out)) {
        refuse("{s} is at {s}, and San records {s} for it", .{
            bindings_path,
            checked_out,
            recorded,
        });
    }

    try git.refuseHidden(bindings_root, &.{});

    if (!isCommit(commit) or !isCommit(recorded)) {
        refuse("git named the commits {s} and {s}, which are not 40 " ++
            "hexadecimal digits", .{ commit, recorded });
    }

    return .{ .commit = commit, .bindings = recorded };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const command = try parseArguments(arena, args) orelse {
        std.debug.print(usage, .{});

        std.process.exit(2);
    };

    const git: Git = try .init(io, arena, init.environ_map);

    switch (command) {
        .check => |check| {
            const tree = try cleanTree(&git, check.root);

            writeFile(io, check.record, tree.commit);
        },
        .stage => |arguments| try stage(&git, arguments),
    }
}

/// Stages the set of `arguments`, or ends the tool.
fn stage(git: *const Git, arguments: Stage) !void {
    const io = git.io;
    const arena = git.arena;
    const cwd = Io.Dir.cwd();

    const tree = try cleanTree(git, arguments.root);

    const checked = cwd.readFileAlloc(
        io,
        arguments.record,
        arena,
        .limited(64),
    ) catch |err| fail("cannot read {s}: {t}", .{ arguments.record, err });

    if (!std.mem.eql(u8, checked, tree.commit)) {
        refuse("the checkout was at {s} before the build and is at {s} " ++
            "now, so the build describes neither; run the build again", .{
            checked,
            tree.commit,
        });
    }

    const set = try std.fs.path.join(arena, &.{ arguments.sets, tree.commit });

    const partial = try std.mem.concat(arena, u8, &.{ set, partial_suffix });

    // An interrupted run can leave its directory behind.
    cwd.deleteTree(io, partial) catch |err|
        fail("cannot remove {s}: {t}", .{ partial, err });

    const files = try arena.alloc(Manifest.File, arguments.sources.len);

    for (arguments.sources, files) |source, *file| {
        const bytes = cwd.readFileAlloc(
            io,
            source.file,
            arena,
            .limited(max_file_len),
        ) catch |err| fail("cannot read {s}: {t}", .{ source.file, err });

        writeFile(
            io,
            try std.fs.path.join(arena, &.{ partial, source.path }),
            bytes,
        );

        file.* = .{
            .path = source.path,
            .size = bytes.len,
            .sha256 = try arena.dupe(u8, &sha256Hex(bytes)),
        };
    }

    const manifest: Manifest = .{
        .san = .{ .version = arguments.version, .commit = tree.commit },
        .bindings = .{ .commit = tree.bindings },
        .builder = .{ .kind = arguments.builder },
        .toolchain = .{ .zig = arguments.zig, .ndk = arguments.ndk },
        .components = &.{.{ .name = "san", .optimize = arguments.optimize }},
        .files = files,
    };

    var text: Io.Writer.Allocating = .init(arena);

    try manifest.write(&text.writer);

    writeFile(
        io,
        try std.fs.path.join(arena, &.{ partial, manifest_name }),
        text.written(),
    );

    // The whole set takes its place at once. A reader that arrives
    // between the two steps finds no set, never a mixed one.
    cwd.deleteTree(io, set) catch |err|
        fail("cannot remove {s}: {t}", .{ set, err });

    cwd.rename(partial, cwd, set, io) catch |err|
        fail("cannot rename {s} to {s}: {t}", .{ partial, set, err });

    const summary = try std.fmt.allocPrint(
        arena,
        "manifest: staged {d} files of {s} in {s}\n",
        .{ files.len, tree.commit, set },
    );

    try Io.File.stdout().writeStreamingAll(io, summary);
}

/// Writes `bytes` to `path`, creating its directory, or ends the tool.
fn writeFile(io: Io, path: []const u8, bytes: []const u8) void {
    const cwd = Io.Dir.cwd();

    if (std.fs.path.dirname(path)) |directory| {
        cwd.createDirPath(io, directory) catch |err|
            fail("cannot create {s}: {t}", .{ directory, err });
    }

    cwd.writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err|
        fail("cannot write {s}: {t}", .{ path, err });
}

const testing = std.testing;

test "the SHA-256 of a file is 64 lowercase hexadecimal digits" {
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &sha256Hex(""),
    );

    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &sha256Hex("abc"),
    );
}

test "a manifest is indented JSON with every field" {
    const commit = "0123456789abcdef0123456789abcdef01234567";
    const bindings = "89abcdef0123456789abcdef0123456789abcdef";

    const manifest: Manifest = .{
        .san = .{ .version = "0.0.0-dev.0", .commit = commit },
        .bindings = .{ .commit = bindings },
        .builder = .{ .kind = .local },
        .toolchain = .{ .zig = "0.17.1", .ndk = "30.0.1" },
        .components = &.{.{ .name = "san", .optimize = "safe" }},
        .files = &.{.{
            .path = "arm64-v8a/libsan.so",
            .size = 3,
            .sha256 = &sha256Hex("abc"),
        }},
    };

    var text: Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();

    try manifest.write(&text.writer);

    try testing.expectEqualStrings(
        \\{
        \\  "format": 1,
        \\  "san": {
        \\    "version": "0.0.0-dev.0",
        \\    "commit": "0123456789abcdef0123456789abcdef01234567"
        \\  },
        \\  "bindings": {
        \\    "commit": "89abcdef0123456789abcdef0123456789abcdef"
        \\  },
        \\  "builder": {
        \\    "kind": "local"
        \\  },
        \\  "toolchain": {
        \\    "zig": "0.17.1",
        \\    "ndk": "30.0.1"
        \\  },
        \\  "components": [
        \\    {
        \\      "name": "san",
        \\      "optimize": "safe"
        \\    }
        \\  ],
        \\  "files": [
        \\    {
        \\      "path": "arm64-v8a/libsan.so",
        \\      "size": 3,
        \\      "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        \\    }
        \\  ]
        \\}
        \\
    , text.written());
}

test "a path of a set stays inside the set" {
    const accepted = [_][]const u8{
        "libsan.so",
        "arm64-v8a/libsan.so",
        "a/b/c.txt",
        "..a/b",
    };

    const rejected = [_][]const u8{
        "",
        manifest_name,
        "/libsan.so",
        "a//b",
        "a/",
        "./a",
        "a/./b",
        "../a",
        "a/../b",
        "a\\b",
    };

    for (accepted) |path| try testing.expect(isSetPath(path));
    for (rejected) |path| try testing.expect(!isSetPath(path));
}

test "a commit name is 40 hexadecimal digits" {
    try testing.expect(isCommit("0123456789abcdef0123456789abcdef01234567"));
    try testing.expect(!isCommit("0123456789abcdef0123456789abcdef0123456"));
    try testing.expect(!isCommit("0123456789abcdef0123456789abcdef012345678"));
    try testing.expect(!isCommit("g123456789abcdef0123456789abcdef01234567"));
    try testing.expect(!isCommit(""));
}

test "the index hides a file that it assumes unchanged or skips" {
    try testing.expectEqual(null, hiddenEntry(""));
    try testing.expectEqual(null, hiddenEntry("H build.zig\nH src/san.zig"));
    try testing.expectEqual(null, hiddenEntry("H S\nH s\nM a\nC b\nR c\nK d"));

    try testing.expectEqualStrings(
        "h src/san.zig",
        hiddenEntry("H build.zig\nh src/san.zig\nH src/x.zig").?,
    );

    try testing.expectEqualStrings("S build.zig", hiddenEntry("S build.zig").?);
    try testing.expectEqualStrings("s a", hiddenEntry("H b\n\ns a").?);
    try testing.expectEqualStrings("m a", hiddenEntry("m a").?);
}

test "the arguments name a command, the build, and each file once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const check = [_][:0]const u8{ "manifest", "check", "/san", "/cache/head" };

    const checked = (try parseArguments(arena, &check)).?.check;

    try testing.expectEqualStrings("/san", checked.root);
    try testing.expectEqualStrings("/cache/head", checked.record);
    try testing.expectEqual(null, try parseArguments(arena, check[0..3]));

    const good = [_][:0]const u8{
        "manifest",         "stage",               "/san",
        "/cache/head",      "/san/sets",           "local",
        "0.0.0",            "0.17.1",              "30.0.1",
        "safe",             "arm64-v8a/libsan.so", "/cache/a.so",
        "x86_64/libsan.so", "/cache/b.so",
    };

    const arguments = (try parseArguments(arena, &good)).?.stage;

    try testing.expectEqual(.local, arguments.builder);
    try testing.expectEqualStrings("/san/sets", arguments.sets);
    try testing.expectEqualStrings("safe", arguments.optimize);
    try testing.expectEqual(2, arguments.sources.len);
    try testing.expectEqualStrings("/cache/b.so", arguments.sources[1].file);

    // No file, a path without its file, another command, a relative
    // root, another builder, a path that leaves the set, and a path
    // twice.
    try testing.expectEqual(null, try parseArguments(arena, good[0..10]));
    try testing.expectEqual(null, try parseArguments(arena, good[0..11]));

    var other = good;
    other[1] = "publish";

    try testing.expectEqual(null, try parseArguments(arena, &other));

    var relative = good;
    relative[2] = "san";

    try testing.expectEqual(null, try parseArguments(arena, &relative));

    var builder = good;
    builder[5] = "ci";

    try testing.expectEqual(null, try parseArguments(arena, &builder));

    var escaping = good;
    escaping[10] = "../libsan.so";

    try testing.expectEqual(null, try parseArguments(arena, &escaping));

    var twice = good;
    twice[12] = "arm64-v8a/libsan.so";

    try testing.expectEqual(null, try parseArguments(arena, &twice));
}
