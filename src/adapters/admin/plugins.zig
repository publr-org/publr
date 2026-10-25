//! Installed plugins in the admin, under Settings: one list of every plugin added, running or
//! not; the review before enabling one or applying its update; and a plugin's own page,
//! where each permission and each of its flags is switched on or off and a version rolled
//! back. A built-in plugin has the same page, read only.
const std = @import("std");
const plugin_define = @import("../../sdk/plugin/define.zig");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const plugin_operations = @import("../../operations/plugin.zig");
const settings_nav = @import("settings_nav.zig");
const rows = @import("plugins/rows.zig");
const secret_operations = @import("../../operations/secret.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;

const webhooks_tab = @import("plugins/webhooks.zig");

pub const back = "/admin/settings/plugins";
const page_size: u32 = 50;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &list);
    router.get(back ++ "/built-in", &built_in);
    router.get(back ++ "/:name", &show);
    router.get(back ++ "/:name/log", &@import("plugins/log.zig").show);
    router.get(back ++ "/:name/webhooks", &webhooks_tab.show);
    router.post(back ++ "/:name/webhooks/:id/run", &webhooks_tab.run_again);
    router.get(back ++ "/:name/enable", &review_enable);
    router.post(back ++ "/:name/enable", &enable);
    router.post(back ++ "/:name/disable", &disable);
    router.get(back ++ "/:name/update", &review_update);
    router.post(back ++ "/:name/update", &update);
    router.post(back ++ "/:name/cancel-update", &cancel_update);
    router.post(back ++ "/:name/rollback", &rollback);
    router.post(back ++ "/:name/grants", &switch_grants);
    router.post(back ++ "/:name/remove", &remove);
    router.post(back ++ "/:name/removal", &removal);
}

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const offset = admin.pager.offset_of(&session);
    const built_ins: u32 = registry.native_plugins.all.len;
    // The installed ones come after the built-in ones in the list: the page starts there.
    const listed = registry.SDK.dispatch(&session.ctx, plugin_operations.List, .{
        .offset = built_ins + offset,
        .limit = page_size,
    }) catch |err| {
        return admin.fail(&session, err, "/admin/settings");
    };
    const arena = session.arena;
    var shown: std.ArrayList(views.Plugins.PluginsItem) = .empty;

    for (listed.plugins) |summary| {
        if (summary.mode != .sandboxed) {
            continue;
        }

        const row = try shown.addOne(arena);
        const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, summary.name });

        row.* = .{
            .href = base,
            .name = summary.name,
            .version = summary.version,
            .summary = summary.summary,
            .enabled = summary.enabled,
            .pending = if (summary.pending == 0) "" else try std.fmt.allocPrint(arena, "{d}", .{
                summary.pending,
            }),
            .update = summary.update orelse "",
            .enable_href = try std.fmt.allocPrint(arena, "{s}/enable", .{base}),
            .update_href = try std.fmt.allocPrint(arena, "{s}/update", .{base}),
            .disable_action = try std.fmt.allocPrint(arena, "{s}/disable", .{base}),
        };
    }

    const pages = try admin.pager.links(
        arena,
        back,
        offset,
        @intCast(shown.items.len),
        listed.total -| built_ins,
        page_size,
    );

    try admin.screen(&session, .ok, views.Plugins, .{
        .tab = "installed",
        .built_in = &.{},
        .off = &.{},
        .plugins = shown.items,
        .range = pages.range,
        .previous_href = pages.previous_href,
        .next_href = pages.next_href,
    }, .{});
}

/// The Built-in tab: the plugins compiled into this binary. Nothing to decide about them:
/// a build puts them there, granted what they ask for, and only a new build changes them.
pub fn built_in(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;

    if (!registry.SDK.may(&session.ctx, plugin_operations.List)) {
        return admin.fail(&session, error.Denied, "/admin/settings");
    }

    const all = registry.native_plugins.all;
    var shown: [all.len]views.Plugins.Built_inItem = undefined;

    inline for (all, 0..) |Plugin, index| {
        shown[index] = .{
            .name = Plugin.manifest.name,
            .version = Plugin.manifest.version,
            .summary = Plugin.manifest.summary,
            .brings = comptime brings_of(Plugin),
            .href = back ++ "/" ++ Plugin.manifest.name,
        };
    }

    const off = plugin_operations.contracts.native_off(&session.ctx) catch |err| {
        return admin.fail(&session, err, "/admin/settings");
    };
    const off_items = try session.arena.alloc(views.Plugins.OffItem, off.len);

    for (off, off_items) |remote, *item| {
        item.* = .{
            .code = remote.name,
            .text = remote.why,
        };
    }

    try admin.screen(&session, .ok, views.Plugins, .{
        .tab = "built_in",
        .built_in = &shown,
        .off = off_items,
        .plugins = &.{},
        .range = "",
        .previous_href = "",
        .next_href = "",
    }, .{});
}

