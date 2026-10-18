//! The typed build profile of San: the toolchain lines, the native API
//! level, the Android ABIs and their targets, and the permitted
//! combinations of ABI and optimization mode. build.zig.zon owns the
//! package metadata and the dependencies, so the profile repeats neither.
//! Every function is pure, so host tests cover the whole profile.

const std = @import("std");

/// The Zig release line that the build requires: 0.17.x.
pub const zig_minor: u32 = 17;

/// The NDK major revision that the build requires: r30.
pub const ndk_major: u32 = 30;

/// The Android API level of every artifact. The profile fixes it; no
/// option selects it.
pub const api_level: u32 = 33;

/// The ABIs of `Abi`, spelled as -Dabi takes them.
pub const abi_names = names: {
    var text: []const u8 = "";

    for (std.enums.values(Abi)) |abi| {
        text = text ++ (if (text.len == 0) "" else ", ") ++ @tagName(abi);
    }

    break :names text;
};

/// The optimization modes that `combinationSupported` permits on some
/// ABI, spelled as -Doptimize takes them.
pub const optimize_names = names: {
    var text: []const u8 = "";

    for (std.enums.values(std.lang.Optimize)) |optimize| {
        if (!supportedOnSomeAbi(optimize)) continue;

        text = text ++ (if (text.len == 0) "" else ", ") ++ @tagName(optimize);
    }

    break :names text;
};

/// An Android ABI, spelled as Android names it.
pub const Abi = enum {
    @"arm64-v8a",
    x86_64,

    /// Returns the target triple without the API level.
    pub fn triple(abi: Abi) []const u8 {
        return switch (abi) {
            .@"arm64-v8a" => "aarch64-linux-android",
            .x86_64 => "x86_64-linux-android",
        };
    }

    /// Returns the target query of the ABI at the profile's API level.
    /// On arm64-v8a the CPU features include reserve_x18, so code that
    /// Zig generates never allocates x18, which ShadowCallStack owns in
    /// the C frames.
    pub fn targetQuery(abi: Abi) std.Target.Query {
        return switch (abi) {
            .@"arm64-v8a" => .{
                .cpu_arch = .aarch64,
                .cpu_features_add = std.Target.aarch64.featureSet(&.{
                    .reserve_x18,
                }),
                .os_tag = .linux,
                .abi = .android,
                .android_api_level = api_level,
            },
            .x86_64 => .{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .android,
                .android_api_level = api_level,
            },
        };
    }
};

/// Reports whether the profile builds `abi` in `optimize`. Debug and
/// ReleaseSafe keep the safety checks. ReleaseFast and ReleaseSmall need
/// measurements and a safety review first.
pub fn combinationSupported(abi: Abi, optimize: std.lang.Optimize) bool {
    return switch (abi) {
        .@"arm64-v8a", .x86_64 => switch (optimize) {
            .debug, .safe => true,
            .fast, .small => false,
        },
    };
}

fn supportedOnSomeAbi(optimize: std.lang.Optimize) bool {
    for (std.enums.values(Abi)) |abi| {
        if (combinationSupported(abi, optimize)) return true;
    }

    return false;
}

/// Reports whether `version` belongs to the release line 0.`minor`.x.
/// Prereleases and development builds belong to no release line.
pub fn zigLineSupported(version: std.SemanticVersion, minor: u32) bool {
    return version.major == 0 and version.minor == minor and
        version.pre == null and version.build == null;
}

/// Returns the Zig minor whose release line `version` misses, or null
/// when it belongs to every required line. The profile's line is always
/// required. The verification option -Dguard-zig-minor, `guard_minor`,
/// can only add a line, so it fails the guard on the profile's compiler
/// without a second toolchain and never admits another line.
pub fn unmetZigMinor(version: std.SemanticVersion, guard_minor: ?u32) ?u32 {
    if (!zigLineSupported(version, zig_minor)) return zig_minor;

    const minor = guard_minor orelse return null;

    if (!zigLineSupported(version, minor)) return minor;

    return null;
}

/// Returns the NDK major that the revision major `major` misses, or null
/// when it meets every requirement. The profile's major is always
/// required. The verification option -Dguard-ndk-major, `guard_major`,
/// can only add a requirement and never admits another major.
pub fn unmetNdkMajor(major: u32, guard_major: ?u32) ?u32 {
    if (major != ndk_major) return ndk_major;

    const required = guard_major orelse return null;

    if (major != required) return required;

    return null;
}

