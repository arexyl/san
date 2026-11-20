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
//!   calls as the VM would: the lifecycle in the order of a caller, then
//!   the methods of a content, a job, and a lease with a handle that
//!   names nothing.
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
    .{ "engineCreate", "(JJJJJJJJJJJJJJJJ[J)I" },
    .{ "engineShutdown", "(J)I" },
    .{ "engineCounters", "(JZ[J)I" },
    .{ "contentOpen", "(J[J)I" },
    .{ "contentFeed", "(JJ[BIIZ)I" },
    .{ "contentClose", "(J)I" },
    .{ "jobRequest", "(JIIIII[J)I" },
    .{ "jobStep", "(J[J)I" },
    .{ "jobCancel", "(J)I" },
    .{ "jobRelease", "(J)I" },
    .{ "outputCopy", "(JIILandroid/graphics/Bitmap;I)I" },
    .{ "outputRelease", "(J)I" },
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

/// engineCreate: the sixteen limits in the field order of
/// `san_engine_limits`, then the output array.
const Create = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlong,
    jni.jlongArray,
) callconv(.c) jni.jint;

/// engineShutdown, contentClose, jobCancel, jobRelease, and
/// outputRelease: one handle.
const OfHandle = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
) callconv(.c) jni.jint;

const Counters = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
    jni.jboolean,
    jni.jlongArray,
) callconv(.c) jni.jint;

/// contentOpen and jobStep: a handle and an output or report array.
const IntoArray = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
    jni.jlongArray,
) callconv(.c) jni.jint;

const Feed = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
    jni.jlong,
    jni.jbyteArray,
    jni.jint,
    jni.jint,
    jni.jboolean,
) callconv(.c) jni.jint;

const Request = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
    jni.jint,
    jni.jint,
    jni.jint,
    jni.jint,
    jni.jint,
    jni.jlongArray,
) callconv(.c) jni.jint;

const Copy = *const fn (
    [*c]jni.JNIEnv,
    jni.jclass,
    jni.jlong,
    jni.jint,
    jni.jint,
    jni.jobject,
    jni.jint,
) callconv(.c) jni.jint;

/// The limits of engineCreate.
const limit_count = 16;

/// Calls `create` with roomy limits, except that the limit `index` is
/// `value`.
fn createWith(
    create: Create,
    env: [*c]jni.JNIEnv,
    index: usize,
    value: jni.jlong,
    engine_out: jni.jlongArray,
) jni.jint {
    var limits: [limit_count]jni.jlong = @splat(1 << 20);

    limits[index] = value;

    return create(
        env,
        null,
        limits[0],
        limits[1],
        limits[2],
        limits[3],
        limits[4],
        limits[5],
        limits[6],
        limits[7],
        limits[8],
        limits[9],
        limits[10],
        limits[11],
        limits[12],
        limits[13],
        limits[14],
        limits[15],
        engine_out,
    );
}

