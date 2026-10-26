//! The Android harness of libsan_png_test.so, the device test library of
//! the PNG decoder. It needs the library through DT_NEEDED, generates
//! its test images with fixtures.zig, and passes each decode to the
//! library's one export. It runs beside the library on the device:
//! `LD_LIBRARY_PATH=. ./san-png-harness <mode>`.
//!
//! Modes:
//! - `generated`: valid images with every filter type at RGB8 and RGBA8,
//!   every case of the strictness table in every split, truncation at
//!   every cut, bytes after IEND in the same portion and in a later one,
//!   a large text chunk whole and split under a tight budget, header-only
//!   images, and the guard of rows that zlib cannot count.
//! - `inject`: one refused allocation at every allocation of a valid
//!   decode, whole and bytewise, then every budget up to its peak.
//! - `cancel`: a cancellation after every row, whole and bytewise.
//! - `stress`: 1000 decodes that fail through libpng's error path, then
//!   1000 cancellations.
//! - `file <path> <category> [reason=<name>] [rows=<n>] [color=<0|1>]`:
//!   the file whole, bytewise, and in seeded portions, each expected to
//!   end in the category, and in the reason, row count, and color flag
//!   that are given.
//!
//! Every decode must also settle its heap and keep the ledger equal to
//! the backing at every callback. The harness prints one line per case,
//! ending in `ok` or `FAIL`, then a summary. It exits 0 only when every
//! case passes, 1 when a case fails, and 2 on a usage error or a file
//! that it cannot read.

const std = @import("std");
const Decoder = @import("Decoder.zig");
const cases = @import("cases.zig");
const device_case = @import("device_case.zig");
const fixtures = @import("fixtures.zig");

const Allocator = std.mem.Allocator;
const Category = device_case.Category;
const Request = device_case.Request;
const Result = device_case.Result;

pub const panic = @import("engine").android_panic;

pub const std_options: std.Options = .{
    // A fault reaches the system's crash handler unchanged, so that the
    // tombstone records the faulting frame.
    .enable_segfault_handler = false,
};

/// The one export of libsan_png_test.so.
extern fn san_png_device_test(request: *const Request, result: *Result) void;

/// A budget that admits every decode of the harness.
const roomy: u64 = 64 << 20;

/// The repetitions of each stress loop.
const stress_runs = 1000;

/// The failed runs of a loop that the harness prints before its summary.
const shown_failures = 10;

/// The largest file of the file mode.
const max_file_len = 64 << 20;

const usage =
    \\usage: san-png-harness generated | inject | cancel | stress
    \\       san-png-harness file <path> <category> [reason=<name>]
    \\                       [rows=<n>] [color=<0|1>]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var buffer: [4096]u8 = undefined;

    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);

    var harness: Harness = .{ .gpa = init.gpa, .out = &stdout.interface };

    const mode = if (args.len >= 2) args[1] else "";

    if (args.len == 2 and std.mem.eql(u8, mode, "generated")) {
        try harness.generated();
    } else if (args.len == 2 and std.mem.eql(u8, mode, "inject")) {
        try harness.inject();
    } else if (args.len == 2 and std.mem.eql(u8, mode, "cancel")) {
        try harness.cancel();
    } else if (args.len == 2 and std.mem.eql(u8, mode, "stress")) {
        try harness.stress();
    } else if (args.len >= 4 and std.mem.eql(u8, mode, "file")) {
        const expectation = Expectation.parse(args[3..]) orelse {
            try std.Io.File.stderr().writeStreamingAll(io, usage);

            return 2;
        };

        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            args[2],
            init.gpa,
            .limited(max_file_len),
        ) catch |err| {
            const message = try std.fmt.allocPrint(
                init.arena.allocator(),
                "san-png-harness: cannot read {s}: {t}\n",
                .{ args[2], err },
            );

            try std.Io.File.stderr().writeStreamingAll(io, message);

            return 2;
        };
        defer init.gpa.free(bytes);

        try harness.file(std.fs.path.basename(args[2]), bytes, expectation);
    } else {
        try std.Io.File.stderr().writeStreamingAll(io, usage);

        return 2;
    }

    try harness.out.print("summary passed={d} failed={d}\n", .{
        harness.passed,
        harness.failed,
    });

    try harness.out.flush();

    return if (harness.failed == 0) 0 else 1;
}

