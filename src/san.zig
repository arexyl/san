//! The root of libsan.so, the San library that the Android app loads.
//! JNI_OnLoad is its one export: the JNI layer registers the Kotlin
//! declarations of the Bindings there, and every other symbol stays
//! local to the library.

pub const panic = @import("engine").android_panic;

comptime {
    // The JNI layer defines JNI_OnLoad.
    _ = @import("jni_layer");
}
