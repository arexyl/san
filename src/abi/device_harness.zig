//! The Android harness of libsan_abi_test.so, the device test library of
//! the C ABI. It needs the library through DT_NEEDED and calls the
//! functions of the Bindings header as a caller would. It runs beside
//! the library on the device, with the directory of the reader corpus:
//! `LD_LIBRARY_PATH=. ./san-abi-harness <corpus>`.
//!
//! The binding flag and the engine slot belong to the process, so the
//! cases run in one fixed order: the calls before the binding is
//! established, the binding, the limits, one engine and the handles that
//! do not name it, the functions that reject every handle, the contents
//! of an engine, a job from its request to its release with a pending
//! shutdown, one decode with the lease that outlives it, early output
//! with the outcomes that keep it, cancellations that race the step of
//! their job, a run of engines one after another, creations that race
//! from several threads, and the cases of the corpus.
//!
//! The decodes before the corpus read an image that is built at compile
//! time. They check the reports and the counters, and they copy each
//! lease into a plain destination with a padded stride and compare its
//! pixels. The cases of the corpus read their fixtures and its manifest
//! from the directory.
//!
//! The harness prints one line per case, ending in `ok` or `FAIL`, then
//! a summary. It exits 0 only when every case passes, 1 when a case
//! fails, and 2 on a usage error.

const std = @import("std");
const san = @import("san");
const tiny = @import("tiny_png");
const corpus = @import("corpus.zig");

pub const panic = @import("engine").android_panic;

pub const std_options: std.Options = .{
    // A fault reaches the system's crash handler unchanged, so that the
    // tombstone records the faulting frame.
    .enable_segfault_handler = false,
};

const limit_names = @typeInfo(san.san_engine_limits).@"struct".field_names;

/// The content slots of an engine of the harness, the staging of each
/// content, and the header that its block adds.
const content_slots = 4;
const portion_bytes = 4096;
const block_header = 16;

/// The job slots of an engine of the harness, and its count limit of
/// leases.
const job_slots = 2;

/// Limits that admit every engine of the harness: each one is 1 << 20,
/// except the slots of the contents and of the jobs, the count limit of
/// leases, and the staging of a content.
const roomy: san.san_engine_limits = uniform: {
    var admitting: san.san_engine_limits = undefined;

    for (limit_names) |name| @field(admitting, name) = 1 << 20;

    admitting.content_count = content_slots;
    admitting.job_count = job_slots;
    admitting.output_lease_count = job_slots;
    admitting.input_portion_bytes = portion_bytes;

    break :uniform admitting;
};

/// The request of the whole image at a scale of 1:1.
const whole: san.san_output_request = .{
    .left = 0,
    .top = 0,
    .right = 0,
    .bottom = 0,
    .max_output_width = 0,
};

/// A job report, and one that no step has written.
const Report = [san.SAN_JOB_REPORT_LENGTH]i64;
const unstepped: Report = @splat(unwritten);

/// A value that no creation writes, so that a case sees whether a call
/// wrote its output.
const unwritten: san.san_handle = 0x5a5a_5a5a_5a5a_5a5a;

/// What turns an engine handle into the handle of the next generation:
/// the kind fills the lowest byte, and the generation starts above it.
const next_generation = 0x100;

/// The engines of the run, one after another.
const run_engines = 1000;

/// The threads of the creation race, and its rounds.
const race_threads = 8;
const race_rounds = 200;

/// The rounds of the race of a cancellation against a step.
const cancel_rounds = 2000;

