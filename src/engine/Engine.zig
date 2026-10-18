//! The engine object of ABI version 0 and the root of the engine module.
//!
//! An engine owns its accounted heap, and its own state is the first
//! block of that heap, so the state counts against the engine's budget.
//! Version 0 allows one live engine per process: creation claims the
//! engine slot, and the completed shutdown releases it. The binding flag
//! gates creation. The C ABI holds the one binding flag and the one slot
//! of the process, validates the arguments of each call, and maps the
//! Zig errors of this module to status codes; the tests create their own
//! flags and slots.
//!
//! San owns no threads and takes no locks. The caller serializes every
//! call on one engine; creation is safe from any thread, because the
//! slot is one atomic word.

const std = @import("std");

pub const Heap = @import("Heap.zig");
pub const Ledger = @import("Ledger.zig");

const Engine = @This();

/// The engine's heap. Its first block holds this engine.
heap: Heap,

/// The limits of an engine, as `san_engine_limits` carries them.
pub const Limits = struct {
    /// The aggregate budget of every native resource, in bytes.
    aggregate_budget_bytes: i64,
};

/// The failures of creation, by category.
pub const CreateError = error{
    /// The binding of the process is not established.
    BindingMismatch,
    /// The limits cannot admit the engine's own state, or another engine
    /// holds the slot.
    BudgetExceeded,
    /// The backing failed to allocate the engine's own state.
    AllocationFailed,
    /// The slot has retired its last generation, so it admits no engine
    /// again.
    EngineFailure,
};

/// The bytes that the engine's own state takes from its budget.
const footprint = Heap.accounted(@sizeOf(Engine)).?;

/// Creates an engine under `limits` in `slot`, with memory from
/// `backing`, and returns its handle. A failure releases every partial
/// resource and leaves the slot as it was.
pub fn create(
    binding: *const Binding,
    slot: *Slot,
    backing: Heap.Backing,
    limits: Limits,
) CreateError!Handle {
    if (!binding.established()) return error.BindingMismatch;

    const budget: Ledger.Budget = try .init(limits.aggregate_budget_bytes);

    var heap: Heap = .init(backing, budget);

    var reservation = try heap.ledger.reserve(footprint);
    errdefer heap.ledger.cancel(&reservation);

    const generation = try slot.claim();
    errdefer slot.abandon(generation);

    const engine = heap.createReserved(Engine, &reservation) orelse
        return error.AllocationFailed;

    // The heap moves into the block that it already counts. Nothing after
    // this point fails, so no cleanup touches the moved heap.
    engine.* = .{ .heap = heap };
    slot.publish(generation, engine);

    return .pack(generation);
}

/// Advances the shutdown of the engine of `handle`. A shutdown stops
/// admission first and releases the engine's resources only after their
/// holders return them. The pinned header defines no contexts, jobs,
/// publications, or leases, so the first call completes the shutdown: it
/// stops admission, releases the engine's state, and releases the slot.
/// The handle is invalid from then on.
pub fn shutdown(slot: *Slot, handle: Handle) error{InvalidHandle}!void {
    const engine = try slot.close(handle);

    engine.destroy();
    slot.release();
}

/// Returns the live engine of `handle`. A zero, stale, foreign, or
/// wrong-type handle fails as InvalidHandle, and the handle of an engine
/// whose shutdown has begun fails as Closed. Validation reads only the
/// handle and the slot word.
pub fn resolve(
    slot: *const Slot,
    handle: Handle,
) error{ InvalidHandle, Closed }!*Engine {
    const generation = handle.unpack() orelse return error.InvalidHandle;

    const word = slot.load(.acquire);

    if (word.generation != generation) return error.InvalidHandle;

    return switch (word.phase) {
        .live => slot.engine.?,
        .closing => error.Closed,
        .free, .creating => error.InvalidHandle,
    };
}

/// Releases the engine's state. The heap leaves the block before it
/// frees the block. Shutdown settles every other block and reservation
/// of the heap before this point, so destroy panics when the heap still
/// counts one: that is a bug in San, not a failure of the caller.
fn destroy(engine: *Engine) void {
    var heap = engine.heap;

    heap.free(engine);

    if (!heap.ledger.settled()) {
        @panic("a block or reservation outlived its engine in San's heap");
    }
}

