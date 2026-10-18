//! The accounted heap of one engine. Every block starts with a header of
//! 16 bytes that holds the requested size, so a release without a size,
//! such as a codec's, settles exactly. The header keeps the 16-byte
//! alignment that malloc guarantees on both ABIs, and the ledger counts
//! it with the requested bytes.
//!
//! The heap has two views: a std.mem.Allocator for Zig code, and `alloc`
//! and `free` without a size for the allocation callbacks of the codecs.
//! Both admit a block in the ledger before the backing allocates it.
//! When the heap refuses a block, it records the cause, the budget or the
//! backing, so that a caller who sees only a null pointer or
//! error.OutOfMemory reports the right category.

const std = @import("std");
const Ledger = @import("Ledger.zig");

const Heap = @This();

ledger: Ledger,
backing: Backing,
/// The cause of the latest refusal that no caller has taken. A block that
/// the heap serves later leaves it in place. A caller that maps a failure
/// through it therefore takes it before the work whose failure it maps,
/// and again once that work fails.
refusal: ?Refusal = null,

/// The bytes of the header before the memory of each block. The header
/// size is also the alignment of every block.
pub const header_size = 16;

const block_alignment: std.mem.Alignment = .fromByteUnits(header_size);

/// The cause of a refused block: the budget cannot admit it, or the
/// backing failed to allocate it after admission.
pub const Refusal = error{ BudgetExceeded, AllocationFailed };

/// The start of each header.
const Header = struct {
    /// The requested size, without the header.
    size: usize,
};

comptime {
    if (@sizeOf(Header) > header_size or @alignOf(Header) > header_size) {
        @compileError("the block header exceeds its 16 bytes");
    }
}

/// The source of the heap's memory: blocks aligned to 16 bytes. The heap
/// passes the length of each block back when it releases the block, so a
/// backing keeps no bookkeeping of its own.
pub const Backing = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns a block of `len` bytes aligned to 16, or null.
        alloc: *const fn (ptr: *anyopaque, len: usize) ?[*]align(16) u8,
        /// Releases the block that `alloc` returned for `len`.
        free: *const fn (
            ptr: *anyopaque,
            block: [*]align(16) u8,
            len: usize,
        ) void,
    };

    /// The system heap: Bionic's malloc and free on Android, and the
    /// host libc's in the host tests.
    pub const system: Backing = .{
        .ptr = undefined,
        .vtable = &.{ .alloc = systemAlloc, .free = systemFree },
    };
};

/// The libc functions of the system backing. San compiles without libc,
/// so it declares each libc function that it calls as a plain extern:
/// Zig accepts extern "c" and std.c only in a compile that links libc.
const libc = struct {
    extern fn malloc(size: usize) ?*anyopaque;
    extern fn free(ptr: ?*anyopaque) void;
};

fn systemAlloc(_: *anyopaque, len: usize) ?[*]align(16) u8 {
    const block = libc.malloc(len) orelse return null;

    return @ptrCast(@alignCast(block));
}

fn systemFree(_: *anyopaque, block: [*]align(16) u8, _: usize) void {
    libc.free(block);
}

pub fn init(backing: Backing, budget: Ledger.Budget) Heap {
    return .{ .ledger = .init(budget), .backing = backing };
}

/// Returns the bytes that a block of `size` requested bytes takes from
/// the budget, or null when the sum overflows.
pub fn accounted(size: usize) ?u64 {
    return std.math.add(u64, size, header_size) catch null;
}

/// Returns `size` bytes aligned to 16 that the budget admits directly,
/// or null after it records the cause of the refusal.
pub fn alloc(heap: *Heap, size: usize) ?[*]align(header_size) u8 {
    const bytes = accounted(size) orelse
        return heap.refuse(error.BudgetExceeded);

    var reservation = heap.ledger.reserve(bytes) catch |err|
        return heap.refuse(err);
    defer heap.ledger.cancel(&reservation);

    return heap.allocReserved(&reservation, size);
}

