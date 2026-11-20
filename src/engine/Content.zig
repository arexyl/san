//! A content context: the slot of one content in the table of its
//! engine. An open content owns the staging of one input portion, which
//! its opening admits and allocates as input, so that a feed only
//! copies.
//!
//! The table is one block of the engine, sized at creation from the
//! count limit of contents, and its slots never move. A handle names a
//! slot by its index and by the generation of the opening. Validation
//! reads the handle, the engine slot of the process, and the slot of the
//! table, in that order, and never follows a value that it has not
//! checked.

const std = @import("std");
const Engine = @import("Engine.zig");
const handles = @import("handles.zig");

const Heap = Engine.Heap;

const Content = @This();

state: State = .vacant,

pub const State = union(enum) {
    /// No content. The slot is free for an opening.
    vacant,
    open: Open,
    /// A content that the shutdown of its engine closed. The slot keeps
    /// the generation of the opening, so the handle fails as Closed, not
    /// as InvalidHandle, until the shutdown completes.
    shut: handles.Generation,
};

pub const Open = struct {
    /// The generation of the opening, which the handle repeats.
    generation: handles.Generation,
    /// The staging of one input portion.
    staging: []align(Heap.header_size) u8,
};

/// A content handle: the opaque 64-bit value that the ABI carries.
pub const Handle = enum(u64) {
    _,

    fn pack(index: handles.Index, generation: handles.Generation) Handle {
        const bits: handles.Slotted = .{
            .tag = .content,
            .index = index,
            .generation = generation,
        };

        return @fromBackingInt(@as(u64, @bitCast(bits)));
    }
};

/// An open content of a live engine. Only `resolve` makes one, so a
/// function that takes one validates nothing again.
pub const Live = struct {
    engine: *Engine,
    content: *Content,
};

/// Returns the open content of `value` in the engine of `slot`. A zero,
/// stale, foreign, or wrong-type handle fails as InvalidHandle, also
/// when no engine lives. A content that was open when the shutdown of
/// its engine began fails as Closed.
pub fn resolve(
    slot: *const Engine.Slot,
    value: Handle,
) error{ InvalidHandle, Closed }!Live {
    const bits: handles.Slotted = @bitCast(@backingInt(value));

    if (bits.tag != .content) return error.InvalidHandle;

    const held = slot.held() orelse return error.InvalidHandle;

    const contents = held.engine.contents;

    if (bits.index >= contents.len) return error.InvalidHandle;

    const content = &contents[bits.index];

    const generation = switch (content.state) {
        .vacant => return error.InvalidHandle,
        .open => |open_state| open_state.generation,
        .shut => |generation| generation,
    };

    if (generation != bits.generation) return error.InvalidHandle;

    // Only a shutdown shuts a content, so a live engine holds none.
    if (held.closing) return error.Closed;

    return .{ .engine = held.engine, .content = content };
}

/// The failures of an opening, by category.
pub const OpenError = error{
    /// Every slot holds a content, or the budget cannot admit the
    /// staging.
    BudgetExceeded,
    /// The backing failed to allocate the staging.
    AllocationFailed,
    /// The serial of the process has retired.
    EngineFailure,
};

/// Opens a content in `engine` and returns its handle. A failure keeps
/// nothing.
pub fn open(engine: *Engine) OpenError!Handle {
    const index = for (engine.contents, 0..) |content, at| {
        if (content.state == .vacant) break at;
    } else return error.BudgetExceeded;

    if (engine.serial.retired()) return error.EngineFailure;

    const size = engine.input_portion_bytes;

    const bytes = Heap.accounted(size) orelse return error.BudgetExceeded;

    var reservation = try engine.heap.ledger.reserve(.input, bytes);
    defer engine.heap.ledger.cancel(&reservation);

    // A refusal that an earlier call left would name the wrong cause.
    _ = engine.heap.takeRefusal();

    const staging = engine.heap.allocReserved(&reservation, size) orelse
        return engine.heap.takeRefusal() orelse error.EngineFailure;

    const generation = engine.serial.take();

    engine.contents[index].state = .{ .open = .{
        .generation = generation,
        .staging = staging[0..size],
    } };

    return .pack(@intCast(index), generation);
}

