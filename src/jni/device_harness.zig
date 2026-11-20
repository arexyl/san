//! The Android harness of libsan.so, the San library. It needs the
//! library through DT_NEEDED and calls JNI_OnLoad, the library's one
//! export, against stand-ins for a Java VM, because a test executable
//! has none. It runs beside the library on the device:
//! `LD_LIBRARY_PATH=. ./san-jni-harness`.
//!
//! Cases:
//! - a VM whose GetEnv fails, which fails the load;
//! - a VM whose class lookup fails, and one whose registration fails,
//!   which both load with no method registered and no exception pending;
//! - a VM that records the registered methods, which the harness then
//!   calls as the VM would, in the order of a caller.
//!
//! Registration in a Java VM, and every conversion that needs one, runs
//! only inside an Android app.
//!
//! The harness prints one line per case, ending in `ok` or `FAIL`, then
//! a summary. It exits 0 only when every case passes, 1 when a case
//! fails, and 2 on a usage error.

const std = @import("std");
const jni = @import("jni");
const san = @import("san");
const fake = @import("fake.zig");

pub const panic = @import("engine").android_panic;

pub const std_options: std.Options = .{
    // A fault reaches the system's crash handler unchanged, so that the
    // tombstone records the faulting frame.
    .enable_segfault_handler = false,
};

/// The methods that the library registers, each with its descriptor.
const expected_methods = [_][2][]const u8{
    .{ "bindingEstablish", "(I)I" },
    .{ "engineCreate", "(J[J)I" },
    .{ "engineShutdown", "(J)I" },
};

/// The binary name of the class that the library looks up.
const class_name = "app/hakusan/reader/san/SanAbi";

/// A value that no method writes, so that a case sees whether a call
/// wrote its output.
const unwritten: jni.jlong = 0x5a5a_5a5a_5a5a_5a5a;

const Establish = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jint,
) callconv(.c) jni.jint;

const Create = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
    jni.jlongArray,
) callconv(.c) jni.jint;

const Shutdown = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
) callconv(.c) jni.jint;

const usage = "usage: san-jni-harness\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 1) {
        try std.Io.File.stderr().writeStreamingAll(io, usage);

        return 2;
    }

    var buffer: [4096]u8 = undefined;

    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);

    var harness: Harness = .{ .out = &stdout.interface };

    try harness.case("GetEnv fails", getEnvFails());
    try harness.case("class lookup fails", unregisteredLoad(.{
        .class_found = false,
    }, 0));
    try harness.case("registration fails", unregisteredLoad(.{
        .register_status = jni.JNI_ERR,
    }, 1));

    var env: fake.Env = .{};

    try harness.case("registered methods", registers(&env));
    try harness.case("lifecycle through the methods", lifecycle(&env));

    try harness.out.print("summary passed={d} failed={d}\n", .{
        harness.passed,
        harness.failed,
    });

    try harness.out.flush();

    return if (harness.failed == 0) 0 else 1;
}

const Harness = struct {
    out: *std.Io.Writer,
    passed: u32 = 0,
    failed: u32 = 0,

    fn case(harness: *Harness, name: []const u8, passed: bool) !void {
        if (passed) harness.passed += 1 else harness.failed += 1;

        try harness.out.print("{s} {s}\n", .{
            name,
            if (passed) "ok" else "FAIL",
        });
    }
};

/// Loads the library into a VM with `env` and reports whether the load
/// succeeded after a lookup of the class, with no exception pending and
/// no call that JNI forbids.
fn loads(env: *fake.Env) bool {
    var vm: fake.Vm = .{ .env = env };

    if (jni.JNI_OnLoad(vm.pointer(), null) != jni.JNI_VERSION_1_6) return false;
    if (vm.requested_version != jni.JNI_VERSION_1_6) return false;

    const looked_up = env.looked_up orelse return false;

    return std.mem.eql(u8, std.mem.span(looked_up), class_name) and
        !env.pending and env.forbidden_calls == 0;
}

