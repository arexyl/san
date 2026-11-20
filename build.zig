//! The composition root of San's build.
//!
//! Every option is declared before any package request, so help, clean,
//! and the host tests need neither -Dabi, -Doptimize, -Dndk, nor a
//! fetched package. -Doptimize requests the codec packages, because the
//! Android steps and the codec host tests compile them; help, clean, and
//! the host tests that need no package take no -Doptimize. A missing or
//! rejected input fails the steps that need it through a Fail step that
//! names the input, before any target compilation. An ambient input of
//! the environment fails the whole configuration.

const std = @import("std");
const builtin = @import("builtin");
const allowlist = @import("src/build/allowlist.zig");
const ambient = @import("src/build/ambient.zig");
const codecs = @import("src/build/codecs.zig");
const header = @import("src/build/header.zig");
const inspect = @import("src/build/inspect.zig");
const library = @import("src/build/library.zig");
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
    "src/build/allowlist.zig",
    "src/build/inspect.zig",
    "src/build/install_prefix.zig",
    "src/build/report.zig",
    "src/build/manifest.zig",
};

/// The root of the engine module, which also holds its host tests.
const engine_root = "src/engine/Engine.zig";

/// The modes of the host tests of the Zig core: Debug, and the safe mode
/// that the core keeps in published builds.
const engine_test_modes = [_]std.lang.Optimize{ .debug, .safe };

/// The root of the C ABI module, which also holds its host tests.
const abi_root = "src/abi/root.zig";

/// The root of libsan_canary_test.so, the device test library of the
/// stack protector, its test-only C source, and the root of its harness.
const canary_device_test_root = "src/canary/device_test.zig";
const canary_source = "src/canary/canary.c";
const canary_device_harness_root = "src/canary/device_harness.zig";

/// The root of the JNI layer, which also holds its host tests.
const jni_root = "src/jni/root.zig";

/// The root of libsan.so, the San library, and the root of the harness
/// that loads it on a device.
const san_root = "src/san.zig";

/// The name of the inspection report beside libsan.so.
const san_report_name = "libsan.report.txt";
const jni_device_harness_root = "src/jni/device_harness.zig";

/// The root of libsan_abi_test.so, the device test library of the C ABI,
/// and the root of its harness.
const abi_device_test_root = "src/abi/device_test.zig";
const abi_device_harness_root = "src/abi/device_harness.zig";

/// The root of the PNG decoder, which also holds its host tests.
const png_decoder_root = "src/codecs/png/Decoder.zig";

/// The root of libsan_png_test.so, the device test library of the PNG
/// decoder, and the root of its harness.
const png_device_test_root = "src/codecs/png/device_test.zig";
const png_device_harness_root = "src/codecs/png/device_harness.zig";

/// The root of the deliberately defective libraries of check-inspect.
const inspect_defects_root = "src/build/inspect_defects.zig";

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

/// The message of a missing -Doptimize.
const missing_optimize = "missing -Doptimize; choose one of: " ++
    profile.optimize_names;

/// The selection of an Android build.
const Selection = struct {
    abi: ?profile.Abi,
    optimize: ?std.lang.Optimize,
    ndk: ?[]const u8,
    /// The NDK major of -Dguard-ndk-major, which only adds a failure.
    guard_ndk_major: ?u32,
};

