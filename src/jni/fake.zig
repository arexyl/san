//! Stand-ins for a Java VM and its JNI environment, for the tests of the
//! JNI layer. They implement only the functions that the layer calls,
//! and every other slot of the function tables is null. San's Android
//! test executables have no Java VM, so they also load the San library
//! against these.
//!
//! An environment records what the layer did with it: the class that it
//! looked up, the methods that it registered, and each call that it made
//! while an exception was pending, which JNI forbids for every function
//! here except the two that inspect and clear the exception.

const std = @import("std");
const jni = @import("jni");

/// A Java `long[]`. A `jlongArray` of the tests is a pointer to one.
pub const LongArray = struct {
    items: []jni.jlong,

    pub fn object(array: *LongArray) jni.jlongArray {
        return array;
    }
};

/// A JNI environment of one thread.
pub const Env = struct {
    /// What a `JNIEnv` holds. A `JNIEnv *` of the tests is the address of
    /// this field.
    functions: jni.JNIEnv = &native_functions,
    /// Whether a class lookup finds its class. A failed lookup leaves an
    /// exception pending.
    class_found: bool = true,
    /// The status of a registration. A failed registration leaves an
    /// exception pending and the methods registered, as a part of them
    /// would be.
    register_status: jni.jint = jni.JNI_OK,

    /// The name of the class of the latest lookup.
    looked_up: ?[*:0]const u8 = null,
    /// The registered methods, or null when none is registered.
    registered: ?[]const jni.JNINativeMethod = null,
    pending: bool = false,
    /// The calls that the layer made while an exception was pending.
    forbidden_calls: u32 = 0,
    unregistrations: u32 = 0,

    pub fn pointer(env: *Env) [*c]jni.JNIEnv {
        return &env.functions;
    }

    /// Returns the registered function of the method `name` as the
    /// function pointer type `Function`, as the VM would call it, or null
    /// when no such method is registered.
    pub fn method(
        env: *const Env,
        comptime Function: type,
        name: []const u8,
    ) ?Function {
        for (env.registered orelse return null) |native| {
            if (std.mem.eql(u8, std.mem.span(native.name), name)) {
                return @ptrCast(@alignCast(native.fnPtr));
            }
        }

        return null;
    }

    fn of(pointer_to_functions: [*c]jni.JNIEnv) *Env {
        const functions: *jni.JNIEnv = pointer_to_functions;

        return @fieldParentPtr("functions", functions);
    }

    /// Returns the environment of a call that JNI forbids while an
    /// exception is pending, and counts the call when one is.
    fn entered(pointer_to_functions: [*c]jni.JNIEnv) *Env {
        const env = of(pointer_to_functions);

        if (env.pending) env.forbidden_calls += 1;

        return env;
    }
};

/// A Java VM whose one thread has the environment `env`.
pub const Vm = struct {
    /// What a `JavaVM` holds. A `JavaVM *` of the tests is the address of
    /// this field.
    functions: jni.JavaVM = &invoke_functions,
    env: *Env,
    /// The status of GetEnv. A failure writes no environment.
    get_env_status: jni.jint = jni.JNI_OK,

    /// The JNI version of the latest GetEnv.
    requested_version: ?jni.jint = null,

    pub fn pointer(vm: *Vm) [*c]jni.JavaVM {
        return &vm.functions;
    }
};

const native_functions: jni.JNINativeInterface = std.mem.zeroInit(
    jni.JNINativeInterface,
    .{
        .FindClass = findClass,
        .ExceptionCheck = exceptionCheck,
        .ExceptionClear = exceptionClear,
        .RegisterNatives = registerNatives,
        .UnregisterNatives = unregisterNatives,
        .GetArrayLength = getArrayLength,
        .SetLongArrayRegion = setLongArrayRegion,
    },
);

const invoke_functions: jni.JNIInvokeInterface = std.mem.zeroInit(
    jni.JNIInvokeInterface,
    .{ .GetEnv = getEnv },
);

fn getEnv(
    pointer_to_functions: [*c]jni.JavaVM,
    out: [*c]?*anyopaque,
    version: jni.jint,
) callconv(.c) jni.jint {
    const functions: *jni.JavaVM = pointer_to_functions;

    const vm: *Vm = @fieldParentPtr("functions", functions);

    vm.requested_version = version;
    out.* = null;

    if (vm.get_env_status == jni.JNI_OK) out.* = @ptrCast(vm.env.pointer());

    return vm.get_env_status;
}

fn findClass(
    pointer_to_functions: [*c]jni.JNIEnv,
    name: [*c]const u8,
) callconv(.c) jni.jclass {
    const env = Env.entered(pointer_to_functions);

    env.looked_up = name;

    if (!env.class_found) {
        env.pending = true;

        return null;
    }

    // Any non-null reference stands for the class.
    return env;
}

fn exceptionCheck(
    pointer_to_functions: [*c]jni.JNIEnv,
) callconv(.c) jni.jboolean {
    return @intFromBool(Env.of(pointer_to_functions).pending);
}

fn exceptionClear(pointer_to_functions: [*c]jni.JNIEnv) callconv(.c) void {
    Env.of(pointer_to_functions).pending = false;
}

fn registerNatives(
    pointer_to_functions: [*c]jni.JNIEnv,
    _: jni.jclass,
    methods: [*c]const jni.JNINativeMethod,
    count: jni.jint,
) callconv(.c) jni.jint {
    const env = Env.entered(pointer_to_functions);

    env.registered = methods[0..@intCast(count)];

    if (env.register_status != jni.JNI_OK) env.pending = true;

    return env.register_status;
}

fn unregisterNatives(
    pointer_to_functions: [*c]jni.JNIEnv,
    _: jni.jclass,
) callconv(.c) jni.jint {
    const env = Env.entered(pointer_to_functions);

    env.registered = null;
    env.unregistrations += 1;

    return jni.JNI_OK;
}

fn getArrayLength(
    pointer_to_functions: [*c]jni.JNIEnv,
    array: jni.jarray,
) callconv(.c) jni.jsize {
    _ = Env.entered(pointer_to_functions);

    const long_array: *const LongArray = @ptrCast(@alignCast(array.?));

    return @intCast(long_array.items.len);
}

fn setLongArrayRegion(
    pointer_to_functions: [*c]jni.JNIEnv,
    array: jni.jlongArray,
    start: jni.jsize,
    len: jni.jsize,
    buffer: [*c]const jni.jlong,
) callconv(.c) void {
    const env = Env.entered(pointer_to_functions);

    const long_array: *const LongArray = @ptrCast(@alignCast(array.?));

    const first: usize = @intCast(start);
    const count: usize = @intCast(len);

    // A real VM throws ArrayIndexOutOfBoundsException here.
    if (first + count > long_array.items.len) {
        env.pending = true;

        return;
    }

    @memcpy(long_array.items[first..][0..count], buffer[0..count]);
}
