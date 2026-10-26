//! The root of libsan_png_test.so, the device test library of the PNG
//! decoder. It has the link shape of San's library and one test entry
//! point in place of JNI: san_png_device_test runs one decode that a
//! request describes and writes what it observed into a result.
//!
//! The decode runs the decoder of the San library over an accounted heap
//! whose backing is Bionic's malloc and free, counted so that a request
//! can refuse one chosen allocation and the result can show that the
//! ledger and the backing settle on every path. Every libpng error, every
//! refusal, and every cancellation leaves libpng through the adapter's
//! jump, so the device runs that jump on Bionic.

const std = @import("std");
const engine = @import("engine");
const Decoder = @import("Decoder.zig");
const cases = @import("cases.zig");
const device_case = @import("device_case.zig");

const Heap = engine.Heap;
const Request = device_case.Request;
const Result = device_case.Result;

pub const panic = engine.android_panic;

/// Runs the decode of `request` and writes its outcome to `result`. A
/// request whose offset lies beyond its bytes runs nothing and gives the
/// category `rejected`.
export fn san_png_device_test(request: *const Request, result: *Result) void {
    result.* = run(request.*);
}

fn run(request: Request) Result {
    const plan = request.portions() orelse return .{};

    var backing: Counting = .{ .fail_at = request.fail_at };

    var heap: Heap = .init(backing.backing(), .{ .bytes = request.budget });

    var cancel: std.atomic.Value(bool) = .init(false);

    var sink: Sink = .{
        .heap = &heap,
        .backing = &backing,
        .cancel = &cancel,
        .cancel_row = request.cancel_row,
    };

    var decoder: Decoder = undefined;

    const outcome = decode: {
        decoder.init(&heap, sink.sink(), &cancel) catch |err| break :decode err;

        break :decode cases.feed(&decoder, request.bytes[0..request.len], plan);
    };

    // A terminal outcome has already released the codec context; this
    // releases a context that a failed init left behind.
    decoder.deinit();

    const report = decoder.report();

    var result: Result = .{
        .category = .of(outcome),
        .reason = @backingInt(report.reason),
        .warnings = report.warnings,
        .color_warning = report.color_warning,
        .headers = sink.headers,
        .rows = sink.rows,
        .mismatches = sink.mismatches,
        .checksum = sink.checksum.final(),
        .peak = heap.ledger.usage.peak,
        .live = heap.ledger.usage.live,
        .blocks = backing.blocks,
        .allocations = backing.allocations,
        .injected = backing.injected,
        .settled = heap.ledger.settled() and
            heap.ledger.usage.peak == backing.peak and
            backing.blocks == 0 and backing.outstanding == 0,
    };

    if (decoder.header()) |found| {
        result.has_header = true;
        result.header = .{
            .width = found.width,
            .height = found.height,
            .row_bytes = found.row_bytes,
            .bit_depth = found.bit_depth,
            .color_type = found.color_type,
            .channels = found.channels,
            .interlaced = found.interlaced,
        };
    }

    return result;
}

/// A backing over the system heap that counts its blocks and refuses the
/// one allocation at `fail_at`. Every other allocation reaches Bionic's
/// malloc, so libpng and zlib go on after a refusal that they tolerate,
/// as they would under a real shortage.
const Counting = struct {
    fail_at: u64,
    /// The allocations so far, the refused one included.
    allocations: u64 = 0,
    injected: bool = false,
    /// The bytes of the blocks that the heap holds.
    outstanding: u64 = 0,
    /// The highest `outstanding` so far.
    peak: u64 = 0,
    /// The blocks that the heap holds.
    blocks: u64 = 0,

    const system = Heap.Backing.system;

    fn backing(counting: *Counting) Heap.Backing {
        return .{
            .ptr = counting,
            .vtable = &.{ .alloc = alloc, .free = free },
        };
    }

    fn alloc(ptr: *anyopaque, len: usize) ?[*]align(16) u8 {
        const counting: *Counting = @ptrCast(@alignCast(ptr));
        defer counting.allocations += 1;

        if (counting.allocations == counting.fail_at) {
            counting.injected = true;

            return null;
        }

        const block = system.vtable.alloc(system.ptr, len) orelse return null;

        counting.outstanding += len;
        counting.blocks += 1;
        counting.peak = @max(counting.peak, counting.outstanding);

        return block;
    }

    fn free(ptr: *anyopaque, block: [*]align(16) u8, len: usize) void {
        const counting: *Counting = @ptrCast(@alignCast(ptr));

        system.vtable.free(system.ptr, block, len);
        counting.outstanding -= len;
        counting.blocks -= 1;
    }
};

/// The receiver of the decoded image. It hashes the samples, checks at
/// every callback that the ledger counts exactly what the backing holds,
/// and sets the cancellation flag after the row `cancel_row`.
const Sink = struct {
    heap: *const Heap,
    backing: *const Counting,
    cancel: *std.atomic.Value(bool),
    cancel_row: u32,
    checksum: std.hash.Crc32 = .init(),
    headers: u32 = 0,
    rows: u32 = 0,
    mismatches: u32 = 0,

    fn sink(receiver: *Sink) Decoder.Sink {
        return .{ .ctx = receiver, .header = onHeader, .row = onRow };
    }

    /// Counts a mismatch when the ledger disagrees with the backing, or
    /// when the decoder called the sink while the heap held a refusal of
    /// the running call.
    fn check(receiver: *Sink) void {
        const usage = receiver.heap.ledger.usage;

        const agrees = usage.live == receiver.backing.outstanding and
            usage.peak == receiver.backing.peak;

        if (!agrees or receiver.heap.refusal != null) receiver.mismatches += 1;
    }

    fn onHeader(ctx: *anyopaque, _: Decoder.Header) Decoder.Stop!void {
        const receiver: *Sink = @ptrCast(@alignCast(ctx));

        receiver.headers += 1;
        receiver.check();
    }

    fn onRow(
        ctx: *anyopaque,
        index: u32,
        bytes: []const u8,
    ) Decoder.Stop!void {
        const receiver: *Sink = @ptrCast(@alignCast(ctx));

        if (index != receiver.rows) receiver.mismatches += 1;

        receiver.rows += 1;
        receiver.check();
        receiver.checksum.update(bytes);

        if (index == receiver.cancel_row) receiver.cancel.store(true, .release);
    }
};
