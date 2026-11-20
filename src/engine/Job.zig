//! A job: the slot of one decode job in the table of its engine.
//!
//! The table is one block of the engine, sized at creation from the
//! count limit of owned jobs, and its slots never move, so a
//! cancellation from another thread finds its slot without a lock. A
//! slot stays taken from the request of its job until the job's release,
//! also after the job's terminal outcome.
//!
//! One 64-bit word holds the generation of the issuance, the
//! cancellation flag, and the terminal mark, so each state of a job is
//! one value of the word:
//!
//!   vacant            generation 0
//!   live              generation g
//!   cancel requested  generation g, canceled
//!   terminal          generation g, terminal
//!   canceled          generation g, canceled and terminal
//!
//! The thread that serializes the engine makes every transition but
//! one: a cancellation moves a live word to cancel requested, from any
//! thread, with one compare-and-exchange. The end of a job is the only
//! other exchange that expects the live word, so exactly one of the two
//! takes a live job, and a job has one terminal outcome. The other
//! fields of a slot are plain data of the serializing thread.

const std = @import("std");
const Content = @import("Content.zig");
const Engine = @import("Engine.zig");
const handles = @import("handles.zig");

const Job = @This();

word: std.atomic.Value(u64) = .init(0),
/// The content that a live job decodes. The end of the job removes it.
content: ?*Content = null,
/// The output request of the job of a taken slot.
requested: Request = .{},

const Word = packed struct(u64) {
    /// The generation of the issuance, which the handle repeats. Zero is
    /// a vacant slot, because the serial never issues it.
    generation: handles.Generation = 0,
    /// A cancellation was requested before the terminal outcome. In a
    /// terminal word, the outcome is the cancellation.
    canceled: bool = false,
    /// The job has its terminal outcome.
    terminal: bool = false,
    unused: u22 = 0,
};

/// The output request of a job, with the shape of its fields checked.
/// The step that learns the size of the image checks the rest.
pub const Request = struct {
    /// The region in image coordinates, or null for the whole image.
    region: ?Region = null,
    /// The largest width of the output grid, or 0 for a scale of 1:1.
    max_output_width: u31 = 0,

    /// A region with left < right and top < bottom.
    pub const Region = struct {
        left: u31,
        top: u31,
        right: u31,
        bottom: u31,
    };
};

/// The terminal outcome of a job. No decode exists, so a job ends as
/// canceled or as an engine failure.
pub const Outcome = enum { canceled, engine_failure };

/// A job handle: the opaque 64-bit value that the ABI carries.
pub const Handle = enum(u64) {
    _,

    fn pack(index: handles.Index, generation: handles.Generation) Handle {
        const bits: handles.Slotted = .{
            .tag = .job,
            .index = index,
            .generation = generation,
        };

        return @fromBackingInt(@as(u64, @bitCast(bits)));
    }
};

/// The slot that a handle names and the generation that the handle
/// expects there. The slot may hold another job, or none.
const Named = struct {
    job: *Job,
    generation: handles.Generation,
    /// Whether a shutdown of the engine has begun.
    closing: bool,
};

/// Returns the slot that `value` names in the engine of `slot`, live or
/// closing. It reads the handle, the engine slot of the process, and the
/// bounds of the table, in that order, and no field of the job, so a
/// cancellation may call it from any thread.
fn named(slot: *const Engine.Slot, value: Handle) error{InvalidHandle}!Named {
    const bits: handles.Slotted = @bitCast(@backingInt(value));

    if (bits.tag != .job) return error.InvalidHandle;

    // A vacant word holds generation 0, so a handle of that generation
    // would match every vacant slot.
    if (bits.generation == 0) return error.InvalidHandle;

    const held = slot.held() orelse return error.InvalidHandle;

    const jobs = held.engine.jobs;

    if (bits.index >= jobs.len) return error.InvalidHandle;

    return .{
        .job = &jobs[bits.index],
        .generation = bits.generation,
        .closing = held.closing,
    };
}

/// A job of a live engine before its terminal outcome. Only `resolve`
/// makes one, so a function that takes one validates nothing again.
pub const Live = struct {
    job: *Job,
};

/// Returns the live job of `value` for a step. A zero, stale, foreign,
/// released, or wrong-type handle fails as InvalidHandle, and a job of a
/// closing engine or after its terminal outcome fails as Closed.
pub fn resolve(
    slot: *const Engine.Slot,
    value: Handle,
) error{ InvalidHandle, Closed }!Live {
    const found = try named(slot, value);

    const word = found.job.load(.monotonic);

    if (word.generation != found.generation) return error.InvalidHandle;
    if (found.closing or word.terminal) return error.Closed;

    return .{ .job = found.job };
}

