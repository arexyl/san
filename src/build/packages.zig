//! The packages that build.zig.zon pins, as the store of an invocation
//! holds them.
//!
//! Zig 0.17.0 marks a lazy package needed on its first request. Under
//! --system, a needed package that the store lacks fails every
//! invocation, help and clean included. build.zig therefore checks the
//! availability first and requests a package only when the store holds
//! it. The check reads std.Build.package_map, a build-system
//! implementation detail; re-run the gating probe on every Zig patch
//! update.

const std = @import("std");

/// The packages of the header translation. translate-c pins aro as an
/// eager dependency in its own manifest, which the content hash of
/// translate-c covers, so aro has no entry of San's. A store that holds
/// translate-c without aro fails every invocation before build.zig runs,
/// with Zig's error that names aro. A root entry for aro, lazy as San
/// needs it, would turn that failure into a maker crash without a name.
pub const translation = [_][]const u8{"translate_c"};

/// Returns the first package of `names` that the store lacks, or null.
pub fn firstMissing(b: *std.Build, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (!available(b, name)) return name;
    }

    return null;
}

/// Reports whether the store holds the package that build.zig.zon
/// declares as `name`, without marking the package needed.
fn available(b: *std.Build, name: []const u8) bool {
    for (b.available_deps) |dep| {
        if (!std.mem.eql(u8, dep[0], name)) continue;

        const entry = std.Build.package_map.get(dep[1]) orelse return false;

        return entry.available;
    }

    std.debug.panic("build.zig.zon declares no package {s}", .{name});
}
