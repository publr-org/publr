//! Plugins' field groups placed on a type's records (rule 11a's third way: a record chooses
//! one for itself, a product's weight or tax class): each group is a `group` field of the
//! record's own document, named after the group (`shipping: { weight, class }`), so it is
//! versioned and published with the record and shown in its form. It is laid over the type
//! where the type is read for its records, never stored on the type: the schema builder
//! neither keeps nor offers it, and it goes when its plugin's group goes.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Def = model.field.Def;
const Error = sdk.Error;

/// The groups placed on `handle`'s records, each as the `group` field its values are kept
/// under.
pub fn fields_of(ctx: *sdk.Ctx, handle: []const u8) Error![]const Def {
    std.debug.assert(handle.len > 0);
    std.debug.assert(handle.len <= model.content_type.handle_len_max);

    const groups = try store.field_groups.list(ctx.db, ctx.arena, .custom_fields);
    var placed: std.ArrayList(Def) = .empty;

    for (groups) |item| {
        // Only a group naming records can be placed on them: the rest are never parsed.
        if (std.mem.indexOf(u8, item.definition, "\"content\"") == null) {
            continue;
        }

        const group = @import("../../lib/json.zig").parse(
            store.field_groups.Def,
            ctx.arena,
            item.definition,
            .{},
        ) catch |err| {
            return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
        };

        if (!model.field_group.placed_on_type(group.options, handle)) {
            continue;
        }

        try placed.append(ctx.arena, .{
            .name = item.owner,
            .label = if (group.name.len > 0) group.name else item.owner,
            .kind = "group",
            .locked = true,
            .fields = group.fields,
        });
    }

    return placed.items;
}

/// Whether `candidate` is one of the `placed` groups' fields, sent back with the type: kept
/// off the type, as it is never stored there.
pub fn is_placed(placed: []const Def, candidate: Def) bool {
    std.debug.assert(placed.len <= model.field.fields_max);
    std.debug.assert(candidate.name.len > 0);

    if (!candidate.locked or !std.mem.eql(u8, candidate.kind, "group")) {
        return false;
    }

    for (placed) |group| {
        if (std.mem.eql(u8, group.name, candidate.name)) {
            return true;
        }
    }

    return false;
}