pub fn build(b: *std.Build) error{LazyDependencyNeeded}!void {
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
        "Android ABI of check-header, check-engine, check-codecs, " ++
            "check-inspect, stage-library, and stage-device: " ++
            profile.abi_names,
    );

    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Optimization mode of the Android checks and of the Zig code of " ++
            "test-codecs; requests the codec packages: " ++
            profile.optimize_names,
    );

    const ndk_root = b.option(
        []const u8,
        "ndk",
        "Absolute NDK root of the Android steps; no environment fallback",
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

    const test_tsan = b.step(
        "test-tsan",
        "Run the host tests of the engine under ThreadSanitizer",
    );

    const test_header = b.step(
        "test-header",
        "Check the host translation of the Bindings header against abi.tsv",
    );

    const test_abi = b.step(
        "test-abi",
        "Run the host tests of the C ABI against the translated header",
    );

    const test_jni = b.step(
        "test-jni",
        "Run the host tests of the JNI layer against the NDK's JNI header",
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

    const test_codecs = b.step(
        "test-codecs",
        "Compile the host codec archives and run the codec host tests",
    );

    const check_codecs = b.step(
        "check-codecs",
        "Compile the zlib and libpng archives for -Dabi",
    );

    const check_inspect = b.step(
        "check-inspect",
        "Check that the inspection rejects a defective library of each " ++
            "base rule for -Dabi",
    );

    const stage_library = b.step(
        "stage-library",
        "Link and inspect the San library for -Dabi, then install it " ++
            "into --prefix, which must be build/work/<abi>-<mode>/",
    );

    const stage_local = b.step(
        "stage-local",
        "Link and inspect the San library of every ABI for -Doptimize, " ++
            "then stage them with a manifest in " ++
            "build/artifacts/local/<commit>/; refuses a tree that " ++
            "differs from its commit",
    );

    const stage_device = b.step(
        "stage-device",
        "Link and inspect the San library and the device test libraries " ++
            "for -Dabi, then install them and their harnesses into " ++
            "--prefix, which must be build/work/<abi>-<mode>/",
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
            test_tsan,
            test_header,
            test_abi,
            test_jni,
            check_header,
            check_engine,
            test_codecs,
            check_codecs,
            check_inspect,
            stage_library,
            stage_local,
            stage_device,
            clean_step,
            verify_store,
        }, b.fmt("a Zig 0.{d}.x release required; found {f}", .{
            minor,
            version,
        }));

        return;
    }

    addHostTests(b, test_step);
    addSanitizedTests(b, test_tsan);
    addClean(b, clean_step, layout);
    addVerifyStore(b, verify_store, layout);
    addHeaderTest(b, test_header, layout);
    addAbiTest(b, test_abi, layout);

    const selection: Selection = .{
        .abi = abi,
        .optimize = optimize,
        .ndk = ndk_root,
        .guard_ndk_major = guard_ndk_major,
    };

    addJniTest(b, test_jni, layout, selection);
    addHeaderCheck(b, check_header, layout, selection);
    addEngineCheck(b, check_engine, selection);

    const inspection = addInspectionTool(b);

    addInspectCheck(b, check_inspect, selection, inspection);

    addLibraryStage(b, .{
        .stage_library = stage_library,
        .stage_device = stage_device,
    }, layout, selection, inspection);

    addLocalStage(
        b,
        stage_local,
        verify_store,
        layout,
        selection,
        inspection,
    );

    try addCodecSteps(b, .{
        .test_codecs = test_codecs,
        .check_codecs = check_codecs,
        .stage_device = stage_device,
    }, layout, selection, inspection);
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

/// Adds the host tests of the engine under ThreadSanitizer. A plain run
/// of the tests that cross threads observes neither a race on a plain
/// field nor a missing memory ordering, and the sanitizer reports both.
fn addSanitizedTests(b: *std.Build, step: *std.Build.Step) void {
    const tests = b.addTest(.{
        .name = "engine-tsan",
        .root_module = b.createModule(.{
            .root_source_file = b.path(engine_root),
            .target = b.graph.host,
            .optimize = .debug,
            // The tests run the system backing on the host libc.
            .link_libc = true,
            .sanitize_thread = true,
        }),
    });

    // On macOS the sanitizer's runtime is a dynamic library in the
    // global cache, and the test finds it through a run path relative to
    // the build root. So the test runs there, where it writes no file:
    // the tests of the engine use no temporary directory.
    step.dependOn(&b.addRunArtifact(tests).step);
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

/// Adds the host tests of the C ABI, in the modes of the Zig core. The
/// module reaches the header through its host translation.
fn addAbiTest(b: *std.Build, step: *std.Build.Step, layout: Layout) void {
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

    const engine = b.createModule(.{
        .root_source_file = b.path(engine_root),
    });

    for (engine_test_modes) |optimize| {
        const tests = b.addTest(.{
            .name = b.fmt("abi-{t}", .{optimize}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(abi_root),
                .target = target,
                .optimize = optimize,
                // The tests run the system backing on the host libc.
                .link_libc = true,
                .imports = &.{
                    .{ .name = "san", .module = translation.san },
                    .{ .name = "engine", .module = engine },
                },
            }),
        });

        step.dependOn(&b.addRunArtifact(tests).step);
    }
}

/// Adds the host tests of the JNI layer, in the modes of the Zig core.
/// The JNI header comes from the NDK, and it includes only <stdarg.h>
/// and <stdint.h>, so the host translates it alone, without another NDK
/// header.
fn addJniTest(
    b: *std.Build,
    step: *std.Build.Step,
    layout: Layout,
    selection: Selection,
) void {
    // The header lies in the include directory that every ABI shares, so
    // any ABI opens the NDK for it.
    const found = openNdk(b, step, selection, .@"arm64-v8a") orelse return;

    if (failMissingPackage(b, step, layout)) return;

    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;

    const target = b.resolveTargetQuery(
        profile.hostQuery(b.graph.host.result),
    );

    const translator = b.dependency("translate_c", .{});

    const jni = header.translateFile(
        b,
        translate_c.Translator,
        translator,
        target,
        .host,
        "jni",
        jniHeader(b, found),
    );

    const translation = header.translate(
        b,
        translate_c.Translator,
        translator,
        target,
        .host,
    );

    const abi = b.createModule(.{
        .root_source_file = b.path(abi_root),
        .imports = &.{
            .{ .name = "san", .module = translation.san },
            .{ .name = "engine", .module = b.createModule(.{
                .root_source_file = b.path(engine_root),
            }) },
        },
    });

    for (engine_test_modes) |optimize| {
        const tests = b.addTest(.{
            .name = b.fmt("jni-{t}", .{optimize}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(jni_root),
                .target = target,
                .optimize = optimize,
                // The methods run the C ABI on the system backing, which
                // is the host libc here.
                .link_libc = true,
                .imports = &.{
                    .{ .name = "jni", .module = jni },
                    .{ .name = "san", .module = translation.san },
                    .{ .name = "abi", .module = abi },
                    .{ .name = "bindings", .module = header.bindingsModule(b) },
                    .{ .name = "table", .module = tableModule(b) },
                },
            }),
        });

        step.dependOn(&b.addRunArtifact(tests).step);
    }
}

