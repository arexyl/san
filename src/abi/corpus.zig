//! The corpus cases of the C ABI: decodes of two fixtures of a reader
//! corpus through the functions of the Bindings header, as a caller
//! makes them. The host tests of this file and the Android harness of
//! the C ABI run the same cases against a directory that the caller
//! names. San holds no fixture of the corpus.
//!
//! The directory holds `manifest.json` and the fixtures at the paths
//! that it states. For each fixture of a case, the manifest gives the
//! length and the hash of the file, the geometry of the image, the hash
//! of its RGB samples, and a hold point: an offset after a whole IDAT
//! chunk, before which the file holds exactly the first rows that the
//! hold counts. A case first checks its file against the manifest, so
//! that a changed corpus fails as itself and not as a wrong decode.
//!
//! A case runs with the binding established and no engine live, and it
//! leaves no engine live.

const std = @import("std");
const builtin = @import("builtin");
const san = @import("san");

comptime {
    // A test binary holds the C ABI itself, as a module of its own. The
    // Android harness takes the functions from its library.
    if (builtin.is_test) _ = @import("abi");
}

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

pub const Error = error{
    /// A file of the corpus is missing or cannot be read.
    CorpusUnreadable,
    /// The manifest does not parse, has another schema, or does not
    /// state a fixture as its case needs it.
    ManifestUnusable,
    /// A fixture differs from what the manifest states.
    FixtureChanged,
    /// A call returned another status than its case expects.
    UnexpectedStatus,
    /// A report holds another element than its case expects.
    UnexpectedReport,
    /// Copied pixels differ from the samples of the image.
    UnexpectedPixels,
    OutOfMemory,
};

const manifest_path = "manifest.json";
const manifest_schema = 1;

/// A page of 1600 by 2400 pixels, whose lease fits the ceiling of one
/// lease, and a segment of 1440 by 40000 pixels, whose lease does not.
const ordinary_path = "journey/ordinary.png";
const long_path = "journey/long.png";

/// The largest file that a case reads, above the largest of the corpus.
const max_file_bytes = 32 << 20;

/// The bytes of one feed.
const portion_bytes = 64 << 10;

/// The limits of a reader with a ceiling of 16 MiB for one lease, which
/// the lease of the ordinary page fits. The image limits admit both
/// fixtures.
const page_limits: san.san_engine_limits = .{
    .aggregate_budget_bytes = 64 << 20,
    .content_count = 1,
    .job_count = 1,
    .content_length_bytes = 16 << 20,
    .input_portion_bytes = portion_bytes,
    .image_axis_pixels = 1 << 16,
    .image_area_pixels = 1 << 26,
    .metadata_bytes = 1 << 20,
    .metadata_expanded_bytes = 1 << 20,
    .metadata_payload_bytes = 1 << 20,
    .held_chunk_bytes = 1 << 20,
    .icc_tag_count = 64,
    .exif_entry_count = 64,
    .output_bytes = 16 << 20,
    .output_lease_bytes = 16 << 20,
    .output_lease_count = 1,
};

/// The same limits with room for the lease of the long segment in the
/// budget and in all output, so that only the ceiling of one lease
/// refuses it. A refusal reserves nothing of that room.
const segment_limits: san.san_engine_limits = roomy: {
    var limits = page_limits;

    limits.aggregate_budget_bytes = 1 << 30;
    limits.output_bytes = 1 << 30;

    break :roomy limits;
};

/// The request of the whole image at a scale of 1:1.
const whole: san.san_output_request = .{
    .left = 0,
    .top = 0,
    .right = 0,
    .bottom = 0,
    .max_output_width = 0,
};

/// The fields of the manifest that the cases read.
const Manifest = struct {
    schema_version: i64,
    artifacts: []const Artifact,

    const Artifact = struct {
        path: []const u8,
        bytes: u64,
        sha256: []const u8,
        width: ?i32 = null,
        height: ?i32 = null,
        hold: ?Hold = null,
        master: ?Master = null,
    };

    const Hold = struct {
        offset: u64,
        prefix_sha256: []const u8,
        source_rows: i32,
    };

    const Master = struct {
        rgb_sha256: []const u8,
    };
};

