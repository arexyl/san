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
//!
//! A step hands the staged bytes of the job's content to the job's
//! codec, which writes the rows that they yield into the job's lease. A
//! step that does not end as canceled then publishes those rows: it
//! extends the coverage of the lease, so a canceled step publishes
//! nothing new, also when it wrote rows.

const std = @import("std");
const Codec = @import("Codec.zig");
const Content = @import("Content.zig");
const Decode = @import("Decode.zig");
const Engine = @import("Engine.zig");
const Lease = @import("Lease.zig");
const handles = @import("handles.zig");

const Job = @This();

word: std.atomic.Value(u64) = .init(0),
/// The content that a live job decodes. The end of the job removes it.
content: ?*Content = null,
/// The output request of the job of a taken slot.
requested: Request = .{},
/// The lease of a live job, which the request takes. The end of the job
/// ends the job's claim on it and removes the link.
lease: ?*Lease = null,
/// The decode of a live job, from its first step until its end. It
/// stays in place, because its codec holds its address.
decode: ?Decode = null,
/// The count of the steps that extended the coverage of the lease.
revision: u64 = 0,

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

/// The terminal outcome of a job.
pub const Outcome = enum {
    completed,
    canceled,
    unsupported_format,
    unsupported_operation,
    invalid_content,
    truncated_content,
    budget_exceeded,
    allocation_failed,
    engine_failure,

    fn of(failure: Codec.Error) Outcome {
        return switch (failure) {
            error.Canceled => .canceled,
            error.UnsupportedFormat => .unsupported_format,
            error.UnsupportedOperation => .unsupported_operation,
            error.InvalidContent => .invalid_content,
            error.TruncatedContent => .truncated_content,
            error.BudgetExceeded => .budget_exceeded,
            error.AllocationFailed => .allocation_failed,
            error.EngineFailure => .engine_failure,
        };
    }
};

/// What a step reports of its job.
pub const Report = struct {
    /// The lease, from the job's first publication on, also after the
    /// caller released it.
    lease: ?Lease.Handle = null,
    /// The count of the publications so far.
    revision: u64 = 0,
    /// The rows [0, covered_rows) of the lease that the publications
    /// cover.
    covered_rows: u32 = 0,
    /// The image and its output grid, once the admission step passed
    /// the image limits.
    admission: ?Decode.Admission = null,
    /// The lease as the admission step admitted it.
    admitted: ?Admitted = null,
    /// The image rows that the codec delivered so far.
    decoded_rows: u32 = 0,

    /// The geometry and the kind of an admitted lease, with its origin
    /// in the output grid. This build decodes every column without
    /// alpha, row by row, so the lease starts at the left edge of the
    /// grid, has no alpha, and publishes before the terminal outcome.
    pub const Admitted = struct {
        width: u32,
        height: u32,
        left: u32 = 0,
        top: u32 = 0,
        alpha: bool = false,
        early_publication: bool = true,
    };
};

/// The result of a step.
pub const Step = struct {
    /// The terminal outcome of the job, or null while the job waits for
    /// more input.
    outcome: ?Outcome,
    report: Report,
};

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
    engine: *Engine,
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
        .engine = held.engine,
        .job = &jobs[bits.index],
        .generation = bits.generation,
        .closing = held.closing,
    };
}

/// A job of a live engine before its terminal outcome. Only `resolve`
/// makes one, so a function that takes one validates nothing again.
pub const Live = struct {
    engine: *Engine,
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

    return .{ .engine = found.engine, .job = found.job };
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
    /// The fields of the request alone name an output that the build
    /// does not support. This build decides every region and scale
    /// when it learns the image, so its request never fails this way.
    UnsupportedOperation,
    /// Every slot holds an owned job, or the count limit of live leases
    /// is reached.
    BudgetExceeded,
    /// The serial of the process retires before it issues both the job
    /// and its lease.
    EngineFailure,
};

/// Admits the one job of `live` under `wanted` and returns its handle.
/// The job takes its lease, which has no pixels yet. A failure keeps
/// nothing, and the call allocates nothing.
pub fn request(live: Content.Live, wanted: Request) RequestError!Handle {
    const engine = live.engine;
    const open_state = &live.content.state.open;

    if (open_state.job != .none) return error.BindingMismatch;

    const index = for (engine.jobs, 0..) |*job, at| {
        if (job.load(.monotonic).generation == 0) break at;
    } else return error.BudgetExceeded;

    const lease = Lease.vacant(engine) orelse return error.BudgetExceeded;

    if (!engine.serial.admits(2)) return error.EngineFailure;

    const generation = engine.serial.take();

    lease.issue(engine.serial.take());

    const job = &engine.jobs[index];

    job.content = live.content;
    job.requested = wanted;
    job.lease = lease;
    job.revision = 0;
    open_state.job = .{ .live = job };
    job.store(.{ .generation = generation }, .release);

    return .pack(@intCast(index), generation);
}

/// Advances `live` by the bytes that its content holds. The step
/// observes the cancellation flag when it starts, before it consumes a
/// byte, and its codec observes the flag at its own observation points.
pub fn step(live: Live) Step {
    const job = live.job;
    const engine = live.engine;

    if (job.load(.acquire).canceled) return job.conclude(engine, .canceled);

    const complete = job.advance(engine) catch |failure|
        return job.conclude(engine, .of(failure));

    if (complete) return job.conclude(engine, .completed);

    job.publish();

    return .{ .outcome = null, .report = job.describe(engine) };
}

/// Hands the bytes that the content of the live job holds to the job's
/// decode, and ends the decode once the input has ended. Returns whether
/// the image is complete. No byte past the length ceiling of a
/// representation reaches the codec: the step that would consume one
/// fails as BudgetExceeded after the bytes before it.
fn advance(job: *Job, engine: *Engine) Codec.Error!bool {
    if (job.decode == null) {
        job.decode = Decode.init(engine, job.lease.?, job.requested);
        errdefer job.decode = null;

        try job.decode.?.open(job.cancelFlag());
    }

    const decode = &job.decode.?;
    const input = &job.content.?.state.open;

    const staged = input.staging[input.consumed..input.staged];

    // The position of the first staged byte in the representation.
    const position = input.received - staged.len;

    const within: usize = @intCast(
        @min(staged.len, engine.content_length_bytes -| position),
    );

    if (within != 0) {
        input.consumed += within;

        switch (try decode.feed(staged[0..within])) {
            .more => {},
            // The decode has the last row of a band, so the job is
            // complete without the rest of its input.
            .satisfied => return job.covered(),
        }
    }

    if (within != staged.len) return error.BudgetExceeded;
    if (!input.ended) return false;

    try decode.finish();

    return job.covered();
}

/// Returns true for a decode that wrote every row of its lease, as a
/// completed job needs. A codec that ends short of that broke its
/// promise, and the job fails.
fn covered(job: *const Job) error{EngineFailure}!bool {
    const decode = &job.decode.?;

    if (!decode.admitted or decode.written != job.lease.?.height) {
        return error.EngineFailure;
    }

    return true;
}

/// Extends the coverage of the lease to the rows that the decode wrote.
/// The first publication starts the caller's claim on the lease.
fn publish(job: *Job) void {
    const rows = (job.decode orelse return).written;
    const lease = job.lease.?;

    if (rows == lease.covered) return;

    if (job.revision == 0) lease.claims.caller = true;

    lease.covered = rows;
    job.revision += 1;
}