/// Returns the JNI header of the NDK.
fn jniHeader(b: *std.Build, found: ndk.Root) std.Build.LazyPath {
    return b.graph.cwdRelativePath(
        b.pathJoin(&.{ found.include_dirs[0], "jni.h" }),
    );
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
        .rejected = missing_optimize,
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

    const found = openNdk(b, step, selection, abi) orelse return;

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

/// Opens the NDK of `selection` for `abi`. A missing or rejected root
/// fails `step` with the message that names it and returns null.
fn openNdk(
    b: *std.Build,
    step: *std.Build.Step,
    selection: Selection,
    abi: profile.Abi,
) ?ndk.Root {
    const root = selection.ndk orelse {
        failSteps(b, &.{step}, "missing -Dndk; pass the absolute NDK root");

        return null;
    };

    const opened = ndk.open(b, root, abi.triple(), selection.guard_ndk_major);

    return switch (opened) {
        .ok => |found| found,
        .rejected => |message| {
            failSteps(b, &.{step}, message);

            return null;
        },
    };
}

/// The steps that compile the codecs.
const CodecSteps = struct {
    test_codecs: *std.Build.Step,
    check_codecs: *std.Build.Step,
    stage_device: *std.Build.Step,
};

/// Adds test-codecs, check-codecs, and stage-device. They need the codec
/// packages, which only -Doptimize requests.
fn addCodecSteps(
    b: *std.Build,
    steps: CodecSteps,
    layout: Layout,
    selection: Selection,
    inspection: *std.Build.Step.Compile,
) error{LazyDependencyNeeded}!void {
    const optimize = selection.optimize orelse return failSteps(
        b,
        &.{ steps.test_codecs, steps.check_codecs, steps.stage_device },
        missing_optimize,
    );

    const codec_packages = try requestCodecs(b, layout);

    addCodecTest(b, steps.test_codecs, layout, codec_packages, optimize);
    addCodecCheck(b, steps.check_codecs, layout, selection, codec_packages);

    addDeviceStage(
        b,
        steps.stage_device,
        layout,
        selection,
        codec_packages,
        inspection,
    );
}

/// Requests both codec packages before either one ends the configuration,
/// so that one invocation marks every missing package. Under --system,
/// Zig names a missing package only by its hash in the store, so this
/// also names each one with the explicit fetch.
fn requestCodecs(
    b: *std.Build,
    layout: Layout,
) error{LazyDependencyNeeded}!codecs.Packages {
    const libpng = b.dependencyLazy("libpng", .{});

    const zlib = b.dependencyLazy("zlib", .{});

    if (b.graph.system_package_mode) {
        if (std.meta.isError(libpng)) reportMissing(b, layout, "libpng");
        if (std.meta.isError(zlib)) reportMissing(b, layout, "zlib");
    }

    return .{ .libpng = try libpng, .zlib = try zlib };
}

fn reportMissing(b: *std.Build, layout: Layout, name: []const u8) void {
    std.log.err(
        "package {s} is not in the store {s}; run the explicit fetch: {s}",
        .{ name, layout.store, layout.fetchCommand(b) },
    );
}

/// Adds the host codec archives and the host tests of the codecs. The
/// archives compile in their own mode, and `optimize` selects the mode of
/// the Zig tests.
fn addCodecTest(
    b: *std.Build,
    step: *std.Build.Step,
    layout: Layout,
    codec_packages: codecs.Packages,
    optimize: std.lang.Optimize,
) void {
    if (!profile.supportedOnSomeAbi(optimize)) return failSteps(
        b,
        &.{step},
        b.fmt("unsupported -Doptimize={t} for test-codecs; supported: {s}", .{
            optimize,
            profile.optimize_names,
        }),
    );

    // With an explicit host query, the host compiles take Zig's own libc
    // headers, as the host translation does, and no SDK of the host.
    const host = b.resolveTargetQuery(profile.hostQuery(b.graph.host.result));

    const added = codecs.addArchives(
        b,
        codec_packages,
        host,
        .host,
        layout.root,
    );

    const archives = switch (added) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    dependOnArchives(step, archives);

    const tests = b.addTest(.{
        .name = "pnglibconf-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/pnglibconf_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{
                .name = "pnglibconf",
                .module = codecs.configModule(b, codec_packages.libpng),
            }},
        }),
    });

    step.dependOn(&b.addRunArtifact(tests).step);
    addDecoderTest(b, step, layout, host, archives, optimize);
}

