//! The public site's door: before a page, a not-found page or an island goes out, the
//! plugins' delivery gates (`sdk.delivery`) say whether this visitor gets it, gets it
//! privately, or gets the gate's own answer instead. With no gates, nothing is asked and
//! nothing changes.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const http = @import("../../lib/http.zig");
const identity_module = @import("../rest/identity.zig");
const Site = @import("../../app/site.zig").Site;

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
    site: *const Site,
    arena: std.mem.Allocator,
    request: *const Request,
    response: *Response,
    kind: sdk.delivery.Kind,
) !Door {
    std.debug.assert(request.path().len > 0);
    std.debug.assert(site.delivery_gates.len <= sdk.delivery.gates_max);

    if (site.delivery_gates.len == 0) {
        return .open;
    }

    var ctx = identity_module.context(site, arena, .system);
    const delivery: sdk.delivery.Delivery = .{
        .ctx = &ctx,
        .visitor = identity_module.identify(request, arena, site).caller,
        .path = request.path(),
        .kind = kind,
    };

    switch (try sdk.delivery.decide(site.delivery_gates, &delivery)) {
        .open => return .open,
        .private => {
            try keep_private(response);
            return .private;
        },
        .refuse => |refusal| {
            const status = std.enums.fromInt(http.Status, refusal.status) orelse .forbidden;

            try keep_private(response);
            try response.set_body(status, refusal.content_type, refusal.body);
            return .refused;
        },
    }
}

/// For an answer a gate made personal: whatever the render set, no shared cache keeps it.
pub fn keep_private(response: *Response) !void {
    std.debug.assert(response.headers_len <= response.headers.len);

    try response.set_header("Cache-Control", "private, no-store");
    // A CDN reads its own header first: it must not keep this one either.
    try response.set_header("CDN-Cache-Control", "no-store");
    try response.set_header("Vary", "Cookie");
}
