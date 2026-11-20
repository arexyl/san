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
//! San implements the engine lifecycle, the counters read, the contents
//! with their feed, and the lifecycle of a job. No decode exists: a step
//! ends its job as canceled when the cancellation flag is set, and as
//! SAN_STATUS_ENGINE_FAILURE otherwise. San issues no lease handle, so
//! each function that takes one rejects every handle.

const std = @import("std");
const san = @import("san");
const Engine = @import("engine");

const Content = Engine.Content;
const Heap = Engine.Heap;
const Job = Engine.Job;

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
    position: i64,
    bytes: [*c]const u8,
    length: i32,
    end_of_input: i32,
) san.san_status {
    return feedContent(&process, content, .{
        .position = position,
        .bytes = bytes,
        .length = length,
        .end_of_input = end_of_input,
    });
}

pub export fn san_content_close(content: san.san_handle) san.san_status {
    return closeContent(&process, content);
}

pub export fn san_job_request(
    content: san.san_handle,
    request: [*c]const san.san_output_request,
    job: [*c]san.san_handle,
) san.san_status {
    return requestJob(&process, content, request.*, job);
}

pub export fn san_job_step(
    job: san.san_handle,
    report: [*c]i64,
) san.san_status {
    return stepJob(&process, job, report[0..san.SAN_JOB_REPORT_LENGTH]);
}

pub export fn san_job_cancel(job: san.san_handle) san.san_status {
    return cancelJob(&process, job);
}

