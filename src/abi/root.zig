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
//! This file also composes the library: the engine names no codec, and
//! every engine that these functions create takes the PNG decoder as the
//! codec of its jobs.
//!
//! San implements the engine lifecycle, the counters read, the contents
//! with their feed, the jobs with their steps and reports, and the copy
//! and the release of an output lease.

const std = @import("std");
const san = @import("san");
const Engine = @import("engine");
const Decoder = @import("png");

const Content = Engine.Content;
const Heap = Engine.Heap;
const Job = Engine.Job;
const Lease = Engine.Lease;

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
    lease: san.san_handle,
    first_row: i32,
    row_count: i32,
    dst: [*c]u8,
    dst_width: i32,
    dst_height: i32,
    dst_stride: i32,
    dst_first_row: i32,
    dst_alpha: i32,
) san.san_status {
    return copyOutput(&process, lease, .{
        .first_row = first_row,
        .row_count = row_count,
        .dst = dst,
        .dst_width = dst_width,
        .dst_height = dst_height,
        .dst_stride = dst_stride,
        .dst_first_row = dst_first_row,
        .dst_alpha = dst_alpha,
    });
}

pub export fn san_output_release(lease: san.san_handle) san.san_status {
    return releaseOutput(&process, lease);
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

/// Creates an engine in `state` with memory from `backing` and the PNG
/// decoder as its codec. It writes the handle of the engine to `out`, or
/// SAN_NO_HANDLE on a failure.
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
        Decoder.opener,
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
    out[san.SAN_ENGINE_COUNTERS_LEASE_COUNT] = reported(Lease.countLive(found));

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

    const stepped = Job.step(live);

    out.* = reportOf(stepped.report);

    // This build consumes every staged byte in one step, so a job that
    // continues always waits for input.
    const outcome = stepped.outcome orelse return san.SAN_STATUS_INPUT_NEEDED;

    return switch (outcome) {
        .completed => san.SAN_STATUS_OK,
        .canceled => san.SAN_STATUS_CANCELED,
        .unsupported_format => san.SAN_STATUS_UNSUPPORTED_FORMAT,
        .unsupported_operation => san.SAN_STATUS_UNSUPPORTED_OPERATION,
        .invalid_content => san.SAN_STATUS_INVALID_CONTENT,
        .truncated_content => san.SAN_STATUS_TRUNCATED_CONTENT,
        .budget_exceeded => san.SAN_STATUS_BUDGET_EXCEEDED,
        .allocation_failed => san.SAN_STATUS_ALLOCATION_FAILED,
        .engine_failure => san.SAN_STATUS_ENGINE_FAILURE,
    };
}

