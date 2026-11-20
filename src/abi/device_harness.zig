//! The Android harness of libsan_abi_test.so, the device test library of
//! the C ABI. It needs the library through DT_NEEDED and calls the
//! functions of the Bindings header as a caller would. It runs beside
//! the library on the device: `LD_LIBRARY_PATH=. ./san-abi-harness`.
//!
//! The binding flag and the engine slot belong to the process, so the
//! cases run in one fixed order: the calls before the binding is
//! established, the binding, the limits, one engine and the handles that
//! do not name it, the functions that reject every handle, the contents
//! of an engine, a run of engines one after another, and creations that
//! race from several threads.
//!
//! The harness prints one line per case, ending in `ok` or `FAIL`, then
//! a summary. It exits 0 only when every case passes, 1 when a case
//! fails, and 2 on a usage error.

const std = @import("std");
const san = @import("san");

pub const panic = @import("engine").android_panic;

pub const std_options: std.Options = .{
    // A fault reaches the system's crash handler unchanged, so that the
    // tombstone records the faulting frame.
    .enable_segfault_handler = false,
};

const limit_names = @typeInfo(san.san_engine_limits).@"struct".field_names;

/// The content slots of an engine of the harness, the staging of each
/// content, and the header that its block adds.
const content_slots = 4;
const portion_bytes = 4096;
const block_header = 16;

/// Limits that admit every engine of the harness: each one is 1 << 20,
/// except the content slots and the staging of a content.
const roomy: san.san_engine_limits = uniform: {
    var admitting: san.san_engine_limits = undefined;

    for (limit_names) |name| @field(admitting, name) = 1 << 20;

    admitting.content_count = content_slots;
    admitting.input_portion_bytes = portion_bytes;

    break :uniform admitting;
};

/// A value that no creation writes, so that a case sees whether a call
/// wrote its output.
const unwritten: san.san_handle = 0x5a5a_5a5a_5a5a_5a5a;

/// What turns an engine handle into the handle of the next generation:
/// the kind fills the lowest byte, and the generation starts above it.
const next_generation = 0x100;

/// The engines of the run, one after another.
const run_engines = 1000;

/// The threads of the creation race, and its rounds.
const race_threads = 8;
const race_rounds = 200;

const usage = "usage: san-abi-harness\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 1) {
        try std.Io.File.stderr().writeStreamingAll(io, usage);

        return 2;
    }

    var buffer: [4096]u8 = undefined;

    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);

    var harness: Harness = .{ .out = &stdout.interface };

    try harness.case("before the binding", beforeBinding());
    try harness.case("binding", binding());
    try harness.case("limits", limits());
    try harness.case("one engine", oneEngine());
    try harness.case("no content, job, or lease", noOtherHandle());
    try harness.case("contents", contents());
    try harness.case("engines in turn", enginesInTurn());
    try harness.case("racing creations", try racingCreations());

    try harness.out.print("summary passed={d} failed={d}\n", .{
        harness.passed,
        harness.failed,
    });

    try harness.out.flush();

    return if (harness.failed == 0) 0 else 1;
}

const Harness = struct {
    out: *std.Io.Writer,
    passed: u32 = 0,
    failed: u32 = 0,

    fn case(harness: *Harness, name: []const u8, passed: bool) !void {
        if (passed) harness.passed += 1 else harness.failed += 1;

        try harness.out.print("{s} {s}\n", .{
            name,
            if (passed) "ok" else "FAIL",
        });
    }
};

/// Reports whether a creation under the roomy limits with an aggregate
/// budget of `budget` fails as `status` and writes SAN_NO_HANDLE.
fn refuses(budget: i64, status: san.san_status) bool {
    var refused = roomy;

    refused.aggregate_budget_bytes = budget;

    return refusesUnder(refused, status);
}

fn refusesUnder(refused: san.san_engine_limits, status: san.san_status) bool {
    var engine = unwritten;

    return san.san_engine_create(&refused, &engine) == status and
        engine == san.SAN_NO_HANDLE;
}