/// What a native plugin brings, counted: `2 operations, 1 content type, 1 role`.
fn brings_of(comptime Plugin: type) []const u8 {
    comptime {
        const contract = @import("../../sdk/plugin.zig");
        const options = std.meta.fields(@TypeOf(Plugin.options)).len;

        // Each of its options' names against the option and seam names, a byte at a time.
        @setEvalBranchQuota(1000 + options * 64 * 64);

        const Count = struct {
            count: u32,
            one: []const u8,
            many: []const u8,
        };
        const counts = [_]Count{
            .{
                .count = plugin_define.get(Plugin, "operations").len,
                .one = "operation",
                .many = "operations",
            },
            .{
                .count = plugin_define.get(Plugin, "content_types").len,
                .one = "content type",
                .many = "content types",
            },
            .{
                .count = plugin_define.get(Plugin, "middleware").len,
                .one = "hook",
                .many = "hooks",
            },
            .{
                .count = contract.roles_of(Plugin).len,
                .one = "role",
                .many = "roles",
            },
        };

        std.debug.assert(Plugin.manifest.name.len > 0);
        var text: []const u8 = "";

        for (counts) |item| {
            if (item.count == 0) {
                continue;
            }

            const separator = if (text.len == 0) "" else ", ";
            const noun = if (item.count == 1) item.one else item.many;

            text = text ++ separator ++ std.fmt.comptimePrint("{d} {s}", .{ item.count, noun });
        }

        return if (text.len == 0) "Nothing of its own" else text;
    }
}

/// What an installed plugin says about itself, through the admin's sanitizer; null when it
/// says nothing or it does not read cleanly.
fn about_of(session: *const Session, name: []const u8) Error!?admin.render.Node {
    std.debug.assert(name.len > 0);

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return cleaned_of(session, Plugin.settings_text);
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return null;

    for (sandboxed.manifests()) |manifest| {
        if (std.mem.eql(u8, manifest.name, name)) {
            return cleaned_of(session, manifest.about);
        }
    }

    return null;
}

fn cleaned_of(session: *const Session, about: []const u8) ?admin.render.Node {
    std.debug.assert(about.len <= 64 << 10);
    std.debug.assert(session.signed_in());

    if (about.len == 0) {
        return null;
    }

    const sanitize = @import("../../lib/sanitize.zig");
    const cleaned = sanitize.sanitize(session.arena, about, .admin) catch return null;

    return admin.render.raw(cleaned);
}

/// A plugin's own page; a built-in one's without what a build decides: enabling, grants,
/// versions, removal.
pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const name = try admin.param(&session, "name", back) orelse return;
    const detail = try get(&session, name) orelse return;
    const arena = session.arena;
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, detail.name });
    var pieces: std.ArrayList(PieceRow) = .empty;

    const compiled_in = detail.mode == .native;

    try pieces.appendSlice(arena, try pieces_of(&session, detail.name));
    try admin.screen(&session, .ok, views.Plugin, .{
        .name = detail.name,
        .built_in = compiled_in,
        .plugins_href = if (compiled_in) back ++ "/built-in" else back,
        .version = detail.version,
        .summary = detail.summary,
        .about = try about_of(&session, detail.name),
        .enabled = detail.enabled,
        .update = if (detail.update) |next| next.version else "",
        .update_href = try std.fmt.allocPrint(arena, "{s}/update", .{base}),
        .previous = detail.previous orelse "",
        .enable_href = try std.fmt.allocPrint(arena, "{s}/enable", .{base}),
        .disable_action = try std.fmt.allocPrint(arena, "{s}/disable", .{base}),
        .rollback_action = try std.fmt.allocPrint(arena, "{s}/rollback", .{base}),
        .grants_action = try std.fmt.allocPrint(arena, "{s}/grants", .{base}),
        .remove_action = try std.fmt.allocPrint(arena, "{s}/remove", .{base}),
        .requests = try rows.requests(
            views.Plugin.RequestsItem,
            &session,
            detail.requests,
            detail.secrets,
            if (compiled_in) .read_only else .switches,
        ),
        .missing = try rows.missing(&session, detail.secrets),
        .removal_action = if (compiled_in) "" else try std.fmt.allocPrint(arena, "{s}/removal", .{
            base,
        }),
        .pieces = pieces.items,
        .removes = try removes_of(&session, pieces.items),
        .log_href = try std.fmt.allocPrint(arena, "{s}/log", .{base}),
        .webhooks_href = if (webhooks_tab.has_webhooks(&session, detail.name))
            try std.fmt.allocPrint(arena, "{s}/webhooks", .{base})
        else
            "",
        .blocked = try lines_of(views.Plugin.BlockedItem, arena, detail.blocked),
        .off = try off_of(arena, detail.off),
        .warnings = try lines_of(
            views.Plugin.WarningsItem,
            arena,
            detail.warnings[0..@min(detail.warnings.len, 64)],
        ),
    }, .{});
}

