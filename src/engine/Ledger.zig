//! The accounting ledger of one engine: its aggregate budget, the live
//! and peak bytes of its blocks, the live bytes of each kind of block,
//! and the bytes that reservations hold for admitted work. Every count
//! is in bytes and includes the header of each block.
//!
//! Admission happens before allocation. A reservation takes bytes from
//! the budget before any block exists, and a block converts reserved
//! bytes into live bytes, so the ledger never counts the same bytes
//! twice. The owner of a reservation cancels what remains of it on every
//! completion path. The ledger takes no lock: the caller serializes every
//! call on one engine.

const std = @import("std");

const Ledger = @This();

/// The bound of `usage.live` and `usage.reserved` together.
budget: Budget,
ceilings: Ceilings = .{},
usage: Usage = .{},
/// The part of `usage.reserved` in reservations of the metadata kind.
reserved_metadata: u64 = 0,
/// The part of `usage.reserved` in reservations of the output kind.
reserved_output: u64 = 0,

/// The bounds of single kinds within the budget. A ledger without an
/// engine, such as a codec test's, has none.
pub const Ceilings = struct {
    /// The bound of the live and the reserved metadata bytes together.
    metadata: u64 = std.math.maxInt(u64),
    /// The bound of the live and the reserved output bytes together.
    output: u64 = std.math.maxInt(u64),
};

/// An aggregate budget in bytes that admits at least one byte.
pub const Budget = struct {
    bytes: u64,

    /// Validates the aggregate budget of the engine limits. A budget that
    /// admits nothing, zero or negative, fails as BudgetExceeded.
    pub fn init(bytes: i64) error{BudgetExceeded}!Budget {
        if (bytes <= 0) return error.BudgetExceeded;

        return .{ .bytes = @intCast(bytes) };
    }
};

/// What a block holds. The ledger counts the live bytes of the first
/// four kinds, and the rest of the live bytes is the last one.
pub const Kind = enum {
    /// The input staging of a content.
    input,
    /// Native metadata and bookkeeping.
    metadata,
    /// An output lease or a conversion intermediate.
    output,
    /// The block of an ended output lease that the heap keeps for the
    /// next one. No reservation has this kind: a block only moves to it
    /// from the output kind and back.
    kept,
    /// Codec state and workspace.
    codec,
};

/// The counts of a ledger.
pub const Usage = struct {
    /// The bytes of the live blocks.
    live: u64 = 0,
    /// The bytes that reservations hold and no block uses yet.
    reserved: u64 = 0,
    /// The highest `live` since the start or the last peak reset.
    peak: u64 = 0,
    /// The highest `live` and `reserved` together since then.
    peak_committed: u64 = 0,
    /// The part of `live` in blocks of the input kind.
    input: u64 = 0,
    /// The part of `live` in blocks of the metadata kind.
    metadata: u64 = 0,
    /// The part of `live` in blocks of the output kind.
    output: u64 = 0,
    /// The part of `live` in the block of the kept kind.
    kept: u64 = 0,
};

/// Bytes that the budget admitted for work before the work allocates
/// them. Its owner converts them into blocks or cancels them.
pub const Reservation = struct {
    /// The admitted bytes that no block uses yet.
    bytes: u64,
    /// The kind of every block that the reservation becomes.
    kind: Kind,
};

pub fn init(budget: Budget) Ledger {
    return .{ .budget = budget };
}

/// Returns the bytes that the budget still admits.
pub fn available(ledger: *const Ledger) u64 {
    return ledger.budget.bytes - ledger.usage.live - ledger.usage.reserved;
}

/// Reports whether the ledger counts no live block and no reservation.
pub fn settled(ledger: *const Ledger) bool {
    return ledger.usage.live == 0 and ledger.usage.reserved == 0;
}

/// Admits `bytes` as a new reservation for blocks of `kind`. A request
/// beyond the available bytes, or beyond the ceiling of its kind, fails
/// as BudgetExceeded and changes nothing.
pub fn reserve(
    ledger: *Ledger,
    kind: Kind,
    bytes: u64,
) error{BudgetExceeded}!Reservation {
    // A block only moves to the kept kind, so no reservation becomes one.
    std.debug.assert(kind != .kept);

    if (!ledger.admits(kind, bytes, 0)) return error.BudgetExceeded;

    if (ledger.boundOf(kind)) |bound| bound.reserved.* += bytes;

    const usage = &ledger.usage;

    usage.reserved += bytes;

    usage.peak_committed = @max(
        usage.peak_committed,
        usage.live + usage.reserved,
    );

    return .{ .bytes = bytes, .kind = kind };
}

