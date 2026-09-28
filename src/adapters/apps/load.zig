const std = @import("std");
const deps = @import("../../lib/deps.zig");
const model_app = @import("../../model/app.zig");
const spec = @import("spec.zig");
const state = @import("state.zig");
const Project = @import("../../server/project.zig").Project;

const App = state.App;

/// Every compiled-in app loaded into `apps`, one per app in the order of their names, and
/// the project pointed at them. An app that does not load fails them all: its template
/// errors are the build's to catch (`publr check-apps`), not the first request's.
pub fn open(
    project: *Project,
    apps: []App,
    gpa: std.mem.Allocator,
    index: *deps.Index,
    options: state.Options,
    now_ms: i64,
) App.Error!void {
    std.debug.assert(apps.len == spec.all.len);
    std.debug.assert(project.apps.len == 0);

    var loaded: u32 = 0;
    errdefer for (apps[0..loaded]) |*app| app.deinit();

    for (spec.all, apps) |*app_spec, *app| {
        try app.init(app_spec, gpa, project.io, index, options, now_ms);
        loaded += 1;
    }

    project.apps = apps;
    project.domain = model_app.domain_of(options.base_url);

    std.debug.assert(project.apps.len == spec.all.len);
}

pub fn close(project: *Project) void {
    std.debug.assert(project.apps.len <= spec.all.len);
    std.debug.assert(project.connection.transaction_depth == 0);

    for (project.apps) |*app| {
        app.deinit();
    }

    project.apps = &.{};
}