pub export fn san_job_release(job: san.san_handle) san.san_status {
    return releaseJob(&process, job);
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
    const reached = Engine.shutdown(
        &state.slot,
        engineHandle(engine),
    ) catch |err| return statusOf(err);

    return switch (reached) {
        .pending => san.SAN_STATUS_PENDING,
        .complete => san.SAN_STATUS_OK,
    };
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

    out[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT] =
        reported(Content.countOpen(found));

    out[san.SAN_ENGINE_COUNTERS_JOB_COUNT] = reported(Job.countOwned(found));
    out[san.SAN_ENGINE_COUNTERS_LEASE_COUNT] = reported(Job.countLeased(found));

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

/// The arguments of san_content_feed after its handle, as the caller
/// passed them.
const Feed = struct {
    position: i64,
    bytes: [*c]const u8,
    length: i32,
    end_of_input: i32,
};

/// Supplies one portion of input to a content of `state`. The checks
/// run in the order of the header, and a failed check changes nothing.
fn feedContent(
    state: *Process,
    content: san.san_handle,
    fed: Feed,
) san.san_status {
    const live = Content.resolve(
        &state.slot,
        contentHandle(content),
    ) catch |err| return statusOf(err);

    const target = Content.feedable(live) catch |err| return statusOf(err);

    const input = portionOf(target, fed) catch |err| return statusOf(err);

    Content.feed(target, input) catch |err| return statusOf(err);

    return san.SAN_STATUS_OK;
}

/// Returns the portion that `fed` names for `target`. An end flag that
/// is neither 0 nor 1, a negative position, a length outside 1 to the
/// staging or 0 without the end, and null bytes of a length above 0 fail
/// as BindingMismatch.
fn portionOf(
    target: Content.Feedable,
    fed: Feed,
) error{BindingMismatch}!Content.Portion {
    const end = switch (fed.end_of_input) {
        0 => false,
        1 => true,
        else => return error.BindingMismatch,
    };

    const position = std.math.cast(u64, fed.position) orelse
        return error.BindingMismatch;

    const length = std.math.cast(usize, fed.length) orelse
        return error.BindingMismatch;

    if (length > target.open.staging.len) return error.BindingMismatch;
    if (length == 0 and !end) return error.BindingMismatch;
    if (length != 0 and fed.bytes == null) return error.BindingMismatch;

    // A feed of no byte may pass a null pointer, which has no slice.
    const bytes: []const u8 = if (length == 0) &.{} else fed.bytes[0..length];

    return .{ .position = position, .bytes = bytes, .end = end };
}

/// Admits the job of a content of `state` and writes its handle to
/// `out`, or SAN_NO_HANDLE on a failure.
fn requestJob(
    state: *Process,
    content: san.san_handle,
    request: san.san_output_request,
    out: *san.san_handle,
) san.san_status {
    out.* = san.SAN_NO_HANDLE;

    const live = Content.resolve(
        &state.slot,
        contentHandle(content),
    ) catch |err| return statusOf(err);

    const wanted = requestOf(request) catch |err| return statusOf(err);

    const job = Job.request(live, wanted) catch |err| return statusOf(err);

    out.* = @bitCast(@backingInt(job));

    return san.SAN_STATUS_OK;
}

/// Returns the request of the header as the engine module takes it. A
/// negative width and a region that is neither four zeros nor
/// 0 <= left < right and 0 <= top < bottom fail as BindingMismatch.
fn requestOf(
    request: san.san_output_request,
) error{BindingMismatch}!Job.Request {
    const max_output_width = std.math.cast(u31, request.max_output_width) orelse
        return error.BindingMismatch;

    const edges = [_]i32{
        request.left,
        request.top,
        request.right,
        request.bottom,
    };

    if (std.mem.allEqual(i32, &edges, 0)) {
        return .{ .region = null, .max_output_width = max_output_width };
    }

    const left = std.math.cast(u31, request.left) orelse
        return error.BindingMismatch;

    const top = std.math.cast(u31, request.top) orelse
        return error.BindingMismatch;

    if (request.right <= request.left or request.bottom <= request.top) {
        return error.BindingMismatch;
    }

    return .{
        .region = .{
            .left = left,
            .top = top,
            .right = @intCast(request.right),
            .bottom = @intCast(request.bottom),
        },
        .max_output_width = max_output_width,
    };
}

/// The job report of the header.
const Report = [san.SAN_JOB_REPORT_LENGTH]i64;

/// Advances a job of `state` and writes its report to `out`. A status
/// that rejects the call writes nothing.
fn stepJob(
    state: *Process,
    job: san.san_handle,
    out: *Report,
) san.san_status {
    const live = Job.resolve(
        &state.slot,
        jobHandle(job),
    ) catch |err| return statusOf(err);

    const outcome = Job.step(live);

    // No admission step ran and no lease exists, so every element is 0.
    out.* = @splat(0);

    return switch (outcome) {
        .canceled => san.SAN_STATUS_CANCELED,
        .engine_failure => san.SAN_STATUS_ENGINE_FAILURE,
    };
}

fn cancelJob(state: *Process, job: san.san_handle) san.san_status {
    Job.cancel(&state.slot, jobHandle(job)) catch |err| return statusOf(err);

    return san.SAN_STATUS_OK;
}

fn releaseJob(state: *Process, job: san.san_handle) san.san_status {
    const owned = Job.resolveOwned(
        &state.slot,
        jobHandle(job),
    ) catch |err| return statusOf(err);

    Job.release(owned) catch |err| return statusOf(err);

    return san.SAN_STATUS_OK;
}

fn engineHandle(engine: san.san_handle) Engine.Handle {
    return @fromBackingInt(@as(u64, @bitCast(engine)));
}

fn contentHandle(content: san.san_handle) Content.Handle {
    return @fromBackingInt(@as(u64, @bitCast(content)));
}

fn jobHandle(job: san.san_handle) Job.Handle {
    return @fromBackingInt(@as(u64, @bitCast(job)));
}

/// A failure of the engine module that a function above can meet.
const Failure = Engine.CreateError || Job.RequestError ||
    error{ InvalidHandle, Closed };

/// Returns the status of `failure`. Each category of the engine module
/// has the status of the same name.
fn statusOf(failure: Failure) san.san_status {
    return switch (failure) {
        error.UnsupportedOperation => san.SAN_STATUS_UNSUPPORTED_OPERATION,
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
    limits.job_count = job_slots;
    limits.output_lease_count = lease_limit;
    limits.input_portion_bytes = portion;

    break :limits limits;
};

/// The content slots and the staging of each content under `roomy`.
const contents = 4;
const portion = 4096;

/// The job slots and the count limit of leases under `roomy`.
const job_slots = 2;
const lease_limit = 2;

/// The blocks of an engine's own state: the engine, the slots of its
/// contents, and the slots of its jobs.
const own_blocks = 3;

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

/// Returns the counters report of the given counts.
fn countersOf(counts: struct {
    live: u64,
    reserved: u64 = 0,
    peak: u64,
    peak_committed: u64,
    metadata: u64,
    output: u64 = 0,
    contents: u64 = 0,
    input: u64 = 0,
    jobs: u64 = 0,
    leases: u64 = 0,
}) Counters {
    var report: Counters = @splat(0);

    report[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT] = reported(counts.contents);
    report[san.SAN_ENGINE_COUNTERS_JOB_COUNT] = reported(counts.jobs);
    report[san.SAN_ENGINE_COUNTERS_LEASE_COUNT] = reported(counts.leases);
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

    // The engine's own state is its three blocks, of the metadata kind.
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
    try testing.expectEqual(own_blocks, test_backing.blocks);
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
    try testing.expectEqual(contents + own_blocks, test_backing.blocks);

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

    // The staging is the first allocation after the engine's own blocks.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = own_blocks,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    const engine = try createRoomy(&state, &test_backing);

    var content = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_ALLOCATION_FAILED,
        openContent(&state, engine, &content),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, content);
    try testing.expectEqual(own_blocks, test_backing.blocks);

    try testing.expectEqual(0, try openCount(&state, engine));

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

/// The request of the whole image at a scale of 1:1.
const whole: san.san_output_request = .{
    .left = 0,
    .top = 0,
    .right = 0,
    .bottom = 0,
    .max_output_width = 0,
};

/// A report that no step has written.
const unstepped: Report = @splat(unwritten);

/// Feeds `bytes` to `content` in `state` as its bytes from `position`.
fn feedBytes(
    state: *Process,
    content: san.san_handle,
    position: i64,
    bytes: []const u8,
    end_of_input: i32,
) san.san_status {
    return feedContent(state, content, .{
        .position = position,
        .bytes = bytes.ptr,
        .length = @intCast(bytes.len),
        .end_of_input = end_of_input,
    });
}

/// Requests the job of `content` for the whole image and returns its
/// handle.
fn requestOk(state: *Process, content: san.san_handle) !san.san_handle {
    var job = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        requestJob(state, content, whole, &job),
    );

    try testing.expect(job != san.SAN_NO_HANDLE);

    return job;
}

/// Checks that `engine` counts `jobs` owned jobs and `leases` live
/// leases.
fn expectJobs(
    state: *Process,
    engine: san.san_handle,
    jobs: i64,
    leases: i64,
) !void {
    const report = try readCounters(state, engine);

    try testing.expectEqual(jobs, report[san.SAN_ENGINE_COUNTERS_JOB_COUNT]);
    try testing.expectEqual(leases, report[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);
}

test "the feed checks its handle before its arguments" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    const malformed: Feed = .{
        .position = -1,
        .bytes = null,
        .length = -1,
        .end_of_input = 2,
    };

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine,
        content + next_generation,
        unwritten,
    };

    for (invalid) |handle| {
        try testing.expectEqual(
            san.SAN_STATUS_INVALID_HANDLE,
            feedContent(&state, handle, malformed),
        );
    }

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        feedContent(&state, content, malformed),
    );

    // A content that its close ended names nothing.
    try testing.expectEqual(san.SAN_STATUS_OK, closeContent(&state, content));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        feedContent(&state, content, malformed),
    );

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        feedBytes(&state, content, 0, "x", 0),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
}