/// Reports whether the budget and the ceiling of `kind` admit `bytes`
/// more once `freed` bytes of the kept kind are released. The ledger
/// counts at least `freed` kept bytes.
pub fn admits(ledger: *Ledger, kind: Kind, bytes: u64, freed: u64) bool {
    std.debug.assert(freed <= ledger.usage.kept);

    if (bytes > ledger.available() + freed) return false;

    const bound = ledger.boundOf(kind) orelse return true;

    // Kept bytes count under the output ceiling alone.
    const relief = if (kind == .output) freed else 0;
    const held = bound.live + bound.reserved.* - relief;

    // The sum stays within the ceiling, so the difference holds.
    return bytes <= bound.ceiling - held;
}

/// Counts `bytes` of live blocks of the kind `from` under the kind `to`,
/// for a block that changes its kind and stays.
pub fn move(ledger: *Ledger, from: Kind, to: Kind, bytes: u64) void {
    if (ledger.countOf(from)) |count| count.* -= bytes;
    if (ledger.countOf(to)) |count| count.* += bytes;
}

/// Converts `bytes` of `reservation` into live bytes, for a block of its
/// kind that exists now. The reservation holds at least `bytes`.
pub fn convert(ledger: *Ledger, reservation: *Reservation, bytes: u64) void {
    reservation.bytes -= bytes;
    ledger.usage.reserved -= bytes;
    ledger.usage.live += bytes;
    ledger.usage.peak = @max(ledger.usage.peak, ledger.usage.live);

    if (ledger.countOf(reservation.kind)) |count| count.* += bytes;
    if (ledger.boundOf(reservation.kind)) |bound| bound.reserved.* -= bytes;
}

/// Returns what remains of `reservation` to the budget. Cancelling a
/// converted or empty reservation changes nothing.
pub fn cancel(ledger: *Ledger, reservation: *Reservation) void {
    ledger.usage.reserved -= reservation.bytes;

    if (ledger.boundOf(reservation.kind)) |bound| {
        bound.reserved.* -= reservation.bytes;
    }

    reservation.bytes = 0;
}

/// Releases `bytes` of live blocks of `kind` that no longer exist.
pub fn release(ledger: *Ledger, kind: Kind, bytes: u64) void {
    ledger.usage.live -= bytes;

    if (ledger.countOf(kind)) |count| count.* -= bytes;
}

/// Starts both peaks again at the current counts.
pub fn resetPeaks(ledger: *Ledger) void {
    ledger.usage.peak = ledger.usage.live;
    ledger.usage.peak_committed = ledger.usage.live + ledger.usage.reserved;
}

/// Returns the count of the live bytes of `kind`, or null for the kind
/// that the ledger counts only as the rest of the live bytes.
fn countOf(ledger: *Ledger, kind: Kind) ?*u64 {
    return switch (kind) {
        .input => &ledger.usage.input,
        .metadata => &ledger.usage.metadata,
        .output => &ledger.usage.output,
        .kept => &ledger.usage.kept,
        .codec => null,
    };
}

/// A kind that has a ceiling: the ceiling, the live bytes that count
/// under it, and the count of its reserved bytes.
const Bound = struct {
    ceiling: u64,
    live: u64,
    reserved: *u64,
};

/// Returns the bound of `kind`, or null for a kind that only the budget
/// bounds.
fn boundOf(ledger: *Ledger, kind: Kind) ?Bound {
    return switch (kind) {
        .metadata => .{
            .ceiling = ledger.ceilings.metadata,
            .live = ledger.usage.metadata,
            .reserved = &ledger.reserved_metadata,
        },
        // A kept block is output memory that waits, so it counts under
        // the ceiling of output until a lease takes it or the heap frees
        // it.
        .output => .{
            .ceiling = ledger.ceilings.output,
            .live = ledger.usage.output + ledger.usage.kept,
            .reserved = &ledger.reserved_output,
        },
        .input, .kept, .codec => null,
    };
}

