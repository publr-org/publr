//! How `publr agent` reaches the server it runs beside: as the local operator for the
//! conversation's bookkeeping, and as the turn's device for the commands the model runs.

const std = @import("std");
const operator = @import("../operator.zig");
const model_app = @import("../../model/app.zig");

/// What `/_publr/cli` and `/api/cli` answer: the command's exit code and what it printed.
pub const Answer = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
};

const Envelope = struct {
    args: []const []const u8,
};

pub const Channel = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    session: operator.Session,
    /// The path the project is served under; empty at the root.
    base: []const u8,
    /// The turn's device, once `ai begin` made it.
    token: []const u8 = "",

    pub fn of(io: std.Io, arena: std.mem.Allocator, session: operator.Session) Channel {
        std.debug.assert(session.port > 0);
        std.debug.assert(session.key.len > 0);

        const base = if (session.url.len > 0) model_app.path_of(session.url) else "";

        return .{
            .io = io,
            .arena = arena,
            .session = session,
            .base = base,
        };
    }

    /// A command run as the local operator; its output, parsed as `T`. Fails when it fails.
    pub fn operate(channel: *Channel, comptime Out: type, args: []const []const u8) !Out {
        std.debug.assert(args.len > 0);
        std.debug.assert(std.mem.eql(u8, args[0], "--as-admin"));

        const arena = channel.arena;
        const payload = try std.json.Stringify.valueAlloc(arena, Envelope{
            .args = args,
        }, .{});
        const body = try operator.post(channel.io, arena, channel.session, "/_publr/cli", payload);
        const answer = try std.json.parseFromSliceLeaky(Answer, channel.arena, body, .{});

        if (answer.code != 0) {
            std.log.warn("{s} {s}: {s}", .{ args[1], args[2], answer.err });

            return error.CommandFailed;
        }

        return std.json.parseFromSliceLeaky(Out, channel.arena, answer.out, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// A command run as the turn's device, through `/api/cli` on this machine: what an
    /// agent elsewhere would send, under the same scope and refusals.
    pub fn command(channel: *Channel, args: []const []const u8) !Answer {
        std.debug.assert(args.len > 0);
        std.debug.assert(channel.token.len > 0);

        const url = try std.fmt.allocPrint(channel.arena, "http://127.0.0.1:{d}{s}/api/cli", .{
            channel.session.port,
            channel.base,
        });
        const bearer = try std.fmt.allocPrint(channel.arena, "Bearer {s}", .{channel.token});
        const envelope: Envelope = .{
            .args = args,
        };
        const payload = try std.json.Stringify.valueAlloc(channel.arena, envelope, .{});
        var body: std.Io.Writer.Allocating = .init(channel.arena);
        var client: std.http.Client = .{
            .allocator = channel.arena,
            .io = channel.io,
        };
        defer client.deinit();

        const result = try client.fetch(.{
            .location = .{
                .url = url,
            },
            .method = .POST,
            .payload = payload,
            .keep_alive = false,
            .headers = .{
                .content_type = .{
                    .override = "application/json",
                },
            },
            .extra_headers = &.{.{
                .name = "Authorization",
                .value = bearer,
            }},
            .response_writer = &body.writer,
        });

        if (result.status != .ok) {
            return .{
                .code = 1,
                .out = "",
                .err = body.written(),
            };
        }

        return std.json.parseFromSliceLeaky(Answer, channel.arena, body.written(), .{});
    }
};
