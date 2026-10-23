//! Settings › Site Health: the broken references, each with what settles it (restore the
//! record, share its type again, take the reference out, keep it as it is), one at a time
//! or for the ticked ones.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const health = @import("../../operations/health.zig");
const record_operations = @import("../../operations/record.zig");
const types = @import("../../operations/content_type.zig");
const values_of = @import("type_fields/settings.zig").values_of;
const translations_tab = @import("health/translations.zig");
const translations = @import("../../operations/health/translations.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Item = views.Health.CasesItem;
const HolderItem = views.Health.HoldersItem;

pub const back = "/admin/health";
pub const routes_count: u32 = 5;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &list);
    router.post(back ++ "/act", &act);
    router.get(back ++ "/translations", &translations_tab.page);
    router.post(back ++ "/translations", &translations_tab.choose);
    router.get(back ++ "/translations/missing", &translations_tab.missing);
}

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const done = admin.query_param(&session, "done") orelse "";
    const notice = if (std.mem.eql(u8, done, "fixed"))
        try session.translated("Done: the record is back, or shared again.", .{})
    else if (std.mem.eql(u8, done, "unlinked"))
        try session.translated("The references were taken out of the records that held them.", .{})
    else if (std.mem.eql(u8, done, "kept"))
        try session.translated(
            "Kept as it is: it comes back here if anything about it changes.",
            .{},
        )
    else
        "";

    try screen(&session, notice, "");
}

fn screen(session: *Session, notice: []const u8, problem: []const u8) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(notice.len == 0 or problem.len == 0);
    var across = unfenced(session);

    const show_kept = admin.query_param(session, "kept") != null;
    const after = admin.query_param(session, "after") orelse "";
    const listed = registry.SDK.dispatch(&across, health.List, .{
        .kept = show_kept,
        .after = after,
    }) catch |err| return admin.fail(session, err, "/admin");
    const arena = session.arena;
    const items = try arena.alloc(Item, listed.cases.len);

    for (listed.cases, items) |case, *item| {
        item.* = try item_of(session, case);
    }

    const next_href = if (listed.next.len == 0)
        ""
    else
        try std.fmt.allocPrint(arena, "/admin/health?after={s}{s}", .{
            listed.next,
            if (show_kept) "&kept=1" else "",
        });

    const Listing = translations.Translations;
    const disagreeing = registry.SDK.dispatch(&session.ctx, Listing, .{}) catch |err| {
        return admin.fail(session, err, "/admin");
    };

    try admin.screen(session, .ok, views.Health, .{
        .translations_open = @floatFromInt(disagreeing.open),
        .cases = items,
        .kept = @floatFromInt(listed.kept),
        .show_kept = show_kept,
        .next_href = next_href,
        .notice = notice,
        .problem = problem,
        .unplaced = try unplaced_of(session),
    }, .{});
}

/// The field groups a location rule places that no compiled-in plugin brings any more.
fn unplaced_of(session: *Session) Error![]const views.Health.UnplacedItem {
    std.debug.assert(session.signed_in());

    const custom_fields = @import("../../operations/custom_fields.zig");
    const arena = session.arena;
    var found: std.ArrayList(views.Health.UnplacedItem) = .empty;
    const listed = registry.SDK.dispatch(&session.ctx, custom_fields.List, .{}) catch {
        return found.items;
    };

    for (listed.groups) |item| {
        const got = registry.SDK.dispatch(&session.ctx, custom_fields.Get, .{
            .group = item.handle,
        }) catch continue;

        for (got.definition.group.location) |group| {
            for (group.rules) |rule| {
                const plugin_rule = std.mem.indexOfScalar(u8, rule.field, '.') != null;

                if (!plugin_rule or model.field_group.find_rule(
                    registry.location_rules,
                    rule.field,
                ) != null) {
                    continue;
                }

                try found.append(arena, .{
                    .group = item.name,
                    .href = try std.fmt.allocPrint(arena, "/admin/custom-fields/{s}", .{
                        item.handle,
                    }),
                    .rule = rule.field,
                });
            }
        }
    }

    return found.items;
}

fn item_of(session: *Session, case: health.Case) Error!Item {
    std.debug.assert(case.target.len > 0);
    std.debug.assert(case.holders.len > 0);

    const arena = session.arena;
    const holders = try arena.alloc(HolderItem, case.holders.len);

    for (case.holders, holders) |holder, *item| {
        item.* = .{
            .title = if (holder.title.len > 0) holder.title else holder.id,
            .href = try std.fmt.allocPrint(arena, "/admin/content/{s}", .{holder.id}),
        };
    }

    const app = try app_label(session, case.app);
    const named: []const admin.Placeholder = &.{.{
        .name = "app",
        .value = app,
    }};

    return .{
        .key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ case.target, case.app }),
        .title = if (case.reason == .gone) try session.translated(
            "Removed record",
            .{},
        ) else case.title,
        .type_name = try type_name(session, case.type),
        .href = if (case.reason == .gone)
            ""
        else
            try std.fmt.allocPrint(arena, "/admin/content/{s}", .{case.target}),
        .why = switch (case.reason) {
            .deleted => try session.translated("Deleted, in the trash", .{}),
            .gone => try session.translated("Deleted for good", .{}),
            .not_shared => try session.translated("No longer shared with {app}", .{
                .values = named,
            }),
        },
        .holders = holders,
        .more_holders = if (case.holders_total > case.holders.len)
            try session.translated_count(
                "and {count} more",
                "and {count} more",
                case.holders_total - case.holders.len,
            )
        else
            "",
        .fix = switch (case.reason) {
            .deleted => try session.translated("Restore", .{}),
            .gone => "",
            .not_shared => try session.translated("Share with {app} again", .{
                .values = named,
            }),
        },
        .kept = case.kept,
    };
}

