//! The composition root of San's build.
//!
//! Every option is declared before any package request, so help, clean,
//! and the host tests need neither -Dabi, -Doptimize, -Dndk, nor a
//! fetched package. A missing or rejected input fails the steps that
//! need it through a Fail step that names the input, before any target
//! compilation. An ambient input of the environment fails the whole
//! configuration.

const std = @import("std");
const builtin = @import("builtin");
const ambient = @import("src/build/ambient.zig");
const header = @import("src/build/header.zig");
const ndk = @import("src/build/ndk.zig");
const packages = @import("src/build/packages.zig");
const profile = @import("src/build/profile.zig");

/// The host test roots that need no package.
const host_test_roots = [_][]const u8{
    "src/build/profile.zig",
    "src/build/ambient.zig",
    "src/build/ndk.zig",
    "src/build/table.zig",
    "src/build/clean.zig",
    "src/build/verify_store.zig",
};

/// The root of the engine module, which also holds its host tests.
const engine_root = "src/engine/Engine.zig";

/// The modes of the engine's host tests: Debug, and the safe mode that
/// the core keeps in published builds.
const engine_test_modes = [_]std.lang.Optimize{ .debug, .safe };

/// The output layout under the absolute San root. Every generated path
/// lies under build/.
const Layout = struct {
    root: []const u8,
    build: []const u8,
    local_cache: []const u8,
    store: []const u8,
    global_cache: []const u8,
    work: []const u8,
    reports: []const u8,

    fn init(b: *std.Build, root: []const u8) Layout {
        return .{
            .root = root,
            .build = b.pathJoin(&.{ root, "build" }),
            .local_cache = b.pathJoin(&.{ root, "build", "cache", "zig" }),
            .store = b.pathJoin(&.{ root, "build", "cache", "packages" }),
            .global_cache = b.pathJoin(&.{
                root, "build", "cache", "zig-global",
            }),
            .work = b.pathJoin(&.{ root, "build", "work" }),
            .reports = b.pathJoin(&.{ root, "build", "reports" }),
        };
    }

    /// Returns the explicit fetch, the one invocation that uses the
    /// network.
    fn fetchCommand(layout: Layout, b: *std.Build) []const u8 {
        return b.fmt(
            "ZIG_GLOBAL_CACHE_DIR={s} zig build --fetch=all " ++
                "--build-file {s}/build.zig --cache-dir {s} --pkg-dir {s}",
            .{
                layout.global_cache,
                layout.root,
                layout.local_cache,
                layout.store,
            },
        );
    }
};

/// The selection of an Android build.
const Selection = struct {
    abi: ?profile.Abi,
    optimize: ?std.lang.Optimize,
    ndk: ?[]const u8,
    /// The NDK major of -Dguard-ndk-major, which only adds a failure.
    guard_ndk_major: ?u32,
};

pub fn build(b: *std.Build) void {
    // The configure logic reads the environment and the package store,
    // which the configuration cache cannot track. Poisoning the cache
    // runs the configuration in every invocation, so no cached
    // configuration accepts an ambient input or a stale availability.
    b.graph.poisonCache();

    const layout: Layout = .init(b, rootPath(b));

    refuseAmbientInputs(b, layout);

    const abi = b.option(
        profile.Abi,
        "abi",
        "Android ABI of check-header and check-engine: " ++ profile.abi_names,
    );

    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Optimization mode of check-header and check-engine: " ++
            profile.optimize_names,
    );

    const ndk_root = b.option(
        []const u8,
        "ndk",
        "Absolute NDK root of check-header; no environment fallback",
    );

    const guard_zig_minor = b.option(
        u32,
        "guard-zig-minor",
        "Verification only: also require this Zig minor; never admits " ++
            "another line",
    );

    const guard_ndk_major = b.option(
        u32,
        "guard-ndk-major",
        "Verification only: also require this NDK major; never admits " ++
            "another major",
    );

    const test_step = b.step("test", "Run the host tests that need no package");

    const test_header = b.step(
        "test-header",
        "Check the host translation of the Bindings header against abi.tsv",
    );

    const check_header = b.step(
        "check-header",
        "Assert the translated header layout in an Android object for -Dabi",
    );

    const check_engine = b.step(
        "check-engine",
        "Compile the engine module as an Android object without libc " ++
            "for -Dabi",
    );

    const clean_step = b.step("clean", "Remove build/work and build/reports");

    const verify_store = b.step(
        "verify-store",
        "Compare a fresh fetch with the network denied to the package store",
    );

    const version = builtin.zig_version;

    if (profile.unmetZigMinor(version, guard_zig_minor)) |minor| {
        failSteps(b, &.{
            b.getInstallStep(),
            test_step,
            test_header,
            check_header,
            check_engine,
            clean_step,
            verify_store,
        }, b.fmt("a Zig 0.{d}.x release required; found {f}", .{
            minor,
            version,
        }));

        return;
    }

    addHostTests(b, test_step);
    addClean(b, clean_step, layout);
    addVerifyStore(b, verify_store, layout);
    addHeaderTest(b, test_header, layout);

    const selection: Selection = .{
        .abi = abi,
        .optimize = optimize,
        .ndk = ndk_root,
        .guard_ndk_major = guard_ndk_major,
    };

    addHeaderCheck(b, check_header, layout, selection);
    addEngineCheck(b, check_engine, selection);
}

