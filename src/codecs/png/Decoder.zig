//! The PNG decoder: libpng's push reader behind San's C containment
//! adapter, over an engine's accounted heap.
//!
//! adapter.h is the one definition of the interface between this file and
//! the adapter; this file reaches it only through the header's
//! translation. A decoder lives in storage that its caller owns and keeps
//! in place, because the adapter's callbacks receive its address as their
//! context.
//!
//! The caller feeds the encoded image in portions of any size and calls
//! finish once its input is complete. Rows reach the sink as they decode.
//! Success is final only at finish, after IEND passed every check and no
//! byte followed it. The decoder delivers the rows of a noninterlaced
//! image; it refuses an interlaced one before any row as
//! UnsupportedFormat.
//!
//! Each call into the adapter maps its outcome in one order: a refusal of
//! the heap during the call, even when libpng tolerated the null and went
//! on; then the cause of a stop verdict that a callback recorded; then
//! the adapter's status. Every terminal outcome destroys the codec context
//! at once, so its memory returns to the heap before the outcome reaches
//! the caller.

const std = @import("std");
const c = @import("adapter");
const Heap = @import("engine").Heap;

const Decoder = @This();

heap: *Heap,
sink: Sink,
/// The cancellation flag of the decode's owner, which another thread may
/// set at any time.
cancel: *const std.atomic.Value(bool),
/// The codec context until a terminal outcome.
codec: ?*c.san_png_decoder = null,
/// The cause of the stop verdict that a callback returned during the
/// current call.
stop: ?Stop = null,
/// The image header, once libpng has read IHDR.
image: ?Header = null,
/// The adapter's records after the latest call.
records: Report = .{},

/// The causes with which a callback stops the decode.
pub const Stop = error{
    /// The owner canceled the decode.
    Canceled,
    /// The sink cannot admit the image or its output within the limits.
    BudgetExceeded,
    /// The decoder or the sink cannot decode this variant of PNG.
    UnsupportedFormat,
};

/// The failures of a decode, by category.
pub const Error = Heap.Refusal || Stop || error{
    /// The input violates the format or San's strictness rules.
    InvalidContent,
    /// The input completed before IEND.
    TruncatedContent,
    /// The codec context could not be set up, or the adapter answered
    /// what this decoder never asks for.
    EngineFailure,
};

/// What a fed portion leaves the decode needing.
pub const Progress = enum {
    /// More input.
    need_input,
    /// Only the end of the input: IEND passed every check.
    ended,
};

/// The receiver of the decoded image. Each callback runs inside a call of
/// the decoder and returns normally; an error stops the decode with that
/// cause.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Runs once, before the first row.
    header: *const fn (ctx: *anyopaque, header: Header) Stop!void,
    /// Runs for each row in order. `bytes` holds the row's samples without
    /// its filter byte, and stays valid only during the call.
    row: *const fn (ctx: *anyopaque, index: u32, bytes: []const u8) Stop!void,
};

/// The image header as IHDR declares it.
pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    interlaced: bool,
    channels: u8,
    /// The bytes of one row without its filter byte.
    row_bytes: u64,

    fn of(record: c.san_png_header) Header {
        return .{
            .width = record.width,
            .height = record.height,
            .bit_depth = record.bit_depth,
            .color_type = record.color_type,
            .interlaced = record.interlace != 0,
            .channels = record.channels,
            .row_bytes = record.row_bytes,
        };
    }
};

/// Why the adapter ended a decode without success, for diagnostics and
/// tests. The category never follows from it.
pub const Reason = enum(i32) {
    none = c.SAN_PNG_REASON_NONE,
    libpng = c.SAN_PNG_REASON_LIBPNG,
    essential = c.SAN_PNG_REASON_ESSENTIAL,
    stream = c.SAN_PNG_REASON_STREAM,
    incomplete = c.SAN_PNG_REASON_INCOMPLETE,
    nonconsecutive = c.SAN_PNG_REASON_NONCONSECUTIVE,
    trailing = c.SAN_PNG_REASON_TRAILING,
    animated = c.SAN_PNG_REASON_ANIMATED,
    stopped = c.SAN_PNG_REASON_STOPPED,
    truncated = c.SAN_PNG_REASON_TRUNCATED,
    geometry = c.SAN_PNG_REASON_GEOMETRY,
    row_order = c.SAN_PNG_REASON_ROW_ORDER,
    palette_index = c.SAN_PNG_REASON_PALETTE_INDEX,
    first_chunk = c.SAN_PNG_REASON_FIRST_CHUNK,
    _,
};

