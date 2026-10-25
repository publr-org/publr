//! The public site's door: before a page, a not-found page or an island goes out, the
//! plugins' delivery gates (`sdk.delivery`) say whether this visitor gets it, gets it
//! privately, or gets the gate's own answer instead. With no gates, nothing is asked and
//! nothing changes.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const http = @import("../../lib/http.zig");
const identity_module = @import("../rest/identity.zig");
const split = @import("../../server/split.zig");
const Project = @import("../../server/project.zig").Project;

const Request = http.Request;
const Response = http.Response;

pub const Door = enum {
    /// Deliver as usual.
    open,
    /// Deliver, kept out of shared caches.
    private,
    /// A gate answered; the response is written.
    refused,
};

pub fn door(
    project: *const Project,
    arena: std.mem.Allocator,
    request: *const Request,
    response: *Response,
) !Door {
    std.debug.assert(request.path().len > 0);
    std.debug.assert(project.delivery_gates.len <= sdk.delivery.gates_max);

    if (project.delivery_gates.len == 0) {
        return .open;
    }

    var ctx = identity_module.context(project, arena, .system);
    const delivery: sdk.delivery.Delivery = .{
        .ctx = &ctx,
        .visitor = visitor_of(project, arena, request),
        .path = request.path(),
    };

    switch (try sdk.delivery.decide(project.delivery_gates, &delivery)) {
        .open => return .open,
        .private => {
            try keep_private(response);
            return .private;
        },
        .refuse => |refusal| {
            const status = std.enums.fromInt(http.Status, refusal.status) orelse .forbidden;

            try keep_private(response);
            try response.set_body(status, "text/html; charset=utf-8", refusal.body);
            return .refused;
        },
    }
}

/// Who asks: signed in on this host, else, on the site's host of a split project, the
/// administrator the admin sent here with a member pass.
fn visitor_of(
    project: *const Project,
    arena: std.mem.Allocator,
    request: *const Request,
) sdk.Caller {
    std.debug.assert(request.path().len > 0);

    const signed_in = identity_module.identify(request, arena, project).caller;

    if (signed_in.user_id() != null or !project.split() or project.on_admin_host(request)) {
        return signed_in;
    }

    const member = split.member_identity(project, arena, request).caller;

    std.debug.assert(member == .anonymous or member.user_id() != null);

    return member;
}

/// For an answer a gate made personal: whatever the render set, no shared cache keeps it.
pub fn keep_private(response: *Response) !void {
    std.debug.assert(response.headers_len <= response.headers.len);

    try response.set_header("Cache-Control", "private, no-store");
    // A CDN reads its own header first: it must not keep this one either.
    try response.set_header("CDN-Cache-Control", "no-store");
    try response.set_header("Vary", "Cookie");
}
