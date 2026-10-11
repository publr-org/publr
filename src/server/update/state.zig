//! What an update is doing, in `<data>/updates/state.json`: written by the process doing it,
//! read by the server for `update.status`. And the marker beside the database a swap leaves
//! (`<db>.updating`), which tells the next start where to go back to if it cannot start.

const std = @import("std");
const context = @import("../../sdk/context.zig");

const file_bytes_max: u32 = 64 << 10;

pub const State = struct {
    step: []const u8 = "idle",
    target: []const u8 = "",
    message: []const u8 = "",
    previous: ?[]const u8 = null,
    started_ms: i64 = 0,

    pub fn status(state: State) context.UpdateStatus {
        std.debug.assert(state.step.len > 0);

        return .{
            .step = state.step,
            .target = state.target,
            .message = state.message,
            .previous = state.previous,
        };
    }

    /// Whether an update is on its way: started, not over, and not left behind by a process
    /// that died (an hour is longer than any update takes).
    pub fn running(state: State, now_ms: i64) bool {
        std.debug.assert(now_ms > 0);

        const over = std.mem.eql(u8, state.step, "idle") or std.mem.eql(u8, state.step, "done") or
            std.mem.eql(u8, state.step, "failed");

        return !over and now_ms - state.started_ms < std.time.ms_per_hour;
    }
};

/// Left beside the database by a swap, removed by the first start that serves.
pub const Marker = struct {
    /// The release swapped in.
    to: []const u8,
    /// Where the binary it replaced is kept, and its release.
    previous_binary: []const u8,
    previous_version: []const u8,
    /// A backup to put back before starting: a step back across a one-way migration.
    restore: ?[]const u8 = null,
};

pub fn updates_dir(arena: std.mem.Allocator, db_path: []const u8) ![]const u8 {
    std.debug.assert(db_path.len > 0);

    return std.fs.path.join(arena, &.{ std.fs.path.dirname(db_path) orelse ".", "updates" });
}

pub fn marker_path(arena: std.mem.Allocator, db_path: []const u8) ![]const u8 {
    std.debug.assert(db_path.len > 0);

    return std.fmt.allocPrint(arena, "{s}.updating", .{db_path});
}

pub fn read(io: std.Io, arena: std.mem.Allocator, db_path: []const u8) State {
    std.debug.assert(db_path.len > 0);

    const path = state_path(arena, db_path) catch return .{};

    return read_json(State, io, arena, path) catch .{};
}

pub fn write(io: std.Io, arena: std.mem.Allocator, db_path: []const u8, state: State) !void {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(state.step.len > 0);

    const dir = try updates_dir(arena, db_path);

    try std.Io.Dir.cwd().createDirPath(io, dir);
    try write_json(io, arena, try state_path(arena, db_path), state);
}

pub fn read_marker(io: std.Io, arena: std.mem.Allocator, db_path: []const u8) ?Marker {
    std.debug.assert(db_path.len > 0);

    const path = marker_path(arena, db_path) catch return null;

    return read_json(Marker, io, arena, path) catch null;
}

pub fn write_marker(
    io: std.Io,
    arena: std.mem.Allocator,
    db_path: []const u8,
    marker: Marker,
) !void {
    std.debug.assert(marker.to.len > 0);
    std.debug.assert(marker.previous_binary.len > 0);

    try write_json(io, arena, try marker_path(arena, db_path), marker);
}

pub fn remove_marker(io: std.Io, arena: std.mem.Allocator, db_path: []const u8) !void {
    std.debug.assert(db_path.len > 0);

    std.Io.Dir.cwd().deleteFile(io, try marker_path(arena, db_path)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn state_path(arena: std.mem.Allocator, db_path: []const u8) ![]const u8 {
    std.debug.assert(db_path.len > 0);

    return std.fs.path.join(arena, &.{ try updates_dir(arena, db_path), "state.json" });
}

fn read_json(comptime Value: type, io: std.Io, arena: std.mem.Allocator, path: []const u8) !Value {
    std.debug.assert(path.len > 0);
    std.debug.assert(file_bytes_max > 0);

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(file_bytes_max));

    return std.json.parseFromSliceLeaky(Value, arena, text, .{
        .ignore_unknown_fields = true,
    });
}

/// Written beside and renamed into place, so a reader never sees half of it.
fn write_json(io: std.Io, arena: std.mem.Allocator, path: []const u8, value: anytype) !void {
    std.debug.assert(path.len > 0);

    const text = try std.json.Stringify.valueAlloc(arena, value, .{
        .whitespace = .indent_2,
    });
    const temporary = try std.fmt.allocPrint(arena, "{s}.next", .{path});
    const cwd = std.Io.Dir.cwd();

    try cwd.writeFile(io, .{
        .sub_path = temporary,
        .data = text,
    });
    try cwd.rename(temporary, cwd, path, io);
}

test "an update is running until it is over, or left an hour" {
    const started: State = .{
        .step = "downloading",
        .target = "0.4.0",
        .started_ms = 1_000,
    };
    const over: State = .{
        .step = "done",
        .target = "0.4.0",
        .started_ms = 1_000,
    };

    try std.testing.expect(started.running(2_000));
    try std.testing.expect(!started.running(1_000 + std.time.ms_per_hour));
    try std.testing.expect(!over.running(2_000));
    try std.testing.expectEqualStrings("0.4.0", started.status().target);
}