/// The adapter's records of a decode.
pub const Report = struct {
    reason: Reason = .none,
    /// libpng's warnings, diagnostics and faults alike.
    warnings: u32 = 0,
    /// Optional color metadata drew a warning, so the color fallback
    /// applies.
    color_warning: bool = false,

    fn of(record: c.san_png_report) Report {
        return .{
            .reason = @fromBackingInt(@intCast(record.reason)),
            .warnings = record.warnings,
            .color_warning = record.color_warning != 0,
        };
    }
};

/// Sets up a decode in `decoder`, which stays in place until deinit. Its
/// codec context takes its memory from `heap`.
pub fn init(
    decoder: *Decoder,
    heap: *Heap,
    sink: Sink,
    cancel: *const std.atomic.Value(bool),
) Error!void {
    decoder.* = .{ .heap = heap, .sink = sink, .cancel = cancel };

    const hooks: c.san_png_hooks = .{
        .ctx = decoder,
        .alloc = &hookAlloc,
        .free = &hookFree,
        .header = &hookHeader,
        .row = &hookRow,
    };

    decoder.prepare();
    decoder.codec = c.san_png_create(&hooks);
    errdefer decoder.close();

    if (decoder.heap.takeRefusal()) |refusal| return refusal;

    // Without a refusal, a null means that libpng refused its own setup,
    // although the header and the library come from one pin.
    if (decoder.codec == null) return error.EngineFailure;
}

/// Releases the codec context, if a terminal outcome has not already.
/// Repeatable.
pub fn deinit(decoder: *Decoder) void {
    decoder.close();
}

/// Feeds the next portion of the encoded image, which the call only
/// reads. A byte after IEND fails the decode, in this portion or a later
/// one. A failure is terminal.
pub fn feed(decoder: *Decoder, bytes: []const u8) Error!Progress {
    const codec = decoder.live();

    decoder.prepare();

    const status = c.san_png_feed(codec, bytes.ptr, bytes.len);

    return switch (try decoder.settle(status)) {
        .need_input => .need_input,
        .ended => .ended,
        .done => decoder.fail(error.EngineFailure),
    };
}

/// Ends the input. Succeeds only after IEND passed every check; an input
/// that ends before IEND fails as TruncatedContent. The decode is complete
/// either way.
pub fn finish(decoder: *Decoder) Error!void {
    const codec = decoder.live();
    defer decoder.close();

    decoder.prepare();

    switch (try decoder.settle(c.san_png_finish(codec))) {
        .done => {},
        .need_input, .ended => return error.EngineFailure,
    }
}

/// Returns the image header once libpng has read IHDR.
pub fn header(decoder: *const Decoder) ?Header {
    return decoder.image;
}

/// Reports whether optional color metadata drew a warning, so that the
/// image takes the warned color fallback.
pub fn colorFallback(decoder: *const Decoder) bool {
    return decoder.records.color_warning;
}

/// Returns the adapter's records after the latest call.
pub fn report(decoder: *const Decoder) Report {
    return decoder.records;
}

/// Returns the live codec context. A call after a terminal outcome is a
/// bug in San, not an input error.
fn live(decoder: *const Decoder) *c.san_png_decoder {
    return decoder.codec orelse
        @panic("the PNG decoder is called after its terminal outcome");
}

/// Clears the records of an earlier call before the next call into the
/// adapter: a refusal that the heap recorded for other work, and a stop
/// cause.
fn prepare(decoder: *Decoder) void {
    _ = decoder.heap.takeRefusal();
    decoder.stop = null;
}

/// The statuses that end a call without a failure.
const Settled = enum { need_input, ended, done };

/// Maps the status of a call into the adapter, after it reads the
/// adapter's records. A failure destroys the codec context.
fn settle(decoder: *Decoder, status: c.san_png_status) Error!Settled {
    decoder.snapshot();
    errdefer decoder.close();

    if (decoder.heap.takeRefusal()) |refusal| return refusal;
    if (decoder.stop) |cause| return cause;

    return switch (status) {
        c.SAN_PNG_STATUS_NEED_INPUT => .need_input,
        c.SAN_PNG_STATUS_ENDED => .ended,
        c.SAN_PNG_STATUS_DONE => .done,
        c.SAN_PNG_STATUS_TRUNCATED => error.TruncatedContent,
        c.SAN_PNG_STATUS_ANIMATED => error.UnsupportedFormat,
        c.SAN_PNG_STATUS_INVALID => error.InvalidContent,
        // A stop verdict without a recorded cause or refusal, or a status
        // that this decoder never asks for.
        else => error.EngineFailure,
    };
}

