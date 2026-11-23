//! The recipes of San's C codecs and the one list of flags that every C
//! compile of San takes.
//!
//! zlib and libpng each compile into a static archive with its own
//! module; the png archive also holds San's containment adapter of
//! libpng. Zig sets the optimization mode per module, so the C code
//! compiles in ReleaseSafe, at -O2 with the undefined-behavior trap, in
//! every San build mode, Debug included: Debug runs execute the C code
//! that published builds ship, whatever mode the Zig code takes. The
//! Adler-32 that zlib's inflate calls is Zig code of the PNG decoder and
//! takes the mode of its root.

const std = @import("std");
const profile = @import("profile.zig");

/// The header that every C compile includes before its first line,
/// relative to the San root. It fails the compile when a hardening flag
/// of `common_flags` or `arm64_android_flags` did not take effect.
pub const hardening_header = "src/build/hardening.h";

/// San's libpng configuration header, relative to the San root. libpng's
/// package holds no pnglibconf.h, so png.h includes this one.
pub const png_config_header = "src/codecs/png/config/pnglibconf.h";

/// The containment adapter of libpng and its one header, relative to the
/// San root. Zig code reaches the adapter only through the translation of
/// the header.
pub const png_adapter_source = "src/codecs/png/adapter.c";
pub const png_adapter_header = "src/codecs/png/adapter.h";

/// The flags that San's own C adds to every flag of `cFlags`: every
/// warning is an error. The codec headers raise none of them: the config
/// and libpng directories are system include paths, and zlib.h and
/// zconf.h, which the png module finds through an -I path, count as
/// system headers by their names.
const adapter_flags = [_][]const u8{
    "-Wall",
    "-Wextra",
    "-Werror",
    "--system-header-prefix=zlib.h",
    "--system-header-prefix=zconf.h",
};

/// The flag of libpng's compiles that renames libpng's one call of zlib's
/// inflate, in png_zlib_inflate, to the adapter's observer. The observer
/// calls inflate unchanged and records the end and the size of the image
/// data stream, which libpng only warns about. zlib and the adapter
/// compile without it, so they keep the real inflate.
const inflate_observer = "-Dinflate=san_png_inflate";

/// zlib's inflate path, which libpng's reader uses. The gz file
/// functions and deflate stay out, and so does adler32.c: inflate binds
/// the Adler-32 of src/codecs/png/adler32.zig, which adds 16 bytes in a
/// step where zlib's adds one.
const zlib_sources = [_][]const u8{
    "crc32.c",
    "inflate.c",
    "inftrees.c",
    "inffast.c",
    "zutil.c",
};

/// libpng's read sources. The write sources stay out.
const png_sources = [_][]const u8{
    "png.c",
    "pngerror.c",
    "pngget.c",
    "pngmem.c",
    "pngpread.c",
    "pngread.c",
    "pngrio.c",
    "pngrtran.c",
    "pngrutil.c",
    "pngset.c",
    "pngtrans.c",
};

/// The flags of every C compile of San, before the hardening header.
const common_flags = [_][]const u8{
    "-std=c11",
    // A canary in every C function that needs one. Zig 0.17.0 passes
    // -fno-stack-protector first to the C of a module without libc, such
    // as every Android module of San, and this later flag wins.
    "-fstack-protector-strong",
    // FORTIFY stays off: its __*_chk calls would import Bionic's checks
    // or bind the trapping copies of Zig's compiler_rt. Zig 0.17.0
    // defines _FORTIFY_SOURCE=2 for C in ReleaseSafe, and this later
    // flag removes it.
    "-U_FORTIFY_SOURCE",
    // One section per function and object, so that the link collects
    // what nothing references. A library's own section settings never
    // reach the archives that it links, and Zig 0.17.0 passes
    // -fno-function-sections and -fno-data-sections first, so every C
    // compile passes these later flags itself.
    "-ffunction-sections",
    "-fdata-sections",
    // Every C symbol stays hidden, so that only the symbols that San
    // exports leave the library, and the link drops the unreachable rest.
    "-fvisibility=hidden",
    // zlib without its default allocator, so that every allocation goes
    // through the callbacks that libpng sets. Every C compile defines
    // it, so that zconf.h declares the same types on every side.
    "-DZ_SOLO",
};

/// The flags that every C compile adds on arm64-v8a.
const arm64_android_flags = [_][]const u8{
    // BTI and PAC. The linker drops the property for the whole library
    // when one object lacks it.
    "-mbranch-protection=standard",
    // C frames keep their return address on the shadow call stack in
    // x18. The target's reserve_x18 feature keeps Zig's code off x18.
    "-fsanitize=shadow-call-stack",
};

/// The pinned codec packages.
pub const Packages = struct {
    libpng: *std.Build.Dependency,
    zlib: *std.Build.Dependency,
};

