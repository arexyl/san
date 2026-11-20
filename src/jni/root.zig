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
    native("engineCreate", "(J[J)I", engineCreate),
    native("engineShutdown", "(J)I", engineShutdown),
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
    engine_out: jni.jlongArray,
) callconv(.c) jni.jint {
    if (!holds(env, engine_out, 1)) return san.SAN_STATUS_BINDING_MISMATCH;

    const limits: san.san_engine_limits = .{
        .aggregate_budget_bytes = aggregate_budget_bytes,
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
const fake = @import("fake.zig");

/// A value that no method writes, so that a test sees whether a call
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
    var buffer: [table.rowCount(bindings.table)]table.Row = undefined;
    var diagnostic: table.Diagnostic = .{};

    const rows = try table.parse(bindings.table, &buffer, &diagnostic);

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

    const establish = env.method(Establish, "bindingEstablish").?;
    const create = env.method(Create, "engineCreate").?;
    const shutdown = env.method(Shutdown, "engineShutdown").?;

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
        create(jenv, null, 1 << 20, null),
    );

    for ([_]usize{ 0, 2 }) |len| {
        var array: fake.LongArray = .{ .items = elements[0..len] };

        try testing.expectEqual(
            san.SAN_STATUS_BINDING_MISMATCH,
            create(jenv, null, 1 << 20, array.object()),
        );
    }

    try testing.expectEqualSlices(
        jni.jlong,
        &.{ unwritten, unwritten },
        &elements,
    );

    var out: fake.LongArray = .{ .items = elements[0..1] };

    // A failure of the C ABI writes no handle.
    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        create(jenv, null, 0, out.object()),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, elements[0]);

    elements[0] = unwritten;

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(jenv, null, 1 << 20, out.object()),
    );

    const engine = elements[0];

    try testing.expect(engine != san.SAN_NO_HANDLE and engine != unwritten);
    try testing.expectEqual(unwritten, elements[1]);

    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        create(jenv, null, 1 << 20, out.object()),
    );

    try testing.expectEqual(san.SAN_NO_HANDLE, elements[0]);
    try testing.expectEqual(san.SAN_STATUS_OK, shutdown(jenv, null, engine));

    try testing.expectEqual(
        san.SAN_STATUS_INVALID_HANDLE,
        shutdown(jenv, null, engine),
    );

    // The budget keeps its 64 bits and its sign on the way to the C ABI.
    try testing.expectEqual(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        create(jenv, null, -1, out.object()),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        create(jenv, null, 1 << 40, out.object()),
    );

    try testing.expectEqual(
        san.SAN_STATUS_OK,
        shutdown(jenv, null, elements[0]),
    );

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
