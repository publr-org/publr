//! The types of user the plugins register, compiled in or installed, and the apps each may
//! sign in to: the administrator's choice when made (`user_type.set`), else the plugin's.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const model = @import("../model/user_type.zig");

pub const Declared = model.Declared;

/// Every registered type, compiled in first, then installed, each name once.
pub fn all(ctx: *const sdk.Ctx) sdk.Error![]const Declared {
    std.debug.assert(ctx.now_ms >= 0);

    const registry = @import("../server/registry.zig");
    var list: std.ArrayList(Declared) = .empty;

    for (registry.user_types) |declared| {
        try list.append(ctx.arena, declared);
    }

    if (ctx.sandboxed_plugins) |sandboxed| {
        for (sandboxed.manifests()) |manifest| {
            for (manifest.user_types) |declared| {
                if (find_in(list.items, declared.name) == null) {
                    var owned = declared;

                    owned.plugin = manifest.name;
                    try list.append(ctx.arena, owned);
                }
            }
        }
    }

    std.debug.assert(list.items.len <= model.types_max * 2);

    return list.items;
}

/// The registered type of that name, when one is.
pub fn find(ctx: *const sdk.Ctx, name: []const u8) sdk.Error!?Declared {
    std.debug.assert(name.len > 0);

    return find_in(try all(ctx), name);
}

fn find_in(list: []const Declared, name: []const u8) ?Declared {
    std.debug.assert(name.len > 0);

    for (list) |declared| {
        if (std.mem.eql(u8, declared.name, name)) {
            return declared;
        }
    }

    return null;
}

/// The apps the type's people may sign in to now.
pub fn apps_of(ctx: *const sdk.Ctx, declared: Declared) sdk.Error![]const []const u8 {
    std.debug.assert(declared.name.len > 0);

    const key = try setting_key(ctx.arena, declared.name);
    const text = try store.settings.get(ctx.db, ctx.arena, key) orelse return declared.apps;
    const chosen = std.json.parseFromSliceLeaky(model.Setting, ctx.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return declared.apps;

    return chosen.apps;
}

pub fn setting_key(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(name.len > 0);

    return std.mem.concat(arena, u8, &.{ model.setting_prefix, name });
}

/// Whether an account of `type_name` may be signed in to `app`: staff (no type) everywhere
/// its roles reach; a type only in the apps it opens; a type no plugin registers now, nowhere.
pub fn opens(ctx: *const sdk.Ctx, type_name: []const u8, app: []const u8) sdk.Error!bool {
    std.debug.assert(type_name.len <= model.name_len_max);

    if (type_name.len == 0) {
        return true;
    }

    const declared = try find(ctx, type_name) orelse return false;

    return model.opens(try apps_of(ctx, declared), app);
}

/// Every role a registered type gives its people (`.roles`), each once.
pub fn roles_given(ctx: *const sdk.Ctx) sdk.Error![]const []const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    var list: std.ArrayList([]const u8) = .empty;

    for (try all(ctx)) |declared| {
        for (declared.roles) |name| {
            if (!held_in(list.items, name)) {
                try list.append(ctx.arena, name);
            }
        }
    }

    std.debug.assert(list.items.len <= model.types_max * 2 * 16);

    return list.items;
}

/// Whether an account is staff: it holds no type of user, or a role no type gives (an
/// administrator who is also a customer). Staff reach every app their roles reach.
pub fn staff(
    ctx: *const sdk.Ctx,
    held_types: []const []const u8,
    roles: []const []const u8,
) sdk.Error!bool {
    std.debug.assert(held_types.len <= model.types_max);
    std.debug.assert(ctx.now_ms >= 0);

    if (held_types.len == 0) {
        return true;
    }

    const given = try roles_given(ctx);

    for (roles) |name| {
        if (!held_in(given, name)) {
            return true;
        }
    }

    return false;
}

/// Whether an account holding `held_types` and `roles` may be signed in to `app`: staff
/// everywhere their roles reach, anyone else only in the apps one of its types opens.
pub fn opens_any(
    ctx: *const sdk.Ctx,
    held_types: []const []const u8,
    roles: []const []const u8,
    app: []const u8,
) sdk.Error!bool {
    std.debug.assert(held_types.len <= model.types_max);
    std.debug.assert(app.len > 0);

    if (try staff(ctx, held_types, roles)) {
        return true;
    }

    for (held_types) |name| {
        if (name.len > 0 and try opens(ctx, name, app)) {
            return true;
        }
    }

    return false;
}

/// The first role `declared` gives that is staff now, or null: a type gives visitor roles
/// only, so one that names a staff role is refused at enable, and gives nothing meanwhile.
pub fn staff_role_given(ctx: *const sdk.Ctx, declared: Declared) sdk.Error!?[]const u8 {
    std.debug.assert(declared.name.len > 0);
    std.debug.assert(declared.roles.len <= 64);

    for (declared.roles) |name| {
        if (try sdk.stored_roles.staff(ctx, name)) {
            return name;
        }
    }

    return null;
}

/// The first registered type that gives the role `name`, if one does.
pub fn giver_of(ctx: *const sdk.Ctx, name: []const u8) sdk.Error!?Declared {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    for (try all(ctx)) |declared| {
        if (held_in(declared.roles, name)) {
            return declared;
        }
    }

    return null;
}

/// The JSON list `store.users.Window.type_roles` takes.
pub fn roles_given_json(ctx: *const sdk.Ctx) sdk.Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const given = try roles_given(ctx);
    const text = std.json.Stringify.valueAlloc(ctx.arena, given, .{}) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(text.len >= 2);

    return text;
}

fn held_in(list: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (list) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}
