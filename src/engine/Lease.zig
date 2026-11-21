//! An output lease: the slot of one lease in the table of its engine.
//!
//! The table is one block of the engine, sized at creation from the
//! count limit of live leases, and its slots never move. A lease lives
//! from the request of its job until San reclaims it. It holds no pixels
//! until the admission step of its job allocates all of them as output,
//! before the job writes the first row.
//!
//! Two claims keep a lease: the job's, from the request until the job's
//! terminal outcome, and the caller's, from the job's first publication
//! until the caller's one release. San reclaims the lease after the
//! later end of the two. The handle of a lease is valid exactly while
//! the caller's claim lasts, so a lease that never published has none.

const std = @import("std");
const Engine = @import("Engine.zig");
const handles = @import("handles.zig");

const Heap = Engine.Heap;

const Lease = @This();

/// The generation of the issuance, which the handle repeats. Zero is a
/// vacant slot, because the serial never issues it.
generation: handles.Generation = 0,
/// The pixels: `height` rows of `width` pixels of four bytes, without
/// padding. Null before the admission step of the job.
pixels: ?[]align(Heap.header_size) u8 = null,
width: u32 = 0,
height: u32 = 0,
/// The rows [0, covered) that a publication covers. The job writes only
/// rows from `covered` on, so a covered row never changes.
covered: u32 = 0,
claims: Claims = .{},

pub const Claims = struct {
    /// The job's, until its terminal outcome.
    job: bool = false,
    /// The caller's, from the first publication until its release.
    caller: bool = false,
};

/// The bytes of one pixel: R, G, B, and A, one byte each.
pub const pixel_bytes = 4;

/// A lease handle: the opaque 64-bit value that the ABI carries.
pub const Handle = enum(u64) {
    _,

    fn pack(index: handles.Index, generation: handles.Generation) Handle {
        const bits: handles.Slotted = .{
            .tag = .lease,
            .index = index,
            .generation = generation,
        };

        return @fromBackingInt(@as(u64, @bitCast(bits)));
    }
};

/// Returns a vacant slot of `engine`, or null while the count limit of
/// live leases is reached.
pub fn vacant(engine: *Engine) ?*Lease {
    for (engine.leases) |*lease| {
        if (lease.generation == 0) return lease;
    }

    return null;
}

/// Takes the vacant `lease` under `generation` for a job, whose claim
/// starts here.
pub fn issue(lease: *Lease, generation: handles.Generation) void {
    lease.* = .{ .generation = generation, .claims = .{ .job = true } };
}

/// Returns the handle of `lease`, a live lease of `engine`.
pub fn handle(lease: *const Lease, engine: *const Engine) Handle {
    const offset = @intFromPtr(lease) - @intFromPtr(engine.leases.ptr);

    return .pack(@intCast(offset / @sizeOf(Lease)), lease.generation);
}

/// A lease that the caller holds, in a live or closing engine. Only
/// `resolve` makes one, so a function that takes one validates nothing
/// again.
pub const Held = struct {
    engine: *Engine,
    lease: *Lease,
};

/// Returns the held lease of `value` in the engine of `slot`, also while
/// that engine shuts down. It reads the handle, the engine slot of the
/// process, and the slot of the table, in that order. A zero, stale,
/// foreign, or wrong-type handle fails as InvalidHandle, and so does the
/// handle of a lease that never published or that the caller released.
pub fn resolve(
    slot: *const Engine.Slot,
    value: Handle,
) error{InvalidHandle}!Held {
    const bits: handles.Slotted = @bitCast(@backingInt(value));

    if (bits.tag != .lease) return error.InvalidHandle;

    // A vacant slot holds generation 0, so a handle of that generation
    // would match every vacant slot.
    if (bits.generation == 0) return error.InvalidHandle;

    const held = slot.held() orelse return error.InvalidHandle;

    const leases = held.engine.leases;

    if (bits.index >= leases.len) return error.InvalidHandle;

    const lease = &leases[bits.index];

    // The state of the slot, then its generation.
    if (!lease.claims.caller) return error.InvalidHandle;
    if (lease.generation != bits.generation) return error.InvalidHandle;

    return .{ .engine = held.engine, .lease = lease };
}

