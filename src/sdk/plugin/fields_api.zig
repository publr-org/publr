//! `publr.fields.get(ctx, Fields, user)` and `publr.fields.save(ctx, Fields, user, values)`:
//! a plugin's own `.register_fields` group on an account, read and written as its typed
//! struct, compiled in or installed alike: both call `custom_fields.values` and
//! `custom_fields.save_values`. The group is the plugin's own data, so no grant is asked; a
//! save changes the group's fields only, every other group's values stay. Neither asks
//! where the group is placed: a plugin's location rule may read its own group to decide.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const json = @import("../../lib/json.zig");
const PluginCtx = @import("context.zig").PluginCtx;
const guest = @import("guest.zig");
const values_operations = @import("../../operations/custom_fields/values.zig");

const Error = sdk.Error;

/// The group's values on the account, wherever its location places it.
pub fn get(ctx: *PluginCtx, comptime Fields: type, user: []const u8) Error!Fields {
    std.debug.assert(user.len > 0);

    const got = try ctx.call(values_operations.Values, .{
        .user = user,
        .group = comptime handle_of(Fields),
    });

    return json.parse(Fields, ctx.arena(), got.values, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.Invalid;
}

/// Writes the group's fields on the account, checked as every write is.
pub fn save(ctx: *PluginCtx, comptime Fields: type, user: []const u8, values: Fields) Error!void {
    std.debug.assert(user.len > 0);

    const text = std.json.Stringify.valueAlloc(ctx.arena(), values, .{}) catch {
        return error.OutOfMemory;
    };

    _ = try ctx.call(values_operations.SaveValues, .{
        .user = user,
        .group = comptime handle_of(Fields),
        .values = text,
    });
}

/// The handle of the plugin's group whose fields are `Fields`: `<plugin>` for its first
/// `.register_fields` group, `<plugin>_<n>` for the others. Installed, the plugin is the
/// module's own; compiled in, the one that registers `Fields`.
fn handle_of(comptime Fields: type) []const u8 {
    comptime {
        const plugins = if (guest.mode == .sandboxed)
            [_]type{@import("root").Plugin}
        else
            @import("../../server/registry.zig").bound_plugins;

        for (plugins) |Plugin| {
            const declared = @hasDecl(Plugin, "options") and
                @hasField(@TypeOf(Plugin.options), "register_fields");

            if (!declared) {
                continue;
            }

            for (Plugin.options.register_fields, 0..) |entry, index| {
                if (entry.fields != Fields) {
                    continue;
                }

                const name = Plugin.manifest.name;

                const numbered = name ++ "_" ++ std.fmt.comptimePrint("{d}", .{index});

                return if (index == 0) name else numbered;
            }
        }

        @compileError(@typeName(Fields) ++ " is no plugin's `.register_fields` group");
    }
}