/// Lines of words as a callout's items, each without a code.
fn lines_of(comptime Item: type, arena: std.mem.Allocator, lines: []const []const u8) Error![]Item {
    const items = try arena.alloc(Item, lines.len);

    std.debug.assert(lines.len <= 64);

    for (lines, items) |line, *item| {
        item.* = .{
            .code = "",
            .text = line,
        };
    }

    return items;
}

fn off_of(
    arena: std.mem.Allocator,
    off: []const plugin_operations.contracts.Off,
) Error![]views.Plugin.OffItem {
    const items = try arena.alloc(views.Plugin.OffItem, off.len);

    std.debug.assert(off.len <= 64);

    for (off, items) |remote, *item| {
        item.* = .{
            .code = remote.name,
            .text = remote.why,
        };
    }

    return items;
}

const PieceRow = views.Plugin.PiecesItem;

fn pieces_of(session: *Session, name: []const u8) Error![]PieceRow {
    std.debug.assert(session.signed_in());

    const read = registry.SDK.dispatch(&session.ctx, plugin_operations.Data, .{
        .name = name,
    }) catch return &.{};
    const pieces = try session.arena.alloc(PieceRow, read.pieces.len);

    for (read.pieces, pieces) |piece, *row| {
        const detail = switch (piece.kind) {
            .type => try session.translated_count(
                "Content type, {count} record",
                "Content type, {count} records",
                piece.count,
            ),
            .taxonomy => try session.translated_count(
                "Taxonomy, {count} term",
                "Taxonomy, {count} terms",
                piece.count,
            ),
            .internal => try session.translated_count(
                "Internal records, {count}",
                "Internal records, {count}",
                piece.count,
            ),
            .fields => try session.translated(
                "Custom field group: the fields, not what records hold in them",
                .{},
            ),
            .role => try session.translated_count(
                "Role, held by {count} account",
                "Role, held by {count} accounts",
                piece.count,
            ),
        };

        row.* = .{
            .key = piece.key,
            .label = piece.label,
            .detail = detail,
            .chosen = piece.chosen,
        };
    }

    return pieces;
}

fn removes_of(session: *const Session, pieces: []const PieceRow) Error![]const u8 {
    std.debug.assert(pieces.len <= 1024);

    const arena = session.arena;

    var going: std.ArrayList(u8) = .empty;

    for (pieces) |piece| {
        if (!piece.chosen) {
            continue;
        }

        const separator: []const u8 = if (going.items.len > 0) ", " else "";

        try going.print(arena, "{s}{s}", .{ separator, piece.label });
    }

    const stops = try session.translated("Its operations and hooks stop.", .{});

    if (going.items.len == 0) {
        const stays = try session.translated(
            "It goes to the trash, restorable; all its data stays.",
            .{},
        );

        return std.fmt.allocPrint(arena, "{s} {s}", .{ stops, stays });
    }

    const goes = try session.translated(
        "It goes to the trash with {pieces}, restorable together; the rest of its data stays.",
        .{
            .values = &.{.{
                .name = "pieces",
                .value = going.items,
            }},
        },
    );

    return std.fmt.allocPrint(arena, "{s} {s}", .{ stops, goes });
}

/// What goes with the plugin when it is removed.
pub fn removal(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;
    const chosen = try @import("type_fields/settings.zig").values_of(
        session.arena,
        &post.form,
        "remove",
    );

    _ = registry.SDK.dispatch(&session.ctx, plugin_operations.ChooseRemoval, .{
        .name = name,
        .remove = chosen,
    }) catch |err| return admin.fail(session, err, back);

    try redirect_to(session, name);
}

