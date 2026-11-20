//! The packing of San's handles. A handle is an opaque 64-bit value to
//! its caller, and its lowest byte holds the kind, so one comparison on
//! the bits alone rejects a handle of another kind.
//!
//! A handle of a slot, a content's or a job's, holds the index of the slot
//! and the generation of its issuance. The generations of a process come
//! from one serial that only rises, so a generation is issued once in a
//! process, and a handle that an earlier engine issued matches no slot
//! of a later one.

const std = @import("std");

/// The kind of a handle. Zero is no kind, so zero is never a handle.
pub const Tag = enum(u8) {
    engine = 1,
    content = 2,
    job = 3,
    _,
};

/// The serial of one issuance in the process. Zero is never issued.
pub const Generation = u40;

/// The index of a slot in the table of its kind.
pub const Index = u16;

/// The packing of the handle of a slot.
pub const Slotted = packed struct(u64) {
    tag: Tag,
    index: Index,
    generation: Generation,
};

/// The source of the generations of a process. One engine lives at a
/// time and its caller serializes its calls, so the serial has one
/// writer: the live engine, or the engine slot between two engines.
pub const Serial = struct {
    /// The generation of the next issuance.
    next: Generation = 1,

    /// Reports whether the serial has retired: it issues no generation
    /// again, so that none ever repeats.
    pub fn retired(serial: Serial) bool {
        return serial.next == std.math.maxInt(Generation);
    }

    /// Returns the generation of one issuance. The serial has not
    /// retired.
    pub fn take(serial: *Serial) Generation {
        std.debug.assert(!serial.retired());

        defer serial.next += 1;

        return serial.next;
    }
};

const testing = std.testing;

test "a slot handle holds its kind in the lowest byte" {
    const packed_handle: Slotted = .{
        .tag = .content,
        .index = 0x1234,
        .generation = 0xab_cdef_0123,
    };

    const bits: u64 = @bitCast(packed_handle);

    try testing.expectEqual(0xabcd_ef01_2312_3402, bits);
    try testing.expectEqual(packed_handle, @as(Slotted, @bitCast(bits)));
    try testing.expectEqual(@backingInt(Tag.content), bits & 0xff);
}

test "the serial issues each generation once and never zero" {
    var serial: Serial = .{};

    try testing.expectEqual(1, serial.take());
    try testing.expectEqual(2, serial.take());
    try testing.expect(!serial.retired());
}

test "the serial retires before its generation wraps" {
    const last = std.math.maxInt(Generation);

    var serial: Serial = .{ .next = last - 1 };

    try testing.expectEqual(last - 1, serial.take());
    try testing.expect(serial.retired());
    try testing.expectEqual(last, serial.next);
}