/// Reads the adapter's records, and the image header while the decoder
/// has none and the context lives.
fn snapshot(decoder: *Decoder) void {
    const codec = decoder.codec.?;

    var record: c.san_png_report = undefined;

    c.san_png_get_report(codec, &record);
    decoder.records = .of(record);

    if (decoder.image != null) return;

    var found: c.san_png_header = undefined;

    if (c.san_png_get_header(codec, &found) != 0) decoder.image = .of(found);
}

fn fail(decoder: *Decoder, err: Error) Error {
    decoder.close();

    return err;
}

fn close(decoder: *Decoder) void {
    const codec = decoder.codec orelse return;

    decoder.codec = null;
    c.san_png_destroy(codec);
}

/// Records `cause` and returns the stop verdict.
fn stopWith(decoder: *Decoder, cause: Stop) c.san_png_verdict {
    decoder.stop = cause;

    return c.SAN_PNG_STOP;
}

fn owner(ctx: ?*anyopaque) *Decoder {
    return @ptrCast(@alignCast(ctx.?));
}

fn hookAlloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return owner(ctx).heap.alloc(size);
}

fn hookFree(ctx: ?*anyopaque, block: ?*anyopaque) callconv(.c) void {
    owner(ctx).heap.free(block);
}

/// The header callback, at the first IDAT chunk. A refusal that libpng
/// tolerated during this call stops the decode, and the refusal decides
/// its category.
fn hookHeader(
    ctx: ?*anyopaque,
    record: [*c]const c.san_png_header,
) callconv(.c) c.san_png_verdict {
    const decoder = owner(ctx);

    if (decoder.heap.refusal != null) return c.SAN_PNG_STOP;

    const found: Header = .of(record.*);

    decoder.image = found;

    // The decoder delivers noninterlaced rows only.
    if (found.interlaced) return decoder.stopWith(error.UnsupportedFormat);

    decoder.sink.header(decoder.sink.ctx, found) catch |cause|
        return decoder.stopWith(cause);

    return c.SAN_PNG_CONTINUE;
}

/// The row callback. It reads the cancellation flag after the sink
/// returns, so a cancellation stops the decode within one row, through
/// libpng's error path.
fn hookRow(
    ctx: ?*anyopaque,
    index: u32,
    bytes: [*c]const u8,
    len: usize,
) callconv(.c) c.san_png_verdict {
    const decoder = owner(ctx);

    if (decoder.heap.refusal != null) return c.SAN_PNG_STOP;

    decoder.sink.row(decoder.sink.ctx, index, bytes[0..len]) catch |cause|
        return decoder.stopWith(cause);

    if (decoder.cancel.load(.acquire)) return decoder.stopWith(error.Canceled);

    return c.SAN_PNG_CONTINUE;
}

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const cases = @import("cases.zig");
const Ledger = @import("engine").Ledger;
const TestBacking = Heap.TestBacking;

test {
    _ = fixtures;
    _ = cases;
}

/// A budget that admits every decode of the tests below.
const roomy: Ledger.Budget = .{ .bytes = 64 << 20 };