/// Returns the report of the header for `report`. An element that the
/// job does not know yet is 0, and no path of this build sets a warning
/// bit.
fn reportOf(report: Job.Report) Report {
    var out: Report = @splat(0);

    if (report.lease) |lease| {
        out[san.SAN_JOB_REPORT_LEASE] = @bitCast(@backingInt(lease));
    }

    out[san.SAN_JOB_REPORT_REVISION] = @intCast(report.revision);
    out[san.SAN_JOB_REPORT_COVERED_ROWS] = report.covered_rows;
    out[san.SAN_JOB_REPORT_DECODED_ROWS] = report.decoded_rows;

    if (report.admission) |admission| {
        out[san.SAN_JOB_REPORT_IMAGE_WIDTH] = admission.image.width;
        out[san.SAN_JOB_REPORT_IMAGE_HEIGHT] = admission.image.height;
        out[san.SAN_JOB_REPORT_OUTPUT_WIDTH] = admission.output_width;
        out[san.SAN_JOB_REPORT_OUTPUT_HEIGHT] = admission.output_height;
    }

    if (report.admitted) |admitted| {
        out[san.SAN_JOB_REPORT_LEASE_WIDTH] = admitted.width;
        out[san.SAN_JOB_REPORT_LEASE_HEIGHT] = admitted.height;
        out[san.SAN_JOB_REPORT_LEASE_LEFT] = admitted.left;
        out[san.SAN_JOB_REPORT_LEASE_TOP] = admitted.top;

        out[san.SAN_JOB_REPORT_ALPHA] = if (admitted.alpha)
            san.SAN_ALPHA_PREMULTIPLIED
        else
            san.SAN_ALPHA_OPAQUE;

        out[san.SAN_JOB_REPORT_EARLY_PUBLICATION] =
            @intFromBool(admitted.early_publication);
    }

    return out;
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

/// The arguments of san_output_copy after its handle, as the caller
/// passed them.
const CopyArguments = struct {
    first_row: i32,
    row_count: i32,
    dst: [*c]u8,
    dst_width: i32,
    dst_height: i32,
    dst_stride: i32,
    dst_first_row: i32,
    dst_alpha: i32,
};

/// Copies covered rows of a lease of `state` into the destination of
/// `wanted`, also while its engine shuts down and after its content
/// closed. The lease decides first, then the checks of the header in
/// their order, and a failed call writes no pixel and changes nothing.
fn copyOutput(
    state: *Process,
    lease: san.san_handle,
    wanted: CopyArguments,
) san.san_status {
    const held = Lease.resolve(
        &state.slot,
        leaseHandle(lease),
    ) catch |err| return statusOf(err);

    const rows = copyOf(held, wanted) catch |err| return statusOf(err);

    Lease.copy(held, rows);

    return san.SAN_STATUS_OK;
}

/// Returns the copy that `wanted` names for `held`. In the order of the
/// header and in 64-bit arithmetic, these fail as BindingMismatch: a
/// width other than the width of the lease; an alpha value that the
/// header does not define; fewer than one row, or rows outside the
/// coverage; a stride below the width times the bytes of a pixel; and
/// destination rows outside the destination, which a null destination
/// has none of.
fn copyOf(
    held: Lease.Held,
    wanted: CopyArguments,
) error{BindingMismatch}!Lease.Copy {
    const lease = held.lease;

    if (wanted.dst_width != lease.width) return error.BindingMismatch;

    // An opaque destination admits only a lease without alpha, and no
    // lease of this build has alpha, so both values admit every lease.
    switch (wanted.dst_alpha) {
        san.SAN_ALPHA_PREMULTIPLIED, san.SAN_ALPHA_OPAQUE => {},
        else => return error.BindingMismatch,
    }

    const row_count: i64 = wanted.row_count;

    if (row_count < 1) return error.BindingMismatch;
    if (wanted.first_row < 0) return error.BindingMismatch;

    if (wanted.first_row + row_count > lease.covered) {
        return error.BindingMismatch;
    }

    const row_bytes = @as(i64, wanted.dst_width) * Lease.pixel_bytes;

    if (wanted.dst_stride < row_bytes) return error.BindingMismatch;
    if (wanted.dst_first_row < 0) return error.BindingMismatch;

    if (wanted.dst_first_row + row_count > wanted.dst_height) {
        return error.BindingMismatch;
    }

    if (wanted.dst == null) return error.BindingMismatch;

    // No factor is negative, and each is below 2^31, so the offset fits
    // the 64 bits of an address on both ABIs.
    const stride: usize = @intCast(wanted.dst_stride);
    const first: usize = @intCast(wanted.dst_first_row);

    return .{
        .first_row = @intCast(wanted.first_row),
        .row_count = @intCast(wanted.row_count),
        .destination = @as([*]u8, wanted.dst) + first * stride,
        .stride = stride,
    };
}

/// Releases the caller's claim on a lease of `state`, also while its
/// engine shuts down and after its content closed.
fn releaseOutput(state: *Process, lease: san.san_handle) san.san_status {
    const held = Lease.resolve(
        &state.slot,
        leaseHandle(lease),
    ) catch |err| return statusOf(err);

    Lease.release(held);

    return san.SAN_STATUS_OK;
}

fn leaseHandle(lease: san.san_handle) Lease.Handle {
    return @fromBackingInt(@as(u64, @bitCast(lease)));
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

/// The blocks of an engine's own state: the engine and the slots of its
/// contents, of its jobs, and of its leases.
const own_blocks = 4;

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

    // The engine's own state is its four blocks, of the metadata kind.
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
const output_bytes = san.SAN_ENGINE_COUNTERS_OUTPUT_BYTES;

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

    // A terminal job still holds its slot until its release. The input
    // of this one ends before any image.
    var report = unstepped;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        feedBytes(&state, opened[0], 0, "", 1),
    );

    try testing.expectEqual(
        san.SAN_STATUS_TRUNCATED_CONTENT,
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

test "a step that fails before an image writes a report of zeros" {
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

    // The bytes are no PNG signature.
    var report = unstepped;

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_CONTENT,
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

    // The one byte is no PNG signature, so the first step ends the job.
    var report: Report = @splat(unwritten);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_CONTENT,
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

const fixtures = Decoder.fixtures;

/// The image of most decode tests below: 8 by 16 pixels in IDAT chunks
/// of 16 bytes, so that its rows arrive spread over its bytes.
const striped: fixtures.Spec = .{
    .width = 8,
    .height = 16,
    .filters = .cycle,
    .idat_size = 16,
};

/// The bytes of the lease of the striped image with their block header.
const striped_lease_bytes = 8 * 16 * Lease.pixel_bytes + Heap.header_size;

/// A backing that requests the cancellation of a job when the heap
/// takes a block of one length. With the length of the job's lease, the
/// request comes from inside the feed of the decoder that reads the
/// image header, before the first row. A length of 0 cancels nothing.
const CancelingBacking = struct {
    inner: *TestBacking,
    state: *Process,
    job: san.san_handle = san.SAN_NO_HANDLE,
    at_len: usize = 0,
    requests: u32 = 0,

    fn backing(canceling: *CancelingBacking) Heap.Backing {
        return .{
            .ptr = canceling,
            .vtable = &.{ .alloc = alloc, .free = free },
        };
    }

    fn alloc(ptr: *anyopaque, len: usize) ?[*]align(16) u8 {
        const canceling: *CancelingBacking = @ptrCast(@alignCast(ptr));

        if (canceling.at_len != 0 and len == canceling.at_len) {
            canceling.requests += 1;

            const status = cancelJob(canceling.state, canceling.job);

            if (status != san.SAN_STATUS_OK) {
                @panic("the backing cancels a job that its test owns");
            }
        }

        const inner = canceling.inner.backing();

        return inner.vtable.alloc(inner.ptr, len);
    }

    fn free(ptr: *anyopaque, block: [*]align(16) u8, len: usize) void {
        const canceling: *CancelingBacking = @ptrCast(@alignCast(ptr));
        const inner = canceling.inner.backing();

        inner.vtable.free(inner.ptr, block, len);
    }
};

/// A plain destination of a copy: rows of `width` pixels in a stride
/// that holds padding after them. Every byte starts as `untouched`, so
/// a test sees each byte that a copy wrote.
const Canvas = struct {
    bytes: []u8,
    width: i32,
    height: i32,
    stride: i32,

    const untouched: u8 = 0xa5;
    const padding = 5;

    fn init(width: i32, height: i32) !Canvas {
        const stride = width * Lease.pixel_bytes + padding;

        const bytes = try testing.allocator.alloc(
            u8,
            @intCast(height * stride),
        );

        @memset(bytes, untouched);

        return .{
            .bytes = bytes,
            .width = width,
            .height = height,
            .stride = stride,
        };
    }

    fn deinit(canvas: Canvas) void {
        testing.allocator.free(canvas.bytes);
    }

    /// Returns the arguments of a copy of `row_count` rows of a lease,
    /// from its row `first_row` on, to the first rows of the canvas, as
    /// an opaque destination.
    fn taking(canvas: Canvas, first_row: i32, row_count: i32) CopyArguments {
        return .{
            .first_row = first_row,
            .row_count = row_count,
            .dst = canvas.bytes.ptr,
            .dst_width = canvas.width,
            .dst_height = canvas.height,
            .dst_stride = canvas.stride,
            .dst_first_row = 0,
            .dst_alpha = san.SAN_ALPHA_OPAQUE,
        };
    }

    /// Returns the row `index` with its padding.
    fn row(canvas: Canvas, index: usize) []const u8 {
        const stride: usize = @intCast(canvas.stride);

        return canvas.bytes[index * stride ..][0..stride];
    }

    /// Checks that no copy wrote the `count` rows from the row `first`
    /// on, their padding included.
    fn expectUntouched(canvas: Canvas, first: usize, count: usize) !void {
        for (first..first + count) |index| {
            try testing.expect(
                std.mem.allEqual(u8, canvas.row(index), untouched),
            );
        }
    }

    /// Checks that the `count` rows from the row `first` on hold the
    /// rows of the image of `samples` from its row `image_first` on, as
    /// pixels of R, G, B, and an alpha of 255, and that their padding
    /// stays untouched.
    fn expectImage(
        canvas: Canvas,
        first: usize,
        samples: []const u8,
        image_first: usize,
        count: usize,
    ) !void {
        const width: usize = @intCast(canvas.width);

        for (0..count) |offset| {
            const pixels = canvas.row(first + offset);
            const expected = samples[(image_first + offset) * width * 3 ..];

            for (0..width) |column| {
                const pixel = pixels[column * Lease.pixel_bytes ..];

                try testing.expectEqualSlices(
                    u8,
                    expected[column * 3 ..][0..3],
                    pixel[0..3],
                );

                try testing.expectEqual(0xff, pixel[3]);
            }

            try testing.expect(std.mem.allEqual(
                u8,
                pixels[width * Lease.pixel_bytes ..],
                untouched,
            ));
        }
    }
};

/// One job over an encoded test image, with the engine and the content
/// that it needs. It starts in place, because the engine names its
/// backing by address.
const Decoding = struct {
    state: Process,
    backing: TestBacking,
    canceling: CancelingBacking,
    /// The encoded image, and the samples that its writer encoded.
    bytes: []u8,
    samples: []u8,
    engine: san.san_handle = san.SAN_NO_HANDLE,
    content: san.san_handle = san.SAN_NO_HANDLE,
    job: san.san_handle = san.SAN_NO_HANDLE,
    /// The bytes of the image that the content received.
    fed: usize = 0,

    const Stepped = struct {
        status: san.san_status,
        report: Report,
    };

    fn start(
        decoding: *Decoding,
        spec: fixtures.Spec,
        limits: san.san_engine_limits,
        request: san.san_output_request,
    ) !void {
        const bytes = try fixtures.encode(testing.allocator, spec);
        errdefer testing.allocator.free(bytes);

        const samples = try fixtures.samples(testing.allocator, spec);
        errdefer testing.allocator.free(samples);

        decoding.* = .{
            .state = established(),
            .backing = .init(testing.allocator),
            .canceling = undefined,
            .bytes = bytes,
            .samples = samples,
        };

        decoding.canceling = .{
            .inner = &decoding.backing,
            .state = &decoding.state,
        };

        try testing.expectEqual(san.SAN_STATUS_OK, create(
            &decoding.state,
            decoding.canceling.backing(),
            limits,
            &decoding.engine,
        ));

        decoding.content = try openOk(&decoding.state, decoding.engine);

        try testing.expectEqual(san.SAN_STATUS_OK, requestJob(
            &decoding.state,
            decoding.content,
            request,
            &decoding.job,
        ));
    }

    fn deinit(decoding: *Decoding) void {
        testing.allocator.free(decoding.bytes);
        testing.allocator.free(decoding.samples);
    }

    /// Returns the bytes of the image that the content has not received.
    fn rest(decoding: *const Decoding) usize {
        return decoding.bytes.len - decoding.fed;
    }

    /// Feeds the next `len` bytes of the image, with or without the end
    /// of the input, and steps the job.
    fn advance(decoding: *Decoding, len: usize, end_of_input: i32) !Stepped {
        try testing.expectEqual(san.SAN_STATUS_OK, feedBytes(
            &decoding.state,
            decoding.content,
            @intCast(decoding.fed),
            decoding.bytes[decoding.fed..][0..len],
            end_of_input,
        ));

        decoding.fed += len;

        return decoding.step();
    }

    fn step(decoding: *Decoding) Stepped {
        var report = unstepped;

        const status = stepJob(&decoding.state, decoding.job, &report);

        return .{ .status = status, .report = report };
    }

    fn copy(
        decoding: *Decoding,
        report: Report,
        wanted: CopyArguments,
    ) san.san_status {
        return copyOutput(
            &decoding.state,
            report[san.SAN_JOB_REPORT_LEASE],
            wanted,
        );
    }

    /// Checks that `report` covers `rows` rows, and copies them out of
    /// its lease into a destination with a padded stride and one row
    /// more: each copied row holds the samples of the image with an
    /// alpha of 255, and every other byte stays as it was. A copy of one
    /// row beyond the coverage is refused and writes nothing.
    fn expectRows(decoding: *Decoding, report: Report, rows: u32) !void {
        try testing.expectEqual(rows, report[san.SAN_JOB_REPORT_COVERED_ROWS]);

        const count: i32 = @intCast(rows);

        var canvas: Canvas = try .init(
            @intCast(report[san.SAN_JOB_REPORT_LEASE_WIDTH]),
            count + 1,
        );
        defer canvas.deinit();

        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            decoding.copy(report, canvas.taking(0, count + 1)),
        );

        try canvas.expectUntouched(0, rows + 1);

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            decoding.copy(report, canvas.taking(0, count)),
        );

        try canvas.expectImage(0, decoding.samples, 0, rows);
        try canvas.expectUntouched(rows, 1);
    }

    fn release(decoding: *Decoding, report: Report) san.san_status {
        return releaseOutput(
            &decoding.state,
            report[san.SAN_JOB_REPORT_LEASE],
        );
    }

    /// Releases the lease that `report` names, which the caller holds.
    fn drop(decoding: *Decoding, report: Report) !void {
        try testing.expectEqual(san.SAN_STATUS_OK, decoding.release(report));
    }

    fn counters(decoding: *Decoding) !Counters {
        return readCounters(&decoding.state, decoding.engine);
    }

    /// Checks that the ledger counts exactly what the backing holds.
    fn expectSettled(decoding: *Decoding) !void {
        const found = try Engine.resolveClosing(
            &decoding.state.slot,
            engineHandle(decoding.engine),
        );

        try Heap.expectMatches(&found.heap, &decoding.backing);
    }

    /// Releases the job, which has its terminal outcome, and shuts down
    /// the engine, which then holds no lease.
    fn stop(decoding: *Decoding) !void {
        try testing.expectEqual(
            san.SAN_STATUS_OK,
            releaseJob(&decoding.state, decoding.job),
        );

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            shutdown(&decoding.state, decoding.engine),
        );

        try testing.expectEqual(0, decoding.backing.blocks);
        try testing.expectEqual(0, decoding.backing.outstanding);
    }
};