/// An owned job of a live or closing engine, before or after its
/// terminal outcome. Only `resolveOwned` makes one.
pub const Owned = struct {
    job: *Job,
};

/// Returns the owned job of `value` for a call that works also while
/// the engine shuts down. Any other handle fails as InvalidHandle.
pub fn resolveOwned(
    slot: *const Engine.Slot,
    value: Handle,
) error{InvalidHandle}!Owned {
    const found = try named(slot, value);

    if (found.job.load(.monotonic).generation != found.generation) {
        return error.InvalidHandle;
    }

    return .{ .job = found.job };
}

/// The failures of a request, by category.
pub const RequestError = error{
    /// The content already admitted its job.
    BindingMismatch,
    /// The fields of the request alone name a region that the build
    /// does not support.
    UnsupportedOperation,
    /// Every slot holds an owned job, or the count limit of leases is
    /// reached.
    BudgetExceeded,
    /// The serial of the process has retired.
    EngineFailure,
};

/// Admits the one job of `live` under `wanted` and returns its handle.
/// A failure keeps nothing, and the call allocates nothing.
pub fn request(live: Content.Live, wanted: Request) RequestError!Handle {
    const engine = live.engine;
    const open_state = &live.content.state.open;

    if (open_state.job != .none) return error.BindingMismatch;

    // Only a region that starts at the image's origin can be the whole
    // image, whatever the size of the image.
    if (wanted.region) |region| {
        if (region.left != 0 or region.top != 0) {
            return error.UnsupportedOperation;
        }
    }

    const index = for (engine.jobs, 0..) |*job, at| {
        if (job.load(.monotonic).generation == 0) break at;
    } else return error.BudgetExceeded;

    if (countLeased(engine) >= engine.output_lease_count) {
        return error.BudgetExceeded;
    }

    if (engine.serial.retired()) return error.EngineFailure;

    const generation = engine.serial.take();

    const job = &engine.jobs[index];

    job.content = live.content;
    job.requested = wanted;
    open_state.job = .{ .live = job };
    job.store(.{ .generation = generation }, .release);

    return .pack(@intCast(index), generation);
}

/// Advances `live` and returns its terminal outcome. The step observes
/// the cancellation flag when it starts. No decode exists, so a step
/// that is not canceled ends the job as an engine failure.
pub fn step(live: Live) Outcome {
    const job = live.job;

    if (job.load(.acquire).canceled) return job.settle(.canceled);

    return job.settle(.engine_failure);
}

/// Requests the cancellation of the job of `value`, from any thread,
/// while the caller owns the job. One compare-and-exchange sets the flag
/// of a live job; no loop follows a failure, because the word that a
/// failed exchange returns already decides the result. A job that is
/// canceled or terminal stays as it is, and a word of another generation
/// fails as InvalidHandle. The call works while the engine shuts down.
pub fn cancel(
    slot: *const Engine.Slot,
    value: Handle,
) error{InvalidHandle}!void {
    const found = try named(slot, value);

    const live: Word = .{ .generation = found.generation };
    const flagged: Word = .{ .generation = found.generation, .canceled = true };

    // The release pairs with the acquire of the step that observes the
    // flag.
    const previous = found.job.word.cmpxchgStrong(
        @bitCast(live),
        @bitCast(flagged),
        .release,
        .monotonic,
    ) orelse return;

    const word: Word = @bitCast(previous);

    if (word.generation != found.generation) return error.InvalidHandle;
}

/// Releases `owned` after its terminal outcome and frees its slot. Its
/// handle is invalid from then on. A job before its terminal outcome
/// fails as BindingMismatch and stays as it is.
pub fn release(owned: Owned) error{BindingMismatch}!void {
    if (!owned.job.load(.monotonic).terminal) return error.BindingMismatch;

    owned.job.store(.{}, .release);
}

/// Ends a live job as canceled, as the close of its content and the
/// shutdown of its engine do. The job stays owned.
pub fn end(job: *Job) void {
    _ = job.settle(.canceled);
}

/// Ends every live job of `engine` as canceled, while the contents of
/// the jobs are still open.
pub fn endAll(engine: *Engine) void {
    for (engine.jobs) |*job| {
        const word = job.load(.monotonic);

        if (word.generation != 0 and !word.terminal) job.end();
    }
}

/// Returns the count of the owned jobs of `engine`: the slots that are
/// taken, terminal jobs included.
pub fn countOwned(engine: *const Engine) u64 {
    var count: u64 = 0;

    for (engine.jobs) |*job| {
        count += @intFromBool(job.load(.monotonic).generation != 0);
    }

    return count;
}