/// Returns `size` bytes aligned to 16 from what `reservation` holds, or
/// null after it records the cause of the refusal. A block beyond the
/// reservation is refused as BudgetExceeded, and a failed backing leaves
/// the reservation intact.
pub fn allocReserved(
    heap: *Heap,
    reservation: *Ledger.Reservation,
    size: usize,
) ?[*]align(header_size) u8 {
    const bytes = accounted(size) orelse
        return heap.refuse(error.BudgetExceeded);

    if (bytes > reservation.bytes) return heap.refuse(error.BudgetExceeded);

    const block = heap.backing.vtable.alloc(heap.backing.ptr, bytes) orelse
        return heap.refuse(error.AllocationFailed);

    heap.ledger.convert(reservation, bytes);
    headerOf(block).* = .{ .size = size };

    return block + header_size;
}

/// Returns a `T` from what `reservation` holds, as `allocReserved` does.
pub fn createReserved(
    heap: *Heap,
    comptime T: type,
    reservation: *Ledger.Reservation,
) ?*T {
    if (comptime @alignOf(T) > header_size) {
        @compileError("the heap aligns its blocks to 16 bytes only");
    }

    const memory = heap.allocReserved(reservation, @sizeOf(T)) orelse
        return null;

    return @ptrCast(memory);
}

/// Releases the block of `ptr`, which `alloc`, `allocReserved`, or
/// `createReserved` returned, by the size in its header. A null `ptr`
/// releases nothing, as with C's free.
pub fn free(heap: *Heap, ptr: ?*anyopaque) void {
    const payload = ptr orelse return;

    const memory: [*]align(header_size) u8 = @ptrCast(@alignCast(payload));

    heap.release(blockOf(memory));
}

/// Returns and clears the cause of the latest refusal, or null when no
/// refusal waits.
pub fn takeRefusal(heap: *Heap) ?Refusal {
    defer heap.refusal = null;

    return heap.refusal;
}

/// Returns the view of the heap for Zig code. Each allocation is a block
/// that the budget admits directly. The view never resizes a block in
/// place, so a growing container moves to a new block.
pub fn allocator(heap: *Heap) std.mem.Allocator {
    return .{ .ptr = heap, .vtable = &vtable };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = allocatorAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = allocatorFree,
};

fn allocatorAlloc(
    ptr: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    const heap: *Heap = @ptrCast(@alignCast(ptr));

    if (alignment.compare(.gt, block_alignment)) {
        @panic("San's heap aligns its blocks to 16 bytes only");
    }

    return heap.alloc(len);
}

fn allocatorFree(
    ptr: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    _: usize,
) void {
    const heap: *Heap = @ptrCast(@alignCast(ptr));

    heap.releaseSized(memory) catch
        @panic("a sized release does not match its block in San's heap");
}

fn refuse(heap: *Heap, cause: Refusal) ?[*]align(header_size) u8 {
    heap.refusal = cause;

    return null;
}

/// Releases the block of `memory`, which Zig code sized, after it checks
/// that size against the header. A mismatch releases nothing and fails
/// as SizeMismatch.
fn releaseSized(heap: *Heap, memory: []u8) error{SizeMismatch}!void {
    const block = blockOf(@alignCast(memory.ptr));

    if (headerOf(block).size != memory.len) return error.SizeMismatch;

    heap.release(block);
}

fn release(heap: *Heap, block: [*]align(header_size) u8) void {
    const bytes = accounted(headerOf(block).size).?;

    heap.backing.vtable.free(heap.backing.ptr, block, bytes);
    heap.ledger.release(bytes);
}

fn blockOf(memory: [*]align(header_size) u8) [*]align(header_size) u8 {
    return memory - header_size;
}

fn headerOf(block: [*]align(header_size) u8) *Header {
    return @ptrCast(block);
}

const testing = std.testing;

