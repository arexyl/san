//! A content context: the slot of one content in the table of its
//! engine. An open content owns the staging of one input portion, which
//! its opening admits and allocates as input, so that a feed only
//! copies. It admits one job in its lifetime, and it names that job
//! exactly while the job is live.
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
const Job = Engine.Job;

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
    /// The bytes of the representation that the feeds supplied.
    received: u64 = 0,
    /// The bytes of the staging that the latest feed supplied, and those
    /// of them that a step consumed: consumed <= staged <= staging.len.
    staged: usize = 0,
    consumed: usize = 0,
    /// Whether a feed reported the end of the input.
    ended: bool = false,
    /// The one job of the content's lifetime. Only the request of a job
    /// makes the link, and only the end of that job removes it.
    job: union(enum) { none, live: *Job, ended } = .none,
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

/// An open content whose job has not ended, so that it still takes
/// input. Only `feedable` makes one.
pub const Feedable = struct {
    open: *Open,
};

/// Returns `live` for a feed. A content whose job has its terminal
/// outcome fails as Closed.
pub fn feedable(live: Live) error{Closed}!Feedable {
    const open_state = &live.content.state.open;

    if (open_state.job == .ended) return error.Closed;

    return .{ .open = open_state };
}

/// One portion of input with its shape checked: the bytes fit the
/// staging of their content, and no bytes come only with the end.
pub const Portion = struct {
    /// The position of the first byte in the representation.
    position: u64,
    bytes: []const u8,
    /// Whether the input ends after the bytes.
    end: bool,
};

/// Copies `input` into the staging of `target` and records the end of
/// the input. A portion after the end, one that follows bytes that no
/// step consumed, and one at another position than the bytes received
/// fail as BindingMismatch and change nothing.
pub fn feed(target: Feedable, input: Portion) error{BindingMismatch}!void {
    const open_state = target.open;

    if (open_state.ended) return error.BindingMismatch;
    if (open_state.consumed != open_state.staged) return error.BindingMismatch;
    if (input.position != open_state.received) return error.BindingMismatch;

    @memcpy(open_state.staging[0..input.bytes.len], input.bytes);

    open_state.staged = input.bytes.len;
    open_state.consumed = 0;
    open_state.received += input.bytes.len;
    open_state.ended = input.end;
}

/// Closes `live`: ends its live job as canceled, releases its staging,
/// and frees its slot. Its handle is invalid from then on, and its job
/// stays owned.
pub fn close(live: Live) void {
    const open_state = &live.content.state.open;

    // The end of the job removes its link to this content.
    switch (open_state.job) {
        .none, .ended => {},
        .live => |job| job.end(live.engine),
    }

    live.engine.heap.free(open_state.staging.ptr);
    live.content.state = .vacant;
}

/// Shuts every open content of `engine`, whose shutdown has begun and
/// has ended every job: it releases each staging and keeps each
/// generation.
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
            Engine.Codec.Scripted.opener,
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

    /// Shuts down the engine of `handle`, which owns no job, in one
    /// call.
    fn shutDown(process: *Process, handle: Engine.Handle) !void {
        try testing.expectEqual(
            .complete,
            try Engine.shutdown(&process.slot, handle),
        );
    }

    /// Feeds `bytes` to the content of `handle` as its bytes from
    /// `position` on.
    fn feedContent(
        process: *Process,
        handle: Handle,
        position: u64,
        bytes: []const u8,
        end: bool,
    ) !void {
        const target = try feedable(try resolve(&process.slot, handle));

        try feed(target, .{ .position = position, .bytes = bytes, .end = end });
    }
};

/// The job slots of each engine of the tests below.
const job_slots = 2;

/// The blocks of an engine's own state: the engine and the slots of its
/// contents, of its jobs, and of its leases.
const own_blocks = 4;

/// Returns limits of `count` contents of one portion each, with every
/// other limit roomy.
fn limitsFor(count: i64) Engine.Limits {
    var limits: Engine.Limits = undefined;

    inline for (Engine.Limits.names) |name| @field(limits, name) = 1 << 20;

    limits.content_count = count;
    limits.job_count = job_slots;
    limits.output_lease_count = job_slots;
    limits.input_portion_bytes = portion;

    return limits;
}

/// Returns the bytes that an engine of `count` content slots takes for
/// itself: the engine and each array of slots, a block each.
fn ownBytes(count: usize) u64 {
    return Heap.accounted(@sizeOf(Engine)).? +
        Heap.accounted(count * @sizeOf(Content)).? +
        Heap.accounted(job_slots * @sizeOf(Job)).? +
        Heap.accounted(job_slots * @sizeOf(Engine.Lease)).?;
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
    try testing.expectEqual(own_blocks + count, test_backing.blocks);
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

    try process.shutDown(engine_handle);
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
    try process.shutDown(engine_handle);
}

test "a handle is stale after its engine shuts down" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const content = try open(try process.engineOf(engine_handle));

    try process.shutDown(engine_handle);
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

    try process.shutDown(first_engine);

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
    try process.shutDown(second_engine);
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
    try process.shutDown(engine_handle);
    try testing.expect(process.slot.serial.retired());

    const later_handle = try process.create(&test_backing, limitsFor(2));

    const later = try process.engineOf(later_handle);

    try testing.expectError(error.EngineFailure, open(later));
    try expectHolds(later, &test_backing, 0);
    try testing.expectEqual(0, countOpen(later));
    try process.shutDown(later_handle);
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
    try process.shutDown(engine_handle);
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
    try process.shutDown(engine_handle);
    try testing.expectEqual(0, test_backing.blocks);
}