/// Returns the report of the live job.
fn describe(job: *const Job, engine: *const Engine) Report {
    const lease = job.lease.?;

    var report: Report = .{
        .revision = job.revision,
        .covered_rows = lease.covered,
    };

    if (job.revision != 0) report.lease = lease.handle(engine);

    if (job.decode) |decode| {
        report.admission = decode.admission;
        report.decoded_rows = decode.rows;

        if (decode.admitted) {
            report.admitted = .{
                .width = lease.width,
                .height = lease.height,
                .top = decode.band.top,
            };
        }
    }

    return report;
}

/// Returns the cancellation flag of the job for its codec: the canceled
/// bit of the job's word.
fn cancelFlag(job: *const Job) Codec.Cancel {
    const flag: Word = .{ .canceled = true };

    return .{ .word = &job.word, .mask = @bitCast(flag) };
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

/// Ends a live job of `engine` as canceled, as the close of its content
/// and the shutdown of its engine do. The job stays owned.
pub fn end(job: *Job, engine: *Engine) void {
    _ = job.conclude(engine, .canceled);
}

/// Ends every live job of `engine` as canceled, while the contents of
/// the jobs are still open.
pub fn endAll(engine: *Engine) void {
    for (engine.jobs) |*job| {
        const word = job.load(.monotonic);

        if (word.generation != 0 and !word.terminal) job.end(engine);
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

/// Ends the live job of `engine` with `outcome`, or as canceled when a
/// cancellation came first, and returns the outcome that the job keeps
/// with its last report. An end that is not a cancellation publishes
/// the rows that the decode wrote. The end releases the codec, removes
/// the link between the job and its content, and ends the job's claim
/// on its lease, so the job is quiescent when it returns.
fn conclude(job: *Job, engine: *Engine, outcome: Outcome) Step {
    const accepted = job.settle(outcome);

    if (accepted != .canceled) job.publish();

    // The report names the lease while the job still links it.
    const report = job.describe(engine);

    if (job.decode) |*decode| decode.close();

    job.decode = null;
    job.content.?.state.open.job = .ended;
    job.content = null;

    job.lease.?.endJobClaim(engine);
    job.lease = null;

    return .{ .outcome = accepted, .report = report };
}

/// Sets the terminal mark of the live job for `outcome`, or for a
/// cancellation that came first, and returns the outcome that the job
/// keeps. It is the only writer of the terminal mark.
fn settle(job: *Job, outcome: Outcome) Outcome {
    const generation = job.load(.monotonic).generation;

    const live: Word = .{ .generation = generation };
    const flagged: Word = .{ .generation = generation, .canceled = true };

    const canceled: Word = .{
        .generation = generation,
        .canceled = true,
        .terminal = true,
    };

    const ended: Word = if (outcome == .canceled)
        canceled
    else
        .{ .generation = generation, .terminal = true };

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

/// The blocks of an engine's own state: the engine and the slots of its
/// contents, of its jobs, and of its leases.
const own_blocks = 4;

/// An engine in a test, with the process that holds it. The engine
/// names the slot and the backing by address, so a rig starts in place.
const Rig = struct {
    binding: Engine.Binding = .{},
    slot: Engine.Slot = .{},
    backing: TestBacking,
    /// What the scripted codecs of the engine call inside a step.
    hooks: Codec.Scripted.Hooks = .{},
    handle: Engine.Handle = undefined,
    engine: *Engine = undefined,

    const Counts = struct {
        contents: i64 = 4,
        jobs: i64 = 2,
        leases: i64 = 2,
    };

    /// Returns limits of `counts` slots, with every other limit roomy.
    fn limitsOf(counts: Counts) Engine.Limits {
        var limits: Engine.Limits = undefined;

        inline for (Engine.Limits.names) |name| @field(limits, name) = 1 << 20;

        limits.content_count = counts.contents;
        limits.job_count = counts.jobs;
        limits.output_lease_count = counts.leases;
        limits.input_portion_bytes = portion_bytes;

        return limits;
    }

    fn start(rig: *Rig, counts: Counts) !void {
        try rig.startUnder(limitsOf(counts));
    }

    fn startUnder(rig: *Rig, limits: Engine.Limits) !void {
        rig.* = .{ .backing = .init(testing.allocator) };
        rig.binding.establish();

        try rig.createUnder(limits);
    }

    /// Creates the engine of the rig, whose slot is free.
    fn create(rig: *Rig, counts: Counts) !void {
        try rig.createUnder(limitsOf(counts));
    }

    fn createUnder(rig: *Rig, limits: Engine.Limits) !void {
        rig.handle = try Engine.create(
            &rig.binding,
            &rig.slot,
            rig.backing.backing(),
            Codec.Scripted.openerWith(&rig.hooks),
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

    /// Supplies `bytes` as the next portion of the content of the live
    /// job of `handle`, with or without the end of the input.
    fn supply(
        rig: *Rig,
        handle: Handle,
        bytes: []const u8,
        end_of_input: bool,
    ) !void {
        const content = rig.slotOf(handle).content.?;

        const target = try Content.feedable(.{
            .engine = rig.engine,
            .content = content,
        });

        try Content.feed(target, .{
            .position = content.state.open.received,
            .bytes = bytes,
            .end = end_of_input,
        });
    }

    /// Steps the job of `handle` and returns the whole result.
    fn take(rig: *Rig, handle: Handle) !Step {
        return step(try resolve(&rig.slot, handle));
    }

    /// Steps the job of `handle` and returns its terminal outcome, or
    /// null while the job waits for input.
    fn advance(rig: *Rig, handle: Handle) !?Outcome {
        return (try rig.take(handle)).outcome;
    }

    /// Ends the live job of `handle`, whose content took no input, with
    /// an outcome that is no cancellation: its input ends before any
    /// image.
    fn fail(rig: *Rig, handle: Handle) !void {
        try rig.supply(handle, &.{}, true);
        try testing.expectEqual(.truncated_content, try rig.advance(handle));
    }

    /// Supplies `script` to the job of `handle` in one portion, then
    /// steps the job.
    fn run(
        rig: *Rig,
        handle: Handle,
        script: []const u8,
        end_of_input: bool,
    ) !Step {
        try rig.supply(handle, script, end_of_input);

        return rig.take(handle);
    }

    /// Returns the lease of `value`, which the caller holds.
    fn leaseOf(rig: *Rig, value: Lease.Handle) !*Lease {
        return (try Lease.resolve(&rig.slot, value)).lease;
    }

    /// Releases the caller's claim on the lease of `value`.
    fn releaseLease(rig: *Rig, value: Lease.Handle) !void {
        Lease.release(try Lease.resolve(&rig.slot, value));
    }

    /// Checks that the ledger counts exactly what the backing holds.
    fn expectSettled(rig: *Rig) !void {
        try Engine.Heap.expectMatches(&rig.engine.heap, &rig.backing);
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

const Scripted = Codec.Scripted;

/// The commands of the scripted codec that have one byte.
const row_command = [_]u8{@backingInt(Scripted.Command.row)};
const end_command = [_]u8{@backingInt(Scripted.Command.end)};
const invalid_command = [_]u8{@backingInt(Scripted.Command.invalid)};

/// The script of a whole image of one pixel.
const pixel_script = Scripted.imageCommand(1, 1) ++ row_command ++ end_command;

/// The script of an image of 3 by 4 pixels up to its admission, and the
/// bytes of its lease with their block header.
const image_script = Scripted.imageCommand(3, 4);
const image_lease_bytes = 3 * 4 * Lease.pixel_bytes + Engine.Heap.header_size;

/// Checks that the rows [0, rows) of `lease` hold the samples of the
/// scripted codec, each pixel with an alpha of 255.
fn expectRows(lease: *Lease, rows: u32) !void {
    for (0..rows) |index| {
        const pixels = lease.row(@intCast(index));

        for (0..lease.width) |column| {
            const pixel = pixels[column * Lease.pixel_bytes ..];

            for (0..3) |channel| {
                try testing.expectEqual(
                    Scripted.sample(@intCast(index), column * 3 + channel),
                    pixel[channel],
                );
            }

            try testing.expectEqual(0xff, pixel[3]);
        }
    }
}

test "a job word holds its generation in the low 40 bits" {
    const word: Word = .{
        .generation = 0xab_cdef_0123,
        .canceled = true,
        .terminal = true,
    };

    try testing.expectEqual(0x3ab_cdef_0123, @as(u64, @bitCast(word)));
    try testing.expectEqual(0, @as(u64, @bitCast(Word{})));
}

test "a job that fails keeps its slot until its release" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const handle = try rig.admit(content, .{});

    const generation = unpack(handle).generation;

    try testing.expectEqual(tag_job, @backingInt(unpack(handle).tag));
    try testing.expectEqual(liveWord(generation), rig.wordOf(handle));
    try testing.expectEqual(1, countOwned(rig.engine));
    try testing.expectEqual(1, Lease.countLive(rig.engine));

    // A release before the terminal outcome changes nothing.
    try testing.expectError(error.BindingMismatch, rig.drop(handle));
    try testing.expectEqual(liveWord(generation), rig.wordOf(handle));
    try rig.fail(handle);
    try testing.expectEqual(terminalWord(generation), rig.wordOf(handle));
    try testing.expectEqual(1, countOwned(rig.engine));
    try testing.expectEqual(0, Lease.countLive(rig.engine));

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
    try testing.expectEqual(1, Lease.countLive(rig.engine));
    try testing.expectError(error.BindingMismatch, rig.drop(handle));
    try cancel(&rig.slot, handle);
    try testing.expectEqual(flaggedWord(generation), rig.wordOf(handle));
    try testing.expectEqual(.canceled, try rig.advance(handle));
    try testing.expectEqual(canceledWord(generation), rig.wordOf(handle));
    try testing.expectEqual(0, Lease.countLive(rig.engine));
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
    try rig.fail(handle);
    try rig.drop(handle);
    try rig.finish();
}

test "a request checks its content and then the limits" {
    var rig: Rig = undefined;

    try rig.start(.{ .jobs = 1, .leases = 1 });

    const first = try rig.open();
    const second = try rig.open();

    // The step that learns the image decides a region, so a request
    // never refuses one.
    const off_left: Request = .{
        .region = .{ .left = 1, .top = 0, .right = 2, .bottom = 2 },
    };

    const handle = try rig.admit(first, .{});

    const next = rig.engine.serial.next;

    // A content that admitted its job decides before the count limits.
    try testing.expectError(error.BindingMismatch, rig.admit(first, off_left));
    try testing.expectError(error.BindingMismatch, rig.admit(first, .{}));
    try testing.expectError(error.BudgetExceeded, rig.admit(second, off_left));
    try testing.expectError(error.BudgetExceeded, rig.admit(second, .{}));

    // A terminal job still holds its slot, and its content admits no
    // second job.
    try rig.fail(handle);
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
    try rig.fail(later);
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
    try rig.fail(first_job);

    const second_job = try rig.admit(second, .{});

    try testing.expectEqual(1, unpack(second_job).index);
    try testing.expectEqual(2, countOwned(rig.engine));
    try testing.expectEqual(1, Lease.countLive(rig.engine));
    try rig.fail(second_job);
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
    try testing.expectEqual(0, Lease.countLive(rig.engine));
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

    try rig.fail(handle);
    try rig.closeContent(content);
    try testing.expectEqual(terminalWord(generation), rig.wordOf(handle));
    try testing.expectEqual(1, countOwned(rig.engine));

    // The slot of the content serves a later content, which admits its
    // own job beside the owned one.
    const later = try rig.admitNew();

    try testing.expectEqual(1, unpack(later).index);
    try testing.expectEqual(terminalWord(generation), rig.wordOf(handle));
    try rig.fail(later);
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

    try testing.expectEqual(1, Lease.countLive(rig.engine));

    try testing.expectEqual(
        .pending,
        try Engine.shutdown(&rig.slot, rig.handle),
    );

    try testing.expectEqual(
        canceledWord(unpack(shut).generation),
        rig.wordOf(shut),
    );

    try testing.expectEqual(0, Lease.countLive(rig.engine));
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

    try rig.fail(ended_job);

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
        try testing.expectEqual(0, Lease.countLive(rig.engine));

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

    try rig.fail(earlier);
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

    try rig.fail(later);
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

    try testing.expectEqual(
        .canceled,
        job.conclude(rig.engine, .engine_failure).outcome,
    );

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
    try testing.expectEqual(
        .engine_failure,
        job.conclude(rig.engine, .engine_failure).outcome,
    );

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

        // The step completes the image unless the cancellation wins.
        try rig.supply(handle, &pixel_script, true);

        const live = try resolve(&rig.slot, handle);

        var cancelers: Cancelers = .{};

        try cancelers.start(1, &rig.slot, handle);

        cancelers.signal();

        const taken = step(live);

        cancelers.finish();

        const attempt = cancelers.made(1)[0];
        const word = rig.wordOf(handle);

        // The request found its job, whichever side won.
        try attempt.outcome;
        try testing.expect(attempt.seen.canceled or attempt.seen.terminal);

        // The step's status and the word agree on the one outcome, and a
        // flag that the request saw set is never lost.
        try testing.expect(word.terminal);

        if (attempt.seen.canceled) try testing.expect(word.canceled);

        switch (taken.outcome.?) {
            .completed => {
                try testing.expect(!word.canceled);
                try testing.expectEqual(1, taken.report.covered_rows);
                try rig.releaseLease(taken.report.lease.?);
            },
            // A canceled step publishes nothing, also when the codec
            // wrote the row before it observed the flag.
            .canceled => {
                try testing.expect(word.canceled);
                try testing.expectEqual(null, taken.report.lease);
                try testing.expectEqual(0, taken.report.covered_rows);
            },
            else => return error.TestUnexpectedResult,
        }

        try testing.expectEqual(0, Lease.countLive(rig.engine));
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

/// The admission of the image of `image_script` at a scale of 1:1.
const image_admission: Decode.Admission = .{
    .image = .{ .width = 3, .height = 4, .layout = .rgb8 },
    .output_width = 3,
    .output_height = 4,
};

test "a step without input waits with an empty report" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const handle = try rig.admit(content, .{});

    for (0..2) |_| {
        const taken = try rig.take(handle);

        try testing.expectEqual(null, taken.outcome);
        try testing.expectEqual(Report{}, taken.report);
    }

    // The first step opened the codec, which keeps its state in the
    // heap beside the staging of the content.
    try testing.expectEqual(own_blocks + 2, rig.backing.blocks);
    try testing.expectEqual(0, rig.engine.heap.ledger.usage.output);

    try testing.expectEqual(
        liveWord(unpack(handle).generation),
        rig.wordOf(handle),
    );

    // The end of the job releases the codec.
    try rig.closeContent(content);
    try testing.expectEqual(own_blocks, rig.backing.blocks);
    try rig.drop(handle);
    try rig.finish();
}

test "the admission step reports the image, the grid, and the lease" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const admitted: Report = .{
        .admission = image_admission,
        .admitted = .{ .width = 3, .height = 4 },
    };

    const taken = try rig.run(handle, &image_script, false);

    try testing.expectEqual(null, taken.outcome);
    try testing.expectEqual(admitted, taken.report);

    // The lease holds all of its pixels as output before any row, and
    // no reservation outlives the step.
    const usage = &rig.engine.heap.ledger.usage;

    try testing.expectEqual(image_lease_bytes, usage.output);
    try testing.expectEqual(0, usage.reserved);
    try rig.expectSettled();

    // Neither group changes after the admission step, and without a
    // publication the end of the job reclaims the lease.
    try cancel(&rig.slot, handle);

    const ended = try rig.take(handle);

    try testing.expectEqual(.canceled, ended.outcome);
    try testing.expectEqual(admitted, ended.report);
    try testing.expectEqual(0, usage.output);
    try testing.expectEqual(0, Lease.countLive(rig.engine));
    try rig.drop(handle);
    try rig.finish();
}

test "each step that yields rows publishes one more revision" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    // The image arrives with its first row.
    var taken = try rig.run(handle, &(image_script ++ row_command), false);

    const named_lease = taken.report.lease.?;

    try testing.expectEqual(null, taken.outcome);
    try testing.expectEqual(1, taken.report.revision);
    try testing.expectEqual(1, taken.report.covered_rows);
    try testing.expectEqual(1, taken.report.decoded_rows);

    const lease = try rig.leaseOf(named_lease);

    try testing.expectEqual(handles.Tag.lease, unpack(
        @fromBackingInt(@backingInt(named_lease)),
    ).tag);

    try expectRows(lease, 1);

    // A step that yields no row publishes nothing.
    taken = try rig.take(handle);

    try testing.expectEqual(null, taken.outcome);
    try testing.expectEqual(1, taken.report.revision);
    try testing.expectEqual(1, taken.report.covered_rows);

    // Two rows of one step are one publication of the same lease.
    taken = try rig.run(handle, &(row_command ++ row_command), false);

    try testing.expectEqual(named_lease, taken.report.lease);
    try testing.expectEqual(2, taken.report.revision);
    try testing.expectEqual(3, taken.report.covered_rows);
    try expectRows(lease, 3);

    // The image is complete, and the job waits for the end of its input.
    taken = try rig.run(handle, &(row_command ++ end_command), false);

    try testing.expectEqual(null, taken.outcome);
    try testing.expectEqual(3, taken.report.revision);
    try testing.expectEqual(4, taken.report.covered_rows);

    // The end of the input completes the job without a publication.
    taken = try rig.run(handle, &.{}, true);

    try testing.expectEqual(.completed, taken.outcome);

    try testing.expectEqual(Report{
        .lease = named_lease,
        .revision = 3,
        .covered_rows = 4,
        .admission = image_admission,
        .admitted = .{ .width = 3, .height = 4 },
        .decoded_rows = 4,
    }, taken.report);

    try testing.expectEqual(
        terminalWord(unpack(handle).generation),
        rig.wordOf(handle),
    );

    // The job's claim ended, and the caller's keeps the lease past the
    // release of the job.
    try rig.drop(handle);
    try testing.expectEqual(1, Lease.countLive(rig.engine));
    try testing.expectEqual(lease, try rig.leaseOf(named_lease));
    try expectRows(lease, 4);

    const usage = &rig.engine.heap.ledger.usage;

    try testing.expectEqual(image_lease_bytes, usage.output);
    try rig.releaseLease(named_lease);
    try testing.expectError(error.InvalidHandle, rig.releaseLease(named_lease));
    try testing.expectEqual(0, usage.output);
    try testing.expectEqual(0, Lease.countLive(rig.engine));
    try rig.finish();
}

test "a job that completes in one step publishes with its outcome" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const taken = try rig.run(handle, &pixel_script, true);

    try testing.expectEqual(.completed, taken.outcome);
    try testing.expectEqual(1, taken.report.revision);
    try testing.expectEqual(1, taken.report.covered_rows);
    try expectRows(try rig.leaseOf(taken.report.lease.?), 1);
    try rig.releaseLease(taken.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

test "an input that ends before its image keeps the published rows" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const early = try rig.run(handle, &(image_script ++ row_command), false);

    const named_lease = early.report.lease.?;

    const taken = try rig.run(handle, &.{}, true);

    try testing.expectEqual(.truncated_content, taken.outcome);
    try testing.expectEqual(early.report, taken.report);

    const lease = try rig.leaseOf(named_lease);

    try testing.expectEqual(1, lease.covered);
    try expectRows(lease, 1);
    try rig.releaseLease(named_lease);
    try rig.drop(handle);
    try rig.finish();
}

test "a failure publishes the rows that the step yielded before it" {
    const scripts = [_][]const u8{
        // A command that the format refuses, and a byte after the image.
        &(image_script ++ row_command ++ invalid_command),
        &(pixel_script ++ row_command),
    };

    for (scripts) |script| {
        var rig: Rig = undefined;

        try rig.start(.{});

        const handle = try rig.admitNew();

        const taken = try rig.run(handle, script, false);

        try testing.expectEqual(.invalid_content, taken.outcome);
        try testing.expectEqual(1, taken.report.revision);
        try testing.expectEqual(1, taken.report.covered_rows);
        try expectRows(try rig.leaseOf(taken.report.lease.?), 1);
        try rig.releaseLease(taken.report.lease.?);
        try rig.drop(handle);
        try rig.finish();
    }
}

test "a byte after the image fails in a later step as well" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const whole = try rig.run(handle, &pixel_script, false);

    try testing.expectEqual(null, whole.outcome);

    const taken = try rig.run(handle, &row_command, false);

    try testing.expectEqual(.invalid_content, taken.outcome);
    try testing.expectEqual(whole.report, taken.report);
    try rig.releaseLease(whole.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

test "a step that starts canceled consumes no byte and publishes nothing" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const early = try rig.run(handle, &(image_script ++ row_command), false);

    try rig.supply(handle, &(row_command ++ row_command), false);
    try cancel(&rig.slot, handle);

    const input = &rig.slotOf(handle).content.?.state.open;

    const taken = try rig.take(handle);

    try testing.expectEqual(.canceled, taken.outcome);
    try testing.expectEqual(early.report, taken.report);
    try testing.expectEqual(0, input.consumed);
    try testing.expectEqual(2, input.staged);

    // The caller's claim keeps the lease of the canceled job.
    const lease = try rig.leaseOf(early.report.lease.?);

    try testing.expectEqual(1, lease.covered);
    try rig.releaseLease(early.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

/// A hook that requests the cancellation of a job from inside a step,
/// after one row of its image.
const CancelAfter = struct {
    slot: *const Engine.Slot,
    handle: Handle,
    row: u32,

    fn hooks(canceling: *CancelAfter) Scripted.Hooks {
        return .{ .ctx = canceling, .after_row = afterRow };
    }

    fn afterRow(ctx: ?*anyopaque, index: u32) void {
        const canceling: *CancelAfter = @ptrCast(@alignCast(ctx.?));

        if (index != canceling.row) return;

        cancel(canceling.slot, canceling.handle) catch
            @panic("the hook cancels a job that its test owns");
    }
};

test "a cancellation inside a step ends it within one row, unpublished" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    var canceling: CancelAfter = .{
        .slot = &rig.slot,
        .handle = handle,
        .row = 1,
    };

    rig.hooks = canceling.hooks();

    const rows = row_command ++ row_command ++ row_command;

    const taken = try rig.run(handle, &(image_script ++ rows), false);

    // The codec wrote two rows and stopped, and the step publishes
    // neither, so no report named the lease, and its end reclaims it.
    try testing.expectEqual(.canceled, taken.outcome);

    try testing.expectEqual(Report{
        .admission = image_admission,
        .admitted = .{ .width = 3, .height = 4 },
        .decoded_rows = 2,
    }, taken.report);

    try testing.expectEqual(
        canceledWord(unpack(handle).generation),
        rig.wordOf(handle),
    );

    try testing.expectEqual(0, Lease.countLive(rig.engine));
    try testing.expectEqual(0, rig.engine.heap.ledger.usage.output);
    try rig.drop(handle);
    try rig.finish();
}

test "a cancellation inside a step repeats the last publication" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const early = try rig.run(handle, &(image_script ++ row_command), false);

    const lease = try rig.leaseOf(early.report.lease.?);

    var canceling: CancelAfter = .{
        .slot = &rig.slot,
        .handle = handle,
        .row = 2,
    };

    rig.hooks = canceling.hooks();

    const rows = row_command ++ row_command ++ row_command;

    const taken = try rig.run(handle, &rows, false);

    var repeated = early.report;

    repeated.decoded_rows = 3;

    try testing.expectEqual(.canceled, taken.outcome);
    try testing.expectEqual(repeated, taken.report);

    // The rows that the step wrote stay outside the coverage.
    try testing.expectEqual(1, lease.covered);
    try expectRows(lease, 1);
    try rig.releaseLease(early.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

test "the close of a content after early output keeps the held lease" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const handle = try rig.admit(content, .{});

    const early = try rig.run(handle, &(image_script ++ row_command), false);

    try rig.closeContent(content);

    try testing.expectEqual(
        canceledWord(unpack(handle).generation),
        rig.wordOf(handle),
    );

    // The codec and the staging are gone, and the lease stays.
    try testing.expectEqual(own_blocks + 1, rig.backing.blocks);

    const lease = try rig.leaseOf(early.report.lease.?);

    try testing.expectEqual(1, lease.covered);
    try expectRows(lease, 1);
    try rig.drop(handle);
    try rig.releaseLease(early.report.lease.?);
    try rig.finish();
}

test "a lease that its caller releases early ends with its job" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const early = try rig.run(handle, &(image_script ++ row_command), false);

    const named_lease = early.report.lease.?;

    try rig.releaseLease(named_lease);
    try testing.expectError(error.InvalidHandle, rig.leaseOf(named_lease));

    // The job keeps the lease and goes on, and its reports name the
    // lease that the caller no longer holds.
    try testing.expectEqual(1, Lease.countLive(rig.engine));

    const taken = try rig.run(handle, &row_command, false);

    try testing.expectEqual(named_lease, taken.report.lease);
    try testing.expectEqual(2, taken.report.revision);
    try testing.expectEqual(2, taken.report.covered_rows);
    try testing.expectError(error.InvalidHandle, rig.leaseOf(named_lease));

    try cancel(&rig.slot, handle);
    try testing.expectEqual(.canceled, try rig.advance(handle));
    try testing.expectEqual(0, Lease.countLive(rig.engine));
    try testing.expectEqual(0, rig.engine.heap.ledger.usage.output);
    try rig.drop(handle);
    try rig.finish();
}

/// One admission of the image of `image_script`: a limit or a request
/// that differs from the roomy ones, and what the admission step makes
/// of it.
const AdmissionCase = struct {
    limit: ?[]const u8 = null,
    value: i64 = 0,
    wanted: Request = .{},
    /// The outcome of the admission step, or null when it admits.
    outcome: ?Outcome,
    /// The output grid that the step reports, or null when the image
    /// limits refuse the image before any geometry.
    grid: ?[2]u32 = .{ 3, 4 },
};

fn regionOf(right: u31, bottom: u31) Request {
    return .{
        .region = .{ .left = 0, .top = 0, .right = right, .bottom = bottom },
    };
}

const admission_cases = [_]AdmissionCase{
    // The image limits, each at its ceiling and below it.
    .{ .limit = "image_axis_pixels", .value = 4, .outcome = null },
    .{
        .limit = "image_axis_pixels",
        .value = 3,
        .outcome = .budget_exceeded,
        .grid = null,
    },
    .{ .limit = "image_area_pixels", .value = 12, .outcome = null },
    .{
        .limit = "image_area_pixels",
        .value = 11,
        .outcome = .budget_exceeded,
        .grid = null,
    },
    // The whole image as a region, a region past the image on either
    // axis, and one inside it that leaves a column out.
    .{ .wanted = regionOf(3, 4), .outcome = null },
    .{ .wanted = regionOf(4, 4), .outcome = .unsupported_operation },
    .{ .wanted = regionOf(3, 5), .outcome = .unsupported_operation },
    .{ .wanted = regionOf(2, 4), .outcome = .unsupported_operation },
    .{
        .wanted = .{
            .region = .{ .left = 1, .top = 0, .right = 3, .bottom = 4 },
        },
        .outcome = .unsupported_operation,
    },
    // A largest output width of at least the image width keeps the
    // image grid.
    .{ .wanted = .{ .max_output_width = 3 }, .outcome = null },
    .{ .wanted = .{ .max_output_width = 4 }, .outcome = null },
    // The byte ceilings of the lease, which come after the region.
    .{
        .limit = "output_lease_bytes",
        .value = image_lease_bytes,
        .outcome = null,
    },
    .{
        .limit = "output_lease_bytes",
        .value = image_lease_bytes - 1,
        .outcome = .budget_exceeded,
    },
    .{ .limit = "output_bytes", .value = image_lease_bytes, .outcome = null },
    .{
        .limit = "output_bytes",
        .value = image_lease_bytes - 1,
        .outcome = .budget_exceeded,
    },
    // Each check decides before the checks after it: the image limits
    // before the region, and the region before the ceilings.
    .{
        .limit = "image_axis_pixels",
        .value = 3,
        .wanted = regionOf(4, 4),
        .outcome = .budget_exceeded,
        .grid = null,
    },
    .{
        .limit = "output_lease_bytes",
        .value = image_lease_bytes - 1,
        .wanted = regionOf(4, 4),
        .outcome = .unsupported_operation,
    },
    .{
        .limit = "output_lease_bytes",
        .value = image_lease_bytes - 1,
        .wanted = regionOf(2, 4),
        .outcome = .unsupported_operation,
    },
};

test "the admission step checks the limits, the region, and the ceilings" {
    inline for (admission_cases) |case| {
        var limits = Rig.limitsOf(.{});

        if (case.limit) |name| @field(limits, name) = case.value;

        var rig: Rig = undefined;

        try rig.startUnder(limits);

        const content = try rig.open();

        const handle = try rig.admit(content, case.wanted);

        const taken = try rig.run(handle, &image_script, false);

        try testing.expectEqual(case.outcome, taken.outcome);
        try testing.expectEqual(null, taken.report.lease);
        try testing.expectEqual(0, taken.report.decoded_rows);

        if (case.grid) |grid| {
            const admission = taken.report.admission.?;

            try testing.expectEqual(image_admission.image, admission.image);
            try testing.expectEqual(grid[0], admission.output_width);
            try testing.expectEqual(grid[1], admission.output_height);
        } else {
            try testing.expectEqual(null, taken.report.admission);
        }

        const usage = &rig.engine.heap.ledger.usage;

        if (case.outcome == null) {
            try testing.expectEqual(
                Report.Admitted{ .width = 3, .height = 4 },
                taken.report.admitted,
            );

            try testing.expectEqual(image_lease_bytes, usage.output);
            try rig.closeContent(content);
        } else {
            // A refusal keeps nothing: the lease, its bytes, and the
            // codec are gone with the job.
            try testing.expectEqual(null, taken.report.admitted);
            try testing.expectEqual(own_blocks + 1, rig.backing.blocks);
        }

        try testing.expectEqual(0, usage.output);
        try testing.expectEqual(0, usage.reserved);
        try testing.expectEqual(0, Lease.countLive(rig.engine));
        try rig.drop(handle);
        try rig.finish();
    }
}

test "a step hands no byte past the length ceiling to the codec" {
    var limits = Rig.limitsOf(.{});

    // The image command and one row.
    limits.content_length_bytes = image_script.len + 1;

    const rows = row_command ++ row_command ++ row_command;

    // A portion that crosses the ceiling: the row before it decodes and
    // publishes, and the job then ends.
    {
        var rig: Rig = undefined;

        try rig.startUnder(limits);

        const handle = try rig.admitNew();

        const taken = try rig.run(handle, &(image_script ++ rows), false);

        try testing.expectEqual(.budget_exceeded, taken.outcome);
        try testing.expectEqual(1, taken.report.decoded_rows);
        try testing.expectEqual(1, taken.report.covered_rows);
        try rig.releaseLease(taken.report.lease.?);
        try rig.drop(handle);
        try rig.finish();
    }

    // A representation of exactly the ceiling passes, and the first
    // byte past it ends the job without reaching the codec.
    {
        var rig: Rig = undefined;

        try rig.startUnder(limits);

        const handle = try rig.admitNew();

        const within = try rig.run(
            handle,
            &(image_script ++ row_command),
            false,
        );

        try testing.expectEqual(null, within.outcome);

        const taken = try rig.run(handle, &row_command, false);

        try testing.expectEqual(.budget_exceeded, taken.outcome);
        try testing.expectEqual(within.report, taken.report);
        try rig.releaseLease(within.report.lease.?);
        try rig.drop(handle);
        try rig.finish();
    }

    // An image of exactly the ceiling completes with the end of its
    // input.
    {
        limits.content_length_bytes = pixel_script.len;

        var rig: Rig = undefined;

        try rig.startUnder(limits);

        const handle = try rig.admitNew();

        const taken = try rig.run(handle, &pixel_script, true);

        try testing.expectEqual(.completed, taken.outcome);
        try rig.releaseLease(taken.report.lease.?);
        try rig.drop(handle);
        try rig.finish();
    }
}

test "a failure that follows an unobserved cancellation publishes nothing" {
    const Canceling = struct {
        slot: *const Engine.Slot,
        handle: Handle,

        fn beforeInvalid(ctx: ?*anyopaque) void {
            const canceling: *@This() = @ptrCast(@alignCast(ctx.?));

            cancel(canceling.slot, canceling.handle) catch
                @panic("the hook cancels a job that its test owns");
        }
    };

    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    var canceling: Canceling = .{ .slot = &rig.slot, .handle = handle };

    rig.hooks = .{
        .ctx = &canceling,
        .before_invalid = Canceling.beforeInvalid,
    };

    // The codec wrote a row, observed a clear flag, and then failed
    // after the request, without observing the flag again. The failure
    // loses to the cancellation, so the row stays unpublished.
    const script = image_script ++ row_command ++ invalid_command;

    const taken = try rig.run(handle, &script, false);

    try testing.expectEqual(.canceled, taken.outcome);
    try testing.expectEqual(null, taken.report.lease);
    try testing.expectEqual(0, taken.report.covered_rows);
    try testing.expectEqual(1, taken.report.decoded_rows);

    try testing.expectEqual(
        canceledWord(unpack(handle).generation),
        rig.wordOf(handle),
    );

    try testing.expectEqual(0, Lease.countLive(rig.engine));
    try rig.drop(handle);
    try rig.finish();
}

test "a shutdown ends a decoding job and keeps the lease that it published" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const early = try rig.run(handle, &(image_script ++ row_command), false);

    try testing.expectEqual(
        .pending,
        try Engine.shutdown(&rig.slot, rig.handle),
    );

    // The codec and the staging are gone, and the lease stays.
    try testing.expectEqual(
        canceledWord(unpack(handle).generation),
        rig.wordOf(handle),
    );

    try testing.expectEqual(own_blocks + 1, rig.backing.blocks);

    const lease = try rig.leaseOf(early.report.lease.?);

    try testing.expectEqual(1, lease.covered);
    try expectRows(lease, 1);
    try rig.drop(handle);

    try testing.expectEqual(
        .pending,
        try Engine.shutdown(&rig.slot, rig.handle),
    );

    try rig.releaseLease(early.report.lease.?);
    try rig.finish();
}

test "a codec that ends its image short of the lease fails the job" {
    const cut_command = [_]u8{@backingInt(Scripted.Command.cut)};

    const scripts = [_][]const u8{
        // Before the image, and before its last row.
        &cut_command,
        &(image_script ++ row_command ++ cut_command),
    };

    for (scripts, 0..) |script, rows| {
        var rig: Rig = undefined;

        try rig.start(.{});

        const handle = try rig.admitNew();

        const taken = try rig.run(handle, script, true);

        // The rows that arrived publish, and the job never completes.
        try testing.expectEqual(.engine_failure, taken.outcome);
        try testing.expectEqual(rows, taken.report.covered_rows);

        if (taken.report.lease) |named_lease| try rig.releaseLease(named_lease);

        try testing.expectEqual(0, Lease.countLive(rig.engine));
        try rig.drop(handle);
        try rig.finish();
    }
}

test "each failed allocation of a decode ends the job and keeps nothing" {
    // The state of the codec, the pixels of the lease, and the
    // workspace of the codec, in the order of their allocation.
    const reports = [_]Report{
        .{},
        .{ .admission = image_admission },
        .{
            .admission = image_admission,
            .admitted = .{ .width = 3, .height = 4 },
        },
    };

    const script = image_script ++ row_command;

    for (reports, 0..) |report, fail_index| {
        var rig: Rig = undefined;

        try rig.start(.{});

        const handle = try rig.admitNew();

        var failing: testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });

        rig.backing.gpa = failing.allocator();

        const taken = try rig.run(handle, &script, false);

        rig.backing.gpa = testing.allocator;

        try testing.expectEqual(.allocation_failed, taken.outcome);
        try testing.expectEqual(report, taken.report);

        const usage = &rig.engine.heap.ledger.usage;

        try testing.expectEqual(own_blocks + 1, rig.backing.blocks);
        try testing.expectEqual(0, usage.output);
        try testing.expectEqual(0, usage.reserved);
        try testing.expectEqual(0, Lease.countLive(rig.engine));
        try rig.expectSettled();
        try rig.drop(handle);
        try rig.finish();
    }

    // A decode allocates nothing else: with the fourth allocation
    // failing, the same step succeeds.
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = reports.len,
    });

    rig.backing.gpa = failing.allocator();

    const taken = try rig.run(handle, &script, false);

    rig.backing.gpa = testing.allocator;

    try testing.expectEqual(null, taken.outcome);
    try testing.expectEqual(1, taken.report.covered_rows);
    try rig.expectSettled();
    try rig.releaseLease(taken.report.lease.?);
    try cancel(&rig.slot, handle);
    try testing.expectEqual(.canceled, try rig.advance(handle));
    try rig.drop(handle);
    try rig.finish();
}