/// A sink that collects the rows of a test decode. At every callback it
/// checks that the ledger counts exactly what the backing holds.
const Collector = struct {
    heap: *const Heap,
    backing: *const TestBacking,
    cancel: *std.atomic.Value(bool),
    /// The row whose delivery sets the cancellation flag.
    cancel_at: ?u32 = null,
    /// The cause with which the header callback stops the decode.
    header_stop: ?Stop = null,
    /// The row after whose delivery the row callback stops the decode as
    /// BudgetExceeded.
    row_stop: ?u32 = null,
    /// The rows' samples, kept outside the heap under test.
    samples: std.ArrayList(u8) = .empty,
    headers: u32 = 0,
    rows: u32 = 0,
    /// The callbacks at which the accounting disagreed, a refusal of the
    /// running call was pending, or a row came out of order.
    mismatches: u32 = 0,

    fn sink(collector: *Collector) Sink {
        return .{ .ctx = collector, .header = onHeader, .row = onRow };
    }

    /// Checks the accounting, and that the decoder stopped instead of
    /// calling the sink while the heap held a refusal of the running call.
    fn check(collector: *Collector) void {
        if (collector.heap.refusal != null) collector.mismatches += 1;

        Heap.expectMatches(collector.heap, collector.backing) catch {
            collector.mismatches += 1;
        };
    }

    fn onHeader(ctx: *anyopaque, _: Header) Stop!void {
        const collector: *Collector = @ptrCast(@alignCast(ctx));

        collector.headers += 1;
        collector.check();

        if (collector.header_stop) |cause| return cause;
    }

    fn onRow(ctx: *anyopaque, index: u32, bytes: []const u8) Stop!void {
        const collector: *Collector = @ptrCast(@alignCast(ctx));

        if (index != collector.rows) collector.mismatches += 1;

        collector.rows += 1;
        collector.check();

        collector.samples.appendSlice(testing.allocator, bytes) catch
            @panic("the test ran out of memory");

        if (collector.cancel_at == index) {
            collector.cancel.store(true, .release);
        }

        if (collector.row_stop == index) return error.BudgetExceeded;
    }
};

/// The options of one test decode.
const Options = struct {
    plan: cases.Plan = .whole,
    budget: Ledger.Budget = roomy,
    cancel_at: ?u32 = null,
    header_stop: ?Stop = null,
    row_stop: ?u32 = null,
    /// The heap holds a refusal of other work when the decode starts.
    stale_refusal: bool = false,
};

/// What one test decode observed.
const Outcome = struct {
    result: Error!void,
    report: Report,
    header: ?Header,
    headers: u32,
    rows: u32,
    /// The rows' samples, which deinit frees.
    samples: []u8,
    /// The highest live bytes of the ledger.
    peak: u64,

    fn deinit(outcome: Outcome) void {
        testing.allocator.free(outcome.samples);
    }
};

/// Decodes `bytes` over a backing that takes its blocks from `gpa`.
/// Checks that the accounting matched at every callback, that the
/// outcome had released the codec context, and that the ledger matches
/// the backing after deinit. Records the exit in `exits`.
fn decodeWith(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
    exits: *Heap.Exits,
) !Outcome {
    var backing: TestBacking = .init(gpa);

    var heap: Heap = .init(backing.backing(), options.budget);

    var cancel: std.atomic.Value(bool) = .init(false);

    var collector: Collector = .{
        .heap = &heap,
        .backing = &backing,
        .cancel = &cancel,
        .cancel_at = options.cancel_at,
        .header_stop = options.header_stop,
        .row_stop = options.row_stop,
    };
    defer collector.samples.deinit(testing.allocator);

    if (options.stale_refusal) {
        try testing.expectEqual(null, heap.alloc(options.budget.bytes));
    }

    var decoder: Decoder = undefined;

    const result = run: {
        decoder.init(&heap, collector.sink(), &cancel) catch |err|
            break :run err;

        break :run cases.feed(&decoder, bytes, options.plan);
    };

    const released = decoder.codec == null;

    decoder.deinit();
    exits.record(&heap, &backing);
    try testing.expect(released);
    try testing.expectEqual(0, collector.mismatches);
    try Heap.expectMatches(&heap, &backing);

    return .{
        .result = result,
        .report = decoder.records,
        .header = decoder.image,
        .headers = collector.headers,
        .rows = collector.rows,
        .samples = try collector.samples.toOwnedSlice(testing.allocator),
        .peak = heap.ledger.usage.peak,
    };
}

/// Decodes `bytes` as decodeWith does over the testing allocator, and
/// checks that the heap settled.
fn decode(bytes: []const u8, options: Options) !Outcome {
    var exits: Heap.Exits = .{};

    const outcome = try decodeWith(testing.allocator, bytes, options, &exits);
    errdefer outcome.deinit();

    try testing.expectEqual(1, exits.settled);

    return outcome;
}

/// Returns the encoded image of `spec`, which the caller frees.
fn encode(spec: fixtures.Spec) ![]u8 {
    return fixtures.encode(testing.allocator, spec);
}

/// Checks that `outcome` delivered exactly the writer's samples of
/// `spec`.
fn expectImage(spec: fixtures.Spec, outcome: Outcome) !void {
    const expected = try fixtures.samples(testing.allocator, spec);
    defer testing.allocator.free(expected);

    try outcome.result;
    try testing.expectEqual(spec.height, outcome.rows);
    try testing.expectEqual(1, outcome.headers);
    try testing.expectEqualSlices(u8, expected, outcome.samples);
}

