const std = @import("std");
const report_module = @import("../../lib/report.zig");
const registry = @import("../../server/registry.zig");
const identity_module = @import("../rest/identity.zig");
const record_operations = @import("../../operations/record.zig");
const deps = @import("../../lib/deps.zig");
const engine = @import("../../template.zig");
const context_module = @import("context.zig");
const build = @import("build.zig");
const artifacts = @import("artifacts.zig");
const Project = @import("../../server/project.zig").Project;
const App = @import("state.zig").App;

const islands_prefix = context_module.islands_prefix;

/// Renders the page or the static island `url` names in `app` again. A page whose entry is
/// gone, or an artifact the app no longer has, is removed and forgotten.
pub fn artifact(
    app: *App,
    project: *const Project,
    arena: std.mem.Allocator,
    batch: u64,
    url: []const u8,
) deps.Outcome {
    std.debug.assert(url.len > 0);
    std.debug.assert(batch > 0);

    const program = app.pages();

    if (std.mem.startsWith(u8, url, islands_prefix)) {
        return island(app, project, arena, batch, url);
    }

    const matched = program.match(url) orelse {
        remove_url(app, arena, url);

        return report(app, batch, url, .removed, "no route");
    };

    if (matched.route.live or matched.route.kind == .catch_all) {
        remove_url(app, arena, url);

        return report(app, batch, url, .removed, "rendered per request");
    }

    // Only a `[slug]` page has a record to lose; anywhere else "not found" is a failed
    // render, and the file it had stays.
    const params: context_module.Params = .{ .slug = matched.slug };
    const rendered = build.render_url(app, project, matched.route, url, params, .when_changed);
    const result = rendered catch |err| {
        if (err == error.EntryNotFound and matched.slug != null) {
            remove_url(app, arena, url);

            return report(app, batch, url, .removed, "its record is gone");
        }

        return report(app, batch, url, .failed, @errorName(err));
    };

    return report(app, batch, url, if (result.wrote) .written else .identical, "");
}

fn island(
    app: *App,
    project: *const Project,
    arena: std.mem.Allocator,
    batch: u64,
    url: []const u8,
) deps.Outcome {
    std.debug.assert(std.mem.startsWith(u8, url, islands_prefix));
    std.debug.assert(batch > 0);

    const key = url[islands_prefix.len..];

    if (app.pages().find_island(key)) |found| {
        if (!found.dynamic) {
            const rendered = build.render_island(app, project, found, .when_changed);
            const result = rendered catch |err| {
                return report(app, batch, url, .failed, @errorName(err));
            };
            const outcome: deps.Outcome = if (result.wrote) .written else .identical;

            return report(app, batch, url, outcome, "");
        }
    }

    remove_island(app, arena, key);

    return report(app, batch, url, .removed, "");
}

/// The observer's window into a rebuild. A removal or a failure is always said: a file
/// that vanished is what someone will ask about; the rest only under `log`.
fn report(
    app: *const App,
    batch: u64,
    url: []const u8,
    outcome: deps.Outcome,
    detail: []const u8,
) deps.Outcome {
    std.debug.assert(url.len > 0);
    std.debug.assert(batch > 0);

    var buffer: [artifacts.path_len_max + 64]u8 = undefined;
    const name = std.fmt.bufPrint(&buffer, "{s}:{s}", .{ app.spec.name, url }) catch url;

    app.index.executed(batch, name, outcome, detail);

    if (app.options.log or outcome == .removed or outcome == .failed) {
        std.debug.print("apps: rebuilt {s}: {s} {s}\n", .{ name, @tagName(outcome), detail });
    }

    return outcome;
}

/// A record that was just published has a page no plan can name yet: for every changed
/// record still readable by a visitor, its own routes in `app` are rendered outright
/// (unchanged bytes are not written), before the batch is planned like any other. How many
/// were written.
pub fn record_pages(
    app: *App,
    project: *const Project,
    arena: std.mem.Allocator,
    keys: []const []const u8,
) u32 {
    std.debug.assert(app.output != null);
    std.debug.assert(keys.len <= app.index.options.queue_cap);

    const prefix = "record:";
    var written: u32 = 0;

    for (keys) |key| {
        if (!std.mem.startsWith(u8, key, prefix)) {
            continue;
        }

        var sdk_ctx = identity_module.context(project, arena, .anonymous);
        const got = registry.SDK.dispatch(&sdk_ctx, record_operations.Get, .{
            .id = key[prefix.len..],
        }) catch continue;
        const slug = got.record.slug orelse continue;

        written += routes_of(app, project, arena, slug);
    }

    return written;
}

fn routes_of(app: *App, project: *const Project, arena: std.mem.Allocator, slug: []const u8) u32 {
    std.debug.assert(slug.len > 0);
    std.debug.assert(app.output != null);

    var written: u32 = 0;

    for (app.pages().routes) |*route| {
        if (route.kind != .dynamic or route.live) {
            continue;
        }

        const url = engine.substitute(arena, route.pattern, slug) catch return written;
        const params: context_module.Params = .{ .slug = slug };
        const rendered = build.render_url(app, project, route, url, params, .when_changed);
        const result = rendered catch |err| {
            report_module.err_reason(reason_of(app), "apps: {s}: {s}: {s}", .{
                app.spec.name,
                url,
                @errorName(err),
            });

            continue;
        };

        if (result.wrote) {
            written += 1;
        }
    }

    return written;
}

fn remove_url(app: *App, arena: std.mem.Allocator, url: []const u8) void {
    std.debug.assert(url.len > 0);
    std.debug.assert(app.output != null);

    const out = app.output.?;

    if (url.len <= 1) {
        out.deleteFile(app.io, "index.html") catch |err| report_removal(url, err);
    } else {
        out.deleteTree(app.io, url[1..]) catch |err| report_removal(url, err);
    }

    forget(app, arena, url);
}

fn remove_island(app: *App, arena: std.mem.Allocator, key: []const u8) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(app.output != null);

    const out = app.output.?;
    const path = artifacts.island_path(arena, key) catch return;
    const url = std.fmt.allocPrint(arena, "{s}{s}", .{ islands_prefix, key }) catch return;

    out.deleteFile(app.io, path) catch |err| report_removal(url, err);
    forget(app, arena, url);
}

fn forget(app: *App, arena: std.mem.Allocator, url: []const u8) void {
    std.debug.assert(url.len > 0);
    std.debug.assert(url[0] == '/');

    const name = artifacts.name(arena, app, url) catch return;

    app.index.forget(name) catch |err| {
        std.debug.print("apps: forget {s}: {s}\n", .{ name, @errorName(err) });
    };
}

/// A file that was already gone is what removal wanted; anything else is said.
fn report_removal(url: []const u8, err: anyerror) void {
    std.debug.assert(url.len > 0);
    std.debug.assert(@errorName(err).len > 0);

    if (err != error.FileNotFound) {
        std.debug.print("apps: remove {s}: {s}\n", .{ url, @errorName(err) });
    }
}

fn reason_of(app: *const App) []const u8 {
    std.debug.assert(app.spec.name.len > 0);

    return if (app.options.diagnostic) |reason| reason.text() else "";
}
