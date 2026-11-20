//! The Android harness of libsan_abi_test.so, the device test library of
//! the C ABI. It needs the library through DT_NEEDED and calls the
//! functions of the Bindings header as a caller would. It runs beside
//! the library on the device: `LD_LIBRARY_PATH=. ./san-abi-harness`.
//!
//! The binding flag and the engine slot belong to the process, so the
//! cases run in one fixed order: the calls before the binding is
//! established, the binding, the limits, one engine and the handles that
//! do not name it, a run of engines one after another, and creations
//! that race from several threads.
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

/// Limits that admit every engine of the harness.
const roomy: san.san_engine_limits = .{ .aggregate_budget_bytes = 1 << 20 };

/// A value that no creation writes, so that a case sees whether a call
/// wrote its output.
const unwritten: san.san_handle = 0x5a5a_5a5a_5a5a_5a5a;

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

/// Reports whether a creation under `budget` fails as `status` and
/// writes SAN_NO_HANDLE.
fn refuses(budget: i64, status: san.san_status) bool {
    const refused: san.san_engine_limits = .{
        .aggregate_budget_bytes = budget,
    };

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

    return true;
}

fn oneEngine() bool {
    const engine = createEngine() orelse return false;

    if (!refuses(1 << 20, san.SAN_STATUS_BUDGET_EXCEEDED)) return false;

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine + 1,
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
