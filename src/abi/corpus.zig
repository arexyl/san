//! The corpus cases of the C ABI: decodes of three fixtures of a reader
//! corpus through the functions of the Bindings header, as a caller
//! makes them. The host tests of this file run every case against a
//! directory that the caller names, and the Android harness of the C
//! ABI runs those that it lists. San holds no fixture of the corpus.
//!
//! A case that scales compares its pixels with the area average of the
//! same image decoded at the image size: for each sample, the sum over
//! the pixels that its grid cell covers, without the row-by-row sums of
//! the engine.
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
const large_path = "qualification/timed/large.png";

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
};

/// The value of every byte of a destination that no copy wrote.
const untouched: u8 = 0xa5;

/// A destination of rows of `width` pixels with a padded stride, which
/// no copy has written.
const Canvas = struct {
    pixels: []u8,
    rows: i32,
    row_bytes: usize,

    const padding = 16;

    fn init(arena: Allocator, width: i32, rows: i32) Error!Canvas {
        const row_bytes = @as(usize, @intCast(width)) * 4;
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

/// One engine with one content and its job.
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

    fn start(
        limits: san.san_engine_limits,
        request: san.san_output_request,
    ) Error!Decode {
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
            san.san_job_request(decode.content, &request, &decode.job),
        );

        return decode;
    }

    /// Feeds `bytes` from the bytes received on, in portions with a step
    /// after each, until a step returns another status than
    /// SAN_STATUS_INPUT_NEEDED, and ends the input with the last portion.
    /// Returns that status. A job that completes before the end of
    /// `bytes` leaves the rest unfed.
    fn run(decode: *Decode, bytes: []const u8) Error!san.san_status {
        while (true) {
            const length = @min(bytes.len - decode.fed, portion_bytes);
            const last = decode.fed + length == bytes.len;

            try expectStatus(san.SAN_STATUS_OK, san.san_content_feed(
                decode.content,
                @intCast(decode.fed),
                bytes[decode.fed..].ptr,
                @intCast(length),
                @intFromBool(last),
            ));

            decode.fed += length;

            const status = try decode.step();

            if (last or status != san.SAN_STATUS_INPUT_NEEDED) return status;
        }
    }

    /// Releases the job, the content, and the held lease of a case that
    /// is done, and ends the engine.
    fn finish(decode: Decode) Error!void {
        try expectStatus(san.SAN_STATUS_OK, san.san_job_release(decode.job));

        try expectStatus(
            san.SAN_STATUS_OK,
            san.san_content_close(decode.content),
        );

        try expectStatus(
            san.SAN_STATUS_OK,
            san.san_output_release(decode.lease),
        );

        try expectStatus(
            san.SAN_STATUS_OK,
            san.san_engine_shutdown(decode.engine),
        );
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
    fn copy(decode: Decode, canvas: Canvas, rows: i32) san.san_status {
        return san.san_output_copy(
            decode.lease,
            0,
            rows,
            canvas.pixels.ptr,
            @intCast(canvas.row_bytes / 4),
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
    var hash: Sha256 = .init(.{});

    try hashRows(arena, &hash, canvas, canvas.rows);

    return hash.finalResult();
}

/// Adds the RGB samples of the first `rows` rows of `canvas` to `hash`.
fn hashRows(
    arena: Allocator,
    hash: *Sha256,
    canvas: Canvas,
    rows: i32,
) Error!void {
    const width = canvas.row_bytes / 4;

    const samples = try arena.alloc(u8, width * 3);

    for (0..@intCast(rows)) |index| {
        const row = canvas.row(index);

        for (0..width) |column| {
            const pixel = row[column * 4 ..][0..4];

            if (pixel[3] != 0xff) return error.UnexpectedPixels;

            samples[column * 3 ..][0..3].* = pixel[0..3].*;
        }

        hash.update(samples);
    }
}

/// The request of the image rows [top, bottom) of `fixture` at every
/// column, in a grid of at most `max_output_width` columns, or at the
/// image size for 0.
fn rowsOf(
    fixture: Fixture,
    top: i32,
    bottom: i32,
    max_output_width: i32,
) san.san_output_request {
    return .{
        .left = 0,
        .top = top,
        .right = fixture.width,
        .bottom = bottom,
        .max_output_width = max_output_width,
    };
}

/// The output grid and the lease of an admitted job.
const Shape = struct {
    grid_width: i64,
    grid_height: i64,
    /// The rows of the lease, and its first row in the grid.
    rows: i64,
    top: i64,

    /// Returns the grid of `fixture` at `width` columns, with the height
    /// rounded to the nearest row, halves up, and the lease of the grid
    /// rows [top, bottom).
    fn of(fixture: Fixture, width: i64, top: i64, bottom: i64) Shape {
        const image_width: i64 = fixture.width;
        const image_height: i64 = fixture.height;

        const height = @divFloor(
            2 * image_height * width + image_width,
            2 * image_width,
        );

        return .{
            .grid_width = width,
            .grid_height = @max(1, height),
            .rows = bottom - top,
            .top = top,
        };
    }
};

/// Checks the elements that the admission step of `fixture` writes for
/// an admitted lease of `shape`, which holds every column of its grid.
fn expectShape(report: Report, fixture: Fixture, shape: Shape) Error!void {
    const expected = [_]struct { usize, i64 }{
        .{ san.SAN_JOB_REPORT_IMAGE_WIDTH, fixture.width },
        .{ san.SAN_JOB_REPORT_IMAGE_HEIGHT, fixture.height },
        .{ san.SAN_JOB_REPORT_OUTPUT_WIDTH, shape.grid_width },
        .{ san.SAN_JOB_REPORT_OUTPUT_HEIGHT, shape.grid_height },
        .{ san.SAN_JOB_REPORT_LEASE_WIDTH, shape.grid_width },
        .{ san.SAN_JOB_REPORT_LEASE_HEIGHT, shape.rows },
        .{ san.SAN_JOB_REPORT_LEASE_LEFT, 0 },
        .{ san.SAN_JOB_REPORT_LEASE_TOP, shape.top },
        .{ san.SAN_JOB_REPORT_ALPHA, san.SAN_ALPHA_OPAQUE },
        .{ san.SAN_JOB_REPORT_EARLY_PUBLICATION, 1 },
        .{ san.SAN_JOB_REPORT_WARNINGS, 0 },
    };

    for (expected) |element| {
        const index, const value = element;

        if (report[index] != value) return error.UnexpectedReport;
    }
}

/// Decodes the image rows [top, bottom) of `fixture` at the image size
/// into the top of `canvas`, whose rows are unwritten. A band that ends
/// above the last row of the image completes at its last row, with
/// exactly the rows down to it decoded.
fn decodeBand(
    fixture: Fixture,
    canvas: Canvas,
    top: i32,
    bottom: i32,
) Error!void {
    var decode: Decode =
        try .start(page_limits, rowsOf(fixture, top, bottom, 0));
    errdefer decode.abandon();

    try expectStatus(san.SAN_STATUS_OK, try decode.run(fixture.bytes));

    const report = decode.report;
    const rows = bottom - top;

    if (report[san.SAN_JOB_REPORT_COVERED_ROWS] != rows or
        report[san.SAN_JOB_REPORT_DECODED_ROWS] != bottom)
    {
        return error.UnexpectedReport;
    }

    try expectShape(
        report,
        fixture,
        .of(fixture, fixture.width, top, bottom),
    );

    try expectStatus(san.SAN_STATUS_OK, decode.copy(canvas, rows));
    try canvas.expectRest(rows);
    try decode.finish();
}

/// Checks that the rows of `scaled`, the grid rows from `shape.top` on,
/// are the area average of the image of `fixture`, whose rows from
/// `first` on `reference` holds at the image size. Each sample is the
/// sum over the pixels that its grid cell covers, each times the part
/// of it that the cell covers on either axis, divided by the area of
/// the image and rounded to the nearest value, halves up.
fn expectAverage(
    fixture: Fixture,
    reference: Canvas,
    first: usize,
    scaled: Canvas,
    shape: Shape,
) Error!void {
    const image_width: u64 = @intCast(fixture.width);
    const image_height: u64 = @intCast(fixture.height);
    const width: u64 = @intCast(shape.grid_width);
    const height: u64 = @intCast(shape.grid_height);
    const area = image_width * image_height;
    const top: u64 = @intCast(shape.top);

    for (0..@intCast(shape.rows)) |index| {
        const row_low = (top + index) * image_height;
        const row_high = row_low + image_height;

        for (0..@intCast(width)) |column| {
            const column_low = column * image_width;
            const column_high = column_low + image_width;

            var sums: [3]u64 = @splat(0);
            var y = row_low / height;

            while (y * height < row_high) : (y += 1) {
                const rows = @min((y + 1) * height, row_high) -
                    @max(y * height, row_low);

                const source = reference.row(@intCast(y - first));

                var x = column_low / width;

                while (x * width < column_high) : (x += 1) {
                    const columns = @min((x + 1) * width, column_high) -
                        @max(x * width, column_low);

                    const pixel = source[@intCast(x * 4)..][0..3];

                    for (&sums, pixel) |*sum, sample| {
                        sum.* += rows * columns * sample;
                    }
                }
            }

            const pixel = scaled.row(index)[column * 4 ..][0..4];

            for (sums, pixel[0..3]) |sum, sample| {
                if ((sum + area / 2) / area != sample) {
                    return error.UnexpectedPixels;
                }
            }

            if (pixel[3] != 0xff) return error.UnexpectedPixels;
        }
    }
}

/// The rows of one band of the long segment at the image size: one
/// reference viewport at the width of the segment.
const band_rows = 2560;

/// The columns of the reference viewport, which the scaled cases request.
const viewport_width = 1080;

/// Decodes the long segment at the image size in bands of one viewport
/// each, every band in a job of its own under the ceiling of one lease
/// that refuses the whole segment. The samples of the bands in order
/// hash to the value of the manifest for the whole image.
pub fn joinsLongBands(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
) Error!void {
    const fixture: Fixture = try .read(io, arena, directory, long_path);

    const canvas: Canvas = try .init(arena, fixture.width, band_rows);

    var hash: Sha256 = .init(.{});
    var top: i32 = 0;

    while (top < fixture.height) : (top += band_rows) {
        const bottom = @min(top + band_rows, fixture.height);

        @memset(canvas.pixels, untouched);
        try decodeBand(fixture, canvas, top, bottom);
        try hashRows(arena, &hash, canvas, bottom - top);
    }

    if (!std.mem.eql(u8, &hash.finalResult(), &fixture.samples)) {
        return error.UnexpectedPixels;
    }
}

/// Decodes one viewport in the middle of the long segment, scaled to
/// the width of the reference viewport. The region lies one image row
/// inside the edges of its grid rows, so the job takes one image row
/// above and one below it. The job completes at its last image row,
/// before the end of the input, and its rows are the area average of
/// the same image rows at the image size.
pub fn scalesLongBand(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
) Error!void {
    const fixture: Fixture = try .read(io, arena, directory, long_path);

    // Four image rows scale to three grid rows, so these edges are
    // edges of grid rows.
    const top = 18720;
    const bottom = top + band_rows;

    if (bottom >= fixture.height or fixture.width != 1440) {
        return error.ManifestUnusable;
    }

    const reference: Canvas = try .init(arena, fixture.width, band_rows);

    try decodeBand(fixture, reference, top, bottom);

    var decode: Decode = try .start(
        page_limits,
        rowsOf(fixture, top + 1, bottom - 1, viewport_width),
    );
    errdefer decode.abandon();

    try expectStatus(san.SAN_STATUS_OK, try decode.run(fixture.bytes));

    if (decode.fed == fixture.bytes.len) return error.UnexpectedReport;

    const shape: Shape = .of(
        fixture,
        viewport_width,
        top / 4 * 3,
        bottom / 4 * 3,
    );

    const report = decode.report;

    if (report[san.SAN_JOB_REPORT_COVERED_ROWS] != shape.rows or
        report[san.SAN_JOB_REPORT_DECODED_ROWS] != bottom)
    {
        return error.UnexpectedReport;
    }

    try expectShape(report, fixture, shape);

    const scaled: Canvas =
        try .init(arena, viewport_width, @intCast(shape.rows));

    try expectStatus(
        san.SAN_STATUS_OK,
        decode.copy(scaled, @intCast(shape.rows)),
    );

    try scaled.expectRest(@intCast(shape.rows));
    try expectAverage(fixture, reference, top, scaled, shape);
    try decode.finish();
}

/// Decodes the first viewport of the long segment, scaled to the width
/// of the reference viewport, with its payload withheld at the hold
/// point. The bytes before the hold publish every grid row that the
/// image rows of the hold complete, which copy while the rest of the
/// payload is withheld. The released payload completes the band in the
/// same lease, before the end of the input, and leaves the rows that
/// copied early as they were.
pub fn publishesTopBand(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
) Error!void {
    const fixture: Fixture = try .read(io, arena, directory, long_path);

    if (fixture.height <= band_rows or fixture.held_rows >= band_rows) {
        return error.ManifestUnusable;
    }

    var decode: Decode = try .start(
        page_limits,
        rowsOf(fixture, 0, band_rows, viewport_width),
    );
    errdefer decode.abandon();

    try expectStatus(
        san.SAN_STATUS_INPUT_NEEDED,
        try decode.advance(fixture.bytes, fixture.held_from, false),
    );

    var shape: Shape = .of(fixture, viewport_width, 0, 0);

    // The band is one viewport of the grid.
    shape.rows = @divExact(
        @as(i64, band_rows) * shape.grid_height,
        fixture.height,
    );

    // A grid row is complete when the image rows of the hold reach its
    // lower edge.
    const held: i32 = @intCast(@divFloor(
        @as(i64, fixture.held_rows) * shape.grid_height,
        fixture.height,
    ));

    const early = decode.report;

    if (early[san.SAN_JOB_REPORT_COVERED_ROWS] != held or
        early[san.SAN_JOB_REPORT_DECODED_ROWS] != fixture.held_rows)
    {
        return error.UnexpectedReport;
    }

    try expectShape(early, fixture, shape);

    const first: Canvas = try .init(arena, viewport_width, held);

    try expectStatus(san.SAN_STATUS_OK, decode.copy(first, held));
    try first.expectRest(held);
    try expectStatus(san.SAN_STATUS_OK, try decode.run(fixture.bytes));

    if (decode.fed == fixture.bytes.len) return error.UnexpectedReport;

    const final = decode.report;

    if (final[san.SAN_JOB_REPORT_COVERED_ROWS] != shape.rows or
        final[san.SAN_JOB_REPORT_DECODED_ROWS] != band_rows)
    {
        return error.UnexpectedReport;
    }

    const band: Canvas =
        try .init(arena, viewport_width, @intCast(shape.rows));

    try expectStatus(
        san.SAN_STATUS_OK,
        decode.copy(band, @intCast(shape.rows)),
    );

    // A later revision never changes a covered row.
    for (0..@intCast(held)) |index| {
        if (!std.mem.eql(u8, first.row(index), band.row(index))) {
            return error.UnexpectedPixels;
        }
    }

    try decode.finish();
}

/// The limits of a reader with room for the large page at the image
/// size in one lease.
const large_limits: san.san_engine_limits = roomy: {
    var limits = page_limits;

    limits.aggregate_budget_bytes = 1 << 30;
    limits.output_bytes = 128 << 20;
    limits.output_lease_bytes = 128 << 20;

    break :roomy limits;
};

/// Decodes the large page scaled to the width of the reference viewport
/// under the ceiling of one lease that refuses it at the image size.
/// The bytes before the hold publish every grid row that the image
/// rows of the hold complete, and the whole output is the area average
/// of the page at the image size, whose samples hash to the value of
/// the manifest.
pub fn scalesLarge(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
) Error!void {
    const fixture: Fixture = try .read(io, arena, directory, large_path);

    const reference: Canvas = try .init(arena, fixture.width, fixture.height);

    {
        var decode: Decode = try .start(large_limits, whole);
        errdefer decode.abandon();

        try expectStatus(san.SAN_STATUS_OK, try decode.run(fixture.bytes));
        try expectRows(decode.report, fixture.height);
        try expectGeometry(decode.report, fixture, true);

        try expectStatus(
            san.SAN_STATUS_OK,
            decode.copy(reference, fixture.height),
        );

        try decode.finish();
    }

    const samples = try samplesOf(arena, reference);

    if (!std.mem.eql(u8, &samples, &fixture.samples)) {
        return error.UnexpectedPixels;
    }

    var decode: Decode = try .start(
        page_limits,
        rowsOf(fixture, 0, fixture.height, viewport_width),
    );
    errdefer decode.abandon();

    try expectStatus(
        san.SAN_STATUS_INPUT_NEEDED,
        try decode.advance(fixture.bytes, fixture.held_from, false),
    );

    var shape: Shape = .of(fixture, viewport_width, 0, 0);

    shape.rows = shape.grid_height;

    // A grid row is complete when the image rows of the hold reach its
    // lower edge.
    const held = @divFloor(
        @as(i64, fixture.held_rows) * shape.grid_height,
        fixture.height,
    );

    const early = decode.report;

    if (early[san.SAN_JOB_REPORT_COVERED_ROWS] != held or
        early[san.SAN_JOB_REPORT_DECODED_ROWS] != fixture.held_rows)
    {
        return error.UnexpectedReport;
    }

    try expectShape(early, fixture, shape);

    try expectStatus(
        san.SAN_STATUS_OK,
        try decode.advance(fixture.bytes, fixture.bytes.len, true),
    );

    const final = decode.report;

    if (final[san.SAN_JOB_REPORT_COVERED_ROWS] != shape.rows or
        final[san.SAN_JOB_REPORT_DECODED_ROWS] != fixture.height)
    {
        return error.UnexpectedReport;
    }

    try expectShape(final, fixture, shape);

    const scaled: Canvas =
        try .init(arena, viewport_width, @intCast(shape.rows));

    try expectStatus(
        san.SAN_STATUS_OK,
        decode.copy(scaled, @intCast(shape.rows)),
    );

    try scaled.expectRest(@intCast(shape.rows));
    try expectAverage(fixture, reference, 0, scaled, shape);
    try decode.finish();
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

    var decode: Decode = try .start(page_limits, whole);
    errdefer decode.abandon();

    try expectStatus(
        san.SAN_STATUS_INPUT_NEEDED,
        try decode.advance(fixture.bytes, fixture.held_from, false),
    );

    const early = decode.report;

    try expectRows(early, fixture.held_rows);
    try expectGeometry(early, fixture, true);

    // One row more than the coverage holds is refused and writes nothing.
    const held: Canvas =
        try .init(arena, fixture.width, fixture.held_rows + 1);

    try expectStatus(
        san.SAN_STATUS_BINDING_MISMATCH,
        decode.copy(held, fixture.held_rows + 1),
    );

    try held.expectRest(0);

    try expectStatus(
        san.SAN_STATUS_OK,
        decode.copy(held, fixture.held_rows),
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

    const image: Canvas = try .init(arena, fixture.width, fixture.height);

    try expectStatus(
        san.SAN_STATUS_OK,
        decode.copy(image, fixture.height),
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

    var decode: Decode = try .start(segment_limits, whole);
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

test "the bands of the long segment join into its samples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try expectBound();
    try joinsLongBands(testing.io, arena_state.allocator(), corpus_directory);
}

test "a scaled band of the long segment is the average of its rows" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try expectBound();
    try scalesLongBand(testing.io, arena_state.allocator(), corpus_directory);
}

test "the first band of the long segment publishes its held rows" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try expectBound();

    try publishesTopBand(
        testing.io,
        arena_state.allocator(),
        corpus_directory,
    );
}

test "the scaled large page is the average of the page" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try expectBound();
    try scalesLarge(testing.io, arena_state.allocator(), corpus_directory);
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