test "a budget that refuses the codec ends the job as BudgetExceeded" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admitNew();

    const ledger = &rig.engine.heap.ledger;
    const budget = ledger.budget;

    // The budget admits what the engine holds and nothing more.
    ledger.budget = .{ .bytes = ledger.usage.live };

    const taken = try rig.run(handle, &image_script, false);

    ledger.budget = budget;

    try testing.expectEqual(.budget_exceeded, taken.outcome);
    try testing.expectEqual(Report{}, taken.report);
    try testing.expectEqual(own_blocks + 1, rig.backing.blocks);
    try rig.drop(handle);
    try rig.finish();
}

test "a request takes the generations of its job and its lease or none" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const content = try rig.open();

    const last = std.math.maxInt(handles.Generation);

    // One issue remains, and a request needs two.
    rig.engine.serial = .{ .next = last - 1 };

    try testing.expectError(error.EngineFailure, rig.admit(content, .{}));
    try testing.expectEqual(last - 1, rig.engine.serial.next);
    try testing.expectEqual(0, countOwned(rig.engine));
    try testing.expectEqual(0, Lease.countLive(rig.engine));

    rig.engine.serial = .{ .next = last - 2 };

    const handle = try rig.admit(content, .{});

    try testing.expectEqual(last - 2, unpack(handle).generation);
    try testing.expectEqual(last - 1, rig.slotOf(handle).lease.?.generation);
    try testing.expect(rig.engine.serial.retired());
    try rig.fail(handle);
    try rig.drop(handle);
    try rig.finish();
}

