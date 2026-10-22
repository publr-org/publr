//! What the administrator's sandboxed frame (`shell.zig`) sends: always a visitor's
//! request, never theirs. The frame has an opaque origin, so its fetches and form posts
//! arrive with `Origin: null`; a form post still carries the session cookie, and its page
//! loads carry it too. Every such request reaches the rest of the server with the session
//! taken out and the frame's own visitor in its place, so islands, `_actions` calls and forms
//! work as they do for anyone, carts and all, and none of them acts as the administrator.
//!
//! The frame's visitor is derived from the session: stable while it lasts, never the
//! administrator's own `publr_visitor`. Page loads and form posts carry the session, so the
//! server derives it; fetches carry no cookie, so the guard (`frame.js`) sends it in
//! `Publr-Visitor`, which the server takes only from the frame. The frame's own link clicks
//! and form posts would carry no cookie either: the guard hands them to the shell, which
//! starts them, posts marked `publr_frame=1`.

const std = @import("std");
const http = @import("../../lib/http.zig");
const ids = @import("../../lib/id.zig");
const identity_module = @import("../rest/identity.zig");
const model_app = @import("../../model/app.zig");
const visitor = @import("visitor.zig");
const Project = @import("../../server/project.zig").Project;

const Request = http.Request;
const Response = http.Response;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const visitor_header = "publr-visitor";
/// What the shell adds to a form it posts into the frame for the page (`toolbar.js`).
pub const frame_mark = "publr_frame=1";

/// The doors the frame must never read through, even as a visitor: the admin's sign-in page
/// carries a token, and `/api` and `/auth` answer as whoever asks.
const closed = [_][]const u8{ "/admin", "/api/", "/auth/" };

/// Sent from an opaque origin (the frame, or a page somewhere else sandboxed the same way),
/// or posted by the shell for the frame and marked so. Either way, never the administrator:
/// the mark only ever takes the session away.
pub fn from_frame(request: *const Request) bool {
    std.debug.assert(request.path().len > 0);
    std.debug.assert(frame_mark.len > 0);

    if (std.mem.eql(u8, request.header("origin") orelse "", "null")) {
        return true;
    }

    var pairs = std.mem.splitScalar(u8, request.query(), '&');

    while (pairs.next()) |pair| {
        if (std.mem.eql(u8, pair, frame_mark)) {
            return true;
        }
    }

    return false;
}

/// The frame's visitor: the one its guard sends, else the one the session derives.
pub fn visitor_of(
    project: *const Project,
    request: *const Request,
    out: *[ids.len]u8,
) ?[]const u8 {
    std.debug.assert(project.session_cookie.len > 0);
    std.debug.assert(out.len == ids.len);

    if (request.header(visitor_header)) |sent| {
        if (well_formed(sent)) {
            @memcpy(out, sent);
            return out;
        }
    }

    const cookies = request.header("cookie") orelse return null;
    const token = identity_module.cookie_value(cookies, project.session_cookie) orelse return null;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    var hmac = HmacSha256.init(&project.auth.secret);

    hmac.update("publr frame visitor\x00");
    hmac.update(token);
    hmac.final(&mac);

    const hex = std.fmt.bytesToHex(mac, .lower);

    @memcpy(out, hex[0..ids.len]);

    return out;
}

fn well_formed(sent: []const u8) bool {
    std.debug.assert(ids.len > 0);

    if (sent.len != ids.len) {
        return false;
    }

    for (sent) |char| {
        if (!std.ascii.isHex(char)) {
            return false;
        }
    }

    return true;
}

/// The same request as a visitor sends it: its only cookie the frame's visitor, no
/// `Authorization`, nothing else that could name the administrator.
pub fn as_visitor(
    project: *const Project,
    arena: std.mem.Allocator,
    request: *const Request,
    visitor_id: ?[]const u8,
) !Request {
    std.debug.assert(visitor_id == null or visitor_id.?.len == ids.len);
    std.debug.assert(request.inner.headers_len <= request.inner.headers.len);

    const inner = try arena.create(@TypeOf(request.inner.*));

    inner.* = request.inner.*;
    inner.headers_len = 0;

    for (request.inner.headers[0..request.inner.headers_len]) |found| {
        const dropped = std.ascii.eqlIgnoreCase(found.name, "cookie") or
            std.ascii.eqlIgnoreCase(found.name, "authorization");

        if (!dropped) {
            inner.headers[inner.headers_len] = found;
            inner.headers_len += 1;
        }
    }

    if (visitor_id) |id| {
        if (inner.headers_len < inner.headers.len) {
            inner.headers[inner.headers_len] = .{
                .name = "Cookie",
                .value = try std.fmt.allocPrint(arena, "{s}={s}", .{ project.visitor_cookie, id }),
            };
            inner.headers_len += 1;
        }
    }

    return .{
        .inner = inner,
        .params = request.params,
        .body = request.body,
    };
}

/// Router middleware: a request from the frame goes on as a visitor's, and what it gets
/// back the frame may read (fonts, module scripts, `fetch`, island and `_actions` answers),
/// except through the closed doors, which it reaches only as nobody. Every other read of an
/// open door varies on `Origin`, so no cache hands the frame a copy made without this.
pub fn open_to_frame(
    request: *Request,
    response: *Response,
    ctx: *http.Context,
    next: http.Router.Next,
) anyerror!void {
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const path = model_app.without_base(project.base, request.path());
    const open = for (closed) |door| {
        if (std.mem.startsWith(u8, path, door)) {
            break false;
        }
    } else true;

    if (!from_frame(request)) {
        try next.run(request, response, ctx);

        if (open and (request.method() == .get or request.method() == .head)) {
            try vary_on_origin(response);
        }

        return;
    }

    if (open and request.method() == .options) {
        return preflight(response);
    }

    var buffer: [ids.len]u8 = undefined;
    var as_sent = try as_visitor(
        project,
        ctx.arena,
        request,
        visitor_of(project, request, &buffer),
    );

    std.debug.assert(as_sent.header("cookie") == null or
        identity_module.cookie_value(as_sent.header("cookie").?, project.session_cookie) == null);

    try next.run(&as_sent, response, ctx);

    if (open) {
        try vary_on_origin(response);
        // What a frame sends with credentials it reads back only if told it may; the answer
        // was made for a visitor, so it may.
        try response.set_header("Access-Control-Allow-Origin", "null");
        try response.set_header("Access-Control-Allow-Credentials", "true");
    }
}

/// The frame's `_actions` calls send `Publr-Request` and its visitor: the browser asks first.
fn preflight(response: *Response) !void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(response.status == .ok);

    try response.set_header("Access-Control-Allow-Origin", "null");
    try response.set_header("Access-Control-Allow-Credentials", "true");
    try response.set_header("Access-Control-Allow-Methods", "GET, HEAD, POST");
    try response.set_header("Access-Control-Allow-Headers", "content-type, " ++
        "publr-request, " ++ visitor_header);
    try response.set_header("Access-Control-Max-Age", "600");
    try response.set_header("Vary", "Origin");
    try response.set_body(.no_content, "text/plain", "");
}

fn vary_on_origin(response: *Response) !void {
    std.debug.assert(response.headers_len <= response.headers.len);

    const vary = response.header("Vary");
    const varied = if (vary) |found|
        try std.fmt.allocPrint(response.arena, "{s}, Origin", .{found})
    else
        "Origin";

    try response.set_header("Vary", varied);
}