/// Returns the count of the live leases of `engine`. A lease lives from
/// the request of its job until San reclaims it. No job publishes, so
/// San reclaims a lease at the terminal outcome of its job, and the jobs
/// before their terminal outcome hold the live leases.
pub fn countLeased(engine: *const Engine) u64 {
    var count: u64 = 0;

    for (engine.jobs) |*job| {
        const word = job.load(.monotonic);

        count += @intFromBool(word.generation != 0 and !word.terminal);
    }

    return count;
}

/// Ends the live job with `outcome`, or as canceled when a cancellation
/// came first, and returns the outcome that the job keeps. It is the
/// only writer of the terminal mark, and it removes the link between the
/// job and its content.
fn settle(job: *Job, outcome: Outcome) Outcome {
    const generation = job.load(.monotonic).generation;

    const live: Word = .{ .generation = generation };
    const flagged: Word = .{ .generation = generation, .canceled = true };

    const canceled: Word = .{
        .generation = generation,
        .canceled = true,
        .terminal = true,
    };

    const ended: Word = switch (outcome) {
        .canceled => canceled,
        .engine_failure => .{ .generation = generation, .terminal = true },
    };

    var accepted = outcome;

    const previous = job.word.cmpxchgStrong(
        @bitCast(live),
        @bitCast(ended),
        .acq_rel,
        .acquire,
    );

    // Only a cancellation changes a live word, and none succeeds from a
    // flagged word, so the store races no other write.
    if (previous) |bits| {
        std.debug.assert(bits == @as(u64, @bitCast(flagged)));

        job.store(canceled, .release);
        accepted = .canceled;
    }

    job.content.?.state.open.job = .ended;
    job.content = null;

    return accepted;
}

fn load(job: *const Job, comptime order: std.builtin.AtomicOrder) Word {
    return @bitCast(job.word.load(order));
}

fn store(
    job: *Job,
    word: Word,
    comptime order: std.builtin.AtomicOrder,
) void {
    job.word.store(@bitCast(word), order);
}

const testing = std.testing;
const TestBacking = Engine.Heap.TestBacking;

/// The staging of each content of the tests below, in bytes.
const portion_bytes = 64;

/// The blocks of an engine's own state: the engine, the slots of its
/// contents, and the slots of its jobs.
const own_blocks = 3;

/// An engine in a test, with the process that holds it. The engine
/// names the slot and the backing by address, so a rig starts in place.
const Rig = struct {
    binding: Engine.Binding = .{},
    slot: Engine.Slot = .{},
    backing: TestBacking,
    handle: Engine.Handle = undefined,
    engine: *Engine = undefined,

    const Counts = struct {
        contents: i64 = 4,
        jobs: i64 = 2,
        leases: i64 = 2,
    };

    fn start(rig: *Rig, counts: Counts) !void {
        rig.* = .{ .backing = .init(testing.allocator) };
        rig.binding.establish();

        try rig.create(counts);
    }

    /// Creates the engine of the rig, whose slot is free.
    fn create(rig: *Rig, counts: Counts) !void {
        var limits: Engine.Limits = undefined;

        inline for (Engine.Limits.names) |name| @field(limits, name) = 1 << 20;

        limits.content_count = counts.contents;
        limits.job_count = counts.jobs;
        limits.output_lease_count = counts.leases;
        limits.input_portion_bytes = portion_bytes;

        rig.handle = try Engine.create(
            &rig.binding,
            &rig.slot,
            rig.backing.backing(),
            limits,
        );

        rig.engine = try Engine.resolve(&rig.slot, rig.handle);
    }

    fn open(rig: *Rig) !Content.Handle {
        return Content.open(rig.engine);
    }

    fn closeContent(rig: *Rig, content: Content.Handle) !void {
        Content.close(try Content.resolve(&rig.slot, content));
    }

    /// Requests the job of `content` under `wanted`.
    fn admit(rig: *Rig, content: Content.Handle, wanted: Request) !Handle {
        return request(try Content.resolve(&rig.slot, content), wanted);
    }

    /// Opens a content and requests its job for the whole image.
    fn admitNew(rig: *Rig) !Handle {
        return rig.admit(try rig.open(), .{});
    }

    fn advance(rig: *Rig, handle: Handle) !Outcome {
        return step(try resolve(&rig.slot, handle));
    }

    fn drop(rig: *Rig, handle: Handle) !void {
        try release(try resolveOwned(&rig.slot, handle));
    }

    /// Returns the slot at the index of `handle`, whatever it holds.
    fn slotOf(rig: *Rig, handle: Handle) *Job {
        return &rig.engine.jobs[unpack(handle).index];
    }

    fn wordOf(rig: *Rig, handle: Handle) Word {
        return rig.slotOf(handle).load(.monotonic);
    }

    /// Checks that each call that takes a job rejects `handle`.
    fn expectInvalid(rig: *Rig, handle: Handle) !void {
        try testing.expectError(error.InvalidHandle, resolve(&rig.slot, handle));
        try testing.expectError(error.InvalidHandle, cancel(&rig.slot, handle));

        try testing.expectError(
            error.InvalidHandle,
            resolveOwned(&rig.slot, handle),
        );
    }

    /// Shuts down the engine, which owns no job, and checks that it
    /// leaves no block.
    fn finish(rig: *Rig) !void {
        try testing.expectEqual(
            .complete,
            try Engine.shutdown(&rig.slot, rig.handle),
        );

        try testing.expectEqual(0, rig.backing.blocks);
        try testing.expectEqual(0, rig.backing.outstanding);
    }
};

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