/// The elements of a report that the admission step writes, by group.
const Geometry = struct {
    image: [2]i64 = .{ 0, 0 },
    grid: [2]i64 = .{ 0, 0 },
    /// The width and the height of the lease, or null without a lease.
    lease: ?[2]i64 = null,
};

/// Checks the image, grid, and lease elements of `report`.
fn expectGeometry(geometry: Geometry, report: Report) !void {
    const lease = geometry.lease orelse .{ 0, 0 };
    const admitted: i64 = @intFromBool(geometry.lease != null);

    try testing.expectEqual(geometry.image, .{
        report[san.SAN_JOB_REPORT_IMAGE_WIDTH],
        report[san.SAN_JOB_REPORT_IMAGE_HEIGHT],
    });

    try testing.expectEqual(geometry.grid, .{
        report[san.SAN_JOB_REPORT_OUTPUT_WIDTH],
        report[san.SAN_JOB_REPORT_OUTPUT_HEIGHT],
    });

    try testing.expectEqual(lease, .{
        report[san.SAN_JOB_REPORT_LEASE_WIDTH],
        report[san.SAN_JOB_REPORT_LEASE_HEIGHT],
    });

    // The lease of this build starts at the origin of the grid, has no
    // alpha, and publishes before the terminal outcome.
    try testing.expectEqual(0, report[san.SAN_JOB_REPORT_LEASE_LEFT]);
    try testing.expectEqual(0, report[san.SAN_JOB_REPORT_LEASE_TOP]);

    try testing.expectEqual(
        admitted * san.SAN_ALPHA_OPAQUE,
        report[san.SAN_JOB_REPORT_ALPHA],
    );

    try testing.expectEqual(
        admitted,
        report[san.SAN_JOB_REPORT_EARLY_PUBLICATION],
    );
}

