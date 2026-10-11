//! What one type and one entry may hold, chosen when Publr is built (`-Dtype-fields-max`,
//! `-Dentry-values-max`, `-Dentry-bytes-max`, `-Drequest-bytes-max`): generous by default, as
//! every Cloud project shares one build. Written as `limits_options`, which `model/limits.zig`
//! reads and derives every budget from, and into the plugin SDK, so a plugin built by this
//! binary sees the same.
const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const Limits = struct {
    /// Fields a type holds at one level (a group or repeater holds as many again inside).
    type_fields_max: u32 = 256,
    /// Values one entry holds, every field and every repeater item's together.
    entry_values_max: u32 = 2000,
    /// One entry's document, as saved.
    entry_bytes_max: u32 = 512 << 10,
    /// One request, as it arrives.
    request_bytes_max: u32 = 1 << 20,
};

pub fn from(builder: *std.Build) Limits {
    std.debug.assert(builder.build_root.path != null);

    const defaults: Limits = .{};
    const chosen: Limits = .{
        .type_fields_max = builder.option(
            u32,
            "type-fields-max",
            "Fields a type holds at one level (default: 256)",
        ) orelse defaults.type_fields_max,
        .entry_values_max = builder.option(
            u32,
            "entry-values-max",
            "Values one entry holds in all (default: 2000)",
        ) orelse defaults.entry_values_max,
        .entry_bytes_max = builder.option(
            u32,
            "entry-bytes-max",
            "One entry's document in bytes (default: 524288)",
        ) orelse defaults.entry_bytes_max,
        .request_bytes_max = builder.option(
            u32,
            "request-bytes-max",
            "One request in bytes (default: 1048576)",
        ) orelse defaults.request_bytes_max,
    };

    check(chosen);

    return chosen;
}

fn check(limits: Limits) void {
    if (limits.type_fields_max < 16 or limits.type_fields_max > 4096) {
        diagnostic.fail("-Dtype-fields-max is 16 to 4096", .{});
    }

    if (limits.entry_values_max < 256 or limits.entry_values_max > 65536) {
        diagnostic.fail("-Dentry-values-max is 256 to 65536", .{});
    }

    if (limits.entry_bytes_max < 64 << 10 or limits.entry_bytes_max > 64 << 20) {
        diagnostic.fail("-Dentry-bytes-max is 65536 to 67108864", .{});
    }

    // An entry arrives whole in one request (a save, an autosave), with room around it.
    if (limits.request_bytes_max < limits.entry_bytes_max + (64 << 10)) {
        diagnostic.fail("-Drequest-bytes-max must hold an entry and 64 KiB more", .{});
    }

    std.debug.assert(limits.request_bytes_max > limits.entry_bytes_max);
}

/// The limits as Zig, the one form both the build and the plugin SDK carry.
pub fn source(builder: *std.Build, limits: Limits) []const u8 {
    std.debug.assert(limits.type_fields_max > 0);
    std.debug.assert(limits.entry_values_max > 0);

    return builder.fmt(
        \\//! Written by `build/limits.zig`.
        \\pub const type_fields_max: u32 = {d};
        \\pub const entry_values_max: u32 = {d};
        \\pub const entry_bytes_max: u32 = {d};
        \\pub const request_bytes_max: u32 = {d};
        \\
    , .{
        limits.type_fields_max,
        limits.entry_values_max,
        limits.entry_bytes_max,
        limits.request_bytes_max,
    });
}

pub fn module(builder: *std.Build, limits: Limits) *std.Build.Module {
    std.debug.assert(builder.build_root.path != null);

    const files = builder.addWriteFiles();
    const file = files.add("limits_options.zig", source(builder, limits));

    return builder.createModule(.{
        .root_source_file = file,
    });
}