/// The binding flag of a process: whether the binding is established.
/// The C ABI establishes it when the ABI version matches, and nothing
/// clears it.
pub const Binding = struct {
    flag: std.atomic.Value(bool) = .init(false),

    /// Establishes the binding. Repeatable, from any thread.
    pub fn establish(binding: *Binding) void {
        binding.flag.store(true, .release);
    }

    /// Reports whether the binding is established.
    pub fn established(binding: *const Binding) bool {
        return binding.flag.load(.acquire);
    }
};

/// An engine handle: the opaque 64-bit value that the ABI carries. San
/// packs the type tag and the generation of the slot into it, so zero is
/// never a handle, and the handle of an earlier engine never matches a
/// later one.
pub const Handle = enum(u64) {
    _,

    /// San's packing of a handle.
    const Bits = packed struct(u64) {
        generation: u32,
        tag: Tag,
        unused: u24 = 0,
    };

    /// The type tag of a handle. The pinned header defines only engine
    /// handles.
    const Tag = enum(u8) {
        engine = 1,
        _,
    };

    fn pack(generation: u32) Handle {
        const bits: Bits = .{ .generation = generation, .tag = .engine };

        return @fromBackingInt(@as(u64, @bitCast(bits)));
    }

    /// Returns the generation of an engine handle, or null when the value
    /// lacks San's packing of one.
    fn unpack(handle: Handle) ?u32 {
        const bits: Bits = @bitCast(@backingInt(handle));

        if (bits.tag != .engine or bits.unused != 0) return null;

        return bits.generation;
    }
};

/// The engine slot of a process. One 64-bit word holds the phase of the
/// slot and the generation of its latest engine, so creation claims the
/// slot with one compare-and-exchange and takes no lock. Every atomic
/// stays at 64 bits, which both ABIs handle without a lock.
pub const Slot = struct {
    word: std.atomic.Value(u64) = .init(0),
    /// The engine of a live or closing slot. Its writer stores it before
    /// the release store of the word that publishes it, and a reader
    /// reads it only after an acquire of that word.
    engine: ?*Engine = null,

    const Word = packed struct(u64) {
        generation: u32,
        phase: Phase,
        unused: u24 = 0,
    };

    const Phase = enum(u8) {
        /// No engine. The generation is that of the latest engine, or 0
        /// before the first.
        free,
        /// A creation holds the slot and has not published its engine.
        creating,
        /// The engine is live.
        live,
        /// A shutdown has stopped admission and holds the slot until it
        /// completes.
        closing,
    };

    fn load(slot: *const Slot, comptime order: std.builtin.AtomicOrder) Word {
        return @bitCast(slot.word.load(order));
    }

    fn store(
        slot: *Slot,
        word: Word,
        comptime order: std.builtin.AtomicOrder,
    ) void {
        slot.word.store(@bitCast(word), order);
    }

    /// Replaces `expected` with `desired` and reports whether it did.
    fn exchange(slot: *Slot, expected: Word, desired: Word) bool {
        const previous = slot.word.cmpxchgStrong(
            @bitCast(expected),
            @bitCast(desired),
            .acquire,
            .monotonic,
        );

        return previous == null;
    }

    /// Claims a free slot for a creation and returns the generation of
    /// the new engine. A taken slot and a claim that loses a race fail as
    /// BudgetExceeded. A slot whose generation would wrap has retired and
    /// fails as EngineFailure, so the handle of an earlier engine never
    /// becomes valid again.
    fn claim(slot: *Slot) error{ BudgetExceeded, EngineFailure }!u32 {
        const current = slot.load(.monotonic);

        if (current.phase != .free) return error.BudgetExceeded;

        if (current.generation == std.math.maxInt(u32)) {
            return error.EngineFailure;
        }

        const claimed: Word = .{
            .generation = current.generation + 1,
            .phase = .creating,
        };

        if (!slot.exchange(current, claimed)) return error.BudgetExceeded;

        return claimed.generation;
    }

    /// Returns a claimed slot to its earlier generation. No handle of the
    /// claimed generation exists.
    fn abandon(slot: *Slot, generation: u32) void {
        slot.store(.{ .generation = generation - 1, .phase = .free }, .release);
    }

    fn publish(slot: *Slot, generation: u32, engine: *Engine) void {
        slot.engine = engine;
        slot.store(.{ .generation = generation, .phase = .live }, .release);
    }

    /// Stops admission on the live engine of `handle` and returns it. The
    /// slot stays taken until `release`. Any other handle fails as
    /// InvalidHandle, and so does the handle of a closing engine: every
    /// shutdown completes in its first call, so a serialized caller never
    /// finds the slot closing. Once a shutdown can stay pending, a repeated
    /// call on a closing engine of its generation must continue it.
    fn close(slot: *Slot, handle: Handle) error{InvalidHandle}!*Engine {
        const generation = handle.unpack() orelse return error.InvalidHandle;

        const live: Word = .{ .generation = generation, .phase = .live };
        const closing: Word = .{ .generation = generation, .phase = .closing };

        if (!slot.exchange(live, closing)) return error.InvalidHandle;

        return slot.engine.?;
    }

    /// Frees a closing slot and keeps its generation.
    fn release(slot: *Slot) void {
        const generation = slot.load(.monotonic).generation;

        slot.engine = null;
        slot.store(.{ .generation = generation, .phase = .free }, .release);
    }
};

