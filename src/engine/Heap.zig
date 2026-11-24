//! The accounted heap of one engine. Every block starts with a header of
//! 16 bytes that holds the requested size and the kind of the block, so
//! a release without either, such as a codec's, settles exactly. The
//! header keeps the 16-byte alignment that malloc guarantees on both
//! ABIs, and the ledger counts it with the requested bytes.
//!
//! The heap has two views: a std.mem.Allocator for Zig code, and `alloc`
//! and `free` without a size for the allocation callbacks of the codecs.
//! Both admit a block in the ledger before the backing allocates it, and
//! both allocate codec state and workspace. A block of another kind
//! comes from a reservation of that kind.
//! When the heap refuses a block, it records the cause, the budget or the
//! backing, so that a caller who sees only a null pointer or
//! error.OutOfMemory reports the right category.
//!
//! The heap keeps the block of the output lease that ended last, for the
//! next lease of its size: an allocator that returns a block of that size
//! to the system would make every lease fault its pages in again. The
//! kept block stays a live block of a kind of its own. The heap frees it
//! for a lease of another size, when it stands between a request and the
//! budget, a ceiling, or the backing, and when the engine shuts down.

const std = @import("std");
const builtin = @import("builtin");
const Ledger = @import("Ledger.zig");

const Heap = @This();

ledger: Ledger,
backing: Backing,
/// The cause of the latest refusal that no caller has taken. A block that
/// the heap serves later leaves it in place. A caller that maps a failure
/// through it therefore takes it before the work whose failure it maps,
/// and again once that work fails.
refusal: ?Refusal = null,
/// The kept block, by its header, or null.
kept: ?[*]align(header_size) u8 = null,
/// Whether an ended lease leaves its block. An engine that shuts down
/// admits no lease, so it keeps none.
keeps: bool = true,

/// The byte that a debug build writes over a kept block. A copy takes
/// only rows that the lease of the block has covered, so no output holds
/// a row of it, which the tests of the leases rely on.
pub const kept_fill = 0xa5;

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
    kind: Ledger.Kind,
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

/// Returns `size` bytes of codec state or workspace, aligned to 16, that
/// the budget admits directly, or null after it records the cause of the
/// refusal.
pub fn alloc(heap: *Heap, size: usize) ?[*]align(header_size) u8 {
    const bytes = accounted(size) orelse
        return heap.refuse(error.BudgetExceeded);

    var reservation = heap.reserve(.codec, bytes) catch |err|
        return heap.refuse(err);
    defer heap.ledger.cancel(&reservation);

    return heap.allocReserved(&reservation, size);
}

/// Admits `bytes` as a new reservation for blocks of `kind`, as the
/// ledger does. When only the kept block stands between the request and
/// the budget or a ceiling, the heap frees that block first. A refusal
/// that the kept block does not cause leaves it in place. The heap
/// records no refusal here: the caller reports the error.
pub fn reserve(
    heap: *Heap,
    kind: Ledger.Kind,
    bytes: u64,
) error{BudgetExceeded}!Ledger.Reservation {
    return heap.ledger.reserve(kind, bytes) catch |err| {
        if (!heap.ledger.admits(kind, bytes, heap.ledger.usage.kept)) {
            return err;
        }

        heap.evict();

        return heap.ledger.reserve(kind, bytes);
    };
}

/// Returns the kept block as the pixels of a lease of `size` bytes when
/// it has exactly that size, counted as output again. A kept block of
/// another size is freed, so that the lease which follows allocates
/// beside nothing.
pub fn takeKept(heap: *Heap, size: usize) ?[*]align(header_size) u8 {
    const block = heap.kept orelse return null;

    const header = headerOf(block);

    if (header.size != size) {
        heap.evict();

        return null;
    }

    heap.ledger.move(.kept, .output, accounted(size).?);
    header.kind = .output;
    heap.kept = null;

    return block + header_size;
}