/// The words of a job of `generation`, by state.
fn liveWord(generation: handles.Generation) Word {
    return .{ .generation = generation };
}

fn flaggedWord(generation: handles.Generation) Word {
    return .{ .generation = generation, .canceled = true };
}

fn terminalWord(generation: handles.Generation) Word {
    return .{ .generation = generation, .terminal = true };
}

fn canceledWord(generation: handles.Generation) Word {
    return .{ .generation = generation, .canceled = true, .terminal = true };
}

const tag_job = @backingInt(handles.Tag.job);

test "a job word holds its generation in the low 40 bits" {
    const word: Word = .{
        .generation = 0xab_cdef_0123,
        .canceled = true,
        .terminal = true,
    };

    try testing.expectEqual(0x3ab_cdef_0123, @as(u64, @bitCast(word)));
    try testing.expectEqual(0, @as(u64, @bitCast(Word{})));
}

test "a step without a cancellation ends the job as an engine failure" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const handle = try rig.admit(content, .{});

    const generation = unpack(handle).generation;

    try testing.expectEqual(tag_job, @backingInt(unpack(handle).tag));
    try testing.expectEqual(liveWord(generation), rig.wordOf(handle));
    try testing.expectEqual(1, countOwned(rig.engine));
    try testing.expectEqual(1, countLeased(rig.engine));

    // A release before the terminal outcome changes nothing.
    try testing.expectError(error.BindingMismatch, rig.drop(handle));
    try testing.expectEqual(liveWord(generation), rig.wordOf(handle));
    try testing.expectEqual(.engine_failure, try rig.advance(handle));
    try testing.expectEqual(terminalWord(generation), rig.wordOf(handle));
    try testing.expectEqual(1, countOwned(rig.engine));
    try testing.expectEqual(0, countLeased(rig.engine));

    // The end removed the link in both directions.
    const live = try Content.resolve(&rig.slot, content);

    try testing.expect(live.content.state.open.job == .ended);
    try testing.expectEqual(null, rig.slotOf(handle).content);

    // After the terminal outcome, a step is refused, and a cancellation
    // changes nothing.
    try testing.expectError(error.Closed, rig.advance(handle));
    try cancel(&rig.slot, handle);
    try testing.expectEqual(terminalWord(generation), rig.wordOf(handle));
    try rig.drop(handle);
    try testing.expectEqual(Word{}, rig.wordOf(handle));
    try testing.expectEqual(0, countOwned(rig.engine));
    try rig.expectInvalid(handle);
    try rig.finish();
}

test "a step that observes the flag ends the job as canceled" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const generation = unpack(handle).generation;

    try cancel(&rig.slot, handle);
    try testing.expectEqual(flaggedWord(generation), rig.wordOf(handle));

    // A flagged job is not terminal: it holds its lease and refuses a
    // release, and a second cancellation changes nothing.
    try testing.expectEqual(1, countLeased(rig.engine));
    try testing.expectError(error.BindingMismatch, rig.drop(handle));
    try cancel(&rig.slot, handle);
    try testing.expectEqual(flaggedWord(generation), rig.wordOf(handle));
    try testing.expectEqual(.canceled, try rig.advance(handle));
    try testing.expectEqual(canceledWord(generation), rig.wordOf(handle));
    try testing.expectEqual(0, countLeased(rig.engine));
    try testing.expectError(error.Closed, rig.advance(handle));
    try cancel(&rig.slot, handle);
    try testing.expectEqual(canceledWord(generation), rig.wordOf(handle));
    try rig.drop(handle);
    try testing.expectEqual(Word{}, rig.wordOf(handle));
    try rig.expectInvalid(handle);
    try rig.finish();
}

