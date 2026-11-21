//! The one table of what a San artifact takes from the Android system and
//! what it offers in return: the import allowlist, the allowed libraries,
//! and the export set of each artifact kind. The link derives its version
//! script from this table, and the inspection tool checks the linked
//! artifact against it, so the two cannot drift apart.
//!
//! The list is closed. Each import entry names its category, its
//! library, its consumer, and its reason, and a symbol or a library joins
//! only with a consumer and a reason that justify it, never as a side
//! effect of a link. A library names the artifacts that need it, and an
//! artifact may import only from the libraries that it needs. The file
//! is pure data without the build API, so build.zig and the host tool can
//! both import it.

const std = @import("std");

/// The kind of system service that an import provides.
pub const Category = enum {
    jump_recovery,
    accounted_heap,
    memory_primitives,
    stack_protection,
    fatal_termination,
    android_pixel_copy,
};

/// One row of the import allowlist: the symbols of one category, the
/// library that holds them, the code that needs them, and why.
pub const Entry = struct {
    category: Category,
    symbols: []const []const u8,
    /// The name of the entry of `libraries` that holds the symbols.
    library: []const u8,
    consumer: []const u8,
    reason: []const u8,
};

/// Bionic, the one library that every artifact needs.
pub const libc = "libc.so";
const jnigraphics = "libjnigraphics.so";

/// The import allowlist. An undefined dynamic symbol of a San artifact
/// must be one of these symbols, from a library that the artifact needs.
pub const imports = [_]Entry{
    .{
        .category = .jump_recovery,
        .symbols = &.{ "_setjmp", "_longjmp" },
        .library = libc,
        .consumer = "San's C containment adapters, the only callers, " ++
            "because libpng built without SETJMP holds no jump code",
        .reason = "Contain C codec errors and cancellation inside a " ++
            "codec call: the adapter's frame calls _setjmp before the " ++
            "codec call, and San's error callback, which never returns, " ++
            "calls _longjmp back to it. The underscore pair saves no " ++
            "signal mask, so it makes no system call.",
    },
    .{
        .category = .accounted_heap,
        .symbols = &.{ "malloc", "free" },
        .library = libc,
        .consumer = "San's accounted allocator, the one route of every " ++
            "Zig and codec allocation",
        .reason = "Bionic's malloc and free back the accounted heap and " ++
            "bring Bionic's heap hardening. libpng's fallback for a " ++
            "missing allocation callback also references both; San " ++
            "always supplies the callbacks.",
    },
    .{
        .category = .memory_primitives,
        .symbols = &.{ "memcpy", "memmove", "memset", "memcmp" },
        .library = libc,
        .consumer = "Zig and C code generation, which emits these calls",
        .reason = "The compilers lower copies, fills, and comparisons " ++
            "to these calls. When the link needs any compiler_rt " ++
            "routine, compiler_rt's hidden copies bind every call site " ++
            "instead, and the imports disappear.",
    },
    .{
        .category = .stack_protection,
        .symbols = &.{"__stack_chk_fail"},
        .library = libc,
        .consumer = "The strong stack protector of every C compile",
        .reason = "The failure path of the canary check. Both ABIs read " ++
            "the guard from thread-local storage at offset 0x28, so no " ++
            "artifact imports __stack_chk_guard. When compiler_rt is " ++
            "linked, its hidden trapping copy binds instead.",
    },
    .{
        .category = .fatal_termination,
        .symbols = &.{ "android_set_abort_message", "abort" },
        .library = libc,
        .consumer = "San's panic handler",
        .reason = "The handler passes the panic message to " ++
            "android_set_abort_message and then calls abort, so the " ++
            "message reaches the tombstone. libpng's png_error and " ++
            "png_chunk_error also reach abort if an error callback " ++
            "returns, because libpng built without SETJMP has no jump " ++
            "of its own; San's error callback never returns.",
    },
    .{
        .category = .android_pixel_copy,
        .symbols = &.{
            "AndroidBitmap_getInfo",
            "AndroidBitmap_getDataSpace",
            "AndroidBitmap_lockPixels",
            "AndroidBitmap_unlockPixels",
        },
        .library = jnigraphics,
        .consumer = "San's JNI layer, in the copy operation only",
        .reason = "The copy writes covered rows of a lease into a " ++
            "Bitmap of the caller. It reads the Bitmap's description, " ++
            "locks the pixels for the one call, and unlocks them, which " ++
            "marks the Bitmap changed. No other route reaches the " ++
            "pixels of a Bitmap without a copy through a Java array.",
    },
};