/// Closes `live`: releases its staging and frees its slot. Its handle
/// is invalid from then on.
pub fn close(live: Live) void {
    live.engine.heap.free(live.content.state.open.staging.ptr);
    live.content.state = .vacant;
}

/// Shuts every open content of `engine`, whose shutdown has begun: it
/// releases each staging and keeps each generation.
pub fn shutAll(engine: *Engine) void {
    for (engine.contents) |*content| switch (content.state) {
        .vacant, .shut => {},
        .open => |open_state| {
            engine.heap.free(open_state.staging.ptr);
            content.state = .{ .shut = open_state.generation };
        },
    };
}

/// Returns the count of the open contents of `engine`.
pub fn countOpen(engine: *const Engine) u64 {
    var count: u64 = 0;

    for (engine.contents) |content| {
        count += @intFromBool(content.state == .open);
    }

    return count;
}

const testing = std.testing;
const TestBacking = Heap.TestBacking;

/// The staging that each content of the tests below opens, in bytes.
const portion = 64;

/// What a staging takes from the budget: its portion and its header.
const staged = portion + Heap.header_size;

/// A process in a test: its binding flag and its engine slot.
const Process = struct {
    binding: Engine.Binding = .{},
    slot: Engine.Slot = .{},

    fn init() Process {
        var process: Process = .{};

        process.binding.establish();

        return process;
    }

    fn create(
        process: *Process,
        test_backing: *TestBacking,
        limits: Engine.Limits,
    ) Engine.CreateError!Engine.Handle {
        return Engine.create(
            &process.binding,
            &process.slot,
            test_backing.backing(),
            limits,
        );
    }

    fn engineOf(process: *Process, handle: Engine.Handle) !*Engine {
        return Engine.resolve(&process.slot, handle);
    }

    /// Closes the content of `handle`.
    fn closeContent(process: *Process, handle: Handle) !void {
        close(try resolve(&process.slot, handle));
    }
};

/// Returns limits of `count` contents of one portion each, with every
/// other limit roomy.
fn limitsFor(count: i64) Engine.Limits {
    var limits: Engine.Limits = undefined;

    inline for (Engine.Limits.names) |name| @field(limits, name) = 1 << 20;

    limits.content_count = count;
    limits.input_portion_bytes = portion;

    return limits;
}

/// Returns the bytes that an engine of `count` slots takes for itself:
/// the engine and the array of slots, a block each.
fn ownBytes(count: usize) u64 {
    return Heap.accounted(@sizeOf(Engine)).? +
        Heap.accounted(count * @sizeOf(Content)).?;
}

fn unpack(handle: Handle) handles.Slotted {
    return @bitCast(@backingInt(handle));
}

fn handleOf(tag: u8, index: u16, generation: handles.Generation) Handle {
    const bits: handles.Slotted = .{
        .tag = @fromBackingInt(tag),
        .index = index,
        .generation = generation,
    };

    return @fromBackingInt(@as(u64, @bitCast(bits)));
}

/// What a call that keeps nothing leaves unchanged. The peaks are
/// high-water marks, so a refused reservation may raise them.
const Snapshot = struct {
    open: u64,
    live: u64,
    reserved: u64,
    input: u64,
    reserved_metadata: u64,
    blocks: u64,
    next: handles.Generation,
};

fn snapshot(engine: *const Engine, test_backing: *const TestBacking) Snapshot {
    const usage = engine.heap.ledger.usage;

    return .{
        .open = countOpen(engine),
        .live = usage.live,
        .reserved = usage.reserved,
        .input = usage.input,
        .reserved_metadata = engine.heap.ledger.reserved_metadata,
        .blocks = test_backing.blocks,
        .next = engine.serial.next,
    };
}