/// Adds the host tests of the PNG decoder, linked with the host archives.
/// The decoder reaches the adapter through the host translation of the
/// adapter's header.
fn addDecoderTest(
    b: *std.Build,
    step: *std.Build.Step,
    layout: Layout,
    host: std.Build.ResolvedTarget,
    archives: codecs.Archives,
    optimize: std.lang.Optimize,
) void {
    if (failMissingPackage(b, step, layout)) return;

    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;

    const adapter = header.translateFile(
        b,
        translate_c.Translator,
        b.dependency("translate_c", .{}),
        host,
        .host,
        "adapter",
        b.path(codecs.png_adapter_header),
    );

    const engine = b.createModule(.{
        .root_source_file = b.path(engine_root),
    });

    const tests = b.addTest(.{
        .name = b.fmt("png-decoder-{t}", .{optimize}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(png_decoder_root),
            .target = host,
            .optimize = optimize,
            // The tests run the system backing on the host libc.
            .link_libc = true,
            .imports = &.{
                .{ .name = "adapter", .module = adapter },
                .{ .name = "engine", .module = engine },
            },
        }),
    });

    tests.root_module.linkLibrary(archives.png);
    tests.root_module.linkLibrary(archives.zlib);
    step.dependOn(&b.addRunArtifact(tests).step);
}

/// Adds the codec archives of the selected ABI. Nothing links them yet.
fn addCodecCheck(
    b: *std.Build,
    step: *std.Build.Step,
    layout: Layout,
    selection: Selection,
    codec_packages: codecs.Packages,
) void {
    const android = switch (selectAndroid(b, selection)) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    const found = openNdk(b, step, selection, android.abi) orelse return;

    const platform: codecs.Platform = .{ .android = .{
        .abi = android.abi,
        .include_dirs = found.include_dirs,
    } };

    const added = codecs.addArchives(
        b,
        codec_packages,
        b.resolveTargetQuery(android.abi.targetQuery()),
        platform,
        layout.root,
    );

    const archives = switch (added) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    dependOnArchives(step, archives);
}

