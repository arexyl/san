//! The port between a job and the codec that decodes its content.
//!
//! The engine drives a codec through this interface and names none:
//! whoever creates an engine passes the opener of its codec, as it
//! passes the backing of its heap. A codec adapter implements the
//! interface over its library, and the tests of the engine implement it
//! with a script, so the engine builds and runs without any codec.
//!
//! A codec delivers its image through the target of its job, inside the
//! calls of this interface: the image once, before the first row, and
//! then each row in order. The target admits the image or refuses it,
//! and the codec ends a refused decode with the cause of the refusal.
//!
//! A codec reads untrusted bytes. It validates what it delivers before
//! it calls the target: an image has both axes of at least 1, a row has
//! the length that its layout gives the image width, and no row follows
//! the last one.

const std = @import("std");
const Heap = @import("Heap.zig");

const Codec = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// Decodes the next portion of the encoded image, which the call
    /// only reads. A failure is the terminal outcome of the decode, and
    /// so is a satisfied demand.
    feed: *const fn (ptr: *anyopaque, bytes: []const u8) Error!Demand,
    /// Ends the input. Succeeds only when the image is complete and
    /// every check of the codec passed.
    finish: *const fn (ptr: *anyopaque) Error!void,
    /// Releases the codec with every block that it holds. The engine
    /// calls it once, after any outcome of the calls above.
    destroy: *const fn (ptr: *anyopaque) void,
};

/// The source of the codecs of an engine.
pub const Opener = struct {
    ptr: *anyopaque,
    /// Opens a codec for one decode. It allocates through `heap` only,
    /// delivers to `target`, and observes `cancel` at its observation
    /// points. A failure keeps nothing.
    open: *const fn (
        ptr: *anyopaque,
        heap: *Heap,
        target: Target,
        cancel: Cancel,
    ) Error!Codec,
};

/// The causes with which a target refuses an image: its limits or its
/// lease do not fit, or the allocation of the lease failed.
pub const Refusal = Heap.Refusal || error{
    /// The engine does not support the output that the job requests of
    /// this image.
    UnsupportedOperation,
};

/// The failures of a decode, by category.
pub const Error = Refusal || error{
    /// The codec observed the cancellation flag.
    Canceled,
    /// The codec decodes no image of this variant of its format.
    UnsupportedFormat,
    /// The input violates its format or San's strictness rules.
    InvalidContent,
    /// The input completed before the image did.
    TruncatedContent,
    /// The codec could not set up its context, or its library answered
    /// what the codec never asks for.
    EngineFailure,
};

/// The receiver of a decoded image. Each callback runs inside a call of
/// the codec and returns normally.
pub const Target = struct {
    ctx: *anyopaque,
    /// Runs once, before the first row. An error stops the decode.
    admit: *const fn (ctx: *anyopaque, image: Image) Refusal!void,
    /// Runs for each row of an admitted image, in order. `samples` holds
    /// the row in the layout of the image and stays valid only during
    /// the call. It returns whether the target wants the rows after it.
    row: *const fn (ctx: *anyopaque, index: u32, samples: []const u8) Demand,
};

/// Whether a decode goes on: a target answers it for the rows after the
/// one that it took, and a codec for the bytes after a portion.
pub const Demand = enum {
    more,
    /// The target has every row of its output. The codec delivers no
    /// row after that one and reads no byte after it, so the rest of the
    /// input stays unchecked, and only `destroy` may follow. A
    /// cancellation that the codec observes at that row comes first.
    satisfied,
};

/// An image as its codec describes it, with both axes at least 1. An
/// axis fits the 31 bits of a coordinate of the ABI, so the arithmetic of
/// the output grid stays within 64 bits, and a codec refuses a larger
/// image itself.
pub const Image = struct {
    width: u31,
    height: u31,
    layout: Layout,
};

/// The samples of one row as a codec delivers them.
pub const Layout = enum {
    /// R, G, and B, one byte each, without padding.
    rgb8,

    /// Returns the bytes of one pixel.
    pub fn pixelBytes(layout: Layout) usize {
        return switch (layout) {
            .rgb8 => 3,
        };
    }
};

/// The cancellation flag of a job: the bits of `mask` in a word that
/// holds other state of the job beside them. Another thread may set the
/// flag at any time, and a codec only reads the word.
pub const Cancel = struct {
    word: *const std.atomic.Value(u64),
    mask: u64,

    /// Reports whether the cancellation is requested. The acquire pairs
    /// with the release of the request.
    pub fn requested(cancel: Cancel) bool {
        return cancel.word.load(.acquire) & cancel.mask != 0;
    }
};