const testing = std.testing;

test "a budget that admits nothing fails as BudgetExceeded" {
    const rejected = [_]i64{ 0, -1, std.math.minInt(i64) };

    for (rejected) |bytes| {
        try testing.expectError(error.BudgetExceeded, Budget.init(bytes));
    }

    const smallest: Budget = try .init(1);

    const largest: Budget = try .init(std.math.maxInt(i64));

    try testing.expectEqual(1, smallest.bytes);
    try testing.expectEqual(std.math.maxInt(i64), largest.bytes);
}

test "a reservation takes bytes from the budget before any block" {
    var ledger: Ledger = .init(try .init(1000));

    var reservation = try ledger.reserve(.codec, 600);

    const held: Usage = .{ .reserved = 600, .peak_committed = 600 };

    try testing.expectEqual(600, reservation.bytes);
    try testing.expectEqual(held, ledger.usage);
    try testing.expectEqual(400, ledger.available());
    try testing.expectError(error.BudgetExceeded, ledger.reserve(.codec, 401));
    try testing.expectEqual(held, ledger.usage);

    var rest = try ledger.reserve(.codec, 400);

    try testing.expectEqual(0, ledger.available());
    try testing.expectError(error.BudgetExceeded, ledger.reserve(.codec, 1));
    ledger.cancel(&rest);
    ledger.cancel(&reservation);
    try testing.expectEqual(Usage{ .peak_committed = 1000 }, ledger.usage);
    try testing.expectEqual(1000, ledger.available());
}

test "a converted reservation is never counted twice" {
    var ledger: Ledger = .init(try .init(1000));

    var reservation = try ledger.reserve(.codec, 500);

    ledger.convert(&reservation, 200);
    try testing.expectEqual(300, reservation.bytes);

    try testing.expectEqual(Usage{
        .live = 200,
        .reserved = 300,
        .peak = 200,
        .peak_committed = 500,
    }, ledger.usage);

    try testing.expectEqual(500, ledger.available());
    ledger.convert(&reservation, 300);
    try testing.expectEqual(0, reservation.bytes);

    try testing.expectEqual(
        Usage{ .live = 500, .peak = 500, .peak_committed = 500 },
        ledger.usage,
    );

    try testing.expectEqual(500, ledger.available());
    ledger.cancel(&reservation);
    ledger.release(.codec, 500);

    try testing.expectEqual(
        Usage{ .peak = 500, .peak_committed = 500 },
        ledger.usage,
    );
}

test "cancelling returns only what remains of a reservation" {
    var ledger: Ledger = .init(try .init(1000));

    var reservation = try ledger.reserve(.codec, 500);

    ledger.convert(&reservation, 120);
    ledger.cancel(&reservation);
    try testing.expectEqual(0, reservation.bytes);

    try testing.expectEqual(
        Usage{ .live = 120, .peak = 120, .peak_committed = 500 },
        ledger.usage,
    );

    ledger.cancel(&reservation);
    try testing.expectEqual(880, ledger.available());
}

test "a ledger is settled once no block and no reservation remain" {
    var ledger: Ledger = .init(try .init(1000));

    try testing.expect(ledger.settled());

    var reservation = try ledger.reserve(.codec, 500);

    try testing.expect(!ledger.settled());
    ledger.convert(&reservation, 200);
    ledger.cancel(&reservation);
    try testing.expect(!ledger.settled());
    ledger.release(.codec, 200);
    try testing.expect(ledger.settled());
    try testing.expectEqual(200, ledger.usage.peak);
}

test "the peak follows the highest live count" {
    var ledger: Ledger = .init(try .init(100));

    var first = try ledger.reserve(.codec, 60);

    ledger.convert(&first, 60);
    ledger.release(.codec, 60);

    var second = try ledger.reserve(.codec, 30);

    ledger.convert(&second, 30);

    try testing.expectEqual(
        Usage{ .live = 30, .peak = 60, .peak_committed = 60 },
        ledger.usage,
    );

    var third = try ledger.reserve(.codec, 70);

    ledger.convert(&third, 70);

    try testing.expectEqual(
        Usage{ .live = 100, .peak = 100, .peak_committed = 100 },
        ledger.usage,
    );
}