const testing = std.testing;
const TestBacking = Heap.TestBacking;

/// Limits that admit every engine of the tests below.
const roomy: Limits = .{ .aggregate_budget_bytes = 1 << 20 };

/// The binding flag and the slot of a process in a test.
const Process = struct {
    binding: Binding = .{},
    slot: Slot = .{},

    /// Returns a process with an established binding and a free slot.
    fn init() Process {
        var process: Process = .{};

        process.binding.establish();

        return process;
    }

    fn createEngine(
        process: *Process,
        backing: Heap.Backing,
        limits: Limits,
    ) CreateError!Handle {
        return Engine.create(&process.binding, &process.slot, backing, limits);
    }
};

/// Checks that `slot` is free at `generation` with no engine.
fn expectFree(slot: *const Slot, generation: u32) !void {
    try testing.expectEqual(
        Slot.Word{ .generation = generation, .phase = .free },
        slot.load(.monotonic),
    );

    try testing.expectEqual(null, slot.engine);
}

/// Checks that `handle` names no engine of `slot`, for a call on a live
/// engine and for shutdown, and that neither call changes the slot.
fn expectInvalid(slot: *Slot, handle: Handle) !void {
    const word = slot.load(.monotonic);

    try testing.expectError(error.InvalidHandle, resolve(slot, handle));
    try testing.expectError(error.InvalidHandle, shutdown(slot, handle));
    try testing.expectEqual(word, slot.load(.monotonic));
}

/// Checks that `engine` holds only its own state and that the ledger
/// counts exactly what the backing holds.
fn expectOwnState(
    engine: *const Engine,
    test_backing: *const TestBacking,
) !void {
    const usage = engine.heap.ledger.usage;

    try testing.expectEqual(
        Ledger.Usage{ .live = footprint, .reserved = 0, .peak = footprint },
        usage,
    );

    try testing.expectEqual(test_backing.outstanding, usage.live);
    try testing.expectEqual(test_backing.peak, usage.peak);
    try testing.expectEqual(1, test_backing.blocks);
}

/// Creates and shuts down an engine with `limits` in `process`, which
/// must admit it.
fn expectAdmits(process: *Process, limits: Limits) !void {
    var test_backing: TestBacking = .init(testing.allocator);

    const handle = try process.createEngine(test_backing.backing(), limits);

    try expectOwnState(try resolve(&process.slot, handle), &test_backing);
    try shutdown(&process.slot, handle);
    try testing.expectEqual(0, test_backing.blocks);
}

test "creation fails as BindingMismatch until the binding is established" {
    var process: Process = .{};

    var test_backing: TestBacking = .init(testing.allocator);

    try testing.expectError(
        error.BindingMismatch,
        process.createEngine(test_backing.backing(), roomy),
    );

    try testing.expectEqual(0, test_backing.peak);
    try expectFree(&process.slot, 0);
    process.binding.establish();
    process.binding.establish();
    try testing.expect(process.binding.established());
    try expectAdmits(&process, roomy);
}

test "limits that admit nothing fail as BudgetExceeded" {
    var process: Process = .init();

    const rejected = [_]i64{
        0,
        -1,
        std.math.minInt(i64),
        1,
        footprint - 1,
    };

    for (rejected) |bytes| {
        var test_backing: TestBacking = .init(testing.allocator);

        try testing.expectError(
            error.BudgetExceeded,
            process.createEngine(test_backing.backing(), .{
                .aggregate_budget_bytes = bytes,
            }),
        );

        try testing.expectEqual(0, test_backing.peak);
        try expectFree(&process.slot, 0);
    }

    try expectAdmits(&process, roomy);
}

