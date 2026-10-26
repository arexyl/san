//! San's panic handler for its Android artifacts. A root file selects it
//! with `pub const panic = @import("engine").android_panic;`.
//!
//! A failed safety check is a bug in San, not an input error, so it
//! never becomes a status. The handler passes a fixed message to Bionic's
//! android_set_abort_message, so that the message reaches the tombstone,
//! and then calls abort, so that the system's crash handler records the
//! backtrace. It is the same in every build mode. It formats no value
//! into the message, so no image content or other user data can reach
//! the tombstone, and it references none of the standard library's
//! stack-trace and printing machinery: without libc, that machinery
//! reaches the kernel through raw system calls.

/// The longest message that the handler passes on. A longer message is
/// cut, so the handler needs no allocation.
const max_message = 255;

/// Bionic's functions of the handler. San's libraries compile without
/// libc, so each libc function is a plain extern declaration: Zig accepts
/// extern "c" and std.c only in a compile that links libc.
extern fn android_set_abort_message(message: [*:0]const u8) void;
extern fn abort() noreturn;

/// Ends the process with `message` in the tombstone. Explicit calls to
/// @panic lower to this function, and every safety check below ends here.
pub fn call(message: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);

    var buffer: [max_message + 1]u8 = undefined;

    const len = @min(message.len, max_message);

    @memcpy(buffer[0..len], message[0..len]);
    buffer[len] = 0;
    android_set_abort_message(buffer[0..len :0]);
    abort();
}

pub fn sentinelMismatch(_: anytype, _: anytype) noreturn {
    @branchHint(.cold);
    call("sentinel mismatch", null);
}

pub fn unwrapError(_: anyerror) noreturn {
    @branchHint(.cold);
    call("attempt to unwrap error", null);
}

pub fn outOfBounds(_: usize, _: usize) noreturn {
    @branchHint(.cold);
    call("index out of bounds", null);
}

pub fn startGreaterThanEnd(_: usize, _: usize) noreturn {
    @branchHint(.cold);
    call("start index is larger than end index", null);
}

pub fn inactiveUnionField(_: anytype, _: anytype) noreturn {
    @branchHint(.cold);
    call("access of inactive union field", null);
}

pub fn sliceCastLenRemainder(_: usize) noreturn {
    @branchHint(.cold);
    call("slice length does not divide exactly into destination " ++
        "elements", null);
}

pub fn reachedUnreachable() noreturn {
    @branchHint(.cold);
    call("reached unreachable code", null);
}

pub fn unwrapNull() noreturn {
    @branchHint(.cold);
    call("attempt to use null value", null);
}

pub fn castToNull() noreturn {
    @branchHint(.cold);
    call("cast causes pointer to be null", null);
}

pub fn incorrectAlignment() noreturn {
    @branchHint(.cold);
    call("incorrect alignment", null);
}

pub fn invalidErrorCode() noreturn {
    @branchHint(.cold);
    call("invalid error code", null);
}

pub fn unexpectedErrorCode(_: anyerror) noreturn {
    @branchHint(.cold);
    call("unexpected error code", null);
}

pub fn integerOutOfBounds() noreturn {
    @branchHint(.cold);
    call("integer does not fit in destination type", null);
}

pub fn integerOverflow() noreturn {
    @branchHint(.cold);
    call("integer overflow", null);
}

pub fn shlOverflow() noreturn {
    @branchHint(.cold);
    call("left shift overflowed bits", null);
}

pub fn shrOverflow() noreturn {
    @branchHint(.cold);
    call("right shift overflowed bits", null);
}

pub fn divideByZero() noreturn {
    @branchHint(.cold);
    call("division by zero", null);
}

pub fn exactDivisionRemainder() noreturn {
    @branchHint(.cold);
    call("exact division produced remainder", null);
}

pub fn integerPartOutOfBounds() noreturn {
    @branchHint(.cold);
    call("integer part of floating point value out of bounds", null);
}

pub fn corruptSwitch() noreturn {
    @branchHint(.cold);
    call("switch on corrupt value", null);
}

pub fn shiftRhsTooBig() noreturn {
    @branchHint(.cold);
    call("shift amount is greater than the type size", null);
}

pub fn invalidEnumValue() noreturn {
    @branchHint(.cold);
    call("invalid enum value", null);
}

pub fn forLenMismatch() noreturn {
    @branchHint(.cold);
    call("for loop over objects with non-equal lengths", null);
}

pub fn copyLenMismatch() noreturn {
    @branchHint(.cold);
    call("source and destination have non-equal lengths", null);
}

pub fn memcpyAlias() noreturn {
    @branchHint(.cold);
    call("@memcpy arguments alias", null);
}

pub fn noreturnReturned() noreturn {
    @branchHint(.cold);
    call("'noreturn' function returned", null);
}

pub fn loadUninstantiableType() noreturn {
    @branchHint(.cold);
    call("attempt to load uninstantiable type", null);
}