const striped_geometry: Geometry = .{
    .image = .{ 8, 16 },
    .grid = .{ 8, 16 },
    .lease = .{ 8, 16 },
};

test "a PNG decodes into a lease that its report names" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    const stepped = try decoding.advance(decoding.rest(), 1);
    const report = stepped.report;

    try testing.expectEqual(san.SAN_STATUS_OK, stepped.status);
    try testing.expect(report[san.SAN_JOB_REPORT_LEASE] != san.SAN_NO_HANDLE);
    try testing.expectEqual(1, report[san.SAN_JOB_REPORT_REVISION]);
    try testing.expectEqual(16, report[san.SAN_JOB_REPORT_DECODED_ROWS]);
    try testing.expectEqual(0, report[san.SAN_JOB_REPORT_WARNINGS]);
    try expectGeometry(striped_geometry, report);
    try decoding.expectRows(report, 16);

    // The codec is gone with the job's terminal outcome, and the lease
    // counts as output until the caller releases it.
    var counted = try decoding.counters();

    try testing.expectEqual(1, counted[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);
    try testing.expectEqual(striped_lease_bytes, counted[output_bytes]);
    try testing.expectEqual(own_blocks + 2, decoding.backing.blocks);
    try decoding.expectSettled();

    try testing.expectEqual(san.SAN_STATUS_OK, decoding.release(report));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        decoding.release(report),
    );

    counted = try decoding.counters();

    try testing.expectEqual(0, counted[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);
    try testing.expectEqual(0, counted[output_bytes]);
    try decoding.stop();
}

test "a PNG decodes the same in portions of one byte" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    var revision: i64 = 0;
    var covered: i64 = 0;

    while (decoding.rest() > 1) {
        const stepped = try decoding.advance(1, 0);

        try testing.expectEqual(san.SAN_STATUS_INPUT_NEEDED, stepped.status);

        // The revision rises by one exactly in a step that extends the
        // coverage, and neither ever falls.
        const extended =
            stepped.report[san.SAN_JOB_REPORT_COVERED_ROWS] - covered;

        try testing.expect(extended >= 0);

        try testing.expectEqual(
            revision + @intFromBool(extended > 0),
            stepped.report[san.SAN_JOB_REPORT_REVISION],
        );

        revision = stepped.report[san.SAN_JOB_REPORT_REVISION];
        covered = stepped.report[san.SAN_JOB_REPORT_COVERED_ROWS];
    }

    // The rows arrived over many steps, before the last byte.
    try testing.expectEqual(16, covered);
    try testing.expect(revision > 1);

    const stepped = try decoding.advance(1, 1);

    try testing.expectEqual(san.SAN_STATUS_OK, stepped.status);
    try testing.expectEqual(
        revision,
        stepped.report[san.SAN_JOB_REPORT_REVISION],
    );

    try decoding.expectRows(stepped.report, 16);
    try decoding.drop(stepped.report);
    try decoding.stop();
}