test "the committed peak follows live and reserved bytes together" {
    var ledger: Ledger = .init(try .init(1000));

    var first = try ledger.reserve(.codec, 400);

    ledger.convert(&first, 100);

    var second = try ledger.reserve(.codec, 500);

    // 100 live and 800 reserved, of which no block exists.
    try testing.expectEqual(100, ledger.usage.peak);
    try testing.expectEqual(900, ledger.usage.peak_committed);

    ledger.cancel(&second);
    ledger.convert(&first, 300);
    try testing.expectEqual(400, ledger.usage.peak);
    try testing.expectEqual(900, ledger.usage.peak_committed);
    ledger.release(.codec, 400);
}

test "a peak reset starts both peaks at the current counts" {
    var ledger: Ledger = .init(try .init(1000));

    var gone = try ledger.reserve(.codec, 700);

    ledger.convert(&gone, 700);
    ledger.release(.codec, 700);

    var held = try ledger.reserve(.codec, 300);

    ledger.convert(&held, 100);
    ledger.resetPeaks();

    try testing.expectEqual(Usage{
        .live = 100,
        .reserved = 200,
        .peak = 100,
        .peak_committed = 300,
    }, ledger.usage);

    // A reset changes no count, so the ledger settles as before.
    ledger.cancel(&held);
    ledger.release(.codec, 100);
    ledger.resetPeaks();
    try testing.expectEqual(Usage{}, ledger.usage);
    try testing.expect(ledger.settled());
}

test "the metadata ceiling bounds live and reserved metadata together" {
    var ledger: Ledger = .init(try .init(1000));

    ledger.ceilings = .{ .metadata = 100 };

    var first = try ledger.reserve(.metadata, 60);

    ledger.convert(&first, 40);

    // 40 live and 20 reserved leave 40 under the ceiling.
    const before = ledger.usage;

    try testing.expectError(
        error.BudgetExceeded,
        ledger.reserve(.metadata, 41),
    );

    try testing.expectEqual(before, ledger.usage);
    try testing.expectEqual(20, ledger.reserved_metadata);

    var second = try ledger.reserve(.metadata, 40);

    try testing.expectError(error.BudgetExceeded, ledger.reserve(.metadata, 1));

    // Every other kind takes from the budget alone.
    var other = try ledger.reserve(.codec, 400);
    var input = try ledger.reserve(.input, 400);

    try testing.expectEqual(60, ledger.reserved_metadata);
    ledger.cancel(&other);
    ledger.cancel(&input);

    // A cancellation and a release each return their room.
    ledger.cancel(&second);

    var third = try ledger.reserve(.metadata, 40);

    ledger.cancel(&third);
    ledger.cancel(&first);
    ledger.release(.metadata, 40);

    var whole = try ledger.reserve(.metadata, 100);

    try testing.expectError(error.BudgetExceeded, ledger.reserve(.metadata, 1));
    ledger.cancel(&whole);
    try testing.expectEqual(0, ledger.reserved_metadata);
    try testing.expect(ledger.settled());
}

test "the output ceiling bounds live and reserved output together" {
    var ledger: Ledger = .init(try .init(1000));

    ledger.ceilings = .{ .output = 100 };

    var first = try ledger.reserve(.output, 60);

    ledger.convert(&first, 40);

    // 40 live and 20 reserved leave 40 under the ceiling.
    const before = ledger.usage;

    try testing.expectError(error.BudgetExceeded, ledger.reserve(.output, 41));
    try testing.expectEqual(before, ledger.usage);
    try testing.expectEqual(20, ledger.reserved_output);

    var second = try ledger.reserve(.output, 40);

    try testing.expectError(error.BudgetExceeded, ledger.reserve(.output, 1));

    // The ceiling of one kind leaves the other kinds to the budget.
    var metadata = try ledger.reserve(.metadata, 400);

    try testing.expectEqual(60, ledger.reserved_output);
    try testing.expectEqual(400, ledger.reserved_metadata);
    ledger.cancel(&metadata);

    // A cancellation and a release each return their room.
    ledger.cancel(&second);
    ledger.cancel(&first);
    ledger.release(.output, 40);

    var whole = try ledger.reserve(.output, 100);

    try testing.expectError(error.BudgetExceeded, ledger.reserve(.output, 1));
    ledger.cancel(&whole);
    try testing.expectEqual(0, ledger.reserved_output);
    try testing.expect(ledger.settled());
}