test "the engine's own state counts against its budget" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const handle = try process.createEngine(test_backing.backing(), .{
        .aggregate_budget_bytes = footprint,
    });

    const engine = try resolve(&process.slot, handle);

    try expectOwnState(engine, &test_backing);
    try testing.expectEqual(0, engine.heap.ledger.available());
    try testing.expectEqual(null, engine.heap.alloc(0));
    try testing.expectEqual(error.BudgetExceeded, engine.heap.takeRefusal().?);
    try shutdown(&process.slot, handle);
    try testing.expectEqual(0, test_backing.outstanding);
}

test "the largest int64 budget admits the engine" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const handle = try process.createEngine(test_backing.backing(), .{
        .aggregate_budget_bytes = std.math.maxInt(i64),
    });

    const engine = try resolve(&process.slot, handle);

    try expectOwnState(engine, &test_backing);

    try testing.expectEqual(
        std.math.maxInt(i64) - footprint,
        engine.heap.ledger.available(),
    );

    try shutdown(&process.slot, handle);
    try testing.expectEqual(0, test_backing.outstanding);
}

test "a second creation while an engine is live fails as BudgetExceeded" {
    var process: Process = .init();

    var first_backing: TestBacking = .init(testing.allocator);

    var second_backing: TestBacking = .init(testing.allocator);

    const first = try process.createEngine(first_backing.backing(), roomy);

    try testing.expectError(
        error.BudgetExceeded,
        process.createEngine(second_backing.backing(), roomy),
    );

    try testing.expectEqual(0, second_backing.peak);
    try expectOwnState(try resolve(&process.slot, first), &first_backing);
    try shutdown(&process.slot, first);
    try expectFree(&process.slot, 1);
}

test "creation after a completed shutdown takes the next generation" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const previous = try process.createEngine(test_backing.backing(), roomy);

    try shutdown(&process.slot, previous);
    try testing.expectEqual(0, test_backing.outstanding);
    try expectFree(&process.slot, 1);
    try expectInvalid(&process.slot, previous);

    const next = try process.createEngine(test_backing.backing(), roomy);

    try testing.expect(next != previous);
    try testing.expectEqual(2, next.unpack().?);
    try expectInvalid(&process.slot, previous);
    try expectOwnState(try resolve(&process.slot, next), &test_backing);
    try shutdown(&process.slot, next);
    try expectInvalid(&process.slot, next);
    try expectFree(&process.slot, 2);
}

// Shutdown panics when the engine's heap has not settled, so that check
// asserts the settlement of the work below.
test "shutdown completes once the engine's heap settles its other work" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const handle = try process.createEngine(test_backing.backing(), roomy);

    const engine = try resolve(&process.slot, handle);

    var reservation = try engine.heap.ledger.reserve(256);

    const reserved = engine.heap.allocReserved(&reservation, 64).?;

    const direct = engine.heap.alloc(32).?;

    try testing.expectEqual(3, test_backing.blocks);
    engine.heap.free(direct);
    engine.heap.free(reserved);
    engine.heap.ledger.cancel(&reservation);
    try shutdown(&process.slot, handle);
    try testing.expectEqual(0, test_backing.blocks);
    try expectFree(&process.slot, 1);
}

/// A change of some fields of a handle's packing.
const Change = struct {
    generation: ?u32 = null,
    tag: ?u8 = null,
    unused: ?u24 = null,
};

/// Returns `handle` with the fields of `change` replaced.
fn altered(handle: Handle, change: Change) Handle {
    var bits: Handle.Bits = @bitCast(@backingInt(handle));

    if (change.generation) |generation| bits.generation = generation;
    if (change.tag) |tag| bits.tag = @fromBackingInt(tag);
    if (change.unused) |unused| bits.unused = unused;

    return @fromBackingInt(@as(u64, @bitCast(bits)));
}

test "zero, foreign, and wrong-type handles fail as InvalidHandle" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const handle = try process.createEngine(test_backing.backing(), roomy);

    const invalid = [_]Handle{
        @fromBackingInt(@as(u64, 0)),
        @fromBackingInt(@as(u64, std.math.maxInt(u64))),
        @fromBackingInt(@as(u64, @intFromPtr(process.slot.engine.?))),
        altered(handle, .{ .unused = 1 }),
        altered(handle, .{ .unused = std.math.maxInt(u24) }),
        altered(handle, .{ .generation = 0 }),
        altered(handle, .{ .generation = 2 }),
        altered(handle, .{ .tag = 0 }),
        altered(handle, .{ .tag = 2 }),
        altered(handle, .{ .tag = 0xff }),
    };

    for (invalid) |value| try expectInvalid(&process.slot, value);

    try expectOwnState(try resolve(&process.slot, handle), &test_backing);
    try shutdown(&process.slot, handle);
}