/// A backing for the tests of the engine module. It takes its blocks
/// from a Zig allocator, such as std.testing.FailingAllocator for failure
/// injection, and it counts what it holds, so that a test compares the
/// ledger with the backing. It is not thread-safe.
pub const TestBacking = struct {
    gpa: std.mem.Allocator,
    /// The bytes of the blocks that the heap holds.
    outstanding: u64 = 0,
    /// The highest `outstanding` so far.
    peak: u64 = 0,
    /// The blocks that the heap holds.
    blocks: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) TestBacking {
        return .{ .gpa = gpa };
    }

    pub fn backing(test_backing: *TestBacking) Backing {
        return .{
            .ptr = test_backing,
            .vtable = &.{ .alloc = testAlloc, .free = testFree },
        };
    }

    fn testAlloc(ptr: *anyopaque, len: usize) ?[*]align(16) u8 {
        const test_backing: *TestBacking = @ptrCast(@alignCast(ptr));

        const block = test_backing.gpa.alignedAlloc(u8, .@"16", len) catch
            return null;

        test_backing.outstanding += len;
        test_backing.blocks += 1;
        test_backing.peak = @max(test_backing.peak, test_backing.outstanding);

        return block.ptr;
    }

    fn testFree(ptr: *anyopaque, block: [*]align(16) u8, len: usize) void {
        const test_backing: *TestBacking = @ptrCast(@alignCast(ptr));

        test_backing.gpa.free(block[0..len]);
        test_backing.outstanding -= len;
        test_backing.blocks -= 1;
    }
};

/// A budget that admits every block of the tests below.
const roomy: Ledger.Budget = .{ .bytes = 1 << 20 };

/// Checks that the ledger counts exactly what the backing holds.
fn expectMatches(heap: *const Heap, test_backing: *const TestBacking) !void {
    try testing.expectEqual(test_backing.outstanding, heap.ledger.usage.live);
    try testing.expectEqual(test_backing.peak, heap.ledger.usage.peak);
}

test "a block carries its header in the budget and keeps 16-byte alignment" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), roomy);

    const sizes = [_]usize{ 0, 1, 15, 16, 17, 4096 };
    var blocks: [sizes.len][*]align(header_size) u8 = undefined;
    var live: u64 = 0;

    for (sizes, &blocks) |size, *block| {
        block.* = heap.alloc(size).?;
        live += size + header_size;
        @memset(block.*[0..size], 0xa5);
        try testing.expectEqual(0, @intFromPtr(block.*) % 16);
        try testing.expectEqual(live, heap.ledger.usage.live);
        try expectMatches(&heap, &test_backing);
    }

    for ([_]usize{ 3, 0, 5, 1, 4, 2 }) |index| {
        heap.free(blocks[index]);
        live -= sizes[index] + header_size;
        try testing.expectEqual(live, heap.ledger.usage.live);
        try expectMatches(&heap, &test_backing);
    }

    try testing.expectEqual(0, test_backing.blocks);
    try testing.expectEqual(Ledger.Usage{ .peak = 4241 }, heap.ledger.usage);
    try testing.expectEqual(null, heap.takeRefusal());
}

test "a free of null releases nothing" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), roomy);

    heap.free(null);
    try testing.expectEqual(Ledger.Usage{}, heap.ledger.usage);
}

test "a block beyond the budget is refused before the backing runs" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), .{ .bytes = 100 });

    const fitting = heap.alloc(84).?;

    try testing.expectEqual(100, heap.ledger.usage.live);
    try testing.expectEqual(null, heap.alloc(0));
    try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);
    try testing.expectEqual(null, heap.takeRefusal());
    heap.free(fitting);
    try testing.expectEqual(null, heap.alloc(85));
    try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);
    try testing.expectEqual(0, test_backing.blocks);
    try testing.expectEqual(100, test_backing.peak);
    try testing.expectEqual(Ledger.Usage{ .peak = 100 }, heap.ledger.usage);
}

test "a later block leaves a recorded refusal in place" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), .{ .bytes = 64 });

    try testing.expectEqual(null, heap.alloc(100));

    const block = heap.alloc(8).?;
    defer heap.free(block);

    try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);
    try testing.expectEqual(null, heap.takeRefusal());
}

