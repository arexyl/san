//! The root of the Android object of the engine module, compiled without
//! libc. Zig compiles only what a root references, and an optimizer
//! drops what nothing outside the object can reach. This root therefore
//! exports a thunk for each entry point that the C ABI and the codec
//! callbacks will call, with hidden visibility under names of this check,
//! so that the object holds the engine's code in every mode. A thunk
//! takes the arguments and the result through pointers, so it adds no
//! ABI of its own. Nothing links the object, so these names reach no
//! library, and no check reads its imports yet.
//!
//! The root of a compile owns its panic handler. San's handler belongs
//! to the root of the library, so this root traps instead, and the
//! object holds only what the engine itself references.

const std = @import("std");
const builtin = @import("builtin");
const Engine = @import("engine");

pub const panic = std.debug.no_panic;

comptime {
    if (!builtin.abi.isAndroid()) {
        @compileError("the engine check compiles only for Android");
    }
}

/// The entry points of the engine, by the suffix of their check names.
const entry_points = .{
    .{ "create", Engine.create },
    .{ "shutdown", Engine.shutdown },
    .{ "resolve", Engine.resolve },
    .{ "establish", Engine.Binding.establish },
    .{ "system_backing", systemBacking },
    .{ "heap_alloc", Engine.Heap.alloc },
    .{ "heap_free", Engine.Heap.free },
    .{ "heap_allocator", Engine.Heap.allocator },
};

comptime {
    for (entry_points) |entry| {
        @export(&Thunk(entry[1]).call, .{
            .name = "engine_check_" ++ entry[0],
            .visibility = .hidden,
        });
    }
}

/// Returns the system backing, the one route to its malloc and free.
fn systemBacking() Engine.Heap.Backing {
    return .system;
}

/// A C function that calls `function` with the arguments behind its
/// first pointer and stores the result behind its second.
fn Thunk(comptime function: anytype) type {
    const Function = @TypeOf(function);

    const Arguments = std.meta.ArgsTuple(Function);

    const Result = @typeInfo(Function).@"fn".return_type.?;

    return struct {
        fn call(
            arguments: *const Arguments,
            result: *Result,
        ) callconv(.c) void {
            result.* = @call(.auto, function, arguments.*);
        }
    };
}
