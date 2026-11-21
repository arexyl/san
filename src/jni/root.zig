//! The JNI layer of San: JNI_OnLoad, the registration of every Kotlin
//! declaration of the Bindings, and the conversion between JNI arguments
//! and the C ABI. It validates nothing but the shape of its arguments:
//! the C ABI is the trust boundary.
//!
//! JNI_OnLoad fails only when GetEnv fails. When the class of the
//! declarations is missing or the registration fails, it clears the
//! pending exception, leaves no method registered, and succeeds, so the
//! first call of the binding fails in the VM instead of the load.
//!
//! Each method calls one function of the C ABI. An argument that
//! violates its declared shape returns SAN_STATUS_BINDING_MISMATCH before
//! that function runs, and an output value is written only after it
//! returns. No method raises a Java exception or leaves one pending.
//!
//! The copy takes its destination as a Bitmap. It rejects a Bitmap that
//! the pixel profile does not admit, locks the pixels around its one
//! function, and unlocks them on every path after the lock. No other
//! code of San touches a Bitmap.

const std = @import("std");
const jni = @import("jni");
const san = @import("san");
const abi = @import("abi");

/// The binary name of the class that holds the Kotlin declarations.
pub const class_name = "app/hakusan/reader/san/SanAbi";

/// The methods that JNI_OnLoad registers: one for each Kotlin
/// declaration of the pinned Bindings. A host test compares the names
/// and the descriptors with the Bindings table.
pub const natives = [_]jni.JNINativeMethod{
    native("bindingEstablish", "(I)I", bindingEstablish),
    native("engineCreate", "(JJJJJJJJJJJJJJJJ[J)I", engineCreate),
    native("engineShutdown", "(J)I", engineShutdown),
    native("engineCounters", "(JZ[J)I", engineCounters),
    native("contentOpen", "(J[J)I", contentOpen),
    native("contentFeed", "(JJ[BIIZ)I", contentFeed),
    native("contentClose", "(J)I", contentClose),
    native("jobRequest", "(JIIIII[J)I", jobRequest),
    native("jobStep", "(J[J)I", jobStep),
    native("jobCancel", "(J)I", jobCancel),
    native("jobRelease", "(J)I", jobRelease),
    native("outputCopy", "(JIILandroid/graphics/Bitmap;I)I", outputCopy),
    native("outputRelease", "(J)I", outputRelease),
};

pub export fn JNI_OnLoad(vm: [*c]jni.JavaVM, _: ?*anyopaque) jni.jint {
    var found: ?*anyopaque = null;

    const status = vm.*.*.GetEnv.?(vm, &found, jni.JNI_VERSION_1_6);

    if (status != jni.JNI_OK) return jni.JNI_ERR;

    const env: [*c]jni.JNIEnv = @ptrCast(@alignCast(found orelse
        return jni.JNI_ERR));

    register(env);

    return jni.JNI_VERSION_1_6;
}

comptime {
    const Declared = @TypeOf(jni.JNI_OnLoad);

    if (@TypeOf(JNI_OnLoad) != Declared) {
        @compileError("JNI_OnLoad is " ++ @typeName(@TypeOf(JNI_OnLoad)) ++
            ", and the JNI header declares " ++ @typeName(Declared));
    }
}

/// Registers `natives` on the class of the declarations, or leaves the
/// class without a registered method and the thread without a pending
/// exception.
fn register(env: [*c]jni.JNIEnv) void {
    const functions = env.*;

    const class = functions.*.FindClass.?(env, class_name) orelse {
        functions.*.ExceptionClear.?(env);

        return;
    };

    const status = functions.*.RegisterNatives.?(
        env,
        class,
        &natives,
        natives.len,
    );

    if (status == jni.JNI_OK) return;

    // A failed registration can leave a part of the methods registered.
    // JNI forbids the next call while the exception is pending.
    functions.*.ExceptionClear.?(env);
    _ = functions.*.UnregisterNatives.?(env, class);
}

fn bindingEstablish(
    _: [*c]jni.JNIEnv,
    _: jni.jclass,
    abi_version: jni.jint,
) callconv(.c) jni.jint {
    return abi.san_binding_establish(abi_version);
}

fn engineCreate(
    env: [*c]jni.JNIEnv,
    _: jni.jclass,
    aggregate_budget_bytes: jni.jlong,
    content_count: jni.jlong,
    job_count: jni.jlong,
    content_length_bytes: jni.jlong,
    input_portion_bytes: jni.jlong,
    image_axis_pixels: jni.jlong,
    image_area_pixels: jni.jlong,
    metadata_bytes: jni.jlong,
    metadata_expanded_bytes: jni.jlong,
    metadata_payload_bytes: jni.jlong,
    held_chunk_bytes: jni.jlong,
    icc_tag_count: jni.jlong,
    exif_entry_count: jni.jlong,
    output_bytes: jni.jlong,
    output_lease_bytes: jni.jlong,
    output_lease_count: jni.jlong,
    engine_out: jni.jlongArray,
) callconv(.c) jni.jint {
    if (!holds(env, engine_out, 1)) return san.SAN_STATUS_BINDING_MISMATCH;

    const limits: san.san_engine_limits = .{
        .aggregate_budget_bytes = aggregate_budget_bytes,
        .content_count = content_count,
        .job_count = job_count,
        .content_length_bytes = content_length_bytes,
        .input_portion_bytes = input_portion_bytes,
        .image_axis_pixels = image_axis_pixels,
        .image_area_pixels = image_area_pixels,
        .metadata_bytes = metadata_bytes,
        .metadata_expanded_bytes = metadata_expanded_bytes,
        .metadata_payload_bytes = metadata_payload_bytes,
        .held_chunk_bytes = held_chunk_bytes,
        .icc_tag_count = icc_tag_count,
        .exif_entry_count = exif_entry_count,
        .output_bytes = output_bytes,
        .output_lease_bytes = output_lease_bytes,
        .output_lease_count = output_lease_count,
    };

    var engine: san.san_handle = san.SAN_NO_HANDLE;

    const status = abi.san_engine_create(&limits, &engine);

    env.*.*.SetLongArrayRegion.?(env, engine_out, 0, 1, &engine);

    return status;
}

fn engineShutdown(
    _: [*c]jni.JNIEnv,
    _: jni.jclass,
    engine: jni.jlong,
) callconv(.c) jni.jint {
    return abi.san_engine_shutdown(engine);
}

fn engineCounters(
    env: [*c]jni.JNIEnv,
    _: jni.jclass,
    engine: jni.jlong,
    reset_peak: jni.jboolean,
    counters_out: jni.jlongArray,
) callconv(.c) jni.jint {
    if (!holds(env, counters_out, san.SAN_ENGINE_COUNTERS_LENGTH)) {
        return san.SAN_STATUS_BINDING_MISMATCH;
    }

    var counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(0);

    const status = abi.san_engine_counters(
        engine,
        flag(reset_peak),
        &counters,
    );

    // Only a successful read writes the counters.
    if (status == san.SAN_STATUS_OK) {
        env.*.*.SetLongArrayRegion.?(
            env,
            counters_out,
            0,
            counters.len,
            &counters,
        );
    }

    return status;
}

fn contentOpen(
    env: [*c]jni.JNIEnv,
    _: jni.jclass,
    engine: jni.jlong,
    content_out: jni.jlongArray,
) callconv(.c) jni.jint {
    if (!holds(env, content_out, 1)) return san.SAN_STATUS_BINDING_MISMATCH;

    var content: san.san_handle = san.SAN_NO_HANDLE;

    const status = abi.san_content_open(engine, &content);

    env.*.*.SetLongArrayRegion.?(env, content_out, 0, 1, &content);

    return status;
}