const usage = "usage: san-abi-harness <corpus directory>\n";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(io, usage);

        return 2;
    }

    const directory = args[1];

    var buffer: [4096]u8 = undefined;

    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);

    var harness: Harness = .{ .out = &stdout.interface };

    try harness.case("before the binding", beforeBinding());
    try harness.case("binding", binding());
    try harness.case("limits", limits());
    try harness.case("one engine", oneEngine());
    try harness.case("no content, job, or lease", noOtherHandle());
    try harness.case("contents", contents());
    try harness.case("one job", oneJob());
    try harness.case("one decode", oneDecode());
    try harness.case("early output", earlyOutput());
    try harness.case("racing cancellations", try racingCancellations());
    try harness.case("engines in turn", enginesInTurn());
    try harness.case("racing creations", try racingCreations());

    // Each case of the corpus holds its fixture and its pixels at once.
    inline for (.{
        .{ "corpus: ordinary page", corpus.decodesOrdinary },
        .{ "corpus: long segment", corpus.refusesLong },
        .{ "corpus: scaled band", corpus.scalesLongBand },
    }) |named| {
        const name, const run = named;

        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();

        try harness.outcome(name, run(io, arena.allocator(), directory));
    }

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

    /// Counts a case of the corpus and names the error of a failed one.
    fn outcome(
        harness: *Harness,
        name: []const u8,
        result: corpus.Error!void,
    ) !void {
        if (result) |_| {
            try harness.case(name, true);
        } else |err| {
            try harness.out.print("{s}: {t}\n", .{ name, err });
            try harness.case(name, false);
        }
    }
};

/// Reports whether a creation under the roomy limits with an aggregate
/// budget of `budget` fails as `status` and writes SAN_NO_HANDLE.
fn refuses(budget: i64, status: san.san_status) bool {
    var refused = roomy;

    refused.aggregate_budget_bytes = budget;

    return refusesUnder(refused, status);
}

fn refusesUnder(refused: san.san_engine_limits, status: san.san_status) bool {
    var engine = unwritten;

    return san.san_engine_create(&refused, &engine) == status and
        engine == san.SAN_NO_HANDLE;
}

/// Creates an engine under the roomy limits and returns its handle, or
/// null when the creation fails or writes no handle.
fn createEngine() ?san.san_handle {
    var engine = unwritten;

    if (san.san_engine_create(&roomy, &engine) != san.SAN_STATUS_OK) {
        return null;
    }

    if (engine == san.SAN_NO_HANDLE or engine == unwritten) return null;

    return engine;
}

fn beforeBinding() bool {
    return refuses(1 << 20, san.SAN_STATUS_BINDING_MISMATCH) and
        san.san_engine_shutdown(san.SAN_NO_HANDLE) ==
            san.SAN_STATUS_INVALID_HANDLE;
}

fn binding() bool {
    const others = [_]i32{
        san.SAN_ABI_VERSION + 1,
        san.SAN_ABI_VERSION - 1,
        std.math.maxInt(i32),
        std.math.minInt(i32),
    };

    for (others) |version| {
        const status = san.san_binding_establish(version);

        if (status != san.SAN_STATUS_BINDING_MISMATCH) return false;
    }

    if (!refuses(1 << 20, san.SAN_STATUS_BINDING_MISMATCH)) return false;

    for (0..2) |_| {
        const status = san.san_binding_establish(san.SAN_ABI_VERSION);

        if (status != san.SAN_STATUS_OK) return false;
    }

    // A later mismatch changes nothing: the next case still creates.
    return san.san_binding_establish(san.SAN_ABI_VERSION + 1) ==
        san.SAN_STATUS_BINDING_MISMATCH;
}

fn limits() bool {
    for ([_]i64{ 0, -1, std.math.minInt(i64), 1 }) |budget| {
        if (!refuses(budget, san.SAN_STATUS_BUDGET_EXCEEDED)) return false;
    }

    // Each limit refuses on its own.
    inline for (limit_names) |name| {
        var refused = roomy;

        @field(refused, name) = 0;

        if (!refusesUnder(refused, san.SAN_STATUS_BUDGET_EXCEEDED)) {
            return false;
        }
    }

    return true;
}

/// Reports whether `counters` shows an engine that holds only its own
/// state: three live blocks of metadata, which are also both peaks, and no
/// reservation, input, output, content, job, or lease.
fn ownStateAlone(counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64) bool {
    const live = counters[san.SAN_ENGINE_COUNTERS_LIVE_BYTES];

    if (live <= 0) return false;

    const equal_to_live = [_]usize{
        san.SAN_ENGINE_COUNTERS_PEAK_LIVE_BYTES,
        san.SAN_ENGINE_COUNTERS_PEAK_COMMITTED_BYTES,
        san.SAN_ENGINE_COUNTERS_METADATA_BYTES,
    };

    const zero = [_]usize{
        san.SAN_ENGINE_COUNTERS_RESERVED_BYTES,
        san.SAN_ENGINE_COUNTERS_INPUT_BYTES,
        san.SAN_ENGINE_COUNTERS_OUTPUT_BYTES,
        san.SAN_ENGINE_COUNTERS_CONTENT_COUNT,
        san.SAN_ENGINE_COUNTERS_JOB_COUNT,
        san.SAN_ENGINE_COUNTERS_LEASE_COUNT,
    };

    for (equal_to_live) |index| {
        if (counters[index] != live) return false;
    }

    for (zero) |index| {
        if (counters[index] != 0) return false;
    }

    return true;
}