/// Checks that `engine` holds its own state and `count` stagings, and
/// that the ledger counts exactly what the backing holds.
fn expectHolds(
    engine: *const Engine,
    test_backing: *const TestBacking,
    count: u64,
) !void {
    const usage = engine.heap.ledger.usage;

    try testing.expectEqual(count, countOpen(engine));
    try testing.expectEqual(count * staged, usage.input);
    try testing.expectEqual(0, usage.reserved);
    try testing.expectEqual(test_backing.outstanding, usage.live);
    try testing.expectEqual(2 + count, test_backing.blocks);
}

test "an invalid handle fails as InvalidHandle and changes nothing" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const engine = try process.engineOf(engine_handle);

    const content = try open(engine);

    const bits = unpack(content);

    const before = snapshot(engine, &test_backing);

    const invalid = [_]Handle{
        @fromBackingInt(@as(u64, 0)),
        @fromBackingInt(@backingInt(engine_handle)),
        handleOf(0, bits.index, bits.generation),
        handleOf(1, bits.index, bits.generation),
        handleOf(3, bits.index, bits.generation),
        handleOf(0xff, bits.index, bits.generation),
        // The slot after the open one is vacant.
        handleOf(2, 1, bits.generation),
        // The table has two slots.
        handleOf(2, 2, bits.generation),
        handleOf(2, 3, bits.generation),
        handleOf(2, std.math.maxInt(handles.Index), bits.generation),
        @fromBackingInt(@as(u64, std.math.maxInt(u64))),
        handleOf(2, bits.index, bits.generation + 1),
        handleOf(2, bits.index, bits.generation - 1),
    };

    for (invalid) |value| {
        try testing.expectError(
            error.InvalidHandle,
            resolve(&process.slot, value),
        );
    }

    try testing.expectEqual(before, snapshot(engine, &test_backing));
    try expectHolds(engine, &test_backing, 1);

    try testing.expectEqual(
        engine,
        (try resolve(&process.slot, content)).engine,
    );

    try Engine.shutdown(&process.slot, engine_handle);
}

test "a handle is stale after its content closes" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const engine = try process.engineOf(engine_handle);

    const content = try open(engine);

    try expectHolds(engine, &test_backing, 1);
    try process.closeContent(content);
    try expectHolds(engine, &test_backing, 0);

    try testing.expectError(
        error.InvalidHandle,
        resolve(&process.slot, content),
    );

    try testing.expectError(
        error.InvalidHandle,
        process.closeContent(content),
    );

    try expectHolds(engine, &test_backing, 0);
    try Engine.shutdown(&process.slot, engine_handle);
}

test "a handle is stale after its engine shuts down" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const content = try open(try process.engineOf(engine_handle));

    try Engine.shutdown(&process.slot, engine_handle);
    try testing.expectEqual(0, test_backing.blocks);

    try testing.expectError(
        error.InvalidHandle,
        resolve(&process.slot, content),
    );
}

test "a handle of a finished engine fails under a later engine" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const first_engine = try process.create(&test_backing, limitsFor(2));

    const first = try open(try process.engineOf(first_engine));

    try Engine.shutdown(&process.slot, first_engine);

    const second_engine = try process.create(&test_backing, limitsFor(2));

    const engine = try process.engineOf(second_engine);

    const second = try open(engine);

    // Both contents sit at the same index.
    try testing.expectEqual(unpack(first).index, unpack(second).index);
    try testing.expect(unpack(first).generation != unpack(second).generation);
    try testing.expect(first != second);

    try testing.expectError(
        error.InvalidHandle,
        resolve(&process.slot, first),
    );

    try testing.expectEqual(
        engine,
        (try resolve(&process.slot, second)).engine,
    );

    try expectHolds(engine, &test_backing, 1);
    try Engine.shutdown(&process.slot, second_engine);
    try testing.expectEqual(0, test_backing.blocks);
}