/// Where the C code of San compiles.
pub const Platform = union(enum) {
    /// An Android ABI without libc, as San's library links, with the
    /// NDK's system include directories.
    android: struct {
        abi: profile.Abi,
        include_dirs: [2][]const u8,
    },
    /// The host with Zig's libc, for the host tests.
    host,
};

/// The codec archives of one target.
pub const Archives = struct {
    zlib: *std.Build.Step.Compile,
    png: *std.Build.Step.Compile,
};

/// The outcome of adding the archives: the archives, or a message that
/// names the unsupported target.
pub const Added = union(enum) {
    ok: Archives,
    rejected: []const u8,
};

/// libpng's filter code for a CPU architecture, compiled in and used
/// unconditionally. ARM_NEON_CHECK stays off in San's configuration, so
/// no runtime detection needs getauxval or reads /proc/cpuinfo.
const Simd = enum {
    /// NEON, part of every arm64 CPU.
    neon,
    /// SSE2, part of the x86_64 baseline.
    sse2,

    fn of(arch: std.Target.Cpu.Arch) ?Simd {
        return switch (arch) {
            .aarch64 => .neon,
            .x86_64 => .sse2,
            else => null,
        };
    }

    /// Returns libpng's sources of the filter code.
    fn sources(simd: Simd) []const []const u8 {
        return switch (simd) {
            .neon => &.{
                "arm/arm_init.c",
                "arm/filter_neon_intrinsics.c",
                "arm/palette_neon_intrinsics.c",
            },
            .sse2 => &.{
                "intel/intel_init.c",
                "intel/filter_sse2_intrinsics.c",
            },
        };
    }

    /// Returns the definition that turns the filter code on. libpng reads
    /// NEON's value 2 as an unconditional use.
    fn define(simd: Simd) []const u8 {
        return switch (simd) {
            .neon => "-DPNG_ARM_NEON_OPT=2",
            .sse2 => "-DPNG_INTEL_SSE_OPT=1",
        };
    }
};

/// Returns the flags of every C compile of San on `platform`: the codecs
/// and San's own C alike. `root` is the absolute San root.
pub fn cFlags(
    b: *std.Build,
    platform: Platform,
    root: []const u8,
) []const []const u8 {
    const arena = b.graph.arena;
    var flags: std.ArrayList([]const u8) = .empty;

    flags.appendSlice(arena, &common_flags) catch @panic("OOM");

    switch (platform) {
        .android => |android| switch (android.abi) {
            .@"arm64-v8a" => flags.appendSlice(
                arena,
                &arm64_android_flags,
            ) catch @panic("OOM"),
            .x86_64 => {},
        },
        .host => {},
    }

    flags.appendSlice(arena, &.{
        "-include",
        b.pathJoin(&.{ root, hardening_header }),
    }) catch @panic("OOM");

    return flags.items;
}

/// Adds the zlib and png archives for `target` on `platform`. `root` is
/// the absolute San root.
pub fn addArchives(
    b: *std.Build,
    packages: Packages,
    target: std.Build.ResolvedTarget,
    platform: Platform,
    root: []const u8,
) Added {
    const arch = target.result.cpu.arch;

    const simd = Simd.of(arch) orelse return .{ .rejected = b.fmt(
        "libpng's filter code is selected for aarch64 and x86_64 only; " ++
            "the target is {t}",
        .{arch},
    ) };

    const flags = cFlags(b, platform, root);

    const zlib_root = packages.zlib.path("");

    const png_root = packages.libpng.path("");

    // zlib's sources find their own headers next to them.
    const zlib = codecModule(b, target, platform, &.{});

    zlib.addCSourceFiles(.{
        .root = zlib_root,
        .files = &zlib_sources,
        .flags = flags,
    });

    const png = codecModule(b, target, platform, &.{
        b.path(std.fs.path.dirname(png_config_header).?),
        png_root,
    });

    // The NDK sysroot and Zig's macOS libc headers each hold a zlib.h and
    // a zconf.h of a system zlib, and Zig places its libc directories
    // before a module's system include paths. clang searches -I
    // directories before every system include directory, so libpng's
    // "zlib.h" is the pinned one on every platform.
    png.addIncludePath(zlib_root);

    const png_flags = std.mem.concat(b.graph.arena, []const u8, &.{
        flags,
        &.{ simd.define(), inflate_observer },
    }) catch @panic("OOM");

    png.addCSourceFiles(.{
        .root = png_root,
        .files = &png_sources,
        .flags = png_flags,
    });

    png.addCSourceFiles(.{
        .root = png_root,
        .files = simd.sources(),
        .flags = png_flags,
    });

    png.addCSourceFile(.{
        .file = b.path(png_adapter_source),
        .flags = std.mem.concat(b.graph.arena, []const u8, &.{
            flags,
            &adapter_flags,
        }) catch @panic("OOM"),
    });

    return .{ .ok = .{
        .zlib = archive(b, "zlib", zlib, platform),
        .png = archive(b, "png", png, platform),
    } };
}