/// Ends the use of the pixels of a lease at `ptr`. The heap keeps the
/// block in place of the one that it kept before, or frees it when it
/// keeps none.
pub fn keep(heap: *Heap, ptr: [*]align(header_size) u8) void {
    const block = blockOf(ptr);

    if (!heap.keeps) return heap.release(block);

    heap.evict();

    const header = headerOf(block);

    std.debug.assert(header.kind == .output);

    if (builtin.mode == .debug) @memset(ptr[0..header.size], kept_fill);

    heap.ledger.move(.output, .kept, accounted(header.size).?);
    header.kind = .kept;
    heap.kept = block;
}

/// Frees the kept block, if the heap holds one.
pub fn evict(heap: *Heap) void {
    const block = heap.kept orelse return;

    heap.kept = null;
    heap.release(block);
}

/// Frees the kept block and keeps none from now on.
pub fn stopKeeping(heap: *Heap) void {
    heap.keeps = false;
    heap.evict();
}

/// Returns `size` bytes aligned to 16 from what `reservation` holds, as
/// a block of its kind, or null after it records the cause of the
/// refusal. A block beyond the reservation is refused as BudgetExceeded,
/// and a failed backing leaves the reservation intact. The backing is
/// asked once more after the heap has freed a kept block.
pub fn allocReserved(
    heap: *Heap,
    reservation: *Ledger.Reservation,
    size: usize,
) ?[*]align(header_size) u8 {
    const bytes = accounted(size) orelse
        return heap.refuse(error.BudgetExceeded);

    if (bytes > reservation.bytes) return heap.refuse(error.BudgetExceeded);

    const block = heap.backed(bytes) orelse
        return heap.refuse(error.AllocationFailed);

    heap.ledger.convert(reservation, bytes);
    headerOf(block).* = .{ .size = size, .kind = reservation.kind };

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

/// Returns `count` values of `T` from what `reservation` holds, as
/// `allocReserved` does. A size that overflows is refused as
/// BudgetExceeded. The caller releases the slice by its pointer.
pub fn allocReservedSlice(
    heap: *Heap,
    comptime T: type,
    reservation: *Ledger.Reservation,
    count: usize,
) ?[]T {
    if (comptime @alignOf(T) > header_size) {
        @compileError("the heap aligns its blocks to 16 bytes only");
    }

    const size = std.math.mul(usize, count, @sizeOf(T)) catch {
        heap.refusal = error.BudgetExceeded;

        return null;
    };

    const memory = heap.allocReserved(reservation, size) orelse return null;

    const items: [*]T = @ptrCast(memory);

    return items[0..count];
}

/// Releases the block of `ptr`, which `alloc`, `allocReserved`,
/// `createReserved`, or `allocReservedSlice` returned, by the size in its
/// header. A null `ptr`
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

/// Returns a block of `bytes` from the backing. When the backing has
/// none and the heap keeps a block, the heap frees that block and asks
/// once more.
fn backed(heap: *Heap, bytes: usize) ?[*]align(header_size) u8 {
    const backing = heap.backing;

    if (backing.vtable.alloc(backing.ptr, bytes)) |block| return block;

    if (heap.kept == null) return null;

    heap.evict();

    return backing.vtable.alloc(backing.ptr, bytes);
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
    const header = headerOf(block).*;
    const bytes = accounted(header.size).?;

    heap.backing.vtable.free(heap.backing.ptr, block, bytes);
    heap.ledger.release(header.kind, bytes);
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
    /// The bound of `outstanding`: a block beyond it is not served, as
    /// with a system that has no memory left until a block returns.
    capacity: u64 = std.math.maxInt(u64),

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

        if (len > test_backing.capacity - test_backing.outstanding) return null;

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

/// Checks that the ledger counts exactly what the backing holds. The
/// tests of the codecs share it.
pub fn expectMatches(
    heap: *const Heap,
    test_backing: *const TestBacking,
) !void {
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

    try testing.expectEqual(Ledger.Usage{
        .peak = 4241,
        .peak_committed = 4241,
    }, heap.ledger.usage);

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

    try testing.expectEqual(Ledger.Usage{
        .peak = 100,
        .peak_committed = 100,
    }, heap.ledger.usage);
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

test "a failed backing is recorded as AllocationFailed and holds no bytes" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    var heap: Heap = .init(test_backing.backing(), roomy);

    try testing.expectEqual(null, heap.alloc(64));
    try testing.expectEqual(error.AllocationFailed, heap.takeRefusal().?);

    try testing.expectEqual(
        Ledger.Usage{ .peak_committed = 80 },
        heap.ledger.usage,
    );

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

    var reservation = try heap.ledger.reserve(.codec, 500);
    defer heap.ledger.cancel(&reservation);

    const first = heap.allocReserved(&reservation, 100).?;

    try testing.expectEqual(384, reservation.bytes);

    try testing.expectEqual(
        Ledger.Usage{
            .live = 116,
            .reserved = 384,
            .peak = 116,
            .peak_committed = 500,
        },
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
        Ledger.Usage{
            .live = 1000,
            .reserved = 0,
            .peak = 1000,
            .peak_committed = 1000,
        },
        heap.ledger.usage,
    );

    try expectMatches(&heap, &test_backing);
    heap.free(second);
    heap.free(direct);
    heap.free(first);

    try testing.expectEqual(Ledger.Usage{
        .peak = 1000,
        .peak_committed = 1000,
    }, heap.ledger.usage);
}

test "a failed backing leaves a reservation intact" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });

    var test_backing: TestBacking = .init(failing.allocator());

    var heap: Heap = .init(test_backing.backing(), .{ .bytes = 1000 });

    var reservation = try heap.ledger.reserve(.codec, 500);

    try testing.expectEqual(null, heap.allocReserved(&reservation, 100));
    try testing.expectEqual(error.AllocationFailed, heap.takeRefusal().?);
    try testing.expectEqual(500, reservation.bytes);

    try testing.expectEqual(Ledger.Usage{
        .reserved = 500,
        .peak_committed = 500,
    }, heap.ledger.usage);

    heap.ledger.cancel(&reservation);

    try testing.expectEqual(
        Ledger.Usage{ .peak_committed = 500 },
        heap.ledger.usage,
    );
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

    try testing.expectEqual(
        Ledger.Usage{ .peak_committed = 64 },
        heap.ledger.usage,
    );
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
/// a settled ledger and an empty backing. The tests of the codecs share
/// it.
pub const Exits = struct {
    runs: u32 = 0,
    settled: u32 = 0,

    pub fn record(
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

    var reservation = try heap.ledger.reserve(.codec, 1024);
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

test "a block counts under the kind of its reservation until its release" {
    var test_backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(test_backing.backing(), roomy);

    const kinds = [_]Ledger.Kind{ .input, .metadata, .output, .codec };
    const sizes = [_]usize{ 100, 200, 300, 400 };
    var blocks: [kinds.len + 1][*]align(header_size) u8 = undefined;

    for (kinds, sizes, blocks[0..kinds.len]) |kind, size, *block| {
        var reservation = try heap.ledger.reserve(kind, accounted(size).?);

        block.* = heap.allocReserved(&reservation, size).?;
        try testing.expectEqual(0, reservation.bytes);
        heap.ledger.cancel(&reservation);
    }

    blocks[kinds.len] = heap.alloc(50).?;

    // The two codec blocks count in `live` only.
    try testing.expectEqual(116, heap.ledger.usage.input);
    try testing.expectEqual(216, heap.ledger.usage.metadata);
    try testing.expectEqual(316, heap.ledger.usage.output);
    try testing.expectEqual(1130, heap.ledger.usage.live);
    try testing.expectEqual(0, heap.ledger.usage.reserved);
    try expectMatches(&heap, &test_backing);

    // The block to free, then the live, input, metadata, and output counts
    // that remain.
    const steps = [_]struct { usize, u64, u64, u64, u64 }{
        .{ 2, 814, 116, 216, 0 },
        .{ 4, 748, 116, 216, 0 },
        .{ 0, 632, 0, 216, 0 },
        .{ 3, 216, 0, 216, 0 },
        .{ 1, 0, 0, 0, 0 },
    };

    for (steps) |step| {
        heap.free(blocks[step[0]]);
        try testing.expectEqual(step[1], heap.ledger.usage.live);
        try testing.expectEqual(step[2], heap.ledger.usage.input);
        try testing.expectEqual(step[3], heap.ledger.usage.metadata);
        try testing.expectEqual(step[4], heap.ledger.usage.output);
        try testing.expectEqual(0, heap.ledger.usage.reserved);
    }

    try testing.expectEqual(0, test_backing.blocks);
    try expectMatches(&heap, &test_backing);
}

test "a slice comes from its reservation as one block of its kind" {
    var test_backing: TestBacking = .init(testing.allocator);
    var heap: Heap = .init(test_backing.backing(), roomy);

    var reservation = try heap.ledger.reserve(.metadata, 100);

    const items = heap.allocReservedSlice(u64, &reservation, 5).?;

    // Five values of 8 bytes and one header of 16.
    try testing.expectEqual(5, items.len);
    try testing.expectEqual(56, heap.ledger.usage.metadata);
    try testing.expectEqual(44, reservation.bytes);
    try testing.expectEqual(1, test_backing.blocks);

    for (items, 0..) |*item, index| item.* = index;

    // A slice beyond the reservation, and a size that overflows.
    for ([_]usize{ 4, std.math.maxInt(usize) }) |count| {
        try testing.expectEqual(
            null,
            heap.allocReservedSlice(u64, &reservation, count),
        );

        try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);
        try testing.expectEqual(44, reservation.bytes);
    }

    // An empty slice is a block of its header alone.
    const none = heap.allocReservedSlice(u64, &reservation, 0).?;

    try testing.expectEqual(0, none.len);
    try testing.expectEqual(72, heap.ledger.usage.metadata);
    heap.free(none.ptr);
    heap.free(items.ptr);
    heap.ledger.cancel(&reservation);
    try testing.expectEqual(Ledger.Usage{
        .peak = 72,
        .peak_committed = 100,
    }, heap.ledger.usage);
    try testing.expectEqual(0, test_backing.blocks);
}

/// Returns `size` bytes as the pixels of a lease, as its admission
/// allocates them.
fn leasePixels(heap: *Heap, size: usize) ![*]align(header_size) u8 {
    if (heap.takeKept(size)) |pixels| return pixels;

    var reservation = try heap.reserve(.output, accounted(size).?);
    defer heap.ledger.cancel(&reservation);

    return heap.allocReserved(&reservation, size) orelse
        return heap.takeRefusal().?;
}

test "a lease of the kept size takes the kept block without the backing" {
    var test_backing: TestBacking = .init(testing.allocator);
    var heap: Heap = .init(test_backing.backing(), roomy);
    defer heap.evict();

    const first = try leasePixels(&heap, 400);

    heap.keep(first);

    try testing.expectEqual(Ledger.Usage{
        .live = 416,
        .peak = 416,
        .peak_committed = 416,
        .kept = 416,
    }, heap.ledger.usage);

    try testing.expectEqual(1, test_backing.blocks);

    // A backing that serves nothing more shows that the heap asks for
    // nothing.
    test_backing.capacity = test_backing.outstanding;

    const second = try leasePixels(&heap, 400);

    try testing.expectEqual(first, second);
    try testing.expectEqual(null, heap.kept);
    try testing.expectEqual(null, heap.takeRefusal());

    try testing.expectEqual(Ledger.Usage{
        .live = 416,
        .peak = 416,
        .peak_committed = 416,
        .output = 416,
    }, heap.ledger.usage);

    // The block is output again, so its release settles as output.
    heap.free(second);
    try testing.expectEqual(0, heap.ledger.usage.live);
    try testing.expectEqual(0, test_backing.blocks);
}

test "a lease of another size frees the kept block before its own" {
    var test_backing: TestBacking = .init(testing.allocator);
    var heap: Heap = .init(test_backing.backing(), roomy);
    defer heap.evict();

    heap.keep(try leasePixels(&heap, 400));

    for ([_]usize{ 399, 401 }) |size| {
        heap.ledger.resetPeaks();
        test_backing.peak = test_backing.outstanding;

        const pixels = try leasePixels(&heap, size);

        // The peak holds the larger of the two blocks, never both.
        const larger = @max(416, size + header_size);

        try testing.expectEqual(larger, heap.ledger.usage.peak);
        try testing.expectEqual(larger, test_backing.peak);
        try testing.expectEqual(0, heap.ledger.usage.kept);
        try testing.expectEqual(1, test_backing.blocks);
        heap.free(pixels);
        heap.keep(try leasePixels(&heap, 400));
    }
}

test "a newer block takes the place of the kept one" {
    var test_backing: TestBacking = .init(testing.allocator);
    var heap: Heap = .init(test_backing.backing(), roomy);
    defer heap.evict();

    var reservation = try heap.reserve(.output, 1024);
    defer heap.ledger.cancel(&reservation);

    const older = heap.allocReserved(&reservation, 100).?;
    const newer = heap.allocReserved(&reservation, 200).?;

    heap.keep(older);
    try testing.expectEqual(116, heap.ledger.usage.kept);
    try testing.expectEqual(216, heap.ledger.usage.output);
    heap.keep(newer);
    try testing.expectEqual(216, heap.ledger.usage.kept);
    try testing.expectEqual(0, heap.ledger.usage.output);
    try testing.expectEqual(216, heap.ledger.usage.live);
    try testing.expectEqual(1, test_backing.blocks);
    try testing.expectEqual(newer, heap.kept.? + header_size);
    try expectMatches(&heap, &test_backing);
}

test "a debug build fills the block that it keeps" {
    var test_backing: TestBacking = .init(testing.allocator);
    var heap: Heap = .init(test_backing.backing(), roomy);
    defer heap.evict();

    const pixels = try leasePixels(&heap, 64);

    @memset(pixels[0..64], 0x11);
    heap.keep(pixels);

    const expected: u8 = if (builtin.mode == .debug) kept_fill else 0x11;

    for (pixels[0..64]) |byte| try testing.expectEqual(expected, byte);
}

test "a reservation that only the kept block refuses frees that block" {
    const Case = struct {
        kind: Ledger.Kind,
        ceilings: Ledger.Ceilings = .{},
    };

    // The budget holds the kept block and 100 bytes more. Each case asks
    // for 300: the budget refuses every kind, and the output ceiling
    // refuses the output kind while the budget would admit it.
    const cases = [_]Case{
        .{ .kind = .input },
        .{ .kind = .metadata },
        .{ .kind = .codec },
        .{ .kind = .output },
        .{ .kind = .output, .ceilings = .{ .output = 516 } },
    };

    for (cases, 0..) |case, index| {
        var test_backing: TestBacking = .init(testing.allocator);

        const budget: u64 = if (index == 4) 4096 else 516;

        var heap: Heap = .init(test_backing.backing(), .{ .bytes = budget });

        heap.ledger.ceilings = case.ceilings;
        heap.keep(try leasePixels(&heap, 400));

        var reservation = try heap.reserve(case.kind, 300);

        try testing.expectEqual(null, heap.kept);
        try testing.expectEqual(0, heap.ledger.usage.kept);
        try testing.expectEqual(0, heap.ledger.usage.live);
        try testing.expectEqual(300, heap.ledger.usage.reserved);
        try testing.expectEqual(0, test_backing.blocks);
        try testing.expectEqual(null, heap.takeRefusal());
        heap.ledger.cancel(&reservation);
    }
}

test "a reservation that the kept block does not refuse leaves it kept" {
    var test_backing: TestBacking = .init(testing.allocator);
    var heap: Heap = .init(test_backing.backing(), .{ .bytes = 1000 });
    defer heap.evict();

    heap.ledger.ceilings = .{ .metadata = 200, .output = 600 };
    heap.keep(try leasePixels(&heap, 400));

    // Beyond the budget even without the kept block, beyond the metadata
    // ceiling, which the kept block does not count under, and beyond the
    // output ceiling even without it.
    try testing.expectError(error.BudgetExceeded, heap.reserve(.codec, 1001));
    try testing.expectError(error.BudgetExceeded, heap.reserve(.metadata, 201));
    try testing.expectError(error.BudgetExceeded, heap.reserve(.output, 601));
    try testing.expectEqual(416, heap.ledger.usage.kept);
    try testing.expectEqual(1, test_backing.blocks);

    // The codec view records the refusal that the kept block does not
    // cause, and none for a block that its eviction admits.
    try testing.expectEqual(null, heap.alloc(1000));
    try testing.expectEqual(error.BudgetExceeded, heap.takeRefusal().?);
    try testing.expectEqual(416, heap.ledger.usage.kept);

    const block = heap.alloc(900).?;

    try testing.expectEqual(null, heap.takeRefusal());
    try testing.expectEqual(null, heap.kept);
    try testing.expectEqual(916, heap.ledger.usage.live);
    heap.free(block);
}

test "a backing without a block is asked again after the kept one is freed" {
    var test_backing: TestBacking = .init(testing.allocator);
    var heap: Heap = .init(test_backing.backing(), roomy);

    heap.keep(try leasePixels(&heap, 400));

    // The system holds the kept block and room for 84 bytes more, so a
    // block of 216 fits only in its place.
    test_backing.capacity = 500;

    const block = heap.alloc(200).?;

    try testing.expectEqual(null, heap.takeRefusal());
    try testing.expectEqual(null, heap.kept);
    try testing.expectEqual(216, heap.ledger.usage.live);
    try testing.expectEqual(1, test_backing.blocks);
    try expectMatches(&heap, &test_backing);
    heap.free(block);

    // A block that fits beside the kept one leaves it kept.
    heap.keep(try leasePixels(&heap, 400));

    const small = heap.alloc(64).?;

    try testing.expectEqual(416, heap.ledger.usage.kept);
    heap.free(small);

    // A block that fits in no case fails once the kept one is freed.
    try testing.expectEqual(null, heap.alloc(600));
    try testing.expectEqual(error.AllocationFailed, heap.takeRefusal().?);
    try testing.expectEqual(null, heap.kept);
    try testing.expectEqual(0, heap.ledger.usage.live);
    try testing.expectEqual(0, test_backing.blocks);
}

test "a heap that stopped keeping frees its block and each later one" {
    var test_backing: TestBacking = .init(testing.allocator);
    var heap: Heap = .init(test_backing.backing(), roomy);

    heap.keep(try leasePixels(&heap, 400));

    const held = try leasePixels(&heap, 200);

    heap.stopKeeping();
    try testing.expectEqual(null, heap.kept);
    try testing.expectEqual(216, heap.ledger.usage.live);
    heap.keep(held);
    try testing.expectEqual(null, heap.kept);
    try testing.expectEqual(0, test_backing.blocks);
    try testing.expect(heap.ledger.settled());

    // A repeated stop frees nothing twice.
    heap.stopKeeping();
    try testing.expect(heap.ledger.settled());
}

/// Returns the pixels of a lease, or ends the run of an injected failure
/// as `refused` does.
fn pixelsOrRefused(
    heap: *Heap,
    test_backing: *const TestBacking,
    size: usize,
) ![*]align(header_size) u8 {
    return leasePixels(heap, size) catch |err| {
        try testing.expectEqual(error.AllocationFailed, err);
        try expectMatches(heap, test_backing);

        return error.OutOfMemory;
    };
}

/// Allocates through the routes of the heap beside a kept block, which a
/// failed backing frees before the failure stands, and frees everything.
fn useBesideKept(gpa: std.mem.Allocator, exits: *Exits) !void {
    var test_backing: TestBacking = .init(gpa);

    var heap: Heap = .init(test_backing.backing(), roomy);
    defer exits.record(&heap, &test_backing);
    defer heap.evict();

    heap.keep(try pixelsOrRefused(&heap, &test_backing, 400));

    const raw = heap.alloc(40) orelse try refused(&heap, &test_backing);
    defer heap.free(raw);

    // A lease of another size, then one that takes the kept block.
    heap.keep(try pixelsOrRefused(&heap, &test_backing, 300));

    const pixels = try pixelsOrRefused(&heap, &test_backing, 300);
    defer heap.keep(pixels);

    const again = heap.alloc(40) orelse try refused(&heap, &test_backing);
    defer heap.free(again);
}

test "every allocation failure beside a kept block settles" {
    var exits: Exits = .{};

    try testing.checkAllAllocationFailures(
        testing.allocator,
        useBesideKept,
        .{&exits},
    );

    // The kept block, the two blocks of codec state, and the lease of
    // another size each fail once, beside the run that fails nowhere.
    try testing.expect(exits.runs >= 5);
    try testing.expectEqual(exits.runs, exits.settled);
}
