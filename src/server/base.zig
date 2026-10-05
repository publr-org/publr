//! A project served under a path (`/environments/dev`, the path of `--url`): requests arrive
//! with it taken off (the HTTP layer strips it), and every address a response sends back
//! gets it here, at the very end: redirects (`Location`, and `Publr-Location`, which the
//! admin's scripts follow) and the paths cookies are kept for. Pages write theirs as they
//! render. A path that carries the base already is left alone.
const std = @import("std");
const http = @import("../lib/http.zig");
const model_app = @import("../model/app.zig");
const Project = @import("project.zig").Project;

const Request = http.Request;
const Response = http.Response;
const Context = http.Context;

const address_headers = [_][]const u8{ "Location", "Publr-Location" };
const cookie_path = "Path=";

pub fn under_base(
    request: *Request,
    response: *Response,
    ctx: *Context,
    next: http.Router.Next,
) anyerror!void {
    std.debug.assert(ctx.user_data != null);

    try next.run(request, response, ctx);

    const base = Project.of(ctx).base;

    if (base.len == 0) {
        return;
    }

    std.debug.assert(base[0] == '/');

    for (response.headers[0..response.headers_len]) |*header| {
        header.value = try value_under(ctx.arena, base, header.name, header.value);
    }
}

/// A header's value with the base in front of the address it carries, where it needs it.
fn value_under(
    arena: std.mem.Allocator,
    base: []const u8,
    name: []const u8,
    value: []const u8,
) ![]const u8 {
    std.debug.assert(base.len > 0);

    std.debug.assert(name.len > 0);

    for (address_headers) |address| {
        if (std.ascii.eqlIgnoreCase(name, address)) {
            if (!model_app.needs_base(base, value)) {
                return value;
            }

            return std.fmt.allocPrint(arena, "{s}{s}", .{ base, value });
        }
    }

    if (std.ascii.eqlIgnoreCase(name, "Set-Cookie")) {
        return cookie_under(arena, base, value);
    }

    return value;
}

/// `name=value; Path=/admin; …` kept for `<base>/admin`; a cookie without a path as it is.
fn cookie_under(arena: std.mem.Allocator, base: []const u8, cookie: []const u8) ![]const u8 {
    std.debug.assert(base.len > 0);

    std.debug.assert(cookie.len > 0);

    var attributes = std.mem.splitSequence(u8, cookie, "; ");
    var offset: u32 = 0;

    while (attributes.next()) |attribute| : (offset += @intCast(attribute.len + 2)) {
        if (!std.ascii.startsWithIgnoreCase(attribute, cookie_path)) {
            continue;
        }

        const path = attribute[cookie_path.len..];

        if (!model_app.needs_base(base, path)) {
            return cookie;
        }

        const start = offset + cookie_path.len;
        // `Path=/` is the whole base, not `<base>/`, which would leave the base itself out.
        const kept = if (std.mem.eql(u8, path, "/")) base else try std.fmt.allocPrint(
            arena,
            "{s}{s}",
            .{ base, path },
        );

        return std.fmt.allocPrint(arena, "{s}{s}{s}", .{
            cookie[0..start],
            kept,
            cookie[start + path.len ..],
        });
    }

    return cookie;
}

test "redirects and cookie paths go under the base, once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "/environments/dev";

    try std.testing.expectEqualStrings(
        "/environments/dev/admin",
        try value_under(arena, base, "Location", "/admin"),
    );
    try std.testing.expectEqualStrings(
        "/environments/dev/admin",
        try value_under(arena, base, "location", "/environments/dev/admin"),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/",
        try value_under(arena, base, "Location", "https://example.com/"),
    );
    try std.testing.expectEqualStrings(
        "s=1; Path=/environments/dev; HttpOnly",
        try value_under(arena, base, "Set-Cookie", "s=1; Path=/; HttpOnly"),
    );
    try std.testing.expectEqualStrings(
        "a=2; Path=/environments/dev/admin",
        try value_under(arena, base, "Set-Cookie", "a=2; Path=/admin"),
    );
    try std.testing.expectEqualStrings(
        "c=3; HttpOnly",
        try value_under(arena, base, "Set-Cookie", "c=3; HttpOnly"),
    );
    try std.testing.expectEqualStrings(
        "text/html",
        try value_under(arena, base, "Content-Type", "text/html"),
    );
}