/// A shared library that a San artifact may name in DT_NEEDED.
pub const Library = struct {
    name: []const u8,
    /// The one kind of artifact that needs the library, or null when
    /// every artifact needs it.
    only: ?Artifact,
    reason: []const u8,

    /// Reports whether `artifact` needs the library.
    pub fn serves(library: Library, artifact: Artifact) bool {
        return library.only == null or library.only == artifact;
    }
};

/// The allowed libraries. A San artifact needs exactly those that serve
/// it, and the link takes their API-level stubs and no other library.
pub const libraries = [_]Library{
    .{
        .name = libc,
        .only = null,
        .reason = "Bionic, which every Android device supplies, holds " ++
            "every allowed import except the Android bitmap functions.",
    },
    .{
        .name = jnigraphics,
        .only = .san,
        .reason = "The NDK library of the Android bitmap functions, which " ++
            "the copy operation of the San library imports. A test " ++
            "library has no JNI layer, so it never needs it.",
    },
};

/// A kind of linked Android artifact, with the entry points it exports.
pub const Artifact = enum {
    /// The San library that the Android app loads. JNI is its one entry
    /// point.
    san,
    /// The test library of the PNG decoder's device tests. It has the
    /// San library's link shape, with one test entry point in place of
    /// JNI.
    png_device_test,
    /// The test library of the C ABI's device tests. It has the San
    /// library's link shape and exports the functions of the Bindings
    /// header in place of JNI.
    abi_device_test,
    /// The test library of the stack protector's device test. It has the
    /// San library's link shape, with one test entry point in place of
    /// JNI.
    canary_device_test,

    /// Returns the names that the artifact exports, and nothing else.
    pub fn exports(artifact: Artifact) []const []const u8 {
        return switch (artifact) {
            .san => &.{"JNI_OnLoad"},
            .png_device_test => &.{"san_png_device_test"},
            .abi_device_test => &.{
                "san_binding_establish",
                "san_engine_create",
                "san_engine_shutdown",
                "san_engine_counters",
                "san_content_open",
                "san_content_feed",
                "san_content_close",
                "san_job_request",
                "san_job_step",
                "san_job_cancel",
                "san_job_release",
                "san_output_copy",
                "san_output_release",
            },
            .canary_device_test => &.{"san_canary_test"},
        };
    }
};

/// Returns the allowlist entry that admits `symbol` as an import of
/// `artifact`, or null when the allowlist does not name the symbol or
/// the artifact does not need the symbol's library.
pub fn importEntry(artifact: Artifact, symbol: []const u8) ?*const Entry {
    for (&imports) |*entry| {
        if (!needs(artifact, entry.library)) continue;

        for (entry.symbols) |allowed| {
            if (std.mem.eql(u8, allowed, symbol)) return entry;
        }
    }

    return null;
}

/// Reports whether `artifact` needs the library `name`.
pub fn needs(artifact: Artifact, name: []const u8) bool {
    for (libraries) |library| {
        if (!std.mem.eql(u8, library.name, name)) continue;

        return library.serves(artifact);
    }

    return false;
}

/// Returns the linker version script of `artifact`. Its one version node
/// has no name, so the exports stay unversioned. The node keeps the
/// declared exports global and makes every other symbol local, so that
/// LTO and section collection can drop whatever the exports do not reach.
pub fn versionScript(artifact: Artifact) []const u8 {
    return switch (artifact) {
        inline else => |known| comptime scriptOf(known.exports()),
    };
}

