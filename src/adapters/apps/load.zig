const std = @import("std");
const deps = @import("../../lib/deps.zig");
const model_app = @import("../../model/app.zig");
const spec = @import("spec.zig");
const state = @import("state.zig");
const Project = @import("../../server/project.zig").Project;
const OwnedTranslation = @import("../../sdk/plugin.zig").OwnedTranslation;

const App = state.App;

/// Every app of `specs` loaded into `apps`, one each, in order, and the project pointed at
/// them. An app that does not load fails them all, naming the app and the template.
pub fn open(
    project: *Project,
    specs: []const spec.Spec,
    apps: []App,
    gpa: std.mem.Allocator,
    index: *deps.Index,
    now_ms: i64,
    options: state.Options,
) App.Error!void {
    std.debug.assert(apps.len == specs.len);
    std.debug.assert(project.apps.len == 0);

    var loaded: u32 = 0;
    errdefer for (apps[0..loaded]) |*app| app.deinit();

    for (specs, apps) |*app_spec, *app| {
        try app.init(app_spec, gpa, project.io, index, now_ms, options);
        loaded += 1;
    }

    project.apps = apps;
    project.domain = model_app.domain_of(options.base_url);

    // Their own words' translations join the catalogues; a file that does not build is
    // logged and left out, the apps load all the same.
    if (project.languages) |languages| {
        own_words(languages, gpa, specs) catch |err| {
            std.log.err("apps: their translations are left out: {t}", .{err});
        };
    }

    std.debug.assert(project.apps.len == specs.len);
}

/// Each app's `i18n/<locale>.po`, the app its own domain, handed to the catalogues.
fn own_words(
    languages: *@import("../../server/languages.zig").Languages,
    gpa: std.mem.Allocator,
    specs: []const spec.Spec,
) !void {
    std.debug.assert(specs.len <= spec.apps_max);
    std.debug.assert(languages.list.len <= @import("../../server/languages.zig").languages_max);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var brought: std.ArrayList(OwnedTranslation) = .empty;

    for (specs) |app_spec| {
        for (app_spec.translations) |file| {
            if (!std.mem.endsWith(u8, file.path, ".po") or file.path.len == ".po".len) {
                continue;
            }

            const locale = file.path[0 .. file.path.len - ".po".len];

            try brought.append(arena, .{
                .plugin = app_spec.name,
                .translation = .{
                    .locale = locale,
                    .label = locale,
                    .po = file.data,
                },
            });
        }
    }

    try languages.set_apps(brought.items);
}

pub fn close(project: *Project) void {
    std.debug.assert(project.apps.len <= spec.apps_max);
    std.debug.assert(project.connection.transaction_depth == 0);

    for (project.apps) |*app| {
        app.deinit();
    }

    project.apps = &.{};
}
