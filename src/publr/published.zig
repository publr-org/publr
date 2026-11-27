//! Published interfaces: what a plugin offers others to build against, as data (its
//! contracts and its dimensions' wrappers), never its code. A plugin naming another in
//! `depends_on` or `compatible_with` imports it by name, `@import("payments")`, and gets a
//! module made from that data: `payments.contracts.method` to provide, its field options
//! checked where its records name them. Compiled in, the module is made from the owner's
//! declarations; installed, `plugin build` writes it from the owner's manifest.
const std = @import("std");
const model = @import("model/published.zig");
const contract = @import("../sdk/contract.zig");

pub const Interface = model.Interface;
pub const Contract = model.Contract;
pub const Part = model.Part;

/// The interface's contracts, each under its name past the plugin's (`.method` for
/// `payments.method`), as contracts to provide.
pub fn contracts(comptime interface: Interface) type {
    comptime {
        const list = interface.contracts;

        std.debug.assert(list.len <= model.contracts_max);

        var names: [list.len][]const u8 = undefined;
        var types: [list.len]type = undefined;
        var attributes: [list.len]std.builtin.Type.Struct.FieldAttributes = undefined;

        for (list, &names, &types, &attributes) |each, *name, *field_type, *attribute| {
            const Published = contract.published(interface.plugin, each);

            std.debug.assert(model.owned_by(each.name, interface.plugin));

            name.* = each.name[interface.plugin.len + 1 ..];
            field_type.* = type;
            attribute.* = .{
                .@"comptime" = true,
                .default_value_ptr = &Published,
            };
        }

        const done_names = names;
        const done_types = types;
        const done_attributes = attributes;

        return @Struct(.auto, null, &done_names, &done_types, &done_attributes);
    }
}