test "a held lease counts against its limit and keeps the shutdown pending" {
    var rig: Rig = undefined;

    try rig.start(.{ .jobs = 2, .leases = 1 });

    const second = try rig.open();

    const first_job = try rig.admitNew();

    const taken = try rig.run(first_job, &pixel_script, true);

    try testing.expectEqual(.completed, taken.outcome);
    try rig.drop(first_job);

    // The caller's claim outlives the job, and the lease stays live.
    try testing.expectEqual(0, countOwned(rig.engine));
    try testing.expectError(error.BudgetExceeded, rig.admit(second, .{}));

    for (0..2) |_| {
        try testing.expectEqual(
            .pending,
            try Engine.shutdown(&rig.slot, rig.handle),
        );
    }

    // The release works while the engine closes, and it lets the
    // shutdown complete.
    try rig.releaseLease(taken.report.lease.?);
    try rig.finish();
}

/// Checks that the row `row` of `lease` holds the image row `index` of
/// a scripted codec at the image size, with an alpha of 255.
fn expectImageRow(lease: *Lease, row: u32, index: u32) !void {
    for (lease.row(row), 0..) |byte, at| {
        const expected = if (at % 4 == 3)
            0xff
        else
            Scripted.sample(index, at / 4 * 3 + at % 4);

        try testing.expectEqual(expected, byte);
    }
}