test "an engine handle is never zero and carries the engine tag" {
    for ([_]u32{ 0, 1, 0x8000_0000, std.math.maxInt(u32) }) |generation| {
        const handle: Handle = .pack(generation);

        try testing.expect(@backingInt(handle) != 0);
        try testing.expectEqual(generation, handle.unpack().?);
    }
}

test "a handle fails as Closed while its shutdown holds the slot" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const handle = try process.createEngine(test_backing.backing(), roomy);

    const live = process.slot.load(.monotonic);

    process.slot.store(.{ .generation = 1, .phase = .closing }, .monotonic);
    try testing.expectError(error.Closed, resolve(&process.slot, handle));
    process.slot.store(live, .monotonic);
    try shutdown(&process.slot, handle);
}

test "a creating slot rejects a guessed handle and admits no creation" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const generation = try process.slot.claim();

    try testing.expectEqual(1, generation);
    try expectInvalid(&process.slot, .pack(generation));

    try testing.expectError(
        error.BudgetExceeded,
        process.createEngine(test_backing.backing(), roomy),
    );

    process.slot.abandon(generation);
    try expectFree(&process.slot, 0);
    try expectAdmits(&process, roomy);
}

test "the slot retires before its generation wraps" {
    var process: Process = .init();

    const last = std.math.maxInt(u32);

    process.slot.store(.{ .generation = last - 1, .phase = .free }, .monotonic);

    var test_backing: TestBacking = .init(testing.allocator);

    const handle = try process.createEngine(test_backing.backing(), roomy);

    try testing.expectEqual(last, handle.unpack().?);
    try shutdown(&process.slot, handle);
    try expectFree(&process.slot, last);

    try testing.expectError(
        error.EngineFailure,
        process.createEngine(test_backing.backing(), roomy),
    );

    try expectFree(&process.slot, last);
    try testing.expectEqual(footprint, test_backing.peak);
    try testing.expectEqual(0, test_backing.outstanding);
    try expectInvalid(&process.slot, handle);
    try expectInvalid(&process.slot, .pack(0));
    try expectInvalid(&process.slot, .pack(1));
}

test "the system backing serves an engine" {
    var process: Process = .init();

    const handle = try process.createEngine(.system, roomy);

    const engine = try resolve(&process.slot, handle);

    try testing.expectEqual(footprint, engine.heap.ledger.usage.live);
    try shutdown(&process.slot, handle);
    try expectFree(&process.slot, 1);
}

/// Creates an engine with a backing over `gpa` and shuts it down. An
/// allocation failure must leave the slot free and the backing empty; it
/// then ends the run as error.OutOfMemory, as
/// std.testing.checkAllAllocationFailures expects.
fn createAndShutDown(gpa: std.mem.Allocator) !void {
    var process: Process = .init();

    var test_backing: TestBacking = .init(gpa);

    const created = process.createEngine(test_backing.backing(), roomy);

    const handle = created catch |err| switch (err) {
        error.AllocationFailed => {
            try testing.expectEqual(0, test_backing.blocks);
            try expectFree(&process.slot, 0);
            try expectAdmits(&process, roomy);

            return error.OutOfMemory;
        },
        else => |other| return other,
    };

    try expectOwnState(try resolve(&process.slot, handle), &test_backing);
    try shutdown(&process.slot, handle);
    try testing.expectEqual(0, test_backing.blocks);
}

test "every allocation failure of creation releases its partial work" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        createAndShutDown,
        .{},
    );
}

/// The threads of the creation race and of the churn, the rounds of the
/// race, the engines that each thread of the churn creates, and the
/// attempts that bound its creations, so that a slot that never frees
/// fails the churn instead of stalling it.
const race_threads = 8;
const race_rounds = 64;
const churn_engines = 200;
const churn_attempts = 10_000_000;

test "racing creations on one slot admit exactly one engine" {
    for (0..race_rounds) |_| {
        var process: Process = .init();

        var backings: [race_threads]TestBacking = undefined;
        var outcomes: [race_threads]CreateError!Handle = undefined;

        for (&backings) |*test_backing| {
            test_backing.* = .init(testing.allocator);
        }

        try race(createAtOnce, &process, &backings, &outcomes);

        var winner: ?Handle = null;

        for (outcomes, backings) |outcome, test_backing| {
            if (outcome) |handle| {
                try testing.expectEqual(null, winner);
                try testing.expectEqual(1, test_backing.blocks);
                winner = handle;
            } else |err| {
                try testing.expectEqual(error.BudgetExceeded, err);
                try testing.expectEqual(0, test_backing.peak);
            }
        }

        try shutdown(&process.slot, winner.?);
        try expectFree(&process.slot, 1);

        for (backings) |test_backing| {
            try testing.expectEqual(0, test_backing.outstanding);
        }
    }
}

