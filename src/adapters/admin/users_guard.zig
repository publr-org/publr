//! An administrator is never tricked into making someone staff: every change to an account's
//! roles is a POST from the admin's own page, and nothing else reaches it.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const user_operations = @import("../../operations/user.zig");
const sdk = @import("../../sdk.zig");

const back = "/admin/settings/users";

/// `method path` as another site's page, or a link, sends it: `origin` and `csrf` as given.
fn send(
    flow: *admin.Flow,
    head: struct {
        method: []const u8,
        path: []const u8,
        origin: []const u8 = "",
        csrf: []const u8 = "",
    },
    body: []const u8,
) !@import("../../lib/http.zig").Response {
    std.debug.assert(head.path.len > 0);
    std.debug.assert(flow.cookie.len > 0);

    const origin = if (head.origin.len > 0)
        try std.fmt.allocPrint(flow.inner.arena, "Origin: {s}\r\n", .{head.origin})
    else
        "";
    const csrf = if (head.csrf.len > 0)
        try std.fmt.allocPrint(flow.inner.arena, "X-CSRF-Token: {s}\r\n", .{head.csrf})
    else
        "";
    const text = try std.fmt.allocPrint(
        flow.inner.arena,
        "{s} {s} HTTP/1.1\r\nHost: h\r\n{s}{s}Cookie: {s}\r\n" ++
            "Content-Type: application/json\r\nContent-Length: 0\r\n\r\n",
        .{ head.method, head.path, origin, csrf, flow.cookie },
    );

    return flow.inner.call(text, body);
}

fn roles_of(harness: *sdk.testing.Harness, email: []const u8) ![]const []const u8 {
    std.debug.assert(email.len > 0);

    var system = harness.ctx(.system);
    const found = try registry.SDK.dispatch(&system, user_operations.Get, .{
        .user = email,
    });

    return found.user.roles;
}

test "staff ladder: cross-site posts, links and GETs never change an account's roles" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var flow: admin.Flow = .{
        .inner = undefined,
    };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    _ = try flow.call("POST", "/admin/setup", "email=ada%40example.com&display_name=Ada&" ++
        "password=correct+horse+battery");

    const listed = try flow.call("GET", back, "");
    const csrf = flow.csrf_of(listed.body);
    const invite = try std.fmt.allocPrint(arena, "csrf={s}&display_name=Writer&" ++
        "email=writer%40example.com&roles=editor&password=", .{csrf});

    _ = try flow.call("POST", back ++ "/create", invite);

    var reading = harness.ctx(.system);
    const writer = try registry.SDK.dispatch(&reading, user_operations.Get, .{
        .user = "writer@example.com",
    });
    const update = try std.fmt.allocPrint(arena, "{s}/{s}/update", .{ back, writer.user.id });
    const promote = try std.fmt.allocPrint(arena, "csrf={s}&display_name=Writer&roles=admin", .{
        csrf,
    });
    const no_token = "display_name=Writer&roles=admin";

    // The admin's form, posted from another site, without the token, or with no origin.
    const posts = [_]struct {
        origin: []const u8,
        body: []const u8,
    }{
        .{
            .origin = "http://evil.example",
            .body = promote,
        },
        .{
            .origin = "http://h",
            .body = no_token,
        },
        .{
            .origin = "",
            .body = promote,
        },
    };

    for (posts) |post| {
        const refused = try send(&flow, .{
            .method = "POST",
            .path = update,
            .origin = post.origin,
        }, post.body);

        try std.testing.expect(refused.status != .see_other);
    }

    // A link or an image: no route changes anything on GET.
    const linked = try std.fmt.allocPrint(arena, "{s}?{s}", .{ update, promote });

    _ = try send(&flow, .{
        .method = "GET",
        .path = linked,
    }, "");

    // The operations over HTTP: GET refused for a write, a post from elsewhere or without
    // the token refused.
    const user_update = "{\"user\":\"writer@example.com\",\"display_name\":\"W\"," ++
        "\"roles\":[\"admin\"]}";
    const read_only = try send(&flow, .{
        .method = "GET",
        .path = "/api/user.update?user=writer%40example.com&display_name=W&roles=admin",
    }, "");
    const cross = try send(&flow, .{
        .method = "POST",
        .path = "/api/user.update",
        .origin = "http://evil.example",
        .csrf = csrf,
    }, user_update);
    const tokenless = try send(&flow, .{
        .method = "POST",
        .path = "/api/role.update",
        .origin = "http://h",
    }, "{\"name\":\"editor\",\"label\":\"Editor\",\"grants\":[\"*\"]}");

    try std.testing.expectEqual(.method_not_allowed, read_only.status);
    try std.testing.expectEqual(.forbidden, cross.status);
    try std.testing.expectEqual(.forbidden, tokenless.status);

    const held = try roles_of(&harness, "writer@example.com");

    try std.testing.expectEqual(@as(usize, 1), held.len);
    try std.testing.expectEqualStrings("editor", held[0]);

    // The same form from the admin's own page goes through.
    const done = try flow.call("POST", update, promote);

    try std.testing.expectEqual(.see_other, done.status);
}

test "staff ladder: an app's /_actions reach no core operation that changes accounts" {
    // `/_actions/app.<plugin>.<verb>` runs only an operation declaring `untrusted_callers`,
    // which plugins make; core's account and role operations never declare it.
    const guarded = [_][]const u8{ "user", "role", "identity", "sign_on", "device", "plugin" };

    // Unrolled once over every operation: the budget grows with the list.
    @setEvalBranchQuota(1000 + registry.SDK.operations.len * 8);

    inline for (registry.SDK.operations) |Operation| {
        const namespace = sdk.operation.namespace(Operation.name);
        const kept = for (guarded) |name| {
            if (std.mem.eql(u8, name, namespace)) {
                break true;
            }
        } else false;

        if (kept and Operation.kind == .write) {
            try std.testing.expect(!@hasDecl(Operation, "untrusted_callers"));
        }
    }
}