test "an invalid handle fails every job call and changes no word" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const handle = try rig.admit(content, .{});

    const bits = unpack(handle);

    try testing.expectEqual(0, bits.index);

    const invalid = [_]Handle{
        @fromBackingInt(@as(u64, 0)),
        @fromBackingInt(@as(u64, std.math.maxInt(u64))),
        @fromBackingInt(@backingInt(rig.handle)),
        @fromBackingInt(@backingInt(content)),
        handleOf(0, bits.index, bits.generation),
        handleOf(1, bits.index, bits.generation),
        handleOf(2, bits.index, bits.generation),
        handleOf(4, bits.index, bits.generation),
        handleOf(0xff, bits.index, bits.generation),
        // The live slot under the generation of a vacant word.
        handleOf(tag_job, bits.index, 0),
        // The vacant slot, under the generation of its word and another.
        handleOf(tag_job, 1, 0),
        handleOf(tag_job, 1, bits.generation),
        // The table has two slots.
        handleOf(tag_job, 2, bits.generation),
        handleOf(tag_job, 3, 0),
        handleOf(tag_job, std.math.maxInt(handles.Index), bits.generation),
        handleOf(tag_job, bits.index, bits.generation + 1),
        handleOf(tag_job, bits.index, bits.generation - 1),
    };

    for (invalid) |value| try rig.expectInvalid(value);

    try testing.expectEqual(liveWord(bits.generation), rig.wordOf(handle));
    try testing.expectEqual(Word{}, rig.engine.jobs[1].load(.monotonic));
    try testing.expectEqual(1, countOwned(rig.engine));
    try testing.expectEqual(.engine_failure, try rig.advance(handle));
    try rig.drop(handle);
    try rig.finish();
}

test "a request checks its content, its region, and the limits in order" {
    var rig: Rig = undefined;

    try rig.start(.{ .jobs = 1, .leases = 1 });

    const first = try rig.open();
    const second = try rig.open();

    const off_left: Request = .{
        .region = .{ .left = 1, .top = 0, .right = 2, .bottom = 2 },
    };

    const off_top: Request = .{
        .region = .{ .left = 0, .top = 1, .right = 2, .bottom = 2 },
    };

    // The one slot is free, so only the region refuses these.
    for ([_]Request{ off_left, off_top }) |wanted| {
        try testing.expectError(
            error.UnsupportedOperation,
            rig.admit(second, wanted),
        );
    }

    try testing.expectEqual(0, countOwned(rig.engine));

    const handle = try rig.admit(first, .{});

    const next = rig.engine.serial.next;

    // A content that admitted its job decides before the region does,
    // and the region before the count limits.
    try testing.expectError(error.BindingMismatch, rig.admit(first, off_left));
    try testing.expectError(error.BindingMismatch, rig.admit(first, .{}));

    try testing.expectError(
        error.UnsupportedOperation,
        rig.admit(second, off_left),
    );

    try testing.expectError(error.BudgetExceeded, rig.admit(second, .{}));

    // A terminal job still holds its slot, and its content admits no
    // second job.
    try testing.expectEqual(.engine_failure, try rig.advance(handle));
    try testing.expectError(error.BudgetExceeded, rig.admit(second, .{}));
    try testing.expectError(error.BindingMismatch, rig.admit(first, .{}));

    // No refusal kept anything.
    const untouched = try Content.resolve(&rig.slot, second);

    try testing.expect(untouched.content.state.open.job == .none);
    try testing.expectEqual(next, rig.engine.serial.next);
    try testing.expectEqual(1, countOwned(rig.engine));
    try rig.drop(handle);

    const whole: Request = .{
        .region = .{ .left = 0, .top = 0, .right = 5, .bottom = 7 },
        .max_output_width = 9,
    };

    const later = try rig.admit(second, whole);

    // The freed slot serves the next job under a later generation.
    try testing.expectEqual(unpack(handle).index, unpack(later).index);
    try testing.expectEqual(next, unpack(later).generation);
    try testing.expectEqual(whole, rig.slotOf(later).requested);
    try testing.expectEqual(untouched.content, rig.slotOf(later).content.?);
    try rig.expectInvalid(handle);
    try testing.expectEqual(liveWord(next), rig.wordOf(later));
    try testing.expectEqual(.engine_failure, try rig.advance(later));
    try rig.drop(later);
    try rig.finish();
}