/// Checks that the row `row` of `lease` holds the grid row `grid_row` of
/// a scripted image scaled to half its size: each sample is the mean of
/// a block of two by two samples, halves up.
fn expectHalvedRow(lease: *Lease, row: u32, grid_row: u32) !void {
    for (lease.row(row), 0..) |byte, at| {
        if (at % 4 == 3) {
            try testing.expectEqual(0xff, byte);

            continue;
        }

        var sum: u32 = 2;

        for ([_]u32{ 2 * grid_row, 2 * grid_row + 1 }) |index| {
            for ([_]usize{ 2 * (at / 4), 2 * (at / 4) + 1 }) |column| {
                sum += Scripted.sample(index, column * 3 + at % 4);
            }
        }

        try testing.expectEqual(sum / 4, byte);
    }
}

test "a band at the image size ends the job at its last row" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admit(try rig.open(), .{
        .region = .{ .left = 0, .top = 1, .right = 3, .bottom = 3 },
    });

    // The input goes on behind the band, with a command that would fail
    // a job that read it.
    const script = image_script ++ row_command ++ row_command ++
        row_command ++ invalid_command;

    const taken = try rig.run(handle, &script, false);

    try testing.expectEqual(.completed, taken.outcome);
    try testing.expectEqual(3, taken.report.decoded_rows);
    try testing.expectEqual(2, taken.report.covered_rows);
    try testing.expectEqual(1, taken.report.revision);

    try testing.expectEqual(
        Report.Admitted{ .width = 3, .height = 2, .top = 1 },
        taken.report.admitted,
    );

    const lease = try rig.leaseOf(taken.report.lease.?);

    try expectImageRow(lease, 0, 1);
    try expectImageRow(lease, 1, 2);
    try rig.releaseLease(taken.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

test "a band publishes no row above it and each of its rows" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admit(try rig.open(), .{
        .region = .{ .left = 0, .top = 2, .right = 3, .bottom = 4 },
    });

    const above = try rig.run(
        handle,
        &(image_script ++ row_command ++ row_command),
        false,
    );

    try testing.expectEqual(null, above.outcome);
    try testing.expectEqual(2, above.report.decoded_rows);
    try testing.expectEqual(0, above.report.covered_rows);
    try testing.expectEqual(null, above.report.lease);

    const inside = try rig.run(handle, &row_command, false);

    try testing.expectEqual(null, inside.outcome);
    try testing.expectEqual(1, inside.report.covered_rows);
    try expectImageRow(try rig.leaseOf(inside.report.lease.?), 0, 2);

    // The band reaches the last row of the image, so the job reads its
    // input to the end, and a command that breaks the format fails it.
    const last = try rig.run(handle, &row_command, false);

    try testing.expectEqual(null, last.outcome);
    try testing.expectEqual(2, last.report.covered_rows);

    const ended = try rig.run(handle, &invalid_command, true);

    try testing.expectEqual(.invalid_content, ended.outcome);
    try testing.expectEqual(2, ended.report.covered_rows);
    try rig.releaseLease(ended.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

const halved_script = Scripted.imageCommand(4, 4);

const halved_admission: Decode.Admission = .{
    .image = .{ .width = 4, .height = 4, .layout = .rgb8 },
    .output_width = 2,
    .output_height = 2,
};

test "a scaled image publishes each grid row as its image rows arrive" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admit(try rig.open(), .{ .max_output_width = 2 });

    const first = try rig.run(handle, &(halved_script ++ row_command), false);

    try testing.expectEqual(null, first.outcome);
    try testing.expectEqual(halved_admission, first.report.admission);
    try testing.expectEqual(1, first.report.decoded_rows);
    try testing.expectEqual(0, first.report.covered_rows);
    try testing.expectEqual(null, first.report.lease);

    try testing.expectEqual(
        Report.Admitted{ .width = 2, .height = 2 },
        first.report.admitted,
    );

    const second = try rig.run(handle, &row_command, false);

    try testing.expectEqual(1, second.report.covered_rows);
    try testing.expectEqual(1, second.report.revision);

    const rest = row_command ++ row_command ++ end_command;

    const last = try rig.run(handle, &rest, true);

    try testing.expectEqual(.completed, last.outcome);
    try testing.expectEqual(4, last.report.decoded_rows);
    try testing.expectEqual(2, last.report.covered_rows);

    const lease = try rig.leaseOf(last.report.lease.?);

    try expectHalvedRow(lease, 0, 0);
    try expectHalvedRow(lease, 1, 1);
    try rig.releaseLease(last.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

test "a scaled band takes the image rows that its grid rows cover" {
    var rig: Rig = undefined;

    try rig.start(.{});

    // The image rows 2 to 5 of 8 are the grid rows 1 and 2 of 4.
    const handle = try rig.admit(try rig.open(), .{
        .region = .{ .left = 0, .top = 2, .right = 4, .bottom = 6 },
        .max_output_width = 2,
    });

    const script = comptime Scripted.imageCommand(4, 8) ++ row_command ++
        row_command ++ row_command ++ row_command ++ row_command ++
        row_command ++ invalid_command;

    const taken = try rig.run(handle, &script, false);

    try testing.expectEqual(.completed, taken.outcome);
    try testing.expectEqual(6, taken.report.decoded_rows);
    try testing.expectEqual(2, taken.report.covered_rows);

    try testing.expectEqual(
        Report.Admitted{ .width = 2, .height = 2, .top = 1 },
        taken.report.admitted,
    );

    const lease = try rig.leaseOf(taken.report.lease.?);

    try expectHalvedRow(lease, 0, 1);
    try expectHalvedRow(lease, 1, 2);
    try rig.releaseLease(taken.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

test "a band from the first row ends above the last row" {
    var rig: Rig = undefined;

    try rig.start(.{});

    const handle = try rig.admit(try rig.open(), regionOf(3, 3));

    const script = image_script ++ row_command ++ row_command ++
        row_command ++ invalid_command;

    const taken = try rig.run(handle, &script, false);

    try testing.expectEqual(.completed, taken.outcome);
    try testing.expectEqual(3, taken.report.decoded_rows);

    try testing.expectEqual(
        Report.Admitted{ .width = 3, .height = 3 },
        taken.report.admitted,
    );

    const lease = try rig.leaseOf(taken.report.lease.?);

    for (0..3) |row| try expectImageRow(lease, @intCast(row), @intCast(row));

    try rig.releaseLease(taken.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

/// Returns a script of `count` rows.
fn rowsOf(comptime count: usize) [count]u8 {
    return @splat(@backingInt(Scripted.Command.row));
}

/// The units that the cell `cell` of a grid with cells of `size` units
/// shares with the cell `other` of a grid with cells of `other_size`.
fn sharedUnits(cell: u64, size: u64, other: u64, other_size: u64) u64 {
    const low = @max(cell * size, other * other_size);
    const high = @min((cell + 1) * size, (other + 1) * other_size);

    return high -| low;
}

/// The area average of one sample of the grid of a scripted image, over
/// every pixel of the image at once.
fn averaged(
    image: [2]u32,
    grid: [2]u32,
    column: usize,
    row: u32,
    channel: usize,
) u8 {
    var sum: u128 = 0;

    for (0..image[1]) |y| {
        const rows = sharedUnits(y, grid[1], row, image[1]);

        for (0..image[0]) |x| {
            const columns = sharedUnits(x, grid[0], column, image[0]);
            const sample = Scripted.sample(@intCast(y), x * 3 + channel);

            sum += @as(u128, rows) * columns * sample;
        }
    }

    const area = @as(u128, image[0]) * image[1];

    return @intCast((sum + area / 2) / area);
}

test "a scaled band between grid edges publishes as its rows arrive" {
    var rig: Rig = undefined;

    try rig.start(.{});

    // 36 by 100 pixels scale to 27 by 75, so a grid row covers 1.33
    // image rows. The image rows 41 to 58 lie in the grid rows 30 to
    // 44, which cover the image rows 40 to 59.
    const handle = try rig.admit(try rig.open(), .{
        .region = .{ .left = 0, .top = 41, .right = 36, .bottom = 59 },
        .max_output_width = 27,
    });

    // The image row 40 starts the first grid row and does not end it.
    const above = comptime Scripted.imageCommand(36, 100) ++ rowsOf(41);

    const started = try rig.run(handle, &above, false);

    try testing.expectEqual(null, started.outcome);
    try testing.expectEqual(41, started.report.decoded_rows);
    try testing.expectEqual(0, started.report.covered_rows);

    try testing.expectEqual(
        Report.Admitted{ .width = 27, .height = 15, .top = 30 },
        started.report.admitted,
    );

    // The image row 41 ends it, in the step that delivers that row.
    const first = try rig.run(handle, &rowsOf(1), false);

    try testing.expectEqual(null, first.outcome);
    try testing.expectEqual(1, first.report.covered_rows);

    // The image row 59 ends the last grid row and the job, in a later
    // step than the first row, and nothing behind it is read.
    const last = try rig.run(handle, &(rowsOf(18) ++ invalid_command), false);

    try testing.expectEqual(.completed, last.outcome);
    try testing.expectEqual(60, last.report.decoded_rows);
    try testing.expectEqual(15, last.report.covered_rows);

    const lease = try rig.leaseOf(last.report.lease.?);

    for (0..15) |row| {
        for (lease.row(@intCast(row)), 0..) |byte, at| {
            const expected = if (at % 4 == 3) 0xff else averaged(
                .{ 36, 100 },
                .{ 27, 75 },
                at / 4,
                @intCast(30 + row),
                at % 4,
            );

            try testing.expectEqual(expected, byte);
        }
    }

    try rig.releaseLease(last.report.lease.?);
    try rig.drop(handle);
    try rig.finish();
}

test "a scale of an image beyond the exact sums is no operation of the build" {
    var limits = Rig.limitsOf(.{});

    limits.image_axis_pixels = std.math.maxInt(u31);
    limits.image_area_pixels = std.math.maxInt(i64);

    // An area of 2^60 pixels, above the 2^56 that the sums of a scale
    // hold exactly.
    const script = comptime Scripted.imageCommand(1 << 30, 1 << 30);

    const Case = struct { wanted: Request, outcome: Outcome, width: u32 };

    const cases = [_]Case{
        // The scale decides before the ceilings, and the image at its
        // own size only meets the ceiling of its lease.
        .{
            .wanted = .{ .max_output_width = 1 },
            .outcome = .unsupported_operation,
            .width = 1,
        },
        .{ .wanted = .{}, .outcome = .budget_exceeded, .width = 1 << 30 },
    };

    for (cases) |case| {
        var rig: Rig = undefined;

        try rig.startUnder(limits);

        const handle = try rig.admit(try rig.open(), case.wanted);

        const taken = try rig.run(handle, &script, false);

        const admission = taken.report.admission.?;

        try testing.expectEqual(case.outcome, taken.outcome);
        try testing.expectEqual(case.width, admission.output_width);
        try testing.expectEqual(null, taken.report.admitted);
        try testing.expectEqual(0, Lease.countLive(rig.engine));
        try rig.expectSettled();
        try rig.drop(handle);
        try rig.finish();
    }
}

test "each failed allocation of a scaled decode keeps nothing" {
    // The state of the codec, the pixels of the lease, the words of the
    // scale, and the workspace of the codec, in the order of their
    // allocation. A decode whose words fail holds its pixels until the
    // job ends, without an admitted lease.
    const reports = [_]Report{
        .{},
        .{ .admission = halved_admission },
        .{ .admission = halved_admission },
        .{
            .admission = halved_admission,
            .admitted = .{ .width = 2, .height = 2 },
        },
    };

    const script = halved_script ++ row_command ++ row_command;

    for (0..reports.len + 1) |fail_index| {
        var rig: Rig = undefined;

        try rig.start(.{});

        const handle = try rig.admit(try rig.open(), .{
            .max_output_width = 2,
        });

        var failing: testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });

        rig.backing.gpa = failing.allocator();

        const taken = try rig.run(handle, &script, false);

        rig.backing.gpa = testing.allocator;

        if (fail_index == reports.len) {
            // A scaled decode allocates nothing else, so the step
            // succeeds and covers the first grid row.
            try testing.expectEqual(null, taken.outcome);
            try testing.expectEqual(1, taken.report.covered_rows);
            try rig.expectSettled();
            try rig.releaseLease(taken.report.lease.?);
            try cancel(&rig.slot, handle);
            try testing.expectEqual(.canceled, try rig.advance(handle));
        } else {
            try testing.expectEqual(.allocation_failed, taken.outcome);
            try testing.expectEqual(reports[fail_index], taken.report);
            try testing.expectEqual(own_blocks + 1, rig.backing.blocks);
        }

        const usage = &rig.engine.heap.ledger.usage;

        try testing.expectEqual(0, usage.output);
        try testing.expectEqual(0, usage.reserved);
        try testing.expectEqual(0, Lease.countLive(rig.engine));
        try rig.expectSettled();
        try rig.drop(handle);
        try rig.finish();
    }
}