const testing = std.testing;

/// A codec for the tests of the engine module, which decodes a script:
/// each byte of its input is a command, and the command that describes
/// the image carries both axes behind it. The script reaches the codec
/// through the feeds of its content, so a test places each portion.
///
/// Like a codec adapter, it holds its state and one row of workspace in
/// the heap of its engine, observes the cancellation flag after each
/// row, and fails a byte after the end of its image.
pub const Scripted = struct {
    heap: *Heap,
    target: Target,
    cancel: Cancel,
    hooks: *const Hooks,
    /// The bytes of an image command that the portions delivered so far.
    pending: [image_command_bytes]u8 = undefined,
    pending_len: usize = 0,
    image: ?Image = null,
    /// The workspace of one row, once the target admitted the image.
    workspace: ?[]u8 = null,
    rows: u32 = 0,
    ended: bool = false,
    /// The target was satisfied, so the decode is over.
    satisfied: bool = false,

    pub const Command = enum(u8) {
        /// Describes the image: the width and the height follow, each
        /// as four bytes, little-endian.
        image = 'I',
        /// Delivers the next row.
        row = 'R',
        /// Ends the image, which needs every row before it.
        end = 'E',
        /// Fails the decode as InvalidContent.
        invalid = 'X',
        /// Ends the image wherever it stands, as a codec with a defect
        /// would: before the image or before its last row.
        cut = 'C',
        _,
    };

    const image_command_bytes = 9;

    /// What a test observes inside a call of the codec.
    pub const Hooks = struct {
        ctx: ?*anyopaque = null,
        /// Runs after the target took a row and before the codec
        /// observes the cancellation flag.
        after_row: ?*const fn (ctx: ?*anyopaque, index: u32) void = null,
        /// Runs before the codec fails as InvalidContent, where it
        /// observes no flag.
        before_invalid: ?*const fn (ctx: ?*anyopaque) void = null,
    };

    const no_hooks: Hooks = .{};

    /// The opener of a codec without hooks.
    pub const opener: Opener = .{
        .ptr = @constCast(&no_hooks),
        .open = open,
    };

    /// Returns the opener of codecs that call `hooks`.
    pub fn openerWith(hooks: *const Hooks) Opener {
        return .{ .ptr = @constCast(hooks), .open = open };
    }

    /// Returns the command that describes an image of `width` by
    /// `height` pixels. A test that joins commands into one script calls
    /// it at compile time.
    pub fn imageCommand(width: u32, height: u32) [image_command_bytes]u8 {
        var command: [image_command_bytes]u8 = undefined;

        command[0] = @backingInt(Command.image);
        std.mem.writeInt(u32, command[1..5], width, .little);
        std.mem.writeInt(u32, command[5..9], height, .little);

        return command;
    }

    /// Returns the sample at the byte `offset` of the row `index`.
    pub fn sample(index: u32, offset: usize) u8 {
        return @truncate(@as(usize, index) *% 31 +% offset *% 7 +% 1);
    }

    fn open(
        ptr: *anyopaque,
        heap: *Heap,
        target: Target,
        cancel: Cancel,
    ) Error!Codec {
        // A refusal that an earlier call left would name the wrong cause.
        _ = heap.takeRefusal();

        const memory = heap.alloc(@sizeOf(Scripted)) orelse
            return heap.takeRefusal() orelse error.EngineFailure;

        const scripted: *Scripted = @ptrCast(memory);

        scripted.* = .{
            .heap = heap,
            .target = target,
            .cancel = cancel,
            .hooks = @ptrCast(@alignCast(ptr)),
        };

        return .{ .ptr = scripted, .vtable = &vtable };
    }

    const vtable: VTable = .{
        .feed = feed,
        .finish = finish,
        .destroy = destroy,
    };

    fn feed(ptr: *anyopaque, bytes: []const u8) Error!Demand {
        const scripted: *Scripted = @ptrCast(@alignCast(ptr));

        scripted.expectLive();

        // A satisfied target ends the decode at its row, so the commands
        // after it stay unread.
        for (bytes) |byte| {
            if (try scripted.take(byte) == .satisfied) return .satisfied;
        }

        return .more;
    }

    fn finish(ptr: *anyopaque) Error!void {
        const scripted: *Scripted = @ptrCast(@alignCast(ptr));

        scripted.expectLive();

        if (!scripted.ended) return error.TruncatedContent;
    }

    fn destroy(ptr: *anyopaque) void {
        const scripted: *Scripted = @ptrCast(@alignCast(ptr));
        const heap = scripted.heap;

        if (scripted.workspace) |workspace| heap.free(workspace.ptr);

        heap.free(scripted);
    }

    fn take(scripted: *Scripted, byte: u8) Error!Demand {
        if (scripted.ended) return error.InvalidContent;

        const command: Command = @fromBackingInt(byte);

        if (scripted.pending_len != 0 or command == .image) {
            scripted.pending[scripted.pending_len] = byte;
            scripted.pending_len += 1;

            if (scripted.pending_len < image_command_bytes) return .more;

            scripted.pending_len = 0;
            try scripted.describe();

            return .more;
        }

        switch (command) {
            .image => unreachable,
            .row => return scripted.deliver(),
            .end => {
                const image = scripted.image orelse
                    return error.InvalidContent;

                if (scripted.rows != image.height) return error.InvalidContent;

                scripted.ended = true;
            },
            .invalid => {
                if (scripted.hooks.before_invalid) |before_invalid| {
                    before_invalid(scripted.hooks.ctx);
                }

                return error.InvalidContent;
            },
            .cut => scripted.ended = true,
            _ => return error.InvalidContent,
        }

        return .more;
    }

    /// Delivers the image of the pending command and takes the
    /// workspace of one row.
    fn describe(scripted: *Scripted) Error!void {
        if (scripted.image != null) return error.InvalidContent;

        const width = std.mem.readInt(u32, scripted.pending[1..5], .little);
        const height = std.mem.readInt(u32, scripted.pending[5..9], .little);

        if (width == 0 or height == 0) return error.InvalidContent;

        const image: Image = .{
            .width = std.math.cast(u31, width) orelse
                return error.InvalidContent,
            .height = std.math.cast(u31, height) orelse
                return error.InvalidContent,
            .layout = .rgb8,
        };

        scripted.image = image;

        try scripted.target.admit(scripted.target.ctx, image);

        const row_bytes = @as(usize, image.width) * image.layout.pixelBytes();

        _ = scripted.heap.takeRefusal();

        const workspace = scripted.heap.alloc(row_bytes) orelse
            return scripted.heap.takeRefusal() orelse error.EngineFailure;

        scripted.workspace = workspace[0..row_bytes];
    }

    fn deliver(scripted: *Scripted) Error!Demand {
        const image = scripted.image orelse return error.InvalidContent;
        const workspace = scripted.workspace orelse return error.InvalidContent;

        if (scripted.rows == image.height) return error.InvalidContent;

        const index = scripted.rows;

        for (workspace, 0..) |*byte, offset| byte.* = sample(index, offset);

        const demand =
            scripted.target.row(scripted.target.ctx, index, workspace);

        scripted.rows += 1;

        if (scripted.hooks.after_row) |after_row| {
            after_row(scripted.hooks.ctx, index);
        }

        if (scripted.cancel.requested()) return error.Canceled;

        scripted.satisfied = demand == .satisfied;

        return demand;
    }

    /// A call other than `destroy` after a satisfied demand is a bug in
    /// San, which a real codec answers the same way.
    fn expectLive(scripted: *const Scripted) void {
        if (scripted.satisfied) {
            @panic("the scripted codec is called after a satisfied demand");
        }
    }
};