test "a valid image decodes to the writer's samples in every split" {
    const spec: fixtures.Spec = .{
        .width = 5,
        .height = 4,
        .filters = .cycle,
        .before = &.{
            fixtures.gama,
            fixtures.time,
            cases.short_text,
            fixtures.exif,
        },
        .idat_size = 11,
    };

    const bytes = try encode(spec);
    defer testing.allocator.free(bytes);

    for (cases.plans) |plan| {
        const outcome = try decode(bytes, .{ .plan = plan });
        defer outcome.deinit();

        try expectImage(spec, outcome);
        try testing.expectEqual(Report{}, outcome.report);

        try testing.expectEqual(Header{
            .width = 5,
            .height = 4,
            .bit_depth = 8,
            .color_type = 2,
            .interlaced = false,
            .channels = 3,
            .row_bytes = 15,
        }, outcome.header.?);
    }
}

test "filters 0 to 4 at RGB8 and RGBA8 match the writer's samples" {
    const sizes = [_][2]u32{
        .{ 1, 1 },
        .{ 67, 53 },
        .{ 4096, 2 },
        .{ 2, 4096 },
    };

    const filters = [_]fixtures.Filters{
        .{ .all = .none },
        .{ .all = .sub },
        .{ .all = .up },
        .{ .all = .average },
        .{ .all = .paeth },
        .cycle,
    };

    for (sizes) |size| {
        for ([_]fixtures.Format{ .rgb8, .rgba8 }) |format| {
            for (filters) |filter| {
                for ([_]fixtures.Block{ .stored, .fixed }) |block| {
                    const spec: fixtures.Spec = .{
                        .width = size[0],
                        .height = size[1],
                        .format = format,
                        .filters = filter,
                        .final_block = block,
                    };

                    const bytes = try encode(spec);
                    defer testing.allocator.free(bytes);

                    const outcome = try decode(bytes, .{});
                    defer outcome.deinit();

                    try expectImage(spec, outcome);
                }
            }
        }
    }
}

test "every strictness rule holds in every split of its input" {
    for (cases.strictness) |case| {
        const bytes = try encode(case.spec);
        defer testing.allocator.free(bytes);

        for (cases.plans) |plan| {
            const outcome = try decode(bytes, .{ .plan = plan });
            defer outcome.deinit();

            expectCase(case, outcome) catch |err| {
                std.debug.print("case: {s}; plan: {any}\n", .{
                    case.name,
                    plan,
                });

                return err;
            };
        }
    }
}

fn expectCase(case: cases.Case, outcome: Outcome) !void {
    if (case.expected) |expected| {
        try testing.expectError(expected, outcome.result);
    } else {
        try expectImage(case.spec, outcome);
    }

    try testing.expectEqual(case.reason, outcome.report.reason);
    try testing.expectEqual(case.color_warning, outcome.report.color_warning);
    try testing.expect(outcome.headers <= 1);

    if (case.rowless) try testing.expectEqual(0, outcome.rows);
    if (case.headerless) try testing.expectEqual(0, outcome.headers);

    if (case.warned) {
        try testing.expect(outcome.report.warnings > 0);
    } else if (case.expected == null) {
        try testing.expectEqual(0, outcome.report.warnings);
    }
}

test "every cut before the end of IEND is truncated, every split decodes" {
    const spec: fixtures.Spec = .{
        .width = 3,
        .height = 2,
        .before = &.{ fixtures.gama, cases.short_text },
        .idat_size = 9,
    };

    const bytes = try encode(spec);
    defer testing.allocator.free(bytes);

    for (0..bytes.len + 1) |cut| {
        const truncated = try decode(bytes, .{ .plan = .{ .prefix = cut } });
        defer truncated.deinit();

        const split = try decode(bytes, .{ .plan = .{ .split = cut } });
        defer split.deinit();

        try expectImage(spec, split);

        if (cut == bytes.len) {
            try expectImage(spec, truncated);
        } else {
            try testing.expectError(error.TruncatedContent, truncated.result);
            try testing.expectEqual(Reason.truncated, truncated.report.reason);
        }
    }
}