fn contentFeed(
    env: [*c]jni.JNIEnv,
    _: jni.jclass,
    content: jni.jlong,
    position: jni.jlong,
    bytes: jni.jbyteArray,
    offset: jni.jint,
    length: jni.jint,
    end_of_input: jni.jboolean,
) callconv(.c) jni.jint {
    const array = bytes orelse return san.SAN_STATUS_BINDING_MISMATCH;

    if (offset < 0 or length < 0) return san.SAN_STATUS_BINDING_MISMATCH;

    // Neither term is negative, so the difference cannot overflow.
    if (length > env.*.*.GetArrayLength.?(env, array) - offset) {
        return san.SAN_STATUS_BINDING_MISMATCH;
    }

    const functions = env.*;

    const critical = functions.*.GetPrimitiveArrayCritical.?(
        env,
        array,
        null,
    ) orelse {
        functions.*.ExceptionClear.?(env);

        return san.SAN_STATUS_ALLOCATION_FAILED;
    };

    const elements: [*]const u8 = @ptrCast(critical);

    // JNI forbids every other JNI call until the release, and the C ABI
    // only copies the bytes.
    const status = abi.san_content_feed(
        content,
        position,
        elements + @as(usize, @intCast(offset)),
        length,
        flag(end_of_input),
    );

    // The call read the elements and wrote none, so nothing copies back.
    functions.*.ReleasePrimitiveArrayCritical.?(
        env,
        array,
        critical,
        jni.JNI_ABORT,
    );

    return status;
}

fn contentClose(
    _: [*c]jni.JNIEnv,
    _: jni.jclass,
    content: jni.jlong,
) callconv(.c) jni.jint {
    return abi.san_content_close(content);
}

fn jobRequest(
    env: [*c]jni.JNIEnv,
    _: jni.jclass,
    content: jni.jlong,
    left: jni.jint,
    top: jni.jint,
    right: jni.jint,
    bottom: jni.jint,
    max_output_width: jni.jint,
    job_out: jni.jlongArray,
) callconv(.c) jni.jint {
    if (!holds(env, job_out, 1)) return san.SAN_STATUS_BINDING_MISMATCH;

    const request: san.san_output_request = .{
        .left = left,
        .top = top,
        .right = right,
        .bottom = bottom,
        .max_output_width = max_output_width,
    };

    var job: san.san_handle = san.SAN_NO_HANDLE;

    const status = abi.san_job_request(content, &request, &job);

    env.*.*.SetLongArrayRegion.?(env, job_out, 0, 1, &job);

    return status;
}

fn jobStep(
    env: [*c]jni.JNIEnv,
    _: jni.jclass,
    job: jni.jlong,
    report_out: jni.jlongArray,
) callconv(.c) jni.jint {
    if (!holds(env, report_out, san.SAN_JOB_REPORT_LENGTH)) {
        return san.SAN_STATUS_BINDING_MISMATCH;
    }

    var report: [san.SAN_JOB_REPORT_LENGTH]i64 = @splat(0);

    const status = abi.san_job_step(job, &report);

    // A status that rejects the call writes no element.
    switch (status) {
        san.SAN_STATUS_INVALID_HANDLE,
        san.SAN_STATUS_CLOSED,
        san.SAN_STATUS_BINDING_MISMATCH,
        => {},
        else => env.*.*.SetLongArrayRegion.?(
            env,
            report_out,
            0,
            report.len,
            &report,
        ),
    }

    return status;
}

fn jobCancel(
    _: [*c]jni.JNIEnv,
    _: jni.jclass,
    job: jni.jlong,
) callconv(.c) jni.jint {
    return abi.san_job_cancel(job);
}

fn jobRelease(
    _: [*c]jni.JNIEnv,
    _: jni.jclass,
    job: jni.jlong,
) callconv(.c) jni.jint {
    return abi.san_job_release(job);
}

fn outputCopy(
    env: [*c]jni.JNIEnv,
    _: jni.jclass,
    lease: jni.jlong,
    first_row: jni.jint,
    row_count: jni.jint,
    destination: jni.jobject,
    destination_first_row: jni.jint,
) callconv(.c) jni.jint {
    const bitmap = destination orelse return san.SAN_STATUS_BINDING_MISMATCH;

    const backing = Backing.of(env, bitmap) orelse
        return san.SAN_STATUS_BINDING_MISMATCH;

    var pixels: ?*anyopaque = null;

    if (jni.AndroidBitmap_lockPixels(env, bitmap, &pixels) != bitmap_ok) {
        return san.SAN_STATUS_BINDING_MISMATCH;
    }

    const status = abi.san_output_copy(
        lease,
        first_row,
        row_count,
        @ptrCast(pixels),
        backing.width,
        backing.height,
        backing.stride,
        destination_first_row,
        backing.alpha,
    );

    // The unlock fails only for a Bitmap that was recycled during the
    // call. A rejection keeps its status, because the first failed check
    // decides.
    const unlocked = jni.AndroidBitmap_unlockPixels(env, bitmap) == bitmap_ok;

    if (status == san.SAN_STATUS_OK and !unlocked) {
        return san.SAN_STATUS_BINDING_MISMATCH;
    }

    return status;
}

const bitmap_ok = jni.ANDROID_BITMAP_RESULT_SUCCESS;

/// The pixels of a Bitmap that the pixel profile admits, as the C ABI
/// takes the destination of a copy.
const Backing = struct {
    width: i32,
    height: i32,
    stride: i32,
    /// SAN_ALPHA_PREMULTIPLIED or SAN_ALPHA_OPAQUE.
    alpha: i32,

    /// The header declares the hardware flag as `1 << 31`, which is no
    /// value of the `int` of its enumeration, so the mask takes its bits.
    const hardware: u32 = @bitCast(@as(
        i32,
        jni.ANDROID_BITMAP_FLAGS_IS_HARDWARE,
    ));

    const alpha_mask: u32 = jni.ANDROID_BITMAP_FLAGS_ALPHA_MASK;
    const alpha_shift: u5 = jni.ANDROID_BITMAP_FLAGS_ALPHA_SHIFT;
    const premultiplied: u32 = jni.ANDROID_BITMAP_FLAGS_ALPHA_PREMUL;
    const @"opaque": u32 = jni.ANDROID_BITMAP_FLAGS_ALPHA_OPAQUE;

    /// Returns the backing of `bitmap`, or null for a Bitmap that the
    /// copy must not lock: one without a readable description, a
    /// hardware Bitmap, one in another format, alpha encoding, or data
    /// space, and one whose geometry exceeds a coordinate of the C ABI.
    fn of(env: [*c]jni.JNIEnv, bitmap: jni.jobject) ?Backing {
        var info: jni.AndroidBitmapInfo = undefined;

        if (jni.AndroidBitmap_getInfo(env, bitmap, &info) != bitmap_ok) {
            return null;
        }

        if (info.flags & hardware != 0) return null;
        if (info.format != jni.ANDROID_BITMAP_FORMAT_RGBA_8888) return null;

        const alpha: i32 = switch ((info.flags & alpha_mask) >> alpha_shift) {
            premultiplied => san.SAN_ALPHA_PREMULTIPLIED,
            @"opaque" => san.SAN_ALPHA_OPAQUE,
            else => return null,
        };

        // A recycled Bitmap keeps its description and loses its data
        // space.
        const data_space = jni.AndroidBitmap_getDataSpace(env, bitmap);

        if (data_space != jni.ADATASPACE_SRGB) return null;

        return .{
            .width = std.math.cast(i32, info.width) orelse return null,
            .height = std.math.cast(i32, info.height) orelse return null,
            .stride = std.math.cast(i32, info.stride) orelse return null,
            .alpha = alpha,
        };
    }
};

fn outputRelease(
    _: [*c]jni.JNIEnv,
    _: jni.jclass,
    lease: jni.jlong,
) callconv(.c) jni.jint {
    return abi.san_output_release(lease);
}

/// Returns a JNI boolean as the 0 or 1 that the C ABI takes.
fn flag(value: jni.jboolean) i32 {
    return @intFromBool(value != jni.JNI_FALSE);
}