/// Reports whether the counters read of a live engine checks its
/// arguments and reports the engine's own state on Bionic's heap, and
/// whether the content opening checks its engine and writes no handle
/// for an engine handle that is invalid.
fn engineCalls(engine: san.san_handle) bool {
    var counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(unwritten);
    var content = unwritten;

    if (san.san_engine_counters(engine + next_generation, 0, &counters) !=
        san.SAN_STATUS_INVALID_HANDLE) return false;

    if (san.san_engine_counters(engine, 2, &counters) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    // A rejected read writes no counter.
    for (counters) |counter| {
        if (counter != unwritten) return false;
    }

    // A read with a reset changes no count of an engine whose peaks
    // equal its live bytes, so the next read reports the same.
    for (0..2) |_| {
        if (san.san_engine_counters(engine, 1, &counters) !=
            san.SAN_STATUS_OK) return false;

        if (!ownStateAlone(counters)) return false;
    }

    if (san.san_content_open(engine + next_generation, &content) !=
        san.SAN_STATUS_INVALID_HANDLE) return false;

    return content == san.SAN_NO_HANDLE;
}

/// Reports whether `engine` counts `count` open contents, with the
/// staging of each in its input bytes and nothing else in its live bytes
/// beyond its own metadata.
fn holds(engine: san.san_handle, count: i64) bool {
    var counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(unwritten);

    if (san.san_engine_counters(engine, 0, &counters) !=
        san.SAN_STATUS_OK) return false;

    const input = counters[san.SAN_ENGINE_COUNTERS_INPUT_BYTES];

    return counters[san.SAN_ENGINE_COUNTERS_CONTENT_COUNT] == count and
        input == count * (portion_bytes + block_header) and
        counters[san.SAN_ENGINE_COUNTERS_LIVE_BYTES] ==
            counters[san.SAN_ENGINE_COUNTERS_METADATA_BYTES] + input;
}

/// Opens a content in `engine` and returns its handle, or null when the
/// opening fails or writes no handle.
fn openContent(engine: san.san_handle) ?san.san_handle {
    var content = unwritten;

    if (san.san_content_open(engine, &content) != san.SAN_STATUS_OK) {
        return null;
    }

    if (content == san.SAN_NO_HANDLE or content == unwritten) return null;

    return content;
}

/// Reports whether each function of a content, a job, and a lease
/// rejects `handle` and leaves its outputs alone.
fn rejects(handle: san.san_handle) bool {
    const request: san.san_output_request = .{
        .left = 0,
        .top = 0,
        .right = 0,
        .bottom = 0,
        .max_output_width = 0,
    };

    const byte: u8 = 0;

    var job = unwritten;
    var report: [san.SAN_JOB_REPORT_LENGTH]i64 = @splat(unwritten);
    var pixel: [4]u8 = @splat(0x5a);

    const statuses = [_]san.san_status{
        san.san_content_feed(handle, 0, &byte, 1, 0),
        san.san_content_close(handle),
        san.san_job_request(handle, &request, &job),
        san.san_job_step(handle, &report),
        san.san_job_cancel(handle),
        san.san_job_release(handle),
        san.san_output_copy(handle, 0, 1, &pixel, 1, 1, 4, 0, 0),
        san.san_output_release(handle),
    };

    for (statuses) |status| {
        if (status != san.SAN_STATUS_INVALID_HANDLE) return false;
    }

    for (report) |element| {
        if (element != unwritten) return false;
    }

    return job == san.SAN_NO_HANDLE and
        std.mem.allEqual(u8, &pixel, 0x5a);
}

fn noOtherHandle() bool {
    const engine = createEngine() orelse return false;

    const handles = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine,
        engine + next_generation,
        unwritten,
        std.math.minInt(i64),
    };

    for (handles) |handle| {
        if (!rejects(handle)) return false;
    }

    return san.san_engine_shutdown(engine) == san.SAN_STATUS_OK;
}

