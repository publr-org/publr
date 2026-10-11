//! The workspaces watching conversations, each over a WebSocket: told the moment one
//! changes (a step, the words so far, its end), so they ask for what is new at once.

const std = @import("std");
const sdk = @import("../sdk.zig");
const http = @import("../lib/http.zig");

const websocket = http.websocket;

/// Open workspaces, at most; one more is refused until one closes.
pub const watches_max: u32 = 64;
const id_len_max: u32 = 64;

pub const Watch = struct {
    hub: *Hub,
    used: bool = false,
    id_buffer: [id_len_max]u8 = undefined,
    id_len: u32 = 0,
    connection: ?websocket.Connection = null,

    fn id(watch: *const Watch) []const u8 {
        std.debug.assert(watch.id_len <= id_len_max);

        return watch.id_buffer[0..watch.id_len];
    }
};

pub const Hub = struct {
    watches: [watches_max]Watch = undefined,
    ready: bool = false,

    pub fn live(hub: *Hub) sdk.context.Live {
        std.debug.assert(watches_max > 0);

        if (!hub.ready) {
            for (&hub.watches) |*watch| {
                watch.* = .{
                    .hub = hub,
                };
            }

            hub.ready = true;
        }

        return .{
            .context = hub,
            .changed = changed,
        };
    }

    /// A watch for conversation `id`, while one is free.
    pub fn take(hub: *Hub, id: []const u8) ?*Watch {
        std.debug.assert(hub.ready);

        if (id.len == 0 or id.len > id_len_max) {
            return null;
        }

        for (&hub.watches) |*watch| {
            if (!watch.used) {
                watch.used = true;
                watch.connection = null;
                watch.id_len = @intCast(id.len);
                @memcpy(watch.id_buffer[0..id.len], id);

                return watch;
            }
        }

        return null;
    }

    /// The handlers a taken watch's connection runs with.
    pub fn handlers(watch: *Watch) websocket.Handlers {
        std.debug.assert(watch.used);

        return .{
            .on_message = &heard,
            .on_open = &opened,
            .on_close = &closed,
            .ctx = watch,
        };
    }

    fn changed(context: *anyopaque, id: []const u8) void {
        const hub: *Hub = @ptrCast(@alignCast(context));

        std.debug.assert(hub.ready);

        for (&hub.watches) |*watch| {
            const connection = watch.connection orelse continue;

            if (watch.used and std.mem.eql(u8, watch.id(), id)) {
                connection.send_text("changed") catch |err| {
                    std.log.info("live: a watch is gone ({t})", .{err});
                };
            }
        }
    }
};

fn watch_of(context: ?*anyopaque) *Watch {
    return @ptrCast(@alignCast(context.?));
}

fn opened(connection: websocket.Connection, context: ?*anyopaque) void {
    const watch = watch_of(context);

    std.debug.assert(watch.used);

    watch.connection = connection;
}

fn closed(connection: websocket.Connection, context: ?*anyopaque) void {
    const watch = watch_of(context);

    std.debug.assert(watch.used);
    _ = connection;

    watch.connection = null;
    watch.used = false;
}

/// A page says nothing that matters: it only listens.
fn heard(connection: websocket.Connection, message: websocket.Message, context: ?*anyopaque) void {
    _ = connection;
    _ = message;
    std.debug.assert(watch_of(context).used);
}