/// Adds stage-device: the device test libraries, each in the link shape
/// of the San library and with its harness. libsan_png_test.so holds the
/// PNG decoder, and libsan_abi_test.so the C ABI. Each inspection runs on
/// the exact file that the install copies, and the installs wait for it,
/// so only an inspected library reaches the install prefix.
fn addDeviceStage(
    b: *std.Build,
    step: *std.Build.Step,
    layout: Layout,
    selection: Selection,
    codec_packages: codecs.Packages,
    inspection: *std.Build.Step.Compile,
) void {
    const android = switch (selectAndroid(b, selection)) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    const found = openNdk(b, step, selection, android.abi) orelse return;

    if (failMissingPackage(b, step, layout)) return;

    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;

    const target = b.resolveTargetQuery(android.abi.targetQuery());

    const added = codecs.addArchives(
        b,
        codec_packages,
        target,
        .{ .android = .{
            .abi = android.abi,
            .include_dirs = found.include_dirs,
        } },
        layout.root,
    );

    const archives = switch (added) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    const adapter = header.translateFile(
        b,
        translate_c.Translator,
        b.dependency("translate_c", .{}),
        target,
        .{ .android = .{
            .api_level = profile.api_level,
            .include_dirs = found.include_dirs,
        } },
        "adapter",
        b.path(codecs.png_adapter_header),
    );

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "adapter", .module = adapter },
        .{ .name = "engine", .module = androidEngine(b) },
    };

    const root = b.createModule(.{
        .root_source_file = b.path(png_device_test_root),
        .target = target,
        .optimize = android.optimize,
        .link_libc = false,
        .imports = imports,
    });

    root.linkLibrary(archives.png);
    root.linkLibrary(archives.zlib);

    const device_library = library.add(b, .{
        .name = "san_png_test",
        .root_module = root,
        .artifact = .png_device_test,
        .ndk = found,
    });

    const inspected = addInspection(
        b,
        inspection,
        android.abi,
        .png_device_test,
        device_library,
    );

    inspected.expectExitCode(0);

    // The harness reads the decoder's types through the imports, and its
    // decodes run in the library.
    const harness = addHarness(b, .{
        .name = "san-png-harness",
        .root = png_device_harness_root,
        .imports = imports,
        .library = device_library,
        .android = android,
        .ndk = found,
    });

    const prefix = addPrefixCheck(b, layout, android);

    stageInspected(b, step, &.{ device_library, harness }, inspected, prefix);

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

    const abi_imports: []const std.Build.Module.Import = &.{
        .{ .name = "san", .module = translation.san },
        .{ .name = "engine", .module = androidEngine(b) },
    };

    const abi_library = library.add(b, .{
        .name = "san_abi_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path(abi_device_test_root),
            .target = target,
            .optimize = android.optimize,
            .link_libc = false,
            .imports = abi_imports,
        }),
        .artifact = .abi_device_test,
        .ndk = found,
    });

    const abi_inspected = addInspection(
        b,
        inspection,
        android.abi,
        .abi_device_test,
        abi_library,
    );

    abi_inspected.expectExitCode(0);

    // The harness reads the header's types and constants through the
    // translation, whose functions the library defines.
    const abi_harness = addHarness(b, .{
        .name = "san-abi-harness",
        .root = abi_device_harness_root,
        .imports = abi_imports,
        .library = abi_library,
        .android = android,
        .ndk = found,
    });

    stageInspected(
        b,
        step,
        &.{ abi_library, abi_harness },
        abi_inspected,
        prefix,
    );

    // The canary library links one test-only C source. Its report shows
    // which __stack_chk_fail the C code binds in this mode.
    const canary_root = b.createModule(.{
        .root_source_file = b.path(canary_device_test_root),
        .target = target,
        .optimize = android.optimize,
        .link_libc = false,
        .imports = &.{.{ .name = "engine", .module = androidEngine(b) }},
    });

    canary_root.linkLibrary(codecs.addTestArchive(
        b,
        "canary",
        canary_source,
        target,
        .{ .android = .{
            .abi = android.abi,
            .include_dirs = found.include_dirs,
        } },
        layout.root,
    ));

    const canary_library = library.add(b, .{
        .name = "san_canary_test",
        .root_module = canary_root,
        .artifact = .canary_device_test,
        .ndk = found,
    });

    const canary_inspected = addInspection(
        b,
        inspection,
        android.abi,
        .canary_device_test,
        canary_library,
    );

    canary_inspected.expectExitCode(0);

    const canary_harness = addHarness(b, .{
        .name = "san-canary-harness",
        .root = canary_device_harness_root,
        .imports = &.{.{ .name = "engine", .module = androidEngine(b) }},
        .library = canary_library,
        .android = android,
        .ndk = found,
    });

    stageInspected(
        b,
        step,
        &.{ canary_library, canary_harness },
        canary_inspected,
        prefix,
    );

    const canary_report = b.addInstallFileWithDir(
        addReport(b, android.abi, .canary_device_test, canary_library, found),
        .prefix,
        "libsan_canary_test.report.txt",
    );

    canary_report.step.dependOn(&canary_inspected.step);
    canary_report.step.dependOn(&prefix.step);
    step.dependOn(&canary_report.step);
}

/// The steps that take the San library.
const LibrarySteps = struct {
    stage_library: *std.Build.Step,
    stage_device: *std.Build.Step,
};

/// Adds the San library: libsan.so, whose root holds the JNI layer over
/// the C ABI and the engine. stage-library installs it, and stage-device
/// installs it with the harness that loads it on a device. The
/// inspection runs on the exact file that each install copies, and the
/// installs wait for it, so only an inspected library reaches the
/// install prefix. A rejected selection fails stage-library here; the
/// device test libraries fail stage-device for it.
fn addLibraryStage(
    b: *std.Build,
    steps: LibrarySteps,
    layout: Layout,
    selection: Selection,
    inspection: *std.Build.Step.Compile,
) void {
    const step = steps.stage_library;

    const android = switch (selectAndroid(b, selection)) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    const found = openNdk(b, step, selection, android.abi) orelse return;

    if (failMissingPackage(b, step, layout)) return;

    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;

    const built = addSanLibrary(
        b,
        translate_c.Translator,
        android,
        found,
        inspection,
    );

    const prefix = addPrefixCheck(b, layout, android);

    stageInspected(b, step, &.{built.library}, built.inspected, prefix);

    // The report lies beside the library that it describes, and it waits
    // for the inspection as the library does.
    const report = b.addInstallFileWithDir(
        built.report,
        .prefix,
        san_report_name,
    );

    report.step.dependOn(&built.inspected.step);
    report.step.dependOn(&prefix.step);
    step.dependOn(&report.step);

    // The harness has no Java VM. It calls the library's JNI_OnLoad
    // against stand-ins that it builds from the same JNI header.
    const harness = addHarness(b, .{
        .name = "san-jni-harness",
        .root = jni_device_harness_root,
        .imports = &.{
            .{ .name = "jni", .module = built.jni },
            .{ .name = "san", .module = built.san },
            .{ .name = "engine", .module = built.engine },
        },
        .library = built.library,
        .android = android,
        .ndk = found,
    });

    // One install copies the library, so stage-device takes it through
    // stage-library.
    steps.stage_device.dependOn(step);

    stageInspected(
        b,
        steps.stage_device,
        &.{harness},
        built.inspected,
        prefix,
    );
}