test "rows publish while the rest of the payload is withheld" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    // Two thirds of the bytes hold some rows of the image and not all.
    const early = try decoding.advance(decoding.bytes.len * 2 / 3, 0);
    const rows = early.report[san.SAN_JOB_REPORT_COVERED_ROWS];

    try testing.expectEqual(san.SAN_STATUS_INPUT_NEEDED, early.status);
    try testing.expect(rows > 0 and rows < 16);
    try testing.expectEqual(1, early.report[san.SAN_JOB_REPORT_REVISION]);
    try testing.expectEqual(
        rows,
        early.report[san.SAN_JOB_REPORT_DECODED_ROWS],
    );

    try expectGeometry(striped_geometry, early.report);
    try decoding.expectRows(early.report, @intCast(rows));

    // A step without new bytes publishes nothing.
    const idle = decoding.step();

    try testing.expectEqual(san.SAN_STATUS_INPUT_NEEDED, idle.status);
    try testing.expectEqual(early.report, idle.report);

    // The released payload completes the image in the same lease.
    const whole_image = try decoding.advance(decoding.rest(), 0);

    try testing.expectEqual(san.SAN_STATUS_INPUT_NEEDED, whole_image.status);

    try testing.expectEqual(
        early.report[san.SAN_JOB_REPORT_LEASE],
        whole_image.report[san.SAN_JOB_REPORT_LEASE],
    );

    try testing.expectEqual(2, whole_image.report[san.SAN_JOB_REPORT_REVISION]);
    try decoding.expectRows(whole_image.report, 16);

    // The image passed every check, and the job completes only with the
    // end of its input.
    const ended = try decoding.advance(0, 1);

    try testing.expectEqual(san.SAN_STATUS_OK, ended.status);
    try testing.expectEqual(whole_image.report, ended.report);
    try decoding.drop(ended.report);
    try decoding.stop();
}

test "a truncation after early output keeps the published rows" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    const early = try decoding.advance(decoding.bytes.len * 2 / 3, 0);
    const rows = early.report[san.SAN_JOB_REPORT_COVERED_ROWS];

    const ended = try decoding.advance(0, 1);

    try testing.expectEqual(san.SAN_STATUS_TRUNCATED_CONTENT, ended.status);
    try testing.expectEqual(early.report, ended.report);
    try decoding.expectRows(ended.report, @intCast(rows));
    try decoding.drop(ended.report);
    try decoding.stop();
}

test "a cancellation after early output repeats the last publication" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    const early = try decoding.advance(decoding.bytes.len * 2 / 3, 0);
    const rows = early.report[san.SAN_JOB_REPORT_COVERED_ROWS];

    // The canceled step consumes none of the bytes that wait for it.
    try testing.expectEqual(san.SAN_STATUS_OK, feedBytes(
        &decoding.state,
        decoding.content,
        @intCast(decoding.fed),
        decoding.bytes[decoding.fed..],
        1,
    ));

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        cancelJob(&decoding.state, decoding.job),
    );

    const canceled = decoding.step();

    try testing.expectEqual(san.SAN_STATUS_CANCELED, canceled.status);
    try testing.expectEqual(early.report, canceled.report);
    try decoding.expectRows(canceled.report, @intCast(rows));
    try decoding.drop(canceled.report);
    try decoding.stop();
}

test "a cancellation inside one feed ends the decode within one row" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    // The request comes when the admission step takes the lease, inside
    // the decoder's feed, and the decoder observes it after its first
    // row, which the canceled step does not publish.
    decoding.canceling.job = decoding.job;
    decoding.canceling.at_len = striped_lease_bytes;

    const canceled = try decoding.advance(decoding.rest(), 1);

    try testing.expectEqual(1, decoding.canceling.requests);
    try testing.expectEqual(san.SAN_STATUS_CANCELED, canceled.status);

    try testing.expectEqual(
        san.SAN_NO_HANDLE,
        canceled.report[san.SAN_JOB_REPORT_LEASE],
    );

    const report = canceled.report;

    try testing.expectEqual(0, report[san.SAN_JOB_REPORT_REVISION]);
    try testing.expectEqual(0, report[san.SAN_JOB_REPORT_COVERED_ROWS]);
    try testing.expectEqual(1, report[san.SAN_JOB_REPORT_DECODED_ROWS]);
    try expectGeometry(striped_geometry, report);

    // The codec context and the unpublished lease are gone.
    const counted = try decoding.counters();

    try testing.expectEqual(0, counted[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);
    try testing.expectEqual(0, counted[output_bytes]);
    try testing.expectEqual(own_blocks + 1, decoding.backing.blocks);
    try decoding.expectSettled();
    try decoding.stop();
}

test "a held lease outlives its content, its job, and the first shutdown" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    const early = try decoding.advance(decoding.bytes.len * 2 / 3, 0);
    const rows: u32 = @intCast(early.report[san.SAN_JOB_REPORT_COVERED_ROWS]);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        closeContent(&decoding.state, decoding.content),
    );

    try testing.expectEqual(
        san.SAN_STATUS_CLOSED,
        decoding.step().status,
    );

    try decoding.expectRows(early.report, rows);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        releaseJob(&decoding.state, decoding.job),
    );

    // The lease alone keeps the shutdown pending, and its release works
    // while the engine closes.
    for (0..2) |_| {
        try testing.expectEqual(
            san.SAN_STATUS_PENDING,
            shutdown(&decoding.state, decoding.engine),
        );
    }

    try decoding.expectRows(early.report, rows);
    try decoding.drop(early.report);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        shutdown(&decoding.state, decoding.engine),
    );

    try testing.expectEqual(0, decoding.backing.blocks);

    // The handle of the lease died with its engine.
    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        decoding.release(early.report),
    );
}

