//! Published interfaces: what a plugin offers others to build against, as data (its
//! contracts and its dimensions' wrappers), never its code. A plugin naming another in
//! `depends_on` or `compatible_with` imports it by name, `@import("payments")`, and gets a
//! module made from that data: `payments.contracts.method` to provide, its field options
//! checked where its records name them. Compiled in, the module is made from the owner's
//! declarations; installed, `plugin build` writes it from the owner's manifest.
const std = @import("std");
const model = @import("../model/published.zig");
const contract = @import("contract.zig");

pub const Interface = model.Interface;
pub const Contract = model.Contract;
pub const Part = model.Part;

/// A plugin's published interface, from its declarations.
pub fn of(comptime Plugin: type) Interface {
    comptime {
        @setEvalBranchQuota(200_000);

        std.debug.assert(Plugin.manifest.name.len > 0);

        return .{
            .plugin = Plugin.manifest.name,
            .version = Plugin.manifest.version,
            .contracts = contract.owned_of(Plugin),
            .dimensions = @import("plugin/dimensions.zig").declared_of(Plugin),
        };
    }
}

/// The interface's contracts, each under its name past the plugin's (`.method` for
/// `payments.method`), as contracts to provide.
pub fn contracts(comptime interface: Interface) type {
    comptime {
        const list = interface.contracts;

        std.debug.assert(list.len <= model.contracts_max);

        var names: [list.len][]const u8 = undefined;
        var types: [list.len]type = undefined;
        var attributes: [list.len]std.builtin.Type.StructField.Attributes = undefined;

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

/// Each dimension option the plugin's fields name (`.translatable = .required`) is one a
/// dimension it may use offers, the value one the option takes: its own dimensions', or
/// those of a plugin it names in `depends_on` or `compatible_with`, as `present` (the
/// interfaces of the plugins there when it builds) describes them. An option none of them
/// offers fails the build, unless a plugin it names is not there to say.
pub fn check(comptime Plugin: type, comptime present: []const Interface) void {
    comptime {
        @setEvalBranchQuota(200_000);

        std.debug.assert(Plugin.manifest.name.len > 0);

        const plugin_define = @import("plugin/define.zig");
        const types = plugin_define.get(Plugin, "content_types") ++
            plugin_define.get(Plugin, "taxonomies") ++
            @import("plugin.zig").custom_fields_of(Plugin);
        const usable = usable_of(Plugin, present);

        for (types) |declared| {
            check_fields(usable, Plugin.manifest.name ++ ": " ++ declared.handle, declared.fields);
        }
    }
}

/// What a plugin's fields may name options of: its own interface and the ones of each plugin
/// it names that is there; `complete` when every plugin it names is.
const Usable = struct {
    interfaces: []const Interface,
    complete: bool,
};

fn usable_of(comptime Plugin: type, comptime present: []const Interface) Usable {
    comptime {
        const plugin_define = @import("plugin/define.zig");
        const depends_on = @import("plugin/depends_on.zig");
        const named = plugin_define.get(Plugin, "depends_on") ++
            plugin_define.get(Plugin, "compatible_with");
        var interfaces: []const Interface = &.{of(Plugin)};
        var complete = true;

        std.debug.assert(present.len <= 1024);

        for (named) |text| {
            const name = depends_on.parse(text).name;
            const found: ?Interface = for (present) |interface| {
                if (std.mem.eql(u8, interface.plugin, name)) {
                    break interface;
                }
            } else null;

            if (found) |interface| {
                interfaces = interfaces ++ &[_]Interface{interface};
            } else {
                complete = false;
            }
        }

        return .{
            .interfaces = interfaces,
            .complete = complete,
        };
    }
}

const Offered = struct {
    plugin: []const u8,
    option: @import("../model/dimension.zig").FieldOption,
};

fn check_fields(
    comptime usable: Usable,
    comptime label: []const u8,
    comptime fields: []const @import("../model/field.zig").Def,
) void {
    comptime {
        std.debug.assert(label.len > 0);

        for (fields) |field| {
            check_fields(usable, label, field.fields);

            for (field.wrapped) |wrapped| {
                const where = label ++ ": field `" ++ field.name ++ "`: `." ++
                    wrapped.option ++ "`";
                const found: ?Offered = for (usable.interfaces) |interface| {
                    if (interface.field_option(wrapped.option)) |option| {
                        break .{
                            .plugin = interface.plugin,
                            .option = option,
                        };
                    }
                } else null;

                if (found) |offered| {
                    const takes = for (offered.option.choices) |choice| {
                        if (std.mem.eql(u8, choice.value, wrapped.value)) {
                            break true;
                        }
                    } else false;

                    if (!takes) {
                        @compileError(where ++ " takes no `." ++ wrapped.value ++ "` (" ++
                            offered.plugin ++ "'s option takes " ++
                            choices_text(offered.option) ++ ")");
                    }
                } else if (usable.complete) {
                    @compileError(where ++ ": no dimension of the plugin or of a plugin it " ++
                        "names in `depends_on` or `compatible_with` offers it");
                }
            }
        }
    }
}

fn choices_text(comptime option: @import("../model/dimension.zig").FieldOption) []const u8 {
    comptime {
        var text: []const u8 = "";

        std.debug.assert(option.choices.len > 0);

        for (option.choices, 0..) |choice, index| {
            text = text ++ (if (index == 0) "" else ", ") ++ "`." ++ choice.value ++ "`";
        }

        return text;
    }
}

test "a published contract: each part's shapes as data, provided by name past the owner's" {
    const Start = struct {
        pub const In = struct {
            order: []const u8,
            amount: i64,
        };
        pub const Out = struct {
            redirect: []const u8,
        };
    };
    const Method = contract.define(.{
        .name = "payments.method",
        .operations = .{
            .start = Start,
        },
    });
    const interface: Interface = .{
        .plugin = "payments",
        .version = "1.0.0",
        .contracts = &.{.{
            .name = Method.contract_name,
            .parts = Method.parts,
        }},
    };
    const Given = contracts(interface);
    const Provided = (Given{}).method;

    try std.testing.expectEqualStrings("payments.method", Provided.contract_name);
    try std.testing.expectEqualStrings("payments", Provided.owner);
    try std.testing.expect(Provided.required("start"));
    try std.testing.expectEqual(@as(usize, 2), Provided.parts[0].input.len - 1);
}