/// A fixture with a hold point, read and checked against the manifest.
const Fixture = struct {
    bytes: []const u8,
    width: i32,
    height: i32,
    /// The hash of the RGB samples of the image, row by row.
    samples: Digest,
    /// The bytes before `held_from` hold exactly the first `held_rows`
    /// rows, and fewer rows than the image has.
    held_from: usize,
    held_rows: i32,

    fn read(
        io: std.Io,
        arena: Allocator,
        directory: []const u8,
        path: []const u8,
    ) Error!Fixture {
        const text = try readFile(io, arena, directory, manifest_path);

        const manifest = std.json.parseFromSliceLeaky(
            Manifest,
            arena,
            text,
            .{ .ignore_unknown_fields = true },
        ) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return error.ManifestUnusable,
        };

        if (manifest.schema_version != manifest_schema) {
            return error.ManifestUnusable;
        }

        const stated = for (manifest.artifacts) |artifact| {
            if (std.mem.eql(u8, artifact.path, path)) break artifact;
        } else return error.ManifestUnusable;

        const hold = stated.hold orelse return error.ManifestUnusable;
        const master = stated.master orelse return error.ManifestUnusable;
        const width = stated.width orelse return error.ManifestUnusable;
        const height = stated.height orelse return error.ManifestUnusable;

        if (width < 1 or height < 1) return error.ManifestUnusable;

        if (hold.source_rows < 1 or hold.source_rows >= height) {
            return error.ManifestUnusable;
        }

        const bytes = try readFile(io, arena, directory, path);

        if (bytes.len != stated.bytes) return error.FixtureChanged;

        if (hold.offset < 1 or hold.offset >= bytes.len) {
            return error.ManifestUnusable;
        }

        const held_from: usize = @intCast(hold.offset);

        try expectDigest(bytes, stated.sha256);
        try expectDigest(bytes[0..held_from], hold.prefix_sha256);

        return .{
            .bytes = bytes,
            .width = width,
            .height = height,
            .samples = try digestOf(master.rgb_sha256),
            .held_from = held_from,
            .held_rows = hold.source_rows,
        };
    }

    /// The bytes of one row of the lease.
    fn rowBytes(fixture: Fixture) usize {
        return @as(usize, @intCast(fixture.width)) * 4;
    }
};

/// The value of every byte of a destination that no copy wrote.
const untouched: u8 = 0xa5;

/// A destination of rows of a fixture with a padded stride, which no
/// copy has written.
const Canvas = struct {
    pixels: []u8,
    rows: i32,
    row_bytes: usize,

    const padding = 16;

    fn init(arena: Allocator, fixture: Fixture, rows: i32) Error!Canvas {
        const row_bytes = fixture.rowBytes();
        const count: usize = @intCast(rows);

        const pixels = try arena.alloc(u8, count * (row_bytes + padding));

        @memset(pixels, untouched);

        return .{ .pixels = pixels, .rows = rows, .row_bytes = row_bytes };
    }

    fn stride(canvas: Canvas) usize {
        return canvas.row_bytes + padding;
    }

    /// The pixels of the row `index`, without its padding.
    fn row(canvas: Canvas, index: usize) []const u8 {
        return canvas.pixels[index * canvas.stride() ..][0..canvas.row_bytes];
    }

    /// Checks that a copy of the first `written` rows left the padding
    /// of each of them and every later row as they were.
    fn expectRest(canvas: Canvas, written: i32) Error!void {
        const count: usize = @intCast(written);

        for (0..count) |index| {
            const end = (index + 1) * canvas.stride();

            if (!std.mem.allEqual(
                u8,
                canvas.pixels[end - padding .. end],
                untouched,
            )) return error.UnexpectedPixels;
        }

        const rest = canvas.pixels[count * canvas.stride() ..];

        if (!std.mem.allEqual(u8, rest, untouched)) {
            return error.UnexpectedPixels;
        }
    }
};