test "each malformed argument of a feed fails as BindingMismatch" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    const bytes: [portion + 1]u8 = @splat(0x5a);

    const valid: Feed = .{
        .position = 0,
        .bytes = &bytes,
        .length = portion,
        .end_of_input = 0,
    };

    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);

    for ([_]i32{ 2, -1, max, min }) |end_of_input| {
        var fed = valid;

        fed.end_of_input = end_of_input;

        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            feedContent(&state, content, fed),
        );
    }

    // A length of 0 needs the end of the input, and the staging bounds
    // every length.
    for ([_]i32{ 0, -1, min, portion + 1, max }) |length| {
        var fed = valid;

        fed.length = length;

        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            feedContent(&state, content, fed),
        );
    }

    // The content received no byte, so only position 0 follows.
    for ([_]i64{ -1, std.math.minInt(i64), 1, portion }) |position| {
        var fed = valid;

        fed.position = position;

        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            feedContent(&state, content, fed),
        );
    }

    var without_bytes = valid;

    without_bytes.bytes = null;

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        feedContent(&state, content, without_bytes),
    );

    // No refusal changed the content: the valid feed still fits it.
    try testing.expectEqual(
        san.SAN_STATUS_OK,
        feedContent(&state, content, valid),
    );

    // The staging holds bytes that no step consumed.
    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        feedBytes(&state, content, portion, "x", 0),
    );

    try testing.expectEqual(own_blocks + 1, test_backing.blocks);
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
}

