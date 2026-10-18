//! The accounting ledger of one engine: its aggregate budget, the live
//! and peak bytes of its blocks, and the bytes that reservations hold
//! for admitted work. Every count is in bytes and includes the header of
//! each block.
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
usage: Usage = .{},

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

/// The counts of a ledger.
pub const Usage = struct {
    /// The bytes of the live blocks.
    live: u64 = 0,
    /// The bytes that reservations hold and no block uses yet.
    reserved: u64 = 0,
    /// The highest `live` so far.
    peak: u64 = 0,
};

/// Bytes that the budget admitted for work before the work allocates
/// them. Its owner converts them into blocks or cancels them.
pub const Reservation = struct {
    /// The admitted bytes that no block uses yet.
    bytes: u64,
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

/// Admits `bytes` as a new reservation. A request beyond the available
/// bytes fails as BudgetExceeded and changes nothing.
pub fn reserve(
    ledger: *Ledger,
    bytes: u64,
) error{BudgetExceeded}!Reservation {
    if (bytes > ledger.available()) return error.BudgetExceeded;

    ledger.usage.reserved += bytes;

    return .{ .bytes = bytes };
}

/// Converts `bytes` of `reservation` into live bytes, for a block that
/// exists now. The reservation holds at least `bytes`.
pub fn convert(ledger: *Ledger, reservation: *Reservation, bytes: u64) void {
    reservation.bytes -= bytes;
    ledger.usage.reserved -= bytes;
    ledger.usage.live += bytes;
    ledger.usage.peak = @max(ledger.usage.peak, ledger.usage.live);
}

/// Returns what remains of `reservation` to the budget. Cancelling a
/// converted or empty reservation changes nothing.
pub fn cancel(ledger: *Ledger, reservation: *Reservation) void {
    ledger.usage.reserved -= reservation.bytes;
    reservation.bytes = 0;
}

/// Releases `bytes` of live blocks that no longer exist.
pub fn release(ledger: *Ledger, bytes: u64) void {
    ledger.usage.live -= bytes;
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

    var reservation = try ledger.reserve(600);

    try testing.expectEqual(600, reservation.bytes);
    try testing.expectEqual(Usage{ .reserved = 600 }, ledger.usage);
    try testing.expectEqual(400, ledger.available());
    try testing.expectError(error.BudgetExceeded, ledger.reserve(401));
    try testing.expectEqual(Usage{ .reserved = 600 }, ledger.usage);

    var rest = try ledger.reserve(400);

    try testing.expectEqual(0, ledger.available());
    try testing.expectError(error.BudgetExceeded, ledger.reserve(1));
    ledger.cancel(&rest);
    ledger.cancel(&reservation);
    try testing.expectEqual(Usage{}, ledger.usage);
    try testing.expectEqual(1000, ledger.available());
}

test "a converted reservation is never counted twice" {
    var ledger: Ledger = .init(try .init(1000));

    var reservation = try ledger.reserve(500);

    ledger.convert(&reservation, 200);
    try testing.expectEqual(300, reservation.bytes);

    try testing.expectEqual(
        Usage{ .live = 200, .reserved = 300, .peak = 200 },
        ledger.usage,
    );

    try testing.expectEqual(500, ledger.available());
    ledger.convert(&reservation, 300);
    try testing.expectEqual(0, reservation.bytes);

    try testing.expectEqual(
        Usage{ .live = 500, .reserved = 0, .peak = 500 },
        ledger.usage,
    );

    try testing.expectEqual(500, ledger.available());
    ledger.cancel(&reservation);
    ledger.release(500);
    try testing.expectEqual(Usage{ .peak = 500 }, ledger.usage);
}

test "cancelling returns only what remains of a reservation" {
    var ledger: Ledger = .init(try .init(1000));

    var reservation = try ledger.reserve(500);

    ledger.convert(&reservation, 120);
    ledger.cancel(&reservation);
    try testing.expectEqual(0, reservation.bytes);

    try testing.expectEqual(
        Usage{ .live = 120, .reserved = 0, .peak = 120 },
        ledger.usage,
    );

    ledger.cancel(&reservation);
    try testing.expectEqual(880, ledger.available());
}

test "a ledger is settled once no block and no reservation remain" {
    var ledger: Ledger = .init(try .init(1000));

    try testing.expect(ledger.settled());

    var reservation = try ledger.reserve(500);

    try testing.expect(!ledger.settled());
    ledger.convert(&reservation, 200);
    ledger.cancel(&reservation);
    try testing.expect(!ledger.settled());
    ledger.release(200);
    try testing.expect(ledger.settled());
    try testing.expectEqual(200, ledger.usage.peak);
}

test "the peak follows the highest live count" {
    var ledger: Ledger = .init(try .init(100));

    var first = try ledger.reserve(60);

    ledger.convert(&first, 60);
    ledger.release(60);

    var second = try ledger.reserve(30);

    ledger.convert(&second, 30);

    try testing.expectEqual(
        Usage{ .live = 30, .reserved = 0, .peak = 60 },
        ledger.usage,
    );

    var third = try ledger.reserve(70);

    ledger.convert(&third, 70);

    try testing.expectEqual(
        Usage{ .live = 100, .reserved = 0, .peak = 100 },
        ledger.usage,
    );
}

test "the largest budget admits all of its bytes without overflow" {
    const largest: u64 = std.math.maxInt(i64);

    var ledger: Ledger = .init(try .init(std.math.maxInt(i64)));

    try testing.expectError(
        error.BudgetExceeded,
        ledger.reserve(std.math.maxInt(u64)),
    );

    var reservation = try ledger.reserve(largest);

    try testing.expectEqual(0, ledger.available());
    ledger.convert(&reservation, largest);
    try testing.expectError(error.BudgetExceeded, ledger.reserve(1));
    try testing.expectEqual(largest, ledger.usage.peak);
}
