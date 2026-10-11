//! The design system builder's page: the element the editor's builder mounts on, carrying
//! what `design.system` reads, the moodboard's size and where Build and the agent lead.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const design_operations = @import("../../../operations/design.zig");
const ai = @import("../../../operations/ai.zig");
const definitions = @import("../definitions.zig");
const editor_site = @import("../editor_site.zig");
const library_module = @import("library.zig");
const App = @import("../../apps/state.zig").App;

const Error = admin.Error;
const Session = admin.Session;

pub fn screen(session: *Session, app: *const App) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(app.spec.name.len > 0);

    const arena = session.arena;
    const read = registry.SDK.dispatch(&session.ctx, design_operations.System, .{
        .app = app.spec.name,
    }) catch |err| return admin.fail(session, err, "/admin/design/templates");
    const board = registry.SDK.dispatch(&session.ctx, design_operations.Moodboard, .{
        .app = app.spec.name,
    }) catch |err| return admin.fail(session, err, "/admin/design/templates");
    const base = session.project.admin_path();
    const library = library_module.library_json(session, app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => "",
    };

    try admin.screen(session, .ok, admin.views.DesignSystem, .{
        .app = app.spec.name,
        .app_label = app.spec.label,
        .system = try std.json.Stringify.valueAlloc(arena, read, .{}),
        .editor_site = try editor_site.json(session, app.spec.name),
        .library = library,
        .moodboard_count = @floatFromInt(board.items.len),
        .ai_ready = ai.connected(&session.ctx),
        .ai_settings_href = try std.fmt.allocPrint(arena, "{s}/admin/settings/ai", .{base}),
        .ask_href = try std.fmt.allocPrint(arena, "{s}/admin/ai/ask", .{base}),
        .moodboard_href = try std.fmt.allocPrint(arena, "{s}/admin/design/moodboard?app={s}", .{
            base,
            app.spec.name,
        }),
        .content_href = try std.fmt.allocPrint(arena, "{s}/admin/content", .{base}),
        .agent_href = try std.fmt.allocPrint(arena, "{s}/admin?mode=agents", .{base}),
        .devices_href = try std.fmt.allocPrint(arena, "{s}/admin/settings/devices", .{base}),
        .site = try std.fmt.allocPrint(arena, "{s}{s}", .{
            try definitions.host_url_of(session),
            base,
        }),
    });
}