/// Creates an engine under the roomy limits and returns its handle, or
/// null when the creation fails or writes no handle.
fn createEngine() ?san.san_handle {
    var engine = unwritten;

    if (san.san_engine_create(&roomy, &engine) != san.SAN_STATUS_OK) {
        return null;
    }

    if (engine == san.SAN_NO_HANDLE or engine == unwritten) return null;

    return engine;
}

fn beforeBinding() bool {
    return refuses(1 << 20, san.SAN_STATUS_BINDING_MISMATCH) and
        san.san_engine_shutdown(san.SAN_NO_HANDLE) ==
            san.SAN_STATUS_INVALID_HANDLE;
}

fn binding() bool {
    const others = [_]i32{
        san.SAN_ABI_VERSION + 1,
        san.SAN_ABI_VERSION - 1,
        std.math.maxInt(i32),
        std.math.minInt(i32),
    };

    for (others) |version| {
        const status = san.san_binding_establish(version);

        if (status != san.SAN_STATUS_BINDING_MISMATCH) return false;
    }

    if (!refuses(1 << 20, san.SAN_STATUS_BINDING_MISMATCH)) return false;

    for (0..2) |_| {
        const status = san.san_binding_establish(san.SAN_ABI_VERSION);

        if (status != san.SAN_STATUS_OK) return false;
    }

    // A later mismatch changes nothing: the next case still creates.
    return san.san_binding_establish(san.SAN_ABI_VERSION + 1) ==
        san.SAN_STATUS_BINDING_MISMATCH;
}

fn limits() bool {
    for ([_]i64{ 0, -1, std.math.minInt(i64), 1 }) |budget| {
        if (!refuses(budget, san.SAN_STATUS_BUDGET_EXCEEDED)) return false;
    }

    // Each limit refuses on its own.
    inline for (limit_names) |name| {
        var refused = roomy;

        @field(refused, name) = 0;

        if (!refusesUnder(refused, san.SAN_STATUS_BUDGET_EXCEEDED)) {
            return false;
        }
    }

    return true;
}

/// Reports whether `counters` shows an engine that holds only its own
/// state: two live blocks of metadata, which are also both peaks, and no
/// reservation, input, output, content, job, or lease.
fn ownStateAlone(counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64) bool {
    const live = counters[san.SAN_ENGINE_COUNTERS_LIVE_BYTES];

    if (live <= 0) return false;

    const equal_to_live = [_]usize{
        san.SAN_ENGINE_COUNTERS_PEAK_LIVE_BYTES,
        san.SAN_ENGINE_COUNTERS_PEAK_COMMITTED_BYTES,
        san.SAN_ENGINE_COUNTERS_METADATA_BYTES,
    };

    const zero = [_]usize{
        san.SAN_ENGINE_COUNTERS_RESERVED_BYTES,
        san.SAN_ENGINE_COUNTERS_INPUT_BYTES,
        san.SAN_ENGINE_COUNTERS_OUTPUT_BYTES,
        san.SAN_ENGINE_COUNTERS_CONTENT_COUNT,
        san.SAN_ENGINE_COUNTERS_JOB_COUNT,
        san.SAN_ENGINE_COUNTERS_LEASE_COUNT,
    };

    for (equal_to_live) |index| {
        if (counters[index] != live) return false;
    }

    for (zero) |index| {
        if (counters[index] != 0) return false;
    }

    return true;
}

