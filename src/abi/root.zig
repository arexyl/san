//! The C ABI of San: the functions of the Bindings header, implemented
//! against its translation. This is the trust boundary of the library.
//! Each function checks its arguments once, calls the engine module with
//! validated types, and maps the outcome to one status.
//!
//! A process has one binding flag and one engine slot, and both live
//! here. Every function keeps the name and the prototype of the header.
//! The check below compares each one with the translation, and requires
//! one for every function that the translation declares, so a function
//! that drifts from the pinned header fails the compile.
//!
//! The pinned header declares the engine lifecycle only.

const std = @import("std");
const san = @import("san");
const Engine = @import("engine");

const Heap = Engine.Heap;

/// The binding flag and the engine slot of one process.
const Process = struct {
    binding: Engine.Binding = .{},
    slot: Engine.Slot = .{},
};

/// The state of this process. The exported functions work on it, and
/// the tests run the same code on states of their own.
var process: Process = .{};

pub export fn san_binding_establish(abi_version: i32) san.san_status {
    return establish(&process, abi_version);
}

pub export fn san_engine_create(
    limits: [*c]const san.san_engine_limits,
    engine: [*c]san.san_handle,
) san.san_status {
    return create(&process, .system, limits.*, engine);
}

pub export fn san_engine_shutdown(engine: san.san_handle) san.san_status {
    return shutdown(&process, engine);
}

comptime {
    // The translation holds several hundred declarations.
    @setEvalBranchQuota(100_000);

    var declared: usize = 0;

    for (@typeInfo(san).@"struct".decl_names) |name| {
        if (!isFunction(san, name)) continue;

        declared += 1;

        if (!isFunction(@This(), name)) {
            @compileError("the header declares " ++ name ++
                ", which San does not implement");
        }

        const Declared = @TypeOf(@field(san, name));
        const Implemented = @TypeOf(@field(@This(), name));

        if (Implemented != Declared) {
            @compileError(name ++ " is " ++ @typeName(Implemented) ++
                ", and the header declares " ++ @typeName(Declared));
        }
    }

    // A translation that showed no function would leave nothing to
    // compare, and the loop above would pass.
    if (declared == 0) {
        @compileError("the translation of the header declares no function");
    }

    for (@typeInfo(@This()).@"struct".decl_names) |name| {
        if (isFunction(@This(), name) and !isFunction(san, name)) {
            @compileError("San implements " ++ name ++
                ", which the header does not declare");
        }
    }
}

/// Reports whether `name` is a function of the header in `container`.
/// The translation also holds the declarations of the header's system
/// includes, and only the header's own names start with `san_`.
fn isFunction(comptime container: type, comptime name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "san_")) return false;
    if (!@hasDecl(container, name)) return false;

    return @typeInfo(@TypeOf(@field(container, name))) == .@"fn";
}

fn establish(state: *Process, abi_version: i32) san.san_status {
    if (abi_version != san.SAN_ABI_VERSION) {
        return san.SAN_STATUS_BINDING_MISMATCH;
    }

    state.binding.establish();

    return san.SAN_STATUS_OK;
}

/// Creates an engine in `state` with memory from `backing`. It writes
/// the handle of the engine to `out`, or SAN_NO_HANDLE on a failure.
fn create(
    state: *Process,
    backing: Heap.Backing,
    limits: san.san_engine_limits,
    out: *san.san_handle,
) san.san_status {
    out.* = san.SAN_NO_HANDLE;

    const handle = Engine.create(&state.binding, &state.slot, backing, .{
        .aggregate_budget_bytes = limits.aggregate_budget_bytes,
    }) catch |err| return statusOf(err);

    out.* = @bitCast(@backingInt(handle));

    return san.SAN_STATUS_OK;
}

fn shutdown(state: *Process, engine: san.san_handle) san.san_status {
    const handle: Engine.Handle = @fromBackingInt(@as(u64, @bitCast(engine)));

    Engine.shutdown(&state.slot, handle) catch |err| return statusOf(err);

    return san.SAN_STATUS_OK;
}

/// A failure of the engine module that a function above can meet.
const Failure = Engine.CreateError || error{InvalidHandle};

/// Returns the status of `failure`. Each category of the engine module
/// has the status of the same name.
fn statusOf(failure: Failure) san.san_status {
    return switch (failure) {
        error.BindingMismatch => san.SAN_STATUS_BINDING_MISMATCH,
        error.BudgetExceeded => san.SAN_STATUS_BUDGET_EXCEEDED,
        error.AllocationFailed => san.SAN_STATUS_ALLOCATION_FAILED,
        error.EngineFailure => san.SAN_STATUS_ENGINE_FAILURE,
        error.InvalidHandle => san.SAN_STATUS_INVALID_HANDLE,
    };
}

const testing = std.testing;
const TestBacking = Heap.TestBacking;

/// Limits that admit every engine of the tests below.
const roomy: san.san_engine_limits = .{ .aggregate_budget_bytes = 1 << 20 };