/// `POST /admin/health/act`: a row's button (`one`: `<action>|<target>|<app>`), or the
/// band's (`bulk`: `keep` or `unlink`) over the ticked cases (`case`: `<target>|<app>`).
pub fn act(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;

    if (post.form.get("one")) |one| {
        const bar = std.mem.indexOfScalar(u8, one, '|') orelse return admin.fail(
            session,
            error.Invalid,
            back,
        );

        return run(session, response, one[0..bar], &.{one[bar + 1 ..]});
    }

    const bulk = post.form.get("bulk") orelse return admin.fail(session, error.Invalid, back);
    const ticked = try values_of(session.arena, &post.form, "case");

    if (ticked.len == 0) {
        return screen(session, "", try session.translated("Tick the cases first.", .{}));
    }

    return run(session, response, bulk, ticked);
}

fn run(
    session: *Session,
    response: *Response,
    action: []const u8,
    keys: []const []const u8,
) Error!void {
    std.debug.assert(action.len > 0);
    std.debug.assert(keys.len > 0);

    for (keys) |key| {
        const bar = std.mem.indexOfScalar(u8, key, '|') orelse return admin.fail(
            session,
            error.Invalid,
            back,
        );
        const target = key[0..bar];
        const app = key[bar + 1 ..];

        settle(session, action, target, app) catch |err| {
            const failure = if (err == error.Failed) session.ctx.failure else null;

            return screen(session, "", if (failure) |found| found.message else @errorName(err));
        };
    }

    const done = if (std.mem.eql(u8, action, "fix"))
        "fixed"
    else if (std.mem.eql(u8, action, "unlink"))
        "unlinked"
    else
        "kept";
    const location = try std.fmt.allocPrint(session.arena, "{s}?done={s}", .{ back, done });

    try response.redirect(.see_other, location);
}

fn settle(session: *Session, action: []const u8, target: []const u8, app: []const u8) !void {
    std.debug.assert(action.len > 0);
    std.debug.assert(app.len <= 64);
    var across = unfenced(session);

    if (target.len == 0) {
        return error.Invalid;
    }

    if (std.mem.eql(u8, action, "keep")) {
        _ = try registry.SDK.dispatch(&across, health.Keep, .{
            .target = target,
            .app = app,
        });
    } else if (std.mem.eql(u8, action, "unlink")) {
        _ = try registry.SDK.dispatch(&across, health.Unlink, .{
            .target = target,
            .app = app,
        });
    } else if (std.mem.eql(u8, action, "fix")) {
        try fix(session, target, app);
    } else {
        return error.Invalid;
    }
}

/// A record in the trash back to draft; a type not shared, shared with the app again.
fn fix(session: *Session, target: []const u8, app: []const u8) !void {
    std.debug.assert(target.len > 0);
    std.debug.assert(session.signed_in());
    var across = unfenced(session);

    if (app.len == 0) {
        _ = try registry.SDK.dispatch(&across, record_operations.Transition, .{
            .id = target,
            .transition = "restore",
        });
        return;
    }

    const reach = try registry.SDK.dispatch(&across, record_operations.Reach, .{
        .id = target,
    });
    const got = try registry.SDK.dispatch(&across, types.Get, .{
        .type = reach.type,
    });
    var def = got.definition;
    const shared = model.content_type.shared_of(def);
    const apps = try session.arena.alloc([]const u8, shared.apps.len + 1);

    @memcpy(apps[0..shared.apps.len], shared.apps);
    apps[shared.apps.len] = app;
    def.shared = .{
        .all = shared.all,
        .apps = apps,
    };
    _ = try registry.SDK.dispatch(&across, types.Update, .{
        .type = def.handle,
        .definition = try model.content_type.encode(session.arena, def),
    });
}

/// The admin's context without the switcher's narrowing: Site Health is about every app,
/// and settling a case reaches what the app narrowed to does not (the type it lost).
fn unfenced(session: *Session) @import("../../sdk.zig").Ctx {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.ctx.now_ms > 0);

    var across = session.ctx;

    across.app_reach = "";
    across.app_plugins = null;

    return across;
}

fn app_label(session: *const Session, name: []const u8) Error![]const u8 {
    std.debug.assert(session.project.apps.len <= 1024);

    if (name.len == 0) {
        return session.translated("Global types", .{});
    }

    const app = session.project.find(name) orelse return name;

    return app.spec.label;
}

fn type_name(session: *Session, handle: []const u8) Error![]const u8 {
    std.debug.assert(session.signed_in());
    var across = unfenced(session);

    if (handle.len == 0) {
        return "";
    }

    const got = registry.SDK.dispatch(&across, types.Get, .{
        .type = handle,
    }) catch return handle;

    return got.definition.name;
}