fn getEnvFails() bool {
    for ([_]jni.jint{ jni.JNI_ERR, jni.JNI_EDETACHED }) |status| {
        var env: fake.Env = .{};
        var vm: fake.Vm = .{ .env = &env, .get_env_status = status };

        if (jni.JNI_OnLoad(vm.pointer(), null) != jni.JNI_ERR) return false;
        if (env.looked_up != null or env.registered != null) return false;
    }

    return true;
}

/// Reports whether a load into `initial` succeeds and leaves no method
/// registered, after exactly `unregistrations` unregistrations.
fn unregisteredLoad(initial: fake.Env, unregistrations: u32) bool {
    var env = initial;

    return loads(&env) and env.registered == null and
        env.unregistrations == unregistrations;
}

fn registers(env: *fake.Env) bool {
    if (!loads(env)) return false;

    const registered = env.registered orelse return false;

    if (registered.len != expected_methods.len) return false;

    for (expected_methods) |expected| {
        const found = for (registered) |native| {
            const name = std.mem.span(native.name);

            if (std.mem.eql(u8, name, expected[0])) break native;
        } else return false;

        const descriptor = std.mem.span(found.signature);

        if (!std.mem.eql(u8, descriptor, expected[1])) return false;
        if (found.fnPtr == null) return false;
    }

    return true;
}

fn lifecycle(env: *fake.Env) bool {
    const establish = env.method(Establish, "bindingEstablish") orelse
        return false;

    const create = env.method(Create, "engineCreate") orelse return false;
    const shutdown = env.method(Shutdown, "engineShutdown") orelse return false;

    const jenv = env.pointer();

    var elements = [_]jni.jlong{ unwritten, unwritten };
    var out: fake.LongArray = .{ .items = elements[0..1] };

    // Before the binding, the C ABI refuses the creation.
    if (create(jenv, null, 1 << 20, out.object()) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    if (establish(jenv, null, san.SAN_ABI_VERSION + 1) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    if (establish(jenv, null, san.SAN_ABI_VERSION) != san.SAN_STATUS_OK) {
        return false;
    }

    // A null array and an array of another length run no function of the
    // C ABI: no engine exists afterward, and no element changes.
    elements[0] = unwritten;

    if (create(jenv, null, 1 << 20, null) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    for ([_]usize{ 0, 2 }) |len| {
        var array: fake.LongArray = .{ .items = elements[0..len] };

        if (create(jenv, null, 1 << 20, array.object()) !=
            san.SAN_STATUS_BINDING_MISMATCH) return false;
    }

    if (elements[0] != unwritten or elements[1] != unwritten) return false;

    // A failure of the C ABI writes no handle.
    if (create(jenv, null, 0, out.object()) !=
        san.SAN_STATUS_BUDGET_EXCEEDED) return false;

    if (elements[0] != san.SAN_NO_HANDLE) return false;

    elements[0] = unwritten;

    if (create(jenv, null, 1 << 20, out.object()) != san.SAN_STATUS_OK) {
        return false;
    }

    const engine = elements[0];

    if (engine == san.SAN_NO_HANDLE or engine == unwritten) return false;

    if (create(jenv, null, 1 << 20, out.object()) !=
        san.SAN_STATUS_BUDGET_EXCEEDED) return false;

    if (shutdown(jenv, null, engine) != san.SAN_STATUS_OK) return false;

    if (shutdown(jenv, null, engine) != san.SAN_STATUS_INVALID_HANDLE) {
        return false;
    }

    // The budget keeps its 64 bits and its sign on the way to the C ABI.
    if (create(jenv, null, -1, out.object()) !=
        san.SAN_STATUS_BUDGET_EXCEEDED) return false;

    if (create(jenv, null, 1 << 40, out.object()) != san.SAN_STATUS_OK) {
        return false;
    }

    if (shutdown(jenv, null, elements[0]) != san.SAN_STATUS_OK) return false;

    return !env.pending and env.forbidden_calls == 0;
}