/// The plan of a request, printed as `whole`, `bytewise`, `seeded:<seed>`,
/// `split:<offset>`, or `prefix:<length>`.
const PlanText = struct {
    plan: cases.Plan,

    pub fn format(
        text: PlanText,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (text.plan) {
            .whole, .bytewise => try writer.writeAll(@tagName(text.plan)),
            .seeded => |seed| try writer.print("seeded:{d}", .{seed}),
            .split => |at| try writer.print("split:{d}", .{at}),
            .prefix => |len| try writer.print("prefix:{d}", .{len}),
        }
    }
};

fn planText(plan: cases.Plan) PlanText {
    return .{ .plan = plan };
}

/// Returns the name of the adapter's reason `code`.
fn reasonName(code: i32) []const u8 {
    const reason: Decoder.Reason = @fromBackingInt(code);

    return std.enums.tagName(Decoder.Reason, reason) orelse "unknown";
}

/// Reports whether a decode settled its heap and kept the ledger equal to
/// the backing at every callback.
fn healthy(result: Result) bool {
    return result.settled and result.mismatches == 0;
}

/// What the file mode expects of each decode of its file.
const Expectation = struct {
    category: Category,
    reason: ?Decoder.Reason = null,
    rows: ?u32 = null,
    color: ?bool = null,

    /// Parses the category and the optional `key=value` expectations
    /// after it, or returns null on an unknown name or a malformed value.
    fn parse(args: []const [:0]const u8) ?Expectation {
        var expectation: Expectation = .{
            .category = std.meta.stringToEnum(Category, args[0]) orelse
                return null,
        };

        for (args[1..]) |arg| {
            const equals = std.mem.findScalar(u8, arg, '=') orelse
                return null;

            const key = arg[0..equals];
            const value = arg[equals + 1 ..];

            if (std.mem.eql(u8, key, "reason")) {
                expectation.reason = std.meta.stringToEnum(
                    Decoder.Reason,
                    value,
                ) orelse return null;
            } else if (std.mem.eql(u8, key, "rows")) {
                expectation.rows = std.fmt.parseUnsigned(u32, value, 10) catch
                    return null;
            } else if (std.mem.eql(u8, key, "color")) {
                const flag = std.meta.stringToEnum(Flag, value) orelse
                    return null;

                expectation.color = flag == .@"1";
            } else {
                return null;
            }
        }

        return expectation;
    }

    const Flag = enum { @"0", @"1" };

    fn meets(expectation: Expectation, result: Result) bool {
        if (result.category != expectation.category) return false;

        if (expectation.reason) |reason| {
            if (result.reason != @backingInt(reason)) return false;
        }

        if (expectation.rows) |rows| {
            if (result.rows != rows) return false;
        }

        if (expectation.color) |color| {
            if (result.color_warning != color) return false;
        }

        return healthy(result);
    }
};