test "a feed of no byte ends the input, also with a null pointer" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    const end: Feed = .{
        .position = 0,
        .bytes = null,
        .length = 0,
        .end_of_input = 1,
    };

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        feedContent(&state, content, end),
    );

    // The input ended, so no feed follows.
    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        feedContent(&state, content, end),
    );

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        feedBytes(&state, content, 0, "x", 0),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
}

test "the job request checks its content, then its fields" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);

    // Left, top, right, bottom, and the largest output width.
    const malformed = [_][5]i32{
        .{ 0, 0, 0, 0, -1 },
        .{ 0, 0, 0, 0, min },
        .{ 0, 0, 2, 2, -1 },
        // An empty or reversed axis, which only four zeros may have.
        .{ 0, 0, 0, 1, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 1, 0, 1, 2, 0 },
        .{ 2, 0, 1, 2, 0 },
        .{ 0, 1, 2, 1, 0 },
        .{ 0, 2, 2, 1, 0 },
        .{ 1, 1, 1, 1, 0 },
        // A negative edge.
        .{ -1, 0, 1, 1, 0 },
        .{ 0, -1, 1, 1, 0 },
        .{ 0, 0, -1, -1, 0 },
        .{ min, min, max, max, 0 },
        .{ min, 0, 0, 0, 0 },
    };

    const unsupported = [_][5]i32{
        .{ 1, 0, 2, 2, 0 },
        .{ 0, 1, 2, 2, 0 },
        .{ max - 1, max - 1, max, max, 0 },
    };

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine,
        content + next_generation,
    };

    for (malformed) |fields| {
        var job = unwritten;

        // The handle decides before the fields do.
        for (invalid) |handle| {
            try testing.expectEqual(
                san.SAN_STATUS_INVALID_HANDLE,
                requestJob(&state, handle, requestWith(fields), &job),
            );

            try testing.expectEqual(san.SAN_NO_HANDLE, job);
        }

        job = unwritten;

        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            requestJob(&state, content, requestWith(fields), &job),
        );

        try testing.expectEqual(san.SAN_NO_HANDLE, job);
    }

    for (unsupported) |fields| {
        var job = unwritten;

        try testing.expectEqual(
            san.SAN_STATUS_UNSUPPORTED_OPERATION,
            requestJob(&state, content, requestWith(fields), &job),
        );

        try testing.expectEqual(san.SAN_NO_HANDLE, job);
    }

    // No refusal admitted a job or took the content's one admission.
    try expectJobs(&state, engine, 0, 0);

    var job = unwritten;

    try testing.expectEqual(san.SAN_STATUS_OK, requestJob(
        &state,
        content,
        requestWith(.{ 0, 0, max, max, max }),
        &job,
    ));

    try testing.expect(job != san.SAN_NO_HANDLE);
    try expectJobs(&state, engine, 1, 1);

    // The content admitted its job, which decides before the region.
    for ([_][5]i32{ .{ 0, 0, 0, 0, 0 }, unsupported[0] }) |fields| {
        var second = unwritten;

        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            requestJob(&state, content, requestWith(fields), &second),
        );

        try testing.expectEqual(san.SAN_NO_HANDLE, second);
    }

    try expectJobs(&state, engine, 1, 1);
    try testing.expectEqual(san.SAN_STATUS_PENDING, shutdown(&state, engine));
    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, job));
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