test "a ledger without ceilings admits each kind up to its budget" {
    inline for (.{ Kind.metadata, Kind.output }) |kind| {
        var ledger: Ledger = .init(try .init(1000));

        var whole = try ledger.reserve(kind, 1000);

        try testing.expectError(error.BudgetExceeded, ledger.reserve(kind, 1));
        ledger.convert(&whole, 1000);
        try testing.expectEqual(0, ledger.reserved_metadata);
        try testing.expectEqual(0, ledger.reserved_output);
        ledger.release(kind, 1000);
        try testing.expect(ledger.settled());
    }
}

test "each kind counts its own live bytes, and codec bytes are the rest" {
    var ledger: Ledger = .init(try .init(1000));

    const sizes = [_]struct { Kind, u64 }{
        .{ .input, 10 },
        .{ .metadata, 20 },
        .{ .output, 40 },
        .{ .codec, 80 },
    };

    for (sizes) |pair| {
        const before = ledger.usage;

        var reservation = try ledger.reserve(pair[0], pair[1] + 1);

        // A reservation counts under no kind before a block exists.
        try testing.expectEqual(before.live, ledger.usage.live);
        try testing.expectEqual(before.input, ledger.usage.input);
        try testing.expectEqual(before.metadata, ledger.usage.metadata);
        try testing.expectEqual(before.output, ledger.usage.output);
        ledger.convert(&reservation, pair[1]);
        ledger.cancel(&reservation);
    }

    try testing.expectEqual(Usage{
        .live = 150,
        .peak = 150,
        .peak_committed = 151,
        .input = 10,
        .metadata = 20,
        .output = 40,
    }, ledger.usage);

    for (sizes) |pair| ledger.release(pair[0], pair[1]);

    try testing.expectEqual(
        Usage{ .peak = 150, .peak_committed = 151 },
        ledger.usage,
    );
}

test "the largest budget admits all of its bytes without overflow" {
    const largest: u64 = std.math.maxInt(i64);

    var ledger: Ledger = .init(try .init(std.math.maxInt(i64)));

    try testing.expectError(
        error.BudgetExceeded,
        ledger.reserve(.codec, std.math.maxInt(u64)),
    );

    var reservation = try ledger.reserve(.codec, largest);

    try testing.expectEqual(0, ledger.available());
    ledger.convert(&reservation, largest);
    try testing.expectError(error.BudgetExceeded, ledger.reserve(.codec, 1));
    try testing.expectEqual(largest, ledger.usage.peak);
}

test "a kept block counts as live bytes under the ceiling of output" {
    var ledger: Ledger = .init(try .init(1000));

    ledger.ceilings = .{ .metadata = 300, .output = 500 };

    var reservation = try ledger.reserve(.output, 400);

    ledger.convert(&reservation, 400);
    ledger.move(.output, .kept, 400);

    try testing.expectEqual(Usage{
        .live = 400,
        .peak = 400,
        .peak_committed = 400,
        .kept = 400,
    }, ledger.usage);

    // The ceiling of output leaves 100 bytes beside the kept block, and
    // the budget 600.
    try testing.expectError(error.BudgetExceeded, ledger.reserve(.output, 101));
    try testing.expectError(error.BudgetExceeded, ledger.reserve(.codec, 601));
    try testing.expect(!ledger.admits(.output, 101, 0));
    try testing.expect(!ledger.admits(.codec, 601, 0));

    // Without the block, each kind has what the block took from it, and
    // the ceiling of metadata has what it had.
    try testing.expect(ledger.admits(.output, 500, 400));
    try testing.expect(!ledger.admits(.output, 501, 400));
    try testing.expect(ledger.admits(.codec, 1000, 400));
    try testing.expect(!ledger.admits(.codec, 1001, 400));
    try testing.expect(ledger.admits(.metadata, 300, 400));
    try testing.expect(!ledger.admits(.metadata, 301, 400));
    try testing.expect(!ledger.admits(.metadata, 301, 0));

    // The block returns to output, and its release settles the ledger.
    ledger.move(.kept, .output, 400);
    try testing.expectEqual(400, ledger.usage.output);
    try testing.expectEqual(0, ledger.usage.kept);
    ledger.release(.output, 400);
    try testing.expect(ledger.settled());
}
