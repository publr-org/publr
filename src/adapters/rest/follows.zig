//! A read the admin follows (`X-Publr-Follow: 1`): what it read, as the change log's keys,
//! and the log's revision before it read, sent back as `X-Publr-Follows` and
//! `X-Publr-Revision`. The admin asks `/admin/live` whether any of them changed since, and
//! reads again when one did: a plugin's page following its record (an order turning paid).
const std = @import("std");
const http = @import("../../lib/http.zig");
const sdk = @import("../../sdk.zig");
const Project = @import("../../server/project.zig").Project;

/// The most keys one read reports; past it, the read is not followed.
pub const keys_max: u32 = 64;
const key_len_max: u32 = 256;

pub const Follows = struct {
    arena: std.mem.Allocator,
    revision: u64,
    keys: std.ArrayList([]const u8) = .empty,
    complete: bool = true,

    /// Where the read's SDK calls write their keys.
    pub fn reads(follows: *Follows) sdk.Reads {
        std.debug.assert(follows.keys.items.len <= keys_max);

        return .{
            .context = follows,
            .read = read,
        };
    }

    fn read(context: *anyopaque, key: []const u8) void {
        const follows: *Follows = @ptrCast(@alignCast(context));

        std.debug.assert(key.len > 0);

        for (follows.keys.items) |held| {
            if (std.mem.eql(u8, held, key)) {
                return;
            }
        }

        const fits = key.len <= key_len_max and follows.keys.items.len < keys_max and
            std.mem.indexOfScalar(u8, key, ',') == null;

        if (!fits) {
            follows.complete = false;
            return;
        }

        const copy = follows.arena.dupe(u8, key) catch {
            follows.complete = false;
            return;
        };

        follows.keys.append(follows.arena, copy) catch {
            follows.complete = false;
        };
    }

    /// The headers telling the admin what to follow; none when the read could not be
    /// followed whole.
    pub fn tell(follows: *const Follows, response: *http.Response) !void {
        std.debug.assert(follows.keys.items.len <= keys_max);

        if (!follows.complete or follows.keys.items.len == 0) {
            return;
        }

        const keys = try std.mem.join(follows.arena, ",", follows.keys.items);
        const revision = try std.fmt.allocPrint(follows.arena, "{d}", .{follows.revision});

        try response.set_header("X-Publr-Follows", keys);
        try response.set_header("X-Publr-Revision", revision);
    }
};

/// A follow for this read, when the admin asks for one and the server keeps a change log.
pub fn start(
    project: *const Project,
    request: *const http.Request,
    arena: std.mem.Allocator,
) ?Follows {
    std.debug.assert(project.connection.transaction_depth == 0);

    const asked = request.header("x-publr-follow") orelse return null;

    if (!std.mem.eql(u8, asked, "1")) {
        return null;
    }

    const host = project.apps_host orelse return null;

    // A read the change log cannot place is answered unfollowed.
    const revision = host.index.revision() catch |err| {
        std.log.warn("follows: the change log unread: {t}", .{err});
        return null;
    };

    return .{
        .arena = arena,
        .revision = revision,
    };
}

test "a followed read keeps each key once, and gives up past its bounds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var follows: Follows = .{
        .arena = arena_state.allocator(),
        .revision = 7,
    };
    const reads = follows.reads();

    reads.read(reads.context, "internal:orders/order/abc");
    reads.read(reads.context, "internal:orders/order/abc");
    reads.read(reads.context, "record:abc");

    try std.testing.expectEqual(@as(usize, 2), follows.keys.items.len);
    try std.testing.expect(follows.complete);

    reads.read(reads.context, "a,b");

    try std.testing.expect(!follows.complete);
}