test "bytes after IEND fail in the same portion and in a later one" {
    const spec: fixtures.Spec = .{ .width = 3, .height = 2 };

    const bytes = try encode(spec);
    defer testing.allocator.free(bytes);

    var backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(backing.backing(), roomy);

    var cancel: std.atomic.Value(bool) = .init(false);

    var collector: Collector = .{
        .heap = &heap,
        .backing = &backing,
        .cancel = &cancel,
    };
    defer collector.samples.deinit(testing.allocator);

    var decoder: Decoder = undefined;

    // An empty portion after IEND is no byte after it.
    try decoder.init(&heap, collector.sink(), &cancel);
    try testing.expectEqual(.ended, try decoder.feed(bytes));
    try testing.expectEqual(.ended, try decoder.feed(&.{}));
    try decoder.finish();
    decoder.deinit();

    try decoder.init(&heap, collector.sink(), &cancel);
    try testing.expectEqual(.ended, try decoder.feed(bytes));
    try testing.expectError(error.InvalidContent, decoder.feed(&.{0}));
    try testing.expectEqual(Reason.trailing, decoder.report().reason);
    try testing.expectEqual(null, decoder.codec);
    decoder.deinit();

    try testing.expectEqual(0, backing.blocks);
    try testing.expectEqual(0, heap.ledger.usage.live);
}

test "a large text chunk costs its length only when the input splits it" {
    const text = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(text);

    const plain_spec: fixtures.Spec = .{ .width = 4, .height = 4 };

    const plain = try encode(plain_spec);
    defer testing.allocator.free(plain);

    const reference = try decode(plain, .{});
    defer reference.deinit();

    // The budget holds the decode of the plain image with less room to
    // spare than the text's length.
    const budget: Ledger.Budget = .{ .bytes = reference.peak + 4096 };

    for ([_][4]u8{ "tEXt".*, "iTXt".* }) |name| {
        const spec: fixtures.Spec = .{
            .width = 4,
            .height = 4,
            .before = &.{.{ .name = name, .data = fixtures.text(text) }},
        };

        const bytes = try encode(spec);
        defer testing.allocator.free(bytes);

        const whole = try decode(bytes, .{ .budget = budget });
        defer whole.deinit();

        // libpng's push reader holds a chunk that spans portions whole in
        // its save buffer, which keeps its size during the image data.
        const middle = fixtures.header_len + 8 + text.len / 2;

        const split = try decode(bytes, .{
            .budget = budget,
            .plan = .{ .split = middle },
        });
        defer split.deinit();

        try expectImage(spec, whole);
        try testing.expectError(error.BudgetExceeded, split.result);
    }
}

test "an axis above libpng's default limit gives a header, not an error" {
    const spec: fixtures.Spec = .{
        .width = 2_000_000,
        .height = 1,
        .format = .gray8,
    };

    const bytes = try encode(spec);
    defer testing.allocator.free(bytes);

    const whole = try decode(bytes, .{});
    defer whole.deinit();

    try expectImage(spec, whole);
}

test "a header alone gives its geometry, then TruncatedContent" {
    const geometries = [_][2]u32{
        .{ 2_000_000, 1 },
        .{ 65_534, 1 },
        .{ 65_535, 1 },
        .{ 65_536, 1 },
        .{ 8_000, 8_000 },
        .{ 1, 64_000_001 },
        .{ 0x7fff_ffff, 0x7fff_ffff },
    };

    for (geometries) |geometry| {
        const bytes = try encode(.{
            .width = geometry[0],
            .height = geometry[1],
            .idat = false,
        });
        defer testing.allocator.free(bytes);

        const outcome = try decode(bytes, .{
            .plan = .{ .prefix = fixtures.header_len },
        });
        defer outcome.deinit();

        const found = outcome.header.?;

        try testing.expectError(error.TruncatedContent, outcome.result);
        try testing.expectEqual(geometry[0], found.width);
        try testing.expectEqual(geometry[1], found.height);
        try testing.expectEqual(3 * @as(u64, geometry[0]), found.row_bytes);
    }
}

/// Returns an image of one row of `width` pixels in `format` whose image
/// data holds only a zlib header, so that libpng reaches the header
/// callback without a row. The caller frees it.
fn wideRow(width: u32, format: fixtures.Format) ![]u8 {
    return encode(.{
        .width = width,
        .height = 1,
        .format = format,
        .idat = false,
        .after = &.{.{ .name = "IDAT".*, .data = &.{ 0x78, 0x01 } }},
    });
}