/// A target that records what a scripted codec delivers.
const Recorder = struct {
    images: u32 = 0,
    image: ?Image = null,
    rows: u32 = 0,
    /// The cause with which the recorder refuses the image.
    refusal: ?Refusal = null,
    /// Whether every row arrived in order with the samples of its index.
    intact: bool = true,
    /// The count of rows after which the recorder is satisfied.
    enough: ?u32 = null,

    fn target(recorder: *Recorder) Target {
        return .{ .ctx = recorder, .admit = admit, .row = row };
    }

    fn admit(ctx: *anyopaque, image: Image) Refusal!void {
        const recorder: *Recorder = @ptrCast(@alignCast(ctx));

        recorder.images += 1;
        recorder.image = image;

        if (recorder.refusal) |refusal| return refusal;
    }

    fn row(ctx: *anyopaque, index: u32, samples: []const u8) Demand {
        const recorder: *Recorder = @ptrCast(@alignCast(ctx));
        const image = recorder.image.?;

        const expected_len = image.width * image.layout.pixelBytes();

        if (index != recorder.rows or samples.len != expected_len) {
            recorder.intact = false;
        }

        for (samples, 0..) |byte, offset| {
            if (byte != Scripted.sample(index, offset)) recorder.intact = false;
        }

        recorder.rows += 1;

        return if (recorder.rows == recorder.enough) .satisfied else .more;
    }
};