/// The San library of one ABI, linked, inspected, and reported on.
const SanLibrary = struct {
    library: *std.Build.Step.Compile,
    /// The inspection of the library. Whatever copies the library waits
    /// for it.
    inspected: *std.Build.Step.Run,
    /// The inspection report of the library.
    report: std.Build.LazyPath,
    /// The modules that a test executable shares with the library: the
    /// translations of the JNI header and of the Bindings header, and
    /// the engine.
    jni: *std.Build.Module,
    san: *std.Build.Module,
    engine: *std.Build.Module,
};

/// Adds libsan.so for `android` with its inspection and its report.
/// `Translator` is the Translator type of the translate_c package.
fn addSanLibrary(
    b: *std.Build,
    comptime Translator: type,
    android: Android,
    found: ndk.Root,
    inspection: *std.Build.Step.Compile,
) SanLibrary {
    const target = b.resolveTargetQuery(android.abi.targetQuery());

    const translator = b.dependency("translate_c", .{});

    const system: header.System = .{ .android = .{
        .api_level = profile.api_level,
        .include_dirs = found.include_dirs,
    } };

    const translation = header.translate(
        b,
        Translator,
        translator,
        target,
        system,
    );

    const jni = header.translateFile(
        b,
        Translator,
        translator,
        target,
        system,
        "jni",
        jniHeader(b, found),
    );

    const engine = androidEngine(b);

    const abi = b.createModule(.{
        .root_source_file = b.path(abi_root),
        .link_libc = false,
        .imports = &.{
            .{ .name = "san", .module = translation.san },
            .{ .name = "engine", .module = engine },
        },
    });

    const layer = b.createModule(.{
        .root_source_file = b.path(jni_root),
        .link_libc = false,
        .imports = &.{
            .{ .name = "jni", .module = jni },
            .{ .name = "san", .module = translation.san },
            .{ .name = "abi", .module = abi },
        },
    });

    const san_library = library.add(b, .{
        .name = "san",
        .root_module = b.createModule(.{
            .root_source_file = b.path(san_root),
            .target = target,
            .optimize = android.optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "engine", .module = engine },
                .{ .name = "jni_layer", .module = layer },
            },
        }),
        .artifact = .san,
        .ndk = found,
    });

    const inspected = addInspection(
        b,
        inspection,
        android.abi,
        .san,
        san_library,
    );

    inspected.expectExitCode(0);

    return .{
        .library = san_library,
        .inspected = inspected,
        .report = addReport(b, android.abi, .san, san_library, found),
        .jni = jni,
        .san = translation.san,
        .engine = engine,
    };
}

/// Adds stage-local: the San library of every ABI in the mode of
/// -Doptimize, each linked, inspected, and reported on as stage-library
/// does, and the manifest tool, which copies them into
/// build/artifacts/local/<San commit>/ and writes the manifest of that
/// set. The tool refuses a checkout that differs from its commit, once
/// before the first compile and once after the last inspection, and the
/// second run also refuses a commit other than the first one's, so a set
/// describes the one commit that it names.
fn addLocalStage(
    b: *std.Build,
    step: *std.Build.Step,
    verify_store: *std.Build.Step,
    layout: Layout,
    selection: Selection,
    inspection: *std.Build.Step.Compile,
) void {
    const abis = comptime std.enums.values(profile.Abi);

    const optimize = selection.optimize orelse
        return failSteps(b, &.{step}, missing_optimize);

    var roots: [abis.len]ndk.Root = undefined;

    for (abis, &roots) |abi, *found| {
        if (!profile.combinationSupported(abi, optimize)) return failSteps(
            b,
            &.{step},
            b.fmt("unsupported -Doptimize={t} for stage-local on {t}; " ++
                "supported: {s}", .{ optimize, abi, profile.optimize_names }),
        );

        found.* = openNdk(b, step, selection, abi) orelse return;
    }

    if (failMissingPackage(b, step, layout)) return;

    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;

    const tool = b.addExecutable(.{
        .name = "manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/manifest.zig"),
            .target = b.graph.host,
        }),
    });

    // The tool reads the state of the checkout in both runs and writes
    // outside the cache in the second, so no earlier run stands for
    // either. The first run waits for the store verification, because
    // the store holds build inputs that Git ignores.
    const check = b.addRunArtifact(tool);

    check.setName("check that the checkout is at its commit");
    check.addArgs(&.{ "check", layout.root });

    const record = check.addOutputFileArg("commit");

    check.has_side_effects = true;
    check.step.dependOn(verify_store);

    const run = b.addRunArtifact(tool);

    const revision = roots[0].revision;

    run.setName("stage the local set with its manifest");
    run.addArgs(&.{ "stage", layout.root });
    run.addFileArg(record);

    run.addArgs(&.{
        b.pathJoin(&.{ layout.build, "artifacts", "local" }),
        "local",
        @import("build.zig.zon").version,
        b.fmt("{f}", .{builtin.zig_version}),
        b.fmt("{d}.{d}.{d}", .{
            revision.major,
            revision.minor,
            revision.build,
        }),
        @tagName(optimize),
    });

    for (abis, roots) |abi, found| {
        const built = addSanLibrary(
            b,
            translate_c.Translator,
            .{ .abi = abi, .optimize = optimize },
            found,
            inspection,
        );

        // No library compiles before the checkout passed its check.
        built.library.step.dependOn(&check.step);

        run.addArg(b.fmt("{t}/libsan.so", .{abi}));
        run.addArtifactArg(built.library);
        run.addArg(b.fmt("{t}/{s}", .{ abi, san_report_name }));
        run.addFileArg(built.report);
        run.step.dependOn(&built.inspected.step);
    }

    run.has_side_effects = true;
    step.dependOn(&run.step);
}