test "a retired serial fails every opening as EngineFailure" {
    var process: Process = .init();

    const last = std.math.maxInt(handles.Generation);

    process.slot.serial = .{ .next = last - 1 };

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const engine = try process.engineOf(engine_handle);

    const content = try open(engine);

    try testing.expectEqual(last - 1, unpack(content).generation);
    try testing.expect(engine.serial.retired());

    const before = snapshot(engine, &test_backing);

    try testing.expectError(error.EngineFailure, open(engine));
    try testing.expectEqual(before, snapshot(engine, &test_backing));
    try testing.expectEqual(1, countOpen(engine));
    try testing.expect(engine.serial.retired());
    try Engine.shutdown(&process.slot, engine_handle);
    try testing.expect(process.slot.serial.retired());

    const later_handle = try process.create(&test_backing, limitsFor(2));

    const later = try process.engineOf(later_handle);

    try testing.expectError(error.EngineFailure, open(later));
    try expectHolds(later, &test_backing, 0);
    try testing.expectEqual(0, countOpen(later));
    try Engine.shutdown(&process.slot, later_handle);
    try testing.expectEqual(0, test_backing.blocks);
}

test "the table admits its slots and refuses the next opening" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(3));

    const engine = try process.engineOf(engine_handle);

    var opened: [3]Handle = undefined;

    for (&opened, 0..) |*content, index| {
        content.* = try open(engine);

        // The lowest vacant slot serves each opening.
        try testing.expectEqual(index, unpack(content.*).index);
        try testing.expectEqual(index + 1, countOpen(engine));
    }

    try expectHolds(engine, &test_backing, 3);

    const before = snapshot(engine, &test_backing);

    try testing.expectError(error.BudgetExceeded, open(engine));
    try testing.expectEqual(before, snapshot(engine, &test_backing));

    try process.closeContent(opened[1]);
    try testing.expectEqual(2, countOpen(engine));

    const reused = try open(engine);

    try testing.expectEqual(1, unpack(reused).index);
    try testing.expectEqual(before.next, unpack(reused).generation);
    try testing.expect(reused != opened[1]);
    try testing.expectEqual(3, countOpen(engine));

    try testing.expectError(
        error.InvalidHandle,
        resolve(&process.slot, opened[1]),
    );

    try expectHolds(engine, &test_backing, 3);
    try Engine.shutdown(&process.slot, engine_handle);
    try testing.expectEqual(0, test_backing.blocks);
}

test "a budget that admits n stagings refuses the next" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    var limits = limitsFor(4);

    limits.aggregate_budget_bytes = @intCast(ownBytes(4) + 2 * staged);

    const engine_handle = try process.create(&test_backing, limits);

    const engine = try process.engineOf(engine_handle);

    _ = try open(engine);
    _ = try open(engine);

    try testing.expectEqual(0, engine.heap.ledger.available());

    const before = snapshot(engine, &test_backing);

    try testing.expectError(error.BudgetExceeded, open(engine));
    try testing.expectEqual(before, snapshot(engine, &test_backing));
    try expectHolds(engine, &test_backing, 2);
    try Engine.shutdown(&process.slot, engine_handle);
    try testing.expectEqual(0, test_backing.blocks);
}

test "an opening that fails on the backing keeps nothing" {
    var process: Process = .init();

    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 2,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const engine = try process.engineOf(engine_handle);

    const before = snapshot(engine, &test_backing);

    try testing.expectError(error.AllocationFailed, open(engine));
    try testing.expectEqual(before, snapshot(engine, &test_backing));
    try testing.expectEqual(0, countOpen(engine));
    try Engine.shutdown(&process.slot, engine_handle);
    try testing.expectEqual(0, test_backing.blocks);
}

