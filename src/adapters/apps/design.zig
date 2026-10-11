//! A page as its app's design has it: the published override of the route's template and
//! of each template part it places, read as the system (they are the site's own, never a
//! visitor's), applied to what the files rendered. A page without the markers reads
//! nothing and is left as it is.

const std = @import("std");
const registry = @import("../../server/registry.zig");
const identity_module = @import("../rest/identity.zig");
const record_operations = @import("../../operations/record.zig");
const design = @import("../../model/design.zig");
const json = @import("../../lib/json.zig");
const engine = @import("../../template.zig");
const Context = @import("context.zig").Context;

const regions = engine.regions;
const overrides = engine.overrides;

pub const parts_max: u32 = record_operations.list_max;

/// What a design record's document holds, of what a page prints.
const Printed = struct {
    name: []const u8 = "",
    output: []const u8 = "",
};

/// `page`, rendered from the template at `rel`, with the app's published overrides.
pub fn apply(context: Context, rel: []const u8, page: []const u8) ![]const u8 {
    std.debug.assert(rel.len > 0);
    std.debug.assert(context.app.spec.name.len > 0);

    if (std.mem.indexOf(u8, page, regions.template_attribute) == null) {
        return page;
    }

    const whole: regions.Range = .{
        .start = 0,
        .end = @intCast(page.len),
    };
    const has_region = regions.find(page, whole, regions.template_attribute, null) != null;
    const has_parts = std.mem.indexOf(u8, page, regions.part_attribute) != null;

    if (context.deps) |deps| {
        if (has_region) {
            deps.record_type(design.template_handle);
        }

        if (has_parts or has_region) {
            deps.record_type(design.part_handle);
        }
    }

    const template = if (has_region) try printed(context, design.template_handle, rel) else &.{};
    const parts = if (has_parts or template.len > 0)
        try printed(context, design.part_handle, null)
    else
        &.{};

    if (template.len == 0 and parts.len == 0) {
        return page;
    }

    const part_overrides = try context.arena.alloc(overrides.Part, parts.len);

    for (parts, part_overrides) |part, *out| {
        out.* = .{
            .name = part.name,
            .output = part.output,
        };
    }

    return overrides.apply(context.arena, page, .{
        .template = if (template.len > 0) template[0].output else null,
        .parts = part_overrides,
    });
}

/// The app's published records of a design type: the one for `route` when given, else
/// every one, newest first, up to `parts_max`.
fn printed(context: Context, handle: []const u8, route: ?[]const u8) ![]const Printed {
    std.debug.assert(handle.len > 0);
    std.debug.assert(route == null or route.?.len > 0);

    const arena = context.arena;
    const app_clause = try std.fmt.allocPrint(arena, "app:is:{s}", .{context.app.spec.name});
    const filters = [_][]const u8{ "status:is:published", app_clause };
    var sdk_ctx = identity_module.context(context.project, arena, .system);
    const listed = registry.SDK.dispatch(&sdk_ctx, record_operations.List, .{
        .type = handle,
        .filters = &filters,
        .filter_field = if (route != null) "route" else null,
        .filter_value = route,
        .limit = if (route != null) 1 else parts_max,
        .documents = true,
    }) catch |err| switch (err) {
        error.NotFound => return &.{},
        else => return err,
    };
    var out: std.ArrayList(Printed) = .empty;

    for (listed.documents) |text| {
        const document = json.parse(Printed, arena, text, .{
            .ignore_unknown_fields = true,
        });
        const read = document catch continue;

        if (read.output.len > 0) {
            try out.append(arena, read);
        }
    }

    std.debug.assert(out.items.len <= listed.records.len);

    return out.items;
}
