const std = @import("std");
const deps = @import("../../lib/deps.zig");
const model_app = @import("../../model/app.zig");
const spec = @import("spec.zig");
const state = @import("state.zig");
const Project = @import("../../server/project.zig").Project;

const App = state.App;

/// Every app of `specs` loaded into `apps`, one each, in order, and the project pointed at
/// them. An app that does not load fails them all, naming the app and the template.
pub fn open(
    project: *Project,
    specs: []const spec.Spec,
    apps: []App,
    gpa: std.mem.Allocator,
    index: *deps.Index,
    options: state.Options,
    now_ms: i64,
) App.Error!void {
    std.debug.assert(apps.len == specs.len);
    std.debug.assert(project.apps.len == 0);

    var loaded: u32 = 0;
    errdefer for (apps[0..loaded]) |*app| app.deinit();

    for (specs, apps) |*app_spec, *app| {
        try app.init(app_spec, gpa, project.io, index, options, now_ms);
        loaded += 1;
    }

    project.apps = apps;
    project.domain = model_app.domain_of(options.base_url);

    std.debug.assert(project.apps.len == specs.len);
}

pub fn close(project: *Project) void {
    std.debug.assert(project.apps.len <= spec.apps_max);
    std.debug.assert(project.connection.transaction_depth == 0);

    for (project.apps) |*app| {
        app.deinit();
    }

    project.apps = &.{};
}
