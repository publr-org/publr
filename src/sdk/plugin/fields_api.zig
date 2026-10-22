//! `publr.fields.get(ctx, Fields, user)` and `publr.fields.save(ctx, Fields, user, values)`:
//! a plugin's own `.register_fields` group on an account, read and written as its typed
//! struct. The group is the plugin's own data, so no grant is asked; a save changes the
//! group's fields only, every other group's values stay.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const json = @import("../../lib/json.zig");
const PluginCtx = @import("context.zig").PluginCtx;
const user_operations = @import("../../operations/user.zig");
const user_fields = @import("../../operations/user/fields.zig");
const field_model = @import("../../model/field.zig");

const Error = sdk.Error;
const Value = std.json.Value;

/// The group's values on the account; null when the group's location doesn't reach it.
pub fn get(ctx: *PluginCtx, comptime Fields: type, user: []const u8) Error!?Fields {
    std.debug.assert(user.len > 0);

    const held = try Held(Fields).read(ctx.inner, user) orelse return null;
    const values = held.document.object.get(held.handle) orelse Value{
        .object = .empty,
    };

    return std.json.parseFromValueLeaky(Fields, ctx.inner.arena, values, .{
        .ignore_unknown_fields = true,
    }) catch error.Invalid;
}

/// Writes the group's fields on the account, checked as every write is; `NotFound` when the
/// group's location doesn't reach it.
pub fn save(ctx: *PluginCtx, comptime Fields: type, user: []const u8, values: Fields) Error!void {
    std.debug.assert(user.len > 0);

    const inner = ctx.inner;
    var held = try Held(Fields).read(inner, user) orelse return error.NotFound;
    const text = std.json.Stringify.valueAlloc(inner.arena, values, .{}) catch {
        return error.OutOfMemory;
    };
    const group = json.parse(Value, inner.arena, text, .{}) catch return error.Invalid;

    held.document.object.put(inner.arena, held.handle, group) catch return error.OutOfMemory;

    const document = std.json.Stringify.valueAlloc(inner.arena, held.document, .{}) catch {
        return error.OutOfMemory;
    };

    try user_fields.write(inner, held.user_id, held.defs, document);
}

fn Held(comptime Fields: type) type {
    return struct {
        user_id: []const u8,
        defs: []const field_model.Def,
        document: Value,
        handle: []const u8,

        /// The account's fields as the system reads them (the plugin's own group needs no
        /// grant), and which group is the plugin's `Fields`.
        fn read(inner: *sdk.Ctx, user: []const u8) Error!?@This() {
            std.debug.assert(inner.plugin.len > 0);

            const caller = inner.caller;
            const plugin = inner.plugin;

            // Read as core reads: the plugin's own grants don't come into it.
            inner.caller = .system;
            inner.plugin = "";
            defer inner.caller = caller;
            defer inner.plugin = plugin;

            const found = try user_operations.find_user(inner, user) orelse return error.NotFound;
            const defs = try user_fields.definition(inner, found.user.roles);
            const handle = handle_of(defs, plugin) orelse return null;
            const document = try user_fields.read(inner, found.user.id, defs);

            std.debug.assert(document == .object);

            return .{
                .user_id = found.user.id,
                .defs = defs,
                .document = document,
                .handle = handle,
            };
        }

        /// The plugin's group (`<plugin>` or `<plugin>_<n>`) whose fields are `Fields`'.
        fn handle_of(defs: []const field_model.Def, plugin: []const u8) ?[]const u8 {
            std.debug.assert(plugin.len > 0);

            for (defs) |def| {
                const own = std.mem.eql(u8, def.name, plugin) or
                    (std.mem.startsWith(u8, def.name, plugin) and
                        def.name.len > plugin.len and def.name[plugin.len] == '_');

                if (own and same_fields(def.fields)) {
                    return def.name;
                }
            }

            return null;
        }

        fn same_fields(defs: []const field_model.Def) bool {
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
    };
}

test "a plugin's own group read and written by field, other groups kept" {
    const custom_fields = @import("../../operations/custom_fields.zig");
    const registry = @import("../../server/registry.zig");
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

    try std.testing.expectEqual(@as(?i64, null), (try get(&ctx, Points, admin_id)).?.points);
    var transaction = try inner.db.transaction();
    try save(&ctx, Points, admin_id, .{
        .points = 120,
    });
    try transaction.commit();
    try std.testing.expectEqual(@as(?i64, 120), (try get(&ctx, Points, admin_id)).?.points);
    try std.testing.expectEqualStrings("loyalty", inner.plugin);

    inner.plugin = "elsewhere";
    try std.testing.expect(try get(&ctx, Points, admin_id) == null);
}
