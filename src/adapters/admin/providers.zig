//! Settings › Providers: each contract's providers, compiled in or installed, in the order
//! the owner tries them, each with a switch and a link to its plugin's settings. Core's own
//! contracts are listed even with no provider, so the page says what then happens.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const contract = @import("../../sdk/contract.zig");
const provider = @import("../../operations/provider.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/settings/providers";
const Row = std.meta.Child(@FieldType(views.Providers.ContractsItem, "providers"));
pub const routes_count: u32 = 2;

/// Core's contracts, with what the page says of each.
const Core = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    empty: []const u8,
};

const core = [_]Core{
    .{
        .name = @import("../../sdk/messaging.zig").contract.contract_name,
        .label = "Messaging",
        .description = "Email, text messages and notifications the site sends. Each " ++
            "message goes to the first provider switched on that covers its channel.",
        .empty = "No provider: Publr sends no message, and nothing fails.",
    },
    .{
        .name = @import("../../sdk/ai.zig").contract.contract_name,
        .label = "AI models",
        .description = "The models the AI workspace and agents can use.",
        .empty = "No provider: install one to build with a model on your own key.",
    },
};

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &list);
    router.post(back ++ "/:contract", &save);
}

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const saved = admin.query_param(&session, "saved") != null;
    const notice = if (saved) try session.translated("Saved.", .{}) else "";

    try screen(&session, .ok, notice, "");
}

fn screen(
    session: *admin.Session,
    status: admin.Status,
    notice: []const u8,
    problem: []const u8,
) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(notice.len == 0 or problem.len == 0);

    const arena = session.arena;
    const names = try contract_names(session);
    const shown = try arena.alloc(views.Providers.ContractsItem, names.len);

    for (names, shown) |name, *item| {
        const listed = registry.SDK.dispatch(&session.ctx, provider.List, .{
            .contract = name,
        }) catch |err| {
            return admin.fail(session, err, "/admin/settings");
        };
        const rows = try arena.alloc(Row, listed.providers.len);

        for (listed.providers, listed.on, rows, 0..) |one, on, *row, index| {
            row.* = .{
                .name = one.name,
                .plugin = one.plugin,
                .parts = try parts_of(arena, one),
                .on = on,
                .first = index == 0,
                .last = index + 1 == rows.len,
                .settings_href = try std.fmt.allocPrint(arena, "/admin/settings/plugins/{s}", .{
                    one.plugin,
                }),
            };
        }

        const words = core_of(name);

        item.* = .{
            .name = name,
            .label = if (words) |found| try session.declared(found.label) else name,
            .description = if (words) |found| try session.declared(found.description) else "",
            .empty = if (words) |found|
                try session.declared(found.empty)
            else
                try session.translated("No provider.", .{}),
            .action = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, name }),
            .providers = rows,
        };
    }

    try admin.screen(session, status, views.Providers, .{
        .contracts = shown,
        .notice = notice,
        .problem = problem,
    }, .{});
}

/// Core's contracts, then every other one a provider registered into, as first met.
fn contract_names(session: *admin.Session) Error![]const []const u8 {
    std.debug.assert(session.signed_in());

    var names: std.ArrayList([]const u8) = .empty;

    for (core) |each| {
        try names.append(session.arena, each.name);
    }

    for (registry.providers) |one| {
        try add_new(session.arena, &names, one.contract);
    }

    if (session.ctx.sandboxed_plugins) |sandboxed| {
        for (sandboxed.manifests()) |manifest| {
            for (manifest.providers) |one| {
                try add_new(session.arena, &names, one.contract);
            }
        }
    }

    return names.items;
}

fn add_new(
    arena: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    name: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);

    for (names.items) |each| {
        if (std.mem.eql(u8, each, name)) {
            return;
        }
    }

    try names.append(arena, name);
}

fn core_of(name: []const u8) ?Core {
    std.debug.assert(name.len > 0);

    for (core) |each| {
        if (std.mem.eql(u8, each.name, name)) {
            return each;
        }
    }

    return null;
}

/// Its parts, joined: "channels, send, attachments".
fn parts_of(arena: std.mem.Allocator, one: contract.Registered) Error![]const u8 {
    std.debug.assert(one.parts.len <= contract.parts_max);

    const names = try arena.alloc([]const u8, one.parts.len);

    for (one.parts, names) |part, *each| {
        each.* = part.part;
    }

    return std.mem.join(arena, ", ", names);
}

/// `POST /admin/settings/providers/:contract`: the providers as listed (`provider`, in
/// order), those switched on (`on`), and a move (`move` = `up:<name>` or `down:<name>`).
pub fn save(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "contract", back) orelse return;
    const arena = session.arena;
    var order: std.ArrayList([]const u8) = .empty;
    var on: std.ArrayList([]const u8) = .empty;

    for (post.form.pairs[0..post.form.len]) |pair| {
        if (pair.value.len == 0) {
            continue;
        }

        if (std.mem.eql(u8, pair.name, "provider") and order.items.len < contract.providers_max) {
            try order.append(arena, pair.value);
        } else if (std.mem.eql(u8, pair.name, "on") and on.items.len < contract.providers_max) {
            try on.append(arena, pair.value);
        }
    }

    if (post.form.text("move")) |move| {
        moved(order.items, move);
    }

    // What the administrator chose for providers not installed now stays as it was.
    const before = contract.choice_of(&session.ctx, name) catch |err| {
        return admin.fail(session, err, back);
    };
    var off: std.ArrayList([]const u8) = .empty;

    for (order.items) |each| {
        if (!named(on.items, each)) {
            try off.append(arena, each);
        }
    }

    for (before.off) |each| {
        if (!named(order.items, each)) {
            try off.append(arena, each);
        }
    }

    for (before.order) |each| {
        if (!named(order.items, each)) {
            try order.append(arena, each);
        }
    }

    _ = registry.SDK.dispatch(&session.ctx, provider.Set, .{
        .contract = name,
        .order = order.items,
        .off = off.items,
    }) catch |err| {
        const problem = if (session.ctx.failure) |failure| failure.message else @errorName(err);

        return screen(session, .unprocessable_content, "", problem);
    };

    try response.redirect(.see_other, back ++ "?saved=1");
}

/// `up:<name>` swaps it with the one before, `down:<name>` with the one after.
fn moved(order: [][]const u8, move: []const u8) void {
    std.debug.assert(order.len <= contract.providers_max);

    const colon = std.mem.indexOfScalar(u8, move, ':') orelse return;
    const up = std.mem.eql(u8, move[0..colon], "up");
    const target = move[colon + 1 ..];

    for (order, 0..) |each, index| {
        if (!std.mem.eql(u8, each, target)) {
            continue;
        }

        const other = if (up) index -% 1 else index + 1;

        if (other < order.len) {
            std.mem.swap([]const u8, &order[index], &order[other]);
        }

        return;
    }
}

fn named(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

test "a move swaps a provider with its neighbour, and never past the ends" {
    var order = [_][]const u8{ "smtp", "postmark", "cloud" };

    moved(&order, "up:postmark");
    try std.testing.expectEqualStrings("postmark", order[0]);
    moved(&order, "up:postmark");
    try std.testing.expectEqualStrings("postmark", order[0]);
    moved(&order, "down:smtp");
    try std.testing.expectEqualStrings("cloud", order[1]);
    try std.testing.expectEqualStrings("smtp", order[2]);
    moved(&order, "down:smtp");
    try std.testing.expectEqualStrings("smtp", order[2]);
}
