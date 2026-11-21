//! The link shape of San's Android libraries: the San library and every
//! test library that stands in for it, so that each test library shows
//! the imports, the libraries, and the layout that the San library gets.
//!
//! - No module of the library's graph links libc. Bionic comes in only as
//!   the API-level stub of libc.so, by its path, so the library takes no
//!   NDK runtime object such as crtbegin_so.o and needs only libc.so.
//! - Every C source of the library's graph takes the hardening header.
//! - `-z defs`, so that an unresolved symbol fails the link instead of
//!   becoming an unversioned import.
//! - LOAD segments aligned to the profile's page size of 16 KiB on both
//!   ABIs, so that the library maps on 16 KiB pages. LLD's default is
//!   64 KiB on arm64-v8a and 4 KiB on x86_64.
//! - One section per function and object, and the collection of unused
//!   sections. These settings reach only the library's own Zig compile;
//!   the C archives that it links pass the section flags themselves.
//! - LLVM and LLD, selected explicitly. Without the selection, Zig 0.17.0
//!   builds x86_64 Debug with its own backend and ELF linker, whose output
//!   has no PT_GNU_RELRO.
//! - Link-time optimization across the library's Zig code and the C
//!   archives that it links, which carry LLVM bitcode for it. The link
//!   then generates all of the code at once, inlines across the boundary
//!   between the two languages, and drops what the exports do not reach.
//! - A version script from the export set that allowlist.zig declares for
//!   the artifact: the exports stay global, and every other symbol becomes
//!   local, so that the link can drop what the exports do not reach.

const std = @import("std");
const allowlist = @import("allowlist.zig");
const codecs = @import("codecs.zig");
const ndk = @import("ndk.zig");
const profile = @import("profile.zig");

/// A San library to link.
pub const Options = struct {
    /// The library's name without the `lib` prefix and the `.so` suffix.
    name: []const u8,
    /// The library's root module, with its imports and C archives
    /// attached, for an Android target.
    root_module: *std.Build.Module,
    /// The kind of the library, which declares its exports.
    artifact: allowlist.Artifact,
    /// The NDK root of the target.
    ndk: ndk.Root,
};

/// Adds the shared library of `options` in San's link shape.
pub fn add(b: *std.Build, options: Options) *std.Build.Step.Compile {
    const graph = moduleGraph(b, options.root_module);

    for (graph.keys(), graph.values()) |module, name| {
        if (module.link_libc orelse false) std.debug.panic(
            "the module '{s}' of the San library {s} links libc; no " ++
                "module of a San library may set link_libc = true",
            .{ name, options.name },
        );

        codecs.requireHardening(module, name);
    }

    options.root_module.addObjectFile(
        b.graph.cwdRelativePath(options.ndk.libc_stub),
    );

    const library = b.addLibrary(.{
        .linkage = .dynamic,
        .name = options.name,
        .root_module = options.root_module,
        .use_llvm = true,
        .use_lld = true,
    });

    library.link_z_defs = true;
    library.link_z_max_page_size = profile.page_size;
    library.link_function_sections = true;
    library.link_data_sections = true;
    library.link_gc_sections = true;
    library.lto = .full;

    const script = b.addWriteFiles().add(
        b.fmt("{s}.map", .{options.name}),
        allowlist.versionScript(options.artifact),
    );

    library.setVersionScript(script);

    return library;
}

/// The modules of a library's graph, each with the name under which the
/// graph first reached it.
const Graph = std.array_hash_map.Auto(*std.Build.Module, []const u8);

/// Returns every module of the graph of `root`, through its imports and
/// the C archives that it links, in the order of a breadth-first walk.
/// Zig 0.17.0 links libc into a compile when any module of its graph
/// does, and translate-c creates its modules with link_libc = true by
/// default.
fn moduleGraph(b: *std.Build, root: *std.Build.Module) Graph {
    const arena = b.graph.arena;

    var seen: Graph = .empty;

    seen.put(arena, root, "root") catch @panic("OOM");

    var next: usize = 0;

    while (next < seen.count()) : (next += 1) {
        const module = seen.keys()[next];

        const names = module.import_table.keys();
        const imports = module.import_table.values();

        for (names, imports) |name, import| {
            _ = seen.getOrPutValue(arena, import, name) catch @panic("OOM");
        }

        for (module.link_objects.items) |object| switch (object) {
            .other_step => |step| _ = seen.getOrPutValue(
                arena,
                step.root_module,
                step.name,
            ) catch @panic("OOM"),
            else => {},
        };
    }

    return seen;
}
