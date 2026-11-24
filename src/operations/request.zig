//! What a plugin reads of the visitor's requests (`request.read`): the query parameters it
//! declares as the visitor brought them, first and latest, where they landed and from where,
//! their address now and the cookies it declares, from a call the visitor makes.
const std = @import("std");
const sdk = @import("../sdk.zig");
const request_data = @import("../sdk/request_data.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "request",
    .label = "Visitors' requests",
    .area = .system,
    .summary = "What plugins read of visitors' requests",
    .details =
    \\A plugin declares the query parameters and cookies it reads (`.request`) and asks for
    \\`request.read`: core keeps, for each visitor, the first and the latest landing that
    \\brought one, where it was and the page that sent them. `request read` answers its own
    \\names of them, with the visitor's address and cookies now. A plugin declaring path
    \\prefixes and holding `request.redirect` answers the addresses under them.
    ,
};

pub const operations = [_]type{Read};

pub const Touch = struct {
    landing: []const u8 = "",
    referrer: []const u8 = "",
    at_ms: i64 = 0,
    values: []const request_data.Value = &.{},
};

pub const Read = struct {
    pub const name = "request.read";
    pub const plugins_only = true;
    pub const description = "What the visitor brought: the plugin's query parameters, " ++
        "landing, referrer, address, cookies";
    pub const details =
        \\Plugins holding `request.read`, for the visitor of the call. Only the names the
        \\plugin declares (`.request`): the query parameters of the visitor's first and latest
        \\landing that brought any (empty when none did), and the cookies of this call. The
        \\address is the visitor's, behind the site's proxy (`X-Forwarded-For`).
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        first: Touch,
        last: Touch,
        address: []const u8,
        cookies: []const request_data.Value,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .first = .{
            .landing = "/products/tea",
            .referrer = "https://news.example.com/",
            .at_ms = 1789640000000,
            .values = &.{.{
                .name = "ref",
                .value = "ada",
            }},
        },
        .last = .{},
        .address = "203.0.113.7",
        .cookies = &.{},
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .first = "The first landing that brought a parameter the plugin reads",
        .last = "The latest such landing",
        .address = "The visitor's address now",
        .cookies = "The cookies the plugin declares, as this call brought them",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const reads = try reads_of(ctx);
        const visit = if (ctx.visitor.len > 0)
            try request_data.visit_of(ctx, ctx.visitor) orelse request_data.Visit{}
        else
            request_data.Visit{};
        var cookies: std.ArrayList(request_data.Value) = .empty;

        for (reads.cookies) |cookie| {
            const value = request_data.cookie_value(ctx.cookies, cookie) orelse continue;

            try cookies.append(ctx.arena, .{
                .name = cookie,
                .value = value,
            });
        }

        return .{
            .first = try own(ctx, visit.first, reads),
            .last = try own(ctx, visit.last, reads),
            .address = ctx.address,
            .cookies = cookies.items,
        };
    }
};

/// What the calling plugin declares; refused for anyone else.
fn reads_of(ctx: *Ctx) Error!request_data.RequestReads {
    std.debug.assert(ctx.now_ms >= 0);

    const plugin = reader_of(ctx);

    if (plugin.len == 0) {
        return error.Denied;
    }

    for (try request_data.declared(ctx)) |one| {
        if (std.mem.eql(u8, one.plugin, plugin)) {
            return one.reads;
        }
    }

    return .{};
}

/// The plugin whose code is running: a hook's own (affiliates' `after` hook on
/// `orders.place`), never the hooked operation's, nor the plugin that called it.
fn reader_of(ctx: *const Ctx) []const u8 {
    std.debug.assert(ctx.plugin.len <= 64);

    if (ctx.plugin.len > 0) {
        return ctx.plugin;
    }

    return switch (ctx.caller) {
        .plugin => |caller| caller.name,
        else => "",
    };
}

/// A landing with the plugin's own parameters alone.
fn own(ctx: *Ctx, touch: request_data.Touch, reads: request_data.RequestReads) Error!Touch {
    std.debug.assert(touch.values.len <= 64);
    std.debug.assert(reads.query.len <= request_data.RequestReads.names_max);

    var values: std.ArrayList(request_data.Value) = .empty;

    for (touch.values) |value| {
        for (reads.query) |name| {
            if (std.mem.eql(u8, value.name, name)) {
                try values.append(ctx.arena, value);
            }
        }
    }

    if (values.items.len == 0) {
        return .{};
    }

    return .{
        .landing = touch.landing,
        .referrer = touch.referrer,
        .at_ms = touch.at_ms,
        .values = values.items,
    };
}

test "the reader is the plugin whose code runs: a hook's own, not its caller's" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var hooked = harness.ctx(.{
        .plugin = .{
            .name = "checkout",
        },
    });

    try std.testing.expectEqualStrings("checkout", reader_of(&hooked));

    hooked.plugin = "affiliates";
    try std.testing.expectEqualStrings("affiliates", reader_of(&hooked));

    var person = harness.ctx(.system);

    try std.testing.expectEqualStrings("", reader_of(&person));
}
