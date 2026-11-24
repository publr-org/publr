//! Who reads a field (`field.Visibility`): a record as read leaves out each top-level field
//! the caller may not see. A restricted field is seen by the plugin declaring it, people
//! holding one of its roles, and administrators; a special-category one only by the plugin
//! and its roles, never by administrators, the system or a device (agents, the CLI).
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");

const Ctx = sdk.Ctx;
const Value = std.json.Value;
const role = model.role;

/// Leaves out of `document` every field of `fields` the caller may not read.
pub fn strip(ctx: *const Ctx, fields: []const model.field.Def, document: *Value) void {
    std.debug.assert(fields.len <= model.field.fields_max);

    if (document.* != .object) {
        return;
    }

    for (fields) |field| {
        if (field.visibility.hidden() and !sees(ctx, field.visibility)) {
            _ = document.object.orderedRemove(field.name);
        }
    }

    std.debug.assert(document.* == .object);
}

/// Whether any field of `fields` is one only some may read.
pub fn any_hidden(fields: []const model.field.Def) bool {
    std.debug.assert(fields.len <= model.field.fields_max);

    for (fields) |field| {
        if (field.visibility.hidden()) {
            return true;
        }
    }

    return false;
}

pub fn sees(ctx: *const Ctx, visibility: model.field.Visibility) bool {
    std.debug.assert(visibility.hidden());
    std.debug.assert(visibility.roles.len <= role.user_roles_max * 4);

    const plugin = switch (ctx.caller) {
        .plugin => |caller| caller.name,
        else => ctx.plugin,
    };

    if (plugin.len > 0 and std.mem.eql(u8, plugin, visibility.plugin)) {
        return true;
    }

    const person = ctx.caller == .user;

    if (!person and (visibility.special or ctx.caller != .system)) {
        return false;
    }

    if (!person) {
        return true;
    }

    const held = ctx.caller.roles() orelse return false;

    for (held) |name| {
        if (!visibility.special and std.mem.eql(u8, name, role.admin)) {
            return true;
        }

        for (visibility.roles) |allowed| {
            if (std.mem.eql(u8, name, allowed)) {
                return true;
            }
        }
    }

    return false;
}

test "a restricted field: its plugin, its roles and administrators; a special one, not them" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const restricted: model.field.Visibility = .{
        .restricted = true,
        .roles = &.{"pharmacist"},
        .plugin = "pharmacy",
    };
    var special = restricted;

    special.special = true;

    const admin = harness.ctx(.{
        .user = .{
            .id = "u1",
        },
    });
    const pharmacist = harness.ctx(.{
        .user = .{
            .id = "u2",
            .roles = &.{"pharmacist"},
        },
    });
    var plugin = harness.ctx(.anonymous);

    plugin.plugin = "pharmacy";

    const visitor = harness.ctx(.anonymous);
    const system = harness.ctx(.system);

    try std.testing.expect(sees(&admin, restricted));
    try std.testing.expect(!sees(&admin, special));
    try std.testing.expect(sees(&pharmacist, special));
    try std.testing.expect(sees(&plugin, special));
    try std.testing.expect(!sees(&visitor, restricted));
    try std.testing.expect(sees(&system, restricted));
    try std.testing.expect(!sees(&system, special));
}
