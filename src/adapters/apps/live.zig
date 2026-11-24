//! `<mount>/_live?since=<revision>&keys=<k1>,<k2>`: whether anything a followed island read
//! changed after the revision it was drawn at (`<X dynamic follow />`). Answered at once from
//! the index's change log, which is read without taking the write lock; the page's script
//! asks again a little later, and draws the island again when it changed. Never a record's
//! content: the island is fetched again as the visitor, through the usual checks.
const std = @import("std");
const http = @import("../../lib/http.zig");
const Project = @import("../../server/project.zig").Project;
const Index = @import("../../lib/deps.zig").Index;

const Request = http.Request;
const Response = http.Response;

pub const prefix = "/_live";
pub const keys_max: u32 = 256;

pub fn answer(
    project: *const Project,
    target: Project.Target,
    request: *Request,
    response: *Response,
    arena: std.mem.Allocator,
) anyerror!void {
    std.debug.assert(std.mem.startsWith(u8, target.path, prefix));
    std.debug.assert(project.base.len == 0 or project.base[0] == '/');

    try response.set_header("Cache-Control", "no-store");

    if (request.method() != .get) {
        return response.text(.method_not_allowed, "Method Not Allowed");
    }

    return response.json(.ok, try changed_since(target.app.index, arena, request.query()));
}

pub const Answer = struct {
    /// The change log's revision now: what the page asks after next.
    revision: u64,
    /// Whether a followed key changed after `since`.
    changed: bool,
};

/// Whether any of `keys` (comma-separated, in the query string) changed after `since`, read
/// from the change log without the write lock: the site's followed islands and the admin's
/// followed pages ask the same.
pub fn changed_since(index: *Index, arena: std.mem.Allocator, query: []const u8) !Answer {
    std.debug.assert(query.len <= 64 << 10);

    const since_text = http.Form.query_param(arena, query, "since") orelse "";
    const keys_text = http.Form.query_param(arena, query, "keys") orelse "";
    const since = std.fmt.parseInt(u64, since_text, 10) catch {
        return .{
            .revision = try index.revision(),
            .changed = false,
        };
    };
    const now = try index.changes_since(arena, since);

    std.debug.assert(now.keys.len <= 1 << 20);

    return .{
        .revision = now.revision,
        .changed = now.reset or any_of(keys_text, now.keys),
    };
}

/// Whether one of the comma-separated `wanted` keys is among `changed`.
fn any_of(wanted: []const u8, changed: []const []const u8) bool {
    std.debug.assert(wanted.len <= 64 << 10);

    var keys = std.mem.splitScalar(u8, wanted, ',');
    var count: u32 = 0;

    while (keys.next()) |key| {
        count += 1;

        if (count > keys_max) {
            return true;
        }

        for (changed) |each| {
            if (key.len > 0 and std.mem.eql(u8, key, each)) {
                return true;
            }
        }
    }

    return false;
}

test "a followed key among the changed ones" {
    try std.testing.expect(any_of("record:a,record:b", &.{ "x", "record:b" }));
    try std.testing.expect(!any_of("record:a", &.{"record:b"}));
    try std.testing.expect(!any_of("", &.{"record:b"}));
}