/// Returns the request of `fields`: left, top, right, bottom, and the
/// largest output width.
fn requestWith(fields: [5]i32) san.san_output_request {
    return .{
        .left = fields[0],
        .top = fields[1],
        .right = fields[2],
        .bottom = fields[3],
        .max_output_width = fields[4],
    };
}

test "a request beyond a count limit fails as BudgetExceeded" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    var opened: [job_slots + 1]san.san_handle = undefined;

    for (&opened) |*content| content.* = try openOk(&state, engine);

    var jobs: [job_slots]san.san_handle = undefined;

    for (&jobs, opened[0..job_slots]) |*job, content| {
        job.* = try requestOk(&state, content);
    }

    try testing.expect(jobs[0] != jobs[1]);
    try expectJobs(&state, engine, job_slots, job_slots);

    var refused = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        requestJob(&state, opened[job_slots], whole, &refused),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, refused);

    // A terminal job still holds its slot until its release.
    var report = unstepped;

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        stepJob(&state, jobs[0], &report),
    );

    try expectJobs(&state, engine, job_slots, job_slots - 1);

    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        requestJob(&state, opened[job_slots], whole, &refused),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, jobs[0]));

    const later = try requestOk(&state, opened[job_slots]);

    try testing.expect(later != jobs[0]);
    try expectJobs(&state, engine, job_slots, job_slots);

    // The first call of the shutdown ends both live jobs.
    try testing.expectEqual(san.SAN_STATUS_PENDING, shutdown(&state, engine));
    try expectJobs(&state, engine, job_slots, 0);
    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, jobs[1]));
    try testing.expectEqual(san.SAN_STATUS_PENDING, shutdown(&state, engine));
    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, later));
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

test "a step ends its job and writes a report of zeros" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    const job = try requestOk(&state, content);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        feedBytes(&state, content, 0, "abc", 0),
    );

    // A release before the terminal outcome changes nothing.
    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        releaseJob(&state, job),
    );

    try expectJobs(&state, engine, 1, 1);

    var report = unstepped;

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        stepJob(&state, job, &report),
    );

    try testing.expectEqual(@as(Report, @splat(0)), report);
    try expectJobs(&state, engine, 1, 0);

    // After the terminal outcome, a step writes no element, a feed is
    // refused whatever its arguments, and a cancellation changes nothing.
    report = unstepped;

    try testing.expectEqual(
        san.SAN_STATUS_CLOSED,
        stepJob(&state, job, &report),
    );

    try testing.expectEqual(unstepped, report);

    try testing.expectEqual(
        san.SAN_STATUS_CLOSED,
        feedBytes(&state, content, 3, "d", 0),
    );

    try testing.expectEqual(san.SAN_STATUS_CLOSED, feedContent(&state, content, .{
        .position = -1,
        .bytes = null,
        .length = -1,
        .end_of_input = 2,
    }));

    try testing.expectEqual(san.SAN_STATUS_OK, cancelJob(&state, job));
    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, job));
    try expectJobs(&state, engine, 0, 0);

    // The released handle names no job.
    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        stepJob(&state, job, &report),
    );

    try testing.expectEqual(unstepped, report);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        cancelJob(&state, job),
    );

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        releaseJob(&state, job),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

