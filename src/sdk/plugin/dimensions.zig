//! Dimensions: what makes a field hold a value per combination (`name@language=pl`, see
//! `model/dimension.zig`). Plugins declare them (`.dimensions`, each made with
//! `publr.dimension.define`): the languages plugin a `language`, an A/B test a `variation`.
//! The core draws a setting for each on every field, reads each one's values where it shows
//! or serves them, and knows nothing else about what a dimension is.
const std = @import("std");
const plugin_define = @import("define.zig");
const model_dimension = @import("../../model/dimension.zig");

/// What `publr.dimension.define` takes, and `.dimensions` lists.
pub const Dimension = struct {
    /// What it is called where values are stored and asked for: `language`.
    name: []const u8,
    /// Its key in an address's query, where the admin keeps what a page shows (`?lang=pl`);
    /// empty: its name.
    param: []const u8 = "",
    /// Higher keeps its value longer when a read falls back across dimensions.
    priority: i32 = 0,
    /// The field setting that turns it on: `Translate`.
    label: []const u8,
    /// What the setting means, under it.
    help: []const u8,
    /// The admin's picker of the value content shows in, top right: `Content language`.
    /// Empty: no picker.
    picker: []const u8 = "",
    /// A read of the plugin's own (`publr.operation.define`) taking nothing and answering
    /// `values`: every `Value` in the order people see them, the main one first.
    list: type,
    /// Its values have pages of their own, under each one's `address` (`/pl`). At most one
    /// dimension on a site does; the others are chosen per request.
    addresses: bool = false,
    /// The type setting for records not written in a value: shown in the main values
    /// (`keep`), or left out of it (`omit`). Unnamed: the setting is not offered.
    untranslated: Untranslated = .{},
};

pub const Untranslated = model_dimension.Untranslated;

/// One value of a dimension as the core shows and serves it.
pub const Value = struct {
    /// `pl`, `en-gb`: the code its values are stored under. The main value is stored under
    /// the plain name; its code still names it (`<html lang>`).
    code: []const u8,
    /// What people call it: `Polski`.
    label: []const u8,
    /// Where its pages are, under the site: `/pl`; empty for the main value, and for a
    /// dimension without pages of its own.
    address: []const u8 = "",
    main: bool = false,
};

pub const values_max: u32 = 64;

/// `publr.dimension.define(.{ .name, .label, .help, .list, ... })`: the dimension, its name
/// and words checked.
pub fn define(comptime dimension: Dimension) Dimension {
    comptime {
        if (!model_dimension.valid_name(dimension.name)) {
            @compileError("dimension `" ++ dimension.name ++ "`: a name is lowercase letters, " ++
                "digits and _, a letter first");
        }

        if (dimension.label.len == 0 or dimension.help.len == 0) {
            @compileError("dimension `" ++ dimension.name ++ "` needs a label and help");
        }

        if (dimension.param.len > 0 and !model_dimension.valid_name(dimension.param)) {
            @compileError("dimension `" ++ dimension.name ++ "`: `param` is lowercase letters, " ++
                "digits and _, a letter first");
        }

        var checked = dimension;

        checked.param = if (dimension.param.len > 0) dimension.param else dimension.name;

        const done = checked;

        return done;
    }
}

/// The dimensions a plugin declares, each list resolved to the plugin's own operation.
pub fn of(comptime Plugin: type) []const Dimension {
    comptime {
        const name = Plugin.manifest.name;

        if (!plugin_define.has(Plugin, "dimensions")) {
            return &.{};
        }

        const given: []const Dimension = plugin_define.get(Plugin, "dimensions");
        var resolved: []const Dimension = &.{};

        if (given.len > model_dimension.dimensions_max) {
            @compileError("plugin " ++ name ++ ": at most 64 dimensions");
        }

        for (given) |declared| {
            const checked = define(declared);
            const List = @import("operation_define.zig").Described(checked.list, name, Plugin.docs);
            const kind = if (@hasDecl(List, "given")) List.given.kind else List.kind;

            if (kind != .read or !@hasField(List.Out, "values")) {
                @compileError("plugin " ++ name ++ ": dimension `" ++ checked.name ++
                    "`'s list is a read answering `values`");
            }

            var one = checked;

            one.list = List;
            resolved = resolved ++ &[_]Dimension{one};
        }

        const done = resolved;

        return done;
    }
}

/// The dimensions `Plugin` declares, as its manifest carries them.
pub fn declared_of(comptime Plugin: type) []const model_dimension.Declared {
    comptime {
        var out: []const model_dimension.Declared = &.{};

        std.debug.assert(of(Plugin).len <= model_dimension.dimensions_max);

        for (of(Plugin)) |dimension| {
            out = out ++ &[_]model_dimension.Declared{.{
                .name = dimension.name,
                .param = dimension.param,
                .priority = dimension.priority,
                .addresses = dimension.addresses,
                .label = dimension.label,
                .help = dimension.help,
                .picker = dimension.picker,
                .list = dimension.list.name,
                .untranslated = dimension.untranslated,
            }};
        }

        const done = out;

        return done;
    }
}