test "a copy writes its rows at their place and nothing else" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    const stepped = try decoding.advance(decoding.rest(), 1);
    const report = stepped.report;

    try testing.expectEqual(san.SAN_STATUS_OK, stepped.status);

    var canvas: Canvas = try .init(8, 6);
    defer canvas.deinit();

    // Rows 3 and 4 of the image go to rows 2 and 3 of the destination.
    // A lease without alpha fills a destination of either kind alike.
    const alphas = [_]i32{ san.SAN_ALPHA_PREMULTIPLIED, san.SAN_ALPHA_OPAQUE };

    for (alphas) |alpha| {
        var wanted = canvas.taking(3, 2);

        wanted.dst_first_row = 2;
        wanted.dst_alpha = alpha;

        @memset(canvas.bytes, Canvas.untouched);

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            decoding.copy(report, wanted),
        );

        try canvas.expectUntouched(0, 2);
        try canvas.expectImage(2, decoding.samples, 3, 2);
        try canvas.expectUntouched(4, 2);
    }

    // The last row of the image fills a destination of exactly one row
    // without padding, to its last byte.
    var tight: [8 * Lease.pixel_bytes]u8 = @splat(Canvas.untouched);

    try testing.expectEqual(san.SAN_STATUS_OK, decoding.copy(report, .{
        .first_row = 15,
        .row_count = 1,
        .dst = &tight,
        .dst_width = 8,
        .dst_height = 1,
        .dst_stride = tight.len,
        .dst_first_row = 0,
        .dst_alpha = san.SAN_ALPHA_OPAQUE,
    }));

    for (0..8) |column| {
        const pixel = tight[column * Lease.pixel_bytes ..];
        const expected = decoding.samples[(15 * 8 + column) * 3 ..];

        try testing.expectEqualSlices(u8, expected[0..3], pixel[0..3]);
        try testing.expectEqual(0xff, pixel[3]);
    }

    // A copy keeps the claims: the lease still copies and still counts.
    try decoding.expectRows(report, 16);

    const counted = try decoding.counters();

    try testing.expectEqual(1, counted[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);
    try decoding.drop(report);
    try decoding.stop();
}

test "a copy refuses what its lease or its destination does not admit" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    // The lease covers some rows of the image and not all.
    const early = try decoding.advance(decoding.bytes.len * 2 / 3, 0);
    const report = early.report;
    const covered: i32 = @intCast(report[san.SAN_JOB_REPORT_COVERED_ROWS]);

    try testing.expect(covered > 1 and covered < 16);

    var canvas: Canvas = try .init(8, 16);
    defer canvas.deinit();

    const largest = std.math.maxInt(i32);
    const lowest = std.math.minInt(i32);
    const good = canvas.taking(0, covered);

    var refused: [31]CopyArguments = @splat(good);

    // A width other than the width of the lease.
    refused[0].dst_width = 7;
    refused[1].dst_width = 9;
    refused[2].dst_width = 0;
    refused[3].dst_width = -8;

    // An alpha value that the header does not define.
    refused[4].dst_alpha = 2;
    refused[5].dst_alpha = -1;

    // Fewer than one row, and rows outside the coverage, also where the
    // lease holds their pixels and where 32 bits would wrap.
    refused[6].row_count = 0;
    refused[7].row_count = -1;
    refused[8].row_count = covered + 1;
    refused[9].first_row = -1;
    refused[10].first_row = 1;
    refused[11] = canvas.taking(covered, 1);
    refused[12] = canvas.taking(largest, 1);
    refused[13] = canvas.taking(largest, largest);
    refused[14] = canvas.taking(1, largest);

    // A stride below the width times the bytes of a pixel.
    refused[15].dst_stride = 8 * Lease.pixel_bytes - 1;
    refused[16].dst_stride = 0;
    refused[17].dst_stride = -canvas.stride;

    // Destination rows outside the destination, and no destination.
    refused[18].dst_first_row = -1;
    refused[19].dst_first_row = 16 - covered + 1;
    refused[20].dst_first_row = largest;
    refused[21].dst_height = covered - 1;
    refused[22].dst_height = -16;
    refused[23].dst = null;

    // The lowest value of each argument, which no narrowing may meet.
    refused[24].first_row = lowest;
    refused[25].row_count = lowest;
    refused[26].dst_width = lowest;
    refused[27].dst_height = lowest;
    refused[28].dst_stride = lowest;
    refused[29].dst_first_row = lowest;
    refused[30].dst_alpha = lowest;

    // A handle of another generation names no lease, whatever the
    // arguments, also while the caller holds the lease of the slot.
    var stale = report;

    stale[san.SAN_JOB_REPORT_LEASE] += next_generation;

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        decoding.copy(stale, good),
    );

    for (refused) |wanted| {
        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            decoding.copy(report, wanted),
        );

        try canvas.expectUntouched(0, 16);
    }

    // The bounds themselves pass: the last covered row alone, into the
    // last row of the destination.
    var last = canvas.taking(covered - 1, 1);

    last.dst_first_row = 15;

    try testing.expectEqual(san.SAN_STATUS_OK, decoding.copy(report, last));
    try canvas.expectUntouched(0, 15);
    try canvas.expectImage(15, decoding.samples, @intCast(covered - 1), 1);

    @memset(canvas.bytes, Canvas.untouched);

    // A lease that its caller released decides before every argument,
    // and so does a handle that names no lease.
    try decoding.drop(report);

    for ([_]Report{ report, stale }) |named| {
        for (refused ++ [_]CopyArguments{good}) |wanted| {
            try testing.expectEqual(
                san.SAN_STATUS_INVALID_HANDLE,
                decoding.copy(named, wanted),
            );
        }
    }

    try canvas.expectUntouched(0, 16);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        cancelJob(&decoding.state, decoding.job),
    );

    try testing.expectEqual(san.SAN_STATUS_CANCELED, decoding.step().status);
    try decoding.stop();
}

test "bytes after the image end the job as InvalidContent" {
    var decoding: Decoding = undefined;

    try decoding.start(striped, roomy, whole);
    defer decoding.deinit();

    const whole_image = try decoding.advance(decoding.rest(), 0);

    try testing.expectEqual(san.SAN_STATUS_INPUT_NEEDED, whole_image.status);

    try testing.expectEqual(san.SAN_STATUS_OK, feedBytes(
        &decoding.state,
        decoding.content,
        @intCast(decoding.fed),
        "x",
        1,
    ));

    const trailing = decoding.step();

    try testing.expectEqual(san.SAN_STATUS_INVALID_CONTENT, trailing.status);
    try testing.expectEqual(whole_image.report, trailing.report);
    try decoding.drop(trailing.report);
    try decoding.stop();
}

