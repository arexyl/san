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
//! San implements the engine lifecycle. It issues no content, job, or
//! lease handle, so each function that takes one rejects every handle.
//! san_engine_counters and san_content_open check their arguments and
//! then fail as SAN_STATUS_ENGINE_FAILURE.

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

pub export fn san_engine_counters(
    engine: san.san_handle,
    reset_peak: i32,
    _: [*c]i64,
) san.san_status {
    return counters(&process, engine, reset_peak);
}

pub export fn san_content_open(
    engine: san.san_handle,
    content: [*c]san.san_handle,
) san.san_status {
    return openContent(&process, engine, content);
}

pub export fn san_content_feed(
    _: san.san_handle,
    _: i64,
    _: [*c]const u8,
    _: i32,
    _: i32,
) san.san_status {
    return san.SAN_STATUS_INVALID_HANDLE;
}

pub export fn san_content_close(_: san.san_handle) san.san_status {
    return san.SAN_STATUS_INVALID_HANDLE;
}

pub export fn san_job_request(
    _: san.san_handle,
    _: [*c]const san.san_output_request,
    job: [*c]san.san_handle,
) san.san_status {
    job.* = san.SAN_NO_HANDLE;

    return san.SAN_STATUS_INVALID_HANDLE;
}

pub export fn san_job_step(_: san.san_handle, _: [*c]i64) san.san_status {
    return san.SAN_STATUS_INVALID_HANDLE;
}

pub export fn san_job_cancel(_: san.san_handle) san.san_status {
    return san.SAN_STATUS_INVALID_HANDLE;
}

pub export fn san_job_release(_: san.san_handle) san.san_status {
    return san.SAN_STATUS_INVALID_HANDLE;
}

pub export fn san_output_copy(
    _: san.san_handle,
    _: i32,
    _: i32,
    _: [*c]u8,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
) san.san_status {
    return san.SAN_STATUS_INVALID_HANDLE;
}

pub export fn san_output_release(_: san.san_handle) san.san_status {
    return san.SAN_STATUS_INVALID_HANDLE;
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

    const handle = Engine.create(
        &state.binding,
        &state.slot,
        backing,
        engineLimits(limits),
    ) catch |err| return statusOf(err);

    out.* = @bitCast(@backingInt(handle));

    return san.SAN_STATUS_OK;
}

/// Returns the limits of the header as the engine module takes them.
fn engineLimits(limits: san.san_engine_limits) Engine.Limits {
    var converted: Engine.Limits = undefined;

    inline for (Engine.Limits.names) |name| {
        @field(converted, name) = @field(limits, name);
    }

    return converted;
}

comptime {
    const declared = @typeInfo(san.san_engine_limits).@"struct".field_names;

    // The conversion reads every limit of the engine module from the
    // header's struct, so equal counts leave no limit of the header out.
    if (declared.len != Engine.Limits.names.len) {
        @compileError("san_engine_limits and the engine module name " ++
            "different limits");
    }
}

fn shutdown(state: *Process, engine: san.san_handle) san.san_status {
    Engine.shutdown(&state.slot, engineHandle(engine)) catch |err| {
        return statusOf(err);
    };

    return san.SAN_STATUS_OK;
}

/// Checks the arguments of a counters read in `state`, in the order of
/// the header.
fn counters(
    state: *Process,
    engine: san.san_handle,
    reset_peak: i32,
) san.san_status {
    const resolved = Engine.resolve(&state.slot, engineHandle(engine));

    if (resolved) |_| {} else |err| switch (err) {
        error.InvalidHandle => return san.SAN_STATUS_INVALID_HANDLE,
        // The read works while the engine shuts down.
        error.Closed => {},
    }

    if (reset_peak != 0 and reset_peak != 1) {
        return san.SAN_STATUS_BINDING_MISMATCH;
    }

    return san.SAN_STATUS_ENGINE_FAILURE;
}

/// Checks the engine of a content opening in `state` and writes
/// SAN_NO_HANDLE to `out`.
fn openContent(
    state: *Process,
    engine: san.san_handle,
    out: *san.san_handle,
) san.san_status {
    out.* = san.SAN_NO_HANDLE;

    _ = Engine.resolve(&state.slot, engineHandle(engine)) catch |err| {
        return statusOf(err);
    };

    return san.SAN_STATUS_ENGINE_FAILURE;
}

fn engineHandle(engine: san.san_handle) Engine.Handle {
    return @fromBackingInt(@as(u64, @bitCast(engine)));
}

/// A failure of the engine module that a function above can meet.
const Failure = Engine.CreateError || error{ InvalidHandle, Closed };