/// The warnings of a test-only C source of San: every warning is an
/// error.
const test_flags = [_][]const u8{ "-Wall", "-Wextra", "-Werror" };

/// Adds the static archive `name` of `source`, a test-only C source of
/// San that only a device test library links. It compiles as every C
/// component does: in the safe mode with the undefined-behavior trap and
/// with every flag of `cFlags`. `root` is the absolute San root.
pub fn addTestArchive(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    platform: Platform,
    root: []const u8,
) *std.Build.Step.Compile {
    const module = codecModule(b, target, platform, &.{});

    module.addCSourceFile(.{
        .file = b.path(source),
        .flags = std.mem.concat(b.graph.arena, []const u8, &.{
            cFlags(b, platform, root),
            &test_flags,
        }) catch @panic("OOM"),
    });

    return archive(b, name, module, platform);
}

/// Returns a module for the C code of a codec on `platform`, with the
/// codec's directories `codec_dirs` as system include paths. A system
/// header raises no warning in a compile that enables warnings.
fn codecModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    platform: Platform,
    codec_dirs: []const std.Build.LazyPath,
) *std.Build.Module {
    const module = b.createModule(.{
        .target = target,
        .optimize = .safe,
        .link_libc = switch (platform) {
            .android => false,
            .host => true,
        },
        // Trap mode, set explicitly: the reporting runtime would enter the
        // artifact with no import that an inspection could see.
        .sanitize_c = .trap,
        // The archives link into a shared library.
        .pic = true,
    });

    // clang searches system include paths from left to right, so the
    // codec's directories come before the NDK's.
    for (codec_dirs) |dir| module.addSystemIncludePath(dir);

    switch (platform) {
        .android => |android| for (android.include_dirs) |dir| {
            module.addSystemIncludePath(b.graph.cwdRelativePath(dir));
        },
        .host => {},
    }

    return module;
}

/// Returns the static archive of the C code of `module`, after checking
/// that each of its C sources takes the hardening header.
fn archive(
    b: *std.Build,
    name: []const u8,
    module: *std.Build.Module,
    platform: Platform,
) *std.Build.Step.Compile {
    requireHardening(module, name);

    const built = b.addLibrary(.{
        .linkage = .static,
        .name = name,
        .root_module = module,
        .use_llvm = true,
        // Android artifacts take LLD explicitly; the host keeps Zig's
        // default linker.
        .use_lld = switch (platform) {
            .android => true,
            .host => null,
        },
    });

    // An Android archive holds LLVM bitcode, so that the link of the
    // library that takes it optimizes across Zig and C. The host tests
    // link the host archives as machine code.
    switch (platform) {
        .android => built.lto = .full,
        .host => {},
    }

    return built;
}

/// Returns a module whose root declares San's libpng configuration header
/// as `san` and libpng's prebuilt default as `prebuilt`. @embedFile reads
/// only files inside the module's directory, so the root and copies of
/// both headers live in one directory of the build cache.
pub fn configModule(
    b: *std.Build,
    libpng: *std.Build.Dependency,
) *std.Build.Module {
    const files = b.addWriteFiles();

    _ = files.addCopyFile(b.path(png_config_header), "san.h");

    _ = files.addCopyFile(
        libpng.path("scripts/pnglibconf.h.prebuilt"),
        "prebuilt.h",
    );

    const root = files.add("pnglibconf.zig",
        \\//! San's libpng configuration header and libpng's prebuilt
        \\//! default, copied from the San tree and the libpng package.
        \\
        \\pub const san = @embedFile("san.h");
        \\pub const prebuilt = @embedFile("prebuilt.h");
        \\
    );

    return b.createModule(.{ .root_source_file = root });
}

/// Ends the configuration unless every C source of `module`, reached as
/// `name`, takes the hardening header through -include. The header checks
/// the flags of each compile that includes it, and nothing else notices a
/// compile without it: a C source added without the flags of `cFlags`, or
/// a changed -include pair, would drop the check silently.
pub fn requireHardening(module: *std.Build.Module, name: []const u8) void {
    for (module.link_objects.items) |object| {
        const flags = switch (object) {
            .c_source_file => |source| source.flags,
            .c_source_files => |sources| sources.flags,
            else => continue,
        };

        if (!forcesHardening(flags)) std.debug.panic(
            "a C source of '{s}' compiles without -include <San>/{s}; " ++
                "every C compile of San takes the flags of cFlags",
            .{ name, hardening_header },
        );
    }
}

/// Reports whether `flags` hold -include with the absolute path of the
/// hardening header.
fn forcesHardening(flags: []const []const u8) bool {
    if (flags.len < 2) return false;

    for (flags[0 .. flags.len - 1], flags[1..]) |flag, path| {
        const forced = std.mem.eql(u8, flag, "-include") and
            std.fs.path.isAbsolute(path) and
            std.mem.endsWith(u8, path, "/" ++ hardening_header);

        if (forced) return true;
    }

    return false;
}