const Harness = struct {
    gpa: Allocator,
    out: *std.Io.Writer,
    passed: u32 = 0,
    failed: u32 = 0,

    fn decode(_: *const Harness, request: Request) Result {
        var result: Result = .{};

        san_png_device_test(&request, &result);

        return result;
    }

    /// Prints the line of one case: its label from `format` and `args`,
    /// what the decode observed, and the verdict. The line reaches the
    /// output at once, so a crash leaves every earlier line behind.
    fn report(
        harness: *Harness,
        passed: bool,
        result: Result,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        if (passed) harness.passed += 1 else harness.failed += 1;

        try harness.line(if (passed) "ok" else "FAIL", result, format, args);
    }

    /// Prints a line for one failed run of a loop. The loop's summary
    /// counts as its case.
    fn detail(
        harness: *Harness,
        result: Result,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try harness.line("FAIL", result, format, args);
    }

    fn line(
        harness: *Harness,
        verdict: []const u8,
        result: Result,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        const out = harness.out;

        try out.print(format, args);

        try out.print(" -> {t} reason={s} rows={d} headers={d} " ++
            "warnings={d} color={d}", .{
            result.category,
            reasonName(result.reason),
            result.rows,
            result.headers,
            result.warnings,
            @intFromBool(result.color_warning),
        });

        if (result.has_header) {
            try out.print(" header={d}x{d}", .{
                result.header.width,
                result.header.height,
            });
        }

        try out.print(" crc={x:0>8} peak={d} allocations={d} live={d} " ++
            "blocks={d} settled={d} mismatches={d} {s}\n", .{
            result.checksum,
            result.peak,
            result.allocations,
            result.live,
            result.blocks,
            @intFromBool(result.settled),
            result.mismatches,
            verdict,
        });

        try out.flush();
    }

    /// Returns the encoded image of `spec`, which the caller frees.
    fn encode(harness: *const Harness, spec: fixtures.Spec) ![]u8 {
        return fixtures.encode(harness.gpa, spec);
    }

    /// Reports whether `result` delivered exactly the writer's samples of
    /// `spec`, each row once and in order.
    fn delivered(
        harness: *const Harness,
        spec: fixtures.Spec,
        result: Result,
    ) !bool {
        if (result.category != .success) return false;
        if (result.rows != spec.height or result.headers != 1) return false;

        const expected = try fixtures.samples(harness.gpa, spec);
        defer harness.gpa.free(expected);

        return result.checksum == std.hash.Crc32.hash(expected);
    }

    fn generated(harness: *Harness) !void {
        try harness.validImages();
        try harness.strictness();
        try harness.truncation();
        try harness.trailing();
        try harness.largeText();
        try harness.headerOnly();
        try harness.rowGuard();
    }

    /// Valid images that reach every filter type at RGB8 and RGBA8, with
    /// a stored or a fixed Huffman final block, and an axis above
    /// libpng's default limit.
    fn validImages(harness: *Harness) !void {
        const sizes = [_][2]u32{
            .{ 1, 1 },
            .{ 67, 53 },
            .{ 4096, 2 },
            .{ 2, 4096 },
        };

        const filters = [_]fixtures.Filters{
            .{ .all = .none },
            .{ .all = .sub },
            .{ .all = .up },
            .{ .all = .average },
            .{ .all = .paeth },
            .cycle,
        };

        for (sizes) |size| {
            for ([_]fixtures.Format{ .rgb8, .rgba8 }) |format| {
                for (filters) |filter| {
                    for ([_]fixtures.Block{ .stored, .fixed }) |block| {
                        try harness.validImage(.{
                            .width = size[0],
                            .height = size[1],
                            .format = format,
                            .filters = filter,
                            .final_block = block,
                        });
                    }
                }
            }
        }

        try harness.validImage(.{
            .width = 2_000_000,
            .height = 1,
            .format = .gray8,
        });
    }

    fn validImage(harness: *Harness, spec: fixtures.Spec) !void {
        const bytes = try harness.encode(spec);
        defer harness.gpa.free(bytes);

        const result = harness.decode(.init(bytes, .whole, roomy));

        const passed = try harness.delivered(spec, result) and
            result.warnings == 0 and healthy(result);

        const filter = switch (spec.filters) {
            .all => |all| @tagName(all),
            .cycle => "cycle",
        };

        try harness.report(
            passed,
            result,
            "generated valid {d}x{d} {t} filters={s} block={t} plan=whole",
            .{ spec.width, spec.height, spec.format, filter, spec.final_block },
        );
    }

    /// Every case of the strictness table in every plan of the table.
    fn strictness(harness: *Harness) !void {
        for (cases.strictness) |case| {
            const bytes = try harness.encode(case.spec);
            defer harness.gpa.free(bytes);

            for (cases.plans) |plan| {
                const result = harness.decode(.init(bytes, plan, roomy));

                try harness.report(
                    try harness.meetsCase(case, result),
                    result,
                    "generated strictness \"{s}\" plan={f} expected={t} " ++
                        "reason={t}",
                    .{
                        case.name,
                        planText(plan),
                        Category.expected(case),
                        case.reason,
                    },
                );
            }
        }
    }

    /// Reports whether `result` meets `case`, as the host tests check it.
    fn meetsCase(
        harness: *const Harness,
        case: cases.Case,
        result: Result,
    ) !bool {
        if (result.category != Category.expected(case)) return false;

        if (case.expected == null) {
            if (!try harness.delivered(case.spec, result)) return false;
        }

        if (result.reason != @backingInt(case.reason)) return false;
        if (result.color_warning != case.color_warning) return false;
        if (result.headers > 1) return false;
        if (case.rowless and result.rows != 0) return false;
        if (case.headerless and result.headers != 0) return false;

        if (case.warned) {
            if (result.warnings == 0) return false;
        } else if (case.expected == null) {
            if (result.warnings != 0) return false;
        }

        return healthy(result);
    }

    /// Every prefix of an image ends as TruncatedContent before its last
    /// byte, and every split of it decodes.
    fn truncation(harness: *Harness) !void {
        const spec: fixtures.Spec = .{
            .width = 3,
            .height = 2,
            .before = &.{ fixtures.gama, cases.short_text },
            .idat_size = 9,
        };

        const bytes = try harness.encode(spec);
        defer harness.gpa.free(bytes);

        for (0..bytes.len + 1) |cut| {
            const prefix: cases.Plan = .{ .prefix = cut };

            const truncated = harness.decode(.init(bytes, prefix, roomy));

            const complete = cut == bytes.len;

            const cut_short = truncated.category == .truncated_content and
                truncated.reason == @backingInt(Decoder.Reason.truncated);

            const passed = if (complete)
                try harness.delivered(spec, truncated)
            else
                cut_short;

            try harness.report(
                passed and healthy(truncated),
                truncated,
                "generated truncation plan={f}",
                .{planText(prefix)},
            );

            const split: cases.Plan = .{ .split = cut };

            const whole = harness.decode(.init(bytes, split, roomy));

            try harness.report(
                try harness.delivered(spec, whole) and healthy(whole),
                whole,
                "generated truncation plan={f}",
                .{planText(split)},
            );
        }
    }

    /// Bytes after IEND fail in the same portion and in a later one, and
    /// an empty portion after IEND is no byte after it.
    fn trailing(harness: *Harness) !void {
        const spec: fixtures.Spec = .{ .width = 3, .height = 2 };

        const valid = try harness.encode(spec);
        defer harness.gpa.free(valid);

        const end: cases.Plan = .{ .split = valid.len };

        const empty = harness.decode(.init(valid, end, roomy));

        try harness.report(
            try harness.delivered(spec, empty) and healthy(empty),
            empty,
            "generated trailing none plan={f}",
            .{planText(end)},
        );

        var with_bytes = spec;

        with_bytes.faults.trailing = 8;

        const bytes = try harness.encode(with_bytes);
        defer harness.gpa.free(bytes);

        for ([_]cases.Plan{ .whole, end, .bytewise }) |plan| {
            const result = harness.decode(.init(bytes, plan, roomy));

            const passed = result.category == .invalid_content and
                result.reason == @backingInt(Decoder.Reason.trailing) and
                result.rows == spec.height and healthy(result);

            try harness.report(
                passed,
                result,
                "generated trailing 8 bytes plan={f}",
                .{planText(plan)},
            );
        }
    }

    /// libpng's push reader holds a chunk that spans portions whole in its
    /// save buffer, so a large text chunk costs its length in the budget
    /// only when the input splits it.
    fn largeText(harness: *Harness) !void {
        const text = try harness.gpa.alloc(u8, 64 * 1024);
        defer harness.gpa.free(text);

        const plain_spec: fixtures.Spec = .{ .width = 4, .height = 4 };

        const plain = try harness.encode(plain_spec);
        defer harness.gpa.free(plain);

        const reference = harness.decode(.init(plain, .whole, roomy));

        try harness.report(
            try harness.delivered(plain_spec, reference) and healthy(reference),
            reference,
            "generated large text reference plan=whole",
            .{},
        );

        // Less room to spare than the text's length.
        const budget = reference.peak + 4096;

        for ([_][4]u8{ "tEXt".*, "iTXt".* }) |name| {
            const spec: fixtures.Spec = .{
                .width = 4,
                .height = 4,
                .before = &.{.{ .name = name, .data = fixtures.text(text) }},
            };

            const bytes = try harness.encode(spec);
            defer harness.gpa.free(bytes);

            const whole = harness.decode(.init(bytes, .whole, budget));

            try harness.report(
                try harness.delivered(spec, whole) and healthy(whole),
                whole,
                "generated large text {s} budget={d} plan=whole",
                .{ &name, budget },
            );

            const middle: cases.Plan = .{
                .split = fixtures.header_len + 8 + text.len / 2,
            };

            const split = harness.decode(.init(bytes, middle, budget));

            try harness.report(
                split.category == .budget_exceeded and healthy(split),
                split,
                "generated large text {s} budget={d} plan={f}",
                .{ &name, budget, planText(middle) },
            );
        }
    }

    /// A header alone gives its geometry, then TruncatedContent.
    fn headerOnly(harness: *Harness) !void {
        const geometries = [_][2]u32{
            .{ 2_000_000, 1 },
            .{ 65_534, 1 },
            .{ 65_535, 1 },
            .{ 65_536, 1 },
            .{ 8_000, 8_000 },
            .{ 1, 64_000_001 },
            .{ 0x7fff_ffff, 0x7fff_ffff },
        };

        for (geometries) |geometry| {
            const bytes = try harness.encode(.{
                .width = geometry[0],
                .height = geometry[1],
                .idat = false,
            });
            defer harness.gpa.free(bytes);

            const plan: cases.Plan = .{ .prefix = fixtures.header_len };

            const result = harness.decode(.init(bytes, plan, roomy));

            const found = result.header;

            const passed = result.category == .truncated_content and
                result.has_header and found.width == geometry[0] and
                found.height == geometry[1] and
                found.row_bytes == 3 * @as(u64, geometry[0]);

            try harness.report(
                passed and healthy(result),
                result,
                "generated header only {d}x{d} plan={f}",
                .{ geometry[0], geometry[1], planText(plan) },
            );
        }
    }

    /// A row of 2^32 - 1 bytes or more fails before the header callback,
    /// because the push reader counts a row and its filter byte in zlib's
    /// 32-bit count. A row of 2^32 - 4 bytes passes the guard and then
    /// exceeds the budget with libpng's row buffer.
    fn rowGuard(harness: *Harness) !void {
        const rows = [_]struct { u32, fixtures.Format, Category }{
            .{ 0x7fff_ffff, .rgba8, .invalid_content },
            .{ 1_431_655_765, .rgb8, .invalid_content },
            .{ 1_431_655_764, .rgb8, .budget_exceeded },
        };

        for (rows) |row| {
            const bytes = try harness.encode(.{
                .width = row[0],
                .height = 1,
                .format = row[1],
                .idat = false,
                .after = &.{.{ .name = "IDAT".*, .data = &.{ 0x78, 0x01 } }},
            });
            defer harness.gpa.free(bytes);

            const result = harness.decode(.init(bytes, .whole, roomy));

            const guarded = row[2] == .invalid_content;

            const reason: Decoder.Reason = if (guarded) .geometry else .libpng;

            const passed = result.category == row[2] and
                result.reason == @backingInt(reason) and
                result.headers == @intFromBool(!guarded) and healthy(result);

            try harness.report(
                passed,
                result,
                "generated row guard {d}x1 {t} plan=whole",
                .{ row[0], row[1] },
            );
        }
    }

    /// One refused allocation at every allocation of a valid decode, then
    /// every budget up to the decode's peak, whole and bytewise.
    fn inject(harness: *Harness) !void {
        const bytes = try harness.encode(cases.small);
        defer harness.gpa.free(bytes);

        for ([_]cases.Plan{ .whole, .bytewise }) |plan| {
            const reference = harness.decode(.init(bytes, plan, roomy));

            const valid = try harness.delivered(cases.small, reference) and
                !reference.injected and healthy(reference);

            try harness.report(
                valid,
                reference,
                "inject reference plan={f}",
                .{planText(plan)},
            );

            for (0..reference.allocations) |index| {
                var request: Request = .init(bytes, plan, roomy);

                request.fail_at = index;

                const result = harness.decode(request);

                const passed = result.category == .allocation_failed and
                    result.injected and healthy(result);

                try harness.report(
                    passed,
                    result,
                    "inject fail_at={d} plan={f}",
                    .{ index, planText(plan) },
                );
            }

            try harness.budgets(bytes, plan, reference.peak);
        }
    }

    /// Every budget below `peak` fails as BudgetExceeded and settles, and
    /// the budget of `peak` decodes. One summary line counts as the case.
    fn budgets(
        harness: *Harness,
        bytes: []const u8,
        plan: cases.Plan,
        peak: u64,
    ) !void {
        var failures: u64 = 0;

        var last: Result = .{};

        var budget: u64 = 1;

        while (budget <= peak) : (budget += 1) {
            const result = harness.decode(.init(bytes, plan, budget));

            const refused = result.category == .budget_exceeded;

            const passed = healthy(result) and if (budget < peak)
                refused
            else
                try harness.delivered(cases.small, result);

            if (!passed) {
                failures += 1;

                if (failures <= shown_failures) {
                    try harness.detail(
                        result,
                        "inject budget={d} plan={f}",
                        .{ budget, planText(plan) },
                    );
                }
            }

            last = result;
        }

        try harness.report(
            peak > 1 and failures == 0,
            last,
            "inject budgets 1..{d} plan={f} failed={d}",
            .{ peak, planText(plan), failures },
        );
    }

    /// A cancellation after every row of a valid image ends the decode
    /// within one row.
    fn cancel(harness: *Harness) !void {
        const spec: fixtures.Spec = .{
            .width = 8,
            .height = 24,
            .filters = .cycle,
            .idat_size = 37,
        };

        const bytes = try harness.encode(spec);
        defer harness.gpa.free(bytes);

        for ([_]cases.Plan{ .whole, .bytewise }) |plan| {
            for (0..spec.height) |row| {
                var request: Request = .init(bytes, plan, roomy);

                request.cancel_row = @intCast(row);

                const result = harness.decode(request);

                const passed = result.category == .canceled and
                    result.rows == row + 1 and
                    result.reason == @backingInt(Decoder.Reason.stopped) and
                    healthy(result);

                try harness.report(
                    passed,
                    result,
                    "cancel row={d} plan={f}",
                    .{ row, planText(plan) },
                );
            }
        }
    }

    /// Repeated jumps: decodes that libpng ends with an error, then
    /// cancellations at every row in turn.
    fn stress(harness: *Harness) !void {
        const failing: fixtures.Spec = .{
            .width = 6,
            .height = 5,
            .faults = .{ .filter_byte = .{ .row = 2, .value = 5 } },
        };

        const failing_bytes = try harness.encode(failing);
        defer harness.gpa.free(failing_bytes);

        var failures: u32 = 0;

        var last: Result = .{};

        for (0..stress_runs) |run| {
            const result = harness.decode(.init(failing_bytes, .whole, roomy));

            const passed = result.category == .invalid_content and
                result.reason == @backingInt(Decoder.Reason.libpng) and
                healthy(result);

            if (!passed) {
                failures += 1;

                if (failures <= shown_failures) {
                    try harness.detail(result, "stress error run={d}", .{run});
                }
            }

            last = result;
        }

        try harness.report(
            failures == 0,
            last,
            "stress errors runs={d} failed={d} plan=whole",
            .{ stress_runs, failures },
        );

        const spec: fixtures.Spec = .{
            .width = 8,
            .height = 24,
            .filters = .cycle,
            .idat_size = 37,
        };

        const bytes = try harness.encode(spec);
        defer harness.gpa.free(bytes);

        failures = 0;

        for (0..stress_runs) |run| {
            const row: u32 = @intCast(run % spec.height);

            var request: Request = .init(bytes, .whole, roomy);

            request.cancel_row = row;

            const result = harness.decode(request);

            const passed = result.category == .canceled and
                result.rows == row + 1 and healthy(result);

            if (!passed) {
                failures += 1;

                if (failures <= shown_failures) {
                    try harness.detail(
                        result,
                        "stress cancel run={d} row={d}",
                        .{ run, row },
                    );
                }
            }

            last = result;
        }

        try harness.report(
            failures == 0,
            last,
            "stress cancellations runs={d} failed={d} plan=whole",
            .{ stress_runs, failures },
        );
    }

    /// Decodes a file whole, bytewise, and in seeded portions.
    fn file(
        harness: *Harness,
        name: []const u8,
        bytes: []const u8,
        expectation: Expectation,
    ) !void {
        const plans = [_]cases.Plan{ .whole, .bytewise, .{ .seeded = 1 } };

        for (plans) |plan| {
            const result = harness.decode(.init(bytes, plan, roomy));

            try harness.report(
                expectation.meets(result),
                result,
                "file {s} bytes={d} plan={f} expected={t}",
                .{ name, bytes.len, planText(plan), expectation.category },
            );
        }
    }
};