/// Reports whether `array` is an array of exactly `len` elements. A
/// null reference is none.
fn holds(env: [*c]jni.JNIEnv, array: jni.jarray, len: jni.jsize) bool {
    const reference = array orelse return false;

    return env.*.*.GetArrayLength.?(env, reference) == len;
}

/// Returns the registration of `function` as the method `name` with the
/// JNI `descriptor`, after checking the function against the descriptor.
fn native(
    comptime name: [:0]const u8,
    comptime descriptor: [:0]const u8,
    comptime function: anytype,
) jni.JNINativeMethod {
    if (comptime descriptorMismatch(descriptor, @TypeOf(function))) |why| {
        @compileError("the JNI method " ++ name ++ " " ++ descriptor ++
            ": " ++ why);
    }

    return .{
        .name = name,
        .signature = descriptor,
        .fnPtr = @ptrCast(@constCast(&function)),
    };
}

/// Returns what keeps `Function` from being a JNI method of
/// `descriptor`, or null when nothing does. A method has the C calling
/// convention, takes the environment and the class first, then one
/// parameter of the JNI type of each descriptor entry, and returns the
/// type of the descriptor. Every reference type is one `jobject` in C,
/// so the check tells a reference from each primitive and one primitive
/// from another, but not one reference type from another.
fn descriptorMismatch(
    comptime descriptor: []const u8,
    comptime Function: type,
) ?[]const u8 {
    const malformed = "the descriptor is malformed";

    const info = @typeInfo(Function).@"fn";

    const types = info.param_types;

    if (!info.attrs.@"callconv".eql(.c)) {
        return "its function lacks the C calling convention";
    }

    if (types.len < 2 or
        types[0].? != [*c]jni.JNIEnv or
        types[1].? != jni.jclass)
    {
        return "its function does not start with the environment and " ++
            "the class";
    }

    if (descriptor.len == 0 or descriptor[0] != '(') return malformed;

    var index: usize = 1;
    var parameter: usize = 2;

    while (index < descriptor.len and descriptor[index] != ')') {
        const entry = entryAt(descriptor, index) orelse return malformed;

        if (parameter == types.len) {
            return "its function takes fewer parameters";
        }

        if (types[parameter].? != entry.Type) {
            return std.fmt.comptimePrint(
                "parameter {d} of its function is not {s}",
                .{ parameter - 2, @typeName(entry.Type) },
            );
        }

        index = entry.end;
        parameter += 1;
    }

    if (parameter != types.len) return "its function takes more parameters";

    const result = resultAt(descriptor, index + 1) orelse return malformed;

    if (result.end != descriptor.len) return malformed;

    if (info.return_type.? != result.Type) {
        return "its function does not return " ++ @typeName(result.Type);
    }

    return null;
}

/// The JNI type of one descriptor entry and the index after the entry.
const Entry = struct {
    Type: type,
    end: usize,
};

/// Returns the return entry of `descriptor` at `start`, or null when
/// none starts there. Only a return entry may be `V`.
fn resultAt(comptime descriptor: []const u8, comptime start: usize) ?Entry {
    if (start < descriptor.len and descriptor[start] == 'V') {
        return .{ .Type = void, .end = start + 1 };
    }

    return entryAt(descriptor, start);
}

/// Reports whether `name` is a binary class name as a descriptor
/// writes it: segments that are not empty, separated by `/`.
fn isClassName(comptime name: []const u8) bool {
    var segments = std.mem.splitScalar(u8, name, '/');

    while (segments.next()) |segment| {
        if (segment.len == 0) return false;

        for (segment) |char| {
            if (char == '[' or char == '.') return false;
        }
    }

    return true;
}

/// Returns the entry of `descriptor` that starts at `start`, or null
/// when none does.
fn entryAt(comptime descriptor: []const u8, comptime start: usize) ?Entry {
    if (start >= descriptor.len) return null;

    switch (descriptor[start]) {
        'Z' => return .{ .Type = jni.jboolean, .end = start + 1 },
        'B' => return .{ .Type = jni.jbyte, .end = start + 1 },
        'C' => return .{ .Type = jni.jchar, .end = start + 1 },
        'S' => return .{ .Type = jni.jshort, .end = start + 1 },
        'I' => return .{ .Type = jni.jint, .end = start + 1 },
        'J' => return .{ .Type = jni.jlong, .end = start + 1 },
        'F' => return .{ .Type = jni.jfloat, .end = start + 1 },
        'D' => return .{ .Type = jni.jdouble, .end = start + 1 },
        '[' => {
            const element = entryAt(descriptor, start + 1) orelse return null;

            return .{ .Type = jni.jobject, .end = element.end };
        },
        'L' => {
            const semicolon = std.mem.findScalarPos(
                u8,
                descriptor,
                start,
                ';',
            ) orelse return null;

            if (!isClassName(descriptor[start + 1 .. semicolon])) return null;

            return .{ .Type = jni.jobject, .end = semicolon + 1 };
        },
        else => return null,
    }
}

const testing = std.testing;
const bindings = @import("bindings");
const table = @import("table");
const tiny = @import("tiny_png");
const fake = @import("fake.zig");

/// A value that no method writes, so that a test sees whether a call
/// wrote its output.
const unwritten: jni.jlong = 0x5a5a_5a5a_5a5a_5a5a;

/// The limits of engineCreate, which takes them in the field order of
/// `san_engine_limits`.
const limit_count = @typeInfo(san.san_engine_limits).@"struct".field_names.len;

/// Returns the position of the limit `name` among the parameters of
/// engineCreate.
fn limitAt(comptime name: []const u8) usize {
    return std.meta.fieldIndex(san.san_engine_limits, name).?;
}

/// The staging of a content under the roomy limits, in bytes.
const portion_bytes = 4096;

/// Returns roomy limits with an aggregate budget of `budget`: four
/// contents of one staging each, two jobs, two leases, and 1 << 20 for
/// every other limit.
fn limitsUnder(budget: jni.jlong) [limit_count]jni.jlong {
    var limits: [limit_count]jni.jlong = @splat(1 << 20);

    limits[limitAt("aggregate_budget_bytes")] = budget;
    limits[limitAt("content_count")] = 4;
    limits[limitAt("job_count")] = 2;
    limits[limitAt("output_lease_count")] = 2;
    limits[limitAt("input_portion_bytes")] = portion_bytes;

    return limits;
}

