//! The one definition of a device test case of the PNG decoder: the
//! request that the harness passes to libsan_png_test.so and the result
//! that the library writes back. The library's root and the harness both
//! import this file, so the two sides of the C call share each layout.
//!
//! The library exports one function,
//! `san_png_device_test(request, result)`. It decodes the request's bytes
//! in the request's portions over an accounted heap whose backing is
//! Bionic's malloc, and it fills the result after the decode has released
//! its codec context.

const std = @import("std");
const Decoder = @import("Decoder.zig");
const cases = @import("cases.zig");

/// `Request.cancel_row` when no row sets the cancellation flag.
pub const no_row = std.math.maxInt(u32);

/// `Request.fail_at` when no allocation fails.
pub const no_failure = std.math.maxInt(u64);

/// One decode to run.
pub const Request = extern struct {
    bytes: [*]const u8,
    len: usize,
    plan: std.meta.Tag(cases.Plan),
    /// The seed of a seeded plan, or the offset of a split or prefix
    /// plan. Zero for the others.
    plan_value: u64,
    /// The row whose delivery sets the cancellation flag, or `no_row`.
    cancel_row: u32 = no_row,
    /// The index of the one backing allocation that fails, counted from
    /// zero over the decode, or `no_failure`. Every other allocation
    /// reaches malloc.
    fail_at: u64 = no_failure,
    /// The budget of the decode's heap, in bytes.
    budget: u64,

    /// Returns the request to decode `bytes` in the portions of `plan`.
    pub fn init(bytes: []const u8, plan: cases.Plan, budget: u64) Request {
        return .{
            .bytes = bytes.ptr,
            .len = bytes.len,
            .plan = plan,
            .plan_value = switch (plan) {
                .whole, .bytewise => 0,
                .seeded => |seed| seed,
                .split, .prefix => |at| at,
            },
            .budget = budget,
        };
    }

    /// Returns the plan of the request, or null when its offset lies
    /// beyond its bytes.
    pub fn portions(request: Request) ?cases.Plan {
        return switch (request.plan) {
            .whole => .whole,
            .bytewise => .bytewise,
            .seeded => .{ .seeded = request.plan_value },
            .split => .{ .split = request.offset() orelse return null },
            .prefix => .{ .prefix = request.offset() orelse return null },
        };
    }

    fn offset(request: Request) ?usize {
        if (request.plan_value > request.len) return null;

        return @intCast(request.plan_value);
    }
};

/// The outcome of a decode, by category.
pub const Category = enum(u32) {
    success,
    invalid_content,
    truncated_content,
    unsupported_format,
    /// A sink refused the output that its owner requested. The sink of
    /// the device test refuses none.
    unsupported_operation,
    budget_exceeded,
    allocation_failed,
    canceled,
    engine_failure,
    /// The request was malformed, and nothing ran.
    rejected,

    /// Returns the category of a decode's outcome. The switch names every
    /// error of the decoder, so a new one needs a category here.
    pub fn of(outcome: Decoder.Error!void) Category {
        outcome catch |err| return switch (err) {
            error.InvalidContent => .invalid_content,
            error.TruncatedContent => .truncated_content,
            error.UnsupportedFormat => .unsupported_format,
            error.UnsupportedOperation => .unsupported_operation,
            error.BudgetExceeded => .budget_exceeded,
            error.AllocationFailed => .allocation_failed,
            error.Canceled => .canceled,
            error.EngineFailure => .engine_failure,
        };

        return .success;
    }

    /// Returns the category of a case of the strictness table.
    pub fn expected(case: cases.Case) Category {
        const failure = case.expected orelse return .success;

        return of(failure);
    }
};

/// The image header as IHDR declares it.
pub const Header = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    /// The bytes of one row without its filter byte.
    row_bytes: u64 = 0,
    bit_depth: u8 = 0,
    color_type: u8 = 0,
    channels: u8 = 0,
    interlaced: bool = false,
};

/// What one decode observed.
pub const Result = extern struct {
    category: Category = .rejected,
    /// The adapter's reason, as the backing integer of `Decoder.Reason`.
    reason: i32 = 0,
    /// libpng's warnings, diagnostics and faults alike.
    warnings: u32 = 0,
    /// Optional color metadata drew a warning, so the color fallback
    /// applies.
    color_warning: bool = false,
    /// Whether `header` holds the image header.
    has_header: bool = false,
    header: Header = .{},
    /// The calls of the sink's header and row callbacks.
    headers: u32 = 0,
    rows: u32 = 0,
    /// The callbacks at which the ledger disagreed with the backing, a
    /// refusal of the running call was pending, or a row came out of
    /// order.
    mismatches: u32 = 0,
    /// The CRC-32 of the delivered rows' samples, in order.
    checksum: u32 = 0,
    /// The highest live bytes of the ledger.
    peak: u64 = 0,
    /// After the decode: the live bytes of the ledger, and the blocks
    /// that the backing holds.
    live: u64 = 0,
    blocks: u64 = 0,
    /// The backing allocations of the decode, the refused one included.
    allocations: u64 = 0,
    /// The allocation at `Request.fail_at` was reached and refused.
    injected: bool = false,
    /// After the decode, the ledger counts no block and no reservation,
    /// its peak equals the backing's, and the backing holds no block.
    settled: bool = false,
};