test "a canceled job ends as Canceled in its next step" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const job = try requestOk(&state, try openOk(&state, engine));

    for (0..2) |_| {
        try testing.expectEqual(san.SAN_STATUS_OK, cancelJob(&state, job));
    }

    // The request ends nothing: the job holds its lease until the step.
    try expectJobs(&state, engine, 1, 1);

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        releaseJob(&state, job),
    );

    var report = unstepped;

    try testing.expectEqual(
        san.SAN_STATUS_CANCELED,
        stepJob(&state, job, &report),
    );

    try testing.expectEqual(@as(Report, @splat(0)), report);
    try expectJobs(&state, engine, 1, 0);
    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, job));
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
}

test "the close of a content ends its job, which stays owned" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    const job = try requestOk(&state, content);

    try testing.expectEqual(san.SAN_STATUS_OK, closeContent(&state, content));
    try expectJobs(&state, engine, 1, 0);
    try testing.expectEqual(0, try openCount(&state, engine));

    var report = unstepped;

    try testing.expectEqual(
        san.SAN_STATUS_CLOSED,
        stepJob(&state, job, &report),
    );

    try testing.expectEqual(unstepped, report);
    try testing.expectEqual(san.SAN_STATUS_OK, cancelJob(&state, job));
    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, job));
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
}

test "a closing engine keeps the counters, the cancel, and the release" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const idle = try openOk(&state, engine);

    const content = try openOk(&state, engine);

    const job = try requestOk(&state, content);

    const own = (try readCounters(&state, engine))[metadata_bytes];

    for (0..2) |_| {
        try testing.expectEqual(
            san.SAN_STATUS_PENDING,
            shutdown(&state, engine),
        );

        // The first call ended the job and closed both contents.
        const report = try readCounters(&state, engine);

        try testing.expectEqual(0, report[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT]);
        try testing.expectEqual(1, report[san.SAN_ENGINE_COUNTERS_JOB_COUNT]);
        try testing.expectEqual(0, report[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);
        try testing.expectEqual(0, report[input_bytes]);
        try testing.expectEqual(own, report[san.SAN_ENGINE_COUNTERS_LIVE_BYTES]);
        try testing.expectEqual(own_blocks, test_backing.blocks);

        var opened = unwritten;
        var requested = unwritten;
        var stepped = unstepped;

        const closed = [_]san.san_status{
            openContent(&state, engine, &opened),
            feedBytes(&state, content, 0, "x", 0),
            feedBytes(&state, idle, 0, "x", 0),
            requestJob(&state, idle, whole, &requested),
            closeContent(&state, content),
            closeContent(&state, idle),
            stepJob(&state, job, &stepped),
        };

        for (closed) |status| {
            try testing.expectEqual(san.SAN_STATUS_CLOSED, status);
        }

        try testing.expectEqual(san.SAN_NO_HANDLE, opened);
        try testing.expectEqual(san.SAN_NO_HANDLE, requested);
        try testing.expectEqual(unstepped, stepped);
        try testing.expectEqual(san.SAN_STATUS_OK, cancelJob(&state, job));
    }

    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, job));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        releaseJob(&state, job),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(&state, engine));
    try testing.expectEqual(0, test_backing.blocks);
    try testing.expectEqual(0, test_backing.outstanding);

    // The completed shutdown ended every handle of the engine.
    var report = unstepped;

    const ended = [_]san.san_status{
        shutdown(&state, engine),
        feedBytes(&state, content, 0, "x", 0),
        closeContent(&state, idle),
        stepJob(&state, job, &report),
        cancelJob(&state, job),
        releaseJob(&state, job),
    };

    for (ended) |status| {
        try testing.expectEqual(san.SAN_STATUS_INVALID_HANDLE, status);
    }

    try testing.expectEqual(unstepped, report);
}

