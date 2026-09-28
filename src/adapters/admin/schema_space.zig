//! The authoring destination determines navigation; all spaces share the field editor.
const std = @import("std");
const admin = @import("../admin.zig");
const Kind = @import("../../model.zig").content_type.Kind;

pub const Space = enum {
    content,
    taxonomies,
    settings,
    components,
    custom,

    pub fn base(space: Space) []const u8 {
        comptime std.debug.assert(@typeInfo(Space).@"enum".fields.len == 5);
        return switch (space) {
            .content => "/admin/types",
            .taxonomies => "/admin/structure/taxonomies",
            .settings => "/admin/structure/settings",
            .components => "/admin/components",
            .custom => "/admin/custom-fields",
        };
    }

    pub fn title(space: Space) []const u8 {
        comptime std.debug.assert(@typeInfo(Space).@"enum".fields.len == 5);
        return switch (space) {
            .content => "Content types",
            .taxonomies => "Taxonomies",
            .settings => "Settings",
            .components => "Components",
            .custom => "Custom Fields",
        };
    }

    pub fn kind(space: Space) Kind {
        comptime std.debug.assert(@typeInfo(Space).@"enum".fields.len == 5);
        return switch (space) {
            .content, .taxonomies => .record,
            .settings => .settings,
            .components, .custom => .component,
        };
    }
};

pub fn of(session: *const admin.Session) Space {
    std.debug.assert(session.signed_in());
    const path = session.request.path();

    inline for (.{ Space.settings, Space.components, Space.custom, Space.taxonomies }) |space| {
        if (std.mem.startsWith(u8, path, comptime space.base() ++ "/")) return space;
    }

    return .content;
}

pub fn hub(session: *const admin.Session, handle: []const u8) admin.Error![]const u8 {
    std.debug.assert(handle.len > 0);
    return std.fmt.allocPrint(session.arena, "{s}/{s}", .{ of(session).base(), handle }) catch
        error.OutOfMemory;
}