/// Returns the absolute San root. A supported invocation passes
/// --build-file with an absolute path, and Zig resolves a build root
/// that it finds from the working directory.
fn rootPath(b: *std.Build) []const u8 {
    const root = b.root.toString(b.graph.arena) catch @panic("OOM");

    if (!std.fs.path.isAbsolute(root)) {
        std.process.fatal("the build root {s} is not absolute", .{root});
    }

    return root;
}

/// Ends the configuration when the environment carries an ambient
/// input, with one line for each.
fn refuseAmbientInputs(b: *std.Build, layout: Layout) void {
    const refusals = ambient.check(
        b.graph.arena,
        &b.graph.environ_map,
        layout.global_cache,
    ) catch @panic("OOM");

    if (refusals.len == 0) return;

    var message: std.Io.Writer.Allocating = .init(b.graph.arena);

    for (refusals) |refusal| {
        refusal.write(&message.writer, layout.global_cache) catch
            @panic("OOM");
    }

    std.process.fatal("San refuses the ambient inputs of this " ++
        "invocation:\n{s}", .{message.written()});
}

fn failSteps(
    b: *std.Build,
    steps: []const *std.Build.Step,
    message: []const u8,
) void {
    const fail = b.addFail(message);

    for (steps) |step| step.dependOn(&fail.step);
}

/// Fails `step` when the store lacks a package of the translation, and
/// reports whether it did.
fn failMissingPackage(
    b: *std.Build,
    step: *std.Build.Step,
    layout: Layout,
) bool {
    const name = packages.firstMissing(b, &packages.translation) orelse
        return false;

    failSteps(b, &.{step}, b.fmt(
        "package {s} is not in the store {s}; run the explicit fetch: {s}",
        .{ name, layout.store, layout.fetchCommand(b) },
    ));

    return true;
}

fn addHostTests(b: *std.Build, step: *std.Build.Step) void {
    // std.testing.tmpDir writes under <cwd>/.zig-cache, so the tests run
    // in a temporary directory of the local cache, never in the caller's
    // working directory or in a cached output. Its path differs in every
    // invocation, so the test runs never come from the cache. Zig 0.17.0
    // exits a successful build before it awaits the removal of temporary
    // directories, so one can stay behind in build/cache/zig/tmp/.
    const scratch = b.tmpPath();

    const bindings = header.bindingsModule(b);

    for (host_test_roots) |root| {
        const tests = b.addTest(.{
            .name = std.fs.path.stem(root),
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = b.graph.host,
                .imports = &.{.{ .name = "bindings", .module = bindings }},
            }),
        });

        const run = b.addRunArtifact(tests);

        run.setCwd(scratch);
        step.dependOn(&run.step);
    }

    for (engine_test_modes) |optimize| {
        const tests = b.addTest(.{
            .name = b.fmt("engine-{t}", .{optimize}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(engine_root),
                .target = b.graph.host,
                .optimize = optimize,
                // The tests run the system backing on the host libc.
                .link_libc = true,
            }),
        });

        const run = b.addRunArtifact(tests);

        run.setCwd(scratch);
        step.dependOn(&run.step);
    }
}

fn addClean(b: *std.Build, step: *std.Build.Step, layout: Layout) void {
    const tool = b.addExecutable(.{
        .name = "clean",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/clean.zig"),
            .target = b.graph.host,
        }),
    });

    const run = b.addRunArtifact(tool);

    run.addArgs(&.{ layout.build, layout.work, layout.reports });
    run.has_side_effects = true;
    step.dependOn(&run.step);
}

/// Adds the store verification: the explicit fetch into a fresh store
/// with the network denied, then a comparison with the store. The
/// tool empties its work directory on every run, because Zig reuses the
/// output directory of a Run step across runs.
fn addVerifyStore(b: *std.Build, step: *std.Build.Step, layout: Layout) void {
    if (b.graph.host.result.os.tag != .macos) {
        return failSteps(b, &.{step}, "verify-store denies the network " ++
            "through /usr/bin/sandbox-exec, so it runs only on macOS");
    }

    if (failMissingPackage(b, step, layout)) return;

    const build_file = b.pathJoin(&.{ layout.root, "build.zig" });

    const tool = b.addExecutable(.{
        .name = "verify-store",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/verify_store.zig"),
            .target = b.graph.host,
        }),
    });

    const run = b.addRunArtifact(tool);

    run.addArg(layout.store);
    _ = run.addOutputDirectoryArg2("work", .{ .make_absolute = true });
    run.addArgs(&.{ b.graph.zig_exe, build_file });
    run.has_side_effects = true;
    step.dependOn(&run.step);
}