/// Calls the registered engineCreate of `env` with `limits`, or fails
/// when the method is not registered.
fn createWith(
    env: *fake.Env,
    limits: [limit_count]jni.jlong,
    engine_out: jni.jlongArray,
) !jni.jint {
    const create = try methodOf(env, "engineCreate", engineCreate);

    return create(
        env.pointer(),
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

/// Returns the registered function of the method `name` of `env`, whose
/// implementation is `function`, as the VM would call it.
fn methodOf(
    env: *const fake.Env,
    comptime name: []const u8,
    comptime function: anytype,
) !*const @TypeOf(function) {
    return env.method(*const @TypeOf(function), name) orelse
        error.TestUnexpectedResult;
}

/// Loads the layer into a VM with `env` and checks that the load
/// succeeds with no exception pending and no forbidden call.
fn expectLoaded(env: *fake.Env) !void {
    var vm: fake.Vm = .{ .env = env };

    try testing.expectEqual(
        jni.JNI_VERSION_1_6,
        JNI_OnLoad(vm.pointer(), null),
    );

    try testing.expectEqual(jni.JNI_VERSION_1_6, vm.requested_version);
    try testing.expectEqualStrings(class_name, std.mem.span(env.looked_up.?));
    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

test "the registration table matches the JNI rows of the Bindings table" {
    // A count at compile time would exceed the default branch quota.
    const buffer = try testing.allocator.alloc(
        table.Row,
        table.rowCount(bindings.table),
    );
    defer testing.allocator.free(buffer);

    var diagnostic: table.Diagnostic = .{};

    const rows = try table.parse(bindings.table, buffer, &diagnostic);

    var declared: usize = 0;

    for (rows) |row| {
        if (row.kind != .jni) continue;

        declared += 1;

        const method = std.mem.cutPrefix(u8, row.name, class_name ++ ".") orelse
            return error.TestUnexpectedResult;

        const registered = for (natives) |candidate| {
            const name = std.mem.span(candidate.name);

            if (std.mem.eql(u8, name, method)) break candidate;
        } else return error.TestUnexpectedResult;

        try testing.expectEqualStrings(
            row.value.descriptor,
            std.mem.span(registered.signature),
        );

        try testing.expect(registered.fnPtr != null);
    }

    try testing.expectEqual(natives.len, declared);
}

test "the load registers every method on the class of the declarations" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const registered = env.registered.?;

    const table_start: [*]const jni.JNINativeMethod = &natives;

    try testing.expectEqual(natives.len, registered.len);
    try testing.expectEqual(table_start, registered.ptr);
    try testing.expectEqual(0, env.unregistrations);
}

test "the load fails only when GetEnv fails" {
    const failures = [_]jni.jint{
        jni.JNI_ERR,
        jni.JNI_EDETACHED,
        jni.JNI_EVERSION,
    };

    for (failures) |status| {
        var env: fake.Env = .{};
        var vm: fake.Vm = .{ .env = &env, .get_env_status = status };

        try testing.expectEqual(jni.JNI_ERR, JNI_OnLoad(vm.pointer(), null));
        try testing.expectEqual(jni.JNI_VERSION_1_6, vm.requested_version);
        try testing.expectEqual(null, env.looked_up);
        try testing.expectEqual(null, env.registered);
    }
}

test "a missing class leaves no method and no exception" {
    var env: fake.Env = .{ .class_found = false };

    try expectLoaded(&env);
    try testing.expectEqual(null, env.registered);
}

test "a failed registration leaves no method and no exception" {
    var env: fake.Env = .{ .register_status = jni.JNI_ERR };

    try expectLoaded(&env);
    try testing.expectEqual(null, env.registered);
    try testing.expectEqual(1, env.unregistrations);
}

// The one test on the state of the process: the registered methods in
// the order of a caller, as the VM would call them.
test "the methods convert their arguments and run the lifecycle" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const establish = try methodOf(&env, "bindingEstablish", bindingEstablish);
    const shutdown = try methodOf(&env, "engineShutdown", engineShutdown);
    const counters = try methodOf(&env, "engineCounters", engineCounters);
    const open = try methodOf(&env, "contentOpen", contentOpen);
    const close = try methodOf(&env, "contentClose", contentClose);

    const jenv = env.pointer();

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        establish(jenv, null, san.SAN_ABI_VERSION + 1),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        establish(jenv, null, san.SAN_ABI_VERSION),
    );

    // A null array and an array of another length run no function of the
    // C ABI: no engine exists afterward, and no element changes.
    var elements = [_]jni.jlong{ unwritten, unwritten };

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        try createWith(&env, limitsUnder(1 << 20), null),
    );

    for ([_]usize{ 0, 2 }) |len| {
        var array: fake.Array = .{ .longs = elements[0..len] };

        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            try createWith(&env, limitsUnder(1 << 20), array.object()),
        );
    }

    try testing.expectEqualSlices(
        jni.jlong,
        &.{ unwritten, unwritten },
        &elements,
    );

    var out: fake.Array = .{ .longs = elements[0..1] };

    // A failure of the C ABI writes no handle.
    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        try createWith(&env, limitsUnder(0), out.object()),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, elements[0]);

    // Each parameter reaches a limit of its own.
    for (0..limit_count) |index| {
        var limits = limitsUnder(1 << 20);

        limits[index] = 0;
        elements[0] = unwritten;

        try testing.expectEqual(
            san.SAN_STATUS_BUDGET_EXCEEDED,
            try createWith(&env, limits, out.object()),
        );

        try testing.expectEqual(san.SAN_NO_HANDLE, elements[0]);
    }

    elements[0] = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        try createWith(&env, limitsUnder(1 << 20), out.object()),
    );

    const engine = elements[0];

    try testing.expect(engine != san.SAN_NO_HANDLE and engine != unwritten);
    try testing.expectEqual(unwritten, elements[1]);

    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        try createWith(&env, limitsUnder(1 << 20), out.object()),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, elements[0]);

    // The read of a live engine writes every counter. Every value of the
    // flag reaches the C ABI as 0 or 1, which rejects any other.
    var counted: [san.SAN_ENGINE_COUNTERS_LENGTH]jni.jlong = @splat(unwritten);
    var counted_array: fake.Array = .{ .longs = &counted };

    const flags = [_]jni.jboolean{ jni.JNI_FALSE, jni.JNI_TRUE, 2, 0xff };

    for (flags) |reset_peak| {
        counted = @splat(unwritten);

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            counters(jenv, null, engine, reset_peak, counted_array.object()),
        );

        for (counted) |element| try testing.expect(element != unwritten);

        // The engine's own state is its four blocks, of the metadata kind.
        const live = counted[san.SAN_ENGINE_COUNTERS_LIVE_BYTES];

        try testing.expect(live > 0);

        try testing.expectEqual(
            live,
            counted[san.SAN_ENGINE_COUNTERS_METADATA_BYTES],
        );

        try testing.expectEqual(
            0,
            counted[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT],
        );
    }

    elements[0] = unwritten;

    // The engine handle of the next generation: the kind fills the
    // lowest byte.
    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        open(jenv, null, engine + 0x100, out.object()),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, elements[0]);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        open(jenv, null, engine, out.object()),
    );

    const content = elements[0];

    try testing.expect(content != san.SAN_NO_HANDLE and content != unwritten);

    counted = @splat(unwritten);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        counters(jenv, null, engine, jni.JNI_FALSE, counted_array.object()),
    );

    try testing.expectEqual(
        1,
        counted[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT],
    );

    try testing.expectEqual(san.SAN_STATUS_OK, close(jenv, null, content));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        close(jenv, null, content),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(jenv, null, engine));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        shutdown(jenv, null, engine),
    );

    // The budget keeps its 64 bits and its sign on the way to the C ABI.
    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        try createWith(&env, limitsUnder(-1), out.object()),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        try createWith(&env, limitsUnder(1 << 40), out.object()),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        shutdown(jenv, null, elements[0]),
    );

    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

/// The image that the decodes of the limits test read, and the bytes of
/// its lease with their block header.
const tiny_png = tiny.bytes;
const tiny_lease_bytes = tiny.width * tiny.height * 4 + 16;

/// Decodes `tiny_png` in a new content of `engine` through the
/// registered methods of `env`, in one portion with the end of the
/// input, so that its one step ends the job. Releases the job and
/// returns the status of the step with the lease that it names.
fn decodeTiny(
    env: *fake.Env,
    engine: jni.jlong,
) !struct { jni.jint, jni.jlong } {
    const open = try methodOf(env, "contentOpen", contentOpen);
    const feed = try methodOf(env, "contentFeed", contentFeed);
    const request = try methodOf(env, "jobRequest", jobRequest);
    const step = try methodOf(env, "jobStep", jobStep);
    const release = try methodOf(env, "jobRelease", jobRelease);

    const jenv = env.pointer();

    var handle = [_]jni.jlong{unwritten};
    var out: fake.Array = .{ .longs = &handle };

    var report: [san.SAN_JOB_REPORT_LENGTH]jni.jlong = @splat(unwritten);
    var report_array: fake.Array = .{ .longs = &report };

    var bytes: [tiny_png.len]jni.jbyte = @bitCast(tiny_png);
    var bytes_array: fake.Array = .{ .bytes = &bytes };

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        open(jenv, null, engine, out.object()),
    );

    const content = handle[0];

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        request(jenv, null, content, 0, 0, 0, 0, 0, out.object()),
    );

    const job = handle[0];

    try testing.expectEqual(san.SAN_STATUS_OK, feed(
        jenv,
        null,
        content,
        0,
        bytes_array.object(),
        0,
        tiny_png.len,
        jni.JNI_TRUE,
    ));

    const status = step(jenv, null, job, report_array.object());

    try testing.expectEqual(san.SAN_STATUS_OK, release(jenv, null, job));

    return .{ status, report[san.SAN_JOB_REPORT_LEASE] };
}