test "the count limit of leases refuses a request until a job ends" {
    var rig: Rig = undefined;

    try rig.start(.{ .jobs = 2, .leases = 1 });

    const second = try rig.open();

    const first_job = try rig.admitNew();

    // A slot is vacant, and the one lease is live.
    try testing.expectError(error.BudgetExceeded, rig.admit(second, .{}));
    try testing.expectEqual(1, countOwned(rig.engine));

    // Without a publication, the terminal outcome reclaims the lease.
    try testing.expectEqual(.engine_failure, try rig.advance(first_job));

    const second_job = try rig.admit(second, .{});

    try testing.expectEqual(1, unpack(second_job).index);
    try testing.expectEqual(2, countOwned(rig.engine));
    try testing.expectEqual(1, countLeased(rig.engine));
    try testing.expectEqual(.engine_failure, try rig.advance(second_job));
    try rig.drop(first_job);
    try rig.drop(second_job);
    try rig.finish();
}

test "a retired serial fails a request as EngineFailure" {
    var rig: Rig = undefined;

    try rig.start(.{});

    rig.engine.serial = .{ .next = std.math.maxInt(handles.Generation) - 1 };

    // The opening takes the last generation.
    const content = try rig.open();

    try testing.expect(rig.engine.serial.retired());
    try testing.expectError(error.EngineFailure, rig.admit(content, .{}));

    const live = try Content.resolve(&rig.slot, content);

    try testing.expect(live.content.state.open.job == .none);
    try testing.expectEqual(0, countOwned(rig.engine));
    try rig.finish();
}

test "the close of a content ends its live job as canceled" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const handle = try rig.admit(content, .{});

    const generation = unpack(handle).generation;

    try rig.closeContent(content);

    // The job is terminal and stays owned, without its content.
    try testing.expectEqual(canceledWord(generation), rig.wordOf(handle));
    try testing.expectEqual(null, rig.slotOf(handle).content);
    try testing.expectEqual(1, countOwned(rig.engine));
    try testing.expectEqual(0, countLeased(rig.engine));
    try testing.expectEqual(own_blocks, rig.backing.blocks);

    try testing.expectError(
        error.InvalidHandle,
        Content.resolve(&rig.slot, content),
    );

    try testing.expectError(error.Closed, rig.advance(handle));
    try cancel(&rig.slot, handle);
    try testing.expectEqual(canceledWord(generation), rig.wordOf(handle));
    try rig.drop(handle);
    try rig.finish();
}

test "the close of a content leaves its terminal job as it ended" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const handle = try rig.admit(content, .{});

    const generation = unpack(handle).generation;

    try testing.expectEqual(.engine_failure, try rig.advance(handle));
    try rig.closeContent(content);
    try testing.expectEqual(terminalWord(generation), rig.wordOf(handle));
    try testing.expectEqual(1, countOwned(rig.engine));

    // The slot of the content serves a later content, which admits its
    // own job beside the owned one.
    const later = try rig.admitNew();

    try testing.expectEqual(1, unpack(later).index);
    try testing.expectEqual(terminalWord(generation), rig.wordOf(handle));
    try testing.expectEqual(.engine_failure, try rig.advance(later));
    try rig.drop(later);
    try rig.drop(handle);
    try rig.finish();
}

test "a close and a shutdown end a job whose flag no step observed" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const closed = try rig.admit(content, .{});
    const shut = try rig.admitNew();

    try cancel(&rig.slot, closed);
    try cancel(&rig.slot, shut);
    try rig.closeContent(content);

    try testing.expectEqual(
        canceledWord(unpack(closed).generation),
        rig.wordOf(closed),
    );

    try testing.expectEqual(
        flaggedWord(unpack(shut).generation),
        rig.wordOf(shut),
    );

    try testing.expectEqual(1, countLeased(rig.engine));

    try testing.expectEqual(
        .pending,
        try Engine.shutdown(&rig.slot, rig.handle),
    );

    try testing.expectEqual(
        canceledWord(unpack(shut).generation),
        rig.wordOf(shut),
    );

    try testing.expectEqual(0, countLeased(rig.engine));
    try rig.drop(closed);
    try rig.drop(shut);
    try rig.finish();
}

