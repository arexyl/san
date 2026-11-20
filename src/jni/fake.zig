//! Stand-ins for a Java VM and its JNI environment, for the tests of the
//! JNI layer. They implement only the functions that the layer calls,
//! and every other slot of the function tables is null. San's Android
//! test executables have no Java VM, so they also load the San library
//! against these.
//!
//! An environment records what the layer did with it: the class that it
//! looked up, the methods that it registered, the critical regions that
//! it entered and left, and each call that JNI forbids. JNI forbids a
//! call while an exception is pending, for every function here except
//! the two that inspect and clear the exception, and it forbids every
//! call inside a critical region except the one that leaves the region.

const std = @import("std");
const jni = @import("jni");

/// A Java primitive array. A `jarray` of the tests is a pointer to one.
pub const Array = union(enum) {
    longs: []jni.jlong,
    bytes: []jni.jbyte,

    pub fn object(array: *Array) jni.jarray {
        return array;
    }

    fn of(reference: jni.jarray) *Array {
        return @ptrCast(@alignCast(reference.?));
    }

    fn len(array: Array) usize {
        return switch (array) {
            inline else => |items| items.len,
        };
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
    /// Whether the VM provides the elements of an array. A refusal
    /// leaves an exception pending, as an OutOfMemoryError would be.
    elements_available: bool = true,

    /// The name of the class of the latest lookup.
    looked_up: ?[*:0]const u8 = null,
    /// The registered methods, or null when none is registered.
    registered: ?[]const jni.JNINativeMethod = null,
    pending: bool = false,
    /// The array of the open critical region, or null outside one.
    critical: ?*const Array = null,
    /// The elements that the open critical region handed out.
    critical_elements: ?*anyopaque = null,
    /// The critical regions that the layer entered.
    critical_regions: u32 = 0,
    /// The release mode of the latest critical region that it left.
    release_mode: ?jni.jint = null,
    /// The calls that the layer made while an exception was pending or
    /// inside a critical region.
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
    /// exception is pending and inside a critical region, and counts the
    /// call when either holds.
    fn entered(pointer_to_functions: [*c]jni.JNIEnv) *Env {
        const env = of(pointer_to_functions);

        if (env.pending or env.critical != null) env.forbidden_calls += 1;

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
        .GetPrimitiveArrayCritical = getPrimitiveArrayCritical,
        .ReleasePrimitiveArrayCritical = releasePrimitiveArrayCritical,
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
    const env = Env.of(pointer_to_functions);

    if (env.critical != null) env.forbidden_calls += 1;

    return @intFromBool(env.pending);
}

fn exceptionClear(pointer_to_functions: [*c]jni.JNIEnv) callconv(.c) void {
    const env = Env.of(pointer_to_functions);

    if (env.critical != null) env.forbidden_calls += 1;

    env.pending = false;
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

    return @intCast(Array.of(array).len());
}

fn setLongArrayRegion(
    pointer_to_functions: [*c]jni.JNIEnv,
    array: jni.jlongArray,
    start: jni.jsize,
    len: jni.jsize,
    buffer: [*c]const jni.jlong,
) callconv(.c) void {
    const env = Env.entered(pointer_to_functions);

    const items = Array.of(array).longs;

    const first: usize = @intCast(start);
    const count: usize = @intCast(len);

    // A real VM throws ArrayIndexOutOfBoundsException here.
    if (first + count > items.len) {
        env.pending = true;

        return;
    }

    @memcpy(items[first..][0..count], buffer[0..count]);
}

fn getPrimitiveArrayCritical(
    pointer_to_functions: [*c]jni.JNIEnv,
    array: jni.jarray,
    _: [*c]jni.jboolean,
) callconv(.c) ?*anyopaque {
    const env = Env.entered(pointer_to_functions);

    if (!env.elements_available) {
        env.pending = true;

        return null;
    }

    const entered = Array.of(array);

    env.critical = entered;
    env.critical_regions += 1;

    env.critical_elements = switch (entered.*) {
        inline else => |items| items.ptr,
    };

    return env.critical_elements;
}

/// Leaves the critical region. A release of another array or of other
/// elements than the region handed out counts as a forbidden call.
fn releasePrimitiveArrayCritical(
    pointer_to_functions: [*c]jni.JNIEnv,
    array: jni.jarray,
    elements: ?*anyopaque,
    mode: jni.jint,
) callconv(.c) void {
    const env = Env.of(pointer_to_functions);

    if (env.critical != Array.of(array) or
        env.critical_elements != elements)
    {
        env.forbidden_calls += 1;
    }

    env.critical = null;
    env.critical_elements = null;
    env.release_mode = mode;
}