/// Reports whether the contents of an engine fill its table, refuse the
/// next opening, reuse a freed slot under a new handle, and end with their
/// engine, so that no handle of them names a content of a later engine.
fn contents() bool {
    const engine = createEngine() orelse return false;

    var opened: [content_slots + 1]san.san_handle = undefined;

    for (opened[0..content_slots], 1..) |*content, count| {
        content.* = openContent(engine) orelse return false;

        if (!holds(engine, @intCast(count))) return false;
    }

    var refused = unwritten;

    if (san.san_content_open(engine, &refused) !=
        san.SAN_STATUS_BUDGET_EXCEEDED) return false;

    if (refused != san.SAN_NO_HANDLE or !holds(engine, content_slots)) {
        return false;
    }

    // The freed slot serves the next opening under another handle, and
    // the handle that named it before names nothing.
    if (san.san_content_close(opened[1]) != san.SAN_STATUS_OK) return false;
    if (!holds(engine, content_slots - 1)) return false;
    if (!rejects(opened[1])) return false;

    opened[content_slots] = openContent(engine) orelse return false;

    if (!holds(engine, content_slots)) return false;

    for (opened, 0..) |content, at| {
        if (std.mem.findScalar(san.san_handle, opened[at + 1 ..], content) !=
            null) return false;
    }

    if (san.san_engine_shutdown(engine) != san.SAN_STATUS_OK) return false;

    for (opened) |content| {
        if (!rejects(content)) return false;
    }

    // A later engine, with a content in the slot of the first one,
    // still rejects every handle of the earlier engine.
    const later = createEngine() orelse return false;

    const content = openContent(later) orelse return false;

    for (opened) |earlier| {
        if (earlier == content or !rejects(earlier)) return false;
    }

    return holds(later, 1) and
        san.san_engine_shutdown(later) == san.SAN_STATUS_OK;
}

/// Requests the job of `content` for the whole image and returns its
/// handle, or null when the request fails or writes no handle.
fn requestJob(content: san.san_handle) ?san.san_handle {
    var job = unwritten;

    if (san.san_job_request(content, &whole, &job) != san.SAN_STATUS_OK) {
        return null;
    }

    if (job == san.SAN_NO_HANDLE or job == unwritten) return null;

    return job;
}

/// Reports whether `engine` counts `owned` jobs and `leased` live
/// leases. The read works while the engine shuts down.
fn counts(engine: san.san_handle, owned: i64, leased: i64) bool {
    var counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(unwritten);

    if (san.san_engine_counters(engine, 0, &counters) !=
        san.SAN_STATUS_OK) return false;

    return counters[san.SAN_ENGINE_COUNTERS_JOB_COUNT] == owned and
        counters[san.SAN_ENGINE_COUNTERS_LEASE_COUNT] == leased;
}

/// Reports whether a step of `job` returns `status` and writes every
/// element of its report as `element`.
fn steps(job: san.san_handle, status: san.san_status, element: i64) bool {
    var report = unstepped;

    return san.san_job_step(job, &report) == status and
        std.mem.allEqual(i64, &report, element);
}