/// Calls `create` with roomy limits under an aggregate budget of
/// `budget`, the first limit.
fn createUnder(
    create: Create,
    env: [*c]jni.JNIEnv,
    budget: jni.jlong,
    engine_out: jni.jlongArray,
) jni.jint {
    return createWith(create, env, 0, budget, engine_out);
}

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
    try harness.case("methods without a handle", withoutHandle(&env));

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
    const shutdown = env.method(OfHandle, "engineShutdown") orelse return false;
    const counters = env.method(Counters, "engineCounters") orelse return false;
    const open = env.method(IntoArray, "contentOpen") orelse return false;

    const jenv = env.pointer();

    var elements = [_]jni.jlong{ unwritten, unwritten };
    var out: fake.Array = .{ .longs = elements[0..1] };

    // Before the binding, the C ABI refuses the creation.
    if (createUnder(create, jenv, 1 << 20, out.object()) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    if (establish(jenv, null, san.SAN_ABI_VERSION + 1) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    if (establish(jenv, null, san.SAN_ABI_VERSION) != san.SAN_STATUS_OK) {
        return false;
    }

    // A null array and an array of another length run no function of the
    // C ABI: no engine exists afterward, and no element changes.
    elements[0] = unwritten;

    if (createUnder(create, jenv, 1 << 20, null) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    for ([_]usize{ 0, 2 }) |len| {
        var array: fake.Array = .{ .longs = elements[0..len] };

        if (createUnder(create, jenv, 1 << 20, array.object()) !=
            san.SAN_STATUS_BINDING_MISMATCH) return false;
    }

    if (elements[0] != unwritten or elements[1] != unwritten) return false;

    // A failure of the C ABI writes no handle.
    if (createUnder(create, jenv, 0, out.object()) !=
        san.SAN_STATUS_BUDGET_EXCEEDED) return false;

    if (elements[0] != san.SAN_NO_HANDLE) return false;

    // Each of the sixteen parameters reaches a limit of its own. Most of
    // them travel on the stack.
    for (0..limit_count) |index| {
        elements[0] = unwritten;

        if (createWith(create, jenv, index, 0, out.object()) !=
            san.SAN_STATUS_BUDGET_EXCEEDED) return false;

        if (elements[0] != san.SAN_NO_HANDLE) return false;
    }

    elements[0] = unwritten;

    if (createUnder(create, jenv, 1 << 20, out.object()) !=
        san.SAN_STATUS_OK) return false;

    const engine = elements[0];

    if (engine == san.SAN_NO_HANDLE or engine == unwritten) return false;

    if (createUnder(create, jenv, 1 << 20, out.object()) !=
        san.SAN_STATUS_BUDGET_EXCEEDED) return false;

    // The read and the opening of a live engine fail without an output.
    var counted: [san.SAN_ENGINE_COUNTERS_LENGTH]jni.jlong = @splat(unwritten);
    var counted_array: fake.Array = .{ .longs = &counted };

    if (counters(jenv, null, engine, jni.JNI_TRUE, counted_array.object()) !=
        san.SAN_STATUS_ENGINE_FAILURE) return false;

    for (counted) |element| {
        if (element != unwritten) return false;
    }

    if (open(jenv, null, engine, out.object()) !=
        san.SAN_STATUS_ENGINE_FAILURE) return false;

    if (elements[0] != san.SAN_NO_HANDLE) return false;
    if (shutdown(jenv, null, engine) != san.SAN_STATUS_OK) return false;

    if (shutdown(jenv, null, engine) != san.SAN_STATUS_INVALID_HANDLE) {
        return false;
    }

    // The budget keeps its 64 bits and its sign on the way to the C ABI.
    if (createUnder(create, jenv, -1, out.object()) !=
        san.SAN_STATUS_BUDGET_EXCEEDED) return false;

    if (createUnder(create, jenv, 1 << 40, out.object()) != san.SAN_STATUS_OK) {
        return false;
    }

    if (shutdown(jenv, null, elements[0]) != san.SAN_STATUS_OK) return false;

    return !env.pending and env.forbidden_calls == 0;
}

/// Reports whether the methods of a content, a job, and a lease check
/// the shape of their arguments and then reject a handle that names
/// nothing.
fn withoutHandle(env: *fake.Env) bool {
    const feed = env.method(Feed, "contentFeed") orelse return false;
    const close = env.method(OfHandle, "contentClose") orelse return false;
    const request = env.method(Request, "jobRequest") orelse return false;
    const step = env.method(IntoArray, "jobStep") orelse return false;
    const cancel = env.method(OfHandle, "jobCancel") orelse return false;
    const release = env.method(OfHandle, "jobRelease") orelse return false;
    const copy = env.method(Copy, "outputCopy") orelse return false;
    const drop = env.method(OfHandle, "outputRelease") orelse return false;

    const jenv = env.pointer();
    const mismatch = san.SAN_STATUS_BINDING_MISMATCH;
    const invalid = san.SAN_STATUS_INVALID_HANDLE;

    var bytes: [8]jni.jbyte = @splat(0x5a);
    var byte_array: fake.Array = .{ .bytes = &bytes };

    const fed = byte_array.object();
    const regions = env.critical_regions;

    // The byte range is checked before the elements are requested.
    if (feed(jenv, null, unwritten, 0, null, 0, 0, 0) != mismatch) return false;

    for ([_][2]jni.jint{ .{ -1, 1 }, .{ 0, 9 }, .{ 8, 1 } }) |range| {
        const offset, const length = range;

        const status = feed(jenv, null, unwritten, 0, fed, offset, length, 0);

        if (status != mismatch) return false;
    }

    if (env.critical_regions != regions) return false;

    if (feed(jenv, null, unwritten, 0, fed, 3, 5, 1) != invalid) return false;

    if (env.critical_regions != regions + 1 or env.critical != null) {
        return false;
    }

    if (env.release_mode != jni.JNI_ABORT) return false;

    var elements: [san.SAN_JOB_REPORT_LENGTH]jni.jlong = @splat(unwritten);
    var report: fake.Array = .{ .longs = &elements };
    var short: fake.Array = .{ .longs = elements[0..2] };
    var out: fake.Array = .{ .longs = elements[0..1] };

    if (step(jenv, null, unwritten, short.object()) != mismatch) return false;
    if (step(jenv, null, unwritten, report.object()) != invalid) return false;

    if (request(jenv, null, unwritten, 0, 0, 0, 0, 0, short.object()) !=
        mismatch) return false;

    for (elements) |element| {
        if (element != unwritten) return false;
    }

    if (request(jenv, null, unwritten, 0, 0, 0, 0, 0, out.object()) !=
        invalid) return false;

    if (elements[0] != san.SAN_NO_HANDLE) return false;

    // Any non-null reference stands for the Bitmap.
    var bitmap: u8 = 0;

    if (copy(jenv, null, unwritten, 0, 1, null, 0) != mismatch) return false;
    if (copy(jenv, null, unwritten, 0, 1, &bitmap, 0) != invalid) return false;

    for ([_]OfHandle{ close, cancel, release, drop }) |method| {
        if (method(jenv, null, unwritten) != invalid) return false;
    }

    return !env.pending and env.forbidden_calls == 0;
}