test "a size whose header overflows the arithmetic is refused" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(
        test_backing.backing(),
        try .init(std.math.maxInt(i64)),
    );

    const max = std.math.maxInt(usize);

    for ([_]usize{ max, max - 15, max - 16 }) |size| {
        try testing.expectEqual(null, heap.alloc(size));
        try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);
    }

    try testing.expectEqual(null, accounted(max - 15));
    try testing.expectEqual(max, accounted(max - 16).?);
    try testing.expectEqual(0, test_backing.peak);
    try testing.expectEqual(Ledger.Usage{}, heap.ledger.usage);
}

test "a failed backing is recorded as AllocationFailed and changes no count" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    var heap: Heap = .init(test_backing.backing(), roomy);

    try testing.expectEqual(null, heap.alloc(64));
    try testing.expectEqual(error.AllocationFailed, heap.takeRefusal().?);
    try testing.expectEqual(Ledger.Usage{}, heap.ledger.usage);
    try testing.expectEqual(roomy.bytes, heap.ledger.available());
}

test "a sized release that mismatches its block is detected" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), roomy);

    const view = heap.allocator();

    const memory = try view.alloc(u8, 24);

    for ([_]usize{ 0, 23, 25, 40 }) |len| {
        const wrong = memory.ptr[0..len];

        try testing.expectError(error.SizeMismatch, heap.releaseSized(wrong));
        try testing.expectEqual(40, heap.ledger.usage.live);
        try testing.expectEqual(1, test_backing.blocks);
    }

    view.free(memory);
    try testing.expectEqual(0, heap.ledger.usage.live);
    try expectMatches(&heap, &test_backing);
}

test "reservations count apart from live blocks" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), .{ .bytes = 1000 });

    var reservation = try heap.ledger.reserve(500);
    defer heap.ledger.cancel(&reservation);

    const first = heap.allocReserved(&reservation, 100).?;

    try testing.expectEqual(384, reservation.bytes);

    try testing.expectEqual(
        Ledger.Usage{ .live = 116, .reserved = 384, .peak = 116 },
        heap.ledger.usage,
    );

    try testing.expectEqual(500, heap.ledger.available());
    try testing.expectEqual(null, heap.allocReserved(&reservation, 369));
    try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);
    try testing.expectEqual(384, reservation.bytes);
    try testing.expectEqual(null, heap.alloc(485));
    try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);

    const direct = heap.alloc(484).?;

    const second = heap.allocReserved(&reservation, 368).?;

    try testing.expectEqual(0, reservation.bytes);
    try testing.expectEqual(0, heap.ledger.available());

    try testing.expectEqual(
        Ledger.Usage{ .live = 1000, .reserved = 0, .peak = 1000 },
        heap.ledger.usage,
    );

    try expectMatches(&heap, &test_backing);
    heap.free(second);
    heap.free(direct);
    heap.free(first);
    try testing.expectEqual(Ledger.Usage{ .peak = 1000 }, heap.ledger.usage);
}

test "a failed backing leaves a reservation intact" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    var heap: Heap = .init(test_backing.backing(), .{ .bytes = 1000 });

    var reservation = try heap.ledger.reserve(500);

    try testing.expectEqual(null, heap.allocReserved(&reservation, 100));
    try testing.expectEqual(error.AllocationFailed, heap.takeRefusal().?);
    try testing.expectEqual(500, reservation.bytes);
    try testing.expectEqual(Ledger.Usage{ .reserved = 500 }, heap.ledger.usage);
    heap.ledger.cancel(&reservation);
    try testing.expectEqual(Ledger.Usage{}, heap.ledger.usage);
}

test "the allocator view serves Zig containers and settles every block" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), roomy);

    const view = heap.allocator();

    var list: std.ArrayList(u64) = .empty;

    for (0..1000) |item| {
        try list.append(view, item);
        try testing.expectEqual(1, test_backing.blocks);
        try expectMatches(&heap, &test_backing);
    }

    try testing.expectEqual(499500, sum(list.items));
    list.deinit(view);
    try testing.expectEqual(0, heap.ledger.usage.live);
    try expectMatches(&heap, &test_backing);
}