/// A scripted codec in a test, over a heap of its own.
const Bench = struct {
    backing: Heap.TestBacking,
    heap: Heap,
    word: std.atomic.Value(u64) = .init(other_bits),
    recorder: Recorder = .{},
    codec: Codec = undefined,

    /// The cancellation flag of the bench's word, and bits beside it,
    /// set from the start, that must not cancel a decode.
    const flag_bit: u64 = 1 << 40;
    const other_bits: u64 = ~flag_bit;

    /// Opens the codec of `bench`, which stays in place.
    fn start(bench: *Bench, source: Opener) !void {
        bench.* = .{
            .backing = .init(testing.allocator),
            .heap = undefined,
        };

        bench.heap = .init(bench.backing.backing(), .{ .bytes = 1 << 20 });

        bench.codec = try source.open(
            source.ptr,
            &bench.heap,
            bench.recorder.target(),
            .{ .word = &bench.word, .mask = flag_bit },
        );
    }

    /// Feeds a portion that leaves the target wanting more.
    fn feed(bench: *Bench, bytes: []const u8) !void {
        try testing.expectEqual(.more, try bench.demand(bytes));
    }

    fn demand(bench: *Bench, bytes: []const u8) Error!Demand {
        return bench.codec.vtable.feed(bench.codec.ptr, bytes);
    }

    fn finish(bench: *Bench) Error!void {
        return bench.codec.vtable.finish(bench.codec.ptr);
    }

    /// Destroys the codec and checks that it leaves no block.
    fn stop(bench: *Bench) !void {
        bench.codec.vtable.destroy(bench.codec.ptr);

        try testing.expectEqual(0, bench.backing.blocks);
        try testing.expect(bench.heap.ledger.settled());
    }
};

const row_command = [_]u8{@backingInt(Scripted.Command.row)};
const end_command = [_]u8{@backingInt(Scripted.Command.end)};
const invalid_command = [_]u8{@backingInt(Scripted.Command.invalid)};

test "a script delivers its image once and then each row in order" {
    var bench: Bench = undefined;

    try bench.start(Scripted.opener);

    const script = comptime Scripted.imageCommand(3, 2) ++ row_command ++
        row_command ++ end_command;

    try bench.feed(&script);
    try bench.finish();

    try testing.expectEqual(1, bench.recorder.images);

    try testing.expectEqual(
        Image{ .width = 3, .height = 2, .layout = .rgb8 },
        bench.recorder.image,
    );

    try testing.expectEqual(2, bench.recorder.rows);
    try testing.expect(bench.recorder.intact);
    try bench.stop();
}

test "a script decodes the same whatever its portions" {
    const script = comptime Scripted.imageCommand(2, 3) ++ row_command ++
        row_command ++ row_command ++ end_command;

    var bench: Bench = undefined;

    try bench.start(Scripted.opener);

    for (script) |byte| try bench.feed(&.{byte});

    try bench.finish();

    try testing.expectEqual(3, bench.recorder.rows);
    try testing.expect(bench.recorder.intact);
    try bench.stop();
}

test "an input that ends before its image fails as TruncatedContent" {
    var bench: Bench = undefined;

    try bench.start(Scripted.opener);

    try bench.feed(&(comptime Scripted.imageCommand(1, 2) ++ row_command));
    try testing.expectError(error.TruncatedContent, bench.finish());
    try bench.stop();
}