fn addHeaderTest(b: *std.Build, step: *std.Build.Step, layout: Layout) void {
    if (failMissingPackage(b, step, layout)) return;

    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;

    const target = b.resolveTargetQuery(
        profile.hostQuery(b.graph.host.result),
    );

    const translation = header.translate(
        b,
        translate_c.Translator,
        b.dependency("translate_c", .{}),
        target,
        .host,
    );

    const tests = b.addTest(.{
        .name = "header-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/header_test.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "san", .module = translation.san },
                .{ .name = "system", .module = translation.system },
                .{ .name = "bindings", .module = header.bindingsModule(b) },
                .{ .name = "table", .module = tableModule(b) },
            },
        }),
    });

    step.dependOn(&b.addRunArtifact(tests).step);
}

/// An Android ABI and an optimization mode that the profile permits.
const Android = struct {
    abi: profile.Abi,
    optimize: std.lang.Optimize,
};

/// The Android ABI and mode of a selection, or the message that names its
/// missing or unsupported input.
const Selected = union(enum) {
    ok: Android,
    rejected: []const u8,
};

/// Checks the ABI and the mode of `selection` against the profile.
fn selectAndroid(b: *std.Build, selection: Selection) Selected {
    const abi = selection.abi orelse return .{
        .rejected = "missing -Dabi; choose one of: " ++ profile.abi_names,
    };

    const optimize = selection.optimize orelse return .{
        .rejected = "missing -Doptimize; choose one of: " ++
            profile.optimize_names,
    };

    if (!profile.combinationSupported(abi, optimize)) return .{
        .rejected = b.fmt(
            "unsupported combination -Dabi={t} -Doptimize={t}; " ++
                "supported: {{{s}}} x {{{s}}}",
            .{ abi, optimize, profile.abi_names, profile.optimize_names },
        ),
    };

    return .{ .ok = .{ .abi = abi, .optimize = optimize } };
}

fn addHeaderCheck(
    b: *std.Build,
    step: *std.Build.Step,
    layout: Layout,
    selection: Selection,
) void {
    const android = switch (selectAndroid(b, selection)) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    const abi = android.abi;
    const optimize = android.optimize;

    const ndk_root = selection.ndk orelse return failSteps(
        b,
        &.{step},
        "missing -Dndk; pass the absolute NDK root",
    );

    const opened = ndk.open(
        b,
        ndk_root,
        abi.triple(),
        selection.guard_ndk_major,
    );

    const found = switch (opened) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    if (failMissingPackage(b, step, layout)) return;

    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;

    const target = b.resolveTargetQuery(abi.targetQuery());

    const translation = header.translate(
        b,
        translate_c.Translator,
        b.dependency("translate_c", .{}),
        target,
        .{ .android = .{
            .api_level = profile.api_level,
            .include_dirs = found.include_dirs,
        } },
    );

    const object = b.addObject(.{
        .name = b.fmt("header-check-{t}", .{abi}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/header_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "san", .module = translation.san },
                .{ .name = "system", .module = translation.system },
                .{ .name = "bindings", .module = header.bindingsModule(b) },
                .{ .name = "table", .module = tableModule(b) },
            },
        }),
        .use_llvm = true,
    });

    _ = object.getEmittedBin();
    step.dependOn(&object.step);
}

/// Compiles the engine module for the selected ABI as an object without
/// libc. Its root references the engine's entry points, so the compile
/// generates their code. Nothing links the object yet.
fn addEngineCheck(
    b: *std.Build,
    step: *std.Build.Step,
    selection: Selection,
) void {
    const android = switch (selectAndroid(b, selection)) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    const engine = b.createModule(.{
        .root_source_file = b.path(engine_root),
        .link_libc = false,
    });

    const object = b.addObject(.{
        .name = b.fmt("engine-check-{t}", .{android.abi}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/engine_check.zig"),
            .target = b.resolveTargetQuery(android.abi.targetQuery()),
            .optimize = android.optimize,
            .link_libc = false,
            .imports = &.{.{ .name = "engine", .module = engine }},
        }),
        .use_llvm = true,
    });

    _ = object.getEmittedBin();
    step.dependOn(&object.step);
}

fn tableModule(b: *std.Build) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/build/table.zig"),
    });
}