test "a row beyond zlib's 32-bit count fails before the header callback" {
    // Rows of 2^33 - 4 bytes and of exactly 2^32 - 1 bytes: a row and its
    // filter byte must fit the 32-bit count.
    const rows = [_]struct { u32, fixtures.Format }{
        .{ 0x7fff_ffff, .rgba8 },
        .{ 1_431_655_765, .rgb8 },
    };

    for (rows) |row| {
        const bytes = try wideRow(row[0], row[1]);
        defer testing.allocator.free(bytes);

        const outcome = try decode(bytes, .{});
        defer outcome.deinit();

        try testing.expectError(error.InvalidContent, outcome.result);
        try testing.expectEqual(Reason.geometry, outcome.report.reason);
        try testing.expectEqual(0, outcome.headers);
    }
}

test "a row of 2^32 - 4 bytes passes the guard and meets the budget" {
    const bytes = try wideRow(1_431_655_764, .rgb8);
    defer testing.allocator.free(bytes);

    const outcome = try decode(bytes, .{});
    defer outcome.deinit();

    // libpng's row buffer of 4 GiB exceeds the budget after the header
    // callback, and png_malloc raises an error on the refusal.
    try testing.expectError(error.BudgetExceeded, outcome.result);
    try testing.expectEqual(Reason.libpng, outcome.report.reason);
    try testing.expectEqual(1, outcome.headers);
    try testing.expectEqual(4_294_967_292, outcome.header.?.row_bytes);
}

/// Decodes `bytes` with the plan `plan` over `gpa`, which
/// std.testing.checkAllAllocationFailures makes fail at one allocation.
/// An injected failure must end the decode as AllocationFailed.
fn injectOnce(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    plan: cases.Plan,
    exits: *Heap.Exits,
) !void {
    const outcome = try decodeWith(gpa, bytes, .{ .plan = plan }, exits);
    defer outcome.deinit();

    outcome.result catch |err| switch (err) {
        error.AllocationFailed => return error.OutOfMemory,
        else => return err,
    };
}

test "every allocation failure in libpng and zlib fails and settles" {
    const bytes = try encode(cases.small);
    defer testing.allocator.free(bytes);

    for ([_]cases.Plan{ .whole, .bytewise }) |plan| {
        var exits: Heap.Exits = .{};

        try testing.checkAllAllocationFailures(
            testing.allocator,
            injectOnce,
            .{ bytes, plan, &exits },
        );

        // The decoder object, libpng's structs, its chunk list, both eXIf
        // buffers, both row buffers, and zlib's state and window, each
        // failed once, and a run without a failure.
        try testing.expect(exits.runs > 10);
        try testing.expectEqual(exits.runs, exits.settled);
    }
}

/// An allocator that refuses exactly one allocation, the one at
/// `fail_at`, and serves every other from the testing allocator.
/// std.testing.FailingAllocator refuses every allocation after its first
/// failure, so it never shows libpng going on after a refusal that it
/// tolerates.
const FailOnce = struct {
    fail_at: usize,
    /// The allocations so far, the refused one included.
    index: usize = 0,
    failed: bool = false,

    fn allocator(fail_once: *FailOnce) std.mem.Allocator {
        return .{
            .ptr = fail_once,
            .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = free,
            },
        };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const fail_once: *FailOnce = @ptrCast(@alignCast(ctx));
        defer fail_once.index += 1;

        if (fail_once.index == fail_once.fail_at) {
            fail_once.failed = true;

            return null;
        }

        return testing.allocator.rawAlloc(len, alignment, return_address);
    }

    fn free(
        _: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        testing.allocator.rawFree(memory, alignment, return_address);
    }
};

test "one refused allocation fails the decode even when libpng goes on" {
    const bytes = try encode(cases.small);
    defer testing.allocator.free(bytes);

    for (cases.plans) |plan| {
        var exits: Heap.Exits = .{};

        var counting: FailOnce = .{ .fail_at = std.math.maxInt(usize) };

        const reference = try decodeWith(
            counting.allocator(),
            bytes,
            .{ .plan = plan },
            &exits,
        );
        defer reference.deinit();

        try expectImage(cases.small, reference);

        // The runs in which libpng warned about a chunk that it could not
        // allocate, so it went on after the refusal.
        var warned: u32 = 0;

        for (0..counting.index) |at| {
            var fail_once: FailOnce = .{ .fail_at = at };

            const outcome = try decodeWith(
                fail_once.allocator(),
                bytes,
                .{ .plan = plan },
                &exits,
            );
            defer outcome.deinit();

            try testing.expect(fail_once.failed);
            try testing.expectError(error.AllocationFailed, outcome.result);

            if (outcome.report.warnings != 0) warned += 1;
        }

        try testing.expect(warned != 0);
        try testing.expectEqual(counting.index + 1, exits.runs);
        try testing.expectEqual(exits.runs, exits.settled);
    }
}