/// A value that no creation writes, so that a test sees whether a call
/// wrote its output.
const unwritten: san.san_handle = 0x5a5a_5a5a_5a5a_5a5a;

/// Returns a state whose binding is established.
fn established() Process {
    var state: Process = .{};

    state.binding.establish();

    return state;
}

/// Checks that a creation in `state` under `limits` fails as `status`,
/// writes SAN_NO_HANDLE, and leaves no block in the backing.
fn expectRefused(
    state: *Process,
    limits: san.san_engine_limits,
    status: san.san_status,
) !void {
    var test_backing: TestBacking = .init(testing.allocator);
    var engine = unwritten;

    try testing.expectEqual(
        status,
        create(state, test_backing.backing(), limits, &engine),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, engine);
    try testing.expectEqual(0, test_backing.blocks);
}

test "the binding needs the exact ABI version" {
    var state: Process = .{};

    const others = [_]i32{
        san.SAN_ABI_VERSION + 1,
        san.SAN_ABI_VERSION - 1,
        std.math.maxInt(i32),
        std.math.minInt(i32),
    };

    for (others) |version| {
        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            establish(&state, version),
        );

        try testing.expect(!state.binding.established());
    }

    try expectRefused(&state, roomy, san.SAN_STATUS_BINDING_MISMATCH);

    for (0..2) |_| {
        try testing.expectEqual(
            san.SAN_STATUS_OK,
            establish(&state, san.SAN_ABI_VERSION),
        );
    }

    try testing.expect(state.binding.established());

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        establish(&state, san.SAN_ABI_VERSION + 1),
    );

    try testing.expect(state.binding.established());
}

test "limits that admit nothing fail as BudgetExceeded" {
    var state = established();

    for ([_]i64{ 0, -1, std.math.minInt(i64), 1 }) |bytes| {
        try expectRefused(
            &state,
            .{ .aggregate_budget_bytes = bytes },
            san.SAN_STATUS_BUDGET_EXCEEDED,
        );
    }
}

test "a second engine fails as BudgetExceeded and leaves the first" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);
    var engine = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(&state, test_backing.backing(), roomy, &engine),
    );

    try testing.expect(engine != san.SAN_NO_HANDLE);
    try expectRefused(&state, roomy, san.SAN_STATUS_BUDGET_EXCEEDED);
    try testing.expectEqual(1, test_backing.blocks);
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

test "a refused allocation fails as AllocationFailed" {
    var state = established();

    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });

    var test_backing: TestBacking = .init(failing.allocator());
    var engine = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_ALLOCATION_FAILED,
        create(&state, test_backing.backing(), roomy, &engine),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, engine);

    // The failure released the slot, so the next creation succeeds.
    var second_backing: TestBacking = .init(testing.allocator);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(&state, second_backing.backing(), roomy, &engine),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
}

test "a shutdown ends the engine and its handle" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);
    var first = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(&state, test_backing.backing(), roomy, &first),
    );

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        first + 1,
        -first,
        unwritten,
        std.math.minInt(i64),
    };

    for (invalid) |handle| {
        try testing.expectEqual(
            san.SAN_STATUS_INVALID_HANDLE,
            shutdown(&state, handle),
        );
    }

    try testing.expectEqual(1, test_backing.blocks);
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, first));
    try testing.expectEqual(0, test_backing.blocks);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        shutdown(&state, first),
    );

    var second = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(&state, test_backing.backing(), roomy, &second),
    );

    try testing.expect(second != first);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        shutdown(&state, first),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, second));
}

test "each failure has the status of its category" {
    const expected = [_]struct { Failure, san.san_status }{
        .{ error.BindingMismatch, san.SAN_STATUS_BINDING_MISMATCH },
        .{ error.BudgetExceeded, san.SAN_STATUS_BUDGET_EXCEEDED },
        .{ error.AllocationFailed, san.SAN_STATUS_ALLOCATION_FAILED },
        .{ error.EngineFailure, san.SAN_STATUS_ENGINE_FAILURE },
        .{ error.InvalidHandle, san.SAN_STATUS_INVALID_HANDLE },
    };

    try testing.expectEqual(
        @typeInfo(Failure).error_set.error_names.?.len,
        expected.len,
    );

    for (expected) |pair| {
        try testing.expectEqual(pair[1], statusOf(pair[0]));
        try testing.expect(pair[1] < 0);
    }
}

// The one test on the state of the process: the exported functions in
// the order of a caller, on the system heap.
test "the exported functions run the lifecycle of the process" {
    var engine = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        san_engine_create(&roomy, &engine),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, engine);

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        san_binding_establish(san.SAN_ABI_VERSION + 1),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_binding_establish(san.SAN_ABI_VERSION),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_engine_create(&roomy, &engine),
    );

    try testing.expect(engine != san.SAN_NO_HANDLE);

    var second = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        san_engine_create(&roomy, &second),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, second);
    try testing.expectEqual(san.SAN_STATUS_OK, san_engine_shutdown(engine));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_engine_shutdown(engine),
    );
}