fn sum(items: []const u64) u64 {
    var total: u64 = 0;

    for (items) |item| total += item;

    return total;
}

test "the allocator view records a refusal of the budget" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), .{ .bytes = 64 });

    const view = heap.allocator();

    try testing.expectError(error.OutOfMemory, view.alloc(u8, 49));
    try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);
    try testing.expectEqual(Ledger.Usage{}, heap.ledger.usage);
}

test "the allocator view records a refusal of the backing" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    var heap: Heap = .init(test_backing.backing(), .{ .bytes = 64 });

    const view = heap.allocator();

    try testing.expectError(error.OutOfMemory, view.alloc(u8, 48));
    try testing.expectEqual(error.AllocationFailed, heap.takeRefusal().?);
    try testing.expectEqual(Ledger.Usage{}, heap.ledger.usage);
}

test "the system backing serves aligned blocks from libc" {
    var heap: Heap = .init(.system, roomy);

    const small = heap.alloc(1).?;

    const large = heap.alloc(65536).?;

    @memset(small[0..1], 0x5a);
    @memset(large[0..65536], 0x5a);
    try testing.expectEqual(0, @intFromPtr(small) % 16);
    try testing.expectEqual(0, @intFromPtr(large) % 16);
    try testing.expectEqual(65569, heap.ledger.usage.live);
    heap.free(large);
    heap.free(small);

    const view = heap.allocator();

    const items = try view.alloc(u128, 3);

    try testing.expectEqual(0, @intFromPtr(items.ptr) % 16);
    view.free(items);
    try testing.expectEqual(0, heap.ledger.usage.live);
    try testing.expectEqual(65569, heap.ledger.usage.peak);
}

/// The runs of a failure-injection test, and how many of them ended with
/// a settled ledger and an empty backing.
const Exits = struct {
    runs: u32 = 0,
    settled: u32 = 0,

    fn record(
        exits: *Exits,
        heap: *const Heap,
        test_backing: *const TestBacking,
    ) void {
        const usage = heap.ledger.usage;

        const settled = usage.live == 0 and usage.reserved == 0 and
            usage.peak == test_backing.peak and test_backing.blocks == 0;

        exits.runs += 1;
        exits.settled += @intFromBool(settled);
    }
};

/// Checks a refusal of an injected failure: the recorded cause is the
/// backing, and the ledger counts what the backing holds. Ends the run as
/// error.OutOfMemory, as std.testing.checkAllAllocationFailures expects.
fn refused(heap: *Heap, test_backing: *const TestBacking) !noreturn {
    try testing.expectEqual(error.AllocationFailed, heap.takeRefusal().?);
    try expectMatches(heap, test_backing);

    return error.OutOfMemory;
}

/// Allocates through every route of the heap, a partial construction
/// from one reservation included, and frees everything.
fn useEveryRoute(gpa: std.mem.Allocator, exits: *Exits) !void {
    var test_backing: TestBacking = .init(gpa);

    var heap: Heap = .init(test_backing.backing(), roomy);
    defer exits.record(&heap, &test_backing);

    const raw = heap.alloc(40) orelse try refused(&heap, &test_backing);
    defer heap.free(raw);

    var reservation = try heap.ledger.reserve(1024);
    defer heap.ledger.cancel(&reservation);

    const first = heap.allocReserved(&reservation, 100) orelse
        try refused(&heap, &test_backing);
    defer heap.free(first);

    const second = heap.createReserved(u128, &reservation) orelse
        try refused(&heap, &test_backing);
    defer heap.free(second);

    const view = heap.allocator();

    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(view);

    for (0..64) |item| {
        list.append(view, @intCast(item)) catch
            try refused(&heap, &test_backing);
    }

    try expectMatches(&heap, &test_backing);
}

test "every allocation failure of the heap records its cause and settles" {
    var exits: Exits = .{};

    try testing.checkAllAllocationFailures(
        testing.allocator,
        useEveryRoute,
        .{&exits},
    );

    try testing.expect(exits.runs > 4);
    try testing.expectEqual(exits.runs, exits.settled);
}