/// Admits and allocates the pixels of `lease` for `width` by `height`
/// pixels, as output of `engine`. A lease beyond the ceiling of one
/// lease, beyond the ceiling of all output, or beyond the budget fails as
/// BudgetExceeded, and a failure keeps nothing. The pixels start
/// unwritten: a reader takes only covered rows.
pub fn allocate(
    lease: *Lease,
    engine: *Engine,
    width: u32,
    height: u32,
) Heap.Refusal!void {
    std.debug.assert(lease.pixels == null);

    const row_bytes = @as(u64, width) * pixel_bytes;

    const area_bytes = std.math.mul(u64, row_bytes, height) catch
        return error.BudgetExceeded;

    const size = std.math.cast(usize, area_bytes) orelse
        return error.BudgetExceeded;

    const bytes = Heap.accounted(size) orelse return error.BudgetExceeded;

    if (bytes > engine.output_lease_bytes) return error.BudgetExceeded;

    var reservation = try engine.heap.ledger.reserve(.output, bytes);
    defer engine.heap.ledger.cancel(&reservation);

    const pixels = engine.heap.allocReserved(&reservation, size) orelse
        return error.AllocationFailed;

    lease.pixels = pixels[0..size];
    lease.width = width;
    lease.height = height;
}

/// Returns the pixels of the row `index` of `lease`, which has its
/// pixels.
pub fn row(lease: *Lease, index: u32) []u8 {
    const row_bytes = @as(usize, lease.width) * pixel_bytes;

    return lease.pixels.?[@as(usize, index) * row_bytes ..][0..row_bytes];
}

/// Ends the claim of the job of `lease` at the job's terminal outcome.
pub fn endJobClaim(lease: *Lease, engine: *Engine) void {
    lease.claims.job = false;

    if (!lease.claims.caller) lease.reclaim(engine);
}

/// Releases the caller's claim on `held`. Its handle is invalid from
/// then on.
pub fn release(held: Held) void {
    held.lease.claims.caller = false;

    if (!held.lease.claims.job) held.lease.reclaim(held.engine);
}

/// Returns the count of the live leases of `engine`: the slots that are
/// taken, with or without pixels.
pub fn countLive(engine: *const Engine) u64 {
    var count: u64 = 0;

    for (engine.leases) |lease| count += @intFromBool(lease.generation != 0);

    return count;
}

/// Releases the pixels of `lease`, which no claim keeps, and frees its
/// slot.
fn reclaim(lease: *Lease, engine: *Engine) void {
    if (lease.pixels) |pixels| engine.heap.free(pixels.ptr);

    lease.* = .{};
}

const testing = std.testing;
const TestBacking = Heap.TestBacking;

/// The lease slots of the engine of each test below.
const lease_slots = 2;

/// An engine in a test, with the process that holds it. The engine
/// names the slot and the backing by address, so a rig starts in place.
const Rig = struct {
    binding: Engine.Binding = .{},
    slot: Engine.Slot = .{},
    backing: TestBacking,
    handle: Engine.Handle = undefined,
    engine: *Engine = undefined,

    fn start(rig: *Rig, limits: Engine.Limits) !void {
        rig.* = .{ .backing = .init(testing.allocator) };
        rig.binding.establish();

        rig.handle = try Engine.create(
            &rig.binding,
            &rig.slot,
            rig.backing.backing(),
            Engine.Codec.Scripted.opener,
            limits,
        );

        rig.engine = try Engine.resolve(&rig.slot, rig.handle);
    }

    /// Returns limits that admit every lease of the tests below within
    /// a budget of 1 MiB.
    fn roomy() Engine.Limits {
        var limits: Engine.Limits = undefined;

        inline for (Engine.Limits.names) |name| @field(limits, name) = 1 << 20;

        limits.content_count = 1;
        limits.job_count = 1;
        limits.output_lease_count = lease_slots;

        return limits;
    }

    /// Takes a slot for a job, as the request of a job does.
    fn take(rig: *Rig) !*Lease {
        const lease = vacant(rig.engine) orelse return error.BudgetExceeded;

        lease.issue(rig.engine.serial.take());

        return lease;
    }

    /// Takes a slot and publishes one row of a lease of 2 by 3 pixels.
    fn publish(rig: *Rig) !*Lease {
        const lease = try rig.take();

        try lease.allocate(rig.engine, 2, 3);

        lease.covered = 1;
        lease.claims.caller = true;

        return lease;
    }

    fn expectInvalid(rig: *Rig, value: Handle) !void {
        try testing.expectError(error.InvalidHandle, resolve(&rig.slot, value));
    }

    /// Shuts down the engine, which holds no lease, and checks that it
    /// leaves no block.
    fn finish(rig: *Rig) !void {
        try testing.expectEqual(
            .complete,
            try Engine.shutdown(&rig.slot, rig.handle),
        );

        try testing.expectEqual(0, rig.backing.blocks);
    }
};

fn handleOf(tag: u8, index: u16, generation: handles.Generation) Handle {
    const bits: handles.Slotted = .{
        .tag = @fromBackingInt(tag),
        .index = index,
        .generation = generation,
    };

    return @fromBackingInt(@as(u64, @bitCast(bits)));
}

