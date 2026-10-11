//! Starts a conversation's turn in a process of its own, `publr agent`, so the server keeps
//! answering while a model works for minutes. The process asks the server for its device and
//! reports each step back over the operator channel; it writes what it did to a log.

const std = @import("std");
const sdk_context = @import("../sdk/context.zig");

pub const Starter = struct {
    io: std.Io,
    db_path: []const u8,
    executable: []const u8 = "",
    logs_dir: []const u8 = "",

    /// The hook `ai.ask` starts a turn through.
    pub fn hook(starter: *Starter, arena: std.mem.Allocator) !sdk_context.AgentStarter {
        std.debug.assert(starter.db_path.len > 0);
        std.debug.assert(starter.executable.len == 0);

        starter.executable = try std.process.executablePathAlloc(starter.io, arena);
        starter.logs_dir = try std.fs.path.join(arena, &.{
            std.fs.path.dirname(starter.db_path) orelse ".",
            "agents",
        });

        return .{
            .context = starter,
            .start = start,
        };
    }

    fn start(context: *anyopaque, conversation_id: []const u8) ?[]const u8 {
        const starter: *Starter = @ptrCast(@alignCast(context));

        std.debug.assert(starter.executable.len > 0);
        std.debug.assert(conversation_id.len > 0 and conversation_id.len <= 64);

        starter.spawn(conversation_id) catch |err| {
            std.log.warn("agent {s}: {t}", .{ conversation_id, err });

            return "The agent could not be started";
        };

        return null;
    }

    fn spawn(starter: *Starter, conversation_id: []const u8) !void {
        std.debug.assert(starter.logs_dir.len > 0);
        std.debug.assert(conversation_id.len <= 64);

        var buffer: [1024]u8 = undefined;
        const log_path = try std.fmt.bufPrint(&buffer, "{s}/{s}.log", .{
            starter.logs_dir,
            conversation_id,
        });
        const cwd = std.Io.Dir.cwd();

        try cwd.createDirPath(starter.io, starter.logs_dir);

        var log = try cwd.createFile(starter.io, log_path, .{});
        defer log.close(starter.io);

        // Not waited for: it outlives this request, and reports through the server itself.
        _ = try std.process.spawn(starter.io, .{
            .argv = &.{
                starter.executable, "--db",           starter.db_path,
                "agent",            "--conversation", conversation_id,
            },
            .stdin = .ignore,
            .stdout = .{
                .file = log,
            },
            .stderr = .{
                .file = log,
            },
        });
    }
};