test "an opening that fails on the backing keeps nothing" {
    var process: Process = .init();

    // The staging is the first allocation after the engine's own blocks.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = own_blocks,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const engine = try process.engineOf(engine_handle);

    const before = snapshot(engine, &test_backing);

    try testing.expectError(error.AllocationFailed, open(engine));
    try testing.expectEqual(before, snapshot(engine, &test_backing));
    try testing.expectEqual(0, countOpen(engine));
    try process.shutDown(engine_handle);
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

    try process.shutDown(later);
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
            try process.shutDown(engine_handle);
            try expectReleased(&process, &test_backing);

            return error.OutOfMemory;
        },
        else => |other| return other,
    };

    try expectHolds(engine, &test_backing, 1);
    try process.shutDown(engine_handle);
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
    try process.shutDown(engine_handle);
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
    try process.shutDown(engine_handle);
    try testing.expectEqual(3, process.slot.serial.next);
    try testing.expectEqual(0, test_backing.blocks);
    try testing.expectEqual(0, test_backing.outstanding);
}

/// Returns the state of the open content of `handle`.
fn openOf(process: *Process, handle: Handle) !*Open {
    const live = try resolve(&process.slot, handle);

    return &live.content.state.open;
}

test "a feed copies its portion and counts the bytes received" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const engine = try process.engineOf(engine_handle);

    const content = try open(engine);

    const open_state = try openOf(&process, content);

    const first = "ten bytes!";

    try testing.expectEqual(portion, open_state.staging.len);
    try process.feedContent(content, 0, first, false);
    try testing.expectEqualSlices(u8, first, open_state.staging[0..first.len]);
    try testing.expectEqual(first.len, open_state.staged);
    try testing.expectEqual(0, open_state.consumed);
    try testing.expectEqual(first.len, open_state.received);
    try testing.expect(!open_state.ended);

    // No step consumes input yet, so the test consumes each portion.
    open_state.consumed = open_state.staged;

    var full: [portion]u8 = undefined;

    for (&full, 0..) |*byte, at| byte.* = @intCast(at);

    // A portion of the whole staging, then the end without a byte.
    try process.feedContent(content, first.len, &full, false);
    try testing.expectEqualSlices(u8, &full, open_state.staging);
    try testing.expectEqual(portion, open_state.staged);
    try testing.expectEqual(0, open_state.consumed);
    try testing.expectEqual(first.len + portion, open_state.received);
    try testing.expect(!open_state.ended);

    open_state.consumed = open_state.staged;

    try process.feedContent(content, first.len + portion, "", true);
    try testing.expectEqual(0, open_state.staged);
    try testing.expectEqual(0, open_state.consumed);
    try testing.expectEqual(first.len + portion, open_state.received);
    try testing.expect(open_state.ended);

    // A feed only copies: it allocates and reserves nothing.
    try expectHolds(engine, &test_backing, 1);
    try process.shutDown(engine_handle);
}

test "a feed out of order fails as BindingMismatch and changes nothing" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const content = try open(try process.engineOf(engine_handle));

    const open_state = try openOf(&process, content);

    // At another position than the bytes received.
    for ([_]u64{ 1, portion, std.math.maxInt(u64) }) |position| {
        try testing.expectError(
            error.BindingMismatch,
            process.feedContent(content, position, "x", false),
        );
    }

    try testing.expectEqual(0, open_state.received);
    try testing.expectEqual(0, open_state.staged);
    try process.feedContent(content, 0, "abc", false);

    // After bytes that no step consumed, whole or in part, at the
    // position that follows them.
    for ([_]usize{ 0, 2 }) |consumed| {
        open_state.consumed = consumed;

        const before = open_state.*;

        try testing.expectError(
            error.BindingMismatch,
            process.feedContent(content, 3, "d", false),
        );

        try testing.expectError(
            error.BindingMismatch,
            process.feedContent(content, 3, "", true),
        );

        try testing.expectEqual(before, open_state.*);
        try testing.expectEqualSlices(u8, "abc", open_state.staging[0..3]);
    }

    open_state.consumed = open_state.staged;

    try process.feedContent(content, 3, "", true);

    // After the end of the input.
    const ended = open_state.*;

    try testing.expectError(
        error.BindingMismatch,
        process.feedContent(content, 3, "e", false),
    );

    try testing.expectError(
        error.BindingMismatch,
        process.feedContent(content, 3, "", true),
    );

    try testing.expectEqual(ended, open_state.*);
    try process.shutDown(engine_handle);
}

test "a feed after the terminal outcome of the job fails as Closed" {
    var process: Process = .init();

    var test_backing: TestBacking = .init(testing.allocator);

    const engine_handle = try process.create(&test_backing, limitsFor(2));

    const content = try open(try process.engineOf(engine_handle));

    const job = try Job.request(try resolve(&process.slot, content), .{});

    // A live job leaves its content open to input.
    try process.feedContent(content, 0, "abc", false);

    // The scripted codec of the engine reads no command in these bytes.
    const stepped = Job.step(try Job.resolve(&process.slot, job));

    try testing.expectEqual(.invalid_content, stepped.outcome);

    const before = (try openOf(&process, content)).*;

    // The ended job decides before the order of the feed does.
    for ([_]u64{ 3, 0 }) |position| {
        try testing.expectError(
            error.Closed,
            process.feedContent(content, position, "d", false),
        );
    }

    try Job.release(try Job.resolveOwned(&process.slot, job));

    // The release of the job reopens nothing.
    try testing.expectError(
        error.Closed,
        process.feedContent(content, 3, "d", false),
    );

    try testing.expectEqual(before, (try openOf(&process, content)).*);
    try process.shutDown(engine_handle);
}