test "every budget below the decode's peak fails and settles" {
    const bytes = try encode(cases.small);
    defer testing.allocator.free(bytes);

    for ([_]cases.Plan{ .whole, .bytewise }) |plan| {
        const reference = try decode(bytes, .{ .plan = plan });
        defer reference.deinit();

        try reference.result;

        var budget: u64 = 1;

        while (budget <= reference.peak) : (budget += 1) {
            const outcome = try decode(bytes, .{
                .plan = plan,
                .budget = .{ .bytes = budget },
            });
            defer outcome.deinit();

            if (budget < reference.peak) {
                try testing.expectError(error.BudgetExceeded, outcome.result);
            } else {
                try expectImage(cases.small, outcome);
            }
        }
    }
}

test "a refusal recorded before the decode does not fail it" {
    const bytes = try encode(cases.small);
    defer testing.allocator.free(bytes);

    const outcome = try decode(bytes, .{ .stale_refusal = true });
    defer outcome.deinit();

    try expectImage(cases.small, outcome);
}

test "a cancellation stops the decode within one row" {
    const spec: fixtures.Spec = .{ .width = 3, .height = 7 };

    const bytes = try encode(spec);
    defer testing.allocator.free(bytes);

    for ([_]cases.Plan{ .whole, .bytewise }) |plan| {
        for ([_]u32{ 0, 3, 6 }) |row| {
            const outcome = try decode(bytes, .{
                .plan = plan,
                .cancel_at = row,
            });
            defer outcome.deinit();

            try testing.expectError(error.Canceled, outcome.result);
            try testing.expectEqual(row + 1, outcome.rows);
            try testing.expectEqual(Reason.stopped, outcome.report.reason);
        }
    }
}

test "a stop verdict of the sink ends the decode with its cause" {
    const bytes = try encode(cases.small);
    defer testing.allocator.free(bytes);

    const at_header = try decode(bytes, .{
        .header_stop = error.BudgetExceeded,
    });
    defer at_header.deinit();

    try testing.expectError(error.BudgetExceeded, at_header.result);
    try testing.expectEqual(0, at_header.rows);

    const at_row = try decode(bytes, .{ .row_stop = 1 });
    defer at_row.deinit();

    try testing.expectError(error.BudgetExceeded, at_row.result);
    try testing.expectEqual(2, at_row.rows);
}

test "the settle check catches a block that a decode leaves behind" {
    const bytes = try encode(cases.small);
    defer testing.allocator.free(bytes);

    var exits: Heap.Exits = .{};

    const clean = try decodeWith(testing.allocator, bytes, .{}, &exits);
    defer clean.deinit();

    var backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(backing.backing(), roomy);

    var cancel: std.atomic.Value(bool) = .init(false);

    var collector: Collector = .{
        .heap = &heap,
        .backing = &backing,
        .cancel = &cancel,
    };
    defer collector.samples.deinit(testing.allocator);

    var decoder: Decoder = undefined;

    try decoder.init(&heap, collector.sink(), &cancel);
    try cases.feed(&decoder, bytes, .whole);
    decoder.deinit();

    const leaked = heap.alloc(8).?;

    exits.record(&heap, &backing);
    heap.free(leaked);
    try testing.expectEqual(2, exits.runs);
    try testing.expectEqual(1, exits.settled);
}

test "deinit before any input releases the codec context once" {
    var backing: TestBacking = .init(testing.allocator);

    var heap: Heap = .init(backing.backing(), roomy);

    var cancel: std.atomic.Value(bool) = .init(false);

    var collector: Collector = .{
        .heap = &heap,
        .backing = &backing,
        .cancel = &cancel,
    };
    defer collector.samples.deinit(testing.allocator);

    var decoder: Decoder = undefined;

    try decoder.init(&heap, collector.sink(), &cancel);
    try testing.expect(heap.ledger.usage.live > 0);
    decoder.deinit();
    decoder.deinit();
    try testing.expectEqual(0, heap.ledger.usage.live);
    try testing.expectEqual(0, backing.blocks);
}
