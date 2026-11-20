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
//! San implements the engine lifecycle, the counters read, and the
//! opening and the close of a content. It issues no job and no lease
//! handle, so each function that takes one rejects every handle. The
//! feed and the job request check their content and then fail as
//! SAN_STATUS_ENGINE_FAILURE.

const std = @import("std");
const san = @import("san");
const Engine = @import("engine");

const Content = Engine.Content;
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
    out: [*c]i64,
) san.san_status {
    return counters(
        &process,
        engine,
        reset_peak,
        out[0..san.SAN_ENGINE_COUNTERS_LENGTH],
    );
}

pub export fn san_content_open(
    engine: san.san_handle,
    content: [*c]san.san_handle,
) san.san_status {
    return openContent(&process, engine, content);
}

pub export fn san_content_feed(
    content: san.san_handle,
    _: i64,
    _: [*c]const u8,
    _: i32,
    _: i32,
) san.san_status {
    return unimplementedOn(&process, content);
}

pub export fn san_content_close(content: san.san_handle) san.san_status {
    return closeContent(&process, content);
}

pub export fn san_job_request(
    content: san.san_handle,
    _: [*c]const san.san_output_request,
    job: [*c]san.san_handle,
) san.san_status {
    job.* = san.SAN_NO_HANDLE;

    return unimplementedOn(&process, content);
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

/// The counters report of the header.
const Counters = [san.SAN_ENGINE_COUNTERS_LENGTH]i64;

/// Writes the counters of an engine of `state` to `out`, then starts
/// both peaks again when `reset_peak` is 1. The read works while the
/// engine shuts down, and a failed call writes nothing.
fn counters(
    state: *Process,
    engine: san.san_handle,
    reset_peak: i32,
    out: *Counters,
) san.san_status {
    const found = Engine.resolveClosing(
        &state.slot,
        engineHandle(engine),
    ) catch |err| return statusOf(err);

    if (reset_peak != 0 and reset_peak != 1) {
        return san.SAN_STATUS_BINDING_MISMATCH;
    }

    const ledger = &found.heap.ledger;
    const usage = ledger.usage;

    // San admits no job and no lease, so their counts are 0.
    out.* = @splat(0);

    out[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT] =
        reported(Content.countOpen(found));

    out[san.SAN_ENGINE_COUNTERS_LIVE_BYTES] = reported(usage.live);
    out[san.SAN_ENGINE_COUNTERS_RESERVED_BYTES] = reported(usage.reserved);
    out[san.SAN_ENGINE_COUNTERS_PEAK_LIVE_BYTES] = reported(usage.peak);

    out[san.SAN_ENGINE_COUNTERS_PEAK_COMMITTED_BYTES] =
        reported(usage.peak_committed);

    out[san.SAN_ENGINE_COUNTERS_INPUT_BYTES] = reported(usage.input);
    out[san.SAN_ENGINE_COUNTERS_METADATA_BYTES] = reported(usage.metadata);
    out[san.SAN_ENGINE_COUNTERS_OUTPUT_BYTES] = reported(usage.output);

    if (reset_peak == 1) ledger.resetPeaks();

    return san.SAN_STATUS_OK;
}

/// Returns a count of the ledger as a report carries it. The aggregate
/// budget bounds every count, and it fits an int64.
fn reported(count: u64) i64 {
    return @intCast(count);
}

/// Opens a content in an engine of `state` and writes its handle to
/// `out`, or SAN_NO_HANDLE on a failure.
fn openContent(
    state: *Process,
    engine: san.san_handle,
    out: *san.san_handle,
) san.san_status {
    out.* = san.SAN_NO_HANDLE;

    const found = Engine.resolve(
        &state.slot,
        engineHandle(engine),
    ) catch |err| return statusOf(err);

    const content = Content.open(found) catch |err| return statusOf(err);

    out.* = @bitCast(@backingInt(content));

    return san.SAN_STATUS_OK;
}

fn closeContent(state: *Process, content: san.san_handle) san.san_status {
    const live = Content.resolve(
        &state.slot,
        contentHandle(content),
    ) catch |err| return statusOf(err);

    Content.close(live);

    return san.SAN_STATUS_OK;
}

/// The status of a function that San does not implement yet, called on
/// a content of `state`: the checks of the handle, then
/// SAN_STATUS_ENGINE_FAILURE.
fn unimplementedOn(state: *Process, content: san.san_handle) san.san_status {
    _ = Content.resolve(&state.slot, contentHandle(content)) catch |err| {
        return statusOf(err);
    };

    return san.SAN_STATUS_ENGINE_FAILURE;
}

fn engineHandle(engine: san.san_handle) Engine.Handle {
    return @fromBackingInt(@as(u64, @bitCast(engine)));
}

fn contentHandle(content: san.san_handle) Content.Handle {
    return @fromBackingInt(@as(u64, @bitCast(content)));
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
const roomy: san.san_engine_limits = limits: {
    var limits = uniform(1 << 20);

    limits.content_count = contents;
    limits.input_portion_bytes = portion;

    break :limits limits;
};

/// The content slots and the staging of each content under `roomy`.
const contents = 4;
const portion = 4096;

/// What a staging takes from the ledger: its portion and its header.
const staged = portion + Heap.header_size;

/// Returns limits that all hold `value`.
fn uniform(value: i64) san.san_engine_limits {
    var limits: san.san_engine_limits = undefined;

    inline for (Engine.Limits.names) |name| @field(limits, name) = value;

    return limits;
}

/// A value that no creation writes, so that a test sees whether a call
/// wrote its output.
const unwritten: san.san_handle = 0x5a5a_5a5a_5a5a_5a5a;

/// What turns an engine handle into the handle of the next generation:
/// the kind fills the lowest byte, and the generation starts above it.
const next_generation = 0x100;

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

/// A report that no read has written.
const unread: Counters = @splat(unwritten);

/// Returns the counters report of the given ledger counts, with every
/// count of jobs and leases at 0.
fn countersOf(counts: struct {
    live: u64,
    reserved: u64 = 0,
    peak: u64,
    peak_committed: u64,
    metadata: u64,
    output: u64 = 0,
    contents: u64 = 0,
    input: u64 = 0,
}) Counters {
    var report: Counters = @splat(0);

    report[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT] = reported(counts.contents);
    report[san.SAN_ENGINE_COUNTERS_INPUT_BYTES] = reported(counts.input);

    report[san.SAN_ENGINE_COUNTERS_LIVE_BYTES] = reported(counts.live);
    report[san.SAN_ENGINE_COUNTERS_RESERVED_BYTES] = reported(counts.reserved);
    report[san.SAN_ENGINE_COUNTERS_PEAK_LIVE_BYTES] = reported(counts.peak);

    report[san.SAN_ENGINE_COUNTERS_PEAK_COMMITTED_BYTES] =
        reported(counts.peak_committed);

    report[san.SAN_ENGINE_COUNTERS_METADATA_BYTES] = reported(counts.metadata);
    report[san.SAN_ENGINE_COUNTERS_OUTPUT_BYTES] = reported(counts.output);

    return report;
}

test "the counters read checks its handle, then its flag, and writes nothing" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);
    var engine = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(&state, test_backing.backing(), roomy, &engine),
    );

    var report = unread;

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine + next_generation,
        unwritten,
    };

    // The handle decides before the flag does.
    for (invalid) |handle| {
        try testing.expectEqual(
            san.SAN_STATUS_INVALID_HANDLE,
            counters(&state, handle, 2, &report),
        );
    }

    const flags = [_]i32{ 2, -1, std.math.maxInt(i32), std.math.minInt(i32) };

    for (flags) |flag| {
        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            counters(&state, engine, flag, &report),
        );
    }

    try testing.expectEqual(unread, report);
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        counters(&state, engine, 0, &report),
    );

    try testing.expectEqual(unread, report);
}