fn scriptOf(comptime names: []const []const u8) []const u8 {
    var text: []const u8 = "{\n  global:\n";

    for (names) |name| {
        // The script grammar reads `*`, `?`, `[`, `;`, braces, and spaces
        // in a name as patterns or syntax, so an export that is not a C
        // identifier could export more than itself.
        if (!isIdentifier(name)) {
            @compileError("the export '" ++ name ++ "' is not a C " ++
                "identifier, so a version script cannot name it exactly");
        }

        text = text ++ "    " ++ name ++ ";\n";
    }

    return text ++ "  local:\n    *;\n};\n";
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;

    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;

    for (name[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }

    return true;
}

const testing = std.testing;

test "each category has one entry with symbols, a consumer, and a reason" {
    for (std.enums.values(Category)) |category| {
        var count: usize = 0;

        for (imports) |entry| {
            if (entry.category == category) count += 1;
        }

        try testing.expectEqual(1, count);
    }

    for (imports) |entry| {
        try testing.expect(entry.symbols.len != 0);
        try testing.expect(entry.consumer.len != 0);
        try testing.expect(entry.reason.len != 0);
    }
}

test "each entry names a library that the San library needs" {
    for (imports) |entry| {
        try testing.expect(needs(.san, entry.library));
    }
}

fn occurrences(symbol: []const u8) usize {
    var count: usize = 0;

    for (imports) |entry| {
        for (entry.symbols) |candidate| {
            if (std.mem.eql(u8, candidate, symbol)) count += 1;
        }
    }

    return count;
}

test "the allowlist holds fifteen distinct imports" {
    var count: usize = 0;

    for (imports) |entry| {
        for (entry.symbols) |symbol| {
            const found = importEntry(.san, symbol).?;

            count += 1;

            try testing.expectEqual(1, occurrences(symbol));
            try testing.expectEqual(entry.category, found.category);
        }
    }

    try testing.expectEqual(15, count);
}

test "only the San library may import the Android bitmap functions" {
    const test_libraries = [_]Artifact{
        .png_device_test,
        .abi_device_test,
        .canary_device_test,
    };

    for (imports) |entry| {
        const shared = entry.category != .android_pixel_copy;

        for (entry.symbols) |symbol| {
            for (test_libraries) |artifact| {
                const admitted = importEntry(artifact, symbol) != null;

                try testing.expectEqual(shared, admitted);
            }
        }
    }

    const copy = importEntry(.san, "AndroidBitmap_lockPixels").?;

    try testing.expectEqual(.android_pixel_copy, copy.category);
    try testing.expectEqual(4, copy.symbols.len);
}

test "the allowlist refuses neighbors of its entries and forbidden calls" {
    const refused = [_][]const u8{
        "setjmp",
        "longjmp",
        "sigsetjmp",
        "calloc",
        "realloc",
        "posix_memalign",
        "__stack_chk_guard",
        "__memcpy_chk",
        "getenv",
        "dlopen",
        "dl_iterate_phdr",
        "__android_log_print",
        "pow",
        "AndroidBitmap_getHardwareBuffer",
        "AndroidBitmap_compress",
        "",
    };

    for (std.enums.values(Artifact)) |artifact| {
        for (refused) |symbol| {
            try testing.expectEqual(null, importEntry(artifact, symbol));
        }

        const jump = importEntry(artifact, "_setjmp").?;

        try testing.expectEqual(.jump_recovery, jump.category);
    }
}

test "every artifact needs libc.so, and the San library libjnigraphics.so" {
    try testing.expectEqual(2, libraries.len);

    for (std.enums.values(Artifact)) |artifact| {
        try testing.expect(needs(artifact, "libc.so"));
        try testing.expect(!needs(artifact, "libm.so"));
        try testing.expect(!needs(artifact, "libdl.so"));
        try testing.expect(!needs(artifact, "liblog.so"));
        try testing.expect(!needs(artifact, "libandroid.so"));
        try testing.expect(!needs(artifact, "libnativewindow.so"));
        try testing.expect(!needs(artifact, "libc.so.6"));

        const copies = artifact == .san;

        try testing.expectEqual(copies, needs(artifact, "libjnigraphics.so"));
    }
}

test "each artifact exports its entry points and nothing else" {
    try testing.expectEqual(1, Artifact.san.exports().len);
    try testing.expectEqualStrings("JNI_OnLoad", Artifact.san.exports()[0]);

    try testing.expectEqual(1, Artifact.png_device_test.exports().len);

    try testing.expectEqualStrings(
        "san_png_device_test",
        Artifact.png_device_test.exports()[0],
    );

    try testing.expectEqual(13, Artifact.abi_device_test.exports().len);

    for (Artifact.abi_device_test.exports()) |name| {
        try testing.expect(std.mem.startsWith(u8, name, "san_"));
    }

    try testing.expectEqual(1, Artifact.canary_device_test.exports().len);

    try testing.expectEqualStrings(
        "san_canary_test",
        Artifact.canary_device_test.exports()[0],
    );
}

test "no artifact exports a name that it may import from the system" {
    for (std.enums.values(Artifact)) |artifact| {
        for (artifact.exports()) |name| {
            try testing.expectEqual(null, importEntry(.san, name));
            try testing.expect(isIdentifier(name));
        }
    }
}

test "the version script keeps the exports global and hides the rest" {
    try testing.expectEqualStrings(
        \\{
        \\  global:
        \\    san_png_device_test;
        \\  local:
        \\    *;
        \\};
        \\
    , versionScript(.png_device_test));

    try testing.expectEqualStrings(
        \\{
        \\  global:
        \\    JNI_OnLoad;
        \\  local:
        \\    *;
        \\};
        \\
    , versionScript(.san));
}

test "an export must be a C identifier" {
    const accepted = [_][]const u8{ "JNI_OnLoad", "_start", "a1" };

    const rejected = [_][]const u8{ "", "1a", "san_*", "a b", "a;", "{" };

    for (accepted) |name| try testing.expect(isIdentifier(name));
    for (rejected) |name| try testing.expect(!isIdentifier(name));
}