/// Returns the status of `failure`. Each category of the engine module
/// has the status of the same name.
fn statusOf(failure: Failure) san.san_status {
    return switch (failure) {
        error.BindingMismatch => san.SAN_STATUS_BINDING_MISMATCH,
        error.BudgetExceeded => san.SAN_STATUS_BUDGET_EXCEEDED,
        error.AllocationFailed => san.SAN_STATUS_ALLOCATION_FAILED,
        error.EngineFailure => san.SAN_STATUS_ENGINE_FAILURE,
        error.InvalidHandle => san.SAN_STATUS_INVALID_HANDLE,
        error.Closed => san.SAN_STATUS_CLOSED,
    };
}

const testing = std.testing;
const TestBacking = Heap.TestBacking;

/// Limits that admit every engine of the tests below.
const roomy: san.san_engine_limits = uniform(1 << 20);

/// Returns limits that all hold `value`.
fn uniform(value: i64) san.san_engine_limits {
    var limits: san.san_engine_limits = undefined;

    inline for (Engine.Limits.names) |name| @field(limits, name) = value;

    return limits;
}

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
        var limits = roomy;

        limits.aggregate_budget_bytes = bytes;

        try expectRefused(&state, limits, san.SAN_STATUS_BUDGET_EXCEEDED);
    }
}

test "each limit of the header reaches the engine" {
    var state = established();

    inline for (Engine.Limits.names) |name| {
        var limits = roomy;

        @field(limits, name) = 0;

        try expectRefused(&state, limits, san.SAN_STATUS_BUDGET_EXCEEDED);
    }

    inline for (Engine.Limits.names, 0..) |name, index| {
        var limits = uniform(0);

        @field(limits, name) = 1 << 20;

        const converted = engineLimits(limits);

        inline for (Engine.Limits.names, 0..) |other, other_index| {
            const expected: i64 = if (index == other_index) 1 << 20 else 0;

            try testing.expectEqual(expected, @field(converted, other));
        }
    }
}

test "the counters read and the content opening check their arguments" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);
    var engine = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(&state, test_backing.backing(), roomy, &engine),
    );

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine + 1,
        unwritten,
    };

    for (invalid) |handle| {
        var content = unwritten;

        // The handle decides before the flag does.
        try testing.expectEqual(
            san.SAN_STATUS_INVALID_HANDLE,
            counters(&state, handle, 2),
        );

        try testing.expectEqual(
            san.SAN_STATUS_INVALID_HANDLE,
            openContent(&state, handle, &content),
        );

        try testing.expectEqual(san.SAN_NO_HANDLE, content);
    }

    for ([_]i32{ 2, -1, std.math.maxInt(i32), std.math.minInt(i32) }) |flag| {
        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            counters(&state, engine, flag),
        );
    }

    for ([_]i32{ 0, 1 }) |flag| {
        try testing.expectEqual(
            san.SAN_STATUS_ENGINE_FAILURE,
            counters(&state, engine, flag),
        );
    }

    var content = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        openContent(&state, engine, &content),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, content);

    // No call kept anything: the engine holds its own state alone.
    try testing.expectEqual(1, test_backing.blocks);
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        counters(&state, engine, 0),
    );
}

test "every content, job, and lease handle is invalid" {
    const request: san.san_output_request = .{
        .left = 0,
        .top = 0,
        .right = 0,
        .bottom = 0,
        .max_output_width = 0,
    };

    const byte: u8 = 0;

    const handles = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        1,
        -1,
        unwritten,
        std.math.minInt(i64),
    };

    for (handles) |handle| {
        var job = unwritten;
        var report: [san.SAN_JOB_REPORT_LENGTH]i64 = @splat(unwritten);
        var pixel: [4]u8 = @splat(0x5a);

        const statuses = [_]san.san_status{
            san_content_feed(handle, 0, &byte, 1, 0),
            san_content_close(handle),
            san_job_request(handle, &request, &job),
            san_job_step(handle, &report),
            san_job_cancel(handle),
            san_job_release(handle),
            san_output_copy(handle, 0, 1, &pixel, 1, 1, 4, 0, 0),
            san_output_release(handle),
        };

        for (statuses) |status| {
            try testing.expectEqual(san.SAN_STATUS_INVALID_HANDLE, status);
        }

        try testing.expectEqual(san.SAN_NO_HANDLE, job);
        try testing.expectEqual(@as([4]u8, @splat(0x5a)), pixel);

        for (report) |element| try testing.expectEqual(unwritten, element);
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
        .{ error.Closed, san.SAN_STATUS_CLOSED },
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

    var counted: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(unwritten);
    var content = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        san_engine_counters(engine, 0, &counted),
    );

    for (counted) |element| try testing.expectEqual(unwritten, element);

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        san_content_open(engine, &content),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, content);
    try testing.expectEqual(san.SAN_STATUS_OK, san_engine_shutdown(engine));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_engine_shutdown(engine),
    );
}