test "the counters read reports the ledger and resets the peaks on request" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);
    var handle = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(&state, test_backing.backing(), roomy, &handle),
    );

    // The engine's own state is its two blocks, of the metadata kind.
    const own = test_backing.outstanding;

    var report = unread;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        counters(&state, handle, 0, &report),
    );

    try testing.expectEqual(countersOf(.{
        .live = own,
        .peak = own,
        .peak_committed = own,
        .metadata = own,
    }), report);

    const engine = try Engine.resolve(&state.slot, engineHandle(handle));

    // An output block of 64 bytes from a reservation of 256, and a codec
    // block of 32 bytes. Each block has a header of 16 bytes.
    var reservation = try engine.heap.ledger.reserve(.output, 256);

    const output = engine.heap.allocReserved(&reservation, 64).?;

    const codec = engine.heap.alloc(32).?;

    const busy = countersOf(.{
        .live = own + 80 + 48,
        .reserved = 176,
        .peak = own + 80 + 48,
        .peak_committed = own + 256 + 48,
        .metadata = own,
        .output = 80,
    });

    // A read without a reset changes no peak.
    for (0..2) |_| {
        report = unread;

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            counters(&state, handle, 0, &report),
        );

        try testing.expectEqual(busy, report);
    }

    engine.heap.free(codec);
    engine.heap.ledger.cancel(&reservation);

    // The read with a reset still reports the peaks before it.
    try testing.expectEqual(
        san.SAN_STATUS_OK,
        counters(&state, handle, 1, &report),
    );

    try testing.expectEqual(countersOf(.{
        .live = own + 80,
        .peak = own + 80 + 48,
        .peak_committed = own + 256 + 48,
        .metadata = own,
        .output = 80,
    }), report);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        counters(&state, handle, 0, &report),
    );

    try testing.expectEqual(countersOf(.{
        .live = own + 80,
        .peak = own + 80,
        .peak_committed = own + 80,
        .metadata = own,
        .output = 80,
    }), report);

    engine.heap.free(output);
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, handle));
    try testing.expectEqual(0, test_backing.blocks);
}

