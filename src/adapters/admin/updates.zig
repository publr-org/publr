//! Settings › Updates: the Publr this site runs, newer releases and updating to one, going
//! back, and the backups taken before each update. Where Publr Cloud runs the site, only
//! what it runs.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const update = @import("../../operations/update.zig");
const time = @import("../../lib/time.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const path = "/admin/settings/updates";
pub const routes_count: u32 = 1;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(path, &show);
}

pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const status = registry.SDK.dispatch(&session.ctx, update.Status, .{}) catch |err| {
        return admin.fail(&session, err, "/admin/settings");
    };
    const arena = session.arena;
    const rows = try arena.alloc(views.Updates.BackupsItem, status.backups.len);

    for (status.backups, rows) |backup, *row| {
        row.* = .{
            .name = backup.name,
            .from = if (backup.from.len == 0)
                try session.translated("a site from before 0.3.0")
            else
                backup.from,
            .to = backup.to,
            .at = time.datetime_text(arena, backup.at_ms) catch "",
        };
    }

    const label = try label_of(&session, status.step);
    const previous = status.previous orelse "";

    try admin.screen(&session, .ok, views.Updates, .{
        .version = status.version,
        .managed = status.managed,
        .step = status.step,
        .busy = label.len > 0,
        .step_label = label,
        .headline = try headline_of(&session, status),
        .back_label = try session.translated_with("Go back to {version}", &.{.{
            .name = "version",
            .value = previous,
        }}),
        .newest_label = try session.translated_with("Publr {version} is the newest release.", &.{.{
            .name = "version",
            .value = status.version,
        }}),
        .target = status.target,
        .message = status.message,
        .previous = previous,
        .backups = rows,
    });
}

/// What the page's callout says for the step: as the panel says it once it follows.
fn headline_of(session: *const admin.Session, status: update.Status.Out) Error![]const u8 {
    std.debug.assert(status.step.len > 0);
    std.debug.assert(session.signed_in());

    const current: []const admin.Placeholder = &.{.{
        .name = "version",
        .value = status.version,
    }};
    const target: []const admin.Placeholder = &.{.{
        .name = "version",
        .value = status.target,
    }};

    if (status.managed) {
        return session.translated_with("Publr {version}, kept up to date by Publr Cloud", current);
    }

    if (std.mem.eql(u8, status.step, "failed")) {
        return session.translated_with("The update to {version} did not go through", target);
    }

    if (std.mem.eql(u8, status.step, "done")) {
        return status.message;
    }

    return session.translated_with("Updating to {version}", target);
}

/// The step an update is at, as the page says it; empty when none is under way.
fn label_of(session: *const admin.Session, step: []const u8) Error![]const u8 {
    std.debug.assert(step.len > 0);
    std.debug.assert(session.signed_in());

    if (std.mem.eql(u8, step, "starting")) {
        return session.translated("Starting");
    }

    if (std.mem.eql(u8, step, "downloading")) {
        return session.translated("Downloading the release");
    }

    if (std.mem.eql(u8, step, "verifying")) {
        return session.translated("Checking it is the release Publr signed");
    }

    if (std.mem.eql(u8, step, "rehearsing")) {
        return session.translated("Rehearsing on a copy of this site");
    }

    if (std.mem.eql(u8, step, "swapping")) {
        return session.translated("Backing up and swapping it in");
    }

    if (std.mem.eql(u8, step, "restarting")) {
        return session.translated("Restarting");
    }

    return "";
}