/// Reports whether the counters read of a live engine checks its
/// arguments and reports the engine's own state on Bionic's heap, and
/// whether the content opening checks its engine and writes no handle
/// for an engine handle that is invalid.
fn engineCalls(engine: san.san_handle) bool {
    var counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(unwritten);
    var content = unwritten;

    if (san.san_engine_counters(engine + next_generation, 0, &counters) !=
        san.SAN_STATUS_INVALID_HANDLE) return false;

    if (san.san_engine_counters(engine, 2, &counters) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    // A rejected read writes no counter.
    for (counters) |counter| {
        if (counter != unwritten) return false;
    }

    // A read with a reset changes no count of an engine whose peaks
    // equal its live bytes, so the next read reports the same.
    for (0..2) |_| {
        if (san.san_engine_counters(engine, 1, &counters) !=
            san.SAN_STATUS_OK) return false;

        if (!ownStateAlone(counters)) return false;
    }

    if (san.san_content_open(engine + next_generation, &content) !=
        san.SAN_STATUS_INVALID_HANDLE) return false;

    return content == san.SAN_NO_HANDLE;
}

/// Reports whether `engine` counts `count` open contents, with the
/// staging of each in its input bytes and nothing else in its live bytes
/// beyond its own metadata.
fn holds(engine: san.san_handle, count: i64) bool {
    var counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(unwritten);

    if (san.san_engine_counters(engine, 0, &counters) !=
        san.SAN_STATUS_OK) return false;

    const input = counters[san.SAN_ENGINE_COUNTERS_INPUT_BYTES];

    return counters[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT] == count and
        input == count * (portion_bytes + block_header) and
        counters[san.SAN_ENGINE_COUNTERS_LIVE_BYTES] ==
            counters[san.SAN_ENGINE_COUNTERS_METADATA_BYTES] + input;
}

/// Opens a content in `engine` and returns its handle, or null when the
/// opening fails or writes no handle.
fn openContent(engine: san.san_handle) ?san.san_handle {
    var content = unwritten;

    if (san.san_content_open(engine, &content) != san.SAN_STATUS_OK) {
        return null;
    }

    if (content == san.SAN_NO_HANDLE or content == unwritten) return null;

    return content;
}

/// Reports whether each function of a content, a job, and a lease
/// rejects `handle` and leaves its outputs alone.
fn rejects(handle: san.san_handle) bool {
    const request: san.san_output_request = .{
        .left = 0,
        .top = 0,
        .right = 0,
        .bottom = 0,
        .max_output_width = 0,
    };

    const byte: u8 = 0;

    var job = unwritten;
    var report: [san.SAN_JOB_REPORT_LENGTH]i64 = @splat(unwritten);
    var pixel: [4]u8 = @splat(0x5a);

    const statuses = [_]san.san_status{
        san.san_content_feed(handle, 0, &byte, 1, 0),
        san.san_content_close(handle),
        san.san_job_request(handle, &request, &job),
        san.san_job_step(handle, &report),
        san.san_job_cancel(handle),
        san.san_job_release(handle),
        san.san_output_copy(handle, 0, 1, &pixel, 1, 1, 4, 0, 0),
        san.san_output_release(handle),
    };

    for (statuses) |status| {
        if (status != san.SAN_STATUS_INVALID_HANDLE) return false;
    }

    for (report) |element| {
        if (element != unwritten) return false;
    }

    return job == san.SAN_NO_HANDLE and
        std.mem.allEqual(u8, &pixel, 0x5a);
}

fn noOtherHandle() bool {
    const engine = createEngine() orelse return false;

    const handles = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine,
        engine + next_generation,
        unwritten,
        std.math.minInt(i64),
    };

    for (handles) |handle| {
        if (!rejects(handle)) return false;
    }

    return san.san_engine_shutdown(engine) == san.SAN_STATUS_OK;
}