/// A test executable that runs beside a device test library.
const Harness = struct {
    name: []const u8,
    /// The root source file, relative to the San root.
    root: []const u8,
    imports: []const std.Build.Module.Import,
    /// The device test library that the executable needs.
    library: *std.Build.Step.Compile,
    android: Android,
    ndk: ndk.Root,
};

/// Adds the test executable of `harness`. A test executable of San links
/// libc, with the crt objects of the generated libc description.
fn addHarness(b: *std.Build, harness: Harness) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{
        .name = harness.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(harness.root),
            .target = b.resolveTargetQuery(harness.android.abi.targetQuery()),
            .optimize = harness.android.optimize,
            .link_libc = true,
            .imports = harness.imports,
        }),
        .use_llvm = true,
        .use_lld = true,
    });

    // The executable needs the library through DT_NEEDED, by the
    // library's SONAME. linkLibrary would also record the library's
    // directory in the build cache as a RUNPATH, a host path that means
    // nothing on the device, so the executable takes the linked file as
    // an input.
    executable.root_module.addObjectFile(harness.library.getEmittedBin());

    executable.setLibCFile(
        ndk.addLibcFile(b, harness.ndk, harness.android.abi.triple()),
    );

    // Android loads position-independent executables only, and segments
    // aligned to the profile's page size map on both page sizes.
    executable.pie = true;
    executable.link_z_max_page_size = profile.page_size;

    return executable;
}

/// Installs `artifacts` into the prefix for `step`. Each install waits
/// for the inspection of the library among them and for the check of the
/// prefix, so only an inspected library reaches the install prefix.
fn stageInspected(
    b: *std.Build,
    step: *std.Build.Step,
    artifacts: []const *std.Build.Step.Compile,
    inspected: *std.Build.Step.Run,
    prefix: *std.Build.Step.Run,
) void {
    for (artifacts) |artifact| {
        const install = b.addInstallArtifact(artifact, .{
            .dest_dir = .{ .override = .prefix },
        });

        install.step.dependOn(&inspected.step);
        install.step.dependOn(&prefix.step);
        step.dependOn(&install.step);
    }
}

/// Returns the check that the install prefix is build/work/<abi>-<mode>/
/// of the selection, the directory from which a device run takes the
/// files. Zig resolves the prefix only when the build runs, so the check
/// is a host tool that receives it then.
fn addPrefixCheck(
    b: *std.Build,
    layout: Layout,
    android: Android,
) *std.Build.Step.Run {
    const tool = b.addExecutable(.{
        .name = "install-prefix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/install_prefix.zig"),
            .target = b.graph.host,
        }),
    });

    const run = b.addRunArtifact(tool);

    const expected = b.pathJoin(&.{
        layout.work,
        b.fmt("{t}-{t}", .{ android.abi, android.optimize }),
    });

    run.setName(b.fmt("check the install prefix {s}", .{expected}));
    run.addArg(expected);
    run.addDirectoryArg2(
        .{ .relative = .{ .base = .install_prefix } },
        .{ .make_absolute = true },
    );
    run.expectExitCode(0);

    return run;
}

/// Returns the engine module for an Android library, which links no
/// libc. It takes its target and mode from the root that imports it.
fn androidEngine(b: *std.Build) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(engine_root),
        .link_libc = false,
    });
}

/// Returns the inspection tool, a host tool that checks a linked Android
/// library against the base rules of San's inspection.
fn addInspectionTool(b: *std.Build) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "inspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/inspect.zig"),
            .target = b.graph.host,
        }),
    });
}

/// Runs the inspection tool on `artifact`, a library of the kind `kind`
/// for `abi`. The run reads the file that the library's compile emits,
/// which is the file that its install copies.
fn addInspection(
    b: *std.Build,
    inspection: *std.Build.Step.Compile,
    abi: profile.Abi,
    kind: allowlist.Artifact,
    artifact: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(inspection);

    run.setName(b.fmt("inspect {s} for {t}", .{ artifact.name, abi }));
    run.addArgs(&.{ @tagName(abi), @tagName(kind) });
    run.addArtifactArg(artifact);

    return run;
}