/// Opens two contents, closes the first, and leaves the second open. A
/// failed allocation ends the run as error.AllocationFailed.
fn openTwo(process: *Process, engine: *Engine) !void {
    const first = try open(engine);

    try testing.expectEqual(1, countOpen(engine));

    const second = try open(engine);

    try testing.expectEqual(2, countOpen(engine));
    try process.closeContent(first);
    try testing.expectEqual(1, countOpen(engine));
    try testing.expectEqual(1, unpack(second).index);
}

/// Checks that no block and no engine remains and that the slot admits a
/// new engine.
fn expectReleased(process: *Process, test_backing: *const TestBacking) !void {
    try testing.expectEqual(0, test_backing.blocks);
    try testing.expectEqual(0, test_backing.outstanding);
    try testing.expectEqual(null, process.slot.held());
    try testing.expectEqual(null, process.slot.engine);

    var later_backing: TestBacking = .init(testing.allocator);

    const later = try process.create(&later_backing, limitsFor(2));

    try Engine.shutdown(&process.slot, later);
    try testing.expectEqual(0, later_backing.blocks);
}

/// Creates an engine over `gpa`, runs `openTwo`, and shuts the engine
/// down with one content open. An allocation failure ends the run as
/// error.OutOfMemory, as std.testing.checkAllAllocationFailures expects.
fn openAndShutDown(gpa: std.mem.Allocator) !void {
    var process: Process = .init();

    var test_backing: TestBacking = .init(gpa);

    const created = process.create(&test_backing, limitsFor(2));

    const engine_handle = created catch |err| switch (err) {
        error.AllocationFailed => {
            try expectReleased(&process, &test_backing);

            return error.OutOfMemory;
        },
        else => |other| return other,
    };

    const engine = try process.engineOf(engine_handle);

    openTwo(&process, engine) catch |err| switch (err) {
        error.AllocationFailed => {
            try Engine.shutdown(&process.slot, engine_handle);
            try expectReleased(&process, &test_backing);

            return error.OutOfMemory;
        },
        else => |other| return other,
    };

    try expectHolds(engine, &test_backing, 1);
    try Engine.shutdown(&process.slot, engine_handle);
    try expectReleased(&process, &test_backing);
}

test "every allocation failure of the contents releases its partial work" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        openAndShutDown,
        .{},
    );
}

test "the handles of a churn over three tables are distinct and nonzero" {
    const slots = 4;
    const rounds = 3;

    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(slots));

    const engine = try process.engineOf(engine_handle);

    var issued: [rounds * slots]Handle = undefined;

    for (0..rounds) |round| {
        for (0..slots) |index| {
            const content = try open(engine);

            issued[round * slots + index] = content;
        }

        try testing.expectEqual(slots, countOpen(engine));

        for (issued[round * slots ..][0..slots]) |content| {
            try process.closeContent(content);
        }

        try testing.expectEqual(0, countOpen(engine));
    }

    for (issued, 0..) |content, at| {
        try testing.expect(@backingInt(content) != 0);

        for (issued[at + 1 ..]) |other| try testing.expect(content != other);
    }

    try expectHolds(engine, &test_backing, 0);
    try Engine.shutdown(&process.slot, engine_handle);
}

test "a shutdown returns the serial to the slot and closes every content" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(3));

    const engine = try process.engineOf(engine_handle);

    _ = try open(engine);
    _ = try open(engine);

    try testing.expectEqual(2, countOpen(engine));
    try testing.expectEqual(1, process.slot.serial.next);
    try testing.expectEqual(3, engine.serial.next);
    try expectHolds(engine, &test_backing, 2);
    try Engine.shutdown(&process.slot, engine_handle);
    try testing.expectEqual(3, process.slot.serial.next);
    try testing.expectEqual(0, test_backing.blocks);
    try testing.expectEqual(0, test_backing.outstanding);
}
