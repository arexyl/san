//! The translation of the Bindings header through the translate-c
//! package, and the module that hands the Bindings files to the checks.
//! The translations and their modules stay in the build cache.

const std = @import("std");

/// The Bindings header, relative to the San root.
pub const header_path = "share/bindings/include/san.h";

/// The Bindings cross-check table, relative to the San root.
pub const table_path = "share/bindings/abi.tsv";

/// A C source with the system includes of the Bindings header and nothing
/// else. By its profile, the header includes only <stdint.h>; extend the
/// stub with the header's includes.
const system_stub = "#include <stdint.h>\n";

/// The modules of one translation. The declarations that `san` holds and
/// `system` does not are the Bindings' own, whatever their names.
pub const Translation = struct {
    /// The translation of the Bindings header.
    san: *std.Build.Module,
    /// The translation of the header's system includes alone, with the
    /// same options.
    system: *std.Build.Module,
};

/// The system headers that a translation sees besides aro's own.
pub const System = union(enum) {
    /// None. The host query is explicit, so translate-c reads no native
    /// system paths.
    host,
    /// The NDK's system include directories of one Android target.
    android: struct {
        api_level: u32,
        include_dirs: [2][]const u8,
    },
};

/// Translates the Bindings header and the stub of its system includes for
/// `target`. `Translator` is the Translator type of the translate_c
/// package, and `translate_c` its dependency.
pub fn translate(
    b: *std.Build,
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    system: System,
) Translation {
    const stub = b.addWriteFiles().add("system.h", system_stub);

    return .{
        .san = translateFile(
            b,
            Translator,
            translate_c,
            target,
            system,
            "san",
            b.path(header_path),
        ),
        .system = translateFile(
            b,
            Translator,
            translate_c,
            target,
            system,
            "system",
            stub,
        ),
    };
}

/// Translates the C source `source` for `target` and returns the module
/// of the translation, named `name`.
fn translateFile(
    b: *std.Build,
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    system: System,
    name: []const u8,
    source: std.Build.LazyPath,
) *std.Build.Module {
    const extra_args: []const []const u8 = switch (system) {
        .host => &.{},
        // The pinned aro predefines only __ANDROID__, and NDK r30
        // sys/cdefs.h rejects a translation without the level.
        .android => |android| b.graph.dupeStrings(&.{
            b.fmt("-D__ANDROID_API__={d}", .{android.api_level}),
            b.fmt("-D__ANDROID_MIN_SDK_VERSION__={d}", .{android.api_level}),
        }),
    };

    const translator = Translator.init(translate_c, .{
        .name = name,
        .c_source_file = source,
        .target = target,
        // The translation never follows the build mode: for ReleaseSafe,
        // translate-c passes -O2 and -D_FORTIFY_SOURCE=2 to aro.
        .optimize = .debug,
        // A module that links libc turns every compile in its graph into
        // a libc compile. Without libc, translate-c takes no include
        // directory from a libc description, so the NDK directories come
        // as system include paths below.
        .link_libc = false,
        .extra_args = extra_args,
    });

    switch (system) {
        .host => {},
        .android => |android| for (android.include_dirs) |dir| {
            translator.addSystemIncludePath(b.graph.cwdRelativePath(dir));
        },
    }

    return translator.mod;
}

/// Returns a module whose root declares the Bindings table as `table`
/// and the header as `header`. @embedFile reads only files inside the
/// module's directory, so the root and copies of both files live in one
/// directory of the build cache.
pub fn bindingsModule(b: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();

    _ = files.addCopyFile(b.path(table_path), "abi.tsv");
    _ = files.addCopyFile(b.path(header_path), "san.h");

    const root = files.add("bindings.zig",
        \\//! The Bindings table and header, copied from share/bindings/.
        \\
        \\pub const table = @embedFile("abi.tsv");
        \\pub const header = @embedFile("san.h");
        \\
    );

    return b.createModule(.{ .root_source_file = root });
}