test "the content opening checks its engine and writes no handle" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);
    var engine = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(&state, test_backing.backing(), roomy, &engine),
    );

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine + next_generation,
        unwritten,
    };

    for (invalid) |handle| {
        var content = unwritten;

        try testing.expectEqual(
            san.SAN_STATUS_INVALID_HANDLE,
            openContent(&state, handle, &content),
        );

        try testing.expectEqual(san.SAN_NO_HANDLE, content);
    }

    // No call kept anything: the engine holds its own state alone.
    try testing.expectEqual(2, test_backing.blocks);
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

/// Creates an engine under `roomy` in `state` and returns its handle.
fn createRoomy(state: *Process, test_backing: *TestBacking) !san.san_handle {
    var engine = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(state, test_backing.backing(), roomy, &engine),
    );

    return engine;
}

/// Reads the counters of `engine` in `state`.
fn readCounters(state: *Process, engine: san.san_handle) !Counters {
    var report = unread;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        counters(state, engine, 0, &report),
    );

    return report;
}

/// Returns the count of the open contents that `engine` reports.
fn openCount(state: *Process, engine: san.san_handle) !i64 {
    const report = try readCounters(state, engine);

    return report[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT];
}

const input_bytes = san.SAN_ENGINE_COUNTERS_INPUT_BYTES;
const metadata_bytes = san.SAN_ENGINE_COUNTERS_METADATA_BYTES;

/// Opens a content in `engine` and returns its handle.
fn openOk(state: *Process, engine: san.san_handle) !san.san_handle {
    var content = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        openContent(state, engine, &content),
    );

    try testing.expect(content != san.SAN_NO_HANDLE);

    return content;
}

test "a content opens, is counted, and closes once" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const own = try readCounters(&state, engine);

    const metadata = own[metadata_bytes];

    const first = try openOk(&state, engine);

    var report = try readCounters(&state, engine);

    try testing.expectEqual(1, report[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT]);
    try testing.expectEqual(staged, report[input_bytes]);
    try testing.expectEqual(metadata, report[metadata_bytes]);

    try testing.expectEqual(
        metadata + staged,
        report[san.SAN_ENGINE_COUNTERS_LIVE_BYTES],
    );

    const second = try openOk(&state, engine);

    report = try readCounters(&state, engine);

    try testing.expect(second != first);
    try testing.expectEqual(2, report[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT]);

    try testing.expectEqual(
        2 * staged,
        report[input_bytes],
    );

    try testing.expectEqual(metadata, report[metadata_bytes]);
    try testing.expectEqual(san.SAN_STATUS_OK, closeContent(&state, first));

    report = try readCounters(&state, engine);

    try testing.expectEqual(1, report[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT]);
    try testing.expectEqual(staged, report[input_bytes]);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        closeContent(&state, first),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, closeContent(&state, second));

    try testing.expectEqual(countersOf(.{
        .live = @intCast(metadata),
        .peak = @intCast(metadata + 2 * staged),
        .peak_committed = @intCast(metadata + 2 * staged),
        .metadata = @intCast(metadata),
    }), try readCounters(&state, engine));

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

