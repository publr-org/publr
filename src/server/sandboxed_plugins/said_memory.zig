//! What a plugin's memory held, said in the server's log: an entry that ran out of it, named
//! with the largest SDK collection the plugin made (`publr.List`, `publr.IdMap`), and a request
//! that left a plugin holding more than half of what it may. Half, as a warning before the
//! limit: derived from the limit, no number of its own.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const counted = @import("counted.zig");
const Loaded = @import("loaded.zig").Loaded;

const line_bytes_max: u32 = 512;
const Error = std.Io.Writer.Error;

/// Entry `entry` of `loaded` ended out of memory.
pub fn out_of_memory(loaded: *const Loaded, ctx: *sdk.Ctx, entry: u32) void {
    var buffer: [line_bytes_max]u8 = undefined;
    const name = loaded.name();
    const line = out_of_memory_line(&buffer, loaded, entry) catch "it ran out of memory";

    std.debug.assert(name.len > 0);

    if (ctx.lines) |lines| {
        lines.add(.{
            .plugin = name,
            .level = .err,
            .text = line,
        });

        return;
    }

    std.log.err("plugin {s}: {s}", .{ name, line });
}

fn out_of_memory_line(buffer: []u8, loaded: *const Loaded, entry: u32) Error![]const u8 {
    var named: [counted.label_len_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(buffer);

    std.debug.assert(loaded.limits.memory_mib > 0);

    try writer.print("{s} ran out of memory (it may hold {d} MiB)", .{
        entry_label(loaded, entry, &named),
        loaded.limits.memory_mib,
    });
    try cause(&writer, &loaded.largest, "it");

    return writer.buffered();
}

/// A request ended: each installed plugin that held more than half of what it may, and the
/// compiled-in plugins together, said with what was largest in it.
pub fn half_full(loaded: []const Loaded, request: *const counted.Request) void {
    var buffer: [line_bytes_max]u8 = undefined;

    std.debug.assert(loaded.len <= 1 << 16);

    for (loaded) |*plugin| {
        const held_kib = @as(u64, plugin.counted.memory_pages) * 64;
        const limit_kib = @as(u64, plugin.limits.memory_mib) * 1024;

        if (held_kib * 2 > limit_kib) {
            const largest = &plugin.largest;
            const label = request.label();
            const line = held_line(&buffer, label, held_kib, limit_kib, largest, "it") catch
                "a request left it holding more than half of what it may";

            std.log.warn("plugin {s}: {s}", .{ plugin.name(), line });
        }
    }

    if (request.plugin_bytes_max > 0 and request.plugin_bytes * 2 > request.plugin_bytes_max) {
        const line = held_line(
            &buffer,
            request.label(),
            (request.plugin_bytes + 1023) / 1024,
            request.plugin_bytes_max / 1024,
            &request.largest,
            "they",
        ) catch "a request left them holding more than half of what they may";

        std.log.warn("compiled-in plugins: {s}", .{line});
    }
}

fn held_line(
    buffer: []u8,
    label: []const u8,
    held_kib: u64,
    limit_kib: u64,
    largest: *const counted.Largest,
    comptime who: []const u8,
) Error![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);

    std.debug.assert(held_kib * 2 > limit_kib);

    try writer.print("{s} left {d} KiB held of the {d} " ++ who ++ " may hold", .{
        label,
        held_kib,
        limit_kib,
    });
    try cause(&writer, largest, who);

    return writer.buffered();
}

/// What was largest, when a collection told of it.
fn cause(
    writer: *std.Io.Writer,
    largest: *const counted.Largest,
    comptime who: []const u8,
) Error!void {
    std.debug.assert(largest.name_len <= counted.name_bytes_max);

    if (largest.kib == 0) {
        return writer.writeAll("; " ++ who ++ " made no SDK collection that grew");
    }

    try writer.print("; the largest collection " ++ who ++ " made, {s}, held {d} KiB", .{
        largest.name(),
        largest.kib,
    });
}

/// The entry as a person finds it: an operation by its name, a hook by what it runs
/// on, a job by its name.
fn entry_label(loaded: *const Loaded, entry: u32, buffer: []u8) []const u8 {
    const manifest = &loaded.manifest;
    const operations: u32 = @intCast(manifest.operations.len);
    const hooks: u32 = @intCast(manifest.hooks.len);
    const jobs: u32 = @intCast(manifest.jobs.len);

    std.debug.assert(buffer.len > 0);

    if (entry < operations) {
        return manifest.operations[entry].name;
    }

    if (entry < operations + hooks) {
        const hook = manifest.hooks[entry - operations];

        return std.fmt.bufPrint(buffer, "its {s} hook on {s}", .{
            @tagName(hook.stage),
            hook.target,
        }) catch hook.target;
    }

    if (entry < operations + hooks + jobs) {
        const job = manifest.jobs[entry - operations - hooks];

        return std.fmt.bufPrint(buffer, "its job {s}", .{job.name}) catch job.name;
    }

    return "one of its entries";
}

test "a line names the largest collection, or says none grew" {
    var buffer: [line_bytes_max]u8 = undefined;
    var largest: counted.Largest = .{};

    const none = try held_line(&buffer, "post_/cart", 9000, 16384, &largest, "it");

    try std.testing.expectEqualStrings(
        "post_/cart left 9000 KiB held of the 16384 it may hold; " ++
            "it made no SDK collection that grew",
        none,
    );

    largest.note("a publr.List of calc.Priced", 6000);
    largest.note("a publr.IdMap of u32", 100);

    const named = try held_line(&buffer, "post_/cart", 9000, 16384, &largest, "it");

    try std.testing.expectEqualStrings(
        "post_/cart left 9000 KiB held of the 16384 it may hold; the largest collection " ++
            "it made, a publr.List of calc.Priced, held 6000 KiB",
        named,
    );
}
