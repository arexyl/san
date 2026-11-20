//! The root of libsan_abi_test.so, the device test library of the C ABI.
//! It has the link shape of San's library and exports the functions of
//! the Bindings header in place of JNI, so that a test executable calls
//! the C ABI on Bionic, over Bionic's malloc and free.

pub const panic = @import("engine").android_panic;

comptime {
    // The functions of the C ABI are the exports of the library.
    _ = @import("root.zig");
}