/// Runs the report tool on `artifact`, a library of the kind `kind` for
/// `abi`, and returns the report. The tool reads the unstripped file that
/// the library's compile emits, and the libc stub that the library links
/// against, whose exports are the libc names.
fn addReport(
    b: *std.Build,
    abi: profile.Abi,
    kind: allowlist.Artifact,
    artifact: *std.Build.Step.Compile,
    found: ndk.Root,
) std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/report.zig"),
            .target = b.graph.host,
        }),
    });

    const run = b.addRunArtifact(tool);

    run.setName(b.fmt("report on {s} for {t}", .{ artifact.name, abi }));
    run.addArgs(&.{ @tagName(abi), @tagName(kind) });
    run.addArtifactArg(artifact);
    run.addFileArg(b.graph.cwdRelativePath(found.libc_stub));

    return run.addOutputFileArg(b.fmt("lib{s}.report.txt", .{artifact.name}));
}

/// A deliberate defect of a library that check-inspect links, with the
/// rule of the inspection that must reject it. `none` is the control:
/// the same library without a defect, which passes every rule.
const Defect = enum {
    none,
    extra_export,
    getenv_import,
    libm_needed,
    small_pages,
    svc,

    fn rule(defect: Defect) ?inspect.Rule {
        return switch (defect) {
            .none => null,
            .extra_export => .exports,
            .getenv_import => .imports,
            .libm_needed => .needed,
            .small_pages => .load_align,
            .svc => .svc,
        };
    }
};

/// The name that the library of the extra-export defect exports beside
/// its declared export.
const extra_export = "san_png_device_test_extra";

/// Adds check-inspect: a library in the link shape of San's libraries
/// for each defect, each inspected with the expectation that the tool
/// exits 1 and names the defect's rule, and the control without a
/// defect, which must pass. The svc rule scans arm64 code only, so its
/// defect is linked for arm64-v8a only.
fn addInspectCheck(
    b: *std.Build,
    step: *std.Build.Step,
    selection: Selection,
    inspection: *std.Build.Step.Compile,
) void {
    const android = switch (selectAndroid(b, selection)) {
        .ok => |valid| valid,
        .rejected => |message| return failSteps(b, &.{step}, message),
    };

    const found = openNdk(b, step, selection, android.abi) orelse return;

    const target = b.resolveTargetQuery(android.abi.targetQuery());

    const engine = androidEngine(b);

    for (std.enums.values(Defect)) |defect| {
        if (defect == .svc and android.abi != .@"arm64-v8a") continue;

        const options = b.addOptions();

        options.addOption(Defect, "defect", defect);
        options.addOption([]const u8, "extra_export", extra_export);

        const root = b.createModule(.{
            .root_source_file = b.path(inspect_defects_root),
            .target = target,
            .optimize = android.optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "options", .module = options.createModule() },
                .{ .name = "engine", .module = engine },
            },
        });

        const defective = library.add(b, .{
            .name = b.fmt("san_defect_{t}", .{defect}),
            .root_module = root,
            .artifact = .png_device_test,
            .ndk = found,
        });

        switch (defect) {
            .none, .getenv_import, .svc => {},
            .extra_export => defective.setVersionScript(
                extraExportScript(b),
            ),
            .libm_needed => root.addObjectFile(b.graph.cwdRelativePath(
                b.pathJoin(&.{ found.crt_dir, "libm.so" }),
            )),
            .small_pages => defective.link_z_max_page_size = 4096,
        }

        const run = addInspection(
            b,
            inspection,
            android.abi,
            .png_device_test,
            defective,
        );

        if (defect.rule()) |rule| {
            run.expectExitCode(1);
            run.expectStdErrMatch(b.fmt("inspect: {t}: ", .{rule}));
        } else {
            run.expectExitCode(0);
        }

        step.dependOn(&run.step);
    }
}

/// Returns the version script of the extra-export defect: the script that
/// allowlist.zig derives for the device test library, with one more
/// global name. If the derived script ever loses its `local:` line, the
/// name stays hidden, the library passes, and check-inspect fails.
fn extraExportScript(b: *std.Build) std.Build.LazyPath {
    const script = std.mem.replaceOwned(
        u8,
        b.graph.arena,
        allowlist.versionScript(.png_device_test),
        "  local:\n",
        "    " ++ extra_export ++ ";\n  local:\n",
    ) catch @panic("OOM");

    return b.addWriteFiles().add("extra-export.map", script);
}

fn dependOnArchives(step: *std.Build.Step, archives: codecs.Archives) void {
    for ([_]*std.Build.Step.Compile{ archives.zlib, archives.png }) |archive| {
        _ = archive.getEmittedBin();
        step.dependOn(&archive.step);
    }
}

fn tableModule(b: *std.Build) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/build/table.zig"),
    });
}
