const std = @import("std");
const builtin = @import("builtin");

pub const message_len_max: u32 = 1024;

const red_bold = "\x1b[1;31m";
const yellow_bold = "\x1b[1;33m";
const Level = enum { err, warn };
const reset = "\x1b[0m";
const fence = "=" ** 72;

/// Keeps a cause alive after the failing operation's arena and resources are released.
pub const Reason = struct {
    buffer: [message_len_max]u8 = undefined,
    len: u32 = 0,

    pub fn set(reason: *Reason, comptime format: []const u8, args: anytype) void {
        reason.len = @intCast(format_bounded(&reason.buffer, format, args).len);
    }

    pub fn text(reason: *const Reason) []const u8 {
        std.debug.assert(reason.len <= reason.buffer.len);
        return reason.buffer[0..reason.len];
    }
};

/// A full buffer is an ordinary diagnostic limit; expose only bytes the writer initialized.
pub fn format_bounded(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print(format, args) catch return writer.buffered();
    return writer.buffered();
}

pub fn err(comptime format: []const u8, args: anytype) void {
    err_reason("", format, args);
}

pub fn err_reason(reason: []const u8, comptime format: []const u8, args: anytype) void {
    report_reason(.err, reason, format, args);
}

pub fn warn_reason(reason: []const u8, comptime format: []const u8, args: anytype) void {
    report_reason(.warn, reason, format, args);
}

fn report_reason(
    level: Level,
    reason: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    std.debug.assert(message_len_max > fence.len);
    var buffer: [message_len_max]u8 = undefined;
    const message = format_bounded(&buffer, format, args);
    const colored = stderr_is_terminal();
    const color = if (level == .warn) yellow_bold else red_bold;
    std.debug.print("\n{s}", .{if (colored) color else ""});
    var block_buffer: [message_len_max * 2 + 256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&block_buffer);
    const bounded_reason = reason[0..@min(reason.len, message_len_max)];
    write_block(&writer, level, message, bounded_reason) catch |print_err| {
        std.debug.print("diagnostic: {s}\n", .{@errorName(print_err)});
    };
    std.debug.print("{s}", .{writer.buffered()});
    std.debug.print("{s}", .{if (colored) reset else ""});
}

pub fn write_error(writer: *std.Io.Writer, message: []const u8, reason: []const u8) !void {
    return write_block(writer, .err, message, reason);
}

fn write_block(
    writer: *std.Io.Writer,
    level: Level,
    message: []const u8,
    reason: []const u8,
) !void {
    std.debug.assert(fence.len == 72);
    const label = if (level == .warn) "WARNING" else "ERROR";
    try writer.print("{s}\n{s}: {s}\n", .{ fence, label, message });

    if (reason.len > 0) {
        try writer.print("\nReason:\n{s}\n", .{reason});
    }

    try writer.print("{s}\n\n", .{fence});
}

pub fn err_text(message: []const u8) void {
    err("{s}", .{message});
}

fn stderr_is_terminal() bool {
    std.debug.assert(fence.len == 72);
    std.debug.assert(red_bold.len > 0);

    if (builtin.os.tag == .wasi) {
        return false;
    }

    return std.c.isatty(2) == 1;
}

test "diagnostics never expose unwritten bytes when formatting overflows" {
    var buffer: [16]u8 = @splat(0xa5);
    const message = format_bounded(&buffer, "error: {s}", .{"x" ** 128});
    try std.testing.expect(std.mem.indexOfScalar(u8, message, 0xa5) == null);
    try std.testing.expect(std.mem.startsWith(u8, message, "error: "));
}

test "an error and its reason share one block" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_error(
        &writer,
        "startup failed: EntryNotFound",
        "[theme] `content/index.publr` missing home",
    );
    try std.testing.expectEqualStrings(
        fence ++ "\nERROR: startup failed: EntryNotFound\n\n" ++
            "Reason:\n[theme] `content/index.publr` missing home\n" ++ fence ++ "\n\n",
        writer.buffered(),
    );
}