/// Reports whether the contents of an engine fill its table, refuse the
/// next opening, reuse a freed slot under a new handle, and end with their
/// engine, so that no handle of them names a content of a later engine.
fn contents() bool {
    const engine = createEngine() orelse return false;

    var opened: [content_slots + 1]san.san_handle = undefined;

    for (opened[0..content_slots], 1..) |*content, count| {
        content.* = openContent(engine) orelse return false;

        if (!holds(engine, @intCast(count))) return false;
    }

    var refused = unwritten;

    if (san.san_content_open(engine, &refused) !=
        san.SAN_STATUS_BUDGET_EXCEEDED) return false;

    if (refused != san.SAN_NO_HANDLE or !holds(engine, content_slots)) {
        return false;
    }

    // The freed slot serves the next opening under another handle, and
    // the handle that named it before names nothing.
    if (san.san_content_close(opened[1]) != san.SAN_STATUS_OK) return false;
    if (!holds(engine, content_slots - 1)) return false;
    if (!rejects(opened[1])) return false;

    opened[content_slots] = openContent(engine) orelse return false;

    if (!holds(engine, content_slots)) return false;

    for (opened, 0..) |content, at| {
        if (std.mem.findScalar(san.san_handle, opened[at + 1 ..], content) !=
            null) return false;
    }

    if (san.san_engine_shutdown(engine) != san.SAN_STATUS_OK) return false;

    for (opened) |content| {
        if (!rejects(content)) return false;
    }

    // A later engine, with a content in the slot of the first one,
    // still rejects every handle of the earlier engine.
    const later = createEngine() orelse return false;

    const content = openContent(later) orelse return false;

    for (opened) |earlier| {
        if (earlier == content or !rejects(earlier)) return false;
    }

    return holds(later, 1) and
        san.san_engine_shutdown(later) == san.SAN_STATUS_OK;
}

fn oneEngine() bool {
    const engine = createEngine() orelse return false;

    if (!refuses(1 << 20, san.SAN_STATUS_BUDGET_EXCEEDED)) return false;
    if (!engineCalls(engine)) return false;

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine + next_generation,
        -engine,
        unwritten,
        std.math.minInt(i64),
    };

    for (invalid) |handle| {
        const status = san.san_engine_shutdown(handle);

        if (status != san.SAN_STATUS_INVALID_HANDLE) return false;
    }

    return san.san_engine_shutdown(engine) == san.SAN_STATUS_OK and
        san.san_engine_shutdown(engine) == san.SAN_STATUS_INVALID_HANDLE;
}

fn enginesInTurn() bool {
    var previous: san.san_handle = san.SAN_NO_HANDLE;

    for (0..run_engines) |_| {
        const engine = createEngine() orelse return false;

        if (engine == previous) return false;

        // The handle of the earlier engine names no engine now.
        if (san.san_engine_shutdown(previous) !=
            san.SAN_STATUS_INVALID_HANDLE) return false;

        if (san.san_engine_shutdown(engine) != san.SAN_STATUS_OK) return false;

        previous = engine;
    }

    return true;
}

/// The outcome of one creation of the race.
const Attempt = struct {
    status: san.san_status = san.SAN_STATUS_ENGINE_FAILURE,
    engine: san.san_handle = unwritten,
};

/// Reports whether, in every round, exactly one of the racing creations
/// succeeds and every other one fails as BudgetExceeded without a handle.
fn racingCreations() !bool {
    for (0..race_rounds) |_| {
        var attempts: [race_threads]Attempt = @splat(.{});

        try race(&attempts);

        var winner: ?san.san_handle = null;

        for (attempts) |attempt| switch (attempt.status) {
            san.SAN_STATUS_OK => {
                if (winner != null) return false;

                winner = attempt.engine;
            },
            san.SAN_STATUS_BUDGET_EXCEEDED => {
                if (attempt.engine != san.SAN_NO_HANDLE) return false;
            },
            else => return false,
        };

        const engine = winner orelse return false;

        if (san.san_engine_shutdown(engine) != san.SAN_STATUS_OK) return false;
    }

    return true;
}

/// Starts one thread per attempt, lets them create at once, and joins
/// them.
fn race(attempts: *[race_threads]Attempt) !void {
    var go: std.atomic.Value(bool) = .init(false);

    var threads: [race_threads]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();

    // The threads wait for this store, so a failed spawn still lets the
    // spawned threads finish before the join.
    defer go.store(true, .release);

    for (attempts) |*attempt| {
        threads[spawned] = try std.Thread.spawn(.{}, createAtOnce, .{
            attempt,
            &go,
        });

        spawned += 1;
    }
}

fn createAtOnce(
    attempt: *Attempt,
    go: *const std.atomic.Value(bool),
) void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();

    attempt.status = san.san_engine_create(&roomy, &attempt.engine);
}