test "a script that breaks its format fails as InvalidContent" {
    const image = comptime Scripted.imageCommand(1, 1);

    const scripts = comptime [_][]const u8{
        // A row before the image, and an end before it.
        &row_command,
        &end_command,
        // A second image, an end before the last row, a row after it,
        // and a byte after the end.
        &(image ++ image),
        &(image ++ end_command),
        &(image ++ row_command ++ row_command),
        &(image ++ row_command ++ end_command ++ row_command),
        // An image without an axis, and one beyond 31 bits.
        &Scripted.imageCommand(0, 1),
        &Scripted.imageCommand(1, 0),
        &Scripted.imageCommand(1 << 31, 1),
        &Scripted.imageCommand(1, 1 << 31),
        &invalid_command,
        &.{0},
    };

    for (scripts) |script| {
        var bench: Bench = undefined;

        try bench.start(Scripted.opener);

        try testing.expectError(error.InvalidContent, bench.feed(script));
        try bench.stop();
    }
}

test "a refusal of the target ends the decode with its cause" {
    const refusals = [_]Refusal{
        error.BudgetExceeded,
        error.AllocationFailed,
        error.UnsupportedOperation,
    };

    for (refusals) |refusal| {
        var bench: Bench = undefined;

        try bench.start(Scripted.opener);

        bench.recorder.refusal = refusal;

        const script = Scripted.imageCommand(4, 4);

        try testing.expectError(refusal, bench.feed(&script));
        try testing.expectEqual(0, bench.recorder.rows);
        try bench.stop();
    }
}

test "a codec observes only the flag of its mask, after each row" {
    const Canceling = struct {
        word: *std.atomic.Value(u64),
        at: u32,

        fn afterRow(ctx: ?*anyopaque, index: u32) void {
            const canceling: *@This() = @ptrCast(@alignCast(ctx.?));

            if (index == canceling.at) {
                _ = canceling.word.fetchOr(Bench.flag_bit, .release);
            }
        }
    };

    var bench: Bench = undefined;

    var canceling: Canceling = .{ .word = &bench.word, .at = 1 };

    const hooks: Scripted.Hooks = .{
        .ctx = &canceling,
        .after_row = Canceling.afterRow,
    };

    try bench.start(Scripted.openerWith(&hooks));

    const script = comptime Scripted.imageCommand(1, 4) ++ row_command ++
        row_command ++ row_command;

    // The bits beside the flag are set from the start, and the decode
    // runs until the hook sets the flag.
    try testing.expectError(error.Canceled, bench.feed(&script));
    try testing.expectEqual(2, bench.recorder.rows);
    try bench.stop();
}

test "a satisfied target ends the decode at its row" {
    var bench: Bench = undefined;

    try bench.start(Scripted.opener);
    bench.recorder.enough = 2;

    // The commands after the second row stay unread: a third row, and
    // one that would fail the decode.
    const script = comptime Scripted.imageCommand(3, 4) ++ row_command ++
        row_command ++ row_command ++ invalid_command;

    try testing.expectEqual(.satisfied, try bench.demand(&script));
    try testing.expectEqual(2, bench.recorder.rows);
    try testing.expect(bench.recorder.intact);
    try bench.stop();
}

test "a cancellation at the row that satisfies the target comes first" {
    var bench: Bench = undefined;

    try bench.start(Scripted.opener);
    bench.recorder.enough = 1;
    _ = bench.word.fetchOr(Bench.flag_bit, .release);

    const script = comptime Scripted.imageCommand(1, 2) ++ row_command;

    try testing.expectError(error.Canceled, bench.demand(&script));
    try testing.expectEqual(1, bench.recorder.rows);
    try bench.stop();
}

test "a failed allocation of the codec fails its opening or its image" {
    // The state of the codec, then the workspace of its row.
    for (0..2) |fail_index| {
        var bench: Bench = undefined;

        bench.backing = .init(testing.allocator);

        var failing: testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });

        bench.backing.gpa = failing.allocator();
        bench.heap = .init(bench.backing.backing(), .{ .bytes = 1 << 20 });
        bench.recorder = .{};
        bench.word = .init(0);

        const opened = Scripted.opener.open(
            Scripted.opener.ptr,
            &bench.heap,
            bench.recorder.target(),
            .{ .word = &bench.word, .mask = Bench.flag_bit },
        );

        if (fail_index == 0) {
            try testing.expectError(error.AllocationFailed, opened);
        } else {
            bench.codec = try opened;

            const script = Scripted.imageCommand(4, 4);

            try testing.expectError(
                error.AllocationFailed,
                bench.feed(&script),
            );

            bench.codec.vtable.destroy(bench.codec.ptr);
        }

        try testing.expectEqual(0, bench.backing.blocks);
        try testing.expect(bench.heap.ledger.settled());
    }
}