// The sixteen limits share one descriptor letter, so only what the
// engine does with each value tells two parameters apart. The test
// covers the limits that the engine enforces: the budget, the three
// count limits, the input portion, and the metadata limit at the
// creation of an engine and at its admissions, and the length ceiling,
// the two image limits, and the two output ceilings at a decode.
test "each enforced limit reaches the engine from its own parameter" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const establish = try methodOf(&env, "bindingEstablish", bindingEstablish);
    const shutdown = try methodOf(&env, "engineShutdown", engineShutdown);
    const counters = try methodOf(&env, "engineCounters", engineCounters);
    const open = try methodOf(&env, "contentOpen", contentOpen);
    const request = try methodOf(&env, "jobRequest", jobRequest);
    const step = try methodOf(&env, "jobStep", jobStep);
    const cancel = try methodOf(&env, "jobCancel", jobCancel);
    const release = try methodOf(&env, "jobRelease", jobRelease);
    const drop = try methodOf(&env, "outputRelease", outputRelease);

    const jenv = env.pointer();

    const budget_at = limitAt("aggregate_budget_bytes");
    const contents_at = limitAt("content_count");
    const jobs_at = limitAt("job_count");
    const metadata_at = limitAt("metadata_bytes");
    const leases_at = limitAt("output_lease_count");

    var handle = [_]jni.jlong{unwritten};
    var out: fake.Array = .{ .longs = &handle };

    var counted: [san.SAN_ENGINE_COUNTERS_LENGTH]jni.jlong = @splat(unwritten);
    var counted_array: fake.Array = .{ .longs = &counted };

    var report: [san.SAN_JOB_REPORT_LENGTH]jni.jlong = @splat(unwritten);
    var report_array: fake.Array = .{ .longs = &report };

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        establish(jenv, null, san.SAN_ABI_VERSION),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        try createWith(&env, limitsUnder(1 << 20), out.object()),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        counters(jenv, null, handle[0], jni.JNI_FALSE, counted_array.object()),
    );

    // The engine's own state under the roomy limits, in bytes.
    const own = counted[san.SAN_ENGINE_COUNTERS_LIVE_BYTES];

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(jenv, null, handle[0]));

    // A count beyond the slot index refuses only a count limit, and a
    // byte count below the engine's own state refuses only the budget
    // and the metadata limit.
    const beyond_index = std.math.maxInt(u16) + 1;

    for (0..limit_count) |index| {
        const counts = index == contents_at or index == jobs_at or
            index == leases_at;

        const holds_state = index == budget_at or index == metadata_at;

        const probes = [_]struct { jni.jlong, bool }{
            .{ beyond_index, counts },
            .{ own - 1, holds_state },
        };

        for (probes) |probe| {
            const value, const refused = probe;

            var limits = limitsUnder(1 << 20);

            limits[index] = value;

            const status = try createWith(&env, limits, out.object());

            if (refused) {
                try testing.expectEqual(san.SAN_STATUS_BUDGET_EXCEEDED, status);

                continue;
            }

            try testing.expectEqual(san.SAN_STATUS_OK, status);

            try testing.expectEqual(
                san.SAN_STATUS_OK,
                shutdown(jenv, null, handle[0]),
            );
        }
    }

    // A staging and its block header, in bytes.
    const staged = portion_bytes + 16;

    // The budget admits the engine and one staging, and the metadata
    // limit admits exactly the engine. With the two values exchanged,
    // the first opening would fail.
    var tight = limitsUnder(own + staged);

    tight[metadata_at] = own;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        try createWith(&env, tight, out.object()),
    );

    const tight_engine = handle[0];

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        open(jenv, null, tight_engine, out.object()),
    );

    try testing.expectEqual(san.SAN_STATUS_OK, counters(
        jenv,
        null,
        tight_engine,
        jni.JNI_FALSE,
        counted_array.object(),
    ));

    try testing.expectEqual(staged, counted[san.SAN_ENGINE_COUNTERS_INPUT_BYTES]);

    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        open(jenv, null, tight_engine, out.object()),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        shutdown(jenv, null, tight_engine),
    );

    // Three contents, two jobs, and one lease: each refusal below has
    // one of the three limits as its only cause.
    var counted_limits = limitsUnder(1 << 20);

    counted_limits[contents_at] = 3;
    counted_limits[jobs_at] = 2;
    counted_limits[leases_at] = 1;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        try createWith(&env, counted_limits, out.object()),
    );

    const engine = handle[0];

    var contents: [3]jni.jlong = undefined;

    for (&contents) |*content| {
        try testing.expectEqual(
            san.SAN_STATUS_OK,
            open(jenv, null, engine, out.object()),
        );

        content.* = handle[0];
    }

    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        open(jenv, null, engine, out.object()),
    );

    var jobs: [3]jni.jlong = undefined;

    // Each job gets its request after the refusal that only one limit
    // causes: none for the first, the one live lease for the second, and
    // the two owned jobs for the third. The step of a canceled job
    // reclaims its lease and keeps its slot, and the release frees the
    // slot.
    for (&jobs, contents, 0..) |*job, content, at| {
        if (at != 0) {
            try testing.expectEqual(
                san.SAN_STATUS_BUDGET_EXCEEDED,
                request(jenv, null, content, 0, 0, 0, 0, 0, out.object()),
            );

            try testing.expectEqual(
                san.SAN_STATUS_OK,
                cancel(jenv, null, jobs[at - 1]),
            );

            try testing.expectEqual(
                san.SAN_STATUS_CANCELED,
                step(jenv, null, jobs[at - 1], report_array.object()),
            );
        }

        if (at == 2) {
            // Both jobs are terminal, and both still hold a slot.
            try testing.expectEqual(
                san.SAN_STATUS_BUDGET_EXCEEDED,
                request(jenv, null, content, 0, 0, 0, 0, 0, out.object()),
            );

            try testing.expectEqual(
                san.SAN_STATUS_OK,
                release(jenv, null, jobs[0]),
            );
        }

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            request(jenv, null, content, 0, 0, 0, 0, 0, out.object()),
        );

        job.* = handle[0];
    }

    try testing.expectEqual(
        san.SAN_STATUS_PENDING,
        shutdown(jenv, null, engine),
    );

    for (jobs[1..]) |job| {
        try testing.expectEqual(san.SAN_STATUS_OK, release(jenv, null, job));
    }

    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(jenv, null, engine));

    // What two decodes of the image need of each limit that a decode
    // reads, exactly, while the lease of the first is held. The five
    // values differ, so any exchange among them puts a smaller value
    // where a larger one is needed.
    const length_at = limitAt("content_length_bytes");
    const axis_at = limitAt("image_axis_pixels");
    const area_at = limitAt("image_area_pixels");
    const output_at = limitAt("output_bytes");
    const lease_at = limitAt("output_lease_bytes");

    var exact = limitsUnder(1 << 20);

    exact[length_at] = tiny_png.len;
    exact[axis_at] = tiny.height;
    exact[area_at] = tiny.width * tiny.height;
    exact[output_at] = 2 * tiny_lease_bytes;
    exact[lease_at] = tiny_lease_bytes;

    // The exact limits admit both decodes. One byte or pixel less in a
    // limit refuses the first decode, and one byte less of all output
    // refuses the second, whose lease the first one's leaves no room for.
    const lowered = [_]?usize{
        null,
        length_at,
        axis_at,
        area_at,
        lease_at,
        output_at,
    };

    const admitted: jni.jint = san.SAN_STATUS_OK;
    const refused: jni.jint = san.SAN_STATUS_BUDGET_EXCEEDED;

    for (lowered) |at| {
        var limits = exact;

        if (at) |index| limits[index] -= 1;

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            try createWith(&env, limits, out.object()),
        );

        const decoding = handle[0];

        const first_refused = at != null and at != output_at;
        const second_refused = at != null;

        const first_status, const first_lease = try decodeTiny(&env, decoding);
        const second_status, const second_lease = try decodeTiny(&env, decoding);

        try testing.expectEqual(
            if (first_refused) refused else admitted,
            first_status,
        );

        try testing.expectEqual(
            if (second_refused) refused else admitted,
            second_status,
        );

        for ([_]jni.jlong{ first_lease, second_lease }) |lease| {
            if (lease == san.SAN_NO_HANDLE) continue;

            try testing.expectEqual(san.SAN_STATUS_OK, drop(jenv, null, lease));
        }

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            shutdown(jenv, null, decoding),
        );
    }

    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