/// Returns an explicit query for the architecture, OS, and ABI of
/// `host`. translate-c reads native system paths only for a native
/// query, and on macOS it then runs xcode-select and xcrun and includes
/// the SDK's headers. With this query, a host translation sees only
/// aro's own headers.
pub fn hostQuery(host: std.Target) std.Target.Query {
    return .{
        .cpu_arch = host.cpu.arch,
        .os_tag = host.os.tag,
        .abi = host.abi,
    };
}

const testing = std.testing;

const abis = [_]Abi{ .@"arm64-v8a", .x86_64 };

test "the zig line accepts the 0.17 releases only" {
    const accepted = [_][]const u8{ "0.17.0", "0.17.3" };

    const rejected = [_][]const u8{
        "0.16.0",
        "0.18.0",
        "0.17.1-dev.25+16d31ceed",
        "1.17.0",
    };

    for (accepted) |text| {
        const version = try std.SemanticVersion.parse(text);

        try testing.expect(zigLineSupported(version, zig_minor));
    }

    for (rejected) |text| {
        const version = try std.SemanticVersion.parse(text);

        try testing.expect(!zigLineSupported(version, zig_minor));
    }
}

test "the zig line follows the required minor" {
    const version = try std.SemanticVersion.parse("0.17.0");

    try testing.expect(!zigLineSupported(version, 18));
}

test "the zig guard option adds a failure and never admits a line" {
    const release = try std.SemanticVersion.parse("0.17.0");

    const next = try std.SemanticVersion.parse("0.18.0");

    const previous = try std.SemanticVersion.parse("0.16.0");

    try testing.expectEqual(null, unmetZigMinor(release, null));
    try testing.expectEqual(null, unmetZigMinor(release, zig_minor));
    try testing.expectEqual(18, unmetZigMinor(release, 18));
    try testing.expectEqual(zig_minor, unmetZigMinor(next, null));
    try testing.expectEqual(zig_minor, unmetZigMinor(next, 18));
    try testing.expectEqual(zig_minor, unmetZigMinor(previous, 16));
}

test "the ndk guard option adds a failure and never admits a major" {
    try testing.expectEqual(null, unmetNdkMajor(ndk_major, null));
    try testing.expectEqual(null, unmetNdkMajor(ndk_major, ndk_major));
    try testing.expectEqual(29, unmetNdkMajor(ndk_major, 29));
    try testing.expectEqual(31, unmetNdkMajor(ndk_major, 31));
    try testing.expectEqual(ndk_major, unmetNdkMajor(31, null));
    try testing.expectEqual(ndk_major, unmetNdkMajor(31, 31));
    try testing.expectEqual(ndk_major, unmetNdkMajor(29, 29));
}

test "the help names derive from the abis and the permitted modes" {
    try testing.expectEqualStrings("arm64-v8a, x86_64", abi_names);
    try testing.expectEqualStrings("debug, safe", optimize_names);
}

test "debug and safe are the supported modes on both abis" {
    for (abis) |abi| {
        try testing.expect(combinationSupported(abi, .debug));
        try testing.expect(combinationSupported(abi, .safe));
        try testing.expect(!combinationSupported(abi, .fast));
        try testing.expect(!combinationSupported(abi, .small));
    }
}

test "the abi targets carry the profile api level" {
    for (abis) |abi| {
        const query = abi.targetQuery();

        try testing.expectEqual(api_level, query.android_api_level.?);
        try testing.expectEqual(std.Target.Abi.android, query.abi.?);
    }

    try testing.expectEqualStrings("x86_64-linux-android", Abi.x86_64.triple());

    try testing.expectEqualStrings(
        "aarch64-linux-android",
        Abi.@"arm64-v8a".triple(),
    );
}

test "the resolved arm64-v8a target reserves x18" {
    const target = try std.zig.system.resolveTargetQuery(
        testing.io,
        Abi.@"arm64-v8a".targetQuery(),
    );

    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, target.cpu.arch);
    try testing.expect(target.cpu.has(.aarch64, .reserve_x18));
}

test "the android baseline alone does not reserve x18" {
    const baseline: std.Target.Query = .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
        .android_api_level = api_level,
    };

    const target = try std.zig.system.resolveTargetQuery(testing.io, baseline);

    try testing.expect(!target.cpu.has(.aarch64, .reserve_x18));
}

test "the host query is explicit" {
    const host = @import("builtin").target;

    const query = hostQuery(host);

    try testing.expect(!query.isNativeOs());
    try testing.expectEqual(host.cpu.arch, query.cpu_arch.?);
}
