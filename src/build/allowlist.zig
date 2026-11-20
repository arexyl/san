//! The one table of what a San artifact takes from the Android system and
//! what it offers in return: the import allowlist, the allowed libraries,
//! and the export set of each artifact kind. The link derives its version
//! script from this table, and the inspection tool checks the linked
//! artifact against it, so the two cannot drift apart.
//!
//! The list is closed. Each import entry names its category, its
//! consumer, and its reason, and a symbol or a library joins only with a
//! consumer and a reason that justify it, never as a side effect of a
//! link. The file is pure data without the build API, so build.zig and
//! the host tool can both import it.

const std = @import("std");

/// The kind of system service that an import provides.
pub const Category = enum {
    jump_recovery,
    accounted_heap,
    memory_primitives,
    stack_protection,
    fatal_termination,
};

/// One row of the import allowlist: the symbols of one category, the code
/// that needs them, and why.
pub const Entry = struct {
    category: Category,
    symbols: []const []const u8,
    consumer: []const u8,
    reason: []const u8,
};

/// The import allowlist. An undefined dynamic symbol of a San artifact
/// must be one of these symbols.
pub const imports = [_]Entry{
    .{
        .category = .jump_recovery,
        .symbols = &.{ "_setjmp", "_longjmp" },
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
        .consumer = "Zig and C code generation, which emits these calls",
        .reason = "The compilers lower copies, fills, and comparisons " ++
            "to these calls. When the link needs any compiler_rt " ++
            "routine, compiler_rt's hidden copies bind every call site " ++
            "instead, and the imports disappear.",
    },
    .{
        .category = .stack_protection,
        .symbols = &.{"__stack_chk_fail"},
        .consumer = "The strong stack protector of every C compile",
        .reason = "The failure path of the canary check. Both ABIs read " ++
            "the guard from thread-local storage at offset 0x28, so no " ++
            "artifact imports __stack_chk_guard. When compiler_rt is " ++
            "linked, its hidden trapping copy binds instead.",
    },
    .{
        .category = .fatal_termination,
        .symbols = &.{ "android_set_abort_message", "abort" },
        .consumer = "San's panic handler",
        .reason = "The handler passes the panic message to " ++
            "android_set_abort_message and then calls abort, so the " ++
            "message reaches the tombstone. libpng's png_error and " ++
            "png_chunk_error also reach abort if an error callback " ++
            "returns, because libpng built without SETJMP has no jump " ++
            "of its own; San's error callback never returns.",
    },
};

/// A shared library that a San artifact may name in DT_NEEDED.
pub const Library = struct {
    name: []const u8,
    reason: []const u8,
};

/// The allowed libraries. A San artifact needs exactly these.
pub const libraries = [_]Library{
    .{
        .name = "libc.so",
        .reason = "Bionic, which every Android device supplies, provides " ++
            "each allowed import. San links against its API-level stub " ++
            "and against no other system library.",
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
            },
            .canary_device_test => &.{"san_canary_test"},
        };
    }
};

/// Returns the allowlist entry that admits `symbol` as an import, or null
/// when the allowlist does not name it.
pub fn importEntry(symbol: []const u8) ?*const Entry {
    for (&imports) |*entry| {
        for (entry.symbols) |allowed| {
            if (std.mem.eql(u8, allowed, symbol)) return entry;
        }
    }

    return null;
}

/// Reports whether `name` is an allowed library.
pub fn allowsLibrary(name: []const u8) bool {
    for (libraries) |library| {
        if (std.mem.eql(u8, library.name, name)) return true;
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

fn occurrences(symbol: []const u8) usize {
    var count: usize = 0;

    for (imports) |entry| {
        for (entry.symbols) |candidate| {
            if (std.mem.eql(u8, candidate, symbol)) count += 1;
        }
    }

    return count;
}

test "the allowlist holds eleven distinct imports" {
    var count: usize = 0;

    for (imports) |entry| {
        for (entry.symbols) |symbol| {
            const found = importEntry(symbol).?;

            count += 1;

            try testing.expectEqual(1, occurrences(symbol));
            try testing.expectEqual(entry.category, found.category);
        }
    }

    try testing.expectEqual(11, count);
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
        "",
    };

    for (refused) |symbol| {
        try testing.expectEqual(null, importEntry(symbol));
    }

    const jump = importEntry("_setjmp").?;

    try testing.expectEqual(.jump_recovery, jump.category);
}

test "libc.so is the one allowed library" {
    try testing.expectEqual(1, libraries.len);
    try testing.expect(allowsLibrary("libc.so"));
    try testing.expect(!allowsLibrary("libm.so"));
    try testing.expect(!allowsLibrary("libdl.so"));
    try testing.expect(!allowsLibrary("liblog.so"));
    try testing.expect(!allowsLibrary("libc.so.6"));
}

test "each artifact exports its entry points and nothing else" {
    try testing.expectEqual(1, Artifact.san.exports().len);
    try testing.expectEqualStrings("JNI_OnLoad", Artifact.san.exports()[0]);

    try testing.expectEqual(1, Artifact.png_device_test.exports().len);

    try testing.expectEqualStrings(
        "san_png_device_test",
        Artifact.png_device_test.exports()[0],
    );

    try testing.expectEqual(3, Artifact.abi_device_test.exports().len);

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
            try testing.expectEqual(null, importEntry(name));
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
