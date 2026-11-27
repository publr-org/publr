const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/request.zig");
const request_data = @import("../sdk/request_data.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const operations = [_]type{Read};

pub const Touch = public.Touch;

pub const Read = struct {
    pub const shape = public.Read;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

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