test "rows publish before a failed check of the image data discredits them" {
    // One IDAT chunk holds the whole image. libpng checks the CRC of a
    // chunk after it handled the data of the chunk, so every row decodes
    // before the CRC fails. The checksum of the stream fails in the call
    // of zlib that yields the last row, and the pinned libpng raises
    // that failure before it delivers the row; a library that delivered
    // it first would cover all sixteen.
    const Case = struct { faults: fixtures.Faults, least: u32 };

    const cases = [_]Case{
        .{ .faults = .{ .crc = "IDAT".* }, .least = 16 },
        .{ .faults = .{ .adler32 = .wrong }, .least = 15 },
    };

    for (cases) |case| {
        var spec = striped;

        spec.idat_size = 0;
        spec.faults = case.faults;

        var decoding: Decoding = undefined;

        try decoding.start(spec, roomy, whole);
        defer decoding.deinit();

        const stepped = try decoding.advance(decoding.rest(), 1);

        const rows: u32 =
            @intCast(stepped.report[san.SAN_JOB_REPORT_COVERED_ROWS]);

        // The rows stay covered, and the job never completes.
        try testing.expectEqual(san.SAN_STATUS_INVALID_CONTENT, stepped.status);
        try testing.expectEqual(1, stepped.report[san.SAN_JOB_REPORT_REVISION]);
        try testing.expect(rows >= case.least and rows <= 16);
        try testing.expectEqual(rows, stepped.report[san.SAN_JOB_REPORT_DECODED_ROWS]);
        try decoding.expectRows(stepped.report, rows);
        try decoding.drop(stepped.report);
        try decoding.stop();
    }
}

/// One refusal of the admission step for the striped image.
const Refused = struct {
    limit: ?[]const u8 = null,
    value: i64 = 0,
    request: san.san_output_request = whole,
    status: san.san_status,
    geometry: Geometry,
};

fn regionOf(right: i32, bottom: i32) san.san_output_request {
    return .{
        .left = 0,
        .top = 0,
        .right = right,
        .bottom = bottom,
        .max_output_width = 0,
    };
}

const striped_without_lease: Geometry = .{
    .image = .{ 8, 16 },
    .grid = .{ 8, 16 },
};

const refusals = [_]Refused{
    // An image limit refuses before any geometry.
    .{
        .limit = "image_axis_pixels",
        .value = 15,
        .status = san.SAN_STATUS_BUDGET_EXCEEDED,
        .geometry = .{},
    },
    .{
        .limit = "image_area_pixels",
        .value = 127,
        .status = san.SAN_STATUS_BUDGET_EXCEEDED,
        .geometry = .{},
    },
    // A lease beyond its ceiling reports the image and the grid, so that
    // a request that fits can follow.
    .{
        .limit = "output_lease_bytes",
        .value = striped_lease_bytes - 1,
        .status = san.SAN_STATUS_BUDGET_EXCEEDED,
        .geometry = striped_without_lease,
    },
    .{
        .limit = "output_bytes",
        .value = striped_lease_bytes - 1,
        .status = san.SAN_STATUS_BUDGET_EXCEEDED,
        .geometry = striped_without_lease,
    },
    // A region past the image, and one inside it that is not whole.
    .{
        .request = regionOf(9, 16),
        .status = san.SAN_STATUS_UNSUPPORTED_OPERATION,
        .geometry = striped_without_lease,
    },
    .{
        .request = regionOf(8, 15),
        .status = san.SAN_STATUS_UNSUPPORTED_OPERATION,
        .geometry = striped_without_lease,
    },
    // A largest output width below the image width, with its grid.
    .{
        .request = .{
            .left = 0,
            .top = 0,
            .right = 0,
            .bottom = 0,
            .max_output_width = 4,
        },
        .status = san.SAN_STATUS_UNSUPPORTED_OPERATION,
        .geometry = .{ .image = .{ 8, 16 }, .grid = .{ 4, 8 } },
    },
    // The region decides before the ceiling of the lease.
    .{
        .limit = "output_lease_bytes",
        .value = striped_lease_bytes - 1,
        .request = regionOf(9, 16),
        .status = san.SAN_STATUS_UNSUPPORTED_OPERATION,
        .geometry = striped_without_lease,
    },
};