test "a shutdown stays pending until every job is released" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const idle = try rig.open();

    const live_job = try rig.admitNew();
    const ended_job = try rig.admitNew();

    const live_generation = unpack(live_job).generation;
    const ended_generation = unpack(ended_job).generation;

    try testing.expectEqual(.engine_failure, try rig.advance(ended_job));

    const issued = rig.engine.serial.next;

    for (0..2) |_| {
        try testing.expectEqual(
            .pending,
            try Engine.shutdown(&rig.slot, rig.handle),
        );

        // The first call ended the live job and closed every content.
        try testing.expectEqual(
            canceledWord(live_generation),
            rig.wordOf(live_job),
        );

        try testing.expectEqual(
            terminalWord(ended_generation),
            rig.wordOf(ended_job),
        );

        try testing.expectEqual(own_blocks, rig.backing.blocks);
        try testing.expectEqual(0, rig.engine.heap.ledger.usage.input);
        try testing.expectEqual(2, countOwned(rig.engine));
        try testing.expectEqual(0, countLeased(rig.engine));

        // A closing engine admits nothing and steps nothing.
        try testing.expectError(
            error.Closed,
            Engine.resolve(&rig.slot, rig.handle),
        );

        try testing.expectError(
            error.Closed,
            Content.resolve(&rig.slot, idle),
        );

        for ([_]Handle{ live_job, ended_job }) |handle| {
            try testing.expectError(error.Closed, rig.advance(handle));
            try cancel(&rig.slot, handle);
        }
    }

    // The serial stays in the closing engine, which issues nothing.
    try testing.expectEqual(issued, rig.engine.serial.next);
    try testing.expectEqual(1, rig.slot.serial.next);
    try rig.drop(live_job);
    try rig.expectInvalid(live_job);

    try testing.expectEqual(
        .pending,
        try Engine.shutdown(&rig.slot, rig.handle),
    );

    try rig.drop(ended_job);

    try testing.expectEqual(
        .complete,
        try Engine.shutdown(&rig.slot, rig.handle),
    );

    try testing.expectEqual(0, rig.backing.blocks);
    try testing.expectEqual(0, rig.backing.outstanding);
    try testing.expectEqual(null, rig.slot.held());
    try testing.expectEqual(issued, rig.slot.serial.next);

    try testing.expectError(
        error.InvalidHandle,
        Engine.shutdown(&rig.slot, rig.handle),
    );

    try rig.expectInvalid(ended_job);
}

test "a job handle of a finished engine fails under a later engine" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const earlier = try rig.admitNew();

    try testing.expectEqual(.engine_failure, try rig.advance(earlier));
    try rig.drop(earlier);
    try rig.finish();
    try rig.expectInvalid(earlier);
    try rig.create(.{});

    const later = try rig.admitNew();

    // Both jobs sit at the same index.
    try testing.expectEqual(unpack(earlier).index, unpack(later).index);
    try testing.expect(unpack(earlier).generation != unpack(later).generation);
    try rig.expectInvalid(earlier);

    try testing.expectEqual(
        liveWord(unpack(later).generation),
        rig.wordOf(later),
    );

    try testing.expectEqual(.engine_failure, try rig.advance(later));
    try rig.drop(later);
    try rig.finish();
}

test "a cancellation after the step's observation takes the outcome" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const job = rig.slotOf(handle);

    // The step observed a clear flag, and the request came before the
    // step accepted its outcome.
    try testing.expect(!job.load(.acquire).canceled);
    try cancel(&rig.slot, handle);
    try testing.expectEqual(.canceled, job.settle(.engine_failure));

    try testing.expectEqual(
        canceledWord(unpack(handle).generation),
        rig.wordOf(handle),
    );

    try rig.drop(handle);
    try rig.finish();
}

test "a cancellation after the step's acceptance changes nothing" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const job = rig.slotOf(handle);

    try testing.expect(!job.load(.acquire).canceled);
    try testing.expectEqual(.engine_failure, job.settle(.engine_failure));
    try cancel(&rig.slot, handle);

    try testing.expectEqual(
        terminalWord(unpack(handle).generation),
        rig.wordOf(handle),
    );

    try rig.drop(handle);
    try rig.finish();
}

/// The rounds of the race of one cancellation against one step, the
/// threads that cancel one job at once, and the rounds of those races.
const step_race_rounds = 10_000;
const cancel_threads = 8;
const cancel_race_rounds = 64;

/// What one cancellation from another thread observed.
const Attempt = struct {
    outcome: error{InvalidHandle}!void = {},
    /// The word right after the request returned.
    seen: Word = .{},
};