test "an output or report array of another length runs no function" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const counters = try methodOf(&env, "engineCounters", engineCounters);
    const open = try methodOf(&env, "contentOpen", contentOpen);
    const request = try methodOf(&env, "jobRequest", jobRequest);
    const step = try methodOf(&env, "jobStep", jobStep);

    const jenv = env.pointer();

    var elements: [san.SAN_JOB_REPORT_LENGTH + 1]jni.jlong = @splat(unwritten);

    const mismatch = san.SAN_STATUS_BINDING_MISMATCH;

    try testing.expectEqual(mismatch, counters(jenv, null, 0, 0, null));
    try testing.expectEqual(mismatch, open(jenv, null, 0, null));
    try testing.expectEqual(mismatch, step(jenv, null, 0, null));

    try testing.expectEqual(
        mismatch,
        request(jenv, null, 0, 0, 0, 0, 0, 0, null),
    );

    for (0..elements.len + 1) |len| {
        var array: fake.Array = .{ .longs = elements[0..len] };

        const object = array.object();

        // An array of the declared length passes the check, and the C ABI
        // then rejects the handle, which writes no report element.
        const invalid = san.SAN_STATUS_INVALID_HANDLE;

        try testing.expectEqual(
            if (len == san.SAN_ENGINE_COUNTERS_LENGTH) invalid else mismatch,
            counters(jenv, null, 0, 0, object),
        );

        try testing.expectEqual(
            if (len == san.SAN_JOB_REPORT_LENGTH) invalid else mismatch,
            step(jenv, null, 0, object),
        );

        if (len == 1) continue;

        try testing.expectEqual(mismatch, open(jenv, null, 0, object));

        try testing.expectEqual(
            mismatch,
            request(jenv, null, 0, 0, 0, 0, 0, 0, object),
        );
    }

    for (elements) |element| try testing.expectEqual(unwritten, element);

    // An output array of one element receives SAN_NO_HANDLE.
    var out: fake.Array = .{ .longs = elements[0..1] };

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        open(jenv, null, 0, out.object()),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, elements[0]);

    elements[0] = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        request(jenv, null, 0, 0, 0, 0, 0, 0, out.object()),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, elements[0]);
    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

test "the feed checks its byte range before it requests the elements" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const feed = try methodOf(&env, "contentFeed", contentFeed);

    const jenv = env.pointer();

    var bytes: [8]jni.jbyte = @splat(0x5a);
    var array: fake.Array = .{ .bytes = &bytes };

    const max = std.math.maxInt(jni.jint);
    const min = std.math.minInt(jni.jint);

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        feed(jenv, null, 0, 0, null, 0, 0, jni.JNI_TRUE),
    );

    const invalid_ranges = [_][2]jni.jint{
        .{ -1, 0 },
        .{ 0, -1 },
        .{ min, 0 },
        .{ 0, min },
        .{ min, min },
        .{ 0, 9 },
        .{ 1, 8 },
        .{ 8, 1 },
        .{ 9, 0 },
        .{ max, 0 },
        .{ 0, max },
        .{ max, max },
        .{ 1, max },
    };

    for (invalid_ranges) |range| {
        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            feed(jenv, null, 0, 0, array.object(), range[0], range[1], 0),
        );
    }

    try testing.expectEqual(0, env.critical_regions);

    // A valid range takes the elements for one call of the C ABI, which
    // rejects the handle, and releases them without a copy back.
    const valid_ranges = [_][2]jni.jint{
        .{ 0, 8 },
        .{ 0, 0 },
        .{ 8, 0 },
        .{ 3, 5 },
        .{ 7, 1 },
    };

    for (valid_ranges, 1..) |range, regions| {
        env.release_mode = null;

        try testing.expectEqual(
            san.SAN_STATUS_INVALID_HANDLE,
            feed(jenv, null, 0, 0, array.object(), range[0], range[1], 0),
        );

        try testing.expectEqual(regions, env.critical_regions);
        try testing.expectEqual(null, env.critical);
        try testing.expectEqual(jni.JNI_ABORT, env.release_mode.?);
    }

    // An empty array has one valid range.
    var empty: fake.Array = .{ .bytes = bytes[0..0] };

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        feed(jenv, null, 0, 0, empty.object(), 0, 0, jni.JNI_TRUE),
    );

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        feed(jenv, null, 0, 0, empty.object(), 0, 1, jni.JNI_TRUE),
    );

    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

test "a feed without the array's elements fails as AllocationFailed" {
    var env: fake.Env = .{ .elements_available = false };

    try expectLoaded(&env);

    const feed = try methodOf(&env, "contentFeed", contentFeed);

    var bytes: [8]jni.jbyte = @splat(0x5a);
    var array: fake.Array = .{ .bytes = &bytes };

    try testing.expectEqual(
        san.SAN_STATUS_ALLOCATION_FAILED,
        feed(env.pointer(), null, 0, 0, array.object(), 0, 8, 0),
    );

    // The range check still comes first.
    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        feed(env.pointer(), null, 0, 0, array.object(), 0, 9, 0),
    );

    try testing.expectEqual(0, env.critical_regions);
    try testing.expectEqual(null, env.critical);
    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

test "the methods of a content, a job, and a lease reject every handle" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const close = try methodOf(&env, "contentClose", contentClose);
    const cancel = try methodOf(&env, "jobCancel", jobCancel);
    const release = try methodOf(&env, "jobRelease", jobRelease);
    const copy = try methodOf(&env, "outputCopy", outputCopy);
    const drop = try methodOf(&env, "outputRelease", outputRelease);

    const jenv = env.pointer();

    var pixels: [bitmap_bytes]u8 = @splat(untouched);
    var bitmap = bitmapOver(&pixels);

    const handles = [_]jni.jlong{
        san.SAN_NO_HANDLE,
        1,
        -1,
        unwritten,
        std.math.minInt(jni.jlong),
    };

    for (handles) |handle| {
        const statuses = [_]jni.jint{
            close(jenv, null, handle),
            cancel(jenv, null, handle),
            release(jenv, null, handle),
            copy(jenv, null, handle, 0, 1, bitmap.object(), 0),
            drop(jenv, null, handle),
        };

        for (statuses) |status| {
            try testing.expectEqual(san.SAN_STATUS_INVALID_HANDLE, status);
        }

        // A null Bitmap decides before the handle does.
        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            copy(jenv, null, handle, 0, 1, null, 0),
        );
    }

    // The handle decides inside the lock of an admitted Bitmap.
    try testing.expectEqual(handles.len, bitmap.locks);
    try testing.expectEqual(handles.len, bitmap.unlocks);
    try testing.expectEqual(0, bitmap.misuses);
    try expectRows(&pixels, 0, 0, 0);
    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

/// The destination of the copy tests: a Bitmap of the width of
/// `tiny_png` with more rows than its lease and a padded stride, so
/// that each number of a copy differs from the others.
const bitmap_height = 7;
const bitmap_stride = tiny.width * 4 + 4;
const bitmap_bytes = bitmap_height * bitmap_stride;

/// The value of every byte of a destination that no copy wrote.
const untouched: u8 = 0xa5;