fn unpack(value: Handle) handles.Slotted {
    return @bitCast(@backingInt(value));
}

const tag_lease = @backingInt(handles.Tag.lease);

test "a lease has no valid handle before its first publication" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    const lease = try rig.take();

    try testing.expectEqual(1, countLive(rig.engine));
    try rig.expectInvalid(lease.handle(rig.engine));

    try lease.allocate(rig.engine, 2, 3);
    try rig.expectInvalid(lease.handle(rig.engine));

    lease.endJobClaim(rig.engine);

    try testing.expectEqual(0, countLive(rig.engine));
    try testing.expectEqual(0, rig.engine.heap.ledger.usage.output);
    try rig.finish();
}

test "a published lease resolves until the caller releases it" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    const lease = try rig.publish();
    const value = lease.handle(rig.engine);
    const bits = unpack(value);

    try testing.expectEqual(handles.Tag.lease, bits.tag);
    try testing.expectEqual(lease.generation, bits.generation);

    const held = try resolve(&rig.slot, value);

    try testing.expectEqual(lease, held.lease);
    try testing.expectEqual(rig.engine, held.engine);

    // The job's claim alone keeps the lease after the caller's release,
    // and the handle is invalid from the release on.
    release(held);

    try rig.expectInvalid(value);
    try testing.expectEqual(1, countLive(rig.engine));
    try testing.expect(lease.pixels != null);

    lease.endJobClaim(rig.engine);

    try testing.expectEqual(0, countLive(rig.engine));
    try rig.finish();
}

test "the handle of each lease names its own slot" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    var leases: [lease_slots]*Lease = undefined;

    for (&leases) |*lease| lease.* = try rig.publish();

    for (leases, 0..) |lease, index| {
        const value = lease.handle(rig.engine);

        try testing.expectEqual(index, unpack(value).index);
        try testing.expectEqual(lease, (try resolve(&rig.slot, value)).lease);
    }

    for (leases) |lease| {
        release(try resolve(&rig.slot, lease.handle(rig.engine)));
        lease.endJobClaim(rig.engine);
    }

    try rig.finish();
}

test "the caller's claim keeps a lease after the job's claim ends" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    const lease = try rig.publish();
    const value = lease.handle(rig.engine);
    const size = Heap.accounted(2 * 3 * pixel_bytes).?;

    lease.endJobClaim(rig.engine);

    try testing.expectEqual(1, countLive(rig.engine));
    try testing.expectEqual(size, rig.engine.heap.ledger.usage.output);

    // A held lease keeps the shutdown pending, and the release works
    // while the engine closes.
    try testing.expectEqual(
        .pending,
        try Engine.shutdown(&rig.slot, rig.handle),
    );

    release(try resolve(&rig.slot, value));

    try rig.expectInvalid(value);
    try testing.expectEqual(0, countLive(rig.engine));
    try rig.finish();
}

test "zero, stale, foreign, and wrong-type handles fail as InvalidHandle" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    const lease = try rig.publish();
    const bits = unpack(lease.handle(rig.engine));

    try rig.expectInvalid(@fromBackingInt(0));
    try rig.expectInvalid(handleOf(tag_lease, bits.index, 0));
    try rig.expectInvalid(handleOf(tag_lease, bits.index, bits.generation + 1));
    try rig.expectInvalid(handleOf(tag_lease, lease_slots, bits.generation));

    try rig.expectInvalid(
        handleOf(tag_lease, std.math.maxInt(u16), bits.generation),
    );

    const other_tags = [_]handles.Tag{ .engine, .content, .job };

    for (other_tags) |tag| {
        try rig.expectInvalid(
            handleOf(@backingInt(tag), bits.index, bits.generation),
        );
    }

    // The slot of a reclaimed lease takes a new generation, so the
    // earlier handle stays invalid.
    release(try resolve(&rig.slot, lease.handle(rig.engine)));
    lease.endJobClaim(rig.engine);

    const again = try rig.publish();

    try testing.expectEqual(lease, again);
    try rig.expectInvalid(handleOf(tag_lease, bits.index, bits.generation));

    release(try resolve(&rig.slot, again.handle(rig.engine)));
    again.endJobClaim(rig.engine);
    try rig.finish();
}

test "the handle of a lease fails once its engine completes its shutdown" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    const lease = try rig.publish();
    const value = lease.handle(rig.engine);

    release(try resolve(&rig.slot, value));
    lease.endJobClaim(rig.engine);
    try rig.finish();

    try rig.expectInvalid(value);
}