/// The enabling screen: what the plugin asks for, before it runs.
pub fn review_enable(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const name = try admin.param(&session, "name", back) orelse return;
    const detail = try get(&session, name) orelse return;
    const arena = session.arena;
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, detail.name });

    if (detail.enabled) {
        return session.response.redirect(.see_other, base);
    }

    try render_review(&session, .{
        .title = try session.translated(
            "Enable {plugin} {version}",
            .{
                .values = &.{
                    .{
                        .name = "plugin",
                        .value = detail.name,
                    },
                    .{
                        .name = "version",
                        .value = detail.version,
                    },
                },
            },
        ),
        .summary = detail.summary,
        .action = try std.fmt.allocPrint(arena, "{s}/enable", .{base}),
        .allow_label = try session.translated("Allow & Enable", .{}),
        .cancel_href = back,
        .discard_action = "",
        .requests_title = try session.translated("This plugin wants to", .{}),
        .requests = try rows.requests(
            views.PluginReview.RequestsItem,
            &session,
            detail.requests,
            detail.secrets,
            .review,
        ),
        .granted = &.{},
        .note_text = try session.translated(
            "What you leave switched on is granted when it starts; what you switch off is " ++
                "not. You can change any of it on its page at any time.",
            .{},
        ),
        .stops_title = try session.translated("Can't be enabled", .{}),
        .stops = try lines_of(views.PluginReview.StopsItem, arena, detail.blocked),
        .switches_off = &.{},
    });
}

/// The update screen: the newer version's requests, new ones above what it holds already.
pub fn review_update(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const name = try admin.param(&session, "name", back) orelse return;
    const detail = try get(&session, name) orelse return;
    const arena = session.arena;
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, detail.name });
    const next = detail.update orelse return session.response.redirect(.see_other, base);
    const split = try rows.split_update(&session, next.requests, detail.requests);

    try render_review(&session, .{
        .title = try session.translated(
            "Update {plugin} from {version} to {next}",
            .{
                .values = &.{
                    .{
                        .name = "plugin",
                        .value = detail.name,
                    },
                    .{
                        .name = "version",
                        .value = detail.version,
                    },
                    .{
                        .name = "next",
                        .value = next.version,
                    },
                },
            },
        ),
        .summary = detail.summary,
        .action = try std.fmt.allocPrint(arena, "{s}/update", .{base}),
        .allow_label = try session.translated("Allow & Update", .{}),
        .cancel_href = base,
        .discard_action = try std.fmt.allocPrint(arena, "{s}/cancel-update", .{base}),
        .requests_title = try session.translated("This version also wants to", .{}),
        .requests = split.fresh,
        .granted = split.held,
        .note_text = try update_note(&session),
        .stops_title = try session.translated(
            "Can't update yet: these plugins need the version running now",
            .{},
        ),
        .stops = try lines_of(views.PluginReview.StopsItem, arena, next.stops),
        .switches_off = try lines_of(
            views.PluginReview.Switches_offItem,
            arena,
            next.switches_off,
        ),
    });
}

fn update_note(session: *const Session) Error![]const u8 {
    std.debug.assert(session.signed_in());

    const grants = try session.translated(
        "Allowing grants everything the new version asks for.",
        .{},
    );
    const kept = try session.translated(
        "The version it replaces is kept: you can roll back to it from the plugin's page.",
        .{},
    );

    return std.fmt.allocPrint(session.arena, "{s} {s}", .{ grants, kept });
}

const Review = struct {
    title: []const u8,
    summary: []const u8,
    action: []const u8,
    allow_label: []const u8,
    cancel_href: []const u8,
    discard_action: []const u8,
    requests_title: []const u8,
    requests: []const views.PluginReview.RequestsItem,
    granted: []const views.PluginReview.GrantedItem,
    note_text: []const u8,
    stops_title: []const u8,
    stops: []const views.PluginReview.StopsItem,
    switches_off: []const views.PluginReview.Switches_offItem,
};

fn render_review(session: *Session, review: Review) Error!void {
    std.debug.assert(review.title.len > 0);
    std.debug.assert(review.action.len > 0);

    try admin.screen(session, .ok, views.PluginReview, .{
        .title = review.title,
        .summary = review.summary,
        .action = review.action,
        .allow_label = review.allow_label,
        .cancel_href = review.cancel_href,
        .discard_action = review.discard_action,
        .requests_title = review.requests_title,
        .requests = review.requests,
        .granted = review.granted,
        .note_text = review.note_text,
        .stops_title = review.stops_title,
        .stops = review.stops,
        .switches_off = review.switches_off,
    }, .{});
}