/// Returns a mutable ARGB_8888 Bitmap in sRGB with alpha over `pixels`.
fn bitmapOver(pixels: *[bitmap_bytes]u8) fake.Bitmap {
    return .{
        .info = .{
            .width = tiny.width,
            .height = bitmap_height,
            .stride = bitmap_stride,
            .format = jni.ANDROID_BITMAP_FORMAT_RGBA_8888,
            .flags = jni.ANDROID_BITMAP_FLAGS_ALPHA_PREMUL,
        },
        .pixels = pixels,
    };
}

/// Checks that `pixels` holds the rows [first, first + count) of
/// `tiny_png` from the row `at` on, in the pixel profile, and
/// `untouched` in every other byte, the padding of each row included.
fn expectRows(
    pixels: *const [bitmap_bytes]u8,
    first: usize,
    count: usize,
    at: usize,
) !void {
    var expected: [bitmap_bytes]u8 = @splat(untouched);

    for (0..count) |row| {
        const samples = tiny.samples[(first + row) * tiny.width * 3 ..];
        const written = expected[(at + row) * bitmap_stride ..];

        for (0..tiny.width) |column| {
            written[column * 4 ..][0..3].* = samples[column * 3 ..][0..3].*;
            written[column * 4 + 3] = 0xff;
        }
    }

    try testing.expectEqualSlices(u8, &expected, pixels);
}

/// An engine with one held lease of the decoded `tiny_png`.
const Held = struct {
    engine: jni.jlong,
    lease: jni.jlong,

    fn decode(env: *fake.Env) !Held {
        var handle = [_]jni.jlong{unwritten};
        var out: fake.Array = .{ .longs = &handle };

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            try createWith(env, limitsUnder(1 << 20), out.object()),
        );

        const engine = handle[0];

        const status, const lease = try decodeTiny(env, engine);

        try testing.expectEqual(san.SAN_STATUS_OK, status);

        return .{ .engine = engine, .lease = lease };
    }

    /// Releases the lease, which a test may have released, and shuts the
    /// engine down.
    fn end(held: Held, env: *fake.Env) !void {
        const drop = try methodOf(env, "outputRelease", outputRelease);
        const shutdown = try methodOf(env, "engineShutdown", engineShutdown);

        _ = drop(env.pointer(), null, held.lease);

        try testing.expectEqual(
            san.SAN_STATUS_OK,
            shutdown(env.pointer(), null, held.engine),
        );
    }
};

test "the copy writes covered rows into the locked pixels of a Bitmap" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const copy = try methodOf(&env, "outputCopy", outputCopy);
    const jenv = env.pointer();

    const held: Held = try .decode(&env);

    // Each copy names its rows, its destination row, and the flags of
    // its Bitmap. No lease of this build has alpha, so an opaque Bitmap
    // admits it as a premultiplied one does. The last Bitmap sets a bit
    // that the header does not define, outside the alpha mask.
    const Case = struct { jni.jint, jni.jint, jni.jint, u32 };

    const cases = [_]Case{
        .{ 0, 3, 4, jni.ANDROID_BITMAP_FLAGS_ALPHA_PREMUL },
        .{ 1, 2, 0, jni.ANDROID_BITMAP_FLAGS_ALPHA_OPAQUE },
        .{ 2, 1, 6, 1 << 4 },
    };

    for (cases) |case| {
        const first, const count, const at, const flags = case;

        var pixels: [bitmap_bytes]u8 = @splat(untouched);
        var bitmap = bitmapOver(&pixels);

        bitmap.info.flags = flags;

        try testing.expectEqual(san.SAN_STATUS_OK, copy(
            jenv,
            null,
            held.lease,
            first,
            count,
            bitmap.object(),
            at,
        ));

        try expectRows(&pixels, @intCast(first), @intCast(count), @intCast(at));
        try testing.expectEqual(1, bitmap.locks);
        try testing.expectEqual(1, bitmap.unlocks);
        try testing.expectEqual(0, bitmap.misuses);
    }

    try held.end(&env);
    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

test "a Bitmap outside the pixel profile fails before the lock" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const copy = try methodOf(&env, "outputCopy", outputCopy);
    const jenv = env.pointer();

    const held: Held = try .decode(&env);

    const hardware: u32 = 1 << 31;
    const @"opaque": u32 = jni.ANDROID_BITMAP_FLAGS_ALPHA_OPAQUE;
    const beyond: u32 = std.math.maxInt(i32) + 1;

    var scratch: [bitmap_bytes]u8 = undefined;

    const admitted = bitmapOver(&scratch);

    var rejected: [17]fake.Bitmap = @splat(admitted);

    // The description is unreadable, or the lock fails.
    rejected[0].info_result = jni.ANDROID_BITMAP_RESULT_BAD_PARAMETER;
    rejected[1].info_result = jni.ANDROID_BITMAP_RESULT_JNI_EXCEPTION;
    rejected[2].lock_result = jni.ANDROID_BITMAP_RESULT_JNI_EXCEPTION;
    rejected[3].lock_result = jni.ANDROID_BITMAP_RESULT_ALLOCATION_FAILED;

    // A hardware Bitmap, whatever else it states.
    rejected[4].info.flags |= hardware;
    rejected[5].info.flags = hardware | @"opaque";

    rejected[6].info.format = jni.ANDROID_BITMAP_FORMAT_NONE;
    rejected[7].info.format = jni.ANDROID_BITMAP_FORMAT_RGB_565;
    rejected[8].info.format = jni.ANDROID_BITMAP_FORMAT_RGBA_F16;

    rejected[9].info.flags = jni.ANDROID_BITMAP_FLAGS_ALPHA_UNPREMUL;
    rejected[10].info.flags = jni.ANDROID_BITMAP_FLAGS_ALPHA_MASK;

    // A recycled Bitmap, and one in another color space.
    rejected[11].data_space = jni.ADATASPACE_UNKNOWN;
    rejected[12].data_space = jni.ADATASPACE_DISPLAY_P3;

    // A geometry that no coordinate of the C ABI holds.
    rejected[13].info.width = beyond;
    rejected[14].info.height = beyond;
    rejected[15].info.stride = beyond;
    rejected[16].info.stride = std.math.maxInt(u32);

    // An invalid handle would fail the same copy inside the lock.
    const leases = [_]jni.jlong{ held.lease, san.SAN_NO_HANDLE, unwritten };

    for (&rejected) |*bitmap| {
        for (leases) |lease| {
            var pixels: [bitmap_bytes]u8 = @splat(untouched);

            bitmap.pixels = &pixels;

            try testing.expectEqual(san.SAN_STATUS_BINDING_MISMATCH, copy(
                jenv,
                null,
                lease,
                0,
                1,
                bitmap.object(),
                0,
            ));

            try expectRows(&pixels, 0, 0, 0);
        }

        try testing.expectEqual(0, bitmap.locks);
        try testing.expectEqual(0, bitmap.unlocks);
        try testing.expectEqual(0, bitmap.misuses);
    }

    // The control: the same copy into the admitted Bitmap succeeds.
    var pixels: [bitmap_bytes]u8 = @splat(untouched);
    var control = bitmapOver(&pixels);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        copy(jenv, null, held.lease, 0, 1, control.object(), 0),
    );

    try expectRows(&pixels, 0, 1, 0);
    try held.end(&env);
    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