test "a refused opening writes no handle and keeps nothing" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    var opened: [contents]san.san_handle = undefined;

    for (&opened) |*content| content.* = try openOk(&state, engine);

    const before = try readCounters(&state, engine);

    var content = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        openContent(&state, engine, &content),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, content);
    try testing.expectEqual(contents + 2, test_backing.blocks);

    try testing.expectEqual(
        before[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT],
        try openCount(&state, engine),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        closeContent(&state, opened[contents - 1]),
    );

    // The freed slot is the one that the next opening takes.
    const reopened = try openOk(&state, engine);

    try testing.expect(reopened != opened[contents - 1]);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        closeContent(&state, opened[contents - 1]),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

test "a refused backing allocation fails an opening as AllocationFailed" {
    var state = established();

    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 2,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    const engine = try createRoomy(&state, &test_backing);

    var content = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_ALLOCATION_FAILED,
        openContent(&state, engine, &content),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, content);
    try testing.expectEqual(2, test_backing.blocks);

    try testing.expectEqual(0, try openCount(&state, engine));

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

test "the feed and the job request on an open content fail as EngineFailure" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        unimplementedOn(&state, content),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, closeContent(&state, content));

    for ([_]san.san_handle{ content, engine, san.SAN_NO_HANDLE }) |handle| {
        try testing.expectEqual(
            san.SAN_STATUS_INVALID_HANDLE,
            unimplementedOn(&state, handle),
        );
    }

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
}

test "an engine handle and a content handle are not interchangeable" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    var opened = unwritten;
    var report = unread;

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        openContent(&state, content, &opened),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, opened);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        counters(&state, content, 0, &report),
    );

    try testing.expectEqual(unread, report);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        shutdown(&state, content),
    );

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        closeContent(&state, engine),
    );

    // Neither misuse changed the engine or its content.
    try testing.expectEqual(1, try openCount(&state, engine));

    try testing.expectEqual(san.SAN_STATUS_OK, closeContent(&state, content));
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
}

test "a shutdown closes the open contents and ends their handles" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const first_engine = try createRoomy(&state, &test_backing);

    const first = try openOk(&state, first_engine);

    _ = try openOk(&state, first_engine);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        shutdown(&state, first_engine),
    );

    try testing.expectEqual(0, test_backing.blocks);
    try testing.expectEqual(0, test_backing.outstanding);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        closeContent(&state, first),
    );

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        unimplementedOn(&state, first),
    );

    const second_engine = try createRoomy(&state, &test_backing);

    // The new content sits in the slot that the old one held.
    const second = try openOk(&state, second_engine);

    try testing.expect(second != first);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        closeContent(&state, first),
    );

    try testing.expectEqual(1, try openCount(&state, second_engine));

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        shutdown(&state, second_engine),
    );

    try testing.expectEqual(0, test_backing.blocks);
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
    try testing.expectEqual(2, test_backing.blocks);
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

    try testing.expectEqual(2, test_backing.blocks);
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

    var counted = unread;
    var content = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_engine_counters(engine, 0, &counted),
    );

    // On the system heap, the engine's own state is the one live block.
    const live = counted[san.SAN_ENGINE_COUNTERS_LIVE_BYTES];

    try testing.expect(live > 0);

    try testing.expectEqual(countersOf(.{
        .live = @intCast(live),
        .peak = @intCast(live),
        .peak_committed = @intCast(live),
        .metadata = @intCast(live),
    }), counted);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_content_open(engine + next_generation, &content),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, content);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_content_open(engine, &content),
    );

    try testing.expect(content != san.SAN_NO_HANDLE);

    const byte: u8 = 0;

    const request: san.san_output_request = .{
        .left = 0,
        .top = 0,
        .right = 0,
        .bottom = 0,
        .max_output_width = 0,
    };

    var job = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        san_content_feed(content, 0, &byte, 1, 0),
    );

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        san_job_request(content, &request, &job),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, job);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_engine_counters(engine, 0, &counted),
    );

    try testing.expectEqual(1, counted[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT]);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_content_close(content),
    );

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_content_close(content),
    );

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_content_feed(content, 0, &byte, 1, 0),
    );

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_job_request(content, &request, &job),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, job);

    // A content still open at the shutdown closes with it.
    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_content_open(engine, &content),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, san_engine_shutdown(engine));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_engine_shutdown(engine),
    );

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_content_close(content),
    );
}