test "the slots bound the live leases" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    var taken: [lease_slots]*Lease = undefined;

    for (&taken) |*lease| lease.* = try rig.take();

    try testing.expectEqual(null, vacant(rig.engine));
    try testing.expectEqual(lease_slots, countLive(rig.engine));

    taken[0].endJobClaim(rig.engine);

    try testing.expectEqual(taken[0], vacant(rig.engine));

    taken[1].endJobClaim(rig.engine);
    try rig.finish();
}

test "a lease beyond a ceiling fails as BudgetExceeded and keeps nothing" {
    const size = 8 * 8 * pixel_bytes;
    const bytes = Heap.accounted(size).?;

    const Case = struct { limit: []const u8, admits: bool };

    const cases = [_]Case{
        .{ .limit = "output_lease_bytes", .admits = true },
        .{ .limit = "output_lease_bytes", .admits = false },
        .{ .limit = "output_bytes", .admits = true },
        .{ .limit = "output_bytes", .admits = false },
    };

    inline for (cases) |case| {
        var limits = Rig.roomy();

        @field(limits, case.limit) =
            @intCast(if (case.admits) bytes else bytes - 1);

        var rig: Rig = undefined;

        try rig.start(limits);

        const lease = try rig.take();
        const usage = &rig.engine.heap.ledger.usage;
        const live = usage.live;

        if (case.admits) {
            try lease.allocate(rig.engine, 8, 8);
            try testing.expectEqual(bytes, usage.output);
            try testing.expectEqual(size, lease.pixels.?.len);
        } else {
            try testing.expectError(
                error.BudgetExceeded,
                lease.allocate(rig.engine, 8, 8),
            );

            try testing.expectEqual(live, usage.live);
            try testing.expectEqual(0, usage.reserved);
            try testing.expectEqual(null, lease.pixels);
        }

        lease.endJobClaim(rig.engine);
        try rig.finish();
    }
}

test "the output ceiling counts the leases together" {
    const bytes: i64 = @intCast(Heap.accounted(8 * 8 * pixel_bytes).?);

    var limits = Rig.roomy();

    limits.output_bytes = 2 * bytes - 1;

    var rig: Rig = undefined;

    try rig.start(limits);

    const first = try rig.take();
    const second = try rig.take();

    try first.allocate(rig.engine, 8, 8);

    try testing.expectError(
        error.BudgetExceeded,
        second.allocate(rig.engine, 8, 8),
    );

    // The room returns with the reclaimed lease.
    first.endJobClaim(rig.engine);
    try second.allocate(rig.engine, 8, 8);

    second.endJobClaim(rig.engine);
    try rig.finish();
}

test "a lease beyond the budget or the address space fails as BudgetExceeded" {
    var limits = Rig.roomy();

    limits.output_bytes = std.math.maxInt(i64);
    limits.output_lease_bytes = std.math.maxInt(i64);

    var rig: Rig = undefined;

    try rig.start(limits);

    const lease = try rig.take();
    const largest = std.math.maxInt(u32);

    // The budget refuses the first, and the size of the second leaves
    // 64 bits.
    try testing.expectError(
        error.BudgetExceeded,
        lease.allocate(rig.engine, 1024, 1024),
    );

    try testing.expectError(
        error.BudgetExceeded,
        lease.allocate(rig.engine, largest, largest),
    );

    try testing.expectEqual(0, rig.engine.heap.ledger.usage.reserved);

    lease.endJobClaim(rig.engine);
    try rig.finish();
}

test "a failed allocation of the pixels fails as AllocationFailed" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });

    const lease = try rig.take();
    const gpa = rig.backing.gpa;

    rig.backing.gpa = failing.allocator();

    try testing.expectError(
        error.AllocationFailed,
        lease.allocate(rig.engine, 8, 8),
    );

    rig.backing.gpa = gpa;

    try testing.expectEqual(null, lease.pixels);
    try testing.expectEqual(0, rig.engine.heap.ledger.usage.reserved);
    try testing.expectEqual(0, rig.engine.heap.ledger.usage.output);

    lease.endJobClaim(rig.engine);
    try rig.finish();
}

test "the rows of a lease lie side by side without padding" {
    var rig: Rig = undefined;

    try rig.start(Rig.roomy());

    const lease = try rig.take();

    try lease.allocate(rig.engine, 2, 3);

    const pixels = lease.pixels.?;

    try testing.expectEqual(2 * 3 * pixel_bytes, pixels.len);

    for (0..3) |index| {
        const start = index * 2 * pixel_bytes;

        try testing.expectEqual(
            pixels[start..][0 .. 2 * pixel_bytes],
            lease.row(@intCast(index)),
        );
    }

    lease.endJobClaim(rig.engine);
    try rig.finish();
}