test "the copy passes the geometry of the Bitmap and unlocks on every path" {
    var env: fake.Env = .{};

    try expectLoaded(&env);

    const copy = try methodOf(&env, "outputCopy", outputCopy);
    const drop = try methodOf(&env, "outputRelease", outputRelease);
    const jenv = env.pointer();

    const held: Held = try .decode(&env);

    // What the platform's unlock returns for a recycled Bitmap.
    const unlock_failure: c_int = jni.ANDROID_BITMAP_RESULT_JNI_EXCEPTION;

    var pixels: [bitmap_bytes]u8 = @splat(untouched);

    // The C ABI rejects each of these inside the lock: a width other
    // than the lease's, a stride below the row, and rows past the end.
    const Rejection = struct { width: u32, height: u32, stride: u32 };

    const rejections = [_]Rejection{
        .{ .width = 3, .height = bitmap_height, .stride = bitmap_stride },
        .{ .width = 2, .height = bitmap_height, .stride = 7 },
        .{ .width = 2, .height = 6, .stride = bitmap_stride },
    };

    for (rejections) |rejection| {
        var bitmap = bitmapOver(&pixels);

        bitmap.info.width = rejection.width;
        bitmap.info.height = rejection.height;
        bitmap.info.stride = rejection.stride;

        // A failed unlock keeps the status of the rejection.
        for ([_]c_int{ bitmap_ok, unlock_failure }) |unlock_result| {
            bitmap.unlock_result = unlock_result;

            try testing.expectEqual(
                san.SAN_STATUS_BINDING_MISMATCH,
                copy(jenv, null, held.lease, 0, 3, bitmap.object(), 4),
            );
        }

        try testing.expectEqual(2, bitmap.locks);
        try testing.expectEqual(2, bitmap.unlocks);
        try testing.expectEqual(0, bitmap.misuses);
        try expectRows(&pixels, 0, 0, 0);
    }

    // A failed unlock after a copy that wrote: the Bitmap was recycled
    // during the call.
    var recycled = bitmapOver(&pixels);

    recycled.unlock_result = unlock_failure;

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        copy(jenv, null, held.lease, 0, 3, recycled.object(), 4),
    );

    try testing.expectEqual(1, recycled.unlocks);
    try expectRows(&pixels, 0, 3, 4);

    // The largest height and stride that a coordinate of the C ABI
    // holds. The copy stays inside the first row of the pixels.
    @memset(&pixels, untouched);

    var largest = bitmapOver(&pixels);

    largest.info.height = std.math.maxInt(i32);
    largest.info.stride = std.math.maxInt(i32);

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        copy(jenv, null, held.lease, 2, 1, largest.object(), 0),
    );

    try testing.expectEqual(1, largest.unlocks);
    try expectRows(&pixels, 2, 1, 0);

    // The largest width reaches the C ABI, which the lease then fails.
    largest.info.width = std.math.maxInt(i32);

    try testing.expectEqual(
        san.SAN_STATUS_BINDING_MISMATCH,
        copy(jenv, null, held.lease, 2, 1, largest.object(), 0),
    );

    try testing.expectEqual(2, largest.locks);
    try testing.expectEqual(2, largest.unlocks);

    // A released lease fails as InvalidHandle, also with a failed unlock.
    try testing.expectEqual(san.SAN_STATUS_OK, drop(jenv, null, held.lease));

    @memset(&pixels, untouched);

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        copy(jenv, null, held.lease, 0, 3, recycled.object(), 4),
    );

    try testing.expectEqual(2, recycled.locks);
    try testing.expectEqual(2, recycled.unlocks);
    try testing.expectEqual(0, recycled.misuses);
    try expectRows(&pixels, 0, 0, 0);

    try held.end(&env);
    try testing.expect(!env.pending);
    try testing.expectEqual(0, env.forbidden_calls);
}

/// A JNI method of one parameter.
fn Unary(comptime Parameter: type, comptime Result: type) type {
    return fn ([*c]jni.JNIEnv, jni.jclass, Parameter) callconv(.c) Result;
}

/// Each primitive letter of a descriptor with its JNI type.
const primitives = .{
    .{ "Z", jni.jboolean },
    .{ "B", jni.jbyte },
    .{ "C", jni.jchar },
    .{ "S", jni.jshort },
    .{ "I", jni.jint },
    .{ "J", jni.jlong },
    .{ "F", jni.jfloat },
    .{ "D", jni.jdouble },
};

test "a method matches its descriptor and no other primitive" {
    inline for (primitives) |primitive| {
        const letter, const Type = primitive;

        const takes = "(" ++ letter ++ ")I";
        const returns = "(I)" ++ letter;

        try testing.expectEqual(
            null,
            comptime descriptorMismatch(takes, Unary(Type, jni.jint)),
        );

        try testing.expectEqual(
            null,
            comptime descriptorMismatch(returns, Unary(jni.jint, Type)),
        );

        inline for (primitives) |other| {
            if (other[1] == Type) continue;

            try testing.expect(comptime descriptorMismatch(
                takes,
                Unary(other[1], jni.jint),
            ) != null);

            try testing.expect(comptime descriptorMismatch(
                returns,
                Unary(jni.jint, other[1]),
            ) != null);
        }

        // A reference is no primitive, and a primitive no reference.
        try testing.expect(comptime descriptorMismatch(
            takes,
            Unary(jni.jobject, jni.jint),
        ) != null);

        try testing.expect(comptime descriptorMismatch(
            "([J)I",
            Unary(Type, jni.jint),
        ) != null);
    }

    const accepted = .{ "([J)I", "([[B)I", "(Landroid/graphics/Bitmap;)I" };

    inline for (accepted) |descriptor| {
        const Reference = Unary(jni.jobject, jni.jint);

        try testing.expectEqual(
            null,
            comptime descriptorMismatch(descriptor, Reference),
        );
    }

    try testing.expectEqual(
        null,
        comptime descriptorMismatch("(I)V", Unary(jni.jint, void)),
    );
}

test "a function that is no JNI method of its descriptor is refused" {
    const Method = Unary(jni.jlong, jni.jint);

    const refused = .{
        // Another calling convention.
        .{ "(J)I", fn ([*c]jni.JNIEnv, jni.jclass, jni.jlong) jni.jint },
        // No environment, and no class.
        .{ "(J)I", fn (jni.jlong) callconv(.c) jni.jint },
        .{ "(J)I", fn ([*c]jni.JNIEnv, jni.jlong) callconv(.c) jni.jint },
        // Fewer and more parameters than entries.
        .{ "(JJ)I", Method },
        .{ "()I", Method },
        // Another return type, and a void return.
        .{ "(J)J", Method },
        .{ "(J)V", Method },
        // Malformed descriptors.
        .{ "", Method },
        .{ "J)I", Method },
        .{ "(J", Method },
        .{ "(J)", Method },
        .{ "(J)II", Method },
        .{ "(V)I", Unary(void, jni.jint) },
        .{ "([)I", Unary(jni.jobject, jni.jint) },
        .{ "([V)I", Unary(jni.jobject, jni.jint) },
        .{ "(Lno/end)I", Unary(jni.jobject, jni.jint) },
        .{ "(L;)I", Unary(jni.jobject, jni.jint) },
        .{ "(L/;)I", Unary(jni.jobject, jni.jint) },
        .{ "(La//b;)I", Unary(jni.jobject, jni.jint) },
        .{ "(L[I;)I", Unary(jni.jobject, jni.jint) },
        .{ "(La.b;)I", Unary(jni.jobject, jni.jint) },
    };

    inline for (refused) |pair| {
        const descriptor, const Function = pair;

        try testing.expect(
            comptime descriptorMismatch(descriptor, Function) != null,
        );
    }
}

test "a descriptor names the JNI type of each parameter" {
    const first = comptime entryAt("(J[J)I", 1).?;
    const second = comptime entryAt("(J[J)I", first.end).?;
    const object = comptime entryAt("(Landroid/graphics/Bitmap;I)I", 1).?;

    try testing.expectEqual(jni.jlong, first.Type);
    try testing.expectEqual(2, first.end);
    try testing.expectEqual(jni.jobject, second.Type);
    try testing.expectEqual(4, second.end);
    try testing.expectEqual(jni.jobject, object.Type);
    try testing.expectEqual(26, object.end);

    try testing.expectEqual(null, comptime entryAt("(Lno/end", 1));
    try testing.expectEqual(null, comptime entryAt("([", 1));
    try testing.expectEqual(null, comptime entryAt("(V)I", 1));
    try testing.expectEqual(null, comptime entryAt("(", 1));
}