/// Enables it with what the review left switched on: each key on or off, each flag.
pub fn enable(request: *Request, response: *Response, ctx: *Context) Error!void {
    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;
    const detail = try get(session, name) orelse return;
    const chosen = try rows.choices_of(session.arena, &post.form, detail.requests, true);

    std.debug.assert(request.method() == .post);

    _ = registry.SDK.dispatch(&session.ctx, plugin_operations.Enable, .{
        .names = &.{name},
        .grants = chosen,
    }) catch |err| return admin.fail(session, err, back);

    try set_secrets(session, &post.form, detail.secrets);
    try redirect_to(session, name);
}

/// Saves the switches of the plugin's page: each request that changed, one at a time.
pub fn switch_grants(request: *Request, response: *Response, ctx: *Context) Error!void {
    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;
    const detail = try get(session, name) orelse return;
    const chosen = try rows.choices_of(session.arena, &post.form, detail.requests, false);

    std.debug.assert(request.method() == .post);

    for (chosen) |choice| {
        _ = registry.SDK.dispatch(&session.ctx, plugin_operations.SetGrant, .{
            .name = name,
            .key = choice.key,
            .on = choice.on,
            .drafts = choice.drafts,
            .private = choice.private,
            .internal = choice.internal,
            .publish = choice.publish,
            .domains = choice.domains,
        }) catch |err| return admin.fail(session, err, back);
    }

    try set_secrets(session, &post.form, detail.secrets);
    try redirect_to(session, name);
}

/// Keeps what the form typed for the plugin's secrets (`secret.set`, which never answers a
/// value); an empty field leaves its secret as it is.
fn set_secrets(
    session: *Session,
    form: *const admin.Form,
    secrets: []const rows.Secret,
) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(secrets.len <= 32);

    for (try rows.secrets_posted(session.arena, form, secrets)) |typed| {
        _ = registry.SDK.dispatch(&session.ctx, secret_operations.Set, .{
            .name = typed.name,
            .value = typed.value,
        }) catch |err| return admin.fail(session, err, back);
    }
}

/// A change to one plugin by its name alone: it lands back on the plugin's page, or on
/// the list when the form says so (`next=list`) or the plugin is gone.
fn Change(comptime Operation: type) type {
    return struct {
        pub fn handle(request: *Request, response: *Response, ctx: *Context) Error!void {
            var post = try admin.accept(request, response, ctx, back) orelse return;
            const session = &post.session;
            const name = try admin.param(session, "name", back) orelse return;

            std.debug.assert(request.method() == .post);

            _ = registry.SDK.dispatch(&session.ctx, Operation, .{
                .name = name,
            }) catch |err| return admin.fail(session, err, back);

            const to_list = std.mem.eql(u8, post.form.text("next") orelse "", "list");

            if (to_list or Operation == plugin_operations.Remove) {
                return session.response.redirect(.see_other, back);
            }

            try redirect_to(session, name);
        }
    };
}

/// Disable from the plugin's page: the one plugin, refused in words while others need it.
fn disable(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, plugin_operations.Disable, .{
        .names = &.{name},
    }) catch |err| return admin.fail(session, err, back);

    if (std.mem.eql(u8, post.form.text("next") orelse "", "list")) {
        return session.response.redirect(.see_other, back);
    }

    try redirect_to(session, name);
}
const update = Change(plugin_operations.Update).handle;
const cancel_update = Change(plugin_operations.CancelUpdate).handle;
const rollback = Change(plugin_operations.Rollback).handle;
const remove = Change(plugin_operations.Remove).handle;

/// The plugin called `name`, or null after the page that says why.
fn get(session: *Session, name: []const u8) Error!?plugin_operations.Detail {
    std.debug.assert(name.len > 0);

    const in: plugin_operations.Get.In = .{
        .name = name,
    };

    return registry.SDK.dispatch(&session.ctx, plugin_operations.Get, in) catch |err| {
        try admin.fail(session, err, back);

        return null;
    };
}

fn redirect_to(session: *Session, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    const location = try std.fmt.allocPrint(session.arena, "{s}/{s}", .{ back, name });

    try session.response.redirect(.see_other, location);
}