/// Starts one thread per backing that runs `worker` with `shared`, the
/// backing, and the backing's element of `results` once every thread
/// exists, and joins them.
fn race(
    comptime worker: anytype,
    shared: anytype,
    backings: *[race_threads]TestBacking,
    results: anytype,
) !void {
    var go: std.atomic.Value(bool) = .init(false);

    var threads: [race_threads]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();

    // The threads wait for this store, so a failed spawn still lets the
    // spawned threads finish before the join.
    defer go.store(true, .release);

    for (backings, results) |*test_backing, *result| {
        threads[spawned] = try std.Thread.spawn(.{}, worker, .{
            shared,
            test_backing,
            result,
            &go,
        });

        spawned += 1;
    }
}

fn createAtOnce(
    process: *Process,
    test_backing: *TestBacking,
    outcome: *CreateError!Handle,
    go: *const std.atomic.Value(bool),
) void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();

    outcome.* = process.createEngine(test_backing.backing(), roomy);
}

/// The process of the churn and the count of its threads that hold an
/// engine. Each completed shutdown hands the slot, and the engine pointer
/// beside its word, to the next creation on any thread. The churn checks
/// that one engine exists at a time and that the counts settle. No plain
/// run observes a weakened memory ordering of the slot; only a
/// ThreadSanitizer run of the churn, or review, detects one.
const Churn = struct {
    process: Process,
    holders: std.atomic.Value(u32) = .init(0),
};

/// What one thread of the churn observed.
const Tally = struct {
    /// The engines that it created.
    created: u32 = 0,
    /// Its creations while another thread held an engine.
    overlaps: u32 = 0,
    /// Its outcomes that the contract of the slot excludes.
    unexpected: u32 = 0,
};

test "creations and shutdowns that churn on one slot keep one engine" {
    var churn: Churn = .{ .process = .init() };

    var backings: [race_threads]TestBacking = undefined;
    var tallies: [race_threads]Tally = undefined;

    for (&backings, &tallies) |*test_backing, *tally| {
        test_backing.* = .init(testing.allocator);
        tally.* = .{};
    }

    try race(churnAtOnce, &churn, &backings, &tallies);

    for (tallies, backings) |tally, test_backing| {
        try testing.expectEqual(Tally{ .created = churn_engines }, tally);
        try testing.expectEqual(0, test_backing.blocks);
    }

    try expectFree(&churn.process.slot, race_threads * churn_engines);
}

/// Creates its engines in `churn` once every thread exists, retries a
/// creation that finds the slot taken, and holds and shuts down each
/// engine. It stops early when its attempts run out or an outcome breaks
/// the contract of the slot.
fn churnAtOnce(
    churn: *Churn,
    test_backing: *TestBacking,
    tally: *Tally,
    go: *const std.atomic.Value(bool),
) void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();

    for (0..churn_attempts) |_| {
        if (tally.created == churn_engines) return;

        const created = churn.process.createEngine(
            test_backing.backing(),
            roomy,
        );

        const handle = created catch |err| switch (err) {
            error.BudgetExceeded => {
                std.atomic.spinLoopHint();

                continue;
            },
            else => {
                tally.unexpected += 1;

                return;
            },
        };

        hold(churn, handle, test_backing, tally);
    }
}

/// Holds the engine of `handle`, checks that no other thread holds one
/// and that it holds only its own state, and shuts it down.
fn hold(
    churn: *Churn,
    handle: Handle,
    test_backing: *const TestBacking,
    tally: *Tally,
) void {
    tally.created += 1;

    if (churn.holders.fetchAdd(1, .acq_rel) != 0) tally.overlaps += 1;

    const engine = resolve(&churn.process.slot, handle) catch {
        tally.unexpected += 1;

        return;
    };

    const own = engine.heap.ledger.usage.live == footprint and
        test_backing.blocks == 1;

    tally.unexpected += @intFromBool(!own);
    _ = churn.holders.fetchSub(1, .acq_rel);

    shutdown(&churn.process.slot, handle) catch {
        tally.unexpected += 1;
    };
}

test {
    _ = Heap;
    _ = Ledger;
}