/// Reports whether a job takes input, ends in its first step, refuses a
/// release before that step and a step after it, and holds the shutdown
/// of its engine pending until its release.
fn oneJob() bool {
    const engine = createEngine() orelse return false;

    const content = openContent(engine) orelse return false;

    const byte: u8 = 0x5a;

    if (san.san_content_feed(content, 0, &byte, 1, 0) !=
        san.SAN_STATUS_OK) return false;

    // The staging holds a byte that no step consumed.
    if (san.san_content_feed(content, 1, &byte, 1, 0) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    const job = requestJob(content) orelse return false;

    var second = unwritten;

    if (san.san_job_request(content, &whole, &second) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    if (second != san.SAN_NO_HANDLE or !counts(engine, 1, 1)) return false;

    if (san.san_job_release(job) !=
        san.SAN_STATUS_BINDING_MISMATCH) return false;

    // The byte is no PNG signature, so the first step ends the job, and
    // a rejected step writes no element.
    if (!steps(job, san.SAN_STATUS_INVALID_CONTENT, 0)) return false;
    if (!steps(job, san.SAN_STATUS_CLOSED, unwritten)) return false;
    if (!counts(engine, 1, 0)) return false;

    if (san.san_content_feed(content, 1, &byte, 1, 0) !=
        san.SAN_STATUS_CLOSED) return false;

    if (san.san_job_cancel(job) != san.SAN_STATUS_OK) return false;

    // The shutdown waits for the release, and the closing engine keeps
    // the counters, the cancellation, and the release.
    for (0..2) |_| {
        if (san.san_engine_shutdown(engine) !=
            san.SAN_STATUS_PENDING) return false;

        if (!counts(engine, 1, 0) or !holds(engine, 0)) return false;
        if (!steps(job, san.SAN_STATUS_CLOSED, unwritten)) return false;

        if (san.san_content_close(content) !=
            san.SAN_STATUS_CLOSED) return false;

        if (san.san_job_cancel(job) != san.SAN_STATUS_OK) return false;
    }

    if (san.san_job_release(job) != san.SAN_STATUS_OK) return false;

    if (san.san_job_release(job) !=
        san.SAN_STATUS_INVALID_HANDLE) return false;

    return san.san_engine_shutdown(engine) == san.SAN_STATUS_OK and
        rejects(job) and rejects(content);
}

/// The bytes of the lease of the tiny image with their block header.
const tiny_lease_bytes = tiny.width * tiny.height * 4 + block_header;

/// A content of an engine with its job.
const Decode = struct {
    content: san.san_handle,
    job: san.san_handle,

    /// Opens a content in `engine`, requests its job for the whole
    /// image, and feeds `bytes` in one portion, with or without the end
    /// of the input. Returns null when a call fails.
    fn start(
        engine: san.san_handle,
        bytes: []const u8,
        end_of_input: i32,
    ) ?Decode {
        const content = openContent(engine) orelse return null;

        const job = requestJob(content) orelse return null;

        const length: i32 = @intCast(bytes.len);

        if (san.san_content_feed(content, 0, bytes.ptr, length, end_of_input) !=
            san.SAN_STATUS_OK) return null;

        return .{ .content = content, .job = job };
    }

    /// Reports whether the job and the content end their handles.
    fn finish(decode: Decode) bool {
        return san.san_job_release(decode.job) == san.SAN_STATUS_OK and
            san.san_content_close(decode.content) == san.SAN_STATUS_OK;
    }
};

/// Reports whether `report` holds the geometry of the tiny image, whole
/// and at a scale of 1:1, in a lease without alpha that publishes early,
/// and no warning.
fn admitsTiny(report: Report) bool {
    const expected = [_]struct { usize, i64 }{
        .{ san.SAN_JOB_REPORT_IMAGE_WIDTH, tiny.width },
        .{ san.SAN_JOB_REPORT_IMAGE_HEIGHT, tiny.height },
        .{ san.SAN_JOB_REPORT_OUTPUT_WIDTH, tiny.width },
        .{ san.SAN_JOB_REPORT_OUTPUT_HEIGHT, tiny.height },
        .{ san.SAN_JOB_REPORT_LEASE_WIDTH, tiny.width },
        .{ san.SAN_JOB_REPORT_LEASE_HEIGHT, tiny.height },
        .{ san.SAN_JOB_REPORT_LEASE_LEFT, 0 },
        .{ san.SAN_JOB_REPORT_LEASE_TOP, 0 },
        .{ san.SAN_JOB_REPORT_ALPHA, san.SAN_ALPHA_OPAQUE },
        .{ san.SAN_JOB_REPORT_EARLY_PUBLICATION, 1 },
        .{ san.SAN_JOB_REPORT_WARNINGS, 0 },
    };

    for (expected) |element| {
        const at, const value = element;

        if (report[at] != value) return false;
    }

    return true;
}

/// Reports whether `report` names a lease at `revision` that covers
/// `rows` rows, all of which the job decoded.
fn publishes(report: Report, revision: i64, rows: i64) bool {
    const lease = report[san.SAN_JOB_REPORT_LEASE];

    return lease != san.SAN_NO_HANDLE and lease != unwritten and
        report[san.SAN_JOB_REPORT_REVISION] == revision and
        report[san.SAN_JOB_REPORT_COVERED_ROWS] == rows and
        report[san.SAN_JOB_REPORT_DECODED_ROWS] == rows;
}

/// Reports whether `engine` counts `leased` live leases that hold
/// `bytes` bytes of output. The read works while the engine shuts down.
fn leases(engine: san.san_handle, leased: i64, bytes: i64) bool {
    var counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(unwritten);

    if (san.san_engine_counters(engine, 0, &counters) !=
        san.SAN_STATUS_OK) return false;

    return counters[san.SAN_ENGINE_COUNTERS_LEASE_COUNT] == leased and
        counters[san.SAN_ENGINE_COUNTERS_OUTPUT_BYTES] == bytes;
}

/// Reports whether the first `rows` rows of `lease` copy out as the rows
/// of the tiny image with an alpha of 255, into a destination whose
/// stride holds padding: the padding and the row after the copied ones
/// stay as they were, and a copy of one row more than the coverage
/// holds is refused and writes nothing.
fn copies(lease: san.san_handle, rows: usize) bool {
    const untouched = 0xa5;
    const row_bytes = tiny.width * 4;
    const stride = row_bytes + 3;

    var destination: [(tiny.height + 1) * stride]u8 = @splat(untouched);

    const count: i32 = @intCast(rows);

    if (san.san_output_copy(
        lease,
        0,
        count + 1,
        &destination,
        tiny.width,
        tiny.height + 1,
        stride,
        0,
        san.SAN_ALPHA_OPAQUE,
    ) != san.SAN_STATUS_BINDING_MISMATCH) return false;

    if (!std.mem.allEqual(u8, &destination, untouched)) return false;

    if (san.san_output_copy(
        lease,
        0,
        count,
        &destination,
        tiny.width,
        tiny.height + 1,
        stride,
        0,
        san.SAN_ALPHA_OPAQUE,
    ) != san.SAN_STATUS_OK) return false;

    for (0..rows) |row| {
        const pixels = destination[row * stride ..][0..stride];

        for (0..tiny.width) |column| {
            const pixel = pixels[column * 4 ..][0..4];
            const expected = tiny.samples[(row * tiny.width + column) * 3 ..];

            if (!std.mem.eql(u8, pixel[0..3], expected[0..3])) return false;
            if (pixel[3] != 0xff) return false;
        }

        if (!std.mem.allEqual(u8, pixels[row_bytes..], untouched)) return false;
    }

    return std.mem.allEqual(u8, destination[rows * stride ..], untouched);
}

/// Reports whether an image decodes in one step into a lease that its
/// report names, and whether that lease copies and outlives its job and
/// its content and holds the shutdown of its engine pending until its
/// release.
fn oneDecode() bool {
    const engine = createEngine() orelse return false;

    const decode = Decode.start(engine, &tiny.bytes, 1) orelse return false;

    var report = unstepped;

    if (san.san_job_step(decode.job, &report) !=
        san.SAN_STATUS_OK) return false;

    if (!publishes(report, 1, tiny.height) or !admitsTiny(report)) return false;

    const lease = report[san.SAN_JOB_REPORT_LEASE];

    if (!copies(lease, tiny.height)) return false;
    if (!decode.finish() or !leases(engine, 1, tiny_lease_bytes)) return false;

    // The lease alone keeps the engine closing, and its copy and its
    // release work there, after its content closed.
    for (0..2) |_| {
        if (san.san_engine_shutdown(engine) !=
            san.SAN_STATUS_PENDING) return false;

        if (!copies(lease, tiny.height)) return false;
    }

    if (san.san_output_release(lease) != san.SAN_STATUS_OK) return false;

    if (san.san_output_release(lease) !=
        san.SAN_STATUS_INVALID_HANDLE) return false;

    // A released lease copies nothing, whatever the arguments.
    var pixel: [4]u8 = undefined;

    if (san.san_output_copy(lease, 0, 1, &pixel, 1, 1, 4, 0, 0) !=
        san.SAN_STATUS_INVALID_HANDLE) return false;

    return leases(engine, 0, 0) and
        san.san_engine_shutdown(engine) == san.SAN_STATUS_OK;
}

/// Reports whether rows publish before the end of their image, and
/// whether an input that ends early, a failed check of the image data,
/// and a cancellation each keep the published rows in a lease that the
/// caller releases. The failed check leaves the decoder through its
/// error path.
fn earlyOutput() bool {
    const engine = createEngine() orelse return false;

    // The input holds two of the three rows.
    const two_rows = comptime tiny.through(2);

    const cut = Decode.start(engine, tiny.bytes[0..two_rows], 0) orelse
        return false;

    var early = unstepped;

    if (san.san_job_step(cut.job, &early) !=
        san.SAN_STATUS_INPUT_NEEDED) return false;

    if (!publishes(early, 1, 2) or !admitsTiny(early)) return false;

    // The end of the input before the image repeats the publication.
    if (san.san_content_feed(cut.content, two_rows, null, 0, 1) !=
        san.SAN_STATUS_OK) return false;

    var ended = unstepped;

    if (san.san_job_step(cut.job, &ended) !=
        san.SAN_STATUS_TRUNCATED_CONTENT) return false;

    if (!std.mem.eql(i64, &early, &ended)) return false;
    if (!cut.finish()) return false;

    // The two published rows copy, and the third does not.
    if (!copies(early[san.SAN_JOB_REPORT_LEASE], 2)) return false;

    if (san.san_output_release(early[san.SAN_JOB_REPORT_LEASE]) !=
        san.SAN_STATUS_OK) return false;

    // A wrong CRC of the image data fails after every row decoded, and
    // the rows publish with the failure.
    var corrupt = tiny.bytes;

    corrupt[tiny.data_crc_at] ^= 1;

    const failed = Decode.start(engine, &corrupt, 1) orelse return false;

    var invalid = unstepped;

    if (san.san_job_step(failed.job, &invalid) !=
        san.SAN_STATUS_INVALID_CONTENT) return false;

    if (!publishes(invalid, 1, tiny.height) or !failed.finish()) return false;
    if (!copies(invalid[san.SAN_JOB_REPORT_LEASE], tiny.height)) return false;

    if (san.san_output_release(invalid[san.SAN_JOB_REPORT_LEASE]) !=
        san.SAN_STATUS_OK) return false;

    // A step that starts canceled consumes nothing and names no lease.
    const canceled = Decode.start(engine, &tiny.bytes, 1) orelse return false;

    if (san.san_job_cancel(canceled.job) != san.SAN_STATUS_OK) return false;
    if (!steps(canceled.job, san.SAN_STATUS_CANCELED, 0)) return false;
    if (!canceled.finish()) return false;

    return counts(engine, 0, 0) and leases(engine, 0, 0) and
        san.san_engine_shutdown(engine) == san.SAN_STATUS_OK;
}

/// One cancellation from another thread, and what it returned.
const Cancellation = struct {
    job: san.san_handle,
    waiting: std.atomic.Value(bool) = .init(false),
    go: std.atomic.Value(bool) = .init(false),
    status: san.san_status = san.SAN_STATUS_ENGINE_FAILURE,
};

fn cancelAtOnce(cancellation: *Cancellation) void {
    cancellation.waiting.store(true, .release);

    while (!cancellation.go.load(.acquire)) std.atomic.spinLoopHint();

    cancellation.status = san.san_job_cancel(cancellation.job);
}

/// Reports whether, in every round, a cancellation that races the step
/// of its job finds the job, and the step ends the job with one terminal
/// outcome: it completes the image and names its lease, or it is
/// canceled and publishes nothing.
fn racingCancellations() !bool {
    const engine = createEngine() orelse return false;

    for (0..cancel_rounds) |_| {
        const decode = Decode.start(engine, &tiny.bytes, 1) orelse
            return false;

        const job = decode.job;

        var cancellation: Cancellation = .{ .job = job };
        var report = unstepped;

        const thread = try std.Thread.spawn(.{}, cancelAtOnce, .{
            &cancellation,
        });

        while (!cancellation.waiting.load(.acquire)) std.atomic.spinLoopHint();

        cancellation.go.store(true, .release);

        const status = san.san_job_step(job, &report);

        // Every cancellation returns before the release of its job.
        thread.join();

        if (cancellation.status != san.SAN_STATUS_OK) return false;

        const lease = report[san.SAN_JOB_REPORT_LEASE];

        switch (status) {
            san.SAN_STATUS_OK => {
                if (!publishes(report, 1, tiny.height)) return false;
                if (!copies(lease, tiny.height)) return false;

                if (san.san_output_release(lease) !=
                    san.SAN_STATUS_OK) return false;
            },
            // The codec may have written rows before it observed the
            // flag, and the step publishes none of them.
            san.SAN_STATUS_CANCELED => {
                if (lease != san.SAN_NO_HANDLE or
                    report[san.SAN_JOB_REPORT_COVERED_ROWS] != 0) return false;
            },
            else => return false,
        }

        if (!steps(job, san.SAN_STATUS_CLOSED, unwritten)) return false;
        if (!decode.finish()) return false;
    }

    return counts(engine, 0, 0) and leases(engine, 0, 0) and
        san.san_engine_shutdown(engine) == san.SAN_STATUS_OK;
}

fn oneEngine() bool {
    const engine = createEngine() orelse return false;

    if (!refuses(1 << 20, san.SAN_STATUS_BUDGET_EXCEEDED)) return false;
    if (!engineCalls(engine)) return false;

    const invalid = [_]san.san_handle{
        san.SAN_NO_HANDLE,
        engine + next_generation,
        -engine,
        unwritten,
        std.math.minInt(i64),
    };

    for (invalid) |handle| {
        const status = san.san_engine_shutdown(handle);

        if (status != san.SAN_STATUS_INVALID_HANDLE) return false;
    }

    return san.san_engine_shutdown(engine) == san.SAN_STATUS_OK and
        san.san_engine_shutdown(engine) == san.SAN_STATUS_INVALID_HANDLE;
}

fn enginesInTurn() bool {
    var previous: san.san_handle = san.SAN_NO_HANDLE;

    for (0..run_engines) |_| {
        const engine = createEngine() orelse return false;

        if (engine == previous) return false;

        // The handle of the earlier engine names no engine now.
        if (san.san_engine_shutdown(previous) !=
            san.SAN_STATUS_INVALID_HANDLE) return false;

        if (san.san_engine_shutdown(engine) != san.SAN_STATUS_OK) return false;

        previous = engine;
    }

    return true;
}

/// The outcome of one creation of the race.
const Attempt = struct {
    status: san.san_status = san.SAN_STATUS_ENGINE_FAILURE,
    engine: san.san_handle = unwritten,
};

/// Reports whether, in every round, exactly one of the racing creations
/// succeeds and every other one fails as BudgetExceeded without a handle.
fn racingCreations() !bool {
    for (0..race_rounds) |_| {
        var attempts: [race_threads]Attempt = @splat(.{});

        try race(&attempts);

        var winner: ?san.san_handle = null;

        for (attempts) |attempt| switch (attempt.status) {
            san.SAN_STATUS_OK => {
                if (winner != null) return false;

                winner = attempt.engine;
            },
            san.SAN_STATUS_BUDGET_EXCEEDED => {
                if (attempt.engine != san.SAN_NO_HANDLE) return false;
            },
            else => return false,
        };

        const engine = winner orelse return false;

        if (san.san_engine_shutdown(engine) != san.SAN_STATUS_OK) return false;
    }

    return true;
}

/// Starts one thread per attempt, lets them create at once, and joins
/// them.
fn race(attempts: *[race_threads]Attempt) !void {
    var go: std.atomic.Value(bool) = .init(false);

    var threads: [race_threads]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();

    // The threads wait for this store, so a failed spawn still lets the
    // spawned threads finish before the join.
    defer go.store(true, .release);

    for (attempts) |*attempt| {
        threads[spawned] = try std.Thread.spawn(.{}, createAtOnce, .{
            attempt,
            &go,
        });

        spawned += 1;
    }
}

fn createAtOnce(
    attempt: *Attempt,
    go: *const std.atomic.Value(bool),
) void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();

    attempt.status = san.san_engine_create(&roomy, &attempt.engine);
}
