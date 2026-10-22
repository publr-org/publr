//! `publr.fields.get(ctx, Fields, user)` and `publr.fields.save(ctx, Fields, user, values)`:
//! a plugin's own `.register_fields` group on an account, read and written as its typed
//! struct. The group is the plugin's own data, so no grant is asked; a save changes the
//! group's fields only, every other group's values stay. Neither asks where the group is
//! placed: a plugin's location rule may read its own group to decide.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const json = @import("../../lib/json.zig");
const PluginCtx = @import("context.zig").PluginCtx;
const user_operations = @import("../../operations/user.zig");
const user_fields = @import("../../operations/user/fields.zig");
const field_model = @import("../../model/field.zig");
const registry = @import("../../server/registry.zig");
const custom_fields = @import("../../operations/custom_fields.zig");

const Error = sdk.Error;
const Value = std.json.Value;

/// The group's values on the account, wherever its location places it: a plugin's location
/// rule may read its own group to decide.
pub fn get(ctx: *PluginCtx, comptime Fields: type, user: []const u8) Error!Fields {
    std.debug.assert(user.len > 0);

    const inner = ctx.inner;
    var as_core = AsCore.of(inner);
    defer as_core.done();

    const found = try user_operations.find_user(inner, user) orelse return error.NotFound;
    const own = try own_group(inner, Fields, as_core.plugin);
    const document = try user_fields.read(inner, found.user.id, &.{own});
    const values = document.object.get(own.name) orelse Value{
        .object = .empty,
    };

    return std.json.parseFromValueLeaky(Fields, inner.arena, values, .{
        .ignore_unknown_fields = true,
    }) catch error.Invalid;
}

/// Writes the group's fields on the account, checked as every write is.
pub fn save(ctx: *PluginCtx, comptime Fields: type, user: []const u8, values: Fields) Error!void {
    std.debug.assert(user.len > 0);

    const inner = ctx.inner;
    var as_core = AsCore.of(inner);
    defer as_core.done();

    const found = try user_operations.find_user(inner, user) orelse return error.NotFound;
    const own = try own_group(inner, Fields, as_core.plugin);
    const placed = try user_fields.definition(inner, found.user.id, found.user.roles);
    const defs = if (placed_has(placed, own.name))
        placed
    else
        std.mem.concat(inner.arena, field_model.Def, &.{ placed, &.{own} }) catch {
            return error.OutOfMemory;
        };
    var document = try user_fields.read(inner, found.user.id, defs);
    const text = std.json.Stringify.valueAlloc(inner.arena, values, .{}) catch {
        return error.OutOfMemory;
    };
    const group = json.parse(Value, inner.arena, text, .{}) catch return error.Invalid;

    document.object.put(inner.arena, own.name, group) catch return error.OutOfMemory;

    const written = std.json.Stringify.valueAlloc(inner.arena, document, .{}) catch {
        return error.OutOfMemory;
    };

    try user_fields.write(inner, found.user.id, defs, written);
}

/// Reading as core reads: the plugin's own group needs no grant of the plugin's.
const AsCore = struct {
    inner: *sdk.Ctx,
    caller: sdk.Caller,
    plugin: []const u8,

    fn of(inner: *sdk.Ctx) AsCore {
        std.debug.assert(inner.plugin.len > 0);

        const kept: AsCore = .{
            .inner = inner,
            .caller = inner.caller,
            .plugin = inner.plugin,
        };

        inner.caller = .system;
        inner.plugin = "";

        return kept;
    }

    fn done(as_core: *const AsCore) void {
        std.debug.assert(as_core.plugin.len > 0);

        as_core.inner.caller = as_core.caller;
        as_core.inner.plugin = as_core.plugin;
    }
};

/// The plugin's group (`<plugin>`, then `<plugin>_1`, ...) whose fields are `Fields`', as
/// the account's fields list it.
fn own_group(inner: *sdk.Ctx, comptime Fields: type, plugin: []const u8) Error!field_model.Def {
    std.debug.assert(plugin.len > 0);

    for (0..field_model.fields_max) |index| {
        const handle = if (index == 0)
            plugin
        else
            try std.fmt.allocPrint(inner.arena, "{s}_{d}", .{ plugin, index });
        const got = registry.SDK.dispatch(inner, custom_fields.Get, .{
            .group = handle,
        }) catch |err| switch (err) {
            error.NotFound => return error.NotFound,
            else => return err,
        };

        if (same_fields(Fields, got.definition.fields)) {
            return .{
                .name = got.definition.handle,
                .label = got.definition.name,
                .kind = "group",
                .fields = got.definition.fields,
            };
        }
    }

    return error.NotFound;
}

fn placed_has(defs: []const field_model.Def, handle: []const u8) bool {
    std.debug.assert(handle.len > 0);

    for (defs) |def| {
        if (std.mem.eql(u8, def.name, handle)) {
            return true;
        }
    }

    return false;
}

fn same_fields(comptime Fields: type, defs: []const field_model.Def) bool {
    const names = comptime std.meta.fieldNames(Fields);

    std.debug.assert(defs.len <= field_model.fields_max);

    if (defs.len != names.len) {
        return false;
    }

    inline for (names, 0..) |name, index| {
        if (!std.mem.eql(u8, defs[index].name, name)) {
            return false;
        }
    }

    return true;
}

test "a plugin's own group read and written by field, other groups kept" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);
    const admin_id = (try user_operations.find_user(&system, "admin@example.com")).?.user.id;

    for ([_][]const u8{ "loyalty", "other" }) |handle| {
        const text = try std.fmt.allocPrint(
            system.arena,
            "{{\"handle\":\"{s}\",\"name\":\"{s}\",\"kind\":\"component\"," ++
                "\"title_field\":\"\",\"group\":{{\"location\":[{{\"rules\":" ++
                "[{{\"field\":\"destination\",\"value\":\"user\"}}]}}]}}," ++
                "\"fields\":[{{\"name\":\"points\",\"label\":\"Points\",\"kind\":\"integer\"}}]}}",
            .{ handle, handle },
        );

        _ = try registry.SDK.dispatch(&system, custom_fields.Create, .{
            .group = handle,
            .definition = text,
        });
    }

    const Points = struct {
        points: ?i64 = null,
    };
    var inner = harness.ctx(.anonymous);
    inner.plugin = "loyalty";
    var ctx: PluginCtx = .{
        .inner = &inner,
    };

    try std.testing.expectEqual(@as(?i64, null), (try get(&ctx, Points, admin_id)).points);
    var transaction = try inner.db.transaction();
    try save(&ctx, Points, admin_id, .{
        .points = 120,
    });
    try transaction.commit();
    try std.testing.expectEqual(@as(?i64, 120), (try get(&ctx, Points, admin_id)).points);
    try std.testing.expectEqualStrings("loyalty", inner.plugin);

    inner.plugin = "elsewhere";
    try std.testing.expectError(error.NotFound, get(&ctx, Points, admin_id));
}