/// Threads that each cancel one job once, all at one signal. The tests
/// below prove the logic of the word's modification order and find a
/// lost update. No plain run observes a weakened memory ordering or a
/// race on a plain field; only a ThreadSanitizer run or review does.
const Cancelers = struct {
    waiting: std.atomic.Value(u32) = .init(0),
    go: std.atomic.Value(bool) = .init(false),
    threads: [cancel_threads]std.Thread = undefined,
    attempts: [cancel_threads]Attempt = @splat(.{}),
    spawned: usize = 0,

    /// Starts `count` threads and returns once each of them waits for
    /// the signal. A failed spawn lets the spawned threads finish.
    fn start(
        cancelers: *Cancelers,
        count: usize,
        slot: *const Engine.Slot,
        handle: Handle,
    ) !void {
        errdefer cancelers.finish();

        for (cancelers.attempts[0..count]) |*attempt| {
            cancelers.threads[cancelers.spawned] = try std.Thread.spawn(
                .{},
                cancelAtOnce,
                .{ cancelers, slot, handle, attempt },
            );

            cancelers.spawned += 1;
        }

        while (cancelers.waiting.load(.acquire) != count) {
            std.atomic.spinLoopHint();
        }
    }

    fn signal(cancelers: *Cancelers) void {
        cancelers.go.store(true, .release);
    }

    /// Signals the threads, if nothing has yet, and joins them.
    fn finish(cancelers: *Cancelers) void {
        cancelers.signal();

        for (cancelers.threads[0..cancelers.spawned]) |thread| thread.join();

        cancelers.spawned = 0;
    }

    /// Returns the attempts of the joined threads.
    fn made(cancelers: *const Cancelers, count: usize) []const Attempt {
        return cancelers.attempts[0..count];
    }
};

fn cancelAtOnce(
    cancelers: *Cancelers,
    slot: *const Engine.Slot,
    handle: Handle,
    attempt: *Attempt,
) void {
    _ = cancelers.waiting.fetchAdd(1, .release);

    while (!cancelers.go.load(.acquire)) std.atomic.spinLoopHint();

    attempt.outcome = cancel(slot, handle);

    const found = named(slot, handle) catch return;

    attempt.seen = found.job.load(.acquire);
}

test "a cancellation that races a step leaves one terminal outcome" {
    var rig: Rig = undefined;

    try rig.start(.{});

    for (0..step_race_rounds) |_| {
        const content = try rig.open();

        const handle = try rig.admit(content, .{});

        const live = try resolve(&rig.slot, handle);

        var cancelers: Cancelers = .{};

        try cancelers.start(1, &rig.slot, handle);

        cancelers.signal();

        const outcome = step(live);

        cancelers.finish();

        const attempt = cancelers.made(1)[0];
        const word = rig.wordOf(handle);

        // The request found its job, whichever side won.
        try attempt.outcome;
        try testing.expect(attempt.seen.canceled or attempt.seen.terminal);

        // The step's status and the word agree on the one outcome, and a
        // flag that the request saw set is never lost.
        try testing.expect(word.terminal);
        try testing.expectEqual(outcome == .canceled, word.canceled);

        if (attempt.seen.canceled) try testing.expect(word.canceled);

        try testing.expectError(error.Closed, rig.advance(handle));
        try rig.drop(handle);
        try rig.closeContent(content);
    }

    try rig.finish();
}

test "cancellations that race on one job set its flag once" {
    var rig: Rig = undefined;

    try rig.start(.{});

    for (0..cancel_race_rounds) |_| {
        const content = try rig.open();

        const handle = try rig.admit(content, .{});

        const generation = unpack(handle).generation;

        var cancelers: Cancelers = .{};

        try cancelers.start(cancel_threads, &rig.slot, handle);

        cancelers.finish();

        for (cancelers.made(cancel_threads)) |attempt| {
            try attempt.outcome;
            try testing.expectEqual(flaggedWord(generation), attempt.seen);
        }

        try testing.expectEqual(flaggedWord(generation), rig.wordOf(handle));
        try testing.expectEqual(.canceled, try rig.advance(handle));
        try rig.drop(handle);
        try rig.closeContent(content);
    }

    try rig.finish();
}

test "cancellations that race the first shutdown call find their job" {
    for (0..cancel_race_rounds) |_| {
        var rig: Rig = undefined;

        try rig.start(.{});

        const handle = try rig.admitNew();

        const generation = unpack(handle).generation;

        var cancelers: Cancelers = .{};

        try cancelers.start(cancel_threads, &rig.slot, handle);

        cancelers.signal();

        const ended = Engine.shutdown(&rig.slot, rig.handle);

        // Every request returns before the release of its job.
        cancelers.finish();

        try testing.expectEqual(.pending, try ended);

        for (cancelers.made(cancel_threads)) |attempt| {
            try attempt.outcome;
            try testing.expect(attempt.seen.canceled);
        }

        try testing.expectEqual(canceledWord(generation), rig.wordOf(handle));
        try rig.drop(handle);
        try rig.finish();
    }
}