fn readFile(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
    path: []const u8,
) Error![]const u8 {
    const full = try std.fs.path.join(arena, &.{ directory, path });

    return std.Io.Dir.cwd().readFileAlloc(
        io,
        full,
        arena,
        .limited(max_file_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.CorpusUnreadable,
    };
}

/// Returns the digest that the manifest states as `hex`.
fn digestOf(hex: []const u8) Error!Digest {
    var digest: Digest = undefined;

    if (hex.len != digest.len * 2) return error.ManifestUnusable;

    _ = std.fmt.hexToBytes(&digest, hex) catch return error.ManifestUnusable;

    return digest;
}

fn expectDigest(bytes: []const u8, hex: []const u8) Error!void {
    const stated = try digestOf(hex);

    var found: Digest = undefined;

    Sha256.hash(bytes, &found, .{});

    if (!std.mem.eql(u8, &found, &stated)) return error.FixtureChanged;
}

fn expectStatus(expected: san.san_status, status: san.san_status) Error!void {
    if (status != expected) return error.UnexpectedStatus;
}

const Report = [san.SAN_JOB_REPORT_LENGTH]i64;

/// One engine with one content and its job for the whole image.
const Decode = struct {
    engine: san.san_handle,
    content: san.san_handle,
    job: san.san_handle,
    /// The bytes that the content received.
    fed: usize = 0,
    /// The report of the latest step, and zeros before the first.
    report: Report = @splat(0),
    /// The lease of the first report that named one, which the case
    /// holds from then on.
    lease: san.san_handle = san.SAN_NO_HANDLE,

    fn start(limits: san.san_engine_limits) Error!Decode {
        var engine: san.san_handle = san.SAN_NO_HANDLE;

        try expectStatus(
            san.SAN_STATUS_OK,
            san.san_engine_create(&limits, &engine),
        );

        // A failed call below leaves the engine to `abandon`.
        var decode: Decode = .{
            .engine = engine,
            .content = san.SAN_NO_HANDLE,
            .job = san.SAN_NO_HANDLE,
        };
        errdefer decode.abandon();

        try expectStatus(
            san.SAN_STATUS_OK,
            san.san_content_open(engine, &decode.content),
        );

        try expectStatus(
            san.SAN_STATUS_OK,
            san.san_job_request(decode.content, &whole, &decode.job),
        );

        return decode;
    }

    /// Feeds `bytes` from the bytes received up to `upto`, in portions
    /// with a step after each, and ends the input with the last portion
    /// when `end_of_input` holds. Every step before the last returns
    /// SAN_STATUS_INPUT_NEEDED. Returns the status of the last step.
    fn advance(
        decode: *Decode,
        bytes: []const u8,
        upto: usize,
        end_of_input: bool,
    ) Error!san.san_status {
        while (true) {
            const length = @min(upto - decode.fed, portion_bytes);
            const last = decode.fed + length == upto;

            try expectStatus(san.SAN_STATUS_OK, san.san_content_feed(
                decode.content,
                @intCast(decode.fed),
                bytes[decode.fed..].ptr,
                @intCast(length),
                @intFromBool(last and end_of_input),
            ));

            decode.fed += length;

            const status = try decode.step();

            if (last) return status;

            try expectStatus(san.SAN_STATUS_INPUT_NEEDED, status);
        }
    }

    /// Steps the job and keeps its report. Across steps, the coverage
    /// never falls, and the revision rises by one exactly in a step that
    /// extends the coverage. The first publication names the lease, and
    /// no later report names another.
    fn step(decode: *Decode) Error!san.san_status {
        const before = decode.report;

        const status = san.san_job_step(decode.job, &decode.report);

        const report = decode.report;
        const named = report[san.SAN_JOB_REPORT_LEASE];

        if (decode.lease == san.SAN_NO_HANDLE) decode.lease = named;

        if (named != decode.lease) return error.UnexpectedReport;

        const extended = report[san.SAN_JOB_REPORT_COVERED_ROWS] -
            before[san.SAN_JOB_REPORT_COVERED_ROWS];

        if (extended < 0) return error.UnexpectedReport;

        const revision = before[san.SAN_JOB_REPORT_REVISION] +
            @intFromBool(extended > 0);

        if (report[san.SAN_JOB_REPORT_REVISION] != revision) {
            return error.UnexpectedReport;
        }

        if ((revision == 0) != (named == san.SAN_NO_HANDLE)) {
            return error.UnexpectedReport;
        }

        return status;
    }

    /// Copies the first `rows` rows of the lease to the top of `canvas`.
    fn copy(
        decode: Decode,
        fixture: Fixture,
        canvas: Canvas,
        rows: i32,
    ) san.san_status {
        return san.san_output_copy(
            decode.lease,
            0,
            rows,
            canvas.pixels.ptr,
            fixture.width,
            canvas.rows,
            @intCast(canvas.stride()),
            0,
            san.SAN_ALPHA_OPAQUE,
        );
    }

    /// Ends the engine of a failed case as far as the calls allow, so
    /// that the next case finds none live.
    fn abandon(decode: Decode) void {
        _ = san.san_engine_shutdown(decode.engine);
        _ = san.san_job_release(decode.job);
        _ = san.san_output_release(decode.lease);
        _ = san.san_engine_shutdown(decode.engine);
    }
};

/// Checks the elements that the admission step of `fixture` writes: the
/// image and its grid at a scale of 1:1, and the lease of the whole
/// image when the step admitted it, or zeros when it refused it.
fn expectGeometry(report: Report, fixture: Fixture, admitted: bool) Error!void {
    const width: i64 = fixture.width;
    const height: i64 = fixture.height;
    const lease: i64 = @intFromBool(admitted);

    const expected = [_]struct { usize, i64 }{
        .{ san.SAN_JOB_REPORT_IMAGE_WIDTH, width },
        .{ san.SAN_JOB_REPORT_IMAGE_HEIGHT, height },
        .{ san.SAN_JOB_REPORT_OUTPUT_WIDTH, width },
        .{ san.SAN_JOB_REPORT_OUTPUT_HEIGHT, height },
        .{ san.SAN_JOB_REPORT_LEASE_WIDTH, lease * width },
        .{ san.SAN_JOB_REPORT_LEASE_HEIGHT, lease * height },
        .{ san.SAN_JOB_REPORT_LEASE_LEFT, 0 },
        .{ san.SAN_JOB_REPORT_LEASE_TOP, 0 },
        .{ san.SAN_JOB_REPORT_ALPHA, lease * san.SAN_ALPHA_OPAQUE },
        .{ san.SAN_JOB_REPORT_EARLY_PUBLICATION, lease },
        .{ san.SAN_JOB_REPORT_WARNINGS, 0 },
    };

    for (expected) |element| {
        const index, const value = element;

        if (report[index] != value) return error.UnexpectedReport;
    }
}

/// Checks that `report` covers and has decoded exactly `rows` rows.
fn expectRows(report: Report, rows: i64) Error!void {
    if (report[san.SAN_JOB_REPORT_COVERED_ROWS] != rows or
        report[san.SAN_JOB_REPORT_DECODED_ROWS] != rows)
    {
        return error.UnexpectedReport;
    }
}

/// Returns the hash of the RGB samples of the rows of `canvas`, which
/// hold an image in the pixel profile. Every pixel of an image without
/// alpha has an alpha of 255.
fn samplesOf(arena: Allocator, canvas: Canvas) Error!Digest {
    const width = canvas.row_bytes / 4;

    const samples = try arena.alloc(u8, width * 3);

    var hash: Sha256 = .init(.{});

    for (0..@intCast(canvas.rows)) |index| {
        const row = canvas.row(index);

        for (0..width) |column| {
            const pixel = row[column * 4 ..][0..4];

            if (pixel[3] != 0xff) return error.UnexpectedPixels;

            samples[column * 3 ..][0..3].* = pixel[0..3].*;
        }

        hash.update(samples);
    }

    return hash.finalResult();
}

/// Decodes the ordinary page with its payload withheld at the hold
/// point. The bytes before the hold publish exactly the rows of the
/// hold, which copy while the rest of the payload is withheld. The
/// released payload completes the image in the same lease, the rows
/// that copied early are the rows of the whole image, and the samples
/// of the whole image hash to the value of the manifest.
pub fn decodesOrdinary(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
) Error!void {
    const fixture: Fixture = try .read(io, arena, directory, ordinary_path);

    var decode: Decode = try .start(page_limits);
    errdefer decode.abandon();

    try expectStatus(
        san.SAN_STATUS_INPUT_NEEDED,
        try decode.advance(fixture.bytes, fixture.held_from, false),
    );

    const early = decode.report;

    try expectRows(early, fixture.held_rows);
    try expectGeometry(early, fixture, true);

    // One row more than the coverage holds is refused and writes nothing.
    const held: Canvas = try .init(arena, fixture, fixture.held_rows + 1);

    try expectStatus(
        san.SAN_STATUS_BINDING_MISMATCH,
        decode.copy(fixture, held, fixture.held_rows + 1),
    );

    try held.expectRest(0);

    try expectStatus(
        san.SAN_STATUS_OK,
        decode.copy(fixture, held, fixture.held_rows),
    );

    try held.expectRest(fixture.held_rows);

    // A step without new bytes publishes nothing.
    try expectStatus(san.SAN_STATUS_INPUT_NEEDED, try decode.step());

    if (!std.mem.eql(i64, &early, &decode.report)) {
        return error.UnexpectedReport;
    }

    try expectStatus(
        san.SAN_STATUS_OK,
        try decode.advance(fixture.bytes, fixture.bytes.len, true),
    );

    const final = decode.report;

    if (final[san.SAN_JOB_REPORT_REVISION] <=
        early[san.SAN_JOB_REPORT_REVISION]) return error.UnexpectedReport;

    try expectRows(final, fixture.height);
    try expectGeometry(final, fixture, true);

    const image: Canvas = try .init(arena, fixture, fixture.height);

    try expectStatus(
        san.SAN_STATUS_OK,
        decode.copy(fixture, image, fixture.height),
    );

    try image.expectRest(fixture.height);

    // A later revision never changes a covered row.
    for (0..@intCast(fixture.held_rows)) |index| {
        if (!std.mem.eql(u8, held.row(index), image.row(index))) {
            return error.UnexpectedPixels;
        }
    }

    const samples = try samplesOf(arena, image);

    if (!std.mem.eql(u8, &samples, &fixture.samples)) {
        return error.UnexpectedPixels;
    }

    try expectStatus(san.SAN_STATUS_OK, san.san_job_release(decode.job));
    try expectStatus(san.SAN_STATUS_OK, san.san_content_close(decode.content));

    // The held lease alone keeps the shutdown pending.
    try expectStatus(
        san.SAN_STATUS_PENDING,
        san.san_engine_shutdown(decode.engine),
    );

    try expectStatus(
        san.SAN_STATUS_OK,
        san.san_output_release(decode.lease),
    );

    try expectStatus(san.SAN_STATUS_OK, san.san_engine_shutdown(decode.engine));
}

/// Requests the long segment whole at a scale of 1:1 under the ceiling
/// of one lease that admits the ordinary page. Its admission step ends
/// the job as SAN_STATUS_BUDGET_EXCEEDED for that ceiling alone, and it
/// reports the image and the grid, so that a request that fits can
/// follow, and no lease.
pub fn refusesLong(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
) Error!void {
    const fixture: Fixture = try .read(io, arena, directory, long_path);

    // The case feeds one whole portion, which holds the header of the
    // image, and then one byte more.
    if (fixture.bytes.len <= portion_bytes) return error.ManifestUnusable;

    var decode: Decode = try .start(segment_limits);
    errdefer decode.abandon();

    try expectStatus(
        san.SAN_STATUS_BUDGET_EXCEEDED,
        try decode.advance(fixture.bytes, portion_bytes, false),
    );

    const refused = decode.report;

    // The step checks that a report without a revision names no lease.
    if (refused[san.SAN_JOB_REPORT_REVISION] != 0) {
        return error.UnexpectedReport;
    }

    try expectRows(refused, 0);
    try expectGeometry(refused, fixture, false);

    // The refusal is terminal, and it kept no output.
    try expectStatus(san.SAN_STATUS_CLOSED, san.san_content_feed(
        decode.content,
        portion_bytes,
        fixture.bytes[portion_bytes..].ptr,
        1,
        0,
    ));

    var counters: [san.SAN_ENGINE_COUNTERS_LENGTH]i64 = @splat(-1);

    try expectStatus(
        san.SAN_STATUS_OK,
        san.san_engine_counters(decode.engine, 0, &counters),
    );

    if (counters[san.SAN_ENGINE_COUNTERS_LEASE_COUNT] != 0 or
        counters[san.SAN_ENGINE_COUNTERS_OUTPUT_BYTES] != 0)
    {
        return error.UnexpectedReport;
    }

    try expectStatus(san.SAN_STATUS_OK, san.san_job_release(decode.job));
    try expectStatus(san.SAN_STATUS_OK, san.san_content_close(decode.content));
    try expectStatus(san.SAN_STATUS_OK, san.san_engine_shutdown(decode.engine));
}

const testing = std.testing;

/// The directory of -Dcorpus.
const corpus_directory = @import("corpus_options").directory;

fn expectBound() !void {
    try testing.expectEqual(
        san.SAN_STATUS_OK,
        san.san_binding_establish(san.SAN_ABI_VERSION),
    );
}

test "the ordinary page publishes its held rows and decodes to its samples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try expectBound();
    try decodesOrdinary(testing.io, arena_state.allocator(), corpus_directory);
}

test "the lease of the long segment is refused with its geometry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try expectBound();
    try refusesLong(testing.io, arena_state.allocator(), corpus_directory);
}

test "a manifest states its digests as 64 hexadecimal digits" {
    const zeros: [64]u8 = @splat('0');
    const letters: [64]u8 = @splat('z');

    try testing.expectEqual(@as(Digest, @splat(0)), try digestOf(&zeros));
    try testing.expectError(error.ManifestUnusable, digestOf(zeros[2..]));
    try testing.expectError(error.ManifestUnusable, digestOf(&zeros ++ "00"));
    try testing.expectError(error.ManifestUnusable, digestOf(&letters));
    try testing.expectError(error.FixtureChanged, expectDigest("", &zeros));

    // The digest of the empty input.
    try expectDigest("", "e3b0c44298fc1c149afbf4c8996fb924" ++
        "27ae41e4649b934ca495991b7852b855");
}