test "a job handle and another handle are not interchangeable" {
    var state = established();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine = try createRoomy(&state, &test_backing);

    const content = try openOk(&state, engine);

    const job = try requestOk(&state, content);

    var report = unstepped;

    for ([_]san.san_handle{ engine, content }) |handle| {
        const statuses = [_]san.san_status{
            stepJob(&state, handle, &report),
            cancelJob(&state, handle),
            releaseJob(&state, handle),
        };

        for (statuses) |status| {
            try testing.expectEqual(san.SAN_STATUS_INVALID_HANDLE, status);
        }
    }

    var opened = unwritten;
    var requested = unwritten;
    var counted = unread;

    const statuses = [_]san.san_status{
        counters(&state, job, 0, &counted),
        openContent(&state, job, &opened),
        feedBytes(&state, job, 0, "x", 0),
        requestJob(&state, job, whole, &requested),
        closeContent(&state, job),
        shutdown(&state, job),
    };

    for (statuses) |status| {
        try testing.expectEqual(san.SAN_STATUS_INVALID_HANDLE, status);
    }

    try testing.expectEqual(unstepped, report);
    try testing.expectEqual(unread, counted);
    try testing.expectEqual(san.SAN_NO_HANDLE, opened);
    try testing.expectEqual(san.SAN_NO_HANDLE, requested);

    // No misuse changed the engine, its content, or its job.
    try expectJobs(&state, engine, 1, 1);
    try testing.expectEqual(1, try openCount(&state, engine));
    try testing.expectEqual(san.SAN_STATUS_OK, closeContent(&state, content));
    try testing.expectEqual(san.SAN_STATUS_OK, releaseJob(&state, job));
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
        feedBytes(&state, first, 0, "x", 0),
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
        // The kind of a job, at generation 0 and at generation 1.
        0x3,
        0x100_0003,
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
    try testing.expectEqual(own_blocks, test_backing.blocks);
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

    try testing.expectEqual(own_blocks, test_backing.blocks);
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
        .{ error.UnsupportedOperation, san.SAN_STATUS_UNSUPPORTED_OPERATION },
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
        san.SAN_STATUS_OK,
        san_content_feed(content, 0, &byte, 1, 0),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_job_request(content, &request, &job),
    );

    try testing.expect(job != san.SAN_NO_HANDLE);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_engine_counters(engine, 0, &counted),
    );

    try testing.expectEqual(1, counted[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT]);
    try testing.expectEqual(1, counted[san.SAN_ENGINE_COUNTERS_JOB_COUNT]);
    try testing.expectEqual(1, counted[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);

    // No decode exists, so the first step ends the job.
    var report: Report = @splat(unwritten);

    try testing.expectEqual(
        san.SAN_STATUS_ENGINE_FAILURE,
        san_job_step(job, &report),
    );

    try testing.expectEqual(@as(Report, @splat(0)), report);
    try testing.expectEqual(san.SAN_STATUS_CLOSED, san_job_step(job, &report));

    try testing.expectEqual(
        san.SAN_STATUS_CLOSED,
        san_content_feed(content, 1, &byte, 1, 0),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, san_job_cancel(job));

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

    var refused = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        san_job_request(content, &request, &refused),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, refused);

    // A content still open at the shutdown closes with it, and the
    // shutdown waits for the release of the job.
    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san_content_open(engine, &content),
    );

    try testing.expectEqual(
        san.SAN_STATUS_PENDING,
        san_engine_shutdown(engine),
    );

    try testing.expectEqual(
        san.SAN_STATUS_CLOSED,
        san_content_close(content),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, san_job_release(job));
    try testing.expectEqual(san.SAN_STATUS_INVALID_HANDLE, san_job_release(job));
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
