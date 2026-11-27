//! Dimensions: what makes a field hold a value per combination (`name@language=pl`, see
//! `model/dimension.zig`). Plugins declare them (`.dimensions`, each made with
//! `publr.dimension.define`): the languages plugin a `language`, an A/B test a `variation`.
//! The owner says how others use it through its wrapper (`.api`): a field option, drawn on
//! the field panel by the owner's own view or as the core's cards, and a read option. The
//! core stores, reads and picks values, and knows nothing else about what a dimension is.
const std = @import("std");
const plugin_define = @import("../../sdk/plugin/bound.zig");
const model_dimension = @import("../model/dimension.zig");

/// What `publr.dimension.define` takes, and `.dimensions` lists.
pub const Dimension = struct {
    /// What it is called where values are stored and asked for: `language`.
    name: []const u8,
    /// Its key in an address's query, where the admin keeps what a page shows (`?lang=pl`);
    /// empty: its name.
    param: []const u8 = "",
    /// Higher keeps its value longer when a read falls back across dimensions.
    priority: i32 = 0,
    /// How others use it, in the owner's words: a file (`@import("api.zig")`) with a
    /// `field`, made with `field_option`, and maybe a `read`, made with `read_option`.
    api: type,
    /// A read of the plugin's own (`publr.operation.define`) taking nothing and answering
    /// `values`: every `Value` in the order people see them, the main one first. Or a family:
    /// answering `dimensions`, each a `Member` with values of its own (each A/B test), kept
    /// under `<name>-<member>`; a field holding the family holds each.
    list: type,
    /// A family's read taking `type` and `id` (a record) and answering `shown`: each field of
    /// it a member shows on (`Shown`). Without it, every field holding the family shows each.
    shown: ?type = null,
    /// Its values have pages of their own, under each one's `address` (`/pl`). At most one
    /// dimension on a site does; the others are chosen per request.
    addresses: bool = false,
};

pub const Holds = model_dimension.Holds;

const field_option_names = [_][]const u8{ "name", "takes", "holds", "default", "options" };

/// `publr.dimension.field_option(.{ .name, .takes, .holds, .default, .options })`: what a
/// field of any plugin says to hold values per the dimension (`.translatable = .required`).
/// `.takes` is an enum, each value's `///` its words; `.holds` maps each value to a `Holds`,
/// no two the same and one `.one`; `.default` the value of a field that says nothing (the
/// one holding `.one` when left out); `.options` a view drawing the setting on the field
/// panel, its `ctx.value` the value the field holds and `ctx.change(value)` handing another
/// to the form.
pub fn field_option(comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            if (!plugin_define.listed_in(&field_option_names, given)) {
                @compileError("field option: no option `" ++ given ++ "`");
            }
        }

        if (!@hasField(Options, "name") or !model_dimension.valid_name(options.name)) {
            @compileError("a field option needs `.name`: lowercase letters, digits and _, a " ++
                "letter first");
        }

        if (!@hasField(Options, "takes") or @typeInfo(options.takes) != .@"enum") {
            @compileError("field option `" ++ options.name ++ "` needs `.takes`, an enum");
        }

        if (!@hasField(Options, "holds")) {
            @compileError("field option `" ++ options.name ++ "` needs `.holds`, " ++
                "`fn (" ++ @typeName(options.takes) ++ ") publr.dimension.Holds`");
        }

        const Takes = options.takes;
        const values = std.meta.fieldNames(Takes);
        var seen: [4]bool = @splat(false);

        if (values.len > model_dimension.choices_max) {
            @compileError("field option `" ++ options.name ++ "`: at most 16 values");
        }

        for (values) |value| {
            const holds: Holds = options.holds(@field(Takes, value));

            if (seen[@backingInt(holds)]) {
                @compileError("field option `" ++ options.name ++ "`: two values hold `." ++
                    @tagName(holds) ++ "`; the field panel could not tell which a field has");
            }

            seen[@backingInt(holds)] = true;
        }

        if (!seen[@backingInt(Holds.one)]) {
            @compileError("field option `" ++ options.name ++ "`: one value holds `.one`, " ++
                "a field that does not vary");
        }

        const default: Holds = if (@hasField(Options, "default"))
            options.holds(@as(Takes, options.default))
        else
            .one;

        return struct {
            pub const publr_dimension_field_option = true;
            pub const name = options.name;
            pub const Value = Takes;
            pub const default_holds = default;
            pub const drawn = @hasField(Options, "options");
            pub const view = if (drawn) options.options else void;

            pub fn holds(value: Takes) Holds {
                return options.holds(value);
            }
        };
    }
}

/// `publr.dimension.read_option(.{ .name })`: what a read of any plugin names the dimension
/// by (`.language = "pl"`), its `///` the word on the editor's picker.
pub fn read_option(comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            if (!std.mem.eql(u8, given, "name")) {
                @compileError("read option: no option `" ++ given ++ "`");
            }
        }

        if (!@hasField(Options, "name") or !model_dimension.valid_name(options.name)) {
            @compileError("a read option needs `.name`: lowercase letters, digits and _, a " ++
                "letter first");
        }

        return struct {
            pub const publr_dimension_read_option = true;
            pub const name = options.name;
        };
    }
}

fn is_field_option(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_dimension_field_option");
}

fn is_read_option(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_dimension_read_option");
}

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

/// One dimension of a family, as its list answers it: `hero`, kept as `variation-hero`.
pub const Member = struct {
    /// Lowercase letters, digits and _, a letter first.
    name: []const u8,
    /// What people call it: `Hero headline`.
    label: []const u8,
    /// Its values, the main one first.
    values: []const Value,
};

/// A field of one record a family's member shows on, as `.shown` answers it.
pub const Shown = struct {
    /// The member: `hero`.
    member: []const u8,
    /// A top-level field of the record's type.
    field: []const u8,
};

/// `publr.dimension.define(.{ .name, .api, .list, ... })`: the dimension, its name and
/// wrapper checked.
pub fn define(comptime dimension: Dimension) Dimension {
    comptime {
        if (!model_dimension.valid_name(dimension.name)) {
            @compileError("dimension `" ++ dimension.name ++ "`: a name is lowercase letters, " ++
                "digits and _, a letter first");
        }

        if (dimension.param.len > 0 and !model_dimension.valid_name(dimension.param)) {
            @compileError("dimension `" ++ dimension.name ++ "`: `param` is lowercase letters, " ++
                "digits and _, a letter first");
        }

        const api = dimension.api;

        if (!@hasDecl(api, "field") or !is_field_option(api.field)) {
            @compileError("dimension `" ++ dimension.name ++ "`: its `.api` has `pub const " ++
                "field = publr.dimension.field_option(...)`");
        }

        if (@hasDecl(api, "read") and !is_read_option(api.read)) {
            @compileError("dimension `" ++ dimension.name ++ "`: its `.api`'s `read` is " ++
                "made with `publr.dimension.read_option`");
        }

        var checked = dimension;

        checked.param = if (dimension.param.len > 0) dimension.param else dimension.name;

        const done = checked;

        return done;
    }
}