test "each refusal of the admission step reports its geometry" {
    inline for (refusals) |refused| {
        var limits = roomy;

        if (refused.limit) |name| @field(limits, name) = refused.value;

        var decoding: Decoding = undefined;

        try decoding.start(striped, limits, refused.request);
        defer decoding.deinit();

        const stepped = try decoding.advance(decoding.rest(), 1);

        try testing.expectEqual(refused.status, stepped.status);
        try expectGeometry(refused.geometry, stepped.report);

        try testing.expectEqual(
            san.SAN_NO_HANDLE,
            stepped.report[san.SAN_JOB_REPORT_LEASE],
        );

        try testing.expectEqual(0, stepped.report[san.SAN_JOB_REPORT_REVISION]);
        try testing.expectEqual(0, stepped.report[san.SAN_JOB_REPORT_DECODED_ROWS]);

        // The refusal kept nothing of the decode.
        const counted = try decoding.counters();

        try testing.expectEqual(0, counted[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);
        try testing.expectEqual(0, counted[output_bytes]);
        try testing.expectEqual(own_blocks + 1, decoding.backing.blocks);
        try decoding.expectSettled();
        try decoding.stop();
    }
}

test "the limits and the whole region at their bounds admit the image" {
    const Admitted = struct {
        limit: ?[]const u8 = null,
        value: i64 = 0,
        request: san.san_output_request = whole,
    };

    const cases = comptime [_]Admitted{
        .{ .limit = "image_axis_pixels", .value = 16 },
        .{ .limit = "image_area_pixels", .value = 128 },
        .{ .limit = "output_lease_bytes", .value = striped_lease_bytes },
        .{ .limit = "output_bytes", .value = striped_lease_bytes },
        .{ .request = regionOf(8, 16) },
        .{ .request = .{
            .left = 0,
            .top = 0,
            .right = 0,
            .bottom = 0,
            .max_output_width = 8,
        } },
    };

    inline for (cases) |case| {
        var limits = roomy;

        if (case.limit) |name| @field(limits, name) = case.value;

        var decoding: Decoding = undefined;

        try decoding.start(striped, limits, case.request);
        defer decoding.deinit();

        const stepped = try decoding.advance(decoding.rest(), 1);

        try testing.expectEqual(san.SAN_STATUS_OK, stepped.status);
        try expectGeometry(striped_geometry, stepped.report);
        try decoding.expectRows(stepped.report, 16);
        try decoding.drop(stepped.report);
        try decoding.stop();
    }
}

test "a PNG of another variant ends the job as UnsupportedFormat" {
    const specs = [_]fixtures.Spec{
        .{ .width = 4, .height = 2, .format = .gray8 },
        .{ .width = 4, .height = 2, .format = .rgba8 },
        .{ .width = 4, .height = 2, .format = .palette8 },
        .{ .width = 4, .height = 2, .interlaced = true },
        // Its rows are RGB samples of 8 bits, and a tRNS chunk makes one
        // color transparent, which an opaque lease would lose.
        .{ .width = 4, .height = 2, .before = &.{fixtures.trns_rgb} },
    };

    for (specs) |spec| {
        var decoding: Decoding = undefined;

        try decoding.start(spec, roomy, whole);
        defer decoding.deinit();

        const stepped = try decoding.advance(decoding.rest(), 1);

        try testing.expectEqual(san.SAN_STATUS_UNSUPPORTED_FORMAT, stepped.status);
        try testing.expectEqual(@as(Report, @splat(0)), stepped.report);
        try decoding.stop();
    }
}

test "a representation beyond the length ceiling ends as BudgetExceeded" {
    var limits = roomy;

    var decoding: Decoding = undefined;

    // The ceiling cuts the image two thirds into its bytes.
    {
        const bytes = try fixtures.encode(testing.allocator, striped);
        defer testing.allocator.free(bytes);

        limits.content_length_bytes = @intCast(bytes.len * 2 / 3);
    }

    try decoding.start(striped, limits, whole);
    defer decoding.deinit();

    const stepped = try decoding.advance(decoding.rest(), 1);
    const rows = stepped.report[san.SAN_JOB_REPORT_COVERED_ROWS];

    // The bytes before the ceiling decoded, and their rows publish with
    // the terminal outcome.
    try testing.expectEqual(san.SAN_STATUS_BUDGET_EXCEEDED, stepped.status);
    try testing.expect(rows > 0 and rows < 16);
    try decoding.expectRows(stepped.report, @intCast(rows));
    try decoding.drop(stepped.report);
    try decoding.stop();
}

test "every failed allocation of a decode ends the job and settles" {
    var failures: usize = 0;

    for (0..64) |fail_index| {
        var decoding: Decoding = undefined;

        try decoding.start(striped, roomy, whole);
        defer decoding.deinit();

        var failing: testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });

        decoding.backing.gpa = failing.allocator();

        const stepped = try decoding.advance(decoding.rest(), 1);

        decoding.backing.gpa = testing.allocator;

        if (stepped.status == san.SAN_STATUS_OK) {
            // No allocation of the decode has this index: every one
            // before it failed once.
            try decoding.expectRows(stepped.report, 16);
            try decoding.drop(stepped.report);
            try decoding.stop();

            break;
        }

        failures += 1;

        try testing.expectEqual(san.SAN_STATUS_ALLOCATION_FAILED, stepped.status);

        // A failure after the first rows leaves their lease to its
        // caller, and one before them leaves none.
        if (stepped.report[san.SAN_JOB_REPORT_LEASE] != san.SAN_NO_HANDLE) {
            try decoding.drop(stepped.report);
        }

        const counted = try decoding.counters();

        try testing.expectEqual(0, counted[san.SAN_ENGINE_COUNTERS_LEASE_COUNT]);
        try testing.expectEqual(0, counted[output_bytes]);
        try testing.expectEqual(0, counted[san.SAN_ENGINE_COUNTERS_RESERVED_BYTES]);
        try testing.expectEqual(own_blocks + 1, decoding.backing.blocks);
        try decoding.expectSettled();
        try decoding.stop();
    } else return error.TestUnexpectedResult;

    // The decoder object, libpng's structs, its row buffers, zlib's state
    // and window, and the lease, each failed once.
    try testing.expect(failures > 6);
}

// This test runs on the state of the process, after the lifecycle test,
// which needs that state before its binding.
test "the exported copy takes each argument from its own parameter" {
    const bytes = try fixtures.encode(testing.allocator, striped);
    defer testing.allocator.free(bytes);

    const samples = try fixtures.samples(testing.allocator, striped);
    defer testing.allocator.free(samples);

    var engine = unwritten;
    var content = unwritten;
    var job = unwritten;
    var report = unstepped;

    const calls = [_]san.san_status{
        san_binding_establish(san.SAN_ABI_VERSION),
        san_engine_create(&roomy, &engine),
        san_content_open(engine, &content),
        san_job_request(content, &whole, &job),
        san_content_feed(content, 0, bytes.ptr, @intCast(bytes.len), 1),
        san_job_step(job, &report),
    };

    for (calls) |status| try testing.expectEqual(san.SAN_STATUS_OK, status);

    var canvas: Canvas = try .init(8, 6);
    defer canvas.deinit();

    // Rows 4 and 5 of the image go to rows 3 and 4 of the destination.
    // The seven values after the destination all differ, so an exchange
    // of two of them copies other rows or fails a check.
    try testing.expectEqual(san.SAN_STATUS_OK, san_output_copy(
        report[san.SAN_JOB_REPORT_LEASE],
        4,
        2,
        canvas.bytes.ptr,
        8,
        6,
        canvas.stride,
        3,
        san.SAN_ALPHA_OPAQUE,
    ));

    try canvas.expectUntouched(0, 3);
    try canvas.expectImage(3, samples, 4, 2);
    try canvas.expectUntouched(5, 1);

    const ended = [_]san.san_status{
        san_output_release(report[san.SAN_JOB_REPORT_LEASE]),
        san_job_release(job),
        san_content_close(content),
        san_engine_shutdown(engine),
    };

    for (ended) |status| try testing.expectEqual(san.SAN_STATUS_OK, status);
}
